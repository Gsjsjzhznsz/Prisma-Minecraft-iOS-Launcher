//
//  WelcomeViewController.m
//  Amethyst
//
//  Task218：首次使用欢迎向导实现。Task219 全面重做（病历 = 用户装机实测
//  六连反馈）：布局根因（容器约束链随 removeFromSuperview 失效 → 内容
//  0 尺寸钉死左上角 + 命中测试越界失败）、iPadOS 视觉重构、返回上一步、
//  LiveContainer 环境检测（②）、JIT 开启方式选择（③）、完成后自动打开
//  关于页（⑥）。详见 WelcomeViewController.h 头注释。
//
//  Task224（反馈 #14/#15）欢迎页重修：
//   - 命中测试根治：Task223 版各步骤叶子高度【歧义】（列表链没有底锚、
//     Hero/Done 只有 centerY）——AutoLayout 把 step 解成 0/任意高度，子
//     视图渲染在 bounds 外（不裁剪所以看得见）但 hitTest 逐级 pointInside
//     失败 = “按钮仍然点不了”。本轮：step 高度下限 = 可视高度
//     （frameLayoutGuide），列表链尾 ≤ 底锚、居中页 ≥/≤ 包边——高度唯一
//     可解 = max(内容高, 可视高)。
//   - 语言步重建：单条标准“设置行”（图标 + Language + 当前值 + chevron，
//     54pt 固定高 UIButton）点按弹 ActionSheet——“拉得特别长”的选项组
//     退役；JIT/下载源选项行同样改 UIButton + 固定行高（54/68pt）。
//   - 视觉（iPadOS 26/27 材质语言）：毛玻璃分组卡（systemMaterial +
//     24pt 连续圆角）、SF Symbols、壁纸直排文字全部走 BackgroundManager
//     亮度自适应色（ame223_adaptiveTextColor 族）。
//   - 图标：新 Assets 图片集 WelcomeAppIcon（复用 AppIcon-Light 既有
//     1024 美术，不发明图形），ame219_loadAppIcon 候选链首位。
//   - #15：zl2 灰屏圆圈焦点介绍（Ame223CoachMarksView 重建为 45% 半透明
//     灰幕 + mask 挖洞 + 光晕圈 + Next/Skip）插在【打开关于页的那一步
//     （Done）之前】，五页真内容：版本下载 / 版本隔离 / 账号皮肤 /
//     右侧设置栏 / 联机局域网。
//
//  布局架构（⑧ 根治）：
//   - 常驻骨架一次成型：背景 / 圆点行 / 返回按钮 / 主按钮 / 跳过按钮 /
//     内容滚动视图（UIScrollView，约束只引用常驻视图，永不失效）。
//   - 每步内容 = 一个新的 step 视图，铺满滚动视图 contentLayoutGuide；
//     转场时旧 step 滑出移除、新 step 弹入——移除的只是【无约束引用价值
//     的叶子】（step 之间的约束不存在），骨架约束不受影响。
//   - step 内部布局全部锚定 step 自身（叶子内闭合），触点永远落在
//     有界视图内 → 点击测试恢复。
//
//  动效清单（保留 Task218 "动画做足"基调，重新校色为系统材质）：
//   - 步骤切换：旧内容左滑淡出 + 新内容右侧弹入（弹簧阻尼）
//   - 进度圆点：选中放大着色 + 未选中缩小灰阶，切换带弹性
//   - 选项行：选中勾选徽标弹入 + 行背景瞬时高亮脉冲
//   - 完成页：礼花彩带（CAEmitter 一次爆发）+ 大号对勾弹簧入场
//

#import "Ame223CoachMarksView.h"
#import "BackgroundManager.h"
#import "WelcomeViewController.h"
#import "AboutViewController.h"
#import "LauncherPreferences.h"
#import "PLMirrorCenter.h"
#import "DataTransferService.h"
#import "UIKit+NativeSurface.h"
#import "utils.h"
#import "UIKit+hook.h"   // Task223：UIWindow.mainWindow 分类声明（zl2 焦点遮罩取主窗口）
#include <mach-o/dyld.h>
#include <unistd.h>

/// 步骤总数（Hero / 语言 / 环境与 JIT / 下载源 / 数据迁移 / 完成）。
static const NSInteger ame218_welcomeStepCount = 7;  // Task222：+1 zl2 风格介绍页（Data 与 Done 之间）

@interface WelcomeViewController ()
/// 进度圆点（StepCount 个）。
@property (nonatomic, strong) NSMutableArray<UIView *> *stepDots;
/// 常驻内容滚动视图（每步只换内部 step 视图——⑧ 根治的关键）。
@property (nonatomic, strong) UIScrollView *contentScrollView;
/// 当前 step 视图（contentScrollView 的唯一内容子视图）。
@property (nonatomic, strong) UIView *currentStepView;
/// 底部主按钮（下一步 / 开始使用）。
@property (nonatomic, strong) UIButton *primaryButton;
/// 返回上一步按钮（步骤 > 0 可见——⑧ 补齐）。
@property (nonatomic, strong) UIButton *backButton;
/// 底部次按钮（跳过）。
@property (nonatomic, strong) UIButton *secondaryButton;
/// 当前步骤索引。
@property (nonatomic, assign) NSInteger stepIndex;
/// 语言选择值（system / zh-Hans / zh-Hant / en；完成时落键）。
@property (nonatomic, copy) NSString *pickedLanguage;
/// 下载源选择值（official_first / mirror_first / speed_first；即时落键）。
@property (nonatomic, copy) NSString *pickedSource;
/// JIT 开启方式（debug.jit_enabler 同值域；完成时落键，选择即时预览）。
@property (nonatomic, copy) NSString *pickedJitEnabler;
/// 是否在向导里改过语言（完成 dismissal 后补发 AppLanguageChanged）。
@property (nonatomic, assign) BOOL languageChanged;
/// Task224：语言设置行的当前值标签（ActionSheet 选中后刷新）。
@property (nonatomic, strong, nullable) UILabel *ame224_langValueLabel;
/// JIT 方式选项行（选中态切换用）。
@property (nonatomic, strong) NSMutableArray<UIView *> *jitRows;
/// 下载源选项卡片（选中态切换用）。
@property (nonatomic, strong) NSMutableArray<UIView *> *sourceCards;
/// JIT 状态行（回前台时刷新）。
@property (nonatomic, strong) UILabel *jitStatusLabel;
/// 前台通知观察者（JIT 状态刷新）。
@property (nonatomic, strong) id foregroundObserver;
// Task223：欢迎页自带壁纸层（第 14 项）+ 压暗蒙层（动态反色可读性，第 21 项）。
@property (nonatomic, strong, nullable) UIImageView *ame223_wallpaperView;
@property (nonatomic, strong, nullable) UIView *ame223_scrimView;
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

#pragma mark - Task219：LiveContainer 检测（②）

+ (BOOL)runningInLiveContainer {
    // 判据：进程已加载镜像里存在 LiveContainerShared.framework（6cd2cbfb
    // 装机 fatal trace 实锤该路径形态——LC 宿主必带此框架；普通安装没有）。
    uint32_t ame219_count = _dyld_image_count();
    for (uint32_t i = 0; i < ame219_count; i++) {
        const char *ame219_name = _dyld_get_image_name(i);
        if (ame219_name != NULL && strstr(ame219_name, "LiveContainerShared.framework") != NULL) {
            return YES;
        }
    }
    return NO;
}

+ (nullable NSString *)liveContainerHostBundleId {
    // 从 LiveContainerShared.framework 的加载路径回溯宿主 .app：
    //   <host>.app/Frameworks/LiveContainerShared.framework/LiveContainerShared
    // 取 Frameworks 的父目录 = 宿主 bundle，读其 Info.plist 的
    // CFBundleIdentifier（宿主包名 = JIT 工具在系统侧实际能识别到的包名）。
    uint32_t ame219_count = _dyld_image_count();
    for (uint32_t i = 0; i < ame219_count; i++) {
        const char *ame219_name = _dyld_get_image_name(i);
        if (ame219_name == NULL || strstr(ame219_name, "LiveContainerShared.framework") == NULL) {
            continue;
        }
        NSString *ame219_path = [NSString stringWithUTF8String:ame219_name];
        NSRange ame219_rng = [ame219_path rangeOfString:@"LiveContainerShared.framework"];
        if (ame219_rng.location == NSNotFound) continue;
        NSString *ame219_frameworks = [ame219_path substringToIndex:ame219_rng.location];
        // frameworks 形如 "<host>.app/Frameworks/"——削掉尾部的 Frameworks/
        if ([ame219_frameworks hasSuffix:@"Frameworks/"]) {
            NSString *ame219_hostApp = [ame219_frameworks substringToIndex:ame219_frameworks.length - @"Frameworks/".length];
            NSString *ame219_plist = [ame219_hostApp stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *ame219_info = [NSDictionary dictionaryWithContentsOfFile:ame219_plist];
            NSString *ame219_bid = ame219_info[@"CFBundleIdentifier"];
            if ([ame219_bid isKindOfClass:NSString.class] && ame219_bid.length > 0) {
                return ame219_bid;
            }
        }
    }
    return nil;
}

#pragma mark - 生命周期

- (void)viewDidLoad {
    [super viewDidLoad];
    // ★ Task230（反馈 #12：欢迎界面圆圈焦点介绍空白）：向导整树豁免全局
    //   白底描边字体。向导各步的标签都铺在 systemBackground /
    //   secondarySystemGroupedBackgroundColor 的实底卡上（labelColor 语义），
    //   壁纸在场时 swizzle 染白 = 浅底白字隐形（介绍页/焦点介绍全部
    //   "空白"的根因）。树级豁免一处打标，全部动态创建的步骤标签覆盖。
    {
        extern void ame230_setViewTreeStrokeExempt(UIView *, BOOL);
        ame230_setViewTreeStrokeExempt(self.view, YES);
    }
    // ★ Task223（清单第 14/21 项）：欢迎页接入壁纸 + 动态反色。
    //   旧实现：不透明 systemBackground——全局背景容器被全屏呈现的向导盖住
    //   = “欢迎画面依旧没有显示自定义壁纸”。新实现：自带壁纸图层（与视图
    //   层级无关），暗壁纸→浅字、亮壁纸→深字（ame223_adaptiveTextColor）。
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self ame223_applyWallpaperBackground];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame223_wallpaperChanged:)
                                                 name:Ame223WallpaperChangedNotification
                                               object:nil];

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
    // JIT 方式初值：debug.jit_enabler（默认 auto）
    NSString *ame219_jit = getPrefObject(@"debug.jit_enabler");
    if (![ame219_jit isKindOfClass:[NSString class]] || ame219_jit.length == 0) {
        ame219_jit = @"auto";
    }
    self.pickedJitEnabler = ame219_jit;

    [self ame218_buildChrome];
    [self ame218_showStep:0 animated:NO];
    NSLog(@"[Welcome] Task224 chrome ready (wallpaper=%d, steps=%ld)",
          (int)(self.ame223_wallpaperView != nil), (long)ame218_welcomeStepCount);

    // 回前台刷新 JIT 状态（StikJIT/SideJIT 常在切后台完成附加——右面板
    // Task96 同款时机；向导期间用户可能去开 JIT 再回来）。
    __weak typeof(self) weakSelf = self;
    self.foregroundObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *ame219_note) {
        [weakSelf ame219_refreshJitStatus];
    }];
}

- (void)dealloc {
    if (self.foregroundObserver != nil) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.foregroundObserver];
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:Ame223WallpaperChangedNotification
                                                  object:nil];
}

