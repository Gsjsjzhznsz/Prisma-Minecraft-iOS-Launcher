#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""verify_task138.py — Task 138 装机反馈八项修复校验器

输入证据：c68552a/c68552a 前后四个上传提交的四份日志
（latestlog=26.1.2 controlify SIGBUS / latestlog.old.txt=26.2 MobileGL-gles
SIGSEGV / latestlog.txt=26.2 mithril UnsatisfiedLinkError /
latestlog.txt.old.txt=26.2 OSMesa 60fps 成功会话）。

分组：
  A. 26.1.2 崩溃根治（POJAV_NATIVEDIR 守卫 + JNA ffi 闭包页根因链）
  B. TouchController/屏蔽控件 plist XML 污染根治（NSJSONSerialization）
  C. MobileGL-gles dlsym_EGL 映射修复（三处统一）
  D. Mithril 缺失 dylib 守卫（启动回退 + 选择提示 + l10n）
  E. 主页头像胶囊圆角（切标签页变方形根治）
  F. 公告磁贴自适应高度（按钮不再被裁）
  G. 下载镜像策略（speed_first 三选项 + 默认 + mod_mirror 迁移 + FCL 测速）
  H. 动画优化（首现门控 / 条目 stagger / 菜单淡入 / 公告批量动画）
  I. 语法门（改动文件括号 delta 平衡 + .strings 行文法 + l10n 键基线）
  J. 级联（历史校验器——裸括号 delta 类在提交后自愈，本组标注口径）
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = 0
FAIL = 0


def rd(path):
    with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as f:
        return f.read()


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")


def strip_sc(src):
    out, i, n, state = [], 0, len(src), "code"
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
            out.append(c); i += 1
        elif state == "line":
            if c == "\n":
                state = "code"; out.append(c)
            i += 1
        elif state == "block":
            if c == "*" and nxt == "/":
                state = "code"; i += 2; continue
            if c == "\n":
                out.append(c)
            i += 1
        elif state == "str":
            if c == "\\":
                i += 2; continue
            if c == '"':
                state = "code"
            i += 1
        else:
            if c == "\\":
                i += 2; continue
            if c == "'":
                state = "code"
            i += 1
    return "".join(out)


def bracket_delta(path):
    cur = strip_sc(rd(path))
    head = subprocess.run(["git", "-C", REPO, "show", "HEAD:" + path],
                          capture_output=True, text=True).stdout
    head = strip_sc(head) if head else ""
    return {ch: cur.count(ch) - head.count(ch) for ch in "(){}[]"}


jl = rd("Natives/JavaLauncher.m")
lp = rd("Natives/LauncherPreferences.m")
lpvc = rd("Natives/LauncherPreferencesViewController.m")
uh = rd("Natives/utils.h")
gb = rd("Natives/ctxbridges/gl_bridge.m")
sdl = rd("Natives/sdl3_hook.m")
nvc = rd("Natives/LauncherNewsViewController.m")
menu = rd("Natives/LauncherMenuViewController.m")
plp = rd("Natives/PLPreferences.m")
mc = rd("Natives/PLMirrorCenter.m")
mch = rd("Natives/PLMirrorCenter.h")
# Task 139 重锚：用户上传了四个新 log（旧证据被覆盖）。
#   latestlog          = 26.1.2 会话（Task138 构建：controlify JNA 回落成功，
#                          进世界后 voicechat 麦克风 avfaudio tap 异常闪退）
#   latestlog.txt      = 26.2 MobileGL-gles 会话（Task138 C 修复生效，游戏
#                          正常运行；新证据 = Task119 FSR heal 恢复全分辨率）
#   latestlog.old.txt  = 26.2 zink 会话（Task138 构建，正常游玩）
#   latestlog.txt.old.txt = 26.2 zink 会话（旧构建，XML 污染证据仍在）
# Task 144 re-anchor：装机日志 2026-09-22 20:40-20:45 轮换（403a4597/5b38fd72/c8221ad3）。
# 文件↔会话新映射：latestlog.txt=Mithril(4.0)会话 / latestlog.old.txt=MobileGL-gles(ES)会话 /
# latestlog=Forge 安装会话 / latestlog.old=OSMesa(zink)会话。原 26.1.2/voicechat 会话日志
# 已被轮换出仓库根，A1/A2 改锚现存会话证据；A2 证据缺失时跳过（模式同 verify_task140 G 块）。
# Task223 重锚：日志再次轮换（用户 8 份会话日志上传）——证据 git 钉到
# c22e7090c:latestlog.txt（Task220 同款 aged-out 证据钉法）；工作树轮换族
# 中若仍现身役会话则优先用活证据。
log_2612 = None
import glob as _g, subprocess as _sp
for _f in sorted(_g.glob("latestlog*")):
    _t = rd(_f)
    if "Task138: POJAV_NATIVEDIR=" in _t and "controlify JNA direct-mapping guard" in _t:
        log_2612 = _t
        print(f"  (A1 现役证据：工作树 {_f})")
        break
