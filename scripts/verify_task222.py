#!/usr/bin/env python3
"""Task222 验证器：上游同步（lifecycle + 陶瓦联机恢复）+ 19 项清单优化轮。

覆盖面：
  A. 上游 lifecycle 修复移植（d76301816 → 清单第 4 项）
  B. 陶瓦联机全量恢复（上游 10-05 系列 + MP-RESTORE → 清单第 15 项）
  C. TouchController 版本串归一化（清单第 3 项）
  D. 导出多线程（清单第 6 项）
  E. 关于页动画 + 右面板按压反馈（清单第 8 项）
  F. 打开文件夹应用内浏览（清单第 10 项）
  G. IME 组合守卫（清单第 12 项）
  H. README 重构（清单第 13 项）
  I. zl2 介绍页 + 贡献专区（清单第 17/18 项）
  J. 启动进度三件套（清单第 16 项）
  K. 语法门（括号平衡 + i18n 完整性）
"""
import os
import re
import subprocess
import sys

REPO = "/home/z/my-project/Amethyst-iOS-MyRemastered"
PASS = 0
FAIL = 0


def read(p):
    with open(os.path.join(REPO, p), encoding="utf-8", errors="replace") as f:
        return f.read()


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  PASS  {name}")
    else:
        FAIL += 1
        print(f"  FAIL  {name}   {detail}")


print("=" * 72)
print("A. 上游 lifecycle 修复移植（清单第 4 项：切后台卡死/黑屏）")
print("=" * 72)
utils_h = read("Natives/utils.h")
ib3 = read("Natives/input_bridge_v3.m")
scene = read("Natives/SceneDelegate.m")
svc = read("Natives/SurfaceViewController.m")

check("A1 utils.h: CallbackBridge_resumeGameIfNeed 声明在位",
      "void CallbackBridge_resumeGameIfNeed(void);" in utils_h)
check("A2 input_bridge_v3: 暂停判据放宽（liveSession 三输入）",
      "BOOL liveSession = (isGrabbing || isInputReady || (g_sdlWindow != NULL));" in ib3)
check("A3 input_bridge_v3: resumeGameIfNeed 实现（0 尺寸兜底）",
      "void CallbackBridge_resumeGameIfNeed(void)" in ib3 and
      "skip resize re-announce" in ib3)
check("A4 SceneDelegate: willResignActive 立即暂停",
      "sceneWillResignActive" in scene and
      scene.find("sceneWillResignActive") < scene.rfind("CallbackBridge_pauseGameIfNeed"))
check("A5 SceneDelegate: didBecomeActive 呈现面自愈 + resume",
      "Amethyst_EnforceSDL3Presentation()" in scene and
      "CallbackBridge_resumeGameIfNeed();" in scene)
check("A6 SceneDelegate: 四回调 swap 取证锚点（AmeFGLogSwapStats ≥ 4 次）",
      scene.count("AmeFGLogSwapStats(@") >= 4)
check("A7 SceneDelegate: Task56 几何重试横屏早退已修（FG 链路走到底）",
      "仅跳过几何重试本身，FG 自愈链路无条件走到底" in scene)
check("A8 SurfaceViewController: 执法函数族四件全在",
      "BOOL Amethyst_EnforceSDL3Presentation(void)" in svc and
      "static UIView *Amethyst_FindSDLView(void)" in svc and
      "BOOL Amethyst_MakeSDLRenderTransparent(void)" in svc and
      "static void ame_dumpPresentationState" in svc)
check("A9 执法主入口: 安全保障（宿主窗口确认后才隐藏 SDL 窗）",
      "绝不把唯一可见窗口藏掉" in svc and "[hostWin makeKeyWindow];" in svc)

print()
print("=" * 72)
print("B. 陶瓦联机全量恢复（上游 10-05 + MP-RESTORE → 清单第 15 项）")
print("=" * 72)
cml = read("Natives/CMakeLists.txt")
tvc = read("Natives/TerracottaViewController.m")
lad_h = read("Natives/LanPortDetector.h")
lcard = read("Natives/LauncherCardLayoutViewController.m")
lroot = read("Natives/LauncherRootViewController.m")
snav = read("Natives/SurfaceViewController+Navigation.m")

check("B1 CMakeLists: TERRACOTTA_LIB 集成块恢复（非注释）",
      'set(TERRACOTTA_LIB_DIR "${CMAKE_CURRENT_LIST_DIR}/terracotta")' in cml)
check("B2 CMakeLists: ZeroTier 六文件编译恢复",
      all(f in cml for f in ["MultiplayerManager.m", "MultiplayerViewController.m",
                             "LanPortDetector.m", "ZeroTierBridge.m", "SOCKS5Proxy.m",
                             "PortForwarder.m"]))
