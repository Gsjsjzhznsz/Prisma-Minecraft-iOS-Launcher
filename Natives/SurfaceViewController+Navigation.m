#import "CustomControlsViewController.h"
#import "AmeNativeMenu.h"       // ★ Task240：菜单全面系统原生 UIMenu 化
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "GameMenuOverlayView.h"
#import "LiquidGlassCompat.h"   // Task229: floating menu composite glass
#import "BackgroundManager.h"   // ★ Task238：菜单树描边豁免（字体重叠根治）
#import "AmeFloatingMenu.h"     // ★ Task237：菜单行控件与统一悬浮菜单组件
#import "AmeLiquidGlassView.h"   // ★ Task252：TG LegacyGlassView 配方接管游戏内菜单面板
#import "TrackedTextField.h"
#import "customcontrols/CustomControlsUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "ScreenUtils.h"
#import "NMToast.h"
// ★ [MP-RESTORE] Task222：ZeroTier/Terracotta 联机恢复（上游同日恢复）
#import "MultiplayerViewController.h"
#import "MultiplayerManager.h"
#import "TerracottaViewController.h"
#import "TerracottaBridge.h"  // Task222 CI fix: isAvailable 探测（run 37300697020 报 undeclared identifier）
#import <objc/runtime.h>

// 暴露 class extension 中的私有属性，供 category 使用
@interface SurfaceViewController()
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) BOOL toggleHidden;
- (void)updateControlHiddenState:(BOOL)hide;
// Task64-fix：loadCustomControls 实现在 SurfaceViewController.m 的类扩展里，
// 对本 category 编译单元不可见（CI 实锤：no visible @interface declares the
// selector 'loadCustomControls'）。此处声明补上可见性，签名与实现一致
// （无参、void 返回，SurfaceViewController.m:1744）。
- (void)loadCustomControls;
@end

// category 不能存储 ivar，用 associated object 实现 menuDimView
static const void *kMenuDimViewKey = &kMenuDimViewKey;
// ★ Task237：自定义菜单面板的关联存储（行滚动区 / 行数组 / 磨砂层）
static const void *kAme237RowsScrollKey = &kAme237RowsScrollKey;
static const void *kAme237RowsKey = &kAme237RowsKey;
static const void *kAme237BlurKey = &kAme237BlurKey;
static const void *kAme243SnapKey = &kAme243SnapKey;
/// ★ Task244：快照磨砂可读性 tint 层（浮在快照之上、内容/滚动区之下）
static const void *kAme244TintKey = &kAme244TintKey;
/// ★ Task247：菜单展示期动态重抓的 CADisplayLink（T10：游戏内菜单伪玻璃
///   背景不随背景变化）
static const void *kAme247RefreshLinkKey = &kAme247RefreshLinkKey;
/// ★ Task252：TG LegacyGlassView 配方玻璃面板（玻璃家族档 + 支持时接管
///   快照磨砂/材质层/描边；快照供料模式由既有 8Hz 机制持续供料）。
static const void *kAme252GlassKey = &kAme252GlassKey;
/// ★ Task277（齿轮连点竞态根修）：菜单逻辑态与动画世代令牌。
///   旧 toggleMenu 读 menuView.hidden 决策，而 dismissMenu 的 hidden=YES
///   延迟到 0.25s 动画 completion——关闭动画窗口内 hidden 恒 NO，连点每
///   一拍都再触发一次 dismiss（永远开不出来）；关闭 completion 与新一次
///   showMenu 赛跑时还会把刚打开的面板隐藏（闪没）。逻辑态同步翻转 +
///   世代令牌让"最后一拍定状态"成为确定性语义。
static const void *kAme277MenuOpenKey = &kAme277MenuOpenKey;
static const void *kAme277MenuGenKey = &kAme277MenuGenKey;

@interface SurfaceViewController(Navigation)
// FCL 风格菜单的背景遮罩（半透明黑色，点击关闭菜单）
@property(nonatomic) UIView *menuDimView;
@end

