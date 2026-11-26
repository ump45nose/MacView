#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "用法：scripts/install.sh local|ssh <主机> (--zip PATH | --build) [--dry-run]" >&2
  exit 2
}
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
[ "$#" -ge 1 ] || usage
target="$1"; shift
host=""
case "$target" in
  local) ;;
  ssh)
    [ "$#" -ge 1 ] || usage
    host="$1"; shift
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || usage ;;
  *) usage ;;
esac
zip=""
build=0
dry=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --zip)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$zip" ] && [ "$build" -eq 0 ] || usage
      zip="$2"; shift 2 ;;
    --build)
      [ -z "$zip" ] && [ "$build" -eq 0 ] || usage
      build=1; shift ;;
    --dry-run) dry=1; shift ;;
    *) usage ;;
  esac
done
[ -n "$zip" ] || [ "$build" -eq 1 ] || usage

inspect_app() {
  local app="$1" description identity commit bundle_id
  [ -d "$app" ] && [ ! -L "$app" ] || { echo "包中缺少 MacView.app" >&2; return 1; }
  /usr/bin/codesign --verify --deep --strict "$app"
  bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
  [ "$bundle_id" = io.github.ump45nose.MacView ] || { echo "包里的 App 不是 MacView" >&2; return 1; }
  description=$(/usr/bin/codesign -dv --verbose=4 "$app" 2>&1)
  if printf '%s\n' "$description" | grep -q '^Signature=adhoc$'; then
    identity="ad-hoc"
  else
    identity=$(printf '%s\n' "$description" | sed -n 's/^Authority=//p' | sed -n '1p')
    [ -n "$identity" ] || { echo "无法识别包的签名身份" >&2; return 1; }
  fi
  commit=$(/usr/libexec/PlistBuddy -c 'Print :MVSourceCommit' "$app/Contents/Info.plist")
  [[ "$commit" =~ ^[0-9a-f]{40,64}(-dirty)?$ ]] || { echo "包内 MVSourceCommit 无效" >&2; return 1; }
  printf '签名身份：%s\nMVSourceCommit：%s\n' "$identity" "$commit"
}

# 在目标设备上运行；暂存与 /Applications 同一卷，才能原子替换目录。
install_bundle() (
  set -euo pipefail
  local package="$1" destination="/Applications/MacView.app" scratch app result
  scratch=$(mktemp -d /Applications/.MacView-install.XXXXXXXX)
  trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
  /usr/bin/ditto -x -k "$package" "$scratch"
  app="$scratch/MacView.app"
  inspect_app "$app"
  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -d "$destination" ]; }; then
    echo "目标不是可替换的 MacView App，保留现状。" >&2; exit 1
  fi
  if [ -d "$destination" ] &&
      [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)" != io.github.ump45nose.MacView ]; then
    echo "现有目标不是 MacView，保留现状。" >&2; exit 1
  fi

  # 正常退出；Apple Event 或进程退出超时都终止安装，不强杀。
  if /usr/bin/pgrep -x MacView >/dev/null; then
    /usr/bin/osascript <<'APPLESCRIPT'
with timeout of 15 seconds
  tell application id "io.github.ump45nose.MacView" to quit
end timeout
APPLESCRIPT
    for ((attempt=0; attempt<30; attempt++)); do
      /usr/bin/pgrep -x MacView >/dev/null || break
      sleep 1
    done
    if /usr/bin/pgrep -x MacView >/dev/null; then
      echo "MacView 正常退出超时，未替换 App。" >&2; exit 1
    fi
  fi

  if python3 - "$app" "$destination" <<'PY'
import ctypes
import os
import subprocess
import sys

source, target = map(os.fsencode, sys.argv[1:])
rename = ctypes.CDLL(None, use_errno=True).renameatx_np
rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
rename.restype = ctypes.c_int
AT_FDCWD = -2
RENAME_SWAP, RENAME_EXCL = 0x2, 0x4

def atomic_rename(left, right, flags):
    if rename(AT_FDCWD, left, AT_FDCWD, right, flags):
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code))

had_previous = os.path.lexists(target)
atomic_rename(source, target, RENAME_SWAP if had_previous else RENAME_EXCL)
try:
    subprocess.run(["/usr/bin/xattr", "-dr", "com.apple.quarantine", os.fsdecode(target)], check=True)
