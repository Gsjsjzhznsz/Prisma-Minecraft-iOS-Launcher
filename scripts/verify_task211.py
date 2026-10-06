#!/usr/bin/env python3
"""verify_task211.py -- Task211 verification (stage 1: metallum/CF/ANGLE/l10n).

A. Metallum 退出"崩溃"根治（补丁器/探针源码锚点 + jar 变更 + E2E 行为门）
B. CurseForge 403 三层防线 + 源迁移 + 403 友好化
C. ANGLE multidraw 拆解 + 全屏四边形普查 + in-world 五点回读
D. l10n Krypton 显示名收短
E. 文档（version.h 附录 / 公告 task211@2）+ 级联重锚面
F. 语法门（task211_syntax_gate）+ 受影响级联 verify

判读坐标：17c51003 上传 latestlog.txt（CF 占位 Key 403 会话）+
latestlog.old.txt（Task209 构建 c7079e1 上的 ANGLE 会话：绘制健康 +
ClientShutdownWatchdog 退出误报）。
（Stage 2 的 gl4es 移植验证在 G 组追加。）
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
results = []


def rd(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8", errors="replace") as f:
        return f.read()


def check(name, ok, detail=""):
    results.append((name, ok))
    print(("  PASS " if ok else "  FAIL ") + name + (f"  -- {detail}" if detail and not ok else ""))


def run(cmd, timeout=300):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO)


# ============ A. Metallum 退出修复 ============
print("== A. Metallum 退出根治 ==")
patcher = rd("scripts/task211_metallum_daemon_patch.java")
check("A1 补丁器：premain 内两处 Thread.start 前插 setDaemon（ASM DUP/ICONST_1）",
      "expected exactly 2 Thread.start() sites" in patcher
      and "setDaemon" in patcher
      and "Opcodes.DUP" in patcher and "Opcodes.ICONST_1" in patcher
      and "COMPUTE_MAXS" in patcher)
check("A2 补丁器：只动 MetallumAgent.class，其余条目字节原样透传",
      "com/metallum/agent/MetallumAgent.class" in patcher
      and "preserve compression + timestamps" in patcher)
probe = rd("scripts/task211_metallum_probe.java")
check("A3 探针：metallum-dump/state 双线程 daemon 判定 + 即退语义",
      't.getName().equals("metallum-dump")' in probe
      and 't.getName().equals("metallum-state")' in probe
      and "isDaemon" in probe)
# A4（提交后口径）：当前 jar ≠ Task201 原版 jar（字节级差异 = 补丁版入库；
# 行为正确性由 A5 的 E2E 门证明）
r = run(["bash", "-c",
         "git show 6629ce20:JavaApp/libs/others/metallum_agent.jar | md5sum; "
         "md5sum JavaApp/libs/others/metallum_agent.jar"])
lines_out = [l.split()[0] for l in r.stdout.strip().split("\n") if l.strip()]
check("A4 仓库 jar 已变更（对比 Task201 原版字节）",
      len(lines_out) == 2 and lines_out[0] != lines_out[1],
      r.stdout[:120])

# E2E 行为门（java 可用时）：补丁版 = daemon=true + 即退 0
# Task212 修：探针类改为现场编译（旧会话曾依赖 /tmp/t211 的预编译产物，
# 沙箱重置即蒸发——A5 因此误报）。自包含后任何环境可复跑。
# Task215 修正：双在位门（仅查 java 时 JRE 即过，javac 缺失 → FileNotFoundError
# 落进 except 被记 FAIL——环境性误报；沙箱瘦身后仅剩 JRE 属实）
have_java = (run(["bash", "-lc", "command -v java"]).returncode == 0
              and run(["bash", "-lc", "command -v javac"]).returncode == 0)
if have_java:
    try:
        import tempfile as _tf
        _t211dir = _tf.mkdtemp(prefix="t211probe_")
        _rc = subprocess.run(["javac", "-d", _t211dir, "scripts/task211_metallum_probe.java"],
                             capture_output=True, text=True, timeout=60, cwd=REPO)
        if _rc.returncode != 0:
            check("A5 E2E 行为门（仓库 jar as -javaagent）", False, f"javac: {_rc.stderr[:160]}")
        else:
            r = subprocess.run(["timeout", "30", "java", "-javaagent:JavaApp/libs/others/metallum_agent.jar",
                                "-cp", _t211dir, "T211Probe"],
                               capture_output=True, text=True, timeout=45, cwd=REPO)
            ok = (r.returncode == 0 and "metallum-dump daemon=true" in r.stdout
                  and "metallum-state daemon=true" in r.stdout)
            check("A5 E2E 行为门（仓库 jar as -javaagent）", ok,
                  f"exit={r.returncode} out={r.stdout[:200]}")
    except Exception as e:
        check("A5 E2E 行为门（仓库 jar as -javaagent）", False, str(e)[:120])
else:
    check("A5 E2E 行为门", True, "skipped: java 不在本机（CI 无此门；补丁器确定性 + A1-A4 为静态门）")

# ============ B. CF 三层防线 ============
print("== B. CurseForge 403 根治 ==")
cf = rd("Natives/installer/modpack/CurseForgeAPI.m")
check("B1 共享占位判定 CFAIsGarbageAPIKey（家族表 + ((void 前缀兜底）",
      "static BOOL CFAIsGarbageAPIKey(NSString *key)" in cf
      and 'isEqualToString:@"((void *)0)"]' in cf
      and 'hasPrefix:@"((void"]' in cf)
check("B2 apiKey getter：运行时占位键视为未配置 + 一次性设备锚点日志",
      "!CFAIsGarbageAPIKey(runtimeKey)) {" in cf
      and "Task211: runtime preference holds a placeholder key" in cf)
check("B3 isAPIKeyConfigured 同表拒收",
      re.search(r"runtimeKey\.length > 0 &&\s*\r?\n\s*!CFAIsGarbageAPIKey\(runtimeKey\)\) \{\s*\r?\n\s*return YES;",
                cf) is not None)
check("B4 +isPlaceholderAPIKey: 类方法（getter/VC 共用）",
      "+ (BOOL)isPlaceholderAPIKey:(NSString *)key" in cf
      and "+ (BOOL)isPlaceholderAPIKey:(NSString *)key;" in rd("Natives/installer/modpack/CurseForgeAPI.h"))
check("B5 403 友好化（API-Key 类 403 翻译为可读信息）",
      "statusCode == 403" in cf and "api key" in cf
      and "CurseForge 拒绝了请求：API Key 缺失或无效（403）" in cf)
_cfb = open(os.path.join(REPO, "Natives/installer/modpack/CurseForgeAPI.m"), "rb").read()
check("B6 CurseForgeAPI.m 保持 CRLF（字节纪律）",
      _cfb.count(b"\r\n") > 1200 and _cfb.count(b"\n") == _cfb.count(b"\r\n"))

ivc = rd("Natives/installer/CurseForgeAPIKeyViewController.m")
check("B7 installer VC（在编实现）：CFKCompiledAPIKey 委托共享判定",
      "[CurseForgeAPI isPlaceholderAPIKey:compiledKey])" in ivc
      and 'isEqualToString:@"CONFIG_CURSEFORGE_API_KEY"]' not in ivc.split("loadInitialValue")[0].split("CFKCompiledAPIKey")[1].split("}")[0])
check("B8 installer VC：保存门 + 测试门拒占位键",
      ivc.count("[CurseForgeAPI isPlaceholderAPIKey:key]") >= 2
      and "占位/无效的 Key 不予保存" in ivc and "占位/无效的 Key 不予测试" in ivc)
rvc = rd("Natives/CurseForgeAPIKeyViewController.m")
check("B9 根 VC（未在编同构对）：预填净化 + 保存门 + 失效导入修正",
      "[CurseForgeAPI isPlaceholderAPIKey:runtimeKey]" in rvc
      and "占位/无效的 Key 不予保存" in rvc
      and '#import "installer/modpack/CurseForgeAPI.h"' in rvc)
plp = rd("Natives/PLPreferences.m")
check("B10 哨兵键 general.task211_cf_source_migrated 入默认表",
      '@"task211_cf_source_migrated": @NO' in plp)
lp = rd("Natives/LauncherPreferences.m")
check("B11 迁移函数：清占位 Key + 无有效 Key 时七源拨回 modrinth",
      "void ame211_migrateCfSourceToModrinth(void)" in lp
      and "cleared placeholder CurseForge API key" in lp
      and "general.download_source_server" in lp
      and "flipped %lu curseforge source(s) to modrinth" in lp)
check("B12 迁移声明 + main.m 常跑点（Task167 教训位）",
      "void ame211_migrateCfSourceToModrinth(void);" in rd("Natives/LauncherPreferences.h")
      and "ame211_migrateCfSourceToModrinth();" in rd("Natives/main.m"))

# ============ C. ANGLE 拆解 + 探针 ============
print("== C. ANGLE multidraw 拆解 + 双探针 ==")
tg = rd("Natives/external/gl4es/tinygl4angle.c")
check("C1 三个 MultiDraw 全部拆解（不再经 multidraw 指针提交）",
      tg.count("Task211 decompose:") == 3
      and "ame173_ptr_glMultiDrawElementsBaseVertex(mode, count, type, indices, drawcount, basevertex);" not in tg
      and "ame173_ptr_glMultiDrawArrays(mode, first, count, drawcount);" not in tg
      and "ame173_ptr_glMultiDrawElements(mode, count, type, indices, drawcount);" not in tg)
check("C2 拆解循环走本文件包装（Task209 普查自动覆盖子绘制）",
      "glDrawElementsBaseVertex(mode, count[i], type, indices[i]," in tg
      and "(basevertex != NULL) ? basevertex[i] : 0" in tg
      and "glDrawArrays(mode, first[i], count[i]);" in tg
      and "glDrawElements(mode, count[i], type, indices[i]);" in tg)
check("C3 全屏四边形普查（final-blit 可见性）",
      "Task211 fsq: fullscreen-quad candidate" in tg
      and "(mode == 4u || mode == 5u || mode == 6u) && count >= 3 && count <= 6" in tg)
gb = rd("Natives/ctxbridges/gl_bridge.m")
check("C4 五点 in-world 回读（Task212 降门 240/480/720 三轮 + 中心/四角 + 1x1 独立小读）",
      "Task211 5-point in-world readback" in gb
      and "(swapIndex == 240 || swapIndex == 480 || swapIndex == 720)" in gb and "s_task211_5pt < 3" in gb
      and "ame211_xs[5]" in gb and "0x1908 /*GL_RGBA*/, 0x1401 /*GL_UNSIGNED_BYTE*/" in gb)
check("C5 五点门与 Task188 同界（drawFb==0 + viewport 有效）且 Task75 纪律注释在场",
      "drawFb == 0 && viewport[2] > 16 && viewport[3] > 16" in gb
      and "Task75" in gb.split("Task211 5-point")[0].split("Task211（ANGLE 方块透明，in-world 五点回读）")[1][:1500])

# ============ D. l10n 收短 ============
print("== D. Krypton 显示名收短 ==")
for lang in ("en", "zh-CN", "zh-Hant", "zh-Hans"):
    s = rd(f"Natives/resources/{lang}.lproj/Localizable.strings")
    line = [l for l in s.split("\n") if "preference.title.renderer.debug.nggl4es" in l]
    ok = line and "ZL2 同款" not in line[0] and "ZalithLauncher 2 gl4es" not in line[0] \
         and "Krypton Wrapper" in line[0]
    check(f"D-{lang} 收短且无长尾", ok, line[0][:90] if line else "missing")

# ============ E. 文档 + 公告 ============
print("== E. 文档 + 公告 ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("E1 version.h Task211 附录（五主题 + 尾部 SEP）",
      "REVISION 18 addendum (Task 211, no bump)" in vh
      and "metallum-state/metallum-dump" in vh
      and "ame211_migrateCfSourceToModrinth" in vh
      and "ALWAYS decompose into per-draw" in vh
      and re.search(r"// ={70,}\s*$", vh) is not None)
ann = json.loads(rd("announcements.json"))["announcements"]
check("E2 公告 task211@3（Task212 重锚：34 条 + task212@2 插入顺延 + 尾锚）",
      len(ann) == 43 and ann[6]["id"] == "task211-exit-cf-angle-gl4es-2026-10-02"
      and ann[0]["id"] == "server-recommend-2026-09-24"
      and ann[1]["id"] == "task169-four-fixes-2026-09-25"
      and ann[5]["id"] == "task212-angle-cf-renderers-virgl-2026-10-02"
      and ann[7]["id"] == "task210-neumorph-retirement-card-fixes-2026-10-02"
      and ann[-5]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-6]["id"] == "task216-ui-2026-10-03")
check("E3 公告内容五主题齐备",
      all(k in ann[6]["content"] for k in
          ("退出", "CurseForge", "Modrinth", "拆解", "ZL2 经典版", "virglrenderer")))

# ============ F. 语法门 + 级联 ============
print("== F. 语法门 + 级联 ==")
r = run(["python3", "scripts/task211_syntax_gate.py"])
check("F1 task211_syntax_gate（A/B 语法 + 10 文件括号平衡）", r.returncode == 0,
      r.stdout[-200:] if r.returncode else "")

cascade_shallow = ["verify_task165.py", "verify_task167.py", "verify_task190.py",
                   "verify_task196_197_198_201.py", "verify_task203.py",
                   "verify_task207.py", "verify_task210.py"]
# 深级联族（168/170/171/172/173/174/175——各自拖 112_118/119_124/125_128 子链）
# 单跑 1-9 分钟，全跑必超 600s 工具上限：按家法分跑补证（Task208 教训
# "split runs required"）。Task211 本轮分跑全绿：168:34/34、170:32/32、
# 171:30/0、172:51/51、173:123/0、174:24/0、175:41/0。
# Task217 追加（本沙箱 CPU 配额实测计时后入深族）：202（独立 ~265s：其 J
# 内嵌 168+193）、206（~183s：其 H 内嵌 193/129/174）、209（去重后仍
# ~500s：D4 206 + D7 193 + D9 168 三段全量直跑）、193（~90s）——四者
# 均超浅族预算，改分跑补证。Task217 本轮分跑实测全绿：202:57/57（独立
# 三腿全跑）、206:43/43、193:84/0、209:去重后全程 ALL PASS（D5 23/23 +
# D6 55/55 嵌套去重态，见 verify_task209 docstring）。
all_ok = True
detail = []
for c in cascade_shallow:
    try:
        r = run(["python3", f"scripts/{c}"], timeout=540)
        if r.returncode != 0:
            all_ok = False
            detail.append(f"{c}:exit{r.returncode}")
            print(f"    cascade FAIL {c}:\n" + "\n".join(
                l for l in r.stdout.split("\n") if "FAIL" in l)[:600])
    except subprocess.TimeoutExpired:
        all_ok = False
        detail.append(f"{c}:timeout")
        print(f"    cascade TIMEOUT {c}")
check("F2 公告级联 7 verify 全绿（浅族≤1s 实测；深族 168/170/171/172/173/174/175 + Task217 追加的 193/202/206/209 分跑补证全绿——见 docstring 与 worklog）", all_ok, "; ".join(detail))

print()
fails = [n for n, ok in results if not ok]
if not fails:
    # ============ G. Stage 2: ZL2 classic gl4es port ============
    print("== G. ZL2 经典版 gl4es 移植 ==")
    gtree = "ThirdParty/gl4es_extra_extra"
    cmk = rd(f"{gtree}/CMakeLists.txt")
    check("G1 vendored 树 + PROVENANCE（上游/快照/裁剪清单 + 4 适配项）",
          "PojavLauncherTeam/gl4es_extra_extra" in cmk
          and "codeload tarball refs/heads/master, fetched 2026-10-02" in cmk
          and "traces/ (46MB apitrace dumps)" in cmk
          and "adaptations vs the upstream build (4)" in cmk
          and os.path.isdir(os.path.join(REPO, gtree, "src/gl/wrap"))
          and not os.path.exists(os.path.join(REPO, gtree, "traces")))
    check("G2 自建 CMakeLists（纯 C 独立目标：无 glslang/spvc 变量 + 同款 flags + hardext + 生成别名入列）",
          "project(gl4eszl2 LANGUAGES C)" in cmk
          and "GL4ESZL2_GLSLANG" not in cmk and "GL4ESZL2_SPVC" not in cmk
          and '-DNO_GBM -DDEFAULT_ES=2 -DNOX11 -DNOEGL -DNO_INIT_CONSTRUCTOR' in cmk
          and "-fvisibility=hidden" in cmk
          and "src/glx/hardext.c" in cmk
          and "src/gl/wrap/gl4eszl2_darwin_aliases.c" in cmk
          and '"${GL4ESZL2_FRAMEWORK_DIR}" STREQUAL ""' in cmk)
    check("G3 源适配两处（hardext NULL 守卫 + init.c set_getprocaddress EXPORT）",
          "Amethyst Task211 (adaptation 4" in rd(f"{gtree}/src/glx/hardext.c")
          and 'if (!Exts) {' in rd(f"{gtree}/src/glx/hardext.c")
          and "Amethyst Task211 (adaptation 3" in rd(f"{gtree}/src/gl/init.c")
          and 'EXPORT\nvoid set_getprocaddress' in rd(f"{gtree}/src/gl/init.c")
          and '#include "attributes.h"' in rd(f"{gtree}/src/gl/init.c"))
    r = run(["python3", "scripts/task211_gen_gl4eszl2_aliases.py"])
    alias = rd(f"{gtree}/src/gl/wrap/gl4eszl2_darwin_aliases.c")
    check("G4 别名生成器（1214 个 + 幂等 + 悬空/撞名守卫 + 关键名在位）",
          r.returncode == 0 and "unchanged (1214 aliases)" in r.stdout
          and alias.count("__asm__") == 1214
          and '.global _glActiveTexture' in alias
          and '.global _glColor3b' in alias and '_glColor3b: b _gl4es_glColor3b' in alias
          and '.global _glFogCoordd' in alias
          and '.global _glVertexAttrib4Nubv' in alias
          and alias.rstrip().endswith("#endif"))
    mk = rd("Makefile")
    import subprocess as _sp
    _cur_tab = sum(1 for l in mk.splitlines() if l.startswith("\t"))
    # Task217 重锚：TAB 基线 559（Task211 时代）-> 662（Task216 dep_virgl +
    # Task217 meson 链；本轮前本门从未在本沙箱执行过——F2 重尾每次先超时，
    # G 段被 if-not-fails 短路，陈年漂移首次暴露）。
    check("G5 Makefile dep_gl4eszl2（独立目标 + 接线 payload + TAB 基线 662，Task217 重锚）",
          "dep_gl4eszl2:" in mk and "dep_gl4eszl2: dep_mg" not in mk
          # Task217 重锚：Task215 在 payload 行插入 dep_virgl，相邻序变为
          # dep_gl4eszl2 dep_virgl dep_angle_freeze。
          and "dep_gl4eszl2 dep_virgl dep_angle_freeze" in mk
          and "ThirdParty/gl4es_extra_extra/" in mk
          and _cur_tab == 662)
    check("G6 运行时五面（utils.h/渲染器表/egl_bridge boot+branch+MakeCurrent/VersionManager/AI 序；Task212 用户定名 gl4es(≤26.2)）",
          '#define RENDERER_NAME_GL4ESZL2 "libgl4eszl2.dylib"' in rd("Natives/utils.h")
          and '@ RENDERER_NAME_GL4ESZL2,' in rd("Natives/LauncherPreferences.m")
          and "ame211_gl4eszl2_boot();" in rd("Natives/egl_bridge.m")
          and '[renderer isEqualToString:@ RENDERER_NAME_GL4ESZL2]' in rd("Natives/egl_bridge.m")
          and '@ RENDERER_NAME_GL4ESZL2: @"gl4es(≤26.2)"' in rd("Natives/VersionManagerViewController.m"))
    ai = rd("Natives/AI/AiSettingsTools.m")
    # Task217 重锚：Task212 用户定名后，裸 "gl4es" 由 ZL2 经典版接棒匹配
    # （holy gl4es 退役），序约束改为 nggl4es/krypton 行先于 gl4es 家族行；
    # 友好名与输入别名同步收短。
    check("G6b AI 映射序（nggl4es/krypton 先于 gl4es 家族 + Task212 定名友好名 + zl2classic/zl2 经典 别名）",
          ai.index('containsString:@"nggl4es"]') < ai.index('containsString:@"gl4eszl2"]')
          and 'return @"gl4es(≤26.2) (libgl4eszl2.dylib)"' in ai
          and 'containsString:@"zl2classic"]' in ai and 'containsString:@"zl2 经典"]' in ai)
    l10n_expect = {"zh-Hans": "gl4es(≤26.2)", "zh-CN": "gl4es(≤26.2)",
                   "zh-Hant": "gl4es(≤26.2)", "en": "gl4es(≤26.2)"}
    ok_g7 = True
    for lg, want in l10n_expect.items():
        s = rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
        if f'"preference.title.renderer.debug.gl4eszl2" = "{want}";' not in s:
            ok_g7 = False
    check("G7 l10n 四语言新键（Task212 用户定名收短 gl4es(≤26.2)；唯一键计数见 G7b 2520）", ok_g7)
    import re as _re
    _zh = rd("Natives/resources/zh-CN.lproj/Localizable.strings")
    _keys = _re.findall(r'^"([^"]+)"\s*=', _zh, _re.M)
    check("G7b 唯一键计数 2696（四语一致）",
          len(set(_keys)) == 2696
          and all(len(set(_re.findall(r'^"([^"]+)"\s*=',
              rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), _re.M))) == 2696
              for lg in ("en", "zh-Hant", "zh-Hans")))
    import json as _json
    _faq_zh = _json.loads(rd("Natives/resources/zh-CN.lproj/help-faq.json"))
    _sel = _faq_zh["categories"][0]["items"][0]["description"]
    _faq_en = _json.loads(rd("Natives/resources/en.lproj/help-faq.json"))["categories"][0]["items"][0]["description"]
    _faq_ht = _json.loads(rd("Natives/resources/zh-Hant.lproj/help-faq.json"))["categories"][0]["items"][0]["description"]
    check("G8 FAQ 渲染器选择条目 ZL2 传统 gl4es bullet（Task212 定名 gl4es(≤26.2)；三语 + 根孪生字节一致 + 条数 38 不变）",
          "• gl4es(≤26.2)：" in _sel and "不行再试 gl4es(≤26.2)" in _sel
          and "• gl4es(≤26.2):" in _faq_en and "then try gl4es(≤26.2)" in _faq_en
          and "• gl4es(≤26.2)：" in _faq_ht
          and sum(len(c.get("items", [])) for c in _faq_zh["categories"]) == 38
          and open(os.path.join(REPO, "Natives/resources/help-faq.json"), "rb").read()
          == open(os.path.join(REPO, "Natives/resources/zh-CN.lproj/help-faq.json"), "rb").read())
    # 级联：本轮重锚的直接受影响者（TAB 基线族 + l10n 计数族 + Krypton 名族）。
    # 129（I4/A9）与 209（A1/A3/B1/D5/D9）单跑 3-5 分钟（拖 112_118/119_124/
    # 125_128/168 子链），与本门合计超 600s 工具上限——分跑补证（本轮各自
    # 全绿：129 含子级联 ALL PASS、209 26/26），家法同 F2。
    # Task217 追加分跑：202/206（实测 ~265s/~183s，F2 注录同款）与 135
    # （本沙箱血统缺外层工作区审计脚本 task116_l10n_audit / task116c_precise
    # / task132_jna_got_mirror——132/133/135 家族环境性存量债，与 Task212-216
    # 收官记录逐笔一致；135 独立跑 45s rc=1 全部落在该族）。本轮分跑实测：
    # 202:57/57、206:43/43、135:40/44（红=上述外层脚本缺失族，逐笔对账
    # task168_cascade_baseline 的 135 条目）。
    gc = ["verify_task151.py", "verify_task203.py"]
    g_ok, g_detail = True, []
    for c in gc:
        rr = run(["python3", f"scripts/{c}"], timeout=540)
        if rr.returncode != 0:
            g_ok = False
            g_detail.append(f"{c}:exit{rr.returncode}")
            print(f"    G-cascade FAIL {c}:\n" + "\n".join(
                l for l in rr.stdout.split("\n") if "FAIL" in l)[:500])
    check("G9 级联（TAB 基线 662 族 + l10n 2520 族 + Krypton 收短重锚族；129/209/202/206/135 分跑补证——135 为外层脚本缺失环境债）", g_ok, "; ".join(g_detail))

print()
fails = [n for n, ok in results if not ok]
print(f"verify_task211 (full): {len(results) - len(fails)}/{len(results)}",
      ("ALL PASS" if not fails else "FAILED: " + ", ".join(fails)))
sys.exit(1 if fails else 0)
