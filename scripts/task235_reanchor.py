#!/usr/bin/env python3
# Task235: l10n count baseline re-anchor 2765 -> 2766 (+1 ame235.deps.godl x4 main langs).
# Mirrors the honest re-anchor discipline (Task233 2763->2765 precedent).
import io, os, re, sys

REPO = "/home/z/my-project/Amethyst-iOS-MyRemastered"

# 1) Verify the actual unique-key count in the 4 main languages first.
langs = ["en", "zh-CN", "zh-Hans", "zh-Hant"]
counts = {}
for l in langs:
    p = os.path.join(REPO, f"Natives/resources/{l}.lproj/Localizable.strings")
    with io.open(p, "r", encoding="utf-8") as f:
        s = f.read()
    keys = set(re.findall(r'^"([^"]+)" =', s, re.M))
    counts[l] = len(keys)
print("unique key counts:", counts)
if any(c != 2766 for c in counts.values()):
    print("FATAL: expected 2766 in all four main languages, refusing to re-anchor")
    sys.exit(1)

# 2) Re-anchor every verify script that pins the baseline.
changed = []
for fn in sorted(os.listdir(os.path.join(REPO, "scripts"))):
    if not (fn.startswith("verify_task") and fn.endswith(".py")):
        continue
    p = os.path.join(REPO, "scripts", fn)
    with io.open(p, "r", encoding="utf-8") as f:
        s = f.read()
    if "2765" not in s:
        continue
    s2 = s.replace("2765", "2766")
    if s2 != s:
        with io.open(p, "w", encoding="utf-8") as f:
            f.write(s2)
        changed.append(fn)
print("re-anchored:", changed)
print("OK" if changed else "NOTE: no scripts needed changes")
