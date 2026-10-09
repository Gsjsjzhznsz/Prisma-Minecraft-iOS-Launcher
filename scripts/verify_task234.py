#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task 234 verification: 5-item round on the Task233 build (c07243ed).

Round items (user message 2026-10-10):
  1. 欢迎圈圈本来要圈启动按钮变成了执行jar —— 启动按钮锚点误中执行Jar
     (Task233 深搜"最靠下大按钮"：执行Jar/选择版本 38pt 贴底恰在启动按钮
     46pt 之下)。修复:右面板 VC 直取 launchButton 真身 + 三级确定性锚定。
  2. 还有文字依旧不显示(第五轮) —— coach 卡 body 标签自 Task223 起漏
     translatesAutoresizingMaskIntoConstraints=NO：autoresize(零初始帧)与骨架约束
     必需级冲突 → 正文恒 0x0 = "无文字介绍"。标题标签有该行(能显示)。
  3. 还有现在文字重叠依旧有问题 —— drawInRect: 顶部锚定 vs
     drawTextInRect: 经 textRectForBounds 垂直居中，按钮 titleLabel 上
     相差 9~13pt = 深色拷贝浮在白字上方("重叠不上"残留)。拷贝改画进
     textRectForBounds 同一紧致文本矩形。
  4. 还有不是叫你看看modilegl更新吗 —— 已复查(带认证 API):上游
     MobileGL-Dev/MobileGlues 最新提交 97558a6(2026-09-22, 即 0f1e10b
     multidraw grow-only 修复的 merge),之后无新提交/无 release/无 tag;
     vendored 源码树已含该修复(version.h REVISION 18 注记) → 无可用更新。
  5. 分享到 GitHub 显示 "Looks like something went wrong!"(GitHub 通用
     500 错误页) —— filename= 斜杠已知 bug(isaacs/github#1527)+value=
     大载荷渲染 500。零查询参数终案:/new/main/controls/layouts/community
     纯路径目录预导航,内容只走剪贴板,提示语带出应补文件名。
"""
import sys, os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(ROOT)

PASS, FAIL = 0, 0
def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()
def check(name, path, needle):
    global PASS, FAIL
    try:
        ok = needle in read(path)
    except Exception as e:
        ok = False
        needle = f"{e}"
    if ok:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}: needle not in {path}")
def check_absent(name, path, needle):
    global PASS, FAIL
    try:
        present = needle in read(path)
    except Exception as e:
        present = True
        needle = f"{e}"
    if not present:
        PASS += 1
        print(f"  ok   {name}")
    else:
        FAIL += 1
        print(f"  FAIL {name}: forbidden needle STILL in {path}")

rp  = "Natives/LauncherRightPanelViewController.h"
rpm = "Natives/LauncherRightPanelViewController.m"
wvc = "Natives/WelcomeViewController.m"
cmk = "Natives/Ame223CoachMarksView.m"
bm  = "Natives/BackgroundManager.m"
crv = "Natives/ControlRepoViewController.m"
mgv = "Natives/external/MobileGlues/MobileGlues-cpp/version.h"
mgm = "Natives/external/MobileGlues/MobileGlues-cpp/gl/multidraw.cpp"

print("== (1) 启动按钮锚点：真身直取 + 三级确定性锚定 ==")
check("234-1a accessor declared in header", rp, "- (UIView *)ame234_launchAnchorView;")
check("234-1b accessor implemented (view identity)", rpm, "return self.launchButton;")
check("234-1c Welcome tier-1 direct access", wvc, "[ame233_rightVC ame234_launchAnchorView]")
check("234-1d tier-2 three-state launch titles", wvc, "localize(@\"i18n_str_412\", nil),   // 启动游戏")
check("234-1e tier-2 jar exclusion", wvc, 'localize(@"i18n_str_414", nil);   // 执行Jar')
check("234-1f tier-2 version-button exclusion", wvc, 'localize(@"i18n_str_38", nil);    // 选择版本')
check("234-1g tier-3 whole-panel fallback kept", wvc, "ame234_tier = @\"whole-panel\"")
check("234-1h tier forensics log", wvc, "[Welcome] Task234 launch anchor tier=%@ rect=%@")
check_absent("234-1i lowest-button heuristic comment gone", wvc, "取最靠下的大按钮 = 启动")
check_absent("234-1j lowest-button heuristic code gone", wvc, "取最靠下大按钮")

print("== (2) 欢迎圈文字（第五轮）：body 标签约束冲突根修 ==")
check("234-2a body label translate fix", cmk, "_ame224_bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;")
check("234-2b title label translate kept (regression)", cmk, "_ame224_titleLabel.translatesAutoresizingMaskIntoConstraints = NO;")
check("234-2c post-layout frame forensics", cmk, "[CoachMarks] Task234 post-layout: card=%@ title=%@ body=%@")
check("234-2d Task233 card bg kept (regression)", cmk, "secondarySystemGroupedBackgroundColor")
check("234-2e Task233 bring-to-front kept (regression)", cmk, "bringSubviewToFront:_ame224_card")
check("234-2f Task233 frame sanity kept (regression)", cmk, "card frame abnormal after layout")
check("234-2g Task233 transform reset kept (regression)", cmk, "_ame224_card.transform = CGAffineTransformIdentity;")
check("234-2h Task232 per-page forensics prefix kept", cmk, "Task232 page %lu/%lu: spot=%@ titleLen=%lu")

print("== (3) 字体重叠残留：拷贝画进 textRectForBounds 文本矩形 ==")
check("234-3a tight text rect computed", bm, "ame234_textRect = [ame232_label textRectForBounds:rect")
check("234-3b four dark copies into text rect (Task235 重锚：缩字标签改画进 ame235_copyRect，非缩字时与 textRect 同一矩形)", bm, "CGRectOffset(ame235_copyRect,  0.6f,  0.0f)")
check("234-3c backing copy into text rect (Task235 重锚：ame235_copyRect)", bm, "[ame233_backing drawInRect:ame235_copyRect]")
check_absent("234-3d raw-rect copies retired", bm, "drawInRect:CGRectOffset(rect,")
check("234-3e paragraph style retained (233-5a compat)", bm, "ame233_ps.alignment = ame232_label.textAlignment")
check("234-3f opaque backing retained (233-5c compat)", bm, "ame233_opaqueColor(ame232_label.textColor)")
check("234-3g exception net intact", bm, "@catch (NSException *ame232_e)")

print("== (4) MobileGlues 上游复查（无更新：上游 97558a6 后无新提交） ==")
check("234-4a vendored contains upstream tip fix (version.h)", mgv, "Ported upstream 0f1e10b")
check("234-4b vendored contains upstream tip fix (multidraw.cpp)", mgm, "Upstream 0f1e10b (2.0.18 sync)")

print("== (5) 分享 GitHub 500 错误页：零查询参数终案 ==")
check("234-5a path-based directory prefill URL", crv, "/new/%@/controls/layouts/community")
check_absent("234-5b filename= query retired", crv, "?filename=")
check_absent("234-5c value= query retired", crv, "&value=%@")
check_absent("234-5d id whitelist encoder retired", crv, "ame233_idSet")
check("234-5e clipboard-first kept", crv, "UIPasteboard.generalPasteboard.string = json")
check("234-5f openURL completion kept (233-4d compat)", crv, "Task233 GitHub openURL success=%d (urlLen=%lu)")
check("234-5g hint carries dynamic filename", crv, "stringWithFormat:localize(@\"ame230.repo.upload.github_hint\", nil), ame230_id")
check("234-5h failure toast kept", crv, 'localize(@"ame233.repo.open_fail", nil)')

print("== (6) i18n hint 文案 x5（带 %1$@.json 文件名占位） ==")
for lang in ["en", "zh-Hans", "zh-Hant", "zh-CN", "ja"]:
    p = f"Natives/resources/{lang}.lproj/Localizable.strings"
    check(f"234-6 hint filename placeholder @{lang}", p, "%1$@.json")

print()
print(f"verify_task234: {PASS} ok, {FAIL} fail")
sys.exit(0 if FAIL == 0 else 1)
