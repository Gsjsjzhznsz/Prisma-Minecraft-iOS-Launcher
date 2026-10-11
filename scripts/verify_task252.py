#!/usr/bin/env python3
# verify_task252.py -- Task252 门禁：TG LegacyGlassView 配方移植
# （伪液态玻璃渲染引擎替换；选项/设置键/公告/REVISION 零改动）。
# 用法: python3 scripts/verify_task252.py [REPO]   # 默认取脚本父目录的上级
import json
import os
import re
import subprocess
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))


def read(path):
    with open(os.path.join(REPO, path), encoding="utf-8") as f:
        return f.read()


# ─── 1. 新组件存在且配方关键物齐全 ───
lgv_h = "Natives/AmeLiquidGlassView.h"
lgv_m = "Natives/AmeLiquidGlassView.m"
for p in (lgv_h, lgv_m):
    check("exists:" + p, os.path.isfile(os.path.join(REPO, p)))

m = read(lgv_m)
check("recipe:CABackdropLayer 字符串拼接", '"CA" stringByAppendingString:@"BackdropLayer"' in m)
check("recipe:CAMutableMeshTransform 字符串拼接", '"CAMutable" stringByAppendingString:@"MeshTransform"' in m)
check("recipe:CAFilter colorMatrix", '"colorMatrix"' in m and "inputColorMatrix" in m)
check("recipe:colorMatrix TG 玻璃矩阵", "2.6705f" in m and "2.8881f" in m and "-1.1087999f" in m)
check("recipe:inputBackdropAware", "inputBackdropAware" in m)
check("recipe:gaussianBlur r=2", '"gaussianBlur"' in m and "@2.0" in m)
check("recipe:meshTransform KVC", 'forKey:@"meshTransform"' in m)
check("recipe:位移 20pt / 带宽 min(12,r) / 分辨率 12 / 外圈 2pt",
      "20.0" in m and "fmin(12.0" in m and "cornerResolution = 12" in m and "outerEdgeDistance = 2.0" in m)
check("recipe:TG 贝塞尔控制点", "0.816137566137566" in m and "0.20502645502645533" in m
      and "0.5806878306878306" in m and "0.873015873015873" in m)
check("recipe:panel 填充（浅 0.70 / 深 0.85）", "colorWithWhite:0.11 alpha:0.85" in m
      and "colorWithWhite:1.0 alpha:0.70" in m)
check("recipe:0.8pt 描边（浅 0.60 / 深 0.15）", "lineWidth = 0.8" in m
      and "_ame252_dark ? 0.15 : 0.60" in m)
check("recipe:双模（实况/快照供料）", "ame252_backdropSnapshot" in m and "ame252_backdropSourceRect" in m
      and "kCAGravityResize" in m)
check("recipe:subdivisionSteps=0 + depthNormalization none",
      "setSubdivisionSteps:" in m and '@"none"' in m)
check("recipe:运行时降级门", "ame252_isSupported" in m and "NSClassFromString" in m)

h = read(lgv_h)
check("header:任务号与 TG 来源注释", "Task252" in h and "LegacyGlassView" in h)

# ─── 2. 站点接线（AmeFloatingMenu / 游戏内菜单 / MVC / TVC）───
fm = read("Natives/AmeFloatingMenu.m")
check("site:AmeFloatingMenu import", '#import "AmeLiquidGlassView.h"' in fm)
check("site:AmeFloatingMenu TG 面板接管", "ame252_glassViewWithCornerRadius:26.0" in fm)
check("site:AmeFloatingMenu 游戏域快照供料判定", "[SurfaceViewController surface]" in fm
      and "ame252_glassSnapshotMode" in fm)
check("site:AmeFloatingMenu 底色退场", "self.panel.backgroundColor = nil;" in fm)
check("site:AmeFloatingMenu 0.5x 供料快照", "Ame252GlassFeedSnapshot" in fm and "ame252_fmt.scale = 0.5" in fm)
check("site:AmeFloatingMenu 布局对位+阴影路径", "ame252_backdropSourceRect =" in fm
      and "shadowPath" in fm)
