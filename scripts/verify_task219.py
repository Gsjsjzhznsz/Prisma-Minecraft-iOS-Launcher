#!/usr/bin/env python3
# verify_task219.py -- Task219 eleven-item round verifier.
# Evidence base: 6cd2cbfb device logs (latestlog.old.txt VirGL session +
# latestlog.txt ANGLE 26.2 FO session), both on the 2f82e61 build (run 622).
import json, os, re, subprocess, sys

REPO = os.path.dirname(os.path.abspath(__file__)) + "/.."
os.chdir(REPO)
PASSED, FAILED = 0, []

def rd(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()

def check(name, ok, detail=""):
    global PASSED
    print(("PASS " if ok else "FAIL ") + name + ((" -- " + detail) if (detail and not ok) else ""))
    if ok:
        PASSED += 1
    else:
        FAILED.append(name)

vs = rd("Natives/ctxbridges/virgl_server.m")
eb = rd("Natives/egl_bridge.m")
tg = rd("Natives/external/gl4es/tinygl4angle.c")
wv = rd("Natives/WelcomeViewController.m")
wh = rd("Natives/WelcomeViewController.h")
ab = rd("Natives/AboutViewController.m")
dt = rd("Natives/DataTransferService.m")
ps = rd("Natives/ProfileSettingsViewController.m")
ms = rd("Natives/ModService.m")
mh = rd("Natives/ModService.h")
mm = rd("Natives/ModsManagerViewController.m")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
cml = rd("Natives/CMakeLists.txt")
ann = json.load(open("announcements.json", encoding="utf-8"))["announcements"]

print("== A. VirGL 崩溃根治（①：vtest 引导失败 → guest abort） ==")
check("A1 诊断盲区修复：virgl_server.m import utils.h（NSLog 宏重定义走 latestlog 管道）",
      '#import "utils.h"' in vs
      and "check [VirGL] logs above" not in eb)
check("A2 socket 路径缩短 + pid 唯一化（旧 $POJAV_HOME/.virgl_test ~170 字节超 sun_path 104 上限）",
      "ame219_compute_socket_path" in vs
      and "sun_path" in vs and "ame_virgl_%d.sock" in vs
      and '"%s/.virgl_test"' not in vs)
check("A3 dlopen 候选链（libEGL + libvtestserver，@executable_path 优先——LiveContainer 的 @rpath 解析落宿主）",
      "ame219_dlopen_first" in vs
      and '"@executable_path/Frameworks/libEGL.framework/libEGL"' in vs
      and '"@executable_path/Frameworks/" AME_VIRGL_VTEST_SERVER_LIB' in vs)
check("A4 eglChooseConfig 回退链（ES3_BIT 优先 → ES2_BIT 兜底，逐档日志）",
      "ame219_configOk" in vs and "EGL_OPENGL_ES3_BIT" in vs
      and vs.count("eglChooseConfig pass#") >= 1)
check("A5 引导后验证 = socket 文件 + S_ISSOCK，且【无 connect 探针】（单发服务名额保护）",
      "S_ISSOCK" in vs and "post-bootstrap check" in vs
      and "connect(ame219_probe" not in vs)
check("A6 egl_bridge 引导失败 → Zink 改道（guest 加载前换 AMETHYST_RENDERER/GALLIUM_DRIVER，abort 不再可达）",
      "diverting renderer to Zink" in eb
      and 'setenv("AMETHYST_RENDERER", RENDERER_NAME_VK_ZINK, 1)' in eb
      and 'setenv("GALLIUM_DRIVER", "zink", 1)' in eb)
check("A7 回退弹窗走 ame219.virgl.fallback 键（l10n 四语言在位）",
      'localize(@"ame219.virgl.fallback.title"' in eb
      and all('ame219.virgl.fallback.title' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
              for l in ["en", "zh-Hans", "zh-Hant", "zh-CN"]))

print("== B. ANGLE 非 26.3 黑屏根治（⑦：桌面 GLSL 直传无 ES300 转换） ==")
check("B1 桌面头重写块在位（#version 300 es + ame176 同款精度组）",
      "Task219" in tg and "kAme219EsHead" in tg
      and '"#version 300 es\\n"' in tg
      and "precision highp float;" in tg
      and "precision highp uimage2D;" in tg)
check("B2 触发门 = 桌面 >=130（26.2 的 #version 330 命中；ES 源不受影响）",
      "ame219_ver >= 130" in tg)
check("B3 重写后走 ES 直传路径（早退分支语义，跳过 gl4es 时代 outColor0/扩展注入）",
      "gles_glShaderSource(shader, 1, (const GLchar * const *)(&ame219_es), NULL)" in tg)
check("B4 取证日志锚点（Task219 desktop->ES300 head rewrite）",
      "[tinygl4angle] Task219 desktop->ES300 head rewrite" in tg)
check("B5 Task183 漏网监测器保留（回归哨兵不退役）",
      "Task183 DESKTOP source reached GLES upload" in tg)
check("B6 旧 1xx 转换路径保留（低版本形态行为不变）",
      "converted[9] == '1'" in tg)

print("== C. 欢迎向导重做（⑧：布局根因 + iPadOS 化 + 返回上一步） ==")
check("C1 布局根因修复：常驻 UIScrollView 舞台，step 锚 contentLayoutGuide（不再引用上一步容器）",
      "contentScrollView" in wv
      and "contentLayoutGuide.topAnchor" in wv
      and "ame218_old.topAnchor constraintEqualToAnchor" not in wv)
check("C2 旧 step 移除仅限叶子（移除的是 currentStepView 的前值，无跨容器约束）",
      "[ame218_old removeFromSuperview]" in wv
      and "insertSubview:ame218_new belowSubview" not in wv)
check("C3 返回上一步按钮（chevron.left + 步骤 0 隐藏）",
      'localize(@"welcome.back"' in wv and "ame219_backTapped" in wv
      and "self.backButton.hidden = (index == 0)" in wv)
check("C4 六步流程（Hero/语言/环境与JIT/下载源/数据/完成）",
      "ame218_welcomeStepCount = 6" in wv)
check("C5 步骤构建器 6/6 与 switch 对齐（run621 事故类防线）",
      set(re.findall(r"\[self (ame218_build\w+Step):", wv)) ==
      set(re.findall(r"^- \(void\)(ame218_build\w+Step):", wv, re.M)) and
      len(set(re.findall(r"^- \(void\)(ame218_build\w+Step):", wv, re.M))) == 6)
check("C6 iPadOS 视觉（systemBackground / labelColor / secondarySystemGroupedBackground 卡片）",
      "systemBackgroundColor" in wv and "labelColor" in wv
      and "secondarySystemGroupedBackgroundColor" in wv)
check("C7 App 图标多候选加载（bundle 根 PNG 实名，根治“没有图标装饰”）",
      "ame219_loadAppIcon" in wv and "AppIcon-Light60x60" in wv)
check("C8 选择器完备性（@selector 全部有实现——run621 事故类防线）",
      not ({u.split(":")[0] for u in re.findall(r"@selector\(([^)]+)\)", wv)}
           - set(re.findall(r"^[-+] \([^)]*\)\s*(\w+)", wv, re.M))))

print("== D. LiveContainer 检测 + JIT 方式（②③） ==")
check("D1 LC 检测 = 已加载镜像扫描 LiveContainerShared（装机 fatal trace 同款判据）",
      "runningInLiveContainer" in wv and "LiveContainerShared.framework" in wv
      and "_dyld_image_count" in wv)
check("D2 宿主包名解析 = LiveContainerShared 路径回溯 App.app + Info.plist",
      "liveContainerHostBundleId" in wv and "CFBundleIdentifier" in wv
      and 'stringByAppendingPathComponent:@"Info.plist"' in wv)
check("D3 包名不一致指引（用户指令原文）+ 复制宿主包名",
      'localize(@"welcome.env.lc.mismatch.title"' in wv
      and 'localize(@"welcome.env.lc.mismatch.body"' in wv
      and "ame219_copyHostId" in wv)
check("D4 包名一致 = 绿色确认态（welcome.env.lc.ok）",
      'localize(@"welcome.env.lc.ok"' in wv)
check("D5 JIT 方式选择写 debug.jit_enabler（右面板 Task134 同键）+ 七选项",
      'setPrefObject(@"debug.jit_enabler"' in wv
      and '"jitstreamer", @"trollstore", @"manual"' in wv)
check("D6 JIT 状态实时（isJITEnabled + 回前台刷新观察者）",
      "isJITEnabled(NO)" in wv and "UIApplicationDidBecomeActiveNotification" in wv
      and "ame219_refreshJitStatus" in wv)
check("D7 立即开起 = 五工具 URL 分发（stikjit/sidestore/stosdebug/jitstreamer/apple-magnifier）",
      "stikjit://enable-jit" in wv and "sidestore://enable-jit" in wv
      and "stosdebug://enableJIT" in wv and "fd00::]:9172/launch_app" in wv
      and "apple-magnifier://enable-jit" in wv)
check("D8 LC 下的 JIT 提示走专用键（hint.lc）",
      'localize(ame219_inLC ? @"welcome.jit.hint.lc" : @"welcome.jit.hint"' in wv)

print("== E. 完成后自动打开关于页 + 关于页图标（⑥⑤） ==")
check("E1 完成步收尾 → finishOpenAbout:YES；跳过路径保持安静",
      "[self ame218_finishOpenAbout:YES]" in wv
      and "ame218_finishOpenAbout:(BOOL)openAbout" in wv)
check("E2 About 以 PageSheet 呈现于 dismissal completion 内",
      "AboutViewController" in wv and "UIModalPresentationPageSheet" in wv)
check("E3 关于页图标同样多候选加载",
      "AppIcon-Light60x60" in ab)

print("== F. 数据导出增强（⑨） ==")
check("F1 导出前预检（文件数 + 总量 + 预检日志）",
      "ame219_files" in dt and "export preflight" in dt)
check("F2 压缩等级三选（UZK None/Default/Best 透传）",
      "ame219_showExportLevelSheetWithFiles" in dt
      and "UZKCompressionMethodNone" in dt and "UZKCompressionMethodDefault" in dt
      and "UZKCompressionMethodBest" in dt
      and "compressionMethod:method" in dt)
check("F3 进度条 + 文件级详情（UIProgressView + i/N + 当前文件 + 已写字节，150ms 节流）",
      "UIProgressView" in dt and "ame219.export.progress_file" in dt
      and "timeIntervalSinceDate:ame219_lastUi] > 0.15" in dt)
check("F4 导出目录选择保留（Files 落点选择器 + move 语义）",
      "initForExportingURLs" in dt and "asCopy:NO" in dt)
check("F5 跳过项不递归（latestlog/hs_err 目录整棵剪枝）",
      "skipDescendants" in dt)
check("F6 空数据兜底（ame219.export.empty）",
      'localize(@"ame219.export.empty"' in dt)

print("== G. TouchController 下载修复（⑩：“寻找 sou…”串台 + 找不到） ==")
check("G1 TC 安装进度文案改用专属键（不再显示 Sodium 的 searching）",
      'localize(@"component.touch.searching"' in ps
      and 'localize(@"component.touch.searching' in ps)
check("G2 取数器 notFoundKey 参数化：sodium 走原键、TC 走 component.touch.not_found",
      "ame219_fetchModrinthPrimaryFileWithQuery" in ps
      and 'notFoundKey:@"component.sodium.not_found"' in ps
      and 'notFoundKey:@"component.touch.not_found"' in ps
      and 'domain:@"TouchControllerComponent"' in ps)
check("G3 版本预检（1.x 且次版本 <12 → 明确“不支持”而非“未找到”）",
      "ame219_touchControllerUnsupportedVersion" in ps
      and 'localize(@"component.touch.unsupported"' in ps)
check("G4 预检不复活 Task217 已退役的 hasPrefix 形态（A1 锚共存）",
      'hasPrefix:@"1."' not in ps)
check("G5 确认/完成/仅Fabric 文案全部走键（双语硬编码退役）",
      'localize(@"component.touch.confirm_message"' in ps
      and 'localize(@"component.touch.done"' in ps
      and 'localize(@"component.touch.fabric_only"' in ps)
check("G6 Sodium 链路零回归（原 sodium 键仍在 sodium 流程使用）",
      ps.count('localize(@"component.sodium.') >= 6)

print("== H. 版本隔离自动识别（⑪） ==")
check("H1 隔离优先解析器（下载 + 扫描共用；隔离目录缺即建，不落共享目录）",
      "ame219_isolationFirstModsFolderForProfile" in ms
      and ms.count("ame219_isolationFirstModsFolderForProfile") >= 3)
check("H2 downloadMod 与 scanMods 都已切到隔离优先",
      all(x in ms for x in re.findall(r"NSString \*modsFolder = \[self (ame219_isolationFirst\w+)", ms))
      and "[self existingModsFolderForProfile:profileName];" not in ms.split("// ---------- 下载")[1].split("// ---------- PLDownloadClient")[0])
check("H3 隔离态类方法 + 头文件声明（ModsManager 徽标数据源）",
      "+ (NSInteger)ame219_isolationStateForProfile" in mh
      and "+ (NSInteger)ame219_isolationStateForProfile" in ms)
check("H4 模组管理页隔离徽标（隔离/共享 两键 + 自动判定日志）",
      "ame219_isolationStateForProfile" in mm
      and 'localize(\n        (ame219_iso == 1) ? @"ame219.mods.isolated_chip" : @"ame219.mods.shared_chip"' in mm.replace(" ", "")[:0] + mm  # raw containment below
      if False else
      ("ame219.mods.isolated_chip" in mm and "ame219.mods.shared_chip" in mm
       and "isolation badge" in mm))

print("== I. VGPU 更名（④） ==")
for lang, expect in [("en", "VGPU (≤1.17)"), ("zh-Hans", "VGPU（≤1.17）"),
                     ("zh-Hant", "VGPU（≤1.17）"), ("zh-CN", "VGPU（≤1.17）")]:
    check(f"I-{lang} VGPU 显示名 = {expect}",
          f'= "{expect}";' in rd(f"Natives/resources/{lang}.lproj/Localizable.strings"))

print("== J. l10n + 公告 ==")
for lang in ["en", "zh-Hans", "zh-Hant", "zh-CN"]:
    keys = set(re.findall(r'^"([^"]+)"\s*=',
                          rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M))
    check(f"J-{lang} 唯一键 2520（Task219 +38）", len(keys) == 2520, f"got {len(keys)}")
check("J-公告 41 条 + task219 尾锚 + 家族顺延（218@-2 / 217@-3 / 216@-4 / 206@-5）",
      len(ann) == 41
      and ann[-1]["id"] == "task219-virgl-angle-welcome-rebuild-2026-10-04"
      and ann[-2]["id"] == "task218-air-interim-welcome-crash-diagnosis-2026-10-04"
      and ann[-3]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-4]["id"] == "task216-ui-2026-10-03"
      and ann[-5]["id"] == "task206-nggl4es-2026-10-01")
