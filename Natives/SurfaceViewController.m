#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import "authenticator/BaseAuthenticator.h"
#import "customcontrols/ControlButton.h"
#import "customcontrols/ControlDrawer.h"
#import "customcontrols/ControlSubButton.h"
#import "customcontrols/CustomControlsUtils.h"

#import "input/ControllerInput.h"
#import "input/GyroInput.h"
#import "input/KeyboardInput.h"

#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "utils.h"
#import "GameMenuOverlayView.h"
#import "TrackedTextField.h"
#import "TouchControllerBridge.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "LanPortDetector.h"
#import "BackgroundManager.h"
// Task 166：MobileGL DirectVulkan 的 Metal 层 FSR1（updateSavedResolution 钩子）。
#import "ctxbridges/mgl_metal_fsr.h"
// ZeroTier/Terracotta 联机暂时移除（排查启动崩溃）
// #import "MultiplayerManager.h"

#include "glfw_keycodes.h"
#include "utils.h"

#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/task_info.h>

// --- [START] TouchController Mod Support ---
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>

#define TC_MOD_PORT 12450

@interface TouchSender : NSObject {
    int _sock;
    struct sockaddr_in6 _target;
}
- (void)sendType:(int32_t)type id:(int32_t)fingerId x:(float)x y:(float)y;
@end

@implementation TouchSender

- (instancetype)init {
    self = [super init];
    if (self) {
        _sock = socket(AF_INET6, SOCK_DGRAM, 0);
        if (_sock < 0) {
            NSLog(@"[TouchController] Error: Failed to create socket");
        } else {
            // Increase send buffer size to reduce packet loss
            int sendBufSize = 256 * 1024; // 256KB
            if (setsockopt(_sock, SOL_SOCKET, SO_SNDBUF, &sendBufSize, sizeof(sendBufSize)) < 0) {
                NSLog(@"[TouchController] Warning: Failed to set send buffer size: %s", strerror(errno));
            }

            // Non-blocking mode
            int flags = fcntl(_sock, F_GETFL, 0);
            fcntl(_sock, F_SETFL, flags | O_NONBLOCK);

            memset(&_target, 0, sizeof(_target));
            _target.sin6_family = AF_INET6;
            _target.sin6_port = htons(TC_MOD_PORT);
            // Connect to localhost IPv6 ::1
            if (inet_pton(AF_INET6, "::1", &_target.sin6_addr) <= 0) {
                NSLog(@"[TouchController] Error: Invalid IPv6 address");
            } else {
                NSLog(@"[TouchController] Sender ready on port %d", TC_MOD_PORT);
            }
        }
    }
    return self;
}

- (void)dealloc {
    if (_sock >= 0) close(_sock);
}

- (void)sendType:(int32_t)type id:(int32_t)fingerId x:(float)x y:(float)y {
    if (_sock < 0) return;

    struct {
        int32_t type;
        int32_t id;
        int32_t x;
        int32_t y;
    } packet;

    packet.type = htonl(type);
    packet.id = htonl(fingerId);

    // Float to Int bits (Big Endian)
    union { float f; int32_t i; } ux, uy;
    ux.f = x;
    uy.f = y;
    packet.x = htonl(ux.i);
    packet.y = htonl(uy.i);

    
    size_t length = (type == 2) ? 8 : 16;

    // ä¼åéè¯æºå¶ï¼åå°éè¯æ¬¡æ°ï¼é¿åä¸å¿è¦çå»¶è¿
    int maxRetries = (type == 2) ? 2 : 1;
    int retry;
    ssize_t sent = -1;

    for (retry = 0; retry < maxRetries; retry++) {
        sent = sendto(_sock, &packet, length, 0, (struct sockaddr *)&_target, sizeof(_target));
        if (sent == length) {
            // åéæå
            break;
        } else if (sent < 0) {
            int err = errno;
            if (err == EAGAIN || err == EWOULDBLOCK) {
                // ç¼å²åºæ»¡ï¼ç­æä¼ç åéè¯
                usleep(500); // åå°ä¼ç æ¶é´å°0.5æ¯«ç§
                continue;
            } else {
                // å¶ä»éè¯¯ï¼è®°å½å¹¶éåºéè¯
                NSLog(@"[TouchController] Error: sendto failed: %s (type=%d, id=%d)", strerror(err), type, fingerId);
                break;
            }
        } else {
            // é¨ååéï¼çè®ºä¸ä¸ä¼åçï¼ï¼è®°å½å¹¶éè¯
            NSLog(@"[TouchController] Warning: partial send: %zd of %zu bytes", sent, length);
            usleep(500); // åå°ä¼ç æ¶é´å°0.5æ¯«ç§
        }
    }

    if (sent != length) {
        NSLog(@"[TouchController] Error: failed to send packet after %d retries (type=%d, id=%d)", maxRetries, type, fingerId);
    }
}
@end

#pragma mark - PLDisplayLinkTarget
// CADisplayLink 回调 target 类
//
// 关键修复（Vulkan FPS 显示无效）：
// 之前使用 [CADisplayLink displayLinkWithTarget:block selector:@selector(invoke)]
// 传递 block，但 block 的 invoke 方法签名 -(void)invoke 与 CADisplayLink 期望的
// -(void)selector:(CADisplayLink*)link 签名不匹配，导致回调不触发。
// 此类提供正确签名的 displayLinkTick: 方法，确保 CADisplayLink 回调正确触发。
@interface PLDisplayLinkTarget : NSObject
@property(nonatomic, assign) BOOL isVulkanMode;  // 配置预期 Vulkan 路径（仅诊断日志用，实际决策由 pojavIsActualVulkanPath() 运行时判定）
@property(nonatomic, assign) NSUInteger tickCount;  // 诊断用：累计 tick 次数
@end

@implementation PLDisplayLinkTarget

- (instancetype)initWithVulkanMode:(BOOL)isVulkanMode {
    self = [super init];
    if (self) {
        _isVulkanMode = isVulkanMode;
        _tickCount = 0;
    }
    return self;
}

// CADisplayLink 回调方法（正确签名：带 CADisplayLink* 参数）
//
// 关键修复（Vulkan/MoltenVK+OpenGL FPS 显示错误）：
// 之前用 viewDidLoad 时的静态字符串推断（isVulkanMode）决定是否递增 FPS 计数器，
// 但 graphicsApi=default 由 MC 内部决定，无法预判；且 MC 实际选择可能与配置不符。
// 现在每帧动态查询 pojavIsActualVulkanPath()（读 clientAPI == GLFW_NO_API），
// 与 MC 真实渲染路径一致，避免：
//   - 双重计数：Vulkan 渲染器但 MC 选 GL 路径，pojavSwapBuffers + displayLink 都计数
//   - 漏计数：graphicsApi=prefer_opengl 但 MC 走 Vulkan，displayLink 未启用 fallback
- (void)displayLinkTick:(CADisplayLink *)link {
    [GyroInput tick];
    [ControllerInput tick];
    // 动态判定：仅当 MC 真实走 Vulkan 路径时才递增 FPS 计数器
    BOOL actualVulkanPath = pojavIsActualVulkanPath();
    if (actualVulkanPath) {
        pojavIncrementFpsCounter();
    }
    _tickCount++;
    // 诊断日志：前 5 次回调 + 状态切换时输出，便于追踪 clientAPI 变化
    static BOOL s_lastActualVulkanPath = NO;
    BOOL stateChanged = (s_lastActualVulkanPath != actualVulkanPath);
    if (_tickCount <= 5 || stateChanged) {
        NSLog(@"[PLDisplayLinkTarget] displayLinkTick #%lu (configuredVulkan=%d, actualVulkanPath=%d, stateChanged=%d)",
              (unsigned long)_tickCount, _isVulkanMode, actualVulkanPath, stateChanged);
        s_lastActualVulkanPath = actualVulkanPath;
    }
}

@end

// --- [START] TouchController Static Library Support ---
// ProxyMessage ç±»åå®ä¹ (åè TouchController-iOSTest)
#define PROXY_MESSAGE_TYPE_ADD_POINTER 1
#define PROXY_MESSAGE_TYPE_REMOVE_POINTER 2
#define PROXY_MESSAGE_TYPE_VIBRATE 4
#define PROXY_MESSAGE_TYPE_INPUT_STATUS 7
#define PROXY_MESSAGE_TYPE_INPUT_CURSOR 9
#define PROXY_MESSAGE_TYPE_INPUT_AREA 11
#define PROXY_MESSAGE_TYPE_MOVE_VIEW 12
#define PROXY_MESSAGE_TYPE_CAPABILITY 5
#define PROXY_MESSAGE_TYPE_KEYBOARD_SHOW 8
#define PROXY_MESSAGE_TYPE_INITIALIZE 10

// Vibrate ç±»å
#define VIBRATE_KIND_BLOCK_BROKEN 0

// --- [END] TouchController Static Library Support ---

int memorystatus_control(uint32_t command, int32_t pid, uint32_t flags, void *buffer, size_t buffersize);
#define MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT        6

static int currentHotbarSlot = -1;
static GameSurfaceView* pojavWindow;

// Task171：键盘主动收起代数（定义与用法见 Input: on-surface functions 区
// 的 ame171_armKeyboardRecheck；此处前置声明供 updateGrabState 等早于定义
// 的收起点使用）。
static NSUInteger ame171_keyboardDismissGeneration = 0;

// Task 78：FSR 预设 → 渲染缩放系数（与 MobileGlues-cpp FSR1.cpp
// CalculateTargetResolution 的 scale 表同步：UQ=1.3 / Q=1.5 / B=1.7 / P=2.0）。
// Task 83（FSR 独立化）：不再仅限 MobileGlues——见 ame83_fsr_capable_renderer。
static float ame78_fsr_preset_scale(NSInteger preset) {
    switch ((int)preset) {
        case 1: return 1.3f;   // UltraQuality：渲染 77%
        case 2: return 1.5f;   // Quality：渲染 67%
        case 3: return 1.7f;   // Balanced：渲染 59%
        case 4: return 2.0f;   // Performance：渲染 50%
        default: return 1.0f;  // Disabled
    }
}

// Task 83（FSR 独立化）：当前渲染器能否吃下 FSR 联动（MC 窗口=表面/档位
// 系数 + 呈现前升采样）。不能升采样的渲染器若也缩窗口，画面会缩到左下角
// （Task82 同款症状），所以能力表与升采样实现一一对应：
//   - MobileGlues：内置 FSR1（egl frontend，Task78-82 已验证）
//   - zink（libOSMesa）：osm_bridge EASU（GL 4.6 compat，复用 MG 同款
//     #version 450 EASU shader，本 Task 新增）
//   - Vulkan 渲染器（libMoltenVK）：不联动。纯 Vulkan 路径无呈现钩子
//     （vkQueuePresent 由 MC 自管）；而 ≤26.2 的 GL 回退路径走 ANGLE
//     （非 MG）也无法升采样——两种形态下缩窗口都会得到“画面缩在角落”
//     （Task82 同款症状）。需要 FSR 请选 MobileGlues / Zink。
//   - auto/gl4es：GLES2 后端（无 VAO/ES3）——暂不接入
//   - tinygl4angle/LTW/Mithril：gl_bridge 侧接入留待后续
//   - MobileGL（libMobileGL.dylib，DirectVulkan/DirectGLES 共体）：Task154
//     全链退休，恢复 da5918a（5.1.0 正常态）语义——【不联动 FSR】。
//     退休病历（7c32bc3 双会话，3b35b26 构建实证）：①Task148 的“内置 FSR1”
//     理论被 Task153 strings 证伪（libMobileGL.dylib 无任何 fsr1Setting/
//     FSR1 符号，配置仅 MOBILEGL_* env）——启动器侧链是该二进制上唯一
//     升采样途径；②Task153 的延迟缩窗依赖 eglGetCurrentDisplay/
//     CurrentSurface/QuerySurface，而 libMobileGL 的 EGL 是伪 EGL（句柄
//     0x1，无 current 跟踪）→ 查询恒失败 → “backbuffer query unavailable”
//     → 缩窗永不下发 → MC 窗口信念恒全尺寸，而 sendTouchPoint 仍除
//     mgFsrScale → 触点只落到 MC 坐标空间左下四分之一（输入错位实测）
//     → FSR 也永远无效果；③链在 d36a24f 构建上曾按启动器信念几何面
//     画 EASU/RCAS（2360x1640 视口栅格化进 1180x820 后缓冲）→ 每帧裁
//     切毁帧（Vulkan 花屏 / ES “方块不渲染”）。用户基准（da5918a 装机
//     9f32cb4/1d4ff3a 会话）：MobileGL 直呈全分辨率、无任何启动器侧
//     FSR 介入 = 正常。mgFsrScale 恒 1.0 = 缩窗、输入除法、延迟武装
//     全部天然失效，与 da5918a 逐位对齐。FSR 仍可选 MobileGlues/zink。
//     Task158 更新：mg 的 GLES / OpenGL 4.0 后端已重映射回 MobileGlues
//     （libmobileglues.dylib，5.1.0 用户实际可玩路径——见
//     LauncherPreferences.m 的 ame_effective_renderer mg 分支），本函数
//     对其返回 YES → FSR 档位联动随 mobileglues.fsr1_setting 恢复，
//     与 5.1.0 装机日志（latestlog.es / latestlog.4.0，fsr1Setting=4、
//     MC 渲染窗口=surface/2.00、exit(0) 正常退出）逐位同款。Vulkan 直连
//     后端（libMobileGL.dylib）维持不联动。
static BOOL ame83_fsr_capable_renderer(NSString *renderer) {
    if (renderer.length == 0) return NO;
    if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) return YES;
    if ([renderer hasPrefix:@"libOSMesa"]) return YES;
    // Task 166：mg 的 Vulkan 后端（libMobileGL.dylib，DirectVulkan）重新
    // 纳入 FSR 联动——升采样由 Task166 的 Metal 层 FSR1 承担（双
    // CAMetalLayer 交换层拦截：render-res swapchain -> Metal EASU+RCAS
    // -> 全分辨率显示层，MobileGL/MoltenVK 二进制零改动）。Task154 的
    // 退休针对的是 mgl_fsr.mm 的【预交换 GL 链】（伪 EGL 无 current 跟踪
    // -> 信念几何失配 -> 花屏/输入错位）；Task166 的战场在 Metal 呈现端，
    // 几何不再依赖启动器信念（EGL attribs = windowWidth 单点下发，输入
    // 除法与缩窗同源同步），Task154 病历的三重形态均不再可达。
    // -gles 变体（DirectGLES）维持不联动（保守范围，用户指令只要求
    // Vulkan）。
    if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGL]) return YES;
    // Task 154：MobileGL-gles 后端退出 FSR 联动（见上方退休病历）——
    // isMobileGLRenderer 命中 -gles 时维持 1.0（不缩窗、不除输入）。
    if (isMobileGLRenderer(renderer.UTF8String)) return NO;
    return NO;
}

// ============================================================================
// Task156：TouchController 文本输入的 IME（拼音等输入法）组字感知。
//
// 病历：设备 iPadOS 27.0 报“输入法无法正常输入”。touchControllerTextField
// 原是纯 UITextField：① IME 组字（marked text）更新在 iOS 27 上不触发
// UIControlEventEditingChanged，mod 侧看不到组字过程；② sendTextInputStatus
// 硬编码 compositionStart/Length = 0，mod 把拼音字母当已提交文本。子类化后：
// 组字更新同样回调 didChange；状态上报真实 markedTextRange 边界，mod 可
// 正确渲染组字下划线/候选替换。
// ============================================================================
@interface Ame156TCIMEAwareTextField : UITextField
@end

@implementation Ame156TCIMEAwareTextField
- (void)setAttributedMarkedText:(NSAttributedString *)markedText selectedRange:(NSRange)selectedRange {
    [super setAttributedMarkedText:markedText selectedRange:selectedRange];
    // 组字更新也走 didChange → sendTextInputStatus（EditingChanged 对 marked
    // text 不触发，iOS 27 实测）；sendActions 与系统触发路径同队列，无重入风险。
    [self sendActionsForControlEvents:UIControlEventEditingChanged];
}
@end

@interface SurfaceViewController ()<UITextFieldDelegate, UIGestureRecognizerDelegate> {
    // Task 78：MobileGlues FSR 渲染分辨率联动系数（1.0=关闭/非 MG）。
    // updateSavedResolution 每次重算（旋转/分辨率变更安全）；sendTouchPoint
    // 等输入换算读取它保持与 MC 窗口信念（windowWidth）同口径。
    float mgFsrScale;
}
// Task 139：FSR 兜底自愈后的输入缩放复位（C 入口
// ame139_fsr_heal_reset_input_scale 经主线程转发到本方法；ivar 私有，
// 类扩展外的 C 函数不可直接访问——e7632b3 CI 教训）。
- (void)ame139_resetFsrInputScale;

// FPS/内存监控相关（FPS 在 native pojavSwapBuffers 中计数，参照 FCL/ZL2）
@property(nonatomic) NSTimer *statsTimer;                 // 低频定时器，1s 一次
@property(nonatomic) CADisplayLink *statsDisplayLink;     // 渲染循环引用（用于 Gyro/Controller tick 和失效）
@property(nonatomic, strong) id statsDisplayLinkTarget;   // CADisplayLink 的 target（强引用防释放）

@property(nonatomic) NSDictionary* metadata;
@property(nonatomic) TrackedTextField *inputTextField;
@property(nonatomic) NSMutableArray* swipeableButtons;
@property(nonatomic) ControlButton* swipingButton;
@property(nonatomic) UITouch *primaryTouch, *hotbarTouch;

@property(nonatomic) UILongPressGestureRecognizer* longPressGesture, *longPressTwoGesture;
@property(nonatomic) UITapGestureRecognizer *tapGesture, *doubleTapGesture;
// TouchController 移动视角手势：右半区单指滑动
@property(nonatomic) UIPanGestureRecognizer *moveViewPanGesture;

@property(nonatomic) id mouseConnectCallback, mouseDisconnectCallback;
@property(nonatomic) id controllerConnectCallback, controllerDisconnectCallback;
// 关键修复（UI 累积异常）：MousePointerUpdated 块观察者之前未存储，
// 无法在 dealloc 中移除，导致每次进出游戏都泄漏一个观察者 + 对 self 的强引用。
// 现存为属性，dealloc 中统一移除。
@property(nonatomic) id mousePointerUpdatedCallback;

@property(nonatomic) CGFloat screenScale;
@property(nonatomic) CGFloat mouseSpeed;
@property(nonatomic) CGRect clickRange;
@property(nonatomic) BOOL isMacCatalystApp, shouldHideControlsFromRecording,
    shouldTriggerClick, shouldTriggerHaptic, slideableHotbar, toggleHidden;

@property(nonatomic) BOOL enableMouseGestures, enableHotbarGestures;

// Task202（议题 #1）：双指滚动手势进行中标记——cancelsTouchesInView=NO
// 让双指同时喂进了光标移动路径（滚动时虚拟鼠标光标跟着跑）。手势
// Began/Changed 置位，Ended/Cancelled 异步清除（手势 Ended 先于同批
// touchesEnded 派发，同步清会让尾批 MOVE 逃逸出抑制窗）。
@property(nonatomic) BOOL ame202ScrollGestureActive;

@property(nonatomic) UIImpactFeedbackGenerator *lightHaptic;
@property(nonatomic) UIImpactFeedbackGenerator *mediumHaptic;

@property(nonatomic, strong) TouchSender *touchSender;
@property(nonatomic) long long touchControllerTransportHandle;

// TouchController Text Input Support
@property(nonatomic, strong) UITextField *touchControllerTextField;
@property(nonatomic) BOOL touchControllerTextInputEnabled;

// 阶段13/16：启动遮罩层（参照 FCL/ZL2 的启动进度显示，JVM 启动到首帧渲染期间显示）
//
// 重要设计说明（参照 FCL/ZL2）：
//   launchOverlayView 的 userInteractionEnabled 必须为 NO，使其不拦截触摸事件。
//   这样视图层级下方的 gameMenuOverlay（悬浮球 + FPS 显示）在启动期间仍可
//   被用户拖动和点击。这是 FCL/ZL2 的做法——启动遮罩层是纯视觉层，不参与
//   交互。所有子控件（图标、进度条、文字）均为展示型，不需要接收触摸。
//
//   视图层级（从下到上）：
//     rootView (游戏渲染表面)
//       → menuView (底部弹出菜单)
//         → menuDimView (菜单背景遮罩)
//           → gameMenuOverlay (悬浮球 + FPS 显示) ← 需要可交互
//             → launchOverlayView (启动遮罩层) ← userInteractionEnabled = NO
//
//   触摸事件流程：
//     1. 用户触摸屏幕 → UIKit 从最顶层 view 开始 hitTest
//     2. launchOverlayView.userInteractionEnabled = NO → hitTest 返回 nil
//     3. 触摸穿透到 gameMenuOverlay
//     4. gameMenuOverlay.hitTest 检查是否命中 menuButton/statsLabel
//        - 命中 → 返回对应控件，用户可拖动/点击
//        - 未命中 → 返回 nil，触摸继续穿透到游戏画面
@property(nonatomic, strong) UIView *launchOverlayView;
@property(nonatomic, strong) CAGradientLayer *launchGradientLayer;
@property(nonatomic, strong) UIActivityIndicatorView *launchSpinner;
@property(nonatomic, strong) UILabel *launchTitleLabel;
// ★ Task222（清单第 16 项）：高级启动进度（阶段文案 + 微光进度条 + 耗时 + 信息胶囊）
@property(nonatomic, strong) UILabel *launchStageLabel;
@property(nonatomic, strong) UIView *launchProgressTrack;
@property(nonatomic, strong) UIView *launchProgressBar;
@property(nonatomic, strong) UILabel *launchElapsedLabel;
@property(nonatomic, strong) UILabel *launchInfoLabel;
@property(nonatomic, strong) NSTimer *launchStageTimer;
@property(nonatomic, assign) NSInteger launchStageIndex;
@property(nonatomic, assign) NSTimeInterval launchStartTime;
@property(nonatomic, assign) BOOL launchOverlayDismissed;
@property(nonatomic, strong) UIButton *launchCancelButton;     // 取消启动按钮

