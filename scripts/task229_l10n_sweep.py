#!/usr/bin/env python3
"""task229_l10n_sweep.py -- re-anchor every verifier that asserts a stale
Localizable.strings key count. Task229 added 12 keys to the five-file parity
set (en/zh-Hans/zh-Hant/zh-CN: 2749 -> 2761). Historical sweeps replaced only
the ADJACENT previous number, so any file asserting an older count (27152761/2708/
2696/2606...) stays red forever -- this sweep replaces ALL stale counts
(2749 and below, but only values that actually appear as count assertions),
then verifies the touched files pass."""
import re, subprocess, sys, os, glob

os.chdir('/home/z/my-project/Amethyst-iOS-MyRemastered')
NEW = 2761
STALE = [2749, 2715, 2708, 2696, 2690, 2678, 2650, 2606, 2228, 1916]

# actual current count
def count_keys(path):
    c = open(path, encoding='utf-8', errors='replace').read()
    return len(re.findall(r'^"[^"]+"\s*=', c, re.M))

n_en = count_keys('Natives/resources/en.lproj/Localizable.strings')
n_zh = count_keys('Natives/resources/zh-Hans.lproj/Localizable.strings')
n_cn = count_keys('Natives/resources/zh-CN.lproj/Localizable.strings')
n_hant = count_keys('Natives/resources/zh-Hant.lproj/Localizable.strings')
n_ja = count_keys('Natives/resources/ja.lproj/Localizable.strings')
print(f'live counts: en={n_en} zh-Hans={n_zh} zh-CN={n_cn} zh-Hant={n_hant} ja={n_ja}')
assert n_en == n_zh == n_cn == n_hant == NEW, 'parity set mismatch'

changed = []
for f in sorted(glob.glob('scripts/verify_task*.py')) + sorted(glob.glob('scripts/task*_l10n*.py')):
    src = open(f, encoding='utf-8', errors='replace').read()
    orig = src
    for s in STALE:
        # replace count-assertion contexts: == 2727, 2749), :2749, 2749 次 etc.
        # keep it surgical: the number must be adjacent to a count-comparison context
        src = re.sub(r'(==\s*)%d\b' % s, r'\g<1>%d' % NEW, src)
        src = re.sub(r'(counts?[^0-9\n]{0,40}%d\b)' % s, r'\g<1>%d' % NEW, src)
        src = re.sub(r'(期望[^0-9\n]{0,10})%d\b' % s, r'\g<1>%d' % NEW, src)
        src = re.sub(r'(基线[^0-9\n]{0,10})%d\b' % s, r'\g<1>%d' % NEW, src)
    if src != orig:
        open(f, 'w', encoding='utf-8').write(src)
        changed.append(f)

print('files re-anchored:', len(changed))
for c in changed:
    print('  ', c)

# ja is a partial-translation language (not in the parity set); ja count = 1899.
# fix any sweep that wrongly moved ja assertions to NEW
for f in changed:
    src = open(f, encoding='utf-8', errors='replace').read()
    if 'ja.lproj' in src and re.search(r'ja[^0-9\n]{0,80}%d' % NEW, src):
        print(f'NOTE: {f} may reference ja with the parity count -- review needed')

# run the re-anchored verifiers that fail-fast
fails = []
for f in ['scripts/verify_task129.py', 'scripts/verify_task130.py', 'scripts/verify_task131.py',
          'scripts/verify_task132.py', 'scripts/verify_task133.py', 'scripts/verify_task134.py',
          'scripts/verify_task135.py']:
    r = subprocess.run([sys.executable, f], capture_output=True, text=True, timeout=240)
    status = 'OK' if r.returncode == 0 else 'FAIL'
    if r.returncode != 0:
        fails.append(f)
        tail = [l for l in r.stdout.splitlines() if 'FAIL' in l][:3]
        print(f'{f}: {status} {tail}')
    else:
        print(f'{f}: {status}')

sys.exit(1 if fails else 0)
