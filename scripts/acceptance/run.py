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
REFRESH_120 = 119.0
LOAD_LIMIT = int(subprocess.check_output(["/usr/sbin/sysctl", "-n", "hw.physicalcpu"], text=True).strip())
MEMORY_ROLLING_MEDIAN = True  # 用户 2026-11-04 已确认采用 60 秒滚动中位数。
MEMORY_KEYS = ("rawBytes", "decodedBytes", "thumbnailMemoryBytes", "preloadBytes", "inFlightBytes", "waitingTasks")
IDLE_SECONDS = 45.0
WAIT_READY = 20 * 60

SCENES = [
    "first-image", "preloaded-flip", "scroll-cached", "scroll-cold", "main-thread", "settle",
    "nas-throughput", "cached-first-screen", "large-dir", "nas-fault", "memory-30min",
    "tiles-cancel", "panel-restart",
]
FOREGROUND = set(SCENES) - {"nas-throughput"}
# 不看时序的场景只要求屏幕没锁。键鼠空闲、运行中输入、负载和外接显示器不参与判定。
SCREEN_ONLY = {"main-thread", "memory-30min", "tiles-cancel", "panel-restart"}
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
    "scroll-cached": {"frameTimeP99Milliseconds": FRAME_MS, "refreshHz": 120, "submitPlusRenderP99Milliseconds": FRAME_MS},
    "scroll-cold": {"frameTimeP99Milliseconds": FRAME_MS, "refreshHz": 120, "submitPlusRenderP99Milliseconds": FRAME_MS},
    "main-thread": {"mainThreadFileReadOrImageIO": 0},
    "settle": {"settleRequestLatencyP99Milliseconds": 100},
    "nas-throughput": {"thumbnailToRawRatio": 0.9},
    "cached-first-screen": {"firstScreenP95Milliseconds": 100, "samplesPerRoot": 20},
    "large-dir": {"maxRoundTripMilliseconds": 250, "itemCountChanges": 3},
    "nas-fault": {"maxRoundTripMilliseconds": 250, "errorWithinSeconds": 10, "quitSeconds": 3},
    "memory-30min": {"deviation": 0.10, "leaks": 0, "ignoreFirstSeconds": 300},
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
    if scene in FOREGROUND and env_problem(env, scene):
        return "environment"
    if scene in ("scroll-cached", "scroll-cold") and (not is_120(env.get("refreshHz")) or not is_120(env.get("refreshHzAfter"))):
        return "environment"
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
        total = measured.get("mainThreadSamples")
        known = measured.get("knownSymbolSamples")
        io_count = measured.get("fileReadOrImageIO")
        if total is None or known is None or io_count is None or total == 0 or known == 0:
            return "unverified"
        return "pass" if io_count == limits["mainThreadFileReadOrImageIO"] else "fail"
    if scene == "settle":
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
        rtt, changes = measured.get("maxRoundTripMilliseconds"), measured.get("itemCountChanges")
        if not measured.get("stateSamples"):
            return "unverified"
        if rtt is None or changes is None:
            return "fail"
        return "fail" if exceeds(rtt, limits["maxRoundTripMilliseconds"]) or changes < limits["itemCountChanges"] else "pass"
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
    if scene == "memory-30min":
        return judge_memory(measured, limits)
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
    if not measured.get("frames") or not measured.get("scrollMovements"):
        return "unverified"
    hitches = measured.get("hitches")
    update, render = measured.get("updateP99"), measured.get("renderP99")
    frame = measured.get("frameTimeP99")
    if hitches is None or update is None or render is None or frame is None:
        return "unverified"
    if hitches > 0 or exceeds(float(update) + float(render), limits["submitPlusRenderP99Milliseconds"]) or exceeds(frame, limits["frameTimeP99Milliseconds"]):
        return "fail"
    return "pass"


