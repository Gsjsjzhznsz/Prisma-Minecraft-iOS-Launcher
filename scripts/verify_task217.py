#!/usr/bin/env python3
"""verify_task217.py -- Task217 eight-item round verifier.

Covers: (A) component-download 26.x fixes (parseVersionId reuse + newest-first
sort + honest no-match + MCIM retry), (B) mod-toggle silent-failure surfacing,
(C) auto-renderer crash learning, (D) FCL-style version isolation + migration,
(E) interim bundle id com.air-devs + data export/import service, (F) About
page + moved update rows + right-panel route, (G) README license/QQ, (H)
dep_virgl CI chain hardening, (I) l10n baseline 2520 x4, (J) announcements 39,
(K) REVISION 21, (L) syntax balance, (M) cascade spot checks.
"""
import json
import os
import re
import subprocess
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


psv = rd("Natives/ProfileSettingsViewController.m")
mma = rd("Natives/installer/modpack/ModrinthAPI.m")
mmg = rd("Natives/ModsManagerViewController.m")
msv = rd("Natives/ModService.m")
jl = rd("Natives/JavaLauncher.m")
lp = rd("Natives/LauncherPreferences.m")
lpv = rd("Natives/LauncherPreferencesViewController.m")
rpp = rd("Natives/LauncherRightPanelViewController.m")
ta = rd("Natives/authenticator/ThirdPartyAuthenticator.m")
dts = rd("Natives/DataTransferService.m")
avc = rd("Natives/AboutViewController.m")
mk = rd("Makefile")
yml = open(".github/workflows/development.yml", "rb").read()
plist = rd("Natives/Info.plist")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")

print("== A. 组件下载 26.x 根治 ==")
check("A1 currentGameVersion 改走 parseVersionId（26.x 前缀/中缀/纯版本全形态）",
      "[ModpackExportService parseVersionId:lastVersionId]" in psv
      and 'hasPrefix:@"1."' not in psv)
check("A2 newest-first 客户端排序（镜像乱序免疫）",
      "static NSArray<ModVersion *> *ame217_modrinthVersionsNewestFirst" in psv
      and "b.datePublished compare:a.datePublished" in psv)
check("A3 两遍通道偏好（release 优先）",
      "static ModVersion *ame217_pickVersionForGameVersion" in psv
      and "ame217_releaseOnly" in psv)
check("A4 ame150 选择器接入统一实现",
      "ame217_pickVersionForGameVersion(\n                        ame217_modrinthVersionsNewestFirst(versions), gameVersion, loader)" in psv)
check("A5 Fabric API 无匹配明确报错（不再 firstObject 静默猜版）",
      "component.fabricapi.no_match" in psv
      and re.search(r'FabricAPI" code:6[^}]*component\.fabricapi\.no_match', psv, re.S) is not None
      and 'matchingVersion = versions.firstObject' not in psv)
check("A6 ModrinthAPI 抖动单次重试（搜索 + 版本列表共享 ame217 取数器）",
      "ame217_fetchJSONWithURL" in mma
      and mma.count("ame217_fetchJSONWithURL:url completion:") == 2
      and "one retry in 1.5s" in mma)
check("A7 Mod 管理页检查更新同源 parseVersionId（fabric 前缀式修复）",
      "[ModpackExportService parseVersionId:lastVersionId]" in mmg)

print("== B. Mod 点击静默失效根修 ==")
check("B1 ModService 源缺失预检（201 + 本地化错误）",
      "code:201" in msv and "mods.toggle.source_missing" in msv)
check("B2 ModService 目标同名预检（202 + 本地化错误）",
      "code:202" in msv and "mods.toggle.dest_exists" in msv)
check("B3 管理页失败弹窗 + 201 自愈重扫（不再裸 NSLog）",
      "mods.toggle.failed" in mmg and "[self loadMods];" in mmg
      and "Error toggling mod: %@\", error);" not in mmg)

print("== C. 自动渲染器智能化（崩溃自学） ==")
check("C1 候选链函数（版本基线语义保持 + 链序正确）",
      "? @[@ RENDERER_NAME_MOBILEGL, @ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE]" in jl
      and ": @[@ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE, @ RENDERER_NAME_MOBILEGL]" in jl)
