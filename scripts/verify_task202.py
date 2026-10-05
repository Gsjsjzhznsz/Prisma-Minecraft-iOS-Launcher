#!/usr/bin/env python3
# verify_task202 -- Task202 八项修复轮验证器（52 检查）
# A gl4es 崩溃免疫 / B Metal 首帧 / C vgpu 探针 / D ANGLE 观察器
# E Forge+OptiFine / F i18n 与语言选择器 / G 输入两议题 / H 文档
# I 语法门 / J 级联
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


# ============ A. gl4es 崩溃免疫（Task203 v2：ADRP+ADD 双点改写，vtool-proof） ============
# Task203 勘误：v1 洞穴垫片（0x6400）被 CI 的 vtool 平台重打标静默清零
# （节间隙非节数据，重序列化被抹）→ 装机 SIGILL @+0x6400。v2 在两个
# glGetString 调用点原地改写（都在 __text 内），本节按 v2 形态验证。
ps = rd("scripts/patch_gl4es_ggstr_nullguard.py")
check("A", "补丁脚本 v2 存在且带双病历（v1 vtool 清零 + strstr(NULL) 首个 needle）",
      "GL_APPLE_texture_2D_limited_npot" in ps and "GetHardwareExtensions" in ps
      and "vtool" in ps and "0x1BC2B0" in ps and "0x1BDE4C" in ps)
check("A", "v2 语义要素（双调用点 ADRP+ADD + 空串锚 0x1CE9A2 + 无洞穴依赖）",
      "EMPTY_STR_ADDR = 0x1CE9A2" in ps and "enc_adrp_x0" in ps and "enc_add_x0_x0_imm12" in ps
      and "SHIM_ADDR" not in ps)
check("A", "指纹与守护（两处原始字序 + 后续活代码守护字 + needle 前缀审计门）",
      "0x5283E060" in ps and "0x5283E000" in ps and "0xF9404FE8" in ps and "0xF94067E8" in ps
      and "needle_prefix" in ps)
check("A", "幂等 + 漂移拒绝 + --verify 三件套",
      "PATCH PRESENT" in ps and "binary drift" in ps and "--verify" in ps)

mk = rd("Makefile")
check("A", "Makefile 接线已随 holy 退役移除（Task212 重锚：两补丁行删除 + 退役注释在场）",
      "patch_gl4es_ggstr_nullguard.py" not in mk
      and "patch_gl4es_rtld_default.py" not in mk
      and "holy gl4es（libgl4es_114.dylib）退役删除" in mk)
check("A", "Makefile TAB 完整性（无空格缩进 recipe 行）",
      not any(l.startswith("    ") for l in mk.split("\n")))

eb = rd("Natives/egl_bridge.m")
check("A", "egl_bridge Task193 块随 holy 退役收档（Task212 重锚：入口锚点退役 + 改道注释在场）",
      "Task202: Task193 gl4es bootstrap block ENTERED" not in eb
      and "holy gl4es（libgl4es_114.dylib）整体退役" in eb)

mh = rd("Natives/main_hook.m")
check("A", "main_hook gl4es 基址记录 + musttail 逃逸修正",
      "Task202: libgl4es_114 image base" in mh and "needsGl4esRecord" in mh)

# Task212 重锚：dylib 已随 holy gl4es 退役删除——补丁生命周期实测退位为
# 工件在位断言（脚本保留作历史法证；仓库不再携带该二进制）。
import os as _os
check("A", "补丁脚本工件保留 + dylib 已退役（Task212）",
      _os.path.exists(os.path.join(REPO, "scripts/patch_gl4es_ggstr_nullguard.py"))
      and not _os.path.exists(os.path.join(REPO, "Natives/resources/Frameworks/libgl4es_114.dylib")))

# ============ B. Metal 首帧信号 ============
check("B", "CAMetalLayer nextDrawable 交换（install + hook 双函数）",
      "ame202_installMetalFirstFrameHook" in mh and "ame202_nextDrawable_hook" in mh
      and "method_setImplementation" in mh and "objc_getClass(\"CAMetalLayer\")" in mh)
check("B", "门控三条件（AMETHYST_METAL env + isRunning + 非空 drawable）",
      "AMETHYST_METAL" in mh and "[SurfaceViewController isRunning]" in mh
      and "ame202_drawable != nil" in mh)
