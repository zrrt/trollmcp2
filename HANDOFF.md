# TrollMCP2 项目交接文档

> 版本：v2.9.15 | 最后更新：2026-09-02 | 仓库：github.com/origina47487lhe-droid/trollmcp2（私有）

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
├── Sources/TrollMCP2/             # 全部 Swift 源码（34 个文件，~7700 行）
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
│   ├── GitHubTools.swift          # ★ v2.9.9：GitHub 线上编译 AI 工具（账号状态/触发编译/查进度/下载产物）
│   ├── ZipExtractor.swift         # ★ v2.9.9：自研轻量 ZIP 解压器（STORE/DEFLATE，替代 iOS 不存在的 FileManager.unzipItem）
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
| **GitHub 账号（v2.9.5+）** | GitHubAccountStore.swift + GitHubAccountView.swift | App 内多 GitHub 账号登录/切换/删除（v2.9.5 PAT；v2.9.6 + Device Flow 网页登录，内置 Safari 授权）；触发仓库 Actions workflow 线上编译；查询 run 状态。仓库 owner/name/workflow/branch/Client ID 可在设置页配置 |
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
| **2.9.6** | 09-02 | **网页登录（Device Flow，gh CLI 同款）**：不再依赖 PAT 手动复制——App 内置 Safari（SFSafariViewController）打开 GitHub 授权页，显示 user_code + 自动轮询换取 token，登录自动完成。需在「仓库设置」填 OAuth App Client ID（免费注册，无需 secret）。PAT 保留为备选 |
| **2.9.7** | 09-02 | **新手零配置登录**：在 origina47487lhe-droid 账号下注册共享 OAuth App「TrollMCP2 线上编译」（id 3832419，Client ID `Ov23li890n3hM15edlcw`，Device Flow 已启用，token 过期已关）并**内置为默认值**——任意 GitHub 用户打开 App 直接点「网页登录」即可授权（各拿各的 token），无需注册/配置任何东西。高级用户仍可在仓库设置覆盖 Client ID |
| **2.9.8** | 09-02 | **零折腾网页登录**：拿到验证码后**自动复制到剪贴板**（GitHub 授权页可自动识别/粘贴，gh CLI 同款）+ 手动复制按钮；授权成功后**自动关闭内置 Safari 并自动返回**登录成功（无需手动点「完成」）；失败也自动关浏览器。修复用户实测"验证码不能复制/要手动切来切去"的体验 |
| **2.9.9** | 09-02 | **8 项反馈一次性落地**：①**图片真传**（选相册图→base64 data URL→多模态 content 数组发给模型，单张 ≤3MB，ChatMessage 新增 imageDataURLs，Chat Completions 用 image_url、Responses 用 input_image）；②**侧边栏精简**（对话列表 List→ScrollView 去分隔线，删除改长按 contextMenu（iOS14 兼容），底部工作台改为紧凑环境入口+设置齿轮）；③**GitHub AI 工具**（新增 `github.account_status`/`github.trigger_build`/`github.fetch_runs`/`github.download_artifact`，AI 可感知登录状态、触发线上编译、查进度、下载 artifact 并解压到工作区 downloads——与 UI 层 GitHubAccountStore 同源 UserDefaults key）；④**键盘收起**（点击聊天空白区收键盘 resignFirstResponder）；⑤**TrollFools 检测修复**（补官方 bundle id `wiki.qaq.TrollFools` + 名称/路径模糊匹配兜底）；⑥**自研 ZipExtractor**（STORE/DEFLATE 解压，compression 框架，替代 iOS 不存在的 FileManager.unzipItem） |
| **2.9.15** | 09-02 | **根治请求慢**：①默认工具白名单（未显式设置的工具按 ~20 个聊天/编译/注入常用工具决定默认启用），80+ 工具全量 schema 导致的载荷巨大/中转超时问题解决；②请求耗时统计写入网络兼容日志（每轮成功/失败均显示 ms）；③版本 2.9.15 | **模型编辑根因修复**：iOS14 .sheet(isPresented:)+闭包捕获存在时序竞争，sheet 首次构建读到旧 editing(nil) 先用默认 OpenAI 渲染、之后才切到真实配置；改用 .sheet(item:)+.id(cfg.id)，item 变化即以新值重建内容、每次打开全新视图身份，编辑页立即显示真实配置，不再闪 gpt-4o | **取消请求 + 模型编辑修复**：①请求进行中发送按钮变红色停止，可取消当前请求（OpenAIClient.cancel + ConversationStore.cancelCurrent）；②模型编辑 sheet 加 .id(editing?.id) 强制按配置重建 State，修复 iOS14 首次渲染锁死为默认 OpenAI 预设（编辑页显示 gpt-4o 而非真实 5.6 配置）| **体验与超时修复**：①老会话打开/切换自动滚到底（ScrollViewReader onAppear + selectedId 监听）；②select() 打开会话即刷新 updatedAt 重排置顶，列表按最近使用倒序；③侧边栏 header 顶部自适应状态栏安全区，标题不再压系统时间；④URLRequest 超时放宽（chat 首次 45→90s/重试 30→60s、Responses/Anthropic 60→90s）；⑤默认上下文预算 24000→16000；⑥版本 2.9.12 |
| **2.9.11** | 09-02 | **上下文预算裁剪**：①核心修复长会话卡死——messagesForAPI 按 token 估算（中文 1.5/字、ASCII/4、图片 600）裁剪最早历史，保留最近 6 条+系统提示，请求体不再无限增长；②sanitizeToolSequence 清理裁剪后孤立 tool 消息防 API 报错；③ModelConfig 新增 contextTokens（默认 24000，解码兼容旧配置），模型编辑页新增上下文预算 Stepper + 参数说明（明确 Max Tokens=输出上限≠上下文）；④Info.plist 加 UIRequiresFullScreen（iPhone 全屏明确）；⑤版本 2.9.11 |
| **2.9.10** | 09-02 | **6 项体验打磨**：①**图片/应用缩略图**（选图后输入栏显示缩略图可删、消息气泡内直接显示图片（dataURL→UIImage）；选应用显示图标+名称预览，复用 AppIconView 加载逻辑）；②**下载管理页**（设置「连接与扩展」新增入口，浏览/勾选/删除 Workspace/downloads 线上编译产物，防垃圾堆积）；③**后台网络中断修复**（新增 AppLifecycleMonitor：NWPathMonitor 网络恢复 + 前后台通知；GatewayClient 网络恢复/回前台自动重连；AppDelegate 后台保活 3 分钟；OpenAIClient 自定义 URLSession `waitsForConnectivity` + 90s/300s 超时放宽；回前台弹提示）；④**侧边栏美化**（渐变 logo、选中渐变圆角卡片、美化搜索栏/底部圆角工具栏）；⑤**请求超时优化**（OpenAIClient request 90s / resource 300s）；⑥**加号改半屏 actionSheet**（替代整屏「添加内容」面板）+ 内置智能搜索占位替换为真实说明页（web.search 默认启用） |

