import zipfile, plistlib, os, shutil

OUT = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\artifacts\v2.9.90'
ART = os.path.join(OUT, 'TrollAgent-v2.9.90-20260907.ipa')

# 第1层：artifact zip → TrollMCP2.ipa
with zipfile.ZipFile(ART) as z:
    inner = z.namelist()[0]
    data = z.read(inner)
tmp_ipa = os.path.join(OUT, 'inner.ipa')
with open(tmp_ipa, 'wb') as f:
    f.write(data)

# 第2层：TrollMCP2.ipa → Payload/TrollMCP2.app
extract_dir = os.path.join(OUT, 'payload_check')
if os.path.exists(extract_dir):
    shutil.rmtree(extract_dir)
os.makedirs(extract_dir)
with zipfile.ZipFile(tmp_ipa) as z:
    z.extractall(extract_dir)

app = os.path.join(extract_dir, 'Payload', 'TrollMCP2.app')
print('app exists:', os.path.isdir(app))

checks = [
    ('tweaks/ProbeAgent.dylib', 90000),
    ('tweaks/ConfigHook.dylib', 170000),
    ('tweaks/FakeDevice.dylib', 160000),
    ('tweaks/ControlAgent.dylib', None),
    ('tweaks/MemoryTweak.dylib', None),
    ('bin/opainject', 150000),
    ('devices.json', 3000),
    ('blueIcon-1024x1024.png', None),
    ('whiteIcon-1024x1024.png', None),
    ('outsetIcon-1024x1024.png', None),
    ('originalIcon-1024x1024.png', None),
    ('TrollMCP2', None),
    ('TrollMCPDeveloperInstructions.md', None),
]
for rel, minsize in checks:
    p = os.path.join(app, rel)
    if os.path.exists(p):
        sz = os.path.getsize(p)
        ok = 'OK' if (minsize is None or sz >= minsize) else 'TOO_SMALL'
        print(f'{ok}  {rel}  ({sz})')
    else:
        print(f'MISSING  {rel}')

# Info.plist
with open(os.path.join(app, 'Info.plist'), 'rb') as f:
    d = plistlib.load(f)
print('version:', d.get('CFBundleShortVersionString'))
print('display:', d.get('CFBundleDisplayName'))
print('bundle_id:', d.get('CFBundleIdentifier'))
alt = d.get('CFBundleIcons', {}).get('CFBundleAlternateIcons', {})
print('altIcons:', list(alt.keys()))
print('opainject in TSRootBinaries:', any('opainject' in s for s in d.get('TSRootBinaries', [])))