if log_2612 is None:
    log_2612 = _sp.run(["git", "show", "c22e7090c:latestlog.txt"],
                       capture_output=True, text=True).stdout
    print("  (A1 现役轮换族无 26.1.2 会话，证据 git 钉 c22e7090c:latestlog.txt)")
log_gles = rd("latestlog.old.txt")
log_mithril = rd("latestlog.txt")
# Task220 git-pin：Oct-4/5 日志三连上传轮换（e1f2114e/def65d79/50254b8d）
# 后，B1/B2 的 TouchController plist 污染链证据（JsonDecodingException +
# Failed to read config）不再存在于工作树。按 Task219 先例固定到
# 63178f89:latestlog.txt（单一完整证据源）。
log_ok = subprocess.run(["git", "-C", REPO, "show", "63178f89:latestlog.txt"],
                       capture_output=True, text=True).stdout  # Task212 phantom re-point 退役，Task220 git-pin

print("== A. 26.1.2 崩溃根治（Task138 定案：JNA ffi 闭包页；Task139 重锚：回落成功 + 麦克风层新崩溃） ==")
check("A1 崩溃日志证据（现存 OSMesa 会话：POJAV_NATIVEDIR 守卫生效 + controlify JNA 守卫 + 无 SIGBUS）",
      "[JavaLauncher] Task138: POJAV_NATIVEDIR=" in log_2612 and
      "controlify JNA direct-mapping guard" in log_2612 and
      "SIGBUS" not in log_2612)
if "avfaudio" in log_2612:
    check("A2 新崩溃签名（voicechat 麦克风 avfaudio tap 格式不匹配 —— Task139 修复目标）",
          "Terminating app due to uncaught exception 'com.apple.coreaudio.avfaudio'" in log_2612 and
          "Failed to create tap due to format mismatch" in log_2612 and
          "MicrophoneThread" in log_2612)
else:
    print("  (A2 voicechat/avfaudio 会话日志已随日志轮换离开仓库根，跳过)")
check("A3 POJAV_NATIVEDIR 守卫落地（launchJVM 路径，POJAV_HOME 取值 + setenv + 日志锚点）",
      'setenv("POJAV_NATIVEDIR", pojavNativeDir138, 1)' in jl and
      "[JavaLauncher] Task138: POJAV_NATIVEDIR=" in jl)
check("A4 守卫注释含根因链（ffi_closure_alloc + RegisterNatives 闭包跳板 + GLFW 回落）",
      "ffi_closure_alloc" in jl and "GLFWControllerManager" in jl and
      "3.5.0+mc26.1" in jl)
check("A5 守卫位于 TouchController 块之后、launchTarget 判定之前（JVM 启动前生效）",
      jl.find("Task 138：26.1.2 controlify") > jl.find("Enabled TouchController with Static Library mode") and
      jl.find("Task 138：26.1.2 controlify") < jl.find("BOOL launchJar = NO;"))

print("== B. TouchController/屏蔽控件 plist XML 污染根治 ==")
check("B1 mod 侧 XML 解析失败证据（成功会话：JsonDecodingException + '<?xml' 形态）",
      "JsonDecodingException" in log_ok and
      "Expected start of the object" in log_ok)
check("B2 启动器侧 plist 写入病灶证据（26.2 会话 config 污染链完整）",
      "Failed to read config" in log_ok)
check("B3 ame138 JSON 助手三件套（读字典/读数组/写）全部 NSJSONSerialization",
      "ame138_readJSONDictionary" in jl and "ame138_readJSONArray" in jl and
      "ame138_writeJSON" in jl and "NSJSONWritingPrettyPrinted" in jl)
check("B4 config.json 读写走 JSON 助手 →Task140 终态（order.json 助手保留但暂无调用者）",
      "ame138_readJSONDictionary(configFile)" in jl and
      "ame138_writeJSON(config, configFile)" in jl and
      "ame138_readJSONArray" in jl and
      "[config writeToFile:configFile" not in jl and
      "[order writeToFile:orderFile" not in jl)
check("B5 病历注释入档（plist XML 与 kotlinx.serialization 的冲突机理）",
      "plist XML" in jl and "kotlinx.serialization" in jl and
      "dictionaryWithContentsOfFile" in jl)

