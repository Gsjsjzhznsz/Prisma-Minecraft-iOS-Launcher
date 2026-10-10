#import "CustomControlsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "GameMenuOverlayView.h"
#import "LiquidGlassCompat.h"   // Task229: floating menu composite glass
#import "AmeFloatingMenu.h"     // ★ Task237：菜单行控件与统一悬浮菜单组件
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

@interface SurfaceViewController(Navigation)
// FCL 风格菜单的背景遮罩（半透明黑色，点击关闭菜单）
@property(nonatomic) UIView *menuDimView;
@end

@implementation SurfaceViewController(Navigation)

- (void)setMenuDimView:(UIView *)menuDimView {
    objc_setAssociatedObject(self, kMenuDimViewKey, menuDimView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIView *)menuDimView {
    return objc_getAssociatedObject(self, kMenuDimViewKey);
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
    CGFloat screenWidth = [ScreenUtils screenSize].width;
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 20;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

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
    [self.view addSubview:self.menuView];

    // 行滚动区（唯一内容层；玻璃层永远在其下）
    UIScrollView *ame237_rowsScroll = [[UIScrollView alloc] init];
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
    self.menuDimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.menuDimView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4];
    self.menuDimView.alpha = 0;
    self.menuDimView.hidden = YES;
    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissMenu)];
    dimTap.cancelsTouchesInView = YES;
    [self.menuDimView addGestureRecognizer:dimTap];
    [self.view addSubview:self.menuDimView];
    // 确保菜单在遮罩之上
    [self.view bringSubviewToFront:self.menuView];

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
    if (LGCIsGlassStyleActive()) {
        // 液态玻璃面板：SystemMaterialDark（Task230 游戏帧可读性教训）
        UIVisualEffectView *ame237_blur = [[UIVisualEffectView alloc]
            initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        ame237_blur.frame = self.menuView.bounds;
        ame237_blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ame237_blur.userInteractionEnabled = NO;
        ame237_blur.layer.cornerRadius = 24.0;
        ame237_blur.layer.cornerCurve = kCACornerCurveContinuous;
        ame237_blur.layer.masksToBounds = YES;
        [self.menuView insertSubview:ame237_blur atIndex:0];
        objc_setAssociatedObject(self, kAme237BlurKey, ame237_blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (ame237_scroll != nil) [self.menuView bringSubviewToFront:ame237_scroll];
        // 防御性深色实底：磨砂在游戏帧上不合成时独立承载面板可见性
        //   （Task236 教训；此处底色只由本函数管理，永不清空）
        self.menuView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.62];
        self.menuView.layer.cornerRadius = 24.0;
        self.menuView.layer.cornerCurve = kCACornerCurveContinuous;
        self.menuView.layer.borderWidth = 0.75;
        self.menuView.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
        for (Ame237MenuRow *ame237_row in ame237_rows) {
            ame237_row.showsIcon = YES;
            [ame237_row setNeedsLayout];
        }
        NSLog(@"[GameMenu] Task237 glass panel applied (frosted + defensive dark base + hairline; rows above blur; icon rows)");
    } else {
        // 原生 = 旧版 FCL 面板（深色半透明、纯文本行）
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
}

/// Task237：菜单行点击（与旧 tableView:didSelectRowAtIndexPath: 同一动作链）。
- (void)ame237_gmRowTouched:(Ame237MenuRow *)sender {
    [self didSelectMenuItem:(int)sender.tag];
}

- (void)ame229_handleBackgroundUIEffectChanged {
    [self ame237_applyMenuStyle];
    [self ame237_layoutMenuContent];
}

/// 切换菜单显示状态（悬浮按钮点击触发）
- (void)toggleMenu {
    if (self.menuView.hidden) {
        [self showMenu];
    } else {
        [self dismissMenu];
    }
}

/// FCL 风格：从底部弹出菜单（游戏画面不缩小）
/// ★ Task227（反馈 #8）：齿轮吸边成把手时，菜单改从吸边侧滑出（侧边栏
/// 形态）；悬浮球形态保持原底部弹层。
- (void)showMenu {
    BOOL ame227_sideDrawer = NO;
    BOOL ame227_fromLeft = NO;
    if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
        GameMenuOverlayView *ame227_ov = (GameMenuOverlayView *)self.gameMenuOverlay;
        ame227_sideDrawer = ame227_ov.isDocked;
        ame227_fromLeft = ame227_ov.dockedLeft;
    }

    self.menuView.hidden = NO;
    self.menuDimView.hidden = NO;

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

    CGFloat screenWidth = [ScreenUtils screenSize].width;
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuWidth = self.menuView.frame.size.width;
    CGFloat menuHeight = self.menuView.frame.size.height;
    self.menuView.transform = CGAffineTransformIdentity;

    if (ame227_sideDrawer) {
        // 侧滑形态：全高面板从吸边侧滑入（宽度取原菜单宽，最小 280）
        CGFloat ame227_drawerW = MAX(menuWidth, 280);
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
            self.menuDimView.alpha = 1.0;
        } completion:^(BOOL finished) {
            [self setNeedsUpdateOfHomeIndicatorAutoHidden];
            [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
            [self setNeedsStatusBarAppearanceUpdate];
        }];
        return;
    }

    // 准备动画初始状态：菜单在屏幕底部外
    self.menuView.frame = CGRectMake(
        self.menuView.frame.origin.x,
        screenHeight,  // 屏幕底部外
        menuWidth,
        menuHeight
    );
    // ★ Task237：底部弹层形态几何回归构造值，重排行区（幂等）
    [self ame237_layoutMenuContent];

    // 计算目标位置：底部弹出，留出安全区域
    CGFloat safeBottom = [ScreenUtils safeAreaBottom];
    CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        // 菜单上滑到目标位置
        self.menuView.frame = CGRectMake(
            self.menuView.frame.origin.x,
            targetY,
            self.menuView.frame.size.width,
            menuHeight
        );
        // 背景遮罩淡入
        self.menuDimView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

