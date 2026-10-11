//
//  TerracottaViewController.m
//  Amethyst
//
//  Terracotta multiplayer UI, modelled on FoldCraftLauncher's multiplayer
//  module: a state-driven flow where every phase gets its own view, an
//  invite-code card that copies itself, and a player list.
//
//  Flow
//    menu        -- two large action cards: create room / join room
//    hostForm    -- port input. Auto-detection (log tail + local scan) is on by
//                   default, so in practice the user only presses one button.
//    detecting   -- waiting for the game to print the LAN port
//    joinForm    -- invite code entry with live validation
//    session     -- driven by TerracottaManager: connecting / ok / error
//
//  New i18n keys used by this screen (en + zh):
//    i18n_str_2091/2092/2093 (上游 2068-2070 重映射，本地 Task220 已占用) +
//    i18n_str_2072 .. i18n_str_2090
//

#import "TerracottaViewController.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "LanPortDetector.h"
#import "LauncherPreferences.h"
#import "utils.h"
#import "BackgroundManager.h"
#import "MultiplayerViewController.h"
#import "SurfaceViewController.h"   // ★ Task248（⑧）：+surface 取游戏呈现面做快照磨砂
#import "LiquidGlassCompat.h"       // ★ Task248（⑧）：玻璃家族档位判定
#import "AmeLiquidGlassView.h"  // ★ Task252：TG 玻璃材料升级整页磨砂（滤镜栈供料）
#import <objc/runtime.h>            // ★ Task248（⑧）：objc_get/setAssociatedObject（CI r1 编译雷）

typedef NS_ENUM(NSInteger, TCUIState) {
    TCUIStateMenu      = 0,  /* 两张大卡片：创建 / 加入 */
    TCUIStateHostForm  = 1,  /* 端口表单（默认自动检测） */
    TCUIStateDetecting = 2,  /* 等待 MC 打印 LAN 端口 */
    TCUIStateJoinForm  = 3,  /* 邀请码表单 */
    TCUIStateSession   = 4,  /* 会话已建立，由 TerracottaManager 驱动 */
};

@interface TerracottaViewController () <UITextFieldDelegate>

@property(nonatomic, strong) UIScrollView *scrollView;
@property(nonatomic, strong) UIStackView *mainStack;

/* 顶部状态卡 */
@property(nonatomic, strong) UIView *headerCard;
@property(nonatomic, strong) UIImageView *statusIcon;
@property(nonatomic, strong) UILabel *statusTitle;
@property(nonatomic, strong) UILabel *statusSubtitle;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;

/* 状态切换容器 */
@property(nonatomic, strong) UIView *stageView;
@property(nonatomic, copy) NSArray<NSLayoutConstraint *> *stageConstraints;

/* menu */
@property(nonatomic, strong) UIView *menuView;

/* hostForm */
@property(nonatomic, strong) UIView *hostFormView;
@property(nonatomic, strong) UISwitch *autoSwitch;
@property(nonatomic, strong) UITextField *portField;
@property(nonatomic, strong) UILabel *portHintLabel;
@property(nonatomic, strong) UIButton *scanButton;

/* detecting */
@property(nonatomic, strong) UIView *detectingView;
@property(nonatomic, strong) UILabel *detectingHintLabel;

/* joinForm */
@property(nonatomic, strong) UIView *joinFormView;
@property(nonatomic, strong) UITextField *codeField;
@property(nonatomic, strong) UILabel *codeHintLabel;

/* session */
@property(nonatomic, strong) UIView *sessionView;
@property(nonatomic, strong) UIView *infoCard;
@property(nonatomic, strong) UILabel *infoTitleLabel;
@property(nonatomic, strong) UILabel *infoValueLabel;
@property(nonatomic, strong) UIButton *infoCopyButton;
@property(nonatomic, strong) UILabel *infoDescLabel;
@property(nonatomic, strong) UIStackView *playersStack;
@property(nonatomic, strong) UIButton *leaveButton;

@property(nonatomic, assign) TCUIState uiState;
/// ★ Task248（④联机菜单完全无法点击 回归根修）：实际在位舞台类型。
///   Task247 T4 的幂等短路用 `target == self.uiState` 判定，但本文件全部
///   状态迁移处理器（createRoomTapped/joinRoomTapped/startHostTapped/
///   scanPortsTapped/cancelDetectingTapped/confirmJoinTapped/
///   createRoomWithPort/leaveTapped）都是【先直写 self.uiState = target
///   再调 updateForCurrentState】——短路条件恒真，舞台永不切换 = 用户
///   点任何卡片都无反应（"联机菜单完全无法点击"）。改用独立记录的
///   builtStage 与 target 比较：处理器预写 uiState 不影响 builtStage，
///   迁移照常拆装；TerracottaManager/LanPortDetector 回调（未预写）
///   到来时 builtStage == target → 短路 = T4 的键盘保护语义保留。
@property(nonatomic, assign) TCUIState ame248_builtStage;
@property(nonatomic, assign) BOOL didAutoCopyCode;
@property(nonatomic, strong) UILabel *toastLabel;

@end

@implementation TerracottaViewController

// ★ Task250：动态磨砂刷新 display link 关联键（ame250_start/stopFrostRefresh
//   在文件前部使用，定义置顶避免前向引用）。
static const void *kAme250FrostLinkKey = &kAme250FrostLinkKey;
// ★ Task252：表单态自动武装幂等键（createRoomTapped 路径与 autoSwitchChanged
//   路径共用——必须在文件作用域；方法内 static 局部各自独立变量，两处键
//   地址不同会导致卸武装清不到武装标记）。
static const void *kAme252ArmedKey = &kAme252ArmedKey;

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.uiState = TCUIStateMenu;

    [self setupDismissHandling];
    [self setupZeroTierButton];

    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // ★ Task252（反馈 9/12）：玻璃家族档 + OverFullScreen 呈现（磁贴联机
    //   入口在本轮改为玻璃条件分支）→ 无系统 dim，自铺轻遮罩（黑 0.18）
    //   保内容可读，壁纸经 ame160 玻璃底透出 = 伪玻璃面板观感；原生档
    //   （PageSheet）系统自带 dim，零改动（"用回原生"）。
    if (LGCIsGlassStyleActive() &&
        self.navigationController != nil &&
        self.navigationController.modalPresentationStyle == UIModalPresentationOverFullScreen &&
        [BackgroundManager sharedManager].blurIntensity > 0.01) {
        /* ★ Task256：模糊程度最低档（≤1%）= 背景完全透明 —— 连轻 dim 也不铺
           （与壁纸 frost/磨砂页同口径；清单 4）。 */
        UIView *ame252_dim = [[UIView alloc] initWithFrame:self.view.bounds];
        ame252_dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ame252_dim.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.18];
        ame252_dim.userInteractionEnabled = NO;
        ame252_dim.tag = 25100;
        [self.view insertSubview:ame252_dim atIndex:0];
        NSLog(@"[TVC] Task252: glass-style OverFullScreen dim applied");
    }
    // ★ Task252（反馈 9 二修取证）：历轮装机截图（IMG_0400）显示联机页仍
    //   呈原生 sheet 观感，但历轮日志均无呈现路径记录（本轮之前此分支
    //   零日志 = 取证盲区）。下一轮 gamelog 直接读出解析风格与呈现方式。
    NSLog(@"[TVC] Task252: viewDidLoad resolvedStyle=%ld glass=%d pseudo=%d navPresentation=%ld presenting=%d",
          (long)LGCResolvedInterfaceStyle(),
          LGCIsGlassStyleActive() ? 1 : 0,
          LGCIsPseudoGlassStyleActive() ? 1 : 0,
          (long)(self.navigationController != nil
                     ? self.navigationController.modalPresentationStyle : -1),
          self.presentingViewController != nil ? 1 : 0);

    [self setupViews];
    [self registerNotifications];
    [self updateForCurrentState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self applyNavigationBarVisibilityForAppearance];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    [self applyBackgroundEffects];
    // ★ Task252（反馈 7 五修：进主机表单页自动武装扫描）：历轮修复都把
    //   扫描挂在用户点"开始检测/立即扫描"之后（gamelog 实锤：世界开服
    //   75s 后才点检测，随即取消——"自动扫描"从未真正自动）。装机实测
    //   用户流 = 先开世界 → 进联机页 → 期待端口已自动填好。修法：主机
    //   表单态 + 自动开关在 + 无已检端口 时，进页即起周期回环扫描 +
    //   日志尾随（命中经 portDidDetect: 回填 portField，与手动路径同
    //   收口；扫描 3s/tick 常驻，成本可忽略）。幂等：LanPortDetector
    //   start 端已在扫时静默换绑，不重复起线程。
    if (self.uiState == TCUIStateHostForm &&
        self.autoSwitch.on &&
        [LanPortDetector sharedInstance].detectedPort == 0) {
        NSLog(@"[TVC] Task252: host form appearing with auto-switch ON and no port -- arming background auto-detection");
        [[LanPortDetector sharedInstance] startAutoDetection];
        [[LanPortDetector sharedInstance] restartLoopbackScanRepeatingWithProgress:nil];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self applyNavigationBarVisibilityForDisappearance];
    // ★ Task252：离页清伪玻璃快照缓存（源视图生命周期不越页持有）。
    ame252_cachedPseudoBase = nil;
    ame252_cachedPseudoSrc = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // ★ Task250：动态磨砂刷新退场（防 display link 持脱脏 VC）。
    [self ame250_stopFrostRefresh];
}