最新 IPA：`artifacts/v2.9.9/TrollMCP2-v2.9.9-20260902.ipa`（包内版本已验证 2.9.9）
GitHub Actions run：33617736761 ✅（v2.9.4 IPA）；33620936109 ✅（CompileProbe tweak）；33625432211 ✅（v2.9.5 IPA）；33628210737 ✅（v2.9.6 IPA）；33630385070 ✅（v2.9.7 IPA）；33632520940 ✅（v2.9.8 IPA）；33638205824 ✅（v2.9.9 IPA）

### v2.9.0 关键认知（重要！）

用户证实：**相同中转（Botcf）上 Codex/ccswitch 能正常带工具运行**。原因是 Codex 走 `/v1/responses` 端点而非 `/chat/completions`。GPT-5.6 家族（terra/luna/sol）的 function tools 在 chat/completions 上不可用/极慢（社区报告），但 Responses API 正常。

降级链（v2.9.0）：L0 完整 → L1 互换 token key → L2 去 tool_choice → **L5 Responses API+工具**（保住工具调用）→ L3 纯对话 → L4 最小载荷 → 结束。nextLevel 的哨兵值 6 防止 L4→L5→L3 死循环。

### v2.9.30 关键认知（2026-09-03）

**修复 +号（添加内容）点击无反应**：用户反馈 +号 点击没反应，且**没发消息也这样**（排除主线程阻塞）。
- 根因：v2.9.25 在 inputBar 挂了授权 actionSheet（`item: pendingApproval`），与 +号 的 actionSheet（`isPresented: showAttachSheet`）在**同一 view 链**上。SwiftUI 同一 view 多个 `.actionSheet` 修饰符，**后一个接管呈现通道** → +号 的 actionSheet 永远无法弹出。
- 修复：授权 actionSheet 从 inputBar **移出**，挂到 NavigationView 外层（`.navigationViewStyle(.stack)` 之后、`.sheet(item:)` 之前），与 +号 actionSheet 分层，互不覆盖。
- 校验：总 `.actionSheet` = 2（+号在 inputBar、授权在导航外层）；inputBar 段不再含 `pendingApproval` actionSheet。
- 教训：SwiftUI 中同 view 链多个 actionSheet/sheet 必须分层挂载，否则后者覆盖前者。

