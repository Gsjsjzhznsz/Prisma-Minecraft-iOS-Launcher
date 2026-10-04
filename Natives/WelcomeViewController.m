//
//  WelcomeViewController.m
//  Amethyst
//
//  Task218：首次使用欢迎向导实现。动效清单（用户指令"动画和视觉要做足"）：
//   - 全屏动画渐变背景（Prisma 紫蓝家族，颜色+位置双回路缓慢呼吸）
//   - CAEmitter 粒子层（微光上浮气泡，Hero 与完成页双配置）
//   - 步骤切换：旧内容左滑淡出 + 新内容右侧弹入（弹簧阻尼）
//   - 进度圆点：选中放大着色 + 未选中缩小灰阶，切换带弹性
//   - 选项卡：选中描边 + 勾选徽标弹入 + 轻微缩放脉冲
//   - 完成页：礼花彩带（CAEmitter 一次爆发生效）+ 大号对勾弹簧入场
//

#import "WelcomeViewController.h"
#import "LauncherPreferences.h"
#import "PLMirrorCenter.h"
#import "DataTransferService.h"
#import "UIKit+NativeSurface.h"
#import "utils.h"
#import <objc/runtime.h>

/// 步骤总数（Hero / 语言 / 下载源 / 数据迁移 / 完成）。
static const NSInteger ame218_welcomeStepCount = 5;

@interface WelcomeViewController ()
/// 动画渐变背景层。
@property (nonatomic, strong) CAGradientLayer *gradientLayer;
/// 粒子层（微光气泡 / 完成页礼花复用同层切配置）。
@property (nonatomic, strong) CAEmitterLayer *emitterLayer;
/// 步骤指示圆点（StepCount 个）。
@property (nonatomic, strong) NSMutableArray<UIView *> *stepDots;
/// 当前内容容器（每步重建内容并做转场）。
@property (nonatomic, strong) UIView *contentView;
/// 底部主按钮（下一步 / 开始使用）。
@property (nonatomic, strong) UIButton *primaryButton;
/// 底部次按钮（跳过）。
@property (nonatomic, strong) UIButton *secondaryButton;
/// 当前步骤索引。
@property (nonatomic, assign) NSInteger stepIndex;
/// 语言选择值（system / zh-Hans / zh-Hant / en；完成时落键）。
@property (nonatomic, copy) NSString *pickedLanguage;
/// 下载源选择值（official_first / mirror_first / speed_first；即时落键）。
@property (nonatomic, copy) NSString *pickedSource;
/// 是否在向导里改过语言（完成 dismissal 后补发 AppLanguageChanged）。
@property (nonatomic, assign) BOOL languageChanged;
/// 语言选项按钮（选中态切换用）。
@property (nonatomic, strong) NSMutableArray<UIButton *> *langButtons;
/// 下载源选项卡片（选中态切换用）。
@property (nonatomic, strong) NSMutableArray<UIView *> *sourceCards;
@end

@implementation WelcomeViewController

#pragma mark - 便捷入口

+ (void)presentIfNeededFromViewController:(UIViewController *)presenter {
    if (getPrefBool(@"general.welcome_completed")) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (getPrefBool(@"general.welcome_completed")) return;
        if (!presenter || presenter.presentedViewController != nil) return;
        WelcomeViewController *ame218_welcome = [[WelcomeViewController alloc] init];
        ame218_welcome.modalPresentationStyle = UIModalPresentationFullScreen;
        ame218_welcome.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        [presenter presentViewController:ame218_welcome animated:YES completion:nil];
    });
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    // 语言初值：跟随当前存储（system 默认）
    NSString *ame218_lang = getPrefObject(@"general.app_language");
    self.pickedLanguage = [ame218_lang isKindOfClass:[NSString class]] ? ame218_lang : @"system";
    // 下载源初值：当前生效策略（粗控口径读 assetDownloadSource，兜底 speed_first）
    NSString *ame218_src = getPrefObject(@"download.assetDownloadSource");
    if (![ame218_src isKindOfClass:[NSString class]] ||
        (![ame218_src isEqualToString:@"official_first"] &&
         ![ame218_src isEqualToString:@"mirror_first"] &&
         ![ame218_src isEqualToString:@"speed_first"])) {
        ame218_src = @"speed_first";
    }
    self.pickedSource = ame218_src;

    [self ame218_buildAnimatedBackground];
    [self ame218_buildChrome];
    [self ame218_showStep:0 animated:NO];
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

#pragma mark - 动画背景（渐变 + 粒子）

