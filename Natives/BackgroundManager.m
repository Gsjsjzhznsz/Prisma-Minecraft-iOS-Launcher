#import <objc/runtime.h>   // Task232：外扩描边标记（ame224_applyAdaptiveTextToLabel 在 1160 行区域使用，导入必须前置于此）
#import "utils.h"
//
//  BackgroundManager.m
//  Amethyst
//
//  Background wallpaper manager implementation - Global Version with Transparency
//

#import "BackgroundManager.h"
#import "UIKit+NativeSurface.h"
#import "LiquidGlassCompat.h"   // Task224（#4）：界面风格（液态玻璃/原生）解析与分层玻璃安装
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>   // Task223：CGImageSource 降采样直取壁纸

static NSString * const kBackgroundTypeKey = @"background_type";
static NSString * const kBackgroundPathKey = @"background_path";
static NSString * const kBackgroundUIEffectKey = @"background_ui_effect";
static NSString * const kBackgroundUIOpacityKey = @"background_ui_opacity";
static NSString * const kBackgroundBlurIntensityKey = @"background_blur_intensity";
// Task172：新拟态界面开关（默认 YES = 卡片永远按规格渲染，与壁纸无关；
// NO = 旧管线毛玻璃/半透明/原生平铺）。Task178：卡片本体透明度滑条恢复
//（Task170 机制，仅淡卡体不含文字，与 UI 效果类型/模糊度彻底解耦）。
// Task210：新拟态偏好 defaults 键（background_cards_neumorph_enabled /
// background_cards_neumorph_opacity）随选项删除一并退役，不再读写。
// Task151：背景来源标记（"user" = 用户手动设置，"bing" = Bing 每日壁纸自动应用）
static NSString * const kBackgroundSourceKey = @"background_source";
static NSString * const kBackgroundsFolder = @"backgrounds";
static const NSInteger kGlobalBackgroundTag = 99999;
static const NSInteger kBackgroundImageTag = 99998;
static const NSInteger kBackgroundBlurTag = 99997;
static const NSInteger kBackgroundDimTag = 99996;
static const NSInteger kDefaultBackgroundTag = 99995;
// Task160：模态弹窗页面级毛玻璃底层的 tag（防重复添加/便于移除重铺）
static const NSInteger kAme160GlassBackdropTag = 99994;

@interface BackgroundManager ()
@property (nonatomic, strong) AVPlayer *videoPlayer;
@property (nonatomic, strong) AVPlayerLayer *videoPlayerLayer;
@property (nonatomic, weak) UIView *currentBackgroundView;
@property (nonatomic, readwrite) BackgroundType currentType;
@property (nonatomic, readwrite, nullable) NSString *currentBackgroundPath;
// Task151：背景来源（@"user"/@"bing"，nil = 历史数据视为 user）
@property (nonatomic, copy, nullable) NSString *backgroundSource;
@property (nonatomic, weak) UIWindow *currentWindow;
@property (nonatomic, weak) UISplitViewController *currentSplitVC;
@property (nonatomic, strong, readwrite, nullable) UIView *globalBackgroundContainer;
@end


// ★ Task232（反馈 #16）：外扩描边标记键——前置定义（ame224_applyAdaptiveTextToLabel
// 在文件前部使用 objc_setAssociatedObject 打标；实现注释见
// ame232_swizzledLabelDrawTextInRect 块）。
static char ame232_OutlineMarkKey;

@implementation BackgroundManager

+ (instancetype)sharedManager {
    static BackgroundManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self loadSavedBackground];
        [self loadUISettings];
        [self setupNotifications];
    }
    return self;
}

- (void)setupNotifications {
    // App lifecycle
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    // Video loop
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(playerItemDidReachEnd:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:nil];
    
    // Orientation changes
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleOrientationChange)
                                                 name:UIApplicationDidChangeStatusBarOrientationNotification
                                               object:nil];
    
    // Window size changes (iPad multitasking, rotation)
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(updateBackgroundFrame)
                                                 name:UIApplicationWillChangeStatusBarFrameNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self cleanupVideoPlayer];
}

#pragma mark - Backgrounds Folder

- (NSString *)backgroundsFolderPath {
    NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *folder = [docsDir stringByAppendingPathComponent:kBackgroundsFolder];
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:folder]) {
        [fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    }
    
    return folder;
}

#pragma mark - Load/Save Background

- (void)loadSavedBackground {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    self.currentType = [defaults integerForKey:kBackgroundTypeKey];
    self.currentBackgroundPath = [defaults stringForKey:kBackgroundPathKey];
    // Task151：读取来源标记；历史数据（升级安装）无标记时视为 user，
    // 保证老用户已设的自定义壁纸不会被 Bing 自动覆盖。
    self.backgroundSource = [defaults stringForKey:kBackgroundSourceKey];
    if (self.backgroundSource.length == 0) {
        self.backgroundSource = (self.currentType != BackgroundTypeNone) ? @"user" : nil;
    }

    // Validate path exists
    if (self.currentBackgroundPath && ![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) {
        self.currentBackgroundPath = nil;
        self.currentType = BackgroundTypeNone;
        self.backgroundSource = nil;
        [self saveBackgroundSettings];
    }
}

- (void)saveBackgroundSettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.currentType forKey:kBackgroundTypeKey];
    [defaults setObject:self.currentBackgroundPath forKey:kBackgroundPathKey];
    // Task151：来源标记随背景持久化（nil 时移除，回退"无标记=user"语义）
    if (self.backgroundSource.length > 0) {
        [defaults setObject:self.backgroundSource forKey:kBackgroundSourceKey];
    } else {
        [defaults removeObjectForKey:kBackgroundSourceKey];
    }
    [defaults synchronize];
}

- (void)loadUISettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    // Task164：默认值判定从"范围检查"改为"键是否存在"（用户定稿：毛玻璃、
    // 透明度 60%、模糊 100%）。Task162 的范围检查有两个漏洞：
    //   ① kBackgroundUIEffectKey 从未保存时 integerForKey 返回 0 =
    //      BackgroundUIEffectTranslucent（枚举 0 = 半透明），范围检查
    //      [Translucent, Blur] 对 0 恒放行 → 新装设备默认"半透明"而非
    //      "毛玻璃"（用户实测"半透明 60%/0%"的第一半）；
    //   ② kBackgroundBlurIntensityKey 从未保存时 floatForKey 返回 0.0，
    //      "< 0.0" 检查抓不住 → 默认模糊 0%（第二半）。
    // 只有 _uiOpacity 的 "< 0.1" 检查碰巧把未保存的 0.0 归一到默认。
    // 现在三个键统一"objectForKey == nil = 从未保存 → 写默认；显式保存过
    // 的值（包括用户故意选的 半透明 / 0% 模糊）照常尊重"。
    NSNumber *ame164_effect = [defaults objectForKey:kBackgroundUIEffectKey];
    if (ame164_effect == nil) {
        _uiEffect = BackgroundUIEffectBlur; // Task162/164：默认毛玻璃效果
    } else {
        _uiEffect = [ame164_effect integerValue];
        if (_uiEffect < BackgroundUIEffectTranslucent || _uiEffect > BackgroundUIEffectBlur) {
            _uiEffect = BackgroundUIEffectBlur; // 越界值（历史损坏数据）兜底毛玻璃
        }
    }

    NSNumber *ame164_opacity = [defaults objectForKey:kBackgroundUIOpacityKey];
    if (ame164_opacity == nil) {
        _uiOpacity = 1.0; // Task162/164 默认 60%；Task216：默认透明度 100%（用户定稿默认全不透明）
    } else {
        _uiOpacity = [ame164_opacity doubleValue];
        if (_uiOpacity < 0.1 || _uiOpacity > 1.0) {
            _uiOpacity = 1.0;
        }
    }

    NSNumber *ame164_blur = [defaults objectForKey:kBackgroundBlurIntensityKey];
    if (ame164_blur == nil) {
        _blurIntensity = 0.75; // Task162/164 默认 100%；Task216：默认模糊程度 75%（用户定稿）
    } else {
        _blurIntensity = [ame164_blur doubleValue];
        if (_blurIntensity < 0.0 || _blurIntensity > 1.0) {
            _blurIntensity = 0.75;
        }
    }
}

- (void)saveUISettings {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setInteger:self.uiEffect forKey:kBackgroundUIEffectKey];
    [defaults setFloat:self.uiOpacity forKey:kBackgroundUIOpacityKey];
    [defaults setFloat:self.blurIntensity forKey:kBackgroundBlurIntensityKey];
    [defaults synchronize];
}

- (void)setUiEffect:(BackgroundUIEffect)uiEffect {
    _uiEffect = uiEffect;
    [self saveUISettings];
}

- (void)setUiOpacity:(CGFloat)uiOpacity {
    _uiOpacity = MAX(0.1, MIN(1.0, uiOpacity));
    [self saveUISettings];
}

- (void)setBlurIntensity:(CGFloat)blurIntensity {
    _blurIntensity = MAX(0.0, MIN(1.0, blurIntensity));
    [self saveUISettings];
}

#pragma mark - Task172 新拟态界面开关（Task210 全链退役）

// Task210：cardsNeumorphEnabled / cardsNeumorphOpacity 存取器随新拟态
// 选项删除整链退役（原 defaults 直读写实现见 announcements 历史）。

#pragma mark - Global Background Application

- (void)applyBackgroundToWindow:(UIWindow *)window {
    if (!window) {
        [self removeGlobalBackground];
        return;
    }
    
    self.currentWindow = window;
    self.currentSplitVC = nil;
    
    // Remove existing
    [self removeGlobalBackground];

    // Task174→Task175→Task177（画布接管退役 → 壁纸共存 → 规格定稿）：用户
    // 实测反馈"新拟态开启时壁纸被覆盖无法正常显示"——Task174 的画布级接管
    // （壁纸整层收起）矫枉过正。定稿语义：新拟态界面开启 = 卡片恒为 CSS
    // 参考规格（渐变表面 + 全不透明固定档双阴影，Task177）+ 壁纸照常铺设
    // 可见。无壁纸时维持原生系统底色（Task137 语义）。本方法不再有新拟态
    // 专属早退——壁纸容器的铺设与开关状态无关，卡面/阴影由卡片管线负责
    // （不再有壁纸柔和档/透明度耦合）。Bing 自动刷新照旧可见（不再被拦截）。

    // Task111：检测并切换（用户实测反馈：Task89 的强制纯色底把启动器背景照片
    // 功能全部顶掉了）。用户设置了自定义背景（图片/视频）时，恢复 Task89 之前的
    // 全局背景管线：容器插入窗口最底层（insertSubview:atIndex:0，即"调低层级"），
    // 图片/视频/模糊/压暗自下而上铺开，UI 悬浮其上；未设置背景时回归 iOS 原生
    // 系统底色（Task137：新拟态退役）。两种模式随 hasBackground 自动切换，
    // 设置/清除背景后本方法被重新调用（setImageBackground/clearBackground 既有链路）。
    if ([self hasBackground]) {
        // Task 129f：有自定义背景时也把窗口底色设为系统底色（动态适配深浅色）：
        // 一旦图片/视频装载失败（解码失败、视频初始化失败等），透出的底色是
        // 系统底色而非随机色。背景装载成功时该底色被容器完全覆盖，零视觉影响。
        window.backgroundColor = [UIColor systemBackgroundColor];
        UIView *container = [[UIView alloc] initWithFrame:window.bounds];
        container.tag = kGlobalBackgroundTag;
        container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        container.backgroundColor = [UIColor clearColor];

        // Insert at index 0 (behind everything)
        [window insertSubview:container atIndex:0];
        self.globalBackgroundContainer = container;

        // Apply content
        switch (self.currentType) {
            case BackgroundTypeImage:
                [self applyImageBackgroundToContainer:container];
                break;
            case BackgroundTypeVideo:
                [self applyVideoBackgroundToContainer:container];
                break;
            default:
                break;
        }
        return;
    }

    // Task137：新拟态退役——无自定义背景时回归 iOS 原生系统底色，
    // 深浅色由语义色自动适配。
    window.backgroundColor = [UIColor systemBackgroundColor];
}