#pragma mark - Task250 动态磨砂刷新（反馈 9）

// ★ Task250（反馈 9：一些位置仍用原生界面而非伪液态玻璃）：Task248 ⑧的
//   磨砂快照是【一次性】抓帧——开服/世界加载/移动视角后背景永远停在开
//   菜单那一刻的静帧，观感退回“静态贴图”而非魔改玻璃。移植
//   Task246/247 同款 8Hz 重抓（快照源 surfaceView 纯游戏画面 + 全黑帧
//   护栏；原生档/启动器呈现自动短路退场）。
- (void)ame250_startFrostRefresh {
    if (objc_getAssociatedObject(self, kAme250FrostLinkKey) != nil) return;
    CADisplayLink *ame250_link = [CADisplayLink displayLinkWithTarget:self
                                                             selector:@selector(ame250_frostTick)];
    if (@available(iOS 10.0, *)) {
        ame250_link.preferredFramesPerSecond = 8;   // Task246/247 同款 8Hz
    }
    [ame250_link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    objc_setAssociatedObject(self, kAme250FrostLinkKey, ame250_link,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[TVC] Task250: dynamic frost refresh engaged (8Hz)");
}

- (void)ame250_stopFrostRefresh {
    CADisplayLink *ame250_link = objc_getAssociatedObject(self, kAme250FrostLinkKey);
    if (ame250_link != nil) {
        [ame250_link invalidate];
        objc_setAssociatedObject(self, kAme250FrostLinkKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

- (void)ame250_frostTick {
    if (!LGCIsGlassStyleActive()) {
        [self ame250_stopFrostRefresh];
        return;
    }
    UIView *ame250_surface = [SurfaceViewController surface];
    if (ame250_surface == nil || ame250_surface.window == nil || self.view.window == nil) {
        // 启动器呈现 / 会话退场：快照失效面，刷新自停（静态壁纸管线接管）。
        [self ame250_stopFrostRefresh];
        return;
    }
    [self ame248_applyGlassFrostBackground];   // 内部自抓新帧 + 全黑帧护栏
}

#pragma mark - Navigation chrome

/// 三种呈现方式区别对待，保证任何入口都能退出：
/// ① pushed（栈里非根）⇒ 交给系统返回键
/// ② modal 根 ⇒ 注入系统关闭按钮
/// ③ 非 modal 的 nav 根 ⇒ 隐藏导航栏（启动器内容区整页呈现）
- (void)setupDismissHandling {
    BOOL isPushed = (self.navigationController &&
                     self.navigationController.viewControllers.count > 1 &&
                     self.navigationController.viewControllers.firstObject != self);
    BOOL isHiddenRoot = (self.navigationController &&
                         self.navigationController.viewControllers.count == 1 &&
                         self.navigationController.presentingViewController == nil &&
                         self.navigationController.viewControllers.firstObject == self);
    if (isHiddenRoot) {
        self.navigationController.navigationBarHidden = YES;
        // ★ [MP-RESTORE] Task222：容器整页呈现（隐藏导航栏）时注入左上角浮动
        //   关闭按钮——与右上角 ZeroTier 浮钮对称，保证本模式也能退出
        //   （close 的容器分支走 ShowHomePage 通知切回主页）。
        UIButton *closeFab = [UIButton buttonWithType:UIButtonTypeSystem];
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration
            configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
        [closeFab setImage:[UIImage systemImageNamed:@"chevron.down" withConfiguration:cfg]
                  forState:UIControlStateNormal];
        closeFab.tintColor = [UIColor whiteColor];
        closeFab.backgroundColor = [UIColor systemBlueColor];
        closeFab.layer.cornerRadius = 18;
        closeFab.layer.masksToBounds = YES;
        closeFab.translatesAutoresizingMaskIntoConstraints = NO;
        closeFab.accessibilityLabel = localize(@"resman.common.cancel", nil);
        [closeFab addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:closeFab];
        [self.view bringSubviewToFront:closeFab];
        [NSLayoutConstraint activateConstraints:@[
            [closeFab.widthAnchor constraintEqualToConstant:36],
            [closeFab.heightAnchor constraintEqualToConstant:36],
            [closeFab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
            [closeFab.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
        ]];
    }
    if (!isPushed && !isHiddenRoot) {
        UIBarButtonItem *closeItem = [[UIBarButtonItem alloc]
            initWithBarButtonSystemItem:UIBarButtonSystemItemClose
                                 target:self
                                 action:@selector(close)];
        self.navigationItem.leftBarButtonItem = closeItem;
    }
}

- (void)applyNavigationBarVisibilityForAppearance {
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
    }
    if (self.navigationController &&
        self.navigationController.viewControllers.count > 1 &&
        self.navigationController.viewControllers.firstObject != self &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = NO;
    }
}

- (void)applyNavigationBarVisibilityForDisappearance {
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
    if (self.navigationController &&
        self.navigationController.viewControllers.count > 1 &&
        self.navigationController.viewControllers.firstObject != self) {
        self.navigationController.navigationBarHidden = YES;
    }
}

/// ZeroTier 旧方案入口（浮动按钮，两种方案并存）
- (void)setupZeroTierButton {
    UIButton *ztFab = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold];
    [ztFab setImage:[UIImage systemImageNamed:@"network" withConfiguration:cfg] forState:UIControlStateNormal];
    ztFab.tintColor = [UIColor whiteColor];
    ztFab.backgroundColor = [UIColor systemBlueColor];
    ztFab.layer.cornerRadius = 18;
    ztFab.layer.masksToBounds = YES;
    ztFab.translatesAutoresizingMaskIntoConstraints = NO;
    ztFab.accessibilityLabel = localize(@"i18n_str_1007", nil);
    [ztFab addTarget:self action:@selector(switchToZeroTier:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:ztFab];
    [self.view bringSubviewToFront:ztFab];
    [NSLayoutConstraint activateConstraints:@[
        [ztFab.widthAnchor constraintEqualToConstant:36],
        [ztFab.heightAnchor constraintEqualToConstant:36],
        [ztFab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [ztFab.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    ]];
}

#pragma mark - Root layout

- (void)setupViews {
    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.alwaysBounceVertical = YES;
    // ★ Task249（用户反馈 3：联机菜单输入一次键盘就关闭一次——残存根因）：
    //   OnDrag = 滚动视图一旦开始拖拽就收起键盘。本页在 PageSheet 里，键盘
    //   弹起时 sheet 收缩/内容自动滚动，手指微动即被判定为拖拽 = 键盘随
    //   意外收起（全仓唯一一处 OnDrag，其余滚动视图均为 Interactive/无）。
    //   改 None：收起走回车键/扫码按钮等显式路径，表单页内容短，不拖拽收。
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    self.scrollView.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.scrollView];

    self.mainStack = [[UIStackView alloc] init];
    self.mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.mainStack.axis = UILayoutConstraintAxisVertical;
    self.mainStack.spacing = 14;
    self.mainStack.alignment = UIStackViewAlignmentFill;
    [self.scrollView addSubview:self.mainStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        [self.mainStack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:16],
        [self.mainStack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:16],
        [self.mainStack.trailingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.trailingAnchor constant:-16],
        [self.mainStack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [self.mainStack.widthAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.widthAnchor constant:-32],
    ]];

    self.headerCard = [self buildHeaderCard];
    [self.mainStack addArrangedSubview:self.headerCard];

    self.stageView = [[UIView alloc] init];
    self.stageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.stageView.backgroundColor = [UIColor clearColor];
    [self.mainStack addArrangedSubview:self.stageView];
}

- (UIView *)buildHeaderCard {
    UIView *card = [self makeCard];

    self.statusIcon = [[UIImageView alloc] init];
    self.statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusIcon.contentMode = UIViewContentModeScaleAspectFit;
    self.statusIcon.tintColor = [UIColor systemGrayColor];
    [card addSubview:self.statusIcon];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.spinner.hidesWhenStopped = YES;
    [card addSubview:self.spinner];

    self.statusTitle = [self makeLabelWithFont:[UIFont systemFontOfSize:19 weight:UIFontWeightSemibold] color:[UIColor labelColor]];
    [card addSubview:self.statusTitle];

    self.statusSubtitle = [self makeLabelWithFont:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    self.statusSubtitle.numberOfLines = 0;
    [card addSubview:self.statusSubtitle];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusIcon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.statusIcon.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [self.statusIcon.widthAnchor constraintEqualToConstant:38],
        [self.statusIcon.heightAnchor constraintEqualToConstant:38],

        [self.spinner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.spinner.centerYAnchor constraintEqualToAnchor:self.statusIcon.centerYAnchor],

        [self.statusTitle.leadingAnchor constraintEqualToAnchor:self.statusIcon.trailingAnchor constant:10],
        [self.statusTitle.centerYAnchor constraintEqualToAnchor:self.statusIcon.centerYAnchor],
        [self.statusTitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],

        [self.statusSubtitle.topAnchor constraintEqualToAnchor:self.statusIcon.bottomAnchor constant:10],
        [self.statusSubtitle.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [self.statusSubtitle.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [self.statusSubtitle.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
    ]];
    return card;
}

#pragma mark - Stage views

- (UIView *)buildMenuView {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [container addSubview:stack];

    UIView *hostCard = [self makeActionCardWithIcon:@"antenna.radiowaves.left.and.right"
                                             title:localize(@"i18n_str_1008", nil)
                                          subtitle:localize(@"i18n_str_2091", nil)
                                            action:@selector(createRoomTapped:)];
    UIView *guestCard = [self makeActionCardWithIcon:@"person.2.fill"
                                              title:localize(@"i18n_str_1009", nil)
                                           subtitle:localize(@"i18n_str_2092", nil)
                                             action:@selector(joinRoomTapped:)];
    [stack addArrangedSubview:hostCard];
    [stack addArrangedSubview:guestCard];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
    ]];
    return container;
}

- (UIView *)buildHostFormView {
    UIView *card = [self makeCard];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [card addSubview:stack];

    /* 自动检测开关行 */
    UIView *autoRow = [[UIView alloc] init];
    autoRow.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *autoTitle = [self makeLabelWithFont:[UIFont systemFontOfSize:16 weight:UIFontWeightMedium] color:[UIColor labelColor]];
    autoTitle.text = localize(@"i18n_str_2093", nil);
    [autoRow addSubview:autoTitle];

    self.autoSwitch = [[UISwitch alloc] init];
    self.autoSwitch.translatesAutoresizingMaskIntoConstraints = NO;
    self.autoSwitch.on = YES;
    [self.autoSwitch addTarget:self action:@selector(autoSwitchChanged:) forControlEvents:UIControlEventValueChanged];
    [autoRow addSubview:self.autoSwitch];

    [NSLayoutConstraint activateConstraints:@[
        [autoTitle.leadingAnchor constraintEqualToAnchor:autoRow.leadingAnchor],
        [autoTitle.centerYAnchor constraintEqualToAnchor:autoRow.centerYAnchor],
        [autoTitle.trailingAnchor constraintEqualToAnchor:self.autoSwitch.leadingAnchor constant:-12],
        [self.autoSwitch.trailingAnchor constraintEqualToAnchor:autoRow.trailingAnchor],
        [self.autoSwitch.centerYAnchor constraintEqualToAnchor:autoRow.centerYAnchor],
        [autoRow.heightAnchor constraintEqualToConstant:36],
    ]];

    self.portField = [self makeTextFieldWithPlaceholder:localize(@"i18n_str_1011", nil)
                                           keyboardType:UIKeyboardTypeNumberPad];
    self.portField.delegate = self;
    /* 默认走自动检测，输入框只作为"检测到的端口"的展示位 */
    self.portField.enabled = NO;

    self.portHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    self.portHintLabel.numberOfLines = 0;
    self.portHintLabel.text = localize(@"i18n_str_2073", nil);

    self.scanButton = [self makeSecondaryButtonWithTitle:localize(@"i18n_str_2076", nil)
                                                  action:@selector(scanPortsTapped:)];

    UIButton *startButton = [self makePrimaryButtonWithTitle:localize(@"i18n_str_2084", nil)
                                                      action:@selector(startHostTapped:)];

    UIButton *backButton = [self makeSecondaryButtonWithTitle:localize(@"i18n_str_2080", nil)
                                                       action:@selector(backToMenuTapped:)];

    [stack addArrangedSubview:autoRow];
    [stack addArrangedSubview:self.portField];
    [stack addArrangedSubview:self.portHintLabel];
    [stack addArrangedSubview:self.scanButton];
    [stack addArrangedSubview:startButton];
    [stack addArrangedSubview:backButton];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [self.portField.heightAnchor constraintEqualToConstant:44],
        [self.scanButton.heightAnchor constraintEqualToConstant:44],
        [startButton.heightAnchor constraintEqualToConstant:50],
        [backButton.heightAnchor constraintEqualToConstant:44],
    ]];
    return card;
}

- (UIView *)buildDetectingView {
    UIView *card = [self makeCard];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    stack.alignment = UIStackViewAlignmentCenter;
    [card addSubview:stack];

    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [stack addArrangedSubview:indicator];

    UILabel *title = [self makeLabelWithFont:[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold] color:[UIColor labelColor]];
    title.text = localize(@"i18n_str_2072", nil);
    title.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:title];

    self.detectingHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    self.detectingHintLabel.numberOfLines = 0;
    self.detectingHintLabel.textAlignment = NSTextAlignmentCenter;
    self.detectingHintLabel.text = localize(@"i18n_str_2073", nil);
    [stack addArrangedSubview:self.detectingHintLabel];

    UIButton *cancel = [self makeSecondaryButtonWithTitle:localize(@"i18n_str_2080", nil)
                                                   action:@selector(cancelDetectingTapped:)];
    [stack addArrangedSubview:cancel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-24],
        [cancel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [cancel.heightAnchor constraintEqualToConstant:44],
    ]];
    return card;
}

- (UIView *)buildJoinFormView {
    UIView *card = [self makeCard];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [card addSubview:stack];

    self.codeField = [self makeTextFieldWithPlaceholder:localize(@"i18n_str_1013", nil)
                                           keyboardType:UIKeyboardTypeDefault];
    self.codeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.codeField.delegate = self;
    [self.codeField addTarget:self action:@selector(codeFieldChanged:) forControlEvents:UIControlEventEditingChanged];

    self.codeHintLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    self.codeHintLabel.numberOfLines = 0;
    self.codeHintLabel.text = localize(@"i18n_str_2088", nil);

    UIButton *join = [self makePrimaryButtonWithTitle:localize(@"i18n_str_1009", nil)
                                              action:@selector(confirmJoinTapped:)];
    UIButton *back = [self makeSecondaryButtonWithTitle:localize(@"i18n_str_2080", nil)
                                                action:@selector(backToMenuTapped:)];

    [stack addArrangedSubview:self.codeField];
    [stack addArrangedSubview:self.codeHintLabel];
    [stack addArrangedSubview:join];
    [stack addArrangedSubview:back];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:18],
        [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
        [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [self.codeField.heightAnchor constraintEqualToConstant:44],
        [join.heightAnchor constraintEqualToConstant:50],
        [back.heightAnchor constraintEqualToConstant:44],
    ]];
    return card;
}

- (UIView *)buildSessionView {
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;

    UIStackView *stack = [[UIStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
    [container addSubview:stack];

    /* 邀请码 / 直连地址卡片 */
    self.infoCard = [self makeCard];
    self.infoTitleLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    [self.infoCard addSubview:self.infoTitleLabel];

    self.infoValueLabel = [self makeLabelWithFont:[UIFont fontWithName:@"Menlo" size:17]
                                            color:[UIColor labelColor]];
    self.infoValueLabel.numberOfLines = 0;
    self.infoValueLabel.textAlignment = NSTextAlignmentCenter;
    [self.infoCard addSubview:self.infoValueLabel];

    self.infoCopyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.infoCopyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.infoCopyButton setTitle:localize(@"i18n_str_2081", nil) forState:UIControlStateNormal];
    self.infoCopyButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.infoCopyButton addTarget:self action:@selector(copyInfoValue:) forControlEvents:UIControlEventTouchUpInside];
    [self.infoCard addSubview:self.infoCopyButton];

    self.infoDescLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:12] color:[UIColor secondaryLabelColor]];
    self.infoDescLabel.numberOfLines = 0;
    self.infoDescLabel.textAlignment = NSTextAlignmentCenter;
    [self.infoCard addSubview:self.infoDescLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.infoTitleLabel.topAnchor constraintEqualToAnchor:self.infoCard.topAnchor constant:16],
        [self.infoTitleLabel.leadingAnchor constraintEqualToAnchor:self.infoCard.leadingAnchor constant:18],
        [self.infoTitleLabel.trailingAnchor constraintEqualToAnchor:self.infoCard.trailingAnchor constant:-18],

        [self.infoValueLabel.topAnchor constraintEqualToAnchor:self.infoTitleLabel.bottomAnchor constant:10],
        [self.infoValueLabel.leadingAnchor constraintEqualToAnchor:self.infoCard.leadingAnchor constant:18],
        [self.infoValueLabel.trailingAnchor constraintEqualToAnchor:self.infoCard.trailingAnchor constant:-18],

        [self.infoCopyButton.topAnchor constraintEqualToAnchor:self.infoValueLabel.bottomAnchor constant:12],
        [self.infoCopyButton.centerXAnchor constraintEqualToAnchor:self.infoCard.centerXAnchor],

        [self.infoDescLabel.topAnchor constraintEqualToAnchor:self.infoCopyButton.bottomAnchor constant:10],
        [self.infoDescLabel.leadingAnchor constraintEqualToAnchor:self.infoCard.leadingAnchor constant:18],
        [self.infoDescLabel.trailingAnchor constraintEqualToAnchor:self.infoCard.trailingAnchor constant:-18],
        [self.infoDescLabel.bottomAnchor constraintEqualToAnchor:self.infoCard.bottomAnchor constant:-16],
    ]];

    UILabel *playersTitle = [self makeLabelWithFont:[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]
                                              color:[UIColor labelColor]];
    playersTitle.text = localize(@"i18n_str_1014", nil);

    self.playersStack = [[UIStackView alloc] init];
    self.playersStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.playersStack.axis = UILayoutConstraintAxisVertical;
    self.playersStack.spacing = 8;
    self.playersStack.alignment = UIStackViewAlignmentFill;

    self.leaveButton = [self makeSecondaryButtonWithTitle:localize(@"i18n_str_694", nil)
                                                   action:@selector(leaveTapped:)];
    [self.leaveButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];

    [stack addArrangedSubview:self.infoCard];
    [stack addArrangedSubview:playersTitle];
    [stack addArrangedSubview:self.playersStack];
    [stack addArrangedSubview:self.leaveButton];

    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [self.leaveButton.heightAnchor constraintEqualToConstant:48],
    ]];
    return container;
}