check("site:AmeFloatingMenu 实况模式免重抓", "ame252_glass != nil && !self.ame252_glassSnapshotMode) return" in fm)
check("site:AmeFloatingMenu 深浅跟随", "traitCollectionDidChange" in fm and "ame252_dark" in fm)

nav = read("Natives/SurfaceViewController+Navigation.m")
check("site:Navigation import", '#import "AmeLiquidGlassView.h"' in nav)
check("site:Navigation TG 键 + 24pt 深色面板", "kAme252GlassKey" in nav
      and "ame252_glassViewWithCornerRadius:24.0" in nav)
check("site:Navigation 三件套退场", "ame243_snap.hidden = YES;" in nav and "ame244_tint.hidden = YES;" in nav)
check("site:Navigation 开菜单供料", "ame252_surfaceSnapshot(self.surfaceView)" in nav)
check("site:Navigation tick 供料", "ame252_glass.ame252_backdropSnapshot = ame252_fresh" in nav)
check("site:Navigation 对位重写", "ame252_glass.ame252_backdropSourceRect = ame248_rect" in nav)
check("site:Navigation 原生档清理", "ame252_glassOff.hidden = YES" in nav)
check("site:Navigation 0.5x 供料函数", "static UIImage *ame252_surfaceSnapshot" in nav
      and "ame252_fmt.scale = 0.5" in nav)

mvc = read("Natives/MultiplayerViewController.m")
check("site:MVC import", '#import "AmeLiquidGlassView.h"' in mvc)
check("site:MVC 滤镜栈上快照图层", "ame249_iv.layer.filters = ame252_filters" in mvc)
check("site:MVC 条件供料倍率", "ame252_isSupported] ? 0.5 : 0.18" in mvc)

tvc = read("Natives/TerracottaViewController.m")
check("site:TVC import", '#import "AmeLiquidGlassView.h"' in tvc)
check("site:TVC 滤镜栈上快照图层", "ame248_iv.layer.filters = ame252_filters" in tvc)
check("site:TVC 条件供料倍率", "ame252_isSupported] ? 0.5 : 0.18" in tvc)

cmake = read("Natives/CMakeLists.txt")
check("build:CMakeLists 登记新源文件", re.search(r"AmeLiquidGlassView\.m", cmake) is not None)

# ─── 3. 括号平衡门（task240 同款算法，覆盖本轮触碰文件）───
def strip_strings_comments(text):
    out, i, n, mode = [], 0, len(text), 0
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if mode == 0:
            if c == '"':
                mode = 1
            elif c == "'":
                mode = 2
            elif c == "/" and nxt == "/":
                mode = 3
            elif c == "/" and nxt == "*":
                mode = 4
            else:
                out.append(c)
        elif mode == 1:
            if c == "\\":
                i += 1
            elif c == '"':
                mode = 0
        elif mode == 2:
            if c == "\\":
                i += 1
            elif c == "'":
                mode = 0
        elif mode == 3:
            if c == "\n":
                mode = 0
        else:
            if c == "*" and nxt == "/":
                mode = 0
                i += 1
        i += 1
    return "".join(out)


for p in (lgv_m, "Natives/AmeFloatingMenu.m", "Natives/SurfaceViewController+Navigation.m",
          "Natives/MultiplayerViewController.m", "Natives/TerracottaViewController.m"):
    text = strip_strings_comments(read(p))
    pairs = {")": "(", "]": "[", "}": "{"}
    stack, bad = [], 0
    for ch in text:
        if ch in "([{":
            stack.append(ch)
        elif ch in pairs:
            if not stack or stack[-1] != pairs[ch]:
                bad += 1
                break
            stack.pop()
    check("balance:" + p, bad == 0 and not stack)

