#!/usr/bin/env python3
"""verify_task229 -- Task 229 (11-item feedback round on the Task228 build,
e24a60a9 log set) anchor verification.

Item map:
  1  ANGLE non-SDL crash + bg input offset   -> A (AppKitStub ext) + B (resume hook)
  2  sprint dead + right shift relapsed      -> B (mod replay) + C (toggleSprint + keybind sync)
  3  liquid glass floating bar no effect     -> D (menu composite glass)
  4  dependency sheet + footer dead          -> E (apiSource + sniff)
  5  folder browser blank / SDL dead         -> F (solid sheet + CTC-on-SDL3)
  6  keyboard cannot close                   -> G (hard suppression window)
  7  gear un-openable + FCL auto-IME switch  -> H (pan threshold + switch)
  8  backup import no effect                 -> I (pickerMode + logging)
  9  welcome tour blank                      -> J3 (coach label exemption)
  10 stroke font black lines                 -> J1 (stroke rework)
  11 i18n completeness                       -> K (12 keys x 5 langs + audits)
"""
import re, subprocess, sys, os

os.chdir('/home/z/my-project/Amethyst-iOS-MyRemastered')
PASS = 0; FAIL = 0
def check(name, cond, detail=""):
    global PASS, FAIL
    if cond: PASS += 1; print(f"[PASS] {name}")
    else: FAIL += 1; print(f"[FAIL] {name} {detail}")

def rd(p): return open(p, encoding='utf-8', errors='replace').read()

# ---------- A: AppKitStub extension (JavaLauncher.m) ----------
jl = rd('Natives/JavaLauncher.m')
check("A1 NSImage stub class registered", 'objc_allocateClassPair(objc_getClass("NSObject"), "NSImage", 0)' in jl)
check("A2 NSData legacy b64 selector added", 'initWithBase64Encoding:' in jl and 'class_addMethod(nsDataCls' in jl)
check("A3 install hooked at JLI_Launch site", jl.count('ame229_installIconPathStubs();') == 1)
check("A4 NSImage stub initWithData IMP", 'ame229_image_initWithData' in jl)
check("A5 install anchor log", 'Task229: NSImage stub + NSData legacy-b64 selector installed' in jl)
# the stub install must be idempotent + guarded
check("A6 real-macOS guard", 'real NSImage present, icon stubs not needed' in jl)
# structural: functions must live OUTSIDE ame99 (the brace we restored)
i99 = jl.find('static void ame99_installAppKitMenuStubs(void)')
i99end = jl.find('ame229_image_initWithData')
seg = jl[i99:i99end]
# the ame99 body must contain its own closing brace before the Task229 comment
import re as _re
closing = _re.search(r'numberOfItems=0\)"\);\n}', seg)
check("A7 ame99 closed before Task229 functions", closing is not None)

# ---------- B: resume reassert (input_bridge + SceneDelegate) ----------
ib = rd('Natives/input_bridge_v3.m')
sd = rd('Natives/SceneDelegate.m')
check("B1 resume reassert defined", 'void ame229_inputResumeReassert(void)' in ib)
check("B2 cursor baseline reset", 'cLastX = cursorX;' in ib and 'cLastY = cursorY;' in ib)
check("B3 toggle-held mod replay map", 'ame229_modMap' in ib and '{AME66_KMOD_RSHIFT, 229}' in ib)
check("B4 ACTION_MOVE baseline refresh (Task232 重锚：Task230 DOWN 重锚后 MOVE+DOWN 双写点)", ib.count('cLastX = x;') == 2)
check("B5 SceneDelegate hook", 'ame229_inputResumeReassert();' in sd)
check("B6 CTC register-on-SDL3 helper", 'static void ame229_registerCTCOnce(void)' in ib)
check("B7 GetCreatedJavaVMs recovery", 'JNI_GetCreatedJavaVMs' in ib)
check("B8 called from Amethyst_SetSDLWindow", 'ame229_registerCTCOnce();' in ib)
check("B9 SDL3-path anchor log", 'Task229 CTCDesktopPeer natives registered via Amethyst_SetSDLWindow' in ib)

# ---------- C: sprint toggle + keybind sync (LauncherPreferencesViewController.m) ----------
lp = rd('Natives/LauncherPreferencesViewController.m')
check("C1 all-instance options scanner", 'ame229_allInstanceOptionsPaths' in lp)
check("C2 toggleSprint writer", 'ame229_writeToggleSprint:toOptions:' in lp or 'ame229_writeToggleSprint' in lp)
check("C3 keybind sync method", 'ame229_syncKeybindsAcrossInstances' in lp)
check("C4 sprint settings entry", '"mc_toggle_sprint"' in lp)
check("C5 keybind sync settings entry", '"keybind_sync"' in lp)
check("C6 toggleSprint log typo fixed", 'toggleSprint written' in lp and 'toggleSpring written' not in lp)