def judge_memory(measured, limits):
    leaks = measured.get("unexpectedLeakItems", measured.get("leaks"))
    if leaks is None:
        return "unverified"
    if measured.get("leakRootsParsed") is False:
        return "unverified"
    samples = measured.get("residentBytes")
    elapsed = measured.get("sampleElapsedSeconds")
    if not isinstance(samples, list) or not samples or not isinstance(elapsed, list) or len(elapsed) != len(samples):
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
    med = statistics.median(tail)
    if med <= 0:
        return "fail"
    metrics = memory_metrics(measured, limits["ignoreFirstSeconds"])
    deviation = metrics.get("rollingMedianDeviation" if MEMORY_ROLLING_MEDIAN else "perSecondDeviation")
    if deviation is None:
        return "unverified"
    if leaks != limits["leaks"] or round(deviation - limits["deviation"], 4) > 0:
        return "fail"
    return "pass"


def memory_metrics(measured, warmup=300):
    pairs = list(zip(measured.get("sampleElapsedSeconds", []), measured.get("residentBytes", [])))
    tail = [(t, v) for t, v in pairs if t >= warmup and isinstance(v, (int, float))]
    if not tail or statistics.median(v for _, v in tail) <= 0:
        return {}
    median = statistics.median(v for _, v in tail)
    rolling = [statistics.median(v for t, v in tail if now - 60 < t <= now)
               for now, _ in tail if now >= warmup + 60]
    peak = max(range(len(pairs)), key=lambda i: pairs[i][1] or 0)
    layers = measured.get("memory", [])
    return {"residentMedianBytes": median, "perSecondDeviation": max(abs(v - median) / median for _, v in tail),
            "rollingMedianDeviation": max(abs(v - median) / median for v in rolling) if rolling else None,
            "rollingWindowSeconds": 60, "residentPeakBytes": pairs[peak][1], "peakElapsedSeconds": pairs[peak][0],
            "peakMemory": layers[peak] if peak < len(layers) else None,
            "deviationMethod": "rollingMedian60Seconds" if MEMORY_ROLLING_MEDIAN else "perSecond"}


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
    scroll = {"frames": 100, "scrollMovements": 50, "windowFront": True,
              "hitches": 0, "updateP99": 2.0, "renderP99": 2.0, "frameTimeP99": 8.33}
    memory = {"leaks": 0, "residentBytes": [100] * 1800,
              "memory": [dict.fromkeys(MEMORY_KEYS, 0)] * 1800,
              "sampleElapsedSeconds": list(range(1800)), "durationSeconds": 1800}
    valid = {
        "first-image": {"p95": 150, "samples": 30},
        "preloaded-flip": {"p95": 8.33, "flips": 100},
        "scroll-cached": scroll, "scroll-cold": scroll,
        "main-thread": {"mainThreadSamples": 10, "knownSymbolSamples": 4, "fileReadOrImageIO": 0},
        "settle": {"settles": 1, "settleRequestLatencyP99": 100},
        "nas-throughput": {"samples": 3, "thumbnailToRawRatio": 0.9},
        "cached-first-screen": {"localP95": 100, "nfsP95": 100, "localSamples": 20, "nfsSamples": 20},
        "large-dir": {"stateSamples": 20, "maxRoundTripMilliseconds": 250, "itemCountChanges": 3},
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
        ("内存不是完整30分钟", judge("memory-30min", {**memory, "durationSeconds": 1000}, env), "unverified"),
        ("内存按秒忽略前5分钟", judge("memory-30min", {**memory, "residentBytes": [10000] * 300 + [100] * 1500}, env), "pass"),
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
            (f"{scene} 帧超预算", judge(scene, {**scroll, "frameTimeP99": 8.34}, env120), "fail"),
            (f"{scene} 有卡顿", judge(scene, {**scroll, "hitches": 1}, env120), "fail"),
            (f"{scene} 提交加渲染超预算", judge(scene, {**scroll, "renderP99": 6.34}, env120), "fail"),
            (f"{scene} 窗口不在前台", judge(scene, {**scroll, "windowFront": False}, env120), "environment"),
        ]
    for scene in SCREEN_ONLY:
        for changed in (_load(env, 10), _screen(env, inputDuringRun=True, idleSeconds=1, externalDisplay=True)):
            cases.append((f"{scene} 只检查锁屏", judge(scene, valid[scene], changed), "pass"))
    merged = merge_during(env, {"load": {"oneMinute": 14.2}, "refreshHz": 120, "screen": {}})
    if merged["load"]["oneMinute"] != 1.0 or merged["load"].get("during") != 14.2 or merged["refreshHz"] != 59.94 or merged.get("refreshHzAfter") != 120:
        raise SystemExit(f"check-verdicts 失败：前后环境没有分别保留 {merged}")
    cases.append(("运行中负载不影响判定", judge("first-image", valid["first-image"], merged), "pass"))
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
WAIT_EXHAUSTED = False