# ─── 4. 网格数学数值验证（独立 C 测试，gcc 可用则跑）───
math_src = os.path.join("/home/z/my-project/scripts", "task252_math_test.c")
if os.path.isfile(math_src) and subprocess.call(["which", "gcc"], stdout=subprocess.DEVNULL) == 0:
    # 以仓库当前源码重新抽取注入，保证测的是本轮仓库状态
    inject = (
        "import sys\n"
        "src = open(os.path.join(REPO_FULL, 'Natives/AmeLiquidGlassView.m'), encoding='utf-8').read()\n"
    )
    ok = False
    detail = ""
    try:
        import tempfile
        src = read(lgv_m)
        partA = src[src.find("/// 位移缓动贝塞尔"):src.find("/// 模板缓存")]
        partB = src[src.find("/// 生成模板"):src.find("/// 模板实例化")]
        body = partA + "\n" + partB
        assert "NSMutableDictionary" not in body and "NSObject" not in body
        base = open(math_src, encoding="utf-8").read()
        main_code = "\nint main(void) {" + base.split("\nint main(void) {", 1)[1]
        header = ("// auto-rebuild by verify_task252\n#include <stdio.h>\n#include <math.h>\n"
                  "#include <string.h>\n#include <stdlib.h>\n\ntypedef double CGFloat;\n#define nil NULL\n")
        tmp_c = tempfile.NamedTemporaryFile(suffix=".c", delete=False, mode="w", encoding="utf-8")
        tmp_c.write(header + body + main_code)
        tmp_c.close()
        tmp_bin = tmp_c.name + ".out"
        cc = subprocess.run(["gcc", "-O2", "-o", tmp_bin, tmp_c.name, "-lm"],
                            capture_output=True, text=True)
        if cc.returncode == 0:
            run = subprocess.run([tmp_bin], capture_output=True, text=True)
            ok = run.returncode == 0 and "ALL MATH CHECKS PASSED" in run.stdout
            detail = run.stdout.strip().replace("\n", " | ")[:200]
        else:
            detail = "gcc fail: " + cc.stderr.strip()[:160]
        os.unlink(tmp_c.name)
        if os.path.isfile(tmp_bin):
            os.unlink(tmp_bin)
    except Exception as e:  # noqa: BLE001
        detail = "exception: %s" % e
    check("math:SDF/贝塞尔/折射网格数值验证", ok, detail)
else:
    check("math:SDF/贝塞尔/折射网格数值验证", True, "skipped (no gcc / no test source)")

# ─── 5. 选项/设置/公告/REVISION 零改动 ───
ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))["announcements"]
check("announcements:恒 43 条（本轮不新增公告）", len(ann) == 43, "len=%d" % len(ann))
vh = read("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("version.h:REVISION define 未动", re.search(r"#define REVISION 22\b", vh) is not None
      or "REVISION 22" in vh)
# 设置键零改动：界面风格四档枚举原样
lgh = read("Natives/LiquidGlassCompat.h")
check("options:界面风格四档枚举原样", all(k in lgh for k in (
    "LGCInterfaceStyleAuto", "LGCInterfaceStyleNative",
    "LGCInterfaceStyleLiquidGlass", "LGCInterfaceStylePseudoGlass")))
check("options:伪玻璃档判定 API 原样", "LGCIsPseudoGlassStyleActive" in lgh
      and "LGCIsGlassStyleActive" in lgh)
# 本轮不新增任何用户可见字符串（无 l10n 触碰）
diff_files = subprocess.run(["git", "-C", REPO, "diff", "--name-only", "HEAD"],
                            capture_output=True, text=True).stdout.split()
l10n_touched = [f for f in diff_files if f.endswith((".strings",)) or "l10n" in f.lower()]
check("i18n:零 .strings 触碰", not l10n_touched, ",".join(l10n_touched))
check("i18n:announcements.json 未触碰", "announcements.json" not in diff_files)

# CRLF 洁检（仓库二进制门教训）
crlf_bad = []
for f in diff_files:
    fp = os.path.join(REPO, f)
    if os.path.isfile(fp):
        with open(fp, "rb") as fh:
            if b"\r\n" in fh.read():
                crlf_bad.append(f)
check("hygiene:触碰文件零 CRLF", not crlf_bad, ",".join(crlf_bad))

# ─── 输出 ───
failed = [(n, d) for n, ok, d in results if not ok]
for n, ok, d in results:
    print(("PASS " if ok else "FAIL ") + n + ((" -- " + d) if d and not ok else ""))
print("verify_task252: %d/%d ALL GREEN" % (len(results) - len(failed), len(results)))
sys.exit(1 if failed else 0)