# ---------- D: floating menu glass (SurfaceViewController+Navigation.m) ----------
# Task237 重锚：游戏内菜单面板已彻底重写为自定义 UIView（旧 UITableView +
# LGCApplyGlassToView 塞玻璃层的路线被用户明令退役）。本区锚点改为验证
# 同一关切在 Task237 现实下的形态：风格应用函数存在、磨砂层分层受控、
# 内容恒在磨砂之上、风格切换广播接力不变。
nav = rd('Natives/SurfaceViewController+Navigation.m')
check("D1 style apply helper (Task237 renamed)", 'ame237_applyMenuStyle' in nav and 'ame229_reapplyMenuGlass' not in nav)
check("D2 LGC glass-in-table retired (Task237)", 'LGCApplyGlassToView(self.menuView' not in nav and
      'LGCRemoveGlassFromView(self.menuView' not in nav)
check("D3 layered blur at index 0 + rows above (Task237)", 'insertSubview:ame237_blur atIndex:0]' in nav and
      'bringSubviewToFront:ame237_scroll' in nav)
check("D4 style-gated", 'LGCIsGlassStyleActive()' in nav)
check("D5 style-change observer", 'ame229_handleBackgroundUIEffectChanged' in nav and 'BackgroundUIEffectChanged' in nav)
check("D6 import present", 'LiquidGlassCompat.h' in nav)

# ---------- E: dependency resolver (ModVersion.m + ModDependencyResolver.m) ----------
mv = rd('Natives/ModVersion.m')
res = rd('Natives/ModDependencyResolver.m')
check("E1 Modrinth apiSource set", '_apiSource = 1;   // Modrinth' in mv)
check("E2 apiSource only in Modrinth branch + CF branch keeps 2", mv.count('_apiSource = 2;') == 1)
check("E3 shape sniffing fallback", 'ame229_mrShape' in res and 'ame229_cfShape' in res)
check("E4 sniff only when not declared Modrinth", 'if (apiSource != 1) {' in res)

# ---------- F: folder browser + label exemption ----------
fb = rd('Natives/FolderBrowserViewController.m')
import re as _re
_fb_code = _re.sub(r'//[^\n]*', '', _re.sub(r'/\*.*?\*/', '', fb, flags=_re.S))
check("F1 solid sheet (no code-level transparency call)", _fb_code.count('makeViewControllerTransparent') == 0)
check("F2 systemBackground view", 'systemBackgroundColor];' in fb)
check("F3 empty state on tableHeaderView", 'tableHeaderView = ame229_hv' in fb)
check("F4 cell labels exempt from stroke", fb.count('ame229_labelSetStrokeExempt') == 5)

# ---------- G: keyboard latch hard suppression (SurfaceViewController.m) ----------
svc = rd('Natives/SurfaceViewController.m')
check("G1 hard suppression window", 'Task229 hard suppression' in svc)
check("G2 2.5s window constant (Task232 重锚：硬抑制块变量随 ⑫ 重排更名)", 'ame232_sinceDismiss < 2.5' in svc)
check("G3 recent-touch clear retired", 'recent touch"' not in svc)
check("G4 chat-opener still honored (post-window)", "CLEARED (chat-opener key, %.1fs after dismissal)" in svc)

# ---------- H: gear pan threshold + auto-IME switch ----------
gm = rd('Natives/GameMenuOverlayView.m')
check("H1 pan shouldBegin gate", 'gestureRecognizerShouldBegin' in gm)
check("H2 gear pan threshold (Task232 重锚：Task230 重写为 pan 恒开始 + Ended 手动补 tap)", 'Task230 gear manual tap-fire' in gm)
check("H3 tap-chain logging", 'Task229 gear tap #' in gm)
check("H4 pan delegate set", 'pan.delegate = self;' in gm)
check("H5 auto-keyboard gate (first Start only)", 'ame229_autoKbShownThisSession' in svc)
check("H6 pref key", 'control.auto_keyboard_sdl' in svc)
check("H7 settings switch", '"auto_keyboard_sdl"' in lp)
check("H8 session reset in viewDidLoad", 'ame229_autoKbShownThisSession = NO;' in svc)
check("H9 unbound-button diagnostic", 'Task229 UNBOUND button pressed' in svc)