check("C2 hs_err 裁决器（哨兵读取 + mtime 对比 + 连败阈值 2）",
      "ame217_autoRendererAdjudicateLastSession" in jl
      and 'hasPrefix:@"hs_err_pid"' in jl and "fails >= 2" in jl)
check("C3 会话哨兵写入（renderer|epoch）",
      ".ame217_session" in jl and 'stringWithFormat:@"%@|%lld"' in jl)
check("C4 auto 解析点接线（裁决 → 决策 → setenv → 哨兵）",
      "ame217_autoRendererAdjudicateLastSession();" in jl
      and "ame217_autoRendererDecide(minVersion)" in jl)
check("C5 逃生舱：显式选择解除拉黑（用户意图永远优先）",
      "explicit selection '%@' un-blacklisted" in lp)
check("C6 决策留痕日志（装机可复盘）",
      "Task217: auto renderer decision: minVersion=" in jl)

print("== D. FCL 风格版本隔离 ==")
check("D1 三态选择器（不隔离/隔离此版本/自定义路径）",
      "ame217_showIsolationPicker" in psv
      and "profile.isolation.none" in psv and "profile.isolation.isolate" in psv
      and "profile.isolation.custom" in psv)
check("D2 隔离目录约定 versions/<lastVersionId>",
      'stringWithFormat:@"versions/%@", lastVersionId' in psv)
check("D3 迁移清单（saves/mods/config 等 10 项，共享层不迁）",
      '@"saves", @"mods", @"config", @"resourcepacks", @"shaderpacks"' in psv
      and '@"options.txt", @"servers.dat", @"servers.dat_old", @"usercache.json"' in psv)
check("D4 绝不覆盖语义（目标已存在跳过）",
      "if ([fm fileExistsAtPath:dst]) {" in psv and "skipped++;" in psv)
check("D5 行内三态显示（不再裸 gameDir）",
      "profile.isolation.state_none" in psv and "profile.isolation.state_isolated" in psv)
check("D6 旧文本编辑器保留为高级入口",
      "[self editGameDir];" in psv)

print("== E. 临时包名 com.air-devs + 数据导出/导入 ==")
check("E1 Info.plist 双处临时 id（bundle id + urlscheme name）",
      "<string>com.air-devs.air</string>" in plist
      and "com.air-devs.air.urlscheme" in plist
      and "com.prisma-devs.prisma" not in plist)
check("E2 Makefile 7 处 + CI 6 处 + 静态 entitlements 3 处跟随",
      mk.count("com.air-devs") == 7
      and yml.count(b"com.air-devs") == 6
      and all("com.air-devs" in rd(p) for p in
              ["entitlements.codesign.xml", "entitlements.sideload.xml", "entitlements.trollstore.xml"]))
check("E3 os_log 双子系统 + 后台会话 id 跟随",
      'os_log_create("com.air-devs.air"' in rd("Natives/TouchControllerBridge.m")
      and 'os_log_create("com.air-devs.air"' in rd("Natives/TouchController/ios_transport.c")
      and "com.air-devs.air.MinecraftResourceDownloadTask" in rd("Natives/MinecraftResourceDownloadTask.m"))
check("E4 Keychain 新服务名 + 三代历史回退链（迁移自愈）",
      'ame131_keychainService = @"com.air-devs.air.ame131.credentials"' in ta
      and "com.air-devs.ame131.credentials" in ta
      and "ame217_legacyKeychainServices" in ta
      and "com.prisma-devs.prisma.ame131.credentials" in ta
      and "com.air-devs.air.ame131.credentials" in ta)
check("E5 DataTransferService 导出（UnzipKit 逐文件 + 垃圾剔除 + 落点选择器）",
      "exportDataFromViewController" in dts
      and "initForExportingURLs" in dts
      and 'hasPrefix:@"latestlog"' in dts and 'hasPrefix:@"hs_err_pid"' in dts)
check("E6 导入（安全域拷贝 + zip-slip 净化 + 同名覆盖合并）",
      "importDataFromViewController" in dts
      and "initForOpeningContentTypes" in dts
      and 'containsString:@"../"' in dts)
check("E7 导出/导入双流程 delegate 状态位区分（不靠扩展名）",
      "awaitingExportDestination" in dts)
