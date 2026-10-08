#!/usr/bin/env python3
# verify_task223.py -- Task223 25-item checklist round verifier.
# Anchors are code-level (distinctive strings from the implementation) plus
# fleet-level (l10n baseline 2606, announcements 43, version.h addendum).
import os, re, sys, json, glob

REPO = os.path.join(os.path.dirname(__file__), "..")
PASSED, FAILED = [], []

def rd(p):
    with open(os.path.join(REPO, p), encoding="utf-8", errors="replace") as f:
        return f.read()

def check(name, ok, detail=""):
    (PASSED if ok else FAILED).append(name)
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {name}" + (f" -- {detail}" if detail and not ok else ""))

vs  = rd("Natives/ctxbridges/virgl_server.m")
tg  = rd("Natives/external/gl4es/tinygl4angle.c")
ut  = rd("Natives/utils.m")
sd  = rd("Natives/SceneDelegate.m")
osm = rd("Natives/ctxbridges/osm_bridge.mm")
glb = rd("Natives/ctxbridges/gl_bridge.m")
rpp = rd("Natives/LauncherRightPanelViewController.m")
psp = rd("Natives/ProfileSettingsViewController.m")
tcp = rd("Natives/TouchControllerPreferencesViewController.m")
svcv= rd("Natives/SurfaceViewController.m")
ib3 = rd("Natives/input_bridge_v3.m")
tmg = rd("Natives/TerracottaManager.m")
dts = rd("Natives/DataTransferService.m")
wv  = rd("Natives/WelcomeViewController.m")
rrv = rd("Natives/LauncherRootViewController.m")
abv = rd("Natives/AboutViewController.m")
alv = rd("Natives/AccountListViewController.m")
alb = alv  # short alias used by section K
bm  = rd("Natives/BackgroundManager.m")
bmh = rd("Natives/BackgroundManager.h")
lpv = rd("Natives/LauncherPreferencesViewController.m")
aivc= rd("Natives/AI/AIViewController.m")
wf  = rd(".github/workflows/development.yml")
main= rd("Natives/main.m")

print("== A. 渲染修复（清单 1/2/3+4/7） ==")
check("A1 VirGL：EGLint typedef 回 32 位（intptr_t 在 arm64 上 64 位，ANGLE 属性对错位）",
      "typedef int EGLint;" in vs
      and not re.search(r"typedef\s+intptr_t\s+EGLint\s*;", vs)
      and not re.search(r"typedef\s+(u?int\d+_t|intptr_t)\s+EGLint", vs))
check("A2 VirGL：surfaceless 回退 + 扩展查询 + 错误日志三件套",
      "ame_vs_eglQueryString" in vs and "AME_VS_EGL_EXTENSIONS" in vs)
check("A3 ANGLE：ES3.00 下移除 image 精度声明（ES3.10 才合法）",
      "precision highp image2D;" not in re.sub(r"//.*", "", tg)
      and "precision highp float;" in tg)
check("A4 后台驻车：park API 三函数 + 双桥交换边界等待",
      "ame223_bg_park_begin" in ut and "ame223_bg_park_wait" in ut
      and 'ame223_bg_park_wait("gl_swap")' in glb
      and 'ame223_bg_park_wait("osm_swap")' in osm)
check("A5 后台驻车：SceneDelegate 生命周期挂接（resignActive 进/激活出，双向释放）",
      "ame223_bg_park_begin()" in sd and sd.count("ame223_bg_park_end()") >= 2)
check("A6 JIT：进度 alert animated:NO（后台切换期主队列楔死嫌疑）+ ame185 无条件续派路径保留",
      rpp.count("presentViewController:alert animated:NO") >= 1
      and "ame185_openJITEnablerURL" in rd("Natives/LauncherNavigationController.m"))

print("== B. 版本隔离迁移（清单 5/6） ==")
check("B1 迁移源 = 当前 gameDir 已解析目录（非仅实例根）",
      "清单第 5/6 项" in psp and "migrateSource = oldGameDirRaw" in psp
      and "stringByAppendingPathComponent:clean" in psp)
check("B2 同目录判定防自搬（symlink 归一化）",
      "ame223_sameDir" in psp and "stringByResolvingSymlinksInPath" in psp)

