#!/usr/bin/env python3
"""Task154 verifier: MobileGL FSR retirement (da5918a semantics) + Mithril
double-classloader pin removal + Delegate dlsym patch + Forge ignoreList v2.

Device-log evidence base (7c32bc3 upload, all sessions on build 3b35b26):
  - latestlog.old.txt (Vulkan): "[MGLFSR] Task153 backbuffer query
    unavailable" -- libMobileGL's fake EGL (handles 0x1, no current tracking)
    makes the deferred-shrink backbuffer query fail forever; viewport stays
    2360x1640 (swap probe) while sendTouchPoint divides by mgFsrScale ->
    touch quarter-screen misalignment + FSR no-op. The user's report:
    "vulkan和es的fsr没有效果导致输入错位".
  - latestlog.txt (Mithril/4.0): "UnsatisfiedLinkError: Failed to locate
    library: liblwjgl.dylib" at NativeLibrariesBootstrap -- Task152b preloaded
    GL/Library through the SYSTEM classloader; MC's Knot-loaded Library hit
    the one-native-library-per-classloader invariant ("already loaded in
    another class loader", masked by LWJGL's catch). The pack ships sodium
    0.9.2 (POJAV_RENDERER would detonate its PostLaunchChecks next).
  - latestlog.forge (Forge): "no AmethystAccountJNI in system library path"
    at MinecraftAccount.<clinit> -- Task153's -Xbootclasspath/a move handed
    the class to the boot loader, whose loadLibrary searches only
    sun.boot.library.path.
  - Known-good baseline: 9f32cb4/1d4ff3a (9e6fc27 = 5.1.0 release build) --
    MobileGL DirectVulkan full-res direct present, no launcher-side FSR.
    libMobileGL.dylib is byte-identical since da5918a (git log: single commit).

Checks: A mg-FSR retirement / B Mithril / C Delegate patch / D Forge v2 /
E evidence anchors / F syntax & balance / G cascade (task153 re-anchored).
"""
import os, re, subprocess, sys, zipfile

REPO = os.environ.get("AME_REPO", "/home/z/my-project/Amethyst-iOS-MyRemastered")
FAILED = []
PASSED = 0

def check(name, cond, detail=""):
    global PASSED
    if cond:
        PASSED += 1
        print(f"  [PASS] {name}")
    else:
        FAILED.append(name)
        print(f"  [FAIL] {name}  {detail}")

def rd(p):
    with open(os.path.join(REPO, p), encoding="utf-8", errors="replace") as f:
        return f.read()

def balance(path):
    """Task153 同款字符扫描器（字符串/字符字面量/两种注释全跳过），括号+花括号分开计。"""
    src = rd(path)
    braces = parens = 0
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\":
                    i += 1
                i += 1
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                if src[i] == "\\":
                    i += 1
                i += 1
        elif src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        elif c in "{}":
            braces += 1 if c == "{" else -1
        elif c in "()":
            parens += 1 if c == "(" else -1
        i += 1
    return braces, parens

def git(*args):
    return subprocess.run(["git", "-C", REPO] + list(args),
                          capture_output=True, text=True).stdout

sv = rd("Natives/SurfaceViewController.m")
mf = rd("Natives/ctxbridges/mgl_fsr.mm")
jl = rd("Natives/JavaLauncher.m")
gb = rd("Natives/ctxbridges/gl_bridge.m")
tools = rd("JavaApp/src/launcher/net/kdt/pojavlaunch/Tools.java")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
eh = rd("Natives/environ.h")

print("== A. MobileGL FSR 退休（da5918a 语义） ==")
check("A1 ame83 能力表：MobileGL 除名（isMobileGLRenderer -> NO），MobileGlues/zink 保留",
      "if (isMobileGLRenderer(renderer.UTF8String)) return NO;" in sv and
      "RENDERER_NAME_MOBILEGLUES]) return YES;" in sv and
      'hasPrefix:@"libOSMesa"]) return YES;' in sv)
check("A2 退休病历注释完整（伪 EGL + 输入错位 + 毁帧三重证据链 + da5918a 基准）",
      "Task154" in sv and "伪 EGL" in sv and "左下四分之一" in sv and
      "9f32cb4/1d4ff3a" in sv)
# Task220 诚实重锚：Task166 重写退休日志时在 "pre-swap" 后插入 "GL"
#（pre-swap GL FSR chain），旧锚点形式随之退役，次序断言语义不变。
check("A3 mgl_fsr 硬门禁：入口即 return false + 一次性退休日志（次序：函数头 < 日志 < return < #if 0；Task220 重锚）",
      mf.find('extern "C" bool ame_mgl_fsr_before_swap(void) {') <
      mf.find('NSLog(@"[MGLFSR] Task154 MobileGL pre-swap GL FSR chain RETIRED') <
      mf.find("return false;\n#if 0") and
      "return false;\n#if 0" in mf)
check("A4 旧链体 #if 0 存档（Task119-153 机制保留，#endif 闭合）",
      "#if 0" in mf and "Task 154：#if 0 —— 旧链体" in mf and
      mf.count("#if 0") >= 1)
