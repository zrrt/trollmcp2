#!/bin/bash
set -e

# ============================================================================
# Alpine Linux aarch64 Rootfs Preparation Script for iSH-ARM64
# ============================================================================
# This script downloads Alpine Linux minirootfs (aarch64) and converts it to
# iSH's fakefs format for use as a sandboxed ARM64 Linux environment.
#
# Repository: https://github.com/OpenMinis/ish-arm64 (branch: feature-arm64)
#
# Prerequisites:
#   - Python 3 with meson (pip3 install meson)
#   - Ninja (brew install ninja)
#   - libarchive (brew install libarchive)
#
# Usage:
#   ./prepare_alpine_rootfs.sh [version]
#
# Output:
#   deps/resources/alpine-rootfs/  - fakefs formatted rootfs
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$SCRIPT_DIR/ish"
OUTPUT_DIR="$SCRIPT_DIR/resources"
CACHE_DIR="$SCRIPT_DIR/.cache"

# Alpine configuration - aarch64 for ARM64 emulation
ALPINE_VERSION="${1:-3.21}"
ALPINE_MINOR="0"
ALPINE_ARCH="aarch64"  # ARM64 for iSH-ARM64 emulation
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

# ============================================================================
# Check Prerequisites
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v curl &> /dev/null; then
        log_error "curl is required"
    fi

    if ! command -v meson &> /dev/null; then
        log_error "Meson is required. Install with: pip3 install meson"
    fi

    if ! command -v ninja &> /dev/null; then
        log_error "Ninja is required. Install with: brew install ninja"
    fi

    # Check for libarchive
    LIBARCHIVE_FOUND=0
    for dir in "/opt/homebrew/opt/libarchive" "/usr/local/opt/libarchive" "/usr"; do
        if [ -f "$dir/lib/libarchive.dylib" ] || [ -f "$dir/lib/libarchive.a" ] || [ -f "$dir/lib/libarchive.so" ]; then
            LIBARCHIVE_FOUND=1
            break
        fi
    done

    if [ $LIBARCHIVE_FOUND -eq 0 ]; then
        log_error "libarchive is required. Install with: brew install libarchive"
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Download Alpine minirootfs
# ============================================================================
download_alpine() {
    log_info "Downloading Alpine Linux $ALPINE_VERSION.$ALPINE_MINOR for $ALPINE_ARCH..."

    mkdir -p "$CACHE_DIR"

    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local ROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/${ROOTFS_FILE}"

    if [ -f "$ROOTFS_PATH" ]; then
        log_info "Using cached rootfs: $ROOTFS_FILE"
    else
        log_info "Downloading from $ROOTFS_URL"
        curl -L -o "$ROOTFS_PATH" "$ROOTFS_URL" --progress-bar

        if [ ! -f "$ROOTFS_PATH" ]; then
            log_error "Failed to download rootfs"
        fi
    fi

    log_success "Alpine rootfs ready: $(du -h "$ROOTFS_PATH" | cut -f1)"
}

# ============================================================================
# Build fakefsify tool
# ============================================================================
build_fakefsify() {
    log_info "Building fakefsify tool..."

    local BUILD_DIR="$ISH_DIR/build-native"

    # Check if already built
    if [ -x "$BUILD_DIR/tools/fakefsify" ]; then
        log_info "fakefsify already built"
        return
    fi

    mkdir -p "$BUILD_DIR"
    cd "$ISH_DIR"

    # Configure for native build (not cross-compile)
    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        log_info "Configuring native meson build..."
        # Deliberately no -Db_ndebug here (unlike build_ish.sh, which disables
        # asserts for release). This build produces only tools/fakefsify, a
        # host-side tool that runs on this Mac and never ships to a device, so
        # a failed assert is a loud build failure rather than a user crash —
        # which is what we want while generating a rootfs.
        meson setup "$BUILD_DIR" \
            --buildtype=release \
            -Dlog="" \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64
    fi

    # Build only fakefsify
    log_info "Building fakefsify..."
    ninja -C "$BUILD_DIR" tools/fakefsify

    if [ ! -x "$BUILD_DIR/tools/fakefsify" ]; then
        log_error "Failed to build fakefsify"
    fi

    cd "$SCRIPT_DIR"
    log_success "fakefsify built successfully"
}

