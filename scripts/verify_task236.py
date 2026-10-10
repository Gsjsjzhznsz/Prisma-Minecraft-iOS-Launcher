#!/usr/bin/env python3
# verify_task236: Task236 六项修复的代码锚点验证
#   (1) 字体重叠第七轮：VersionCardCell 垂直超定根修（行高 64→72）+ 描边交换多行缩字镜像
#   (2) 游戏内悬浮栏（齿轮/统计/菜单标签）防御性可见性
#   (3) 游戏内菜单面板防御性底色 + 原生风格底色恢复
#   (4) 前置条目模组列表化（图标+介绍内联）+ 点击直跳下载页 + 自委托下载
#   (5) 弹窗液态玻璃 v2（present-hook 必定安装 + 自适应配方 + 防御性半透明底）
#   (6) i18n +ame236.deps.hint x5
import os, re, subprocess, sys

BASE = "/home/z/my-project/Amethyst-iOS-MyRemastered"

def rd(p):
    with open(os.path.join(BASE, p), encoding="utf-8") as f:
        return f.read()

n_ok = n_fail = 0
def check(cid, desc, ok):
    global n_ok, n_fail
    if ok:
        n_ok += 1
        print(f"  ok   {cid} {desc}")
    else:
        n_fail += 1
        print(f"  FAIL {cid} {desc}")

def check_absent(cid, desc, text, bad):
    check(cid, desc + " [absent]", bad not in text)

dlv = rd("Natives/DownloadViewController.m")
vcc = rd("Natives/VersionCardCell.m")
bgm = rd("Natives/BackgroundManager.m")
gmv = rd("Natives/GameMenuOverlayView.m")
svn = rd("Natives/SurfaceViewController+Navigation.m")
mvv = rd("Natives/ModVersionViewController.m")
ukh = rd("Natives/UIKit+hook.m")

print("== A. 字体重叠第七轮（垂直超定根修 + 多行缩字镜像）==")
check("A1", "版本列表行高 64→72（初始 itemSize）", "CGSizeMake(360, 72)" in dlv)
check("A2", "版本列表行高 64→72（动态宽度路径）", "CGSizeMake(availableWidth, 72)" in dlv)
check("A3", "根因注释（垂直内容链超定 ~6.3pt）", "超定 ~6.3pt" in dlv)
check("A4", "顶行上距 14→13", "self.cardContainer.topAnchor constant:13" in vcc)
check("A5", "日期间距 3→2", "self.topRowStack.bottomAnchor constant:2" in vcc)
check("A6", "日期底距 12→10", "self.cardContainer.bottomAnchor constant:-10" in vcc)
check("A7", "旧 64 行高退役", "CGSizeMake(availableWidth, 64)" not in dlv and "CGSizeMake(360, 64)" not in dlv)
check("A8", "多行缩字镜像（Task239：!= 1 分支，==0 不限行标签纳入）",
      "ame232_label.numberOfLines != 1 && ame235_scaledFont == nil" in bgm)
check("A9", "二分搜索 12 次迭代", "ame236_i < 12; ame236_i++" in bgm)
check("A10", "多行拷贝词换行（TruncatingTail 单行陷阱修复）",
      "ame233_ps.lineBreakMode = NSLineBreakByWordWrapping;" in bgm)
check("A11", "多行注释（换行几何错位根因）", "只画【单行截断】不换行" in bgm)
check("A12", "单行缩字镜像逐字节保留（Task235 锚不回归）",
      "ame232_label.numberOfLines == 1 && rect.size.width > 0.5" in bgm and
      "ame235_natural" in bgm)
check("A13", "测量块无自引用（Task231 雷类）", "__block CGFloat (^ame236_wrappedHeight)" not in bgm)

print("== B. 悬浮栏防御性可见性（齿轮消失/什么都不显示）==")
check("B1", "齿轮玻璃后重铺半透明深色底（alpha 0.55）",
      "blue:0.1 alpha:0.55];" in gmv)
