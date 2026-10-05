#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task141.py —— Task 141 校验器

用户七项需求：
  1. 未选择账号时主页欢迎卡显示默认头像（DefaultAccount，与账户列表同源），
     不再观感空白。
  2. 欢迎卡第二行（原灰字问候语）改为公告标题行：喇叭图标 + 公告标题
     （字号与"欢迎回来,玩家名称!"一致 21pt bold）+ 公告卡同款"查看详情"按钮；
     无公告数据回退问候语。
  3. 下载页版本行主标题字号不得小于时间灰字：版本号缩小下限 0.7→0.75
     （16pt×0.75=12pt = 日期字号，最坏情况两者同字号）。
  4. 实例管理"内存分配"由枚举列表改为弹出小窗口：顶部灰字（当前内存：xMB）
     + 拉条（512MB → 启动器检测的最大可分配 maxMemory = 物理内存×0.8）。
  5. 排查"…"截断逻辑改为缩小字号：至少修复实例管理"JVM启动参数"行标题
     （Value1 cell 被 200pt accessoryView 挤压）与下载页版本列表时间
     （日期尾锚被短版本号拖窄 → "2026-…"）。
  6. 启动内存决策链排查：原由全局 java.auto_ram/java.allocated_memory 决定，
     实例 allocatedMemory 写 general.ram_allocation 无人读取（死项）。
     按用户指令改为实例决定：新共享助手 ame141_currentLaunchAllocMem
     （JavaLauncher -Xmx 与 SurfaceVC Jetsam 上限同源，Task68 漂移根治）；
     全局设置两行删除；实例未设置时回退原自动比例。
  7. MC 新闻页贴边单列：旧布局组宽 1.0 但子项 0.5 且仅一项 → 卡片贴左半宽
     右侧留白；改为 fractional 1.0 贴于窗口 + 禁横向回弹 + 侧边 inset 退役；
     等高机制不变。

分节：A 欢迎卡(1,2) / B 版本行(3,5) / C 实例设置(4,5) / D 内存决策链(6) /
      E 新闻页(7) / F l10n / G 语法配平