- (void)applyBackgroundToSplitViewController:(UISplitViewController *)splitVC {
    if (!splitVC || !splitVC.view) {
        [self removeGlobalBackground];
        return;
    }

    self.currentSplitVC = splitVC;
    self.currentWindow = nil;

    // Remove existing
    [self removeGlobalBackground];

    // Task174→Task175：与 applyBackgroundToWindow 同款退役（画布接管门
    // 删除，壁纸照常铺设；语义见彼处注释）。

    // Task111：同 applyBackgroundToWindow 的检测并切换——有自定义背景时恢复
    // Task89 之前的容器管线（最底层插入 + 图片/视频 + 子 VC 透明化），
    // 无背景时回归 iOS 原生系统底色（Task137：新拟态退役）。
    if ([self hasBackground]) {
        // Task 129f：与 applyBackgroundToWindow 同款兜底——背景容器之下的
        // splitVC.view 底色设为系统底色（动态适配深浅色），图片/视频装载
        // 失败时透出的是系统底色而非随机色。
        splitVC.view.backgroundColor = [UIColor systemBackgroundColor];
        UIView *container = [[UIView alloc] initWithFrame:splitVC.view.bounds];
        container.tag = kGlobalBackgroundTag;
        container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        container.backgroundColor = [UIColor clearColor];

        // Insert at the very bottom
        [splitVC.view insertSubview:container atIndex:0];
        self.globalBackgroundContainer = container;

        // Apply content
        switch (self.currentType) {
            case BackgroundTypeImage:
                [self applyImageBackgroundToContainer:container];
                break;
            case BackgroundTypeVideo:
                [self applyVideoBackgroundToContainer:container];
                break;
            default:
                break;
        }

        // Make all child controllers transparent (only for custom backgrounds)
        [self makeSplitViewControllerTransparent:splitVC];
        return;
    }

    // Task137：新拟态退役——无自定义背景时回归 iOS 原生系统底色。
    splitVC.view.backgroundColor = [UIColor systemBackgroundColor];
}

- (void)removeGlobalBackground {
    // Remove from window
    if (self.currentWindow) {
        UIView *existing = [self.currentWindow viewWithTag:kGlobalBackgroundTag];
        if (existing) [existing removeFromSuperview];
    }
    
    // Remove from split VC
    if (self.currentSplitVC && self.currentSplitVC.view) {
        UIView *existing = [self.currentSplitVC.view viewWithTag:kGlobalBackgroundTag];
        if (existing) [existing removeFromSuperview];
    }
    
    // Cleanup
    [self cleanupVideoPlayer];
    self.globalBackgroundContainer = nil;
    // Task161（Bing 壁纸“要重启才能加载”根修）：不再清空 currentWindow /
    // currentSplitVC。旧代码在这里把两个宿主引用置 nil，而
    // applyBackgroundToWindow: 的顺序是【先设 currentWindow → 再调本方法
    // → 本方法把它置 nil】——启动后宿主引用恒为 nil，后续
    // setBingBackgroundImageAtPath 的应用分支（currentSplitVC / currentWindow
    // 双 nil）什么都不做：Bing 图下载完成只落盘了状态，活 UI 从不插入
    // 背景容器，直到重启时启动路径才真正应用 = “要重启才能静默加载”。
    // 修复后语义：宿主注册归 applyBackgroundToWindow / ToSplitViewController
    // 所有（互斥另一侧置 nil 的逻辑保留在那两侧）；两个属性均为 weak，
    // 宿主销毁时自动置 nil，无悬挂风险。
}

- (void)updateBackgroundFrame {
    if (!self.globalBackgroundContainer) return;
    
    UIView *parent = self.globalBackgroundContainer.superview;
    if (!parent) return;
    
    // Update container frame
    self.globalBackgroundContainer.frame = parent.bounds;
    
    // Update default background view
    UIView *defaultBg = [self.globalBackgroundContainer viewWithTag:kDefaultBackgroundTag];
    if (defaultBg) defaultBg.frame = self.globalBackgroundContainer.bounds;
    
    // Update image view
    UIView *imageView = [self.globalBackgroundContainer viewWithTag:kBackgroundImageTag];
    if (imageView) imageView.frame = self.globalBackgroundContainer.bounds;
    
    // Update blur view
    UIView *blurView = [self.globalBackgroundContainer viewWithTag:kBackgroundBlurTag];
    if (blurView) blurView.frame = self.globalBackgroundContainer.bounds;
    
    // Update dim view
    UIView *dimView = [self.globalBackgroundContainer viewWithTag:kBackgroundDimTag];
    if (dimView) dimView.frame = self.globalBackgroundContainer.bounds;
    
    // Update video layer
    if (self.videoPlayerLayer) self.videoPlayerLayer.frame = self.globalBackgroundContainer.bounds;
}

- (void)handleOrientationChange {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBackgroundFrame];
    });
}

#pragma mark - Background Content Application

- (void)applyDefaultBackgroundToContainer:(UIView *)container {
    // Remove existing default background
    UIView *existing = [container viewWithTag:kDefaultBackgroundTag];
    if (existing) [existing removeFromSuperview];
    
    // Create default background view that adapts to system appearance
    UIView *defaultBackgroundView = [[UIView alloc] initWithFrame:container.bounds];
    defaultBackgroundView.tag = kDefaultBackgroundTag;
    defaultBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    
    // Use system background color that adapts to light/dark mode
    // In dark mode: black, In light mode: system background color
    if (@available(iOS 13.0, *)) {
        defaultBackgroundView.backgroundColor = [UIColor systemBackgroundColor];
    } else {
        // Fallback for iOS < 13
        defaultBackgroundView.backgroundColor = [UIColor blackColor];
    }
    
    [container addSubview:defaultBackgroundView];
}

- (void)applyImageBackgroundToContainer:(UIView *)container {
    if (!self.currentBackgroundPath) return;
    
    UIImage *image = [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    if (!image) {
        // Task 129f：图片解码失败（内存压力/格式异常/文件半损）旧实现静默 return，
        // 容器空置 -> 透出 window 底色 systemBackgroundColor（浅色模式=纯白）——
        // “一些设备（如 iPad9）背景是白色而不是设置里的背景”的根因。
        // 修复：容器底铺系统底色兜底（动态适配深浅色），随机底色永不透出；
        // 日志锚点供下一轮装机取证。
        NSLog(@"[BackgroundManager] Task129f: background image failed to decode (%@) - falling back to system base", self.currentBackgroundPath.lastPathComponent);
        UIView *fallback = [[UIView alloc] initWithFrame:container.bounds];
        fallback.tag = kDefaultBackgroundTag;
        fallback.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        fallback.backgroundColor = [UIColor systemBackgroundColor];
        [container addSubview:fallback];
        return;
    }
    
    // Remove existing
    UIView *existing = [container viewWithTag:kBackgroundImageTag];
    if (existing) [existing removeFromSuperview];
    
    // Remove existing fallback (Task129f：解码成功时清除兜底层，避免叠压)
    UIView *existingFallback = [container viewWithTag:kDefaultBackgroundTag];
    if (existingFallback) [existingFallback removeFromSuperview];
    
    // Image view
    UIImageView *imageView = [[UIImageView alloc] initWithImage:image];
    imageView.tag = kBackgroundImageTag;
    imageView.contentMode = UIViewContentModeScaleAspectFill;
    imageView.clipsToBounds = YES;
    imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    imageView.frame = container.bounds;
    
    [container addSubview:imageView];
    
    // Add blur effect for UI readability
    [self addBlurEffectToContainer:container];
}

- (void)applyVideoBackgroundToContainer:(UIView *)container {
    if (!self.currentBackgroundPath) return;
    
    NSURL *videoURL = [NSURL fileURLWithPath:self.currentBackgroundPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.currentBackgroundPath]) return;
    
    [self cleanupVideoPlayer];
    
    // Create player
    self.videoPlayer = [AVPlayer playerWithURL:videoURL];
    self.videoPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    self.videoPlayer.muted = YES; // Mute to avoid interrupting other audio
    
    // Create player layer
    self.videoPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:self.videoPlayer];
    self.videoPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    self.videoPlayerLayer.frame = container.bounds;
    
    // Insert at bottom
    [container.layer insertSublayer:self.videoPlayerLayer atIndex:0];
    
    // Add blur effect
    [self addBlurEffectToContainer:container];
    
    // Start playing
    [self.videoPlayer play];
}

- (void)addBlurEffectToContainer:(UIView *)container {
    // Remove existing blur
    UIView *existingBlur = [container viewWithTag:kBackgroundBlurTag];
    if (existingBlur) [existingBlur removeFromSuperview];

    UIView *existingDim = [container viewWithTag:kBackgroundDimTag];
    if (existingDim) [existingDim removeFromSuperview];

    // 修复：使用 SystemThinMaterial（自适应浅色/深色，且较通透）替代硬编码 Dark。
    // 之前使用 UIBlurEffectStyleDark + 黑色 dim view 叠加，导致：
    // 1. 浅色模式下背景图被完全压暗成"中间一片黑"
    // 2. 左右侧栏完全不透明，背景图透不出来
    // SystemThinMaterial 会在浅色模式呈浅色毛玻璃、深色模式呈深色毛玻璃，
    // 且透明度适中，背景图可见。
    UIBlurEffect *blurEffect;
    if (@available(iOS 13.0, *)) {
        blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    } else {
        blurEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
    }
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blurEffect];
    blurView.tag = kBackgroundBlurTag;
    blurView.alpha = self.blurIntensity * 0.5; // max 0.5 for readability
    blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    blurView.frame = container.bounds;
    // Task161：纯装饰层显式关闭触摸——容器层在任何层级形态下都不得拦截
    // 命中测试（保险带：装机实测“壁砰设置页被盖住、滑块拖不动”的嫌疑层
    // 之一，与 Task160 模态毛玻璃底同轮排查）。
    blurView.userInteractionEnabled = NO;

    [container addSubview:blurView];

    // 修复：dim view 改为自适应颜色而非纯黑，避免浅色模式下过度压暗
    UIView *dimView = [[UIView alloc] initWithFrame:container.bounds];
    dimView.tag = kBackgroundDimTag;
    if (@available(iOS 13.0, *)) {
        dimView.backgroundColor = [UIColor labelColor];
    } else {
        dimView.backgroundColor = [UIColor blackColor];
    }
    dimView.alpha = self.blurIntensity * 0.2; // 降低到 0.2，避免过度压暗
    dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Task161：同上——装饰层不参与命中测试。
    dimView.userInteractionEnabled = NO;

    [container addSubview:dimView];
}

