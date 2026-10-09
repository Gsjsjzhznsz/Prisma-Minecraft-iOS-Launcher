#import "ControlDrawer.h"
#import "ControlJoystick.h"
#import "ControlSubButton.h"
#import "CustomControlsUtils.h"
#import "../LauncherPreferences.h"
#import "../PLProfiles.h"
#import "../ios_uikit_bridge.h"
#include "../glfw_keycodes.h"
#include "../utils.h"

NSMutableDictionary* createButton(NSString* name, int* keycodes, NSString* dynamicX, NSString* dynamicY, CGFloat width, CGFloat height) {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"name"] = name;
    dict[@"keycodes"] = [[NSMutableArray alloc] initWithCapacity:4];
    for (int i = 0; i < 4; i++) {
        [dict[@"keycodes"] addObject:@(keycodes[i])];
    }
    dict[@"dynamicX"] = dynamicX;
    dict[@"dynamicY"] = dynamicY;
    dict[@"width"] = @(width);
    dict[@"height"] = @(height);
    dict[@"opacity"] = @(1);
    dict[@"cornerRadius"] = @(0);
    dict[@"bgColor"] = @(0x4d000000);
    dict[@"displayInGame"] = @YES;
    dict[@"displayInMenu"] = @YES;
    return dict;
}

NSMutableDictionary* createGamepadButton(NSString* name, int gamepad_button, int keycode) {
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"name"] = name;
    dict[@"gamepad_button"] = @(gamepad_button);
    dict[@"keycode"] = @(keycode);
    return dict;
}

UIColor* convertARGB2UIColor(int argb) {
    return [UIColor 
        colorWithRed:((argb>>16)&0xFF)/255.0
               green:((argb>>8)&0xFF)/255.0
                blue:((argb>>0)&0xFF)/255.0
               alpha:((argb>>24)&0xFF)/255.0];
}

int convertUIColor2ARGB(UIColor* color) {
    const CGFloat *rgba = CGColorGetComponents(color.CGColor);
    int a = (int) (rgba[3] * 255);
    int r = (int) (rgba[0] * 255);
    int g = (int) (rgba[1] * 255);
    int b = (int) (rgba[2] * 255);
    return (a << 24) | (r << 16) | (g << 8) | (b << 0);
}

int convertUIColor2RGB(UIColor* color) {
    const CGFloat *rgb = CGColorGetComponents(color.CGColor);
    int r = (int) (rgb[0] * 255);
    int g = (int) (rgb[1] * 255);
    int b = (int) (rgb[2] * 255);
    return (0xFF << 24) | (r << 16) | (g << 8) | (b << 0);
}

static int computeStrokeWidth(float widthInPercent, float width, float height) {
    CGFloat maxSize = MAX(width, height);
    return (int) ((maxSize / 2) * (widthInPercent / 100));
}

void convertV3_4Layout(NSMutableDictionary* dict) {
    // Convert the layout stroke width to the V5 form
    for (NSMutableDictionary *button in (NSMutableArray *)dict[@"mControlDataList"]) {
        button[@"strokeWidth"] = @(computeStrokeWidth([button[@"strokeWidth"] intValue], [button[@"width"] intValue], [button[@"height"] intValue]));
    }

    // Add default values
    for (NSString *key in @[@"mControlDataList", @"mDrawerDataList"]) {
        for (NSMutableDictionary *button in (NSMutableArray *)dict[key]) {
            button[@"displayInGame"] = @YES;
            button[@"displayInMenu"] = @YES;
        }
    }

    dict[@"version"] = @(7);
}

void convertV2Layout(NSMutableDictionary* dict) {
    CGRect screenBounds = [[UIScreen mainScreen] bounds];
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    UIEdgeInsets insets = UIApplication.sharedApplication.windows.firstObject.safeAreaInsets;

    // width: offset the notch parts
    CGFloat screenWidth = (screenBounds.size.width - insets.left - insets.right) * screenScale;

    for (NSMutableDictionary *button in (NSMutableArray *)dict[@"mControlDataList"]) {
        if (![button[@"isDynamicBtn"] boolValue]) {
            button[@"dynamicX"] = [NSString stringWithFormat:@"%f * ${screen_width}", [button[@"x"] floatValue] / screenWidth];
            button[@"dynamicY"] = [NSString stringWithFormat:@"%f * ${screen_height}", [button[@"y"] floatValue] / screenBounds.size.height];
            [button removeObjectForKey:@"x"];
            [button removeObjectForKey:@"y"];
        }
    }
    for (NSMutableDictionary *button in (NSMutableArray *)dict[@"mDrawerDataList"]) {
        NSMutableDictionary *buttonProp = button[@"properties"];
        if (![buttonProp[@"isDynamicBtn"] boolValue]) {
            buttonProp[@"dynamicX"] = [NSString stringWithFormat:@"%f * ${screen_width}", [buttonProp[@"x"] floatValue] / screenWidth];
            buttonProp[@"dynamicY"] = [NSString stringWithFormat:@"%f * ${screen_height}", [buttonProp[@"y"] floatValue] / screenBounds.size.height];
            [buttonProp removeObjectForKey:@"x"];
            [buttonProp removeObjectForKey:@"y"];
        }
    }

    dict[@"version"] = @(5);
    convertV3_4Layout(dict);
}

