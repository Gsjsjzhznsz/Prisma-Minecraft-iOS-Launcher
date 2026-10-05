#!/usr/bin/env python3
"""verify_task218.py -- Task218 six-item round verifier.

Covers: (A) download-source dual-track retirement (PLMirrorCenter single
source of truth; fill-only migration; root/card manifest chains; IconLoader
policy; 7 label sites), (B) settings hero card -> About entry, (C) FCL-style
crash identification (CrashAnalyzer + adjudicator classification + diagnosis
dialog), (D) first-use welcome wizard (trigger/steps/keys/animations),
(E) interim bundle id com.air-devs.air + REVISION 22, (F) repo rename away
from air (update checker / control repo / announcements + pre-rename
normalization), (G) l10n 2520 x4 + announcements 40, (H) syntax/baselines,
(I) cascade spot checks on the re-anchored fleet.
"""
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASSED, FAILED = 0, []


def rd(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def check(name, ok, detail=""):
    global PASSED
    if ok:
        PASSED += 1
        print(f"  PASS  {name}")
    else:
        FAILED.append(name)
        print(f"  FAIL  {name}  -- {detail[:160]}")


pmc = rd("Natives/PLMirrorCenter.m")
pmch = rd("Natives/PLMirrorCenter.h")
lp = rd("Natives/LauncherPreferences.m")
plp = rd("Natives/PLPreferences.m")
lpv = rd("Natives/LauncherPreferencesViewController.m")
rvc = rd("Natives/LauncherRootViewController.m")
cvc = rd("Natives/LauncherCardLayoutViewController.m")
ico = rd("Natives/IconLoader.m")
jl = rd("Natives/JavaLauncher.m")
ca = rd("Natives/CrashAnalyzer.m")
cah = rd("Natives/CrashAnalyzer.h")
wvc = rd("Natives/WelcomeViewController.m")
sd = rd("Natives/SceneDelegate.m")
cml = rd("Natives/CMakeLists.txt")
mk = rd("Makefile")
yml = open(".github/workflows/development.yml", "rb").read()
plist = rd("Natives/Info.plist")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
ta = rd("Natives/authenticator/ThirdPartyAuthenticator.m")
uc = rd("Natives/UpdateChecker.m")
crv = rd("Natives/ControlRepoViewController.m")
ans = rd("Natives/AnnouncementService.m")

print("== A. 下载源双轨收敛（用户主诉：设置显示与实际行为不一致） ==")
check("A1 PLMirrorCenter 新增体系化布尔判定 + 显示 token 辅助",
      "+ (BOOL)mirrorPreferredForType:(PLMirrorResourceType)type" in pmch
      and "+ (NSString *)legacySourceTokenForType:(PLMirrorResourceType)type" in pmch
      and "return [self mirrorPreferredForType:type] ? @\"bmclapi\" : @\"official\";" in pmc)
check("A2 迁移 fill-only + 无旧值封口哨兵（杜绝哨兵重置后整组覆写）",
      "Task218：无旧值也立即封口哨兵" in lp
      and "Task218：整组覆写 -> 按键补齐（fill-only）" in lp
      and 'Task218 sealed download-source migration sentinel (no legacy value present)' in lp)
check("A3 旧键默认值退役（不再播种 bmclapi）",
      '// @"download_source": @"bmclapi",   // retired by Task218' in plp)
check("A4 根页 + 卡片页版本清单走候选链（bmclapi-vs-官方硬切换退役）",
      "candidateURLsForOriginalURL:ame218_official" in rvc
      and "candidateURLsForOriginalURL:ame218_official" in cvc
      and "bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" not in rvc
      and "bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json" not in cvc
      and "Task218 manifest fetch failed" in rvc and "Task218 manifest fetch failed" in cvc)
check("A5 IconLoader 镜像开关收敛到策略层",
      "return [PLMirrorCenter mirrorPreferredForType:PLMirrorResourceTypeAssetDownload];" in ico
      and 'getPrefObject(@"general.download_source")' not in ico)
check("A6 七处任务来源标签统一走 legacySourceTokenForType",
      sum(rd(p).count("legacySourceTokenForType") for p in
          ["Natives/MinecraftResourceDownloadTask.m", "Natives/LauncherPrefManageJREViewController.m",
           "Natives/ShaderService.m", "Natives/WorldService.m", "Natives/DataPackService.m",
           "Natives/DownloadViewController.m"]) == 7)
check("A7 全工程无残留旧键直读（PLMirrorCenter 回退链 + 迁移读为合法读者）",
      all('getPrefObject(@"general.download_source")' not in rd(p) for p in
          ["Natives/IconLoader.m", "Natives/LauncherRootViewController.m",
           "Natives/LauncherCardLayoutViewController.m", "Natives/MinecraftResourceDownloadTask.m",
           "Natives/LauncherPrefManageJREViewController.m", "Natives/ShaderService.m",
           "Natives/WorldService.m", "Natives/DataPackService.m", "Natives/DownloadViewController.m"])
      and 'kPrefLegacyDownloadSource = @"general.download_source"' in pmc)
check("A8 设置页四个细分行显示兜底（标签与 ✓ 永远同源）",
      "Task218：四个细粒度镜像策略行的显示兜底" in lpv
      and lpv.count('return @"speed_first";') == 2)

print("== B. 设置页顶部 Hero 卡片 = 关于页二级入口 ==")
check("B1 Hero 卡片点击接线（手势 + 按压动效 + push 关于页）",
      "initWithTarget:self action:@selector(ame218_heroCardTapped:)" in lpv
      and "ame218_heroCardTapped:(UITapGestureRecognizer" in lpv
      and "CGAffineTransformMakeScale(0.97, 0.97)" in lpv
      and "pushViewController:ame218_about animated:YES" in lpv)

print("== C. 崩溃识别（判断脚本口径 + FCL 式诊断） ==")
check("C1 CrashAnalyzer 存在且登记 CMake",
      os.path.exists("Natives/CrashAnalyzer.m") and os.path.exists("Natives/CrashAnalyzer.h")
      and "CrashAnalyzer.m" in cml)
check("C2 OOM 分型判读（insufficient memory + 紧凑头两形态）",
      "There is insufficient memory for the Java Runtime Environment to continue" in ca
      and '# Out of Memory Error' in ca and '# java.lang.OutOfMemoryError' in ca)
check("C3 渲染器库映射表（11 库族，vtest/virgl 与 holy-gl4es 归并）",
      all(k in ca for k in ["libOSMesa.8.dylib", "libOSMesaVirgl.dylib", "libvtestserver.dylib",
                            "libMobileGL.dylib", "libMobileGL-gles.dylib", "libmobileglues.dylib",
                            "libmithril.dylib", "libgl4eszl2.dylib", "libgl4es_114.dylib",
                            "libtinygl4angle.dylib", "libMoltenVK.dylib"]))
check("C4 裁决器升级（最新 mtime + OOM 不记锅 + 归因优先 + 弹窗去重）",
      "ame218_newest = " not in jl  # no stray draft
      and "t > newestMtime" in jl
      and "classified OOM (signal %@) -- renderer fail counts untouched" in jl
      and "counting against the blamed renderer" in jl
      and 'ame218.crashDialogShownFor' in jl
      and "ame218_showCrashDiagnosis(diag, hsErrPath, NO, nil);" in jl)
check("C5 FCL 式诊断弹窗（标题/三型文案/拉黑提示/分享导出/取消）",
      'localize(@"ame218.crash.title"' in jl and 'localize(@"ame218.crash.oom.body"' in jl
      and 'localize(@"ame218.crash.renderer.body"' in jl and 'localize(@"ame218.crash.unknown.body"' in jl
      and 'localize(@"ame218.crash.blacklisted"' in jl and 'localize(@"ame218.crash.view"' in jl
      and 'localize(@"ame218.crash.ok"' in jl
      and "UIActivityViewController" in jl)
check("C6 JavaLauncher 接入 CrashAnalyzer（import + 分析调用）",
      '#import "CrashAnalyzer.h"' in jl
      and "[CrashAnalyzer analyzeHsErrFile:hsErrPath]" in jl)

print("== D. 首次使用欢迎向导 ==")
check("D1 向导存在且登记 CMake + 六个步骤构建器齐备（CI 病历：步骤 0/1 曾因插入事故缺席；Task219 重做后五步扩为六步——新增 EnvJitStep，验证器同步重锚）",
      os.path.exists("Natives/WelcomeViewController.m")
      and "WelcomeViewController.m" in cml
      and all(f"ame218_build{s}:(UIView *)container" in wvc for s in
              ["HeroStep", "LanguageStep", "EnvJitStep", "SourceStep", "DataStep", "DoneStep"])
      and 'localize(@"welcome.hero.subtitle"' in wvc
      and 'localize(@"welcome.lang.title"' in wvc
      and "ame218_refreshLangButtons" in wvc)
check("D2 SceneDelegate 触发（0.8s 延迟 + 哨兵判定 + 全屏呈现）",
      "presentIfNeededFromViewController:rootVC" in sd
      and 'getPrefBool(@"general.welcome_completed")' in wvc
      and "UIModalPresentationFullScreen" in wvc)
check("D3 哨兵默认注册 + 完成落键",
      '@"welcome_completed": @NO' in plp
      and 'setPrefObject(@"general.welcome_completed", @YES)' in wvc)
check("D4 下载源步写四个策略键 + 触发测速",
      wvc.count('@"download.fileSource"') >= 1
      and "startSpeedProbesIfNeeded" in wvc
      and "Task218: download source set to" in wvc)
check("D5 语言步写 app_language + 完成后补发重建通知",
      'setPrefObject(@"general.app_language"' in wvc
      and 'postNotificationName:@"AppLanguageChanged"' in wvc)
check("D6 数据迁移步复用 Task217 数据桥",
      "[[DataTransferService sharedService] importDataFromViewController:self]" in wvc)
check("D7 动效清单（Task219 重做后口径：常驻 UIScrollView 步骤舞台 + 弹簧转场 + 圆点 + 礼花；渐变背景/氛围气泡随 iPadOS 化改造退役）",
      "UIScrollView" in wvc and "contentLayoutGuide" in wvc
      and "usingSpringWithDamping" in wvc and "ame218_fireConfettiBurst" in wvc
      and "CAEmitterLayer" in wvc and "updateDots" in wvc)

print("== E. 包名过渡 com.air-devs.air（上游原地更新通道） ==")
check("E1 Info.plist 双处（bundle id + urlscheme）",
      "<string>com.air-devs.air</string>" in plist
      and "com.air-devs.air.urlscheme" in plist
      and "com.prisma-devs.prisma" not in plist)
check("E2 Makefile 7 处 + CI 6 处 + 静态 entitlements 3 处（.air 后缀子串计数不变）",
      mk.count("com.air-devs") == 7
      and yml.count(b"com.air-devs") == 6
      and all("com.air-devs.air" in rd(p) for p in
              ["entitlements.codesign.xml", "entitlements.sideload.xml", "entitlements.trollstore.xml"]))
check("E3 os_log 双子系统 + 后台会话 id（.air 全形）",
      'os_log_create("com.air-devs.air"' in rd("Natives/TouchControllerBridge.m")
      and 'os_log_create("com.air-devs.air"' in rd("Natives/TouchController/ios_transport.c")
      and "com.air-devs.air.MinecraftResourceDownloadTask" in rd("Natives/MinecraftResourceDownloadTask.m"))
check("E4 Keychain 主键 .air + 过渡代入链",
      'ame131_keychainService = @"com.air-devs.air.ame131.credentials"' in ta
      and '@"com.air-devs.ame131.credentials",             // Task217 过渡代（本轮身份）' in ta)
check("E5 REVISION 22 + Task218 附录",
      "#define REVISION 22" in vh
      and "REVISION 21->22 bump addendum (Task 218)" in vh)

print("== F. 仓库名去 air（Prisma-Minecraft-iOS-Launcher） ==")
check("F1 UpdateChecker 指向新仓库名",
      '+ (NSString *)repoName { return @"Prisma-Minecraft-iOS-Launcher"; }' in uc
      and "Air-Minecraft-iOS-Launcher" not in uc)
check("F2 控件仓库跟随",
      'kTask189RepoName = @"Prisma-Minecraft-iOS-Launcher"' in crv)
check("F3 公告源三处 + 改名前旧 URL 纳入已知默认值（存量 news_url 归一化）",
      "Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/main/announcements.json" in plp
      and pmc.count("Prisma-Minecraft") == 0
      and "Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/main/announcements.json" in ans
      and "cdn.jsdelivr.net/gh/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher@main" in ans
      and "kPreRenameAnnouncementURL" in ans and "kPreRenameAnnouncementMirrorURL" in ans
      and ans.count("Air-Minecraft-iOS-Launcher") == 3)  # 改名前常量两处 + 注释一处
check("F4 README 双语徽章 + star-history 全部新名",
      rd("README.md").count("Gsjsjzhznsz%2FPrisma-Minecraft-iOS-Launcher") == 4
      and "Air-Minecraft" not in rd("README.md")
      and rd("README_CN.md").count("Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher") >= 10)

print("== G. l10n + 公告 ==")
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    keys = set(re.findall(r'^"([^"]+)"\s*=',
                          rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M))
    check(f"G-{lang} 唯一键 2520（Task218 +27）", len(keys) == 2520, f"got {len(keys)}")
zh = rd("Natives/resources/zh-Hans.lproj/Localizable.strings")
en = rd("Natives/resources/en.lproj/Localizable.strings")
check("G-新键在位（welcome 全家 + ame218.crash 全家）",
      all(k in zh and k in en for k in [
          "welcome.hero.subtitle", "welcome.next", "welcome.lang.title", "welcome.lang.more",
          "welcome.source.title", "welcome.source.mirror.desc", "welcome.data.import.desc",
          "welcome.done.start", "ame218.crash.title", "ame218.crash.oom.body",
          "ame218.crash.renderer.body", "ame218.crash.blacklisted", "ame218.crash.view"]))
ann = json.load(open("announcements.json"))["announcements"]
check("G-公告 41 条 + 尾锚家族顺延（Task219 后：219@-1 / 218@-2 / 217@-3 / 216@-4 / 206@-5）",
      len(ann) == 42
      and ann[-3]["id"] == "task218-air-interim-welcome-crash-diagnosis-2026-10-04"
      and ann[-4]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-5]["id"] == "task216-ui-2026-10-03"
      and ann[-6]["id"] == "task206-nggl4es-2026-10-01"
      and ann[0].get("pin") is True)

