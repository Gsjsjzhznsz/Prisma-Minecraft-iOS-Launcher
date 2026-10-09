#!/usr/bin/env python3
"""verify_task232.py -- Task 232 (17-item feedback round on the Task231 build 092d8448,
device logs 7d8f6630 + 96c67e38) implementation gates. Byte-level anchors, absence checks
where code was retired, and the standing fleet audits (self-ref blocks, task225 bracket)."""
import os, sys, re, subprocess

BASE = "/home/z/my-project/Amethyst-iOS-MyRemastered"
passed, failed = 0, []

def rd(path):
    return open(os.path.join(BASE, path), encoding="utf-8", errors="replace").read()

def check(name, path, needle):
    global passed
    if needle in rd(path):
        passed += 1
    else:
        failed.append(f"{name}: anchor missing in {path}")

def check_absent(name, path, needle):
    global passed
    if needle not in rd(path):
        passed += 1
    else:
        failed.append(f"{name}: forbidden pattern STILL PRESENT in {path}")

svc = "Natives/SurfaceViewController.m"
nav = "Natives/SurfaceViewController+Navigation.m"
gmv = "Natives/GameMenuOverlayView.m"
bm = "Natives/BackgroundManager.m"

# (1) 扩展按键（可滑动键簇）：滑动收尾/切换走干净 UP（无 toggle 补发）
check("232-1a clean swipe release", svc, "Task232 swipe release: clean UP (no toggle re-fire)")
check("232-1b swipe switch clean", svc, "切换键同样走干净路径：旧键 UP + 还原，新键 DOWN（不走 toggle 补发）")
check_absent("232-1c old toggle fallthrough gone", svc, "executebtn_up:self.swipingButton isOutside:NO")

# (2) 切后台输入错位：恢复时刻几何链取证
check("232-2 resume geometry probe", "Natives/input_bridge_v3.m", "Task232 resume geometry probe: physical=%dx%d window=%dx%d guiScale=%d")

# (3) 26.3 进存档卡死：MC>=26 + MobileGL 家族覆盖 → tinygl4angle 转向
check("232-3 renderer steer", "Natives/JavaLauncher.m", "steering to tinygl4angle (on-device 4bdd916: MobileGL froze the JVM at ENTER_WORLD")

# (4) 持续奔跑：迁移扫全部 .json + 名字含 常用/奔跑
check("232-4a all-json scan", "Natives/main.m", "contentsOfDirectoryAtPath:controlPath error:nil] ?: @[]")
check("232-4b name match 常用/奔跑", "Natives/main.m", '([ame230_nm containsString:@"常用"] || [ame230_nm containsString:@"奔跑"])')

# (5) 无映射按键 toast 退役（取证留日志层）
check("232-5 toast retired keep diag", svc, "NMToast 退役")
check_absent("232-5b no toast call", svc, "ame230.controls.unbound_toast")

# (6) 悬浮栏玻璃：齿轮/统计/标签三件套 + 菜单 tint 拆除
check("232-6a floating bar glass", gmv, "ame232_applyFloatingGlass")
check("232-6b gear glass heavy dark", gmv, "floating bar glass applied (gear + stats + caption, heavy dark material)")
check("232-6c menu tint stripped", nav, "ame232_sub.tag == 888903")

# (7) 上游问题关闭：FAQ 四文件 + 代码标记
faq = 0
for f in ["Natives/resources/help-faq.json", "Natives/resources/en.lproj/help-faq.json",
          "Natives/resources/zh-CN.lproj/help-faq.json", "Natives/resources/zh-Hant.lproj/help-faq.json"]:
    if "上游" in rd(f) or "upstream" in rd(f):
        faq += 1
if faq == 4:
    passed += 1
else:
    failed.append(f"232-7 FAQ upstream note present in {faq}/4 files")
check("232-7b code marker", svc, "本议题【按上游问题关闭】")

# (8) 前置详情页：启动器内打开 + 图标/介绍
check("232-8a detail VC", "Natives/ModVersionViewController.m", "@implementation Ame232DepDetailViewController")
check("232-8b in-app route", "Natives/ModVersionViewController.m", "dependency quick-entry (in-app detail)")
check("232-8c modrinth fetch", "Natives/ModVersionViewController.m", "api.modrinth.com/v2/project/")

# (9) SDL 打开文件夹死锁根修 + 浏览器取证
check("232-9a main-thread no-wait", "Natives/input_bridge_v3.m", "主线程调用时跳过等待")
check("232-9b guarded leave", "Natives/input_bridge_v3.m", "if (group != NULL) dispatch_group_leave(group);")
check("232-9c browser forensics", "Natives/FolderBrowserViewController.m", "Task232 viewWillAppear: rows=%lu first=%@")
check("232-9d browser entry log", "Natives/FolderBrowserViewController.m", "Task232 browser requested for")

# (10) 联机自动扫描端口：ZeroTier 房主自动检测 + 18s 手动兜底
check("232-10a auto detect", "Natives/MultiplayerViewController.m", "ame232_startAutoPortDetection")
check("232-10b detector reactivated", "Natives/MultiplayerViewController.m", "auto-detected LAN port %@ -- generating share code")
check("232-10c 18s fallback", "Natives/MultiplayerViewController.m", "auto detection window elapsed without a port -- falling back to manual input")

# (11) 齿轮菜单文字：cell 白字 + 软黑投影 + 开菜取证
check("232-11a cell shadow", nav, "cell.textLabel.layer.shadowOpacity = 0.85")
check("232-11b menu shown forensics", nav, "Task232 menu shown: rows=%lu firstTitleLen=%lu")

