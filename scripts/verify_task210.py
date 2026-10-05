#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Task 210 验证器：新拟态全面退役 + 实例卡修复（用户七问定稿）。
A 新拟态退役清扫（引擎/偏好/选项/l10n/调用点） / B 实例卡规格（104pt/原色图标/
语义色/纯描边环/⋯28·16Black/弹簧动效退役） / C 设置页行退役与区段折叠 /
D BackgroundManager 单路径管线 / E 文档与级联重锚 / F 语法门。
无本地 clang，全部静态锚点 + 括号配平（仓库口径）。
"""
import io
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASS, FAIL = [], []


def check(group, name, ok, detail=""):
    (PASS if ok else FAIL).append((group, name, detail))
    print(("  ok " if ok else "FAIL ") + f"[{group}] {name}" + (f"  ({detail})" if detail and not ok else ""))


def rd(path):
    return io.open(os.path.join(REPO, path), encoding="utf-8").read()


def strip_objc(s):
    s = re.sub(r'@"(?:[^"\\]|\\.)*"', '@"S"', s)
    s = re.sub(r'//.*', '', s)
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return s


def strip_line_comments(s):
    return "\n".join(l.split("//")[0] for l in s.split("\n"))


def balanced(s):
    t = strip_objc(s)
    stack = []
    pairs = {')': '(', ']': '[', '}': '{'}
    for ch in t:
        if ch in '([{':
            stack.append(ch)
        elif ch in ')]}':
            if not stack or stack[-1] != pairs[ch]:
                return False
            stack.pop()
    return not stack


print("=" * 72)
print("Task 210 新拟态全面退役 + 实例卡修复 验证")
print("=" * 72)

engine_m = rd("Natives/UIKit+NativeSurface.m")
engine_h = rd("Natives/UIKit+NativeSurface.h")
bm_m = rd("Natives/BackgroundManager.m")
bm_h = rd("Natives/BackgroundManager.h")
bsvc = rd("Natives/BackgroundSettingsViewController.m")
vm = rd("Natives/VersionManagerViewController.m")

# ============ A. 新拟态退役清扫 ============
print("== A. 新拟态退役 ==")
check("A", "引擎类/原语/色族/度量全删（ShadowView/ame_*Neumorph*/Shadow|Highlight|Gradient/Metrics/BaseDimension）",
      all(sym not in strip_line_comments(engine_m) and sym not in strip_line_comments(engine_h)
          for sym in ["AmeNeumorphShadowView", "ame_applyNeumorphSurface", "ame_removeNeumorphShadow",
                      "ame_applyNeumorphCardOpacity", "ame_setNeumorphPinnedCornerRadius",
                      "AmeNeumorphShadowColor", "AmeNeumorphHighlightColor",
                      "AmeNeumorphSurfaceGradientStartColor", "AmeNeumorphMetricsForSide",
                      "AmeNeumorphBaseDimension", "AmeNeumorphSurfaceColor",
                      "AmeNeumorphPrimaryTextColor", "AmeNeumorphSecondaryTextColor"]))
check("A", "改名保留三函数（Surface/PrimaryText/SecondaryText，色值逐字节沿用）",
      all(f"AmeCard{x}Color(void)" in engine_m for x in ["Surface", "PrimaryText", "SecondaryText"])
      and "0xE0/255.0" in engine_m and "0x2C/255.0" in engine_m
      and "0x33/255.0" in engine_m and "0xF5/255.0" in engine_m
      and "0x88/255.0" in engine_m and "0xA0/255.0" in engine_m)
check("A", "AmeBadgeLabel 胶囊徽章幸存（与新拟态无关）",
      "@implementation AmeBadgeLabel" in engine_m and "_textInsets = UIEdgeInsetsMake(0, 8, 0, 8);" in engine_m)
check("A", "BackgroundManager 开关/透明度偏好零残留（属性/存取器/defaults 键）",
      all(sym not in strip_line_comments(bm_m) and sym not in strip_line_comments(bm_h)
          for sym in ["cardsNeumorphEnabled", "cardsNeumorphOpacity",
                      "kBackgroundCardsNeumorphEnabledKey", "kBackgroundCardsNeumorphOpacityKey"]))
check("A", "设置页新拟态两行零残留（开关行/滑条行/回调/tags 410·500）",
      all(sym not in bsvc for sym in ["CardsNeumorphToggleCell", "CardsNeumorphOpacityCell",
                                      "cardsNeumorphToggleChanged", "cardsNeumorphOpacitySliderChanged",
                                      "neumorphSwitch.tag = 410", "slider.tag = 500"]))
check("A", "l10n 双键六语言全退役",
      all("background.cards.neumorph." not in rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
          for lg in ["en", "zh-Hans", "zh-CN", "zh-Hant", "ja", "km"]))
check("A", "调用点改名收口（applyCardEffectToView ×3 落点 + 全仓 Neumorph API 零调用）",
      rd("Natives/VersionCardCell.m").count("applyCardEffectToView:self.cardContainer];") == 1
      and rd("Natives/TerracottaViewController.m").count("applyCardEffectToView:self.statusCard];") == 1
      and rd("Natives/installer/ModLoaderInstallViewController.m").count("applyCardEffectToView:_cardContainer];") == 3
      and all(sym not in strip_line_comments(rd(f))
              for f in ["Natives/VersionCardCell.m", "Natives/TerracottaViewController.m",
                        "Natives/installer/ModLoaderInstallViewController.m",
                        "Natives/LauncherNewsViewController.m", "Natives/LauncherRightPanelViewController.m",
                        "Natives/ProfileSettingsViewController.m", "Natives/LauncherPreferencesViewController.m",
                        "Natives/NMToast.m", "Natives/DownloadViewController.m", "Natives/MinecraftNewsViewController.m"]
              for sym in ["ame_applyNeumorph", "ame_removeNeumorph", "ame_setNeumorph",
                          "AmeNeumorph", "applyNeumorphCardEffectToView"]))

# ============ B. 实例卡规格 ============
print("== B. 实例卡（快捷指令样 · Task210 定稿） ==")


def segment(src, start_marker, end_marker):
    i = src.find(start_marker)
    j = src.find(end_marker, i + 1) if i >= 0 else -1
    if i < 0 or j < 0:
        return ""
    return src[i:j]


cell_seg = segment(vm, "#pragma mark - Version Card Cell (Task207", "#pragma mark - Game Directory Cell")
check("B", "卡底 = 深浅自适应平贴灰面（本卡零自绘背景；渐变/透明度滑条跟随退役）",
      "CAGradientLayer" not in strip_objc(cell_seg)
      and "gradientView" not in strip_objc(cell_seg)
      and "cardsNeumorphOpacity" not in strip_objc(vm))
check("B", "图标 = 原始彩色直出（白色模板渲染退役；PNG 不着色 / cube 兜底强调色）",
      "configureImageView:self.iconView" in cell_seg
      and "imageWithRenderingMode" not in strip_objc(cell_seg)
      and "self.iconView.tintColor = accentColor();" in cell_seg)
check("B", "⋯ 钮 = 28pt 圆底 + 16pt Black 三点 + 自适应配色（labelColor 12% 底）",
      "CGFloat ellipsisSize = 28.0;" in cell_seg
      and "configurationWithPointSize:16.0 weight:UIFontWeightBlack" in cell_seg
      and "[[UIColor labelColor] colorWithAlphaComponent:0.12]" in cell_seg
      and "self.ellipsisButton.tintColor = [UIColor labelColor];" in cell_seg)
check("B", "字体 = 深浅模式自适应（名称 AmeCard 主色 semibold / 版本 AmeCard 次色；白字清零）",
      "self.nameLabel.textColor = AmeCardPrimaryTextColor();" in cell_seg
      and "self.versionLabel.textColor = AmeCardSecondaryTextColor();" in cell_seg
      and "whiteColor" not in strip_objc(cell_seg))
check("B", "选中 = 纯 2pt accent 内缩描边（内缩 = 省略号间距/3；柔光光晕退役）",
      "self.selectionRing.layer.borderWidth = kVMCardRingBorderWidth;" in cell_seg
      and vm.count("kVMCardEllipsisInset / 3.0") >= 2
      and "shadowOpacity" not in strip_objc(cell_seg)
      and "shadowPath" not in strip_objc(cell_seg))
check("B", "行高 128pt（Task212 重锚：对照快捷指令卡再抬一档）+ 密度翻倍保持",
      "static const CGFloat kVMVersionRowHeight = 128.0;" in vm
      and "CGFloat itemWidth = isiPad ? 0.25 : 0.5;" in vm
      and "CGFloat itemHeight = kVMVersionRowHeight;" in vm)
check("B", "全部磁贴按压弹簧缩放退役（touchesBegan/Ended/Cancelled 零实现；0.96 按压模式清零——FAB 出场动画无关）",
      "touchesBegan" not in strip_objc(vm)
      and "touchesEnded" not in strip_objc(vm)
      and "touchesCancelled" not in strip_objc(vm)
      and "MakeScale(0.96" not in strip_objc(vm))
check("B", "交互不回潮（Task212 重锚）：点卡 = 选用 / ⋯ = 纯编辑 / 长按 = 直接呼出确认删除弹窗",
      "[self selectProfileNamed:profileName];" in vm
      and "cell.ellipsisAction = ^{" in vm
      and "[self deleteProfile:self.profileList[indexPath.item]];" in vm
      and "- (void)showProfileActions" not in vm)

# ============ C. 设置页 ============
print("== C. 壁纸设置页 ==")
check("C", "sections[0] = 纯壁纸效果三行（无 neumorph 键）",
      'localize(@"i18n_str_57", nil), localize(@"i18n_str_1296", nil), localize(@"i18n_str_1297", nil)' in bsvc
      and "background.cards.neumorph" not in bsvc)
check("C", "无壁纸时 section 0 整段隐藏（0 行 + 页脚同步隐藏；Task216 重锚：页脚改多行自定义视图）",
      "if (section == 0 && ![[BackgroundManager sharedManager] hasBackground]) {\n        return 0;" in bsvc
      and 'section != 0 || ![[BackgroundManager sharedManager] hasBackground]' in bsvc
      and "viewForFooterInSection" in bsvc)
check("C", "壁纸管线滑条行不受影响（opacity/blur 回调单在位 + 刷新链保留）",
      bsvc.count("- (void)opacitySliderChanged:") == 1
      and bsvc.count("- (void)blurIntensitySliderChanged:") == 1
      and "[[BackgroundManager sharedManager] refreshUIEffect];" in bsvc)

# ============ D. BackgroundManager 单路径管线 ============
print("== D. 管线单路径化 ==")
rui = bm_m[bm_m.index("- (void)refreshUIEffect"):]
check("D", "refreshUIEffect 单路径（无开关分支无取证日志）",
      "if (self.cardsNeumorphEnabled) {" not in rui
      and "ame178DecoupleLogOnce" not in bm_m
      and "[self addBlurEffectToContainer:self.globalBackgroundContainer];" in rui)
check("D", "无壁纸尾部 = 平贴灰面（AmeCardSurfaceColor + clamp[8,50] + 保裁剪）",
      "view.backgroundColor = AmeCardSurfaceColor();" in bm_m
      and "view.layer.cornerRadius = MAX(8.0, MIN(radius, 50.0));" in bm_m
      and "view.layer.masksToBounds = YES;" in bm_m)
check("D", "管线改名 applyCardEffectToView（恒转调 applyEffectToView）+ 泛型管线无 ON 分支",
      "- (void)applyCardEffectToView:(UIView *)view" in bm_m
      and "[self applyEffectToView:view];" in bm_m[bm_m.index("- (void)applyCardEffectToView"):bm_m.index("- (void)applyEffectToSearchBar")]
      and "if (self.cardsNeumorphEnabled) {" not in bm_m)
check("D", "applyCardEffectToCell 直转 applyEffectToCell（Flat 特调行退役）",
      "[self applyEffectToCell:cell];" in bm_m[bm_m.index("- (void)applyCardEffectToCell"):bm_m.index("- (void)applyCardEffectToView")])

# ============ E. 文档与级联 ============
print("== E. 公告 / version.h / 级联 ==")
ann = json.loads(rd("announcements.json"))["announcements"]
check("E", "公告 32 条，task210@2，置顶钉位未动，NG-GL4ES 尾锚保持",
      len(ann) == 42
      and ann[7]["id"] == "task210-neumorph-retirement-card-fixes-2026-10-02"
      and ann[0]["id"].startswith("server-recommend")
      and ann[1]["id"] == "task169-four-fixes-2026-09-25"
      and ann[-4]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-5]["id"] == "task216-ui-2026-10-03"
      and ann[-6]["id"] == "task206-nggl4es-2026-10-01")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("E", "version.h Task210 附录在场（REVISION 18 append-only，无 bump）+ 尾部 SEP 收口",
      "REVISION 18 addendum (Task 210, no bump)" in vh
      and "AmeCardSurfaceColor" in vh
      and vh.endswith("// ============================================================================\n"))
v207 = rd("scripts/verify_task207.py")
check("E", "verify_task207 重锚（Task212 重锚：行高 128 / AmeCard 色族 / 纯描边 / 91 配额 1）",
      "kVMVersionRowHeight = 128.0" in v207
      and "AmeCardPrimaryTextColor()" in v207
      and '"Natives/VersionManagerViewController.m": 1,' in rd("scripts/verify_task91.py"))
check("E", "级联计数族重锚（206 F1 / 202 F / 193 M / 190 G / 151 H = 2520）",
      "== 2520" in rd("scripts/verify_task206.py")
      and "== 2520" in rd("scripts/verify_task202.py")
      and "唯一键 2520" in rd("scripts/verify_task193.py")
      and "唯一键总数 == 2520" in rd("scripts/verify_task190.py")
      and '!= "2520"' in rd("scripts/verify_task151.py"))
check("E", "纯新拟态验证器退役（173b_neumorph/177/178 不在 scripts）",
      all(not os.path.exists(f"scripts/verify_task{n}.py")
          for n in ["173b_neumorph", "177", "178"]))

# ============ F. 语法门 ============
print("== F. 语法 / 配平 ==")
for f in ["Natives/VersionManagerViewController.m", "Natives/BackgroundManager.m",
          "Natives/BackgroundManager.h", "Natives/BackgroundSettingsViewController.m",
          "Natives/UIKit+NativeSurface.m", "Natives/UIKit+NativeSurface.h",
          "Natives/VersionCardCell.m", "Natives/MinecraftNewsViewController.m",
          "Natives/installer/ModLoaderInstallViewController.m"]:
    check("F", f"配平：{os.path.basename(f)}", balanced(rd(f)))
for f in ["scripts/task210_docs.py", "scripts/verify_task207.py", "scripts/verify_task91.py",
          "scripts/verify_task206.py", "scripts/verify_task202.py"]:
    try:
        import ast
        ast.parse(rd(f))
        check("F", f"py 语法：{os.path.basename(f)}", True)
    except SyntaxError as e:
        check("F", f"py 语法：{os.path.basename(f)}", False, str(e))

print("=" * 72)
print(f"PASS {len(PASS)}  FAIL {len(FAIL)}")
if FAIL:
    for g, n, d in FAIL:
        print(f"  FAIL [{g}] {n}  {d}")
print("==== RESULT: " + ("ALL PASS" if not FAIL else f"{len(PASS)}/{len(PASS) + len(FAIL)}") + " ====")
sys.exit(0 if not FAIL else 1)
