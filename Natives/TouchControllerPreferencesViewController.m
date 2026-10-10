//
//  TouchControllerPreferencesViewController.m
//  Angel Aura Amethyst
//
//  TouchController 设置页面实现
//

#import "TouchControllerPreferencesViewController.h"
#import "AmeNativeMenu.h"       // ★ Task240：菜单全面系统原生 UIMenu 化
#import "LauncherPreferences.h"
#import "PLPreferences.h"
#import "BackgroundManager.h"
#import "config.h"
#import "utils.h"

// 定义通信方式枚举
typedef NS_ENUM(NSInteger, TouchControllerCommMode) {
    TouchControllerCommModeDisabled = 0,
    TouchControllerCommModeUDP = 1,
    TouchControllerCommModeStaticLib = 2
};

@interface TouchControllerPreferencesViewController ()

@end

@implementation TouchControllerPreferencesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"preference.touchcontroller.title", nil);

    // 添加关闭按钮
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 虽然父类 PLPrefTableViewController 的 viewDidLoad 已调用 makeViewControllerTransparent，
    // 但此处再次调用以确保本子类的背景设置在所有初始化完成后仍然正确。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // Task223：监听 TouchController 设置变化广播（组件安装完成时立即落地三项
    // 全局键后发出）——已打开的本页即时刷新显示，不再需要重启启动器。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame223_reloadOnTouchSettingsChanged)
                                                 name:@"TouchControllerSettingsChanged"
                                               object:nil];
}

/// Task223：TouchControllerSettingsChanged 广播到达时重载表格（三项全局键
/// 已被外部落地，重读即显示真实状态）。
- (void)ame223_reloadOnTouchSettingsChanged {
    [self.tableView reloadData];
    NSLog(@"[TouchController] Task223 settings page reloaded (TouchControllerSettingsChanged)");
}

