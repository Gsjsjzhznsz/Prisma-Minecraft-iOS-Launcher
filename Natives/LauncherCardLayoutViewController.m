#import "LauncherCardLayoutViewController.h"
#import "LauncherMenuViewController.h"
#import "LauncherNewsViewController.h"
#import "LauncherRightPanelViewController.h"
#import "DownloadViewController.h"
#import "VersionManagerViewController.h"
#import "ProfileSettingsViewController.h"
#import "LauncherPreferencesViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "PLMirrorCenter.h"   // Task218: version manifest candidate chain
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "CustomControlsViewController.h"
// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// #import "MultiplayerViewController.h"
// #import "TerracottaViewController.h"
// #import "TerracottaManager.h"
// #import "TerracottaBridge.h"
#import "AccountListViewController.h"
#import "AI/AIViewController.h"
#import "AI/AiSessionStore.h"
// Task212：使用问题 FAQ 页（侧边栏问号按钮）在卡片布局下的落地依赖
#import "LauncherHelpViewController.h"

// 布局常量（iPad/宽屏基准值；iPhone 上通过 traitCollection 适配后会变窄）
static const CGFloat kSidebarWidthPad = 70.0;      // iPad 左侧边栏卡片宽度
static const CGFloat kSidebarWidthPhone = 56.0;    // iPhone 左侧边栏卡片宽度（仅图标）
static const CGFloat kRightPanelWidthPad = 220.0;  // iPad 右侧面板卡片宽度
static const CGFloat kRightPanelWidthPhone = 168.0; // iPhone 右侧面板卡片宽度（保证启动/JAR 按钮可读）
static const CGFloat kCardSpacing = 12.0;          // 卡片间距
static const CGFloat kCardOuterMarginPad = 12.0;   // iPad 卡片到外边缘的间距
static const CGFloat kCardOuterMarginPhone = 8.0;  // iPhone 卡片到外边缘的间距（窄屏减小留白）
static const CGFloat kCardCornerRadius = 16.0;     // 卡片圆角

/// 检测物理设备是否为 iPhone（不受 debug.debug_ipad_ui 的 idiom hook 影响）。
/// UIKit+hook.m 会把 idiom 强制改成 Pad，导致 trait.userInterfaceIdiom 不可靠。
/// 这里用 UIDevice.model 检测真实设备类型。
static BOOL LauncherCardLayoutIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"iphone"];
}

/// 根据物理设备类型决定卡片外边距
static CGFloat LauncherCardLayoutOuterMargin(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kCardOuterMarginPhone;
    return kCardOuterMarginPad;
}

/// 根据物理设备类型决定侧栏宽度
/// - iPhone 横屏（含 SE/8/Plus/X/Pro Max）：56pt（菜单只有图标，56pt 足够）
/// - iPad：70pt
static CGFloat LauncherCardLayoutSidebarWidth(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kSidebarWidthPhone;
    return kSidebarWidthPad;
}

/// 根据物理设备类型决定右侧面板宽度
/// - iPhone 横屏：168pt（保证启动/编辑控件/执行 Jar 按钮文字不截断）
/// - iPad：220pt
static CGFloat LauncherCardLayoutRightPanelWidth(UITraitCollection *trait) {
    if (LauncherCardLayoutIsPhysicalPhone()) return kRightPanelWidthPhone;
    return kRightPanelWidthPad;
}

@interface LauncherCardLayoutViewController ()

@property(nonatomic, strong) UIView *sidebarCard;
@property(nonatomic, strong) UIView *contentCard;
@property(nonatomic, strong) UIView *rightPanelCard;

@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;
// 存储外边距约束，traitCollection 变化时动态更新
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *outerMarginConstraints;
// Task187（iPhone 刘海适配）：水平边距约束单独持有（leading/trailing 需叠加
// 刘海避让量，top/bottom 维持对称 outerMargin）
@property(nonatomic, strong) NSLayoutConstraint *ame187_sidebarLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *ame187_rightTrailingConstraint;
// 关键修复（UI 累积异常）：同 LauncherRootViewController，持有当前内容 VC 的约束
// 并先 deactivate 再激活，避免 tmpRootVC 保留场景下缓存复用子 VC 的约束叠加。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;
// Task173：主页 VC 实例缓存（头像消失根修，同 LauncherRootViewController）。
@property(nonatomic, strong) LauncherNewsViewController *cachedHomeVC;

