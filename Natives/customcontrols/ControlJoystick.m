#import "ControlJoystick.h"
#import "CustomControlsUtils.h"
#import "../input/ControllerInput.h"
#import "../UIKit+hook.h"
#import "../utils.h"
#include "../glfw_keycodes.h"
#include <stdatomic.h>   // Task67：心跳计数 _Atomic

// Left thumbstick directions
#define DIRECTION_EAST 0
#define DIRECTION_NORTH_EAST 1
#define DIRECTION_NORTH 2
#define DIRECTION_NORTH_WEST 3
//#define DIRECTION_WEST 4
#define DIRECTION_SOUTH_WEST 5
//#define DIRECTION_SOUTH 6
#define DIRECTION_SOUTH_EAST 7

extern BOOL leftShiftHeld;

extern CGFloat lastXValue; // lastHorizontalValue
extern CGFloat lastYValue; // lastVerticalValue

// ============================================================================
// Task 66（抓取切换时的摇杆状态复位）：
// callbackMoveX 的 lastDirection 去重会在方向不变时吞掉全量刷新。
// MC 开关界面时（grab 1→0/0→1）：Java 侧 releaseAll/setAll 会清空/重建
// 键位态（setAll 轮询 SDL_GetKeyboardState——Task66 已让虚拟键可见），
// 摇杆若不重新发送全量状态，同方向推杆会被去重吞掉 → “推杆不动，
// 换个方向才动”。两个方向切换沿都把 lastDirection 复位到 -2（未知），
// 迫使下一次 touchesMoved 重发全量 W/A/S/D 状态。
// 1→0（开界面）时额外补发 4 键释放：镜像物理键盘语义，防止虚拟键在
// SDL 键盘数组里滞留（否则关界面后 setAll 会恢复幽灵行走）。
// 由 input_bridge_v3.m 的 CallbackBridge_syncGrabStateFromSDL 调用。
// ============================================================================
static char ame66_joystickLastDirection = -2;

// Task67：物理按住方向（手指未离开时摇杆指向）。
// 与 ame66_joystickLastDirection（去重状态）分离：菜单开关沿会把去重状态
// 复位到 -2，但手指若仍按住不动，touchesMoved 不会再来——去重路径永远
// 无法重发。心跳/重抓沿改用物理方向：只要手指还按着，状态就该被重断言。
static char ame67_physDirection = -1;

// Task67：把方向→四键状态的下发抽成独立函数。
// 心跳重发（ame67_heartbeatResend）与方向变化（callbackMoveX）共用同一套
// 键位计算，保证两条路径发出的 W/A/S/D 状态恒一致。
static void ame67_sendDirectionKeys(char direction, int mod) {
    CallbackBridge_nativeSendKey(GLFW_KEY_W, 0,
        direction >= DIRECTION_NORTH_EAST &&
        direction <= DIRECTION_NORTH_WEST,
        mod);
    CallbackBridge_nativeSendKey(GLFW_KEY_A, 0,
        direction >= DIRECTION_NORTH_WEST &&
        direction <= DIRECTION_SOUTH_WEST,
        mod);
    CallbackBridge_nativeSendKey(GLFW_KEY_S, 0,
        direction >= DIRECTION_SOUTH_WEST &&
        direction <= DIRECTION_SOUTH_EAST,
        mod);
    CallbackBridge_nativeSendKey(GLFW_KEY_D, 0,
        direction == DIRECTION_SOUTH_EAST ||
        direction == DIRECTION_EAST ||
        direction == DIRECTION_NORTH_EAST,
        mod);
}

