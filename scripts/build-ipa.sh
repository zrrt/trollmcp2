#!/bin/bash
# TrollAgent 骨架 IPA 构建脚本（macOS runner / 本地 Mac 均可）
# 产物：ldid ad-hoc 签名 + 特权 entitlements 注入的 TrollAgent.ipa —— TrollStore 安装时直接继承
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
echo ">>> iphoneos SDK: $SDK"

# v3.0.37: iSH 引擎依赖——CI 已由 workflow 的 "Build iSH engine" 步骤生成 ish-stage/
# （libs/include/resources + alpine-rootfs.zip）；本地构建需先跑 scripts/ish-build/*.sh
if [ ! -f "ish-stage/libs/libish.a" ]; then
    echo "!!! ish-stage/libs/libish.a 缺失——本地构建请先运行 scripts/ish-build/build_ish.sh 与 prepare_alpine_rootfs.sh" >&2
    exit 1
fi
echo ">>> iSH libs: $(du -sh ish-stage/libs | cut -f1)"

# v3.3.0: MITM 内核依赖 OpenSSL 静态库——本地构建先跑 scripts/build-openssl.sh
if [ ! -f "openssl-stage/lib/libssl.a" ]; then
    echo "!!! openssl-stage/lib/libssl.a 缺失——本地构建请先运行 scripts/build-openssl.sh（仅 macOS；CI 已内置该步骤）" >&2
    exit 1
fi
echo ">>> OpenSSL: $(du -sh openssl-stage/lib | cut -f1)"

# v2.9.249: 部署目标 16→15 治本——按 ios16 编译会引用 iOS16+ 符号(URLRequest.httpMethod/timeoutInterval 等 availability 标注错误的 Swift setter),iOS 15.6 dyld 启动崩;降到 ios14 后编译器自动避免 iOS16+ API
# v4.3.54: 双架构（arm64 + arm64e）——TrollAgent 纯 arm64 在 A12+(arm64e 芯片)
# 设备上以兼容模式运行，MobileIcons/CoreImage 在 compat 模式下处理图标异常 →
# 分享面板 LICreateIconForImages SIGSEGV（与 TrollFools 双架构原生运行对比）。
echo ">>> swift build (arm64-apple-ios15.0, release)"
swift build -c release \
    -Xswiftc -sdk -Xswiftc "$SDK" \
    -Xswiftc -target -Xswiftc arm64-apple-ios15.0 \
    -Xcc -isysroot -Xcc "$SDK" \
    -Xcc -target -Xcc arm64-apple-ios15.0

BIN=".build/release/TrollAgent"
test -f "$BIN"
cp "$BIN" /tmp/TrollAgent-arm64 2>/dev/null || cp "$BIN" "$BIN.arm64"
echo ">>> binary: $(du -h "$BIN" | cut -f1)"

echo ">>> swift build (arm64e-apple-ios15.0, release)"
swift build -c release --scratch-path .build-arm64e \
    -Xswiftc -sdk -Xswiftc "$SDK" \
    -Xswiftc -target -Xswiftc arm64e-apple-ios15.0 \
    -Xcc -isysroot -Xcc "$SDK" \
    -Xcc -target -Xcc arm64e-apple-ios15.0 || echo "!!! arm64e build failed"

BIN64E=".build-arm64e/release/TrollAgent"
if [ -f "$BIN64E" ] && lipo -info "$BIN64E" 2>/dev/null | grep -q "arm64e"; then
    echo ">>> lipo -create (arm64 + arm64e)"
    lipo -create /tmp/TrollAgent-arm64 "$BIN64E" -output "$BIN" 2>/dev/null || lipo -create "$BIN.arm64" "$BIN64E" -output "$BIN"
else
    echo ">>> arm64e unavailable -> fallback arm64 only"
fi
lipo -info "$BIN" | head -1

APP="TrollAgent.app"
IPA="TrollAgent.ipa"
rm -rf "$APP" Payload "$IPA"
mkdir -p "$APP"

cp "$BIN" "$APP/TrollAgent"
cp Support/Info.plist "$APP/Info.plist"