def wait_ready(scene=None):
    global WAIT_EXHAUSTED
    if WAIT_EXHAUSTED:
        current = sample_conditions()
        return current, not env_problem(current, scene)
    deadline = time.monotonic() + WAIT_READY
    while True:
        current = sample_conditions()
        if not env_problem(current, scene):
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

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def send(self, command, args=None):
        ident = self.next_id
        self.next_id += 1
        payload = json.dumps({"id": ident, "command": command, "args": args or {}}, ensure_ascii=False) + "\n"
        self.sock.sendall(payload.encode())
        self.pending[ident] = {"command": command, "phase": self.phase, "arguments": args or {}}
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

    def request(self, command, args=None, timeout=30):
        message = self.wait(self.send(command, args), timeout)
        if not message.get("ok", False):
            raise RuntimeError(message.get("error") or message)
        return message.get("result")


def launch_app(socket_path, support, cache, layout, log):
    binary = app_binary()
    temporary = Path(support).resolve().parent / "tmp"
    temporary.mkdir(parents=True, exist_ok=True)
    subprocess.run(["/usr/bin/open", "-n", "-a", str(binary.parents[2]), "--stdout", str(log), "--stderr", str(log),
                    "--env", f"TMPDIR={temporary}/",
                    "--args", "-MVDebugSocket", str(socket_path), "-MVSupportDirectory", str(support),
                    "-MVCacheDirectory", str(cache), "-MVLayoutFile", str(layout)], check=True)
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

    def __init__(self, name, prefetch_zero=False, empty_cache=True, prefetch=None):
        self.name = name
        self.prefetch_zero = prefetch_zero
        self.empty_cache = empty_cache
        self.prefetch = prefetch
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
        self.pid = launch_app(self.socket, self.support, self.cache, self.layout, self.root / "app.log")
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
        samples = []
        for page in pages:
            app.client.request("open", {"path": path, "page": page}, timeout=120)
            samples.append(wait_exact(app.client, page))
        state = app.client.request("state")
        final = {"memory": state.get("memory"), "hudVisible": window_of(state).get("hudVisible")}
        return {"samples": len(samples), "p95": p95(samples), "milliseconds": samples, "pages": pages,
                "frameCount": count, "prefetchDisabled": True, "panelsHidden": True,
                "initialState": initial, "finalState": final}
    finally:
        app.stop()


def scene_preloaded_flip():
    path = str(ensure_sample())
    app = App("preloaded-flip", empty_cache=True).start()
    try:
        app.client.request("open", {"path": path}, timeout=120)
        wait_idle(app.client, 180)
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
        return {"flips": len(samples), "p95": p95(samples), "milliseconds": samples}
    finally:
        app.stop()


