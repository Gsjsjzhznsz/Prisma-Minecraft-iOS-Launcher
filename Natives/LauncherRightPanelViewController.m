#import "LauncherRightPanelViewController.h"
#import "UIKit+NativeSurface.h" // Task160 新拟态规格色
#import "authenticator/BaseAuthenticator.h"
#import "AccountListViewController.h"
#import "SurfaceViewController.h"
#import "JavaGUIViewController.h"
#import "JavaLauncher.h"
#import "PLCrashView.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "MinecraftResourceDownloadTask.h"
#import "DownloadTaskManager.h"
#import "DownloadTasksViewController.h"
#import "DownloadTaskItem.h"
#import "PLTaskProgressViewController.h"
#import "ALTServerConnection.h"
#import "BackgroundManager.h"
#import "LiquidGlassCompat.h"   // Task224（#19）：界面缩放（右栏字号/间距）
#import "AboutViewController.h"   // Task217：启动器版本卡 about 路由
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AvatarManager.h"
#import "ImageCropperViewController.h"
#import "LauncherPreferencesViewController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h> // Task156：信息卡手势的 associated-object 路由

#include <sys/time.h>
#include <math.h> // Task102：fabs（居中偏移钳制比较）

// 添加 C 函数声明 - 这些函数在 LauncherPreferences.m 或其他地方定义
extern void setPrefString(NSString *key, NSString *value);
extern void setPrefInt(NSString *key, NSInteger value);

static void *ProgressObserverContext = &ProgressObserverContext;
// Task102：滚动区 contentSize KVO 上下文——卡片组整体居中的 contentInset 联动
// （下载中心/进度 UI 展开折叠只改 contentSize，不一定触发 VC 根视图重布局，
//   靠 KVO 才能精确跟上内容增减）。
static void *AmeInfoContentSizeContext = &AmeInfoContentSizeContext;
// Task102：面板纵向安全边距——头像距面板顶部间距与执行Jar/管理版本按钮
// 距面板底部间距共用同一常量（用户指定对称关系：头像顶部间距 = 按钮底部
// 间距），后续调整只改这一处，对称关系不会再被破坏。
static const CGFloat AmePanelVerticalEdgeInset = 12;

@interface LauncherRightPanelViewController () <UIDocumentPickerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate>

@property(nonatomic, strong) UIImageView *avatarImageView;
@property(nonatomic, strong) UILabel *usernameLabel;
// Task101：原灰字游戏版本标签（versionLabel）已退场——游戏版本由绿色
// 游戏版本卡显示（同一数据源），顶部冗余灰字按用户要求去除。
@property(nonatomic, strong) UIButton *launchButton;
@property(nonatomic, strong) UIButton *manageVersionBtn;
@property(nonatomic, strong) UIButton *executeJarBtn;
// ===== Task96：MeloNX 风格信息卡（把 MeloNX 设置页的信息卡搬入右侧面板）=====
// 卡片纵向滚动区：7 张信息卡 + 下载中心/进度 UI 一起装入 UIStackView，
// 空间不足时整区上下滚动（用户确认方案）。左右边缘与「登录并启动」对齐。
@property(nonatomic, strong) UIScrollView *infoScrollView;
@property(nonatomic, strong) UIStackView *infoStackView;
// 各卡片的正文标签（MeloNX 卡片结构：小号彩色标题 + 大号正文；按用户要求
// 不带 "2.6 / JIT Enabled" 之类附带小字）。Task93 起内存两卡与启动日志同源。
@property(nonatomic, strong) UILabel *launcherVersionCardValue; // 启动器版本
@property(nonatomic, strong) UILabel *gameVersionCardValue;    // 游戏版本
@property(nonatomic, strong) UILabel *deviceCardValue;         // 设备
@property(nonatomic, strong) UILabel *systemCardValue;         // 系统
@property(nonatomic, strong) UILabel *jitCardValue;            // JIT（兔子图标卡）
@property(nonatomic, strong) UILabel *memLimitCardValue;       // 内存上限提升
@property(nonatomic, strong) UILabel *extVMCardValue;          // 扩展虚拟寻址

// 下载相关属性
@property(nonatomic, strong) MinecraftResourceDownloadTask *task;
@property(nonatomic, strong) UIProgressView *progressView;
@property(nonatomic, strong) UILabel *progressLabel;

// ===== 下载中心入口（参照 FCL/ZL2/HMCL 的统一下载进度弹窗入口）=====
// FCL/ZL2/HMCL 都在启动器主界面提供一个"下载管理/下载中心"入口按钮，
// 点击后弹出下载进度对话框，集中显示所有下载任务（MC本体/模组/光影/资源包等）的实时进度。
// 本按钮即对应这个入口：当 DownloadTaskManager 中存在任何下载任务时显示，
// 点击以 FormSheet 方式弹出 DownloadTasksViewController（全任务列表 + 进度详情）。
@property(nonatomic, strong) UIButton *downloadCenterButton;
// 按钮上的活动指示器（下载进行中时旋转，表示有活跃任务）
@property(nonatomic, strong) UIActivityIndicatorView *downloadCenterActivityIndicator;
// 按钮上的进度百分比标签（实时显示所有活动任务的聚合进度）
@property(nonatomic, strong) UILabel *downloadCenterProgressLabel;
// 进行中任务数徽标（redesign-download-ui Task 2.4）：红色圆形小徽标显示
// 进行中（下载中/排队中）任务数，无进行中任务时隐藏
@property(nonatomic, strong) UILabel *downloadCenterBadgeLabel;
// 当前弹出的下载中心 VC（弱引用，避免循环持有）
@property(nonatomic, weak) DownloadTasksViewController *presentedDownloadCenterVC;
// 标记用户是否手动关闭了下载中心（避免下载任务更新时反复自动弹出）
@property(nonatomic, assign) BOOL userDismissedDownloadCenter;

// FCL 风格：无账号时点击启动游戏跳转添加账号界面，登录完成后自动继续启动。
// pendingLaunchAfterLogin=YES 表示用户从启动按钮进入账号登录，登录成功后应自动触发 launchGame。
@property(nonatomic, assign) BOOL pendingLaunchAfterLogin;
// Task226：JIT 等待超时的静默自动重拉已用标记（每轮 launch 重置）
@property(nonatomic, assign) BOOL ame226_jitAutoRetried;

@end

@implementation LauncherRightPanelViewController

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor clearColor];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 即使本控制器在 LauncherRootViewController 中作为子 VC 添加，仍需在自身 viewDidLoad 中调用。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupUI];
    [self updateAccountInfo];
    [self updateVersionInfo];
    
    // Task173：自动启动出口（gJvmUsedInProcess 一键出路的冷启侧）。用户在
    // "Forge 安装完成 → 启动 → 安装器占用 JVM"弹窗里选了「重启并启动」后，
    // internal.autolaunch_profile 持久化 + exit(0)；下次冷启在此检测该键：
    // 选中对应实例 → 清键 → 延迟 1.5s（等 UI/账户就位）触发 launchGame
    //（JIT 等待链 invokeAfterJITEnabled 照常接管，与手动点启动完全同路）。
    {
        NSString *ame173_autolaunch = getPrefObject(@"internal.autolaunch_profile");
        if ([ame173_autolaunch isKindOfClass:NSString.class] && ame173_autolaunch.length > 0) {
            setPrefObject(@"internal.autolaunch_profile", nil);
            NSLog(@"[Task173] autolaunch detected for '%@' -- will auto-launch after UI settles", ame173_autolaunch);
            if (PLProfiles.current.profiles[ame173_autolaunch]) {
                [PLProfiles.current setSelectedProfileName:ame173_autolaunch];
            }
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                NSLog(@"[Task173] auto-launching profile '%@'", ame173_autolaunch);
                [strongSelf launchGame];
            });
        }
    }
    
    // 监听账户信息更新通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateAccountInfo)
                                                 name:@"UpdateAccountInfo"
                                               object:nil];
    // 监听版本/配置切换通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateVersionInfo)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];

    // 监听统一下载任务聚合状态变化，以更新启动按钮
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateLaunchButtonState)
                                                 name:DownloadTaskManagerAggregateStateDidChangeNotification
                                               object:nil];

    // ===== 下载中心入口通知监听 =====
    // 监听下载任务更新通知（进度变化、新任务注册等），实时更新下载中心按钮的显示状态和进度百分比。
    // 这确保了模组、光影、资源包、数据包、世界存档等所有通过 DownloadTaskManager 注册的下载任务
    // 都能在下载中心按钮上反映出来，用户点击即可查看详情（参照 FCL/ZL2/HMCL 的下载进度弹窗）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskUpdate:)
                                                 name:DownloadTaskManagerDidUpdateTaskNotification
                                               object:nil];
    // 监听任务完成通知，更新按钮状态并在全部完成时隐藏活动指示器
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompleted:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];
    // 监听下载中心被用户手动关闭的通知，设置标记避免反复自动弹出
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadCenterDismissed)
                                                 name:@"DownloadCenterDidDismiss"
                                               object:nil];

    // 监听启动器外观变化（自定义字体/卡片颜色），刷新文字颜色
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyCustomAppearance)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // Task224（#18）：壁纸变化 → 亮度自适应文字重算（Ame223WallpaperChanged
    // 复用欢迎页链路；面板半透明时壁纸直接透到文字底下）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_handleWallpaperChanged)
                                                 name:Ame223WallpaperChangedNotification
                                               object:nil];
    // Task224（#19）：界面缩放变化 → 右栏字号/间距实时重排。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_refreshScaledFonts)
                                                 name:LGCUIScaleChangedNotification
                                               object:nil];
    // Task225（#13）：文字缩放独立成键——字号变化同样触发刷新
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_refreshScaledFonts)
                                                 name:LGCTextScaleChangedNotification
                                               object:nil];
    // Task224（#4）：界面风格切换 → 面板表面随活重铺（可见状态下）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:LGCInterfaceStyleChangedNotification
                                               object:nil];

    // JIT 状态必须实时反映：StikJIT/SideJIT 常在启动器已打开后才完成附加（甚至
    // 附加后自身退出，应用被 launchd 收养），若只在 viewWillAppear 刷新，标签会
    // 一直停留在"未开启"。应用回到前台时同步刷新一次。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateJITStatus)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];

    // 内存 entitlement 状态与 JIT 标识使用相同刷新时机（Task88）：
    // entitlement 签名后固定、运行期不会变化，这里仅为保证界面每次回到前台
    // 都处于最新状态，与 updateJITStatus 的刷新策略保持一致。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateMemoryEntitlementStatus)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateAccountInfo];
    [self updateVersionInfo];
    [self updateLaunchButtonState];
    [self updateJITStatus];
    [self updateMemoryEntitlementStatus];
    [self applyCustomAppearance];
    [self updateDownloadCenterButton];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Task102：头像宽度跟随执行Jar按钮（等宽约束），圆角动态取宽/2 保持正圆
    // （原固定 72pt→36 圆角，改等宽后尺寸随面板变化，写死会变成椭圆圆角）
    CGFloat avatarSide = self.avatarImageView.bounds.size.width;
    if (avatarSide > 0) {
        self.avatarImageView.layer.cornerRadius = avatarSide / 2.0;
    }
    // Task102：卡片组整体居中——视口尺寸变化（首布局/旋转/面板宽度切换）时
    // 重算 contentInset；内容增减由 contentSize KVO 单独跟上
    [self updateInfoContentInset];
}