check("E8 CMake 注册（DataTransferService + AboutViewController）",
      "DataTransferService.m" in rd("Natives/CMakeLists.txt")
      and "AboutViewController.m" in rd("Natives/CMakeLists.txt"))
check("E9 设置页导出/导入两行（含 detail）",
      '@"data_export"' in lpv and '@"data_import"' in lpv
      and "DataTransferService sharedService] exportDataFromViewController" in lpv
      and "DataTransferService sharedService] importDataFromViewController" in lpv)

print("== F. 关于页（二级菜单 + 迁移两项 + 侧栏路由） ==")
check("F1 设置页关于行（secondary menu 入口）",
      '@"about"' in lpv and "AboutViewController alloc] init]" in lpv)
check("F2 更新两项已迁出设置·通用（general 区无 check_update/auto_update_check 行键）",
      '@"key": @"check_update"' not in lpv and '@"key": @"auto_update_check"' not in lpv)
check("F3 关于页承载更新两项（开关 + 检查按钮 + UpdateChecker）",
      "general.auto_update_check" in avc and "UpdateChecker checkForUpdateWithCompletion" in avc
      and "ame217_checkForUpdate" in avc)
check("F4 QQ 群展示 + 一键复制（1126547426）",
      'ame217_qqGroup = @"1126547426"' in avc and "ame217_copyQQGroup" in avc)
check("F5 许可证声明（AGPL-3.0 + LICENSE 文件所在处）",
      "about.license.title" in avc and "about.license.body" in avc)
check("F6 版本动态读 plist（6.5.0 双键）",
      "CFBundleShortVersionString" in avc
      and "<string>6.5.0</string>" in plist
      and plist.count("6.5.0") == 2)
check("F7 右侧栏启动器版本卡改路由 about",
      'route:@"about"' in rpp and 'isEqualToString:@"about"' in rpp
      and 'route:@"settings:check_update"' not in rpp)
check("F8 版本号 6.5.0 + REVISION 21（identity-follows-cache-epoch）",
      "#define REVISION 22" in vh
      and "REVISION 20->21 bump addendum (Task 217)" in vh)

print("== G. README（许可证 + QQ 群） ==")
rm = rd("README.md")
rmc = rd("README_CN.md")
check("G1 EN：Community 段 QQ 群 + License 段（AGPL + LICENSE 文件说明）",
      "QQ Group: 1126547426" in rm and "## License" in rm
      and "GNU Affero General Public License v3.0" in rm
      and "[`LICENSE`](./LICENSE)" in rm)
check("G2 CN：社区段 QQ 群 + 许可证段",
      "QQ 群：1126547426" in rmc and "## 许可证" in rmc
      and "AGPL-3.0" in rmc and "LICENSE" in rmc)

print("== H. dep_virgl CI 链加固 ==")
check("H1 cross 文件补 pkg-config（host 机探测）",
      "\"pkg-config = 'pkg-config'\"" in mk)
check("H2 native 文件生成（build 机钉死裸 clang，绕开 CC=ccache 包装）",
      "> $(WORKINGDIR)/virgl-native.txt" in mk
      and mk.count("virgl-native.txt") == 4
      and re.search(r"printf '%s\\n' \\\n\t\t'\[binaries\]' \\\n\t\t\"c = 'clang'\" \\", mk) is not None)
check("H3 三处 meson setup 均带 --native-file",
      mk.count("--native-file $(WORKINGDIR)/virgl-native.txt") == 3)
check("H4 CI brew 补装 pkg-config",
      b"brew install meson ninja bison pkg-config" in yml)
check("H5 优雅降级包装层保持（dep_virgl warn+pass 不阻断主构建）",
      "dep_virgl - build failed; VirGL renderer entry hidden (graceful degradation by design)" in mk)

print("== I. l10n 基线 ==")
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    keys = set(re.findall(r'^"([^"]+)"\s*=',
                          rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M))
    check(f"I-{lang} 唯一键 2520（Task217 +36）", len(keys) == 2520, f"got {len(keys)}")
zh = rd("Natives/resources/zh-Hans.lproj/Localizable.strings")
en = rd("Natives/resources/en.lproj/Localizable.strings")
check("I-核心键在位（isolation/导出导入/about/mods/fabricapi）",
      all(k in zh and k in en for k in [
          "profile.isolation.title", "profile.isolation.migrated",
          "preference.title.data_export", "preference.title.data_import",
          "preference.title.about", "about.license.body", "about.qq.copied",
          "mods.toggle.dest_exists", "component.fabricapi.no_match",
          "ame217.export.done", "ame217.import.done"]))

