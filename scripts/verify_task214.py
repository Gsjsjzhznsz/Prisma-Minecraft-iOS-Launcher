#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_task214.py -- Task 214 five-fix round on the Task213 Prisma build.

R1 memory-limit dialog: mem_help.button l10n key was missing from ALL six
   languages -> button rendered as the raw key name. Key added everywhere.
R2 add-directory card: green 1pt border retired (plus icon + 0.08 tint kept).
R3 shortcut-family cards (instance + game-directory): corner radius 12 -> 16.
R4 THE selection bug: selection ring (plain UIView, higher sibling order than
   the buttons) swallowed all touches on a selected card -- buttons now get
   userInteractionEnabled=NO passthrough on both cells.
R5 game-menu overlay stats label: shrink-to-fit instead of tail ellipsis.
F. version.h REVISION 18 -> 19 (rebrand-round bump the user ordered, paid here).
G. announcement task214@2 (35 -> 36), pins and tail anchors intact.
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # Task217: script-relative (sandbox moved)
os.chdir(REPO)

PASSED = []
FAILED = []

def check(name, cond, detail=""):
    if cond:
        PASSED.append(name)
        print(f"  PASS {name}")
    else:
        FAILED.append(name)
        print(f"  FAIL {name}  {detail}")

def rd(p):
    with open(os.path.join(REPO, p), encoding="utf-8") as f:
        return f.read()

print("== A. R1 mem_help.button six-language key ==")
vm_m = rd("Natives/LauncherPreferencesViewController.m")
check("A1 alert uses mem_help.button key",
      'localize(@"mem_help.button", @"付费开发者证书")' in vm_m)
check("A1b button opens b23.tv/WtgrPJM",
      "https://b23.tv/WtgrPJM" in vm_m)
EXPECT = {
    "en":      "Paid Developer Certificate",
    "zh-CN":   "付费开发者证书",
    "zh-Hans": "付费开发者证书",
    "zh-Hant": "付費開發者證書",
    "ja":      "有料開発者証明書",
    "km":      "Paid Developer Certificate",
}
for lg, val in EXPECT.items():
    s = rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
    check(f"A2 {lg} mem_help.button = {val}",
          f'"mem_help.button" = "{val}";' in s)
# key set consistency: six languages each +1 -> identical key sets
def keyset(lg):
    return set(re.findall(r'^"([^"]+)"\s*=', rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), re.M))
k4 = [keyset(l) for l in ("en", "zh-Hans", "zh-CN", "zh-Hant")]
check("A3 four-main-language key sets identical (each 2520 after +1)",
      k4[0] == k4[1] == k4[2] == k4[3] and len(k4[0]) == 2715,
      f"counts={[len(k) for k in k4]}")
check("A3b ja/km also carry mem_help.button",
      "mem_help.button" in keyset("ja") and "mem_help.button" in keyset("km"))

print("== B. R2 add-directory card green border retired ==")
vmm = rd("Natives/VersionManagerViewController.m")
seg_dir = vmm.split("@implementation VMGameDirCell")[1].split("#pragma mark - Renderer Card Cell")[0]
check("B1 green 0.6 border retired from add-card branch",
      "systemGreenColor] colorWithAlphaComponent:0.6]" not in seg_dir)
check("B2 add-card branch restores default 0.5pt border",
      seg_dir.count('[[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor') >= 2
      and "layer.borderWidth = 0.5" in seg_dir.split("if (isAddButton)")[1][:900])
check("B3 green plus icon + green 0.08 tint kept",
      '[UIImage systemImageNamed:@"plus"]' in seg_dir
      and "systemGreenColor] colorWithAlphaComponent:0.08]" in seg_dir)
check("B4 class-header comment records the retirement",
      "绿色 1pt 描边随" in vmm and "删除添加目录卡片的绿色边框" in vmm)

print("== C. R3 corner radius 12 -> 16 (shortcut-family only) ==")
check("C1 kVMCardCornerRadius constant = 16.0",
      "static const CGFloat kVMCardCornerRadius = 16.0;" in vmm)
base = vmm.split("@implementation VMTileBaseCell")[1].split("#pragma mark - Version Card Cell")[0]
check("C2 base cell property + default 12",
      "@property (nonatomic, assign) CGFloat cardCornerRadius;" in vmm
      and "self.cardCornerRadius = 12.0;" in base)