void convertV1Layout(NSMutableDictionary* dict) {
    for (NSMutableDictionary *btnDict in (NSMutableArray *)dict[@"mControlDataList"]) {
        NSMutableArray *keycodes = [NSMutableArray arrayWithCapacity:4];
        CGFloat scale = [dict[@"scaledAt"] floatValue];

        // default values
        btnDict[@"bgColor"] = @(0x4d000000);
        btnDict[@"strokeWidth"] = @(0);

        // opacity -> reverse transparency
        btnDict[@"opacity"] = @((100.0 - [btnDict[@"transparency"] intValue]) / 100.0);
        [btnDict removeObjectForKey:@"transparency"];

        // pixel of width, height -> dp
        btnDict[@"width"] = @([btnDict[@"width"] floatValue] / scale * 50.0);
        btnDict[@"height"] = @([btnDict[@"height"] floatValue] / scale * 50.0);

        // isRound -> cornerRadius 35%
        if ([btnDict[@"isRound"] boolValue] == YES) {
            btnDict[@"cornerRadius"] = @(35.0f);
        }
        [btnDict removeObjectForKey:@"isRound"];

        // keycode -> keycodes[0]
        // Task193：仓库下载的 v1 布局可能缺省 "keycode" 字段（727a291 装机
        // latestlog.old 符号化实锤：_convertV1Layout+0x410 ←
        // _convertLayoutIfNecessary ← _loadControlObject ←
        // -[ControlLayout loadControlFile:] ← actionMenuLoad block ←
        // FileListViewController tableView:didSelectRowAtIndexPath:]，
        // [keycodes addObject:nil] → "insertObject:atIndex: object cannot
        // be nil" 崩溃）。缺省/非数值一律按 KEY_UNKNOWN(0) 兜底，布局照常
        // 加载（按钮无绑定键也比整个启动器崩溃好）。
        [keycodes addObject:@([btnDict[@"keycode"] integerValue])];
        [btnDict removeObjectForKey:@"keycode"];

        // alt -> keycodes[i++]
        if ([dict[@"holdAlt"] boolValue] == YES) {
            [keycodes addObject:@(GLFW_KEY_LEFT_ALT)];
        }
        [btnDict removeObjectForKey:@"holdAlt"];

        // ctrl -> keycodes[i++]
        if ([dict[@"holdCtrl"] boolValue] == YES) {
            [keycodes addObject:@(GLFW_KEY_LEFT_CONTROL)];
        }
        [btnDict removeObjectForKey:@"holdCtrl"];

        // shift -> keycodes[i++]
        if ([dict[@"holdShift"] boolValue] == YES) {
            [keycodes addObject:@(GLFW_KEY_LEFT_SHIFT)];
        }
        [btnDict removeObjectForKey:@"holdShift"];

        // set final keycode array
        btnDict[@"keycodes"] = keycodes;

        btnDict[@"mDrawerDataList"] = [[NSMutableArray alloc] init];
    }

    dict[@"scaledAt"] = @(100);
    dict[@"version"] = @(2);

    convertV2Layout(dict);
}

