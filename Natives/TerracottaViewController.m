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
@property(nonatomic, assign) BOOL didAutoCopyCode;
@property(nonatomic, strong) UILabel *toastLabel;

@end

@implementation TerracottaViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.uiState = TCUIStateMenu;

    [self setupDismissHandling];
    [self setupZeroTierButton];

    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

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
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self applyNavigationBarVisibilityForDisappearance];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
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

- (void)applyBackgroundEffects {
    BOOL hasBg = [[BackgroundManager sharedManager] hasBackground];
    UIColor *primary = hasBg ? [UIColor whiteColor] : [UIColor labelColor];
    UIColor *secondary = hasBg ? [UIColor colorWithWhite:1.0 alpha:0.85] : [UIColor secondaryLabelColor];

    self.statusTitle.textColor = primary;
    self.statusSubtitle.textColor = secondary;

    /* 顶部状态卡：Task168 改走新拟态卡片管线（实底开关开=规格实底+双阴影；
       动态=毛玻璃/半透明面+双阴影叠加）——与主页/下载页卡片形态统一 */
    [[BackgroundManager sharedManager] applyCardEffectToView:self.headerCard];
    for (UIView *sub in self.stageView.subviews) {
        [[BackgroundManager sharedManager] applyEffectToView:sub];
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
        self.portField.text = [NSString stringWithFormat:@"%u", port];
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

- (void)startHostTapped:(id)sender {
    if (self.autoSwitch.on) {
        uint16_t known = [LanPortDetector sharedInstance].detectedPort;
        if (known > 0) {
            [self createRoomWithPort:known];
            return;
        }
        self.uiState = TCUIStateDetecting;
        [self updateForCurrentState];
        [[LanPortDetector sharedInstance] startAutoDetection];
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
    self.detectingHintLabel.text = localize(@"i18n_str_2077", nil);
    self.uiState = TCUIStateDetecting;
    [self updateForCurrentState];

    __weak typeof(self) weakSelf = self;
    [[LanPortDetector sharedInstance] scanLocalPortsWithProgress:^(NSUInteger scanned, NSUInteger total) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            strongSelf.detectingHintLabel.text = [NSString stringWithFormat:localize(@"i18n_str_2078", nil),
                                                  (unsigned long)scanned, (unsigned long)total];
        });
    } completion:^(NSArray<NSNumber *> *ports) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        if (ports.count > 0) {
            uint16_t port = (uint16_t)[ports.firstObject unsignedIntValue];
            strongSelf.portField.text = [NSString stringWithFormat:@"%u", port];
            /* publishPort 的通知通常已经创建了房间；只有它没触发时才补一次 */
            if (strongSelf.uiState == TCUIStateDetecting) {
                [strongSelf createRoomWithPort:port];
            }
        } else {
            strongSelf.uiState = TCUIStateHostForm;
            [strongSelf updateForCurrentState];
            [strongSelf showToast:localize(@"i18n_str_2079", nil)];
        }
    }];
}

- (void)cancelDetectingTapped:(id)sender {
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
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
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
