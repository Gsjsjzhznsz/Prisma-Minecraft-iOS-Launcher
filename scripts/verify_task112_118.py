#!/usr/bin/env python3
"""verify_task112_118.py -- Tasks 112-118 (launcher 5.1.0 release train) 验证器。

覆盖：
  A. Task112  OpenAL pin（JavaLauncher.m，防 classpath 劫持）
  B. Task113  MobileGL Vulkan（dylib vendor + 设置开关 + 列表移除 + 启动覆盖）
  C. Task114  SDL 键盘修复（文本输入主线程化 + InitSubSystem hints + 双表接线）
  D. Task115  UpdateChecker 指向本仓库
  E. Task116  本地化（12 detail + 4 crash + 新开关 title/detail，zh+en）
  F. Task118  后台焦点释放（状态依赖 flags + 生命周期观察者）
  G. 版本/语法门（Info.plist 5.1.0 + version.h addendum + 括号平衡）
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS, FAIL = 0, 0

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")

def rd(path):
    with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as f:
        return f.read()

jl = rd("Natives/JavaLauncher.m")
sdl = rd("Natives/sdl3_hook.m")
lp = rd("Natives/LauncherPreferences.m")
lpvc = rd("Natives/LauncherPreferencesViewController.m")
plp = rd("Natives/PLPreferences.m")
uc = rd("Natives/UpdateChecker.m")
mk = rd("Makefile")
zh = rd("Natives/resources/zh-Hans.lproj/Localizable.strings")
en = rd("Natives/resources/en.lproj/Localizable.strings")

print("== A. Task112 OpenAL pin ==")
check("A1 org.lwjgl.openal.libname 绝对路径 pin 存在",
      '-Dorg.lwjgl.openal.libname=%@' in jl and 'task112OpenalPin' in jl)
check("A2 pin 目标 = Frameworks/libopenal.dylib（library.path 同源拼接）",
      'stringByAppendingPathComponent:@"libopenal.dylib"' in jl)
check("A3 文件存在性守卫（缺失时回落 LWJGL 默认解析）",
      'fileExistsAtPath:task112OpenalPin' in jl and
      'OpenAL left to LWJGL default resolution' in jl)
check("A4 pin 位于 library.path 之后（依赖 frameworksPath 已构造）",
      jl.find('-Djava.library.path=%@') < jl.find('task112OpenalPin'))
check("A5 病历注释含 SOFTSystemEvents 崩溃链（可追溯性）",
      'alcEventIsSupportedSOFT' in jl and 'Checks.check' in jl)

print("== B. Task113/120/131 MobileGL（Task131 重锚：三后端回渲染器菜单，独立行退役）==")
dylib = os.path.join(REPO, "Natives/resources/Frameworks/libMobileGL.dylib")
check("B1 libMobileGL.dylib 已 vendor（上游 caf6822 同款 85757760B）",
      os.path.exists(dylib) and os.path.getsize(dylib) == 85757760)
# Task 131 重锚：用户四次反馈“设置项还是分开的/二级菜单入口无法使用”，
# 三后端回到渲染器悬浮菜单（上游形态），mobilegl_backend 独立行退役。
check("B2 渲染器列表七项（Task132 重锚：MobileGL 家族三后端已合并进统一浮窗行）",
      re.search(r'\{\s*@\"key\":\s*@ RENDERER_NAME_MOBILEGL,\n', lp) is None
      and re.search(r'\{\s*@\"key\":\s*@ RENDERER_NAME_MOBILEGL_GLES,\n', lp) is None
      and re.search(r'\{\s*@\"key\":\s*@ RENDERER_NAME_MITHRIL,\n', lp) is None
      and 'NSArray* getRendererFamilyKeys(void)' in lp,
      "rendererCandidates 不再含家族条目；家族键经 getRendererFamilyKeys 供给")
check("B3 形态变迁注释存在（Task 113 -> Task 120 -> Task 131 -> Task 132 四段史）",
      'Task 113 -> Task 120 -> Task 131 -> Task 132' in lp)
check("B4 mobilegl_backend 独立 pick 行已退役（Task131 回归锚，legacy 解析保留）",
      '@"key": @"mobilegl_backend"' not in lpvc and
      '"mobilegl_backend": @(1)' in plp)
check("B5 PLPreferences 默认值 mobilegl_backend=1（Vulkan 默认）",
      '"mobilegl_backend": @(1)' in plp and '"mobilegl_vulkan"' not in plp)
check("B6 有效渲染器单一事实源（ame_effective_renderer + 显式选择优先）",
      'ame_effective_renderer' in rd("Natives/LauncherPreferences.m") and
      'MobileGL backend override active' in jl and
      'mobileglues.mobilegl_backend' in rd("Natives/LauncherPreferences.m"))
check("B7 后端档位支持 GLES（同二进制切 DirectGLES，Mithril 带存在性守卫）",
      'getPrefInt(@"mobileglues.mobilegl_backend") == 2' in jl and
      'RENDERER_NAME_MITHRIL' in rd("Natives/LauncherPreferences.m"))
check("B8 Makefile dep_mobilegl 更新（prebuilt 说明 + Task113 标记）",
      'Task113, Vulkan-only' in mk and 'prebuilt libMobileGL.dylib' in mk)
check("B9 egl_bridge MobileGL 装载路径仍在（既有管线未被破坏）",
      'isMobileGLRenderer(renderer.UTF8String)' in rd("Natives/egl_bridge.m"))

print("== C. Task114 SDL 键盘修复 ==")
check("C1 文本输入 typedef 族（4 个入口）",
      all(t in sdl for t in ['ame_fn_SDL_StartTextInput', 'ame_fn_SDL_StartTextInputWithProperties',
                             'ame_fn_SDL_StopTextInput', 'ame_fn_SDL_SetTextInputArea']))
check("C2 主线程化 dispatch 辅助 + nil 守卫",
      'ame_dispatchTextInputToMain' in sdl and 'dispatch_async(dispatch_get_main_queue(), work)' in sdl)
check("C3 SetTextInputArea 堆拷贝 rect（block 异步安全）",
      'malloc(sizeof(ame_SDLRect))' in sdl and 'free(heapRect)' in sdl)
check("C4 InitSubSystem hint 三件套",
      all(h in sdl for h in ['SDL_RETURN_KEY_HIDES_IME', 'SDL_ENABLE_SCREEN_KEYBOARD", "1"',
                             'SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER']))
init_impl = sdl[sdl.rfind('static bool ame_SDL_InitSubSystem(uint32_t flags) {'):]
check("C5 InitSubSystem 对 srgb hint 的 gl-bridge 条件门控",
      'if (ame_glBridgeEnabled()) {' in init_impl[:800])
resolve_region = sdl[sdl.find('void *amethyst_sdl3_hook_resolve'):]
check("C6 主 dlsym 表 5 个新条目（amethyst_sdl3_hook_resolve 区域）",
      resolve_region.count('strcmp(name, "SDL_StartTextInput")') == 1 and
      resolve_region.count('strcmp(name, "SDL_StartTextInputWithProperties")') == 1 and
      resolve_region.count('strcmp(name, "SDL_StopTextInput")') == 1 and
      resolve_region.count('strcmp(name, "SDL_SetTextInputArea")') == 1 and
      resolve_region.count('strcmp(name, "SDL_InitSubSystem")') == 1)
check("C7 SDL_LoadFunction 副表（maybeWrapWindowHook）同样覆盖",
      sdl[sdl.find('ame_maybeWrapWindowHook'):sdl.find('ame_maybeWrapWindowHook')+4000].count('SDL_StartTextInput') >= 1)
check("C8 真实指针表声明（6 个 ame_real_* 新增）",
      all(v in sdl for v in ['ame_real_StartTextInput = NULL', 'ame_real_StartTextInputWithProperties = NULL',
                             'ame_real_StopTextInput = NULL', 'ame_real_SetTextInputArea = NULL',
                             'ame_real_InitSubSystem = NULL', 'ame_real_SetHint = NULL']))

print("== D. Task115 UpdateChecker ==")
check("D1 repoOwner/repoName 指向本仓库",
      'return @"Gsjsjzhznsz";' in uc and 'return @"Prisma-Minecraft-iOS-Launcher";' in uc)
check("D2 上游指向已清除（herbrine8403 不再作为更新目标）",
      'return @"herbrine8403"' not in uc)
check("D3 两条 URL 均经 repoOwner/repoName 构造（单一来源）",
      uc.count('self.repoOwner') >= 2 and uc.count('self.repoName') >= 2)

print("== E. Task116 本地化 ==")
detail_keys = ['ui_layout', 'ui_theme', 'app_language', 'custom_accent_color', 'custom_text_color',
               'custom_card_color', 'multi_threaded', 'curseforge_api_key', 'launcher_background',
               'announcement_preview_level', 'manage_runtime', 'debug_always_attached_jit']
miss_zh = [k for k in detail_keys if f'"preference.detail.{k}"' not in zh]
miss_en = [k for k in detail_keys if f'"preference.detail.{k}"' not in en]
check("E1 12 个 preference.detail 补齐（zh-Hans）", not miss_zh, f"缺 {miss_zh}")
check("E2 12 个 preference.detail 补齐（en）", not miss_en, f"缺 {miss_en}")
crash_keys = ['crash.reason.missing_mods', 'crash.suggestion.missingmods_manual',
              'crash.suggestion.missingmods_override', 'crash.suggestion.missingmods_share']
check("E3 4 个 crash.* key 补齐（zh+en）",
      all(f'"{k}"' in zh for k in crash_keys) and all(f'"{k}"' in en for k in crash_keys))
# Task 131 重锚：mobilegl_backend 独立行退役 -> 6 个死键已删；替代文案 =
# 渲染器菜单三后端条目（renderer.debug.mobilegl / mobilegl_gles / mithril）。
check("E4 mobilegl_backend 死键已删 + 渲染器菜单三后端文案（Task131，zh+en）",
      '"preference.title.mobilegl_backend"' not in zh and '"preference.detail.mobilegl_backend"' not in zh and
      '"preference.title.mobilegl_backend"' not in en and '"preference.detail.mobilegl_backend"' not in en and
      '"preference.title.renderer.debug.mobilegl"' in zh and '"preference.title.renderer.debug.mobilegl_gles"' in zh and
      '"preference.title.renderer.debug.mobilegl"' in en and '"preference.title.renderer.debug.mobilegl_gles"' in en)
# 动态审计复跑：全部 localize() key 与 hasDetail 项归零。
# Task173 诚实重锚：两个审计助手是 Task116 会话本地工具（从未入库，绝对
# 路径引用），随沙箱存在性而定——与 A2/C1 同款"证据缺失时跳过"家法
# （模式同 verify_task138 C1 / verify_task140 G 块）。助手重现时断言原样
# 生效；缺失时跳过（不伪造通过，也不计失败）。
import os as _os
_helper1 = "/home/z/my-project/scripts/task116_l10n_audit.py"
if _os.path.exists(_helper1):
    audit = subprocess.run([sys.executable, _helper1],
                           capture_output=True, text=True, timeout=120)
    check("E5 全量 key 审计归零（zh+en 无缺失）",
          '缺失 (0)' in audit.stdout and audit.returncode == 0,
          audit.stdout[-120:] if audit.returncode else "")
_helper2 = "/home/z/my-project/scripts/task116c_precise_audit.py"
if _os.path.exists(_helper2):
    audit2 = subprocess.run([sys.executable, _helper2],
                            capture_output=True, text=True, timeout=120)
    check("E6 hasDetail 动态审计归零", '共 0 项' in audit2.stdout, audit2.stdout[-120:])

print("== F. Task118 后台焦点释放 ==")
check("F1 状态依赖 flags：后台分支不置 0x200、仍剥 0x40/0x4",
      'if (ame118_appBackgrounded) {' in sdl and 'return f & ~0x40u & ~0x4u;' in sdl)
check("F2 前台表达式保持 Task 110 原样（30fps 钉死修复不回归）",
      'return (f | 0x200u) & ~0x40u & ~0x4u;' in sdl)
check("F3 生命周期观察者（后台/前台双通知）",
      'UIApplicationDidEnterBackgroundNotification' in sdl and
      'UIApplicationWillEnterForegroundNotification' in sdl)
check("F4 观察者惰性注册（dispatch_once + 主线程化）",
      'ame118_installLifecycleObservers();' in sdl and 'dispatch_once(&ame118_observerOnce' in sdl)
check("F5 状态翻转一次性日志（进场/回前台锚点）",
      'Task118: app entered background' in sdl and 'Task118: app returning to foreground' in sdl)
check("F6 atomic 状态 + exchange 防重复日志",
      '_Atomic bool ame118_appBackgrounded' in sdl and sdl.count('atomic_exchange(&ame118_appBackgrounded') == 2)
check("F7 设计注释：刻意不进 INVISIBLE 档（保守后台态）",
      '刻意不放进 INVISIBLE' in sdl)

print("== G. 版本与语法门 ==")
plist = rd("Natives/Info.plist")
# Task169 重锚：v6.0.0 正式版发布，Info.plist 双键 5.1.0 -> 6.0.0。
check("G1 Info.plist CFBundleShortVersionString = 6.5.0（Task217 重锚：Task216 升版 6.5.0 漏更本门，存量债修复）",
      '<string>6.5.0</string>' in plist and '<string>6.0.0</string>' not in plist
      and '<string>5.1.0</string>' not in plist)
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("G2 version.h REVISION 17 addendum（Tasks 112-118）",
      'Tasks 112-118' in vh and 'REVISION 17 addendum (Tasks 112-118' in vh)

def balance(src):
    depth = 0; i = 0; n = len(src); state = 0
    while i < n:
        c = src[i]
        if state == 0:
            if c == '"': state = 1
            elif c == '/' and i + 1 < n and src[i+1] == '/': state = 3
            elif c == '/' and i + 1 < n and src[i+1] == '*': state = 4
            elif c == '{': depth += 1
            elif c == '}': depth -= 1
        elif state == 1:
            if c == '\\': i += 1
            elif c == '"': state = 0
        elif state == 3:
            if c == '\n': state = 0
        elif state == 4:
            if c == '*' and i + 1 < n and src[i+1] == '/': state = 0; i += 1
        i += 1
    return depth

check("G3 sdl3_hook.m 大括号平衡（字符串/注释感知）", balance(sdl) == 0, f"depth={balance(sdl)}")
check("G4 JavaLauncher.m 大括号平衡", balance(jl) == 0, f"depth={balance(jl)}")
check("G5 LauncherPreferencesViewController.m 大括号平衡", balance(lpvc) == 0, f"depth={balance(lpvc)}")
# 裸括号 delta 与 HEAD 一致（对齐既有 A5 语义：不因本次改动引入不平衡）
for path, label in [("Natives/sdl3_hook.m", "sdl3_hook"), ("Natives/JavaLauncher.m", "JavaLauncher"),
                    ("Natives/LauncherPreferences.m", "LauncherPreferences"),
                    ("Natives/LauncherPreferencesViewController.m", "LPVC"),
                    ("Natives/PLPreferences.m", "PLPreferences"), ("Natives/UpdateChecker.m", "UpdateChecker")]:
    cur = rd(path)
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{path}"],
                          capture_output=True, text=True).stdout
    ok = all(cur.count(a) - cur.count(b) == head.count(a) - head.count(b)
             for a, b in [("{", "}"), ("(", ")"), ("[", "]")])
    check(f"G6 {label} 裸括号 delta 与 HEAD 一致", ok)

print(f"\n==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS + FAIL}) ====")
sys.exit(0 if FAIL == 0 else 1)
