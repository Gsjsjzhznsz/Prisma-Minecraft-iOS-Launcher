#import "LauncherRootViewController.h"
#import "UIKit+NativeSurface.h"
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
#import "LiquidGlassCompat.h"   // Task224（#4/#19）：界面风格 + 界面缩放
#import "PLProfiles.h"
#import "utils.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ModpackImportViewController.h"
#import "LauncherPrefGameDirViewController.h"
#import "CustomControlsViewController.h"
// ★ [MP-RESTORE] Task222：ZeroTier/Terracotta 联机恢复（上游同日恢复）
#import "MultiplayerViewController.h"
#import "TerracottaViewController.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "AccountListViewController.h"
#import "UpdateChecker.h"
#import "NMToast.h"
#import "AI/AIViewController.h"
#import "AI/AiSessionStore.h"
#import "LauncherHelpViewController.h"

// 布局常量（iPad 基准值；iPhone 上通过 LauncherRootLayoutWidth 适配后会变窄）
static const CGFloat kSidebarWidthPad = 70.0;      // iPad 左侧边栏宽度
static const CGFloat kSidebarWidthPhone = 56.0;    // iPhone 左侧边栏宽度（仅图标）
static const CGFloat kRightPanelWidthPad = 220.0;  // iPad 右侧面板宽度
// Task 146a：撤销 Task 139 的 iPhone 右面板 96pt 图标轨（真机反馈"变窄"非
// 用户本意，原意是信息列表可滚动），恢复 Task 139 之前的 168pt 全内容列，
// 与 LauncherCardLayoutViewController.kRightPanelWidthPhone 保持一致；
// 信息卡溢出交给 infoScrollView 的纵向滚动处理，不再做设备级内容裁剪。
static const CGFloat kRightPanelWidthPhone = 168.0; // iPhone 右侧面板宽度（全内容列）

/// 检测物理设备是否为 iPhone（不受 debug.debug_ipad_ui 的 idiom hook 影响）。
/// UIKit+hook.m 会把 idiom 强制改成 Pad，导致 trait.userInterfaceIdiom 不可靠。
/// 这里用 UIDevice.model 检测真实设备类型。
static BOOL LauncherRootIsPhysicalPhone(void) {
    NSString *model = [[UIDevice currentDevice].model lowercaseString];
    return [model containsString:@"iphone"];
}

/// 根据物理设备类型决定侧栏宽度（与 LauncherCardLayoutViewController 保持一致）
/// Task224（#19）：乘界面缩放倍率；iPhone 上另以屏宽 12% 封顶（放大不挤占
/// 中间内容区——缩放上限场景侧栏+右栏+间距合计不超屏宽 45%）
static CGFloat LauncherRootLayoutSidebarWidth(UITraitCollection *trait) {
    CGFloat ame224_base = LauncherRootIsPhysicalPhone() ? kSidebarWidthPhone : kSidebarWidthPad;
    CGFloat ame224_width = LGCScaledValue(ame224_base);
    if (LauncherRootIsPhysicalPhone()) {
        CGFloat ame224_cap = UIScreen.mainScreen.bounds.size.width * 0.12;
        if (ame224_width > ame224_cap) ame224_width = ame224_cap;
    }
    return ame224_width;
}

/// 根据物理设备类型决定右侧面板宽度
/// Task224（#19）：同上——倍率 + iPhone 屏宽 32% 封顶（读得下优先）
static CGFloat LauncherRootLayoutRightPanelWidth(UITraitCollection *trait) {
    CGFloat ame224_base = LauncherRootIsPhysicalPhone() ? kRightPanelWidthPhone : kRightPanelWidthPad;
    CGFloat ame224_width = LGCScaledValue(ame224_base);
    if (LauncherRootIsPhysicalPhone()) {
        CGFloat ame224_cap = UIScreen.mainScreen.bounds.size.width * 0.32;
        if (ame224_width > ame224_cap) ame224_width = ame224_cap;
    }
    return ame224_width;
}

@interface LauncherRootViewController ()

