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
        # v2.9.38c: 优先 macOS 原生 ldid（CI 已加 brew install ldid；xerub ldid 对 iOS arm64e 兼容最好）。
        # fallback codesign（macOS 原生，主二进制已验证可用）。
        # 切勿 fallback 到 $APP/bin/ldid —— 那是 iOS arm64 二进制，在 macOS runner 上会被 SIGKILL。
        if command -v ldid >/dev/null 2>&1; then
            SIGN_TOOL=ldid
        elif command -v codesign >/dev/null 2>&1; then
            SIGN_TOOL=codesign
        else
            SIGN_TOOL=""
        fi
        if [ -n "$SIGN_TOOL" ]; then
            for t in "$APP"/bin/*; do
                [ -f "$t" ] || continue
                case "$t" in *.dylib) continue;; esac
                if [ "$SIGN_TOOL" = codesign ]; then
                    codesign -s - -f --entitlements "Support/bin-entitlements.plist" "$t" 2>/dev/null || true
                else
                    # xerub ldid 语法：-S 后必须紧跟文件名（-Sent.plist），否则 entitlements 写不进去
                    "$SIGN_TOOL" -S"Support/bin-entitlements.plist" "$t" 2>/dev/null || true
                fi
            done
            echo ">>> signed bin tools with no-sandbox entitlements (via $SIGN_TOOL)"
        else
            echo "!!! ldid/codesign not available; bin tools stay sandboxed (injection may fail)" >&2
        fi
    fi
fi

# 其他资源文件（开发者指令、配置模板、图标等）
if [ -d "Resources" ]; then
    # 复制文件
    find Resources -mindepth 1 -maxdepth 1 -type f -exec cp {} "$APP/" \;
    # v2.9.62：复制子目录（tweaks/ 内置 dylib 等）——用 find 避免 bash glob 尾部斜杠问题
    find Resources -mindepth 1 -maxdepth 1 -type d | while read -r d; do
        dirname=$(basename "$d")
        # bin 已在前面单独复制（需要 chmod + 签名），跳过避免重复
        [ "$dirname" = "bin" ] && continue
        rm -rf "$APP/$dirname"
        cp -R "$d" "$APP/$dirname"
    done
    echo ">>> bundled resources: $(find Resources -maxdepth 1 -type f | wc -l | tr -d ' ') files + $(find Resources -maxdepth 1 -type d | tail -n +2 | wc -l | tr -d ' ') dirs"
fi

# 把特权 entitlements 签入主二进制，TrollStore 安装时才能继承 no-sandbox/no-container/task_for_pid 等权限
# v2.9.64：强制用 ldid 签名（TrollStore 官方明确要求 ldid -S 格式；codesign ad-hoc 签名格式不同，可能导致 entitlements 不被保留）
if [ -f "Support/TrollMCP2.entitlements" ]; then
    echo ">>> ldid sign main binary with entitlements"
    # CI 已 brew install ldid；优先用 macOS 原生 ldid（xerub ldid 对 iOS arm64e 兼容最好）
    LDID="$(command -v ldid || true)"
    if [ -z "$LDID" ]; then
        echo "!!! ldid not available; cannot inject entitlements" >&2
        exit 1
    fi
    "$LDID" -S"Support/TrollMCP2.entitlements" "$APP/TrollMCP2"
    echo ">>> signed main binary with ldid"
else
    echo "!!! Support/TrollMCP2.entitlements missing" >&2
    exit 1
fi

mkdir -p Payload
cp -R "$APP" Payload/

zip -qry "$IPA" Payload
echo ">>> built: $IPA ($(du -h "$IPA" | cut -f1))"
