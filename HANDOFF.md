# TrollMCP2 项目交接文档

> 版本：v2.9.5 | 最后更新：2026-09-02 | 仓库：github.com/origina47487lhe-droid/trollmcp2（私有）

---

## 1. 项目目标

基于原版 TrollMCP v0.14.15 的二进制静态分析 + 用户截图，功能对等重构一个 iOS MCP 客户端 App。原版源码已丢失（前搭档数据被删），只能从 Mach-O 字符串/符号逆向 + 截图对照重写。

**边界**：只复刻 MCP 客户端本体功能。原版包内 `DeveloperInstructions.md` 含外挂/反作弊/凭据攻击内容，一律不实现。

---

## 2. 技术栈与约束

| 项 | 值 |
|---|---|
| 语言 | Swift 5.10 / SwiftUI |
| 构建系统 | SwiftPM（`Package.swift`） |
| 部署目标 | iOS 14.0（TrollStore 侧载，非越狱） |
| 架构 | arm64 only |
| CI | GitHub Actions macos-14 runner |
| 产物 | 未签名 IPA → TrollStore 安装时自动签名 |
| 仓库 | `github.com/origina47487lhe-droid/trollmcp2`（私有） |

### iOS 14 禁区（踩过的坑，必须遵守）

- SwiftUI 颜色 `.indigo/.teal/.cyan/.brown` 是 iOS15+ → 用 `Color.tmIndigo/tmTeal/tmCyan/tmBrown`
- `Section("标题")` 字面量 init 是 iOS15+ → 用 `Section(header: Text("标题"))`
- `.bordered/.borderedProminent` 按钮样式不可用
- `TextField(axis:)` / `textSelection(.enabled)` / `@Environment(\.dismiss)` 不可用
- `Package.swift` 的 `.executableTarget` 不支持 `linkedFrameworks`（Swift import 自动链接）
- `UNUserNotificationCenter.authorizationStatus` 是 iOS15+ → 用 `getNotificationSettings` + 信号量
- `WEXITSTATUS` 不在 iOS → 手算 `(UInt32(st) >> 8) & 0xff`
- 嵌套 NavigationView + sheet 在 iOS14 上有 bug（onAppear 重触发冲掉表单）→ 子页不包 NavigationView 或在 init 里初始化 State
- `guard` 后必须显式 `return`

---

## 3. 目录结构

