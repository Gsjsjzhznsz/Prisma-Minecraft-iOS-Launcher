#!/usr/bin/env python3
# Task 193 -- app icon replacement (upstream Amethyst hexagon -> user grass-block cube).
# Scope: ONLY the Light family that iOS actually serves (1024x3 + 120 + 152). Everything
# else upstream stays pristine. Blob hashes below are content-addressed (stable forever).
import os, sys, io, json, struct, subprocess

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASS, FAIL = [], []
def check(group, name, cond, detail=""):
    (PASS if cond else FAIL).append((group, name, detail))
    print(("  PASS " if cond else "  FAIL ") + f"[{group}] {name}" + ("" if cond else f"  -- {detail}"))

def blob(path):
    return subprocess.run(["git", "hash-object", path], capture_output=True, text=True).stdout.strip()

def png_size(path):
    with open(path, "rb") as f:
        head = f.read(33)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])

# ============ A. replaced files: valid PNG, exact dimensions ============
print("== A. 替换集尺寸与 PNG 完整性 ==")
A = [
    ("Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png", 1024),
    ("Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024-Transparent.png", 1024),
    ("Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024-Monochrome-White.png", 1024),
    ("Natives/resources/AppIcon-Light60x60@2x.png", 120),
    ("Natives/resources/AppIcon-Light76x76@2x~ipad.png", 152),
]
for path, size in A:
    ok = os.path.exists(path) and png_size(path) == (size, size)
    check("A", f"{size}x{size}: {os.path.basename(path)}", ok, f"actual={png_size(path) if os.path.exists(path) else 'missing'}")

# ============ B. replaced-vs-upstream: blobs moved, trio same-image ============
print("== B. 替换断言（blob 已离开上游内容） ==")
UP_OLD = {
    "Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024.png": "03f063d5b3d3e518503231e8ef616609dc31aa1b",
    "Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024-Transparent.png": "03f063d5b3d3e518503231e8ef616609dc31aa1b",
    "Natives/Assets.xcassets/AppIcon-Light.appiconset/1024x1024-Monochrome-White.png": "03f063d5b3d3e518503231e8ef616609dc31aa1b",
    "Natives/resources/AppIcon-Light60x60@2x.png": "86bf1a2f7059bb24196a06ff9abd5e77937634d4",
    "Natives/resources/AppIcon-Light76x76@2x~ipad.png": "fd634b457a540b43ecf7ea26f1a2d5ac2f4f6118",
}
new_blobs = {}
for path, old in UP_OLD.items():
    b = blob(path)
    new_blobs[path] = b
    check("B", f"replaced: {os.path.basename(path)}", b != old, f"now={b[:12]} old={old[:12]}")
trio = {new_blobs[A[0][0]], new_blobs[A[1][0]], new_blobs[A[2][0]]}
check("B", "1024 三外观同图一份（与上游同约定）", len(trio) == 1, f"distinct={len(trio)}")

# ============ C. untouched: upstream heritage stays byte-identical ============
print("== C. 上游资产不动断言 ==")
UP_KEEP = {
    "Natives/Assets.xcassets/AppIcon-Dark.appiconset/AppIcon-Dark_1024x1024.png": "a0432d5fe04cc5c714b81960e8edfbada084c403",
    "Natives/Assets.xcassets/AppIcon-Development.appiconset/AppIcon-Development_1024x1024.png": "9075d45eb2cf7dd9b4c923fe86dce07d99bb0121",
    "Natives/resources/AppIcon-Dark60x60@2x.png": "201ad8f125b2647dcef91d6639706d62f6165049",
    "Natives/resources/AppIcon-Dark76x76@2x~ipad.png": "43ff9a88815ab269ed0848371ce625b548ad01c7",
    "Natives/resources/AppIcon-Development60x60@2x.png": "196e31c5ab0a5a8307482ada0a38539e964dd7a9",
    "Natives/resources/AppIcon-Development76x76@2x~ipad.png": "8df3c3566db65545e46148d64f725fafc8a92f62",
    "Natives/resources/AppIcon60x60@2x.png": "0260a341aede9e2efd395852abdfb55d4e1e635d",
    "Natives/resources/AppIcon76x76@2x~ipad.png": "d38f16e9f319f9f78b691de82c35a7c009f88c42",
    "Natives/Assets.xcassets/AppLogo-Vector.imageset/1024x1024-Transparent.png": "54d3a349d8c1ff3ab21c2e57794bf284c705db14",
    "Natives/Assets.xcassets/AppIcon-Light.appiconset/Contents.json": "4819ac371c028eefd057dbdb474f45bdd2935de9",
}
for path, up in UP_KEEP.items():
    b = blob(path)
    check("C", f"pristine: {os.path.basename(os.path.dirname(path))}/{os.path.basename(path)}", b == up, f"now={b[:12]} upstream={up[:12]}")