# ============================================================================
# Create fakefs rootfs
# ============================================================================
create_fakefs() {
    log_info "Creating fakefs rootfs..."

    local ROOTFS_FILE="alpine-minirootfs-${ALPINE_VERSION}.${ALPINE_MINOR}-${ALPINE_ARCH}.tar.gz"
    local ROOTFS_PATH="$CACHE_DIR/$ROOTFS_FILE"
    local PROVISIONED_PATH="$CACHE_DIR/${ROOTFS_FILE}.provisioned"
    local FAKEFSIFY="$ISH_DIR/build-native/tools/fakefsify"
    local OUTPUT_ROOTFS="$OUTPUT_DIR/alpine-rootfs"

    # v4.3.74：构建时预装常用工具（python3/pip/binutils/git/sqlite3/tar/unzip/curl）——
    # 手机端零网络零安装，AI 直接用；根治"运行时 apk 联网装工具老失败"。
    # 任一步失败自动降级为原始 minirootfs（运行时 ISHEngine.apkAdd 仍兜底），CI 不红。
    if [ -f "$ROOTFS_PATH" ] && [ ! -f "$PROVISIONED_PATH" ]; then
        provision_rootfs_tar "$ROOTFS_PATH" "$PROVISIONED_PATH"
    fi
    if [ -f "$PROVISIONED_PATH" ]; then
        ROOTFS_PATH="$PROVISIONED_PATH"
        log_info "Using pre-provisioned rootfs (python3/pip/binutils/git/sqlite3/tar/unzip/curl preinstalled)"
    fi

    # Remove existing rootfs
    if [ -d "$OUTPUT_ROOTFS" ]; then
        log_info "Removing existing rootfs..."
        rm -rf "$OUTPUT_ROOTFS"
    fi

    mkdir -p "$OUTPUT_DIR"

    # Convert to fakefs format
    log_info "Converting rootfs to fakefs format..."
    "$FAKEFSIFY" "$ROOTFS_PATH" "$OUTPUT_ROOTFS"

    if [ ! -d "$OUTPUT_ROOTFS/data" ] || [ ! -f "$OUTPUT_ROOTFS/meta.db" ]; then
        log_error "Failed to create fakefs rootfs"
    fi

    log_success "Fakefs rootfs created"
}

# ============================================================================
# v4.3.74: Pre-provision common tools into rootfs (build-time, zero network on device)
# ============================================================================
# macOS 宿主不能直接跑 aarch64 ELF，用 qemu-aarch64 跑 Alpine 官方静态 apk
# (apk.static) 做交叉安装；--no-scripts 不执行 guest 包脚本（纯解包安装）。
# 失败即降级（返回 0 用原始 minirootfs），保证 CI 不因预装失败而红。
provision_rootfs_tar() {
    local SRC_TAR="$1"
    local OUT_TAR="$2"

    command -v qemu-aarch64 >/dev/null 2>&1 || { log_warning "qemu-aarch64 缺失，跳过预装（运行时 apkAdd 兜底）"; return 0; }

    local STAGE="$CACHE_DIR/rootfs-stage"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    tar -xzf "$SRC_TAR" -C "$STAGE" 2>/dev/null || { log_warning "rootfs 解包失败，跳过预装"; return 0; }

    # 下载 Alpine aarch64 静态 apk（版本号从 APKINDEX 动态解析，失败回退已知版本）
    local IDX="$CACHE_DIR/APKINDEX.tar.gz"
    curl -sL -o "$IDX" "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main/${ALPINE_ARCH}/APKINDEX.tar.gz" 2>/dev/null || true
    local APKVER=""
    if [ -s "$IDX" ]; then
        APKVER=$(tar -xzO -f "$IDX" APKINDEX 2>/dev/null | grep -A2 '^P:apk-tools-static$' | grep '^V:' | head -1 | cut -d: -f2)
    fi
    [ -z "$APKVER" ] && APKVER="2.14.4-r0"
    curl -sL -o "$CACHE_DIR/apk-tools-static.apk" \
        "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}/main/${ALPINE_ARCH}/apk-tools-static-${APKVER}.apk" 2>/dev/null || true
    if [ ! -s "$CACHE_DIR/apk-tools-static.apk" ]; then
        log_warning "apk-tools-static 下载失败，跳过预装"
        return 0
    fi
    tar -xzf "$CACHE_DIR/apk-tools-static.apk" -C "$CACHE_DIR" sbin/apk.static 2>/dev/null || true
    chmod +x "$CACHE_DIR/sbin/apk.static" 2>/dev/null || true

    # qemu 交叉装包：常用工具链一次到位（--no-scripts 跳过 guest post-install）
    # v4.3.77：曾加 py3-pandas——实测 iSH 模拟器 import numpy/openblas 段错误闪退
    # （崩溃栈 cpu_run_to_interrupt），预装 pandas 反成陷阱，v4.4.2 移除。
    qemu-aarch64 "$CACHE_DIR/sbin/apk.static" add --root "$STAGE" --arch "$ALPINE_ARCH" --no-scripts \
        --repository "https://mirrors.aliyun.com/alpine/v${ALPINE_VERSION}/main" \
        --repository "https://mirrors.aliyun.com/alpine/v${ALPINE_VERSION}/community" \
        python3 py3-pip binutils git file sqlite3 tar unzip curl ca-certificates \
        > "$CACHE_DIR/provision.log" 2>&1
    local RC=$?
    if [ $RC -ne 0 ]; then
        log_warning "预装失败(rc=$RC)，降级为原始 minirootfs；日志尾部: $(tail -1 "$CACHE_DIR/provision.log" 2>/dev/null)"
        return 0
    fi

    tar -czf "$OUT_TAR" -C "$STAGE" . 2>/dev/null || { log_warning "预装后重打包失败，降级"; return 0; }
    log_success "预装完成: python3/pip/binutils/git/sqlite3/tar/unzip/curl (size $(du -h "$OUT_TAR" 2>/dev/null | cut -f1))"
}

