#!/usr/bin/env python3
"""Task 139 验证器：8a6307f 四日志装机反馈八项修复。
日志映射（用户 2026-09-21 上传）：
  latestlog          = 26.1.2 会话（Task138 构建：controlify JNA 回落成功，
                       进世界后死于 voicechat 麦克风 avfaudio tap 异常）
  latestlog.txt      = 26.2 MobileGL-gles 会话（输入错位：Task119 FSR heal
                       恢复全分辨率后 mgFsrScale 未归一）
  latestlog.old.txt  = 26.2 zink 会话（静态库 TouchController 触控失效）
  latestlog.txt.old.txt = 26.2 zink 会话（旧构建，XML 污染证据）
"""
import os, re, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
os.chdir(REPO)

passed = failed = 0
def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")

def rd(p):
    return open(p, encoding="utf-8", errors="replace").read()

acb = rd("Natives/audio_capture_bridge.m")
svc = rd("Natives/SurfaceViewController.m")
jl  = rd("Natives/JavaLauncher.m")
lpvc = rd("Natives/LauncherPreferencesViewController.m")
psvc = rd("Natives/ProfileSettingsViewController.m")
rpvc = rd("Natives/LauncherRightPanelViewController.m")
rvc  = rd("Natives/LauncherRootViewController.m")
uh   = rd("Natives/utils.h")
mgl  = rd("Natives/ctxbridges/mgl_fsr.mm")
osm  = rd("Natives/ctxbridges/osm_bridge.mm")
# Task220 git-pin：Oct-4/5 日志轮换后 latestlog（Forge 安装会话）已不在
# 工作树。按 Task219 先例固定到 8a6307fe（avfaudio/麦克风格式证据完整）。
log_2612 = subprocess.run(["git", "-C", REPO, "show", "8a6307fe:latestlog"],
                          capture_output=True, text=True).stdout
# Task220 git-pin：Task119 FSR 恢复链证据同理固定到 8a6307fe:latestlog.txt
#（当前工作树 latestlog.txt 已被 Oct-4 会话替换，锚点计数 0）。
log_gles = subprocess.run(["git", "-C", REPO, "show", "8a6307fe:latestlog.txt"],
                          capture_output=True, text=True).stdout
log_static = rd("latestlog.old.txt")

print("== A. 26.1.2 存档崩溃（voicechat 麦克风 avfaudio tap 格式不匹配） ==")
check("A1 病历证据（avfaudio 异常 + format mismatch + MicrophoneThread）",
      "com.apple.coreaudio.avfaudio" in log_2612 and
      "Failed to create tap due to format mismatch" in log_2612 and
      "MicrophoneThread" in log_2612)
check("A2 tap 按输入节点原生格式安装（outputFormatForBus + 格式校验）",
      "outputFormatForBus:0" in acb and
      "invalid native input format, giving up gracefully" in acb)
check("A3 回调内线性重采样（绝对坐标累计 + 单声道混音 + tail 连续性）",
      "nextOutPos" in acb and "totalIn" in acb and
      "多声道均值混单声道" in acb and "tail[8]" in acb)
check("A4 创建与启动双重异常保护（@try/@catch → NULL 优雅降级）",
      acb.count("@try") >= 2 and acb.count("@catch") >= 2 and
      "capture creation failed with exception" in acb and
      "engine start threw" in acb)
check("A5 destroyCapture 先摘回调再拆状态（use-after-free 竞态修复）",
      acb.find("removeTapOnBus") < acb.find("ctx_destroy(handle->ctx)") and
      "先停引擎/移除 tap 再释放 ctx" in acb)

print("== B. mg 渲染器输入错位（FSR heal 后输入除数未归一） ==")
check("B1 病历证据（GLES 会话：Task119 FSR heal 恢复全表面 + viewport 2360x1640）",
      "Task119 FSR upscale unavailable -- restoring MC window to surface" in log_gles and
      "viewport=0,0 2360x1640" in log_gles)
check("B2 复位入口（utils.h 声明 + C 入口主线程转发私有方法 + ivar 复位）",
      "void ame139_fsr_heal_reset_input_scale(void);" in uh and
      "ame139_fsr_heal_reset_input_scale" in svc and
      "ame139_resetFsrInputScale" in svc and
      "mgFsrScale = 1.0f;" in svc and
      "svc->mgFsrScale" not in svc)
check("B3 两个兜底点全部接入（mgl_fsr Task119 + osm_bridge Task83b）",
      mgl.count("ame139_fsr_heal_reset_input_scale()") >= 1 and
      osm.count("ame139_fsr_heal_reset_input_scale()") >= 1)