@property(nonatomic, strong) UIView *sidebarContainer;
@property(nonatomic, strong) UIView *contentContainer;
@property(nonatomic, strong) UIView *rightPanelContainer;

@property(nonatomic, strong) NSLayoutConstraint *contentLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *contentTrailingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sidebarWidthConstraint;
@property(nonatomic, strong) NSLayoutConstraint *rightPanelWidthConstraint;
// Task187（iPhone 刘海适配）：左右边距约束单独持有（叠加避让量）
@property(nonatomic, strong) NSLayoutConstraint *ame187_sidebarLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *ame187_rightTrailingConstraint;
// 关键修复（UI 累积异常）：setContentViewController: 之前每次切换都激活 4 个新约束
// （leading/trailing/top/bottom 到 contentContainer），但旧 VC 的约束未显式 deactivate。
// 在 tmpRootVC 保留场景下，缓存复用的子 VC 反复激活约束，layout 解算时 leading/trailing
// 约束叠加导致 contentContainer 内容区左右变宽。现持有当前约束并先 deactivate 再激活。
@property(nonatomic, strong) NSArray<NSLayoutConstraint *> *currentContentConstraints;

@property(nonatomic, assign) BOOL isShowingProfileEditor;
@property(nonatomic, strong) ProfileSettingsViewController *profileEditorVC;
// Task173：主页 VC 实例缓存（头像消失根修）。
// 病历：showHomePage 每次切回主页都 alloc 全新 LauncherNewsViewController，
// 头像/公告/壁纸同步全部重跑一遍——Task169/171/172 三轮“切标签页回来
// 头像要点一下才显示”的时序修复全部治标不治本（新实例的 fetch/缓存命中
// 总能找到新的时序窗口）。复用实例后 currentAvatar 存活于实例上，切回
// 主页零重拉。onConfigsChanged（主页自定义）回调更新同一实例，无过期风险。
@property(nonatomic, strong) LauncherNewsViewController *cachedHomeVC;

@end

@implementation LauncherRootViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];

    self.view.backgroundColor = [UIColor clearColor];

    // 初始化版本列表（必须在其他视图控制器之前）
    [self initializeVersionLists];

    // 创建三个容器视图
    [self setupContainers];

    // 添加子视图控制器
    [self setupChildViewControllers];

    // 应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];

    // 监听外观变更（字体颜色 / 卡片颜色），与 Card 布局保持一致
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
    [self applyCustomAppearance];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
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
            NSDebugLog(@"[LauncherRootVC] Task218 version manifest: all candidates failed");
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
                        NSDebugLog(@"[LauncherRootVC] Task218 loaded %d remote versions from %@", remoteVersionList.count, ame218_url.host);
                    });
                    return;
                }
            }
            NSDebugLog(@"[LauncherRootVC] Task218 manifest fetch failed on %@ (%@) -- trying next candidate",
                      ame218_url.host, error.localizedDescription ?: @"non-JSON");
            ame218_tryNext();
        }];
        [ame218_task resume];
    };
    ame218_tryNext();
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Task187（iPhone 刘海适配）：viewDidLoad 时刻 insets 尚为 0，首布局后补算
    if (self.ame187_sidebarLeadingConstraint != nil) {
        self.ame187_sidebarLeadingConstraint.constant = ame187_iphoneNotchInset(self.view, YES);
        self.ame187_rightTrailingConstraint.constant = -ame187_iphoneNotchInset(self.view, NO);
    }
    [[BackgroundManager sharedManager] resumeVideo];
    [self ame125_autoUpdateCheckOnce];
}