check("B2", "玻璃圆角跟随当前形态（docked 13 / 浮态 22）",
      "self.menuButton.layer.cornerRadius > 0.5" in gmv)
check("B3", "标签不再入磨砂层（文字被盖 = 什么都不显示）",
      "LGCApplyGlassToView(self.statsLabel" not in gmv and
      "LGCApplyGlassToView(self.ame230_captionLabel" not in gmv)
check("B4", "标签改实底胶囊 + 发丝描边 0.75pt",
      "self.statsLabel.layer.borderWidth = 0.75;" in gmv and
      "self.ame230_captionLabel.layer.borderWidth = 0.75;" in gmv and
      "colorWithWhite:1.0 alpha:0.32].CGColor" in gmv)
check("B5", "把手/悬浮形态切换后玻璃重铺（动画完成回调）",
      "completion:^(BOOL finished) {\n            // ★ Task236：形态切换后玻璃层圆角/尺寸跟随新几何（把手 13 / 球 22）\n            [self ame232_applyFloatingGlass];" in gmv)
check("B6", "非动画路径同样重铺", "ame227_apply();\n        // ★ Task236：同上，非动画路径立即重铺（恢复把手态时圆角已变）。" in gmv)
check("B7", "取证日志（帧/圆角/子视图构成）", "[GameMenu] Task236 floating bar hardened" in gmv)
check("B8", "非玻璃风格还原（清描边）",
      "self.statsLabel.layer.borderWidth = 0;" in gmv and
      "self.ame230_captionLabel.layer.borderWidth = 0;" in gmv)
check("B9", "SystemMaterialDark 升级保留（Task230 锚）",
      "UIBlurEffectStyleSystemMaterialDark" in gmv)
check("B10", "方法头根因注释（磨砂层覆盖标签文字）", "盖在标签自己的文字上" in gmv)

print("== C. 菜单面板防御性底色（Task237 重锚：面板彻底重写为自控分层自定义 UIView）==")
# Task237（用户：“游戏内菜单打开还是就液态玻璃的覆盖层，根本没有任何文字”）：
# UITableView + 塞玻璃层方案整体退役，同一关切（面板可见 + 文字恒在）由
# 自控分层构造性保证。
check("C1", "防御性深色实底（Task239：原生玻璃 0.50 通透档 / 材质回退 0.62 厚底，永不被 LGC 清空）",
      "alpha:LGCNativeGlassEngaged() ? 0.50 : 0.62]" in svn and "LGCApplyGlassToView(self.menuView" not in svn)
check("C2", "面板重写日志（玻璃/原生两分支）", "[GameMenu] Task237 glass panel applied" in svn and
      "[GameMenu] Task237 native panel applied" in svn)
check("C3", "原生风格旧版 FCL 外观恢复（纯文本行）", "showsIcon = NO" in svn and
      "legacy FCL look" in svn)
check("C4", "分层构造（磨砂 index 0 + 行区恒在其上 + 开菜取证）",
      "insertSubview:ame237_blur atIndex:0]" in svn and
      "[GameMenu] Task237 menu shown" in svn)

print("== D. 前置条目模组列表化 + 直跳 ==")
# Task238 诚实重锚：前置区上移到头部堆叠（用户："摆在最上面合理的地方"），
# 渲染日志升级为 Task238 pinned above version list；富条目/直跳/iⓘ 行为不变。
check("D1", "富条目渲染 + 日志", "[ModVersionVC] Task238 dependency section pinned above version list:" in mvv)
check("D2", "数据抓取（图标 + 介绍一步到位）", "ame236_buildDependencyFooterWithItems:" in mvv)
check("D3", "行构造（44pt 图标 + 标题 + 介绍 + ⓘ）", "ame236_dependencyRow:(NSDictionary *)row" in mvv and
      'constraintEqualToConstant:44' in mvv and 'systemImageNamed:@"info.circle"' in mvv)
check("D4", "整行点按直跳（自委托）", "ame236_openDependencyDownload:(UIButton *)sender" in mvv and
      "ame236_vc.delegate = self;" in mvv)
