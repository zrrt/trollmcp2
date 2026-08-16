#!/bin/bash
# TrollMCP2 骨架 IPA 构建脚本（macOS runner / 本地 Mac 均可）
# 产物：ldid ad-hoc 签名 + 特权 entitlements 注入的 TrollMCP2.ipa —— TrollStore 安装时直接继承
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

# 其他资源文件（开发者指令、配置模板等）
if [ -d "Resources" ]; then
    for f in Resources/*; do
        [ -d "$f" ] && continue
        cp "$f" "$APP/"
    done
    echo ">>> bundled resources: $(find Resources -maxdepth 1 -type f | wc -l | tr -d ' ') files"
fi

# 用 ldid -S 把特权 entitlements 签入主二进制，TrollStore 安装时才能继承 no-sandbox/no-container/task_for_pid 等权限
if [ -f "Support/TrollMCP2.entitlements" ]; then
    echo ">>> codesign main binary with ldid + entitlements"

    # 优先使用 macOS 原生 ldid（runner 稳定）；没有则通过 Homebrew安装
    if ! command -v ldid >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
        echo ">>> installing ldid via Homebrew"
        brew install ldid 2>/dev/null || true
    fi

    LDID="$(command -v ldid || true)"
    if [ -z "$LDID" ] && [ -x "$APP/bin/ldid" ]; then
        LDID="$APP/bin/ldid"
    fi

    if [ -n "$LDID" ]; then
        "$LDID" -S "Support/TrollMCP2.entitlements" "$APP/TrollMCP2"
        echo ">>> signed main binary with $LDID"
    else
        echo "!!! ldid not available; cannot inject entitlements" >&2
        exit 1
    fi
else
    echo "!!! Support/TrollMCP2.entitlements missing" >&2
    exit 1
fi

mkdir -p Payload
cp -R "$APP" Payload/

zip -qry "$IPA" Payload
echo ">>> built: $IPA ($(du -h "$IPA" | cut -f1))"