check("B3 CMakeLists: Terracotta 四文件编译恢复",
      all(f in cml for f in ["TerracottaBridge.m", "TerracottaManager.m",
                             "SilentAudioPlayer.m", "TerracottaViewController.m"]))
check("B4 CMakeLists: 链接行（TERRACOTTA_LIB + libc++ + resolv + ZT 变量）",
      '${TERRACOTTA_LIB}' in cml and '"-lresolv"' in cml and
      '"${ZT_FRAMEWORK_LINK}"' in cml)
check("B5 SceneDelegate: lazy init 探测（启动路径不创建 Manager）",
      "libterracotta linked, multiplayer available (lazy init)" in scene)
check("B6 LanPortDetector: 上游新版 API（log tailing + 扫描）",
      "scanLocalPortsWithProgress" in lad_h and "parsePortFromLogLine" in lad_h)
check("B7 TVC: FCL 重写版结构（stage 视图 + 端口自动检测接线）",
      "startAutoDetection" in tvc and "TCUIStateMenu" in tvc)
check("B8 TVC: Task168 新拟态管线重放（headerCard 卡片管线）",
      "applyCardEffectToView:self.headerCard" in tvc)
check("B9 TVC: 容器模式退出（ShowHomePage 通知）",
      'postNotificationName:@"ShowHomePage"' in tvc)
check("B10 TVC: isHiddenRoot 注入浮动关闭按钮",
      'chevron.down' in tvc and "closeFab addTarget" in tvc.replace("[closeFab addTarget]", "closeFab addTarget"))
check("B11 TVC: 键重映射避让 Task220（2091/2092/2093）",
      'i18n_str_2091' in tvc and 'i18n_str_2092' in tvc and 'i18n_str_2093' in tvc and
      'localize(@"i18n_str_2068"' not in tvc)
check("B12 卡片布局: showMultiplayer 恢复（isAvailable 门 + nav 包裹）",
      "showMultiplayer" in lcard and "[TerracottaBridge isAvailable]" in lcard)
check("B13 VS 布局: showMultiplayer 恢复",
      "[TerracottaBridge isAvailable]" in lroot)
check("B14 游戏内: actionOpenMultiplayer modal 恢复（PageSheet）",
      "actionOpenMultiplayer" in snav and "UIModalPresentationPageSheet" in snav)
check("B15 游戏内: ForceClose 联机资源清理恢复",
      "stopAllMultiplayerServices" in snav)

print()
print("=" * 72)
print("C. TouchController 版本串归一化（清单第 3 项）")
print("=" * 72)
mes = read("Natives/ModpackExportService.m")
check("C1 ame222_stripBuildHash 剥离函数在位",
      "static NSString *ame222_stripBuildHash(NSString *version)" in mes)
check("C2 剥离规则：7-12 位 hex + 头部含数字双保险",
      "tail.length < 7 || tail.length > 12" in mes and
      "decimalDigitCharacterSet" in mes)
check("C3 四分支全接剥离（fabric/quilt/forge/neoforge/纯版本）",
      mes.count("ame222_stripBuildHash(") >= 5)
check("C4 minecraftRaw 原始串保留（回退口径）",
      mes.count('@"minecraftRaw"') >= 5)

print()
print("=" * 72)
print("D. 导出多线程（清单第 6 项：分批并行读 + 串行写）")
print("=" * 72)
check("D1 并行读队列（concurrent + dispatch_group）",
      'dispatch_queue_create("ame222.export.read", DISPATCH_QUEUE_CONCURRENT)' in mes)
check("D2 内存有界分批（64MB / 128 文件双上限）",
      "64ULL * 1024 * 1024" in mes and "batch.count >= 128" in mes)
check("D3 zip 写串行保持（UZKArchive 线程安全约束注释）",
      "writeData 不是线程安全" in mes)
check("D4 取消检查点保留（批间）",
      "取消检查点（批间检查" in mes)

print()
print("=" * 72)
print("E. 关于页动画 + 右面板按压反馈（清单第 8 项）")
print("=" * 72)
about = read("Natives/AboutViewController.m")
rp = read("Natives/LauncherRightPanelViewController.m")
check("E1 About: 入场 stagger（spring + 80ms 间隔 + 只播一次）",
      "ame222_didPlayEntrance" in about and "0.08 * i" in about)
check("E2 RightPanel: 信息卡按压反馈（0.97 缩放 + spring 回弹）",
      "CGAffineTransformMakeScale(0.97, 0.97)" in rp and "ame156_navigateToRoute:route" in rp)

print()
print("=" * 72)
print("F. 打开文件夹应用内浏览（清单第 10 项）")
print("=" * 72)
check("F1 openURLGlobal: 目录分支走应用内浏览器（Task223 起为 FolderBrowserViewController）",
      "wrappedControllerForPath:fsPath" in ib3 and "[FolderBrowserViewController" in ib3)
