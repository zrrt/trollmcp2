# 校验 MCPCore 中所有 register(XxxTool()) 的类都有定义
import re, os, sys

SRC = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2'

# 收集所有定义的类
defined = set()
for f in os.listdir(SRC):
    if not f.endswith('.swift'):
        continue
    text = open(os.path.join(SRC, f), encoding='utf-8').read()
    for m in re.finditer(r'class\s+(\w+Tool)\b', text):
        defined.add(m.group(1))

# 收集 MCPCore 里的注册（含多行调用）
core = open(os.path.join(SRC, 'MCPCore.swift'), encoding='utf-8').read()
registered = set(re.findall(r'register\(\s*(\w+Tool)\s*\(', core))

missing = sorted(registered - defined)
extra = sorted(defined - registered)
print('registered:', len(registered), 'defined:', len(defined))
print('MISSING (registered but not defined):', missing if missing else 'NONE')
if extra:
    print('defined but not registered (可能正常，被其它文件用):', extra[:20])
sys.exit(1 if missing else 0)
