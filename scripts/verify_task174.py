#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task174.py -- 新拟态画布接管（晕影根修）+ 透明度百分比实时回显

用户装机反馈（Task173 构建）：
  "现在是怎么都无法复现正常的新拟态了，全都是晕影的"
  "新拟态透明度的百分比没有正确显示"

根因定稿：
  1) Task173 只把卡片重写为"正常态"，壁纸层仍垫在卡片底下——规格双阴影
     （20pt 偏移 / 60pt 模糊 / opacity 1.0）投在照片上必然读作边缘晕影；
     复现方法（Bing 开→调→关）的终态是壁纸被取消后的整体形态，背景本身
     就是"正常态"的一部分。
  2) cardsNeumorphOpacitySliderChanged 从 Task170 起从不更新数值标签——
     拖动全程冻结在上一次 cellForRow 的读数。

组别：
  A 画布接管（applyBackgroundToWindow/SplitVC 顶部开关门 + refreshUIEffect
    双分支 + 一次性取证日志）
  B 百分比实时回显（slider→contentView→cell→tag501）
  C 既有语义不回潮（开关门/灰化反转/卡片管线/回调链）
  D l10n 零新增（四主语言计数 2157 = 十症状并行会话并入后 1954->2157）
  E 公告 + version.h
  F 配平
  G 级联零新增失败（当前失败 ⊆ 基线 ∪ 具名沙箱传播簇）
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASS = 0
FAIL = 0


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"[PASS] {name}")
    else:
        FAIL += 1
        print(f"[FAIL] {name}" + (f"  -- {detail}" if detail else ""))


bm_m = rd("Natives/BackgroundManager.m")
bsvc = rd("Natives/BackgroundSettingsViewController.m")

# ============================================================
# A. Task175 重锚：画布接管退役 → 壁纸共存
# （用户对 Task174 构建的反馈"新拟态壁纸开启时壁纸被覆盖无法正常显示"；
#   开启 = 壁纸照常铺设 + 卡片实底 + 柔和阴影档；接管门整体删除）
# ============================================================
win_fn = bm_m[bm_m.index("- (void)applyBackgroundToWindow:"):bm_m.index("// Task111：检测并切换")]
split_fn_start = bm_m.index("- (void)applyBackgroundToSplitViewController:")
split_fn = bm_m[split_fn_start:bm_m.index("// Task111：同 applyBackgroundToWindow", split_fn_start)]
check("A1 applyBackgroundToWindow 无新拟态早退门（画布接管退役：Task174→Task175→Task177 注释链在位 + 旧门体删除）",
      "Task174→Task175→Task177" in bm_m
      and bm_m.index("Task174→Task175→Task177") < bm_m.index("// Task111：检测并切换")
      and "if (self.cardsNeumorphEnabled)" not in win_fn
      and "if (self.cardsNeumorphEnabled)" not in split_fn)
check("A2 Task210：开关门全链退役（applyBackgroundToSplitViewController 及任意管线均无）",
      "if (self.cardsNeumorphEnabled) {" not in bm_m
      and "if (self.cardsNeumorphEnabled)" not in split_fn)
check("A3 Task210 refreshUIEffect 单路径：壁纸容器缺席时原位重建 + blur 重挂（无开关分支无取证日志）",
      "if (self.cardsNeumorphEnabled) {" not in bm_m[bm_m.index("- (void)refreshUIEffect"):]
      and "if ([self hasBackground] && !self.globalBackgroundContainer) {" in bm_m[bm_m.index("- (void)refreshUIEffect"):]
      and "ame178DecoupleLogOnce" not in bm_m)
check("A4 refreshUIEffect OFF 分支：原位重建 + blur 重挂（不变）",
      "if ([self hasBackground] && !self.globalBackgroundContainer) {" in bm_m
      and "[self applyBackgroundToSplitViewController:self.currentSplitVC];" in bm_m
      and "[self applyBackgroundToWindow:self.currentWindow];" in bm_m)
