#import "ControllerInput.h"
#import "../LauncherPreferences.h"
#import "../PLProfiles.h"
#import "../SurfaceViewController.h"
#import "../utils.h"
#import "../NMToast.h"

#include "../glfw_keycodes.h"

// Left thumbstick directions
#define DIRECTION_EAST 0
#define DIRECTION_NORTH_EAST 1
//#define DIRECTION_NORTH 2
#define DIRECTION_NORTH_WEST 3
//#define DIRECTION_WEST 4
#define DIRECTION_SOUTH_WEST 5
//#define DIRECTION_SOUTH 6
#define DIRECTION_SOUTH_EAST 7
#define MOUSE_MAX_ACCELERATION 2

CFAbsoluteTime lastFrameTime;
CGFloat lastXValue; // lastHorizontalValue
CGFloat lastYValue; // lastVerticalValue

@implementation ControllerInput

NSMutableDictionary *gameMap, *menuMap;
BOOL leftShiftHeld;

// ★ Task310（Switch 手柄）：任天堂/Switch 布局交换。
//   病历：GCController 按位置上报面键（buttonA=下方物理键、buttonB=右方），
//   Xbox 位置语义下下方键标 "A"；而 Switch/Pro/Joy-Con 下方物理键标 "B"、
//   右方标 "A"——Switch 用户按肌肉记忆按 "A"（右键）却得到 buttonB 的映射，
//   确认/跳跃反了。开启本偏好后在映射查询前做 A↔B、X↔Y 位置交换，
//   让 "键面标签 A" 重新对准 "A 的功能"。
//   偏好：control.nintendo_layout（默认 NO = Xbox 位置语义，老用户无感）。
static int ame310_layoutSwapKeycode(int keycode) {
    if (![getPrefObject(@"control.nintendo_layout") boolValue]) return keycode;
    switch (keycode) {
        case GLFW_GAMEPAD_BUTTON_A: return GLFW_GAMEPAD_BUTTON_B;
        case GLFW_GAMEPAD_BUTTON_B: return GLFW_GAMEPAD_BUTTON_A;
        case GLFW_GAMEPAD_BUTTON_X: return GLFW_GAMEPAD_BUTTON_Y;
        case GLFW_GAMEPAD_BUTTON_Y: return GLFW_GAMEPAD_BUTTON_X;
        default: return keycode;
    }
}

// ★ Task310（手柄优化）：虚拟滚轮速度系数（control.scroll_speed，100=1.0）。
//   作用面 = 触屏布局滚动按钮 + 手柄滚动键这类模拟滚轮（固定 ±1 步进）
//   的发送点；真硬件外设（GCMouse 滚轮/触摸惯性甩动）不在此列，保持原样。
static CGFloat ame310_scrollFactor(void) {
    NSInteger pct = [getPrefObject(@"control.scroll_speed") integerValue];
    if (pct < 25) pct = 25;   // 与设置页滑条 min 一致，防手改越界
    if (pct > 300) pct = 300;
    return pct / 100.0;
}

+ (CGFloat)scrollStep:(CGFloat)baseStep {
    return baseStep * ame310_scrollFactor();
}

+ (void)initKeycodeTable {
    if (gameMap && menuMap) {
        return;
    }
    
    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultGamepadCtrl"];
    NSString *gamepadPath = [NSString stringWithFormat:@"%s/controlmap/gamepads/%@", getenv("POJAV_HOME"), controlFile];
    NSMutableDictionary *gamepadJSON = parseJSONFromFile(gamepadPath);
    
    gameMap = gamepadJSON[@"mGameMappingList"];
    menuMap = gamepadJSON[@"mMenuMappingList"];
}