// ============================================================================
// Task 67（摇杆心跳重发）：按住方向不动时每 250ms 重断言全量 W/A/S/D 状态。
//
// 动机：callbackMoveX 的 lastDirection 去重意味着“方向不变 = 零事件”。
// 若 MC/SDL 侧存在任何未被观测到的清键机制（setAll 兼容性、焦点释放、
// 未来版本的轮询路径变化），按住方向的状态会被静默清掉且永不恢复。
// 心跳重发是事件层的自愈保险：即使状态被清，250ms 内下一次重发即恢复。
// 开销：每 250ms 4 次 sendKey（仅按住摇杆期间），完全可忽略。
// 安全性：重发的是“当前方向的正确状态”，与去重路径发出的内容恒等；
// MC 侧 KeyMapping.set 幂等，重复 set(true) 无副作用。
// ============================================================================
static void ame67_heartbeatResend(void) {
    // 只在抓取状态下且有有效物理方向时重发；开菜单/无触摸时静默
    if (!isGrabbing) return;
    char direction = ame67_physDirection;
    if (direction < 0) return;
    int mod = leftShiftHeld ? GLFW_MOD_SHIFT : 0;
    ame67_sendDirectionKeys(direction, mod);
    static _Atomic int s_ame67Beats = 0;
    int n = atomic_fetch_add(&s_ame67Beats, 1) + 1;
    if (n <= 5 || n % 40 == 0) {   // 前 5 次 + 每 40 次（≈10s）采样记录
        NSLog(@"[Task67] joystick heartbeat #%d: direction=%d re-asserted (WASD self-heal)", n, (int)direction);
    }
}

void AmeControlJoystickOnGrabChange(BOOL grabbed) {
    if (!grabbed && ame66_joystickLastDirection >= 0) {
        // 开界面：释放当前方向的全部按键（W/A/S/D up）
        CallbackBridge_nativeSendKey(GLFW_KEY_W, 0, 0, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_A, 0, 0, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_S, 0, 0, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_D, 0, 0, 0);
        NSLog(@"[Task66] joystick reset on ungrab: WASD released (lastDirection=%d)",
              (int)ame66_joystickLastDirection);
    }
    if (grabbed && ame67_physDirection >= 0) {
        // Task67：重抓沿（关菜单回游戏）且手指仍按住——立即重断言物理方向。
        // 旧行为只复位去重状态等下一次 touchesMoved；手指不动就永远零事件。
        ame67_sendDirectionKeys(ame67_physDirection, 0);
        NSLog(@"[Task67] joystick re-assert on regrab: direction=%d (finger still holding)",
              (int)ame67_physDirection);
    }
    // 双向复位：0→1 时 setAll 已从 SDL 状态恢复真实态，-2 迫使下次重发全量
    ame66_joystickLastDirection = -2;
}

// From CustomControlsUtils
NSMutableDictionary* createButton(NSString* name, int* keycodes, NSString* dynamicX, NSString* dynamicY, CGFloat width, CGFloat height);

@interface ControlJoystick()
@property(nonatomic) UIView *background, *thumb;
@property(nonatomic) UIButton *fwdLockView;
@property(nonatomic) CGPoint mCenter;
@property(nonatomic) NSTimer *ame67HeartbeatTimer;   // Task67：按住期间的心跳重发定时器
@end

@implementation ControlJoystick

+ (id)buttonWithProperties:(NSMutableDictionary *)propArray {
    ControlJoystick *instance = [super buttonWithProperties:propArray];
    instance.clipsToBounds = NO;
    instance.background = [UIView new];
    instance.thumb = [UIView new];
    instance.thumb.backgroundColor = UIColor.blackColor;
    [instance addSubview:instance.background];
    [instance addSubview:instance.thumb];

    if (!isControlModifiable && [propArray[@"forwardLock"] boolValue]) {
        instance.fwdLockView = [UIButton buttonWithType:UIButtonTypeCustom];
        instance.fwdLockView.hidden = YES;
        instance.fwdLockView.imageEdgeInsets = UIEdgeInsetsMake(4, 4, 4, 4);
        instance.fwdLockView.tintColor = UIColor.whiteColor;
        instance.fwdLockView.userInteractionEnabled = NO;
        [instance addSubview:instance.fwdLockView];
    }

    return instance;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (isControlModifiable || touches.count != 1) return;
    if (touches.anyObject.view == self) {
        self.thumb.center = [touches.anyObject locationInView:self];
    }
    if (isGrabbing && self.fwdLockView) {
        self.fwdLockView.center = CGPointMake(self.mCenter.x, -self.mCenter.y);
    }
    // Task67：按住期间启动心跳重发（0.25s）——去重吞掉的重发在这里补上
    if (!self.ame67HeartbeatTimer) {
        self.ame67HeartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
            target:self selector:@selector(ame67HeartbeatTick:)
            userInfo:nil repeats:YES];
    }
    // pass this touch through the move handler
    [self touchesMoved:touches withEvent:event];
}