- (void)initViewCreation {
    __weak typeof(self) weakSelf = self;

    // 确保所有选项都可见
    self.prefSectionsVisible = YES;

    // 设置偏好获取和保存块
    self.getPreference = ^id(NSString *section, NSString *key){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        return getPrefObject(keyFull);
    };
    self.setPreference = ^(NSString *section, NSString *key, id value){
        NSString *keyFull = [NSString stringWithFormat:@"%@.%@", section, key];
        setPrefObject(keyFull, value);
    };

    // 调用父类初始化
    [super initViewCreation];

    // 通信方式选择
    self.typeChildPane = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.text = item[@"title"];
        NSInteger mode = [weakSelf.getPreference(section, key) integerValue];
        switch (mode) {
            case TouchControllerCommModeUDP:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.mode.udp", nil) ?: @"UDP Protocol";
                break;
            case TouchControllerCommModeStaticLib:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.mode.staticlib", nil) ?: @"Static Library";
                break;
            default:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.mode.disabled", nil) ?: @"Disabled";
                break;
        }
    };

    // 按钮类型
    self.typeButton = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.selectionStyle = UITableViewCellSelectionStyleGray;
        cell.textLabel.text = item[@"title"];
        cell.textLabel.textColor = weakSelf.view.tintColor;
    };

    // 滑块类型（震动强度）
    self.typeSlider = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.text = item[@"title"];

        // 创建滑块
        UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
        NSInteger value = [weakSelf.getPreference(section, key) integerValue];
        if (value < 1) value = 1;
        if (value > 3) value = 3;
        slider.value = value;
        slider.minimumValue = [item[@"min"] floatValue];
        slider.maximumValue = [item[@"max"] floatValue];
        slider.continuous = YES;

        // 设置详细文本
        switch (value) {
            case 1:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.light", nil) ?: @"Light";
                break;
            case 2:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
            case 3:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.heavy", nil) ?: @"Heavy";
                break;
            default:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
        }

        // 滑块变化处理
        [slider addTarget:weakSelf action:@selector(sliderValueChanged:) forControlEvents:UIControlEventValueChanged];

        // 将滑块添加到附件视图
        cell.accessoryView = slider;
    };

    // 开关类型
    self.typeSwitch = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item) {
        UISwitch *view = [[UISwitch alloc] init];
        NSArray *customSwitchValue = item[@"customSwitchValue"];
        if (customSwitchValue == nil) {
            [view setOn:[weakSelf.getPreference(section, key) boolValue] animated:NO];
        } else {
            [view setOn:[weakSelf.getPreference(section, key) isEqualToString:customSwitchValue[1]] animated:NO];
        }
        [view addTarget:weakSelf action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = view;
    };

    // 设置偏好设置部分
    self.prefSections = @[@"control"];

    // 配置设置内容
    self.prefContents = @[
        @[
            @{@"key": @"mod_touch_mode",
              @"icon": @"antenna.radiowaves.left.and.right",
              @"hasDetail": @YES,
              @"type": self.typeChildPane,
              @"canDismissWithSwipe": @NO,
              @"title": localize(@"preference.touchcontroller.mode.title", nil) ?: @"Communication Mode"
            },
            @{@"key": @"mod_touch_vibrate_enable",
              @"icon": @"waveform.path",
              @"type": self.typeSwitch,
              @"canDismissWithSwipe": @NO,
              @"title": localize(@"preference.touchcontroller.vibrate.enable", nil) ?: @"Enable Vibration"
            },
            @{@"key": @"mod_touch_vibrate_intensity",
              @"icon": @"speaker.wave.2",
              @"type": self.typeSlider,
              @"hasDetail": @YES,
              @"canDismissWithSwipe": @NO,
              @"min": @1,
              @"max": @3,
              @"step": @1,
              @"title": localize(@"preference.touchcontroller.vibrate.intensity", nil) ?: @"Vibration Intensity"
            },
            @{@"key": @"mod_touch_moveview_enable",
              @"icon": @"arrow.triangle.2.circlepath",
              @"type": self.typeSwitch,
              @"canDismissWithSwipe": @NO,
              @"title": localize(@"preference.touchcontroller.moveview.enable", nil) ?: @"Enable Move View"
            },
            // Task 134：屏蔽控件——把整个游戏界面换成没有任何屏幕控件的
            // 样式（写入空布局预设到 <游戏目录>/config/touchcontroller/，
            // mod 下次启动读取；触屏手势/震动/文本输入等全部功能保留）
            @{@"key": @"mod_touch_hide_controls",
              @"icon": @"eye.slash.circle",
              @"type": self.typeSwitch,
              @"canDismissWithSwipe": @NO,
              @"title": localize(@"preference.touchcontroller.hide_controls", nil) ?: @"Hide All Controls"
            },
            @{@"key": @"mod_touch_about",
              @"icon": @"info.circle",
              @"type": self.typeButton,
              @"canDismissWithSwipe": @NO,
              @"action": ^void(){
                  [weakSelf showInfoAlert];
              },
              @"title": localize(@"preference.touchcontroller.about", nil) ?: @"About TouchController"
            }
        ]
    ];
}

// 滑块值变化处理
- (void)sliderValueChanged:(UISlider *)slider {
    NSInteger value = (NSInteger)round(slider.value);
    self.setPreference(@"control", @"mod_touch_vibrate_intensity", @(value));

    // 更新详细文本
    UITableViewCell *cell = (UITableViewCell *)slider.superview;
    while (cell && ![cell isKindOfClass:[UITableViewCell class]]) {
        cell = (UITableViewCell *)cell.superview;
    }

    if (cell) {
        switch (value) {
            case 1:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.light", nil) ?: @"Light";
                break;
            case 2:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
            case 3:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.heavy", nil) ?: @"Heavy";
                break;
            default:
                cell.detailTextLabel.text = localize(@"preference.touchcontroller.vibrate.intensity.medium", nil) ?: @"Medium";
                break;
        }
    }
}

