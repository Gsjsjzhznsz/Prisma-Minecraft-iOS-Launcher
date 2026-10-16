#import "PLCrashView.h"
#import "PLLogOutputView.h"
#import "SurfaceViewController.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "BackgroundManager.h"
#import "CrashAnalyzer.h"

@interface PLCrashView ()
// 数据
@property (nonatomic, assign) int exitCode;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *customReason;

// 崩溃类型分析（参照 HMCL 的崩溃分析器，提供更精确的崩溃分类和建议）
typedef NS_ENUM(NSInteger, CrashType) {
    CrashTypeNormal = 0,         // 正常退出
    CrashTypeOOM,                // 内存不足
    CrashTypeSegfault,           // 段错误（JNI/原生库）
    CrashTypeAbort,              // 程序异常终止
    CrashTypeTerminated,         // 被外部信号终止
    CrashTypeModConflict,        // Mod 冲突
    CrashTypeMissingLibrary,     // 缺失库文件
    CrashTypeMissingMods,        // Task 95：整合包缺失 mod 文件（entrypoint 阶段类加载失败）
    CrashTypeJavaVersionMismatch,// Java 版本不匹配
    CrashTypeRendererError,      // 渲染器错误
    CrashTypeModLoadingFailure,  // Mod 加载失败
    CrashTypeModIncompatible,    // ★ Task263：Mod 版本不兼容（Fabric FormattedException 实证块）
    CrashTypeJavaException,      // Java 异常
    CrashTypeUnknown             // 未知错误
};
@property (nonatomic, assign) CrashType crashType;
@property (nonatomic, strong, nullable) NSString *crashDetail; // 崩溃详情（从日志提取的关键行）
// ★ Task267：Prisma 自研 CrashAnalyzer 的 hs_err 结构化分型接入
//   （analyzeHsErrFile: 的返回字典：signal/isOOM/blamedRenderer/
//   problematicFrame/nativeFrames）。此前本页只把 hs_err 头 4KB 当
//   文本证据展示，丢掉了分型结果——"没有我们项目的详细错误分析器"
//   的核心缺口。analyzeCrashType 末尾融合（详见 ame267_refineWithHsErr）。
@property (nonatomic, strong, nullable) NSDictionary *ame267_hsErr;
// Task 95：缺失 mod 崩溃的解析产物（供建议卡片精确点名）
@property (nonatomic, strong, nullable) NSArray<NSString *> *ame95_missingModNames; // 推断的缺失 mod/库名单
@property (nonatomic, copy, nullable) NSString *ame95_overriddenEvidence;           // "Dependencies overridden for ..." 证据行（可为空）
// ★ Task263：Fabric 不兼容解析产物（FormattedException 的用户向方案行，
//   例：" - Replace mod 'Sodium' (sodium) 0.9.3-alpha.1+mc26.3 with version 0.9.2+mc26.3."）
@property (nonatomic, copy, nullable) NSString *ame263_incompatSummary;

// UI 组件
@property (nonatomic, strong) UIScrollView *mainScrollView;
@property (nonatomic, strong) UIStackView *mainStackView;
@property (nonatomic, strong) UIView *errorCardView;
@property (nonatomic, strong) UIImageView *errorIconView;
@property (nonatomic, strong) UILabel *errorTitleLabel;
@property (nonatomic, strong) UILabel *errorCodeLabel;
@property (nonatomic, strong) UILabel *reasonLabel;
@property (nonatomic, strong) UILabel *oomSuggestionLabel;
// 快速修复建议卡片（参照 FCL/HMCL 的"快速修复"面板）
@property (nonatomic, strong) UIView *suggestionsCardView;
@property (nonatomic, strong) UILabel *suggestionsTitleLabel;
@property (nonatomic, strong) UIStackView *suggestionsStackView;
@property (nonatomic, strong) UIView *logCardView;
@property (nonatomic, strong) UILabel *logTitleLabel;
@property (nonatomic, strong) UITextView *logTextView;
@property (nonatomic, strong) UILabel *logPlaceholderLabel;
@property (nonatomic, strong) UIButton *restartButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIButton *githubButton;
@property (nonatomic, strong) UIButton *fullLogButton;
@property (nonatomic, strong) UIButton *exitButton;
// 错误卡片顶部红色 accent 条
@property (nonatomic, strong) CAGradientLayer *accentGradientLayer;
// 建议卡片顶部黄色 accent 条
@property (nonatomic, strong) CAGradientLayer *suggestionAccentLayer;
// 日志卡片高度约束（根据屏幕高度动态调整）
@property (nonatomic, strong) NSLayoutConstraint *logCardHeightConstraint;
// ★ Task263：日志卡展开态（查看日志详情 ↔ 收起日志；展开时高度控制权
//   从 viewDidLayoutSubviews 移交给 ame263_applyLogExpansion）
@property (nonatomic, assign) BOOL ame263_logExpanded;
@end

@implementation PLCrashView

// 当前正在显示的崩溃 VC 实例（单例）
static PLCrashView *currentCrashVC = nil;
// ★ Task267（用户："崩溃界面还是上游的分析"）：反馈出口从上游 Amethyst
//   仓库改指本仓库——用户点"前往 GitHub Issues"应到 Prisma 的 issue 区。
static NSString *const kGitHubIssuesURL = @"https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/issues";

/// ★ Task274-g（G5）：L2 崩溃界面呈现成功即消费 ame273_crash_report.txt（改名
/// 归档 seen-<epoch>.txt）——否则下次启动 L3 会补弹同一崩溃（L2 已把原因展示过）。
/// NSFileManager 自包含实现，不动 main_hook/utils（归并行代理）。仅在 L2 呈现
/// 成功路径调用；L2 未呈现（keyWindow 缺失/提前被杀）不调用，报告保持原文件名
/// 在盘，下次启动由 SceneDelegate L3 补弹（Task273 旗标协议语义不变）。
static void ame274_archiveCrashReportAfterL2Present(void) {
    @try {
        NSString *home = [NSProcessInfo processInfo].environment[@"POJAV_HOME"];
        if (home.length == 0) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *path = [home stringByAppendingPathComponent:@"ame273_crash_report.txt"];
        if (![fm fileExistsAtPath:path]) return;
        NSString *archive = [home stringByAppendingPathComponent:
            [NSString stringWithFormat:@"ame273_crash_report.seen-%.0f.txt",
             [NSDate date].timeIntervalSince1970]];
        [fm removeItemAtPath:archive error:nil];
        NSError *moveError = nil;
        if ([fm moveItemAtPath:path toPath:archive error:&moveError]) {
            NSLog(@"[PLCrashView] Task274: L2 presented -> crash report archived as %@ (next-launch L3 will not re-pop)", archive.lastPathComponent);
        } else {
            NSLog(@"[PLCrashView] Task274: crash report archive failed (%@) -- kept on disk for next-launch L3", moveError.localizedDescription);
        }
        // ★ Task275（P3-b9）：归档保留最近 5 份——每次 L2 呈现都新增
        // seen-<epoch>.txt 且无清理方，无限累积（Cleanup 不覆盖该前缀）。
        NSArray *ame275_seen = [fm contentsOfDirectoryAtPath:home error:nil];
        NSMutableArray<NSString *> *ame275_archives = [NSMutableArray array];
        for (NSString *ame275_n in ame275_seen) {
            if ([ame275_n hasPrefix:@"ame273_crash_report.seen-"]) [ame275_archives addObject:ame275_n];
        }
        if (ame275_archives.count > 5) {
            [ame275_archives sortUsingSelector:@selector(localizedStandardCompare:)];
            for (NSUInteger ame275_i = 0; ame275_i < ame275_archives.count - 5; ame275_i++) {
                [fm removeItemAtPath:[home stringByAppendingPathComponent:ame275_archives[ame275_i]] error:nil];
            }
            NSLog(@"[PLCrashView] Task275: crash report archives trimmed to newest 5 (was %lu)", (unsigned long)ame275_archives.count);
        }
    } @catch (NSException *ame274_e) {
        NSLog(@"[PLCrashView] Task274: crash report archive exception: %@", ame274_e);
    }
}

#pragma mark - Public Methods

+ (void)showWithExitCode:(int)exitCode {
    [self showWithExitCode:exitCode customTitle:nil customReason:nil];
}

+ (void)showWithExitCode:(int)exitCode customTitle:(NSString *)customTitle customReason:(NSString *)customReason {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 如果已经存在崩溃界面，先 dismiss，避免叠加
        if (currentCrashVC) {
            [currentCrashVC dismissViewControllerAnimated:NO completion:nil];
            currentCrashVC = nil;
        }

        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive ||
                    scene.activationState == UISceneActivationStateForegroundInactive) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    for (UIWindow *window in windowScene.windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                    if (keyWindow) break;
                }
            }
        }

        if (!keyWindow) return;

        // 找到最顶层的 presented VC 来 present 崩溃界面。
        // 旧实现把 UIView 直接 addSubview 到 keyWindow，存在生命周期无人管理、
        // 旋转/安全区不跟随等问题。改为 UIViewController 后由系统管理生命周期。
        UIViewController *rootVC = keyWindow.rootViewController;
        while (rootVC.presentedViewController) {
            rootVC = rootVC.presentedViewController;
        }

        PLCrashView *crashVC = [[PLCrashView alloc] init];
        crashVC.exitCode = exitCode;
        crashVC.customTitle = customTitle;
        crashVC.customReason = customReason;
        crashVC.modalPresentationStyle = UIModalPresentationOverFullScreen;
        crashVC.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;

        currentCrashVC = crashVC;
        [rootVC presentViewController:crashVC animated:NO completion:nil];
        // ★ Task273：呈现成功握手 —— Ame251 看门狗据此从"150ms 抢杀"切换到
        //   让路窗口（≤8s 等本呈现 + 呈现后 ≤120s 等用户读完），HMCL 式崩溃
        //   分析首次真正有机会展示（装机 f71c88b：看门狗 150ms _exit 抢杀 =
        //   "启动器直接闪退"病灶）。
        ame273_crashViewDidPresent();
        // ★ Task274-g（G5）：呈现成功即消费报告文件（归档改名）——L2 已把崩溃
        //   原因展示给用户，报告留盘会让下次启动 L3 补弹同一崩溃。
        ame274_archiveCrashReportAfterL2Present();
    });
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _exitCode = 0;
        _customTitle = nil;
        _customReason = nil;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    [self setupBackground];
    // 先分析崩溃类型，setupUI 中的建议卡片依赖此结果
    [self analyzeCrashType];
    [self setupUI];
    [self loadLogContent];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 根据屏幕高度动态调整日志卡片高度，避免小屏挤压按钮或大屏浪费空间
    // ★ Task263：展开态由 ame263_applyLogExpansion 独占高度控制权，
    //   布局回写不再覆盖（否则一布局展开态就被打回定高）。
    if (!self.ame263_logExpanded) {
        [self adjustLogCardHeight];
    }
    // 更新错误卡片顶部红色 accent 条的 frame
    if (_accentGradientLayer) {
        _accentGradientLayer.frame = CGRectMake(0, 0, _errorCardView.bounds.size.width, 2);
    }
    // 更新建议卡片顶部黄色 accent 条的 frame
    if (_suggestionAccentLayer && _suggestionsCardView) {
        _suggestionAccentLayer.frame = CGRectMake(0, 0, _suggestionsCardView.bounds.size.width, 2);
    }
}

#pragma mark - Background

