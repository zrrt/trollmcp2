#!/bin/bash
# build_kfd_helper.sh — 在 macOS 上把 kfd_helper 编成 iOS arm64 二进制，放入 Resources/bin/
#
# 依赖: Xcode (iphoneos SDK) + 网络 (git clone libkfd)
# 用法: bash tools/build_kfd_helper.sh
# 说明: libkfd 的编译方式随版本变化(不同 exploit 目录/flag)，本脚本先用"全量编 .c"，
#       若失败，请改用 libkfd 自带 Makefile 产出目标文件再与本文件链接。
set -e
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
mkdir -p Resources/bin

# 1. 拉 libkfd（puaf_landa 支持 iOS 15.5–16.6.1；我们目标 iOS 16.3）
rm -rf /tmp/libkfd
git clone --depth 1 -q https://github.com/Felix-pb/libkfd.git /tmp/libkfd

# 2. 收集 libkfd 全部 .c（含 exploits/，排除示例 main）
C_FILES=""
for f in /tmp/libkfd/libkfd/*.c /tmp/libkfd/libkfd/exploits/*/*.c; do
    [ -e "$f" ] && C_FILES="$C_FILES $f"
done

# 3. 编译：全量源文件 + kfd_helper.c
xcrun -sdk iphoneos clang -arch arm64 -mios-version-min=14.0 \
    -isysroot "$SDK" \
    -I/tmp/libkfd -I"$ROOT/tools" \
    -DARCH_ARM64 \
    $C_FILES \
    "$ROOT/tools/kfd_helper.c" \
    -o Resources/bin/kfd_helper \
    -framework Security \
    -lz \
    || { echo "KFD_HELPER BUILD FAILED (libkfd 结构变更?) — 请改用 libkfd Makefile 产物再编"; exit 1; }

echo "=== kfd_helper built ==="
file Resources/bin/kfd_helper
