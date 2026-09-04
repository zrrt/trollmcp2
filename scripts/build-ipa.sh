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
    # v2.9.38: 给注入工具签 no-sandbox entitlements
    # iOS 沙箱按每次 exec 的新二进制签名计算：工具不签 no-sandbox 则即使被 root spawn 也仍套普通沙箱，
    # 写其他 App bundle（/private/var/containers/Bundle/Application/...）会 Permission denied。
    if [ -f "Support/bin-entitlements.plist" ]; then
        LDID_TOOL="$(command -v ldid || true)"
        if [ -z "$LDID_TOOL" ] && [ -x "$APP/bin/ldid" ]; then LDID_TOOL="$APP/bin/ldid"; fi
        if [ -n "$LDID_TOOL" ]; then
            for t in "$APP"/bin/*; do
                [ -f "$t" ] || continue
                case "$t" in *.dylib) continue;; esac
                "$LDID_TOOL" -S "Support/bin-entitlements.plist" "$t" 2>/dev/null || true
            done
            echo ">>> signed bin tools with no-sandbox entitlements"
        else
            echo "!!! ldid not available; bin tools stay sandboxed (injection may fail)" >&2
        fi
    fi
fi

# 其他资源文件（开发者指令、配置模板等）
if [ -d "Resources" ]; then
    for f in Resources/*; do
        [ -d "$f" ] && continue
        cp "$f" "$APP/"
    done
    echo ">>> bundled resources: $(find Resources -maxdepth 1 -type f | wc -l | tr -d ' ') files"
fi

# 把特权 entitlements 签入主二进制，TrollStore 安装时才能继承 no-sandbox/no-container/task_for_pid 等权限
if [ -f "Support/TrollMCP2.entitlements" ]; then
    echo ">>> codesign main binary with entitlements"

    # 优先用 macOS 原生 codesign（ad-hoc 签名 + --entitlements 更稳）
    if command -v codesign >/dev/null 2>&1; then
        codesign -s - -f --entitlements "Support/TrollMCP2.entitlements" "$APP/TrollMCP2"
        echo ">>> signed main binary with codesign"
    else
        # fallback：ldid（Homebrew 优先，再试 bundled iOS 二进制）
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
            echo ">>> signed main binary with ldid"
        else
            echo "!!! codesign/ldid not available; cannot inject entitlements" >&2
            exit 1
        fi
    fi
else
    echo "!!! Support/TrollMCP2.entitlements missing" >&2
    exit 1
fi

mkdir -p Payload
cp -R "$APP" Payload/

zip -qry "$IPA" Payload
echo ">>> built: $IPA ($(du -h "$IPA" | cut -f1))"
