# -*- coding: utf-8 -*-
import zipfile, io, plistlib, os

z1 = zipfile.ZipFile(r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\dl_295\trollmcp2.zip')
names = z1.namelist()
ipa_name = next(n for n in names if n.endswith('.ipa'))
ipa_bytes = z1.read(ipa_name)
print('IPA:', ipa_name, len(ipa_bytes))

z2 = zipfile.ZipFile(io.BytesIO(ipa_bytes))
app_prefix = 'Payload/TrollMCP2.app/'
app_files = [n for n in z2.namelist() if n.startswith(app_prefix)]
print('APP FILES:', len(app_files))

pl = plistlib.loads(z2.read(app_prefix + 'Info.plist'))
print('VERSION:', pl.get('CFBundleShortVersionString'), '| DISPLAY:', pl.get('CFBundleDisplayName'), '| BUNDLE:', pl.get('CFBundleIdentifier'))

main = z2.read(app_prefix + 'TrollMCP2')
for kw in [b'app.entitlements', b'device.keychain_wipe', b'device.keychain_reset', b'device.advertising', b'device.idfv', b'device.refresh_container', b'keychain-2.db', b'resetIdentifier']:
    print(kw.decode(), '->', kw in main)

tw = [n for n in app_files if '/tweaks/' in n]
print('TWEAKS:', [os.path.basename(n) for n in tw])

# 落盘到 artifacts 目录
out = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\artifacts\v2.9.95'
os.makedirs(out, exist_ok=True)
final = os.path.join(out, 'TrollAgent-v2.9.95-20260907.ipa')
with open(final, 'wb') as f:
    f.write(ipa_bytes)
print('SAVED:', final, os.path.getsize(final))