- (void)setupBackground {
    // 适配自定义背景壁纸：让 BackgroundManager 的全局背景透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.view.backgroundColor = [UIColor clearColor];

    // 如果没有自定义背景，使用系统材质毛玻璃作为回退（自适应深浅色）
    if (![[BackgroundManager sharedManager] hasBackground]) {
        UIBlurEffect *blurEffect;
        if (@available(iOS 13.0, *)) {
            blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        } else {
            blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
        }
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
        blurView.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:blurView];
        [self.view sendSubviewToBack:blurView];

        [NSLayoutConstraint activateConstraints:@[
            [blurView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
            [blurView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
            [blurView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [blurView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        ]];
    }
}

#pragma mark - UI Setup

- (void)setupUI {
    // ============================================================
    // FCL 风格崩溃界面：左边大日志框 + 右边按钮列
    // ============================================================
    // 参照 FCL (FoldCraftLauncher) 的崩溃界面布局：
    //   - 顶部：简洁的错误信息卡片（图标 + 标题 + 错误代码）
    //   - 下方水平分栏：
    //     - 左侧（占 65% 宽度）：大日志文本框，显示崩溃日志内容
    //     - 右侧（占 35% 宽度）：垂直排列的按钮列
    //       - 重启启动器（蓝色强调）
    //       - 退出启动器（退出进程，不重启）
    //       - 分享日志
    //       - 前往 GitHub Issues
    //       - 查看完整日志
    //
    // 关键修复：之前"重启启动器"和"退出启动器"按钮功能相同
    // （都是返回启动器主界面），现在明确区分：
    //   - 重启启动器：exit(0) + openURL 拉起应用（重启整个启动器）
    //   - 退出启动器：exit(0) 直接退出进程（不重启）

    // 主滚动视图（内容超出屏幕时可滚动）
    _mainScrollView = [[UIScrollView alloc] init];
    _mainScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    _mainScrollView.alwaysBounceVertical = YES;
    _mainScrollView.showsVerticalScrollIndicator = YES;
    _mainScrollView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    _mainScrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self.view addSubview:_mainScrollView];

    // 主垂直 StackView（错误卡片 + 水平分栏）
    _mainStackView = [[UIStackView alloc] init];
    _mainStackView.axis = UILayoutConstraintAxisVertical;
    _mainStackView.spacing = 16;
    _mainStackView.alignment = UIStackViewAlignmentFill;
    _mainStackView.distribution = UIStackViewDistributionFill;
    _mainStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainScrollView addSubview:_mainStackView];

    [NSLayoutConstraint activateConstraints:@[
        [_mainScrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:16],
        [_mainScrollView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [_mainScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_mainScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_mainStackView.topAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.topAnchor],
        [_mainStackView.bottomAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.bottomAnchor],
        [_mainStackView.leadingAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.leadingAnchor],
        [_mainStackView.trailingAnchor constraintEqualToAnchor:_mainScrollView.contentLayoutGuide.trailingAnchor],
        [_mainStackView.widthAnchor constraintEqualToAnchor:_mainScrollView.frameLayoutGuide.widthAnchor],
    ]];

    // StackView 左右留白
    _mainStackView.layoutMargins = UIEdgeInsetsMake(16, 20, 16, 20);
    _mainStackView.layoutMarginsRelativeArrangement = YES;

    // 1. 错误信息卡片（顶部）
    [self setupErrorCard];

    // 2. 快速修复建议卡片（可选，有建议时才显示）
    [self setupSuggestionsCard];

    // 3. 水平分栏容器：左日志 + 右按钮
    UIStackView *horizontalSplit = [[UIStackView alloc] init];
    horizontalSplit.axis = UILayoutConstraintAxisHorizontal;
    horizontalSplit.spacing = 12;
    horizontalSplit.alignment = UIStackViewAlignmentFill;
    horizontalSplit.distribution = UIStackViewDistributionFill;
    horizontalSplit.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:horizontalSplit];

    // 3a. 左侧：日志卡片
    [self setupLogCard];
    // 将日志卡片添加到水平分栏的左侧
    [horizontalSplit addArrangedSubview:_logCardView];

    // 3b. 右侧：按钮列容器
    UIStackView *buttonColumn = [[UIStackView alloc] init];
    buttonColumn.axis = UILayoutConstraintAxisVertical;
    buttonColumn.spacing = 10;
    buttonColumn.alignment = UIStackViewAlignmentFill;
    buttonColumn.distribution = UIStackViewDistributionFillEqually;
    buttonColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [horizontalSplit addArrangedSubview:buttonColumn];

    // 设置左侧日志卡片占据约 65% 宽度，右侧按钮列占据约 35%
    NSLayoutConstraint *logWidthConstraint = [_logCardView.widthAnchor constraintEqualToAnchor:horizontalSplit.widthAnchor multiplier:0.65];
    logWidthConstraint.priority = UILayoutPriorityDefaultHigh;
    logWidthConstraint.active = YES;

    // 按钮列最小宽度（确保按钮文字不被截断）
    [buttonColumn.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;

    // 4. 创建按钮并添加到右侧按钮列
    [self setupButtonsIntoContainer:buttonColumn];
}

- (void)setupErrorCard {
    _errorCardView = [[UIView alloc] init];
    _errorCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _errorCardView.layer.cornerRadius = 16;  // Task137：回归原生卡片圆角
    _errorCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _errorCardView.layer.borderWidth = 0.5;
    _errorCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _errorCardView.layer.shadowColor = [UIColor blackColor].CGColor;
    _errorCardView.layer.shadowOffset = CGSizeMake(0, 4);
    _errorCardView.layer.shadowOpacity = 0.12;
    _errorCardView.layer.shadowRadius = 8;
    _errorCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_errorCardView];
    // 应用毛玻璃效果（适配自定义背景壁纸）
    [[BackgroundManager sharedManager] applyEffectToView:_errorCardView];

    // 顶部红色 accent 条（2pt 高的渐变层，从红色到透明）
    _accentGradientLayer = [CAGradientLayer layer];
    _accentGradientLayer.colors = @[
        (__bridge id)[UIColor systemRedColor].CGColor,
        (__bridge id)[[UIColor systemRedColor] colorWithAlphaComponent:0].CGColor,
    ];
    _accentGradientLayer.locations = @[@0.0, @1.0];
    _accentGradientLayer.startPoint = CGPointMake(0.5, 0.0);
    _accentGradientLayer.endPoint = CGPointMake(0.5, 1.0);
    _accentGradientLayer.cornerRadius = 16;
    _accentGradientLayer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [_errorCardView.layer addSublayer:_accentGradientLayer];

    // 错误图标
    _errorIconView = [[UIImageView alloc] init];
    _errorIconView.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightBold];
        _errorIconView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill" withConfiguration:config];
    }
    _errorIconView.tintColor = [UIColor systemRedColor];
    _errorIconView.contentMode = UIViewContentModeScaleAspectFit;
    [_errorCardView addSubview:_errorIconView];

    // 错误标题
    _errorTitleLabel = [[UILabel alloc] init];
    _errorTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorTitleLabel.text = _customTitle ?: localize(@"crash.error_title", nil);
    _errorTitleLabel.font = [UIFont boldSystemFontOfSize:18];
    _errorTitleLabel.textColor = [UIColor labelColor];
    _errorTitleLabel.textAlignment = NSTextAlignmentCenter;
    _errorTitleLabel.numberOfLines = 0;
    [_errorCardView addSubview:_errorTitleLabel];

    // 错误代码
    _errorCodeLabel = [[UILabel alloc] init];
    _errorCodeLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorCodeLabel.text = [NSString stringWithFormat:@"%@%d", localize(@"crash.error_code", nil), _exitCode];
    _errorCodeLabel.font = [UIFont systemFontOfSize:14];
    _errorCodeLabel.textColor = [UIColor secondaryLabelColor];
    _errorCodeLabel.textAlignment = NSTextAlignmentCenter;
    [_errorCardView addSubview:_errorCodeLabel];

    // 可能原因
    _reasonLabel = [[UILabel alloc] init];
    _reasonLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _reasonLabel.text = [self crashReasonText];
    _reasonLabel.font = [UIFont systemFontOfSize:13];
    _reasonLabel.textColor = [UIColor secondaryLabelColor];
    _reasonLabel.textAlignment = NSTextAlignmentCenter;
    _reasonLabel.numberOfLines = 0;
    [_errorCardView addSubview:_reasonLabel];

    // 通用约束（图标/标题/代码/原因）
    NSMutableArray<NSLayoutConstraint *> *constraints = [NSMutableArray arrayWithArray:@[
        [_errorIconView.topAnchor constraintEqualToAnchor:_errorCardView.topAnchor constant:16],
        [_errorIconView.centerXAnchor constraintEqualToAnchor:_errorCardView.centerXAnchor],
        [_errorIconView.widthAnchor constraintEqualToConstant:40],
        [_errorIconView.heightAnchor constraintEqualToConstant:40],

        [_errorTitleLabel.topAnchor constraintEqualToAnchor:_errorIconView.bottomAnchor constant:12],
        [_errorTitleLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_errorTitleLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],

        [_errorCodeLabel.topAnchor constraintEqualToAnchor:_errorTitleLabel.bottomAnchor constant:6],
        [_errorCodeLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_errorCodeLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],

        [_reasonLabel.topAnchor constraintEqualToAnchor:_errorCodeLabel.bottomAnchor constant:6],
        [_reasonLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
        [_reasonLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],
    ]];

    // OOM 崩溃时显示建议标签，errorCardView 底部锚定到 oomSuggestionLabel 底部
    if ([self isOOMCrash]) {
        _oomSuggestionLabel = [[UILabel alloc] init];
        _oomSuggestionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _oomSuggestionLabel.font = [UIFont systemFontOfSize:12];
        _oomSuggestionLabel.textColor = [UIColor secondaryLabelColor];
        _oomSuggestionLabel.textAlignment = NSTextAlignmentCenter;
        _oomSuggestionLabel.numberOfLines = 0;
        NSString *suggestion = [NSString stringWithFormat:@"%@ %@",
                                localize(@"crash.suggestion", @"建议操作"),
                                localize(@"crash.suggestion.oom", @"iOS 内存限制导致崩溃，建议使用 GetMoreRam (LiveContainer) 解除内存限制后重试")];
        _oomSuggestionLabel.text = suggestion;
        [_errorCardView addSubview:_oomSuggestionLabel];

        [constraints addObjectsFromArray:@[
            [_oomSuggestionLabel.topAnchor constraintEqualToAnchor:_reasonLabel.bottomAnchor constant:8],
            [_oomSuggestionLabel.leadingAnchor constraintEqualToAnchor:_errorCardView.leadingAnchor constant:16],
            [_oomSuggestionLabel.trailingAnchor constraintEqualToAnchor:_errorCardView.trailingAnchor constant:-16],
            [_oomSuggestionLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16],
        ]];
    } else {
        // 非 OOM 时，errorCardView 底部直接锚定到 reasonLabel 底部
        [constraints addObject:[_reasonLabel.bottomAnchor constraintEqualToAnchor:_errorCardView.bottomAnchor constant:-16]];
    }

    [NSLayoutConstraint activateConstraints:constraints];
}

#pragma mark - Suggestions Card (快速修复建议卡片)