@end

@implementation LauncherCardLayoutViewController

#pragma mark - Lifecycle

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];
    
    // 初始化版本列表（必须在其他视图控制器之前）
    [self initializeVersionLists];
    
    // 创建三个卡片容器视图
    [self setupCardContainers];
    
    // 添加子视图控制器
    [self setupChildViewControllers];
    
    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听启动器外观变化（自定义字体/卡片颜色），刷新卡片背景
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

- (void)initializeVersionLists {
    // 初始化本地版本列表
    if (!localVersionList) {
        localVersionList = [NSMutableArray new];
    }
    [localVersionList removeAllObjects];
    
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *versionPath = [NSString stringWithFormat:@"%s/versions/", getenv("POJAV_GAME_DIR")];
    NSArray *list = [fileManager contentsOfDirectoryAtPath:versionPath error:nil];
    for (NSString *versionId in list) {
        NSString *localPath = [NSString stringWithFormat:@"%s/versions/%@", getenv("POJAV_GAME_DIR"), versionId];
        BOOL isDirectory;
        if ([fileManager fileExistsAtPath:localPath isDirectory:&isDirectory] && isDirectory) {
            [localVersionList addObject:@{
                @"id": versionId,
                @"type": @"custom"
            }];
        }
    }
    
    // 初始化远程版本列表
    if (!remoteVersionList) {
        remoteVersionList = [NSMutableArray new];
    }
    [remoteVersionList removeAllObjects];
    [remoteVersionList addObjectsFromArray:@[
        @{@"id": @"latest-release", @"type": @"release"},
        @{@"id": @"latest-snapshot", @"type": @"snapshot"}
    ]];
    
    // 异步获取远程版本列表
    [self fetchRemoteVersionList];
}

