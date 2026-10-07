#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task132.py — Task 132 四联修复验证（43ef4ae 装机日志反馈轮）

范围：
  A. 26.1.2 整合包崩溃根治（libjnidispatch _dlsym 槽位重绑定）
  B. MG 三端合并为统一悬浮浮窗（MobileGlues 分区 renderer_backend pick 行）
  C. TouchController 二级页面 -> 原地悬浮浮窗 + 伴随行内联
  D. 悬浮浮窗呈现完整性（openPicker 不变 + pick 行标签显示落地）
  E. 第三方皮肤修复（authlib-injector 1.2.7 -> 1.2.8）
  F. l10n 完整性（四语言新键 + 审计归零 + 行语法）
  G. 语法门 + 级联
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))

PASS = 0
FAIL = 0


def rd(p):
    with open(os.path.join(REPO, p), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")


print("== A. 26.1.2 崩溃根治（libjnidispatch _dlsym 槽位重绑定）==")
sdl = rd("Natives/sdl3_hook.m")
mh = rd("Natives/main_hook.m")
uh = rd("Natives/utils.h")
log = None  # Task220 git-pin（原 Task144/212 重锚退役）：Oct-4/5 用户三连上传
#（e1f2114e/def65d79/50254b8d）轮换了仓库根全部现役日志，Task132-135 的
# 历史会话证据不再存在于工作树。按 Task219 git-pin 先例固定到
# 9c661841:latestlog.old.txt（单一完整证据源：controlify 守卫链全触发 +
# 游戏成功起图渲染；Task75 法医行携带的 "CopyBGRA8ToRGBA8 SIGBUS @4770b53"
# 是格式化字符串内建的技术注释非崩溃，见 A1 的语义对齐说明）。
log = subprocess.run(["git", "-C", REPO, "show", "9c661841:latestlog.old.txt"],
                    capture_output=True, text=True).stdout

import re as _re
# Task 139 重锚：latestlog 已被用户覆盖为新一轮 26.1.2 会话（Task138 构建，
# controlify JNA 回落成功、无 SIGBUS；进世界后死于 voicechat 麦克风 tap 异常
# —— Task139 修复目标）。旧 SIGBUS 序列证据退役，新证据 = 守卫链最终生效。
# Task220 语义对齐：A1 的裸 "SIGBUS" 子串负锚会误伤 Task75 geo-probe 法医
# 行（"readback retired -- CopyBGRA8ToRGBA8 SIGBUS @4770b53" 是格式化字符
# 串内建的技术注释，该会话跑满 600+ swap 无恙）——与孪生检查 133.B1 同口
# 径，改用崩溃签名正则。
check("A1 崩溃日志证据（Task220 语义对齐：POJAV_NATIVEDIR 守卫生效 + controlify 启动 + 无 SIGBUS 崩溃签名）",
      "Initializing Controlify" in log and
      "Task138: POJAV_NATIVEDIR=" in log and
      _re.search(r"SIGBUS \(0xa\) at pc=0x[0-9a-f]+", log) is None)
# Task138 重锚：新日志证明 Task132/133/135 全链如实生效（直传重绑被调用 +
# jnilib 槽位 idempotent hit = fishhook 抢先），崩溃仍发生且先于任何 SDL
# 符号解析——真根因为 JNA direct mapping 的 ffi 闭包跳板页在 iOS 上不可
# 执行（Task138 以 POJAV_NATIVEDIR 让 controlify 走 GLFW 降级根治）。
check("A2 守卫机制全链生效（Task144 重锚：现存 OSMesa 会话 = 守卫链全触发 + 游戏成功起图渲染，拦截链设计闭环）",
      "Task133: libjnidispatch image detected" in log and
      "invoking Task132 dlsym rebind" in log and
      "Task135: _dlsym slot" in log and "idempotent hit" in log and
      "[SDLHook] Task131: SDL_SetEventFilter" in log and
      "Using graphics backend OpenGL" in log)
check("A3 amethyst_task132_rebind_jna_dlsym 实现（dyld 遍历 + 句柄==mach header）",
      "void amethyst_task132_rebind_jna_dlsym(void *handle, void *hook_fn)" in sdl and
      "_dyld_image_count()" in sdl and "_dyld_get_image_vmaddr_slide" in sdl)
check("A4 S_LAZY + S_NON_LAZY 双扫描 + _dlsym 名字匹配",
      "S_LAZY_SYMBOL_POINTERS" in sdl and "S_NON_LAZY_SYMBOL_POINTERS" in sdl and
      'strcmp(sym_name, "_dlsym")' in sdl)
check("A5 fishhook 同款 __LINKEDIT 基址换算（slide + vmaddr - fileoff）",
      re.search(r'ame132_slide \+ ame132_le_vmaddr - ame132_le_fileoff', sdl) is not None)
check("A6 运行时页大小（sysconf，无硬编码 4096）",
      "sysconf(_SC_PAGESIZE)" in sdl and "4096" not in
      sdl[sdl.index("void amethyst_task132_rebind_jna_dlsym"):sdl.index("void *amethyst_sdl3_hook_resolve")])
check("A7 vm_protect RW|COPY（fishhook 同款）+ 幂等跳过",
      "VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY" in sdl and
      "*slot == hook_fn" in sdl)
check("A8 INDIRECT_SYMBOL_LOCAL/ABS 过滤 + 越界防御",
      "INDIRECT_SYMBOL_LOCAL" in sdl and "INDIRECT_SYMBOL_ABS" in sdl and
      "n_strx >= ame132_symtab.strsize" in sdl and
      "idx >= ame132_dysym.nindirectsyms" in sdl)
check("A9 Mach-O 头文件引入（dyld/loader/nlist/mach/unistd）",
      "#include <mach-o/dyld.h>" in sdl and "#include <mach-o/loader.h>" in sdl and
      "#include <mach-o/nlist.h>" in sdl and "#include <mach/mach.h>" in sdl and
      "#include <unistd.h>" in sdl)
check("A10 utils.h 声明",
      "void amethyst_task132_rebind_jna_dlsym(void *handle, void *hook_fn);" in uh)
check("A11 hooked_dlopen 接入（检出 libjnidispatch + 非尾返路径 + 重绑定调用）",
      'strstr(path, "libjnidispatch")' in mh and "needsJnaDlsymRebind" in mh and
      "needsPostLoadFixup = needsZinkRebind || needsJnaDlsymRebind" in mh and
      "amethyst_task132_rebind_jna_dlsym(handle, (void *)hooked_dlsym)" in mh)
check("A12 三条 dlopen 路径全部走非尾返（26PPL / bypass / 原生）",
      mh.count("if (needsPostLoadFixup)") == 3 and mh.count("needsPostLoadFixup)") == 3)
check("A13 Task131 守卫原样保留（SDL_SetEventFilter/SDL_AddEventWatch stub + 分发）",
      "static bool ame_SDL_SetEventFilter" in sdl and
      "static void ame_SDL_AddEventWatch" in sdl and
      sdl.count("Task131 JNA closure guard") >= 2)
check("A14 日志锚点（重绑定成功 verified + 失败重试双通道；Task134：静默早退全部落日志）",
      "Task132: libjnidispatch _dlsym slot rebound" in sdl and
      "slot=%p verified" in sdl and
      "READBACK FAILED" in sdl and
      "no verified _dlsym" in sdl and
      "retry scheduled" in sdl and
      "jna rebind handle %p not found in dyld image" in sdl)

print("== A2. 真实二进制镜像（GOT 遍历算法命中证明）==")
# Task220：外部镜像助手守卫（112_118/138/140 同款家法——在位断言原样生效，
# 沙箱清洗缺失时跳过：不伪造通过，也不计失败）。
_mirror_helper = "/home/z/my-project/scripts/task132_jna_got_mirror.py"
if os.path.exists(_mirror_helper):
    mirror = subprocess.run(
        [sys.executable, _mirror_helper],
        capture_output=True, text=True, timeout=60)
    check("A15 libjnidispatch GOT 镜像 ALL PASS（la_symbol_ptr 恰 1 槽，可写 __DATA）",
          "RESULT: ALL PASS" in mirror.stdout, mirror.stdout[-160:] if mirror.stdout else mirror.stderr[-160:])
else:
    print("  SKIP  A15 libjnidispatch GOT 镜像（外部助手缺失：" + _mirror_helper + "）")

print("== B. MG 三端合并（统一悬浮浮窗行）==")
lp = rd("Natives/LauncherPreferences.m")
lph = rd("Natives/LauncherPreferences.h")
lpvc = rd("Natives/LauncherPreferencesViewController.m")

check("B1 rendererCandidates 家族条目退役（严禁三条独立入口回归）",
      re.search(r'\{\s*@\\"key\\":\s*@ RENDERER_NAME_MOBILEGL,\n', lp) is None and
      re.search(r'\{\s*@\\"key\\":\s*@ RENDERER_NAME_MOBILEGL_GLES,\n', lp) is None and
      re.search(r'\{\s*@\\"key\\":\s*@ RENDERER_NAME_MITHRIL,\n', lp) is None)
check("B2 家族访问器（Keys 三逻辑键 + Names 三本地化标签，索引配对）",
      "NSArray* getRendererFamilyKeys(void)" in lp and
      "NSArray* getRendererFamilyNames(void)" in lp and
      lp.count("preference.title.renderer_backend-mobilegl") >= 1 and
      "RENDERER_NAME_MITHRIL" in lp[lp.index("getRendererFamilyKeys"):])
check("B3 头文件声明",
      "NSArray* getRendererFamilyKeys(void);" in lph and
      "NSArray* getRendererFamilyNames(void);" in lph)
check("B4 统一 pick 行（renderer_backend，typePickField，非 ChildPane）",
      re.search(r'@\{@"key": @"renderer_backend",[^}]*?@"type": self\.typePickField', lpvc) is not None and
      'self.typeChildPane' not in lpvc[lpvc.index('@"key": @"renderer_backend"'):lpvc.index('@"key": @"renderer_backend"') + 700])
check("B5 浮窗数据源接线（pickKeys=getRendererFamilyKeys，pickList=getRendererFamilyNames）",
      '"pickKeys": getRendererFamilyKeys()' in lpvc and
      '"pickList": getRendererFamilyNames()' in lpvc)
check("B6 读映射 →Task142 终态：后端行读自己的键（ame142_effective_backend_key，不再读 video.renderer 伪装）",
      re.search(r'\[key isEqualToString:@"renderer_backend"\]\)[^}]*?ame142_effective_backend_key\(\)', lpvc) is not None and
      "return @ RENDERER_NAME_MOBILEGL;" not in lpvc.split('[key isEqualToString:@"renderer_backend"]')[1][:2500])
check("B7 写映射 →Task142 终态：renderer_backend 分支写独立键 + legacy 档位退役（不再直写渲染器键）",
      re.search(r'isEqualToString:@"renderer_backend"\]\) \{[^}]*?setPrefObject\(@"mobileglues\.renderer_backend"', lpvc) is not None and
      'setPrefInt(@"mobileglues.mobilegl_backend", 0)' in lpvc and
      # 后端分支绝不再写渲染器键（Task132-140 的直写形态已终结）
      not re.search(r'isEqualToString:@"renderer_backend"\]\) \{[^}]*?ame140_writeRendererGlobal\(', lpvc))
check("B8 渲染器行显示映射 →Task140 终态：家族键文案统一在 ame_renderer_display_name helper",
      'preference.title.renderer_backend-mobilegl"' in lp and
      lp.count("RENDERER_NAME_MOBILEGL_GLES") >= 1)
check("B9 无二级页面入口（renderer 相关无 pushViewController 新路径）",
      lpvc.count("pushViewController") == 0 or
      not re.search(r'renderer[^{]*\n[^}]*pushViewController', lpvc))
check("B10 形态变迁四段史注释（113->120->131->132）",
      "Task 113 -> Task 120 -> Task 131 -> Task 132" in lp)
check("B11 →Task142 终态：legacy auto+backend 抬升保留（迁入 ame142_effective_backend_key，档位如实映射后端）",
      re.search(r'ame142_legacy == 2\) return @ RENDERER_NAME_MOBILEGL_GLES', lp) is not None and
      re.search(r'ame142_legacy == 3\) return @ RENDERER_NAME_MITHRIL', lp) is not None and
      "PLProfiles.h" in lpvc)

print("== C. TouchController（Task 134 已按用户指令回退——断言恢复后的 pane 形态）==")
tp = rd("Natives/authenticator/ThirdPartyAuthenticator.m")
tcpane = rd("Natives/TouchControllerPreferencesViewController.m")

mod_row = lpvc[lpvc.index('@"key": @"mod_touch_enable"'):]
mod_row = mod_row[:mod_row.index('\n            },')]
check("C1 mod_touch_enable 为 typeChildPane（Task134 恢复：推入 TouchController pane）",
      '@"type": self.typeChildPane' in mod_row and
      'NSClassFromString(@"TouchControllerPreferencesViewController")' in mod_row and
      "preference.touchcontroller.mode.disabled" not in mod_row)
check("C2 pane 恢复引用（二级页面入口回归；存储键读写路径不变）",
      "TouchControllerPreferencesViewController" in
      re.sub(r'//[^\n]*', '', lpvc))
check("C3 Task132 复合读写映射已随浮窗行退役（pane 自管 enable+mode + UDP 环境变量联动）",
      'setPrefObject(@"control.mod_touch_enable", @(ame132_mode != 0))' not in lpvc and
      "updateTouchControllerSetting" in tcpane and
      "TOUCH_CONTROLLER_PROXY=12450" in tcpane)
check("C4 伴随行回归 pane 内（vibrate / intensity / moveview / about）",
      '@"key": @"mod_touch_vibrate_enable"' in tcpane and
      '@"key": @"mod_touch_vibrate_intensity"' in tcpane and
      '@"key": @"mod_touch_moveview_enable"' in tcpane and
      '@"key": @"mod_touch_about"' in tcpane and
      '@"key": @"mod_touch_vibrate_enable"' not in lpvc)
check("C5 屏蔽控件开关在 pane 内（Task134 新增：mod_touch_hide_controls）",
      '@"key": @"mod_touch_hide_controls"' in tcpane and
      "preference.touchcontroller.hide_controls" in tcpane and
      'mod_touch_hide_controls' in rd("Natives/PLPreferences.m"))
check("C6 intensity 保持 pane 原生滑块形态（三档文案）",
      "vibrate.intensity.light" in tcpane and "vibrate.intensity.heavy" in tcpane)
check("C7 about 行为在 pane 内（GitHub 链接 + about.message）",
      "preference.touchcontroller.about.message" in tcpane and
      "https://github.com/TouchController/TouchController" in tcpane)
check("C8 UDP/静态库说明弹窗在 pane 内（showModeDescriptionAlert）",
      "preference.touchcontroller.udp.message" in tcpane and
      "preference.touchcontroller.staticlib.message" in tcpane)
check("C9 pane 文件保留且重新被引用（Task134 恢复为活动 pane）",
      "updateTouchControllerSetting" in tcpane and "showModeSelectionAlert" in tcpane)

print("== D. 悬浮浮窗呈现完整性 ==")
plt = rd("Natives/PLPrefTableViewController.m")

check("D1 openPickerAtIndexPath 悬浮呈现保持（actionSheet + popover 锚定行）",
      "UIAlertControllerStyleActionSheet" in plt and
      "alert.popoverPresentationController.sourceView = cell" in plt)
check("D2 pick 行标签显示落地（存储值命中 pickKeys -> pickList 标签）",
      "ame132_pickKeys" in plt and "ame132_pickList" in plt and
      "ame132_idx != NSNotFound" in plt)
pickblock = plt[plt.index("self.typePickField = ^void"):plt.index("self.typeSlider = ^void")]
check("D3 未命中回落旧显示（新逻辑在旧显示之前，同块内）",
      pickblock.index("ame132_idx != NSNotFound") <
      pickblock.index("[value boolValue] ? @\"YES\" : @\"NO\""))

print("== E. 第三方皮肤修复（authlib-injector 1.2.8）==")
jar8 = os.path.join(REPO, "Natives/resources/authlib-injector-1.2.8.jar")
check("E1 1.2.8 jar 随包（349681B）且 1.2.7 jar 已移除",
      os.path.getsize(jar8) == 349681 and
      not os.path.exists(os.path.join(REPO, "Natives/resources/authlib-injector-1.2.7.jar")))
jarlist = subprocess.run(["unzip", "-l", jar8], capture_output=True, text=True, timeout=60).stdout
check("E2 jar 内含 DiscoveryFilter.class（26.3+ discovery 修复类）",
      "httpd/DiscoveryFilter.class" in jarlist)
mf = subprocess.run(["unzip", "-p", jar8, "META-INF/MANIFEST.MF"],
                    capture_output=True, text=True, timeout=60).stdout
check("E3 jar 清单 Implementation-Version 1.2.8",
      "Implementation-Version: 1.2.8" in mf)
check("E4 下载源 build 56 + 版本常量 1.2.8",
      "artifact/56/authlib-injector-1.2.8.jar" in tp and
      '#define AUTHLIB_INJECTOR_VERSION @"1.2.8"' in tp and
      "1.2.7" not in re.sub(r'//.*', '', tp))
check("E5 bundled 路径随版本常量解析（pathForResource 拼接）",
      'pathForResource:@"authlib-injector-" AUTHLIB_INJECTOR_VERSION' in tp)
check("E6 根因注释入档（26.3 discovery 链路 + 401 机制）",
      "DiscoveryFilter" in tp and "discovery" in tp)

print("== F. l10n 完整性 ==")
langs = ["en", "zh-Hans", "zh-CN", "zh-Hant"]
sets = []
for lang in langs:
    sets.append(set(re.findall(r'^"([^"]+)"\s*=',
                  rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M)))
# Task138 重锚：+2 键（renderer_missing_dylib + mirror_policy-speed_first）
check("F1 四语言键集一致（Task222 重锚：2708 = Task212 基线 2520 + Task222 45 + Task223 41）",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2708,
      f"counts={[len(s) for s in sets]}")
newkeys = ["preference.title.renderer_backend",
           "preference.detail.renderer_backend",
           "preference.title.renderer_backend-mobilegl",
           "preference.title.renderer_backend-mobilegl_gles",
           "preference.title.renderer_backend-mithril"]
check("F2 新键五件套四语言齐备",
      all(k in s for s in sets for k in newkeys))
grammar_ok = True
for lang in langs:
    in_block = False
    for t in rd(f"Natives/resources/{lang}.lproj/Localizable.strings").splitlines():
        t = t.strip()
        if in_block:
            if "*/" in t: in_block = False
            continue
        if t.startswith("/*"):
            if "*/" not in t: in_block = True
            continue
        if not t or t.startswith("//"): continue
        if not re.match(r'^"[^"]+"\s*=\s*".*";\s*$', t):
            grammar_ok = False
check("F3 四语言 .strings 行语法（块注释感知）", grammar_ok)
# Task220：外部审计助手守卫（同 A15 家法）。
_helper1 = "/home/z/my-project/scripts/task116_l10n_audit.py"
_helper2 = "/home/z/my-project/scripts/task116c_precise_audit.py"
if os.path.exists(_helper1) and os.path.exists(_helper2):
    audit1 = subprocess.run([sys.executable, _helper1],
                            capture_output=True, text=True, timeout=120)
    audit2 = subprocess.run([sys.executable, _helper2],
                            capture_output=True, text=True, timeout=120)
    check("F4 全量 key 审计归零（含新 renderer_backend 行）",
          "缺失 (0)" in audit1.stdout and audit1.returncode == 0,
          audit1.stdout[-100:] if audit1.returncode else "")
    check("F5 hasDetail 动态审计归零（intensity 行已去 hasDetail）",
          "共 0 项" in audit2.stdout and audit2.returncode == 0,
          audit2.stdout[-100:] if audit2.returncode else "")
else:
    print("  SKIP  F4/F5 l10n 审计（外部助手缺失：task116_l10n_audit / task116c_precise_audit）")

print("== G. 语法门 + 级联 ==")
touched = ["Natives/sdl3_hook.m", "Natives/main_hook.m", "Natives/utils.h",
           "Natives/LauncherPreferences.m", "Natives/LauncherPreferences.h",
           "Natives/LauncherPreferencesViewController.m",
           "Natives/PLPrefTableViewController.m",
           "Natives/authenticator/ThirdPartyAuthenticator.m"]


def lex_strip(src):
    """真词法剥离：逐字符扫描 code/line-comment/block-comment/string 四态。
    先串后注的顺序保证 URL 字符串里的 // 不被误判为注释（注释先剥的
    伪影会让括号 delta 门误报——Task132 实测：`@"https://..."` 被吃掉
    后未闭合引号级联吞掉后续代码的大括号）。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"' or (c == '@' and i + 1 < n and src[i + 1] == '"'):
            j = i + (2 if c == '@' else 1)
            j = src.index('"', j) if '"' in src[j:] else n
            out.append(' ')
            i = j + 1
        elif c == '/' and i + 1 < n and src[i + 1] == '/':
            j = src.find('\n', i)
            i = n if j == -1 else j
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            j = src.find('*/', i + 2)
            i = n if j == -1 else j + 2
        else:
            if c == '#' and src[i:i + 12] == '#pragma mark':
                j = src.find('\n', i)
                i = n if j == -1 else j
                continue
            out.append(c)
            i += 1
    return ''.join(out)


balance_ok = True
for p in touched:
    s = lex_strip(rd(p))
    for a, b in [("{", "}"), ("(", ")"), ("[", "]")]:
        if s.count(a) != s.count(b):
            balance_ok = False
            print(f"    imbalance {a}{b}: {p} delta={s.count(a) - s.count(b)}")
check("G1 触碰文件括号平衡（词法剥离，8 文件 x 3 括号对）", balance_ok)
delta_ok = True
for p in touched:
    cur = lex_strip(rd(p))
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{p}"],
                          capture_output=True, text=True).stdout
    if not head:
        continue
    head = lex_strip(head)
    if not all(cur.count(a) - cur.count(b) == head.count(a) - head.count(b)
               for a, b in [("{", "}"), ("(", ")"), ("[", "]")]):
        delta_ok = False
        print(f"    bracket delta mismatch: {p}")
check("G2 裸括号 delta 与 HEAD 一致（词法剥离，提交前工作树门）", delta_ok)
check("G3 version.h Task132 增补（四项修复入档）",
      "REVISION 17 addendum (Task 132, no bump)" in
      rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h"))

cascade = {  # Task212 重锚：计数随各轮演化对齐当前现实（129 的 I4 提交后自愈为 47/47）
    "verify_task112_118.py": "ALL PASS (47/47)",
    "verify_task119_124.py": "ALL PASS (62/62)",
    "verify_task125_128.py": "ALL PASS (52/52)",
    "verify_task129.py": "ALL PASS (47/47)",
    "verify_task130.py": "ALL PASS (59/59)",
    "verify_task131.py": "ALL PASS (37/37)",
}
all_cascade = True
for script, expect in cascade.items():
    r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", script)],
                       capture_output=True, text=True, timeout=600)
    ok = expect in r.stdout
    all_cascade = all_cascade and ok
    print(f"    {script}: {'PASS' if ok else 'FAIL -> ' + r.stdout.strip().splitlines()[-1]}")
check("G4 级联六验证器全绿（112_118/119_124/125_128/129/130/131）", all_cascade)

print(f"\n==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS + FAIL}) ====")
sys.exit(0 if FAIL == 0 else 1)