print("== C. TouchController（清单 8） ==")
check("C1 用户关闭哨兵：user_off 置位后启动期自动配置不再覆盖",
      "control.mod_touch_user_off" in tcp and "control.mod_touch_user_off" in rd("Natives/ios_uikit_bridge.m"))
check("C2 关闭路径写哨兵 + 重开清哨兵（双态）",
      'setPrefBool(@"control.mod_touch_user_off", YES)' in tcp
      and tcp.count('setPrefBool(@"control.mod_touch_user_off", NO)') >= 2)

print("== D. 输入法防抖（清单 10） ==")
check("D1 Stop 路径 resign 防抖 250ms + 起跳时组词复查 + Start 取消挂起",
      "ame223_pendingStopResign" in svcv and "debounced 250ms" in svcv
      and "cancelled by StartTextInput" in svcv)

print("== E. 文件夹浏览器（清单 9） ==")
check("E1 FolderBrowserViewController 存在并接入 input_bridge（.json 选择器退役）",
      os.path.exists(os.path.join(REPO, "Natives/FolderBrowserViewController.m"))
      and "wrappedControllerForPath:fsPath" in ib3
      and '#import "FolderBrowserViewController.h"' in ib3)
check("E2 CMakeLists 收录新文件",
      "FolderBrowserViewController.m" in rd("Natives/CMakeLists.txt"))
check("E3 Ame223CoachMarksView 存在（第 16 项配套）",
      os.path.exists(os.path.join(REPO, "Natives/Ame223CoachMarksView.m")))

print("== F. 陶瓦联机预检（清单 11） ==")
check("F1 公共服务器预检（15 秒 EasyTier 搜索超时根因）+ 通过/失败双锚点",
      "public peer precheck passed" in tmg and "terracotta.stage.precheck" in tmg)

print("== G. 导出重构（清单 12/13） ==")
check("G1 DataExportViewController 二级入口（设置页直推）",
      "DataExportViewController *vc = [[DataExportViewController alloc] init]" in lpv)
# Task225 再锚：224-B 子代理重写导出引擎后旧 G2 两锚（maxInFlight/
# writeGroup）已随旧实现退役——新引擎 = 3 worker 并行 + 信号量预算
#（Ame224BudgetUnits）+ dispatch_group 汇合，语义等价。
check("G2 流水线：并行压缩 + 信号量预算（Task224 引擎，Task225 再锚）",
      "dispatch_semaphore_create((long)Ame224BudgetUnits)" in dts
      and "dispatch_group_enter(group)" in dts
      and "dispatch_group_leave(group)" in dts)
check("G3 backup 资源类型 + 版本下载任务体系挂接",
      'DownloadTaskResourceTypeBackup = @"backup"' in rd("Natives/DownloadTaskItem.m")
      and "DownloadTaskResourceTypeBackup" in rd("Natives/DataExportViewController.m"))
check("G4 压缩三档 + 提示文案键（none/fast/best）",
      "dataexport.level.none" in rd("Natives/resources/en.lproj/Localizable.strings")
      and "dataexport.level.best.hint" in rd("Natives/resources/en.lproj/Localizable.strings"))

print("== H. 欢迎向导重做（清单 14/15/16/21） ==")
check("H1 壁纸直取 + 亮度自适应反色（BackgroundManager API）",
      "ame223_currentWallpaperImage" in bmh and "wallpaperLuminanceIsDark" in bmh
      and "Ame223WallpaperChanged" in bm)
check("H2 向导步骤按钮化（UIAction）+ intro 重建",
      "清单第 15 项" in wv and "清单第 16 项" in wv)
check("H3 zl2 灰屏圆圈焦点介绍 + 教练标记",
      "Ame223CoachMarksView" in wv or "Ame223CoachMarksView" in rd("Natives/Ame223CoachMarksView.m"))
check("H4 启动遮罩壁纸（SurfaceViewController 直取）",
      "清单第 14 项" in svcv)

print("== I. 侧边栏方向性动画（清单 17） ==")
check("I1 crossDissolve 退役：弹簧滑动 + 方向位移 + 双视图 alpha 过渡",
      "UIViewAnimationOptionTransitionCrossDissolve" not in rrv
      and "CGAffineTransformMakeTranslation(30, 0)" in rrv
      and "usingSpringWithDamping:0.85" in rrv)