- (void)fetchRemoteVersionList {
    // Task218：版本清单改走 PLMirrorCenter 候选链（GameFile 策略：官方 +
    // BMCLAPI 镜像按序尝试，任一成功即停）。旧实现读冻结的旧键
    // general.download_source 做 bmclapi-vs-官方硬切换——设置页"下载镜像
    // 策略"四个键里选什么都不生效，行为永远停留在迁移那一刻的旧值上
    //（双轨制病灶，与 DownloadVC Task173 版本选择页同源同修）。
    NSURL *ame218_official = [NSURL URLWithString:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"];
    NSArray<NSURL *> *ame218_candidates = [PLMirrorCenter candidateURLsForOriginalURL:ame218_official
                                                                          resourceType:PLMirrorResourceTypeGameFile];
    if (ame218_candidates.count == 0) {
        ame218_candidates = @[ame218_official];
    }
    __block NSMutableArray<NSURL *> *ame218_remaining = [ame218_candidates mutableCopy];
    __block void (^ame218_tryNext)(void) = ^{ };
    ame218_tryNext = ^{
        if (ame218_remaining.count == 0) {
            NSDebugLog(@"[LauncherCardVC] Task218 version manifest: all candidates failed");
            return;
        }
        NSURL *ame218_url = ame218_remaining.firstObject;
        [ame218_remaining removeObjectAtIndex:0];
        NSURLSessionDataTask *ame218_task = [[NSURLSession sharedSession] dataTaskWithURL:ame218_url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (data && !error) {
                NSError *jsonError;
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
                if (json && json[@"versions"]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [remoteVersionList addObjectsFromArray:json[@"versions"]];
                        setPrefObject(@"internal.latest_version", json[@"latest"]);
                        NSDebugLog(@"[LauncherCardVC] Task218 loaded %d remote versions from %@", remoteVersionList.count, ame218_url.host);
                    });
                    return;
                }
            }
            NSDebugLog(@"[LauncherCardVC] Task218 manifest fetch failed on %@ (%@) -- trying next candidate",
                      ame218_url.host, error.localizedDescription ?: @"non-JSON");
            ame218_tryNext();
        }];
        [ame218_task resume];
    };
    ame218_tryNext();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Task187（iPhone 刘海适配）：viewDidLoad 时刻 safeAreaInsets 仍是 0，
    // 真实内缩在首次布局后才到位；在此补一次水平边距重算（iPad 恒 0 零开销）
    if (self.ame187_sidebarLeadingConstraint != nil) {
        CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);
        self.ame187_sidebarLeadingConstraint.constant = outerMargin + ame187_iphoneNotchInset(self.view, YES);
        self.ame187_rightTrailingConstraint.constant = -(outerMargin + ame187_iphoneNotchInset(self.view, NO));
    }
    [[BackgroundManager sharedManager] resumeVideo];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[BackgroundManager sharedManager] pauseVideo];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // card 布局四边外边距一致性由约束保证（用 view.edgeAnchor + kCardOuterMargin，
    // 不依赖 safeAreaLayoutGuide），此处无需额外补偿。
    // 之前用 additionalSafeAreaInsets 补偿 safeArea 不对称，但补偿后外边距 =
    // max(safeArea) + kCardOuterMargin 反而更大（"下边和左右两边空隙过大"），
    // 故移除该补偿方案，改用 view.edgeAnchor 直接约束。
    //
    // 关键修复（阶段4：Card 布局进入设置崩溃，无日志）：
    // 与 LauncherRootViewController 对齐：清理 additionalSafeAreaInsets 累积。
    // 之前此方法体为空，导致 LauncherPreferencesViewController（含 UISearchController）在
    // nav 栈中时 additionalSafeAreaInsets 可能累积异常，UISearchController.searchBar
    // （作为 tableHeaderView）frame 计算异常 → EXC_BAD_ACCESS（不被 NSUncaughtExceptionHandler
    // 捕获，故无日志）。VS 布局不崩溃是因为 Root 的 viewDidLayoutSubviews 持续清理 inset。
    UIViewController *contentVC = _contentViewController;
    if (!contentVC) return;
    if ([contentVC isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)contentVC;
        for (UIViewController *vc in nav.viewControllers) {
            UIEdgeInsets insets = vc.additionalSafeAreaInsets;
            if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
                vc.additionalSafeAreaInsets = UIEdgeInsetsZero;
            }
        }
    } else {
        UIEdgeInsets insets = contentVC.additionalSafeAreaInsets;
        if (insets.top != 0 || insets.left != 0 || insets.right != 0 || insets.bottom != 0) {
            contentVC.additionalSafeAreaInsets = UIEdgeInsetsZero;
        }
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // iPhone 与 iPad 切换、或分屏调整大小时，更新侧栏与右侧面板宽度
    CGFloat sidebarWidth = LauncherCardLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherCardLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // 更新外边距约束（iPhone/iPad 切换时 outerMargin 不同）
    CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);
    // Task187：水平约束单独重算（含刘海避让；旋转 180° 后左右互换）
    if (self.ame187_sidebarLeadingConstraint != nil) {
        self.ame187_sidebarLeadingConstraint.constant = outerMargin + ame187_iphoneNotchInset(self.view, YES);
    }
    if (self.ame187_rightTrailingConstraint != nil) {
        self.ame187_rightTrailingConstraint.constant = -(outerMargin + ame187_iphoneNotchInset(self.view, NO));
    }
    // top/bottom 维持对称 outerMargin；水平约束已在上方单独重算，跳过
    for (NSLayoutConstraint *c in self.outerMarginConstraints) {
        if (c == self.ame187_sidebarLeadingConstraint || c == self.ame187_rightTrailingConstraint) {
            continue;
        }
        // 根据 original constant 符号决定正负（top 正、bottom 负）
        if (c.constant >= 0) {
            c.constant = outerMargin;
        } else {
            c.constant = -outerMargin;
        }
    }
    // 关键修复（阶段4：Card 布局进入设置崩溃，无日志）：
    // 与 LauncherRootViewController 对齐：仅遍历直接子 VC，避免递归栈溢出风险。
    // 之前递归遍历所有后代 VC（adjustChildLayoutForTraitCollection:），若 VC 树存在
    // 循环引用会栈溢出（SIGSEGV，不被 NSUncaughtExceptionHandler 捕获，故无日志）。
    // respondsToSelector:@selector(viewWillAppear:) 检查永真（所有 UIViewController 都响应），
    // 属冗余代码，一并删除。
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
}

#pragma mark - Setup

