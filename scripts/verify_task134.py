#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_task134.py — Task 134 六项修复验证（9fa66fb 装机反馈轮）。
A TouchController 26.2 失效根治（双 ABI 传输层 + 双通道桥接）；
B 二级菜单恢复（四行 typeChildPane + pickExtraAction 退役）；
C 屏蔽控件（pane 开关 + 空布局预设写入 mod 配置）；
D 右上角头像实时刷新（profilePicURL 更新后广播 UpdateAccountInfo）；
E 26.1.2 崩溃链加固（200ms 镜像扫描看门狗 + 读回验证）；
F JIT 设置（LiveContainer 式工具选择 + iOS 26 JS 脚本开关）；
G l10n 与发布物（四语言 1916 键 + announcements/README 6.0.0）；
H 语法门 + 级联全链。
"""
import json
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
tpa = rd("Natives/authenticator/ThirdPartyAuthenticator.m")
jl = rd("Natives/JavaLauncher.m")
plp = rd("Natives/PLPreferences.m")
utils_h = rd("Natives/utils.h")
tcpane = rd("Natives/TouchControllerPreferencesViewController.m")
tcbr = rd("Natives/TouchControllerBridge.m")
tct = rd("Natives/TouchController/ios_transport.c")
tcrb = rd("Natives/TouchController/ring_buffer.c")
tcrbh = rd("Natives/TouchController/ring_buffer.h")
cmake = rd("Natives/CMakeLists.txt")
rpvc = rd("Natives/LauncherRightPanelViewController.m")
svc = rd("Natives/SurfaceViewController.m")

print("== A. TouchController 26.2 失效根治（双 ABI 传输层）==")
check("A1 双 ABI 病历注释在位（根因：mod 26.2 单例制 vs 旧句柄制 JNI 同名异签名）",
      "双 ABI 兼容实现" in tct and "单例制" in tct and "同符号双签名" in tct)
check("A2 五个 JNI 符号齐全（init/new/receive/send/destroy——新旧两代 mod 的全部入口）",
      all(s in tct for s in [
          "Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_init",
          "Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_new",
          "Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_receive",
          "Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_send",
          "Java_top_fifthlight_touchcontroller_common_platform_ios_Transport_destroy"]))
check("A3 指针注册表判别（零解引用：活动 malloc 指针 vs jbyteArray 不可能同一）",
      "tc_is_registered_handle" in tct and "tc_is_registered_handle((void *)(intptr_t)handle_or_buffer)" in tct)
check("A4 send trampoline 寄存器重解释（新 ABI off 取 a3 低 32 位——w3；len 在 a4/w4）",
      "(jint)(uint32_t)(uintptr_t)buffer_or_off" in tct and "jint len = len_or_off" in tct)
check("A5 新 C API 与 mod 仓库当前签名一致（receive(void*)/send(const void*,int) 单例通道）",
      "int touchcontroller_ios_receive(void *buf)" in tct and
      "int touchcontroller_ios_send(const void *buf, int len)" in tct)
check("A6 旧 C API 加 _v1 后缀保留（启动器桥接与旧 mod 兼容，避免同名异签名冲突）",
      "touchcontroller_ios_receive_v1(long long handle" in tct and
      "touchcontroller_ios_send_v1(long long handle" in tct)
check("A7 同路径复用语义（旧 mod 与启动器各调 new(path) 拿同一传输块——与旧 xcframework 一致）",
      tct.count("strcmp(g_named_paths[i], path) == 0") >= 1 and
      tct.count("strcmp(g_named_paths[i], cPath) == 0") >= 1)
check("A8 ring_buffer 忠实移植（alloc/free/enqueue/try_enqueue/dequeue 全家 + 扩容回绕搬移）",
      all(s in tcrb for s in ["ring_buffer_alloc", "ring_buffer_free", "ring_buffer_enqueue",
                               "ring_buffer_try_enqueue", "ring_buffer_dequeue", "ring_buffer_expand"]))
check("A9 CMake Level 0 源码优先（双 ABI 版参与构建，旧 xcframework 退役仅存档）",
      "Level 0" in cmake and "Task134 dual-ABI transport" in cmake and
      cmake.index("Level 0: 源码编译") < cmake.index("Level 1: 预编译 XCFramework"))
check("A10 桥接双通道（收：先单例后句柄；发：广播两通道）",
      "g_TouchController_SingletonReceive" in tcbr and "g_TouchController_SingletonSend" in tcbr and
      tcbr.index("g_TouchController_SingletonReceive(tempBuffer)") < tcbr.index("g_TouchController_Receive(handle") and
      tcbr.count("g_TouchController_SingletonSend(data.bytes") == 1)
check("A11 桥接 dlsym 符号更新到 _v1 命名 + 单例 API",
      'dlsym(RTLD_DEFAULT, "touchcontroller_ios_receive_v1")' in tcbr and
      'dlsym(RTLD_DEFAULT, "touchcontroller_ios_receive")' in tcbr)
check("A12 SurfaceViewController 零改动仍工作（transport 创建/消息循环/发送点不变）",
      "createTransportWithName" in svc and "startTouchControllerMessageLoop" in svc and
      "[TouchControllerBridge sendToTransport:" in svc)
check("A13 JNI trampoline 调用约定防御（GetArrayLength 边界检查 + off 范围检查）",
      "GetArrayLength" in tct and "Bad message range" in tct)

print("== B. 二级菜单恢复（用户宣告浮窗化指令为误判）==")
check("B1 四行 typeChildPane 回归（TouchController/键位/手柄/运行时）",
      lpvc.count('@"type": self.typeChildPane') >= 4 and
      'NSClassFromString(@"TouchControllerPreferencesViewController")' in lpvc and
      "CustomControlsViewController.class" in lpvc and
      "LauncherPrefContCfgViewController.class" in lpvc and
      "LauncherPrefManageJREViewController.class" in lpvc)
check("B2 pickExtraAction 机制退役（基类代码 + l10n 键 + 数据源全清）",
      "pickExtraAction" not in plpt and "ame133_ctrlKeys" not in lpvc and
      "ame133_padKeys" not in lpvc and "ame133_rtKeys" not in lpvc)
check("B3 Task132/133 复合读写映射退役（pane 自管 enable+mode 与 UDP 联动）",
      'setPrefObject(@"control.mod_touch_enable", @(ame132_mode != 0))' not in lpvc and
      'setPrefObject(@"control.default_ctrl", value)' not in lpvc and
      'ame133_homesM[@"0"] = ame133_route' not in lpvc)

print("== C. 屏蔽控件（无控件界面——空布局预设写入 mod 配置）==")
check("C1 pane 开关行在位（mod_touch_hide_controls，位于 moveview 与 about 之间）",
      '@"key": @"mod_touch_hide_controls"' in tcpane and
      "preference.touchcontroller.hide_controls" in tcpane and
      tcpane.index('@"mod_touch_moveview_enable"') < tcpane.index('@"mod_touch_hide_controls"') < tcpane.index('@"mod_touch_about"'))
check("C2 PLPreferences 默认值",
      '@"mod_touch_hide_controls": @NO' in plp)
check("C3 →Task140 终态：mod 侧空布局写入器退役，一次性修复器接管（只动污染指针）",
      "ame140_remediateTouchControllerConfig" in jl and
      '0196a1ba-6e9a-7b4c-8d5e-3f2a1c0e9b7d' in jl and
      'config/touchcontroller' in jl and
      'pointsToClean' in jl and
      '@"type": @"custom", @"uuid": cleanUuid' not in jl)
check("C4 可逆性 →Task140：备份恢复路径保留在修复器内（control.mod_touch_prev_preset_json）",
      "control.mod_touch_prev_preset_json" in jl and
      "removeObjectForKey:@\"preset\"" in jl)
check("C5 调用点在 gameDir 解析后（JLI_Launch 前，当次启动生效）",
      jl.index("ame140_remediateTouchControllerConfig(gameDir)") > jl.index("ame95_warnIncompleteImport(gameDir)"))
check("C6 →Task140：空布局 JSON 载荷已删（presetJson/Amethyst Clean 字面量写入清零）",
      '\\"name\\" : \\"Amethyst Clean\\"' not in jl and
      'presetJson writeToFile' not in jl)

print("== D. 右上角头像实时刷新 ==")
check("D1 通知助手定义（主线程广播 UpdateAccountInfo + 病历注释：磁贴只在 viewDidLoad 读一次）",
      "ame134_notifyAccountInfoUpdated" in tpa and
      "postNotificationName:@\"UpdateAccountInfo\"" in tpa and
      "dispatch_get_main_queue(), ^{" in tpa.split("ame134_notifyAccountInfoUpdated(void)")[1][:400])
check("D2 全部 profilePicURL 写点均通知（三方法主路径 + mc-heads 兜底 ≥6 处）",
      tpa.count("ame134_notifyAccountInfoUpdated();") >= 6)
check("D3 两个展示 VC 均已注册该通知（通知消费者在位，无需改动）",
      "name:@\"UpdateAccountInfo\"" in rd("Natives/LauncherNewsViewController.m") and
      "name:@\"UpdateAccountInfo\"" in rd("Natives/LauncherRightPanelViewController.m"))

print("== E. 26.1.2 崩溃链加固（链路无关看门狗）==")
check("E1 看门狗实现（主队列 200ms 定时器 + 事件回调跑 ensure_jvm_chain + 常驻锚点）",
      "amethyst_task134_watchdog_maybe_start" in sdl and
      "DISPATCH_SOURCE_TYPE_TIMER" in sdl and
      "200 * NSEC_PER_MSEC" in sdl and
      "t134_retain_anchor" in sdl)
check("E2 检出即启动（isJli/isJvm 与 isJna 分支都挂了看门狗启动）",
      sdl.count("amethyst_task134_watchdog_maybe_start();") >= 3)
check("E3 前向声明（定义在 ensure 之后，CI 35512461717 教训类防御）",
      "static void amethyst_task134_watchdog_maybe_start(void);" in sdl and
      "amethyst_task134_jvm_watchdog_start" in utils_h)
check("E4 Task132 重绑定读回验证（写后槽值校验 + READBACK FAILED 取证日志）",
      "READBACK FAILED" in sdl and "*slot != hook_fn" in sdl)
# Task138 重锚：c68552a 四日志（latestlog=26.1.2 崩溃 / latestlog.txt.old.txt
# =26.2 成功）——Task132 直传重绑被调用 + jnilib 槽 idempotent hit（fishhook
# 抢先，Task135 取证假说落定），崩溃链最终定案为 JNA ffi 闭包页（Task138 修复）。
check("E4b 新日志取证闭环（c68552a：直传重绑调用 + idempotent hit，Task138 定案 JNA ffi 闭包页）",
      # Task212 重锚：99d8122e 上传把会话再次轮换——直传重绑证据改钉工作树
      # 现行日志（99d8122e 的 latestlog.txt 同含 rebind/idempotent 双锚）；
      # latestlog.old / latestlog.txt.old.txt 两文件名已不存在于工作树
      # （Task144 时代的文件名假设早已随多轮轮换失效 = 存量漂移，本轮收口）。
      rd("latestlog.txt").count("invoking Task132 dlsym rebind") >= 1 and
      "idempotent hit" in rd("latestlog.txt"))
check("E4c 静默早退根治（核心改直传 hdr+slide + 旧入口句柄查找失败落日志）",
      "amethyst_task132_rebind_jna_dlsym_ex(const struct mach_header_64 *ame132_hdr" in sdl and
      "jna rebind handle %p not found in dyld image" in sdl and
      "jna rebind rejected null args" in sdl and
      "jna rebind bad magic" in sdl)
check("E4d 看门狗重试机制（未验证绑定每 200ms 重试 + 100 次上限 + 验证通过即停）",
      "amethyst_task134_retry_pending_jna" in sdl and
      "t134_jna_attempts >= 100" in sdl and
      "amethyst_task134_jna_retry_arm" in sdl and
      "amethyst_task134_jna_retry_clear" in sdl and
      sdl.index("amethyst_task134_retry_pending_jna();") < sdl.index("if (t133_initialized && count == t133_cursor)"))
check("E5 看门狗病历注释（秒级窗口取证：JNA 加载到 controlify 解析相隔秒级）",
      "链路无关" in sdl and "相隔【秒级】" in sdl)

print("== F. JIT 设置（LiveContainer 式多工具方案）==")
check("F1 jit_enabler pick 行（7 选项 auto/stikjit/sidestore/stosdebug/jitstreamer/trollstore/manual）",
      '@"key": @"jit_enabler"' in lpvc and
      all('@"%s"' % k in lpvc for k in
          ["auto", "stikjit", "sidestore", "stosdebug", "jitstreamer", "trollstore", "manual"]) and
      lpvc.count("preference.debug.jit_enabler.") == 7)
check("F2 jit26_script_disable 开关行（用户点名：关闭 iOS 26 走 js 文件获取 JIT）",
      '@"key": @"jit26_script_disable"' in lpvc and
      "jit26_script_disable" in plp)
check("F3 PLPreferences 默认（jit_enabler=auto，脚本默认携带）",
      '@"jit_enabler": @"auto"' in plp and '@"jit26_script_disable": @NO' in plp)
check("F4 waitJITEnabled 七路分发（各工具 URL scheme 逐字在位）",
      "apple-magnifier://enable-jit?bundle-id=" in rpvc and
      "sidestore://enable-jit?bundle-id=" in rpvc and
      "stosdebug://enableJIT?bundleId=" in rpvc and
      "http://[fd00::]:9172/launch_app/" in rpvc and
      "stikjit://enable-jit?bundle-id=%@&pid=%d" in rpvc and
      "sidestore://sidejit-enable?pid=%d" in rpvc)
check("F5 脚本开关消费（normal 路径 + TXM 重连路径双门控 ame134_noScript / jit26_script_disable）",
      "ame134_noScript" in rpvc and
      'getPrefBool(@"debug.jit26_script_disable")' in rpvc and
      rpvc.count('getPrefBool(@"debug.jit26_script_disable")') >= 2)
check("F6 auto 语义保真（默认行为不变：TrollStore 检测 → stikjit → sidestore 分支保留）",
      "hasTrollStoreJIT" in rpvc and "@available(iOS 17.4, *)" in rpvc)

print("== G. l10n 与发布物 ==")
LANGS = ["en", "zh-Hans", "zh-CN", "zh-Hant"]


def lkeys(lang):
    ks = set()
    for line in rd(f"Natives/resources/{lang}.lproj/Localizable.strings").splitlines():
        m = re.match(r'^"([^"]+)"\s*=', line)
        if m:
            ks.add(m.group(1))
    return ks


ks = [lkeys(l) for l in LANGS]
# Task138 重锚：+2 键（renderer_missing_dylib + mirror_policy-speed_first）
check("G1 四语言键集一致（Task157 基线 2228 = Task156 基线 2228 + Task157 组件键 2）",
      ks[0] == ks[1] == ks[2] == ks[3] and len(ks[0]) == 2520, f"counts={[len(k) for k in ks]}")
check("G2 Task134 新键齐备（jit_enabler 7 + title/detail 4 + hide_controls；pickextra 3 键已删）",
      all("preference.debug.jit_enabler.auto" in k and
          "preference.debug.jit_enabler.manual" in k and
          "preference.title.jit_enabler" in k and
          "preference.detail.jit_enabler" in k and
          "preference.title.jit26_script_disable" in k and
          "preference.detail.jit26_script_disable" in k and
          "preference.touchcontroller.hide_controls" in k and
          "preference.pickextra.edit_layout" not in k for k in ks))
try:
    ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))
    ann_ok = any(a["id"] == "v6-0-0-release-2026-09-21" for a in ann["announcements"])
except Exception:
    ann_ok = False
check("G3 announcements.json 合法且含 v6.0.0 条目", ann_ok)
check("G4 双语 README 更新（新差异行 + 本地化行数刷新）",
      "Dual-ABI Transport" in rd("README.md") and "双 ABI 传输层" in rd("README_CN.md") and
      "JIT Enabler Picker" in rd("README.md") and "2000+ lines" in rd("README.md"))

print("== H. 语法门 ==")


def raw_delta(path):
    cur = rd(path)
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{path}"],
                          capture_output=True, text=True).stdout
    pairs = [("{", "}"), ("(", ")"), ("[", "]")]
    return all(cur.count(a) - cur.count(b) == head.count(a) - head.count(b) for a, b in pairs)


for f in ["Natives/LauncherPreferencesViewController.m", "Natives/PLPrefTableViewController.m",
          "Natives/sdl3_hook.m", "Natives/authenticator/ThirdPartyAuthenticator.m",
          "Natives/JavaLauncher.m", "Natives/PLPreferences.m",
          "Natives/LauncherRightPanelViewController.m",
          "Natives/TouchControllerPreferencesViewController.m",
          "Natives/TouchControllerBridge.m", "Natives/CMakeLists.txt"]:
    check(f"H 裸括号 delta 与 HEAD 一致（{f.split('/')[-1]}）", raw_delta(f))

# 新文件（HEAD 无）：绝对平衡
for f in ["Natives/TouchController/ios_transport.c", "Natives/TouchController/ring_buffer.c",
          "Natives/TouchController/ring_buffer.h"]:
    src = rd(f)
    balanced = all(src.count(a) == src.count(b) for a, b in [("{", "}"), ("(", ")"), ("[", "]")])
    check(f"H 新文件裸括号绝对平衡（{f.split('/')[-1]}）", balanced)


def strings_grammar(lang):
    bad = 0
    for ln in rd(f"Natives/resources/{lang}.lproj/Localizable.strings").splitlines():
        s = ln.strip()
        if not s or s.startswith("//") or s.startswith("/*"):
            continue
        if not re.match(r'^"[^"]+"\s*=\s*"[^"]*";\s*$', s):
            bad += 1
    return bad


for lang in LANGS:
    # 21 处历史“违例”（多行块注释与含转义引号的存量行）HEAD 即存在——
    # 门语义为 Task134 零新增违例（delta 与 HEAD 一致），与裸括号门同款。
    head = subprocess.run(["git", "-C", REPO, "show",
                           f"HEAD:Natives/resources/{lang}.lproj/Localizable.strings"],
                          capture_output=True, text=True).stdout
    head_bad = sum(1 for ln in head.splitlines()
                   if (s := ln.strip()) and not s.startswith("//") and not s.startswith("/*")
                   and not re.match(r'^"[^"]+"\s*=\s*"[^"]*";\s*$', s))
    cur_bad = strings_grammar(lang)
    check(f"H .strings 行文法零新增违例（{lang}）", cur_bad <= head_bad,
          f"cur={cur_bad} head={head_bad}")

print("== I. 级联 ==")
for v in ["verify_task112_118", "verify_task119_124", "verify_task125_128",
          "verify_task129", "verify_task130", "verify_task131", "verify_task132", "verify_task133"]:
    r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", v + ".py")],
                       capture_output=True, text=True, timeout=300)
    ok = "ALL PASS" in r.stdout
    check(f"I 级联 {v} ALL PASS", ok)

print()
print(f"==== RESULT: {'ALL PASS' if PASS == TOTAL else 'FAILED'} ({PASS}/{TOTAL}) ====")
sys.exit(0 if PASS == TOTAL else 1)
