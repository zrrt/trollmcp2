# -*- coding: utf-8 -*-
import zipfile, io, plistlib, os

z1 = zipfile.ZipFile(r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\dl_297\trollmcp2.zip')
ipa_name = next(n for n in z1.namelist() if n.endswith('.ipa'))
ipa_bytes = z1.read(ipa_name)
z2 = zipfile.ZipFile(io.BytesIO(ipa_bytes))
app_prefix = 'Payload/TrollMCP2.app/'
pl = plistlib.loads(z2.read(app_prefix + 'Info.plist'))
print('VERSION:', pl.get('CFBundleShortVersionString'), '| DISPLAY:', pl.get('CFBundleDisplayName'))

main = z2.read(app_prefix + 'TrollMCP2')
print('markUsed in binary:', b'markUsed' in main)
print('lastUsedConfigId in binary:', b'last_used_config_id' in main)
print('memory prompt (跨会话记忆):', '跨会话记忆'.encode('utf-8') in main)
print('notify emoji ok (AI 已回复):', '✅'.encode('utf-8') in main)
# sqlite_wipe 仍在
bins = [n for n in z2.namelist() if n.startswith(app_prefix + 'bin/')]
print('sqlite_wipe in bin:', any(n.endswith('/sqlite_wipe') for n in bins))

out = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\artifacts\v2.9.97'
os.makedirs(out, exist_ok=True)
final = os.path.join(out, 'TrollAgent-v2.9.97-20260907.ipa')
with open(final, 'wb') as f:
    f.write(ipa_bytes)
print('SAVED:', final, os.path.getsize(final))