#pragma mark - Transparency Helpers with UI Effect Support

// Task152：背景"从无到有"时对整棵 VC 树重放透明化。首次启动时 Bing 壁纸尚未
// 下载完成，全部已加载 VC 在"无背景"时期经 makeViewControllerTransparent 的
// hasBackground 守卫直接 return（保持不透明 systemBackgroundColor）；数秒后
// setBingBackgroundImageAtPath 插入背景容器时没有任何机制通知这些既有 VC，
// 背景被完全盖住，用户实测表现为"Bing 壁纸加载完成需重启软件才正常"。
// 递归覆盖 childViewControllers（nav/split/tab 子栈均注册为 child）、
// presentedViewController；nav 栏/工具栏效果单独补刷。幂等，可安全重复调用。
- (void)refreshTransparencyForWindowUI {
    UIViewController *root = nil;
    if (self.currentSplitVC && self.currentSplitVC.view.window) {
        root = self.currentSplitVC;
    } else if (self.currentWindow && self.currentWindow.rootViewController) {
        root = self.currentWindow.rootViewController;
    }
    if (!root) {
        NSLog(@"[BackgroundManager] Task152: refreshTransparency skipped (no live root)");
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self ame_applyTransparencyRecursive:root];
        NSLog(@"[BackgroundManager] Task152: transparency refreshed for live VC tree");
    });
}

- (void)ame_applyTransparencyRecursive:(UIViewController *)vc {
    if (!vc) return;
    [self makeViewControllerTransparent:vc];

    if ([vc isKindOfClass:[UISplitViewController class]]) {
        for (UIViewController *child in [(UISplitViewController *)vc viewControllers]) {
            [self ame_applyTransparencyRecursive:child];
        }
    } else if ([vc isKindOfClass:[UINavigationController class]]) {
        UINavigationController *nav = (UINavigationController *)vc;
        for (UIViewController *child in nav.viewControllers) {
            [self ame_applyTransparencyRecursive:child];
        }
        nav.view.backgroundColor = [UIColor clearColor];
        [self applyEffectToNavigationBar:nav.navigationBar];
        [self applyEffectToToolbar:nav.toolbar];
    } else if ([vc isKindOfClass:[UITabBarController class]]) {
        for (UIViewController *child in [(UITabBarController *)vc viewControllers]) {
            [self ame_applyTransparencyRecursive:child];
        }
    }

    for (UIViewController *child in [vc childViewControllers]) {
        if (child != vc.presentedViewController) {
            [self ame_applyTransparencyRecursive:child];
        }
    }
    if (vc.presentedViewController) {
        [self ame_applyTransparencyRecursive:vc.presentedViewController];
    }
}

- (void)makeViewControllerTransparent:(UIViewController *)viewController {
    if (!viewController) return;

    // Task111：无自定义背景时什么都不做——新拟态纯色底下没有需要"透出"的
    // 背景图，保持各 VC 自己的背景与系统 cell 样式即可。此前无条件透明化会在
    // 纯色底上叠出白色蒙膜（Translucent 模式）并把表格 cell 洗成近透明的
    // secondarySystemBackgroundColor，用户实测表现为"有些菜单的背景消失了，
    // 只剩下按钮和阴影"。有自定义背景时才执行原有透明化管线。
    if (![self hasBackground]) {
        return;
    }

    // Main view - apply effect based on settings
    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - clear background, let blur show through
        viewController.view.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果 - 主视图保持透明，壁纸直接透出。
        // ★ Task226（反馈 #10：恢复半透明效果直接黑色壁纸）：旧实现给每个
        // VC 主视图铺 systemBackgroundColor×uiOpacity 半透明层——深色模式下
        // systemBackgroundColor = 纯黑，多层 VC 叠加（nav + 内容 + 卡片）的
        // 复合透明度接近不透明 → 用户看到“黑色壁纸”（毛玻璃模式本层恒
        // clearColor 从无此现象，Task216 的 (1-o)×o 语义修复也没有解决
        // “多层叠加压黑”这一层）。修法：本层与毛玻璃同款 clearColor，
        // 可读性由卡面管线（applyEffectToView/applyEffectToCell 的
        // secondarySystemBackground×uiOpacity）承担——卡片半透明、页底
        // 透壁纸，两种模式的页面底行为从此一致。
        viewController.view.backgroundColor = [UIColor clearColor];
    }

    // For UITableViewController
    if ([viewController isKindOfClass:[UITableViewController class]]) {
        UITableViewController *tableVC = (UITableViewController *)viewController;
        tableVC.tableView.backgroundColor = [UIColor clearColor];
        tableVC.tableView.backgroundView = nil;

        // Make cells semi-transparent or with blur effect
        tableVC.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;

        // Apply to all visible cells
        for (UITableViewCell *cell in tableVC.tableView.visibleCells) {
            [self applyEffectToCell:cell];
        }
    }

    // For UICollectionViewController
    if ([viewController isKindOfClass:[UICollectionViewController class]]) {
        UICollectionViewController *collectionVC = (UICollectionViewController *)viewController;
        collectionVC.collectionView.backgroundColor = [UIColor clearColor];
    }

    // Child view controllers
    for (UIViewController *childVC in viewController.childViewControllers) {
        [self makeViewControllerTransparent:childVC];
    }

    // Task161：模态弹窗页面级毛玻璃底收口到方法末尾——必须在上方
    // UITableViewController 分支（backgroundView = nil）之后执行，否则
    // table 控制器的 glass 会被立即清掉。仅毛玻璃模式（Task160 语义）。
    if (self.uiEffect == BackgroundUIEffectBlur) {
        // Task160：模态弹窗"把背景加回来"（用户指令：自定义背景/自定义主页等
        // 大量小窗口此前整页透明直接透壁纸，文字直接压在壁纸上）。壁纸模式下
        // 给弹窗页铺一层页面级 SystemThinMaterial 毛玻璃底（文字可读、隐约透
        // 壁纸）；侧栏/右面板/root 中央内容区（非模态）不铺、保持透壁纸。
        // 无壁纸时上方已 return，弹窗保持各页自持的系统底色。
        [self ame160_applyGlassBackdropIfModal:viewController];
    }
}

/// Task160：模态弹窗页面级毛玻璃底（"把背景加回来"）。
/// 判定：present 出来的 VC（presentingViewController 非空）或弹窗 nav 内
/// push 的子页（navigationController.presentingViewController 非空）。侧栏/
/// 右面板/root 中央内容区（setContentViewController 嵌入）两链都为空，
/// 自然跳过。SystemThinMaterial：比 cell 级 SystemMaterial 更通透，避免
/// 页面底+cell 毛玻璃双层叠加后过浓；深浅色自动适配。
- (void)ame160_applyGlassBackdropIfModal:(UIViewController *)viewController {
    if (!viewController || !viewController.viewIfLoaded) return;
    BOOL isModal = (viewController.presentingViewController != nil) ||
                   (viewController.navigationController.presentingViewController != nil);
    if (!isModal) return;

    if (@available(iOS 13.0, *)) {
        // Task161：UITableViewController 的 view 即 UITableView 本体时
        // （未在 viewDidLoad 里重赋 tableView 的形态——BackgroundSettings
        // ViewController 正是如此），绝不 insertSubview——外来视图插进
        // UITableView 不在受支持用法内：子视图顺序由表自管（iOS 27 实测
        // 布局与命中测试不可预期，装机表现为"整页像盖了东西、文字按钮
        // 看不到、滑块拖不动"）。改挂 tableView.backgroundView——UIKit
        // 管理的背景位，天然位于全部 cells 之下且不参与命中测试。
        if ([viewController isKindOfClass:[UITableViewController class]] &&
            viewController.view == ((UITableViewController *)viewController).tableView) {
            UITableView *ame161_table = ((UITableViewController *)viewController).tableView;
            UIView *ame161_existing = ame161_table.backgroundView;
            if (ame161_existing.tag != kAme160GlassBackdropTag) {
                UIVisualEffectView *ame161_glass;
                if (LGCIsGlassStyleActive()) {
                    // Task224（#4）：玻璃风格用 UIGlassEffect（26+；低版
                    // 本回退系统材质——解析层已保证玻璃风格仅在 26+ 生效）
                    ame161_glass = LGCCreateGlassEffectView(NO);
                } else {
                    UIBlurEffect *ame161_effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
                    ame161_glass = [[UIVisualEffectView alloc] initWithEffect:ame161_effect];
                }
                ame161_glass.tag = kAme160GlassBackdropTag;
                ame161_glass.frame = ame161_table.bounds;
                ame161_glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                ame161_glass.userInteractionEnabled = NO;
                ame161_table.backgroundView = ame161_glass;
            }
            return;
        }

        // 防重复：先移除旧底层再重铺（重复调用/布局变更场景）
        for (UIView *sub in [NSArray arrayWithArray:viewController.view.subviews]) {
            if (sub.tag == kAme160GlassBackdropTag) [sub removeFromSuperview];
        }

        UIVisualEffectView *glass;
        if (LGCIsGlassStyleActive()) {
            // Task224（#4）：同上——玻璃风格的模态页底层用玻璃效果视图
            glass = LGCCreateGlassEffectView(NO);
        } else {
            UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
            glass = [[UIVisualEffectView alloc] initWithEffect:effect];
        }
        glass.tag = kAme160GlassBackdropTag;
        glass.frame = viewController.view.bounds;
        glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        glass.userInteractionEnabled = NO;
        [viewController.view insertSubview:glass atIndex:0];
    }
}

