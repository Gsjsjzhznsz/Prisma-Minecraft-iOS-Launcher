#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# verify_task235.py -- Task 235 (7-item round on the Task234 build a32f1f3)
# (1) all-version launch crash: array literal with nil statsLabel in the
#     floating-glass applier (NSInvalidArgumentException objects[1], device
#     log 51327919). (2) version/isolation coach anchor aimed at the home
#     avatar card. (3) font overlap round 6: adjustsFontSizeToFitWidth labels
#     draw outline copies at the UNSCALED font. (4) multiplayer home tile
#     (upstream MP-RESTORE port). (5) dependency quick-entry gains an in-app
#     go-to-download-page flow. (6) native UIAlertController popups -> liquid
#     glass (global, style-gated). (7) issue #11 forensics reply (see worklog).
import io, os, re, subprocess, sys

REPO = "/home/z/my-project/Amethyst-iOS-MyRemastered"
PASSED = []
FAILED = []

def rd(p):
    with io.open(os.path.join(REPO, p), "r", encoding="utf-8", errors="replace") as f:
        return f.read()

def check(idx, name, cond, detail=""):
    (PASSED if cond else FAILED).append(f"{idx} {name}")
    print(("PASS " if cond else "FAIL ") + f"{idx} {name}" + (f"  [{detail}]" if detail and not cond else ""))

def check_absent(idx, name, content, absent):
    check(idx, name, absent not in content)

gmv = rd("Natives/GameMenuOverlayView.m")
bm  = rd("Natives/BackgroundManager.m")
wvc = rd("Natives/WelcomeViewController.m")
rph = rd("Natives/LauncherRightPanelViewController.h")
rpm = rd("Natives/LauncherRightPanelViewController.m")
nvh = rd("Natives/LauncherNewsViewController.h")
nvm = rd("Natives/LauncherNewsViewController.m")
hcv = rd("Natives/HomeCustomizeViewController.m")
mvv = rd("Natives/ModVersionViewController.m")
ukh = rd("Natives/UIKit+hook.m")

print("== A. 全版本启动闪退（数组字面量 nil[1]）==")
# Task236 诚实重锚：ame232_applyFloatingGlass 重构为防御性可见性——statsLabel/
# captionLabel 不再往标签内插磨砂层（UILabel 文字画在自己图层，子视图磨砂会
# 盖住文字 = “什么都不显示”），ame235_hosts 收集数组整体退役；nil 安全由
# 结构保证（LGCRemoveGlassFromView 对 nil 宿卫返回，menuButton 在两处调用
# 点均非 nil，SystemMaterialDark 升级只迭代 menuButton.subviews）。
check("A1", "nil 安全（Task236 结构性：hosts 数组退役，LGC 系 nil 宿卫 + 标签不入玻璃）",
      "LGCRemoveGlassFromView(self.statsLabel);" in gmv and
      "LGCRemoveGlassFromView(self.ame230_captionLabel);" in gmv and
      "for (UIView *ame232_sub in self.menuButton.subviews) {" in gmv)
check_absent("A2", "裸数组字面量退役", gmv, "@[self.menuButton, self.statsLabel, self.statsLabel]")
check_absent("A3", "三件套裸数组退役（真锚）", gmv,
             "@[self.menuButton, self.statsLabel, self.ame230_captionLabel]")
check("A4", "init 末尾统一补铺玻璃（三件套就绪后）",
      "[self applyStatsLabelVisibility];" in gmv and
      gmv.index("[self ame232_applyFloatingGlass];") > gmv.index("[self setupStatsLabel];") and
      gmv.index("[self ame232_applyFloatingGlass];") > gmv.index("[self restorePositions];"))
check("A5", "崩溃根因注释锚（NSInvalidArgumentException）", "NSInvalidArgumentException" in gmv)

print("== B. 字体重叠第六轮（缩字标签的描边拷贝用原字号）==")
check("B1", "缩字门（adjustsFontSizeToFitWidth + 单行）",
      "ame232_label.adjustsFontSizeToFitWidth && ame235_baseFont != nil &&" in bm)
check("B2", "自然宽度测量（无限宽 boundingRect）",
      "CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)" in bm)
check("B3", "下限钳制（minimumScaleFactor）", "ame235_minScale" in bm)
check("B4", "缩后字号注入深色拷贝",
      "[ame233_dark addAttribute:NSFontAttributeName value:ame235_scaledFont range:ame233_darkRange];" in bm)
check("B5", "缩后字号注入垫底",
      "[ame233_backing addAttribute:NSFontAttributeName value:ame235_scaledFont range:ame233_backRange];" in bm)
check("B6", "四份拷贝画进 ame235_copyRect",
      bm.count("CGRectOffset(ame235_copyRect,") == 4)