@end

// Forward declaration: findSDL_uikitview is defined further down this file
// (after the @implementation block, near touchesBegan). Declaring it here
// avoids an implicit-declaration warning when pressesBegan/pressesEnded
// forward physical keyboard events to the embedded SDL_uikitview.
static UIView *findSDL_uikitview(UIView *root);

// Task 139：FSR 渲染兜底自愈的输入侧复位入口。
//
// 病历（23:08 MobileGL-gles 装机会话实锤）：mgl_fsr 的 Task119 兜底在
// EASU 不可用时把 MC 窗口恢复为全表面分辨率（nativeSendScreenSize 会
// 同步全局 windowWidth/windowHeight），MC 随即按全分辨率渲染（viewport
// 2360x1640 证据）——但 sendTouchPoint 的输入换算仍除以 mgFsrScale(2.0)，
// 触点坐标只发了一半，落在 MC 全分辨率窗口信念的四分之一处 = 用户看到
// 的"mg 渲染器输入错位"。osm_bridge 的 Task83b 兜底同款隐患。
//
// 修法：两个兜底点在恢复窗口尺寸后调用本函数，把 mgFsrScale 归一。
// ivar 是类扩展私有（C 函数不可直接访问——e7632b3 CI 教训），实际复位由
// 同类内的 ame139_resetFsrInputScale 方法执行；本函数是唯一外部入口
// （主线程派发，与 UI/输入事件线程归属一致，无竞态）。
void ame139_fsr_heal_reset_input_scale(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIViewController *vc = UIWindow.mainWindow.rootViewController;
            if (![vc isKindOfClass:SurfaceViewController.class]) {
                // 游戏中 root 一定是 SurfaceViewController；防御其它形态
                return;
            }
            [(SurfaceViewController *)vc ame139_resetFsrInputScale];
        } @catch (NSException *e) {
            NSLog(@"[SurfaceVC] Task139: FSR heal reset exception: %@", e);
        }
    });
}

@implementation SurfaceViewController

// Task 139：FSR 兜底自愈的输入缩放复位（方法体内可访问私有 ivar）。
- (void)ame139_resetFsrInputScale {
    if (mgFsrScale > 1.0f) {
        NSLog(@"[SurfaceVC] Task139: FSR heal -- input scale reset (%.2f -> 1.00; MC window was restored to full surface)",
              (double)mgFsrScale);
        mgFsrScale = 1.0f;
    }
}

#pragma mark - TouchController Static Library Support

// å¯å¨ TouchController æ¶æ¯æ¥æ¶å¾ªç¯
- (void)startTouchControllerMessageLoop {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Bug fix: 当 VC 被 dealloc 后 weakSelf 变为 nil，
        // nil 的属性访问返回 0（不是负数），导致 0 >= 0 为 true 循环永不终止。
        // 必须先检查 weakSelf 本身是否为 nil。
        while (weakSelf && weakSelf.touchControllerTransportHandle >= 0 && ![weakSelf isViewDismissed]) {
            @autoreleasepool {
                NSMutableData *buffer = [NSMutableData dataWithLength:256];
                int result = [TouchControllerBridge receiveFromTransport:weakSelf.touchControllerTransportHandle buffer:buffer];

                if (result > 0) {
                    [buffer setLength:result];
                    [weakSelf processTouchControllerMessage:buffer];
                }

                // ä¼ç  16ms
                usleep(16000);
            }
        }
    });
}

// æ£æ¥è§å¾æ¯å¦å·²å³é­
- (BOOL)isViewDismissed {
    // 修复：self.view.window 和 self.isBeingDismissed 是 UIKit 属性，
    // 必须在主线程访问。从后台线程 TouchController 循环调用时需 dispatch 到主线程。
    __block BOOL dismissed = NO;
    if ([NSThread isMainThread]) {
        dismissed = !self.view.window || self.isBeingDismissed;
    } else {
        dispatch_sync(dispatch_get_main_queue(), ^{
            dismissed = !self.view.window || self.isBeingDismissed;
        });
    }
    return dismissed;
}

// ç¼ç  ProxyMessage: AddPointerMessage (type=1, index=int32, x=float, y=float)
- (NSData *)encodeAddPointerMessage:(int32_t)index x:(float)x y:(float)y {
    NSMutableData *data = [NSMutableData dataWithCapacity:16];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_ADD_POINTER);
    int32_t indexBE = htonl(index);

    // å° float è½¬æ¢ä¸ºç½ç»å­èåº
    union { float f; uint32_t i; } ux, uy;
    ux.f = x;
    uy.f = y;
    uint32_t xBE = htonl(ux.i);
    uint32_t yBE = htonl(uy.i);

    [data appendBytes:&type length:4];
    [data appendBytes:&indexBE length:4];
    [data appendBytes:&xBE length:4];
    [data appendBytes:&yBE length:4];

    return data;
}

// ç¼ç  ProxyMessage: RemovePointerMessage (type=2, index=int32)
- (NSData *)encodeRemovePointerMessage:(int32_t)index {
    NSMutableData *data = [NSMutableData dataWithCapacity:8];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_REMOVE_POINTER);
    int32_t indexBE = htonl(index);

    [data appendBytes:&type length:4];
    [data appendBytes:&indexBE length:4];

    return data;
}

// åé ProxyMessage å° TouchController éæåº
- (void)sendTouchControllerProxyMessage:(int32_t)index x:(float)x y:(float)y isRemove:(BOOL)isRemove {
    NSData *messageData;

    if (isRemove) {
        messageData = [self encodeRemovePointerMessage:index];
    } else {
        messageData = [self encodeAddPointerMessage:index x:x y:y];
    }

    if (self.touchControllerTransportHandle >= 0 && messageData) {
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }

    // Task 139：静态库模式双发 —— mod 0.3.1-alpha14 的 iOS 静态分支是上游
    // 半成品（Task135 判读：创建 IosPlatform 后不 return，probeNativeLibraryInfo
    // 落入 Cocoa/Unknown 返回 null），启动器为此设置了 TOUCH_CONTROLLER_PROXY
    // 环境变量让 mod 自动回落 legacy UDP 通道。但本方法此前【只发 native 单例
    // 通道】——mod 在 UDP 通道上等，事件全发进了没人读的 ring buffer，进世界
    // 后触控全灭（菜单阶段因启动器直发输入链路兜底而幸存，造成"菜单能点、
    // 游戏内失灵"的假象）。两通道线格式逐字节一致（type/id/x/y 大端 16/8B），
    // 同一事件同时投递：当前 alpha14 走 UDP 收到；未来 mod 修好静态分支用
    // 新 ABI 时走 native 收到；mod 只在其中一个通道监听，不会重复消费。
    if (self.touchSender) {
        if (isRemove) {
            [self.touchSender sendType:2 id:index x:0 y:0];
        } else {
            [self.touchSender sendType:1 id:index x:x y:y];
        }
    }
}

#pragma mark - TouchController Text Input Support

// ç¼ç  InputStatusMessage (type=7)
- (NSData *)encodeInputStatusMessageWithText:(NSString *)text
                              compositionStart:(int)compositionStart
                              compositionLength:(int)compositionLength
                              selectionStart:(int)selectionStart
                              selectionLength:(int)selectionLength
                              selectionLeft:(BOOL)selectionLeft {
    if (!text) {
        // æ æ°æ®ï¼åªåé type + 0
        int32_t type = htonl(7);
        NSMutableData *data = [NSMutableData dataWithCapacity:1];
        [data appendBytes:&type length:4];
        uint8_t hasData = 0;
        [data appendBytes:&hasData length:1];
        return data;
    }

    // å° UTF-16 è½¬æ¢ä¸º UTF-8
    NSData *textData = [text dataUsingEncoding:NSUTF8StringEncoding];
    const char *textBytes = (const char *)[textData bytes];
    int textLength = (int)[textData length];

    // è®¡ç® UTF-8 ä½ç½®
    NSString *prefix = [text substringToIndex:compositionStart];
    NSData *prefixData = [prefix dataUsingEncoding:NSUTF8StringEncoding];
    int compositionStartUtf8 = (int)[prefixData length];

    NSString *compSegment = [text substringWithRange:NSMakeRange(compositionStart, compositionLength)];
    NSData *compData = [compSegment dataUsingEncoding:NSUTF8StringEncoding];
    int compositionLengthUtf8 = (int)[compData length];

    NSString *selPrefix = [text substringToIndex:selectionStart];
    NSData *selPrefixData = [selPrefix dataUsingEncoding:NSUTF8StringEncoding];
    int selectionStartUtf8 = (int)[selPrefixData length];

    NSString *selSegment = [text substringWithRange:NSMakeRange(selectionStart, selectionLength)];
    NSData *selData = [selSegment dataUsingEncoding:NSUTF8StringEncoding];
    int selectionLengthUtf8 = (int)[selData length];

    // ç¼ç æ¶æ¯
    NSMutableData *data = [NSMutableData dataWithCapacity:5 + textLength + 17];
    int32_t type = htonl(7);
    [data appendBytes:&type length:4];

    uint8_t hasDataFlag = 1;
    [data appendBytes:&hasDataFlag length:1];

    int32_t textLengthBE = htonl(textLength);
    [data appendBytes:&textLengthBE length:4];
    [data appendBytes:textBytes length:textLength];

    int32_t compStartBE = htonl(compositionStartUtf8);
    int32_t compLenBE = htonl(compositionLengthUtf8);
    [data appendBytes:&compStartBE length:4];
    [data appendBytes:&compLenBE length:4];

    int32_t selStartBE = htonl(selectionStartUtf8);
    int32_t selLenBE = htonl(selectionLengthUtf8);
    [data appendBytes:&selStartBE length:4];
    [data appendBytes:&selLenBE length:4];

    uint8_t selectionLeftFlag = selectionLeft ? 1 : 0;
    [data appendBytes:&selectionLeftFlag length:1];

    return data;
}

// ç¼ç  InputCursorMessage (type=9)
- (NSData *)encodeInputCursorMessageWithRect:(CGRect)rect {
    NSMutableData *data = [NSMutableData dataWithCapacity:17];
    int32_t type = htonl(9);
    [data appendBytes:&type length:4];

    uint8_t hasData = 1;
    [data appendBytes:&hasData length:1];

    union { float f; uint32_t i; } left, top, width, height;
    left.f = rect.origin.x;
    top.f = rect.origin.y;
    width.f = rect.size.width;
    height.f = rect.size.height;

    uint32_t leftBE = htonl(left.i);
    uint32_t topBE = htonl(top.i);
    uint32_t widthBE = htonl(width.i);
    uint32_t heightBE = htonl(height.i);

    [data appendBytes:&leftBE length:4];
    [data appendBytes:&topBE length:4];
    [data appendBytes:&widthBE length:4];
    [data appendBytes:&heightBE length:4];

    return data;
}

// ç¼ç  InputAreaMessage (type=11)
- (NSData *)encodeInputAreaMessageWithRect:(CGRect)rect {
    NSMutableData *data = [NSMutableData dataWithCapacity:17];
    int32_t type = htonl(11);
    [data appendBytes:&type length:4];

    uint8_t hasData = 1;
    [data appendBytes:&hasData length:1];

    union { float f; uint32_t i; } left, top, width, height;
    left.f = rect.origin.x;
    top.f = rect.origin.y;
    width.f = rect.size.width;
    height.f = rect.size.height;

    uint32_t leftBE = htonl(left.i);
    uint32_t topBE = htonl(top.i);
    uint32_t widthBE = htonl(width.i);
    uint32_t heightBE = htonl(height.i);

    [data appendBytes:&leftBE length:4];
    [data appendBytes:&topBE length:4];
    [data appendBytes:&widthBE length:4];
    [data appendBytes:&heightBE length:4];

    return data;
}

// åéææ¬è¾å¥ç¶æå° TouchController
- (void)sendTextInputStatus {
    if (self.touchControllerTransportHandle < 0) return;

    NSString *text = self.touchControllerTextField.text ?: @"";
    // Task156：上报真实组字（marked text）边界——此前硬编码 0/0，mod 侧把
    // 拼音字母当已提交文本，候选上屏时整段替换异常。markedTextRange 为 nil
    // （无组字）时边界为零，与旧语义一致。
    NSInteger compositionStart = 0, compositionLength = 0;
    UITextRange *markedRange = self.touchControllerTextField.markedTextRange;
    if (markedRange != nil) {
        compositionStart = [self.touchControllerTextField offsetFromPosition:self.touchControllerTextField.beginningOfDocument
                                                                  toPosition:markedRange.start];
        compositionLength = [self.touchControllerTextField offsetFromPosition:markedRange.start
                                                                     toPosition:markedRange.end];
        if (compositionStart < 0 || (NSUInteger)compositionStart > text.length) compositionStart = 0;
        if (compositionLength < 0 || (NSUInteger)(compositionStart + compositionLength) > text.length) compositionLength = 0;
    }
    UITextRange *selectedRange = self.touchControllerTextField.selectedTextRange;
    // Bug fix: 当 TextField 不是 firstResponder 时 selectedTextRange 可能为 nil，
    // 此时 offsetFromPosition:toPosition:nil 会抛出 NSInternalInconsistencyException。
    if (!selectedRange) {
        NSData *messageData = [self encodeInputStatusMessageWithText:text
                                                  compositionStart:(int)compositionStart
                                                  compositionLength:(int)compositionLength
                                                  selectionStart:0
                                                  selectionLength:0
                                                  selectionLeft:NO];
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
        return;
    }
    NSInteger selectionStart = [self.touchControllerTextField offsetFromPosition:self.touchControllerTextField.beginningOfDocument
                                                                  toPosition:selectedRange.start];
    NSInteger selectionLength = [self.touchControllerTextField offsetFromPosition:selectedRange.start
                                                                    toPosition:selectedRange.end];

    NSData *messageData = [self encodeInputStatusMessageWithText:text
                                              compositionStart:(int)compositionStart
                                              compositionLength:(int)compositionLength
                                              selectionStart:(int)selectionStart
                                              selectionLength:(int)selectionLength
                                              selectionLeft:NO];

    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

// åéåæ ä½ç½®ä¿¡æ¯
- (void)sendInputCursorWithRect:(CGRect)rect {
    if (self.touchControllerTransportHandle < 0) return;

    NSData *messageData = [self encodeInputCursorMessageWithRect:rect];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

// åéè¾å¥åºåä¿¡æ¯
- (void)sendInputAreaWithRect:(CGRect)rect {
    if (self.touchControllerTransportHandle < 0) return;

    NSData *messageData = [self encodeInputAreaMessageWithRect:rect];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

#pragma mark - TouchController Vibration Support

// ç¼ç  VibrateMessage (type=4)
- (NSData *)encodeVibrateMessageWithKind:(int32_t)kind {
    NSMutableData *data = [NSMutableData dataWithCapacity:8];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_VIBRATE);
    int32_t kindBE = htonl(kind);

    [data appendBytes:&type length:4];
    [data appendBytes:&kindBE length:4];

    return data;
}

// è§¦åéå¨åé¦
- (void)triggerVibrationWithKind:(int32_t)kind {
    // æ£æ¥éå¨æ¯å¦å¯ç¨
    if (!getPrefBool(@"control.mod_touch_vibrate_enable")) {
        return;
    }

    // è·åéå¨å¼ºåº¦è®¾ç½®
    NSInteger intensity = [getPrefObject(@"control.mod_touch_vibrate_intensity") integerValue];
    if (intensity < 1) intensity = 1;
    if (intensity > 3) intensity = 3;

    // ä½¿ç¨ UIImpactFeedbackGenerator è§¦åéå¨
    UIImpactFeedbackGenerator *feedbackGenerator;
    switch (intensity) {
        case 1: // è½»åº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            break;
        case 2: // ä¸­åº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            break;
        case 3: // éåº¦éå¨
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleHeavy];
            break;
        default:
            feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            break;
    }

    [feedbackGenerator impactOccurred];

    // åæ¶åé VibrateMessage å° TouchController
    if (self.touchControllerTransportHandle >= 0) {
        NSData *messageData = [self encodeVibrateMessageWithKind:kind];
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Capability

// 编码 CapabilityMessage (type=5)
// 格式: 4B type (big endian) + 1B name_len + N B name (UTF-8) + 1B enabled (0/1)
- (NSData *)encodeCapabilityMessageWithName:(NSString *)name enabled:(BOOL)enabled {
    NSData *nameData = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!nameData) {
        NSLog(@"[TouchController] Failed to encode capability name as UTF-8: %@", name);
        return nil;
    }

    uint8_t nameLen = (uint8_t)[nameData length];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_CAPABILITY);
    uint8_t enabledByte = enabled ? 1 : 0;

    NSMutableData *data = [NSMutableData dataWithCapacity:4 + 1 + nameLen + 1];
    [data appendBytes:&type length:4];
    [data appendBytes:&nameLen length:1];
    [data appendBytes:[nameData bytes] length:nameLen];
    [data appendBytes:&enabledByte length:1];

    return data;
}

// 编码 InitializeMessage (type=10)
// 供未来启动器主动初始化使用，当前未调用
- (NSData *)encodeInitializeMessage {
    int32_t type = htonl(PROXY_MESSAGE_TYPE_INITIALIZE);
    return [NSData dataWithBytes:&type length:4];
}

// 在收到 InitializeMessage 后调用，向 Mod 声明启动器支持的能力
- (void)sendCapabilities {
    if (self.touchControllerTransportHandle < 0) {
        NSLog(@"[TouchController] Cannot send capabilities: transport not initialized");
        return;
    }

    // 发送 text_status 能力：声明启动器会通过 InputStatusMessage 上报文本编辑状态
    NSData *textStatusCap = [self encodeCapabilityMessageWithName:@"text_status" enabled:YES];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:textStatusCap];

    // 发送 keyboard_show 能力：声明启动器会响应 KeyboardShowMessage 显示/隐藏键盘
    NSData *keyboardShowCap = [self encodeCapabilityMessageWithName:@"keyboard_show" enabled:YES];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:keyboardShowCap];

    NSLog(@"[TouchController] Sent capabilities: text_status, keyboard_show");
}

#pragma mark - TouchController MoveView Support

// ç¼ç  MoveViewMessage (type=12)
- (NSData *)encodeMoveViewMessageWithScreenBased:(BOOL)screenBased
                                     deltaPitch:(float)deltaPitch
                                      deltaYaw:(float)deltaYaw {
    NSMutableData *data = [NSMutableData dataWithCapacity:13];
    int32_t type = htonl(PROXY_MESSAGE_TYPE_MOVE_VIEW);
    uint8_t screenBasedByte = screenBased ? 1 : 0;

    // å° float è½¬æ¢ä¸ºç½ç»å­èåº
    union { float f; uint32_t i; } up, uy;
    up.f = deltaPitch;
    uy.f = deltaYaw;
    uint32_t pitchBE = htonl(up.i);
    uint32_t yawBE = htonl(uy.i);

    [data appendBytes:&type length:4];
    [data appendBytes:&screenBasedByte length:1];
    [data appendBytes:&pitchBE length:4];
    [data appendBytes:&yawBE length:4];

    return data;
}

