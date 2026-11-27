#!/usr/bin/env bash
# macauto 双机交付的入口：产出一个可移植的交付目录，App 在各台 Mac 上用本机证书重签后安装。
#   build --output ABS_DIR            本机 Release 构建（ad-hoc）后整理成交付目录
#   stage --zip ABS_ZIP --output ABS_DIR  把 package.sh --adhoc 的 zip 整理成交付目录（CI 用）
# 交付目录：MacView.app、THIRD_PARTY_NOTICES、install.sh、support/、manifest.json。
set -euo pipefail

usage() {
  echo "用法：scripts/delivery.sh build --output ABS_DIR | stage --zip ABS_ZIP --output ABS_DIR" >&2
  exit 2
}
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
[ "$#" -ge 1 ] || usage
action="$1"; shift
output=""
zip=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) [ "$#" -ge 2 ] || usage; output="$2"; shift 2 ;;
    --zip) [ "$#" -ge 2 ] || usage; zip="$2"; shift 2 ;;
    *) usage ;;
  esac
done
case "$action" in
  build) [ -z "$zip" ] || usage ;;
  stage) case "$zip" in /*) [ -f "$zip" ] || { echo "zip 不存在：$zip" >&2; exit 1; } ;; *) usage ;; esac ;;
  *) usage ;;
esac
case "$output" in /*) ;; *) usage ;; esac
if [ -e "$output" ] && [ -n "$(ls -A "$output")" ]; then
  echo "交付目录非空，拒绝覆盖：$output" >&2
  exit 1
fi

mkdir -p "$root/build" "$(dirname "$output")"
scratch=$(mktemp -d "$root/build/delivery.XXXXXXXX")
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT

if [ "$action" = build ]; then
  [ -z "$(git -C "$root" status --porcelain)" ] || { echo "工作区有改动；交付只从干净的提交构建。" >&2; exit 1; }
  "$root/scripts/package.sh" --adhoc --output "$scratch/package"
  packages=("$scratch"/package/*.zip)
  [ "${#packages[@]}" -eq 1 ] && [ -f "${packages[0]}" ] || { echo "本次构建没有产生唯一的 zip" >&2; exit 1; }
  zip="${packages[0]}"
fi

bundle="$scratch/bundle"
mkdir -p "$bundle/support"
/usr/bin/ditto -x -k "$zip" "$bundle"
app="$bundle/MacView.app"
[ -d "$app" ] && [ -f "$bundle/THIRD_PARTY_NOTICES" ] || { echo "zip 里缺少 MacView.app 或 THIRD_PARTY_NOTICES" >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$app"
install -m 0755 "$root/scripts/delivery-install.sh" "$bundle/install.sh"
install -m 0755 "$root/scripts/sign-app.sh" "$bundle/support/sign-app.sh"
install -m 0644 "$root/scripts/app-install.py" "$bundle/support/app-install.py"

python3 - "$bundle" <<'PY'
import json, pathlib, plistlib, re, subprocess, sys
bundle = pathlib.Path(sys.argv[1])
info = plistlib.loads((bundle / 'MacView.app/Contents/Info.plist').read_bytes())
if info.get('CFBundleIdentifier') != 'io.github.ump45nose.MacView':
    sys.exit('包里的 App 不是 MacView')
commit = info.get('MVSourceCommit', '')
if not re.fullmatch(r'[0-9a-f]{40,64}', commit):
    sys.exit('MVSourceCommit 无效或带 -dirty，交付只接受干净提交：' + commit)
executable = bundle / 'MacView.app/Contents/MacOS' / info['CFBundleExecutable']
arch = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).split()
manifest = {'project': 'macview', 'artifact': 'MacView.app', 'version': info['CFBundleShortVersionString'],
            'sourceCommit': commit, 'arch': 'arm64' if arch == ['arm64'] else ' '.join(arch),
            'minimumSystemVersion': info['LSMinimumSystemVersion']}
(bundle / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest))
PY

if [ -e "$output" ]; then rmdir "$output"; fi
mv "$bundle" "$output"
echo "交付目录：$output"
