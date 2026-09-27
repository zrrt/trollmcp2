# AGENTS.md — TrollAgent AI 代理入口

> 你是运行在 TrollAgent（iOS 逆向/自动化 MCP 工具）之上的 AI 代理。开始任何任务前**先读完本文件**，再按 RULES.md 的路由契约执行。

## 这是什么

TrollAgent 是部署在 iOS 设备上的原生 MCP 服务，通过 26 个原生工具让 AI 直接操作真实 iOS 系统：App 管理、dylib 注入、网络抓包、SQLite 取证、跨环境文件、内存修改、包解剖、设备/定位等。Shell 分为 **iOS 原生**（直接读写真实文件系统）与 **ISH Alpine**（Linux 工具链）两套环境。

## 第一原则：先路由，后动手

遇到用户任务，**不要直接乱试工具**。按以下顺序：

1. **读 RULES.md** 的操作契约（MUST/SHOULD 语义）。
2. **路由**：用 `skills.list` 搜索匹配的技能（query 用任务关键词，如 `inject`/`capture`/`db`/`package`/`memory`）。命中则 `skills.read` 读取完整指令，**按指令执行**。
3. **未命中**：再用 `ta list` 查看可用工具，按工具文档组合；复杂多步流程优先参考既有技能方法论。
4. 执行时用 `ta <tool>` 或对应 MCP 工具，产出结构化结果与证据。

## 核心工具速查（常用）

| 工具 | 作用 | 典型用法 |
|---|---|---|
| `ta app` | App 管理/启动/安装/诊断 | `ta app status bundle_id:...` |
| `ta inject` | dylib 注入与逆向 | `ta inject status / enable` |
| `ta network.capture` | HTTP/HTTPS 抓包 | `ta network.capture ...` |
| `ta vpn.capture` | 系统级 MITM 隧道（TrollStore 环境受限时退化到本地代理） | `ta vpn.capture ...` |
| `ta db` | SQLite 取证分析（自动桥接 iOS .db → Alpine 跑 sqlite3） | `ta db ...` |
| `ta file` | 跨环境文件检查（iOS→Alpine 自动桥接） | `ta file inspect path:...` |
| `ta package` | 解剖 .deb/.ipa | `ta package ...` |
| `ta memory` | 进程内存修改（H5GG 类） | `ta memory ...` |
| `ta device` / `ta location` | 设备信息/定位 | `ta device info` |
| `ta shell.exec` | 原生 shell（iOS 原生 或 Alpine） | `ta shell.exec ...` |
| `ta skills.list/read` | 技能发现与读取 | `ta skills list query:...` |

完整清单：`ta list`；单工具参数：`ta help <tool>`。

## 环境与桥接（关键约束）

- **iOS 原生 shell**：直接读真实文件系统，支持 head/tail/grep/wc/sed/awk/uniq/cut/tr/echo/cat/base64 等过滤，但**不支持通配符展开、cd 后相对路径、二进制 grep**——一律用绝对路径。
- **ISH Alpine**：Linux 工具链（strings/file/sqlite3/nm/otool 等），通过自动桥接读取 iOS 文件到 `/tmp/_bridge_N_...`。
- **单向桥**：Alpine 写 `/tmp` 的文件会落到 iOS 侧；**iOS 侧后写入的文件 Alpine 看不到**。需要跨环境的数据，正确姿势是"iOS 读 → 从 Alpine 侧写 /tmp → 在 Alpine 用"。
- 工具输出可能走 `tool_spill` 落盘，读时用绝对路径。

## 输出契约

- 结论先给判断，再给证据（命令/路径/字节/哈希/表结构）。
- 涉及具体文件时给出**绝对路径**，不要用占位符或相对路径。
- 每一步说清"做了什么、结果是什么、下一步依据"。

## 定位

TrollAgent 是一个**轻量 iOS 操作路由包**：AI 路由 + 原生工具执行 + 经验记忆（`AssistantMemoryTools` / knowledge base）。遇到不熟悉的逆向/抓包/注入流程，先查技能库，缺技能可建议新增，不要把任务硬塞到不匹配的工具。
