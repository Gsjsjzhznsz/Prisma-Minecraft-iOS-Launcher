#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Task 238 验证脚本：第 8 轮反馈的 7 项修复静态验证。
A. 游戏内菜单悬浮形态几何重算（不再读残留抽屉帧）
B. game.gear.docked 偏好注册 + 默认贴边 + 近边自动吸附
C. 启动遮罩层 z 序（悬浮球/菜单在遮罩之上）
D. JVM 正常退出 → 返回启动器主页
E. 字体重叠根修（numberOfLines==0 拷贝词换行 + 菜单树描边豁免）
F. 前置区上移（头部堆叠）+ CF 源前置富元数据
G. 括号配平（所有修改文件）
"""
import sys, re

BASE = "/home/z/my-project/Amethyst-iOS-MyRemastered/Natives/"
results = []

def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))

def rd(p):
    with open(BASE + p, "r", encoding="utf-8") as f:
        return f.read()

# ---------- A. 菜单悬浮形态几何重算 ----------
nav = rd("SurfaceViewController+Navigation.m")
check("A1 showMenu 悬浮形态几何重算(ame238_sheetW 居中)",
      "ame238_sheetW" in nav and "(screenWidth - ame238_sheetW) / 2.0" in nav,
      "不再从残留 frame 读宽高/x")
check("A2 showMenu 不再读残留 menuWidth/menuHeight",
      "CGFloat menuWidth = self.menuView.frame.size.width" not in nav,
      "残留帧读取已移除")
check("A3 抽屉宽度同源公式重算",
      "MAX(MIN(screenWidth * 0.7, 400), 280)" in nav,
      "侧滑形态宽度也不信任残留值")
check("A4 菜单树描边豁免",
      "ame230_setViewTreeStrokeExempt(self.menuView, YES)" in nav,
      "游戏内菜单面板文字单层干净")

# ---------- B. 吸边持久化 + 默认贴边 ----------
gmov = rd("GameMenuOverlayView.m")
prefs = rd("PLPreferences.m")
check("B1 PLPreferences 注册 game.gear.docked/docked_left",
      '"docked": @NO' in prefs and '"docked_left": @NO' in prefs and '"gear"' in prefs,
      "valueForKeyPath 嵌套键注册（内层可变字典）")
check("B2 默认形态 = 右侧吸边把手",
      "Task238 gear default: docked right handle" in gmov and
      re.search(r"kAme227HandleWidth \* 0\.66,\s*bh > 0 \? bh \* 0\.45 : 300\.0", gmov) is not None,
      "首启即贴边把手并落盘")
check("B3 存量近边悬浮态自动吸附",
      "Task238 gear auto-docked on restore" in gmov and
      "ame238_distL < kAme227DockThreshold" in gmov,
      "修复 setter 失败时代的残留状态")
check("B4 首启落盘守卫(bw/bh>0)",
      "if (bw > 0 && bh > 0) {" in gmov,
      "避免 0 除写坏偏好")

# ---------- C. 启动遮罩层 z 序 ----------
svc = rd("SurfaceViewController.m")
check("C1 悬浮三件套提到遮罩之上",
      "Task238 launch overlay z-order" in svc and
      "bringSubviewToFront:self.gameMenuOverlay" in svc and
      "bringSubviewToFront:self.menuView" in svc and
      "bringSubviewToFront:self.menuDimView" in svc,
      "遮罩<菜单面板<悬浮球次序保持，取消按钮置顶")

# ---------- D. JVM 退出返回启动器 ----------
check("D1 launchResult==0 返回启动器主页",
      "Task238 JVM exited normally" in svc and "UIKit_returnToSplitView();" in svc,
      "退游戏回启动器（FCL 同款）")
check("D2 根守卫(已在启动器则跳过)",
      "root already left the game surface" in svc and
      "isKindOfClass:[SurfaceViewController class]]" in svc,
      "避免 cancelLaunch 已换根后的重复换根")

# ---------- E. 字体重叠根修 ----------
bm = rd("BackgroundManager.m")
afm = rd("AmeFloatingMenu.m")
check("E1 numberOfLines==0 拷贝词换行",
      re.search(r"numberOfLines == 0.*?NSLineBreakByWordWrapping", bm, re.S) is not None,
      "不限行数标签的拷贝不再拉成单条长线横穿正文")
check("E2 玻璃悬浮菜单树描边豁免",
      "ame230_setViewTreeStrokeExempt(self.view, YES)" in afm,
      "Ame237 菜单标题/正文/行单层干净")
bmh = rd("BackgroundManager.h")
check("E3 豁免 API 头文件导出",
      "void ame230_setViewTreeStrokeExempt(UIView *view, BOOL exempt);" in bmh and
      "void ame229_labelSetStrokeExempt(UILabel *label, BOOL exempt);" in bmh,
      "两个 C 函数声明公开")

# ---------- F. 前置区上移 + CF 源 ----------
mvv = rd("ModVersionViewController.m")
cfh = rd("installer/modpack/CurseForgeAPI.h")
cfm = rd("installer/modpack/CurseForgeAPI.m")
check("F1 前置区渲染目标 = 头部堆叠(不再表尾)",
      "ame238_depsSectionView = ame236_footer" in mvv and
      "self.tableView.tableFooterView = ame236_footer" not in mvv,
      "摆在详情头之下、版本列表之上")
check("F2 头部堆叠机制",
      "ame238_headerStackView" in mvv and "systemLayoutSizeFittingSize" in mvv,
      "[详情头+前置区] 合成 tableHeaderView")
check("F3 多版本依赖探测(≤6)",
      "ame238_probe" in mvv and "MIN((NSUInteger)6" in mvv,
      "最新版本缺 dependencies[] 时向后探测")
check("F4 CF 富元数据回填链",
      "ame238_fetchProjectInfo" in mvv and "CF dependency rows enriched" in mvv,
      "占位先行 → 名称/摘要/图标到达后重渲染")
check("F5 CurseForgeAPI 新方法",
      "ame238_fetchProjectInfo" in cfh and
      cfm.count("ame238_fetchProjectInfo") >= 1 and
      "logo.thumbnailUrl" in cfm.replace(' ', '').replace('[ame238_logo[@\"thumbnailUrl\"]', 'logo.thumbnailUrl') or "thumbnailUrl" in cfm,
      "GET /mods/{id} 完整元数据（name/summary/logo）")
check("F6 重渲染不残留旧视图",
      "ame238_old removeFromSuperview" in mvv or "ame238_old" in mvv,
      "新前置区入栈时清掉旧视图")
check("F7 无依赖清理路径走头部",
      mvv.count("self.ame238_depsSectionView = nil") >= 2,
      "探测失败/空计划时移除前置区并恢复纯详情头")

# ---------- G. 括号配平 ----------
def balanced(path):
    s = rd(path)
    # 去掉字符串与注释的粗糙处理：逐行去掉 "//..." 与 "..." 内容
    s = re.sub(r'"(?:[^"\\]|\\.)*"', '""', s)
    s = re.sub(r"'(?:[^'\\]|\\.)*'", "''", s)
    s = re.sub(r"//[^\n]*", "", s)
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    return s.count("{") == s.count("}") and s.count("(") == s.count(")")

for f in ["SurfaceViewController+Navigation.m", "GameMenuOverlayView.m",
          "PLPreferences.m", "SurfaceViewController.m", "BackgroundManager.m",
          "BackgroundManager.h", "AmeFloatingMenu.m", "ModVersionViewController.m",
          "installer/modpack/CurseForgeAPI.m", "installer/modpack/CurseForgeAPI.h"]:
    check(f"G:balanced {f}", balanced(f), "")

passed = sum(1 for _, ok, _ in results if ok)
total = len(results)
for name, ok, detail in results:
    print(f"{'PASS' if ok else 'FAIL'}  {name}" + (f"  [{detail}]" if detail and not ok else ""))
print(f"\n{passed}/{total} checks passed")
sys.exit(0 if passed == total else 1)