check("C3 base setupViews/shadowPath use the property",
      "self.contentContainer.layer.cornerRadius = self.cardCornerRadius;" in base
      and "cornerRadius:self.cardCornerRadius].CGPath" in base)
seg_ver = vmm.split("@implementation VMVersionCardCell")[1].split("@implementation VMGameDirCell")[0]
check("C4 both shortcut-family cells override to 16",
      seg_ver.count("self.cardCornerRadius = kVMCardCornerRadius;") == 1
      and seg_dir.count("self.cardCornerRadius = kVMCardCornerRadius;") == 1)
check("C5 both rings follow kVMCardCornerRadius - inset/3",
      vmm.count("kVMCardCornerRadius - (kVMCardEllipsisInset / 3.0)") == 2)
check("C6 renderer cell does NOT override (stays 12)",
      "self.cardCornerRadius = kVMCardCornerRadius" not in
      vmm.split("@implementation VMRendererCell")[1])

print("== D. R4 selection-ring hitTest passthrough (THE selection bug) ==")
check("D1 instance-cell ring userInteractionEnabled = NO",
      "self.selectionRing.userInteractionEnabled = NO;" in seg_ver)
check("D2 dir-cell ring userInteractionEnabled = NO",
      "self.selectionRing.userInteractionEnabled = NO;" in seg_dir)
check("D3 root-cause note recorded (ring above buttons)",
      "拦截整卡触摸" in vmm and "命中穿透" in vmm)
check("D4 ring is still added after the buttons (fix is passthrough, not reorder)",
      seg_ver.index("addSubview:self.ellipsisButton]") < seg_ver.index("addSubview:self.selectionRing]")
      and seg_dir.index("addSubview:self.deleteButton]") < seg_dir.index("addSubview:self.selectionRing]"))

print("== E. R5 stats label shrink-to-fit ==")
gmo = rd("Natives/GameMenuOverlayView.m")
check("E1 adjustsFontSizeToFitWidth on",
      "self.statsLabel.adjustsFontSizeToFitWidth = YES;" in gmo)
check("E2 minimumScaleFactor 0.5",
      "self.statsLabel.minimumScaleFactor = 0.5;" in gmo)
check("E3 updateFPS format unchanged (FPS + MEM)",
      '@"FPS: %ld | MEM: %.0fMB"' in gmo)
check("E4 initial frame stays 130x24 (shrink, not widen)",
      "CGRectMake(0, 0, 130, 24)" in gmo)

print("== F. version.h REVISION 18 -> 19 ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("F1 #define REVISION 20 (Task216 identity bump: air-devs -> prisma-devs)",
      "#define REVISION 22" in vh and "#define REVISION 19\n" not in vh)
check("F2 Task214 addendum present (bump rationale + five fixes)",
      "REVISION 18->19 bump addendum (Task 214" in vh
      and "mem_help.button l10n key" in vh and "shrink-to-fit" in vh
      and "userInteractionEnabled = NO" in vh)
check("F3 rebrand-bump rationale recorded",
      "rebrand-round bump the user ordered" in vh
      and "com.air-devs.prisma" in vh)
check("F4 trailing SEP = 76 equals",
      re.search(r"\n//\s(={76})\s*$", vh) is not None)
check("F5 Task212/213 addenda untouched",
      "REVISION 18 addendum (Task 212, no bump)" in vh
      and "REVISION 18 addendum (Task 213, no bump)" in vh)

print("== G. announcement task214@2 (36 items) ==")
ann = json.loads(rd("announcements.json"))["announcements"]
ids = [a["id"] for a in ann]
check("G1 38 items, id-unique (Task216@2 append)", len(ann) == 43 and len(ids) == len(set(ids)))
check("G2 task214@3 (Task215@2 insert shifted +1)", ids[3] == "task214-five-fixes-2026-10-02")
check("G3 task213@3 + parallel task212@4 shifted intact",
      ids[4].startswith("task213-") and ids[5].startswith("task212-angle"))
check("G4 pins intact (server@0 pin, task169@1)",
      ann[0].get("pin") is True and ids[1] == "task169-four-fixes-2026-09-25")
