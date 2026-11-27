#!/usr/bin/env bash
# 交付目录里的 install.sh（由 scripts/delivery.sh 放入）。在目标 Mac 的图形会话里运行：
# 用本机 MacView Local Development 证书重签，正常退出旧版后替换 /Applications/MacView.app，
# 后台启动做启动检查，失败时恢复并重启上一版。回执写到 $MACAUTO_INSTALL_RECEIPT。
set -euo pipefail

usage() {
  echo "用法：./install.sh [--dry-run] [--no-launch]" >&2
  exit 2
}
root=$(cd -- "$(dirname -- "$0")" && pwd -P)
dry=0
launch=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1; shift ;;
    --no-launch) launch=0; shift ;;
    *) usage ;;
  esac
done
destination="/Applications/MacView.app"

commit=$(python3 - "$root" <<'PY'
import json, pathlib, platform, subprocess, sys
root = pathlib.Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
if manifest.get('project') != 'macview' or manifest.get('artifact') != 'MacView.app':
    sys.exit('不是 MacView 交付目录。')
if manifest['arch'] != platform.machine():
    sys.exit('产物架构与当前 Mac 不一致。')
current = [int(x) for x in subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True).split('.')]
minimum = [int(x) for x in manifest['minimumSystemVersion'].split('.')]
if current + [0] * 3 < minimum + [0] * 3:
    sys.exit('此产物要求 macOS ' + manifest['minimumSystemVersion'] + ' 或更高版本。')
print(manifest['sourceCommit'])
PY
)
[ -d "$root/MacView.app" ] || { echo "交付目录缺少 MacView.app" >&2; exit 1; }
"$root/support/sign-app.sh" --local --check
if [ "$dry" -eq 1 ]; then
  printf '{"action":"install","dryRun":true,"destination":"%s","identity":"MacView Local Development","launch":%s,"sourceCommit":"%s"}\n' \
    "$destination" "$([ "$launch" -eq 1 ] && echo true || echo false)" "$commit"
  exit 0
fi

# 暂存在 /Applications 同一卷，替换时只是改名。
scratch=$(mktemp -d /Applications/.MacView-delivery.XXXXXXXX)
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
staged="$scratch/MacView.app"
/usr/bin/ditto "$root/MacView.app" "$staged"
"$root/support/sign-app.sh" --local "$staged"
[ "$(/usr/libexec/PlistBuddy -c 'Print :MVSourceCommit' "$staged/Contents/Info.plist")" = "$commit" ] ||
  { echo "App 的 MVSourceCommit 与交付清单不符。" >&2; exit 1; }

# 只处理 /Applications 里这一份：开发中的 Debug 构建和自检进程同名同包标识，不能被波及。
# 先请求正常退出，让会话与设置照常保存；超时就停止，不强杀，保留旧版。
installed_running() {
  /usr/bin/pgrep -f "^$destination/Contents/MacOS/MacView( |\$)" >/dev/null
}
if installed_running; then
  /usr/bin/osascript - "$destination" <<'APPLESCRIPT'
on run argv
  with timeout of 15 seconds
    tell application (item 1 of argv) to quit
  end timeout
end run
APPLESCRIPT
  for ((attempt=0; attempt<30; attempt++)); do
    installed_running || break
    sleep 1
  done
  if installed_running; then
    echo "MacView 正常退出超时，未替换 App。" >&2
    exit 1
  fi
fi

args=("$root/support/app-install.py" "$staged" "$destination")
[ "$launch" -eq 1 ] || args+=(--no-launch)
/usr/bin/python3 "${args[@]}"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination" >/dev/null 2>&1 || true