def record_scroll(scene):
    out = ROOT / "build" / "acceptance" / f"{scene}-record"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    try:
        subprocess.run([str(ROOT / "scripts/acceptance/record-trackpad.sh"), scene, str(out), "--automatic"], cwd=ROOT, check=True)
    except subprocess.CalledProcessError as exc:
        measured = json.loads((out / "error.json").read_text()) if (out / "error.json").exists() else {}
        raise MeasurementError(str(exc), measured) from exc
    summary = json.loads((out / "hitches.json").read_text())
    phases = summary.get("phases") or []
    if not phases:
        raise RuntimeError("帧时间汇总没有阶段")
    during = json.loads((out / "during.json").read_text()) if (out / "during.json").exists() else {}
    phase = phases[0]
    measured = {
        "frames": phase.get("frames"),
        "hitches": phase.get("hitches"),
        "updateP99": phase.get("updateP99"),
        "renderP99": phase.get("renderP99"),
        "frameTimeP99": phase.get("frameTimeP99"),
        "refreshHz": during.get("refreshHz"),
        "settleRequestLatencyP99": phase.get("settleRequestLatencyP99"),
        "settles": phase.get("settles"),
        "trace": str(out / "record.trace"),
        "scrollMovements": during.get("scrollMovements"),
        "residentPeakBytes": during.get("residentPeakBytes"),
        "residentSamplingError": during.get("residentSamplingError"),
        "residentSampleCount": during.get("residentSampleCount"),
        "residentSamplingComplete": during.get("residentSamplingComplete"),
        "windowFrontBefore": during.get("windowFrontBefore"),
        "submitPlusRenderP99": None if phase.get("updateP99") is None or phase.get("renderP99") is None else phase["updateP99"] + phase["renderP99"],
        "performanceIssueAt120Hz": bool(phase.get("hitches")) or ((phase.get("updateP99") or 0) + (phase.get("renderP99") or 0) > FRAME_MS),
    }
    if "windowFront" in during:
        measured["windowFront"] = during["windowFront"]
    if "responsiveScrolling" in during:
        measured["responsiveScrolling"] = during["responsiveScrolling"]
    return measured, during, out / "record.trace"


COLD = {}


def cold_recording():
    if "error" in COLD:
        raise COLD["error"]
    if "measured" not in COLD:
        try:
            COLD["measured"], COLD["during"], COLD["trace"] = record_scroll("scroll-cold")
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
    return main_thread_samples(data["trace"]), data["during"]


def scene_settle():
    data = cold_recording()
    measured = data["measured"]
    return {"settleRequestLatencyP99": measured.get("settleRequestLatencyP99"), "settles": measured.get("settles")}, data["during"]


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


def wait_first_screen(client, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = window_of(client.request("state")).get("firstScreenThumbnailMilliseconds")
        if isinstance(value, (int, float)):
            return float(value)
        time.sleep(0.02)
    return None


def first_screen_samples(path, name, times=20):
    app = App(name, empty_cache=True).start()
    try:
        app.client.request("open", {"path": path}, timeout=180)
        wait_first_screen(app.client)
        wait_idle(app.client, 180)
    finally:
        app.stop()
    samples = []
    for _ in range(times):
        app = App(name, empty_cache=False).start()
        try:
            app.client.request("open", {"path": path}, timeout=180)
            samples.append(wait_first_screen(app.client))
        finally:
            app.stop()
    numeric = [value for value in samples if value is not None]
    return {"samples": samples, "count": len(numeric), "p95": p95(numeric) if len(numeric) == times else None}


def scene_cached_first_screen():
    local = first_screen_samples(str(ensure_sample()), "cached-first-screen-local")
    measured = {"localP95": local["p95"], "localSamples": local["count"], "localMilliseconds": local["samples"], "protocol": "nfs"}
    mount, error = ensure_nfs()
    album = find_samples(mount)[0] if mount else None
    if not mount or not album:
        measured["unavailable"] = True
        measured["nfsError"] = error or "NFS 上没有找到 JPEG 目录"
        smb_album = find_samples(SMB_ROOT)[0] if SMB_ROOT.is_dir() else None
        supplement = {"protocol": "smb"}
        if smb_album:
            smb = first_screen_samples(smb_album, "cached-first-screen-smb")
            supplement.update(p95=smb["p95"], samples=smb["count"], path=smb_album)
        else:
            supplement["error"] = "没有找到 /Volumes/Picture 上的 JPEG 目录"
        measured["supplement"] = supplement
        return measured
    remote = first_screen_samples(album, "cached-first-screen-nfs")
    measured.update(nfsP95=remote["p95"], nfsSamples=remote["count"], nfsMilliseconds=remote["samples"], nfsAlbum=album)
    return measured


def scene_large_dir():
    if not TREE.is_dir():
        return {"unavailable": True, "error": f"没有目录 {TREE}"}
    app = App("large-dir", empty_cache=True).start()
    try:
        client = app.client
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
            "openOk": bool(opened and opened.get("ok")),
        }
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
    return [volume for volume in state.get("volumes") or [] if str(NFS_FAULT) in volume.get("root", "")]


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
                started = time.monotonic()
                app.client.request("state", timeout=2)
                supplement.update(path=smb, roundTripMilliseconds=(time.monotonic() - started) * 1000)
            except (RuntimeError, TimeoutError, OSError) as exc:
                supplement["error"] = str(exc)
            finally:
                app.stop()
        else:
            supplement["error"] = "没有找到 /Volumes/Picture 上的 JPEG 目录"
        return {"unavailable": True, "nfsError": error or "NFS 上没有找到 JPEG 目录", "supplement": supplement, "protocol": "nfs"}
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
        wait_frame(app.client, opened["frame"])
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
                while time.monotonic() - started < seconds:
                    sent = time.monotonic()
                    try:
                        state = app.client.request("state", timeout=1)
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
                                   "errorSeconds": error_at, "retryExactSucceeded": recovered})
                if not recovered:
                    return {"protocol": "nfs", "stateSamples": len(rtts), "injections": injections,
                            "maxRoundTripMilliseconds": max(rtts), "retrySucceeded": False,
                            "errorWithin10Seconds": False, "quitSeconds": None,
                            "error": "故障恢复后当前页未重新显示 exact，停止后续注入"}
        # 独立验证退出：再次暂停代理，确认未读页存在在途I/O，保持暂停直到目标PID退出。
        control_send(ready["controlPort"], "pause")
        quit_frame = arm_fault_read(app.client)
        quit_read = False
        quit_volumes = None
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            state = app.client.request("state", timeout=1)
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
            "maxRoundTripMilliseconds": max(rtts) if rtts else None,
            "errorWithin10Seconds": len(required) == 4 and all(item["errorSeconds"] is not None and item["errorSeconds"] <= 10 for item in required),
            "injections": injections, "retrySucceeded": retry,
            "quitSeconds": quit_seconds, "quitReadInFlight": quit_read,
            "quitFrame": quit_frame, "quitInFlightVolumes": quit_volumes,
            "quitExitedNormally": quit_normal,
            "quitExitCode": quit_code,
            "quitPID": quit_pid,
        }
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


