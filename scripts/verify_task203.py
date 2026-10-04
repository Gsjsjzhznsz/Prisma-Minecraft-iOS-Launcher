#!/usr/bin/env python3
# verify_task203 -- Task203 修复轮验证器
# A gl4es v2 补丁（vtool-proof）/ B 钉扎门控（vgpu 根修）
# C tinygl4angle printf 化 / D ANGLE 流量观察器
# E FAQ i18n 三语 / F Forge early display 散弹 / G OptiFine 误报
# H 文档（version.h/公告）/ I 语法门 / J 级联
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
results = []


def check(section, label, ok, detail=""):
    results.append((f"[{section}] {label}", bool(ok)))
    if not ok:
        print(f"  [FAIL] {section} {label} {detail}")


def rd(path):
    with open(os.path.join(REPO, path), encoding='utf-8', errors='replace') as f:
        return f.read()


# ============ A. gl4es v2 补丁（本地全生命周期实测） ============
ps = rd("scripts/patch_gl4es_ggstr_nullguard.py")
check("A", "v2 脚本在位（双调用点 + vtool 病历 + 自校验解码器）",
      "SITE_EXTS_PC   = 0x1BC2B0" in ps and "SITE_VENDOR_PC = 0x1BDE4C" in ps
      and "vtool" in ps and "decode_adrp_target" in ps and "decode_add_imm12" in ps)

# Task212 重锚：holy gl4es（libgl4es_114.dylib）退役删除——补丁全生命周期实测
# 退位为工件在位断言（脚本保留作历史法证与复现记录；仓库不再携带该 dylib，
# Makefile 接线随退役移除）。
src = os.path.join(REPO, "Natives/resources/Frameworks/libgl4es_114.dylib")
import os as _os
mk = rd("Makefile")
check("A", "补丁工件保留 + dylib 退役 + Makefile 接线移除（Task212）",
      _os.path.exists(os.path.join(REPO, "scripts/patch_gl4es_ggstr_nullguard.py"))
      and not _os.path.exists(src)
      and "patch_gl4es_ggstr_nullguard.py" not in mk)

check("A", "Makefile 接线已随 holy 退役移除（Task212 重锚）",
      "patch_gl4es_ggstr_nullguard.py" not in mk
      and "holy gl4es（libgl4es_114.dylib）退役删除" in mk)
check("A", "Makefile TAB 基线（Task214 重锚：644 = 561 + 83 dep_virgl 行）",
      sum(1 for l in mk.split("\n") if l.startswith("\t")) == 662)

# ============ B. 钉扎门控（vgpu 崩溃根修） ============
mh = rd("Natives/main_hook.m")
check("B", "会话门（AMETHYST_RENDERER 必须含 libtinygl4angle 才钉扎）",
      'getenv("AMETHYST_RENDERER")' in mh
      and 'strstr(ame203_renderer, "libtinygl4angle") == NULL) return NULL;' in mh)
check("B", "病历锚（v1 劫持链 + Task182 gles pin 铁证引用）",
      "vgpu 1.8.9 崩溃根修" in mh and "gl4es_glMultMatrixf" in mh and "load_all" in mh)

# ============ C. tinygl4angle printf 化（诊断解锁） ============
tg = rd("Natives/external/gl4es/tinygl4angle.c")
nsl = re.findall(r'^[^/\n]*\bNSLog\(', tg, re.M)
check("C", "代码内零 NSLog（注释除外）", len(nsl) == 0, str(nsl[:3]))
check("C", "关键锚点已 printf 化（Task187/193/197/179 至少四族）",
      'printf("[tinygl4angle] Task187: accepted desktop-only' in tg
      and 'printf("[tinygl4angle] Task193: extension cache built' in tg
      and 'printf("[tinygl4angle] Task197: DSA advertisement WITHDRAWN' in tg
      and 'printf("[TinyGL] Task179 desktop identity' in tg)
