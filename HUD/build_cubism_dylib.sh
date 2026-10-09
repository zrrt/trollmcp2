#!/bin/bash
# build_cubism_dylib.sh — 把 Cubism Framework + Metal 渲染器 + LApp + bridge 编成独立 CubismDL.dylib
# 用法（CI / 本机 macOS）：bash build_cubism_dylib.sh <HUD目录> <输出dylib路径>
# 说明：HUD 主进程 dlopen 该 dylib，隔离 Cubism 启动崩溃（编入主二进制会崩 __completeAndRunAsPlugin）。
set -e

HUD="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT="${2:-$HUD/CubismDL.dylib}"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
if [ -z "$SDK" ]; then echo "!! iphoneos SDK not found (macOS+Xcode required)"; exit 1; fi

echo ">>> SDK: $SDK"
echo ">>> HUD: $HUD"
echo ">>> OUT: $OUT"

FW_SRC=$(find "$HUD/cubism/Framework/src" -name '*.cpp' \
  | grep -v -E '(Rendering/(OpenGL|D3D9|D3D11|Vulkan)|Rendering/[^/]*/Shaders)')
METAL_SRC=$(find "$HUD/cubism/Framework/src/Rendering/Metal" -name '*.mm')
LAPP_SRC=$(find "$HUD/cubism/LApp" -name '*.mm' -o -name '*.m')
BRIDGE="$HUD/cubism/Bridge/CubismBridge.mm"

echo ">>> FW_SRC 文件数: $(echo "$FW_SRC" | wc -l | tr -d ' ')"
echo ">>> METAL_SRC 文件数: $(echo "$METAL_SRC" | wc -l | tr -d ' ')"
echo ">>> LAPP_SRC 文件数: $(echo "$LAPP_SRC" | wc -l | tr -d ' ')"

xcrun -sdk iphoneos clang++ -arch arm64 -std=gnu++14 -fobjc-arc -fobjc-weak \
  -isysroot "$SDK" -dynamiclib -o "$OUT" \
  -I"$HUD/cubism/Framework/src" -I"$HUD/cubism/Core/include" -I"$HUD/cubism/LApp" -I"$HUD/cubism/Bridge" \
  $FW_SRC $METAL_SRC $LAPP_SRC "$BRIDGE" \
  "$HUD/cubism/Core/lib/ios/Release-iphoneos/libLive2DCubismCore.a" \
  -framework Metal -framework MetalKit -framework QuartzCore -framework UIKit -framework CoreGraphics -framework Foundation \
  -Wl,-undefined,dynamic_lookup 2>&1 | tail -40

ls -la "$OUT"
echo ">>> BUILD_CUBISM_DYLIB_OK"
