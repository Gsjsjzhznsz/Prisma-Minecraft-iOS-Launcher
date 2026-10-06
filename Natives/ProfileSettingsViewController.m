#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "LauncherNavigationController.h" // for localVersionList/remoteVersionList
#import "MinecraftResourceUtils.h"
#import "installer/modpack/ModrinthAPI.h"
#import "ModVersion.h"
#import "ios_uikit_bridge.h" // for showDialog
#import "utils.h"
#import "UIKit+NativeSurface.h"
#import <objc/runtime.h>

#import "BackgroundManager.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "ModpackExportService.h" // for parseVersionId:

@interface ProfileSettingsViewController () <UITextFieldDelegate, UIPickerViewDataSource, UIPickerViewDelegate>

@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) NSString *selectedRenderer;
// Task172：版本级 TouchController 开关（开启 = 启动时自动配置 UDP 模式 +
// 屏蔽启动器控件；关闭 = 仅移除本键，不碰全局设置）
@property (nonatomic, assign) BOOL touchControllerEnabled;
@property (nonatomic, strong) NSString *selectedGraphicsApi;  // MC 26.2+ 图形 API: default/prefer_vulkan/prefer_opengl
@property (nonatomic, strong) NSString *selectedJavaVersion;
@property (nonatomic, assign) NSInteger allocatedMemory;
@property (nonatomic, assign) NSInteger maxMemory;
@property (nonatomic, assign) BOOL memoryAutoEnabled;  // Task157：自动分配内存开关（profile memoryAuto 标记，仅显式拨过为 YES）
// Task160：分辨率缩放（per-instance，profile 键 resolution，25~150，与旧全局滑条同口径）
@property (nonatomic, assign) NSInteger resolutionScale;
@property (nonatomic, strong) UITextField *resolutionScaleTextField;
// 服务器地址（FCL 风格：留空则不自动加入）
@property (nonatomic, strong) NSString *serverIp;
// JVM 启动参数（如 -Dfoo=bar -Xnoclassgc 等；Xms/Xmx/d32/d64 由内存分配控制会被过滤）
@property (nonatomic, strong) NSString *javaArgs;
// JVM 参数输入框
@property (nonatomic, strong) UITextField *javaArgsTextField;
// 版本选择器
@property (nonatomic, strong) UITextField *versionTextField;
@property (nonatomic, strong) UITextField *nameTextField;
@property (nonatomic, strong) UISegmentedControl *versionTypeControl;
@property (nonatomic, strong) UIPickerView *versionPickerView;
@property (nonatomic, strong) UIToolbar *versionPickerToolbar;
@property (nonatomic, strong) NSArray *versionList;
@property (nonatomic, assign) NSInteger versionSelectedAt;
// 原始名称，用于重命名检测
@property (nonatomic, copy) NSString *originalName;
// Task162（profile 身份一致性）：本 VC 在 PLProfiles.profiles 字典里的【键】。
// 病历（bf91f41 装机日志实锤）：saveSettings/actionDone 原先一律用 name 字段
// （originalName）当字典键写入，而启动链 resolveKeyForCurrentProfile 读的是
// selectedProfileName（字典键）。整合包重名导入（createProfileForModpack 碰撞
// 后缀 " (2)"，name 字段仍是原名）等路径下键≠名，写入落到幻影条目——用户实测
// “切换渲染器为其他都会自动切回自动”（渲染器/内存/分辨率/Java 全部丢写）。
// 修复：加载时记录真实键，保存按键写；重命名按旧键删、新键建。
@property (nonatomic, copy, nullable) NSString *profileDictKey;
// Hero 卡片（顶部 Profile 信息卡片）
@property (nonatomic, strong, nullable) UIView *heroCard;

// 双列 tableView（横屏双列布局）
// leftTableView：竖屏时显示所有 sections（0-4）；横屏时只显示 sections 0,1（版本信息、资源管理）
// rightTableView：仅横屏时显示，显示 sections 2,3,4（组件安装、高级设置、服务器）
@property (nonatomic, strong, nullable) UITableView *leftTableView;
@property (nonatomic, strong, nullable) UITableView *rightTableView;
// Hero 卡片容器（包含 heroCard，作为 leftTableView 的 tableHeaderView）
@property (nonatomic, strong, nullable) UIView *heroContainer;

@end

// 已汉化/英化的行标题显示映射：模块标题在 self.sections 中仍保留中文作为逻辑键（isEqualToString 比较），
// 仅在渲染 cell 时翻译为界面语言。若命中的键不存在会回退为标题本身。
static NSString * localizeProfileTitle(NSString *title) {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"渲染器": @"preference.title.renderer",
            // Task159：分辨率缩放（per-instance，紧随渲染器行）
            @"分辨率缩放": @"preference.profile.title.resolution_scale",
            // Task 150（[可撤销] 删除渲染器全局控制）：跟随全局渲染器开关退役，
            // 映射项同步删除（l10n 键 preference.profile.renderer_follow_global_toggle 退役）
            @"图形 API": @"i18n_str_2057",
            @"Java版本": @"i18n_str_2036",
            @"内存分配": @"i18n_str_2037",
            @"JVM 启动参数": @"preference.title.java_args",
            @"清除JVM参数": @"i18n_str_2038",
            // Task172：TouchController 行标题语言中立，无需翻译键（回退标题本身）
            @"名称": @"preference.profile.title.name",
            @"游戏版本": @"i18n_str_2031",
            @"游戏目录": @"preference.title.game_directory",
            @"模组管理": @"i18n_str_2039",
            @"光影管理": @"i18n_str_2016",
            @"资源包管理": @"i18n_str_2040",
            @"数据包管理": @"i18n_str_2041",
            @"世界管理": @"i18n_str_2042",
            @"Fabric API": @"Fabric API",
            // Task 157：Sodium + Iris Shaders 组件安装入口（火焰图标；与 Fabric API 同逻辑）
            @"Sodium + Iris Shaders": @"Sodium + Iris Shaders",
            @"OptiFine": @"OptiFine",
        };
    });
    NSString *key = map[title] ?: title;
    return localize(key, nil);
}


@implementation ProfileSettingsViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    // 如果只传了 profileName 没传 profile，从 PLProfiles 加载
    if (!self.profile && self.profileName) {
        // Task162：profileName 是字典键（两个 ShowProfileEditor 投递点均传
        // selectedProfileName）。仅当该键真实存在时记为 profileDictKey——
        // 不存在（新建/竞态）保持 nil，saveSettings 回退 name 键（新建语义
        // 与旧行为一致）。
        if (PLProfiles.current.profiles[self.profileName]) {
            self.profileDictKey = self.profileName;
        }
        self.profile = [PLProfiles.current.profiles[self.profileName] mutableCopy];
        if (!self.profile) {
            self.profile = [NSMutableDictionary dictionary];
            self.profile[@"name"] = self.profileName;
        }
    }
    // 安全网：如果调用方既没传 profileName 也没传 profile，创建空字典避免后续 nil 写入
    if (!self.profile) {
        self.profile = [NSMutableDictionary dictionary];
    }
    // Task162：直传 profile 字典的调用路径（如旧版内联创建）无 profileName——
    // 用 originalName 反查键（name 字段与键一致的常规形态；查不到保持 nil）。
    if (!self.profileDictKey) {
        NSString *ame162_probeName = self.profile[@"name"];
        if ([ame162_probeName isKindOfClass:NSString.class] &&
            PLProfiles.current.profiles[ame162_probeName]) {
            self.profileDictKey = ame162_probeName;
        }
    }

    // 确保 profile 有 name 字段
    self.originalName = self.profile[@"name"];
    if ([self.originalName length] == 0) {
        self.originalName = self.profileName ?: @"New Profile";
        self.profile[@"name"] = self.originalName;
    }

    self.title = [NSString stringWithFormat:localize(@"i18n_str_863", nil), self.originalName];

    // 导航栏按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // 设置表格（双列布局：leftTableView 主表格，rightTableView 仅横屏时显示）
    // UIViewController 的 self.view 是容器视图，包含两个 tableView
    self.leftTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.leftTableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.leftTableView.dataSource = self;
    self.leftTableView.delegate = self;
    self.leftTableView.backgroundColor = [UIColor clearColor];
    // 使用 Automatic 让系统自动避开导航栏（修复内容上移被导航栏遮挡）
    // 配合 edgesForExtendedLayout = UIRectEdgeAll 让背景延伸到导航栏后方
    self.leftTableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    [self.view addSubview:self.leftTableView];

    self.rightTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    self.rightTableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.rightTableView.dataSource = self;
    self.rightTableView.delegate = self;
    self.rightTableView.backgroundColor = [UIColor clearColor];
    self.rightTableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    self.rightTableView.hidden = YES; // 默认隐藏，横屏时显示
    [self.view addSubview:self.rightTableView];

    // 适配自定义启动器背景：透明背景让底层背景毛玻璃透出。
    // 两条进入路径（push 和 showProfileEditor modal）都使用 clearColor，
    // 统一由 BackgroundManager 管理背景效果。
    // 适配自定义启动器背景：给 tableView 设置毛玻璃 backgroundView，遮挡栈底 VC 内容。
    // 修复"点击版本管理进入版本设置后前一页面未及时消失"问题：
    // 若 tableView 完全透明，push 后会透出栈底 VersionManagerViewController 的卡片，造成"前一页未消失"。
    // 这里给 backgroundView 设置 UIVisualEffectView（毛玻璃），既能模糊并透出全局背景图，
    // 又能遮挡栈底 VC 内容，同时保持视觉一致性。
    [self applyBackgroundBlurToTableView];
    // 适配自定义启动器背景：导航栏毛玻璃 + 视图透明
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;

    // 计算最大内存
    [self calculateMaxMemory];

    // 加载设置
    [self loadSettings];

    // 设置版本选择器
    [self setupVersionPicker];

    // 设置分区
    [self setupSections];

    // 顶部 Hero 卡片（Profile 名 + 当前版本 pill + 游戏目录）
    [self setupHeroCard];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionList)
                                                 name:@"ReloadProfileList"
                                               object:nil];

    // Task224：全局 TouchController 设置变化 → 刷新本页“有效状态”显示
    //（状态不同步根修的观察侧；广播侧在 TouchControllerPreferencesViewController
    // updateTouchControllerSetting: 尾部补发）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_touchControllerSettingsChanged)
                                                 name:@"TouchControllerSettingsChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Task224: TouchController 有效状态显示

/// 版本设置 TouchController 行的“有效状态”文案（状态不同步根修）。
/// 旧代码只看 profile 开关 + 硬编码 “UDP 协议”文案——全局设置页已禁用时
/// 此处仍显示 “UDP 协议”（用户实测反馈）。口径对齐启动链
/// ame172_applyProfileTouchController：profile 开 AND 全局
/// control.mod_touch_enable；模式取全局 control.mod_touch_mode
/// （1=UDP，2=静态库）；全局关闭 → 新键 profile.touchcontroller.global_off。
- (NSString *)ame224_touchControllerModeLabel {
    if (!getPrefBool(@"control.mod_touch_enable")) {
        return localize(@"profile.touchcontroller.global_off", nil);
    }
    NSInteger ame224_mode = getPrefInt(@"control.mod_touch_mode");
    if (ame224_mode == 2) {
        return localize(@"preference.touchcontroller.mode.staticlib", nil);
    }
    return localize(@"preference.touchcontroller.mode.udp", nil);
}

/// Task224：TouchControllerSettingsChanged 广播到达时重载双列表格
///（设置页可能正叠在本页之上，改完全局设置返回即刻可见，不再显示
/// 过期的 “UDP 协议”）。
- (void)ame224_touchControllerSettingsChanged {
    self.touchControllerEnabled = [self.profile[@"touchController"] boolValue];
    [self.leftTableView reloadData];
    [self.rightTableView reloadData];
    NSLog(@"[ProfileSettings] Task224 TouchController row refreshed (global settings changed)");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 修复"前一个页面没有及时消失"：viewDidLoad 时 tableView.bounds 可能为 zero，
    // 导致 applyBackgroundBlurToTableView 设置的 backgroundView frame 为 zero，
    // push 转场初期无法遮挡栈底 VersionManagerViewController 的内容。
    // 在 viewWillAppear 中重新应用，此时 bounds 已正确，确保转场前遮挡到位。
    [self applyBackgroundBlurToTableView];
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    // 横竖屏切换时，重新计算 tableHeaderView（Hero 卡片）的高度，并切换双列布局
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // 切换 rightTableView 的显示状态（横屏时显示）
        BOOL landscape = size.width > size.height;
        self.rightTableView.hidden = !landscape;

        // 重新计算 Hero 卡片高度（仅 leftTableView 显示 Hero 卡片）
        UIView *header = self.leftTableView.tableHeaderView;
        if (header) {
            // 横屏时 leftTableView 宽度是总宽度的一半（减去间距）
            CGFloat headerWidth = landscape ? (size.width / 2.0 - 8.0) : size.width;
            header.frame = CGRectMake(0, 0, headerWidth, 0);
            [header setNeedsLayout];
            [header layoutIfNeeded];
            CGFloat fittingHeight = [header systemLayoutSizeFittingSize:CGSizeMake(headerWidth, 0)
                                                    withHorizontalFittingPriority:UILayoutPriorityRequired
                                                          verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
            header.frame = CGRectMake(0, 0, headerWidth, fittingHeight);
            self.leftTableView.tableHeaderView = header;
        }

        // 重新加载两个 tableView 的数据（visible sections 会根据方向变化）
        [self.leftTableView reloadData];
        [self.rightTableView reloadData];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        // 转场完成后再次应用背景模糊（frame 已稳定）
        [self applyBackgroundBlurToTableView];
    }];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    [self layoutDualTableViews];
}

/// 布局双列 tableView
/// - 竖屏：leftTableView 占满整个 view，rightTableView 隐藏
/// - 横屏：leftTableView 占左半部分，rightTableView 占右半部分，中间 16pt 间距
- (void)layoutDualTableViews {
    CGRect bounds = self.view.bounds;
    BOOL landscape = [self isLandscape];

    if (landscape) {
        // 横屏双列布局
        CGFloat spacing = 16.0;
        CGFloat halfWidth = (bounds.size.width - spacing) / 2.0;
        self.leftTableView.frame = CGRectMake(0, 0, halfWidth, bounds.size.height);
        self.rightTableView.frame = CGRectMake(halfWidth + spacing, 0, halfWidth, bounds.size.height);
        self.rightTableView.hidden = NO;
    } else {
        // 竖屏单列布局
        self.leftTableView.frame = bounds;
        self.rightTableView.hidden = YES;
    }

    // 重新计算 Hero 卡片（tableHeaderView）的宽度和高度
    [self relayoutHeroHeader];

    // 同步背景模糊视图的 frame
    [self syncBackgroundBlurFrames];
}

