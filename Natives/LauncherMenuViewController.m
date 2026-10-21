#import "LauncherMenuViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherPreferences.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "PLProfiles.h"
#import "BackgroundManager.h"
#import "PrismaUI.h" // Task314：PrismaUI 设计系统令牌（7.0 UI 架构试点第一屏）
#import "utils.h"

@interface LauncherMenuViewController ()

@property(nonatomic, strong) UIView *sidebarView;
@property(nonatomic, strong) UIStackView *menuStackView;
@property(nonatomic, strong) NSArray<NSDictionary *> *menuItems;
@property(nonatomic, assign) NSInteger selectedIndex;
// Task102：主界面图标首启自愈重试定时器（全部图标就绪或达上限即停）
@property(nonatomic, strong) NSTimer *menuIconSelfHealTimer;

@end

@implementation LauncherMenuViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 即使本控制器在 LauncherRootViewController 中作为子 VC 添加，仍需在自身 viewDidLoad 中调用。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 监听外观变更（字体颜色变化时刷新菜单按钮颜色）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // 菜单项配置
    // 联机相关入口暂不显示（需进一步完善）
    // case 3 为"联机"（陶瓦联机 Terracotta，与 HMCL/FCL/ZL2 互通）
    // case 4 为"ZeroTier 联机"（独立入口，与陶瓦联机并列，便于用户直接进入 ZeroTier 界面）
    // case 5 为"设置"
    // case 6 为"使用问题"（Task 82：FAQ 标签页，收录渲染/输入/安装/故障排除常见问题）
    // 键位调整界面已移到设置页面中
    self.menuItems = @[
        @{@"icon": @"house.fill", @"title": @" ", @"index": @0},
        @{@"icon": @"arrow.down.circle.fill", @"title": @" ", @"index": @1},
        @{@"icon": @"sparkles", @"title": @" ", @"index": @2},
        @{@"icon": @"puzzlepiece.fill", @"title": @" ", @"index": @3},
        // 暂时移除两个联机图标，恢复时取消下方两行注释并将设置项 index 顺延
        // @{@"icon": @"antenna.radiowaves.left.and.right", @"title": @" ", @"index": @4},
        // @{@"icon": @"network", @"title": @" ", @"index": @5},
        @{@"icon": @"gearshape.fill", @"title": @" ", @"index": @4},
        @{@"icon": @"questionmark.circle.fill", @"title": @" ", @"index": @5}
    ];
    
    self.selectedIndex = 0;
    
    [self setupSidebar];
}

#pragma mark - UI Setup

- (void)setupSidebar {
    self.sidebarView = [[UIView alloc] init];
    self.sidebarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.sidebarView];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.sidebarView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.sidebarView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    // 创建垂直均分的 UIStackView，替代固定偏移布局。
    // 之前用 startY=60 + 固定间距 15，5 个按钮总高 370pt，在 iPhone 横屏（卡片高度不足）
    // 时第 5 个按钮（设置）被卡片 masksToBounds 裁剪，且按钮只锚定 top 无 bottom 约束，
    // 下方留出大块空白加剧"下面空隙大"的观感。
    // 改用 UIStackView EqualSpacing 让按钮在可用空间内垂直均匀分布，上下留白相同，
    // 无论卡片高度如何都能完整显示所有按钮，且消除固定 startY 导致的下方空白。
    self.menuStackView = [[UIStackView alloc] init];
    self.menuStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.menuStackView.axis = UILayoutConstraintAxisVertical;
    self.menuStackView.distribution = UIStackViewDistributionEqualSpacing;
    self.menuStackView.alignment = UIStackViewAlignmentCenter;
    self.menuStackView.spacing = 8;
    [self.sidebarView addSubview:self.menuStackView];

    CGFloat buttonSize = 50;
    for (NSInteger i = 0; i < self.menuItems.count; i++) {
        NSDictionary *item = self.menuItems[i];
        UIButton *btn = [self createMenuButtonWithItem:item index:i];
        [self.menuStackView addArrangedSubview:btn];
        [NSLayoutConstraint activateConstraints:@[
            [btn.widthAnchor constraintEqualToConstant:buttonSize],
            [btn.heightAnchor constraintEqualToConstant:buttonSize]
        ]];
    }

    [NSLayoutConstraint activateConstraints:@[
        [self.menuStackView.leadingAnchor constraintEqualToAnchor:self.sidebarView.leadingAnchor],
        [self.menuStackView.trailingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor],
        [self.menuStackView.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:8],
        [self.menuStackView.bottomAnchor constraintEqualToAnchor:self.sidebarView.bottomAnchor constant:-8],
        [self.menuStackView.centerXAnchor constraintEqualToAnchor:self.sidebarView.centerXAnchor]
    ]];
}