- (void)applyEffectToCell:(UITableViewCell *)cell {
    // Task111：检测并切换——有自定义背景时保持 Task89 之前的毛玻璃/半透明
    // cell 效果（背景图从 cell 下方透出）；无自定义背景时回归 iOS 原生列表
    // 外观（Task137：新拟态退役）——cell 保持系统默认透明底，页面底色由各页
    // 自持 systemBackgroundColor，深浅色由语义色自动适配，标准分隔线可见。
    if (![self hasBackground]) {
        cell.backgroundView = nil;
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
        return;
    }

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - use UIBlurEffect on cell background
        if (@available(iOS 13.0, *)) {
            UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.frame = cell.bounds;
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

            // Remove old background views
            for (UIView *subview in cell.contentView.superview.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview != blurView) {
                    [subview removeFromSuperview];
                }
            }

            // Task152：卡片化 cell（contentView 自带圆角，如下载页模组加载器列表）
            // 不能用直角 backgroundView 铺 blur——卡片圆角四角外会露出深色直角
            // （用户实测"圆角有黑直边"）。改为插入 contentView 底层并继承圆角；
            // 普通矩形行维持 backgroundView 原路径。
            CGFloat contentRadius = cell.contentView.layer.cornerRadius;
            if (contentRadius > 0) {
                blurView.frame = cell.contentView.bounds;
                blurView.layer.cornerRadius = contentRadius;
                blurView.layer.cornerCurve = cell.contentView.layer.cornerCurve;
                blurView.layer.masksToBounds = YES;
                blurView.userInteractionEnabled = NO;
                [cell.contentView insertSubview:blurView atIndex:0];
                cell.backgroundView = nil;
            } else {
                cell.backgroundView = blurView;
            }
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        cell.contentView.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果 - simple semi-transparent background
        // 修复：使用 secondarySystemBackgroundColor 替代硬编码 0.1 黑色
        if (@available(iOS 13.0, *)) {
            // Task152：卡片化 cell（圆角 > 0）把半透明底作用到 contentView，
            // 避免直角 cell 底色在卡片圆角外露直角。
            CGFloat contentRadius = cell.contentView.layer.cornerRadius;
            if (contentRadius > 0) {
                cell.backgroundColor = [UIColor clearColor];
                cell.contentView.backgroundColor = [[UIColor secondarySystemBackgroundColor]
                    colorWithAlphaComponent:self.uiOpacity];
                cell.contentView.layer.masksToBounds = YES;
                cell.backgroundView = nil;
            } else {
                cell.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
                cell.contentView.backgroundColor = [UIColor clearColor];
                cell.backgroundView = nil;
            }
        } else {
            cell.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            cell.contentView.backgroundColor = [UIColor clearColor];
            cell.backgroundView = nil;
        }
    }
}

- (void)makeSplitViewControllerTransparent:(UISplitViewController *)splitVC {
    if (!splitVC) return;
    
    // Make split view itself transparent
    splitVC.view.backgroundColor = [UIColor clearColor];
    
    // Make all view controllers transparent
    for (UIViewController *vc in splitVC.viewControllers) {
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)vc;
            
            // Navigation controller setup
            nav.view.backgroundColor = [UIColor clearColor];
            nav.navigationBar.translucent = YES;
            nav.toolbar.translucent = YES;
            
            // Apply effect to navigation bar
            [self applyEffectToNavigationBar:nav.navigationBar];
            [self applyEffectToToolbar:nav.toolbar];
            
            // Make all view controllers in stack transparent
            for (UIViewController *childVC in nav.viewControllers) {
                [self makeViewControllerTransparent:childVC];
            }
        } else {
            [self makeViewControllerTransparent:vc];
        }
    }
}

- (void)applyEffectToNavigationBar:(UINavigationBar *)navigationBar {
    // ★ Task228：液态玻璃风格的"导航栏交还系统"退役。用户指令是软件 UI
    // （含导航栏/标签页切换器）保持原样、玻璃只用于悬浮弹窗；且栏位交还
    // 系统后由 iOS 26+ 自行绘制的液态玻璃与 UIGlassEffect 同一渲染路径，
    // 在本进程的可靠性已被 Task225/Task228 两次装机实锤否定（黑面）。
    // 两种风格一律走本仓既有毛玻璃/半透明栏管线；LGCAdaptNavigationBar
    // 保留为工具函数（无生产调用方）。

    // 关键修复（UI 累积异常 + 小白条根治）：
    // 1. 之前每次调用都重建 UINavigationBarAppearance，iOS 内部会重新生成 hairline
    //    UIImageView，累积后表现为"上方一行小白条"。现改为静态单例 Appearance，
    //    同一种效果只构建一次，避免反复触发 iOS 内部 hairline view 重建。
    // 2. 之前清理 hairline 只遍历 navigationBar.subviews（直接子视图），但 iOS 的
    //    hairline 常嵌在 _UINavigationBarBackground / _UIBarBackground 等私有子视图
    //    内部。改为递归遍历所有后代视图，彻底清理累积的 hairline。
    static UIImage *emptyImage = nil;
    static UINavigationBarAppearance *blurAppearance = nil;
    static UINavigationBarAppearance *translucentAppearance = nil;
    static UIColor *translucentBarColor = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        emptyImage = [UIImage new];
        // 预构建毛玻璃 Appearance（configureWithTransparentBackground + shadowImage 置空）
        blurAppearance = [[UINavigationBarAppearance alloc] init];
        [blurAppearance configureWithTransparentBackground];
        blurAppearance.backgroundColor = [UIColor clearColor];
        blurAppearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        blurAppearance.shadowColor = nil;
        blurAppearance.shadowImage = emptyImage;
        // 半透明 Appearance 在首次调用时按当前 uiOpacity 构建（见下方懒加载）
    });

    // 递归清理 iOS 内部累积的 hairline UIImageView（高度极小的分割线视图）
    // hairline 常嵌在 _UINavigationBarBackground / _UIBarBackground 等私有子视图内部
    //
    // 关键修复（Card/Root 布局进入所有页闪退加固）：
    //   block 内引用自身（removeHairlines(sub)）必须用 __block 限定符，否则
    //   捕获的是 nil（block 字面量赋值还未完成时的栈帧值），递归调用是 no-op，
    //   只会处理 navigationBar 的直接子视图，无法清理 _UIBarBackground 内层的 hairline。
    //   累积的 hairline 在 setContentViewController 反复切换时会触发私有子视图
    //   layout 解算异常，导致 EXC_BAD_ACCESS（不被 NSUncaughtExceptionHandler 捕获）。
    __block void (^removeHairlines)(UIView *) = ^(UIView *view) {
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.bounds.size.height > 0 &&
                sub.bounds.size.height <= 2.0) {
                [sub removeFromSuperview];
            } else {
                removeHairlines(sub);
            }
        }
    };
    removeHairlines(navigationBar);

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - 复用静态单例
        if (@available(iOS 13.0, *)) {
            navigationBar.standardAppearance = blurAppearance;
            navigationBar.scrollEdgeAppearance = blurAppearance;
            navigationBar.compactAppearance = blurAppearance;
        }
        navigationBar.barTintColor = [UIColor clearColor];
        navigationBar.backgroundColor = [UIColor clearColor];
        navigationBar.shadowImage = emptyImage;
    } else {
        // 半透明效果
        if (@available(iOS 13.0, *)) {
            UIColor *barColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
            navigationBar.barTintColor = barColor;
            navigationBar.backgroundColor = barColor;
            // 半透明 Appearance 需要按当前 uiOpacity 构建（uiOpacity 可变，无法像 blur 一样全局单例）
            // 但同一 uiOpacity 下复用同一实例，避免反复重建
            if (!translucentAppearance || ![translucentBarColor isEqual:barColor]) {
                UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundColor = barColor;
                appearance.backgroundEffect = nil;
                appearance.shadowColor = nil;
                appearance.shadowImage = emptyImage;
                translucentAppearance = appearance;
                translucentBarColor = barColor;
            }
            navigationBar.standardAppearance = translucentAppearance;
            navigationBar.scrollEdgeAppearance = translucentAppearance;
            navigationBar.compactAppearance = translucentAppearance;
        } else {
            navigationBar.barTintColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            navigationBar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
        navigationBar.shadowImage = emptyImage;
    }
}

- (void)applyEffectToToolbar:(UIToolbar *)toolbar {
    // 关键修复（同 applyEffectToNavigationBar:）：静态单例 Appearance + 递归清理 hairline
    static UIImage *emptyImage = nil;
    static UIToolbarAppearance *blurToolbarAppearance = nil;
    static UIToolbarAppearance *translucentToolbarAppearance = nil;
    static UIColor *translucentToolbarColor = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        emptyImage = [UIImage new];
        blurToolbarAppearance = [[UIToolbarAppearance alloc] init];
        [blurToolbarAppearance configureWithTransparentBackground];
        blurToolbarAppearance.backgroundColor = [UIColor clearColor];
        blurToolbarAppearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
        blurToolbarAppearance.shadowColor = nil;
        blurToolbarAppearance.shadowImage = emptyImage;
    });

    // 递归清理累积的 hairline UIImageView
    // 关键修复：同 applyEffectToNavigationBar:，block 内引用自身必须用 __block
    // 限定符，否则递归调用是 no-op，无法清理 _UIBarBackground 内层的 hairline。
    __block void (^removeHairlines)(UIView *) = ^(UIView *view) {
        for (UIView *sub in view.subviews) {
            if ([sub isKindOfClass:[UIImageView class]] &&
                sub.bounds.size.height > 0 &&
                sub.bounds.size.height <= 2.0) {
                [sub removeFromSuperview];
            } else {
                removeHairlines(sub);
            }
        }
    };
    removeHairlines(toolbar);

    if (self.uiEffect == BackgroundUIEffectBlur) {
        // 毛玻璃效果 - 复用静态单例
        if (@available(iOS 13.0, *)) {
            toolbar.standardAppearance = blurToolbarAppearance;
            toolbar.scrollEdgeAppearance = blurToolbarAppearance;
            toolbar.compactAppearance = blurToolbarAppearance;
        }
        toolbar.barTintColor = [UIColor clearColor];
        toolbar.backgroundColor = [UIColor clearColor];
    } else {
        // 半透明效果
        if (@available(iOS 13.0, *)) {
            UIColor *barColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:self.uiOpacity];
            toolbar.barTintColor = barColor;
            toolbar.backgroundColor = barColor;
            if (!translucentToolbarAppearance || ![translucentToolbarColor isEqual:barColor]) {
                UIToolbarAppearance *appearance = [[UIToolbarAppearance alloc] init];
                [appearance configureWithTransparentBackground];
                appearance.backgroundColor = barColor;
                appearance.backgroundEffect = nil;
                appearance.shadowColor = nil;
                appearance.shadowImage = emptyImage;
                translucentToolbarAppearance = appearance;
                translucentToolbarColor = barColor;
            }
            toolbar.standardAppearance = translucentToolbarAppearance;
            toolbar.scrollEdgeAppearance = translucentToolbarAppearance;
            toolbar.compactAppearance = translucentToolbarAppearance;
        } else {
            toolbar.barTintColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            toolbar.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
        }
    }
}

- (void)refreshUIEffect {
    // Task210：新拟态开关分支删除——恒为单路径（原 Task174 关闭分支语义）：
    // 壁纸容器缺席时原位重建，有壁纸时透明化 splitVC 并重挂 blur。
    if ([self hasBackground] && !self.globalBackgroundContainer) {
        if (self.currentSplitVC) {
            [self applyBackgroundToSplitViewController:self.currentSplitVC];
        } else if (self.currentWindow) {
            [self applyBackgroundToWindow:self.currentWindow];
        }
    }
    if (self.currentSplitVC && self.currentType != BackgroundTypeNone) {
        [self makeSplitViewControllerTransparent:self.currentSplitVC];
    }
    if (self.globalBackgroundContainer) {
        [self addBlurEffectToContainer:self.globalBackgroundContainer];
    }

    // Post notification for other views to refresh
    [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
    // Task223：壁纸变化 → 亮度自适应颜色可能翻转（动态反色）。
    [[NSNotificationCenter defaultCenter] postNotificationName:Ame223WallpaperChangedNotification object:nil];
}

#pragma mark - Task223：壁纸直取 + 亮度自适应（清单第 14/21 项）

NSNotificationName const Ame223WallpaperChangedNotification = @"Ame223WallpaperChanged";

- (nullable UIImage *)ame223_currentWallpaperImage {
    if (![self hasImageBackground]) return nil;
    NSString *path = self.currentBackgroundPath;
    if (path.length == 0) return nil;
    // 降采样解码（壁纸原图可达 4K；界面层只需要屏幕尺寸级别的位图，
    // 降采样同时省内存并让亮度计算更快）。kCGImageSource* 字面量键直用。
    CGFloat maxDim = MAX(UIScreen.mainScreen.bounds.size.width,
                         UIScreen.mainScreen.bounds.size.height) * UIScreen.mainScreen.scale;
    CGImageSourceRef src = CGImageSourceCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (src == NULL) {
        return [UIImage imageWithContentsOfFile:path];
    }
    NSDictionary *downOpts = @{
        (NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @(YES),
        (NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxDim),
        (NSString *)kCGImageSourceShouldCacheImmediately: @(YES),
    };
    CGImageRef img = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)downOpts);
    CFRelease(src);
    if (img == NULL) return [UIImage imageWithContentsOfFile:path];
    UIImage *result = [UIImage imageWithCGImage:img];
    CGImageRelease(img);
    return result;
}