#pragma mark - Component helpers

- (UIView *)makeCard {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor clearColor];
    card.layer.cornerRadius = 20;
    card.layer.masksToBounds = YES;
    return card;
}

- (UILabel *)makeLabelWithFont:(UIFont *)font color:(UIColor *)color {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = font;
    label.textColor = color;
    return label;
}

- (UITextField *)makeTextFieldWithPlaceholder:(NSString *)placeholder
                                 keyboardType:(UIKeyboardType)keyboardType {
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.keyboardType = keyboardType;
    field.font = [UIFont systemFontOfSize:16];
    field.backgroundColor = [UIColor clearColor];
    field.layer.cornerRadius = 10;
    field.clipsToBounds = YES;
    return field;
}

- (UIButton *)makePrimaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    btn.backgroundColor = accentColor();
    btn.layer.cornerRadius = 14;
    btn.layer.masksToBounds = YES;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (UIButton *)makeSecondaryButtonWithTitle:(NSString *)title action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    btn.layer.cornerRadius = 14;
    btn.layer.borderWidth = 1;
    btn.layer.borderColor = [UIColor tertiaryLabelColor].CGColor;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

/// FCL 风格的大操作卡片：图标 + 标题 + 副标题 + 箭头，整块可点
- (UIView *)makeActionCardWithIcon:(NSString *)iconName
                             title:(NSString *)title
                          subtitle:(NSString *)subtitle
                            action:(SEL)action {
    UIView *card = [self makeCard];

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightSemibold];
    icon.image = [UIImage systemImageNamed:iconName withConfiguration:cfg];
    icon.tintColor = accentColor();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [card addSubview:icon];

    UILabel *titleLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
                                            color:[UIColor labelColor]];
    titleLabel.text = title;
    [card addSubview:titleLabel];

    UILabel *subLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:13] color:[UIColor secondaryLabelColor]];
    subLabel.text = subtitle;
    subLabel.numberOfLines = 0;
    [card addSubview:subLabel];

    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *smallCfg = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold];
    chevron.image = [UIImage systemImageNamed:@"chevron.right" withConfiguration:smallCfg];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    [card addSubview:chevron];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [icon.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:30],
        [icon.heightAnchor constraintEqualToConstant:30],

        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [titleLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],

        [subLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [subLabel.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:14],
        [subLabel.trailingAnchor constraintEqualToAnchor:chevron.leadingAnchor constant:-8],
        [subLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],

        [chevron.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [chevron.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [chevron.widthAnchor constraintEqualToConstant:12],
    ]];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:action];
    [card addGestureRecognizer:tap];
    card.accessibilityLabel = title;
    return card;
}