BOOL convertLayoutIfNecessary(NSMutableDictionary* dict) {
    int version = [dict[@"version"] intValue];
    // Task 198（控件仓库"挤成一坨"修复）：误盖落戳救回。
    // 病历：仓库种子文件本是 v7 格式（mControlDataList 按钮带 keycodes 数组 +
    // dynamicX/dynamicY 相对定位表达式、无静态 x/y、scaledAt≈100 基准），却被
    // 误盖 "version":"1.0"。加载链把它当真 V1 老布局跑转换：
    //   V1 段：单数键 "keycode" 缺省（nil→0）→ keycodes 数组被整体替换成 [0]
    //          （按钮全部失去按键绑定）；width/height 被 scaledAt=101 重除
    //          再乘 50（尺寸近乎减半）；
    //   V2 段：isDynamicBtn=false 的按钮读静态 x/y（v7 无此键，nil→0）→
    //          dynamicX 被覆写成 "0.000000 * ${screen_width}"；
    //   → 全部控件堆到屏幕左上角 + 按钮不可用（用户实测"全部挤在一坨"）。
    // 判据（真 V1 不可能满足）：mControlDataList 里【任一】按钮同时具有
    //   ① "keycodes" 为 NSArray —— V1 的键名是单数 "keycode"，"keycodes"
    //      数组是 V1 转换的【产物】，转换前的 V1 文件里不可能存在；
    //   ② "dynamicX" 为 NSString；
    //   ③ 无静态 "x" 键。
    //   三者齐备 = 这本来就是转换后的新格式，低版本号是误盖。
    // 处置：直接落戳 version=7，跳过整条转换链（scaledAt 语义同因：v7 的
    // scaledAt 已是 100 基准，V1 转换会重置后再动 width/height —— 灾难）。
    // 本救回同时治愈【已下载到设备的坏副本】（无需重新下载，重新加载即自愈）；
    // 种子源文件自身的修正（version=7 重落戳 + index.json 版本元数据同步）
    // 见仓库 controls/ 目录 —— 推送后新下载的文件自带正确落戳。
    if (version <= 1) {
        NSArray *ame198_controls = dict[@"mControlDataList"];
        if ([ame198_controls isKindOfClass:[NSArray class]]) {
            for (NSDictionary *ame198_btn in ame198_controls) {
                if (![ame198_btn isKindOfClass:[NSDictionary class]]) continue;
                if ([ame198_btn[@"keycodes"] isKindOfClass:[NSArray class]] &&
                    [ame198_btn[@"dynamicX"] isKindOfClass:[NSString class]] &&
                    ame198_btn[@"x"] == nil) {
                    dict[@"version"] = @(7);
                    NSLog(@"[CustomControls] Task198: mis-stamped version=%d rescued to 7 (button '%@' carries keycodes-array + dynamicX + no static x -- impossible for a real V1 layout), conversion chain skipped",
                          version, ame198_btn[@"name"]);
                    version = 7;
                    break;
                }
            }
        }
    }
    switch (version) {
        case 0:
        case 1:
            convertV1Layout(dict);
            break;
        case 2:
            convertV2Layout(dict);
            break;
        case 3:
        case 4:
        case 5:
            convertV3_4Layout(dict);
            break;
        case 6:
        case 7:
            break;
        default:
            showDialog(localize(@"custom_controls.control_menu.save.error.json", nil), [NSString stringWithFormat:localize(@"custom_controls.error.incompatible", nil), version]);
            return NO;
    }
    return YES;
}

void generateAndSaveDefaultControl() {
    NSString *defaultPath = [NSString stringWithFormat:@"%s/controlmap/default.json", getenv("POJAV_HOME")];
    if ([NSFileManager.defaultManager fileExistsAtPath:defaultPath]) {
        return;
    }

    // Generate a v2.7 control
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"version"] = @(5);
    dict[@"scaledAt"] = @(100);
    dict[@"mControlDataList"] = [NSMutableArray new];
    dict[@"mDrawerDataList"] = [NSMutableArray new];
    dict[@"mJoystickDataList"] = [NSMutableArray new];
    [dict[@"mControlDataList"] addObject:createButton(@"Keyboard",
        (int[]){SPECIALBTN_KEYBOARD,0,0,0},
        @"${margin} * 3 + ${width} * 2",
        @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"GUI",
        (int[]){SPECIALBTN_TOGGLECTRL,0,0,0},
        @"${margin}",
        @"${bottom} - ${margin}",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"PRI",
        (int[]){SPECIALBTN_MOUSEPRI,0,0,0},
        @"${margin}",
        @"${screen_height} - ${margin} * 3 - ${height} * 3",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"SEC",
        (int[]){SPECIALBTN_MOUSESEC,0,0,0},
        @"${margin} * 3 + ${width} * 2",
        @"${screen_height} - ${margin} * 3 - ${height} * 3",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Mouse",
        (int[]){SPECIALBTN_VIRTUALMOUSE,0,0,0},
        @"${right} - ${margin}",
        @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Debug",
        (int[]){GLFW_KEY_F3,0,0,0},
        @"${margin}",
        @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Chat",
        (int[]){GLFW_KEY_T,0,0,0},
        @"${margin} * 2 + ${width}",
        @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Tab",
        (int[]){GLFW_KEY_TAB,0,0,0},
        @"${margin} * 4 + ${width} * 3",
        @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Opti-Zoom",
        (int[]){GLFW_KEY_C,0,0,0},
        @"${margin} * 5 + ${width} * 4",
        @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Offhand",
        (int[]){GLFW_KEY_F,0,0,0},
        @"${margin} * 6 + ${width} * 5",
        @"${margin}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"3rd",
        (int[]){GLFW_KEY_F5,0,0,0},
        @"${margin}",
        @"${margin} * 2 + ${height}",
        BTN_RECT
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"▲",
        (int[]){GLFW_KEY_W,0,0,0},
        @"${margin} * 2 + ${width}",
        @"${bottom} - ${margin} * 3 - ${height} * 2",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"◀",
        (int[]){GLFW_KEY_A,0,0,0},
        @"${margin}",
        @"${bottom} - ${margin} * 2 - ${height}",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"▼",
        (int[]){GLFW_KEY_S,0,0,0},
        @"${margin} * 2 + ${width}",
        @"${bottom} - ${margin}",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"▶",
        (int[]){GLFW_KEY_D,0,0,0},
        @"${margin} * 3 + ${width} * 2",
        @"${bottom} - ${margin} * 2 - ${height}",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Inv",
        (int[]){GLFW_KEY_E,0,0,0},
        @"${margin} * 3 + ${width} * 2",
        @"${bottom} - ${margin}",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"◇",
        (int[]){GLFW_KEY_LEFT_SHIFT,0,0,0},
        @"${margin} * 2 + ${width}",
        @"${screen_height} - ${margin} * 2 - ${height} * 2",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"⬛",
        (int[]){GLFW_KEY_SPACE,0,0,0},
        @"${right} - ${margin} * 2 - ${width}",
        @"${bottom} - ${margin} * 2 - ${height}",
        BTN_SQUARE
    )];
    [dict[@"mControlDataList"] addObject:createButton(@"Esc",
        (int[]){GLFW_KEY_ESCAPE,0,0,0},
        @"${right} - ${margin}",
        @"${bottom} - ${margin}",
        BTN_RECT
    )];
    NSOutputStream *os = [[NSOutputStream alloc] initToFileAtPath:defaultPath append:NO];
    [os open];
    [NSJSONSerialization writeJSONObject:dict toStream:os options:NSJSONWritingPrettyPrinted error:nil];
    [os close];

