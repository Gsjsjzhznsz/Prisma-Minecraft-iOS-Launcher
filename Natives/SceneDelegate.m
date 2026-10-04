#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "LauncherRootViewController.h"
#import "LauncherCardLayoutViewController.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "BingWallpaperManager.h" // Task151
#import "WelcomeViewController.h" // Task218：首次使用欢迎向导
// Terracotta 暂时移除（排查启动崩溃）
// #import "TerracottaManager.h"
// #import "TerracottaBridge.h"

extern __weak UIWindow *mainWindow;

@interface SceneDelegate ()
// Task191：横向窗口的持向基线（首次观察到该横向窗口时的设备方向）。
// 设备对调（LandscapeLeft <-> LandscapeRight）时内容补转 180°。
@property (nonatomic, assign) UIDeviceOrientation ame191_landscapeBaseline;
@end

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    UIWindowScene *windowScene = (UIWindowScene *)scene;

    // Task189：异常处理器晚装复挂（AppDelegate 挂载点之后 LC 若再覆盖，
    // 此处再抢回一次——场景连接是 UI 阶段最后的稳定挂载点）。
    // Task191：补装机锚点日志——dde0f82 会话（latestlog.1）的 insertObject
    // nil 崩溃仍走系统默认输出（无 "Uncaught exception:" 符号栈），
    // 且日志里两处 re-arm 均不可见（AppDelegate 点无日志输出、此处
    // 静默安装）——先让 willConnect 点的 re-arm 可观测，下轮日志直接
    // 判定此点是否安装成功、还是 LC 在更晚时机再次覆盖。
    {
        extern void uncaughtExceptionHandler(NSException *exception);
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
        NSLog(@"[SceneDelegate] Task191: uncaught-exception handler re-armed at willConnect");
        // Task192：定时复挂（LC 覆盖战争的终局方案）。
        // 病历（956ea9b latestlog.1）：willConnect 点的 re-arm 日志在场，
        // 但 insertObject nil 崩溃仍走系统默认裸地址输出——证明 LC 在
        // willConnect 之后（框架装载/invokeAppMain 尾段）又装了自己的
        // 处理器。与其追挂载点竞速，改为周期性检测+抢回：每 2 秒查
        // NSGetUncaughtExceptionHandler() 是否仍是我们的，被偷就装回
        // （每次抢回都打锚点）。60 秒后降频到 30 秒。最后一次安装者
        // 生效——只要我们在崩溃前的任一 tick 抢回，符号化栈就到手。
        static dispatch_source_t s_ame192_timer = NULL;
        static BOOL s_ame192_started = NO;
        if (!s_ame192_started) {
            s_ame192_started = YES;
            s_ame192_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
            dispatch_source_set_timer(s_ame192_timer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                      2 * NSEC_PER_SEC, NSEC_PER_SEC);
            __block int64_t ame192_elapsed = 0;
            dispatch_source_set_event_handler(s_ame192_timer, ^{
                ame192_elapsed += 2;
                if (ame192_elapsed > 60) {
                    dispatch_source_set_timer(s_ame192_timer, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                                              30 * NSEC_PER_SEC, NSEC_PER_SEC);
                }
                if (NSGetUncaughtExceptionHandler() != &uncaughtExceptionHandler) {
                    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
                    NSLog(@"[SceneDelegate] Task192: uncaught-exception handler STOLEN (was=%p) -- re-armed at t+%llds",
                          (void *)NSGetUncaughtExceptionHandler(), (long long)ame192_elapsed);
                }
            });
            dispatch_resume(s_ame192_timer);
        }
    }

    // 强制横屏 (iOS 16+)
    // Task188：窗口模式（iPadOS 26+ 多窗口/LiveContainer 宿主）下系统持有
    // 几何、本请求预期被拒（Code=101）——Info.plist 的 UIRequiresFullScreen=true
    // 才是主修复；此请求仅在全屏模式下作纵深防御，失败为预期态降级为单次
    // 提示（不再每次启动刷一条 Failed 日志）。
    if (@available(iOS 16.0, *)) {
        UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
        geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscape;
        [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError *error) {
            static BOOL s_task188_logged = NO;
            if (!s_task188_logged) {
                s_task188_logged = YES;
                NSLog(@"[SceneDelegate] Task188: geometry request declined (expected in window mode; Info.plist UIRequiresFullScreen is the primary fix): %@", error.localizedDescription);
            }
        }];
    }
    
    self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
    self.window.frame = windowScene.coordinateSpace.bounds;
    // Task137：窗口底色回归 iOS 原生系统底色（深浅色由语义色自动适配）；
    // 用户设置自定义壁纸时仍由 BackgroundManager.applyBackgroundToWindow
    // 接管（Task111 检测并切换）。
    self.window.backgroundColor = [UIColor systemBackgroundColor];
    mainWindow = self.window;

    // 根据设置选择布局：Task180 用户定稿默认 = 卡片式便当盒布局；显式选择
    // 过 "vs"（写盘）的设备保持三栏布局（未写盘 = 从未选择 → 走新默认 card）
    NSString *layout = getPrefObject(@"general.ui_layout");
    UIViewController *rootVC;
    if ([layout isEqualToString:@"vs"]) {
        rootVC = [[LauncherRootViewController alloc] init];
    } else {
        rootVC = [[LauncherCardLayoutViewController alloc] init];
    }
    self.window.rootViewController = rootVC;

    // Task218：首次使用欢迎向导（general.welcome_completed 哨兵，默认 NO）。
    // 延迟 0.8s 让主界面先完成首帧布局，再全屏淡入向导（语言 / 下载源 /
    // 数据导入三步引导 + 动效）。完成或跳过即置 YES，此后不再打扰。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [WelcomeViewController presentIfNeededFromViewController:rootVC];
    });

    // 外观模式（浅色/深色/跟随系统）：读 general.ui_theme 偏好。
    //   light  -> UIUserInterfaceStyleLight
    //   dark   -> UIUserInterfaceStyleDark（Task160 前的历史默认）
    //   auto   -> UIUserInterfaceStyleUnspecified（跟随系统；Task161 起为默认）
    // iOS 13+ 支持 overrideUserInterfaceStyle。仅设置 window 级别，不触碰账号/偏好。
    if (@available(iOS 13.0, *)) {
        // Task161：一次性迁移——外观默认值改为"跟随系统"（用户指令）。历史
        // 版本的默认合并曾把 dark（Task160 前）/ light（Task160）静默写盘，
        // 只改默认表对这些设备无效；未显式选择过的设备（无
        // general.ui_theme_explicit 标记）若还停在两个历史默认值上，迁移到
        // auto。显式选过的设备永不覆盖（标记在设置页 pick 的 action 里置位）。
        // Task216：一次性迁移——用户定稿默认初始值回到"跟随系统"。历史
        // 迁移链：Task161 曾迁 auto/light → auto，Task180 又把 auto/light
        // 迁到 dark；本轮把未显式选择过的设备（无 general.ui_theme_explicit
        // 标记，无论停在 dark（Task180 迁移值）/ light（Task160 历史默认））
        // 统一迁回 auto。显式选过的设备永不覆盖（Task161 家法不变）。
        if (!getPrefBool(@"general.ui_theme_explicit")) {
            NSString *ame216_legacy = getPrefObject(@"general.ui_theme");
            if (![ame216_legacy isEqualToString:@"auto"]) {
                setPrefObject(@"general.ui_theme", @"auto");
                NSLog(@"[SceneDelegate] Task216: ui_theme '%@' was never explicitly chosen -> migrated to 'auto' (follow system, user-specified default)", ame216_legacy);
            }
        }
        NSString *theme = getPrefObject(@"general.ui_theme");
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }

    [self.window makeKeyAndVisible];

    // Task189（强制横屏第三轮）：窗口内容旋转兜底。Task187 移除 Portrait、
    // Task188 声明 UIRequiresFullScreen=true 均在真机无效——LiveContainer 宿主
    // 下窗口模式由【宿主】的 plist 决定，来宾 plist 的方向列表与全屏声明不被
    // 系统采纳（几何请求 Code=101 拒绝 + 仍处窗口模式双证）。本轮不再依赖
    // 系统honoring任何声明：窗口为竖向时直接对 UIWindow 施加 90° transform，
    // 把内容坐标系换为横屏（bounds 高宽互换 + center 对齐窗口中心）——UI、
    // 游戏、触控（UIKit 命中测试自动走逆变换）全部一致，物理窗口形状不变、
    // 内容铺满无黑边。横屏窗口零变化（transform 恒等）。场景尺寸变化（用户
    // 调整窗口大小 / 旋转设备）经 didUpdateCoordinateSpace 重评估。
    [self ame189_applyLandscapeWindowTransform];
    NSLog(@"[SceneDelegate] Task189: landscape window transform evaluated (bounds=%@ rotated=%d)",
          NSStringFromCGRect(self.window.windowScene.coordinateSpace.bounds),
          (int)!CGAffineTransformIsIdentity(self.window.transform));

    // Task191：设备持向变化重评估（±90°/180° 跟手的唯一时机——窗口几何
    // 在自由窗口模式下不随设备旋转变化，didUpdateCoordinateSpace 不够）。
    // 开启加速计采样 + 监听方向变化通知；sceneDidDisconnect 摘除。
    [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame191_deviceOrientationDidChange:)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];

    // Task137：Task136 的 NMContrast 动态文字对比度扫描器随新拟态一并退役。
    // 深底深字问题改为直接修复（各元素使用系统语义色/动态色自动适配，
    // 例：右侧栏下载中心按钮 Task137 已改 secondarySystemGroupedBackground
    // 底 + labelColor 字，深浅色下对比度均由系统保证）。

    // 立即应用背景（移除原来的 0.1s 延迟）：
    // 延迟会在启动时露出窗口底色形成"黑条"或"黑闪"。BackgroundManager 在其 init
    // 中已 loadSavedBackground/loadUISettings，单例首次访问即完成初始化，无需延迟。
    [[BackgroundManager sharedManager] applyBackgroundToWindow:self.window];

    // Task151：Bing 每日壁纸自动刷新与应用（默认开启；全异步不阻塞启动：
    // 有缓存今日图直接登记背景，否则联网拉取后换图；用户自定义壁纸优先）。
    [[BingWallpaperManager sharedManager] autoRefreshAndApplyIfEnabled];

    [self showTranslationNoticeIfNeeded];

    // Terracotta 暂时移除（排查启动崩溃）
    // if ([TerracottaBridge isAvailable]) {
    //     TerracottaManager *mgr = [TerracottaManager shared];
    //     NSLog(@"[SceneDelegate] Terracotta manager initialized: %d", mgr.initialized);
    // } else {
    //     NSLog(@"[SceneDelegate] libterracotta not linked, multiplayer disabled");
    // }
    NSLog(@"[SceneDelegate] Terracotta temporarily disabled for crash investigation");

    // 监听主题切换通知（设置页"外观模式"切换时实时应用，无需重启）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyUITheme:)
                                                 name:@"UIThemeChanged"
                                               object:nil];
    // 监听语言切换通知
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applyLanguageChange:)
                                                 name:@"AppLanguageChanged"
                                               object:nil];
}

