import re, sys, os

files = [
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\AdvancedTools.swift',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\IconThemeView.swift',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\FakeDeviceView.swift',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\MCPCore.swift',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\ToolsView.swift',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\SettingsView.swift',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\SystemPrompts.swift',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\Sources\TrollMCP2\Localization.swift',
]

ok = True
for f in files:
    src = open(f, encoding='utf-8').read()
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', src)          # 字符串
    s = re.sub(r'//[^\n]*', '', s)                        # 行注释
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)           # 块注释
    name = os.path.basename(f)
    for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
        if s.count(a) != s.count(b):
            print('MISMATCH', name, a, s.count(a), b, s.count(b))
            ok = False
    # 简单 import 检查
    if 'UIKit' in src and 'import UIKit' not in src:
        print('MISSING UIKit import:', name)
        ok = False
    if ok and ('MISMATCH' not in name):
        pass
    print('checked', name, '->', 'OK' if ok else 'FAIL')
    ok = True  # 每个文件独立判断（上面循环内重置）

print('ALL DONE')
