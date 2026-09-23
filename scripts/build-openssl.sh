#!/bin/bash
# 编译 OpenSSL 3.x iOS arm64 静态库（MITM 代理内核用）
# 产物：openssl-stage/{lib,include} —— SwiftPM CMitm target 链接用
# CI 每次全量编译（约 2-4 分钟）；本地可复用已缓存的 openssl-stage
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f "openssl-stage/lib/libssl.a" ] && [ -f "openssl-stage/lib/libcrypto.a" ]; then
    echo ">>> openssl-stage cache hit, skip"
    exit 0
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo ">>> iphoneos SDK: $SDK"

rm -rf /tmp/openssl-src openssl-stage
git clone --depth 1 -q -b openssl-3.3.1 https://github.com/openssl/openssl.git /tmp/openssl-src
cd /tmp/openssl-src

export CC="$(xcrun -sdk iphoneos -f clang) -arch arm64 -mios-version-min=14.0 -isysroot $SDK"
export CROSS_TOP="$SDK"
export CROSS_SDK="$(basename "$SDK")"
export CROSS_COMPILE="$(dirname "$(xcrun -sdk iphoneos -f clang)")/arm64-apple-ios"

# ios64-cross：OpenSSL 内建 iOS arm64 target（无加密硬件加速，needs no asm）
./Configure ios64-cross no-shared no-tests no-async --prefix="$OLDPWD/openssl-stage" >/dev/null 2>&1 || \
{ echo ">>> Configure ios64-cross failed, fallback with env"; ./Configure ios64-cross no-shared no-tests no-async --prefix="$OLDPWD/openssl-stage" 2>&1 | tail -5; }

make -j4 >/dev/null 2>&1 || make -j4 2>&1 | tail -10
make install_sw >/dev/null 2>&1 || make install_sw 2>&1 | tail -5

cd "$OLDPWD"
echo ">>> openssl built:"
ls -lh openssl-stage/lib/libssl.a openssl-stage/lib/libcrypto.a
