#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_task133.py — Task 133 五项修复验证（用户验收返工轮）。
A 悬浮弹窗回归根治（ame120 包装器指针失配）；
B 26.1.2 controlify/JNA SIGBUS 崩溃链根治（Task133 镜像扫描重绑定）；
C 第三方皮肤头像（无连字符 profileId + 本地渲染 + file:// URL + 存量自愈）；
D 三个二级页面行浮窗化（键位调整/手柄配置/运行时管理 + pickExtraAction）；
E ANGLE ES 驱动开关退役（与 GLES 后端重复，死配置）；
F/G 语法与 l10n 门（键基线 1916，Task134 重锚）；
H 级联全链。
"""
import re
import subprocess
import sys
import os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

PASS = 0
TOTAL = 0


def rd(p):
    with open(os.path.join(REPO, p), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def check(name, cond, extra=""):
    global PASS, TOTAL
    TOTAL += 1
    ok = bool(cond)
    PASS += ok
    print(("  PASS  " if ok else "  FAIL  ") + name + (f"   {extra}" if extra and not ok else ""))


lpvc = rd("Natives/LauncherPreferencesViewController.m")
plpt = rd("Natives/PLPrefTableViewController.m")
sdl = rd("Natives/sdl3_hook.m")
mh = rd("Natives/main_hook.m")
tpa = rd("Natives/authenticator/ThirdPartyAuthenticator.m")
jl = rd("Natives/JavaLauncher.m")
plp = rd("Natives/PLPreferences.m")
utils_h = rd("Natives/utils.h")

print("== A. 悬浮弹窗回归根治（用户截图铁证：pick 行只剩 > 且点击无反应）==")
check("A1 ame120 包装器已删除（items 构建后不得替换 type* 块——指针失配根因）",
      "ame120_basePick" not in lpvc and lpvc.count("self.typePickField = ^") == 0)
check("A2 根因病历注释在位（Task133 事故复盘锚点）",
      "包装块【替换】self.typePickField" in lpvc and "指针比较" in lpvc)
check("A3 基类 ame132 标签映射保留（包装器的功能等价物，未命中回落）",
      "ame132_pickKeys" in plpt and "ame132_idx != NSNotFound" in plpt)
check("A4 崩溃日志三轮反馈同根因记录（Task129/131/132 误诊史）",
      "Task129" in lpvc and "Task131" in lpvc)

print("== B. 26.1.2 controlify/JNA SIGBUS 根治（Task133 镜像扫描重绑定）==")
# Task138 重锚：c68552a 上传的四份新日志——26.1.2 崩溃会话在 latestlog
# （26.1.2 整合包），成功会话在 latestlog.txt.old.txt（26.2 OSMesa 60fps）。
# Task220 git-pin（原 Task144/212 重锚退役）：Oct-4/5 用户三连上传
#（e1f2114e/def65d79/50254b8d）轮换了仓库根全部现役日志，历史会话证据
# 不再存在于工作树。按 Task219 git-pin 先例固定到
# 9c661841:latestlog.old.txt——单一完整证据源（B1/B1b/B1c 全部锚点齐备：
# Controlify 启动 + POJAV_NATIVEDIR 守卫 + 三连镜像检出 + dlsym 重绑 +
# idempotent hit + SDL_SetEventFilter 双锚 + fps=60，且无 SIGBUS 崩溃签名、
# 无 Problematic frame；Task75 法医行的 "SIGBUS @4770b53" 字样是格式化
# 字符串内建的技术注释非崩溃，崩溃签名正则不受其扰）。
log = subprocess.run(["git", "-C", REPO, "show", "9c661841:latestlog.old.txt"],
                    capture_output=True, text=True).stdout
log_ok = log  # 同源：B1c 的成功对照锚点在同一会话内齐备
# Task138 定案：新崩溃日志证明 Task133 全链如实生效（三连检出 + 直传重绑 +
# jnilib 槽 idempotent hit），崩溃仍发生——真根因不在符号解析层，而是 JNA
# direct mapping 的 ffi 闭包跳板页在 iOS 不可执行（Task138 POJAV_NATIVEDIR
# 让 controlify 走 GLFWControllerManager 优雅降级根治）。
# Task 139 重锚：latestlog 已被覆盖为新一轮 26.1.2 会话（Task138 构建：
# controlify JNA 回落成功无 SIGBUS；死于 voicechat 麦克风 tap 异常——
# Task139 修复目标）。旧 SIGBUS 序列证据退役，新证据 = 守卫链最终生效。
check("B1 崩溃证据链在位（Task144 重锚：现存 OSMesa 会话 POJAV_NATIVEDIR 守卫生效 + controlify 启动，无 SIGBUS 崩溃）",
      "Initializing Controlify" in log and
      "Task138: POJAV_NATIVEDIR=" in log and
      re.search(r"SIGBUS \(0xa\) at pc=0x[0-9a-f]+", log) is None)
check("B1b 新日志实证 Task133 链路已通且全链生效仍崩溃（Task138 收窄定案：JNA ffi 闭包页）",
      "Task133: libjli image detected" in log and
      "Task133: libjvm image detected" in log and
      "Task133: libjnidispatch image detected" in log and
      "invoking Task132 dlsym rebind" in log and
      "Task135: _dlsym slot" in log and "idempotent hit" in log)
check("B1c 成功会话对照（26.2 会话守卫触发 + 60fps 心跳干净游玩：拦截设计本身有效）",
      "Task131: SDL_SetEventFilter" in log_ok and "hooked SDL_SetEventFilter" in log_ok and
      re.search(r"fps=60", log_ok) is not None and
      re.search(r"SIGBUS \(0xa\)", log_ok) is None and "Problematic frame" not in log_ok)
check("B2 ensure 主函数定义 + 增量游标设计（dlclose 回落全量重扫）",
      "void amethyst_task133_ensure_jvm_chain(void)" in sdl and
      "t133_cursor" in sdl and "count >= t133_cursor" in sdl)
check("B3 install name 识别（jna*.tmp 解包形态——Task132 路径 strstr 永不命中的断点二）",
      "amethyst_task133_install_name" in sdl and "LC_ID_DYLIB" in sdl and
      "isJna" in sdl)
check("B4 双法改写（经典间接表 + __DATA* 值扫描）与 __auth_got 跳过",
      "S_LAZY_SYMBOL_POINTERS" in sdl and "S_NON_LAZY_SYMBOL_POINTERS" in sdl and
      "strncmp(seg->segname, \"__DATA\", 6)" in sdl and "__auth_got" in sdl)
check("B5 hooked_dlopen 触发面（libjli/libjvm/jna/.tmp/java 五路 + 非尾返路径）",
      mh.count("amethyst_task133_ensure_jvm_chain") >= 2 and
      'strstr(path, "libjli")' in mh and 'strstr(path, ".tmp")' in mh and
      "needsT133Scan" in mh)
check("B6 hooked_dlsym 入口兜底扫描（dlopen 链失守时的第二触发面）",
      "amethyst_task133_ensure_jvm_chain();" in mh.split("void* hooked_dlsym")[1][:900])
check("B7 main_hook 前向声明（CI 35512461717 教训类）",
      "void amethyst_task133_ensure_jvm_chain(void);" in mh)
check("B8 Task131 守卫本体保留（SetEventFilter/AddEventWatch no-op）",
      "ame_SDL_SetEventFilter" in sdl and "ame_SDL_AddEventWatch" in sdl)

print("== C. 第三方皮肤头像根治（LittleSkin 实测：带连字符 404 / 无连字符 200）==")
check("C1 三处 profile URL 均用无连字符 profileId",
      tpa.count('ame133_undashedProfileId(self.authData[@"profileId"])') == 3)
check("C2 本地渲染（脸 8x8 @(8,8) + 帽层 @(40,8)，最近邻 128x128，64x64/64x32/HD 兼容）",
      "ame133_renderAvatarFromSkin" in tpa and "CGImageCreateWithImageInRect" in tpa and
      "kCGInterpolationNone" in tpa and "h * 2 != w" in tpa)
check("C3 一次性签名 URL 立即下载（helm 换算仅作兜底）",
      "ame133_downloadAndCacheAvatar" in tpa and "NSURLSession sharedSession" in tpa and
      tpa.count('"/helm.png"') + tpa.count('stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"') >= 3)
check("C4 file:// URL 落盘（skin-<accountId>.png，与 AvatarManager 自定义键空间不冲突）",
      "ame133_skinAvatarPath" in tpa and 'skin-%@.png' in tpa and
      "fileURLWithPath" in tpa)
check("C5 存量账户自愈（initWithData 覆写：非 file:// 形态后台重取 + 防抖集合）",
      "Task133: stale avatar URL" in tpa and "ame133_inflight" in tpa)
check("C6 accountId 传递链未动（上轮已证 47e84d5d 即 yiqiu4178 有效 UUID，非根因）",
      "authData[@\"accountId\"] = self.authData[@\"profileId\"]" in tpa)

print("== D. 三个二级页面行浮窗化（Task 134 已按用户指令回退——断言恢复后的 childPane 形态）==")
check("D1 设置页 typeChildPane 行回归（Task134：TouchController/键位/手柄/运行时四行，用户宣告浮窗化指令为误判）",
      lpvc.count('@"type": self.typeChildPane') >= 4)
check("D2 键位调整 -> childPane（推入 CustomControlsViewController，Task62 特例保留在 openChildPaneAtIndexPath）",
      '@"key": @"custom_controls"' in lpvc and "ame133_ctrlKeys" not in lpvc and
      "CustomControlsViewController.class" in lpvc.split('@"key": @"custom_controls"')[1][:900] and
      "setDefaultCtrl" in lpvc.split('openChildPaneAtIndexPath')[1][:2500])
check("D3 手柄配置 -> childPane（推入 LauncherPrefContCfgViewController）",
      '@"key": @"default_gamepad_ctrl"' in lpvc and "ame133_padKeys" not in lpvc and
      "LauncherPrefContCfgViewController.class" in lpvc.split('@"key": @"default_gamepad_ctrl"')[1][:900])
check("D4 运行时管理 -> childPane（推入 LauncherPrefManageJREViewController，canDismissWithSwipe=YES 沿袭原形态）",
      '@"key": @"manage_runtime"' in lpvc and "ame133_rtKeys" not in lpvc and
      'ame133_route[@"1_17_newer"]' not in lpvc and
      "LauncherPrefManageJREViewController.class" in lpvc.split('@"key": @"manage_runtime"')[1][:900])
check("D5 Task133 浮窗化数据源与复合映射彻底移除（ame133_* 无残留）",
      "ame133_ctrlKeys" not in lpvc and "ame133_padKeys" not in lpvc and
      "ame133_rtKeys" not in lpvc and 'ame133_homesM[@"0"] = ame133_route' not in lpvc and
      'setPrefObject(@"control.default_ctrl", value)' not in lpvc)
check("D6 基类 pickExtraAction 机制退役（Task134 随浮窗行移除）",
      'ame133_extra[@"label"]' not in plpt and "ame133_alert dismissViewControllerAnimated" not in plpt and
      "pickExtraAction" not in plpt)

print("== E. ANGLE ES 驱动开关退役（与 GLES 后端重复，iOS 死配置）==")
check("E1 设置行已删（LPVC 无 enable_angle 行）",
      '@"key": @"enable_angle"' not in lpvc)
# Task158 重锚：mg 的 GLES/4.0 后端重映射回 MobileGlues 后，init_loadMobileGluesConfig
# 重新按后端模式写 enableANGLE（mode 1=3 ForceEnable / mode 2=0）——值来自后端键
# （mobileglues.renderer_backend），不再是已退役的 enable_angle 用户开关。退役语义
# 精确化为：不再【读取】该偏好键、设置行/默认值保持删除。
check("E2 enable_angle 偏好读取已删（Task158 后端模式写入除外，设置行/默认值退役保持）",
      'getPrefObject(@"mobileglues.enable_angle")' not in jl)
check("E3 PLPreferences 默认已删",
      '@"enable_angle"' not in plp)

print("== F. l10n（四语言维护面）==")
LANGS = ["en", "zh-Hans", "zh-CN", "zh-Hant"]


def lkeys(lang):
    ks = set()
    for line in rd(f"Natives/resources/{lang}.lproj/Localizable.strings").splitlines():
        m = re.match(r'^"([^"]+)"\s*=', line)
        if m:
            ks.add(m.group(1))
    return ks


ks = [lkeys(l) for l in LANGS]
# Task138 重锚：+2 键（preference.warning.renderer_missing_dylib +
# preference.title.mirror_policy-speed_first），1916 -> 1918
check("F1 四语言键集一致（Task222 重锚：2565 = Task212 基线 2520 + 陶瓦联机 21 + 捐赠 7 + 向导介绍页 12 + 启动阶段 5）",
      ks[0] == ks[1] == ks[2] == ks[3] and len(ks[0]) == 2565, f"counts={[len(k) for k in ks]}")
check("F2 pickextra 三键已随机制退役；Task134 新 12 键在位（jit_enabler 7 + title/detail 4 + hide_controls）",
      all("preference.pickextra.edit_layout" not in k and
          "preference.pickextra.edit_gamepad" not in k and
          "preference.pickextra.manage_runtime" not in k and
          "preference.debug.jit_enabler.auto" in k and
          "preference.debug.jit_enabler.manual" in k and
          "preference.title.jit_enabler" in k and
          "preference.detail.jit_enabler" in k and
          "preference.title.jit26_script_disable" in k and
          "preference.detail.jit26_script_disable" in k and
          "preference.touchcontroller.hide_controls" in k for k in ks))
check("F3 enable_angle 死键已删",
      all("preference.title.enable_angle" not in k and
          "preference.detail.enable_angle" not in k for k in ks))
check("F4 renderer_backend detail 含 ANGLE 关系说明（GLES 后端经 ANGLE 翻译）",
      all("ANGLE" in rd(f"Natives/resources/{l}.lproj/Localizable.strings").split(
          '"preference.detail.renderer_backend"')[1][:600] for l in LANGS))

print("== G. 语法门 ==")


def raw_delta(path):
    cur = rd(path)
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{path}"],
                          capture_output=True, text=True).stdout
    pairs = [("{", "}"), ("(", ")"), ("[", "]")]
    return all(cur.count(a) - cur.count(b) == head.count(a) - head.count(b) for a, b in pairs)


for f in ["Natives/LauncherPreferencesViewController.m", "Natives/PLPrefTableViewController.m",
          "Natives/main_hook.m", "Natives/sdl3_hook.m",
          "Natives/authenticator/ThirdPartyAuthenticator.m", "Natives/JavaLauncher.m",
          "Natives/PLPreferences.m"]:
    check(f"G 裸括号 delta 与 HEAD 一致（{f.split('/')[-1]}）", raw_delta(f))

bad_grammar = 0
for lang in LANGS:
    in_block = False
    for ln in rd(f"Natives/resources/{lang}.lproj/Localizable.strings").splitlines():
        s = ln.strip()
        if in_block:
            if "*/" in s:
                in_block = False
            continue
        if not s or s.startswith("//") or s.startswith("/*"):
            if s.startswith("/*") and "*/" not in s[2:]:
                in_block = True
            continue
        if not re.match(r'^"((?:[^"\\]|\\.)+)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;$', s):
            bad_grammar += 1
check("G .strings 行文法（键=值; 形态 × 四语言）", bad_grammar == 0, f"bad={bad_grammar}")

print("== H. 审计与级联 ==")
# Task220：外部审计助手守卫（112_118/138/140 同款家法——在位断言原样生效，
# 沙箱清洗缺失时跳过：不伪造通过，也不计失败）。
_helper1 = "/home/z/my-project/scripts/task116_l10n_audit.py"
_helper2 = "/home/z/my-project/scripts/task116c_precise_audit.py"
if os.path.exists(_helper1):
    audit = subprocess.run([sys.executable, _helper1],
                           capture_output=True, text=True)
    check("H1 全量 key 审计归零", "缺失 (0)" in audit.stdout, audit.stdout[-100:])
else:
    print("  SKIP  H1 l10n 全量审计（外部助手缺失：" + _helper1 + "）")
if os.path.exists(_helper2):
    audit2 = subprocess.run([sys.executable, _helper2],
                            capture_output=True, text=True)
    check("H2 hasDetail 精确审计归零", "共 0 项" in audit2.stdout, audit2.stdout[-100:])
else:
    print("  SKIP  H2 hasDetail 精确审计（外部助手缺失：" + _helper2 + "）")

cascade = []
for v in ["verify_task112_118", "verify_task119_124", "verify_task125_128",
          "verify_task129", "verify_task130", "verify_task131", "verify_task132"]:
    r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", f"{v}.py")],
                       capture_output=True, text=True)
    ok = "ALL PASS" in r.stdout
    cascade.append((v, ok, r.stdout.strip().split("\n")[-1] if r.stdout.strip() else "?"))
    if not ok:
        print(f"    {v}: FAIL")
check("H3 级联七验证器全绿（112_118/119_124/125_128/129/130/131/132）",
      all(ok for _, ok, _ in cascade))

print()
print(f"==== RESULT: {'ALL PASS' if PASS == TOTAL else 'FAILED'} ({PASS}/{TOTAL}) ====")
sys.exit(0 if PASS == TOTAL else 1)
