# TrollAgent 开发者指令

> 面向使用 TrollAgent 进行 iOS Tweak / 自动化 / 逆向测试的开发者约定与工程指南。
> 本文件在"设置 → 开发者指令"中展示，同时也是 AI 助手在本 App 内工作的行为规范。

---

## 1. 项目概览

- 项目：TrollAgent（原名 TrollMCP2，TrollStore 环境，无越狱）
- 目标：AI 驱动的移动端实验与 QA 工作台——一句话描述目标，AI 自动完成诊断、操作、验证和报告
- 构建：SwiftPM + GitHub Actions（私有仓库 origina47487lhe-droid/trollmcp2）
- 版本：2.9.115
- 环境：iOS 14+，TrollStore 安装，纯 TrollStore 无越狱

## 2. 核心设计原则

1. **目标导向，不是工具导向**：用户说"检查这个 App 为什么打不开"，AI 自动拆解步骤，而不是让用户知道要调哪些工具。
2. **交付成品**：给出可直接使用的结果、报告、文件，不写空标题、不画饼。
3. **守住约束**：TrollStore only、无越狱。注入必须在 TrollStore 开启"编辑 Entitlements"后**卸载重装**（覆盖安装不重新应用 entitlements）。
4. **先验证再声明**：注入后必须启动检查、hook 触发验证，不能只返回 `injected: true` 就说成功。
5. **可回滚**：所有修改 App 的操作保留备份，失败自动恢复。
6. **可审计**：所有动作记录到本机工具审计，可导出给 AI 分析。

## 3. 项目上下文（v2.9.73）

AI 应优先使用 `project` 工具管理当前项目，避免用户重复说明环境：

```
project action=current          # 查看当前项目（目标App、dylib、历史运行）
project action=create name=... bundle_id=... app_name=... dylib_path=...
project action=list             # 列出所有项目
project action=select project_id=...
project action=history          # 当前项目的运行历史
```

每个项目保存：目标 App、dylib、运行次数、成功率、上次结论。AI 发消息前应先 `project action=current` 读取上下文。

## 4. 任务模板（v2.9.73）

常见流程已固化为一键模板，AI 用 `task.run` 执行，无需逐步调用工具：

| 模板 ID | 用途 | 关键步骤 |
|---|---|---|
| `diagnose_injection` | 诊断注入失败 | 设备检查→注入诊断→知识库匹配→输出原因+修复 |
| `capture_crash` | 采集崩溃现场 | 停止App→采集日志→崩溃分析→生成复现hook模板 |
| `inject_verify` | 注入验证闭环 | dylib预检→杀进程→注入→启动→加载检查→**失败自动回滚** |
| `ipa_health` | IPA健康检查 | 架构/签名/依赖/加密→注入可行性报告 |
| `perf_regression` | 性能回归 | 启动→采样30秒→CPU/内存→回归结论 |

```
task.run template=inject_verify bundle_id=com.example dylib_path=/path/to/x.dylib
```


## 5. 工具调用约定

- **核心白名单**（约 13 个）直接可用：tool_search, ping, device.info, device.probe, workspace.info, artifact.list, artifact.read_text, artifact.find, model.config, injection.status, browser.status, apps.control。
- **其他工具通过 `tool_search` 搜索**后自动注入下一轮请求，不必全量加载。AI 只需要知道工具名称和大概用途，搜索后才获取完整 schema。
- **工具不限制调用次数**。死循环由用户手动暂停。搜索类工具自动授权；敏感隐私操作（删除、注入、修改）需要用户确认。
- **工具名用点号分层**（如 `injection.enable`、`binary.symbols`）。

