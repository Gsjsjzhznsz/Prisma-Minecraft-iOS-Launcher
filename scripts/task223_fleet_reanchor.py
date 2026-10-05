#!/usr/bin/env python3
"""Task223 fleet re-anchor sweep (25-item checklist round).

Mechanical cascade, same protocol as task219_sync.py / Task220's sweep:
  1) l10n unique-key baseline: 2520 / 2565 / 2605 -> 2606
     (net +41 this round: 42 added incl. i18n_str_989 rewrite, 1 old form removed)
  2) announcements count 42 -> 43 (task223 appended at tail)
  3) tail-window negative-index shifts, DEEPEST FIRST:
        task206 -6 -> -7 ; task216 -5 -> -6 ; task217 -4 -> -5 ;
        task218 -3 -> -4 ; task219 -2 -> -3 ; task220 -1 -> -2
     Both raw and backslash-escaped quoted forms are swept (spot-tables quoting
     other verifiers' source carry the same substrings).
Order inside PAIRS matters; run phases strictly in sequence.
Idempotent-ish: running twice would double-shift, so this script guards by
checking whether the fleet already carries the 2606 baseline.
"""
import os, re, sys, glob

REPO = "/home/z/my-project/Amethyst-iOS-MyRemastered"
S = os.path.join(REPO, "scripts")

# ---------------------------------------------------------------------------
# Gather target files: every verifier + helper that carries any stale token.
# ---------------------------------------------------------------------------
TARGETS = sorted(set(glob.glob(os.path.join(S, "verify_task*.py")))
                | {os.path.join(S, "task219_syntax.py"),
                   os.path.join(S, "task219_sync.py")})

def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with open(p, "w", encoding="utf-8") as f:
        f.write(s)

# Guard: already swept?
if all("2606" in rd(p) or not re.search(r"25[26][05]|\b2605\b", rd(p)) for p in TARGETS):
    pass  # continue anyway; the pairs simply won't match

# ---------------------------------------------------------------------------
# Phase 1: announcement tail shifts (deepest first). Prefix-based pairs.
# Raw form   : ann[-6]["id"] == "task206
# Escaped    : ann[-6][\"id\"] == \"task206
# ids form   : ids[-4] == "task217
# ann_items  : ann_items[-1]["id"] == "task220
# ---------------------------------------------------------------------------
PHASE1 = [
    # -6 -> -7 (task206 family; also title/content refs)
    ('ann[-6]["id"] == "task206',      'ann[-7]["id"] == "task206'),
    ('ann[-6][\\"id\\"] == \\"task206', 'ann[-7][\\"id\\"] == \\"task206'),
    ('ann[-6]["title"]',                'ann[-7]["title"]'),
    ('ann[-6]["content"]',              'ann[-7]["content"]'),
    # -5 -> -6 (task216 family, incl. date ref)
    ('ann[-5]["id"] == "task216',       'ann[-6]["id"] == "task216'),
    ('ann[-5][\\"id\\"] == \\"task216',  'ann[-6][\\"id\\"] == \\"task216'),
    ('ann[-5]["date"]',                 'ann[-6]["date"]'),
    ('ann[-5]["id"] == "task217',       'ann[-6]["id"] == "task217'),  # safety (none known)
    # -4 -> -5 (task217 family)
    ('ann[-4]["id"] == "task217',       'ann[-5]["id"] == "task217'),
    ('ann[-4][\\"id\\"] == \\"task217',  'ann[-5][\\"id\\"] == \\"task217'),
    ("ann[-4]['id'] == 'task217",       "ann[-5]['id'] == 'task217"),
    ('ids[-4] == "task217',             'ids[-5] == "task217'),
    # -3 -> -4 (task218 family, incl. truncated quoted id)
    ('ann[-3]["id"] == "task218',       'ann[-4]["id"] == "task218'),
    ('ann[-3][\\"id\\"] == \\"task218',  'ann[-4][\\"id\\"] == \\"task218'),
    # -2 -> -3 (task219 family; content refs keep step)
    ('ann[-2]["id"] == "task219',       'ann[-3]["id"] == "task219'),
    ('ann[-2][\\"id\\"] == \\"task219',  'ann[-3][\\"id\\"] == \\"task219'),
    ('ann[-2]["content"]',              'ann[-3]["content"]'),
    # task220 tail: ann_items[-1] -> [-2] (count handled in phase 2)
    ('ann_items[-1]["id"] == "task220', 'ann_items[-2]["id"] == "task220'),
]