// åéç§»å¨è§è§æ¶æ¯
- (void)sendMoveViewWithDeltaPitch:(float)deltaPitch deltaYaw:(float)deltaYaw {
    if (self.touchControllerTransportHandle >= 0) {
        NSData *messageData = [self encodeMoveViewMessageWithScreenBased:YES
                                                              deltaPitch:deltaPitch
                                                               deltaYaw:deltaYaw];
        [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
    }
}

#pragma mark - TouchController Message Receiver

// å¤çä» TouchController æ¥æ¶å°çæ¶æ¯
- (void)processTouchControllerMessage:(NSData *)messageData {
    if (messageData.length < 4) {
        NSLog(@"[TouchController] Message too short: %lu bytes", (unsigned long)messageData.length);
        return;
    }

    int32_t type;
    [messageData getBytes:&type length:4];
    type = ntohl(type);

    switch (type) {
        case PROXY_MESSAGE_TYPE_VIBRATE: {
            if (messageData.length >= 8) {
                int32_t kind;
                [messageData getBytes:&kind range:NSMakeRange(4, 4)];
                kind = ntohl(kind);
                
                // ä½¿ç¨ dispatch_async ç¡®ä¿å¨ä¸»çº¿ç¨ä¸­è°ç¨
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.view && !self.isBeingDismissed) {
                        [self triggerVibrationWithKind:kind];
                    }
                });
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_MOVE_VIEW: {
            if (messageData.length >= 13) {
                uint8_t screenBasedByte;
                int32_t pitchBE, yawBE;
                [messageData getBytes:&screenBasedByte range:NSMakeRange(4, 1)];
                [messageData getBytes:&pitchBE range:NSMakeRange(5, 4)];
                [messageData getBytes:&yawBE range:NSMakeRange(9, 4)];

                BOOL screenBased = (screenBasedByte != 0);
                union { uint32_t i; float f; } up, uy;
                up.i = ntohl(pitchBE);
                uy.i = ntohl(yawBE);

                // MoveView æ¶æ¯éå¸¸æ¯ä»å®¢æ·ç«¯åéå°æå¡ç«¯ç
                // è¿éæä»¬è®°å½æ¥å¿ï¼å®éåºç¨å¯è½éè¦ç¹æ®å¤ç
                NSLog(@"[TouchController] Received MoveView: screenBased=%d, pitch=%.2f, yaw=%.2f",
                      screenBased, up.f, uy.f);
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_INITIALIZE: {
            NSLog(@"[TouchController] Received InitializeMessage, sending capabilities");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.view && !self.isBeingDismissed) {
                    [self sendCapabilities];
                }
            });
            break;
        }
        case PROXY_MESSAGE_TYPE_KEYBOARD_SHOW: {
            if (messageData.length >= 5) {
                uint8_t showByte;
                [messageData getBytes:&showByte range:NSMakeRange(4, 1)];
                BOOL show = (showByte != 0);
                NSLog(@"[TouchController] Received KeyboardShow: show=%d", show);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.view && !self.isBeingDismissed) {
                        if (show) {
                            [self.touchControllerTextField becomeFirstResponder];
                        } else {
                            [self.touchControllerTextField resignFirstResponder];
                        }
                    }
                });
            } else {
                NSLog(@"[TouchController] KeyboardShowMessage too short: %lu bytes", (unsigned long)messageData.length);
            }
            break;
        }
        case PROXY_MESSAGE_TYPE_CAPABILITY: {
            // Mod → launcher 方向的能力协商（未来扩展点）
            // 当前启动器不处理 Mod 声明的能力，仅记录日志
            if (messageData.length >= 6) {
                uint8_t nameLen;
                [messageData getBytes:&nameLen range:NSMakeRange(4, 1)];
                if (messageData.length >= (NSUInteger)(5 + nameLen + 1)) {
                    NSRange nameRange = NSMakeRange(5, nameLen);
                    NSString *capabilityName = [[NSString alloc] initWithData:[messageData subdataWithRange:nameRange] encoding:NSUTF8StringEncoding];
                    uint8_t enabledByte;
                    [messageData getBytes:&enabledByte range:NSMakeRange(5 + nameLen, 1)];
                    NSLog(@"[TouchController] Received Capability: name=%@, enabled=%d", capabilityName, enabledByte != 0);
                } else {
                    NSLog(@"[TouchController] CapabilityMessage too short for declared name length");
                }
            }
            break;
        }
        default: {
            NSUInteger dumpLen = MIN(messageData.length, (NSUInteger)32);
            NSMutableString *hexDump = [NSMutableString string];
            const uint8_t *bytes = (const uint8_t *)[messageData bytes];
            for (NSUInteger i = 0; i < dumpLen; i++) {
                [hexDump appendFormat:@"%02x ", bytes[i]];
            }
            NSLog(@"[TouchController] Unknown message type: %d, length: %lu, hex: %@",
                  type, (unsigned long)messageData.length, hexDump);
            break;
        }
    }
}

// åå§åææ¬è¾å¥å­æ®µ
#pragma mark - GestureRecognizer Delegate

// 仅 moveViewPanGesture 需要特殊判定；其他手势保持默认行为
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self.moveViewPanGesture) {
        // 条件 1: TouchController 必须启用
        if (!getPrefBool(@"control.mod_touch_enable")) return NO;
        // 条件 2: 必须是静态库模式（mode == 2）
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode != 2) return NO;
        // 条件 3: 移动视角开关必须打开
        if (!getPrefBool(@"control.mod_touch_moveview_enable")) return NO;
        // 条件 4: 必须在游戏内（isGrabbing 为 true）
        if (isGrabbing != JNI_TRUE) return NO;
        // 条件 5: 触摸起点必须在 touchView 右半区
        CGPoint location = [gestureRecognizer locationInView:self.touchView];
        if (location.x < self.touchView.bounds.size.width / 2.0) return NO;
        return YES;
    }
    return YES;
}

#pragma mark - TouchController MoveView Gesture

// 处理右半区滑动手势，发送 MoveViewMessage 给 TouchController
- (void)handleMoveViewPanGesture:(UIPanGestureRecognizer *)gesture {
    // 双重检查（防御性编程，即使 gestureRecognizerShouldBegin 返回 YES 也再次验证）
    if (!getPrefBool(@"control.mod_touch_enable")) return;
    if (!getPrefBool(@"control.mod_touch_moveview_enable")) return;
    if (isGrabbing != JNI_TRUE) return;

    UIPanGestureRecognizer *panGesture = (UIPanGestureRecognizer *)gesture;
    CGPoint translation = [panGesture translationInView:self.touchView];

    switch (panGesture.state) {
        case UIGestureRecognizerStateBegan:
            // 起始位置无需特殊处理，translation 已经是相对起点
            break;
        case UIGestureRecognizerStateChanged: {
            // 计算增量视角变化
            // 注意：deltaPitch 对应 Y 轴（上下），deltaYaw 对应 X 轴（左右）
            // 灵敏度系数：将屏幕像素转换为合理的视角变化
            // 1.0 表示 1:1 映射（screenBased=true 时 Mod 端会乘以 sensitivity）
            float deltaPitch = (float)translation.y;
            float deltaYaw = (float)translation.x;
            [self sendMoveViewWithDeltaPitch:deltaPitch deltaYaw:deltaYaw];
            // 重置 translation 为零，让下一帧 delta 是增量而非累计
            [panGesture setTranslation:CGPointZero inView:self.touchView];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            // 清理状态（无需特殊操作，translation 已被重置或手势已结束）
            break;
        default:
            break;
    }
}

- (void)setupTouchControllerTextInput {
    if (!self.touchControllerTextField) {
        // Task156：Ame156TCIMEAwareTextField——IME 组字感知（见类声明处病历）。
        self.touchControllerTextField = [[Ame156TCIMEAwareTextField alloc] initWithFrame:CGRectZero];
        self.touchControllerTextField.hidden = YES;
        self.touchControllerTextField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.touchControllerTextField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.touchControllerTextField.keyboardType = UIKeyboardTypeDefault;
        [self.view addSubview:self.touchControllerTextField];

        // æ·»å ææ¬ååçå¬
        [self.touchControllerTextField addTarget:self
                                          action:@selector(textFieldDidChange:)
                                forControlEvents:UIControlEventEditingChanged];
    }
}

// å¤çææ¬åå
- (void)textFieldDidChange:(UITextField *)textField {
    [self sendTextInputStatus];
}

// æ¾ç¤ºææ¬è¾å¥çé¢
- (void)showTouchControllerTextInput {
    if (!self.touchControllerTextInputEnabled) return;

    [self setupTouchControllerTextInput];
    self.touchControllerTextField.hidden = NO;
    [self.touchControllerTextField becomeFirstResponder];

    // åéè¾å¥åºåä¿¡æ¯
    [self sendInputAreaWithRect:self.touchControllerTextField.frame];

    // åéåå§ææ¬ç¶æ
    [self sendTextInputStatus];
}

// éèææ¬è¾å¥çé¢
- (void)hideTouchControllerTextInput {
    [self.touchControllerTextField resignFirstResponder];
    self.touchControllerTextField.hidden = YES;

    // åéç©ºç¶æä»¥å³é­è¾å¥
    NSData *messageData = [self encodeInputStatusMessageWithText:nil
                                              compositionStart:0
                                              compositionLength:0
                                              selectionStart:0
                                              selectionLength:0
                                              selectionLeft:NO];
    [TouchControllerBridge sendToTransport:self.touchControllerTransportHandle data:messageData];
}

#pragma mark - Initialization

- (instancetype)initWithMetadata:(NSDictionary *)metadata {
    self = [super init];
    if (self) {
        self.metadata = metadata;
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    isControlModifiable = NO;
    self.isMacCatalystApp = NSProcessInfo.processInfo.isMacCatalystApp;
    // Load MetalHUD library
    dlopen("/usr/lib/libMTLHud.dylib", 0);

    // Task176：主线程卡死看门狗（多人游戏打开卡死的取证）。
    // 病历（3b0307b 装机日志 latestlog.2，FO 26.3 mg 会话）：主菜单按 ESC
    // 后点"多人游戏"，全进程骤死（fps 心跳、触摸、渲染全部停摆，用户强
    // 杀）。日志无任何异常帧，无法定位卡点。此看门狗每 5s 用信号量探测
    // 主线程（4s 超时）：连续两轮无响应即落取证日志（NSLog 异步安全，
    // 主线程恢复后补写），下轮装机日志直接钉死卡点是否在 UIKit 主线程。
    // 只取证不干预——不杀进程、不改行为，零回归风险。
    {
        static dispatch_once_t ame176_once;
        dispatch_once(&ame176_once, ^{
            dispatch_source_t ame176_timer = dispatch_source_create(
                DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            dispatch_source_set_timer(
                ame176_timer, DISPATCH_TIME_NOW, 5ull * NSEC_PER_SEC, 0);
            __block volatile int ame176_hangStreak = 0;
            dispatch_source_set_event_handler(ame176_timer, ^{
                dispatch_semaphore_t ame176_sem = dispatch_semaphore_create(0);
                dispatch_async(dispatch_get_main_queue(), ^{
                    dispatch_semaphore_signal(ame176_sem);
                });
                long ame176_rc = dispatch_semaphore_wait(ame176_sem, 4ull * NSEC_PER_SEC);
                if (ame176_rc != 0) {
                    ++ame176_hangStreak;
                    if (ame176_hangStreak == 2) {
                        NSLog(@"[FreezeWatch] Task176: main thread unresponsive >= 8s "
                              @"(2 consecutive 4s probes failed) -- if the game froze "
                              @"just now, this pins the hang to the UIKit main thread");
                    } else if (ame176_hangStreak > 2 && (ame176_hangStreak % 6) == 0) {
                        NSLog(@"[FreezeWatch] Task176: main thread still unresponsive (streak=%d)",
                              ame176_hangStreak);
                    }
                } else {
                    if (ame176_hangStreak >= 2) {
                        NSLog(@"[FreezeWatch] Task176: main thread recovered after streak=%d",
                              ame176_hangStreak);
                    }
                    ame176_hangStreak = 0;
                }
            });
            dispatch_resume(ame176_timer);
        });
    }

    self.lightHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleLight)];
    self.mediumHaptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:(UIImpactFeedbackStyleMedium)];
    
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    BOOL isTVOS = realUIIdiom == UIUserInterfaceIdiomTV;
    if (!isTVOS) {
        [self setNeedsUpdateOfScreenEdgesDeferringSystemGestures];
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }

    // 渲染循环 tick：Gyro/Controller 输入采样（FPS 计数已移至 native pojavSwapBuffers）
    // Vulkan 模式下 MC 不调用 glfwSwapBuffers，FPS 计数器不递增，
    // 使用 CADisplayLink 作为 fallback：每帧触发时递增计数器。
    //
    // 关键修复（Vulkan FPS 显示无效）：
    //   之前使用 [CADisplayLink displayLinkWithTarget:tickInput selector:@selector(invoke)]
    //   传递 block，但 block 的 invoke 方法签名是 -(void)invoke，而 CADisplayLink 期望的
    //   selector 签名是 -(void)selector:(CADisplayLink*)link。签名不匹配导致回调不触发，
    //   FPS 计数器永远不递增，显示为 0。
    //   修复：使用专门的 target 类 PLDisplayLinkTarget，提供正确签名的回调方法。
    //
    //   另一个问题：currentRenderer 在 viewDidLoad 时从 PLProfiles 读取，但 JavaLauncher.m
    //   可能在启动时修改 AMETHYST_RENDERER 环境变量（如 auto → ANGLE）。
    //   因此同时检查 PLProfiles 和 AMETHYST_RENDERER 环境变量，任一为 Vulkan 即启用 fallback。
    //
    //   关键修复（Vulkan 渲染器 + OpenGL 路径的 FPS 计数）：
    //   当 renderer=libMoltenVK.dylib 但 MC 26.2+ 选 prefer_opengl 时，MC 走 GL 路径
    //   （glfwWindowHint(GLFW_OPENGL_API)），pojavSwapBuffers 会被调用（经 eglSwapBuffers）。
    //   此时不应启用 CADisplayLink fallback，否则会与 pojavSwapBuffers 的 FPS 计数重复。
    //   只有真正的 Vulkan 路径（graphicsApi=prefer_vulkan 且 renderer=libMoltenVK.dylib）
    //   才需要 CADisplayLink fallback，因为 Vulkan 路径不调用 pojavSwapBuffers。
    //
    //   注意（阶段2修复）：此处的 configuredVulkanExpected 仅用于诊断日志（PLDisplayLinkTarget.isVulkanMode），
    //   实际是否启用 fallback 由 displayLinkTick: 内部每帧动态查询 pojavIsActualVulkanPath()
    //   （读 clientAPI == GLFW_NO_API）决定，与 MC 真实渲染路径一致。
    NSString *currentRenderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    NSString *envRenderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    NSString *graphicsApi = NSProcessInfo.processInfo.environment[@"AMETHYST_GRAPHICS_API"];
    BOOL isVulkanRenderer = [currentRenderer isEqualToString:@ RENDERER_NAME_VULKAN] ||
                            [envRenderer isEqualToString:@ RENDERER_NAME_VULKAN];
    // 配置预期 Vulkan 路径：仅用于诊断日志，对比"配置预期"与"MC 实际选择"的差异
    BOOL configuredVulkanExpected = isVulkanRenderer &&
        ![graphicsApi isEqualToString:@"prefer_opengl"] &&
        ![graphicsApi isEqualToString:@"opengl"];
    NSLog(@"[SurfaceViewController] FPS counter setup: profileRenderer=%@, envRenderer=%@, graphicsApi=%@, isVulkan=%d, configuredVulkanExpected=%d (actual path decided at runtime via pojavIsActualVulkanPath)",
          currentRenderer, envRenderer, graphicsApi, isVulkanRenderer, configuredVulkanExpected);

    PLDisplayLinkTarget *linkTarget = [[PLDisplayLinkTarget alloc] initWithVulkanMode:configuredVulkanExpected];
    CADisplayLink *displayLink = [CADisplayLink displayLinkWithTarget:linkTarget
                                                            selector:@selector(displayLinkTick:)];
    if (@available(iOS 15.0, tvOS 15.0, *)) {
        // max_framerate 选项已移除：始终采用 30-120Hz 自适应范围。
        // 屏幕硬件决定实际帧率（60Hz 设备仍为 60，120Hz ProMotion 设备可达 120），
        // 不再人为限制在 60FPS。配合 disable_game_vsync 完整解锁 VSync 后帧率可超过屏幕刷新率。
        displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
    }
    [displayLink addToRunLoop:NSRunLoop.currentRunLoop forMode:NSRunLoopCommonModes];
    self.statsDisplayLink = displayLink;
    self.statsDisplayLinkTarget = linkTarget;  // 强引用防止释放

    // 低频采样定时器：每 1 秒读取一次 native FPS 计数器和内存占用
    // 参照 FCL/ZL2 的 1Hz 采样策略（FCL_GameMenu.java Thread.sleep(1000)）
    // pojavGetAndResetFps() 读取并重置计数器，1 秒间隔直接返回 FPS 值
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                      target:self
                                                    selector:@selector(updateGameStats)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop currentRunLoop] addTimer:self.statsTimer forMode:NSRunLoopCommonModes];

    CGFloat screenScale = UIScreen.mainScreen.scale;
    [self updateSavedResolution];

    self.rootView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.frame.size.width + 30.0, self.view.frame.size.height)];
    [self.view addSubview:self.rootView];

    self.ctrlView = [[ControlLayout alloc] initWithFrame:getSafeArea(self.view.frame)];
    [self performSelector:@selector(initCategory_Navigation)];

    self.surfaceView = [[GameSurfaceView alloc] initWithFrame:self.view.frame];
    self.surfaceView.layer.contentsScale = screenScale * resolutionScale;
    self.surfaceView.layer.magnificationFilter = self.surfaceView.layer.minificationFilter = kCAFilterNearest;
    self.surfaceView.multipleTouchEnabled = YES;
    pojavWindow = self.surfaceView;

    self.touchView = [[UIView alloc] initWithFrame:self.view.frame];
    self.touchView.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1.0];
    self.touchView.multipleTouchEnabled = YES;
    [self.touchView addSubview:self.surfaceView];

    [self.rootView addSubview:self.touchView];
    [self.rootView addSubview:self.ctrlView];

    [self performSelector:@selector(setupCategory_Navigation)];

    UIHoverGestureRecognizer *hoverGesture = [[NSClassFromString(@"UIHoverGestureRecognizer") alloc] initWithTarget:self action:@selector(surfaceOnHover:)];
    [self.touchView addGestureRecognizer:hoverGesture];

    self.tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnClick:)];
    self.tapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.tapGesture.delegate = self;
    self.tapGesture.numberOfTapsRequired = 1;
    self.tapGesture.numberOfTouchesRequired = 1;
    self.tapGesture.cancelsTouchesInView = NO;
    self.tapGesture.delaysTouchesBegan = NO;
    self.tapGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.tapGesture];

    self.doubleTapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnDoubleClick:)];
    self.doubleTapGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.doubleTapGesture.delegate = self;
    self.doubleTapGesture.numberOfTapsRequired = 2;
    self.doubleTapGesture.numberOfTouchesRequired = 1;
    self.doubleTapGesture.cancelsTouchesInView = NO;
    self.doubleTapGesture.delaysTouchesBegan = NO;
    self.doubleTapGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.doubleTapGesture];

    self.longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnLongpress:)];
    self.longPressGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressGesture.cancelsTouchesInView = NO;
    self.longPressGesture.delaysTouchesBegan = NO;
    self.longPressGesture.delaysTouchesEnded = NO;
    self.longPressGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressGesture];

    self.longPressTwoGesture = [[UILongPressGestureRecognizer alloc]initWithTarget:self action:@selector(keyboardGesture:)];
    self.longPressTwoGesture.numberOfTouchesRequired = 2;
    self.longPressTwoGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.longPressTwoGesture.cancelsTouchesInView = NO;
    self.longPressTwoGesture.delaysTouchesBegan = NO;
    self.longPressTwoGesture.delaysTouchesEnded = NO;
    self.longPressTwoGesture.delegate = self;
    [self.touchView addGestureRecognizer:self.longPressTwoGesture];

    self.scrollPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(surfaceOnTouchesScroll:)];
    self.scrollPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.scrollPanGesture.delegate = self;
    self.scrollPanGesture.minimumNumberOfTouches = 2;
    self.scrollPanGesture.maximumNumberOfTouches = 2;
    self.scrollPanGesture.cancelsTouchesInView = NO;
    self.scrollPanGesture.delaysTouchesBegan = NO;
    self.scrollPanGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.scrollPanGesture];

    // TouchController 移动视角手势：右半区单指滑动
    self.moveViewPanGesture = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMoveViewPanGesture:)];
    self.moveViewPanGesture.allowedTouchTypes = @[@(UITouchTypeDirect)];
    self.moveViewPanGesture.delegate = self;
    self.moveViewPanGesture.maximumNumberOfTouches = 1;
    self.moveViewPanGesture.minimumNumberOfTouches = 1;
    // 不取消 touches 事件，让 touchesMoved 仍能触发（与 TC AddPointer 并存）
    self.moveViewPanGesture.cancelsTouchesInView = NO;
    self.moveViewPanGesture.delaysTouchesBegan = NO;
    self.moveViewPanGesture.delaysTouchesEnded = NO;
    [self.touchView addGestureRecognizer:self.moveViewPanGesture];

    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18, 27);
    self.mousePointerView = [[UIImageView alloc] initWithFrame:virtualMouseFrame];
    self.mousePointerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin |UIViewAutoresizingFlexibleBottomMargin;
    self.mousePointerView.hidden = !virtualMouseEnabled;
    [self reloadMousePointerImage];
    self.mousePointerView.userInteractionEnabled = NO;
    [self.touchView addSubview:self.mousePointerView];

    // 关键修复（UI 累积异常）：将块观察者存为属性，dealloc 中移除。
    // 之前返回值未存储，导致每次新建 SurfaceViewController 都泄漏一个观察者 + 强引用 self。
    self.mousePointerUpdatedCallback = [[NSNotificationCenter defaultCenter] addObserverForName:@"MousePointerUpdated" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [self reloadMousePointerImage];
    }];

    self.inputTextField = [[TrackedTextField alloc] initWithFrame:CGRectMake(0, -32.0, self.view.frame.size.width, 30.0)];
    self.inputTextField.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.inputTextField.delegate = self;
    self.inputTextField.font = [UIFont fontWithName:@"Menlo-Regular" size:20];
    // Task171：clearsOnBeginEditing 改 NO。哨兵空格由触发点在
    // becomeFirstResponder 之前写入（text = @" "），旧序"become 后赋值
    // + begin 时清空"与 iPadOS 26+ UIAsyncTextInput 的异步会话激活竞争
    // （装机日志实锤：首会话每输一个字符字段即被系统拆会话，用户必须
    // 每打一个字按一次输入法按钮）。TrackedTextField.deleteBackward 自带
    // @" " 兜底，不清空不改变任何键盘行为。
    self.inputTextField.clearsOnBeginEditing = NO;
    self.inputTextField.textAlignment = NSTextAlignmentCenter;
    self.inputTextField.sendChar = ^(jchar keychar){ CallbackBridge_nativeSendChar(keychar); };
    self.inputTextField.sendCharMods = ^(jchar keychar, int mods){ CallbackBridge_nativeSendCharMods(keychar, mods); };
    self.inputTextField.sendKey = ^(int key, int scancode, int action, int mods) { CallbackBridge_nativeSendKey(key, scancode, action, mods); };

    self.swipeableButtons = [[NSMutableArray alloc] init];

    [KeyboardInput initKeycodeTable];
    self.mouseConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCMouse* mouse = note.object;
        [self registerMouseCallbacks:mouse];
        self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
        [self setNeedsUpdateOfPrefersPointerLocked];
    }];
    self.mouseDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCMouseDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCMouse* mouse = note.object;
        mouse.mouseInput.mouseMovedHandler = nil;
        [mouse.mouseInput.auxiliaryButtons makeObjectsPerformSelector:@selector(setPressedChangedHandler:) withObject:nil];
        [self setNeedsUpdateOfPrefersPointerLocked];
        if (getPrefBool(@"controll.hardware_hide") && ![self ame139_modControlsHidden]) { self.ctrlView.hidden = NO; }
    }];
    if (GCMouse.current != nil) { [self registerMouseCallbacks:GCMouse.current]; }

    self.controllerConnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidConnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCController* controller = note.object;
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:controller];
        self.mousePointerView.hidden = isGrabbing;
        virtualMouseEnabled = YES;
        if (getPrefBool(@"control.hardware_hide")) { self.ctrlView.hidden = YES; }
    }];
    self.controllerDisconnectCallback = [[NSNotificationCenter defaultCenter] addObserverForName:GCControllerDidDisconnectNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        GCController* controller = note.object;
        [ControllerInput unregisterControllerCallbacks:controller];
        if (getPrefBool(@"control.hardware_hide") && ![self ame139_modControlsHidden]) { self.ctrlView.hidden = NO; }
    }];
    if (GCController.controllers.count == 1) {
        [ControllerInput initKeycodeTable];
        [ControllerInput registerControllerCallbacks:GCController.controllers.firstObject];
    }

    [self.rootView addSubview:self.inputTextField];
    [self performSelector:@selector(initCategory_LogView)];
    [self updateJetsamControl];
    [self updatePreferenceChanges];
    [self loadCustomControls];

    if (UIApplication.sharedApplication.connectedScenes.count > 1 && getPrefBool(@"video.fullscreen_airplay")) {
        [self switchToExternalDisplay];
    }
    
    self.touchSender = [[TouchSender alloc] init];

    // åå§å TouchController éæåº Transport
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode == 2 && [TouchControllerBridge isTouchControllerAvailable]) {
            // éæåºæ¨¡å¼ï¼åå»º Transport
            self.touchControllerTransportHandle = [TouchControllerBridge createTransportWithName:@"/tmp/touchcontroller.sock"];
            if (self.touchControllerTransportHandle < 0) {
                NSLog(@"[TouchController] Failed to create transport for static library mode");
            } else {
                NSLog(@"[TouchController] Transport created successfully (handle: %lld)", self.touchControllerTransportHandle);
            }
        } else {
            self.touchControllerTransportHandle = -1;
        }
    } else {
        self.touchControllerTransportHandle = -1;
    }

    // åå§å TouchController ææ¬è¾å¥æ¯æ
    if (self.touchControllerTransportHandle >= 0) {
        self.touchControllerTextInputEnabled = YES;
        [self setupTouchControllerTextInput];
        NSLog(@"[TouchController] Text input support initialized");

        // å¯å¨æ¶æ¯æ¥æ¶å®æ¶å¨
        [self startTouchControllerMessageLoop];
    }

    // 阶段13：显示启动遮罩层（在 launchMinecraft 之前显示，首帧渲染后自动移除）
    [self setupLaunchOverlay];

    [self launchMinecraft];
}