CI 33673863443 / 提交 965d344 / 版本 2.9.29→2.9.30 / IPA artifacts\v2.9.30

### v2.9.29 关键认知（2026-09-03）

**修复授权后一直转圈 + 聊天框/+号点击无响应**：用户点授权后转圈，且聊天框旁 + 号（添加应用/相册）点击没反应。
- 根因：整条 `runLoop→processToolCalls→dispatch→invoke` 链在**主线程**执行。授权恢复后真的执行注入（InjectionManager.enable 同步：拷贝文件 + insert_dylib --inplace + ldid -S 子进程）时，主线程被完全占用 → 转圈 + 所有 UI 交互（输入框、+号、按钮）无响应。用户补充"+号点击没反应"进一步印证主线程卡死。
- 修复：processToolCalls 的 dispatch 改为 `DispatchQueue.global().async` 后台执行，结果/授权/错误经新增 `handleDispatchResult` 回主线程继续递归。注入等耗时工具不再阻塞主线程；UI 正常 loading，完成后继续回复。
- 结构：ConversationStore 是 `final class ObservableObject`（闭包捕获 self 安全）；多工具调用经主线程 handleDispatchResult 串行化，不并行。
- Mach-O 校验：`handleDispatchResult`（新增方法符号）UTF-8 可搜到；`DispatchQueue` 是系统符号不在 App 二进制，搜不到属正常。

CI 33673241546 / 提交 e2fc1f2 / 版本 2.9.28→2.9.29 / IPA artifacts\v2.9.29

### v2.9.28 关键认知（2026-09-03）

**修复 unknown tool: injection_enable**：用户调用注入工具报 `error: unknown tool: injection_enable`。
- 根因：injection.enable 不在白名单（v2.9.25 移出），而 `enabledOpenAIToolSchema()` 只给**已启用**工具建立 apiName→原名映射。tool_search 披露的敏感工具（injection.enable 等）**不在该映射里**；模型按披露 schema 的 function name（apiName=`injection_enable`，下划线）返回调用，dispatch 查 `tools[name]` 无、查 `apiNameToOriginal[name]` 也无 → unknown tool。
- 修复：dispatch 增加**第三层兜底解析**——遍历所有注册工具，按 `definition.apiName` 反向匹配（lock 内）。模型返回下划线 apiName 或点号原名都能解析到真实工具；敏感工具继续走 requiresApproval 弹授权窗。
- Mach-O 校验经验：`injection.enable`/`apiName` 可 UTF-8 搜到（FOUND）；`unknown tool`/`injection_enable` 是运行时生成/错误字符串，编译后不保留属正常。

**注入调用名机制总结**：schema 里 function name = apiName（下划线，如 injection_enable）；tool_search 返回原名（点号）；dispatch 解析顺序 = 原名直接命中 → apiNameToOriginal → 遍历 apiName 兜底。敏感工具任何路径都弹授权。

CI 33670612695 / 提交 9395507 / 版本 2.9.27→2.9.28 / IPA artifacts\v2.9.28

### v2.9.27 关键认知（2026-09-03）

**修复 tool_search 披露 bug（从 v2.9.16 就存在）**：AI 说"当前会话没有加载 injection.enable 的可执行接口"，无法执行注入。
- 根因：`ToolSearchTool` 返回 `"tools": [[String: String]]`，但 runLoop 披露逻辑用 `r["tools"] as? [[String: Any]]` 转换——Swift 中 Dictionary 的 Value 泛型参数不同（String vs Any）时 `as?` **永远返回 nil** → `nextDisclosed` 一直为空 → AI 搜到工具名但**下一轮 schema 从不注入** → AI 拿不到可执行接口。
- v2.9.25 把 injection.enable 移出白名单后完全依赖此（坏的）通道，问题暴露。
- 修复：优先 `as? [[String: String]]`（ToolSearchTool 实际返回类型），`else if` 兼容 `[[String: Any]]`。
- 校验提示：`nextDisclosed` 是局部变量编译后被优化，Mach-O 搜不到属正常；`disclosed`（runLoop 参数）可搜到。

