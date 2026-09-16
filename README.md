# TrollAgent（原 TrollMCP2）

**AI 驱动的 iOS 巨魔（TrollStore）实验与 QA 工作台** —— Swift + SwiftUI + SwiftPM，跑在 iOS 14+ / TrollStore 环境，内置 175+ 个 MCP 工具，AI 通过自然语言调用全部能力。

## 核心能力全景

### 🧩 注入与自动化（对齐 TrollFools 注入策略）
- `injection.enable/disable/remove/restore`：dylib 注入、移除、备份恢复（`.bak_macho` 自动回滚）
- `injection.verify`：注入后健康检查（Mach-O 加载命令 + 进程存活 + 崩溃检测，4 级判定）
- `injection.mem`：内存注入（opainject，零文件残留）；`probe.inspect` / `hook.apply`
- `rescue.scan/recover_all/cleanup`：紧急恢复（Residue 式，防"注入后 App 打不开"死局）
- 注入失败自动回滚 + 注入后启动自检（闪退自动还原）

### 📱 应用管理
- `app.start/stop/restart/status/stats`：进程管理（start 三级降级：open -b → direct_exec → url_scheme）
- `app.diagnose`：启动失败自动判因（注入残留/加密/签名/崩溃现场 → 明确 next_step）
- `app.install/uninstall`：AI 安装/卸载 App（trollstorehelper 静默安装优先）
- `app.decrypt` / `app.encrypt_info`：内置砸壳引擎（DecryptEngine：task_for_pid + vm_read 内存 dump → 重建解密镜像 → 打包 ipa）
- `ipa.inspect` / `dylib.inspect`：IPA/dylib 解析（架构/签名/entitlements/依赖，区分"解析失败"与"真没有"）

### 🧹 系统清理（对齐 Fuck 工具箱）
- 存储环形卡片 + 6 类缓存占用 + 快速/高级清理 Tab + 一键清理（setuid root 整目录重建）

### 📂 文件系统（Filza 式，18 个工具）
- `fs.tree/read/hexdump/zip/sqlite/grep/write/edit/diff/hash/find/download/plist/container/crash/imageinfo`

### 🌐 浏览器（WKWebView + JS 注入，仿 Playwright）
- `browser.open/navigate/snapshot/click/type/submit/scroll/eval/wait` + 元素绝对 xpath
- `browser.form_fields/fill_form`：整表自动填充（React/Vue 兼容 value setter + 事件）
- `browser.wait_for`：元素/正文关键词轮询等待

### 🎮 设备伪装（绿盾式）
- `device.fake/restore`：内存注入 FakeDevice.dylib 改 UIDevice 机型（零残留，重启还原）
- `new_device`（一键新机）/ `keychain.wipe/reset` / `idfv` / `advertising`

### 🛡️ 安全检测
- `device.probe`：TrollStore / task_for_pid / 容器读写 / 注入工具链全项检测

### 🔌 控制（跨 App UI 控制）
- 注入 ControlAgent.dylib → localhost:4789 HTTP API（/status /ui_tree /tap /swipe /type）

### 🏗️ 构建与工程
- `build.env/run`：theos tweak 编译、GitHub Actions 触发/产物下载（GitHub 多账号）
- `project/task`：工作区项目管理；`artifact.find` 定位编译产物

### 🤖 AI 与模型
- 多上游模型（OpenAI 兼容 API）、SSE 流式逐字输出、推理强度控制、智能搜索
- `tool_search` 渐进式披露（不必 175 工具全量进请求）、技能系统（skills.*）

### 📡 网关与自动化
- Gateway WebSocket 配对、多节点调用、定时任务（cron）、自动化中心（automation.*）

### 📊 网络与诊断
- `web.search/fetch`（Bing 桌面 UA 三级解析）、`network.capture` 抓包
- `log.collect`、崩溃日志解析、`diagnose.startup/crash`、`test.run` 一键测试编排

### 📚 知识库与系统能力
- 知识库增删查、助手记忆、通讯录/日历/提醒/通知/定位/扫码/剪贴板/电话

## 架构要点
- **注册中心**：`MCPCore.swift` 单点注册全部工具，`tool_search` 按需披露 schema
- **TrollStore 机制**：内置 setuid root 工具链（ldid/optool/insert_dylib/ct_bypass）、trollstorehelper 静默安装
- **失败边界**：高优先级工具统一 `error_code/reason/next_step`，拒绝误导性报错

## 构建
macOS runner / 本地 Mac：`bash scripts/build-ipa.sh`（产物 TrollMCP2.ipa，TrollStore 直接安装）。
CI 传 `RELEASE_VERSION` 自动注入产物版本（解决版本脱节）。