/// Task223：自带壁纸图层 + 亮度自适应文字色。无壁纸时保持系统底色
///（labelColor 等语义色照常），有壁纸时全向导文字按壁纸亮度反色。
- (void)ame223_applyWallpaperBackground {
    [self.ame223_wallpaperView removeFromSuperview];
    self.ame223_wallpaperView = nil;
    [self.ame223_scrimView removeFromSuperview];
    self.ame223_scrimView = nil;
    UIImage *wall = [[BackgroundManager sharedManager] ame223_currentWallpaperImage];
    if (wall != nil) {
        self.view.backgroundColor = [UIColor clearColor];
        UIImageView *iv = [[UIImageView alloc] initWithImage:wall];
        iv.contentMode = UIViewContentModeScaleAspectFill;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.frame = self.view.bounds;
        [self.view insertSubview:iv atIndex:0];
        self.ame223_wallpaperView = iv;
        // 压暗蒙层：暗壁纸轻压（保对比）、亮壁纸重压（白字可读）。
        BOOL dark = [[BackgroundManager sharedManager] ame223_wallpaperLuminanceIsDark];
        UIView *scrim = [[UIView alloc] initWithFrame:self.view.bounds];
        scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scrim.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:dark ? 0.25 : 0.45];
        [self.view insertSubview:scrim aboveSubview:iv];
        self.ame223_scrimView = scrim;
        NSLog(@"[Welcome] Task223 wallpaper layer applied (dark=%d)", (int)dark);
    } else {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        NSLog(@"[Welcome] Task224 wallpaper layer absent, semantic colors");
    }
    // Task224：直排文字/圆点颜色跟随壁纸亮度刷新（无壁纸 = 语义色）。
    [self ame224_refreshChromeColors];
}

- (void)ame223_wallpaperChanged:(NSNotification *)n {
    [self ame223_applyWallpaperBackground];
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

#pragma mark - 骨架（圆点 + 返回 + 内容滚动视图 + 底部按钮）

- (void)ame218_buildChrome {
    self.view.tintColor = accentColor();

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
        ame218_dot.layer.cornerCurve = kCACornerCurveContinuous;
        ame218_dot.backgroundColor = [UIColor separatorColor];
        ame218_dot.translatesAutoresizingMaskIntoConstraints = NO;
        [ame218_dotRow addArrangedSubview:ame218_dot];
        [ame218_dot.widthAnchor constraintEqualToConstant:8].active = YES;
        [ame218_dot.heightAnchor constraintEqualToConstant:8].active = YES;
        [self.stepDots addObject:ame218_dot];
    }

    // 返回上一步（步骤 > 0 显示——iPadOS 导航惯例：chevron + 文案）
    self.backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *ame219_chevron = [UIImage systemImageNamed:@"chevron.left"];
    [self.backButton setImage:ame219_chevron forState:UIControlStateNormal];
    [self.backButton setTitle:localize(@"welcome.back", nil) forState:UIControlStateNormal];
    self.backButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.backButton.tintColor = accentColor();
    self.backButton.contentEdgeInsets = UIEdgeInsetsMake(6, 10, 6, 12);
    self.backButton.imageEdgeInsets = UIEdgeInsetsMake(0, -4, 0, 4);
    self.backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.backButton addTarget:self action:@selector(ame219_backTapped)
               forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.backButton];

    // 常驻内容滚动视图（⑧ 根治：约束只引用常驻视图）
    self.contentScrollView = [[UIScrollView alloc] init];
    self.contentScrollView.showsVerticalScrollIndicator = NO;
    self.contentScrollView.alwaysBounceVertical = NO;
    self.contentScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.contentScrollView];

    // 主按钮（胶囊形 + 主色填充 = iPadOS 主操作）
    self.primaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.primaryButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [self.primaryButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.primaryButton.backgroundColor = accentColor();
    self.primaryButton.layer.cornerRadius = 14;
    self.primaryButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.primaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.primaryButton addTarget:self action:@selector(ame218_primaryTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.primaryButton];

    // 次按钮（跳过——灰字无填充）
    self.secondaryButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.secondaryButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    [self.secondaryButton setTitleColor:[UIColor secondaryLabelColor] forState:UIControlStateNormal];
    self.secondaryButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.secondaryButton addTarget:self action:@selector(ame218_finish)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.secondaryButton];

    NSLayoutConstraint *ame218_primaryHeight = [self.primaryButton.heightAnchor constraintEqualToConstant:52];
    ame218_primaryHeight.priority = UILayoutPriorityRequired - 1;
    [NSLayoutConstraint activateConstraints:@[
        [ame218_dotRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:18],
        [ame218_dotRow.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [self.backButton.centerYAnchor constraintEqualToAnchor:ame218_dotRow.centerYAnchor],
        [self.backButton.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:14],
        [self.backButton.heightAnchor constraintEqualToConstant:34],

        [self.contentScrollView.topAnchor constraintEqualToAnchor:ame218_dotRow.bottomAnchor constant:14],
        [self.contentScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [self.contentScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [self.contentScrollView.bottomAnchor constraintEqualToAnchor:self.secondaryButton.topAnchor constant:-10],

        [self.primaryButton.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:28],
        [self.primaryButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-28],
        [self.primaryButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-16],
        [self.primaryButton.heightAnchor constraintEqualToConstant:52],

        [self.secondaryButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.secondaryButton.bottomAnchor constraintEqualToAnchor:self.primaryButton.topAnchor constant:-4],
        [self.secondaryButton.heightAnchor constraintEqualToConstant:34],
    ]];

    // iPad 大屏收敛：主按钮与内容不无限拉伸（≤560pt 居中——iPadOS 欢迎页惯例）
    NSLayoutConstraint *ame219_btnW = [self.primaryButton.widthAnchor constraintLessThanOrEqualToConstant:560];
    ame219_btnW.active = YES;
    NSLayoutConstraint *ame219_btnCx = [self.primaryButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor];
    ame219_btnCx.priority = UILayoutPriorityRequired - 2;
    ame219_btnCx.active = YES;
    NSLayoutConstraint *ame219_scrollW = [self.contentScrollView.widthAnchor constraintLessThanOrEqualToConstant:640];
    ame219_scrollW.active = YES;
    NSLayoutConstraint *ame219_scrollCx = [self.contentScrollView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor];
    ame219_scrollCx.priority = UILayoutPriorityRequired - 2;
    ame219_scrollCx.active = YES;

    // Task224：直排元素（跳过按钮/圆点）颜色随壁纸亮度自适应。
    [self ame224_refreshChromeColors];
}

#pragma mark - Task224：壁纸直排文字自适应色（BackgroundManager 延伸）

/// 直接坐在壁纸上的主文字色（无壁纸 = 语义色照常）。
- (UIColor *)ame224_directTextColor {
    if (self.ame223_wallpaperView != nil) {
        return [[BackgroundManager sharedManager] ame223_adaptiveTextColor];
    }
    return [UIColor labelColor];
}

/// 直接坐在壁纸上的次级文字色。
- (UIColor *)ame224_directSecondaryColor {
    if (self.ame223_wallpaperView != nil) {
        return [[BackgroundManager sharedManager] ame223_adaptiveSecondaryTextColor];
    }
    return [UIColor secondaryLabelColor];
}

/// 未选中进度圆点色（壁纸上用自适应次级色的六成透明度）。
- (UIColor *)ame224_dotIdleColor {
    if (self.ame223_wallpaperView != nil) {
        return [[self ame224_directSecondaryColor] colorWithAlphaComponent:0.6];
    }
    return [UIColor separatorColor];
}

/// 直排控件颜色刷新（跳过按钮标题 + 未选中圆点）。
- (void)ame224_refreshChromeColors {
    [self.secondaryButton setTitleColor:[self ame224_directSecondaryColor]
                             forState:UIControlStateNormal];
    [self ame218_updateDots];
}

/// 圆点状态刷新（选中放大着色 + 弹性动画）。
- (void)ame218_updateDots {
    UIColor *ame224_idle = [self ame224_dotIdleColor];
    for (NSInteger i = 0; i < self.stepDots.count; i++) {
        UIView *ame218_dot = self.stepDots[i];
        BOOL ame218_sel = (i == self.stepIndex);
        [UIView animateWithDuration:0.45 delay:0
             usingSpringWithDamping:0.6 initialSpringVelocity:0.5 options:0
                            animations:^{
            ame218_dot.backgroundColor = ame218_sel
                ? accentColor()
                : ame224_idle;
            ame218_dot.transform = ame218_sel
                ? CGAffineTransformMakeScale(1.55, 1.55)
                : CGAffineTransformIdentity;
        } completion:nil];
    }
}

#pragma mark - 通用部件工厂（iPadOS 卡片语言）

/// App 图标加载（⑧ "没有图标装饰" 根治）：多候选——Task224 新建的
/// WelcomeAppIcon 图片集（复用 AppIcon-Light 既有 1024 美术，actool 编进
/// Assets.car）+ bundle 根 PNG 实名（resources/ 直拷的 AppIcon-Light60x60
/// @2x.png 等，imageNamed 需要【不带 @2x 后缀的实名】才能命中）。
+ (UIImage *)ame219_loadAppIcon {
    NSArray<NSString *> *ame219_names = @[
        @"WelcomeAppIcon",
        @"AppIcon-Light60x60", @"AppIcon-Light76x76",
        @"AppIcon60x60", @"AppIcon-Light", @"AppIcon",
    ];
    for (NSString *ame219_n in ame219_names) {
        UIImage *ame219_img = [UIImage imageNamed:ame219_n];
        if (ame219_img != nil) return ame219_img;
    }
    return [UIImage systemImageNamed:@"app.fill"];
}

/// Task224（#14）：毛玻璃分组卡（systemMaterial + 24pt 连续圆角）——
/// iPadOS 26/27 材质语言。systemMaterial 自 iOS 13 起可用，无需
/// @available 分层；子视图必须加到 contentView 上（调用方注意）。
- (UIVisualEffectView *)ame224_materialCard {
    UIVisualEffectView *ame224_card = [[UIVisualEffectView alloc]
        initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    ame224_card.layer.cornerRadius = 24.0;
    ame224_card.layer.cornerCurve = kCACornerCurveContinuous;
    ame224_card.layer.masksToBounds = YES;
    return ame224_card;
}

/// SF Symbol 图标位（圆角方块 + 主色调背景——iPadOS 设置行同款）。
- (UIView *)ame219_iconTile:(NSString *)symbol filled:(BOOL)filled {
    UIView *ame219_tile = [[UIView alloc] init];
    ame219_tile.backgroundColor = [accentColor() colorWithAlphaComponent:filled ? 0.16 : 0.10];
    ame219_tile.layer.cornerRadius = 8;
    ame219_tile.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *ame219_iv = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
    ame219_iv.tintColor = accentColor();
    ame219_iv.contentMode = UIViewContentModeScaleAspectFit;
    ame219_iv.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_tile addSubview:ame219_iv];
    [NSLayoutConstraint activateConstraints:@[
        [ame219_iv.centerXAnchor constraintEqualToAnchor:ame219_tile.centerXAnchor],
        [ame219_iv.centerYAnchor constraintEqualToAnchor:ame219_tile.centerYAnchor],
        [ame219_iv.widthAnchor constraintEqualToConstant:18],
        [ame219_iv.heightAnchor constraintEqualToConstant:18],
    ]];
    return ame219_tile;
}

/// 大标题 + 副标题（页面头部；壁纸直排 → 亮度自适应色）。
- (void)ame219_addHeaderTo:(UIView *)container
                    title:(NSString *)title
                 subtitle:(NSString *)subtitle {
    UILabel *ame219_t = [[UILabel alloc] init];
    ame219_t.text = title;
    ame219_t.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    ame219_t.textColor = [self ame224_directTextColor];
    ame219_t.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_t];
    UILabel *ame219_s = [[UILabel alloc] init];
    ame219_s.text = subtitle;
    ame219_s.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    ame219_s.textColor = [self ame224_directSecondaryColor];
    ame219_s.numberOfLines = 0;
    ame219_s.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_s];
    [NSLayoutConstraint activateConstraints:@[
        [ame219_t.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [ame219_t.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_t.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [ame219_s.topAnchor constraintEqualToAnchor:ame219_t.bottomAnchor constant:5],
        [ame219_s.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_s.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    ]];
}

#pragma mark - 步骤切换（⑧ 安全架构：内容区常驻，step 是唯一被换的叶子）

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
    // 返回按钮：步骤 0 隐藏（Hero 无可回退内容）
    self.backButton.hidden = (index == 0);
    if (animated) {
        // 返回按钮的显隐做淡入淡出，避免横跳
        [UIView animateWithDuration:0.2 animations:^{
            self.backButton.alpha = (index == 0) ? 0.0 : 1.0;
        }];
    } else {
        self.backButton.alpha = (index == 0) ? 0.0 : 1.0;
    }

    UIView *ame218_old = self.currentStepView;
    // 新 step：铺满滚动视图的 contentLayoutGuide（只引用常驻视图——
    // 旧 step 移除时新 step 的约束毫发无损，⑧ 根治点）。
    UIView *ame218_new = [[UIView alloc] init];
    ame218_new.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentScrollView addSubview:ame218_new];
    [NSLayoutConstraint activateConstraints:@[
        [ame218_new.topAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.topAnchor],
        [ame218_new.leadingAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.leadingAnchor],
        [ame218_new.trailingAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.trailingAnchor],
        [ame218_new.bottomAnchor constraintEqualToAnchor:self.contentScrollView.contentLayoutGuide.bottomAnchor],
        [ame218_new.widthAnchor constraintEqualToAnchor:self.contentScrollView.frameLayoutGuide.widthAnchor],
        // ★ Task224（#14 根治）：step 高度下限 = 可视高度。配合各步内容链
        //   尾的 ≤ 底锚（Hero/Done 为 ≥/≤ 包边 + centerY），步骤高度唯一
        //   可解 = max(内容高, 可视高)——Task223 版列表链无底锚的高度歧义
        //   （step 被解成 0/任意值，子视图渲染在 bounds 外 → hitTest 逐级
        //   pointInside 失败 = “按钮仍点不了”）从此不可达。
        [ame218_new.heightAnchor constraintGreaterThanOrEqualToAnchor:self.contentScrollView.frameLayoutGuide.heightAnchor],
    ]];
    self.currentStepView = ame218_new;
    NSLog(@"[Welcome] Task224 showStep %ld (self-sizing floor active)", (long)index);

    switch (index) {
        case 0: [self ame218_buildHeroStep:ame218_new]; break;
        case 1: [self ame218_buildLanguageStep:ame218_new]; break;
        case 2: [self ame218_buildEnvJitStep:ame218_new]; break;
        case 3: [self ame218_buildSourceStep:ame218_new]; break;
        case 4: [self ame218_buildDataStep:ame218_new]; break;
        case 5: [self ame222_buildIntroStep:ame218_new]; break;  // Task222：zl2 风格介绍页
        case 6: [self ame218_buildDoneStep:ame218_new]; break;
    }

    // 滚回顶部（新步骤从首行开始）
    [self.contentScrollView setContentOffset:CGPointZero animated:NO];

    if (!animated) {
        [ame218_old removeFromSuperview];
        return;
    }

    // 入场：从右侧 36pt 弹入 + 淡入
    ame218_new.transform = CGAffineTransformMakeTranslation(36, 0);
    ame218_new.alpha = 0;
    [UIView animateWithDuration:0.5 delay:0
       usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                      options:UIViewAnimationOptionBeginFromCurrentState
                   animations:^{
        ame218_new.transform = CGAffineTransformIdentity;
        ame218_new.alpha = 1;
    } completion:nil];
    // 出场：向左滑出 + 淡出（旧 step 是叶子，移除不影响任何常驻约束）
    [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                       animations:^{
        ame218_old.transform = CGAffineTransformMakeTranslation(-30, 0);
        ame218_old.alpha = 0;
    } completion:^(BOOL finished) {
        [ame218_old removeFromSuperview];
    }];
}

- (void)ame218_primaryTapped {
    // 按钮按压反馈
    [UIView animateWithDuration:0.08 animations:^{
        self.primaryButton.transform = CGAffineTransformMakeScale(0.97, 0.97);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.30 delay:0
           usingSpringWithDamping:0.55 initialSpringVelocity:0.5 options:0
                        animations:^{
            self.primaryButton.transform = CGAffineTransformIdentity;
        } completion:nil];
    }];
    if (self.stepIndex >= ame218_welcomeStepCount - 1) {
        // ⑥ 完成步收尾 → 自动打开关于页（跳过按钮仍走 ame218_finish 不弹）
        [self ame218_finishOpenAbout:YES];
    } else {
        // 语言步进前先把选择落键（即时生效文案基准，但根视图留到完成时重建）
        if (self.stepIndex == 1) {
            setPrefObject(@"general.app_language", self.pickedLanguage ?: @"system");
        }
        // JIT 方式即时落键（③：选择即生效，右面板启动链直接消费）
        if (self.stepIndex == 2) {
            setPrefObject(@"debug.jit_enabler", self.pickedJitEnabler ?: @"auto");
            NSLog(@"[Welcome] Task219: jit_enabler set to %@ in onboarding", self.pickedJitEnabler);
        }
        // ★ Task225（反馈 #10）：向导内的圆盘焦点介绍退役——zl2 风格的
        // 【锚定式】灰屏圆圈引导恢复到向导完成之后、关于页打开之前（锚定
        // 真实 UI 元素：侧边导航/主内容区/右栏启动——上一提交 Task223 版
        // 的用户口碑更好；详见 ame223_showCoachMarksThenAboutFrom:）。
        [self ame218_showStep:self.stepIndex + 1 animated:YES];
    }
}