check("F2 目录判定 + file: 前缀剥离 + 符号链接解析",
      "fileExistsAtPath:fsPath" in ib3 and "stringByResolvingSymlinksInPath" in ib3)
check("F3 import FolderBrowserViewController（Task223）",
      '#import "FolderBrowserViewController.h"' in ib3)
check("F4 文件路径保持 URL scheme 链（processPath 原样）",
      "NSString *realPath = processPath(path);" in ib3)

print()
print("=" * 72)
print("G. IME 组合守卫（清单第 12 项）")
print("=" * 72)
check("G1 Stop 分支 markedTextRange 守卫（组合中不 resign）",
      "self.inputTextField.markedTextRange != nil" in svc and
      "skip resign during marked-text composition" in svc)

print()
print("=" * 72)
print("H. README 重构（清单第 13 项：中文默认 + QQ/贡献置顶）")
print("=" * 72)
rd = read("README.md")
ren = read("README_EN.md")
check("H1 README.md 为中文（含中文标题与正文锚点）",
      "一款面向中国用户深度优化的 iOS Minecraft: Java Edition 启动器" in rd)
check("H2 README.md 语言切换指向 README_EN.md",
      '<a href="./README_EN.md">English</a>' in rd)
check("H3 README.md QQ 群置顶区块",
      "QQ 群：1126547426" in rd and rd.find("QQ 群：1126547426") < rd.find("## Prisma 是什么"))
check("H4 README.md 贡献置顶（爱发电 + 赞赏码）",
      "爱发电" in rd and "微信赞赏码" in rd and rd.find("爱发电") < rd.find("## Prisma 是什么"))
check("H5 README_EN.md 语言切换指回中文",
      '<a href="./README.md">中文</a>' in ren)
check("H6 README_EN.md QQ 置顶（英文区块）",
      "QQ Group: 1126547426" in ren and ren.find("QQ Group: 1126547426") < ren.find("## What is Prisma?"))
check("H7 README_CN.md 已退役（git 索引中不存在）",
      not os.path.exists(os.path.join(REPO, "README_CN.md")))

print()
print("=" * 72)
print("I. zl2 介绍页 + 贡献专区（清单第 17/18 项）")
print("=" * 72)
wv = read("Natives/WelcomeViewController.m")
check("I1 向导 7 步（zl2 介绍页插入 Data 与 Done 之间）",
      "static const NSInteger ame218_welcomeStepCount = 7;" in wv)
check("I2 case 5 = zl2 介绍页 / case 6 = Done",
      "case 5: [self ame222_buildIntroStep:ame218_new]" in wv and
      "case 6: [self ame218_buildDoneStep:ame218_new]" in wv)
check("I3 介绍页：特性行 + 社区卡（Task223 重写为直接布局，见 verify_task223）",
      "ame222_buildIntroStep:(UIView *)container" in wv and
      "welcome.intro.community.title" in wv and "welcome.intro.subtitle" in wv)
# Task225 再锚：Task224 把介绍页后的推进改成了圆盘焦点引导（weakSelf 版
# showStep:6），Task225 又退役圆盘改回通用步进 + 向导后锚定式焦点引导
# （ame223_showCoachMarksThenAboutFrom:）。I4 语义 = "介绍页之后直达
# Done/收尾"，锚点改为通用步进与锚定引导的存在性。
check("I4 介绍页推进：通用步进（Task225）+ 向导后锚定引导直达 About",
      "[self ame218_showStep:self.stepIndex + 1 animated:YES];" in wv
      and "ame223_showCoachMarksThenAboutFrom:" in wv)
check("I5 About 贡献卡（爱发电按钮 + 赞赏码）",
      "ame222_buildDonateCard" in about and "ame222_openAfdian" in about)
check("I6 赞赏码 bundle 直显 + 长按存图",
      "imageWithContentsOfFile:donatePath" in about and "ame222_saveDonateImage" in about)
check("I7 CMakeLists: donate.png 打包",
      'set(DONATE_PNG' in cml and 'MACOSX_PACKAGE_LOCATION "Resources"' in cml)
check("I8 Photos import（存图权限）",
      "#import <Photos/Photos.h>" in about)

print()
print("=" * 72)
print("J. 启动进度三件套（清单第 16 项）")
print("=" * 72)
check("J1 属性齐全（stage/track/bar/elapsed/timer）",
      all(p in svc for p in ["UILabel *launchStageLabel;", "UIView *launchProgressTrack;",
                              "UIView *launchProgressBar;", "UILabel *launchElapsedLabel;",
                              "NSTimer *launchStageTimer;"]))