/// Task102：七卡并列位置整体居中（用户澄清：居中的是卡片的并列位置，
/// 不是卡片内容——Task101 的内容居中已回退为左对齐布局）。
/// 实现：滚动区内容（下载中心 + 7 张信息卡）总高不足视口时，上下均分
/// contentInset，让整组落在右侧栏中部；内容超高（下载 UI 展开/小屏）时
/// inset 归零，恢复普通滚动，不破 Task96 的可滚动能力。
/// 幂等：inset 未变化时不写回，避免无谓的布局抖动。
- (void)updateInfoContentInset {
    UIScrollView *scrollView = self.infoScrollView;
    if (!scrollView || scrollView.bounds.size.height <= 0 || scrollView.contentSize.height <= 0) return;
    CGFloat inset = (scrollView.bounds.size.height - scrollView.contentSize.height) / 2.0;
    if (inset < 0) inset = 0;
    UIEdgeInsets target = UIEdgeInsetsMake(inset, 0, inset, 0);
    if (!UIEdgeInsetsEqualToEdgeInsets(scrollView.contentInset, target)) {
        scrollView.contentInset = target;
    }
    // 偏移钳制：内容变小时有效偏移区间收拢到唯一点 -inset，主动落位到居中
    // 位置，不依赖系统迟到的补偿；拖拽/减速中不干预，避免抢手势
    if (inset > 0 && !scrollView.isDragging && !scrollView.isDecelerating
        && fabs(scrollView.contentOffset.y - (-inset)) > 0.5) {
        scrollView.contentOffset = CGPointMake(scrollView.contentOffset.x, -inset);
    }
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Task183：Task180 按钮透明度实时重刷退役（双滑条体系整体撤销，回归
    // Task179 形态：底色恒定，不接任何透明度滑条）
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Task102：卡片组居中联动 KVO 同步移除（setupUI 必然注册，直接移除安全）
    @try {
        [self.infoScrollView removeObserver:self
                                 forKeyPath:@"contentSize"
                                    context:AmeInfoContentSizeContext];
    } @catch (NSException *e) {}
    // 关键修复（UI 累积异常）：KVO 兜底移除，防止 task 仍在进行中时 VC 被释放导致野指针。
    if (self.task && self.task.progress) {
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // 头像
    self.avatarImageView = [[UIImageView alloc] init];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.avatarImageView.layer.cornerRadius = 36;
    self.avatarImageView.layer.masksToBounds = YES;
    // Task137：占位底色原生化（0.2 白硬编码深灰与下载中心小框同族问题，
    // 改 tertiarySystemFillColor 随深浅色自适应）
    self.avatarImageView.backgroundColor = [UIColor tertiarySystemFillColor];
    self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    self.avatarImageView.tintColor = [UIColor systemGrayColor];
    self.avatarImageView.userInteractionEnabled = YES;
    [self.avatarImageView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(selectAccount:)]];
    // 长按头像：弹出自定义头像导入/清除菜单
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(showAvatarMenu:)];
    longPress.minimumPressDuration = 0.5;
    [self.avatarImageView addGestureRecognizer:longPress];
    [self.view addSubview:self.avatarImageView];
    
    // 用户名标签
    self.usernameLabel = [[UILabel alloc] init];
    self.usernameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    // Task224（#19）：字号乘界面缩放倍率（1.0 时与原 16pt 逐字节一致）
    self.usernameLabel.font = [UIFont boldSystemFontOfSize:LGCScaledFontSize(16)];
    self.usernameLabel.textColor = AmeCardPrimaryTextColor(); // Task160 规格主文字（#18 动态反色在 applyCustomAppearance 内接管）
    self.usernameLabel.textAlignment = NSTextAlignmentCenter;
    // iPhone 上侧栏宽度更窄，开启字号自适应避免长用户名被截断
    self.usernameLabel.adjustsFontSizeToFitWidth = YES;
    self.usernameLabel.minimumScaleFactor = 0.7;
    self.usernameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.usernameLabel.text = localize(@"i18n_str_357", nil);
    [self.view addSubview:self.usernameLabel];

    // Task101：原灰字游戏版本标签（versionLabel，头像下方的 26.3）整体退场：
    // 游戏版本卡（绿色）与它同数据源（updateVersionInfo），顶部不再重复显示。

    // 进度标签
    self.progressLabel = [[UILabel alloc] init];
    self.progressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressLabel.font = [UIFont systemFontOfSize:12];
    self.progressLabel.textColor = AmeCardSecondaryTextColor(); // Task160 规格次要文字
    self.progressLabel.textAlignment = NSTextAlignmentCenter;
    self.progressLabel.text = @"";
    self.progressLabel.hidden = YES;
    // Task96：不再直接挂 self.view，改入下方信息卡滚动区的 UIStackView
    
    // 进度条
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    self.progressView.translatesAutoresizingMaskIntoConstraints = NO;
    self.progressView.hidden = YES;
    // Task96：装入信息卡滚动区（组装见 makeInfoCard... 之后的 stack 组装段）
    [self.progressView.heightAnchor constraintEqualToConstant:4].active = YES;

    // ===== 下载中心入口按钮（参照 FCL/ZL2/HMCL 下载进度弹窗入口）=====
    // 设计理念：FCL 和 ZL2 在启动器主界面提供一个"下载管理"按钮，点击后弹出下载进度对话框；
    // HMCL 在下载页面显示所有下载任务的进度。本按钮综合三者风格：
    // - 按钮样式：圆角卡片式，与启动器其他按钮统一
    // - 左侧：下载图标 + 活动指示器（下载中时旋转）
    // - 中间："下载中心"文字 + 进度百分比
    // - 右侧：箭头图标（表示点击可查看详情）
    // - 当 DownloadTaskManager 中存在任何下载任务时显示，无任务时隐藏
    self.downloadCenterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.downloadCenterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.downloadCenterButton setTitle:localize(@"i18n_str_136", nil) forState:UIControlStateNormal];
    [self.downloadCenterButton setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
    self.downloadCenterButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.downloadCenterButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.downloadCenterButton.titleLabel.minimumScaleFactor = 0.7;
    self.downloadCenterButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    // Task137：黑底深字直修（用户实测反馈）——旧实现硬编码 0.2 白（深灰）底
    // 配 labelColor 字（浅色模式下黑字），深浅模式都可能不可读。改用原生卡片
    // 表面（secondarySystemGroupedBackground），深浅色对比度由系统语义色保证。
    // Task183：Task180 按钮透明度接线撤销，回归恒定语义色底
    self.downloadCenterButton.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.downloadCenterButton.layer.cornerRadius = 10;
    self.downloadCenterButton.layer.masksToBounds = YES;
    // 左侧下载图标
    UIImage *downloadIcon = [UIImage systemImageNamed:@"arrow.down.circle"];
    [self.downloadCenterButton setImage:downloadIcon forState:UIControlStateNormal];
    self.downloadCenterButton.tintColor = accentColor();
    self.downloadCenterButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    self.downloadCenterButton.titleEdgeInsets = UIEdgeInsetsMake(0, 4, 0, -4);
    self.downloadCenterButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    self.downloadCenterButton.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [self.downloadCenterButton addTarget:self action:@selector(openDownloadCenter) forControlEvents:UIControlEventTouchUpInside];
    self.downloadCenterButton.hidden = YES; // 默认隐藏，有下载任务时显示
    // Task96：改入信息卡滚动区 UIStackView（见下方 stack 组装段）

    // 活动指示器（下载中时旋转，叠加在按钮右侧）
    self.downloadCenterActivityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.downloadCenterActivityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterActivityIndicator.color = accentColor();
    self.downloadCenterActivityIndicator.hidesWhenStopped = YES;
    [self.downloadCenterButton addSubview:self.downloadCenterActivityIndicator];

    // 进度百分比标签（叠加在按钮右侧，显示聚合进度）
    self.downloadCenterProgressLabel = [[UILabel alloc] init];
    self.downloadCenterProgressLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterProgressLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.downloadCenterProgressLabel.textColor = accentColor();
    self.downloadCenterProgressLabel.textAlignment = NSTextAlignmentRight;
    self.downloadCenterProgressLabel.text = @"0%";
    [self.downloadCenterButton addSubview:self.downloadCenterProgressLabel];

    // 进行中任务数徽标（红色圆形，位于进度百分比左侧，redesign-download-ui Task 2.4）
    self.downloadCenterBadgeLabel = [[UILabel alloc] init];
    self.downloadCenterBadgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.downloadCenterBadgeLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
    self.downloadCenterBadgeLabel.textColor = [UIColor whiteColor];
    self.downloadCenterBadgeLabel.backgroundColor = [UIColor systemRedColor];
    self.downloadCenterBadgeLabel.textAlignment = NSTextAlignmentCenter;
    self.downloadCenterBadgeLabel.layer.cornerRadius = 8.0;
    self.downloadCenterBadgeLabel.layer.masksToBounds = YES;
    self.downloadCenterBadgeLabel.hidden = YES;
    [self.downloadCenterButton addSubview:self.downloadCenterBadgeLabel];
    
    // 启动游戏按钮（FCL 复合布局 + ZL2 按压动画风格）
    self.launchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchButton setTitle:localize(@"i18n_str_412", nil) forState:UIControlStateNormal];
    [self.launchButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.launchButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    // iPhone 右侧面板更窄：标题字号自适应，避免"下载中..."等长文案被截断
    self.launchButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.launchButton.titleLabel.minimumScaleFactor = 0.6;
    self.launchButton.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.launchButton.backgroundColor = accentColor();
    self.launchButton.layer.cornerRadius = 10;
    self.launchButton.layer.masksToBounds = YES;
    // FCL 风格：按钮阴影（elevation 效果），增强层次感
    self.launchButton.layer.shadowColor = [UIColor blackColor].CGColor;
    self.launchButton.layer.shadowOffset = CGSizeMake(0, 2);
    self.launchButton.layer.shadowRadius = 4;
    self.launchButton.layer.shadowOpacity = 0.3;
    // masksToBounds 会裁剪阴影，改用 backgroundColor + cornerRadius 不裁剪
    // 但 masksToBounds=YES 是为了让背景色圆角生效，阴影需要单独的容器视图
    // 权衡：保留 masksToBounds=YES（圆角更重要），放弃阴影（iOS 上 UIButton 本身有高亮效果）
    self.launchButton.layer.masksToBounds = YES;

    [self.launchButton addTarget:self action:@selector(launchButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    // ZL2 风格按压动画：按下时缩放到 0.95，松开时恢复
    [self.launchButton addTarget:self action:@selector(launchButtonTouchDown) forControlEvents:UIControlEventTouchDown];
    [self.launchButton addTarget:self action:@selector(launchButtonTouchUp) forControlEvents:UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [self.view addSubview:self.launchButton];

    // ===== Task96：MeloNX 风格信息卡（把 MeloNX 设置页的信息卡搬进右侧面板）=====
    // 结构：7 张信息卡装入纵向 UIScrollView + UIStackView，卡宽与下方
    // 「登录并启动」按钮同宽（12pt 边距）、同高（46pt）。
    // 卡片自上而下：启动器版本 → 游戏版本 → 设备 → 系统 → JIT(兔子) →
    // 内存上限提升 → 扩展虚拟寻址；JIT 卡按用户指定放在 MeloNX 四卡
    // （设备/系统/内存×2）的正中间，与内存权限卡同色系。
    // 下载中心/进度 UI 也一并装入 stack 顶部，隐藏时由 UIStackView 自动折叠，
    // 空间不足时整区上下滚动（用户确认方案）。
    self.infoScrollView = [[UIScrollView alloc] init];
    self.infoScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoScrollView.showsHorizontalScrollIndicator = NO;
    self.infoScrollView.alwaysBounceVertical = YES;
    if (@available(iOS 11.0, *)) {
        self.infoScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self.view addSubview:self.infoScrollView];

    self.infoStackView = [[UIStackView alloc] init];
    self.infoStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.infoStackView.axis = UILayoutConstraintAxisVertical;
    self.infoStackView.alignment = UIStackViewAlignmentFill;
    self.infoStackView.distribution = UIStackViewDistributionFill;
    self.infoStackView.spacing = 8;
    [self.infoScrollView addSubview:self.infoStackView];

    [NSLayoutConstraint activateConstraints:@[
        [self.infoStackView.topAnchor constraintEqualToAnchor:self.infoScrollView.contentLayoutGuide.topAnchor],
        [self.infoStackView.bottomAnchor constraintEqualToAnchor:self.infoScrollView.contentLayoutGuide.bottomAnchor],
        [self.infoStackView.leadingAnchor constraintEqualToAnchor:self.infoScrollView.contentLayoutGuide.leadingAnchor],
        [self.infoStackView.trailingAnchor constraintEqualToAnchor:self.infoScrollView.contentLayoutGuide.trailingAnchor],
        [self.infoStackView.widthAnchor constraintEqualToAnchor:self.infoScrollView.frameLayoutGuide.widthAnchor],
    ]];

    // Task102：卡片组整体居中——监听 contentSize 变化，内容不足视口时上下
    // 均分 contentInset 使七卡并列位置落在右侧栏中部（用户指定：居中的是
    // 卡片的并列位置，不是卡片内容）；内容超高时 inset 归零恢复普通滚动。
    // 首布局/旋转由 viewDidLayoutSubviews 兜底，下载 UI 展开折叠由本 KVO 跟上。
    [self.infoScrollView addObserver:self
                          forKeyPath:@"contentSize"
                             options:NSKeyValueObservingOptionNew
                             context:AmeInfoContentSizeContext];

    // stack 顶部：下载中心入口 / 进度文本 / 进度条（隐藏时自动折叠不占位）
    [self.infoStackView addArrangedSubview:self.downloadCenterButton];
    [self.infoStackView addArrangedSubview:self.progressLabel];
    [self.infoStackView addArrangedSubview:self.progressView];
    [self.downloadCenterButton.heightAnchor constraintEqualToConstant:36].active = YES;

    // 卡片配色（用户指定）：新卡 #64C466 绿；设备/系统同色（系统蓝）；
    // JIT 与内存权限卡同色系（橙/黄）。卡片正文之外一律不带小字。
    UIColor *cardGreen = [UIColor colorWithRed:0x64 / 255.0 green:0xC4 / 255.0 blue:0x66 / 255.0 alpha:1.0];  // #64C466
    UIColor *cardBlue = [UIColor systemBlueColor];
    UIColor *cardOrange = [UIColor colorWithRed:1.0 green:0.584 blue:0.0 alpha:1.0];                          // #FF9500
    UIColor *cardAmber = [UIColor colorWithRed:0.906 green:0.635 blue:0.0 alpha:1.0];                         // #E7A200（黄系加深保可读）

    // 设备图标按机型选 iPad/iPhone 轮廓；系统卡沿用苹果标
    NSString *deviceIconName = [UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad
        ? @"ipad" : @"iphone";

    // 卡片语言按用户指定全部中文；JIT 卡标题即 "JIT"（兔子=速度，替代原 JIT 徽标）。
    // Task101 图标修正（用户实测 JIT 卡回退成 circle.grid.2x2 点阵）：SF Symbols
    // 全库（1.0→8.0 共 9476 符号，联网核实 sf-symbols-reference 全表）中不存在
    // 名为 "rabbit" 的符号——兔子的真名是 hare（SF Symbols 1.0 起就有，线框兔）。
    // 内存两卡改用 ROM 芯片符号：扩展内存限制=实心 memorychip.fill（SF 3.0），
    // 扩展虚拟内存=空心 memorychip（SF 2.0，即原内存上限提升卡同款图标），
    // 均按用户指定；原名 arrow.up.left.and.arrow.down.right 退场。
    UIView *launcherVersionCard = [self makeInfoCardWithIcon:@"cube.transparent" accent:cardGreen title:localize(@"ame189.rp.launcher_version", nil) valueLabel:&_launcherVersionCardValue];
    UIView *gameVersionCard = [self makeInfoCardWithIcon:@"gamecontroller" accent:cardGreen title:localize(@"ame189.rp.game_version", nil) valueLabel:&_gameVersionCardValue];
    UIView *deviceCard = [self makeInfoCardWithIcon:deviceIconName accent:cardBlue title:localize(@"ame189.rp.device", nil) valueLabel:&_deviceCardValue];
    UIView *systemCard = [self makeInfoCardWithIcon:@"applelogo" accent:cardBlue title:localize(@"ame189.rp.system", nil) valueLabel:&_systemCardValue];
    UIView *jitCard = [self makeInfoCardWithIcon:@"hare" accent:cardOrange title:@"JIT" valueLabel:&_jitCardValue];
    UIView *memLimitCard = [self makeInfoCardWithIcon:@"memorychip.fill" accent:cardOrange title:localize(@"ame189.rp.mem_limit", nil) valueLabel:&_memLimitCardValue];
    UIView *extVMCard = [self makeInfoCardWithIcon:@"memorychip" accent:cardAmber title:localize(@"ame189.rp.ext_vm", nil) valueLabel:&_extVMCardValue];

    // Task156：信息卡点击直达对应入口（用户反馈"右边侧边栏的信息能不能点击
    // 直达对应的入口"）。映射：启动器版本→设置·检查更新（深链）、游戏版本→
    // 版本管理页、JIT→设置·JIT 开启工具（深链）、内存两卡→设置·内存分配
    // （深链）、设备/系统→设置首页（无更精确入口）。深链经
    // LauncherPreferencesViewController.ameDeepLinkKey 滚动到行并高亮。
    // Task217：启动器版本卡改路由 about（关于页）——原 settings:check_update
    // 深链随"启动器更新两项迁往关于页"一并改道（用户指令："将右侧侧边栏
    // “启动器版本”入口改为指向关于页面"）。
    [self ame156_attachInfoCardTap:launcherVersionCard route:@"about"];
    [self ame156_attachInfoCardTap:gameVersionCard       route:@"versionManager"];
    [self ame156_attachInfoCardTap:deviceCard            route:@"settings"];
    [self ame156_attachInfoCardTap:systemCard            route:@"settings"];
    [self ame156_attachInfoCardTap:jitCard               route:@"settings:jit_enabler"];
    [self ame156_attachInfoCardTap:memLimitCard          route:@"settings:memory_limit_help"];
    [self ame156_attachInfoCardTap:extVMCard             route:@"settings:memory_limit_help"];

    [self.infoStackView addArrangedSubview:launcherVersionCard];
    [self.infoStackView addArrangedSubview:gameVersionCard];
    [self.infoStackView addArrangedSubview:deviceCard];
    [self.infoStackView addArrangedSubview:systemCard];
    [self.infoStackView addArrangedSubview:jitCard];
    [self.infoStackView addArrangedSubview:memLimitCard];
    [self.infoStackView addArrangedSubview:extVMCard];

    // 启动器版本卡：App 版本号 + 构建号双读（用户指定 "5.0.0 (build)" 格式；
    // 两者相同时只显示一个，避免 "5.0.0 (5.0.0)" 冗余）
    NSString *shortVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    NSString *buildVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleVersion"] ?: @"";
    if (shortVersion.length == 0) {
        shortVersion = localize(@"ame189.common.unknown", nil);
    }
    if (buildVersion.length > 0 && ![buildVersion isEqualToString:shortVersion]) {
        self.launcherVersionCardValue.text = [NSString stringWithFormat:@"%@ (%@)", shortVersion, buildVersion];
    } else {
        self.launcherVersionCardValue.text = shortVersion;
    }

    // 设备/系统卡：utils.h Task96 数据源（营销名 + "iPadOS x.x (build)"）
    self.deviceCardValue.text = getDeviceMarketingName();
    self.systemCardValue.text = getSystemVersionDisplay();

    // 选择版本按钮（FCL 风格：右侧版本选择入口；控制设置已挪到左侧菜单 case 3）
    self.manageVersionBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.manageVersionBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.manageVersionBtn setTitle:localize(@"i18n_str_38", nil) forState:UIControlStateNormal];
    // Task96：与「登录并启动」同款配色（accentColor 底 + 白字）
    [self.manageVersionBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [self.manageVersionBtn.titleLabel setFont:[UIFont systemFontOfSize:14 weight:UIFontWeightMedium]];
    self.manageVersionBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.manageVersionBtn.titleLabel.minimumScaleFactor = 0.7;
    self.manageVersionBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.manageVersionBtn.backgroundColor = accentColor();
    self.manageVersionBtn.layer.cornerRadius = 10;
    [self.manageVersionBtn addTarget:self action:@selector(showVersionPicker) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.manageVersionBtn];

    // 执行JAR按钮
    self.executeJarBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    self.executeJarBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.executeJarBtn setTitle:localize(@"i18n_str_414", nil) forState:UIControlStateNormal];
    // Task96：按用户要求与「登录并启动」同款配色（accentColor 底 + 白字）
    [self.executeJarBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.executeJarBtn.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.executeJarBtn.titleLabel.minimumScaleFactor = 0.7;
    self.executeJarBtn.titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.executeJarBtn.backgroundColor = accentColor();
    self.executeJarBtn.layer.cornerRadius = 10;
    [self.executeJarBtn addTarget:self action:@selector(executeJar) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.executeJarBtn];
    
    // 约束布局（Task96 改版；Task102 头像等宽执行Jar按钮 + 顶/底间距对称）：
    // - 顶部：头像（宽=执行Jar按钮，距顶=按钮距底）/用户名 自上而下锚定
    // - 中部：信息卡滚动区（7 张卡 + 下载中心/进度 UI，空间不足整区上下滚动，
    //   内容不足视口时整组垂直居中——Task102 updateInfoContentInset），
    //   左右边缘与下方「登录并启动」按钮对齐（同 12pt 边距）
    // - 底部：启动按钮 + 执行Jar/选择版本一排，自下而上锚定
    [NSLayoutConstraint activateConstraints:@[
        // 头像（顶部）——Task102：宽度与执行Jar按钮等宽（用户指定；原固定
        // 72pt 与按钮宽度不一致），高度跟随宽度保持正方形头像，正圆效果由
        // viewDidLayoutSubviews 动态圆角（宽/2）保证；距面板顶部间距与
        // 执行Jar按钮距面板底部间距共用 AmePanelVerticalEdgeInset（对称）
        [self.avatarImageView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:AmePanelVerticalEdgeInset],
        [self.avatarImageView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToAnchor:self.executeJarBtn.widthAnchor],
        [self.avatarImageView.heightAnchor constraintEqualToAnchor:self.avatarImageView.widthAnchor],

        // 用户名
        [self.usernameLabel.topAnchor constraintEqualToAnchor:self.avatarImageView.bottomAnchor constant:8],
        [self.usernameLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.usernameLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        // ===== 信息卡滚动区（Task96；Task101 上接用户名标签）=====
        // 进度/下载中心/卡片全部在滚动区内的 stack 里，隐藏时自动折叠；
        // 空间不足时滚动区内部滚动，不会与顶部/底部产生约束冲突。
        [self.infoScrollView.topAnchor constraintEqualToAnchor:self.usernameLabel.bottomAnchor constant:8],
        [self.infoScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.infoScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.infoScrollView.bottomAnchor constraintEqualToAnchor:self.launchButton.topAnchor constant:-8],

        // 活动指示器（下载中心按钮右侧，垂直居中；按钮本身在滚动区 stack 内）
        [self.downloadCenterActivityIndicator.trailingAnchor constraintEqualToAnchor:self.downloadCenterButton.trailingAnchor constant:-12],
        [self.downloadCenterActivityIndicator.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],

        // 进度百分比标签（指示器左侧，垂直居中）
        [self.downloadCenterProgressLabel.trailingAnchor constraintEqualToAnchor:self.downloadCenterActivityIndicator.leadingAnchor constant:-6],
        [self.downloadCenterProgressLabel.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],

        // 进行中任务数徽标（进度百分比左侧，垂直居中；隐藏时自动收起不占位）
        [self.downloadCenterBadgeLabel.trailingAnchor constraintEqualToAnchor:self.downloadCenterProgressLabel.leadingAnchor constant:-6],
        [self.downloadCenterBadgeLabel.centerYAnchor constraintEqualToAnchor:self.downloadCenterButton.centerYAnchor],
        [self.downloadCenterBadgeLabel.heightAnchor constraintEqualToConstant:16],
        [self.downloadCenterBadgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:16],

        // ===== 下方按钮区（自下而上锚定到 safeArea 底部，参照 FCL 两按钮一排）=====
        // 执行Jar 按钮（最底部，左半区；Task96 起与登录并启动同款配色）
        [self.executeJarBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-AmePanelVerticalEdgeInset],
        [self.executeJarBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.executeJarBtn.heightAnchor constraintEqualToConstant:38],

        // 管理版本按钮（最底部，右半区，与执行Jar 同一排）
        [self.manageVersionBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-AmePanelVerticalEdgeInset],
        [self.manageVersionBtn.leadingAnchor constraintEqualToAnchor:self.executeJarBtn.trailingAnchor constant:8],
        [self.manageVersionBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.manageVersionBtn.heightAnchor constraintEqualToConstant:38],

        // 两个按钮宽度相等（各占一半，减去中间 8pt 间距）
        [self.executeJarBtn.widthAnchor constraintEqualToAnchor:self.manageVersionBtn.widthAnchor],

        // 启动按钮（占满整排，位于两按钮上方）
        [self.launchButton.bottomAnchor constraintEqualToAnchor:self.executeJarBtn.topAnchor constant:-8],
        [self.launchButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.launchButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [self.launchButton.heightAnchor constraintEqualToConstant:46],
    ]];

    // 创建后立即刷新一次状态卡片（同步快速，无需等 viewWillAppear）：
    // JIT 卡三态 + 内存权限两卡（Task93 起与启动日志同源的签名口径）
    [self updateJITStatus];
    [self updateMemoryEntitlementStatus];

    // Task 146a：撤销 Task 139 的 iPhone 精简（96pt 图标轨：隐藏用户名/信息卡
    // 滚动区、按钮图标化、头像固定 44pt）——真机反馈"右边侧边栏变窄"并非用户
    // 本意，原意是"启动按钮与登录头像之间的信息列表在显示不全时可上下滚动"。
    // 恢复 168pt 全内容列后，infoScrollView 本身就是纵向滚动区（顶部锚
    // usernameLabel、底部锚 launchButton、infoStackView 钉在 contentLayoutGuide），
    // 内容超出可视高度时天然可滚动，无需任何设备分支代码。
}

#pragma mark - Actions

- (void)selectAccount:(UITapGestureRecognizer *)gesture {
    // 用户主动管理账号（非启动入口），取消任何"待启动"意图，
    // 避免登录后意外自动启动游戏。
    self.pendingLaunchAfterLogin = NO;
    // FCL 风格：账户管理在中间内容区显示，发送通知让 LauncherRootViewController 切换内容
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
}

#pragma mark - 下载中心（参照 FCL/ZL2/HMCL 下载进度弹窗）

/// 打开下载中心弹窗
/// 参照 FCL/ZL2/HMCL 的下载进度显示方式：以 FormSheet 方式弹出 DownloadTasksViewController，
/// 集中显示所有下载任务（MC本体/模组/光影/资源包/数据包/世界存档/整合包）的实时进度。
/// 所有通过 DownloadTaskManager 注册的下载任务都会在这里显示，实现统一的下载进度管理。
- (void)openDownloadCenter {
    // 如果已经弹出了下载中心，直接返回避免重复弹出
    if (self.presentedDownloadCenterVC) {
        return;
    }

    // 用户主动打开了下载中心，重置"用户已关闭"标记
    self.userDismissedDownloadCenter = NO;

    DownloadTasksViewController *downloadCenterVC = [[DownloadTasksViewController alloc] init];
    downloadCenterVC.modalPresentationStyle = UIModalPresentationFormSheet;
    // 弹出时不要覆盖全屏，FormSheet 方式在 iPad 上居中显示，在 iPhone 上接近全屏
    downloadCenterVC.preferredContentSize = CGSizeMake(500, 600);

    // 弱引用持有，避免循环持有
    self.presentedDownloadCenterVC = downloadCenterVC;

    // 获取最顶层的视图控制器来 present
    UIViewController *topVC = self;
    while (topVC.presentedViewController) {
        topVC = topVC.presentedViewController;
    }

    [topVC presentViewController:downloadCenterVC animated:YES completion:nil];
}

/// 处理下载任务更新通知（进度变化、新任务注册等）
/// 当收到通知时仅更新下载中心按钮的状态，不再自动弹出下载中心界面。
///
/// redesign-download-ui Phase 3：单任务进度展示统一由任务注册时置
/// autoPresentDetail=YES 的 DownloadTaskItem 触发 DownloadTaskManager
/// 自动弹出统一进度页（PLTaskProgressViewController）；下载中心
/// DownloadTasksViewController 仅保留为手动打开（通过下载中心按钮）。
- (void)handleDownloadTaskUpdate:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// 处理下载任务完成通知
/// 当任务完成时更新按钮状态；如果所有任务都已完成，延迟隐藏下载中心按钮
- (void)handleDownloadTaskCompleted:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateDownloadCenterButton];
    });
}

/// 处理下载中心被用户手动关闭的通知
/// 设置 userDismissedDownloadCenter=YES，避免后续下载任务更新时反复自动弹出下载中心。
/// 用户可以通过点击启动器上的"下载中心"按钮重新打开（会重置此标记）。
- (void)handleDownloadCenterDismissed {
    self.userDismissedDownloadCenter = YES;
    self.presentedDownloadCenterVC = nil;
}

/// 更新下载中心按钮的显示状态和进度百分比
/// 根据 DownloadTaskManager 的当前状态：
/// - 无任务：隐藏按钮
/// - 有活跃任务（downloading/pending）：显示按钮 + 活动指示器旋转 + 进行中任务数徽标 + 显示聚合进度百分比
/// - 全部完成：显示按钮 + 活动指示器停止 + 显示"已完成"
- (void)updateDownloadCenterButton {
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSArray<DownloadTaskItem *> *allTasks = [manager allTasks];

    if (allTasks.count == 0) {
        // 无任何下载任务，隐藏下载中心按钮
        self.downloadCenterButton.hidden = YES;
        self.downloadCenterBadgeLabel.hidden = YES;
        [self.downloadCenterActivityIndicator stopAnimating];
        return;
    }

    // 有下载任务，显示按钮
    self.downloadCenterButton.hidden = NO;

    // 计算聚合进度（所有活动任务的平均进度）
    BOOL hasActive = NO;
    BOOL allCompleted = YES;
    double totalProgress = 0.0;
    NSInteger activeCount = 0;

    for (DownloadTaskItem *task in allTasks) {
        if (task.state == DownloadTaskStateDownloading || task.state == DownloadTaskStatePending) {
            hasActive = YES;
            allCompleted = NO;
            totalProgress += task.progress;
            activeCount++;
        } else if (task.state != DownloadTaskStateCompleted) {
            allCompleted = NO;
        }
    }

    // 进行中任务数徽标（redesign-download-ui Task 2.4）：有进行中任务时显示数量
    if (hasActive) {
        self.downloadCenterBadgeLabel.text = activeCount > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)activeCount];
        self.downloadCenterBadgeLabel.hidden = NO;
    } else {
        self.downloadCenterBadgeLabel.hidden = YES;
    }

    if (hasActive) {
        // 有活跃下载任务
        double avgProgress = activeCount > 0 ? totalProgress / activeCount : 0.0;
        NSInteger percent = (NSInteger)(avgProgress * 100.0 + 0.5);
        percent = MAX(0, MIN(100, percent));
        self.downloadCenterProgressLabel.text = [NSString stringWithFormat:@"%ld%%", (long)percent];
        [self.downloadCenterActivityIndicator startAnimating];
    } else if (allCompleted) {
        // 全部完成
        self.downloadCenterProgressLabel.text = localize(@"i18n_str_126", nil);
        [self.downloadCenterActivityIndicator stopAnimating];
    } else {
        // 有暂停/失败/取消的任务但没有活跃任务
        self.downloadCenterProgressLabel.text = localize(@"i18n_str_125", nil);
        [self.downloadCenterActivityIndicator stopAnimating];
    }
}

