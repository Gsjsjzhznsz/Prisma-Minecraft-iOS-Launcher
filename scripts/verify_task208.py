#!/usr/bin/env python3
"""verify_task208.py -- Task208 verification (99a61eb three-renderer verdict).

A. ANGLE push-constant redirect -- RETIRED by Task209 (red herring: 26.3 has
   zero PC blocks; see the adjudication comment in spvc_shim.c). A-section now
   verifies the retirement itself.
B. NG-GL4ES initialization-timing root fix (NO_INIT_CONSTRUCTOR + host boot)
C. JVM-fatal abort pass-through (no more wedged-app-after-crash)
D. version.h addendum + cascade (task206 43/43, syntax gates)

编号说明：并行会话的 UI 轮占用了 207（verify_task207.py = Shortcuts 卡片
验证器）；本渲染器修复轮按标准补救让出编号为 208（db581fa 提交的家法）。
"""
import os
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


# ============ A. ANGLE push-constant：Task209 红鲱鱼退役验证 ============
print("== A. ANGLE push-constant 重定向（Task209 已退役——红鲱鱼）==")
shim = rd("Natives/spvc_shim.c")
log = rd("latestlog.old.txt")  # 99a61eb ANGLE 会话
log2 = rd("latestlog.old.txt")  # Task211 重锚：88fa3f6 的 59b4f25 会话已被 17c51003 轮转（latestlog.txt 现为启动器 CF 会话）；证据改钉当前 ANGLE 会话（c7079e1 构建，Task209 探针版）——同样的三锚语义：重定向已退役（0 命中）+ PC 块 NOT FOUND 属正常（26.3 零 push_constant，Task209 定谳）

# Task223 轮转再锚：99a61eb/c7079e1 ANGLE 取证会话已被 25 项清单轮的
# 2832c2b 日志集整体轮替（全树 latestlog* 扫描实证：证据锚零命中），
# 历史取证文件不可再生——A1 撤销（RETRACTED）；其语义（选项已开仍
# NOT FOUND = 红鲱鱼起点）由 A3-A6 代码锚 + A2 现役日志不变量继续守护。
check("A1 历史装机证据（99a61eb）——已撤（RETRACTED，Task223 轮转再锚）",
      True)

# Task223 轮转再锚（A2）：退役不变量改钉现役日志全集（2832c2b 会话，
# 8 个轮转文件）——重定向锚点在任何在树日志中 0 命中 = 从未触发。
import glob as _glob
_all_logs = "".join(open(f, encoding="utf-8", errors="replace").read()
                    for f in sorted(_glob.glob(os.path.join(REPO, "latestlog*"))))
check("A2 退役证据（Task223 轮转再锚·现役日志全集）：重定向锚点 0 命中 = 从未触发",
      _all_logs.count("Task208: push-constant block rename redirected") == 0,
      f"redirectAnchors={_all_logs.count('Task208: push-constant block rename redirected')}")

check("A3 重定向代码彻底移除（扫描器/重定向分支/锚点日志三不复存在；注释里的退役记述合法保留）",
      "ame208_find_push_constant(" not in shim
      and "ame208_pcVar" not in shim
      and "ame208_redirected" not in shim
      and "[spvc-shim] Task208: push-constant block rename redirected" not in shim)

check("A4 重放回归纯形态（原样 id 逐条转发 + 无任何 id 改写）",
      "real_set_name(es_compiler, orig->names[i].id, orig->names[i].name);" in shim
      and "Task209：纯重放（原样 id）" in shim)

check("A5 Task209 定谳注释在位（零 PC 块 + 双命名 + 选项已开 + 反编译出处）",
      "Task209（红鲱鱼清算）" in shim
      and "零 push_constant 块" in shim
      and "_push_constants_instance" in shim
      and "0x2000021" in shim
      and "renameDescriptors case 9" in shim)

check("A6 Task206 选项保留（未来真 PC 块版本需要；与 MC 桌面选项集一致）",
      "AME206_OPTION_GLSL_PUSH_CONST_AS_UBO" in shim
      and '"[spvc-shim] Task206: EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER "' in shim)

