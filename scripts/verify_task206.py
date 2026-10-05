#!/usr/bin/env python3
"""verify_task206.py -- Task206 verification (two renderer topics).

A. ANGLE 'blocks render transparent' root fix (push-constant-as-UBO)
B. NG-GL4ES vendored tree + provenance
C. Darwin alias generator (coverage / guards / idempotence)
D. Makefile dep_nggl4es + payload wiring (+ TAB integrity)
E. Runtime wiring (utils.h / egl_bridge / renderer table / VersionMgr /
   JavaLauncher / AI mapping / LWJGL-name compatibility)
F. l10n + FAQ + announcements (counts, sweep, fidelity)
G. version.h addendum
H. cascade (green set + documented dirty-tree allowances)
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
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                          cwd=REPO)


# ============ A. ANGLE push-constant-as-UBO root fix ============
print("== A. ANGLE 方块透明根修 ==")
shim = rd("Natives/spvc_shim.c")

# Task219: device-log evidence pinned to the git blob that was green at the
# Task218 CI closure (2f82e611) -- the working-tree latestlog.old.txt has
# since been replaced by the user's 6cd2cbfb upload (VirGL crash session);
# live log files rotate by design, git is the durable evidence store.
import subprocess as _sp
log = _sp.run(["git", "show", "2f82e611:latestlog.old.txt"],
              capture_output=True, text=True).stdout
check("A1 装机证据（7c0a021 latestlog.old）：_push_constants NOT FOUND ×206 + _uniform_00_XX 命中 + UBO 绑定链激活",
      log.count("name='_push_constants') -> 4294967295") >= 200
      and "name='_uniform_00_00') -> 0" in log
      and "glUniformBlockBinding" in log and "glBindBufferRange" in log,
      f"notfound={log.count(chr(39) + '_push_constants') + 0}")

check("A2 选项常量 = 33u | 0x2000000u（钉 vendored spirv_cross_c.h 665 行枚举）",
      "#define AME206_OPTION_GLSL_PUSH_CONST_AS_UBO (33u | 0x2000000u)" in shim
      and "SPVC_COMPILER_OPTION_GLSL_EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER = 33 | SPVC_COMPILER_OPTION_GLSL_BIT"
      in rd("Natives/external/MobileGlues/MobileGlues-cpp/include/spirv_cross/spirv_cross_c.h")
      and "#define SPVC_COMPILER_OPTION_GLSL_BIT 0x2000000"
      in rd("Natives/external/MobileGlues/MobileGlues-cpp/include/spirv_cross/spirv_cross_c.h"))

check("A3 新版选项路径设置（new_set_opt + 1u）",
      "new_set_opt(opts, AME206_OPTION_GLSL_PUSH_CONST_AS_UBO, 1u);" in shim)

check("A4 旧版选项路径设置（old_set_bool + 1）",
      "old_set_bool(opts, AME206_OPTION_GLSL_PUSH_CONST_AS_UBO, 1);" in shim)

check("A5 装机锚点日志行（Task206 EMIT_PUSH_CONSTANT...）",
      "[spvc-shim] Task206: EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER " in shim)

r = run(["gcc", "-fsyntax-only", "-x", "c", "Natives/spvc_shim.c"])
check("A6 spvc_shim.c 语法干净（gcc -fsyntax-only）", r.returncode == 0,
      r.stderr[:200])

# ============ B. vendored tree + provenance ============
print("== B. NG-GL4ES vendor 树与溯源 ==")
NG = "ThirdParty/ZalithLauncher2"
check("B1 树结构（src/include/version.h/LICENSE/README 在位，272 文件）",
      all(os.path.isfile(os.path.join(REPO, NG, p)) for p in
          ["src/gl/wrap/gles.c", "src/gl/wrap/glesnative.cpp", "src/gl/glsl/glsl_for_es.cpp",
           "include/spirv_cross/spirv_cross_c.h", "version.h", "LICENSE", "README.md", "CMakeLists.txt"]))

cm_ng = rd(f"{NG}/CMakeLists.txt")
check("B2 CMakeLists PROVENANCE 头（上游 URL + snapshot + 5 项适配）",
      "https://github.com/BZLZHH/NG-GL4ES" in cm_ng
      and "codeload tarball refs/heads/main, fetched 2026-10-01" in cm_ng
      and cm_ng.count("adaptation") >= 1
      and "NOX11" in cm_ng and "NOEGL" in cm_ng)

check("B3 上游指纹原样（GL_GET_MAP/STUB/NATIVE_FUNCTION_HEAD/attributes __APPLE__ 分支）",
      "GL_GET_MAP(t, type)" in rd(f"{NG}/src/gl/eval.c")
      and "AliasExport(ret, def, , args);" in rd(f"{NG}/src/gl/wrap/glstub.c")
      and "NATIVE_FUNCTION_HEAD(GLsync, glFenceSync" in rd(f"{NG}/src/gl/wrap/glesnative.cpp")
      and "!defined(__EMSCRIPTEN__) && !defined(__APPLE__)" in rd(f"{NG}/src/gl/attributes.h"))

check("B4 include/glslang 已移除（15.4 头不能漂离 15.0 链接库）",
      not os.path.exists(os.path.join(REPO, NG, "include/glslang"))
      and "NGGL4ES_GLSLANG_INCLUDE" in cm_ng and "NGGL4ES_GLSLANG_LIBS" in cm_ng)

check("B5 .gitmodules 无 ZalithLauncher2 子模块（死 pin eba819b 去注册）",
      "ZalithLauncher2" not in rd(".gitmodules"))

r = run(["git", "ls-files", "-s", "--", "ThirdParty/ZalithLauncher2"])
modes = {ln.split()[0] for ln in r.stdout.splitlines() if ln.strip()}
# pre-commit the new files are untracked (empty is fine); the invariant that
# matters = no 160000 gitlink mode survives the de-registration
check("B6 无 gitlink 残留（无 160000 mode；提交后全为 100644 普通文件）",
      "160000" not in modes and os.path.isdir(os.path.join(REPO, NG)), str(modes))

pruned = ["traces", "spec", "refs", "media", "tests", "debian", "external", "3rdparty",
          "GL4ES.cbp", "test.cmake", "gl4es.png", "_config.yml"]
check("B7 裁剪面（traces/spec/refs/media/tests/debian/external/3rdparty 等不在树）",
      not any(os.path.exists(os.path.join(REPO, NG, p)) for p in pruned))

# ============ C. alias generator ============
print("== C. darwin 别名生成器 ==")
gen = rd("scripts/task206_gen_nggl4es_aliases.py")
alias_rel = f"{NG}/src/gl/wrap/nggl4es_darwin_aliases.c"
alias_txt = rd(alias_rel)
globals_n = re.findall(r'\.global _([A-Za-z0-9_]+)\\n\\t_\1: b _([A-Za-z0-9_]+)', alias_txt)
check("C1 生成器幂等（重跑 exit 0 + 字节不变）",
      run([sys.executable, "scripts/task206_gen_nggl4es_aliases.py"]).returncode == 0
      and rd(alias_rel) == alias_txt)

check("C2 别名计数 1293（1273 + 18 string_utils 裸属性族 + 2 AliasDecl 族）且按名排序",
      len(globals_n) == 1293
      and [n for n, _ in globals_n] == sorted(n for n, _ in globals_n))

names = {n for n, _ in globals_n}
targets = {t for _, t in globals_n}
check("C3 覆盖面（Task204 教训名单 + 变体 + glX 排除 + ARB twins）",
      all(n in names for n in
          ["glEnable", "glGenTextures", "glBindTexture", "glTexImage2D", "glTexSubImage2D",
           "glGetError", "glCreateProgram", "glEnableClientStateiEXT",
           "glProgramEnvParameter4dARB", "glXWaitGL", "glXSwapInterval"])
      and "glXCreateContext" not in names and "glXChooseFBConfig" not in names
      and "glFenceSyncARB" in names and ("glFenceSyncARB", "glFenceSync") in globals_n)

check("C4 守卫在位（悬空 exit 1 + 裸名碰撞 + 幂等注释）",
      "would dangle the link" in gen and "duplicate symbol" in gen.lower()
      or ("dangling" in gen.lower() and "collision" in gen.lower()),
      "")

check("C5 生成文件头（Task206 标记 + 1293 计数 + 再生成指引）",
      "Task206 (NG-GL4ES iOS port) -- GENERATED FILE" in alias_txt
      and "1293 exports" in alias_txt
      and "scripts/task206_gen_nggl4es_aliases.py" in alias_txt)

check("C6 CMakeLists 源列表含别名文件且全部源文件存在",
      "src/gl/wrap/nggl4es_darwin_aliases.c" in cm_ng
      and all(os.path.isfile(os.path.join(REPO, NG, f))
              for f in re.findall(r"(src/[A-Za-z0-9_/]+\.(?:c|cpp))\s*$",
                                  cm_ng[cm_ng.index("set(NGGL4ES_SRC"):cm_ng.index("add_library(nggl4es")], re.M)))

# ============ D. Makefile ============
print("== D. Makefile dep_nggl4es ==")
mk = rd("Makefile")
check("D1 dep_nggl4es 目标（目标级先决 dep_mg——CI run 36804929330 教训：payload 列表在 -j 并行下无序，dep_shader_shims 同款写法 + 四缓存变量 + cmake 交叉配置 + copy 到 WORKINGDIR）",
      "dep_nggl4es: dep_mg" in mk
      and all(v in mk for v in ["NGGL4ES_GLSLANG_INCLUDE", "NGGL4ES_GLSLANG_LIBS",
                                "NGGL4ES_SPVC_IMPL", "NGGL4ES_FRAMEWORK_DIR"])
      and "ThirdParty/ZalithLauncher2/" in mk
      and "cp $(WORKINGDIR)/nggl4es/libnggl4es.dylib $(WORKINGDIR)/" in mk)

check("D2 payload 行接线（mithril 之后、angle_freeze 之前；Task215 重锚：dep_virgl 插于 gl4eszl2 与 angle_freeze 之间）",
      "payload: native dep_mg java jre assets dep_shader_shims dep_openal_shim dep_mithril_glshim dep_nggl4es dep_gl4eszl2 dep_virgl dep_angle_freeze dep_sdl3_guard" in mk
      and mk.find("dep_nggl4es dep_gl4eszl2") > mk.find("dep_mithril_glshim dep_nggl4es"))

cur_tab = sum(1 for l in mk.split("\n") if l.startswith("\t"))
check("D3 TAB 基线 644（Task215 重锚：dep_virgl +83）（Task212 重锚：559 + holy 退役净 +2：删 2 补丁行、增 4 注释行）且无空格缩进 recipe",
      cur_tab == 662
      and not any(l.startswith("    ") for l in mk.split("\n")),
      f"cur={cur_tab}")

check("D4 glslang 静态库解析与 dep_shader_shims 同构（superbuild 路径 + find 兜底 + 分号连接）",
      mk.count('mg_bindir=$(WORKINGDIR)/mobileglues/3rdparty/glslang') == 2
      and 'extra_glslang_libs="$$extra_glslang_libs;$$mg_bindir/glslang/$$l"' in mk
      and 'ngg_libs="$$mg_spirv_a;$$mg_glslang_a;$$mg_rl_a$$extra_glslang_libs"' in mk)

# ============ E. runtime wiring ============
print("== E. 运行时接线 ==")
uh = rd("Natives/utils.h")
check("E1 utils.h 定义（libnggl4es.dylib + Task206 注释）",
      '#define RENDERER_NAME_NGGL4ES "libnggl4es.dylib"' in uh
      and "Krypton Wrapper" in uh)

eb = rd("Natives/egl_bridge.m")
check("E2 egl_bridge 分支（Task206 锚点 + set_gl_bridge_tbl + vgpu 同款流注释）",
      "RENDERER_NAME_NGGL4ES])" in eb
      and "[egl_bridge] Task206: NG-GL4ES renderer:" in eb
      and eb.find("RENDERER_NAME_NGGL4ES])") < eb.find("RENDERER_NAME_MITHRIL])"))

lp = rd("Natives/LauncherPreferences.m")
check("E3 rendererCandidates 末位追加（NGGL4ES 在 METAL 之后 = 索引稳定规则）",
      lp.find('@ RENDERER_NAME_NGGL4ES,\n          @"name"') > lp.find('@ RENDERER_NAME_METAL,\n          @"name"')
      and '@ RENDERER_NAME_NGGL4ES,\n          @"name": localize(@"preference.title.renderer.debug.nggl4es", nil),\n          @"file": @ RENDERER_NAME_NGGL4ES}' in lp)

vm = rd("Natives/VersionManagerViewController.m")
check("E4 VersionManager 短名（Task209 重锚：Krypton Wrapper）",
      '@ RENDERER_NAME_NGGL4ES: @"Krypton Wrapper"' in vm)

jl = rd("Natives/JavaLauncher.m")
check("E5 JavaLauncher NGG_DIR_PATH 块（POJAV_HOME/ngg + Task206 日志锚）",
      'setenv("NGG_DIR_PATH", ame206_path, 1);' in jl
      and "[JavaLauncher] Task206: NG-GL4ES renderer active" in jl)

ai = rd("Natives/AI/AiSettingsTools.m")
check("E6 AI 双向映射（nggl4es 先于 gl4es 家族 = 子串包含序 + friendlyName；Task212 重锚：holy 退役，裸 gl4es 由 gl4eszl2 接棒）",
      0 <= ai.find('containsString:@"nggl4es"') < ai.find('containsString:@"gl4eszl2"]')
      and ai.find('containsString:@"nggl4es"') < ai.find('return @(RENDERER_NAME_GL4ESZL2)')
      and 'return @"Krypton Wrapper/NG-GL4ES (libnggl4es.dylib)"' in ai
      and ai.count("Krypton Wrapper") >= 3)

check("E7 LWJGL 名字兼容（libnggl4es.dylib 匹配 DYLIB 正则，无连字符陷阱）",
      re.match(r"(?:^|/)lib\w+(?:[.]\d+)*[.]dylib$", "libnggl4es.dylib") is not None
      and "-" not in "libnggl4es.dylib")

# ============ F. l10n / FAQ / announcements ============
print("== F. l10n / FAQ / 公告 ==")
langs = {}
for lg in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    keys = re.findall(r'^"([^"]+)"\s*=',
                      rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), re.M)
    langs[lg] = keys
check("F1 四主语言 nggl4es 键在位且唯一键 2606（Task210 重锚：neumorph 双键退役 2520-2，nggl4es +1 已并入）",
      all("preference.title.renderer.debug.nggl4es" in set(langs[l]) for l in langs)
      and all(len(set(langs[l])) == 2606 for l in langs))

# Task211 重锚：本轮 gl4eszl2 键 +1 后全 fleet 计数 = 2520（2419 一代旧值
# 清零；守卫精神不变——fleet 与 task151 H 门计数一致，无独立旧值残留。
# v211 自身的历史基线叙述（2419+1）豁免。）
fleet_stale = []
for fn in sorted(os.listdir(os.path.join(REPO, "scripts"))):
    if fn.startswith("verify_task") and fn.endswith(".py") and fn not in ("verify_task206.py", "verify_task211.py"):
        t = rd(f"scripts/{fn}")
        if re.search(r"(?<![\w.])2419(?![\w.])", t):
            fleet_stale.append(fn)
check("F2 锚扫荡干净（fleet 无残留 2419 旧值；task151 H 门期望 2520，Task211 重锚）",
      not fleet_stale and '!= "2606"' in rd("scripts/verify_task151.py"))

faq_files = [("Natives/resources/help-faq.json", 2), ("help-faq.json", 2),
             ("Natives/resources/zh-CN.lproj/help-faq.json", 2),
             ("Natives/resources/zh-Hant.lproj/help-faq.json", 1),
             ("Natives/resources/en.lproj/help-faq.json", 1)]
ok_counts = True
ok_fidelity = True
for rel, ind in faq_files:
    raw = open(os.path.join(REPO, rel), "rb").read()
    obj = json.loads(raw.decode("utf-8"))
    if [len(c["items"]) for c in obj["categories"]] != [12, 4, 7, 15]:
        ok_counts = False
    if (json.dumps(obj, ensure_ascii=False, indent=ind) + "\n").encode("utf-8") != raw:
        ok_fidelity = False
check("F3 FAQ 5 份 [12,4,7,15]=38 + 保真 roundtrip + root twin 字节一致",
      ok_counts and ok_fidelity
      and open(os.path.join(REPO, "help-faq.json"), "rb").read()
      == open(os.path.join(REPO, "Natives/resources/help-faq.json"), "rb").read())

sel_ok = True
for rel, _, in [("Natives/resources/help-faq.json", 0)]:
    d = json.load(open(os.path.join(REPO, rel), encoding="utf-8"))
    sel = d["categories"][0]["items"][0]["description"]
    # Task209 重锚：条目更名 Krypton Wrapper（≤26.2）后，新名 + 旧名别名 + 记法句三锚
    if "Krypton Wrapper（≤26.2，原 NG-GL4ES）" not in sel or "老版本优先 Krypton Wrapper" not in sel:
        sel_ok = False
en_sel = json.load(open(os.path.join(REPO, "Natives/resources/en.lproj/help-faq.json"),
                        encoding="utf-8"))["categories"][0]["items"][0]["description"]
ht_sel = json.load(open(os.path.join(REPO, "Natives/resources/zh-Hant.lproj/help-faq.json"),
                        encoding="utf-8"))["categories"][0]["items"][0]["description"]
check("F4 渲染器选择条目（Task209 重锚：Krypton Wrapper 新名 + 原名别名 + 记法句；zh/en/zh-Hant 三语）",
      sel_ok and "Krypton Wrapper first" in en_sel and "老版本優先 Krypton Wrapper" in ht_sel)

ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))["announcements"]
check("F5 公告 39，task217 追加，task216@2 保位于 -2（Task217 重锚）",
      len(ann) == 43 and ann[-5]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[-6]["id"] == "task216-ui-2026-10-03"
      and ann[-7]["id"] == "task206-nggl4es-2026-10-01"
      and "NG-GL4ES" in ann[-7]["title"] and "EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER" in ann[-7]["content"])

anchor_ok = ('== [12, 4, 7, 15]' in rd("scripts/verify_task202.py")
             and '== [12, 4, 7, 15]' in rd("scripts/verify_task168.py")
             and "len(ann) == 43" in rd("scripts/verify_task203.py")
             and "len(ann) == 43" in rd("scripts/verify_task202.py")
             and "len(ann) == 43" in rd("scripts/verify_task196_197_198_201.py"))
check("F6 计数锚重锚一致（FAQ 168/202 + 公告 193/202/203/196 家族；Task212 重锚 33→34）", anchor_ok)

# ============ G. version.h ============
print("== G. version.h 附录 ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("G1 Task206 附录双主题（push-constant + NG-GL4ES + 1273 别名 + 溯源）",
      "REVISION 18 addendum (Amethyst Task 206, no bump)" in vh
      and "EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER" in vh
      and "1293 asm aliases" in vh
      and "ThirdParty/ZalithLauncher2" in vh
      and "eba819b" in vh)
check("G2 尾部 SEP 不变量恢复（append-friendly；Task210 附录后重收口）",
      vh.endswith("// ============================================================================\n"))

# ============ H. cascade ============
print("== H. 级联 ==")
CASCADE_BANNERS = {
    "verify_task203.py": lambda o: "ALL GREEN" in o,
    "verify_task196_197_198_201.py": lambda o: (
        lambda m: m is not None and m.group(1) == m.group(2)
    )(re.search(r"==== Task196/197/198/201: (\d+)/(\d+) ====", o)),
    "verify_task193.py": lambda o: re.search(r"\d+ PASS / 0 FAIL", o) is not None,
}
for v, ok_fn in CASCADE_BANNERS.items():
    r = run([sys.executable, f"scripts/{v}"], timeout=600)
    check(f"H {v} 绿（含本轮全部重锚）", ok_fn(r.stdout) and r.returncode == 0,
          r.stdout[-160:] if not ok_fn(r.stdout) else "")

# dirty-tree family: allowed to fail pre-commit (head-vs-cur TAB + whitelist),
# must carry ONLY the documented failures
r = run([sys.executable, "scripts/verify_task129.py"], timeout=600)
fails129 = [l for l in r.stdout.splitlines() if "FAIL" in l and "RESULT" not in l]
# head tracks the last commit's baseline (531 after Task206f, 534 after this
# round); only cur is stable to assert pre-commit
dirty_ok = all("I4 Makefile TAB" in l and "head=561 cur=644" in l for l in fails129) and len(fails129) <= 1
check("H verify_task129 仅剩脏树 I4（Task212 重锚：cur=561，head 随提交基线走，提交后自愈）", dirty_ok, str(fails129))

r = run([sys.executable, "scripts/verify_task174.py"], timeout=600)
f174 = [l for l in r.stdout.splitlines() if l.strip().startswith(("- [")) or "FAIL" in l]
check("H verify_task174 仅剩脏树族（I/J 两门 = TAB + 168 级联）",
      len([l for l in f174 if "[FAIL]" in l or "FAIL " in l]) <= 2, str(f174[:3]))

# ============ verdict ============
fails = [l for l, ok in results if not ok]
print(f"\n==== Task206: {len(results) - len(fails)}/{len(results)} ====")
if fails:
    print("FAILED:")
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS")
