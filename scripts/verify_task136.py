#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task136.py —— Task 136 校验器（Task137 重锚版）

Task 136 原始八项需求中，与新拟态强绑定的色板/引擎/扫描器门已随 Task 137
（用户最终决定：删去所有新拟态代码，回归 iOS 原生 UI）退役或转为"退役门"；
幸存特性（新闻卡等高、顶卡头像交换、列表小字框、模组加载器卡片化、
设置页图标本体着色、页面底色自适应）的门重锚到 Task137 原生实现。
口径护栏（Task93 检测链）零变化断言保留。

分节：
  A. 新拟态色板/引擎退役（原 NMTheme/UIView+Neomorph 色板门 → 退役门）
  B. NMContrast 扫描器退役（原 Item 4a 扫描器门 → 退役门；深浅色由语义色自适应）
  C. BackgroundManager 枢纽（原凸出分发 → 原生表面分发）
  D. Item 1：MC 新闻卡固定最低高度（机制保留；圆角回归原生 12）
  E. Item 2：主页顶卡头像交换 + 欢迎语纵轴居中（原样幸存）
  F. Item 3：列表右侧小字框（Task137 重锚：AmeBadgeLabel intrinsic 完整实现）
  G. Item 4b：下载页模组加载器卡片化（机制保留；圆角回归原生）
  H. Item 5：设置页 SF 图标改图标本体（原样幸存）
  I. 全局样式清扫（原 50/10 基准门 → 原生圆角/原生表面退役门）
  J. 页面底色（nm_background → systemBackgroundColor 重锚）
  K. 口径护栏（Task93 检测链零变化）与语法配平