#pragma mark - 自定义头像导入

- (void)showAvatarMenu:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:localize(@"i18n_str_357", nil) message:localize(@"i18n_str_415", nil)];
        return;
    }

    BOOL hasCustom = [[AvatarManager sharedManager] hasCustomAvatarForAccount:accountId];

    // ★ Task227（反馈 #3：悬浮弹窗风格统一）：界面风格 = 液态玻璃时，长按
    // 头像的菜单改走玻璃悬浮浮层（与整体设置一致）；native 风格保持系统
    // UIAlertController（原生外观）。此前所有弹窗一律 UIAlertController，
    // 与液态玻璃设置不符（用户实测"不符合设置"）。
    if (LGCIsGlassStyleActive()) {
        NSMutableArray<NSDictionary *> *ame227_actions = [NSMutableArray array];
        [ame227_actions addObject:@{
            @"title": localize(@"i18n_str_417", nil),
            @"style": @(UIAlertActionStyleDefault),
            @"handler": @"avatarPick",
        }];
        if (hasCustom) {
            [ame227_actions addObject:@{
                @"title": localize(@"i18n_str_418", nil),
                @"style": @(UIAlertActionStyleDestructive),
                @"handler": @"avatarRemove",
            }];
        }
        [ame227_actions addObject:@{
            @"title": localize(@"resman.common.cancel", nil),
            @"style": @(UIAlertActionStyleCancel),
            @"handler": @"",
        }];
        [self ame227_presentGlassMenu:ame227_actions
                           sourceView:self.avatarImageView
                                 accountId:accountId];
        return;
    }

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_416", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_417", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self openAvatarImagePicker];
    }]];
    if (hasCustom) {
        [sheet addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_418", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
            [[AvatarManager sharedManager] removeAvatarForAccount:accountId];
            [self updateAccountInfo];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配：用 popover 锚定到头像
    if (sheet.popoverPresentationController) {
        sheet.popoverPresentationController.sourceView = self.avatarImageView;
        sheet.popoverPresentationController.sourceRect = self.avatarImageView.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

/// ★ Task227：玻璃悬浮菜单（液态玻璃风格专用）：锚定 sourceView 的浮层，
/// 玻璃底 + 连续圆角 + 主色标题；点按动作后收起。遮罩点击取消。
- (void)ame227_presentGlassMenu:(NSArray<NSDictionary *> *)actions
                     sourceView:(UIView *)sourceView
                     accountId:(NSString *)accountId {
    UIViewController *presenter = self;
    while (presenter.presentedViewController != nil) presenter = presenter.presentedViewController;

    UIView *ame227_dim = [[UIView alloc] initWithFrame:presenter.view.bounds];
    ame227_dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ame227_dim.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.25];
    ame227_dim.userInteractionEnabled = YES;

    UIVisualEffectView *ame227_panel = [[UIVisualEffectView alloc]
        initWithEffect:LGCCreateGlassEffectView(NO).effect];
    ame227_panel.layer.cornerRadius = 20.0;
    ame227_panel.layer.cornerCurve = kCACornerCurveContinuous;
    ame227_panel.layer.masksToBounds = YES;

    UIStackView *ame227_stack = [[UIStackView alloc] init];
    ame227_stack.axis = UILayoutConstraintAxisVertical;
    ame227_stack.spacing = 2;
    ame227_stack.translatesAutoresizingMaskIntoConstraints = NO;
    [ame227_panel.contentView addSubview:ame227_stack];

    UITapGestureRecognizer *ame227_dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(ame227_glassMenuDimTapped:)];
    [ame227_dim addGestureRecognizer:ame227_dimTap];

    for (NSDictionary *ame227_act in actions) {
        NSString *ame227_title = ame227_act[@"title"];
        NSInteger ame227_style = [ame227_act[@"style"] integerValue];
        NSString *ame227_handler = ame227_act[@"handler"];
        UIButton *ame227_btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [ame227_btn setTitle:ame227_title forState:UIControlStateNormal];
        ame227_btn.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
        UIColor *ame227_color = (ame227_style == UIAlertActionStyleDestructive)
            ? [UIColor systemRedColor]
            : [UIColor labelColor];
        [ame227_btn setTitleColor:ame227_color forState:UIControlStateNormal];
        ame227_btn.contentEdgeInsets = UIEdgeInsetsMake(12, 20, 12, 20);
        [ame227_btn addTarget:self action:@selector(ame227_glassMenuAction:) forControlEvents:UIControlEventTouchUpInside];
        ame227_btn.tag = 0;
        objc_setAssociatedObject(ame227_btn, "ame227.handler", ame227_handler, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(ame227_btn, "ame227.accountId", accountId, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [ame227_stack addArrangedSubview:ame227_btn];
        [ame227_btn.heightAnchor constraintEqualToConstant:44].active = YES;
        [ame227_btn.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    }

    [presenter.view addSubview:ame227_dim];
    [ame227_dim addSubview:ame227_panel];
    ame227_panel.translatesAutoresizingMaskIntoConstraints = NO;
    CGRect ame227_src = [sourceView convertRect:sourceView.bounds toView:presenter.view];
    [NSLayoutConstraint activateConstraints:@[
        [ame227_panel.widthAnchor constraintEqualToAnchor:ame227_stack.widthAnchor constant:40],
        [ame227_panel.centerXAnchor constraintLessThanOrEqualToAnchor:presenter.view.centerXAnchor],
        [ame227_panel.leadingAnchor constraintGreaterThanOrEqualToAnchor:presenter.view.leadingAnchor constant:16],
        [ame227_panel.trailingAnchor constraintLessThanOrEqualToAnchor:presenter.view.trailingAnchor constant:-16],
        [ame227_panel.topAnchor constraintEqualToAnchor:presenter.view.topAnchor
                                              constant:MAX(60.0, CGRectGetMinY(ame227_src) + CGRectGetHeight(ame227_src) + 10.0)],
    ]];
    ame227_dim.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{
        ame227_dim.alpha = 1;
    }];
}

- (void)ame227_glassMenuDimTapped:(UITapGestureRecognizer *)t {
    [UIView animateWithDuration:0.18 animations:^{
        t.view.alpha = 0;
    } completion:^(BOOL finished) {
        [t.view removeFromSuperview];
    }];
}

- (void)ame227_glassMenuAction:(UIButton *)sender {
    NSString *ame227_handler = objc_getAssociatedObject(sender, "ame227.handler");
    NSString *ame227_accountId = objc_getAssociatedObject(sender, "ame227.accountId");
    // 收起浮层（dim 是面板的父链根）
    UIView *ame227_root = sender.superview;
    while (ame227_root != nil && ame227_root.gestureRecognizers.count == 0) {
        ame227_root = ame227_root.superview;
    }
    [UIView animateWithDuration:0.18 animations:^{
        ame227_root.alpha = 0;
    } completion:^(BOOL finished) {
        [ame227_root removeFromSuperview];
    }];
    if ([ame227_handler isEqualToString:@"avatarPick"]) {
        [self openAvatarImagePicker];
    } else if ([ame227_handler isEqualToString:@"avatarRemove"] && ame227_accountId.length > 0) {
        [[AvatarManager sharedManager] removeAvatarForAccount:ame227_accountId];
        [self updateAccountInfo];
    }
}

- (void)openAvatarImagePicker {
    // 防止重复弹出
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        for (UIView *view in window.subviews) {
            if ([view isKindOfClass:[UIImagePickerController class]]) return;
        }
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            UIImage *selectedImage = info[UIImagePickerControllerOriginalImage];
            if (!selectedImage) {
                [self showAlert:localize(@"i18n_str_42", nil) message:localize(@"i18n_str_368", nil)];
                return;
            }
            // 头像需要正方形，非正方形则裁剪
            if (selectedImage.size.width != selectedImage.size.height) {
                ImageCropperViewController *cropperVC = [[ImageCropperViewController alloc] initWithImage:selectedImage];
                __weak typeof(self) weakSelf = self;
                cropperVC.completionHandler = ^(UIImage * _Nullable croppedImage) {
                    [weakSelf dismissViewControllerAnimated:YES completion:^{
                        if (croppedImage) {
                            [weakSelf saveAvatarImage:croppedImage];
                        }
                    }];
                };
                // 本 VC 为 child view controller，self.navigationController 可能为 nil，
                // 故用 present 方式呈现裁剪器（包装在 NavigationController 中以保留其导航栏样式）
                UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:cropperVC];
                nav.modalPresentationStyle = UIModalPresentationFullScreen;
                [self presentViewController:nav animated:YES completion:nil];
            } else {
                [self saveAvatarImage:selectedImage];
            }
        });
    }];
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveAvatarImage:(UIImage *)image {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    NSString *accountId = currentAuth.authData[@"accountId"];
    if (!accountId || accountId.length == 0) {
        [self showAlert:localize(@"i18n_str_42", nil) message:localize(@"i18n_str_419", nil)];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[AvatarManager sharedManager] saveAvatarForAccount:accountId image:image withCompletion:^(BOOL success, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (success) {
                [weakSelf updateAccountInfo];
            } else {
                NSString *msg = error.localizedDescription ?: localize(@"i18n_str_420", nil);
                [weakSelf showAlert:localize(@"i18n_str_42", nil) message:msg];
            }
        });
    }];
}