# ---------- I: import picker mode (DataTransferService.m) ----------
dts = rd('Natives/DataTransferService.m')
check("I1 picker mode enum", 'Ame229PickerModeImportZip' in dts and 'Ame229PickerModeExportDestination' in dts)
check("I2 mode consumed on dispatch", 'self.ame229_pickerMode = Ame229PickerModeNone;' in dts)
check("I3 import presented log", 'Task229: import picker presented' in dts)
check("I4 didPick log", 'Task229: didPickDocumentsAtURLs' in dts)
check("I5 cancelled log", 'Task229: picker cancelled' in dts)
check("I6 import branch routes to performImport", 'ame229_mode == Ame229PickerModeImportZip' in dts)
check("I7 export sites set mode", dts.count('Ame229PickerModeExportDestination') == 4)

# ---------- J: font stroke rework (BackgroundManager.m + coach marks) ----------
bm = rd('Natives/BackgroundManager.m')
cm = rd('Natives/Ame223CoachMarksView.m')
check("J1 stroke width (Task232 重锚：⑯ CoreText stroke 退役，四方向 0.6pt 外扩描边)", "NSStrokeWidthAttributeName" not in bm and "ame232_swizzledLabelDrawTextInRect" in bm)
check("J2 semi-transparent stroke color", 'colorWithWhite:0.0 alpha:0.82' in bm)
check("J3 shadow (Task232 重锚：⑯ 光晕整体退役——零偏移模糊向字腔渗黑，职责全交外扩描边)", "shadowRadius = 2.5" not in bm and "shadowOpacity = 0.0" in bm)
check("J4 exemption API", 'ame229_labelSetStrokeExempt' in bm and 'ame229_labelIsStrokeExempt' in bm)
check("J5 swizzle honors exemption", 'if (ame229_labelIsStrokeExempt((UILabel *)self)) return;' in bm)
check("J6 coach title exempt", cm.count('ame229_labelSetStrokeExempt') == 3)

# ---------- K: i18n ----------
KEYS = ['preference.title.auto_keyboard_sdl', 'preference.title.mc_toggle_sprint',
        'preference.title.keybind_sync', 'ame229.sprint.title', 'ame229.sprint.on.desc',
        'ame229.sprint.off.desc', 'ame229.sprint.turn_on', 'ame229.sprint.turn_off',
        'ame229.sprint.result', 'ame229.keybind.sync.one_instance',
        'ame229.keybind.sync.no_bindings', 'ame229.keybind.sync.done']
for lang in ['en', 'zh-Hans', 'zh-Hant', 'zh-CN', 'ja']:
    p = f'Natives/resources/{lang}.lproj/Localizable.strings'
    c = rd(p)
    missing = [k for k in KEYS if f'"{k}" =' not in c]
    check(f"K {lang}: all 12 Task229 keys present", not missing, f"missing {missing}")

# used-subset audit: every localize(@"..." key in touched UI files exists in en+zh-Hans
used = set()
for f in ['Natives/LauncherPreferencesViewController.m', 'Natives/FolderBrowserViewController.m',
          'Natives/SurfaceViewController.m', 'Natives/SurfaceViewController+Navigation.m']:
    for m in re.finditer(r'localize\(@"([A-Za-z0-9_.\-]+)"', rd(f)):
        used.add(m.group(1))
en = rd('Natives/resources/en.lproj/Localizable.strings')
zh = rd('Natives/resources/zh-Hans.lproj/Localizable.strings')
miss_en = [k for k in sorted(used) if f'"{k}" =' not in en]
miss_zh = [k for k in sorted(used) if f'"{k}" =' not in zh]
check("K used-subset audit (en)", not miss_en, f"missing {miss_en[:6]}")
check("K used-subset audit (zh-Hans)", not miss_zh, f"missing {miss_zh[:6]}")

# ---------- syntax gates ----------
r = subprocess.run([sys.executable, 'scripts/task139_syntax_gate.py'], capture_output=True, text=True)
check("L task139 syntax gate", r.returncode == 0, r.stdout[-200:] if r.returncode else "")
r = subprocess.run([sys.executable, 'scripts/task225_bracket_audit.py'], capture_output=True, text=True)
check("L bracket audit (touched files)", 'FAIL' not in r.stdout, r.stdout[-300:] if 'FAIL' in r.stdout else "")

print(f"\n===== verify_task229: {PASS} PASS / {FAIL} FAIL =====")
sys.exit(1 if FAIL else 0)
