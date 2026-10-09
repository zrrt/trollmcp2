#!/bin/bash
# build_cubism_dylib.sh — 把 Cubism Framework + Metal 渲染器 + LApp + bridge 编成独立 CubismDL.dylib
# 用法（CI / 本机 macOS）：bash build_cubism_dylib.sh <HUD目录> <输出dylib路径>
# 说明：HUD 主进程 dlopen 该 dylib，隔离 Cubism 启动崩溃（编入主二进制会崩 __completeAndRunAsPlugin）。
# 编译分语言：.cpp/.mm 用 clang++(gnu++14)；.m(纯 ObjC) 用 clang——避免 "-std=gnu++14 not allowed with Objective-C"。
set -e

HUD="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
OUT="${2:-$HUD/CubismDL.dylib}"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
if [ -z "$SDK" ]; then echo "!! iphoneos SDK not found (macOS+Xcode required)"; exit 1; fi

echo ">>> SDK: $SDK"
echo ">>> HUD: $HUD"
echo ">>> OUT: $OUT"

INC="-I$HUD/cubism/Framework/src -I$HUD/cubism/Core/include -I$HUD/cubism/LApp -I$HUD/cubism/Bridge -I$HUD/cubism/iosdemo"

FW_SRC=$(find "$HUD/cubism/Framework/src" -name '*.cpp' \
  | grep -v -E '(Rendering/(OpenGL|D3D9|D3D11|Vulkan)|Rendering/[^/]*/Shaders)')
METAL_SRC=$(find "$HUD/cubism/Framework/src/Rendering/Metal" -name '*.mm')
LAPP_MM=$(find "$HUD/cubism/LApp" -name '*.mm')
LAPP_M=$(find "$HUD/cubism/LApp" -name '*.m')
BRIDGE="$HUD/cubism/Bridge/CubismBridge.mm"
CORE="$HUD/cubism/Core/lib/ios/Release-iphoneos/libLive2DCubismCore.a"

echo ">>> FW_SRC: $(echo "$FW_SRC" | wc -l | tr -d ' ')  METAL: $(echo "$METAL_SRC" | wc -l | tr -d ' ')  LAPP_MM: $(echo "$LAPP_MM" | wc -l | tr -d ' ')  LAPP_M: $(echo "$LAPP_M" | wc -l | tr -d ' ')"

OBJDIR="$HUD/.cubism_obj"
rm -rf "$OBJDIR"; mkdir -p "$OBJDIR"

compile_cpp_mm() { # clang++ (C++/ObjC++)
  local f="$1"
  local base
  base=$(echo "$f" | sed "s#^$HUD/##" | tr '/' '_')
  xcrun -sdk iphoneos clang++ -arch arm64 -std=gnu++14 -fobjc-arc -fobjc-weak -c "$f" \
    -o "$OBJDIR/$base.o" $INC 2>>"$OBJDIR/err.log" || { echo "FAIL cpp/mm: $f"; tail -8 "$OBJDIR/err.log"; exit 1; }
}
compile_m() { # clang (纯 ObjC)
  local f="$1"
  local base
  base=$(echo "$f" | sed "s#^$HUD/##" | tr '/' '_')
  xcrun -sdk iphoneos clang -arch arm64 -fobjc-arc -fobjc-weak -c "$f" \
    -o "$OBJDIR/$base.o" $INC 2>>"$OBJDIR/err.log" || { echo "FAIL m: $f"; tail -8 "$OBJDIR/err.log"; exit 1; }
}

# 1) Framework C++ + Metal 渲染器
for f in $FW_SRC $METAL_SRC; do compile_cpp_mm "$f"; done
# 2) LApp
for f in $LAPP_MM "$BRIDGE"; do compile_cpp_mm "$f"; done
for f in $LAPP_M; do compile_m "$f"; done

OBJS=$(ls "$OBJDIR"/*.o)

echo ">>> 链接 dylib (OBJS=$(echo "$OBJS" | wc -l | tr -d ' '))"
xcrun -sdk iphoneos clang++ -arch arm64 -dynamiclib -o "$OUT" $OBJS "$CORE" \
  -framework Metal -framework MetalKit -framework QuartzCore -framework UIKit -framework CoreGraphics -framework Foundation \
  -Wl,-undefined,dynamic_lookup 2>&1 | tail -30

ls -la "$OUT"
echo ">>> BUILD_CUBISM_DYLIB_OK"