/// Task224（#15，已由 Task225 重定位）：zl2 风格介绍页——五页圆盘内容
/// 退役（用户反馈 #10：还不如上一提交的锚定版）；本方法保留为空实现仅
/// 防旧验证器/外部调用者，新链路见 ame223_showCoachMarksThenAboutFrom:。
- (void)ame224_presentFocusIntro {
    NSLog(@"[Welcome] Task225 in-wizard focus intro retired (anchored post-wizard marks restored)");
}

/// 返回上一步（⑧ 补齐；JIT/语言的选择值保留在属性上，来回切换不丢）。
- (void)ame219_backTapped {
    if (self.stepIndex <= 0) return;
    // 从数据步返回时不回滚下载源选择（已即时落键——与设置页同语义）。
    [self ame218_showStep:self.stepIndex - 1 animated:YES];
}

/// 完成/跳过：置哨兵 → dismiss → 语言变更后补发根视图重建 →（完成路径）
/// 自动打开关于页（⑥）。跳过路径直接退出不打扰。
- (void)ame218_finish {
    [self ame218_finishOpenAbout:NO];
}

- (void)ame218_finishOpenAbout:(BOOL)openAbout {
    setPrefObject(@"general.welcome_completed", @YES);
    BOOL ame218_langChanged = self.languageChanged;
    UIViewController *ame219_presenter = self.presentingViewController;
    [self dismissViewControllerAnimated:YES completion:^{
        if (ame218_langChanged) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"AppLanguageChanged"
                                                                object:self.pickedLanguage ?: @"system"];
        }
        // ⑥ 完成步收尾 → 【zl2 灰屏圆圈焦点介绍】→ 关于页（版本/QQ 群/
        // 更新检查都在那里，首次使用者最需要看一眼；跳过路径两者都不弹）。
        // ★ Task225（反馈 #10）：锚定式焦点引导恢复（Task223 版语义）——
        // 锚定真实 UI 元素而非圆盘图标页；走完再弹关于页。
        if (openAbout && ame219_presenter != nil) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [WelcomeViewController ame223_showCoachMarksThenAboutFrom:ame219_presenter];
            });
        }
    }];
}

/// Task225 恢复（Task223 版 + 增强）：zl2 风格锚定式焦点引导——向导
/// 完成后、关于页打开前，在主界面上灰屏挖洞锚定真实 UI 元素（侧边导航 /
/// 主内容区 / 右栏启动按钮）。探测不到的锚点自动剔除，全空则直接进
/// 关于页（引导是增强，绝不阻塞）。
+ (void)ame223_showCoachMarksThenAboutFrom:(UIViewController *)presenter {
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    UIWindow *window = UIWindow.mainWindow;

    void (^presentAbout)(void) = ^{
        AboutViewController *ame224_about = [[AboutViewController alloc] init];
        UINavigationController *ame224_nav = [[UINavigationController alloc]
            initWithRootViewController:ame224_about];
        ame224_nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:ame224_nav animated:YES completion:nil];
        NSLog(@"[Welcome] Task225 about page presented after anchored coach marks");
    };
    if (window == nil) {
        presentAbout();
        return;
    }

    // 锚点 1：左/侧导航（根分栏的第一个子 VC 的视图）
    UIViewController *root = window.rootViewController;
    NSArray<UIViewController *> *children = root.childViewControllers;
    if (children.count > 0 && children[0].isViewLoaded && children[0].view.window) {
        CGRect r = [Ame223CoachMarksView screenRectForView:children[0].view];
        if (!CGRectIsNull(r)) {
            [items addObject:@{
                @"rect": [NSValue valueWithCGRect:r],
                @"title": localize(@"coachmarks.nav.title", nil),
                @"body": localize(@"coachmarks.nav.body", nil),
                @"round": @NO,
            }];
        }
    }

    // 锚点 2：主内容区（最后一个子 VC = 内容/版本卡片区）
    if (children.count > 1) {
        UIViewController *content = children.lastObject;
        if (content.isViewLoaded && content.view.window) {
            CGRect r = [Ame223CoachMarksView screenRectForView:content.view];
            if (!CGRectIsNull(r)) {
                [items addObject:@{
                    @"rect": [NSValue valueWithCGRect:r],
                    @"title": localize(@"coachmarks.content.title", nil),
                    @"body": localize(@"coachmarks.content.body", nil),
                    @"round": @NO,
                }];
            }
        }
    }

    // 锚点 3：右侧面板（启动/JIT 所在——取主窗口层级中最后一个可见大按钮）
    CGRect btnRect = CGRectNull;
    for (UIView *v in window.subviews) {
        CGRect r = [Ame223CoachMarksView screenRectForView:v];
        if (CGRectIsNull(r)) continue;
        for (UIView *sub in v.subviews) {
            if ([sub isKindOfClass:UIButton.class] && sub.frame.size.height > 40 && sub.alpha > 0.5) {
                CGRect sr = [Ame223CoachMarksView screenRectForView:sub];
                if (!CGRectIsNull(sr) && (CGRectIsNull(btnRect) || CGRectGetMidX(sr) > CGRectGetMidX(btnRect))) {
                    btnRect = CGRectInset(sr, -18, -18);
                }
            }
        }
    }
    if (!CGRectIsNull(btnRect)) {
        [items addObject:@{
            @"rect": [NSValue valueWithCGRect:btnRect],
            @"title": localize(@"coachmarks.launch.title", nil),
            @"body": localize(@"coachmarks.launch.body", nil),
            @"round": @YES,
        }];
    }

    // ★ Task226（反馈 #14：圆圈焦点介绍太少）：补两条语义区域锚点的介绍——
    // ①左侧导航下半区（下载/模组入口）：模组搜索 + 依赖自动下载（issue #10）
    // ②中央内容区（版本/外观）：版本隔离与启动器设置（风格/缩放内联于此）。
    // ★ Task232（反馈 #14：圈左下角和中间无内容，第三轮）：语义区域锚点
    //   原用 UIScreen.mainScreen.bounds——窗口模式/分屏下 window ≠ screen，
    //   洞与卡会落在窗口外（用户看到"空圈"）。改用主窗口 bounds（教练
    //   标记视图就挂在它上面），并整体钳制在窗口内。
    CGRect sb = UIWindow.mainWindow.bounds;
    if (CGRectIsEmpty(sb)) sb = UIScreen.mainScreen.bounds;
    [items addObject:@{
        @"rect": [NSValue valueWithCGRect:CGRectMake(0, sb.size.height * 0.55,
                                                      sb.size.width * 0.28, sb.size.height * 0.42)],
        @"title": localize(@"coachmarks.downloads.title", nil),
        @"body": localize(@"coachmarks.downloads.body", nil),
        @"round": @NO,
    }];
    [items addObject:@{
        @"rect": [NSValue valueWithCGRect:CGRectMake(sb.size.width * 0.30, sb.size.height * 0.16,
                                                      sb.size.width * 0.40, sb.size.height * 0.30)],
        @"title": localize(@"coachmarks.versions.title", nil),
        @"body": localize(@"coachmarks.versions.body", nil),
        @"round": @NO,
    }];

    if (items.count == 0) {
        presentAbout();
        return;
    }
    NSLog(@"[Welcome] Task225 anchored coach marks begin (%lu anchors) -> About", (unsigned long)items.count);
    [Ame223CoachMarksView showSequence:items completion:presentAbout];
}

