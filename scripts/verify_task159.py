#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task159.py —— Task 159 校验器

用户三项需求：
  1. 启动器设置 > 管理 Java：1.17+ 预选下新增"26.0 及更高版本：Java 25"
     （tag 1_26_newer，PLPreferences 默认 25，footer.java25），启动/安装链
     检测代码全面适配 26.x（JavaLauncher 两处 defaultJRETag 三档 +
     ModpackUtils / ForgeProcessorExecutor / NeoForgeDirectInstaller 补
     26→25；ModpackImportService/ForgeDirectInstaller 已有 Task70 分支）。
  2. 实例设置 > 内存分配：弹窗改为与游戏目录（editGameDir）同款输入框
     alert——标题"调整内存分配"、简介"设备最大内存/可分配最大内存/内存
     调配指南见启动器使用教程"、无"恢复默认"按钮、输入值 clamp 到
     [512, 可分配最大内存]；Task157 居中卡片（含自动分配内存开关）退役，
     存量 memoryAuto=YES 实例保持原版自动比例语义直到用户确认一次输入。
  3. 分辨率缩放全局滑条退役 → 每实例"渲染器"行下新行（25~100 行内输入框
     + 右侧独立 % 标签）；解析链 profile resolution → 全局 video.resolution
     （存量回退）→ 100；游戏内菜单与 Java GUI 仍走全局键。

分节：A Manage JRE 预选 / B 检测代码 26.x 适配 / C 内存输入框弹窗 /
      D 分辨率缩放 per-instance / E l10n（1952）/ F 发布资产 /
      G 配平+白名单 / H 回归锚点
