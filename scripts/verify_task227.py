#!/usr/bin/env python3
# verify_task227.py — Task 227（13 项反馈轮）静态验证器
import io, os, re, subprocess, sys

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
passed = failed = 0
def rd(p):
    with io.open(p, encoding='utf-8', errors='replace') as f:
        return f.read()
def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}   {detail}")

def strip_comments(src):
    src = re.sub(r'/\*.*?\*/', '', src, flags=re.S)
    src = re.sub(r'//[^\n]*', '', src)
    return src

tga = rd("Natives/external/gl4es/tinygl4angle.c")
jl  = rd("Natives/JavaLauncher.m")
svc = strip_comments(rd("Natives/SurfaceViewController.m"))
ib  = rd("Natives/input_bridge_v3.m")
sdh = rd("Natives/sdl3_hook.m")
lrv = rd("Natives/LauncherRootViewController.m")
bm  = rd("Natives/BackgroundManager.m")
lgc = rd("Natives/LiquidGlassCompat.m")
rpv = rd("Natives/LauncherRightPanelViewController.m")
dlv = strip_comments(rd("Natives/DownloadViewController.m"))
mdr = rd("Natives/ModDependencyResolver.m")
mvv = strip_comments(rd("Natives/ModVersionViewController.m")
                     if os.path.exists("Natives/ModVersionViewController.m") else "")
mv  = rd("Natives/ModVersion.m")
dts = rd("Natives/DataTransferService.m")
gmh = rd("Natives/GameMenuOverlayView.h")
gmov = rd("Natives/GameMenuOverlayView.m")
nav = rd("Natives/SurfaceViewController+Navigation.m")
coach = rd("Natives/Ame223CoachMarksView.m")
mapi = rd("Natives/installer/modpack/ModrinthAPI.m")
cfapi = rd("Natives/installer/modpack/CurseForgeAPI.m")
egl = rd("Natives/egl_bridge.m")

print("== A. ANGLE 着色器崩溃 + heal ==")
check("A1 ivec 转换函数在位（Task227）",
      "ame227_fixIvecConversions" in tga
      and "ame227_collectIvecNames" in tga)
check("A2 Task219 头重写接入 ivec pass",
      "ame227_body = ame227_fixIvecConversions(ame219_eol + 1)" in tga)
check("A3 形态A除法包裹（除数须含 '.'）",
      'memchr(num, \'.\'' in tga)
check("A4 形态B赋值包裹（ivec 左值守卫）",
      "hasIvecLhs" in tga)
check("A5 heal URL 官方两段式",
      "resources.download.minecraft.net/%@/%@\", ame227_two, ame227_hash" in jl)
check("A6 bmclapi 镜像回退",
      "bmclapi2.bangbang93.com/assets/%@/%@" in jl)
check("A7 落盘前建中间目录",
      "createDirectoryAtPath:dstDir" in jl)

print("== B. sprint（输入链） ==")
svc_raw = rd("Natives/SurfaceViewController.m")
svc_lf = svc.replace("\r\n", "\n")
check("B1 toggle 态再按压 DOWN 静默",
      "Task227（反馈 #2：tap-tap 修饰键事件流 2:1）" in svc_raw
      and "containsObject:@(keycode)]) {" in svc_lf
      and "continue;" in svc_lf)
check("B2 control 键全量取证",
      "Task227 controlKey: key=%d action=%d" in ib)
check("B3 SDL 事件 ev.mod 取自 modstate",
      "ev.mod = pSDL_GetModState" in ib)

print("== C. 键盘关闭闩锁 ==")
check("C1 闩锁状态在位",
      "ame227_kbUserDismissed" in svc)
check("C2 游离 Start 抑制（真输入意图门）",
      "stray StartTextInput SUPPRESSED" in svc
      and "ame161_lastSentKeyWasChatOpener(3.0)" in svc)
check("C3 输入法按钮收起置闩 / 打开清闩",
      "Task227 latch armed" in svc
      and "ame227_kbUserDismissed = NO;" in svc)
check("C4 触摸信号（0.8s 窗）",
      "ame227_lastTouchAt = CFAbsoluteTimeGetCurrent();" in svc)

print("== D. 液态玻璃收敛 ==")
check("D1 chrome 玻璃回退（sidebar/rightPanel）",
      "LGCRemoveGlassFromView(self.sidebarContainer)" in lrv
      and "LGCApplyGlassToView(self.sidebarContainer, 16)" not in lrv)
check("D2 列表卡面玻璃回退",
      "LGCRemoveGlassFromView(cardTarget);" in bm
      and "LGCApplyGlassToView(cardTarget, cardRadius)) {" not in bm)
check("D3 组合玻璃默认 + 系统 UIGlassEffect opt-in 逃生阀【Task228 重锚：装机实锤系统玻璃黑面，默认反转】",
      "_LGCCreateGlassEffect(isDark)" in lgc
      and "AME227_SYSTEM_GLASS" in lgc
      and 'strcmp(ame228_env, "1") == 0' in lgc
      and "ame228_compositeLogged" in lgc)
check("D4 头像长按玻璃菜单（风格门控）",
      "ame227_presentGlassMenu:" in rpv
      and "LGCIsGlassStyleActive()" in rpv)

print("== E. 依赖自动下载（issue #10 重做） ==")
check("E1 ModDependencyResolver 移植在位",
      os.path.exists("Natives/ModDependencyResolver.m")
      and "resolveDependenciesFromVersionDetail" in mdr)
check("E2 双源归一（Modrinth project_id / CF modId relationType）",
      "dependency_type" in mdr and "relationType" in mdr)
check("E3 防环 + 上限（visited/64/深度8）",
      "kMaxProjects = 64" in mdr and "kMaxDepth = 8" in mdr)