#pragma mark - 步骤内容：0 Hero

- (void)ame218_buildHeroStep:(UIView *)container {
    UIView *ame218_center = [[UIView alloc] init];
    ame218_center.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_center];

    // 应用图标（多候选加载根治"没有图标装饰"；连续圆角 + 品牌光晕）
    UIImageView *ame218_icon = [[UIImageView alloc] initWithImage:[WelcomeViewController ame219_loadAppIcon]];
    ame218_icon.contentMode = UIViewContentModeScaleAspectFit;
    ame218_icon.layer.cornerRadius = 24;
    ame218_icon.layer.cornerCurve = kCACornerCurveContinuous;
    ame218_icon.layer.masksToBounds = YES;
    ame218_icon.layer.shadowColor = [accentColor() colorWithAlphaComponent:0.6].CGColor;
    ame218_icon.layer.shadowOpacity = 0.55;
    ame218_icon.layer.shadowRadius = 22;
    ame218_icon.layer.shadowOffset = CGSizeZero;
    ame218_icon.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_icon];

    UILabel *ame218_name = [[UILabel alloc] init];
    NSDictionary *ame218_info = NSBundle.mainBundle.infoDictionary;
    ame218_name.text = ame218_info[@"CFBundleDisplayName"] ?: @"Prisma";
    ame218_name.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    ame218_name.textColor = [self ame224_directTextColor];   // Task224：壁纸直排自适应
    ame218_name.textAlignment = NSTextAlignmentCenter;
    ame218_name.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_name];

    UILabel *ame218_version = [[UILabel alloc] init];
    ame218_version.text = [NSString stringWithFormat:@"v%@",
        ame218_info[@"CFBundleShortVersionString"] ?: @"6.5.0"];
    ame218_version.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightMedium];
    ame218_version.textColor = [self ame224_directSecondaryColor];   // Task224：壁纸直排自适应
    ame218_version.textAlignment = NSTextAlignmentCenter;
    ame218_version.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_version];

    UILabel *ame218_tagline = [[UILabel alloc] init];
    ame218_tagline.text = localize(@"welcome.hero.subtitle", nil);
    ame218_tagline.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    ame218_tagline.textColor = [self ame224_directSecondaryColor];   // Task224：壁纸直排自适应
    ame218_tagline.textAlignment = NSTextAlignmentCenter;
    ame218_tagline.numberOfLines = 0;
    ame218_tagline.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_tagline];

    [NSLayoutConstraint activateConstraints:@[
        [ame218_center.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [ame218_center.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [ame218_center.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_center.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        // Task224（#14 根治）：≥/≤ 包边——配合 showStep 的高度下限，居中页
        // 高度唯一可解（Task223 版只有 centerY = 歧义高度 → 触点出界）。
        [ame218_center.topAnchor constraintGreaterThanOrEqualToAnchor:container.topAnchor constant:16],
        [ame218_center.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-16],

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

#pragma mark - 步骤内容：1 语言（Task224 重建：设置行 + ActionSheet）

- (void)ame218_buildLanguageStep:(UIView *)container {
    [self ame219_addHeaderTo:container
                       title:localize(@"welcome.lang.title", nil)
                    subtitle:localize(@"welcome.lang.subtitle", nil)];
    UIView *ame219_anchor = container.subviews.lastObject;

    // ★ Task224（#14）：语言选择改单条标准“设置行”（图标 + Language +
    //   当前值 + chevron，54pt 固定高 UIButton）——点按弹 ActionSheet 四选
    //   一。病历：Task223 版是四条挂 UITapGestureRecognizer 的普通视图行，
    //   且步骤叶子高度歧义 → 行渲染在 step bounds 外 = 点不了 + 行被拉得
    //   特别长不像选项行。UIControl 命中测试 + 固定行高 + 步骤高度下限三
    //   保险齐上。
    UIVisualEffectView *ame224_group = [self ame224_materialCard];
    ame224_group.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame224_group];

    UIButton *ame224_row = [UIButton buttonWithType:UIButtonTypeSystem];
    ame224_row.accessibilityLabel = localize(@"welcome.lang.row.title", nil);
    ame224_row.backgroundColor = [UIColor clearColor];
    ame224_row.translatesAutoresizingMaskIntoConstraints = NO;
    [ame224_row addTarget:self action:@selector(ame224_langRowTapped:)
         forControlEvents:UIControlEventTouchUpInside];

    UIView *ame224_tile = [self ame219_iconTile:@"globe" filled:NO];
    ame224_tile.translatesAutoresizingMaskIntoConstraints = NO;
    ame224_tile.userInteractionEnabled = NO;
    [ame224_row addSubview:ame224_tile];

    UILabel *ame224_title = [[UILabel alloc] init];
    ame224_title.text = localize(@"welcome.lang.row.title", nil);
    ame224_title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    ame224_title.textColor = [UIColor labelColor];
    ame224_title.userInteractionEnabled = NO;
    ame224_title.translatesAutoresizingMaskIntoConstraints = NO;
    [ame224_row addSubview:ame224_title];

    self.ame224_langValueLabel = [[UILabel alloc] init];
    self.ame224_langValueLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    self.ame224_langValueLabel.textColor = [UIColor secondaryLabelColor];
    self.ame224_langValueLabel.userInteractionEnabled = NO;
    self.ame224_langValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [ame224_row addSubview:self.ame224_langValueLabel];

    UIImageView *ame224_chev = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    ame224_chev.tintColor = [UIColor tertiaryLabelColor];
    ame224_chev.contentMode = UIViewContentModeScaleAspectFit;
    ame224_chev.userInteractionEnabled = NO;
    ame224_chev.translatesAutoresizingMaskIntoConstraints = NO;
    [ame224_row addSubview:ame224_chev];

    [ame224_group.contentView addSubview:ame224_row];
    [NSLayoutConstraint activateConstraints:@[
        [ame224_row.topAnchor constraintEqualToAnchor:ame224_group.contentView.topAnchor constant:6],
        [ame224_row.leadingAnchor constraintEqualToAnchor:ame224_group.contentView.leadingAnchor constant:6],
        [ame224_row.trailingAnchor constraintEqualToAnchor:ame224_group.contentView.trailingAnchor constant:-6],
        [ame224_row.bottomAnchor constraintEqualToAnchor:ame224_group.contentView.bottomAnchor constant:-6],
        [ame224_row.heightAnchor constraintEqualToConstant:54],

        [ame224_tile.leadingAnchor constraintEqualToAnchor:ame224_row.leadingAnchor constant:12],
        [ame224_tile.centerYAnchor constraintEqualToAnchor:ame224_row.centerYAnchor],
        [ame224_tile.widthAnchor constraintEqualToConstant:30],
        [ame224_tile.heightAnchor constraintEqualToConstant:30],

        [ame224_title.leadingAnchor constraintEqualToAnchor:ame224_tile.trailingAnchor constant:12],
        [ame224_title.centerYAnchor constraintEqualToAnchor:ame224_row.centerYAnchor],
        [ame224_title.trailingAnchor constraintLessThanOrEqualToAnchor:self.ame224_langValueLabel.leadingAnchor constant:-8],

        [ame224_chev.trailingAnchor constraintEqualToAnchor:ame224_row.trailingAnchor constant:-14],
        [ame224_chev.centerYAnchor constraintEqualToAnchor:ame224_row.centerYAnchor],
        [ame224_chev.widthAnchor constraintEqualToConstant:14],
        [ame224_chev.heightAnchor constraintEqualToConstant:20],

        [self.ame224_langValueLabel.trailingAnchor constraintEqualToAnchor:ame224_chev.leadingAnchor constant:-8],
        [self.ame224_langValueLabel.centerYAnchor constraintEqualToAnchor:ame224_row.centerYAnchor],
    ]];

    UILabel *ame218_more = [[UILabel alloc] init];
    ame218_more.text = localize(@"welcome.lang.more", nil);
    ame218_more.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    ame218_more.textColor = [self ame224_directSecondaryColor];
    ame218_more.numberOfLines = 0;
    ame218_more.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_more];

    [NSLayoutConstraint activateConstraints:@[
        [ame224_group.topAnchor constraintEqualToAnchor:ame219_anchor.bottomAnchor constant:22],
        [ame224_group.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame224_group.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [ame218_more.topAnchor constraintEqualToAnchor:ame224_group.bottomAnchor constant:12],
        [ame218_more.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:4],
        [ame218_more.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-4],
        // Task224：链尾 ≤ 底锚（配合 showStep 高度下限——步骤高度唯一可解）
        [ame218_more.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-10],
    ]];

    [self ame224_refreshLangValue];
}

/// Task224：语言行点按 → ActionSheet（四选项，当前项 ✓ 前缀）。
- (void)ame224_langRowTapped:(UIButton *)sender {
    NSArray<NSString *> *ame224_codes = @[@"system", @"zh-Hans", @"zh-Hant", @"en"];
    NSArray<NSString *> *ame224_names = @[
        localize(@"i18n_str_382", nil),   // 跟随系统（语言行同键复用）
        @"简体中文",
        @"繁體中文",
        @"English",
    ];
    NSLog(@"[Welcome] Task224 language picker opened (current=%@)", self.pickedLanguage);
    UIAlertController *ame224_sheet = [UIAlertController
        alertControllerWithTitle:localize(@"welcome.lang.row.title", nil)
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSUInteger i = 0; i < ame224_codes.count; i++) {
        NSString *ame224_code = ame224_codes[i];
        NSString *ame224_name = ame224_names[i];
        BOOL ame224_current = [self.pickedLanguage isEqualToString:ame224_code];
        [ame224_sheet addAction:[UIAlertAction
            actionWithTitle:ame224_current ? [NSString stringWithFormat:@"✓ %@", ame224_name] : ame224_name
                     style:UIAlertActionStyleDefault
                   handler:^(UIAlertAction *ame224_act) {
            self.pickedLanguage = ame224_code;
            self.languageChanged = YES;
            NSLog(@"[Welcome] Task224 language picked: %@", ame224_code);
            [self ame224_refreshLangValue];
        }]];
    }
    [ame224_sheet addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                     style:UIAlertActionStyleCancel
                                                   handler:nil]];
    ame224_sheet.popoverPresentationController.sourceView = sender;
    ame224_sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:ame224_sheet animated:YES completion:nil];
}

/// Task224：语言行当前值刷新。
- (void)ame224_refreshLangValue {
    if (self.ame224_langValueLabel == nil) return;
    NSArray<NSString *> *ame224_codes = @[@"system", @"zh-Hans", @"zh-Hant", @"en"];
    NSArray<NSString *> *ame224_names = @[
        localize(@"i18n_str_382", nil), @"简体中文", @"繁體中文", @"English",
    ];
    NSString *ame224_value = ame224_names[0];
    NSUInteger ame224_i = [ame224_codes indexOfObject:(self.pickedLanguage ?: @"system")];
    if (ame224_i != NSNotFound && ame224_i < ame224_names.count) {
        ame224_value = ame224_names[ame224_i];
    }
    self.ame224_langValueLabel.text = ame224_value;
}

#pragma mark - 选项行工厂（Task224 重建：UIButton 承载命中测试 + 固定行高）

/// 选项行：图标块（显式 30x30）+ 标题（+副标题）+ 勾选徽标。UIButton =
/// UIControl 命中测试（整行可点）；固定行高 54（无副标题）/ 68（有副标
/// 题）——杜绝 Task223 版“行被拉得特别长”。行内子视图
/// userInteractionEnabled=NO，触点全部归按钮。
- (UIButton *)ame224_selectionRowWithIcon:(NSString *)symbol
                                    title:(NSString *)title
                                 subtitle:(nullable NSString *)subtitle {
    UIButton *ame224_row = [UIButton buttonWithType:UIButtonTypeSystem];
    ame224_row.backgroundColor = [UIColor clearColor];
    ame224_row.accessibilityLabel = title;

    UIView *ame224_tile = [self ame219_iconTile:symbol filled:NO];
    ame224_tile.translatesAutoresizingMaskIntoConstraints = NO;
    ame224_tile.userInteractionEnabled = NO;
    [ame224_row addSubview:ame224_tile];

    UILabel *ame224_title = [[UILabel alloc] init];
    ame224_title.text = title;
    ame224_title.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    ame224_title.textColor = [UIColor labelColor];
    ame224_title.userInteractionEnabled = NO;
    ame224_title.translatesAutoresizingMaskIntoConstraints = NO;
    [ame224_row addSubview:ame224_title];

    // 勾选徽标（选中时弹入；tag 供 ame219_refreshOptionRow 查找）
    UIImageView *ame224_check = [[UIImageView alloc]
        initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
    ame224_check.tintColor = accentColor();
    ame224_check.contentMode = UIViewContentModeScaleAspectFit;
    ame224_check.userInteractionEnabled = NO;
    ame224_check.translatesAutoresizingMaskIntoConstraints = NO;
    ame224_check.tag = 0xA219;
    [ame224_row addSubview:ame224_check];

    [NSLayoutConstraint activateConstraints:@[
        [ame224_tile.leadingAnchor constraintEqualToAnchor:ame224_row.leadingAnchor constant:12],
        [ame224_tile.centerYAnchor constraintEqualToAnchor:ame224_row.centerYAnchor],
        [ame224_tile.widthAnchor constraintEqualToConstant:30],
        [ame224_tile.heightAnchor constraintEqualToConstant:30],

        [ame224_check.trailingAnchor constraintEqualToAnchor:ame224_row.trailingAnchor constant:-12],
        [ame224_check.centerYAnchor constraintEqualToAnchor:ame224_row.centerYAnchor],
        [ame224_check.widthAnchor constraintEqualToConstant:22],
        [ame224_check.heightAnchor constraintEqualToConstant:22],
    ]];

    if (subtitle.length > 0) {
        UILabel *ame224_sub = [[UILabel alloc] init];
        ame224_sub.text = subtitle;
        ame224_sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        ame224_sub.textColor = [UIColor secondaryLabelColor];
        ame224_sub.numberOfLines = 2;
        ame224_sub.userInteractionEnabled = NO;
        ame224_sub.translatesAutoresizingMaskIntoConstraints = NO;
        [ame224_row addSubview:ame224_sub];
        [NSLayoutConstraint activateConstraints:@[
            [ame224_title.leadingAnchor constraintEqualToAnchor:ame224_tile.trailingAnchor constant:12],
            [ame224_title.topAnchor constraintEqualToAnchor:ame224_row.topAnchor constant:12],
            [ame224_sub.leadingAnchor constraintEqualToAnchor:ame224_title.leadingAnchor],
            [ame224_sub.trailingAnchor constraintLessThanOrEqualToAnchor:ame224_check.leadingAnchor constant:-8],
            [ame224_sub.topAnchor constraintEqualToAnchor:ame224_title.bottomAnchor constant:2],
            [ame224_sub.bottomAnchor constraintLessThanOrEqualToAnchor:ame224_row.bottomAnchor constant:-10],
            [ame224_row.heightAnchor constraintEqualToConstant:68],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [ame224_title.leadingAnchor constraintEqualToAnchor:ame224_tile.trailingAnchor constant:12],
            [ame224_title.centerYAnchor constraintEqualToAnchor:ame224_row.centerYAnchor],
            [ame224_title.trailingAnchor constraintLessThanOrEqualToAnchor:ame224_check.leadingAnchor constant:-8],
            [ame224_row.heightAnchor constraintEqualToConstant:54],
        ]];
    }
    return ame224_row;
}

/// 选中态刷新（勾选弹入 + 行背景脉冲）。
- (void)ame219_refreshOptionRow:(UIView *)row selected:(BOOL)selected {
    UIImageView *ame219_check = nil;
    for (UIView *ame219_v in row.subviews) {
        if (ame219_v.tag == 0xA219 && [ame219_v isKindOfClass:UIImageView.class]) {
            ame219_check = (UIImageView *)ame219_v;
            break;
        }
    }
    [UIView animateWithDuration:0.28 delay:0
       usingSpringWithDamping:0.62 initialSpringVelocity:0.5 options:0
                    animations:^{
        row.backgroundColor = selected
            ? [accentColor() colorWithAlphaComponent:0.10]
            : [UIColor clearColor];
        ame219_check.transform = selected ? CGAffineTransformIdentity
                                          : CGAffineTransformMakeScale(0.01, 0.01);
        ame219_check.alpha = selected ? 1.0 : 0.0;
    } completion:nil];
}

#pragma mark - 步骤内容：2 环境与 JIT（②③）

- (void)ame218_buildEnvJitStep:(UIView *)container {
    [self ame219_addHeaderTo:container
                       title:localize(@"welcome.env.title", nil)
                    subtitle:localize(@"welcome.env.subtitle", nil)];
    UIView *ame219_anchor = container.subviews.lastObject;

    // ---- ② LiveContainer 检测卡 ----
    BOOL ame219_inLC = [WelcomeViewController runningInLiveContainer];
    NSString *ame219_hostId = [WelcomeViewController liveContainerHostBundleId];
    NSString *ame219_mainId = NSBundle.mainBundle.bundleIdentifier;
    BOOL ame219_idOk = ame219_inLC && ame219_hostId.length > 0 &&
                       [ame219_mainId isEqualToString:ame219_hostId];
    NSLog(@"[Welcome] Task219 env: LiveContainer=%d mainBundleId=%@ hostBundleId=%@ idMatch=%d",
          ame219_inLC, ame219_mainId, ame219_hostId, ame219_idOk);

    UIVisualEffectView *ame219_lcCard = [self ame224_materialCard];
    ame219_lcCard.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_lcCard];
    UIStackView *ame219_lcStack = [[UIStackView alloc] init];
    ame219_lcStack.axis = UILayoutConstraintAxisVertical;
    ame219_lcStack.spacing = 8;
    ame219_lcStack.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_lcCard.contentView addSubview:ame219_lcStack];

    UIView *ame219_lcHead = [[UIView alloc] init];
    UIView *ame219_lcTile = [self ame219_iconTile:ame219_inLC ? @"square.3.layers.3d" : @"checkmark.shield"
                                            filled:YES];
    ame219_lcTile.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_lcHead addSubview:ame219_lcTile];
    UILabel *ame219_lcTitle = [[UILabel alloc] init];
    ame219_lcTitle.text = ame219_inLC ? localize(@"welcome.env.lc.detected", nil)
                                      : localize(@"welcome.env.notlc", nil);
    ame219_lcTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    ame219_lcTitle.textColor = [UIColor labelColor];
    ame219_lcTitle.numberOfLines = 0;
    ame219_lcTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_lcHead addSubview:ame219_lcTitle];
    [NSLayoutConstraint activateConstraints:@[
        [ame219_lcTile.leadingAnchor constraintEqualToAnchor:ame219_lcHead.leadingAnchor constant:14],
        [ame219_lcTile.centerYAnchor constraintEqualToAnchor:ame219_lcHead.centerYAnchor],
        [ame219_lcTile.widthAnchor constraintEqualToConstant:34],
        [ame219_lcTile.heightAnchor constraintEqualToConstant:34],
        [ame219_lcTitle.leadingAnchor constraintEqualToAnchor:ame219_lcTile.trailingAnchor constant:12],
        [ame219_lcTitle.trailingAnchor constraintEqualToAnchor:ame219_lcHead.trailingAnchor constant:-14],
        [ame219_lcTitle.topAnchor constraintEqualToAnchor:ame219_lcHead.topAnchor constant:12],
        [ame219_lcTitle.bottomAnchor constraintEqualToAnchor:ame219_lcHead.bottomAnchor constant:-12],
    ]];
    [ame219_lcStack addArrangedSubview:ame219_lcHead];

    if (ame219_inLC) {
        // 包名对照区（当前包名 vs LiveContainer 宿主包名）
        UILabel *ame219_pair = [[UILabel alloc] init];
        ame219_pair.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
        ame219_pair.textColor = [UIColor secondaryLabelColor];
        ame219_pair.numberOfLines = 0;
        ame219_pair.text = [NSString stringWithFormat:
            @"%@: %@\n%@: %@",
            localize(@"welcome.env.lc.current", nil), ame219_mainId ?: @"?",
            localize(@"welcome.env.lc.host", nil), ame219_hostId ?: @"?"];
        [ame219_lcStack addArrangedSubview:ame219_pair];

        if (ame219_idOk) {
            // 包名已由 LC 接管 → JIT 工具可识别（绿色确认行）
            UILabel *ame219_ok = [[UILabel alloc] init];
            ame219_ok.text = [NSString stringWithFormat:localize(@"welcome.env.lc.ok", nil), ame219_hostId];
            ame219_ok.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            ame219_ok.textColor = [UIColor systemGreenColor];
            ame219_ok.numberOfLines = 0;
            [ame219_lcStack addArrangedSubview:ame219_ok];
        } else {
            // 不一致 → 用户指令原文指引（Task219 ②："Please open use
            // livecontainer's bundle id in livecontainer"）+ 复制宿主包名。
            UILabel *ame219_warn = [[UILabel alloc] init];
            ame219_warn.text = localize(@"welcome.env.lc.mismatch.title", nil);
            ame219_warn.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
            ame219_warn.textColor = [UIColor systemOrangeColor];
            ame219_warn.numberOfLines = 0;
            [ame219_lcStack addArrangedSubview:ame219_warn];
            UILabel *ame219_body = [[UILabel alloc] init];
            ame219_body.text = [NSString stringWithFormat:localize(@"welcome.env.lc.mismatch.body", nil),
                ame219_mainId ?: @"?", ame219_hostId ?: @"?"];
            ame219_body.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
            ame219_body.textColor = [UIColor secondaryLabelColor];
            ame219_body.numberOfLines = 0;
            [ame219_lcStack addArrangedSubview:ame219_body];
            if (ame219_hostId.length > 0) {
                UIButton *ame219_copy = [UIButton buttonWithType:UIButtonTypeSystem];
                [ame219_copy setTitle:[NSString stringWithFormat:localize(@"welcome.env.lc.copy", nil), ame219_hostId]
                              forState:UIControlStateNormal];
                ame219_copy.titleLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightMedium];
                [ame219_copy setTitleColor:accentColor() forState:UIControlStateNormal];
                ame219_copy.backgroundColor = [accentColor() colorWithAlphaComponent:0.10];
                ame219_copy.layer.cornerRadius = 10;
                ame219_copy.layer.cornerCurve = kCACornerCurveContinuous;
                ame219_copy.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
                ame219_copy.translatesAutoresizingMaskIntoConstraints = NO;
                [ame219_copy addTarget:self action:@selector(ame219_copyHostId)
                          forControlEvents:UIControlEventTouchUpInside];
                [ame219_lcStack addArrangedSubview:ame219_copy];
                [ame219_copy.heightAnchor constraintEqualToConstant:36].active = YES;
            }
        }
    }

    // ---- ③ JIT 状态行 + 方式选择 ----
    UILabel *ame219_jitSection = [[UILabel alloc] init];
    ame219_jitSection.text = localize(@"welcome.jit.title", nil);
    ame219_jitSection.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
    ame219_jitSection.textColor = [self ame224_directTextColor];   // Task224：壁纸直排自适应
    ame219_jitSection.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_jitSection];

    UILabel *ame219_jitSub = [[UILabel alloc] init];
    ame219_jitSub.text = localize(@"welcome.jit.subtitle", nil);
    ame219_jitSub.font = [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
    ame219_jitSub.textColor = [self ame224_directSecondaryColor];   // Task224：壁纸直排自适应
    ame219_jitSub.numberOfLines = 0;
    ame219_jitSub.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_jitSub];

    // 状态行（图标 + 文案 + 立即开启按钮）
    UIVisualEffectView *ame219_statusCard = [self ame224_materialCard];
    ame219_statusCard.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_statusCard];
    UIView *ame219_statusRow = [[UIView alloc] init];
    ame219_statusRow.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_statusCard.contentView addSubview:ame219_statusRow];

    UIImageView *ame219_jitIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"hare"]];
    ame219_jitIcon.tintColor = [UIColor systemOrangeColor];
    ame219_jitIcon.contentMode = UIViewContentModeScaleAspectFit;
    ame219_jitIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_statusRow addSubview:ame219_jitIcon];

    self.jitStatusLabel = [[UILabel alloc] init];
    self.jitStatusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.jitStatusLabel.textColor = [UIColor secondaryLabelColor];
    self.jitStatusLabel.numberOfLines = 0;
    self.jitStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_statusRow addSubview:self.jitStatusLabel];

    UIButton *ame219_enableBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [ame219_enableBtn setTitle:localize(@"welcome.jit.enable_now", nil) forState:UIControlStateNormal];
    ame219_enableBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [ame219_enableBtn setTitleColor:accentColor() forState:UIControlStateNormal];
    ame219_enableBtn.backgroundColor = [accentColor() colorWithAlphaComponent:0.12];
    ame219_enableBtn.layer.cornerRadius = 10;
    ame219_enableBtn.layer.cornerCurve = kCACornerCurveContinuous;
    ame219_enableBtn.contentEdgeInsets = UIEdgeInsetsMake(8, 14, 8, 14);
    ame219_enableBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_enableBtn addTarget:self action:@selector(ame219_enableJitNow)
               forControlEvents:UIControlEventTouchUpInside];
    [ame219_statusRow addSubview:ame219_enableBtn];

    [NSLayoutConstraint activateConstraints:@[
        [ame219_jitIcon.leadingAnchor constraintEqualToAnchor:ame219_statusRow.leadingAnchor constant:14],
        [ame219_jitIcon.centerYAnchor constraintEqualToAnchor:ame219_statusRow.centerYAnchor],
        [ame219_jitIcon.widthAnchor constraintEqualToConstant:24],
        [ame219_jitIcon.heightAnchor constraintEqualToConstant:24],
        [self.jitStatusLabel.leadingAnchor constraintEqualToAnchor:ame219_jitIcon.trailingAnchor constant:12],
        [self.jitStatusLabel.topAnchor constraintEqualToAnchor:ame219_statusRow.topAnchor constant:12],
        [self.jitStatusLabel.bottomAnchor constraintEqualToAnchor:ame219_statusRow.bottomAnchor constant:-12],
        [ame219_enableBtn.leadingAnchor constraintEqualToAnchor:self.jitStatusLabel.trailingAnchor constant:10],
        [ame219_enableBtn.trailingAnchor constraintEqualToAnchor:ame219_statusRow.trailingAnchor constant:-14],
        [ame219_enableBtn.centerYAnchor constraintEqualToAnchor:ame219_statusRow.centerYAnchor],
        [ame219_enableBtn.heightAnchor constraintEqualToConstant:36],
    ]];

    // 方式选择卡（debug.jit_enabler 七选项，键文案复用设置页）
    UIVisualEffectView *ame219_jitGroup = [self ame224_materialCard];
    ame219_jitGroup.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_jitGroup];
    UIStackView *ame219_jitRows = [[UIStackView alloc] init];
    ame219_jitRows.axis = UILayoutConstraintAxisVertical;
    ame219_jitRows.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_jitGroup.contentView addSubview:ame219_jitRows];

    self.jitRows = [NSMutableArray array];
    NSArray<NSString *> *ame219_keys = @[@"auto", @"stikjit", @"sidestore", @"stosdebug",
                                         @"jitstreamer", @"trollstore", @"manual"];
    NSArray<NSString *> *ame219_names = @[
        localize(@"preference.debug.jit_enabler.auto", nil),
        localize(@"preference.debug.jit_enabler.stikjit", nil),
        localize(@"preference.debug.jit_enabler.sidestore", nil),
        localize(@"preference.debug.jit_enabler.stosdebug", nil),
        localize(@"preference.debug.jit_enabler.jitstreamer", nil),
        localize(@"preference.debug.jit_enabler.trollstore", nil),
        localize(@"preference.debug.jit_enabler.manual", nil),
    ];
    for (NSUInteger i = 0; i < ame219_keys.count; i++) {
        // Task224：选项行改 UIButton + tag（UIControl 命中测试 + 固定 54pt）
        UIButton *ame224_row = [self ame224_selectionRowWithIcon:@"bolt"
                                                           title:ame219_names[i]
                                                        subtitle:nil];
        ame224_row.tag = 1000 + (NSInteger)i;
        [ame224_row addTarget:self action:@selector(ame224_jitRowTapped:)
           forControlEvents:UIControlEventTouchUpInside];
        [ame219_jitRows addArrangedSubview:ame224_row];
        [self.jitRows addObject:ame224_row];
    }

    // JIT 说明（LiveContainer 下的包名识别口径）
    UILabel *ame219_jitHint = [[UILabel alloc] init];
    ame219_jitHint.text = localize(ame219_inLC ? @"welcome.jit.hint.lc" : @"welcome.jit.hint", nil);
    ame219_jitHint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    ame219_jitHint.textColor = [self ame224_directSecondaryColor];
    ame219_jitHint.numberOfLines = 0;
    ame219_jitHint.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_jitHint];

    [NSLayoutConstraint activateConstraints:@[
        [ame219_lcCard.topAnchor constraintEqualToAnchor:ame219_anchor.bottomAnchor constant:18],
        [ame219_lcCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_lcCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [ame219_lcStack.topAnchor constraintEqualToAnchor:ame219_lcCard.contentView.topAnchor constant:8],
        [ame219_lcStack.leadingAnchor constraintEqualToAnchor:ame219_lcCard.contentView.leadingAnchor constant:6],
        [ame219_lcStack.trailingAnchor constraintEqualToAnchor:ame219_lcCard.contentView.trailingAnchor constant:-14],
        [ame219_lcStack.bottomAnchor constraintEqualToAnchor:ame219_lcCard.contentView.bottomAnchor constant:-10],

        [ame219_jitSection.topAnchor constraintEqualToAnchor:ame219_lcCard.bottomAnchor constant:22],
        [ame219_jitSection.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_jitSection.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [ame219_jitSub.topAnchor constraintEqualToAnchor:ame219_jitSection.bottomAnchor constant:4],
        [ame219_jitSub.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_jitSub.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],

        [ame219_statusCard.topAnchor constraintEqualToAnchor:ame219_jitSub.bottomAnchor constant:12],
        [ame219_statusCard.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_statusCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [ame219_statusRow.topAnchor constraintEqualToAnchor:ame219_statusCard.contentView.topAnchor],
        [ame219_statusRow.leadingAnchor constraintEqualToAnchor:ame219_statusCard.contentView.leadingAnchor],
        [ame219_statusRow.trailingAnchor constraintEqualToAnchor:ame219_statusCard.contentView.trailingAnchor],
        [ame219_statusRow.bottomAnchor constraintEqualToAnchor:ame219_statusCard.contentView.bottomAnchor],

        [ame219_jitGroup.topAnchor constraintEqualToAnchor:ame219_statusCard.bottomAnchor constant:12],
        [ame219_jitGroup.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_jitGroup.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [ame219_jitRows.topAnchor constraintEqualToAnchor:ame219_jitGroup.contentView.topAnchor constant:6],
        [ame219_jitRows.leadingAnchor constraintEqualToAnchor:ame219_jitGroup.contentView.leadingAnchor constant:6],
        [ame219_jitRows.trailingAnchor constraintEqualToAnchor:ame219_jitGroup.contentView.trailingAnchor constant:-6],
        [ame219_jitRows.bottomAnchor constraintEqualToAnchor:ame219_jitGroup.contentView.bottomAnchor constant:-6],

        [ame219_jitHint.topAnchor constraintEqualToAnchor:ame219_jitGroup.bottomAnchor constant:10],
        [ame219_jitHint.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:4],
        [ame219_jitHint.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-4],
        // Task224：链尾 ≤ 底锚（原 == 与高度下限冲突 → 歧义/断链；≤ 唯一可解）
        [ame219_jitHint.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-8],
    ]];

    [self ame219_refreshJitStatus];
    [self ame219_refreshJitRows];
}

/// Task224：JIT 方式行点按（UIButton tag 回带索引）。
- (void)ame224_jitRowTapped:(UIButton *)sender {
    NSInteger ame224_i = (NSInteger)sender.tag - 1000;
    NSArray<NSString *> *ame219_keys = @[@"auto", @"stikjit", @"sidestore", @"stosdebug",
                                         @"jitstreamer", @"trollstore", @"manual"];
    if (ame224_i < 0 || (NSUInteger)ame224_i >= ame219_keys.count) return;
    self.pickedJitEnabler = ame219_keys[(NSUInteger)ame224_i];
    [self ame219_refreshJitRows];
}

- (void)ame219_refreshJitRows {
    NSArray<NSString *> *ame219_keys = @[@"auto", @"stikjit", @"sidestore", @"stosdebug",
                                         @"jitstreamer", @"trollstore", @"manual"];
    for (NSUInteger i = 0; i < self.jitRows.count; i++) {
        [self ame219_refreshOptionRow:self.jitRows[i]
                            selected:[self.pickedJitEnabler isEqualToString:ame219_keys[i]]];
    }
}

/// JIT 状态刷新（构建时/回前台时调用）。
- (void)ame219_refreshJitStatus {
    if (self.jitStatusLabel == nil) return;
    BOOL ame219_on = isJITEnabled(NO);
    self.jitStatusLabel.text = ame219_on ? localize(@"welcome.jit.status.on", nil)
                                         : localize(@"welcome.jit.status.off", nil);
    self.jitStatusLabel.textColor = ame219_on ? [UIColor systemGreenColor] : [UIColor secondaryLabelColor];
}

/// 复制宿主包名（②指引的配套动作）。
- (void)ame219_copyHostId {
    NSString *ame219_hostId = [WelcomeViewController liveContainerHostBundleId];
    if (ame219_hostId.length == 0) return;
    [UIPasteboard generalPasteboard].string = ame219_hostId;
    UIAlertController *ame219_alert = [UIAlertController
        alertControllerWithTitle:localize(@"welcome.env.lc.copied", nil)
                         message:ame219_hostId
                  preferredStyle:UIAlertControllerStyleAlert];
    [ame219_alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"好的")
                                                     style:UIAlertActionStyleDefault
                                                   handler:nil]];
    [self presentViewController:ame219_alert animated:YES completion:nil];
}

/// 立即开启 JIT（③）：按当前选择拉起对应工具的 URL（右面板 Task134 分发
/// 的同款语义——向导里只拉起不挂等待链；回前台时状态行自动刷新）。
- (void)ame219_enableJitNow {
    NSString *ame219_enabler = self.pickedJitEnabler ?: @"auto";
    NSString *ame219_bundleId = NSBundle.mainBundle.bundleIdentifier;
    NSString *ame219_appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Prisma";
    NSURL *ame219_url = nil;
    NSString *ame219_tool = ame219_enabler;

    if ([ame219_enabler isEqualToString:@"trollstore"]) {
        ame219_url = [NSURL URLWithString:[NSString stringWithFormat:
            @"apple-magnifier://enable-jit?bundle-id=%@", ame219_bundleId]];
        ame219_tool = @"apple-magnifier://";
    } else if ([ame219_enabler isEqualToString:@"sidestore"]) {
        ame219_url = [NSURL URLWithString:[NSString stringWithFormat:
            @"sidestore://enable-jit?bundle-id=%@", ame219_bundleId]];
        ame219_tool = @"sidestore://";
    } else if ([ame219_enabler isEqualToString:@"stosdebug"]) {
        NSMutableString *ame219_m = [NSMutableString stringWithFormat:
            @"stosdebug://enableJIT?bundleId=%@&appName=%@", ame219_bundleId, ame219_appName];
        NSData *ame219_script = [NSData dataWithContentsOfFile:
            [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
        if (ame219_script) {
            [ame219_m appendFormat:@"&script=%@", [ame219_script base64EncodedStringWithOptions:0]];
        }
        ame219_url = [NSURL URLWithString:ame219_m];
        ame219_tool = @"stosdebug://";
    } else if ([ame219_enabler isEqualToString:@"jitstreamer"]) {
        ame219_url = [NSURL URLWithString:[NSString stringWithFormat:
            @"http://[fd00::]:9172/launch_app/%@", ame219_bundleId]];
        ame219_tool = @"jitstreamer";
    } else if ([ame219_enabler isEqualToString:@"manual"]) {
        // 手动：不拉起（用户自己附加调试器），仅刷新状态提示
        [self ame219_refreshJitStatus];
        return;
    } else {
        // auto / stikjit：stikjit://（附 JIT26 脚本，右面板 Task134 同款）
        NSMutableString *ame219_m = [NSMutableString stringWithFormat:
            @"stikjit://enable-jit?bundle-id=%@&pid=%d", ame219_bundleId, getpid()];
        NSData *ame219_script = [NSData dataWithContentsOfFile:
            [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
        if (ame219_script) {
            [ame219_m appendFormat:@"&script-data=%@", [ame219_script base64EncodedStringWithOptions:0]];
        }
        ame219_url = [NSURL URLWithString:ame219_m];
        ame219_tool = @"stikjit://";
    }

    if (ame219_url == nil) {
        [self ame219_refreshJitStatus];
        return;
    }
    NSLog(@"[Welcome] Task219: firing JIT enabler %@ from onboarding", ame219_tool);
    [UIApplication.sharedApplication openURL:ame219_url options:@{}
        completionHandler:^(BOOL ame219_ok) {
        NSLog(@"[Welcome] Task219 openURL %@ -> %d", ame219_tool, ame219_ok);
        if (!ame219_ok) {
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ame219_alert = [UIAlertController
                    alertControllerWithTitle:localize(@"Error", nil)
                                     message:[NSString stringWithFormat:
                                         localize(@"ame193.misc.jit_not_handled", @"%@ 未接管启动请求（未安装或版本过旧？）。请换用其它工具后重试。"), ame219_tool]
                              preferredStyle:UIAlertControllerStyleAlert];
                [ame219_alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"好的")
                                                                  style:UIAlertActionStyleDefault
                                                                handler:nil]];
                [self presentViewController:ame219_alert animated:YES completion:nil];
            });
        }
    }];
}

#pragma mark - 步骤内容：3 下载源

- (void)ame218_buildSourceStep:(UIView *)container {
    [self ame219_addHeaderTo:container
                       title:localize(@"welcome.source.title", nil)
                    subtitle:localize(@"welcome.source.subtitle", nil)];
    UIView *ame219_anchor = container.subviews.lastObject;

    UIVisualEffectView *ame219_group = [self ame224_materialCard];
    ame219_group.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame219_group];
    UIStackView *ame219_rows = [[UIStackView alloc] init];
    ame219_rows.axis = UILayoutConstraintAxisVertical;
    ame219_rows.translatesAutoresizingMaskIntoConstraints = NO;
    [ame219_group.contentView addSubview:ame219_rows];

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
        // Task224：选项行改 UIButton + tag（UIControl 命中测试 + 固定 68pt）
        UIButton *ame224_row = [self ame224_selectionRowWithIcon:ame218_icons[i]
                                                           title:ame218_names[i]
                                                        subtitle:ame218_descs[i]];
        ame224_row.tag = 2000 + (NSInteger)i;
        [ame224_row addTarget:self action:@selector(ame224_sourceRowTapped:)
           forControlEvents:UIControlEventTouchUpInside];
        [ame219_rows addArrangedSubview:ame224_row];
        [self.sourceCards addObject:ame224_row];
    }

    [NSLayoutConstraint activateConstraints:@[
        [ame219_group.topAnchor constraintEqualToAnchor:ame219_anchor.bottomAnchor constant:22],
        [ame219_group.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame219_group.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [ame219_rows.topAnchor constraintEqualToAnchor:ame219_group.contentView.topAnchor constant:6],
        [ame219_rows.leadingAnchor constraintEqualToAnchor:ame219_group.contentView.leadingAnchor constant:6],
        [ame219_rows.trailingAnchor constraintEqualToAnchor:ame219_group.contentView.trailingAnchor constant:-6],
        [ame219_rows.bottomAnchor constraintEqualToAnchor:ame219_group.contentView.bottomAnchor constant:-6],
        // Task224：链尾 ≤ 底锚（配合 showStep 高度下限——步骤高度唯一可解）
        [ame219_group.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-10],
    ]];

    [self ame218_refreshSourceCards];
}