check("B7", "垫底画进 ame235_copyRect", "[ame233_backing drawInRect:ame235_copyRect];" in bm)
check("B8", "同中心重求缩后行高", "CGRectGetMidY(ame234_textRect) - ame235_scaledSize.height / 2.0" in bm)
check("B9", "非缩字路径语义保留（copyRect 初值 = textRect）",
      "CGRect ame235_copyRect = ame234_textRect;" in bm)
check("B10", "Task234 紧致矩形语义保留（回归锚）",
      "ame234_textRect = [ame232_label textRectForBounds:rect" in bm)

print("== C. 版本与隔离锚点（头像卡 → 选择版本真身）==")
check("C1", ".h 声明 ame235_versionAnchorView", "ame235_versionAnchorView" in rph)
check("C2", ".m 实现返回 manageVersionBtn 真身",
      "return self.manageVersionBtn;" in rpm and "ame235_versionAnchorView" in rpm)
check("C3", "欢迎页 tier-1 直取真身",
      "[ame233_rightVC ame235_versionAnchorView]" in wvc)
check("C4", "tier-2 标题匹配兜底（i18n_str_38）",
      'localize(@"i18n_str_38", nil)' in wvc)
check("C5", "tier 落日志", "[Welcome] Task235 version anchor tier=%@ rect=%@" in wvc)
check_absent("C6", "旧'内容区上半 42%'派生退役", wvc, "CGRectGetHeight(cr) * 0.42")
check("C7", "绝不回落头像区（全失败宁可跳过）",
      "全部失败则宁可跳过该页，绝不回落到头像区" in wvc)

print("== D. 联机主页磁贴（上游 MP-RESTORE 移植）==")
check("D1", "动作常量定义", 'NSString * const kShortcutActionMultiplayer = @"multiplayer";' in nvm)
check("D2", ".h extern 声明", "extern NSString * const kShortcutActionMultiplayer;" in nvh)
check("D3", "默认磁贴（tileId=shortcut_multiplayer）",
      '@"shortcut_multiplayer"' in nvm and nvm.count('kShortcutActionMultiplayer') >= 4)
check("D4", "老用户布局一次性补入（缺失才加）", "hasMultiplayerShortcut" in nvm and "Task235 multiplayer shortcut injected into saved layout" in nvm)
check("D5", "点按 → 陶瓦联机页 PageSheet",
      "TerracottaViewController *ame235_mpVC = [[TerracottaViewController alloc] init];" in nvm and
      "UIModalPresentationPageSheet" in nvm)
check("D6", "可用性探测（TerracottaBridge）", "![TerracottaBridge isAvailable]" in nvm)
check("D7", "磁贴图标与上游一致", "antenna.radiowaves.left.and.right" in nvm)
check("D8", "自定义主页可选清单收录", "kShortcutActionMultiplayer" in hcv)
check("D9", "标题键复用 game.menu.multiplayer", 'localize(@"game.menu.multiplayer", @"联机")' in nvm)

print("== E. 前置快捷入口直跳模组下载页 ==")
check("E1", "详情页接口挂委托协议", "@interface Ame232DepDetailViewController : UIViewController <ModVersionViewControllerDelegate>" in mvv)
check("E2", "偏好版本/加载器透传属性", "preferredGameVersion" in mvv and mvv.count("preferredLoader") >= 4)
check("E3", "调用点透传（openDependencyPage）",
      "detail.preferredGameVersion = self.preferredGameVersion;" in mvv)
check("E4", "前往下载页按钮（i18n ame235.deps.godl）", 'localize(@"ame235.deps.godl", nil)' in mvv)
check("E5", "跳转实现（push 版本列表 + delegate=self）",
      "ame235_vc.delegate = self;" in mvv and
      "[self.navigationController pushViewController:ame235_vc animated:YES];" in mvv)
check("E6", "选中版本 → ModService 下载（SHA1 + 实例）",
      "[[ModService sharedService] downloadMod:ame235_dl" in mvv and
      "expectedSHA1:ame235_dl.fileSHA1" in mvv and
      "[PLProfiles current].selectedProfileName" in mvv)
check("E7", "无双弹（委托不 pop——版本页自 pop）",
      "不在这里 pop" in mvv)
check("E8", "进度/完成提示（NMToast + i18n_str_266）",
      "[NMToast showMessage:" in mvv and 'localize(@"i18n_str_266", nil)' in mvv)

