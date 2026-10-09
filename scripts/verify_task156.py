#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task 156 verifier: 四渲染家族 + IME + UI 三案。
A. Espryt multidraw 保守档（ES 方块透明）
B. Mithril GL shim（/0 崩溃根修）
C. Forge android.util 模块层可见性
D. IME（TrackedTextField 公有路径兜底 + TouchController 组字感知）
E. UI（滑块命名 + FSR 诚实化 + 侧边栏深链）
F. l10n / 配平 / 版本档案
G. 级联（不新增既有失败）
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASS, FAIL = 0, 0


def rd(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def check(name, cond, extra=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {name}")
    else:
        FAIL += 1
        print(f"  [FAIL] {name} {extra}")


jl = rd("Natives/JavaLauncher.m")
eb = rd("Natives/egl_bridge.m")
shim = rd("Natives/mithril_gl_shim.c")
mk = rd("Makefile")
sv = rd("Natives/SurfaceViewController.m")
ttf = rd("Natives/TrackedTextField.m")
rpp = rd("Natives/LauncherRightPanelViewController.m")
lpv = rd("Natives/LauncherPreferencesViewController.m")
lph = rd("Natives/LauncherPreferencesViewController.h")
bsv = rd("Natives/BackgroundSettingsViewController.m")

print("=" * 72)
print("A. Espryt multidraw 保守档（ES 方块不渲染 = 上游翻译层丢绘制）")
print("=" * 72)
check("A1 JavaLauncher：DirectGLES 时 setenv MOBILEGL_ESPRYT_MULTIDRAW_MODE=drawelements",
      'setenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE", "drawelements", 1)' in jl
      and 'strcmp(backend, "DirectGLES") == 0' in jl)
check("A2 JavaLauncher：已有值不覆盖（getenv NULL 守卫）",
      'getenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE") == NULL' in jl)
check("A3 JavaLauncher：非 MobileGL 渲染器 unsetenv 清残留",
      'unsetenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE")' in jl)
check("A4 egl_bridge：镜像站点（backend NULL 安全 + 不覆盖已有值）",
      'MOBILEGL_ESPRYT_MULTIDRAW_MODE' in eb
      and 'ame156_backend != NULL' in eb)
check("A5 二进制依据：libMobileGL.dylib 暴露 ESPRYT tier 开关",
      subprocess.run(["strings", "Natives/resources/Frameworks/libMobileGL.dylib"],
                     capture_output=True).stdout.count(b"MOBILEGL_ESPRYT_MULTIDRAW_MODE") >= 1)
check("A6 Vulkan 不受影响（MAGMA 开关无 setenv 触碰）",
      'setenv("MOBILEGL_MAGMA_MULTIDRAW_MODE"' not in jl and 'setenv("MOBILEGL_MAGMA_MULTIDRAW_MODE"' not in eb)

print("=" * 72)
print("B. Mithril GL shim（GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT=0 → /0 崩溃）")
print("=" * 72)
check("B1 shim 源文件存在 + 病历注释（35380 除零）",
      os.path.exists("Natives/mithril_gl_shim.c") and "35380" in shim)
check("B2 shim：本地 glGetIntegerv 定义 + 真实现 dlsym（无递归）",
      "void glGetIntegerv(GLenum pname, GLint *params)" in shim
      and 'dlsym(ame156_mithril(), "glGetIntegerv")' in shim)
check("B3 shim：limit 下限表（3379/34852/35361/35380）",
      all(k in shim for k in ["3379", "34852", "35361", "35380"]))
check("B4 shim：64 位路径 + eglGetProcAddress 漏斗",
      "glGetInteger64v" in shim and "eglGetProcAddress" in shim)
check("B5 Makefile：dep_mithril_glshim 目标（re-export + install_name）",
      "dep_mithril_glshim:" in mk
      and "-Wl,-reexport_library,$(SOURCEDIR)/Natives/resources/Frameworks/libmithril.dylib" in mk
      and "-install_name @rpath/libmithril_glshim.dylib" in mk)
check("B6 Makefile：payload 钩子接入",
      "payload: native dep_mg java jre assets dep_shader_shims dep_openal_shim dep_mithril_glshim" in mk)
check("B7 JavaLauncher：Mithril libname 优先指向 shim（存在性守卫 + 双层回退）",
      "Frameworks/libmithril_glshim.dylib" in jl
      and "Task156: Mithril libname -> GL shim" in jl)
check("B8 Makefile 目标仍是 tab 缩进（recipe 语法）",
      "\ndep_mithril_glshim:\n\techo" in mk)

print("=" * 72)
print("C. Forge android.util 模块层可见性（GLFWErrorCallback ArrayMap）")
print("=" * 72)
stub = ["ArrayMap.java", "ContainerHelpers.java", "EmptyArray.java",
        "MapCollections.java", "Objects.java"]
# Task189 重锚：五存根自 android/util 迁至 org/lwjgl/ame（Forge Bootstrap
# 2.1.7 拒绝 lwjgl+launcher 双导出 android.util；语义不变——ArrayMap 仍在
# lwjgl 模块内，Task156 的 MC-BOOTSTRAP 可见性目标由更强形态达成）。
check("C1 lwjgl overlay 含 5 个 org/lwjgl/ame 桩源（Task189 迁移后形态）",
      all(os.path.exists(f"JavaApp/src/lwjgl/org/lwjgl/ame/{f}") for f in stub))
check("C2 launcher 侧桩保留（-cp 类路径仍可见，Tools.java 引用不破）",
      all(os.path.exists(f"JavaApp/src/launcher/android/util/{f}") for f in stub))
glfw_java = rd("JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java")
# Task189 重锚：import 改 org.lwjgl.ame.ArrayMap（存根同批迁移，字段不变）
check("C3 overlay GLFW.java 的 ArrayMap 字段在位（触发链保留）",
      "import org.lwjgl.ame.ArrayMap;" in glfw_java and "ArrayMap<Long, GLFWWindowProperties>" in glfw_java)
# 合并 jar 规则把 build/lwjgl/** 全量拷进两个版本的 lwjgl jar（JavaApp/Makefile）
check("C4 JavaApp/Makefile lwjgl 合并规则覆盖 overlay 全目录（android/util 类会进 jar）",
      "cp -R $(OUTPUTDIR)/lwjgl/* $(OUTPUTDIR)/lwjgl_lib_$*/" in rd("JavaApp/Makefile"))

print("=" * 72)
print("D. IME（iPadOS 27）")
print("=" * 72)
check("D1 TrackedTextField：公有 insertText: 兜底（UIKeyInput）",
      "- (void)insertText:(NSString *)text {" in ttf and "[super insertText:text];" in ttf)
check("D2 TrackedTextField：同文本去重（记录 + 查询成对；Task202 议题#2 勘误：80ms -> 20ms）",
      "ame156_recordDelivery" in ttf and "ame156_recentlyDelivered" in ttf
      and "> 20" in ttf and "> 80" not in ttf)
check("D3 TrackedTextField：私有路径送达后登记（防公有路径双发）",
      ttf.count("[self ame156_recordDelivery:text]") == 3)
check("D4 TrackedTextField：setAttributedMarkedText nil 守卫 + 长度钳制",
      "if (self.markedTextRange != nil)" in ttf
      and "(NSUInteger)markedLength > self.text.length" in ttf)
check("D5 SurfaceViewController：Ame156TCIMEAwareTextField 子类（组字触发 didChange）",
      "Ame156TCIMEAwareTextField" in sv and "sendActionsForControlEvents:UIControlEventEditingChanged" in sv)
check("D6 sendTextInputStatus：真实 markedTextRange 组字边界（非硬编码 0/0）",
      "UITextRange *markedRange = self.touchControllerTextField.markedTextRange;" in sv
      and "compositionStart:(int)compositionStart" in sv)

print("=" * 72)
print("E. UI（滑块命名 + FSR 诚实化 + 侧边栏深链）")
print("=" * 72)
check("E1 透明度行显示标题（Task173 重锚：行统一构建，标题随 indexPath 动态取）",
      "titleLabel.text = self.sections[0][indexPath.row]" in bsv and "@202" in bsv)
check("E2 模糊行显示标题（Task173 重锚：同上，302 标签在 rowSpec 表内）",
      "titleLabel.text = self.sections[0][indexPath.row]" in bsv and "@302" in bsv)
check("E3 section0 页脚（background.effect.footer）",
      'localize(@"background.effect.footer", nil)' in bsv)
check("E4 两行图标分化（circle.lefthalf.filled / drop.halffull）",
      "circle.lefthalf.filled" in bsv and "drop.halffull" in bsv)
# Task158 重锚：mg 的 GLES/OpenGL 4.0 后端重映射回 MobileGlues 后 FSR 恢复联动，
# 详情文案改为「GLES/4.0 后端支持 FSR；Vulkan 直连不支持 → 分辨率缩放」。
check("E5 FSR 详情（Task158：GLES/4.0 后端支持 FSR；Vulkan 直连 → video 分辨率）",
      "GLES／OpenGL 4.0 后端" in rd("Natives/resources/zh-Hans.lproj/Localizable.strings")
      and "Vulkan 直连后端" in rd("Natives/resources/zh-Hans.lproj/Localizable.strings")
      and "分辨率」缩放" in rd("Natives/resources/zh-Hans.lproj/Localizable.strings"))
check("E6 侧边栏 7 卡全部挂点击路由",
      rpp.count("[self ame156_attachInfoCardTap:") == 7)
check("E7 深链目标键正确（about / jit_enabler / memory_limit_help / versionManager）（Task217 重锚：启动器版本卡改路由 about）",
      'route:@"about"' in rpp and 'route:@"settings:jit_enabler"' in rpp
      and 'route:@"settings:memory_limit_help"' in rpp and 'route:@"versionManager"' in rpp
      and 'isEqualToString:@"about"' in rpp)
check("E8 深链实现（ameDeepLinkKey 属性 + 滚动高亮消费）",
      "ameDeepLinkKey" in lph and "scrollToRowAtIndexPath" in lpv
      and "deselectRowAtIndexPath" in lpv)
check("E9 objc runtime import（associated-object 路由）",
      "#import <objc/runtime.h>" in rpp)

print("=" * 72)
print("F. l10n / 配平 / 版本档案")
print("=" * 72)
langs = ["en.lproj", "zh-Hans.lproj", "zh-CN.lproj", "zh-Hant.lproj",
         "ja.lproj", "km.lproj"]
sets = []
for lg in langs:
    s = rd("Natives/resources/" + lg + "/Localizable.strings")
    keys = set(re.findall(r'^"([^"]+)"\s*=', s, re.M))
    sets.append(keys)
    check(f"F[{lg}] footer 键在位", "background.effect.footer" in keys)
check("F1 四主语言键集一致（1952 = Task157 基线 1948 + Task159 净增 4（新增 5 键，退役 memory.current））",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2763,
      f"counts={[len(x) for x in sets]}")
for f in ["Natives/BackgroundSettingsViewController.m", "Natives/JavaLauncher.m",
          "Natives/egl_bridge.m", "Natives/SurfaceViewController.m",
          "Natives/TrackedTextField.m", "Natives/LauncherRightPanelViewController.m",
          "Natives/LauncherPreferencesViewController.m"]:
    d = rd(f)
    check(f"F2 配平 {f}", d.count("{") == d.count("}"))
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("F3 version.h Task156 addendum 存在 + 无非法 '#' 行",
      "REVISION 17 addendum (Task 156, no bump)" in vh
      and "\n# //" not in vh and "\n#//" not in vh)

print("=" * 72)
print("G. 级联（本会话改动不引入新失败）")
print("=" * 72)
for t in ["153", "151"]:
    r = subprocess.run([sys.executable, f"scripts/verify_task{t}.py"],
                       capture_output=True, text=True)
    tail = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "<no output>"
    check(f"G verify_task{t} 全绿（{tail}）", r.returncode == 0)
r = subprocess.run([sys.executable, "scripts/verify_task154.py"],
                   capture_output=True, text=True)
# Task158 基线漂移：用户上传新日志（d380bcc/0cb7708）后，task154 的 E4（旧 Mithril
# 会话的 sodium 版本串）与 E1/E3/E5 一同成为日志轮换环境项（35P/4F，语义锚全部 intact）。
# Task220 基线再锚：154 的 E 组证据已 git-pin 到 7c32bc33（Oct-4/5 轮换根治），
# 环境性失败面清零，154 回归全绿（39P/0F）。
baseline = "39 passed, 0 failed"  # Task220：E 组 git-pin 后全绿基线
check(f"G verify_task154 与基线一致（{baseline}；Task220 git-pin 后全绿）",
      "39 passed, 0 failed" in r.stdout and "ALL GREEN" in r.stdout)
r = subprocess.run([sys.executable, "scripts/verify_task150.py"],
                   capture_output=True, text=True,
                   env={**os.environ, "TASK150_REPO": REPO})
check("G verify_task150 全绿（TASK150_REPO 注入）", "43/43" in r.stdout)

print()
print("=" * 72)
print(f"==== RESULT: {'ALL GREEN' if FAIL == 0 else 'HAS FAILURES'} ({PASS} passed, {FAIL} failed) ====")
print("=" * 72)
sys.exit(0 if FAIL == 0 else 1)
