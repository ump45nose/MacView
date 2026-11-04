#!/usr/bin/env python3
"""xctrace 原始文件准入与收尾；只删除本次录制后新增且没有打开者的文件。"""

import argparse
import json
import shutil
import subprocess
from pathlib import Path

MIN_FREE_BYTES = 40_000_000_000
DATA_VOLUME = Path("/System/Volumes/Data")


def raw_files(directory):
    return {str(path): {"bytes": path.lstat().st_size, "allocatedBytes": path.lstat().st_blocks * 512}
            for path in sorted(directory.glob("instruments*.ktrace")) if path.is_file() and not path.is_symlink()}


def save(path, report):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


def begin(path):
    directory = Path(subprocess.check_output(["getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip())
    free = shutil.disk_usage(DATA_VOLUME).free
    report = {"rawDirectory": str(directory), "existing": raw_files(directory),
              "space": {"volume": str(DATA_VOLUME), "freeBytes": free, "requiredBytes": MIN_FREE_BYTES},
              "ready": free >= MIN_FREE_BYTES, "added": [], "cleanupComplete": False}
    if not report["ready"]:
        report.update(verdict="environment", reason="数据卷可用空间不足 40 GB")
    save(path, report)
    return report


def finish(path):
    report = json.loads(path.read_text())
    if report.get("cleanupComplete"):
        return report
    directory = Path(report["rawDirectory"])
    current = raw_files(directory)
    added = current.keys() - report["existing"].keys()
    results = {item["path"]: item for item in report.get("added", [])}
    for name in sorted(added):
        if results.get(name, {}).get("result") == "deleted":
            continue
        raw = Path(name)
        info = {"path": name, **current[name]}
        try:
            opened = subprocess.run(["/usr/sbin/lsof", "-nP", "--", name], capture_output=True, text=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as error:
            results[name] = {**info, "result": "lsof-failed", "error": str(error)}
            continue
        if opened.returncode == 1 and not opened.stdout and not opened.stderr:
            try:
                raw.unlink()
                info["result"] = "deleted"
            except OSError as error:
                info.update(result="delete-failed", error=str(error))
        else:
            info.update(result="in-use" if opened.returncode == 0 else "lsof-failed",
                        lsofExitCode=opened.returncode, lsof=opened.stdout, lsofError=opened.stderr)
        results[name] = info
    for name, info in results.items():
        if name not in current and info["result"] not in ("deleted", "absent"):
            info.update(previousResult=info["result"], result="absent")
    results = [results[name] for name in sorted(results)]
    report.update(added=results, addedBytes=sum(item["bytes"] for item in results),
                  deletedBytes=sum(item["bytes"] for item in results if item["result"] == "deleted"),
                  cleanupComplete=all(item["result"] in ("deleted", "absent") for item in results))
    save(path, report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("begin", "finish"))
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    report = begin(args.evidence) if args.action == "begin" else finish(args.evidence)
    if args.action == "begin" and not report["ready"]:
        print(report["reason"])
        return 3
    if args.action == "finish" and not report["cleanupComplete"]:
        print("本次新增的 xctrace 原始文件仍有占用或未能清理，见 " + str(args.evidence))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