def scene_memory():
    sample = str(ensure_sample())
    other = str(HUGE_DIR)
    app = App("memory-30min", empty_cache=False).start()
    samples, elapsed, memory = [], [], []
    index = 0
    started = None
    try:
        app.client.phase = "memory-30min:initial-open"
        app.client.request("open", {"path": sample}, timeout=120)
        direction = 1
        started = time.monotonic()
        end = started + 30 * 60
        tick = started
        pending = None
        budgets = None
        while time.monotonic() < end:
            app.client.phase = f"memory-30min:sample-{len(samples)}"
            state = app.client.request("state", timeout=10)
            samples.append(state.get("residentBytes"))
            memory.append(state.get("memory"))
            elapsed.append(time.monotonic() - started)
            budgets = state.get("cacheBudgets")
            if pending in app.client.inbox:
                response = app.client.inbox.pop(pending)
                app.client.pending.pop(pending, None)
                if not response.get("ok"):
                    raise RuntimeError(response.get("error") or response)
                pending = None
            if pending is None:
                action = index % 6
                window = window_of(state)
                if action < 3:
                    app.client.phase = f"memory-30min:flip-{index}"
                    if window.get("browseMode") != "paged":
                        app.client.request("perform", {"command": "view.paged"}, timeout=10)
                    frame, count = int(window["frame"]), int(window["frameCount"])
                    if count > 1 and ((direction > 0 and frame >= count - 1) or (direction < 0 and frame <= 0)):
                        direction = -direction
                    pending = app.client.send("perform", {"command": "frame.next" if direction > 0 else "frame.previous"})
                elif action == 3:
                    app.client.phase = f"memory-30min:scroll-{index}"
                    if window.get("browseMode") != "waterfall":
                        app.client.request("perform", {"command": "view.waterfall"}, timeout=10)
                    pending = app.client.send("scroll", {"dy": -12, "durationMs": 500, "intervalMs": 8})
                else:
                    app.client.phase = f"memory-30min:switch-book-{index}"
                    pending = app.client.send("open", {"path": other if index % 12 == 4 else sample})
                index += 1
            tick += 1
            if tick < time.monotonic():
                tick = time.monotonic()
            time.sleep(max(0, min(tick, end) - time.monotonic()))
        duration = time.monotonic() - started
        pid = str(app.pid)
        leaks = subprocess.run(["leaks", pid], capture_output=True, text=True, timeout=180)
        vmmap = subprocess.run(["vmmap", "--summary", pid], capture_output=True, text=True, timeout=60)
        leaks_output = leaks.stdout + leaks.stderr
        vmmap_output = vmmap.stdout + vmmap.stderr
        (app.root / "leaks.txt").write_text(leaks_output)
        (app.root / "vmmap.txt").write_text(vmmap_output)
        measured = {"residentBytes": samples, "sampleElapsedSeconds": elapsed, "durationSeconds": duration, "memory": memory,
                "cacheBudgets": budgets, "actions": index, **parse_leaks(leaks_output),
                "leaksReturnCode": leaks.returncode, "leaksOutput": leaks_output,
                "vmmapReturnCode": vmmap.returncode, "vmmap": vmmap_output}
        return {**measured, **memory_metrics(measured)}
    except Exception as exc:
        measured = {"residentBytes": samples, "sampleElapsedSeconds": elapsed, "actions": index, "memory": memory,
                    "durationSeconds": time.monotonic() - started if started is not None else 0}
        measured.update(memory_metrics(measured))
        if isinstance(exc, DebugTimeout):
            measured["diagnostic"] = exc.detail
        raise MeasurementError(str(exc), measured) from exc
    finally:
        app.stop()


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


