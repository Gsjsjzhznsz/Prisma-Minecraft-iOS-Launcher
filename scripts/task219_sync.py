#!/usr/bin/env python3
# Task219 fleet re-anchor sweep:
#   1) l10n unique-key baseline 2482 -> 2520 (+38 keys x4 tables)
#   2) announcements count 40 -> 41 (+ task219 entry)
#   3) tail-window anchors shift by one (219 appended at -1):
#        ann[-2]==task217 -> ann[-3] ; ann[-3]==task216 -> ann[-4] ;
#        ann[-4]==task206 -> ann[-5]   (deepest FIRST to avoid double-shift)
#   Order inside the file matters; quoted cross-references (task207 quoting
#   task206's source text) are covered because the inner text is identical.
# verify_task218's D1/G/I sections are re-anchored separately by hand (the
# wizard structure changed: five builders -> six + back button + env/JIT).
import os, re, sys, glob

REPO = os.path.join(os.path.dirname(__file__), "..")
changed = []

def sweep(path, pairs):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    orig = src
    for old, new in pairs:
        src = src.replace(old, new)
    if src != orig:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        changed.append(path)

# --- ordered replacements (deepest tail shift FIRST) ---
PAIRS_ALL = [
    # tail shifts -- double-quoted and single-quoted variants
    ('ann[-4]["id"] == "task206-nggl4es-2026-10-01"', 'ann[-5]["id"] == "task206-nggl4es-2026-10-01"'),
    ("ann[-4]['id'] == 'task206-nggl4es-2026-10-01'", "ann[-5]['id'] == 'task206-nggl4es-2026-10-01'"),
    ('ann[-3]["id"] == "task216-ui-2026-10-03"', 'ann[-4]["id"] == "task216-ui-2026-10-03"'),
    ("ann[-3]['id'] == 'task216-ui-2026-10-03'", "ann[-4]['id'] == 'task216-ui-2026-10-03'"),
    ('ann[-2]["id"] == "task217-download-fixes-about-isolation-2026-10-03"', 'ann[-3]["id"] == "task217-download-fixes-about-isolation-2026-10-03"'),
    ("ann[-2]['id'] == 'task217-download-fixes-about-isolation-2026-10-03'", "ann[-3]['id'] == 'task217-download-fixes-about-isolation-2026-10-03'"),
    # counts
    ("len(ann) == 40", "len(ann) == 41"),
    ("len(ids) == 40", "len(ids) == 41"),
    # l10n baseline
    ("2482", "2520"),
]

for path in sorted(glob.glob(os.path.join(REPO, "scripts/verify_task*.py"))):
    # verify_task219 is written fresh for the new state; skip it
    if path.endswith("verify_task219.py"):
        continue
    sweep(path, PAIRS_ALL)

print(f"swept {len(changed)} verifier files")
for c in changed:
    print("  ", os.path.relpath(c, REPO))

# --- sanity: no stale anchors remain anywhere (except task219 which states the new world) ---
stale = []
for path in sorted(glob.glob(os.path.join(REPO, "scripts/verify_task*.py"))):
    if path.endswith("verify_task219.py"):
        continue
    src = open(path, encoding="utf-8").read()
    for bad in ["2482", "len(ann) == 40", 'ann[-2]["id"] == "task217',
                'ann[-3]["id"] == "task216', 'ann[-4]["id"] == "task206',
                "ann[-2]['id'] == 'task217", "ann[-3]['id'] == 'task216", "ann[-4]['id'] == 'task206"]:
        if bad in src:
            stale.append((os.path.relpath(path, REPO), bad))
if stale:
    print("STALE ANCHORS REMAIN:")
    for s in stale:
        print("  ", s)
    sys.exit(1)
print("no stale anchors remain")