- (BOOL)ame223_wallpaperLuminanceIsDark {
    static BOOL s_ame223_cachedDark = NO;
    static NSString *s_ame223_cachedPath = nil;
    // 无壁纸：按系统外观（浅色外观 = 亮 → 深字）。
    NSString *path = [self hasImageBackground] ? self.currentBackgroundPath : nil;
    if (path == nil || path.length == 0) {
        return UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    // 命中缓存（路径级；壁纸变化时路径变，缓存自动失效）。
    if (s_ame223_cachedPath != nil && [s_ame223_cachedPath isEqualToString:path]) {
        return s_ame223_cachedDark;
    }
    // 降采样到 24x24 灰度均值（足够稳的亮度判定，亚毫秒开销）。
    UIImage *wall = [self ame223_currentWallpaperImage];
    if (wall == nil) {
        return UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    CGSize size = CGSizeMake(24, 24);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:fmt];
    UIImage *thumb = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [wall drawInRect:CGRectMake(0, 0, size.width, size.height)];
    }];
    CGImageRef cg = thumb.CGImage;
    if (cg == NULL) {
        return UIScreen.mainScreen.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark;
    }
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    CFDataRef data = CGDataProviderCopyData(CGImageGetDataProvider(cg));
    BOOL dark = YES;
    if (data != NULL) {
        const UInt8 *px = CFDataGetBytePtr(data);
        size_t len = CFDataGetLength(data);
        if (px != NULL && len >= w * h * 4) {
            double sum = 0;
            for (size_t i = 0; i < (size_t)(w * h); i++) {
                const UInt8 *p = px + i * 4;
                // BT.601 luma（alpha 忽略——壁纸不透明）。
                sum += (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) / 255.0;
            }
            double avg = sum / (double)(w * h);
            dark = (avg < 0.45);
        }
        CFRelease(data);
    }
    s_ame223_cachedPath = [path copy];
    s_ame223_cachedDark = dark;
    return dark;
}

- (UIColor *)ame223_adaptiveTextColor {
    // ★ Task226（反馈 #16：取消动态反色——用户实测“没效果”）：反色判定
    // 退役，壁纸在场时恒定白色（可读性由 ame224_applyAdaptiveTextToLabel
    // 的白底黑边全局字体承担），无壁纸回语义色。
    if ([[BackgroundManager sharedManager] hasBackground]) {
        return [UIColor whiteColor];
    }
    if (@available(iOS 13.0, *)) {
        return [UIColor labelColor];
    }
    return [UIColor darkTextColor];
}

- (UIColor *)ame223_adaptiveSecondaryTextColor {
    if ([[BackgroundManager sharedManager] hasBackground]) {
        return [UIColor colorWithWhite:1.0 alpha:0.82];
    }
    if (@available(iOS 13.0, *)) {
        return [UIColor secondaryLabelColor];
    }
    return [UIColor lightGrayColor];
}

#pragma mark - Task224（#18）：通用动态反色文字（壁纸透出的界面文字）

// 欢迎页之外的动态反色机制：主菜单磁贴文字、右面板标题等直接/半透明地
// 压在壁纸上的文字，统一经本组类方法取色。无壁纸时回落 Task210 卡面规格
// 色（与今日外观逐字节一致，零回归）；有壁纸时按亮度反色 + 软阴影兜底。
// 壁纸变化重算：Ame223WallpaperChangedNotification（复用欢迎页链路）。

+ (UIColor *)ame224_adaptiveTextColor {
    BackgroundManager *ame224_mgr = [BackgroundManager sharedManager];
    if (![ame224_mgr hasBackground]) {
        return AmeCardPrimaryTextColor();
    }
    return [ame224_mgr ame223_adaptiveTextColor];
}

+ (UIColor *)ame224_adaptiveSecondaryTextColor {
    BackgroundManager *ame224_mgr = [BackgroundManager sharedManager];
    if (![ame224_mgr hasBackground]) {
        return AmeCardSecondaryTextColor();
    }
    return [ame224_mgr ame223_adaptiveSecondaryTextColor];
}

+ (void)ame224_applyAdaptiveTextToLabel:(UILabel *)label secondary:(BOOL)secondary {
    if (!label) return;
    // ★ Task226（反馈 #12/#16：壁纸可读性终案——白底黑边全局字体）：
    // 动态反色（按壁纸亮度翻转文字颜色）实测无效果且用户明确弃用；
    // 改为常开的白底黑边描边字体：白色填充 + 黑色描边（负 strokeWidth
    // = 描边 + 填充）+ 软阴影。任何壁纸上文字都可读，无需判定亮度。
    if ([[BackgroundManager sharedManager] hasBackground]) {
        label.textColor = [UIColor whiteColor];
        // ★ Task232（反馈 #16）：同 setText: 交换的改道——CoreText stroke
        //   与大光晕都向字形内部渗黑（CJK 字腔黑线的构造性来源），
        //   本入口也改为：染白 + 打标记，描边交给 drawTextInRect: 的
        //   四方向外扩拷贝（字腔保持纯白）。
        objc_setAssociatedObject(label, &ame232_OutlineMarkKey,
                                 @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // ★ Task232（反馈 #16）：光晕整体退役——零偏移模糊阴影一样向
        //   字腔（孔洞）里渗黑（“内部黑线”第二来源）；描边职责全部
        //   交给四方向外扩拷贝。
        label.layer.shadowOpacity = 0.0;
        label.layer.shadowRadius = 0.0;
        label.layer.shadowOffset = CGSizeZero;
    } else {
        // 无壁纸：语义色 + 清阴影（原生外观零回归）
        label.textColor = secondary ? [BackgroundManager ame224_adaptiveSecondaryTextColor]
                                    : [BackgroundManager ame224_adaptiveTextColor];
        label.layer.shadowColor = nil;
        label.layer.shadowOpacity = 0.0;
        label.layer.shadowRadius = 0.0;
        label.layer.shadowOffset = CGSizeZero;
    }
}

+ (NSAttributedString *)ame224_adaptiveAttributedTitle:(NSString *)title
                                              fontSize:(CGFloat)fontSize
                                             secondary:(BOOL)secondary {
    NSDictionary *ame224_attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:fontSize
                                           weight:secondary ? UIFontWeightMedium : UIFontWeightSemibold],
        NSForegroundColorAttributeName: secondary
            ? [BackgroundManager ame224_adaptiveSecondaryTextColor]
            : [BackgroundManager ame224_adaptiveTextColor],
    };
    NSMutableAttributedString *ame224_str =
        [[NSMutableAttributedString alloc] initWithString:(title ?: @"") attributes:ame224_attrs];
    if (ame224_str.length > 0 && [[BackgroundManager sharedManager] hasBackground]) {
        NSShadow *ame224_shadow = [[NSShadow alloc] init];
        ame224_shadow.shadowColor = [[BackgroundManager sharedManager] ame223_wallpaperLuminanceIsDark]
            ? [UIColor colorWithWhite:0.0 alpha:0.45]
            : [UIColor colorWithWhite:1.0 alpha:0.55];
        ame224_shadow.shadowBlurRadius = 1.5;
        ame224_shadow.shadowOffset = CGSizeMake(0, 1);
        [ame224_str addAttribute:NSShadowAttributeName value:ame224_shadow
                            range:NSMakeRange(0, ame224_str.length)];
    }
    return ame224_str;
}

#pragma mark - Unified View Effect Application

- (void)applyEffectToView:(UIView *)view {
    if (!view) return;

    // ★ Task228（用户反馈：切回液态玻璃主界面大面积变黑）：Task227 只回退了
    // cell 卡面路径（applyEffectToCell 无条件清玻璃），本方法——非 cell 的
    // 主界面表面（侧栏/右面板/内容三卡/筛选侧栏/登录卡/AI 卡等几十个调用
    // 点）——在玻璃风格下仍被 LGCApplyGlassToView 接管，而系统
    // UIGlassEffect 在本进程渲染为黑（Task225/Task228 两次装机实锤）→
    // Card 布局切风格瞬间三卡全黑。按用户既定指令（软件 UI 保持原生、
    // 玻璃只用于悬浮弹窗），与 cell 路径对齐：无条件清玻璃层，恒走既有
    // 毛玻璃/半透明管线。悬浮弹窗玻璃不经本方法（头像长按菜单与模态页
    // 底层直接走 LGCCreateGlassEffectView），不受影响。
    // LGCApplyGlassToView 保留为悬浮弹窗分层玻璃安装原语（无生产调用方）。
    LGCRemoveGlassFromView(view);

    // Task111：检测并切换——有自定义背景时毛玻璃/半透明卡片效果
    // （背景图从卡片下方透出）；无背景时平贴灰面/原生平铺（Task210 单路径）。
    // 防御性移除历史遗留的 blur 子视图在两条分支各自处理。
    if ([self hasBackground]) {
        if (self.uiEffect == BackgroundUIEffectBlur) {
            // 毛玻璃效果 - 创建 UIVisualEffectView 作为子视图
            for (UIView *subview in view.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                    [subview removeFromSuperview];
                }
            }

            // SystemThinMaterial：浅色/深色模式自适应，且足够通透让背景图透出
            UIBlurEffect *blur;
            if (@available(iOS 13.0, *)) {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
            } else {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
            }
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.tag = kBackgroundBlurTag;
            blurView.frame = view.bounds;
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blurView.layer.cornerRadius = view.layer.cornerRadius;
            blurView.layer.masksToBounds = YES;

            // 模糊强度→透明度（0.3~1.0），无背景时再提高不透明度使 UI 更清晰
            CGFloat effectiveAlpha = 0.3 + (self.blurIntensity * 0.7);
            if (![self hasBackground]) {
                effectiveAlpha = MIN(effectiveAlpha + 0.2, 1.0);
            }
            blurView.alpha = effectiveAlpha;

            // 毛玻璃本身不响应触摸，让事件穿透到宿主视图（如 UIControl 卡片）
            blurView.userInteractionEnabled = NO;

            [view insertSubview:blurView atIndex:0];
            view.backgroundColor = [UIColor clearColor];
        } else {
            // 半透明效果 - 移除 blur view，使用半透明背景
            for (UIView *subview in view.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                    [subview removeFromSuperview];
                }
            }
            if (@available(iOS 13.0, *)) {
                CGFloat effectiveOpacity = self.uiOpacity;
                if (![self hasBackground]) {
                    effectiveOpacity = MIN(effectiveOpacity + 0.3, 1.0);
                }
                UIColor *base = [UIColor secondarySystemBackgroundColor];
                view.backgroundColor = [base colorWithAlphaComponent:effectiveOpacity];
            } else {
                view.backgroundColor = [UIColor colorWithWhite:0.08 alpha:self.uiOpacity];
            }
        }
        return;
    }

    // Task210：新拟态平贴表面分支删除（用户定稿"保留平贴灰面但去掉双阴影"
    // 保留表面色本身）——无自定义背景时：调用点预置了圆角的（卡片容器）=
    // 平贴灰面（AmeCardSurfaceColor，浅 #e0e0e0 / 深 #2c2c2c，无任何自绘
    // 阴影）；未设圆角的（多数页面的整页 self.view）= systemBackground
    // 平铺整页，不加圆角不强制裁剪（原生页面形态）。
    CGFloat radius = view.layer.cornerRadius;
    if (radius > 0) {
        view.backgroundColor = AmeCardSurfaceColor();
        view.layer.cornerRadius = MAX(8.0, MIN(radius, 50.0));
        view.layer.masksToBounds = YES;
    } else {
        view.backgroundColor = [UIColor systemBackgroundColor];
    }
}

