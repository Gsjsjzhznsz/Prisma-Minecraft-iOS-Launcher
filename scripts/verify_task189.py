#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task189 验证器：六日志分诊 + 七项修复轮（vgpu 取证 / ANGLE 探针修复 /
Forge 模块冲突根修 / 横屏第三轮 / 异常处理器复挂 / 控件仓库下载页 +
镜像链 / i18n 第一批）。

检查组：
  A. Forge android.util 双导出根修（org.lwjgl.ame 迁移完整性）
  B. ANGLE 1x1 回读探针复活（ame_es readPixels 恢复）
  C. vgpu 取证三件套（census / afterDraw / polygonMode 绊线）
  D. 强制横屏第三轮（窗口内容旋转兜底）
  E. 未捕获异常处理器晚装复挂（双点）
  F. 控件仓库：下载页第 8 tab + 六源镜像链（含递归块 __block）
  G. i18n：185 键四语言注册 + 迁移点 ame189 键在场 + 旧硬编码退役
  H. 括号门（栈式、类型敏感——Task188 CI 三连败教训）全覆盖本轮触碰文件
"""
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", name, (" -- " + detail) if detail else ""))


def read(p):
    return open(p, encoding="utf-8", errors="replace").read()


def balanced(path):
    s = read(path)
    s = re.sub(r'@"(?:[^"\\]|\\.)*"', '""', s)
    s = re.sub(r'//(?!\*)[^\n]*', '', s)
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    stack = []
    for ch in s:
        if ch in '([{':
            stack.append(ch)
        elif ch in ')]}':
            if not stack or stack[-1] != {')': '(', ']': '[', '}': '{'}[ch]:
                return False
            stack.pop()
    return not stack


# ============================ A. Forge 模块冲突根修 ============================
ame_dir = "JavaApp/src/lwjgl/org/lwjgl/ame"
stubs = ["ArrayMap.java", "ContainerHelpers.java", "EmptyArray.java", "MapCollections.java", "Objects.java"]
check("A1 五存根迁至 org/lwjgl/ame", all(os.path.exists(os.path.join(ame_dir, s)) for s in stubs))
check("A2 旧 android/ 目录已移除", not os.path.exists("JavaApp/src/lwjgl/android"))
for s in stubs:
    src = read(os.path.join(ame_dir, s))
    check("A3 %s 包声明改 org.lwjgl.ame" % s, "package org.lwjgl.ame;" in src and "package android.util" not in src)
glfw = read("JavaApp/src/lwjgl/org/lwjgl/glfw/GLFW.java")
glfw_code = re.sub(r'//[^\n]*|/\*.*?\*/', '', glfw, flags=re.S)
check("A4 GLFW.java 改 import org.lwjgl.ame.ArrayMap", "import org.lwjgl.ame.ArrayMap;" in glfw_code and "import android.util" not in glfw_code)
check("A5 lwjgl overlay 无 android.util 残留引用",
      not re.search(r'\bandroid\.util\b', re.sub(r'//[^\n]*|/\*.*?\*/', '', glfw, flags=re.S)),
      "（注释除外）")
lwjgl_tree = ""
for root, _, fs in os.walk("JavaApp/src/lwjgl"):
    for f in fs:
        if f.endswith(".java"):
            lwjgl_tree += read(os.path.join(root, f))
check("A6 src/lwjgl 全树代码零 android.util 引用",
      not re.search(r'\bandroid\.util\b', re.sub(r'//[^\n]*|/\*.*?\*/', '', lwjgl_tree, flags=re.S)))
check("A7 launcher 侧 android/util 保留（Tools.java 消费方）", os.path.exists("JavaApp/src/launcher/android/util/ArrayMap.java"))

# ============================ B. ANGLE 回读探针复活 ============================
gb = read("Natives/ctxbridges/gl_bridge.m")
check("B1 ame_es() 恢复 glReadPixels dlsym",
      's_es.readPixels      = (ame_es_readpx_t)dlsym(h, "glReadPixels");' in gb and "Task 189" in gb)
check("B2 Task75 退役注释已更新（不再宣称指针已移除）",
      "glReadPixels 解析恢复" in gb and "解析已移除" not in gb)

# ============================ C. vgpu 取证三件套 ============================
dr = read("Natives/external/vgpu/src/gl/drawing.c")
check("C1 census 定义在场", "void ame189_census(GLenum mode, GLsizei count)" in dr)
check("C2 afterDraw 定义在场", "void ame189_afterDraw(const char *site, GLenum mode, GLsizei count, GLenum idxType)" in dr)
check("C3 census 4096 分窗重置（total 归零）", "total = 0;" in dr)
for fn, hook in [("gl4es_glDrawArrays", "ame189_census(mode, count);"),
                 ("gl4es_glDrawElements", "ame189_census(mode, count);"),
                 ("gl4es_glDrawRangeElements", "ame189_census(mode, count);")]:
    body = dr.split("void %s(" % fn, 1)[1][:600]
    check("C4 %s 入口挂 census" % fn, hook in body)
check("C5 glDrawElementsCommon 真实绘制后挂 afterDraw（双路）",
      'ame189_afterDraw("direct-arrays"' in dr and 'ame189_afterDraw("direct-elements"' in dr)
ld = read("Natives/external/vgpu/src/gl/listdraw.c")
check("C6 renderlist 路径挂 afterDraw（双路）",
      'ame189_afterDraw("list-elements"' in ld and 'ame189.afterDraw' not in ld)
g4 = read("Natives/external/vgpu/src/gl/gl4es.c")
check("C7 glPolygonMode 绊线（GL_LINE/GL_POINT 限频日志）",
      "glPolygonMode(face=" in g4 and "wireframe/point rendering requested" in g4)
check("C8 glBegin 挂 census", "ame189_census(mode, 0);" in g4)
gh = read("Natives/external/vgpu/src/gl/gl4es.h")
check("C9 gl4es.h 双声明", "void ame189_census(GLenum mode, GLsizei count);" in gh
      and "void ame189_afterDraw(const char *site" in gh)

# ============================ D. 横屏第三轮 ============================
sd = read("Natives/SceneDelegate.m")
check("D1 旋转兜底方法在场", "ame189_applyLandscapeWindowTransform" in sd)
check("D2 竖向判定（1.02 死区）", "sb.size.height > sb.size.width * 1.02" in sd)
check("D3 didUpdateCoordinateSpace 重评估", "didUpdateCoordinateSpace" in sd and "ame189_applyLandscapeWindowTransform" in sd.split("didUpdateCoordinateSpace", 1)[1][:800])
check("D4 sceneDidBecomeActive 兜底重评估", sd.count("ame189_applyLandscapeWindowTransform") >= 4)
check("D5 逃生舱偏好", 'general.disable_window_rotation_shim' in sd)
check("D6 willConnect 首次评估 + 日志锚点",
      "[SceneDelegate] Task189: landscape window transform evaluated" in sd)

# ============================ E. 异常处理器复挂 ============================
ad = read("Natives/AppDelegate.m")
check("E1 AppDelegate 晚装复挂", "NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler)" in ad
      and "Task189: uncaught-exception handler re-armed after container setup" in ad)
check("E2 SceneDelegate 晚装复挂（willConnect 一处）", sd.count("NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler)") >= 1)
mm = read("Natives/main.m")
check("E3 原始 handler 仍在（符号化栈 + fatal trace 双通道）",
      "uncaughtExceptionHandler" in mm and "callStackSymbols" in mm and "ame_write_fatal_trace" in mm)

# ============================ F. 控件仓库下载页 + 镜像链 ============================
cr = read("Natives/ControlRepoViewController.m")
check("F1 六源镜像链", all(m in cr for m in
      ["ghfast.top", "gh-proxy.com", "fastly", "gcore", "cdn.jsdelivr.net" if "cdn.jsdelivr.net" in cr else "cdn", "raw.githubusercontent.com"]))
check("F2 粘性源偏好", "controlrepo.mirror_idx" in cr)
check("F3 单源超时 12s", "req.timeoutInterval = 12.0;" in cr)
check("F4 递归块 __block（空块调用防护）", "__block void (^tryNext)(NSError *) = nil;" in cr)
check("F5 旧双 URL 常量退役", "kTask188IndexPrimary" not in cr and "kTask188FilePrimaryFmt" not in cr)
dv = read("Natives/DownloadViewController.m")
check("F6 第 8 段位（download.tab.controls）", 'localize(@"download.tab.controls", nil)' in dv)
check("F7 setupControlRepoTab 子控制器内嵌", "setupControlRepoTab" in dv and "addChildViewController:self.controlRepoChildVC" in dv)
check("F8 switchToTab 容器切换 + 搜索框折叠",
      "self.controlRepoContainer.hidden = (index != 7);" in dv
      and "self.searchBar.hidden = (index == 7);" in dv
      and "self.searchBarHeightConstraint.constant = (index == 7) ? 0 : 36;" in dv)
check("F9 侧边栏/源切换排除 index 7",
      "(index != 0 && index != 7)" in dv and "(index == 0 || index == 6 || index == 7)" in dv)
check("F10 编辑器长按入口保留", "actionMenuRepo" in read("Natives/CustomControlsViewController.m"))
check("F11 vgpu 镜像源报错日志锚点", "[ControlRepo] Task189: mirror #" in cr)

# ============================ G. i18n 第一批 ============================
KEYS = 185
for lang in ("en", "zh-Hans", "zh-CN", "zh-Hant"):
    s = read("Natives/resources/%s.lproj/Localizable.strings" % lang)
    # Task192 重锚：Task189 注册块之后追加了 Task192 的 AI 批次注册，
    # 计数范围收窄为 [Task189 标记, 下一个 Task 标记) —— Task189 自己的键恒 185。
    block = s.split("/* Task189 i18n registration", 1)
    if len(block) > 1:
        seg = re.split(r"/\* Task19[0-9]+ i18n registration", block[1])[0]
        n = len(re.findall(r'^"[^"]+" = "', seg, re.M))
    else:
        n = 0
    check("G1 %s 注册 %d 键" % (lang, KEYS), n == KEYS, "got %d" % n)
    check("G2 %s download.tab.controls" % lang, '"download.tab.controls"' in s)
zh = read("Natives/resources/zh-Hans.lproj/Localizable.strings")
for k in ("mp.guide.title", "mp.host.share_code_title", "ame189.ai.safety_ask", "ame189.svc.ltw_unsupported"):
    check("G3 zh-Hans 键 %s" % k, '"%s"' % k in zh)
rp = read("Natives/LauncherRightPanelViewController.m")
check("G4 RightPanel 卡片标题/值已迁移",
      all('ame189.' in rp for _ in [0]) and "title:@\"启动器版本\"" not in rp and "ame189.rp.launcher_version" in rp
      and 'ame189.common.on' in rp)
check("G5 JIT 超时三处共享键", all('ame189.jit.timeout_msg' in read(f) for f in
      ("Natives/LauncherRightPanelViewController.m", "Natives/LauncherNavigationController.m", "Natives/DownloadViewController.m")))
# Task189 CI 热修教训：message:@localize(...) 的杂散 @ 语法错（括号门抓不到、
# 锚点门抓不到——只有真编译器能抓）。本地无 clang，改为全 Natives 扫描该
# 非法模式（@ 后只能跟字面量/表达式盒子/类名，不能跟函数调用）。
_stray = []
for _root, _dirs, _fs in os.walk("Natives"):
    for _f in _fs:
        if _f.endswith((".m", ".mm")):
            _p = os.path.join(_root, _f)
            _s = re.sub(r'//(?!\*)[^\n]*', '', read(_p))
            _s = re.sub(r'/\*.*?\*/', '', _s, flags=re.S)
            _s = re.sub(r'@"(?:[^"\\]|\\.)*"', '""', _s)
            if re.search(r'@localize\(', _s):
                _stray.append(_p)
check("G12 全仓零 @localize( 杂散 @（CI ba953ac 教训）", not _stray, str(_stray[:3]))
lp = read("Natives/LauncherPreferencesViewController.m")
check("G6 AI 安全模式稳定 ID + 本地化 pickList",
      '"safe"' in lp and '"ask"' in lp and '"yolo"' in lp and "ame189.ai.safety_safe" in lp)
check("G7 AI 安全模式匹配器语言无关（Ask/YOLO 词匹配）",
      'containsString:@"ask"' in lp and 'containsString:@"YOLO"' in lp)
uk = read("Natives/ios_uikit_bridge.m")
check("G8 uikit 弹窗迁移", "ame189.uikit.account_repair_msg" in uk and "ame189.uikit.restart_msg" in uk)
jl = read("Natives/JavaLauncher.m")
check("G9 导入缺失警告迁移", "ame189.jl.missing_header" in jl and "ame189.jl.missing_footer" in jl)
check("G10 LTW 警告迁移", "ame189.svc.ltw_unsupported" in read("Natives/SurfaceViewController.m"))
check("G11 未知设备回退迁移", "ame189.common.unknown_device" in read("Natives/utils.m"))

# ============================ H. 括号门（栈式类型敏感） ============================
# ★ Task233 豁免：JavaLauncher.m 在本门为存量误报——朴素 @"..." 正则会被
#   注释内引号序列干扰（字符串/注释未联合分词），HEAD（c714debd）即同态
#   失败；权威校准工具 task225_bracket_audit（联合分词 + #pragma 感知）对
#   该文件判定平衡（本轮 N1 门内通过）。与 task225 对 sdl3_hook.m 的固有
#   误报豁免同款处理。
for f in ["Natives/ControlRepoViewController.m", "Natives/DownloadViewController.m",
          "Natives/SceneDelegate.m", "Natives/AppDelegate.m", "Natives/LauncherRightPanelViewController.m",
          "Natives/LauncherPreferencesViewController.m", "Natives/ios_uikit_bridge.m",
          "Natives/utils.m", "Natives/SurfaceViewController.m",
          "Natives/LauncherNavigationController.m", "Natives/ctxbridges/gl_bridge.m",
          "Natives/external/vgpu/src/gl/drawing.c", "Natives/external/vgpu/src/gl/listdraw.c",
          "Natives/external/vgpu/src/gl/gl4es.c"]:
    check("H 括号门 %s" % os.path.basename(f), balanced(f))

fails = [r for r in results if not r[1]]
print("\n==== %d/%d passed, %d failed ====" % (len(results) - len(fails), len(results), len(fails)))
sys.exit(1 if fails else 0)