#pragma mark - State switching

- (void)updateForCurrentState {
    TerracottaManager *mgr = [TerracottaManager shared];
    BOOL sessionActive = (mgr.status != TerracottaStatusDisconnected);

    TCUIState target = self.uiState;
    if (sessionActive) target = TCUIStateSession;
    if (target == TCUIStateSession && !sessionActive) target = TCUIStateMenu;

    // ★ Task247（T4 联机菜单输入一次键盘就关闭一次 根修）：幂等短路。
    // 本方法每次都整台拆除 stageView 子视图再重装——舞台内的 first
    // responder（codeField/portField）随 removeFromSuperview 被打断；
    // 而 TerracottaManager 状态回调 / LanPortDetector 进度回调 / 分享码
    // 轮询在打字期间每次触发都走到这里 = 键盘随任意后台事件收起一次。
    // 目标态未变且舞台已在位时不再拆装，只做轻量内容刷新（端口回填）；
    // 状态真正迁移时才走拆除-重建。
    // ★ Task248（④）：幂等判定改用 ame248_builtStage（实际在位舞台），
    //   不再比较被处理器预写过的 self.uiState——详见证性注释见类扩展。
    if (target == self.ame248_builtStage && self.stageView.subviews.count > 0) {
        if (target == TCUIStateHostForm) {
            uint16_t ame247_known = [LanPortDetector sharedInstance].detectedPort;
            // Task248：回填只在自动模式生效——手动输入端口的用户在打字期间
            // 后台回调触发短路刷新时，detectedPort 不得覆盖用户正在输入的值。
            if (ame247_known > 0 && self.autoSwitch.on) {
                self.portField.text = [NSString stringWithFormat:@"%u", ame247_known];
                self.portHintLabel.text = [NSString stringWithFormat:localize(@"i18n_str_2074", nil), ame247_known];
            }
        }
        [self updateHeader];
        if (target == TCUIStateSession) {
            [self updateSessionContent];
        }
        return;
    }

    for (UIView *sub in self.stageView.subviews) {
        [sub removeFromSuperview];
    }
    if (self.stageConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.stageConstraints];
        self.stageConstraints = nil;
    }

    UIView *stage = nil;
    switch (target) {
        case TCUIStateMenu:      stage = [self viewForMenu]; break;
        case TCUIStateHostForm:  stage = [self viewForHostForm]; break;
        case TCUIStateDetecting: stage = [self viewForDetecting]; break;
        case TCUIStateJoinForm:  stage = [self viewForJoinForm]; break;
        case TCUIStateSession:   stage = [self viewForSession]; break;
    }
    self.uiState = target;
    self.ame248_builtStage = target;   // ★ Task248（④）：记录实际在位舞台

    if (stage == nil) return;
    [self.stageView addSubview:stage];
    NSArray<NSLayoutConstraint *> *constraints = @[
        [stage.topAnchor constraintEqualToAnchor:self.stageView.topAnchor],
        [stage.leadingAnchor constraintEqualToAnchor:self.stageView.leadingAnchor],
        [stage.trailingAnchor constraintEqualToAnchor:self.stageView.trailingAnchor],
        [stage.bottomAnchor constraintEqualToAnchor:self.stageView.bottomAnchor],
    ];
    [NSLayoutConstraint activateConstraints:constraints];
    self.stageConstraints = constraints;

    [self updateHeader];
    if (target == TCUIStateSession) {
        [self updateSessionContent];
    }
    [self applyBackgroundEffects];
}

- (UIView *)viewForMenu {
    if (self.menuView == nil) self.menuView = [self buildMenuView];
    return self.menuView;
}

- (UIView *)viewForHostForm {
    if (self.hostFormView == nil) self.hostFormView = [self buildHostFormView];
    uint16_t known = [LanPortDetector sharedInstance].detectedPort;
    if (known > 0) {
        self.portField.text = [NSString stringWithFormat:@"%u", known];
        self.portHintLabel.text = [NSString stringWithFormat:localize(@"i18n_str_2074", nil), known];
    }
    return self.hostFormView;
}

- (UIView *)viewForDetecting {
    if (self.detectingView == nil) self.detectingView = [self buildDetectingView];
    return self.detectingView;
}

- (UIView *)viewForJoinForm {
    if (self.joinFormView == nil) self.joinFormView = [self buildJoinFormView];
    return self.joinFormView;
}

- (UIView *)viewForSession {
    if (self.sessionView == nil) self.sessionView = [self buildSessionView];
    return self.sessionView;
}

- (void)updateHeader {
    TerracottaManager *mgr = [TerracottaManager shared];

    NSString *title;
    NSString *subtitle;
    NSString *iconName;
    UIColor *tint;

    if (self.uiState == TCUIStateSession) {
        switch (mgr.status) {
            case TerracottaStatusConnecting:
                title = (mgr.role == TerracottaRoleHost) ? localize(@"i18n_str_2046", nil) : localize(@"i18n_str_1031", nil);
                subtitle = mgr.stageDescription ?: @"";
                iconName = @"arrow.triangle.2.circlepath";
                tint = [UIColor systemOrangeColor];
                break;
            case TerracottaStatusConnected:
                title = (mgr.role == TerracottaRoleHost) ? localize(@"i18n_str_2047", nil) : localize(@"i18n_str_1006", nil);
                subtitle = mgr.stageDescription ?: @"";
                iconName = @"checkmark.seal.fill";
                tint = [UIColor systemGreenColor];
                break;
            case TerracottaStatusError:
                title = localize(@"i18n_str_1033", nil);
                subtitle = mgr.lastError ?: localize(@"i18n_str_2087", nil);
                iconName = @"exclamationmark.triangle.fill";
                tint = [UIColor systemRedColor];
                break;
            default:
                title = localize(@"i18n_str_1029", nil);
                subtitle = @"";
                iconName = @"antenna.radiowaves.left.and.right.slash";
                tint = [UIColor systemGrayColor];
                break;
        }
    } else {
        title = localize(@"i18n_str_1029", nil);
        subtitle = localize(@"i18n_str_2075", nil);
        iconName = @"antenna.radiowaves.left.and.right.slash";
        tint = [UIColor systemGrayColor];
    }

    self.statusTitle.text = title;
    self.statusSubtitle.text = subtitle;
    self.statusIcon.tintColor = tint;

    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightMedium];
    self.statusIcon.image = [UIImage systemImageNamed:iconName withConfiguration:cfg];

    if (self.uiState == TCUIStateSession && mgr.status == TerracottaStatusConnecting) {
        [self.spinner startAnimating];
    } else {
        [self.spinner stopAnimating];
    }
}