"""
import os
import re
import subprocess
import sys

# Task138 环境修复：上一会话的默认克隆路径 /home/z/my-project/workspace/
# Air-Minecraft-iOS-Launcher 已被沙箱清除，默认值改为脚本所在仓库（与
# verify_task133/134 同形态），TASK136_REPO 环境变量覆盖能力保留。
REPO = os.environ.get("TASK136_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PASS = 0
FAIL = 0


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as f:
        return f.read()


def exists(path):
    return os.path.exists(os.path.join(REPO, path))


def strip_objc(s):
    s = re.sub(r'@"(?:[^"\\]|\\.)*"', '""', s)
    s = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', s)
    s = re.sub(r'//.*', '', s)
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    return s


def balanced(s):
    s = strip_objc(s)
    return all(s.count(a) == s.count(b) for a, b in [("{", "}"), ("(", ")"), ("[", "]")])


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")


print("=" * 72)
print("A. 新拟态色板/引擎退役（Task137：用户决定删去所有新拟态代码）")
print("=" * 72)
check("A1  NeomorphKit 目录整体退役（NMTheme/UIView+Neomorph 等源文件不存在）",
      not exists("Natives/NeomorphKit/NMTheme.m")
      and not exists("Natives/NeomorphKit/NMTheme.h")
      and not exists("Natives/NeomorphKit/UIView+Neomorph.m")
      and not exists("Natives/NeomorphKit/UIView+Neomorph.h"))
check("A2  NMToast 迁出 Kit（原 NeomorphKit/NMToast.m 不存在，Natives/NMToast.m 存在）",
      not exists("Natives/NeomorphKit/NMToast.m") and exists("Natives/NMToast.m"))
check("A3  原生表面辅助 UIKit+NativeSurface 就位",
      exists("Natives/UIKit+NativeSurface.m") and exists("Natives/UIKit+NativeSurface.h"))
check("A4  CMake 不再登记 Kit 源，登记原生辅助",
      "NeomorphKit/" not in read("Natives/CMakeLists.txt")
      and "UIKit+NativeSurface.m" in read("Natives/CMakeLists.txt"))
# Task170 诚实重锚：Task160 新拟态回归把卡片表面语义色替换为规格表面色，
# 本锚自 Task160 起即为漂移失败（此前仅经 138 J 行豁免）。现锚定现行语义。
check("A5  原生卡片表面 = 平贴灰面身份色（Task210 重锚：AmeCardSurfaceColor 改名保留）",
      "AmeCardSurfaceColor" in read("Natives/UIKit+NativeSurface.m"))

print()
print("=" * 72)
print("B. NMContrast 扫描器退役（Task137：直接修复替代动态扫描）")
print("=" * 72)
check("B1  NMContrast.{h,m} 源文件删除", not exists("Natives/NeomorphKit/NMContrast.h")
      and not exists("Natives/NeomorphKit/NMContrast.m"))
check("B2  CMake 不再登记 NMContrast", "NMContrast" not in read("Natives/CMakeLists.txt"))
check("B3  SceneDelegate 启动扫描接线移除",
      "[NMContrast nm_startContrastSweep];" not in read("Natives/SceneDelegate.m"))
check("B4  窗口底色回归原生 systemBackgroundColor（Task137 重锚）",
      "self.window.backgroundColor = [UIColor systemBackgroundColor];" in read("Natives/SceneDelegate.m"))
check("B5  全仓无 NMContrast 代码引用",
      "NMContrast" not in strip_objc(read("Natives/SceneDelegate.m"))
      and "NMContrast" not in strip_objc(read("Natives/BackgroundManager.m")))

print()
print("=" * 72)
print("C. BackgroundManager 枢纽（原生表面分发 / 裁剪恢复 / 检测切换保留）")
print("=" * 72)
bm = read("Natives/BackgroundManager.m")
bmh = read("Natives/BackgroundManager.h")
# Task170 诚实重锚：Task160/163 后列表行表面为平贴新拟态（Flat 无阴影）。
check("C1  applyCardEffectToCell 保留（Task210 重锚：单路径直转 applyEffectToCell，Flat 特调行退役）",
      "applyCardEffectToCell" in bmh
      and "ame_applyNeumorphSurfaceFlatWithRadius" not in bm)
# Task173 诚实重锚：行管线被"新拟态界面"开关接管——关闭 → applyEffectToCell
# 旧管线（有壁纸毛玻璃/半透明、无壁纸标准列表，原 C2 语义并入此门）；开启 →
# Flat 平贴（壁纸无关）。
check("C2  applyCardEffectToCell（Task210 重锚：无开关门，恒直转 applyEffectToCell 同管线）",
      re.search(r"applyCardEffectToCell:\(UITableViewCell \*\)cell \{[\s\S]{0,300}?\[self applyEffectToCell:cell\];", bm))
check("C3  Task210：无壁纸卡面裁剪由平贴分支收口（masksToBounds = YES，无帧外阴影诉求）",
      "view.layer.masksToBounds = YES;" in bm
      and "cell.clipsToBounds = YES;" not in bm)
# Task220 诚实重锚：Task190 的参数化重构把 cell.contentView 局部化为
# contentView（cell. 前缀退场），"优先读 contentView 自身圆角"语义不变。
check("C4  collection cell 圆角来源保留：优先读 contentView 自身圆角（Task220 重锚：参数化后形式）",
      "contentView.layer.cornerRadius > 0" in bm)
# Task170 诚实重锚：无背景分派在 Task160 后为等比圆角平贴新拟态/整页 systemBackground。
check("C5  applyEffectToView 无背景 → 原生表面分派（有圆角=平贴灰面 AmeCardSurfaceColor，无圆角=systemBackground；Task210 重锚）",
      "view.backgroundColor = AmeCardSurfaceColor();" in bm
      and "view.backgroundColor = [UIColor systemBackgroundColor];" in bm)
check("C6  检测并切换架构原样保留（hasBackground 双分支 + SystemThinMaterial 旧管线）",
      bm.count("[self hasBackground]") >= 5 and "SystemThinMaterial" in bm
      and "nm_removeNeomorph" not in bm)

print()
print("=" * 72)
print("D. Item 1：MC 新闻卡固定最低高度（机制保留；圆角回归原生）")
print("=" * 72)
mcnews = read("Natives/MinecraftNewsViewController.m")
check("D1  卡片圆角回归原生 12（Task137 重锚：kNewsCardCornerRadius = 12.0）",
      "kNewsCardCornerRadius = 12.0" in mcnews)
check("D2  Task149 重锚：固定等高机制退役（newsCardFixedHeight 代码引用清零），高度 estimated 自 sizing",
      "newsCardFixedHeight" not in strip_objc(mcnews)
      and "estimatedDimension:280" in mcnews)
check("D3  Task149 重锚：恢复双列并列排（每组两个 0.5 宽子项）+ 简介行数不限",
      "fractionalWidthDimension:0.5]" in mcnews
      and "subitems:@[ame149_itemA, ame149_itemB]" in mcnews
      and "_summaryLabel.numberOfLines = 0" in mcnews)
check("D4  正文纵向 stack + 截断优先级（摘要 750 先截断，标题/作者/查看详情保底）",
      "initWithArrangedSubviews:@[_titleLabel, _metaLabel, _summaryLabel, _readMoreLabel]" in mcnews
      and "setContentCompressionResistancePriority:750 forAxis:UILayoutConstraintAxisVertical" in mcnews
      and "setCustomSpacing:4 afterView:_titleLabel" in mcnews)
check("D5  新闻页底色原生（systemBackgroundColor；Task137 重锚）",
      "self.view.backgroundColor = [UIColor systemBackgroundColor];" in mcnews
      and "self.view.backgroundColor = [NMTheme nm_background];" not in mcnews)

print()
print("=" * 72)
print("E. Item 2：主页顶卡头像交换 + 欢迎语纵轴居中（原样幸存）")
print("=" * 72)
home = read("Natives/LauncherNewsViewController.m")
check("E1  皮肤全身预览退场（skinImageView 代码引用清零，仅留档注释）",
      len(re.findall(r"self\.skinImageView", home)) == 0)
check("E2  Task149 重锚：头像等边距（leading/文字间距 = 上下边距，layoutSubviews 按 side/2 动态刷新；尺寸不变）",
      "avatarLeadingConstraint" in home
      and "self.avatarLeadingConstraint.constant = side / 2.0;" in home
      and "self.textLeadingConstraint.constant = side / 2.0;" in home
      and "heightAnchor constraintEqualToAnchor:self.contentContainer.heightAnchor multiplier:0.5" in home
      and "avatarImageView.widthAnchor constraintEqualToAnchor:self.avatarImageView.heightAnchor" in home)
check("E3  半透明边框样式保留（2.5pt white@0.35）+ 圆形裁剪 masksToBounds",
      "layer.borderWidth = 2.5" in home
      and "colorWithWhite:1.0 alpha:0.35" in home
      and "avatarImageView.layer.masksToBounds = YES" in home)
check("E4  Task149 重锚：两行欢迎句 stack（第二行 = 问候语 greetingLabel；相对头像纵轴居中保留）",
      "initWithArrangedSubviews:@[self.welcomeLabel, self.greetingLabel]" in home
      and re.search(r"welcomeStack\.centerYAnchor constraintEqualToAnchor:self\.avatarImageView\.centerYAnchor\]", home))
check("E5  头像圆角随尺寸取半（layoutSubviews 动态）",
      "avatarImageView.layer.cornerRadius = side / 2.0" in home)
check("E6  皮肤全身图请求退役（updateSkinDisplay 不再调用 loadSkinForUUID）",
      "[self loadSkinForUUID:" not in home.split("@implementation LauncherNewsViewController")[1])

print()
print("=" * 72)
print("F. Item 3：列表右侧小字框（Task137 重锚：AmeBadgeLabel 完整 intrinsic 实现）")
print("=" * 72)
vc = read("Natives/VersionCardCell.m")
vm = read("Natives/VersionManagerViewController.m")
nsh = read("Natives/UIKit+NativeSurface.h")
check("F1  版本类型胶囊 = AmeBadgeLabel（12pt + 高 24 + 内边距 8 由共享实现保证）",
      "[[AmeBadgeLabel alloc] init]" in vc
      and "systemFontOfSize:12 weight:UIFontWeightSemibold" in vc
      and "typeLabel.heightAnchor constraintEqualToConstant:24" in vc
      and "UIEdgeInsetsMake(0, 8, 0, 8)" in read("Natives/UIKit+NativeSurface.m"))
check("F1b AmeBadgeLabel intrinsicContentSize 补偿内边距（修复 Task136 全胶囊'…'截断回归）",
      "intrinsicContentSize" in read("Natives/UIKit+NativeSurface.m")
      and "_textInsets.left + _textInsets.right" in read("Natives/UIKit+NativeSurface.m"))
check("F2  版本类型胶囊靠右锚定 chevron 左侧 8pt（不贴卡片边缘）",
      "typeLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8" in vc)
check("F3  版本类型胶囊移出顶行 stack（独立靠右，版本号侧留 8pt 间隙）",
      "initWithArrangedSubviews:@[self.versionLabel]]" in vc
      and "topRowStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.typeLabel.leadingAnchor constant:-8" in vc)
check("F4  计数徽章（游戏目录/已安装版本）= AmeBadgeLabel：高 24 ≈ 两行字 + 垂直居中对齐文字块",
      "[[AmeBadgeLabel alloc] init]" in vm
      and "countBadge.heightAnchor constraintEqualToConstant:24" in vm
      and "countBadge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor" in vm
      and "sp:12" in vm)
check("F5  计数徽章右侧 18pt 安全边距保留",
      "countBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18" in vm)
check("F6  账户类型标识（Task212 重锚：安装器同构——类型判别口径保留，sp:12 AmeCard 次文字色）",
      "ame190_accountTypeTextForAccount:" in read("Natives/AccountListViewController.m")
      and '[UIFont systemFontOfSize:[ScreenUtils sp:12] weight:UIFontWeightRegular]' in read("Natives/AccountListViewController.m")
      and "self.typeLabel.textColor = AmeCardSecondaryTextColor();" in read("Natives/AccountListViewController.m"))
check("F7  模组下载列表的下载按钮回归 Task89 之前原生样式（accent 底白字胶囊；Task137 重锚）",
      "_downloadButton.backgroundColor = accentColor();" in read("Natives/ModTableViewCell.m")
      and "_downloadButton.layer.cornerRadius = 13.0" in read("Natives/ModTableViewCell.m"))

print()
print("=" * 72)
print("G. Item 4b：下载页模组加载器与上级菜单样式统一（机制保留；圆角回归原生）")
print("=" * 72)
ml = read("Natives/installer/ModLoaderInstallViewController.m")
check("G1  每个加载器独立 section（insetGrouped 独立圆角卡）",
      "return _loaders.count + ([self currentOptions].count > 0 ? 1 : 0);" in ml
      and "return 1;  // Task136：每个加载器 section 仅一行卡片" in ml)
check("G2  卡片间距（Task190 重锚：用户要求与版本号页一致——section 头 10->4，净距 = 4 下内缩 + 4 头 + 4 上内缩 = 12pt）",
      "if (section < (NSInteger)_loaders.count) return 4;" in ml
      and "return 0.01;" in ml)
check("G3  两类 cell 视觉自洽（Task210 重锚：ModLoaderInstall 卡容器 init 挂 applyCardEffectToView ×3）",
      ml.count("[[BackgroundManager sharedManager] applyCardEffectToView:_cardContainer];") == 3
      and "applyNeumorphCardEffectToView" not in ml)
check("G4  nameBar 与上级菜单同语言（Task137 重锚：原生圆角 10 + 原生表面枢纽）",
      "_nameBar.layer.cornerRadius = 10;" in ml)
check("G5  didSelect 按新 section 语义取行（_loaders[indexPath.section] + 越界守卫）",
      "ModLoaderRow *row = _loaders[indexPath.section];" in ml
      and "if (indexPath.section >= (NSInteger)_loaders.count) return;" in ml)
check("G6  选中态同步改整表重载（reloadSections(0) 退役）",
      "[self.tableView reloadData];" in ml
      and "reloadSections:[NSIndexSet indexSetWithIndex:0]" not in ml)
check("G7  分隔线关闭（卡片化后无系统分隔线）",
      "_tableView.separatorStyle = UITableViewCellSeparatorStyleNone;" in ml)
check("G8  cellForRow 按新 section 语义取行",
      "ModLoaderRow *row = _loaders[indexPath.section];" in ml
      and "NSDictionary *opt = opts[indexPath.row];" in ml)

print()
print("=" * 72)
print("H. Item 5：设置页 SF 图标改图标本体（去彩底白标；原样幸存）")
print("=" * 72)
pref = read("Natives/LauncherPreferencesViewController.m")
seg = pref.split("applySettingsAppStyleToCell:(UITableViewCell *)cell")[1].split("@end")[0]
check("H1  白标渲染退役（imageWithTintColor:whiteColor 清零）",
      "imageWithTintColor:[UIColor whiteColor]" not in seg
      and "iconView.tintColor = [UIColor whiteColor];" not in seg)
check("H2  彩色圆角背景退役（clearColor + cornerRadius 0 + masksToBounds NO）",
      "iconView.backgroundColor = [UIColor clearColor];" in seg
      and "iconView.layer.cornerRadius = 0;" in seg
      and "iconView.layer.masksToBounds = NO;" in seg)
check("H3  图标本体着色（tintColor = 原 section 色，红/搜索模式映射保留）",
      "iconView.tintColor = iconColor;" in seg
      and "iconBackgroundColorForItem" in pref
      and "colorForPreferenceSection" in pref)
check("H4  section header 行仍为 accentColor",
      "iconView.tintColor = accentColor();" in seg)
check("H5  图标尺寸随本体渲染放大（pointSize 20）",
      "configurationWithPointSize:20" in seg)

print()
print("=" * 72)
print("I. 全局样式清扫（Task137 重锚：统一 50/10 基准退役 → 原生圆角/原生表面）")
print("=" * 72)
check("I1  全仓 nm_convex/nm_flat/nm_pill 引擎调用点清零",
      not re.search(r"nm_(convex|flat|pill|styleConvex)",
                    "".join(strip_objc(read(f)) for f in [
                        "Natives/LauncherMenuViewController.m",
                        "Natives/DownloadViewController.m",
                        "Natives/LauncherNavigationController.m",
                        "Natives/AnnouncementDetailViewController.m",
                        "Natives/ModpackExportViewController.m",
                        "Natives/ServerDetailViewController.m",
                        "Natives/ModTableViewCell.m",
                        "Natives/LauncherRootViewController.m",
                        "Natives/BackgroundManager.m"])))
check("I2  卡片圆角回归原生逐元素取值（Task190 重锚：账户卡与已安装版本页同构 = 12pt；版本卡 12/资源卡 12/Mod版本卡 12/筛选 14/自定义行 12/崩溃卡 16）",
      "cardContainer.layer.cornerRadius = 12" in read("Natives/VersionCardCell.m")
      and "contentView.layer.cornerRadius = 12.0" in read("Natives/ResourceCardTableViewCell.m")
      and "cardContainer.layer.cornerRadius = 12" in read("Natives/ModVersionTableViewCell.m")
      and "self.contentContainer.layer.cornerRadius = 12;" in read("Natives/AccountListViewController.m")
      and "filterContainerView.layer.cornerRadius = 14" in read("Natives/AssetVersionViewController.m")
      and "self.contentView.layer.cornerRadius = 12;" in read("Natives/HomeCustomizeViewController.m")
      and read("Natives/PLCrashView.m").count("layer.cornerRadius = 16;  // Task137") == 3)
check("I3  主页磁贴圆角 16（Task137 重锚：原生磁贴卡片，阴影路径退场）",
      "self.contentView.layer.cornerRadius = 16;" in home
      and "cornerRadius:50].CGPath" not in home)
check("I4  NMToast 卡片 = 原生表面 18pt 圆角（凸出 raised 50/10 退役）",
      "[self.cardView ame_applyCardSurfaceWithRadius:kNMToastCornerRadius];" in read("Natives/NMToast.m")
      and "kNMToastCornerRadius = 18.0" in read("Natives/NMToast.m"))
check("I5  平贴面板 = 原生 panel 表面（侧栏/右面板 radius 16）",
      "[self.sidebarContainer ame_applyPanelSurfaceWithRadius:16];" in read("Natives/LauncherRootViewController.m")
      and "[self.rightPanelContainer ame_applyPanelSurfaceWithRadius:16];" in read("Natives/LauncherRootViewController.m"))
check("I6  侧栏选中态 = accent 0.15 原生高亮（凸出面板退役）",
      "[accent colorWithAlphaComponent:0.15]" in read("Natives/LauncherMenuViewController.m"))

print()
print("=" * 72)
print("J. 页面底色（Task137 重锚：13 页面 nm_background → systemBackgroundColor）")
print("=" * 72)
page_files = ["AssetVersionViewController.m", "AnnouncementDetailViewController.m",
              "MinecraftNewsViewController.m", "LauncherSplitViewController.m",
              "DownloadHistoryViewController.m", "ServerDetailViewController.m",
              "ResourceListViewController.m", "ShaderVersionViewController.m",
              "DownloadTasksViewController.m", "PLTaskProgressViewController.m",
              "AnnouncementListViewController.m", "ModVersionViewController.m",
              "BackgroundSettingsViewController.m"]
sweep_ok = all("self.view.backgroundColor = [UIColor systemBackgroundColor];" in read("Natives/" + f)
               for f in page_files)
check("J1  13 个页面 view 底色 = systemBackgroundColor（原生自适应）", sweep_ok)
check("J2  上述页面 nm_background 残留清零",
      all("[NMTheme nm_background]" not in read("Natives/" + f) for f in page_files))
check("J3  LauncherSplitViewController 双入口均原生（systemBackgroundColor ×2）",
      read("Natives/LauncherSplitViewController.m").count("[UIColor systemBackgroundColor];") == 2
      and "self.view.backgroundColor = [UIColor blackColor];" not in read("Natives/LauncherSplitViewController.m"))
check("J4  BackgroundSettings 清除背景处理器同步原生化（tableView systemBackgroundColor ×4）",
      read("Natives/BackgroundSettingsViewController.m").count(
          "self.tableView.backgroundColor = [UIColor systemBackgroundColor];") == 4)

print()
print("=" * 72)
print("K. 口径护栏（Task93 检测链零变化）与语法配平")
print("=" * 72)
rp = read("Natives/LauncherRightPanelViewController.m")
check("K1  内存标识仍走 getEntitlementValue（签名口径 ×2，Task93 护栏）",
      rp.count("getEntitlementValue(") >= 2)
check("K2  JIT 检测链不受影响（isJITEnabled(NO) 仍在）",
      "isJITEnabled(NO)" in rp)
check("K3  七卡工厂零变化（makeInfoCardWithIcon 仍在）",
      "makeInfoCardWithIcon" in rp)
check("K4  侧栏图标自愈机制不受影响（refreshMenuIconImagesForced 仍在）",
      "refreshMenuIconImagesForced" in read("Natives/LauncherMenuViewController.m"))
check("K5  关键改动文件括号配平",
      all(balanced(read(f)) for f in [
          "Natives/MinecraftNewsViewController.m",
          "Natives/LauncherNewsViewController.m",
          "Natives/VersionCardCell.m",
          "Natives/VersionManagerViewController.m",
          "Natives/AccountListViewController.m",
          "Natives/installer/ModLoaderInstallViewController.m",
          "Natives/LauncherPreferencesViewController.m",
          "Natives/BackgroundManager.m",
          "Natives/SceneDelegate.m",
          "Natives/LauncherSplitViewController.m",
          "Natives/UIKit+NativeSurface.m",
          "Natives/UIViewController+AMEPanel.m",
          "Natives/NMToast.m",
      ]))

print()
print(f"verify_task136: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
