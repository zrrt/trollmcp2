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

# OpenSSL 3.x ios64-cross 内建 target：自动定位 clang 并拼接 isysroot。
# 只需提供 CROSS_TOP（平台 Developer 目录）+ CROSS_SDK（具体 sdk 名）。
# 切勿手动设 CC/CROSS_COMPILE——会与 target 内建路径拼接冲突
# （产生 .../usr/bin/arm64-apple-ios/.../clang 的错误路径，make 直接 Error 127）。
export CROSS_TOP="$(dirname "$(dirname "$SDK")")"
export CROSS_SDK="$(basename "$SDK")"
echo ">>> CROSS_TOP=$CROSS_TOP CROSS_SDK=$CROSS_SDK"

# v4.3.55: 双架构（arm64 + arm64e）——arm64e 链接需要 arm64e 版 openssl。
# 方案：把 ios64-cross target 的 -arch arm64 改为 "-arch arm64 -arch arm64e"，
# 一次编译直接产出 fat 静态库（每个 .o 含双 slice，避免二次编译+lipo 合并失败）。
perl -pi -e 's/-arch arm64/-arch arm64 -arch arm64e/' Configurations/10-main.conf
./Configure ios64-cross no-shared no-tests no-async --prefix="$OLDPWD/openssl-stage" 2>&1 | tail -2
make -j4 2>&1 | tail -3
make install_sw 2>&1 | tail -2

cd "$OLDPWD"
echo ">>> openssl built:"
ls -lh openssl-stage/lib/libssl.a openssl-stage/lib/libcrypto.a
# 验证是否为 fat（arm64 + arm64e）
file openssl-stage/lib/libssl.a | head -1