```
TrollMCP2/
├── Package.swift                  # SwiftPM 包定义（单 executable target）
├── Support/
│   ├── Info.plist                 # CFBundleShortVersionString=2.8.3, min iOS 14.0, 8 项隐私权限描述
│   └── TrollMCP2.entitlements     # TrollStore 特权（no-sandbox/no-container/task_for_pid 等 16 项）
├── Sources/TrollMCP2/             # 全部 Swift 源码（31 个文件，~7240 行）
│   ├── AppMain.swift              # @main 入口，UIApplicationMain + AppDelegate
│   ├── RootView.swift             # ZStack: ChatView + 左侧抽屉 + Settings sheet
│   ├── ChatView.swift             # 聊天主界面（消息列表 + 模型条 + 输入栏）
│   ├── Models.swift               # ★ ModelConfig + ModelStore + ModelAPIClient + ConversationStore
│   ├── ModelsView.swift           # 模型 API 配置页 + 编辑器 + 测试连接
│   ├── OpenAIClient.swift         # ★ API 客户端（OpenAI/DeepSeek/Anthropic/Custom 兼容）
│   ├── MCPCore.swift              # ★ ToolRegistry + MCPTool 协议 + Workspace + 工具注册
│   ├── AllMCPTools.swift          # 全部工具的 invoke 实现（apps/injection/gateway/automation/系统）
│   ├── OriginalTools.swift        # AutomationStore + GatewayServerStore + 原版命名工具
│   ├── MissingTools.swift         # 12 个补齐设备端工具（calendar/reminder/device/web/knowledge/phone/skills）
│   ├── InjectionManager.swift     # posix_spawn 调 insert_dylib + ldid 真注入
│   ├── GatewayClient.swift        # WebSocket 握手（hello+token → ready/paired）
│   ├── DeviceProbe.swift          # 本机环境自检（TrollStore/task_for_pid/容器读写/注入二进制）
│   ├── AppTools.swift             # apps.cache_inspect/clear/open + wechat
│   ├── AssistantMemoryTools.swift # assistant.memory_* (UserDefaults)
│   ├── AppCatalog.swift           # LSApplicationWorkspace 已装应用枚举
│   ├── AppPickerView.swift        # 应用选择器
│   ├── AttachmentPanelView.swift  # 附件面板（应用/相册/文件）
│   ├── AuditLog.swift             # 审计日志
│   ├── DeviceDetectionView.swift  # 环境检测 UI
│   ├── GatewayView.swift          # Gateway 设置 UI
│   ├── InjectionView.swift        # 注入管理 UI
│   ├── JSONRPC.swift             # JSON-RPC 消息封装
│   ├── MoreViews.swift            # 设置子页（权限/数据/知识库/Webhook/Agent）
│   ├── OriginalViews.swift       # 原版视图复刻（OperationView/ApprovalSheet/AutomationCenter 等）
│   ├── SettingsView.swift        # 设置页
│   ├── ToolAuditView.swift       # 本机工具审计
│   ├── Tools.swift               # artifact.*/ping/device.info 基础工具
│   ├── ToolsView.swift            # 工具列表 UI
│   └── UIComponents.swift         # 通用 UI 组件
├── Resources/
│   └── bin/                       # 18 个注入工具链二进制（从原版提取）
│       ├── TrollMCPAgent.dylib    # 111KB，注入目标 App 的剪贴板桥 agent
│       ├── ldid                   # 2.4MB（含依赖库）
│       ├── insert_dylib           # 109KB
│       ├── optool                 # 163KB
│       ├── ct_bypass              # 244KB
│       ├── install_name_tool      # 210KB
│       ├── cp/mv/rm/mkdir/chown  # coreutils
│       ├── cp-15/mv-15           # iOS15 变种
│       └── libcrypto.3/libintl.8/libiosexec.1/libxar.1  # 依赖 dylib
├── scripts/
│   └── build-ipa.sh              # 交叉编译 + 组装 .app + codesign 签名 + zip IPA
├── .github/workflows/
│   └── build-trollmcp2.yml        # workflow_dispatch 手动触发
└── .gitignore                     # artifacts/ 被 ignore
```

---

## 4. 构建与部署流程

### 本地构建（需 macOS）

```bash
cd TrollMCP2
bash scripts/build-ipa.sh
# 产物：TrollMCP2.ipa
```

### GitHub Actions 构建

1. 推代码到 `main`
2. 去 GitHub Actions 页面手动触发 `build-trollmcp2` workflow
3. 等待 macos-14 runner 完成（约 30s）
4. 下载 artifact `TrollMCP2-ipa`

### build-ipa.sh 执行流程

```
1. xcrun --sdk iphoneos --show-sdk-path → 获取 iOS SDK
2. swift build -c release -Xswiftc -sdk/-target arm64-apple-ios14.0 -Xcc -isysroot/-target → 交叉编译
3. 组装 TrollMCP2.app：
   - cp 主二进制
   - cp Info.plist
   - cp -R Resources/bin → .app/bin（18 个注入工具）
   - cp Resources/* → .app/（其他资源）
4. codesign -s - -f --entitlements Support/TrollMCP2.entitlements TrollMCP2.app/TrollMCP2
   → 给主 Mach-O 做 ad-hoc 签名 + 注入特权 entitlements
   （ldid -S 不可用：Homebrew ldid 2.1.5 对 Swift 交叉编译的 Mach-O 断言失败）
5. zip -qry TrollMCP2.ipa Payload
```

### 安装

IPA 未签名，通过 TrollStore 安装。TrollStore 会自动签名并继承 entitlements。