- (void)applyEffectToCollectionViewCell:(UICollectionViewCell *)cell {
    // Task190：Collection 与 Table cell 从此共用同一 Task172 三段式管线
    // （正文整体迁入泛型 ame190_applyCardPipelineToCell:，此处仅剩转发）。
    // 动因：账号列表（UITableView）按用户定稿与已安装版本页
    // （VersionManagerViewController / VMTileBaseCell，走本管线）逐像素
    // 同构——旧 applyEffectToCell: 是 Task172 之前的无开关管线，走它会
    // 在新拟态开关两种状态下都与版本页行为不一致。
    [self ame190_applyCardPipelineToCell:cell contentView:cell.contentView];
}

- (void)applyEffectToTableViewCell:(UITableViewCell *)cell {
    [self ame190_applyCardPipelineToCell:cell contentView:cell.contentView];
}

// Task190：卡面管线的泛型实现（原内联于 applyEffectToCollectionViewCell:）。
// CI 修复（run 36403614574 实锤）：UIView 基类没有 contentView 属性
//（property 'contentView' not found on object of type 'UIView *'）——
// 泛型参数收窄为 cell + contentView 双参数，由类型化包装点传入。
// Task210：新拟态三段式开关分支删除，恒为壁纸感知单路径（无壁纸 =
// 平贴灰面/原生平铺；有壁纸 = 毛玻璃/半透明随其余 UI 效果选项变化）。
- (void)ame190_applyCardPipelineToCell:(UIView *)cell contentView:(UIView *)contentView {
    if (!cell) return;

    // 无壁纸：清残留 blur 层后走无壁纸尾部
    //（applyEffectToView：容器圆角 > 0 = 平贴灰面，否则原生平铺）。
    if (![self hasBackground]) {
        UIView *target = nil;
        CGFloat radius = 0;
        for (UIView *sub in contentView.subviews) {
            if ([sub isKindOfClass:[UIVisualEffectView class]] && sub.tag == kBackgroundBlurTag) {
                [sub removeFromSuperview];
                continue;
            }
            if (!target && sub.layer.cornerRadius > 0 &&
                ![sub isKindOfClass:[UIImageView class]] &&
                ![sub isKindOfClass:[UILabel class]] &&
                ![sub isKindOfClass:[UITextView class]] &&
                ![sub isKindOfClass:[UIControl class]]) {
                target = sub;
                radius = sub.layer.cornerRadius;
            }
        }
        if (!target) {
            target = contentView;
            radius = contentView.layer.cornerRadius > 0
                ? contentView.layer.cornerRadius : 12;
        }
        for (UIView *sub in [target.subviews copy]) {
            if ([sub isKindOfClass:[UIVisualEffectView class]] && sub.tag == kBackgroundBlurTag) {
                [sub removeFromSuperview];
            }
        }
        cell.backgroundColor = [UIColor clearColor];
        contentView.backgroundColor = [UIColor clearColor];
        [self applyEffectToView:target];
        return;
    }

    // 有壁纸：壁纸管线（Task111 检测切换语义）——毛玻璃/半透明卡面随
    // 设置页其余 UI 效果选项变化（Task210：无新拟态开关，恒走本分支）。
    {
        // Task152：探测卡片容器（contentView 内第一个带圆角的非文本/控件子视图）。
        // 此前 blur/半透明一律铺满直角 contentView，而 VMTileBaseCell 等的圆角在
        // contentContainer 上 → 深色毛玻璃直角铺满 cell，卡片圆角四角外露出深色
        // 直角（用户实测"圆角有黑直边"）。现改为把效果作用到卡片容器本身，
        // 位置/尺寸/圆角全部对齐；无容器时回退 contentView（行为同旧）。
        UIView *cardTarget = nil;
        CGFloat cardRadius = 0;
        for (UIView *subview in contentView.subviews) {
            // ★ Task225（#4 嵌套崩溃根修）：一切 UIVisualEffectView 都不当
            // 卡面容器（旧判据只跳 kBackgroundBlurTag——玻璃层的 888901/
            // 888902 与页面底层的 kAme160GlassBackdropTag 均可被选中，
            // 下一轮 LGCApplyGlassToView 往效果视图里插效果视图 =
            // NSInternalInconsistencyException，设备实锤 latestlog.1 终末）。
            if ([subview isKindOfClass:[UIVisualEffectView class]]) {
                continue;
            }
            if (!cardTarget && subview.layer.cornerRadius > 0 &&
                ![subview isKindOfClass:[UIImageView class]] &&
                ![subview isKindOfClass:[UILabel class]] &&
                ![subview isKindOfClass:[UITextView class]] &&
                ![subview isKindOfClass:[UIControl class]]) {
                cardTarget = subview;
                cardRadius = subview.layer.cornerRadius;
            }
        }
        if (!cardTarget) {
            cardTarget = contentView;
            cardRadius = contentView.layer.cornerRadius > 0
                ? contentView.layer.cornerRadius : 12;
        }

        // Task210：残留阴影承载层清理原语随新拟态引擎一并删除（无挂载即无残留）。

        // ★ Task227（反馈 #3：就改悬浮弹窗——列表卡面玻璃回退）：Task224（#4）
        // 曾让液态玻璃风格接管 cell 卡面。用户明确指示软件 UI（列表/卡片/
        // 标签页切换器）保持原生外观，玻璃只用于悬浮弹窗。此处无条件清玻璃
        // 层并落回既有毛玻璃/半透明管线（从玻璃切回原生零残留）。
        LGCRemoveGlassFromView(cardTarget);

        if (self.uiEffect == BackgroundUIEffectBlur) {
            // 毛玻璃
            for (UIView *subview in contentView.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                    [subview removeFromSuperview];
                }
            }
            for (UIView *subview in cardTarget.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                    [subview removeFromSuperview];
                }
            }

            UIBlurEffect *blur;
            if (@available(iOS 13.0, *)) {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial];
            } else {
                blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
            }
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.tag = kBackgroundBlurTag;
            blurView.frame = cardTarget.bounds;
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blurView.layer.cornerRadius = cardRadius;
            blurView.layer.cornerCurve = cardTarget.layer.cornerCurve;
            blurView.layer.masksToBounds = YES;
            blurView.alpha = 0.3 + (self.blurIntensity * 0.7);
            blurView.userInteractionEnabled = NO;

            [cardTarget insertSubview:blurView atIndex:0];
            cardTarget.backgroundColor = [UIColor clearColor];
            cell.backgroundColor = [UIColor clearColor];
            contentView.backgroundColor = [UIColor clearColor];
        } else {
            // 半透明
            for (UIView *subview in contentView.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                    [subview removeFromSuperview];
                }
            }
            for (UIView *subview in cardTarget.subviews) {
                if ([subview isKindOfClass:[UIVisualEffectView class]] && subview.tag == kBackgroundBlurTag) {
                    [subview removeFromSuperview];
                }
            }
            if (@available(iOS 13.0, *)) {
                cardTarget.backgroundColor = [[UIColor secondarySystemBackgroundColor]
                    colorWithAlphaComponent:self.uiOpacity];
            } else {
                cardTarget.backgroundColor = [UIColor colorWithWhite:0.1 alpha:self.uiOpacity];
            }
            cell.backgroundColor = [UIColor clearColor];
            contentView.backgroundColor = [UIColor clearColor];
        }
        return;
    }
}

- (void)applyCardEffectToCell:(UITableViewCell *)cell {
    if (!cell) return;

    // Task210：新拟态开关分支删除——恒为旧管线 applyEffectToCell
    //（有壁纸 = 毛玻璃/半透明随其余 UI 效果选项变化；无壁纸 = 平贴灰面
    // /标准列表外观），与新拟态彻底脱钩。
    [self applyEffectToCell:cell];
}

- (void)applyCardEffectToView:(UIView *)view {
    if (!view) return;

    // Task210 改名（原 applyNeumorphCardEffectToView:）：新拟态退役后
    // 恒为壁纸感知单路径——有壁纸 = 毛玻璃/半透明（随设置页其余 UI 效果
    // 选项变化），无壁纸 = 平贴灰面（AmeCardSurfaceColor）/原生平铺。
    // 原语（ame_applyNeumorphSurface / ame_applyNeumorphCardOpacity /
    // ame_removeNeumorphShadow）已随引擎一并删除，此转发与旧"开关关闭"
    // 分支语义逐字节一致。
    [self applyEffectToView:view];
}

- (void)applyEffectToSearchBar:(UISearchBar *)searchBar {
    if (!searchBar) return;

    // 1. searchBar 整体背景透明，让底层自定义启动器背景透出
    //    UISearchBar 默认是不透明的 systemBackgroundColor，会遮挡全局背景图/毛玻璃
    searchBar.barTintColor = [UIColor clearColor];
    searchBar.backgroundColor = [UIColor clearColor];
    searchBar.translucent = YES;
    // Minimal 样式让系统不绘制不透明背景，仅保留输入框背景
    searchBar.searchBarStyle = UISearchBarStyleMinimal;
    // 移除系统自动添加的 _UISearchBarBackground 不透明背景视图
    for (UIView *sub in searchBar.subviews) {
        for (UIView *inner in sub.subviews) {
            if ([NSStringFromClass(inner.class) containsString:@"Background"]) {
                inner.backgroundColor = [UIColor clearColor];
                inner.hidden = NO;
            }
        }
        if ([NSStringFromClass(sub.class) containsString:@"Background"]) {
            sub.backgroundColor = [UIColor clearColor];
        }
    }

    // 2. 透明化内部 UITextField（搜索输入框）背景
    //    UITextField 默认带 systemFillColor 浅灰色背景，遮挡自定义背景
    UITextField *textField = nil;
    for (UIView *sub in searchBar.subviews) {
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:[UITextField class]]) {
                textField = (UITextField *)inner;
                break;
            }
        }
        if (textField) break;
    }
    // iOS 13+ 可直接用 -searchTextField
    if (!textField && [searchBar respondsToSelector:@selector(searchTextField)]) {
        @try {
            textField = [searchBar performSelector:@selector(searchTextField)];
        } @catch (NSException *e) {
            textField = nil;
        }
    }
    if (textField) {
        if (self.uiEffect == BackgroundUIEffectBlur) {
            // 毛玻璃：输入框背景设为浅色半透明，保证文字可读且不挡背景
            if (@available(iOS 13.0, *)) {
                textField.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.5];
            } else {
                textField.backgroundColor = [UIColor colorWithWhite:0.95 alpha:0.5];
            }
        } else {
            // 半透明效果：输入框背景按 uiOpacity 调整
            if (@available(iOS 13.0, *)) {
                textField.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:MAX(0.3, self.uiOpacity)];
            } else {
                textField.backgroundColor = [UIColor colorWithWhite:0.95 alpha:MAX(0.3, self.uiOpacity)];
            }
        }
    }
}