- (UIButton *)createMenuButtonWithItem:(NSDictionary *)item index:(NSInteger)index {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    btn.tag = index;

    // 设置图标（Task101：仅图标按钮，无文字；图标在 50×50 按钮内居中，
    // 与新拟物高亮面板几何中心对齐）
    // Task111：冷启动首次 systemImageNamed: 偶发 nil（CoreUI 符号注册竞态），
    // 创建时立即二次补拉（首次调用本身会完成注册，第二次同刻拿到非 nil），
    // 与后续重试自愈双保险。
    NSString *iconName = item[@"icon"];
    UIImage *icon = [UIImage systemImageNamed:iconName];
    if (!icon) {
        icon = [UIImage systemImageNamed:iconName];
    }
    [btn setImage:icon forState:UIControlStateNormal];

    // 设置颜色 - 选中项高亮
    // 支持自定义字体颜色：用户在设置中配置 general.text_color 后，
    // 未选中项使用自定义颜色，选中项保持高亮蓝色
    UIColor *normalColor = [self menuNormalColor];
    UIColor *accent = accentColor();
    if (index == self.selectedIndex) {
        btn.tintColor = accent;
    } else {
        btn.tintColor = normalColor;
    }

    // 图标居中（Task101：原 imageEdgeInsets(-10,0,0,0)+空白标题的
    // 图标在上文字在下布局退役——菜单项标题本就是空格 " "，
    // 原偏移让图标偏离高亮面板中心，用户实测"高亮和图标有点偏差"）
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    btn.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;

    // Task111：z 序保险——图标子视图存在时显式提到最前，两种绘制路径下
    // 都保证可见。幂等、无副作用（Task137 保留：高亮背景回归后无害）。
    UIView *iconView = btn.imageView;
    if (iconView && iconView.superview == btn) {
        [btn bringSubviewToFront:iconView];
    }
    
    [btn addTarget:self action:@selector(menuButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

    // 统一圆角：防御性设置 10pt，避免后续给选中态加背景高亮时出现直角方块
    btn.layer.cornerRadius = 10;
    // Task137：新拟态退役——初始选中项直接应用原生 accent 半透明高亮
    // （选中态在 updateButtonColors 维护）
    if (index == self.selectedIndex) {
        // Task314：选中态底色收敛 PrismaTheme 令牌（同值 accent 15%）
        btn.backgroundColor = [PrismaTheme colorAccentSelectedBackground];
    }

    return btn;
}

#pragma mark - Actions

// Task101：菜单图标自愈——启动早期偶发 systemImageNamed: 拿到 nil
// （用户实测：左上角主界面 house.fill 图标有时刚打开软件时消失，
// 二次启动恢复正常，典型时序型 nil）。
// Task111：拆成两条路径——
//  ① 填充式（稳态路径：updateButtonColors/applyCustomAppearance）仅补 nil，
//     幂等零抖动；
//  ② 强制式（首启自愈窗口内）无条件重取重设——CoreUI 竞态除直接返回 nil
//     外，还可能返回不可正常渲染的哑图（非 nil 但不显示，填充式会被
//     imageForState != nil 误判已就绪）；重设新获取的 UIImage 强制重渲染。
- (void)refreshMenuIconImages {
    [self refreshMenuIconImagesForced:NO];
}

- (void)refreshMenuIconImagesForced:(BOOL)forced {
    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *btn = (UIButton *)view;
        NSInteger idx = btn.tag;
        if (idx < 0 || idx >= (NSInteger)self.menuItems.count) continue;
        UIImage *current = [btn imageForState:UIControlStateNormal];
        if (!forced && current) continue;
        NSString *iconName = self.menuItems[idx][@"icon"];
        UIImage *icon = [UIImage systemImageNamed:iconName];
        if (!icon) continue;
        if (forced || !current) {
            [btn setImage:icon forState:UIControlStateNormal];
            // 重设后保证图标子视图在最前（同 createMenuButton 的 z 序保险）
            UIView *iconView = btn.imageView;
            if (iconView && iconView.superview == btn) {
                [btn bringSubviewToFront:iconView];
            }
        }
    }
}

// Task102：根因收窄——主界面按钮是 setupSidebar 循环里第一个调
// systemImageNamed: 的控件，进程冷启动首调用存在 CoreUI 符号注册竞态：
// 首调用偶尔拿到 nil，后续调用全部正常，所以症状总是“只有主界面消失，
// 其他按钮都在”。Task101 的单次 viewWillAppear 补拉仍在同一竞态窗口内
// （viewDidLoad 与 viewWillAppear 几乎同刻执行），用户实测仍能复现。
// Task111：重试窗口 0.25s×16（4s）→ 0.25s×40（10s），且每个 tick 用
// 强制式重设（见 refreshMenuIconImagesForced:）覆盖哑图情形；即使图标全部
// 非 nil，前 8 个 tick（2s）仍继续强制重刷，之后稳态提前退出，零开销。
- (BOOL)allMenuIconsLoaded {
    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if (![view isKindOfClass:[UIButton class]]) continue;
        UIButton *btn = (UIButton *)view;
        NSInteger idx = btn.tag;
        if (idx < 0 || idx >= (NSInteger)self.menuItems.count) continue;
        if (![btn imageForState:UIControlStateNormal]) return NO;
    }
    return YES;
}