- (void)reloadMousePointerImage {
    NSString *path = [NSString stringWithFormat:@"%s/controlmap/mouse_pointer.png", getenv("POJAV_HOME")];
    UIImage *img = [UIImage imageWithContentsOfFile:path];
    if (img) {
        self.mousePointerView.image = img;
    } else {
        self.mousePointerView.image = [UIImage imageNamed:@"MousePointer"];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self setNeedsUpdateOfPrefersPointerLocked];

    // LAN 端口检测器已改为手动输入模式（LanPortDetector.h 说明），
    // 自动检测（startDetecting/stopDetecting）已移除，无需在此启动。
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 更新启动遮罩层渐变背景的 frame（旋转/尺寸变化时）
    if (self.launchGradientLayer && self.launchOverlayView) {
        self.launchGradientLayer.frame = self.launchOverlayView.bounds;
    }
}

- (void)updateAudioSettings {
    NSError *sessionError = nil;
    AVAudioSessionCategory category;
    AVAudioSessionCategoryOptions options = 0;
    if(getPrefBool(@"video.allow_microphone")) {
        category = AVAudioSessionCategoryPlayAndRecord;
        options |= AVAudioSessionCategoryOptionAllowAirPlay | AVAudioSessionCategoryOptionAllowBluetoothA2DP | AVAudioSessionCategoryOptionDefaultToSpeaker;
    } else if(getPrefBool(@"video.silence_with_switch")) {
        category = AVAudioSessionCategorySoloAmbient;
    } else {
        category = AVAudioSessionCategoryPlayback;
    }
    if(!getPrefBool(@"video.silence_other_audio")) {
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:category withOptions:options error:&sessionError];
    [session setActive:YES error:&sessionError];
}

- (void)updateJetsamControl {
    if (!getEntitlementValue(@"com.apple.private.memorystatus")) {
        return;
    }
    // 必须与 JavaLauncher.m 中 launchJVM 的 allocmem 计算保持一致，
    // 否则会出现 Jetsam 上限 < JVM Xmx + native 开销 的情况，
    // 导致系统在 JVM 启动阶段 SIGKILL 进程（日志表现为 "XPC connection interrupted"）。
    // Task141：两处现读同一共享助手 ame141_currentLaunchAllocMem（实例内存拉条
    // 决定，未设置时回退自动比例）—— 从结构上保证一致，不再依赖人工逐字同步。
    int allocmem = ame141_currentLaunchAllocMem();
    // 1024 MB 留给 JVM native 堆 + UIKit/Metal/EGL 等非 Java 堆开销。
    int limit = allocmem + 1024;
    if (memorystatus_control(MEMORYSTATUS_CMD_SET_JETSAM_TASK_LIMIT, getpid(), limit, NULL, 0) == -1) {
        NSLog(@"Failed to set Jetsam task limit: error: %s", strerror(errno));
    } else {
        NSLog(@"Successfully set Jetsam task limit (allocmem=%d MB, limit=%d MB)", allocmem, limit);
    }
}

- (void)updatePreferenceChanges {
    if (getPrefBool(@"debug.debug_auto_correction")) {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeDefault;
    } else {
        self.inputTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    }

    BOOL gyroEnabled = getPrefBool(@"control.gyroscope_enable");
    BOOL gyroInvertX = getPrefBool(@"control.gyroscope_invert_x_axis");
    int gyroSensitivity = getPrefInt(@"control.gyroscope_sensitivity");
    [GyroInput updateSensitivity:gyroEnabled?gyroSensitivity:0 invertXAxis:gyroInvertX];

    self.mouseSpeed = getPrefFloat(@"control.mouse_speed") / 100.0;
    virtualMouseEnabled = getPrefBool(@"control.virtmouse_enable");
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;

    CGFloat mouseScale = getPrefFloat(@"control.mouse_scale") / 100.0;
    virtualMouseFrame = CGRectMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2, 18.0 * mouseScale, 27 * mouseScale);
    self.mousePointerView.frame = virtualMouseFrame;

    self.shouldHideControlsFromRecording = getPrefFloat(@"control.recording_hide");
    [self.ctrlView hideViewFromCapture:self.shouldHideControlsFromRecording];
    self.ctrlView.frame = getSafeArea(self.view.frame);

    self.slideableHotbar = getPrefBool(@"control.slideable_hotbar");
    self.enableMouseGestures = getPrefBool(@"control.gesture_mouse");
    self.enableHotbarGestures = getPrefBool(@"control.gesture_hotbar");
    self.shouldTriggerHaptic = !getPrefBool(@"control.disable_haptics");

    self.scrollPanGesture.enabled = self.enableMouseGestures;
    self.doubleTapGesture.enabled = self.enableHotbarGestures;
    self.longPressGesture.minimumPressDuration = getPrefFloat(@"control.press_duration") / 1000.0;

    [self updateAudioSettings];
    [self updateSavedResolution];
    if (@available(iOS 16, tvOS 16, *)) {
        if ([self.surfaceView.layer isKindOfClass:CAMetalLayer.class]) {
            BOOL perfHUDEnabled = getPrefBool(@"video.performance_hud");
            ((CAMetalLayer *)self.surfaceView.layer).developerHUDProperties = perfHUDEnabled ? @{@"mode": @"default"} : nil;
        }
    }
    [self setNeedsUpdateOfPrefersPointerLocked];
}

- (void)updateSavedResolution {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
        self.screenScale = scene.screen.scale;
        if (scene.session.role != UIWindowSceneSessionRoleApplication) {
            break;
        }
    }

    if (self.surfaceView.superview != nil) {
        self.surfaceView.frame = self.surfaceView.superview.frame;
    }

    // Task159：分辨率缩放实例化——profile 键 resolution（实例设置页显式值）
    // → 全局 video.resolution（存量回退，PLProfiles prefDefaults）→ 100
    // （PLPreferences 默认）。与 ame_effective_renderer 的解析哲学同源：
    // 单点解析、调用方零回退逻辑。
    resolutionScale = [PLProfiles resolveKeyForCurrentProfile:@"resolution"].floatValue / 100.0;
    // Task 78（FSR 渲染分辨率联动）：MG 渲染器 + FSR 预设开启时，
    // MG 配置里的 fsr1_setting 终于有真实含义：
    //   surface/drawable = 物理 × resolutionScale（呈现分辨率，不变）；
    //   MC 告知窗口 windowWidth×windowHeight = surface / fsr_scale（渲染分辨率）。
    // MC viewport 锁存渲染尺寸，MobileGlues FSR1（Task78 后跟随 viewport）
    // 把 EASU/RCAS 升采样到 target = render × fsr_scale ≈ surface 后 blit
    // 上屏。此前 render 恒被 surface 尺寸覆写 → render==surface → FSR 永远
    // 零增益（Task76 只能旁路），用户只能手动降 video.resolution 逃生。
    // Task 119/120：改用 ame_effective_renderer（含 MobileGL 后端选项覆盖）——
    // 裸读 profile 会在“覆盖成 MobileGL”的会话里把窗口缩给一个不存在
    // 的升采样器（蜷缩根因），或反向漏掉 MobileGL 的 mgl_fsr 升采样。
    NSString *ame78_renderer = ame_effective_renderer();
    NSInteger ame78_fsr_preset = getPrefInt(@"mobileglues.fsr1_setting");
    // Task 83（FSR 独立化）：联动不再仅限 MG——zink（osm_bridge EASU）与
    // Vulkan 渲染器的 GL 路径（=MG）同样吃下窗口=表面/档位系数。能力表见
    // ame83_fsr_capable_renderer；不支持的渲染器维持 1.0（零回归）。
    mgFsrScale = ame83_fsr_capable_renderer(ame78_renderer)
        ? ame78_fsr_preset_scale(ame78_fsr_preset) : 1.0f;
    if (mgFsrScale > 1.0f) {
        static BOOL s_task78_logged = NO;
        if (!s_task78_logged) {
            s_task78_logged = YES;
            NSLog(@"[SurfaceVC] Task83 FSR linkage: renderer=%@ preset=%ld scale=%.2f -- MC render window = surface/%.2f (renderer-side upscale: %@); resolution=%.0f%%",
                  ame78_renderer, (long)ame78_fsr_preset, (double)mgFsrScale, (double)mgFsrScale,
                  [ame78_renderer hasPrefix:@"libOSMesa"] ? @"zink EASU (Task83)" : @"MobileGlues FSR1",
                  (double)(resolutionScale * 100.0));
        }
    }
    self.surfaceView.layer.contentsScale = self.screenScale * resolutionScale;

    physicalWidth = roundf(self.surfaceView.frame.size.width * self.screenScale);
    physicalHeight = roundf(self.surfaceView.frame.size.height * self.screenScale);
    // 呈现口径（surface/drawableSize）：物理 × resolutionScale。
    int surfaceWidth = roundf(physicalWidth * resolutionScale);
    int surfaceHeight = roundf(physicalHeight * resolutionScale);
    if ((surfaceWidth % 2) != 0) { --surfaceWidth; }
    if ((surfaceHeight % 2) != 0) { --surfaceHeight; }
    // Task 83（FSR 独立化）：表面像素尺寸单点写入——OSMesa/zink 桥的 FSR
    // 升采样需要全尺寸表面（其 OSMesa 缓冲与 CGImage 上屏都按它分配），
    // 而 windowWidth 是 MC 窗口信念（FSR 联动下 = surface/fsr_scale）。
    ame_surfaceWidth = surfaceWidth;
    ame_surfaceHeight = surfaceHeight;
    // 渲染口径（MC 告知窗口 = viewport = FSR render）：surface / fsr_scale。
    int ame153_renderW = roundf((float)surfaceWidth / mgFsrScale);
    int ame153_renderH = roundf((float)surfaceHeight / mgFsrScale);
    if ((ame153_renderW % 2) != 0) { --ame153_renderW; }
    if ((ame153_renderH % 2) != 0) { --ame153_renderH; }
    // Task 154：Task153 的 MobileGL 延迟缩窗分支退役（连同 ame83 能力表
    // 对 MobileGL 的除名，见上方针释）：mgFsrScale 对 MobileGL 恒 1.0，
    // ame153_renderW/H == surfaceWidth/Height，下方统一路径写入的全尺寸
    // 窗口与 da5918a 逐位一致。延迟武装标志清零以防残留（同进程内先玩
    // zink（FSR 联动）再切 mg 的会话：armed 位的旧值不得跨渲染器存活）。
    ame153_fsr_deferred_armed = 0;
    windowWidth = ame153_renderW;
    windowHeight = ame153_renderH;
    // Task175：物理/窗口合成比例单点写入（物品栏命中几何的单一事实源，
    // 见 environ.h 声明处注释）。异常值写 0 = 消费者自行回退本地重算。
    ame_windowToPhysRatio = 0.0f;
    if (windowHeight > 0 && physicalHeight > 0) {
        float ame175_ratio = (float)physicalHeight / (float)windowHeight;
        if (ame175_ratio >= 0.25f && ame175_ratio <= 8.0f) {
            ame_windowToPhysRatio = ame175_ratio;
        }
    }
    // Task 166：MobileGL(DirectVulkan) Metal-FSR 的私有交换层尺寸同步
    // （旋转/分辨率缩放后）：非活跃态零开销；活跃态下 gl_bridge 的 EGL
    // attribs 已固定于建 surface 时刻，但 MoltenVK swapchain 跟随层几何
    // （上游文档：“follows real surface resizes without rebuilding”），
    // 环形纹理在 nextDrawable 的尺寸自查里惰性重建。
    ame166_metal_fsr_update_size(windowWidth, windowHeight);
    if ([self.surfaceView.layer isKindOfClass:CAMetalLayer.class]) {
        CAMetalLayer *metalLayer = (CAMetalLayer *)self.surfaceView.layer;
        // Task 60（画面模糊根因修复，5f1df50 真机日志实证）：
        // Task50 的 1x 钉扎（contentsScale=1.0、drawableSize=bounds 点数）
        // 把 EGL surface 压到 1180x820，CoreAnimation 线性放大 2x 到物理屏
        // 2360x1640 → 全屏模糊（用户实测"画面模糊"）；MC 26.2 LWJGL 路径
        // viewport 2360x1640 ≠ surface 1180x820 → Task49 geo-heal 每帧降采样
        // blit → 双重模糊 + blit 开销（用户实测"MG 对 LWJGL 兼容性倒退"）。
        //
        // 渲染/输入口径已由 Task58（EGL 查询常量修正）+ Task59（输入像素直通）
        // 定案：启动器像素口径 2360x1640 == launchJVM 告知值 == MC 窗口信念
        // == MC 输入归一化基准。因此 GL 分支与非 GL 分支统一：
        //   drawableSize = surfaceWidth x surfaceHeight（= physical x resolutionScale），
        //   contentsScale 维持上方 screenScale x resolutionScale。
        // surface==drawable==物理像素 1:1 呈现零缩放；resolutionScale < 1
        // 时按比例整体缩放（保留用户分辨率偏好的语义）；旋转时 bounds 跟随
        // → 三者同步翻转。本写入与 gl_init_context 的 Task60 创建对齐块
        // 同口径（主线程单一写者纪律不变）。
        // Task 78：FSR 联动下 windowWidth（MC 窗口/渲染尺寸）< surface，
        // drawableSize 必须写【呈现口径】surfaceWidth×surfaceHeight 而非
        // windowWidth；fsr_scale=1 时两值相同（零回归），fsr_scale>1 时
        // surface 保持全尺寸供 FSR1 升采样 blit。gl_bridge 的 Task78 豁免
        // 保证此期 geoMismatch 不触发（g_ame53_transposed=0 → 写入畅通）。
        if (ame_gl_surface_owns_layer()) {
            // Task 53（分裂画面根治之一）：surface 与 MC viewport 几何失配
            //（转置锁死、重对齐未治愈/熔断）期间停写 drawableSize——此期
            // Task52 guard 正以 surface 尺寸独占写权保持 present 自洽（全屏
            // 压扁-拉伸往返，宽高比还原）；本函数若继续写会与之每帧拉锯。
            // 重对齐成功后 surface==drawable==bounds 像素，本写入变为同值
            // no-op，单一事实源正常恢复。
            if (!ame_gl_surface_transposed()) {
                metalLayer.drawableSize = CGSizeMake(MAX(surfaceWidth, 1), MAX(surfaceHeight, 1));
            }
        } else {
            metalLayer.drawableSize = CGSizeMake(MAX(surfaceWidth, 1), MAX(surfaceHeight, 1));
        }
        // 解锁帧率（关闭垂直同步）：三缓冲。
        // 默认 maximumDrawableCount（通常为 2）下，当两个 drawable 都在等待呈现时，
        // nextDrawable 会阻塞到 vblank 释放一个 drawable，间接把渲染线程锁在刷新率。
        // 设为 3（三缓冲）后几乎总有空闲 drawable，渲染线程不再因等待 drawable 而 stall，
        // 配合 VSync 关闭可让帧率超过屏幕刷新率。该值是 Metal 低延迟/高吞吐渲染的标准设置。
        // 注：此优化对 GL 类渲染器（经 CAMetalLayer 呈现）最有意义；Vulkan/MoltenVK 自管 swapchain。
        metalLayer.maximumDrawableCount = 3;

        // 显式设置 presentsWithTransaction=NO（默认值）。
        // presentsWithTransaction=YES 会导致 presentDrawable 同步等待 Core Animation 事务提交，
        // 增加延迟且不会提高帧率。设为 NO 让 presentDrawable 异步提交到 Core Animation，
        // 渲染线程可以立即继续下一帧渲染，配合 eglSwapInterval(0) 实现帧率解锁。
        // 这是 Metal 高吞吐渲染的标准配置。
        metalLayer.presentsWithTransaction = NO;

        // 确保异步绘制开启（GameSurfaceView.initWithFrame 已设置，此处二次确认）
        metalLayer.drawsAsynchronously = YES;

        // 记录 Metal 层配置（仅首次），帮助诊断帧率问题
        static BOOL s_loggedMetalConfig = NO;
        if (!s_loggedMetalConfig) {
            s_loggedMetalConfig = YES;
            NSLog(@"[SurfaceVC] CAMetalLayer configured: drawableSize=%.0fx%.0f, maximumDrawableCount=%ld, presentsWithTransaction=%d, drawsAsynchronously=%d, contentsScale=%.2f",
                  metalLayer.drawableSize.width, metalLayer.drawableSize.height,
                  (long)metalLayer.maximumDrawableCount,
                  metalLayer.presentsWithTransaction,
                  metalLayer.drawsAsynchronously,
                  metalLayer.contentsScale);
        }
    }
    CallbackBridge_nativeSendScreenSize(windowWidth, windowHeight);
}

- (void)updateControlHiddenState:(BOOL)hide {
    for (UIView *view in self.ctrlView.subviews) {
        ControlButton *button = (ControlButton *)view;
        if (!button.canBeHidden) continue;
        BOOL hidden = hide || !(
            (isGrabbing && [button.properties[@"displayInGame"] boolValue]) ||
            (!isGrabbing && [button.properties[@"displayInMenu"] boolValue]));
        if (!hidden && ![button isKindOfClass:ControlSubButton.class]) {
            button.hidden = hidden;
            if ([button isKindOfClass:ControlDrawer.class]) {
                [(ControlDrawer *)button restoreButtonVisibility];
            }
        } else if (hidden) {
            button.hidden = hidden;
        }
    }
}