check("J2 updateLaunchStage 实装（时间轴五阶段）",
      "elapsed >= 40.0" in svc and "elapsed >= 4.0" in svc and "launch.stage.%ld" in svc)
check("J3 微光扫过动画（keyframe 往复）",
      "ame222_shimmer" in svc and "transform.translation.x" in svc)
check("J4 定时器启动（0.5s repeats）",
      "scheduledTimerWithTimeInterval:0.5" in svc)
check("J5 双 dismiss 路径清理定时器",
      svc.count("[self.launchStageTimer invalidate];") >= 2)
check("J6 阶段文案淡入淡出切换",
      "self.launchStageLabel.alpha = 0.0;" in svc and "self.launchStageLabel.alpha = 1.0;" in svc)

print()
print("=" * 72)
print("K. 语法门（括号平衡 vs HEAD + i18n 完整性）")
print("=" * 72)
TOUCHED = [
    "Natives/utils.h", "Natives/input_bridge_v3.m", "Natives/SceneDelegate.m",
    "Natives/SurfaceViewController.m", "Natives/TerracottaViewController.m",
    "Natives/LanPortDetector.h", "Natives/LanPortDetector.m",
    "Natives/LauncherCardLayoutViewController.m", "Natives/LauncherRootViewController.m",
    "Natives/SurfaceViewController+Navigation.m", "Natives/ModpackExportService.m",
    "Natives/AboutViewController.m", "Natives/LauncherRightPanelViewController.m",
    "Natives/WelcomeViewController.m",
]
def _strip_comments_strings(src):
    """清洗注释与字符串字面量（括号计数只看代码级）。"""
    src = re.sub(r'@?"(?:[^"\\]|\\.)*"', '""', src)
    src = re.sub(r"//[^\n]*", "", src)
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return src


for p in TOUCHED:
    cur = read(p)
    head = subprocess.run(["git", "-C", REPO, "show", f"HEAD:{p}"],
                          capture_output=True, text=True).stdout or cur
    # LanPortDetector 是上游整体快进文件（注释含 "1)" 编号文本，原始计数天然
    # 漂移但编译无影响）——用代码级清洗对比；其余文件用原始计数对比
    # （119_124 E2 门语义）。
    if "LanPortDetector" in p or p.endswith("utils.h"):
        # Task223：utils.h 新增段落注释含 ASCII 括号——切代码级清洗对比
        cur_c, head_c = _strip_comments_strings(cur), _strip_comments_strings(head)
        ok = all(cur_c.count(a) - cur_c.count(b) == head_c.count(a) - head_c.count(b)
                 for a, b in [("{", "}"), ("(", ")"), ("[", "]")])
    else:
        ok = all(cur.count(a) - cur.count(b) == head.count(a) - head.count(b)
                 for a, b in [("{", "}"), ("(", ")"), ("[", "]")])
    check(f"K[{os.path.basename(p)}] 括号 delta 与 HEAD 一致（上游快进文件按代码级）", ok)

# i18n 完整性：四语言键集一致 + 本轮新键全部在位
langs = ["en", "zh-Hans", "zh-Hant", "zh-CN"]
sets = []
for lg in langs:
    s = read(f"Natives/resources/{lg}.lproj/Localizable.strings")
    sets.append(set(re.findall(r'^"([^"]+)"\s*=', s, re.M)))
check("K2 四语言键集一致（2606 = 2565 + Task223 的 41）",
      # Task225 再锚：Task224 +69 → 2675；Task225 +21 → 2696。
      sets[0] == sets[1] == sets[2] == sets[3] and len(sets[0]) == 2696,
      f"counts={[len(x) for x in sets]}")
need_keys = ["i18n_str_2072", "i18n_str_2090", "i18n_str_2091", "i18n_str_2093",
             "about.donate.title", "about.donate.afdian", "welcome.intro.title",
             "welcome.intro.community.hint", "launch.stage.0", "launch.stage.4"]
check("K3 本轮新键全部在位（4 语言）",
      all(k in s for k in need_keys for s in sets))
# 陶瓦 TVC 引用的键全存在（防 localize 落空）
tvc_keys = set(re.findall(r'i18n_str_(\d+)', tvc))
tvc_keys = {f"i18n_str_{k}" for k in tvc_keys if k.isdigit()}
missing = tvc_keys - sets[0]
check("K4 TVC 引用的 i18n 键零缺失（含重映射键）", not missing, f"missing={sorted(missing)}")

print()
print("=" * 72)
if FAIL == 0:
    print(f"==== RESULT: ALL PASS ({PASS}/{PASS}) ====")
    sys.exit(0)
print(f"==== RESULT: FAILED ({PASS} passed, {FAIL} failed) ====")
sys.exit(1)