/// 重新计算 Hero 卡片（tableHeaderView）的宽度和高度
- (void)relayoutHeroHeader {
    UIView *header = self.leftTableView.tableHeaderView;
    if (!header) return;
    CGFloat width = self.leftTableView.bounds.size.width;
    if (width == 0) return;
    header.frame = CGRectMake(0, 0, width, 0);
    [header setNeedsLayout];
    [header layoutIfNeeded];
    CGFloat fittingHeight = [header systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                            withHorizontalFittingPriority:UILayoutPriorityRequired
                                                  verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    header.frame = CGRectMake(0, 0, width, fittingHeight);
    self.leftTableView.tableHeaderView = header;
}

/// 同步 leftTableView 和 rightTableView 的 backgroundView frame
- (void)syncBackgroundBlurFrames {
    for (UITableView *tv in @[self.leftTableView, self.rightTableView]) {
        if (!tv || tv.hidden) continue;
        if (tv.backgroundView) {
            tv.backgroundView.frame = tv.bounds;
        }
    }
}

- (void)reloadVersionList {
    self.versionList = nil;
    self.versionSelectedAt = -1;
    if (self.versionPickerView && self.versionPickerView.window) {
        [self changeVersionType:nil];
    }
}

#pragma mark - Hero Card

/// 顶部 Hero 卡片：Profile 名 + 当前版本 pill + 游戏目录（Prisma-Design v1.2 L3 大卡片）
- (void)setupHeroCard {
    // ===== Hero 卡片容器（L3：16pt 圆角 + 半透明背景 + 毛玻璃 + 浅边框 + 中阴影）=====
    UIView *heroCard = [[UIView alloc] init];
    // Task160：半透明白底/白边框/黑色下阴影退役——无壁纸时由
    // applyEffectToView 上新拟态规格表面色（cell 场景同款 flat），有壁纸时
    // 走毛玻璃管线；黑色单侧阴影与新拟态双阴影体系冲突，一并移除
    heroCard.layer.cornerRadius = 16;
    heroCard.layer.cornerCurve = kCACornerCurveContinuous;
    [[BackgroundManager sharedManager] applyEffectToView:heroCard];

    // ===== Hero 图标（56x56，14pt 圆角，accentColor 背景，白色 cube.fill SF Symbol）=====
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.image = [UIImage systemImageNamed:@"cube.fill"];
    iconView.tintColor = [UIColor whiteColor];
    iconView.contentMode = UIViewContentModeCenter;
    iconView.backgroundColor = accentColor();
    iconView.layer.cornerRadius = 14;
    iconView.layer.cornerCurve = kCACornerCurveContinuous;
    iconView.layer.masksToBounds = YES;
    [heroCard addSubview:iconView];

    // ===== 标题（Profile 名，17pt bold，labelColor）=====
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = self.profile[@"name"] ?: self.originalName ?: @"New Profile";
    titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    titleLabel.textColor = AmeCardPrimaryTextColor(); // Task160 规格主文字
    titleLabel.adjustsFontSizeToFitWidth = YES;
    titleLabel.minimumScaleFactor = 0.8;
    [heroCard addSubview:titleLabel];

    // ===== 版本 pill（11pt bold，绿底白字，checkmark.circle.fill + 版本号）=====
    UIView *versionPill = [[UIView alloc] init];
    versionPill.backgroundColor = [UIColor systemGreenColor];
    versionPill.layer.cornerRadius = 9;
    versionPill.layer.cornerCurve = kCACornerCurveContinuous;
    versionPill.layer.masksToBounds = YES;
    [heroCard addSubview:versionPill];

    UIImageView *pillIcon = [[UIImageView alloc] init];
    pillIcon.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    pillIcon.tintColor = [UIColor whiteColor];
    pillIcon.contentMode = UIViewContentModeScaleAspectFit;
    [versionPill addSubview:pillIcon];

    UILabel *pillLabel = [[UILabel alloc] init];
    NSString *currentVersion = self.profile[@"lastVersionId"];
    pillLabel.text = currentVersion.length > 0 ? currentVersion : localize(@"i18n_str_864", nil);
    pillLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    pillLabel.textColor = [UIColor whiteColor];
    pillLabel.adjustsFontSizeToFitWidth = YES;
    pillLabel.minimumScaleFactor = 0.7;
    [versionPill addSubview:pillLabel];

    // ===== 副标题（游戏目录，12pt regular，secondaryLabelColor）=====
    UILabel *subtitleLabel = [[UILabel alloc] init];
    NSString *gameDir = self.profile[@"gameDir"] ?: @".";
    NSString *instanceName = getPrefObject(@"general.game_directory") ?: @"default";
    subtitleLabel.text = [NSString stringWithFormat:@"%@ → /instances/%@", gameDir, instanceName];
    subtitleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    subtitleLabel.textColor = AmeCardSecondaryTextColor(); // Task160 规格次要文字
    subtitleLabel.adjustsFontSizeToFitWidth = YES;
    subtitleLabel.minimumScaleFactor = 0.7;
    [heroCard addSubview:subtitleLabel];

    self.heroCard = heroCard;

    // ===== 布局：使用 container 包装，设置为 tableHeaderView =====
    UIView *container = [[UIView alloc] init];
    [container addSubview:heroCard];

    heroCard.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionPill.translatesAutoresizingMaskIntoConstraints = NO;
    pillIcon.translatesAutoresizingMaskIntoConstraints = NO;
    pillLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;

    [NSLayoutConstraint activateConstraints:@[
        // heroCard：左右 16pt 外边距，上下 8pt
        [heroCard.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [heroCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [heroCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [heroCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],

        // iconView：56x56，左侧 16pt，上下 16pt
        [iconView.leadingAnchor constraintEqualToAnchor:heroCard.leadingAnchor constant:16],
        [iconView.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [iconView.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
        [iconView.widthAnchor constraintEqualToConstant:56],
        [iconView.heightAnchor constraintEqualToConstant:56],

        // titleLabel：iconView 右侧 14pt，顶部 16pt
        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
        [titleLabel.topAnchor constraintEqualToAnchor:heroCard.topAnchor constant:16],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:heroCard.trailingAnchor constant:-16],

        // versionPill：titleLabel 下方 4pt，高度 18pt，左侧对齐 titleLabel
        [versionPill.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [versionPill.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        [versionPill.heightAnchor constraintEqualToConstant:18],

        // pillIcon：8x8，左侧 6pt，垂直居中
        [pillIcon.leadingAnchor constraintEqualToAnchor:versionPill.leadingAnchor constant:6],
        [pillIcon.centerYAnchor constraintEqualToAnchor:versionPill.centerYAnchor],
        [pillIcon.widthAnchor constraintEqualToConstant:10],
        [pillIcon.heightAnchor constraintEqualToConstant:10],

        // pillLabel：紧跟 pillIcon 右侧 2pt，右侧 6pt，垂直居中
        [pillLabel.leadingAnchor constraintEqualToAnchor:pillIcon.trailingAnchor constant:2],
        [pillLabel.centerYAnchor constraintEqualToAnchor:versionPill.centerYAnchor],
        [pillLabel.trailingAnchor constraintEqualToAnchor:versionPill.trailingAnchor constant:-6],

        // subtitleLabel：versionPill 下方 4pt，底部 16pt
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
        [subtitleLabel.topAnchor constraintEqualToAnchor:versionPill.bottomAnchor constant:4],
        [subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:heroCard.trailingAnchor constant:-16],
        [subtitleLabel.bottomAnchor constraintEqualToAnchor:heroCard.bottomAnchor constant:-16],
    ]];

    // 手动计算 container 高度并设置 tableHeaderView
    CGFloat width = self.leftTableView.bounds.size.width;
    if (width == 0) width = [UIScreen mainScreen].bounds.size.width;
    container.frame = CGRectMake(0, 0, width, 0);
    [container setNeedsLayout];
    [container layoutIfNeeded];
    CGFloat fittingHeight = [container systemLayoutSizeFittingSize:CGSizeMake(width, 0)
                                               withHorizontalFittingPriority:UILayoutPriorityRequired
                                                     verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    container.frame = CGRectMake(0, 0, width, fittingHeight);
    self.heroContainer = container;
    self.leftTableView.tableHeaderView = container;
}

/// 更新 Hero 卡片内容（用户修改名称/版本后调用）
- (void)updateHeroCard {
    if (!self.heroCard) return;
    // 遍历 heroCard 子视图找到 titleLabel/versionPill/subtitleLabel 并更新
    for (UIView *sub in self.heroCard.subviews) {
        if ([sub isKindOfClass:[UILabel class]]) {
            UILabel *label = (UILabel *)sub;
            // 通过字体特征区分：17pt bold = 标题；12pt regular = 副标题；11pt bold = 版本 pill label
            if (label.font.pointSize >= 16) {
                label.text = self.profile[@"name"] ?: self.originalName ?: @"New Profile";
            } else if (label.font.pointSize <= 11) {
                NSString *currentVersion = self.profile[@"lastVersionId"];
                label.text = currentVersion.length > 0 ? currentVersion : localize(@"i18n_str_864", nil);
            } else {
                NSString *gameDir = self.profile[@"gameDir"] ?: @".";
                NSString *instanceName = getPrefObject(@"general.game_directory") ?: @"default";
                // Task224：完整解析路径 + 语义标签 + 选中态提示（"开了隔离
                // 还是共享"的显示层错位根修——旧文案只有相对片段且方向
                // 奇怪，用户无从核对数据实际落点）。
                NSInteger ame224_isoState = [self ame217_isolationState];
                NSString *ame224_dirLabel = (ame224_isoState == 0) ? localize(@"profile.isolation.none", nil)
                    : (ame224_isoState == 1) ? localize(@"profile.isolation.isolate", nil)
                    : localize(@"profile.isolation.custom", nil);
                NSString *ame224_suffix = @"";
                NSString *ame224_editedKey = self.profileName;
                if (ame224_editedKey.length > 0 &&
                    ![ame224_editedKey isEqualToString:PLProfiles.current.selectedProfileName]) {
                    ame224_suffix = [NSString stringWithFormat:@" · %@", localize(@"profile.isolation.not_selected", nil)];
                }
                label.text = [NSString stringWithFormat:@"%@ · /instances/%@/%@%@",
                    ame224_dirLabel, instanceName, gameDir, ame224_suffix];
            }
        }
    }
}

#pragma mark - Memory

- (void)calculateMaxMemory {
    long long totalMemory = [NSProcessInfo processInfo].physicalMemory;
    self.maxMemory = (NSInteger)(totalMemory / (1024 * 1024));
    self.maxMemory = (NSInteger)(self.maxMemory * 0.8);
    if (self.maxMemory < 1024) {
        self.maxMemory = 1024;
    }
    // Task173：内存滑条上限过 Jetsam 安全堆顶（惊变100天根修的 UI 侧）。
    // 0.8 × 物理内存（8GB 设备 ≈ 7165MB）远超 iOS 进程上限——用户滑到
    // 满格 = 启动后静默 SIGKILL。上限收紧到 安全堆顶 + 512MB 余量
    //（滑条顶格仍略高于钳制值，但启动链 ame141 会兜底钳制并提示）。
    NSInteger ame173_sliderCap = ame173_safeHeapCeilingMB() + 512;
    if (self.maxMemory > ame173_sliderCap) {
        NSLog(@"[ProfileSettings] Task173: memory slider cap %ldMB -> %ldMB (Jetsam-safe)",
              (long)self.maxMemory, (long)ame173_sliderCap);
        self.maxMemory = ame173_sliderCap;
    }
}

#pragma mark - Load Settings

- (void)loadSettings {
    // 渲染器（Task 140：nil = 跟随全局——profile 无 renderer 键时不再
    // 假装“auto”，实例页如实显示“跟随全局”态；启动链
    // resolveKeyForCurrentProfile 对无键 profile 自动回退全局 video.renderer，
    // 语义一致。用户想显式用 auto 可在选项表里选“自动”。）
    // Task 142：读前迁移（幂等）+ legacy 家族键归一为 "mg"——渲染器层
    // 不存后端（后端由 mg 设置 mobileglues.renderer_backend 决定，默认
    // Vulkan 直连）。跟随全局（无键）由外置开关呈现，不再混进选择列表。
    ame142_migrateRendererStorage();
    id ame140_rendererRaw = self.profile[@"renderer"];
    if ([ame140_rendererRaw isKindOfClass:NSString.class] &&
        [getRendererFamilyKeys() containsObject:ame140_rendererRaw]) {
        ame140_rendererRaw = @ RENDERER_KEY_MG;
    }
    // Task 150（[可撤销] 删除渲染器全局控制）：无键实例缺省 "auto"
    //（用户确认；启动链同口径——resolveKeyForCurrentProfile 全局回退
    // 已退役，profile 无键 → ame_effective_renderer 落 auto）。从此
    // 每个实例都拥有显式渲染器值，实例页不再有“跟随全局”灰态。
    self.selectedRenderer = [ame140_rendererRaw isKindOfClass:NSString.class] ? ame140_rendererRaw : @"auto";

    // 图形 API（MC 26.2+ 游戏内 OpenGL/Vulkan 切换）
    self.selectedGraphicsApi = self.profile[@"graphicsApi"] ?: @"default";

    // Task172：版本级 TouchController（无键 = 关闭）
    self.touchControllerEnabled = [self.profile[@"touchController"] boolValue];

    // Task160：分辨率缩放（per-instance，25~150，与旧全局滑条同口径）。profile 无键时
    // 显示全局回退值（与启动解析链 resolveKeyForCurrentProfile 同口径）——存量设备
    // 全局行删除后存量值继续生效直到显式设置；编辑结束 clamp [25,150]。
    id ame159_resolutionRaw = self.profile[@"resolution"];
    if ([ame159_resolutionRaw isKindOfClass:[NSString class]] && [(NSString *)ame159_resolutionRaw length] > 0) {
        self.resolutionScale = [(NSString *)ame159_resolutionRaw intValue];
    } else if ([ame159_resolutionRaw isKindOfClass:[NSNumber class]]) {
        self.resolutionScale = [(NSNumber *)ame159_resolutionRaw integerValue];
    } else {
        self.resolutionScale = (NSInteger)getPrefFloat(@"video.resolution");
    }
    if (self.resolutionScale <= 0) self.resolutionScale = 100;

    // Java版本（兼容旧版直装器写入的 NSDictionary 格式）
    id javaVerRaw = self.profile[@"javaVersion"];
    if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
        id major = javaVerRaw[@"majorVersion"];
        self.selectedJavaVersion = major ? [major description] : @"0";
    } else {
        self.selectedJavaVersion = [javaVerRaw isKindOfClass:[NSString class]] ? javaVerRaw : @"0";
    }

    // 内存分配 (MB)
    self.allocatedMemory = [self.profile[@"allocatedMemory"] integerValue];
    if (self.allocatedMemory == 0) {
        self.allocatedMemory = MIN(self.maxMemory / 2, 2048);
    }
    if (self.allocatedMemory > self.maxMemory) {
        self.allocatedMemory = self.maxMemory;
    }
    // Task157：自动分配内存标记（仅显式拨过开关的实例为 YES；老实例无
    // 标记 = 手动态，沿用缺省值展示——用户定稿"默认手动"）
    self.memoryAutoEnabled = [self.profile[@"memoryAuto"] boolValue];

    // 服务器地址（默认空字符串，留空不自动加入）
    NSString *profName = self.profile[@"name"] ?: self.profileName;
    self.serverIp = [PLProfiles.current serverIpForProfile:profName] ?: @"";

    // JVM 启动参数：参照 main 分支，仅读取 profile 自身字段；
    // 为空时 UI 显示 "(default)" placeholder，实际启动时由 PLProfiles.resolveKeyForCurrentProfile
    // 回退到全局 java.java_args（见 JavaLauncher.init_loadCustomJvmFlags）。
    id rawArgs = self.profile[@"javaArgs"];
    if ([rawArgs isKindOfClass:[NSString class]]) {
        self.javaArgs = rawArgs;
    } else {
        self.javaArgs = @"";
    }
}

#pragma mark - Sections

- (void)setupSections {
    // 高级设置 section：渲染器（Task 150：跟随全局开关退役——每个实例
    // 强制单独选择，无键实例缺省 auto）+ 分辨率缩放（Task159：全局滑条
    // 退役后迁入，per-instance 25~100）+ 图形 API（仅 MC 26.2+）+
    // Java/内存/JVM。
    NSMutableArray *advancedRows = [NSMutableArray arrayWithArray:@[@"渲染器"]];
    // Task159：分辨率缩放迁入实例页，紧随渲染器行（用户指令"渲染器选项下"）
    [advancedRows addObject:@"分辨率缩放"];
    if ([self isCurrentProfileModernVersion]) {
        [advancedRows addObject:@"图形 API"];
    }
    [advancedRows addObjectsFromArray:@[@"Java版本", @"内存分配", @"JVM 启动参数", @"清除JVM参数"]];
    // Task173：TouchController 从高级设置区退役（Task172 的开关式 picker 一并
    // 退役），改为组件安装区的 Sodium 同款样式（用户指令"TouchController 选项
    // 是跟 sodium 一样的样式，点击自动安装加自动配置，而不是只有自动配置"）。
    // 选中行为 = 一键安装（Modrinth 拉取适配版本的 mod jar 落 mods/）+ 自动
    // 配置（写 profile touchController=YES → 启动链 ame172_applyProfileTouchController
    // 自动落 UDP 模式 + 屏蔽启动器控件）。

    // 重构（Prisma-Design v1.2）：5 个 Bento 分组
    // 顺序与横屏布局对应：左侧（0,1）+ 右侧（2,3,4）
    //   0: 版本信息  - 名称 / 游戏版本 / 游戏目录
    //   1: 资源管理  - 模组 / 光影 / 资源包 / 数据包 / 世界
    //   2: 组件安装  - Fabric API / Sodium + Iris Shaders（Task157）/ TouchController（Task173）/ OptiFine
    //   3: 高级设置  - 渲染器 / 图形 API / Java / 内存 / JVM 参数
    //   4: 服务器    - 服务器地址
    self.sections = @[
        @[@"名称", @"游戏版本", @"游戏目录"],
        @[@"模组管理", @"光影管理", @"资源包管理", @"数据包管理", @"世界管理"],
        @[@"Fabric API", @"Sodium + Iris Shaders", @"TouchController", @"OptiFine"],
        [advancedRows copy],
        @[localize(@"i18n_str_730", nil)]
    ];
}

#pragma mark - Dual Table View Helpers

/// 是否处于横屏（宽度 > 高度）
- (BOOL)isLandscape {
    CGSize size = self.view.bounds.size;
    return size.width > size.height;
}

/// 返回指定 tableView 显示的全局 section 索引数组
/// - leftTableView：竖屏时显示所有 sections (0,1,2,3,4)；横屏时只显示 (0,1)
/// - rightTableView：仅横屏时显示 (2,3,4)
- (NSArray<NSNumber *> *)visibleSectionsForTableView:(UITableView *)tableView {
    if (tableView == self.rightTableView) {
        return @[@2, @3, @4];
    }
    // leftTableView
    if ([self isLandscape]) {
        return @[@0, @1];
    }
    return @[@0, @1, @2, @3, @4];
}

/// 将 tableView 的本地 section 索引转换为全局 section 索引
- (NSInteger)globalSectionForTableView:(UITableView *)tableView localSection:(NSInteger)localSection {
    NSArray<NSNumber *> *visible = [self visibleSectionsForTableView:tableView];
    if (localSection < 0 || localSection >= (NSInteger)visible.count) return -1;
    return visible[localSection].integerValue;
}

/// 主 tableView（用于与外部代码交互，如 Hero 卡片、背景模糊等）
- (UITableView *)mainTableView {
    return self.leftTableView;
}

/// 重新加载所有 tableView 的数据
- (void)reloadAllTableViews {
    [self.leftTableView reloadData];
    if (self.rightTableView && !self.rightTableView.hidden) {
        [self.rightTableView reloadData];
    }
}

/// 根据全局 section 和 row 查找 cell（用于 popover sourceView 等）
/// 遍历 leftTableView 和 rightTableView，找到包含该全局 section 的 tableView
- (UITableViewCell *)cellForGlobalSection:(NSInteger)globalSection row:(NSInteger)row {
    // 检查 leftTableView
    NSArray<NSNumber *> *leftVisible = [self visibleSectionsForTableView:self.leftTableView];
    NSInteger leftLocal = [leftVisible indexOfObject:@(globalSection)];
    if (leftLocal != NSNotFound) {
        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:leftLocal];
        return [self.leftTableView cellForRowAtIndexPath:ip];
    }
    // 检查 rightTableView
    if (self.rightTableView && !self.rightTableView.hidden) {
        NSArray<NSNumber *> *rightVisible = [self visibleSectionsForTableView:self.rightTableView];
        NSInteger rightLocal = [rightVisible indexOfObject:@(globalSection)];
        if (rightLocal != NSNotFound) {
            NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:rightLocal];
            return [self.rightTableView cellForRowAtIndexPath:ip];
        }
    }
    return nil;
}

#pragma mark - Save

- (void)saveSettings {
    // 仅保存渲染器/Java/内存/服务器等设置项，不处理重命名
    // 重命名逻辑在 actionDone 中处理
    // 注意：必须使用 originalName 作为 key，且不能把用户正在编辑的 name 写入 PLProfiles
    // 否则用户改名后关闭（不点 Done），PLProfiles 中的 profile.name 会变成新名但 key 仍是旧名
    // Task162（身份一致性）：写入键改为 profileDictKey（加载时记录的字典键），
    //   originalName 仅作新建/未知路径的回退。键≠名时旧代码写幻影条目，
    //   启动链读 selectedProfileName 键永远看不到——渲染器/内存/分辨率
    //   等全部丢写，装机日志实锤（详见 viewDidLoad 的 Task162 病历注）。
    NSString *profName = self.originalName ?: self.profile[@"name"];
    if (!profName) return;
    NSString *ame162_targetKey = self.profileDictKey.length > 0 ? self.profileDictKey : profName;
    if (self.profileDictKey.length > 0 && ![self.profileDictKey isEqualToString:profName]) {
        NSLog(@"[ProfileSettings] Task162: save keyed by dict key '%@' (display name '%@' differs -- no phantom write)",
              ame162_targetKey, profName);
    }

    // 保存用户正在编辑的字段（name 和 lastVersionId 可能在编辑中，尚未确认）
    NSString *userInputName = self.profile[@"name"];
    NSString *userInputVersion = self.profile[@"lastVersionId"];

    // Task162：读源同写目标——existing 必须从 ame162_targetKey 取（旧代码读
    // name 键：键≠名时拷到空字典，再把残缺条目（缺 lastVersionId/gameDir/
    // javaVersion 等）整体写回正确键 = 破坏原条目）。self.profile 在编辑器
    // 生命周期内保持加载时的完整字段（loadSettings 只读不改），此处以
    // profileDictKey 的活字典为基底最稳。
    NSMutableDictionary *existing = [PLProfiles.current.profiles[ame162_targetKey] mutableCopy];
    if (!existing) {
        existing = [self.profile mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    // Task 140：渲染器分居重构 —— 实例页只写【profile】层。
    // Task 150（[可撤销] 删除渲染器全局控制）：跟随全局（删键）态退役——
    // 无键实例在 loadSettings 已缺省 "auto"，此处防御性同口径：nil → auto。
    if (self.selectedRenderer == nil || self.selectedRenderer.length == 0) {
        existing[@"renderer"] = @"auto";
        NSLog(@"[ProfileSettings] Task150: renderer missing -> explicit 'auto' for '%@'", ame162_targetKey);
    } else {
        existing[@"renderer"] = self.selectedRenderer;
        NSLog(@"[ProfileSettings] Task150: renderer written to PROFILE ONLY '%@' = %@",
              ame162_targetKey, self.selectedRenderer);
    }
    existing[@"graphicsApi"] = self.selectedGraphicsApi;
    // Task172：版本级 TouchController——开启落 YES，关闭删键（无键 = 关闭，
    // 启动链 ame172_applyProfileTouchController 同口径；关闭不碰全局设置）
    if (self.touchControllerEnabled) {
        existing[@"touchController"] = @YES;
    } else {
        [existing removeObjectForKey:@"touchController"];
    }
    existing[@"javaVersion"] = self.selectedJavaVersion;
    // Task159：分辨率缩放落 profile 层（NSString，与 PLProfiles resolveKey 的
    // NSString 读取约定一致）；用户未设置时 loadSettings 已把全局回退值填进
    // resolutionScale，首次保存即固化为实例显式值（语义与显示一致）
    existing[@"resolution"] = [NSString stringWithFormat:@"%ld", (long)self.resolutionScale];
    // Task157：自动分配内存——开启时 allocatedMemory 落 0（启动链
    // ame141_currentLaunchAllocMem 的 0 = 原版自动比例语义）并打 memoryAuto
    // 标记；关闭时写拉条值并清标记（无标记 = 手动态，用户定稿"默认手动"）
    if (self.memoryAutoEnabled) {
        existing[@"allocatedMemory"] = @(0);
        existing[@"memoryAuto"] = @YES;
    } else {
        existing[@"allocatedMemory"] = @(self.allocatedMemory);
        [existing removeObjectForKey:@"memoryAuto"];
    }
    existing[@"serverIp"] = self.serverIp ?: @"";
    // 参照 main 分支：javaArgs 为空时移除 key，让 profile 回退到全局 java.java_args
    if (self.javaArgs.length > 0) {
        existing[@"javaArgs"] = self.javaArgs;
    } else {
        [existing removeObjectForKey:@"javaArgs"];
    }
    // 保存游戏目录（版本隔离用）：gameDir 为 nil 时默认 "."，与 main 分支行为一致
    existing[@"gameDir"] = self.profile[@"gameDir"] ?: @".";
    // existing 中的 name 和 lastVersionId 字段保持原始值不变
    PLProfiles.current.profiles[ame162_targetKey] = existing;
    [PLProfiles.current save];

    // 同步到 working copy（深拷贝，避免与 PLProfiles 共享对象）
    // 恢复用户正在编辑的 name 和 lastVersionId，这样 actionDone 仍能拿到用户改的值
    self.profile = [existing mutableCopy];
    if (userInputName.length > 0) {
        self.profile[@"name"] = userInputName;
    }
    if (userInputVersion.length > 0) {
        self.profile[@"lastVersionId"] = userInputVersion;
    }
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return [[self visibleSectionsForTableView:tableView] count];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return 0;
    return [self.sections[globalSection] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    switch (globalSection) {
        case 0: return localize(@"i18n_str_289", nil);
        case 1: return localize(@"i18n_str_877", nil);
        case 2: return localize(@"i18n_str_878", nil);
        case 3: return localize(@"i18n_str_879", nil);
        case 4: return localize(@"i18n_str_880", nil);
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:section];
    if (globalSection == 0) {
        return localize(@"i18n_str_881", nil);
    }
    if (globalSection == 2) {
        return localize(@"i18n_str_882", nil);
    }
    if (globalSection == 4) {
        return localize(@"i18n_str_883", nil);
    }
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"SettingsCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellIdentifier];
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        // Task141：行标题/详情永不省略号截断，空间不足时缩小字号
        // （用户实测"JVM 启动参数"在 iPhone 上被 accessoryView 挤成"JVM启动…"）
        cell.textLabel.adjustsFontSizeToFitWidth = YES;
        cell.textLabel.minimumScaleFactor = 0.6;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        cell.detailTextLabel.minimumScaleFactor = 0.6;
    }

    // 重置复用 cell 的状态
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.imageView.image = nil;
    cell.textLabel.text = nil;
    cell.detailTextLabel.text = nil;
    // 重置可能被"清除JVM参数"修改过的颜色；detailTextLabel 一并复位
    // （Task 142：跟随全局态的渲染器行会把值位染成 tertiary 灰，
    // 复用流向其它行前必须还原，secondaryLabel 与 value1 样式的
    // 原生灰同族且深色模式安全）
    cell.imageView.tintColor = nil;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:indexPath.section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return cell;

    NSString *title = self.sections[globalSection][indexPath.row];
    cell.textLabel.text = localizeProfileTitle(title);

    switch (globalSection) {
        case 0: // 版本信息
            if ([title isEqualToString:@"名称"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"tag"];
                cell.accessoryView = [self buildNameTextField];
            } else if ([title isEqualToString:@"游戏版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"archivebox"];
                // Task163：原 disclosureType 赋值删除——accessoryView 已被
                // 版本输入框占用，系统箭头本就不绘制，留着误导维护者
                cell.accessoryView = [self buildVersionTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"游戏目录"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"folder"];
                cell.accessoryView = [self ame163_disclosureChevron];
                // Task217：FCL 三态隔离态显示（不隔离/versions/<id>/自定义路径），
                // 替代旧版裸 gameDir 字符串。
                NSInteger ame217_state = [self ame217_isolationState];
                if (ame217_state == 0) {
                    cell.detailTextLabel.text = localize(@"profile.isolation.state_none", nil);
                } else if (ame217_state == 1) {
                    cell.detailTextLabel.text = [NSString stringWithFormat:localize(@"profile.isolation.state_isolated", nil),
                        self.profile[@"lastVersionId"] ?: @"?"];
                } else {
                    cell.detailTextLabel.text = self.profile[@"gameDir"];
                }
            }
            break;

        case 1: // 资源管理
            if ([title isEqualToString:@"模组管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
                cell.accessoryView = [self ame163_disclosureChevron];
            } else if ([title isEqualToString:@"光影管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"paintbrush.fill"];
                cell.accessoryView = [self ame163_disclosureChevron];
            } else if ([title isEqualToString:@"资源包管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"rectangle.stack.fill"];
                cell.accessoryView = [self ame163_disclosureChevron];
            } else if ([title isEqualToString:@"数据包管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"shippingbox.fill"];
                cell.accessoryView = [self ame163_disclosureChevron];
            } else if ([title isEqualToString:@"世界管理"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"globe.asia.australia.fill"];
                cell.accessoryView = [self ame163_disclosureChevron];
            }
            break;

        case 2: // 组件安装
            if ([title isEqualToString:@"Fabric API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"bolt.fill"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = [self isFabricProfile] ? localize(@"i18n_str_2043", nil) : localize(@"i18n_str_885", nil);
            } else if ([title isEqualToString:@"Sodium + Iris Shaders"]) {
                // Task 157：Sodium + Iris Shaders 组件安装（火焰图标；与 Fabric
                // API 同逻辑，一键装 Sodium + Iris + Podium 三模组，仅 Fabric
                // 实例可用）
                cell.imageView.image = [UIImage systemImageNamed:@"flame.fill"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = [self isFabricProfile] ? localize(@"i18n_str_2043", nil) : localize(@"i18n_str_885", nil);
            } else if ([title isEqualToString:@"TouchController"]) {
                // Task173：TouchController 组件安装（Sodium 同款样式，用户指令
                // "跟 sodium 一样的样式，点击自动安装加自动配置"）。触摸手掌图标
                // + 橙色 + 右箭头；右侧文案三态：非 Fabric → 仅 Fabric 有效；
                // 已启用（profile touchController=YES，Task172 键沿用）→ UDP
                // 模式；可安装 → 点击安装。零新 l10n 键（复用 Task172 的
                // preference.touchcontroller.mode.udp + 组件区现成键）。
                cell.imageView.image = [UIImage systemImageNamed:@"hand.tap.fill"];
                cell.imageView.tintColor = [UIColor systemOrangeColor];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = ![self isFabricProfile]
                    ? localize(@"i18n_str_885", nil)
                    : (self.touchControllerEnabled
                        ? [self ame224_touchControllerModeLabel]
                        : localize(@"i18n_str_2043", nil));
            } else if ([title isEqualToString:@"OptiFine"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"speedometer"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = [self isOptiFineCompatibleProfile] ? localize(@"i18n_str_2043", nil) : localize(@"i18n_str_886", nil);
            }
            break;

        case 3: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                // Task 150：跟随全局开关退役——每个实例强制单独选择，
                // 渲染器行永远可点（不再有置灰态）
                cell.imageView.image = [UIImage systemImageNamed:@"cpu"];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = [self rendererDisplayName:self.selectedRenderer];
            } else if ([title isEqualToString:@"分辨率缩放"]) {
                // Task160：per-instance 分辨率缩放（25~150）——右侧参数样式与
                // 内存分配行同款（灰字 + 向右箭头），行内输入保留（点击行聚焦）；
                // "%" 为独立标签（不在输入框内）；容器尾端补仿系统箭头
                cell.imageView.image = [UIImage systemImageNamed:@"viewfinder"];
                cell.accessoryView = [self buildResolutionScaleAccessory];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"图形 API"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"rectangle.dashed"];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = [self graphicsApiDisplayName:self.selectedGraphicsApi];
            } else if ([title isEqualToString:@"Java版本"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"j.square"];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = [self.selectedJavaVersion isEqualToString:@"0"] ? localize(@"preference.auto", nil) : [NSString stringWithFormat:@"Java %@", self.selectedJavaVersion];
            } else if ([title isEqualToString:@"内存分配"]) {
                // Task157：右侧只显示当前分配值（去"/ 最大可分配内存"）+
                // 与 Java版本同款箭头；自动分配态显示"自动分配内存"
                cell.imageView.image = [UIImage systemImageNamed:@"memorychip"];
                cell.accessoryView = [self ame163_disclosureChevron];
                cell.detailTextLabel.text = self.memoryAutoEnabled
                    ? localize(@"memory.auto_row", nil)
                    : [NSString stringWithFormat:@"%ld MB", (long)self.allocatedMemory];
            } else if ([title isEqualToString:@"JVM 启动参数"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"slider.vertical.3"];
                cell.accessoryView = [self buildJavaArgsTextField];
                cell.detailTextLabel.text = nil;
            } else if ([title isEqualToString:@"清除JVM参数"]) {
                cell.imageView.image = [UIImage systemImageNamed:@"trash"];
                cell.imageView.tintColor = [UIColor systemRedColor];
                cell.textLabel.textColor = [UIColor systemRedColor];
                cell.detailTextLabel.text = self.javaArgs.length > 0 ? localize(@"i18n_str_2044", nil) : localize(@"i18n_str_889", nil);
            }
            // Task173：TouchController 行已迁往组件安装区（case 2），高级设置
            // 区的旧分支（Task172 开关式 picker）随之退役。
            break;

        case 4: // 服务器地址（FCL 风格）
            cell.imageView.image = [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"];
            cell.accessoryView = [self buildServerIpTextField];
            break;
    }

    return cell;
}

#pragma mark - 名称输入框

- (UITextField *)buildNameTextField {
    // 复用已有 textField
    if (self.nameTextField) {
        // 检查是否已被其他 cell 持有（复用机制下需要重新添加）
        if (!self.nameTextField.superview || self.nameTextField.superview == self.view) {
            return self.nameTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.placeholder = localize(@"i18n_str_890", nil);
    textField.text = self.profile[@"name"];
    textField.font = [UIFont systemFontOfSize:14];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 10;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1001;
    textField.delegate = self;
    [textField addTarget:self action:@selector(nameTextFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(nameTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.nameTextField = textField;
    return textField;
}

#pragma mark - Task160 分辨率缩放输入框（per-instance）

#pragma mark - Task163 统一 disclosure 箭头

/// 与分辨率行尾端完全同款的自绘向右箭头（chevron.right，tertiaryLabel 灰）。
/// Task163：系统 DisclosureIndicator 的 glyph 粗细与分辨率行的 SF Symbol
/// chevron 并排观感突兀（用户实测渲染器行箭头"与其他选项样式不匹配"）
/// ——整页所有跳转行统一改用本箭头，与分辨率行容器尾端箭头同款
/// （同 glyph/同色/同 8x13 尺寸；容器 14x30 使箭头距右缘 6pt、垂直居中
/// 与分辨率行一致）。accessoryView 占位后系统箭头同样不再绘制。
- (UIView *)ame163_disclosureChevron {
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 30)];
    UIImageView *chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    chevron.tintColor = [UIColor tertiaryLabelColor];
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.frame = CGRectMake(0, 8.5, 8, 13);
    [container addSubview:chevron];
    return container;
}

/// 分辨率缩放行的 accessory：[数字输入框 | % | 箭头] 容器（Task160）。
/// 右侧参数样式与内存分配行同款——灰字（secondaryLabelColor）、系统 detail
/// 同字号 17pt、无输入框观感；行内输入保留（点击行聚焦编辑，用户定稿）；
/// "%" 为独立标签（与输入框文字同字号样式，不在输入框内）；accessoryView
/// 占位后系统 disclosure 箭头不再显示，容器尾端补一个同视觉的 chevron。
/// 编辑结束 clamp 到 [25, 150] 落盘。
- (UIView *)buildResolutionScaleAccessory {
    // 复用：container 仍持有 textField 就直接重挂（accessoryView 赋值时
    // UIKit 自动从旧 cell 挪到新 cell），并刷新为当前值
    if (self.resolutionScaleTextField && self.resolutionScaleTextField.superview) {
        self.resolutionScaleTextField.text = [NSString stringWithFormat:@"%ld", (long)self.resolutionScale];
        return self.resolutionScaleTextField.superview;
    }

    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 56, 30)];
    textField.text = [NSString stringWithFormat:@"%ld", (long)self.resolutionScale];
    // Task160：与内存分配行 detailTextLabel 同色同字号（系统 detail 默认 17pt regular）
    textField.font = [UIFont systemFontOfSize:17];
    textField.textColor = [UIColor secondaryLabelColor];
    textField.keyboardType = UIKeyboardTypeNumberPad;
    textField.textAlignment = NSTextAlignmentRight;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.delegate = self;
    textField.tag = 1004;
    // NumberPad 无 return 键：Done 条收键盘 → EditingDidEnd 落库
    UIToolbar *doneBar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    doneBar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
                      [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:textField action:@selector(resignFirstResponder)]];
    textField.inputAccessoryView = doneBar;
    [textField addTarget:self action:@selector(resolutionScaleDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.resolutionScaleTextField = textField;

    UILabel *percentLabel = [[UILabel alloc] initWithFrame:CGRectMake(58, 0, 18, 30)];
    percentLabel.text = @"%";
    percentLabel.font = [UIFont systemFontOfSize:17];
    percentLabel.textColor = [UIColor secondaryLabelColor];

    // Task160：容器尾端自绘箭头（chevron.right，tertiaryLabel 灰）——
    // accessoryView 被本容器占用后 cell 自带的向右箭头不会绘制，在此补齐；
    // Task163：本箭头升级为整页统一基准（ame163_disclosureChevron 与本处
    // 同 glyph/同色/同尺寸），渲染器等所有跳转行已与其对齐
    UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.right"];
    UIImageView *chevronView = [[UIImageView alloc] initWithImage:chevronImage];
    chevronView.tintColor = [UIColor tertiaryLabelColor];
    chevronView.contentMode = UIViewContentModeScaleAspectFit;
    chevronView.frame = CGRectMake(82, 9, 8, 13);

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 96, 30)];
    [container addSubview:textField];
    [container addSubview:percentLabel];
    [container addSubview:chevronView];
    return container;
}

- (void)resolutionScaleDidEnd:(UITextField *)textField {
    // 编辑结束 clamp 到 [25, 150]（Task160 用户指令范围）并落盘；空/非数字
    // 输入 intValue=0 → 落到下限 25
    NSInteger ame159_value = textField.text.intValue;
    if (ame159_value < 25) ame159_value = 25;
    if (ame159_value > 150) ame159_value = 150;
    self.resolutionScale = ame159_value;
    textField.text = [NSString stringWithFormat:@"%ld", (long)ame159_value];
    [self saveSettings];
}

- (void)nameTextFieldChanged:(UITextField *)textField {
    self.profile[@"name"] = textField.text ?: @"";
    [self updateHeroCard];
}

- (void)nameTextFieldDidEnd:(UITextField *)textField {
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    self.profile[@"name"] = trimmed;
    textField.text = trimmed;
    [self updateHeroCard];
}

#pragma mark - 版本选择器

- (void)setupVersionPicker {
    self.versionPickerView = [[UIPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;

    self.versionPickerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width, 44)];
    self.versionTypeControl = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"i18n_str_891", nil), localize(@"i18n_str_2058", nil), localize(@"i18n_str_1288", nil), @"Old-beta", @"Old-alpha"
    ]];
    [self.versionTypeControl addTarget:self action:@selector(changeVersionType:) forControlEvents:UIControlEventValueChanged];
    self.versionPickerToolbar.items = @[
        [[UIBarButtonItem alloc] initWithCustomView:self.versionTypeControl],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(versionClosePicker)]
    ];

    // 自动选择版本类型
    NSString *currentVersion = self.profile[@"lastVersionId"];
    if (currentVersion) {
        if ([MinecraftResourceUtils findVersion:currentVersion inList:localVersionList]) {
            self.versionTypeControl.selectedSegmentIndex = 0;
        } else {
            NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:currentVersion inList:remoteVersionList];
            if (selected) {
                NSArray *types = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"];
                NSString *type = selected[@"type"];
                self.versionTypeControl.selectedSegmentIndex = [types indexOfObject:type];
                if (self.versionTypeControl.selectedSegmentIndex == NSNotFound) {
                    self.versionTypeControl.selectedSegmentIndex = 0;
                }
            } else {
                self.versionTypeControl.selectedSegmentIndex = 0;
            }
        }
    } else {
        self.versionTypeControl.selectedSegmentIndex = 0;
    }
    self.versionSelectedAt = -1;
}

- (UITextField *)buildVersionTextField {
    if (self.versionTextField) {
        if (!self.versionTextField.superview || self.versionTextField.superview == self.view) {
            return self.versionTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    textField.text = self.profile[@"lastVersionId"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.textAlignment = NSTextAlignmentRight;
    textField.tag = 1002;
    textField.delegate = self;
    textField.inputView = self.versionPickerView;
    textField.inputAccessoryView = self.versionPickerToolbar;
    [textField addTarget:self action:@selector(versionTextFieldDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.versionTextField = textField;

    // 初始化版本列表
    [self changeVersionType:nil];
    return textField;
}

- (void)versionTextFieldDidEnd:(UITextField *)textField {
    // 更新 profile 中的版本
    self.profile[@"lastVersionId"] = textField.text ?: @"";
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

- (void)changeVersionType:(UISegmentedControl *)sender {
    NSArray *newVersionList = self.versionList;
    if (sender || !self.versionList) {
        if (self.versionTypeControl.selectedSegmentIndex == 0) {
            // nil 安全：启动器刚启动时 localVersionList 可能尚未加载
            newVersionList = localVersionList ?: @[];
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            // nil 安全：remoteVersionList 为 nil 时用空数组，避免 filteredArrayUsingPredicate 崩溃
            NSArray *remote = remoteVersionList ?: @[];
            newVersionList = [remote filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
        }
    }

    if (self.versionSelectedAt == -1) {
        NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:self.versionTextField.text inList:newVersionList];
        self.versionSelectedAt = [newVersionList indexOfObject:selected];
    } else {
        NSObject *lastSelected = nil;
        if (self.versionList.count > self.versionSelectedAt) {
            lastSelected = self.versionList[self.versionSelectedAt];
        }
        if (lastSelected != nil) {
            NSObject *nearest = [MinecraftResourceUtils findNearestVersion:lastSelected expectedType:self.versionTypeControl.selectedSegmentIndex];
            if (nearest != nil) {
                self.versionSelectedAt = [newVersionList indexOfObject:(id)nearest];
            }
        }
        self.versionSelectedAt = MIN(labs(self.versionSelectedAt), (NSInteger)newVersionList.count - 1);
    }

    self.versionList = newVersionList;
    [self.versionPickerView reloadAllComponents];
    if (self.versionSelectedAt != -1 && self.versionSelectedAt < (NSInteger)newVersionList.count) {
        [self.versionPickerView selectRow:self.versionSelectedAt inComponent:0 animated:NO];
        [self pickerView:self.versionPickerView didSelectRow:self.versionSelectedAt inComponent:0];
    }
}

#pragma mark - UIPickerView DataSource/Delegate

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.versionList.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (self.versionList.count <= row) return nil;
    NSObject *object = self.versionList[row];
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString *)object;
    } else {
        return [object valueForKey:@"id"];
    }
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (self.versionList.count == 0) {
        self.versionTextField.text = @"";
        return;
    }
    self.versionSelectedAt = row;
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
    self.profile[@"lastVersionId"] = self.versionTextField.text;
    [self updateHeroCard];
}

#pragma mark - 服务器地址输入框

- (UITextField *)buildServerIpTextField {
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 220, 30)];
    textField.placeholder = localize(@"i18n_str_893", nil);
    textField.text = self.serverIp;
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.keyboardType = UIKeyboardTypeURL;
    textField.tag = 9527;
    textField.delegate = self;
    [textField addTarget:self action:@selector(serverIpTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(serverIpTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    return textField;
}

#pragma mark - JVM 启动参数输入框

- (UITextField *)buildJavaArgsTextField {
    if (self.javaArgsTextField) {
        if (!self.javaArgsTextField.superview || self.javaArgsTextField.superview == self.view) {
            return self.javaArgsTextField;
        }
    }
    UITextField *textField = [[UITextField alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
    // 参照 main 分支 LauncherProfileEditorViewController：placeholder 为 "(default)"，
    // 表示未设置时回退到全局 java.java_args。
    textField.placeholder = @"(default)";
    // 仅当 profile 显式设置了 javaArgs 时才显示，否则留空显示 placeholder
    textField.text = self.profile[@"javaArgs"] ?: @"";
    textField.font = [UIFont systemFontOfSize:13];
    textField.adjustsFontSizeToFitWidth = YES;
    textField.minimumFontSize = 9;
    textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    textField.returnKeyType = UIReturnKeyDone;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    textField.tag = 1003;
    textField.delegate = self;
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
    [textField addTarget:self action:@selector(javaArgsTextFieldEditingDidEnd:) forControlEvents:UIControlEventEditingDidEnd];
    self.javaArgsTextField = textField;
    return textField;
}

- (void)javaArgsTextFieldEditingChanged:(UITextField *)textField {
    self.javaArgs = textField.text ?: @"";
}

- (void)javaArgsTextFieldEditingDidEnd:(UITextField *)textField {
    // 参照 main 分支：空串或 "(default)" 视为未设置，保存时移除 key 以回退全局 java.java_args
    NSString *trimmed = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (trimmed.length == 0 || [trimmed isEqualToString:@"(default)"]) {
        self.javaArgs = @"";
        textField.text = @"";
    } else {
        self.javaArgs = trimmed;
        textField.text = trimmed;
    }
    [self saveSettings];
}

/// 一键清除当前版本已设置的 JVM 启动参数
- (void)clearJavaArgs {
    if (self.javaArgs.length == 0) {
        UIAlertController *tip = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                     message:localize(@"i18n_str_894", nil)
                                                              preferredStyle:UIAlertControllerStyleAlert];
        [tip addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:tip animated:YES completion:nil];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_895", nil)
                                                                   message:localize(@"i18n_str_896", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_77", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.javaArgs = @"";
        self.javaArgsTextField.text = @"";
        [self saveSettings];
        [self reloadAllTableViews];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)serverIpTextFieldEditingChanged:(UITextField *)textField {
    self.serverIp = textField.text ?: @"";
}

- (void)serverIpTextFieldEditingDidEnd:(UITextField *)textField {
    self.serverIp = [textField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    textField.text = self.serverIp;
    [self saveSettings];
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

#pragma mark - Helpers

// Task 140：渲染器显示名（实例页专用）。三层：
//   - MG 家族键 → 三后端文案（旧版显示原始 dylib 名“libMobileGL-gles.dylib”，
//     用户不认识）；
//   - 经典键 → candidates 表显示名（ame_renderer_display_name 统一处理）。
// Task 150（[可撤销] 删除渲染器全局控制）：nil/空值分支改为显示 "auto"
//（跟随全局态已退役——loadSettings 缺省 auto，此处仅防御）。
- (NSString *)rendererDisplayName:(NSString *)renderer {
    if (renderer == nil || renderer.length == 0) {
        return ame_renderer_display_name(@"auto");
    }
    return ame_renderer_display_name(renderer);
}

- (NSString *)currentProfileName {
    return self.profile[@"name"] ?: self.profileName;
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSInteger globalSection = [self globalSectionForTableView:tableView localSection:indexPath.section];
    if (globalSection < 0 || globalSection >= (NSInteger)self.sections.count) return;

    NSString *title = self.sections[globalSection][indexPath.row];

    switch (globalSection) {
        case 0: // 版本信息
            if ([title isEqualToString:@"名称"]) {
                // 聚焦名称输入框
                if (self.nameTextField) [self.nameTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"游戏版本"]) {
                // 聚焦版本选择器
                if (self.versionTextField) [self.versionTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"游戏目录"]) {
                // Task217：FCL 风格版本隔离——游戏目录行点击弹三态选择器
                //（不隔离 / 隔离此版本 / 自定义路径），替代旧版直接弹文本框。
                [self ame217_showIsolationPicker];
            }
            break;

        case 1: // 资源管理
            if ([title isEqualToString:@"模组管理"]) {
                [self openModsManager];
            } else if ([title isEqualToString:@"光影管理"]) {
                [self openShadersManager];
            } else if ([title isEqualToString:@"资源包管理"]) {
                [self openResourcePacksManager];
            } else if ([title isEqualToString:@"数据包管理"]) {
                [self openDataPacksManager];
            } else if ([title isEqualToString:@"世界管理"]) {
                [self openWorldsManager];
            }
            break;

        case 2: // 组件安装
            if ([title isEqualToString:@"Fabric API"]) {
                [self installFabricAPIStandalone];
            } else if ([title isEqualToString:@"Sodium + Iris Shaders"]) {
                // Task 157：Sodium + Iris Shaders（+ Podium）一键安装
                [self installSodiumStandalone];
            } else if ([title isEqualToString:@"TouchController"]) {
                // Task173：TouchController 一键安装 + 自动配置（Sodium 同款流程）
                [self installTouchControllerStandalone];
            } else if ([title isEqualToString:@"OptiFine"]) {
                [self installOptiFineStandalone];
            }
            break;

        case 3: // 高级设置
            if ([title isEqualToString:@"渲染器"]) {
                // Task 150：跟随全局开关退役——渲染器行永远直接弹选择器
                [self showRendererSelector];
            } else if ([title isEqualToString:@"分辨率缩放"]) {
                // Task159：聚焦行内输入框（名称行同款交互）
                if (self.resolutionScaleTextField) [self.resolutionScaleTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"图形 API"]) {
                [self showGraphicsApiSelector];
            } else if ([title isEqualToString:@"Java版本"]) {
                [self showJavaVersionSelector];
            } else if ([title isEqualToString:@"内存分配"]) {
                [self showMemoryAllocator];
            } else if ([title isEqualToString:@"JVM 启动参数"]) {
                if (self.javaArgsTextField) [self.javaArgsTextField becomeFirstResponder];
            } else if ([title isEqualToString:@"清除JVM参数"]) {
                [self clearJavaArgs];
            }
            // Task173：TouchController 分支已迁往组件安装区（case 2）。
            break;

        case 4: // 服务器地址
            [self focusTextFieldInCellAtIndexPath:indexPath inTableView:tableView];
            break;
    }
}

- (void)focusTextFieldInCellAtIndexPath:(NSIndexPath *)indexPath inTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    if (!cell) return;
    UITextField *textField = [self findTextFieldInView:cell.contentView];
    if ([textField canBecomeFirstResponder]) {
        [textField becomeFirstResponder];
    }
}

- (UITextField *)findTextFieldInView:(UIView *)view {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UITextField class]]) {
            return (UITextField *)sub;
        }
        UITextField *found = [self findTextFieldInView:sub];
        if (found) return found;
    }
    return nil;
}

#pragma mark - Actions

/// 编辑游戏目录（仿 main 分支 LauncherProfileEditorViewController 的 gameDir 文本框）
/// gameDir="." 表示使用当前 POJAV_GAME_DIR（即"游戏目录切换"选中的实例目录）
/// 也可以输入相对路径（相对于 POJAV_GAME_DIR）或绝对路径来实现版本隔离
/// Task217：不再作为游戏目录行的首选交互（改弹 FCL 三态选择器），保留为
/// 选择器里的"自定义路径（高级）"入口。
- (void)editGameDir {
    NSString *currentGameDir = self.profile[@"gameDir"] ?: @".";
    NSString *currentInstance = getPrefObject(@"general.game_directory") ?: @"default";

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"i18n_str_2004", nil)
                         message:[NSString stringWithFormat:
                                  [[[localize(@"i18n_str_897", nil)
                                      stringByAppendingString:localize(@"i18n_str_2010", nil)]
                                     stringByAppendingString:localize(@"i18n_str_2011", nil)]
                                    stringByAppendingString:localize(@"i18n_str_2012", nil)],
                                  currentInstance]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.text = currentGameDir;
        textField.placeholder = [NSString stringWithFormat:@". -> /Documents/instances/%@", currentInstance];
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_898", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        self.profile[@"gameDir"] = @".";
        [self saveSettings];
        [self reloadAllTableViews];
        [self updateHeroCard];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *newGameDir = alert.textFields.firstObject.text;
        newGameDir = [newGameDir stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (newGameDir.length == 0) {
            newGameDir = @".";
        }
        self.profile[@"gameDir"] = newGameDir;
        [self saveSettings];
        [self reloadAllTableViews];
        [self updateHeroCard];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openModsManager {
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Task217：FCL 风格版本隔离（三态选择器 + 旧版升级自动迁移）

/// 当前 gameDir 的隔离态归类：0 = 不隔离（"."），1 = 隔离此版本
/// （versions/<lastVersionId>），2 = 自定义路径。
- (NSInteger)ame217_isolationState {
    NSString *gameDir = self.profile[@"gameDir"];
    if (![gameDir isKindOfClass:[NSString class]] || [gameDir isEqualToString:@"."]) return 0;
    NSString *vid = self.profile[@"lastVersionId"] ?: @"";
    // Task224：隔离目录与版本元数据分居（数据完整性根修）——新口径
    // versions/<id>/game；旧口径 versions/<id>（jar/json 同目录混居，
    // 版本重校验/清理/modpack 重导入可伤及存档）识别为隔离态，由迁移
    // 路径自动升级搬入 game/ 子目录。
    if ([gameDir isEqualToString:[NSString stringWithFormat:@"versions/%@/game", vid]]) return 1;
    if ([gameDir isEqualToString:[NSString stringWithFormat:@"versions/%@", vid]]) return 1;
    return 2;
}

/// FCL 三态选择器：不隔离 / 隔离此版本（自动迁移）/ 自定义路径（高级）。
/// 与上游同步的版本隔离语义 + FCL 式交互优化（用户指令：参考 FCL）；
/// 旧版升级自动迁移 = 从"不隔离"切到"隔离此版本"时，实例根目录下已
/// 存在的用户数据（存档/模组/配置等）自动搬入隔离目录，绝不丢失。
- (void)ame217_showIsolationPicker {
    NSInteger state = [self ame217_isolationState];
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }

    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:localize(@"profile.isolation.title", nil)
                         message:[NSString stringWithFormat:localize(@"profile.isolation.subtitle", nil), lastVersionId]
                  preferredStyle:UIAlertControllerStyleActionSheet];

    NSString *noneMark = (state == 0) ? @" ✓" : @"";
    [sheet addAction:[UIAlertAction actionWithTitle:[localize(@"profile.isolation.none", nil) stringByAppendingString:noneMark]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * _Nonnull action) {
            if (state == 0) return;
            // Task224：回切共享改为【可选搬回】（旧实现单向不搬回 = 数据
            // 滞留隔离目录，用户视角“存档消失”——两轮实测实测铁）。
            [self ame224_disableIsolationWithOptionalMigration];
        }]];

    NSString *isoMark = (state == 1) ? @" ✓" : @"";
    [sheet addAction:[UIAlertAction actionWithTitle:[localize(@"profile.isolation.isolate", nil) stringByAppendingString:isoMark]
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * _Nonnull action) {
            [self ame217_enableIsolationWithMigration];
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"profile.isolation.custom", nil)
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * _Nonnull action) {
            [self editGameDir];
        }]];

    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2.0, self.view.bounds.size.height / 2.0, 1.0, 1.0);
    [self presentViewController:sheet animated:YES completion:nil];
}

/// 开启隔离 + 旧版升级自动迁移。把实例根目录下的运行时用户数据移入
/// versions/<lastVersionId>/game/（Task224：数据与版本元数据分居——旧口径
/// 直接放 versions/<id>/，与 jar/json 混居，版本重校验/清理/modpack 重导入
/// 都可能伤及存档；本函数同时把旧口径数据自动升级搬入 game/ 子目录）：
/// 目标已存在的条目一律跳过（绝不覆盖）；libraries/assets/versions 保持
/// 共享不迁移。迁移在后台队列执行（大 mods 目录不再冻结 UI），计数制
/// 汇总（无百分比——杜绝负数显示）。
- (void)ame217_enableIsolationWithMigration {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }
    NSString *instanceRoot = @(getenv("POJAV_GAME_DIR"));
    if (instanceRoot.length == 0) {
        [self showComponentAlert:localize(@"profile.isolation.title", nil)
                          message:[NSString stringWithFormat:localize(@"profile.isolation.migrate_failed", nil),
                              @"POJAV_GAME_DIR unset"]];
        return;
    }
    // Task224：隔离目标 = versions/<id>/game（数据与版本 jar/json 分居）。
    NSString *relative = [NSString stringWithFormat:@"versions/%@/game", lastVersionId];
    NSString *legacyRelative = [NSString stringWithFormat:@"versions/%@", lastVersionId];
    NSString *isoDir = [instanceRoot stringByAppendingPathComponent:relative];
    NSString *legacyDir = [instanceRoot stringByAppendingPathComponent:legacyRelative];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *mkErr = nil;
    if (![fm fileExistsAtPath:isoDir] &&
        ![fm createDirectoryAtPath:isoDir withIntermediateDirectories:YES attributes:nil error:&mkErr]) {
        [self showComponentAlert:localize(@"profile.isolation.title", nil)
                          message:[NSString stringWithFormat:localize(@"profile.isolation.migrate_failed", nil),
                              mkErr.localizedDescription ?: @"mkdir failed"]];
        return;
    }

    // ★ Task223（清单第 5/6 项）：迁移源改为【当前 gameDir 的已解析目录】，
    // 而非只看实例根（modpack 客户端 mods 得以保留的根修，语义不变）。
    NSString *oldGameDirRaw = self.profile[@"gameDir"];
    NSString *migrateSource = instanceRoot;
    if ([oldGameDirRaw isKindOfClass:[NSString class]] && oldGameDirRaw.length > 0 &&
        ![oldGameDirRaw isEqualToString:@"."] && ![oldGameDirRaw isEqualToString:relative] &&
        ![oldGameDirRaw isEqualToString:legacyRelative]) {
        if ([oldGameDirRaw isAbsolutePath]) {
            migrateSource = oldGameDirRaw;
        } else {
            NSString *clean = [oldGameDirRaw hasPrefix:@"./"] ? [oldGameDirRaw substringFromIndex:2] : oldGameDirRaw;
            migrateSource = [instanceRoot stringByAppendingPathComponent:clean];
        }
    }
    BOOL ame223_sameDir = [migrateSource.stringByResolvingSymlinksInPath
        isEqualToString:isoDir.stringByResolvingSymlinksInPath];
    NSLog(@"[ProfileSettings] Task223/224 isolation migration source: %@ (old gameDir=%@, same-as-target=%d)",
          migrateSource, oldGameDirRaw, (int)ame223_sameDir);

    // 迁移清单：游戏运行时会读写的用户数据。刻意排除 logs/crash-reports
    // （历史垃圾）、versions/libraries/assets（共享层）。
    NSArray<NSString *> *ame217_items = @[
        @"saves", @"mods", @"config", @"resourcepacks", @"shaderpacks",
        @"options.txt", @"servers.dat", @"servers.dat_old", @"usercache.json",
        @"screenshots"
    ];

    // Task224：迁移进度弹窗（计数制）——旧实现同步跑在主线程，大 mods
    // 目录冻结 UI；且“迁移显示的是负数”族症状与本轮 -1 哨兵哨值无关
    // （本弹窗只显示已迁移条目计数，恒 >= 0）。
    UIAlertController *ame224_progressAlert = [UIAlertController
        alertControllerWithTitle:localize(@"profile.isolation.title", nil)
                         message:localize(@"profile.isolation.migrating", nil)
                  preferredStyle:UIAlertControllerStyleAlert];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self presentViewController:ame224_progressAlert animated:NO completion:nil];
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSInteger moved = 0;
        NSInteger skipped = 0;
        NSInteger legacyMoved = 0;
        NSMutableArray<NSString *> *skipNames = [NSMutableArray array];

        // (a) Task224 legacy 升级：versions/<id>/ 根上混居的游戏数据 → game/。
        //     jar/json 等版本元数据不动；目标已存在一律跳过。
        if (![legacyDir isEqualToString:isoDir] && [fm fileExistsAtPath:legacyDir]) {
            for (NSString *item in ame217_items) {
                NSString *src = [legacyDir stringByAppendingPathComponent:item];
                NSString *dst = [isoDir stringByAppendingPathComponent:item];
                if (![fm fileExistsAtPath:src]) continue;
                if ([fm fileExistsAtPath:dst]) continue;
                if ([fm moveItemAtPath:src toPath:dst error:nil]) {
                    legacyMoved++;
                }
            }
            if (legacyMoved > 0) {
                NSLog(@"[ProfileSettings] Task224 legacy isolation upgraded: %ld item(s) versions/<id> -> versions/<id>/game",
                      (long)legacyMoved);
            }
        }

        // (b) 主迁移：migrateSource → isoDir（Task223 语义）。
        if (!ame223_sameDir) {
            for (NSString *item in ame217_items) {
                NSString *src = [migrateSource stringByAppendingPathComponent:item];
                NSString *dst = [isoDir stringByAppendingPathComponent:item];
                if (![fm fileExistsAtPath:src]) continue;
                if ([fm fileExistsAtPath:dst]) {
                    skipped++;
                    [skipNames addObject:item];
                    continue;
                }
                NSError *mvErr = nil;
                if ([fm moveItemAtPath:src toPath:dst error:&mvErr]) {
                    moved++;
                    NSLog(@"[ProfileSettings] Task217/224: isolation migration moved '%@' -> %@", item, relative);
                } else {
                    skipped++;
                    [skipNames addObject:item];
                    NSLog(@"[ProfileSettings] Task217: isolation migration FAILED for '%@': %@", item, mvErr);
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.profile[@"gameDir"] = relative;
            [self saveSettings];
            [self reloadAllTableViews];
            [self updateHeroCard];
            NSLog(@"[ProfileSettings] Task217/224: version isolation ON for %@ (gameDir=%@; moved=%ld skipped=%ld legacyUpgraded=%ld)",
                  lastVersionId, relative, (long)moved, (long)skipped, (long)legacyMoved);

            NSString *summary;
            if (moved == 0 && skipped == 0 && legacyMoved == 0) {
                summary = [NSString stringWithFormat:localize(@"profile.isolation.migrated_clean", nil), relative];
            } else {
                summary = [NSString stringWithFormat:localize(@"profile.isolation.migrated", nil),
                    @(moved), @(skipped),
                    skipNames.count > 0 ? [skipNames componentsJoinedByString:@", "] : @"-"];
                if (legacyMoved > 0) {
                    summary = [summary stringByAppendingString:
                        [NSString stringWithFormat:localize(@"profile.isolation.legacy_upgraded", nil), @(legacyMoved)]];
                }
            }
            void (^ame224_showSummary)(void) = ^{
                [self showComponentAlert:localize(@"profile.isolation.title", nil) message:summary];
                // Task224：编辑页 ≠ 选中实例时提醒选用（启动链读选中 profile）。
                [self ame224_offerSelectIfNotSelected];
            };
            // Task224：呈现竞态守卫——progress 弹窗可能从未呈现（用户已离开
            // 本页 / 0.35s 延迟窗口内被顶掉），此时 dismiss 的 completion
            // 不会执行，汇总必须直发。
            if (ame224_progressAlert.presentingViewController != nil) {
                [ame224_progressAlert dismissViewControllerAnimated:NO completion:ame224_showSummary];
            } else {
                ame224_showSummary();
            }
        });
    });
}

/// Task224：回切共享 + 可选搬回。旧实现单向不搬回 = 数据滞留隔离目录，
/// 用户视角"存档消失"（10-06 实测："换回隔离/重启后两个版本都看不到"）。
/// 先切共享（立即生效），再询问是否把隔离目录的数据搬回共享根
/// （冲突一律跳过，绝不覆盖）。
- (void)ame224_disableIsolationWithOptionalMigration {
    NSString *instanceRoot = @(getenv("POJAV_GAME_DIR"));
    NSString *oldGameDirRaw = self.profile[@"gameDir"];
    NSString *isoSource = nil;
    if (instanceRoot.length > 0 && [oldGameDirRaw isKindOfClass:[NSString class]] &&
        oldGameDirRaw.length > 0 && ![oldGameDirRaw isEqualToString:@"."]) {
        isoSource = [oldGameDirRaw isAbsolutePath] ? oldGameDirRaw
            : [instanceRoot stringByAppendingPathComponent:
                ([oldGameDirRaw hasPrefix:@"./"] ? [oldGameDirRaw substringFromIndex:2] : oldGameDirRaw)];
    }

    // 先切共享（立即生效）
    self.profile[@"gameDir"] = @".";
    [self saveSettings];
    [self reloadAllTableViews];
    [self updateHeroCard];
    [self ame224_offerSelectIfNotSelected];

    if (isoSource.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:isoSource]) {
        [self showComponentAlert:localize(@"profile.isolation.title", nil)
                          message:localize(@"profile.isolation.disabled_note", nil)];
        return;
    }

    UIAlertController *ask = [UIAlertController
        alertControllerWithTitle:localize(@"profile.isolation.title", nil)
                         message:localize(@"profile.isolation.moveback_prompt", nil)
                  preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:localize(@"profile.isolation.moveback", nil)
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * _Nonnull action) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSFileManager *fm = NSFileManager.defaultManager;
                NSArray<NSString *> *items = @[
                    @"saves", @"mods", @"config", @"resourcepacks", @"shaderpacks",
                    @"options.txt", @"servers.dat", @"servers.dat_old", @"usercache.json",
                    @"screenshots"
                ];
                NSInteger movedBack = 0;
                NSInteger skippedBack = 0;
                for (NSString *item in items) {
                    NSString *src = [isoSource stringByAppendingPathComponent:item];
                    NSString *dst = [instanceRoot stringByAppendingPathComponent:item];
                    if (![fm fileExistsAtPath:src]) continue;
                    if ([fm fileExistsAtPath:dst]) {
                        skippedBack++;
                        continue;
                    }
                    if ([fm moveItemAtPath:src toPath:dst error:nil]) {
                        movedBack++;
                    } else {
                        skippedBack++;
                    }
                }
                NSLog(@"[ProfileSettings] Task224 isolation move-back: moved=%ld skipped=%ld (from %@)",
                      (long)movedBack, (long)skippedBack, isoSource);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showComponentAlert:localize(@"profile.isolation.title", nil)
                        message:[NSString stringWithFormat:localize(@"profile.isolation.moved_back", nil),
                                  @(movedBack), @(skippedBack)]];
                });
            });
        }]];
    [ask addAction:[UIAlertAction actionWithTitle:localize(@"profile.isolation.keep_isolated", nil)
        style:UIAlertActionStyleCancel
        handler:^(UIAlertAction * _Nonnull action) {
            [self showComponentAlert:localize(@"profile.isolation.title", nil)
                              message:localize(@"profile.isolation.disabled_note", nil)];
        }]];
    [self presentViewController:ask animated:YES completion:nil];
}

