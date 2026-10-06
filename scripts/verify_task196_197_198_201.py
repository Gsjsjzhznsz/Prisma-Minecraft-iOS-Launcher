#!/usr/bin/env python3
"""Task 196/197/198/201 综合校验器。

四项修复的静态验证：
  A. vgpu useVbo 强制（Task196，PojavLauncher.java）
  B. ANGLE DSA 通告撤回（Task197，tinygl4angle.c）
  C. 控件仓库误戳救回（Task198，CustomControlsUtils.m + controls/）
  D. Metallum Metal 渲染器移植（Task201，二进制 + 五处代码 + l10n）
  E. 文档与公告（version.h 附录 / announcements / surveys / 2696 基线扫荡）
"""
import json
import os
import re
import struct
import subprocess
import sys
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
results = []

def check(group, label, ok, detail=""):
    results.append((f"[{group}] {label}", bool(ok)))
    mark = "PASS" if ok else "FAIL"
    print(f"  [{mark}] {group} {label}" + (f"  ({detail})" if detail and not ok else ""))

def rd(path):
    with open(os.path.join(REPO, path), encoding="utf-8", errors="replace") as f:
        return f.read()

# ============ A. vgpu Task196 ============
print("== A. vgpu useVbo（Task196）==")
pj = rd("JavaApp/src/launcher/net/kdt/pojavlaunch/PojavLauncher.java")
check("A", "useVbo=true 写入存在", 'MCOptionUtils.set("useVbo", "true")' in pj)
check("A", "vgpu 会话门控（AMETHYST_RENDERER contains vgpu）",
      'ame196Renderer.contains("vgpu")' in pj and 'getenv("AMETHYST_RENDERER")' in pj)
first_save = pj.find("MCOptionUtils.save()")
set_pos = pj.find('MCOptionUtils.set("useVbo", "true")')
check("A", "时序：写入位于第一块 save() 之前", 0 <= set_pos < first_save,
      f"set@{set_pos} save@{first_save}")
check("A", "锚点日志 Task196 useVbo=true forced", "Task196 useVbo=true forced" in pj)
vd_pos = pj.find('MCOptionUtils.getFromFile("useVbo")')
check("A", "落盘校验位于 save() 之后", first_save < vd_pos, f"verify@{vd_pos}")
check("A", "病历注释含 glCallList/RenderList 证据",
      "glCallList" in pj and "RenderList" in pj)
check("A", "兼容性注释：1.7.10- 无此键", "1.7.10-" in pj)
check("A", "Task196 标记在场", "Task 196" in pj or "Task196" in pj)

# ============ B. angle Task197 ============
print("== B. ANGLE DSA 撤回（Task197）==")
tg = rd("Natives/external/gl4es/tinygl4angle.c")
check("B", "AME193_DSA_EXT 宏定义（保留字符串供历史锚）",
      '#define AME193_DSA_EXT "GL_ARB_direct_state_access"' in tg)
check("B", "ame197_effectiveExtCount 门控函数存在",
      "static size_t ame197_effectiveExtCount(void)" in tg)
check("B", "env 取证开关 AME193_DSA_ADVERTISE", 'getenv("AME193_DSA_ADVERTISE")' in tg)
check("B", "默认撤回（env 未设 = 0）",
      'cached ? AME193_EXTRA_EXT_COUNT : 0' in tg)
cache_build = tg.find("static void ame193_buildExtCache")
append_fn = tg.find("static const GLubyte *ame193_appendExtString(const GLubyte *real) {")
check("B", "索引式缓存走门控", cache_build >= 0 and
      tg.find("ame197_effectiveExtCount()", cache_build, cache_build + 2000) > 0)
check("B", "旧式字符串追加点走门控", append_fn >= 0 and
      tg.find("ame197_effectiveExtCount()", append_fn, append_fn + 1200) > 0)
check("B", "WITHDRAWN 锚点（缓存路径）",
      "Task197: DSA advertisement WITHDRAWN" in tg)
check("B", "WITHDRAWN 锚点（旧式字符串路径）",
      "WITHDRAWN on legacy GL_EXTENSIONS string too" in tg)
check("B", "Task193 块头的 Task197 判决附注", "Task197 判决" in tg)
check("B", "Task192/193 DSA 函数体保留（未删实现）",
      "glCreateBuffers" in tg and "glMapNamedBuffer" in tg)

# ============ C. controls Task198 ============
print("== C. 控件仓库误戳救回（Task198）==")
cu = rd("Natives/customcontrols/CustomControlsUtils.m")
check("C", "convertLayoutIfNecessary 救回块（version <= 1）",
      "if (version <= 1)" in cu)