// Task 125：启动器启动时自动检测更新（非侵入式）。
// 用户要求：启动时自动检测。设计口径：
//   - 每次冷启动只检查一次（静态标志，同会话多次 viewWillAppear 不重复）
//   - 偏好 general.auto_update_check（默认开）可关；与设置页手动"检查更新"
//     共用 UpdateChecker（Task115 已指向本仓库）
//   - 发现新版本 -> NMToast 新拟物卡片通知（自动消失，点击"查看"打开发布页）
//     ——刻意不用 AlertDialog：启动场景用户无决策要做，弹窗即打扰
//     （Task126 同批修复：旧 showDialog 的系统窗泄漏事故不复用在启动路径）
//   - 已是最新/网络失败 -> 静默（不弹任何东西，启动零骚扰）
//   - 延迟 1.5s：避开启动期 UI 竞争（侧栏/背景/JIT 卡首帧），toast 落在
//     稳定后的主界面上
- (void)ame125_autoUpdateCheckOnce {
    static BOOL ame125_checked = NO;
    if (ame125_checked) return;
    ame125_checked = YES;
    if (!getPrefBool(@"general.auto_update_check")) return;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UpdateChecker checkForUpdateWithCompletion:^(UpdateInfo *info, NSError *error) {
            if (!info.hasUpdate) return;   // 已是最新/出错：静默
            NSString *msg = [NSString stringWithFormat:localize(@"auto_update.toast.new_version", nil),
                             info.latestVersion];
            [NMToast showMessage:msg
                     actionTitle:localize(@"auto_update.toast.view", nil)
                        onAction:^{ [UpdateChecker openReleasePage]; }];
        }];
    });
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[BackgroundManager sharedManager] pauseVideo];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    // iPhone 与 iPad 切换、或分屏调整大小时，更新侧栏与右侧面板宽度
    CGFloat sidebarWidth = LauncherRootLayoutSidebarWidth(self.traitCollection);
    CGFloat rightPanelWidth = LauncherRootLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint.constant != sidebarWidth) {
        self.sidebarWidthConstraint.constant = sidebarWidth;
    }
    if (self.rightPanelWidthConstraint.constant != rightPanelWidth) {
        self.rightPanelWidthConstraint.constant = rightPanelWidth;
    }
    // Task187（iPhone 刘海适配）：旋转 180° 后左右安全区互换，重算避让量
    if (self.ame187_sidebarLeadingConstraint != nil) {
        self.ame187_sidebarLeadingConstraint.constant = ame187_iphoneNotchInset(self.view, YES);
        self.ame187_rightTrailingConstraint.constant = -ame187_iphoneNotchInset(self.view, NO);
    }
    // 通知子 VC 重新布局
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 修复：移除原先对 nav 栈所有 VC 一刀切注入负 additionalSafeAreaInsets.top 的逻辑。
    // 该负 inset 会导致两个严重问题：
    //   1. 设置页等使用 safeAreaLayoutGuide.topAnchor 布局的 VC，其内容被推到导航栏之上（"飞到顶上"），
    //      外观调整等选项无法正常滚动和操作。
    //   2. Java 管理等 push 进来的子页面，前一个页面的内容因为负 inset 透出在当前页面下方，
    //      形成"前一页面没有及时消失"的视觉残留。
    // "大白条"问题已通过 makeViewControllerTransparent（将 VC view 背景设为 clearColor）
    // + applyEffectToNavigationBar（导航栏毛玻璃）解决，不再需要此 hack。
    //
    // 关键修复（UI 累积异常）：之前仅清理 NEGATIVE .top 的 additionalSafeAreaInsets，
    // 未覆盖 .left/.right/.bottom 与正值累积。在 tmpRootVC 保留场景下，若其他路径
    // 累加 left/right inset，此方法无法兜底，导致 contentContainer 内容区左右变宽。
    // 现清理所有方向的非零 inset。
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

#pragma mark - Setup