/*
    [dict[@"mControlDataList"] addObject:createButton(@"NAME",
        {SPECIALBTN_KEYBOARD,0,0,0},
        @"DYNAMICX",
        @"DYNAMICY",
        WIDTHHEIGHT
    )];
*/
}

void generateAndSaveDefaultControlForGamepad() {
    NSString *gamepadPath = [NSString stringWithFormat:@"%s/controlmap/gamepads/default.json", getenv("POJAV_HOME")];
    if ([NSFileManager.defaultManager fileExistsAtPath:gamepadPath]) {
        return;
    }
    
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    dict[@"version"] = @(1);
    
    dict[@"mGameMappingList"] = [[NSMutableArray alloc] init];
    
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"bumper_left", GLFW_GAMEPAD_BUTTON_LEFT_BUMPER, SPECIALBTN_SCROLLUP)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"bumper_right", GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER, SPECIALBTN_SCROLLDOWN)];
    
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"trigger_left", GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER, SPECIALBTN_MOUSESEC)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"trigger_right", GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER, SPECIALBTN_MOUSEPRI)];
    
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"named_back", GLFW_GAMEPAD_BUTTON_BACK, GLFW_KEY_TAB)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"named_start", GLFW_GAMEPAD_BUTTON_START, GLFW_KEY_ESCAPE)];
    
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"named_a", GLFW_GAMEPAD_BUTTON_A, GLFW_KEY_SPACE)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"named_b", GLFW_GAMEPAD_BUTTON_B, GLFW_KEY_Q)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"named_x", GLFW_GAMEPAD_BUTTON_X, GLFW_KEY_E)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"named_y", GLFW_GAMEPAD_BUTTON_Y, GLFW_KEY_F)];
    
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"dpad_up", GLFW_GAMEPAD_BUTTON_DPAD_UP, GLFW_KEY_LEFT_SHIFT)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"dpad_down", GLFW_GAMEPAD_BUTTON_DPAD_DOWN, GLFW_KEY_O)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"dpad_left", GLFW_GAMEPAD_BUTTON_DPAD_LEFT, GLFW_KEY_J)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"dpad_right", GLFW_GAMEPAD_BUTTON_DPAD_RIGHT, GLFW_KEY_K)];
    
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"thumb_left", GLFW_GAMEPAD_BUTTON_LEFT_THUMB, GLFW_KEY_LEFT_CONTROL)];
    [dict[@"mGameMappingList"] addObject:createGamepadButton(@"thumb_right", GLFW_GAMEPAD_BUTTON_RIGHT_THUMB, GLFW_KEY_LEFT_SHIFT)];
    
    dict[@"mMenuMappingList"] = [[NSMutableArray alloc] init];
    
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"bumper_left", GLFW_GAMEPAD_BUTTON_LEFT_BUMPER, SPECIALBTN_SCROLLUP)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"bumper_right", GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER, SPECIALBTN_SCROLLDOWN)];
    
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"trigger_left", GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER, GLFW_KEY_UNKNOWN)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"trigger_right", GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER, GLFW_KEY_UNKNOWN)];
    
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"named_back", GLFW_GAMEPAD_BUTTON_BACK, GLFW_KEY_UNKNOWN)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"named_start", GLFW_GAMEPAD_BUTTON_START, GLFW_KEY_UNKNOWN)];
    
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"named_a", GLFW_GAMEPAD_BUTTON_A, SPECIALBTN_MOUSEPRI)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"named_b", GLFW_GAMEPAD_BUTTON_B, GLFW_KEY_ESCAPE)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"named_x", GLFW_GAMEPAD_BUTTON_X, SPECIALBTN_MOUSESEC)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"named_y", GLFW_GAMEPAD_BUTTON_Y, GLFW_KEY_LEFT_SHIFT)];
    
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"dpad_up", GLFW_GAMEPAD_BUTTON_DPAD_UP, GLFW_KEY_UNKNOWN)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"dpad_down", GLFW_GAMEPAD_BUTTON_DPAD_DOWN, GLFW_KEY_O)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"dpad_left", GLFW_GAMEPAD_BUTTON_DPAD_LEFT, GLFW_KEY_J)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"dpad_right", GLFW_GAMEPAD_BUTTON_DPAD_RIGHT, GLFW_KEY_K)];
    
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"thumb_left", GLFW_GAMEPAD_BUTTON_LEFT_THUMB, GLFW_KEY_UNKNOWN)];
    [dict[@"mMenuMappingList"] addObject:createGamepadButton(@"thumb_right", GLFW_GAMEPAD_BUTTON_RIGHT_THUMB, GLFW_KEY_UNKNOWN)];
    
    NSOutputStream *os = [[NSOutputStream alloc] initToFileAtPath:gamepadPath append:NO];
    [os open];
    [NSJSONSerialization writeJSONObject:dict toStream:os options:NSJSONWritingPrettyPrinted error:nil];
    [os close];
}