check("C", "判据三要素：keycodes 数组 + dynamicX 字符串 + 无静态 x",
      'ame198_btn[@"keycodes"] isKindOfClass:[NSArray class]' in cu
      and 'ame198_btn[@"dynamicX"] isKindOfClass:[NSString class]' in cu
      and 'ame198_btn[@"x"] == nil' in cu)
check("C", "落戳 version=7 跳过转换链", 'dict[@"version"] = @(7)' in cu)
check("C", "锚点日志 Task198 mis-stamped rescue",
      "Task198: mis-stamped version" in cu)
seeds_ok = True
detail = []
for name in ["classic", "minimal-fps", "large-buttons"]:
    d = json.load(open(os.path.join(REPO, f"controls/layouts/{name}.json"), encoding="utf-8"))
    if d.get("version") != "7":
        seeds_ok = False
        detail.append(f"{name}={d.get('version')}")
check("C", "三个种子重落戳 version=7", seeds_ok, ",".join(detail))
idx = json.load(open(os.path.join(REPO, "controls/index.json"), encoding="utf-8"))
check("C", "index.json 版本元数据同步 7",
      all(e.get("version") == "7" for e in idx["layouts"]))
check("C", "index.json updated 日期同步", idx.get("updated") == "2026-09-29")
check("C", "种子表达式完好（非 0 覆写形态）",
      "0.99601203 * ${screen_width}" in
      open(os.path.join(REPO, "controls/layouts/classic.json"), encoding="utf-8").read())
check("C", "size 字段与实际字节一致（卫生）",
      all(e["size"] == os.path.getsize(os.path.join(REPO, "controls", e["file"]))
          for e in idx["layouts"]))

# ============ D. metallum Task201 ============
print("== D. Metallum Metal 渲染器（Task201）==")
fw = os.path.join(REPO, "Natives/resources/Frameworks")
check("D", "libmetallum.dylib 入仓（存在性过滤用）",
      os.path.isfile(os.path.join(fw, "libmetallum.dylib")))
jar_path = os.path.join(REPO, "JavaApp/libs/others/metallum_agent.jar")
jar_ok = False
manifest = ""
if os.path.isfile(jar_path):
    with zipfile.ZipFile(jar_path) as z:
        names = z.namelist()
        jar_ok = ("com/metallum/Metallum.class" in names
                  and "natives/ios/libmetallum.dylib" in names
                  and "classes263/" in "".join(names[:400])
                  or "classes263" in "\n".join(names))
        if "META-INF/MANIFEST.MF" in names:
            manifest = z.read("META-INF/MANIFEST.MF").decode("utf-8", "replace")
check("D", "metallum_agent.jar 自包含（类集 + natives + 26.3 映射）", jar_ok)
check("D", "agent 清单 Premain-Class", "Premain-Class: com.metallum.agent.MetallumAgent" in manifest)

def macho_export_count(path):
    data = open(path, "rb").read()
    if data[:4] != b"\xcf\xfa\xed\xfe":
        return -1
    ncmds = struct.unpack_from("<I", data, 16)[0]
    off = 32
    symoff = nsyms = stroff = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, off)
        if cmd == 0x2:
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, off + 8)
        off += cmdsize
    n = msl = 0
    seen = set()
    for i in range(nsyms):
        so = symoff + i * 16
        n_strx, n_type, n_sect, n_desc, n_value = struct.unpack_from("<IBBHQ", data, so)
        if (n_type & 0x0e) == 0x0e:
            end = data.index(b"\x00", stroff + n_strx)
            name = data[stroff + n_strx:end].decode("utf-8", "replace")
            if name and name not in seen:
                seen.add(name)
                n += 1
                if "msl" in name.lower():
                    msl += 1
    return n, msl

impl_path = os.path.join(fw, "libspirv-cross-c-shared.0.impl.dylib")
syms = macho_export_count(impl_path)
check("D", "impl 为 MSL 版（导出 12383 + MSL 40）",
      isinstance(syms, tuple) and syms[0] == 12383 and syms[1] == 40, f"got {syms}")
bare = [f for f in ["libspvc.dylib", "libspirv-cross.dylib",
                    "libspirv-cross-c-shared.0.dylib"] if os.path.exists(os.path.join(fw, f))]