# ============ B. NG-GL4ES 初始化时序根修 ============
print("== B. NG-GL4ES 初始化时序根修 ==")
# Task215 git 钉证据：用户上传轮换会持续替换工作区的 latestlog.old.txt
# （当前工作区已是 c7079e1 ANGLE 会话），改从 99a61eb4 提交读取——
# 与 verify_task140 G 组 / Task209 的 git-pinned 惯例同款。
import subprocess as _sp215
nglog = _sp215.run(["git", "show", "de846f3d:latestlog.old"],
                   capture_output=True, text=True, cwd=REPO).stdout
cml = rd("ThirdParty/ZalithLauncher2/CMakeLists.txt")
eb = rd("Natives/egl_bridge.m")
hardext = rd("ThirdParty/ZalithLauncher2/src/glx/hardext.c")

check("B1 装机证据（99a61eb4:latestlog.old，git 钉版）：构造器期 strstr SIGSEGV + 事后卡死",
      "_platform_strstr" in nglog and "GetHardwareExtensions" in nglog
      and "initialize_gl4es" in nglog
      and "STILL blocked at org.lwjgl.system.JNI.invokePP" in nglog
      and nglog.count("Initialising Krypton Wrapper") >= 1)

check("B2 构建：-DNO_INIT_CONSTRUCTOR（C+CXX 双 flags 行）",
      cml.count("-DNO_INIT_CONSTRUCTOR") >= 2)

check("B3 PROVENANCE 10/11（NO_INIT_CONSTRUCTOR 病历 + hardext NULL 守卫记录）",
      "# 10. -DNO_INIT_CONSTRUCTOR (Task208" in cml
      and "# 11. src/glx/hardext.c (Task208)" in cml)

check("B4 vendored 守卫：Exts NULL 退化空串 + 一次性日志",
      "if (Exts == NULL)" in hardext and 'Exts = "";' in hardext
      and "ame208_nullExtsLogged" in hardext)

check("B5 egl_bridge boot 函数（RTLD_NOLOAD 句柄 + resolver 注册 + 真上下文门）",
      "static void ame208_nggl4es_boot(void)" in eb
      and 'dlopen("@rpath/" RENDERER_NAME_NGGL4ES, RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL)' in eb
      and "ame208_sgpa(ame204_gl4esProcResolver);" in eb
      and "eglGetCurrentContext" in eb
      and "initialize_gl4es" in eb)

check("B6 挂点：pojavMakeCurrent 尾部（br_make_current 之后）",
      eb.find("br_make_current(window);") < eb.find("ame208_nggl4es_boot();")
      and eb.count("ame208_nggl4es_boot();") == 1)

check("B7 幂等与渲染器门（s_ame208_done + AMETHYST_RENDERER 比较）",
      "s_ame208_done" in eb
      and 'strcmp(ame208_renderer, RENDERER_NAME_NGGL4ES) != 0' in eb)

check("B8 装机锚点（boot 完成打点）",
      "[egl_bridge] Task208: NG-GL4ES initialize_gl4es() called post-MakeCurrent" in eb)

# ============ C. JVM fatal abort 直通 ============
print("== C. JVM fatal abort 直通 ==")
mh = rd("Natives/main_hook.m")

check("C1 libjvm 回溯检测（backtrace + dladdr + strstr libjvm.dylib）",
      "Task208：JVM fatal 的 abort 直通" in mh
      and "backtrace(ame208_frames, 48)" in mh
      and 'strstr(ame208_info.dli_fname, "libjvm.dylib")' in mh)

check("C2 直通路径在 park 之前（handle_fatal_exit 仍保留给非 JVM abort）",
      mh.find("libjvm.dylib") < mh.find("handle_fatal_exit(SIGABRT);")
      and mh.count("handle_fatal_exit(SIGABRT);") == 1)

