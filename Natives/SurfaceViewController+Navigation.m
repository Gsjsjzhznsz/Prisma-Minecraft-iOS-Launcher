#import "CustomControlsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "customcontrols/CustomControlsUtils.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "ScreenUtils.h"
#import "NMToast.h"
// ★ [MP-RESTORE] Task222：ZeroTier/Terracotta 联机恢复（上游同日恢复）
#import "MultiplayerViewController.h"
#import "MultiplayerManager.h"
#import "TerracottaViewController.h"
#import "TerracottaBridge.h"  // Task222 CI fix: isAvailable 探测（run 37300697020 报 undeclared identifier）
#import <objc/runtime.h>

// 暴露 class extension 中的私有属性，供 category 使用
@interface SurfaceViewController()
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) BOOL toggleHidden;
- (void)updateControlHiddenState:(BOOL)hide;
// Task64-fix：loadCustomControls 实现在 SurfaceViewController.m 的类扩展里，
// 对本 category 编译单元不可见（CI 实锤：no visible @interface declares the
// selector 'loadCustomControls'）。此处声明补上可见性，签名与实现一致
// （无参、void 返回，SurfaceViewController.m:1744）。
- (void)loadCustomControls;
@end

// category 不能存储 ivar，用 associated object 实现 menuDimView
static const void *kMenuDimViewKey = &kMenuDimViewKey;

@interface SurfaceViewController(Navigation)
// FCL 风格菜单的背景遮罩（半透明黑色，点击关闭菜单）
@property(nonatomic) UIView *menuDimView;
@end

@implementation SurfaceViewController(Navigation)

- (void)setMenuDimView:(UIView *)menuDimView {
    objc_setAssociatedObject(self, kMenuDimViewKey, menuDimView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIView *)menuDimView {
    return objc_getAssociatedObject(self, kMenuDimViewKey);
}

- (void)initCategory_Navigation {
    // FCL 安卓风格：菜单从底部弹出，游戏画面不缩小
    // 参照 FCL GameMenu.java / GameMenuView.kt 的底部弹出菜单样式
    self.menuArray = @[
        @"game.menu.force_close",          // 强制关闭
        @"game.menu.log_output",            // 日志输出
        @"game.menu.custom_controls",       // 按键布局编辑
        @"game.menu.restore_default_controls", // Task 64: 恢复默认控件（重建出厂布局）
        @"game.menu.multiplayer",           // 联机（陶瓦联机 Terracotta，右上角可切换 ZeroTier）
        @"game.menu.toggle_stats",          // FPS/内存显示开关
        @"game.menu.toggle_controls",       // 隐藏/显示控制按钮
        @"game.menu.toggle_virtual_mouse",  // 虚拟鼠标开关
        @"game.menu.toggle_keyboard",       // 游戏内键盘
        @"game.menu.resolution",            // 分辨率调整
        @"Settings"                         // 设置
    ];

    // FCL 风格：菜单从底部弹出，宽度为屏幕宽度的 70%（居中），最大高度为屏幕高度的 60%
    CGFloat screenWidth = [ScreenUtils screenSize].width;
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 16;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    self.menuView = [[UITableView alloc] initWithFrame:CGRectMake(
        (screenWidth - menuWidth) / 2.0,
        screenHeight,  // 初始放在屏幕底部外（动画时上滑）
        menuWidth,
        menuHeight
    ) style:UITableViewStylePlain];

    self.menuView.dataSource = self;
    self.menuView.delegate = self;
    self.menuView.hidden = YES;
    self.menuView.layer.cornerRadius = 16;
    self.menuView.clipsToBounds = YES;
    self.menuView.scrollEnabled = YES;
    self.menuView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    // FCL 风格：半透明深色背景
    self.menuView.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull traitCollection) {
        return [UIColor colorWithRed:28.0/255.0 green:28.0/255.0 blue:30.0/255.0 alpha:0.95];
    }];
    // 添加阴影
    self.menuView.layer.shadowColor = [UIColor blackColor].CGColor;
    self.menuView.layer.shadowOffset = CGSizeMake(0, -2);
    self.menuView.layer.shadowRadius = 12;
    self.menuView.layer.shadowOpacity = 0.4;
    [self.view addSubview:self.menuView];

    // FCL 风格：半透明背景遮罩（点击关闭菜单）
    self.menuDimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.menuDimView.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.4];
    self.menuDimView.alpha = 0;
    self.menuDimView.hidden = YES;
    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissMenu)];
    dimTap.cancelsTouchesInView = YES;
    [self.menuDimView addGestureRecognizer:dimTap];
    [self.view addSubview:self.menuDimView];
    // 确保菜单在遮罩之上
    [self.view bringSubviewToFront:self.menuView];

    // FCL/ZL2 风格悬浮按钮 + FPS/内存显示
    GameMenuOverlayView *overlay = [[GameMenuOverlayView alloc] initWithParentView:self.view];
    __weak typeof(self) weakSelf = self;
    overlay.onMenuButtonTapped = ^{
        [weakSelf toggleMenu];
    };
    self.gameMenuOverlay = overlay;
}

