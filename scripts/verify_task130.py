#!/usr/bin/env python3
"""verify_task130 -- RCAS 锐化 pass + 档案旁切换角色入口 + 公告仓库托管的代码级验证。

A. RCAS 着色器源（FSRRCASSource.h，mpv FSR.glsl 参照）
B. osm_bridge（zink）RCAS 管线
C. mgl_fsr（MobileGL）RCAS 管线
D. MobileGlues FSR1.cpp + config/settings
E. 启动器侧（JavaLauncher 环境变量 + 设置行 + 偏好默认值）
F. 任务 B：档案旁「切换角色」按钮（免密）
G. 任务 F：公告仓库托管 JSON（raw + jsDelivr 级联）
H. 语法门（括号平衡 / .strings 行语法 / 键集一致）
I. 级联（verify_task129 含其全部子级联）
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = 0
FAIL = 0

def rd(p):
    return open(os.path.join(REPO, p), encoding="utf-8").read()

def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")

print("== A. RCAS 着色器源（FSRRCASSource.h）==")
rc = rd("Natives/ctxbridges/FSRRCASSource.h")
check("A1 static const 内部链接（bd71210 多 TU 教训）",
      "static const char *const FSR_RCAS_FSSource" in rc)
check("A2 mpv 映射：stops = 2*(1-SHARPNESS) 在 main() 入口",
      "FsrRcasCon(con, AF1_(2.0) * (AF1_(1.0) - clamp(uSharpness" in rc)
check("A3 alpha 透传（Task103/104 哨兵住在 EASU 输出 alpha）",
      "oFragColor = vec4(c, center.a);" in rc)
check("A4 con[1] 置零（packHalf2x16 规避，zink 4.10 cap）",
      "con[1]=AU1_(0);" in rc)
check("A5 texelFetch 采样（1:1，ESSL 300 口径）",
      "return texelFetch(uInputTex, p, 0);" in rc)
check("A6 AMD FSR1 1.20210629 逐字函数体（FsrRcasCon + FsrRcasF + LIMIT）",
      "void FsrRcasCon(" in rc and "void FsrRcasF(" in rc
      and "#define FSR_RCAS_LIMIT (0.25-(1.0/16.0))" in rc)
check("A7 uniform uSharpness 声明（可配置强度）",
      "uniform float uSharpness;" in rc)

print("== B. osm_bridge（zink）RCAS ==")
ob = rd("Natives/ctxbridges/osm_bridge.mm")
check("B1 符号表补 RCAS 入口（glTexImage2D + FBO×4）",
      '{"glTexImage2D"' in ob and '{"glGenFramebuffers"' in ob
      and '{"glFramebufferTexture2D"' in ob and '{"glCheckFramebufferStatus"' in ob)
check("B2 RCAS init 独立 do-while：失败不拖 EASU 下水",
      "Task130 RCAS vertex compile FAILED -- falling back to EASU-only" in ob
      and "ame83_fsr.rcasProgram == 0) ame83_fsr.rcasFailed = true" in ob)
check("B3 ping-pong：EASU→离屏 easuFBO / RCAS→fb0",
      "g->glBindFramebuffer(GL_FRAMEBUFFER, ame83_fsr.easuFBO);" in ob
      and "g->glBindFramebuffer(GL_FRAMEBUFFER, 0);" in ob)
check("B4 回退口径：FBO 不完整 → rcasFailed + EASU 直画旧路径",
      "RCAS offscreen target incomplete" in ob and "ame83_fsr.rcasFailed = true;" in ob)
check("B5 sharpness 环境变量解析（负值 off / NaN 回默认）",
      'getenv("AMETHYST_FSR_RCAS_SHARPNESS")' in ob and "return v;" in ob)
check("B6 装机锚点日志（ready + engaged）",
      "Task130 RCAS ready (zink)" in ob and "Task130 RCAS engaged (zink)" in ob)
check("B7 uSharpness 每帧下发（运行期可调）",
      "g->glUniform1f(ame83_fsr.uRcasSharpness, ame130_sharp);" in ob)

print("== C. mgl_fsr（MobileGL）RCAS ==")
mg = rd("Natives/ctxbridges/mgl_fsr.mm")
check("C1 kSym 解析表 7 新符号 + ame119_gl_t 结构体成员齐备（CI run 35492554181 回归锚：mgl_fsr.mm 调用 glDeleteTextures 而结构体漏字段 = 编译错误；表项与字段缺一即挂）",
      all(f'{{"{s}"' in mg for s in ["glUniform1f", "glTexImage2D", "glGenFramebuffers",
          "glDeleteFramebuffers", "glFramebufferTexture2D", "glCheckFramebufferStatus",
          "glDeleteTextures"])
      and "void (*glDeleteTextures)(int, const unsigned int*);" in mg)
check("C2 RCAS init + 失败回退日志",
      "Task130 RCAS vertex compile FAILED -- falling back to EASU-only" in mg
      and "ame119_fsr.rcasProgram == 0) ame119_fsr.rcasFailed = true" in mg)
check("C3 ping-pong 分支（EASU→easuFBO / RCAS→fb0=swapchain）",
      "g->glBindFramebuffer(GL_FRAMEBUFFER, ame119_fsr.easuFBO);" in mg
      and "Task130 RCAS engaged (MobileGL)" in mg)
check("C4 context_reset 清 RCAS 对象（跨上下文重建）",
      "ame119_fsr.rcasProgram = 0;" in mg and "ame119_fsr.rcasFailed = false;" in mg)
check("C5 GL 枚举守卫全覆盖（Task125 CI 教训口径）",
      (lambda used, guarded: not (used - guarded))(
          set(re.findall(r'\bGL_[A-Z0-9_]+\b', re.sub(r'/\*.*?\*/', '', re.sub(r'//[^\n]*', '', mg)))),
          set(re.findall(r'#ifndef\s+(GL_[A-Z0-9_]+)', mg))))
check("C6 符号解析完整性函数（ok == count 全解析门）",
      "return ok == (int)(sizeof(kSym) / sizeof(kSym[0]));" in mg)

print("== D. MobileGlues FSR1 + config ==")
f1 = rd("Natives/external/MobileGlues/MobileGlues-cpp/gl/FSR1/FSR1.cpp")
st = rd("Natives/external/MobileGlues/MobileGlues-cpp/config/settings.cpp")
cf = rd("Natives/external/MobileGlues/MobileGlues-cpp/config/config.cpp")
f1h = rd("Natives/external/MobileGlues/MobileGlues-cpp/gl/FSR1/FSR1.h")
sth = rd("Natives/external/MobileGlues/MobileGlues-cpp/config/settings.h")
check("D1 __has_include 守卫（standalone MobileGlues 无 RCAS 也可编译）",
      '#if __has_include("../../../../../ctxbridges/FSRRCASSource.h")' in f1
      and "#define AME130_FSR_RCAS 0" in f1)
check("D2 CompileRCASShader 失败返回 0（EASU 不受影响）",
      "GLuint CompileRCASShader()" in f1 and "staying EASU-only" in f1)
check("D3 InitFSRResources：EASU 之后编 RCAS + ready 日志",
      "g_rcasProgram = CompileRCASShader();" in f1 and "Task130 RCAS ready" in f1)
check("D4 ApplyFSR directToSurface rcasOn 分支（Task182 重锚：Task165 加了 s_ame165_rcasBailout 第三条件，行尾由 ; 变 &&）",
      "const bool rcasOn = FSR1_Context::g_rcasProgram != 0 &&" in f1
      and "global_settings.fsr1_rcas_sharpness >= 0.0f &&" in f1
      and "Task130 RCAS engaged" in f1)
check("D5 ctx 状态表携带 rcasProgram（跨上下文）",
      "d.rcasProgram = FSR1_Context::g_rcasProgram;" in f1
      and "FSR1_Context::g_rcasProgram = s.rcasProgram;" in f1)
check("D6 settings.cpp 范围策略（负透传/>1 clamp/NaN 默认）",
      "fsr1RcasSharpness" in st and "explicit off" in st)
check("D7 config_get_double 新增 + FSR1 消费",
      "double config_get_double(char* name, double fallback)" in cf
      and 'config_get_double((char*)"fsr1RcasSharpness", 0.2)' in st)
check("D8 settings.h 字段 + FSR1.h extern",
      "float fsr1_rcas_sharpness;" in sth and "extern GLuint g_rcasProgram;" in f1h)
check("D9 设置日志锚点（fsr1RcasSharpness = %.3f）",
      "Setting: fsr1RcasSharpness" in st)

print("== E. 启动器侧（env + 设置行 + 偏好）==")
jl = rd("Natives/JavaLauncher.m")
lp = rd("Natives/LauncherPreferencesViewController.m")
plp = rd("Natives/PLPreferences.m")
check("E1 ame130_export_rcas_env 双态解析（NSNumber 默认表 + NSString pick 行）",
      "isKindOfClass:NSNumber.class]" in jl and "isKindOfClass:NSString.class]" in jl
      and "[sharpObj isKindOfClass" in jl)
check("E2 setenv AMETHYST_FSR_RCAS_SHARPNESS（zink/MobileGL 统一出口）",
      'setenv("AMETHYST_FSR_RCAS_SHARPNESS"' in jl)
check("E3 非 MobileGlues 早退分支也导出（zink/MobileGL 会话覆盖）",
      jl.find("ame130_export_rcas_env();") < jl.find("init_loadMobileGluesConfig() {") + 2000
      and "config.json 不写，但 RCAS 锐化环境变量仍需导出" in jl)
check("E4 config.json 写入 fsr1RcasSharpness",
      'config[@"fsr1RcasSharpness"] = @(ame130_export_rcas_env());' in jl)
check("E5 PLPreferences 默认 @0.2（mobileglues 分区）",
      '@"fsr_rcas_sharpness": @0.2' in plp)
check("E6 设置 pick 行（7 档 pickKeys + whenNotInGame）",
      '@"key": @"fsr_rcas_sharpness"' in lp and '@"-1", @"0.1", @"0.2"' in lp)
check("E7 get/set 双重映射（video.fsr_rcas_sharpness -> mobileglues.）",
      lp.count('keyFull = @"mobileglues.fsr_rcas_sharpness";') == 2)
check("E8 l10n 9 键四语言齐备",
      all('preference.title.fsr_rcas_sharpness' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          and 'preference.title.mg_fsr_rcas-6' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]))
lp2 = rd("Natives/LauncherPreferences.m")
lph = rd("Natives/LauncherPreferences.h")
ad = rd("Natives/AppDelegate.m")
# Task166 重锚：DSA 0->1 分支整段停用（三会话 A/B 实锤 DSAWrapper 在
# FSR1 重定向下黑屏；性能依据来自 zink 原生 DSA），原 E9 的 dsa==0 锚
# 随分支退役而消失；现锚 = 迁移函数骨架 + Task130 哨兵 + 缓存 32 分支
# （保留）+ Task166 修订注释 + ame166 反向迁移接线（两处：哨兵已置位
# 老设备补课路径 + 新设备迁移后立即跑）。
check("E9 性能默认值治愈迁移（Task166 重锚：DSA 分支停用，缓存 32->128 保留 + ame166 接线）",
      "void ame130_migrateMgPerfDefaults(void)" in lp2
      and 'task130_perf_defaults_migrated") boolValue]' in lp2
      and "dsa branch retired by Task166" in lp2
      and "[(NSNumber *)cache intValue] == 32" in lp2
      and "void ame130_migrateMgPerfDefaults(void);" in lph
      and lp2.count("ame166_migrateMgDsaBlackScreen();") == 2)
# Task166 重锚：原 E10 锚（DSA 0->1 迁移写入 @YES）已随分支停用退役；
# 现锚 = Task166 反向迁移形态——仅匹配持久化 1（boolValue == YES）才
# 归 0、task166 哨兵一次性、自选 0 不动；缓存 32->128 写入保留。
# Task167 重锚：翻转判定改局部变量双类型形态（NSNumber boolValue +
# NSString intValue，见 LauncherPreferences.m 的 Task167 修订注释——
# 迁移原挂载点 configurationForConnectingSceneSession 在既有场景会话
# 设备上永不执行，调用点已搬 main.m）。
check("E10 Task166 反向迁移（DSA 仅匹配 1 归 0 / 缓存 32->128；自选 64/0 不动）",
      'setPrefObject(@"mobileglues.enable_ext_direct_state_access", @NO)' in lp2
      and "dsaOn = [(NSNumber *)dsa boolValue];" in lp2
      and "dsaOn = ([(NSString *)dsa intValue] != 0);" in lp2
      and 'task166_dsa_blackscreen_migrated") boolValue]' in lp2
      and 'setPrefObject(@"mobileglues.max_glsl_cache_size", @(128))' in lp2)
check("E11 AppDelegate 接线 + PLPreferences 哨兵默认键注册（setPrefObject 只能写已存在键）",
      "ame130_migrateMgPerfDefaults();" in ad
      and '@"task130_perf_defaults_migrated": @NO' in plp)

print("== F. 切换角色（Task190 重锚：用户定稿账号卡与已安装版本页同构、卡片无多余控件——Task130b 行内 person.2 按钮 + actionSheet 退役，角色切换收敛进全账户长按菜单 Task129b 角色项；免密链零回退）==")
al = rd("Natives/AccountListViewController.m")
check("F1 行内按钮/actionSheet 退役（ame130b_switchRoleTapped 零残留）",
      "ame130b_switchRoleTapped" not in al
      and 'systemImageNamed:@"person.2"' not in al)
check("F2 关联对象 row 绑定随之退役",
      "objc_setAssociatedObject" not in al and "objc_getAssociatedObject" not in al
      and "#import <objc/runtime.h>" not in al)
# Task225 再锚：Task224 账号 ⋯ 菜单（224-A）复用了 ame129b 切换入口（长按
# 与行内菜单共用 ame223_accountMenuItemsAtIndexPath 单一事实源），调用点
# 从 1 处扩到多处——"存在"语义替代"恰好 1 处"。
check("F3 长按菜单保留 Task129b 角色项（免密链唯一入口）",
      al.count("ame129b_switchAccountAtIndexPath:indexPath toProfile:p") >= 1
      and "contextMenuConfigurationForRowAtIndexPath" in al
      # Task223 重锚：菜单重构为 ame223_accountMenuItemsAtIndexPath 单一事实源
      # （长按与行内 ⋯ 共用），当前角色标注从 UIMenuElementStateOn 换 "✓ " 标题前缀。
      and "ame223_accountMenuItemsAtIndexPath" in al
      and '"✓ %@"' in al)
check("F4 account.switch_role.button l10n 四语言（键保留，未消费也保留）",
      all('"account.switch_role.button"' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]))
check("F6 account.switch_role.button l10n 四语言",
      all('"account.switch_role.button"' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]))

print("== G. 公告仓库托管 JSON ==")
ans = rd("Natives/AnnouncementService.m")
import json as _json
check("G1 仓库根 announcements.json 存在且结构合法",
      os.path.exists(os.path.join(REPO, "announcements.json"))
      and (lambda d: isinstance(d.get("announcements"), list) and len(d["announcements"]) > 0
           and all(k in d["announcements"][0] for k in ["id", "title", "date", "summary", "content"]))(
          _json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))))
check("G2 主源常量 = raw.githubusercontent（仓库根 announcements.json）",
      'https://raw.githubusercontent.com/Gsjsjzhznsz/Air-Minecraft-iOS-Launcher/main/announcements.json' in ans)
check("G3 jsDelivr 镜像常量（国内可达性第二源）",
      'https://cdn.jsdelivr.net/gh/Gsjsjzhznsz/Air-Minecraft-iOS-Launcher@main/announcements.json' in ans)
check("G4 源级联 + 已知默认值识别（自定义独占 / 旧上游归一）",
      "announcementSourceURLs" in ans and "kLegacyAnnouncementURL" in ans
      and "return @[url];" in ans)
check("G5 逐源降级（失败/解析失败都试下一个）",
      "ame130_fetchFromSources:sources index:index + 1" in ans)
check("G6 全失败 → 缓存 → 内置（Task129h 链保留 + Task130 日志锚）",
      ans.find("cached.count > 0") < ans.find("builtinAnnouncements]")
      and "Task130: all announcement sources unreachable" in ans
      and "serving bundled offline announcements" in ans)
check("G7 PLPreferences news_url 默认 = 仓库 raw 地址",
      '@"news_url": @"https://raw.githubusercontent.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/main/announcements.json"' in plp)
check("G8 内置兜底措辞更新（不再指旧上游 API）",
      "GitHub" in rd("Natives/resources/announcements-fallback.json")
      and "air-api.vercel.app/api" not in rd("Natives/resources/announcements-fallback.json"))
check("G9 头文件注释同步（AnnouncementService.h / AnnouncementItem.h）",
      "Task 130" in rd("Natives/AnnouncementService.h") and "Task 130" in rd("Natives/AnnouncementItem.h"))

print("== H. 语法门 ==")
def balance(path):
    src = open(path, encoding="utf-8").read()
    i, n = 0, len(src)
    cnt = {"{": 0, "(": 0, "[": 0}
    pairs = {"}": "{", ")": "(", "]": "["}
    state = "code"
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
            if c in cnt:
                cnt[c] += 1
            elif c in pairs:
                if cnt[pairs[c]] <= 0:
                    return False
                cnt[pairs[c]] -= 1
            i += 1
        elif state == "line":
            if c == "\n":
                state = "code"
            i += 1
        elif state == "block":
            if c == "*" and nxt == "/":
                state = "code"; i += 2; continue
            i += 1
        elif state == "str":
            if c == "\\":
                i += 2; continue
            if c == '"':
                state = "code"
            i += 1
        elif state == "chr":
            if c == "\\":
                i += 2; continue
            if c == "'":
                state = "code"
            i += 1
    return all(v == 0 for v in cnt.values()) and state == "code"

TOUCHED = [
    "Natives/ctxbridges/FSRRCASSource.h", "Natives/ctxbridges/osm_bridge.mm",
    "Natives/ctxbridges/mgl_fsr.mm", "Natives/JavaLauncher.m",
    "Natives/LauncherPreferencesViewController.m", "Natives/PLPreferences.m",
    "Natives/LauncherPreferences.m", "Natives/LauncherPreferences.h",
    "Natives/AppDelegate.m", "Natives/AccountListViewController.m",
    "Natives/AnnouncementService.m",
    "Natives/external/MobileGlues/MobileGlues-cpp/gl/FSR1/FSR1.cpp",
    "Natives/external/MobileGlues/MobileGlues-cpp/gl/FSR1/FSR1.h",
    "Natives/external/MobileGlues/MobileGlues-cpp/config/config.cpp",
    "Natives/external/MobileGlues/MobileGlues-cpp/config/config.h",
    "Natives/external/MobileGlues/MobileGlues-cpp/config/settings.cpp",
    "Natives/external/MobileGlues/MobileGlues-cpp/config/settings.h",
]
check("H1 触碰文件括号平衡（17 文件全过）",
      all(balance(os.path.join(REPO, p)) for p in TOUCHED))

grammar_ok = True
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    src = open(os.path.join(REPO, f"Natives/resources/{lang}.lproj/Localizable.strings"),
               encoding="utf-8").read().splitlines()
    in_block = False
    for ln in src:
        t = ln.strip()
        if in_block:
            if "*/" in t:
                in_block = False
            continue
        if t.startswith("/*"):
            if "*/" not in t:
                in_block = True
            continue
        if not t or t.startswith("//"):
            continue
        if not re.match(r'^"[^"]+"\s*=\s*".*";\s*$', t):
            grammar_ok = False
check("H2 四语言 .strings 行语法（块注释感知）", grammar_ok)

sets = []
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    sets.append(set(re.findall(r'^"([^"]+)"\s*=',
                  rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M)))
# Task222 重锚：2715 = Task212 基线 2520 + Task222 45 + Task223 41
check("H3 四语言键集一致（Task157 基线 2228 = Task156 基线 2228 + Task157 组件键 2）",
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2715,  # Task222 重锚：+21 陶瓦联机键
      f"counts={[len(s) for s in sets]}")

delta_ok = True
for p in TOUCHED:
    cur = rd(p)
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{p}"],
                          capture_output=True, text=True).stdout
    if not head:
        continue  # 新文件（FSRRCASSource.h / announcements.json 无 HEAD 基线）
    if not all(cur.count(a) - cur.count(b) == head.count(a) - head.count(b)
               for a, b in [("{", "}"), ("(", ")"), ("[", "]")]):
        delta_ok = False
check("H4 裸括号 delta 与 HEAD 一致（提交前工作树门，提交后自愈口径不变）", delta_ok)

print("== I. 级联 ==")
r = subprocess.run([sys.executable, os.path.join(REPO, "scripts/verify_task129.py")],
                   capture_output=True, text=True, timeout=300)
check("I1 verify_task129 ALL PASS（含 119_124/125_128/112_118 子级联）",
      "ALL PASS" in r.stdout and r.returncode == 0,
      r.stdout[-120:] if r.returncode else "")

print()
print(f"==== RESULT: {'ALL PASS' if FAIL == 0 else 'FAILED'} ({PASS}/{PASS + FAIL}) ====")
sys.exit(1 if FAIL else 0)