+ (void)sendKeyEvent:(int)controllerKeycode pressed:(BOOL)pressed {
    // ★ Task275（E-P1-3）：keycode 必须有初值——mapping 为 nil（controlmap 缺失/
    //   解析失败）或按键未配置时，原未初始化局部变量走 switch = 未定义行为
    //   （"按未映射键重放上一次映射键"/首次发送随机值）。GLFW_KEY_UNKNOWN
    //   已有专门 case，零成本根修。
    int keycode = GLFW_KEY_UNKNOWN;
    __block NSMutableDictionary *mapping;
    // ★ Task310（Switch 手柄）：任天堂布局交换在映射查询前生效，
    //   gameMap/menuMap 两表统一走同一交换（位置键值 -> 键面标签语义）。
    controllerKeycode = ame310_layoutSwapKeycode(controllerKeycode);
    if (isGrabbing) {
        mapping = gameMap;
    } else {
        mapping = menuMap;
    }

    if (mapping != nil) for (NSMutableDictionary *buttonDict in mapping) {
        if(controllerKeycode == [buttonDict[@"gamepad_button"] intValue]) {
            keycode = [buttonDict[@"keycode"] intValue];
        }
    }

    switch (keycode) {
        case GLFW_KEY_UNKNOWN:
            // Do nothing
            break;
        case -GLFW_KEY_LEFT_SHIFT:
            if (!pressed) {
                leftShiftHeld = !leftShiftHeld;
                CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SHIFT, 0, leftShiftHeld, 0);
            }
            break;
        case SPECIALBTN_MOUSEPRI:
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed, 0);
            break;
        case SPECIALBTN_MOUSEMID:
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed, 0);
            break;
        case SPECIALBTN_MOUSESEC:
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed, 0);
            break;
        case SPECIALBTN_SCROLLUP:
            CallbackBridge_nativeSendScroll(0, pressed ? [self scrollStep:1.0] : 0);
            break;
        case SPECIALBTN_SCROLLDOWN:
            CallbackBridge_nativeSendScroll(0, pressed ? [self scrollStep:-1.0] : 0);
            break;
        default:
            if (keycode == GLFW_KEY_LEFT_SHIFT) {
                leftShiftHeld = pressed;
            }
            CallbackBridge_nativeSendKey(keycode, 0, pressed, 0);
            break;
    }
}

+ (void)registerControllerCallbacks:(GCController *)controller {
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    // ★ Task310（手柄优化）：不完整档案守卫——单边 Joy-Con 等无法提供
    //   extendedGamepad 档案的外设，原先静默零注册（每个元素 handler 都对
    //   nil 发消息 = 全部无感失效，用户只觉"手柄坏了"）。改为如实提示：
    //   iOS 16+ 双只成对连接的 Joy-Con 会由系统合并为单一 extendedGamepad
    //   档案可正常游玩，单只请先成对连接。
    if (gamepad == nil) {
        NSString *name = controller.vendorName ?: @"controller";
        NSLog(@"[ControllerInput] Task310: %@ provides no extendedGamepad profile (single Joy-Con half?), skipped", name);
        [NMToast showMessage:[NSString stringWithFormat:localize(@"controller.profile.unsupported", nil), name]];
        return;
    }
    NSLog(@"[ControllerInput] Task310: registered extendedGamepad profile for %@", controller.vendorName ?: @"controller");

    gamepad.leftShoulder.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_BUMPER pressed:pressed];
    };
    gamepad.rightShoulder.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_BUMPER pressed:pressed];
    };

    gamepad.leftTrigger.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_TRIGGER pressed:pressed];
    };
    gamepad.rightTrigger.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_TRIGGER pressed:pressed];
    };
    gamepad.buttonOptions.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_BACK pressed:pressed];
    };
    gamepad.buttonMenu.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_START pressed:pressed];
    };
    gamepad.buttonHome.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_GUIDE pressed:pressed];
    };

    gamepad.buttonA.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_A pressed:pressed];
    };
    gamepad.buttonB.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_B pressed:pressed];
    };
    gamepad.buttonX.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_X pressed:pressed];
    };
    gamepad.buttonY.pressedChangedHandler = ^(GCControllerButtonInput *button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_Y pressed:pressed];
    };

    gamepad.dpad.up.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_UP pressed:pressed];
    };
    gamepad.dpad.down.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_DOWN pressed:pressed];
    };
    gamepad.dpad.left.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_LEFT pressed:pressed];
    };
    gamepad.dpad.right.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_DPAD_RIGHT pressed:pressed];
    };

    gamepad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad * _Nonnull dpad, float xValue, float yValue) {
        if (!isGrabbing) {
            // Update virtual mouse position
            lastXValue = xValue;
            lastYValue = yValue;
            return;
        }

        static char lastLThumbDirection = -2;
        char direction = -1;
        // Task223 上游同步（upstream 3a2116c05）：同 ControlJoystick——测
        // "偏离中心"用或而非与。手柄更常见：GCController 在死区内把轴直接
        // snap 到 0，前推带轻微侧漂也会被误判为静止。
        if (xValue != 0 || yValue != 0) {
            CGFloat degree = atan2f(yValue, xValue) * (180.0 / M_PI);
            if (degree < 0) {
                degree += 360;
            }
            direction = (int)((degree+22.5)/45.0) % 8;
        }
        if (lastLThumbDirection == direction) {
            return;
        }

        // Update WASD states
        CallbackBridge_nativeSendKey(GLFW_KEY_W, 0,
            direction >= DIRECTION_NORTH_EAST &&
            direction <= DIRECTION_NORTH_WEST, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_A, 0,
            direction >= DIRECTION_NORTH_WEST &&
            direction <= DIRECTION_SOUTH_WEST, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_S, 0,
            direction >= DIRECTION_SOUTH_WEST &&
            direction <= DIRECTION_SOUTH_EAST, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_D, 0,
            direction == DIRECTION_SOUTH_EAST ||
            direction == DIRECTION_EAST ||
            direction == DIRECTION_NORTH_EAST, 0);

        lastLThumbDirection = direction;
    };
    gamepad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad * _Nonnull dpad, float xValue, float yValue) {
        if (isGrabbing) {
            lastXValue = xValue;
            lastYValue = yValue;
        }
    };
    gamepad.leftThumbstickButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_LEFT_THUMB pressed:pressed];
    };
    gamepad.rightThumbstickButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        [self sendKeyEvent:GLFW_GAMEPAD_BUTTON_RIGHT_THUMB pressed:pressed];
    };
}