### 版本号修改

同时改两个地方：
- `Support/Info.plist` → `<key>CFBundleShortVersionString</key><string>X.Y.Z</string>`
- `Sources/TrollMCP2/SettingsView.swift` → `LabeledRow(label: "版本", value: "X.Y.Z")`

---

## 5. 三层架构

从原版 v0.14.15 二进制逆向确认的三层架构：

### 第一层：设备端真实执行（在 iPhone 上跑）

| 模块 | 实现文件 | 机制 |
|------|---------|------|
| **Apps/Device/Web** | AppTools.swift, MissingTools.swift | LSApplicationWorkspace, EventKit, CoreLocation, UNUserNotificationCenter, Vision, Bing HTML parse |
| **Injection** | InjectionManager.swift | posix_spawn 调包内 `insert_dylib --inplace` → `ldid -S` 重签；备份 `.bak_macho` |
| **Automation** | OriginalTools.swift | UNUserNotificationCenter 本地通知调度 + Ledger |
| **Knowledge** | MissingTools.swift | 本机文件知识库 |
| **System** | AllMCPTools.swift | Contacts, Calendar, Reminder, Location, Notification, QR, Process |
| **Build（v2.9.3+）** | BuildTools.swift | 设备端编译桥：`build.environment` 探测 toolchain/clang/make/theos/SDK；`build.run` 用 posix_spawn + `/bin/sh -c "cd ... && exec ..."` 编译；v2.9.4 支持 toolchain=system（越狱 Nyxian 系统布局）与绝对路径 |
| **GitHub 账号（v2.9.5）** | GitHubAccountStore.swift + GitHubAccountView.swift | App 内多 GitHub 账号 PAT 登录/切换/删除；触发仓库 Actions workflow 线上编译；查询 run 状态。仓库 owner/name/workflow/branch 可在设置页配置 |
| **build-tweak workflow** | .github/workflows/build-tweak.yml | 线上编译 tweak：macOS runner + theos（递归 submodule，dm.pl 软链目标需 submodule）+ Xcode SDK 软链 iPhoneOS17.5.sdk + brew ldid/dpkg；触发方式 `gh workflow run build-tweak -f tweak=<name>` |

### 第二层：设备端 WS 客户端（真发消息，执行在服务端）

| 模块 | 实现文件 | 机制 |
|------|---------|------|
| **Gateway** | GatewayClient.swift | WebSocket 握手（hello+token → 等服务端 ready/paired），iOS 无 shell，真执行在用户自建 Gateway |

### 第三层：AI 模型 API（用户自配）

| 模块 | 实现文件 | 机制 |
|------|---------|------|
| **Model API** | OpenAIClient.swift, Models.swift | OpenAI Chat Completions / OpenAI Responses / Anthropic Messages / Custom Endpoint |

---

## 6. 核心数据流：聊天 → 模型 → 工具调用闭环

```
用户输入文字
  ↓
ChatView → ConversationStore.send(text, config)
  ↓
appendToCurrent(user message)
  ↓
runLoop(config, tools, depth=0)
  ↓
OpenAIClient.send(messages, tools)
  ├─ apiProtocol == "Anthropic Messages" → POST {base}/messages
  ├─ apiProtocol == "OpenAI Responses" → POST {base}/responses（v2.9.0，Codex 同款）
  └─ apiProtocol == "OpenAI Chat Completions" / "Custom" → POST {base}/chat/completions
  ↓
  请求体：
  {
    "model": config.model,
    "messages": [...],
    "max_tokens" 或 "max_completion_tokens": config.maxTokens,  ← 推理模型用后者
    "temperature": 0.7,            ← 推理模型不发（gpt-5.x/o1/o3/o4）
    "tools": [...],                 ← 非推理模型时发送所有已启用工具的 schema
    "tool_choice": "auto"
  }
  ↓
  鉴权头（applyAuth）：
  - Bearer → "Authorization: Bearer {apiKey}"
  - API Key → "x-api-key: {apiKey}"
  - None → 不发
  - 空/未知 + key 非空 → 默认 Bearer
  ↓
模型返回 → 解析 choices[0].message
  ├─ 有 tool_calls → 本地 ToolRegistry.dispatch 执行 → 结果以 role=tool 回传 → runLoop depth+1（最多 6 轮）
  └─ 纯文本 → 显示给用户
```

