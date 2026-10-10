#!/usr/bin/env python3
# verify_task237: Task237 悬浮菜单体系彻底重写的代码锚点验证
#   用户指令原文：“帮我彻底重写所有悬浮菜单样式。不要使用原生
#   UIAlertController 加魔改，也不要出现原生与液态玻璃混杂。根据设置中的
#   界面风格适配：当界面风格为液态玻璃时，显示真正的液态玻璃悬浮菜单，
#   使用 UIVisualEffectView 实现毛玻璃半透明背景、圆角、菜单项带图标、
#   整体悬浮于界面上，而不是系统 ActionSheet 分块列表。当界面风格为原生
#   时，显示旧版本的原生悬浮弹窗。请覆盖账号设置等所有类似弹窗，统一成
#   对应风格的自定义组件。还有现在游戏内菜单打开还是就液态玻璃的覆盖层，
#   根本没有任何文字，要是不贴边，就只会给我全部屏幕覆盖层灰色。”
#
#   实现架构：
#   (1) AmeFloatingMenu.h/m —— 全自定义液态玻璃悬浮菜单组件（毛玻璃/圆角/
#       图标/悬浮面板/输入框镜像/键盘避让）+ present 中央路由
#   (2) UIKit+hook.m —— Task235/236 魔改双钩子拆除，Task237 路由安装
#       （玻璃风格下 UIAlertController 永不上屏 = 构造性杜绝混杂；
#        原生风格零改动直透 = 旧版原生弹窗）
#   (3) SurfaceViewController+Navigation.m —— 游戏内菜单面板重写
#       （自控分层：实底永不清空 + 磨砂 index 0 + 内容恒在其上 + 图标行）
#   (4) SurfaceViewController.h —— menuView 类型 UITableView → UIView
#   (5) CMakeLists.txt —— 新源文件登记
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

fmh = rd("Natives/AmeFloatingMenu.h")
fm = rd("Natives/AmeFloatingMenu.m")
ukh = rd("Natives/UIKit+hook.m")
svn = rd("Natives/SurfaceViewController+Navigation.m")
svh = rd("Natives/SurfaceViewController.h")
cml = rd("Natives/CMakeLists.txt")

print("== A. 统一组件存在性与构建登记 ==")
check("A1", "组件头文件存在（路由 + 组件 + 行控件公开）",
      "AmeFloatingMenu" in fmh and "Ame237MenuRow" in fmh and
      "Ame237FloatingMenuRouter" in fmh)
check("A2", "CMake 源列表登记", "  AmeFloatingMenu.m\n" in cml)
check("A3", "组件实现含玻璃菜单 VC + 路由分类",
      "Ame237GlassMenuViewController" in fm and
      "UIViewController (Ame237FloatingMenuRouter)" in fm)
check("A4", "公开 API（presentGlassMenuForAlert + 图标启发式 + 符号渲染）",
      "presentGlassMenuForAlert:" in fmh and "iconNameForTitle:" in fmh and
      "symbolImageForName:" in fmh)

print("== B. 渲染配方（自控分层，文字可见性由构造保证）==")
check("B1", "面板防御性明暗实底（深黑 55% / 浅白 80%）",
      "static UIColor *Ame237PanelBase(void)" in fm and
      "alpha:0.55]" in fm and "alpha:0.80]" in fm)
check("B2", "UIVisualEffectView 毛玻璃背景（SystemMaterial 自适应）",
      "UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]" in fm and
      "[self.panel addSubview:self.blurView];" in fm)
check("B3", "圆角悬浮面板（26pt 连续圆角 + 阴影 + OverFullScreen 悬浮）",
      "cornerRadius = 26.0" in fm and "shadowOpacity = 0.32" in fm and
      "UIModalPresentationOverFullScreen" in fm)
check("B4", "发丝描边覆盖环（最上层空心底环）",
      "borderOverlay" in fm and "borderWidth = 0.75" in fm and
      "Ame237Dyn(0.30, 0.10)" in fm)
check("B5", "内容恒在磨砂之上（blur 先加、内容后加）",
      fm.find("[self.panel addSubview:self.blurView]") < fm.find("[self.panel addSubview:self.titleLabel]") and
      fm.find("[self.panel addSubview:self.rowsScroll]") < fm.find("[self.panel addSubview:self.borderOverlay]"))
