#!/bin/sh
# 构建 libsmb2 动态库，供 `mvbench io ... --transport smb2` 在运行时加载。
# libsmb2 使用 LGPL-2.1，只能动态链接；源码与产物都在 build/libsmb2/，不入库。
set -eu

TAG=libsmb2-6.3.1
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="$ROOT/build/libsmb2"

if [ ! -d "$DIR/src" ]; then
	git clone --quiet https://github.com/sahlberg/libsmb2.git "$DIR/src"
fi
git -C "$DIR/src" checkout --quiet "$TAG"

cmake -S "$DIR/src" -B "$DIR/build" -G Ninja -Wno-deprecated \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_INSTALL_PREFIX="$DIR/install" \
	-DCMAKE_INSTALL_NAME_DIR="$DIR/install/lib" \
	-DBUILD_SHARED_LIBS=ON \
	-DENABLE_EXAMPLES=OFF \
	-DENABLE_LIBKRB5=OFF \
	-DENABLE_GSSAPI=OFF >/dev/null
cmake --build "$DIR/build" >/dev/null
cmake --install "$DIR/build" >/dev/null
echo "$DIR/install/lib/libsmb2.dylib"