/// 创建快速修复建议卡片（参照 FCL/HMCL 的"快速修复"面板）
///
/// 根据 analyzeCrashType 分析的崩溃类型，显示对应的修复建议：
/// - OOM: 降低内存分配、移除重量级 Mod、使用 GetMoreRam
/// - Segfault: 切换渲染器、检查原生库兼容性
/// - ModConflict: 移除最近添加的 Mod、检查 Mod 兼容性
/// - MissingLibrary: 重新安装游戏版本、检查库文件
/// - JavaVersionMismatch: 切换 Java 版本
/// - RendererError: 切换渲染器、禁用光影
/// - ModLoadingFailure: 检查 Mod 加载器版本、移除问题 Mod
///
/// 每条建议以一行带图标的文字展示，点击可复制到剪贴板。
- (void)setupSuggestionsCard {
    // 获取当前崩溃类型的建议列表
    NSArray<NSDictionary *> *suggestions = [self suggestionsForCrashType];
    if (suggestions.count == 0) return; // 无建议时不显示卡片

    _suggestionsCardView = [[UIView alloc] init];
    _suggestionsCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    _suggestionsCardView.layer.cornerRadius = 16;  // Task137：回归原生卡片圆角
    _suggestionsCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _suggestionsCardView.layer.borderWidth = 0.5;
    _suggestionsCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _suggestionsCardView.translatesAutoresizingMaskIntoConstraints = NO;
    [_mainStackView addArrangedSubview:_suggestionsCardView];
    // 应用毛玻璃效果（适配自定义背景壁纸）
    [[BackgroundManager sharedManager] applyEffectToView:_suggestionsCardView];

    // 顶部黄色 accent 条（提示性质，非致命错误）
    CAGradientLayer *suggestionAccent = [CAGradientLayer layer];
    suggestionAccent.colors = @[
        (__bridge id)[UIColor systemYellowColor].CGColor,
        (__bridge id)[[UIColor systemYellowColor] colorWithAlphaComponent:0].CGColor,
    ];
    suggestionAccent.locations = @[@0.0, @1.0];
    suggestionAccent.startPoint = CGPointMake(0.5, 0.0);
    suggestionAccent.endPoint = CGPointMake(0.5, 1.0);
    suggestionAccent.cornerRadius = 16;
    suggestionAccent.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    [_suggestionsCardView.layer addSublayer:suggestionAccent];
    self.suggestionAccentLayer = suggestionAccent;
    // accent 条 frame 在 viewDidLayoutSubviews 中设置

    // 标题行：图标 + "快速修复建议"
    UIView *titleRow = [[UIView alloc] init];
    titleRow.translatesAutoresizingMaskIntoConstraints = NO;
    [_suggestionsCardView addSubview:titleRow];

    UIImageView *titleIcon = [[UIImageView alloc] init];
    titleIcon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        titleIcon.image = [UIImage systemImageNamed:@"lightbulb.fill" withConfiguration:config];
    }
    titleIcon.tintColor = [UIColor systemYellowColor];
    titleIcon.contentMode = UIViewContentModeScaleAspectFit;
    [titleRow addSubview:titleIcon];

    _suggestionsTitleLabel = [[UILabel alloc] init];
    _suggestionsTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _suggestionsTitleLabel.text = localize(@"crash.quick_fix", @"快速修复建议");
    _suggestionsTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _suggestionsTitleLabel.textColor = [UIColor labelColor];
    [titleRow addSubview:_suggestionsTitleLabel];

    // 建议列表（垂直 StackView）
    _suggestionsStackView = [[UIStackView alloc] init];
    _suggestionsStackView.axis = UILayoutConstraintAxisVertical;
    _suggestionsStackView.spacing = 8;
    _suggestionsStackView.alignment = UIStackViewAlignmentFill;
    _suggestionsStackView.distribution = UIStackViewDistributionFill;
    _suggestionsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    [_suggestionsCardView addSubview:_suggestionsStackView];

    // 为每条建议创建一行
    for (NSDictionary *suggestion in suggestions) {
        NSString *icon = suggestion[@"icon"];
        NSString *text = suggestion[@"text"];
        UIView *row = [self createSuggestionRowWithIcon:icon text:text];
        [_suggestionsStackView addArrangedSubview:row];
    }

    // 布局约束
    [NSLayoutConstraint activateConstraints:@[
        [titleRow.topAnchor constraintEqualToAnchor:_suggestionsCardView.topAnchor constant:14],
        [titleRow.leadingAnchor constraintEqualToAnchor:_suggestionsCardView.leadingAnchor constant:16],
        [titleRow.trailingAnchor constraintEqualToAnchor:_suggestionsCardView.trailingAnchor constant:-16],
        [titleRow.heightAnchor constraintEqualToConstant:22],

        [titleIcon.leadingAnchor constraintEqualToAnchor:titleRow.leadingAnchor],
        [titleIcon.centerYAnchor constraintEqualToAnchor:titleRow.centerYAnchor],
        [titleIcon.widthAnchor constraintEqualToConstant:18],
        [titleIcon.heightAnchor constraintEqualToConstant:18],

        [_suggestionsTitleLabel.leadingAnchor constraintEqualToAnchor:titleIcon.trailingAnchor constant:8],
        [_suggestionsTitleLabel.centerYAnchor constraintEqualToAnchor:titleRow.centerYAnchor],
        [_suggestionsTitleLabel.trailingAnchor constraintEqualToAnchor:titleRow.trailingAnchor],

        [_suggestionsStackView.topAnchor constraintEqualToAnchor:titleRow.bottomAnchor constant:12],
        [_suggestionsStackView.leadingAnchor constraintEqualToAnchor:_suggestionsCardView.leadingAnchor constant:16],
        [_suggestionsStackView.trailingAnchor constraintEqualToAnchor:_suggestionsCardView.trailingAnchor constant:-16],
        [_suggestionsStackView.bottomAnchor constraintEqualToAnchor:_suggestionsCardView.bottomAnchor constant:-14],
    ]];
}

/// 创建单条建议行（图标 + 文字）
- (UIView *)createSuggestionRowWithIcon:(NSString *)iconName text:(NSString *)text {
    UIView *row = [[UIView alloc] init];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightRegular];
        icon.image = [UIImage systemImageNamed:iconName withConfiguration:config] ?: [UIImage systemImageNamed:@"chevron.right.circle" withConfiguration:config];
    }
    icon.tintColor = [UIColor systemYellowColor];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    [row addSubview:icon];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:13];
    label.textColor = [UIColor secondaryLabelColor];
    label.numberOfLines = 0;
    [row addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [icon.topAnchor constraintEqualToAnchor:row.topAnchor constant:2],
        [icon.widthAnchor constraintEqualToConstant:16],
        [icon.heightAnchor constraintEqualToConstant:16],

        [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:8],
        [label.topAnchor constraintEqualToAnchor:row.topAnchor],
        [label.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [label.bottomAnchor constraintEqualToAnchor:row.bottomAnchor],
    ]];

    return row;
}