- (void)updateGrabState {
    // Task161：GLFW 路径（MC ≤26.2）聊天自动弹键盘——与 26.3（SDL 路径，
    // SDL_StartTextInput 系统键盘）对齐的用户指令"遇到光标能正常弹出键盘"。
    // 判定：grab 转 false（开界面）+ 最近 1.5s 内启动器发过 T/斜杠（vanilla
    // 聊天/命令行开键，见 ame161_lastSentKeyWasChatOpener）+ 本页键盘未开
    // → inputTextField becomeFirstResponder（与 ⌨ 按钮同路径）。仅 GLFW
    // 路径（ame161_inputPathIsGLFW，MC ≤26.2）生效；26.3 的 SDL 键盘不受影响。
    // 自动弹出的键盘在 grab 恢复 true（回游戏/关聊天）时自动收起；
    // ame161_autoShown 标记保证 ⌨ 手动唤出的键盘不被误收（游戏内 ⌨ 键盘
    // 常用于快捷栏按键）。
    static BOOL ame161_autoShown = NO;
    if (ame161_inputPathIsGLFW()) {
        if (isGrabbing == JNI_FALSE &&
            !self.inputTextField.isFirstResponder &&
            ame161_lastSentKeyWasChatOpener(1.5)) {
            [self.inputTextField becomeFirstResponder];
            ame161_autoShown = YES;
            NSLog(@"[SurfaceVC] Task161: chat key + ungrab -> keyboard auto-shown (GLFW path, MC <=26.2)");
        } else if (isGrabbing == JNI_TRUE && ame161_autoShown) {
            if (self.inputTextField.isFirstResponder) {
                ame171_keyboardDismissGeneration++;   // Task171：主动收起，作废在途自愈检查
                [self.inputTextField resignFirstResponder];
                self.inputTextField.alpha = 1.0f;
            }
            ame161_autoShown = NO;
            NSLog(@"[SurfaceVC] Task161: grab restored -> auto-shown keyboard dismissed");
        }
    }
    if (isGrabbing == JNI_TRUE) {
        // Task59：contentsScale 已被 Task52 呈现对齐钉成 1.0，作输入乘数会缺 ×2
        // （lastVirtualMousePoint 是点，乘 1 后落入 MC 2360 像素空间的 1/4 处）。
        // 与 sendTouchPoint 同口径：用 screenScale（scene.screen.scale，即 2.0）。
        CGFloat screenScale = self.screenScale > 0 ? self.screenScale : UIScreen.mainScreen.scale;
        CallbackBridge_nativeSendCursorPos(ACTION_DOWN, lastVirtualMousePoint.x * screenScale, lastVirtualMousePoint.y * screenScale);
        virtualMouseFrame.origin.x = self.view.frame.size.width / 2;
        virtualMouseFrame.origin.y = self.view.frame.size.height / 2;
        self.mousePointerView.frame = virtualMouseFrame;
    }
    self.scrollPanGesture.enabled = !isGrabbing;
    self.mousePointerView.hidden = isGrabbing || !virtualMouseEnabled;
    [self setNeedsUpdateOfPrefersPointerLocked];
    [self updateControlHiddenState:NO];
}

// Task 87：LTW × MC 26.x 兼容性预检 ------------------------------------------
// 病历（7b88b69 latestlog.txt，6054498 构建，iPad Air M4 / iPadOS 27）：
// LTW 在 iOS 上把桌面 GL 3.3 转译到 Apple 系统 ANGLE 的 GLES 3.0（日志实证
// "LTW: Running on OpenGL ES 3.0 with ESSL 300"；BaseVertex 亦因缺 ES 3.1
// 不可用），且 LTW 无纹理缓冲（TBO）模拟层。而 MC 26.x 的云渲染管线
// （minecraft:core/rendertype_clouds）在桌面 GL 3.3 下按核心规范使用
// samplerBuffer（TBO 自 GL 3.1 起为核心特性）——ES 3.0 后端没有
// GL_EXT_texture_buffer，着色器编译死于 "'samplerBuffer' : Illegal use of
// reserved word" → pipeline/flat_clouds 与 clouds 缺失 → 资源重载阶段必崩
// （实测 11.8s，标题界面，crash report: Failed to load required shader
// programs）。Zink（桌面 GL 4.x 全量）与 MobileGlues（自带 TBO 模拟，
// 2.0.x REVISION 7+）不受影响。
// 给 LTW 补 TBO 模拟属结构性工程（缓冲追踪 + 着色器改写 + 采样重接，
// 参照 MobileGlues REVISION 7-13 的迭代史），列路线图；当前策略：启动前
// 拦截 + 明确指引，避免用户白跑一次必崩的启动。
// 版本口径：主版本号 >= 26（Mojang 年度版本方案 26.1/26.2/...）即不兼容，
// 含 26w* 快照与 rc/pre 后缀；1.21.x 及更早不受影响。
// Task98：解析下沉到 ame98_mcMajorFromVersionId（JavaLauncher.h 导出），
// 修复 Fabric/NeoForge/Forge 前缀形态 ID 的盲区——旧解析在首个 "-" 截断，
// "fabric-loader-0.19.5-26.3-e4ecd7db" 只读到 "fabric"（0），LTW 门对
// Fabric 26.x 整合包失效放行。新口径对 rc/pre 后缀天然免疫（锚定正则
// 不依赖后缀剥离），与 ResolveLwjglVersion 的 LWJGL 选择共用同一实现。
static BOOL ame87_mcVersionRequiresTextureBuffer(NSString *mcVersionId) {
    if (mcVersionId.length == 0) {
        return NO;
    }
    // "26.2"→26；"26w13a"→26；"1.20.1"→1；"25w45a"→25；
    // "fabric-loader-0.19.5-26.3-e4ecd7db"→26（Task98 修复点）
    NSInteger major = ame98_mcMajorFromVersionId(mcVersionId);
    if (major <= 0) {
        return NO;
    }
    return major >= 26;
}

- (void)launchMinecraft {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // Validate metadata first
        if (!self.metadata) {
            NSLog(@"[SurfaceViewController] Error: metadata is nil");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil), localize(@"ame202.surface.version_load_failed", @"游戏版本加载失败，请重新选择版本"));
            });
            return;
        }

        // Validate window dimensions
        if (windowWidth <= 0 || windowHeight <= 0) {
            NSLog(@"[SurfaceViewController] Error: invalid window size %dx%d", windowWidth, windowHeight);
            windowWidth = 1280;
            windowHeight = 720;
        }

        // Task 87：LTW 渲染器 × MC 26.x 预检（渲染器能力缺口，见 ame87_mcVersionRequiresTextureBuffer 头注释）
        NSString *ame87_renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        NSString *ame87_versionId = [self.metadata[@"id"] description];
        if ([ame87_renderer isEqualToString:@ RENDERER_NAME_LTW]
            && ame87_mcVersionRequiresTextureBuffer(ame87_versionId)) {
            NSLog(@"[SurfaceViewController] Task87 launch gate: LTW renderer + MC %@ blocked -- GL 3.3 requires texture buffers for the 26.x clouds pipeline, LTW's iOS backend is GLES 3.0 without GL_EXT_texture_buffer; startup would crash at the title screen (7b88b69 evidence)", ame87_versionId);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil),
                    [NSString stringWithFormat:localize(@"ame189.svc.ltw_unsupported", nil), ame87_versionId]);
            });
            return;
        }
        
        // Get Java version
        int minVersion = [self.metadata[@"javaVersion"][@"majorVersion"] intValue];
        if (minVersion == 0) {
            minVersion = [self.metadata[@"javaVersion"][@"version"] intValue];
        }
        if (minVersion == 0) {
            minVersion = 8; // Default to Java 8
        }
        
        // Validate authenticator
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (!currentAuth) {
            NSLog(@"[SurfaceViewController] Error: no authenticator available");
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
                showDialog(localize(@"Error", nil), localize(@"ame202.surface.login_required", @"请先登录账号"));
            });
            return;
        }

        // Task220：正版账号启动前令牌门控——keychain 令牌缺失/损坏时（换侧载
        // 方式/恢复备份后的常见态，Task185 取证锚点 "SecItem OK but unarchive
        // failed"），游戏会带着 accessToken="0" 启动：正版皮肤不加载、多人会话
        // 校验必败（用户主诉"正版账号皮肤不正常"的根源之一）。此前修复弹窗
        // 只在选择账号 / 右面板刷新时出现，直接点启动的用户全程无感。现在
        // 启动前显式拦下并给出一键修复入口（ame187：删账号重登，登录成功后
        // pendingLaunchAfterLogin 自动接续启动）。Demo 账号（无 MC profile，
        // 用户名 Demo. 前缀）本就只能离线玩，不拦。
        if ([currentAuth isKindOfClass:[MicrosoftAuthenticator class]]) {
            NSString *ame220_xuid = currentAuth.authData[@"xuid"];
            NSString *ame220_user = currentAuth.authData[@"username"];
            BOOL ame220_isDemo = [ame220_user isKindOfClass:NSString.class] && [ame220_user hasPrefix:@"Demo."];
            if (!ame220_isDemo && [ame220_xuid isKindOfClass:NSString.class] && ame220_xuid.length > 0 &&
                ![MicrosoftAuthenticator tokenDataOfProfile:ame220_xuid]) {
                NSLog(@"[SurfaceViewController] Task220 launch gate: MS account token missing/corrupt (user=%@, xuid=%@) -- repair dialog shown",
                      ame220_user, ame220_xuid);
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self dismissLaunchOverlayOnError];
                    ame187_showAccountRepairDialog(ame220_user,
                                                   currentAuth.authData[@"accountId"],
                                                   ame220_xuid);
                });
                return;
            }
        }

        // Validate accountId（用作账户文件名，传给 Java 端加载对应账户）
        NSString *accountId = currentAuth.authData[@"accountId"];
        if (!accountId || accountId.length == 0) {
            // 兜底：极少数情况下 accountId 缺失（如旧账户未迁移），回退到 username
            accountId = currentAuth.authData[@"username"];
            if (!accountId || accountId.length == 0) {
                accountId = @"Player";
            }
        }

        NSLog(@"[SurfaceViewController] Launching Minecraft with accountId: %@, version: %d, size: %dx%d",
              accountId, minVersion, windowWidth, windowHeight);

        // Launch JVM（args[0] 传 accountId，Java 端 MinecraftAccount.load(accountId) 据此加载账户）
        int launchResult = launchJVM(accountId, self.metadata, windowWidth, windowHeight, minVersion);

        // JVM 启动失败（返回非 0）：移除启动遮罩层，让用户看到错误对话框
        // launchJVM 内部失败时会调用 showDialog 显示错误，此处仅负责清理遮罩层
        if (launchResult != 0) {
            NSLog(@"[SurfaceViewController] JVM launch failed with code %d", launchResult);
            dispatch_async(dispatch_get_main_queue(), ^{
                [self dismissLaunchOverlayOnError];
            });
        }
    });
}

#pragma mark - 阶段13/16：启动遮罩层（仿 FCL/ZL2 全屏启动进度显示）

/// 创建并显示启动遮罩层（参照 FCL/ZL2 风格重构）：
///
/// 设计理念（参照 FCL/ZalithLauncher2）：
///   - 启动遮罩层是纯视觉层，不拦截任何触摸事件
///   - userInteractionEnabled = NO，让下层的 gameMenuOverlay（悬浮球/FPS）可交互
///   - 深色渐变背景 + 毛玻璃效果，营造沉浸式启动体验
///   - 居中信息卡片展示启动进度、阶段、Java 版本、内存、渲染器
///   - 底部取消按钮允许用户中止卡住的启动流程
///
/// 视觉布局（从上到下）：
///   ┌─────────────────────────────────┐
///   │         游戏图标 (72pt)          │
///   │       旋转指示器 (Medium)        │
///   │     "正在启动 Minecraft"         │
///   │      当前阶段文案                │
///   │   ━━━━━━━━━━━━━━━━ 45%          │
///   │         已耗时 12秒              │
///   │  ┌─────────────────────────┐    │
///   │  │ Java 17 │ 2048MB │ gl4es │    │
///   │  └─────────────────────────┘    │
///   │        [ 取消启动 ]              │
///   └─────────────────────────────────┘
- (void)setupLaunchOverlay {
    // ============================================================
    // FCL 风格启动界面：中间转圈圈 + 显示自定义启动器背景
    // ============================================================
    // 参照 FCL (FoldCraftLauncher) 的启动加载界面：
    //   - 背景显示启动器的自定义壁纸（如果有）
    //   - 屏幕正中央显示一个大的旋转加载指示器
    //   - 指示器下方显示简短的标题文字（如"正在启动 Minecraft"）
    //   - 不显示进度条、百分比、阶段文案、信息卡片等多余元素
    //   - 底部保留一个小的"取消启动"按钮
    //
    // 之前的实现包含了图标、进度条、百分比、已耗时、信息卡片、
    // 阶段轮转文案等大量元素，过于复杂。FCL 的设计理念是简洁：
    // 用户只需要知道"正在加载"即可，不需要知道详细的阶段和进度。
    self.launchStartTime = [NSDate timeIntervalSinceReferenceDate];
    self.launchOverlayDismissed = NO;

    // ========================================================================
    // 全屏遮罩容器
    // ========================================================================
    // userInteractionEnabled = NO：让触摸穿透到下层的 gameMenuOverlay，
    // 用户可在启动期间拖动悬浮球、查看 FPS。
    // 取消按钮单独加到 self.view 上（不受此设置影响）。
    self.launchOverlayView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.launchOverlayView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.launchOverlayView.userInteractionEnabled = NO;
    [self.view addSubview:self.launchOverlayView];

    // ========================================================================
    // 背景层：显示自定义启动器背景
    // ========================================================================
    // 有自定义壁纸时：透明遮罩 + 轻微暗化蒙层（增强文字可读性）
    // 无自定义壁纸时：使用深色渐变作为回退
    if ([[BackgroundManager sharedManager] hasBackground]) {
        // 有自定义背景：透明遮罩 + 轻微暗化蒙层
        self.launchOverlayView.backgroundColor = [UIColor clearColor];
        UIView *dimOverlay = [[UIView alloc] initWithFrame:self.launchOverlayView.bounds];
        dimOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        dimOverlay.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.3];
        dimOverlay.userInteractionEnabled = NO;
        [self.launchOverlayView addSubview:dimOverlay];
    } else {
        // 无自定义背景：使用深色渐变
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.frame = self.launchOverlayView.bounds;
        gradient.colors = @[
            (__bridge id)[UIColor colorWithRed:0.08 green:0.09 blue:0.13 alpha:1.0].CGColor,
            (__bridge id)[UIColor colorWithRed:0.03 green:0.03 blue:0.05 alpha:1.0].CGColor,
        ];
        gradient.locations = @[@0.0, @1.0];
        gradient.startPoint = CGPointMake(0.5, 0.0);
        gradient.endPoint = CGPointMake(0.5, 1.0);
        [self.launchOverlayView.layer insertSublayer:gradient atIndex:0];
        self.launchGradientLayer = gradient;
    }

    // ========================================================================
    // 中央内容容器（居中显示转圈圈 + 标题）
    // ========================================================================
    UIView *centerContainer = [[UIView alloc] init];
    centerContainer.translatesAutoresizingMaskIntoConstraints = NO;
    centerContainer.userInteractionEnabled = NO;
    [self.launchOverlayView addSubview:centerContainer];

    // 大号旋转指示器（FCL 风格：屏幕正中央的大转圈）
    self.launchSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.launchSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchSpinner.color = [UIColor whiteColor];
    [self.launchSpinner startAnimating];
    [centerContainer addSubview:self.launchSpinner];

    // 标题文字（转圈下方，简短提示）
    self.launchTitleLabel = [[UILabel alloc] init];
    self.launchTitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchTitleLabel.text = localize(@"launch.title", @"正在启动 Minecraft");
    self.launchTitleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.launchTitleLabel.textColor = [UIColor colorWithWhite:0.9 alpha:1.0];
    self.launchTitleLabel.textAlignment = NSTextAlignmentCenter;
    [centerContainer addSubview:self.launchTitleLabel];

    // ============================================================
    // ★ Task222（清单第 16 项）：高级启动进度三件套
    //   阶段文案（时间轴轮转，淡入淡出）+ 微光进度条（FCL 式 indeterminate
    //   shimmer，真实进度不可知时的最佳形态）+ 已耗时计时。
    //   保持 FCL 的简洁语言：元素少而精，信息密度高。
    // ============================================================
    self.launchStageLabel = [[UILabel alloc] init];
    self.launchStageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchStageLabel.text = localize(@"launch.stage.0", nil);
    self.launchStageLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    self.launchStageLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    self.launchStageLabel.textAlignment = NSTextAlignmentCenter;
    [centerContainer addSubview:self.launchStageLabel];
    self.launchStageIndex = 0;

    // 进度轨道（2pt 细条，280pt 宽）+ 微光滑块（30% 宽往复移动）
    self.launchProgressTrack = [[UIView alloc] init];
    self.launchProgressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchProgressTrack.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15];
    self.launchProgressTrack.layer.cornerRadius = 1.5;
    self.launchProgressTrack.layer.masksToBounds = YES;
    [centerContainer addSubview:self.launchProgressTrack];

    self.launchProgressBar = [[UIView alloc] init];
    self.launchProgressBar.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchProgressBar.backgroundColor = [UIColor whiteColor];
    self.launchProgressBar.layer.cornerRadius = 1.5;
    [self.launchProgressTrack addSubview:self.launchProgressBar];
    // 微光动画：30% 宽的亮条从左到右循环扫过（indeterminate shimmer）
    [NSLayoutConstraint activateConstraints:@[
        [self.launchProgressBar.topAnchor constraintEqualToAnchor:self.launchProgressTrack.topAnchor],
        [self.launchProgressBar.bottomAnchor constraintEqualToAnchor:self.launchProgressTrack.bottomAnchor],
        [self.launchProgressBar.leadingAnchor constraintEqualToAnchor:self.launchProgressTrack.leadingAnchor],
        [self.launchProgressBar.widthAnchor constraintEqualToAnchor:self.launchProgressTrack.widthAnchor multiplier:0.3],
    ]];
    // 微光扫过动画在 updateLaunchStage 的首个周期挂载（届时 track 已完成
    // 首次 layout、有真实宽度，keyframe 数值才有效）。

    // 已耗时
    self.launchElapsedLabel = [[UILabel alloc] init];
    self.launchElapsedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.launchElapsedLabel.text = @"0s";
    self.launchElapsedLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.launchElapsedLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    self.launchElapsedLabel.textAlignment = NSTextAlignmentCenter;
    [centerContainer addSubview:self.launchElapsedLabel];

    // ========================================================================
    // 取消启动按钮（底部，独立添加到 self.view 不受遮罩穿透影响）
    // ========================================================================
    self.launchCancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.launchCancelButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.launchCancelButton setTitle:localize(@"launch.cancel", @"取消启动") forState:UIControlStateNormal];
    [self.launchCancelButton setTitleColor:[UIColor colorWithWhite:0.7 alpha:1.0] forState:UIControlStateNormal];
    self.launchCancelButton.titleLabel.font = [UIFont systemFontOfSize:14];
    self.launchCancelButton.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.1];
    self.launchCancelButton.layer.cornerRadius = 8;
    self.launchCancelButton.layer.cornerCurve = kCACornerCurveContinuous;
    [self.launchCancelButton addTarget:self action:@selector(cancelLaunch) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.launchCancelButton];

    // ========================================================================
    // 布局约束
    // ========================================================================
    [NSLayoutConstraint activateConstraints:@[
        // 中央容器：水平居中，垂直居中
        [centerContainer.centerXAnchor constraintEqualToAnchor:self.launchOverlayView.centerXAnchor],
        [centerContainer.centerYAnchor constraintEqualToAnchor:self.launchOverlayView.centerYAnchor],

        // 旋转指示器：容器顶部居中
        [self.launchSpinner.topAnchor constraintEqualToAnchor:centerContainer.topAnchor],
        [self.launchSpinner.centerXAnchor constraintEqualToAnchor:centerContainer.centerXAnchor],

        // 标题：转圈下方
        [self.launchTitleLabel.topAnchor constraintEqualToAnchor:self.launchSpinner.bottomAnchor constant:16],
        [self.launchTitleLabel.leadingAnchor constraintEqualToAnchor:centerContainer.leadingAnchor],
        [self.launchTitleLabel.trailingAnchor constraintEqualToAnchor:centerContainer.trailingAnchor],

        // ★ Task222：阶段文案（标题下方，淡入淡出轮转）
        [self.launchStageLabel.topAnchor constraintEqualToAnchor:self.launchTitleLabel.bottomAnchor constant:8],
        [self.launchStageLabel.leadingAnchor constraintEqualToAnchor:centerContainer.leadingAnchor],
        [self.launchStageLabel.trailingAnchor constraintEqualToAnchor:centerContainer.trailingAnchor],

        // ★ Task222：微光进度条（阶段下方，280pt 宽 3pt 高）
        [self.launchProgressTrack.topAnchor constraintEqualToAnchor:self.launchStageLabel.bottomAnchor constant:14],
        [self.launchProgressTrack.centerXAnchor constraintEqualToAnchor:centerContainer.centerXAnchor],
        [self.launchProgressTrack.widthAnchor constraintEqualToConstant:280],
        [self.launchProgressTrack.heightAnchor constraintEqualToConstant:3],

        // ★ Task222：已耗时（进度条下方）
        [self.launchElapsedLabel.topAnchor constraintEqualToAnchor:self.launchProgressTrack.bottomAnchor constant:8],
        [self.launchElapsedLabel.leadingAnchor constraintEqualToAnchor:centerContainer.leadingAnchor],
        [self.launchElapsedLabel.trailingAnchor constraintEqualToAnchor:centerContainer.trailingAnchor],
        [self.launchElapsedLabel.bottomAnchor constraintEqualToAnchor:centerContainer.bottomAnchor],

        // 取消按钮：底部安全区域上方
        [self.launchCancelButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [self.launchCancelButton.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.launchCancelButton.widthAnchor constraintEqualToConstant:120],
        [self.launchCancelButton.heightAnchor constraintEqualToConstant:36],
    ]];

    // 注册首帧渲染通知（egl_bridge.m 中 pojavSwapBuffers 首次调用时发送）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onFirstFrameRendered)
                                                 name:@"PojavFirstFrameRendered"
                                               object:nil];

    // ★ Task222（清单第 16 项）：阶段轮转定时器（0.5s 周期：阶段判定 +
    //   耗时刷新 + 微光动画延迟挂载——首帧 layout 完成后 track 才有宽度）
    self.launchStageTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                             target:self
                                                           selector:@selector(updateLaunchStage)
                                                           userInfo:nil
                                                            repeats:YES];

    // Task172：SDL 文本输入路由（sdl3_hook.m 的 Start/StopTextInput 钩子派发）。
    // MC 26.3 EditBox 聚焦时 SDL UIKit 自己的 textField 会抢走 first responder
    // 但其投递链不可靠——键盘必须服务启动器的 inputTextField（病历见
    // sdl3_hook.m 的 Task172 注释）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame172_sdlStartTextInput:)
                                                 name:@"AME172_SDLStartTextInput"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame172_sdlStopTextInput:)
                                                 name:@"AME172_SDLStopTextInput"
                                               object:nil];
}