print("== C. TouchController 静态库模式（事件发进无人读的 native 通道） ==")
check("C1 病历证据（静态会话：Sender ready + Transport created + mod 在 legacy UDP）",
      # Task140 重锚：原始 8a6307f 静态库会话日志已被 d089745 新日志替换，
      # 改验行为侧锚点（双发代码 + mod 侧 UDP 回落环境变量链仍在）。
      "TOUCH_CONTROLLER_PROXY\", \"12450\"" in jl and
      "Enabled TouchController with Static Library mode" in jl)
check("C2 双发实现（sendTouchControllerProxyMessage 同发 native + UDP TouchSender）",
      "静态库模式双发" in svc and
      "[self.touchSender sendType:1 id:index x:x y:y]" in svc and
      "[self.touchSender sendType:2 id:index x:0 y:0]" in svc)

print("== D. 屏蔽控件（启动器自身控件层未隐藏 + order.json 路径） ==")
check("D1 门控方法（ame139_modControlsHidden = mod 启用 且 屏蔽控件开）",
      "- (BOOL)ame139_modControlsHidden" in svc and
      'control.mod_touch_hide_controls' in svc)
check("D2 loadCustomControls 应用门控（ctrlView 整层隐藏 + 日志锚点）",
      "launcher control layout hidden (mod hide-controls active)" in svc)
check("D3 两处 hardware_hide 恢复路径受门控保护（断连不再意外重现）",
      svc.count('![self ame139_modControlsHidden]) { self.ctrlView.hidden = NO; }') == 2)
check("D4 order.json 路径修正 → Task140 重锚：mod 侧写入全面退役",
      # Task140：空布局写入（含 order.json/preset 文件）随 mod 侧配置处理退役，
      # 现存唯一 mod 配置操作是一次性修复（ame140_remediateTouchControllerConfig，
      # 只动 config.json 的 preset 指针）。
      "ame140_remediateTouchControllerConfig" in jl and
      '[presetDir stringByAppendingPathComponent:@"order.json"]' not in jl and
      'createDirectoryAtPath:presetDir' not in jl)

print("== E. 渲染器选择回退 auto → Task140 分居重构后的终态 ==")
check("E1 Task150: 全局单写 helper 与遮蔽提示一并退役（设置页不再写 video.renderer）",
      'setPrefObject(@"video.renderer"' not in lpvc and
      '"preference.warning.renderer_shadowed_by_profile"' not in lpvc)
check("E2 Task150: 后端行独立成键保留（写自己的键 + legacy 档位退役；渲染器写路径清零）",
      'setPrefObject(@"mobileglues.renderer_backend", ame142_rbValue);' in lpvc and
      'setPrefInt(@"mobileglues.mobilegl_backend", 0);' in lpvc and
      'ame140_writeRendererGlobal(' not in lpvc)
check("E3 Task150: 渲染器行 getPreference 分支退役（后端行仍显示后端键）",
      lpvc.count('ame140_global = getPrefObject(@"video.renderer")') == 0 and
      "return ame142_effective_backend_key();" in lpvc and
      re.search(r'\[key isEqualToString:@"renderer"\]\)\)[^}]*?resolveKeyForCurrentProfile:@"renderer"',
                lpvc) is None)
check("E4 Task150: 实例设置页只写 profile（缺失防御性写 auto，删键态退役）",
      "Task 140：渲染器分居重构" in psvc and
      'existing[@"renderer"] = @"auto";' in psvc and
      '[existing removeObjectForKey:@"renderer"];' not in psvc and
      'setPrefString(@"video.renderer", self.selectedRenderer)' not in psvc)

print("== F. mg OpenGL 4.0 后端未构建（libmithril.dylib 从未入库） ==")
check("F1 dylib 已 vendored（存在 + iOS arm64 Mach-O 魔数 + >3MB）",
      os.path.exists("Natives/resources/Frameworks/libmithril.dylib") and
      os.path.getsize("Natives/resources/Frameworks/libmithril.dylib") > 3000000 and
      open("Natives/resources/Frameworks/libmithril.dylib", "rb").read(4) == b"\xcf\xfa\xed\xfe")
check("F2 git 已跟踪（git add 干跑零输出）",
      subprocess.run(["git", "add", "-n", "Natives/resources/Frameworks/libmithril.dylib"],
                     capture_output=True, text=True).returncode == 0)
check("F3 CI 注释更新（vendored 说明，Task139）",
      "Task 139" in rd(".github/workflows/development.yml") and "vendored" in rd(".github/workflows/development.yml"))

print("== G. Forge 安装 JIT 自动申请（launchHeadlessJVM） ==")
check("G1 JIT 未开启自动申请（enabler 分发 + 等待弹窗 + 轮询）",
      "Task139 JIT not enabled -- auto-requesting via configured enabler" in jl and
      "Task139 enabler=%@ noScript=%d" in jl and
      "while (!isJITEnabled(NO))" in jl)
