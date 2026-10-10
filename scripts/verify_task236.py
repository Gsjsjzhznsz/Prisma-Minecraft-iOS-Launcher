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
check("A8", "多行缩字镜像（numberOfLines > 1 分支）",
      "ame232_label.numberOfLines > 1 && ame235_scaledFont == nil" in bgm)
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

print("== C. 菜单面板防御性底色 ==")
check("C1", "玻璃之下重铺半透明深色实底（0.72）",
      'green:28.0/255.0 blue:30.0/255.0 alpha:0.72];' in svn)
check("C2", "面板加固日志", "[GameMenu] Task236 menu panel hardened" in svn)
check("C3", "原生风格底色恢复（玻璃→原生切换隐性雷）",
      "} else {\n        // ★ Task236：切回原生风格时底色一并恢复" in svn)
check("C4", "Task229/230/232 玻璃链保留（锚不回归）",
      "LGCApplyGlassToView(self.menuView, 16.0)" in svn and
      "UIBlurEffectStyleSystemMaterialDark" in svn and
      "ame232_sub.tag == 888903" in svn)

print("== D. 前置条目模组列表化 + 直跳 ==")
check("D1", "富条目渲染 + 日志", "[ModVersionVC] Task236 dependency rich footer:" in mvv)
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

print("== E. 弹窗液态玻璃 v2（present-hook 必定安装）==")
check("E1", "present-hook 安装块（基类自有选择器）",
      "Task236 alert glass present-hook installed" in ukh)
check("E2", "钩子先调原实现", "[self ame236_hook_presentViewController:viewControllerToPresent animated:flag completion:completion];" in ukh)
check("E3", "只对 UIAlertController + 玻璃风格激活", 
      "if (![viewControllerToPresent isKindOfClass:[UIAlertController class]]) return;" in ukh)
check("E4", "双延时补玻璃（0s + 0.45s）", "(int64_t)(0.45 * NSEC_PER_SEC)" in ukh)
check("E5", "自适应材质（SystemMaterial 非 Dark）",
      "UIBlurEffectStyleSystemMaterial]" in ukh)
check("E6", "防御性半透明底（systemBackground 55%）",
      "[[UIColor systemBackgroundColor]\n            colorWithAlphaComponent:0.55];" in ukh)
check("E7", "文字自适应（labelColor）", "setTextColor:[UIColor labelColor]];" in ukh)
check("E8", "v2 应用日志", "[ThemeOps] Task236 alert glass v2 (#%d style=%ld ok=%d; present-hook double-shot, adaptive material+base)" in ukh)
check("E9", "viewWillAppear 钩子保留（Task235 首层）", "ame235_hook_viewWillAppear:(BOOL)animated" in ukh)

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