check("E4 ModVersion.rawDictionary 双源留存",
      "_rawDictionary = [dictionary copy];" in mv)
check("E5 didSelectVersion 前置解析钩子",
      "resolveDependenciesFromVersionDetail:version.rawDictionary" in dlv)
check("E6 PCL2CE 确认单（仅本体/全部安装）",
      'localize(@"ame227.deps.only_mod", nil)' in dlv
      and 'localize(@"ame227.deps.install_all", nil)' in dlv)
check("E7 依赖名 enrichment（双源项目名接口）",
      "ame227_fetchProjectTitle" in mapi and "ame227_fetchModTitle" in cfapi)
check("E8 版本页前置 footer",
      "ame227_refreshDependenciesFooter" in mvv
      and "ame227.deps.footer" in mvv)
check("E9 后置钩子退役",
      "ame226_offerModDependenciesIfModrinth" not in dlv)

print("== F. SDL 打开文件夹 ==")
check("F1 SDL_OpenURL 钩子注册",
      'strcmp(name, "SDL_OpenURL") == 0' in sdh)
check("F2 file:// → FolderBrowser 路由",
      "hasPrefix:@\"file:\"]" in sdh and "openURLGlobal" in sdh)
check("F3 http(s) → 系统浏览器",
      "hasPrefix:@\"https:\"]" in sdh)

print("== G. 齿轮侧边栏 ==")
check("G1 阈值门控吸附（非一直吸）",
      "kAme227DockThreshold" in gmov and "ame227_nearEdge" in gmov)
check("G2 dock 把手变形 + 持久化",
      "kAme227HandleWidth" in gmov and "game.gear.docked" in gmov)
check("G3 dock 状态公开（isDocked/dockedLeft）",
      "isDocked" in gmh and "dockedLeft" in gmh)
check("G4 docked 点击开侧滑面板",
      "ame227_sideDrawer" in nav)

print("== H. 备份导入闭环 ==")
check("H1 导入后立即触发实例合并迁移",
      "init_setupMultiDir();" in dts)
check("H2 当前实例核对日志",
      "restored-instance-present" in dts)
check("H3 导入完成带文件计数",
      "ame227.import.done" in dts)

print("== I. 教练标记重建 ==")
check("I1 stage/card 实底自适应（不再 UIVisualEffectView）",
      "systemBackgroundColor] colorWithAlphaComponent:0.94" in coach
      and "_ame224_stage = [[UIView alloc] init]" in coach)
check("I2 卡片位置双端钳制",
      "ame224_cardY = MIN(ame224_cardY" in coach)
check("I3 contentView 引用已清理",
      "_ame224_card.contentView" not in coach
      and "_ame224_stage.contentView" not in coach)

print("== J. 全局白底黑边字体 ==")
check("J1 UILabel setText: swizzle 在位",
      "ame227_swizzledLabelSetText" in bm
      and "class_getInstanceMethod(self, @selector(setText:))" in bm)
check("J2 描边字体（白填充+黑描边 2.6）",
      "NSStrokeWidthAttributeName: @(-2.6)" in bm)
check("J3 无壁纸零干预（hasBackground 门控）",
      "if (![[BackgroundManager sharedManager] hasBackground]) return;" in bm)

print("== K. i18n ==")
langs = ["en", "zh-Hans", "zh-Hant", "zh-CN"]
keys = {}
for l in langs:
    ks = set()
    for line in io.open(f"Natives/resources/{l}.lproj/Localizable.strings", encoding='utf-8'):
        if line.startswith('"') and '" = "' in line:
            ks.add(line.split('"')[1])
    keys[l] = ks
check("K1 四语言键集一致且 2715",
      keys["en"] == keys["zh-Hans"] == keys["zh-Hant"] == keys["zh-CN"]
      and len(keys["en"]) == 2715, f"counts={[len(keys[l]) for l in langs]}")
ja_ks = set()
for line in io.open("Natives/resources/ja.lproj/Localizable.strings", encoding='utf-8'):
    if line.startswith('"') and '" = "' in line:
        ja_ks.add(line.split('"')[1])
check("K2 ja coachmarks 14 键补齐",
      len([k for k in ja_ks if k.startswith("coachmarks.")]) == 14)
check("K3 ja ame227 7 键补齐",
      len([k for k in ja_ks if k.startswith("ame227.")]) == 7)
used = set()
for f in ["Natives/DownloadViewController.m", "Natives/ModVersionViewController.m",
          "Natives/DataTransferService.m", "Natives/Ame223CoachMarksView.m"]:
    for m in re.finditer(r'localize\(@"([a-zA-Z0-9_.]+)"', rd(f)):
        used.add(m.group(1))
check("K4 本轮触碰文件 used ⊆ defined（en）",
      used <= keys["en"], f"missing={sorted(used - keys['en'])[:5]}")

print("== L. 上游合流 ==")
check("L1 br_init 空指针兜底（上游 c9b568da72 P0）",
      "br_init == NULL" in egl
      and "refusing to call" in egl)

print("== M. 门 ==")
r = subprocess.run(["python3", "scripts/task139_syntax_gate.py"], capture_output=True, text=True)
check("M1 task139 语法门",
      "NOT balanced" not in r.stdout, r.stdout[-120:])
r = subprocess.run(["bash", "scripts/task193_tinygl_syntax.sh"], capture_output=True, text=True)
check("M2 tinygl 语法门",
      "SYNTAX OK" in (r.stdout + r.stderr), (r.stdout + r.stderr)[-120:])

print()
print("=" * 72)
print(f"==== RESULT: {'ALL PASS' if failed == 0 else 'FAILED'} ({passed} passed, {failed} failed) ====")
sys.exit(0 if failed == 0 else 1)