/// FCL 风格：菜单下滑消失（游戏画面不缩小）
- (void)dismissMenu {
    CGFloat screenWidth = [ScreenUtils screenSize].width;
    CGFloat screenHeight = [ScreenUtils screenSize].height;

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
            // 菜单下滑到屏幕底部外
            self.menuView.frame = CGRectMake(
                self.menuView.frame.origin.x,
                screenHeight,
                self.menuView.frame.size.width,
                self.menuView.frame.size.height
            );
        }
        // 背景遮罩淡出
        self.menuDimView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.menuView.hidden = YES;
        self.menuDimView.hidden = YES;
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"game.menu.resolution", nil)
                                                                   message:localize(@"game.menu.resolution.message", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *options = @[@25, @50, @75, @100, @125, @150];
    // Task186（分辨率调节失效根修）：Task159 实例化后生效链（updateSavedResolution）
    // 读 profile 键 resolution（[PLProfiles resolveKeyForCurrentProfile:]，
    // profile 固化显式值后全局 video.resolution 即被无视——版本设置页首次保存
    // 即固化），而本菜单旧代码读写全局键 → 游戏内调节永远无效、✓ 标记与实际
    // 生效值脱节。修法：读写全部对齐 profile 层（与生效链同源）。
    NSInteger currentValue = [PLProfiles resolveKeyForCurrentProfile:@"resolution"].integerValue;
    if (currentValue <= 0) currentValue = 100;
    for (NSNumber *value in options) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value.intValue];
        if (value.intValue == currentValue) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenNavigationMenu {
    // FCL 风格：游戏内自定义按键的 SPECIALBTN_MENU 也触发底部弹出菜单
    [self toggleMenu];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    if (!self.menuView.hidden) {
        return 0;
    }
    return UIRectEdgeBottom | UIRectEdgeRight;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return self.menuView.hidden &&
        getPrefBool(@"debug.debug_hide_home_indicator");
}

- (BOOL)prefersStatusBarHidden {
    return self.menuView.hidden;
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
    CGFloat screenWidth = frame.size.width;
    CGFloat screenHeight = frame.size.height;
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