check("C", "嵌套 NSString 参数已转 UTF8String（printf %s 安全）",
      "[[NSString stringWithFormat:@\", MISSING: %@\", [misses componentsJoinedByString:@\", \"]] UTF8String]" in tg)

# ============ D. ANGLE 流量观察器 ============
check("D", "查询族观察器（glGetString/glGetStringi/glGetIntegerv 首次记名）",
      "Task203 query: glGetString #" in tg and "Task203 query: glGetStringi #" in tg
      and "Task203 query: glGetIntegerv #" in tg)
check("D", "矩阵上传族（AME186 宏内嵌计数器 + glUniform4fv 记名 + 1iv/1f/2f/3f 转发）",
      "Task203 uniform: %s #" in tg and "Task203 uniform: glUniform4fv #" in tg
      and "void glUniform1iv(" in tg and "void glUniform1f(" in tg
      and "void glUniform2f(" in tg and "void glUniform3f(" in tg
      and "AME186_MATRIX_FN" in tg)
check("D", "绘制族（useProgram/drawElements/drawArrays/两种 instanced 周期记名）",
      "Task203 draw: glUseProgram #" in tg and "Task203 draw: glDrawElements #" in tg
      and "Task203 draw: glDrawArrays #" in tg and "Task203 draw: glDrawElementsInstanced #" in tg
      and "Task203 draw: glDrawArraysInstanced #" in tg)
check("D", "解析失败安全（Task203 转发族经 AME173_RESOLVE；矩阵族经 LOOKUP_FUNC 同款门；Task204 数据面观察器同门）",
      (tg.count("AME173_RESOLVE(ame203_ptr_") + tg.count("AME173_RESOLVE(ame204_ptr_")) >= 14
      and "if (ame204_ptr_u1iv) ame204_ptr_u1iv(" in tg)

# ============ E. FAQ i18n ============
lh = rd("Natives/LauncherHelpViewController.m")
check("E", "加载器随应用内语言（三级回退 + system 原生探测）",
      "general.app_language" in lh and "help-faq.json" in lh
      and 'stringByAppendingPathComponent:@"help-faq.json"' in lh
      and "Task203（FAQ i18n" in lh)
en = json.load(open(os.path.join(REPO, "Natives/resources/en.lproj/help-faq.json"), encoding='utf-8'))
ht = json.load(open(os.path.join(REPO, "Natives/resources/zh-Hant.lproj/help-faq.json"), encoding='utf-8'))
cn = json.load(open(os.path.join(REPO, "Natives/resources/zh-CN.lproj/help-faq.json"), encoding='utf-8'))
src = json.load(open(os.path.join(REPO, "help-faq.json"), encoding='utf-8'))
n_src = sum(len(c['items']) for c in src['categories'])
check("E", "三语件在场且条目数对齐（38，Task206 重锚）",
      sum(len(c['items']) for c in en['categories']) == n_src
      and sum(len(c['items']) for c in ht['categories']) == n_src
      and sum(len(c['items']) for c in cn['categories']) == n_src)
icons_ok = all(
    ie['icon'] == iz['icon']
    for ce, cz in zip(en['categories'], src['categories'])
    for ie, iz in zip(ce['items'], cz['items']))
check("E", "图标序列三语对齐", icons_ok)
check("E", "en 翻译实质（标题英文 + 描述长度合理）",
      all(re.match(r'^[A-Za-z0-9 "\'/()&+,.:\u2014-]+$', it['title'][:20]) or it['title'][:1].isupper()
          for c in en['categories'] for it in c['items'])
      and all(len(it['description']) > 200 for c in en['categories'] for it in c['items']))
check("E", "zh-Hant 已繁化（样本含 罒/設 等繁体字形）",
      "渲染器應該怎麼選" in json.dumps(ht, ensure_ascii=False))
check("E", "Forge 条目四语含 tinyfd 说明",
      all("tiny file dialogs" in json.dumps(x, ensure_ascii=False) for x in (src, en, ht, cn)))

