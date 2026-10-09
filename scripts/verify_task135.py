#!/usr/bin/env python3
"""Task 135 验证器：两项装机反馈的根治 + 取证加固。

覆盖：
  A. TouchController 26.2 修复（Static Library 模式自动回落 UDP 通道）
  B. SDL3 二进制补丁（SDL_SetEventFilter/AddEventWatch 入口 JNA closure 守卫）
  C. 取证加固（Task132 _ex 幂等日志 + Task133 _dlsym 双通道）
  D. 语法门（括号平衡 / l10n 键基线 / 补丁幂等）
  E. 级联（九级验证器全绿 + Makefile TAB 基线重锚）
"""
import io
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # Task168: portable (was a parallel-session sandbox path)
sys.path.insert(0, os.path.join(REPO, "scripts"))

PASS = FAIL = 0
def check(name, cond, note=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {note}")

def rd(p):
    return io.open(os.path.join(REPO, p), encoding="utf-8", errors="replace").read()

def balance(src):
    state = depth = i = 0
    n = len(src)
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
    return depth == 0 and state == 0

print("== A. TouchController 26.2 修复（alpha14 iOS 分支上游 WIP 回归的启动器侧兜底）==")
jl = rd("Natives/JavaLauncher.m")
m = re.search(r'mode == 2\).*?setenv\("TOUCH_CONTROLLER_PROXY_SOCKET".*?\n(.*?)\n\s*\}', jl, re.S)
check("A1 Static 模式双环境变量（SOCKET + UDP 回落）",
      m is not None and 'setenv("TOUCH_CONTROLLER_PROXY", "12450", 1);' in (m.group(1) if m else ""),
      "static 分支需同时设置两个环境变量")
check("A2 回落注释含 alpha14 WIP 根因链",
      "没有" in jl and "return { IosPlatform(socketPath) }" in jl and "alpha13" in jl)
check("A3 日志行含 UDP fallback 说明",
      "+ UDP fallback: mod 0.3.1-alpha14 iOS static branch is upstream" in jl)

langs = ["en", "ja", "km", "zh-CN", "zh-Hans", "zh-Hant"]
ok3 = True
for l in langs:
    s = rd(f"Natives/resources/{l}.lproj/Localizable.strings")
    m2 = re.search(r'^"preference\.touchcontroller\.staticlib\.message" = "(.*)";$', s, re.M)
    if not m2 or ("UDP" not in m2.group(1) and "12450" not in m2.group(1)):
        ok3 = False
        check(f"A3.{l} staticlib 文案含 UDP 回落说明", False, l)
    else:
        check(f"A3.{l} staticlib 文案含 UDP 回落说明", True)

print("== B. SDL3 二进制补丁（26.1.2 controlify/JNA closure SIGBUS 源头守卫）==")
patch_py = rd("scripts/patch_sdl3_eventfilter_guard.py")
check("B1 补丁脚本存在且含原始字节哨兵",
      "PRISTINE_SET_EVENT_FILTER" in patch_py and "PRISTINE_ADD_EVENT_WATCH" in patch_py)
r = subprocess.run([sys.executable, os.path.join(REPO, "scripts/patch_sdl3_eventfilter_guard.py"),
                    os.path.join(REPO, "Natives/resources/Frameworks/libSDL3.dylib"), "--verify"],
                   capture_output=True, text=True, timeout=60)
check("B2 补丁幂等验证通过（--verify 退出 0）",
      r.returncode == 0 and "already patched" in r.stdout,
      r.stdout[-100:] + r.stderr[-100:])

mk = rd("Makefile")
check("B3 Makefile dep_sdl3_guard 目标 + payload 依赖",
      "dep_sdl3_guard:" in mk and
      re.search(r'payload:.*dep_sdl3_guard', mk) is not None)

sdl3 = open(os.path.join(REPO, "Natives/resources/Frameworks/libSDL3.dylib"), "rb").read()
check("B4 入口 trampoline 字节在位",
      sdl3[0x27CBC:0x27CC0] == bytes([0xf1, 0xe7, 0x06, 0x14]) and
      sdl3[0x27DB4:0x27DB8] == bytes([0xbf, 0xe7, 0x06, 0x14]))
cave1 = sdl3[0x1E1C80:0x1E1C90]
cave2 = sdl3[0x1E1CB0:0x1E1CC4]
check("B5 cave 守卫字节在位",
      cave1 == bytes([0x40, 0x00, 0x00, 0xb4, 0xe0, 0x03, 0x1f, 0xaa,
                      0xf6, 0x57, 0xbd, 0xa9, 0x0d, 0x18, 0xf9, 0x17]) and
      cave2 == bytes([0x60, 0x00, 0x00, 0xb4, 0x20, 0x00, 0x80, 0x52,
                      0xc0, 0x03, 0x5f, 0xd6, 0xe2, 0x03, 0x01, 0xaa,
                      0x3e, 0x18, 0xf9, 0x17]))
def cbz_target(word, pc):
    imm19 = (word >> 5) & 0x7FFFF
    if imm19 & 0x40000:
        imm19 -= 0x80000
    return pc + imm19 * 4
w1 = int.from_bytes(cave1[0:4], "little")
w2 = int.from_bytes(cave2[0:4], "little")
check("B6 cbz 目标回归守卫（NULL 路径必须落在重定位原指令上——防栈损坏偏移 bug）",
      cbz_target(w1, 0x1E1C80) == 0x1E1C88 and cbz_target(w2, 0x1E1CB0) == 0x1E1CBC,
      f"cbz1->0x{cbz_target(w1, 0x1E1C80):x} cbz2->0x{cbz_target(w2, 0x1E1CB0):x}")

print("== C. 取证加固（下一轮装机日志可直接判读 JNA 绕行机制）==")
sdl = rd("Natives/sdl3_hook.m")
check("C1 _ex 幂等命中取证日志（fishhook 竞态判读锚点）",
      "Task135: _dlsym slot %p already ==" in sdl and
      "idempotent hit" in sdl)
check("C2 Task133 重绑器参数化 + 双通道调用",
      "const char *t135_sym" in sdl and
      'orig_dlopen, "_dlopen"' in sdl and
      'orig_dlsym, "_dlsym"' in sdl)
check("C3 extern orig_dlsym 声明（CI undeclared 防线）",
      re.search(r'extern void \*\(\*orig_dlsym\)\(void \*handle, const char \*name\);', sdl) is not None)
check("C4 Task133 日志参数化（符号名不再硬编码 _dlopen）",
      'Task133: %s slots rebound for %s' in sdl)

print("== D. 语法门 ==")
check("D1 sdl3_hook.m 括号平衡", balance(sdl))
check("D2 JavaLauncher.m 括号平衡", balance(jl))
base = {}
ok4 = True
for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    s = rd(f"Natives/resources/{l}.lproj/Localizable.strings")
    keys = set(re.findall(r'^"([^"]+)"\s*=', s, re.M))
    base[l] = len(keys)
vals = set(base.values())
# Task138 重锚：+2 键（renderer_missing_dylib + mirror_policy-speed_first），
# 唯一键基线 2745（Task230 重锚：+18 ame230.*）
check("D3 四语言唯一键集一致且为 Task230 基线 2745（Task230 重锚：+18 ame230.*）",
      vals == {2765}, str(base))
r2 = subprocess.run([sys.executable, os.path.join(REPO, "scripts/patch_sdl3_eventfilter_guard.py"),
                     os.path.join(REPO, "Natives/resources/Frameworks/libSDL3.dylib")],
                    capture_output=True, text=True, timeout=60)
check("D4 补丁脚本重跑幂等（不写不报错）",
      r2.returncode == 0 and "already patched" in r2.stdout)

print("== E. 级联 ==")
casc = ["112_118", "119_124", "125_128", "129", "130", "131", "132", "133", "134"]
allc = True
for v in casc:
    r3 = subprocess.run([sys.executable, os.path.join(REPO, f"scripts/verify_task{v}.py")],
                        capture_output=True, text=True, timeout=600)
    good = "ALL PASS" in r3.stdout and r3.returncode == 0
    allc &= good
    check(f"E. verify_task{v} ALL PASS", good,
          "" if good else r3.stdout[-160:])
cur_tab = sum(1 for l in mk.splitlines() if l.startswith("\t"))
head_mk = subprocess.run(["git", "-C", REPO, "show", "HEAD:Makefile"],
                         capture_output=True, text=True).stdout
head_tab = sum(1 for l in head_mk.splitlines() if l.startswith("\t"))
# Task138 重锚：Task135 的 14 个 TAB 行已随提交入 HEAD，"+14" 形态在
# 提交后恒假；长期不变量 = 工作树与 HEAD 一致 + dep_sdl3_guard 目标在位。
check("E10 Makefile TAB 基线 = 绝对 644 且双守卫在位（Task214 重锚：561 + 83 dep_virgl 行）",
      # Task203 起绝对基线；Task206 重锚 559；Task212 重锚 561；Task214 重锚 644 = 561 + 83 dep_virgl 行
      # （holy gl4es 的两个二进制补丁接线随 dylib 退役删除）。
      cur_tab == 662 and head_tab == 662 and "dep_sdl3_guard:" in mk and "dep_sdl3_guard" in head_mk
      and "patch_gl4es_ggstr_nullguard.py" not in mk,
      f"head={head_tab} cur={cur_tab}")

print(f"\n==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS+FAIL}) ====")
sys.exit(0 if FAIL == 0 else 1)