# v2.9.133: 版本注入——CI 传 RELEASE_VERSION 时覆盖产物版本，
# 解决"构建产物版本永远停在仓库写死值、装上分不清新旧"的脱节问题。
# 未传时保持 Support/Info.plist 原值（本地构建默认）。
if [ -n "${RELEASE_VERSION:-}" ]; then
    echo ">>> injecting RELEASE_VERSION=$RELEASE_VERSION"
    if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $RELEASE_VERSION" "$APP/Info.plist" 2>/dev/null || \
        /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $RELEASE_VERSION" "$APP/Info.plist"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-parse --short HEAD 2>/dev/null || echo 1)" "$APP/Info.plist" 2>/dev/null || true
    else
        /usr/bin/sed -i '' "s#<string>2\.9\.[0-9]*</string>#<string>$RELEASE_VERSION</string>#" "$APP/Info.plist" || true
    fi
fi

# 内置注入工具链（ldid/optool/insert_dylib/ct_bypass + coreutils + 依赖 dylib）
if [ -d "Resources/bin" ]; then
    cp -R "Resources/bin" "$APP/bin"
    chmod +x "$APP/bin/"* 2>/dev/null || true
    echo ">>> bundled bin: $(ls "$APP/bin" | wc -l | tr -d ' ') files"
    # v4.4.5: 原生工具（CI native-tools job 交叉编译/预编译提取的 arm64 iOS 二进制：
    # lua=源码编译, node=nodejs-mobile iOS 预编译, r2=radare2 r2ios-sdk 预编译, cstool=capstone 交叉编译；
    # 均随 tool.install 绑定）
    for t in lua node r2 cstool; do
        if [ -f "native-tools-out/$t" ]; then
            cp "native-tools-out/$t" "$APP/bin/$t"
            chmod +x "$APP/bin/$t"
            echo ">>> native $t bundled ($(du -h "$APP/bin/$t" | cut -f1))"
        fi
    done
    # fix3bo: node C wrapper 的运行时库（nodejs-mobile NodeMobile dylib）同目录进包，@executable_path 相对定位
    if [ -f "native-tools-out/NodeMobile.dylib" ]; then
        cp "native-tools-out/NodeMobile.dylib" "$APP/bin/NodeMobile.dylib"
        echo ">>> NodeMobile.dylib bundled"
    fi
    # capstone 静态库（cstool 的引擎，未来 C 扩展/嵌入可链接）
    if [ -f "native-tools-out/libcapstone.a" ]; then
        cp "native-tools-out/libcapstone.a" "$APP/bin/libcapstone.a"
        echo ">>> libcapstone.a bundled ($(du -h "$APP/bin/libcapstone.a" | cut -f1))"
    fi
    # v4.4.6-fix3u→fix3ac: nmap 源码 iOS 编不过(SDK 缺 Linux 头)→ 降级 nscan.py(Python 端口扫描, 原生 python3 跑)
    if [ -f "nmap-out/nscan.py" ]; then
        cp "nmap-out/nscan.py" "$APP/bin/nscan.py"
        chmod +x "$APP/bin/nscan.py"
        echo ">>> nscan.py bundled"
    fi
    # v4.4.8-fix3w: LLVM 工具链（native-llvm job 交叉编译）+ jtool2（prebuilt arm64 切片）
    for t in llvm-objdump llvm-nm llvm-readelf llvm-size llvm-strings jtool2; do
        if [ -f "native-llvm-out/$t" ]; then
            cp "native-llvm-out/$t" "$APP/bin/$t"
            chmod +x "$APP/bin/$t"
            echo ">>> native $t bundled ($(du -h "$APP/bin/$t" | cut -f1))"
        fi
    done
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

# v4.4.4: 原生 Python 集成（CPython 3.14 iOS, PEP 730）。
# CI 由 native-python job 编译 Python.xcframework 并 upload artifact（tar.gz 包装）；
# build job download 到 python-ios/。此处先解包再定位 ios-arm64 slice。
# 本地构建无 artifact 时自动跳过（App 不内置原生 Python，AI 仍走 iSH python3）。
# 目标：python3 默认路由原生（iPhone 芯片直跑，numpy/pandas 可用），根治 iSH 模拟器 import 段错误闪退。
if ls python-ios/python-*.tar.gz >/dev/null 2>&1; then
    mkdir -p python-ios/unpacked
    tar -xzf python-ios/python-*.tar.gz -C python-ios/unpacked