/**
 * Send the new mouse position, computing the delta
 */
+ (void)tick {
    // There isn't a convenient way to get ns, use ms at this point
    CGFloat frameTime = CACurrentMediaTime();
    // GameController automatically performs deadzone calculations
    // so we just take the raw input
    if (lastFrameTime != 0 && (lastXValue != 0 || lastYValue != 0)) {
        CGFloat acceleration = pow(MathUtils_dist(0, 0, lastXValue, lastYValue), MOUSE_MAX_ACCELERATION); // magnitude
        if (acceleration > 1) acceleration = 1;

        // Compute delta since last tick time
        CGFloat deltaX = lastXValue * acceleration * 18;
        CGFloat deltaY = -lastYValue * acceleration * 18;
        CGFloat deltaTimeScale = (frameTime - lastFrameTime) / (1.0/60.0); // Scale of 1 = 60Hz
        deltaX *= deltaTimeScale;
        deltaY *= deltaTimeScale;

        SurfaceViewController *vc = [SurfaceViewController currentInstance];
        if (vc) {
            [vc sendTouchPoint:CGPointMake(deltaX, deltaY) withEvent:ACTION_MOVE_MOTION];
        }
    }
    lastFrameTime = frameTime;
}

+ (void)releaseAllHeld {
    // ★ Task310（手柄优化）：断连全量释放。左手摇杆 WASD 不走映射表（直接
    //   CallbackBridge_nativeSendKey），故这里也直接补发，两侧语义一致：
    //   ① 八方向 WASD 全 UP  ② 潜行 Shift UP（含锁存态复位）
    //   ③ 鼠标三键 UP  ④ 滚轮清零  ⑤ 虚拟鼠标增量/方向锁存复位
    //   （防下次连接后残留上次的 lastX/Y 首帧漂移）。
    CallbackBridge_nativeSendKey(GLFW_KEY_W, 0, NO, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_A, 0, NO, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_S, 0, NO, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_D, 0, NO, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SHIFT, 0, NO, 0);
    leftShiftHeld = NO;
    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, NO, 0);
    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, NO, 0);
    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, NO, 0);
    CallbackBridge_nativeSendScroll(0, 0);
    lastXValue = 0;
    lastYValue = 0;
    lastFrameTime = 0;
    NSLog(@"[ControllerInput] Task310: controller lost -- all held keys/buttons released");
}

+ (void)unregisterControllerCallbacks:(GCController *)controller {
    // ★ Task310（手柄优化）：断连先释放全部按住态再摘 handler——
    //   否则"边走边断连"会让角色永远走下去（游戏侧等不到 UP）。
    [self releaseAllHeld];
    GCExtendedGamepad *gamepad = controller.extendedGamepad;
    gamepad.leftShoulder.pressedChangedHandler = nil;
    gamepad.rightShoulder.pressedChangedHandler = nil;
    gamepad.leftTrigger.pressedChangedHandler = nil;
    gamepad.rightTrigger.pressedChangedHandler = nil;
    gamepad.buttonOptions.pressedChangedHandler = nil;
    gamepad.buttonMenu.pressedChangedHandler = nil;
    gamepad.buttonHome.pressedChangedHandler = nil;
    gamepad.buttonA.pressedChangedHandler = nil;
    gamepad.buttonB.pressedChangedHandler = nil;
    gamepad.buttonX.pressedChangedHandler = nil;
    gamepad.buttonY.pressedChangedHandler = nil;
    gamepad.dpad.up.pressedChangedHandler = nil;
    gamepad.dpad.down.pressedChangedHandler = nil;
    gamepad.dpad.left.pressedChangedHandler = nil;
    gamepad.dpad.right.pressedChangedHandler = nil;
    gamepad.leftThumbstick.valueChangedHandler = nil;
    gamepad.rightThumbstick.valueChangedHandler = nil;
    gamepad.leftThumbstickButton.pressedChangedHandler = nil;
    gamepad.rightThumbstickButton.pressedChangedHandler = nil;
}

@end
