#!/usr/bin/env python3
# Task240 import sweep: 确保所有换装文件都 import AmeNativeMenu.h
import re, sys

FILES = [
    "Natives/SurfaceViewController+Navigation.m",
    "Natives/ThirdPartyLoginViewController.m",
    "Natives/TouchControllerPreferencesViewController.m",
    "Natives/WelcomeViewController.m",
    "Natives/ControlRepoViewController.m",
    "Natives/BingWallpaperGalleryViewController.m",
    "Natives/LauncherPrefManageJREViewController.m",
    "Natives/PLPrefTableViewController.m",
]

IMP = '#import "AmeNativeMenu.h"       // ★ Task240：菜单全面系统原生 UIMenu 化\n'

for path in FILES:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
    if any("AmeNativeMenu.h" in ln for ln in lines):
        print(f"SKIP {path} (already imported)")
        continue
    # 找到第一个 #import 行，在其后插入
    insert_at = None
    for i, ln in enumerate(lines):
        if ln.startswith("#import"):
            insert_at = i + 1
            break
    if insert_at is None:
        print(f"FAIL {path}: no #import line found")
        sys.exit(1)
    lines.insert(insert_at, IMP)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(lines)
    print(f"OK   {path} (inserted after line {insert_at})")

# JRE: 退役 currentMenu 属性（UIMenu 双轨呈现已统一到 AmeNativeMenu）
jre = "Natives/LauncherPrefManageJREViewController.m"
with open(jre, "r", encoding="utf-8") as f:
    src = f.read()
new_src = src.replace("@property(nonatomic) UIMenu* currentMenu;\n", "")
if new_src != src:
    with open(jre, "w", encoding="utf-8") as f:
        f.write(new_src)
    print(f"OK   {jre} (currentMenu property retired)")
else:
    print(f"WARN {jre}: currentMenu property not found (check manually)")