- (void)beginMenuIconSelfHeal {
    // 先立即强制重刷一次（绝大多数情况到这一步就已恢复）
    [self refreshMenuIconImagesForced:YES];
    if (self.menuIconSelfHealTimer) return; // 重试已在跑，不叠加
    __weak typeof(self) weakSelf = self;
    __block NSInteger attempts = 0;
    NSTimer *timer = [NSTimer timerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { [t invalidate]; return; }
        [strongSelf refreshMenuIconImagesForced:YES];
        attempts += 1;
        // 图标齐备且过了 8 个强制重刷 tick（哑图重渲染窗口）即停；
        // 最多 40 个 tick（10s）兜底
        if (([strongSelf allMenuIconsLoaded] && attempts >= 8) || attempts >= 40) {
            [strongSelf.menuIconSelfHealTimer invalidate];
            strongSelf.menuIconSelfHealTimer = nil;
        }
    }];
    self.menuIconSelfHealTimer = timer;
    // CommonModes：滚动/追踪时也照常触发，不遗漏
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self beginMenuIconSelfHeal];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Task102：首布局比 viewWillAppear 更晚一拍，再多给一次自愈入口；
    // 全部就绪时 beginMenuIconSelfHeal 内部直接返回，零开销
    [self beginMenuIconSelfHeal];
}

- (void)menuButtonTapped:(UIButton *)sender {
    NSInteger index = sender.tag;

    // FCL 风格：选中菜单项时添加弹跳动画（ScaleX/ScaleY 弹跳，OvershootInterpolator 效果）
    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.5
          initialSpringVelocity:0.8
                        options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        sender.transform = CGAffineTransformMakeScale(1.2, 1.2);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.2
                              delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            sender.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];

    // 更新选中状态
    self.selectedIndex = index;
    [self updateButtonColors];

    // 回调
    NSString *title = self.menuItems[index][@"title"];
    if (self.onMenuItemSelected) {
        self.onMenuItemSelected(index, title);
    }

    // 处理导航
    [self handleMenuSelection:index];
}

- (void)updateButtonColors {
    UIColor *normalColor = [self menuNormalColor];
    UIColor *accent = accentColor();
    // Task138：选中态着色包一层 0.18s 淡入——切换标签页时图标配色
    // 平滑过渡，替代原本的瞬时硬切（动效优化，语义不变）。
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut animations:^{
        [self ame138_applyButtonColors:normalColor accent:accent];
    } completion:nil];
}

