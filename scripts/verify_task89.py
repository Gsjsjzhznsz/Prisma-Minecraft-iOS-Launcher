#!/usr/bin/env python3
"""
Task 89 验证器（Task137 重写为"新拟态退役"校验器）

历史：Task 89 引入 NeomorphKit（NMTheme + UIView+Neomorph 凸出双阴影引擎，
react-native-neomorph-shadows 忠实移植），经历 Task101/111/136 多轮重锚。

Task137（用户最终决定）：
  "现在请把所有UI全部尽量改成能用iOS原生UI的，删去所有新拟态代码，
   重新调整层级等，大小保持一样，确保启动器每个功能都不会被占用影响"
  ——新拟态在实测中暴露：阴影被父视图裁剪、统一圆角 50 对小元素过圆/
  大元素阴影过宽、深浅色对比需额外扫描器兜底。全部新拟态代码退役，
  回归 iOS 原生 UI（UIKit 语义色 + 标准圆角，无自绘阴影）。

本文件因此从"新拟态存在性校验"重写为"新拟态退役完整性校验"：
  A. NeomorphKit 目录与引擎/主题/扫描器源文件彻底删除
  B. 全仓 .m/.h 无任何 nm_*/NMTheme/NMContrast 代码引用（注释豁免）
  C. 构建清单（CMakeLists.txt）与文件系统一致（Kit 源移除、原生辅助登记）
  D. 原生替换层就位（UIKit+NativeSurface 三表面 + AmeBadgeLabel）
  E. 工作区改动仅限预期文件集（提交后自愈）
"""
import os
import re
import subprocess
import sys

REPO = os.environ.get("TASK89_REPO", "/home/z/my-project/Amethyst-iOS-MyRemastered")
PASS, FAIL = 0, 0


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}  {detail}")


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8", errors="replace") as f:
        return f.read()


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True).stdout


print("=" * 72)
print("A. NeomorphKit 退役（引擎/主题/扫描器/面板基座源文件删除）")
print("=" * 72)
for rel in ["Natives/NeomorphKit/NMTheme.h", "Natives/NeomorphKit/NMTheme.m",
            "Natives/NeomorphKit/UIView+Neomorph.h", "Natives/NeomorphKit/UIView+Neomorph.m",
            "Natives/NeomorphKit/NMContrast.h", "Natives/NeomorphKit/NMContrast.m",
            "Natives/NeomorphKit/UIViewController+NMPanel.h", "Natives/NeomorphKit/UIViewController+NMPanel.m"]:
    check(f"已删除 {rel}", not os.path.exists(os.path.join(REPO, rel)))

print()
print("=" * 72)
print("B. 全仓代码零新拟态引用（strip 注释/字符串后扫描）")
print("=" * 72)


def strip_objc(src):
    # 去掉块注释、行注释与字符串字面量，避免历史注释误报
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    return src


code_refs = []
for root, dirs, files in os.walk(os.path.join(REPO, "Natives")):
    dirs[:] = [d for d in dirs if d not in ("external", "resources", "AI")]
    for fn in files:
        if not fn.endswith((".m", ".h")):
            continue
        p = os.path.join(root, fn)
        rel = os.path.relpath(p, REPO)
        if not os.path.exists(p):
            continue
        code = strip_objc(read(rel))
        for pat in ("nm_convex", "nm_flat", "nm_pill", "nm_styleConvex",
                    "nm_removeNeomorph", "nm_hasNeomorph", "NMTheme",
                    "NMContrast", "nm_applySubpanel"):
            if pat in code:
                code_refs.append(f"{rel}:{pat}")
check("Natives 全部 .m/.h 代码零新拟态符号", not code_refs, str(code_refs[:6]))

print()
print("=" * 72)
print("C. 构建清单与文件系统一致")
print("=" * 72)
cmake = read("Natives/CMakeLists.txt")
check("CMake 不再登记 Kit 源", "NeomorphKit/" not in cmake)
check("CMake 登记原生表面辅助 UIKit+NativeSurface.m", "UIKit+NativeSurface.m" in cmake)
check("CMake 登记原生面板基座 UIViewController+AMEPanel.m", "UIViewController+AMEPanel.m" in cmake)
check("CMake 登记迁出后的 NMToast.m", "  NMToast.m" in cmake)
kit_dir = os.path.join(REPO, "Natives/NeomorphKit")
check("NeomorphKit 目录不存在或为空", (not os.path.isdir(kit_dir)) or not os.listdir(kit_dir))

print()
print("=" * 72)
print("D. 原生替换层就位")
print("=" * 72)
ns_h = read("Natives/UIKit+NativeSurface.h")
ns_m = read("Natives/UIKit+NativeSurface.m")
check("三表面 API 声明齐备", all(m in ns_h for m in
      ["ame_applyCardSurfaceWithRadius", "ame_applyRaisedCardSurfaceWithRadius",
       "ame_applyPanelSurfaceWithRadius"]))
check("AmeBadgeLabel 声明（Task136 '…' 截断回归的修复载体）", "AmeBadgeLabel" in ns_h)
check("卡片表面使用 secondarySystemGroupedBackground",
      "secondarySystemGroupedBackgroundColor" in ns_m)
check("面板表面使用 secondarySystemBackground",
      "secondarySystemBackgroundColor" in ns_m)
check("AmeBadgeLabel intrinsicContentSize 补偿内边距",
      "intrinsicContentSize" in ns_m and "_textInsets.left + _textInsets.right" in ns_m)
ame_panel = read("Natives/UIViewController+AMEPanel.m")
check("AMEPanel 基座原生化（systemBackgroundColor + separatorColor）",
      "[UIColor systemBackgroundColor]" in ame_panel and "[UIColor separatorColor]" in ame_panel)
nav = read("Natives/LauncherNavigationController.m")
check("导航单一执法点改调 ame_applySubpanelBaseStyle",
      nav.count("[viewController ame_applySubpanelBaseStyle];") >= 1
      and "[self.viewControllers.firstObject ame_applySubpanelBaseStyle];" in nav)

print()
print("=" * 72)
print("E. 工作区改动仅限预期文件集（提交后自愈）")
print("=" * 72)
changed = {ln[3:].strip() for ln in git("status", "--porcelain").splitlines() if ln.strip()}
check("E1 改动仅限预期文件集", all(
    c.startswith(("Natives/", "scripts/verify_task", "worklog.md", "JavaApp/")) for c in changed),  # Task226：+JavaApp/（cacio jar 的 CTCDesktopPeer 替换）
    f"unexpected={changed}")

print()
print(f"verify_task89: {PASS} passed, {FAIL} failed")
sys.exit(1 if FAIL else 0)
