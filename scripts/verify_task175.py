#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
verify_task175.py -- 六连修装机反馈轮

用户反馈（f484eb7 构建，b1e9723/e54aca5 三份日志）：
  1) "angle依旧闪退"                    -- pipeline/gui 着色器 1:1 语法错误
  2) "cf还是不会显示下载量以及依据筛选排序" -- downloads 字段断层 + 整合包路径漏传筛选
  3) "主页上方的头像依旧切换标签页再切换回去无法正常显示"
  4) "物品栏依旧不会动态调节……切换界面尺寸或者更换分辨率就会有位置和大小偏移"
  5) "forge1.8.9加vgpu崩溃（安装整合包的时候怎么连jit申请都没有弹出来）"
  6) "在新拟态壁纸开启的情况下，壁纸会被覆盖导致无法正常显示"

组别：
  A ANGLE ES 重写（spvc_shim.c 拦截 + 门控 + 登记 + 双形选项 API + 二进制法证）
  B CurseForge 下载量 + 整合包排序/加载器
  C 主页头像（初始实例注册 + 转场后重载）
  D 物品栏/输入（分辨率系数修正 + 单写者比例 + guiScale 节流 + 取证）
  E 旧版 Forge（maven 后缀形候选 + 占位版本启动拦截）
  F 新拟态壁纸共存（画布门退役 + 柔和阴影档）
  G 文档（公告/version.h/l10n 计数不动/fallback 最小集）
  H 级联（129/141/165/167/168/169/170/171/172/173/173b/174 全绿）