#pragma mark - Legacy Methods

- (void)applyBackgroundToView:(UIView *)view {
    // Find the view controller or window
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UISplitViewController class]]) {
            [self applyBackgroundToSplitViewController:(UISplitViewController *)responder];
            return;
        }
        if ([responder isKindOfClass:[UIWindow class]]) {
            [self applyBackgroundToWindow:(UIWindow *)responder];
            return;
        }
        responder = responder.nextResponder;
    }
}

- (void)removeBackgroundFromView:(UIView *)view {
    [self removeGlobalBackground];
}

#pragma mark - Video Management

- (void)cleanupVideoPlayer {
    if (self.videoPlayer) {
        [self.videoPlayer pause];
        self.videoPlayer = nil;
    }
    if (self.videoPlayerLayer) {
        [self.videoPlayerLayer removeFromSuperlayer];
        self.videoPlayerLayer = nil;
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    AVPlayerItem *playerItem = notification.object;
    [playerItem seekToTime:kCMTimeZero completionHandler:nil];
}

#pragma mark - App Lifecycle

- (void)appDidEnterBackground {
    [self pauseVideo];
}

- (void)appWillEnterForeground {
    [self resumeVideo];
}

- (void)pauseVideo {
    if (self.videoPlayer) [self.videoPlayer pause];
}

- (void)resumeVideo {
    if (self.videoPlayer && self.currentType == BackgroundTypeVideo) {
        [self.videoPlayer play];
    }
}

#pragma mark - Set Background

- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!image) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_48", nil)}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing
        [self clearBackgroundInternal];
        
        // Save image
        NSString *fileName = [NSString stringWithFormat:@"background_image_%ld.jpg", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        NSData *imageData = UIImageJPEGRepresentation(image, 0.85);
        if (!imageData) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_49", nil)}]);
            });
            return;
        }
        
        BOOL saved = [imageData writeToFile:filePath atomically:YES];
        
        if (saved) {
            self.currentType = BackgroundTypeImage;
            self.currentBackgroundPath = filePath;
            self.backgroundSource = @"user"; // Task151：用户手动设置，优先于 Bing 自动应用
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Reapply if needed
                if (self.currentSplitVC) {
                    [self applyBackgroundToSplitViewController:self.currentSplitVC];
                } else if (self.currentWindow) {
                    [self applyBackgroundToWindow:self.currentWindow];
                }
                // Task152：无背景 → 有背景的同款即时生效刷新（用户首次设置图片/视频）
                [self refreshTransparencyForWindowUI];

                if (completion) completion(YES, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:3 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_50", nil)}]);
            });
        }
    });
}

#pragma mark - Task151：Bing 每日壁纸联动

- (BOOL)isBingSource {
    return [self.backgroundSource isEqualToString:@"bing"];
}

// Task162：背景容器是否真实挂在活窗口上。
// 判定链：容器存在 → 容器有 window（在任意 UIWindow 层级里）→ 宿主引用
//（currentWindow / currentSplitVC）至少一个活着且其视图也在窗口上。
// 轻量纯读，Bing 每次元数据同步/前台回调时调用一次无性能负担。
- (BOOL)isBackgroundLiveAttached {
    if (![self hasBackground]) return NO;
    if (!self.globalBackgroundContainer) return NO;
    if (!self.globalBackgroundContainer.window) return NO;
    // 容器挂载了但宿主引用双失（理论上不该发生——容器就在宿主视图里），
    // 视为脱节，交由调用方重放应用重建全链。
    BOOL ame162_hostAlive = (self.currentWindow != nil && self.currentWindow.rootViewController != nil)
        || (self.currentSplitVC != nil && self.currentSplitVC.view.window != nil);
    return ame162_hostAlive;
}

// 将 Bing 缓存目录中已存在的图片直接登记为当前背景（不复制、不删源文件）。
// 与 setImageBackground 的差异：跳过 JPEG 重编码与 backgrounds/ 目录复制，
// 来源标记为 bing（供 BingWallpaperManager 的"用户优先"守卫与画廊勾选使用）。
- (void)setBingBackgroundImageAtPath:(NSString *)path completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:6 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_48", nil)}]);
        }
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self clearBackgroundInternal];

        self.currentType = BackgroundTypeImage;
        self.currentBackgroundPath = path;
        self.backgroundSource = @"bing";
        [self saveBackgroundSettings];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.currentSplitVC) {
                [self applyBackgroundToSplitViewController:self.currentSplitVC];
            } else if (self.currentWindow) {
                [self applyBackgroundToWindow:self.currentWindow];
            }
            // Task152：首次拉到 Bing 壁纸时既有 VC 是"无背景"时期建的（不透明），
            // 必须重放透明化，否则壁纸被盖住直到重启。
            [self refreshTransparencyForWindowUI];
            if (completion) completion(YES, nil);
        });
    });
}

- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!videoURL || ![[NSFileManager defaultManager] fileExistsAtPath:videoURL.path]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:@"BackgroundManager" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_51", nil)}]);
        }
        return;
    }
    
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Clear existing
        [self clearBackgroundInternal];
        
        // Copy video
        NSString *fileName = [NSString stringWithFormat:@"background_video_%ld.mp4", (long)[[NSDate date] timeIntervalSince1970]];
        NSString *filePath = [[self backgroundsFolderPath] stringByAppendingPathComponent:fileName];
        
        NSError *copyError = nil;
        BOOL copied = [[NSFileManager defaultManager] copyItemAtURL:videoURL toURL:[NSURL fileURLWithPath:filePath] error:&copyError];
        
        if (copied) {
            self.currentType = BackgroundTypeVideo;
            self.currentBackgroundPath = filePath;
            self.backgroundSource = @"user"; // Task151：用户手动设置，优先于 Bing 自动应用
            [self saveBackgroundSettings];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                // Reapply if needed
                if (self.currentSplitVC) {
                    [self applyBackgroundToSplitViewController:self.currentSplitVC];
                } else if (self.currentWindow) {
                    [self applyBackgroundToWindow:self.currentWindow];
                }
                // Task152：无背景 → 有背景的同款即时生效刷新（用户首次设置图片/视频）
                [self refreshTransparencyForWindowUI];

                if (completion) completion(YES, nil);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, copyError ?: [NSError errorWithDomain:@"BackgroundManager" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_52", nil)}]);
            });
        }
    });
}

- (void)clearBackground {
    [self clearBackgroundInternal];
    [self removeGlobalBackground];
    [self saveBackgroundSettings];
}

- (void)clearBackgroundInternal {
    [self cleanupVideoPlayer];

    if (self.currentBackgroundPath) {
        // Task151：仅清理 backgrounds/ 目录内的文件。Bing 缓存图
        // （Application Support/BingWallpaper/）不属于本目录，清除背景时
        // 保留缓存（离线回退与画廊复用需要），避免误删后重复下载。
        NSString *folder = [self backgroundsFolderPath];
        if ([self.currentBackgroundPath hasPrefix:folder]) {
            [[NSFileManager defaultManager] removeItemAtPath:self.currentBackgroundPath error:nil];
        }
    }

    self.currentType = BackgroundTypeNone;
    self.currentBackgroundPath = nil;
    self.backgroundSource = nil; // Task151：来源一并复位（saveBackgroundSettings 移除标记）
}

#pragma mark - Check Background

- (BOOL)hasBackground {
    return self.currentType != BackgroundTypeNone && self.currentBackgroundPath != nil;
}

- (BOOL)hasImageBackground {
    return self.currentType == BackgroundTypeImage && self.currentBackgroundPath != nil;
}

- (BOOL)hasVideoBackground {
    return self.currentType == BackgroundTypeVideo && self.currentBackgroundPath != nil;
}

#pragma mark - Preview

- (nullable UIImage *)backgroundPreview {
    if (self.currentType == BackgroundTypeImage && self.currentBackgroundPath) {
        return [UIImage imageWithContentsOfFile:self.currentBackgroundPath];
    }
    return nil;
}

@end
// ============================================================================
// ★ Task227（反馈 #11：全局白底黑边字体——"我说了许多次了"）：
// UILabel setText: 方法交换（swizzle）。壁纸在场时，所有 UILabel 的纯文本
// 一律重写为 白色填充 + 黑色描边（NSStrokeWidth -2.6）+ 软阴影——任何壁
// 纸上可读，不再依赖各页面逐点接入（此前仅 5 处显式调用 applyAdaptive
// TextToLabel，覆盖率远低于用户预期）。无壁纸时零干预（原生外观零回归）。
//
// 边界与防御：
//   * 只处理纯 setText:（attributedText 直设的富文本不动）；
//   * 空文本直接透传；
//   * 壁纸状态每次实时判定（切换壁纸后下一次 setText 自动回到原生）；
//   * 交换只做一次（+load 中 dispatch_once）。
// ============================================================================
#import <objc/runtime.h>
#import <objc/message.h>

static void (*ame227_origLabelSetText)(id, SEL, NSString *);