void generateAndSaveCustomControl() {
    NSString *customPath = [NSString stringWithFormat:@"%s/controlmap/custom.json", getenv("POJAV_HOME")];
    if ([NSFileManager.defaultManager fileExistsAtPath:customPath]) {
        return;
    }
    
    // Get path to the built-in custom control layout
    NSString *builtinCustomPath = [[NSBundle mainBundle] pathForResource:@"custom" ofType:@"json" inDirectory:@"controlmap"];
    if (builtinCustomPath && [NSFileManager.defaultManager fileExistsAtPath:builtinCustomPath]) {
        // Copy the built-in custom layout to the user's controlmap directory
        NSError *error = nil;
        [NSFileManager.defaultManager copyItemAtPath:builtinCustomPath toPath:customPath error:&error];
        if (error) {
            NSLog(@"Failed to copy built-in custom control layout: %@", error.localizedDescription);
        }
    } else {
        NSLog(@"Built-in custom control layout not found");
    }
}

NSString* restoreDefaultCustomControl() {
    // Task 64（恢复默认控件）：
    // 用户场景：App 升级带来新模板（如 Task 63 的 custom.json v7 重写）后，
    // 设备上仍是旧布局；或旧布局在历史崩溃（Task 62 之前的保存闪退）中写坏，
    // 导致进游戏控件全部无反应（loadControlFile 解析失败 = 零控件加载）。
    // generateAndSave* 系列“仅当文件不存在才生成”的语义无法自愈这两种情况，
    // 需要一个显式的“恢复出厂”入口：永远删除重建。
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *controlmapDir = [NSString stringWithFormat:@"%s/controlmap", getenv("POJAV_HOME")];
    NSString *defaultPath = [controlmapDir stringByAppendingPathComponent:@"default.json"];
    NSString *customPath = [controlmapDir stringByAppendingPathComponent:@"custom.json"];

    // 目录兜底（正常必然存在，防御 POJAV_HOME 被清空的极端情况）
    NSError *error = nil;
    if (![fm fileExistsAtPath:controlmapDir]) {
        if (![fm createDirectoryAtPath:controlmapDir withIntermediateDirectories:YES attributes:nil error:&error]) {
            return error.localizedDescription;
        }
    }

    // 1) 删除两个出厂布局文件（用户自建的其他布局不受影响）
    for (NSString *path in @[defaultPath, customPath]) {
        if ([fm fileExistsAtPath:path]) {
            if (![fm removeItemAtPath:path error:&error]) {
                NSLog(@"[CustomControls] Task64 restore: remove failed (%@): %@", path.lastPathComponent, error.localizedDescription);
                return error.localizedDescription;
            }
        }
    }

    // 2) 从出厂来源重建
    //    default.json：generateAndSaveDefaultControl 程序化生成 v5 布局
    //    custom.json：App Bundle 内置模板（Task 63 v7）
    generateAndSaveDefaultControl();
    generateAndSaveCustomControl();

    if (![fm fileExistsAtPath:defaultPath]) {
        NSLog(@"[CustomControls] Task64 restore: default.json regeneration failed");
        return localize(@"custom_controls.restore_default.error.template", nil);
    }
    // custom.json 复制失败不阻断：Task 77 起默认布局就是 custom.json，极端情况下
    // 缺失时 loadControlFile 的 Task64 回落链会退回 default.json 保住可玩性
    if (![fm fileExistsAtPath:customPath]) {
        NSLog(@"[CustomControls] Task64 restore: custom.json copy failed (parse-fail fallback to default.json still covers playability)");
    }

    // 3) 复位激活布局指针（档案感知：与 actionOpenCustomControls 的写入路径一致）
    //    Task 77：复位目标与出厂默认对齐改为 custom.json（两个出厂文件均刚重建，
    //    custom.json 此时必然为干净出厂模板）。
    NSString *ame77RestoreCtrl = [fm fileExistsAtPath:customPath] ? @"custom.json" : @"default.json";
    if (PLProfiles.current.selectedProfile[@"defaultTouchCtrl"]) {
        PLProfiles.current.selectedProfile[@"defaultTouchCtrl"] = ame77RestoreCtrl;
        [PLProfiles.current save];
    } else {
        setPrefObject(@"control.default_ctrl", ame77RestoreCtrl);
    }

    NSLog(@"[CustomControls] Task64 restore default: factory layouts regenerated (default.json + custom.json), active layout reset to %@", ame77RestoreCtrl);
    return nil;
}

