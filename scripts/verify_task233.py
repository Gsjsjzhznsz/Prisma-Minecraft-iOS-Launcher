#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task 233 verification: 5-item correction round on the Task232 build (9137a8f5).

Round items (user message 2026-10-09):
  1. 常用操作键 drawer (item-1 correction): z-order yield + visibility
     single source of truth + overlap forensics
  3. MGL probabilistic enter-world freeze (item-3 correction): Task232 steer
     retired + 25s render-stall watchdog
  *.  分享控件到 GitHub 打不开网页: URL encode + clipboard + length cap
  *.  字体双层/重叠不上/偏黑: paragraph-style copies + opaque backing
  *.  欢迎界面圆圈焦点介绍 (4th report): class-based anchor discovery +
     deep launch-button search + real-frame semantic anchors + card hardening
"""
import sys, os, re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

PASS, FAIL = 0, 0
def check(name, path, needle):
    global PASS, FAIL
    try:
        with open(path, encoding="utf-8") as f:
            body = f.read()
        if needle in body:
            PASS += 1
            print(f"  ok   {name}")
        else:
            FAIL += 1
            print(f"  FAIL {name}: needle not in {path}")
    except Exception as e:
        FAIL += 1
        print(f"  FAIL {name}: {e}")

def check_absent(name, path, needle):
    global PASS, FAIL
    try:
        with open(path, encoding="utf-8") as f:
            body = f.read()
        if needle in body:
            FAIL += 1
            print(f"  FAIL {name}: forbidden needle STILL in {path}")
        else:
            PASS += 1
            print(f"  ok   {name}")
    except Exception as e:
        FAIL += 1
        print(f"  FAIL {name}: {e}")

svc = "Natives/SurfaceViewController.m"
ccu = "Natives/customcontrols/CustomControlsUtils.m"
jl  = "Natives/JavaLauncher.m"
crv = "Natives/ControlRepoViewController.m"
bm  = "Natives/BackgroundManager.m"
wvc = "Natives/WelcomeViewController.m"
cmk = "Natives/Ame223CoachMarksView.m"

print("== (1) 常用操作键 drawer: z-order + visibility + forensics ==")
check("233-1a sub-buttons z-order move", ccu, "drawer sub-buttons moved below interactive main buttons")
check("233-1b order-preserving insert (above prev)", ccu, "insertSubview:ame233_v aboveSubview:ame233_prev")
check("233-1c decorative wrapper exposed", "Natives/customcontrols/CustomControlsUtils.h", "ame233_viewIsDecorativeControlButton")
check("233-1d wrapper single-source impl", ccu, "BOOL ame233_viewIsDecorativeControlButton(UIView *view)")
check("233-1e drawer restore respects own hidden", "Natives/customcontrols/ControlDrawer.m", "button.hidden = self.hidden || !self.areButtonsVisible")
check("233-1f sub-button visibility single source", svc, "ame233_drawer == nil || ame233_drawer.hidden ||")
check("233-1g overlap forensics", svc, "Task233 drawer-key overlaps main control")
check_absent("233-1h no crude decorative copy in SVC", svc, "ame83b_is_decorative_button")

print("== (3) MGL probabilistic freeze: steer retired + stall watchdog ==")
check("233-3a steer retired marker", jl, "Task232 steer 退役")
check_absent("233-3b steer code gone", jl, "steering to tinygl4angle")
check_absent("233-3c ame232_major var gone", jl, "ame232_major >= 26")
check("233-3d watchdog installed", svc, "Task233 RENDER STALL: swapOK frozen at %lu for ~25s")
check("233-3e per-session state (assoc object)", svc, "ame233_stallKey")
check("233-3f saw-live guard against slow second launch", svc, '@"sawLive": @NO')

print("== (4) share-to-GitHub webpage ==")
check("233-4a clipboard-first", crv, "submission JSON (%lu bytes) copied to clipboard")
check("233-4b id encoded with safe whitelist (Task234 重锚：id 不再进 URL——零查询参数终案)", crv, "stringWithFormat:localize(@\"ame230.repo.upload.github_hint\", nil), ame230_id")
check_absent("233-4c value length cap retired (Task234：value= 大载荷预填是 GitHub 500 错误页的触发面，整体退役)", crv, "<= 6000")
check("233-4d openURL completion handler", crv, "Task233 GitHub openURL success=%d (urlLen=%lu)")
check("233-4e failure toast", crv, 'localize(@"ame233.repo.open_fail", nil)')
check_absent("233-4f raw id interpolation gone", crv, "community%%2F%@.json&value=%@\",\n            kTask189RepoOwner, kTask189RepoName, kTask189RepoRef, ame230_id,")

print("== (5) font double-layer / misalignment / dark tint ==")
check("233-5a paragraph style replication", bm, "ame233_ps.alignment = ame232_label.textAlignment")
check("233-5b single-line truncation parity", bm, "ame233_ps.lineBreakMode = NSLineBreakByTruncatingTail")
check("233-5c opaque backing copy", bm, "ame233_opaqueColor(ame232_label.textColor)")
check("233-5d opaque helper", bm, "static UIColor *ame233_opaqueColor(UIColor *ame233_c)")
check("233-5e four offsets preserved (Task234 重锚：拷贝画进 textRectForBounds 文本矩形)", bm, "CGRectOffset(ame234_textRect,  0.6f,  0.0f)")

print("== (6) welcome circle focus intro (4th round) ==")
check("233-6a class-based anchor discovery", wvc, "Task233 anchor discovery: menu=%d content=%d right=%d")
check("233-6b menu VC by class", wvc, "isKindOfClass:[LauncherMenuViewController class]")
check("233-6c right panel VC by class", wvc, "isKindOfClass:[LauncherRightPanelViewController class]")
check("233-6d deep launch-button search", wvc, "ame233_visited < 600")
check("233-6e semantic anchor from real menu frame", wvc, "CGRectGetHeight(mr) * 0.48")
check("233-6f semantic anchor from real content frame", wvc, "CGRectGetHeight(cr) * 0.42")
check_absent("233-6g hardcoded screen-fraction rects gone", wvc, "sb.size.height * 0.55")
check("233-6h anchor log with real-view note", wvc, "all real-view derived")
check("233-6i card elevated background", cmk, "secondarySystemGroupedBackgroundColor")
check("233-6j labels always visible (no alpha anim)", cmk, "_ame224_titleLabel.alpha = 1.0")
check("233-6k per-page bring-to-front", cmk, "bringSubviewToFront:_ame224_card")
check("233-6l card frame sanity + fallback", cmk, "card frame abnormal after layout")
check("233-6m transform reset per page", cmk, "_ame224_card.transform = CGAffineTransformIdentity;")

print("== (7) i18n keys x5 tables ==")
hint_needle = {"en": "clipboard", "zh-Hans": "剪贴板", "zh-Hant": "剪貼簿", "zh-CN": "剪贴板", "ja": "クリップボード"}
for lang in ["en", "zh-Hans", "zh-Hant", "zh-CN", "ja"]:
    p = f"Natives/resources/{lang}.lproj/Localizable.strings"
    check(f"233-7 stall.toast @{lang}", p, '"ame233.stall.toast"')
    check(f"233-7 repo.open_fail @{lang}", p, '"ame233.repo.open_fail"')
    check(f"233-7 github_hint revised @{lang}", p, hint_needle[lang])

print()
print(f"verify_task233: {PASS} ok, {FAIL} fail")
sys.exit(0 if FAIL == 0 else 1)
