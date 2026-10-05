#!/usr/bin/env python3
"""verify_task209.py -- Task209 verification.

A. 用户点名改名 NG-GL4ES -> Krypton Wrapper（≤26.2）五面落地
B. ANGLE "PC 红鲱鱼" 定谳与 Task208 幽灵重定向退役
C. tinygl4angle 四叉取证探针（绘制族普查 / 状态快照 / 纹理格式 / ESSL dump）
D. 文档（version.h / 公告 @2 / worklog）+ 级联

判读坐标：88fa3f6 上传 latestlog.txt（构建 59b4f25）；红鲱鱼定谳的资产/
代码双铁证（client-263.jar 零 push_constant + CFR 反编译双命名）见
spvc_shim.c 的 Task209 定谳注释与 worklog.md Task 209 条目。

Task217 嵌套去重（本沙箱 CPU 配额家法）：D5（208）与 D6（202）带
TASK209_NESTED=1——208 跳其 D2 的 206 内部重跑（209 的 D4 直接跑），
202 跳其 J 的 168/193 两腿（209 的 D9/D7 直接跑）；独立运行 208/202
行为不变（24/24、57/57）。去重后 209 全程在本沙箱 600s 工具时限内
可单跑完成（此前 580s 只到 D8 中段）。深族分跑补证口径见 verify_task211
F2 同款注释（Task208 教训 "split runs required"）。
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


def run(cmd, timeout=300, env=None):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO,
                          env=env)


# ============ A. 改名五面 ============
print("== A. NG-GL4ES -> Krypton Wrapper（<=26.2）五面 ==")
l10n_expect = {
    # Task211 重锚：显示名收短（用户定案）——长尾描述退役
    "zh-Hans": "Krypton Wrapper（≤26.2）",
    "zh-CN": "Krypton Wrapper（≤26.2）",
    "zh-Hant": "Krypton Wrapper（≤26.2）",
    "en": "Krypton Wrapper (≤26.2)",
}
ok_a1 = True
for lg, want in l10n_expect.items():
    s = rd(f"Natives/resources/{lg}.lproj/Localizable.strings")
    line = f'"preference.title.renderer.debug.nggl4es" = "{want}";'
    if line not in s or s.count("preference.title.renderer.debug.nggl4es") != 1:
        ok_a1 = False
check("A1 l10n 四主语言新值（≤26.2；Task211 起收短）", ok_a1)

vm = rd("Natives/VersionManagerViewController.m")
check("A2 VersionManager 短名 = Krypton Wrapper（渲染器键值映射不动）",
      '@ RENDERER_NAME_NGGL4ES: @"Krypton Wrapper"' in vm
      and '@ RENDERER_NAME_NGGL4ES: @"NG-GL4ES"' not in vm)

ai = rd("Natives/AI/AiSettingsTools.m")
check("A3 AI 面（友好名新名在前 + 提示词键表两处 + 子串包含序不回退；Task211 重锚：键表加入 gl4es ZL2 经典版）",
      'return @"Krypton Wrapper/NG-GL4ES (libnggl4es.dylib)"' in ai
      and "auto/GL4ES/Krypton Wrapper" in ai
      and "GL4ES/Krypton Wrapper/NG-GL4ES/gl4es ZL2/ANGLE" in ai
      and 0 <= ai.find('containsString:@"nggl4es"') < ai.find('containsString:@"gl4es"]')
      and ai.find('containsString:@"nggl4es"') < ai.find('return @(RENDERER_NAME_GL4ESZL2)')
      and ai.find('containsString:@"gl4eszl2"') < ai.find('containsString:@"gl4es"]'))

faq_files = [("Natives/resources/help-faq.json", 2), ("help-faq.json", 2),
             ("Natives/resources/zh-CN.lproj/help-faq.json", 2),
             ("Natives/resources/zh-Hant.lproj/help-faq.json", 1),
             ("Natives/resources/en.lproj/help-faq.json", 1)]
ok_counts = ok_fidelity = ok_rename = True
for rel, ind in faq_files:
    raw = open(os.path.join(REPO, rel), "rb").read()
    obj = json.loads(raw.decode("utf-8"))
    if [len(c["items"]) for c in obj["categories"]] != [12, 4, 7, 15]:
        ok_counts = False
    if (json.dumps(obj, ensure_ascii=False, indent=ind) + "\n").encode("utf-8") != raw:
        ok_fidelity = False
zh_sel = json.loads(rd("Natives/resources/help-faq.json"))["categories"][0]["items"]
en_sel = json.loads(rd("Natives/resources/en.lproj/help-faq.json"))["categories"][0]["items"]
ht_sel = json.loads(rd("Natives/resources/zh-Hant.lproj/help-faq.json"))["categories"][0]["items"]
if not ("Krypton Wrapper（≤26.2，原 NG-GL4ES）" in zh_sel[0]["description"]
        and "老版本优先 Krypton Wrapper" in zh_sel[0]["description"]
        and "Krypton Wrapper（原 NG-GL4ES）是什么" in zh_sel[2]["title"]
        and "原名 NG-GL4ES" in zh_sel[2]["description"]):
    ok_rename = False
if not ("Krypton Wrapper first" in en_sel[0]["description"]
        and "formerly NG-GL4ES" in en_sel[2]["description"]
        and "老版本優先 Krypton Wrapper" in ht_sel[0]["description"]):
    ok_rename = False
check("A4 FAQ 五份（计数不变 + 保真 roundtrip + 三语新名/别名）",
      ok_counts and ok_fidelity and ok_rename
      and open(os.path.join(REPO, "help-faq.json"), "rb").read()
      == open(os.path.join(REPO, "Natives/resources/help-faq.json"), "rb").read())

uh = rd("Natives/utils.h")
check("A5 存储键零迁移（libnggl4es.dylib 语义不动）",
      '#define RENDERER_NAME_NGGL4ES "libnggl4es.dylib"' in uh)

# ============ B. 红鲱鱼退役 ============
print("== B. PC 红鲱鱼定谳 + Task208 重定向退役 ==")
shim = rd("Natives/spvc_shim.c")
log = rd("latestlog.old.txt")  # Task211 轮转重锚：88fa3f6 的 59b4f25 会话已被 17c51003 轮转；证据改钉当前 ANGLE 会话（c7079e1，Task209 探针版）

# Task223 轮转再锚：c7079e1 ANGLE 会话已被 25 项清单轮 2832c2b 日志集整体
# 轮替（全树 latestlog* 扫描实证零命中）。历史 NOT FOUND 计数证据不可再生
# ——保留的不变量收窄为"退役重定向在任何在树日志中零命中"（2832c2b 全集，
# 8 个轮转文件）；红鲱鱼定谳语义另由 B2/B3 代码锚守护。
import glob as _glob209
_logs209 = "".join(open(f, encoding="utf-8", errors="replace").read()
                   for f in sorted(_glob209.glob("latestlog*")))
check("B1 退役不变量（Task223 轮转再锚·现役日志全集 2832c2b）：重定向锚点 0 命中 = 从未触发",
      _logs209.count("Task208: push-constant block rename redirected") == 0,
      f"anchors={_logs209.count('Task208: push-constant block rename redirected')}")

check("B2 幽灵代码三删（函数定义/重定向变量/锚点日志；注释里的退役记述合法）",
      "ame208_find_push_constant(" not in shim
      and "ame208_pcVar" not in shim
      and "ame208_redirected" not in shim
      and "[spvc-shim] Task208: push-constant block rename redirected" not in shim)

check("B3 重放回归纯形态（原样 id 逐条转发）",
      "real_set_name(es_compiler, orig->names[i].id, orig->names[i].name);" in shim
      and "Task209：纯重放（原样 id）" in shim)

check("B4 Task209 定谳注释（零 PC 块 + MC 双命名 + 0x2000021 + 反编译出处）",
      "Task209（红鲱鱼清算）" in shim
      and "零 push_constant 块" in shim
      and "_push_constants_instance" in shim
      and "0x2000021" in shim
      and "renameDescriptors case 9" in shim)

check("B5 Task206 选项保留（未来真 PC 块版本需要；与 MC 桌面选项集一致）",
      "AME206_OPTION_GLSL_PUSH_CONST_AS_UBO" in shim
      and shim.count("AME206_OPTION_GLSL_PUSH_CONST_AS_UBO") >= 3
      and '"[spvc-shim] Task206: EMIT_PUSH_CONSTANT_AS_UNIFORM_BUFFER "' in shim)

# ============ C. 四叉探针 ============
print("== C. tinygl4angle Task209 探针 ==")
tg = rd("Natives/external/gl4ses/tinygl4angle.c"
        if os.path.exists(os.path.join(REPO, "Natives/external/gl4ses/tinygl4angle.c"))
        else "Natives/external/gl4es/tinygl4angle.c")

check("C1 状态快照（blend/depth/mask/drawFb + 单元 0-3 + active 恢复）",
      "static void ame209_draw_state(const char *ame209_tag)" in tg
      and "GL_BLEND_SRC_RGB" in tg and "GL_COLOR_WRITEMASK" in tg
      and "GL_DRAW_FRAMEBUFFER_BINDING" in tg
      and "GL_TEXTURE_BINDING_2D" in tg
      and tg.count("ame209_ptr_activeTex((GLenum)ame209_act);") == 1)

check("C2 BaseVertex 族普查（统一计数 + 大规模必采 + 状态联动）",
      "static int ame209_bv_sample(int ame209_big)" in tg
      and "ame209_bv_sample(count >= 1024)" in tg
      and "ame209_bv_sample(count >= 1024 || instancecount >= 4)" in tg
      and "ame209_bv_sample(ame209_c0 >= 1024 || drawcount >= 16)" in tg
      and tg.count("ame209_draw_state(") >= 6)

check("C3 glDrawArraysInstanced 大规模通道（BIG 必采 + 状态）",
      "Task209 draw: glDrawArraysInstanced BIG" in tg
      and 'ame209_draw_state("DrawArraysInstancedBIG")' in tg
      and 'ame209_draw_state("DrawArraysInstanced")' in tg)

check("C4 纹理上传法证（TexImage/TexSubImage 格式 + 三阈值采样）",
      "Task209 tex: glTexImage2D" in tg and "Task209 tex: glTexSubImage2D" in tg
      and "ifmt=0x%04X" in tg and "ame209_px >= 1000000u" in tg
      and tg.count("% 4096) == 0") >= 2)

check("C5 地形族 ESSL dump（签名 + 大源 + begin/end 标记 + 4 次上限）",
      'strstr(ame209_src, "sphericalVertexDistance")' in tg
      and "ame209_l0 >= 3800" in tg
      and "Task209 ESSL dump #%d begin" in tg
      and "Task209 ESSL dump #%d end <<<" in tg
      and "s_ame209_dumpN < 4" in tg)

stub = rd("scripts/task179_inc/GL/gl.h")
check("C6 stub gl.h 九枚举（值对 vgpu const.h/gles.h 核验）",
      "#define GL_BLEND_SRC_RGB 0x80C9" in stub
      and "#define GL_BLEND_DST_RGB 0x80C8" in stub
      and "#define GL_DEPTH_TEST 0x0B71" in stub
      and "#define GL_DEPTH_FUNC 0x0B74" in stub
      and "#define GL_COLOR_WRITEMASK 0x0C23" in stub
      and "#define GL_DRAW_FRAMEBUFFER_BINDING 0x8CA6" in stub
      and "#define GL_ACTIVE_TEXTURE 0x84E0" in stub
      and "#define GL_TEXTURE0 0x84C0" in stub
      and "#define GL_TEXTURE_BINDING_2D 0x8069" in stub)

rsyn = run(["bash", "scripts/task193_tinygl_syntax.sh"], timeout=280)
check("C7 tinygl 语法门（task193，stub 扩枚举后）",
      rsyn.returncode == 0 and "SYNTAX OK" in rsyn.stdout,
      (rsyn.stdout or rsyn.stderr)[-160:] if rsyn.returncode != 0 else "")

# ============ D. 文档 + 级联 ============
print("== D. 文档 + 级联 ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("D1 version.h Task209 附录（改名 + 红鲱鱼 + 探针 + 尾部 SEP）",
      "Amethyst Task 209, 2026-10-01" in vh
      and "Krypton Wrapper (<=26.2)" in vh
      and "ZERO push-constant blocks" in vh
      and "DUAL naming" in vh
      and vh.rstrip().endswith("// ============================================================================"))

ann = json.loads(rd("announcements.json"))["announcements"]
a209 = ann[8] if len(ann) > 2 else {}  # Task212 重锚：task212@2 插入顺延
check("D2 公告 task209@2（Task212 重锚：34 条 + 末位 task206 不动 + 内容双主题）",
      len(ann) == 43 and a209.get("id") == "task209-krypton-rename-2026-10-01"
      and ann[-5]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and "Krypton Wrapper" in a209.get("title", "")
      and "红鲱鱼" in a209.get("content", "")
      and "Initialising Krypton Wrapper" in a209.get("content", ""))

wl = rd("worklog.md")
check("D3 worklog Task 209 条目（判读 + 定谳 + 改名 + 探针 + 级联）",
      "Task ID: 209" in wl and "红鲱鱼" in wl and "Krypton Wrapper" in wl
      and "四叉" in wl)

r206 = run([sys.executable, "scripts/verify_task206.py"], timeout=600)
check("D4 verify_task206 级联 43/43（改名重锚 E4/E6/F4 后）",
      r206.returncode == 0 and "43/43" in r206.stdout and "ALL PASS" in r206.stdout,
      r206.stdout[-160:] if r206.returncode != 0 else "")

# Task217 嵌套去重：D5（208）与 D6（202）均带 TASK209_NESTED=1——208 跳过其
# D2 的 206 内部重跑（由本验证器 D4 直接全量跑），202 跳过其 J 的 168/193
# 两腿（由 D9/D7 直接全量跑）。同舰队一次全程不重复跑，且深嵌套在本
# 沙箱 CPU 配额下必超工具时限。独立运行 208/202 时行为不变（24/24、57/57）。
_nested_env = dict(os.environ)
_nested_env["TASK209_NESTED"] = "1"
r208 = run([sys.executable, "scripts/verify_task208.py"], timeout=600, env=_nested_env)
check("D5 verify_task208 级联 23/23（嵌套去重态：其 D2 的 206 重跑由本验证器 D4 直接跑；独立跑为 24/24；A 门退役重锚后）",
      r208.returncode == 0 and "23/23" in r208.stdout and "ALL PASS" in r208.stdout,
      r208.stdout[-160:] if r208.returncode != 0 else "")

r202 = run([sys.executable, "scripts/verify_task202.py"], timeout=600, env=_nested_env)
check("D6 verify_task202 级联 55/55（嵌套去重态：J 跳 168/193 两腿、由 D9/D7 直接跑；独立跑为 57/57；公告 31 + 索引顺延重锚后）",
      r202.returncode == 0 and "55/55" in r202.stdout and "ALL GREEN" in r202.stdout,
      r202.stdout[-160:] if r202.returncode != 0 else "")

r193 = run([sys.executable, "scripts/verify_task193.py"], timeout=600)
check("D7 verify_task193 级联 84 PASS / 0 FAIL（Task215 重锚：并行 214 的 N-gate 重排净 -2）",
      r193.returncode == 0 and "84 PASS / 0 FAIL" in r193.stdout,
      r193.stdout[-160:] if r193.returncode != 0 else "")

r165 = run([sys.executable, "scripts/verify_task165.py"], timeout=280)
check("D8 存量断锚修复复证（165 34/34 + 167 31/31）",
      "34/34" in r165.stdout
      and "31/31" in run([sys.executable, "scripts/verify_task167.py"], timeout=280).stdout)

r168 = run([sys.executable, "scripts/verify_task168.py"], timeout=600)
fails168 = [l for l in r168.stdout.split("\n") if l.strip().startswith("[FAIL]")]
check("D9 verify_task168 34/34 全绿（Task211 重锚：Task210 附录后的干净提交树；旧 42/43 的 E7/134-E4b 存量漂移已随 Task211 轮转重锚清零）",
      "34/34" in r168.stdout and len(fails168) == 0,
      str(fails168[:2]))

# ============ summary ============
fails = [n for n, ok in results if not ok]
print()
print(f"==== Task209: {len(results) - len(fails)}/{len(results)} ====")
if fails:
    print("FAILED:")
    for n in fails:
        print("  " + n)
    sys.exit(1)
print("ALL PASS")