### 工具注册

`AppDelegate.didFinishLaunching` → `ToolRegistry.shared.registerBuiltinTools()`

注册了 **57 个工具**（见 MCPCore.swift `registerBuiltinTools()`），分为 7 组：
- M1: artifact.read_text/write_text/list + ping + device.info/probe + workspace.info（7 个）
- M2: assistant.memory_set/list/delete（3 个）
- M3: apps.cache_inspect/clear/open/open_and_input + wechat.prepare_message（5 个）
- M4: injection.enable/disable/status/inspect/list/remove + container.write_text/delete（8 个）
- M5: gateway.status/connect + node_invoke + gateway.node_invoke/channel_send/cron_create/run/cancel + cron.fire + automation.run_now/list/jobs/stop/cancel/history/set_enabled/status（16 个）
- M6: contacts.search + calendar.list + reminder.create + location.get + notification.send + scan.qr + process.list（7 个）
- M7: build.runner.token + project.generate_tweak + model.config/authentication/selectedProfileID + workspace.outputBookmark/outputName（7 个）
- M8: calendar.create_event + reminder.schedule/schedule_recurring + device.snapshot + web.search + knowledge.import_text/import_file/search/delete + phone.call/schedule_call + skills.set_enabled（12 个）

### 工具 schema 转换

`Array<TargetDefinition>.openAIToolSchema()` 把每个工具转成 OpenAI tools 参数格式：
```json
{
  "type": "function",
  "function": {
    "name": "apps.cache_inspect",
    "description": "检查应用缓存大小",
    "parameters": {
      "type": "object",
      "properties": { "bundle_id": {"type":"string","description":"..."} },
      "required": ["bundle_id"]
    }
  }
}
```

---

## 7. 模型 API 配置（★ 当前问题所在）

### ModelConfig 字段

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| name | String | - | 显示名 |
| provider | String | - | openai/deepseek/anthropic/custom |
| apiProtocol | String | "OpenAI Chat Completions" | 协议选择 |
| baseURL | String | - | 如 https://botcf.com/v1 |
| apiKey | String | - | API 密钥 |
| model | String | - | 如 gpt-5.6-terra |
| authMethod | String | "Bearer" | Bearer / API Key / None |
| temperature | Double | 0.7 | 推理模型自动省略 |
| maxTokens | Int | 4096 | 推理模型用 max_completion_tokens |
| isDefault | Bool | false | 是否默认配置 |

### 计算属性（v2.8.3 新增）

```swift
// 推理模型（gpt-5./o1/o3/o4/reasoning）不接受 temperature
var sendsTemperature: Bool { ... }

// 推理模型用 max_completion_tokens 而非 max_tokens
var maxTokensKey: String { ... }
```

### 供应商预设

```swift
static let providerPresets = [
    ("OpenAI",    "openai",    "OpenAI Chat Completions", "https://api.openai.com/v1",      "gpt-4o-mini",        "Bearer"),
    ("DeepSeek",  "deepseek",  "OpenAI Chat Completions", "https://api.deepseek.com/v1",    "deepseek-chat",      "Bearer"),
    ("Anthropic", "anthropic", "Anthropic Messages",     "https://api.anthropic.com/v1",   "claude-3-5-sonnet-20240620", "API Key"),
    ("Botcf",     "custom",    "OpenAI Chat Completions", "https://botcf.com/v1",           "gpt-5.6-terra",      "Bearer")
]
```

### 测试连接逻辑

