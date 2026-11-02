PACKAGE := Packages/MacViewKit
DERIVED := build/DerivedData
APP := $(DERIVED)/Build/Products/Debug/MacView.app
LOCAL_FIXTURES := Fixtures/local/generated
FIXTURES_TMP := build/fixtures-tmp

.PHONY: project build test bench run clean

# App/ 下增删文件后需要重新生成，所以 build 每次都先生成工程。
project:
	@command -v xcodegen >/dev/null || { echo "缺少 xcodegen，请先运行：brew install xcodegen" >&2; exit 1; }
	xcodegen generate --quiet

build: project
	xcodebuild -quiet -project MacView.xcodeproj -scheme MacView -configuration Debug \
		-destination "platform=macOS,arch=$(shell uname -m)" -derivedDataPath $(DERIVED) build

# 本地夹具不入库：缺失时先生成到临时根再移入，不动入库夹具，中断也不留半成品。
test:
	@test -d $(LOCAL_FIXTURES) || { \
		rm -rf $(FIXTURES_TMP) && \
		swift run --package-path $(PACKAGE) mvbench fixtures --root $(CURDIR)/$(FIXTURES_TMP) && \
		mkdir -p $(dir $(LOCAL_FIXTURES)) && mv $(FIXTURES_TMP)/local/generated $(LOCAL_FIXTURES) && \
		rm -rf $(FIXTURES_TMP); }
	swift test --package-path $(PACKAGE) --disable-xctest

# 用法：make bench ARGS="env --path /Volumes/Picture"
bench:
	swift run -c release --package-path $(PACKAGE) mvbench $(ARGS)

run: build
	open $(APP)

clean:
	rm -rf build MacView.xcodeproj $(PACKAGE)/.build