/// 切换菜单显示状态（悬浮按钮点击触发）
- (void)toggleMenu {
    if (self.menuView.hidden) {
        [self showMenu];
    } else {
        [self dismissMenu];
    }
}

/// FCL 风格：从底部弹出菜单（游戏画面不缩小）
- (void)showMenu {
    self.menuView.hidden = NO;
    self.menuDimView.hidden = NO;

    // 准备动画初始状态：菜单在屏幕底部外
    CGFloat screenHeight = [ScreenUtils screenSize].height;
    CGFloat menuHeight = self.menuView.frame.size.height;
    self.menuView.transform = CGAffineTransformIdentity;
    self.menuView.frame = CGRectMake(
        self.menuView.frame.origin.x,
        screenHeight,  // 屏幕底部外
        self.menuView.frame.size.width,
        menuHeight
    );

    // 计算目标位置：底部弹出，留出安全区域
    CGFloat safeBottom = [ScreenUtils safeAreaBottom];
    CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;

    [UIView animateWithDuration:0.3
                          delay:0
         usingSpringWithDamping:0.85
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        // 菜单上滑到目标位置
        self.menuView.frame = CGRectMake(
            self.menuView.frame.origin.x,
            targetY,
            self.menuView.frame.size.width,
            menuHeight
        );
        // 背景遮罩淡入
        self.menuDimView.alpha = 1.0;
    } completion:^(BOOL finished) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

/// FCL 风格：菜单下滑消失（游戏画面不缩小）
- (void)dismissMenu {
    CGFloat screenHeight = [ScreenUtils screenSize].height;

    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseIn
                     animations:^{
        // 菜单下滑到屏幕底部外
        self.menuView.frame = CGRectMake(
            self.menuView.frame.origin.x,
            screenHeight,
            self.menuView.frame.size.width,
            self.menuView.frame.size.height
        );
        // 背景遮罩淡出
        self.menuDimView.alpha = 0.0;
    } completion:^(BOOL finished) {
        self.menuView.hidden = YES;
        self.menuDimView.hidden = YES;
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsStatusBarAppearanceUpdate];
    }];
}

- (void)setupCategory_Navigation {
    // FCL 风格：完全删除原来的右侧滑动调出菜单的方式
    // 不再注册 UIScreenEdgePanGestureRecognizer，菜单通过悬浮按钮触发
    // 保留空方法体，因为 SurfaceViewController.m 中通过 performSelector 调用
}

- (void)actionForceClose {
    UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
        message:localize(@"game.menu.confirm.force_close", nil)
        preferredStyle:UIAlertControllerStyleAlert];

    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:cancelAction];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * action) {
        // ★ [MP-RESTORE] Task222 联机恢复：强退前清理联机资源
        //   （ZeroTier 节点 / 陶瓦会话 / SOCKS5 / 端口转发）
        @try {
            [[MultiplayerManager sharedManager] stopAllMultiplayerServices];
            NSLog(@"[ForceClose] Multiplayer resources cleaned up");
        } @catch (NSException *e) {
            NSLog(@"[ForceClose] Exception while cleaning up multiplayer resources: %@", e);
        }

        // FCL 风格：直接退出，不再做缩小动画
        if (fatalExitGroup == nil) {
            exit(0);
        } else {
            dispatch_group_leave(fatalExitGroup);
        }
    }];
    [alert addAction:okAction];

    [self presentViewController:alert animated:YES completion:nil];
}