#pragma mark - 状态卡片刷新（JIT / 内存权限，Task96 改为 MeloNX 风格信息卡）

- (void)updateJITStatus {
    if (!self.jitCardValue) return;
    BOOL enabled = isJITEnabled(NO);
    // Three-state display on TXM devices (iPadOS 26 + M-series): JIT can be
    // "enabled" (CS_DEBUGGED set) while the JIT26 debugger that must service
    // brk #0x69 at launch is gone.  That state is expected and recoverable --
    // invokeAfterJITEnabled re-attaches the script via stikjit:// -- so tell
    // it apart from plain "Not Enabled" instead of lying either way.
    // Task96：三态写入 JIT 卡正文（卡片语言按用户指定全部中文）；
    // 卡片配色固定与内存权限卡同色系（用户指定），状态由正文文字表达。
    if (enabled && DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
        !JIT26IsLikelyDebuggerKeepAttached()) {
        self.jitCardValue.text = localize(@"ame189.rp.jit_attached", nil);
    } else if (enabled) {
        self.jitCardValue.text = localize(@"ame189.common.on", nil);
    } else {
        self.jitCardValue.text = localize(@"ame189.common.off", nil);
    }
}

#pragma mark - Task156：信息卡点击直达对应入口

// 挂点击手势（卡片是普通 UIView，用 tap gesture 而非改造成按钮——
// makeInfoCardWithIcon 的内部层级/约束零改动）。
- (void)ame156_attachInfoCardTap:(UIView *)card route:(NSString *)route {
    if (card == nil || route.length == 0) return;
    card.userInteractionEnabled = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(ame156_infoCardTapped:)];
    // 路由标识随身携带（多张卡共用同一 selector）
    objc_setAssociatedObject(tap, "ame156_route", route, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [card addGestureRecognizer:tap];
}