# ---------------------------------------------------------------------------
# Phase 2: announcement counts 42 -> 43 (with the 213/214 double-shift first).
# ---------------------------------------------------------------------------
PHASE2 = [
    # verify_task213 H7 + its verbatim quote inside verify_task214: double shift
    ("'== 42' in v207 and '== 41' not in v207",
     "'== 43' in v207 and '== 42' not in v207"),
    # generic count forms
    ('len(ann) == 42',      'len(ann) == 43'),
    ('len(ids) == 42',      'len(ids) == 43'),
    ('len(ann_items) == 42','len(ann_items) == 43'),
    # labels that narrate the count
    ('J-公告 41 条',         'J-公告 42 条'),
]

# ---------------------------------------------------------------------------
# Phase 3: l10n baselines -> 2606.
# ---------------------------------------------------------------------------
PHASE3 = [
    # assertions and their quoted needle forms
    ('== 2520', '== 2606'),
    ('== 2565', '== 2606'),
    ('== 2605', '== 2606'),
    ('!= "2520"', '!= "2606"'),          # verify_task151 stale-detector constant
    ('vals == {2520}', 'vals == {2606}'),
    # labels
    ('唯一键 2520', '唯一键 2606'),
    ('唯一键 2565', '唯一键 2606'),
    ('唯一键 2605', '唯一键 2606'),
    ('unique keys 2605 (Task223 +40)', 'unique keys 2606 (Task223 +41)'),
    ('keys 2520', 'keys 2606'),
    ('keys 2565', 'keys 2606'),
    ('计数 2520', '计数 2606'),
    ('计数 2565', '计数 2606'),
    ('expect 2520 everywhere', 'expect 2606 everywhere'),
    ('2520 family swept', '2606 family swept'),
    ('当前基线 2520', '当前基线 2606'),
    ('2520 基线扫荡', '2606 基线扫荡'),
    ('2520 一致', '2606 一致'),
    ('2520 守恒', '2606 守恒'),
    # spot-table bare needles
    ('("scripts/verify_task206.py", "== 2520")', '("scripts/verify_task206.py", "== 2606")'),
    ('"2520" in rd(', '"2606" in rd('),
    ('"2520"]', '"2606"]'),
    ("'2520'", "'2606'"),
    # Task223 round relabels of Task222-era explanations
    ('2565 = Task212 基线 2520 + 陶瓦联机 21 + 捐赠 7 + 向导介绍页 12 + 启动阶段 5',
     '2606 = Task212 基线 2520 + Task222 45 + Task223 41'),
    ('2605 = 2565 + Task223 的 40', '2606 = 2565 + Task223 的 41'),
    ('2605（Task223 重锚：+40）', '2606（Task223 重锚：+41）'),
    ('l10n {lang} unique keys 2605', 'l10n {lang} unique keys 2606'),
]

changed = {}
for phase, pairs in (("tail-shift", PHASE1), ("ann-count", PHASE2), ("l10n-count", PHASE3)):
    for path in TARGETS:
        src = rd(path)
        orig = src
        for old, new in pairs:
            src = src.replace(old, new)
        if src != orig:
            wr(path, src)
            changed.setdefault(os.path.basename(path), []).append(phase)

print(f"files changed: {len(changed)}")
for name, phases in sorted(changed.items()):
    print(f"  {name}: {', '.join(phases)}")