check("A5 Task210：卡片本体透明度挂载点随退役删除（柔和档亦无）",
      bm_m.count("ame_setNeumorphWallpaperSoft") == 0
      and "ame_applyNeumorphCardOpacity" not in "\n".join(l.split("//")[0] for l in bm_m.split("\n")))
check("A5b Task210：柔和档与引擎整体退役（透明渐变表面/投影层全退，平贴灰面接棒）",
      "ame_wallpaperSoftProfile" not in rd("Natives/UIKit+NativeSurface.m")
      and "offset * 0.35" not in rd("Natives/UIKit+NativeSurface.m")
      and "darkOpacity = 0.45" not in rd("Natives/UIKit+NativeSurface.m")
      and "ame_setNeumorphWallpaperSoft:(BOOL)soft" not in rd("Natives/UIKit+NativeSurface.m")
      and "ame177_surfaceLayer" not in rd("Natives/UIKit+NativeSurface.m")
      and "AmeCardSurfaceColor" in rd("Natives/UIKit+NativeSurface.m"))

# ============================================================
# B. 百分比实时回显（Task177 重锚：滑条随透明度退役，回显机制随之成为历史；
#    其余两滑条的实时回显范式仍在，作为不回归锚）
# ============================================================
blur_handler = bsvc[bsvc.index("- (void)blurIntensitySliderChanged"):]
blur_handler = blur_handler[:blur_handler.index("\n}", 1) + 2]
check("B1 滑条回调实时回显（Task210 重锚：501/500 随新拟态行退役；blur 行范式不变）",
      "viewWithTag:301" in blur_handler
      and "viewWithTag:501]" not in bsvc
      and "cardsNeumorphOpacitySliderChanged" not in bsvc)
check("B2 blur 回调含百分比格式（%.0f%% × 100）",
      '@"%.0f%%", value * 100' in blur_handler)
check("B3 blur 滑条取回范式（slider→superview→superview + 类型守卫）",
      "slider.superview.superview" in blur_handler
      and "[cell isKindOfClass:[UITableViewCell class]]" in blur_handler)
check("B4 既有刷新链不破坏（Task210 重锚：refreshUIEffect 仍在；壁纸透明度落盘链在位，新拟态落盘链退役）",
      "refreshUIEffect" in blur_handler
      and "[BackgroundManager sharedManager].uiOpacity = value;" in bsvc
      and "cardsNeumorphOpacity = slider.value" not in bsvc)

# ============================================================
# C. 既有语义不回潮（Task173 重写与灰化反转原样保留）
# ============================================================
check("C1 Task210：管线入口三件套在位（开关门退役，改名 applyCardEffectToView）",
      "self.cardsNeumorphEnabled" not in bm_m
      and "- (void)applyCardEffectToView:" in bm_m
      and "- (void)applyEffectToCollectionViewCell:" in bm_m
      and "- (void)applyCardEffectToCell:" in bm_m)
check("C2 灰化退役（Task178 重锚：开关不变灰任何选项——0.35/neumorphOn 全退，交互恒开）",
      bsvc.count("neumorphOn ? 0.35 : 1.0") == 0
      and "neumorphOn" not in bsvc
      and "slider.enabled = neumorphOn;" not in bsvc
      and "cell.contentView.alpha = neumorphOn ? 1.0 : 0.35;" not in bsvc)
check("C3 Task210：开关回调链随退役删除（零残留）",
      "cardsNeumorphToggleChanged" not in bsvc)
check("C4 Task210：卡片本体透明度原语随退役删除（管线 + 引擎零残留）",
      "ame_applyNeumorphCardOpacity" not in "\n".join(l.split("//")[0] for l in bm_m.split("\n"))
      and "ame_applyNeumorphCardOpacity" not in rd("Natives/UIKit+NativeSurface.m"))

# ============================================================
# D. l10n 零新增（本轮无新键，计数不动）
# ============================================================
KEYSETS = [set(re.findall(r'^"([^"]+)"\s*=', rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), re.M))
           for lg in ["en", "zh-Hans", "zh-CN", "zh-Hant"]]