// Task229: per-label opt-out (associated object). Labels placed on solid
// light surfaces (coach-mark cards, the file browser sheet) must NOT get the
// white-fill/stroke treatment -- white on a white card reads as blank text.
static char ame229_StrokeExemptKey;
void ame229_labelSetStrokeExempt(UILabel *label, BOOL exempt) {
    objc_setAssociatedObject(label, &ame229_StrokeExemptKey,
                             @(exempt), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
BOOL ame229_labelIsStrokeExempt(UILabel *label) {
    NSNumber *v = objc_getAssociatedObject(label, &ame229_StrokeExemptKey);
    return v.boolValue;
}

// ★ Task230（反馈 #12：欢迎界面圆圈焦点介绍空白，复发轮）：视图树级豁免。
//   Task229 只做了【单标签】豁免（教练标记卡、文件浏览器）；但欢迎向导
//   的介绍页（step 5，ame222_buildIntroStep）标签用 labelColor 铺在
//   secondarySystemGroupedBackgroundColor 0.92 的浅色卡上——壁纸在场时
//   全局 swizzle 把它们染成白字 = 浅底白字隐形 = "圆圈焦点介绍空白"。
//   向导页面结构动态创建、逐个豁免易漏，提供整树豁免：在容器根视图上
//   打标，swizzle 沿 superview 链上溯（上限 16 层）命中即豁免。
static char ame230_TreeExemptKey;
void ame230_setViewTreeStrokeExempt(UIView *view, BOOL exempt) {
    objc_setAssociatedObject(view, &ame230_TreeExemptKey,
                             @(exempt), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL ame230_viewTreeIsStrokeExempt(UILabel *label) {
    UIView *v = (UIView *)label;
    for (int i = 0; i < 16 && v != nil; ++i) {
        NSNumber *n = objc_getAssociatedObject(v, &ame230_TreeExemptKey);
        if (n && n.boolValue) return YES;
        v = v.superview;
    }
    return NO;
}

// ★ Task232（反馈 #16）：外扩描边标记 + drawTextInRect: 交换。setText: 染白
//   并打标；本交换在绘制时先画四份 0.6pt 偏移的深色拷贝（字形外侧造边），
//   再调原实现画白色正文居中盖上。字腔（孔洞）宽度 ≥1.2pt 保持纯白——
//   CoreText 居中描边与模糊光晕都会向内渗黑，这是“中文字体内部黑线”
//   连续三轮修不掉的构造性根因。绘制时复核壁纸/豁免状态（壁纸切换后
//   旧标记的标签立即回到原生外观）。
static void (*ame232_origLabelDrawTextInRect)(id, SEL, CGRect);

static BOOL ame232_shouldPaintOutline(UILabel *label) {
    if (![[BackgroundManager sharedManager] hasBackground]) return NO;
    if (ame229_labelIsStrokeExempt(label)) return NO;
    if (ame230_viewTreeIsStrokeExempt(label)) return NO;
    return YES;
}

/// Task233（反馈 #16 后续：字体双层 / 有地方重叠不上 / 有透明度导致偏黑）：
/// 把任意颜色提为全不透明（getRed 失败的非 RGB 色回落白色）。半透明白字
/// （secondary 0.82）下面透出深色描边拷贝 = "字体偏黑"的来源——垫底拷贝
/// 必须不透明。
static UIColor *ame233_opaqueColor(UIColor *ame233_c) {
    if (ame233_c == nil) return [UIColor whiteColor];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([ame233_c getRed:&r green:&g blue:&b alpha:&a]) {
        return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
    }
    return [UIColor whiteColor];
}

static void ame232_swizzledLabelDrawTextInRect(id self, SEL _cmd, CGRect rect) {
    @try {
        NSNumber *ame232_mark = objc_getAssociatedObject(self, &ame232_OutlineMarkKey);
        if (ame232_mark.boolValue && ame232_shouldPaintOutline((UILabel *)self)) {
            UILabel *ame232_label = (UILabel *)self;
            NSAttributedString *ame232_as = ame232_label.attributedText;
            if (ame232_as.length > 0 && UIGraphicsGetCurrentContext() != NULL) {
                // ★ Task242（用户："文字重叠问题在一些角落依旧出现，不能自适应吗，
                //   非要手动适配"）：【镜像 UILabel 渲染】取代 Task233-241 九轮
                //   手动几何镜像（233 对齐/234 垂直锚定/235 单行缩字/236 多行
                //   缩字二分/238 ==0 词换行/239 段落继承/241 溢出跳过）。
                //   结构性定案：深拷贝与垫底不再用 NSAttributedString drawInRect
                //   手动复刻 UILabel 排版（每轮只修一个分歧点，用户实测仍有角落
                //   漏网），而是构造【镜像 UILabel】——attributedText 同源 +
                //   numberOfLines/lineBreakMode/textAlignment/adjustsFontSize
                //   ToWidth/minimumScaleFactor 全属性镜像，由 UIKit 同一套
                //   drawTextInRect 内核渲染（textRectForBounds 垂直居中、截断、
                //   缩字、富文本段落优先全部与本体制画 100% 同源）——
                //   分歧族从构造上不存在 = 自适应，无需再逐角手修。
                //   叠序不变：四向 0.6pt 深拷贝 → 不透明原色垫底 → 正文本体
                //   （orig 实现）。镜像 label 未打描边标记 → 不触发本 swizzle
                //   递归；attributedText 驱动时 label 级对齐/断行属性被字符串
                //   段落覆盖，与本体制画语义一致。
                UIColor *ame242_dark = [UIColor colorWithWhite:0.0 alpha:0.82];
                UIColor *ame242_opaque = ame233_opaqueColor(ame232_label.textColor);

                NSMutableAttributedString *ame242_darkStr =
                    [[NSMutableAttributedString alloc] initWithAttributedString:ame232_as];
                NSRange ame242_full = NSMakeRange(0, ame242_darkStr.length);
                [ame242_darkStr addAttribute:NSForegroundColorAttributeName
                                       value:ame242_dark
                                       range:ame242_full];

                NSMutableAttributedString *ame242_backStr =
                    [[NSMutableAttributedString alloc] initWithAttributedString:ame232_as];
                [ame242_backStr addAttribute:NSForegroundColorAttributeName
                                       value:ame242_opaque
                                       range:ame242_full];

                CGContextRef ame242_ctx = UIGraphicsGetCurrentContext();
                static const CGPoint ame242_offsets[4] = {
                    {0.6f, 0.0f}, {-0.6f, 0.0f}, {0.0f, 0.6f}, {0.0f, -0.6f}
                };
                for (int ame242_i = 0; ame242_i < 4; ame242_i++) {
                    UILabel *ame242_mirror = [[UILabel alloc] initWithFrame:
                        CGRectOffset(rect, ame242_offsets[ame242_i].x, ame242_offsets[ame242_i].y)];
                    ame242_mirror.attributedText = ame242_darkStr;
                    ame242_mirror.numberOfLines = ame232_label.numberOfLines;
                    ame242_mirror.lineBreakMode = ame232_label.lineBreakMode;
                    ame242_mirror.textAlignment = ame232_label.textAlignment;
                    ame242_mirror.adjustsFontSizeToFitWidth = ame232_label.adjustsFontSizeToFitWidth;
                    ame242_mirror.minimumScaleFactor = ame232_label.minimumScaleFactor;
                    ame242_mirror.baselineAdjustment = ame232_label.baselineAdjustment;
                    ame242_mirror.userInteractionEnabled = NO;
                    ame242_mirror.backgroundColor = nil;
                    [ame242_mirror.layer renderInContext:ame242_ctx];
                }
                UILabel *ame242_backing = [[UILabel alloc] initWithFrame:rect];
                ame242_backing.attributedText = ame242_backStr;
                ame242_backing.numberOfLines = ame232_label.numberOfLines;
                ame242_backing.lineBreakMode = ame232_label.lineBreakMode;
                ame242_backing.textAlignment = ame232_label.textAlignment;
                ame242_backing.adjustsFontSizeToFitWidth = ame232_label.adjustsFontSizeToFitWidth;
                ame242_backing.minimumScaleFactor = ame232_label.minimumScaleFactor;
                ame242_backing.baselineAdjustment = ame232_label.baselineAdjustment;
                ame242_backing.userInteractionEnabled = NO;
                ame242_backing.backgroundColor = nil;
                [ame242_backing.layer renderInContext:ame242_ctx];
            }
        }
    } @catch (NSException *ame232_e) {
        // 任何意外（系统私有标签子类等）绝不影响绘制主链
    }
    if (ame232_origLabelDrawTextInRect) {
        ame232_origLabelDrawTextInRect(self, _cmd, rect);
    }
}

static void ame227_swizzledLabelSetText(id self, SEL _cmd, NSString *text) {
    if (!ame227_origLabelSetText) return;
    ame227_origLabelSetText(self, _cmd, text);
    @try {
        if (text.length == 0) return;
        if (![[BackgroundManager sharedManager] hasBackground]) return;
        // Task229 (feedback #9): opted-out labels keep their native look.
        if (ame229_labelIsStrokeExempt((UILabel *)self)) return;
        // Task230 (feedback #12): view-tree opt-out (welcome wizard & friends).
        if (ame230_viewTreeIsStrokeExempt((UILabel *)self)) return;
        // 注：不守卫 attributedText——setText: 之后 attributedText 恒非 nil
        //（UIKit 把纯文本包装成 attributed 存储），该守卫会跳过一切。
        // 真正的富文本路径（attributedText 直设）不经 setText:，天然不受
        // 本交换影响。
        UILabel *ame227_label = (UILabel *)self;
        if (ame227_label.font == nil) return;
        // Task229 (feedback #10: "black lines inside the font"): a negative
        // NSStrokeWidth paints the stroke ON TOP of the fill with the outline
        // centered on the glyph edge -- at -2.6 the counters of dense CJK
        // glyphs (the character 'de' has four enclosed counters) and entire
        // line-shaped glyphs (the full-width slash) were swallowed into solid
        // black. Rework: a thinner stroke (-1.6) in a SEMI-TRANSPARENT dark
        // color reads as a soft dark halo instead of hard black ink, and the
        // strengthened drop shadow carries most of the contrast duty, so
        // legibility on busy wallpapers is preserved while interiors stay
        // clean.
        // ★ Task232（反馈 #16：中文字体内部黑线，第三轮）：CoreText 负
        //   strokeWidth 的描边以字形轮廓为中心，内半边吃进密集 CJK 笔画
        //   间隙；零偏移光晕（radius 2.5）向字腔渗黑——两者都是“内部
        //   黑线”的构造性来源，调参数修不掉。改道：setText: 只负责把
        //   文字染白 + 打描边标记；真正的描边由 drawTextInRect: 交换做
        //   【四方向 0.6pt 外扩深色拷贝 + 原色居中】——边只长在字形
        //   外侧，字腔保持纯白（详见 ame232_swizzledLabelDrawTextInRect）。
        ame227_label.textColor = [UIColor whiteColor];
        objc_setAssociatedObject(ame227_label, &ame232_OutlineMarkKey,
                                 @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ame227_label.layer.shadowOpacity = 0.0;
        ame227_label.layer.shadowRadius = 0.0;
    } @catch (NSException *ame227_e) {
        // 任何意外（系统私有标签子类等）绝不影响 setText 主链
    }
}

@implementation UILabel (Ame227GlobalStrokeFont)
+ (void)load {
    static dispatch_once_t ame227_once;
    dispatch_once(&ame227_once, ^{
        Method ame227_m = class_getInstanceMethod(self, @selector(setText:));
        if (ame227_m == NULL) return;
        ame227_origLabelSetText = (void (*)(id, SEL, NSString *))method_getImplementation(ame227_m);
        method_setImplementation(ame227_m, (IMP)ame227_swizzledLabelSetText);
        // ★ Task232（反馈 #16）：外扩描边绘制交换（与 setText: 交换同装）。
        Method ame232_m = class_getInstanceMethod(self, @selector(drawTextInRect:));
        if (ame232_m != NULL) {
            ame232_origLabelDrawTextInRect = (void (*)(id, SEL, CGRect))method_getImplementation(ame232_m);
            method_setImplementation(ame232_m, (IMP)ame232_swizzledLabelDrawTextInRect);
        }
    });
}
@end