// 沿父链找最近的导航宿主（LauncherRoot / LauncherCardLayout 都实现了
// showSettings / showVersionManager；不 import 具体类，respondsToSelector
// 动态判定避免布局层耦合）。
- (void)ame156_navigateToRoute:(NSString *)route {
    NSString *target = route;
    NSString *deepLinkKey = nil;
    NSRange colon = [route rangeOfString:@":"];
    if (colon.location != NSNotFound) {
        target = [route substringToIndex:colon.location];
        deepLinkKey = [route substringFromIndex:colon.location + 1];
    }

    UIViewController *host = self.parentViewController;
    while (host != nil && ![host respondsToSelector:@selector(showSettings)]) {
        host = host.parentViewController;
    }
    if (host == nil) {
        NSLog(@"[RightPanel] Task156: no navigation host found for route %@", route);
        return;
    }

    if ([target isEqualToString:@"versionManager"]) {
        if ([host respondsToSelector:@selector(showVersionManager)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [host performSelector:@selector(showVersionManager)];
#pragma clang diagnostic pop
        }
        return;
    }

    // Task217：about 路由——关于页（二级菜单：版本/QQ 群/启动器更新/许可证/致谢）。
    if ([target isEqualToString:@"about"]) {
        AboutViewController *aboutVC = [[AboutViewController alloc] init];
        UINavigationController *aboutNav = [[UINavigationController alloc] initWithRootViewController:aboutVC];
        if ([host respondsToSelector:@selector(setContentViewController:animated:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [host performSelector:@selector(setContentViewController:animated:)
                       withObject:aboutNav
                       withObject:@(YES)];
#pragma clang diagnostic pop
        } else {
            aboutNav.modalPresentationStyle = UIModalPresentationFormSheet;
            [self presentViewController:aboutNav animated:YES completion:nil];
        }
        NSLog(@"[RightPanel] Task217: info card -> about page");
        return;
    }

    // settings[:deepLinkKey]
    // ★ Task226（反馈 #15：右侧栏打开设置没有动画）：设置页首次构建
    // （视图加载 + 全量行数据 + 首次布局）在 setContentViewController 的
    // 动画开启前同步执行，主线程被卡 ~0.5s——CA 动画按真实时钟推进，
    // 冻结期间 0.38s 的弹簧过渡已悄然走完，用户看到"瞬时出现"。
    // 修法：路由延迟一个 runloop 拍——信息卡按压回弹动画先完整呈现，
    // 设置页构建与过渡动画在空闲主线程上执行（动画不再被吃掉）。
    dispatch_async(dispatch_get_main_queue(), ^{
    LauncherPreferencesViewController *prefsVC = [[LauncherPreferencesViewController alloc] init];
    prefsVC.ameDeepLinkKey = deepLinkKey;
    UINavigationController *navVC = [[UINavigationController alloc] initWithRootViewController:prefsVC];
    navVC.navigationBar.prefersLargeTitles = YES;
    if ([host respondsToSelector:@selector(setContentViewController:animated:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [host performSelector:@selector(setContentViewController:animated:)
                   withObject:navVC
                   withObject:@(YES)];
#pragma clang diagnostic pop
    } else {
        // 宿主无 setContentViewController：直接弹设置页（降级但仍可用）
        [self presentViewController:navVC animated:YES completion:nil];
    }
    NSLog(@"[RightPanel] Task156: info card -> %@ (deepLink=%@)", target, deepLinkKey ?: @"<none>");
    }); // Task226 deferred-route close
}

- (void)ame156_infoCardTapped:(UITapGestureRecognizer *)tap {
    NSString *route = objc_getAssociatedObject(tap, "ame156_route");
    if (route == nil) return;
    // ★ Task222（清单第 8 项）：信息卡按压反馈动画（旧实现零反馈，点击
    //   "不知道按没按上"）。先快速缩到 0.97，spring 回弹到位后再路由——
    //   与设置页 hero 卡（ame218_heroCardTapped）同一交互语言。
    UIView *card = tap.view;
    [UIView animateWithDuration:0.08 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        card.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.35 delay:0
                        usingSpringWithDamping:0.55 initialSpringVelocity:0.4
                        options:0 animations:^{
            card.transform = CGAffineTransformIdentity;
        } completion:nil];
        [self ame156_navigateToRoute:route];
    }];
}

#pragma mark - MeloNX 风格信息卡工厂（Task96）

/// 生成 MeloNX 风格信息卡：圆角彩色底 + SF 图标 + 小号彩色标题 +
/// 大号正文，内容整体在卡片内水平居中（Task101 用户指定：七卡居中）。
/// 正文随深浅色取 #222222/#EEEEEE（Task91 字色规范），超长时
/// 自动缩小到不溢出（用户指定）。卡片高度与「登录并启动」按钮一致（46pt），
/// 宽度撑满 stack（与按钮同宽）。按用户要求不带任何小字副标题。
// Task98 CI 解堵：参数从裸 UILabel **（ARC 下默认 __autoreleasing）改为
// UILabel * __strong *——调用点传入的是属性 ivar 的地址（&_xxxCardValue，
// strong 存储），对 __autoreleasing 出参做写回是编译错误
// （"passing address of non-local object to __autoreleasing parameter for
// write-back"，Xcode 15.4 实测 7 处全崩在 401-407 行，2af8c45 CI 失败根因）。
// 改为 __strong * 后类型严格匹配，单次 *out = value 赋值由编译器生成标准
// strong store（先 release 旧值再 retain 新值），运行期语义与原设计完全一致。
// 功能代码（卡片结构/配色/层级）零改动，仅所有权限定符修正。
- (UIView *)makeInfoCardWithIcon:(NSString *)iconName
                          accent:(UIColor *)accent
                           title:(NSString *)title
                      valueLabel:(UILabel * __strong *)outValueLabel {
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    // Task183：Task180 按钮透明度接线撤销，信息卡回归原设计 accent × 0.15 淡底
    card.backgroundColor = [accent colorWithAlphaComponent:0.15];
    card.layer.cornerRadius = 12;
    card.layer.masksToBounds = YES;
    [card.heightAnchor constraintEqualToConstant:46].active = YES;

    // 左侧图标（与标题同色；Task102 回退 Task101 内容居中误解，恢复 Task96
    // 左锢定布局——用户澄清：居中的是七卡并列位置，不是卡片内容）
    UIImageView *iconView = [[UIImageView alloc] initWithImage:[self cardSymbolImageNamed:iconName]];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.tintColor = accent;
    [card addSubview:iconView];

    // 小号彩色标题（Task224（#19）：字号乘界面缩放倍率）
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont systemFontOfSize:LGCScaledFontSize(11) weight:UIFontWeightMedium];
    titleLabel.textColor = accent;
    titleLabel.text = title;
    [card addSubview:titleLabel];

    // 大号正文（Task91 字色规范：浅色 #222222 / 深色 #EEEEEE，动态色自动跟随）
    UILabel *valueLabel = [[UILabel alloc] init];
    valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    valueLabel.font = [UIFont systemFontOfSize:LGCScaledFontSize(15) weight:UIFontWeightSemibold]; // Task224（#19）缩放
    valueLabel.textColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traitCollection) {
        return traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark
            ? [UIColor colorWithRed:0xEE / 255.0 green:0xEE / 255.0 blue:0xEE / 255.0 alpha:1.0]
            : [UIColor colorWithRed:0x22 / 255.0 green:0x22 / 255.0 blue:0x22 / 255.0 alpha:1.0];
    }];
    // 超长正文自动缩小到不溢出（用户指定），极限时截尾
    valueLabel.adjustsFontSizeToFitWidth = YES;
    valueLabel.minimumScaleFactor = 0.55;
    valueLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [card addSubview:valueLabel];

    if (outValueLabel) {
        *outValueLabel = valueLabel;
    }

    // Task96 原版左锢定布局（Task102 回退后与初版一致，仅留档注释更新）：
    // 图标 20×20 垂直居中于卡左侧（leading 14），标题/正文排在图标右侧
    // （间距 10），标题贴顶 7 / 正文贴底 -7，超长时 trailing -12 内缩放截尾
    [NSLayoutConstraint activateConstraints:@[
        [iconView.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [iconView.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:20],
        [iconView.heightAnchor constraintEqualToConstant:20],

        [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
        [titleLabel.topAnchor constraintEqualToAnchor:card.topAnchor constant:7],
        [titleLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],

        [valueLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:10],
        [valueLabel.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [valueLabel.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-7],
        [valueLabel.topAnchor constraintGreaterThanOrEqualToAnchor:titleLabel.bottomAnchor constant:0],
    ]];
    return card;
}

/// SF Symbol 读取（低版本/受限符号缺失时逐级回退，避免 nil 图标）
- (UIImage *)cardSymbolImageNamed:(NSString *)name {
    UIImage *image = [UIImage systemImageNamed:name];
    if (!image) image = [UIImage systemImageNamed:@"circle.grid.2x2"];
    return image ?: [UIImage systemImageNamed:@"gear"];
}

#pragma mark - 内存 entitlement 状态显示（Task88 引入；Task96 改为信息卡正文）

/// 刷新「扩展内存限制」「扩展虚拟内存」两张卡片的正文。
/// Task93：与启动日志 [Pre-init] Entitlements availability 完全同源的检测——
/// getEntitlementValue()（SecTask 私有 API 读签名 entitlement，与 main.m
/// printEntitlementAvailability 同一函数）。Task90 引入的"签名+描述文件双确认"
/// （getEffectiveEntitlementValue）已按用户要求整体移除：实测双确认在重签工具把
/// entitlement 同时写入描述文件时依然误报，且与日志口径不一致导致排查混乱。
///   - 扩展内存限制 = com.apple.developer.kernel.increased-memory-limit
///   - 扩展虚拟内存 = com.apple.developer.kernel.extended-virtual-addressing
/// Task96：展示由胶囊标签改为 MeloNX 风格信息卡正文（卡片语言按用户指定
/// 全部中文，值显示 已开启/未开启）；检测函数与刷新时机不变，
/// entitlement 运行期不会变化，这里与 JIT 卡保持相同刷新时机。
/// Task101：卡名随用户指定更名（原 内存上限提升/扩展虚拟寻址），
/// 检测口径继续零变化。
- (void)updateMemoryEntitlementStatus {
    if (!self.memLimitCardValue || !self.extVMCardValue) return;
    BOOL memLimit = getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit");
    BOOL extVM = getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing");

    self.memLimitCardValue.text = memLimit ? localize(@"ame189.common.on", nil) : localize(@"ame189.common.off", nil);
    self.extVMCardValue.text = extVM ? localize(@"ame189.common.on", nil) : localize(@"ame189.common.off", nil);
}

#pragma mark - 自定义外观（字体颜色）

/// 读取 general.text_color 偏好并应用到右侧面板的主要文字。
/// 卡片背景始终深色（BackgroundManager），用户若设置浅色 card_color 则需同时设置 text_color。
/// 同时读取 general.accent_color 刷新启动按钮主题色（FCL 风格主题强调色）。
- (void)applyCustomAppearance {
    // 主题强调色：刷新启动按钮背景，使用户自选的主题色立即生效。
    // Task96：执行Jar/选择版本与「登录并启动」同款配色（accentColor 底 +
    // 白字），三枚按钮统一在此刷新。
    // Task183：Task180 按钮透明度接线撤销，三枚按钮回归恒定 accentColor 底
    self.launchButton.backgroundColor = accentColor();
    self.executeJarBtn.backgroundColor = accentColor();
    self.manageVersionBtn.backgroundColor = accentColor();

    NSString *hex = getPrefObject(@"general.text_color");
    UIColor *customColor = [self colorFromHexString:hex];
    if (customColor) {
        self.usernameLabel.textColor = customColor;
        self.progressLabel.textColor = [customColor colorWithAlphaComponent:0.75];
    } else {
        // 未设置自定义字体颜色时：
        // Task224（#18）——用户名/进度文字直接压在（半透明）面板表面、
        // 壁纸可透出的位置，改走壁纸亮度自适应色（深壁纸→白字 +
        // 软阴影 / 亮壁纸→黑字）；无壁纸时 ame224_* 回落 Task160 规格
        // 色——与今日外观逐字节一致（零回归）。
        [BackgroundManager ame224_applyAdaptiveTextToLabel:self.usernameLabel secondary:NO];
        [BackgroundManager ame224_applyAdaptiveTextToLabel:self.progressLabel secondary:YES];
        // 信息卡正文颜色随深浅色自动切换（动态色），不参与自定义文字色
    }
}

// Task224（#19）：界面缩放变化 → 右栏字号实时重排（usernameLabel /
// 三枚按钮 / 下载中心 / 进度文字 + 七张信息卡正文）。
- (void)ame224_refreshScaledFonts {
    self.usernameLabel.font = [UIFont boldSystemFontOfSize:LGCScaledFontSize(16)];
    self.launchButton.titleLabel.font = [UIFont systemFontOfSize:LGCScaledFontSize(15) weight:UIFontWeightSemibold];
    self.manageVersionBtn.titleLabel.font = [UIFont systemFontOfSize:LGCScaledFontSize(14) weight:UIFontWeightMedium];
    self.executeJarBtn.titleLabel.font = [UIFont systemFontOfSize:LGCScaledFontSize(14) weight:UIFontWeightMedium];
    self.downloadCenterButton.titleLabel.font = [UIFont systemFontOfSize:LGCScaledFontSize(13) weight:UIFontWeightMedium];
    self.progressLabel.font = [UIFont systemFontOfSize:LGCScaledFontSize(12)];
    NSArray<UILabel *> *ame224_values = @[self.launcherVersionCardValue, self.gameVersionCardValue,
                                          self.deviceCardValue, self.systemCardValue,
                                          self.jitCardValue, self.memLimitCardValue,
                                          self.extVMCardValue];
    for (UILabel *ame224_label in ame224_values) {
        ame224_label.font = [UIFont systemFontOfSize:LGCScaledFontSize(15) weight:UIFontWeightSemibold];
    }
    [self updateInfoContentInset];
}

// Task224（#18）：壁纸变化 → 亮度自适应颜色重算（复用欢迎页的
// Ame223WallpaperChanged 广播链路）。
- (void)ame224_handleWallpaperChanged {
    [self applyCustomAppearance];
    NSLog(@"[ThemeOps] Task224 right panel adaptive text refreshed after wallpaper change");
}

- (nullable UIColor *)colorFromHexString:(id)hex {
    if (![hex isKindOfClass:[NSString class]] || [(NSString *)hex length] == 0) return nil;
    NSString *clean = [(NSString *)hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    if (clean.length != 6 && clean.length != 8) return nil;
    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:clean];
    if (![scanner scanHexInt:&rgb]) return nil;
    unsigned int r, g, b, a;
    if (clean.length == 6) {
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
    return [UIColor colorWithRed:r / 255.0 green:g / 255.0 blue:b / 255.0 alpha:a / 255.0];
}

- (void)showVersionPicker {
    // FCL 风格：在右侧面板弹出 ActionSheet 让用户选择已安装的版本
    NSDictionary *profiles = PLProfiles.current.profiles;
    NSArray *sortedNames = [[profiles allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *currentSelected = PLProfiles.current.selectedProfileName;
    
    if (sortedNames.count == 0) {
        [self showAlert:localize(@"i18n_str_423", nil) message:localize(@"i18n_str_424", nil)];
        return;
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_38", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *profileName in sortedNames) {
        NSDictionary *profile = profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: @"";
        // 检测是否启用版本隔离（gameDir != "."）
        NSString *gameDir = profile[@"gameDir"] ?: @".";
        BOOL isolated = ![gameDir isEqualToString:@"."];
        NSMutableString *title = [NSMutableString string];
        if ([profileName isEqualToString:currentSelected]) {
            [title appendString:@"✓ "];
        }
        [title appendString:profileName];
        [title appendFormat:@"  (%@)", versionId];
        if (isolated) {
            [title appendString:[@"  · " stringByAppendingString:localize(@"i18n_str_2026", nil)]];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self selectProfile:profileName];
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_426", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        // 跳转到版本管理页面
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    
    // iPad 上 ActionSheet 必须指定 popoverPresentationController
    alert.popoverPresentationController.sourceView = self.manageVersionBtn;
    alert.popoverPresentationController.sourceRect = self.manageVersionBtn.bounds;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)selectProfile:(NSString *)profileName {
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];
    // SelectedProfileChanged 通知已由 setSelectedProfileName 内部发送
    [self updateVersionInfo];
}

- (void)showVersionManager {
    // 兼容旧调用方：跳转到版本管理页面
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowVersionManager" object:nil];
}

- (void)executeJar {
    // 执行JAR功能 - 打开文件选择器选择JAR文件
    // 使用 asCopy:YES 保证文件被复制到应用沙盒，避免安全作用域 URL 导致 UZKArchive 读取失败
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithMIMEType:@"application/java-archive"]]
        asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *jarURL = urls[0];
    [self enterModInstallerWithPath:jarURL.path hitEnterAfterWindowShown:NO];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
}

- (void)enterModInstallerWithPath:(NSString *)path hitEnterAfterWindowShown:(BOOL)hitEnter {
    // 关键修复（二次执行 jar 卡死）：iOS 进程内 JVM 只能创建一次
    // （gJVMUsedInProcess，第二次 JLI_Launch 会崩溃）。首次执行 jar 已在本进程
    // 创建过 JVM，再次进入 JavaGUIViewController 会黑屏卡死。因此在此处提前拦截，
    // 提示用户重启启动器，而不是进入注定失败的界面。
    if (JVMUsedInProcess()) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_214", nil)
                                                                       message:localize(@"i18n_str_1143", nil)
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_216", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [PLCrashView restartLauncher];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_217", nil) style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }

    JavaGUIViewController *vc = [[JavaGUIViewController alloc] init];
    vc.filepath = path;
    vc.hitEnterAfterWindowShown = hitEnter;
    // requiredJavaVersion 会读取 JAR 的 MANIFEST.MF 解析主类
    int javaVersion = vc.requiredJavaVersion;
    if (!javaVersion) {
        // JAR 解析失败：vc 还没 present，showDialog 不会显示，这里在 self 上弹明确提示
        [self showAlert:localize(@"i18n_str_427", nil)
                  message:[NSString stringWithFormat:localize(@"i18n_str_428", nil), path.lastPathComponent ?: @""]];
        return;
    }

    // execute_jar 路径：Caciocavallo17 jar 现已统一为 Java 17 编译版本，
    // Java 17/21 均可加载，不再需要强制提升 requiredJavaVersion 到 25。
    // - Java 8 JAR（如 OptiFine 安装器）走 Caciocavallo（非 17）路径，用 Java 8
    // - Java 17+ JAR 走 Caciocavallo17 路径，用 Java 17/21 即可
    // 与 JavaLauncher.m launchJar 分支保持一致。
    int requiredJavaVersion = javaVersion;

    // 预检 execute_jar 标签的 JRE 是否已配置，避免 present 后才发现没 JRE 导致黑屏
    NSString *javaHome = getSelectedJavaHome(@"execute_jar", requiredJavaVersion);
    if (!javaHome) {
        [self showAlert:localize(@"i18n_str_429", nil)
                  message:[NSString stringWithFormat:localize(@"i18n_str_222", nil), requiredJavaVersion, requiredJavaVersion]];
        return;
    }

    [self invokeAfterJITEnabled:^{
        vc.modalPresentationStyle = UIModalPresentationFullScreen;
        NSLog(@"[ModInstaller] launching %@ (Java %d, home=%@)", vc.filepath, requiredJavaVersion, javaHome);
        [self presentViewController:vc animated:YES completion:nil];
    }];
}

/// 显示简单的提示弹窗
- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_322", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Launch Game

/// ZL2 风格按压动画：按下时缩放到 0.95
- (void)launchButtonTouchDown {
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        self.launchButton.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:nil];
}

/// ZL2 风格按压动画：松开时恢复到 1.0
- (void)launchButtonTouchUp {
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.launchButton.transform = CGAffineTransformIdentity;
    } completion:nil];
}