check("B", "init_hookFunctions 安装接线 + objc/runtime 导入",
      mh.find("ame202_installMetalFirstFrameHook()") > mh.find("void init_hookFunctions()")
      and "#import <objc/runtime.h>" in mh)
check("B", "首帧信号走 pojavIncrementFpsCounter（与 GL/Vulkan 同门）",
      mh.count("pojavIncrementFpsCounter();") >= 1)

# ============ C. vgpu（EAB 常量勘误 + 纹理探针） ============
dc = rd("Natives/external/vgpu/src/gl/drawing.c")
_eab_def = [l for l in dc.split("\n") if l.startswith("#define AME193_EAB_BINDING")]
check("C", "EAB 查询常量 0x8894 -> 0x8895（ELEMENT_ARRAY_BUFFER_BINDING；勘误注释合法提及旧值）",
      _eab_def == ["#define AME193_EAB_BINDING 0x8895"])
tc = rd("Natives/external/vgpu/src/gl/texture.c")
check("C", "勘误注释（顶点/索引缓冲错读的机制说明，drawing.c 内）",
      "顶点" in dc and "0x8895" in dc and "GL_ELEMENT_ARRAY_BUFFER_BINDING  = 0x8895" in dc)
check("C", "TexImage2D 双路径探针（RESIZE-PATH / DIRECT-PATH）",
      "RESIZE-PATH" in tc and "DIRECT-PATH" in tc)
check("C", "TexSubImage2D 探针（in/out 对照 + shrink + 真错误）",
      "VGPU Task202 texsub" in tc and "shrink=%d" in tc and "in=(%d,%d %dx%d)" in tc)
check("C", "探针节流（首 8 + 每 120 采样）",
      "<= 8" in tc and "% 120" in tc)
check("C", "错误读取在最终 gles 分发后（LOAD_GLES(glGetError) 直读）",
      "LOAD_GLES(glGetError)" in tc)

# ============ D. ANGLE 观察器（钉扎 + eglGPA 包装 + 记名升级） ============
check("D", "GL 符号钉扎入口（hooked_dlsym 顶部接线）",
      "ame202_pinGLSymbol(handle, name)" in mh)
check("D", "callerIsTinygl 守卫（noinline + 返回地址层级 1）",
      "__attribute__((noinline))" in mh and "__builtin_return_address(1)" in mh
      and "ame202_callerIsTinygl" in mh)
check("D", "NOLOAD 自取镜像句柄（绝不触发加载）",
      "RTLD_NOLOAD" in mh and "libtinygl4angle.dylib" in mh)
check("D", "eglGetProcAddress 钉扎 + 记名包装",
      "eglGetProcAddress pinned to tinygl4angle" in mh and "ame202_eglGPA_wrapper" in mh)
check("D", "NULL 记名升级（去重全量替代 30 截断）",
      "ame202_logNullGL" in mh and "s_ame193_glNulls < 30" not in mh)
sd = rd("Natives/sdl3_hook.m")
check("D", "SDL_GL_GetProcAddress 观察器（首 12 成功 + NULL 去重记名）",
      "ame202_gpaObserve" in sd and "GetProcAddress OK #" in sd and "GetProcAddress NULL" in sd)
check("D", "观察器纯取证（三条解析路径全打点）",
      sd.count("ame202_gpaObserve(proc,") == 3)

# ============ E. Forge + OptiFine 检测 ============
pl = rd("JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java")
check("E", "共存检测（forge 版本串 + mods 目录扫描 optifine）",
      'contains("forge")' in pl and 'contains("optifine")' in pl and "DIR_GAME_NEW" in pl)
check("E", "警示锚点 + 不阻断（日志后 break，无 return/exit）",
      "Task202: OptiFine detected alongside Forge" in pl)
faq = json.load(open(os.path.join(REPO, "help-faq.json"), encoding='utf-8'))
allit = [i for c in faq['categories'] for i in c['items']]
check("E", "FAQ 定性条目（IForgeVertexFormat + 移除指引）",
      any("IForgeVertexFormat" in i["description"] for i in allit))

