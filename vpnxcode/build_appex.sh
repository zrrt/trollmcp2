#!/bin/bash
# P1 Step A：Xcode app-extension 构建 + ldid-procursus 签名 + entitlements 校验
# 用法：bash vpnxcode/build_appex.sh <输出目录>（把 VpnTunnel.appex 放到指定目录）
set -euo pipefail

OUT="${1:-out}"
# fix3cy27c: 先把 OUT 解析为绝对路径（按调用方 cwd 解析），再 cd 进本目录——
#   本脚本 cd "$(dirname "$0")"（vpnxcode/）后，相对 OUT 会落到 vpnxcode/TrollAgent.app/PlugIns/，
#   而调用方 build-ipa.sh 检查的是仓库根的 TrollAgent.app/PlugIns，导致"复制成功但检查 MISSING→被删"。
if [[ "$OUT" != /* ]]; then
    OUT="$(pwd)/$OUT"
fi
cd "$(dirname "$0")"

mkdir -p "$OUT"

for tool in xcodegen xcodebuild ldid; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "error: '$tool' not found (brew install xcodegen ldid-procursus)"
        exit 1
    fi
done

echo "==> xcodegen"
xcodegen

echo "==> xcodebuild (unsigned)"
rm -rf DerivedData
xcodebuild -project VpnTunnelX.xcodeproj \
    -scheme VpnTunnel \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath DerivedData \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build 2>&1 | tail -30

APPEX=$(find DerivedData -name "VpnTunnel.appex" -type d | head -1)
if [ -z "$APPEX" ]; then
    echo "error: VpnTunnel.appex not found in DerivedData"
    exit 1
fi
echo "==> appex at: $APPEX"
BIN="$APPEX/VpnTunnel"
file "$BIN"

echo "==> ldid sign + verify"
ldid -Sentitlements/VpnTunnel.entitlements "$BIN"
DUMP=$(mktemp)
ldid -e "$BIN" > "$DUMP" 2>/dev/null || true
cat "$DUMP"
grep -q packet-tunnel-provider "$DUMP" || { echo "ERROR: packet-tunnel-provider missing after sign"; exit 1; }
grep -q "allow-vpn" "$DUMP" || { echo "ERROR: vpn.api allow-vpn missing after sign"; exit 1; }
grep -q "container-required" "$DUMP" || { echo "ERROR: container-required missing after sign"; exit 1; }
echo "==> entitlements OK"

rm -rf "$OUT/VpnTunnel.appex"
cp -R "$APPEX" "$OUT/"
echo "==> copied to $OUT/VpnTunnel.appex"
ls -la "$OUT/VpnTunnel.appex/"
