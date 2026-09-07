# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\Models.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

# 1) send 开头 markUsed
old = """    func send(_ text: String, using config: ModelConfig, imageDataURLs: [String]? = nil,
              reasoningLevel: Int = 0, smartSearch: Bool = true) {
        // v2.9.82：请求开始——首次要通知权限 + 开启后台任务延长
        TaskNotify.shared.requestPermissionIfNeeded()"""
new = """    func send(_ text: String, using config: ModelConfig, imageDataURLs: [String]? = nil,
              reasoningLevel: Int = 0, smartSearch: Bool = true) {
        // v2.9.97：记住最近使用的模型，顶栏/下次启动立即恢复
        ModelStore.shared.markUsed(config.id.uuidString)
        // v2.9.82：请求开始——首次要通知权限 + 开启后台任务延长
        TaskNotify.shared.requestPermissionIfNeeded()"""
assert old in c, 'send markUsed not found'
c = c.replace(old, new)

# 2) 通知标题加 emoji 与模型名
old2 = '''TaskNotify.shared.notifyIfBackground(title: "AI 已回复", body: String(text.prefix(60)))'''
new2 = '''TaskNotify.shared.notifyIfBackground(title: "✅ AI 已回复", body: String(text.prefix(60)))'''
assert old2 in c, 'notify ok not found'
c = c.replace(old2, new2)

old3 = '''TaskNotify.shared.notifyIfBackground(title: "任务出错", body: String(error.localizedDescription.pre'''
# 找到该行完整文本
import re
m3 = re.search(r'TaskNotify\.shared\.notifyIfBackground\(title: "任务出错".*?\)\n', c, re.S)
assert m3, 'notify err not found'
c = c.replace(m3.group(0), m3.group(0).replace('title: "任务出错"', 'title: "⚠️ 任务出错"'))

old4 = '''TaskNotify.shared.notifyIfBackground(title: "任务已停止", body: "达到极端安全上限（60 轮），已停止。可点「停止」中断。")'''
new4 = '''TaskNotify.shared.notifyIfBackground(title: "⏹ 任务已停止", body: "达到极端安全上限（60 轮），已停止。可点「停止」中断。")'''
assert old4 in c, 'notify stop not found'
c = c.replace(old4, new4)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('PATCHED send+notify')