def prepare_scroll(scene, socket_path):
    client = DebugClient(socket_path, phase=scene + ":prepare")
    try:
        client.request("open", {"path": str(ensure_sample())}, timeout=180)
        client.request("perform", {"command": "view.waterfall"})
        client.request("resize", {"width": 1400, "height": 900})
        if scene == "scroll-cached":
            wait_idle(client, 180)
            for _ in range(12):
                client.request("scroll", {"dy": -900, "steps": 6, "intervalMs": 16}, timeout=30)
            wait_idle(client, 180)
        elif scene != "scroll-cold":
            raise SystemExit(f"不是滚动场景：{scene}")
        client.request("resize", {"width": 1400, "height": 900})
        print(json.dumps({"windowFront": window_of(client.request("state")).get("windowFront")}))
    finally:
        client.close()


def run_scroll(scene, socket_path, outdir, automatic=True, seconds=60):
    if scene not in ("scroll-cached", "scroll-cold"):
        raise SystemExit(f"不是滚动场景：{scene}")
    client = DebugClient(socket_path, phase=scene + ":record")
    out = Path(outdir)
    before = sample_conditions()
    mark = input_mark(DURING_EVENTS)
    started = trace_clock_seconds()
    resident, rss_error = [], None
    try:
        window_before = json.loads((out / "window-before.json").read_text())
        pending = client.send("scroll", {"dy": -12, "durationMs": int(seconds * 1000), "intervalMs": 8}) if automatic else None
        if not automatic:
            print(f"正在录制 {seconds} 秒：请在 MacView 中用触控板滚动、缩放。", flush=True)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if rss_error is None:
                try:
                    value = client.request("state", timeout=5).get("residentBytes")
                    if not isinstance(value, (int, float)) or value <= 0:
                        raise ValueError("residentBytes 缺失或无效")
                    resident.append(value)
                except (TimeoutError, ConnectionError, OSError, ValueError) as exc:
                    rss_error = getattr(exc, "detail", {"error": str(exc)})
            time.sleep(min(1, max(0, deadline - time.monotonic())))
        scroll = client.wait(pending, 30).get("result", {}) if automatic else {}
        time.sleep(0.5)
        during = sample_conditions()
        during["before"] = before
        during["screen"]["inputDuringRun"] = input_mark(DURING_EVENTS) > mark + 0.5
        # 连续手势的响应已经带回窗口和响应式滚动状态，不为辅助字段再等一次state。
        window = scroll if automatic else window_of(client.request("state", timeout=5))
        during["windowFrontBefore"] = window_before.get("windowFront")
        during["windowFront"] = window_before.get("windowFront") is True and window.get("windowFront") is True and scroll.get("windowFront", True)
        during["residentPeakBytes"] = max(resident, default=None)
        during["residentSamplingError"] = rss_error
        during["residentSampleCount"] = len(resident)
        during["residentSamplingComplete"] = rss_error is None and len(resident) >= math.ceil(seconds)
        during["scrollMovements"] = scroll.get("scrollMovements")
        during["scrollEvents"] = scroll.get("events")
        during["driver"] = "synthetic" if automatic else "trackpad"
        during["responsiveScrolling"] = window.get("responsiveScrolling")
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
    # 录制准备和构建之后的实际开跑环境；复用冷录制的其他场景也必须引用同一段环境。
    for key in ("load", "displayMode", "refreshHz", "screen"):
        if key in (during.get("before") or {}):
            merged[key] = during["before"][key]
    screen = during.get("screen") or {}
    merged["screenAfter"] = screen
    # 开始时的空闲秒数保留。滚动之后滚轮空闲会变成 0，那不是用户输入。
    merged["screen"]["inputDuringRun"] = bool(screen.get("inputDuringRun"))
    if "locked" in screen:
        initial = merged["screen"].get("locked")
        merged["screen"]["locked"] = False if initial is False and screen["locked"] is False else (True if initial or screen["locked"] else None)
    if "externalDisplay" in screen:
        merged["screen"]["externalDisplay"] = bool(merged["screen"].get("externalDisplay") or screen["externalDisplay"])
    # 负载只看开跑前的 oneMinute。跑起来之后的值含场景自己和 xctrace，只留在 during。
    if during.get("load") and during["load"].get("oneMinute") is not None:
        merged["load"]["during"] = during["load"]["oneMinute"]
    if during.get("refreshHz") is not None:
        merged["refreshHzAfter"] = during["refreshHz"]
    if during.get("displayMode"):
        merged["displayModeAfter"] = during["displayMode"]
    return merged


