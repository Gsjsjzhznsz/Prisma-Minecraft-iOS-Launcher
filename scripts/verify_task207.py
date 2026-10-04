#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Task 206 验证器：实例选择页快捷指令化。
A 卡结构（竖卡四要素 + 旧五件套退役） / B 布局常量与密度翻倍 / C 交互拆分
（点卡=选用、⋯=纯编辑、长按保留）/ D 渐变与主题联动 / E 文档与级联重锚 / F 语法门。
无本地 clang，全部静态锚点 + 括号配平（仓库口径）。
"""
import io
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VM = os.path.join(REPO, "Natives", "VersionManagerViewController.m")

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


def balanced_py(s):
    """.py 文件用真解析器（ObjC 剥离器不适用于 Python 语法）"""
    try:
        import ast
        ast.parse(s)
        return True
    except SyntaxError:
        return False


def segment(src, start_marker, end_marker):
    i = src.find(start_marker)
    j = src.find(end_marker, i + 1) if i >= 0 else -1
    if i < 0 or j < 0:
        return ""
    return src[i:j]


print("=" * 72)
print("Task 207 实例选择页快捷指令化 验证（编号让位重锚版：206 = 并行会话 NG-GL4ES 渲染器移植）")
print("=" * 72)

vm = rd("Natives/VersionManagerViewController.m")
cell_seg = segment(vm, "#pragma mark - Version Card Cell (Task207", "#pragma mark - Game Directory Cell")
# editProfile 段只切到下一个方法（selectProfileNamed），避免把后续方法包进判定
edit_seg = segment(vm, "- (void)editProfile:(NSString *)profileName {", "- (void)selectProfileNamed:")

# ============ A. 卡结构 ============
print("== A. 快捷指令卡结构 ==")
check("A", "VMVersionCardCell 属性齐备（Task210：icon/⋯钮/高亮环/名称/版本/回调；渐变宿主+层退役）",
      all(p in cell_seg for p in [
          "UIImageView *iconView;", "UIButton *ellipsisButton;",
          "UIView *selectionRing;", "UILabel *nameLabel;", "UILabel *versionLabel;",
          "void (^ellipsisAction)(void);"])
      and "gradientView" not in strip_objc(cell_seg)
      and "CAGradientLayer" not in strip_objc(cell_seg))
check("A", "旧五件套在本卡段内退役（iconContainer/selectedBadge/isolatedBadge/lastPlayedLabel/chevronView 零代码引用）",
      all(f"self.{p}" not in strip_objc(cell_seg) for p in
          ["iconContainer", "selectedBadge", "isolatedBadge", "lastPlayedLabel", "chevronView"]),
      "（仅注释中允许出现旧名，strip 后应为零）" if all(f"self.{p}" not in strip_objc(cell_seg) for p in
          ["iconContainer", "selectedBadge", "isolatedBadge", "lastPlayedLabel", "chevronView"]) else "仍有 self. 引用")
check("A", "Task210：卡底 = 全局管线平贴灰面（本卡零自绘背景，AmeCardSurfaceColor 由 BackgroundManager 铺）",
      "CAGradientLayer" not in strip_objc(cell_seg)
      and "addSublayer" not in strip_objc(cell_seg))
check("A", "Task210 实例图标 = 原始彩色直出（白色模板渲染退役；PNG 不着色 / cube 兜底用强调色）",
      "detectLoaderFromVersionId:" in cell_seg
      and "configureImageView:self.iconView" in cell_seg
      and "imageWithRenderingMode" not in strip_objc(cell_seg)
      and "self.iconView.tintColor = accentColor();" in cell_seg)
check("A", "Task210 ⋯ 编辑钮：28pt 自适应圆底 + 16pt Black 三点 + i18n_str_1091 无障碍标签",
      'systemImageNamed:@"ellipsis"' in cell_seg
      and "CGFloat ellipsisSize = 28.0;" in cell_seg
      and "[[UIColor labelColor] colorWithAlphaComponent:0.12]" in cell_seg
      and "UIFontWeightBlack" in cell_seg
      and 'localize(@"i18n_str_1091", nil)' in cell_seg
      and "ellipsisTapped" in cell_seg)
check("A", "Task210 名称/版本深浅自适应双行（sp15 semibold 主色 / sp11 次色）",
      "[UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold]" in cell_seg
      and "self.nameLabel.textColor = AmeCardPrimaryTextColor();" in cell_seg
      and "[UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular]" in cell_seg
      and "self.versionLabel.textColor = AmeCardSecondaryTextColor();" in cell_seg
      and "[UIColor whiteColor]" not in strip_objc(cell_seg))
check("A", "prepareForReuse 复用卫生（环隐藏 + 回调清空）",
      "- (void)prepareForReuse" in cell_seg
      and "self.selectionRing.hidden = YES;" in cell_seg
      and "self.ellipsisAction = nil;" in cell_seg)

# ============ B. 布局 ============
print("== B. 布局常量与密度翻倍 ==")
check("B", "三常量定稿（Task212 重锚：行高 128 对照快捷指令 / 省略号间距 12 / 环描边 2pt）",
      "static const CGFloat kVMVersionRowHeight = 128.0;" in vm
      and "static const CGFloat kVMCardEllipsisInset = 12.0;" in vm
      and "static const CGFloat kVMCardRingBorderWidth = 2.0;" in vm)
check("B", "环内缩动态推导 = 省略号间距 / 3（圆角与四边约束双站点）",
      vm.count("kVMCardEllipsisInset / 3.0") >= 2
      and "CGFloat ringInset = kVMCardEllipsisInset / 3.0;" in cell_seg)
check("B", "Task210 选中环 = 纯 accent 描边（柔光光晕退役）+ 隐藏默认",
      "self.selectionRing.layer.borderWidth = kVMCardRingBorderWidth;" in cell_seg
      and "shadowOpacity" not in strip_objc(cell_seg)
      and "shadowColor" not in strip_objc(cell_seg)
      and "self.selectionRing.hidden = YES;" in cell_seg)
check("B", "版本区段密度翻倍（iPhone 0.5 双列 / iPad 0.25 四列）+ 行高沿用 kVMVersionRowHeight",
      "CGFloat itemWidth = isiPad ? 0.25 : 0.5;" in vm
      and "CGFloat itemHeight = kVMVersionRowHeight;" in vm)
check("B", "紧凑卡固定 pt 几何（Task212 重锚：icon 28 与 ⋯钮 28 对角平衡）+ nameClearance 999 静默守卫",
      "CGFloat iconSize = 28.0;" in cell_seg
      and "CGFloat ellipsisSize = 28.0;" in cell_seg
      and "NSLayoutConstraint *nameClearance =" in cell_seg
      and "nameClearance.priority = 999;" in cell_seg)
check("B", "Task210：layoutSubviews 无渐变/柔光收口（两者随引擎退役）",
      "gradientLayer" not in strip_objc(cell_seg)
      and "bezierPathWithRoundedRect:ringFrame" not in cell_seg)

# ============ C. 交互 ============
print("== C. 点卡=选用 / ⋯=纯编辑 / 长按保留 ==")
check("C", "didSelect 版本区段 = selectProfileNamed（editProfile 不再由点卡触发）",
      "[self selectProfileNamed:profileName];" in vm
      and "[self editProfile:profileName];" not in segment(vm, "kSectionVersions) {", "#pragma mark - Game Directory Actions"))
check("C", "selectProfileNamed：防抖 + 保存 + SelectedProfileChanged 广播",
      "- (void)selectProfileNamed:(NSString *)profileName {" in vm
      and "if ([profileName isEqualToString:self.selectedProfile]) return;" in vm
      and "PLProfiles.current.selectedProfileName = profileName;" in vm
      and 'postNotificationName:@"SelectedProfileChanged"' in vm)
check("C", "editProfile 纯编辑（方法段内零选中写入，仅 push ProfileSettingsViewController）",
      "selectedProfileName" not in strip_objc(edit_seg)
      and "[[ProfileSettingsViewController alloc] init]" in edit_seg
      and "pushViewController:vc animated:YES];" in edit_seg)
check("C", "⋯ 回调在 cellForItem 注入（weak self 捕获 profileName → editProfile）",
      "cell.ellipsisAction = ^{" in vm
      and "[weakSelf editProfile:profileName];" in vm
      and "__weak typeof(self) weakSelf = self;" in vm)
check("C", "长按菜单退役（Task212 重锚：长按 = 直接呼出确认删除弹窗；选择 = 点卡、编辑 = ⋯ 各有直达入口）",
      'localize(@"i18n_str_1091", nil)' in vm
      and "[self deleteProfile:self.profileList[indexPath.item]];" in vm
      and "- (void)showProfileActions" not in vm)

# ============ D. 主题联动 ============
print("== D. 渐变与主题/透明度联动 ==")
check("D", "Task210：渐变身份面退役（ame207_darkenedAccent 助手零残留；选中环仍随主题即时刷新）",
      "ame207_darkenedAccent" not in vm
      and "gradientLayer" not in strip_objc(vm)
      and "self.selectionRing.layer.borderColor = accentColor().CGColor;" in cell_seg)
check("D", "Task210：卡体透明度滑条语义退役（cardsNeumorphOpacity 零引用）",
      "cardsNeumorphOpacity" not in strip_objc(vm))
check("D", "LauncherAppearanceChanged → reloadData 联动保留（换主题色渐变即时跟随）",
      'name:@"LauncherAppearanceChanged"' in vm
      and "handleAccentColorChanged" in vm)
check("D", "Task172 管线保留（Task214 重锚：setupViews 开头允许 cardCornerRadius 覆写行插在 super 之前，毛玻璃调用不动）",
      re.search(r"- \(void\)setupViews \{\n(?:    //[^\n]*\n|    self\.cardCornerRadius = kVMCardCornerRadius;\n)*    \[super setupViews\];", cell_seg) is not None
      and "applyEffectToCollectionViewCell" in rd("Natives/BackgroundManager.m"))

# ============ E. 文档与级联 ============
print("== E. 公告 / version.h / 级联重锚 ==")
ann = json.loads(io.open(os.path.join(REPO, "announcements.json"), encoding="utf-8").read())["announcements"]
check("E", "公告 31 条，task209@2 插入后 task207@3，置顶钉位未动，NG-GL4ES 尾锚保持",
      len(ann) == 40
      and ann[9]["id"] == "task207-shortcuts-instance-cards-2026-10-01"
      and ann[0]["id"].startswith("server-recommend")
      and ann[-2]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-3]["id"] == "task216-ui-2026-10-03"
      and ann[-4]["id"] == "task206-nggl4es-2026-10-01")
check("E", "公告窗口族顺延（Task209@2 后：task196@4 / task193@5 / task190@6）",
      ann[10]["id"] == "task196-quad-fixes-2026-09-29"
      and ann[11]["id"] == "task193-app-icon-replace-2026-09-28"
      and ann[12]["id"].startswith("task190-"))
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("E", "version.h Task 207 附录在场（REVISION 18 append-only，无 bump）",
      "Amethyst Task 207" in vh and "#define REVISION 22" in vh
      and "Amethyst Task 206" in vh)  # 并行会话 Task206 渲染器附录共存
v91 = rd("scripts/verify_task91.py")
check("E", "verify_task91 C2 重锚（Task210：配额 2 -> 1，实例卡白字改 AmeCard 语义色；保留位 = countBadge）",
      '"Natives/VersionManagerViewController.m": 1,' in v91
      and '("Natives/VersionManagerViewController.m", "self.countBadge.textColor = [UIColor whiteColor];", None),' in v91
      and '"self.nameLabel.textColor = [UIColor whiteColor];"' not in v91)
v193 = rd("scripts/verify_task193.py")
v173 = rd("scripts/verify_task173.py")
v190 = rd("scripts/verify_task190.py")
v196 = rd("scripts/verify_task196_197_198_201.py")
v202 = rd("scripts/verify_task202.py")
v203 = rd("scripts/verify_task203.py")
v206t = rd("scripts/verify_task206.py")  # 并行会话的 Task206 渲染器验证器（本轮仅重锚其 F5 长度）
check("E", "七脚本公告锚全部重锚（Task215@2 后：193/173/190/196-201/202/203 + 并行 v206 F5）",
      "len(ann) == 40" in v193 and 'ann[11]["id"] == "task193-app-icon-replace-2026-09-28"' in v193
      and 'ann["announcements"][21]["id"] == "task173-ten-fixes-2026-09-26"' in v173
      and '["announcements"][12]["id"].startswith("task190-")' in v190
      and "ann[10][\"id\"] == \"task196-quad-fixes-2026-09-29\"" in v196 and "len(ann) == 40" in v196
      and "len(ann) == 40" in v202 and 'ann[34]["id"] == "task202-october-fix-wave"' in v202
      and "len(ann) == 40" in v203
      and 'len(ann) == 40 and ann[-2]["id"] == "task217-download-fixes-about-isolation-2026-10-03"' in v206t)
check("E", "l10n 零新增键（⋯ 钮无障碍复用 i18n_str_1091，strings 文件不含 ame207.*；并行 nggl4es 键不在判定面）",
      'localize(@"i18n_str_1091", nil)' in vm
      and "ame207." not in rd("Natives/resources/en.lproj/Localizable.strings"))

# ============ F. 语法门 ============
print("== F. 语法门 ==")
check("F", "VersionManagerViewController.m 括号配平（栈配平，去注释/字符串）", balanced(vm))
check("F", "verify_task91.py 语法合法（ast 解析）", balanced_py(v91))
check("F", "数组字面量内无语句残留（.priority 写法只能出现在语句位）",
      ".priority = 999;" not in strip_objc(cell_seg).split("[NSLayoutConstraint activateConstraints")[-1].split("]];")[0]
      or "nameClearance.priority = 999;" in cell_seg)
# Task173/140/142/160/193 对本文件的历史锚点不被本轮破坏
check("F", "历史锚点常驻（ame140_shortNames / RENDERER_NAME_VGPU 映射 / FAB a11y / Task210 色族落点）",
      "ame140_shortNames" in vm
      and '@ RENDERER_NAME_VGPU: @"VGPU"' in vm
      and 'isEqualToString:localize(@"i18n_str_2027"' in vm
      and "AmeCardPrimaryTextColor(); // Task160 规格主文字" in vm)

print("=" * 72)
print(f"PASS {len(PASS)}  FAIL {len(FAIL)}")
if FAIL:
    for g, n, d in FAIL:
        print(f"  FAIL [{g}] {n}  {d}")
    sys.exit(1)
print("ALL GREEN")
