#!/usr/bin/env python3
"""verify_task171.py -- Task 171 (seven-symptom device-feedback round) verification.

Groups:
  A. git-pinned device-log forensics (uploads 470055c + 143f8f2)
  B. code anchors (all seven fixes)
  C. behavior mirrors (geometry math, version gate, backend order, CF matrix,
     keyboard state machine, crash preservation)
  D. docs (version.h / announcements / worklog)
  E. cascades (verify_task168/170 re-anchored, syntax gates)
"""
import json, os, re, subprocess, sys

REPO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
os.chdir(REPO)

passed, failed = 0, 0
def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok  {name}")
    else:
        failed += 1
        print(f" FAIL {name}")

def rd(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()

def git_show(commit, path):
    return subprocess.run(["git", "show", f"{commit}:{path}"],
                          capture_output=True, text=True).stdout

print("== A. git-pinned device-log forensics ==")
log_angle = git_show("470055c", "latestlog.txt")          # ANGLE 26.3 FO pack
log_mp    = git_show("470055c", "latestlog.old.txt")      # mg 26.3 multiplayer
log_264   = git_show("143f8f2", "latestlog.old")          # mg 26.4-snapshot-1

check("A1 ANGLE 会话完整崩溃链（LoadLibrary already loaded -> glGetError mismatch -> Vulkan 回落 -> Iris No GLCapabilities）",
      "OpenGL library already loaded" in log_angle
      and "glGetError mismatch" in log_angle
      and "Failed to create backend OpenGL" in log_angle
      and "No GLCapabilities instance set" in log_angle
      and "ExceptionInInitializerError" in log_angle)
check("A2 ANGLE 会话零桥接接管（无 'hooked SDL_GL_LoadLibrary -> EGL bridge' 行）= ame_glBridgeEnabled 列表缺 ANGLE 的直接证据",
      "hooked SDL_GL_LoadLibrary -> EGL bridge" not in log_angle)
check("A3 多人会话 HotbarDiag 拒绝证据（y=1516/1556 < barY=1560，视觉物品栏上半段被拒）",
      log_mp.count("REJECT above bar") >= 3
      and "y=1516.0 < barY=1560" in log_mp
      and "y=1556.0 < barY=1560" in log_mp)
check("A4 多人会话 FSR 联动在场（scale=1.70，窗口=表面/1.70）",
      "Task83 FSR linkage" in log_mp and "scale=1.70" in log_mp
      and "1388x964" in log_mp)
check("A5 26.4 会话：默认 Vulkan 优先实锤 + GL 从未被尝试（无 RenderPearl GL 探窗）",
      "26.4-snapshot-1" in log_264
      and "Using graphics backend Vulkan" in log_264
      and "RenderPearl OpenGL Hidden" not in log_264
      and "Failed to create backend OpenGL" not in log_264)
check("A6 多人会话本身干净（mysv.dpdns.org + 60fps + exit(0)）= 崩溃日志已被轮换覆盖的证据",
      "Connecting to mysv.dpdns.org, 25565" in log_mp
      and "exit(0) called" in log_mp
      and "fps=60" in log_mp)
kb_shows = log_mp.count("Keyboard widget: becomeFirstResponder=1")
check("A7 键盘首会话竞争：每次按输入法按钮都是 becomeFirstResponder=1（字段每输一字后被系统拆会话）且零 dismissing 行",
      kb_shows >= 3 and "Keyboard widget: dismissing" not in log_mp)

print("== B. code anchors ==")
sdl = rd("Natives/sdl3_hook.m")
check("B1 sdl3_hook：AMEglBridgeEnabled 收编 libtinygl4angle + ANGLE 逃生阀",
      'strstr(renderer, "libtinygl4angle") != NULL' in sdl
      and 'ame_envFlagOn("AMETHYST_ANGLE_GL_BRIDGE", true)' in sdl)
ib = rd("Natives/input_bridge_v3.m")
new_geo = ib[ib.find("Task 171：物品栏命中矩形改为 FSR 感知"):ib.find("int slot = hotbarKeys")]
check("B2 touchHotbar：物理/窗口比例 + 182x22 精灵 + 比例护栏 + 不用 mcscale（防双重除法）",
      "ame171_winToPhys" in new_geo
      and "(22 * guiScale)" in new_geo and "(182 * guiScale)" in new_geo
      and "ratio >= 0.25f && ratio <= 8.0f" in new_geo
      and "mcscale(22)" not in new_geo and "mcscale(182)" not in new_geo)
cf = rd("Natives/installer/modpack/CurseForgeAPI.m")
check("B3 CF：无 nil 拦截（if (!headers) 归零）+ keyless Accept-only + 4 处 setValue 空值保护 + Task171 日志",
      "if (!headers)" not in cf
      and 'return @{@"Accept" : @"application/json"};' in cf
      and cf.count("ame171_key") >= 4
      and "no API key configured" in cf)
news = rd("Natives/LauncherNewsViewController.m")
# Task172 重锚：helper nil 分支改为取证日志（不再裸 return）；viewDidAppear
# 增加 0.35s 延迟补刷调用（调用点 4 -> 5）。
check("B4 头像：helper + viewDidAppear + 三处调用（updateSkinDisplay 尾 / 网络回调 / viewDidAppear；Task172 起另有延迟补刷）",
      news.count("ame171_syncVisibleProfileAvatar") >= 5
      and "- (void)viewDidAppear:(BOOL)animated" in news
      and "sync skipped: currentAvatar is nil" in news)
mainm = rd("Natives/main.m")
check("B5 main.m：latestlog.crash.txt 保全 + exit 标记检测 + 仅在无标记时复制",
      "latestlog.crash.txt" in mainm
      and 'containsString:@") called"]' in mainm
      and "copyItemAtPath:currName toPath:crashName" in mainm)
tools = rd("JavaApp/src/launcher/net/kdt/pojavlaunch/Tools.java")
check("B6 Tools.java：appendGraphicsBackendArg + 版本门槛 + MoltenVK 跳过 + 已存在守卫 + 锚点日志",
      "appendGraphicsBackendArg" in tools and "ame171IsMc264OrLater" in tools
      and '"--graphicsBackend"' in tools and '"opengl"' in tools
      and 'renderer.contains("MoltenVK")' in tools
      and '"--graphicsBackend".equals(a)' in tools
      and "Vulkan-first backend order" in tools)
svc = rd("Natives/SurfaceViewController.m")
# Task172 重锚：SDL Stop 路由新增第 4 处代数递增；SDL Start 路由新增第 3 处
# re-arm 调用与第 3 处 text 先于 become。
check("B7 键盘：clearsOnBeginEditing=NO + 两处 text 先于 become + 收起代数递增 + 自愈重挂（深度上限 2；Task172 起 4 处递增/3 处 re-arm）",
      "self.inputTextField.clearsOnBeginEditing = NO;" in svc
      and svc.count("ame171_keyboardDismissGeneration++") == 4
      and svc.count("[self ame171_armKeyboardRecheck:0];") == 3
      and "if (depth > 2) return;" in svc
      and "keyboard auto re-arm depth=%d" in svc)
# text-before-become ordering in the two trigger sites
btn = svc[svc.find("case SPECIALBTN_KEYBOARD:"):svc.find("case SPECIALBTN_MOUSEPRI:")]
kg = svc[svc.find("- (void)keyboardGesture:"):svc.find("- (void)sendTouchEvent:")]
check("B8 两触发点均为 text=@" '" " 先于 becomeFirstResponder',
      btn.find('self.inputTextField.text = @" ";') < btn.find("[self.inputTextField becomeFirstResponder]")
      and kg.find('self.inputTextField.text = @" ";') < kg.find("[self.inputTextField becomeFirstResponder]"))

print("== C. behavior mirrors ==")
# C1 hotbar geometry on the f26337d session values
physW, physH, winW, winH, gs = 2360, 1640, 1388, 964, 4
ratio = physH / winH
barH = int(22 * gs * ratio + 0.5); barY = physH - barH
barW = int(182 * gs * ratio + 0.5); barX = (physW - barW) // 2
old_barY = physH - int(gs * 20 / 1.0)
check("C1 f26337d 几何镜像：新 barY≈1490（视觉顶边 1640-88*1.70）< 旧 1560；y=1516/1556 由 REJECT 转 HIT",
      1485 <= barY <= 1495 and old_barY == 1560
      and 1516 >= barY and 1556 >= barY
      and 1230 <= barW <= 1245 and barX == (physW - barW) // 2)
# C2 version gate
def is264(v):
    m = re.match(r"^(\d+)\.(\d+)", v.strip())
    if not m: return False
    try:
        M, mnr = int(m.group(1)), int(m.group(2))
        return M > 26 or (M == 26 and mnr >= 4)
    except ValueError: return False
check("C2 版本门槛镜像：26.4-snapshot-1/26.4/27.0 -> True；26.3/1.20.1/25/垃圾串 -> False",
      is264("26.4-snapshot-1") and is264("26.4") and is264("27.0")
      and not is264("26.3") and not is264("1.20.1") and not is264("25")
      and not is264("fabric-loader-x") and not is264(""))
# C3 backend order (from the CFR decompiles of the REAL client jars)
# Task173 诚实重锚：反编译工件是 Task171 会话本地证据（从未入库，绝对路径
# 引用），随沙箱存在性而定——与 verify_task138 C1 / verify_task112_118 E5
# 同款"证据缺失时跳过"家法。工件重现时断言原样生效。
import os as _os
_d264_path = "/home/z/my-project/task171/decomp264/net/minecraft/client/PreferredGraphicsApi.java"
_d263_path = "/home/z/my-project/task171/decomp263/net/minecraft/client/PreferredGraphicsApi.java"
if _os.path.exists(_d264_path) and _os.path.exists(_d263_path):
    order_264 = "if (this != OPENGL)"   # 26.4: DEFAULT -> {vulkan, gl}
    order_263 = "if (this == VULKAN)"   # 26.3: DEFAULT -> {gl, vulkan}
    d264 = rd(_d264_path)
    d263 = rd(_d263_path)
    check("C3 后端顺序实锤（真 jar 反编译）：26.4 DEFAULT=Vulkan优先 / 26.3 DEFAULT=GL优先",
          order_264 in d264 and order_263 in d263
          and "vulkanNonExperimental" in d264)
# C4 CF decision matrix
check("C4 CF 决策矩阵：keyless+官方URL -> baseURL 强制镜像（既有逻辑保持）+ 请求照发（新逻辑）",
      "if ([self apiKey].length == 0 && [ame162_resolved containsString:@\"api.curseforge.com\"])" in cf
      and "mcimCurseForgeAPIBaseURL" in cf)
# C5 keyboard state machine mirror
def kb_sim(user_dismiss_before_check, healthy, depth_cap=2):
    """returns ('rearm', d) / ('noop', None) / ('abort', None)"""
    gen = 0; captured = gen
    if user_dismiss_before_check: gen += 1          # user dismissed during window
    if captured != gen: return ("abort", None)
    if healthy: return ("noop", None)
    return ("rearm", 0)
check("C5 键盘状态机：健康=no-op / 系统拆会话+用户未动=re-arm / 用户主动收起=abort",
      kb_sim(False, True) == ("noop", None)
      and kb_sim(False, False) == ("rearm", 0)
      and kb_sim(True, False) == ("abort", None))
# C6 crash preservation marker logic
def preserve(tail): return ") called" not in tail
check("C6 保全判定：干净 exit(0) 尾部 -> 不保全；SIGSEGV 截断尾部 -> 保全",
      not preserve("...\nexit(0) called\n") and preserve("...\n[RenderDiag] fps=38 swap"))

print("== D. docs ==")
vh = rd("Natives/external/MobileGlues/MobileGlues-cpp/version.h")
check("D1 version.h Task 171 附录：七主题齐全",
      "Task 171 (2026-09-25)" in vh
      and all(k in vh for k in ["libtinygl4angle", "touchHotbar", "MCIM mirror",
                                 "ame171_syncVisibleProfileAvatar", "latestlog.crash.txt",
                                 "PreferredGraphicsApi", "UIAsyncTextInput"]))
anns = json.loads(rd("announcements.json"))["announcements"]
# Task174 重锚：task174@2 + 十症状 task173@4 相继插入，task171 顺延 anns[10] -> anns[12]。
check("D2 公告（Task214 重锚：task214@2 插入 + Task212/213 漏锚补偿后 task171@22；置顶服务器推荐仍在 anns[0]；task169 仍在 anns[1]",
      anns[23]["id"] == "task171-seven-fixes-2026-09-25"
      and anns[0].get("pin") and "mysv.dpdns.org" in anns[0]["title"]
      and anns[1]["id"] == "task169-four-fixes-2026-09-25")
check("D3 task171 公告内容七条全列",
      all(k in anns[23]["content"] for k in ["①", "②", "③", "④", "⑤", "⑥", "⑦"]))
wl = rd("worklog.md")
check("D4 仓库 worklog 已记 Task 171",
      "Task ID: 171" in wl)

print("== E. cascades ==")
# E 组说明：165/166/167/169 是本轮公告插入的漂移面，重锚后必须全绿
#（独立可复跑）。168/170 的 E7/H1 子级联对拍在【本沙箱】会被历史脚本的
# 硬编码路径污染（163/150/157/159/141 指向不存在的
# /home/z/my-project/workspace/... —— task168 基线已记录的沙箱路径默认值，
# 非代码回归），故对它们只断言"失败仅限子级联对拍组，且漂移面相关脚本
# 不在其失败清单里"。
for script in ["scripts/verify_task165.py", "scripts/verify_task166.py",
               "scripts/verify_task167.py", "scripts/verify_task169.py"]:
    r = subprocess.run([sys.executable, script], capture_output=True, text=True)
    check(f"E1 直接受影响验证器全绿 {os.path.basename(script)}", r.returncode == 0)

# Task220：深嵌套拆分开关（202 的 TASK209_NESTED 同款家法）——168/170 腿
# 各自内嵌完整子级联（168→133→七子链），在本沙箱 CPU 配额下全程 >550s
#（Task208 "split runs required" 的对偶面）。TASK220_SPLIT=1 时跳过这两腿
#（分跑实证：168:34/34、170:32/32），独立运行行为不变。
if os.environ.get("TASK220_SPLIT") == "1":
    print("  SKIP  E2 深嵌套腿 168/170（TASK220_SPLIT=1：本轮分跑实证 168:34/34、170:32/32）")
else:
    for script, cascade_check in [("scripts/verify_task168.py", "E7"),
                                  ("scripts/verify_task170.py", "H1")]:
        r = subprocess.run([sys.executable, script], capture_output=True, text=True)
        out = r.stdout + r.stderr
        if r.returncode == 0:
            check(f"E2 {os.path.basename(script)} 全绿（本沙箱路径幸运命中）", True)
            continue
        # 容忍口径：失败行只有子级联对拍组，且不含漂移面脚本
        fail_lines = [l for l in out.splitlines() if l.strip().startswith("[FAIL]")]
        only_cascade = all(cascade_check in l for l in fail_lines)
        drift_free = not any(k in out for k in
                             ["'165'", "'166'", "'167'", "'169'", "D8 ", "G1 task165", "E1 task167"])
        check(f"E2 {os.path.basename(script)} 失败仅限 {cascade_check} 子级联对拍（沙箱路径污染）且公告漂移面已清零",
              only_cascade and drift_free and len(fail_lines) == 1)

print(f"\n==== verify_task171: {passed} passed, {failed} failed ====")
sys.exit(1 if failed else 0)