/// Task138：updateButtonColors 的实际着色体（从原实现抽出，供动画块调用）
- (void)ame138_applyButtonColors:(UIColor *)normalColor accent:(UIColor *)accent {
    // Task101：顺手补拉缺失图标（幂等，仅填 nil）
    [self refreshMenuIconImages];
    // 按钮现在在 menuStackView.arrangedSubviews 中（UIStackView 重构后）
    for (UIView *view in self.menuStackView.arrangedSubviews) {
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *btn = (UIButton *)view;
            NSInteger index = btn.tag;

            if (index == self.selectedIndex) {
                btn.tintColor = accent;
                // Task101：按钮无标题（纯图标），仅剩图标着色，原 setTitleColor 分支退场
                // Task137：新拟态退役——选中项回归原生 accent 半透明高亮
                // （Task89 之前的样式）；幂等重刷（重复调用安全）
                // Task314：底色收敛 PrismaTheme 令牌（同值 accent 15%）
                btn.backgroundColor = [PrismaTheme colorAccentSelectedBackground];
                // Task111：z 序保险——把图标子视图提回最前（幂等保留）
                UIView *iconView = btn.imageView;
                if (iconView && iconView.superview == btn) {
                    [btn bringSubviewToFront:iconView];
                }
            } else {
                btn.tintColor = normalColor;
                // 未选中项恢复无底色
                btn.backgroundColor = [UIColor clearColor];
            }
        }
    }
}

// 字体颜色变更时刷新所有菜单按钮
- (void)applyCustomAppearance {
    [self updateButtonColors];
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
}

- (void)dealloc {
    // Task102：自愈重试定时器随控制器释放而停止（block 弱引用 self，无循环持有，
    // 但 runloop 对已调度 timer 的强持有需要显式 invalidate）
    [self.menuIconSelfHealTimer invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// 未选中菜单项的颜色：优先使用用户自定义的 general.text_color，否则默认 systemGray
- (UIColor *)menuNormalColor {
    NSString *hex = getPrefObject(@"general.text_color");
    if (hex.length > 0) {
        UIColor *custom = [self colorFromHexString:hex];
        if (custom) return custom;
    }
    // Task314：系统默认色迁 PrismaTheme 令牌（明暗双态跟随系统）——
    // 原 systemGrayColor 单值在深色模式下偏亮，token 化后观感与全应用一致
    return [PrismaTheme colorTextSecondary];
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int r, g, b, a = 255;
    if (hex.length == 6) {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        b = r & 0xFF;
        g = (r >> 8) & 0xFF;
        r = (r >> 16) & 0xFF;
    } else {
        [[NSScanner scannerWithString:hex] scanHexInt:&r];
        a = r & 0xFF;
        b = (r >> 8) & 0xFF;
        g = (r >> 16) & 0xFF;
        r = (r >> 24) & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
}

- (void)handleMenuSelection:(NSInteger)index {
    switch (index) {
        case 0: // 主页
            // 通知父控制器切换到新闻页
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHomePage" object:nil];
            break;

        case 1: // 下载
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
            break;

        case 2: // AI 助手
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAIPage" object:nil];
            break;

        case 3: // 版本管理（合并了原"当前版本设置"功能）
            [self showVersionManager];
            break;

        case 4: // 设置（联机入口暂时移除，恢复时顺延 index）
            [self showSettings];
            break;

        case 5: // 使用问题（Task 82：FAQ 页）
            [self showHelpPage];
            break;
    }
}

- (void)showVersionManager {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)showMultiplayer {
    // 发送通知让 LauncherRootViewController 显示陶瓦联机界面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowMultiplayer" object:nil];
}

- (void)showZeroTier {
    // 发送通知让 LauncherRootViewController 显示 ZeroTier 联机界面
    // ZeroTier 与陶瓦联机为并列的两套联机方案，独立菜单入口避免用户先进入陶瓦再切换。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowZeroTier" object:nil];
}

- (void)showSettings {
    // 发送通知让 LauncherRootViewController 在中间内容区显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowSettings" object:nil];
}

- (void)showHelpPage {
    // Task 82：发送通知让 LauncherRootViewController 在中间内容区显示"使用问题"FAQ 页
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHelpPage" object:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    // 账户信息在右侧面板显示，这里不需要处理
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end
