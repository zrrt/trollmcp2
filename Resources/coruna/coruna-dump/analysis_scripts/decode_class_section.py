import re

data = open('final_payload_B_6241388a_inner.js', 'r').read()

# Find class oc through end of file
idx = data.find('class oc')
subset = data[idx:]

# Find all XOR patterns
pattern = r'\[([0-9, ]+)\]\.map\(x\s*=>\s*\{?\s*return\s+String\.fromCharCode\(x\s*\^\s*(\d+)\)\s*\}?\s*\)\.join\(\s*["\x27]{2}\s*\)'
matches = list(re.finditer(pattern, subset))
print(f"Found {len(matches)} XOR-encoded strings in class section\n")

for i, m in enumerate(matches):
    nums = [int(n.strip()) for n in m.group(1).split(',')]
    key = int(m.group(2))
    decoded = ''.join(chr(x ^ key) for x in nums)
    print(f"  [{i}] key={key} len={len(decoded)}: {decoded}")