/// 取消启动：用户点击"取消启动"按钮时调用。
/// 终止 JVM 启动流程，移除遮罩层，返回启动器主界面。
- (void)cancelLaunch {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"launch.cancel_confirm_title", @"确认取消启动？")
                                                                   message:localize(@"launch.cancel_confirm_message", @"取消启动将终止当前的游戏加载流程并返回启动器。")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"launch.cancel_confirm_yes", @"确认取消")
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        NSLog(@"[SurfaceViewController] User cancelled launch");
        // 移除遮罩层
        [self dismissLaunchOverlayOnError];
        // 返回启动器
        [[SurfaceViewController currentInstance].logOutputView dismissAndReturnToLauncher];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"launch.cancel_confirm_no", @"继续等待")
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 定时器回调（每 0.5 秒）——★ Task222（清单第 16 项）实装：
/// 1. 基于已耗时判定启动阶段（时间轴估计：JVM 日志时机在 C 层，OC 侧
///    不可靠，时间轴是 Pojav 系启动器的通用形态），阶段切换带淡入淡出；
/// 2. 首个周期挂载微光扫过动画（track 首次 layout 后才有真实宽度）；
/// 3. 刷新已耗时（等宽数字，秒级）。
- (void)updateLaunchStage {
    if (self.launchOverlayDismissed) return;

    NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.launchStartTime;

    // 阶段时间轴（iPad 性能基线；慢设备自然多停留几拍，文案语义渐进不违和）：
    //   0-4s 准备运行环境 / 4-10s 启动 Java 虚拟机 / 10-22s 加载游戏与模组 /
    //   22-40s 初始化资源 / 40s+ 生成窗口（首次启动/整合包耗时更久）
    NSInteger stage = 0;
    if (elapsed >= 40.0)      stage = 4;
    else if (elapsed >= 22.0) stage = 3;
    else if (elapsed >= 10.0) stage = 2;
    else if (elapsed >= 4.0)  stage = 1;

    if (stage != self.launchStageIndex) {
        self.launchStageIndex = stage;
        NSString *key = [NSString stringWithFormat:@"launch.stage.%ld", (long)stage];
        // 淡出 -> 换文案 -> 淡入（0.18s，克制不抢戏）
        [UIView animateWithDuration:0.18 animations:^{
            self.launchStageLabel.alpha = 0.0;
        } completion:^(BOOL finished) {
            self.launchStageLabel.text = localize(key, nil);
            [UIView animateWithDuration:0.22 animations:^{
                self.launchStageLabel.alpha = 1.0;
            }];
        }];
    }

    // 首个周期：挂载微光扫过动画（track 已 layout，宽度有效）
    if (self.launchProgressBar.layer.animationKeys.count == 0 &&
        self.launchProgressTrack.bounds.size.width > 1.0) {
        CGFloat trackW = self.launchProgressTrack.bounds.size.width;
        CGFloat barW = trackW * 0.3;
        CAKeyframeAnimation *shimmer = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
        [shimmer setValues:@[@(-barW), @(trackW), @(-barW)]];
        [shimmer setKeyTimes:@[@0.0, @0.5, @1.0]];
        [shimmer setDuration:2.4];
        shimmer.repeatCount = HUGE_VALF;
        [self.launchProgressBar.layer addAnimation:shimmer forKey:@"ame222_shimmer"];
    }

    // 已耗时（分钟:秒 或 秒）
    if (elapsed >= 60.0) {
        self.launchElapsedLabel.text = [NSString stringWithFormat:@"%ldm%02lds",
            (long)(elapsed / 60.0), (long)elapsed % 60];
    } else {
        self.launchElapsedLabel.text = [NSString stringWithFormat:@"%lds", (long)elapsed];
    }
}

/// 首帧渲染通知回调：淡出并移除启动遮罩层
- (void)onFirstFrameRendered {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchSpinner stopAnimating];
        // ★ Task222：停阶段轮转定时器
        [self.launchStageTimer invalidate];
        self.launchStageTimer = nil;

        NSTimeInterval elapsed = [NSDate timeIntervalSinceReferenceDate] - self.launchStartTime;

        // 隐藏取消按钮（淡出动画与遮罩层一起进行）
        [self.launchCancelButton setHidden:YES];

        // 淡出移除遮罩层（FCL 风格：简洁的淡出过渡）
        [UIView animateWithDuration:0.4
                              delay:0.1
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.launchOverlayView.alpha = 0.0;
            self.launchCancelButton.alpha = 0.0;
        }
                         completion:^(BOOL finished) {
            [self.launchOverlayView removeFromSuperview];
            self.launchOverlayView = nil;
            self.launchGradientLayer = nil;
            [self.launchCancelButton removeFromSuperview];
            self.launchCancelButton = nil;
            [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[SurfaceViewController] Launch overlay dismissed after %.1f seconds", elapsed);
        }];
    });
}

/// 启动失败时移除遮罩层（JVM 启动失败、metadata 为空等错误路径调用）
- (void)dismissLaunchOverlayOnError {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.launchOverlayDismissed) return;
        self.launchOverlayDismissed = YES;

        [self.launchSpinner stopAnimating];
        // ★ Task222：停阶段轮转定时器
        [self.launchStageTimer invalidate];
        self.launchStageTimer = nil;
        [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];

        [self.launchOverlayView removeFromSuperview];
        self.launchOverlayView = nil;
        self.launchGradientLayer = nil;
        [self.launchCancelButton removeFromSuperview];
        self.launchCancelButton = nil;
        NSLog(@"[SurfaceViewController] Launch overlay dismissed due to launch error");
    });
}

// Task 139 → Task 140：屏蔽控件门控 —— mod 已启用且开启屏蔽控件时，启动器
// 【自身】的虚拟控件层（ctrlView，经典 Pojav 屏幕按钮）隐藏。
// Task140 语义更新：此开关【只隐藏启动器自身控件】，mod 的虚拟按钮保留
// （上游内置预设自带完整按钮——Task134-139 曾同时给 mod 写空布局导致
// 全屏无按钮，用户反馈“虚拟按钮没有显示”；mod 侧写入已在 Task140
// 退役，存量污染由 JavaLauncher.ame140_remediateTouchControllerConfig
// 一次性修复）。此门控同时作用于：初始加载（loadCustomControls）、
// 鼠标/手柄连接断开时的 hardware_hide 恢复路径（防止意外重新显示）。
// updateControlHiddenState 只改逐按钮 hidden，ctrlView 整层隐藏优先级更高，
// 无需改动。
- (BOOL)ame139_modControlsHidden {
    return getPrefBool(@"control.mod_touch_enable") &&
           getPrefBool(@"control.mod_touch_hide_controls");
}

- (void)loadCustomControls {
    self.edgeGesture.enabled = YES;
    [self.swipeableButtons removeAllObjects];
    NSString *controlFile = [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    [self.ctrlView loadControlFile:controlFile];

    // Task 139：屏蔽控件 —— 启动器自身控件层整体退场（mod 侧空布局预设
    // 已在 JavaLauncher.ame134_applyTouchControllerCleanLayout 写入）。
    if ([self ame139_modControlsHidden]) {
        self.ctrlView.hidden = YES;
        NSLog(@"[SurfaceVC] Task139: launcher control layout hidden (mod hide-controls active)");
    }

    ControlButton *menuButton;
    for (ControlButton *button in self.ctrlView.subviews) {
        BOOL isSwipeable = [button.properties[@"isSwipeable"] boolValue];

        button.canBeHidden = YES;
        BOOL isMenuButton = NO;
        for (int i = 0; i < 4; i++) {
            int keycodeInt = [button.properties[@"keycodes"][i] intValue];
            button.canBeHidden &= keycodeInt != SPECIALBTN_TOGGLECTRL && keycodeInt != SPECIALBTN_VIRTUALMOUSE;
            if (keycodeInt == SPECIALBTN_MENU) {
                menuButton = button;
            }
        }

        [button addTarget:self action:@selector(executebtn_down:) forControlEvents:UIControlEventTouchDown];
        [button addTarget:self action:@selector(executebtn_up_inside:) forControlEvents:UIControlEventTouchUpInside];
        [button addTarget:self action:@selector(executebtn_up_outside:) forControlEvents:UIControlEventTouchUpOutside];

        if (isSwipeable) {
            UIPanGestureRecognizer *panRecognizerButton = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(executebtn_swipe:)];
            panRecognizerButton.delegate = self;
            [button addGestureRecognizer:panRecognizerButton];
            [self.swipeableButtons addObject:button];
        }
    }

    [self updateControlHiddenState:self.toggleHidden];

    if (menuButton) {
        NSMutableArray *items = [NSMutableArray new];
        for (int i = 0; i < self.menuArray.count; i++) {
            UIAction *item = [UIAction actionWithTitle:localize(self.menuArray[i], nil) image:nil identifier:nil
                handler:^(id action) {[self didSelectMenuItem:i];}];
            [items addObject:item];
        }
        menuButton.menu = [UIMenu menuWithTitle:@"" image:nil identifier:nil
            options:UIMenuOptionsDisplayInline children:items];
        menuButton.showsMenuAsPrimaryAction = YES;
        self.edgeGesture.enabled = NO;
    }
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
    [coordinator animateAlongsideTransition:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        self.rootView.bounds = CGRectMake(0, 0, size.width + 30.0, size.height);

        CGRect frame = self.view.frame;
        frame.size = size;
        self.touchView.frame = frame;
        self.inputTextField.frame = CGRectMake(0, -32.0, size.width, 30.0);
        [self viewWillTransitionToSize_LogView:frame];
        [self viewWillTransitionToSize_Navigation:frame];
        self.ctrlView.frame = getSafeArea(self.view.frame);
        [self.ctrlView.subviews makeObjectsPerformSelector:@selector(update)];
        [self updateSavedResolution];
        [GyroInput updateOrientation];
    } completion:^(id<UIViewControllerTransitionCoordinatorContext>  _Nonnull context) {
        virtualMouseFrame = self.mousePointerView.frame;
    }];
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
}

#pragma mark - Input: send touch utilities

- (BOOL)isTouchInactive:(UITouch *)touch {
    return touch == nil || touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled;
}

- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event
{
    CGFloat screenScale = self.screenScale;
    // Task 78（FSR 输入口径）：输入像素空间必须等于 MC 窗口信念
    // windowWidth×windowHeight（Task59 定案：MC 按告知窗口尺寸归一化）。
    // view 点 × screenScale = 物理空间；窗口 = 物理 × resolutionScale
    // 再 ÷ fsr_scale（window = surface/fsr，surface = 物理×resolutionScale）。
    // Task175 修正：×resolutionScale 从 "!isGrabbing" 分支提出为无条件——
    // 旧代码只在非抓取（菜单）态乘，抓取（游戏内）态漏乘：分辨率 ≠100% 的
    // 会话里游戏内触点/视角映射整体偏大 1/resolutionScale 倍（用户实测
    // "更换分辨率后位置偏移"的存活根因之一；历史会话 resScale 恒 1.00
    // 所以从未暴露）。FSR 除法保持原位（Task78 锚点）。
    if (mgFsrScale > 0.0f) screenScale /= mgFsrScale;
    screenScale *= resolutionScale;
    // Task202（议题 #1）：双指滚动手势进行中——光标移动抑制（虚拟/非虚拟
    // 鼠标同门；ACTION_DOWN/UP 不受影响，点击照常）。锚点照常推进：
    // 滚动结束后的首个 MOVE 不会把光标瞬移到旧锚点的反向 delta 上。
    if (!isGrabbing && event == ACTION_MOVE && self.ame202ScrollGestureActive) {
        lastVirtualMousePoint = location;
        return;
    }
    if (!isGrabbing) {
        if (virtualMouseEnabled) {
            if (event == ACTION_MOVE) {
                virtualMouseFrame.origin.x += (location.x - lastVirtualMousePoint.x) * self.mouseSpeed;
                virtualMouseFrame.origin.y += (location.y - lastVirtualMousePoint.y) * self.mouseSpeed;
            } else if (event == ACTION_MOVE_MOTION) {
                event = ACTION_MOVE;
                virtualMouseFrame.origin.x += location.x * self.mouseSpeed;
                virtualMouseFrame.origin.y += location.y * self.mouseSpeed;
            }
            virtualMouseFrame.origin.x = clamp(virtualMouseFrame.origin.x, 0, self.surfaceView.frame.size.width);
            virtualMouseFrame.origin.y = clamp(virtualMouseFrame.origin.y, 0, self.surfaceView.frame.size.height);
            lastVirtualMousePoint = location;
            self.mousePointerView.frame = virtualMouseFrame;
            CallbackBridge_nativeSendCursorPos(event, virtualMouseFrame.origin.x * screenScale, virtualMouseFrame.origin.y * screenScale);
            return;
        }
        lastVirtualMousePoint = location;
    }
    CallbackBridge_nativeSendCursorPos(event, location.x * screenScale, location.y * screenScale);
}

#pragma mark - Input: on-surface functions

// Task171：键盘首会话自愈重挂——becomeFirstResponder 成功后 0.4s 复查；
// 若系统（UIAsyncTextInput 首会话竞争）已把字段打回非 first responder，
// 自动重挂一次（最多递归 2 层，防硬件键盘场景死循环）。装机日志实锤
// "触发键盘后直接输入各种问题，必须再按一次输入法按钮才能正常输入"
// ——本方法就是把用户手动做的那"再按一次"自动化。
// （ame171_keyboardDismissGeneration 的定义在文件前部静态区。）
- (void)ame171_armKeyboardRecheck:(int)depth {
    if (depth > 2) return;
    NSUInteger gen = ame171_keyboardDismissGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (gen != ame171_keyboardDismissGeneration) return;   // 用户已主动收起
        if (strongSelf.inputTextField.isFirstResponder) return; // 会话健康
        strongSelf.inputTextField.text = @" ";
        BOOL ok = [strongSelf.inputTextField becomeFirstResponder];
        NSLog(@"[SurfaceVC] Task171: keyboard auto re-arm depth=%d (system dismissed the field after show; ok=%d)",
              depth, ok);
        [strongSelf ame171_armKeyboardRecheck:depth + 1];
    });
}

// Task172：SDL StartTextInput 路由——把键盘拉到启动器字段（在 SDL UIKit
// 的 textField 抢占之后，同轮主队列内执行，稳赢 first responder）。
// 已是 first responder 时不动（MC 在两个文本框间切换焦点时不得打断
// 进行中的输入会话）。
- (void)ame172_sdlStartTextInput:(NSNotification *)n {
    if (!self.inputTextField) return;
    if (self.inputTextField.isFirstResponder) return;
    // Task171 哨兵空格先于 becomeFirstResponder 写入（防 UIAsyncTextInput
    // 首会话竞争，与 ✎ 按钮同序）
    self.inputTextField.text = @" ";
    BOOL ok = [self.inputTextField becomeFirstResponder];
    NSLog(@"[SurfaceVC] Task172 SDL auto-keyboard routed to launcher field (becameFR=%d)", ok);
    [self ame171_armKeyboardRecheck:0];
}

// Task172：SDL StopTextInput 路由——MC 关闭文本上下文（发送/ESC）时同步
// 收起启动器字段。代数计数器照常递增，作废可能还在飞的自愈重挂。
- (void)ame172_sdlStopTextInput:(NSNotification *)n {
    if (!self.inputTextField) return;
    if (self.inputTextField.isFirstResponder) {
        // ★ Task222（清单第 12 项）：IME 组合输入守卫——"输入法输入一部分后
        //   再输入会关闭键盘"的根修。MC 26.x 的 EditBox 在部分输入场景会
        //   快速 Stop->Start 文本上下文（每次字符事件都可能重设上下文）；
        //   Stop 分支的 resign 会把进行中的 IME 组合态（拼音/注音缓冲，
        //   markedTextRange 非空）整个拆掉——键盘收起、缓冲丢弃，用户
        //   必须重新聚焦从头再打。组合进行中跳过本次 resign：紧随的
        //   Start 分支有 isFirstResponder 早退守卫（不会打断），MC 后续
        //   真正关闭上下文（发送/ESC）时组合态早已上屏，正常收起。
        if (self.inputTextField.markedTextRange != nil) {
            NSLog(@"[SurfaceVC] Task222 IME guard: skip resign during marked-text composition");
            return;
        }
        ame171_keyboardDismissGeneration++;
        [self.inputTextField resignFirstResponder];
        self.inputTextField.alpha = 1.0f;
        NSLog(@"[SurfaceVC] Task172 SDL stop-text-input: keyboard resigned with MC text context");
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)keyboardGesture:(UIGestureRecognizer*)gestureRecognizer {
    // [ä¿®æ­£] æ·»å äºå¯¹è®¾ç½®é¡¹ control.two_finger_keyboard çæ£æ¥
    if (!getPrefBool(@"control.two_finger_keyboard")) {
        return;
    }

    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        if (self.inputTextField.isFirstResponder) {
            ame171_keyboardDismissGeneration++;
            [self.inputTextField resignFirstResponder];
            self.inputTextField.alpha = 1.0f;
        } else {
            // Task171：哨兵空格先于 becomeFirstResponder 写入（旧序反着来，
            // 与 UIAsyncTextInput 异步会话激活竞争，首会话被系统拆掉）
            self.inputTextField.text = @" ";
            [self.inputTextField becomeFirstResponder];
            [self ame171_armKeyboardRecheck:0];
        }
    }
}

- (void)sendTouchEvent:(UITouch *)touchEvent withUIEvent:(UIEvent *)uievent withEvent:(int)event
{
    // Task59：rootView 比 surfaceView 宽 30pt（菜单溢出，层级转储 1210x820 层），
    // 游戏画面在 rootView 内两侧各缩进 15pt——用 rootView 坐标会给启动器直发
    // 路径引入 +15pt 恒定水平偏移，且与 TouchController mod 的 surfaceView
    // 归一化口径不一致。改用 surfaceView 参考系（mod 路径同款，下游
    // touchHotbar 的 phys=2360x1640 数学也以游戏表面为基准）。
    CGPoint locationInView = [touchEvent locationInView:self.surfaceView];
    switch (event) {
        case ACTION_DOWN:
            // Task202（议题 #1）：点击容差 5x5 → 24x24pt（居中）。装机反馈
            // “虚拟鼠标点击失效”：手指轻点的自然漂移普遍超过 5pt（指尖
            // 接触面变化 + 抬起漂移），旧容差把真实点击误判为拖拽吞掉。
            self.clickRange = CGRectMake(locationInView.x - 12, locationInView.y - 12, 24, 24);
            self.shouldTriggerClick = YES;
            break;
        case ACTION_MOVE:
            if (self.shouldTriggerClick && !CGRectContainsPoint(self.clickRange, locationInView)) {
                self.shouldTriggerClick = NO;
            }
            break;
    }

    if (touchEvent == self.hotbarTouch && self.slideableHotbar && ![self isTouchInactive:self.hotbarTouch]) {
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        int slot = self.enableHotbarGestures ?
        callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if (slot != -1 && currentHotbarSlot != slot && (event == ACTION_DOWN || currentHotbarSlot != -1)) {
            currentHotbarSlot = slot;
            CallbackBridge_nativeSendKey(slot, 0, 1, 0);
            CallbackBridge_nativeSendKey(slot, 0, 0, 0);
            return;
        }
        if (event == ACTION_DOWN && slot == -1) {
            currentHotbarSlot = -1;
        }
        return;
    }

    if (touchEvent == self.primaryTouch) {
        if ([self isTouchInactive:self.primaryTouch] && event != ACTION_UP) return; 
        if (event == ACTION_MOVE && isGrabbing) {
            event = ACTION_MOVE_MOTION;
            CGPoint prevLocationInView = [touchEvent previousLocationInView:self.rootView];
            locationInView.x -= prevLocationInView.x;
            locationInView.y -= prevLocationInView.y;
        }
        [self sendTouchPoint:locationInView withEvent:event];
    }
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:YES];
        }
    }
    // Forward to SDL view for MC 26.3 (SDL3 input)
    UIView *sdlView = findSDL_uikitview(self.view);
    if (sdlView) [sdlView pressesBegan:presses withEvent:event];
    // Always call super so that inputTextField (UITextInput) can receive
    // key events for text input (e.g., Minecraft chat).
    [super pressesBegan:presses withEvent:event];
}

- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    for (UIPress *press in presses) {
        if (press.key != nil) {
            [KeyboardInput sendKeyEvent:press.key down:NO];
        }
    }
    // Forward to SDL view for MC 26.3 (SDL3 input)
    UIView *sdlView = findSDL_uikitview(self.view);
    if (sdlView) [sdlView pressesEnded:presses withEvent:event];
    // Always call super so that inputTextField (UITextInput) can receive
    // key-up events properly.
    [super pressesEnded:presses withEvent:event];
}