# ============================================================================
# Configure rootfs for iSH
# ============================================================================
configure_rootfs() {
    log_info "Configuring rootfs for iSH..."

    local ROOTFS_DATA="$OUTPUT_DIR/alpine-rootfs/data"

    # Create necessary directories
    mkdir -p "$ROOTFS_DATA/dev"
    mkdir -p "$ROOTFS_DATA/proc"
    mkdir -p "$ROOTFS_DATA/sys"
    mkdir -p "$ROOTFS_DATA/tmp"
    mkdir -p "$ROOTFS_DATA/run"
    mkdir -p "$ROOTFS_DATA/root"
    mkdir -p "$ROOTFS_DATA/home"

    # Configure /etc/passwd - set root shell
    if [ -f "$ROOTFS_DATA/etc/passwd" ]; then
        # Ensure root has /bin/sh as shell
        sed -i.bak 's|^root:.*|root:x:0:0:root:/root:/bin/sh|' "$ROOTFS_DATA/etc/passwd"
        rm -f "$ROOTFS_DATA/etc/passwd.bak"
    fi

    # Configure /etc/profile for better shell experience
    cat >> "$ROOTFS_DATA/etc/profile" << 'EOF'

# MinisApp iSH Configuration
export PS1='\u@minis:\w\$ '
export TERM=xterm-256color
export HOME=/root
export LANG=C.UTF-8
export CHARSET=UTF-8
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/bin

# Aliases
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'

cd ~
EOF

    # DNS（v3.0.40）：minirootfs 无 /etc/resolv.conf，guest 内 DNS 解析全失败。
    # 预置国内可达的公共 DNS（阿里/腾讯 + Google 兜底），apk/curl/python 网络即开即用。
    cat > "$ROOTFS_DATA/etc/resolv.conf" << 'EOF'
nameserver 223.5.5.5
nameserver 119.29.29.29
nameserver 8.8.8.8
EOF

    # Create /etc/motd
    cat > "$ROOTFS_DATA/etc/motd" << 'EOF'

  __  __ _       _        _    _ _
 |  \/  (_)_ __ (_)___   | |  (_) |_ ___
 | |\/| | | '_ \| / __|  | |  | | __/ _ \
 | |  | | | | | | \__ \  | |__| | ||  __/
 |_|  |_|_|_| |_|_|___/  |____|_|\__\___|

 Welcome to MinisApp Linux Shell
 Alpine Linux aarch64 on iSH-ARM64 Emulator

EOF

    # Configure /etc/inittab for single user mode (iSH handles tty)
    cat > "$ROOTFS_DATA/etc/inittab" << 'EOF'
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default
::ctrlaltdel:/sbin/reboot
::shutdown:/sbin/openrc shutdown
EOF

    # Configure resolv.conf for DNS
    cat > "$ROOTFS_DATA/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

    # Configure APK repositories
    # v4.3.69: 预置国内镜像源（阿里云 HTTPS）——官方 dl-cdn.alpinelinux.org 在国内手机网络下
    # HTTPS 常被断(SSL unexpected eof/Permission denied)，apk 索引拉不下会误报 "no such package"。
    # 同时把宿主 CA 证书拷进 rootfs（minirootfs 无 ca-certificates，HTTPS 握手必失败）。
    cat > "$ROOTFS_DATA/etc/apk/repositories" << EOF
https://mirrors.aliyun.com/alpine/v${ALPINE_VERSION}/main
https://mirrors.aliyun.com/alpine/v${ALPINE_VERSION}/community
EOF

    # CA 证书：优先拷宿主系统证书（macOS /etc/ssl/cert.pem、Linux /etc/ssl/certs/ca-certificates.crt），
    # 否则留空由运行时 ISHEngine.apkAdd 自动补 ca-certificates 包。
    if [ -f /etc/ssl/cert.pem ]; then
        mkdir -p "$ROOTFS_DATA/etc/ssl"
        cp /etc/ssl/cert.pem "$ROOTFS_DATA/etc/ssl/cert.pem"
        log_success "Copied host CA bundle into rootfs (/etc/ssl/cert.pem)"
    elif [ -f /etc/ssl/certs/ca-certificates.crt ]; then
        mkdir -p "$ROOTFS_DATA/etc/ssl/certs"
        cp /etc/ssl/certs/ca-certificates.crt "$ROOTFS_DATA/etc/ssl/certs/ca-certificates.crt"
        log_success "Copied host CA bundle into rootfs (/etc/ssl/certs/ca-certificates.crt)"
    else
        log_warning "No host CA bundle found; runtime apkAdd will install ca-certificates package"
    fi

    log_success "Rootfs configured"
}

