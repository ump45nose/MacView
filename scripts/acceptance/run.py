#!/usr/bin/env python3
"""MacView 验收场景。只经调试套接字驱动 App，每个场景写一份 S2-T2-<场景>.json。

用法：
  python3 -I scripts/acceptance/run.py <场景…> [--out docs/reports/bench]
  python3 -I scripts/acceptance/run.py --check-verdicts

--check-verdicts 不启动 App，只断言判定。滚动录制由 record-trackpad.sh 完成。
"""

import argparse
import ctypes
import json
import math
import os
import plistlib
import re
import select
import shutil
import socket
import statistics
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
os.environ["TMPDIR"] = str(ROOT / "build" / "acceptance" / "tmp") + "/"
Path(os.environ["TMPDIR"]).mkdir(parents=True, exist_ok=True)
SAMPLE_LINK = ROOT / "Fixtures" / "local" / "sample-set"
SAMPLE_TARGET = Path("/Users/yuwk/WorkSpace/Code/Github/MacView/Fixtures/local/sample-set")
TREE = ROOT / "Fixtures" / "local" / "generated" / "tree" / "10000"
HUGE_DIR = ROOT / "Fixtures" / "local" / "generated" / "image"
DERIVED = ROOT / "build" / "DerivedData-profile"
APP_BINARY = DERIVED / "Build" / "Products" / "Debug" / "MacView.app" / "Contents" / "MacOS" / "MacView"
NFS_HOST = "192.168.31.201"
NFS_EXPORT = "/fs/1000/nfs"
NFS_MOUNT = Path.home() / "MacViewBench" / "nfs"
NFS_FAULT = ROOT / "build" / "acceptance" / "nfs-fault-mount"
SMB_ROOT = Path("/Volumes/Picture")
FRAME_MS = 8.33
SCROLL_FRAME_MS = 8.333  # canvas-hitches.py 将 120 Hz 的一个刷新间隔保留三位小数。
MIN_SCROLL_FRAMES = 3000
REFRESH_120 = 119.0
LOAD_LIMIT = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.physicalcpu"], text=True).strip())
PHYSICAL_FOOTPRINT_SOURCE = "proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint"
MEMORY_KEYS = ("rawBytes", "decodedBytes", "thumbnailMemoryBytes", "preloadBytes", "inFlightBytes", "waitingTasks")
IDLE_SECONDS = 45.0
WAIT_READY = 20 * 60

SCENES = [
    "first-image", "preloaded-flip", "large-dir", "tiles-cancel", "panel-restart",
    "nas-throughput", "cached-first-screen", "nas-fault",
    "scroll-cached", "scroll-cold", "main-thread", "settle", "memory-30min",
]
OCCLUSION = "w37-occlusion"  # 定位实验显式请求；默认仍是原来的 13 个正式场景。
NAS_SCENES = {"nas-throughput", "cached-first-screen", "nas-fault"}
NAS_APP_SCENES = {"cached-first-screen", "nas-fault"}
FOREGROUND = (set(SCENES) | {OCCLUSION}) - {"nas-throughput"}
# 不看时序的场景只要求屏幕没锁。键鼠空闲、运行中输入、负载和外接显示器不参与判定。
SCREEN_ONLY = {"main-thread", "memory-30min", "tiles-cancel", "panel-restart", OCCLUSION}
# 这些场景在各自准备完成后准入；录制子进程把准入结果带回主进程。
DEFERRED_ADMISSION = (FOREGROUND - SCREEN_ONLY) | {"main-thread"}
# 开始前的空闲包含滚轮。录制过程中场景自己会发合成滚动，过程中的输入检查不含滚轮。
START_EVENTS = (1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 22, 25, 26, 27)
DURING_EVENTS = (1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 25, 26, 27)
# `subscript.read` 这类 Swift 访问器不是文件读取，所以 read 前面不能是点。
IO_RE = re.compile(
    r"(?<![A-Za-z0-9_.])(?:read|pread|readv|vnode_read)(?![A-Za-z0-9_])"
    r"|FileByteSource|ImageIO|CGImageSource|AppleJPEG|IIORead|IIOImage"
)
OTHER_IO_RE = re.compile(r"(?<![A-Za-z0-9_.])(?:open|openat|stat(?:64)?|lstat(?:64)?|fstat(?:64)?|statfs|fstatfs|getattrlist|getattrlistbulk|getdirentries|fsync|access)(?![A-Za-z0-9_])")
C1_10_UNVERIFIED = {
    "verified": False,
    "reason": "Picture 共享的 .gz 是改了扩展名的 RAR 或 7z，需求不做这些格式，不往 NAS 写样本",
}

BUDGETS = {
    "first-image": {"lastDisplayP95Milliseconds": 150, "samples": 30},
    "preloaded-flip": {"lastDisplayP95Milliseconds": FRAME_MS, "flips": 100},
    "scroll-cached": {"frameTimeP99Milliseconds": SCROLL_FRAME_MS, "refreshHz": 120, "minimumPresentedFrames": MIN_SCROLL_FRAMES},
    "scroll-cold": {"frameTimeP99Milliseconds": SCROLL_FRAME_MS, "refreshHz": 120, "minimumPresentedFrames": MIN_SCROLL_FRAMES},
    "main-thread": {"mainThreadFileReadOrImageIO": 0, "minimumPresentedFrames": MIN_SCROLL_FRAMES},
    "settle": {"settleRequestLatencyP99Milliseconds": 100},
    "nas-throughput": {"thumbnailToRawRatio": 0.9},
    "cached-first-screen": {"firstScreenP95Milliseconds": 100, "samplesPerRoot": 20},
    "large-dir": {"maxRoundTripMilliseconds": 250, "totalItems": 10000, "intermediateItemCount": True},
    "nas-fault": {"maxRoundTripMilliseconds": 250, "errorWithinSeconds": 10, "quitSeconds": 3},
    "memory-30min": {"deviation": 0.10, "leaks": 0, "ignoreFirstSeconds": 300, "maxRoundTripMilliseconds": 1000},
    OCCLUSION: {"foregroundSeconds": 180, "occludedSeconds": 300, "restoredSeconds": 120,
                "sleepDisabledOccludedSeconds": 180, "maxRoundTripMilliseconds": 1000},
    "tiles-cancel": {"cancelledGreaterThan": 0},
    "panel-restart": {"matchesQuit": True},
}


def exceeds(value, limit):
    return round(float(value) - float(limit), 3) > 0


def percentile(values, fraction):
    ordered = sorted(values)
    if not ordered:
        return None
    return ordered[min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))]


def p95(values):
    return percentile(values, 0.95)


def env_problem(env, scene=None):
    screen = env.get("screen") or {}
    if screen.get("locked") is not False:
        return True
    if scene in SCREEN_ONLY:
        return False
    load = (env.get("load") or {}).get("oneMinute")
    idle = screen.get("idleSeconds")
    if idle is None or idle < IDLE_SECONDS:
        return True
    if screen.get("inputDuringRun"):
        return True
    if screen.get("externalDisplay"):
        return True
    if load is None or load >= (env.get("load") or {}).get("limit", LOAD_LIMIT):
        return True
    return False


def is_120(hz):
    return hz is not None and float(hz) >= REFRESH_120


def judge(scene, measured, env, budget=None):
    """纯判定。环境不满足时结果作废，先于测量结论。"""
    limits = dict(BUDGETS[scene])
    if budget:
        limits.update(budget)
    if measured.get("environment"):
        return "environment"
    if scene in FOREGROUND and env_problem(env, scene):
        return "environment"
    if scene in ("scroll-cached", "scroll-cold") and (not is_120(env.get("refreshHz")) or not is_120(env.get("refreshHzAfter"))):
        return "environment"
    if scene == "memory-30min":
        return judge_memory(measured, limits)
    if scene == OCCLUSION:
        return occlusion_result(measured)["verdict"]
    if measured.get("unavailable"):
        return "unverified"
    if scene == "first-image":
        if not measured.get("samples"):
            return "unverified"
        return "fail" if measured.get("p95") is None or exceeds(measured["p95"], limits["lastDisplayP95Milliseconds"]) or measured.get("samples", 0) < limits["samples"] else "pass"
    if scene == "preloaded-flip":
        if not measured.get("flips"):
            return "unverified"
        return "fail" if measured.get("p95") is None or exceeds(measured["p95"], limits["lastDisplayP95Milliseconds"]) or measured.get("flips", 0) < limits["flips"] else "pass"
    if scene in ("scroll-cached", "scroll-cold"):
        return judge_scroll(measured, env, limits)
    if scene == "main-thread":
        if (measured.get("frames") or 0) < limits["minimumPresentedFrames"]:
            return "unverified"
        total = measured.get("mainThreadSamples")
        known = measured.get("knownSymbolSamples")
        io_count = measured.get("fileReadOrImageIO")
        if total is None or known is None or io_count is None or total == 0 or known == 0:
            return "unverified"
        return "pass" if io_count == limits["mainThreadFileReadOrImageIO"] else "fail"
    if scene == "settle":
        if measured.get("windowFront") is False:
            return "environment"
        if not measured.get("settles"):
            return "unverified"
        latency = measured.get("settleRequestLatencyP99")
        return "fail" if latency is None or exceeds(latency, limits["settleRequestLatencyP99Milliseconds"]) else "pass"
    if scene == "nas-throughput":
        ratio = measured.get("thumbnailToRawRatio")
        if ratio is None or not measured.get("samples"):
            return "unverified"
        return "pass" if ratio >= limits["thumbnailToRawRatio"] else "fail"
    if scene == "cached-first-screen":
        if not measured.get("localSamples") or not measured.get("nfsSamples"):
            return "unverified"
        local, remote = measured.get("localP95"), measured.get("nfsP95")
        limit = limits["firstScreenP95Milliseconds"]
        if local is None or remote is None or measured.get("localSamples", 0) < limits["samplesPerRoot"] or measured.get("nfsSamples", 0) < limits["samplesPerRoot"]:
            return "fail"
        return "fail" if exceeds(local, limit) or exceeds(remote, limit) else "pass"
    if scene == "large-dir":
        rtt, counts = measured.get("maxRoundTripMilliseconds"), measured.get("itemCounts")
        if not measured.get("stateSamples"):
            return "unverified"
        if rtt is None or not counts:
            return "fail"
        progressive = any(0 < count < limits["totalItems"] for count in counts)
        complete = measured.get("openOk") is True and counts[-1] == limits["totalItems"]
        return "pass" if not exceeds(rtt, limits["maxRoundTripMilliseconds"]) and progressive and complete else "fail"
    if scene == "nas-fault":
        if not measured.get("stateSamples") or not measured.get("injections"):
            return "unverified"
        rtt, quit_s = measured.get("maxRoundTripMilliseconds"), measured.get("quitSeconds")
        if rtt is None or quit_s is None or measured.get("retrySucceeded") is None or measured.get("errorWithin10Seconds") is None:
            return "fail"
        if not measured.get("quitReadInFlight") or any(not item.get("readInFlight") for item in measured["injections"]):
            return "unverified"
        required = [item for item in measured["injections"] if item.get("seconds") in (15, 60)]
        error_ok = len(required) == 4 and all(item.get("errorSeconds") is not None and not exceeds(item["errorSeconds"], limits["errorWithinSeconds"]) for item in required)
        ok = len(measured["injections"]) == 6 and not exceeds(rtt, limits["maxRoundTripMilliseconds"]) and error_ok and measured["retrySucceeded"] and measured.get("quitExitedNormally") and not exceeds(quit_s, limits["quitSeconds"])
        return "pass" if ok else "fail"
    if scene == "tiles-cancel":
        if not measured.get("requested"):
            return "unverified"
        cancelled = measured.get("cancelled")
        return "fail" if cancelled is None or cancelled <= limits["cancelledGreaterThan"] else "pass"
    if scene == "panel-restart":
        if not measured.get("before") or not measured.get("after"):
            return "unverified"
        return "pass" if measured.get("matched") is True else "fail"
    return "fail"


def judge_scroll(measured, env, limits):
    if measured.get("windowFront") is not True:
        return "environment"
    before = env.get("refreshHz")
    after = env.get("refreshHzAfter")
    if not is_120(before) or not is_120(after):
        return "environment"
    if (measured.get("frames") or 0) < limits["minimumPresentedFrames"] or not measured.get("scrollMovements"):
        return "unverified"
    frame = measured.get("frameTimeP99")
    if frame is None:
        return "unverified"
    if exceeds(frame, limits["frameTimeP99Milliseconds"]):
        return "fail"
    return "pass"


def memory_front_observations(measured):
    return ([item for values in (measured.get("windowFront"), measured.get("stateWindowFront"))
             if isinstance(values, list) for item in values] +
            [state_window_front(item.get("state")) for item in measured.get("stateSnapshots", [])])


def memory_foreground(measured):
    """每秒与每次 state 的前台状态都完整才可证明全程前台；旧快照只用于证明离开过。"""
    per_second = measured.get("windowFront")
    per_state = measured.get("stateWindowFront")
    observed = memory_front_observations(measured)
    if any(item is False for item in observed):
        return False
    if (not isinstance(per_second, list) or not per_second or
            len(per_second) != len(measured.get("residentBytes", [])) or
            not isinstance(per_state, list) or not per_state or len(per_state) != measured.get("stateSamples") or
            any(item is not True for item in per_second + per_state)):
        return None
    return True


def memory_components(measured, limits):
    front = memory_foreground(measured)
    if any(check.get("screenLocked") is not False for check in measured.get("environmentObservations", [])):
        front = False
    rtt = measured.get("maxRoundTripMilliseconds")
    failed = measured.get("stateTimedOut") or (rtt is not None and exceeds(rtt, limits["maxRoundTripMilliseconds"]))
    main = ("environment" if front is False else
            "fail" if failed and any(item is True for item in memory_front_observations(measured)) else
            "unverified" if front is None or rtt is None else "pass")
    leaks = measured.get("unexpectedLeakItems", measured.get("leaks"))
    leak_verdict = ("unverified" if leaks is None or measured.get("leakRootsParsed") is False else
                    "pass" if leaks == limits["leaks"] else "fail")
    return {"mainThread": main, "physicalFootprint": judge_memory_footprint(measured, limits), "leaks": leak_verdict}


def judge_memory(measured, limits):
    parts = memory_components(measured, limits)
    if parts["mainThread"] == "environment":
        return "environment"
    if parts["mainThread"] == "unverified":
        return "unverified"
    return "fail" if "fail" in parts.values() else "unverified" if "unverified" in parts.values() else "pass"


def judge_memory_footprint(measured, limits):
    # 新口径必须有本轮外部物理占用采样，旧 resident 证据不能被重新判为通过。
    if measured.get("physicalFootprintSource") != PHYSICAL_FOOTPRINT_SOURCE or measured.get("physicalFootprintSamplingErrors"):
        return "unverified"
    samples = measured.get("physicalFootprintBytes")
    elapsed = measured.get("sampleElapsedSeconds")
    if not isinstance(samples, list) or not samples or not isinstance(elapsed, list) or len(elapsed) != len(samples):
        return "unverified"
    if any(not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or value <= 0 for value in samples):
        return "unverified"
    if any(not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0 for value in elapsed) or any(
            after <= before for before, after in zip(elapsed, elapsed[1:])):
        return "unverified"
    # resident 原值与同次 state 分层保留；其波动、数值不参与内存预算判定。
    resident = measured.get("residentBytes")
    if not isinstance(resident, list) or len(resident) != len(samples):
        return "unverified"
    layers = measured.get("memory")
    if not isinstance(layers, list) or len(layers) != len(samples) or any(
            not isinstance(layer, dict) or any(not isinstance(layer.get(key), (int, float)) for key in MEMORY_KEYS) for layer in layers):
        return "unverified"
    tail = [value for seconds, value in zip(elapsed, samples) if seconds >= limits["ignoreFirstSeconds"] and isinstance(value, (int, float))]
    if len(tail) < 2:
        return "unverified"
    if measured.get("durationSeconds", 0) < 30 * 60:
        return "unverified"
    metrics = memory_metrics(measured, limits["ignoreFirstSeconds"])
    deviation = metrics.get("physicalFootprintRollingMedianDeviation")
    if deviation is None:
        return "unverified"
    if round(deviation - limits["deviation"], 4) > 0:
        return "fail"
    return "pass"