- (void)updateSessionContent {
    TerracottaManager *mgr = [TerracottaManager shared];

    BOOL isHost = (mgr.role == TerracottaRoleHost);
    if (isHost) {
        self.infoTitleLabel.text = localize(@"i18n_str_2089", nil);
        NSString *code = mgr.currentInviteCode ?: @"";
        self.infoValueLabel.text = code;
        self.infoDescLabel.text = localize(@"i18n_str_2082", nil);
        [self.infoCopyButton setTitle:localize(@"i18n_str_2081", nil) forState:UIControlStateNormal];

        /* 房主就绪时自动复制一次邀请码（对齐 FCL 的行为） */
        if (mgr.status == TerracottaStatusConnected && code.length > 0 && !self.didAutoCopyCode) {
            self.didAutoCopyCode = YES;
            [UIPasteboard generalPasteboard].string = code;
            [self showToast:localize(@"i18n_str_2082", nil)];
        }
    } else {
        self.infoTitleLabel.text = localize(@"i18n_str_2090", nil);
        self.infoValueLabel.text = mgr.directConnectURL ?: @"";
        self.infoDescLabel.text = localize(@"i18n_str_2083", nil);
        [self.infoCopyButton setTitle:localize(@"i18n_str_2081", nil) forState:UIControlStateNormal];
        if (mgr.status == TerracottaStatusConnected && mgr.directConnectURL.length > 0 && !self.didAutoCopyCode) {
            self.didAutoCopyCode = YES;
            [UIPasteboard generalPasteboard].string = mgr.directConnectURL;
            [self showToast:localize(@"i18n_str_1019", nil)];
        }
    }

    [self refreshPlayersList:mgr.players role:mgr.role];
}

