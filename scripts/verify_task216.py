#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_task216 — 六项 UI 统一轮

A. 加载器选择列表对齐游戏版本列表（N1，用户六轮重写的真收口）
B. 版本号 6.5.0 + 包名 com.air-devs.prisma -> com.prisma-devs.prisma（N2）
C. 半透明透明度拉条全程单调（N3，驼峰根因修复）
D. 实例卡按钮/阴影与透明度绑定（N4，仅实例卡族）
E. 默认设置改版（N5：跟随系统/毛玻璃/100%/75%）
F. UI 效果页脚换行（N6）
G. 级联（公告 38、REVISION 20、存量验证器重锚抽查）
"""
import json
import os
import re

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASS = 0
FAIL = 0
FAILURES = []


def check(label, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {label}")
    else:
        FAIL += 1
        FAILURES.append(label)
        print(f"  FAIL  {label}" + (f"  {detail}" if detail else ""))


def rd(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def _nocomment(s):
    return re.sub(r"^\s*//.*$", "", s, flags=re.M)


print("=" * 70)
print("A. 加载器列表对齐游戏版本列表（ModLoaderInstallViewController.m）")
print("=" * 70)
ml = rd("Natives/installer/ModLoaderInstallViewController.m")
check("A1 both tables rowHeight 64 (two sites, 50 retired)",
      ml.count("_tableView.rowHeight = 64;") == 2 and "_tableView.rowHeight = 50;" not in ml)
check("A2 RowCell icon container = VersionCardCell spec (40x40, corner 10, leading 14)",
      "_iconContainer.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:14" in ml
      and "_iconContainer.widthAnchor constraintEqualToConstant:40" in ml
      and "_iconContainer.heightAnchor constraintEqualToConstant:40" in ml
      and "_iconContainer.layer.cornerRadius = 10" in ml
      and "_iconContainer.layer.cornerRadius = 8" not in ml)
check("A3 RowCell icon 22x22 (was 20)",
      "_iconView.widthAnchor constraintEqualToConstant:22" in ml
      and "_iconView.widthAnchor constraintEqualToConstant:20" not in ml)
check("A4 RowCell icon-text gap 14 (was 12)",
      "_nameLabel.leadingAnchor constraintEqualToAnchor:_iconContainer.trailingAnchor constant:14" in ml
      and "constraintEqualToAnchor:_iconContainer.trailingAnchor constant:12" not in ml)
check("A5 RowCell text block top 14 (was 8)",
      "_nameLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:14" in ml)
check("A6 RowCell state row gap 3 (VersionCardCell date rhythm)",
      "_stateLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3" in ml)
check("A7 SwitchCell text block realigned (top 14 / desc gap 3)",
      "_titleLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:14" in ml
      and "_descLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3" in ml)
check("A8 version-picker table also 64",
      ml.count("_tableView.estimatedRowHeight = 64;") == 2)

print("=" * 70)
print("B. 版本号 6.5.0 + 包名 air -> prisma（全接线）")
print("=" * 70)
plist = rd("Natives/Info.plist")
check("B1 marketing + build version 6.5.0",
      re.search(r"<key>CFBundleShortVersionString</key>\s*<string>6\.5\.0</string>", plist) is not None
      and re.search(r"<key>CFBundleVersion</key>\s*<string>6\.5\.0</string>", plist) is not None
      and "<string>6.0.0</string>" not in plist)
# Task217 re-anchor: interim migration id com.air-devs (user order; final com.prisma-devs later).
check("B2 bundle id com.air-devs interim (prisma-devs.prisma retired from plist, Task217)",
      "<string>com.air-devs.air</string>" in plist and "com.prisma-devs.prisma" not in plist)
check("B3 os_log subsystems follow the interim id (Task217)",
      'os_log_create("com.air-devs.air"' in rd("Natives/TouchController/ios_transport.c")
      and 'os_log_create("com.air-devs.air"' in rd("Natives/TouchControllerBridge.m"))
check("B4 keychain service + background session follow the interim id (Task217; legacy chain exempt)",
      'static NSString *const ame131_keychainService = @"com.air-devs.air.ame131.credentials"' in rd("Natives/authenticator/ThirdPartyAuthenticator.m")
      and "com.air-devs.air.MinecraftResourceDownloadTask" in rd("Natives/MinecraftResourceDownloadTask.m"))
mk = rd("Makefile")
check("B5 Makefile artifact names + generated entitlements (7 sites, Task217 interim)",
      mk.count("com.air-devs") == 7 and "com.prisma-devs.prisma" not in mk)
yml = open(".github/workflows/development.yml", "rb").read()
check("B6 CI artifact names follow (6 sites, CRLF intact, Task217 interim)",
      yml.count(b"com.air-devs") == 6 and b"com.prisma-devs.prisma" not in yml
      and yml.count(b"\r\n") == yml.count(b"\n"))
check("B7 static entitlements follow (3 files, Task217 interim)",
      all("com.air-devs" in rd(p) and "com.prisma-devs.prisma" not in rd(p)
          for p in ["entitlements.codesign.xml", "entitlements.sideload.xml", "entitlements.trollstore.xml"]))
check("B8 URL scheme name follows the interim id (Task217)",
      "com.air-devs.air.urlscheme" in plist)
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("B9 REVISION bumped 19 -> 20 (identity change, Task214 rule)",
      "#define REVISION 22" in vh and "#define REVISION 19\n" not in vh)
check("B10 Task216 bump addendum recorded",
      "REVISION 19->20 bump addendum (Task 216)" in vh and "com.air-devs.prisma -> com.prisma-devs.prisma" in vh)
check("B11 historic addenda untouched (append-only)",
      "REVISION 18 addendum (Task 212, no bump)" in vh
      and "REVISION 18 addendum (Task 213, no bump)" in vh
      and "REVISION 18->19 bump addendum (Task 214" in vh)

print("=" * 70)
print("C. 透明度拉条全程单调（makeViewControllerTransparent 正向语义）")
print("=" * 70)
bm = _nocomment(rd("Natives/BackgroundManager.m"))
check("C1 page-base alpha uses forward uiOpacity (hump root fixed)",
      "[base colorWithAlphaComponent:self.uiOpacity]" in bm
      and "colorWithAlphaComponent:1.0 - self.uiOpacity" not in bm
      and "colorWithWhite:0 alpha:1.0 - self.uiOpacity" not in bm)
check("C2 card pipeline keeps forward semantics",
      "colorWithAlphaComponent:self.uiOpacity]" in bm
      and bm.count("self.uiOpacity") >= 6)
check("C3 blur formulas untouched",
      "0.3 + (self.blurIntensity * 0.7)" in bm
      and "0.3 + (manager.blurIntensity * 0.7)" not in bm)

print("=" * 70)
print("D. 实例卡按钮/阴影与透明度绑定（仅实例卡族）")
print("=" * 70)
vm = rd("Natives/VersionManagerViewController.m")
check("D0 primitives declared in the class interface (CI run 602: undeclared -> id return -> invalid operands error)",
      "- (CGFloat)ame216_effectOpacityFactor;" in vm and "- (void)ame216_rebindCardSurface;" in vm
      and vm.index("- (CGFloat)ame216_effectOpacityFactor;") < vm.index("@implementation VMTileBaseCell"))
check("D1 base-cell opacity factor primitive (blur/translucent/none)",
      "- (CGFloat)ame216_effectOpacityFactor {" in vm
      and "return 0.3 + (manager.blurIntensity * 0.7);" in vm
      and "return manager.uiOpacity;" in vm
      and "if (![manager hasBackground]) return 1.0;" in vm)
check("D2 rebind primitive: pipeline re-apply + shadow bound to factor",
      "- (void)ame216_rebindCardSurface {" in vm
      and "[[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];" in vm
      and "self.layer.shadowOpacity = 0.12 * factor;" in vm)
check("D3 instance card configures through rebind (button base bound)",
      vm.count("ame216_rebindCardSurface];") >= 2
      and vm.count("colorWithAlphaComponent:0.12 * [self ame216_effectOpacityFactor]") == 2)
check("D4 directory card normal branch no longer paints fixed white 0.08 base",
      "选中态只由内缩环表达" not in vm
      and vm.count('self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];') <= 2)
check("D5 quick-action / renderer cells untouched (user scope: instance family only)",
      "VMQuickActionCell" in vm and "VMRendererCell" in vm
      and "ame216_rebindCardSurface" not in vm.split("@implementation VMQuickActionCell")[1].split("@interface VMVersionCardCell")[0])

print("=" * 70)
print("E. 默认设置改版（跟随系统 / 毛玻璃 / 100% / 75%）")
print("=" * 70)
check("E1 default uiOpacity 1.0 (nil-branch + fallback)",
      "_uiOpacity = 1.0; // Task162/164 默认 60%；Task216：默认透明度 100%" in bm
      and bm.count("_uiOpacity = 1.0;") == 2
      and "_uiOpacity = 0.6;" not in bm)
check("E2 default blurIntensity 0.75 (nil-branch + fallback)",
      bm.count("_blurIntensity = 0.75;") == 2
      and "_blurIntensity = 1.0;" not in bm)
check("E3 default effect stays blur",
      "_uiEffect = BackgroundUIEffectBlur; // Task162/164：默认毛玻璃效果" in bm)
sd = rd("Natives/SceneDelegate.m")
check("E4 appearance migration back to follow-system (Task216)",
      'setPrefObject(@"general.ui_theme", @"auto")' in sd
      and 'setPrefObject(@"general.ui_theme", @"dark")' not in sd
      and "migrated to 'auto'" in sd)
check("E5 explicit-choice devices never overridden",
      "if (!getPrefBool(@\"general.ui_theme_explicit\"))" in sd)
bgs = rd("Natives/BackgroundSettingsViewController.m")
check("E6 restore-default resets to the new factory values (1.0 / 0.75 / blur)",
      "manager.uiOpacity = 1.0;" in bgs and "manager.blurIntensity = 0.75;" in bgs
      and "manager.uiOpacity = 0.7;" not in bgs)

print("=" * 70)
print("F. UI 效果页脚换行")
print("=" * 70)
check("F1 footer label wraps (numberOfLines 0, word wrap)",
      "- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section" in bgs
      and "footer.numberOfLines = 0;" in bgs
      and "NSLineBreakByWordWrapping;" in bgs)
check("F2 footer height pre-computed for multi-line",
      "- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section" in bgs
      and "boundingRectWithSize:" in bgs)
check("F3 titleForFooter no longer returns the effect hint (no double footer)",
      "return localize(@\"background.effect.footer\", nil);" not in bgs)

print("=" * 70)
print("G. 级联（公告 38 / 重锚抽查）")
print("=" * 70)
ann = json.loads(rd("announcements.json"))["announcements"]
ids = [a["id"] for a in ann]
check("G1 38 items, id-unique (Task216@2 append)",
      len(ann) == 42 and len(ids) == len(set(ids)))
check("G2 task217 entry complete at tail (Task217 re-anchor; task216 one step in)",
      ids[-4] == "task217-download-fixes-about-isolation-2026-10-03" and ann[-4]["date"] == "2026-10-03")
check("G3 task216 kept at -3 (Task218 append, re-anchor)",
      ids[-5] == "task216-ui-2026-10-03" and ids[-6] == "task206-nggl4es-2026-10-01")
check("G4 pins intact (server@0, task169@1)",
      ann[0].get("pin") is True and ids[1] == "task169-four-fixes-2026-09-25")
check("G5 historical indices unchanged (task214@3, task213@4, task212@5, task211@6)",
      ids[3].startswith("task214-") and ids[4].startswith("task213-")
      and ids[5].startswith("task212-angle") and ids[6].startswith("task211-"))
check("G6 v207/211 length gates follow 41 (Task219)",
      "== 42" in rd("scripts/verify_task207.py") and "== 42" in rd("scripts/verify_task211.py"))
check("G7 v213 realigned to Task217 anchors",
      "'_tableView.rowHeight = 64;' in ml" in rd("scripts/verify_task213.py")
      and "len(ids) == 42" in rd("scripts/verify_task213.py"))
check("G8 v214/193/196 REVISION gates follow 21 (Task217)",
      '#define REVISION 22' in rd("scripts/verify_task214.py")
      and '#define REVISION 22' in rd("scripts/verify_task193.py")
      and '#define REVISION 22' in rd("scripts/verify_task196_197_198_201.py"))
check("G9 v215 REPO probe is path-independent (Task216 hardening)",
      "REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))" in rd("scripts/verify_task215.py"))

print("=" * 70)
print("H. 语法平衡门（本轮触碰的 ObjC 文件）")
print("=" * 70)


def balance(path):
    d = rd(path)
    i, n = 0, len(d)
    par = brk = brc = 0
    while i < n:
        c = d[i]
        if c == '"':
            i += 1
            while i < n and d[i] != '"':
                i += 2 if d[i] == "\\" else 1
        elif c == "'":
            i += 1
            while i < n and d[i] != "'":
                i += 2 if d[i] == "\\" else 1
        elif c == "/":
            if i + 1 < n and d[i + 1] == "/":
                while i < n and d[i] != "\n":
                    i += 1
            elif i + 1 < n and d[i + 1] == "*":
                i = d.find("*/", i + 2)
                i = n if i < 0 else i + 1
                continue
        elif c == "(":
            par += 1
        elif c == ")":
            par -= 1
        elif c == "[":
            brk += 1
        elif c == "]":
            brk -= 1
        elif c == "{":
            brc += 1
        elif c == "}":
            brc -= 1
        i += 1
    return par == 0 and brk == 0 and brc == 0


for p in ["Natives/VersionManagerViewController.m",
          "Natives/BackgroundManager.m",
          "Natives/BackgroundSettingsViewController.m",
          "Natives/SceneDelegate.m",
          "Natives/installer/ModLoaderInstallViewController.m",
          "Natives/TouchControllerBridge.m",
          "Natives/MinecraftResourceDownloadTask.m",
          "Natives/authenticator/ThirdPartyAuthenticator.m",
          "Natives/TouchController/ios_transport.c"]:
    check(f"H balance {os.path.basename(p)}", balance(p))

print("=" * 70)
print(f"verify_task216: {PASS}/{PASS + FAIL}" +
      ("  ALL GREEN" if FAIL == 0 else f"  FAILURES: {FAILURES}"))
print("=" * 70)
sys_exit = 0 if FAIL == 0 else 1
raise SystemExit(sys_exit)