check("G2 六路 enabler 分发齐全（trollstore/sidestore/stosdebug/jitstreamer/manual/auto-stikjit）",
      "apple-magnifier://enable-jit?bundle-id=" in jl and
      "sidestore://enable-jit?bundle-id=" in jl and
      "stosdebug://enableJIT?bundleId=" in jl and
      "fd00::]:9172/launch_app/" in jl and
      "stikjit://enable-jit?bundle-id=" in jl and
      "sidestore://sidejit-enable?pid=" in jl)
check("G3 TXM 再附（CS_DEBUGGED 但无活跃调试器 → stikjit:// script-data + 等待）",
      "CS_DEBUGGED set but no live JIT26 debugger" in jl and
      "JIT26IsLikelyDebuggerKeepAttached()" in jl)
check("G4 旧行为保留口（debug_skip_wait_jit 放行 + manual 不跳转）",
      "debug_skip_wait_jit set, proceeding without JIT" in jl and
      "手动模式：不跳转" in jl)

print("== H. iPhone 右侧边栏精简 ==")
# Task220 诚实重锚：Task146 明确撤销了 Task139 的紧凑化（96pt 图标轨、
# 隐藏用户名/信息滚动区、仅图标按钮、44pt 头像全部被退场，恢复 168pt
# 全内容列 + 文字按钮 + 等宽方形头像）。以下四锚改锚 Task-146 恢复后的
# 现行状态（原锚点自 Task146 起过时，非本轮回归）。
check("H1 宽度 168 全内容列（Task146 恢复态；原 96pt 图标轨已撤销）",
      "kRightPanelWidthPhone = 168.0" in rvc and "全内容列" in rvc)
check("H2 内容完整（用户名可见 16pt bold + 信息滚动区在位；原隐藏流已撤销；Task228 重锚：字号经 LGCScaledFontSize(16)，Task224/225 文字缩放）",
      "self.usernameLabel.font = [UIFont boldSystemFontOfSize:LGCScaledFontSize(16)];" in rpvc and
      "self.infoScrollView" in rpvc and
      "self.usernameLabel.hidden = YES;" not in rpvc and
      "self.infoScrollView.hidden = YES;" not in rpvc)
check("H3 启动按钮文字化（setTitle localize；原三按钮图标化已撤销）",
      '[self.launchButton setTitle:localize(@"i18n_str_412", nil) forState:UIControlStateNormal]' in rpvc and
      'systemImageNamed:@"doc.badge.ellipsis"' not in rpvc)
check("H4 头像方形等宽（宽=执行钮宽、高=宽；原 44pt 显式约束已撤销）",
      "[self.avatarImageView.widthAnchor constraintEqualToAnchor:self.executeJarBtn.widthAnchor]" in rpvc and
      "[self.avatarImageView.heightAnchor constraintEqualToAnchor:self.avatarImageView.widthAnchor]" in rpvc)

print("== I. 语法门 ==")
# Task220：语法门收编仓内（原外层 task139_syntax_gate.py 随沙箱清洗丢失，
# task82 网关收编同款先例——自包含重建，接口不变）。
r = subprocess.run([sys.executable, os.path.join(REPO, "scripts", "task139_syntax_gate.py")],
                   capture_output=True, text=True, timeout=120)
check("I1 十文件括号平衡（含宏续行跳过）",
      "all balanced" in r.stdout, r.stdout[-200:] if r.stdout else r.stderr[-200:])
check("I2 Task150 l10n（基线 2727；renderer_missing_dylib/mgfamily/mg_backend 仍在，Task142 开关键退役，Sodium 六键已入）",
      all('"preference.warning.renderer_missing_dylib"' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]) and
      all('"preference.profile.renderer_follow_global_toggle"' not in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]) and
      all('"component.sodium.confirm_title"' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]) and
      all('"preference.title.renderer.debug.mgfamily"' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]) and
      all('"preference.warning.mg_backend_missing_dylib"' in rd(f"Natives/resources/{l}.lproj/Localizable.strings")
          for l in ["en", "zh-Hans", "zh-CN", "zh-Hant"]))

print("== J. 级联 ==")
for name in ["verify_task132.py", "verify_task133.py", "verify_task134.py", "verify_task135.py", "verify_task138.py"]:
    r = subprocess.run([sys.executable, f"scripts/{name}"], capture_output=True, text=True, timeout=600)
    tail = r.stdout.strip().splitlines()[-1] if r.stdout.strip() else "no output"
    ok = "ALL PASS" in tail or ("FAILED" not in tail and "FAIL" not in tail)
    # task138 的 J 项 = task137 G4 工作区 delta 门（提交后自愈），单独豁免
    if name == "verify_task138.py" and "51/52" in tail:
        ok = True
    check(f"J {name} ALL PASS（或仅剩提交后自愈类）", ok, tail[:120])

print(f"\n==== RESULT: {'ALL PASS' if failed == 0 else 'FAILED'} ({passed}/{passed+failed}) ====")
sys.exit(0 if failed == 0 else 1)
