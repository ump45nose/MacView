#!/bin/sh
# 启动隔离的 MacView，用 Animation Hitches 加 os_signpost 录制滚动，再汇总帧时间。
# 用法：scripts/acceptance/record-trackpad.sh <场景> <输出目录> [--automatic|--smoke]
# 场景为 scroll-cached 或 scroll-cold。scroll-cold 同时录 Time Profiler。
# 默认只录用户的真实触控板手势；自动验收显式使用 --automatic，--smoke 只空录1秒检查流程。
# 只结束本脚本启动的 App PID。
set -eu
scene=${1:?需要场景}
out=${2:?需要输出目录}
mode=${3:---manual}
cd "$(dirname "$0")/../.."
case "$scene" in
scroll-cached|scroll-cold) ;;
*) echo "场景需要是 scroll-cached 或 scroll-cold" >&2; exit 2 ;;
esac
case "$mode" in
--manual|--automatic|--smoke) ;;
*) echo "第三个参数需要是 --automatic 或 --smoke" >&2; exit 2 ;;
esac

derived=build/DerivedData-profile
socket="build/acceptance/trackpad-$$.sock"
support="$PWD/build/acceptance/$scene/support"
cache="$PWD/build/acceptance/$scene/cache"
layout="$PWD/build/acceptance/$scene/layout.json"
mkdir -p "$out" "$support" "$(dirname "$layout")"
if [ "$scene" = "scroll-cold" ]; then
	rm -rf "$cache" "$support"
	rm -f "$layout"
fi
mkdir -p "$cache" "$support"
rm -f "$support/session.json"
rm -f "$socket"

xcodegen generate --quiet
xcodebuild -quiet -project MacView.xcodeproj -scheme MacView -configuration Debug \
	-destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$derived" SWIFT_OPTIMIZATION_LEVEL=-O build
app="$derived/Build/Products/Debug/MacView.app/Contents/MacOS/MacView"

pid=""
trace=""
caffeinate -d -w $$ &
cleanup() {
	if [ -n "$trace" ]; then
		kill -INT "$trace" 2>/dev/null || true
		wait "$trace" 2>/dev/null || true
		trace=""
	fi
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
	fi
	rm -f "$socket"
}
trap cleanup EXIT INT TERM

"$app" -MVDebugSocket "$socket" -MVSupportDirectory "$support" -MVCacheDirectory "$cache" -MVLayoutFile "$layout" \
	>"$out/app.log" 2>&1 &
pid=$!

i=0
while [ ! -S "$socket" ]; do
	if ! kill -0 "$pid" 2>/dev/null; then
		echo "App 已退出，见 $out/app.log" >&2
		exit 1
	fi
	i=$((i + 1))
	if [ "$i" -gt 600 ]; then
		echo "调试套接字没有出现" >&2
		exit 1
	fi
	sleep 0.05
done

python3 -I scripts/acceptance/run.py --prepare-scroll "$scene" "$socket"

rm -rf "$out/record.trace"
if [ "$scene" = "scroll-cold" ]; then
	xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost --instrument 'Time Profiler' \
		--attach "$pid" --output "$out/record.trace" >"$out/xctrace.log" 2>&1 &
else
	xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost \
		--attach "$pid" --output "$out/record.trace" >"$out/xctrace.log" 2>&1 &
fi
trace=$!

i=0
while [ ! -d "$out/record.trace" ]; do
	if ! kill -0 "$trace" 2>/dev/null; then
		echo "xctrace 已退出，见 $out/xctrace.log" >&2
		exit 1
	fi
	i=$((i + 1))
	if [ "$i" -gt 200 ]; then
		echo "录制目录没有出现" >&2
		exit 1
	fi
	sleep 0.1
done
sleep 1

case "$mode" in
--automatic) python3 -I scripts/acceptance/run.py --run-scroll "$scene" "$socket" "$out" ;;
--smoke) python3 -I scripts/acceptance/run.py --smoke-scroll "$scene" "$socket" "$out" ;;
*) python3 -I scripts/acceptance/run.py --observe-scroll "$scene" "$socket" "$out" ;;
esac
kill -INT "$trace" 2>/dev/null || true
wait "$trace" || true
trace=""
python3 -I scripts/canvas-hitches.py "$out/record.trace" "$out/phase.json" "$out/hitches.json" >/dev/null

python3 -I scripts/acceptance/run.py --quit-app "$socket" || true
i=0
while [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; do
	i=$((i + 1))
	if [ "$i" -gt 30 ]; then
		break
	fi
	sleep 0.1
done
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
	kill "$pid" 2>/dev/null || true
	wait "$pid" 2>/dev/null || true
fi
pid=""
rm -f "$socket"
trap - EXIT INT TERM