- (void)launchButtonTapped {
    // 恢复按压动画（TouchUpInside 不触发 launchButtonTouchUp）
    [UIView animateWithDuration:0.1
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.launchButton.transform = CGAffineTransformIdentity;
    } completion:nil];

    if (self.task) {
        // redesign-download-ui Phase 3 Task 3.4：下载中点击启动按钮改为打开统一进度页。
        // 任务由 MinecraftResourceDownloadTask 内部注册到 DownloadTaskManager，
        // 此处按 rawTask 反查 taskId 后呈现统一进度页。
        NSString *taskId = nil;
        for (DownloadTaskItem *item in [DownloadTaskManager sharedManager].allTasks) {
            if (item.rawTask == self.task) {
                taskId = item.taskId;
                break;
            }
        }
        if (taskId) {
            [PLTaskProgressViewController presentForTaskId:taskId];
        }
    } else if ([[DownloadTaskManager sharedManager] hasActiveTasks]) {
        // 下载中仍允许启动游戏（不再硬阻断），仅提示用户有进行中的下载。
        // 原实现在此处 return 导致"开了下载球后任意下载未完成就永远无法启动游戏"，
        // 且某些下载任务状态机异常会卡住导致永久无法启动。
        [self showAlert:localize(@"i18n_str_388", nil) message:localize(@"i18n_str_430", nil)];
        [self launchGame];
    } else {
        [self launchGame];
    }
}

- (void)launchGame {
    // 下载任务不再阻断启动。某些下载（如 Mod/光影）与游戏本体启动无依赖关系，
    // 强制等待会造成"启动游戏过慢或无法启动"的体验问题。
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (!currentAuth) {
        // FCL 风格：无账号时跳转到账号管理界面，登录完成后自动继续启动。
        // 之前的行为是弹 alert 提示"请先登录账户"然后 return，用户需手动去登录再回来启动，
        // 体验不友好。改为设置 pendingLaunchAfterLogin 标记后发送 ShowAccountManager 通知，
        // 账号添加成功后 UpdateAccountInfo 通知回到此处时自动触发 launchGame 继续启动。
        self.pendingLaunchAfterLogin = YES;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
        return;
    }

    // 正常启动，清除待启动标记
    self.pendingLaunchAfterLogin = NO;
    // Task226：新一轮用户发起的启动——重置 JIT 自动重拉标记（本轮内
    // 超时可静默重拉一次，下一轮重新计数）
    self.ame226_jitAutoRetried = NO;

    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (!selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }

    NSString *versionId = PLProfiles.current.profiles[selectedProfile][@"lastVersionId"];
    if (!versionId) {
        [self showAlert:localize(@"i18n_str_43", nil)];
        return;
    }

    // FCL 风格：记录最后游玩时间戳到 profile，供版本管理页显示
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[selectedProfile] mutableCopy];
    if (profile) {
        profile[@"lastPlayed"] = @([[NSDate date] timeIntervalSince1970]);
        profiles[selectedProfile] = profile;
        [PLProfiles.current save];
    }

    // 设置UI为下载状态
    [self setInteractionEnabled:NO];
    
    // 查找版本对象
    NSDictionary *versionObject = nil;
    
    // 从远程版本列表中查找（通过 LauncherRootViewController 的 remoteVersionList）
    // 由于 remoteVersionList 在 LauncherRootViewController 中，我们需要通过其他方式获取
    // 这里使用通知来请求版本信息
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    userInfo[@"versionId"] = versionId;
    userInfo[@"callback"] = ^(NSDictionary *version) {
        if (version) {
            [self startDownloadWithVersion:version profileName:selectedProfile];
        } else {
            // 如果在远程列表中找不到，可能是本地版本
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setInteractionEnabled:YES];
                [self showAlert:localize(@"i18n_str_432", nil)];
            });
        }
    };
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"FindVersionInRemoteList" object:nil userInfo:userInfo];
}

- (void)startDownloadWithVersion:(NSDictionary *)versionObject profileName:(NSString *)profileName {
    self.task = [MinecraftResourceDownloadTask new];

    __weak LauncherRightPanelViewController *weakSelf = self;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        weakSelf.task.handleError = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf setInteractionEnabled:YES];
                // 关键修复（UI 累积异常）：handleError 时未移除 KVO 观察者，
                // task.progress 被释放后 KVO 仍指向已释放对象，多次启动会导致野指针崩溃。
                // 现在在 task = nil 之前先移除 KVO。
                @try {
                    [weakSelf.task.progress removeObserver:weakSelf
                                                forKeyPath:@"fractionCompleted"
                                                   context:ProgressObserverContext];
                } @catch (NSException *e) {}
                weakSelf.progressView.observedProgress = nil;
                weakSelf.task = nil;
            });
        };

        [weakSelf.task downloadVersion:versionObject];

        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.progressView.observedProgress = weakSelf.task.progress;
            [weakSelf.task.progress addObserver:weakSelf
                                    forKeyPath:@"fractionCompleted"
                                       options:NSKeyValueObservingOptionInitial
                                       context:ProgressObserverContext];

            // redesign-download-ui Phase 3 Task 3.4：启动下载的进度页已由任务内部
            // 阶段上报（MinecraftResourceDownloadTask.downloadVersion: 注册任务并
            // 置 autoPresentDetail=YES）自动弹出统一进度页，此处不再手动 present 旧进度 VC。
        });
    });
}

- (void)setInteractionEnabled:(BOOL)enabled {
    self.manageVersionBtn.enabled = enabled;
    self.executeJarBtn.enabled = enabled;

    // 启动游戏的完整性检查/下载：始终显示进度（HMCL 风格进度条+文本），
    // 不再被悬浮球设置隐藏。悬浮球（球心百分比）与此处进度条互为补充，
    // 确保用户在启动前能"一模一样"地看到完整性检查进度。
    BOOL showProgressUI = YES;
    if (enabled) {
        self.progressView.hidden = YES;
        self.progressLabel.hidden = YES;
        self.progressLabel.text = @"";
    } else {
        self.progressView.hidden = !showProgressUI;
        self.progressLabel.hidden = !showProgressUI;
        self.progressLabel.text = showProgressUI ? localize(@"i18n_str_2052", nil) : @"";
    }

    UIApplication.sharedApplication.idleTimerDisabled = !enabled;
    [self updateLaunchButtonState];
}

