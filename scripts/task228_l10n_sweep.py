#!/usr/bin/env python3
"""Task228 l10n baseline sweep: 2708 -> 2715 (Task227 +7 ame227 keys) across
the whole verifier fleet. Task227's closure only re-anchored its own K1/Q1
checks; the other ~25 count-anchored verifiers (and the cross-reads between
them, e.g. verify_task210 reading verify_task206's "== 2708") stayed on the
Task226 baseline and went red -- surfaced by Task228's chain run. Also
re-anchors verify_task227 D3 to the Task228 glass default flip."""
import glob, io

BASE = '/home/z/my-project/Amethyst-iOS-MyRemastered'

# --- 1. count sweep across all verifiers ---
changed = []
for path in glob.glob(f'{BASE}/scripts/verify_task*.py'):
    with io.open(path, encoding='utf-8') as f:
        src = f.read()
    if '2708' not in src:
        continue
    new = src.replace('2708', '2715')
    # annotation text updates where the arithmetic is spelled out
    new = new.replace('Task226 12）', 'Task226 12 + Task227 7）')
    new = new.replace('Task226 +12）', 'Task226 +12 + Task227 +7）')
    if new != src:
        with io.open(path, 'w', encoding='utf-8') as f:
            f.write(new)
        changed.append(path.split('/')[-1])
print(f'count sweep: {len(changed)} verifiers updated 2708->2715')
for c in changed:
    print(f'  - {c}')

# --- 2. verify_task227 D3 re-anchor (Task228: default flipped to composite) ---
p227 = f'{BASE}/scripts/verify_task227.py'
with io.open(p227, encoding='utf-8') as f:
    s = f.read()

old_d3 = '''check("D3 系统 UIGlassEffect 优先 + 逃生阀",
      "_LGCCreateGlassEffect(isDark)" in lgc
      and "AME227_SYSTEM_GLASS" in lgc)'''
new_d3 = '''check("D3 组合玻璃默认 + 系统 UIGlassEffect opt-in 逃生阀【Task228 重锚：装机实锤系统玻璃黑面，默认反转】",
      "_LGCCreateGlassEffect(isDark)" in lgc
      and "AME227_SYSTEM_GLASS" in lgc
      and 'strcmp(ame228_env, "1") == 0' in lgc
      and "ame228_compositeLogged" in lgc)'''

if old_d3 in s:
    s = s.replace(old_d3, new_d3)
    print('task227 D3 re-anchored to Task228 composite-default state')
else:
    print('WARNING: task227 D3 pattern not found -- manual inspection needed')

with io.open(p227, 'w', encoding='utf-8') as f:
    f.write(s)
print('done')