- (void)ame218_buildAnimatedBackground {
    // Prisma 紫蓝家族渐变（深底，内容白字）
    self.gradientLayer = [CAGradientLayer layer];
    self.gradientLayer.frame = self.view.bounds;
    self.gradientLayer.colors = @[
        (__bridge id)[UIColor colorWithRed:0.16 green:0.10 blue:0.34 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.24 green:0.18 blue:0.52 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.12 green:0.30 blue:0.55 alpha:1.0].CGColor,
    ];
    self.gradientLayer.locations = @[@0.0, @0.55, @1.0];
    self.gradientLayer.startPoint = CGPointMake(0.0, 0.0);
    self.gradientLayer.endPoint = CGPointMake(1.0, 1.0);
    [self.view.layer insertSublayer:self.gradientLayer atIndex:0];

    // 呼吸回路一：位置缓慢往返（8s 周期）
    CABasicAnimation *ame218_loc = [CABasicAnimation animationWithKeyPath:@"locations"];
    ame218_loc.fromValue = @[@0.0, @0.55, @1.0];
    ame218_loc.toValue = @[@0.15, @0.75, @1.0];
    ame218_loc.duration = 8.0;
    ame218_loc.autoreverses = YES;
    ame218_loc.repeatCount = HUGE_VALF;
    ame218_loc.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.gradientLayer addAnimation:ame218_loc forKey:@"ame218_locations"];

    // 呼吸回路二：中段色相微移（11s 周期，与位置回路错拍避免机械感）
    CABasicAnimation *ame218_col = [CABasicAnimation animationWithKeyPath:@"colors"];
    ame218_col.fromValue = self.gradientLayer.colors;
    ame218_col.toValue = @[
        (__bridge id)[UIColor colorWithRed:0.13 green:0.12 blue:0.38 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.28 green:0.16 blue:0.46 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.10 green:0.34 blue:0.50 alpha:1.0].CGColor,
    ];
    ame218_col.duration = 11.0;
    ame218_col.autoreverses = YES;
    ame218_col.repeatCount = HUGE_VALF;
    ame218_col.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.gradientLayer addAnimation:ame218_col forKey:@"ame218_colors"];

    // 粒子层：微光气泡自底部缓升（低密度、低透明度——氛围而非喧宾夺主）
    self.emitterLayer = [CAEmitterLayer layer];
    self.emitterLayer.frame = self.view.bounds;
    self.emitterLayer.emitterPosition = CGPointMake(self.view.bounds.size.width / 2.0,
                                                    self.view.bounds.size.height + 40);
    self.emitterLayer.emitterSize = CGSizeMake(self.view.bounds.size.width * 1.2, 10);
    self.emitterLayer.emitterShape = kCAEmitterLayerLine;
    self.emitterLayer.renderMode = kCAEmitterLayerOldestFirst;
    [self ame218_configureBubbleEmitter];
    [self.view.layer insertSublayer:self.emitterLayer above:self.gradientLayer];
}

- (void)ame218_configureBubbleEmitter {
    CAEmitterCell *ame218_cell = [CAEmitterCell emitterCell];
    ame218_cell.scale = 0.10;
    ame218_cell.scaleRange = 0.18;
    ame218_cell.color = [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.45].CGColor;
    ame218_cell.alphaRange = 0.30;
    ame218_cell.lifetime = 14.0;
    ame218_cell.lifetimeRange = 6.0;
    ame218_cell.birthRate = 7.0;
    ame218_cell.velocity = 26.0;
    ame218_cell.velocityRange = 16.0;
    ame218_cell.yAcceleration = -4.0;
    ame218_cell.emissionLongitude = (CGFloat)(-M_PI / 2.0);
    ame218_cell.emissionRange = (CGFloat)M_PI;
    ame218_cell.spin = 0.4;
    ame218_cell.spinRange = 0.8;
    self.emitterLayer.emitterCells = @[ame218_cell];
}

- (void)ame218_fireConfettiBurst {
    // 完成页礼花：一次性密集迸发（birthRate 置零前先跑足 2.4s）
    CAEmitterCell *ame218_confetti = [CAEmitterCell emitterCell];
    ame218_confetti.scale = 0.16;
    ame218_confetti.scaleRange = 0.22;
    ame218_confetti.color = [UIColor colorWithRed:1.0 green:0.92 blue:0.70 alpha:1.0].CGColor;
    ame218_confetti.alphaRange = 0.25;
    ame218_confetti.alphaSpeed = -0.35;
    ame218_confetti.lifetime = 4.5;
    ame218_confetti.lifetimeRange = 1.5;
    ame218_confetti.birthRate = 90.0;
    ame218_confetti.velocity = 340.0;
    ame218_confetti.velocityRange = 200.0;
    ame218_confetti.yAcceleration = 190.0;
    ame218_confetti.emissionLongitude = (CGFloat)M_PI;      // 朝上
    ame218_confetti.emissionRange = (CGFloat)M_PI;
    ame218_confetti.spin = 3.0;
    ame218_confetti.spinRange = 5.0;
    self.emitterLayer.emitterPosition = CGPointMake(self.view.bounds.size.width / 2.0,
                                                    self.view.bounds.size.height * 0.68);
    self.emitterLayer.emitterCells = @[ame218_confetti];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        // 礼花熄灭后回到氛围气泡
        [self ame218_configureBubbleEmitter];
        self.emitterLayer.emitterPosition = CGPointMake(self.view.bounds.size.width / 2.0,
                                                        self.view.bounds.size.height + 40);
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.gradientLayer.frame = self.view.bounds;
    self.emitterLayer.frame = self.view.bounds;
}

#pragma mark - 骨架（圆点 + 内容容器 + 底部按钮）