// Task 83b：装饰板免疫——判断一个按钮属性字典是否"纯装饰"：
// 四键位全 0、非 toggle、非穿透。这种按钮在 executebtn 里永远空转
// （keycode<0 特殊键 / keycode>0 普通键都不命中），但作为 UIControl 照样
// 参与命中测试。若它恰好叠在功能键上方（后加 = z 序更高），会吞掉整片
// 区域的触摸——出厂 custom.json 的"⌨"抽屉背景板正是这种情况：它排在
// buttonProperties 数组末尾（addSubview 最后 = 最顶层），全覆盖 58/60
// 个功能键 = "面板打不了字"的真正根因（be276a0 装机日志零事件实锤）。
// 修复：纯装饰按钮禁用交互，触摸自然落到下层的功能键上。
static BOOL ame83b_is_decorative_button(NSMutableDictionary *props) {
    if ([props[@"passThruEnabled"] boolValue]) return NO;   // 穿透板有自己的转发语义
    if ([props[@"isToggle"] boolValue]) return NO;          // toggle 板有视觉切换语义
    NSArray *kcs = props[@"keycodes"];
    for (int i = 0; i < 4; i++) {
        if (kcs && i < (int)kcs.count && [kcs[i] intValue] != 0) return NO;
    }
    return YES;
}

/// Task233（反馈 #1 纠偏）：ame83b 装饰判定的公开包装（单一事实源）。
/// SurfaceViewController 的重叠取证与 z 序判定复用同一条规则，
/// 非 ControlButton 一律 NO。
BOOL ame233_viewIsDecorativeControlButton(UIView *view) {
    if (![view isKindOfClass:ControlButton.class]) return NO;
    if ([view isKindOfClass:ControlSubButton.class]) return NO;
    return ame83b_is_decorative_button(((ControlButton *)view).properties);
}