/// Task224：编辑页 ≠ 选中实例（Task207 解耦语义：⋯ 只编辑不选用）时，
/// 改完隔离配置后主动提醒选用——启动链 resolveKeyForCurrentProfile 读的
/// 是【选中】profile 的 gameDir，不提醒 = "开了隔离还是共享文件夹"
/// 的错位源头（10-06 实测："手动开了隔离还是共享文件夹"）。
- (void)ame224_offerSelectIfNotSelected {
    NSString *editedKey = self.profileName;
    NSString *selectedKey = PLProfiles.current.selectedProfileName;
    if (editedKey.length == 0 || [editedKey isEqualToString:selectedKey]) return;
    NSLog(@"[ProfileSettings] Task224 isolation changed on non-selected profile (edited=%@ selected=%@) -- offering selection",
          editedKey, selectedKey);
    UIAlertController *ask = [UIAlertController
        alertControllerWithTitle:localize(@"profile.isolation.title", nil)
                         message:[NSString stringWithFormat:localize(@"profile.isolation.select_prompt", nil),
                                   editedKey, selectedKey]
                  preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:localize(@"profile.isolation.select_now", nil)
        style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * _Nonnull action) {
            PLProfiles.current.selectedProfileName = editedKey;
            [PLProfiles.current save];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
            [self updateHeroCard];
            NSLog(@"[ProfileSettings] Task224 profile '%@' selected after isolation change", editedKey);
        }]];
    [ask addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
        style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ask animated:YES completion:nil];
}

