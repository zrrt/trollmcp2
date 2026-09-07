# -*- coding: utf-8 -*-
import io

p = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\scripts\patch_v2101_templates.py'
c = io.open(p, encoding='utf-8').read()

# 修 enum anchor：补 4 空格缩进
c = c.replace(
    '    case performanceRegression = "perf_regression"\n}',
    '    case performanceRegression = "perf_regression"\n    }',
)

# 修 list anchor：补 4 空格缩进
c = c.replace(
    '            ["id": "perf_regression", "name": "性能回归测试", "desc": "启动→采样30秒→对比历史→输出回归结论"]\n        ]',
    '            ["id": "perf_regression", "name": "性能回归测试", "desc": "启动→采样30秒→对比历史→输出回归结论"],\n'
    '            ["id": "emergency_recover", "name": "紧急恢复", "desc": "扫描注入状态→恢复全部备份→验证启动（App 打不开时的保命流程）"],\n'
    '            ["id": "network_probe", "name": "抓包分析", "desc": "注入 NetworkTweak→打开App采集→stop→请求列表→统计分析"],\n'
    '            ["id": "new_device", "name": "一键新机", "desc": "重置keychain+刷新广告符+设备伪装写入（⚠️ 清空所有App登录态）"],\n'
    '            ["id": "ai_analyze", "name": "AI分析App", "desc": "采集类结构→当前模型LLM生成hook方案→自动应用（VIP/去广告/绕过检测）"],\n'
    '            ["id": "crash_triage", "name": "闪退诊断", "desc": "启动诊断→崩溃分析→日志采集→给出原因与修复建议"]\n'
    '        ]',
)

# 修 switch anchor：enum/list 修复后，switch anchor 里 performanceRegression 块缩进也对齐（原文件是 8 空格）
# 原 old_switch 已按真实缩进写的，无需改。

io.open(p, 'w', encoding='utf-8').write(c)
print('ANCHORS FIXED')