except (OSError, subprocess.CalledProcessError):
    # 隔离属性处理失败时原子恢复旧版，避免留下半完成安装。
    try:
        atomic_rename(source, target, RENAME_SWAP) if had_previous else atomic_rename(target, source, RENAME_EXCL)
    except OSError:
        print("自动恢复失败；保留暂存目录中的旧 App。", file=sys.stderr)
        sys.exit(3)
    print("去除隔离属性失败，已恢复原状。", file=sys.stderr)
    sys.exit(1)
PY
  then
    result=0
  else
    result=$?
  fi
  if [ "$result" -eq 3 ]; then
    trap - EXIT
    echo "保留用于恢复的暂存目录：$scratch" >&2
    exit 3
  elif [ "$result" -ne 0 ]; then
    exit "$result"
  fi
  echo "已安装 /Applications/MacView.app；未改动用户支持目录。"
)

if [ "$dry" -eq 1 ] && [ "$build" -eq 1 ]; then
  commit=$(git -C "$root" rev-parse HEAD)
  if [ -n "$(git -C "$root" status --porcelain)" ]; then commit="$commit-dirty"; fi
  printf '将当场运行 scripts/package.sh --local 生成唯一新包。\n签名身份：MacView Local Development（计划）\nMVSourceCommit：%s（构建时核对）\n' "$commit"
elif [ "$build" -eq 1 ]; then
  mkdir -p "$root/build"
  scratch=$(mktemp -d "$root/build/install.XXXXXXXX")
  trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
  "$root/scripts/package.sh" --local --output "$scratch"
  # 独有的新目录，绝不根据时间从以前的发布包里挑选。
  packages=("$scratch"/*.zip)
  [ "${#packages[@]}" -eq 1 ] && [ -f "${packages[0]}" ] || { echo "本次构建没有产生唯一的 zip" >&2; exit 1; }
  zip="${packages[0]}"
else
  [ -f "$zip" ] || { echo "指定 zip 不存在。" >&2; exit 2; }
  case "$zip" in /*) ;; *) zip="$PWD/$zip" ;; esac
fi

if [ "$dry" -eq 1 ]; then
  if [ -n "$zip" ]; then
    mkdir -p "$root/build"
    scratch=$(mktemp -d "$root/build/install-dry.XXXXXXXX")
    trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
    /usr/bin/ditto -x -k "$zip" "$scratch"
    inspect_app "$scratch/MacView.app"
  fi
  if [ "$target" = ssh ]; then
    printf '[干跑] ssh %s：传输明确指定或本次刚构建的 zip，在对端解包。\n' "$host"
  else
    echo "[干跑] local：使用明确指定或本次刚构建的 zip。"
  fi
  echo "[干跑] 验证签名 → osascript 正常退出 MacView（超时停止） → 原子替换 /Applications/MacView.app → xattr 去隔离。"
  echo "[干跑] 不启动、退出或替换 App，不连接远端，不触碰用户支持目录。"
  exit 0
fi

if [ "$target" = local ]; then
  install_bundle "$zip"
else
  # 对端暂存目录是这次安装新建的，绝不重用以前的文件。
  remote_scratch=$(ssh "$host" 'umask 077; mktemp -d /Applications/.MacView-transfer.XXXXXXXX')
  [[ "$remote_scratch" =~ ^/Applications/\.MacView-transfer\.[A-Za-z0-9]+$ ]] || { echo "无法取得远端暂存目录。" >&2; exit 1; }
  cleanup_remote() {
    ssh "$host" "python3 -c 'import shutil,sys; shutil.rmtree(sys.argv[1])' '$remote_scratch'" >/dev/null 2>&1 || true
  }
  # 若 --build 已有本机暂存目录，仍保留其清理。
  trap 'cleanup_remote; if [ "$build" -eq 1 ]; then python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"; fi' EXIT
  scp -- "$zip" "$host:$remote_scratch/package.zip"
  printf '%s\n' 'set -euo pipefail' "$(declare -f inspect_app install_bundle)" 'install_bundle "$1"' |
    ssh "$host" "bash -s -- '$remote_scratch/package.zip'"
fi