- (UIView *)createCardContainer {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.layer.cornerRadius = kCardCornerRadius;
    card.layer.masksToBounds = YES;
    [[BackgroundManager sharedManager] applyEffectToView:card];
    [self applyCustomCardColorToCard:card];
    return card;
}

/// Task89 起空操作；Task137 新拟态退役后保持空操作（卡片表面归
/// UIKit+NativeSurface / BackgroundManager 管理）。
- (void)applyCustomCardColorToCard:(UIView *)card {
    // Task89 起空操作（Task137 延续）：general.card_color 不再叠加到卡片
    // 表面——卡片底色由原生表面辅助统一管理。
    // 原毛玻璃+半透明色叠加实现见 git 历史（1a135fe 之前版本）。
}
- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1.0];
}

/// 外观变化时重新应用卡片颜色（保留圆角，重建背景）
- (void)applyCustomAppearance {
    [self applyCustomCardColorToCard:self.sidebarCard];
    [self applyCustomCardColorToCard:self.contentCard];
    [self applyCustomCardColorToCard:self.rightPanelCard];
}

- (void)setupCardContainers {
    // 左侧菜单卡片
    self.sidebarCard = [self createCardContainer];
    [self.view addSubview:self.sidebarCard];

    // 中间内容卡片
    self.contentCard = [self createCardContainer];
    [self.view addSubview:self.contentCard];

    // 右侧信息/启动卡片
    self.rightPanelCard = [self createCardContainer];
    [self.view addSubview:self.rightPanelCard];

    // 用自适应宽度创建可变宽度约束，便于 traitCollection 变化时更新
    self.sidebarWidthConstraint = [self.sidebarCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelCard.widthAnchor constraintEqualToConstant:LauncherCardLayoutRightPanelWidth(self.traitCollection)];

    // 卡片外边距：iPhone 窄屏用较小值减少留白
    CGFloat outerMargin = LauncherCardLayoutOuterMargin(self.traitCollection);

    // 设置约束
    // 四个方向均用 view.edgeAnchor（而非 safeAreaLayoutGuide），使外边距完全由 outerMargin 控制，
    // 上下左右边距一致（均 = outerMargin），不受刘海/home indicator 导致的 safeArea 不对称影响。
    //
    // 修复"下面过宽"问题：之前上下用 safeAreaLayoutGuide + outerMargin，
    // 导致底部边距 = homeIndicatorInset + outerMargin（约 21+8=29pt），
    // 而顶部边距 = 0 + outerMargin = 8pt，底部比顶部宽 3.6 倍。
    // 改为 view.topAnchor/view.bottomAnchor 后，上下边距均 = outerMargin，保持一致。
    // 卡片背景会延伸到 home indicator 下方，视觉上无影响（卡片有不透明/毛玻璃背景）。
    // Task187（iPhone 刘海/挖孔适配）：水平边距叠加安全避让（仅 iPhone 生效，
    // iPad 恒 0 零回归）——否则横屏下侧栏/右面板直接被刘海压住。
    // 上下边维持对称 outerMargin（既有"下面过宽"修复语义不变，home indicator
    // 由不透明卡片背景自然覆盖）。
    CGFloat ame187_leadInset = ame187_iphoneNotchInset(self.view, YES);
    CGFloat ame187_trailInset = ame187_iphoneNotchInset(self.view, NO);
    NSLayoutConstraint *sidebarLeading = [self.sidebarCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:outerMargin + ame187_leadInset];
    NSLayoutConstraint *sidebarTop = [self.sidebarCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *sidebarBottom = [self.sidebarCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-outerMargin];
    NSLayoutConstraint *rightTrailing = [self.rightPanelCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-(outerMargin + ame187_trailInset)];
    NSLayoutConstraint *rightTop = [self.rightPanelCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *rightBottom = [self.rightPanelCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-outerMargin];
    NSLayoutConstraint *contentTop = [self.contentCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:outerMargin];
    NSLayoutConstraint *contentBottom = [self.contentCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-outerMargin];

    self.ame187_sidebarLeadingConstraint = sidebarLeading;
    self.ame187_rightTrailingConstraint = rightTrailing;

    self.outerMarginConstraints = @[sidebarLeading, sidebarTop, sidebarBottom,
                                    rightTrailing, rightTop, rightBottom,
                                    contentTop, contentBottom];

    [NSLayoutConstraint activateConstraints:@[
        // 左侧菜单卡片
        sidebarLeading, sidebarTop, sidebarBottom,
        self.sidebarWidthConstraint,

        // 右侧面板卡片
        rightTrailing, rightTop, rightBottom,
        self.rightPanelWidthConstraint,

        // 中间内容卡片——填满侧栏与右面板之间的空间，两侧间距均等为 kCardSpacing
        [self.contentCard.leadingAnchor constraintEqualToAnchor:self.sidebarCard.trailingAnchor constant:kCardSpacing],
        [self.contentCard.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor constant:-kCardSpacing],
        contentTop, contentBottom
    ]];
}

- (void)setupChildViewControllers {
    // 左侧边栏 - 功能菜单
    LauncherMenuViewController *sidebarVC = [[LauncherMenuViewController alloc] init];
    [self addChildViewController:sidebarVC];
    sidebarVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarCard addSubview:sidebarVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarVC.view.leadingAnchor constraintEqualToAnchor:self.sidebarCard.leadingAnchor],
        [sidebarVC.view.trailingAnchor constraintEqualToAnchor:self.sidebarCard.trailingAnchor],
        [sidebarVC.view.topAnchor constraintEqualToAnchor:self.sidebarCard.topAnchor],
        [sidebarVC.view.bottomAnchor constraintEqualToAnchor:self.sidebarCard.bottomAnchor]
    ]];
    [sidebarVC didMoveToParentViewController:self];
    _sidebarViewController = sidebarVC;
    
    // 中间内容 - 默认显示新闻页
    // Task173：实例缓存（头像消失根修，见 cachedHomeVC 属性注释）。
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    self.cachedHomeVC = newsVC;
    [self setContentViewController:newsVC animated:NO];
    
    // 右侧面板 - 账户和启动
    LauncherRightPanelViewController *rightPanelVC = [[LauncherRightPanelViewController alloc] init];
    [self addChildViewController:rightPanelVC];
    rightPanelVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightPanelCard addSubview:rightPanelVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [rightPanelVC.view.leadingAnchor constraintEqualToAnchor:self.rightPanelCard.leadingAnchor],
        [rightPanelVC.view.trailingAnchor constraintEqualToAnchor:self.rightPanelCard.trailingAnchor],
        [rightPanelVC.view.topAnchor constraintEqualToAnchor:self.rightPanelCard.topAnchor],
        [rightPanelVC.view.bottomAnchor constraintEqualToAnchor:self.rightPanelCard.bottomAnchor]
    ]];
    [rightPanelVC didMoveToParentViewController:self];
    _rightPanelViewController = rightPanelVC;
    
    // 注册通知监听
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showHomePage)
                                                 name:@"ShowHomePage"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showDownloadPage)
                                                 name:@"ShowDownloadPage"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showVersionManager)
                                                 name:@"ShowVersionManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showProfileEditor:)
                                                 name:@"ShowProfileEditor"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showSettings)
                                                 name:@"ShowSettings"
                                               object:nil];
    // ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showMultiplayer)
    //                                              name:@"ShowMultiplayer"
    //                                            object:nil];
    // [[NSNotificationCenter defaultCenter] addObserver:self
    //                                          selector:@selector(showZeroTier)
    //                                              name:@"ShowZeroTier"
    //                                            object:nil];
    // 账户管理：右侧面板点击头像会发 ShowAccountManager 通知。
    // 原实现遗漏此监听，导致卡片布局下点头像无反应、无法登录账号。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
                                               object:nil];
    // AI 助手：卡片布局下点侧边栏 AI Agent 按钮发 ShowAIPage 通知。
    // 关键修复（点 AI 中间栏不切换）：卡片布局此前未监听 ShowAIPage，
    // 导致菜单发出通知后无人响应、中间栏不变。与 LauncherRootViewController 对齐。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAIPage)
                                                 name:@"ShowAIPage"
                                               object:nil];
    // Task212（使用问题页呼出失效根修，用户报障"无法点击按钮以呼出，已经
    // 存在了一周"）：Task 180 起默认根 = 卡片布局（general.ui_layout 未写盘
    // 即走 card），而 ShowHelpPage 通知只有旧三栏 LauncherRootViewController
    // 监听——卡片布局下点侧边栏"使用问题"（questionmark.circle，菜单
    // index 5）通知发出后无人响应，按钮点了没反应。与 ShowAIPage 同款
    // 病灶（当时修过 AI 侧，help 侧漏了），本次补齐观察者 + showHelpPage，
    // 与 VS 布局行为对齐。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showHelpPage)
                                                 name:@"ShowHelpPage"
                                               object:nil];
    // 首页快捷瓷砖触发：切到对应内容区子页面（不再 FormSheet 弹窗）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModsManager)
                                                 name:@"ShowModsManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showShadersManager)
                                                 name:@"ShowShadersManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showModpackImport)
                                                 name:@"ShowModpackImport"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showGameDirectory)
                                                 name:@"ShowGameDirectory"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged)
                                                 name:@"BackgroundChanged"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(uiEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // 监听版本切换，重新加载编辑器
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadProfileEditorIfNeeded)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    // 监听游戏目录切换，重新加载版本列表
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadVersionLists)
                                                 name:@"ReloadProfileList"
                                               object:nil];
    // 监听查找版本请求
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(findVersionInRemoteList:)
                                                 name:@"FindVersionInRemoteList"
                                               object:nil];
}