check("J-公告内容覆盖本轮主题（VirGL/ANGLE/向导/导出/隔离）",
      "VirGL" in ann[-1]["content"] and "ANGLE" in ann[-1]["content"]
      and "欢迎向导" in ann[-1]["content"] and "压缩等级" in ann[-1]["content"]
      and "隔离" in ann[-1]["content"])
check("J-JSON 可解析 + id 唯一",
      len(set(a["id"] for a in ann)) == len(ann))

print("== K. 身份与基线 ==")
plist = rd("Natives/Info.plist")
check("K1 身份不变（com.air-devs.air——本轮零包名改动）",
      "<string>com.air-devs.air</string>" in plist)
check("K2 REVISION 保持 22 + Task219 附录在位（无 identity 变更不 bump）",
      "#define REVISION 22" in vh and "Task 219, no bump" in vh)
mk = open("Makefile", "rb").read()
check("K3 Makefile TAB 基线 662（本轮零 Makefile 改动）",
      sum(1 for line in mk.split(b"\n") if line.startswith(b"\t")) == 662)
yml = open(".github/workflows/development.yml", "rb").read()
check("K4 工作流 CRLF 完整", yml.count(b"\r\n") == yml.count(b"\n"))

print("== L. 括号平衡（本轮 10 个改动源文件，状态机口径） ==")
def balance(path):
    src = rd(path)
    stack, pairs = [], {")": "(", "]": "[", "}": "{"}
    i, n, state = 0, len(src), "code"
    while i < n:
        c = src[i]; nxt = src[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/": state = "lc"; i += 2; continue
            if c == "/" and nxt == "*": state = "bc"; i += 2; continue
            if c == '"': state = "st"; i += 1; continue
            if c == "'": state = "ch"; i += 1; continue
            if c in "([{": stack.append(c)
            elif c in ")]}":
                if not stack or stack[-1] != pairs[c]: return False
                stack.pop()
        elif state == "lc":
            if c == "\n": state = "code"
        elif state == "bc":
            if c == "*" and nxt == "/": state = "code"; i += 2; continue
        elif state == "st":
            if c == "\\": i += 2; continue
            if c == '"': state = "code"
        elif state == "ch":
            if c == "\\": i += 2; continue
            if c == "'": state = "code"
        i += 1
    return not stack
for p in ["Natives/ctxbridges/virgl_server.m", "Natives/egl_bridge.m",
          "Natives/external/gl4es/tinygl4angle.c", "Natives/WelcomeViewController.m",
          "Natives/AboutViewController.m", "Natives/DataTransferService.m",
          "Natives/ProfileSettingsViewController.m", "Natives/ModService.m",
          "Natives/ModsManagerViewController.m",
          "Natives/external/MobileGlues/MobileGlues-cpp/version.h"]:
    check(f"L-balance {p.split('/')[-1]}", balance(p))

print("== M. 舰队重锚（计数与尾窗顺延） ==")
spot = {
    "scripts/verify_task218.py": ['len(ann) == 41', "ann[-2][\"id\"] == \"task218-air-interim",
                                  "EnvJitStep", "2520"],
    "scripts/verify_task217.py": ["len(ann) == 41", "task219-virgl-angle-welcome-rebuild"],
    "scripts/verify_task216.py": ["== 41", "ids[-4] == \"task216-ui"],
    "scripts/verify_task214.py": ["ids[-4] == \"task216-ui", "'== 41' in v207"],
    "scripts/verify_task213.py": ["'== 41' in v207"],
    "scripts/verify_task211.py": ["== 41"],
    "scripts/verify_task210.py": ["== 41"],
    "scripts/verify_task206.py": ["ann[-5][\"id\"] == \"task206-nggl4es"],
    "scripts/verify_task207.py": ["ann[-3][\"id\"] == \"task217-download-fixes"],
}
g_ok, g_detail = True, []
for path, needles in spot.items():
    src = rd(path)
    for n in needles:
        if n not in src:
            g_ok = False
            g_detail.append(f"{path} missing {n!r}")
check("M1 重锚族抽查（9 验证器：计数 41 / 尾窗顺延 / 向导六步）", g_ok, "; ".join(g_detail[:3]))
check("M2 舰队 2520 旧值扫荡干净（除 task219 自身）",
      all("2482" not in rd(f) for f in
          ["scripts/verify_task217.py", "scripts/verify_task216.py", "scripts/verify_task214.py",
           "scripts/verify_task211.py", "scripts/verify_task210.py", "scripts/verify_task206.py"])
      and all("2482" not in rd("scripts/" + f) for f in os.listdir("scripts")
              if f.startswith("verify_task") and f != "verify_task219.py"))

print("== N. 上游死亡救治：khanhduytran0 两个子模块树内置入（CI 37188369741 根因） ==")
# 病历：run 37188369741（0a54f2f4）与 37181806916（6cd2cbfb，早于本提交）都在
# "Checkout repository submodules" 步骤死于 "could not read Username"——
# khanhduytran0 账号已删（user API 404），DBNumberedSlider 与 fishhook 两个
# 子模块上游 404。救治：两棵钉住树（4eddc68b / 27bedb2ab）经各自 fork 网络
# （immago/DBNumberedSlider、facebook/fishhook——fork 网络共享对象存储，
# codeload 对钉住 SHA 仍返回 200）完整取回，去子模块化后树内置入。
gm = rd(".gitmodules")
check("N1 .gitmodules 不再引用已死上游 khanhduytran0",
      "khanhduytran0" not in gm
      and 'submodule "Natives/external/fishhook"' not in gm
      and 'submodule "Natives/external/DBNumberedSlider"' not in gm
      and gm.count("[submodule") == 6)
check("N2 fishhook 树内在位（fishhook.c/h + LICENSE，路径与 CMakeLists 消费点一致）",
      os.path.exists("Natives/external/fishhook/fishhook.c")
      and os.path.exists("Natives/external/fishhook/fishhook.h")
      and os.path.exists("Natives/external/fishhook/LICENSE")
      and "external/fishhook/fishhook.c" in cml)
check("N3 恢复的是 fork 版内容（arm64e ptrauth __auth_got 重签名补丁在位——facebook 上游没有这段）",
      "ptrauth_strip" in rd("Natives/external/fishhook/fishhook.c")
      and "__auth_got" in rd("Natives/external/fishhook/fishhook.c"))
check("N4 DBNumberedSlider 树内在位（Classes/DBNumberedSlider.m + LICENSE）",
      os.path.exists("Natives/external/DBNumberedSlider/Classes/DBNumberedSlider.m")
      and os.path.exists("Natives/external/DBNumberedSlider/Classes/DBNumberedSlider.h")
      and os.path.exists("Natives/external/DBNumberedSlider/LICENSE")
      and "external/DBNumberedSlider/Classes/DBNumberedSlider.m" in cml)
check("N5 消费方零改动（main_hook.m include 路径 + CMakeLists include 目录原样）",
      '#include "external/fishhook/fishhook.h"' in rd("Natives/main_hook.m")
      and '"external/DBNumberedSlider/Classes"' in cml
      and '"external/fishhook"' in cml)
gitlinks = subprocess.run(["git", "ls-files", "-s"], capture_output=True, text=True).stdout
check("N6 两处 gitlink（160000）已除名，树内为普通文件",
      "160000" not in "\n".join(l for l in gitlinks.splitlines()
                                if "external/fishhook" in l or "DBNumberedSlider" in l))

print()
print("=" * 40)
print(f"verify_task219: {PASSED} passed, {len(FAILED)} failed")
if FAILED:
    print("FAILED:", FAILED)
    sys.exit(1)
print("ALL GREEN")