# ============================================================================
# Create ZIP Archive
# ============================================================================
create_zip_archive() {
    log_info "Creating ZIP archive..."

    local ROOTFS_DIR="$OUTPUT_DIR/alpine-rootfs"
    local ZIP_FILE="$OUTPUT_DIR/alpine-rootfs.zip"

    # Remove existing zip
    rm -f "$ZIP_FILE"

    # Create zip (exclude WAL files)
    cd "$OUTPUT_DIR"
    zip -r "alpine-rootfs.zip" "alpine-rootfs" \
        -x "*.db-shm" \
        -x "*.db-wal" \
        > /dev/null

    cd "$SCRIPT_DIR"

    if [ ! -f "$ZIP_FILE" ]; then
        log_error "Failed to create ZIP archive"
    fi

    log_success "ZIP archive created: $(du -h "$ZIP_FILE" | cut -f1)"
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    local ROOTFS_DIR="$OUTPUT_DIR/alpine-rootfs"
    local ZIP_FILE="$OUTPUT_DIR/alpine-rootfs.zip"

    echo ""
    echo "============================================================"
    echo -e "${GREEN}🎉 Alpine Rootfs Preparation Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Output files:"
    echo "  📁 $ROOTFS_DIR"
    echo "  📦 $ZIP_FILE"
    echo ""
    echo "Sizes:"
    echo "  Data:     $(du -sh "$ROOTFS_DIR/data" | cut -f1)"
    echo "  Database: $(du -h "$ROOTFS_DIR/meta.db" | cut -f1)"
    echo "  ZIP:      $(du -h "$ZIP_FILE" | cut -f1)"
    echo ""
    echo "To use in MinisApp:"
    echo "  1. Add alpine-rootfs.zip to Xcode project resources"
    echo "  2. Extract to Documents on first launch"
    echo "  3. Use mount_root(&fakefs, path_to_data)"
    echo ""
    echo "============================================================"
}

# ============================================================================
# Clean
# ============================================================================
clean() {
    log_info "Cleaning..."

    rm -rf "$OUTPUT_DIR/alpine-rootfs"
    rm -rf "$ISH_DIR/build-native"
    rm -rf "$CACHE_DIR"

    log_success "Clean completed"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  Alpine Linux aarch64 Rootfs Preparation for iSH-ARM64"
    echo "  Version: $ALPINE_VERSION.$ALPINE_MINOR ($ALPINE_ARCH)"
    echo "============================================================"
    echo ""

    check_prerequisites
    download_alpine
    build_fakefsify
    create_fakefs
    configure_rootfs
    create_zip_archive
    print_summary
}

# Parse arguments
case "${1:-}" in
    clean)
        clean
        exit 0
        ;;
    --help|-h)
        echo "Usage: $0 [version|clean]"
        echo ""
        echo "Arguments:"
        echo "  version    Alpine version (default: 3.21)"
        echo "  clean      Remove all generated files"
        echo ""
        echo "Examples:"
        echo "  $0           # Use default version 3.21"
        echo "  $0 3.18      # Use Alpine 3.18"
        echo "  $0 clean     # Clean all files"
        exit 0
        ;;
    *)
        main
        ;;
esac
