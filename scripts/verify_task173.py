#!/usr/bin/env python3
# verify_task173.py — Task 173 (ten-symptom round) verification.
# Sections:
#   A. git-pinned device-log forensics (fd31b79 three sessions)
#   B. ANGLE desktop-GL completion layer (tinygl4angle.c) + latent bug fixes
#   C. old-Forge Tools.java NPE guards
#   D. memory ceiling (utils.m / ProfileSettingsViewController.m)
#   E. CurseForge sorting + modpack downloads + ModVersion mirror + Modrinth index
#   F. version picker completion + manifest mirror chain
#   G. TouchController Sodium-style component
#   H. avatar home-VC reuse (both layouts)
#   I. wallpaper slider Auto Layout
#   J. Forge-JIT restart-and-launch flow
#   K. VGPU renderer integration (CMake + registry + l10n + egl_bridge)
#   L. renderer label/auto changes + l10n
#   M. docs (version.h addendum, announcements)
#   N. no-regression cascade (balance gates + core verifiers)
import subprocess, sys, os, json

# Task174 可移植化收尾（169/135/164 家法）：会话本地旧仓硬编码路径在此
# 沙箱缺席导致本脚本中途 FileNotFoundError；改为脚本仓两级 dirname。
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = 0
FAIL = 0
FAILED = []

def rd(path):
    with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as f:
        return f.read()

def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args),
                          capture_output=True, text=True).stdout

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS {name}")
    else:
        FAIL += 1
        FAILED.append(name)
        print(f"  FAIL {name} {detail}")

def strip_comments(s):
    out = []
    for line in s.splitlines():
        # keep pragma-adjacent code; drop // comments (code-state checks)
        i = line.find("//")
        out.append(line[:i] if i >= 0 else line)
    return "\n".join(out)

print("== A. device-log forensics (fd31b79, git-pinned) ==")
log_angle = git("show", "fd31b79:latestlog.old.txt")
log_zombie = git("show", "fd31b79:latestlog.old")
log_forge189 = git("show", "fd31b79:latestlog.txt")
check("A1 ANGLE session present (FO pack)",
      "Fabulously Optimized" in log_angle or "ComplementaryReimagined" in log_angle)
check("A2 ANGLE GL backend accepted (Task172 mirror worked)",
      "Using graphics backend OpenGL" in log_angle and "pojavInitOpenGLForSDL3()=0" in log_angle)
check("A3 ANGLE crash chain: pipeline/gui",
      "Failed to find or load pipeline minecraft:pipeline/gui" in log_angle)
check("A4 ANGLE NULL-pointer signature (LWJGL unavailable fn)",
      "No context is current or a function that is not available" in log_angle)
check("A5 Iris GLSL semver failure on ANGLE string",
      'Could not parse GL version from "OpenGL GLSL 3.30' in log_angle)
check("A6 zombie session: 7165MB allocation",
      "launch memory from instance profile: 7165 MB" in log_zombie)
check("A7 zombie session: 244 mods loaded",
      log_zombie.count("Found mod file") >= 240)
check("A8 zombie session: abrupt death (no exit marker in tail)",
      "exit(" not in log_zombie[-2000:])
check("A9 old-Forge session: NPE at Tools 752",
      "java.lang.NullPointerException" in log_forge189 and "Tools.java:752" in log_forge189)
check("A10 old-Forge session: crash before window creation",
      "swapOK=0 swapFail=0" in log_forge189)

print("== B. tinygl4angle desktop-GL completion layer ==")
tgl = rd("Natives/external/gl4es/tinygl4angle.c")
for fn in ["glColorMaski", "glEnablei", "glDisablei", "glBlendFuncSeparatei",
           "glBlendEquationSeparatei", "glFramebufferTexture", "glTexBuffer",
           "glTexBufferRange", "glVertexAttribDivisor", "glCopyImageSubData",
           "glTexImage1D", "glQueryCounter", "glDrawElementsBaseVertex",
           "glDrawElementsInstancedBaseVertex", "glMultiDrawArrays",
           "glMultiDrawElements", "glDepthRange", "glGetDoublev"]:
    check(f"B wrapper {fn}", f"void {fn}(" in tgl)