**修复后注入闭环**：AI 用 tool_search 搜"注入" → 下一轮自动注入 injection.enable/disable/remove 等 schema → 调用时弹授权（本轮/会话/拒绝）→ 放行执行。injection.enable 参数：bundle_id + dylib_path（默认 @executable_path/TrollMCPAgent.dylib）。

CI 33669844943 / 提交 23aed06 / 版本 2.9.26→2.9.27 / IPA artifacts\v2.9.27

### v2.9.26 关键认知（2026-09-03）

**修复工具权限策略页开关点不动**：用户反馈工具列表开关仍不能启动/关闭。
- 根因：ToolRegistry **无任何 @Published 属性**，只靠 `objectWillChange.send()` 手动通知，在 iOS16 的 List 内 Toggle 刷新不可靠 → 开关点了没反应/弹回。
- 修复①：ToolRegistry 加 `@Published private(set) var policyRevision`，`setEnabled` 递增（真正 @Published 触发 UI 必刷新）+ 保留 objectWillChange.send() 双保险。
- 修复②：权限策略页工具列表 **Toggle → 自定义 iOS 风格开关**（Capsule 46x28 + Circle 24x24 + ZStack 对齐），整行 `contentShape(Rectangle())` + `onTapGesture` 切换，点整行任意位置即可开关，彻底绕开 List+Toggle 兼容问题。
- 坑：`.animation(_:value:)` 是 iOS15 API（项目 iOS14 目标会编译失败），改用 iOS14 的 `.animation(.easeInOut(duration: 0.15))`。

CI 33667158729 / 提交 761b6cd / 版本 2.9.25→2.9.26 / IPA artifacts\v2.9.26

### v2.9.25 关键认知（2026-09-03）

**分层工具授权**：用户要求"工具调用次数不要限制（死循环手动暂停）+ 搜索即自动授权，除非敏感隐私权限弹窗选择（本轮授权/会话授权/拒绝）"。
- **普通工具**：AI 用 tool_search 搜到即 approveForSession 自动授权本会话（保留 v2.9.22）。
- **敏感工具**（sensitiveTools 集合：通讯录/定位/日历/提醒/通知/进程/记忆/写删/扫码/电话/打开App输入/微信消息/注入 enable-disable-remove/本机编译/知识删除）：搜索不自动授权，调用时弹窗。
- **白名单移除** injection.enable/disable/remove、build.run（高危执行类走弹窗；查询类 injection.status/list/inspect、build.environment 保留）。
- 实现：MCPError.requiresApproval + ToolRegistry.sensitiveTools/isSensitive/approveOnce/consumeOnce/summary；dispatch = isEnabled || isSessionApproved || consumeOnce 放行，否则 requiresApproval；Models.swift 加 processToolCalls 可暂停/恢复递归 + resolveApproval + PendingToolApproval（存恢复上下文 config/tools/disclosed/depth/remainingCalls）；ChatView 挂 ActionSheet（本轮=approveOnce 单次 / 会话=approveForSession / 拒绝=forceDeny 直接返回错误给 AI）；tool_search 返回 authorized/sensitive 区分。
- **次数不限制**：depth 上限 8→60 极端保险（正常永不触发），提示告知可用"停止"按钮。
- 注意：老用户升级后，此前 tool_search 自动授权过的工具仍留在 UserDefaults？不会——sessionApproved 在内存，新会话自动清空，无持久化残留。但白名单移除的 4 个工具若用户此前在权限策略里手动开过（setEnabled true 显式状态 v2.9.24 起），则 isEnabled=true 仍直接放行（用户明确授权，合理）。

CI 33665879947 / 提交 3ac0bb7 / 版本 2.9.24→2.9.25 / IPA artifacts\v2.9.25

### v2.9.24 关键认知（2026-09-03）

