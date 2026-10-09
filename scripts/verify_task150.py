#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task150.py —— Task 150 校验器

标题：[可撤销] 删除渲染器全局控制 及 Sodium 组件安装

用户需求：
  1. 启动器设置页面的渲染器选择删掉；实例页面的"跟随全局渲染器"开关删掉；
     相关代码一并退役（PLProfiles 的 video.renderer 回退、设置页 get/set
     分支、shadow toast、rendererKeys/rendererList 属性、开关行/映射/方法）。
     每个实例强制单独选择渲染器；无显式设置的存量实例缺省 auto（用户确认；
     1.17+ 自动解析为 MobileGL Vulkan 直连）。
  2. 实例页组件安装：复用 Fabric API 安装逻辑开一个 Sodium 选项（火焰图标），
     一键安装 Sodium + Podium（Modrinth 搜索，标题精确匹配避开 Sodium Extra /
     Podium Port；按游戏版本 + fabric 加载器匹配版本；下载进实例 mods/ 目录）；
     仅 Fabric 实例可用（与 Fabric API 同门槛）。Podium = 禁用 Sodium 的
     PojavLauncher 检查，与 Task145 的 POJAV_RENDERER 导出收敛互为双保险。

分节：A 设置页退役 / B 实例页强制单选 / C 启动链 profile→auto /
      D Sodium 组件安装 / E l10n（Task159 后基线 2727）/ F 发布资产 / G 配平
