import io, re, sys

files = [
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\tweaks\ProbeAgent\Tweak.x',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\tweaks\ConfigHook\Tweak.x',
    r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\tweaks\FakeDevice\Tweak.x',
]
for f in files:
    s = io.open(f, encoding='utf-8').read()
    s2 = re.sub(r'@?"(?:\\.|[^"\\])*"', '""', s)
    s2 = re.sub(r'//[^\n]*', '', s2)
    s2 = re.sub(r'/\*.*?\*/', '', s2, flags=re.S)
    name = f.split('\\')[-1]
    ok = True
    for a, b in [('{','}'), ('(',')'), ('[',']')]:
        d = s2.count(a) - s2.count(b)
        print(name, a+b, d, 'OK' if d == 0 else 'MISMATCH')
        if d != 0: ok = False
    print(name, '=>', 'PASS' if ok else 'FAIL')