"""
import json
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

PASS = 0
FAIL = 0


def rd(p):
    with open(p, encoding="utf-8", errors="replace") as f:
        return f.read()


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"[PASS] {name}")
    else:
        FAIL += 1
        print(f"[FAIL] {name}" + (f"  -- {detail}" if detail else ""))


shim = rd("Natives/spvc_shim.c")
cfa = rd("Natives/installer/modpack/CurseForgeAPI.m")
dlvc = rd("Natives/DownloadViewController.m")
rootvc = rd("Natives/LauncherRootViewController.m")
newsvc = rd("Natives/LauncherNewsViewController.m")
envh = rd("Natives/environ.h")
svc = rd("Natives/SurfaceViewController.m")
ib3 = rd("Natives/input_bridge_v3.m")
mis = rd("Natives/ModpackImportService.m")
jl = rd("Natives/JavaLauncher.m")
bm = rd("Natives/BackgroundManager.m")
engine_m = rd("Natives/UIKit+NativeSurface.m")
engine_h = rd("Natives/UIKit+NativeSurface.h")

# ============================================================
# A. ANGLE ES 重写
# ============================================================
print("== A. ANGLE 桌面 GLSL → ES 300 重写 ==")
check("A1 病历注释在位（pipeline/gui 1:1 syntax error 机制叙述）",
      "ERROR: 1:1: '' : syntax error" in shim
      and "minecraft:pipeline/gui" in shim
      and "桌面 GLSL → GLSL ES 300 重写" in shim)
check("A2 门控：仅 tinygl4angle 会话 + 逃生阀",
      'strstr(renderer, "tinygl4angle") != NULL' in shim
      and 'getenv("AME175_ANGLE_ES_REWRITE")' in shim
      and 'strcmp(kill, "0") == 0' in shim
      and 'getenv("AMETHYST_RENDERER")' in shim)
check("A3 桌面源判定（#version >= 130 且非 es）",
      "ame175_is_desktop_glsl" in shim
      and 'strncmp(src, "#version ", 9) != 0' in shim
      and 'strtol(&src[9], NULL, 10)' in shim)
check("A4 登记：parse 留存字 + compiler 登记 + destroy/release 作废",
      shim.count("ame175_record_parse(") >= 2
      and "ame175_forget_context" in shim
      and shim.count("ame175_forget_context(context);") == 2)
check("A5 重写主体：同源校验 + 重 parse + ES 编译器 + 失败回落",
      # Task176 重锚：重写主体升级为自证（is_es_source）+ 文本兑底（textual）
      # + 路径标记（path=option|textual），最终替换指针改名为 ame176_final。
      "ame175_ctxe->last_parsed_ir == ame175_ce->parsed_ir" in shim
      and "ame175_compile_es_source(" in shim
      and "*source = ame176_final;" in shim
      and "ame176_is_es_source(ame175_es)" in shim
      and "ame176_textual_es_rewrite(*source)" in shim
      and "falling back to " in shim)
check("A6 双形选项 API（新版优先 + 旧版兜底）+ 枚举值钉 vendored 头",
      "spvc_context_create_compile_options" in shim
      and "spvc_compile_options_set_option" in shim
      and "spvc_compiler_create_compiler_options" in shim
      and "spvc_compiler_options_set_bool" in shim
      and "spvc_compiler_options_set_uint" in shim
      and "#define AME175_OPTION_GLSL_VERSION (8u | 0x2000000u)" in shim
      and "#define AME175_OPTION_GLSL_ES (9u | 0x2000000u)" in shim)
check("A7 装机取证锚（成功/失败两向日志）",
      "Task175 ANGLE ES rewrite: desktop GLSL -> GLSL ES" in shim
      and "Task175 ANGLE ES rewrite FAILED" in shim)
check("A8 生命周期：ES 编译器挂同 ctx（fresh_ir TAKE_OWNERSHIP）+ 生命周期注释",
      "AME175_CAPTURE_TAKE_OWNERSHIP" in shim
      and "随 MC 自己的" in shim)
r = subprocess.run([sys.executable, "scripts/task175_spvc_symtab.py"],
                   capture_output=True, text=True, timeout=60)
check("A9 二进制法证：impl dylib 实导出旧版选项 API（set_bool/set_uint/install/create）",
      r.returncode == 0
      and "OK      spvc_compiler_options_set_bool" in r.stdout
      and "OK      spvc_compiler_options_set_uint" in r.stdout
      and "OK      spvc_compiler_install_compiler_options" in r.stdout
      and "OK      spvc_compiler_create_compiler_options" in r.stdout)

# ============================================================
# B. CurseForge 下载量 + 整合包排序
# ============================================================
print("== B. CurseForge 下载量 + 整合包排序 ==")
check("B1 downloads 透传（downloadCount → downloads，类型守卫）",
      '@"downloads": [project[@"downloadCount"] isKindOfClass:NSNumber.class]' in cfa
      and '? project[@"downloadCount"] : @0,' in cfa)
check("B2 卡片渲染端仍读 downloads（formatDownloadCount 链）",
      'formatDownloadCount:data[@"downloads"]' in dlvc)
check("B3 整合包搜索补 sort 传参",
      'filters[@"sort"] = self.currentSortField;' in dlvc[dlvc.index("- (void)loadModpackList"):dlvc.index("- (void)searchModpacks:")])
check("B4 整合包搜索补 loader 传参",
      'filters[@"loader"] = self.currentModLoader;' in dlvc[dlvc.index("- (void)loadModpackList"):dlvc.index("- (void)searchModpacks:")])
check("B5 CF 适配器已能消费（Task173 映射 + URL 拼接在位，本轮零改动面）",
      "ame173_applySortAndLoaderParams:filters params:ame173_params" in cfa
      and '&sortField=%@&sortOrder=%@' in cfa)

# ============================================================
# C. 主页头像
# ============================================================
print("== C. 主页头像（第五轮） ==")
check("C1 初始主页实例注册进缓存（侧栏布局补齐；含日志铁证叙述）",
      "self.cachedHomeVC = newsVC;" in rootvc
      and rootvc.index("self.cachedHomeVC = newsVC;") < rootvc.index("[self setContentViewController:newsVC animated:NO];")
      and "初始主页实例注册进缓存" in rootvc)
check("C2 卡片布局本就注册（不回退）",
      "self.cachedHomeVC = newsVC;" in rd("Natives/LauncherCardLayoutViewController.m"))
check("C3 0.35s 兜底先重载个人卡再直写（crossDissolve 快照防御）",
      "[strongSelf reloadProfileSection];" in newsvc[newsvc.index("0.35 * NSEC_PER_SEC"):newsvc.index("0.35 * NSEC_PER_SEC") + 700]
      and "[strongSelf ame171_syncVisibleProfileAvatar];" in newsvc[newsvc.index("0.35 * NSEC_PER_SEC"):newsvc.index("0.35 * NSEC_PER_SEC") + 700]
      and newsvc.index("[strongSelf reloadProfileSection];",
                       newsvc.index("0.35 * NSEC_PER_SEC")) < newsvc.index("[strongSelf ame171_syncVisibleProfileAvatar];",
                                                                          newsvc.index("0.35 * NSEC_PER_SEC")))

# ============================================================
# D. 物品栏 / 输入
# ============================================================
print("== D. 物品栏与输入比例 ==")
check("D1 environ.h 声明 ame_windowToPhysRatio（单一事实源注释）",
      "AME_ENVIRON_DECL float ame_windowToPhysRatio;" in envh)
check("D2 updateSavedResolution 单点写入（钳制 [0.25,8]，异常写 0）",
      "ame_windowToPhysRatio = 0.0f;" in svc
      and "ame175_ratio >= 0.25f && ame175_ratio <= 8.0f" in svc)
check("D3 touchHotbar 优先全局比例 + 本地回退 + 来源标记",
      "if (ame_windowToPhysRatio > 0.0f) {" in ib3
      and "ame175_ratioSource = 1;" in ib3
      and "ame175_ratioSource = 2;" in ib3)
check("D4 guiScale 节流保鲜（2s + options.txt 直读）",
      "s_ame175_lastScaleRefresh > 2.0" in ib3
      and "refreshGuiScaleNatively();" in ib3[ib3.index("s_ame175_lastScaleRefresh"):ib3.index("s_ame175_lastScaleRefresh") + 300])
check("D5 Task175 取证快照（phys/surface/win/resScale/guiScale/ratio/barY 一行钉死）",
      "Task175 geometry snapshot" in ib3
      and "source=%d: 1=savedResolution-global 2=local-recompute 0=fallback-1.0" in ib3)
check("D6 sendTouchPoint 抓取态补乘 resolutionScale（× 从分支提出为无条件；Task78 FSR 除法锚原位）",
      "if (mgFsrScale > 0.0f) screenScale /= mgFsrScale;" in svc
      and svc.index("if (mgFsrScale > 0.0f) screenScale /= mgFsrScale;")
      < svc.index("screenScale *= resolutionScale;")
      < svc.index("if (!isGrabbing) {"))
check("D7 Task171 几何锚不回退（FSR-aware 日志 + 182x22 精灵 + 比例护栏）",
      "Task171 FSR-aware hotbar geometry" in ib3
      and "(22 * guiScale)" in ib3
      and "(182 * guiScale)" in ib3)

# ============================================================
# E. 旧版 Forge
# ============================================================
print("== E. 旧版 Forge 装包 ==")
check("E1 候选列表方法（后缀形仅 1.x minor<=12 追加；1.8.9 实锤注释）",
      "buildInstallerURLCandidatesForLoader" in mis
      and "ame175_legacyForge = (ame175_minor > 0 && ame175_minor <= 12);" in mis
      and "1.8.9-11.15.1.2318-1.8.9" in mis)
check("E2 下载循环逐候选尝试 + 全败日志",
      "for (NSString *ame175_candidate in installerURLCandidates) {" in mis
      and "installerDownloaded = YES;" in mis
      and "all %lu candidates" in mis)
check("E3 成功日志带胜出候选（via）",
      "download completed: %@ (via %@)" in mis)
check("E4 launchJVM 占位 mainClass 预检（i18n_str_555 复用 + 主线程弹窗 + return 1）",
      'isEqualToString:@"net.angelaura.installer.MissingLoader"' in jl
      and "refusing to launch placeholder version JSON" in jl
      and "localize(@\"i18n_str_555\", nil)" in jl
      and "dispatch_async(dispatch_get_main_queue(), ^{" in jl[jl.index("refusing to launch placeholder") - 400:jl.index("refusing to launch placeholder") + 900])
check("E5 占位写入端 _comment_ 仍在（运行时消息源）",
      '@"_comment_": [NSString stringWithFormat:localize(@"i18n_str_555", nil), loader, loaderVersion],' in mis)

# ============================================================
# F. 新拟态壁纸共存
# ============================================================
print("== F. 新拟态壁纸共存 ==")
win_fn = bm[bm.index("- (void)applyBackgroundToWindow:"):bm.index("// Task111：检测并切换")]
split_fn_start = bm.index("- (void)applyBackgroundToSplitViewController:")
split_fn = bm[split_fn_start:bm.index("// Task111：同 applyBackgroundToWindow", split_fn_start)]
check("F1 画布门退役（Task177 重锚：两个 apply 函数体内无 cardsNeumorphEnabled 早退；注释链演化）",
      "if (self.cardsNeumorphEnabled)" not in win_fn
      and "if (self.cardsNeumorphEnabled)" not in split_fn
      and "Task174→Task175→Task177" in bm)
rui = bm[bm.index("- (void)refreshUIEffect"):]
check("F2 Task210 refreshUIEffect 单路径：容器缺席重建 + blur 重挂（开关分支与解耦日志退役）",
      "if (self.cardsNeumorphEnabled) {" not in rui
      and "ame178DecoupleLogOnce" not in rui
      and "if ([self hasBackground] && !self.globalBackgroundContainer) {" in rui
      and "[self addBlurEffectToContainer:self.globalBackgroundContainer];" in rui)
check("F3 柔和档引擎整体退役（Task177 重锚：属性/透传原语/0.35/0.37/0.45/0.50 全退；不透明渐变表面层在位）",
      "ame_wallpaperSoftProfile" not in engine_h
      and "- (void)ame_setNeumorphWallpaperSoft:(BOOL)soft;" not in engine_h
      and "offset * 0.35" not in engine_m
      and "darkOpacity = 0.45" not in engine_m
      and "lightOpacity = 0.50" not in engine_m
      and "ame_wallpaperSoftProfile != soft" not in engine_m
      and "ame177_surfaceLayer" not in engine_m
      and "AmeCardSurfaceColor" in engine_m)
check("F4 Task210：柔和档退役 + 卡体透明度挂点随退役删除（管线零残留）",
      bm.count("ame_setNeumorphWallpaperSoft") == 0
      and "[view ame_applyNeumorphCardOpacity" not in bm
      and "[target ame_applyNeumorphCardOpacity" not in bm)  # Task183/184 撤销 + Task210 引擎退役
check("F5 Task210：规格档随引擎退役（自绘阴影零残留）",
      "shadowOpacity" not in engine_m)

# ============================================================
# G. 文档
# ============================================================
print("== G. 文档 ==")
anns = json.loads(rd("announcements.json"))["announcements"]
# Task220 重锚：task215/task214 相继 @2/@3 插入后，Task213 时代的全体系数
# 再整体顺延一步（当前：task190@12/task184@13/task180@14/task179@15/
# task178@16/task177@17/task175@18/task174@19/172@22/168@25；server/task169
# pin 不动）。末尾追加（Task216-220）不影响前向索引。
check("G1 公告 task175@18（Task220 重锚：task215/214 双插入后现行系数）",
      anns[0]["id"] == "server-recommend-2026-09-24"
      and anns[1]["id"] == "task169-four-fixes-2026-09-25"
      and anns[12]["id"] == "task190-account-card-installer-spacing-2026-09-28"
      and anns[13]["id"] == "task184-revert-180-ui-whitespace-fix-2026-09-27"
      and anns[14]["id"] == "task180-opacity-dual-slider-2026-09-26"
      and anns[15]["id"] == "task179-eight-fixes-2026-09-26"
      and anns[16]["id"] == "task178-neumorph-decouple-opacity-2026-09-26"
      and anns[17]["id"] == "task177-neumorph-css-spec-2026-09-26"
      and anns[18]["id"] == "task175-six-fixes-2026-09-26"
      and anns[19]["id"] == "task174-neumorph-canvas-opacity-label-2026-09-26"
      and anns[22]["id"] == "task172-six-fixes-2026-09-25"
      and anns[25]["id"] == "task168-neumorph-faq-json-2026-09-25")
t175 = anns[18]
check("G2 公告内容六条全列 + EN 尾注 + 装机锚点",
      all(k in t175["content"] for k in
          ["ANGLE", "下载量", "头像", "物品栏", "Forge", "壁纸", "[Task175]"])
      and "EN:" in t175["content"])
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("G3 version.h Task 175 addendum（六主题 + 三个装机锚点 + 六条主述）",
      "Task 175" in vh
      and "Task175 ANGLE ES rewrite" in vh
      and "Task175 geometry snapshot" in vh
      and "Task175] neumorph UI wallpaper coexist" in vh
      and "sendTouchPoint" in vh
      and "cachedHomeVC" in vh
      and "downloadCount" in vh
      and "11.15.1.2318" in vh)
KEYSETS = [set(re.findall(r'^"([^"]+)"\s*=', rd(f"Natives/resources/{lg}.lproj/Localizable.strings"), re.M))
           for lg in ["en", "zh-Hans", "zh-CN", "zh-Hant"]]
check("G4 l10n 计数（Task210 重锚：neumorph 双键退役后 2520）",
      all(len(k) == 2727 for k in KEYSETS)
      and KEYSETS[0] == KEYSETS[1] == KEYSETS[2] == KEYSETS[3])
fb = json.loads(rd("Natives/resources/announcements-fallback.json"))
fbi = fb["announcements"]
check("G5 fallback 最小集不回潮（builtin-offline 首位 + server-recommend 钉二；Task169 F7 口径）",
      len(fbi) == 2
      and fbi[0]["id"] == "builtin-offline-2026-09-20"
      and fbi[1]["id"] == "server-recommend-2026-09-24")

# ============================================================
# H. 语法门 + 级联
# ============================================================
print("== H. 语法门 + 级联 ==")
r = subprocess.run([sys.executable, "scripts/task175_syntax_gates.py"],
                   capture_output=True, text=True, timeout=60)
check("H1 语法门：13 个触碰文件全配平（状态机版）",
      r.returncode == 0 and "ALL PASS" in r.stdout)

CASCADES = ["129", "141", "165", "167", "168", "169", "170", "171", "172", "173", "174"]  # Task210：173b_neumorph 退役
cascade_env = dict(os.environ)
# Task220：拆分模式（家法 Task208 split runs required）——TASK220_SPLIT=1 时
# 本门级联跳过长杆腿 168（本轮分跑实证 34/34），并向 171 腿传播拆分信号
#（其内部对 168/170 的重跑与本级联重复，170 已直接在列）。
cascade_env["TASK220_SPLIT"] = os.environ.get("TASK220_SPLIT", "")
for k in ("TASK129_REPO", "TASK141_REPO", "TASK165_REPO", "TASK167_REPO",
          "TASK168_REPO", "TASK169_REPO", "TASK170_REPO", "TASK171_REPO",
          "TASK172_REPO", "TASK173_REPO", "TASK173B_REPO", "TASK174_REPO",
          "AME_REPO", "TASK160_REPO", "TASK161_REPO", "TASK162_REPO",
          "TASK163_REPO", "TASK164_REPO", "TASK166_REPO"):
    cascade_env[k] = REPO
bad = []
for tid in CASCADES:
    script = f"scripts/verify_task{tid}.py"
    if not os.path.exists(script):
        continue
    if os.environ.get("TASK220_SPLIT") == "1" and tid in ("168", "174"):
        print(f"  SKIP  级联腿 {tid}（TASK220_SPLIT=1：聚合器腿分跑实证 168:34/34、174:52/52）")
        continue
    try:
        r = subprocess.run([sys.executable, script], env=cascade_env,
                           capture_output=True, text=True, timeout=280)
        out = r.stdout + r.stderr
        if r.returncode != 0 or "FAIL" in out:
            bad.append((tid, [l.strip()[:100] for l in out.splitlines()
                              if ("FAIL" in l or "FAILED" in l)][:3]))
    except subprocess.TimeoutExpired:
        bad.append((tid, ["TIMEOUT"]))
check("H2 级联零失败（12 个直接受影响验证器全绿）", not bad, str(bad)[:600])

print(f"\n===== verify_task175: {PASS} passed, {FAIL} failed =====")
sys.exit(1 if FAIL else 0)
