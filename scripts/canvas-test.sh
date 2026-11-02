#!/bin/sh
# 画布测试：用 Instruments（Animation Hitches，加 os_signpost）录制自动场景，再按阶段汇总。
# 用法：scripts/canvas-test.sh <结果目录> [布局…]；布局默认依次为 masonry grid verticalStrip horizontalStrip。
# 结果写到 <结果目录>/S1-F3-<布局>.json。
# 要在 ProMotion 屏幕上测，并断开刷新率较低的外接显示器（否则显示链接只有 60 Hz）。
set -eu
out=$1
shift
layouts=${*:-masonry grid verticalStrip horizontalStrip}
derived=build/DerivedData-profile
work=$(mktemp -d)

xcodegen generate --quiet
# 测试窗口只在 Debug 配置中编译；打开优化，测的是与 Release 相当的代码。
xcodebuild -quiet -project MacView.xcodeproj -scheme MacView -configuration Debug \
	-destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$derived" SWIFT_OPTIMIZATION_LEVEL=-O build
app="$derived/Build/Products/Debug/MacView.app/Contents/MacOS/MacView"
mkdir -p "$out"

for layout in $layouts; do
	# 显示器睡眠时显示链接停止，场景会停住：录制期间唤醒并保持显示器。
	caffeinate -d -u xcrun xctrace record --template 'Animation Hitches' --instrument os_signpost --time-limit 60s --output "$work/$layout.trace" \
		--launch -- "$app" -MVCanvasTest YES -MVCanvasTestAutorun YES -MVCanvasTestLayout "$layout" \
		-MVCanvasTestReport "$work/$layout.json"
	summary="$work/S1-F3-$layout.json"
	python3 -I scripts/canvas-hitches.py "$work/$layout.trace" "$work/$layout.json" "$summary" >/dev/null
	# os-signpost 表可能为空（xctrace 没导出），这时 C5.3 没有数据，这份录制不能用。
	if ! python3 -I -c 'import json, sys; sys.exit(0 if any(p.get("settles", 0) for p in json.load(open(sys.argv[1]))["phases"]) else 1)' "$summary"; then
		echo "错误：$layout 的 settles 为 0（os-signpost 表为空），录制不可用，需要重录。录制保留在 $work" >&2
		exit 1
	fi
	mv "$summary" "$out/S1-F3-$layout.json"
	echo "$layout：$out/S1-F3-$layout.json"
done
echo "录制保留在 $work"