- (BOOL)prefersPointerLocked {
    return GCMouse.mice.count > 0 && (isGrabbing || virtualMouseEnabled);
}

- (void)registerMouseCallbacks:(GCMouse *)mouse {
    NSLog(@"Input: Got mouse %@", mouse);
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput * _Nonnull mouse, float deltaX, float deltaY) {
        // Always forward mouse movement to the game.
        // When pointer is locked (in-game grabbing), deltaX/deltaY are true deltas.
        // When pointer is NOT locked (menu, or Bluetooth mouse before lock activates),
        // we still send the delta so the virtual mouse or cursor can move.
        [self sendTouchPoint:CGPointMake(deltaX, -deltaY) withEvent:ACTION_MOVE_MOTION];
    };

    mouse.mouseInput.leftButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, pressed, 0);
    };
    mouse.mouseInput.middleButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, pressed, 0);
    };
    mouse.mouseInput.rightButton.pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
        CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, pressed, 0);
    };
    for (int i = 0; i < MIN(mouse.mouseInput.auxiliaryButtons.count, 5); i++) {
        mouse.mouseInput.auxiliaryButtons[i].pressedChangedHandler = ^(GCControllerButtonInput * _Nonnull button, float value, BOOL pressed) {
            CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_4 + i, pressed, 0);
        };
    }

    mouse.mouseInput.scroll.xAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(value, value);
    };
    mouse.mouseInput.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput * _Nonnull axis, float value) {
        CallbackBridge_nativeSendScroll(-value, -value);
    };

    if (getPrefBool(@"control.hardware_hide")) {
        self.ctrlView.hidden = YES;
    }
}

- (void)surfaceOnClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    if (!self.shouldTriggerClick) return;

    if (sender.state == UIGestureRecognizerStateRecognized) {
        if (currentHotbarSlot == -1) {
            if (!self.enableMouseGestures) return;
            CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 1, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 33 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                CallbackBridge_nativeSendMouseButton(isGrabbing == JNI_TRUE ?
                    GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT, 0, 0);
            });
        } else {
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 1, 0);
            CallbackBridge_nativeSendKey(currentHotbarSlot, 0, 0, 0);
        }
    }
}

- (void)surfaceOnDoubleClick:(UITapGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }
    if (sender.state == UIGestureRecognizerStateRecognized && isGrabbing) {
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        CGPoint point = [sender locationInView:self.rootView];
        int hotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(point.x * screenScale, point.y * screenScale) : -1;
        if (hotbarSlot != -1 && currentHotbarSlot == hotbarSlot) {
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 1, 0);
            CallbackBridge_nativeSendKey(GLFW_KEY_F, 0, 0, 0);
        }
    }
}

- (void)surfaceOnHover:(UIGestureRecognizer *)sender {
    if (isGrabbing) return;
    CGPoint point = [sender locationInView:self.rootView];
    switch (sender.state) {
        case UIGestureRecognizerStateBegan:
            [self sendTouchPoint:point withEvent:ACTION_DOWN];
            break;
        case UIGestureRecognizerStateChanged:
            [self sendTouchPoint:point withEvent:ACTION_MOVE];
            break;
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
            [self sendTouchPoint:point withEvent:ACTION_UP];
            break;
        default:
            break;
    }
}

-(void)surfaceOnLongpress:(UILongPressGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.mediumHaptic impactOccurred];
        }
    }

    if (!self.slideableHotbar) {
        CGPoint location = [sender locationInView:self.rootView];
        CGFloat screenScale = UIScreen.mainScreen.scale;
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(location.x * screenScale, location.y * screenScale) : -1;
    }
    if (sender.state == UIGestureRecognizerStateBegan) {
        self.shouldTriggerClick = NO;
        if (currentHotbarSlot == -1) {

            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 1, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 1, 0);
        }
    } else if (sender.state == UIGestureRecognizerStateChanged) {
    } else if (sender.state == UIGestureRecognizerStateCancelled
        || sender.state == UIGestureRecognizerStateFailed
            || sender.state == UIGestureRecognizerStateEnded)
    {
        if (currentHotbarSlot == -1) {
            if (self.enableMouseGestures)
                CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, 0, 0);
        } else {
            CallbackBridge_nativeSendKey(GLFW_KEY_Q, 0, 0, 0);
        }
    }
}

- (void)surfaceOnTouchesScroll:(UIPanGestureRecognizer *)sender {
    if (sender.state == UIGestureRecognizerStateBegan || sender.state == UIGestureRecognizerStateEnded){
        if(self.shouldTriggerHaptic) {
            [self.lightHaptic impactOccurred];
        }
    }

    // Task202（议题 #1）：滚动手势活跃标记——Began/Changed 置位；
    // Ended/Cancelled 异步清除（手势 Ended 先于同批 touchesEnded 派发，
    // 同步清会让尾批 MOVE 逃逸抑制窗，光标小跳一帧）。
    if (sender.state == UIGestureRecognizerStateBegan ||
        sender.state == UIGestureRecognizerStateChanged) {
        self.ame202ScrollGestureActive = YES;
    } else if (sender.state == UIGestureRecognizerStateEnded ||
               sender.state == UIGestureRecognizerStateCancelled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ame202ScrollGestureActive = NO;
        });
    }

    if (isGrabbing) return;
    if (sender.state == UIGestureRecognizerStateBegan ||
        sender.state == UIGestureRecognizerStateChanged ||
        sender.state == UIGestureRecognizerStateEnded) {
        CGPoint velocity = [sender velocityInView:self.rootView];
        if (velocity.x != 0.0f || velocity.y != 0.0f) {
            // Bug fix: view.frame.size 在窗口最小化、转场动画中可能为零，
            // 除零产生 NaN/Inf 传入 native 层导致滚动异常。
            CGFloat w = self.view.frame.size.width;
            CGFloat h = self.view.frame.size.height;
            if (w > 0 && h > 0) {
                CallbackBridge_nativeSendScroll(velocity.x / w, velocity.y / h);
            }
        }
    }
}

#pragma mark - Input view stuff

-(BOOL)textFieldShouldReturn:(UITextField *)textField {
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 1, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_ENTER, 0, 0, 0);
    textField.text = @" ";
    return YES;
}

#pragma mark - On-screen button functions

- (void)executebtn:(ControlButton *)sender withAction:(int)action {
    // Task 83b：入口取证——⌨ 面板问题的日志闭环。此前 sendKey（nativeSendKey）
    // 与字符合成端（buttonKeySynthesizeText）都有日志，唯独 executebtn 入口
    // 没有：按钮没触发 / 键位为 0 / 事件被上游吞掉 三种情况在日志里长得
    // 一模一样（全是零事件）。装机日志判读实锤：用户点字母时零日志零事件，
    // 真凶是背景板吞触摸（见 CustomControlsUtils Task83b）。前 20 次 + 每
    // 100 次记录按钮名与四键位，下次反馈可直接定位到层。
    static int s_task83bEntry = 0;
    s_task83bEntry++;
    if (s_task83bEntry <= 20 || s_task83bEntry % 100 == 0) {
        NSLog(@"[InputDiag] Task83b executebtn #%d: name=%@ action=%d keycodes=[%d,%d,%d,%d]",
              s_task83bEntry, sender.properties[@"name"], action,
              [sender.properties[@"keycodes"][0] intValue],
              [sender.properties[@"keycodes"][1] intValue],
              [sender.properties[@"keycodes"][2] intValue],
              [sender.properties[@"keycodes"][3] intValue]);
    }
    int held = action == ACTION_DOWN;
    // ===== Task179：修饰键 TOGGLE 语义（右shift 无效第二轮根修）=====
    // 病历（9aacebb 装机 latestlog.1）：事件链依旧全绿（sc=229 送达 MC、
    // KeyMapping.set(right.shift) 执行），但 Task176 的"粘滞到下一键"语义
    // 让用户仍然无法使用：轻点右shift 后【任何】非修饰输入（包括摇杆/屏幕
    // 触摸）都会立即自动释放它——"点 shift 再移动"的潜行用法被结构性杀死。
    // Task179 新语义（移动启动器通用约定）：
    //   轻点 = 开关（toggle）：再点一次才关；期间任意其它输入不影响；
    //   长按（≥0.4s）= 常规按住：抬手即释放（并清除该键的 toggle 态）。
    // 潜行（点 shift→移动→再点关）、shift+点击（点 shift→点击→再点关）、
    // 大写字母（长按 shift+字母）三种用法全部成立。
    static NSMutableDictionary<NSNumber *, NSNumber *> *s_ame176_modDownTime = nil;
    static NSMutableSet<NSNumber *> *s_ame179_toggledMods = nil;
    if (s_ame176_modDownTime == nil) {
        s_ame176_modDownTime = [NSMutableDictionary dictionary];
        s_ame179_toggledMods = [NSMutableSet set];
    }
#define AME176_IS_MOD_KEY(kc) \
    ((kc) == GLFW_KEY_LEFT_SHIFT || (kc) == GLFW_KEY_RIGHT_SHIFT || \
     (kc) == GLFW_KEY_LEFT_CONTROL || (kc) == GLFW_KEY_RIGHT_CONTROL || \
     (kc) == GLFW_KEY_LEFT_ALT || (kc) == GLFW_KEY_RIGHT_ALT || \
     (kc) == GLFW_KEY_LEFT_SUPER || (kc) == GLFW_KEY_RIGHT_SUPER)
    for (int i = 0; i < 4; i++) {
        int keycode = ((NSNumber *)sender.properties[@"keycodes"][i]).intValue;
        if (keycode < 0) {
            switch (keycode) {
                case SPECIALBTN_KEYBOARD:
                    if (held == 0) {
                        // Task 82：键盘控件取证——按钮触发 + becomeFirstResponder 结果
                        // （26.3 下打字靠 input_bridge_v3 的 SDL_EVENT_TEXT_INPUT 路径）
                        BOOL wasFirst = self.inputTextField.isFirstResponder;
                        if (wasFirst) {
                            ame171_keyboardDismissGeneration++;
                            [self.inputTextField resignFirstResponder];
                            self.inputTextField.alpha = 1.0f;
                            NSLog(@"[Task82] Keyboard widget: dismissing (was first responder)");
                        } else {
                            // Task171：哨兵空格先于 becomeFirstResponder 写入。
                            // 病历（f26337d 装机日志 latestlog.old.txt，多人服务器
                            // 聊天登录）：每次按 ✎输入法 按钮日志都是
                            // "becomeFirstResponder=1"（而非 "dismissing"）——
                            // 字段在每输一个字符后被系统自行拆会话（旧序：
                            // become 后立即改 text，与 iPadOS 26+ UIAsyncTextInput
                            // 的异步会话激活竞争），用户被迫每打一个字按一次
                            // 输入法按钮；几个循环后（或 ESC+重开聊天后）
                            // 输入才稳定。修法：写入顺序反转 + 清空位退役
                            // （初始化处）+ ame171_armKeyboardRecheck 自愈重挂。
                            self.inputTextField.text = @" ";
                            BOOL ok = [self.inputTextField becomeFirstResponder];
                            NSLog(@"[Task82] Keyboard widget: becomeFirstResponder=%d (on-screen keyboard should appear; typing delivered via SDL text-input on 26.3)", ok);
                            [self ame171_armKeyboardRecheck:0];
                        }
                    }
                    break;
                case SPECIALBTN_MOUSEPRI:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_LEFT, held, 0);
                    break;
                case SPECIALBTN_MOUSESEC:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_RIGHT, held, 0);
                    break;
                case SPECIALBTN_MOUSEMID:
                    CallbackBridge_nativeSendMouseButton(GLFW_MOUSE_BUTTON_MIDDLE, held, 0);
                    break;
                case SPECIALBTN_TOGGLECTRL:
                    [self executebtn_special_togglebtn:held];
                    break;
                case SPECIALBTN_SCROLLDOWN:
                    if (!held) { CallbackBridge_nativeSendScroll(0.0, 1.0); }
                    break;
                case SPECIALBTN_SCROLLUP:
                    if (!held) { CallbackBridge_nativeSendScroll(0.0, -1.0); }
                    break;
                case SPECIALBTN_VIRTUALMOUSE:
                    if (!isGrabbing && !held) {
                        virtualMouseEnabled = !virtualMouseEnabled;
                        self.mousePointerView.hidden = !virtualMouseEnabled;
                        setPrefBool(@"control.virtmouse_enable", virtualMouseEnabled);
                        [self setNeedsUpdateOfPrefersPointerLocked];
                    }
                    break;
                case SPECIALBTN_MENU:
                    if (!held) { [self actionOpenNavigationMenu]; }
                    break;
                default:
                    NSLog(@"Warning: button %@ sent unknown special keycode: %d", sender.titleLabel.text, keycode);
                    break;
            }
        } else if (keycode > 0) {
            // Task179：修饰键 toggle 判定（在 nativeSendKey 之前）。
            if (AME176_IS_MOD_KEY(keycode)) {
                if (held) {
                    // DOWN：记录按压起点（供 UP 时区分轻点/长按）。
                    s_ame176_modDownTime[@(keycode)] = @(CFAbsoluteTimeGetCurrent());
                } else {
                    NSNumber *ame176_downT = s_ame176_modDownTime[@(keycode)];
                    [s_ame176_modDownTime removeObjectForKey:@(keycode)];
                    BOOL ame179_wasTap = (ame176_downT != nil &&
                                          CFAbsoluteTimeGetCurrent() - ame176_downT.doubleValue < 0.4);
                    BOOL ame179_wasToggled = [s_ame179_toggledMods containsObject:@(keycode)];
                    if (ame179_wasTap) {
                        if (ame179_wasToggled) {
                            // 轻点在 toggle 态上：关闭（补发 UP），流程继续到
                            // 下方的 nativeSendKey(..., 0, ...) 把 UP 发出去。
                            [s_ame179_toggledMods removeObject:@(keycode)];
                            NSLog(@"[InputDiag] Task179 mod toggle OFF: keycode=%d (tap on toggled state)", keycode);
                        } else {
                            // 轻点在常态上：开启（扣住 UP，保持按下态）。
                            [s_ame179_toggledMods addObject:@(keycode)];
                            NSLog(@"[InputDiag] Task179 mod toggle ON: keycode=%d (tap; stays down until next tap)", keycode);
                            continue;
                        }
                    } else {
                        // 长按释放：常规 UP，同时清除 toggle 态（按住玩法优先）。
                        [s_ame179_toggledMods removeObject:@(keycode)];
                    }
                }
            }
            CallbackBridge_nativeSendKey(keycode, 0, held, 0);
            // Task83：按钮键盘打字支持。custom 布局"键盘图标"抽屉里的
            // 字母/数字/符号按钮只发 key 事件，而 MC 1.13+ 聊天框只消费
            // charTyped（text-input）事件 → 此前完全打不了字。按下时补发
            // 字符；Ctrl/Alt 按住时由助手抑制（快捷键语义，组合键不灌字符）。
            if (held) {
                CallbackBridge_buttonKeySynthesizeText(keycode);
            }
        }
    }

    // Task179："非修饰输入自动释放锁定修饰键"机制退役——正是它让
    // "点 shift 再移动"的潜行用法失效（任何输入都把 shift 弹起）。
    // toggle 态只由再次轻点或长按释放，语义自洽。
}

- (void)executebtn_down:(ControlButton *)sender
{
    if(self.shouldTriggerHaptic) { [self.lightHaptic impactOccurred]; }
    if (sender.savedBackgroundColor == nil) { [self executebtn:sender withAction:ACTION_DOWN]; }
    if ([self.swipeableButtons containsObject:sender]) { self.swipingButton = sender; }
}

- (void)executebtn_swipe:(UIPanGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateCancelled || sender.state == UIGestureRecognizerStateEnded) {
        [self executebtn_up:self.swipingButton isOutside:NO];
        return;
    }
    CGPoint location = [sender locationInView:self.ctrlView];
    for (ControlButton *button in self.swipeableButtons) {
        if (CGRectContainsPoint(button.frame, location) && (ControlButton *)self.swipingButton != button) {
            [self executebtn_up:self.swipingButton isOutside:NO];
            self.swipingButton = (ControlButton *)button;
            [self executebtn:self.swipingButton withAction:ACTION_DOWN];
            break;
        }
    }
}

- (void)executebtn_up:(ControlButton *)sender isOutside:(BOOL)isOutside
{
    if (self.swipingButton == sender) {
        [self executebtn:self.swipingButton withAction:ACTION_UP];
        self.swipingButton = nil;
    } else if (sender.savedBackgroundColor == nil) {
        [self executebtn:sender withAction:ACTION_UP];
        return;
    }

    if (isOutside || sender.savedBackgroundColor == nil) { return; }

    sender.isToggleOn = !sender.isToggleOn;
    if (sender.isToggleOn) {
        sender.backgroundColor = [self.view.tintColor colorWithAlphaComponent:CGColorGetAlpha(sender.savedBackgroundColor.CGColor)];
        [self executebtn:sender withAction:ACTION_DOWN];
    } else {
        sender.backgroundColor = sender.savedBackgroundColor;
        [self executebtn:sender withAction:ACTION_UP];
    }

    if(self.shouldTriggerHaptic) { [self.lightHaptic impactOccurred]; }
}

- (void)executebtn_up_inside:(ControlButton *)sender { [self executebtn_up:sender isOutside:NO]; }
- (void)executebtn_up_outside:(ControlButton *)sender { [self executebtn_up:sender isOutside:YES]; }

- (void)executebtn_special_togglebtn:(int)held {
    if (held) return;
    self.toggleHidden = !self.toggleHidden;
    [self updateControlHiddenState:self.toggleHidden];
}

#pragma mark - Input: On-screen touch events (TouchController Mod Integration)

static int32_t s_fingerIdCounter = 0;
static NSMutableDictionary *s_touchToFingerIdMap = nil;

- (int32_t)getFingerId:(UITouch *)touch {
    // Lazy initialize the map
    if (!s_touchToFingerIdMap) {
        s_touchToFingerIdMap = [NSMutableDictionary dictionary];
    }
    
    // Use touch pointer address as key (UITouch doesn't support NSCopying)
    NSString *touchKey = [NSString stringWithFormat:@"%p", touch];
    
    // Check if we already have a finger ID for this touch
    NSNumber *fingerIdNum = [s_touchToFingerIdMap objectForKey:touchKey];
    if (fingerIdNum) {
        return [fingerIdNum intValue];
    }
    
    // Generate a new unique finger ID
    s_fingerIdCounter = (s_fingerIdCounter + 1) % 100000;
    int32_t newFingerId = s_fingerIdCounter;
    
    // Store the mapping
    [s_touchToFingerIdMap setObject:@(newFingerId) forKey:touchKey];
    
    return newFingerId;
}

// Clear the touch to finger ID map when touches end
- (void)clearTouchToFingerIdMapForTouches:(NSSet *)touches {
    if (!s_touchToFingerIdMap) return;
    
    for (UITouch *touch in touches) {
        NSString *touchKey = [NSString stringWithFormat:@"%p", touch];
        [s_touchToFingerIdMap removeObjectForKey:touchKey];
    }
}

// Clear all touch to finger ID mappings
- (void)clearAllTouchToFingerIdMappings {
    if (s_touchToFingerIdMap) {
        [s_touchToFingerIdMap removeAllObjects];
    }
}

// Find the embedded SDL_uikitview (MC 26.3 uses SDL3 for input).
static UIView *findSDL_uikitview(UIView *root) {
    static Class sdlCls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ sdlCls = NSClassFromString(@"SDL_uikitview"); });
    if (!sdlCls) return nil;
    if ([root isKindOfClass:sdlCls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = findSDL_uikitview(sub);
        if (found) return found;
    }
    return nil;
}

// ============================================================================
// ★ [FG] 上游 d76301816 同步（Task222）：SDL3 呈现面执法函数族。
//   供 SceneDelegate 的前后台生命周期回调使用（回前台自愈）；也可被
//   gl_bridge / 其它路径周期性重跑——设计上幂等且全程 @try。
//   覆盖三个黑屏遮挡源（Air Task 32/52 法证）：
//     (a) SDL 自建 UIWindow 被 makeKeyAndVisible 浮在宿主之上（空窗黑盖子）；
//     (b) 供应商 libSDL3.dylib 的 Zalith 同源嵌入补丁对 GameSurfaceView
//         setHidden:YES（但它的 CAMetalLayer 才是 GL/Vulkan 真正呈现面）；
//     (c) SDL 嵌入视图的 CAMetalLayer 默认 opaque=1 整块盖住画面。
// ============================================================================

// 找到当前嵌入的 SDL 视图；非 SDL3 路径返回 nil。
static UIView *Amethyst_FindSDLView(void) {
    UIWindow *host = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive ||
                ![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.hidden && w.rootViewController != nil) { host = w; break; }
            }
            if (host) break;
        }
    }
    if (!host) host = UIApplication.sharedApplication.keyWindow;

    UIView *root = host.rootViewController.view;
    if (!root && pojavWindow != nil) root = pojavWindow.window.rootViewController.view;
    if (!root) return nil;
    return findSDL_uikitview(root);
}

// 回退开关：AMETHYST_KEEP_SDL_METAL=1 时保留 SDL 的金属子层（仅透明化，
// 不隐藏）。默认隐藏 —— EGL 路径下真正的呈现面是 GameSurfaceView 的
// CAMetalLayer，SDL 的金属层不是渲染目标，留着只会整块盖住画面。
static BOOL ame_keepSDLMetalLayer(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *e = getenv("AMETHYST_KEEP_SDL_METAL");
        cached = (e != NULL && atoi(e) == 1) ? 1 : 0;
    }
    return cached == 1;
}