**① 修工具开关手动开启 bug**：根因 `setEnabled` 用"删除 disabled key"表示启用，但 `isEnabled` 对非白名单工具默认 false，删除 key 后回落白名单 → 开关弹回，非白名单工具（contacts.search / process.list 等）永远开不了。改为显式状态字典 `states[name]=enabled`，用户手动设置过以显式值为准。注意：旧数据兼容——旧版只有用户"禁用"留下的 false 值，新逻辑读 false 一致；旧版"启用"白名单工具是 removeValue 无残留，新逻辑回落白名单一致。

**② 指令一键复制**：列表页每行尾部加复制按钮（点击即复制 + 图标变绿 checkmark 1.5s 反馈，BorderlessButtonStyle 防触发整行点击）；编辑页导航栏加复制按钮（copyContent 复制当前 TextEditor 内容）。

**③ 工具调用上限友好化**：depth 上限 6→8（防止死循环的保护），提示改为"已达到本轮工具调用上限（8 轮），已停止，防止死循环。你可以直接回复「继续」"。

CI 33664659207 / 提交 3c7f370 / 版本 2.9.23→2.9.24 / IPA artifacts\v2.9.24

### v2.9.23 关键认知（2026-09-03）

**合并"工具权限策略"与"本机工具审计"（去重）**：用户指出两个页面功能重复（都是每个工具 Toggle 控制启停）。合并：保留功能更全的"工具权限策略"页（搜索 + 全部启用/禁用），把审计页的"真实/占位"标记 + "仅显示真实实现"过滤并入（realTools 集合 + 每行徽标 + 过滤开关）。删除 SettingsView"本机工具审计"入口（subtitle 改"按工具控制 · 真实/占位"），删除 ToolAuditView.swift（确认无其他引用）。

CI 33663668863 / 提交 fe59857 / 版本 2.9.22→2.9.23 / IPA artifacts\v2.9.23

### v2.9.22 关键认知（2026-09-03）

**AI 工具搜索即自动授权（无需手动开 Toggle）**：用户质疑"本机工具审计要手动开启？为什么不能让 AI 查询决定用哪个"。此前 dispatch 拦 isEnabled，工具策略禁用时 AI 通过 tool_search 搜到也调不了。现在：
- ToolRegistry 加 `sessionApproved` + `approveForSession` / `clearSessionApproval` / `isSessionApproved`
- `ToolSearchTool.invoke` 命中即 approve（搜索到 = 决定使用 = 授权）
- `dispatch` 改为 `isEnabled || isSessionApproved` 放行
- 新会话 `clearSessionApproval()` 自动清空授权
- 工具权限策略页 / 本机工具审计页加说明文案
- ToolAuditView.realTools 补 injection.* / skills.* / tool_search 为"真实"

**指令编辑器滚动修复**：Form+TextEditor 滚动冲突/键盘遮挡 → ScrollView + 520 高 TextEditor + 键盘高度监听底部留白 + iOS14 兼容"收起键盘"按钮（`.keyboard` toolbar 是 iOS15+，iOS14 会编译失败，已改按钮形式）。

CI 33662966976 / 提交 39470ef + a6dc7b8 / 版本 2.9.21→2.9.22 / IPA artifacts\v2.9.22

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


### v2.9.31 关键认知（2026-09-03）

**去掉全部授权弹窗 + 工具按需加载（Anthropic defer_loading 同款）**——用户明确要求"去掉所有本轮授权/会话授权/拒绝"、"工具只保留几个其他 AI 选择不限制"、"全勾选变慢"。

- **常驻核心工具集 `coreToolNames`（9 个）**：tool_search / ping / device.info / device.probe / workspace.info / artifact.list / artifact.read_text / model.config / injection.status。
  - `enabledOpenAIToolSchema()` 改为 **只返回 coreToolNames**（不再 filter isEnabled 全量）→ 初始请求载荷恒定极小，**权限策略页全量勾选不再影响速度**。
  - 其余全部工具靠 tool_search 按需披露：AI 搜索命中 → approveForSession 自动授权 → 下一轮注入完整 schema（disclosed 合并逻辑不变）。
- **删除全部授权弹窗机制**：sensitiveTools / isSensitive / approveOnce / consumeOnce / singleUseApproved / MCPError.requiresApproval / ApprovalDecision / PendingToolApproval / pendingApproval / resolveApproval / forceDeny 全删。
  - dispatch 放行 = `isEnabled || isSessionApproved`；未加载工具返回错误 `tool X 未加载，请先调用 tool_search 搜索该工具`（不弹窗）。
  - tool_search 现在对全部命中工具 approveForSession（含注入/删除/扫码等原敏感工具），返回 authorized 全量 + 新 hint。