- (void)setupContainers {
    // 左侧边栏容器：表面随背景模式切换（Task111）——有自定义背景时用
    // 毛玻璃/半透明让背景图从侧栏下方透出，无背景时维持 Task89 新拟态
    // 平贴表面（surface 底色、无阴影，立体感交给面板内的凸起元素）。
    // 表面应用统一收敛到 updateChromeSurfaces（setupContainers 尾部一次调用）。
    self.sidebarContainer = [[UIView alloc] init];
    self.sidebarContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarContainer.layer.cornerRadius = 16;
    self.sidebarContainer.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    self.sidebarContainer.layer.masksToBounds = YES;
    [self.view addSubview:self.sidebarContainer];

    // 中间内容容器 - 完全透明，四角直角（透出系统页面底色/背景照片）
    self.contentContainer = [[UIView alloc] init];
    self.contentContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.contentContainer.backgroundColor = [UIColor clearColor];
    [self.view addSubview:self.contentContainer];

    // 右侧面板容器 - 表面同侧栏随背景模式切换（Task111），仅保留外侧（右上/右下）圆角
    self.rightPanelContainer = [[UIView alloc] init];
    self.rightPanelContainer.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightPanelContainer.layer.cornerRadius = 16;
    self.rightPanelContainer.layer.maskedCorners = kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    self.rightPanelContainer.layer.masksToBounds = YES;
    [self.view addSubview:self.rightPanelContainer];

    // 双容器几何就位后统一应用初始表面（随背景模式自动选择新旧管线）
    [self updateChromeSurfaces];
    
    // 设置约束
    // 使用可变宽度约束，便于 traitCollection 变化时更新（iPhone/iPad 适配）
    self.sidebarWidthConstraint = [self.sidebarContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutSidebarWidth(self.traitCollection)];
    self.rightPanelWidthConstraint = [self.rightPanelContainer.widthAnchor constraintEqualToConstant:LauncherRootLayoutRightPanelWidth(self.traitCollection)];

    // Task187（iPhone 刘海/挖孔适配）：左右边距叠加安全避让（仅 iPhone 生效，
    // iPad 恒 0 零回归）——旧约束直接贴 view 边缘，iPhone 横屏下侧栏被刘海压住。
    CGFloat ame187_leadInset = ame187_iphoneNotchInset(self.view, YES);
    CGFloat ame187_trailInset = ame187_iphoneNotchInset(self.view, NO);
    self.ame187_sidebarLeadingConstraint = [self.sidebarContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:ame187_leadInset];
    self.ame187_rightTrailingConstraint = [self.rightPanelContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-ame187_trailInset];

    [NSLayoutConstraint activateConstraints:@[
        // 左侧边栏
        self.ame187_sidebarLeadingConstraint,
        [self.sidebarContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.sidebarContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.sidebarWidthConstraint,

        // 右侧面板
        self.ame187_rightTrailingConstraint,
        [self.rightPanelContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.rightPanelContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        self.rightPanelWidthConstraint,

        // 中间内容区——填满侧栏与右面板之间的空间
        [self.contentContainer.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [self.contentContainer.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [self.contentContainer.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.contentContainer.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)setupChildViewControllers {
    // 左侧边栏 - 功能菜单
    LauncherMenuViewController *sidebarVC = [[LauncherMenuViewController alloc] init];
    [self addChildViewController:sidebarVC];
    sidebarVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sidebarContainer addSubview:sidebarVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [sidebarVC.view.leadingAnchor constraintEqualToAnchor:self.sidebarContainer.leadingAnchor],
        [sidebarVC.view.trailingAnchor constraintEqualToAnchor:self.sidebarContainer.trailingAnchor],
        [sidebarVC.view.topAnchor constraintEqualToAnchor:self.sidebarContainer.topAnchor],
        [sidebarVC.view.bottomAnchor constraintEqualToAnchor:self.sidebarContainer.bottomAnchor]
    ]];
    [sidebarVC didMoveToParentViewController:self];
    _sidebarViewController = sidebarVC;
    
    // 中间内容 - 默认显示新闻页
    LauncherNewsViewController *newsVC = [[LauncherNewsViewController alloc] init];
    // Task175：初始主页实例注册进缓存（头像消失根修收尾）。
    // 病历（f484eb7 装机日志实锤）：本方法创建的初始实例从未写入
    // cachedHomeVC，用户首次切走再切回时 showHomePage 缓存未命中
    // → 又 alloc 了全新实例（日志 "[HomeAvatar] Task173 home VC created"
    // 出现在首次切换后 = 铁证），Task169/171/172 修过的全部时序病灶
    // 在这个新实例上复发。卡片布局（LauncherCardLayoutViewController）
    // 早已注册，此处补齐侧栏布局的差异。
    self.cachedHomeVC = newsVC;
    [self setContentViewController:newsVC animated:NO];
    
    // 右侧面板 - 账户和启动
    LauncherRightPanelViewController *rightPanelVC = [[LauncherRightPanelViewController alloc] init];
    [self addChildViewController:rightPanelVC];
    rightPanelVC.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightPanelContainer addSubview:rightPanelVC.view];
    [NSLayoutConstraint activateConstraints:@[
        [rightPanelVC.view.leadingAnchor constraintEqualToAnchor:self.rightPanelContainer.leadingAnchor],
        [rightPanelVC.view.trailingAnchor constraintEqualToAnchor:self.rightPanelContainer.trailingAnchor],
        [rightPanelVC.view.topAnchor constraintEqualToAnchor:self.rightPanelContainer.topAnchor],
        [rightPanelVC.view.bottomAnchor constraintEqualToAnchor:self.rightPanelContainer.bottomAnchor]
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
    // 监听显示 AI 助手页面
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAIPage)
                                                 name:@"ShowAIPage"
                                               object:nil];
    // 监听显示"使用问题"FAQ 页（Task 82）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showHelpPage)
                                                 name:@"ShowHelpPage"
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
    // FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showAccountManager)
                                                 name:@"ShowAccountManager"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(backgroundChanged)
                                                 name:@"BackgroundChanged"
                                               object:nil];
    // 监听背景 UI 效果变化通知（Task224（#4）：界面风格切换的 action 同样
    // 发该通知——全量重铺卡片表面）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(uiEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // Task224（#4/#19）：风格/缩放直连广播——风格重铺面板表面，缩放重算
    // 面板宽度（两路均幂等，与 BackgroundUIEffectChanged 通路双保险）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_handleInterfaceStyleChanged)
                                                 name:LGCInterfaceStyleChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_handleUIScaleChanged)
                                                 name:LGCUIScaleChangedNotification
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

    // Task 72 修复（防御纵深，"找不到版本信息"）：远程列表与内存 localVersionList
    // 双双未命中时，不直接判死——立即扫描磁盘 versions/ 目录兜底。
    // localVersionList 是 viewDidLoad / ReloadProfileList 时的快照，任何安装路径
    // 若漏发 ReloadProfileList（或外部工具刚写入版本），快照即过期；此时启动
    // 会误弹"找不到版本信息"。磁盘存在 <id>.json 即返回与 localVersionList 同构的
    // @{id, type=custom}，与既有本地版本启动路径完全一致（downloadVersion 内部的
    // Task70/71 自愈链会处理 JSON 缺失/损坏等边界）。
    if (!versionObject && versionId.length > 0) {
        NSString *versionJsonPath = [NSString stringWithFormat:@"%s/versions/%@/%@.json",
                                      getenv("POJAV_GAME_DIR"), versionId, versionId];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:versionJsonPath isDirectory:&isDir] && !isDir) {
            versionObject = @{@"id": versionId, @"type": @"custom"};
            NSLog(@"[LauncherRootVC] Task72 version found on disk (stale list fallback): %@", versionId);
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
    // Task173：复用主页 VC 实例（头像消失根修，见 cachedHomeVC 属性注释）。
    // setContentViewController 对同一实例有早退守卫（主页已在前台时点击
    // 主页按钮 = 无操作）；从其它页切回时走正常 crossDissolve + 子 VC
    // appearance 链——viewWillAppear 触发 updateSkinDisplay（本地/会话缓存
    // 命中同步上屏，不再有网络窗口期）。
    if (!self.cachedHomeVC) {
        self.cachedHomeVC = [[LauncherNewsViewController alloc] init];
        NSLog(@"[HomeAvatar] Task173 home VC created (will be reused across tab switches)");
    } else {
        NSLog(@"[HomeAvatar] Task173 home VC reused (avatar survives tab switch)");
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

- (void)showAIPage {
    // 从 AiSessionStore 取最近会话，没有则让 AIViewController 新建一个
    AiSession *session = [[AiSessionStore sharedStore] lastActiveSession];
    AIViewController *vc = [[AIViewController alloc] initWithSession:session];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

- (void)showHelpPage {
    // Task 82："使用问题"FAQ 页（侧边栏新增标签），包在导航控制器里保持标题栏一致
    LauncherHelpViewController *vc = [[LauncherHelpViewController alloc] init];
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:vc];
    navVC.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:navVC animated:YES];
}

// ★ [MP-RESTORE] Task222：联机恢复——陶瓦联机 / ZeroTier 两个入口。
//   容器模式（setContentViewController 包 nav）：TVC 的 isHiddenRoot 分支隐藏
//   导航栏并注入左上角浮动关闭按钮（close 发 ShowHomePage 通知回主页）。
//   会话进行中切 ZeroTier 时先停陶瓦会话，以免端口冲突。
- (void)showMultiplayer {
    // 陶瓦联机界面（与 HMCL/FCL/ZL2 互通）；libterracotta 未链接时提示
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
    [self setContentViewController:nav animated:YES];
}

- (void)showZeroTier {
    // ZeroTier 联机界面（独立入口）；若陶瓦会话进行中，先停以免端口冲突。
    if ([TerracottaBridge isAvailable] &&
        [TerracottaManager shared].status != TerracottaStatusDisconnected) {
        [[TerracottaManager shared] stopSession];
    }
    MultiplayerViewController *vc = [[MultiplayerViewController alloc] initWithMode:MultiplayerVCModeLauncher];
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

/// FCL 风格：账户管理在中间内容区显示（不再 FormSheet 弹窗）
- (void)showAccountManager {
    AccountListViewController *vc = [[AccountListViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    // 账户选择后通知右侧面板刷新（使用已有的 UpdateAccountInfo 通知）
    vc.whenItemSelected = ^void() {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    // 账户删除后也通知右侧面板刷新
    vc.whenDelete = ^void(NSString *name) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo" object:nil];
    };
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.prefersLargeTitles = NO;
    [self setContentViewController:nav animated:YES];
}

- (void)backgroundChanged {
    // 重新应用背景
    [[BackgroundManager sharedManager] applyBackgroundToView:self.view];
    // Task111：背景设置/清除后同步切换侧栏/右面板容器表面（毛玻璃↔新拟态平贴）
    [self updateChromeSurfaces];
}

- (void)updateChromeSurfaces {
    // Task111：检测并切换（用户实测：背景照片功能被 Task89 强制纯色底顶掉）。
    // 有自定义背景 → 走 BackgroundManager 旧毛玻璃/半透明管线，背景图从
    // 两侧面板下方透出；无背景 → 原生平贴表面（Task163：ame_applyPanel
    // SurfaceWithRadius 已退役阴影——全屏高大容器的等比阴影会溢出压到
    // 中央卡片上，用户实测"不该改的你改了"；现为规格表面色+圆角平贴）。
    // cornerRadius/maskedCorners/masksToBounds 由调用点维护，此处只换表面。
    //
    // Task224（#4）：液态玻璃风格时面板表面升级为分层玻璃（效果层+高光层+
    // 发丝描边，maskedCorners 跟随宿主——VS 布局仅外侧圆角）；native 解析
    // 时先清残留玻璃层再走既有分支（从玻璃切回原生完全还原）。
    if (LGCIsGlassStyleActive()) {
        if (LGCApplyGlassToView(self.sidebarContainer, 16) &&
            LGCApplyGlassToView(self.rightPanelContainer, 16)) {
            return;
        }
    } else {
        LGCRemoveGlassFromView(self.sidebarContainer);
        LGCRemoveGlassFromView(self.rightPanelContainer);
    }
    if ([[BackgroundManager sharedManager] hasBackground]) {
        [[BackgroundManager sharedManager] applyEffectToView:self.sidebarContainer];
        [[BackgroundManager sharedManager] applyEffectToView:self.rightPanelContainer];
    } else {
        [self.sidebarContainer ame_applyPanelSurfaceWithRadius:16];
        [self.rightPanelContainer ame_applyPanelSurfaceWithRadius:16];
    }
}

- (void)uiEffectChanged:(NSNotification *)notification {
    // Task111：毛玻璃/半透明/背景模式变化后统一重刷容器表面
    // （attachment 幂等重建，表面色随主题）
    [self updateChromeSurfaces];
}

// Task224（#4）：界面风格切换 → 面板表面重铺（玻璃↔原生双向还原）。
- (void)ame224_handleInterfaceStyleChanged {
    [self updateChromeSurfaces];
    NSLog(@"[ThemeOps] Task224 VS-layout chrome surfaces re-applied (resolved=%d)",
          (int)LGCResolvedInterfaceStyle());
}

// Task224（#19）：界面缩放变化 → 面板宽度重算 + 子 VC 重布局。
- (void)ame224_handleUIScaleChanged {
    CGFloat ame224_sidebar = LauncherRootLayoutSidebarWidth(self.traitCollection);
    CGFloat ame224_right = LauncherRootLayoutRightPanelWidth(self.traitCollection);
    if (self.sidebarWidthConstraint && self.sidebarWidthConstraint.constant != ame224_sidebar) {
        self.sidebarWidthConstraint.constant = ame224_sidebar;
    }
    if (self.rightPanelWidthConstraint && self.rightPanelWidthConstraint.constant != ame224_right) {
        self.rightPanelWidthConstraint.constant = ame224_right;
    }
    for (UIViewController *child in self.childViewControllers) {
        [child.view setNeedsLayout];
    }
    [self.view setNeedsLayout];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Custom Appearance（字体颜色 / 卡片颜色，与 Card 布局一致）

- (void)applyCustomAppearance {
    // Task137：新拟态退役，容器表面由 updateChromeSurfaces 的原生平贴分支管理；
    // general.card_color / 毛玻璃不再作用于容器表面；text_color 偏好
    // 仍由子 VC 的 LauncherAppearanceApplied 处理。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"LauncherAppearanceApplied" object:nil];
}

- (void)applySemiTransparentColor:(UIColor *)color toContainer:(UIView *)container {
    // 保留 BackgroundManager 的毛玻璃 UIVisualEffectView，在其上叠加半透明纯色
    // 这样既显示用户自定义的卡片颜色，又能透出背景图
    container.backgroundColor = color;
}

- (void)restoreEffectToContainer:(UIView *)container {
    container.backgroundColor = [UIColor clearColor];
    // 检查是否已有毛玻璃，没有则重新应用
    BOOL hasBlur = NO;
    for (UIView *sub in container.subviews) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            hasBlur = YES;
            break;
        }
    }
    if (!hasBlur) {
        [[BackgroundManager sharedManager] applyEffectToView:container];
    }
}

- (UIColor *)colorFromHexString:(NSString *)hexString {
    NSString *hex = [hexString stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (hex.length != 6 && hex.length != 8) return nil;
    unsigned int rgb = 0;
    if (![[NSScanner scannerWithString:hex] scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (hex.length == 6) {
        // RRGGBB
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
        a = 255;
    } else {
        // AARRGGBB
        a = (rgb >> 24) & 0xFF;
        r = (rgb >> 16) & 0xFF;
        g = (rgb >> 8) & 0xFF;
        b = rgb & 0xFF;
    }
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:a/255.0];
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

    // FCL 风格：对 UINavigationController 应用 nav bar 毛玻璃效果，并对内容 VC 透明化处理，
    // 避免顶部出现默认白色 nav bar 形成"大白条"，同时与两侧深色毛玻璃面板视觉一致。
    if ([viewController isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)viewController;
        nav.delegate = self;
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:nav.navigationBar];
        // 透明化 topViewController，让背景透出 nav bar 毛玻璃
        [[BackgroundManager sharedManager] makeViewControllerTransparent:nav.topViewController];
        // 透明化 nav 栈中所有已存在的 VC（防止前一个页面透出残留）
        for (UIViewController *stackVC in nav.viewControllers) {
            [[BackgroundManager sharedManager] makeViewControllerTransparent:stackVC];
        }
    } else {
        // 非导航控制器包装的 VC 也透明化，确保与背景融合
        [[BackgroundManager sharedManager] makeViewControllerTransparent:viewController];
    }

    // 关键修复（UI 累积异常）：deactivate 旧约束，避免在 tmpRootVC 保留场景下
    // 缓存复用的子 VC 反复激活约束导致 contentContainer 内容区左右变宽。
    if (self.currentContentConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.currentContentConstraints];
        self.currentContentConstraints = nil;
    }

    NSArray<NSLayoutConstraint *> *newConstraints = @[
        [viewController.view.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor],
        [viewController.view.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor],
        [viewController.view.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor],
        [viewController.view.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor]
    ];

    if (animated && oldVC) {
        // 修复问题5：原实现用两个独立的 UIView transitionWithView:（一个移除旧视图、一个添加新视图），
        // 两个 crossDissolve 同时作用于 contentContainer 会导致视觉冲突和残影（旧画面未完全消失就覆盖新界面）。
        // 改为单个 transition：在同一个 animations block 内完成"移除旧视图 + 添加新视图"，
        // crossDissolve 会正确抓取前后快照做交叉渐变，completion 中清理旧 VC 父子关系。
        //
        // 关键修复（入场动画从左上角弹出）：UIKit 在 animations block 返回后立即对容器做 snapshot，
        // 此时新视图虽然已 addSubview + activateConstraints，但尚未经历 layout pass，frame 仍是
        // (0,0,0,0)。配合 contentContainer 子视图（contentCard）的 masksToBounds+圆角裁剪，
        // crossDissolve 渐变呈现"从左上角小点扩展出来"的怪异效果。
        // 在 animations block 内显式 layoutIfNeeded 强制立即布局，让 snapshot B 时 frame 已撑满，
        // crossDissolve 就是标准的淡入淡出。duration 由 0.25 调整为 0.3 让过渡更柔和自然。
        // Task223：先落位再动画（新视图 addSubview + 约束 + 强制布局，
        // 确保 transform/alpha 动画作用于已撑满的 frame——crossDissolve 时代
        // 的"左上角小点弹出"教训在此同样适用）。
        [self.contentContainer addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:newConstraints];
        [self.contentContainer layoutIfNeeded];
        self.contentContainer.clipsToBounds = YES;
        viewController.view.alpha = 0.0;
        viewController.view.transform = CGAffineTransformMakeTranslation(30, 0);
        oldVC.view.transform = CGAffineTransformIdentity;
        [UIView animateWithDuration:0.38 delay:0
                        usingSpringWithDamping:0.85 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
            viewController.view.alpha = 1.0;
            viewController.view.transform = CGAffineTransformIdentity;
            oldVC.view.alpha = 0.0;
            oldVC.view.transform = CGAffineTransformMakeTranslation(-22, 0);
        } completion:^(BOOL finished) {
            oldVC.view.alpha = 1.0;
            oldVC.view.transform = CGAffineTransformIdentity;
            [oldVC willMoveToParentViewController:nil];
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
            [viewController didMoveToParentViewController:self];
        }];
    } else {
        if (oldVC) {
            [oldVC willMoveToParentViewController:nil];
            [oldVC.view removeFromSuperview];
            [oldVC removeFromParentViewController];
        }
        [self.contentContainer addSubview:viewController.view];
        [NSLayoutConstraint activateConstraints:newConstraints];
        [viewController didMoveToParentViewController:self];
        // Task225 (#11 缺失动画补充)：无 oldVC（首次内容落位）或 animated=NO
        // 的兜底路径——先落位约束再轻淡入，代替瞬时出现（菜单/右栏入口
        // 第一次打开设置等也有过渡；不与 animated 分支的弹簧滑动重叠）。
        [self.contentContainer layoutIfNeeded];
        viewController.view.alpha = 0.0;
        [UIView animateWithDuration:0.30 delay:0 options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            viewController.view.alpha = 1.0;
        } completion:nil];
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

/// 当 nav 栈 push 或 pop 完成后，对新显示的 VC 透明化处理，
/// 确保所有 push 进来的子页面（如 Java 管理、模组管理、整合包导入等）
/// 都能透出自定义启动器背景，而非显示默认的 systemBackgroundColor（白色）。
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
