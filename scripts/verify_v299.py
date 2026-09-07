# -*- coding: utf-8 -*-
import zipfile, io, plistlib, os

z1 = zipfile.ZipFile(r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\TrollMCP2\dl_299\trollmcp2.zip')
ipa_name = next(n for n in z1.namelist() if n.endswith('.ipa'))
ipa_bytes = z1.read(ipa_name)
z2 = zipfile.ZipFile(io.BytesIO(ipa_bytes))
app_prefix = 'Payload/TrollMCP2.app/'
pl = plistlib.loads(z2.read(app_prefix + 'Info.plist'))
print('VERSION:', pl.get('CFBundleShortVersionString'), '| DISPLAY:', pl.get('CFBundleDisplayName'))

# tweaks 全部内置
tweaks = [n.split('/')[-1] for n in z2.namelist() if '/tweaks/' in n and n.endswith('.dylib')]
print('TWEAKS:', sorted(tweaks))
need = {'ProbeAgent.dylib', 'ConfigHook.dylib', 'FakeDevice.dylib',
        'NetworkTweak.dylib', 'MemoryTweak.dylib', 'ControlAgent.dylib'}
print('ALL 6 BUILTIN:', need.issubset(set(tweaks)))

main = z2.read(app_prefix + 'TrollMCP2')
print('new_device in binary:', b'new_device' in main or b'automation.new_device' in main)
print('NetworkCapture in binary:', b'network.capture' in main)

bins = [n for n in z2.namelist() if n.startswith(app_prefix + 'bin/')]
print('sqlite_wipe in bin:', any(n.endswith('/sqlite_wipe') for n in bins))

out = r'C:\Users\q3711\WorkBuddy\2026-08-16-16-09-55\artifacts\v2.9.99'
os.makedirs(out, exist_ok=True)
final = os.path.join(out, 'TrollAgent-v2.9.99-20260907.ipa')
with open(final, 'wb') as f:
    f.write(ipa_bytes)
print('SAVED:', final, os.path.getsize(final))
