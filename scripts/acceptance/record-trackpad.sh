#!/bin/sh
# 启动隔离的 MacView，用 Animation Hitches 加 os_signpost 录制滚动，再汇总帧时间。
# 用法：scripts/acceptance/record-trackpad.sh <场景> <输出目录> [--automatic|--smoke]
# 场景为 scroll-cached、scroll-cold 或 settle。scroll-cold 同时录 Time Profiler。
# 默认只录用户的真实触控板手势；自动验收显式使用 --automatic，--smoke 只空录1秒检查流程。
# 只结束本脚本启动的 App PID。
set -eu
scene=${1:?需要场景}
out=${2:?需要输出目录}
mode=${3:---manual}
cd "$(dirname "$0")/../.."
mkdir -p "$out"
out=$(cd "$out" && pwd)
case "$scene" in
scroll-cached|scroll-cold|settle) ;;
*) echo "场景需要是 scroll-cached、scroll-cold 或 settle" >&2; exit 2 ;;
esac
case "$mode" in
--manual|--automatic|--smoke) ;;
*) echo "第三个参数需要是 --automatic 或 --smoke" >&2; exit 2 ;;
esac

if [ -e "$out/record.trace" ] || [ -e "$out/raw-files.json" ]; then
	echo "输出目录已有录制或原始文件名单，请使用新的输出目录" >&2
	exit 2
fi
mkdir -p "$PWD/build/acceptance"
work=$(mktemp -d "$PWD/build/acceptance/trackpad.XXXXXX")
export TMPDIR="$work/tmp/"
mkdir -p "$TMPDIR"
derived="$PWD/build/DerivedData-profile"
socket="$PWD/build/t-$$.sock"
support="$work/support"
cache="$work/cache"
layout="$work/layout.json"
pid=""
trace=""
raw_manifest=""
cleanup() {
	status=$?
	trap - EXIT INT TERM
	if [ -n "$trace" ]; then
		kill -INT "$trace" 2>/dev/null || true
		wait "$trace" 2>/dev/null || true
		trace=""
	fi
	if [ -n "$raw_manifest" ]; then
		python3 -I "$PWD/scripts/acceptance/recording.py" finish "$raw_manifest" || status=1
	fi
	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
	fi
	rm -f "$socket"
	rm -rf "$work"
	exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p "$out" "$support" "$(dirname "$layout")"
if [ "$scene" = "scroll-cold" ]; then
	rm -rf "$cache" "$support"
	rm -f "$layout"
fi
mkdir -p "$cache" "$support"
rm -f "$support/session.json"
rm -f "$socket"

if [ ! -x "$derived/Build/Products/Debug/MacView.app/Contents/MacOS/MacView" ]; then
	xcodegen generate --quiet
	xcodebuild -quiet -project "$PWD/MacView.xcodeproj" -scheme MacView -configuration Debug \
		-destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$derived" SWIFT_OPTIMIZATION_LEVEL=-O build
fi

caffeinate -d -w $$ &

pid=$(python3 -I "$PWD/scripts/acceptance/run.py" --launch-app "$socket" "$support" "$cache" "$layout" "$out/app.log")
printf '%s\n' "$pid" >"$out/app.pid"

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

python3 -I "$PWD/scripts/acceptance/run.py" --prepare-scroll "$scene" "$socket" >"$out/window-before.json"

raw_manifest="$out/raw-files.json"
python3 -I "$PWD/scripts/acceptance/recording.py" begin "$raw_manifest"
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
--automatic) python3 -I "$PWD/scripts/acceptance/run.py" --run-scroll "$scene" "$socket" "$out" ;;
--smoke) python3 -I "$PWD/scripts/acceptance/run.py" --smoke-scroll "$scene" "$socket" "$out" ;;
*) python3 -I "$PWD/scripts/acceptance/run.py" --observe-scroll "$scene" "$socket" "$out" ;;
esac
kill -INT "$trace" 2>/dev/null || true
wait "$trace" || true
trace=""
python3 -I "$PWD/scripts/canvas-hitches.py" "$out/record.trace" "$out/phase.json" "$out/hitches.json" >/dev/null
if [ "$scene" = "scroll-cold" ]; then
	python3 -I "$PWD/scripts/acceptance/run.py" --main-thread-summary "$out/record.trace" "$out/main-thread.json"
fi

python3 -I "$PWD/scripts/acceptance/run.py" --quit-app "$socket" || true
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
fi
pid=""
rm -f "$socket"
