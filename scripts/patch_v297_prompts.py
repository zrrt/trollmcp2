# -*- coding: utf-8 -*-
import io

path = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\SystemPrompts.swift'
with io.open(path, 'r', encoding='utf-8') as f:
    c = f.read()

old = """            4. 涉及修改 App、注入、删除等操作时，先说明将要做什么，再执行。
            5. 操作完成后验证结果，不能只返回"成功"。
            \"\"\""""
new = """            4. 涉及修改 App、注入、删除等操作时，先说明将要做什么，再执行。
            5. 操作完成后验证结果，不能只返回"成功"。
            6. 跨会话记忆（v2.9.97）：用户提到"上次/之前/以前"的上下文时，先调 assistant.memory_list 查询已有记忆；有值得长期保留的结论用 assistant.memory_set 保存。
            \"\"\""""
assert old in c, 'default prompt not found'
c = c.replace(old, new)

old2 = """            6. 注入操作前提：提醒用户 TrollStore 需开启"编辑 Entitlements"并卸载重装（覆盖安装不生效）。"""
new2 = """            6. 注入操作前提：提醒用户 TrollStore 需开启"编辑 Entitlements"并卸载重装（覆盖安装不生效）。
            6b. 跨会话记忆（v2.9.97）：涉及历史上下文先用 assistant.memory_list 查询，重要结论用 assistant.memory_set 保存（键如 device_id / project_state）。"""
assert old2 in c, 'developer prompt not found'
c = c.replace(old2, new2)

with io.open(path, 'w', encoding='utf-8') as f:
    f.write(c)
print('PATCHED SystemPrompts')