- (void)ame67HeartbeatTick:(NSTimer *)timer {
    if (isControlModifiable) {   // 编辑控件时不应发键
        [timer invalidate];
        self.ame67HeartbeatTimer = nil;
        return;
    }
    ame67_heartbeatResend();
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (isControlModifiable || touches.count != 1) return;
    UITouch *touch = touches.anyObject;

    //CGPoint prev = [touches.anyObject previousLocationInView:self];
    //CGPoint loc = [touches.anyObject locationInView:self];

    CGPoint center = [touches.anyObject locationInView:self];
    //self.thumb.center;
    //center.x += loc.x - prev.x;
    //center.y += loc.y - prev.y;

    CGFloat dirX = center.x - self.mCenter.x;
    CGFloat dirY = center.y - self.mCenter.y;
    CGFloat radius = sqrt(dirX*dirX + dirY*dirY);
    CGFloat maxRadius = MIN(self.mCenter.x, self.mCenter.y) - self.thumb.frame.size.width/2;
    if (radius > maxRadius) {
        center.x = dirX*maxRadius/radius + self.mCenter.x;
        center.y = dirY*maxRadius/radius + self.mCenter.y;
    }
    self.thumb.center = center;

    CGFloat deadzone = 0.35;
    if (!isGrabbing || radius >= maxRadius*deadzone) {
        [self callbackMoveX:((center.x / self.frame.size.width)*2-1) Y:((-center.y / self.frame.size.height)*2+1)];
    }

#ifdef DEBUG_JOYSTICK
    [UIView performWithoutAnimation:^{
        [self setTitle:[NSString stringWithFormat:@"rad=%f\nCX=%f\nCY=%f", radius, self.mCenter.x / radius, self.mCenter.y / radius] forState:UIControlStateNormal];
        [self layoutIfNeeded];
    }];
#endif
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (isControlModifiable) return;

    [self.ame67HeartbeatTimer invalidate];   // Task67：松手即停心跳
    self.ame67HeartbeatTimer = nil;

    lastXValue = lastYValue = 0;
    ame67_physDirection = -1;   // Task67：松手即清物理方向（心跳随之静默）
    if (isGrabbing && self.fwdLockView && CGRectContainsPoint(self.fwdLockView.frame, [touches.anyObject locationInView:self])) {
        self.fwdLockView.center = self.thumb.center;
    } else {
        self.thumb.center = self.mCenter;
        [self callbackMoveX:0 Y:0];
    }
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    // Task67：系统打断（手势冲突/来电/切换 app）同样停心跳 + 复位摇杆。
    // 旧代码无 touchesCancelled：打断后 thumb 停在偏位、WASD 可能滞留。
    [self.ame67HeartbeatTimer invalidate];
    self.ame67HeartbeatTimer = nil;
    ame67_physDirection = -1;   // Task67：打断同样清物理方向
    if (!isControlModifiable) {
        self.thumb.center = self.mCenter;
        [self callbackMoveX:0 Y:0];
    }
}

- (void)callbackMoveX:(CGFloat)xValue Y:(CGFloat)yValue {
#ifdef DEBUG_JOYSTICK
    static UILabel *debugLabel;
    if (debugLabel == nil) {
        debugLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 200)];
        debugLabel.lineBreakMode = NSLineBreakByWordWrapping;
        debugLabel.numberOfLines = 0;
        debugLabel.userInteractionEnabled = NO;
        [UIWindow.mainWindow addSubview:debugLabel];
    }