- (void)updateLaunchButtonState {
    BOOL hasActiveTasks = [[DownloadTaskManager sharedManager] hasActiveTasks];
    BOOL hasAccount = (BaseAuthenticator.current != nil);
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    BOOL hasVersion = selectedProfile && PLProfiles.current.profiles[selectedProfile][@"lastVersionId"] != nil;
    // FCL 风格：无账号时按钮仍可点击，点击后跳转账号管理界面（登录后自动继续启动）。
    // 之前 hasAccount 参与禁用判断导致无账号时按钮完全不可点，用户"点击启动游戏完全没有反应"。
    // 现在无账号时按钮可点，标题改为"登录并启动"提示用户点击后会先登录。
    BOOL enabled = hasVersion && !self.task;

    self.launchButton.enabled = enabled;
    NSString *title;
    if (hasActiveTasks) {
        title = localize(@"i18n_str_434", nil);
    } else if (!hasAccount) {
        title = localize(@"i18n_str_435", nil);
    } else {
        title = localize(@"i18n_str_412", nil);
    }
    [self.launchButton setTitle:title forState:UIControlStateNormal];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    // Task102：滚动区 contentSize 变化（下载中心/进度 UI 展开折叠）→ 重算
    // 卡片组居中 inset；与下载进度 KVO 互不干扰（context 区分）
    if (context == AmeInfoContentSizeContext) {
        [self updateInfoContentInset];
        return;
    }
    if (context != ProgressObserverContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    
    // 计算下载速度和剩余时间
    static CGFloat lastMsTime;
    static NSUInteger lastSecTime, lastCompletedUnitCount;
    NSProgress *progress = self.task.textProgress;
    // Bug fix: static 变量在多次下载之间保留旧值，导致新下载首秒吞吐量/ETA 计算错误。
    // 当 progress 尚未开始（totalUnitCount == 0）时重置。
    if (!progress || progress.totalUnitCount == 0) {
        lastMsTime = 0;
        lastSecTime = 0;
        lastCompletedUnitCount = 0;
    }
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSInteger completedUnitCount = self.task.progress.totalUnitCount * self.task.progress.fractionCompleted;
    progress.completedUnitCount = completedUnitCount;
    if (lastSecTime < tv.tv_sec) {
        CGFloat currentTime = tv.tv_sec + tv.tv_usec / 1000000.0;
        CGFloat timeDelta = currentTime - lastMsTime;
        NSInteger throughput = timeDelta > 0 ? (completedUnitCount - lastCompletedUnitCount) / timeDelta : 0;
        progress.throughput = @(throughput);
        // Bug fix: throughput 可能为 0（下载暂停/卡住），整数除零会触发 SIGFPE 崩溃
        if (throughput > 0) {
            progress.estimatedTimeRemaining = @((progress.totalUnitCount - completedUnitCount) / throughput);
        } else {
            progress.estimatedTimeRemaining = nil;
        }
        lastCompletedUnitCount = completedUnitCount;
        lastSecTime = tv.tv_sec;
        lastMsTime = currentTime;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // 启动游戏的完整性检查/下载：始终显示进度（HMCL 风格进度条+文本），
        // 不再被悬浮球设置隐藏。悬浮球（球心百分比）与此处进度条互为补充，
        // 确保用户在启动前能"一模一样"地看到完整性检查进度。
        BOOL showProgressUI = YES;
        if (showProgressUI) {
            self.progressLabel.text = progress.localizedAdditionalDescription;
        }

        if (!progress.finished) return;

        // 关键修复（UI 累积异常）：进度完成时未移除 KVO 观察者，
        // 导致每次下载完成后 KVO 仍挂在已释放的 task.progress 上，多次启动累积后崩溃。
        // 现在在 task 完成（无论是否启动游戏）后立即移除 KVO。
        @try {
            [self.task.progress removeObserver:self
                                    forKeyPath:@"fractionCompleted"
                                       context:ProgressObserverContext];
        } @catch (NSException *e) {}

        self.progressView.observedProgress = nil;
        
        if (self.task.metadata) {
            // 应用配置特定的设置
            NSString *profileName = PLProfiles.current.selectedProfileName;
            NSDictionary *profile = PLProfiles.current.profiles[profileName];
            
            if (profile) {
                // Task 140：移除“应用渲染器设置”的全局回写。旧代码把当前
                // 游戏 profile 的 renderer 写进全局 video.renderer——启动链
                // （ame_effective_renderer / JavaLauncher / SurfaceVC）本就
                // profile 优先（resolveKeyForCurrentProfile），此回写纯冗余，
                // 且会把“上一个启动的游戏的渲染器”污染成全局默认，其它
                // “跟随全局”的游戏被动切换渲染器。全局默认现在只由设置页
                // 两行写入（Task140 分居语义）。graphicsApi/java/内存的回写
                // 维持原状（不在本轮病灶内，最小改动）。
                // 应用图形 API 设置（MC 26.2+ 游戏内 OpenGL/Vulkan 切换）
                // 由 JavaLauncher.m 读取并设置 AMETHYST_GRAPHICS_API 环境变量，
                // PojavLauncher.java 写入 options.txt 的 graphicsApi 字段
                NSString *graphicsApi = profile[@"graphicsApi"];
                if (graphicsApi.length > 0) {
                    setPrefString(@"video.graphics_api", graphicsApi);
                }

                // 应用Java版本设置（兼容旧版直装器写入的 NSDictionary 格式）
                id javaVerRaw = profile[@"javaVersion"];
                NSString *javaVer = nil;
                if ([javaVerRaw isKindOfClass:[NSDictionary class]]) {
                    id major = javaVerRaw[@"majorVersion"];
                    javaVer = major ? [major description] : @"auto";
                } else if ([javaVerRaw isKindOfClass:[NSString class]]) {
                    javaVer = javaVerRaw;
                } else {
                    javaVer = @"auto";
                }
                if (![javaVer isEqualToString:@"auto"]) {
                    setPrefString(@"java.java_version", javaVer);
                }
                
                // 应用内存设置
                NSInteger allocatedMemory = [profile[@"allocatedMemory"] integerValue];
                if (allocatedMemory > 0) {
                    setPrefInt(@"general.ram_allocation", (int)allocatedMemory);
                }
            }
            
            // Task224：版本设置页启动偶发 JIT 楔死（Task185 病历：二级编辑页
            // 文本框 + 拼音键盘在后台化时楔住主队列；resign + 自愈重派已上，
            // 仍偶发）。按用户方案根治：先把面板之上呈现的整条 UI 链（版本
            // 设置/编辑页等）dismiss 干净，延迟 0.8s 让 UIKit 完成视图卸载
            // 与输入会话清理，之后才进入 JIT 等待与 SurfaceVC 启动链。
            {
                UIWindow *ame224_window = self.view.window;
                UIViewController *ame224_root = ame224_window.rootViewController;
                UIViewController *ame224_top = ame224_root;
                while (ame224_top.presentedViewController) {
                    ame224_top = ame224_top.presentedViewController;
                }
                void (^ame224_beginJITWait)(void) = ^{
                    [self invokeAfterJITEnabled:^{
                        UIKit_launchMinecraftSurfaceVC(ame224_window, self.task.metadata);
                    }];
                };
                if (ame224_top != ame224_root && ame224_top.presentingViewController) {
                    NSLog(@"[JIT] [RightPanel] Task224 closing presented stack ('%@') + 0.8s settle before JIT wait",
                          NSStringFromClass([ame224_top class]));
                    [ame224_top.presentingViewController dismissViewControllerAnimated:YES completion:^{
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                                       dispatch_get_main_queue(), ame224_beginJITWait);
                    }];
                } else {
                    // 无叠加 UI：仍给半拍让 resign/清理落地
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ame224_beginJITWait);
                }
            }
        } else {
            self.task = nil;
            [self setInteractionEnabled:YES];
            // 通知刷新版本列表
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        }
    });
}

- (void)invokeAfterJITEnabled:(void(^)(void))handler {
    [[UIApplication sharedApplication] sendAction:@selector(resignFirstResponder) to:nil from:nil forEvent:nil];

    // Task91：entitlement AND 磁盘标记双确认（同 LauncherNavigationController，
    // 防止普通侧载包里的预写标记把流程导入 apple-magnifier:// 死路）
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust") && isTrollStoreInstall();

    // Diagnostic: full JIT state at decision time (mirrors the other two
    // invokeAfterJITEnabled implementations).
    {
        BOOL hasDynamicCS = getEntitlementValue(@"dynamic-codesigning");
        int diagCsFlags = 0;
        csops(getpid(), 0, &diagCsFlags, sizeof(diagCsFlags));
        NSLog(@"[JIT] [RightPanel] invokeAfterJITEnabled: dynamicCS=%d trollStore=%d CS_DEBUGGED=%d ppid=%d traced=%d exn=%d JIT_FLAGS=0x%X",
              hasDynamicCS, hasTrollStoreJIT, (diagCsFlags & CS_DEBUGGED) != 0, getppid(), JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts(), DeviceGetJITFlags(NO));
    }

    // 决策前先刷新一次状态标签，保证显示与本次实际判定一致
    [self updateJITStatus];

    if (isJITEnabled(false)) {
        [ALTServerManager.sharedManager stopDiscovering];
        // iPadOS 26+ TXM devices: HotSpot's RX mappings are allocated by the
        // JIT26 debugger script while it services brk #0x69.  CS_DEBUGGED
        // being set only proves JIT was enabled once for this process -- the
        // JIT26 debugger itself is normally long gone by launch time
        // (ppid==1, P_TRACED==0, no task exception ports).  launchJVM() then
        // runs JIT26CreateRegionLegacy() whose brk #0x69 is instantly fatal
        // with no live debugger (measured 2026-08-30: crash right after
        // custom-env init when this re-attach step was skipped).  So when
        // launchJVM would enter the JIT26 path and no debugger is live,
        // re-attach the Universal script via stikjit:// first, then launch.
        // NOTE: this intentionally does NOT reuse isJITEnabled() -- that
        // reports the persistent CS_DEBUGGED state, not debugger liveness.
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
            !JIT26IsLikelyDebuggerKeepAttached() &&
            !getPrefBool(@"debug.jit26_script_disable")) {
            NSLog(@"[JIT] [RightPanel] CS_DEBUGGED set but no live JIT26 debugger (ppid=%d traced=%d exn=%d) — re-attaching script via stikjit://",
                  getppid(), JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            // Task172：重挂逻辑抽取为共用助手（本分支 + 等待成功后的存活性
            // 复查两处调用，见 ame172_reattachJIT26ThenLaunch）。
            [self ame172_reattachJIT26ThenLaunch:handler];
            return;
        }
        NSLog(@"[JIT] [RightPanel] JIT enabled with live JIT26 debugger, launching game directly");
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        // Task185：TrollStore 分支回执检查（他人装机反馈“巨魔 JIT 启动游戏
        // 没有任何反应”）。旧代码 completionHandler:nil——apple-magnifier://
        // 无人处理时（TrollStore 版本过旧/助手异常）完全静默，只能盲等
        // 120s 超时。现在失败即时弹指引（Task176 stikjit:// 同款）。
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:^(BOOL ame185_ok) {
            NSLog(@"[JIT] [RightPanel] Task185 openURL apple-magnifier:// -> %d", ame185_ok);
            if (!ame185_ok) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    showDialog(localize(@"Error", nil), @"apple-magnifier:// 无响应（TrollStore JIT 助手未接管，常见于 TrollStore 版本过旧）。请更新 TrollStore，或在设置的 JIT 开启工具改用 stikjit / SideStore / StosDebug 后重试。\napple-magnifier:// not handled. Update TrollStore or switch the JIT enabler in Settings.");
                });
            }
        }];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else {
        // ---- Task 134：JIT 开启工具分发（LiveContainer 多工具方案） ----
        // 病历：用户没装 StikDebug 而用 SideStore/StosDebug/JITStreamer 等
        // 其它工具时，固定跳 stikjit:// 等于"点了没反应"，JIT 永远开不了。
        // 现按 debug.jit_enabler 偏好分发；auto = 原自动判定（TrollStore 检测
        // → apple-magnifier；iOS>=17.4 → stikjit；16.7-17.3.1 → sidestore）。
        // debug.jit26_script_disable（用户点名）：关闭后 stikjit:// 请求不再
        // 附带 UniversalJIT26.js 的 script-data（纯调试器附加式 JIT）。
        NSString *ame134_enabler = getPrefObject(@"debug.jit_enabler");
        if (![ame134_enabler isKindOfClass:NSString.class] || ame134_enabler.length == 0) {
            ame134_enabler = @"auto";
        }
        BOOL ame134_noScript = getPrefBool(@"debug.jit26_script_disable");
        NSString *ame134_bundleId = NSBundle.mainBundle.bundleIdentifier;
        NSLog(@"[JIT] [RightPanel] Task134 enabler=%@ noScript=%d", ame134_enabler, ame134_noScript);

        if ([ame134_enabler isEqualToString:@"manual"]) {
            // 手动：不跳任何工具，等用户自己附加调试器（显示等待弹窗）
        } else if ([ame134_enabler isEqualToString:@"trollstore"]) {
            [self ame185_openJITEnablerURL:[NSURL URLWithString:
                [NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", ame134_bundleId]]
                toolLabel:@"apple-magnifier://"];
        } else if ([ame134_enabler isEqualToString:@"sidestore"]) {
            // SideStore 官方 scheme（LiveContainer 同款）
            [self ame185_openJITEnablerURL:[NSURL URLWithString:
                [NSString stringWithFormat:@"sidestore://enable-jit?bundle-id=%@", ame134_bundleId]]
                toolLabel:@"sidestore://"];
        } else if ([ame134_enabler isEqualToString:@"stosdebug"]) {
            NSString *ame134_appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Amethyst";
            NSMutableString *ame134_url = [NSMutableString stringWithFormat:
                @"stosdebug://enableJIT?bundleId=%@&appName=%@", ame134_bundleId, ame134_appName];
            if (!ame134_noScript) {
                NSData *ame134_script = [NSData dataWithContentsOfFile:
                    [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                if (ame134_script) {
                    [ame134_url appendFormat:@"&script=%@", [ame134_script base64EncodedStringWithOptions:0]];
                }
            }
            [self ame185_openJITEnablerURL:[NSURL URLWithString:ame134_url] toolLabel:@"stosdebug://"];
        } else if ([ame134_enabler isEqualToString:@"jitstreamer"]) {
            // JitStreamer-EB：默认 WireGuard 本地地址（LiveContainer 同款
            // 默认值 http://[fd00::]:9172），浏览器打开 launch_app 接口
            [self ame185_openJITEnablerURL:[NSURL URLWithString:
                [NSString stringWithFormat:@"http://[fd00::]:9172/launch_app/%@", ame134_bundleId]]
                toolLabel:@"jitstreamer"];
        } else if (@available(iOS 17.4, *)) {
            // auto / stikjit 共用 stikjit://（显式选择时无视系统版本）
            NSString *scriptDataString = @"";
            if (!ame134_noScript &&
                ([ame134_enabler isEqualToString:@"stikjit"] ||
                 DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM))) {
                NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
            }
            // Task176：openURL 结果取证 + 无处理器即时指引（不盲等 120s）。
            NSURL *ame176_jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]];
            [UIApplication.sharedApplication openURL:ame176_jitURL options:@{} completionHandler:^(BOOL ame176_ok) {
                NSLog(@"[JIT] [RightPanel] Task176 openURL stikjit:// -> %d", ame176_ok);
                if (!ame176_ok) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        showDialog(localize(@"Error", nil), @"stikjit:// 无响应（未安装 StikDebug？）。请在设置的 JIT 开启工具改用 SideStore/StosDebug/JITStreamer，或安装 StikDebug 后重试。");
                    });
                }
            }];
        } else {
            // Assuming 16.7-17.3.1. SideStore still lacks this URL scheme at the time of writing, so it only jumps to SideStore.
            [self ame185_openJITEnablerURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]]
                toolLabel:@"sidestore://sidejit-enable"];
        }
    }
    
    self.progressLabel.text = localize(@"i18n_str_436", nil);
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:hasTrollStoreJIT ? localize(@"i18n_str_2054", nil) : localize(@"i18n_str_439", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    // ★ Task223（“版本设置启动游戏，JIT 有概率卡死”根修层 1/2）：进度型弹窗
    //   无动画呈现——stikjit:// 切后台转场瞬间的 animated present 是主线程
    //   楔死头号嫌疑类（同 NavCtrl 病历注释）。
    [self presentViewController:alert animated:NO completion:nil];
    
    // Task172：后台任务断言。stikjit:// 必然把 App 切到后台（切去 StikJIT），
    // 无断言时 iOS 立即挂起本进程——760c07c 装机日志实锤等待循环被冻结
    //（"still waiting after 0s" 后零心跳零超时，App 停在后台直到用户手动
    // 切回）。断言让进程在宽限期内继续运行：StikJIT 可在后台完成附加，
    // 心跳/超时日志照常输出，切回失败时超时重试弹窗也能照常出现。
    __block UIBackgroundTaskIdentifier ame172_bgt = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ame172-jit-wait" expirationHandler:^{
        // 宽限期到由系统挂起；恢复后循环按剩余预算继续（NSDate 计时包含
        // 挂起时长，超时语义不变）。
    }];
    // Task179：断言有效性取证。latestlog.2 病历里心跳只打了 0s 一条就冻结
    // ——断言是否真的被系统批准无从分辨（Invalid = 无后台宽限，挂起来得更
    // 早）。无效断言 + Task179 的挂起间隙豁免双保险：即便立即挂起，恢复后
    // 预算也不被墙钟烧穿。
    // Task181（取证可读性修正）：backgroundTimeRemaining 在前台无后台任务时
    // 返回 DBL_MAX（≈1.8e308）——上一轮装机日志里那串 300 位数字是它的本来
    // 面目，不是溢出 bug（UIKit 契约）。打印时归一为 "fg(n/a)" 免再吓人。
    double ame181_bgTime = [UIApplication.sharedApplication backgroundTimeRemaining];
    NSLog(@"[JIT] [RightPanel] Task179 background task assertion: id=%lu valid=%d (remaining bg time %@)",
          (unsigned long)ame172_bgt, ame172_bgt != UIBackgroundTaskInvalid,
          (ame181_bgTime > 1e300) ? @"fg(n/a)" : [NSString stringWithFormat:@"%.0fs", ame181_bgTime]);
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Task169：有界等待（120s）+每 10s 心跳日志。旧裸循环在 stikjit://
        // 偶发没开成 JIT 时永不退出（装机 485b18c：冷启动首次启动卡在
        // 启动器界面，只能杀进程）。超时后撤弹窗并给出重试/取消。
        BOOL ok = ame169_waitForJITCondition(^{ return isJITEnabled(false); }, 120.0, @"isJITEnabled");
        // Task185：自愈式派发（11e4b63 装机 latestlog.2 病历：condition
        // satisfied 后旧 dispatch_async(main) 续接块在后台被楔死的主队列上
        // 永不执行，Task183 锚点缺失即卡死——见 utils.h
        // ame185_dispatchToMainSelfHealing 病历注释）。捕获的 alert/bgt
        // 随块存活到送达，endBackgroundTask/dismiss 在迟到送达时仍正确执行。
        ame185_dispatchToMainSelfHealing(^{
            // Task183（断点钉死锚点）：59d4b48 装机 latestlog.1 病历——
            // condition satisfied 之后主队列续接块静默丢失（连 TouchController
            // 首日志都没出）。本行+后续每步锚点让下轮日志直接定位卡点。
            NSLog(@"[JIT] [RightPanel] Task183 wait-completed block entered on main (ok=%d)", ok);
            if (ame172_bgt != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:ame172_bgt];
                ame172_bgt = UIBackgroundTaskInvalid;
            }
            if (ok) {
                // Task182：成功路径不再依赖 dismiss 的 completion。病历
                //（bc1941b 装机 latestlog.1）：stikjit:// 把 App 切后台、UIKit
                // 暂停动画，present 动画未完成的 alert 上调 dismiss 是 no-op，
                // completion 【永不回调】——Task181 三针实锤 condition
                // satisfied 之后零后续日志、且全程无 returned-to-FOREGROUND
                //（用户始终没切回前台也能成局：后台断言让等待循环活着），
                // handler 就此丢失 = 用户实测的"二级菜单启动卡死"。对照组
                // latestlog.2：用户先切回前台（alert 完成呈现）再满足，同一
                // 份 completion 正常触发、游戏正常启动。修法：completion:nil
                // + 同步直接执行后续链（dismiss 本身对未完成呈现是安全的）。
                [alert dismissViewControllerAnimated:YES completion:nil];
                // Task172：等待成功 ≠ 能安全启动。StikJIT 在我们被挂起
                // 期间附加又死亡时，CS_DEBUGGED 已置而 JIT26 调试器无人
                // 服务 brk #0x69 —— 旧代码直接跑 handler 即用户实测的
                // "二级菜单启动卡 JIT 等待 120s 后闪退"。与入口
                // CS_DEBUGGED 分支同款存活性复查：需要重挂就重挂。
                if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM) &&
                    !JIT26IsLikelyDebuggerKeepAttached() &&
                    !getPrefBool(@"debug.jit26_script_disable")) {
                    NSLog(@"[JIT] [RightPanel] Task172 wait satisfied but JIT26 debugger is gone — re-attaching before launch");
                    [self ame172_reattachJIT26ThenLaunch:handler];
                } else {
                    NSLog(@"[JIT] [RightPanel] Task183 invoking launch handler");
                    handler();
                }
            } else {
                // Task182：同上——超时路径的 retry 弹窗也不再包进 dismiss
                // completion（后台态同样悬空），直接呈现。
                [alert dismissViewControllerAnimated:YES completion:nil];
                // ★ Task226（反馈 #4：版本设置启动偶发"JIT 未响应"）：
                // 间歇性失败的形态 = stikjit:// 拉起竞争（StikJIT 自身冷启动
                // 时 URL 无人接住，openURL 回执 ok 但附加没发生）。旧逻辑
                // 直接弹超时对话框，用户手动点重试才恢复。改为静默自动
                // 重拉一次 enabler URL + 续一轮等待预算——只有第二轮也
                // 超时才真正打扰用户。
                if (!self.ame226_jitAutoRetried) {
                    self.ame226_jitAutoRetried = YES;
                    NSLog(@"[JIT] [RightPanel] Task226 wait timed out -- AUTO-RETRY: re-firing enabler URL once before alerting");
                    [self invokeAfterJITEnabled:handler];
                    return;
                }
                self.ame226_jitAutoRetried = NO;
                [self ame169_showJITTimeoutAlertWithRetry:handler];
            }
        }, @"RightPanel main wait");
    });
}