check("B6", "永不清空宿主底色（无 clearColor 接管）",
      "self.panel.backgroundColor = [UIColor clearColor]" not in fm and
      "LGCApplyGlassToView" not in fm)
check("B7", "遮罩点击 = 取消/关闭（点击遮罩可关）",
      "ame237_dimTapped" in fm and "UIKeyboardWillShowNotification" in fm)
check("B8", "入场/退场动画（弹簧弹入 + 淡出）",
      "usingSpringWithDamping:0.80" in fm and
      "CGAffineTransformMakeScale(0.92, 0.92)" in fm)
check("B9", "行控件按压反馈（缩放 + 高亮）",
      "setHighlighted:(BOOL)highlighted" in fm and
      "CGAffineTransformMakeScale(0.97, 0.97)" in fm)
check("B10", " destructive 红色 / cancel 半粗体 / 长菜单滚动",
      "systemRedColor" in fm and "UIFontWeightSemibold" in fm and
      "rowsScroll.scrollEnabled" in fm)

print("== C. 菜单项带图标（SF Symbol 启发式 + 回退链）==")
check("C1", "标题归一化（剥 ✓/空白 + 小写）",
      "stringByTrimmingCharactersInSet" in fm and "lowercaseString" in fm)
check("C2", "中英双语关键词规则表",
      "xmark.circle" in fm and "trash.fill" in fm and "checkmark.circle.fill" in fm and
      "square.and.arrow.down" in fm and "person.crop.circle" in fm)
check("C3", "✓ 前缀识别（分辨率等已选项）",
      'hasPrefix:@"\\u2713"' in fm)
check("C4", "符号回退链（缺失降级 circle）",
      'systemImageNamed:@"circle"' in fm)
check("C5", "无规则时的样式化默认图标",
      "exclamationmark.circle" in fm and "circle.dotted" in fm)

print("== D. 镜像与中央路由 ==")
check("D1", "UIAlertAction KVC 镜像（title/style/handler/enabled）",
      'valueForKey:@"title"' in fm and 'valueForKey:@"style"' in fm and
      'valueForKey:@"handler"' in fm and 'valueForKey:@"enabled"' in fm)
check("D2", "镜像失败整体回退原生（样式永不破坏功能）",
      "action mirror failed" in fm and "return NO;" in fm)
check("D3", "玻璃风格下原生弹窗永不上屏（present 整体替换 + return）",
      "presentGlassMenuForAlert:(UIAlertController *)viewControllerToPresent" in fm and
      "[presenter presentViewController:menu animated:NO completion:" in fm)
check("D4", "原生风格零接触直透（交换后调原实现）",
      "[self ame237_hook_presentViewController:viewControllerToPresent animated:flag completion:completion];" in fm and
      "isKindOfClass:[UIAlertController class]] && LGCIsGlassStyleActive()" in fm)
check("D5", "输入框镜像（属性拷贝 + 双向同步 + 首框自动聚焦）",
      "secureTextEntry = src.secureTextEntry" in fm and
      "ame237_fieldChanged:" in fm and "ame237_syncAllFields" in fm and
      "becomeFirstResponder" in fm)
check("D6", "动作在退场完成后触发（规避呈现竞争）",
      "dismissViewControllerAnimated:NO completion:^{" in fm and
      "action.handler(action.orig);" in fm)
check("D7", "遮罩点击 = cancel 动作（存在时）",
      "if (m.style == 1) { cancel = m; break; }" in fm)
check("D8", "替换日志（限流）", "[AmeMenu] Task237 glass menu replaced native alert" in fm)
check("D9", "键盘避让（上移 + 回落）",
      "UIKeyboardFrameEndUserInfoKey" in fm and "ame237_kbShift" in fm)
check("D10", "布局纯 frame（无 Auto Layout 约束竞态）",
      "ame237_layout" in fm and "NSLayoutConstraint" not in fm)

print("== E. 游戏内菜单面板重写（文字恒可见）==")
check("E1", "面板容器改 UIView（UITableView 退役）",
      "self.menuView = [[UIView alloc] initWithFrame" in svn and
      "UITableView alloc] initWithFrame" not in svn)