- **ChatView 授权 actionSheet 删除**（v2.9.30 挂导航外层的那个）；+号 actionSheet 保留在 inputBar。
- 注意：授权弹窗删除后**注入/删除/扫码/电话等原敏感工具 AI 可自由调用**——这是用户明确要求（"AI 可以选择不要限制"），需在 UI 提示用户自行承担。
- 校验：verify_v2931.py 检查 coreToolNames 存在、enabledOpenAIToolSchema 只返回常驻、无 requiresApproval/approveOnce/sensitiveTools/pendingApproval/resolveApproval/forceDeny、版本 2.9.31、花括号配对；全过。


### v2.9.32 关键认知（2026-09-03）

**注入修复：TrollStore TSRootBinaries + persona-mgmt 机制**——无越狱下 mobile 用户无 POSIX 写权限写 root 拥有的 app bundle（此前 POSIX 13 Permission denied）。

- **根因确认**：TrollMCP2 entitlements 已有 no-sandbox/no-container/platform-application，但报错是 POSIX 权限而非沙箱。TrollStore 无越狱 app 以 mobile 运行，无法写 root 拥有的 bundle。
- **TrollFools 原理（查证）**：TrollStore 官方机制——app 无沙箱 + `com.apple.private.persona-mgmt` entitlement 即可用 `posix_spawnattr_setuid_np/setgid_np` 以 root 身份 spawn 内置二进制（TrollStore TSUtil.m 的 spawnRoot）。iOS 14+ 支持任意 UID/GID spawn；**iOS 17.6/18.0 起非 root 进程禁止 spawn root 二进制（需内核漏洞）**。用户 iOS 16.3 → 完全支持。
- **落地**：
  1. `InjectionManager.spawnRoot(_:args:)`：`posix_spawnattr_init` + dlsym 动态绑定 `posix_spawnattr_setuid_np/setgid_np`（uid/gid 0）→ posix_spawn。**注意**：`@_silgen_name` 绑定 _np 私有函数会链接失败（undefined symbol），必须 dlsym 运行时查找。
  2. `Info.plist` 加 `TSRootBinaries` 数组，声明 bin/insert_dylib、ldid、cp、cp-15、mv、mv-15、rm、chown、install_name_tool、optool——TrollStore 安装时对其特殊处理。
  3. enable/disable/remove 写 bundle 的操作全部 `runAsRoot`（root cp 拷贝 agent / root cp 备份 / root insert_dylib --inplace / root ldid -S / root rm）。cp 版本按 iOS 大版本选：iOS 15 用 cp-15，16+ 用 cp。
  4. `enable` 新增 `dylibSourcePath` 参数：支持注入 GitHub 下载的本地 dylib（如 CompileProbe.dylib）——root 拷贝进目标 App + insert_dylib + ldid，覆盖"线上打包→下载→注入测试→移除"闭环。
  5. injected 判定改为 `insert_dylib exit==0`（自定义 dylib 不匹配 "TrollMCPAgent" 字符串扫描）。
- **注入工具参数**：`injection.enable` 的 `dylib_path` 传本地文件路径 → 作为注入源；传 @executable_path/@loader_path 前缀 → 作为 load name；空 → 内置 agent。

**权限策略页对齐新架构（v2.9.31/32）**：
- 说明文字改为按需加载语义：初始请求只加载常驻核心（标★），其余 AI 用工具搜索按需加载、搜索命中即自动放行本会话、无弹窗；开关控制"是否默认可用"（关闭的工具 AI 仍可先搜索再调用）；全量勾选不影响请求速度。
- `ToolRegistry` 加 `coreToolNames` 只读访问器 + `isCore(_:)`；MoreViews 工具名加 ★ 标记（蓝色）。

**校验**：verify_v2932.py 检查 spawnRoot/runAsRoot/@_silgen_name 移除/dlsym/TSRootBinaries/persona-mgmt/dylibSourcePath/cp 版本选择/injected 判定/权限页 isCore/版本 2.9.32；全过。CI 首次失败（@_silgen_name 链接 undefined symbol _posix_spawnattr_setuid_np）→ 改 dlsym 后成功。


### v2.9.33（2026-09-03）

