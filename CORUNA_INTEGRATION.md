# Coruna Web 注入集成技术文档

## 概述

将 Coruna 漏洞利用链集成到 TrollAgent v3.0.5，实现网页端一键注入 dylib 到任意 App。

## 漏洞利用链架构

```
WebView 加载 exploit 页面
    │
    ▼
Stage 1: WebKit RCE (CVE-2024-23222)
    ├─ 路径 A: iOS OfflineAudioContext 堆腐蚀 (Fq2t1Q_dbfd6e84.js)
    ├─ 路径 B: macOS NaN-Boxing 类型混淆 (YGPUu7_8dbfa3fd.js)
    └─ 路径 C: macOS JIT 结构检查消除 (KRfmo6_166411bd.js)
    │
    ▼
Stage 2: Wasm call_indirect 调度劫持
    └─ 覆盖 Wasm Table 中的 JIT 函数指针 → 任意原生调用
    │
    ▼
Stage 3: PAC 绕过 (arm64e GOT-Swap)
    └─ 通过 Apple 私有框架"混淆代理"伪造 PAC 签名
    │
    ▼
Stage 4: 沙盒逃逸 (mach_vm_allocate RWX)
    └─ 在 JIT 沙盒外分配可执行内存页
    │
    ▼
Stage 5: JIT Cage 逃逸 (PACDB Hash 伪造)
    └─ JavaScript 中伪造滚动哈希，通过内核 JIT 验证
    │
    ▼
Stage 6: Shellcode 执行 (mini dyld)
    └─ 加载 Mach-O，解析符号，应用重定位
    │
    ▼
Stage 7: 内核 exploit (CVE-2023-41974 IOSurfaceRoot)
    └─ IOSurface 漏洞 → 内核任意读写
    │
    ▼
Stage 8: PPL 绕过 (GPU 命令写物理内存)
    │
    ▼
Stage 9: AMFI 补丁
    ├─ 启用 Developer Mode (developer_mode_status)
    └─ 启用 Security Research Mode (allows_security_research)
    │
    ▼
完成：内核 R/W + 无签名执行 + 可注入任意 dylib
```

## 集成文件清单

### 新增 Swift 源文件
- `Sources/TrollMCP2/CorunaWebInjector.swift` (14KB)
  - 核心管理器，单例模式
  - 管理 exploit 生命周期状态机
  - 负责加载 exploit HTML 页面
  - 处理 WKScriptMessageHandler 回调

- `Sources/TrollMCP2/CorunaInjectView.swift` (16KB)
  - SwiftUI 用户界面
  - 目标 App 选择器
  - Dylib 文件选择器
  - 漏洞链进度可视化
  - 平台路径选择

### 修改的文件
- `Sources/TrollMCP2/SettingsView.swift`
  - 在 Coruna 安全盾下方添加 "Coruna Web 注入" 入口

### 资源文件 (Resources/coruna/)
- `coruna-dump/` (5MB) - 完整 Coruna dump
  - `samples/` - 28 个 JavaScript 模块
    - `Fq2t1Q_dbfd6e84.js` (29KB) - iOS OfflineAudioContext 路径
    - `YGPUu7_8dbfa3fd.js` (14KB) - macOS NaN-Boxing 路径
    - `KRfmo6_166411bd.js` (24KB) - macOS JIT 路径
    - `final_payload_A_*.js` / `final_payload_B_*.js` - 最终 payload
    - `ios_qeqLdN_*.js` / `ios_uOj89n_*.js` - iOS 备用路径
  - `extracted_binaries/` - 提取的二进制文件
    - `dump.bin` (2MB) - 内核 exploit Mach-O
    - `final_payload_*_shellcode.bin` (31KB each) - ARM64 shellcode
    - `final_payload_*_macho.bin` (89KB each) - Mach-O loader
  - `detailed_reports/` - 详细技术报告
  - `docs/` - 完整技术分析文档 (6630 行)
  - `kernel_analysis/` - 内核 exploit 逆向分析

## 设备兼容性

| 项目 | 你的设备 | 支持情况 |
|------|---------|---------|
| 型号 | iPhone 13 Pro Max (iPhone14,3) | ✅ arm64e (A15) |
| iOS 版本 | 16.3 | ✅ 13.0 - 17.2.1 范围内 |
| TrollStore | 已安装 | ✅ 已有内核级注入能力 |

## 使用流程

1. 打开 TrollAgent → 设置 → Coruna Web 注入
2. 选择目标 App（要注入的应用）
3. 选择要注入的 dylib 文件（Documents/dylibs/ 目录）
4. 选择利用路径（默认自动检测）
5. 点击"启动网页注入"
6. 观察漏洞链执行进度
7. 完成后自动注入 dylib 到目标 App

## 技术实现细节

### 状态机
```
idle → loadingPage → fingerprinting → webkitRCE → pacBypass 
     → shellcode → kernelExploit → ppLBypass → amfiPatch 
     → ready → injecting → success
                    ↓
                 failed / crashed
```

### 与 WebView 的通信
- 使用 `WKScriptMessageHandler` 实现 Swift ↔ JavaScript 双向通信
- JS 端通过 `window.webkit.messageHandlers.corunaCallback.postMessage()` 发送进度
- Swift 端解析 JSON 消息，更新 UI 状态

### 资源加载
- 所有 exploit 模块打包在 App Bundle 内 `coruna/coruna-dump/samples/`
- 通过 `Bundle.main.resourcePath` 定位
- 使用 `loadHTMLString` + `baseURL` 加载本地 exploit 页面

## 注意事项

1. **iOS 15.6 兼容**：Coruna 核心 exploit 仅支持 iOS 16.0+，iOS 15.6 上此功能不可用（UI 会显示不兼容警告）
2. **不破坏现有功能**：完全独立于现有 TrollFools 注入流程
3. **稳定性**：exploit 执行过程中 WebContent 进程可能崩溃，有重试机制
4. **研究用途**：此功能仅用于安全研究和学习目的

## 构建说明

```bash
# 标准构建流程
./scripts/build-ipa.sh

# 资源会自动打包：
# Resources/coruna/ → TrollMCP2.app/coruna/
```

## 参考资料

- Google GTIG Coruna 报告: https://cloud.google.com/blog/topics/threat-intelligence/coruna-powerful-ios-exploit-kit
- matteyeux 技术分析: https://matteyeux.com/posts/2026-03-06-coruna/
- NadSec 逆向分析: https://www.nadsec.online/blog/coruna
- GitHub dump: Rat5ak/CORUNA_IOS-MACOS_FULL_DUMP
