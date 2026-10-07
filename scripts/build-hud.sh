#!/bin/bash
# 桌面悬浮 HUD 单可执行双模式：把 HUD/sources 的 ObjC++ 悬浮核心编成 libHUD.a 静态库，
# 供主 App（SwiftPM）链接。避开 SwiftPM 直接编 .mm/私有 framework 的局限。
# - 私有头：HUD/headers（BackboardServices.h 等 iOS 私有头）
# - 私有 framework 符号：编译 .o 只需头；链接（主 App）由 Package.swift 用 -F HUD/libraries 解析
# - roothide 前缀头：pch 有 roothide.h 分支，用 -DDISABLE_PATH_REDIRECTION 跳过（无越狱 TrollStore）
# 产物：hud-stage/lib/libHUD.a（arm64，arm64e 尝试——PAC 私有 API 编不过则回退 arm64 only）
set -euo pipefail
cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo ">>> HUD: compiling libHUD.a (sdk=$SDK)"

mkdir -p hud-stage/lib build-hud

SRCS="HUD/sources/HUDApp.mm \
HUD/sources/HUDMainApplication.mm \
HUD/sources/HUDMainWindow.mm \
HUD/sources/HUDMainApplicationDelegate.mm \
HUD/sources/HUDHelper.mm \
HUD/sources/TSEventFetcher.mm \
HUD/sources/HUDRootViewController.mm \
HUD/sources/UITouch-KIFAdditions.m \
HUD/sources/IOHIDEvent+KIF.m"

CFLAGS="-fobjc-arc \
-I HUD/headers \
-I HUD/sources \
-include HUD/supports/hudapp-prefix.pch \
-DDISABLE_PATH_REDIRECTION \
-Wno-error -Wno-deprecated-declarations -Wno-unused-variable -Wno-unused-function"

build_arch() {
    local arch="$1"
    local dir="build-hud/$arch"
    mkdir -p "$dir"
    rm -f "$dir"/*.o
    local objs=()
    for f in $SRCS; do
        local base; base="$(basename "$f")"
        local o="$dir/${base%.m}.o"   # 去 .mm/.m → .o
        echo "    [$arch] $f"
        if [[ "$f" == *.mm ]]; then
            xcrun -sdk iphoneos clang++ -arch "$arch" -isysroot "$SDK" -miphoneos-version-min=15.0 $CFLAGS -c "$f" -o "$o" || return 1
        else
            xcrun -sdk iphoneos clang -arch "$arch" -isysroot "$SDK" -miphoneos-version-min=15.0 $CFLAGS -c "$f" -o "$o" || return 1
        fi
        objs+=("$o")
    done
    ar rcs "hud-stage/lib/libHUD-$arch.a" "${objs[@]}"
}

# arm64 必须成功；arm64e（PAC 私有 API）失败仅回退，不阻断
if build_arch arm64; then
    echo ">>> HUD arm64 OK"
else
    echo "!!! HUD arm64 build FAILED — aborting"
    exit 1
fi

ARM64E_OK=0
if build_arch arm64e; then
    echo ">>> HUD arm64e OK"
    ARM64E_OK=1
else
    echo "!!! HUD arm64e build failed — fallback arm64 only (PAC private API)"
fi

if [ "$ARM64E_OK" = "1" ]; then
    lipo -create hud-stage/lib/libHUD-arm64.a hud-stage/lib/libHUD-arm64e.a -output hud-stage/lib/libHUD.a
    echo ">>> libHUD.a fat (arm64+arm64e): $(du -h hud-stage/lib/libHUD.a | cut -f1)"
else
    cp hud-stage/lib/libHUD-arm64.a hud-stage/lib/libHUD.a
    echo ">>> libHUD.a arm64 only: $(du -h hud-stage/lib/libHUD.a | cut -f1)"
fi