/// Task 64（恢复默认控件）：强制重建出厂布局并热重载。
/// 用户场景：旧布局在历史崩溃中写坏 / App 升级后模板换代，导致进游戏控件
/// 全部无反应。此入口删除 default.json 与 custom.json 后从出厂来源重建，
/// 并把激活布局指针复位为 default.json，最后热重载控件（无需重启游戏）。
- (void)actionRestoreDefaultControls {
    [self dismissMenu];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"game.menu.restore_default_controls", nil)
                          message:localize(@"game.menu.restore_default_controls.confirm", nil)
                   preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *error = restoreDefaultCustomControl();
        if (error) {
            NSLog(@"[CustomControls] Task64 restore failed: %@", error);
            showDialog(localize(@"Error", nil), error);
            return;
        }
        // 热重载：与 actionOpenCustomControls 关闭编辑器后的重载路径一致
        // （removeAllButtons + loadCustomControls 会重新挂接 executebtn_* 触摸目标）
        [self.ctrlView removeAllButtons];
        [self loadCustomControls];
        NSLog(@"[CustomControls] Task64 in-game restore applied, controls reloaded");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenCustomControls {
    [self dismissMenu];
    [self.ctrlView removeAllButtons];
    CustomControlsViewController *vc = [[CustomControlsViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name){
        if (PLProfiles.current.selectedProfile[@"defaultTouchCtrl"]) {
            // Save default to current profile
            PLProfiles.current.selectedProfile[@"defaultTouchCtrl"] = name;
        } else {
            // Save default to preferences
            setPrefObject(@"control.default_ctrl", name);
        }
    };
    vc.getDefaultCtrl = ^{
        return [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    };
    [self presentViewController:vc animated:NO completion:nil];
}

- (void)actionOpenPreferences {
    [self dismissMenu];
    LauncherPreferencesViewController *vc = [[LauncherPreferencesViewController alloc] init];
    [self presentViewController:vc animated:YES completion:nil];
}

/// 游戏内打开联机界面（陶瓦联机，与 HMCL/FCL/ZL2 互通）
///
/// 对标 FCL 流程：启动游戏后通过悬浮球菜单进入联机界面，
/// 选择当房主（创建世界→开放局域网→输入端口→生成邀请码）
/// 或当房客（输入邀请码→加入网络→MC 多人游戏直连 127.0.0.1:25565）。
- (void)actionOpenMultiplayer {
    // ★ [MP-RESTORE] Task222 联机恢复：游戏内 modal 呈现（TVC 的 modal 分支
    //   自带系统 Close 按钮，dismiss 即回游戏；与上游 FCL 流程一致）。
    [self dismissMenu];
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
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

/// FCL 风格：隐藏/显示控制按钮（对应 FCL hide_all 开关）
- (void)actionToggleControls {
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

/// FCL 风格：切换虚拟鼠标（对应 FCL 鼠标分组 / ZL2 ControlMouse）
- (void)actionToggleVirtualMouse {
    if (!isGrabbing) {
        virtualMouseEnabled = !virtualMouseEnabled;
        self.mousePointerView.hidden = !virtualMouseEnabled;
        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
}

/// FCL 风格：打开/关闭游戏内键盘（对应 FCL open_quick_input / ZL2 input_method）
- (void)actionToggleKeyboard {
    if (self.inputTextField.isFirstResponder) {
        [self.inputTextField resignFirstResponder];
        self.inputTextField.alpha = 1.0f;
    } else {
        [self.inputTextField becomeFirstResponder];
        self.inputTextField.text = @" ";
    }
}

/// FCL/ZL2 风格：调整游戏分辨率（对应 FCL window_scale / ZL2 resolutionRatio）
- (void)actionAdjustResolution {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"game.menu.resolution", nil)
                                                                   message:localize(@"game.menu.resolution.message", nil)
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray *options = @[@25, @50, @75, @100, @125, @150];
    // Task186（分辨率调节失效根修）：Task159 实例化后生效链（updateSavedResolution）
    // 读 profile 键 resolution（[PLProfiles resolveKeyForCurrentProfile:]，
    // profile 固化显式值后全局 video.resolution 即被无视——版本设置页首次保存
    // 即固化），而本菜单旧代码读写全局键 → 游戏内调节永远无效、✓ 标记与实际
    // 生效值脱节。修法：读写全部对齐 profile 层（与生效链同源）。
    NSInteger currentValue = [PLProfiles resolveKeyForCurrentProfile:@"resolution"].integerValue;
    if (currentValue <= 0) currentValue = 100;
    for (NSNumber *value in options) {
        NSString *title = [NSString stringWithFormat:@"%ld%%", (long)value.intValue];
        if (value.intValue == currentValue) {
            title = [NSString stringWithFormat:@"✓ %@", title];
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // Task186：写当前实例的 resolution 键（setServerIp 同款 mutableCopy
            // 写回模式，updateSavedResolution 立即可见——PLProfiles.current 同一
            // 内存对象，无需重建）；
            NSString *ame186_profileName = PLProfiles.current.selectedProfileName;
            if (ame186_profileName.length > 0) {
                NSMutableDictionary *ame186_profile = [PLProfiles.current.profiles[ame186_profileName] mutableCopy];
                if (!ame186_profile) ame186_profile = [NSMutableDictionary dictionary];
                ame186_profile[@"resolution"] = [NSString stringWithFormat:@"%ld", (long)value.intValue];
                PLProfiles.current.profiles[ame186_profileName] = ame186_profile;
                [PLProfiles.current save];
                NSLog(@"[Task186] in-game resolution: profile '%@' resolution -> %ld%% (was %ld%%)",
                      ame186_profileName, (long)value.intValue, (long)currentValue);
            }
            // 兼容镜像：JavaGUI（executeJar 窗口，无实例上下文）4 处仍读全局
            // video.resolution（Task159 注释明确的保留设计），保持旧全局写入
            // 不回归其行为。
            setPrefFloat(@"video.resolution", value.floatValue);
            // Task187（分辨率触摸错位根修）：不再【立即】调用 updateSavedResolution。
            // 病历（8cca75a 用户反馈"分辨率调节触摸输入不正常"）：updateSavedResolution
            // 是全量几何重算——运行中调用会同步改写 surface/drawableSize/contentsScale
            // 与 windowWidth/Height 全局，但 MC 的窗口信念（launchJVM 启动时告知的
            // 窗口尺寸）在本进程内【不可变】：
            //   1) EGL 表面被缩到新尺寸而 MC 仍按旧尺寸渲染（拉伸/裁切）；
            //   2) sendTouchPoint 的 Task175 公式按新 resolutionScale 换算触点，
            //      MC 仍按旧窗口信念归一化 → 触点整体偏移 1/旧比例（实测病灶）。
            // 修法：菜单只写偏好（键值已即时落盘），下一次 launchJVM 周期
            // updateSavedResolution 自然以新值建表面/窗口/输入三口径一致的
            // 会话。当前会话保持既有几何不动（触摸与渲染完全自洽）。
            if (value.intValue != currentValue) {
                [NMToast showMessage:localize(@"game.menu.resolution.next_launch", nil)];
            }
            NSLog(@"[Task187] in-game resolution saved %ld%% -- geometry applies next launch (in-session resize would desync MC window belief + touch mapping)",
                  (long)value.intValue);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];

    // iPad 适配
    alert.popoverPresentationController.sourceView = self.view;
    alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);

    [self presentViewController:alert animated:YES completion:nil];
}

- (void)actionOpenNavigationMenu {
    // FCL 风格：游戏内自定义按键的 SPECIALBTN_MENU 也触发底部弹出菜单
    [self toggleMenu];
}

- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    if (!self.menuView.hidden) {
        return 0;
    }
    return UIRectEdgeBottom | UIRectEdgeRight;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return self.menuView.hidden &&
        getPrefBool(@"debug.debug_hide_home_indicator");
}

- (BOOL)prefersStatusBarHidden {
    return self.menuView.hidden;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.menuArray.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"FCLMenuCell"];

    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"FCLMenuCell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        // 修复：游戏内菜单字体不应使用 sp 缩放，使用固定 16pt 保证所有设备一致
        // 原 [ScreenUtils sp:16] 在 iPad 上会放大到 32pt 导致菜单字体过大
        cell.textLabel.font = [UIFont systemFontOfSize:16];
        cell.textLabel.textAlignment = NSTextAlignmentLeft;
        // FCL 风格：左侧留出图标空间，cell 高度 48
        cell.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        // 选中状态背景
        UIView *selectedBg = [[UIView alloc] init];
        selectedBg.backgroundColor = [UIColor colorWithRed:80.0/255.0 green:80.0/255.0 blue:90.0/255.0 alpha:0.6];
        cell.selectedBackgroundView = selectedBg;
    }

    cell.textLabel.text = localize(self.menuArray[indexPath.row], nil);
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 修复：行高使用固定值 48pt，不随屏幕缩放
    // 原 [ScreenUtils sp:48] 在 iPad 上会放大到 96pt 导致菜单项过高
    return 48;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    [self didSelectMenuItem:indexPath.row];
}

- (void)didSelectMenuItem:(int)item {
    switch (item) {
        case 0: // 强制关闭
            [self actionForceClose];
            break;
        case 1: // 日志输出
            [self.logOutputView actionToggleLogOutput];
            break;
        case 2: // 按键布局编辑
            [self actionOpenCustomControls];
            break;
        case 3: // Task 64: 恢复默认控件
            [self actionRestoreDefaultControls];
            break;
        case 4: // 联机（陶瓦联机 Terracotta，与 HMCL/FCL/ZL2 互通；右上角可切换到 ZeroTier）
            [self actionOpenMultiplayer];
            break;
        case 5: // FPS/内存显示开关
            if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
                [(GameMenuOverlayView *)self.gameMenuOverlay toggleStatsLabel];
            }
            break;
        case 6: // 隐藏/显示控制按钮
            [self actionToggleControls];
            break;
        case 7: // 虚拟鼠标开关
            [self actionToggleVirtualMouse];
            break;
        case 8: // 游戏内键盘
            [self actionToggleKeyboard];
            break;
        case 9: // 分辨率调整
            [self actionAdjustResolution];
            break;
        case 10: // 设置
            [self actionOpenPreferences];
            break;
    }
}

- (void)viewWillTransitionToSize_Navigation:(CGRect)frame {
    // FCL 风格：菜单从底部弹出，旋转时重新计算 frame
    CGFloat screenWidth = frame.size.width;
    CGFloat screenHeight = frame.size.height;
    CGFloat menuWidth = MIN(screenWidth * 0.7, 400);
    CGFloat menuMaxHeight = screenHeight * 0.6;
    CGFloat menuEstimatedHeight = self.menuArray.count * 48 + 16;
    CGFloat menuHeight = MIN(menuEstimatedHeight, menuMaxHeight);

    if (!self.menuView.hidden) {
        // 菜单可见时，更新到新的目标位置
        CGFloat safeBottom = [ScreenUtils safeAreaBottom];
        CGFloat targetY = screenHeight - menuHeight - safeBottom - 16;
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            targetY,
            menuWidth,
            menuHeight
        );
    } else {
        // 菜单不可见时，保持在屏幕底部外
        self.menuView.frame = CGRectMake(
            (screenWidth - menuWidth) / 2.0,
            screenHeight,
            menuWidth,
            menuHeight
        );
    }
    // 更新遮罩 frame
    self.menuDimView.frame = CGRectMake(0, 0, screenWidth, screenHeight);
}

@end
