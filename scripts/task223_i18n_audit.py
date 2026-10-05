#!/usr/bin/env python3
"""Task223 item-25 i18n audit:
1. Collect every localize(@"key", ...) key used in Natives/**/*.m (working tree).
2. Collect keys defined in the 4 maintained Localizable.strings files.
3. Report: (a) used-but-missing keys per language; (b) ame223/ame22x-family keys
   introduced by this round; (c) obviously hardcoded UI text in the Task223 diff
   (text/title/setTitle/message assignments with a literal NSString, no localize).
"""
import re, subprocess, sys, os, glob

REPO = "/home/z/my-project/Amethyst-iOS-MyRemastered"
LANGS = ["en", "zh-CN", "zh-Hans", "zh-Hant"]

src_files = []
for pat in ["Natives/*.m", "Natives/**/*.m"]:
    src_files += glob.glob(os.path.join(REPO, pat), recursive=True)
src_files = sorted(set(src_files))

use_re = re.compile(r'localize\(\s*@"([A-Za-z0-9_.\-]+)"')
used = {}
for f in src_files:
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    for m in use_re.finditer(text):
        used.setdefault(m.group(1), set()).add(os.path.basename(f))

defined = {}
for lang in LANGS:
    path = os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings")
    text = open(path, encoding="utf-8", errors="replace").read()
    keys = set(re.findall(r'^"([^"]+)"\s*=', text, re.M))
    defined[lang] = keys

print(f"used keys total: {len(used)}")
for lang in LANGS:
    print(f"defined[{lang}]: {len(defined[lang])}")

missing = {}
for lang in LANGS:
    miss = {k for k in used if k not in defined[lang]}
    missing[lang] = miss
    print(f"\n== missing in {lang}: {len(miss)}")
    for k in sorted(miss):
        print(f"   {k}  (used in: {', '.join(sorted(used[k])[:4])})")

# keys of this round
round_keys = sorted(k for k in used if "ame223" in k or "ame222" in k)
print(f"\n== Task222/223-family keys in use: {len(round_keys)}")
for k in round_keys:
    status = "".join("Y" if k in defined[l] else "-" for l in LANGS)
    print(f"   [{status}] {k}")

# hardcoded UI literals in the uncommitted diff
diff = subprocess.run(["git", "diff", "--", "Natives"], cwd=REPO,
                      capture_output=True, text=True).stdout
hard_re = re.compile(
    r'^\+.*(?:\.text|\.title|setTitle:|message:|titleLabel\.text)\s*=\s*@"([^"\\]{2,60})"')
print("\n== hardcoded UI literals added in diff (candidates):")
seen = set()
for line in diff.splitlines():
    m = hard_re.match(line)
    if m and m.group(1) not in seen:
        seen.add(m.group(1))
        print(f"   {m.group(1)!r}")
if not seen:
    print("   (none)")