"""
import os
import re
import subprocess
import sys

# Task175：可移植化（169/135/164/165/173 家法——两级 dirname，防沙箱路径漂移）
REPO = os.environ.get("TASK141_REPO",
                      os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PASS = 0
FAIL = 0


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as f:
        return f.read()


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
print("A. 欢迎卡：默认头像首帧 + 问候语回归（Task149 重锚：Item 1 + 2 返工）")
print("=" * 72)
home = read("Natives/LauncherNewsViewController.m")
home_code = strip_objc(home)
check("A1  无头像分支使用 DefaultAccount 默认头像（账户列表同源；Asset 缺失回退 SF 占位）",
      'UIImage *defaultAvatar = [UIImage imageNamed:@"DefaultAccount"];' in home
      and "cell.avatarImageView.tintColor = nil;" in home)
check("A2  Task149 重锚：公告标题行整体退役（icon/label/button/rowStack 引用清零）",
      all(x not in home for x in [
          'self.announceIconView = [[UIImageView alloc] init];',
          'self.announceLabel = [[UILabel alloc] init];',
          'self.detailButton = [UIButton buttonWithType:UIButtonTypeSystem];',
          'announceRowStack']))
check("A3  Task149 重锚：问候语行回归（14pt medium，cellForItem 填充 festivalGreeting；Task160 文字色规格化）",
      "self.greetingLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];" in home
      and "self.greetingLabel.textColor = AmeCardSecondaryTextColor(); // Task160" in home
      and "cell.greetingLabel.text = festivalGreeting();" in home)
check("A4  Task149 重锚：公告预览回归主页公告卡（cellForItem 不再引用 detailButton；公告卡标题行/内联按钮在位）",
      "cell.detailButton" not in home
      and "cell.titleLabel.text = ann.title;" in home
      and "cell.actionButton addTarget:self action:@selector(openAnnouncementActionURL)" in home)
check("A5  Task149 重锚：欢迎堆叠第二行 = 问候语（greetingLabel 入栈）",
      "initWithArrangedSubviews:@[self.welcomeLabel, self.greetingLabel]" in home)
check("A6  Task149 重锚：greetingLabel 属性复位（旧退役断言反转）",
      "@property (nonatomic, strong) UILabel *greetingLabel;" in home)
check("A7  欢迎堆叠仍相对头像纵轴居中（Task136 语义保留）",
      "welcomeStack.centerYAnchor constraintEqualToAnchor:self.avatarImageView.centerYAnchor" in home_code)

print()
print("=" * 72)
print("B. 版本行：标题字号下限 + 日期贴边不截断（Item 3 + 5）")
print("=" * 72)
vc = read("Natives/VersionCardCell.m")
check("B1  版本号缩小下限 0.7→0.75（16×0.75=12pt=日期字号，标题不再比灰字小）",
      "self.versionLabel.minimumScaleFactor = 0.75;" in vc
      and "self.versionLabel.minimumScaleFactor = 0.7;" not in vc)
check("B2  日期右锚 chevron 左侧 8pt（不再被短版本号拖窄成 2026-…）",
      "[self.dateLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8]," in vc
      and "[self.dateLabel.trailingAnchor constraintEqualToAnchor:self.topRowStack.trailingAnchor]," not in vc)
check("B3  日期保底缩字（adjustsFontSizeToFitWidth + minScale 0.7 保留）",
      "self.dateLabel.adjustsFontSizeToFitWidth = YES;" in vc)

print()
print("=" * 72)
print("C. 实例设置：内存弹窗拉条 + 行标题缩字（Item 4 + 5）")
print("=" * 72)
ps = read("Natives/ProfileSettingsViewController.m")
ps_code = strip_objc(ps)
check("C1  枚举 actionSheet 列表退役（旧 for-options 循环不再存在）",
      "NSMutableArray *options = [NSMutableArray array];" not in ps_code
      and "for (NSNumber *memNum in options)" not in ps_code)
check("C2  Task159 重锚：内存弹窗 = 输入框 alert（卡片/转场符号清零；sheet 仍退役）",
      "[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {" in ps_code
      and "Ame157MemoryAllocatorCard" not in ps_code
      and "UIModalPresentationCustom" not in ps_code
      and "UISheetPresentationControllerDetent.mediumDetent" not in ps_code)
check("C3  Task159 重锚：弹窗标题/简介键（adjust_title/adjust_message；memory.current 退役）",
      'localize(@"memory.adjust_title", nil)' in ps
      and 'localize(@"memory.adjust_message", nil)' in ps
      and "memory.current" not in ps)
check("C4  Task159 重锚：数值范围（下限 512 / 上限 self.maxMemory，空输入落 512）",
      "if (ame159_value < 512) ame159_value = 512;" in ps_code
      and "if (ame159_value > self.maxMemory) ame159_value = self.maxMemory;" in ps_code
      and "NSInteger ame159_initial = self.allocatedMemory > 0 ? self.allocatedMemory : 512;" in ps_code)
check("C5  Task159 重锚：确定写回（退出自动态 → saveSettings → reloadAllTableViews）",
      "self.memoryAutoEnabled = NO;" in ps_code
      and "[self saveSettings];" in ps_code
      and "[self reloadAllTableViews];" in ps_code)
check("C6  行标题/详情永不截断改缩字（JVM 启动参数行修复）",
      "cell.textLabel.adjustsFontSizeToFitWidth = YES;" in ps_code
      and "cell.textLabel.minimumScaleFactor = 0.6;" in ps_code
      and "cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;" in ps_code)
check("C7  maxMemory 口径不变（物理内存×0.8，用户参考值 6116MB 即此口径）",
      "self.maxMemory = (NSInteger)(self.maxMemory * 0.8);" in ps_code)

print()
print("=" * 72)
print("D. 内存决策链：实例决定 + 全局行删除（Item 6）")
print("=" * 72)
utils_h = read("Natives/utils.h")
utils_m = read("Natives/utils.m")
jl = read("Natives/JavaLauncher.m")
jl_code = strip_objc(jl)
svc = read("Natives/SurfaceViewController.m")
prefs = read("Natives/LauncherPreferencesViewController.m")
prefs_code = strip_objc(prefs)
rp = read("Natives/LauncherRightPanelViewController.m")
check("D1  共享助手声明+实现（utils.h/.m：实例 allocatedMemory 优先，未设置回退自动比例）",
      "int ame141_currentLaunchAllocMem(void);" in utils_h
      and "int ame141_currentLaunchAllocMem(void) {" in utils_m
      and '[profile[@"allocatedMemory"] integerValue]' in utils_m
      # Task223 L2 再锚：单 entitlement 判定升级双路（memorystatus ||
      # increased-memory-limit，raisedCeiling）；语义不变（抬升过 0.5 否则 0.25）。
      and 'CGFloat autoRatio = raisedCeiling ? 0.5 : 0.25;' in utils_m
      and 'getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit")' in utils_m)
check("D2  JavaLauncher -Xmx 读共享助手（旧 auto_ram/allocated_memory 双分支退役）",
      "int allocmem = ame141_currentLaunchAllocMem();" in jl_code
      and 'getPrefBool(@"java.auto_ram")' not in jl_code
      and 'getPrefInt(@"java.allocated_memory")' not in jl_code)
check("D3  SurfaceVC Jetsam 上限读同一助手（Task68 一致性由结构保证）",
      "int allocmem = ame141_currentLaunchAllocMem();" in strip_objc(svc))
check("D4  全局设置两行删除（auto_ram 开关 + allocated_memory 滑条）",
      '@{@"key": @"auto_ram",' not in prefs_code
      and '@{@"key": @"allocated_memory",' not in prefs_code
      and "Task141" in prefs)
check("D5  Task159 重锚：实例内存写回链路（确定 → allocatedMemory 落值；loadSettings 读取字段同前）",
      "self.allocatedMemory = ame159_value;" in ps_code
      and 'self.allocatedMemory = [self.profile[@"allocatedMemory"] integerValue];' in ps)
check("D5b  Task159 重锚：转场/呈现链退役（transitioningDelegate / 动画器类清零）",
      "transitioningDelegate" not in ps_code
      and "Ame157CardTransitionAnimator" not in ps_code)
check("D6  validateVirtualMemorySpace 口径保留（虚存校验不回退）",
      "if (!validateVirtualMemorySpace(allocmem)) {" in jl_code)
check("D7  启动日志锚点保留（Max RAM allocation 行在）",
      '[JavaLauncher] Max RAM allocation is set to %d MB' in jl)

print()
print("=" * 72)
print("E. MC 新闻页：双列恢复 + 简介完整显示 + 禁横向滑（Task149 重锚）")
print("=" * 72)
mcnews = read("Natives/MinecraftNewsViewController.m")
mcnews_code = strip_objc(mcnews)
check("E1  Task149 重锚：恢复双列并列排（每组两个 0.5 宽子项 + interItemSpacing）",
      "fractionalWidthDimension:0.5]" in mcnews_code
      and "subitems:@[ame149_itemA, ame149_itemB]" in mcnews_code)
check("E2  Task149 重锚：双列侧边距（8,8,8,8，公告列表页同款语言）",
      "UIEdgeInsetsMake(8, 8, 8, 8)" in mcnews_code
      and "UIEdgeInsetsMake(8, 0, 8, 0)" not in mcnews_code)
check("E3  禁横向回弹（alwaysBounceHorizontal = NO，Task141 用户指令幸存）",
      "self.collectionView.alwaysBounceHorizontal = NO;" in mcnews_code)
check("E4  Task149 重锚：等高机制改自 sizing（简介不截断：numberOfLines 0 + estimated 高度；固定模板实测删除）",
      "newsCardFixedHeight" not in mcnews_code
      and "_summaryLabel.numberOfLines = 0;" in mcnews_code
      and "estimatedDimension:280" in mcnews_code)

print()
print("=" * 72)
print("F. l10n：memory.current / memory.apply 四语言一致")
print("=" * 72)
langs = ["en", "zh-CN", "zh-Hans", "zh-Hant"]
keysets = {}
for lang in langs:
    src = read(f"Natives/resources/{lang}.lproj/Localizable.strings")
    keysets[lang] = set(re.findall(r'^"([^"]+)"\s*=', src, flags=re.M))
check("F1  四语言 key 集合完全一致", len({frozenset(v) for v in keysets.values()}) == 1)
check("F2  Task159 新 key 存在于全部语言（五新键 + auto_row/apply 幸存）",
      all({"memory.adjust_title", "memory.adjust_message", "memory.apply", "memory.auto_row",
           "preference.manage_runtime.default.126", "preference.manage_runtime.footer.java25",
           "preference.profile.title.resolution_scale"} <= keysets[l] for l in langs))
check("F3  简繁中文文案正确（Task159 新键抽查）",
      '"memory.adjust_title" = "调整内存分配";' in read("Natives/resources/zh-Hans.lproj/Localizable.strings")
      and '"memory.adjust_title" = "調整記憶體分配";' in read("Natives/resources/zh-Hant.lproj/Localizable.strings")
      and '"preference.profile.title.resolution_scale" = "解析度縮放";' in read("Natives/resources/zh-Hant.lproj/Localizable.strings"))
check("G1  关键改动文件括号配平（字符串/注释感知）",
      all(balanced(read(f)) for f in [
          "Natives/LauncherNewsViewController.m",
          "Natives/VersionCardCell.m",
          "Natives/ProfileSettingsViewController.m",
          "Natives/JavaLauncher.m",
          "Natives/SurfaceViewController.m",
          "Natives/LauncherPreferencesViewController.m",
          "Natives/MinecraftNewsViewController.m",
          "Natives/utils.h",
          "Natives/utils.m",
      ]))
check("G2  新增 UIColor 选择器白名单审计",
      not [m for m in set(re.findall(r"\[UIColor (\w+)\]",
                                     "".join(read(f) for f in [
                                         "Natives/LauncherNewsViewController.m",
                                         "Natives/ProfileSettingsViewController.m",
                                         "Natives/VersionCardCell.m",
                                         "Natives/MinecraftNewsViewController.m",
                                         "Natives/LauncherPreferencesViewController.m"])))
           if m not in {
               "systemBackgroundColor", "labelColor", "secondaryLabelColor", "tertiaryLabelColor",
               "placeholderTextColor", "separatorColor", "secondarySystemBackgroundColor",
               "secondarySystemGroupedBackgroundColor", "tertiarySystemGroupedBackgroundColor",
               "tertiarySystemFillColor", "secondarySystemFillColor", "systemGrayColor",
               "systemBlueColor", "systemPurpleColor", "systemRedColor", "systemGreenColor",
               "systemOrangeColor", "whiteColor", "blackColor", "clearColor",
               "groupTableViewBackgroundColor", "systemGroupedBackgroundColor", "grayColor",
               "systemTealColor", "systemPinkColor", "systemGray3Color", "quaternaryLabelColor",
               "systemIndigoColor"}])
check("G3  检测口径护栏零变化（getEntitlementValue ×2 / isJITEnabled(NO)+TXM）",
      read("Natives/LauncherRightPanelViewController.m").count('getEntitlementValue(@"com.apple.developer.kernel.') == 2
      and "isJITEnabled(NO)" in strip_objc(read("Natives/LauncherRightPanelViewController.m")))
# Task175：白名单从 verify_task* 放宽到 scripts/ 全体（task175 法证/语法门
# 脚本与历届 task167_announcements / task170_announcements / task168_baseline_sweep
# 同族——"scripts/ 下的一切皆可提交"是历次会话反复学到的同一条教训）。
# Task217：+.gitignore（仓库卫生轮会正常触碰——本轮 __pycache__ untrack +
# ignore 规则即触发过 141 G4 -> 168 E7 -> 202 J -> 209 D6 的脏树传播链）。
check("G4  工作区改动仅限预期文件集（提交后自愈；Task175：scripts/ 全体入白名单；"
      "Task202：docs/surveys/ 入白名单——Task201 报告曾被 /docs gitignore 静默吞掉，"
      "本轮强制入库；Task217：+.gitignore；Task218：README 双语 + CI 工作流 + 根级"
      " entitlements——仓库名去 air 与包名 .air 过渡的合法触碰面）",
      all(ln[3:].strip().startswith(("Natives/", "scripts/", "worklog.md", "announcements.json",
                                     "JavaApp/", "help-faq.json", "docs/", "Makefile", ".gitignore",
                                     "README.md", "README_CN.md", "README_EN.md", ".github/", "entitlements."))
          for ln in subprocess.run(["git", "-C", REPO, "status", "--porcelain"],
                                   capture_output=True, text=True).stdout.splitlines()
          if ln.strip()))

print()
print(f"verify_task141: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
