#!/bin/sh
# S0-F1 画布测试：用 Instruments（Animation Hitches）录制自动场景，再按阶段汇总。
# 用法：scripts/canvas-test.sh <结果目录> [变体…]；变体默认依次为 full noImages empty。
# 要在 ProMotion 屏幕上测，并断开刷新率较低的外接显示器（否则显示链接只有 60 Hz）。
set -eu
out=$1
shift
variants=${*:-full noImages empty}
derived=build/DerivedData-profile
work=$(mktemp -d)

xcodegen generate --quiet
# 测试窗口只在 Debug 配置中编译；打开优化，测的是与 Release 相当的代码。
xcodebuild -quiet -project MacView.xcodeproj -scheme MacView -configuration Debug \
	-destination "platform=macOS,arch=$(uname -m)" -derivedDataPath "$derived" SWIFT_OPTIMIZATION_LEVEL=-O build
app="$derived/Build/Products/Debug/MacView.app/Contents/MacOS/MacView"
mkdir -p "$out"

for variant in $variants; do
	xcrun xctrace record --template 'Animation Hitches' --time-limit 60s --output "$work/$variant.trace" \
		--launch -- "$app" -MVCanvasTest YES -MVCanvasTestAutorun YES -MVCanvasTestVariant "$variant" \
		-MVCanvasTestReport "$work/$variant.json"
	python3 -I scripts/canvas-hitches.py "$work/$variant.trace" "$work/$variant.json" "$out/S0-F1-$variant.json" >/dev/null
	echo "$variant：$out/S0-F1-$variant.json"
done
echo "录制保留在 $work"