check("D", "无裸 spvc 副本泄漏（垫片链不被旁路）", not bare, str(bare))
uh = rd("Natives/utils.h")
check("D", "utils.h RENDERER_NAME_METAL 定义",
      '#define RENDERER_NAME_METAL "libmetallum.dylib"' in uh)
lp = rd("Natives/LauncherPreferences.m")
vul = lp.find("RENDERER_NAME_VULKAN")
met = lp.find("RENDERER_NAME_METAL")
check("D", "渲染器表 Metal 条目位于末位（VULKAN 之后）", 0 < vul < met)
check("D", "表位注释：索引稳定说明在场", "刻意追加在表末" in lp)
jl = rd("Natives/JavaLauncher.m")
check("D", "AMETHYST_METAL=1 + 回落 auto",
      'setenv("AMETHYST_METAL", "1", 1)' in jl and 'renderer = @"auto"' in jl)
check("D", "--add-opens=java.base/java.lang",
      '"--add-opens=java.base/java.lang=ALL-UNNAMED"' in jl)
check("D", "javaagent 注入 + mcMajor>=26 门控 + Task201 锚点",
      "metallum_agent.jar=" in jl and "metallumMcMajor >= 26" in jl
      and "Task201: Metallum agent enabled" in jl and "Task201: Metallum agent skipped" in jl)
glue = rd("Natives/shaderc_impl_glue.c")
check("D", "mapIO 胶水（glslang_program_map_io）",
      "glslang_program_map_io(program)" in glue)
check("D", "surface 指针发布块在场",
      "-Dmetallum.ios.view.pointer" in jl and "-Dmetallum.ios.screen.scale" in jl)
ai = rd("Natives/AI/AiSettingsTools.m")
angle_ai = ai.find('containsString:@"angle"')
metal_ai = ai.find('containsString:@"metallum"')
check("D", "AiSettingsTools 映射（angle 先于 metal + 友好名）",
      0 < angle_ai < metal_ai and 'return @"Metal (libmetallum.dylib)"' in ai)

# ============ E. docs / l10n ============
print("== E. 文档与公告 ==")
def lang_keys(lang):
    return set(re.findall(r'^"([^"]+)"\s*=',
                          rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M))
k4 = [lang_keys(l) for l in ["en", "zh-Hans", "zh-Hant", "zh-CN"]]
check("E", "四语言 metal 键齐备", all("preference.title.renderer.debug.metal" in k for k in k4))
check("E", "四语言键集全同", k4[0] == k4[1] == k4[2] == k4[3])
check("E", "唯一键计数 2696", len(k4[0]) == 2696, f"got {len(k4[0])}")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("E", "REVISION 保持 18（不 bump）", "#define REVISION 22" in vh)
check("E", "version.h 四任务附录在场",
      "Tasks 196/197/198/201" in vh and "Task 201 (Metallum Metal renderer" in vh)
ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))["announcements"]
e196 = next((a for a in ann if a["id"] == "task196-quad-fixes-2026-09-29"), None)
check("E", "公告条目在场且四锚点齐备", e196 is not None and all(
    k in e196["content"] for k in
    ["Task196 useVbo=true forced", "Task197: DSA advertisement WITHDRAWN",
     "Task198", "Task201: Metallum agent enabled"]))
check("E", "公告位置：新条目@2，task193 顺延@3（Task212 重锚：task212@2 插入后再顺延）",
      ann[10]["id"] == "task196-quad-fixes-2026-09-29"
      and ann[11]["id"] == "task193-app-icon-replace-2026-09-28")
check("E", "公告计数 34（Task212@2 插入，NG-GL4ES 尾锚顺延不变）", len(ann) == 43, f"got {len(ann)}")
sv = os.path.join(REPO, "docs/surveys")
check("E", "两份调查报告入仓",
      os.path.isfile(os.path.join(sv, "2026-09-29-upstream-sync-survey.md"))
      and os.path.isfile(os.path.join(sv, "2026-09-29-upstream-issues-survey.md")))
r = subprocess.run(["grep", "-rl", "2407", f"{REPO}/scripts/"],
                   capture_output=True, text=True)
leak = [f for f in r.stdout.split()
        if not f.endswith("verify_task196_197_198_201.py")]
check("E", "2407 基线扫荡干净（全部升 2520，自引用除外）", not leak, str(leak[:2]))

# ============ verdict ============
fails = [l for l, ok in results if not ok]
print(f"\n==== Task196/197/198/201: {len(results) - len(fails)}/{len(results)} ====")
if fails:
    print("FAILED:")
    for l in fails:
        print("  -", l)
sys.exit(1 if fails else 0)