check("B eglGetProcAddress resolution chain", "ame173_gpa_multi" in tgl and "eglGetProcAddress" in tgl)
check("B suffix fallback family", '"EXT", "OES", "KHR", "NV", "ARB"' in tgl)
check("B glShaderSource ES-branch uploads (latent bug fixed)",
      "Task173 bug fix" in tgl and tgl.count("gles_glShaderSource(shader, 1") >= 1)
check("B GLSL version prefix normalization (Iris)",
      "OpenGL GLSL " in tgl and "normalized" in tgl)
check("B forensics one-shot log", "desktop-GL completion layer" in tgl)
check("B slot-0 degradation guards",
      tgl.count("} else if (buf == 0) {") >= 3)
check("B logic-op no-op", "void glLogicOp(GLenum opcode)" in tgl)
tglcm = rd("Natives/CMakeLists.txt")
check("B tinygl4angle objective-c dialect forced",
      'COMPILE_OPTIONS "-x;objective-c;-fobjc-arc"' in tglcm and
      "external/gl4es/tinygl4angle.c PROPERTIES" in tglcm)

print("== C. old-Forge Tools.java NPE guards ==")
tj = rd("JavaApp/src/launcher/net/kdt/pojavlaunch/Tools.java")
tjc = strip_comments(tj)
check("C1 customLibraries null guard",
      "customVer.libraries != null) ? customVer.libraries : new DependentLibrary[0]" in tj)
check("C2 inheritLibraries null guard",
      "inheritsVer.libraries != null) ? inheritsVer.libraries : new DependentLibrary[0]" in tj)
check("C3 null library entry skips",
      "if (library == null || library.name == null)" in tj)
check("C4 null inheritLibrary skips",
      "if (inheritLibrary == null || inheritLibrary.name == null)" in tj)
check("C5 inheritsVer null -> locatable error",
      "Parent version JSON for" in tj and "inheritsVer == null" in tj)
check("C6 fuse uses guarded arrays",
      "inheritLibraryList.addAll(Arrays.asList(customLibraries));" in tj)

print("== D. memory ceiling (Jetsam root fix) ==")
u = rd("Natives/utils.m")
check("D1 ame173_safeHeapCeilingMB defined", "int ame173_safeHeapCeilingMB(void)" in u)
check("D2 os_proc_available_memory used", "os_proc_available_memory" in u and "libproc.h" in u)
check("D3 1.2GB native reserve", "availMB - 1200" in u)
check("D4 floor 1024", "ceilingMB = 1024;" in u)
check("D5 launch clamp wired into ame141",
      "Task173：Jetsam 安全钳制" in u and "mem = ame173_ceiling;" in u)
# Task189 重锚：钳制 toast 文案迁 i18n 键 ame189.utils.mem_clamped
#（en 值保留 "exceeds the device limit; clamped" 语义；zh 值为原文案）。
check("D6 toast on clamp（Task189 i18n 键形态）", "ame189.utils.mem_clamped" in u)
uh = rd("Natives/utils.h")
check("D7 header declares ceiling", "int ame173_safeHeapCeilingMB(void);" in uh)
ps = rd("Natives/ProfileSettingsViewController.m")
check("D8 slider capped at ceiling+512",
      "ame173_safeHeapCeilingMB() + 512" in ps)

print("== E. CurseForge sorting/modpacks + Modrinth index ==")
cf = rd("Natives/installer/modpack/CurseForgeAPI.m")
check("E1 sortField mapping helper", "ame173_applySortAndLoaderParams" in cf)
check("E2 CF sort enums (2/6/3)",
      'params[@"sortField"] = @2;' in cf and 'params[@"sortField"] = @6;' in cf and 'params[@"sortField"] = @3;' in cf)
check("E3 loader enum map (forge1/fabric4/quilt5/neoforge6)",
      '"forge": @1' in cf and '"fabric": @4' in cf and '"quilt": @5' in cf and '"neoforge": @6' in cf)
check("E4 async URL appends sort+loader", 'appendFormat:@"&sortField=%@&sortOrder=%@"' in cf)
check("E5 sync path applies params", cf.count("ame173_applySortAndLoaderParams:searchFilters params:params") == 1)
check("E6 CDN path unpadded (403 fix)",
      "%ld/%ld/%@" in cf and "%03ld" not in strip_comments(cf))