- (void)findVersionInRemoteList:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSString *versionId = userInfo[@"versionId"];
    void (^callback)(NSDictionary *) = userInfo[@"callback"];
    
    if (!versionId || !callback) {
        return;
    }
    
    // 在远程版本列表中查找
    NSDictionary *versionObject = nil;
    for (NSDictionary *version in remoteVersionList) {
        if ([version[@"id"] isEqualToString:versionId]) {
            versionObject = version;
            break;
        }
    }
    
    // 如果在远程列表中找不到，检查是否是本地版本
    if (!versionObject) {
        for (NSDictionary *version in localVersionList) {
            if ([version[@"id"] isEqualToString:versionId]) {
                versionObject = version;
                break;
            }
        }
    }

    // Task 72 修复（防御纵深，"找不到版本信息"）：与 LauncherRootViewController
    // 同构——远程列表与内存 localVersionList 双双未命中时，扫描磁盘 versions/ 兜底，
    // 防止快照过期（安装路径漏发 ReloadProfileList）导致启动误报"找不到版本信息"。
    if (!versionObject && versionId.length > 0) {
        NSString *versionJsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json",
                                      getenv("POJAV_GAME_DIR"), versionId, versionId];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:versionJsonPath isDirectory:&isDir] && !isDir) {
            versionObject = @{@"id": versionId, @"type": @"custom"};
            NSLog(@"[LauncherCardLayout] Task72 version found on disk (stale list fallback): %@", versionId);
        }
    }

    callback(versionObject);
}