/// Task224：下载源行点按（UIButton tag 回带索引）。
- (void)ame224_sourceRowTapped:(UIButton *)sender {
    NSInteger ame224_i = (NSInteger)sender.tag - 2000;
    NSArray<NSString *> *ame218_values = @[@"official_first", @"mirror_first", @"speed_first"];
    if (ame224_i < 0 || (NSUInteger)ame224_i >= ame218_values.count) return;
    self.pickedSource = ame218_values[(NSUInteger)ame224_i];
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
        [self ame219_refreshOptionRow:self.sourceCards[i]
                            selected:[self.pickedSource isEqualToString:ame218_values[i]]];
    }
}

#pragma mark - 步骤内容：4 数据迁移

- (void)ame218_buildDataStep:(UIView *)container {
    [self ame219_addHeaderTo:container
                       title:localize(@"welcome.data.title", nil)
                    subtitle:localize(@"welcome.data.subtitle", nil)];
    __block UIView *ame219_anchor = container.subviews.lastObject;   // Task223 CI 修复：ame223_addRow 块内重指锚（ame223 重建数据步骤引入）

    // ★ Task223（清单第 15 项）：选项行改真 UIAction 按钮（旧 UITapGestureRecognizer
    //   挂在零高度/被拉伸的普通 UIView 上 = “部分按键仍点击不了”的头号嫌疑；
    //   UIControl 的命中测试 + 固定行高 = 稳定可点 + 不再“拉得特别长”。
    //   行样式：iOS 设置风格（图标块 + 双行文字 + chevron），固定 68pt。
    void (^ame223_addRow)(NSString *symbol, NSString *title, NSString *subtitle, SEL action) = ^(NSString *symbol, NSString *title, NSString *subtitle, SEL action) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.accessibilityLabel = title;
        row.accessibilityHint = subtitle;
        [row addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        row.backgroundColor = [[UIColor secondarySystemGroupedBackgroundColor] colorWithAlphaComponent:0.92];
        row.layer.cornerRadius = 14.0;
        row.layer.cornerCurve = kCACornerCurveContinuous;
        row.translatesAutoresizingMaskIntoConstraints = NO;

        UIView *tile = [self ame219_iconTile:symbol filled:NO];
        tile.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:tile];

        UILabel *t = [[UILabel alloc] init];
        t.text = title;
        t.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        t.textColor = [UIColor labelColor];
        t.userInteractionEnabled = NO;
        t.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:t];

        UILabel *s = [[UILabel alloc] init];
        s.text = subtitle;
        s.font = [UIFont systemFontOfSize:12];
        s.textColor = [UIColor secondaryLabelColor];
        s.numberOfLines = 2;
        s.userInteractionEnabled = NO;
        s.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:s];

        UIImageView *chev = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        chev.tintColor = [UIColor tertiaryLabelColor];
        chev.contentMode = UIViewContentModeScaleAspectFit;
        chev.userInteractionEnabled = NO;
        chev.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:chev];

        [container addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.topAnchor constraintEqualToAnchor:ame219_anchor.bottomAnchor constant:22],
            [row.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [row.heightAnchor constraintEqualToConstant:68],
            [tile.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
            [tile.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [tile.widthAnchor constraintEqualToConstant:34],
            [tile.heightAnchor constraintEqualToConstant:34],
            [t.leadingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:12],
            [t.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
            [s.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
            [s.trailingAnchor constraintEqualToAnchor:chev.leadingAnchor constant:-8],
            [s.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:2],
            [chev.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
            [chev.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [chev.widthAnchor constraintEqualToConstant:14],
        ]];
        ame219_anchor = row;
    };

    // 主选项：从备份导入
    ame223_addRow(@"square.and.arrow.down",
                  localize(@"welcome.data.import", nil),
                  localize(@"welcome.data.import.desc", nil),
                  @selector(ame218_importTapped2));

    // 次选项：跳过（新装无数据）
    ame223_addRow(@"arrow.right.circle",
                  localize(@"welcome.data.skip", nil),
                  localize(@"welcome.data.skip.desc", nil),
                  @selector(ame218_dataSkipTapped2));

    // 底部贴边（内容链尾锚到容器底——消除高度歧义，步骤内容不再异常拉伸）。
    [ame219_anchor.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-8].active = YES;
}

- (void)ame218_importTapped2 {
    // 从备份导入：复用 Task217 数据桥（系统文件选择器 + zip 净化 + 合并）。
    // 导入完成后的重启提示由 DataTransferService 自己弹；向导不阻拦。
    NSLog(@"[Welcome] Task218: data import requested in onboarding");
    [[DataTransferService sharedService] importDataFromViewController:self];
}

- (void)ame218_dataSkipTapped2 {
    // Task224：跳过数据迁移 → 特性介绍页（5）——Next 会先走灰屏圆圈焦点
    // 介绍再进 Done（旧代码直达 6，把介绍页也跳掉了——Task222 注释与行为
    // 不符的存量偏差，本轮顺手对齐）。
    [self ame218_showStep:5 animated:YES];
}

#pragma mark - 步骤内容：5 zl2 风格介绍页（Task222，清单第 17 项）

/// zl2（ZalithLauncher2）风格的特性介绍页：插入在数据迁移与完成页之间。
/// 品牌图标 + 特性行列表（SF 图标 + 标题 + 副标题）+ 社区卡（QQ 群/爱发电，
/// 与关于页/README 同源信息）。完成后下一步即 Done（自动弹关于页）。
- (void)ame222_buildIntroStep:(UIView *)container {
    // ★ Task223（清单第 16 项第一半）：本页 Task222 版在装机上是“黑屏完全
    //   用不了”——内层 UIScrollView 与 contentLayoutGuide 双重定宽（冲突）+
    //   特性行 alpha=0 依赖动画救活（动画被打断即永久透明）。重写为与其
    //   它步骤同构的【直接布局】：无内层滚动（外层 contentScrollView 已有
    //   滚动）、可见即渲染（无 alpha 依赖）、卡片底色用半透明分组色
    //   （壁纸/深浅色下都可见）。zl2 灰屏圆圈焦点介绍（coach marks）在
    //   完成向导后、打开关于页前呈现（见 ame218_finishOpenAbout）。
    [self ame219_addHeaderTo:container
                       title:localize(@"welcome.intro.title", nil)
                    subtitle:localize(@"welcome.intro.subtitle", nil)];
    UIView *ame222_anchor = container.subviews.lastObject;

    // ★ Task225（反馈 #9）：特性清单重写为【Prisma 独有优势】——旧四条
    //   （多版本加载器/中文优化/TouchController/联机）上游全都拥有，用户
    //   指令原话："要找出比上游好的优点，而不是上游本来就拥有的功能"。
    //   新六条全部来自本 fork 的差异化工程（每条都有装机日志/提交锚点）：
    //   f1 渲染器矩阵+设备级性能根修（mg/zink+FSR/ANGLE/VirGL/gl4es + 帧率
    //      分解取证，26.3 整合包 30fps 根修、dynamic-fps 免疫）
    //   f2 深度输入链（虚拟键盘全链打字、后台恢复输入重建、手柄/摇杆四向、
    //      键位净化保护）
    //   f3 数据安全（隔离目录完整性+迁移、模组重导入自动备份、键位标记随迁）
    //   f4 并行导出引擎（3 线程压缩 + 分区选择 + 全维度进度）
    //   f5 外观体系（液态玻璃/动态文字反色/界面+文字双缩放/壁纸亮度自适应）
    //   f6 深度诊断（FAQ 标签页 + 崩溃取证链 + 设备日志锚点驱动修复）
    NSArray<NSDictionary *> *ame222_features = @[
        @{@"icon": @"speedometer.fill", @"t": @"welcome.intro.f1.title", @"b": @"welcome.intro.f1.body"},
        @{@"icon": @"keyboard.fill", @"t": @"welcome.intro.f2.title", @"b": @"welcome.intro.f2.body"},
        @{@"icon": @"externaldrive.badge.timemachine", @"t": @"welcome.intro.f3.title", @"b": @"welcome.intro.f3.body"},
        @{@"icon": @"square.and.arrow.up.fill", @"t": @"welcome.intro.f4.title", @"b": @"welcome.intro.f4.body"},
        @{@"icon": @"paintpalette.fill", @"t": @"welcome.intro.f5.title", @"b": @"welcome.intro.f5.body"},
        @{@"icon": @"stethoscope.fill", @"t": @"welcome.intro.f6.title", @"b": @"welcome.intro.f6.body"},
    ];
    for (NSDictionary *f in ame222_features) {
        UIView *row = [[UIView alloc] init];
        row.backgroundColor = [[UIColor secondarySystemGroupedBackgroundColor] colorWithAlphaComponent:0.92];
        row.layer.cornerRadius = 14.0;
        row.layer.cornerCurve = kCACornerCurveContinuous;
        row.translatesAutoresizingMaskIntoConstraints = NO;

        UIView *tile = [self ame219_iconTile:f[@"icon"] filled:YES];
        tile.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:tile];

        UILabel *t = [[UILabel alloc] init];
        t.text = localize(f[@"t"], nil);
        t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        t.textColor = [UIColor labelColor];
        t.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:t];

        UILabel *b = [[UILabel alloc] init];
        b.text = localize(f[@"b"], nil);
        b.font = [UIFont systemFontOfSize:12];
        b.textColor = [UIColor secondaryLabelColor];
        b.numberOfLines = 0;
        b.translatesAutoresizingMaskIntoConstraints = NO;
        [row addSubview:b];

        [container addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.topAnchor constraintEqualToAnchor:ame222_anchor.bottomAnchor constant:14],
            [row.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
            [tile.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:14],
            [tile.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
            [tile.widthAnchor constraintEqualToConstant:34],
            [tile.heightAnchor constraintEqualToConstant:34],
            [t.leadingAnchor constraintEqualToAnchor:tile.trailingAnchor constant:12],
            [t.topAnchor constraintEqualToAnchor:row.topAnchor constant:12],
            [b.leadingAnchor constraintEqualToAnchor:t.leadingAnchor],
            [b.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-14],
            [b.topAnchor constraintEqualToAnchor:t.bottomAnchor constant:2],
            [b.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-12],
        ]];
        ame222_anchor = row;
    }

    // 社区卡（QQ 群 + 爱发电；与关于页/README 同源信息）
    UIView *comm = [[UIView alloc] init];
    comm.backgroundColor = [accentColor() colorWithAlphaComponent:0.14];
    comm.layer.cornerRadius = 14.0;
    comm.layer.cornerCurve = kCACornerCurveContinuous;
    comm.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *commTitle = [[UILabel alloc] init];
    commTitle.text = localize(@"welcome.intro.community.title", nil);
    commTitle.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    commTitle.textColor = [UIColor labelColor];
    commTitle.textAlignment = NSTextAlignmentCenter;
    commTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [comm addSubview:commTitle];

    UILabel *commHint = [[UILabel alloc] init];
    commHint.text = localize(@"welcome.intro.community.hint", nil);
    commHint.font = [UIFont systemFontOfSize:12];
    commHint.textColor = [UIColor secondaryLabelColor];
    commHint.textAlignment = NSTextAlignmentCenter;
    commHint.numberOfLines = 0;
    commHint.translatesAutoresizingMaskIntoConstraints = NO;
    [comm addSubview:commHint];

    [container addSubview:comm];
    [NSLayoutConstraint activateConstraints:@[
        [comm.topAnchor constraintEqualToAnchor:ame222_anchor.bottomAnchor constant:14],
        [comm.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [comm.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [commTitle.topAnchor constraintEqualToAnchor:comm.topAnchor constant:12],
        [commTitle.leadingAnchor constraintEqualToAnchor:comm.leadingAnchor constant:14],
        [commTitle.trailingAnchor constraintEqualToAnchor:comm.trailingAnchor constant:-14],
        [commHint.topAnchor constraintEqualToAnchor:commTitle.bottomAnchor constant:4],
        [commHint.leadingAnchor constraintEqualToAnchor:comm.leadingAnchor constant:14],
        [commHint.trailingAnchor constraintEqualToAnchor:comm.trailingAnchor constant:-14],
        [commHint.bottomAnchor constraintEqualToAnchor:comm.bottomAnchor constant:-12],
    ]];

    // 底部提示 + 内容链尾锚（高度无歧义）
    UILabel *next = [[UILabel alloc] init];
    next.text = localize(@"welcome.intro.focus_hint", nil);   // Task224：Next 先走焦点引导再进完成页
    next.font = [UIFont systemFontOfSize:11];
    next.textColor = [self ame224_directSecondaryColor];   // Task224：壁纸直排自适应
    next.textAlignment = NSTextAlignmentCenter;
    next.numberOfLines = 0;
    next.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:next];
    [NSLayoutConstraint activateConstraints:@[
        [next.topAnchor constraintEqualToAnchor:comm.bottomAnchor constant:12],
        [next.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [next.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [next.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-8],
    ]];
}

#pragma mark - 步骤内容：6 完成

- (void)ame218_buildDoneStep:(UIView *)container {
    UIView *ame218_center = [[UIView alloc] init];
    ame218_center.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:ame218_center];

    UIImageView *ame218_check = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"checkmark.circle.fill"]];
    ame218_check.tintColor = [UIColor systemGreenColor];
    ame218_check.contentMode = UIViewContentModeScaleAspectFit;
    ame218_check.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_check];

    UILabel *ame218_title = [[UILabel alloc] init];
    ame218_title.text = localize(@"welcome.done.title", nil);
    ame218_title.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    ame218_title.textColor = [self ame224_directTextColor];   // Task224：壁纸直排自适应
    ame218_title.textAlignment = NSTextAlignmentCenter;
    ame218_title.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_title];

    UILabel *ame218_sub = [[UILabel alloc] init];
    ame218_sub.text = localize(@"welcome.done.subtitle", nil);
    ame218_sub.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    ame218_sub.textColor = [self ame224_directSecondaryColor];   // Task224：壁纸直排自适应
    ame218_sub.textAlignment = NSTextAlignmentCenter;
    ame218_sub.numberOfLines = 0;
    ame218_sub.translatesAutoresizingMaskIntoConstraints = NO;
    [ame218_center addSubview:ame218_sub];

    [NSLayoutConstraint activateConstraints:@[
        [ame218_center.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [ame218_center.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [ame218_center.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [ame218_center.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        // Task224（#14 根治）：≥/≤ 包边——配合 showStep 的高度下限，居中页
        // 高度唯一可解（Task223 版只有 centerY = 歧义高度 → 触点出界）。
        [ame218_center.topAnchor constraintGreaterThanOrEqualToAnchor:container.topAnchor constant:16],
        [ame218_center.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-16],

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

/// 完成页礼花（一次性迸发后清除）。
- (void)ame218_fireConfettiBurst {
    CAEmitterLayer *ame219_confetti = [CAEmitterLayer layer];
    ame219_confetti.frame = self.view.bounds;
    ame219_confetti.emitterPosition = CGPointMake(self.view.bounds.size.width / 2.0,
                                                  self.view.bounds.size.height * 0.62);
    ame219_confetti.emitterSize = CGSizeMake(self.view.bounds.size.width * 0.7, 10);
    ame219_confetti.emitterShape = kCAEmitterLayerLine;
    CAEmitterCell *ame218_cell = [CAEmitterCell emitterCell];
    ame218_cell.scale = 0.14;
    ame218_cell.scaleRange = 0.18;
    ame218_cell.color = [UIColor colorWithRed:1.0 green:0.92 blue:0.70 alpha:1.0].CGColor;
    ame218_cell.alphaRange = 0.25;
    ame218_cell.alphaSpeed = -0.35;
    ame218_cell.lifetime = 4.0;
    ame218_cell.lifetimeRange = 1.5;
    ame218_cell.birthRate = 90.0;
    ame218_cell.velocity = 320.0;
    ame218_cell.velocityRange = 200.0;
    ame218_cell.yAcceleration = 190.0;
    ame218_cell.emissionLongitude = (CGFloat)M_PI;      // 朝上
    ame218_cell.emissionRange = (CGFloat)M_PI;
    ame218_cell.spin = 3.0;
    ame218_cell.spinRange = 5.0;
    ame219_confetti.emitterCells = @[ame218_cell];
    [self.view.layer addSublayer:ame219_confetti];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ame219_confetti removeFromSuperlayer];
    });
}

@end