pp = subprocess.run(["python3", "-c", """
import re
data = open('%s/Natives/ctxbridges/mgl_fsr.mm', encoding='utf-8').read()
data = re.sub(r'/\\*.*?\\*/', '', data, flags=re.S)
data = re.sub(r'//[^\\n]*', '', data)
stack = []
for i, ln in enumerate(data.split('\\n'), 1):
    s = ln.strip()
    if s.startswith('#if'): stack.append(i)
    elif s.startswith('#endif'):
        if not stack: raise SystemExit('unmatched endif')
        stack.pop()
raise SystemExit(1 if stack else 0)
""" % REPO], capture_output=True, text=True)
check("A5 预处理器指令配平（#if/#endif 全嵌套闭合）", pp.returncode == 0, pp.stderr.strip())
check("A6 SurfaceVC：延迟缩窗分支移除，统一 renderW 路径 + armed 清零",
      "Task153 MobileGL deferred FSR shrink" not in sv and
      "ame153_fsr_deferred_armed = 0;" in sv and
      sv.find("windowWidth = ame153_renderW;") > sv.find("ame153_fsr_deferred_armed = 0;"))
check("A7 sendTouchPoint 输入除法保持（mgFsrScale=1 时恒等，da5918a 口径）",
      "if (mgFsrScale > 0.0f) screenScale /= mgFsrScale;" in sv)
check("A8 gl_bridge Task78 豁免：MobileGL 扩展回退（仅 MobileGlues 豁免）",
      "strcmp(ame78_renderer, RENDERER_NAME_MOBILEGLUES) == 0) ? 1 : 0;" in gb and
      "isMobileGLRenderer(ame78_renderer))) ? 1 : 0;" not in gb)
check("A9 渲染器 UI 现状零改动（用户明令保持）：单 mg 条目 + 后端键仍在",
      "RENDERER_KEY_MG" in rd("Natives/LauncherPreferences.m") and
      "renderer_backend" in rd("Natives/LauncherPreferences.m"))

print("== B. Mithril 4.0（Task152b 撤除 + POJAV_RENDERER 退役） ==")
check("B1 Tools.java：Task152b 反射钉扎整块移除",
      "MacOSXLibraryDL" not in tools and "explicitInit" not in tools and
      "Task152b:" not in tools and "Task 154: Task152b Mithril GL pinning RETIRED" in tools)
check("B2 病历注释：双类加载器原生库不变量 + 前提证伪 + Delegate 真因记录",
      "already loaded in another class loader" in tools and
      "c71dcfa" in tools and "eglGetProcAddress" in tools)
check("B3 JavaLauncher：Mithril 的 POJAV_RENDERER 导出移除（Sodium 0.9.2 雷点）",
      'setenv("POJAV_RENDERER", glLibName, 1);' not in jl and
      "Task 154（Mithril 同步退役 POJAV_RENDERER）" in jl)
check("B4 全仓库无 POJAV_RENDERER setenv 残留（unsetenv 防御保留）",
      re.search(r'(?<![n\w])setenv\("POJAV_RENDERER"', jl) is None and
      re.search(r'(?<![n\w])setenv\("POJAV_RENDERER"', rd("Natives/egl_bridge.m")) is None and
      'unsetenv("POJAV_RENDERER");' in jl)
check("B5 -Dorg.lwjgl.opengl.libname 推送保留（Task146 绝对路径，MC 侧 create() 消费）",
      'PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.opengl.libname=%s", openglLibPush.UTF8String);' in jl)

print("== C. GL$1 Delegate dlsym 补丁（lwjgl-341 lwjgl-opengl.jar） ==")
jar = os.path.join(REPO, "JavaApp/libs/lwjgl-341/lwjgl-opengl.jar")
with zipfile.ZipFile(jar, "r") as zf:
    g1 = zf.read("org/lwjgl/opengl/GL$1.class")
check("C1 补丁已应用：常量池 'eglGetProcAddress' -> 'xglGetProcAddress'（17 字节等长）",
      b"\x01\x00\x11eglGetProcAddress" not in g1 and
      b"\x01\x00\x11xglGetProcAddress" in g1)
check("C2 OSMesaGetProcAddress 查找保留（zink 路径不受影响）",
      b"OSMesaGetProcAddress" in g1)
check("C3 补丁脚本存在且幂等复跑通过",
      os.path.exists(os.path.join(REPO, "scripts/patch_lwjgl_delegate_dlsym.py")) and
      subprocess.run(["python3", os.path.join(REPO, "scripts/patch_lwjgl_delegate_dlsym.py"), jar],
                     capture_output=True, text=True).returncode == 0)
check("C4 lwjgl-333 未触碰（该构建 Delegate 无 eglGetProcAddress，上游结构）",
      b"eglGetProcAddress" not in zipfile.ZipFile(
          os.path.join(REPO, "JavaApp/libs/lwjgl-333/lwjgl-opengl.jar")).read("org/lwjgl/opengl/GL$1.class"))
check("C5 src/lwjgl overlay 无 opengl 类（jar 补丁在最终构建存活）",
      not any("opengl" in root for root, _, _ in
              __import__("os").walk(os.path.join(REPO, "JavaApp/src/lwjgl"))))