- (void)openShadersManager {
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = [self currentProfileName];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 组件独立安装（Fabric API / OptiFine）

- (BOOL)isFabricProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    // Fabric profile id 形如 "fabric-loader-0.16.0-1.21"，含 "fabric"
    // Quilt profile id 含 "quilt"
    return [lastVersionId.lowercaseString containsString:@"fabric"];
}

- (BOOL)isOptiFineCompatibleProfile {
    return [self isVanillaProfile] || [self isForgeProfile];
}

/// 是否为原版 (Vanilla) profile
/// lastVersionId 不含 forge/fabric/quilt/neoforge 等加载器标识
- (BOOL)isVanillaProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return ![lower containsString:@"forge"]
        && ![lower containsString:@"fabric"]
        && ![lower containsString:@"quilt"];
}

/// 是否为 Forge profile（排除 NeoForge）
/// 关键修复：原先用 `containsString:@"forge"` 会误判 neoforge 为 forge，
/// 现显式排除 neoforge（参照 FCL/HMCL 的 OptiFine 兼容性判断）
- (BOOL)isForgeProfile {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return NO;
    NSString *lower = lastVersionId.lowercaseString;
    return [lower containsString:@"forge"] && ![lower containsString:@"neoforge"];
}

/// 当前 profile 的 mods 目录路径
- (NSString *)currentProfileModsPath {
    NSString *gameDir = self.profile[@"gameDir"];
    NSString *baseDir;
    const char *env = getenv("POJAV_GAME_DIR");
    if (env) {
        baseDir = [NSString stringWithUTF8String:env];
    } else {
        baseDir = NSHomeDirectory();
    }

    NSString *modsBase;
    if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
        if ([gameDir isAbsolutePath]) {
            modsBase = gameDir;
        } else {
            modsBase = [baseDir stringByAppendingPathComponent:gameDir];
        }
    } else {
        modsBase = baseDir;
    }

    NSString *modsDir = [modsBase stringByAppendingPathComponent:@"mods"];
    [[NSFileManager defaultManager] createDirectoryAtPath:modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return modsDir;
}