def memory_metrics(measured, warmup=300):
    metrics = {"rollingWindowSeconds": 60, "deviationMethod": "physicalFootprintRollingMedian60Seconds"}
    layers = measured.get("memory", [])
    for field, prefix in (("physicalFootprintBytes", "physicalFootprint"), ("residentBytes", "resident")):
        pairs = list(zip(measured.get("sampleElapsedSeconds", []), measured.get(field, [])))
        valid = [(index, t, v) for index, (t, v) in enumerate(pairs)
                 if isinstance(v, (int, float)) and math.isfinite(v) and v > 0]
        tail = [(t, v) for _, t, v in valid if t >= warmup]
        if not tail:
            continue
        median = statistics.median(v for _, v in tail)
        rolling = [statistics.median(v for t, v in tail if now - 60 < t <= now)
                   for now, _ in tail if now >= warmup + 60]
        peak, peak_time, peak_value = max(valid, key=lambda item: item[2])
        metrics.update({prefix + "MedianBytes": median,
                        prefix + "PerSecondDeviation": max(abs(v - median) / median for _, v in tail),
                        prefix + "RollingMedianDeviation": max(abs(v - median) / median for v in rolling) if rolling else None,
                        prefix + "PeakBytes": peak_value, prefix + "PeakElapsedSeconds": peak_time,
                        prefix + "PeakMemory": layers[peak] if peak < len(layers) else None})
    return metrics


class RusageInfoV4(ctypes.Structure):
    # 本机 SDK sys/resource.h：16 字节 UUID 后是 35 个 uint64_t；大小 296，物理占用偏移 72。
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime", "ri_proc_exit_abstime",
        "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
        "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility",
        "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated", "ri_cpu_time_qos_user_interactive",
        "ri_billed_system_time", "ri_serviced_system_time", "ri_logical_writes", "ri_lifetime_max_phys_footprint",
        "ri_instructions", "ri_cycles", "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint",
        "ri_runnable_time",
    )]


def physical_footprint(pid):
    """从目标进程外部读取字节数；错误交给采样边界记录，不以 resident 或 0 代替。"""
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int
    usage = RusageInfoV4()
    if libproc.proc_pid_rusage(pid, 4, ctypes.byref(usage)) != 0:
        code = ctypes.get_errno()
        raise OSError(code, f"proc_pid_rusage({pid}, RUSAGE_INFO_V4): {os.strerror(code)}")
    if usage.ri_phys_footprint <= 0:
        raise ValueError(f"proc_pid_rusage({pid}, RUSAGE_INFO_V4) 返回无效 ri_phys_footprint")
    return usage.ri_phys_footprint


def parse_leaks(output):
    summary = re.search(r"(\d+) leaks for \d+ total leaked bytes", output)
    total = int(summary.group(1)) if summary else None
    rows = [(len(m[1]), int(m[2]), m[3]) for m in re.finditer(r"^([ \t]+)(\d+) \([^\n)]+\) (.+)$", output, re.M) if "<< TOTAL >>" not in m[3]]
    indent = min((row[0] for row in rows), default=0)
    roots = [{"items": count, "description": text,
              "exempt": text.startswith("ROOT CYCLE: <NSXPCConnection ") and
              'Protocol: LNDaemonApplicationInterface  Connection: "com.apple.linkd.autoShortcut"' in text}
             for level, count, text in rows if level == indent]
    parsed = total is not None and sum(root["items"] for root in roots) == total
    return {"leaks": total, "leakRoots": roots, "leakRootsParsed": parsed,
            "unexpectedLeakItems": total - sum(root["items"] for root in roots if root["exempt"]) if parsed else None}


def clean_env():
    return {
        "load": {"oneMinute": 1.0, "limit": LOAD_LIMIT},
        "refreshHz": 59.94,
        "displayMode": {"width": 1728, "height": 1080, "refreshHz": 59.94, "builtin": True, "externalDisplay": False},
        "screen": {"locked": False, "idleSeconds": 60.0, "inputDuringRun": False, "externalDisplay": False},
    }


def check_verdicts():
    env = clean_env()
    env120 = {**env, "refreshHz": 120, "refreshHzAfter": 120}
    scroll = {"frames": 3000, "scrollMovements": 50, "windowFront": True,
              "hitches": 0, "updateP99": 2.0, "renderP99": 2.0, "frameTimeP99": 8.333}
    memory = {"leaks": 0, "residentBytes": [100] * 1800,
              "physicalFootprintBytes": [100] * 1800, "physicalFootprintSource": PHYSICAL_FOOTPRINT_SOURCE,
              "memory": [dict.fromkeys(MEMORY_KEYS, 0)] * 1800,
              "sampleElapsedSeconds": list(range(1800)), "durationSeconds": 1800,
              "stateSamples": 1800, "maxRoundTripMilliseconds": 1000,
              "windowFront": [True] * 1800, "stateWindowFront": [True] * 1800}
    valid = {
        "first-image": {"p95": 150, "samples": 30},
        "preloaded-flip": {"p95": 8.33, "flips": 100},
        "scroll-cached": scroll, "scroll-cold": scroll,
        "main-thread": {"frames": 3000, "mainThreadSamples": 10, "knownSymbolSamples": 4, "fileReadOrImageIO": 0},
        "settle": {"settles": 1, "settleRequestLatencyP99": 100},
        "nas-throughput": {"samples": 3, "thumbnailToRawRatio": 0.9},
        "cached-first-screen": {"localP95": 100, "nfsP95": 100, "localSamples": 20, "nfsSamples": 20},
        "large-dir": {"stateSamples": 20, "maxRoundTripMilliseconds": 250, "itemCounts": [0, 8190, 10000], "openOk": True},
        "nas-fault": {"stateSamples": 20, "maxRoundTripMilliseconds": 250, "quitSeconds": 3,
                      "retrySucceeded": True, "errorWithin10Seconds": True, "quitReadInFlight": True,
                      "quitExitedNormally": True, "injections": [{"mode": mode, "seconds": seconds, "errorSeconds": 5, "readInFlight": True} for mode in ("pause", "drop") for seconds in (5, 15, 60)]},
        "memory-30min": memory,
        "tiles-cancel": {"requested": 4, "cancelled": 3},
        "panel-restart": {"matched": True, "before": {"bookshelf": {}}, "after": {"bookshelf": {}}},
    }
    cases = []
    for scene, measured in valid.items():
        cases.append((f"{scene} 预算内", judge(scene, measured, env120), "pass"))
        if scene in FOREGROUND:
            cases.append((f"{scene} 锁屏", judge(scene, measured, _screen(env120, locked=True)), "environment"))
            cases.append((f"{scene} 环境优先于不可用", judge(scene, {"unavailable": True}, _screen(env120, locked=True)), "environment"))
        empty = {"windowFront": True} if scene.startswith("scroll-") else {}
        cases.append((f"{scene} 空样本", judge(scene, empty, env120), "unverified"))
    cases += [
        ("预算收紧", judge("first-image", valid["first-image"], env, {"lastDisplayP95Milliseconds": 100}), "fail"),
        ("键鼠未空闲", judge("first-image", valid["first-image"], _screen(env, idleSeconds=10)), "environment"),
        ("运行中输入", judge("first-image", valid["first-image"], _screen(env, inputDuringRun=True)), "environment"),
        ("外接显示器", judge("first-image", valid["first-image"], _screen(env, externalDisplay=True)), "environment"),
        ("开跑前负载过高", judge("first-image", valid["first-image"], _load(env, LOAD_LIMIT)), "environment"),
        ("锁定状态未知", judge("first-image", valid["first-image"], _screen(env, locked=None)), "environment"),
        ("缺少符号", judge("main-thread", {**valid["main-thread"], "knownSymbolSamples": 0}, env), "unverified"),
        ("主线程读取", judge("main-thread", {**valid["main-thread"], "fileReadOrImageIO": 1}, env), "fail"),
        ("旧主线程证据缺少呈现帧数", judge("main-thread", {**valid["main-thread"], "frames": None}, env), "unverified"),
        ("主线程对应冷滚动不足3000帧", judge("main-thread", {**valid["main-thread"], "frames": 1253}, env), "unverified"),
        ("内存不是完整30分钟", judge("memory-30min", {**memory, "durationSeconds": 1000}, env), "unverified"),
        ("物理占用按秒忽略前5分钟", judge("memory-30min", {**memory, "physicalFootprintBytes": [10000] * 300 + [100] * 1500}, env), "pass"),
        ("resident 压缩下降不参与判定", judge("memory-30min", {**memory, "residentBytes": [100] * 1200 + [50] * 600}, env), "pass"),
        ("物理占用短尖峰按60秒中位数", judge("memory-30min", {**memory, "physicalFootprintBytes": [100] * 900 + [200] * 10 + [100] * 890}, env), "pass"),
        ("物理占用持续偏离", judge("memory-30min", {**memory, "physicalFootprintBytes": [100] * 1200 + [50] * 600}, env), "fail"),
        ("旧 resident 数据不可追认为通过", judge("memory-30min", {**memory, "physicalFootprintSource": None}, env), "unverified"),
        ("物理占用缺失", judge("memory-30min", {**memory, "physicalFootprintBytes": []}, env), "unverified"),
        ("物理占用采样失败", judge("memory-30min", {**memory, "physicalFootprintSamplingErrors": [{"sampleIndex": 2, "error": "EPERM"}]}, env), "unverified"),
        ("物理占用不是有效数字", judge("memory-30min", {**memory, "physicalFootprintBytes": [100] * 1799 + [None]}, env), "unverified"),
        ("物理占用不能默认为零", judge("memory-30min", {**memory, "physicalFootprintBytes": [100] * 1799 + [0]}, env), "unverified"),
        ("物理占用与state分层错位", judge("memory-30min", {**memory, "memory": memory["memory"][:-1]}, env), "unverified"),
        ("前台已确认的停顿保持失败优先级", judge("memory-30min", {**memory, "stateTimedOut": True, "leaks": None}, env), "fail"),
        ("泄漏不忽略", judge("memory-30min", {**memory, "leaks": 416}, env), "fail"),
        ("故障时没有真实读取", judge("nas-fault", {**valid["nas-fault"], "quitReadInFlight": False}, env), "unverified"),
        ("退出靠强杀", judge("nas-fault", {**valid["nas-fault"], "quitExitedNormally": False}, env), "fail"),
    ]
    for scene in ("scroll-cached", "scroll-cold"):
        cases += [
            (f"{scene} 非120有卡顿仍环境作废", judge(scene, {**scroll, "hitches": 1}, env), "environment"),
            (f"{scene} 非120渲染超预算仍环境作废", judge(scene, {**scroll, "renderP99": 20}, env), "environment"),
            (f"{scene} 只在结束时120", judge(scene, scroll, {**env, "refreshHzAfter": 120}), "environment"),
            (f"{scene} 只在开始时120", judge(scene, scroll, {**env120, "refreshHzAfter": 60}), "environment"),
            (f"{scene} 帧超预算", judge(scene, {**scroll, "frameTimeP99": 8.334}, env120), "fail"),
            (f"{scene} 旧1253帧不可追认", judge(scene, {**scroll, "frames": 1253}, env120), "unverified"),
            (f"{scene} 少于3000帧", judge(scene, {**scroll, "frames": 2999}, env120), "unverified"),
            (f"{scene} 卡顿仅作证据", judge(scene, {**scroll, "hitches": 1}, env120), "pass"),
            (f"{scene} 两个P99之和仅作证据", judge(scene, {**scroll, "renderP99": 6.34}, env120), "pass"),
            (f"{scene} 窗口不在前台", judge(scene, {**scroll, "windowFront": False}, env120), "environment"),
        ]
    for scene in SCREEN_ONLY - {OCCLUSION}:
        for changed in (_load(env, 10), _screen(env, inputDuringRun=True, idleSeconds=1, externalDisplay=True)):
            cases.append((f"{scene} 只检查锁屏", judge(scene, valid[scene], changed), "pass"))
    merged = merge_during(env, {"load": {"oneMinute": 14.2}, "refreshHz": 120, "screen": {}})
    if merged["load"]["oneMinute"] != 1.0 or merged["load"].get("during") != 14.2 or merged["refreshHz"] != 59.94 or merged.get("refreshHzAfter") != 120:
        raise SystemExit(f"check-verdicts 失败：前后环境没有分别保留 {merged}")
    cases.append(("运行中负载不影响判定", judge("first-image", valid["first-image"], merged), "pass"))
    admitted = merge_during(env120, {"admission": env120, "before": _load(env120, 48.9),
                                    "load": {"oneMinute": 27}, "refreshHz": 120, "screen": {}})
    if admitted["load"] != {**env120["load"], "before": 48.9, "during": 27}:
        raise SystemExit(f"check-verdicts 失败：准备后的准入负载没有保留 {admitted['load']}")
    for scene in sorted(DEFERRED_ADMISSION):
        cases.append((f"{scene} 准备后准入，测量期间负载只记录", judge(scene, valid[scene], admitted), "pass"))
    cases.append(("首屏准入后启动失败保留不可验证结论", judge("cached-first-screen", {"unavailable": True}, admitted), "unverified"))
    cases.append(("首屏失败期间输入仍作废", judge("cached-first-screen", {"unavailable": True}, _screen(admitted, inputDuringRun=True)), "environment"))
    fault_state = {"windows": [{"book": "nfs://server/share/album"}], "volumes": [
        {"root": "/", "state": "healthy", "inFlight": 9, "stuck": False},
        {"root": "nfs://other/share", "state": "failed", "inFlight": 8, "stuck": True},
        {"root": "nfs://server/share", "state": "healthy", "inFlight": 1, "stuck": False},
    ]}
    if fault_volumes(fault_state) != [fault_state["volumes"][-1]] or not volume_in_flight(fault_state) or volume_failed(fault_state):
        raise SystemExit("check-verdicts 失败：NAS 当前书匹配或卷状态字段错误")
    for name, got, expected in cases:
        if got != expected:
            raise SystemExit(f"check-verdicts 失败：{name} 得到 {got}，期望 {expected}")
    print(f"check-verdicts: ok ({len(cases)} cases)")


def _screen(env, **changes):
    copied = json.loads(json.dumps(env))
    copied["screen"].update(changes)
    if "externalDisplay" in changes:
        copied["displayMode"]["externalDisplay"] = changes["externalDisplay"]
    return copied


def _load(env, value):
    copied = json.loads(json.dumps(env))
    copied["load"]["oneMinute"] = value
    return copied


def _during_load(env, value):
    copied = json.loads(json.dumps(env))
    copied["load"]["during"] = value
    return copied


def cf_library():
    cf = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    return cf, cg


def screen_locked():
    """会话字典里的 CGSSessionScreenIsLocked。读不到就当未知，不当成未锁定。"""
    try:
        cf, cg = cf_library()
        cg.CGSessionCopyCurrentDictionary.restype = ctypes.c_void_p
        cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
        cf.CFStringCreateWithCString.restype = ctypes.c_void_p
        cf.CFDictionaryGetValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        cf.CFDictionaryGetValue.restype = ctypes.c_void_p
        cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
        cf.CFGetTypeID.restype = ctypes.c_ulong
        cf.CFBooleanGetTypeID.restype = ctypes.c_ulong
        cf.CFBooleanGetValue.argtypes = [ctypes.c_void_p]
        cf.CFBooleanGetValue.restype = ctypes.c_bool
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        dictionary = cg.CGSessionCopyCurrentDictionary()
        if not dictionary:
            return None
        key = cf.CFStringCreateWithCString(None, b"CGSSessionScreenIsLocked", 0x08000100)
        value = cf.CFDictionaryGetValue(dictionary, key) if key else None
        locked = False
        if value:
            if cf.CFGetTypeID(value) != cf.CFBooleanGetTypeID():
                locked = None
            else:
                locked = bool(cf.CFBooleanGetValue(value))
        if key:
            cf.CFRelease(key)
        cf.CFRelease(dictionary)
        return locked
    except (AttributeError, OSError):
        return None


def display_probe():
    cf, cg = cf_library()
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
    cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
    for name in ("CGDisplayModeGetWidth", "CGDisplayModeGetHeight", "CGDisplayModeGetPixelWidth", "CGDisplayModeGetPixelHeight"):
        getattr(cg, name).argtypes = [ctypes.c_void_p]
        getattr(cg, name).restype = ctypes.c_size_t
    cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
    cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
    cg.CGDisplayIsBuiltin.argtypes = [ctypes.c_uint32]
    cg.CGDisplayIsBuiltin.restype = ctypes.c_int
    cg.CGGetOnlineDisplayList.argtypes = [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32)]
    cg.CGGetOnlineDisplayList.restype = ctypes.c_int32
    main_id = cg.CGMainDisplayID()
    mode = cg.CGDisplayCopyDisplayMode(main_id)
    width = int(cg.CGDisplayModeGetWidth(mode)) if mode else 0
    height = int(cg.CGDisplayModeGetHeight(mode)) if mode else 0
    pixel_width = int(cg.CGDisplayModeGetPixelWidth(mode)) if mode else 0
    pixel_height = int(cg.CGDisplayModeGetPixelHeight(mode)) if mode else 0
    refresh = float(cg.CGDisplayModeGetRefreshRate(mode)) if mode else 0.0
    ids = (ctypes.c_uint32 * 16)()
    count = ctypes.c_uint32(0)
    cg.CGGetOnlineDisplayList(16, ids, ctypes.byref(count))
    external = any(not cg.CGDisplayIsBuiltin(ids[index]) for index in range(count.value))
    builtin = bool(cg.CGDisplayIsBuiltin(main_id))
    if mode and hasattr(cg, "CGDisplayModeRelease"):
        cg.CGDisplayModeRelease.argtypes = [ctypes.c_void_p]
        cg.CGDisplayModeRelease(mode)
    return {
        "width": width, "height": height, "pixelWidth": pixel_width, "pixelHeight": pixel_height,
        "refreshHz": refresh, "builtin": builtin, "externalDisplay": external,
    }