/// ★ Task247（T10）：游戏画面快照（surfaceView 直抓）——菜单展示期的动态
///   磨砂原料。与 ame243_blurredGameSnapshot（keyWindow 全窗抓）的关键差
///   异：菜单打开后 menuView/menuDimView 都叠在 self.view 上，继续抓
///   keyWindow 会把面板自己拍进去（自噬 = 背景永不变化、菜单开着时背景
///   一直是一张静止图）；surfaceView 是游戏的 Metal 呈现面，永远不含菜
///   单 UI，8Hz 重抓零自噬面。drawViewHierarchyInRect afterScreenUpdates:NO
///   与 Task243 同序（Metal 帧安全，抓帧即模糊）。
static UIImage *ame247_surfaceSnapshot(UIView *ame247_surface) {
    if (ame247_surface == nil || ame247_surface.window == nil ||
        ame247_surface.bounds.size.width < 40.0 ||
        ame247_surface.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame247_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame247_fmt.scale = 0.18;
        ame247_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame247_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame247_surface.bounds.size
                                                   format:ame247_fmt];
        return [ame247_r imageWithActions:^(UIGraphicsImageRendererContext *ame247_rc) {
            [ame247_surface drawViewHierarchyInRect:ame247_surface.bounds
                                afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame247_e) {
        return nil;
    }
}

/// ★ Task252：TG 玻璃供料快照（0.5x——TG 滤镜栈自带 r=2 微模糊与
///   colorMatrix，原料保留真实细节供边缘网格折射；与 0.18x “抓帧即
///   模糊”旧路不同源）。
static UIImage *ame252_surfaceSnapshot(UIView *ame252_surface) {
    if (ame252_surface == nil || ame252_surface.window == nil ||
        ame252_surface.bounds.size.width < 40.0 ||
        ame252_surface.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame252_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame252_fmt.scale = 0.5;
        ame252_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame252_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame252_surface.bounds.size
                                                   format:ame252_fmt];
        return [ame252_r imageWithActions:^(UIGraphicsImageRendererContext *ame252_rc) {
            [ame252_surface drawViewHierarchyInRect:ame252_surface.bounds
                                 afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame252_e) {
        return nil;
    }
}

@implementation SurfaceViewController(Navigation)

- (void)setMenuDimView:(UIView *)menuDimView {
    objc_setAssociatedObject(self, kMenuDimViewKey, menuDimView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIView *)menuDimView {
    return objc_getAssociatedObject(self, kMenuDimViewKey);
}

/// ★ Task243：keyWindow 重度降采样快照（自绘磨砂原料）。
///   玻璃档的 UIVisualEffectView（UIGlassEffect/SystemMaterial）在本进程
///   Metal 游戏层上不合成（Task228 黑面 / Task230 隐形 / Task236 无字
///   三轮装机实锤），玻璃风格下游戏内菜单只剩深色防御底 = 用户看到的
///   "黑面板、毛玻璃没生效"（IMG_0378）。修法：打开菜单瞬间对 keyWindow
///   以 0.18x scale 抓一帧（重度降采样 = 天然高斯感模糊，抓帧即模糊），
///   作为面板背景层的"自绘磨砂"——游戏画面透出 + 模糊 + 深色底叠加 =
///   毛玻璃观感，零 CoreImage 依赖，一次抓帧零逐帧开销。
///   afterScreenUpdates:NO：抓当前已呈现帧，不触发屏幕更新（Metal 帧安全）；
///   抓帧失败/异常返回 nil，调用方保持深色底现状（护栏不降级观感）。
static UIImage *ame243_blurredGameSnapshot(UIView *hostView) {
    UIWindow *ame243_win = hostView.window;
    if (ame243_win == nil || ame243_win.bounds.size.width < 40.0 ||
        ame243_win.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame243_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame243_fmt.scale = 0.18;
        ame243_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame243_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame243_win.bounds.size
                                                   format:ame243_fmt];
        return [ame243_r imageWithActions:^(UIGraphicsImageRendererContext *ame243_rc) {
            [ame243_win drawViewHierarchyInRect:ame243_win.bounds
                             afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame243_e) {
        return nil;
    }
}

/// ★ Task244：快照有效性护栏（全黑帧检测，与 AmeFloatingMenu 同源）。
///   opaque=YES 抓帧失败/异常的病态产物是纯黑图（非 nil），上屏即黑面板。
static BOOL ame244_snapshotLooksValid(UIImage *ame244_img) {
    if (ame244_img == nil || ame244_img.size.width < 1.0 ||
        ame244_img.size.height < 1.0) return NO;
    CGImageRef ame244_cg = ame244_img.CGImage;
    if (ame244_cg == NULL) return NO;
    unsigned char ame244_px[4] = {0, 0, 0, 0};
    CGColorSpaceRef ame244_cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ame244_ctx = CGBitmapContextCreate(ame244_px, 1, 1, 8, 4,
        ame244_cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(ame244_cs);
    if (ame244_ctx == NULL) return NO;
    CGContextDrawImage(ame244_ctx, CGRectMake(0, 0, 1, 1), ame244_cg);
    CGContextRelease(ame244_ctx);
    int ame244_sum = (int)ame244_px[0] + (int)ame244_px[1] + (int)ame244_px[2];
    return ame244_sum > 19;   // 平均每通道 > ~6/255
}

/// ★ Task244：快照磨砂上的可读性 tint（快照不透明，menuView 底色被盖住
///   无法压暗）。深色 = 黑 0.40（暗玻璃）；浅色 = 白 0.42（奶白玻璃）。
///   ★ Task263（反馈 5）：alpha 随伪玻璃透明度设置映射，0.5 = 既有锚点；
///   1.0 最透 / 0.0 最闷（与 AmeFloatingMenu 同款映射）。
///   ★ Task276（"滑块无效"三连根修之二）：梯度拉宽 ±0.25/±0.275（0.0 =
///   深 0.65/浅 0.70；1.0 = 深 0.15/浅 0.15），provider 内延迟求值。本面板
///   为重建型瞬时视图（每次点开新建）→ 呈现时即取最新值，无需监听。
static UIColor *ame244_snapshotTint(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
        CGFloat ame263_t = LGCPseudoGlassTransparency();
        CGFloat ame263_a = (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? 0.40 - 0.50 * (ame263_t - 0.5)    // 0.65(最闷)..0.15(最透)，0.5→0.40
            : 0.42 - 0.55 * (ame263_t - 0.5);   // 0.70..0.15，0.5→0.42
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:0.0 alpha:ame263_a]
            : [UIColor colorWithWhite:1.0 alpha:ame263_a];
    }];
}

- (void)initCategory_Navigation {
    // FCL 安卓风格：菜单从底部弹出，游戏画面不缩小
    // 参照 FCL GameMenu.java / GameMenuView.kt 的底部弹出菜单样式
    self.menuArray = @[
        @"game.menu.force_close",          // 强制关闭
        @"game.menu.log_output",            // 日志输出
        @"game.menu.custom_controls",       // 按键布局编辑
        @"game.menu.restore_default_controls", // Task 64: 恢复默认控件（重建出厂布局）
        @"game.menu.multiplayer",           // 联机（陶瓦联机 Terracotta，右上角可切换 ZeroTier）
        @"game.menu.toggle_stats",          // FPS/内存显示开关
        @"game.menu.toggle_controls",       // 隐藏/显示控制按钮
        @"game.menu.toggle_virtual_mouse",  // 虚拟鼠标开关
        @"game.menu.toggle_keyboard",       // 游戏内键盘
        @"game.menu.resolution",            // 分辨率调整
        @"game.menu.settings"               // Task232⑰：原为裸英文字串 "Settings"（ localize 找不到键回退原文 = 硬编码残留）
    ];

    // ★ Task237（用户："现在游戏内菜单打开还是就液态玻璃的覆盖层，根本
    //   没有任何文字，要是不贴边，就只会给我全部屏幕覆盖层灰色"）：菜单
    //   面板整体重建——旧 UITableView + "往表里塞玻璃层"方案（Task229→
    //   232→236 三轮补丁）把分层控制权交给了 UIKit，磨砂层在本进程 Metal
    //   游戏层上合成不可靠（Task228 黑面 / Task230 隐形 / Task236 仍无字）。
    //   新面板分层自控：容器半透明深色实底（永不清空）→ UIVisualEffectView
    //   （最底层子视图）→ 行滚动区（内容恒在磨砂之上，文字可见性由构造
    //   保证）。玻璃风格 = 24pt 圆角磨砂面板 + 发丝描边 + SF Symbol 图标行；
    //   原生风格 = 旧版深色 FCL 面板纯文本行。底部弹层/侧滑把手两形态、
    //   全部 11 项动作与遮罩关闭行为全部保留。
    // ★ Task282：菜单几何源从 [ScreenUtils screenSize]（UIScreen 全屏口径
    //   ——自由窗口模式界面方向被系统接管后返回竖屏 820x1180，与窗口实
    //   况 551x486 完全脱钩，装机日志 panel={{420,0},{400,1180}} 实锤）
    //   改为 self.view.bounds（menuView 的宿主坐标系本源）：全屏时与旧值
    //   完全一致（window==screen），窗口模式菜单按窗口实况铺排不再溢出。
    // ★ Task285（"菜单设置不会跟随方向"根修）：菜单转置容器——menuView/
    //   menuDimView 的宿主从 self.view 改为 menuCanvas：⊥ 旋转态由 rescale
    //   与 overlay 同参跟转（同角 transform + 转置逻辑 bounds），面板在容
    //   器内按逻辑口径铺排 = 与游戏内容同向；非 ⊥ 容器恒等铺满 self.view，
    //   面板几何与直挂 self.view 逐字节一致（零回归）。全屏时容器与宿主
    //   同尺寸同向，行为完全不变。
    //   交互策略：容器 userInteractionEnabled 跟随菜单开闭——开启时 YES
    //   （面板/遮罩可交互），关闭时 NO（空容器不拦截触摸，悬浮球/游戏
    //   触摸照常穿透；否则 hitTest 命中容器自身会把 overlay 挡死）。
    CGFloat screenWidth = self.view.bounds.size.width;
    CGFloat screenHeight = self.view.bounds.size.height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 20;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    self.menuCanvas = [[UIView alloc] initWithFrame:self.view.bounds];
    self.menuCanvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.menuCanvas.userInteractionEnabled = NO;   // 关闭态穿透（showMenu 开启）
    self.menuCanvas.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.menuCanvas];

    self.menuView = [[UIView alloc] initWithFrame:CGRectMake(
        (screenWidth - menuWidth) / 2.0,
        screenHeight,  // 初始放在屏幕底部外（动画时上滑）
        menuWidth,
        menuHeight
    )];
    self.menuView.hidden = YES;
    self.menuView.clipsToBounds = NO;
    self.menuView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.menuView.layer.shadowOffset = CGSizeMake(0, -2);
    self.menuView.layer.shadowRadius = 12;
    self.menuView.layer.shadowOpacity = 0.4;
    [self.menuCanvas addSubview:self.menuView];

    // ★ Task238（用户：“修复字体与选项文本重叠问题”）：菜单面板行文字住在
    //   自控的磨砂/深色面板上（行自带软投影，Task232 #11），不再叠加全局
    //   壁纸描边（拷贝+垫底在面板上就是“文字双层/重叠”）。豁免整棵树。
    ame230_setViewTreeStrokeExempt(self.menuView, YES);

    // 行滚动区（唯一内容层；玻璃层永远在其下）
    // ★ Task271（271-b D1）：Ame237Scroll 放行取消跟踪——UIControl 行铺满
    //   滚动区时拖动也能起滚（游戏内 ⚙ 菜单 11 行 × 48pt 超 60% 帽同病）。
    UIScrollView *ame237_rowsScroll = [[Ame237Scroll alloc] init];
    ame237_rowsScroll.showsVerticalScrollIndicator = NO;
    ame237_rowsScroll.delaysContentTouches = NO;
    ame237_rowsScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.menuView addSubview:ame237_rowsScroll];
    objc_setAssociatedObject(self, kAme237RowsScrollKey, ame237_rowsScroll,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // 菜单行：SF Symbol 图标 + 标题（与 menuArray 逐项对齐；符号缺失安全降级为纯文本行）
    NSArray<NSString *> *ame237_gmIcons = @[
        @"xmark.circle.fill",                     // 强制关闭（destructive，红色）
        @"doc.text.viewfinder",                   // 日志输出
        @"slider.horizontal.3",                   // 按键布局编辑
        @"arrow.counterclockwise.circle",         // 恢复默认控件
        @"antenna.radiowaves.left.and.right",     // 联机
        @"chart.bar.fill",                        // FPS/内存显示开关
        @"eye.fill",                              // 隐藏/显示控制按钮
        @"cursorarrow.rays",                      // 虚拟鼠标
        @"keyboard",                              // 游戏内键盘
        @"textformat.size",                       // 分辨率调整
        @"gearshape.fill",                        // 设置
    ];
    NSMutableArray<Ame237MenuRow *> *ame237_rows = [NSMutableArray array];
    for (NSUInteger ame237_i = 0; ame237_i < self.menuArray.count; ame237_i++) {
        NSString *ame237_iconName = (ame237_i < ame237_gmIcons.count) ? ame237_gmIcons[ame237_i] : nil;
        UIImage *ame237_icon = [AmeFloatingMenu symbolImageForName:ame237_iconName];
        Ame237MenuRow *ame237_row = [[Ame237MenuRow alloc] init];
        BOOL ame237_destructive = (ame237_i == 0);   // 强制关闭 = 破坏性动作
        UIColor *ame237_rowColor = ame237_destructive ? [UIColor systemRedColor] : [UIColor whiteColor];
        [ame237_row ame237_configureWithIcon:ame237_icon
                                       title:localize(self.menuArray[ame237_i], nil)
                                   textColor:ame237_rowColor
                                 symbolTint:ame237_rowColor
                                    emphasis:NO];
        // 文字可读性沿用 Task232 #11 的教训：软黑投影，任何背景上可读
        ame237_row.rowLabel.layer.shadowColor = [UIColor blackColor].CGColor;
        ame237_row.rowLabel.layer.shadowOpacity = 0.85;
        ame237_row.rowLabel.layer.shadowRadius = 1.5;
        ame237_row.rowLabel.layer.shadowOffset = CGSizeMake(0, 1);
        ame237_row.tag = (NSInteger)ame237_i;
        [ame237_row addTarget:self action:@selector(ame237_gmRowTouched:)
            forControlEvents:UIControlEventTouchUpInside];
        [ame237_rowsScroll addSubview:ame237_row];
        [ame237_rows addObject:ame237_row];
        if (ame237_i + 1 < self.menuArray.count) {
            UIView *ame237_sep = [[UIView alloc] init];
            ame237_sep.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
            ame237_sep.userInteractionEnabled = NO;
            [ame237_rowsScroll addSubview:ame237_sep];
        }
    }
    objc_setAssociatedObject(self, kAme237RowsKey, [ame237_rows copy],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // FCL 风格：半透明背景遮罩（点击关闭菜单）
    self.menuDimView = [[UIView alloc] initWithFrame:self.menuCanvas.bounds];
    self.menuDimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.menuDimView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4];
    self.menuDimView.alpha = 0;
    self.menuDimView.hidden = YES;
    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissMenu)];
    dimTap.cancelsTouchesInView = YES;
    [self.menuDimView addGestureRecognizer:dimTap];
    [self.menuCanvas addSubview:self.menuDimView];
    // 确保菜单在遮罩之上
    [self.menuCanvas bringSubviewToFront:self.menuView];

    // 面板风格（玻璃/原生）与行区布局
    [self ame237_applyMenuStyle];
    [self ame237_layoutMenuContent];

    // FCL/ZL2 风格悬浮按钮 + FPS/内存显示
    GameMenuOverlayView *overlay = [[GameMenuOverlayView alloc] initWithParentView:self.view];
    __weak typeof(self) weakSelf = self;
    overlay.onMenuButtonTapped = ^{
        [weakSelf toggleMenu];
    };
    self.gameMenuOverlay = overlay;

    // Task229: style-switch broadcast re-applies (or removes) the floating
    // menu glass so toggling the launcher style reflects immediately.
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame229_handleBackgroundUIEffectChanged)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

/// ★ Task237：按当前界面风格应用/还原面板样式（风格切换广播也走这里）。
/// 玻璃 = 液态玻璃面板（SystemMaterialDark 磨砂 + 防御性深色实底 +
/// 发丝描边 + 图标行）；原生 = 旧版深色 FCL 面板（纯文本行）。
/// 分层：磨砂层是 index 0 子视图，行滚动区恒在其上——底色永不清空
/// （不再使用会清宿主底色的 LGCApplyGlassToView，三轮装机教训的根除）。
- (void)ame237_applyMenuStyle {
    if (![self.menuView isKindOfClass:[UIView class]]) return;
    // 幂等：先拆旧磨砂层（本函数是唯一写点）
    UIView *ame237_oldBlur = objc_getAssociatedObject(self, kAme237BlurKey);
    if (ame237_oldBlur != nil) {
        [ame237_oldBlur removeFromSuperview];
        objc_setAssociatedObject(self, kAme237BlurKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIScrollView *ame237_scroll = objc_getAssociatedObject(self, kAme237RowsScrollKey);
    NSArray<Ame237MenuRow *> *ame237_rows = objc_getAssociatedObject(self, kAme237RowsKey);
    // ★ Task260（清单 2）：会话玻璃安全闸——MC <26 会话（老绘制链）上玻璃
    //   面板崩溃且无回退；auto 与手动 liquid_glass 同闸，<26 会话内一律
    //   回退原生面板（下面的 else 分支），绝不崩。
    BOOL ame260_glassAllowed = LGCIsGlassStyleActive() && LGCGameSessionGlassAllowed();
    if (!LGCIsGlassStyleActive()) {
        // 风格本身非玻璃：静默走原生（原语义零变化）
    } else if (!ame260_glassAllowed) {
        NSLog(@"[GameMenu] Task260: glass panel blocked by session gate (MC major <26 legacy "
              @"draw chain) -- falling back to native panel (auto and manual liquid_glass alike)");
    }
    if (ame260_glassAllowed) {
        // ★ Task239（用户指令：iOS 26 原生液态玻璃 API）：玻璃风格优先
        //   【系统原生 UIGlassEffect】（iOS 26+，真液态玻璃：磨砂 + 折光 +
        //   边缘高光一体）；Task244 默认退役（本进程恒不渲染，见 LGC），
        //   诊断开关 AME239_FORCE_SYSTEM_GLASS=1 才回取；默认回退
        //   SystemMaterialDark 磨砂（Task230 游戏帧可读性教训的装机验证路径）。
        UIVisualEffect *ame239_gmEffect = LGCNativeGlassEffect();
        if (ame239_gmEffect == nil) {
            ame239_gmEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
        }
        UIVisualEffectView *ame237_blur = [[UIVisualEffectView alloc] initWithEffect:ame239_gmEffect];
        ame237_blur.frame = self.menuView.bounds;
        ame237_blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ame237_blur.userInteractionEnabled = NO;
        ame237_blur.layer.cornerRadius = 24.0;
        ame237_blur.layer.cornerCurve = kCACornerCurveContinuous;
        ame237_blur.layer.masksToBounds = YES;
        // ★ Task243：自绘磨砂层（快照 UIImageView）——插在 blur 之下
        //   （index 0），blur 重建时跟随重插保持次序：快照在下、系统磨砂
        //   在上。Metal 游戏帧上系统磨砂不合成（透明）→ 快照层承载观感；
        //   合成场景（若存在）两者叠加 = 层次更接近真玻璃。
        UIImageView *ame243_snap = objc_getAssociatedObject(self, kAme243SnapKey);
        if (ame243_snap == nil) {
            ame243_snap = [[UIImageView alloc] initWithFrame:self.menuView.bounds];
            ame243_snap.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            // ★ Task248（⑨）：ScaleToFill（窗口对位 1:1 映射，无裁剪）——
            //   旧 ScaleAspectFill 居中裁剪 = 假透视（见 ame248_alignMenuFrost）。
            ame243_snap.contentMode = UIViewContentModeScaleToFill;
            ame243_snap.clipsToBounds = YES;
            ame243_snap.userInteractionEnabled = NO;
            ame243_snap.hidden = YES;   // 首次 showMenu 抓帧后才显示
            objc_setAssociatedObject(self, kAme243SnapKey, ame243_snap,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            [ame243_snap removeFromSuperview];   // 幂等：先拆再插（本函数是唯一写点）
        }
        ame243_snap.frame = self.menuView.bounds;
        ame243_snap.layer.cornerRadius = 24.0;
        ame243_snap.layer.cornerCurve = kCACornerCurveContinuous;
        ame243_snap.layer.masksToBounds = YES;
        [self.menuView insertSubview:ame243_snap atIndex:0];
        [self.menuView insertSubview:ame237_blur aboveSubview:ame243_snap];
        objc_setAssociatedObject(self, kAme237BlurKey, ame237_blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // ★ Task244：快照磨砂 tint 层——浮在快照之上、滚动区之下。
        //   快照不透明，menuView 底色在其下无法压暗；系统材质层（无论
        //   玻璃还是 SystemMaterialDark）在 27.0.1 上已实证不可靠，快照
        //   成品磨砂到位后整体退场（见 showMenu 抓帧点联动）。首建时尚
        //   未抓帧（image=nil）：tint/快照均保持 hidden，面板走材质磨砂。
        UIView *ame244_tint = objc_getAssociatedObject(self, kAme244TintKey);
        if (ame244_tint == nil) {
            ame244_tint = [[UIView alloc] init];
            ame244_tint.backgroundColor = ame244_snapshotTint();
            ame244_tint.userInteractionEnabled = NO;
            ame244_tint.layer.cornerRadius = 24.0;
            ame244_tint.layer.cornerCurve = kCACornerCurveContinuous;
            ame244_tint.layer.masksToBounds = YES;
            objc_setAssociatedObject(self, kAme244TintKey, ame244_tint,
                                     OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else {
            [ame244_tint removeFromSuperview];   // 幂等：先拆再插（本函数是唯一写点）
        }
        ame244_tint.frame = self.menuView.bounds;
        ame244_tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        // ★ Task277（玻璃感三件之二·顶部光泽线，游戏菜单侧）：嵌进 tint 层
        //   —— tint 显隐/退场（TG 接管/原生档）时光泽自动跟随，零额外
        //   同步状态。tag 277 供幂等重建识别。
        {
            UIView *ame277_oldSheen = [ame244_tint viewWithTag:277];
            [ame277_oldSheen removeFromSuperview];
            UIView *ame277_sheenHost = [[UIView alloc] initWithFrame:
                CGRectMake(0.0, 0.0, self.menuView.bounds.size.width,
                           self.menuView.bounds.size.height * 0.32)];
            ame277_sheenHost.userInteractionEnabled = NO;
            ame277_sheenHost.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            ame277_sheenHost.tag = 277;
            CAGradientLayer *ame277_sheen = [CAGradientLayer layer];
            ame277_sheen.frame = ame277_sheenHost.bounds;
            ame277_sheen.name = @"ame277_sheen";
            ame277_sheen.colors = @[(id)[UIColor colorWithWhite:1.0 alpha:0.10].CGColor,
                                    (id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor];
            ame277_sheen.locations = @[@0.0, @1.0];
            ame277_sheen.startPoint = CGPointMake(0.5, 0.0);
            ame277_sheen.endPoint = CGPointMake(0.5, 1.0);
            [ame277_sheenHost.layer addSublayer:ame277_sheen];
            [ame244_tint addSubview:ame277_sheenHost];
        }
        [self.menuView insertSubview:ame244_tint aboveSubview:ame243_snap];
        ame244_tint.hidden = (ame243_snap.image == nil);
        ame237_blur.hidden = (ame243_snap.image != nil);
        if (ame237_scroll != nil) [self.menuView bringSubviewToFront:ame237_scroll];
        // 防御性深色实底：磨砂在游戏帧上不合成时独立承载面板可见性
        //   （Task236 教训；此处底色只由本函数管理，永不清空）。
        //   Task239：原生玻璃用 0.50 通透档（真玻璃自带磨砂折光），
        //   材质回退保持 0.62 厚底（行文字为白色，两档均可读）。
        //   Task243：底色减薄至 0.42——快照磨砂层已接管"游戏画面透出"，
        //   底色只负责压暗保证可读，过厚会把模糊画面闷成黑面板
        //   （IMG_0378 的观感主因之一）。
        self.menuView.backgroundColor = [UIColor colorWithWhite:0.0
                                                          alpha:LGCNativeGlassEngaged() ? 0.42 : 0.62];
        self.menuView.layer.cornerRadius = 24.0;
        self.menuView.layer.cornerCurve = kCACornerCurveContinuous;
        self.menuView.layer.borderWidth = 0.75;
        self.menuView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        // ★ Task252：TG LegacyGlassView 配方接管——运行时支持时，快照磨砂/
        //   材质层/发丝描边三件套整体退场，TG 玻璃（backdrop 采样[快照供
        //   料] + colorMatrix + gaussianBlur(2) + SDF 折射网格 + .panel 填充
        //   + 0.8pt 描边）一次到位；供料由 showMenu/8Hz tick 持续执行。
        if ([AmeLiquidGlassView ame252_isSupported]) {
            AmeLiquidGlassView *ame252_glass = objc_getAssociatedObject(self, kAme252GlassKey);
            if (ame252_glass == nil) {
                ame252_glass = [AmeLiquidGlassView ame252_glassViewWithCornerRadius:24.0
                                                                             isDark:YES];
                objc_setAssociatedObject(self, kAme252GlassKey, ame252_glass,
                                         OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            } else {
                [ame252_glass removeFromSuperview];   // 幂等：先拆再插（本函数是唯一写点）
                ame252_glass.hidden = NO;
            }
            if (ame252_glass != nil) {
                ame252_glass.frame = self.menuView.bounds;
                ame252_glass.autoresizingMask =
                    UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [self.menuView insertSubview:ame252_glass atIndex:0];
                ame243_snap.hidden = YES;      // 旧快照磨砂退场（心跳关联保留）
                ame244_tint.hidden = YES;      // 旧 tint 退场（填充承载可读性）
                ame237_blur.hidden = YES;      // 材质层退场
                self.menuView.backgroundColor = nil;   // 底色退场（防 backdrop 双采）
                self.menuView.layer.borderWidth = 0.0; // 描边交 TG 0.8pt 环
                self.menuView.layer.borderColor = nil;
            }
        }
        for (Ame237MenuRow *ame237_row in ame237_rows) {
            ame237_row.showsIcon = YES;
            [ame237_row setNeedsLayout];
        }
        // ★ Task288：材质名不再误导——TG 玻璃接管（ame252）后旧文案仍打
        //   "SystemMaterialDark fallback"，装机日志判档会被带偏。如实三态。
        NSLog(@"[GameMenu] Task237 glass panel applied (frosted + defensive dark base + hairline; rows above blur; icon rows) [material: %@]",
              LGCNativeGlassEngaged() ? @"native UIGlassEffect"
              : ([AmeLiquidGlassView ame252_isSupported] ? @"TG pseudo-liquid-glass (ame252 takeover)"
                                                         : @"SystemMaterialDark fallback"));
    } else {
        // 原生 = 旧版 FCL 面板（深色半透明、纯文本行）
        // ★ Task243：风格切回原生时同步隐藏快照磨砂层（幂等清理）。
        // ★ Task244：同步恢复材质层/撤下 tint（与抓帧点两分支对齐）。
        UIImageView *ame243_snap = objc_getAssociatedObject(self, kAme243SnapKey);
        if (ame243_snap != nil) {
            ame243_snap.hidden = YES;
            ame243_snap.image = nil;
        }
        // ★ Task252：原生档同步隐藏 TG 玻璃（风格切换幂等清理）。
        {
            AmeLiquidGlassView *ame252_glassOff = objc_getAssociatedObject(self, kAme252GlassKey);
            if (ame252_glassOff != nil) ame252_glassOff.hidden = YES;
        }
        {
            UIView *ame244_blurBack = objc_getAssociatedObject(self, kAme237BlurKey);
            if (ame244_blurBack != nil) ame244_blurBack.hidden = NO;
            UIView *ame244_tintBack = objc_getAssociatedObject(self, kAme244TintKey);
            if (ame244_tintBack != nil) ame244_tintBack.hidden = YES;
        }
        self.menuView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
            return [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.95];
        }];
        self.menuView.layer.cornerRadius = 16.0;
        self.menuView.layer.borderWidth = 0.0;
        self.menuView.layer.borderColor = nil;
        for (Ame237MenuRow *ame237_row in ame237_rows) {
            ame237_row.showsIcon = NO;
            [ame237_row setNeedsLayout];
        }
        NSLog(@"[GameMenu] Task237 native panel applied (legacy FCL look, text-only rows)");
    }
}

/// Task237：行/分隔线/滚动区布局（面板几何确定后调用：构造、旋转、侧滑形态切换）。
- (void)ame237_layoutMenuContent {
    UIScrollView *ame237_scroll = objc_getAssociatedObject(self, kAme237RowsScrollKey);
    NSArray<Ame237MenuRow *> *ame237_rows = objc_getAssociatedObject(self, kAme237RowsKey);
    if (![ame237_scroll isKindOfClass:[UIScrollView class]] || ame237_rows.count == 0) return;
    CGFloat ame237_w = self.menuView.bounds.size.width;
    CGFloat ame237_h = self.menuView.bounds.size.height;
    CGFloat ame237_pad = 10.0;
    ame237_scroll.frame = CGRectMake(0.0, ame237_pad, ame237_w, MAX(0.0, ame237_h - ame237_pad * 2.0));
    // 分隔线 = 行滚动区内的非行子视图（构造顺序即排列顺序）
    NSMutableArray<UIView *> *ame237_seps = [NSMutableArray array];
    for (UIView *ame237_sub in ame237_scroll.subviews) {
        if (![ame237_sub isKindOfClass:[Ame237MenuRow class]]) {
            [ame237_seps addObject:ame237_sub];
        }
    }
    CGFloat ame237_y = 0.0;
    NSUInteger ame237_sepIdx = 0;
    for (NSUInteger ame237_i = 0; ame237_i < ame237_rows.count; ame237_i++) {
        Ame237MenuRow *ame237_row = ame237_rows[ame237_i];
        ame237_row.frame = CGRectMake(0.0, ame237_y, ame237_w, 48.0);
        ame237_y += 48.0;
        if (ame237_i + 1 < ame237_rows.count && ame237_sepIdx < ame237_seps.count) {
            UIView *ame237_sep = ame237_seps[ame237_sepIdx++];
            ame237_sep.frame = CGRectMake(22.0, ame237_y, ame237_w - 44.0, 0.5);
            ame237_y += 0.5;
        }
    }
    ame237_scroll.contentSize = CGSizeMake(ame237_w, ame237_y);
    ame237_scroll.scrollEnabled = (ame237_y > ame237_scroll.bounds.size.height + 0.5);
    ame237_scroll.showsVerticalScrollIndicator = ame237_scroll.isScrollEnabled; // ★ Task271（D5）：可滚时给暗示
    // ★ Task248（⑨）：行区重排（旋转/形态切换）后快照对位几何同步刷新
    [self ame248_alignMenuFrost];
}

/// Task237：菜单行点击（与旧 tableView:didSelectRowAtIndexPath: 同一动作链）。
- (void)ame237_gmRowTouched:(Ame237MenuRow *)sender {
    // ★ Task277（连点锁存）：行点击只在逻辑态开时生效——首拍触发动作链
    //   （dismissMenu 置态关）后，淡出动画期的残留点击不再二连发（双弹窗
    //   /双动作根源；与 Ame237 面板 ame237_dismissing 同族锁存语义）。
    if (!self.ame277_menuOpenState) return;
    [self didSelectMenuItem:(int)sender.tag];
}

- (void)ame229_handleBackgroundUIEffectChanged {
    [self ame237_applyMenuStyle];
    [self ame237_layoutMenuContent];
}

/// ★ Task238（用户："刚启动游戏⚙️和文字没有显示"）：把游戏内悬浮件
///   （遮罩 < 菜单面板 < 悬浮球，相对次序保持）提到启动遮罩层之上——
///   启动遮罩是 viewDidLoad 后 addSubview 的，默认盖住全部悬浮件 8.5 秒；
///   遮罩本身 userInteractionEnabled=NO（设计意图就是启动期间可拖悬浮球、
///   查 FPS）。menuDimView 是本分类的关联对象属性——方法必须住在本分类
///   里才可见（SurfaceViewController.m 经 performSelector 调用）。
///   ★ Task285：dim/menu 已迁宿主 menuCanvas——bringSubviewToFront 只作
///   用于直接子视图，整组改以 canvas 为单位提升（canvas 内相对次序不变：
///   dim < menu），overlay 最后置顶不变。
- (void)ame238_raiseGameMenuAboveLaunchMask {
    if ([self.menuCanvas isKindOfClass:[UIView class]]) {
        [self.view bringSubviewToFront:self.menuCanvas];
    }
    if ([self.gameMenuOverlay isKindOfClass:[UIView class]]) {
        [self.view bringSubviewToFront:self.gameMenuOverlay];
    }
}

/// ★ Task277：菜单逻辑态读写（关联对象；分类无 ivar）。
- (BOOL)ame277_menuOpenState {
    return [objc_getAssociatedObject(self, kAme277MenuOpenKey) boolValue];
}

- (void)ame277_setMenuOpenState:(BOOL)open {
    objc_setAssociatedObject(self, kAme277MenuOpenKey, @(open), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSInteger)ame277_bumpMenuGeneration {
    NSInteger ame277_gen = [objc_getAssociatedObject(self, kAme277MenuGenKey) integerValue] + 1;
    objc_setAssociatedObject(self, kAme277MenuGenKey, @(ame277_gen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return ame277_gen;
}

- (NSInteger)ame277_currentMenuGeneration {
    return [objc_getAssociatedObject(self, kAme277MenuGenKey) integerValue];
}

/// 切换菜单显示状态（悬浮按钮点击触发）
/// ★ Task277：决策源从 menuView.hidden（延迟到关闭动画 completion 才归位
///   = 关闭窗口内连点永远 dismiss 再 dismiss，开不出来）改为同步翻转的
///   逻辑态——连点语义变为确定性的"最后一拍定状态"：关动画中点一下立
///   即重新展开，开动画中点一下立即收起。
- (void)toggleMenu {
    if (self.ame277_menuOpenState) {
        [self dismissMenu];
    } else {
        [self showMenu];
    }
}

/// ★ Task247（T10）：菜单展示期动态磨砂——8Hz 重抓游戏画面（Task246 在
///   AmeFloatingMenu 弹窗上的同款机制移植到游戏内主菜单）。停止条件：
///   菜单隐藏/风格切换非玻璃族/链接失效，tick 内自查自停（分类无 dealloc
///   钩子，靠隐藏态自愈 + showMenu 重启）。
- (void)ame247_stopMenuSnapshotRefresh {
    CADisplayLink *ame247_link = objc_getAssociatedObject(self, kAme247RefreshLinkKey);
    if (ame247_link != nil) {
        [ame247_link invalidate];
        objc_setAssociatedObject(self, kAme247RefreshLinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

/// ★ Task248（⑨ 折射有问题 根修）：快照磨砂【窗口对位真透视】。
///   Task247 T10 移植 8Hz 重抓时没移植 Task245 的对位几何：快照
///   ScaleAspectFill 居中放大裁切进 70% 宽面板 = 显示的是整幅游戏画面的
///   中心裁切，而面板正后方实际是另一块内容（几何错位假透透）。修法：
///   surfaceView.bounds 经 convertRect 映射到 menuView 坐标系，快照层
///   恰好铺在"面板正后方的游戏画面区域"上（1:1 真透视，与 Ame245
///   AmeFloatingMenu 定案同源）；ScaleToFill 1:1 映射无裁剪。
- (void)ame248_alignMenuFrost {
    // ★ Task252：TG 玻璃对位——同一几何映射改写玻璃快照源矩形。
    AmeLiquidGlassView *ame252_glass = objc_getAssociatedObject(self, kAme252GlassKey);
    UIImageView *ame248_snap = objc_getAssociatedObject(self, kAme243SnapKey);
    if (ame252_glass == nil && ame248_snap == nil) return;
    if (self.menuView == nil || self.surfaceView == nil) return;
    if (self.surfaceView.window == nil) return;
    CGRect ame248_rect = [self.surfaceView convertRect:self.surfaceView.bounds
                                                toView:self.menuView];
    if (CGRectIsEmpty(ame248_rect)) return;
    if (!isfinite(ame248_rect.origin.x) || !isfinite(ame248_rect.origin.y) ||
        !isfinite(ame248_rect.size.width) || !isfinite(ame248_rect.size.height)) return;
    if (ame252_glass != nil) {
        ame252_glass.ame252_backdropSourceRect = ame248_rect;
        return;
    }
    ame248_snap.contentMode = UIViewContentModeScaleToFill;
    ame248_snap.frame = ame248_rect;
}

- (void)ame247_menuSnapshotTick:(CADisplayLink *)ame247_sender {
    if (self.menuView == nil || self.menuView.hidden ||
        // ★ Task270 P2：VC 已离开窗口（退游戏/被替换）→ 供料链自停。原停止
        //   条件依赖 dealloc 复位会话闸（P0 前 dealloc 不可达，P0 后也晚于
        //   离窗）——菜单开着退游戏后死 VC 会以 8Hz 永久快照 dead surface
        //   空耗 CPU/电池；对齐 ame250_frostTick 的 view.window==nil 同族护栏。
        self.surfaceView.window == nil ||
        !LGCIsGlassStyleActive() ||
        // ★ Task260（清单 2）：<26 会话闸内供料链整体自停（面板已回退原生）
        !LGCGameSessionGlassAllowed()) {
        [self ame247_stopMenuSnapshotRefresh];
        return;
    }
    // ★ Task252：TG 玻璃供料 tick（0.5x 原料持续喑玻璃；心跳依旧以
    //   kAme243SnapKey 关联存在为前提）。
    AmeLiquidGlassView *ame252_glass = objc_getAssociatedObject(self, kAme252GlassKey);
    if (ame252_glass != nil && ame252_glass.superview != nil) {
        UIImage *ame252_fresh = ame252_surfaceSnapshot(self.surfaceView);
        if (ame252_fresh != nil && !ame244_snapshotLooksValid(ame252_fresh)) return;
        if (ame252_fresh != nil) {
            ame252_glass.ame252_backdropSnapshot = ame252_fresh;
            [self ame248_alignMenuFrost];   // 每 tick 同步对位（面板挪位/旋转不脱钩）
        }
        return;
    }
    UIImageView *ame247_snap = objc_getAssociatedObject(self, kAme243SnapKey);
    if (ame247_snap == nil) {
        [self ame247_stopMenuSnapshotRefresh];
        return;
    }
    UIImage *ame247_fresh = ame247_surfaceSnapshot(self.surfaceView);
    if (ame247_fresh != nil && !ame244_snapshotLooksValid(ame247_fresh)) {
        // 全黑帧护栏：Metal 抓帧病态产物 = 保留上一张有效图，绝不降级黑磨砂
        return;
    }
    if (ame247_fresh != nil) {
        // ★ Task277：8Hz 重抓成品同步材质化（与首帧同配方，零观感跳变）。
        ame247_snap.image = [AmeFloatingMenu ame277_materializeSnapshot:ame247_fresh];
        // ★ Task248（⑨）：每 tick 同步对位几何（面板挪位/旋转后不脱钩）
        [self ame248_alignMenuFrost];
        if (ame247_snap.hidden) {
            ame247_snap.hidden = NO;
            UIView *ame247_tint = objc_getAssociatedObject(self, kAme244TintKey);
            if (ame247_tint != nil) ame247_tint.hidden = NO;
            UIView *ame247_blur = objc_getAssociatedObject(self, kAme237BlurKey);
            if (ame247_blur != nil) ame247_blur.hidden = YES;
        }
    }
}

- (void)ame247_startMenuSnapshotRefresh {
    if (!LGCIsGlassStyleActive()) return;
    // ★ Task260（清单 2）：<26 会话闸内不建供料链（面板已回退原生）
    if (!LGCGameSessionGlassAllowed()) return;
    [self ame247_stopMenuSnapshotRefresh];
    CADisplayLink *ame247_link = [CADisplayLink displayLinkWithTarget:self
                                                             selector:@selector(ame247_menuSnapshotTick:)];
    ame247_link.preferredFramesPerSecond = 8;   // Task246 同款 8Hz：背景变化 ≤125ms 跟上
    [ame247_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(self, kAme247RefreshLinkKey, ame247_link,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

/// FCL 风格：从底部弹出菜单（游戏画面不缩小）
/// ★ Task227（反馈 #8）：齿轮吸边成把手时，菜单改从吸边侧滑出（侧边栏
/// 形态）；悬浮球形态保持原底部弹层。
- (void)showMenu {
    // ★ Task277：逻辑态置开 + 世代令牌推进（作废在飞的关闭 completion）——
    //   连点场景下旧关闭动画的 completion 不得把刚重新打开的面板藏掉。
    [self ame277_setMenuOpenState:YES];
    __block NSInteger ame277_gen = [self ame277_bumpMenuGeneration];
    BOOL ame227_sideDrawer = NO;
    BOOL ame227_fromLeft = NO;
    if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
        GameMenuOverlayView *ame227_ov = (GameMenuOverlayView *)self.gameMenuOverlay;
        ame227_sideDrawer = ame227_ov.isDocked;
        ame227_fromLeft = ame227_ov.dockedLeft;
    }

    // ★ Task243：打开菜单瞬间抓帧——【必须在 menuView.hidden = NO 之前】：
    //   先抓帧（menuView 还不可见，抓到的是纯游戏画面）再显示面板；若
    //   反序，快照里会包含面板自身的黑底 = 快照全黑（自噬）。
    //   玻璃档才启用；抓帧失败（返回 nil）保持层隐藏，面板回退到深色底
    //   现状（护栏）。
    UIImageView *ame243_snap = objc_getAssociatedObject(self, kAme243SnapKey);
    if (ame243_snap != nil && LGCIsGlassStyleActive()) {
        // ★ Task252：TG 玻璃供料分支——0.5x 原料（滤镜栈自微模糊，保留细节）；
        //   无效帧供 nil = 实况回退（填充承载）；旧快照/tint/材质层不在此路上屏。
        AmeLiquidGlassView *ame252_glass = objc_getAssociatedObject(self, kAme252GlassKey);
        if (ame252_glass != nil && ame252_glass.superview != nil) {
            UIImage *ame252_img = ame252_surfaceSnapshot(self.surfaceView);
            if (ame252_img != nil && !ame244_snapshotLooksValid(ame252_img)) ame252_img = nil;
            ame252_glass.ame252_backdropSnapshot = ame252_img;
            [self ame248_alignMenuFrost];   // 首帧即对位
        } else {
        // ★ Task248（⑨）：首帧源与 8Hz tick 统一为 surfaceView 直抓——旧首帧
        //   用 ame243_blurredGameSnapshot(self.view)（整窗快照，含控制按钮层），
        //   tick 用 surfaceView（纯游戏画面）：两个源构图不同 = 开菜单瞬间
        //   背景"跳变"（折射有问题的观感成分之一）。统一后零跳变。
        UIImage *ame243_img = ame247_surfaceSnapshot(self.surfaceView);
        if (ame243_img != nil && !ame244_snapshotLooksValid(ame243_img)) {
            NSLog(@"[GameMenu] Task244: snapshot blank (capture failure), panel falls back to material blur");
            ame243_img = nil;
        }
        if (ame243_img != nil) {
            // ★ Task277：磨砂成品统一走材质链（高斯+饱和度，与 AmeFloatingMenu
            //   弹窗同配方；旧纯降采样的"糊"升级为 Apple 材质观感）。
            ame243_snap.image = [AmeFloatingMenu ame277_materializeSnapshot:ame243_img];
            [self ame248_alignMenuFrost];   // ★ Task248（⑨）：首帧即对位
            ame243_snap.hidden = NO;
            // ★ Task244：快照成品磨砂到位——系统材质层退场、tint 上岗
            //   （快照不透明，磨砂/玻璃叠在其上只会引入黑块/过糊变量）。
            UIView *ame244_blur = objc_getAssociatedObject(self, kAme237BlurKey);
            if (ame244_blur != nil) ame244_blur.hidden = YES;
            UIView *ame244_tintOn = objc_getAssociatedObject(self, kAme244TintKey);
            if (ame244_tintOn != nil) ame244_tintOn.hidden = NO;
        } else {
            ame243_snap.hidden = YES;
            // 快照缺席：材质磨砂回归、tint 撤下（与 applyMenuStyle 幂等态对齐）
            UIView *ame244_blurFb = objc_getAssociatedObject(self, kAme237BlurKey);
            if (ame244_blurFb != nil) ame244_blurFb.hidden = NO;
            UIView *ame244_tintOff = objc_getAssociatedObject(self, kAme244TintKey);
            if (ame244_tintOff != nil) ame244_tintOff.hidden = YES;
        }
        }   // ★ Task252：else（旧快照磨砂管线）收口
    } else if (ame243_snap != nil) {
        ame243_snap.hidden = YES;
        UIView *ame244_blurNat = objc_getAssociatedObject(self, kAme237BlurKey);
        if (ame244_blurNat != nil) ame244_blurNat.hidden = NO;
        UIView *ame244_tintNat = objc_getAssociatedObject(self, kAme244TintKey);
        if (ame244_tintNat != nil) ame244_tintNat.hidden = YES;
    }

    self.menuView.hidden = NO;
    self.menuDimView.hidden = NO;

    // ★ Task247（T10）：菜单展示期动态重抓（8Hz）——伪玻璃/玻璃档下背景
    //   随游戏画面持续变化（此前只在打开瞬间抓一帧，菜单开着时背景永远
    //   是静止图）。
    [self ame247_startMenuSnapshotRefresh];

    // ★ Task237：开菜取证（接替 Task232 的 cell 取证——菜单已非表视图）——
    //   面板帧/底色/磨砂层/首行帧与标签尺寸全量落日志，下一轮装机日志
    //   直接验证“面板可见 + 文字在上层”是否成立。
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<Ame237MenuRow *> *ame237_rows = objc_getAssociatedObject(self, kAme237RowsKey);
        Ame237MenuRow *ame237_r0 = ame237_rows.firstObject;
        NSLog(@"[GameMenu] Task237 menu shown: rows=%lu firstRow=%@ label=%@ panel=%@ bg=%@ blur=%ld glass=%d",
              (unsigned long)ame237_rows.count,
              ame237_r0 != nil ? NSStringFromCGRect(ame237_r0.frame) : @"nil",
              ame237_r0 != nil ? NSStringFromCGSize(ame237_r0.rowLabel.frame.size) : @"nil",
              NSStringFromCGRect(self.menuView.frame),
              self.menuView.backgroundColor,
              (long)(objc_getAssociatedObject(self, kAme237BlurKey) != nil),
              (int)LGCIsGlassStyleActive());
    });

    // ★ Task282：几何源同创建处改宿主实况口径，抽屉/悬浮两形态均不再引
    //   用全屏口径尺寸。★ Task285：几何源再随宿主迁移改 menuCanvas.bounds
    //   （⊥ 时容器已是转置逻辑口径 = 面板与游戏内容同向铺排）；同时开启
    //   容器交互（面板/遮罩可点）。
    CGFloat screenWidth = self.menuCanvas.bounds.size.width;
    CGFloat screenHeight = self.menuCanvas.bounds.size.height;
    self.menuCanvas.userInteractionEnabled = YES;
    self.menuView.transform = CGAffineTransformIdentity;

    if (ame227_sideDrawer) {
        // 侧滑形态：全高面板从吸边侧滑入（宽度与构造公式同源，最小 280；
        // ★ Task238：不再读残留 frame 宽——上一形态可能是不同宽度的弹层）
        CGFloat ame227_drawerW = MAX(MIN(screenWidth * 0.7, 400), 280);
        CGFloat ame227_drawerH = screenHeight;
        CGFloat ame227_offX = ame227_fromLeft ? -ame227_drawerW : screenWidth;
        self.menuView.frame = CGRectMake(ame227_offX, 0, ame227_drawerW, ame227_drawerH);
        // ★ Task237：几何变更（全高抽屉）后重排行区
        [self ame237_layoutMenuContent];
        CGFloat ame227_targetX = ame227_fromLeft ? 0 : (screenWidth - ame227_drawerW);
        [UIView animateWithDuration:0.32
                              delay:0
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.menuView.frame = CGRectMake(ame227_targetX, 0, ame227_drawerW, ame227_drawerH);
            [self ame248_alignMenuFrost];   // ★ Task248（⑨）：目标位对位随动画插值
            self.menuDimView.alpha = 1.0;
        } completion:^(BOOL finished) {
            [self ame248_alignMenuFrost];   // ★ Task248（⑨）：落位后精确对位
            [self setNeedsUpdateOfHomeIndicatorAutoHidden];
            [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
            [self setNeedsStatusBarAppearanceUpdate];
        }];
        return;
    }

    // 准备动画初始状态：菜单在屏幕底部外
    // ★ Task238（用户：“不贴边在中间打开菜单完全没有，只有层覆盖层”）：
    //   装机日志实锤根因——Task227 侧滑抽屉形态会把 menuView 的宽高改写成
    //   抽屉几何（400×屏高）并把 x 留在屏外；旧代码从【当前 frame】读
    //   menuWidth/menuHeight/origin.x（残留抽屉值）→ 悬浮形态的“底部弹层”
    //   整块被摆到屏外（日志：panel={{1180, -41}, {400, 820}}，1180 = 屏幕
    //   右缘）——只有遮罩可见，菜单本体完全不在屏内。
    //   修法：悬浮形态几何全部重算（与构造函数同源公式），不再信任残留帧。
    CGFloat ame238_sheetW = MIN(screenWidth * 0.7, 400);
    CGFloat ame238_sheetMaxH = screenHeight * 0.6;
    CGFloat ame238_sheetEstH = self.menuArray.count * 48 + 20;
    CGFloat ame238_sheetH = MIN(ame238_sheetEstH, ame238_sheetMaxH);
    self.menuView.frame = CGRectMake(
        (screenWidth - ame238_sheetW) / 2.0,   // 水平居中（不继承抽屉的屏外 x）
        screenHeight,                          // 屏幕底部外
        ame238_sheetW,
        ame238_sheetH
    );
    // ★ Task237：底部弹层形态几何回归构造值，重排行区（幂等）
    [self ame237_layoutMenuContent];

    // 计算目标位置：底部弹出，留出安全区域
    CGFloat safeBottom = [ScreenUtils safeAreaBottom];
    CGFloat targetY = screenHeight - ame238_sheetH - safeBottom - 16;

    // ★ Task252（反馈 10 配套：开启动画同步去平移）：开启时也不再从屏幕
    //   底部外全行程上滑（同样会拖着画面拷贝滑大半屏 = 打开瞬间“屏幕
    //   在滑”），改【原位微放大(1.08→1.0) + 淡入】——与关闭动画同语言，
    //   画面拷贝零位移。
    self.menuView.frame = CGRectMake(
        (screenWidth - ame238_sheetW) / 2.0,
        targetY,
        ame238_sheetW,
        ame238_sheetH
    );
    self.menuView.transform = CGAffineTransformMakeScale(1.08, 1.08);
    self.menuView.alpha = 0.0;

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        // 菜单原位浮现（零位移）
        self.menuView.transform = CGAffineTransformIdentity;
        self.menuView.alpha = 1.0;
        [self ame248_alignMenuFrost];   // ★ Task248（⑨）：对位（位置已定，无插值）
        // 背景遮罩淡入
        self.menuDimView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self ame248_alignMenuFrost];   // ★ Task248（⑨）：落位后精确对位
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

/// FCL 风格：菜单下滑消失（游戏画面不缩小）
- (void)dismissMenu {
    // ★ Task277：逻辑态置关 + 世代令牌推进——completion 仅在世代仍现任时
    //   才落 hidden=YES（否则 = 关闭期间被重新打开，面板交回 showMenu 管）。
    [self ame277_setMenuOpenState:NO];
    __block NSInteger ame277_gen = [self ame277_bumpMenuGeneration];
    // ★ Task282：同 showMenu——几何源改宿主实况口径。★ Task285：随宿主
    //   迁移改 menuCanvas.bounds（⊥ 转置逻辑口径）。
    CGFloat screenWidth = self.menuCanvas.bounds.size.width;
    CGFloat screenHeight = self.menuCanvas.bounds.size.height;

    // ★ Task250（反馈 10：恢复关闭动画）：摘掉 Task249 的“起步即摘快照”——
    //   快照瞬间消失 = 面板内容跳变（用户感知“动画没了”）。改为：磨砂快照
    //   保持 + 面板整体下滑同步淡出（alpha→0）——滑出中的面板是“带折射
    //   背景的菜单卡片”渐隐，既无“屏幕拷贝滑动”错觉（卡片在消失而非静止
    //   背景在移动），也保留了完整的视觉过渡（不再裸跳）。
    //   配合本轮状态栏/手势条恒定化（关闭期间零系统位移），关闭动画完整
    //   可见且不再牵动游戏画面。
    [self ame247_stopMenuSnapshotRefresh];   // 快照定格（滑出期间不再重抓）

    // ★ Task227：侧滑形态判定（showMenu 的侧边栏以 y=0 全高呈现）——
    // 收起时横向滑出吸边侧，而非下滑。
    BOOL ame227_sideDrawer = (CGRectGetMinY(self.menuView.frame) == 0.0 &&
                              CGRectGetHeight(self.menuView.frame) >= screenHeight * 0.9);

    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        if (ame227_sideDrawer) {
            BOOL ame227_fromLeft = (CGRectGetMinX(self.menuView.frame) <= 0.0);
            CGFloat ame227_offX = ame227_fromLeft
                ? -CGRectGetWidth(self.menuView.frame)
                : screenWidth;
            self.menuView.frame = CGRectMake(
                ame227_offX, 0,
                CGRectGetWidth(self.menuView.frame),
                CGRectGetHeight(self.menuView.frame)
            );
        } else {
            // ★ Task252（反馈 10 四修：悬浮形态“屏幕滑动”错觉终除）：
            //   Task251 的 28pt 短下沉装机反馈仍有滑动感——根因是任何
            //   位移都会带着面板内的窗口对位画面拷贝一起动（对位误差
            //   在 1:1 拷贝上被感知为“屏幕在滑”）。终案：悬浮形态关闭
            //   改【原位微收缩(0.96) + 淡出，零位移】——画面拷贝一个
            //   像素都不挪，“屏幕滑动”物理上不可能产生；收场动画依然
            //   完整（收缩+淡出双重过渡）。侧滑抽屉形态保持横向滑出
            //   （贴边语义，属用户预期）。
            self.menuView.transform =
                CGAffineTransformMakeScale(0.96, 0.96);
        }
        // ★ Task250：面板同步淡出（卡片化收场，不裸跳）
        self.menuView.alpha = 0.0;
        // 背景遮罩淡出
        self.menuDimView.alpha = 0.0;
    } completion:^(BOOL finished) {
        if ([self ame277_currentMenuGeneration] != ame277_gen) {
            NSLog(@"[GameMenu] Task277: dismiss completion stale (gen %ld != %ld) -- panel re-shown, skip hide",
                  (long)ame277_gen, (long)[self ame277_currentMenuGeneration]);
            return;   // 关闭动画期被重新打开：面板归 showMenu 管，不得藏
        }
        self.menuView.hidden = YES;
        self.menuDimView.hidden = YES;
        self.menuView.alpha = 1.0;   // ★ Task250：复位透明度（下次 showMenu 零残留）
        // ★ Task252：复位收缩变换（frame 复位靠 showMenu 重设 frame +
        //  transform 必须归零，否则下次出现时几何被 0.96 缩放污染）。
        self.menuView.transform = CGAffineTransformIdentity;
        // ★ Task285：关闭完成 → 容器交互关闭（空容器不拦截触摸，悬浮球/
        //   游戏触摸穿透；连点重开时 showMenu 会重新置 YES）。
        self.menuCanvas.userInteractionEnabled = NO;
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

- (void)setupCategory_Navigation {
    // FCL 风格：完全删除原来的右侧滑动调出菜单的方式
    // 不再注册 UIScreenEdgePanGestureRecognizer，菜单通过悬浮按钮触发
    // 保留空方法体，因为 SurfaceViewController.m 中通过 performSelector 调用
}

- (void)actionForceClose {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
        message:localize(@"game.menu.confirm.force_close", nil)
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:cancelAction];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
        // ★ [MP-RESTORE] Task222 联机恢复：强退前清理联机资源
        //   （ZeroTier 节点 / 陶瓦会话 / SOCKS5 / 端口转发）
        @try {
            [[MultiplayerManager sharedManager] stopAllMultiplayerServices];
            NSLog(@"[ForceClose] Multiplayer resources cleaned up");
        } @catch (NSException *e) {
            NSLog(@"[ForceClose] Exception while cleaning up multiplayer resources: %@", e);
        }

        // FCL 风格：直接退出，不再做缩小动画
        if (fatalExitGroup == nil) {
            exit(0);
        } else {
            dispatch_group_leave(fatalExitGroup);
        }
    }];
    [alert addAction:okAction];

    [self presentViewController:alert animated:YES completion:nil];
}

/// Task 64（恢复默认控件）：强制重建出厂布局并热重载。
/// 用户场景：旧布局在历史崩溃中写坏 / App 升级后模板换代，导致进游戏控件
/// 全部无反应。此入口删除 default.json 与 custom.json 后从出厂来源重建，
/// 并把激活布局指针复位为 default.json，最后热重载控件（无需重启游戏）。
- (void)actionRestoreDefaultControls {
    [self dismissMenu];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"game.menu.restore_default_controls", nil)
                          message:localize(@"game.menu.restore_default_controls.confirm", nil)
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *error = restoreDefaultCustomControl();
        if (error) {
            NSLog(@"[CustomControls] Task64 restore failed: %@", error);
            showDialog(localize(@"Error", nil), error);
            return;
        }
        // 热重载：与 actionOpenCustomControls 关闭编辑器后的重载路径一致
        // （removeAllButtons + loadCustomControls 会重新挂接 executebtn_* 触摸目标）
        [self.ctrlView removeAllButtons];
        [self loadCustomControls];
        NSLog(@"[CustomControls] Task64 in-game restore applied, controls reloaded");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenCustomControls {
    [self dismissMenu];
    [self.ctrlView removeAllButtons];
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        if (PLProfiles.current.selectedProfile[@"defaultTouchCtrl"]) {
            // Save default to current profile
            PLProfiles.current.selectedProfile[@"defaultTouchCtrl"] = name;
        } else {
            // Save default to preferences
            setPrefObject(@"control.default_ctrl", name);
        }
    };
    vc.getDefaultCtrl = ^{
        return [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    };
    // Task224（#16）：按键布局编辑器此前 animated:NO 裸切（用户反馈
    // “侧栏打开设置完全没动画”同族）。改为无动画呈现 + 尾缘滑入弹簧过渡
    // （与右栏方向语言一致；0.42s 不超过 0.45s 本轮动画预算）。
    [self presentViewController:vc animated:NO completion:^{
        UIView *ame224_editorView = vc.view;
        CGAffineTransform ame224_rest = ame224_editorView.transform;
        ame224_editorView.transform = CGAffineTransformTranslate(
            ame224_rest, ame224_editorView.bounds.size.width * 0.35, 0);
        ame224_editorView.alpha = 0.4;
        [UIView animateWithDuration:0.42 delay:0
             usingSpringWithDamping:0.85 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            ame224_editorView.transform = ame224_rest;
            ame224_editorView.alpha = 1.0;
        } completion:nil];
        NSLog(@"[ThemeOps] Task224 custom controls presented with trailing slide-in");
    }];
}

- (void)actionOpenPreferences {
    [self dismissMenu];
    // Task224（#16）：游戏内设置包上导航控制器（此前裸 present——设置页
    // 二级页的推入依赖 navigationController，裸呈现时全部静默失效）；
    // PageSheet 呈现保持系统动画（侧栏到目标页的标准模态语言）。
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    // ★ Task286：游戏内标记——设置页 viewWillDisappear 据此回调 presenter
    //   的 applyInGamePreferenceChanges（UI 安全面热应用；分辨率/FSR 保持
    //   "下次启动"语义）。旧刷新桥以 navigationController == nil 为前提，
    //   而本入口 Task224 起恒包 Navigation = 刷新桥在游戏内死路案发现场。
    vc.presentedInGame = YES;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
    NSLog(@"[ThemeOps] Task224 in-game settings presented (page sheet + nav wrapper)");
}

/// 游戏内打开联机界面（陶瓦联机，与 HMCL/FCL/ZL2 互通）
///
/// 对标 FCL 流程：启动游戏后通过悬浮球菜单进入联机界面，
/// 选择当房主（创建世界→开放局域网→输入端口→生成邀请码）
/// 或当房客（输入邀请码→加入网络→MC 多人游戏直连 127.0.0.1:25565）。
- (void)actionOpenMultiplayer {
    // ★ [MP-RESTORE] Task222 联机恢复：游戏内 modal 呈现（TVC 的 modal 分支
    //   自带系统 Close 按钮，dismiss 即回游戏；与上游 FCL 流程一致）。
    [self dismissMenu];
    if (![TerracottaBridge isAvailable]) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"i18n_str_320", nil)
                              message:localize(@"i18n_str_321", nil)
                       preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    TerracottaViewController *vc = [[TerracottaViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

/// FCL 风格：隐藏/显示控制按钮（对应 FCL hide_all 开关）
- (void)actionToggleControls {
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

/// FCL 风格：切换虚拟鼠标（对应 FCL 鼠标分组 / ZL2 ControlMouse）
- (void)actionToggleVirtualMouse {
    if (!isGrabbing) {
        virtualMouseEnabled = !virtualMouseEnabled;
        self.mousePointerView.hidden = !virtualMouseEnabled;
        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
}

/// FCL 风格：打开/关闭游戏内键盘（对应 FCL open_quick_input / ZL2 input_method）
- (void)actionToggleKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
        self.inputTextField.alpha = 1.0f;
    } else {
        [self.inputTextField becomeFirstResponder];
        self.inputTextField.text = @" ";
    }
}

/// FCL/ZL2 风格：调整游戏分辨率（对应 FCL window_scale / ZL2 resolutionRatio）
- (void)actionAdjustResolution {
    // ★ Task240：换装系统原生 UIMenu（旧 actionSheet 退役；锚定常驻的
    // 齿轮悬浮球，避免面板关闭后锚点失效）。

    NSArray *options = @[@25, @50, @75, @100, @125, @150];
    // Task186（分辨率调节失效根修）：Task159 实例化后生效链（updateSavedResolution）
    // 读 profile 键 resolution（[PLProfiles resolveKeyForCurrentProfile:]，
    // profile 固化显式值后全局 video.resolution 即被无视——版本设置页首次保存
    // 即固化），而本菜单旧代码读写全局键 → 游戏内调节永远无效、✓ 标记与实际
    // 生效值脱节。修法：读写全部对齐 profile 层（与生效链同源）。
    NSInteger currentValue = [PLProfiles resolveKeyForCurrentProfile:@"resolution"].integerValue;
    if (currentValue <= 0) currentValue = 100;
    NSMutableArray<NSDictionary *> *ame240_items = [NSMutableArray array];
    for (NSNumber *value in options) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value.intValue];
        if (value.intValue == currentValue) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [ame240_items addObject:@{
            @"title": title,
            @"handler": ^{
            // Task186：写当前实例的 resolution 键（setServerIp 同款 mutableCopy
            // 写回模式，updateSavedResolution 立即可见——PLProfiles.current 同一
            // 内存对象，无需重建）；
            NSString *ame186_profileName = PLProfiles.current.selectedProfileName;
            if (ame186_profileName.length > 0) {
                NSMutableDictionary *ame186_profile = [PLProfiles.current.profiles[ame186_profileName] mutableCopy];
                if (!ame186_profile) ame186_profile = [NSMutableDictionary dictionary];
                ame186_profile[@"resolution"] = [NSString stringWithFormat:@"%ld", (long)value.intValue];
                PLProfiles.current.profiles[ame186_profileName] = ame186_profile;
                [PLProfiles.current save];
                NSLog(@"[Task186] in-game resolution: profile '%@' resolution -> %ld%% (was %ld%%)",
                      ame186_profileName, (long)value.intValue, (long)currentValue);
            }
            // 兼容镜像：JavaGUI（executeJar 窗口，无实例上下文）4 处仍读全局
            // video.resolution（Task159 注释明确的保留设计），保持旧全局写入
            // 不回归其行为。
            setPrefFloat(@"video.resolution", value.floatValue);
            // Task187（分辨率触摸错位根修）：不再【立即】调用 updateSavedResolution。
            // 病历（8cca75a 用户反馈"分辨率调节触摸输入不正常"）：updateSavedResolution
            // 是全量几何重算——运行中调用会同步改写 surface/drawableSize/contentsScale
            // 与 windowWidth/Height 全局，但 MC 的窗口信念（launchJVM 启动时告知的
            // 窗口尺寸）在本进程内【不可变】：
            //   1) EGL 表面被缩到新尺寸而 MC 仍按旧尺寸渲染（拉伸/裁切）；
            //   2) sendTouchPoint 的 Task175 公式按新 resolutionScale 换算触点，
            //      MC 仍按旧窗口信念归一化 → 触点整体偏移 1/旧比例（实测病灶）。
            // 修法：菜单只写偏好（键值已即时落盘），下一次 launchJVM 周期
            // updateSavedResolution 自然以新值建表面/窗口/输入三口径一致的
            // 会话。当前会话保持既有几何不动（触摸与渲染完全自洽）。
            if (value.intValue != currentValue) {
                [NMToast showMessage:localize(@"game.menu.resolution.next_launch", nil)];
            }
            NSLog(@"[Task187] in-game resolution saved %ld%% -- geometry applies next launch (in-session resize would desync MC window belief + touch mapping)",
                  (long)value.intValue);
            },
        }];
    }

    // ★ Task240：系统 UIMenu 呈现。
    [AmeNativeMenu ame240_presentMenuWithTitle:localize(@"game.menu.resolution", nil)
                                     dictItems:ame240_items
                                    sourceView:self.gameMenuOverlay ?: self.view];
}

- (void)actionOpenNavigationMenu {
    // FCL 风格：游戏内自定义按键的 SPECIALBTN_MENU 也触发底部弹出菜单
    [self toggleMenu];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    // ★ Task250（反馈 10：菜单明明悬浮在屏幕上方，关闭时屏幕却会滑动 根修）：
    //   旧实现随菜单开合翻转（菜单开=0/关=底部+右）——翻转触发系统手势条
    //   /安全区重评估，全屏内容随开合位移 = “屏幕滑动”。恒定后开合零位移，
    //   关闭动画回归“面板卡片滑出”。
    return UIRectEdgeBottom | UIRectEdgeRight;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    // ★ Task250：不再随菜单开合翻转（翻转 = 手势条显隐动画 + 安全区重评估
    //   = 屏幕位移；恒定化后关闭动画期间零系统级位移）。
    return getPrefBool(@"debug.debug_hide_home_indicator");
}

- (BOOL)prefersStatusBarHidden {
    // ★ Task250：游戏内恒定隐藏（旧实现随菜单开合翻转——iPad 横屏下状态
    //   栏显隐改写 safeAreaInsets，关闭菜单瞬间全屏内容位移 = “屏幕滑动”
    //   的主源；恒定隐藏后开合零位移，且游戏沉浸性更佳）。
    return YES;
}

// ★ Task237：UITableView 数据源/委托六方法（numberOfRows / cellForRow /
// heightForRow / didSelectRow / didHighlight / didUnhighlight）随菜单面板
// 重写整体退役——菜单行是 Ame237MenuRow 控件（点击走 ame237_gmRowTouched:，
// 按压反馈由行控件自带），动作分发 didSelectMenuItem: 保持不变。

- (void)didSelectMenuItem:(int)item {
    switch (item) {
        case 0: // 强制关闭
            [self actionForceClose];
            break;
        case 1: // 日志输出
            [self.logOutputView actionToggleLogOutput];
            break;
        case 2: // 按键布局编辑
            [self actionOpenCustomControls];
            break;
        case 3: // Task 64: 恢复默认控件
            [self actionRestoreDefaultControls];
            break;
        case 4: // 联机（陶瓦联机 Terracotta，与 HMCL/FCL/ZL2 互通；右上角可切换到 ZeroTier）
            [self actionOpenMultiplayer];
            break;
        case 5: // FPS/内存显示开关
            if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
                [(GameMenuOverlayView *)self.gameMenuOverlay toggleStatsLabel];
            }
            break;
        case 6: // 隐藏/显示控制按钮
            [self actionToggleControls];
            break;
        case 7: // 虚拟鼠标开关
            [self actionToggleVirtualMouse];
            break;
        case 8: // 游戏内键盘
            [self actionToggleKeyboard];
            break;
        case 9: // 分辨率调整
            [self actionAdjustResolution];
            break;
        case 10: // 设置
            [self actionOpenPreferences];
            break;
    }
}

- (void)viewWillTransitionToSize_Navigation:(CGRect)frame {
    // FCL 风格：菜单从底部弹出，旋转时重新计算 frame
    // ★ Task285：几何源随宿主迁移改 menuCanvas.bounds——⊥ 态容器已是转
    //   置逻辑口径，菜单按逻辑口径重排 = 与游戏内容同向；外层传入的
    //   frame（物理口径）不再直接消费。
    CGFloat screenWidth = self.menuCanvas.bounds.size.width;
    CGFloat screenHeight = self.menuCanvas.bounds.size.height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 20;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    if (!self.menuView.hidden) {
        // 菜单可见时，更新到新的目标位置
        CGFloat safeBottom = [ScreenUtils safeAreaBottom];
        CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            targetY,
            menuWidth,
            menuHeight
        );
    } else {
        // 菜单不可见时，保持在屏幕底部外
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            screenHeight,
            menuWidth,
            menuHeight
        );
    }
    // ★ Task237：旋转后面板几何变更，行区/滚动内容随之重排
    [self ame237_layoutMenuContent];
    // 更新遮罩 frame
    self.menuDimView.frame = CGRectMake(0, 0, screenWidth, screenHeight);
}

@end