- (void)updateTouchControllerSetting:(TouchControllerCommMode)mode {
    switch (mode) {
        case TouchControllerCommModeDisabled:
            // 禁用 TouchController
            self.setPreference(@"control", @"mod_touch_enable", @NO);
            self.setPreference(@"control", @"mod_touch_mode", @0);
            // ★ Task223（用户报“手动关闭后又被强制开启”）：全局页手动关闭 =
            // 明确的用户意图——落哨兵，启动链 ame172 的自动配置见到哨兵
            // 即不再覆盖（否则 profile 开关仍 YES，下次启动又把全局顶回 ON）。
            setPrefBool(@"control.mod_touch_user_off", YES);
            [self removeUDPEnvironmentVariable];
            NSLog(@"[TouchController] Disabled (Task223: user-off sentinel set, launch-time auto-config will not override)");
            break;

        case TouchControllerCommModeUDP:
            // 启用 UDP 模式
            self.setPreference(@"control", @"mod_touch_enable", @YES);
            self.setPreference(@"control", @"mod_touch_mode", @1);
            // Task223：手动开启 = 撤哨兵（用户重新接管，自动配置恢复默认行为）。
            setPrefBool(@"control.mod_touch_user_off", NO);
            [self setUDPEnvironmentVariable];
            NSLog(@"[TouchController] Enabled with UDP mode");
            break;

        case TouchControllerCommModeStaticLib:
            // 启用静态库模式
            self.setPreference(@"control", @"mod_touch_enable", @YES);
            self.setPreference(@"control", @"mod_touch_mode", @2);
            // Task223：同上，撤哨兵。
            setPrefBool(@"control.mod_touch_user_off", NO);
            [self removeUDPEnvironmentVariable];
            NSLog(@"[TouchController] Enabled with Static Library mode");
            break;
    }

    // Task224：广播全局键变化——版本设置页等已开页面即时刷新"有效状态"
    //（旧代码只有自动配置侧发广播，用户手动改模式不发 → 版本设置仍显示
    // 过期的 "UDP 协议"）。观察侧见 ProfileSettingsViewController
    // ame224_touchControllerSettingsChanged。
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TouchControllerSettingsChanged" object:nil];
}

- (void)setUDPEnvironmentVariable {
    NSString *currentEnv = getPrefObject(@"java.env_variables");
    if ([currentEnv isKindOfClass:[NSString class]]) {
        if (![currentEnv containsString:@"TOUCH_CONTROLLER_PROXY=12450"]) {
            NSString *newEnv = [currentEnv stringByAppendingString:@" TOUCH_CONTROLLER_PROXY=12450"];
            setPrefObject(@"java.env_variables", newEnv);
        }
    } else {
        setPrefObject(@"java.env_variables", @"TOUCH_CONTROLLER_PROXY=12450");
    }
}

- (void)removeUDPEnvironmentVariable {
    NSString *currentEnv = getPrefObject(@"java.env_variables");
    if ([currentEnv isKindOfClass:[NSString class]]) {
        NSString *newEnv = [currentEnv stringByReplacingOccurrencesOfString:@" TOUCH_CONTROLLER_PROXY=12450" withString:@""];
        setPrefObject(@"java.env_variables", newEnv);
    }
}