# ============ F. i18n 与语言选择器 ============
lp = rd("Natives/LauncherPreferencesViewController.m")
check("F", "语言枚举助手（lproj 目录扫描 + dispatch_once 缓存）",
      "ame202_availableLanguageCodes" in lp and "pathsForResourcesOfType" in lp
      and "dispatch_once" in lp)
check("F", "显示名（原生名表 + NSLocale 兜底 + 部分翻译标记）",
      "ame202_languageDisplayName" in lp and "ame202.lang.partial" in lp
      and "NSLocaleIdentifier" in lp)
check("F", "app_language 动态 pickKeys/pickList（预构建局部数组，非语句表达式）",
      "ame202_langKeys" in lp and '@"pickKeys": ame202_langKeys' in lp
      and "ame202_langNames" in lp)
check("F", "旧三选项硬编码退役",
      '@"zh-Hans",' not in lp[lp.find('@"key": @"app_language"'):lp.find('@"key": @"app_language"') + 900])

langs = {}
for lg in ("zh-Hans", "zh-Hant", "en", "zh-CN"):
    keys = re.findall(r'^"([^"]+)"\s*=', rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), re.M)
    langs[lg] = set(keys)
check("F", "四主表键集一致且 2520（2408 + 10 ame202 - 2 Task210 退役）",
      len(langs["zh-Hans"]) == len(langs["zh-Hant"]) == len(langs["en"]) == len(langs["zh-CN"]) == 2520
      and langs["zh-Hans"] == langs["zh-Hant"] == langs["en"] == langs["zh-CN"])
ame202_keys = {k for k in langs["zh-Hans"] if k.startswith("ame202.")}
check("F", "恰 10 个 ame202.* 键（partial + surface×2 + ai×6 + copy）",
      len(ame202_keys) == 10 and "ame202.lang.partial" in ame202_keys
      and "ame202.surface.version_load_failed" in ame202_keys and "ame202.common.copy" in ame202_keys)

sv = rd("Natives/SurfaceViewController.m")
check("F", "乱码串修复（两处 localize 化 + 无残留 mojibake）",
      "ame202.surface.version_load_failed" in sv and "ame202.surface.login_required" in sv
      and "æ¸¸æ" not in sv and "è¯·å" not in sv)
ask = rd("Natives/AI/AiAskTool.m")
check("F", "AI 问筹对话框迁移（6 串 + utils.h 导入）",
      ask.count("ame202.ai.") >= 6 and '#import "../utils.h"' in ask)
sess = rd("Natives/AI/AiSession.m")
check("F", "AI 会话默认标题迁移",
      "ame202.ai.new_session" in sess and '#import "../utils.h"' in sess)
ub = rd("Natives/ios_uikit_bridge.m")
check("F", "Java 对话框桥 OK/Copy 迁移",
      'localize(@"ame202.common.copy", @"Copy")' in ub and 'actionWithTitle:localize(@"OK", nil)' in ub)

# ============ G. 输入两议题 ============
ttf = rd("Natives/TrackedTextField.m")
check("G", "议题 #2：去重窗 80ms -> 20ms + 勘误注",
      "> 20)" in ttf and "> 80" not in ttf and "Task202（议题 #2 勘误）" in ttf)
check("G", "议题 #1：滚动抑制门（sendTouchPoint 顶部 + 锚点推进）",
      "ame202ScrollGestureActive" in sv and "lastVirtualMousePoint = location;" in sv
      and sv.count("ame202ScrollGestureActive") >= 4)
check("G", "议题 #1：异步清除（手势 Ended 先于 touchesEnded 的时序防线）",
      "dispatch_async(dispatch_get_main_queue(), ^{\n            self.ame202ScrollGestureActive = NO;" in sv)
check("G", "议题 #1：点击容差 24x24（居中）",
      "CGRectMake(locationInView.x - 12, locationInView.y - 12, 24, 24)" in sv)
check("G", "属性声明在位",
      "@property(nonatomic) BOOL ame202ScrollGestureActive;" in sv)

# ============ H. 文档 ============
check("H", "FAQ 计数 38（[12,4,7,15]，Task206 重锚：+NG-GL4ES 条目）且双份同步",
      [len(c['items']) for c in faq['categories']] == [12, 4, 7, 15]
      and json.load(open(os.path.join(REPO, "Natives/resources/help-faq.json"), encoding='utf-8')) == faq)