void loadControlObject(UIView* targetView, NSMutableDictionary* controlDictionary) {
    NSMutableString *errorString = [[NSMutableString alloc] init];

    if (convertLayoutIfNecessary(controlDictionary)) {
        NSMutableArray *controlDataList = controlDictionary[@"mControlDataList"];
        //setPrefObject(@"internal.internal_current_button_scale", controlDictionary[@"scaledAt"]);
        for (NSMutableDictionary *buttonDict in controlDataList) {
            //APPLY_SCALE(buttonDict[@"strokeWidth"]);
            @try {
                ControlButton *button = [ControlButton buttonWithProperties:buttonDict];
                [targetView addSubview:button];
                [button update];
                // Task 83b：顶层纯装饰板同样免疫（与子按钮同规则）。编辑模式
                // 保留交互（否则板无法被选中/拖动/删除），仅游戏模式穿透。
                if (!isControlModifiable && ame83b_is_decorative_button(buttonDict)) {
                    button.userInteractionEnabled = NO;
                }
            } @catch (NSException *exception) {
                [errorString appendFormat:@"%@: %@\n", buttonDict[@"name"], exception.reason];
            }
            //NSLog(@"DBG Added button=%@", button);
        }

        NSMutableArray *drawerDataList = controlDictionary[@"mDrawerDataList"];
        for (NSMutableDictionary *drawerData in drawerDataList) {
            ControlDrawer *drawer;
            @try {
                drawer = [ControlDrawer buttonWithData:drawerData];
            } @catch (NSException *exception) {
                [errorString appendFormat:@"%@: %@\n", drawerData[@"name"], exception.reason];
            }
            if (isControlModifiable) drawer.areButtonsVisible = YES;
            [targetView addSubview:drawer];
            //NSLog(@"DBG Added drawer=%@", drawer);

            for (NSMutableDictionary *subButton in drawerData[@"buttonProperties"]) {
                ControlSubButton *subView = [ControlSubButton buttonWithProperties:subButton];
                [drawer addButton:subView];
                [targetView addSubview:subView];
                // Task 83b：纯装饰子按钮（背景板）禁用交互——否则它在 z 序
                // 顶层吞掉整面板触摸（⌨ 键盘面板从未能用的根因）。编辑模式
                // 保留交互（板可被选中编辑），仅游戏模式穿透。
                if (!isControlModifiable && ame83b_is_decorative_button(subButton)) {
                    subView.userInteractionEnabled = NO;
                    static int s_task83b_plates = 0;
                    s_task83b_plates++;
                    if (s_task83b_plates <= 5) {
                        NSLog(@"[CustomControls] Task83b decorative sub-button pass-through enabled #%d (name=%@, touch no longer swallowed)",
                              s_task83b_plates, subButton[@"name"]);
                    }
                }
            }
            [drawer update];
        }

        NSMutableArray *joystickDataList = controlDictionary[@"mJoystickDataList"];
        if (!joystickDataList) {
            controlDictionary[@"mJoystickDataList"] = [NSMutableArray new];
        }
        for (NSMutableDictionary *joystickDict in joystickDataList) {
            @try {
                ControlJoystick *button = [ControlJoystick buttonWithProperties:joystickDict];
                [targetView addSubview:button];
                [button update];
            } @catch (NSException *exception) {
                [errorString appendFormat:@"%@: %@\n", @"ControlJoystick", exception.reason];
            }
        }

        controlDictionary[@"scaledAt"] = getPrefObject(@"control.button_scale");

        // ★ Task233（反馈 #1 纠偏："常用操作键"抽屉开启时左右键失灵）：
        //   装载序 = 主按钮 → 抽屉 → 抽屉子按钮 → 摇杆——子按钮全部压在
        //   主按钮之上（z 序最顶，仅让位于摇杆）。抽屉子按钮是 FREE 散点
        //   键（出厂常用操作键 = F5/T/F/F1/F3/右SHIFT/Z 分布全屏），用户
        //   自编布局里与 左键/右键/方向/字母 主控件重叠时，开启抽屉 =
        //   重叠区触摸全部被子按钮抢走 = "开着常用操作键就无法左右键"。
        //   修法（仅游戏模式；编辑器保持原 z 序便于拖动编辑）：把全部
        //   ControlSubButton 整体下移到【第一个可交互主按钮】之下——抽屉
        //   键只在空白区可点，与主控件的任何重叠都让位给主控件。子按钮
        //   相对顺序保持不变（逐个"接龙"插入，背景板仍在最底）。
        if (!isControlModifiable) {
            UIView *ame233_firstInteractive = nil;
            for (UIView *ame233_v in targetView.subviews) {
                if ([ame233_v isKindOfClass:ControlSubButton.class]) continue;
                if (![ame233_v isKindOfClass:ControlButton.class]) continue;
                if (!ame233_v.userInteractionEnabled) continue;   // 装饰板已禁用
                if (ame83b_is_decorative_button(((ControlButton *)ame233_v).properties)) continue;
                ame233_firstInteractive = ame233_v;
                break;
            }
            if (ame233_firstInteractive != nil) {
                int ame233_moved = 0;
                UIView *ame233_prev = nil;
                for (UIView *ame233_v in [targetView.subviews copy]) {
                    if (![ame233_v isKindOfClass:ControlSubButton.class]) continue;
                    if (ame233_prev == nil) {
                        [targetView insertSubview:ame233_v belowSubview:ame233_firstInteractive];
                    } else {
                        [targetView insertSubview:ame233_v aboveSubview:ame233_prev];
                    }
                    ame233_prev = ame233_v;   // 后续插在前一枚之上 → 顺序不反转
                    ame233_moved++;
                }
                if (ame233_moved > 0) {
                    NSLog(@"[CustomControls] Task233: %d drawer sub-buttons moved below interactive main buttons (drawer keys yield to 左/右键/摇杆 overlaps)", ame233_moved);
                }
            }
        }

        if (errorString.length > 0) {
            showDialog(@"Error processing dynamic position", errorString);
        }
    }
}