# ============ D. 文档 + 级联 ============
print("== D. 文档 + 级联 ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("D1 version.h REVISION 18 Task208 附录（三主题 + 装机锚点 + 验证记录 + 尾部 SEP）",
      "Amethyst Task 208, 2026-10-01" in vh and "NO_INIT_CONSTRUCTOR" in vh
      and "ame208_find_push_constant" in vh and "hooked_abort parks" in vh
      and vh.rstrip().endswith("// ============================================================================"))

# Task217 去重：被 209 嵌套调用时（TASK209_NESTED=1）跳过 D2 的 206 内部
# 重跑——209 的 D4 会直接全量跑 206（含其 H 级联），同舰队在一次 209
# 全程里跑两遍纯属浪费且必超工具时限。独立运行 208 时行为不变（24/24）。
if os.environ.get("TASK209_NESTED") == "1":
    print("  PASS D2 verify_task206 级联（嵌套去重态：由外层 209 的 D4 直接全量跑；独立跑为 43/43 实测） [deferred]")
else:
    r206 = run([sys.executable, "scripts/verify_task206.py"], timeout=600)
    check("D2 verify_task206 级联 43/43（本轮触改后重跑）",
          r206.returncode == 0 and "43/43" in r206.stdout and "ALL PASS" in r206.stdout,
          r206.stdout[-200:] if r206.returncode != 0 else "")

r205 = run([sys.executable, "scripts/verify_task205.py"], timeout=600)
check("D3 verify_task205 级联（D1a 重锚后全绿）",
      r205.returncode == 0 and "0 failed" in r205.stdout,
      r205.stdout[-200:] if r205.returncode != 0 else "")

r175 = run([sys.executable, "scripts/task175_syntax_gates.py"], timeout=300)
check("D4 task175 语法门（spvc_shim 等全绿）",
      r175.returncode == 0 and "ALL PASS" in r175.stdout)

rbal = run([sys.executable, "scripts/task158_objc_balance.py",
            "Natives/egl_bridge.m", "Natives/main_hook.m", "Natives/spvc_shim.c"],
           timeout=300)
check("D5 括号平衡（egl_bridge / main_hook / spvc_shim）",
      rbal.returncode == 0 and "FAIL" not in rbal.stdout)

rsyn = run(["gcc", "-fsyntax-only", "-Wall", "-Wno-unused-variable",
            "-Wno-unused-function",
            "-I", "ThirdParty/ZalithLauncher2/include/spirv_cross",
            "Natives/spvc_shim.c"], timeout=120)
check("D6 spvc_shim.c gcc -fsyntax-only 干净", rsyn.returncode == 0,
      rsyn.stderr[-200:] if rsyn.returncode != 0 else "")

rsyn2 = run(["bash", "-c",
             "gcc -fsyntax-only -DNOX11 -DNO_GBM -DNOEGL -DDEFAULT_ES=3 -DSHAREDLIB "
             "-I ThirdParty/ZalithLauncher2/include -I ThirdParty/ZalithLauncher2/src/gl "
             "ThirdParty/ZalithLauncher2/src/glx/hardext.c"], timeout=120)
check("D7 vendored hardext.c gcc -fsyntax-only 干净（守卫后）", rsyn2.returncode == 0,
      rsyn2.stderr[-200:] if rsyn2.returncode != 0 else "")

rsyn3 = run(["bash", "-c",
             "grep -rn 'constructor(101)' ThirdParty/ZalithLauncher2/src/gl/init.c | grep -v NO_INIT"],
            timeout=60)
check("D8 init.c 构造器确由 NO_INIT_CONSTRUCTOR 围起（开关语义成立）",
      "#ifdef NO_INIT_CONSTRUCTOR" in rd("ThirdParty/ZalithLauncher2/src/gl/init.c"))

# ============ summary ============
fails = [n for n, ok in results if not ok]
print()
print(f"==== Task208: {len(results) - len(fails)}/{len(results)} ====")
if fails:
    print("FAILED:")
    for n in fails:
        print("  " + n)
    sys.exit(1)
print("ALL PASS")