/// 当前 profile 的游戏版本（从 lastVersionId 解析）
- (NSString *)currentGameVersion {
    NSString *lastVersionId = self.profile[@"lastVersionId"];
    if (![lastVersionId isKindOfClass:[NSString class]] || lastVersionId.length == 0) return nil;
    // Task217（26.x 组件下载三连修的共因）：改用 ModpackExportService 的
    // parseVersionId 单一事实源。旧实现的版本号识别硬编码 hasPrefix:"1."——
    // MC 26.x（26.2/26.3）全部失配，函数退回完整 lastVersionId 字符串
    // （如 "fabric-loader-0.17.2-26.2"），下游 gameVersions 精确匹配必然落空：
    // Sodium+Iris/TouchController 报“找不到适配版本”，Fabric API 则静默
    // 回退 versions.firstObject（镜像乱序时 = 2024 年的旧版本）。
    // parseVersionId 的形态覆盖：fabric-loader-<loaderVer>-<mcVer> 前缀式、
    // <mcVer>-forge/-neoforge-<loaderVer> 中缀式、纯 <mcVer> 三类，26.x 通吃。
    NSDictionary *ame217_parsed = [ModpackExportService parseVersionId:lastVersionId];
    NSString *ame217_mc = ame217_parsed[@"minecraft"];
    if ([ame217_mc isKindOfClass:[NSString class]] && ame217_mc.length > 0) {
        return ame217_mc;
    }
    return lastVersionId;
}