- (void)ame218_buildChrome {
    // 进度圆点
    self.stepDots = [NSMutableArray array];
    UIStackView *ame218_dotRow = [[UIStackView alloc] init];
    ame218_dotRow.axis = UILayoutConstraintAxisHorizontal;
    ame218_dotRow.spacing = 10;
    ame218_dotRow.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:ame218_dotRow];
    for (NSInteger i = 0; i < ame218_welcomeStepCount; i++) {
        UIView *ame218_dot = [[UIView alloc] init];
        ame218_dot.layer.cornerRadius = 4;
        ame218_dot.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.30];
        ame218_dot.translatesAutoresizingMaskIntoConstraints = NO;
        [ame218_dotRow addArrangedSubview:ame218_dot];
        [ame218_dot.widthAnchor constraintEqualToConstant:8].active = YES;
        [ame218_dot.heightAnchor constraintEqualToConstant:8].active = YES;
        [self.stepDots addObject:ame218_dot];
    }

    // 内容容器
    self.contentView = [[UIView alloc] init];
    self.contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentView];

    // 主按钮
    self.primaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.primaryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.primaryButton.backgroundColor = accentColor();
    self.primaryButton.layer.cornerRadius = 22;
    self.primaryButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.primaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.primaryButton addTarget:self action:@selector(ame218_primaryTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.primaryButton];

    // 次按钮（跳过）
    self.secondaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.secondaryButton setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.75] forState:UIControlStateNormal];
    self.secondaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.secondaryButton addTarget:self action:@selector(ame218_finish)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.secondaryButton];

    NSLayoutConstraint *ame218_primaryHeight = [self.primaryButton.heightAnchor constraintEqualToConstant:50];
    ame218_primaryHeight.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [ame218_dotRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:22],
        [ame218_dotRow.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [self.contentView.topAnchor constraintEqualToAnchor:ame218_dotRow.bottomAnchor constant:18],
        [self.contentView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [self.contentView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [self.contentView.bottomAnchor constraintEqualToAnchor:self.secondaryButton.topAnchor constant:-16],

        [self.primaryButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [self.primaryButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [self.primaryButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-18],
        [self.primaryButton.heightAnchor constraintEqualToConstant:50],

        [self.secondaryButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.secondaryButton.bottomAnchor constraintEqualToAnchor:self.primaryButton.topAnchor constant:-6],
        [self.secondaryButton.heightAnchor constraintEqualToConstant:34],
    ]];
}

/// 圆点状态刷新（选中放大着色 + 弹性动画）。
- (void)ame218_updateDots {
    for (NSInteger i = 0; i < self.stepDots.count; i++) {
        UIView *ame218_dot = self.stepDots[i];
        BOOL ame218_sel = (i == self.stepIndex);
        [UIView animateWithDuration:0.45 delay:0
         usingSpringWithDamping:0.6 initialSpringVelocity:0.5 options:0
                        animations:^{
            ame218_dot.backgroundColor = ame218_sel
                ? [UIColor whiteColor]
                : [UIColor colorWithWhite:1.0 alpha:0.30];
            ame218_dot.transform = ame218_sel
                ? CGAffineTransformMakeScale(1.55, 1.55)
                : CGAffineTransformIdentity;
        } completion:nil];
    }
}

#pragma mark - 步骤切换（旧内容左滑淡出 + 新内容右侧弹入）

- (void)ame218_showStep:(NSInteger)index animated:(BOOL)animated {
    self.stepIndex = index;
    [self ame218_updateDots];

    // 按钮文案与可见性
    BOOL ame218_last = (index == ame218_welcomeStepCount - 1);
    [self.primaryButton setTitle:localize(ame218_last ? @"welcome.done.start" : @"welcome.next", nil)
                        forState:UIControlStateNormal];
    [self.secondaryButton setTitle:localize(ame218_last ? @"" : @"welcome.skip", nil)
                          forState:UIControlStateNormal];
    self.secondaryButton.hidden = ame218_last;

    UIView *ame218_old = self.contentView;
    // 重建内容容器（新内容独立于旧容器做入场动画）
    UIView *ame218_new = [[UIView alloc] init];
    ame218_new.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view insertSubview:ame218_new belowSubview:self.stepDots.firstObject.superview];
    [NSLayoutConstraint activateConstraints:@[
        [ame218_new.topAnchor constraintEqualToAnchor:ame218_old.topAnchor],
        [ame218_new.leadingAnchor constraintEqualToAnchor:ame218_old.leadingAnchor],
        [ame218_new.trailingAnchor constraintEqualToAnchor:ame218_old.trailingAnchor],
        [ame218_new.bottomAnchor constraintEqualToAnchor:ame218_old.bottomAnchor],
    ]];
    self.contentView = ame218_new;

    switch (index) {
        case 0: [self ame218_buildHeroStep:ame218_new]; break;
        case 1: [self ame218_buildLanguageStep:ame218_new]; break;
        case 2: [self ame218_buildSourceStep:ame218_new]; break;
        case 3: [self ame218_buildDataStep:ame218_new]; break;
        case 4: [self ame218_buildDoneStep:ame218_new]; break;
    }

    if (!animated) {
        [ame218_old removeFromSuperview];
        return;
    }

    // 入场：从右侧 44pt 弹入 + 淡入
    ame218_new.transform = CGAffineTransformMakeTranslation(44, 0);
    ame218_new.alpha = 0;
    [UIView animateWithDuration:0.55 delay:0
     usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                    options:UIViewAnimationOptionBeginFromCurrentState
                 animations:^{
        ame218_new.transform = CGAffineTransformIdentity;
        ame218_new.alpha = 1;
    } completion:nil];
    // 出场：向左滑出 + 淡出
    [UIView animateWithDuration:0.32 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        ame218_old.transform = CGAffineTransformMakeTranslation(-36, 0);
        ame218_old.alpha = 0;
    } completion:^(BOOL finished) {
        [ame218_old removeFromSuperview];
    }];
}