# ============ D. config purity: filename-referencing configs untouched in meaning ============
print("== D. 配置纯净度（引用未动） ==")
plist = io.open("Natives/Info.plist", encoding="utf-8", errors="replace").read()
check("D", "Info.plist iPhone 主图标仍为 AppIcon-Light60x60", "AppIcon-Light60x60" in plist)
check("D", "Info.plist iPad 主图标仍含 AppIcon-Light76x76", "AppIcon-Light76x76" in plist)
check("D", "Info.plist CFBundleIconName 仍为 AppIcon-Light", "<string>AppIcon-Light</string>" in plist)
check("D", "无后缀 AppIcon60x60 依旧零引用（不动它的依据）", "AppIcon60x60" not in plist)
vh = io.open("Natives/external/MobileGlues/MobileGlues-cpp/version.h", encoding="utf-8", errors="replace").read()
check("D", "version.h 含 Task 193 附录", "Amethyst Task 193" in vh)

# ============ E. provenance: source artwork + scripts present ============
print("== E. 素材与脚本溯源 ==")
check("E", "根目录 IMG_9288.jpeg 在场（用户上传源）", os.path.exists("IMG_9288.jpeg"))
if os.path.exists("IMG_9288.jpeg"):
    from PIL import Image
    try:
        im = Image.open("IMG_9288.jpeg"); im.load()
        check("E", "源图 690x690 可解码", im.size == (690, 690), f"actual={im.size}")
    except Exception as e:
        check("E", "源图 690x690 可解码", False, str(e))
for s in ("scripts/task193_icon.py", "scripts/task193_announce.py", "scripts/task193_docs.py", "scripts/verify_task193.py"):
    check("E", f"script: {os.path.basename(s)}", os.path.exists(s))

# ============ F. announcement: task193@2, family shifted, pin intact ============
print("== F. 公告窗口族 ==")
ann = json.loads(io.open("announcements.json", encoding="utf-8").read())["announcements"]
check("F", "条目数 -> 34（Task212@2 插入，窗口族顺延）", len(ann) == 43, f"actual={len(ann)}")
check("F", "Task212 重锚：task193 顺延至 [8]，task190 顺延至 [9]，置顶公告 [0] 未动",
      len(ann) > 6 and ann[11]["id"] == "task193-app-icon-replace-2026-09-28"
      and ann[12]["id"].startswith("task190-") and ann[0]["id"].startswith("server-recommend"))

# ============ G. re-anchored verifiers import-clean ============
print("== G. 重锚校验器语法完好 ==")
for v in ("scripts/verify_task173.py", "scripts/verify_task190.py"):
    src = io.open(v, encoding="utf-8").read()
    try:
        compile(src, v, "exec")
        check("G", f"{os.path.basename(v)} compile-ok", True)
    except SyntaxError as e:
        check("G", f"{os.path.basename(v)} compile-ok", False, str(e))


# ============ H. vgpu Task193（fpe NULL 守卫 + 四步归因 + 单次上传）============
print("== H. vgpu Task193（fpe NULL 守卫 + 四步归因 + 单次上传）==")
def rd(p):
    return io.open(p, encoding="utf-8", errors="replace").read()
fpe = rd("Natives/external/vgpu/src/gl/fpe.c")
drawing = rd("Natives/external/vgpu/src/gl/drawing.c")
gl4es_c = rd("Natives/external/vgpu/src/gl/gl4es.c")
check("H", "fpe_glDrawElements 影子重绑对 NULL 免疫（indices && 前置）",
      "if(indices && glstate->vao->elements" in fpe)
check("H", "ame191 四步归因插桩（preErr/bindErr/dataErr/drawErr）",
      all(s in drawing for s in ["ame193_ePre", "ame193_eBind", "ame193_eData", "ame193_eDraw"]))
check("H", "单次 glBufferData 上传（listdraw 同构）",
      "gles_glBufferData(GL_ELEMENT_ARRAY_BUFFER, bytes, indices, GL_DYNAMIC_DRAW);" in drawing)
check("H", "旧 SubData 两段式退役",
      "gles_glBufferSubData(GL_ELEMENT_ARRAY_BUFFER, 0, bytes, indices);" not in drawing)
check("H", "EAB 绑定查询用 ELEMENT_ARRAY_BUFFER_BINDING=0x8895（Task202 勘误：Task193 的 0x8894 实为 ARRAY_BUFFER_BINDING——顶点而非索引缓冲）",
      "#define AME193_EAB_BINDING 0x8895" in drawing)