/// 根据崩溃类型返回对应的修复建议列表
- (NSArray<NSDictionary *> *)suggestionsForCrashType {
    NSMutableArray *result = [NSMutableArray array];

    switch (self.crashType) {
        case CrashTypeOOM:
            [result addObject:@{@"icon": @"arrow.down.circle", @"text": localize(@"crash.suggestion.oom_ram", @"降低内存分配（建议 1024-2048MB）")}];
            [result addObject:@{@"icon": @"sparkles", @"text": localize(@"crash.suggestion.oom_getmoream", @"使用 GetMoreRam (LiveContainer) 解除 iOS 内存限制")}];
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.oom_mods", @"移除重量级 Mod（如光影、高清材质）")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.oom_restart", @"重启启动器后重试（释放内存碎片）")}];
            break;
        case CrashTypeSegfault:
            [result addObject:@{@"icon": @"cpu", @"text": localize(@"crash.suggestion.segfault_renderer", @"尝试切换渲染器（MobileGlues / Zink / MoltenVK / ANGLE / VirGL）")}];
            [result addObject:@{@"icon": @"shield", @"text": localize(@"crash.suggestion.segfault_jit", @"确保 JIT 已启用（设置→调试：自动/StikDebug/SideStore/StosDebug/JitStreamer-EB/TrollStore/手动）")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.segfault_restart", @"重启启动器后重试")}];
            break;
        case CrashTypeAbort:
            [result addObject:@{@"icon": @"exclamationmark.bubble", @"text": localize(@"crash.suggestion.abort_mods", @"检查 Mod 是否兼容（移除最近添加的 Mod）")}];
            [result addObject:@{@"icon": @"cpu", @"text": localize(@"crash.suggestion.abort_renderer", @"尝试切换渲染器")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.abort_restart", @"重启启动器后重试")}];
            break;
        case CrashTypeModConflict:
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.modconflict_remove", @"移除最近添加的 Mod")}];
            [result addObject:@{@"icon": @"info.circle", @"text": localize(@"crash.suggestion.modconflict_check", @"检查 Mod 版本兼容性（Forge/Fabric/API 版本）")}];
            [result addObject:@{@"icon": @"doc.text", @"text": localize(@"crash.suggestion.modconflict_log", @"查看完整日志定位冲突 Mod")}];
            break;
        case CrashTypeMissingLibrary:
            [result addObject:@{@"icon": @"arrow.clockwise.circle", @"text": localize(@"crash.suggestion.missinglib_reinstall", @"重新安装当前游戏版本")}];
            [result addObject:@{@"icon": @"folder", @"text": localize(@"crash.suggestion.missinglib_check", @"检查实例目录中的 libraries 文件夹是否完整")}];
            [result addObject:@{@"icon": @"wifi", @"text": localize(@"crash.suggestion.missinglib_network", @"检查网络连接，确保下载源可访问")}];
            break;
        case CrashTypeMissingMods:
            [result addObject:@{@"icon": @"arrow.clockwise.circle", @"text": [NSString stringWithFormat:localize(@"ame193.crash.1", @"删除该实例并重新导入整合包（建议换个下载源重试）%@"), self.ame95_missingModNames.count > 0 ? [NSString stringWithFormat:localize(@"ame193.crash.2", @"——重点确认：%@"), [self.ame95_missingModNames componentsJoinedByString:@"、"]] : @""]}];
            [result addObject:@{@"icon": @"square.and.pencil", @"text": localize(@"crash.suggestion.missingmods_manual", @"或在 Mod 管理器中手动补齐缺失的 mod（版本需与整合包要求一致）")}];
            if (self.ame95_overriddenEvidence.length > 0) {
                [result addObject:@{@"icon": @"eye.slash", @"text": localize(@"crash.suggestion.missingmods_override", @"日志显示依赖检查被覆盖（Dependencies overridden），它会让缺失 mod 逃避报错直到运行时崩溃；修复后可删掉 config/fabric-loader.json 里的 dependencyOverrides 条目")}];
            }
            [result addObject:@{@"icon": @"doc.text", @"text": localize(@"crash.suggestion.missingmods_share", @"分享 latestlog.txt 反馈，可凭崩溃报告中的缺失类清单直接定位")}];
            break;
        case CrashTypeJavaVersionMismatch:
            [result addObject:@{@"icon": @"hammer", @"text": localize(@"crash.suggestion.javaver_change", @"在设置中切换 Java 版本（8/17/21）")}];
            [result addObject:@{@"icon": @"info.circle", @"text": localize(@"crash.suggestion.javaver_check", @"检查游戏版本要求的 Java 版本")}];
            break;
        case CrashTypeRendererError:
            [result addObject:@{@"icon": @"cpu", @"text": localize(@"crash.suggestion.renderer_switch", @"尝试切换渲染器：MobileGlues / Zink / MoltenVK / ANGLE / VirGL")}];
            [result addObject:@{@"icon": @"eye.slash", @"text": localize(@"crash.suggestion.renderer_shader", @"禁用光影包后重试")}];
            [result addObject:@{@"icon": @"arrow.down.circle", @"text": localize(@"crash.suggestion.renderer_resolution", @"降低游戏分辨率缩放比例")}];
            break;
        case CrashTypeModLoadingFailure:
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.modload_remove", @"移除问题 Mod（查看日志中的错误行）")}];
            [result addObject:@{@"icon": @"arrow.clockwise.circle", @"text": localize(@"crash.suggestion.modload_update", @"更新 Mod 加载器（Forge/Fabric/OptiFine）")}];
            [result addObject:@{@"icon": @"info.circle", @"text": localize(@"crash.suggestion.modload_version", @"检查 Mod 是否支持当前 MC 版本")}];
            break;
        case CrashTypeModIncompatible:
            // ★ Task263：Fabric 自带的人话方案行直接作为首条建议（若解析到）
            if (self.ame263_incompatSummary.length > 0) {
                [result addObject:@{@"icon": @"wand.and.stars", @"text": [NSString stringWithFormat:localize(@"crash.suggestion.incompat_fabric_plan", @"按 Fabric 给出的方案：%@"), self.ame263_incompatSummary]}];
            }
            [result addObject:@{@"icon": @"puzzlepiece", @"text": localize(@"crash.suggestion.incompat_align", @"在 Mod 管理中把报告点名的 mod 更新/降级到匹配版本，或移除多余一方")}];
            [result addObject:@{@"icon": @"clock.arrow.circlepath", @"text": localize(@"crash.suggestion.incompat_pack_update", @"整合包更新后新旧 mod 混装常见此崩：以报告列出的版本对为准")}];
            break;
        case CrashTypeJavaException:
            [result addObject:@{@"icon": @"doc.text", @"text": localize(@"crash.suggestion.java_log", @"查看完整日志定位异常堆栈")}];
            [result addObject:@{@"icon": @"trash", @"text": localize(@"crash.suggestion.java_mods", @"检查 Mod 是否兼容（移除最近添加的 Mod）")}];
            [result addObject:@{@"icon": @"arrow.clockwise", @"text": localize(@"crash.suggestion.java_restart", @"重启启动器后重试")}];
            break;
        case CrashTypeNormal:
        case CrashTypeTerminated:
        case CrashTypeUnknown:
            // 这些类型不显示建议卡片
            break;
    }

    return result;
}

#pragma mark - Crash Type Analysis (崩溃类型分析，参照 HMCL)

#pragma mark - Task 95：缺失 mod 崩溃检测（Fabric entrypoint 链）

/// Task 95：整合包缺失 mod 检测（Fabric/NeoForge 入口点阶段的类加载失败）
///
/// 病历（96c527f latestlog.txt，1ee7111 构建，BMC2 [FABRIC] 1.20.1，536 mods，
/// iPad Air M4 / iPadOS 27）：实例 mods 目录缺失 FTB 全家桶 + balm +
/// terrablender + kleeslabs 等 8+ 个 jar；config/fabric-loader.json 的
/// dependencyOverrides（日志 "Dependencies overridden for ..."）掩盖了 Fabric
/// 的硬依赖检查，游戏死在 main entrypoint：
///   RuntimeException: Could not execute entrypoint stage 'main' due to errors,
///   provided by 'certain_questing_additions'
///     Caused by: NoClassDefFoundError: dev/ftb/mods/ftblibrary/config/ui/EditConfigScreen
///       Caused by: ClassNotFoundException: dev.ftb.mods.ftblibrary.config.ui.EditConfigScreen
///
/// 解析产物：
///   * ame95_missingModNames —— 缺失类包名推断的 mod 名（FTB Library/Balm/TerraBlender 等）
///   * ame95_overriddenEvidence —— "Dependencies overridden for ..." 证据行（存在时）
///   * crashDetail —— 面向用户的缺失类清单（封顶 8 条，防撑爆错误卡片）
/// 返回 YES 表示已识别并定型（analyzeCrashType 直接返回）。
- (BOOL)ame95_detectMissingModsFromLog:(NSString *)logContent lowerLog:(NSString *)lowerLog {
    if (logContent.length == 0 || lowerLog.length == 0) {
        return NO;
    }
    // 只认 Fabric 实证形态；Forge/NeoForge 缺失依赖在 resolve 阶段就会被干净拒绝，
    // 不会以 entrypoint 异常形态出现（宁缺毋滥，避免误报）。
    NSRange entrypointRange = [lowerLog rangeOfString:@"could not execute entrypoint stage"];
    if (entrypointRange.location == NSNotFound) {
        return NO;
    }
    // 1) 缺失类清单：ClassNotFoundException / NoClassDefFoundError 后的类名（去重）
    //    扫描范围限定在崩溃报告段（或 entrypoint 异常邻域）——大型整合包日志早段
    //    充斥无害的 soft-dependency 警告（KubeJS/EMI/LootJs 的可选类探测），全量
    //    扫描会把这些噪音顶满 8 条封顶，挤掉崩溃报告里真正的元凶（96c527f 实证：
    //    噪音在 970-1061 行，真凶在 2089+ 行的崩溃报告内）。
    NSUInteger scanLoc = 0;
    NSUInteger scanLen = logContent.length;
    NSRange reportHeader = [logContent rangeOfString:@"---- Minecraft Crash Report ----"];
    if (reportHeader.location != NSNotFound && reportHeader.location < entrypointRange.location) {
        scanLoc = reportHeader.location;
        NSRange walkthrough = [logContent rangeOfString:@"A detailed walkthrough"
                                                options:0
                                                  range:NSMakeRange(scanLoc, logContent.length - scanLoc)];
        // rangeOfString 返回的 location 是接收者内的绝对坐标（非搜索 range 内相对值）
        NSUInteger end = (walkthrough.location != NSNotFound) ? walkthrough.location : logContent.length;
        scanLen = end - scanLoc;
    } else {
        // 无正式崩溃报告头：退回 entrypoint 行前后窗口（前 500 字符兜住 Caused by 链头）
        scanLoc = entrypointRange.location > 500 ? (entrypointRange.location - 500) : 0;
        scanLen = logContent.length - scanLoc;
    }
    NSMutableArray<NSString *> *missingClasses = [NSMutableArray array];
    NSRegularExpression *classRe = [NSRegularExpression
        regularExpressionWithPattern:@"(?:ClassNotFoundException|NoClassDefFoundError): ([A-Za-z0-9_.$/]+)"
                              options:0 error:nil];
    if (classRe) {
        [classRe enumerateMatchesInString:logContent options:0
                                     range:NSMakeRange(scanLoc, scanLen)
                                usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags, BOOL *stop) {
            NSRange r = [m rangeAtIndex:1];
            if (r.location == NSNotFound) return;
            NSString *cls = [logContent substringWithRange:r];
            // '/' 与 '.' 两种类名形态归一（JVM 内部态用 '/'）
            cls = [cls stringByReplacingOccurrencesOfString:@"/" withString:@"."];
            if (cls.length > 0 && ![missingClasses containsObject:cls]) {
                [missingClasses addObject:cls];
            }
            if (missingClasses.count >= 8) *stop = YES; // 封顶，防错误卡片爆版
        }];
    }
    // 2) dependencyOverrides 证据行
    NSString *overriddenLine = nil;
    for (NSString *line in [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([line rangeOfString:@"Dependencies overridden for"].location != NSNotFound && line.length < 400) {
            overriddenLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            break;
        }
    }
    // 3) 类名 → 友好 mod 名映射（实证过的常见家族；兜底用包前两段）
    NSMutableArray<NSString *> *modNames = [NSMutableArray array];
    for (NSString *cls in missingClasses) {
        NSString *name = nil;
        if ([cls hasPrefix:@"dev.ftb.mods.ftbquests"]) name = @"FTB Quests";
        else if ([cls hasPrefix:@"dev.ftb.mods.ftblibrary"]) name = @"FTB Library";
        else if ([cls hasPrefix:@"dev.ftb.mods.ftbteams"]) name = @"FTB Teams";
        else if ([cls hasPrefix:@"dev.ftb.mods.ftbbackups"]) name = @"FTB Backups";
        else if ([cls hasPrefix:@"dev.ftb.mods."]) name = localize(@"ame193.crash.3", @"FTB 组件");
        else if ([cls hasPrefix:@"net.blay09.mods.balm"]) name = @"Balm";
        else if ([cls hasPrefix:@"terrablender."]) name = @"TerraBlender";
        if (name && ![modNames containsObject:name]) {
            [modNames addObject:name];
        }
    }
    // 4) 定型 + 详情文案
    self.crashType = CrashTypeMissingMods;
    self.ame95_missingModNames = [modNames copy];
    self.ame95_overriddenEvidence = overriddenLine;
    NSMutableString *detail = [NSMutableString string];
    if (missingClasses.count > 0) {
        [detail appendString:localize(@"ame193.crash.4", @"缺失的类（对应 mod 未安装或版本不符）：\n")];
        for (NSString *cls in missingClasses) {
            [detail appendFormat:@"  • %@\n", cls];
        }
    }
    if (modNames.count > 0) {
        [detail appendFormat:localize(@"ame193.crash.5", @"\n推断缺失组件：%@"), [modNames componentsJoinedByString:@"、"]];
    }
    if (overriddenLine.length > 0) {
        [detail appendFormat:localize(@"ame193.crash.6", @"\n\n依赖检查被覆盖：%@"), overriddenLine];
    }
    self.crashDetail = detail.length > 0 ? [detail copy] : nil;
    return YES;
}

/// ★ Task263：Fabric mod 不兼容检测（装机日志 1015 23:36:58 实证：
/// reeses-sodium-options 2.2.5 要求 sodium 0.9.2，实装 0.9.3-alpha.1 →
/// FormattedException → exit(1)，旧分析链只给"Mod 加载失败"一句泛话 =
/// 用户投诉的"上游的简略问题分析"。Fabric 自己已给出人话方案行，本解析
/// 把它原样搬上错误卡片。）
///
/// 触发词（任一）："Some of your mods are incompatible with the game or
/// each other!"（FormattedException 头）/ "Incompatible mods found!"（日志
/// 行）。采集范围：触发行到堆栈首行（"\tat "）或空 20 行窗口内，凡
/// " - " 开头的方案/细节行 + "A potential solution"/"More details:" 导语。
/// 产物：
///   * ame263_incompatSummary —— 第一条 " - Replace mod ..." 方案行
///   * crashDetail —— 导语 + 方案行 + 细节行（封顶 10 行，防错误卡爆版）
/// 返回 YES 表示已识别并定型（analyzeCrashType 直接返回）。
- (BOOL)ame263_detectFabricIncompatibleFromLog:(NSString *)logContent lowerLog:(NSString *)lowerLog {
    if (logContent.length == 0) return NO;
    NSArray<NSString *> *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSInteger triggerIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        NSString *l = lines[i];
        if ([l containsString:@"Some of your mods are incompatible with the game or each other"] ||
            [l containsString:@"Incompatible mods found!"]) {
            triggerIdx = i;
            break;
        }
    }
    if (triggerIdx < 0) return NO;

    NSMutableArray<NSString *> *collected = [NSMutableArray array];
    NSString *summary = nil;
    for (NSInteger i = triggerIdx; i < (NSInteger)lines.count && collected.count < 10; i++) {
        NSString *raw = lines[i];
        NSString *l = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (l.length == 0) break;
        if ([l hasPrefix:@"\tat "] || [raw hasPrefix:@"\tat "]) break;   // Java 堆栈开始
        BOOL keep = [l hasPrefix:@"- "] || [l hasPrefix:@" - "] ||
                    [l containsString:@"A potential solution"] ||
                    [l containsString:@"More details:"] ||
                    [l containsString:@"Some of your mods are incompatible"];
        if (!keep) continue;
        // 堆栈行形态的异常头（"net.fabricmc.loader.impl.FormattedException: ..."）只取冒号后人话段
        if ([l containsString:@"FormattedException:"]) {
            NSRange c = [l rangeOfString:@":"];
            if (c.location != NSNotFound && c.location + 1 < l.length) {
                l = [[l substringFromIndex:c.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }
        }
        if (l.length == 0 || l.length > 300) continue;
        if (![collected containsObject:l]) [collected addObject:l];
        // 方案行 = Fabric 给出的人话修复建议（" - Replace mod 'X' ... with version Y."）
        if (summary == nil && [l containsString:@"Replace mod '"]) summary = l;
    }
    if (collected.count == 0) return NO;

    self.crashType = CrashTypeModIncompatible;
    self.ame263_incompatSummary = summary;
    self.crashDetail = [collected componentsJoinedByString:@"\n"];
    return YES;
}

/// ★ Task263：Minecraft 原生崩溃报告解析（"---- Minecraft Crash Report ----"
/// 块——游戏内崩溃（mod 冲突/世界加载/渲染异常）MC 自带人话报告，旧链
/// 只做关键词分型丢掉了 Description 与 Caused by 链）。采集 Description
/// 行 + 首个异常行 + 前 2 条 "Caused by" + 头部注释（"// " 开头的诊断语）。
- (BOOL)ame263_extractMinecraftCrashReportFromLog:(NSString *)logContent {
    if (logContent.length == 0) return NO;
    NSRange report = [logContent rangeOfString:@"---- Minecraft Crash Report ----"];
    if (report.location == NSNotFound) return NO;
    NSArray<NSString *> *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    // 定位报告头所在行
    NSInteger start = -1;
    NSUInteger consumed = 0;
    for (NSInteger i = 0; i < (NSInteger)lines.count; i++) {
        consumed += lines[i].length + 1;
        if (consumed >= report.location + report.length) { start = i; break; }
    }
    if (start < 0) return NO;

    NSString *description = nil;
    NSMutableArray<NSString *> *exceptions = [NSMutableArray array];
    NSString *comment = nil;
    for (NSInteger i = start + 1; i < (NSInteger)lines.count && (description == nil || exceptions.count < 3 || comment == nil); i++) {
        NSString *l = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([l hasPrefix:@"-- Head --"]) break;   // 进入堆栈细节区，收手
        if (description == nil && [l hasPrefix:@"Description:"]) description = l;
        if (comment == nil && [l hasPrefix:@"// "]) comment = l;
        if (exceptions.count < 3 && l.length > 0 &&
            ([l containsString:@"Exception"] || [l containsString:@"Error"]) &&
            ![l hasPrefix:@"#"] && ![l hasPrefix:@"//"] &&
            [l rangeOfString:@":"].location != NSNotFound && l.length < 260) {
            BOOL dup = NO;
            for (NSString *e in exceptions) if ([e isEqualToString:l]) { dup = YES; break; }
            if (!dup) [exceptions addObject:l];
        }
        if ([l hasPrefix:@"Description:"] || description != nil) {
            // Description 后紧跟异常块；异常收满 3 条且 Description 已得即可停
            if (description != nil && exceptions.count >= 3) break;
        }
    }
    if (description == nil && exceptions.count == 0) return NO;

    NSMutableString *detail = [NSMutableString string];
    if (description.length > 0) [detail appendFormat:@"%@\n", description];
    for (NSString *e in exceptions) [detail appendFormat:@"  %@\n", e];
    if (comment.length > 0) [detail appendFormat:@"%@", comment];
    if (detail.length == 0) return NO;

    self.crashType = CrashTypeJavaException;
    self.crashDetail = [detail copy];
    return YES;
}

/// 分析崩溃类型（基于 exitCode 和日志关键词）
///
/// 参照 HMCL 的崩溃分析器，通过 exitCode 和日志中的异常关键词，
/// 将崩溃分类为 OOM/段错误/Mod 冲突/缺失库/Java 版本不匹配/渲染器错误等类型。
/// 分析结果用于：
/// 1. 在错误卡片中显示更精确的原因描述
/// 2. 在建议卡片中显示对应的修复建议
- (void)analyzeCrashType {
    NSString *logContent = [self readLatestLogForAnalysis];
    NSString *lowerLog = logContent.length > 0 ? [logContent lowercaseString] : @"";

    // 1. 正常退出
    if (_exitCode == 0) {
        self.crashType = CrashTypeNormal;
        self.crashDetail = nil;
        return;
    }

    // 2. OOM（SIGKILL 或日志含 OOM 关键词）
    if ([self isOOMCrash]) {
        self.crashType = CrashTypeOOM;
        self.crashDetail = [self extractLineContaining:@"outofmemory" fromLog:lowerLog] ?: [self extractLineContaining:@"cannot allocate" fromLog:lowerLog];
        return;
    }

    // ★ Task263 2.5：Fabric mod 不兼容（FormattedException 人话方案块）——
    //   必须先于一切泛化关键词：本块自带权威修复方案，被泛化分支抢先
    //   定型为"Mod 加载失败"就丢掉了方案行（装机日志 1015 实证路径）。
    if ([self ame263_detectFabricIncompatibleFromLog:logContent lowerLog:lowerLog]) {
        return;
    }

    // 3. SIGSEGV 段错误
    if (_exitCode == 11) {
        self.crashType = CrashTypeSegfault;
        self.crashDetail = nil;
        return;
    }

    // 4. SIGABRT
    if (_exitCode == 6) {
        // 检查是否为 Mod 冲突导致
        if ([lowerLog containsString:@"nosuchmethoderror"] || [lowerLog containsString:@"classcastexception"] ||
            [lowerLog containsString:@"illegalaccessexception"] || [lowerLog containsString:@"nosuchfielderror"]) {
            self.crashType = CrashTypeModConflict;
            self.crashDetail = [self extractLineContaining:@"nosuchmethod" fromLog:lowerLog] ?: [self extractLineContaining:@"classcast" fromLog:lowerLog];
        } else if ([lowerLog containsString:@"unsatisfiedlinkerror"] || [lowerLog containsString:@"noclassdeffounderror"]) {
            self.crashType = CrashTypeMissingLibrary;
            self.crashDetail = [self extractLineContaining:@"unsatisfiedlink" fromLog:lowerLog] ?: [self extractLineContaining:@"noclassdef" fromLog:lowerLog];
        } else if ([lowerLog containsString:@"unsupportedclassversionerror"]) {
            self.crashType = CrashTypeJavaVersionMismatch;
            self.crashDetail = [self extractLineContaining:@"unsupportedclassversion" fromLog:lowerLog];
        } else {
            self.crashType = CrashTypeAbort;
            self.crashDetail = nil;
        }
        return;
    }

    // 5. SIGTERM
    if (_exitCode == 15) {
        self.crashType = CrashTypeTerminated;
        self.crashDetail = nil;
        return;
    }

    // 6. 基于日志关键词分析（其他 exitCode）
    // Task 95：Fabric entrypoint 缺失 mod 检测必须最先做——entrypoint 崩溃日志里
    // 常混杂 ClassCastException 等其他 suppressed 异常，交给泛化分支会误分类为
    // Mod 冲突/缺失库，丢失宝贵的缺失类清单与精确指引。
    if ([self ame95_detectMissingModsFromLog:logContent lowerLog:lowerLog]) {
        return;
    }

    // Mod 冲突
    if ([lowerLog containsString:@"nosuchmethoderror"] || [lowerLog containsString:@"classcastexception"] ||
        [lowerLog containsString:@"illegalaccessexception"] || [lowerLog containsString:@"nosuchfielderror"] ||
        [lowerLog containsString:@"duplicate mod"]) {
        self.crashType = CrashTypeModConflict;
        self.crashDetail = [self extractLineContaining:@"nosuchmethod" fromLog:lowerLog] ?: [self extractLineContaining:@"classcast" fromLog:lowerLog];
        return;
    }

    // ★ Task263 5.5：MC 原生崩溃报告（"---- Minecraft Crash Report ----"）
    //   ——Description + 异常链原样上卡（游戏内崩溃的人话报告，优先于
    //   泛化关键词，避免被 "fabric+error" 之类误抢定型）。
    if ([self ame263_extractMinecraftCrashReportFromLog:logContent]) {
        return;
    }

    // 缺失库
    if ([lowerLog containsString:@"unsatisfiedlinkerror"] || [lowerLog containsString:@"noclassdeffounderror"] ||
        [lowerLog containsString:@"filenotfoundexception"] && [lowerLog containsString:@"library"]) {
        self.crashType = CrashTypeMissingLibrary;
        self.crashDetail = [self extractLineContaining:@"unsatisfiedlink" fromLog:lowerLog] ?: [self extractLineContaining:@"noclassdef" fromLog:lowerLog];
        return;
    }

    // Java 版本不匹配
    if ([lowerLog containsString:@"unsupportedclassversionerror"] || [lowerLog containsString:@"unsupported major.minor version"]) {
        self.crashType = CrashTypeJavaVersionMismatch;
        self.crashDetail = [self extractLineContaining:@"unsupportedclassversion" fromLog:lowerLog] ?: [self extractLineContaining:@"unsupported major" fromLog:lowerLog];
        return;
    }

    // 渲染器错误
    if ([lowerLog containsString:@"gl_invalid"] || [lowerLog containsString:@"egl_error"] ||
        [lowerLog containsString:@"opengl error"] || [lowerLog containsString:@"failed to create context"] ||
        [lowerLog containsString:@"glgeterror"] || [lowerLog containsString:@"metal:"]) {
        self.crashType = CrashTypeRendererError;
        self.crashDetail = [self extractLineContaining:@"gl_invalid" fromLog:lowerLog] ?: [self extractLineContaining:@"egl_error" fromLog:lowerLog] ?: [self extractLineContaining:@"opengl error" fromLog:lowerLog];
        return;
    }

    // Mod 加载失败
    if ([lowerLog containsString:@"fml"] && [lowerLog containsString:@"error"] ||
        [lowerLog containsString:@"forge"] && [lowerLog containsString:@"modloading"] ||
        [lowerLog containsString:@"fabric"] && [lowerLog containsString:@"error"] ||
        [lowerLog containsString:@"optifine"] && [lowerLog containsString:@"error"]) {
        self.crashType = CrashTypeModLoadingFailure;
        self.crashDetail = [self extractLineContaining:@"modloading" fromLog:lowerLog] ?: [self extractLineContaining:@"fml" fromLog:lowerLog];
        return;
    }

    // Java 异常
    if ([lowerLog containsString:@"exception"] || [lowerLog containsString:@"stacktrace"]) {
        self.crashType = CrashTypeJavaException;
        self.crashDetail = [self extractLineContaining:@"exception" fromLog:lowerLog];
        return;
    }

    // 兜底：未知
    self.crashType = CrashTypeUnknown;
    self.crashDetail = nil;

    // ★ Task267：Prisma 详细错误分析器（CrashAnalyzer）hs_err 分型融合。
    //   退出码语义弱（JVM fatal 常以 exit(1) 出现、Task208 直死不落码），
    //   而 hs_err 是 JVM 自落的信号级铁证——分类完统一拉一次对账。
    [self ame267_refineWithHsErr];
}

/// ★ Task267：hs_err_pid*.log 结构化分型融合（自研 CrashAnalyzer，
///   Task217/218 渲染器自学的同一引擎；此前本页只把 hs_err 头 4KB 当
///   文本证据，丢掉了分型结果 = "没有我们项目的详细错误分析器"的缺口）。
///   融合策略（保守精化，不推翻已有分类）：
///   - hs_err 命中 isOOM → OOM 优先（JVM OOM 常以 exit(1) 呈现，退出码
///     路径漏判；OOM 不记渲染器的锅，与 Task217/218 口径一致）；
///   - 信号级死亡且命中渲染器家族库 → RendererError，detail 带
///     Problematic frame / 归因库 / native 帧摘要（详细分析直接可见）；
///   - 无归因的信号 → 仅当原分类为 Unknown/Segfault/Abort 时按信号精化；
///   - 无 hs_err（FastQuit/SIGKILL）零动作，维持原分类。
- (void)ame267_refineWithHsErr {
    if (_exitCode == 0) return;
    const char *ame267_homeC = getenv("POJAV_HOME");
    NSString *ame267_home = ame267_homeC ? [NSString stringWithUTF8String:ame267_homeC] : nil;
    if (ame267_home.length == 0) return;
    // 扫 mtime 最新的 hs_err_pid*.log（JavaLauncher ame217 同款口径；
    // Task27 已把 -XX:ErrorFile 定向到 POJAV_HOME 根，浅扫描即可）。
    NSFileManager *ame267_fm = [NSFileManager defaultManager];
    NSArray *ame267_files = [ame267_fm contentsOfDirectoryAtPath:ame267_home error:nil];
    NSString *ame267_best = nil;
    NSDate *ame267_bestDate = nil;
    for (NSString *ame267_f in ame267_files) {
        if (![ame267_f hasPrefix:@"hs_err_pid"] || ![ame267_f hasSuffix:@".log"]) continue;
        NSString *ame267_path = [ame267_home stringByAppendingPathComponent:ame267_f];
        NSDate *ame267_d = [[ame267_fm attributesOfItemAtPath:ame267_path error:nil]
            fileModificationDate];
        if (ame267_d && (!ame267_bestDate || [ame267_d compare:ame267_bestDate] == NSOrderedDescending)) {
            ame267_bestDate = ame267_d;
            ame267_best = ame267_path;
        }
    }
    if (ame267_best.length == 0) return;
    NSDictionary *ame267_r = [CrashAnalyzer analyzeHsErrFile:ame267_best];
    if (ame267_r.count == 0) return;
    self.ame267_hsErr = ame267_r;

    BOOL ame267_oom = [ame267_r[@"isOOM"] boolValue];
    NSString *ame267_signal = ame267_r[@"signal"] ?: @"";
    NSString *ame267_blamed = ame267_r[@"blamedRenderer"] ?: @"";
    NSString *ame267_pf = ame267_r[@"problematicFrame"] ?: @"";
    NSString *ame267_nf = ame267_r[@"nativeFrames"] ?: @"";
    BOOL ame267_isSignalDeath = [ame267_signal hasPrefix:@"SIG"] &&
                                ![ame267_signal isEqualToString:@"(unknown)"];

    // 结构化诊断摘要（走 crashDetail 槽位，与 extractLine 产物同位展示）。
    NSMutableString *ame267_diag = [NSMutableString string];
    if (ame267_pf.length > 0) [ame267_diag appendFormat:@"Problematic frame: %@", ame267_pf];
    if (ame267_blamed.length > 0) {
        if (ame267_diag.length > 0) [ame267_diag appendString:@"\n"];
        [ame267_diag appendFormat:@"CrashAnalyzer 归因：%@（渲染器层库）", ame267_blamed];
    }
    if (ame267_nf.length > 0) {
        if (ame267_diag.length > 0) [ame267_diag appendString:@"\n"];
        [ame267_diag appendFormat:@"native 帧：%@", ame267_nf];
    }
    if (ame267_diag.length == 0) return;   // hs_err 无可融合结论，维持原分类

    if (ame267_oom) {
        self.crashType = CrashTypeOOM;
        if (self.crashDetail.length == 0) self.crashDetail = [ame267_diag copy];
        NSLog(@"[PLCrashView] Task267: hs_err refined -> OOM (CrashAnalyzer)");
        return;
    }
    if (ame267_isSignalDeath && ame267_blamed.length > 0) {
        self.crashType = CrashTypeRendererError;
        if (self.crashDetail.length == 0) self.crashDetail = [ame267_diag copy];
        NSLog(@"[PLCrashView] Task267: hs_err refined -> RendererError (blamed %@)", ame267_blamed);
        return;
    }
    if (ame267_isSignalDeath &&
        (self.crashType == CrashTypeUnknown || self.crashType == CrashTypeSegfault ||
         self.crashType == CrashTypeAbort)) {
        self.crashType = [ame267_signal containsString:@"ABRT"] ? CrashTypeAbort : CrashTypeSegfault;
        if (self.crashDetail.length == 0) self.crashDetail = [ame267_diag copy];
        NSLog(@"[PLCrashView] Task267: hs_err refined -> %ld (%@)", (long)self.crashType, ame267_signal);
    }
}

/// 从日志中提取包含指定关键词的第一行（用于崩溃详情展示）
- (NSString *)extractLineContaining:(NSString *)keyword fromLog:(NSString *)lowerLog {
    if (lowerLog.length == 0) return nil;
    NSArray *lines = [lowerLog componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line containsString:keyword] && line.length < 200) {
            return [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
    }
    return nil;
}

- (void)setupLogCard {
    _logCardView = [[UIView alloc] init];
    _logCardView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    _logCardView.layer.cornerRadius = 16;  // Task137：回归原生卡片圆角
    _logCardView.layer.cornerCurve = kCACornerCurveContinuous;
    _logCardView.layer.masksToBounds = YES;
    _logCardView.layer.borderWidth = 0.5;
    _logCardView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    _logCardView.translatesAutoresizingMaskIntoConstraints = NO;
    // 注意：不在此处添加到 _mainStackView，由 setupUI 中的水平分栏容器管理
    // 应用毛玻璃效果（适配自定义背景壁纸）
    [[BackgroundManager sharedManager] applyEffectToView:_logCardView];

    // 日志标题
    _logTitleLabel = [[UILabel alloc] init];
    _logTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logTitleLabel.text = localize(@"crash.log_info", nil);
    _logTitleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _logTitleLabel.textColor = [UIColor labelColor];
    [_logCardView addSubview:_logTitleLabel];

    // 日志文本视图（可内部滚动）
    _logTextView = [[UITextView alloc] init];
    _logTextView.translatesAutoresizingMaskIntoConstraints = NO;
    _logTextView.backgroundColor = [UIColor clearColor];
    _logTextView.textColor = [UIColor labelColor];
    _logTextView.font = [UIFont fontWithName:@"Menlo" size:11];
    _logTextView.editable = NO;
    _logTextView.showsVerticalScrollIndicator = YES;
    _logTextView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [_logCardView addSubview:_logTextView];

    // 占位符（日志为空时显示，居中放大文字）
    _logPlaceholderLabel = [[UILabel alloc] init];
    _logPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _logPlaceholderLabel.text = localize(@"crash.log_info", nil);
    _logPlaceholderLabel.font = [UIFont systemFontOfSize:36 weight:UIFontWeightBold];
    _logPlaceholderLabel.textColor = [UIColor tertiaryLabelColor];
    _logPlaceholderLabel.textAlignment = NSTextAlignmentCenter;
    [_logCardView addSubview:_logPlaceholderLabel];

    // 日志卡片高度约束（初始 240，viewDidLayoutSubviews 中根据屏幕高度调整）
    self.logCardHeightConstraint = [_logCardView.heightAnchor constraintEqualToConstant:240];
    self.logCardHeightConstraint.priority = UILayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [_logTitleLabel.topAnchor constraintEqualToAnchor:_logCardView.topAnchor constant:12],
        [_logTitleLabel.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor constant:16],
        [_logTitleLabel.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor constant:-16],

        [_logTextView.topAnchor constraintEqualToAnchor:_logTitleLabel.bottomAnchor constant:8],
        [_logTextView.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor constant:8],
        [_logTextView.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor constant:-8],
        [_logTextView.bottomAnchor constraintEqualToAnchor:_logCardView.bottomAnchor constant:-8],

        [_logPlaceholderLabel.topAnchor constraintEqualToAnchor:_logCardView.topAnchor],
        [_logPlaceholderLabel.bottomAnchor constraintEqualToAnchor:_logCardView.bottomAnchor],
        [_logPlaceholderLabel.leadingAnchor constraintEqualToAnchor:_logCardView.leadingAnchor],
        [_logPlaceholderLabel.trailingAnchor constraintEqualToAnchor:_logCardView.trailingAnchor],

        self.logCardHeightConstraint,
    ]];
}

- (void)setupButtonsIntoContainer:(UIStackView *)container {
    // ============================================================
    // FCL 风格按钮列（右侧垂直排列）
    // ============================================================
    // 按钮顺序（从上到下）：
    //   1. 重启启动器（蓝色强调）— exit(0) + openURL 拉起应用
    //   2. 退出启动器（红色）— exit(0) 直接退出进程，不重启
    //   3. 分享日志
    //   4. 前往 GitHub Issues
    //   5. 查看完整日志
    //
    // 关键修复：之前"重启启动器"和"退出启动器"功能相同
    //   - 重启：调用 +restartLauncher（exit + relaunch）
    //   - 退出：调用 dismissAndReturnToLauncher（仅返回启动器主界面，不退出进程）
    // 用户反馈两个按钮效果一样（都回到启动器），不符合 FCL 行为。
    // 现在"退出启动器"改为调用 exitLauncherAction（exit(0) 直接退出，不重启）。

    // 1. 重启启动器按钮（蓝色强调）
    // 参照 FCL：很多崩溃是临时加载失败（JIT/dylib/内存碎片），重启即可解决。
    _restartButton = [self createButtonWithTitle:localize(@"crash.restart_launcher", @"重启启动器")
                                            icon:@"arrow.clockwise"
                                   backgroundColor:[UIColor colorWithRed:0.2 green:0.6 blue:0.95 alpha:1.0]
                                       textColor:[UIColor whiteColor]
                                          bold:YES
                                          action:@selector(restartLauncherAction)];
    [container addArrangedSubview:_restartButton];

    // 2. 退出启动器按钮（红色强调）
    // 关键修复：之前此按钮调用 dismissAndReturnToLauncher（返回启动器主界面），
    // 与"重启启动器"效果一样（都是回到启动器）。现在改为直接 exit(0) 退出进程，
    // 不重启应用，与 FCL 的"退出"行为一致。
    _exitButton = [self createButtonWithTitle:localize(@"crash.return_launcher", @"退出启动器")
                                         icon:@"xmark.circle.fill"
                                backgroundColor:[UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:1.0]
                                    textColor:[UIColor whiteColor]
                                       bold:YES
                                       action:@selector(exitLauncherAction)];
    [container addArrangedSubview:_exitButton];

    // 3. 分享日志按钮
    _shareButton = [self createButtonWithTitle:localize(@"crash.share_log", @"分享日志")
                                          icon:@"square.and.arrow.up"
                                 backgroundColor:[[UIColor whiteColor] colorWithAlphaComponent:0.15]
                                     textColor:[UIColor labelColor]
                                        bold:NO
                                        action:@selector(shareLog)];
    [container addArrangedSubview:_shareButton];

    // 4. GitHub Issues 按钮
    _githubButton = [self createButtonWithTitle:localize(@"crash.github_issue", @"前往 GitHub Issues")
                                           icon:@"link"
                                  backgroundColor:[[UIColor colorWithRed:0.3 green:0.5 blue:0.9 alpha:1.0] colorWithAlphaComponent:0.3]
                                      textColor:[UIColor whiteColor]
                                         bold:NO
                                         action:@selector(openGitHubIssues)];
    [container addArrangedSubview:_githubButton];

    // 5. 查看完整日志按钮（透明文字按钮）
    _fullLogButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _fullLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_fullLogButton setTitle:localize(@"crash.view_log", @"查看日志详情") forState:UIControlStateNormal];
    _fullLogButton.titleLabel.font = [UIFont systemFontOfSize:14];
    [_fullLogButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    [_fullLogButton addTarget:self action:@selector(showFullLog) forControlEvents:UIControlEventTouchUpInside];
    [container addArrangedSubview:_fullLogButton];
}

- (UIButton *)createButtonWithTitle:(NSString *)title icon:(NSString *)icon backgroundColor:(UIColor *)bgColor textColor:(UIColor *)textColor bold:(BOOL)bold action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.backgroundColor = bgColor;
    button.layer.cornerRadius = 12;
    button.layer.cornerCurve = kCACornerCurveContinuous;

    [button setTitleColor:textColor forState:UIControlStateNormal];
    button.titleLabel.font = bold ? [UIFont boldSystemFontOfSize:15] : [UIFont systemFontOfSize:15];

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:bold ? UIImageSymbolWeightMedium : UIImageSymbolWeightRegular];
        UIImage *iconImage = [UIImage systemImageNamed:icon withConfiguration:config];
        [button setImage:iconImage forState:UIControlStateNormal];
    }

    button.titleEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 0);
    button.imageEdgeInsets = UIEdgeInsetsMake(0, -8, 0, 0);
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];

    // 固定按钮高度
    [button.heightAnchor constraintEqualToConstant:48].active = YES;

    return button;
}