mv = rd("Natives/ModVersion.m")
check("E7 CF downloadUrl mirror-resolved",
      "PLMirrorCenter preferredURLForOriginalURL" in mv and "PLMirrorResourceTypeAssetDownload" in mv)
mr = rd("Natives/installer/modpack/ModrinthAPI.m")
check("E8 ame173_indexForSort helper", "ame173_indexForSort" in mr)
check("E9 three call sites wired", mr.count("ame173_indexForSort:") >= 4)  # 1 def + 3 calls
check("E10 hardcoded index retired",
      'query.length > 0 ? @"relevance" : @"follows"' not in strip_comments(mr))

print("== F. version picker completion + manifest chain ==")
dl = rd("Natives/DownloadViewController.m")
check("F1 numeric-release filter (26.x accepted)", "ame173_digits" in dl and "characterIsMember:ame173_first" in dl)
# Task179 重锚：下限放宽到 1.7（用户"再加多点低版本"），1.8 地板退役。
check("F2 1.7 floor for 1.x line (Task179 重锚：自 1.8 放宽)", "ame179_minor < 7) continue" in dl)
# Task179 重锚：64 封顶退役（低版本扩容后全量展示）。
check("F3 cap retired (Task179 重锚：无 64/32 截断)", "versions.count > 64" not in dl and "versions.count > 32" not in dl)
check("F4 full fallback list", '"1.12.2"' in dl and '"1.8.9"' in dl and '"26.3"' in dl)
check("F5 manifest candidate chain", "candidateURLsForOriginalURL" in dl and "PLMirrorResourceTypeGameFile" in dl)
check("F6 PLMirrorCenter import", '#import "PLMirrorCenter.h"' in dl)
check("F7 failover loop", "trying next candidate" in dl)

print("== G. TouchController Sodium-style component ==")
check("G1 moved to components section (index 2)",
      '@[@"Fabric API", @"Sodium + Iris Shaders", @"TouchController", @"OptiFine"]' in ps)
check("G2 install method exists", "- (void)installTouchControllerStandalone {" in ps)
check("G3 startInstall method exists", "- (void)startInstallTouchControllerWithGameVersion:(NSString *)gameVersion {" in ps)
check("G4 Fabric gate (Task219 l10n)", 'localize(@"component.touch.fabric_only"' in ps
      and "TouchController" in ps)
check("G5 Modrinth exact-title fetch", 'exactTitle:@"touchcontroller"' in ps)
check("G6 auto-config armed on success", "profile auto-config armed" in ps)
check("G7 touchControllerEnabled write", "weakSelf.touchControllerEnabled = YES;" in ps)
check("G8 cell in section 2 with hand icon",
      'systemImageNamed:@"hand.tap.fill"' in ps)
check("G9 row removed from advanced section",
      '[advancedRows addObject:@"TouchController"];' not in ps)
check("G10 old picker retired",
      "- (void)showTouchControllerSelector {" not in ps)

print("== H. avatar home-VC reuse ==")
lr = rd("Natives/LauncherRootViewController.m")
lc = rd("Natives/LauncherCardLayoutViewController.m")
check("H1 root caches home VC", "cachedHomeVC" in lr)
check("H2 root reuse branch", "home VC reused (avatar survives tab switch)" in lr)
check("H3 card caches home VC", "cachedHomeVC" in lc)
check("H4 card initial page registers cache", "self.cachedHomeVC = newsVC;" in lc)
check("H5 card reuse branch", "avatar survives tab switch" in lc)
check("H6 setContentViewController same-instance early return (prereq)",
      "if (viewController == _contentViewController) return;" in lr)

print("== I. wallpaper slider Auto Layout ==")
bg = rd("Natives/BackgroundSettingsViewController.m")
check("I1 unified row spec table", "ame173_rowSpec" in bg)
check("I2 centerY anchors", bg.count("centerYAnchor constraintEqualToAnchor:cell.contentView.centerYAnchor") >= 3)
check("I3 constraint-built sliders", "translatesAutoresizingMaskIntoConstraints = NO" in bg)
check("I4 no y=0 frames remain", "CGRectMake(150, 0," not in bg and "CGRectMake(165, 0," not in bg)
check("I5 slider floor semantics (Task210 重锚：壁纸透明度行 0.1 下限/模糊行 0.0 起步的三元式在位；新拟态滑条行已删)", 'slider.minimumValue = (indexPath.row == 1) ? 0.1f : 0.0f;' in bg)

