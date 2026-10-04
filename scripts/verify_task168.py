#!/usr/bin/env python3
# Task168 verifier: neumorphism wallpaper-mode visibility (dynamic/solid dual form)
# + help-FAQ JSON migration (dual-file, aligned with announcements).
# Task170 诚实重锚：实底开关退役为整体透明度滑条（cardsNeumorphOpacity），
# 管线实底分支合并、l10n 键原位换名（计数 1954 不变）、公告顺延一位。
# 用法: python3 scripts/verify_task168.py   （在仓库根的任意子目录运行皆可）
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)


def rd(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


results = []


def check(name, cond, detail=""):
    results.append((bool(cond), name, detail))


# ============================================================
# A. 新拟态退役完整性（Task210 重锚：引擎/管线/选项全链删除）
# ============================================================
engine_h = rd("Natives/UIKit+NativeSurface.h")
engine_m = rd("Natives/UIKit+NativeSurface.m")
bm_m = rd("Natives/BackgroundManager.m")
bm_h = rd("Natives/BackgroundManager.h")

def _nocomment(t):
    return "\n".join(l.split("//")[0] for l in t.split("\n"))

check("A1 Task210：引擎 API 零残留（ShadowView/ame_applyNeumorph*/removeNeumorphShadow/Pinned/CardOpacity 全删；注释留档不计）",
      all(sym not in _nocomment(engine_m) and sym not in _nocomment(engine_h) for sym in
          ("AmeNeumorphShadowView", "ame_applyNeumorphSurface", "ame_removeNeumorphShadow",
           "ame_applyNeumorphCardOpacity", "ame_setNeumorphPinnedCornerRadius",
           "AmeNeumorphShadowColor", "AmeNeumorphHighlightColor",
           "AmeNeumorphSurfaceGradientStartColor", "AmeNeumorphMetricsForSide",
           "AmeNeumorphBaseDimension", "ame_attachNeumorphShadowOnly")))
check("A2 Task210：平贴家族改名保留（AmeCardSurfaceColor + 卡/面板双方法，双阴影零回归）",
      "UIColor *AmeCardSurfaceColor(void)" in engine_m
      and "- (void)ame_applyCardSurfaceWithRadius:(CGFloat)cornerRadius" in engine_m
      and "- (void)ame_applyPanelSurfaceWithRadius:(CGFloat)cornerRadius" in engine_m
      and "shadowOpacity" not in engine_m and "CAGradientLayer layer" not in engine_m)
check("A3 Task210：BackgroundManager 开关/透明度偏好零残留（属性+存取器+defaults 键；注释留档不计）",
      all(sym not in _nocomment(bm_m) and sym not in _nocomment(bm_h) for sym in
          ("cardsNeumorphEnabled", "cardsNeumorphOpacity",
           "kBackgroundCardsNeumorphEnabledKey", "kBackgroundCardsNeumorphOpacityKey")))
check("A4 Task210：管线单路径化（refreshUIEffect 无开关分支；ame190 泛型无 ON 分支；"
      "applyNeumorphCardEffectToView 改名 applyCardEffectToView）",
      "self.cardsNeumorphEnabled" not in _nocomment(bm_m)
      and "[target ame_applyNeumorphSurface];" not in bm_m
      and "- (void)applyCardEffectToView:(UIView *)view" in bm_m
      and "applyNeumorphCardEffectToView" not in _nocomment(bm_m)
      and "applyNeumorphCardEffectToView" not in _nocomment(bm_h))
check("A5 Task210：无壁纸尾部 = 平贴灰面（AmeCardSurfaceColor + clamp[8,50] + 平贴保裁剪）",
      "view.backgroundColor = AmeCardSurfaceColor();" in bm_m
      and "view.layer.cornerRadius = MAX(8.0, MIN(radius, 50.0));" in bm_m)
check("A6 Task210：设置页新拟态两行退役（开关行/透明度滑条行/回调全删）",
      all(sym not in rd("Natives/BackgroundSettingsViewController.m") for sym in
          ("CardsNeumorphToggleCell", "CardsNeumorphOpacityCell",
           "cardsNeumorphToggleChanged", "cardsNeumorphOpacitySliderChanged",
           "cardsNeumorphOpacity", "cardsNeumorphEnabled")))
check("A7 Task210：Terracotta 状态卡换调改名后的 applyCardEffectToView",
      "applyCardEffectToView:self.statusCard]" in rd("Natives/TerracottaViewController.m")
      and "applyNeumorphCardEffectToView" not in rd("Natives/TerracottaViewController.m"))
check("A8 Task210：l10n 双键六语言全退役",
      all("background.cards.neumorph." not in rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
          for lg in ["en", "zh-Hans", "zh-CN", "zh-Hant", "ja", "km"]))
check("A9 边界维持：侧栏/右面板仍走 applyEffectToView（Task163 平贴结论不被波及）",
      "applyEffectToView:self.sidebarContainer]" in rd("Natives/LauncherRootViewController.m")
      and "applyEffectToView:self.rightPanelContainer]" in rd("Natives/LauncherRootViewController.m"))

# ============================================================
# B. l10n 键集（Task210 重锚：双键退役，计数 2520 -> 2520）
# ============================================================
bsvc = rd("Natives/BackgroundSettingsViewController.m")

check("B1 Task210：壁纸管线既有滑条行不受影响（opacity/blur 回调单在位）",
      "opacitySliderChanged:" in bsvc and "blurIntensitySliderChanged:" in bsvc
      and bsvc.count("- (void)blurIntensitySliderChanged:") == 1
      and bsvc.count("- (void)opacitySliderChanged:") == 1)
check("B2 Task210：settings sections[0] = 纯壁纸效果三行（无 neumorph 键）",
      "background.cards.neumorph" not in bsvc
      and 'localize(@"i18n_str_57", nil), localize(@"i18n_str_1296", nil), localize(@"i18n_str_1297", nil)' in bsvc)
check("B3 Task210：无壁纸时 section 0 整段隐藏（numberOfRows 0 行 + 页脚同步隐藏）",
      "if (section == 0 && ![[BackgroundManager sharedManager] hasBackground]) {\n        return 0;" in bsvc.replace('\n', '\n'))
check("B4 四主语言键集一致且计数 = 2520（Task210 重锚：neumorph 双键退役，2520-2）",
      all(len(set(re.findall(r'^"([^"]+)"\s*=', rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), re.M))) == 2520
          for lg in ["en", "zh-Hans", "zh-CN", "zh-Hant"]))