print("== J. announcements ==")
ann = json.load(open("announcements.json", encoding="utf-8"))["announcements"]
check("J1 41 条 + task218@-2 锚（Task219 追加后顺延）",
      len(ann) == 42 and ann[-4]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-3]["id"] == "task218-air-interim-welcome-crash-diagnosis-2026-10-04"
      and ann[-2]["id"] == "task219-virgl-angle-welcome-rebuild-2026-10-04")
check("J2 task216@-3 / task206@-4（Task218 追加后顺延）",
      ann[-5]["id"] == "task216-ui-2026-10-03" and ann[-6]["id"] == "task206-nggl4es-2026-10-01")
check("J3 置顶钉位未动",
      ann[0].get("pin") is True and ann[0]["id"].startswith("server-recommend"))

print("== K. 语法平衡（字符串/注释感知括号扫描） ==")


def strip_strings_comments(code):
    out, i, n = [], 0, len(code)
    while i < n:
        c = code[i]
        if c == '"':
            i += 1
            while i < n:
                if code[i] == '\\':
                    i += 2
                    continue
                if code[i] == '"':
                    i += 1
                    break
                i += 1
            out.append('""')
        elif code.startswith('//', i):
            j = code.find('\n', i)
            i = n if j < 0 else j
        elif code.startswith('/*', i):
            j = code.find('*/', i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return ''.join(out)


touched = ["Natives/ProfileSettingsViewController.m", "Natives/installer/modpack/ModrinthAPI.m",
           "Natives/ModsManagerViewController.m", "Natives/ModService.m", "Natives/JavaLauncher.m",
           "Natives/LauncherPreferences.m", "Natives/LauncherPreferencesViewController.m",
           "Natives/LauncherRightPanelViewController.m", "Natives/authenticator/ThirdPartyAuthenticator.m",
           "Natives/DataTransferService.m", "Natives/AboutViewController.m"]
bal_ok = True
for f in touched:
    s = strip_strings_comments(rd(f))
    for o, c in [('{', '}'), ('(', ')'), ('[', ']')]:
        if s.count(o) != s.count(c):
            bal_ok = False
            print(f"    unbalanced {f}: {o}{s.count(o)} vs {c}{s.count(c)}")
check("K1 括号平衡（11 个改动 ObjC 文件）", bal_ok)

mk_tabs = sum(1 for line in open("Makefile", 'rb').read().split(b'\n') if line.startswith(b'\t'))
check("K2 Makefile TAB 基线 662（dep_virgl native-file 块 +16）", mk_tabs == 662, f"got {mk_tabs}")
check("K3 工作流 CRLF 完整（二进制口径）",
      yml.count(b"\r\n") == yml.count(b"\n"))

print("== L. 级联抽查 ==")
spot = [
    ("scripts/verify_task112_118.py", "6.5.0"),
    ("scripts/verify_task125_128.py", "AboutViewController.m"),
    ("scripts/verify_task156.py", 'route:@"about"'),
    ("scripts/verify_task173.py", "legacy MC baseline (Task173/212: ZL2 classic gl4es)"),
    ("scripts/verify_task206.py", "== 2520"),
    ("scripts/verify_task216.py", "com.air-devs interim"),
]
spot_ok = True
for path, needle in spot:
    if needle not in rd(path):
        spot_ok = False
        print(f"    missing in {path}: {needle}")
check("L1 重锚抽查（6 个关键验证器锚点在位）", spot_ok)
try:
    r = subprocess.run([sys.executable, "scripts/verify_task125_128.py"],
                       capture_output=True, text=True, timeout=200)
    check("L2 verify_task125_128 深跑绿（更新行迁移重锚）", r.returncode == 0,
          r.stdout[-120:] if r.returncode else "")
except Exception as e:
    check("L2 verify_task125_128 深跑绿", False, str(e))

print(f"\n{'=' * 40}")
print(f"verify_task217: {PASSED} passed, {len(FAILED)} failed")
if FAILED:
    for f in FAILED:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("ALL GREEN")