check("H", "gl4es_scratch_indices 退役为绑定+名字（size 跟踪移除）",
      "Task193：本函数退役为" in gl4es_c and "scratch_indices_size < alloc" not in gl4es_c)
check("H", "首调用基线 + 前 8 错误调用日志（装机锚点）",
      "VGPU Task193 step-attrs" in drawing and "baseline: first call clean" in drawing)

# ============ I. gl4es 构造器临时上下文引导 ============
print("== I. gl4es 构造器临时上下文引导 ==")
egl = rd("Natives/egl_bridge.m")
# Task212 重锚：holy gl4es 退役——Task193 的构造器引导链（pbuffer+ES3 铺垫、
# 显式 dlopen、资源释放、失败安全）整体随 dylib 删除，由 egl_bridge 的退役
# 注释收档；接棒者 gl4eszl2 走 ame211_gl4eszl2_boot（MakeCurrent 后显式
# initialize_gl4es，构造器不存在）。本节断言退役态而非在场。
check("I", "Task193 引导块随 holy gl4es 退役收档（Task212 重锚）",
      "holy gl4es（libgl4es_114.dylib）整体退役" in egl and "s_ame193_gl4esDone" not in egl)
check("I", "退役后无残留引导符号（pbuffer/显式 dlopen 全清）",
      "ame193_createPbuffer" not in egl
      and 'dlopen("@rpath/libgl4es_114.dylib", RTLD_NOW | RTLD_GLOBAL)' not in egl)
check("I", "接棒路径在场（gl4eszl2 的 MakeCurrent 后初始化 = 构造器问题的终态解）",
      "ame211_gl4eszl2_boot();" in egl and "initialize_gl4es" in egl)

# ============ J. gl_bridge 同 layer 表面复用 ============
print("== J. gl_bridge 同 layer 表面复用 ==")
glb = rd("Natives/ctxbridges/gl_bridge.m")
check("J", "Task193 复用块 + 层→表面单例",
      "Task193：同 layer 表面复用" in glb and "s_ame193_layerSurface" in glb)
check("J", "复用命中日志（装机锚点）", "eglCreateWindowSurface REUSED" in glb)
check("J", "首个 (layer, surface) 记录",
      "s_ame193_layerCF = (CFTypeRef)CFBridgingRetain(swapLayerForEGL);" in glb)
check("J", "CFBridgingRetain 平衡（reqCF 释放）",
      "if (ame193_reqCF != NULL) CFRelease(ame193_reqCF);" in glb)

# ============ K. convertV1Layout addObject:nil 根修 ============
print("== K. convertV1Layout addObject:nil 根修 ==")
ccu = rd("Natives/customcontrols/CustomControlsUtils.m")
check("K", "keycode addObject nil 防护（integerValue 兜底）",
      '[keycodes addObject:@([btnDict[@"keycode"] integerValue])];' in ccu)
check("K", "病历注释（符号化调用链）",
      "_convertV1Layout+0x410" in ccu and "FileListViewController" in ccu)
check("K", "其余三处 addObject 为常量（无 nil 面）",
      ccu.count("[keycodes addObject:@(GLFW_KEY_") == 3)

# ============ L. ANGLE DSA 通告 + Map/VAO 族 + dlsym 取证 ============
print("== L. ANGLE DSA 通告 + Map/VAO 族 + dlsym 取证 ==")
tg = rd("Natives/external/gl4es/tinygl4angle.c")
check("L", "GL_ARB_direct_state_access 通告", '"GL_ARB_direct_state_access"' in tg)
check("L", "glGetStringi 导出 + 扩展缓存",
      "ame193_buildExtCache" in tg and "const GLubyte *glGetStringi(GLenum name, GLuint index)" in tg)
check("L", "glGetIntegerv 拦截（NUM_EXTENSIONS +1）",
      "void glGetIntegerv(GLenum pname, GLint *params)" in tg and "GL_NUM_EXTENSIONS" in tg)
check("L", "glGetString(GL_EXTENSIONS) 追加（旧式路径）", "ame193_appendExtString(result)" in tg)
check("L", "Map/Storage 族（7 函数）",
      all(s in tg for s in ["glMapNamedBufferRange", "glUnmapNamedBuffer",
                            "glGetNamedBufferSubData", "glNamedBufferStorage",
                            "glFlushMappedNamedBufferRange", "glClearNamedBufferSubData"]))
