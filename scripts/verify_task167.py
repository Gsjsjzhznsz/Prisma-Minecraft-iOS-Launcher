#!/usr/bin/env python3
"""verify_task167 -- 上一版（Task166 IPA）两处修复装机失效的双根因修复验证。

装机输入（git 钉住 1b76d19，防工作树漂移）：
  latestlog.old.txt = Vulkan 会话：MGLFSR engaged 后首个 DSA
      glBlitNamedFramebuffer 走 SwapchainObject::GetImage -> SIGSEGV
      （pc = GetImage+0x28，反汇编 = ldr x0,[x0] 读 m_images[index]）；
      swapOK=0（首帧未呈现即崩）。
  latestlog.txt     = GLES 会话：enable_ext_direct_state_access 仍读 1
      （Task129d 时代 @YES 默认经 defaults 合并被持久化，压制 Task166
      新默认 @NO）、"ARB_direct_state_access detected, enabling DSA"、
      render-texture probe 00000000、且无任何 Task166 迁移日志
      （迁移挂在 configurationForConnectingSceneSession: —— UIKit 只为
      新建场景会话调它，既有会话设备永不执行；60+ 份历史上传日志中
      该回调内任何日志零出现）。

A. 装机日志法证（git 钉 1b76d19 双会话）
B. Vulkan 崩溃根因修复（Layer B bounds + contentsScale 三写入点）
C. DSA 迁移常跑化（main.m 调用点 / AppDelegate 保留 / ame166 强化）
D. 行为镜像（尺寸真源一致性 / 迁移幂等 / 崩溃链完整闭合）
E. 文档（version.h / announcements / 重锚）
F. 语法门 + 级联（166/130/165）
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


def git_show(ref, path):
    r = subprocess.run(["git", "-C", REPO, "show", f"{ref}:{path}"],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")


mm = rd("Natives/ctxbridges/mgl_metal_fsr.mm")
mn = rd("Natives/main.m")
ad = rd("Natives/AppDelegate.m")
lp = rd("Natives/LauncherPreferences.m")
lph = rd("Natives/LauncherPreferences.h")
ver = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")

print("== A. 装机日志法证（git 钉 1b76d19）==")
vk = git_show("1b76d19", "latestlog.old.txt")
gl = git_show("1b76d19", "latestlog.txt")
check("A1 Vulkan 会话：MGLFSR engaged + GetImage 崩溃帧 + abort 三件套",
      "[MGLFSR] Task166 Metal FSR engaged" in vk
      and "SwapchainObject::GetImage(unsigned int) const+0x28" in vk
      and "abort() called" in vk)
check("A2 Vulkan 会话：崩溃先于首帧（无 first-frame 锚 + swapOK=0 快照）",
      "first frame presented" not in vk
      and "exit(0) snapshot: swapOK=0 swapFail=0" in vk)
check("A3 Vulkan 会话：崩溃由 DSA blit 路径触发（glBlitNamedFramebuffer 栈 + OpenGL 4.5 DSA 启用行）",
      "glBlitNamedFramebuffer" in vk
      and "OpenGL 4.5 detected, enabling DSA" in vk
      and "BlitNamedFramebuffer" in vk)
check("A4 GLES 会话：DSA 仍 =1（读行 + config.json 1 + MC 启用行）",
      "mobileglues.enable_ext_direct_state_access = 1 -> enableExtDirectStateAccess = 1" in gl
      and '"enableExtDirectStateAccess" : 1' in gl
      and "ARB_direct_state_access detected, enabling DSA" in gl)
check("A5 GLES 会话：迁移从未执行（无 Task166/167 迁移日志）+ 黑屏签名（probe 全零）",
      "Task166 migrated MG DSA" not in gl
      and "migration ran" not in gl
      and "rgba=00000000" in gl)
check("A6 双会话构建归属（ff5003f = Task166 CI 闭合作）",
      "Commit: ff5003f" in vk and "Commit: ff5003f" in gl)

print("== B. Vulkan 崩溃根因修复（Layer B 几何三写入点）==")
check("B1 新建点：drawableSize + bounds + contentsScale 成对（Task167 注释在场）",
      "layerB.drawableSize = CGSizeMake(renderW, renderH);" in mm
      and "layerB.bounds = CGRectMake(0.0, 0.0, renderW, renderH);" in mm
      and "layerB.contentsScale = 1.0;" in mm
      and "MoltenVK currentExtent 真源 = bounds × contentsScale" in mm)
check("B2 已存在同步点：bounds 与 drawableSize 成对",
      "s_ame166_layerB.drawableSize = CGSizeMake(renderW, renderH);\n            s_ame166_layerB.bounds = CGRectMake(0.0, 0.0, renderW, renderH);" in mm)
check("B3 update_size 钩子：bounds 与 drawableSize 成对",
      "s_ame166_layerB.drawableSize = CGSizeMake(renderW, renderH);\n        // Task 167：bounds 成对同步（currentExtent 真源，见类注释）。\n        s_ame166_layerB.bounds = CGRectMake(0.0, 0.0, renderW, renderH);" in mm)
check("B4 三写入点全覆盖（bounds 写入恰好 3 处，drawableSize 仍 3 处）",
      mm.count(".bounds = CGRectMake(0.0, 0.0, renderW, renderH)") == 3
      and mm.count("drawableSize = CGSizeMake(renderW, renderH)") == 3)
check("B5 类注释承载完整崩溃链（naturalDrawableSizeMVK -> zero-area -> 空向量 -> GetImage+0x28 SIGSEGV）",
      "naturalDrawableSizeMVK = bounds ×" in mm
      and "zero-area 守卫" in mm
      and "m_images 空" in mm
      and "GetImage(0)" in mm
      and "GetImage+0x28 的 ldr x0,[x0]" in mm
      and "反汇编逐字节比对吻合" in mm)

print("== C. DSA 迁移常跑化 ==")
check("C1 main.m 常跑调用点（toggleIsolatedPref 之后、PLProfiles 之前）",
      re.search(r"toggleIsolatedPref\(NO\);.*?ame130_migrateMgPerfDefaults\(\);.*?\[PLProfiles updateCurrent\];",
                mn, re.S) is not None)
check("C2 main.m 注释承载失效根因（回调只为新建会话触发 + 60+ 日志零出现 + 装机锚点）",
      "configurationForConnectingSceneSession" in mn
      and "60+ 份历史上传日志零出现" in mn
      and "Task167 MG DSA black-screen migration ran" in mn)
check("C3 AppDelegate 调用保留（verify_task130 E11 共存）+ Task167 修订注释",
      "ame130_migrateMgPerfDefaults();" in ad
      and "Task 167 修订" in ad
      and "常跑调用点已搬到 main.m" in ad)
check("C4 ame166 双类型容错（NSNumber boolValue + NSString intValue）",
      "dsaOn = [(NSNumber *)dsa boolValue];" in lp
      and "dsaOn = ([(NSString *)dsa intValue] != 0);" in lp)
check("C5 无条件运行锚点日志（装机验证迁移真正执行过）",
      '[Preferences] Task167 MG DSA black-screen migration ran (stored=%@, flipped=%d)' in lp)
check("C6 哨兵语义不变（已迁移即返回 + 哨兵写入收尾）",
      'task166_dsa_blackscreen_migrated") boolValue]' in lp
      and 'setPrefObject(@"mobileglues.task166_dsa_blackscreen_migrated", @YES);' in lp)
check("C7 声明未动（.h 双锚：ame130 + ame166）",
      "void ame130_migrateMgPerfDefaults(void);" in lph
      and "void ame166_migrateMgDsaBlackScreen(void);" in lph)
check("C8 LauncherPreferences.m 内 ame166 接线仍为 2 处（ame130 两分支）",
      lp.count("ame166_migrateMgDsaBlackScreen();") == 2)

print("== D. 行为镜像 ==")
check("D1 尺寸真源一致性：bounds=render、contentsScale=1.0 -> natural==drawable==swapchain extent"
      "（hasOptimalSurface 不触发 SUBOPTIMAL churn；注释锚）",
      "contentsScale 钉 1.0" in mm)
check("D2 迁移幂等镜像：main.m 与 AppDelegate 双调用点 -> 哨兵一次性（注释锚 + 两调用点计数）",
      "哨兵保证" in mn and "幂等" in ad
      and mn.count("ame130_migrateMgPerfDefaults();") == 1
      and ad.count("ame130_migrateMgPerfDefaults();") == 1)
check("D3 Task166 降级面零回归（kill switch / 回退日志 / 环形池锚仍在）",
      'getenv("AME166_MGL_METAL_FSR")' in mm
      and "Task166 fallback: no MTLDevice" in mm
      and "static const int kAme166RingSlots = 8;" in mm
      and "layerB.maximumDrawableCount = 3;" in mm)
check("D4 存量 1 持久化机理入档（defaults 合并写盘 + 压制新默认；注释锚）",
      "defaults 合并在每次启动时被写进 plist" in lp
      and "存量 1 压制 Task166 新默认 @NO" in lp)

print("== E. 文档 ==")
import json
anns = json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))["announcements"]
a167 = [a for a in anns if a.get("id") == "task167-crashfix-migration-2026-09-25"]
# Task169 重锚：用户点名服务器推荐置顶（pin 字段，anns[0]）+ task169 公告
# 与 v6.0.0 发行文案改写插入——task167 现居 unpinned 组首位（数组第 4：
# server(pin) / task169 / v6.0.0 / task167）。置顶断言改为"2026-09-25 同日
# 组内、task166/task165/task164 之前"。
check("E1 task167 公告置顶（Task214 重锚：task214@2 插入后居 index 26；双根因 + 装机验证清单）",
      len(a167) == 1
      and any(anns[i]["id"] == "task167-crashfix-migration-2026-09-25" for i in range(min(28, len(anns))))
      and all(anns.index(a167[0]) < anns.index(x) for x in anns
              if x.get("id") in ("task166-vulkan-fsr-dsa-2026-09-25",
                                 "task165-blackscreen-rootcause-2026-09-25",
                                 "task164-fsr-blackscreen-defaults-2026-09-25"))
      and "Vulkan 崩溃" in a167[0]["title"] and "黑屏" in a167[0]["title"]
      and "migration ran (stored=1, flipped=1)" in a167[0]["content"])
check("E2 task166 公告诚实补记（勘误 + 指向 Task167）",
      any("勘误（装机实测后补记）" in a.get("content", "") and "Task 167" in a.get("content", "")
          for a in anns if a.get("id") == "task166-vulkan-fsr-dsa-2026-09-25"))
check("E3 version.h Task 167 addendum（双根因 + 反汇编吻合 + 重锚记录）",
      "Task 167 (REVISION 17 addendum" in ver
      and "naturalDrawableSizeMVK" in ver
      and "GetImage+0x28" in ver
      and "configurationForConnectingSceneSession" in ver
      and "verify_task130 E10" in ver)
v166 = rd("scripts/verify_task166.py")
v130 = rd("scripts/verify_task130.py")
check("E4 重锚就位（task166 C2 + task130 E10 的 Task167 形态）",
      "Task167 重锚" in v166 and "dsaOn = [(NSNumber *)dsa boolValue];" in v166
      and "Task167 重锚" in v130 and "dsaOn = ([(NSString *)dsa intValue] != 0);" in v130)

print("== F. 语法门 + 级联 ==")
def balanced(path):
    # Task223 再锚：旧 stripper 先剥注释再剥字符串——字符串里的 URL（含 //）
    # 会被行注释规则截断（Task223 的 Prisma 横幅三行 NSLog 暴露：HEAD 恰好
    # 事故性配平，加一行后 net +1 误报）。换成 verify_task223 O 门的 house
    # 状态机（code/lc/bc/st/ch 五态单遍扫描，字符字面量与转义正确处理）。
    src = rd(path)
    out, state, i = [], "code", 0
    n = len(src)
    while i < n:
        c, nxt = src[i], (src[i+1] if i+1 < n else "")
        if state == "code":
            if c == "/" and nxt == "/": state = "lc"; i += 2; continue
            if c == "/" and nxt == "*": state = "bc"; i += 2; continue
            if c == '"': state = "st"
            elif c == "'": state = "ch"
            out.append(c)
        elif state == "lc":
            if c == "\n": state = "code"; out.append(c)
        elif state == "bc":
            if c == "*" and nxt == "/": state = "code"; i += 2; continue
        elif state == "st":
            if c == "\\": i += 2; continue
            if c == '"': state = "code"
        elif state == "ch":
            if c == "\\": i += 2; continue
            if c == "'": state = "code"
        i += 1
    s = "".join(out)
    return s.count("{") == s.count("}") and s.count("(") == s.count(")")

check("F1 编辑文件括号平衡（mgl_metal_fsr.mm / LauncherPreferences.m / main.m / AppDelegate.m）",
      all(balanced(p) for p in [
          "Natives/ctxbridges/mgl_metal_fsr.mm",
          "Natives/LauncherPreferences.m",
          "Natives/main.m",
          "Natives/AppDelegate.m"]))

for tid, script in (("F2 verify_task166 级联（C2 重锚后全绿）", "verify_task166.py"),
                    ("F4 verify_task165 级联（G1 置顶区重锚后全绿）", "verify_task165.py")):
    r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", script)],
                       capture_output=True, text=True, timeout=600)
    m = re.search(r"==== RESULT: (ALL PASS|FAILED) \((\d+)/(\d+)\) ====", r.stdout)
    m2 = re.search(r"==== Task165: (\d+)/(\d+) ====", r.stdout)
    ok = r.returncode == 0 and (
        (m and m.group(1) == "ALL PASS" and m.group(2) == m.group(3))
        or (m2 and m2.group(1) == m2.group(2)))
    check(tid, ok, (r.stdout[-200:] + r.stderr[-200:]) if not ok else "")

# F3（基线容忍）：verify_task130 的 D4（FSR1.cpp 锚，Task164/165 改动面）+
# I1（l10n E5/E6 基线失败的级联传播）为 stash 实证的既有环境基线（干净 HEAD
# 同样 47/49 + 嵌套 44/47 + 58/60，本轮工作树已复核一致）；本轮要求 = 分数与
# 失败集合与基线完全相同（零新增失败）。
r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", "verify_task130.py")],
                   capture_output=True, text=True, timeout=600)
# Task173 口径修订（家法 = 零新增失败，分数无关化）：130 的既有环境基线 =
# {D4 ApplyFSR（FSR1.cpp 锚，Task164/165 改动面，stash 实证）,
#  I1 verify_task129（深子级联 112_118/119_124/125_128 的会话本地审计助手
# 依赖，112_118 E5/E6 已证据条件化后 I1 可自愈）}。当前失败 ⊆ 基线集合
# 即通过；出现集合外失败 = 新增失败，FAIL。
fails130 = [l.strip() for l in r.stdout.splitlines() if l.strip().startswith("FAIL ")]
BASELINE130 = ("D4 ApplyFSR", "I1 verify_task129")
unexpected130 = [f for f in fails130 if not any(b in f for b in BASELINE130)]
baseline_ok = (not unexpected130)
check("F3 verify_task130 级联（D4+I1 = stash 实证既有基线，零新增失败）", baseline_ok,
      "; ".join(fails130) if not baseline_ok else "")

print()
print(f"==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS + FAIL}) ====")
sys.exit(0 if FAIL == 0 else 1)