- (void)refreshPlayersList:(NSArray<TerracottaPlayerProfile *> *)players
                      role:(TerracottaRole)role {
    for (UIView *v in self.playersStack.arrangedSubviews) {
        [self.playersStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (players.count == 0) {
        UILabel *empty = [self makeLabelWithFont:[UIFont systemFontOfSize:13]
                                           color:[UIColor tertiaryLabelColor]];
        empty.text = (role == TerracottaRoleHost) ? localize(@"i18n_str_2045", nil) : localize(@"i18n_str_1026", nil);
        [self.playersStack addArrangedSubview:empty];
        return;
    }
    for (TerracottaPlayerProfile *profile in players) {
        [self.playersStack addArrangedSubview:[self makePlayerRow:profile role:role]];
    }
}

- (UIView *)makePlayerRow:(TerracottaPlayerProfile *)profile role:(TerracottaRole)myRole {
    UIView *row = [self makeCard];
    row.layer.cornerRadius = 12;

    UIImageView *avatar = [[UIImageView alloc] init];
    avatar.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightRegular];
    avatar.image = [UIImage systemImageNamed:@"person.circle.fill" withConfiguration:cfg];
    avatar.tintColor = accentColor();
    [row addSubview:avatar];

    UILabel *nameLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:15] color:[UIColor labelColor]];
    nameLabel.text = profile.name.length > 0 ? profile.name : localize(@"i18n_str_351", nil);
    [row addSubview:nameLabel];

    UILabel *roleLabel = [self makeLabelWithFont:[UIFont systemFontOfSize:12] color:[UIColor secondaryLabelColor]];
    roleLabel.text = [self playerRoleText:profile];
    roleLabel.textAlignment = NSTextAlignmentRight;
    [row addSubview:roleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [avatar.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
        [avatar.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [avatar.widthAnchor constraintEqualToConstant:30],
        [avatar.heightAnchor constraintEqualToConstant:30],

        [nameLabel.leadingAnchor constraintEqualToAnchor:avatar.trailingAnchor constant:12],
        [nameLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [nameLabel.trailingAnchor constraintEqualToAnchor:roleLabel.leadingAnchor constant:-8],

        [roleLabel.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
        [roleLabel.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [roleLabel.widthAnchor constraintGreaterThanOrEqualToConstant:56],

        [row.heightAnchor constraintEqualToConstant:48],
    ]];
    return row;
}

- (NSString *)playerRoleText:(TerracottaPlayerProfile *)profile {
    NSString *kind = profile.kind;
    if ([kind isEqualToString:@"host"]) return localize(@"i18n_str_1027", nil);
    if ([kind isEqualToString:@"guest"]) return localize(@"i18n_str_1028", nil);
    return localize(@"i18n_str_351", nil);
}

#pragma mark - Background adaptation

// ★ Task248（⑧ 玻璃档联机菜单磨砂化）：游戏表面重度降采样快照（0.18x，
//   与 Task243/246 同族的"抓帧即模糊"自绘磨砂原料）。
static UIImage *ame248_surfaceSnapshot(UIView *ame248_surface) {
    if (ame248_surface == nil || ame248_surface.window == nil ||
        ame248_surface.bounds.size.width < 40.0 ||
        ame248_surface.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame248_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        // ★ Task252：TG 材料在场（滤镜栈可用）时 0.5x 供料；滤镜缺失时
        //   维持 0.18x 旧路（抓帧即模糊）。
        ame248_fmt.scale = ([AmeLiquidGlassView ame252_isSupported] ? 0.5 : 0.18);
        ame248_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame248_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame248_surface.bounds.size
                                                   format:ame248_fmt];
        return [ame248_r imageWithActions:^(UIGraphicsImageRendererContext *ame248_rc) {
            [ame248_surface drawViewHierarchyInRect:ame248_surface.bounds
                                afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame248_e) {
        return nil;
    }
}

// ★ Task248（⑧）：全黑帧护栏（与 Task244 同判据：抓帧病态产物绝不降级黑面）。
static BOOL ame248_snapshotLooksValid(UIImage *ame248_img) {
    if (ame248_img == nil || ame248_img.size.width < 1.0 ||
        ame248_img.size.height < 1.0) return NO;
    CGImageRef ame248_cg = ame248_img.CGImage;
    if (ame248_cg == NULL) return NO;
    unsigned char ame248_px[4] = {0, 0, 0, 0};
    CGColorSpaceRef ame248_cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ame248_ctx = CGBitmapContextCreate(ame248_px, 1, 1, 8, 4,
        ame248_cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(ame248_cs);
    if (ame248_ctx == NULL) return NO;
    CGContextDrawImage(ame248_ctx, CGRectMake(0, 0, 1, 1), ame248_cg);
    CGContextRelease(ame248_ctx);
    int ame248_sum = (int)ame248_px[0] + (int)ame248_px[1] + (int)ame248_px[2];
    return ame248_sum > 19;
}

static const void *kAme248FrostKey = &kAme248FrostKey;

/// ★ Task248（⑧ 一些位置仍用原生界面而非伪液态玻璃）：联机页（TVC）在
///   【游戏内 PageSheet 呈现】时，其下的 Metal 游戏层让系统材质/毛玻璃
///   一律不合成（Task228/230/236 三轮装机实锤的同款机理）——整页只剩
///   系统原生 sheet 底 = 用户看到的"联机菜单还是原生界面"。玻璃家族
///   档位（液态玻璃/伪液态玻璃）下：抓当前游戏表面快照铺进本页底层
///   （快照即成品磨砂 + 深色 tint 压暗），页面立刻进入玻璃语言；原生
///   档与启动器呈现（壁纸管线在场）零改动——"原生风格用回原生"。
- (void)ame248_applyGlassFrostBackground {
    UIView *ame248_frost = objc_getAssociatedObject(self, kAme248FrostKey);
    if (!LGCIsGlassStyleActive()) {
        if (ame248_frost != nil) ame248_frost.hidden = YES;
        return;
    }
    /* ★ Task256（清单 4）：模糊程度最低档 = 背景完全透明 —— 游戏面快照
       磨砂整层退场（与壁纸 frost 同口径；拖回高档即自动恢复，本方法
       在 viewDidAppear/Tick 重入）。 */
    if ([BackgroundManager sharedManager].blurIntensity <= 0.01) {
        if (ame248_frost != nil) ame248_frost.hidden = YES;
        [self ame250_stopFrostRefresh];
        return;
    }
    UIView *ame248_surface = [SurfaceViewController surface];
    UIImage *ame248_img = ame248_surfaceSnapshot(ame248_surface);
    if (ame248_img != nil && !ame248_snapshotLooksValid(ame248_img)) ame248_img = nil;
    if (ame248_img == nil) {
        // 启动器呈现（surface 不在窗口）或抓帧失败：壁纸/卡片管线接管，
        // 快照层退场——与"原生档零改动"同语义。
        if (ame248_frost != nil) ame248_frost.hidden = YES;
        return;
    }
    if (ame248_frost == nil) {
        UIView *ame248_container = [[UIView alloc] init];
        ame248_container.translatesAutoresizingMaskIntoConstraints = NO;
        ame248_container.userInteractionEnabled = NO;
        ame248_container.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        UIImageView *ame248_iv = [[UIImageView alloc] init];
        ame248_iv.translatesAutoresizingMaskIntoConstraints = NO;
        ame248_iv.contentMode = UIViewContentModeScaleToFill;
        ame248_iv.userInteractionEnabled = NO;
        ame248_iv.tag = 24801;
        // ★ Task252：整页磨砂材料升级——TG 滤镜栈（colorMatrix +
        //   gaussianBlur(2)）直接作用于快照图层自身内容（Metal 场景无合成
        //   问题）；0.45 深色 tint 与可读性门禁原样保留。
        NSArray *ame252_filters = [AmeLiquidGlassView ame252_glassFilters];
        if (ame252_filters != nil) ame248_iv.layer.filters = ame252_filters;
        [ame248_container addSubview:ame248_iv];
        [NSLayoutConstraint activateConstraints:@[
            [ame248_iv.topAnchor constraintEqualToAnchor:ame248_container.topAnchor],
            [ame248_iv.bottomAnchor constraintEqualToAnchor:ame248_container.bottomAnchor],
            [ame248_iv.leadingAnchor constraintEqualToAnchor:ame248_container.leadingAnchor],
            [ame248_iv.trailingAnchor constraintEqualToAnchor:ame248_container.trailingAnchor],
        ]];
        [self.view insertSubview:ame248_container atIndex:0];
        [NSLayoutConstraint activateConstraints:@[
            [ame248_container.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [ame248_container.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [ame248_container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [ame248_container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
        objc_setAssociatedObject(self, kAme248FrostKey, ame248_container,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ame248_frost = ame248_container;
    }
    UIImageView *ame248_iv = (UIImageView *)[ame248_frost viewWithTag:24801];
    ame248_iv.image = ame248_img;
    ame248_frost.hidden = NO;
    [self.view sendSubviewToBack:ame248_frost];
    // ★ Task250：快照在位 → 启动 8Hz 动态重抓（磨砂背景随游戏画面持续跟随；
    //   tick 内自检失效面自停，见 ame250_frostTick）。
    [self ame250_startFrostRefresh];
}

#pragma mark - Task252 伪液态玻璃面板（反馈 9/毛玻璃回归）

// 魔改磨砂原料（与 AmeFloatingMenu Task243/245/246 配方同源）：0.18x 抓帧
// 即模糊 + 0.5x 二次柔化 + 全黑帧护栏。源 = 游戏表面（在场时）或呈现方
// view（启动器 OverFullScreen 呈现下呈现方仍在窗口层级内且位于本页之下
// = 纯背景内容，无自噬面——Ame246 同语义）。
static UIImage *ame252_pseudoSnapshotSource(UIView *ame252_src) {
    if (ame252_src == nil || ame252_src.window == nil ||
        ame252_src.bounds.size.width < 40.0 ||
        ame252_src.bounds.size.height < 40.0) return nil;
    @try {
        UIGraphicsImageRendererFormat *ame252_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame252_fmt.scale = 0.18;
        ame252_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame252_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame252_src.bounds.size
                                                   format:ame252_fmt];
        return [ame252_r imageWithActions:^(UIGraphicsImageRendererContext *ame252_rc) {
            [ame252_src drawViewHierarchyInRect:ame252_src.bounds
                             afterScreenUpdates:NO];
        }];
    } @catch (NSException *ame252_e) {
        return nil;
    }
}

static UIImage *ame252_pseudoSoften(UIImage *ame252_img) {
    if (ame252_img == nil) return nil;
    @try {
        CGSize ame252_sz = ame252_img.size;
        if (ame252_sz.width < 1.0 || ame252_sz.height < 1.0) return ame252_img;
        UIGraphicsImageRendererFormat *ame252_fmt =
            [[UIGraphicsImageRendererFormat alloc] init];
        ame252_fmt.scale = 0.5;
        ame252_fmt.opaque = YES;
        UIGraphicsImageRenderer *ame252_r =
            [[UIGraphicsImageRenderer alloc] initWithSize:ame252_sz format:ame252_fmt];
        UIImage *ame252_soft =
            [ame252_r imageWithActions:^(UIGraphicsImageRendererContext *ame252_rc) {
                [ame252_img drawInRect:CGRectMake(0, 0, ame252_sz.width, ame252_sz.height)];
            }];
        return ame252_soft ?: ame252_img;
    } @catch (NSException *ame252_e) {
        return ame252_img;
    }
}

static BOOL ame252_pseudoLooksValid(UIImage *ame252_img) {
    if (ame252_img == nil || ame252_img.size.width < 1.0 ||
        ame252_img.size.height < 1.0) return NO;
    CGImageRef ame252_cg = ame252_img.CGImage;
    if (ame252_cg == NULL) return NO;
    unsigned char ame252_px[4] = {0, 0, 0, 0};
    CGColorSpaceRef ame252_cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ame252_ctx = CGBitmapContextCreate(ame252_px, 1, 1, 8, 4,
        ame252_cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(ame252_cs);
    if (ame252_ctx == NULL) return NO;
    CGContextDrawImage(ame252_ctx, CGRectMake(0, 0, 1, 1), ame252_cg);
    CGContextRelease(ame252_ctx);
    return (ame252_px[0] + ame252_px[1] + ame252_px[2]) > 19;
}

static UIImage *ame252_cachedPseudoBase = nil;
static UIView *ame252_cachedPseudoSrc = nil;

- (void)ame252_refreshPseudoBase {
    if (!LGCIsPseudoGlassStyleActive()) {
        ame252_cachedPseudoBase = nil;
        ame252_cachedPseudoSrc = nil;
        return;
    }
    UIView *ame252_src = [SurfaceViewController surface];
    if (ame252_src == nil || ame252_src.window == nil) {
        UIViewController *ame252_p = self.presentingViewController;
        ame252_src = (ame252_p != nil) ? ame252_p.view : nil;
    }
    UIImage *ame252_raw = ame252_pseudoSnapshotSource(ame252_src);
    if (ame252_raw != nil && !ame252_pseudoLooksValid(ame252_raw)) ame252_raw = nil;
    ame252_cachedPseudoBase = (ame252_raw != nil) ? ame252_pseudoSoften(ame252_raw) : nil;
    ame252_cachedPseudoSrc = (ame252_cachedPseudoBase != nil) ? ame252_src : nil;
    NSLog(@"[TVC] Task252: pseudo panel base refresh -> %@ (src=%@)",
          ame252_cachedPseudoBase != nil ? @"ok" : @"nil",
          ame252_src != nil ? NSStringFromClass([ame252_src class]) : @"none");
}

/// 魔改磨砂面板铺设：面板内 index 0 插窗口对位快照层（convertRect 对位
/// 源视图坐标系，面板 masksToBounds 裁剪 = 真玻璃透视），上盖 Ame239 同款
/// 动态深浅半透明底。幂等：旧 252 层先拆。失效面（无源/全黑帧）自动回退
/// BackgroundManager 管线，面板绝不裸奔。
- (void)ame252_applyPseudoPanelFrost {
    if (!LGCIsPseudoGlassStyleActive()) return;
    NSMutableArray<UIView *> *ame252_panels = [NSMutableArray array];
    if (self.headerCard != nil && self.headerCard.layer.cornerRadius > 0) {
        [ame252_panels addObject:self.headerCard];
    }
    if (self.stageView != nil && self.stageView.layer.cornerRadius > 0) {
        [ame252_panels addObject:self.stageView];
    }
    for (UIView *ame252_sub in self.stageView.subviews) {
        if ([ame252_sub isKindOfClass:[UIVisualEffectView class]]) continue;
        if (ame252_sub.layer.cornerRadius > 0) [ame252_panels addObject:ame252_sub];
    }
    if (ame252_cachedPseudoBase == nil || ame252_cachedPseudoSrc == nil ||
        ame252_cachedPseudoSrc.window == nil) {
        // 失效面：回退原生卡面管线（面板不裸奔）。
        [[BackgroundManager sharedManager] applyCardEffectToView:self.headerCard];
        for (UIView *ame252_sub in self.stageView.subviews) {
            [[BackgroundManager sharedManager] applyEffectToView:ame252_sub];
        }
        NSLog(@"[TVC] Task252: pseudo panels fallback to native pipeline (no valid source)");
        return;
    }
    UIColor *ame252_tint = [UIColor colorWithDynamicProvider:
        ^UIColor * _Nonnull(UITraitCollection * _Nonnull ame252_tc) {
            return (ame252_tc.userInterfaceStyle == UIUserInterfaceStyleDark)
                ? [UIColor colorWithWhite:0.02 alpha:0.30]
                : [UIColor colorWithWhite:1.0 alpha:0.58];
        }];
    for (UIView *ame252_panel in ame252_panels) {
        if (ame252_panel.window == nil) continue;
        for (UIView *ame252_sub in [ame252_panel.subviews copy]) {
            if (ame252_sub.tag == 25201) [ame252_sub removeFromSuperview];
            if ([ame252_sub isKindOfClass:[UIVisualEffectView class]] &&
                ame252_sub.tag != 25100) {
                [ame252_sub removeFromSuperview];   // 清管线 blur 层（252 磨砂接管）
            }
        }
        ame252_panel.layer.masksToBounds = YES;
        ame252_panel.backgroundColor = ame252_tint;
        UIImageView *ame252_iv =
            [[UIImageView alloc] initWithImage:ame252_cachedPseudoBase];
        ame252_iv.tag = 25201;
        ame252_iv.userInteractionEnabled = NO;
        ame252_iv.contentMode = UIViewContentModeScaleToFill;
        ame252_iv.frame = [ame252_panel convertRect:ame252_panel.bounds
                                             toView:ame252_cachedPseudoSrc];
        [ame252_panel insertSubview:ame252_iv atIndex:0];
    }
    NSLog(@"[TVC] Task252: pseudo glass frost applied to %lu panel(s)",
          (unsigned long)ame252_panels.count);
}

/// 布局后重对位（不重抓帧：复用缓存快照，仅重算 convertRect）。
- (void)ame252_realignPseudoPanelFrost {
    if (!LGCIsPseudoGlassStyleActive() || ame252_cachedPseudoBase == nil ||
        ame252_cachedPseudoSrc == nil || ame252_cachedPseudoSrc.window == nil) return;
    NSMutableArray<UIView *> *ame252_panels = [NSMutableArray array];
    if (self.headerCard != nil) [ame252_panels addObject:self.headerCard];
    for (UIView *ame252_sub in self.stageView.subviews) {
        [ame252_panels addObject:ame252_sub];
    }
    for (UIView *ame252_panel in ame252_panels) {
        UIImageView *ame252_iv = (UIImageView *)[ame252_panel viewWithTag:25201];
        if (![ame252_iv isKindOfClass:[UIImageView class]]) continue;
        ame252_iv.frame = [ame252_panel convertRect:ame252_panel.bounds
                                             toView:ame252_cachedPseudoSrc];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self ame252_realignPseudoPanelFrost];
}

- (void)applyBackgroundEffects {
    BOOL hasBg = [[BackgroundManager sharedManager] hasBackground];
    UIColor *primary = hasBg ? [UIColor whiteColor] : [UIColor labelColor];
    UIColor *secondary = hasBg ? [UIColor colorWithWhite:1.0 alpha:0.85] : [UIColor secondaryLabelColor];

    // ★ Task248（⑧）：玻璃家族档位 + 游戏在场 → 快照自绘磨砂背景（原生档
    //   /启动器呈现自动短路为零改动，见方法内护栏）。
    [self ame248_applyGlassFrostBackground];

    // ★ Task252（反馈 9/毛玻璃回归）：伪液态玻璃档 → 面板改魔改快照磨砂
    //   （伪玻璃面板语言），不再走 BackgroundManager 原生毛玻璃管线；
    //   失效面（无源/全黑帧）ame252_applyPseudoPanelFrost 内自动回退管线，
    //   面板不裸奔。文字颜色与表单可读性适配对全档照常执行（仅在卡片
    //   表面重铺段短路——见下方 ame252_pseudo 判断）。
    [self ame252_refreshPseudoBase];
    BOOL ame252_pseudo = LGCIsPseudoGlassStyleActive();
    if (ame252_pseudo) {
        [self ame252_applyPseudoPanelFrost];
    }

    self.statusTitle.textColor = primary;
    self.statusSubtitle.textColor = secondary;

    if (!ame252_pseudo) {
        /* 顶部状态卡：Task168 改走新拟态卡片管线（实底开关开=规格实底+双阴影；
           动态=毛玻璃/半透明面+双阴影叠加）——与主页/下载页卡片形态统一 */
        [[BackgroundManager sharedManager] applyCardEffectToView:self.headerCard];
        for (UIView *sub in self.stageView.subviews) {
            [[BackgroundManager sharedManager] applyEffectToView:sub];
        }
    }

    if (self.hostFormView != nil) {
        [[BackgroundManager sharedManager] applyEffectToView:self.portField];
        self.portField.textColor = primary;
        self.portHintLabel.textColor = secondary;
    }
    if (self.joinFormView != nil) {
        [[BackgroundManager sharedManager] applyEffectToView:self.codeField];
        self.codeField.textColor = primary;
        self.codeHintLabel.textColor = secondary;
    }
    if (self.sessionView != nil) {
        if (hasBg) {
            [self.leaveButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.leaveButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.6].CGColor;
        } else {
            [self.leaveButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
            self.leaveButton.layer.borderColor = [UIColor systemRedColor].CGColor;
        }
        self.infoTitleLabel.textColor = secondary;
        self.infoValueLabel.textColor = primary;
        self.infoDescLabel.textColor = secondary;
        for (UIView *row in self.playersStack.arrangedSubviews) {
            [[BackgroundManager sharedManager] applyEffectToView:row];
        }
    }
}

#pragma mark - Notifications

- (void)registerNotifications {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(stateDidChange:)
               name:TerracottaManagerStateDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(portDidDetect:)
               name:LanPortDetectorDidDetectPortNotification object:nil];
    [nc addObserver:self selector:@selector(backgroundEffectChanged:)
               name:@"BackgroundUIEffectChanged" object:nil];
}

- (void)stateDidChange:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateForCurrentState];
    });
}

- (void)portDidDetect:(NSNotification *)notification {
    uint16_t port = (uint16_t)[notification.userInfo[@"port"] unsignedIntValue];
    if (port == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // ★ Task249（用户反馈 3 伴随修复）：回填加输入闸——手动模式
        // （autoSwitch OFF）下用户正在输入时不覆盖 portField（与
        // updateForCurrentState 短路分支的 autoSwitch 闸同语义）；自动模式
        // 字段本就禁用，回填无冲突。
        if (self.autoSwitch.on || !self.portField.isFirstResponder) {
            self.portField.text = [NSString stringWithFormat:@"%u", port];
        }
        if (self.uiState == TCUIStateDetecting) {
            [self createRoomWithPort:port];
        } else if (self.uiState == TCUIStateHostForm) {
            self.portHintLabel.text = [NSString stringWithFormat:localize(@"i18n_str_2074", nil), port];
        }
    });
}

- (void)backgroundEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
        [self applyBackgroundEffects];
    });
}

#pragma mark - Actions

- (void)createRoomTapped:(id)sender {
    self.uiState = TCUIStateHostForm;
    [self updateForCurrentState];
    // ★ Task252（反馈 7 五修：端口扫描“仍无法自动”根修）：Task251 的自动
    //   武装只挂在 viewWillAppear，且条件含 uiState==HostForm——用户从菜单
    //   态点「创建房间」进表单态是【 VC 内部状态切换】，viewWillAppear 不再
    //   触发 = 武装永远不开火（本轮 gamelog 实锤：latestlog.txt 全场零
    //   "host form appearing … arming"，用户只能手点扫描→扫不到→手动取消，
    //   "stale port was 0" 即此链终点）。修法：进表单态当场武装，与
    //   viewWillAppear 路径共用同一守卫（开关 ON + 无已检端口）。
    [self ame252_armAutoDetectionIfNeeded];
}

/// ★ Task252：表单态自动武装（幂等：LanPortDetector start 端已在扫时
///   静默换绑，不重复起线程；armedWithAutoSwitch 守卫防同态重复打日志）。
- (void)ame252_armAutoDetectionIfNeeded {
    if (self.uiState != TCUIStateHostForm) return;
    if (!self.autoSwitch.on) return;
    if ([LanPortDetector sharedInstance].detectedPort != 0) return;
    if (objc_getAssociatedObject(self, kAme252ArmedKey) != nil) return;
    objc_setAssociatedObject(self, kAme252ArmedKey, @YES,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[TVC] Task252: host form ENTERED in-session (menu->form) -- arming auto-detection (viewWillAppear-gate blind spot fixed)");
    [[LanPortDetector sharedInstance] startAutoDetection];
    [[LanPortDetector sharedInstance] restartLoopbackScanRepeatingWithProgress:nil];
}

- (void)joinRoomTapped:(id)sender {
    self.uiState = TCUIStateJoinForm;
    [self updateForCurrentState];
}

- (void)backToMenuTapped:(id)sender {
    self.uiState = TCUIStateMenu;
    [self updateForCurrentState];
}

- (void)autoSwitchChanged:(UISwitch *)sender {
    BOOL autoOn = sender.on;
    self.portField.enabled = !autoOn;
    self.portField.text = autoOn ? @"" : self.portField.text;
    self.scanButton.hidden = !autoOn;
    self.portHintLabel.text = autoOn ? localize(@"i18n_str_2073", nil) : localize(@"i18n_str_1010", nil);
    // ★ Task252（T7）：表单态把开关拨回 ON = 显式自动意图 → 当场武装
    //   （与进表单态/viewWillAppear 同一收口，卸武装走 LanPortDetector 自停）。
    if (autoOn) {
        objc_setAssociatedObject(self, kAme252ArmedKey, nil,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self ame252_armAutoDetectionIfNeeded];
    }
}

/// 等待 30 秒仍没有端口时，提示用户改用手动输入（不至于一直干等）。
- (void)scheduleDetectionHint {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (strongSelf.uiState != TCUIStateDetecting) return;
        strongSelf.detectingHintLabel.text = localize(@"i18n_str_2079", nil);
    });
}

/// ★ Task248（⑥）：回环 MC 协议扫描（startHostTapped 自动档与 scanPortsTapped
///   共用）。进度文案实时回填；命中走 publishPort → 通知统一收口，本方法
///   的 completion 不重复建房（publishPort 的通知通常已触发 portDidDetect:）。
- (void)ame248_startLoopbackScan {
    __weak typeof(self) weakSelf = self;
    [[LanPortDetector sharedInstance] scanLocalPortsWithProgress:^(NSUInteger scanned, NSUInteger total) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (strongSelf.uiState != TCUIStateDetecting) return;
            strongSelf.detectingHintLabel.text =
                [NSString stringWithFormat:localize(@"i18n_str_2078", nil),
                 (unsigned long)scanned, (unsigned long)total];
        });
    } completion:^(NSArray<NSNumber *> *ports) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            /* publishPort 的通知通常已经创建了房间；只有它没触发时才补一次 */
            if (ports.count > 0 && strongSelf.uiState == TCUIStateDetecting) {
                uint16_t port = (uint16_t)[ports.firstObject unsignedIntValue];
                [strongSelf createRoomWithPort:port];
            }
        });
    }];
}