check("L", "VAO-DSA 族（8 函数）",
      all(s in tg for s in ["glCreateVertexArrays", "glVertexArrayElementBuffer",
                            "glVertexArrayVertexBuffer", "glVertexArrayAttribFormat",
                            "glVertexArrayAttribBinding", "glEnableVertexArrayAttrib",
                            "glDisableVertexArrayAttrib", "glVertexArrayBindingDivisor"]))
check("L", "dlsym GL NULL 取证（hooked_dlsym；Task202 升级为 ame202_logNullGL 去重全量）",
      "GL symbol resolution NULL (dedup" in rd("Natives/main_hook.m")
      and "ame202_logNullGL" in rd("Natives/main_hook.m"))
check("L", "LWJGL natives dlsym 重绑（触发面 + 镜像扫描）",
      'strstr(path, "lwjgl") != NULL' in rd("Natives/main_hook.m") and
      "isLwjglNative" in rd("Natives/sdl3_hook.m"))
r = subprocess.run(["bash", "scripts/task193_tinygl_syntax.sh"], capture_output=True, text=True, timeout=180)
check("L", "tinygl4angle 真源码语法门（task193_tinygl_syntax.sh）",
      r.returncode == 0 and "SYNTAX OK" in r.stdout, r.stdout[-200:] + r.stderr[-200:])

# ============ M. i18n UI 清扫（180 键 ×4 主语言）============
print("== M. i18n UI 清扫（180 键 ×4 主语言）==")
import re as _re
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    n = len(set(_re.findall(r'^"([^"]+)"\s*=',
                            rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), _re.M)))
    check("M", f"{lang} 唯一键 2696", n == 2696, f"got {n}")
for lang in ["en", "zh-Hans", "zh-CN", "zh-Hant"]:
    t = rd(f"Natives/resources/{lang}.lproj/Localizable.strings")
    check("M", f"{lang} ame193 键 179 个", len(_re.findall(r'^"ame193\.', t, _re.M)) == 179)
mp = rd("Natives/MultiplayerViewController.m")
check("M", "MP 硬编码中文清零（localize 包装后）", mp.count('localize(@"ame193.') >= 100)
check("M", "混合语 JIT 串迁移",
      'localize(@"ame193.misc.jit_not_handled"' in rd("Natives/LauncherRightPanelViewController.m"))
check("M", "既有键复用（新建版本→i18n_str_2027 修英文模式比较失配）",
      'isEqualToString:localize(@"i18n_str_2027"' in rd("Natives/VersionManagerViewController.m"))
r = subprocess.run([sys.executable, "scripts/task191_validate_strings.py"],
                   capture_output=True, text=True, timeout=300)
check("M", "全部 lproj 表解析 OK（task191 tokenizer）",
      r.returncode == 0 and "FAIL" not in r.stdout and "OK" in r.stdout)

# ============ N. MobileGlues 2.0.18 ============
print("== N. MobileGlues 2.0.18 ==")
vh2 = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
md = rd("Natives/external/MobileGlues/MobileGlues-cpp/gl/multidraw.cpp")
check("N", "REVISION 18", "#define REVISION 22" in vh2)
check("N", "上游 0f1e10b multidraw grow-only 移植",
      "if (staged.size() < static_cast<size_t>(primcount))" in md and
      "Upstream 0f1e10b (2.0.18 sync)" in md)
check("N", "FSR1 兼容审计注记（478d479 已在树 + config 键对齐）",
      "FSR1 compatibility audit" in vh2 and "fsr1Setting" in vh2)
settings = rd("Natives/external/MobileGlues/MobileGlues-cpp/config/settings.cpp")
jl = rd("Natives/JavaLauncher.m")
check("N", "FSR1 config 键两端对齐（fsr1Setting/fsr1RcasSharpness）",
      'config_get_int((char*)"fsr1Setting")' in settings and
      'config[@"fsr1Setting"]' in jl and
      'config_get_double((char*)"fsr1RcasSharpness"' in settings and
      'config[@"fsr1RcasSharpness"]' in jl)
check("N", "RCAS 负值 off 语义（两端）", "negative (not NaN) = explicit off" in settings)

# ============ O. 级联 spot check ============
print("== O. 级联 ==")
for v in ["verify_task188", "verify_task189", "verify_task190", "verify_task191", "verify_task192"]:
    r = subprocess.run([sys.executable, f"scripts/{v}.py"], capture_output=True, text=True, timeout=600)
    low = r.stdout.lower()
    ok = ("0 fail" in low or "0 failed" in low or "all pass" in low or "all green" in low)
    check("O", f"级联 {v}", ok, r.stdout[-160:])


print(f"\n===== verify_task193: {len(PASS)} PASS / {len(FAIL)} FAIL =====")
sys.exit(1 if FAIL else 0)
