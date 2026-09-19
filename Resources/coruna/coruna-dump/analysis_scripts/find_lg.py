data = open('final_payload_B_6241388a_inner.js','r').read()
import re

# Find Lg() method definition
m = re.search(r'Lg\(\)\s*\{', data)
if m:
    lg_start = m.start()
    print(f'Lg() definition at: {lg_start}')
    chunk = data[lg_start:lg_start+800]
    print(chunk)
else:
    # Try to find it via the property reference
    idx = data.find('this.Lg()')
    print(f'this.Lg() at: {idx}')
    # Find the next method-like definition 'Lg(){'
    idx2 = data.find('Lg()', idx+5)
    print(f'Next Lg() at: {idx2}')
    chunk = data[idx2:idx2+800]
    print(chunk)

print("\n\n=== Searching for khTYss, ZPvyxD, uxHrSg, hY1Ib7 context ===")
for name in ['khTYss', 'ZPvyxD', 'uxHrSg', 'hY1Ib7']:
    idx = data.find(name)
    if idx >= 0:
        print(f'{name} at {idx}: ...{data[max(0,idx-40):idx+80]}...')
        print()