`ModelAPIClient.testConnection`：
- 发一个最简请求（`messages: [{"role":"user","content":"hi"}]`，maxTokens 限制为 8）
- 成功 → "连接成功 (HTTP 200)"
- 失败 → 显示 HTTP 状态码 + 原始响应前 200 字符

### 持久化

`ModelStore` 用 `UserDefaults.standard.data(forKey: "trollmcp2.model_configs")` 存储 JSON 编码的 `[ModelConfig]`。

`ConversationStore` 用 `UserDefaults.standard.data(forKey: "trollmcp2.conversations")` 存储对话历史。

---

## 8. ★ 当前未解决的问题：模型连接失败

### 症状

用户使用**中转 API**（Botcf, https://botcf.com/v1）+ `gpt-5.6-terra` 模型，聊天时报错：

```
Invalid request parameter (request id: ...)
type: invalid_request_error
param: ""
code: unknown_error
```

### 已做的修复（v2.8.0 → v2.8.4）

| 版本 | 修复 | 效果 |
|------|------|------|
| v2.8.0 | 真实化所有工具执行层 | 功能补全 |
| v2.8.1 | 注入 TrollStore 特权 entitlements | TrollStore 权限检测通过 |
| v2.8.2 | authMethod 空串 → 回退 Bearer | "Missing bearer authentication" 消失 |
| v2.8.3 | 推理模型省略 temperature + 改用 max_completion_tokens | 参数兼容（但用户报仍无法使用） |
| **v2.8.4** | **自适应兼容降级**（详见下节） | 客户端自动逐级试探中转站可接受的参数组合 |

### v2.8.4：自适应兼容降级（当前最新方案）

**不再猜测中转站支持哪些参数，让 App 自己试探并记住结果。**

`OpenAIClient` 在收到 4xx 参数类错误时自动逐级简化请求体：

| 级别 | 载荷 |
|------|------|
| 0 | 完整载荷（tools + tool_choice + 推理模型参数适配） |
| 1 | 互换 token key（max_completion_tokens ↔ max_tokens） |
| 2 | 去掉 tool_choice |
| 3 | 去掉 tools（纯对话；历史中的 tool 消息自动降级为普通文本） |
| 4 | 最小载荷（仅 model + messages） |

- 成功后把可用级别写入 `ModelConfig.compatLevel` 持久化，下次直接从该级别发起
- 兼容 new-api 中转「HTTP 200 + error body」的非标准返回
- 鉴权(401/403)、配额(429)、超时(408) 不降级（换载荷无意义）
- `testConnection` 改为最小载荷（旧版 `max_completion_tokens=8` 低于推理模型最低推理 token 预算，必然 400——这很可能就是"测试连接"一直失败的原因）
- 新增 `NetworkDebugView`（设置 → 关于 → 网络兼容日志）：查看各模型当前级别 + 每次请求的字段与结果，可手动重置级别

### 网上调研结论（2026-08 检索）

1. **GPT-5.6 家族（sol/terra/luna）在 chat/completions 上对 function tools + reasoning_effort 组合有限制**（CrewAI 社区 bug 报告）：报错 "Function tools with reasoning_effort are not supported... use /v1/responses or set reasoning_effort to 'none'"。模型默认 reasoning_effort=medium，即带 tools 的请求可能直接被拒。
2. **gpt-5.6-terra 实测超过 ~64 个并行工具定义会触发 500**（treerouter 社区压测）。TrollMCP2 发 57 个，接近阈值，中转站可能更严格。
3. **reapi.ai 实测**：gpt-5.6-terra 在 chat/completions 接受 `max_tokens` 或 `max_completion_tokens`（≤128k）、接受 tools；但**拒绝** frequency_penalty / presence_penalty / stop（400）。
4. 错误 `type: new_api_error` 证实 Botcf 是 new-api 系中转；new-api 会把上游 400 包装成自己的错误格式。

→ 若 v2.8.4 仍失败，看「网络兼容日志」里停在哪个级别；若级别 4（最小载荷）仍 400，则问题在鉴权或模型名，不在参数。