void initKeycodeTable(NSMutableArray* keyCodeMap, NSMutableArray* keyValueMap) {
#define GLFW_KEY_NONE 0
#define addkey(key) \
    [keyCodeMap addObject:@(#key)]; \
    [keyValueMap addObject:@(GLFW_KEY_##key)];
#define addspec(key) \
    [keyCodeMap addObject:@(#key)]; \
    [keyValueMap addObject:@(key)];

    addspec(SPECIALBTN_MENU)
    addspec(SPECIALBTN_SCROLLDOWN)
    addspec(SPECIALBTN_SCROLLUP)
    addspec(SPECIALBTN_VIRTUALMOUSE)
    addspec(SPECIALBTN_MOUSEMID)
    addspec(SPECIALBTN_MOUSESEC)
    addspec(SPECIALBTN_MOUSEPRI)
    addspec(SPECIALBTN_TOGGLECTRL)
    addspec(SPECIALBTN_KEYBOARD)

    addkey(NONE)
    addkey(HOME)
    addkey(ESCAPE)

    // 0-9 keys
    addkey(0) addkey(1) addkey(2) addkey(3) addkey(4)
    addkey(5) addkey(6) addkey(7) addkey(8) addkey(9)
    //addkey(POUND)

    // Arrow keys
    addkey(DPAD_UP) addkey(DPAD_DOWN) addkey(DPAD_LEFT) addkey(DPAD_RIGHT)

    // A-Z keys
    addkey(A) addkey(B) addkey(C) addkey(D) addkey(E)
    addkey(F) addkey(G) addkey(H) addkey(I) addkey(J)
    addkey(K) addkey(L) addkey(M) addkey(N) addkey(O)
    addkey(P) addkey(Q) addkey(R) addkey(S) addkey(T)
    addkey(U) addkey(V) addkey(W) addkey(X) addkey(Y)
    addkey(Z)

    addkey(COMMA)
    addkey(PERIOD)

    // Alt keys
    addkey(LEFT_ALT)
    addkey(RIGHT_ALT)

    // Shift keys
    addkey(LEFT_SHIFT)
    addkey(RIGHT_SHIFT)

    addkey(TAB)
    addkey(SPACE)
    addkey(ENTER)
    addkey(BACKSPACE)
    addkey(DELETE)
    addkey(GRAVE_ACCENT)
    addkey(MINUS)
    addkey(EQUAL)
    addkey(LEFT_BRACKET) addkey(RIGHT_BRACKET)
    addkey(BACKSLASH)
    addkey(SEMICOLON)
    addkey(SLASH)
    //addkey(AT) //@

    // Page keys
    addkey(PAGE_UP) addkey(PAGE_DOWN)

    // Control keys
    addkey(LEFT_CONTROL)
    addkey(RIGHT_CONTROL)

    addkey(CAPS_LOCK)
    addkey(PAUSE)
    addkey(INSERT)

    // Fn keys
    addkey(F1) addkey(F2) addkey(F3) addkey(F4)
    addkey(F5) addkey(F6) addkey(F7) addkey(F8)
    addkey(F9) addkey(F10) addkey(F11) addkey(F12)

    // Num keys
    addkey(NUM_LOCK)
    addkey(NUMPAD_0)
    addkey(NUMPAD_1) addkey(NUMPAD_2) addkey(NUMPAD_3)
    addkey(NUMPAD_4) addkey(NUMPAD_5) addkey(NUMPAD_6)
    addkey(NUMPAD_7) addkey(NUMPAD_8) addkey(NUMPAD_9)
    addkey(NUMPAD_DECIMAL)
    addkey(NUMPAD_DIVIDE)
    addkey(NUMPAD_MULTIPLY)
    addkey(NUMPAD_SUBTRACT)
    addkey(NUMPAD_ADD)
    addkey(NUMPAD_ENTER)
    addkey(NUMPAD_EQUAL)

    //addkey(APOSTROPHE)
    //addkey(WORLD_1) addkey(WORLD_2)
    //addkey(END)
    //addkey(SCROLL_LOCK) 
    //addkey(PRINT_SCREEN)
    //addkey(LEFT_SUPER) addkey(RIGHT_ENTER)
    //addkey(MENU)
#undef addkey
}