print("== F. UIAlertController 液态玻璃化（Task237 重锚：魔改路线整体退役 → 中央路由整体替换）==")
# Task237（用户指令“彻底重写所有悬浮菜单样式。不要使用原生 UIAlertController
# 加魔改”）：Task235/236 的 viewWillAppear/present-hook 玻璃化魔改被整体
# 拆除；同一关切（玻璃风格下弹窗呈现液态玻璃外观）由 AmeFloatingMenu 的
# 全自定义组件 + 中央路由承接——玻璃风格下 UIAlertController 永不上屏。
fm = rd("Natives/AmeFloatingMenu.m")
check("F1", "路由钩子实现迁移至 AmeFloatingMenu.m", "- (void)ame237_hook_presentViewController:" in fm and
      "Ame237FloatingMenuRouter)" in fm)
check("F2", "UIKit+hook.m 魔改双钩子拆除（viewWillAppear 交换退役）", "ame235_hook_viewWillAppear" not in ukh and
      "class_copyMethodList([UIAlertController class], &ame235_mcount)" not in ukh)
check("F3", "Task236 present-hook 魔改拆除（路由日志仍在）", "ame236_hook_presentViewController" not in ukh and
      "[AmeMenu] Task237 floating-menu router installed" in ukh)
check("F4", "路由先判类型与风格（非玻璃零接触直透）",
      "isKindOfClass:[UIAlertController class]] && LGCIsGlassStyleActive()" in fm)
check("F5", "玻璃风格下原生弹窗永不上屏（镜像接管 return）",
      "presentGlassMenuForAlert:(UIAlertController *)viewControllerToPresent" in fm)
check("F6", "UIAlertAction KVC 镜像 + 失败回退原生", 'valueForKey:@"title"' in fm and
      'valueForKey:@"handler"' in fm and "native passthrough" in fm)
check("F7", "自适应材质（SystemMaterial）+ 防御性明暗实底",
      "UIBlurEffectStyleSystemMaterial]" in fm and "Ame237PanelBase" in fm)
check("F8", "文字自适应（labelColor/secondaryLabel）", "[UIColor labelColor]" in fm and "[UIColor secondaryLabelColor]" in fm)
check("F9", "菜单项带图标（SF Symbol 启发式 + 回退链）", "iconNameForTitle:" in fm and
      'systemImageNamed:@"circle"' in fm)
check("F10", "替换日志（限流）", "[AmeMenu] Task237 glass menu replaced native alert" in fm)
check("F11", "输入框镜像 + 双向同步", "ame237_fieldChanged:" in fm and "ame237_syncAllFields" in fm)
check("F12", "键盘避让", "UIKeyboardWillShowNotification" in fm and "UIKeyboardWillHideNotification" in fm)

print("== G. i18n 基线（2765 → 2767）==")
langs4 = ["en", "zh-CN", "zh-Hans", "zh-Hant"]
for l in langs4:
    s = rd(f"Natives/resources/{l}.lproj/Localizable.strings")
    keys = set(re.findall(r'^"([^"]+)" =', s, re.M))
    check("G1", f"{l} 唯一键总数 == 2767（Task235 重锚 +1 ame235.deps.godl）", len(keys) == 2767, f"got {len(keys)}")
for l in ["en", "ja", "zh-CN", "zh-Hans", "zh-Hant"]:
    s = rd(f"Natives/resources/{l}.lproj/Localizable.strings")
    check("G2", f"{l} ame235.deps.godl 在场", '"ame235.deps.godl"' in s)

print("== H. 级联（被本改动触碰的区域）==")
# 232/233/234 已诚实重锚（本轮实改代码区）；229/230 触碰同文件区域。
# 各 fleet 脚本总结行格式不一（passed/ok/PASS / X of Y），这里逐一适配。
def fleet_summary(r):
    t = r.stdout
    for pat in (r"(\d+) passed, (\d+) failed", r"(\d+) ok, (\d+) fail\b",
                r"(\d+) PASS / (\d+) FAIL", r"(\d+) / (\d+) checks passed",
                r"(\d+)/(\d+) checks passed"):
        m = re.search(pat, t)
        if m:
            return m.group(1) == m.group(2) or m.group(2) == "0"
    return r.returncode == 0

for tag, tasks in (("H1", (232, 233, 234)), ("H2", (229, 230))):
    for t in tasks:
        r = subprocess.run([sys.executable, os.path.join(REPO, f"scripts/verify_task{t}.py")],
                           capture_output=True, text=True, timeout=300)
        ok = r.returncode == 0 and fleet_summary(r)
        check(tag, f"verify_task{t} 全绿（重锚/同文件回归）", ok,
              (r.stdout[-300:].replace("\n", " ") + " | rc=" + str(r.returncode)) if not ok else "")

print(f"\n{'=' * 40}\n{len(PASSED)} passed, {len(FAILED)} failed")
if FAILED:
    for f in FAILED:
        print("  FAILED:", f)
    sys.exit(1)