def idle_seconds(events):
    _, cg = cf_library()
    cg.CGEventSourceSecondsSinceLastEventType.argtypes = [ctypes.c_int32, ctypes.c_uint32]
    cg.CGEventSourceSecondsSinceLastEventType.restype = ctypes.c_double
    return min(float(cg.CGEventSourceSecondsSinceLastEventType(0, event)) for event in events)


def input_mark(events):
    return time.monotonic() - idle_seconds(events)


def trace_clock_seconds():
    """与显示链接和xctrace同一主机时基；macOS上的Python3.9 monotonic原点属于各自进程。"""
    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_absolute_time.argtypes = []
    system.mach_absolute_time.restype = ctypes.c_uint64
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    system.mach_timebase_info.restype = ctypes.c_int
    info = Timebase()
    status = system.mach_timebase_info(ctypes.byref(info))
    if status != 0:
        raise OSError(f"mach_timebase_info失败：{status}")
    return system.mach_absolute_time() * info.numer / info.denom / 1e9


def sample_conditions():
    try:
        display = display_probe()
    except (AttributeError, OSError):
        display = {"width": 0, "height": 0, "pixelWidth": 0, "pixelHeight": 0, "refreshHz": 0.0, "builtin": False, "externalDisplay": True}
    try:
        idle = idle_seconds(START_EVENTS)
    except (AttributeError, OSError):
        idle = None
    return {
        "load": {"oneMinute": os.getloadavg()[0], "limit": LOAD_LIMIT, "limitSource": "sysctl -n hw.physicalcpu"},
        "displayMode": display,
        "refreshHz": display.get("refreshHz") or 0.0,
        "screen": {
            "locked": screen_locked(),
            "idleSeconds": idle,
            "inputDuringRun": False,
            "externalDisplay": bool(display.get("externalDisplay")),
        },
    }


# 一轮里等满 20 分钟仍不满足时，后面的场景只再看一眼，不再各等 20 分钟。
WAIT_EXHAUSTED = os.environ.get("MV_ACCEPTANCE_WAIT_EXHAUSTED") == "1"


def wait_ready(scene=None, screen_only=False):
    global WAIT_EXHAUSTED
    condition_scene = "memory-30min" if screen_only else scene
    if WAIT_EXHAUSTED:
        current = sample_conditions()
        return current, not env_problem(current, condition_scene)
    deadline = time.monotonic() + WAIT_READY
    while True:
        current = sample_conditions()
        if not env_problem(current, condition_scene):
            return current, True
        if time.monotonic() >= deadline:
            WAIT_EXHAUSTED = True
            return current, False
        time.sleep(2)


def norm_id(value):
    if isinstance(value, bool) or value is None:
        return value
    if isinstance(value, (int, float)) and float(value).is_integer():
        return int(value)
    return value


class DebugTimeout(TimeoutError):
    def __init__(self, detail):
        self.detail = detail
        super().__init__(f"调试响应超时：command={detail['command']} phase={detail['phase']} pid={detail['pid']}，等待{detail['responseWaitSeconds']:.3f}秒；sample={detail['sample']}")


class MeasurementError(RuntimeError):
    def __init__(self, message, measured):
        self.measured = measured
        super().__init__(message)


def admit_measurement(scene):
    admission, ready = wait_ready(scene)
    if not ready:
        raise MeasurementError("准备后环境准入等待已耗尽", {
            "environment": True, "reason": "准备后环境准入等待已耗尽", "admission": admission,
        })
    return {**admission, "inputMark": input_mark(DURING_EVENTS)}


class MemoryStateMonitor:
    """500 ms 起并行诊断；停顿预算仍为 1 秒，响应超时仍为 120 秒。"""
    def __init__(self, started, directory, observer=None, sample_times=None):
        self.started = started
        self.directory = Path(str(directory) + f"-{time.time_ns()}")
        self.directory.mkdir(parents=True, exist_ok=False)
        self.observer = observer
        self.sample_times = sample_times if sample_times is not None else []
        self.last_state = None
        self.state_snapshots = []
        self.requests = []
        self.round_trips = []
        self.window_front = []
        self.stalls = []
        self.diagnostics = []
        self.observations = []
        self.sample_jobs = []
        self.timed_out = False

    def _sample(self, client, ident, diagnostic):
        now = time.monotonic()
        self.sample_times[:] = [stamp for stamp in self.sample_times if now - stamp < 60]
        if len(self.sample_times) >= 3:
            return
        self.sample_times.append(now)
        path = self.directory / f"{client.pid}-{ident}-{len(diagnostic['samples']) + 1}.sample.txt"
        record = {"path": str(path), "startedElapsedSeconds": now - self.started, "durationSeconds": 1}
        diagnostic["samples"].append(record)
        try:
            process = subprocess.Popen(["/usr/bin/sample", str(client.pid), "1", "1", "-file", str(path)],
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
            self.sample_jobs.append((process, record, now))
        except OSError as exc:
            record["error"] = str(exc)

    def _diagnostic(self, client, ident, request, sent, now, checks):
        diagnostic = {"requestID": ident, "phase": request["phase"], "pid": client.pid,
                      "startedElapsedSeconds": sent - self.started,
                      "startedUnixSeconds": time.time() - (now - sent), "lastState": self.last_state,
                      "inFlightActions": [{"requestID": pending_id, **pending,
                                           "ageSeconds": now - pending["sentMonotonic"]}
                                          for pending_id, pending in client.pending.items()
                                          if pending["command"] != "state" and pending_id not in client.inbox],
                      "samples": [], "environmentChecks": checks}
        self.diagnostics.append(diagnostic)
        return diagnostic

    def wait(self, client, ident, timeout=120):
        request = client.pending[ident]
        sent = request["sentMonotonic"]
        timeout = min(timeout, 120)
        deadline = sent + timeout
        diagnostic = None
        stall = None
        checks = []
        next_observation = sent
        next_sample = sent + 0.5
        received_at = {}
        while True:
            now = time.monotonic()
            returned_at = received_at.get(ident, now)
            if now >= next_observation or ident in client.inbox:
                observation = {"elapsedSeconds": now - self.started, "screenLocked": screen_locked(),
                               "loadOneMinute": os.getloadavg()[0]}
                if self.observer is not None:
                    observation.update(self.observer())
                self.observations.append(observation)
                checks.append(observation)
                next_observation = time.monotonic() + 0.5
                now = time.monotonic()
            if ident in client.inbox and returned_at <= deadline:
                message = client.inbox.pop(ident)
                client.pending.pop(ident, None)
                duration = returned_at - sent
                if duration > 1 and stall is None:
                    if diagnostic is None:
                        diagnostic = self._diagnostic(client, ident, request, sent, returned_at, checks)
                    stall = diagnostic
                    self.stalls.append(stall)
                self.round_trips.append(duration * 1000)
                front = state_window_front(message.get("result")) if message.get("ok") else None
                self.window_front.append(front)
                self.requests.append({"requestID": ident, "phase": request["phase"],
                                      "startedElapsedSeconds": sent - self.started,
                                      "durationSeconds": duration, "windowFront": front, "environmentChecks": checks})
                if diagnostic is not None:
                    diagnostic.update(durationSeconds=duration, returned=True)
                if message.get("ok"):
                    self.last_state = message.get("result")
                    elapsed = now - self.started
                    if not self.state_snapshots or elapsed - self.state_snapshots[-1]["elapsedSeconds"] >= 60:
                        self.state_snapshots.append({"elapsedSeconds": elapsed, "state": self.last_state})
                return message
            if now - sent >= 0.5 and diagnostic is None:
                diagnostic = self._diagnostic(client, ident, request, sent, now, checks)
            if now - sent >= 1 and stall is None:
                stall = diagnostic
                self.stalls.append(stall)
            if diagnostic is not None and len(diagnostic["samples"]) < 3 and now >= next_sample and now < deadline:
                self._sample(client, ident, diagnostic)
                # 同一次等待最多三份现场，且所有等待/实验阶段共享滚动 60 秒限额。
                next_sample = now + 5 if len(diagnostic["samples"]) < 3 else deadline
                if len(self.sample_times) >= 3:
                    next_sample = max(next_sample, self.sample_times[0] + 60)
            if now >= deadline:
                if diagnostic is None:
                    diagnostic = self._diagnostic(client, ident, request, sent, now, checks)
                self.timed_out = True
                duration = now - sent
                self.round_trips.append(duration * 1000)
                self.window_front.append(None)
                self.requests.append({"requestID": ident, "phase": request["phase"],
                                      "startedElapsedSeconds": sent - self.started, "durationSeconds": duration,
                                      "windowFront": None, "environmentChecks": checks, "timedOut": True})
                diagnostic.update(durationSeconds=duration, returned=False)
                detail = {**request, "pid": client.pid, "requestID": ident, "timeoutSeconds": timeout,
                          "responseWaitSeconds": duration,
                          "sample": diagnostic["samples"][0]["path"] if diagnostic["samples"] else None}
                raise DebugTimeout(detail)
            boundaries = [deadline, next_observation, next_sample]
            if stall is None:
                boundaries.append(sent + 1)
            wake = min(boundary for boundary in boundaries if boundary > now)
            try:
                message = client._read_line(wake - now)
                message_id = norm_id(message.get("id"))
                received_at[message_id] = time.monotonic()
                client.inbox[message_id] = message
            except TimeoutError:
                pass

    def evidence(self):
        for process, record, started in self.sample_jobs:
            try:
                _, diagnostic = process.communicate(timeout=max(0.1, 10 - (time.monotonic() - started)))
                record.update(returnCode=process.returncode, diagnostic=diagnostic[-2000:])
            except subprocess.TimeoutExpired:
                process.kill()
                process.communicate()
                record["error"] = "sample 超过10秒未结束"
            path = Path(record["path"])
            if path.exists():
                record["rawSample"] = path.read_text(errors="replace")
                path.unlink()
        self.directory.rmdir()
        stalled = {stall["requestID"]: index for index, stall in enumerate(self.stalls)}
        # 同一现场只在 stalls 保存；earlyDiagnostics 用同一 evidence 内的索引定位。
        diagnostics = [{"requestID": diagnostic["requestID"], "phase": diagnostic["phase"],
                        "stallIndex": stalled[diagnostic["requestID"]]}
                       if diagnostic["requestID"] in stalled else diagnostic for diagnostic in self.diagnostics]
        return {"stateSamples": len(self.round_trips), "stateRoundTripMilliseconds": self.round_trips,
                "maxRoundTripMilliseconds": max(self.round_trips, default=None), "stateWindowFront": self.window_front,
                "stateRequests": self.requests, "stateTimedOut": self.timed_out, "stalls": self.stalls,
                "earlyDiagnostics": diagnostics, "lastState": self.last_state,
                "stateSnapshots": self.state_snapshots, "environmentObservations": self.observations}


class DebugClient:
    def __init__(self, path, phase=None):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(path)
        # macOS SDK sys/un.h：SOL_LOCAL=0，LOCAL_PEERPID=2。只认该连接的对端PID。
        self.pid = int.from_bytes(self.sock.getsockopt(0, 2, 4), sys.byteorder, signed=True)
        self.phase = phase or Path(path).name
        self.buf = b""
        self.inbox = {}
        self.pending = {}
        self.next_id = 1
        self.sampled_timeout = None
        self.memory_monitor = None

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, command, args=None, action=None):
        ident = self.next_id
        self.next_id += 1
        payload = json.dumps({"id": ident, "command": command, "args": args or {}}, ensure_ascii=False) + "\n"
        self.sock.sendall(payload.encode())
        self.pending[ident] = {"command": command, "phase": self.phase, "arguments": args or {},
                               "sentMonotonic": time.monotonic(), "action": action}
        return ident

    def _read_line(self, timeout):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buf:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("调试响应超时")
            self.sock.settimeout(max(remaining, 0.01))
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                raise TimeoutError("调试响应超时") from None
            if not chunk:
                raise ConnectionError("调试连接已关闭")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def wait(self, ident, timeout):
        ident = norm_id(ident)
        if self.memory_monitor is not None and self.pending.get(ident, {}).get("command") == "state":
            return self.memory_monitor.wait(self, ident, timeout=timeout)
        started = time.monotonic()
        deadline = time.monotonic() + timeout
        try:
            while True:
                if ident in self.inbox:
                    self.pending.pop(ident, None)
                    return self.inbox.pop(ident)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError(f"等待响应 {ident} 超时")
                message = self._read_line(remaining)
                self.inbox[norm_id(message.get("id"))] = message
        except TimeoutError:
            detail = {**self.pending.get(ident, {"command": "unknown", "phase": self.phase}),
                      "pid": self.pid, "requestID": ident, "timeoutSeconds": timeout,
                      "responseWaitSeconds": time.monotonic() - started}
            # 计时在采样前结束；保留进程现场后才交给调用方清理，不延长响应预算。
            # 仅在内存/滚动场景失败边界保留现场；NAS探针、退出及其余场景的计时不等采样。
            capture = detail["phase"].startswith(("memory-30min:", "scroll-cold:", "scroll-cached:"))
            if not capture or detail["command"] == "quit":
                detail["sample"] = None
                raise DebugTimeout(detail) from None
            if self.sampled_timeout is None:
                directory = ROOT / "build" / "acceptance" / "debug-timeouts"
                directory.mkdir(parents=True, exist_ok=True)
                sample = directory / f"{self.pid}-{os.getpid()}-{ident}.sample.txt"
                try:
                    result = subprocess.run(["/usr/bin/sample", str(self.pid), "1", "1", "-file", str(sample)],
                                            capture_output=True, text=True, timeout=8)
                    self.sampled_timeout = {"sample": str(sample), "sampleReturnCode": result.returncode,
                                            "sampleDiagnostic": (result.stderr or result.stdout)[-1000:]}
                except (subprocess.TimeoutExpired, OSError) as exc:
                    self.sampled_timeout = {"sample": str(sample), "sampleError": str(exc)}
            detail.update(self.sampled_timeout)
            (Path(detail["sample"]).with_suffix(".json")).write_text(json.dumps(detail, ensure_ascii=False, indent=2) + "\n")
            raise DebugTimeout(detail) from None

    def request(self, command, args=None, timeout=30, action=None):
        message = self.wait(self.send(command, args, action=action), timeout)
        if not message.get("ok", False):
            raise RuntimeError(message.get("error") or message)
        return message.get("result")


def launch_app(socket_path, support, cache, layout, log, app_sleep_disabled=False):
    binary = app_binary()
    temporary = Path(support).resolve().parent / "tmp"
    temporary.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/open", "-n", "-a", str(binary.parents[2]), "--stdout", str(log), "--stderr", str(log),
                    "--env", f"TMPDIR={temporary}/",
                    "--args", "-MVDebugSocket", str(socket_path), "-MVSupportDirectory", str(support),
                    "-MVCacheDirectory", str(cache), "-MVLayoutFile", str(layout)] +
                   (["-NSAppSleepDisabled", "YES"] if app_sleep_disabled else []), check=True)
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        lines = subprocess.check_output(["/bin/ps", "-axo", "pid=,command="], text=True).splitlines()
        pids = [int(line.split(None, 1)[0]) for line in lines if line.split(None, 1)[1].startswith(str(binary) + " ")
                and re.search(r"(?:^|\s)-MVDebugSocket " + re.escape(str(socket_path)) + r"(?:\s|$)", line)]
        if len(pids) == 1:
            return pids[0]
        if len(pids) > 1:
            raise RuntimeError(f"隔离路径匹配多个 PID：{pids}")
        time.sleep(0.05)
    raise TimeoutError(f"没有找到隔离实例 PID：{socket_path}，日志 {log}")