### 仍可能的原因（v2.8.4 之后）

1. **模型名不匹配**：中转站可能要求 `openai/gpt-5.6-terra` 而非 `gpt-5.6-terra`。

2. **API key 本身无效**：中转站可能对 key 格式有要求。

### 排查建议（v2.8.4 后剩余问题）

1. **先看 App 内「网络兼容日志」**：它会显示每次请求降级到哪个级别、每个级别的失败原因——这是首要排查入口，不再需要 curl 对比。

2. **对比 curl**：让用户用 curl 发同样的请求体到中转站，对比报错（仅当需要二次确认时）。

3. **检查中转站文档**：botcf.com 的 API 文档，确认它支持的参数列表。

4. **响应解析也要改**：推理模型可能返回 `choices[0].message.content` 为 null + 有 `reasoning` 字段，当前解析逻辑不处理 reasoning（v2.8.4 已把 content 为 null 时返回空字符串而非报错）。

### 代码位置

- 请求构建：`OpenAIClient.swift` 第 69-89 行（Chat Completions 分支）
- 鉴权头：`OpenAIClient.swift` 第 160-175 行 `applyAuth`
- 测试连接：`Models.swift` 第 180-209 行 `testConnection`
- 模型配置：`Models.swift` 第 6-50 行 `ModelConfig`
- 聊天循环：`Models.swift` 第 330-376 行 `ConversationStore.runLoop`
- 工具 schema：`MCPCore.swift` 第 178-200 行 `openAIToolSchema()`

---

## 9. TrollStore 特权 Entitlements

从原版 v0.14.15 Mach-O 的 `LC_CODE_SIGNATURE` 提取的 16 项权限，写在 `Support/TrollMCP2.entitlements`：

| 权限 | 用途 |
|------|------|
| `platform-application` | TrollStore 识别为平台应用 |
| `com.apple.private.security.no-sandbox` | 沙盒逃逸 |
| `com.apple.private.security.no-container` | 无容器限制 |
| `com.apple.private.security.storage.AppBundles` | 读写 App Bundle |
| `com.apple.private.security.storage.AppDataContainers` | 读写 App 数据容器 |
| `com.apple.security.exception.files.absolute-path.read-write` | `/`、`/var/mobile/Containers/Data/Application` |
| `com.apple.security.exception.files.absolute-path.read-only` | `/Applications`、`/private/var/containers/Bundle/Application` |
| `com.apple.private.MobileContainerManager.allowed/lookup/otherIdLookup` | 容器管理器查询 |
| `com.apple.private.mobileinstall.allowedSPI` | `[Lookup]` |
| `com.apple.private.persona-mgmt` | persona 管理 |
| `task_for_pid-allow` | task_for_pid 权限 |
| `com.apple.private.security.container-required` | **false** |
| `checklessPersistentURLTranslation` | URL 翻译 |
| `keychain-access-groups` | 钥匙串 |

打包时由 `codesign -s - -f --entitlements` 注入主二进制。

---

## 10. 原版二进制位置

```
D:/Users/Administrator/Desktop/Payload/TrollMCP.app/TrollMCP    # 7.1MB Mach-O arm64
D:/Users/Administrator/Desktop/Payload/TrollMCP.app/            # 完整 .app 目录
```

可用 Python 解析 Mach-O 的 `LC_CODE_SIGNATURE` → `CSMAGIC_EMBEDDED_ENTITLEMENTS` 提取 entitlements（已提取，存为 `trollmcp_entitlements_extracted.xml`）。

---

## 11. 版本历史