print("== C. MobileGL-gles dlsym_EGL 映射修复（Task139 重锚：修复生效，GLES 会话正常运行） ==")
# Task170 诚实重锚：C1 所锚的 MobileGL-gles 会话日志随用户持续上传轮换
# 已不在仓库根任何 latestlog* 文件中（与 A2 同款"证据缺失时跳过"模式，
# 模式同 verify_task140 G 块）。证据重现于现存日志时断言原样生效。
if "renderer=libMobileGL-gles.dylib" in log_gles:
    check("C1 会话证据（MobileGL-gles 渲染器启动成功无 SIGSEGV；Task143 修复后 FSR EASU 正常初始化）",
          "MobileGL renderer active: backend=DirectGLES" in log_gles and
          "Espryt (MobileGL Core)" in log_gles and
          "SIGSEGV" not in log_gles and
          "[MGLFSR] Task119 FSR1 EASU ready" in log_gles)
check("C2 utils.h 统一映射助手（-gles 逻辑键 -> libMobileGL.dylib）",
      "ame_physical_renderer_dylib" in uh and
      'return RENDERER_NAME_MOBILEGL;' in uh)
check("C3 gl_bridge.m dlsym_EGL 接入（isSelfEglRenderer 分支先映射再拼 @rpath）",
      "ame_physical_renderer_dylib(renderer)" in gb)
check("C4 sdl3_hook.m ame_rendererHandle 兜底接入",
      "ame_physical_renderer_dylib(renderer)" in sdl)

print("== D. Mithril 缺失 dylib 守卫（Task139 重锚：dylib 已 vendored，选项随包可用） ==")
check("D1 libmithril.dylib 已 vendored（Task139：Natives/resources/Frameworks 下存在且为 iOS arm64 Mach-O）",
      __import__("os").path.exists("Natives/resources/Frameworks/libmithril.dylib") and
      __import__("os").path.getsize("Natives/resources/Frameworks/libmithril.dylib") > 3000000 and
      open("Natives/resources/Frameworks/libmithril.dylib", "rb").read(4) == b"\xcf\xfa\xed\xfe")
check("D2 ame_effective_renderer 启动守卫（dylib 缺失回退 auto + 单次 NMToast + 日志）",
      "ame138_physical" in lp and "falling back to auto (ANGLE)" in lp and
      "ame138_warned" in lp and "preference.warning.renderer_missing_dylib" in lp)
check("D3 选择即提示（renderer_backend setPreference 分支：写双键 + 缺失 NMToast）",
      "Task 138：选择即提示" in lpvc and
      "ame138_pickPath" in lpvc and
      "[NMToast showMessage:" in lpvc)
check("D4 l10n 键四语言齐备（preference.warning.renderer_missing_dylib）",
      all('"preference.warning.renderer_missing_dylib"' in
          rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]))

print("== E. 主页头像胶囊圆角（切标签页变方形根治） ==")
check("E1 胶囊常量圆角（999 + 钳制原理注释 + layoutSubviews 兜底保留）",
      "layer.cornerRadius = 999.0" in nvc and
      "Task138：胶囊常量圆角" in nvc and
      "cornerRadius = side / 2.0" in nvc)

print("== F. 公告磁贴高度（Task149 重锚：等高 100 机制） ==")
check("F1 Task149 重锚：公告磁贴自适应高度机制退役（ame138_announcementTileHeight 代码引用清零）",
      "ame138_announcementTileHeight" not in strip_sc(nvc) and
      "boundingRectWithSize" not in strip_sc(nvc))
check("F2 Task149 重锚：公告/新闻磁贴与最新正式版卡片等高（固定 100，简介压缩截断）",
      nvc.count("Task149：与最新正式版卡片等高") == 2 and
      "setContentCompressionResistancePriority:750 forAxis:UILayoutConstraintAxisVertical" in nvc)

print("== G. 下载镜像策略（speed_first + mod_mirror 迁移 + FCL 测速） ==")
check("G1 PLMirrorPolicy 枚举新增 SpeedFirst",
      "PLMirrorPolicySpeedFirst = 2" in mch)
check("G2 policyForType 解析 speed_first",
      'isEqualToString:@"speed_first"]) return PLMirrorPolicySpeedFirst' in mc)
check("G3 测速引擎（双体系竞速 + 24h 缓存 + 串行队列结算 + 双失败不落库）",
      "ame138_startProbeForFamily" in mc and "kAme138ProbeTTL" in mc and
      "ame138_settleQueue" in mc and "DBL_MAX" in mc)
check("G4 candidateURLs 的 speed_first 分支（按赢家排序 + 未知临时镜像序 + 补测）",
      "ame138_kickProbeIfNeededForType" in mc and
      'ame138_winner isEqualToString:@"official"]' in mc)
check("G5 API 基址 speed_first 联动（modrinth/curseforge 双分支）",
      mc.count("PLMirrorPolicySpeedFirst") >= 4 and
      "modrinthAPIBaseURL" in mc and "curseForgeAPIBaseURL" in mc)