class App:
    live = []

    def __init__(self, name, prefetch_zero=False, empty_cache=True, prefetch=None, app_sleep_disabled=False):
        self.name = name
        self.prefetch_zero = prefetch_zero
        self.empty_cache = empty_cache
        self.prefetch = prefetch
        self.app_sleep_disabled = app_sleep_disabled
        self.root = ROOT / "build" / "acceptance" / f"{name}-{os.getpid()}"
        self.support = self.root / "support"
        self.cache = self.root / "cache"
        self.layout = self.root / "layout.json"
        self.socket = str(ROOT / "build" / f"s-{os.getpid()}-{len(App.live)}.sock")
        self.pid = None
        self.exit_watch = None
        self.exit_code = None
        self.client = None
        self.quit_exited_normally = False

    def start(self):
        # 全部是该场景在工作区生成的私有状态。冷场景重新初始化，重启场景保留设置与缓存。
        if self.empty_cache:
            if self.support.exists():
                shutil.rmtree(self.support)
            self.layout.unlink(missing_ok=True)
        self.support.mkdir(parents=True, exist_ok=True)
        # 明确的 open 必须是第一次打开，不能由上次测试的窗口恢复提前填满缓存。
        (self.support / "session.json").unlink(missing_ok=True)
        if self.empty_cache and self.cache.exists():
            shutil.rmtree(self.cache)
        self.cache.mkdir(parents=True, exist_ok=True)
        self.layout.parent.mkdir(parents=True, exist_ok=True)
        prefetch = self.prefetch
        if self.prefetch_zero:
            prefetch = {"viewerDecodeFrames": 0, "viewerReadAheadPages": 0,
                        "currentBookPages": False, "neighborBooks": 0, "shelfCovers": False}
        if prefetch is not None:
            document = {"version": 1, "value": {"prefetch": prefetch}}
            (self.support / "settings.json").write_text(json.dumps(document) + "\n")
        socket_path = Path(self.socket)
        if socket_path.exists():
            socket_path.unlink()
        self.pid = launch_app(self.socket, self.support, self.cache, self.layout, self.root / "app.log",
                              app_sleep_disabled=self.app_sleep_disabled)
        App.live.append(self)
        self.exit_watch = select.kqueue()
        # SDK sys/event.h：NOTE_EXITSTATUS 对可发送信号的非子进程也有效，data 是 wait(2) 状态。
        self.exit_watch.control([select.kevent(self.pid, filter=select.KQ_FILTER_PROC, flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                               fflags=select.KQ_NOTE_EXIT | 0x04000000)], 0)
        self.client = self._connect()
        self.client.request("state", timeout=20)
        return self

    def _connect(self):
        deadline = time.monotonic() + 30
        last = "套接字没有出现"
        while time.monotonic() < deadline:
            if self.wait_exit(0):
                raise RuntimeError(f"App 已退出，code={self.exit_code}，日志 {self.root / 'app.log'}")
            try:
                client = DebugClient(self.socket, phase=self.name + ":startup")
                if client.pid != self.pid:
                    client.close()
                    raise RuntimeError("套接字 PID 与隔离路径 PID 不一致")
                return client
            except (FileNotFoundError, ConnectionRefusedError, OSError) as exc:
                last = str(exc)
                time.sleep(0.05)
        raise TimeoutError(last)

    def stop(self):
        quit_seconds = None
        if self.client is not None and self.pid is not None and not self.wait_exit(0):
            started = time.monotonic()
            try:
                self.client.request("quit", timeout=2)
            except (RuntimeError, TimeoutError, ConnectionError, OSError):
                pass
            self.quit_exited_normally = self.wait_exit(max(0.001, 3 - (time.monotonic() - started))) and self.exit_code == 0
            quit_seconds = time.monotonic() - started
        self.kill()
        if self.client is not None:
            self.client.close()
            self.client = None
        Path(self.socket).unlink(missing_ok=True)
        return quit_seconds

    def wait_exit(self, timeout):
        if self.exit_code is None and self.exit_watch is not None:
            events = self.exit_watch.control([], 1, timeout)
            if events:
                self.exit_code = os.waitstatus_to_exitcode(events[0].data)
                self.exit_watch.close()
                self.exit_watch = None
        return self.exit_code is not None

    def kill(self):
        if self.pid is None or self.wait_exit(0):
            return
        os.kill(self.pid, 15)
        if not self.wait_exit(2):
            os.kill(self.pid, 9)
            self.wait_exit(2)


def stop_live():
    for app in list(App.live):
        try:
            app.kill()
        except OSError:
            pass


def app_binary():
    if APP_BINARY.exists():
        return APP_BINARY
    build_app()
    if not APP_BINARY.exists():
        raise RuntimeError(f"找不到 App：{APP_BINARY}")
    return APP_BINARY


def build_app():
    subprocess.run(["xcodegen", "generate", "--quiet"], cwd=ROOT, check=True)
    arch = subprocess.check_output(["uname", "-m"], text=True).strip()
    subprocess.run(
        ["xcodebuild", "-quiet", "-project", str(ROOT / "MacView.xcodeproj"), "-scheme", "MacView", "-configuration", "Debug",
         "-destination", f"platform=macOS,arch={arch}", "-derivedDataPath", str(DERIVED),
         "SWIFT_OPTIMIZATION_LEVEL=-O", "build"],
        cwd=ROOT, check=True,
    )


def mvbench_binary():
    binary = ROOT / "Packages" / "MacViewKit" / ".build" / "release" / "mvbench"
    if not binary.exists():
        subprocess.run(
            ["swift", "build", "--package-path", str(ROOT / "Packages/MacViewKit"), "-c", "release", "--product", "mvbench"],
            cwd=ROOT, check=True,
        )
    return binary


def mvbench_env(paths):
    try:
        result = subprocess.run(
            [str(mvbench_binary()), "env", "--host", NFS_HOST] + sum([["--path", path] for path in paths], []),
            cwd=ROOT, check=True, capture_output=True, text=True,
        )
        return json.loads(result.stdout)
    except (subprocess.CalledProcessError, json.JSONDecodeError, OSError) as exc:
        return {"mvbenchError": str(exc)}


def ensure_sample():
    if not SAMPLE_TARGET.is_dir():
        raise FileNotFoundError(f"样本目录不存在：{SAMPLE_TARGET}")
    if SAMPLE_LINK.is_symlink():
        if SAMPLE_LINK.resolve() != SAMPLE_TARGET.resolve():
            raise FileNotFoundError(f"样本链接指向其他目录，保留现状：{SAMPLE_LINK}")
    elif not SAMPLE_LINK.exists():
        SAMPLE_LINK.parent.mkdir(parents=True, exist_ok=True)
        SAMPLE_LINK.symlink_to(SAMPLE_TARGET)
    return SAMPLE_LINK


def state_window_front(state):
    windows = (state or {}).get("windows") or []
    return windows[0].get("windowFront") if windows else None


def window_of(state):
    windows = state.get("windows") or []
    if not windows:
        raise RuntimeError("没有窗口")
    return windows[0]


def hide_docks(client):
    if window_of(client.request("state")).get("docksVisible"):
        client.request("perform", {"command": "panel.docks.toggle"})


def wait_exact(client, page, timeout=20, prime=False):
    """初始页只等真实图层就绪；计时页必须取得 lastDisplay。"""
    deadline = time.monotonic() + timeout
    state = None
    while time.monotonic() < deadline:
        try:
            state = client.request("state", timeout=5)
        except TimeoutError as exc:
            exc.measured = {"lastState": state, "expectedPage": page}
            raise
        window = window_of(state)
        if prime and int(window.get("page", -1)) == int(page) and any(
                slot.get("page") == int(page) and slot.get("quality") == "exact" and slot.get("hasImage") is True
                for slot in window.get("pageSlots", [])):
            return None
        display = window.get("lastDisplay")
        if not prime and display and int(display.get("page", -1)) == int(page) and display.get("quality") == "exact":
            return float(display["milliseconds"])
        time.sleep(0.01)
    raise MeasurementError(f"第 {page} 页没有 exact 显示", {"lastState": state, "expectedPage": page})


