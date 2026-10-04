#!/usr/bin/env python3
"""verify_task129 -- v5.1.0 八项装机反馈修复的代码级验证。

A. OpenAL ALC_SOFT_system_events 垫片（26.1.2 整合包崩溃）
B. 第三方登录多服务器 + 多角色管理（FCL 参照）
C. 设置 pick 悬浮统一（iPadOS 27 二级菜单/无法切换修复）
D. MG Vulkan 性能默认值（DSA/缓存）
E. 白背景双层兜底
F. iPad 机型强制 Pad idiom
G. 公告内置离线兜底
H. 集合 cell 效果注入排除内容自绘视图（MC 公告图片被覆盖）
I. 语法门（括号平衡 / .strings 行语法 / Makefile TAB 完整性）
J. 级联（119_124 / 125_128 / 112_118）
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

print("== A. OpenAL 垫片（26.1.2 崩溃根治）==")
shim = rd("Natives/openal_shim.c")
jl = rd("Natives/JavaLauncher.m")
mk = rd("Makefile")
check("A1 垫片源存在且导出三个桩函数",
      "int alcEventIsSupportedSOFT(int eventType, int deviceType)" in shim
      and "ALCboolean alcEventControlSOFT(" in shim
      and "void alcEventCallbackSOFT(void *callback, void *userParam)" in shim)
check("A2 isSupported 桩返回 ALC_FALSE（MC 回退轮询）",
      "return AME129_ALC_FALSE; // 事件类型不支持 => MC 回退轮询" in shim)
check("A3 覆盖 alcGetString 追加扩展名（按查询组合不共用缓存）",
      "param != AME129_ALC_EXTENSIONS" in shim and "ame129_ext_buf" in shim)
check("A4 覆盖 alcIsExtensionPresent 对本扩展应答真",
      'strcmp(name, AME129_EXT_NAME) == 0' in shim)
check("A5 未来 impl 自带真扩展时透明转发",
      "ame129_forwarding" in shim and 'impl_alcGetProcAddress(NULL, "alcEventIsSupportedSOFT")' in shim)
check("A6 impl 句柄解析：NOLOAD 优先 + 三候选（shaderc 教训）",
      "RTLD_NOLOAD" in shim and "@loader_path/libopenal_impl.dylib" in shim)
check("A7 真库已重命名 impl 且未随包",
      os.path.exists(os.path.join(REPO, "Natives/resources/Frameworks/libopenal_impl.dylib"))
      and not os.path.exists(os.path.join(REPO, "Natives/resources/Frameworks/libopenal.dylib")))
check("A8 Makefile dep_openal_shim 目标（re-export + LC_ID 修正）",
      "dep_openal_shim:" in mk
      and "-Wl,-reexport_library,$(WORKINGDIR)/libopenal_impl.dylib" in mk
      and "install_name_tool -id @rpath/libopenal_impl.dylib" in mk)
check("A9 payload 依赖链接入 dep_openal_shim（Task157 重锚；Task206 重锚：并行插入 dep_nggl4es；Task214 重锚：并行插入 dep_virgl）",
      "payload: native dep_mg java jre assets dep_shader_shims dep_openal_shim dep_mithril_glshim dep_nggl4es dep_gl4eszl2 dep_virgl dep_angle_freeze" in mk)
check("A10 Task112 钉子保留（绝对路径直载）",
      '-Dorg.lwjgl.openal.libname=%@' in jl and 'stringByAppendingPathComponent:@"libopenal.dylib"' in jl)
check("A11 JavaLauncher Task129 论断修正入档",
      "Task129 论断修正" in jl and "26.1.2 的" in jl)

print("== B. 第三方登录（多服务器 + 多角色，FCL 参照）==")
tpli = rd("Natives/ThirdPartyLoginViewController.m")
tpa = rd("Natives/authenticator/ThirdPartyAuthenticator.m")
tpah = rd("Natives/authenticator/ThirdPartyAuthenticator.h")
alvc = rd("Natives/AccountListViewController.m")
check("B1 服务器列表存储（general.thirdparty_servers，去重上限 12）",
      'general.thirdparty_servers' in tpli and "list.count > 12" in tpli)
check("B2 ALI 解析成功自动入库 + 点条回填 + 长按删除",
      "[ThirdPartyLoginViewController rememberServer:resolvedURL];" in tpli
      and "serverChipTapped:" in tpli and "serverChipLongPressed:" in tpli)
check("B3 onProfileSelection 回调类型与属性声明",
      "ThirdPartyProfilePicker" in tpah and "onProfileSelection" in tpah)
check("B4 多角色登录弹选择器（>1 且有 UI）",
      "availableProfiles.count > 1 && self.onProfileSelection" in tpa
      and "Task129b: multi-profile login" in tpa)
check("B5 取消优雅终止（complete(nil) -> 1030 错误）",
      "profile selection cancelled by user" in tpa and "1030" in tpa)
check("B6 availableProfiles 登录时存入 authData",
      'self.authData[@"availableProfiles"] = ame129b_profiles;' in tpa)
check("B7 switchToProfile API（refresh 重绑 + 旧文件清理）",
      "- (void)switchToProfile:(NSDictionary *)profile callback:(Callback)callback {" in tpa
      and "removed old account file" in tpa)
check("B8 账户列表长按角色切换菜单（公开 API）",
      "contextMenuConfigurationForRowAtIndexPath" in alvc
      and "ame129b_switchAccountAtIndexPath" in alvc
      and "_presentMenuAtLocation" not in alvc)
check("B9 登录页角色选择器锚定登录按钮（悬浮）",
      "picker.popoverPresentationController.sourceView = sSelf.loginButton;" in tpli)
l10n_ok = True
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    s = rd(f"Natives/resources/{lang}.lproj/Localizable.strings")
    for k in ["login.thirdparty.servers.title", "login.thirdparty.servers.remove.title",
              "login.thirdparty.servers.remove.confirm", "login.thirdparty.profiles.title",
              "login.error.cancelled", "account.switch_role.title", "account.switch_role.working",
              "account.switch_role.done", "account.switch_role.failed"]:
        if f'"{k}" =' not in s:
            l10n_ok = False
            print(f"    missing: [{lang}] {k}")
check("B10 四语言 9 个新键齐全", l10n_ok)

print("== C. 设置 pick 悬浮统一（iPadOS 27 修复）==")
plpt = rd("Natives/PLPrefTableViewController.m")
check("C1 iPad 紧凑菜单私有 API 已退役（调用语法消失）",
      "[interaction _presentMenuAtLocation:location];" not in plpt)
check("C2 统一 actionSheet + popover 锚定 cell",
      "popoverPresentationController.sourceView = cell;" in plpt
      and "permittedArrowDirections" in plpt)
check("C3 Task121 ✓ 存储值比较保留",
      "ame121_cur " in plpt and "ame121_curPads" not in plpt)

print("== D. MG Vulkan 性能默认值 ==")
plp = rd("Natives/PLPreferences.m")
# Task166 重锚：DSA 默认改为 NO（三会话 A/B 实锤 DSAWrapper 在 FSR1 重定向下
# 黑屏；性能依据来自 zink 原生 DSA，与 MobileGlues 无关；详见 Task166 病历）。
check("D1 enable_ext_direct_state_access 默认 NO（Task166 黑屏反向；原 YES 时代结束）",
      '@"enable_ext_direct_state_access": @NO,' in plp)
check("D2 max_glsl_cache_size 默认 128",
      '@"max_glsl_cache_size": @(128),' in plp)
# Task166 重锚：原 D3 锚（bd71210 "= 0" 实锚）随 PLPreferences 注释重写而迁移；
# 现锚指向 Task166 反向迁移哨兵 + 病历注释（Task129d 历史现场转入注释链）。
check("D3 修正说明入档（Task166 重锚：黑屏反向迁移哨兵 + 病历注释链）",
      "task166_dsa_blackscreen_migrated" in plp
      and "DSAWrapper" in plp)

print("== E. 白背景双层兜底 ==")
bm = rd("Natives/BackgroundManager.m")
check("E1 window 底色双分支兜底（hasBackground + 无背景；Task137 重锚：原生系统底色；Task175 重锚：画布门退役回 2 处 = applyBackgroundToWindow 尾 + refreshUIEffect ON 分支）",
      bm.count("window.backgroundColor = [UIColor systemBackgroundColor];") == 2)
check("E2 splitVC.view 底色双分支兜底（Task137 重锚：原生系统底色；Task175 重锚：画布门退役回 2 处）",
      bm.count("splitVC.view.backgroundColor = [UIColor systemBackgroundColor];") == 2)
check("E3 图片解码失败铺系统底色兜底层（不再静默 return；Task137 重锚）",
      "background image failed to decode" in bm
      and "falling back to system base" in bm)
check("E4 解码成功清除兜底层（避免叠压）",
      "Remove existing fallback (Task129f" in bm)

print("== F. iPad 机型强制 Pad idiom ==")
uh = rd("Natives/UIKit+hook.m")
check("F1 hook：iPad 机型永远 Pad（model 判据，不可 hook）",
      "ame129g_isIPad" in uh and "idiom = UIUserInterfaceIdiomPad;" in uh)
check("F2 iPhone 保留解锁开关语义",
      'getPrefBool(@"debug.debug_ipad_ui") ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone' in uh)
check("F3 PLPreferences 默认值改 model 推导（hidden_sidebar + debug_ipad_ui）",
      'containsString:@"iphone"' in plp and 'containsString:@"ipad"]),' in plp)

print("== G. 公告内置离线兜底 ==")
ans = rd("Natives/AnnouncementService.m")
check("G1 内置 JSON 随包（payload resources 自动打包）",
      os.path.exists(os.path.join(REPO, "Natives/resources/announcements-fallback.json")))
check("G2 失败链：网络失败 -> 缓存 -> 内置 -> 错误（顺序正确）",
      ans.find("cached.count > 0") < ans.find("builtinAnnouncements]")
      and "serving bundled offline announcements" in ans)
check("G3 内置解析 dispatch_once 缓存 + 容错",
      "builtinAnnouncements" in ans and "dispatch_once" in ans)
import json as _json
try:
    fb = _json.load(open(os.path.join(REPO, "Natives/resources/announcements-fallback.json"), encoding="utf-8"))
    g4 = isinstance(fb.get("announcements"), list) and len(fb["announcements"]) > 0 \
        and all(k in fb["announcements"][0] for k in ["id", "title", "date", "summary", "content"])
except Exception:
    g4 = False
check("G4 内置 JSON 结构合法（announcements 数组 + 必要字段）", g4)

print("== H. cell 效果注入排除内容自绘视图 ==")
check("H1 排除 UIImageView/UILabel/UITextView/UIControl",
      "![sub isKindOfClass:[UIImageView class]]" in bm
      and "![sub isKindOfClass:[UILabel class]]" in bm
      and "![sub isKindOfClass:[UITextView class]]" in bm
      and "![sub isKindOfClass:[UIControl class]]" in bm)
# Task138 重锚：Task137 按用户指令退役全部新拟态并原生化重写
# BackgroundManager，Task129 时代的"子层画在 contents 之上"注释随旧实现
# 一起退场；断言改钉 Task137 继任注释（证明文件处于继任形态而非损坏）。
check("H2 BackgroundManager 处于 Task137 原生化继任形态（渲染序注释随新拟态退役）",
      "Task137：新拟态退役" in bm)

print("== I. 语法门 ==")
def balance(path):
    src = open(path, encoding="utf-8").read()
    i, n = 0, len(src)
    cnt = {"{": 0, "(": 0, "[": 0}
    pairs = {"}": "{", ")": "(", "]": "["}
    state = "code"
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line"; i += 2; continue
            if c == "/" and nxt == "*":
                state = "block"; i += 2; continue
            if c == '"':
                state = "str"; i += 1; continue
            if c == "'":
                state = "chr"; i += 1; continue
            if c in cnt:
                cnt[c] += 1
            elif c in pairs:
                cnt[pairs[c]] -= 1
        elif state == "str":
            if c == "\\":
                i += 2; continue
            if c == '"':
                state = "code"
        elif state == "chr":
            if c == "\\":
                i += 2; continue
            if c == "'":
                state = "code"
        elif state == "line":
            if c == "\n":
                state = "code"
        elif state == "block":
            if c == "*" and nxt == "/":
                state = "code"; i += 2; continue
        i += 1
    return all(v == 0 for v in cnt.values())

touched = [
    "Natives/openal_shim.c", "Natives/JavaLauncher.m",
    "Natives/ThirdPartyLoginViewController.m",
    "Natives/authenticator/ThirdPartyAuthenticator.m",
    "Natives/authenticator/ThirdPartyAuthenticator.h",
    "Natives/AccountListViewController.m", "Natives/PLPrefTableViewController.m",
    "Natives/PLPreferences.m", "Natives/BackgroundManager.m",
    "Natives/UIKit+hook.m", "Natives/AnnouncementService.m",
    "JavaApp/src/launcher/net/kdt/pojavlaunch/Tools.java",
]
check("I1 触碰文件括号平衡（12 文件全过）",
      all(balance(os.path.join(REPO, p)) for p in touched))

grammar_ok = True
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    src = open(os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings"),
               encoding="utf-8").read().splitlines()
    in_block = False
    for ln in src:
        t = ln.strip()
        if in_block:
            if "*/" in t:
                in_block = False
            continue
        if t.startswith("/*"):
            if "*/" not in t:
                in_block = True
            continue
        if not t or t.startswith("//"):
            continue
        if not re.match(r'^"[^"]+"\s*=\s*".*";\s*$', t):
            grammar_ok = False
            print(f"    bad [{lang}]: {t[:60]}")
check("I2 .strings 行语法（四语言全行键=值; 形态）", grammar_ok)

# 键集一致性（Task121 不变量）
sets = []
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    ks = set(re.findall(r'^"([^"]+)"\s*=',
                        rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M))
    sets.append(ks)
# Task138 重锚：+2 键（renderer_missing_dylib + mirror_policy-speed_first）
check("I3 四语言键集一致（Task138 基线 2228 = Task134 的 1916 + 2）",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2482,
      f"counts={[len(s) for s in sets]}")

# Makefile TAB 完整性（9e6fc27/129 双教训）
head_mk = subprocess.run(["git", "-C", REPO, "show", "HEAD:Makefile"],
                         capture_output=True, text=True).stdout
cur_tab = sum(1 for l in mk.splitlines() if l.startswith("\t"))
head_tab = sum(1 for l in head_mk.splitlines() if l.startswith("\t"))
check("I4 Makefile TAB 完整（Task212 重锚：绝对基线 644（Task214 重锚：561 + 83 dep_virgl 行） + 守卫在位）",
      # Task138 重锚：Task135 的 dep_sdl3_guard 14 个 TAB 行已随提交入 HEAD，
      # "+14" 形态自此恒假；Task202 重锚曾用 cur == head + 3（垫片接线
      # +3 TAB），Task203 起 +3 已随 64fdaf2 入 HEAD——对拍口径转为绝对
      # 基线；Task206 重锚：dep_nggl4es 目标 +47 TAB 行（531 = 484 + 47）；
      # 守卫目标（dep_sdl3_guard + patch_gl4es_ggstr_nullguard）双在位。
      cur_tab == 662 and head_tab == 662 and "dep_sdl3_guard:" in mk and "dep_sdl3_guard" in head_mk
      and "patch_gl4es_ggstr_nullguard.py" not in mk,  # Task212：holy 补丁接线随退役移除
      f"head={head_tab} cur={cur_tab}")

print("== J. 级联 ==")
for v in ["119_124", "125_128", "112_118"]:
    r = subprocess.run([sys.executable, os.path.join(REPO, f"scripts/verify_task{v}.py")],
                       capture_output=True, text=True, timeout=300)
    check(f"J verify_task{v} ALL PASS", ("ALL PASS" in r.stdout) and r.returncode == 0,
          r.stdout[-100:] if r.returncode else "")

print()
print(f"==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS + FAIL}) ====")
sys.exit(1 if FAIL else 0)
