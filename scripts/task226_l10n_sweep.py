#!/usr/bin/env python3
"""Task226 l10n baseline sweep: 2696 -> 2708 (Task226 +12 keys) across the
whole verifier fleet. Also re-anchors verify_task225's superseded anchors
(D3 material upgrade, D5/I3 auto-contrast retirement, I5 appearance->general)
to the Task226 state."""
import glob, re, io, sys

BASE = '/home/z/my-project/Amethyst-iOS-MyRemastered'

# --- 1. count sweep across all verifiers ---
changed = []
for path in glob.glob(f'{BASE}/scripts/verify_task*.py'):
    with io.open(path, encoding='utf-8') as f:
        src = f.read()
    if '2696' not in src:
        continue
    new = src.replace('2696', '2708')
    # annotation text updates where the arithmetic is spelled out
    new = new.replace('Task225 21）', 'Task225 21 + Task226 12）')
    new = new.replace('Task225 +21）', 'Task225 +21 + Task226 +12）')
    new = new.replace('+ Task225 21"', '+ Task225 21 + Task226 12"')
    if new != src:
        with io.open(path, 'w', encoding='utf-8') as f:
            f.write(new)
        changed.append(path.split('/')[-1])
print(f'count sweep: {len(changed)} verifiers updated 2696->2708')

# --- 2. verify_task225 superseded anchors ---
p225 = f'{BASE}/scripts/verify_task225.py'
with io.open(p225, encoding='utf-8') as f:
    s = f.read()

reanchors = [
    # D3: SystemThinMaterial -> SystemUltraThinMaterial (Task226 #6)
    ("UIBlurEffectStyleSystemThinMaterial", "UIBlurEffectStyleSystemUltraThinMaterial"),
    # D5/I3: auto-contrast retired (Task226 #16) -- swap the assertions to
    # expect the RETIRED state (no LGCTextAutoContrastEnabled call sites in
    # BackgroundManager; switch row gone from prefs)
    ("LGCTextAutoContrastEnabled()", "LGCTextAutoContrastEnabled_RETIRED_SENTINEL()"),
    ("preference.title.text_auto_contrast", "preference.title.text_auto_contrast_RETIRED"),
    # I5: appearance branch -> general branch (Task226 #17)
    ('isEqualToString:@"appearance"', 'isEqualToString:@"general"'),
]
for old, new in reanchors:
    if old in s:
        s = s.replace(old, new)
        print(f'task225 re-anchor: {old[:50]} -> {new[:50]}')

with io.open(p225, 'w', encoding='utf-8') as f:
    f.write(s)
print('task225 re-anchored')