**问题现场（用户截图）**：AI 想注入 CompileProbe.dylib 到 TrollMCP（巨魔MCP，非 trollmcp2），调用 artifact_list 读 downloads/run_xxx/packages/com.example.compileprobe_*.deb 报 NSCocoaErrorDomain Code=256 / NSPOSIXErrorDomain Code=20 "Not a directory"。

**根因**：Theos `make package` 产物是 .deb 归档（ar+tar），裸 .dylib 在 downloads/run_*/private/.theos/obj/debug/ 下；artifact.list 对文件路径直接 contentsOfDirectory → Code 20。

**落地**：
1. artifact.list 文件友好化：subpath 是文件时返回该文件信息（isDirectory:false + size + hint"这是文件不是目录"），不报错；列目录时标注 isDirectory。
2. 新增 artifact.find：递归扫描工作区，按 ext（dylib/deb/ipa）或 name 片段查找，返回路径+大小+limit；hint 引导"用裸 dylib 路径传给 injection.enable 的 dylib_path"（.deb 是归档不能直接注入）。
3. artifact.find 入常驻核心（coreToolNames 增至 10：tool_search/ping/device.info/device.probe/workspace.info/artifact.list/artifact.read_text/artifact.find/model.config/injection.status）。
4. 版本 2.9.33（Info.plist + SettingsView）。CI 33740774416 success，commit 07ba0f1。

**注入流程（给用户/AI 的正确路径）**：injection_list 找目标 app bundle id（如 dev.trollmcp.app）→ artifact.find ext=dylib 找 CompileProbe.dylib → injection.enable {bundle_id, dylib_path=裸dylib路径} → 打开目标 app 验证。


### v2.9.34（2026-09-04）

**问题现场（用户 6 张截图）**：AI 注入调研时调用 artifact.find 报"tool artifact.find 未加载，请先调用 tool_search 搜索该工具"，随后"正在通过 Responses API 请求（保留工具调用）…"一直转圈。device_probe 全绿（ready=true、注入二进制全捆绑、amfidBypassInferred=true）。用户还抱怨：AI 一下子调多个工具、没有思考过程显示（对比老 MCP"正在思考/第 N 轮"）、回复无 emoji、问 DeepSeek 等模型/中转站适配。

**根因（关键 bug）**：`ToolRegistry.dispatch` 放行条件只有 `isEnabled || isSessionApproved`。coreToolNames 决定"初始请求发给模型的 schema"，defaultEnabledTools 决定"dispatch 放行默认值"——两个集合不一致。artifact.find 只加了 coreToolNames（schema 发出去了），没加 defaultEnabledTools（isEnabled false）→ 模型按 schema 调用 → 被拒"未加载"。**常驻核心集合必须 ⊆ 放行集合**。

**落地**：
1. **dispatch 放行加 `|| isCore(originalName)`**——coreToolNames 工具必然放行（schema 已发、用户开关不再二次拦截）。defaultEnabledTools 同步补 artifact.find。
2. **请求过程可视化（对齐老 MCP"正在思考"面板）**：ChatStore 加 `requestRound`/`requestRounds`/`runningTool` @Published；runLoop 显示"已准备请求（正在整理会话与可用工具）"→ onStatus 前缀"正在请求模型（第 N/60 轮）· …"；工具执行时 `runningTool=call.name` 显示"正在执行工具 xxx…"；ChatView isLoading 时升级为 ProgressView+"正在思考"+状态+执行中工具+轮次 卡片。
3. **协作规范 system 注入（最高优先级，不依赖开发者指令配置）**：①工具逐个调用——每次只调 1 个、等结果再下一步，次数不限（尊重用户"不要限制次数"）；②回复自然可带 emoji。
4. **模型/中转站适配确认**：ModelConfig 已支持 provider=openai/deepseek/anthropic/custom + apiProtocol=OpenAI Chat Completions / OpenAI Responses / Anthropic Messages / Custom + 任意 baseURL/apiKey/model/authMethod。DeepSeek 预设 https://api.deepseek.com/v1 + deepseek-chat；Botcf 自定义。中转站填 baseURL 即可。推理模型（gpt-5.x/o1/o3/o4）自动降级（sendsTemperature=false、reasoning_effort 控制、compatLevel 自适应降级）。

**校验**：verify_v2934.py 检查 isCore 放行/artifact.find 白名单/协作规范/轮次状态/thinking 面板/版本 2.9.34；全过。CI 33869773624 success，commit 0a167f5。