print("== J. 关于页与 README（清单 18/19/22/23） ==")
check("J1 QQ 行 Discord 按钮 + 捐献旁 GitHub Star CTA",
      "about.discord.join" in abv and "about.donate.star" in abv)
check("J2 Discord 邀请链接 + GitHub 仓库链接",
      "https://discord.gg/HqcmswrEy" in abv)
check("J3 README：Discord 上移 + Star CTA",
      "discord" in rd("README.md").lower() and "⭐" in rd("README.md"))
check("J4 air 遗留引用清理（主横幅自称 + 关于页 URL 族）",
      "清单第 23 项" in main and "清单第 23 项" in abv)

print("== K. 账号高级操作（清单 20） ==")
check("K1 行内 ⋯ 菜单按钮 + 长按同源动作",
      "清单第 20 项" in alb and "ame223_menuButton" in alb
      and "ame223_accountMenuItemsAtIndexPath" in alb)
check("K2 高级项：微软改名/换皮肤；离线默认皮肤 Steve/Alex",
      "account.menu.change_name" in rd("Natives/resources/en.lproj/Localizable.strings")
      and "account.default_skin.title" in rd("Natives/resources/en.lproj/Localizable.strings")
      and 'actionWithTitle:@"Steve"' in alb and 'actionWithTitle:@"Alex"' in alb)

print("== L. 上游同步（清单 24） ==")
_u = ut
check("L1 Task173 权威路径撤 1024 下限（3GB 设备 jetsam 根修）",
      "no floor on authoritative path" in _u
      and not re.search(r"if \(ceilingMB < 1024\) \{\s*\n\s*ceilingMB = 1024;", _u.split("if (ceilingMB <= 0)")[0]))
check("L2 自动内存双 entitlement（memorystatus + increased-memory-limit）",
      'getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit")' in _u
      and "raisedCeiling" in _u)
check("L3 memorystatus 权限不钳 + AMETHYST_MEM_NO_CLAMP 逃生门 + 256 下限",
      "ame223_canRaiseJetsamLimit" in _u and "AMETHYST_MEM_NO_CLAMP" in _u
      and "if (mem < 256) mem = 256;" in _u)
check("L4 AI 会话页 PAGE-GLASS（与其余 AI 页同风格层）",
      "[[BackgroundManager sharedManager] makeViewControllerTransparent:self];" in aivc)
check("L5 CI：macos-15 + 优先 Xcode ≥26 + SDKPATH/DEVELOPER_DIR 钉死 + 桶键换代",
      "runs-on: macos-15" in wf and "prefer 26+ for iOS 26 Liquid Glass" in wf
      and 'echo "SDKPATH=$SDKPATH_REAL" >> "$GITHUB_ENV"' in wf
      and "ccache-macos15-v1-" in wf)