- (void)showTranslationNoticeIfNeeded {
    // 仅当实际显示语言为英文时提示（包括系统英文和手动选择英文）。
    // 用户选择“不再提醒”后通过偏好持久化，下次不再弹出。
    NSString *lang = getPrefObject(@"general.app_language");
    BOOL isEnglish;
    if (lang && ![lang isEqualToString:@"system"]) {
        isEnglish = [lang isEqualToString:@"en"];
    } else {
        isEnglish = [NSLocale.preferredLanguages.firstObject hasPrefix:@"en"];
    }
    if (!isEnglish) {
        return;
    }
    if (getPrefBool(@"general.translation_notice_dismissed")) {
        return;
    }

    UIViewController *presenter = self.window.rootViewController;
    if (presenter == nil) {
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_2000", nil)
                                                                   message:localize(@"i18n_str_2001", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction *gotItAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2002", nil)
                                                          style:UIAlertActionStyleDefault
                                                        handler:nil];
    [alert addAction:gotItAction];

    UIAlertAction *dontAskAction = [UIAlertAction actionWithTitle:localize(@"i18n_str_2003", nil)
                                                            style:UIAlertActionStyleCancel
                                                          handler:^(UIAlertAction *action) {
        setPrefBool(@"general.translation_notice_dismissed", YES);
    }];
    [alert addAction:dontAskAction];

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)applyUITheme:(NSNotification *)notification {
    // 实时切换外观模式。仅修改 window.overrideUserInterfaceStyle，
    // 不触碰 PLPreferences 重置逻辑、不读写账号数据，确保切换主题不会导致账号退出。
    NSString *theme = notification.object ?: getPrefObject(@"general.ui_theme");
    if (@available(iOS 13.0, *)) {
        if ([theme isEqualToString:@"light"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
        } else if ([theme isEqualToString:@"auto"]) {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleUnspecified;
        } else {
            self.window.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        }
    }
    // Task137：新拟态退役，无需主题广播重绘——外观切换由语义色动态适配。
}

- (void)applyLanguageChange:(NSNotification *)notification {
    // 语言切换后重建根视图控制器以应用新语言
    NSString *layout = getPrefObject(@"general.ui_layout");
    UIViewController *rootVC;
    if ([layout isEqualToString:@"card"]) {
        rootVC = [[LauncherCardLayoutViewController alloc] init];
    } else {
        rootVC = [[LauncherRootViewController alloc] init];
    }
    [UIView transitionWithView:self.window duration:0.3 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self.window.rootViewController = rootVC;
    } completion:nil];
}

- (void)sceneDidDisconnect:(UIScene *)scene {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"UIThemeChanged" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AppLanguageChanged" object:nil];
    // Task191：设备方向监听摘除（配对 willConnect 的注册）。
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    // Task137：window traitCollection KVO 已随 NMTheme 退役（注册与摘除同步移除）
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Task 62（窗口模式平反）：Task 56 曾以 UIRequiresFullScreen 灭小窗来断
    // "几何失控→表面转置→画面分裂"链条，但后续取证（Task 58-61）证明真凶
    // 另有其人——EGL 查询常量对调（58）、输入 px÷2（59）、1x 钉扎模糊（60）、
    // SDL3 点/像素分裂（61），窗口模式从未是肇因，且 Info.plist 已改回
    // UIRequiresFullScreen=false（恢复 iPadOS 26 多任务/窗口化）。本重试保留作
    // 纵深防御：窗口模式下系统拥有几何，requestGeometryUpdate 可能被拒
    // （Code=101 为良性噪声，旧日志全屏下也出现）；后台崩溃链的真正修复
    // （sdl3_hook 吞噬 MINIMIZED 事件）与呈现模式无关，继续生效。
    if (@available(iOS 16.0, *)) {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UIInterfaceOrientation orient = windowScene.interfaceOrientation;
        if (UIInterfaceOrientationIsLandscape(orient)) {
            return;  // 已横屏，无需重试
        }
        UIWindowSceneGeometryPreferencesIOS *geometryPreferences = [[UIWindowSceneGeometryPreferencesIOS alloc] init];
        geometryPreferences.interfaceOrientations = UIInterfaceOrientationMaskLandscape;
        [windowScene requestGeometryUpdateWithPreferences:geometryPreferences errorHandler:^(NSError *error) {
            NSLog(@"[SceneDelegate] Task56 geometry retry on becomeActive failed: %@", error);
        }];
        NSLog(@"[SceneDelegate] Task56 geometry retry on becomeActive (orientation=%ld not landscape)",
              (long)orient);
    }
    // Task189：激活时兜底重评估一次内容旋转（willConnect 时场景 bounds 尚未
    // 最终确定、且 didUpdateCoordinateSpace 不保证必有回调的窗口场景）。
    [self ame189_applyLandscapeWindowTransform];
}

- (void)sceneWillResignActive:(UIScene *)scene {
}

- (void)sceneWillEnterForeground:(UIScene *)scene {
}

- (void)sceneDidEnterBackground:(UIScene *)scene {
    CallbackBridge_pauseGameIfNeed();
}

#pragma mark - Orientation Support (iOS 16+)

- (UIInterfaceOrientationMask)scene:(UIScene *)scene supportedInterfaceOrientationsForWindowScene:(UIWindowScene *)windowScene API_AVAILABLE(ios(16.0)) {
    return UIInterfaceOrientationMaskLandscape;
}

// ============================================================================
// Task189（强制横屏第三轮）→ Task191（方向反转根修）：窗口内容旋转兜底。
// 病历：Task187（plist 移除 Portrait）与 Task188（UIRequiresFullScreen=true）
// 双双真机无效——c3f4623 会话实测仍处窗口模式（geometry 请求 Code=101 拒绝），
// 根因 = LiveContainer 宿主流程里窗口化由宿主 app 的 plist/scene 清单决定，
// 来宾（本 app）的方向声明不被 UIKit 采纳。
// Task189 首版对竖向窗口固定 +90°（按 scene.interfaceOrientation 选向）。
// Task191 病历（dde0f82 装机，用户实测"竖屏之后再横屏，方向会一直反的"）：
//   (a) scene.interfaceOrientation 在窗口模式下恒报 Portrait（与设备实际
//       持向解耦）→ 设备倒持/换手时 ±90° 选错，内容相差 180°（"反的"）；
//   (b) 窗口几何变化之外（设备旋转但窗口 bounds 不变的自由窗口）无重评估
//       时机 → 陈旧 transform 一直挂着。
// 修法（Task191）：
//   - 旋转角度改由 UIDevice 物理方向（加速计，独立于窗口几何）决定：
//     LandscapeRight（顶部朝右）→ +90°（内容顶部转向屏幕右）；
//     LandscapeLeft（顶部朝左）→ -90°；Portrait/平放/未知 → 保持当前角；
//   - 横向窗口也参与：设备持向相对"首次观察到该横向窗口时的持向"翻转
//     180° 时，内容补转 180°（两手持 iPad 对调的场景）；
//   - 新增 UIDeviceOrientationDidChangeNotification 监听 + 开启加速计
//     采样（beginGeneratingDeviceOrientationNotifications），任何持向
//     变化立即重评估。
// 效果：全持向横屏呈现（竖窗 ±90 跟手、横窗 180° 翻转跟手）。
// 重评估时机：willConnect（首次）+ didUpdateCoordinateSpace（窗口几何
// 变化）+ orientationDidChange（设备持向变化）。
// 逃生舱：偏好 general.disable_window_rotation_shim = true 可关闭（出现
// 触控/键盘错位等极端兼容问题时无需重编译即可回退）。
// ============================================================================
- (void)ame189_applyLandscapeWindowTransform {
    if (getPrefBool(@"general.disable_window_rotation_shim")) return;   // 逃生舱
    UIWindowScene *scene = self.window.windowScene;
    if (!scene || !self.window) return;

    CGRect sb = scene.coordinateSpace.bounds;
    if (sb.size.width <= 0 || sb.size.height <= 0) return;

    UIDeviceOrientation dev = [UIDevice currentDevice].orientation;

    // 仅在"明显竖向"的窗口旋转（1.02 死区：近方形窗口旋转无收益反而扰动）
    BOOL portraitWindow = (sb.size.height > sb.size.width * 1.02);
    if (!portraitWindow) {
        // ---- 横向窗口 ----
        // Task191：记录/对比持向，设备对调（180° 翻转）时内容补转 180°。
        if (self.ame191_landscapeBaseline == UIDeviceOrientationUnknown ||
            self.ame191_landscapeBaseline == UIDeviceOrientationPortrait ||
            self.ame191_landscapeBaseline == UIDeviceOrientationPortraitUpsideDown ||
            self.ame191_landscapeBaseline == UIDeviceOrientationFaceUp ||
            self.ame191_landscapeBaseline == UIDeviceOrientationFaceDown) {
            // 基线无效（首次观察/上一窗口是竖向）：以当前持向为基线，不旋转。
            self.ame191_landscapeBaseline = dev;
            if (!CGAffineTransformIsIdentity(self.window.transform)) {
                self.window.transform = CGAffineTransformIdentity;
                self.window.frame = sb;
                NSLog(@"[SceneDelegate] Task189: window is landscape -> rotation removed (baseline=%ld)", (long)dev);
            }
            return;
        }
        BOOL flipped = ((self.ame191_landscapeBaseline == UIDeviceOrientationLandscapeRight && dev == UIDeviceOrientationLandscapeLeft) ||
                        (self.ame191_landscapeBaseline == UIDeviceOrientationLandscapeLeft && dev == UIDeviceOrientationLandscapeRight));
        CGAffineTransform want = flipped ? CGAffineTransformMakeRotation((CGFloat)M_PI) : CGAffineTransformIdentity;
        if (!CGAffineTransformEqualToTransform(self.window.transform, want)) {
            self.window.transform = want;
            self.window.frame = sb;
            NSLog(@"[SceneDelegate] Task191: landscape window flipped=%d (baseline=%ld dev=%ld) -> content %s",
                  (int)flipped, (long)self.ame191_landscapeBaseline, (long)dev, flipped ? "rotated 180deg" : "upright");
        }
        return;
    }

    // ---- 竖向窗口：±90° 由设备物理持向决定（Task191 根修）----
    // LandscapeRight（设备顶部朝右，从 Portrait 顺时针转）→ 内容顶部需指向
    // 屏幕右 → +90°（顺时针）；LandscapeLeft（顶部朝左）→ -90°。
    // Portrait/倒持/平放/未知：保持当前旋转角（不确定时不动，避免抖动）。
    CGFloat angle;
    CGAffineTransform cur = self.window.transform;
    if (dev == UIDeviceOrientationLandscapeRight) {
        angle = (CGFloat)M_PI_2;
    } else if (dev == UIDeviceOrientationLandscapeLeft) {
        angle = (CGFloat)(-M_PI_2);
    } else if (!CGAffineTransformIsIdentity(cur)) {
        return;   // 持向不明确但已在旋转：保持
    } else {
        angle = (CGFloat)M_PI_2;   // 持向不明确且未旋转：默认 +90°
    }
    CGAffineTransform rot = CGAffineTransformMakeRotation(angle);
    if (CGAffineTransformIsIdentity(self.window.transform) ||
        !CGAffineTransformEqualToTransform(self.window.transform, rot) ||
        !CGSizeEqualToSize(self.window.bounds.size, CGSizeMake(sb.size.height, sb.size.width))) {
        self.window.transform = rot;
        self.window.bounds = CGRectMake(0, 0, sb.size.height, sb.size.width);
        self.window.center = CGPointMake(sb.size.width / 2.0, sb.size.height / 2.0);
        NSLog(@"[SceneDelegate] Task191: portrait window -> content rotated %+.0fdeg by device orientation %ld (scene=%@ content=%@)",
              (float)(angle * 180.0 / M_PI), (long)dev,
              NSStringFromCGRect(sb), NSStringFromCGRect(self.window.bounds));
    }
    // 竖向窗口期间基线失效（回到横向窗口时会重新取基线）
    self.ame191_landscapeBaseline = UIDeviceOrientationUnknown;
}

- (void)scene:(UIScene *)scene didUpdateCoordinateSpace:(id<UICoordinateSpace>)coordinateSpace
                         interfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
                                        traitCollection:(UITraitCollection *)traitCollection {
    // Task189：窗口尺寸/方向变化（窗口模式下的拖拽调整、设备旋转）后
    // 重评估内容旋转。轻微去抖：下一帧执行，避开变更回调内的布局重入。
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf ame189_applyLandscapeWindowTransform];
    });
}

// Task191：设备持向变化（窗口几何可能不变）也触发重评估——±90°/180°
// 跟手的唯一时机。去抖同上。
- (void)ame191_deviceOrientationDidChange:(NSNotification *)notification {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf ame189_applyLandscapeWindowTransform];
    });
}

@end