print("== D. Forge 隔离 v2（ignoreList） ==")
check("D1 bootclasspath 迁移撤销：bootAppendBuilder 消失，libs 回归 -cp（主路径+headless 双处）",
      "bootAppendBuilder" not in jl and
      jl.count('[classpathBuilder appendFormat:@"%@/%@:", librariesPath, libFile];') == 2)
check("D2 ignoreList 注入：并入 JSON 自带值 + launcher.jar + 后推生效",
      'PUSH_MARGV_FORMAT(@"-DignoreList=%@", ame154_ignore);' in jl and
      ',launcher.jar"' in jl and
      "hasPrefix:@\"-DignoreList=\"]" in jl)
check("D3 BootstrapLauncher 默认值口径（asm,securejarhandler 基线）",
      '@"asm,securejarhandler";' in jl)
check("D4 日志锚点 + ResolutionException 病历保留",
      "Task154 Forge ignoreList shield" in jl and "ResolutionException" in jl)
check("D5 MinecraftAccount loadLibrary 不再被 boot 加载器劫持（-cp 主路径）",
      'System.loadLibrary("AmethystAccountJNI");' in
      rd("JavaApp/src/launcher/net/kdt/pojavlaunch/value/MinecraftAccount.java"))

print("== E. 装机证据锚点（7c32bc3 = 3b35b26 三会话） ==")
try:
    # Task220 git-pin：vk（Vulkan 3b35b26 会话）与 mt（Mithril 会话）同样被
    # Oct-4/5 轮换出工作树，按 Task219 先例固定到 7c32bc33（与 fg 同源）。
    vk = subprocess.run(["git", "-C", REPO, "show", "7c32bc33:latestlog.old.txt"],
                        capture_output=True, text=True).stdout
    mt = subprocess.run(["git", "-C", REPO, "show", "7c32bc33:latestlog.txt"],
                        capture_output=True, text=True).stdout
    # Task220 git-pin：latestlog.forge（Forge 会话）已被 Oct-4/5 轮换出工作树，
    # 按 Task219 先例固定到 7c32bc33（完整证据集）。
    fg = subprocess.run(["git", "-C", REPO, "show", "7c32bc33:latestlog.forge"],
                        capture_output=True, text=True).stdout
    check("E1 Vulkan 会话：3b35b26 构建 + 伪 EGL 查询失败实锤",
          "Commit: 3b35b26" in vk and "backbuffer query unavailable" in vk)
    check("E2 Vulkan 会话：窗口信念恒全尺寸（viewport 2360x1640）+ 窗口全尺寸启动日志",
          "2360x1640" in vk and "0x0" in vk)
    check("E3 Mithril 会话：Task152b 双类加载器崩溃实锤（pinned 日志 + UnsatisfiedLinkError）",
          "Commit: 3b35b26" in mt and "Task152b: GL FunctionProvider pinned to Mithril" in mt and
          "Failed to locate library: liblwjgl.dylib" in mt)
    check("E4 Mithril 会话：sodium 0.9.2 在场（POJAV_RENDERER 退役的必要性）",
          "sodium: Sodium 0.9.2+mc26.2" in mt)
    check("E5 Forge 会话：bootclasspath 副作用实锤（isolation ON + AmethystAccountJNI 闪退）",
          "Task153 Forge bootclasspath isolation ON" in fg and
          "no AmethystAccountJNI in system library path" in fg)
    check("E6 用户基准：da5918a 后 MobileGL dylib 未变（回归全部来自启动器侧）",
          git("log", "--oneline", "--", "Natives/resources/Frameworks/libMobileGL.dylib").strip()
          .startswith("da5918a"))
except FileNotFoundError as e:
    check("E 证据文件缺失", False, str(e))

print("== F. 语法与配平 ==")
for f in ["Natives/SurfaceViewController.m", "Natives/ctxbridges/mgl_fsr.mm",
          "Natives/JavaLauncher.m", "Natives/ctxbridges/gl_bridge.m",
          "Natives/environ.h"]:
    b, p = balance(f)
    check(f"F 配平 {f}", b == 0 and p == 0, f"braces={b} parens={p}")
check("F version.h 无非法 '#' 前缀行", "\n# //" not in vh and "\n#//" not in vh)
check("F version.h Task154 addendum 存在", "REVISION 17 addendum (Task 154, no bump)" in vh)
check("F environ.h ame153 档案语义注释", "Task 154 已退役" in eh)

print("== G. 级联（task153 重锚后全绿） ==")
r = subprocess.run(["python3", os.path.join(REPO, "scripts/verify_task153.py")],
                   capture_output=True, text=True)
check("G1 verify_task153 重锚通过（29 项）", "ALL GREEN" in r.stdout and r.returncode == 0,
      r.stdout.strip().split("\n")[-1] if r.stdout else "")

print()
print(f"Result: {PASSED} passed, {len(FAILED)} failed")
if FAILED:
    print("FAILED:", *FAILED, sep="\n  - ")
    sys.exit(1)
print("ALL GREEN")
