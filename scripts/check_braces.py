import re, io, sys

files = [
    'Sources/TrollMCP2/InjectionManager.swift',
    'Sources/TrollMCP2/RescueTools.swift',
    'Sources/TrollMCP2/QTTools.swift',
    'Sources/TrollMCP2/MCPCore.swift',
    'Sources/TrollMCP2/SystemPrompts.swift',
]
bad = False
for f in files:
    s = io.open(f, encoding='utf-8').read()
    s2 = re.sub(r'"""(.*?)"""', '', s, flags=re.S)
    s2 = re.sub(r'//.*', '', s2)
    for a, b in [('{', '}'), ('(', ')'), ('[', ']')]:
        ca, cb = s2.count(a), s2.count(b)
        if ca != cb:
            print(f'{f}: MISMATCH {a}{b} {ca} vs {cb}')
            bad = True
    print(f'{f}: ok len={len(s)}')
sys.exit(1 if bad else 0)