- (void)reloadVersionLists {
    // 重新加载版本列表
    [self initializeVersionLists];
    // 通知右侧面板刷新版本显示
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
}

- (void)showHomePage {
    // Task173：复用主页 VC 实例（头像消失根修，同 LauncherRootViewController）。
    if (!self.cachedHomeVC) {
        self.cachedHomeVC = [[LauncherNewsViewController alloc] init];
        NSLog(@"[HomeAvatar] Task173 home VC created (card layout, will be reused)");
    } else {
        NSLog(@"[HomeAvatar] Task173 home VC reused (card layout, avatar survives tab switch)");
    }
    [self setContentViewController:self.cachedHomeVC animated:YES];
}

- (void)showDownloadPage {
    // 在中间内容区显示下载页面，包在 NavigationController 中以便子流程（版本选择/安装器）push 显示
    DownloadViewController *downloadVC = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:downloadVC];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showVersionManager {
    // 在中间内容区显示版本管理页面，包在 NavigationController 中以便子流程（模组/光影/游戏目录管理）push
    VersionManagerViewController *vc = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)showProfileEditor:(NSNotification *)notification {
    // 在中间内容区显示版本编辑器页面（使用 ProfileSettingsViewController）
    NSString *profileName = notification.object;

    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;

    // 包装在导航控制器中
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;

    self.profileEditorVC = vc;
    self.isShowingProfileEditor = YES;
    [self setContentViewController:navVC animated:YES];
}

- (void)reloadProfileEditorIfNeeded {
    // 如果当前正在显示编辑器页面，重新加载
    if (self.isShowingProfileEditor) {
        NSString *currentProfile = PLProfiles.current.selectedProfileName;
        if (currentProfile) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowProfileEditor" object:currentProfile];
        }
    }
}