- (void)startHostTapped:(id)sender {
    if (self.autoSwitch.on) {
        uint16_t known = [LanPortDetector sharedInstance].detectedPort;
        // ★ Task250：快捷路径验活——陈旧端口（上一局世界）直接建房必连不
        //   上；验活失败 = 清口重扫（新世界新端口）。
        if (known > 0 && [[LanPortDetector sharedInstance] isPortStillAlive:known]) {
            [self createRoomWithPort:known];
            return;
        }
        if (known > 0) {
            NSLog(@"[TVC] Task250: stale detected port %u failed liveness check -- clearing and rescanning", known);
            [[LanPortDetector sharedInstance] clearPort];
        }
        self.uiState = TCUIStateDetecting;
        [self updateForCurrentState];
        [[LanPortDetector sharedInstance] startAutoDetection];
        // ★ Task248（⑥ 联机自动扫描端口 双路对齐）：日志尾随之外并行起
        //   127.0.0.1 回环 MC 协议扫描——Task247 T7 只给启动器联机页
        //   （MVC）加了第二路，TVC 的自动检测路径（本分支）仍只有日志
        //   尾随（正则随 MC 版本漂移 = 命中不稳定）。扫描命中经
        //   publishPort → 通知 → portDidDetect: → createRoomWithPort:，
        //   与日志路共享同一收口；进度文案实时回填 detectingHintLabel。
        // ★ Task249（用户反馈 5 根修）：一次性回环扫描升级为周期回环扫描——
        //   用户先点"开始检测"再回游戏开世界（加载 5~30s），一次性扫描在
        //   服务器 bind 前早已空跑结束 = 永远扫不到。周期扫描每 3s 一轮直到
        //   命中/取消；命中经 publishPort → portDidDetect: →
        //   createRoomWithPort: 与日志路同一收口（进度仍实时回填 detectingHintLabel）。
        __weak typeof(self) ame249_wSelf = self;
        [[LanPortDetector sharedInstance] restartLoopbackScanRepeatingWithProgress:^(NSUInteger scanned, NSUInteger total) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(ame249_wSelf) strongSelf = ame249_wSelf;
                if (strongSelf == nil) return;
                if (strongSelf.uiState != TCUIStateDetecting) return;
                strongSelf.detectingHintLabel.text =
                    [NSString stringWithFormat:localize(@"i18n_str_2078", nil),
                     (unsigned long)scanned, (unsigned long)total];
            });
        }];
        [self scheduleDetectionHint];
        return;
    }
    int port = [self.portField.text intValue];
    if (port < 1024 || port > 65535) {
        [self showToast:localize(@"i18n_str_1015", nil)];
        return;
    }
    [self createRoomWithPort:(uint16_t)port];
}