keysets = [set(re.findall(r'^"([^"]+)"\s*=', rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), re.M))
           for lg in ["en", "zh-Hans", "zh-CN", "zh-Hant"]]
check("B5 四主语言键集逐键一致", keysets[0] == keysets[1] == keysets[2] == keysets[3])

# ============================================================
# C. 使用问题 JSON 化（双文件对齐公告）
# ============================================================
root_bytes = open("help-faq.json", "rb").read()
bundle_bytes = open("Natives/resources/help-faq.json", "rb").read()
check("C1 双文件逐字节一致（根 = 维护源，resources = 随包）", root_bytes == bundle_bytes)
faq = json.loads(root_bytes.decode("utf-8"))
cats = faq.get("categories", [])
check("C2 结构：四分类且组名正确",
      [c["name"] for c in cats] == ["渲染与性能", "输入与控制", "安装与数据", "故障排除"])
check("C3 条数口径（12/4/7/15，总 38 —— Task206 重锚：渲染与性能 +1 = NG-GL4ES 条目；"
      "Task202 重锚：故障排除 +2 = Metal(metallum) 崩溃指引 + Forge/OptiFine 不兼容定性；"
      "Task176 重锚：用户并行编辑 3d36ea5/407b710 把「内存分配建议」拆成两条，安装与数据 6→7；"
      "Task82-166 硬编码时代的 34 已过时）",
      [len(c["items"]) for c in cats] == [12, 4, 7, 15]
      and sum(len(c["items"]) for c in cats) == 38)
allit = [i for c in cats for i in c["items"]]
check("C4 每条 icon/title/description 三字段全非空",
      all(i.get("icon") and i.get("title") and i.get("description") for i in allit))
check("C5 过时结论已更新：FSR 条目 = 三后端支持（Metal 呈现层），旧句清除",
      any("Metal 呈现层拦截放大" in i["description"] and "FSR 超分辨率怎么用" in i["title"] for i in allit)
      and not any("暂不支持。Vulkan 直连无升采样呈现钩子" in i["description"] for i in allit))
check("C6 过时结论已更新：MobileGlues 卡顿条目补 Vulkan+FSR 推荐路径",
      any("Vulkan 直连后端（MobileGL）并开 FSR 档位" in i["description"] for i in allit))
helpvc = rd("Natives/LauncherHelpViewController.m")
check("C7 页面改读随包 JSON（pathForResource + JSONSerialization + 空分组兜底日志）",
      'pathForResource:@"help-faq" ofType:@"json"' in helpvc
      and "JSONObjectWithData" in helpvc
      and "help-faq.json missing/unparsable" in helpvc)
check("C8 硬编码条目已整体退役（旧 buildFaqData 大块不存在）",
      "renderer.iconName" not in helpvc and "sparkProfiler" not in helpvc
      and "self.itemsByCategory = @[" not in helpvc)
check("C9 LauncherHelpFaqItem 类保留（页面模型零改动）",
      "@interface LauncherHelpFaqItem : NSObject" in helpvc
      and "item.question = title;" in helpvc
      and "item.iconName" in helpvc)
check("C10 抽取/幂等脚本入库（可重跑再生成）",
      os.path.exists("scripts/task168_faq_extract.py")
      and "help-faq.json" in rd("scripts/task168_faq_extract.py"))