- (void)installFabricAPIStandalone {
    if (![self isFabricProfile]) {
        [self showComponentAlert:localize(@"i18n_str_899", nil)
                          message:localize(@"i18n_str_900", nil)];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_902", nil)
                                                                     message:[NSString stringWithFormat:localize(@"i18n_str_903", nil), gameVersion, gameVersion]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_904", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startInstallFabricAPIWithGameVersion:gameVersion];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)installOptiFineStandalone {
    if (![self isOptiFineCompatibleProfile]) {
        [self showComponentAlert:localize(@"i18n_str_899", nil)
                          message:localize(@"i18n_str_905", nil)];
        return;
    }

    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }

    // 关键修复（参照 FCL/HMCL OptiFine 安装流程）：
    //   - Vanilla profile: 必须以版本补丁方式安装（launchwrapper + tweakClass），
    //     仅把 jar 放进 mods/ 目录对原版完全无效，因为原版没有 mods 加载机制。
    //   - Forge profile: Forge 可作为 mod 加载 OptiFine jar，沿用 mods/ 方式。
    BOOL isVanilla = [self isVanillaProfile];
    NSString *message = nil;
    if (isVanilla) {
        NSString *fmt = [[[[[localize(@"i18n_str_906", nil)
                              stringByAppendingString:localize(@"i18n_str_907", nil)]
                             stringByAppendingString:localize(@"i18n_str_2006", nil)]
                            stringByAppendingString:localize(@"i18n_str_2007", nil)]
                           stringByAppendingString:localize(@"i18n_str_2008", nil)]
                          stringByAppendingString:localize(@"i18n_str_911", nil)];
        message = [NSString stringWithFormat:fmt, gameVersion, gameVersion, gameVersion];
    } else {
        NSString *fmt = [[localize(@"i18n_str_906", nil)
                          stringByAppendingString:localize(@"i18n_str_912", nil)]
                         stringByAppendingString:localize(@"i18n_str_913", nil)];
        message = [NSString stringWithFormat:fmt, gameVersion, gameVersion];
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_914", nil)
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_904", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (isVanilla) {
            [self startInstallOptiFineAsPatch:gameVersion];
        } else {
            [self startInstallOptiFineWithGameVersion:gameVersion];
        }
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showComponentAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIAlertController *)showProgressAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:alert.view.centerYAnchor constant:20]
    ]];
    [indicator startAnimating];
    [self presentViewController:alert animated:YES completion:nil];
    return alert;
}

- (void)startInstallFabricAPIWithGameVersion:(NSString *)gameVersion {
    // redesign-download-ui Phase 4 Task 4.4：Fabric API 安装注册为统一下载任务，
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出统一进度页
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:[NSString stringWithFormat:@"fabric-api-%@", gameVersion]
                         displayName:@"Fabric API"
                      downloadSource:@"modrinth"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                       status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_915", nil), gameVersion]];
    }

    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = @"fabric api";
    filters[@"limit"] = @"20";

    __weak typeof(self) weakSelf = self;
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            if (error || results.count == 0) {
                NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_916", nil), error.localizedDescription ?: localize(@"i18n_str_917", nil)]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_916", nil), error.localizedDescription ?: localize(@"i18n_str_917", nil)]];
                return;
            }

            // 找到标题包含 "fabric api" 且不包含 "kotlin" 的项目
            NSDictionary *fabricAPI = nil;
            for (NSDictionary *mod in results) {
                NSString *title = mod[@"title"] ?: @"";
                if ([title.lowercaseString containsString:@"fabric api"] && ![title.lowercaseString containsString:@"kotlin"]) {
                    fabricAPI = mod;
                    break;
                }
            }
            if (!fabricAPI) {
                NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_919", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf showComponentAlert:localize(@"i18n_str_918", nil) message:localize(@"i18n_str_919", nil)];
                return;
            }

            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                     stageAtIndex:0
                                                         progress:-1.0
                                                          message:localize(@"i18n_str_920", nil)];

            [[ModrinthAPI sharedInstance] getVersionsForModWithID:fabricAPI[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf2 = weakSelf;
                    if (!strongSelf2) return;

                    if (versionError || versions.count == 0) {
                        NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_921", nil), versionError.localizedDescription ?: localize(@"i18n_str_463", nil)]}];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                        [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_921", nil), versionError.localizedDescription ?: localize(@"i18n_str_463", nil)]];
                        return;
                    }

                    // Task217：找到匹配当前 gameVersion 的【最新】版本。
                    // 旧实现两处病灶：① “第一个匹配”在 MCIM 镜像上命中任意
                    // 旧版本（镜像 /project/{id}/version 返回乱序，实测头部
                    // 是 2024 年的 0.100.7+1.21——26.3 装机“旧版本 API”实锤）；
                    // ② 无匹配时静默回退 versions.firstObject（再叠加镜像乱序
                    // = 明确的错版安装）。现改为：客户端 newest-first 排序 +
                    // release 通道优先；仍无匹配 → 明确报错（不再猜版本）。
                    ModVersion *matchingVersion = ame217_pickVersionForGameVersion(
                        ame217_modrinthVersionsNewestFirst(versions), gameVersion, @"fabric");
                    if (!matchingVersion) {
                        NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:6 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"component.fabricapi.no_match", nil), gameVersion]}];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                        [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:failError.localizedDescription];
                        return;
                    }

                    NSDictionary *primaryFile = matchingVersion.primaryFile;
                    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
                        NSError *failError = [NSError errorWithDomain:@"FabricAPI" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_922", nil)}];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                        [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:localize(@"i18n_str_922", nil)];
                        return;
                    }

                    [strongSelf2 downloadFabricAPIFile:primaryFile[@"url"]
                                                filename:primaryFile[@"filename"]
                                                  taskId:taskId
                                                 modInfo:fabricAPI];
                });
            }];
        });
    }];
}

- (void)downloadFabricAPIFile:(NSString *)urlString filename:(NSString *)filename taskId:(NSString *)taskId modInfo:(NSDictionary *)modInfo {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSURL *url = [NSURL URLWithString:urlString];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:url error:&downloadError];

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                NSError *failError = downloadError ?: [NSError errorWithDomain:@"FabricAPI" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_448", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_923", nil), downloadError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: @"fabric-api.jar";
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                          stageAtIndex:0
                                                               progress:1.0
                                                               message:[NSString stringWithFormat:localize(@"i18n_str_924", nil), saveFilename]];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_253", nil) message:[NSString stringWithFormat:localize(@"i18n_str_925", nil), saveFilename]];
            } else {
                NSError *failError = writeError ?: [NSError errorWithDomain:@"FabricAPI" code:6 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_926", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_927", nil), writeError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            }
        });
    });
}

#pragma mark - 组件独立安装（Sodium + Iris Shaders + Podium，Task 157）

/// Task217：Modrinth 版本列表客户端排序 + 通道偏好 + 版本匹配的统一实现。
/// 病历：MCIM 镜像的 /project/{id}/version 返回顺序与官方不同（实测官方
/// newest-first，镜像近乎乱序，2026-10 实测 fabric-api 镜像头部是
/// 2024-07 的 0.100.7+1.21）——“取第一个匹配”在镜像源上会命中任意旧版本
/// （26.3 装 Fabric API 落到 1.21 时代的旧包，用户实锤“旧版本 API”）。
/// 所有组件安装统一改为：客户端按 date_published 降序排序后再匹配。
/// ISO 8601 字符串字典序即时间序（镜像与官方的毫秒位数不同，差异只在
/// 亚秒级，不影响版本先后判定）。通道偏好：release 优先，beta/alpha 仅在
/// 无 release 适配版时兜底（一键安装的意图是“最新正式适配版”）。
static NSArray<ModVersion *> *ame217_modrinthVersionsNewestFirst(NSArray<ModVersion *> *versions) {
    if (versions.count < 2) return versions;
    return [versions sortedArrayUsingComparator:^NSComparisonResult(ModVersion *a, ModVersion *b) {
        NSComparisonResult ame217_r = [b.datePublished compare:a.datePublished options:NSLiteralSearch];
        if (ame217_r == NSOrderedSame) {
            ame217_r = [b.versionNumber compare:a.versionNumber options:NSNumericSearch];
        }
        return ame217_r;
    }];
}

/// Task217：两遍匹配——第一遍只认 release 通道，第二遍放开 beta/alpha。
/// 输入应先经 ame217_modrinthVersionsNewestFirst 排序（匹配到的即最新）。
static ModVersion *ame217_pickVersionForGameVersion(NSArray<ModVersion *> *versions
                                                    , NSString *gameVersion
                                                    , NSString *loader) {
    for (NSInteger ame217_pass = 0; ame217_pass < 2; ame217_pass++) {
        BOOL ame217_releaseOnly = (ame217_pass == 0);
        for (ModVersion *ver in versions) {
            if (![ver.gameVersions containsObject:gameVersion]) continue;
            if (ame217_releaseOnly && ![ver.versionType isEqualToString:@"release"]) continue;
            BOOL ame217_hasLoader = NO;
            for (NSString *l in ver.loaders) {
                if ([l.lowercaseString isEqualToString:loader.lowercaseString]) {
                    ame217_hasLoader = YES;
                    break;
                }
            }
            if (ame217_hasLoader) return ver;
        }
    }
    return nil;
}

/// Task 150 引入、Task 157 沿用：Modrinth 搜索 → 标题【精确】匹配 →
/// 按游戏版本 + 加载器选版本 → primaryFile。与 Fabric API 流程同逻辑，
/// 但匹配用全等比较——containsString 会误命中 "Sodium Extra" /
/// "Podium Port" 等衍生项目。Task217：版本选择改走排序 + 通道偏好统一实现
/// （镜像乱序免疫 + release 优先）。
- (void)ame150_fetchModrinthPrimaryFileWithQuery:(NSString *)query
                                      exactTitle:(NSString *)exactTitle
                                     gameVersion:(NSString *)gameVersion
                                          loader:(NSString *)loader
                                      completion:(void (^)(NSString *fileURL, NSString *filename, NSError *error))completion {
    // Task219：notFoundKey 参数化——旧实现把 sodium 的 not_found 文案硬编码在
    // 共享取数器里，TouchController 走同链路时弹的是“没有找到 Sodium / Iris /
    // Podium”（装机反馈“寻找 sou…”的同族问题：进度文案与失败文案全部串台）。
    [self ame219_fetchModrinthPrimaryFileWithQuery:query
                                         exactTitle:exactTitle
                                        gameVersion:gameVersion
                                             loader:loader
                                       notFoundKey:@"component.sodium.not_found"
                                          domain:@"SodiumComponent"
                                         completion:completion];
}

/// Task219：带 notFoundKey 的取数器（TouchController 传自己的键；解析主体
/// 与错误码语义与旧实现逐字一致）。
- (void)ame219_fetchModrinthPrimaryFileWithQuery:(NSString *)query
                                      exactTitle:(NSString *)exactTitle
                                     gameVersion:(NSString *)gameVersion
                                          loader:(NSString *)loader
                                    notFoundKey:(NSString *)notFoundKey
                                         domain:(NSString *)errorDomain
                                     completion:(void (^)(NSString *fileURL, NSString *filename, NSError *error))completion {
    NSMutableDictionary *filters = [NSMutableDictionary dictionary];
    filters[@"query"] = query;
    filters[@"limit"] = @"20";
    [[ModrinthAPI sharedInstance] searchModWithFilters:filters completion:^(NSArray *results, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || results.count == 0) {
                completion(nil, nil, [NSError errorWithDomain:errorDomain code:1
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(notFoundKey, nil),
                        [NSString stringWithFormat:@"%@ / %@", gameVersion, loader]]}]);
                return;
            }
            NSDictionary *match = nil;
            for (NSDictionary *mod in results) {
                NSString *title = mod[@"title"] ?: @"";
                if ([title.lowercaseString isEqualToString:exactTitle.lowercaseString]) {
                    match = mod;
                    break;
                }
            }
            if (!match) {
                completion(nil, nil, [NSError errorWithDomain:errorDomain code:2
                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(notFoundKey, nil),
                        [NSString stringWithFormat:@"%@ / %@", gameVersion, loader]]}]);
                return;
            }
            [[ModrinthAPI sharedInstance] getVersionsForModWithID:match[@"id"] completion:^(NSArray<ModVersion *> *versions, NSError *versionError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (versionError || versions.count == 0) {
                        completion(nil, nil, [NSError errorWithDomain:errorDomain code:3
                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(notFoundKey, nil),
                                [NSString stringWithFormat:@"%@ / %@", gameVersion, loader]]}]);
                        return;
                    }
                    ModVersion *matchingVersion = ame217_pickVersionForGameVersion(
                        ame217_modrinthVersionsNewestFirst(versions), gameVersion, loader);
                    if (!matchingVersion) {
                        completion(nil, nil, [NSError errorWithDomain:errorDomain code:4
                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(notFoundKey, nil),
                                [NSString stringWithFormat:@"%@ / %@", gameVersion, loader]]}]);
                        return;
                    }
                    NSDictionary *primaryFile = matchingVersion.primaryFile;
                    if (!primaryFile || ![primaryFile[@"url"] isKindOfClass:[NSString class]]) {
                        completion(nil, nil, [NSError errorWithDomain:errorDomain code:5
                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(notFoundKey, nil),
                                [NSString stringWithFormat:@"%@ / %@", gameVersion, loader]]}]);
                        return;
                    }
                    completion(primaryFile[@"url"], primaryFile[@"filename"], nil);
                });
            }];
        });
    }];
}