- (void)adjustLogCardHeight {
    self.logCardHeightConstraint.constant = [self ame263_baseLogCardHeight];
}

/// ★ Task263：收起态基准高度（原 adjustLogCardHeight 的屏幕分档逻辑，
///   展开/收起切换共用）。
- (CGFloat)ame263_baseLogCardHeight {
    CGFloat screenHeight = self.view.bounds.size.height;
    // 根据屏幕高度调整日志卡片高度：
    //   小屏幕（iPhone SE）日志区较矮，给按钮留空间
    //   大屏幕（iPad）日志区较高，充分利用空间
    CGFloat logHeight;
    if (screenHeight < 600) {
        logHeight = 160;
    } else if (screenHeight < 800) {
        logHeight = 220;
    } else {
        logHeight = 300;
    }
    return logHeight;
}

#pragma mark - Log Content

/// Task274-g（G8）：只读文件尾部 maxBytes 字节（文件不足则整读），失败/空返回 nil。
/// 供崩溃界面日志卡展示——崩溃时 latestlog 可达数 MB，主线程整读会拖住
/// PLCrashView 呈现 8s 让路窗口（Task273 看门狗让路协议）。
static NSString *ame274_readFileTail(NSString *path, NSUInteger maxBytes) {
    if (path.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    unsigned long long size = attrs ? [attrs fileSize] : 0;
    if (size == 0) return nil;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    @try {
        if (size > maxBytes) [fh seekToFileOffset:size - maxBytes];
        NSData *logData = [fh readDataToEndOfFile];
        [fh closeFile];
        if (logData.length == 0) return nil;
        NSString *s = [[NSString alloc] initWithData:logData encoding:NSUTF8StringEncoding];
        // Task274-r1: NSString 无 initWithData:encoding:allowLossyConversion:（CI 实编译抓出）；
        // 恒不失败的换码回退用 NSISOLatin1StringEncoding（单字节全映射，永不返回 nil）。
        if (!s) s = [[NSString alloc] initWithData:logData encoding:NSISOLatin1StringEncoding];
        return s;
    } @catch (NSException *ame274_e) {
        [fh closeFile];
        return nil;
    }
}

- (void)loadLogContent {
    // ★ Task274-g（G8）：主线程同步整读 latestlog.txt（崩溃时数 MB）拖住崩溃呈现
    //   8s 让路窗口——改后台队列只读尾部 4KB 回主线程塞 textView；
    //   空文件/读失败回落现状占位行为（fatal_trace 尾窗同法）。
    NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *tracePath = [NSString stringWithFormat:@"%s/fatal_trace.txt", getenv("POJAV_HOME")];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *logContent = ame274_readFileTail(latestlogPath, 4096);
        if (logContent.length == 0) {
            // 空文件/读失败：回落现状行为（占位提示；不追加 fatal_trace，同旧口径）
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                strongSelf.logTextView.text = nil;
                strongSelf.logPlaceholderLabel.hidden = NO;
            });
            return;
        }

        // 尾窗首行可能是截断残行（仅尾读时）：裁掉后取最后 150 行（同旧语义）
        NSArray *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:latestlogPath error:nil];
        NSUInteger firstIdx = (attrs && [attrs fileSize] > 4096) ? 1 : 0;
        NSInteger startIndex = MAX((NSInteger)firstIdx, (NSInteger)lines.count - 150);
        NSMutableArray *lastLines = [NSMutableArray array];
        for (NSInteger i = startIndex; i < (NSInteger)lines.count; i++) {
            NSString *line = lines[i];
            if (line.length > 0) {
                [lastLines addObject:line];
            }
        }
        NSMutableString *logText =
            [NSMutableString stringWithString:[lastLines componentsJoinedByString:@"\n"]];

        // Task 27：日志尾部可能在死亡竞争中丢失（Task 26 教训），把 fatal_trace.txt
        // 尾部追加显示（若存在）——这是错误界面上唯一直接可见的死亡现场
        NSString *trace = ame274_readFileTail(tracePath, 4096);
        if (trace.length > 0) {
            NSArray *traceLines = [trace componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSDictionary *tAttrs = [[NSFileManager defaultManager] attributesOfItemAtPath:tracePath error:nil];
            NSUInteger tFirst = (tAttrs && [tAttrs fileSize] > 4096) ? 1 : 0;
            NSInteger tStart = MAX((NSInteger)tFirst, (NSInteger)traceLines.count - 40);
            NSMutableArray *traceTail = [NSMutableArray arrayWithObject:@"----- fatal_trace.txt (tail) -----"];
            for (NSInteger i = tStart; i < (NSInteger)traceLines.count; i++) {
                NSString *tl = traceLines[i];
                if (tl.length > 0) [traceTail addObject:tl];
            }
            [logText appendFormat:@"\n%@", [traceTail componentsJoinedByString:@"\n"]];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.logTextView.text = logText;
            strongSelf.logPlaceholderLabel.hidden = strongSelf.logTextView.text.length > 0;
            // 滚动到底部
            [strongSelf.logTextView scrollRangeToVisible:NSMakeRange(strongSelf.logTextView.text.length, 0)];
        });
    });
}