static BOOL ame_applyTransparentRecursive(UIView *v, BOOL isRoot) {
    if (v == nil) return NO;
    BOOL changed = NO;
    BOOL isMetal = [v.layer isKindOfClass:CAMetalLayer.class];
    if (isRoot || isMetal) {
        if (v.opaque) { v.opaque = NO; changed = YES; }
        if (v.layer.opaque) { v.layer.opaque = NO; changed = YES; }
        if (v.backgroundColor != nil &&
            CGColorGetAlpha(v.backgroundColor.CGColor) > 0.0) {
            v.backgroundColor = UIColor.clearColor;
            changed = YES;
        }
    }
    // 预编译 libSDL3.dylib 在 SDL 视图内额外建了 SDL_uikitmetalview 子层
    //（Air 从源码构建 SDL3，不存在这层）。它的 CAMetalLayer 默认 opaque=1
    // 且 drawableSize 为全屏像素：即便把 opaque 置 NO，只要有内容仍会整块
    // 盖住画面。EGL 路径下它不是渲染目标，直接移出合成最稳妥（可用
    // AMETHYST_KEEP_SDL_METAL=1 回退为仅透明化）。
    if (isMetal && !isRoot && !ame_keepSDLMetalLayer()) {
        if (!v.hidden) { v.hidden = YES; changed = YES; }
    }
    for (UIView *sub in v.subviews) {
        if (ame_applyTransparentRecursive(sub, NO)) changed = YES;
    }
    return changed;
}

// 让 SDL 嵌入视图（含其金属子层）退出"整块黑层"状态。
// 非 SDL3 路径返回 NO、不改动任何状态。
BOOL Amethyst_MakeSDLRenderTransparent(void) {
    UIView *sdl = Amethyst_FindSDLView();
    if (sdl == nil) return NO;
    return ame_applyTransparentRecursive(sdl, YES);
}

// 一次性诊断：把「谁在谁上面」完整 dump 出来。只在检测到异常时打印，
// 且总预算有限，避免高频执法刷屏。
static void ame_dumpPresentationState(const char *reason) {
    static int budget = 6;
    if (budget <= 0) return;
    budget--;

    NSMutableString *m = [NSMutableString string];
    [m appendFormat:@"[Amethyst][diag] presentation dump (%s)\n", reason];

    NSArray *wins = [UIApplication sharedApplication].windows;
    [m appendFormat:@"  windows=%lu\n", (unsigned long)wins.count];
    for (UIWindow *w in wins) {
        [m appendFormat:@"    win=%@ rc=%@ hidden=%d level=%.0f key=%d frame=%@\n",
            NSStringFromClass(w.class),
            w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"(nil)",
            (int)w.hidden, w.windowLevel, (int)w.isKeyWindow,
            NSStringFromCGRect(w.frame)];
    }

    UIView *gs = pojavWindow;
    if (gs) {
        CALayer *l = gs.layer;
        NSString *ds = @"(n/a)";
        if ([l isKindOfClass:CAMetalLayer.class]) {
            CGSize sz = ((CAMetalLayer *)l).drawableSize;
            ds = [NSString stringWithFormat:@"%.0fx%.0f", sz.width, sz.height];
        }
        [m appendFormat:@"  gameSurface=%@ hidden=%d layerHidden=%d layer=%@ layerOpaque=%d "
                        @"scale=%.2f drawable=%@ frame=%@ window=%@\n",
            NSStringFromClass(gs.class), (int)gs.hidden, (int)l.hidden,
            NSStringFromClass(l.class), (int)l.opaque, l.contentsScale, ds,
            NSStringFromCGRect(gs.frame),
            gs.window ? NSStringFromClass(gs.window.class) : @"(nil)"];
    } else {
        [m appendString:@"  gameSurface=(nil)\n"];
    }

    UIView *sdl = Amethyst_FindSDLView();
    if (sdl) {
        CALayer *l = sdl.layer;
        NSString *ds = @"(n/a)";
        if ([l isKindOfClass:CAMetalLayer.class]) {
            CGSize sz = ((CAMetalLayer *)l).drawableSize;
            ds = [NSString stringWithFormat:@"%.0fx%.0f", sz.width, sz.height];
        }
        [m appendFormat:@"  sdlView=%@ hidden=%d opaque=%d layer=%@ layerOpaque=%d "
                        @"scale=%.2f drawable=%@ frame=%@ window=%@\n",
            NSStringFromClass(sdl.class), (int)sdl.hidden, (int)sdl.opaque,
            NSStringFromClass(l.class), (int)l.opaque, l.contentsScale, ds,
            NSStringFromCGRect(sdl.frame),
            sdl.window ? NSStringFromClass(sdl.window.class) : @"(nil)"];
    } else {
        [m appendString:@"  sdlView=(not found)\n"];
    }

    UIView *container = gs ? gs.superview : nil;
    if (container) {
        NSMutableArray *order = [NSMutableArray array];
        for (UIView *v in container.subviews) {
            [order addObject:[NSString stringWithFormat:@"%@(h=%d,op=%d,lo=%d)",
                NSStringFromClass(v.class), (int)v.hidden, (int)v.opaque, (int)v.layer.opaque]];
        }
        [m appendFormat:@"  container=%@ subviews(bottom->top)=%@\n",
            NSStringFromClass(container.class),
            [order componentsJoinedByString:@" | "]];
    }
    NSLog(@"%@", m);
}

// 呈现面执法主入口：隐藏 SDL 自建空窗 + 揭开 GameSurfaceView + SDL 视图
// 透明化 + z 序钉扎。幂等、非游戏态（pojavWindow==nil）直接返回 NO，
// 全程 @try 吞异常。安全保障：
//   * 只在确认存在另一个可见宿主 window 时才隐藏 SDL window；
//   * z 序调整前先确认 SDL 的 layer 已真正透明，否则宁可维持现状；
//   * 任何异常都吞掉并记录，不影响游戏进程。
BOOL Amethyst_EnforceSDL3Presentation(void) {
    if (pojavWindow == nil) return NO;
    UIView *gs = pojavWindow;
    UIView *sdlView = Amethyst_FindSDLView();
    UIView *container = gs.superview;
    if (container == nil) return NO;

    @try {
        BOOL fixed = NO;

        // 1. SDL 自建 UIWindow 永远隐藏，并把 key window 还给宿主。
        //    安全条件：必须存在另一个可见的、非 SDL 的 window 才动手。
        NSArray *allWindows = [UIApplication sharedApplication].windows;
        for (UIWindow *w in allWindows) {
            UIViewController *rc = w.rootViewController;
            if (rc == nil) continue;
            if ([NSStringFromClass(rc.class) rangeOfString:@"SDL_uikitviewcontroller"]
                    .location == NSNotFound) continue;
            if (w.hidden) continue;

            // 安全：确认有替身 host window 可见，且该 host 不是 SDL 自己的
            UIWindow *hostWin = nil;
            for (UIWindow *w2 in allWindows) {
                if (w2 == w || w2.hidden || w2.rootViewController == nil) continue;
                if ([NSStringFromClass(w2.rootViewController.class) rangeOfString:
                        @"SDL_uikitviewcontroller"].location != NSNotFound) continue;
                hostWin = w2;
                break;
            }
            if (hostWin == nil) {
                ame_dumpPresentationState("SDL window found but NO host window to fall back");
                continue;   // 绝不把唯一可见窗口藏掉
            }

            w.hidden = YES;
            [hostWin makeKeyWindow];
            fixed = YES;
            NSLog(@"[Amethyst] Task32: SDL UIWindow re-hidden (empty key+visible window "
                  @"covers GameSurfaceView = black screen); host key window restored");
            ame_dumpPresentationState("SDL own UIWindow was visible (black cover)");
        }

        // 2. 揭开真正的渲染呈现面。
        if (gs.hidden || gs.layer.hidden) {
            gs.hidden = NO;
            gs.layer.hidden = NO;
            fixed = YES;
            NSLog(@"[Amethyst] Task52: GameSurfaceView was HIDDEN by SDL provider embed "
                  @"patch -- UN-HIDDEN (it is our render target)");
            ame_dumpPresentationState("GameSurfaceView was hidden");
        }

        // 3. SDL 视图透明化（Air Task 52 原样：sdlView.backgroundColor = nil;
        //    sdlView.opaque = NO;）+ 递归处理预编译 SDL 额外建出的金属子层。
        if (sdlView != nil) {
            if (sdlView.opaque) { sdlView.opaque = NO; fixed = YES; }
            if (sdlView.layer.opaque) { sdlView.layer.opaque = NO; fixed = YES; }
            if (sdlView.backgroundColor != nil) {
                sdlView.backgroundColor = nil;
                fixed = YES;
            }
            if (Amethyst_MakeSDLRenderTransparent()) fixed = YES;
        }

        // 4. z 序终局（Air Task 52 原样）：其它子视图（虚拟鼠标指针、控制按钮）
        //    压回 SDL 视图之上，GameSurfaceView 紧贴 SDL 触摸视图之下 ——
        //    画面在下、触摸层在上，靠 SDL 视图透明透出画面。
        if (sdlView != nil && sdlView.superview == container) {
            for (UIView *sub in [container.subviews copy]) {
                if (sub != sdlView && sub != gs) [container bringSubviewToFront:sub];
            }
            NSArray *subs = container.subviews;
            NSUInteger gi = [subs indexOfObjectIdenticalTo:gs];
            NSUInteger si = [subs indexOfObjectIdenticalTo:sdlView];
            if (gi != NSNotFound && si != NSNotFound && gi > si) {
                [container insertSubview:gs belowSubview:sdlView];
                NSLog(@"[Amethyst] Task52: GameSurfaceView pinned BELOW SDL touch view "
                      @"(Air Task52: SDL view transparent, frame shows through)");
            }
        }

        return fixed;
    } @catch (NSException *e) {
        NSLog(@"[Amethyst] Task32/52 enforcement exception: %@", e);
        return NO;
    }
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event
{

    [super touchesBegan:touches withEvent:event];

    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send Type 1 (Add Pointer)
                [self.touchSender sendType:1 id:[self getFingerId:touch] x:x y:y];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send ProxyMessage: AddPointerMessage
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:x y:y isRemove:NO];
            }
        }

        if (isGrabbing == JNI_TRUE) return;
    }


    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) continue;
        CGPoint locationInView = [touch locationInView:self.rootView];
        CGFloat screenScale = [[UIScreen mainScreen] scale];
        currentHotbarSlot = self.enableHotbarGestures ?
            callback_SurfaceViewController_touchHotbar(locationInView.x * screenScale, locationInView.y * screenScale) : -1;
        if ([self isTouchInactive:self.hotbarTouch] && currentHotbarSlot != -1) {
            self.hotbarTouch = touch;
        }
        if ([self isTouchInactive:self.primaryTouch] && currentHotbarSlot == -1) {
            self.primaryTouch = touch;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
    }
    // NOTE: Touches are NOT forwarded to SDL_uikitview here.
    // Our input_bridge_v3.m handles all mouse injection via SDL_PushEvent.
    // Forwarding to SDL_uikitview would cause duplicate SDL_FINGER + mouse events
    // (SDL internally converts touch→mouse), resulting in hitbox mismatch.
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send Type 1 (Move Pointer)
                [self.touchSender sendType:1 id:[self getFingerId:touch] x:x y:y];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;

                CGPoint p = [touch locationInView:self.surfaceView];
                float x = p.x / self.surfaceView.frame.size.width;
                float y = p.y / self.surfaceView.frame.size.height;
                // Send ProxyMessage: AddPointerMessage (Move is also Add with new position)
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:x y:y isRemove:NO];
            }
        }

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesMoved:touches withEvent:event];

    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            if (!isGrabbing && !virtualMouseEnabled) {
                CGPoint point = [touch locationInView:self.rootView];
                [self sendTouchPoint:point withEvent:ACTION_MOVE];
            }
            continue;
        }
        if (self.hotbarTouch != touch && [self isTouchInactive:self.primaryTouch]) {
            self.primaryTouch = touch;
            [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_DOWN];
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_MOVE];
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                // Send Type 2 (Remove Pointer) for surfaceView touch ending
                [self.touchSender sendType:2 id:[self getFingerId:touch] x:0 y:0];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                // Send ProxyMessage: RemovePointerMessage
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:0 y:0 isRemove:YES];
            }
        }

        // Clear the touch to finger ID map for ended touches
        [self clearTouchToFingerIdMapForTouches:touches];

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesEnded:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event
{
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];

        if (mode == 1) {  // UDP æ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                [self.touchSender sendType:2 id:[self getFingerId:touch] x:0 y:0];
            }
        } else if (mode == 2) {  // éæåºæ¨¡å¼
            for (UITouch *touch in touches) {
                if (touch.view != self.surfaceView) continue;
                [self sendTouchControllerProxyMessage:[self getFingerId:touch] x:0 y:0 isRemove:YES];
            }
        }

        // Clear the touch to finger ID map for cancelled touches
        [self clearTouchToFingerIdMapForTouches:touches];

        if (isGrabbing == JNI_TRUE) return;
    }

    [super touchesCancelled:touches withEvent:event];
    [self touchesEndedGlobal:touches withEvent:event];
}

- (void)touchesEndedGlobal:(NSSet *)touches withEvent:(UIEvent *)event
{
    for (UITouch *touch in touches) {
        if (touch.type == UITouchTypeIndirectPointer) {
            continue;
        }
        [self sendTouchEvent:touch withUIEvent:event withEvent:ACTION_UP];
    }
}

+ (BOOL)isRunning {
    return [self currentInstance] != nil;
}

+ (instancetype)currentInstance {
    UIViewController *rootVC = UIWindow.mainWindow.rootViewController;
    // 情况1：rootViewController 就是 SurfaceViewController
    if ([rootVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)rootVC;
    }
    // 情况2：SurfaceViewController 以模态方式呈现
    UIViewController *presentedVC = rootVC.presentedViewController;
    if ([presentedVC isKindOfClass:[SurfaceViewController class]]) {
        return (SurfaceViewController *)presentedVC;
    }
    return nil;
}

+ (GameSurfaceView *)surface {
    return pojavWindow;
}

#pragma mark - FPS/内存监控（参照 FCL egl_bridge.c 与 ZL2 MemoryUtils.kt）

- (void)updateGameStats {
    // 1. 读取 native swap buffer 计数器并重置（参照 FCL CallbackBridge.getFps()）
    // pojavGetAndResetFps() 返回自上次调用以来的渲染帧数
    // 采样间隔 1 秒（statsTimer 已改为 1s），所以返回值即为 FPS
    NSInteger fps = (NSInteger)pojavGetAndResetFps();

    // 2. 获取内存占用（phys_footprint）
    // 使用 task_vm_info 的 phys_footprint 字段，这是 iOS 上最准确的进程内存占用指标
    // 包含常驻内存、压缩内存、GPU 内存（UMA 架构下），与 Xcode 内存表盘一致
    // 参照 ZL2 MemoryUtils.kt 的系统级内存统计理念，在 iOS 上用 phys_footprint 等价
    double memoryMB = [self currentPhysFootprintMB];

    // 3. 更新 UI（GameMenuOverlayView 内部会 dispatch 到主线程）
    if ([self.gameMenuOverlay isKindOfClass:[GameMenuOverlayView class]]) {
        [(GameMenuOverlayView *)self.gameMenuOverlay updateFPS:fps memoryUsageMB:memoryMB];
    }

    // 4. 黑屏取证心跳（Task 32）：每 5 秒一条 [RenderDiag] 日志。
    // 三元判据（配合 gl_bridge.m 的 ame_egl_swap_stats）：
    //   - swapFail 增长 → eglSwapBuffers 报错，呈现路径断（layer/surface 生命周期）
    //   - swapOK 增长但用户仍黑屏 → 帧成功换入了 layer 但没上屏（覆盖/层级/尺寸）
    //   - swapOK/swapFail 都不增长且 fps=0 → 渲染循环卡死（启动后期阻塞）
    // 同时带上 layer 现场（drawableSize/contentsScale/bounds/inWindow），
    // 一次日志即可同时判断"渲染活不活"与"呈现层状态对不对"。
    {
        static int s_diagTick = 0;
        if (++s_diagTick >= 5) {
            s_diagTick = 0;
            unsigned long swapOK = 0, swapFail = 0;
            ame_egl_swap_stats(&swapOK, &swapFail);
            // Task 76（帧节奏诊断）：swap 帧间隔窗口统计（读取即重置）。
            // maxGap=5 秒窗口内最坏帧间隔——"30fps 看得像 10fps"的直接度量
            //（vsync 锁 60 下丢拍阶梯 33/50/100/200ms 会把它顶高）；avgGap
            // 与 fps 互为倒数校验。MG/FSR1 修复前后对比的硬指标。
            unsigned int maxGap = 0, avgGap = 0;
            ame_egl_swap_framegap(&maxGap, &avgGap);
            // Task 77（帧相位归因）：render 线程帧循环分相计时（读取即重置）。
            // pres=avg/max：eglSwapBuffers 本体耗时（ANGLE Metal 提交/
            // nextDrawable 等待/GPU 追赶）；build=avg/max：上次 present 返回
            // 到本次 swap 入口（MC tick+事件泵+GL 编码 CPU 税）。
            // 判读：presAvg≈avgGap→停在呈现/GPU 侧（降分辨率/换渲染器才有效）；
            // buildAvg≈avgGap→停在 CPU 帧构造侧（转译栈逐 draw 优化才有效）。
            unsigned int presAvg = 0, presMax = 0, buildAvg = 0, buildMax = 0;
            ame_egl_swap_phase_stats(&presAvg, &presMax, &buildAvg, &buildMax);
            CALayer *l = self.surfaceView.layer;
            BOOL isMetal = [l isKindOfClass:CAMetalLayer.class];
            CGSize drawable = isMetal ? ((CAMetalLayer *)l).drawableSize : CGSizeZero;
            BOOL inWindow = (self.surfaceView.window != nil);
            NSLog(@"[RenderDiag] fps=%ld swapOK=%lu swapFail=%lu maxGap=%ums avgGap=%ums pres=%u/%ums build=%u/%ums mem=%.0fMB layer=%p drawable=%.0fx%.0f scale=%.2f bounds=%.0fx%.0f inWindow=%d",
                  (long)fps, swapOK, swapFail, maxGap, avgGap,
                  presAvg, presMax, buildAvg, buildMax, memoryMB, (__bridge void *)l,
                  drawable.width, drawable.height, (double)l.contentsScale,
                  l.bounds.size.width, l.bounds.size.height, (int)inWindow);
        }
    }
}

- (double)currentPhysFootprintMB {
    // 使用 TASK_VM_INFO flavor 读取 phys_footprint
    // phys_footprint 是 Apple 推荐的进程内存占用指标，包含：
    // - 常驻物理内存（resident_size）
    // - 压缩内存
    // - GPU 内存（iOS UMA 架构下 Metal 缓冲区映射到进程地址空间）
    // 减去通过 mmap 共享的部分，与 Xcode/Memory Graph 显示的值一致
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO,
                                 (task_info_t)&vmInfo, &count);
    if (kr != KERN_SUCCESS) {
        return 0.0;
    }
    // phys_footprint 单位是字节
    return (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
}

- (void)dealloc {
    // 停止 FPS/内存采样定时器与渲染循环
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [self.statsDisplayLink invalidate];
    self.statsDisplayLink = nil;
    self.statsDisplayLinkTarget = nil;  // 释放 CADisplayLink target

    // 清理启动遮罩层资源
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"PojavFirstFrameRendered" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AME172_SDLStartTextInput" object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"AME172_SDLStopTextInput" object:nil];
    self.launchOverlayView = nil;
    self.launchGradientLayer = nil;

    // 关键修复（UI 累积异常）：移除 5 个块式通知观察者。
    // 之前只移除了 PojavFirstFrameRendered，未移除以下 5 个块观察者，
    // 导致每次进出游戏都泄漏 5 个观察者 + 5 条对 self 的强引用，
    // 多次进出后多个"已释放"的 VC 同时收到通知操作 UI，造成 UI 行为错乱。
    // 块观察者必须通过 removeObserver: 显式移除（removeObserver:self 无效）。
    id defaultCenter = [NSNotificationCenter defaultCenter];
    if (self.mousePointerUpdatedCallback) {
        [defaultCenter removeObserver:self.mousePointerUpdatedCallback];
        self.mousePointerUpdatedCallback = nil;
    }
    if (self.mouseConnectCallback) {
        [defaultCenter removeObserver:self.mouseConnectCallback];
        self.mouseConnectCallback = nil;
    }
    if (self.mouseDisconnectCallback) {
        [defaultCenter removeObserver:self.mouseDisconnectCallback];
        self.mouseDisconnectCallback = nil;
    }
    if (self.controllerConnectCallback) {
        [defaultCenter removeObserver:self.controllerConnectCallback];
        self.controllerConnectCallback = nil;
    }
    if (self.controllerDisconnectCallback) {
        [defaultCenter removeObserver:self.controllerDisconnectCallback];
        self.controllerDisconnectCallback = nil;
    }

    // LAN 端口检测器已改为手动输入模式，stopDetecting 已移除，无需调用。
    // ZeroTier/Terracotta 联机暂时移除：原 stopAllMultiplayerServices 调用注释掉
    // [[MultiplayerManager sharedManager] stopAllMultiplayerServices];

    //æ¸ç TouchController èµæº
    if (self.touchControllerTransportHandle >= 0) {
        [TouchControllerBridge destroyTransport:self.touchControllerTransportHandle];
        self.touchControllerTransportHandle = -1;
    }
}

@end