- (void)installSodiumStandalone {
    // Task 157：与 Fabric API 同门槛、同弹窗文案结构（模组名换成
    // Sodium + Iris Shaders）——仅 Fabric 实例可用（Sodium/Iris/Podium
    // 均为 Fabric 模组；用户指令：不再用简短"仅 Fabric 有效"提示）
    if (![self isFabricProfile]) {
        [self showComponentAlert:localize(@"i18n_str_899", nil)
                          message:localize(@"component.sodium.fabric_only", nil)];
        return;
    }
    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"component.sodium.confirm_title", nil)
                                                                     message:[NSString stringWithFormat:localize(@"component.sodium.confirm_message", nil), gameVersion]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_904", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startInstallSodiumWithGameVersion:gameVersion];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)startInstallSodiumWithGameVersion:(NSString *)gameVersion {
    // Task 157：与 Fabric API 同链路（统一下载任务 + Modrinth 搜索 → 版本匹配
    // → 下载进 mods/），一键安装三个模组：Sodium（高性能渲染）+ Iris（光影
    // 加载器，与 Sodium 配合）+ Podium（禁用 Sodium 的 PojavLauncher 检查
    // ——与 Task145 的 POJAV_RENDERER 导出收敛互为双保险：非 Mithril 会话
    // 不导出该变量，Podium 再兜底屏蔽模组侧检查）。
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:[NSString stringWithFormat:@"sodium-iris-podium-%@", gameVersion]
                         displayName:@"Sodium + Iris Shaders + Podium"
                      downloadSource:@"modrinth"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"component.sodium.searching", nil), gameVersion]];
    }
    __weak typeof(self) weakSelf = self;
    void (^ame157_failBlock)(NSError *) = ^(NSError *failError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
            [weakSelf showComponentAlert:localize(@"i18n_str_918", nil)
                                 message:failError.localizedDescription ?: localize(@"i18n_str_97", nil)];
        });
    };
    void (^ame157_downloadAll)(NSString *, NSString *, NSString *, NSString *, NSString *, NSString *) =
        ^(NSString *sodiumURL, NSString *sodiumFile, NSString *irisURL, NSString *irisFile, NSString *podiumURL, NSString *podiumFile) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *modsDir = [strongSelf currentProfileModsPath];
            NSError *dlError1 = nil;
            NSData *sodiumData = [strongSelf downloadDataWithURL:[NSURL URLWithString:sodiumURL] error:&dlError1];
            NSError *dlError2 = nil;
            NSData *irisData = sodiumData ? [strongSelf downloadDataWithURL:[NSURL URLWithString:irisURL] error:&dlError2] : nil;
            NSError *dlError3 = nil;
            NSData *podiumData = irisData ? [strongSelf downloadDataWithURL:[NSURL URLWithString:podiumURL] error:&dlError3] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!sodiumData || !irisData || !podiumData) {
                    NSError *failError = [NSError errorWithDomain:@"SodiumComponent" code:6
                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"component.sodium.download_failed", nil),
                            (dlError1 ?: dlError2 ?: dlError3).localizedDescription ?: localize(@"i18n_str_97", nil)]}];
                    ame157_failBlock(failError);
                    return;
                }
                NSString *sodiumPath = [modsDir stringByAppendingPathComponent:sodiumFile ?: @"sodium.jar"];
                NSString *irisPath = [modsDir stringByAppendingPathComponent:irisFile ?: @"iris.jar"];
                NSString *podiumPath = [modsDir stringByAppendingPathComponent:podiumFile ?: @"podium.jar"];
                NSError *writeError1 = nil;
                NSError *writeError2 = nil;
                NSError *writeError3 = nil;
                BOOL ok1 = [sodiumData writeToFile:sodiumPath options:NSDataWritingAtomic error:&writeError1];
                BOOL ok2 = ok1 ? [irisData writeToFile:irisPath options:NSDataWritingAtomic error:&writeError2] : NO;
                BOOL ok3 = ok2 ? [podiumData writeToFile:podiumPath options:NSDataWritingAtomic error:&writeError3] : NO;
                if (ok1 && ok2 && ok3) {
                    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                             stageAtIndex:0
                                                                 progress:1.0
                                                                 message:[NSString stringWithFormat:localize(@"i18n_str_924", nil), sodiumFile ?: @"sodium.jar"]];
                    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
                    [weakSelf showComponentAlert:localize(@"i18n_str_253", nil)
                                         message:[NSString stringWithFormat:localize(@"component.sodium.done", nil),
                                             [NSString stringWithFormat:@"%@ + %@ + %@",
                                                 sodiumFile ?: @"sodium.jar",
                                                 irisFile ?: @"iris.jar",
                                                 podiumFile ?: @"podium.jar"]]];
                } else {
                    NSError *failError = [NSError errorWithDomain:@"SodiumComponent" code:7
                        userInfo:@{NSLocalizedDescriptionKey: (writeError1 ?: writeError2 ?: writeError3).localizedDescription ?: localize(@"i18n_str_926", nil)}];
                    ame157_failBlock(failError);
                }
            });
        });
    };
    [self ame150_fetchModrinthPrimaryFileWithQuery:@"sodium"
                                        exactTitle:@"sodium"
                                       gameVersion:gameVersion
                                            loader:@"fabric"
                                        completion:^(NSString *sodiumURL, NSString *sodiumFile, NSError *error) {
        if (error || sodiumURL.length == 0) {
            ame157_failBlock(error ?: [NSError errorWithDomain:@"SodiumComponent" code:10 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_97", nil)}]);
            return;
        }
        // Task 157：Iris 光影加载器。Modrinth 项目标题为 "Iris Shaders"，
        // 先精确匹配全名，失败回退短名 "Iris"（防官方改名/搜索排序差异）
        void (^ame157_fetchPodium)(NSString *, NSString *) = ^(NSString *irisURL, NSString *irisFile) {
            [weakSelf ame150_fetchModrinthPrimaryFileWithQuery:@"podium"
                                                    exactTitle:@"podium"
                                                   gameVersion:gameVersion
                                                        loader:@"fabric"
                                                    completion:^(NSString *podiumURL, NSString *podiumFile, NSError *error3) {
                if (error3 || podiumURL.length == 0) {
                    ame157_failBlock(error3 ?: [NSError errorWithDomain:@"SodiumComponent" code:12 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_97", nil)}]);
                    return;
                }
                ame157_downloadAll(sodiumURL, sodiumFile, irisURL, irisFile, podiumURL, podiumFile);
            }];
        };
        [weakSelf ame150_fetchModrinthPrimaryFileWithQuery:@"iris shaders"
                                                exactTitle:@"iris shaders"
                                               gameVersion:gameVersion
                                                    loader:@"fabric"
                                                    completion:^(NSString *irisURL, NSString *irisFile, NSError *error2) {
            if (error2 || irisURL.length == 0) {
                [weakSelf ame150_fetchModrinthPrimaryFileWithQuery:@"iris"
                                                        exactTitle:@"iris"
                                                       gameVersion:gameVersion
                                                            loader:@"fabric"
                                                        completion:^(NSString *irisURL2, NSString *irisFile2, NSError *error2b) {
                    if (error2b || irisURL2.length == 0) {
                        ame157_failBlock(error2b ?: error2 ?: [NSError errorWithDomain:@"SodiumComponent" code:11 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_97", nil)}]);
                        return;
                    }
                    ame157_fetchPodium(irisURL2, irisFile2);
                }];
                return;
            }
            ame157_fetchPodium(irisURL, irisFile);
        }];
    }];
}

- (void)startInstallOptiFineWithGameVersion:(NSString *)gameVersion {
    // redesign-download-ui Phase 4 Task 4.4：OptiFine（mods 方式）注册为统一下载任务，
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出统一进度页
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:[NSString stringWithFormat:@"optifine-%@", gameVersion]
                         displayName:@"OptiFine"
                      downloadSource:@"bmclapi"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                       status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_928", nil), gameVersion]];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // BMCL API 列表查询
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = [NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]];
            });
            return;
        }

        // 切换到下载阶段
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_930", nil), optiFineType, optiFinePatch]];

        // 下载 OptiFine
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *data = [self downloadDataWithURL:dlURL error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!data || downloadError) && filename) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                data = officialData;
                downloadError = nil;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            if (!data || downloadError) {
                NSError *failError = downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_448", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_931", nil), downloadError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
                return;
            }

            NSString *modsDir = [strongSelf2 currentProfileModsPath];
            NSString *saveFilename = filename ?: [NSString stringWithFormat:@"OptiFine_%@_%@_%@.jar", gameVersion, optiFineType, optiFinePatch];
            NSString *savePath = [modsDir stringByAppendingPathComponent:saveFilename];

            NSError *writeError = nil;
            BOOL success = [data writeToFile:savePath options:NSDataWritingAtomic error:&writeError];

            if (success) {
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                          stageAtIndex:0
                                                               progress:1.0
                                                               message:[NSString stringWithFormat:localize(@"i18n_str_924", nil), saveFilename]];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_253", nil) message:[NSString stringWithFormat:localize(@"i18n_str_932", nil), optiFineType, optiFinePatch]];
            } else {
                NSError *failError = writeError ?: [NSError errorWithDomain:@"OptiFine" code:3 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_926", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_927", nil), writeError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            }
        });
    });
}

#pragma mark - OptiFine 版本补丁安装（Vanilla profile，参照 FCL/HMCL OptiFineInstallTask）

/// 以版本补丁方式安装 OptiFine（适用于 Vanilla profile）
/// 参照 FCL OptiFineInstallTask 与 HMCL OptiFineInstallTask：
///   1. 下载 OptiFine jar 到 libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
///   2. 创建 versions/<versionId>/<versionId>.json，mainClass 设为
///      net.minecraft.launchwrapper.Launcher，并附加 --tweakClass optifine.OptiFineTweaker
///   3. inheritsFrom 指向原版版本（vanilla parent 必须已存在）
///   4. 创建新 profile 并切换为当前 profile
- (void)startInstallOptiFineAsPatch:(NSString *)gameVersion {
    // redesign-download-ui Phase 4 Task 4.4：OptiFine 版本补丁安装注册为统一下载任务，
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出统一进度页
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                        resourceName:[NSString stringWithFormat:@"optifine-patch-%@", gameVersion]
                         displayName:[NSString stringWithFormat:@"OptiFine (%@)", gameVersion]
                      downloadSource:@"bmclapi"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                       status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_928", nil), gameVersion]];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // 1. BMCL API 查询适配当前游戏版本的 OptiFine 列表
        NSString *listURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", gameVersion];
        NSURL *url = [NSURL URLWithString:listURL];
        NSError *listError = nil;
        NSData *listData = [self downloadDataWithURL:url error:&listError];

        NSString *optiFineType = nil;
        NSString *optiFinePatch = nil;
        NSString *filename = nil;

        if (listData && !listError) {
            NSError *jsonError = nil;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:listData options:0 error:&jsonError];
            if (!jsonError && [versions isKindOfClass:[NSArray class]] && versions.count > 0) {
                NSDictionary *first = versions.firstObject;
                if ([first isKindOfClass:[NSDictionary class]]) {
                    optiFineType = first[@"type"] ?: @"HD_U";
                    optiFinePatch = first[@"patch"];
                    filename = first[@"filename"];
                }
            }
        }

        if (!optiFinePatch) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = [NSError errorWithDomain:@"OptiFine" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_929", nil), gameVersion]];
            });
            return;
        }

        // 2. 下载 OptiFine jar
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"i18n_str_930", nil), optiFineType, optiFinePatch]];
        NSString *downloadURL = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@/%@/%@", gameVersion, optiFineType, optiFinePatch];
        NSURL *dlURL = [NSURL URLWithString:downloadURL];
        NSError *downloadError = nil;
        NSData *jarData = [self downloadDataWithURL:dlURL error:&downloadError];

        // fallback: OptiFine 官方源
        if ((!jarData || downloadError) && filename.length > 0) {
            NSString *officialURL = [NSString stringWithFormat:@"https://optifine.net/downloadx?f=%@", filename];
            NSURL *officialURLObject = [NSURL URLWithString:officialURL];
            NSError *officialError = nil;
            NSData *officialData = [self downloadDataWithURL:officialURLObject error:&officialError];
            if (officialData && !officialError) {
                jarData = officialData;
                downloadError = nil;
            }
        }

        if (!jarData || downloadError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = downloadError ?: [NSError errorWithDomain:@"OptiFine" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_448", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_931", nil), downloadError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            });
            return;
        }

        // 3. 检查原版父版本必须已存在（否则 inheritsFrom 会失败）
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *gameDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *parentJsonPath = [gameDir stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@/%@.json", gameVersion, gameVersion]];
        if (![[NSFileManager defaultManager] fileExistsAtPath:parentJsonPath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = [NSError errorWithDomain:@"OptiFine" code:4 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_933", nil), gameVersion]}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_934", nil), gameVersion, gameVersion]];
            });
            return;
        }

        // 4. 写入 jar 到 libraries/optifine/OptiFine/<mcVersion>/<versionId>.jar
        //    参照 FCL/HMCL：OptiFine jar 作为 launchwrapper 的 tweakClass 输入，
        //    mainClass 设为 net.minecraft.launchwrapper.Launcher
        NSString *versionId = [NSString stringWithFormat:@"%@-OptiFine_%@_%@", gameVersion, optiFineType, optiFinePatch];
        NSString *optifineJarPath = [NSString stringWithFormat:@"optifine/OptiFine/%@/%@.jar", gameVersion, versionId];
        NSString *optifineJarAbsPath = [NSString stringWithFormat:@"%@/libraries/%@", gameDir, optifineJarPath];
        NSString *jarDir = [optifineJarAbsPath stringByDeletingLastPathComponent];
        [[NSFileManager defaultManager] createDirectoryAtPath:jarDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *writeJarError = nil;
        BOOL jarOk = [jarData writeToFile:optifineJarAbsPath options:NSDataWritingAtomic error:&writeJarError];
        if (!jarOk) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                NSError *failError = writeJarError ?: [NSError errorWithDomain:@"OptiFine" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_935", nil)}];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_936", nil), writeJarError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            });
            return;
        }

        // 5. 创建 version JSON（launchwrapper + tweakClass + inheritsFrom）
        NSDictionary *versionJson = @{
            @"id": versionId,
            @"inheritsFrom": gameVersion,
            @"type": @"release",
            @"mainClass": @"net.minecraft.launchwrapper.Launcher",
            @"minecraftArguments": @"--username ${auth_player_name} --version ${version_name} --gameDir ${game_directory} --assetsDir ${assets_root} --assetIndex ${assets_index_name} --uuid ${auth_uuid} --accessToken ${auth_access_token} --userType ${user_type} --versionType ${version_type} --tweakClass optifine.OptiFineTweaker",
            @"libraries": @[
                @{
                    @"name": [NSString stringWithFormat:@"optifine:OptiFine:%@", gameVersion],
                    @"downloads": @{
                        @"artifact": @{
                            @"path": optifineJarPath,
                            @"url": @"",
                            @"size": @(jarData.length),
                            @"sha1": @""
                        }
                    }
                }
            ],
            @"jar": gameVersion,
            @"minimumLauncherVersion": @21
        };
        NSString *versionDir = [gameDir stringByAppendingPathComponent:[NSString stringWithFormat:@"versions/%@", versionId]];
        [[NSFileManager defaultManager] createDirectoryAtPath:versionDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *jsonPath = [versionDir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.json", versionId]];
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:versionJson options:NSJSONWritingPrettyPrinted error:nil];
        NSError *writeJsonError = nil;
        [jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&writeJsonError];

        if (writeJsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf2 = weakSelf;
                if (!strongSelf2) return;
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
                [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:writeJsonError];
                [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
                [strongSelf2 showComponentAlert:localize(@"i18n_str_918", nil) message:[NSString stringWithFormat:localize(@"i18n_str_937", nil), writeJsonError.localizedDescription ?: localize(@"i18n_str_97", nil)]];
            });
            return;
        }

        // 6. 注册新 profile 并切换为当前 profile（参照 FCL/HMCL 行为）
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;

            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
            profile[@"name"] = versionId;
            profile[@"lastVersionId"] = versionId;
            profile[@"gameDir"] = @".";
            profile[@"type"] = @"custom";
            profile[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:profile withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;

            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];

            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                      stageAtIndex:0
                                                           progress:1.0
                                                           message:[NSString stringWithFormat:localize(@"i18n_str_938", nil), versionId]];
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
            [strongSelf2 showComponentAlert:localize(@"i18n_str_253", nil)
                                     message:[NSString stringWithFormat:
                                              localize(@"i18n_str_939", nil),
                                              optiFineType, optiFinePatch, versionId]];
        });
    });
}

// Task 140：实例页渲染器选择器 —— 选项全量：跟随全局（删键）+ 经典可用项
//（auto/gl4es/zink/...，按 dylib 存在性过滤）+ MG 家族三后端。旧版只有
// 经典四项：用户无法给单个游戏选 MG 后端（只能在设置页选全局），而设置页
// 的选择又被旧双写改到“当前游戏”——两头堵。现在实例页独占 per-game 选择，
// 家族键直接写 profile（启动链 ame_effective_renderer 原样识别）。
// Task 142：实例页渲染器选择器 —— 单一经典列表（auto/gl4es/angle/
// mobileglues/zink/ltw/vulkan，按 dylib 存在性过滤，与设置页渲染器行
// 同源）+ 唯一的 "mg" 条目（getRendererKeys 已含）。用户明令："渲染器
// 选择只有一个 mg，而且不写什么后端，后端是根据 mg 设置选择的后端启动，
// 默认 vulkan"——选中 mg 只写逻辑键 "mg"，后端在启动时按
// mobileglues.renderer_backend 解析（设置页 MobileGlues 分区选择）。
// "跟随全局"不再是列表选项：它是外置开关（buildRendererFollowSwitch），
// 开启时渲染器行置灰不可点。legacy 家族键（迁移前残留）在 ✓ 匹配上
// 归一到 "mg"。
- (void)showRendererSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_940", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *renderers = getRendererKeys(NO);
    NSArray *displayNames = getRendererNames(NO);
    for (NSInteger i = 0; i < renderers.count; i++) {
        NSString *renderer = renderers[i];
        NSString *name = i < displayNames.count ? displayNames[i] : renderer;
        // ✓ 匹配：精确命中，或 mg 条目命中 legacy 家族键（归一显示）
        BOOL ame142_selected = [self.selectedRenderer isEqualToString:renderer] ||
            ([renderer isEqualToString:@ RENDERER_KEY_MG] &&
             self.selectedRenderer != nil &&
             [getRendererFamilyKeys() containsObject:self.selectedRenderer]);
        if (ame142_selected) {
            name = [NSString stringWithFormat:@"✓ %@", name];
        }
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedRenderer = renderer;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        // Task 150：渲染器行现在是高级设置 section 的第 1 行（跟随全局
        // 开关已退役）
        UITableViewCell *cell = [self cellForGlobalSection:3 row:0];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    NSLog(@"[ProfileSettings] Task150: renderer picker opened (%ld options incl. single 'mg'; follow-global retired)",
          (long)renderers.count);
    [self presentViewController:alert animated:YES completion:nil];
}

// Task 150（[可撤销] 删除渲染器全局控制）：跟随全局开关整体退役
// （buildRendererFollowSwitch / rendererFollowSwitchChanged 删除）——
// 每个实例强制单独选择渲染器，无键实例缺省 auto（loadSettings 同口径）。
// 撤销 = 恢复本 pragma 区 + setupSections 的开关行 + cellForItem/didSelect
// 的跟随全局分支 + loadSettings/saveSettings 的 nil（删键）语义。

/// 判断当前 profile 的 MC 版本是否为 26.2+（需要图形 API 切换）
- (BOOL)isCurrentProfileModernVersion {
    NSString *versionId = self.profile[@"lastVersionId"] ?: @"";
    // 修复 Fabric/Quilt/Forge loader profile 的版本号识别：
    //   原 implementation 用 hasPrefix:@"26." 判断，但 Fabric profile 的 lastVersionId
    //   形如 "fabric-loader-0.16.0-26.2"，前缀是 "fabric-loader" 不是 "26."，导致
    //   MC 26.2+ Fabric profile 看不到"图形 API"选项。
    //   修复：先用 ModpackExportService.parseVersionId 提取 minecraft 版本号，
    //   再用提取后的版本号判断。也支持 forge/neoforge 形如 "26.2-forge-..."。
    NSDictionary *parsed = [ModpackExportService parseVersionId:versionId];
    NSString *mcVersion = parsed[@"minecraft"] ?: versionId;
    // 26.x 版本（26w02a 等快照也匹配）
    if ([mcVersion hasPrefix:@"26."]) return YES;
    if ([mcVersion hasPrefix:@"26w"]) return YES;
    // 1.21.8+ 版本（Mojang 在 1.21.8 引入 Vulkan API）
    if ([mcVersion hasPrefix:@"1.21."]) {
        NSString *minorStr = [mcVersion substringFromIndex:5];
        NSInteger minor = [minorStr integerValue];
        if (minor >= 8) return YES;
    }
    return NO;
}

/// 图形 API 显示名
- (NSString *)graphicsApiDisplayName:(NSString *)api {
    if ([api isEqualToString:@"prefer_vulkan"]) return localize(@"i18n_str_941", nil);
    if ([api isEqualToString:@"prefer_opengl"]) return localize(@"i18n_str_942", nil);
    return localize(@"i18n_str_943", nil);
}

