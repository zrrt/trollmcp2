# TrollMCP2 开发者指令

> 面向使用 TrollMCP2 进行 iOS Tweak / 自动化工具开发的开发者约定与工程指南。
> 本文件在"设置 → 开发者指令"中展示，同时也是 AI 助手在本 App 内工作的行为规范。

---

## 1. 项目概览

- 项目：TrollMCP2（TrollStore 环境，无越狱）
- 目标：线上编译 Tweak → 下载产物 → 注入测试 的完整闭环
- 构建：SwiftPM + GitHub Actions（私有仓库 origina47487lhe-droid/trollmcp2）
- 版本：2.9.17
- 环境：iOS 14+，TrollStore 安装，TrollFools 注入

## 2. 开发者约定

1. **交付成品**：给出可直接使用的命令、脚本、文件与验证步骤，不写空标题、不画饼。
2. **守住约束**：TrollStore only、无越狱、不注入目标进程。在约束内做最优设计。
3. **匹配语言**：对话跟随用户语言，代码与标识符用英文。
4. **先验证再声明**：产物必须经过实际构建/运行验证后，才能报告"完成"。
5. **可审计**：涉及数字、来源、结论时标注出处；不确定的标为估算。

## 3. 技能（Skill）编写规范

技能是预置的工作流指令，AI 通过 `skills.list` 发现、`skills.read` 读取并按指令执行。

### 字段

| 字段 | 说明 |
|---|---|
| name | 技能名称（简短、可搜索，如"翻译润色"） |
| summary | 用途摘要（AI 判断何时使用该技能的依据） |
| instruction | 完整指令（分步骤、可执行、带输出要求） |

### 规范

- 技能指令要**步骤化**：1/2/3… 明确输入、处理、输出。
- summary 用一句话说清"这个技能解决什么问题"。
- 技能应聚焦单一职责，不要一个技能塞多件事。
- 新建技能：设置 → Agents 与 Skills → 右上角 +。

## 4. 工具调用约定

- 核心白名单工具（约 20 个）直接可用：ping、device.info、workspace.info、artifact.*、web.search、knowledge.search、github.*、model.*、gateway.status、injection.*、build.*、skills.list/skills.read。
- 其他工具通过 `tool_search` 搜索后自动注入下一轮请求，不必全量加载。
- 工具名用点号分层（如 `github.trigger_build`）；禁用工具在"工具权限策略"中管理。

## 5. Tweak 工程规范

一个最小可编译的 Tweak 工程必须包含：

```
projects/<Name>/
├── Makefile        # 含 Tweak 目标、THEOS_DEVICE_IP 等
├── Tweak.x         # 源码（Logos 语法）
└── <Name>.plist    # Filter（Bundle ID 列表）
```

打包命令：`make clean package FINALPACKAGE=1`，产物为 `.deb` / `.dylib`。

## 6. 线上编译（GitHub Actions）

- 工作流：`build-trollmcp2`，artifact 名 `TrollMCP2-ipa`。
- 推送 `main` 或手动触发 `workflow_dispatch`。
- 查看进度：`gh run view <id> --repo <repo>`；下载：`gh run download <id> -D <dir> --name <name>`。
- 校验产物：读取 `Payload/*.app/Info.plist` 的 CFBundleShortVersionString 与 Mach-O 字符串。

## 7. 版本迭代流程

1. 升级两处版本号：`Support/Info.plist` 与 `SettingsView.swift` 的"版本"行。
2. 静态校验（括号平衡、符号存在、iOS14 禁区扫描）。
3. 提交推送 → CI → 下载 IPA → 校验 → 更新 HANDOFF.md → 交付。

## 8. 注入测试闭环

1. 用线上编译产出 `.dylib` / `.deb`。
2. 通过 TrollFools 注入目标 App（TrollStore 环境）。
3. 用 `injection.*` 工具查看注入状态与二进制列表。
4. 用 `device.probe` 检测本机环境（task_for_pid、容器读写、amfid 推断）。

---

*本指令随 App 版本迭代维护；如与最新版本不符，以 App 实际功能为准。*