fi
# 定位 Python.xcframework：不猜 tar 顶层目录名（官方产物可能是 python-3.14.8-iOS-XCframework/
# 包一层，也可能直接散落），find 一次命中。|| true：download 未就位/缺失时不得触发
# set -euo pipefail 杀死整个打包（fix3d 曾因此静默失败——find 找不到目录 exit 1）
XCF_DIR=$(find python-ios -type d -name "Python.xcframework" 2>/dev/null | head -1 || true)
if [ -n "$XCF_DIR" ]; then
    SLICE="$XCF_DIR/ios-arm64"
    if [ -d "$SLICE" ]; then
        echo ">>> integrating native Python (iOS arm64)..."
        # 1. Python.framework → App/Frameworks（CLI 链接 libPython，rpath 指向 ../Frameworks）
        mkdir -p "$APP/Frameworks"
        cp -R "$SLICE/Python.framework" "$APP/Frameworks/"
        # 2. stdlib（PYTHONHOME = App/python）：PEP 730 布局 = XCFramework 顶层共享
        #    lib/python3.14/（纯 Python 模块 + ensurepip + site-packages）+
        #    ios-arm64/lib-arm64/python3.14/lib-dynload/（平台 .so 扩展）
        if [ -d "$XCF_DIR/lib/python3.14" ]; then
            mkdir -p "$APP/python/lib"
            cp -R "$XCF_DIR/lib/python3.14" "$APP/python/lib/"
            echo ">>> stdlib: $(du -sh "$APP/python" | cut -f1)"
        else
            echo "!!! XCFramework lib/python3.14 missing (shared stdlib)" >&2
        fi
        if [ -d "$SLICE/lib-arm64/python3.14/lib-dynload" ]; then
            mkdir -p "$APP/python/lib/python3.14"
            cp -R "$SLICE/lib-arm64/python3.14/lib-dynload" "$APP/python/lib/python3.14/"
            echo ">>> lib-dynload merged: $(ls "$APP/python/lib/python3.14/lib-dynload" | wc -l | tr -d ' ') exts"
        else
            echo "!!! ios-arm64 lib-dynload missing (platform extensions)" >&2
        fi
        # 3. numpy/pandas iOS wheel（CI native-wheels job 用 cibuildwheel 编的 cp314 arm64 iphoneos wheel）
        #    解包进 site-packages——原生 python3 直接 import numpy/pandas
        if ls native-wheels/*.whl >/dev/null 2>&1; then
            SP="$APP/python/lib/python3.14/site-packages"
            mkdir -p "$SP"
            for w in native-wheels/*.whl; do
                unzip -oq "$w" -d "$SP" && echo ">>> wheel unpacked: $(basename "$w")"
            done
            echo ">>> site-packages: $(du -sh "$SP" | cut -f1)"
        else
            echo "!!! native-wheels not present — numpy/pandas 未进包 (iSH 版仍会段错误)" >&2
        fi
        # 4. 编译 python3 CLI（嵌入式入口：PyConfig + PYTHONHOME + -c/-m/script）
        if [ -f "Sources/PythonCLI/main.c" ] && [ -f "$APP/Frameworks/Python.framework/Headers/Python.h" ]; then
            xcrun -sdk iphoneos clang -arch arm64 -isysroot "$SDK" \
                -I"$APP/Frameworks/Python.framework/Headers" \
                -F"$APP/Frameworks" -framework Python \
                -Wl,-rpath,@executable_path/../Frameworks \
                -o "$APP/bin/python3" Sources/PythonCLI/main.c || \
                { echo "!!! python3 CLI build FAILED (native Python skipped)" >&2; rm -f "$APP/bin/python3"; }
            if [ -f "$APP/bin/python3" ]; then
                chmod +x "$APP/bin/python3"
                echo ">>> native python3 CLI built ($(du -h "$APP/bin/python3" | cut -f1))"
            fi
        else
            echo "!!! PythonCLI/main.c or Python.h missing — native Python skipped" >&2
        fi
    else
        echo "!!! ios-arm64 slice missing in $XCF_DIR — native Python skipped" >&2
    fi
else
    echo ">>> python-ios xcframework not present — native Python skipped (iSH python3 stays default)"
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

# v3.0.48: tweaks/*.dylib 注入用——必须纯 arm64 + adhoc 签名。
# 1) arm64e 进程（A12+ 的 App Store App 如豆包）dlopen fat dylib 会选 arm64e slice，
#    arm64e slice 的 adhoc 签名在 iOS16 dyld 上必报 "code signature invalid"（真机实测）。
#    lipo -thin arm64 只留 arm64 slice（arm64e 进程可正常 dlopen 纯 arm64 dylib，TrollFools 同款）。
# 2) ldid 重签（老 xerub ldid 生成的签名 iOS16 也 invalid；CI brew 版为 Procursus 维护版）。
for d in "$APP"/tweaks/*.dylib; do
    [ -f "$d" ] || continue
    if lipo -info "$d" 2>/dev/null | grep -qi "architectures"; then
        lipo -thin arm64 "$d" -output "$d.tmp" 2>/dev/null && mv "$d.tmp" "$d" && echo ">>> thinned to arm64: $d"
    fi
    if command -v ldid >/dev/null 2>&1 && ldid -S "$d" >/dev/null 2>&1; then
        echo ">>> ldid re-signed $d"
    elif codesign -s - -f "$d" >/dev/null 2>&1; then
        echo ">>> codesign adhoc re-signed $d"
    else
        echo "!!! sign failed: $d"
    fi
done

# v3.0.37: iSH 引擎资源——alpine-rootfs.zip（首次启动解压）+ VDSO + RootfsPatch
if [ -f "ish-stage/resources/alpine-rootfs.zip" ]; then
    cp "ish-stage/resources/alpine-rootfs.zip" "$APP/alpine-rootfs.zip"
    echo ">>> bundled alpine-rootfs.zip ($(du -h "$APP/alpine-rootfs.zip" | cut -f1))"
fi
if [ -f "ish-stage/resources/libvdso.so.elf" ]; then
    cp "ish-stage/resources/libvdso.so.elf" "$APP/"
fi
if [ -d "ish-stage/resources/RootfsPatch.bundle" ]; then
    rm -rf "$APP/RootfsPatch.bundle"
    cp -R "ish-stage/resources/RootfsPatch.bundle" "$APP/"
fi

# v3.0.41：ios_system 已删除，不再需要 @executable_path rpath 与 shellhelper 独立进程

# v3.3.0: MITM VPN appex —— 编译 VpnTunnel target + 组装 PlugIns/VpnTunnel.appex + 签名
# v4.3.50：曾禁用。根因实证：PlugIns/VpnTunnel.appex（networkextension 扩展、无图标文件）
# 在 TrollStore 侧载环境注册异常，分享面板打开时 MobileIcons 枚举扩展图标 → CoreImage SIGSEGV
# （崩溃栈固定：ShareSheet → SharingUI → MobileIcons LICreateIconForImages → CoreImage）。
# 只有 TrollAgent 崩、TrollFools/系统 App 不崩 = 只有它带异常 appex。
# VPN 抓包功能降级为 local proxy 模式（VpnTools.swift 已支持 appex 缺失自动降级）。
# v4.3.65：恢复构建（用户要求）。崩溃触发面已在 v4.3.46 定版绕开（分享全走 ShareCenter 自建菜单），
# 分享 Debug 入口 v4.3.64 已移除。
# ⚠️ 注意：VPN 抓包仍是半成品、开发中——隧道为"系统代理模式"（不转发 packetFlow）：
# 自建 socket 直连 App 在 VPN 下会断网、QUIC/HTTP3 不解密、TLS-pinned App 握手失败（已知边界）。
# 实际可用路径以 local proxy（WiFi 手动代理 127.0.0.1:18180）为准；appex 恢复便于继续开发调试。
if [ -d "openssl-stage/lib" ] && [ -f "openssl-stage/lib/libssl.a" ]; then
    echo ">>> swift build VpnTunnel appex (openssl-stage present)"
    if swift build -c release --product VpnTunnel \
        -Xswiftc -sdk -Xswiftc "$SDK" \
        -Xswiftc -target -Xswiftc arm64-apple-ios15.0 \
        -Xcc -isysroot -Xcc "$SDK" \
        -Xcc -target -Xcc arm64-apple-ios15.0 2>&1 | tail -5; then
        VT_BIN=".build/release/VpnTunnel"
        if [ -f "$VT_BIN" ]; then
            mkdir -p "$APP/PlugIns/VpnTunnel.appex"
            cp "$VT_BIN" "$APP/PlugIns/VpnTunnel.appex/VpnTunnel"
            cp "Support/VpnTunnel-Info.plist" "$APP/PlugIns/VpnTunnel.appex/Info.plist"
            if command -v ldid >/dev/null 2>&1; then
                if ldid -S"Support/VpnTunnel.entitlements" "$APP/PlugIns/VpnTunnel.appex/VpnTunnel"; then
                    echo ">>> signed VpnTunnel appex"
                else
                    echo "!!! VpnTunnel appex sign FAILED — removing (VPN mode unavailable)"
                    rm -rf "$APP/PlugIns/VpnTunnel.appex"
                fi
            else
                echo "!!! ldid missing; VpnTunnel appex unsigned — removing"
                rm -rf "$APP/PlugIns/VpnTunnel.appex"
            fi
        else
            echo "!!! VpnTunnel binary missing; VPN mode unavailable"
        fi
    else
        echo "!!! VpnTunnel build FAILED — VPN mode unavailable (local proxy mode still works)"
    fi
else
    echo "!!! openssl-stage missing — skipping VpnTunnel appex (VPN mode unavailable)"
fi

# 把特权 entitlements 签入主二进制，TrollStore 安装时才能继承 no-sandbox/no-container/task_for_pid 等权限
# v2.9.64：强制用 ldid 签名（TrollStore 官方明确要求 ldid -S 格式；codesign ad-hoc 签名格式不同，可能导致 entitlements 不被保留）
# v4.4.9-fix3by: Python 瘦身（大厂标配）——Python 官方 build 把完整 stdlib 复制进包（含 test/ 162MB 测试套件、
# idlelib 编辑器等生产用不到的模块）。删除后 App 448M→~260M（numpy/pandas/lib-dynload 全保留）。
if [ -d "$APP/python/lib/python3.14" ]; then
    echo ">>> python slim: removing test/idlelib/turtledemo/pydoc_data/__pycache__"
    rm -rf "$APP/python/lib/python3.14/test" "$APP/python/lib/python3.14/idlelib"            "$APP/python/lib/python3.14/turtledemo" "$APP/python/lib/python3.14/pydoc_data"            "$APP/python/lib/python3.14/__pycache__"
    find "$APP/python/lib" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
    echo ">>> python after slim: $(du -sh "$APP/python" | cut -f1)"
fi

if [ -f "Support/TrollAgent.entitlements" ]; then
    echo ">>> ldid sign main binary with entitlements"
    # CI 已 brew install ldid；优先用 macOS 原生 ldid（xerub ldid 对 iOS arm64e 兼容最好）
    LDID="$(command -v ldid || true)"
    if [ -z "$LDID" ]; then
        echo "!!! ldid not available; cannot inject entitlements" >&2
        exit 1
    fi
    "$LDID" -S"Support/TrollAgent.entitlements" "$APP/TrollAgent"
    echo ">>> signed main binary with ldid"
else
    echo "!!! Support/TrollAgent.entitlements missing" >&2
    exit 1
fi

mkdir -p Payload
cp -R "$APP" Payload/

zip -qry "$IPA" Payload
echo ">>> built: $IPA ($(du -h "$IPA" | cut -f1))"

# v2.9.206: 同时输出 TrollStore 原生 .tipa（TrollDecrypt/TrollFools 同款格式，
# TrollStore 对自家格式签名/entitlements 处理最完整）。tipa 即 zip（内含 Payload）。
cp "$IPA" TrollAgent.tipa
echo ">>> built: TrollAgent.tipa ($(du -h "TrollAgent.tipa" | cut -f1))"