#pragma mark - Crash Analysis

/// 读取 latestlog.txt 的内容（用于崩溃原因分析）
/// Task 27：追加 fatal_trace.txt 与 hs_err（若有）——这两者是“无报告死亡”
/// 场景下唯一的现场证据，且不经过 latestlog 管道，不存在丢尾问题
- (NSString *)readLatestLogForAnalysis {
    static NSString *cachedLog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
        // ★ Task275（P1-b2）：分析读改 256KB 尾窗（ame273_writeCrashReport 同口径）——
        //   原主线程整读数 MB 日志，后续 containsString/全文 split O(n)×N 次，大日志卡
        //   主线程数秒即可击穿 Task273 的 8s 让路窗（最重崩溃时崩溃界面反而出不来，
        //   只剩 L3 补弹）。崩溃归因关键证据（异常链/at exit）集中于日志尾部。
        cachedLog = ame274_readFileTail(latestlogPath, 256 * 1024) ?: @"";
        NSString *extra = [PLCrashView fatalEvidenceText];
        if (extra.length > 0) {
            cachedLog = [cachedLog stringByAppendingFormat:@"\n%@", extra];
        }
    });
    return cachedLog;
}

/// 汇总 fatal 证据文本：fatal_trace.txt 全部 + 最新 hs_err_pid*.log 头部 4KB
+ (NSString *)fatalEvidenceText {
    NSMutableString *out = [NSMutableString string];
    NSString *home = @(getenv("POJAV_HOME") ?: "");
    if (home.length == 0) return out;

    NSString *tracePath = [home stringByAppendingPathComponent:@"fatal_trace.txt"];
    NSString *trace = [NSString stringWithContentsOfFile:tracePath encoding:NSUTF8StringEncoding error:nil];
    if (trace.length > 0) {
        [out appendFormat:@"\n----- fatal_trace.txt -----\n%@", trace];
    }

    // 最新 hs_err_pid*.log（JVM fatal log，-XX:ErrorFile 已定向到 POJAV_HOME）
    NSError *dirErr = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:home error:&dirErr];
    NSString *best = nil; NSDate *bestDate = nil;
    for (NSString *f in files) {
        if (![f hasPrefix:@"hs_err_pid"] || ![f hasSuffix:@".log"]) continue;
        NSString *p = [home stringByAppendingPathComponent:f];
        NSDate *d = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil][NSFileModificationDate];
        if (!bestDate || [d compare:bestDate] == NSOrderedDescending) { best = p; bestDate = d; }
    }
    if (best) {
        NSData *data = [NSData dataWithContentsOfFile:best];
        if (data.length > 0) {
            NSUInteger cap = MIN(data.length, (unsigned long)4096);
            NSString *head = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, cap)] encoding:NSUTF8StringEncoding];
            if (head.length > 0) {
                [out appendFormat:@"\n----- %@ (head) -----\n%@", best.lastPathComponent, head];
            }
        }
    }
    return out;
}