print("== J. Forge-JIT restart-and-launch ==")
jl = rd("Natives/JavaLauncher.m")
rp = rd("Natives/LauncherRightPanelViewController.m")
ib = rd("Natives/ios_uikit_bridge.m")
check("J1 launchJVM guard offers restart", "ame173_showJvmUsedRestartDialog" in jl)
check("J2 dialog writes autolaunch key", 'setPrefObject(@"internal.autolaunch_profile", profileName)' in ib)
check("J3 dialog exits after 2s", "exit(0);" in ib)
check("J4 right panel consumes key", 'getPrefObject(@"internal.autolaunch_profile")' in rp)
check("J5 profile selected on cold start", "setSelectedProfileName:ame173_autolaunch" in rp)
check("J6 delayed launchGame", "[strongSelf launchGame];" in rp and "1.5 * NSEC_PER_SEC" in rp)
check("J7 header declaration", "ame173_showJvmUsedRestartDialog(NSString *profileName);" in rd("Natives/ios_uikit_bridge.h"))

print("== K. VGPU renderer integration ==")
cm = rd("Natives/CMakeLists.txt")
check("K1 CMake vgpu target", "add_library(vgpu SHARED" in cm)
check("K2 two OBJECT libs (basename collision)", "add_library(vgpu_pack OBJECT" in cm and "add_library(vgpu_core OBJECT" in cm)
# Task179 重锚：+NOEGL（1.8.9+vgpu 崩溃根修——临时 EGL 探测路径在 iOS 全灭）。
check("K3 Android-parity defines (Task179 重锚：+NOEGL)", "NOX11 NO_GBM NOEGL DEFAULT_ES=3 SHAREDLIB" in cm)
vgpu_exists = os.path.isdir(os.path.join(REPO, "Natives/external/vgpu/src"))
check("K4 vendored source tree", vgpu_exists)
if vgpu_exists:
    loadc = rd("Natives/external/vgpu/src/gl/pack/load.c")
    check("K5 @rpath framework dlopens", '@rpath/libGLESv2.framework/libGLESv2' in loadc)
    glxc = rd("Natives/external/vgpu/src/glx/glx.c")
    check("K6 android log removed from glx.c", "#include <android/log.h>" not in glxc)
    stc = rd("Natives/external/vgpu/src/gl/stencil.c")
    check("K7 clang implicit-decl fixes (stencil fwd decls)", "gl4es_glStencilFunc" in stc and "gl4es_glStencilOp" in stc)
uh2 = rd("Natives/utils.h")
check("K8 RENDERER_NAME_VGPU macro", '#define RENDERER_NAME_VGPU "libvgpu.dylib"' in uh2)
eb = rd("Natives/egl_bridge.m")
check("K9 egl_bridge VGPU branch", "RENDERER_NAME_VGPU" in eb and "VGPU renderer" in eb)
lp = rd("Natives/LauncherPreferences.m")
check("K10 renderer registry entry", "RENDERER_NAME_VGPU" in lp and "preference.title.renderer.debug.vgpu" in lp)
vm = rd("Natives/VersionManagerViewController.m")
check("K11 short-name map", '@ RENDERER_NAME_VGPU: @"VGPU"' in vm)
for lang in ["en", "ja", "km", "zh-CN", "zh-Hans", "zh-Hant"]:
    s = rd(f"Natives/resources/{lang}.lproj/Localizable.strings")
    check(f"K12 l10n vgpu {lang}", "preference.title.renderer.debug.vgpu" in s)