# (12) 自动开输入法(SDL)：常驻放行语义（非 one-shot）
check("232-12a always-on mode", svc, "always-on mode while switch is enabled")
check("232-12b hard suppression first", svc, "ame232_sinceDismiss < 2.5")

# (13) 备份导入：实例感知 + 自动切换
check("232-13a touched instances", "Natives/DataTransferService.m", "ame232_touchedInstances")
check("232-13b auto switch", "Natives/DataTransferService.m", "auto-switched game directory to '%@'")
check("232-13c pick instance hint", "Natives/DataTransferService.m", "ame232.import.pick_instance")

# (14) 欢迎页：窗口基准锚点 + 卡片实底投影 + 每页取证 + 空标题过滤
check("232-14a window-based anchors", "Natives/WelcomeViewController.m", "UIWindow.mainWindow.bounds")
check("232-14b solid card + shadow", "Natives/Ame223CoachMarksView.m", "_ame224_card.layer.shadowRadius = 18.0")
check("232-14c per-page forensics", "Natives/Ame223CoachMarksView.m", "Task232 page %lu/%lu: spot=%@ titleLen=%lu")
check("232-14d empty-title filter", "Natives/Ame223CoachMarksView.m", "锚点页也要求非空标题")

# (15) 控件分享：上传免检 + 下载扫描询问
check("232-15a upload unchecked", "Natives/ControlRepoViewController.m", "上传免检")
check("232-15b issues collector", "Natives/ControlRepoViewController.m", "ame232_layoutSafetyIssues")
check("232-15c ask dialog", "Natives/ControlRepoViewController.m", "ame232.repo.check.continue")
check("232-15d 4MB cap", "Natives/ControlRepoViewController.m", "4 * 1024 * 1024")
check("232-15e keycode -12 floor", "Natives/ControlRepoViewController.m", "iv < -12")

# (16) 白底黑边字体：四方向外扩描边（CoreText stroke + 光晕退役）
check("232-16a drawTextInRect swizzle", bm, "ame232_swizzledLabelDrawTextInRect")
check("232-16b four offsets", bm, "CGRectOffset(rect,  0.6f,  0.0f)")
check("232-16c setText marks only", bm, "ame232_OutlineMarkKey")
check_absent("232-16d CoreText stroke retired", bm, "NSStrokeWidthAttributeName")
check_absent("232-16e halo retired", bm, "shadowRadius = 2.5")

# (17) i18n：20 新键 ×5 语言 + 2 退役键移除 + 裸键名修复
KEYS = ["game.menu.settings", "ame232.repo.check.title", "ame232.repo.check.continue",
        "ame232.repo.check.cancel", "ame232.repo.issue.size", "ame232.repo.issue.shape",
        "ame232.repo.issue.depth", "ame232.repo.issue.strlen", "ame232.repo.issue.url",
        "ame232.repo.issue.keycode", "ame232.repo.issue.buttons", "ame232.import.switched",
        "ame232.import.pick_instance", "ame232.mp.auto_title", "ame232.mp.auto_msg",
        "ame232.deps.browser", "ame232.deps.loading", "ame232.deps.stats",
        "ame232.deps.cf_desc", "ame232.deps.no_desc"]
for lang in ["en", "zh-Hans", "zh-Hant", "zh-CN", "ja"]:
    src = rd(f"Natives/resources/{lang}.lproj/Localizable.strings")
    miss = [k for k in KEYS if f'"{k}"' not in src]
    if miss:
        failed.append(f"232-17 i18n {lang} missing: {miss}")
    else:
        passed += 1
    if '"ame230.controls.unbound_toast"' not in src and '"ame230.repo.safety_blocked"' not in src:
        passed += 1
    else:
        failed.append(f"232-17 retired keys still present in {lang}")

# --- standing audits -------------------------------------------------------
# 自引用 block 舰队扫描（Task231 常驻审计，Task232 后 = 6 处全 __block）
r = subprocess.run([sys.executable, os.path.join(BASE, "scripts/task231_selfref_block_scan.py")],
                   capture_output=True, text=True, cwd=os.path.join(BASE, "Natives"))
bad = [l for l in r.stdout.splitlines() if l.startswith("***")]
if "total real self-referencing blocks: 6" in r.stdout and not bad:
    passed += 1
else:
    failed.append(f"232-fleet selfref scan: {bad or 'count mismatch'}")

# task139 语法门 + task225 括号审计
r = subprocess.run([sys.executable, os.path.join(BASE, "scripts/task139_syntax_gate.py")],
                   capture_output=True, text=True, cwd=BASE)
if "all balanced" in r.stdout:
    passed += 1
else:
    failed.append("232-fleet task139 syntax gate RED")
r = subprocess.run([sys.executable, os.path.join(BASE, "scripts/task225_bracket_audit.py")],
                   capture_output=True, text=True, cwd=BASE)
n_ok = sum(1 for l in r.stdout.splitlines() if l.startswith("[OK "))
n_bad = sum(1 for l in r.stdout.splitlines() if l.startswith("[FAIL"))
if n_bad == 0 and n_ok >= 10:
    passed += 1
else:
    failed.append(f"232-fleet task225 bracket audit: {n_bad} FAIL of {n_ok}")

print(f"verify_task232: {passed} passed, {len(failed)} failed")
for f in failed:
    print(f"  FAIL: {f}")
sys.exit(1 if failed else 0)
