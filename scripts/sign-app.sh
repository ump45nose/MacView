#!/usr/bin/env bash
# 给 MacView.app 由内向外签名。--local 用本机登录钥匙串里的自签证书，--adhoc 用临时签名。
# --check 只确认本机签名身份可用，不签名。打包脚本和双机交付的安装器共用本脚本。
set -euo pipefail

usage() {
  echo "用法：sign-app.sh --local --check | sign-app.sh (--local | --adhoc) APP" >&2
  exit 2
}
[ "$#" -eq 2 ] || usage
mode="$1"
case "$mode" in --local|--adhoc) ;; *) usage ;; esac

identity="-"
signing_args=()
if [ "$mode" = --local ]; then
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
if [ "$2" = --check ]; then
  [ "$mode" = --local ] || usage
  exit 0
fi
app="$2"
[ -d "$app" ] && [ ! -L "$app" ] || { echo "不是可签名的 App：$app" >&2; exit 1; }

sign() {
  /usr/bin/codesign --force --sign "$identity" --timestamp=none ${signing_args[@]+"${signing_args[@]}"} "$1"
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