- **任意 App UI 控制链路（v2.9.103）**：先 `injection.enable`（注入 TrollMCPAgent v4.1，构建时随包自动编译），再 `apps.open` 打开目标 App，等 agent HTTP（127.0.0.1:4792）就绪后用 `apps.control`（action: status/ui_tree/tap/swipe/type/scroll）直接控制 UI；`apps.open_and_input` 已改为 HTTP 链路（打开→等待就绪→type），不再依赖沙盒内 UserDefaults 队列。
- **远程控制链路（v2.9.115 真后台保活）**：`control.inject` 注入 ControlAgent 后**自动开启真后台保活**——TrollAgent 侧静音音频保活、目标 App 侧 FrontBoard scene 拦截（借鉴 ImmortalizerJailed 机制），目标 App 切后台不再被挂起，4789 持续在线。执行远程控制时：注入→`apps.open` 启动目标 App→等 4789 就绪→`control.ui_tree`/`control.tap` 等控制；用户切走 App 也不会断连。远程控制页可手动开关「真后台保活」。

## 6. 工作流可视化（v2.9.72）

AI 调用工具时，聊天界面下方自动显示步骤条：
- 每个工具调用 = 一个步骤（pending/running/success/failed）
- 用户可点击查看详情（输入参数、返回值、耗时）
- AI 回复完成后工作流自动结束

## 7. 崩溃知识库（v2.9.72）

`kb.query` 工具内置 14 种常见错误模式，自动匹配原因和修复方案：
- Operation not permitted → TrollStore Entitlements 未开启或未卸载重装
- bin-setuid=0 → setuid 位丢失
- Failed to parse plist → ldid 签名问题
- Library not loaded → dylib 依赖缺失
- 等等

AI 遇到工具失败时，应自动用 `kb.query error=<错误信息>` 查找已知方案。

## 8. 注入测试闭环

1. 用线上编译产出 `.dylib`（GitHub Actions build-tweak 工作流）。
2. `artifact.find name=xxx ext=dylib` 定位产物。
3. `task.run template=inject_verify` 一键注入+验证+回滚。
4. `injection.inspect bundle_id=...` 确认加载状态。
5. `compat.check` 记录到兼容矩阵（App版本+iOS版本+dylib+结果）。

**注入成功的必要条件**：TrollStore → 已安装 App → 开启"编辑 Entitlements" → **卸载** → 重新安装。覆盖安装不会重新应用 entitlements。

## 8.5 注入安全与紧急恢复（v2.9.89 保命版）

**注入策略（对齐 TrollFools InjectorV3，防事故）：**
1. 目标默认选 **Frameworks/ 内未加密、可读的 Mach-O**（字典序），**不直接修改主二进制**；App Store 加密 App（cryptid=1）跳过，全部加密则明确报错。
2. 备份格式统一为 **`<二进制>.troll-fools.bak`**（与 TrollFools 完全兼容，TrollFools 可识别并卸载我们的注入）。
3. 每一步改 Mach-O 前**先 `ldid -S` 伪签**（修复 install_name_tool 的 __LINKEDIT 顺序报错）。
4. **任一步失败自动回滚**：恢复备份 + 删除已拷贝 dylib。
5. 注入后验证：加载命令已写入 + Mach-O 结构有效，才返回 `injected: true`。

**高危护栏：** 微信/支付宝/系统/银行类 App 注入时返回 `risk_warning`，AI 必须先 `injection.diagnose` 并向用户说明风险；注入始终不碰主二进制。

**紧急恢复（App 打不开时的第一选择）：**
```
injection.restore bundle_id=...      # 单 App 恢复：移除加载命令+删资产+还原备份
rescue.scan                          # 全机扫描：找有注入痕迹/损坏二进制的 App
rescue.recover_all                   # 一键全恢复：自动恢复所有问题 App
rescue.cleanup bundle_id=...         # 清理残留：注入标记/孤儿备份/残留 dylib
```
事故流程：`rescue.scan` → `rescue.recover_all`（或对目标 App `injection.restore`）→ `rescue.cleanup`。
不要用卸载重装救注入事故——那会丢聊天记录等数据。

## 9. Tweak 工程规范

```
tweaks/<Name>/
├── Makefile        # 含 ARCHS、TARGET、THEOS_DEVICE_IP
├── control         # 包名、版本、依赖
├── Tweak.x         # 源码（Logos 语法）
└── <Name>.plist    # Filter（Bundle ID 列表）
```