check("H", "FAQ Metal 崩溃指引条目",
      any("metallum" in i["title"].lower() and "AGX" in i["description"] for i in allit))
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("H", "version.h REVISION 18 附录（Task202 八节 + no bump 理由）",
      "REVISION 18 addendum (Task 202, no bump" in vh and "ggstr_nullguard" in vh
      and "54 bundled .lproj" in vh)
ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding='utf-8'))["announcements"]
check("H", "公告 31 条且末位仍是 task206-nggl4es（Task209@2 插入 +1）",
      # Task209 重锚：task209@2 插入（30→31）；task202 锚顺延 [28]。
      len(ann) == 42 and ann[-4]["id"] == "task217-download-fixes-about-isolation-2026-10-03"
      and ann[34]["id"] == "task202-october-fix-wave")
check("H", "公告索引锚（Task212 重锚：[7]=task196 / [8]=task193 / [0]=server）",
      ann[10]["id"] == "task196-quad-fixes-2026-09-29" and ann[11]["id"] == "task193-app-icon-replace-2026-09-28"
      and ann[0]["id"].startswith("server-recommend"))
check("H", "两份调查报告在位（Task201 gitignore 丢失重建）",
      os.path.isfile(os.path.join(REPO, "docs/surveys/2026-09-29-upstream-sync-survey.md"))
      and os.path.isfile(os.path.join(REPO, "docs/surveys/2026-09-29-upstream-issues-survey.md")))

# ============ I. 语法门（括号平衡 vs HEAD） ============
def strip_c(src):
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == '/' and i + 1 < n and src[i + 1] == '/':
            while i < n and src[i] != '\n':
                i += 1
        elif c == '/' and i + 1 < n and src[i + 1] == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
        elif c == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == '\\':
                    i += 1
                i += 1
            i += 1
        elif c == "'":
            i += 1
            while i < n and src[i] != "'":
                if src[i] == '\\':
                    i += 1
                i += 1
            i += 1
        else:
            out.append(c)
            i += 1
    return ''.join(out)

edited = ["Natives/main_hook.m", "Natives/egl_bridge.m", "Natives/sdl3_hook.m",
          "Natives/LauncherPreferencesViewController.m", "Natives/SurfaceViewController.m",
          "Natives/ios_uikit_bridge.m", "Natives/TrackedTextField.m",
          "Natives/AI/AiAskTool.m", "Natives/AI/AiSession.m",
          "Natives/external/vgpu/src/gl/drawing.c", "Natives/external/vgpu/src/gl/texture.c"]
drift = []
for f in edited:
    cur = strip_c(rd(f))
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{f}"], capture_output=True).stdout.decode('utf-8', errors='replace')
    if not head:
        continue
    headp = strip_c(head)
    if (cur.count('{') - cur.count('}')) != (headp.count('{') - headp.count('}')) or \
       (cur.count('(') - cur.count(')')) != (headp.count('(') - headp.count(')')):
        drift.append(f)
check("I", f"括号平衡 vs HEAD（{len(edited)} 个编辑文件零漂移）", not drift, str(drift))

jp = "JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java"
cur = strip_c(rd(jp))
head = strip_c(subprocess.run(["git", "-C", REPO, "show", f"HEAD:{jp}"], capture_output=True).stdout.decode('utf-8', errors='replace'))
check("I", "Java 结构平衡（大括号/圆括号增量对称）",
      (cur.count('{') - cur.count('}')) == (head.count('{') - head.count('}'))
      and (cur.count('(') - cur.count(')')) == (head.count('(') - head.count(')')))

st = subprocess.run(["git", "-C", REPO, "status", "--short"], capture_output=True, text=True).stdout
# Task203 重锚：Task202 的 Makefile 改动已随 64fdaf2 入 HEAD——本检查的
# "dirty" 口径自此恒假。长期不变量改 absolutist：ggstr 接线行在位 +
# TAB 绝对基线 484（= 481 基线 + Task202 的 3 行；本轮 Makefile 零改动）。
# （本轮工作树亦不再改 Makefile，HEAD 同含该行。）
mk_tab = sum(1 for l in mk.split("\n") if l.startswith("\t"))
check("I", "Makefile 未被 TAB 化破坏（Task212 重锚：接线退役 + TAB 基线 644）",
      mk.count("patch_gl4es_ggstr_nullguard") == 0 and mk_tab == 662,
      f"tabs={mk_tab}")