/// Task185：JIT 开启工具 URL 统一拉起（回执取证 + 失败即时指引，Task176
/// stikjit:// 同款）。旧代码五个分支全部 completionHandler:nil——URL 无人
/// 处理时完全静默（他人装机反馈“巨魔 JIT 启动游戏没有任何反应”的形态
/// 之一），只能盲等 120s 超时。
- (void)ame185_openJITEnablerURL:(NSURL *)url toolLabel:(NSString *)tool {
    if (!url) {
        NSLog(@"[JIT] [RightPanel] Task185 openURL skipped: nil URL (tool=%@)", tool);
        return;
    }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL ok) {
        NSLog(@"[JIT] [RightPanel] Task185 openURL %@ -> %d", tool, ok);
        if (!ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"ame193.misc.jit_not_handled", @"%@ 未接管启动请求（未安装或版本过旧？）。请在设置的 JIT 开启工具中换用其它工具后重试。"), tool]);
            });
        }
    }];
}

/// Task169：JIT 等待超时后的出路弹窗（重试 = 重新走一轮 invokeAfterJITEnabled，
/// 会重新拉起 stikjit://；取消 = 回到启动器，用户可手动附加调试器后重试）。
- (void)ame169_showJITTimeoutAlertWithRetry:(void(^)(void))handler {
    NSLog(@"[JIT] [RightPanel] Task169 JIT wait timed out, showing retry alert");
    UIAlertController *retry = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:localize(@"ame189.jit.timeout_msg", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [retry addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [retry addAction:[UIAlertAction actionWithTitle:localize(@"ame189.jit.retry", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self invokeAfterJITEnabled:handler];
    }]];
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        retry.popoverPresentationController.sourceView = self.view;
        retry.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
    }
    [self presentViewController:retry animated:YES completion:nil];
}

// Task172：JIT26 调试器重挂统一助手（stikjit:// + 有界等待 + 前台等待 +
// 后台任务断言）。原为 invokeAfterJITEnabled 的 CS_DEBUGGED 分支内联代码，
// 现另供等待成功后的存活性复查使用（两处语义一致：拉起 StikJIT 带脚本
// 重附加，等调试器真正存活后才执行 handler）。
// 病历（760c07c 装机 latestlog.txt）：stikjit:// 切后台后若 StikJIT 没把
// 用户带回来，App 被挂起、循环冻结（零心跳）；用户手动切回时若
// CS_DEBUGGED 已置而调试器已死，直接启动 → brk #0x69 无人服务 = 闪退。
// 助手三道防线：①App 非激活态先等前台（openURL 后台无效，一次性监听 +
// 10s 兜底，双 nil 防护防双发）；②拉起 stikjit://（附 UniversalJIT26.js）；
// ③断言防挂起冻结 + 有界等调试器存活，超时走重试弹窗。
- (void)ame172_reattachJIT26ThenLaunch:(void(^)(void))handler {
    self.progressLabel.text = localize(@"i18n_str_436", nil);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_437", nil)
                                                                   message:localize(@"i18n_str_439", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:NO  /* Task223: JIT progress alert presented un-animated (background-transition present is the main-thread wedge suspect) */ completion:nil];
    
    __block UIBackgroundTaskIdentifier ame172_bgt = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"ame172-jit26-reattach" expirationHandler:^{
        // 同上：宽限期到由系统挂起，恢复后继续。
    }];
    
    void (^ame172_fireURL)(void) = ^{
        NSString *scriptDataString = @"";
        NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
        if (scriptData) {
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:^(BOOL ame185_ok) {
            // Task185：回执取证（重挂场景已有等待弹窗 + 超时重试兑底，失败只记日志）
            NSLog(@"[JIT] [RightPanel] Task185 re-attach stikjit:// -> %d", ame185_ok);
        }];
        NSLog(@"[JIT] [RightPanel] Task172 stikjit:// re-attach fired (script=%lu bytes)",
              (unsigned long)scriptData.length);
    };
    
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        // 后台态：openURL 无效，先等回前台再拉起（一次性监听 + 10s 兜底，
        // 双 nil 防护防双发）。
        __block id ame172_obs = nil;
        ame172_obs = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *ame172_n) {
            [[NSNotificationCenter defaultCenter] removeObserver:ame172_obs];
            ame172_obs = nil;
            ame172_fireURL();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (ame172_obs) {
                [[NSNotificationCenter defaultCenter] removeObserver:ame172_obs];
                ame172_obs = nil;
                ame172_fireURL();
            }
        });
    } else {
        ame172_fireURL();
    }
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Wait for the JIT26 debugger to actually attach (P_TRACED /
        // exception ports / spawned-by-debugger), not for CS_DEBUGGED
        // -- that flag is already set and would race the first brk.
        // Task169：有界等待（120s）+心跳日志，超时走重试弹窗。
        BOOL ok = ame169_waitForJITCondition(^{ return JIT26IsLikelyDebuggerKeepAttached(); }, 120.0, @"JIT26 debugger attach");
        // Task185：自愈式派发（同主等待路径，病历见 utils.h）。
        ame185_dispatchToMainSelfHealing(^{
            if (ame172_bgt != UIBackgroundTaskInvalid) {
                [UIApplication.sharedApplication endBackgroundTask:ame172_bgt];
                ame172_bgt = UIBackgroundTaskInvalid;
            }
            if (ok) {
                // Task182：同主等待路径——后台态 dismiss completion 悬空风险，
                // completion:nil + 直接执行（reattach 场景 App 同样常在后台）。
                [alert dismissViewControllerAnimated:YES completion:nil];
                if (handler) handler();
            } else {
                [alert dismissViewControllerAnimated:YES completion:nil];
                [self ame169_showJITTimeoutAlertWithRetry:handler];
            }
        }, @"RightPanel reattach wait");
    });
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Data Updates

- (void)updateAccountInfo {
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    if (currentAuth && currentAuth.authData) {
        NSString *username = currentAuth.authData[@"username"];
        if (username) {
            if ([username hasPrefix:@"Demo."]) {
                username = [username substringFromIndex:5];
            }
            self.usernameLabel.text = username;
        }

        // 加载头像：本地自定义头像优先，回退到在线 URL
        // 头像文件名使用 accountId（唯一标识），同名账户头像不再冲突
        // Task169：在线回退换 AvatarManager fetchAvatarFromURL（10s 超时 +
        // 磁盘缓存 + 失败日志），替换裸 dataWithContentsOfURL（60s 挂起、
        // 失败静默——主页头像"点一下才有"同源病灶）。
        // Task180：查询加 username 回退（防御性修复"右侧栏头像未显示"：
        // 历史 username 文件名 / 账号 ID 漂移后的旧文件仍可命中）
        UIImage *localAvatar = [[AvatarManager sharedManager]
            avatarForAccount:currentAuth.authData[@"accountId"]
            usernameFallback:currentAuth.authData[@"username"]];
        if (localAvatar) {
            self.avatarImageView.image = localAvatar;
        } else {
            // Task185：换带账号上下文的头像获取链（profilePicURL → crafatar
            // UUID → minotar username 三层回退）。病历：他人装机日志实锤
            // 单一镜像 api.rms.net.cn DNS 失效时正版账号头像全灭，且首登
            // 顺序 bug 存下的 "head/(null)" 脏 URL 会永远拉失败。
            [[AvatarManager sharedManager] ame185_fetchAvatarForAuthData:currentAuth.authData completion:^(UIImage *image) {
                if (!image) {
                    NSLog(@"[Task180] RightPanel avatar chain exhausted (accountId=%@)",
                          currentAuth.authData[@"accountId"]);
                }
                self.avatarImageView.image = image ?: [UIImage systemImageNamed:@"person.circle.fill"];
            }];
        }
    } else {
        self.usernameLabel.text = localize(@"i18n_str_357", nil);
        self.avatarImageView.image = [UIImage systemImageNamed:@"person.circle.fill"];
    }

    [self updateLaunchButtonState];

    // FCL 风格：若用户从"启动游戏"进来登录（pendingLaunchAfterLogin=YES），
    // 且账号已就绪，自动继续启动游戏。
    if (self.pendingLaunchAfterLogin && BaseAuthenticator.current != nil) {
        self.pendingLaunchAfterLogin = NO;
        [self launchGame];
    }
}

- (void)updateVersionInfo {
    NSString *selectedProfile = PLProfiles.current.selectedProfileName;
    if (selectedProfile) {
        NSDictionary *profile = PLProfiles.current.profiles[selectedProfile];
        if (profile) {
            NSString *versionId = profile[@"lastVersionId"] ?: @"unknown";
            // Task96：游戏版本卡显示当前选择实例版本号（不带隔离后缀）。
            // Task101：原灰字版本标签退场后，这里是该数据的唯一展示出口。
            self.gameVersionCardValue.text = versionId;
        }
    } else {
        self.gameVersionCardValue.text = localize(@"ame189.rp.not_selected", nil);
    }

    [self updateLaunchButtonState];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}

@end