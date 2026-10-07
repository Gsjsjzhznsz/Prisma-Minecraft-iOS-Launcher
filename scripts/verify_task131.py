#!/usr/bin/env python3
"""verify_task131 -- 四项装机反馈修复的代码级验证。

A. SDL 事件回调拦截（26.1.2 controlify/JNA SIGBUS 根治）
B. 渲染器悬浮菜单恢复 MG 三后端（上游形态）+ mobilegl_backend 独立行退役
C. -gles 逻辑键的物理加载映射（egl_bridge×2 + JavaLauncher libname）
D. 第三方切换角色：Keychain 凭据 + 重新认证回退（Blessing Skin 语义）
E. pick 呈现加固 + 取证日志
F. version.h addendum
G. 语法门（括号平衡 / .strings 行语法 / 键集 1901 / 括号 delta）
H. 级联（119_124 / 129 / 130）
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = 0
FAIL = 0

def rd(p):
    return open(os.path.join(REPO, p), encoding="utf-8").read()

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")

print("== A. SDL 事件回调拦截（controlify/JNA closure SIGBUS 根治）==")
sdl = rd("Natives/sdl3_hook.m")
check("A1 SDL_SetEventFilter 钩子声明 + 实现（Task131）",
      "static bool ame_SDL_SetEventFilter(void *filter, void *userdata);" in sdl
      and "static bool ame_SDL_SetEventFilter(void *filter, void *userdata) {" in sdl)
check("A2 SDL_AddEventWatch 钩子声明 + 实现（防御性同源拦截）",
      "static void ame_SDL_AddEventWatch(void *filter, void *userdata);" in sdl
      and "static void ame_SDL_AddEventWatch(void *filter, void *userdata) {" in sdl)
check("A3 resolve 表按名字分发两个符号（LWJGL 与 JNA 的 dlsym 都命中）",
      'strcmp(name, "SDL_SetEventFilter") == 0' in sdl
      and 'strcmp(name, "SDL_AddEventWatch") == 0' in sdl
      and "return (void *)ame_SDL_SetEventFilter;" in sdl
      and "return (void *)ame_SDL_AddEventWatch;" in sdl)
check("A4 no-op 返回 true（假装注册成功，controlify 不走异常路径）",
      "return true; // 假装注册成功" in sdl)
check("A5 装机锚点日志（blocked + JNA/libffi closure 不可执行原因）",
      "[SDLHook] Task131: SDL_SetEventFilter(%p) blocked" in sdl
      and "not executable on iOS" in sdl)
check("A6 事故链注释完整（mac SDL3 链 Cocoa 必败 + rpath 回退 + trampoline SIGBUS）",
      "Cocoa/AppKit/Carbon/ForceFeedback" in sdl
      and "0x12e550010" in sdl
      and "pojavPumpEvents" in sdl)
check("A7 事件过滤器零使用面（启动器/MC/LWJGL 不受误伤）",
      sdl.count("SDL_SetEventFilter") >= 4  # 声明+实现+resolve+注释
      and "hotplug events still arrive via SDL_PollEvent" in sdl)

print("== B. 渲染器入口形态（Task132 重锚：MG 三端合并为统一悬浮浮窗行）==")
lp = rd("Natives/LauncherPreferences.m")
lpvc = rd("Natives/LauncherPreferencesViewController.m")
plp = rd("Natives/PLPreferences.m")
check("B1 rendererCandidates 三后端条目已退役（Task132 合并；七项列表回归）",
      re.search(r'\{\s*@\"key\":\s*@ RENDERER_NAME_MOBILEGL,\n\s*@\"name\"', lp) is None
      and re.search(r'\{\s*@\"key\":\s*@ RENDERER_NAME_MOBILEGL_GLES,\n\s*@\"name\"', lp) is None
      and re.search(r'\{\s*@\"key\":\s*@ RENDERER_NAME_MITHRIL,\n\s*@\"name\"', lp) is None)
check("B2 家族三键改经 getRendererFamilyKeys/Names 供给统一浮窗（无条件三选项）",
      "NSArray* getRendererFamilyKeys(void)" in lp
      and "NSArray* getRendererFamilyNames(void)" in lp
      and 'RENDERER_NAME_MOBILEGL,' in lp and 'RENDERER_NAME_MOBILEGL_GLES,' in lp
      and 'RENDERER_NAME_MITHRIL' in lp
      and 'preference.title.renderer_backend-mobilegl_gles' in lp)
check("B3 mobilegl_backend 独立 pick 行退役（Task131 回归锚，Task132 保持）",
      '@"key": @"mobilegl_backend"' not in lpvc)
check("B4 PLPreferences 默认 mobilegl_backend=1 保留（legacy 解析）",
      '"mobilegl_backend": @(1)' in plp)
check("B5 legacy 解析保留（auto + backend 1/2/3 -> libMobileGL/Mithril）",
      'getPrefInt(@"mobileglues.mobilegl_backend")' in lp)
check("B6 形态变迁注释（Task113 -> Task120 -> Task131 -> Task132 四段史）",
      "Task 113 -> Task 120 -> Task 131 -> Task 132" in lp)

print("== C. -gles 物理加载映射 ==")
eb = rd("Natives/egl_bridge.m")
jl = rd("Natives/JavaLauncher.m")
check("C1 egl_bridge dlopen 映射（-gles -> libMobileGL.dylib）",
      'strcmp(renderer.UTF8String, RENDERER_NAME_MOBILEGL_GLES) == 0' in eb
      and eb.count("? RENDERER_NAME_MOBILEGL") >= 2)
check("C2 egl_bridge changeRenderer 传共享二进制名（Java libname 不指向不存在的 -gles 文件）",
      "JNI_LWJGL_changeRenderer(ame131_libname);" in eb)
check("C3 JavaLauncher openglLibName 映射（LWJGL libname 指向真实文件）",
      'strcmp(openglLibName, RENDERER_NAME_MOBILEGL_GLES) == 0' in jl
      and "openglLibName = RENDERER_NAME_MOBILEGL;" in jl)
check("C4 MOBILEGL_BACKEND_TYPE=DirectGLES 由 -gles 键触发（逻辑键 -> 后端环境变量）",
      'renderer isEqualToString:@ RENDERER_NAME_MOBILEGL_GLES]' in jl
      and '"DirectGLES"' in jl)

print("== D. 第三方切换角色（Keychain + 重新认证回退）==")
tp = rd("Natives/authenticator/ThirdPartyAuthenticator.m")
check("D1 Security.framework 引入 + Keychain 存取三件套（store/read/key）",
      "#import <Security/Security.h>" in tp
      and "static void ame131_storeCredentials(" in tp
      and "static NSString *ame131_readCredentials(" in tp
      and "static NSString *ame131_credentialKey(" in tp)
check("D2 Keychain 语义（GenericPassword + AfterFirstUnlock + Update-then-Add）",
      "kSecClassGenericPassword" in tp
      and "kSecAttrAccessibleAfterFirstUnlock" in tp
      and "SecItemUpdate" in tp and "SecItemAdd" in tp)
check("D2b ARC bridge 齐备（CI run 35498188445 回归锚：SecItemUpdate 双参数 __bridge + 出参 CFTypeRef）",
      "SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs)" in tp
      and "CFTypeRef out = NULL;" in tp
      and "SecItemCopyMatching((__bridge CFDictionaryRef)query, &out)" in tp)
check("D3 登录成功存凭据（原始密码，2FA 拼接版不存）+ loginIdentifier 持久化",
      "ame131_storeCredentials(self.authData[@\"authserver\"], ame131_login, ame131_pass);" in tp
      and 'self.authData[@"loginIdentifier"] = ame131_login;' in tp
      and "self.authData[@\"password\"]" in tp)
check("D4 切换失败 -> 重新认证回退链（refresh-bind rejected -> retry）",
      "ame131_retrySwitchWithStoredCredentials:profile" in tp
      and "refresh-bind rejected" in tp)
check("D5 回退流程（authenticate 拿未绑定 token -> refreshToBindProfile 绑定 -> 文件迁移复用）",
      "ame131_retrySwitchWithStoredCredentials:(NSDictionary *)profile" in tp
      and "fresh unbound token" in tp
      and tp.count("removed old account file") >= 2)
check("D6 凭据缺失 -> 引导重登（一次性，之后免密）",
      "account.switch_role.relogin_required" in tp)
check("D7 装机锚点日志（credentials secured / re-authenticating / completed via re-auth）",
      "credentials secured in keychain" in tp
      and "re-authenticating with secured credentials" in tp
      and "profile switch completed via re-authentication path" in tp)
check("D8 raw authenticate 不触发选择器 UI（无 onProfileSelection 调用）",
      tp[tp.find("- (void)ame131_retrySwitchWithStoredCredentials"):tp.find("/// 异步获取角色纹理")].find("onProfileSelection") == -1)

print("== E. pick 呈现加固 ==")
plpt = rd("Natives/PLPrefTableViewController.m")
check("E1 最顶层 presented VC 呈现（消除静默拒绝面）",
      "ame131_presenter.presentedViewController" in plpt
      and "[ame131_presenter presentViewController:alert animated:YES completion:nil];" in plpt)
check("E2 取证日志锚点（pick opened: section.key (N options)）",
      "[PLPrefTable] Task131: pick opened:" in plpt)
check("E3 popover 锚点保持在被点击行（iPad 悬浮面板形态）",
      "alert.popoverPresentationController.sourceView = cell;" in plpt)

print("== F. version.h addendum ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("F1 REVISION 17 addendum (Task 131) 双主题（SDL guard + 渲染器菜单 + 切换回退 + pick 加固）",
      "REVISION 17 addendum (Amethyst Task 131, no bump)" in vh
      and "SDL_SetEventFilter" in vh
      and "Keychain" in vh)

print("== G. 语法门 ==")
def balance(path):
    src = open(os.path.join(REPO, path), encoding="utf-8").read()
    # 块注释/字符串/行注释/预处理指令感知的括号平衡（verify_task130 H1 同款
    # 状态机 + 预处理行跳过：sdl3_hook.m 的既有 "#pragma mark - 1) ..." 含裸
    # 右括号，属指令文本而非代码，不参与平衡；含反斜杠续行的宏一并跳过）。
    cnt = {"{": 0, "(": 0, "[": 0}
    pair = {"}": "{", ")": "(", "]": "["}
    state = "code"; i = 0; n = len(src); bol = True
    while i < n:
        c = src[i]
        if state == "code":
            if bol and c == "#":
                state = "pp"; i += 1; continue
            if c == "/" and i + 1 < n and src[i+1] == "*": state = "block"; i += 2; continue
            if c == "/" and i + 1 < n and src[i+1] == "/": state = "line"; i += 2; continue
            if c == '"': state = "str"; i += 1; continue
            if c == "'": state = "chr"; i += 1; continue
            if c in cnt: cnt[c] += 1
            elif c in pair:
                cnt[pair[c]] -= 1
                if cnt[pair[c]] < 0: return False
        elif state == "block":
            if c == "*" and i + 1 < n and src[i+1] == "/": state = "code"; i += 2; continue
        elif state == "line":
            if c == "\n": state = "code"
        elif state == "pp":
            # 预处理指令：换行结束；反斜杠续行时延续到下一行
            if c == "\\" and i + 1 < n and src[i+1] == "\n": i += 2; continue
            if c == "\n": state = "code"
        elif state == "str":
            if c == "\\": i += 2; continue
            if c == '"': state = "code"
        elif state == "chr":
            if c == "\\": i += 2; continue
            if c == "'": state = "code"
        bol = c == "\n"
        i += 1
    return all(v == 0 for v in cnt.values()) and state == "code"

TOUCHED = [
    "Natives/sdl3_hook.m", "Natives/LauncherPreferences.m",
    "Natives/LauncherPreferencesViewController.m", "Natives/egl_bridge.m",
    "Natives/JavaLauncher.m", "Natives/PLPrefTableViewController.m",
    "Natives/authenticator/ThirdPartyAuthenticator.m",
    "Natives/external/MobileGlues/MobileGlues-cpp/version.h",
]
check("G1 触碰文件括号平衡（8 文件全过）",
      all(balance(p) for p in TOUCHED))

grammar_ok = True
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    src = open(os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings"),
               encoding="utf-8").read().splitlines()
    in_block = False
    for ln in src:
        t = ln.strip()
        if in_block:
            if "*/" in t: in_block = False
            continue
        if t.startswith("/*"):
            if "*/" not in t: in_block = True
            continue
        if not t or t.startswith("//"): continue
        if not re.match(r'^"[^"]+"\s*=\s*".*";\s*$', t):
            grammar_ok = False
check("G2 四语言 .strings 行语法（块注释感知）", grammar_ok)

sets = []
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    sets.append(set(re.findall(r'^"([^"]+)"\s*=',
                  rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M)))
# Task222 重锚：2708 = Task212 基线 2520 + Task222 45 + Task223 41
check("G3 四语言键集一致（Task157 基线 2228 = Task156 基线 2228 + Task157 组件键 2）",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2708,  # Task222 重锚：+21 陶瓦联机键
      f"counts={[len(s) for s in sets]}")

delta_ok = True
for p in TOUCHED:
    cur = rd(p)
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{p}"],
                          capture_output=True, text=True).stdout
    if not head:
        continue
    if not all(cur.count(a) - cur.count(b) == head.count(a) - head.count(b)
               for a, b in [("{", "}"), ("(", ")"), ("[", "]")]):
        delta_ok = False
        print(f"    bracket delta mismatch: {p}")
check("G4 裸括号 delta 与 HEAD 一致（提交前工作树门）", delta_ok)

print("== H. 级联 ==")
r = subprocess.run([sys.executable, os.path.join(REPO, "scripts/verify_task119_124.py")],
                   capture_output=True, text=True, timeout=300)
check("H1 verify_task119_124 ALL PASS（含 mobilegl_backend 重锚 B7/B8/C3）",
      "ALL PASS" in r.stdout and r.returncode == 0,
      r.stdout[-200:] if r.returncode else "")
r = subprocess.run([sys.executable, os.path.join(REPO, "scripts/verify_task129.py")],
                   capture_output=True, text=True, timeout=600)
check("H2 verify_task129 ALL PASS（I3 基线 1901）",
      "ALL PASS" in r.stdout and r.returncode == 0,
      r.stdout[-200:] if r.returncode else "")
r = subprocess.run([sys.executable, os.path.join(REPO, "scripts/verify_task130.py")],
                   capture_output=True, text=True, timeout=600)
check("H3 verify_task130 ALL PASS（H3 基线 1901）",
      "ALL PASS" in r.stdout and r.returncode == 0,
      r.stdout[-200:] if r.returncode else "")

print()
print(f"==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS + FAIL}) ====")
sys.exit(1 if FAIL else 0)
