# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\ProjectAndTasks.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

# 1. enum 加 case（精确文本，含缩进）
old_enum = "        case performanceRegression = \"perf_regression\"\n    }"
new_enum = "        case performanceRegression = \"perf_regression\"\n" \
           "        case emergencyRecover = \"emergency_recover\"\n" \
           "        case networkProbe = \"network_probe\"\n" \
           "        case newDevice = \"new_device\"\n" \
           "        case aiAnalyze = \"ai_analyze\"\n" \
           "        case crashTriage = \"crash_triage\"\n    }"
assert c.count(old_enum) == 1, 'enum anchor'
c = c.replace(old_enum, new_enum, 1)

# 2. listTemplates 加条目
old_list = '            ["id": "perf_regression", "name": "性能回归测试", "desc": "启动→采样30秒→对比历史→输出回归结论"]\n        ]'
new_list = '            ["id": "perf_regression", "name": "性能回归测试", "desc": "启动→采样30秒→对比历史→输出回归结论"],\n' \
           '            ["id": "emergency_recover", "name": "紧急恢复", "desc": "扫描注入状态→恢复全部备份→验证启动（App 打不开时的保命流程）"],\n' \
           '            ["id": "network_probe", "name": "抓包分析", "desc": "注入 NetworkTweak→打开App采集→stop→请求列表→统计分析"],\n' \
           '            ["id": "new_device", "name": "一键新机", "desc": "重置keychain+刷新广告符+设备伪装写入（⚠️ 清空所有App登录态）"],\n' \
           '            ["id": "ai_analyze", "name": "AI分析App", "desc": "采集类结构→当前模型LLM生成hook方案→自动应用（VIP/去广告/绕过检测）"],\n' \
           '            ["id": "crash_triage", "name": "闪退诊断", "desc": "启动诊断→崩溃分析→日志采集→给出原因与修复建议"]\n        ]'
assert c.count(old_list) == 1, 'list anchor'
c = c.replace(old_list, new_list, 1)

# 3. run() 签名加 options
old_sig = "    func run(_ type: TemplateType, bundleId: String, dylibPath: String? = nil) -> TemplateResult {"
new_sig = "    func run(_ type: TemplateType, bundleId: String, dylibPath: String? = nil,\n             options: [String: Any] = [:]) -> TemplateResult {"
assert c.count(old_sig) == 1, 'sig anchor'
c = c.replace(old_sig, new_sig, 1)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('PART1 OK (enum/list/sig)')