print("== H. 语法平衡 + 基线 ==")
def balance(path):
    # 状态机口径：字符串/注释感知，不受 URL 内 // 与注释内括号千扰
    stack = []
    in_block = False
    for raw in open(path, encoding="utf-8", errors="replace"):
        i, in_str = 0, False
        while i < len(raw):
            c = raw[i]
            if in_block:
                if raw.startswith("*/", i): in_block = False; i += 2; continue
                i += 1; continue
            if in_str:
                if c == "\\": i += 2; continue
                if c == '"': in_str = False
                i += 1; continue
            if raw.startswith("//", i): break
            if raw.startswith("/*", i): in_block = True; i += 2; continue
            if c == '"': in_str = True; i += 1; continue
            if c in "([{": stack.append(c)
            elif c in ")]}":
                if not stack: return False
                o = stack.pop()
                if (o == "[" and c != "]") or (o == "(" and c != ")") or (o == "{" and c != "}"):
                    return False
            i += 1
        if in_str: return False
    return not stack
changed_files = ["Natives/WelcomeViewController.m", "Natives/CrashAnalyzer.m",
                 "Natives/PLMirrorCenter.m", "Natives/LauncherPreferences.m",
                 "Natives/PLPreferences.m", "Natives/AnnouncementService.m",
                 "Natives/LauncherPreferencesViewController.m", "Natives/JavaLauncher.m",
                 "Natives/LauncherRootViewController.m", "Natives/LauncherCardLayoutViewController.m",
                 "Natives/IconLoader.m", "Natives/SceneDelegate.m"]