- (void)showModeSelectionAlert {
    // ★ Task240：换装系统原生 UIMenu（旧 actionSheet 退役；旧实现给
    // UIAlertAction 发私有 KVC "checked"，顺带清除——✓ 改为标题前缀）。
    NSMutableArray<NSDictionary *> *ame240_items = [NSMutableArray array];

    // 获取当前模式
    NSInteger currentMode = [self.getPreference(@"control", @"mod_touch_mode") integerValue];
    if (currentMode == 0) currentMode = TouchControllerCommModeDisabled;
    if (![self.getPreference(@"control", @"mod_touch_enable") boolValue]) currentMode = TouchControllerCommModeDisabled;

    // 禁用选项
    [ame240_items addObject:@{
        @"title": [(currentMode == TouchControllerCommModeDisabled ? @"✓ " : @"")
            stringByAppendingString:(localize(@"preference.touchcontroller.mode.disabled", nil) ?: @"Disabled")],
        @"destructive": @YES,
        @"handler": ^{
            [self updateTouchControllerSetting:TouchControllerCommModeDisabled];
            [self.tableView reloadData];
        },
    }];

    // UDP 模式选项
    [ame240_items addObject:@{
        @"title": [(currentMode == TouchControllerCommModeUDP ? @"✓ " : @"")
            stringByAppendingString:(localize(@"preference.touchcontroller.mode.udp", nil) ?: @"UDP Protocol")],
        @"handler": ^{
            [self updateTouchControllerSetting:TouchControllerCommModeUDP];
            [self.tableView reloadData];
            [self showModeDescriptionAlert:TouchControllerCommModeUDP];
        },
    }];

    // 静态库模式选项
    [ame240_items addObject:@{
        @"title": [(currentMode == TouchControllerCommModeStaticLib ? @"✓ " : @"")
            stringByAppendingString:(localize(@"preference.touchcontroller.mode.staticlib", nil) ?: @"Static Library")],
        @"handler": ^{
            [self updateTouchControllerSetting:TouchControllerCommModeStaticLib];
            [self.tableView reloadData];
            [self showModeDescriptionAlert:TouchControllerCommModeStaticLib];
        },
    }];

    [AmeNativeMenu ame240_presentMenuWithTitle:localize(@"preference.touchcontroller.select_mode.title", nil) ?: @"Select Communication Mode"
                                     dictItems:ame240_items
                                    sourceView:self.view];
}

- (void)showModeDescriptionAlert:(TouchControllerCommMode)mode {
    NSString *title, *message;

    switch (mode) {
        case TouchControllerCommModeUDP:
            title = localize(@"preference.touchcontroller.udp.title", nil) ?: @"UDP Protocol Mode";
            message = localize(@"preference.touchcontroller.udp.message", nil) ?: @"TouchController will communicate via UDP port 12450. This mode is compatible with most servers and provides stable network communication.";
            break;

        case TouchControllerCommModeStaticLib:
            title = localize(@"preference.touchcontroller.staticlib.title", nil) ?: @"Static Library Mode";
            message = localize(@"preference.touchcontroller.staticlib.message", nil) ?: @"TouchController will use native static library for high-performance local communication via Unix Domain Socket. This mode provides better performance but requires the static library to be linked.";
            break;

        default:
            return;
    }

    UIAlertController *infoAlert = [UIAlertController alertControllerWithTitle:title
                                                                         message:message
                                                                  preferredStyle:UIAlertControllerStyleAlert];

    [infoAlert addAction:[UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.ok", nil) ?: @"OK"
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];

    [self presentViewController:infoAlert animated:YES completion:nil];
}

- (void)showInfoAlert {
    UIAlertController *infoAlert = [UIAlertController alertControllerWithTitle:localize(@"preference.touchcontroller.about.title", nil) ?: @"About TouchController"
                                                                         message:localize(@"preference.touchcontroller.about.message", nil) ?: @"TouchController is a Minecraft mod that adds touch controls to Java Edition. This launcher supports two communication modes:\n\n• UDP Protocol: Network-based communication\n• Static Library: High-performance local communication\n\nVisit GitHub for more information."
                                                                  preferredStyle:UIAlertControllerStyleAlert];

    [infoAlert addAction:[UIAlertAction actionWithTitle:localize(@"preference.touchcontroller.ok", nil) ?: @"OK"
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];

    [infoAlert addAction:[UIAlertAction actionWithTitle:@"GitHub"
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/TouchController/TouchController"]
                                            options:@{}
                                  completionHandler:nil];
    }]];

    [self presentViewController:infoAlert animated:YES completion:nil];
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *key = self.prefContents[indexPath.section][indexPath.row][@"key"];
    if ([key isEqualToString:@"mod_touch_mode"]) {
        [self showModeSelectionAlert];
    } else if ([key isEqualToString:@"mod_touch_about"]) {
        [self showInfoAlert];
    }
}

#pragma mark - Close Button Action

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并手动清空 tableView 背景与 backgroundView，确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end