# TrollAgent 开发者指令

> 面向使用 TrollAgent 进行 iOS Tweak / 自动化 / 逆向测试的开发者约定与工程指南。
> 本文件在"设置 → 开发者指令"中展示，同时也是 AI 助手在本 App 内工作的行为规范。

---

## 1. 项目概览

- 项目：TrollAgent（原名 TrollMCP2，TrollStore 环境，无越狱）
- 目标：AI 驱动的移动端实验与 QA 工作台——一句话描述目标，AI 自动完成诊断、操作、验证和报告
- 构建：SwiftPM + GitHub Actions（私有仓库 origina47487lhe-droid/trollmcp2）
- 版本：2.9.73
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

- **核心白名单**（约 11 个）直接可用：tool_search, ping, device.info, device.probe, workspace.info, artifact.list, artifact.read_text, artifact.find, model.config, injection.status, browser.status。
- **其他工具通过 `tool_search` 搜索**后自动注入下一轮请求，不必全量加载。AI 只需要知道工具名称和大概用途，搜索后才获取完整 schema。
- **工具不限制调用次数**。死循环由用户手动暂停。搜索类工具自动授权；敏感隐私操作（删除、注入、修改）需要用户确认。
- **工具名用点号分层**（如 `injection.enable`、`binary.symbols`）。

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
| 注入 | injection.enable/disable/remove/inspect/list/status, injection.diagnose |
| 工件 | artifact.list/find/read_text, ipa.inspect, dylib.inspect, binary.symbols |
| 诊断 | diagnose.startup, diagnose.crash, kb.query, crash.repro_template |
| 网络 | network.capture（需 NetworkTweak.dylib）, server.start/stop/status |
| 项目 | project, task.run, compat.check, plugin.list, workspace.cleanup |
| 构建 | github.trigger_build, github.fetch_runs, github.download_artifact |
| 浏览器 | browser.navigate/click/type/snapshot, browser.status |
| 内存 | memory.search/read/write（需 MemoryTweak.dylib 注入） |

---

*本指令随 App 版本迭代维护；如与最新版本不符，以 App 实际功能为准。*