- (void)ame218_primaryTapped {
    // 按钮按压反馈
    [UIView animateWithDuration:0.08 animations:^{
        self.primaryButton.transform = CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.30 delay:0
         usingSpringWithDamping:0.55 initialSpringVelocity:0.5 options:0
                        animations:^{
            self.primaryButton.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
    if (self.stepIndex >= ame218_welcomeStepCount - 1) {
        [self ame218_finish];
    } else {
        // 语言步进前先把选择落键（即时生效文案基准，但根视图留到完成时重建）
        if (self.stepIndex == 1) {
            setPrefObject(@"general.app_language", self.pickedLanguage ?: @"system");
        }
        [self ame218_showStep:self.stepIndex + 1 animated:YES];
    }
}

/// 完成/跳过：置哨兵 → dismiss → 语言变更后补发根视图重建。
- (void)ame218_finish {
    setPrefObject(@"general.welcome_completed", @YES);
    BOOL ame218_langChanged = self.languageChanged;
    [self dismissViewControllerAnimated:YES completion:^{
        if (ame218_langChanged) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"AppLanguageChanged"
                                                                object:self.pickedLanguage ?: @"system"];
        }
    }];
}

#pragma mark - 步骤内容：0 Hero

- (void)ame218_buildHeroStep:(UIView *)container {
    UIView *ame218_center = [[UIView alloc] init];
    ame218_center.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_center];

    // 应用图标（弹入 + 光晕；无 AppIcon 资源时回退 SF Symbol）
    UIImageView *ame218_icon = [[UIImageView alloc] init];
    UIImage *ame218_appIcon = [UIImage imageNamed:@"AppIcon-Light"];
    if (ame218_appIcon == nil) {
        ame218_appIcon = [UIImage systemImageNamed:@"cube.fill"];
    }
    ame218_icon.image = ame218_appIcon;
    ame218_icon.contentMode = UIViewContentModeScaleAspectFit;
    ame218_icon.layer.cornerRadius = 24;
    ame218_icon.layer.cornerCurve = kCACornerCurveContinuous;
    ame218_icon.layer.masksToBounds = YES;
    ame218_icon.layer.shadowColor = [UIColor colorWithRed:0.55 green:0.55 blue:1.0 alpha:1.0].CGColor;
    ame218_icon.layer.shadowOpacity = 0.55;
    ame218_icon.layer.shadowRadius = 26;
    ame218_icon.layer.shadowOffset = CGSizeZero;
    ame218_icon.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_icon];

    UILabel *ame218_name = [[UILabel alloc] init];
    NSDictionary *ame218_info = NSBundle.mainBundle.infoDictionary;
    ame218_name.text = ame218_info[@"CFBundleDisplayName"] ?: @"Prisma";
    ame218_name.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    ame218_name.textColor = [UIColor whiteColor];
    ame218_name.textAlignment = NSTextAlignmentCenter;
    ame218_name.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_name];

    UILabel *ame218_version = [[UILabel alloc] init];
    ame218_version.text = [NSString stringWithFormat:@"v%@",
        ame218_info[@"CFBundleShortVersionString"] ?: @"6.5.0"];
    ame218_version.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    ame218_version.textColor = [UIColor colorWithWhite:1.0 alpha:0.72];
    ame218_version.textAlignment = NSTextAlignmentCenter;
    ame218_version.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_version];

    UILabel *ame218_tagline = [[UILabel alloc] init];
    ame218_tagline.text = localize(@"welcome.hero.subtitle", nil);
    ame218_tagline.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    ame218_tagline.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    ame218_tagline.textAlignment = NSTextAlignmentCenter;
    ame218_tagline.numberOfLines = 0;
    ame218_tagline.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_tagline];

    [NSLayoutConstraint activateConstraints:@[
        [ame218_center.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [ame218_center.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [ame218_center.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_center.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [ame218_icon.centerXAnchor constraintEqualToAnchor:ame218_center.centerXAnchor],
        [ame218_icon.topAnchor constraintEqualToAnchor:ame218_center.topAnchor],
        [ame218_icon.widthAnchor constraintEqualToConstant:104],
        [ame218_icon.heightAnchor constraintEqualToConstant:104],

        [ame218_name.topAnchor constraintEqualToAnchor:ame218_icon.bottomAnchor constant:22],
        [ame218_name.centerXAnchor constraintEqualToAnchor:ame218_center.centerXAnchor],

        [ame218_version.topAnchor constraintEqualToAnchor:ame218_name.bottomAnchor constant:6],
        [ame218_version.centerXAnchor constraintEqualToAnchor:ame218_center.centerXAnchor],

        [ame218_tagline.topAnchor constraintEqualToAnchor:ame218_version.bottomAnchor constant:14],
        [ame218_tagline.leadingAnchor constraintEqualToAnchor:ame218_center.leadingAnchor constant:16],
        [ame218_tagline.trailingAnchor constraintEqualToAnchor:ame218_center.trailingAnchor constant:-16],
        [ame218_tagline.bottomAnchor constraintEqualToAnchor:ame218_center.bottomAnchor],
    ]];

    // 图标弹簧入场（缩放 0.4 -> 1.06 -> 1.0 的过冲）
    ame218_icon.transform = CGAffineTransformMakeScale(0.4, 0.4);
    ame218_icon.alpha = 0;
    [UIView animateWithDuration:0.7 delay:0.1
     usingSpringWithDamping:0.58 initialSpringVelocity:0.35 options:0
                    animations:^{
        ame218_icon.transform = CGAffineTransformMakeScale(1.06, 1.06);
        ame218_icon.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.32 delay:0
         usingSpringWithDamping:0.7 initialSpringVelocity:0.3 options:0
                        animations:^{
            ame218_icon.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
    // 文本阶梯淡入
    ame218_name.alpha = 0; ame218_version.alpha = 0; ame218_tagline.alpha = 0;
    [UIView animateWithDuration:0.5 delay:0.35 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        ame218_name.alpha = 1; ame218_version.alpha = 1; ame218_tagline.alpha = 1;
    } completion:nil];
}

#pragma mark - 步骤内容：1 语言

- (void)ame218_buildLanguageStep:(UIView *)container {
    UILabel *ame218_title = [[UILabel alloc] init];
    ame218_title.text = localize(@"welcome.lang.title", nil);
    ame218_title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    ame218_title.textColor = [UIColor whiteColor];
    ame218_title.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_title];

    UILabel *ame218_sub = [[UILabel alloc] init];
    ame218_sub.text = localize(@"welcome.lang.subtitle", nil);
    ame218_sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    ame218_sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    ame218_sub.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_sub];

    UIStackView *ame218_grid = [[UIStackView alloc] init];
    ame218_grid.axis = UILayoutConstraintAxisVertical;
    ame218_grid.spacing = 12;
    ame218_grid.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_grid];

    self.langButtons = [NSMutableArray array];
    NSArray<NSString *> *ame218_codes = @[@"system", @"zh-Hans", @"zh-Hant", @"en"];
    NSArray<NSString *> *ame218_labels = @[
        localize(@"i18n_str_382", nil),   // 跟随系统（复用语言行同键）
        @"简体中文",
        @"繁體中文",
        @"English",
    ];
    for (NSUInteger i = 0; i < ame218_codes.count; i++) {
        UIButton *ame218_btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [ame218_btn setTitle:ame218_labels[i] forState:UIControlStateNormal];
        [ame218_btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        ame218_btn.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
        ame218_btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        ame218_btn.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 18);
        ame218_btn.layer.cornerRadius = 16;
        ame218_btn.layer.cornerCurve = kCACornerCurveContinuous;
        ame218_btn.layer.borderWidth = 1.5;
        ame218_btn.translatesAutoresizingMaskIntoConstraints = NO;
        [ame218_btn addTarget:self action:@selector(ame218_langPicked:)
           forControlEvents:UIControlEventTouchUpInside];
        ame218_btn.tag = (NSInteger)i;
        [ame218_grid addArrangedSubview:ame218_btn];
        [ame218_btn.heightAnchor constraintEqualToConstant:52].active = YES;
        [self.langButtons addObject:ame218_btn];
    }

    UILabel *ame218_more = [[UILabel alloc] init];
    ame218_more.text = localize(@"welcome.lang.more", nil);
    ame218_more.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    ame218_more.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    ame218_more.numberOfLines = 0;
    ame218_more.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_more];

    [NSLayoutConstraint activateConstraints:@[
        [ame218_title.topAnchor constraintEqualToAnchor:container.topAnchor constant:26],
        [ame218_title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [ame218_sub.topAnchor constraintEqualToAnchor:ame218_title.bottomAnchor constant:6],
        [ame218_sub.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [ame218_grid.topAnchor constraintEqualToAnchor:ame218_sub.bottomAnchor constant:22],
        [ame218_grid.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_grid.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [ame218_more.topAnchor constraintEqualToAnchor:ame218_grid.bottomAnchor constant:14],
        [ame218_more.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:4],
        [ame218_more.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-4],
    ]];

    [self ame218_refreshLangButtons];
}

- (void)ame218_langPicked:(UIButton *)sender {
    NSArray<NSString *> *ame218_codes = @[@"system", @"zh-Hans", @"zh-Hant", @"en"];
    self.pickedLanguage = ame218_codes[(NSUInteger)sender.tag];
    self.languageChanged = YES;
    [self ame218_refreshLangButtons];
}

- (void)ame218_refreshLangButtons {
    NSArray<NSString *> *ame218_codes = @[@"system", @"zh-Hans", @"zh-Hant", @"en"];
    for (NSUInteger i = 0; i < self.langButtons.count; i++) {
        UIButton *ame218_btn = self.langButtons[i];
        BOOL ame218_sel = [self.pickedLanguage isEqualToString:ame218_codes[i]];
        [UIView animateWithDuration:0.30 delay:0
         usingSpringWithDamping:0.65 initialSpringVelocity:0.4 options:0
                        animations:^{
            ame218_btn.backgroundColor = ame218_sel
                ? [UIColor colorWithWhite:1.0 alpha:0.16]
                : [UIColor colorWithWhite:1.0 alpha:0.07];
            ame218_btn.layer.borderColor = ame218_sel
                ? [UIColor whiteColor].CGColor
                : [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
            ame218_btn.transform = ame218_sel
                ? CGAffineTransformMakeScale(1.02, 1.02)
                : CGAffineTransformIdentity;
        } completion:nil];
    }
}

#pragma mark - 步骤内容：2 下载源

- (void)ame218_buildSourceStep:(UIView *)container {
    UILabel *ame218_title = [[UILabel alloc] init];
    ame218_title.text = localize(@"welcome.source.title", nil);
    ame218_title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    ame218_title.textColor = [UIColor whiteColor];
    ame218_title.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_title];

    UILabel *ame218_sub = [[UILabel alloc] init];
    ame218_sub.text = localize(@"welcome.source.subtitle", nil);
    ame218_sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    ame218_sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    ame218_sub.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_sub];

    UIStackView *ame218_stack = [[UIStackView alloc] init];
    ame218_stack.axis = UILayoutConstraintAxisVertical;
    ame218_stack.spacing = 12;
    ame218_stack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_stack];

    self.sourceCards = [NSMutableArray array];
    NSArray<NSString *> *ame218_values = @[@"official_first", @"mirror_first", @"speed_first"];
    NSArray<NSString *> *ame218_names = @[
        localize(@"preference.title.mirror_policy-official_first", nil),
        localize(@"preference.title.mirror_policy-mirror_first", nil),
        localize(@"preference.title.mirror_policy-speed_first", nil),
    ];
    NSArray<NSString *> *ame218_descs = @[
        localize(@"welcome.source.official.desc", nil),
        localize(@"welcome.source.mirror.desc", nil),
        localize(@"welcome.source.speed.desc", nil),
    ];
    NSArray<NSString *> *ame218_icons = @[@"globe", @"bolt.horizontal", @"speedometer"];

    for (NSUInteger i = 0; i < ame218_values.count; i++) {
        UIView *ame218_card = [[UIView alloc] init];
        ame218_card.layer.cornerRadius = 16;
        ame218_card.layer.cornerCurve = kCACornerCurveContinuous;
        ame218_card.layer.borderWidth = 1.5;
        ame218_card.translatesAutoresizingMaskIntoConstraints = NO;

        UIImageView *ame218_icon = [[UIImageView alloc] init];
        ame218_icon.image = [UIImage systemImageNamed:ame218_icons[i]];
        ame218_icon.tintColor = [UIColor whiteColor];
        ame218_icon.contentMode = UIViewContentModeScaleAspectFit;
        ame218_icon.translatesAutoresizingMaskIntoConstraints = NO;
        [ame218_card addSubview:ame218_icon];

        UILabel *ame218_name = [[UILabel alloc] init];
        ame218_name.text = ame218_names[i];
        ame218_name.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        ame218_name.textColor = [UIColor whiteColor];
        ame218_name.translatesAutoresizingMaskIntoConstraints = NO;
        [ame218_card addSubview:ame218_name];

        UILabel *ame218_desc = [[UILabel alloc] init];
        ame218_desc.text = ame218_descs[i];
        ame218_desc.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        ame218_desc.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
        ame218_desc.numberOfLines = 0;
        ame218_desc.translatesAutoresizingMaskIntoConstraints = NO;
        [ame218_card addSubview:ame218_desc];

        [ame218_stack addArrangedSubview:ame218_card];
        [ame218_card.heightAnchor constraintEqualToConstant:74].active = YES;

        [NSLayoutConstraint activateConstraints:@[
            [ame218_icon.leadingAnchor constraintEqualToAnchor:ame218_card.leadingAnchor constant:16],
            [ame218_icon.centerYAnchor constraintEqualToAnchor:ame218_card.centerYAnchor],
            [ame218_icon.widthAnchor constraintEqualToConstant:26],
            [ame218_icon.heightAnchor constraintEqualToConstant:26],

            [ame218_name.leadingAnchor constraintEqualToAnchor:ame218_icon.trailingAnchor constant:14],
            [ame218_name.topAnchor constraintEqualToAnchor:ame218_card.topAnchor constant:14],
            [ame218_name.trailingAnchor constraintEqualToAnchor:ame218_card.trailingAnchor constant:-12],

            [ame218_desc.leadingAnchor constraintEqualToAnchor:ame218_name.leadingAnchor],
            [ame218_desc.topAnchor constraintEqualToAnchor:ame218_name.bottomAnchor constant:3],
            [ame218_desc.trailingAnchor constraintEqualToAnchor:ame218_card.trailingAnchor constant:-12],
        ]];

        // 点击选择（卡片整体 + 手势；tag 用关联值存索引）
        objc_setAssociatedObject(ame218_card, "ame218.idx", @(i), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ame218_card.userInteractionEnabled = YES;
        UITapGestureRecognizer *ame218_tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(ame218_sourcePicked:)];
        [ame218_card addGestureRecognizer:ame218_tap];
        [self.sourceCards addObject:ame218_card];
    }

    [NSLayoutConstraint activateConstraints:@[
        [ame218_title.topAnchor constraintEqualToAnchor:container.topAnchor constant:26],
        [ame218_title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [ame218_sub.topAnchor constraintEqualToAnchor:ame218_title.bottomAnchor constant:6],
        [ame218_sub.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [ame218_stack.topAnchor constraintEqualToAnchor:ame218_sub.bottomAnchor constant:20],
        [ame218_stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];

    [self ame218_refreshSourceCards];
}

- (void)ame218_sourcePicked:(UITapGestureRecognizer *)gesture {
    UIView *ame218_card = gesture.view;
    NSNumber *ame218_idx = objc_getAssociatedObject(ame218_card, "ame218.idx");
    if (![ame218_idx isKindOfClass:NSNumber.class]) return;
    NSArray<NSString *> *ame218_values = @[@"official_first", @"mirror_first", @"speed_first"];
    self.pickedSource = ame218_values[(NSUInteger)ame218_idx.integerValue];
    [self ame218_applySourceSelection];
    [self ame218_refreshSourceCards];
}

/// 下载源选择即时落键：四个策略键同值（与设置页 mod_mirror 粗控同语义），
/// 并让测速引擎立即跟上（speed_first 时补测）。
- (void)ame218_applySourceSelection {
    NSArray<NSString *> *ame218_keys = @[
        @"download.fileSource",
        @"download.assetSearchSource",
        @"download.assetDownloadSource",
        @"download.modLoaderSource"
    ];
    for (NSString *ame218_key in ame218_keys) {
        setPrefObject(ame218_key, self.pickedSource);
    }
    [PLMirrorCenter startSpeedProbesIfNeeded];
    NSLog(@"[Welcome] Task218: download source set to %@ (4 policy keys)", self.pickedSource);
}

- (void)ame218_refreshSourceCards {
    NSArray<NSString *> *ame218_values = @[@"official_first", @"mirror_first", @"speed_first"];
    for (NSUInteger i = 0; i < self.sourceCards.count; i++) {
        UIView *ame218_card = self.sourceCards[i];
        BOOL ame218_sel = [self.pickedSource isEqualToString:ame218_values[i]];
        [UIView animateWithDuration:0.30 delay:0
         usingSpringWithDamping:0.65 initialSpringVelocity:0.4 options:0
                        animations:^{
            ame218_card.backgroundColor = ame218_sel
                ? [UIColor colorWithWhite:1.0 alpha:0.16]
                : [UIColor colorWithWhite:1.0 alpha:0.07];
            ame218_card.layer.borderColor = ame218_sel
                ? [UIColor whiteColor].CGColor
                : [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
            ame218_card.transform = ame218_sel
                ? CGAffineTransformMakeScale(1.02, 1.02)
                : CGAffineTransformIdentity;
        } completion:nil];
    }
}

#pragma mark - 步骤内容：3 数据迁移

- (void)ame218_buildDataStep:(UIView *)container {
    UILabel *ame218_title = [[UILabel alloc] init];
    ame218_title.text = localize(@"welcome.data.title", nil);
    ame218_title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    ame218_title.textColor = [UIColor whiteColor];
    ame218_title.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_title];

    UILabel *ame218_sub = [[UILabel alloc] init];
    ame218_sub.text = localize(@"welcome.data.subtitle", nil);
    ame218_sub.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
    ame218_sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.75];
    ame218_sub.numberOfLines = 0;
    ame218_sub.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_sub];

    // 主选项：从备份导入
    UIView *ame218_importCard = [self ame218_dataCardWithTitle:localize(@"welcome.data.import", nil)
                                                           desc:localize(@"welcome.data.import.desc", nil)
                                                           icon:@"square.and.arrow.down"];
    ame218_importCard.userInteractionEnabled = YES;
    UITapGestureRecognizer *ame218_importTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(ame218_importTapped:)];
    [ame218_importCard addGestureRecognizer:ame218_importTap];

    // 次选项：跳过
    UIView *ame218_skipCard = [self ame218_dataCardWithTitle:localize(@"welcome.data.skip", nil)
                                                        desc:localize(@"welcome.data.skip.desc", nil)
                                                        icon:@"arrow.right.circle"];
    ame218_skipCard.userInteractionEnabled = YES;
    UITapGestureRecognizer *ame218_skipTap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(ame218_dataSkipTapped:)];
    [ame218_skipCard addGestureRecognizer:ame218_skipTap];

    UIStackView *ame218_stack = [[UIStackView alloc] init];
    ame218_stack.axis = UILayoutConstraintAxisVertical;
    ame218_stack.spacing = 12;
    ame218_stack.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_stack addArrangedSubview:ame218_importCard];
    [ame218_stack addArrangedSubview:ame218_skipCard];
    [container addSubview:ame218_stack];

    [NSLayoutConstraint activateConstraints:@[
        [ame218_title.topAnchor constraintEqualToAnchor:container.topAnchor constant:26],
        [ame218_title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],

        [ame218_sub.topAnchor constraintEqualToAnchor:ame218_title.bottomAnchor constant:6],
        [ame218_sub.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_sub.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [ame218_stack.topAnchor constraintEqualToAnchor:ame218_sub.bottomAnchor constant:20],
        [ame218_stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];
}

- (UIView *)ame218_dataCardWithTitle:(NSString *)title desc:(NSString *)desc icon:(NSString *)iconName {
    UIView *ame218_card = [[UIView alloc] init];
    ame218_card.layer.cornerRadius = 16;
    ame218_card.layer.cornerCurve = kCACornerCurveContinuous;
    ame218_card.layer.borderWidth = 1.5;
    ame218_card.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.28].CGColor;
    ame218_card.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.07];
    ame218_card.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *ame218_icon = [[UIImageView alloc] init];
    ame218_icon.image = [UIImage systemImageNamed:iconName];
    ame218_icon.tintColor = [UIColor whiteColor];
    ame218_icon.contentMode = UIViewContentModeScaleAspectFit;
    ame218_icon.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_card addSubview:ame218_icon];

    UILabel *ame218_title = [[UILabel alloc] init];
    ame218_title.text = title;
    ame218_title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    ame218_title.textColor = [UIColor whiteColor];
    ame218_title.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_card addSubview:ame218_title];

    UILabel *ame218_desc = [[UILabel alloc] init];
    ame218_desc.text = desc;
    ame218_desc.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    ame218_desc.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
    ame218_desc.numberOfLines = 0;
    ame218_desc.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_card addSubview:ame218_desc];

    [ame218_card.heightAnchor constraintEqualToConstant:74].active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [ame218_icon.leadingAnchor constraintEqualToAnchor:ame218_card.leadingAnchor constant:16],
        [ame218_icon.centerYAnchor constraintEqualToAnchor:ame218_card.centerYAnchor],
        [ame218_icon.widthAnchor constraintEqualToConstant:26],
        [ame218_icon.heightAnchor constraintEqualToConstant:26],

        [ame218_title.leadingAnchor constraintEqualToAnchor:ame218_icon.trailingAnchor constant:14],
        [ame218_title.topAnchor constraintEqualToAnchor:ame218_card.topAnchor constant:14],
        [ame218_title.trailingAnchor constraintEqualToAnchor:ame218_card.trailingAnchor constant:-12],

        [ame218_desc.leadingAnchor constraintEqualToAnchor:ame218_title.leadingAnchor],
        [ame218_desc.topAnchor constraintEqualToAnchor:ame218_title.bottomAnchor constant:3],
        [ame218_desc.trailingAnchor constraintEqualToAnchor:ame218_card.trailingAnchor constant:-12],
    ]];
    return ame218_card;
}