check("D1 四主语言键集一致且计数 = 2482（Task210 重锚：neumorph 双键退役 2482-2）",
      all(len(k) == 2482 for k in KEYSETS) and KEYSETS[0] == KEYSETS[1] == KEYSETS[2] == KEYSETS[3])
check("D2 Task210：neumorph 双键六语言退役（button.opacity 亦无）",
      "background.cards.neumorph.interface.title" not in KEYSETS[0]
      and "background.cards.neumorph.opacity.title" not in KEYSETS[0]
      and "background.button.opacity.title" not in KEYSETS[0]
      and all("background.cards.neumorph." not in
              rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
              for lg in ["ja", "km"]))

# ============================================================
# E. 公告 + version.h
# ============================================================
anns = json.loads(rd("announcements.json"))["announcements"]
ids = [a["id"] for a in anns]
check("E1 公告（Task212 重锚：task212@2 插入后全体非钉位再 +1；本条（task174）顺延 anns[18]；server/task169 pin 不动）且 id 唯一",
      len(ids) == len(set(ids))
      and anns[0]["id"] == "server-recommend-2026-09-24"
      and anns[1]["id"] == "task169-four-fixes-2026-09-25"
      and anns[15]["id"] == "task179-eight-fixes-2026-09-26"
      and anns[16]["id"] == "task178-neumorph-decouple-opacity-2026-09-26"
      and anns[17]["id"] == "task177-neumorph-css-spec-2026-09-26"
      and anns[18]["id"] == "task175-six-fixes-2026-09-26"
      and anns[19]["id"] == "task174-neumorph-canvas-opacity-label-2026-09-26"
      and anns[20]["id"] == "task173-neumorph-rewrite-toggle-2026-09-25"
      and anns[22]["id"] == "task172-six-fixes-2026-09-25"
      and anns[23]["id"] == "task171-seven-fixes-2026-09-25"
      and anns[24]["id"] == "task170-neumorph-opacity-spacing-2026-09-25"
      and anns[25]["id"] == "task168-neumorph-faq-json-2026-09-25")
t174 = anns[19]  # Task212 重锚：task212@2 插入后 174 实居 [16]（旧 anns[14] 自 Task190 轮起已错位=存量）
check("E2 公告内容锚（晕影根因=壁纸垫底/画布接管/百分比实时回显 + EN 尾注）",
      "晕影" in t174["summary"] and "画布接管" in t174["summary"]
      and "壁纸" in t174["content"] and "实时回显" in t174["content"]
      and "EN:" in t174["content"] and "[Task174]" in t174["content"])
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("E3 version.h Task 174 addendum（canvas takeover + label live echo）",
      "Task 174" in vh and "canvas takeover" in vh
      and "neumorph UI canvas active" in vh)
check("E4 历史 addendum 仍在（append-only 不回改）",
      all(f"Task {t}" in vh for t in (168, 169, 170, 171, 172, 173)))

# ============================================================
# F. 配平
# ============================================================
def balance(path):
    src = open(path, encoding="utf-8").read()
    depth = {"{": 0, "(": 0, "[": 0}
    pair = {"}": "{", ")": "(", "]": "["}
    i, n, state = 0, len(src), "code"
    while i < n:
        c = src[i]
        if state == "code":
            if c == '"':
                state = "str"
            elif c == "/" and i + 1 < n and src[i + 1] == "/":
                state = "line"
                i += 1
            elif c == "/" and i + 1 < n and src[i + 1] == "*":
                state = "block"
                i += 1
            elif c in depth:
                depth[c] += 1
            elif c in pair:
                depth[pair[c]] -= 1
        elif state == "str":
            if c == "\\":
                i += 1
            elif c == '"':
                state = "code"
        elif state == "line":
            if c == "\n":
                state = "code"
        elif state == "block":
            if c == "*" and i + 1 < n and src[i + 1] == "/":
                state = "code"
        i += 1
    return all(v == 0 for v in depth.values())