/// 判断是否为 OOM（内存不足）崩溃
- (BOOL)isOOMCrash {
    // SIGKILL (信号 9) 通常是系统因内存不足强制终止进程
    if (_exitCode == 9) return YES;

    // 检查日志中是否包含 OOM 相关关键词
    NSString *logContent = [self readLatestLogForAnalysis];
    if (logContent.length > 0) {
        NSString *lowerLog = [logContent lowercaseString];
        NSArray<NSString *> *oomKeywords = @[
            @"outofmemoryerror",
            @"cannot allocate memory",
            @"failed to allocate",
            @"java.lang.outofmemory",
            @"insufficient memory",
            @"mmap failed",
            @"out of memory"
        ];
        for (NSString *keyword in oomKeywords) {
            if ([lowerLog containsString:keyword]) return YES;
        }
    }
    return NO;
}

/// 根据 analyzeCrashType 分析的崩溃类型，返回本地化的原因描述
///
/// 参照 HMCL 的崩溃分析器，提供更精确的崩溃原因描述。
/// 新增的崩溃类型：Mod 冲突、缺失库、Java 版本不匹配、渲染器错误、Mod 加载失败。
- (NSString *)crashReasonText {
    // 优先使用自定义原因
    if (_customReason.length > 0) {
        return [NSString stringWithFormat:@"%@%@", localize(@"crash.possible_reason", nil), _customReason];
    }

    NSString *reason = nil;

    switch (self.crashType) {
        case CrashTypeNormal:
            reason = localize(@"crash.reason.normal", nil);
            break;
        case CrashTypeOOM:
            reason = localize(@"crash.reason.memory", nil);
            break;
        case CrashTypeSegfault:
            reason = localize(@"crash.reason.segmentation", nil);
            break;
        case CrashTypeAbort:
            reason = localize(@"crash.reason.abort", nil);
            break;
        case CrashTypeTerminated:
            reason = localize(@"crash.reason.terminated", nil);
            break;
        case CrashTypeModConflict:
            reason = localize(@"crash.reason.mod_conflict", @"Mod 冲突导致崩溃（NoSuchMethodError/ClassCastException 等）");
            break;
        case CrashTypeMissingLibrary:
            reason = localize(@"crash.reason.missing_library", @"缺失游戏库文件（UnsatisfiedLinkError/NoClassDefFoundError）");
            break;
        case CrashTypeMissingMods:
            reason = localize(@"crash.reason.missing_mods", @"整合包缺失 mod 文件（入口点阶段类加载失败，常见于导入不完整）");
            break;
        case CrashTypeJavaVersionMismatch:
            reason = localize(@"crash.reason.java_version", @"Java 版本不匹配（UnsupportedClassVersionError）");
            break;
        case CrashTypeRendererError:
            reason = localize(@"crash.reason.renderer", @"渲染器错误（OpenGL/Vulkan/EGL 初始化失败）");
            // ★ Task267：hs_err 归因到具体渲染器库时点名展示。
            if (self.ame267_hsErr[@"blamedRenderer"] &&
                [self.ame267_hsErr[@"blamedRenderer"] isKindOfClass:NSString.class] &&
                [(NSString *)self.ame267_hsErr[@"blamedRenderer"] length] > 0) {
                reason = [NSString stringWithFormat:@"%@（CrashAnalyzer 归因：%@）",
                          reason, self.ame267_hsErr[@"blamedRenderer"]];
            }
            break;
        case CrashTypeModLoadingFailure:
            reason = localize(@"crash.reason.mod_loading", @"Mod 加载失败（Forge/Fabric/OptiFine 加载错误）");
            break;
        case CrashTypeModIncompatible:
            // ★ Task263：不兼容类型的原因行只报事实，细节与方案在 crashDetail
            reason = localize(@"crash.reason.mod_incompatible", @"Mod 版本不兼容（多个 mod 对同一依赖的版本要求冲突，或 mod 与 MC/加载器版本不匹配）");
            break;
        case CrashTypeJavaException:
            reason = localize(@"crash.reason.java_exception", nil);
            break;
        case CrashTypeUnknown:
            reason = [NSString stringWithFormat:localize(@"crash.reason.unknown", @"未知错误 (代码: %d)"), _exitCode];
            break;
    }

    // 如果有崩溃详情，追加到原因后面
    if (self.crashDetail.length > 0) {
        reason = [NSString stringWithFormat:@"%@\n%@", reason, self.crashDetail];
    }

    return [NSString stringWithFormat:@"%@%@", localize(@"crash.possible_reason", nil), reason];
}

