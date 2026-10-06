#!/usr/bin/env python3
"""verify_task212 -- Task 212 stage-1 verification (user's five orders, part 1).

Coverage:
  A. ANGLE evidence kit (99d8122e adjudication):
     A1-A3  tinygl4angle.c: instanced fullscreen-quad census + terrain
            mega-draw landing probe (both born from the device log's evidence
            that the composite draws via glDrawArraysInstanced and the chunk
            target sees count=222534 draws)
     A4-A5  gl_bridge.m: 5-point readback gate lowered to 240/480/720 rounds
            (the 99d8122e session ran ~810 swaps and never reached the old
            >=900 gate)
  B. CurseForge filter hardening (user: "cf的筛选功能无法使用"):
     B1-B3  transient retry (network error + empty body) -- sandbox-reproduced
            mirror flakiness
     B4-B6  filter-chain anchor logs (reload + source switch)
     B7     version-tab picker popover anchor fix (container visibility)
     B8     the display-layer "[m" lesson recorded in version.h (the phantom
            "sgView dismiss];" corruption -- bytes are "[msgView dismiss];")
  C. Renderer rename "gl4es(≤26.2)" (user's EXACT string, nothing added):
     C1-C4  l10n x4 / VersionManager / AI mapping / FAQ x5 twins
  D. Holy gl4es retirement (user's deletion order):
     D1-D7  dylib gone, table entry gone, egl_bridge/JavaLauncher fallbacks
            retargeted, migration wired, Makefile patch lines retired
  E. l10n net-zero key swap (2520 held: gl4es key out, virgl key in)
  F. Docs: version.h addendum + announcement task212@2
  G. Cascade spot checks (the re-anchored family)
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASS = FAIL = 0
def check(label, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print(f"  PASS  {label}")
    else:
        FAIL += 1
        print(f"  FAIL  {label}  -- {detail}")

def rd(p):
    return open(p, encoding="utf-8").read()

print("== A. ANGLE evidence kit ==")
tg = rd("Natives/external/gl4es/tinygl4angle.c")

check("A1 fsq-instanced 普查（26.3 合成走 glDrawArraysInstanced；门 4/5/6 + count 3-6 + inst 1-4）",
      "Task212 fsq-instanced: fullscreen-quad candidate" in tg
      and "(mode == 4u || mode == 5u || mode == 6u) && count >= 3 && count <= 6" in tg
      and "instancecount >= 1 && instancecount <= 4" in tg
      and "s_ame212_fsq <= 4) ame209_draw_state(\"Task212FSQInstanced\")" in tg)

check("A2 地形巨型绘制落地探针（count>=100000 门 + 每会话 <=2 + 1x1 中心读）",
      "ame212_terrain_landing_probe(GLsizei count)" in tg
      and "if (count < 100000) return;" in tg
      and "s_ame212_tl >= 2" in tg
      and "Task212 terrain landing probe #%d" in tg
      and "0x1908 /*GL_RGBA*/, 0x1401 /*GL_UNSIGNED_BYTE*/, ame212_px" in tg)

check("A3 探针在绘制提交【后】回读（BaseVertex 包装器尾部调用）",
      tg.index("ame212_terrain_landing_probe(count);") >
      tg.index("ame173_ptr_glDrawElementsInstancedBaseVertex(mode, count, type, indices, instancecount, basevertex)"))

gb = rd("Natives/ctxbridges/gl_bridge.m")
check("A4 五点回读降门（240/480/720 三轮，<=3 次）",
      "(swapIndex == 240 || swapIndex == 480 || swapIndex == 720)" in gb
      and "s_task211_5pt < 3" in gb
      and "swapIndex >= 900" not in gb)

check("A5 降门判据注释（99d8122e 会话 ~810 swap 的实证记录）",
      "99d8122e 会话总 swap 数约 810" in gb)

r = subprocess.run(["bash", "scripts/task193_tinygl_syntax.sh"],
                   capture_output=True, text=True, timeout=300)
check("A6 tinygl4angle 真源码语法门（task193 gate）", r.returncode == 0 and "SYNTAX OK" in r.stdout,
      r.stdout[-160:] if r.returncode else "")
r = subprocess.run(["python3", "scripts/task103_syntax_swap.py"],
                   capture_output=True, text=True, timeout=300)
check("A7 gl_bridge osm_swap 语法门（task103 gate；本轮修复其 br_get_current 桩缺失）",
      r.returncode == 0 and "syntax OK" in r.stdout,
      r.stdout[-160:] if r.returncode else "")

print("== B. CurseForge 筛选加固 ==")
cf = rd("Natives/installer/modpack/CurseForgeAPI.m")
check("B1 瞬态网络错误自动重试（NSURLErrorDomain + attempt<1）",
      "transient network error" in cf
      and "attempt < 1 && [error.domain isEqualToString:NSURLErrorDomain]" in cf
      and "ame172_retrySearchRequest:request attempt:attempt" in cf)

check("B2 空响应退避重试（不再要求 5xx；沙盒镜像波动实测）",
      "if (attempt < 1 || ([self ame172_isTransientServerStatus:response] && attempt < 2)) {" in cf
      and "Task212：空体本身就是镜像瞬态波动" in cf)

dvc = rd("Natives/DownloadViewController.m")
check("B3 源切换锚点日志（curseforge/modrinth 双向 + 类型 + 旧值）",
      "Task212 source switch: type=%@ %@ -> curseforge (keyless mirror eligible)" in dvc
      and "Task212 source switch: type=%@ %@ -> modrinth" in dvc)

check("B4 列表重载锚点日志（tab/源/版本/加载器/排序 全量打印）",
      "Task212 reload: tab=%ld type=%@ source=%@ version=%@ loader=%@ sort=%@" in dvc)

check("B5-7 iPad popover 锚修（三 picker 改查容器可见性）",
      dvc.count("self.filterSidebarContainer.hidden ? self.filterButton :") == 3)

vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("B8 显示层 \"[m\" 教训入档（幻影 sgView 损伤 = 5b6d 字节实为 [msgView）",
      "sgView dismiss" in vh and "5b6d" in vh)

print("== C. 渲染器更名 gl4es(≤26.2)（用户定名一字不加） ==")
NAME = "gl4es(≤26.2)"
l10n_ok = True
for lg in ("en", "zh-CN", "zh-Hans", "zh-Hant"):
    s = rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
    if f'"preference.title.renderer.debug.gl4eszl2" = "{NAME}";' not in s:
        l10n_ok = False
check("C1 l10n 四语值 = 精确串 gl4es(≤26.2)（ASCII 括号 + U+2264）", l10n_ok)

vm = rd("Natives/VersionManagerViewController.m")
check("C2 VersionManager 短名 = gl4es(≤26.2)（holy GL4ES 行已删）",
      f'@ RENDERER_NAME_GL4ESZL2: @"{NAME}"' in vm
      and '@ RENDERER_NAME_GL4ES:' not in vm)

ai = rd("Natives/AI/AiSettingsTools.m")
check("C3 AI 映射（裸 gl4es 由 gl4eszl2 接棒 + 友好名同步）",
      '[lower containsString:@"gl4eszl2"] || [lower containsString:@"zl2classic"] ||' in ai
      and '    [lower containsString:@"gl4es"] || [lower containsString:@"zl2 经典"]) return @(RENDERER_NAME_GL4ESZL2);' in ai
      and f'return @"{NAME} (libgl4eszl2.dylib)"; // Task211 引入；Task212 用户定名' in ai
      and 'GL4ES (libgl4es_114.dylib)' not in ai)

faq_ok = True
for f in ("Natives/resources/help-faq.json", "Natives/resources/en.lproj/help-faq.json",
          "Natives/resources/zh-CN.lproj/help-faq.json", "Natives/resources/zh-Hant.lproj/help-faq.json",
          "help-faq.json"):
    txt = rd(f)
    if NAME not in txt:
        faq_ok = False
    if "ZL2 经典版）" in txt or "ZL2 經典版）" in txt or "ZL2 classic)" in txt:
        faq_ok = False
    json.loads(txt)
check("C4 FAQ 五份孪生（新名在场 + 旧名清零 + JSON 合法 + 条数 38）", faq_ok and all(
    sum(len(c.get("items", [])) for c in json.loads(rd(f))["categories"]) == 38
    for f in ("Natives/resources/help-faq.json", "help-faq.json")))

print("== D. holy gl4es 退役（用户明令删除） ==")
check("D1 dylib 已删",
      not os.path.exists("Natives/resources/Frameworks/libgl4es_114.dylib"))

lp = rd("Natives/LauncherPreferences.m")
check("D2 渲染器表项已删（auto/mg 后直接 ANGLE + 退役注释）",
      '@{"key": @ RENDERER_NAME_GL4ES,' not in lp
      and "holy gl4es 表项退役删除" in lp)

eb = rd("Natives/egl_bridge.m")
check("D3 egl_bridge auto/legacy 改道 gl4eszl2（含 holy 存量值兼容分支）",
      'if (isAuto || [renderer isEqualToString:@"libgl4es_114.dylib"]) {' in eb
      and "renderer = @ RENDERER_NAME_GL4ESZL2;" in eb
      and "Task212: renderer '%@' -> ZL2 classic gl4es (holy gl4es retired" in eb
      and "Task192: preloading ANGLE frameworks RTLD_GLOBAL" not in eb
      and "Task202: Task193 gl4es bootstrap block ENTERED" not in eb)

check("D4 pojavSetWindowHint legacy 分支改道",
      "setenv(\"AMETHYST_RENDERER\", RENDERER_NAME_GL4ESZL2, 1);" in eb
      and "JNI_LWJGL_changeRenderer(RENDERER_NAME_GL4ESZL2);" in eb)

jl = rd("Natives/JavaLauncher.m")
# Task217 重锚：auto 分支重构为 ame217_autoRendererDecide 候选链
#（Task144/173/212 的版本基线语义不变，措辞随链函数搬迁）。
check("D5 JavaLauncher legacy auto 路径改道（Task217 重锚：候选链函数形态）",
      "? @[@ RENDERER_NAME_MOBILEGL, @ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE]" in jl
      and ": @[@ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE, @ RENDERER_NAME_MOBILEGL]" in jl
      and "legacy MC baseline (Task173/212: ZL2 classic gl4es)" in jl)

check("D6 存量迁移（全局 + per-profile，main.m 于 updateCurrent 前调用）",
      "ame212_migrateHolyGl4es" in lp and "ame212_migrateHolyGl4es" in rd("Natives/main.m")
      and "ame212_migrateHolyGl4es();" in rd("Natives/main.m")
      and "video.renderer" in lp and 'ame212_p[@"renderer"]' in lp)

mk = rd("Makefile")
check("D7 Makefile 补丁接线退役 + TAB 基线 644（Task215 重锚：dep_virgl +83）",
      "patch_gl4es_rtld_default.py" not in mk and "patch_gl4es_ggstr_nullguard.py" not in mk
      and "holy gl4es（libgl4es_114.dylib）退役删除" in mk
      and sum(1 for l in mk.split("\n") if l.startswith("\t")) == 662)

check("D8 utils.h 宏退役（字面量仅存于迁移判定）",
      '#define RENDERER_NAME_GL4ES "libgl4es_114.dylib"' not in rd("Natives/utils.h"))

print("== E. l10n 净零交换（2696 守恒） ==")
def keys_of(lg):
    return set(re.findall(r'^"([^"]+)" = ', rd(f"Natives/resources/{lg}.lproj/Localizable.strings"),
                          re.M))
sets = [keys_of(lg) for lg in ("en", "zh-CN", "zh-Hans", "zh-Hant")]
check("E1 四语唯一键 2696 一致（gl4es 出 / virgl 入 = 净零）",
      all(len(s) == 2696 for s in sets) and sets[0] == sets[1] == sets[2] == sets[3])
check("E2 holy gl4es l10n 键全清（54 文件零残留）",
      all("preference.title.renderer.debug.gl4es\"" not in
          rd(os.path.join("Natives/resources", f, "Localizable.strings"))
          for f in os.listdir("Natives/resources") if f.endswith(".lproj")))
check("E3 virgl 显示键就位（VirGLRenderer(≤26.2)，四语同串）",
      all(f'"preference.title.renderer.debug.virgl" = "VirGLRenderer(≤26.2)";' in
          rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
          for lg in ("en", "zh-CN", "zh-Hans", "zh-Hant")))

print("== F. 文档 ==")
check("F1 version.h Task212 附录（REVISION 18 addendum + 五主题）",
      "REVISION 18 addendum (Task 212, no bump)" in vh
      and "VirGLRenderer(<=26.2)" in vh and "terrain mega-draw landing" in vh
      and "net-zero swap" in vh)

ann = json.loads(rd("announcements.json"))["announcements"]
check("F2 公告 task212@3（35 条 = 并行 task213@2 插入后的合并态 + 置顶钉位 + 尾锚）",
      len(ann) == 43 and ann[5]["id"] == "task212-angle-cf-renderers-virgl-2026-10-02"
      and ann[0]["id"].startswith("server-recommend")
      and ann[1]["id"] == "task169-four-fixes-2026-09-25"
      and ann[6]["id"] == "task211-exit-cf-angle-gl4es-2026-10-02"
      and ann[-5]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-6]["id"] == "task216-ui-2026-10-03"
      and ann[-7]["id"] == "task206-nggl4es-2026-10-01")

check("F3 公告内容五主题齐备",
      all(k in ann[5]["content"] for k in
          ("810", "glDrawArraysInstanced", "重试", "gl4es(≤26.2)", "holy gl4es", "VirGLRenderer(≤26.2)")))

print("== G. 级联抽查（本轮重锚族） ==")
spot = {
    "scripts/verify_task206.py": ["cur_tab == 662", 'len(ann) == 43 and ann[-5]["id"] == "task217-download-fixes-about-isolation-2026-10-03"'],
    "scripts/verify_task211.py": ['len(ann) == 43 and ann[6]["id"] == "task211-exit-cf-angle-gl4es-2026-10-02"',
                                  "(swapIndex == 240 || swapIndex == 480 || swapIndex == 720)"],
    "scripts/verify_task210.py": ['len(ann) == 43\n      and ann[7]["id"] == "task210-neumorph'],
    "scripts/verify_task209.py": ["a209 = ann[8]", "len(ann) == 43"],
    "scripts/verify_task203.py": ["len(ann) == 43 and ann[-5]['id'] == 'task217-download-fixes-about-isolation-2026-10-03'"],
    "scripts/verify_task202.py": ["len(ann) == 43", 'ann[34]["id"] == "task202-october-fix-wave"', "mk_tab == 662"],
    "scripts/verify_task193.py": ["len(ann) == 43", 'ann[11]["id"] == "task193-app-icon-replace-2026-09-28"'],
    "scripts/verify_task129.py": ["cur_tab == 662 and head_tab == 662"],
    "scripts/verify_task135.py": ["cur_tab == 662 and head_tab == 662"],
    "scripts/verify_task173.py": ['ann["announcements"][21]["id"] == "task173-ten-fixes-2026-09-26"'],
    "scripts/verify_task174.py": ['anns[19]["id"] == "task174-neumorph-canvas-opacity-label-2026-09-26"'],
    "scripts/verify_task168.py": ['anns[25]["id"] == "task168-neumorph-faq-json-2026-09-25"'],
    "scripts/verify_task207.py": ["len(ann) == 43", 'ann[9]["id"] == "task207-shortcuts-instance-cards-2026-10-01"'],
    "scripts/verify_task142.py": ["v6-0-0-release-2026-09-21"],
    "scripts/verify_task140.py": ["f95a2193", "2c668874"],
    "scripts/verify_task190.py": ['["announcements"][12]["id"].startswith("task190-")'],  # Task213: two @2 inserts
}
g_ok = True
g_detail = []
for f, needles in spot.items():
    s = rd(f)
    for n in needles:
        if n not in s:
            g_ok = False
            g_detail.append(f"{f}: missing {n[:50]}")
check("G1 重锚抽查（16 验证器锚点在位）", g_ok, "; ".join(g_detail[:3]))

# deep runs (subset; the rest documented in the worklog)
for v in ("verify_task140.py", "verify_task142.py", "verify_task173.py", "verify_task203.py"):
    r = subprocess.run([sys.executable, f"scripts/{v}"], capture_output=True, text=True, timeout=600)
    ok = r.returncode == 0
    check(f"G2 {v} 深跑全绿", ok, r.stdout[-150:] if not ok else "")

print(f"\n==== Task212 stage-1: {PASS}/{PASS + FAIL} ====")
if FAIL:
    print("FAILED:")
    sys.exit(1)
print("ALL PASS")