打包：`make clean package FINALPACKAGE=1`，产物 `.deb` + 裸 `.dylib`（在 `.theos/obj/debug/`）。

## 10. 线上编译（GitHub Actions）

- App 工作流：`build-trollmcp2`（macos-14 + brew install ldid + scripts/build-ipa.sh）
- Tweak 工作流：`build-tweak`（macos-14 + theos）
- 触发：推送 main 或手动 `workflow_dispatch`
- 下载：用 `curl.exe -L -H "Authorization: token $token"`（gh run download 常 TLS 超时）

## 11. 版本迭代流程

1. 升级两处版本号：`Support/Info.plist` 的 CFBundleShortVersionString 与 `SettingsView.swift` 的 LabeledRow。
2. `UpdateManager.checkForUpdate` 已改为动态读取 Info.plist，无需手动传版本号。
3. 静态校验（括号平衡、import UIKit、访问级别、复杂表达式拆分）。
4. 提交推送 → CI → 下载 IPA → 校验 → 交付。

## 12. 内置工具箱

| 类别 | 工具 |
|---|---|
| 设备 | device.info, device.probe, app.start/stop/restart/status/stats |
| 注入 | injection.enable/disable/remove/inspect/list/status, injection.diagnose, **injection.restore, rescue.scan, rescue.recover_all, rescue.cleanup**（v2.9.89 紧急恢复） |
| 高级探测（v2.9.90） | **injection.mem**（opainject 内存注入：不改文件、零残留、重启即消失，临时测试首选）, **probe.inspect**（ProbeAgent 运行时类探测：类/方法/属性/UserDefaults，localhost:4791）, **hook.apply**（ConfigHook 配置化 Hook：hook_config.json 驱动导航栏颜色/全局 tint/弹窗/方法日志，改配置重启即生效）, **device.fake / device.restore**（FakeDevice 设备伪装：fake_device.json 驱动 UIDevice 机型伪装，绿盾式） |
| 工件 | artifact.list/find/read_text, ipa.inspect, dylib.inspect, binary.symbols |
| 诊断 | diagnose.startup, diagnose.crash, kb.query, crash.repro_template |
| 网络 | network.capture（需 NetworkTweak.dylib）, server.start/stop/status |
| 项目 | project, task.run, compat.check, plugin.list, workspace.cleanup |
| 构建 | github.trigger_build, github.fetch_runs, github.download_artifact |
| 浏览器 | browser.open/wait/snapshot/click/type/submit/text/scroll/eval/navigate/status（v2.9.88 起标准流程：open → wait → snapshot → 操作 → text 验证结果） |
| 内存 | memory.search/read/write（需 MemoryTweak.dylib 注入） |
| 远程控制 | control.inject/status/ui_tree/screenshot/tap/swipe/type/key（需 ControlAgent.dylib 注入，AI 可控制任意 App UI） |

## 13. v2.9.90 高级工具使用建议

1. **注入失败排障**：先用 `injection.diagnose`（会检查 Bundle 目录真实可写性）→ `injection.mem` 内存注入验证 dylib 本身可用 → 再决定是否文件注入。
2. **临时测试优先内存注入**：`injection.mem` 不改任何文件、无备份、App 重启自动消失，绝无"注入后打不开 App"风险；文件注入（enable）才需要备份与恢复。
3. **探测目标 App 结构**：`probe.inspect`（自动内存注入 ProbeAgent）→ 查类/方法/UserDefaults，适合逆向前摸底与确认 hook 目标存在。
4. **UI 改动用配置化 Hook**：`hook.apply` 写 hook_config.json + 注入 ConfigHook；改配置只需重启 App，无需重新编译注入。
5. **设备伪装**：`device.fake` 伪装 UIDevice 返回的机型/名称/系统版本（绿盾式）；`device.restore` 一键还原。注意部分 App 用 sysctl 读硬件标识，UIDevice 层伪装不覆盖。
6. **注入前检查目标 App 是否在运行**：内存注入要求进程存活；文件注入（enable）会自动 kill 并建议重启。
7. **安全边界**：对微信/支付宝等敏感 App 注入前必须说明风险并给出恢复方案（rescue.*）；内存注入不会破坏 App，仍要谨慎操作。