def write_report(out, scene, commit, env, measured, verdict):
    path = Path(out) / f"S2-T2-{scene}.json"
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
        "tiles-cancel": scene_tiles_cancel,
        "panel-restart": scene_panel_restart,
    }[scene]
    paths = []
    if scene in ("first-image", "preloaded-flip", "scroll-cached", "scroll-cold", "main-thread", "settle", "cached-first-screen", "memory-30min"):
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
    during = None
    mark = None
    if scene in FOREGROUND:
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
        if during is None and mark is not None:
            during = sampled_during(mark)
        env = merge_during(env, during)
        measured["unavailable"] = True
        verdict = judge(scene, measured, env)
        write_report(out, scene, commit, env, measured, verdict)
        return
    # 滚动场景用录制期间的 during.json，里面的输入不含滚轮。其余前台场景在这里补一次。
    if during is None and mark is not None:
        during = sampled_during(mark)
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
    parser.add_argument("--run-scroll", nargs=3, metavar=("SCENE", "SOCKET", "OUT"))
    parser.add_argument("--observe-scroll", nargs=3, metavar=("SCENE", "SOCKET", "OUT"))
    parser.add_argument("--smoke-scroll", nargs=3, metavar=("SCENE", "SOCKET", "OUT"))
    parser.add_argument("--quit-app", metavar="SOCKET")
    parser.add_argument("--launch-app", nargs=5, metavar=("SOCKET", "SUPPORT", "CACHE", "LAYOUT", "LOG"))
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
    if args.quit_app:
        quit_app(args.quit_app)
        return 0
    if args.prepare_scroll:
        prepare_scroll(args.prepare_scroll[0], args.prepare_scroll[1])
        return 0
    if args.run_scroll:
        run_scroll(*args.run_scroll)
        return 0
    if args.observe_scroll:
        run_scroll(*args.observe_scroll, automatic=False)
        return 0
    if args.smoke_scroll:
        run_scroll(*args.smoke_scroll, automatic=False, seconds=1)
        return 0
    scenes = args.scenes or list(SCENES)
    unknown = [scene for scene in args.scenes if scene not in SCENES]
    if unknown:
        raise SystemExit(f"未知场景：{', '.join(unknown)}")
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
