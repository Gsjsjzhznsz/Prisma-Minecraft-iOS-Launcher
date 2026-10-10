#!/usr/bin/env python3
# task240_syntax_gate.py -- Task240 括号平衡门（沿 task139 结构门同款算法）。
# 覆盖本轮全部触碰文件；跳过反斜杠宏续行；剥离字符串/注释后核对的
# 是 ()/[]/{} 三对平衡。输出 "all balanced" 即通过。
import os, sys

REPO = "/home/z/my-project/repo-prisma"

FILES = [
    "Natives/AmeNativeMenu.m",
    "Natives/AmeNativeMenu.h",
    "Natives/AccountListViewController.m",
    "Natives/LauncherRightPanelViewController.m",
    "Natives/PLLogOutputView.m",
    "Natives/DataTransferService.m",
    "Natives/MultiplayerViewController.m",
    "Natives/DownloadTasksViewController.m",
    "Natives/ModpackExportViewController.m",
    "Natives/ModpackImportViewController.m",
    "Natives/DownloadViewController.m",
    "Natives/HomeCustomizeViewController.m",
    "Natives/BackgroundSettingsViewController.m",
    "Natives/ProfileSettingsViewController.m",
    "Natives/SurfaceViewController+Navigation.m",
    "Natives/ThirdPartyLoginViewController.m",
    "Natives/TouchControllerPreferencesViewController.m",
    "Natives/WelcomeViewController.m",
    "Natives/ControlRepoViewController.m",
    "Natives/BingWallpaperGalleryViewController.m",
    "Natives/LauncherPrefManageJREViewController.m",
    "Natives/PLPrefTableViewController.m",
]

def strip_strings_comments(text):
    out, i, n, mode = [], 0, len(text), 0
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if mode == 0:
            if c == '"':
                mode = 1
            elif c == "'":
                mode = 2
            elif c == "/" and nxt == "/":
                mode = 3
            elif c == "/" and nxt == "*":
                mode = 4
            else:
                out.append(c)
        elif mode == 1:
            if c == "\\":
                i += 1
            elif c == '"':
                mode = 0
        elif mode == 2:
            if c == "\\":
                i += 1
            elif c == "'":
                mode = 0
        elif mode == 3:
            if c == "\n":
                mode = 0
                out.append(c)
        elif mode == 4:
            if c == "*" and nxt == "/":
                mode = 0
                i += 1
        i += 1
    return "".join(out)

PAIRS = {")": "(", "]": "[", "}": "{"}
fail = 0
for rel in FILES:
    path = os.path.join(REPO, rel)
    if not os.path.exists(path):
        print(f"MISSING {rel}")
        fail += 1
        continue
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    # 跳过反斜杠宏续行（task139 同款规则）
    cleaned_lines = [ln for ln in strip_strings_comments(text).split("\n") if not ln.rstrip().endswith("\\")]
    code = "\n".join(cleaned_lines)
    stack = []
    ok = True
    for ch in code:
        if ch in "([{":
            stack.append(ch)
        elif ch in ")]}":
            if not stack or stack[-1] != PAIRS[ch]:
                ok = False
                break
            stack.pop()
    if ok and not stack:
        print(f"OK       {rel}")
    else:
        print(f"UNBALANCED {rel} (leftover={len(stack)})")
        fail += 1

# 引用完整性：退役方法零【代码】残留引用（注释行豁免；currentMenu 属
# 其他文件自有的独立实现，不在退役清单内）
import subprocess
dead_out = subprocess.run(
    ["grep", "-rn", "ame227_presentGlassMenu\\|ame227_glassMenuAction\\|ame227_glassMenuDimTapped",
     "Natives/", "--include=*.m", "--include=*.h"],
    capture_output=True, text=True).stdout.strip()
dead = []
for l in dead_out.splitlines():
    if "/external/" in l:
        continue
    code_part = l.split(":", 2)[2] if l.count(":") >= 2 else l
    if code_part.strip().startswith("//") or code_part.strip().startswith("*"):
        continue  # 墓碑注释豁免
    dead.append(l)
if dead:
    print(f"DEAD-REF REMAIN:\n" + "\n".join(dead))
    fail += 1
else:
    print("OK       retired-method code refs = 0")

os.chdir(REPO)
callers = subprocess.run(
    ["bash", "-c",
     "grep -rln 'AmeNativeMenu ' Natives/*.m | while read f; do grep -q '#import \"AmeNativeMenu.h\"' \"$f\" || echo \"NO-IMPORT $f\"; done"])
print("all balanced" if fail == 0 else f"FAILURES: {fail}")
sys.exit(1 if fail else 0)