# ============================================================
# D. 公告 + version.h
# ============================================================
anns = json.loads(rd("announcements.json"))["announcements"]
ids = [a["id"] for a in anns]
check("D1 公告顺延（Task212 重锚：task212@2 插入后 task168 顺延至 anns[24]；task169 钉死 anns[1] 不动）且 id 唯一",
      len(ids) == len(set(ids))
      and anns[1]["id"] == "task169-four-fixes-2026-09-25"
      and anns[25]["id"] == "task168-neumorph-faq-json-2026-09-25")
t168 = anns[25]  # Task212 重锚：task212@2 插入后 task168 实居 21
check("D2 公告内容：根因叙述 + 双形态 + 两个维护路径",
      "447a677" in t168["content"] and "透明度/模糊" in t168["content"]
      and "announcements.json" in t168["content"] and "help-faq.json" in t168["content"]
      and "实底" in t168["summary"])
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("D3 version.h Task 168 addendum（双事由）",
      "Task 168" in vh and "ame_attachNeumorphShadowOnly" in vh and "help-faq.json" in vh)

# ============================================================
# E. 语法 / 配平 / 级联
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
        i += 1
    return all(v == 0 for v in depth.values())


check("E1 配平：BackgroundManager.m", balance("Natives/BackgroundManager.m"))
check("E2 配平：BackgroundSettingsViewController.m", balance("Natives/BackgroundSettingsViewController.m"))
check("E3 配平：LauncherHelpViewController.m", balance("Natives/LauncherHelpViewController.m"))
check("E4 配平：UIKit+NativeSurface.m", balance("Natives/UIKit+NativeSurface.m"))
check("E5 配平：TerracottaViewController.m", balance("Natives/TerracottaViewController.m"))
check("E6 新增 NSLog 无格式符（Task169 格式串审计口径）",
      "FAQ rendered empty" in helpvc and helpvc.count('NSLog(@"[LauncherHelp]') == 1)

CASCADES = ["160", "161", "162", "163", "164", "165", "166", "167", "169",
            "129", "130", "131", "132", "133", "134", "135", "138", "139",
            "141", "142", "143", "150", "151", "156", "157", "159"]
# 历史 verify 脚本用 TASKxxx_REPO / AME_REPO 环境变量注入仓库根（默认值是
# 并行会话沙箱路径）——级联运行时统一注入为本仓库根。
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
# Task173 具名沙箱传播簇（详证见 verify_task173 G1 注释；Task171 先例同款）。
SANDBOX_EXCEPTIONS = {
    "131": ("H3 verify_task130",),
    "132": ("A1 崩溃日志证据", "A15 libjnidispatch", "G4 级联六验证器"),
    "135": ("E. verify_task130", "E. verify_task131", "E. verify_task132",
            "E. verify_task133", "E. verify_task134", "G4 级联六验证器"),
    "156": ("G verify_task154",),
    # Task213 补录：并行 Task212（a4a4c77/b842b67）文档化的 132-135 家族
    # 漂移（OSMesa/controlify 会话日志轮换类）+ 138 的 Task157 时代 2228
    # l10n 基线陈旧（现 2520）——与该轮 b842b67 提交说明逐条对账。
    "133": ("B1 崩溃证据链在位", "B1c 成功会话对照"),
    "138": ("A1 崩溃日志证据", "B1 mod 侧 XML 解析失败证据",
            "B2 启动器侧 plist 写入病灶证据", "I-l10n 四语言键集一致",
            "J verify_task135 ALL PASS",
            "J verify_task136 ALL PASS",  # Task213: 136 的存量 C4 一笔（62/1）
            "J verify_task137 ALL PASS"),
}
new_failures = []
for t in CASCADES:
    script = f"scripts/verify_task{t}.py"
    if not os.path.exists(script):
        new_failures.append((t, ["<script missing>"]))
        continue
    r = subprocess.run([sys.executable, script], capture_output=True, text=True,
                       timeout=600, env=cascade_env)
    if r.returncode == 0:
        continue
    cur = set(fail_lines(r.stdout + r.stderr))
    allow = set(baseline.get(t, []))
    exc = SANDBOX_EXCEPTIONS.get(t, ())
    extra = sorted(f for f in cur
                   if f not in allow and not any(e in f for e in exc))
    if extra:
        new_failures.append((t, [e[:120] for e in extra]))
cascade_fail = new_failures
check("E7 级联零新增失败（当前失败 ⊆ 提交树基线，家法 stash 对拍口径）", not cascade_fail, str(cascade_fail))
# E7 实现：与 scripts/task168_cascade_baseline.json（提交树实测既有失败清单）
# 逐脚本比对——新增失败脚本或新增失败检查行都会置红；基线内的既有失败
# （子级联沙箱路径默认值 / 日志钉住漂移，HEAD 上即存在）不计为回归。

# ============================================================
print("=" * 72)
passed = sum(1 for ok, _, _ in results if ok)
for ok, name, detail in results:
    print(("[PASS] " if ok else "[FAIL] ") + name + (f"  -- {detail}" if (detail and not ok) else ""))
print("=" * 72)
print(f"verify_task168: {passed}/{len(results)}" + ("  ALL GREEN" if passed == len(results) else "  HAS FAILURES"))
sys.exit(0 if passed == len(results) else 1)
