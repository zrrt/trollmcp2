# TrollAgent（原 TrollMCP2）

**AI 驱动的 iOS 巨魔（TrollStore）实验与 QA 工作台** —— Swift + SwiftUI + SwiftPM，跑在 iOS 15+ / TrollStore 环境，内置 **37 个大工具、100+ 子命令**，AI 通过自然语言调用全部能力。

> 小白模式：你只需要说一句大白话（比如"帮我分析下这个 App 怎么实现的"、"看看这个插件安不安全"、"帮我抓一下这个 App 的包"），AI 会自动选工具、自动装依赖、直接干完，再给你一句人话结论。

## 核心能力全景

### 🧩 注入与自动化（对齐 TrollFools 注入策略）
- `inject`（enable / disable / remove / restore / enable_persisted / status / inspect / list）：dylib 注入、移除、备份恢复（`.bak_macho` 自动回滚）
- `inject verify`：注入后健康检查（Mach-O load command + 进程存活 + 崩溃检测）；`inject static`：Mach-O 静态分析
- `inject mem`：内存注入（opainject，零文件残留）；`hook_apply` / `probe_inspect`；`inject load_dylib`：加载自写 dylib
- `rescue`（scan / recover_all / cleanup）：紧急恢复（Residue 式，防"注入后 App 打不开"死局）
- 注入失败自动回滚 + 注入后启动自检（闪退自动还原）

### 📱 应用管理
- `app`（launch / stop / restart / status / stats）：进程管理（start 三级降级：open -b → direct_exec → url_scheme）
- `app diagnose`：启动失败自动判因（注入残留/加密/签名/崩溃现场 → 明确 next_step）
- `app install / uninstall / duplicate`：AI 安装/卸载/复制 App（trollstorehelper 静默安装优先）
- `app encrypt_info / decrypt / replace_decrypted / restore_binary`：内置砸壳引擎（DecryptEngine：task_for_pid + vm_read 内存 dump → 重建解密镜像 → 打包 ipa）
- `app entitlements / deps / cache_inspect / cache_clear / launch_options / inject_package`
- `inject ipa_inspect / dylib_inspect`：IPA/dylib 解析（架构/签名/entitlements/依赖，区分"解析失败"与"真没有"）

### 🧹 系统清理
- 存储环形卡片 + 6 类缓存占用 + 快速/高级清理 Tab + 一键清理（setuid root 整目录重建）

### 📂 文件系统与数据
- `file`（inspect / analyze）：跨环境文件检查（原生元信息；自动 bind 走 Alpine file+strings）
- `db`（list / schema / query）：原生 sqlite3 直读 App 数据容器
- `package`（inspect / unpack）：deb/ipa 解包（ar/tar/zip）
- `artifact`（read / write / list）：工作区文件管理
- `container`（refresh / resolve / write / delete）：容器解析与读写

### 🌐 浏览器（WKWebView + JS 注入，仿 Playwright）
- `browser`（status / navigate / screenshot / snapshot / text / click / type / submit / scroll / wait / wait_for）+ 元素绝对 xpath
- `browser form_fields / fill_form`：整表自动填充（React/Vue 兼容 value setter + 事件）
- `browser adblock / clear`：广告/追踪拦截（WKContentRuleList，参考 reynard-browser 内容拦截）+ 缓存/Cookie 清理；navigate 支持 `fresh=true` 忽略缓存强制拉新

### 🎮 设备伪装（绿盾式）
- `device fake / restore`：内存注入 FakeDevice.dylib 改 UIDevice 机型（零残留，重启还原）
- `device advertising / idfv`：广告标识/IDFV；`inject keychain_wipe`：钥匙串清理

### 🛡️ 安全检测
- `device info / probe / snapshot`：TrollStore / task_for_pid / 容器读写 / 注入工具链全项检测

### 🔌 跨 App UI 控制
- `control`（inject / status / ui_tree / screenshot / tap / swipe / type / key / tap_text / type_text）
- 注入 ControlAgent.dylib → localhost:4789 HTTP API（/status /ui_tree /tap /swipe /type）

### 🏗️ 构建与工程
- `tool.install`：统一工具安装闭环——内置原生 bin → Alpine apk 即装即用 → CI 交叉编译原生 iOS 二进制（`build-tool.yml`，best-effort）
- `env.setup_re`：一键逆向工具链（binutils/file/python3/sqlite/tcpdump/7z…）
- `github`（account_status / trigger_build / fetch_runs / download_artifact）：GitHub Actions 触发/查进度/取产物
- `project`：工作区项目管理；`macro`（record / run / list / delete / export）：可录制重复操作

### 🤖 AI 与模型
- 多上游模型（OpenAI 兼容 / Anthropic Messages）、SSE 流式逐字输出、推理强度控制
- 技能系统：`skills.list` / `skills.read` / `skills.set_enabled`（可复用标准工作流）

### 📡 网关与自动化
- Gateway WebSocket 配对、多节点调用、`automation`（run / list / jobs / stop / status / history / set_enabled）、`ssh`（exec / scp）、`server`（start / stop / status）

### 📊 网络与诊断
- `web.search`（多引擎回退 Bing→DuckDuckGo→Baidu、`queries` 多词并行检索自动去重、来源分级排序 `sort`、结果沉淀知识库 `save`）
- `web.fetch`（自动正文抽取 article/main 优先 + 内置浏览器兜底）
- `network.capture`（start / stop / requests / analyze）：注入 NetworkTweak 抓 NSURLSession；TLSHook 解 SSL_read/SSL_write
- `vpn.capture`（⚠️ 半成品/开发中）：系统代理模式隧道（不转发 packetFlow）——自建 socket 直连 App 会断网、QUIC 不解密、TLS-pinned 握手失败；实际可用路径以 local proxy（WiFi 手动代理 127.0.0.1:18180）为准
- `diagnose`（startup / injection）、崩溃日志解析、`verify`（file / app_running）

### 📚 知识库与系统能力
- `knowledge`（import_text / import_file / search / delete / clear）：知识库增删查
- `memory`（内存搜索/修改/冻结）、`assistant_memory`（跨会话记忆）
- `location`（get / fake / status / clear）、`reminder`（create / schedule / recurring）

## 架构要点
- **注册中心**：`MCPCore.swift` 单点注册全部工具，默认全量启用（37 个大工具）
- **Alpine 用户态**：内置 iSH，AI 可自动 `apk add` 安装任意 Linux 工具（python3/git/sqlite/jq…），并通过自动 bind 直读 iOS 文件
- **原生 iOS 工具三通道**：内置 bin / GitHub Actions 交叉编译 / 自写 dylib（`inject load_dylib`）
- **TrollStore 机制**：内置 setuid root 工具链（ldid/optool/insert_dylib/ct_bypass）、trollstorehelper 静默安装
- **失败边界**：高优先级工具统一 `error_code/reason/next_step`，拒绝误导性报错

## 构建
macOS runner / 本地 Mac：`bash scripts/build-ipa.sh`（产物 TrollMCP2.ipa，TrollStore 直接安装）。
CI 传 `RELEASE_VERSION` 自动注入产物版本（解决版本脱节）。