print("== L. renderer label/auto changes ==")
s_en = rd("Natives/resources/en.lproj/Localizable.strings")
check("L1 auto label suffix dropped (en)", '"preference.title.renderer.debug.auto" = "Auto";' in s_en)
check("L2 mgfamily annotated (en)", '"preference.title.renderer.debug.mgfamily" = "MobileGlues (1.17+)";' in s_en)
s_zh = rd("Natives/resources/zh-Hans.lproj/Localizable.strings")
check("L3 auto label zh", '"preference.title.renderer.debug.auto" = "自动";' in s_zh)
check("L4 mgfamily zh", '"preference.title.renderer.debug.mgfamily" = "MobileGlues (1.17+)";' in s_zh)
# Task217 重锚：auto 分支重构为 ame217_autoRendererDecide 候选链函数
#（版本基线语义不变：legacy 首选 ZL2 gl4es、缺档回退 ANGLE——由链序
#  1.17+ 与 ≤1.16 两行 + 决策留痕日志承载）。
check("L5 auto legacy branch -> ZL2 classic gl4es (Task217 重锚：候选链函数形态)",
      "? @[@ RENDERER_NAME_MOBILEGL, @ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE]" in jl
      and ": @[@ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE, @ RENDERER_NAME_MOBILEGL]" in jl
      and "legacy MC baseline (Task173/212: ZL2 classic gl4es)" in jl)
check("L6 gl4es-missing ANGLE fallback retained (Task217 重锚：可用性兜底措辞)",
      "all candidates unavailable/blacklisted -- availability fallback to chain head" in jl)

print("== M. docs ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("M1 version.h addendum", "Task 173" in vh and "desktop-GL completion layer" in vh)
ann = json.load(open(os.path.join(REPO, "announcements.json")))
check("M2 announcement present", any(a["id"] == "task173-ten-fixes-2026-09-26" for a in ann["announcements"]))
# Task179 重锚：task179@2 插入，全体非钉位再顺延 +1；task178 自 anns[6] -> anns[7]。
# Task207 重锚：task207@2 插入，全体非钉位再顺延 +1（184/190/193/196/201/206/207 累计）。
check("M3 announcement at index 11 (Task212 重锚：task212@2 插入后 ten-fixes@16、toggle-173@15、174@14、175@13、177@12、178@11、179@10、180@9、184@8)",
      ann["announcements"][21]["id"] == "task173-ten-fixes-2026-09-26"  # Task184+190+193+196+201+207+212 各 +1
      and ann["announcements"][20]["id"] == "task173-neumorph-rewrite-toggle-2026-09-25"
      and ann["announcements"][19]["id"] == "task174-neumorph-canvas-opacity-label-2026-09-26"
      and ann["announcements"][18]["id"] == "task175-six-fixes-2026-09-26"
      and ann["announcements"][17]["id"] == "task177-neumorph-css-spec-2026-09-26"
      and ann["announcements"][16]["id"] == "task178-neumorph-decouple-opacity-2026-09-26"
      and ann["announcements"][15]["id"] == "task179-eight-fixes-2026-09-26"
      and ann["announcements"][14]["id"] == "task180-opacity-dual-slider-2026-09-26"
      and ann["announcements"][13]["id"] == "task184-revert-180-ui-whitespace-fix-2026-09-27")
check("M4 server pin still first", ann["announcements"][0]["id"].startswith("server-recommend"))

print("== N. no-regression: balance gates ==")
import subprocess as sp
files = ["Natives/ProfileSettingsViewController.m", "Natives/DownloadViewController.m",
         "Natives/LauncherRootViewController.m", "Natives/LauncherCardLayoutViewController.m",
         "Natives/LauncherRightPanelViewController.m", "Natives/BackgroundSettingsViewController.m",
         "Natives/JavaLauncher.m", "Natives/utils.m", "Natives/egl_bridge.m",
         "Natives/LauncherPreferences.m", "Natives/VersionManagerViewController.m",
         "Natives/ios_uikit_bridge.m", "Natives/installer/modpack/CurseForgeAPI.m",
         "Natives/installer/modpack/ModrinthAPI.m", "Natives/ModVersion.m",
         "Natives/external/gl4es/tinygl4angle.c"]
r = sp.run(["python3", "scripts/task158_objc_balance.py"] + files, cwd=REPO,
           capture_output=True, text=True)
check("N1 all touched files balanced", r.returncode == 0 and "FAIL" not in r.stdout,
      r.stdout[-200:])

print()
print(f"RESULT: {PASS} passed, {FAIL} failed")
if FAILED:
    print("FAILED:", FAILED)
    sys.exit(1)