check("G5 tail anchors task219 appended, task217 kept at -3",
      ids[-5] == "task217-download-fixes-about-isolation-2026-10-03" and ids[-6] == "task216-ui-2026-10-03")
a214 = ann[3]
check("G6 task214 entry metadata complete",
      a214["date"] == "2026-10-02" and "付费开发者证书" in a214["summary"]
      and "缩小字号" in a214["summary"] and "选中卡片" in a214["title"])
check("G7 five-fix content all present",
      all(k in a214["content"] for k in
          ("mem_help.button", "绿色边框移除", "12pt → 16pt",
           "不参与触摸命中", "缩小字号", "REVISION 18 → 19")))

print("== H. cascade spot-checks (re-anchored verifiers) ==")
def has(p, needle):
    return needle in rd(p)
check("H1 v213 B5 re-anchored to kVMCardCornerRadius ring formula",
      has("scripts/verify_task213.py",
          "vm.count('kVMCardCornerRadius - (kVMCardEllipsisInset / 3.0)') >= 2"))
check("H2 v213 H1/H7/H8 shifted onward (Task219 append)",
      "len(ids) == 43" in rd("scripts/verify_task213.py")
      and "'== 43' in v207 and '== 42' not in v207" in rd("scripts/verify_task213.py"))
check("H3 v165/167 windows lifted to 29/27",
      "range(min(30, len(anns)))" in rd("scripts/verify_task165.py")
      and "range(min(28, len(anns)))" in rd("scripts/verify_task167.py"))
check("H4 v193 N-gate follows REVISION 20 (Task216 bump)",
      "#define REVISION 22" in rd("scripts/verify_task193.py"))
check("H5 v207 D-gate accepts corner-radius preamble before super",
      "self\\.cardCornerRadius = kVMCardCornerRadius" in rd("scripts/verify_task207.py"))
check("H6 v190/180 AccountList pairing semantics (Task213 hotfix re-anchor)",
      "not uses_engine_symbols(ac) or '#import \"UIKit+NativeSurface.h\"' in ac" in rd("scripts/verify_task190.py")
      and "'#import \"UIKit+NativeSurface.h\"' in ac" in rd("scripts/verify_task180.py"))
check("H7 v172 G2 retry-count 3 -> 4 (Task212 CF hardening backfill)",
      "cf.count(\"ame172_retrySearchRequest:request\") == 4" in rd("scripts/verify_task172.py"))
check("H8 v170 F1 re-anchored to true positions (179@14..168@24)",
      'anns[15]["id"] == "task179-eight-fixes-2026-09-26"' in rd("scripts/verify_task170.py")
      and 'anns[25]["id"] == "task168-neumorph-faq-json-2026-09-25"' in rd("scripts/verify_task170.py"))
check("H9 l10n 2715 family swept (spot: 129/133/151/206)",
      all("2715" in rd(f) for f in
          ("scripts/verify_task129.py", "scripts/verify_task133.py",
           "scripts/verify_task151.py", "scripts/verify_task206.py")))
check("H10 no stale == 35 announcement counters",
      all("len(ann) == 35" not in rd(f) for f in
          ("scripts/verify_task202.py", "scripts/verify_task203.py",
           "scripts/verify_task206.py", "scripts/verify_task207.py",
           "scripts/verify_task210.py", "scripts/verify_task211.py",
           "scripts/verify_task212.py")))

print("== I. bracket balance (touched .m files) ==")
def balanced(p):
    s = rd(p)
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
    s = re.sub(r"//.*", "", s)
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return s.count("{") == s.count("}") and s.count("(") == s.count(")") and s.count("[") == s.count("]")
check("I1 VersionManagerViewController.m balanced", balanced("Natives/VersionManagerViewController.m"))
check("I2 GameMenuOverlayView.m balanced", balanced("Natives/GameMenuOverlayView.m"))
check("I3 LauncherPreferencesViewController.m untouched this round (baseline sanity)",
      "mem_help.button" in vm_m)

print(f"\n{'=' * 40}\nverify_task214: {len(PASSED)} passed, {len(FAILED)} failed")
if FAILED:
    for f in FAILED:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("ALL GREEN -- Task 214")