"""
import json
import os
import re
import sys

REPO = os.environ.get("TASK159_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PASS = 0
FAIL = 0
FAILED = []


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
        FAILED.append(name)
        print(f"  FAIL  {name}  {detail}")


ps = read("Natives/ProfileSettingsViewController.m")
mje = read("Natives/LauncherPrefManageJREViewController.m")
plpref = read("Natives/PLPreferences.m")
jl = read("Natives/JavaLauncher.m")
mppu = read("Natives/installer/modpack/ModpackUtils.m")
fpe = read("Natives/installer/ForgeProcessorExecutor.m")
nfd = read("Natives/installer/NeoForgeDirectInstaller.m")
mpis = read("Natives/ModpackImportService.m")
lpvc = read("Natives/LauncherPreferencesViewController.m")
plp = read("Natives/PLProfiles.m")
svc = read("Natives/SurfaceViewController.m")
jgui = read("Natives/JavaGUIViewController.m")

print()
print("=" * 72)
print("A. 管理 Java 预选：26.0 及更高版本（Java 25）")
print("=" * 72)
check("A1  DEFAULT_JRE 预选行在 1.17+ 与 execute_jar 之间插入 default.126",
      mje.index('@"preference.manage_runtime.default.117"') < mje.index('@"preference.manage_runtime.default.126"') < mje.index('@"launcher.menu.execute_jar"'))
check("A2  selectedRTTags 同序插入 1_26_newer",
      mje.index('@"1_17_newer"') < mje.index('@"1_26_newer"') < mje.index('@"execute_jar"'))
check("A3  Java 25 section footer（case 25 → footer.java25）",
      "case 25: return localize(@\"preference.manage_runtime.footer.java25\", nil);" in mje)
check("A4  未配置 tag 显示\"自动\"（存量设备 getObject 无深合并的 nil 守卫）",
      "NSString *ame159_picked" in mje and "localize(@\"preference.auto\", nil);" in mje
      and 'ame159_picked\n        ? [NSString stringWithFormat:@"Java %@", ame159_picked]' in mje)

print()
print("=" * 72)
print("B. 26.x 检测代码适配（启动 + 安装链）")
print("=" * 72)
check("B1  launchJVM defaultJRETag 三档分界（>=25 → 1_26_newer）",
      "} else if (minVersion >= 25) {" in jl and "defaultJRETag = @\"1_26_newer\";" in jl)
check("B2  execute_jar 路径三档（minJavaVersion >= 25）",
      "(minJavaVersion >= 25) ? @\"1_26_newer\"" in jl
      and ": ((minJavaVersion >= 17) ? @\"1_17_newer\" : @\"1_16_5_older\");" in jl)
check("B3  PLPreferences java_homes 默认加 1_26_newer: 25 槽位",
      '@"1_26_newer": @"25"' in plpref and '@"25": @"internal"' in plpref)
check("B4  ModpackUtils.javaMajorVersionForMC 补 26.x → 25（对齐 Task70 口径）",
      "if ([parts.firstObject integerValue] >= 26) return 25;" in mppu)
check("B5  ForgeProcessorExecutor 补 26.x → 25（原 fallback 17 漏网）",
      "if (parts.count >= 2 && [parts[0] integerValue] >= 26) return 25;" in fpe)
check("B6  NeoForge loader 反推 >=26 → 25（21 档保留在其后）",
      nfd.index("if (major >= 26) return 25;") < nfd.index("if (major >= 21) return 21;"))
check("B7  既有 Task70 分支幸存（ModpackImportService 26w/年份制 → 25）",
      'if (!' in mpis and "[mcVersion hasPrefix:@\"26w\"]" in mpis
      and "if (first >= 26) return 25;" in mpis)

print()
print("=" * 72)
print("C. 内存调整输入框弹窗（游戏目录同款，卡片退役）")
print("=" * 72)
check("C1  Ame157 卡片+动画+回调符号全仓清零",
      all(t not in ps for t in ("Ame157MemoryAllocatorCard", "Ame157CardTransitionAnimator",
                                "ameOnChange", "ame157SliderReleased", "ame157AutoSwitchChanged",
                                "ame157Close", "ame157SyncAutoVisual")))
check("C2  showMemoryAllocator 改输入框 alert（UIAlertControllerStyleAlert + textField）",
      "[alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {" in ps
      and ps.count("preferredStyle:UIAlertControllerStyleAlert];") >= 2)
check("C3  标题 memory.adjust_title + 简介 memory.adjust_message（设备/可分配最大内存两参数）",
      "alertControllerWithTitle:localize(@\"memory.adjust_title\", nil)" in ps
      and "message:[NSString stringWithFormat:localize(@\"memory.adjust_message\", nil),\n                                  (long)ame159_deviceTotalMB, (long)self.maxMemory]" in ps)
check("C4  \"恢复默认\"按钮不搬（showMemoryAllocator 无 i18n_str_898；editGameDir 保留）",
      ps.count("@\"i18n_str_898\"") == 1
      and "[alert addAction:[UIAlertAction actionWithTitle:localize(@\"i18n_str_898\", nil)" in ps)
check("C5  输入值 clamp [512, 可分配最大内存]（空输入落 512）",
      "if (ame159_value < 512) ame159_value = 512;" in ps
      and "if (ame159_value > self.maxMemory) ame159_value = self.maxMemory;" in ps)
check("C6  确定后退出自动态并落盘（memoryAutoEnabled=NO + saveSettings + reload）",
      "self.allocatedMemory = ame159_value;" in ps
      and "self.memoryAutoEnabled = NO;" in ps
      and "self.memoryAutoEnabled = NO;\n        [self saveSettings];\n        [self reloadAllTableViews];" in ps)
check("C7  NumberPad 键盘 + 预填（存量自动实例 allocatedMemory=0 → 预填 512）",
      "textField.keyboardType = UIKeyboardTypeNumberPad;" in ps
      and "NSInteger ame159_initial = self.allocatedMemory > 0 ? self.allocatedMemory : 512;" in ps)
check("C8  存量自动兼容链幸存（memory.auto_row 行显示 + saveSettings memoryAuto 分支）",
      "self.memoryAutoEnabled\n                    ? localize(@\"memory.auto_row\", nil)" in ps
      and 'existing[@"allocatedMemory"] = @(0);' in ps and 'existing[@"memoryAuto"] = @YES;' in ps)
check("C9  memory.current 键全仓退役（卡片标题唯一引用方已删）",
      all("memory.current" not in read(f) for f in
          ("Natives/ProfileSettingsViewController.m", "Natives/SurfaceViewController.m")))
check("C10 启动内存链零改动（ame141 契约幸存）",
      "int allocmem = ame141_currentLaunchAllocMem();" in jl)

print()
print("=" * 72)
print("D. 分辨率缩放 per-instance（渲染器行下 + 独立 % 标签）")
print("=" * 72)
check("D1  全局滑条行退役（typeSlider resolution 行字典清零，留撤销注释）",
      '@{@"key": @"resolution",' not in lpvc and "Task159（[可撤销] 分辨率缩放实例化）" in lpvc)
check("D2  PLProfiles prefDefaults 回退映射（profile resolution → video.resolution）",
      '@"resolution": @"video.resolution",' in plp)
check("D3  启动解析单点接入（resolveKeyForCurrentProfile:@\"resolution\"）",
      'resolutionScale = [PLProfiles resolveKeyForCurrentProfile:@"resolution"].floatValue / 100.0;' in svc)
check("D4  实例页 advancedRows 渲染器后插入\"分辨率缩放\"",
      '[advancedRows addObject:@"分辨率缩放"];' in ps
      and ps.index('arrayWithArray:@[@"渲染器"]') < ps.index('[advancedRows addObject:@"分辨率缩放"];'))
check("D5  行名映射 preference.profile.title.resolution_scale",
      '@"分辨率缩放": @"preference.profile.title.resolution_scale",' in ps)
check("D6  行渲染：viewfinder 图标 + builder accessory + detail 置空",
      '[UIImage systemImageNamed:@"viewfinder"]' in ps
      and "cell.accessoryView = [self buildResolutionScaleAccessory];" in ps)
check("D7  点击行聚焦输入框（名称行同款交互）",
      "if (self.resolutionScaleTextField) [self.resolutionScaleTextField becomeFirstResponder];" in ps)
check("D8  builder：NumberPad + Done 条 + 独立 % 标签（不在输入框内）",
      "textField.keyboardType = UIKeyboardTypeNumberPad;" in ps
      and "percentLabel.text = @\"%\";" in ps
      and "UIBarButtonSystemItemDone target:textField action:@selector(resignFirstResponder)" in ps)
check("D9  编辑结束 clamp [25, 150] 并落盘（Task160 上限放宽至旧全局滑条口径）",
      "if (ame159_value < 25) ame159_value = 25;" in ps
      and "if (ame159_value > 150) ame159_value = 150;" in ps
      and "- (void)resolutionScaleDidEnd:(UITextField *)textField {" in ps)
check("D10 saveSettings 写 profile 层 NSString",
      'existing[@"resolution"] = [NSString stringWithFormat:@"%ld", (long)self.resolutionScale];' in ps)
check("D11 loadSettings 读取（NSString/NSNumber/全局回退 + <=0 兜底 100）",
      "self.resolutionScale = (NSInteger)getPrefFloat(@\"video.resolution\");" in ps
      and "if (self.resolutionScale <= 0) self.resolutionScale = 100;" in ps)
check("D12 Java GUI 保留全局键（执行 .jar 无实例上下文，4 处读取不动）",
      jgui.count('getPrefFloat(@"video.resolution")') == 4
      and "Task159：分辨率缩放实例化后本文件 4 处仍读全局 video.resolution" in jgui)

print()
print("=" * 72)
print("E. l10n：Task159 后基线 2745（Task230 重锚；四语言一致 + 新键/退役在位）")
print("=" * 72)
LANGS = ["en", "zh-CN", "zh-Hans", "zh-Hant"]
def keyset(lang):
    s = read(f"Natives/resources/{lang}.lproj/Localizable.strings")
    return set(re.findall(r'^"([^"]+)"\s*=', s, re.M))
sets = [keyset(l) for l in LANGS]
check("E1  四语言键集一致且为 2745（Task230 重锚：Task229 基线 2727 + 18 个 ame230.* 键）",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2763,
      f"counts={[len(s) for s in sets]}")
NEW_KEYS = ["preference.manage_runtime.default.126", "preference.manage_runtime.footer.java25",
            "preference.profile.title.resolution_scale", "memory.adjust_title", "memory.adjust_message"]
check("E2  五个新键全部在位（四语言）",
      all(k in s for k in NEW_KEYS for s in sets))
check("E3  memory.current 退役（四语言）",
      all("memory.current" not in s for s in sets))
check("E4  memory.auto_row 保留（存量自动实例行显示）",
      all("memory.auto_row" in s for s in sets))
en_s = read("Natives/resources/en.lproj/Localizable.strings")
zht_s = read("Natives/resources/zh-Hant.lproj/Localizable.strings")
check("E5  文案抽查（adjust_message 双 %ld + default.126 数值 + auto_row 繁体幸存）",
      en_s.count("%ld MB\\\\n") >= 2 or en_s.count("%ld MB\\n") >= 2
      and '"preference.manage_runtime.default.126" = "26.0 and newer";' in en_s
      and '"memory.auto_row" = "自動分配記憶體";' in zht_s)

print()
print("=" * 72)
print("F. 发布资产：announcements.json 四处同步")
print("=" * 72)
# Task162 重锚：公告数组按日期降序，新条目（服务器推荐等）会插到头部——发布资产锚点改按 id 定位 v6.0.0 发行条目。
e = [a for a in json.loads(read("announcements.json"))["announcements"] if a.get("id") == "v6-0-0-release-2026-09-21"][0]
check("F1  summary 收尾补本轮三项（26.0+ 预选 / 内存输入框 / 分辨率缩放）",
      "Java 25）预选" in e["summary"] and "内存分配输入框弹窗" in e["summary"]
      and "分辨率缩放每实例单独设置" in e["summary"])
check("F2  content 新块\"Java 与内存（体验调整）\"三 bullet",
      "**Java 与内存（体验调整）**" in e["content"]
      and "26.0 及更高版本：Java 25" in e["content"]
      and "内存调配指南见启动器使用教程" in e["content"]
      and "可编辑 25~150" in e["content"])  # Task160 口径：25~150 + 内存分配同款样式
check("F3  主页卡片内存措辞更新（输入框弹窗 + 自动开关退役）",
      "内存分配改为输入框弹窗（512MB ~ 可分配上限，自动分配开关随旧弹窗退役）" in e["content"])
check("F4  EN 尾段（Java 25 preselect / input dialog / per-instance resolution）",
      '26.0 and newer: Java 25" preselect' in e["content"]
      and "game-directory-style input dialog" in e["content"]
      and "resolution scale from the global slider into per-instance settings" in e["content"])

print()
print("=" * 72)
print("G. 语法配平 + UIColor 白名单抽查")
print("=" * 72)
check("G  ProfileSettingsViewController.m 括号配平", balanced(ps))
ALLOWED_UICOLOR = [
    "labelColor", "secondaryLabelColor", "tertiaryLabelColor", "quaternaryLabelColor",
    "systemBackgroundColor", "secondarySystemBackgroundColor", "tertiarySystemBackgroundColor",
    "secondarySystemGroupedBackgroundColor", "tertiarySystemGroupedBackgroundColor",
    "systemGroupedBackgroundColor", "tertiarySystemFillColor", "separatorColor",
    "systemRedColor", "systemBlueColor", "systemOrangeColor", "systemGreenColor",
    "systemGrayColor", "systemTealColor", "whiteColor", "clearColor", "blackColor",
]
bad = []
for m in re.finditer(r"\[UIColor ([A-Za-z]+(?:Color|Fill)?)\]", ps):
    if m.group(1) not in ALLOWED_UICOLOR:
        bad.append(m.group(1))
check("G  ProfileSettingsViewController UIColor 白名单审计（无硬编码异常色）", not bad, str(bad[:6]))

print()
print("=" * 72)
print("H. 回归锚点（Task149/157 关键契约幸存）")
print("=" * 72)
check("H1  Ame149 符号全仓清零（Task149 退役延续）",
      "Ame149MemoryAllocatorController" not in ps and "ameOnApply" not in ps)
check("H2  Sodium + Iris 行与三 jar 下载链幸存（Task157 契约）",
      '@"Sodium + Iris Shaders"' in ps
      and "startInstallSodiumWithGameVersion" in ps
      and 'resourceName:[NSString stringWithFormat:@"sodium-iris-podium-%@", gameVersion]' in ps)
check("H3  组件区 footer/其余行零意外（Fabric API 与 OptiFine 行原样）",
      ps.count('cell.detailTextLabel.text = [self isFabricProfile] ? localize(@"i18n_str_2043", nil) : localize(@"i18n_str_885", nil);') == 2
      and '[UIImage systemImageNamed:@"speedometer"]' in ps)
check("H4  内存行箭头与 Task157 显示口径幸存（Task163 重锚：整页统一自绘 chevron，ame163_disclosureChevron 形态）",
      'cell.accessoryView = [self ame163_disclosureChevron];\n                cell.detailTextLabel.text = self.memoryAutoEnabled' in ps
      and "MB / %ld MB" not in ps)

print()
print("=" * 40)
total = PASS + FAIL
print(f"{PASS} passed, {len(FAILED)} failed")
if FAILED:
    for f in FAILED:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("==== RESULT: PASSED ====")
sys.exit(0)