| 版本 | 日期 | 主要变更 |
|------|------|---------|
| 2.0.0 | 08-16 | M1 首次编译成功（基础工具） |
| 2.1.0 | 08-16 | 补齐原版命名工具与视图 |
| 2.2.0 | 08-16 | 重构主界面为聊天+侧边抽屉 |
| 2.3.0 | 08-16 | 修复模型 API 保存（嵌套 NavView bug） |
| 2.4.0 | 08-16 | 二次修复模型编辑器保存（init 替代 onAppear） |
| 2.5.0 | 08-16 | 按原版截图复刻底部输入区 |
| 2.6.0 | 08-16 | 设备环境自检 |
| 2.7.0 | 08-16 | 工具调用闭环 + 应用/相册/文件选择器 + 工具审计 |
| 2.8.0 | 08-16 | 真实化注入/Gateway/automation + 补齐 12 个设备工具 |
| 2.8.1 | 08-16 | 注入 TrollStore 特权 entitlements |
| 2.8.2 | 08-16 | 修复 authMethod 空串 → Bearer |
| 2.8.3 | 08-17 | 推理模型省略 temperature + max_completion_tokens |
| **2.8.4** | 09-02 | 自适应兼容降级（5 级试探 + 持久化 + 网络调试日志页） |
| **2.8.5** | 09-02 | 推理模型 reasoning_effort=none（提速+修 tools 兼容）、降级重试超时 30s、聊天实时状态文案 |
| **2.8.6** | 09-02 | 请求超时（URLSession -1001）触发降级；500/502/503/504 也纳入可降级；首次超时缩至 45s |
| **2.9.0** | 09-02 | **Responses API 支持**（/v1/responses，Codex 同款端点）：新级别 L5「Responses API+工具」、新协议「OpenAI Responses」、L3/L4 旧配置自动先试 L5 |
| **2.9.1** | 09-02 | **工具名净化**：OpenAI/Responses API 要求工具名匹配 `^[a-zA-Z0-9_-]+$`；ToolDefinition.apiName 净化（中文/标点→下划线、数字开头加 t_ 前缀、重名加 _N 后缀），dispatch 用 apiNameToOriginal 反查原始工具 |
| **2.9.2** | 09-02 | **聊天复制/分享 + 移除 OpenAI Completions**：① 长按消息气泡 → 复制/分享（UIPasteboard / UIActivityViewController）；② 导航栏"勾选"进入多选模式 → 点选多条消息 → 复制或分享到其他 App（勾选文本带"我：/工具结果"前缀与会话标题）；③ 移除废弃的「OpenAI Completions」旧协议（旧配置自动迁移到 Chat Completions，请求固定走 /chat/completions） |
| **2.9.3** | 09-02 | **设备端编译桥（本机构建）**：新增 `build.environment`（检查 toolchain/clang/make/perl/ldid/theos/iOS SDK，真实跑 --version 探测）与 `build.run`（编译 projects/ 下的 theos `make [package]` 或裸 clang 工程，返回退出码/输出/产物）；`project.generate_tweak` 补全 Tweak.x 生成；BuildRunner 用 posix_spawn + `/bin/sh -c "cd '<dir>' && exec ..."` 处理工作目录（iOS SDK 无 posix_spawnattr_setworkingdir_np、fork() 不可用），输出落临时文件 + 超时杀进程 + 类型容错参数（Bool/Double/数组兼容字符串） |
| **2.9.4** | 09-02 | **工具链 system 模式 + 绝对路径**：`build.environment`/`build.run` 的 toolchain 参数支持 `system`（越狱机 Nyxian 系统布局：clang/make/perl/ldid 在 /var/jb/usr/bin、/usr/bin，theos 在 /usr/local/theos）与任意绝对路径；规范布局仍走 Workspace/<path>。新增 ToolchainProfile/resolveToolchainProfile 统一解析 |
| **2.9.4+tweak** | 09-02 | **线上编译 tweak（非越狱正解）**：新增 `build-tweak` workflow（GitHub Actions macOS runner + theos 递归 submodule + Xcode SDK 软链 + dm.pl），仓库 `tweaks/<name>/` 放工程，手动触发即产出 .dylib + .deb；CompileProbe 已编译验证成功 |
| **2.9.5** | 09-02 | **App 内 GitHub 账号系统**：设置 → GitHub 账号——任何账号 PAT 登录/切换/删除（多账号并存，UserDefaults 存储），一键触发线上编译（workflow dispatch API）+ 实时查看 run 状态；仓库/workflow/分支可配置。实现于 GitHubAccountStore.swift + GitHubAccountView.swift |