---

*本指令随 App 版本迭代维护；如与最新版本不符，以 App 实际功能为准。*

## 14. Filza 式文件浏览与二进制分析（v2.9.115）

工具名与调用方式：
- `fs.tree` —— 浏览目录树。参数：`bundle_id`（目标 App）+ `relative`（容器内相对路径，如 Documents / Library / Library/Preferences），或 `path`（绝对路径）；`depth` 递归深度（1-3），`limit` 每层条数。默认浏览工作区。
- `fs.read` —— 读取文件并自动识别格式。`bundle_id`+`relative` 或 `path`；`max_bytes` 默认 512KB；`as` 可强制 `text` / `json` / `hex`。
  - 文本（UTF-8 / UTF-16）→ 返回原文
  - plist（XML / 二进制）→ 自动转 JSON
  - SQLite → 返回数据表清单
  - 其他二进制 → 返回 magic 与 ASCII 预览，提示改用 fs.hexdump
- `fs.hexdump` —— 二进制十六进制 + ASCII。参数：`path` / `bundle_id`+`relative`、`offset` 起始偏移、`length` 分段长度（默认 256，最大 4096）。

路径范围：仅 App 数据容器（Containers/Data）、App Bundle（Containers/Bundle）、工作区（Documents/Workspace）、用户 Library（/var/mobile/Library）。系统关键区（Keychains、SystemGroup、/usr、/System 等）不可访问。

- `fs.zip` —— ZIP/IPA 归档浏览。`action=list` 列条目（名称/大小/压缩方式），`action=read` + `entry` 读 zip 内单个文件（自动识别文本/plist，`as=hex` 看十六进制）。分析 IPA 直接用它。
- `fs.sql` —— SQLite 只读查询。默认列数据表；`sql` 支持 SELECT/PRAGMA（自动 LIMIT 防爆）。看表结构 `PRAGMA table_info(表名)`。
- `fs.write` / `fs.edit` —— 写文件 / 行级与片段编辑（自动备份 .bak）。仅限工作区与 App 数据容器，禁止 Bundle 与系统区。
- `fs.diff` —— 对比两个文件：文本逐行 diff（+/−），二进制比 SHA256 与首个差异偏移。
- `fs.hash` —— 文件 MD5/SHA1/SHA256/SHA512 + 大小/时间/权限/所有者。
- `fs.find` —— 按文件名关键词搜索（fs.grep 搜内容，这个搜文件名）。
- `fs.download` —— 从 URL 下载到工作区 downloads，返回路径与 SHA256，供后续分析。
- `fs.plist` —— plist 键值读写（支持二进制 plist）：get/set/delete + 点路径 key（如 Root.Foo.Bar），写前自动 .bak。
- `fs.container` —— 按 bundle_id 返回容器路径四件套（Data 容器 / Bundle / Documents / Library / Caches / tmp）。
- `fs.crash` —— 解析设备崩溃日志（.ips/.crash）：异常类型/终止原因/触发线程/栈顶帧，可按 bundle_id 过滤。
- `fs.image_info` —— 图片元数据（PNG/JPEG/GIF/WebP 格式与宽高）。
- `fs.grep` —— 目录文本搜索。`dir` 或 `bundle_id` + `pattern` 关键词 + `ext` 扩展名过滤，返回 文件:行号:匹配行。

与既有分析工具的分工：
- 看文件内容 → `fs.read` / `fs.hexdump`
- 看 App 权限声明 → `app.entitlements`
- 看 IPA / 已装 App 架构签名依赖 → `ipa.inspect`
- 看 dylib 架构签名依赖符号 → `dylib.inspect`
- 提取类 / 方法 / 字符串 / 导入导出 → `binary.symbols`
- 查加壳状态 → `app.encrypt_info`