- (void)ame218_importTapped:(UITapGestureRecognizer *)gesture {
    // 从备份导入：复用 Task217 数据桥（系统文件选择器 + zip 净化 + 合并）。
    // 导入完成后的重启提示由 DataTransferService 自己弹；向导不阻拦。
    NSLog(@"[Welcome] Task218: data import requested in onboarding");
    [[DataTransferService sharedService] importDataFromViewController:self];
}

- (void)ame218_dataSkipTapped:(UITapGestureRecognizer *)gesture {
    [self ame218_showStep:4 animated:YES];
}

#pragma mark - 步骤内容：4 完成

- (void)ame218_buildDoneStep:(UIView *)container {
    UIView *ame218_center = [[UIView alloc] init];
    ame218_center.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_center];

    UIImageView *ame218_check = [[UIImageView alloc] init];
    ame218_check.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    ame218_check.tintColor = [UIColor whiteColor];
    ame218_check.contentMode = UIViewContentModeScaleAspectFit;
    ame218_check.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_check];

    UILabel *ame218_title = [[UILabel alloc] init];
    ame218_title.text = localize(@"welcome.done.title", nil);
    ame218_title.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    ame218_title.textColor = [UIColor whiteColor];
    ame218_title.textAlignment = NSTextAlignmentCenter;
    ame218_title.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_title];

    UILabel *ame218_sub = [[UILabel alloc] init];
    ame218_sub.text = localize(@"welcome.done.subtitle", nil);
    ame218_sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    ame218_sub.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
    ame218_sub.textAlignment = NSTextAlignmentCenter;
    ame218_sub.numberOfLines = 0;
    ame218_sub.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_sub];

    [NSLayoutConstraint activateConstraints:@[
        [ame218_center.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [ame218_center.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [ame218_center.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_center.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [ame218_check.centerXAnchor constraintEqualToAnchor:ame218_center.centerXAnchor],
        [ame218_check.topAnchor constraintEqualToAnchor:ame218_center.topAnchor],
        [ame218_check.widthAnchor constraintEqualToConstant:88],
        [ame218_check.heightAnchor constraintEqualToConstant:88],

        [ame218_title.topAnchor constraintEqualToAnchor:ame218_check.bottomAnchor constant:20],
        [ame218_title.centerXAnchor constraintEqualToAnchor:ame218_center.centerXAnchor],

        [ame218_sub.topAnchor constraintEqualToAnchor:ame218_title.bottomAnchor constant:12],
        [ame218_sub.leadingAnchor constraintEqualToAnchor:ame218_center.leadingAnchor constant:16],
        [ame218_sub.trailingAnchor constraintEqualToAnchor:ame218_center.trailingAnchor constant:-16],
        [ame218_sub.bottomAnchor constraintEqualToAnchor:ame218_center.bottomAnchor],
    ]];

    // 大号对勾弹簧入场 + 礼花
    ame218_check.transform = CGAffineTransformMakeScale(0.3, 0.3);
    ame218_check.alpha = 0;
    [UIView animateWithDuration:0.65 delay:0.05
     usingSpringWithDamping:0.55 initialSpringVelocity:0.4 options:0
                    animations:^{
        ame218_check.transform = CGAffineTransformIdentity;
        ame218_check.alpha = 1;
    } completion:nil];
    ame218_title.alpha = ame218_sub.alpha = 0;
    [UIView animateWithDuration:0.5 delay:0.3 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        ame218_title.alpha = 1; ame218_sub.alpha = 1;
    } completion:nil];
    [self ame218_fireConfettiBurst];
}

@end