- (void)showSettings {
    // 在中间内容区显示设置页面
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    // 包装在导航控制器中，使其子页面能够正常导航
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = YES;
    [self setContentViewController:navVC animated:YES];
}

// Task212："使用问题"FAQ 页（侧边栏新增标签；与 LauncherRootViewController
// showHelpPage 逐字对齐——包在导航控制器里保持标题栏一致）。
- (void)showHelpPage {
    LauncherHelpViewController *vc = [[LauncherHelpViewController alloc] init];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

- (void)showAIPage {
    // 在中间内容区显示 AI 助手页面（与 LauncherRootViewController showAIPage 一致）。
    // 关键修复（点 AI 中间栏不切换）：卡片布局此前缺失此方法，
    // 现在 ShowAIPage 通知到达后能正常切到 AI 页面。
    // 从 AiSessionStore 取最近会话，没有则让 AIViewController 新建一个。
    AiSession *session = [[AiSessionStore sharedStore] lastActiveSession];
    AIViewController *vc = [[AIViewController alloc] initWithSession:session];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// - (void)showMultiplayer { ... TerracottaViewController ... }
// - (void)showZeroTier { ... MultiplayerViewController ... TerracottaManager ... }
- (void)showMultiplayer {
    [self showMultiplayerDisabledAlert];
}
- (void)showZeroTier {
    [self showMultiplayerDisabledAlert];
}
- (void)showMultiplayerDisabledAlert {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"i18n_str_320", nil)
                          message:localize(@"i18n_str_321", nil)
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showAccountManager {
    // 卡片布局下账户管理在中间内容区显示（与 VS 布局 LauncherRootViewController 行为一致）。
    // 右侧面板点击头像发 ShowAccountManager 通知触发此方法。
    // 使用 insetGrouped 样式让账户列表呈现圆角分组卡片（原默认 plain 为直角行）。
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

#pragma mark - 首页快捷入口 (替换原 FormSheet 弹窗)

- (void)showModsManager {
    // 切到版本管理页并直接 push 模组管理
    // 修复"前一界面未消失"竞态：先构建完整 nav 栈再 setContentViewController，
    // 这样 setContentViewController 内的 for 循环能一次性透明化栈中所有 VC，
    // 避免 animated:YES 的 crossDissolve 进行中再 animated:NO push 导致新 VC 未透明化。
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ModsManagerViewController *m = [[ModsManagerViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showShadersManager {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    ShadersManagerViewController *s = [[ShadersManagerViewController alloc] init];
    s.initialMode = ShadersManagerModeLocal;
    [nav pushViewController:s animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showGameDirectory {
    VersionManagerViewController *vm = [[VersionManagerViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vm];
    nav.navigationBar.prefersLargeTitles = NO;
    LauncherPrefGameDirViewController *g = [[LauncherPrefGameDirViewController alloc] init];
    [nav pushViewController:g animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)showModpackImport {
    // 切到下载页并直接 push 整合包导入界面
    DownloadViewController *d = [[DownloadViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:d];
    nav.navigationBar.prefersLargeTitles = NO;
    ModpackImportViewController *m = [[ModpackImportViewController alloc] init];
    [nav pushViewController:m animated:NO];
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // 重新应用毛玻璃/半透明效果到卡片容器视图
    [[BackgroundManager sharedManager] applyEffectToView:self.sidebarCard];
    [[BackgroundManager sharedManager] applyEffectToView:self.contentCard];
    [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelCard];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Content Switching

- (void)setContentViewController:(UIViewController *)viewController animated:(BOOL)animated {
    if (!viewController) return;

    // 关键修复（UI 累积异常）：同一实例直接跳过，避免对同一 VC 重复添加约束
    // 和反复调用 applyEffectToNavigationBar: 导致 hairline UIImageView 累积。
    if (viewController == _contentViewController) return;

    // 检查是否切换到非编辑器页面
    if (![viewController isKindOfClass:[UINavigationController class]] ||
        ![((UINavigationController *)viewController).topViewController isKindOfClass:[ProfileSettingsViewController class]]) {
        self.isShowingProfileEditor = NO;
        self.profileEditorVC = nil;
    }

    UIViewController *oldVC = _contentViewController;

    // 移除旧的 + 添加新的
    _contentViewController = viewController;
    [self addChildViewController:viewController];
    viewController.view.translatesAutoresizingMaskIntoConstraints = NO;

    // 修复：对齐 LauncherRootViewController 的 nav bar 透明化处理。
    // 原卡片布局缺失此逻辑，导致 VersionManagerViewController 等被 UINavigationController
    // 包裹的子页面顶部出现默认不透明 nav bar（白条），与卡片背景不融合。
    //
    // 统一参照 RootVC 的完整处理（setContentViewController 中对 nav 栈所有 VC 透明化 +
    // 设置 nav.delegate + didShowViewController 回调中重新透明化）：
    // 1. 透明化 nav 栈中所有 VC（不仅是 topViewController），防止 push 后子页面样式被重置
    // 2. 设置 nav.delegate = self，在 didShowViewController 回调中重新应用 nav bar 效果
    // 3. 重新应用 nav bar 效果，确保 push/pop 后样式一致
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // 透明化栈中所有 VC（与 RootVC 一致），防止 push 后子页面背景不透明
        for (UIViewController *vc in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:vc];
        }
    } else {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // 关键修复（UI 累积异常）：deactivate 旧约束，避免在 tmpRootVC 保留场景下
    // 缓存复用的子 VC 反复激活约束导致 contentCard 内容区左右变宽。
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentCard.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentCard.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentCard.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentCard.bottomAnchor]
    ];

    if (animated && oldVC) {
        // 修复问题5：原实现用两个独立的 UIView transitionWithView:（一个移除旧视图、一个添加新视图），
        // 两个 crossDissolve 同时作用于 contentCard 会导致视觉冲突和残影（旧画面未完全消失就覆盖新界面）。
        // 改为单个 transition：在同一个 animations block 内完成"移除旧视图 + 添加新视图"，
        // crossDissolve 会正确抓取前后快照做交叉渐变，completion 中清理旧 VC 父子关系。
        //
        // 关键修复（入场动画从左上角弹出）：UIKit 在 animations block 返回后立即对容器做 snapshot，
        // 此时新视图虽然已 addSubview + activateConstraints，但尚未经历 layout pass，frame 仍是
        // (0,0,0,0)。配合 contentCard 的 masksToBounds=YES + 圆角裁剪，crossDissolve 渐变呈现
        // "从左上角小点扩展出来"的怪异效果。在 animations block 内显式 layoutIfNeeded 强制立即
        // 布局，让 snapshot B 时 frame 已撑满，crossDissolve 就是标准的淡入淡出。
        // duration 由 0.25 调整为 0.3 让过渡更柔和自然（与 LauncherRootViewController 一致）。
        [UIView transitionWithView:self.contentCard
                          duration:0.3
                           options:UIViewAnimationOptionTransitionCrossDissolve
                        animations:^{
                            [oldVC willMoveToParentViewController:nil];
                            [oldVC.view removeFromSuperview];
                            [self.contentCard addSubview:viewController.view];
                            [NSLayoutConstraint activateConstraints:newConstraints];
                            [self.contentCard layoutIfNeeded];
                        } completion:^(BOOL finished) {
                            [oldVC removeFromParentViewController];
                            [viewController didMoveToParentViewController:self];
                        }];
    } else {
        if (oldVC) {
            [oldVC willMoveToParentViewController:nil];
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
        }
        [self.contentCard addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:newConstraints];
        [viewController didMoveToParentViewController:self];
    }

    self.currentContentConstraints = newConstraints;
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

#pragma mark - UINavigationControllerDelegate

/// nav push/pop 后重新透明化所有 VC 并重新应用 nav bar 效果
/// 参照 RootVC 的同名实现，确保 push 后子页面样式与卡片背景一致
- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    // 透明化刚显示的 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    // 同时透明化栈中所有 VC（防止前一个页面透出残留，解决"前一页面未及时消失"问题）
    for (UIViewController *stackVC in navigationController.viewControllers) {
        [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
    }
    // 重新应用导航栏毛玻璃效果（防止 push 后 nav bar 样式被重置）
    [[BackgroundManager sharedManager] applyEffectToNavigationBar:navigationController.navigationBar];
}

@end