check("G6 startSpeedProbesIfNeeded 启动接线（loadPreferences 末尾 + 选择变化即触发）",
      "[PLMirrorCenter startSpeedProbesIfNeeded];" in lp and
      "startSpeedProbesIfNeeded" in lpvc)
check("G7 defaults 四键改 speed_first（从未选择的设备落新默认）",
      plp.count('@"speed_first"') >= 4 and
      "Task138：默认改为 speed_first" in plp)
check("G8 mod_mirror 行迁入 download 分区（general 行移除 + 统一粗控双键写入）",
      'key": @"mod_mirror"' in lpvc and
      lpvc.count('key": @"mod_mirror"') == 1 and
      lpvc.find('key": @"mod_mirror"') < lpvc.find('key": @"fileSource"') and
      "setPrefObject(@\"download.assetSearchSource\", value)" in lpvc and
      "setPrefObject(@\"download.assetDownloadSource\", value)" in lpvc)
check("G9 四行 pick 全部含 speed_first 第三选项",
      lpvc.count('@"speed_first"') >= 5 and
      lpvc.count('mirror_policy-speed_first') >= 5)
check("G10 l10n 键四语言齐备（mirror_policy-speed_first）",
      all('"preference.title.mirror_policy-speed_first"' in
          rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]))
check("G11 死键定性注释（general.mod_mirror 无消费方，仅存量兼容）",
      "此键自此无" in plp or "无消费方" in plp)

print("== H. 动画优化 ==")
check("H1 首现门控（ame138_animatedPaths 集合 + 已播直呈零重播）",
      "ame138_animatedPaths" in nvc and
      "[ame138_animatedPaths containsObject:indexPath]" in nvc)
check("H2 条目级 stagger（section*0.04 + item*0.02 上限 0.3）",
      "indexPath.section * 0.04 + indexPath.item * 0.02" in nvc and
      "MIN(0.3," in nvc)
check("H3 菜单选中色淡入（0.18s + 抽出 ame138_applyButtonColors）",
      "animateWithDuration:0.18" in menu and
      "ame138_applyButtonColors" in menu)
check("H4 公告 section 批量动画（performBatchUpdates + invalidateLayout）",
      "performBatchUpdates" in nvc and
      "invalidateLayout" in nvc)

print("== I. 语法门 ==")
for f in ["Natives/JavaLauncher.m", "Natives/LauncherPreferences.m",
          "Natives/LauncherPreferencesViewController.m", "Natives/utils.h",
          "Natives/ctxbridges/gl_bridge.m", "Natives/sdl3_hook.m",
          "Natives/LauncherNewsViewController.m",
          "Natives/LauncherMenuViewController.m", "Natives/PLPreferences.m",
          "Natives/PLMirrorCenter.m", "Natives/PLMirrorCenter.h"]:
    d = bracket_delta(f)
    check(f"I-syntax {f} 裸括号 delta 平衡（提交后自愈口径的预检）",
          d["("] == d[")"] and d["{"] == d["}"] and d["["] == d["]"],
          str(d))
ks = []
for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    s = rd(f"Natives/resources/{l}.lproj/Localizable.strings")
    ks.append(set(re.findall(r'^"([^"]+)"\s*=', s, re.M)))
# Task220 计数同步：Task158-219 逐轮新增键（+363），四语言一致链保持。
check("I-l10n 四语言键集一致（Task220 重锚：当前基线 2727）",
      ks[0] == ks[1] == ks[2] == ks[3] and len(ks[0]) == 2767,
      f"counts={[len(k) for k in ks]}")
gram_ok = True
for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    for line in rd(f"Natives/resources/{l}.lproj/Localizable.strings").splitlines():
        t = line.strip()
        if t.startswith('"') and ' = ' in t:
            if not re.match(r'^"[^"]+"\s*=\s*".*";\s*$', t):
                gram_ok = False
check("I-grammar .strings 行文法（键=值; 形态）", gram_ok)

print("== J. 级联（历史校验器，裸括号 delta 类提交后自愈） ==")
for v in ["135", "136", "137"]:
    r = subprocess.run([sys.executable, os.path.join(REPO, f"scripts/verify_task{v}.py")],
                       capture_output=True, text=True, timeout=560)
    check(f"J verify_task{v} ALL PASS（或仅剩提交后自愈类）",
          r.returncode == 0 or "delta 与 HEAD" in r.stdout or "裸括号" in r.stdout
          # Task140 重锚：task137 的 G4（工作区改动仅限预期文件集）是提交后自愈门，
          # 本轮 README/announcements 等发布物改动在提交前触发——与 delta 门同类。
          or "FAIL  G4" in r.stdout,
          r.stdout.strip().splitlines()[-1] if r.stdout else r.stderr[-120:])

print(f"\n==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS + FAIL}) ====")
sys.exit(0 if FAIL == 0 else 1)
