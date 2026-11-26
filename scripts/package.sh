#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "用法：scripts/package.sh (--local | --adhoc) [--version X.Y.Z] [--output DIR]" >&2
  exit 2
}
root=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
mode=""
version=""
output="$root/build/release"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --local|--adhoc)
      [ -z "$mode" ] || usage
      mode="${1#--}"; shift ;;
    --version)
      [ "$#" -ge 2 ] && [ -z "$version" ] && [ -n "$2" ] || usage
      version="$2"; shift 2 ;;
    --output)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      output="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$mode" ] || usage
if [ -z "$version" ]; then
  version=$(awk '$1=="MARKETING_VERSION:" {print $2; exit}' "$root/project.yml" | tr -d '"')
fi
# 标签允许 rc 等预发布后缀；文件名不得含路径或 shell 特殊字符。
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9][A-Za-z0-9.+-]*)?$ ]] || usage
case "$output" in /*) ;; *) output="$PWD/$output" ;; esac
cd "$root"

identity="-"
signing_args=()
if [ "$mode" = local ]; then
  name="MacView Local Development"
  if ! keychain=$(/usr/bin/security login-keychain 2>/dev/null); then
    echo "无法定位登录钥匙串，请先解锁后重试。" >&2
    exit 1
  fi
  keychain=$(printf '%s' "$keychain" | sed 's/^[[:space:]]*"//;s/"[[:space:]]*$//')
  # 自签证书不属于公开信任链；find-identity -v 会排除它。按唯一证书身份签名。
  identity=$(/usr/bin/security find-identity -p codesigning "$keychain" 2>/dev/null |
    awk -v name="\"$name\"" 'index($0,name) {print $2}' | sort -u)
  if [[ ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo "缺少唯一的 $name 签名身份；先运行 scripts/setup-signing.sh。" >&2
    exit 1
  fi
  signing_args=(--keychain "$keychain")
fi

short_commit=$(git rev-parse --short=12 HEAD)
filename="MacView-$version-$mode-$short_commit.zip"
zip="$output/$filename"
checksum="$zip.sha256"
mkdir -p "$root/build" "$output"
if [ -e "$zip" ] || [ -L "$zip" ] || [ -e "$checksum" ] || [ -L "$checksum" ]; then
  echo "同名打包产物已存在；请用 --output 指定另一个目录。" >&2
  exit 1
fi
scratch=$(mktemp -d "$root/build/package.XXXXXXXX")
trap 'python3 -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$scratch"' EXIT
derived="$root/build/ReleaseDerivedData"

command -v xcodegen >/dev/null || { echo "缺少 xcodegen，请先运行 brew install xcodegen" >&2; exit 1; }
xcodegen generate --quiet
# CFBundleShortVersionString 使用数字版本；预发布后缀保留在公开包文件名。
marketing_version="${version%%[-+]*}"
xcodebuild -quiet -project MacView.xcodeproj -scheme MacView -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$derived" \
  MARKETING_VERSION="$marketing_version" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

stage="$scratch/stage"
app="$stage/MacView.app"
mkdir -p "$stage"
/usr/bin/ditto "$derived/Build/Products/Release/MacView.app" "$app"
mkdir -p "$app/Contents/Resources"
cp "$root/THIRD_PARTY_NOTICES" "$app/Contents/Resources/THIRD_PARTY_NOTICES"
cp "$root/THIRD_PARTY_NOTICES" "$stage/THIRD_PARTY_NOTICES"

sign() {
  if [ "$mode" = local ]; then
    /usr/bin/codesign --force --sign "$identity" --timestamp=none "${signing_args[@]}" "$1"
  else
    /usr/bin/codesign --force --sign - --timestamp=none "$1"
  fi
}
# 从深处的可执行文件和动态库向外签，避免用 --deep 签名掩盖内嵌代码的错误。
while IFS= read -r -d '' item; do
  if [ -L "$item" ]; then
    continue
  elif [ -f "$item" ]; then
    case "$(/usr/bin/file -b "$item")" in
      *Mach-O*) sign "$item" ;;
    esac
  elif [ -d "$item" ]; then
    case "$item" in
      *.framework|*.app|*.xpc|*.appex|*.plugin) sign "$item" ;;
      *.bundle)
        # 纯资源 bundle 不含可执行代码，不单独签名。
        if /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$item/Contents/Info.plist" >/dev/null 2>&1; then
          sign "$item"
        fi ;;
    esac
  fi
done < <(find "$app/Contents" -depth -print0)
sign "$app"
/usr/bin/codesign --verify --deep --strict "$app"

# zip 根目录同时包含 App 和许可声明。
/usr/bin/ditto -c -k --sequesterRsrc "$stage" "$scratch/package.zip"
digest=$(/usr/bin/shasum -a 256 "$scratch/package.zip" | awk '{print $1}')
printf '%s  %s\n' "$digest" "$filename" > "$scratch/package.sha256"
# 独占创建，避免覆盖用户以前的包。源文件先完整构建和验证才发布。
python3 - "$scratch/package.zip" "$zip" "$scratch/package.sha256" "$checksum" <<'PY'
import os
import shutil
import sys
created = {}
try:
    for source, target in zip(sys.argv[1::2], sys.argv[2::2]):
        with open(source, "rb") as reader, open(target, "xb") as writer:
            stat = os.fstat(writer.fileno())
            created[target] = (stat.st_dev, stat.st_ino)
            shutil.copyfileobj(reader, writer)
except BaseException:
    for target, identity in created.items():
        try:
            stat = os.lstat(target)
            if (stat.st_dev, stat.st_ino) == identity:
                os.unlink(target)
        except FileNotFoundError:
            pass
        except OSError:
            print("清理未完成的打包产物失败", file=sys.stderr)
    raise
PY
echo "打包完成：$zip"
echo "校验和：$checksum"
