#!/usr/bin/env python3
"""Task228 round 2: byte-level fixes + stale-anchor re-anchors.

1. .github/workflows/development.yml: Task228's own Edit-tool insertion wrote
   7 LF lines (201-207) into a 411-line CRLF file -- the exact byte discipline
   that verify_task217/218/219 K3/H3/K4 guard. Normalize back to pure CRLF.
2. Natives/installer/modpack/CurseForgeAPI.m: Task227's dual-source edit wrote
   24 LF-only lines into the 1370-line CRLF file (verify_task211 B6 red since
   17774754). Normalize back to pure CRLF.
3. verify_task133 C1: count 3 -> 4 (Task224 b996e62d8 added the 4th profile-URL
   site, same undashed helper -- intent holds, arithmetic was stale).
4. verify_task193 E: IMG_9288.jpeg presence -> absence (user deleted the upload
   via web, commit 3ae087cd; decode block short-circuits on the existence if).
5. Stale l10n count sweep 2606 -> 2715 in verify_task{134,143,168,170,174,175,
   180}.py -- red since the Task224 era because every historical sweep only
   replaced the ADJACENT previous number (2696->2708, 2708->2715) and these
   files were never on the adjacent baseline.
"""
import io

def rd(p):
    with io.open(p, encoding="utf-8") as f:
        return f.read()

def wr(p, s):
    with io.open(p, "w", encoding="utf-8") as f:
        f.write(s)

problems = []

# --- 1+2. CRLF normalization ---
for p in (".github/workflows/development.yml",
          "Natives/installer/modpack/CurseForgeAPI.m"):
    b = open(p, "rb").read()
    crlf = b.count(b"\r\n")
    lf_only = b.count(b"\n") - crlf
    if lf_only == 0:
        print(f"{p}: already pure CRLF ({crlf} lines), skip")
        continue
    nb = b.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
    open(p, "wb").write(nb)
    n_crlf = nb.count(b"\r\n")
    n_lf = nb.count(b"\n") - n_crlf
    print(f"{p}: {crlf} CRLF + {lf_only} LF-only -> {n_crlf} CRLF, {n_lf} LF-only remain")
    if n_lf != 0:
        problems.append(p)

# --- 3. verify_task133 C1 re-anchor ---
p = "scripts/verify_task133.py"
s = rd(p)
old_c1 = ('check("C1 三处 profile URL 均用无连字符 profileId",\n'
          "      tpa.count('ame133_undashedProfileId(self.authData[@\"profileId\"])') == 3)")
new_c1 = ('check("C1 四处 profile URL 均用无连字符 profileId【Task228 重锚：Task224 b996e62d8 增至四处，同款 helper】",\n'
          "      tpa.count('ame133_undashedProfileId(self.authData[@\"profileId\"])') == 4)")
if old_c1 in s:
    s = s.replace(old_c1, new_c1)
    wr(p, s)
    print("verify_task133: C1 re-anchored 3 -> 4")
elif new_c1 in s:
    print("verify_task133: C1 already re-anchored")
else:
    problems.append("verify_task133 C1 pattern not found")

# --- 4. verify_task193 E re-anchor ---
p = "scripts/verify_task193.py"
s = rd(p)
old_e = 'check("E", "根目录 IMG_9288.jpeg 在场（用户上传源）", os.path.exists("IMG_9288.jpeg"))'
new_e = ('check("E", "根目录 IMG_9288.jpeg 已退场（用户 web 端删除，3ae087cd；Task228 重锚）",\n'
         '      not os.path.exists("IMG_9288.jpeg"))')
if old_e in s:
    s = s.replace(old_e, new_e)
    wr(p, s)
    print("verify_task193: E re-anchored presence -> absence")
elif new_e in s:
    print("verify_task193: E already re-anchored")
else:
    problems.append("verify_task193 E pattern not found")

# --- 5. stale 2606 sweep ---
p134_label_old = "（Task222 重锚：2606 = Task212 基线 2520 + Task222 45 + Task223 41）"
p134_label_new = "（Task228 重锚：2715 = 2520 + T222 45 + T223 41 + T224 69 + T225 21 + T226 12 + T227 7）"
for p in ("scripts/verify_task134.py", "scripts/verify_task143.py",
          "scripts/verify_task168.py", "scripts/verify_task170.py",
          "scripts/verify_task174.py", "scripts/verify_task175.py",
          "scripts/verify_task180.py"):
    s = rd(p)
    if "2606" not in s:
        print(f"{p}: no 2606 (already swept?), skip")
        continue
    if p.endswith("verify_task134.py") and p134_label_old in s:
        s = s.replace(p134_label_old, p134_label_new)
    n = s.count("2606")
    s = s.replace("2606", "2715")
    wr(p, s)
    print(f"{p}: swept {n} occurrence(s) 2606 -> 2715")

print("PROBLEMS:", problems if problems else "none")