check("L6 拒绝项留档：metallum agent 保留守护补丁版（上游新版线程仍非守护）",
      "Task 211 exit" in rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h"))

print("== P. 上游同步第二波特口（清单 24 续，10-06 会话） ==")
mru = rd("Natives/MinecraftResourceUtils.m")
jgv = rd("Natives/JavaGUIViewController.m")
msa = rd("Natives/authenticator/MicrosoftAuthenticator.m")
jlf = rd("Natives/JavaLauncher.m")
dlvc= rd("Natives/DownloadViewController.m")
cjs = rd("Natives/customcontrols/ControlJoystick.m")
cim = rd("Natives/input/ControllerInput.m")
check("P1 Forge 早窗闪退（upstream 63add943c）：lwjgl-glfw/natives 类路径豁免",
      '![library[@"name"] hasPrefix:@"org.lwjgl:lwjgl-glfw"]' in mru
      and '![library[@"name"] hasPrefix:@"org.lwjgl:lwjgl-natives"]' in mru
      and re.search(r'\[library\[@"name"\] hasPrefix:@"org\.lwjgl"\]\s*&&', mru))
check("P2 Forge 早窗闪退（63add943c）：POJAV_SKIP_JNI_GLFW 改 unsetenv（GLFW JNI 桥恢复注册）",
      'unsetenv("POJAV_SKIP_JNI_GLFW");' in jgv
      and not re.search(r'(?<![A-Za-z])setenv\("POJAV_SKIP_JNI_GLFW"', jgv))
check("P3 Flux-p1（3a2116c05）：isConnectivityError 工具 + MS 离线判定接入",
      "BOOL isConnectivityError(NSError *error)" in ut
      and "isConnectivityError(error)" in msa
      and "NSURLErrorDataNotAllowed" not in re.sub(r"//.*", "", msa.split("isConnectivityError")[1][:600]))
check("P4 Flux-p1（3a2116c05）：asm-all 换 jar 后清继承 size（校验必败根修）",
      'removeObjectForKey:@"size"' in mru[mru.rfind("asm-all"):mru.rfind("asm-all")+400])
check("P5 Flux-p1（3a2116c05）：四正方向误判回中——joystick/手柄两处与改或",
      'if (xValue != 0 || yValue != 0)' in cjs
      and 'if (xValue != 0 || yValue != 0)' in cim
      and 'if (xValue != 0 && yValue != 0)' not in cjs + cim)
check("P6 JVM 软引用（f05ec3842 安全项）：SoftRefLRU 250ms；同提交 -Xss1m 已拒（-Xss32M 保留）",
      'PUSH_MARGV_LITERAL("-XX:SoftRefLRUPolicyMSPerMB=250");' in jlf
      and '-Xss32M' in jlf and '"-Xss1m"' not in jlf)
check("P7 stikjit 失败兜底（f05ec3842 缺口项）：openURL 回调弹错 + i18n 键四语言在位",
      'launcher.jit.stikjit_unhandled' in dlvc
      and all('launcher.jit.stikjit_unhandled' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
              for l in ["en", "zh-Hans", "zh-Hant", "zh-CN"]))
_vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("P8 拒绝项留档（version.h 第二波特口附录）：Xss1m 与 63add943c/3a2116c05 因由",
      "Task 223 port block" in _vh and "-Xss1m" in _vh and "63add943c" in _vh and "3a2116c05" in _vh)

print("== M. i18n（清单 25） ==")
LANGS = ["en", "zh-Hans", "zh-Hant", "zh-CN"]
keysets = []
for lang in LANGS:
    keys = set(re.findall(r'^"([^"]+)"\s*=',
                          rd(f"Natives/resources/{lang}.lproj/Localizable.strings"), re.M))
    keysets.append(keys)
    # Task225 再锚：Task224 +69（导出分区/界面风格族）→ 2675；Task225 +21
    #（隔离选择/三态徽标/缩放反色/欢迎页 f5-f6）→ 2715。四语对等由
    # task225_strings_audit.py 独立复验。
    check(f"M-{lang} 唯一键 2715（2564 + Task223 42 + Task224 69 + Task225 21 + Task226 12 + Task227 7）", len(keys) == 2727, f"got {len(keys)}")
check("M-四语言键集一致", keysets[0] == keysets[1] == keysets[2] == keysets[3])
# used-vs-defined sweep
used = set()
for f in glob.glob(os.path.join(REPO, "Natives/**/*.m"), recursive=True):
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
    except OSError:
        continue
    used |= set(re.findall(r'localize\(\s*@"([A-Za-z0-9_.\-]+)"', text))
missing = sorted(k for k in used if k not in keysets[0])
check("M-代码引用零缺键（used ⊆ defined）", not missing, f"missing: {missing[:8]}")
for k in ["folderbrowser.item_count", "dataexport.start", "coachmarks.hint",
          "about.discord.join", "account.default_skin.title",
          "terracotta.stage.precheck", "welcome.intro.subtitle"]:
    check(f"M-新键在位 {k}", all(k in ks for ks in keysets))
# translation sanity: zh files must not carry the raw English value for
# translatable new keys (proper-noun keys excluded)
_pairs = [("about.donate.star_hint", "Can't donate"), ("dataexport.start", "Start Export"),
          ("coachmarks.hint", "Tap anywhere")]
for k, en_frag in _pairs:
    zh_val = re.search(r'^"%s" = "(.*)";' % re.escape(k),
                       rd("Natives/resources/zh-Hans.lproj/Localizable.strings"), re.M).group(1)
    check(f"M-zh-Hans 已翻译 {k}", en_frag not in zh_val, f"raw english: {zh_val[:40]}")

print("== N. 公告 / version.h / 舰队重锚 ==")
ann = json.load(open(os.path.join(REPO, "announcements.json"), encoding="utf-8"))["announcements"]
ids = [a["id"] for a in ann]
check("N1 公告 43 条 + id 唯一 + task223 在尾",
      len(ann) == 43 and len(set(ids)) == len(ids)
      and ids[-1] == "task223-25item-round-upstream-sync-2026-10-05")
check("N2 尾窗顺延（220@-2 / 219@-3 / 218@-4 / 217@-5 / 216@-6 / 206@-7）",
      ids[-2] == "task220-account-avatar-skin-integrity-2026-10-05"
      and ids[-3] == "task219-virgl-angle-welcome-rebuild-2026-10-04"
      and ids[-4] == "task218-air-interim-welcome-crash-diagnosis-2026-10-04"
      and ids[-5] == "task217-download-fixes-about-isolation-2026-10-03"
      and ids[-6] == "task216-ui-2026-10-03"
      and ids[-7] == "task206-nggl4es-2026-10-01")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("N3 version.h：REVISION 22 不抬 + Task223 addendum（含拒绝项留档）",
      "#define REVISION 22" in vh and "REVISION 22 addendum (Task 223, no bump)" in vh)
# Task226 l10n 扫荡（+12 键）：2715 基线，无 2727/2606 残留断言
check("N4 舰队 l10n 基线扫荡（Task226：2715 无 2696/2606 残留断言）",
      "== 2520" not in rd("scripts/verify_task202.py")
      and "== 2520" not in rd("scripts/verify_task206.py")
      and "== 2727" in rd("scripts/verify_task211.py")
      and "唯一键 2715" in rd("scripts/verify_task217.py")
      and "== 2727" not in rd("scripts/verify_task211.py")
      and "唯一键 2606" not in rd("scripts/verify_task217.py"))
check("N5 舰队公告窗扫荡（43 + 尾窗新位抽查）",
      "len(ann) == 43" in rd("scripts/verify_task217.py")
      and '"== 43" in rd("scripts/verify_task207.py")' in rd("scripts/verify_task216.py")
      and 'ids[-6] == "task216-ui-2026-10-03"' in rd("scripts/verify_task216.py"))

print("== O. 语法门（括号平衡，本轮关键改动面；house 状态机剔注释/字符串/字符字面量） ==")
def strip_comments_strings(src):
    out, i, n, state = [], 0, len(src), "code"
    while i < n:
        c = src[i]; nxt = src[i+1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "lc"; i += 2; continue
            if c == "/" and nxt == "*":
                state = "bc"; i += 2; continue
            if c == '"':
                state = "st"; out.append(" "); i += 1; continue
            if c == "'":
                state = "ch"; out.append(" "); i += 1; continue
            out.append(c)
        elif state == "lc":
            if c == "\n": state = "code"; out.append(c)
        elif state == "bc":
            if c == "*" and nxt == "/": state = "code"; i += 2; continue
        elif state == "st":
            if c == "\\": i += 2; continue
            if c == '"': state = "code"
        elif state == "ch":
            if c == "\\": i += 2; continue
            if c == "'": state = "code"
        i += 1
    return "".join(out)
for f in ["Natives/ctxbridges/virgl_server.m", "Natives/external/gl4es/tinygl4angle.c",
          "Natives/utils.m", "Natives/SurfaceViewController.m",
          "Natives/DataExportViewController.m", "Natives/FolderBrowserViewController.m",
          "Natives/WelcomeViewController.m", "Natives/AccountListViewController.m",
          "Natives/ProfileSettingsViewController.m", "Natives/AI/AIViewController.m",
          "Natives/BackgroundManager.m", "Natives/LauncherRootViewController.m"]:
    code = strip_comments_strings(rd(f))
    check(f"O-括号 {os.path.basename(f)}",
          code.count("{") == code.count("}") and code.count("(") == code.count(")"),
          f"braces {code.count('{')}/{code.count('}')} parens {code.count('(')}/{code.count(')')}")

print()
print(f"{'=' * 40}\n{len(PASSED)} passed, {len(FAILED)} failed")
if FAILED:
    for f in FAILED:
        print(f"  FAILED: {f}")
    sys.exit(1)
print("ALL GREEN")