"""
import json
import os
import re
import sys

# Task223 修复：仓库更名+搬移后的存量路径漂移（workspace/Air-Minecraft-iOS-Launcher
# 已不存在）——默认改为脚本所在仓库根，环境变量覆盖口保留。
REPO = os.environ.get("TASK150_REPO", os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
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
print("A. 设置页渲染器全局控制退役（LauncherPreferencesViewController.m）")
print("=" * 72)
lp = read("Natives/LauncherPreferencesViewController.m")
lp_code = strip_objc(lp)
check("A1  渲染器行字典退役（key renderer 不再出现在 prefContents）",
      '@{"key": @"renderer",' not in lp)
check("A2  getPreference video.renderer 分支退役（STORAGE 键读取清零）",
      'if ([section isEqualToString:@"video"] && [key isEqualToString:@"renderer"]) {' not in lp_code
      and 'getPrefObject(@"video.renderer")' not in lp_code)
check("A3  setPreference video.renderer 分支 + ame140_writeRendererGlobal 块退役",
      'ame140_writeRendererGlobal' not in lp_code
      and 'setPrefObject(@"video.renderer"' not in lp_code)
check("A4  遮蔽告警 toast 键不再引用（preference.warning.renderer_shadowed_by_profile）",
      'preference.warning.renderer_shadowed_by_profile' not in lp_code)
check("A5  rendererKeys/rendererList 属性与赋值退役（唯一消费者 = 已删行）",
      'self.rendererKeys' not in lp and 'rendererKeys, *rendererList' not in lp)
check("A6  MobileGlues 后端行幸存（renderer_backend 分支原位，Task142 语义不变）",
      '[key isEqualToString:@"renderer_backend"]' in lp
      and 'return ame142_effective_backend_key();' in lp)

print()
print("=" * 72)
print("B. 实例页强制单选（ProfileSettingsViewController.m）")
print("=" * 72)
ps = read("Natives/ProfileSettingsViewController.m")
ps_code = strip_objc(ps)
check("B1  跟随全局渲染器行退役（advancedRows 只以渲染器开头）",
      'NSMutableArray *advancedRows = [NSMutableArray arrayWithArray:@[@"渲染器"]];' in ps
      and '@"跟随全局渲染器"' not in ps_code)
check("B2  开关构建/回调方法退役（签名级清零）",
      '- (UISwitch *)buildRendererFollowSwitch' not in ps_code
      and '- (void)rendererFollowSwitchChanged' not in ps_code)
check("B3  渲染器行永远可选（无置灰分支、无 nil 显示态）",
      'cell.detailTextLabel.text = [self rendererDisplayName:self.selectedRenderer];' in ps
      and '[self rendererDisplayName:nil]' not in ps_code
      and 'if (self.selectedRenderer != nil) {' not in ps_code)
check("B4  didSelect 渲染器行直接弹选择器",
      ps_code.count('[self showRendererSelector];') >= 1
      and 'rendererFollowSwitchChanged' not in ps_code)
check("B5  loadSettings 缺省 auto（nil → @\"auto\"）",
      '? ame140_rendererRaw : @"auto";' in ps)
check("B6  saveSettings 显式写入（缺失防御性写 auto，键不再被删除）",
      'existing[@"renderer"] = @"auto";' in ps
      and '[existing removeObjectForKey:@"renderer"];' not in ps_code)
check("B7  rendererDisplayName nil 分支显示 auto",
      'return ame_renderer_display_name(@"auto");' in ps)
check("B8  弹窗锚点回到第 0 行（渲染器行重新是高级设置首行）",
      '[self cellForGlobalSection:3 row:0];' in ps)
check("B9  家族键归一与迁移保留（ame142_migrateRendererStorage 原位）",
      'ame142_migrateRendererStorage();' in ps
      and 'ame140_rendererRaw = @ RENDERER_KEY_MG;' in ps)

print()
print("=" * 72)
print("C. 启动链 profile→auto（PLProfiles.m + LauncherPreferences.m）")
print("=" * 72)
pp = read("Natives/PLProfiles.m")
lpm = read("Natives/LauncherPreferences.m")
pp_code = strip_objc(pp)
check("C1  prefDefaults 的 renderer→video.renderer 回退退役（注释留档可撤销）",
      '        // @"renderer": @"video.renderer",' in pp
      and '        @"renderer": @"video.renderer",' not in pp_code)
check("C2  nil 守卫（getPrefObject(nil) 崩溃防护：prefKey 判空后返回）",
      'id prefKey = prefDefaults[key];' in pp
      and 'return prefKey ? getPrefObject(prefKey) : nil;' in pp)
check("C3  ame_effective_renderer 解析链注释更新（profile 键 → auto）",
      'resolveKeyForCurrentProfile' in lpm
      and 'renderer = @"auto";' in lpm)
check("C4  JavaLauncher 仍经 ame_effective_renderer 单一事实源（零改动幸存）",
      'NSString *renderer = ame_effective_renderer();' in read("Natives/JavaLauncher.m"))

print()
print("=" * 72)
print("D. Sodium 组件安装（ProfileSettingsViewController.m）")
print("=" * 72)
check("D1  组件安装区新增 Sodium 行（Fabric API / Sodium + Iris Shaders / OptiFine，Task157 行名升级）",
      '@[@"Fabric API", @"Sodium + Iris Shaders", @"TouchController", @"OptiFine"]' in ps)
check("D2  火焰图标（flame.fill）+ Fabric 门槛文案（2043/885，与 Fabric API 行同构）",
      '[UIImage systemImageNamed:@"flame.fill"]' in ps
      and ps.count('cell.detailTextLabel.text = [self isFabricProfile] ? localize(@"i18n_str_2043", nil) : localize(@"i18n_str_885", nil);') == 2)
check("D3  didSelect 接入 installSodiumStandalone",
      '[self installSodiumStandalone];' in ps)
check("D4  Fabric 门槛 + 游戏版本解析（isFabricProfile / currentGameVersion 复用）",
      ps_code.count('if (![self isFabricProfile]) {') >= 2
      and '[self startInstallSodiumWithGameVersion:gameVersion];' in ps)
check("D5  Modrinth 精确标题匹配（避开 Sodium Extra / Podium Port）",
      'ame150_fetchModrinthPrimaryFileWithQuery' in ps_code
      and '[title.lowercaseString isEqualToString:exactTitle.lowercaseString]' in ps)
check("D6  版本匹配 = 游戏版本 + fabric 加载器（gameVersions + loaders 双过滤）",
      '[ver.gameVersions containsObject:gameVersion]' in ps
      and 'l.lowercaseString isEqualToString:loader.lowercaseString' in ps)
check("D7  一键装三模组（sodium + iris + podium 三次取文件，串行下载进 mods/，Task157 扩容）",
      'exactTitle:@"sodium"' in ps and 'exactTitle:@"podium"' in ps
      and 'exactTitle:@"iris shaders"' in ps and 'exactTitle:@"iris"' in ps
      and '[strongSelf downloadDataWithURL:[NSURL URLWithString:sodiumURL] error:&dlError1];' in ps
      and '[strongSelf downloadDataWithURL:[NSURL URLWithString:irisURL] error:&dlError2] : nil;' in ps
      and '[strongSelf downloadDataWithURL:[NSURL URLWithString:podiumURL] error:&dlError3] : nil;' in ps
      and 'currentProfileModsPath' in ps)
check("D8  统一下载任务接入（DownloadTaskManager 注册 Sodium + Iris Shaders + Podium 单阶段任务）",
      'displayName:@"Sodium + Iris Shaders + Podium"' in ps
      and 'resourceName:[NSString stringWithFormat:@"sodium-iris-podium-%@", gameVersion]' in ps
      and 'PLTaskStagesSingleFile()' in ps.split('- (void)startInstallSodiumWithGameVersion')[1].split('ame150_fetchModrinthPrimaryFileWithQuery')[0])

print()
print("=" * 72)
print("E. l10n：Task159 后基线 2727（四语言一致）")
print("=" * 72)
langs = ['en.lproj', 'zh-Hans.lproj', 'zh-CN.lproj', 'zh-Hant.lproj']
base = 'Natives/resources/'
sets = []
for lg in langs:
    s = read(base + lg + '/Localizable.strings')
    r1 = '"preference.profile.renderer_follow_global_toggle"' not in s
    r2 = '"preference.warning.renderer_shadowed_by_profile"' not in s
    n1 = '"component.sodium.confirm_title"' in s
    n2 = '"component.sodium.confirm_message"' in s
    n3 = '"component.sodium.searching"' in s
    n4 = '"component.sodium.not_found"' in s
    n5 = '"component.sodium.download_failed"' in s
    n6 = '"component.sodium.done"' in s
    check(f"E[{lg}] 退役 2 键清零 + Sodium 6 键在位", r1 and r2 and n1 and n2 and n3 and n4 and n5 and n6)
    sets.append(set(re.findall(r'^"([^"]+)"\s*=', s, re.M)))
check("E5 四语言键集一致（1952 = Task156 基线 2727 + Task157 组件键 2）",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2763,
      f"counts={[len(x) for x in sets]}")

print()
print("=" * 72)
print("F. 发布资产（README 双语 / announcements / version.h 附记）")
print("=" * 72)
# Task222：README.md 现为中文默认，英文移至 README_EN.md
rcn = read("README.md")
ren = read("README_EN.md")
ann = json.loads(read("announcements.json"))
# Task162 重锚：公告数组按日期降序（服务端排序消费），新条目会插到头部——
# 发布资产锚点改按 id 定位 v6.0.0 发行条目，不再假设它是 [0]。
e = [a for a in ann["announcements"] if a.get("id") == "v6-0-0-release-2026-09-21"][0]
check("F1  README_CN 渲染器行 = 每游戏强制单选（缺省自动 + mg 单入口）",
      '每游戏强制单选' in rcn and '缺省"自动"' in rcn and '唯一的 mg 条目' in rcn)
check("F2  README EN 渲染器行 = per-game mandatory（无全局默认）",
      'per-game mandatory' in ren and 'no global default' in ren or 'games without an explicit choice default to Auto' in ren)
check("F3  announcements 渲染器 bullet 重写 + Sodium 入口提及",
      '每游戏强制单选' in e['content'] and 'Sodium' in e['content'])
check("F4  announcements 英文尾段同步（per-game mandatory / Sodium + Iris Shaders + Podium）",
      'per-game mandatory' in e['content'] and 'Sodium + Iris Shaders' in e['content']
      and 'Sodium + Iris + Podium' in e['content'])
vh = read("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("F5  version.h Task 150 附记（[可撤销] 退役 + sodium 组件）",
      'REVISION 17 addendum (Task 150, no bump)' in vh
      and 'Sodium + Podium' in vh)
check("F6  announcements 主页卡片 bullet（Task163 重锚：用户指令推翻 Task149 '取消阴影'——主页磁贴更新为新拟态凸起阴影，公告文案同步）",
      '最新正式版' in e['content'] and '新拟态凸起阴影' in e['content'])

print()
print("=" * 72)
print("G. 语法配平 + UIColor 白名单抽查")
print("=" * 72)
for name, path in [
    ("LauncherPreferencesViewController.m", "Natives/LauncherPreferencesViewController.m"),
    ("ProfileSettingsViewController.m", "Natives/ProfileSettingsViewController.m"),
    ("PLProfiles.m", "Natives/PLProfiles.m"),
    ("LauncherPreferences.m", "Natives/LauncherPreferences.m"),
]:
    check(f"G  {name} 括号配平", balanced(read(path)))

bad = []
for m in re.finditer(r"\[UIColor ([A-Za-z]+(?:Color|Fill)?)\]", read("Natives/ProfileSettingsViewController.m")):
    if m.group(1) not in [
        "labelColor", "secondaryLabelColor", "tertiaryLabelColor", "quaternaryLabelColor",
        "systemBackgroundColor", "secondarySystemBackgroundColor", "tertiarySystemBackgroundColor",
        "secondarySystemGroupedBackgroundColor", "tertiarySystemGroupedBackgroundColor",
        "systemGroupedBackgroundColor", "tertiarySystemFillColor", "separatorColor",
        "systemRedColor", "systemBlueColor", "systemOrangeColor", "systemGreenColor",
        "systemGrayColor", "systemTealColor", "whiteColor", "clearColor", "blackColor",
    ]:
        bad.append(m.group(1))
check("G  ProfileSettingsViewController UIColor 白名单审计", not bad, str(bad[:6]))

print()
print("=" * 72)
total = PASS + FAIL
print(f"==== RESULT: {'PASSED' if FAIL == 0 else 'FAILED'} ({PASS}/{total}) ====")
sys.exit(0 if FAIL == 0 else 1)