check("H1 括号平衡（12 个改动 ObjC 文件，状态机口径）",
      all(balance(p) for p in changed_files))
check("H2 Makefile TAB 基线 662（行首配方行计数，同线替换保持）",
      sum(1 for line in open("Makefile", "rb").read().split(b"\n") if line.startswith(b"\t")) == 662)
check("H3 工作流 CRLF 完整（二进制口径）",
      yml.count(b"\r\n") == yml.count(b"\n"))
check("H4 公告 JSON 可解析且 id 唯一",
      len(set(a["id"] for a in ann)) == len(ann))

print("== I. 级联抽查（本轮重锚族） ==")
spot = {
    "scripts/verify_task217.py": ['<string>com.air-devs.air</string>',
                                  "len(ann) == 42", "#define REVISION 22", "2520"],
    "scripts/verify_task216.py": ["<string>com.air-devs.air</string>", "len(ann) == 42",
                                  "#define REVISION 22"],
    "scripts/verify_task213.py": ["len(ids) == 42"],
    "scripts/verify_task214.py": ["len(ann) == 42", "2520"],
    "scripts/verify_task212.py": ["len(ann) == 42", "2520"],
    "scripts/verify_task211.py": ["len(ann) == 42", "2520"],
    "scripts/verify_task210.py": ["len(ann) == 42", "2520"],
    "scripts/verify_task207.py": ["len(ann) == 42"],
    "scripts/verify_task206.py": ["len(ann) == 42", "ann[-5]", "2520"],
}
g_ok = True
g_detail = []
for path, needles in spot.items():
    src = rd(path)
    for n in needles:
        if n not in src:
            g_ok = False
            g_detail.append(f"{path} missing {n!r}")
check("I1 重锚族抽查（9 验证器：计数 40 / 尾窗顺延 / 身份 / REVISION / l10n 2520）",
      g_ok, "; ".join(g_detail[:3]))
check("I2 舰队 2455 旧值扫荡干净",
      all("2455" not in rd(f) for f in
          ["scripts/verify_task217.py", "scripts/verify_task216.py", "scripts/verify_task151.py",
           "scripts/verify_task206.py", "scripts/verify_task211.py", "scripts/verify_task133.py"]))
check("I3 欢迎向导与崩溃分析器登记 CMake（新文件可编译）",
      "CrashAnalyzer.m" in cml and "WelcomeViewController.m" in cml)

print()
print("=" * 40)
print(f"verify_task218: {PASSED} passed, {len(FAILED)} failed")
if FAILED:
    print("FAILED:", FAILED)
    sys.exit(1)
print("ALL GREEN")
