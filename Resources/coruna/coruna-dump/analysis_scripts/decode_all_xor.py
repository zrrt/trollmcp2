import re

data = open('final_payload_B_6241388a_inner.js', 'r').read()

# More permissive regex
pattern = r'\[([0-9][0-9, ]*)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*;?\s*\}?\s*\)\.join\('
matches = list(re.finditer(pattern, data))
print(f"Found {len(matches)} XOR-encoded strings total\n")

seen = set()
for i, m in enumerate(matches):
    nums = [int(n.strip()) for n in m.group(1).split(',')]
    key = int(m.group(2))
    decoded = ''.join(chr(x ^ key) for x in nums)
    if decoded not in seen and len(decoded) > 2:
        seen.add(decoded)
        pos = m.start()
        # Find context: what property is being assigned?
        ctx_start = max(0, pos - 80)
        ctx = data[ctx_start:pos]
        # Get last assignment
        assign_match = re.search(r'(this\.\w+|[\w.]+)\s*=\s*(?:this\.\w+\.(?:wo|Eo|fo|mo)\()?\s*\(?\s*$', ctx)
        assign = assign_match.group(0) if assign_match else ctx[-40:]
        print(f"  [{i}] pos={pos} key={key} len={len(decoded)}")
        print(f"       context: ...{assign.strip()}")
        print(f"       decoded: {decoded}")
        print()