#pragma mark - Actions

- (void)shareLog {
    NSString *latestlogPath = [NSString stringWithFormat:@"file://%s/latestlog.txt", getenv("POJAV_HOME")];
    NSMutableArray *items = [NSMutableArray arrayWithArray:@[@"latestlog.txt", [NSURL URLWithString:latestlogPath]]];

    // Task 27：一并分享 fatal 证据文件（fatal_trace.txt / 最新 hs_err），
    // 让“无报告死亡”场景的现场数据随一次分享全部带出
    NSString *home = @(getenv("POJAV_HOME") ?: "");
    if (home.length > 0) {
        NSString *tracePath = [home stringByAppendingPathComponent:@"fatal_trace.txt"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:tracePath]) {
            [items addObject:[NSURL fileURLWithPath:tracePath]];
        }
        NSError *dirErr = nil;
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:home error:&dirErr];
        NSString *best = nil; NSDate *bestDate = nil;
        for (NSString *f in files) {
            if (![f hasPrefix:@"hs_err_pid"] || ![f hasSuffix:@".log"]) continue;
            NSString *p = [home stringByAppendingPathComponent:f];
            NSDate *d = [[NSFileManager defaultManager] attributesOfItemAtPath:p error:nil][NSFileModificationDate];
            if (!bestDate || [d compare:bestDate] == NSOrderedDescending) { best = p; bestDate = d; }
        }
        if (best) [items addObject:[NSURL fileURLWithPath:best]];
    }

    UIActivityViewController *activityVC = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];

    activityVC.popoverPresentationController.sourceView = self.view;
    activityVC.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:activityVC animated:YES completion:nil];
}

- (void)showFullLog {
    // ★ Task263（反馈 2 装机实证："点击查看日志详细按钮会退出到桌面，
    //   打开 app 发现在等待 mc 启动画面"）：旧实现转调 PLLogOutputView
    //   actionToggleLogOutput —— 该方法带上游 fatal 语义（fatalErrorOccurred
    //   时 [UIApplication suspend] + dispatch_group_leave）：suspend 把 app
    //   送回桌面，leave 唤醒 handle_fatal_exit 的 park 线程继续 orig_exit
    //   终结进程 = 点"查看日志详情"得到退到桌面；重开时残留会话停在
    //   启动等待画面。Task275 的先 dismiss 再 toggle 修了"点了没反应"，
    //   但 fatal suspend 死路仍在。根修：不再触碰 PLLogOutputView，改为
    //   崩溃页内自展开（日志卡定高 → 近全屏 + 完整日志尾部，按钮变
    //   "收起日志"），两个问题一起根除。
    self.ame263_logExpanded = !self.ame263_logExpanded;
    [self ame263_applyLogExpansion];
}

/// ★ Task263：日志卡展开/收起（高度动画 + 完整日志装载 + 按钮文案切换）。
///   展开态由本方法独占 logCardHeightConstraint 控制权（viewDidLayoutSubviews
///   已加守卫），高度不再被布局回写打回定高。
- (void)ame263_applyLogExpansion {
    BOOL expand = self.ame263_logExpanded;
    CGFloat target = expand
        ? MAX(self.view.bounds.size.height * 0.72, 420.0)
        : [self ame263_baseLogCardHeight];
    self.logCardHeightConstraint.constant = target;
    // ★ Task263 ⑥：双 localize 直调（不写三元内联——三元式调用曾逃过
    //   task248 闸1 静态扫描，crash.collapse_log 一度从未入表）。
    NSString *ame263_buttonTitle = expand
        ? localize(@"crash.collapse_log", @"收起日志")
        : localize(@"crash.view_log", @"查看日志详情");
    [_fullLogButton setTitle:ame263_buttonTitle forState:UIControlStateNormal];
    if (expand) {
        [self ame263_loadFullLogContent];
    } else {
        [self loadLogContent];   // 收起恢复摘要（尾读 150 行 + fatal_trace 尾）
    }
    [UIView animateWithDuration:0.25 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseInOut
                     animations:^{ [self.view layoutIfNeeded]; } completion:nil];
    // 展开后滚到底部（最新日志在尾部）
    if (expand && self.logTextView.text.length > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.logTextView scrollRangeToVisible:NSMakeRange(self.logTextView.text.length, 0)];
        });
    }
    NSLog(@"[PLCrashView] Task263: full log %s (in-place, no suspend path)", expand ? "expanded" : "collapsed");
}

/// ★ Task263：完整日志装载（展开态）：latestlog 尾窗 256KB + fatal_trace
///   全量 + hs_err 头 4KB（复用 Task274 ame274_readFileTail 尾读与
///   +fatalEvidenceText 同源证据链——主线程点按钮不做数 MB 整读）。
- (void)ame263_loadFullLogContent {
    NSMutableString *out = [NSMutableString string];
    NSString *latestlogPath = [NSString stringWithFormat:@"%s/latestlog.txt", getenv("POJAV_HOME")];
    NSString *logContent = ame274_readFileTail(latestlogPath, 256 * 1024);
    if (logContent.length > 0) {
        NSArray *lines = [logContent componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:latestlogPath error:nil];
        NSUInteger firstIdx = (attrs && [attrs fileSize] > 256 * 1024) ? 1 : 0;   // 尾窗首行截断残行裁掉
        [out appendString:@"----- latestlog.txt (tail) -----\n"];
        for (NSUInteger i = firstIdx; i < lines.count; i++) {
            [out appendFormat:@"%@\n", lines[i]];
        }
    } else {
        [out appendString:@"(latestlog.txt 为空或不可读)\n"];   // task250 口径：不裸上键名
    }
    // fatal_trace.txt 全量 + 最新 hs_err 头 4KB（与 readLatestLogForAnalysis 同源）
    NSString *extra = [PLCrashView fatalEvidenceText];
    if (extra.length > 0) {
        [out appendString:extra];
    }
    self.logTextView.text = out;
    _logPlaceholderLabel.hidden = out.length > 0;
}

- (void)openGitHubIssues {
    NSURL *url = [NSURL URLWithString:kGitHubIssuesURL];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

/// 退出启动器：直接 exit(0) 退出进程，不重启应用。
///
/// 关键修复：之前"退出启动器"按钮调用 dismissAndReturnToLauncher，
/// 该方法仅返回启动器主界面（不退出进程），与"重启启动器"按钮效果一样
/// （都是回到启动器）。用户反馈两个按钮功能相同，不符合 FCL 行为。
///
/// FCL 的行为：
///   - 重启启动器 = exit(0) + relaunch（重新拉起应用）
///   - 退出启动器 = exit(0)（直接退出，不重启）
///
/// 现在此方法直接调用 exit(0) 退出进程，不进行 relaunch。
- (void)exitLauncherAction {
    NSLog(@"[PLCrashView] User tapped exit launcher, exiting process directly");
    // 先清理崩溃界面
    if (currentCrashVC) {
        [currentCrashVC dismissViewControllerAnimated:NO completion:nil];
        currentCrashVC = nil;
    }
    // 通知 SurfaceViewController 释放游戏资源
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }
    // 直接退出进程，不重启
    exit(0);
}

- (void)dismissAndReturnToLauncher {
    // 调用 PLLogOutputView 的返回逻辑
    if ([SurfaceViewController currentInstance]) {
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }

    [self dismissViewControllerAnimated:YES completion:^{
        currentCrashVC = nil;
        // ★ Task273：用户主动关闭崩溃界面握手 —— 看门狗读后即刻 _exit。
        ame273_crashViewDidDismiss();
    }];
}

/// 重启启动器按钮的实例回调，委托给类方法 +restartLauncher
- (void)restartLauncherAction {
    [PLCrashView restartLauncher];
}

#pragma mark - Class Methods for External Callers

/// 类方法：隐藏崩溃界面并返回启动器。
/// 供外部 VC 安全调用，避免直接对类对象 performSelector 实例方法导致的崩溃。
+ (void)dismissAndReturnToLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (currentCrashVC) {
            [currentCrashVC dismissAndReturnToLauncher];
        } else if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }
    });
}

/// 重启启动器：清理崩溃界面与游戏 surface，通过 exit(0) + relaunch 触发系统重启。
/// 参照 FCL 的"重启软件"按钮：很多崩溃是临时加载失败，重启即可解决。
+ (void)restartLauncher {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 清理崩溃界面
        if (currentCrashVC) {
            [currentCrashVC dismissViewControllerAnimated:NO completion:nil];
            currentCrashVC = nil;
        }

        // 2. 通知 SurfaceViewController 释放游戏资源
        if ([SurfaceViewController currentInstance]) {
            [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
        }

        // 3. 通过 NSURL relaunch 触发系统重新拉起应用（TrollStore/越狱环境支持）
        //    若 relaunch 失败则回退到 exit(0)，系统在 10 秒内会重新唤起前台 App
        NSString *bundlePath = [NSBundle mainBundle].bundlePath;
        NSURL *appURL = [NSURL fileURLWithPath:bundlePath];
        NSLog(@"[PLCrashView] Restarting launcher from %@", bundlePath);

        // 尝试通过 openURL 拉起（需要 UIApplication.openURL，越狱/TrollStore 可用）
        if (@available(iOS 10.0, *)) {
            [[UIApplication sharedApplication] openURL:appURL
                                               options:@{}
                                     completionHandler:^(BOOL success) {
                if (!success) {
                    NSLog(@"[PLCrashView] openURL failed, falling back to exit(0)");
                }
                // 无论如何都退出当前进程，让系统重新拉起
                exit(0);
            }];
        } else {
            exit(0);
        }
    });
}

@end