check("E2", "表委托六方法退役（didSelect 动作链保持）",
      "tableView:(UITableView *)tableView numberOfRowsInSection" not in svn and
      "didSelectMenuItem:(int)item" in svn)
check("E3", "行控件 + 图标表（11 项对齐）",
      "Ame237MenuRow" in svn and "xmark.circle.fill" in svn and
      "antenna.radiowaves.left.and.right" in svn and "gearshape.fill" in svn)
check("E4", "行点击走同一动作链",
      "ame237_gmRowTouched:" in svn)
check("E5", "玻璃分支：磨砂 index 0 + 防御性深色实底 0.62 + 发丝描边",
      "insertSubview:ame237_blur atIndex:0]" in svn and
      "colorWithWhite:0.0 alpha:0.62]" in svn and
      "borderWidth = 0.75" in svn)
check("E6", "原生分支：旧版 FCL 深色 0.95 + 纯文本行",
      "alpha:0.95]" in svn and "showsIcon = NO" in svn)
check("E7", "风格切换广播接力（观察者保留）",
      "ame229_handleBackgroundUIEffectChanged" in svn and
      "BackgroundUIEffectChanged" in svn)
check("E8", "两形态保留（底部弹层 + 侧滑抽屉）",
      "ame227_sideDrawer" in svn and "ame227_drawerW" in svn)
check("E9", "几何变更后行区重排（抽屉/旋转）",
      svn.count("ame237_layoutMenuContent];") >= 4)
check("E10", "开菜取证日志（面板帧/底色/磨砂/首行）",
      "[GameMenu] Task237 menu shown" in svn)
check("E11", "行文字软黑投影（Task232 可读性教训保留）",
      "rowLabel.layer.shadowOpacity = 0.85" in svn)
check("E12", "关联存储（行滚动区/行数组/磨砂层）",
      "kAme237RowsScrollKey" in svn and "kAme237RowsKey" in svn and "kAme237BlurKey" in svn)

print("== F. UIKit+hook.m 手术（魔改拆除 + 路由安装 + 既有 hook 保留）==")
check("F1", "Task235/236 魔改双钩子拆除",
      "ame235_" not in ukh and "ame236_" not in ukh and
      "_UIAlertController" not in ukh)
check("F2", "Task237 路由安装块（基类 presentViewController 交换）",
      "@selector(ame237_hook_presentViewController:animated:completion:)" in ukh and
      "[AmeMenu] Task237 floating-menu router installed" in ukh)
check("F3", "路由头文件导入", '#import "AmeFloatingMenu.h"' in ukh)
check("F4", "LiquidGlassCompat 导入退役（本文件已无 LGC 调用）",
      'LiquidGlassCompat.h' not in ukh)
check("F5", "既有 hook 保留（UIDevice idiom / UIImageView / UIImage / tvOS / UIWindow）",
      "_setActiveUserInterfaceIdiom" in ukh and "hook_setImage:" in ukh and
      "hook_imageWithSize:" in ukh and "visibleViewController" in ukh)

print("== G. 头文件类型变更 ==")
check("G1", "menuView 类型 UITableView → UIView",
      "@property(nonatomic) UIView *menuView;" in svh and
      "UITableView *menuView" not in svh)

print("== H. 级联（被本改动触碰的区域 + 舰队抽样）==")
casc = ["verify_task129.py", "verify_task222.py", "verify_task225.py",
        "verify_task227.py", "verify_task229.py", "verify_task230.py",
        "verify_task231.py", "verify_task232.py", "verify_task233.py",
        "verify_task234.py", "verify_task235.py", "verify_task236.py"]
for v in casc:
    r = subprocess.run([sys.executable, os.path.join(BASE, "scripts", v)],
                       capture_output=True, text=True, timeout=600)
    tail = (r.stdout + r.stderr).strip().splitlines()
    verdict = tail[-1] if tail else "(no output)"
    check(f"H-{v}", f"exit={r.returncode} ({verdict[:60]})", r.returncode == 0)

print("========================================")
print(f"verify_task237: {n_ok} passed, {n_fail} failed")
sys.exit(1 if n_fail else 0)