最新 IPA：`artifacts/v2.9.5/TrollMCP2-v2.9.5-20260902.ipa`（包内版本已验证 2.9.5）
GitHub Actions run：33617736761 ✅（v2.9.4 IPA）；33620936109 ✅（CompileProbe tweak）；33625432211 ✅（v2.9.5 IPA）

### v2.9.0 关键认知（重要！）

用户证实：**相同中转（Botcf）上 Codex/ccswitch 能正常带工具运行**。原因是 Codex 走 `/v1/responses` 端点而非 `/chat/completions`。GPT-5.6 家族（terra/luna/sol）的 function tools 在 chat/completions 上不可用/极慢（社区报告），但 Responses API 正常。

降级链（v2.9.0）：L0 完整 → L1 互换 token key → L2 去 tool_choice → **L5 Responses API+工具**（保住工具调用）→ L3 纯对话 → L4 最小载荷 → 结束。nextLevel 的哨兵值 6 防止 L4→L5→L3 死循环。

### v2.9.1 关键认知（重要！）

用户截图证实：Responses API 已打通，但报 **`Invalid tools[0].name: name must contain a-z A-Z 0-9 _ -`** —— OpenAI 端点对 function tool 名有严格校验（`^[a-zA-Z0-9_-]+$`），而我们 57 个工具里部分原名含中文/点号/冒号。修复：

- `ToolDefinition.apiName` 计算属性：非法字符→`_`、空名兜底 `tool`、数字开头加 `t_` 前缀
- `ToolRegistry.enabledOpenAIToolSchema()`：用净化名构建 schema，重名自动加 `_2/_3` 后缀去重
- `ToolRegistry.dispatch(name:)`：先查原名，再查 `apiNameToOriginal` 反查表，模型回传的净化名能正确路由到原始工具
- 旧的 `Array.openAIToolSchema()` 扩展已删除，统一走 ToolRegistry（chat/completions 与 Responses 共用同一套净化名）

---

## 12. 关键注意事项

### 构建

- `artifacts/` 目录被 `.gitignore` 忽略，IPA 只在本地
- GitHub Actions artifact 保留 90 天，过期需重新构建
- `gh run download` 必须在 git 仓库目录内执行
- `ldid -S` 不可用（断言失败），必须用 `codesign`
- Windows 上无法编译（无 iOS SDK），只能走 GitHub Actions 或本地 Mac

### 设计决策

- 所有用户数据存在 `UserDefaults`（模型配置、对话、工具开关），没有文件系统数据库
- 工作区目录：`Documents/Workspace/`，工具读写文件都在这里（防目录穿越）
- 工具开关持久化在 `UserDefaults["trollmcp2.disabled_tools"]`
- 对话历史不截断（可能超 context length，这是个隐患）

### 已知隐患

1. **对话历史不截断**：`messagesForAPI()` 返回全部历史消息，长对话会超 context length
2. **工具全量发送**：每次聊天把 57 个工具全发给模型，中转站可能拒
3. **错误提示不够详细**：只显示 `raw.prefix(300)`，用户看不到完整请求/响应
4. **reasoning 字段未解析**：推理模型返回的 `reasoning` / `reasoning_content` 字段被忽略
5. **无 stream 支持**：所有请求非流式，长回复体验差
6. ~~无重试/降级~~ v2.8.4 起已有 5 级自适应降级 + compatLevel 持久化（见第 7/8 节）

### 代码风格

- 工具类用 `final class XTool: MCPTool`（不是 struct）
- 单例用 `static let shared`
- 状态管理用 `@Published` + `ObservableObject`
- UI 不包 NavigationView 的子页 → 被 NavigationLink 推入时由父页的 NavigationView 管理