def wait_frame(client, frame, timeout=20):
    """翻页后的 exact 显示。页码和帧号在单页模式下相同，这里以当前帧对准。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        window = window_of(client.request("state", timeout=5))
        display = window.get("lastDisplay")
        if int(window.get("frame", -1)) == int(frame) and display and display.get("quality") == "exact" and int(display.get("page", -1)) == int(window.get("page", -2)):
            return float(display["milliseconds"])
        time.sleep(0.01)
    raise TimeoutError(f"第 {frame} 帧没有 exact 显示")


def wait_idle(client, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if window_of(client.request("state")).get("prefetchIdle"):
            return
        time.sleep(0.05)
    raise TimeoutError("预取没有在限时内结束")


def wait_prefetch_idle(client, timeout=60):
    """翻页前等到这一会话的预取全部落地。"""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if int(window_of(client.request("state")).get("prefetchInFlightCount") or 0) == 0:
            return
        time.sleep(0.01)
    raise TimeoutError("翻页前预取没有结束")


def distinct_pages(count, samples):
    if count <= 0:
        return []
    if count <= samples:
        return list(range(count))
    chosen = []
    for index in range(samples):
        page = round(index * (count - 1) / (samples - 1))
        if page not in chosen:
            chosen.append(page)
    cursor = 0
    while len(chosen) < samples and cursor < count:
        if cursor not in chosen:
            chosen.append(cursor)
        cursor += 1
    return chosen


def scene_first_image():
    path = str(ensure_sample())
    app = App("first-image", prefetch_zero=True, empty_cache=True).start()
    admission = None
    try:
        hide_docks(app.client)
        opened = app.client.request("open", {"path": path, "page": 0}, timeout=120)
        count = int(opened["frameCount"])
        wait_exact(app.client, 0, prime=True)
        state = app.client.request("state")
        initial = {"memory": state.get("memory"), "hudVisible": window_of(state).get("hudVisible")}
        if (initial["memory"] or {}).get("preloadBytes") != 0 or initial["hudVisible"] is not False:
            return {"unavailable": True, "reason": "首图冷样本前提不满足：初始预载须为 0 且 HUD 隐藏", "initialState": initial}
        # 初始第0页已访问，30次计时只选择其余不同页。
        pages = [page + 1 for page in distinct_pages(count - 1, 30)]
        admission = admit_measurement("first-image")
        samples = []
        for page in pages:
            app.client.request("open", {"path": path, "page": page}, timeout=120)
            samples.append(wait_exact(app.client, page))
        state = app.client.request("state")
        final = {"memory": state.get("memory"), "hudVisible": window_of(state).get("hudVisible")}
        return {"samples": len(samples), "p95": p95(samples), "milliseconds": samples, "pages": pages,
                "frameCount": count, "prefetchDisabled": True, "panelsHidden": True,
                "initialState": initial, "finalState": final, "admission": admission}
    except Exception as exc:
        if admission:
            exc.measured = {**getattr(exc, "measured", {}), "admission": admission}
        raise
    finally:
        app.stop()


def scene_preloaded_flip():
    path = str(ensure_sample())
    app = App("preloaded-flip", empty_cache=True).start()
    admission = None
    try:
        app.client.request("open", {"path": path}, timeout=120)
        wait_idle(app.client, 180)
        admission = admit_measurement("preloaded-flip")
        samples = []
        direction = 1
        for _ in range(100):
            current = window_of(app.client.request("state"))
            frame = int(current["frame"])
            count = int(current["frameCount"])
            if count < 2:
                raise RuntimeError("页数不足，无法来回翻")
            if direction > 0 and frame >= count - 1:
                direction = -1
            elif direction < 0 and frame <= 0:
                direction = 1
            command = "frame.next" if direction > 0 else "frame.previous"
            wait_prefetch_idle(app.client)
            app.client.request("perform", {"command": command})
            samples.append(wait_frame(app.client, frame + direction))
        return {"flips": len(samples), "p95": p95(samples), "milliseconds": samples, "admission": admission}
    except Exception as exc:
        if admission:
            exc.measured = {**getattr(exc, "measured", {}), "admission": admission}
        raise
    finally:
        app.stop()


def record_scroll(scene):
    global WAIT_EXHAUSTED
    out = ROOT / "build" / "acceptance" / f"{scene}-record"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    trace = out / "record.trace"
    measured = {}
    try:
        subprocess.run([str(ROOT / "scripts/acceptance/record-trackpad.sh"), scene, str(out), "--automatic"], cwd=ROOT, check=True,
                       env={**os.environ, "MV_ACCEPTANCE_WAIT_EXHAUSTED": "1" if WAIT_EXHAUSTED else "0"})
        measured, during = scroll_summary(out)
        profile = json.loads((out / "main-thread.json").read_text()) if scene == "scroll-cold" else None
        return measured, during, profile
    except Exception as exc:
        measured.update(json.loads((out / "error.json").read_text()) if (out / "error.json").exists() else {})
        prepared = json.loads((out / "window-before.json").read_text().strip() or "{}") if (out / "window-before.json").exists() else {}
        if prepared.get("admission"):
            measured["admission"] = prepared["admission"]
        if prepared.get("ready") is False:
            measured.update(environment=True, reason="环境准入等待已耗尽", admission=prepared.get("admission"))
            return measured, {"admission": prepared.get("admission")}, None
        failure = MeasurementError(str(exc), measured)
        if (out / "during.json").exists():
            failure.during = json.loads((out / "during.json").read_text())
        raise failure from exc
    finally:
        prepared = json.loads((out / "window-before.json").read_text().strip() or "{}") if (out / "window-before.json").exists() else {}
        WAIT_EXHAUSTED = WAIT_EXHAUSTED or bool(prepared.get("waitExhausted"))
        raw = json.loads((out / "raw-files.json").read_text()) if (out / "raw-files.json").exists() else {}
        measured["recording"] = raw
        if raw.get("ready") is False:
            measured.update(environment=True, reason=raw.get("reason"))
        # 帧时间和主线程汇总已经写进文件。自动验收的 trace 不留存，用户录制脚本仍保留。
        if trace.exists():
            shutil.rmtree(trace)
        raw.update(trace=str(trace), traceDeleted=not trace.exists())
        (out / "raw-files.json").write_text(json.dumps(raw, ensure_ascii=False, indent=2) + "\n")


def scroll_summary(out):
    summary = json.loads((out / "hitches.json").read_text())
    phases = summary.get("phases") or []
    if not phases:
        raise RuntimeError("帧时间汇总没有阶段")
    during = json.loads((out / "during.json").read_text()) if (out / "during.json").exists() else {}
    phase = phases[0]
    measured = {
        "frames": phase.get("frames"),
        "hitches": phase.get("hitches"),
        "hitchMilliseconds": phase.get("hitchMilliseconds"),
        "hitchRatioMsPerSecond": phase.get("hitchRatioMsPerSecond"),
        "updateP99": phase.get("updateP99"),
        "renderP99": phase.get("renderP99"),
        "frameTimeP99": phase.get("frameTimeP99"),
        "frameTimeMax": phase.get("frameTimeMax"),
        "refreshHz": during.get("refreshHz"),
        "settleRequestLatencyP99": phase.get("settleRequestLatencyP99"),
        "settles": phase.get("settles"),
        "trace": str(out / "record.trace"),
        "scrollMovements": during.get("scrollMovements"),
        "scrollEvents": during.get("scrollEvents"),
        "events": during.get("events"),
        "eventsPerSecond": during.get("eventsPerSecond"),
        "scrollSegments": during.get("scrollSegments"),
        "durationSeconds": during.get("durationSeconds"),
        "gestureSeconds": during.get("gestureSeconds"),
        "residentPeakBytes": during.get("residentPeakBytes"),
        "residentSamplingError": during.get("residentSamplingError"),
        "residentSampleCount": during.get("residentSampleCount"),
        "residentSamplingComplete": during.get("residentSamplingComplete"),
        "windowFrontBefore": during.get("windowFrontBefore"),
        "submitPlusRenderP99": None if phase.get("updateP99") is None or phase.get("renderP99") is None else phase["updateP99"] + phase["renderP99"],
        "frameTimeExceeds120HzBudget": phase.get("frameTimeP99") is not None and exceeds(phase["frameTimeP99"], SCROLL_FRAME_MS),
    }
    if "windowFront" in during:
        measured["windowFront"] = during["windowFront"]
    if "responsiveScrolling" in during:
        measured["responsiveScrolling"] = during["responsiveScrolling"]
    return measured, during


COLD = {}


def cold_recording():
    if "error" in COLD:
        raise COLD["error"]
    if "measured" not in COLD:
        try:
            COLD["measured"], COLD["during"], COLD["mainThread"] = record_scroll("scroll-cold")
        except Exception as exc:
            COLD["error"] = exc
            raise
    return COLD


def scene_scroll_cached():
    measured, during, _ = record_scroll("scroll-cached")
    return measured, during


def scene_scroll_cold():
    data = cold_recording()
    return data["measured"], data["during"]


def scene_main_thread():
    data = cold_recording()
    return {**(data["mainThread"] or {}), "frames": data["measured"].get("frames"),
            "scrollSegments": data["measured"].get("scrollSegments"),
            "events": data["measured"].get("events"), "gestureSeconds": data["measured"].get("gestureSeconds"),
            "eventsPerSecond": data["measured"].get("eventsPerSecond"),
            "environment": data["measured"].get("environment", False),
            "recording": data["measured"].get("recording")}, data["during"]


def scene_settle():
    measured, during, _ = record_scroll("settle")
    return {"settleRequestLatencyP99": measured.get("settleRequestLatencyP99"), "settles": measured.get("settles"),
            "scrollMovements": measured.get("scrollMovements"),
            "windowFront": measured.get("windowFront"), "environment": measured.get("environment", False),
            "scrollBursts": during.get("scrollBursts"), "durationSeconds": during.get("durationSeconds"),
            "recording": measured.get("recording")}, during


def trace_cell(element, ids):
    """还原 id/ref。显示文本是 fmt、符号名和子节点；原值是文本或地址。"""
    if "ref" in element.attrib:
        return ids.get(element.attrib["ref"], ("", None))
    displays = []
    fmt = element.attrib.get("fmt")
    name = element.attrib.get("name")
    if fmt:
        displays.append(fmt)
    if name and name != fmt:
        displays.append(name)
    raw = (element.text or "").strip() or element.attrib.get("addr")
    if raw and raw not in displays:
        displays.append(raw)
    for child in list(element):
        child_display, _ = trace_cell(child, ids)
        if child_display:
            displays.append(child_display)
    result = (" ".join(displays), raw)
    if "id" in element.attrib and element.attrib["id"] not in ids:
        ids[element.attrib["id"]] = result
    return result


def main_thread_samples(trace):
    try:
        toc = subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--toc"], check=True, capture_output=True).stdout
    except subprocess.CalledProcessError as exc:
        return {"mainThreadSamples": None, "knownSymbolSamples": None, "fileReadOrImageIO": None, "error": exc.stderr.decode(errors="replace")[-500:], "unavailable": True}
    schemas = re.findall(r'schema="([^"]+)"', toc.decode(errors="replace"))
    if "time-profile" in schemas:
        chosen = ["time-profile"]
    else:
        chosen = [schema for schema in schemas if re.search(r"time-profile|time-sample|sample", schema, re.I) and "signpost" not in schema and "hitch" not in schema]
    if not chosen:
        return {"mainThreadSamples": None, "knownSymbolSamples": None, "fileReadOrImageIO": None, "schemas": schemas, "unavailable": True}
    used = None
    main = known = io_count = other_io = 0
    examples = []
    other_examples = []
    for schema in chosen:
        xpath = f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'
        try:
            data = subprocess.run(["xcrun", "xctrace", "export", "--input", str(trace), "--xpath", xpath], check=True, capture_output=True).stdout
        except subprocess.CalledProcessError:
            continue
        try:
            root = ET.fromstring(data)
        except ET.ParseError:
            continue
        node = root.find("node")
        rows = [] if node is None else node.findall("row")
        columns = [] if node is None else [column.findtext("mnemonic") for column in node.findall("schema/col")]
        if not rows or "thread" not in columns or "stack" not in columns:
            continue
        used = schema
        ids = {}
        for row in rows:
            values = dict(zip(columns, [trace_cell(element, ids)[0] for element in list(row)]))
            thread = values.get("thread", "")
            if "Main Thread" not in thread and "com.apple.main-thread" not in thread:
                continue
            text = values.get("stack", "")
            main += 1
            if "CFRunLoop" in text or "NSApplication" in text:
                known += 1
            if IO_RE.search(text):
                io_count += 1
                if len(examples) < 5:
                    examples.append(re.sub(r"\s+", " ", text)[:1500])
            if OTHER_IO_RE.search(text):
                other_io += 1
                if len(other_examples) < 5:
                    other_examples.append(re.sub(r"\s+", " ", text)[:1500])
        break
    if used is None:
        return {"mainThreadSamples": None, "knownSymbolSamples": None, "fileReadOrImageIO": None, "schemas": schemas, "unavailable": True}
    return {
        "mainThreadSamples": main,
        "knownSymbolSamples": known,
        "fileReadOrImageIO": io_count,
        "schema": used,
        "tableSamples": len(rows),
        "examples": examples,
        "otherMainThreadFileOperations": other_io,
        "otherFileOperationExamples": other_examples,
    }


def run_json(command, output):
    result = subprocess.run(command, cwd=ROOT, check=False, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip() or f"退出 {result.returncode}")
    return json.loads(Path(output).read_text())


def mount_fstype(path):
    target = str(path)
    listed = subprocess.run(["mount"], capture_output=True, text=True).stdout
    for line in listed.splitlines():
        marker = f" on {target} ("
        if marker in line:
            return line.split("(", 1)[1].split(",", 1)[0].strip()
    return None


def ensure_nfs():
    fstype = mount_fstype(NFS_MOUNT)
    if fstype == "nfs":
        return NFS_MOUNT, None
    if fstype:
        return None, f"{NFS_MOUNT} 已挂载为 {fstype}"
    if NFS_MOUNT.exists() and any(NFS_MOUNT.iterdir()):
        return None, f"{NFS_MOUNT} 非空且未挂载"
    if not NFS_MOUNT.is_dir():
        return None, f"授权挂载目录不存在，未在家目录新建：{NFS_MOUNT}"
    result = subprocess.run(
        ["mount_nfs", "-o", "ro,vers=3,tcp,port=2049", f"{NFS_HOST}:{NFS_EXPORT}", str(NFS_MOUNT)],
        stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30,
    )
    if result.returncode != 0:
        return None, (result.stderr or result.stdout or "mount_nfs 失败").strip()
    return NFS_MOUNT, None


def find_samples(root):
    album = archive = None
    started = time.monotonic()
    seen = 0
    bases = [root / "Picture" / "YY" / "秀人", root / "Picture", root]
    for base in bases:
        if not base.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            seen += 1
            if seen > 400 or time.monotonic() - started > 20:
                return album, archive
            dirnames[:] = [name for name in dirnames if not name.startswith(".")][:40]
            images = [name for name in filenames if name.lower().endswith((".jpg", ".jpeg"))]
            archives = [name for name in filenames if name.lower().endswith(".gz")]
            if album is None and len(images) >= 8:
                album = dirpath
            if archive is None and archives:
                archive = str(Path(dirpath) / archives[0])
            if album and archive:
                return album, archive
    return album, archive


def throughput(directory):
    output = ROOT / "build" / "acceptance" / "throughput.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    work = ROOT / "build" / "acceptance" / "nas-work"
    report = run_json(
        [str(mvbench_binary()), "pipeline", "--throughput", "--dir", directory, "--limit", "1",
         "--work-directory", str(work), "--output", str(output)],
        output,
    )
    return report.get("thumbnailToRawRatio"), report


def scene_nas_throughput():
    measured = {"protocol": "nfs", "c1_10": dict(C1_10_UNVERIFIED)}
    mount, error = ensure_nfs()
    album = None
    if mount:
        album, _ = find_samples(mount)
    if not mount or not album:
        measured["unavailable"] = True
        measured["nfsError"] = error or "NFS 上没有找到 JPEG 目录"
        smb_album = find_samples(SMB_ROOT)[0] if SMB_ROOT.is_dir() else None
        measured["supplement"] = {"protocol": "smb", "path": str(SMB_ROOT), "c1_10": dict(C1_10_UNVERIFIED)}
        if smb_album:
            try:
                ratio, _ = throughput(smb_album)
                measured["supplement"].update(album=smb_album, thumbnailToRawRatio=ratio)
            except (RuntimeError, OSError, json.JSONDecodeError) as exc:
                measured["supplement"]["error"] = str(exc)
        else:
            measured["supplement"]["error"] = "没有找到 /Volumes/Picture 上的 JPEG 目录"
        return measured
    ratio, report = throughput(album)
    measured.update(album=album, thumbnailToRawRatio=ratio, samples=len(report.get("throughput") or []), throughput=report.get("throughput"))
    return measured


def parse_network_tcc(output, pid):
    lines = output.splitlines()
    def request_id(line):
        match = re.search(r"msgID=([^,\s]+)", line)
        return match[1] if match else None
    network = {request_id(line) for line in lines if "AUTHREQ_CTX:" in line and "kTCCServiceSystemPolicyNetworkVolumes" in line}
    own = {request_id(line) for line in lines if "AUTHREQ_ATTRIBUTION:" in line
           and "identifier=io.github.ump45nose.MacView," in line and f"pid={pid}," in line}
    requests = [line for line in lines if request_id(line) in network & own]
    prompting = [line for line in requests if "AUTHREQ_PROMPTING:" in line]
    result = [line for line in requests if "AUTHREQ_RESULT:" in line]
    decisions = {request_id(line) for line in requests if "AUTHREQ_CTX:" in line and "preflight=no" in line}
    decisions.update(request_id(line) for line in prompting)
    return {"prompting": prompting, "result": result, "requests": requests,
            "denied": any(request_id(line) in decisions and re.search(r"authValue=0(?:,|\s)", line) for line in result)}


def network_tcc_logs(started, pid):
    start = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(started - 1))
    try:
        logged = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--start", start, "--info", "--debug",
                                 "--predicate", 'process == "tccd" AND eventMessage CONTAINS "AUTHREQ_"'],
                                capture_output=True, text=True, timeout=15)
        report = parse_network_tcc(logged.stdout, pid)
        report.update(returnCode=logged.returncode, diagnostic=logged.stderr.strip())
        return report
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {"prompting": [], "result": [], "requests": [], "denied": False, "error": str(exc)}


NAS_ACCESS = {}


def preflight_nas_access(directory):
    """同一签名只预检一次；授权等待不占用性能计时，也不替用户处理弹窗。"""
    binary = app_binary()
    signed = subprocess.run(["/usr/bin/codesign", "-d", "--verbose=4", str(binary.parents[2])], capture_output=True, text=True)
    cdhash = re.search(r"^CDHash=(.+)$", signed.stderr, re.M)
    signature = {"binary": str(binary), "cdhash": cdhash[1] if cdhash else None,
                 "returnCode": signed.returncode, "details": signed.stderr}
    key = (binary.stat().st_mtime_ns, signature["cdhash"])
    if key in NAS_ACCESS:
        return NAS_ACCESS[key]
    started_wall, started = time.time(), time.monotonic()
    evidence = {"ready": False, "directory": str(directory), "signature": signature, "timeoutSeconds": WAIT_READY}
    app = App("nas-authorization", prefetch_zero=True, empty_cache=True)
    open_id, state_id = None, None
    next_open = next_logs = 0
    notified = False
    errors = []
    try:
        app.start()
        evidence["pid"] = app.pid
        while time.monotonic() - started < WAIT_READY:
            now = time.monotonic()
            if now >= next_logs:
                evidence["tccd"] = network_tcc_logs(started_wall, app.pid)
                next_logs = time.monotonic() + 5
                if evidence["tccd"]["prompting"] and not notified:
                    print("网络卷权限弹窗已出现，等待用户答复（最多20分钟）。", flush=True)
                    notified = True
                if evidence["tccd"]["denied"]:
                    evidence["reason"] = "用户拒绝网络卷访问授权"
                    break
            if open_id is None and now >= next_open:
                open_id = app.client.send("open", {"path": str(directory)})
            if state_id is None:
                state_id = app.client.send("state")
            try:
                message = app.client.wait(state_id, min(1, max(0.01, WAIT_READY - (time.monotonic() - started))))
                state_id = None
                window = window_of(message.get("result") or {})
                if message.get("ok") and int(window.get("itemCount") or 0) > 0:
                    evidence.update(ready=True, itemCount=window["itemCount"])
                    break
            except TimeoutError:
                pass
            if open_id in app.client.inbox:
                message = app.client.inbox.pop(open_id)
                app.client.pending.pop(open_id, None)
                if not message.get("ok"):
                    errors.append(message.get("error"))
                open_id = None
                next_open = time.monotonic() + 2
            time.sleep(0.25)
        if not evidence["ready"]:
            evidence.setdefault("reason", "网络卷授权预检在20分钟内没有读出条目")
    except (RuntimeError, TimeoutError, ConnectionError, OSError) as exc:
        evidence["reason"] = str(exc)
    finally:
        app.stop()
        evidence.update(waitSeconds=time.monotonic() - started, openErrors=errors)
        if app.pid is not None:
            evidence["tccd"] = network_tcc_logs(started_wall, app.pid)
    NAS_ACCESS[key] = evidence
    return evidence


def wait_first_screen(client, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = window_of(client.request("state")).get("firstScreenThumbnailMilliseconds")
        if isinstance(value, (int, float)):
            return float(value)
        time.sleep(0.02)
    return None


def first_screen_samples(path, name, times=20):
    result = {"path": path, "admission": None, "ready": None, "waitExhausted": WAIT_EXHAUSTED,
              "samples": [], "measurements": [], "count": 0, "p95": None}
    samples, measurements = result["samples"], result["measurements"]
    mark, load = None, None
    phase = "prepareStart"
    try:
        app = App(name, empty_cache=True)
        try:
            app.start()
            phase = "prepareOpen"
            app.client.request("open", {"path": path}, timeout=180)
            wait_first_screen(app.client)
            wait_idle(app.client, 180)
        finally:
            app.stop()
        phase = "admission"
        admission, ready = wait_ready("cached-first-screen")
        result.update(admission=admission, ready=ready, waitExhausted=WAIT_EXHAUSTED)
        if not ready:
            return result
        mark = input_mark(DURING_EVENTS)
        result["admission"] = {**admission, "inputMark": mark}
        for _ in range(times):
            phase, load = "start", None
            app = App(name, empty_cache=False)
            try:
                app.start()
                load = os.getloadavg()[0]
                phase = "open"
                app.client.request("open", {"path": path}, timeout=180)
                phase = "firstScreen"
                value = wait_first_screen(app.client)
                samples.append(value)
                measurements.append({"milliseconds": value, "load": {"oneMinute": load}})
            finally:
                app.stop()
    except Exception as exc:
        result.update(unavailable=True, error=str(exc), failure={
            "phase": phase, "sampleIndex": len(samples) if mark is not None else None,
            "load": {"oneMinute": load},
        })
        if isinstance(exc, DebugTimeout):
            result["diagnostic"] = exc.detail
    numeric = [value for value in samples if value is not None]
    result.update(count=len(numeric), p95=p95(numeric) if len(numeric) == times else None)
    if mark is not None:
        result["during"] = sampled_during(mark)
    return result


def first_screen_root_evidence(result):
    return {key: result[key] for key in ("path", "admission", "ready", "waitExhausted", "during",
                                         "unavailable", "error", "failure", "diagnostic") if key in result}


def scene_cached_first_screen():
    local = first_screen_samples(str(ensure_sample()), "cached-first-screen-local")
    measured = {"localP95": local["p95"], "localSamples": local["count"], "localMilliseconds": local["samples"],
                "localMeasurements": local["measurements"], "protocol": "nfs",
                "rootAdmissions": [first_screen_root_evidence(local)], "admission": local["admission"],
                "measurementInputDuringRun": bool((local.get("during") or {}).get("screen", {}).get("inputDuringRun"))}
    if local["ready"] is False:
        return {**measured, "environment": True, "reason": "本地根冷填充退出后环境准入等待已耗尽"}
    if local.get("unavailable"):
        return {**measured, "unavailable": True, "error": local["error"]}
    mount, error = ensure_nfs()
    album = find_samples(mount)[0] if mount else None
    if not mount or not album:
        measured["unavailable"] = True
        measured["nfsError"] = error or "NFS 上没有找到 JPEG 目录"
        smb_album = find_samples(SMB_ROOT)[0] if SMB_ROOT.is_dir() else None
        supplement = {"protocol": "smb"}
        if smb_album:
            smb = first_screen_samples(smb_album, "cached-first-screen-smb")
            supplement.update(p95=smb["p95"], samples=smb["count"], path=smb_album,
                              measurements=smb["measurements"], admission=smb["admission"], ready=smb["ready"], during=smb.get("during"))
            measured["rootAdmissions"].append(first_screen_root_evidence(smb))
            if smb.get("admission"):
                measured["admission"] = smb["admission"]
            measured["measurementInputDuringRun"] |= bool((smb.get("during") or {}).get("screen", {}).get("inputDuringRun"))
            if smb.get("unavailable"):
                supplement.update(unavailable=True, error=smb["error"], failure=smb["failure"])
            if smb["ready"] is False:
                measured.update(environment=True, reason="SMB 根冷填充退出后环境准入等待已耗尽")
        else:
            supplement["error"] = "没有找到 /Volumes/Picture 上的 JPEG 目录"
        measured["supplement"] = supplement
        return measured
    remote = first_screen_samples(album, "cached-first-screen-nfs")
    measured.update(nfsP95=remote["p95"], nfsSamples=remote["count"], nfsMilliseconds=remote["samples"], nfsAlbum=album,
                    nfsMeasurements=remote["measurements"])
    if remote.get("admission"):
        measured["admission"] = remote["admission"]
    measured["rootAdmissions"].append(first_screen_root_evidence(remote))
    measured["measurementInputDuringRun"] |= bool((remote.get("during") or {}).get("screen", {}).get("inputDuringRun"))
    if remote.get("unavailable"):
        measured.update(unavailable=True, error=remote["error"])
    if remote["ready"] is False:
        measured.update(environment=True, reason="NFS 根冷填充退出后环境准入等待已耗尽")
    return measured


def scene_large_dir():
    if not TREE.is_dir():
        return {"unavailable": True, "error": f"没有目录 {TREE}"}
    app = App("large-dir", empty_cache=True).start()
    admission = None
    try:
        client = app.client
        admission = admit_measurement("large-dir")
        open_id = client.send("open", {"path": str(TREE)})
        counts = []
        rtts = []
        opened = None
        last_change = time.monotonic()
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            started = time.monotonic()
            state_id = client.send("state")
            window = None
            try:
                message = client.wait(state_id, 1.0)
                if message.get("ok"):
                    window = window_of(message["result"])
            except TimeoutError:
                pass
            rtts.append((time.monotonic() - started) * 1000)
            if open_id in client.inbox:
                opened = client.inbox.pop(open_id)
            if window is not None:
                count = int(window.get("itemCount") or 0)
                if not counts or counts[-1] != count:
                    counts.append(count)
                    last_change = time.monotonic()
            if opened is not None and time.monotonic() - last_change > 1 and counts:
                break
            elapsed = time.monotonic() - started
            if elapsed < 0.05:
                time.sleep(0.05 - elapsed)
        transitions = sum(1 for previous, current in zip(counts, counts[1:]) if previous != current)
        return {
            "stateSamples": len(rtts),
            "maxRoundTripMilliseconds": max(rtts) if rtts else None,
            "itemCountChanges": transitions,
            "itemCounts": counts,
            "intermediateItemCounts": [count for count in counts if 0 < count < BUDGETS["large-dir"]["totalItems"]],
            "openOk": bool(opened and opened.get("ok")),
            "admission": admission,
        }
    except Exception as exc:
        if admission:
            exc.measured = {**getattr(exc, "measured", {}), "admission": admission}
        raise
    finally:
        app.stop()


def control_send(port, command):
    with socket.create_connection(("127.0.0.1", int(port)), timeout=5) as sock:
        sock.sendall((command + "\n").encode())
        sock.settimeout(5)
        data = b""
        while b"\n" not in data:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    return json.loads(data.decode().splitlines()[0])


def fault_volumes(state):
    book = window_of(state).get("book") or ""
    return [{key: volume.get(key) for key in ("root", "state", "inFlight", "stuck")}
            for volume in state.get("volumes") or []
            if (root := volume.get("root")) and root != "/" and book.startswith(root)]


def volume_failed(state):
    return bool(window_of(state).get("loadError")) or any(volume.get("state") != "healthy" for volume in fault_volumes(state))


def volume_in_flight(state):
    return any(int(volume.get("inFlight") or 0) > 0 for volume in fault_volumes(state))


def arm_fault_read(client):
    """代理已停止转发后，再翻到未读过的下一页。关闭面板与预取，避免缩略图提前读完整页。"""
    window = window_of(client.request("state", timeout=2))
    frame = int(window.get("frame") or 0)
    count = int(window.get("frameCount") or 0)
    if frame + 1 >= count:
        raise RuntimeError("没有尚未访问的下一页，无法证明故障期间发生真实读取")
    client.request("perform", {"command": "frame.next"}, timeout=2)
    return frame + 1


def recover_fault(client, frame, timeout=30):
    deadline = time.monotonic() + timeout
    client.request("perform", {"command": "item.retryFailed"}, timeout=2)
    while time.monotonic() < deadline:
        state = client.request("state", timeout=2)
        window = window_of(state)
        display = window.get("lastDisplay") or {}
        if not volume_failed(state) and window.get("frame") == frame and display.get("page") == window.get("page") and display.get("quality") == "exact":
            return True
        if window.get("loadError"):
            client.request("perform", {"command": "item.retryFailed"}, timeout=2)
        time.sleep(0.05)
    return False


def scene_nas_fault():
    mount, error = ensure_nfs()
    album = find_samples(mount)[0] if mount else None
    if not mount or not album:
        supplement = {"protocol": "smb"}
        if SMB_ROOT.is_dir() and (smb := find_samples(SMB_ROOT)[0]):
            app = App("nas-fault-smb", empty_cache=True).start()
            try:
                app.client.request("open", {"path": smb}, timeout=180)
                supplement["admission"] = admit_measurement("nas-fault")
                started = time.monotonic()
                app.client.request("state", timeout=2)
                supplement.update(path=smb, roundTripMilliseconds=(time.monotonic() - started) * 1000)
            except (RuntimeError, TimeoutError, OSError) as exc:
                supplement.update(getattr(exc, "measured", {}))
                supplement["error"] = str(exc)
            finally:
                app.stop()
        else:
            supplement["error"] = "没有找到 /Volumes/Picture 上的 JPEG 目录"
        return {"unavailable": True, "nfsError": error or "NFS 上没有找到 JPEG 目录", "supplement": supplement, "protocol": "nfs",
                "admission": supplement.get("admission"), "environment": supplement.get("environment", False)}
    if mount_fstype(NFS_FAULT):
        return {"unavailable": True, "error": f"测试挂载点已在使用，保留现状：{NFS_FAULT}"}
    NFS_FAULT.parent.mkdir(parents=True, exist_ok=True)
    log = open(NFS_FAULT.parent / "nfs-fault.log", "w")
    proxy = subprocess.Popen(
        [str(mvbench_binary()), "io", "proxy", "--source", album, "--mount-at", str(NFS_FAULT), "--nfs-options", "ro"],
        cwd=ROOT, stdout=subprocess.PIPE, stderr=log, text=True,
    )
    app = None
    ready = None
    admission = None
    try:
        if not proxy.stdout or not select.select([proxy.stdout], [], [], 60)[0]:
            return {"unavailable": True, "error": "NFS 故障代理在60秒内未就绪"}
        line = proxy.stdout.readline()
        if not line:
            return {"unavailable": True, "error": "NFS 故障代理未能挂载，见 build/acceptance/nfs-fault.log"}
        ready = json.loads(line)
        if ready.get("fileSystem") != "nfs":
            return {"unavailable": True, "error": "故障代理未使用NFS，停止以避免凭据访问"}
        app = App("nas-fault", empty_cache=True, prefetch={
            "viewerDecodeFrames": 0, "viewerReadAheadPages": 0, "currentBookPages": False,
            "neighborBooks": 0, "shelfCovers": False,
        }).start()
        hide_docks(app.client)
        opened = app.client.request("open", {"path": ready["path"], "page": 0}, timeout=180)
        # 初始页可能已在 open 返回前上屏，lastDisplay 只记录翻页计时；用真实图层就绪作前提。
        wait_exact(app.client, opened["page"], prime=True)
        admission = admit_measurement("nas-fault")
        rtts, injections = [], []
        retry = True
        for mode in ("pause", "drop"):
            for seconds in (5, 15, 60):
                control_send(ready["controlPort"], mode)
                started = time.monotonic()
                frame = arm_fault_read(app.client)
                error_at = None
                read_in_flight = False
                initial_volumes = None
                injection_volumes = None
                final_volumes = []
                while time.monotonic() - started < seconds:
                    sent = time.monotonic()
                    try:
                        state = app.client.request("state", timeout=1)
                        final_volumes = fault_volumes(state)
                        if injection_volumes is None:
                            injection_volumes = final_volumes
                        if volume_in_flight(state):
                            read_in_flight = True
                            if initial_volumes is None:
                                initial_volumes = fault_volumes(state)
                        if error_at is None and window_of(state).get("loadError"):
                            error_at = time.monotonic() - started
                    except TimeoutError:
                        pass
                    rtts.append((time.monotonic() - sent) * 1000)
                    time.sleep(max(0, 0.05 - (time.monotonic() - sent)))
                control_send(ready["controlPort"], "forward")
                recovered = recover_fault(app.client, frame)
                retry = retry and recovered
                injections.append({"mode": mode, "seconds": seconds, "frame": frame,
                                   "readInFlight": read_in_flight, "inFlightVolumes": initial_volumes,
                                   "injectionVolumes": injection_volumes, "faultEndVolumes": final_volumes,
                                   "errorSeconds": error_at, "retryExactSucceeded": recovered})
                if not recovered:
                    return {"protocol": "nfs", "stateSamples": len(rtts), "injections": injections,
                            "maxRoundTripMilliseconds": max(rtts), "retrySucceeded": False,
                            "errorWithin10Seconds": False, "quitSeconds": None,
                            "admission": admission,
                            "error": "故障恢复后当前页未重新显示 exact，停止后续注入"}
        # 独立验证退出：再次暂停代理，确认未读页存在在途I/O，保持暂停直到目标PID退出。
        control_send(ready["controlPort"], "pause")
        quit_frame = arm_fault_read(app.client)
        quit_read = False
        quit_volumes = None
        quit_observed_volumes = []
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            state = app.client.request("state", timeout=1)
            quit_observed_volumes = fault_volumes(state)
            if volume_in_flight(state):
                quit_read = True
                quit_volumes = fault_volumes(state)
                break
            time.sleep(0.02)
        quit_seconds = app.stop()
        quit_normal = app.quit_exited_normally
        quit_code = app.exit_code
        quit_pid = app.pid
        app = None
        control_send(ready["controlPort"], "forward")
        required = [item for item in injections if item["seconds"] in (15, 60)]
        return {
            "protocol": "nfs", "stateSamples": len(rtts),
            "admission": admission,
            "maxRoundTripMilliseconds": max(rtts) if rtts else None,
            "errorWithin10Seconds": len(required) == 4 and all(item["errorSeconds"] is not None and item["errorSeconds"] <= 10 for item in required),
            "injections": injections, "retrySucceeded": retry,
            "quitSeconds": quit_seconds, "quitReadInFlight": quit_read,
            "quitFrame": quit_frame, "quitInFlightVolumes": quit_volumes,
            "quitVolumes": quit_observed_volumes,
            "quitExitedNormally": quit_normal,
            "quitExitCode": quit_code,
            "quitPID": quit_pid,
        }
    except Exception as exc:
        if admission:
            exc.measured = {**getattr(exc, "measured", {}), "admission": admission}
        raise
    finally:
        if ready is not None:
            try:
                control_send(ready["controlPort"], "forward")
            except OSError:
                pass
        if app is not None:
            app.stop()
        if proxy.poll() is None:
            proxy.send_signal(2)
            try:
                proxy.wait(timeout=20)
            except subprocess.TimeoutExpired:
                proxy.terminate()
                proxy.wait(timeout=5)
        log.close()


def memory_process_snapshot(pid):
    measured = {}
    for name, arguments, timeout in (("leaks", ["leaks", str(pid)], 180),
                                      ("vmmap", ["vmmap", "--summary", str(pid)], 60)):
        try:
            result = subprocess.run(arguments, capture_output=True, text=True, timeout=timeout)
            output = result.stdout + result.stderr
            measured[name + "ReturnCode"] = result.returncode
            measured["leaksOutput" if name == "leaks" else "vmmap"] = output
            if name == "leaks":
                measured.update(parse_leaks(output))
        except (subprocess.TimeoutExpired, OSError) as exc:
            measured[name + "Error"] = str(exc)
    return measured


class MemoryActions:
    """正式内存场景和定位实验复用同一翻页、滚动、切书循环。"""
    def __init__(self, sample, other, scroll_enabled=True):
        self.sample, self.other = sample, other
        self.scroll_enabled = scroll_enabled
        self.index = 0
        self.direction = 1
        self.pending = None
        self.pending_mode = False
        self.log = []

    def step(self, client, state, phase):
        if self.pending in client.inbox:
            response = client.inbox.pop(self.pending)
            client.pending.pop(self.pending, None)
            self.log[-1].update(response={key: response[key] for key in ("ok", "error") if key in response},
                                returnedMonotonic=time.monotonic())
            if not response.get("ok"):
                raise RuntimeError(response.get("error") or response)
            self.pending = None
            self.pending_mode = False
        if self.pending is not None:
            return
        action = self.index % 6
        window = window_of(state)
        self.pending_mode = False
        if action < 3:
            client.phase = f"{phase}:flip-{self.index}"
            if window.get("browseMode") != "paged":
                command, args, kind = "perform", {"command": "view.paged"}, "mode-paged"
                self.pending_mode = True
            else:
                frame, count = int(window["frame"]), int(window["frameCount"])
                if count > 1 and ((self.direction > 0 and frame >= count - 1) or (self.direction < 0 and frame <= 0)):
                    self.direction = -self.direction
                command, args, kind = "perform", {"command": "frame.next" if self.direction > 0 else "frame.previous"}, "flip"
        elif action == 3:
            client.phase = f"{phase}:{'scroll' if self.scroll_enabled else 'waterfall'}-{self.index}"
            if window.get("browseMode") != "waterfall" or not self.scroll_enabled:
                command, args, kind = "perform", {"command": "view.waterfall"}, "mode-waterfall"
                self.pending_mode = self.scroll_enabled
            else:
                command, args, kind = "scroll", {"dy": -12, "durationMs": 500, "intervalMs": 8}, "scroll"
        else:
            client.phase = f"{phase}:switch-book-{self.index}"
            command, args, kind = "open", {"path": self.other if self.index % 12 == 4 else self.sample}, "switch-book"
        self.pending = client.send(command, args, action={"index": self.index, "type": kind})
        self.log.append({"requestID": self.pending, **client.pending[self.pending]})
        if not self.pending_mode:
            self.index += 1


def memory_activity(app, duration_seconds, phase, actions, observer=None, sample_times=None):
    samples, physical, elapsed, memory, front, sampling_errors = [], [], [], [], [], []
    budgets = None
    started = time.monotonic()
    tick = started
    end = started + duration_seconds
    action_start = len(actions.log)
    monitor = MemoryStateMonitor(started, ROOT / "build" / "w37" / f"{phase}-{app.pid}", observer, sample_times)
    app.client.memory_monitor = monitor
    failure = None
    try:
        while time.monotonic() < end:
            resident_sample = time.monotonic() >= tick
            app.client.phase = f"{phase}:{'sample' if resident_sample else 'mode-probe'}-{len(samples)}"
            state = app.client.request("state", timeout=120)
            if resident_sample:
                # resident、physical、分层和前台状态来自同一次 state，保持同下标。
                try:
                    footprint = physical_footprint(app.pid)
                except (OSError, ValueError, AttributeError) as exc:
                    footprint = None
                    sampling_errors.append({"sampleIndex": len(samples), "elapsedSeconds": time.monotonic() - started,
                                            "error": str(exc)})
                samples.append(state.get("residentBytes"))
                physical.append(footprint)
                memory.append(state.get("memory"))
                front.append(state_window_front(state))
                elapsed.append(time.monotonic() - started)
                budgets = state.get("cacheBudgets")
                tick += 1
                if tick < time.monotonic():
                    tick = time.monotonic()
            actions.step(app.client, state, phase)
            # 模式响应快时让出 50 ms；原始动作、每秒采样与 120 秒等待保持不变。
            wake = min(tick, time.monotonic() + 0.05) if actions.pending_mode else tick
            time.sleep(max(0, min(wake, end) - time.monotonic()))
    except Exception as exc:
        failure = exc
    finally:
        measured = {"residentBytes": samples, "sampleElapsedSeconds": elapsed, "windowFront": front,
                    "actions": actions.index, "actionLog": actions.log[action_start:],
                    "physicalFootprintBytes": physical, "physicalFootprintSource": PHYSICAL_FOOTPRINT_SOURCE,
                    "physicalFootprintSamplingErrors": sampling_errors, "memory": memory,
                    "durationSeconds": time.monotonic() - started, "cacheBudgets": budgets}
        app.client.memory_monitor = None
        measured.update(monitor.evidence())
    if failure is not None:
        measured["error"] = str(failure)
        if isinstance(failure, DebugTimeout):
            measured["diagnostic"] = failure.detail
        if not measured.get("stateTimedOut"):
            raise MeasurementError(str(failure), measured) from failure
    return measured


def scene_memory(duration_seconds=1800, name="memory-30min"):
    sample = str(ensure_sample())
    app = App(name, empty_cache=False).start()
    measured = {}
    try:
        app.client.phase = "memory-30min:initial-open"
        app.client.request("open", {"path": sample}, timeout=120)
        try:
            measured = memory_activity(app, duration_seconds, name, MemoryActions(sample, str(HUGE_DIR)))
        except MeasurementError as exc:
            measured = exc.measured
            raise
        finally:
            # 不因前台离开或 RTT 失败提前结束；物理波动和泄漏仍独立给出结论。
            measured.update(memory_process_snapshot(app.pid))
            measured.update(memory_metrics(measured))
            measured["componentVerdicts"] = memory_components(measured, BUDGETS["memory-30min"])
    finally:
        app.stop()
    return measured


def cg_window_list():
    """仅取 CGWindowList 的只读属性，经 CoreFoundation 转成标准库 plist。"""
    cf, cg = cf_library()
    cg.CGWindowListCopyWindowInfo.argtypes = [ctypes.c_uint32, ctypes.c_uint32]
    cg.CGWindowListCopyWindowInfo.restype = ctypes.c_void_p
    cf.CFPropertyListCreateData.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long,
                                           ctypes.c_ulong, ctypes.c_void_p]
    cf.CFPropertyListCreateData.restype = ctypes.c_void_p
    cf.CFDataGetLength.argtypes = [ctypes.c_void_p]
    cf.CFDataGetLength.restype = ctypes.c_long
    cf.CFDataGetBytePtr.argtypes = [ctypes.c_void_p]
    cf.CFDataGetBytePtr.restype = ctypes.c_void_p
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    windows = cg.CGWindowListCopyWindowInfo(1 | 16, 0)  # on-screen only、exclude desktop；顺序是由前到后。
    data = None
    try:
        if not windows:
            raise RuntimeError("CGWindowListCopyWindowInfo 没有返回窗口")
        data = cf.CFPropertyListCreateData(None, windows, 100, 0, None)
        if not data:
            raise RuntimeError("CGWindowList 属性无法转换成 plist")
        return plistlib.loads(ctypes.string_at(cf.CFDataGetBytePtr(data), cf.CFDataGetLength(data)))
    finally:
        if data:
            cf.CFRelease(data)
        if windows:
            cf.CFRelease(windows)


def occlusion_evidence(target_pid, cover_pid):
    windows = [{"zIndex": index, "pid": row.get("kCGWindowOwnerPID"), "number": row.get("kCGWindowNumber"),
                "layer": row.get("kCGWindowLayer"), "alpha": row.get("kCGWindowAlpha"),
                "bounds": row.get("kCGWindowBounds"), "onScreen": row.get("kCGWindowIsOnscreen")}
               for index, row in enumerate(cg_window_list()) if row.get("kCGWindowOwnerPID") in (target_pid, cover_pid)]
    target = [row for row in windows if row["pid"] == target_pid and row["layer"] == 0]
    cover = [row for row in windows if row["pid"] == cover_pid and row["layer"] == 0]
    verified = False
    if len(target) == len(cover) == 1:
        t, c = target[0], cover[0]
        tb, cb = t["bounds"] or {}, c["bounds"] or {}
        if all(isinstance(bounds.get(key), (int, float)) for bounds in (tb, cb) for key in ("X", "Y", "Width", "Height")):
            verified = (t["zIndex"] > c["zIndex"] and c["alpha"] == 1 and
                        t["onScreen"] is True and c["onScreen"] is True and
                        tb["Width"] > 0 and tb["Height"] > 0 and
                        cb["X"] <= tb["X"] and cb["Y"] <= tb["Y"] and
                        cb["X"] + cb["Width"] >= tb["X"] + tb["Width"] and
                        cb["Y"] + cb["Height"] >= tb["Y"] + tb["Height"])
    return {"verified": verified, "targetPID": target_pid, "coverPID": cover_pid, "windows": windows}


def valid_occluded_stalls(stage):
    return [stall for stall in stage.get("stalls", [])
            if stall.get("durationSeconds", 0) > 1 and stall.get("environmentChecks") and
            all(check.get("verified") is True and check.get("screenLocked") is False
                for check in stall["environmentChecks"])]


def continuous_occlusion(stage):
    checks = stage.get("environmentObservations", [])
    return (bool(checks) and all(check.get("verified") is True for check in checks) and
            checks[0]["elapsedSeconds"] <= 1 and
            checks[-1]["elapsedSeconds"] >= stage.get("durationSeconds", 0) - 1.1 and
            all(after["elapsedSeconds"] - before["elapsedSeconds"] <= 1.1
                for before, after in zip(checks, checks[1:])))


def occlusion_result(measured):
    if measured.get("error") or measured.get("cleanupErrors"):
        return {"verdict": "unverified", "conclusion": "实验未完成，原因未定位"}
    restoration = measured.get("restoration") or {}
    if restoration.get("activationTimedOut"):
        return {"verdict": "environment", "conclusion": "窗口未在10秒内回到前台，前台对照未成立"}
    stages = {stage["phase"]: stage for stage in measured.get("stages", [])}
    if not all(name in stages for name in ("foreground", "occluded", "restored")):
        return {"verdict": "unverified", "conclusion": "实验未完成，原因未定位"}
    covered = stages["occluded"]
    continuous = continuous_occlusion(covered)
    complete = all(stage.get("durationSeconds", 0) >= stage.get("plannedSeconds", math.inf) and
                   stage.get("environmentObservations") and
                   all(check.get("screenLocked") is False for check in stage["environmentObservations"])
                   for stage in stages.values())
    for name, stage in stages.items():
        if name.endswith("occluded") and name != "occluded":
            continuous = continuous and continuous_occlusion(stage)
    valid_stalls = valid_occluded_stalls(covered)
    front_ok = all(memory_foreground(stages[name]) is True and
                   stages[name].get("maxRoundTripMilliseconds") is not None and
                   not exceeds(stages[name]["maxRoundTripMilliseconds"], 1000) and
                   not stages[name].get("stateTimedOut") for name in ("foreground", "restored"))
    front_requests = [request for request in restoration.get("stateRequests", []) if request.get("windowFront") is True]
    front_ok = (front_ok and state_window_front(restoration.get("afterActivation")) is True and
                bool(front_requests) and not restoration.get("stateTimedOut") and
                bool(restoration.get("environmentObservations")) and
                all(check.get("screenLocked") is False for check in restoration["environmentObservations"]) and
                all(not exceeds(request["durationSeconds"] * 1000, 1000) for request in front_requests))
    if not continuous or not complete or not front_ok:
        return {"verdict": "environment", "continuousOcclusionVerified": continuous,
                "validOccludedStalls": len(valid_stalls), "conclusion": "有效遮挡或前台对照未完整成立，原因未定位"}
    return {"verdict": "pass", "continuousOcclusionVerified": True, "validOccludedStalls": len(valid_stalls),
            "conclusion": "复现且回前台恢复：系统对被盖住窗口的节流" if valid_stalls else "未复现，原因未定位"}


def scene_w37_occlusion():
    sample = str(ensure_sample())
    managed, stages, instances = [], [], []
    sample_times = []
    measured = {"stages": stages, "instances": instances, "scrollEnabled": False,
                "actionSequence": "翻页、切换瀑布流（不滚动）、切书；四段一致",
                "untestedFactor": "用户操作带来的负载未在本实验验证"}

    def start(name, disabled=False):
        app = App(name, empty_cache=False, app_sleep_disabled=disabled)
        managed.append(app)  # 启动中途失败也清理这个唯一的隔离路径。
        app.start()
        instances.append({"name": name, "pid": app.pid, "socket": app.socket,
                          "root": str(app.root), "appSleepDisabled": disabled})
        return app

    def phase(app, actions, name, seconds, cover=None):
        environment, ready = wait_ready(OCCLUSION)  # 各阶段只以解锁为门槛。
        if not ready:
            raise MeasurementError("屏幕锁定或状态未知，阶段准入未满足", measured)
        observer = (lambda: occlusion_evidence(app.pid, cover.pid)) if cover is not None else None
        try:
            result = memory_activity(app, seconds, f"w37-{name}", actions, observer, sample_times)
        except MeasurementError as exc:
            result = exc.measured
            result.update(phase=name, plannedSeconds=seconds, environmentBefore=environment)
            stages.append(result)
            raise MeasurementError(str(exc), measured) from exc
        result.update(phase=name, plannedSeconds=seconds, environmentBefore=environment)
        if cover is not None:
            checks = result["environmentObservations"]
            result["verifiedOcclusionSeconds"] = sum(
                after["elapsedSeconds"] - before["elapsedSeconds"] for before, after in zip(checks, checks[1:])
                if before.get("verified") is True and after.get("verified") is True and
                after["elapsedSeconds"] - before["elapsedSeconds"] <= 1.1)
            result["invalidOcclusionChecks"] = sum(check.get("verified") is not True for check in checks)
            result["validOccludedStalls"] = len(valid_occluded_stalls(result))
        stages.append(result)
        return result

    def cover_for(app, name):
        cover = start(name)
        mode = display_probe()
        resized = cover.client.request("resize", {"width": mode["width"], "height": mode["height"]})
        instances[-1].update(resizeResult=resized, initialOcclusion=occlusion_evidence(app.pid, cover.pid))
        return cover

    try:
        target = start("w37-target")
        target.client.request("open", {"path": sample}, timeout=120)
        actions = MemoryActions(sample, str(HUGE_DIR), scroll_enabled=False)
        phase(target, actions, "foreground", 180)
        cover = cover_for(target, "w37-cover")
        covered = phase(target, actions, "occluded", 300, cover)
        cover.stop()
        restored = measured["restoration"] = {}
        restoration_monitor = MemoryStateMonitor(time.monotonic(), ROOT / "build" / "w37" / f"restoration-{target.pid}",
                                                  sample_times=sample_times)
        target.client.memory_monitor = restoration_monitor
        try:
            target.client.phase = "w37-restoration:before-activation"
            restored["beforeActivation"] = target.client.request("state", timeout=120)
            if state_window_front(restored["beforeActivation"]) is not True:
                command = ["/usr/bin/open", "-a", str(app_binary().parents[2])]
                subprocess.run(command, check=True, timeout=30)
                restored["activationCommand"] = command
            target.client.phase = "w37-restoration:after-activation"
            poll_started = time.monotonic()
            poll_deadline = poll_started + 10
            restored["afterActivation"] = None
            while True:
                remaining = poll_deadline - time.monotonic()
                if remaining <= 0:
                    break
                try:
                    restored["afterActivation"] = target.client.request("state", timeout=remaining)
                except DebugTimeout as exc:
                    restored["pollDiagnostic"] = exc.detail
                    break
                if state_window_front(restored["afterActivation"]) is True:
                    break
                time.sleep(min(0.1, max(0, poll_deadline - time.monotonic())))
            restored["activationWaitSeconds"] = time.monotonic() - poll_started
            restored["activationTimedOut"] = state_window_front(restored["afterActivation"]) is not True
        finally:
            target.client.memory_monitor = None
            restored.update(restoration_monitor.evidence())
        if not restored["activationTimedOut"]:
            phase(target, actions, "restored", 120)
        # 只以已经证实盖住时的停顿触发额外实例；未盖住的慢响应不能触发因果对照。
        if valid_occluded_stalls(covered):
            target.stop()
            disabled = start("w37-sleep-disabled-target", disabled=True)
            disabled.client.request("open", {"path": sample}, timeout=120)
            disabled_cover = cover_for(disabled, "w37-sleep-disabled-cover")
            phase(disabled, MemoryActions(sample, str(HUGE_DIR), scroll_enabled=False), "sleep-disabled-occluded", 180, disabled_cover)
        measured.update(occlusion_result(measured))
    except Exception as exc:
        measured.update(error=str(exc), verdict="unverified", conclusion="实验未完成，原因未定位")
        if isinstance(exc, DebugTimeout):
            measured["diagnostic"] = exc.detail
    finally:
        for app in reversed(managed):
            try:
                app.stop()
            except (OSError, RuntimeError, TimeoutError) as exc:
                measured.setdefault("cleanupErrors", []).append({"pid": app.pid, "error": str(exc)})
            try:
                if app.pid is None or not app.wait_exit(0):
                    measured.setdefault("cleanupErrors", []).append({"pid": app.pid, "root": str(app.root),
                                                                    "error": "未确认隔离实例退出，保留其支持目录"})
                    continue
                if app.root.exists():
                    shutil.rmtree(app.root)
                Path(app.socket).unlink(missing_ok=True)
            except OSError as exc:
                measured.setdefault("cleanupErrors", []).append({"root": str(app.root), "error": str(exc)})
    measured.update(occlusion_result(measured))
    return measured


def scene_tiles_cancel():
    if not (HUGE_DIR / "20000x20000.jpg").is_file():
        return {"unavailable": True, "error": f"没有 {HUGE_DIR / '20000x20000.jpg'}"}
    app = App("tiles-cancel", empty_cache=True).start()
    try:
        app.client.request("resize", {"width": 1400, "height": 900})
        app.client.request("open", {"path": str(HUGE_DIR)}, timeout=180)
        for _ in range(16):
            app.client.request("perform", {"command": "zoom.in"})
        requested = 0
        cancelled = 0
        scrolls = 0
        tiles = {}
        for _ in range(8):
            baseline = None
            for _ in range(80):
                tiles = window_of(app.client.request("state")).get("tiles") or {}
                requested = int(tiles.get("requested") or 0)
                if int(tiles.get("inFlight") or 0) > 0:
                    baseline = int(tiles.get("cancelled") or 0)
                    app.client.request("scroll", {"dx": 5000, "dy": -4000, "steps": 1}, timeout=10)
                    scrolls += 1
                    break
                time.sleep(0.02)
            time.sleep(0.05)
            tiles = window_of(app.client.request("state")).get("tiles") or {}
            cancelled = 0 if baseline is None else int(tiles.get("cancelled") or 0) - baseline
            if cancelled > 0:
                break
            app.client.request("perform", {"command": "zoom.in"})
        return {"requested": requested, "cancelled": cancelled, "scrolls": scrolls,
                "inFlight": int(tiles.get("inFlight") or 0), "tiles": tiles}
    finally:
        app.stop()


def panel_view(state):
    panels = window_of(state).get("panels") or {}
    return {"bookshelf": panels.get("bookshelf"), "pageList": panels.get("pageList")}


def same_panel(before, after):
    if not before or not after:
        return False
    for name in ("bookshelf", "pageList"):
        left, right = before.get(name), after.get(name)
        if not left or not right:
            return False
        if left.get("style") != right.get("style"):
            return False
        if round(float(left.get("itemExtent")), 3) != round(float(right.get("itemExtent")), 3):
            return False
        if left.get("sort") != right.get("sort"):
            return False
    return True


def scene_panel_restart():
    app = App("panel-restart", empty_cache=True).start()
    try:
        client = app.client
        client.request("perform", {"command": "panel.settings", "arguments": {"panel": "bookshelf", "style": "grid", "itemExtent": 180}})
        client.request("perform", {"command": "panel.settings", "arguments": {"panel": "pageList", "style": "table", "itemExtent": 80}})
        before = panel_view(client.request("state"))
    finally:
        app.stop()
    app = App("panel-restart", empty_cache=False).start()
    try:
        after = panel_view(app.client.request("state"))
    finally:
        app.stop()
    return {"before": before, "after": after, "matched": same_panel(before, after)}


def prepare_scroll(scene, socket_path, automatic=False):
    if scene not in ("scroll-cached", "scroll-cold", "settle"):
        raise SystemExit(f"不是滚动场景：{scene}")
    client = DebugClient(socket_path, phase=scene + ":prepare")
    prepared = {"admission": None, "ready": True, "automatic": automatic}
    try:
        if automatic and scene in ("scroll-cold", "settle"):
            admission, ready = wait_ready(scene)
            prepared.update(admission=admission, ready=ready)
        if prepared["ready"]:
            client.request("open", {"path": str(ensure_sample())}, timeout=180)
            client.request("perform", {"command": "view.waterfall"})
            client.request("resize", {"width": 1400, "height": 900})
            if scene == "scroll-cached":
                for dy in (-900, 900):
                    # steps 路径的 dy 是总位移，不含 continuousScroll 的边界反向。
                    for _ in range(20):
                        client.request("scroll", {"dy": dy, "steps": 6, "intervalMs": 16}, timeout=30)
                    wait_idle(client, 180)
                visible = window_of(client.request("state")).get("visibleRange") or []
                if not visible or visible[0] != 0:
                    raise RuntimeError(f"缓存准备后未回到顶部：visibleRange={visible}")
                if automatic:
                    admission, ready = wait_ready(scene)
                    prepared.update(admission=admission, ready=ready)
        prepared["windowFront"] = window_of(client.request("state")).get("windowFront")
        return prepared["ready"]
    finally:
        # open 或后续准备失败时也带回已经完成的准入，不回退到主进程的旧环境。
        prepared["waitExhausted"] = WAIT_EXHAUSTED
        print(json.dumps(prepared))
        client.close()


def run_settle_scroll(client, seconds, sample_resident):
    """独立停止场景：每 2 秒连续滚动后停到本轮 2.5 秒边界，持续完整 60 秒。"""
    started = time.monotonic()
    deadline = started + seconds
    result = {"events": 0, "scrollMovements": 0, "windowFront": True, "scrollBursts": []}
    while time.monotonic() < deadline:
        burst = time.monotonic()
        duration_ms = min(2000, max(1, int((deadline - burst) * 1000)))
        scroll = client.request("scroll", {"dy": -12, "durationMs": duration_ms, "intervalMs": 8}, timeout=10)
        result["events"] += scroll.get("events", 0)
        result["scrollMovements"] += scroll.get("scrollMovements", 0)
        result["windowFront"] = result["windowFront"] and scroll.get("windowFront") is True
        result["responsiveScrolling"] = scroll.get("responsiveScrolling")
        result["scrollBursts"].append({"startElapsedSeconds": burst - started, "durationMs": duration_ms,
                                       "responseElapsedSeconds": time.monotonic() - started})
        sample_resident()
        # continuousScroll 在 ended 后已等 250 ms；这里只补齐本次停止的其余时间。
        time.sleep(max(0, min(deadline, burst + duration_ms / 1000 + 0.5) - time.monotonic()))
    result["durationSeconds"] = time.monotonic() - started
    return result


def run_segmented_scroll(client, seconds, sample_resident):
    """每段是独立手势，交替方向；手势时长合计 60 秒，结束响应的间隔也留在录制内。"""
    started = time.monotonic()
    remaining_ms = int(seconds * 1000)
    result = {"events": 0, "scrollMovements": 0, "windowFront": True, "scrollSegments": []}
    while remaining_ms > 0:
        duration_ms = min(8000, remaining_ms)
        dy = -8 if len(result["scrollSegments"]) % 2 == 0 else 8
        burst = time.monotonic()
        pending = client.send("scroll", {"dy": dy, "durationMs": duration_ms, "intervalMs": 3})
        deadline = burst + duration_ms / 1000
        while time.monotonic() < deadline:
            sample_resident()
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        scroll = client.wait(pending, 30).get("result", {})
        result["events"] += scroll.get("events", 0)
        result["scrollMovements"] += scroll.get("scrollMovements", 0)
        result["windowFront"] = result["windowFront"] and scroll.get("windowFront") is True
        result["responsiveScrolling"] = scroll.get("responsiveScrolling")
        gesture_seconds = duration_ms / 1000
        result["scrollSegments"].append({"startElapsedSeconds": burst - started, "durationMs": duration_ms, "dy": dy,
                                          "responseElapsedSeconds": time.monotonic() - started,
                                          "events": scroll.get("events"), "scrollMovements": scroll.get("scrollMovements"),
                                          "gestureSeconds": gesture_seconds,
                                          "eventsPerSecond": scroll.get("events", 0) / gesture_seconds})
        remaining_ms -= duration_ms
    gesture_seconds = sum(segment["gestureSeconds"] for segment in result["scrollSegments"])
    result.update(durationSeconds=time.monotonic() - started, gestureSeconds=gesture_seconds,
                  eventsPerSecond=result["events"] / gesture_seconds if gesture_seconds else None)
    return result


def run_scroll(scene, socket_path, outdir, automatic=True, seconds=60):
    if scene not in ("scroll-cached", "scroll-cold", "settle"):
        raise SystemExit(f"不是滚动场景：{scene}")
    client = DebugClient(socket_path, phase=scene + ":record")
    out = Path(outdir)
    before = sample_conditions()
    mark = input_mark(DURING_EVENTS)
    started = trace_clock_seconds()
    resident, rss_error = [], None
    try:
        window_before = json.loads((out / "window-before.json").read_text())

        def sample_resident():
            nonlocal rss_error
            if rss_error is None:
                try:
                    value = client.request("state", timeout=5).get("residentBytes")
                    if not isinstance(value, (int, float)) or value <= 0:
                        raise ValueError("residentBytes 缺失或无效")
                    resident.append(value)
                except (TimeoutError, ConnectionError, OSError, ValueError) as exc:
                    rss_error = getattr(exc, "detail", {"error": str(exc)})

        if automatic and scene == "settle":
            scroll = run_settle_scroll(client, seconds, sample_resident)
        elif automatic:
            scroll = run_segmented_scroll(client, seconds, sample_resident)
        else:
            print(f"正在录制 {seconds} 秒：请在 MacView 中用触控板滚动、缩放。", flush=True)
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                sample_resident()
                time.sleep(min(1, max(0, deadline - time.monotonic())))
            scroll = {}
        if scene != "settle":
            time.sleep(0.5)
        during = sample_conditions()
        during["before"] = before
        during["admission"] = window_before.get("admission")
        during["inputMark"] = mark
        during["screen"]["inputDuringRun"] = input_mark(DURING_EVENTS) > mark + 0.5
        # 连续手势的响应已经带回窗口和响应式滚动状态，不为辅助字段再等一次state。
        window = scroll if automatic else window_of(client.request("state", timeout=5))
        during["windowFrontBefore"] = window_before.get("windowFront")
        during["windowFront"] = window_before.get("windowFront") is True and window.get("windowFront") is True and scroll.get("windowFront", True)
        during["residentPeakBytes"] = max(resident, default=None)
        during["residentSamplingError"] = rss_error
        during["residentSampleCount"] = len(resident)
        cadence = 2.5 if automatic and scene == "settle" else 1
        during["residentSampleCadenceSeconds"] = cadence
        during["residentSamplingComplete"] = rss_error is None and len(resident) >= math.ceil(seconds / cadence)
        during["scrollMovements"] = scroll.get("scrollMovements")
        during["scrollEvents"] = scroll.get("events")
        during["driver"] = "synthetic" if automatic else "trackpad"
        during["responsiveScrolling"] = window.get("responsiveScrolling")
        if automatic:
            during["events"] = scroll.get("events")
            during["eventsPerSecond"] = scroll.get("eventsPerSecond")
            during["scrollSegments"] = scroll.get("scrollSegments")
            during["gestureSeconds"] = scroll.get("gestureSeconds")
            during["durationSeconds"] = scroll.get("durationSeconds")
        if scene == "settle":
            during["scrollBursts"] = scroll.get("scrollBursts")
        (out / "during.json").write_text(json.dumps(during, ensure_ascii=False, indent=2) + "\n")
    except Exception as exc:
        measured = {"error": str(exc), "residentPeakBytes": max(resident, default=None), "residentSamplingError": rss_error,
                    "residentSampleCount": len(resident), "residentSamplingComplete": False}
        if isinstance(exc, DebugTimeout):
            measured["diagnostic"] = exc.detail
        (out / "error.json").write_text(json.dumps(measured, ensure_ascii=False, indent=2) + "\n")
        raise
    finally:
        phase = {"phases": [{"name": scene, "start": started, "end": trace_clock_seconds()}]}
        (out / "phase.json").write_text(json.dumps(phase) + "\n")
        client.close()


def quit_app(socket_path):
    try:
        client = DebugClient(socket_path)
    except OSError:
        return
    try:
        client.request("quit", timeout=2)
    except (RuntimeError, TimeoutError, ConnectionError, OSError):
        pass
    finally:
        client.close()


def sampled_during(mark):
    """跑完再看一次。滚轮不计入输入，场景自己会发合成滚动。"""
    sampled = sample_conditions()
    sampled["screen"]["inputDuringRun"] = input_mark(DURING_EVENTS) > mark + 0.5
    return sampled


def merge_during(env, during):
    if not during:
        return env
    merged = json.loads(json.dumps(env))
    # 准备后、启动测量工具前的准入负载才参与判定；before 是 xctrace 启动后的观察值。
    admission = during.get("admission") or {}
    before = during.get("before") or {}
    for key in ("load", "displayMode", "refreshHz", "screen"):
        source = admission if key == "load" and admission else before or admission
        if key in source:
            merged[key] = json.loads(json.dumps(source[key]))
    if admission:
        merged["admission"] = admission
    if before.get("load"):
        merged["load"]["before"] = before["load"].get("oneMinute")
    screen = during.get("screen") or {}
    merged["screenAfter"] = screen
    # 开始时的空闲秒数保留。滚动之后滚轮空闲会变成 0，那不是用户输入。
    merged["screen"]["inputDuringRun"] = bool(screen.get("inputDuringRun"))
    if "locked" in screen:
        initial = merged["screen"].get("locked")
        merged["screen"]["locked"] = False if initial is False and screen["locked"] is False else (True if initial or screen["locked"] else None)
    if "externalDisplay" in screen:
        merged["screen"]["externalDisplay"] = bool(merged["screen"].get("externalDisplay") or screen["externalDisplay"])
    # 后续负载包括重启、场景动作和 xctrace，保留观测但不重新准入。
    if during.get("load") and during["load"].get("oneMinute") is not None:
        merged["load"]["during"] = during["load"]["oneMinute"]
    if during.get("refreshHz") is not None:
        merged["refreshHzAfter"] = during["refreshHz"]
    if during.get("displayMode"):
        merged["displayModeAfter"] = during["displayMode"]
    return merged


def write_report(out, scene, commit, env, measured, verdict):
    path = Path(out) / ("S2-T3-w37-occlusion.json" if scene == OCCLUSION else f"S2-T2-{scene}.json")
    path.parent.mkdir(parents=True, exist_ok=True)
    document = {
        "scene": scene,
        "commit": commit,
        "env": env,
        "budget": BUDGETS[scene],
        "measured": measured,
        "verdict": verdict,
    }
    path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n")
    print(f"{scene}: {verdict} -> {path}", flush=True)


def run_scene(scene, out, commit, base_env):
    runner = {
        "first-image": scene_first_image,
        "preloaded-flip": scene_preloaded_flip,
        "scroll-cached": scene_scroll_cached,
        "scroll-cold": scene_scroll_cold,
        "main-thread": scene_main_thread,
        "settle": scene_settle,
        "nas-throughput": scene_nas_throughput,
        "cached-first-screen": scene_cached_first_screen,
        "large-dir": scene_large_dir,
        "nas-fault": scene_nas_fault,
        "memory-30min": scene_memory,
        OCCLUSION: scene_w37_occlusion,
        "tiles-cancel": scene_tiles_cancel,
        "panel-restart": scene_panel_restart,
    }[scene]
    paths = []
    if scene in ("first-image", "preloaded-flip", "scroll-cached", "scroll-cold", "main-thread", "settle", "cached-first-screen", "memory-30min", OCCLUSION):
        try:
            paths.append(str(ensure_sample()))
        except FileNotFoundError:
            pass
    if scene == "large-dir":
        paths.append(str(TREE))
    if scene in ("nas-throughput", "cached-first-screen", "nas-fault"):
        paths.append(str(NFS_MOUNT))
    env = dict(base_env)
    env.update(mvbench_env(paths))
    # mvbench 的字段和本机探针都留在 env 里；探针放在后面，避免被环境 JSON 覆盖。
    for key in ("load", "displayMode", "refreshHz", "screen"):
        env[key] = base_env[key]
    if scene in NAS_APP_SCENES:
        if screen_locked() is not False:
            current, ready = wait_ready(scene, screen_only=True)
            for key in ("load", "displayMode", "refreshHz", "screen"):
                env[key] = current[key]
            if not ready:
                write_report(out, scene, commit, env,
                             {"environment": True, "reason": "屏幕锁定或锁定状态未知，环境准入等待已耗尽"}, "environment")
                return
        try:
            mount, _ = ensure_nfs()
            album = find_samples(mount)[0] if mount else None
        except (OSError, subprocess.TimeoutExpired) as exc:
            write_report(out, scene, commit, env, {"unavailable": True, "nfsError": str(exc)}, "unverified")
            return
        if album:
            authorization = preflight_nas_access(album)
            env["nasAuthorization"] = authorization
            if not authorization["ready"]:
                write_report(out, scene, commit, env,
                             {"environment": True, "reason": authorization["reason"]}, "environment")
                return
    during = None
    mark = None
    if scene in FOREGROUND:
        if scene not in DEFERRED_ADMISSION:
            current, ready = wait_ready(scene)
            for key in ("load", "displayMode", "refreshHz", "screen"):
                env[key] = current[key]
            if not ready:
                write_report(out, scene, commit, env, {"reason": "环境在 20 分钟内没有满足"}, "environment")
                return
            mark = input_mark(DURING_EVENTS)
    try:
        result = runner()
        if isinstance(result, tuple):
            measured, during = result
        else:
            measured = result
    except Exception as exc:
        measured = {**getattr(exc, "measured", {}), "error": str(exc)}
        if isinstance(exc, DebugTimeout):
            measured["diagnostic"] = exc.detail
        during = getattr(exc, "during", during)
        if during is None and scene in FOREGROUND:
            mark = (measured.get("admission") or {}).get("inputMark", mark)
            during = sampled_during(mark) if mark is not None else sample_conditions()
        if measured.get("admission"):
            during = {**(during or {}), "admission": measured["admission"]}
        env = merge_during(env, during)
        measured["unavailable"] = True
        verdict = judge(scene, measured, env)
        write_report(out, scene, commit, env, measured, verdict)
        return
    # 滚动场景用录制期间的 during.json，里面的输入不含滚轮。其余前台场景在这里补一次。
    if during is None and scene in FOREGROUND:
        mark = (measured.get("admission") or {}).get("inputMark", mark)
        during = sampled_during(mark) if mark is not None else sample_conditions()
    if "measurementInputDuringRun" in measured:
        during["screen"]["inputDuringRun"] = measured["measurementInputDuringRun"]
    if measured.get("admission"):
        during = {**(during or {}), "admission": measured["admission"]}
    env = merge_during(env, during)
    if isinstance(measured, dict) and measured.get("refreshHz") is None and env.get("refreshHz") is not None:
        measured["refreshHz"] = env["refreshHz"]
    write_report(out, scene, commit, env, measured, judge(scene, measured, env))


def parse_args(argv):
    parser = argparse.ArgumentParser(description="运行 MacView 验收场景")
    parser.add_argument("scenes", nargs="*", help="场景名；省略时跑全部场景")
    parser.add_argument("--out", default="docs/reports/bench")
    parser.add_argument("--check-verdicts", action="store_true")
    parser.add_argument("--prepare-scroll", nargs=2, metavar=("SCENE", "SOCKET"))
    parser.add_argument("--automatic", action="store_true", help="滚动准备时执行自动验收的环境准入")
    parser.add_argument("--run-scroll", nargs=3, metavar=("SCENE", "SOCKET", "OUT"))
    parser.add_argument("--observe-scroll", nargs=3, metavar=("SCENE", "SOCKET", "OUT"))
    parser.add_argument("--smoke-scroll", nargs=3, metavar=("SCENE", "SOCKET", "OUT"))
    parser.add_argument("--quit-app", metavar="SOCKET")
    parser.add_argument("--launch-app", nargs=5, metavar=("SOCKET", "SUPPORT", "CACHE", "LAYOUT", "LOG"))
    parser.add_argument("--main-thread-summary", nargs=2, metavar=("TRACE", "OUT"))
    return parser.parse_args(argv)


def main(argv):
    if "--check-verdicts" in argv:
        check_verdicts()
        return 0
    args = parse_args(argv)
    os.chdir(ROOT)
    if args.launch_app:
        print(launch_app(*[str(Path(path).resolve()) for path in args.launch_app]))
        return 0
    if args.main_thread_summary:
        trace, output = args.main_thread_summary
        Path(output).write_text(json.dumps(main_thread_samples(trace), ensure_ascii=False, indent=2) + "\n")
        return 0
    if args.quit_app:
        quit_app(args.quit_app)
        return 0
    if args.prepare_scroll:
        return 0 if prepare_scroll(args.prepare_scroll[0], args.prepare_scroll[1], automatic=args.automatic) else 3
    if args.run_scroll:
        run_scroll(*args.run_scroll)
        return 0
    if args.observe_scroll:
        run_scroll(*args.observe_scroll, automatic=False)
        return 0
    if args.smoke_scroll:
        run_scroll(*args.smoke_scroll, automatic=False, seconds=1)
        return 0
    requested = args.scenes or list(SCENES)
    unknown = [scene for scene in args.scenes if scene not in SCENES + [OCCLUSION]]
    if unknown:
        raise SystemExit(f"未知场景：{', '.join(unknown)}")
    # 保留显式请求的顺序；默认 NAS 在录制前，内存场景始终放在最后。
    scenes = ([scene for scene in requested if scene != "memory-30min"]
              + [scene for scene in requested if scene == "memory-30min"])
    subprocess.Popen(["caffeinate", "-d", "-w", str(os.getpid())])
    if any(scene in FOREGROUND for scene in scenes):
        app_binary()  # 构建在环境准入之前完成，嵌套录制只复用已冻结的二进制。
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    base = sample_conditions()
    for scene in scenes:
        run_scene(scene, args.out, commit, base)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    finally:
        stop_live()