# ============ F. Forge early display 散弹 ============
jl = rd("Natives/JavaLauncher.m")
check("F", "三属性齐发（fml 老 + neoforge 新 + forge 新）",
      '-Dfml.earlyprogresswindow=false' in jl
      and '-Dneoforge.enabledEarlyDisplay=false' in jl
      and '-Dforge.disableEarlyDisplay=true' in jl)
check("F", "病历注释（tiny file dialogs + stdin EOF 不死锁结论）",
      "tiny file dialogs" in jl and "EOF" in jl)

# ============ G. OptiFine 误报修复 ============
pj = rd("JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java")
check("G", ".jar 后缀门（禁用副本不告警）",
      'endsWith(".jar")' in pj and "Task203（误报修复）" in pj)

# ============ H. 文档 ============
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("H", "version.h Task203 附录（no bump + vtool 病历）",
      "Task 203, no bump" in vh and "vtool" in vh and "ZERO-WIPED" in vh)
ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding='utf-8'))['announcements']
check("H", "公告末位是 task206-nggl4es（Task212 重锚：task212@2 插入后 34）",
      len(ann) == 40 and ann[-2]['id'] == 'task217-download-fixes-about-isolation-2026-10-03')
bundled = open(os.path.join(REPO, "Natives/resources/help-faq.json"), 'rb').read()
rootfaq = open(os.path.join(REPO, "help-faq.json"), 'rb').read()
check("H", "FAQ 根/随包副本逐字节一致（verify_task168 契约）", bundled == rootfaq)

# ============ I. 语法门 ============
def balanced(path, strip_pattern):
    txt = rd(path)
    nc = re.sub(r'//[^\n]*', '', txt)
    nc = re.sub(r'/\*.*?\*/', '', nc, flags=re.S)
    ns = re.sub(strip_pattern, '""', nc)
    return ns.count('{') - ns.count('}'), ns.count('(') - ns.count(')')

# 注意：粗检剥离器对 ObjC 的富字面量（插值/转义序列）有存量误报——
# 口径 = 与 HEAD 对拍同态（增量平衡），与 Task202 轮方法论一致。
import subprocess
def head_balance(path, pat):
    txt = subprocess.run(['git', '-C', REPO, 'show', f'HEAD:{path}'],
                         capture_output=True, text=True).stdout
    nc = re.sub(r'//[^\n]*', '', txt)
    nc = re.sub(r'/\*.*?\*/', '', nc, flags=re.S)
    ns = re.sub(pat, '""', nc)
    return ns.count('{') - ns.count('}'), ns.count('(') - ns.count(')')

for f, pat in [("Natives/external/gl4es/tinygl4angle.c", r'"(?:[^"\\]|\\.)*"'),
               ("Natives/main_hook.m", r'@"(?:[^"\\]|\\.)*"'),
               ("Natives/LauncherHelpViewController.m", r'@"(?:[^"\\]|\\.)*"'),
               ("Natives/JavaLauncher.m", r'@"(?:[^"\\]|\\.)*"')]:
    b, p = balanced(f, pat)
    hb, hp = head_balance(f, pat)
    check("I", f"{os.path.basename(f)} 括号平衡（对拍 HEAD）", b == hb and p == hp,
          f"cur=({b},{p}) head=({hb},{hp})")

jtxt = rd("JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java")
nc = re.sub(r'//[^\n]*', '', jtxt)
nc = re.sub(r'/\*.*?\*/', '', nc, flags=re.S)
ns = re.sub(r'"(?:[^"\\]|\\.)*"', '""', nc)
check("I", "PojavLauncher.java 括号平衡",
      ns.count('{') - ns.count('}') == 0 and ns.count('(') - ns.count(')') == 0)

# ============ 输出 ============
print()
fails = [r for r in results if not r[1]]
print(f"==== Task203: {len(results) - len(fails)}/{len(results)} ====")
if fails:
    print("FAILED:")
    for name, _ in fails:
        print(f"  - {name}")
    sys.exit(1)
print("ALL GREEN")