/// 图形 API 选择器（MC 26.2+ 专用）
- (void)showGraphicsApiSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_944", nil)
                                                                   message:localize(@"i18n_str_945", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *keys = @[@"default", @"prefer_vulkan", @"prefer_opengl"];
    NSArray *names = @[localize(@"i18n_str_943", nil), localize(@"i18n_str_941", nil), localize(@"i18n_str_942", nil)];

    for (NSInteger i = 0; i < keys.count; i++) {
        NSString *key = keys[i];
        NSString *name = i < names.count ? names[i] : key;
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedGraphicsApi = key;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:1];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

/// Task173：TouchController 一键安装 + 自动配置（Sodium 同款流程，取代
/// Task172 的开关式 showTouchControllerSelector——用户指令"TouchController
/// 选项是跟 sodium 一样的样式，点击自动安装加自动配置，而不是只有自动
/// 配置"）。
/// 流程：Fabric 门槛检查 → 确认弹窗（双语硬编码，Task169 先例）→
/// Modrinth 精确匹配 "TouchController" 项目（fabric loader + 当前游戏版本）
/// → 下载 primaryFile 落 mods/（统一下载任务 + autoPresentDetail）→
/// 成功后写 profile touchController=YES（Task172 键沿用，启动链
/// ame172_applyProfileTouchController 自动落 UDP 模式 + 屏蔽启动器控件）。
- (void)installTouchControllerStandalone {
    if (![self isFabricProfile]) {
        [self showComponentAlert:localize(@"i18n_str_899", nil)
                          message:localize(@"component.touch.fabric_only", nil)];
        return;
    }
    NSString *gameVersion = [self currentGameVersion];
    if (!gameVersion) {
        [self showComponentAlert:localize(@"i18n_str_899", nil) message:localize(@"i18n_str_901", nil)];
        return;
    }
    // Task219：版本支持预检——TouchController 项目（Modrinth 实测 2026-10：
    // slug=touchcontroller，作者 fifth_light，543 个版本）的 game_versions
    // 从 1.12.2 起，更老版本（1.11-）必然“找不到适配版本”。装机反馈
    //（1.8.9 VirGL 实例装 TouchController → sodium 文案的“未找到”）——现在
    // 直接前置拦截并说明支持范围，不再浪费网络往返。
    if ([self ame219_touchControllerUnsupportedVersion:gameVersion]) {
        [self showComponentAlert:localize(@"component.touch.unsupported_title", nil)
                          message:[NSString stringWithFormat:localize(@"component.touch.unsupported", nil), gameVersion]];
        return;
    }
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"TouchController"
                                                                     message:[NSString stringWithFormat:
        localize(@"component.touch.confirm_message", nil), gameVersion, gameVersion]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_904", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self startInstallTouchControllerWithGameVersion:gameVersion];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

/// Task219：TouchController 版本预检——“1.x” 且 x < 12 的版本形态
///（1.0-1.11.x）不在模组支持面内（1.12.2+）。26.x/快照形态不拦截（由
/// 版本匹配器如实裁决）。注：刻意不用 hasPrefix 字面量（Task217 A1 锚点
/// 声明 ProfileSettings 里不再出现该解析形态——这里用分量解析绕开）。
- (BOOL)ame219_touchControllerUnsupportedVersion:(NSString *)gameVersion {
    if (![gameVersion isKindOfClass:NSString.class] || gameVersion.length == 0) return NO;
    NSArray<NSString *> *ame219_parts = [gameVersion componentsSeparatedByString:@"."];
    if (ame219_parts.count < 2) return NO;              // 无点分形态（快照等）不拦截
    if (![ame219_parts[0] isEqualToString:@"1"]) return NO;  // 26.x 等新版本形态
    return [ame219_parts[1] integerValue] < 12;
}

- (void)startInstallTouchControllerWithGameVersion:(NSString *)gameVersion {
    // Task173：与 Sodium 组件同链路（统一下载任务 + Modrinth 搜索 → 版本匹配
    // → 下载进 mods/），单模组安装 + 成功后落 profile 自动配置键。
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:[NSString stringWithFormat:@"touchcontroller-%@", gameVersion]
                         displayName:@"TouchController"
                      downloadSource:@"modrinth"
                             rawTask:nil
                      supportsResume:NO
                             iconURL:nil];
    NSString *taskId = taskItem.taskId;
    if (taskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId stages:PLTaskStagesSingleFile()];
        taskItem.autoPresentDetail = YES;
        [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     status:PLTaskStageStatusRunning];
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 stageAtIndex:0
                                                     progress:-1.0
                                                      message:[NSString stringWithFormat:localize(@"component.touch.searching", nil), gameVersion]];
    }
    __weak typeof(self) weakSelf = self;
    void (^ame173_failBlock)(NSError *) = ^(NSError *failError) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
            [[DownloadTaskManager sharedManager] updateTaskWithId:taskId error:failError];
            [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateFailed];
            [weakSelf showComponentAlert:localize(@"i18n_str_918", nil)
                                 message:failError.localizedDescription ?: localize(@"i18n_str_97", nil)];
        });
    };
    // Task219：改走带 notFoundKey 的取数器（失败文案不再串台成 Sodium）
    [self ame219_fetchModrinthPrimaryFileWithQuery:@"touchcontroller"
                                         exactTitle:@"touchcontroller"
                                        gameVersion:gameVersion
                                             loader:@"fabric"
                                       notFoundKey:@"component.touch.not_found"
                                          domain:@"TouchControllerComponent"
                                         completion:^(NSString *tcURL, NSString *tcFile, NSError *error) {
        if (error || tcURL.length == 0) {
            ame173_failBlock(error ?: [NSError errorWithDomain:@"TouchControllerComponent" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_97", nil)}]);
            return;
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            NSString *modsDir = [strongSelf currentProfileModsPath];
            NSError *dlError = nil;
            NSData *tcData = [strongSelf downloadDataWithURL:[NSURL URLWithString:tcURL] error:&dlError];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!tcData) {
                    NSError *failError = [NSError errorWithDomain:@"TouchControllerComponent" code:2
                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"component.touch.download_failed", nil),
                            dlError.localizedDescription ?: localize(@"i18n_str_97", nil)]}];
                    ame173_failBlock(failError);
                    return;
                }
                NSString *tcPath = [modsDir stringByAppendingPathComponent:tcFile ?: @"touchcontroller.jar"];
                NSError *writeError = nil;
                BOOL ok = [tcData writeToFile:tcPath options:NSDataWritingAtomic error:&writeError];
                if (ok) {
                    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                             stageAtIndex:0
                                                                 progress:1.0
                                                                  message:[NSString stringWithFormat:localize(@"i18n_str_924", nil), tcFile ?: @"touchcontroller.jar"]];
                    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
                    [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateCompleted];
                    // Task173：安装成功 → 落自动配置键（Task172 键沿用；启动链
                    // ame172_applyProfileTouchController 落 UDP + 屏蔽控件）。
                    weakSelf.touchControllerEnabled = YES;
                    // ★ Task223（用户报“下载完成后没有自动配置：设置项状态没有
                    //   刷新，手动重启就行”）：自动配置提前到【安装完成时刻】
                    //   落地——三项全局键立即生效（设置页/右面板即时反映，不再
                    //   需要重启或等首次启动），同时撤掉用户关闭哨兵（新安装 =
                    //   明确的启用意图）+ 广播刷新已打开的设置页。
                    setPrefBool(@"control.mod_touch_enable", YES);
                    setPrefObject(@"control.mod_touch_mode", @1);  // UDP
                    setPrefBool(@"control.mod_touch_hide_controls", YES);
                    setPrefBool(@"control.mod_touch_user_off", NO);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        // Task223：专属刷新广播（已打开的 TC 设置页重读三项全局键）。
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"TouchControllerSettingsChanged" object:nil];
                        [[NSNotificationCenter defaultCenter]
                            postNotificationName:@"ReloadProfileList" object:nil];
                    });
                    [weakSelf saveSettings];
                    [weakSelf reloadAllTableViews];
                    NSLog(@"[TouchController] Task173 installed %@ for %@ -- auto-config applied immediately (UDP + hide controls)", tcFile, gameVersion);
                    [weakSelf showComponentAlert:localize(@"i18n_str_253", nil)
                                         message:[NSString stringWithFormat:
                        localize(@"component.touch.done", nil),
                        tcFile ?: @"touchcontroller.jar", tcFile ?: @"touchcontroller.jar"]];
                } else {
                    NSError *failError = [NSError errorWithDomain:@"TouchControllerComponent" code:3
                        userInfo:@{NSLocalizedDescriptionKey: writeError.localizedDescription ?: localize(@"i18n_str_926", nil)}];
                    ame173_failBlock(failError);
                }
            });
        });
    }];
}

- (void)showJavaVersionSelector {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_946", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    // 从 java.java_homes 偏好动态获取已安装的 Java 版本列表
    NSMutableDictionary *javaHomes = [getPrefObject(@"java.java_homes") mutableCopy];
    if (!javaHomes) {
        javaHomes = [NSMutableDictionary dictionary];
    }
    NSMutableArray *versions = [[javaHomes allKeys] mutableCopy];
    // "0" 表示自动选择，单独处理
    [versions removeObject:@"0"];
    [versions sortUsingSelector:@selector(compare:)];
    // 自动选项放最前
    [versions insertObject:@"0" atIndex:0];

    for (NSString *ver in versions) {
        NSString *name = [ver isEqualToString:@"0"] ? localize(@"preference.auto_select", nil) : [NSString stringWithFormat:@"Java %@", ver];
        [alert addAction:[UIAlertAction actionWithTitle:name
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            self.selectedJavaVersion = ver;
            [self saveSettings];
            [self reloadAllTableViews];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self cellForGlobalSection:3 row:1];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMemoryAllocator {
    // Task159：内存调整改为与游戏目录（editGameDir）同款的输入框弹窗——
    // Task157 居中卡片（拉条 + "自动分配内存"开关 + ✕）整体退役：输入框
    // 形态放不下开关，用户本轮定稿为纯数值输入（512 ~ 可分配最大内存）。
    // 边界约定：
    // - 存量 memoryAuto=YES 实例（allocatedMemory=0）：表格行仍显示
    //   "自动分配内存"（memory.auto_row 键保留），弹窗预填 512，确认后落
    //   实际值并清 memoryAuto 标记（回到纯手动语义）；用户不碰内存时启动
    //   链 ame141_currentLaunchAllocMem 的 0=自动比例语义不变。
    // - "设备最大内存"= 物理内存 MB；"可分配最大内存"= self.maxMemory
    //   （loadSettings：物理×0.8，下限 1024，与原拉条上限同口径）。
    // - 恢复默认按钮不搬（用户指令：游戏目录弹窗三按钮 → 本弹窗仅取消/确定）。
    NSInteger ame159_deviceTotalMB = (NSInteger)(NSProcessInfo.processInfo.physicalMemory >> 20);
    NSInteger ame159_initial = self.allocatedMemory > 0 ? self.allocatedMemory : 512;

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"memory.adjust_title", nil)
                         message:[NSString stringWithFormat:localize(@"memory.adjust_message", nil),
                                  (long)ame159_deviceTotalMB, (long)self.maxMemory]
                  preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.keyboardType = UIKeyboardTypeNumberPad;
        textField.text = [NSString stringWithFormat:@"%ld", (long)ame159_initial];
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel handler:nil]];

    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil)
                                              style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSInteger ame159_value = alert.textFields.firstObject.text.intValue;
        // 输入值 clamp 到 [512, 可分配最大内存]（用户指令范围）；空/非数字
        // 输入 intValue=0 → 落到下限 512
        if (ame159_value < 512) ame159_value = 512;
        if (ame159_value > self.maxMemory) ame159_value = self.maxMemory;
        self.allocatedMemory = ame159_value;
        // 写实际值即退出自动态（memoryAuto 标记随 saveSettings 手动分支清除）
        self.memoryAutoEnabled = NO;
        [self saveSettings];
        [self reloadAllTableViews];
    }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Done / Close

- (void)actionClose {
    // 收起键盘
    [self.view endEditing:YES];
    // 直接关闭，不保存（设置项在编辑过程中已自动保存）
    if (self.navigationController) {
        if (self.navigationController.viewControllers.firstObject == self) {
            [self dismissViewControllerAnimated:YES completion:nil];
        } else {
            [self.navigationController popViewControllerAnimated:YES];
        }
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)actionDone {
    // 收起键盘，触发 EditingDidEnd
    [self.view endEditing:YES];

    NSString *newName = self.profile[@"name"];
    if ([newName length] == 0) {
        // 名称为空，恢复原名
        self.profile[@"name"] = self.originalName;
        newName = self.originalName;
    }

    // 检查重命名冲突
    // Task162：重命名的【旧键】改为 profileDictKey（字典键）；无键路径
    //（新建 profile）回退 originalName。删旧键、建新键、同步 selected、
    // 同步 profileDictKey——后续 saveSettings 继续落在新键上。
    NSString *ame162_oldKey = self.profileDictKey.length > 0 ? self.profileDictKey : self.originalName;
    if (![self.originalName isEqualToString:newName]) {
        // 名称变了，检查新名是否已存在
        if (PLProfiles.current.profiles[newName]) {
            // 重名，提示并取消
            showDialog(localize(@"i18n_str_42", nil), localize(@"i18n_str_1289", nil));
            return;
        }
        // 删除旧键，添加新键
        if (ame162_oldKey.length > 0) {
            [PLProfiles.current.profiles removeObjectForKey:ame162_oldKey];
        }
        PLProfiles.current.profiles[newName] = self.profile;
        self.profileDictKey = newName;
        // 如果原来选中的是被重命名的 profile，更新选中
        if ([PLProfiles.current.selectedProfileName isEqualToString:ame162_oldKey]) {
            PLProfiles.current.selectedProfileName = newName;
        }
    } else {
        // 名称没变，直接保存（Task162：按键落位，不写幻影）
        if (ame162_oldKey.length > 0) {
            PLProfiles.current.profiles[ame162_oldKey] = self.profile;
        } else {
            PLProfiles.current.profiles[newName] = self.profile;
        }
    }

    [PLProfiles.current save];

    // 发送通知刷新配置文件列表
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:newName];

    // 关闭
    [self actionClose];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 背景效果切换后重新应用 tableView 毛玻璃 backgroundView，
        // 否则切换毛玻璃↔半透明后旧 backgroundView 仍存在造成视觉不一致
        [self applyBackgroundBlurToTableView];
        [self reloadAllTableViews];
    });
}

/// 给 self.tableView 设置底层背景视图，遮挡栈底 VC 内容同时透出全局背景。
/// - 有自定义启动器背景时：使用 UIVisualEffectView (SystemThinMaterial) 毛玻璃背景，
///   模糊全局背景图但仍能透出，并遮挡栈底 VersionManager 的卡片。
/// - 无自定义背景时：使用 systemBackgroundColor，与系统默认外观一致。
- (void)applyBackgroundBlurToTableView {
    // 应用到两个 tableView（leftTableView 和 rightTableView）
    for (UITableView *tv in @[self.leftTableView, self.rightTableView]) {
        if (!tv) continue;
        // 清理旧 backgroundView（避免叠加）
        tv.backgroundView = nil;

        if ([[BackgroundManager sharedManager] hasBackground]) {
            // 有自定义背景：使用毛玻璃 backgroundView 模糊背景并遮挡栈底 VC
            UIBlurEffect *blur;
            if (@available(iOS 13.0, *)) {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
            } else {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
            }
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blurView.frame = tv.bounds;
            // 按 uiEffect 调整透明度：毛玻璃模式保持默认 0.7 通透，半透明模式按 uiOpacity
            BackgroundUIEffect effect = [BackgroundManager sharedManager].uiEffect;
            if (effect == BackgroundUIEffectBlur) {
                blurView.alpha = 0.85;
            } else {
                blurView.alpha = MAX(0.5, [BackgroundManager sharedManager].uiOpacity);
            }
            tv.backgroundView = blurView;
        } else {
            // 无自定义背景：使用系统默认色，保持原 UI 风格
            if (@available(iOS 13.0, *)) {
                UIView *bg = [[UIView alloc] initWithFrame:tv.bounds];
                bg.backgroundColor = [UIColor systemBackgroundColor];
                bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                tv.backgroundView = bg;
            }
        }
        // tableView 本身保持透明，让 backgroundView 显示
        tv.backgroundColor = [UIColor clearColor];
    }
}

#pragma mark - UA-aware download helper

/// 阶段6修复（参照 FCL）：用带浏览器 User-Agent 的 NSURLSession 替代 NSData dataWithContentsOfURL:
/// 进行同步下载。BMCLAPI 的 optifine/curseforge 转发受 Cloudflare 保护，默认 UA 会被拦截返回 403。
/// 与 DownloadViewController.downloadDataWithURLString:error: 等价，但接收 NSURL 参数
/// （本文件调用处均已构造好 NSURL）。
- (NSData *)downloadDataWithURL:(NSURL *)url error:(NSError **)error {
    if (!url) {
        if (error) {
            *error = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"nil URL"}];
        }
        return nil;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 60;
    cfg.HTTPAdditionalHeaders = @{
        @"User-Agent": @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        @"Accept": @"*/*"
    };
    __block NSData *result = nil;
    __block NSError *resultError = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if (err) {
            resultError = err;
        } else if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
            if (statusCode >= 400) {
                resultError = [NSError errorWithDomain:@"ProfileSettingsDownload"
                                                  code:statusCode
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld for %@", (long)statusCode, url.absoluteString]}];
            } else {
                result = data;
            }
        } else {
            result = data;
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC));
    if (error) *error = resultError;
    [session finishTasksAndInvalidate];
    return result;
}

@end
