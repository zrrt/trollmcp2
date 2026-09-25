#!/bin/bash
# build_kfd_helper.sh — 在 macOS 上把 kfd_helper 编成 iOS arm64 二进制，放入 Resources/bin/
#
# 依赖: Xcode (iphoneos SDK) + 网络 (git clone felix-pb/kfd)
# 用法: bash tools/build_kfd_helper.sh
#
# 说明:
#   - libkfd 为 header-only（kfd/libkfd.h 内联实现，子目录全 .h），只编 kfd_helper.c 即可。
#   - dynamic_info 偏移表用本仓库 tools/kfd/dynamic_info.h 覆盖 libkfd 同名文件
#     （原版只有 iOS 16.6，我们补了 iOS 16.3 A12–A16）。
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p Resources/bin

# 1. 拉 felix-pb/kfd（正确仓库名；puaf_landa 支持 iOS 15.0–16.6.1，目标 iOS 16.3）
rm -rf /tmp/kfd
git clone --depth 1 -q https://github.com/felix-pb/kfd.git /tmp/kfd

# 2. 用现成偏移表覆盖 libkfd 的 dynamic_info.h（含 iOS 16.3 A12–A16，原版仅 16.6）
cp "$ROOT/tools/kfd/dynamic_info.h" /tmp/kfd/kfd/libkfd/info/dynamic_info.h

# 3. 编译 kfd_helper（header-only，无需编 libkfd 的 .c）
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=14.0 \
    -isysroot "$SDK" \
    -I/tmp/kfd/kfd -I"$ROOT/tools" \
    -DARCH_ARM64 \
    "$ROOT/tools/kfd_helper.c" \
    -o Resources/bin/kfd_helper \
    -framework Security \
    -framework IOKit \
    -framework CoreFoundation \
    -lz \
    || { echo "KFD_HELPER BUILD FAILED — 若因缺失 framework，按 libkfd 实际依赖补 -framework（见 Support/kfd/README.md）"; exit 1; }

echo "=== kfd_helper built ==="
file Resources/bin/kfd_helper
