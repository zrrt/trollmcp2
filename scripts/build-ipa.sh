#!/bin/bash
# TrollMCP2 骨架 IPA 构建脚本（macOS runner / 本地 Mac 均可）
# 产物：未签名 TrollMCP2.ipa —— 由 TrollStore 安装时自动签名
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo ">>> iphoneos SDK: $SDK"

echo ">>> swift build (arm64-apple-ios14.0, release)"
swift build -c release \
    -Xswiftc -sdk -Xswiftc "$SDK" \
    -Xswiftc -target -Xswiftc arm64-apple-ios14.0 \
    -Xcc -isysroot -Xcc "$SDK" \
    -Xcc -target -Xcc arm64-apple-ios14.0

BIN=".build/release/TrollMCP2"
test -f "$BIN"
echo ">>> binary: $(du -h "$BIN" | cut -f1)"

APP="TrollMCP2.app"
IPA="TrollMCP2.ipa"
rm -rf "$APP" Payload "$IPA"
mkdir -p "$APP"

cp "$BIN" "$APP/TrollMCP2"
cp Support/Info.plist "$APP/Info.plist"

# 内置注入工具链（ldid/optool/insert_dylib/ct_bypass + coreutils + 依赖 dylib）
if [ -d "Resources/bin" ]; then
    cp -R "Resources/bin" "$APP/bin"
    chmod +x "$APP/bin/"* 2>/dev/null || true
    echo ">>> bundled bin: $(ls "$APP/bin" | wc -l | tr -d ' ') files"
fi

mkdir -p Payload
cp -R "$APP" Payload/

zip -qry "$IPA" Payload
echo ">>> built: $IPA ($(du -h "$IPA" | cut -f1))"
