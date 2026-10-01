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

# v4.3.54: 双架构（arm64 + arm64e）——arm64e 链接需要 arm64e 版 openssl。
# arm64e 版通过临时把 ios64-cross target 的 -arch arm64 改为 arm64e 编出，
# 再 lipo 合并成 fat 静态库。arm64e 失败则回退纯 arm64（不影响主构建）。
./Configure ios64-cross no-shared no-tests no-async --prefix="$OLDPWD/openssl-stage" 2>&1 | tail -2
make -j4 2>&1 | tail -3
make install_sw 2>&1 | tail -2
echo ">>> arm64 openssl done"

# arm64e: 修改 target arch 后重新编译到独立前缀，再 lipo 合并
if perl -pi -e 's/-arch arm64/-arch arm64e/g' Configurations/10-main.conf 2>/dev/null; then
    mkdir -p /tmp/openssl-stage-arm64e
    make clean 2>/dev/null || true
    if ./Configure ios64-cross no-shared no-tests no-async --prefix=/tmp/openssl-stage-arm64e 2>&1 | tail -2 && make -j4 2>&1 | tail -3 && make install_sw 2>&1 | tail -2; then
        if lipo -create "$OLDPWD/openssl-stage/lib/libssl.a" /tmp/openssl-stage-arm64e/lib/libssl.a -output "$OLDPWD/openssl-stage/lib/libssl.a.fat" 2>/dev/null && \
           lipo -create "$OLDPWD/openssl-stage/lib/libcrypto.a" /tmp/openssl-stage-arm64e/lib/libcrypto.a -output "$OLDPWD/openssl-stage/lib/libcrypto.a.fat" 2>/dev/null; then
            mv "$OLDPWD/openssl-stage/lib/libssl.a.fat" "$OLDPWD/openssl-stage/lib/libssl.a"
            mv "$OLDPWD/openssl-stage/lib/libcrypto.a.fat" "$OLDPWD/openssl-stage/lib/libcrypto.a"
            echo ">>> openssl fat (arm64+arm64e):"
        else
            echo "!!! lipo openssl failed -> keep arm64 only"
        fi
    else
        echo "!!! arm64e openssl build failed -> keep arm64 only"
    fi
fi

cd "$OLDPWD"
echo ">>> openssl built:"
ls -lh openssl-stage/lib/libssl.a openssl-stage/lib/libcrypto.a