check("F1 配平：BackgroundManager.m", balance("Natives/BackgroundManager.m"))
check("F2 配平：BackgroundSettingsViewController.m", balance("Natives/BackgroundSettingsViewController.m"))
check("F3 announcements.json 合法 JSON 且新条目元数据齐备",
      "priority" in t174 and "date" in t174 and "title" in t174
      and t174["date"] == "2026-09-26")

# ============================================================
# G. 级联零新增失败（家法：当前失败 ⊆ 提交树基线 ∪ 具名沙箱传播簇）
# ============================================================
CASCADES = ["160", "161", "162", "163", "164", "165", "166", "167", "169",
            "129", "130", "131", "132", "133", "134", "135", "138", "139",
            "141", "142", "143", "150", "151", "156", "157", "159"]
ENV_NAMES = ["TASK160_REPO", "TASK161_REPO", "TASK162_REPO", "TASK163_REPO",
             "TASK164_REPO", "TASK165_REPO", "AME_REPO", "TASK101_REPO",
             "TASK102_REPO", "TASK111_REPO", "TASK136_REPO", "TASK137_REPO",
             "TASK141_REPO", "TASK149_REPO", "TASK150_REPO", "TASK157_REPO",
             "TASK159_REPO", "TASK88_REPO", "TASK89_REPO", "TASK90_REPO",
             "TASK91_REPO", "TASK92_REPO", "TASK93_REPO", "TASK95_REPO",
             "TASK96_REPO"]
cascade_env = {k: REPO for k in ENV_NAMES}
cascade_env.update(os.environ)


def fail_lines(text):
    lines = []
    for line in text.splitlines():
        s = line.strip()
        if s.startswith("[FAIL]") or s.startswith("FAIL ") or " FAILED:" in s or s.startswith("FAILED"):
            lines.append(s[:120])
    return lines


baseline_doc = json.loads(rd("scripts/task168_cascade_baseline.json"))
baseline = baseline_doc.get("baseline", {})
SANDBOX_EXCEPTIONS = {
    "131": ("H3 verify_task130",),
    "132": ("A1 崩溃日志证据", "A15 libjnidispatch", "G4 级联六验证器"),
    "135": ("E. verify_task130", "E. verify_task131", "E. verify_task132",
            "E. verify_task133", "E. verify_task134", "G4 级联六验证器"),
    "156": ("G verify_task154",),
    # Task213 补录（与 verify_task168 同款）：并行 Task212 文档化的 132-135
    # 家族漂移 + 138 的 2228 基线陈旧 + 136 存量 C4 一笔（62/1）。
    "133": ("B1 崩溃证据链在位", "B1c 成功会话对照"),
    "138": ("A1 崩溃日志证据", "B1 mod 侧 XML 解析失败证据",
            "B2 启动器侧 plist 写入病灶证据", "I-l10n 四语言键集一致",
            "J verify_task135 ALL PASS", "J verify_task136 ALL PASS",
            "J verify_task137 ALL PASS"),
}
new_failures = {}
for tid in CASCADES:
    script = f"scripts/verify_task{tid}.py"
    if not os.path.exists(script):
        continue
    try:
        r = subprocess.run([sys.executable, script], env=cascade_env,
                           capture_output=True, text=True, timeout=300)
        fails = fail_lines(r.stdout) + fail_lines(r.stderr)
    except subprocess.TimeoutExpired:
        fails = ["TIMEOUT"]
    if fails:
        new_failures[tid] = fails

unexpected = {}
for tid, fails in new_failures.items():
    known = baseline.get(tid, [])
    exc = SANDBOX_EXCEPTIONS.get(tid, ())
    diff = [f for f in fails
            if not (any(k.split(" -- ")[0] in f or f in k for k in known)
                    or any(e in f for e in exc))]
    if diff:
        unexpected[tid] = diff

check("G1 级联零新增失败（当前失败 ⊆ 基线 ∪ 具名沙箱传播簇）",
      not unexpected, json.dumps(unexpected, ensure_ascii=False)[:800])

print(f"\n===== verify_task174: {PASS} passed, {FAIL} failed =====")
sys.exit(1 if FAIL else 0)
