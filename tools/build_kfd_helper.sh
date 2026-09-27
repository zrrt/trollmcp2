#!/bin/bash
# build_kfd_helper.sh — 在 macOS 上把 kfd_helper（纯 C 胶水版）编成 iOS arm64 二进制，放入 Resources/bin/
#
# 依赖: Xcode (iphoneos SDK)。不再需要 git clone libkfd（胶水版不依赖 kfd 内核读写，
#       注入由同目录 Resources/bin/fuck_helper=FuckKfdHelper 完成）。
# 用法: bash tools/build_kfd_helper.sh
#
# 说明:
#   - kfd_helper 只做: 提取 VpnTunnel.appex 的 cdhash → posix_spawn 同目录 fuck_helper。
#   - 需 CommonCrypto（算 cdhash）+ mach-o 头，均来自 iphoneos SDK，无第三方依赖。
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p Resources/bin

xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=14.0 \
    -isysroot "$SDK" \
    -O2 \
    "$ROOT/tools/kfd_helper.c" \
    -o Resources/bin/kfd_helper \
    || { echo "KFD_HELPER BUILD FAILED"; exit 1; }

echo "=== kfd_helper built (glue, invokes Resources/bin/fuck_helper) ==="
file Resources/bin/kfd_helper
