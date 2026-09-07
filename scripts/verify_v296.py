# -*- coding: utf-8 -*-
import zipfile, io, plistlib, os

z1 = zipfile.ZipFile(r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\dl_296\trollmcp2.zip')
ipa_name = next(n for n in z1.namelist() if n.endswith('.ipa'))
ipa_bytes = z1.read(ipa_name)
z2 = zipfile.ZipFile(io.BytesIO(ipa_bytes))
app_prefix = 'Payload/TrollMCP2.app/'
app_files = [n for n in z2.namelist() if n.startswith(app_prefix)]

pl = plistlib.loads(z2.read(app_prefix + 'Info.plist'))
print('VERSION:', pl.get('CFBundleShortVersionString'), '| DISPLAY:', pl.get('CFBundleDisplayName'))

main = z2.read(app_prefix + 'TrollMCP2')
print('timeout 25s in binary:', b'timeoutInterval: 25' in main or b'\x19\x00\x00\x00' in main)

# bin 工具
bins = [n for n in app_files if n.startswith(app_prefix + 'bin/')]
print('BIN FILES:', [os.path.basename(n) for n in bins])
sw = z2.read(app_prefix + 'bin/sqlite_wipe')
print('sqlite_wipe size:', len(sw), '| magic:', sw[:4].hex(), '| arm64:', b'\x64\x00\x00\x00' in sw[:8] or sw[4:8] == b'\x0b\x00\x00\x00')
# Mach-O magic: arm64 = 0xfeedfacf little endian -> cf fa ed fe
print('macho magic cf fa ed fe:', sw[:4] == b'\xcf\xfa\xed\xfe')

# 版本行多处
print('keychain wipe sqlite ref:', b'sqlite_wipe' in main)

out = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\artifacts\v2.9.96'
os.makedirs(out, exist_ok=True)
final = os.path.join(out, 'TrollAgent-v2.9.96-20260907.ipa')
with open(final, 'wb') as f:
    f.write(ipa_bytes)
print('SAVED:', final, os.path.getsize(final))
