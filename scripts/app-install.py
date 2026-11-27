"""Replace a signed macOS app, check its running process, retain one rollback copy.

Adapted from Lasso's scripts/app-install.py (MIT, same author).
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time


def info(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())


def pids(executable):
    processes = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
    result = []
    for line in processes.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and (fields[1] == str(executable) or fields[1].startswith(str(executable) + ' ')):
            result.append(int(fields[0]))
    return result


def stop(app, force=False):
    if not app.exists():
        return
    executable = app / 'Contents/MacOS' / info(app)['CFBundleExecutable']
    for pid in pids(executable):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 15
    while pids(executable):
        if time.monotonic() >= deadline:
            if not force:
                raise RuntimeError('application did not exit: ' + str(app))
            print('Normal exit timed out; force-stopping ' + str(app), flush=True)
            for pid in pids(executable):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 5
            while pids(executable):
                if time.monotonic() >= deadline:
                    raise RuntimeError('application survived force exit: ' + str(app))
                time.sleep(0.25)
            return
        time.sleep(0.25)


def start(app):
    # -n: a running development build with the same bundle identifier must not stand in for this copy.
    subprocess.run(['/usr/bin/open', '-g', '-n', str(app)], check=True)
    executable = app / 'Contents/MacOS' / info(app)['CFBundleExecutable']
    deadline, alive_since = time.monotonic() + 25, None
    while time.monotonic() < deadline:
        running = pids(executable)
        if running:
            alive_since = alive_since or time.monotonic()
            if time.monotonic() - alive_since >= 5:
                return running
        else:
            alive_since = None
        time.sleep(0.5)
    raise RuntimeError('application failed its startup check: ' + str(app))


def install(source, destination, launch=True, backup_root=None, force_exit=False):
    source, destination = Path(source).resolve(), Path(destination).absolute()
    metadata = info(source)
    if destination.is_symlink():
        raise ValueError('installation destination is a symlink')
    if destination.exists() and info(destination)['CFBundleIdentifier'] != metadata['CFBundleIdentifier']:
        raise ValueError('installed application has a different bundle identifier')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(source)], check=True)
    backups = Path(backup_root) if backup_root else Path.home() / 'Library/Application Support/MacAutomation/backups/apps' / metadata['CFBundleIdentifier']
    backups.mkdir(parents=True, exist_ok=True)
    previous = backups / 'previous.app'
    destination.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='.app-install-', dir=str(destination.parent)))
    staged, old = work / destination.name, work / 'old.app'
    replaced = False
    try:
        subprocess.run(['/usr/bin/ditto', str(source), str(staged)], check=True)
        stop(destination, force=force_exit)
        if destination.exists():
            destination.rename(old)
        try:
            staged.rename(destination)
            replaced = True
            running = start(destination) if launch else []
        except Exception as error:
            if replaced:
                stop(destination, force=True)
                shutil.rmtree(destination)
            if old.exists():
                old.rename(destination)
                if launch:
                    start(destination)
                raise RuntimeError('installation failed; restored and restarted previous app: ' + str(error)) from error
            raise
        if old.exists():
            if previous.exists():
                shutil.rmtree(previous)
            old.rename(previous)
        executable = destination / 'Contents/MacOS' / metadata['CFBundleExecutable']
        result = {'status': 'healthy' if launch else 'installed', 'destination': str(destination),
                  'version': metadata.get('CFBundleShortVersionString'), 'bundleIdentifier': metadata['CFBundleIdentifier'],
                  'pids': running, 'executableSHA256': hashlib.sha256(executable.read_bytes()).hexdigest(),
                  'previous': str(previous) if previous.exists() else None}
        receipt = os.environ.get('MACAUTO_INSTALL_RECEIPT')
        if receipt:
            Path(receipt).write_text(json.dumps(result, indent=2) + '\n')
        return result
    finally:
        # Never discard the only previous app if restoring it failed.
        if not old.exists():
            shutil.rmtree(work)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--no-launch', action='store_true')
    parser.add_argument('--force-exit', action='store_true')
    args = parser.parse_args()
    print(json.dumps(install(args.source, args.destination, not args.no_launch, force_exit=args.force_exit)))


if __name__ == '__main__':
    main()