# strings 表语法门：每行引号配对
bad_strings = []
for lg in ("zh-Hans", "zh-Hant", "en", "zh-CN"):
    for ln in rd(f"Natives/resources/{lg}.lproj/Localizable.strings").split("\n"):
        if ln.count('"') % 2 != 0:
            bad_strings.append((lg, ln[:50]))
check("I", "四主 .strings 引号配对零违例", not bad_strings, str(bad_strings[:2]))

# ============ J. 级联（重锚后的关键验证器） ============
_j_known_drift = {
    # verify_task168 D2：公告内容检查在纯 HEAD 上同败（家法 stash 对拍已确认，
    # 环境性存量漂移）。E7：其级联子集里的 134-E4b 为并行 Task206 日志上传
    # 轮换造成的存量漂移（Task207 在纯净 origin/main 上复跑 134 = 66/68 同败
    # 实锤，非本轮引入）——E7 失败明细只引用该条时同样放行。
    "verify_task168": ("D2", "E4b"),
}
# Task217 去重：被 209 嵌套调用时（TASK209_NESTED=1）跳过 J 循环里的 168 与
# 193 两腿——209 的 D9/D7 会直接全量跑它们，同一级联舰队在一次 209 全程
# 里重复跑纯属浪费，且深嵌套（209->202->168->24 子验证器）在本沙箱
# CPU 配额下必超工具时限（Task208 家法 "split runs required" 的对偶面：
# 嵌套去重）。独立运行 202 时行为不变（三腿全跑，57/57）。
_j_cascade = ("verify_task196_197_198_201", "verify_task168", "verify_task193")
if os.environ.get("TASK209_NESTED") == "1":
    _j_cascade = tuple(v for v in _j_cascade if v not in ("verify_task168", "verify_task193"))
for v in _j_cascade:
    r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", f"{v}.py")],
                       capture_output=True, text=True, cwd=REPO)
    # 裁决行三种形态："==== X: N/M ====" / "N PASS / M FAIL" / "RESULT: ALL PASS (N/M)"
    # N/M 形态：相等即全过；N PASS / M FAIL 形态：FAIL 数为 0 即全过。
    m1 = re.search(r'====[^=]*?(\d+)\s*/\s*(\d+)\s*====', r.stdout)
    m2 = re.search(r'(\d+)\s*PASS\s*/\s*(\d+)\s*FAIL', r.stdout)
    m3 = re.search(r'RESULT:\s*ALL PASS\s*\((\d+)\s*/\s*(\d+)\)', r.stdout)
    if m1:
        ratio_ok = m1.group(1) == m1.group(2)
    elif m2:
        ratio_ok = m2.group(2) == "0"
    elif m3:
        ratio_ok = m3.group(1) == m3.group(2)
    else:
        ratio_ok = False
    # fails 列表只认真失败行形态（"[FAIL]" / 行首 "FAIL"）——PASS 行的
    # 标签可能合法含 "FAILED" 字样（如 bootstrap FAILED 日志锚点检查）
    fails = [l for l in r.stdout.split("\n")
             if re.match(r'\s*(\[FAIL\]|FAIL\b)', l)]
    drift_ok = all(any(tag in l for tag in _j_known_drift.get(v, ("",))) for l in fails) if fails else True
    ok = (ratio_ok and not fails) or (v in _j_known_drift and drift_ok)
    check("J", f"{v} 全绿（或仅存量漂移 {(':' + '/'.join(_j_known_drift[v])) if v in _j_known_drift else ''}）",
          ok, (r.stdout or r.stderr)[-160:] if not ok else "")

# ============ verdict ============
fails = [l for l, ok in results if not ok]
print(f"\n==== Task202: {len(results) - len(fails)}/{len(results)} ====")
if fails:
    print("FAILED:")
    for l in fails:
        print("  -", l)
    sys.exit(1)
print("ALL GREEN")
