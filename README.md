# TrollMCP 2

基于 TrollMCP v0.14.15 功能盘点的对等重构（Swift + SwiftUI + SwiftPM）。
源码全部在 Git 里，永不再丢。

## 里程碑

- **M1（当前）**：App 骨架 + MCPCore 工具分发 + 文件桥（`artifact.read_text / write_text / list`）+ `ping / device.info` + 首页网格/列表切换 UI
- M2：模型接入（多模型配置、OpenAI 兼容 API）
- M3：注入管理 + App 目录
- M4：Gateway 配对（WebSocket）+ 自动化中心
- M5：系统能力（通讯录/日历/提醒/通知/定位/语音识别/扫码）
- M6：编译模式 + 完整网格 UI

完整规划见 `../DeviceBuild/REBUILD_PLAN.md`。

## 构建

```bash
bash scripts/build-ipa.sh   # 需要 macOS + Xcode 命令行工具
# 或 GitHub Actions: build-trollmcp2 workflow（手动触发）
```

产物是**未签名** `TrollMCP2.ipa`，用 TrollStore 安装即可（安装时自动签名）。

## 结构

```
Sources/TrollMCP2/
├── AppMain.swift     # UIApplication 入口，注册内置工具
├── RootView.swift    # SwiftUI 根视图（TabView + 网格/列表切换）
├── MCPCore.swift     # ToolRegistry / MCPTool 协议 / Workspace（防目录穿越）
├── JSONRPC.swift     # 最小 JSON-RPC 2.0（initialize / tools/list / tools/call）
└── Tools.swift       # 内置工具：artifact.* 文件桥 + ping + device.info
Support/Info.plist    # Bundle ID dev.trollmcp2.app，iOS 14.0+
scripts/build-ipa.sh  # 交叉编译 + 组装 .app + 打包 IPA
```