#endif

    if (!isGrabbing) {
        // Update virtual mouse position
        lastXValue = xValue;
        lastYValue = yValue;
        return;
    }

    // Task66：lastDirection 提升为文件级 ame66_joystickLastDirection，
    // 抓取切换沿可复位（见文件头 AmeControlJoystickOnGrabChange）
    char lastDirection = ame66_joystickLastDirection;
    char direction = -1;
    // Task223 上游同步（upstream 3a2116c05 / Flux 同款）：沿轴正推时必有一
    // 分量为 0，要求两分量都非零会把四正方向误判为回中。这里测的是"偏离
    // 中心"，任一分量非零即成立。
    if (xValue != 0 || yValue != 0) {
        CGFloat degree = atan2f(yValue, xValue) * (180.0 / M_PI);
        if (degree < 0) {
            degree += 360;
        }
        direction = (int)((degree+22.5)/45.0) % 8;
#ifdef DEBUG_JOYSTICK
        debugLabel.text = [NSString stringWithFormat:@"x=%f\ny=%f\natan=%f\ndeg=%f\ndirection=%d, last=%d\npressW=%d A=%d S=%d D=%d", atan2f(yValue, xValue), xValue, yValue, degree, direction, lastDirection,
            direction >= DIRECTION_NORTH_EAST &&
            direction <= DIRECTION_NORTH_WEST,
            direction >= DIRECTION_NORTH_WEST &&
            direction <= DIRECTION_SOUTH_WEST,
            direction >= DIRECTION_SOUTH_WEST &&
            direction <= DIRECTION_SOUTH_EAST,
            direction == DIRECTION_SOUTH_EAST ||
            direction == DIRECTION_EAST ||
            direction == DIRECTION_NORTH_EAST];
#endif
    }
    // Task67：物理方向实时更新（含归零 -1），供心跳与重抓沿重断言使用。
    // 放在去重检查之前——方向即使没变，物理状态也可能需要被重新确认。
    ame67_physDirection = direction;
    if (lastDirection == direction) {
        return;
    }

    // Update WASD states（Task67：抽入 ame67_sendDirectionKeys，与心跳共用）
    int mod = leftShiftHeld ? GLFW_MOD_SHIFT : 0;
    ame67_sendDirectionKeys(direction, mod);

    self.fwdLockView.hidden = direction != DIRECTION_NORTH;
    ame66_joystickLastDirection = direction;
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    self.mCenter = CGPointMake(frame.size.width/2, frame.size.height/2);
    CGFloat minSize = MIN(frame.size.width, frame.size.height);

    self.fwdLockView.frame = CGRectMake(0, 0, minSize/4, minSize/4);
    [self.fwdLockView setImage:[UIImage systemImageNamed:@"lock"] forState:UIControlStateNormal];
    self.fwdLockView.layer.cornerRadius = self.fwdLockView.frame.size.width/2;

    self.thumb.frame = CGRectMake(0, 0, minSize/4, minSize/4);
    self.thumb.center = self.mCenter;
    self.thumb.layer.cornerRadius = self.thumb.frame.size.width/2;

    CGFloat bgSize = minSize - self.thumb.frame.size.width + self.background.layer.borderWidth/2;
    self.background.frame = CGRectMake(0, 0, bgSize, bgSize);
    self.background.layer.cornerRadius = bgSize/2;
    self.background.center = self.mCenter;
}

- (void)update {
    NSAssert(self.superview != nil, @"should not be nil");

    self.displayInGame = [self.properties[@"displayInGame"] boolValue];
    self.displayInMenu = [self.properties[@"displayInMenu"] boolValue];

    // net/kdt/pojavlaunch/customcontrols/ControlData.update()
    [self preProcessProperties];

    NSString *propDynamicX = (NSString *) self.properties[@"dynamicX"];
    NSString *propDynamicY = (NSString *) self.properties[@"dynamicY"];

    CGFloat propW = [self.properties[@"width"] floatValue];
    CGFloat propH = [self.properties[@"height"] floatValue];
    float propStrokeWidth = [self.properties[@"strokeWidth"] floatValue];
    int propBackgroundColor = [self.properties[@"bgColor"] intValue];
    int propStrokeColor = [self.properties[@"strokeColor"] intValue];

    self.background.backgroundColor = self.fwdLockView.backgroundColor = convertARGB2UIColor(propBackgroundColor);
    self.background.layer.borderColor = [convertARGB2UIColor(propStrokeColor) CGColor];
    self.background.layer.borderWidth = propStrokeWidth + 1;

    // Calculate dynamic position
    CGFloat propX = [self calculateDynamicPos:propDynamicX];
    CGFloat propY = [self calculateDynamicPos:propDynamicY];

    // Update other properties
    self.frame = CGRectMake(propX, propY, propW, propH);
    self.alpha = [self.properties[@"opacity"] floatValue];
    self.alpha = MAX(self.alpha, isControlModifiable ? 0.1 : 0.01);
    self.layer.cornerRadius = MIN(self.frame.size.width, self.frame.size.height) / 2.0;
}

@end