check("D5", "自委托实现（下载到当前实例）",
      "- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {" in mvv and
      "[[ModService sharedService] downloadMod:ame236_dl" in mvv)
check("D6", "类扩展声明委托协议", "<UITableViewDataSource, UITableViewDelegate, ModVersionViewControllerDelegate>" in mvv)
check("D7", "ⓘ 保留详情页入口（关联对象复用）",
      'objc_setAssociatedObject(ame236_info, "ame230.dep.pid"' in mvv)
check("D8", "偏好版本/加载器透传", "ame236_vc.preferredGameVersion = self.preferredGameVersion;" in mvv)
check("D9", "直跳日志", "[ModVersionVC] Task236 dependency row direct-jump" in mvv)
check("D10", "头部提示（ame236.deps.hint）", 'localize(@"ame236.deps.hint", nil)' in mvv)
check_absent("D11", "旧纯文字按钮形态退役", mvv, '"▸  %@ (%@)"')

print("== E. 弹窗液态玻璃 v2（Task237 重锚：present-hook 魔改拆除 → 中央路由整体替换）==")
fm2 = rd("Natives/AmeFloatingMenu.m")
check("E1", "Task237 路由安装（基类自有选择器，接替 Task236 hook）",
      "[AmeMenu] Task237 floating-menu router installed" in ukh)
check("E2", "路由先判后透传（原生直通零魔改）",
      "[self ame237_hook_presentViewController:viewControllerToPresent animated:flag completion:completion];" in fm2)
check("E3", "只对 UIAlertController + 玻璃风格激活",
      "isKindOfClass:[UIAlertController class]] && LGCIsGlassStyleActive()" in fm2)
check("E4", "魔改双钩子整体退役（无延时补玻璃残留）", "ame235_" not in ukh and "ame236_" not in ukh and
      "0.45 * NSEC_PER_SEC" not in ukh)
check("E5", "自适应材质（SystemMaterial）",
      "UIBlurEffectStyleSystemMaterial]" in fm2)
check("E6", "防御性明暗实底（Ame237PanelBase）",
      "static UIColor *Ame237PanelBase(void)" in fm2)
check("E7", "文字自适应（labelColor）", "[UIColor labelColor]" in fm2)
check("E8", "替换日志（限流）", "[AmeMenu] Task237 glass menu replaced native alert" in fm2)
check("E9", "行控件公开共用（头文件 Ame237MenuRow）", "Ame237MenuRow" in rd("Natives/AmeFloatingMenu.h"))

print("== F. i18n（+ame236.deps.hint x5，基线 2766→2767）==")
langs4 = ["en", "zh-CN", "zh-Hans", "zh-Hant"]
for l in langs4 + ["ja"]:
    s = rd(f"Natives/resources/{l}.lproj/Localizable.strings")
    check(f"F-{l}", "ame236.deps.hint 已定义", '"ame236.deps.hint"' in s)
for l in langs4:
    s = rd(f"Natives/resources/{l}.lproj/Localizable.strings")
    keys = set(re.findall(r'^"([^"]+)" =', s, re.M))
    check(f"F-cnt-{l}", "唯一键数 2767", len(keys) == 2767)

print("== G. 级联（同文件/同链回归）==")
casc = ["verify_task229.py", "verify_task230.py", "verify_task232.py", "verify_task233.py",
        "verify_task234.py", "verify_task235.py"]
for v in casc:
    r = subprocess.run([sys.executable, os.path.join(BASE, "scripts", v)],
                       capture_output=True, text=True, timeout=300)
    tail = (r.stdout + r.stderr).strip().splitlines()
    verdict = tail[-1] if tail else "(no output)"
    check(f"G-{v}", f"exit={r.returncode} ({verdict[:60]})", r.returncode == 0)

print("========================================")
print(f"verify_task236: {n_ok} passed, {n_fail} failed")
sys.exit(1 if n_fail else 0)