- (void)scanPortsTapped:(id)sender {
    // ★ Task250：立即扫描同样先验活已知端口（活的直接收口，死的清口重扫）
    uint16_t ame250_known = [LanPortDetector sharedInstance].detectedPort;
    if (ame250_known > 0 && [[LanPortDetector sharedInstance] isPortStillAlive:ame250_known]) {
        [self createRoomWithPort:ame250_known];
        return;
    }
    self.detectingHintLabel.text = localize(@"i18n_str_2077", nil);
    self.uiState = TCUIStateDetecting;
    [self updateForCurrentState];

    /* ★ Task249：手动"立即扫描"同样走周期回环扫描（首轮自带全范围深扫）。
     * 旧行为"扫不到就回表单+提示"退役：世界可能尚未开服，留在检测页
     * 持续轮询（每轮进度实时回填），命中即通知收口建房；用户可随时取消。
     * ★ Task250：换 restart 变体——陈旧端口清口 + 新监听方进度块换绑
     * （旧版重复检测的进度块被静默丢弃 = 检测页永远等待的病根之一）。 */
    __weak typeof(self) ame249_wSelf2 = self;
    [[LanPortDetector sharedInstance] restartLoopbackScanRepeatingWithProgress:^(NSUInteger scanned, NSUInteger total) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ame249_wSelf2) strongSelf = ame249_wSelf2;
            if (strongSelf == nil) return;
            if (strongSelf.uiState != TCUIStateDetecting) return;
            strongSelf.detectingHintLabel.text = [NSString stringWithFormat:localize(@"i18n_str_2078", nil),
                                                  (unsigned long)scanned, (unsigned long)total];
        });
    }];
}

- (void)cancelDetectingTapped:(id)sender {
    // ★ Task252（反馈 7）：取消路径补日志——装机日志链里 stop 有、started
    //   无的唯一无日志 stop 入口（历轮取证盲区），补齐后下轮 gamelog 可
    //   完整还原扫描生命周期。
    NSLog(@"[TVC] Task252: auto detection cancelled by user (stale port was %u)",
          (unsigned)[LanPortDetector sharedInstance].detectedPort);
    [[LanPortDetector sharedInstance] stopAutoDetection];
    self.uiState = TCUIStateHostForm;
    [self updateForCurrentState];
}

- (void)codeFieldChanged:(UITextField *)field {
    NSString *code = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) {
        self.codeHintLabel.text = localize(@"i18n_str_2088", nil);
        self.codeHintLabel.textColor = [UIColor secondaryLabelColor];
        return;
    }
    if ([TerracottaBridge respondsToSelector:@selector(verifyRoomCode:)]) {
        BOOL valid = [TerracottaBridge verifyRoomCode:code];
        self.codeHintLabel.text = valid ? localize(@"i18n_str_2085", nil) : localize(@"i18n_str_1017", nil);
        self.codeHintLabel.textColor = valid ? [UIColor systemGreenColor] : [UIColor systemRedColor];
    }
}

- (void)confirmJoinTapped:(id)sender {
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (code.length == 0) {
        [self showToast:localize(@"i18n_str_1016", nil)];
        return;
    }
    [self.view endEditing:YES];
    self.didAutoCopyCode = NO;
    BOOL ok = [[TerracottaManager shared] joinRoomWithInviteCode:code playerName:[self currentPlayerName]];
    if (!ok) {
        [self showToast:[[TerracottaManager shared] lastError] ?: localize(@"i18n_str_1017", nil)];
        return;
    }
    self.uiState = TCUIStateSession;
    [self updateForCurrentState];
}

- (void)createRoomWithPort:(uint16_t)port {
    [self.view endEditing:YES];
    [[LanPortDetector sharedInstance] stopAutoDetection];
    self.didAutoCopyCode = NO;
    [[TerracottaManager shared] createRoomWithPort:port
                                        inviteCode:nil
                                        playerName:[self currentPlayerName]];
    self.uiState = TCUIStateSession;
    [self updateForCurrentState];
}

- (void)copyInfoValue:(id)sender {
    NSString *value = self.infoValueLabel.text;
    if (value.length == 0) return;
    [UIPasteboard generalPasteboard].string = value;
    [self showToast:localize(@"i18n_str_1018", nil)];
}

- (void)leaveTapped:(id)sender {
    [[TerracottaManager shared] stopSession];
    self.uiState = TCUIStateMenu;
    [self updateForCurrentState];
}

- (void)close {
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else if (self.presentingViewController != nil) {
        [self dismissViewControllerAnimated:YES completion:nil];
    } else {
        // ★ [MP-RESTORE] Task222：容器模式（nav 根 + 非 modal，卡片/VS 布局的
        //   setContentViewController 呈现）——pop 与 dismiss 都无效，通知容器
        //   切回主页（两个布局容器都监听 ShowHomePage）。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowHomePage" object:nil];
    }
}

- (void)switchToZeroTier:(id)sender {
    TerracottaStatus status = [TerracottaManager shared].status;
    if (status != TerracottaStatusDisconnected) {
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"i18n_str_1020", nil)
                             message:localize(@"i18n_str_1021", nil)
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                                  style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_1022", nil)
                                                  style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            [[TerracottaManager shared] stopSession];
            [self presentZeroTierVC];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    [self presentZeroTierVC];
}

- (void)presentZeroTierVC {
    MultiplayerViewController *vc = [[MultiplayerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    // ★ Task252（反馈 9/12）：玻璃家族档 → OverFullScreen（MVC 自铺轻 dim
    //   + 透壁纸，与磁贴联机页同语言）；原生档 → PageSheet 原状。
    if (LGCIsGlassStyleActive()) {
        nav.modalPresentationStyle = UIModalPresentationOverFullScreen;
        NSLog(@"[TVC] Task252: ZeroTier page -> OverFullScreen (glass style)");
    } else {
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Misc

- (NSString *)currentPlayerName {
    NSString *name = getPrefObject(@"launcher.account_selected_name");
    if (name.length > 0) return name;
    return [UIDevice currentDevice].name ?: @"iOSPlayer";
}

/// 轻量 toast（不用 UIAlertController 打断操作）
- (void)showToast:(NSString *)message {
    if (message.length == 0) return;
    if (self.toastLabel != nil) {
        [self.toastLabel removeFromSuperview];
        self.toastLabel = nil;
    }
    UILabel *toast = [[UILabel alloc] init];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.text = message;
    toast.textColor = [UIColor whiteColor];
    toast.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.numberOfLines = 0;
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    toast.layer.cornerRadius = 12;
    toast.layer.masksToBounds = YES;
    toast.alpha = 0.0;
    [self.view addSubview:toast];
    self.toastLabel = toast;

    [NSLayoutConstraint activateConstraints:@[
        [toast.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:32],
        [toast.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-32],
        [toast.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:self.view.widthAnchor constant:-64],
        [toast.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
    ]];

    [UIView animateWithDuration:0.2 animations:^{
        toast.alpha = 1.0;
    } completion:^(BOOL finished) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{
                toast.alpha = 0.0;
            } completion:^(BOOL done) {
                [toast removeFromSuperview];
                if (self.toastLabel == toast) self.toastLabel = nil;
            }];
        });
    }];
}

#pragma mark - TextField Delegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

@end
