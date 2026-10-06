/*
 * V3 input bridge implementation.
 *
 * Status:
 * - Active development
 * - Works with some bugs:
 *  + Modded versions gives broken stuff..
 */

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "SurfaceViewController.h"
#import "FileListViewController.h"  // Task222：openURLGlobal 目录分支走应用内文件浏览器
#import "FolderBrowserViewController.h"  // Task223：真正的全功能文件夹浏览器（FileList 只列 .json）

#include <assert.h>
#include <dlfcn.h>
#include <libgen.h>
#include <limits.h>
#include <math.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <string.h>
#include <stdio.h>

#include "jni.h"
#include "glfw_keycodes.h"
#include "ios_uikit_bridge.h"
#include "utils.h"

#include "JavaLauncher.h"

// Task66：抓取切换沿复位摇杆方向去重状态（实现于 customcontrols/ControlJoystick.m）
extern void AmeControlJoystickOnGrabChange(BOOL grabbed);

// SDL3 event injection via dlsym — used when GLFW callbacks are NULL (MC 26.3)
// SDL_PushEvent / SDL_GetWindowID / SDL_GetKeyboardState / SDL_SetModState are
// exported from libSDL3.dylib (Task66 symbol-table verified). Internal functions
// like SDL_SendKeyboardKey are NOT exported (LOCAL symbol), so we construct
// SDL_Event structs and push them directly, then sync SDL's internal keyboard
// state array manually (ame66_syncKeyboardState).
//
// We cannot #include <SDL3/SDL_events.h> from the Natives build, so we define
// the minimal constants and structs we need inline.

// SDL3 event type constants (from SDL_events.h)
#define SDL3_EVENT_KEY_DOWN        0x300
#define SDL3_EVENT_KEY_UP          0x301
#define SDL3_EVENT_MOUSE_MOTION    0x400
#define SDL3_EVENT_MOUSE_BUTTON_DOWN 0x401
#define SDL3_EVENT_MOUSE_BUTTON_UP   0x402
#define SDL3_EVENT_MOUSE_WHEEL     0x403
// Task 82：SDL_EVENT_TEXT_INPUT（0x303=771）。MC 26.3 的
// SDLEventHandler.pollEvents 里 case 771 → handleTextInputEvent →
// keyboardHandler.textInput → charTyped，虚拟键盘字符的唯一入口。
#define SDL3_EVENT_TEXT_INPUT      0x303
// Task 83b：SDL_EVENT_WINDOW_RESIZED（0x207）。MC 26.3 的窗口尺寸消费
// 通道——Task61 已实证它直接把 data1/data2 当像素尺寸用（当年 uikit 发的
// 点制 1180x820 被 MC 按像素消费导致分辨率减半，正是利用此语义改写）。
// nativeSendScreenSize 的 SDL3 路径用它把窗口信念下发给 MC。
#define SDL3_EVENT_WINDOW_RESIZED  0x207
// Task224：后台恢复链重建 SDL/MC 焦点态的标准事件对（resumeGameIfNeed）。
#define SDL3_EVENT_WINDOW_MOUSE_ENTER  0x20C
#define SDL3_EVENT_WINDOW_FOCUS_GAINED 0x20E

typedef uint32_t SDL3_WindowID;
typedef uint32_t SDL3_MouseID;
typedef uint16_t SDL3_Keymod;
typedef int      SDL3_Scancode;
typedef uint32_t SDL3_Keycode;

// SDL3 MouseMotionEvent layout (must match SDL3 ABI exactly)
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    uint32_t state;
    float x, y;
    float xrel, yrel;
} SDL3_MouseMotionEvent;

// SDL3 MouseButtonEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    uint8_t button;
    bool down;
    uint8_t clicks;
    uint8_t padding;
    float x, y;
} SDL3_MouseButtonEvent;

// SDL3 MouseWheelEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    SDL3_MouseID which;
    float x, y;
    uint32_t direction;
    float mouse_x, mouse_y;
    int32_t integer_x, integer_y;
} SDL3_MouseWheelEvent;

// SDL3 KeyboardEvent layout
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    uint32_t which;
    SDL3_Scancode scancode;
    SDL3_Keycode key;
    SDL3_Keymod mod;
    uint16_t raw;
    bool down;
    bool repeat;
} SDL3_KeyboardEvent;

// Task 82：SDL3 TextInputEvent layout（与 SDL3 ABI 对齐：
// type@0 reserved@4 timestamp@8 windowID@16 pad@20 text@24，sizeof=32）。
// text 是指针而非内联数组（SDL3 改动），指向的 UTF-8 字符串必须在
// MC 轮询该事件时仍然存活——用下方的静态环形槽位保证。
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    const char *text;
} SDL3_TextInputEvent;

// Task 83b：SDL3 WindowEvent layout（与 Task61 在 sdl3_hook.m 里的布局
// 注释互证：type@0 reserved@4 timestamp@8 windowID@16 data1@20 data2@24）。
// sizeof=28，padded 到 32。
typedef struct {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    SDL3_WindowID windowID;
    int32_t data1;
    int32_t data2;
} SDL3_WindowEvent;

// Union large enough to hold any SDL3 event
typedef union {
    uint32_t type;
    char _padding[128];
} SDL3_Event;

typedef bool SDL_PushEvent_func(void *event);
typedef uint32_t SDL_GetWindowID_func(void *window);
typedef bool SDL_HideCursor_func(void);
typedef bool SDL_ShowCursor_func(void);
// Task 66：SDL 内部键盘状态同步（导出符号已在 libSDL3.dylib 符号表实锤：
// SDL_GetKeyboardState @0x2a56c / SDL_SetModState @0x2a584，N_EXT|N_SECT）。
// SDL_SendKeyboardKey 是 LOCAL 符号不可 dlsym，官方管线不可用，改手动同步。
typedef const bool *SDL_GetKeyboardState_func(int *numkeys);
typedef unsigned short SDL_GetModState_func(void);
typedef void SDL_SetModState_func(unsigned short modstate);

static SDL_PushEvent_func     *pSDL_PushEvent     = NULL;
static SDL_GetWindowID_func   *pSDL_GetWindowID   = NULL;
static SDL_GetKeyboardState_func *pSDL_GetKeyboardState = NULL;  // Task66
static SDL_GetModState_func   *pSDL_GetModState   = NULL;        // Task66
static SDL_SetModState_func   *pSDL_SetModState   = NULL;        // Task66
static bool *ame66_kbState = NULL;   // Task66：SDL 内部键盘状态数组（SDL_GetKeyboardState 返回值，直接写入）
static int    ame66_kbNumKeys = 0;   // Task66：数组长度（SDL3 = 512 = SDL_NUM_SCANCODES）
static unsigned short ame66_virtualMods = 0;  // Task66：虚拟修饰键掩码（我们注入的 shift/ctrl/alt/gui）
static void *g_sdlWindow = NULL;  // The real SDL3 window pointer
static void ame104_armAfkHeartbeat(void);  // Task104：AFK 心跳（前向声明，实现见 pushSDLMouseWheel 之后）
// Task224：SDL 嵌入视图 z 序重钉的公开包装（sdl3_hook.m，自带主线程调度）
extern void ame224_refrontEmbeddedViewSafe(void);

static void initSDLEventFuncs(void) {
    static BOOL inited = NO;
    if (inited) return;
    inited = YES;
    pSDL_PushEvent   = dlsym(RTLD_DEFAULT, "SDL_PushEvent");
    pSDL_GetWindowID = dlsym(RTLD_DEFAULT, "SDL_GetWindowID");
    pSDL_GetKeyboardState = dlsym(RTLD_DEFAULT, "SDL_GetKeyboardState");  // Task66
    pSDL_GetModState = dlsym(RTLD_DEFAULT, "SDL_GetModState");            // Task66
    pSDL_SetModState = dlsym(RTLD_DEFAULT, "SDL_SetModState");            // Task66
    NSLog(@"[InputDiag] initSDLEventFuncs: PushEvent=%p GetWindowID=%p g_sdlWindow=%p Task66GetKBState=%p SetModState=%p",
        (void*)pSDL_PushEvent, (void*)pSDL_GetWindowID, g_sdlWindow,
        (void*)pSDL_GetKeyboardState, (void*)pSDL_SetModState);
}

// Called from UIKit_CreateWindow to register the real SDL window
void Amethyst_SetSDLWindow(void *window) {
    g_sdlWindow = window;
    // Re-init in case libSDL3.dylib wasn't loaded at JNI_OnLoad time
    initSDLEventFuncs();
    // Task 104：窗口就绪即布防 AFK 心跳（26.3 的 30fps 短 AFK 限帧根治）
    ame104_armAfkHeartbeat();
    NSLog(@"[InputDiag] Amethyst_SetSDLWindow: %p PushEvent=%p", window, (void*)pSDL_PushEvent);
}

static SDL3_WindowID getSDLWindowID(void) {
    if (g_sdlWindow && pSDL_GetWindowID) {
        return pSDL_GetWindowID(g_sdlWindow);
    }
    return 0;
}

// Task 59：触控坐标“像素”直通（Task51 的 ÷2 换算移除）。
//
// Task51 Fix G 引入 ÷2（UIScreen.scale=2）时基于两个假设：
//   a. SDL 窗口点空间（1180x820）是 MC 鼠标事件的正确坐标系；
//   b. 超出 SDL 窗口宽度的坐标会被 MC 丢弃（"x=1551 → 无反应"）。
// f335789 真机日志（376192f 构建）推翻了这两个假设：
//   1. 启动器把 windowWidth/windowHeight=2360x1640（物理像素口径）经
//      launchJVM 喂给 MC（"[SurfaceViewController] Launching Minecraft
//      ... size: 2360x1640"），MC 26.3 据此创建 SDL 窗口（"[SDLHook]
//      SDL_CreateWindow ... 2360x1640"）——MC Window 对象/输入归一化基准
//      是启动器告知的 2360x1640，而不是 Task51 钳制后的实际 SDL 窗口
//      1180x820 点。渲染尺寸由 renderpearl 适配真实 EGL 表面（1180x820，
//      Task58 后画面 1:1 正常），与输入归一化解耦。
//   2. TouchController mod（运行在 MC 内）的参考分辨率同为 2360x1640
//      （sendCursorPos x 最大 1802 > 1180，整数坐标实锤）。
//   3. Task58 后画面正常但输入仍错位：若 MC 按 1180 归一化，÷2 后的坐标
//      恰好对齐——仍错位 ⟹ MC 不按 1180 归一化。Task51 的"超界丢弃"推断
//      出自黑屏时代的"全无反应"，当时画面本身就没渲染，无取证价值。
// 结论：SDL 鼠标事件必须携带 2360x1640 像素口径的原始坐标（与 MC 窗口
// 信念一致）。÷2 把每个输入位置压到真实位置的一半处 = "输入错位"。
// 本函数保留为恒等直通（pushSDLMouse* 调用点零改动），一次性指纹确认
// 新构建在跑。
static float ame51_px_to_pt(float v) {
    static BOOL ame59_logged = NO;
    if (!ame59_logged) {
        ame59_logged = YES;
        NSLog(@"[InputDiag] Task59 raw px pass-through: SDL mouse coords stay in launcher-px space (= MC window belief, launcher-told 2360x1640); Task51 /2 removed -- it halved every input position");
    }
    return v;
}

// Push a mouse motion event into SDL's event queue
static void pushSDLMouseMotion(float x, float y, float xrel, float yrel) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseMotionEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SDL3_EVENT_MOUSE_MOTION;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.state = 0;
    ev.x = ame51_px_to_pt(x);          // Task51: 触控像素 -> SDL 窗口点
    ev.y = ame51_px_to_pt(y);
    ev.xrel = ame51_px_to_pt(xrel);    // 增量同口径换算
    ev.yrel = ame51_px_to_pt(yrel);
    pSDL_PushEvent((void*)&ev);
}

// Push a mouse button event into SDL's event queue
// sdlButton: 1=left, 2=middle, 3=right (SDL convention)
static void pushSDLMouseButton(uint8_t sdlButton, bool down, float x, float y) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseButtonEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL3_EVENT_MOUSE_BUTTON_DOWN : SDL3_EVENT_MOUSE_BUTTON_UP;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.button = sdlButton;
    ev.down = down;
    ev.clicks = 1;
    ev.x = ame51_px_to_pt(x);          // Task51: 触控像素 -> SDL 窗口点
    ev.y = ame51_px_to_pt(y);
    pSDL_PushEvent((void*)&ev);
}

// Task 53（输入修复）：SDL3 键事件的 key 字段（SDL_Keycode）。MC/RenderPearl
// 部分路径读 ev.key 而非 scancode；此前恒 0，空格/ESC/回车等在游戏内可能
// 无响应。纯函数计算（不 dlsym SDL_GetKeyFromScancode——规避跨版本 ABI
// 差异）：字母=小写 ASCII、数字=ASCII、常用控制键=SDL 控制字符码，其余
// = scancode | SDLK_SCANCODE_MASK(0x40000000)。
static uint32_t ame53_keycode_from_scancode(SDL3_Scancode sc) {
    if (sc >= 4 && sc <= 29)  return (uint32_t)('a' + (sc - 4));   // A-Z -> SDLK_a..z
    if (sc >= 30 && sc <= 38) return (uint32_t)('1' + (sc - 30));  // 1-9 -> SDLK_1..9
    if (sc == 39)             return (uint32_t)'0';                // SDLK_0
    switch (sc) {
        case 40: return 0x0D;   // SDLK_RETURN
        case 41: return 0x1B;   // SDLK_ESCAPE
        case 42: return 0x08;   // SDLK_BACKSPACE
        case 43: return 0x09;   // SDLK_TAB
        case 44: return 0x20;   // SDLK_SPACE
        case 45: return 0x2D;   // SDLK_MINUS '-'
        case 46: return 0x3D;   // SDLK_EQUAL '='
        case 47: return 0x5B;   // SDLK_LEFTBRACKET '['
        case 48: return 0x5D;   // SDLK_RIGHTBRACKET ']'
        case 49: return 0x5C;   // SDLK_BACKSLASH '\\'
        case 51: return 0x3B;   // SDLK_SEMICOLON ';'
        case 52: return 0x27;   // SDLK_APOSTROPHE '\''
        case 53: return 0x60;   // SDLK_GRAVE '`'
        case 54: return 0x2C;   // SDLK_COMMA ','
        case 55: return 0x2E;   // SDLK_PERIOD '.'
        case 56: return 0x2F;   // SDLK_SLASH '/'
        default:  return ((uint32_t)sc) | 0x40000000u;  // 功能键/小键盘等
    }
}

// ============================================================================
// Task 66（虚拟键状态同步）：SDL 内部键盘状态与注入事件解耦的根因修复
//
// 现象链（用户实测："很奇怪要按下 shift 才能移动" + 摇杆需反复晃动才动）：
//   Path B 用 SDL_PushEvent 注入虚拟键事件，事件能被 MC 消费（Task64/65
//   日志已证 1:1 送达），但 SDL_PushEvent 只入队——SDL_GetKeyboardState()
//   返回的内部状态数组与 SDL_GetModState() 的修饰键态由 SDL 自家管线
//   （SDL_SendKeyboardKey，LOCAL 符号不可 dlsym）维护，对注入事件零感知。
//
//   MC 26.3（反编译实锤）有四类消费点轮询"真实"键盘态而非事件流：
//   1. MouseHandler.grabMouse() → KeyMapping.setAll()
//      （InputQuirks.RESTORE_KEY_STATE_AFTER_MOUSE_GRAB = !OSX = iOS 恒真）
//      把所有键盘键位 isDown 强制覆盖为 SDL_GetKeyboardState 轮询值。
//      虚拟键不可见 → 每次进出菜单/进世界，摇杆按住的 W/A/S/D 全被清成
//      false；而 ControlJoystick.callbackMoveX 有 lastDirection 去重，
//      同方向不再重发 → 玩家"卡住"直到换方向——与日志实测（90 秒内
//      450+ sendKey ≈ 112 次换向 = 用户反复晃动摇杆挣扎）完全吻合。
//   2. Minecraft.hasShiftDown()/hasControlDown()/hasAltDown()
//      轮询 scancode 225/229/224/228 → 虚拟 Shift/Ctrl 永远不可见。
//   3. SDLEventHandler.handleMouseButtonEvent 把 SDL_GetModState() 塞进
//      MouseButtonInfo → 修饰键语义（shift 点击等）丢失。
//   4. InputQuirks.isQuitShortcutDown / isShiftInvertedScroll 同源受害。
//
// 修复：pushSDLKeyboardEvent 推完事件后，把该键写入 SDL_GetKeyboardState
// 返回的内部数组（SDL 拥有的 .bss 内存，单写者竞争仅剩蓝牙真键盘，同键
// 同时一虚一真属罕见且自愈）；修饰键事件额外维护虚拟掩码，经 SDL_SetModState
// 合并进 SDL 修饰键态（保留非托管位，不清真键盘的修饰键）。
// ============================================================================

// SDL3 Keymod 位（SDL_Keymod，与 SDL2 同值）
#define AME66_KMOD_LSHIFT 0x0001
#define AME66_KMOD_RSHIFT 0x0002
#define AME66_KMOD_LCTRL  0x0040
#define AME66_KMOD_RCTRL  0x0080
#define AME66_KMOD_LALT   0x0100
#define AME66_KMOD_RALT   0x0200
#define AME66_KMOD_LGUI   0x0400
#define AME66_KMOD_RGUI   0x0800
#define AME66_KMOD_MANAGED_MASK (0x0003u | 0x00C0u | 0x0300u | 0x0C00u)

static void ame66_syncKeyboardState(int sc, bool down) {
    // 惰性获取 SDL 内部键盘状态数组
    if (ame66_kbState == NULL && pSDL_GetKeyboardState != NULL) {
        int n = 0;
        ame66_kbState = (bool *)pSDL_GetKeyboardState(&n);
        ame66_kbNumKeys = n;
        NSLog(@"[InputDiag] Task66 kb-state sync ready: array=%p numkeys=%d (SDL_GetKeyboardState passthrough)",
              (void *)ame66_kbState, ame66_kbNumKeys);
    }
    if (ame66_kbState != NULL && sc > 0 && sc < ame66_kbNumKeys) {
        ame66_kbState[sc] = down;
    }

    // 修饰键掩码：合并进 SDL 修饰键态（保留非托管位，不清真键盘修饰键）
    unsigned short bit = 0;
    switch (sc) {
        case 225: bit = AME66_KMOD_LSHIFT; break;   // SDL_SCANCODE_LEFT_SHIFT
        case 229: bit = AME66_KMOD_RSHIFT; break;   // SDL_SCANCODE_RIGHT_SHIFT
        case 224: bit = AME66_KMOD_LCTRL;  break;   // SDL_SCANCODE_LEFT_CONTROL
        case 228: bit = AME66_KMOD_RCTRL;  break;   // SDL_SCANCODE_RIGHT_CONTROL
        case 226: bit = AME66_KMOD_LALT;   break;   // SDL_SCANCODE_LEFT_ALT
        case 230: bit = AME66_KMOD_RALT;   break;   // SDL_SCANCODE_RIGHT_ALT
        case 227: bit = AME66_KMOD_LGUI;   break;   // SDL_SCANCODE_LEFT_GUI
        case 231: bit = AME66_KMOD_RGUI;   break;   // SDL_SCANCODE_RIGHT_GUI
    }
    if (bit) {
        if (down) {
            ame66_virtualMods |= bit;
        } else {
            ame66_virtualMods &= (unsigned short)~bit;
        }
        if (pSDL_SetModState && pSDL_GetModState) {
            unsigned short real = pSDL_GetModState();
            unsigned short merged = (unsigned short)((real & ~AME66_KMOD_MANAGED_MASK) | ame66_virtualMods);
            pSDL_SetModState(merged);
            NSLog(@"[InputDiag] Task66 modstate sync: sc=%d down=%d virt=0x%x real=0x%x merged=0x%x",
                  sc, down ? 1 : 0, ame66_virtualMods, real, merged);
        }
    }
}

// Push a keyboard event into SDL's event queue
static void pushSDLKeyboardEvent(SDL3_Scancode scancode, bool down) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_KeyboardEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = down ? SDL3_EVENT_KEY_DOWN : SDL3_EVENT_KEY_UP;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.scancode = scancode;
    ev.key = ame53_keycode_from_scancode(scancode);   // Task53: 补 key sym
    ev.mod = 0;
    ev.down = down;
    ev.repeat = false;
    pSDL_PushEvent((void*)&ev);
    ame66_syncKeyboardState((int)scancode, down);   // Task66：同步 SDL 内部键盘态
}

// ============================================================================
// Task 82：虚拟键盘文本输入（MC 26.3 / SDL3 路径）
//
// 根因：CallbackBridge_nativeSendChar 只有 GLFW 路径（GLFW_invoke_Char），
// 而 26.3 走 SDL3，GLFW_invoke_Char 恒为 NULL → 左上角 Keyboard 控件按钮
// 唤起的虚拟键盘打字全部被静默丢弃。修法：照 sendKey 的 Path B 模式，
// 把字符编成 UTF-8 后直接推 SDL_EVENT_TEXT_INPUT 事件，MC 26.3 的
// SDLEventHandler 会把它送进 keyboardHandler.textInput → charTyped
// （聊天框/搜索框等 Screen 打开时生效）。
// ============================================================================

// 每个 codepoint 的 UTF-8 最长 4 字节 + NUL = 5，取 8 对齐。
// 1024 个槽位：MC 每帧 pollEvents 排空队列，上千字符的积压只可能发生在
// 帧循环冻结时——那本身已是更大的故障。槽位复用只会覆盖早已被消费的事件。
#define AME82_TEXT_RING_SLOTS 1024
static char ame82_textRing[AME82_TEXT_RING_SLOTS][8];
static uint32_t ame82_textRingIdx = 0;
// UTF-16 代理对合并状态：TrackedTextField.sendText 按 UTF-16 码元逐个发送，
// emoji 等增补平面字符会拆成 high/low 两个码元，先记 high 再与 low 合并。
static uint32_t ame82_pendingHighSurrogate = 0;

static int ame82_utf8_encode(uint32_t cp, char out[8]) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

// Push a text input event into SDL's event queue (one UTF-16 code unit,
// surrogate halves are merged into a single codepoint)
static void pushSDLTextInput(jchar codepoint) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;

    uint32_t cp;
    if (codepoint >= 0xD800 && codepoint <= 0xDBFF) {
        // 高代理：等配对的低代理一起合成码点，暂不发事件
        ame82_pendingHighSurrogate = (uint32_t)codepoint;
        return;
    }
    if (codepoint >= 0xDC00 && codepoint <= 0xDFFF) {
        if (ame82_pendingHighSurrogate != 0) {
            cp = 0x10000 + ((ame82_pendingHighSurrogate - 0xD800) << 10) + ((uint32_t)codepoint - 0xDC00);
        } else {
            cp = 0xFFFD;   // 孤立低代理：替换字符，不向游戏注入乱码
        }
        ame82_pendingHighSurrogate = 0;
    } else {
        // 普通码元：若之前挂着一个未配对的高代理，就地丢弃（保持 UTF-16 语义）
        ame82_pendingHighSurrogate = 0;
        cp = (uint32_t)codepoint;
    }

    char *slot = ame82_textRing[ame82_textRingIdx];
    ame82_textRingIdx = (ame82_textRingIdx + 1) % AME82_TEXT_RING_SLOTS;
    const int len = ame82_utf8_encode(cp, slot);
    slot[len] = '\0';

    // 用 128 字节的 SDL3_Event 联合体承载，避免 SDL_PushEvent 拷贝整个
    // union 时读到栈上未初始化的尾部（32 字节的 TextInputEvent 单独声明
    // 会被越界读）。
    SDL3_Event ev;
    memset(&ev, 0, sizeof(ev));
    SDL3_TextInputEvent *te = (SDL3_TextInputEvent *)&ev;
    te->type = SDL3_EVENT_TEXT_INPUT;
    te->windowID = getSDLWindowID();
    te->text = slot;
    pSDL_PushEvent((void *)&ev);

    static int s_task82_textPushed = 0;
    s_task82_textPushed++;
    if (s_task82_textPushed <= 10 || s_task82_textPushed % 100 == 0) {
        NSLog(@"[InputDiag] Task82 SDL text input #%d: U+%04X -> \"%s\" (virtual keyboard chars now reach MC 26.3)",
              s_task82_textPushed, cp, slot);
    }
}

// ============================================================================
// Task 83：控件按钮键盘（custom 布局的 QWERTY 抽屉面板）打字支持
//
// 根因：SurfaceViewController executebtn 的 keycode>0 分支只发 GLFW key 事件
// （nativeSendKey → SDL3 key down/up 或 GLFW key 回调），而 MC 1.13+ 的
// 聊天框/书与笔/搜索框只消费 charTyped（GLFW char 回调 / SDL3
// SDL_EVENT_TEXT_INPUT）事件——纯 key 事件一律不进文本。所以"键盘图标"
// 抽屉里的字母/数字/符号按钮在聊天框里完全没有反应；而系统软键盘正常
// （inputTextField → nativeSendChar 链路，Task82 已修好 SDL3 分支）。
//
// 修法：executebtn 在按键按下（ACTION_DOWN）时对本键补发一个字符事件。
// - 映射按 US ANSI 布局（与 GLFW/CPredefinedProcGetKey 惯例一致）；
// - SHIFT 状态：SDL3 路径读 SDL_GetModState（Task66 已把虚拟 SHIFT/CTRL/
//   ALT/GUI 同步进去），GLFW 路径读 nativeSendKey 维护的 currMods；
// - Ctrl/Alt/Super 按住时抑制字符（与真实键盘一致：Ctrl+W 是快捷键不产文本，
//   也避免"持续奔跑"[CTRL,W] 组合键往聊天框里灌字符）；
// - CAPS_LOCK 按钮自管理虚拟大写状态（SDL 不为注入事件维护 KMOD_CAPS）；
// - 硬件键盘不受影响：pressesBegan → KeyboardInput.sendKeyEvent 同时发
//   key+char，不经过 executebtn，无重复字符风险。
// ============================================================================

static bool ame83_virtualCaps = false;

// GLFW 键码 → US ANSI 布局字符；不可打印键返回 0。
// shift/caps 仅对字母异或生效（真实键盘语义），数字/符号只看 shift。
static jchar ame83_keycodeToChar(int key, bool shift, bool caps) {
    if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) {
        bool upper = shift != caps;
        return (jchar)((key - GLFW_KEY_A) + (upper ? 'A' : 'a'));
    }
    if (key >= GLFW_KEY_0 && key <= GLFW_KEY_9) {
        if (!shift) return (jchar)('0' + (key - GLFW_KEY_0));
        static const jchar shifted[10] = {')','!','@','#','$','%','^','&','*','('};
        return shifted[key - GLFW_KEY_0];
    }
    if (key >= GLFW_KEY_NUMPAD_0 && key <= GLFW_KEY_NUMPAD_9) {
        return (jchar)('0' + (key - GLFW_KEY_NUMPAD_0));   // 小键盘不受 shift 影响
    }
    if (!shift) {
        switch (key) {
            case GLFW_KEY_SPACE:            return ' ';
            case GLFW_KEY_APOSTROPHE:       return '\'';
            case GLFW_KEY_COMMA:            return ',';
            case GLFW_KEY_MINUS:            return '-';
            case GLFW_KEY_PERIOD:           return '.';
            case GLFW_KEY_SLASH:            return '/';
            case GLFW_KEY_SEMICOLON:        return ';';
            case GLFW_KEY_EQUAL:            return '=';
            case GLFW_KEY_LEFT_BRACKET:     return '[';
            case GLFW_KEY_BACKSLASH:        return '\\';
            case GLFW_KEY_RIGHT_BRACKET:    return ']';
            case GLFW_KEY_GRAVE_ACCENT:     return '`';
            case GLFW_KEY_NUMPAD_DECIMAL:   return '.';
            case GLFW_KEY_NUMPAD_DIVIDE:    return '/';
            case GLFW_KEY_NUMPAD_MULTIPLY:  return '*';
            case GLFW_KEY_NUMPAD_SUBTRACT:  return '-';
            case GLFW_KEY_NUMPAD_ADD:       return '+';
            case GLFW_KEY_NUMPAD_EQUAL:     return '=';
        }
    } else {
        switch (key) {
            case GLFW_KEY_SPACE:            return ' ';
            // 34 = ASCII 双引号字符。不写成字面量形式：历史校验脚本
            // （verify_task66/67/82 的括号计数器）先剥字符串再剥字符字面量，
            // 字面量里的双引号会被误当字符串起点，翻转全文件引号配对。
            case GLFW_KEY_APOSTROPHE:       return 34;
            case GLFW_KEY_COMMA:            return '<';
            case GLFW_KEY_MINUS:            return '_';
            case GLFW_KEY_PERIOD:           return '>';
            case GLFW_KEY_SLASH:            return '?';
            case GLFW_KEY_SEMICOLON:        return ':';
            case GLFW_KEY_EQUAL:            return '+';
            case GLFW_KEY_LEFT_BRACKET:     return '{';
            case GLFW_KEY_BACKSLASH:        return '|';
            case GLFW_KEY_RIGHT_BRACKET:    return '}';
            case GLFW_KEY_GRAVE_ACCENT:     return '~';
        }
    }
    return 0;
}

// executebtn 专用：按键按下时补发字符事件（Task83）。
// 返回 YES 表示发出了字符。仅由按钮路径调用，硬件键盘不走这里。
char getKeyModifiers(int key, int action);   // 定义于本文件 nativeSendKey 段

BOOL CallbackBridge_buttonKeySynthesizeText(int key) {
    if (key == GLFW_KEY_CAPS_LOCK) {
        ame83_virtualCaps = !ame83_virtualCaps;
        NSLog(@"[InputDiag] Task83 virtual caps-lock -> %d (button keyboard)", ame83_virtualCaps ? 1 : 0);
        return NO;
    }

    bool shift, ctrlLike;
    if (!GLFW_invoke_Char && g_sdlWindow && pSDL_GetModState != NULL) {
        // SDL3 路径（MC 26.3+）：修饰键态由 Task66 从虚拟按钮同步进 SDL
        unsigned short m = pSDL_GetModState();
        shift = (m & 0x0003) != 0;                       // KMOD_LSHIFT|KMOD_RSHIFT
        ctrlLike = (m & (0x00C0 | 0x0300 | 0x0C00)) != 0; // Ctrl|Alt|GUI
    } else {
        // GLFW 路径（旧版 MC）：nativeSendKey 维护的 currMods（key=0 纯查询）
        char m = getKeyModifiers(0, 0);
        shift = (m & GLFW_MOD_SHIFT) != 0;
        ctrlLike = (m & (GLFW_MOD_CONTROL | GLFW_MOD_ALT | GLFW_MOD_SUPER)) != 0;
    }

    if (ctrlLike) return NO;   // Ctrl/Alt/Super 组合 = 快捷键语义，不产文本

    jchar ch = ame83_keycodeToChar(key, shift, ame83_virtualCaps);
    if (ch == 0) return NO;

    CallbackBridge_nativeSendChar(ch);
    static int s_task83_chars = 0;
    s_task83_chars++;
    if (s_task83_chars <= 10 || s_task83_chars % 100 == 0) {
        NSLog(@"[InputDiag] Task83 button text #%d: glfwKey=%d -> '%C' (button keyboard types in chat now)",
              s_task83_chars, key, ch);
    }
    return YES;
}

// Push a mouse wheel event into SDL's event queue
static void pushSDLMouseWheel(float x, float y) {
    if (!pSDL_PushEvent || !g_sdlWindow) return;
    SDL3_MouseWheelEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = SDL3_EVENT_MOUSE_WHEEL;
    ev.windowID = getSDLWindowID();
    ev.which = 0;
    ev.x = x;
    ev.y = y;
    ev.direction = 0;
    ev.mouse_x = ame51_px_to_pt((float)cursorX);   // Task51: px -> pt
    ev.mouse_y = ame51_px_to_pt((float)cursorY);
    ev.integer_x = (int32_t)x;
    ev.integer_y = (int32_t)y;
    pSDL_PushEvent((void*)&ev);
}

// ============================================================================
// Task 104（26.3 FSR 30fps 根治）：AFK 心跳——每 45s 推一个 (0,0) SDL 滚轮。
//
// 根因链（341c110 装机日志 + piston-data 26.3 client.jar CFR 反编译实证）：
//   * MC 26.3 的 FramerateLimitTracker.getThrottleReason()：当
//     inactivityFpsLimit == AFK（该版本默认值，InactivityFpsLimit 枚举仅
//     minimized/afk 两值）且 Util.getMillis() - latestInputTime > 60000ms
//     时返回 SHORT_AFK → getFramerateLimit() = min(maxFps, 30) = 30；
//   * Minecraft.runTick 尾部 framerateLimit < 260 时调
//     FramerateLimiter.limitDisplayFPS(framerateLimit)（LockSupport.parkNanos
//     睡到 33ms/帧）——watchdog 采样实锤渲染线程 park 在该帧；
//   * 26.3 整合包（128 mods）加载 1-3 分钟无触摸 → latestInputTime 过期
//     → 整个加载期 + 无操作期被压在 30fps（用户所见“FSR 卡 30fps”）。
//     输入重置点仅在 MouseHandler.onButton/onScroll/onDrop/
//     handleAccumulatedMovement（后者还要求 isWindowActive）。
//
// 修复策略（双保险）：
//   1. 启动器仍写 inactivityFpsLimit=minimized（PojavLauncher，本轮加
//      落盘校验日志）；
//   2. 本心跳：游戏窗口就绪后每 45s 推一个 (0,0) SDL_MOUSEWHEEL ——
//     MouseHandler.onScroll 在句柄检查后第一行就是 onInputReceived()，
//     SHORT_AFK/LONG_AFK 的 60s/600s 阈值在游戏运行期间永不达成。
//
// (0,0) 滚轮的零副作用论证（26.3 反编译）：
//   * 加载期 overlay != null → onScroll 整个处理体被跳过（仅剩
//     onInputReceived）；
//   * 游戏内 screen==null → scrollWheelHandler.onMouseScroll(0,0) →
//     wheelXY=(0,0) → 提前 return（快捷栏不变）；
//   * 菜单内 screen.mouseScrolled(x,y,0,0)：0 增量对原版控件为算术空转。
// GLFW 路径（1.20.1 等）g_sdlWindow 恒 NULL，心跳静默不推（零回归——
// 旧版本无 inactivityFpsLimit 机制）。
// ============================================================================
static void ame104_armAfkHeartbeat(void) {
    static dispatch_source_t s_ame104_timer = nil;
    if (s_ame104_timer) return;
    s_ame104_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                            dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (!s_ame104_timer) return;
    dispatch_source_set_timer(s_ame104_timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)45 * NSEC_PER_SEC),
                              (int64_t)45 * NSEC_PER_SEC,
                              (int64_t)5 * NSEC_PER_SEC);
    static unsigned long s_ame104_beats = 0;
    dispatch_source_set_event_handler(s_ame104_timer, ^{
        if (!g_sdlWindow || !pSDL_PushEvent) return;
        pushSDLMouseWheel(0.0f, 0.0f);
        ++s_ame104_beats;
        if (s_ame104_beats <= 3 || s_ame104_beats % 20 == 0) {
            NSLog(@"[InputDiag] Task104 AFK heartbeat #%lu: wheel(0,0) pushed -- MC onScroll resets the 60s inactivity clock (SHORT_AFK 30fps cap unreachable)",
                  s_ame104_beats);
        }
    });
    dispatch_resume(s_ame104_timer);
    NSLog(@"[InputDiag] Task104 AFK heartbeat armed: 45s interval, wheel(0,0) -- inactivity FPS caps (30/10) cannot engage while the game runs");
}

// GLFW keycode → SDL_Scancode conversion
static int glfwKeyToSDLScancode(int glfwKey) {
    // Printable keys: ASCII-based, same as USB HID usage
    if (glfwKey >= GLFW_KEY_A && glfwKey <= GLFW_KEY_Z) return 4 + (glfwKey - GLFW_KEY_A);   // SDL_SCANCODE_A=4
    // Task 53（输入修复）：数字键修正。SDL 扫描码是 HID 顺序 1,2,...,9,0
    //（SDL_SCANCODE_1=30 ... SDL_SCANCODE_9=38, SDL_SCANCODE_0=39），不是
    // 0,1,...,9。旧映射 `39 + (glfwKey - GLFW_KEY_0)` 把 1-9 全部偏移 +10
    //（→40..48 = RETURN/ESC/BACKSPACE/TAB/SPACE/MINUS/...），表现为：快捷栏
    // 数字键全部失效、按 5 变成空格等错乱。
    if (glfwKey >= GLFW_KEY_1 && glfwKey <= GLFW_KEY_9) return 30 + (glfwKey - GLFW_KEY_1); // SDL_SCANCODE_1=30..SDL_SCANCODE_9=38
    if (glfwKey == GLFW_KEY_0) return 39;                                                  // SDL_SCANCODE_0=39
    if (glfwKey >= GLFW_KEY_F1 && glfwKey <= GLFW_KEY_F25) return 58 + (glfwKey - GLFW_KEY_F1); // SDL_SCANCODE_F1=58
    if (glfwKey >= GLFW_KEY_NUMPAD_0 && glfwKey <= GLFW_KEY_NUMPAD_9) return 98 + (glfwKey - GLFW_KEY_NUMPAD_0);
    switch (glfwKey) {
        case GLFW_KEY_SPACE:           return 44;
        case GLFW_KEY_APOSTROPHE:      return 52;
        case GLFW_KEY_COMMA:           return 54;
        case GLFW_KEY_MINUS:           return 45;
        case GLFW_KEY_PERIOD:          return 55;
        case GLFW_KEY_SLASH:           return 56;
        case GLFW_KEY_SEMICOLON:       return 51;
        case GLFW_KEY_EQUAL:           return 46;
        case GLFW_KEY_LEFT_BRACKET:    return 47;
        case GLFW_KEY_BACKSLASH:       return 49;
        case GLFW_KEY_RIGHT_BRACKET:   return 48;
        case GLFW_KEY_GRAVE_ACCENT:    return 53;
        case GLFW_KEY_ESCAPE:          return 41;
        case GLFW_KEY_ENTER:           return 40;
        case GLFW_KEY_TAB:             return 43;
        case GLFW_KEY_BACKSPACE:       return 42;
        case GLFW_KEY_INSERT:          return 73;
        case GLFW_KEY_DELETE:          return 76;
        case GLFW_KEY_DPAD_RIGHT:      return 79;
        case GLFW_KEY_DPAD_LEFT:       return 80;
        case GLFW_KEY_DPAD_DOWN:       return 81;
        case GLFW_KEY_DPAD_UP:         return 82;
        case GLFW_KEY_PAGE_UP:         return 75;
        case GLFW_KEY_PAGE_DOWN:       return 78;
        case GLFW_KEY_HOME:            return 74;
        case GLFW_KEY_END:             return 77;
        case GLFW_KEY_CAPS_LOCK:       return 57;
        case GLFW_KEY_SCROLL_LOCK:     return 71;
        case GLFW_KEY_NUM_LOCK:        return 83;
        case GLFW_KEY_PRINT_SCREEN:    return 70;
        case GLFW_KEY_PAUSE:           return 72;
        case GLFW_KEY_LEFT_SHIFT:      return 225;
        case GLFW_KEY_LEFT_CONTROL:    return 224;
        case GLFW_KEY_LEFT_ALT:        return 226;
        case GLFW_KEY_LEFT_SUPER:      return 227;
        case GLFW_KEY_RIGHT_SHIFT:     return 229;
        case GLFW_KEY_RIGHT_CONTROL:   return 228;
        case GLFW_KEY_RIGHT_ALT:       return 230;
        case GLFW_KEY_RIGHT_SUPER:     return 231;
        case GLFW_KEY_MENU:            return 101;
        case GLFW_KEY_NUMPAD_ADD:      return 87;
        case GLFW_KEY_NUMPAD_SUBTRACT: return 86;
        case GLFW_KEY_NUMPAD_MULTIPLY: return 85;
        case GLFW_KEY_NUMPAD_DIVIDE:   return 84;
        case GLFW_KEY_NUMPAD_DECIMAL:  return 220;
        case GLFW_KEY_NUMPAD_ENTER:    return 88;
        case GLFW_KEY_NUMPAD_EQUAL:    return 103;
        default:                       return 0; // SDL_SCANCODE_UNKNOWN
    }
}

// SDL button ID mapping: GLFW uses 0-based, SDL uses 1-based
static uint8_t glfwButtonToSDLButton(int glfwButton) {
    switch (glfwButton) {
        case GLFW_MOUSE_BUTTON_LEFT:   return 1; // SDL_BUTTON_LEFT
        case GLFW_MOUSE_BUTTON_RIGHT:  return 3; // SDL_BUTTON_RIGHT
        case GLFW_MOUSE_BUTTON_MIDDLE: return 2; // SDL_BUTTON_MIDDLE
        default:                       return (uint8_t)(glfwButton + 1);
    }
}

jint (*orig_ProcessImpl_forkAndExec)(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream);
jlong (*orig_ProcessHandleImpl_isAlive0)(JNIEnv *env, jclass clazz, jlong jpid);

NSString* processPath(NSString* path) {
    if ([path hasPrefix:@"file:"]) {
        path = [path substringFromIndex:5].stringByRemovingPercentEncoding;
    }
    path = path.stringByResolvingSymlinksInPath;

    NSString *prefix = @"file";
    if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"shareddocuments://"]] &&
      ![path hasPrefix:@"/var/mobile/Documents"]) {
        // Prefer opening in Files if containerized
        prefix = @"shareddocuments";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"filza://"]]) {
        // Open in Filza if installed
        prefix = @"filza";
    } else if ([UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"santander://"]]) {
        // Open in Santander if installed
        prefix = @"santander";
    }

    return [NSString stringWithFormat:@"%@://%@", prefix, path];
}

void openURLGlobal(NSString *path) {
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([path hasPrefix:@"http"]) {
            openLink(UIWindow.mainWindow.rootViewController, [NSURL URLWithString:path]);
            dispatch_group_leave(group);
            return;
        }
        // ★ Task222（清单第 10 项）：游戏内"打开文件夹"无反应根修。
        //   旧链路：裸目录路径 -> processPath 拼成 "file://<path>"（缺第三个
        //   "/" 且未 percent-encode）-> [NSURL URLWithString:] 解析出错误 URL
        //   -> openURL 静默失败（日志只打 "Failed to open"，用户看到无反应）。
        //   且 iOS 上 openURL 打不开沙盒内目录（除非装了 Filza/Santander）。
        //   修复：目录路径改走启动器自带的应用内文件浏览器
        //   （FileListViewController，包 nav 后 present，Files.app 风格浏览
        //   + 滑动删除 + 分享）；文件路径保持原有 URL scheme 链不变。
        NSString *fsPath = path;
        if ([fsPath hasPrefix:@"file:"]) {
            fsPath = [fsPath substringFromIndex:5].stringByRemovingPercentEncoding;
        }
        fsPath = fsPath.stringByResolvingSymlinksInPath;
        BOOL isDir = NO;
        BOOL pathExists = [[NSFileManager defaultManager] fileExistsAtPath:fsPath
                                                               isDirectory:&isDir];
        if (pathExists && isDir) {
            @try {
                UIViewController *presenter = UIWindow.mainWindow.rootViewController;
                while (presenter.presentedViewController != nil) {
                    presenter = presenter.presentedViewController;
                }
                // ★ Task223（清单第 9 项）：换用 FolderBrowserViewController。
                //   病历：Task222 路由到的 FileListViewController 是自定义控件
                //   JSON 选择器——只列 .json、无标题无导航，普通文件夹上
                //   = 空列表 = 用户只看到 PageSheet 毛玻璃。新浏览器支持全
                //   类型、目录下钻、QL 预览与分享。
                UINavigationController *nav = [FolderBrowserViewController wrappedControllerForPath:fsPath];
                [presenter presentViewController:nav animated:YES completion:nil];
                NSLog(@"[input_bridge] Task223: opened folder in-app browser: %@", fsPath);
            } @catch (NSException *e) {
                NSLog(@"[input_bridge] Task223: in-app folder browser exception: %@", e);
            }
            dispatch_group_leave(group);
            return;
        }
        NSString *realPath = processPath(path);
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:realPath] options:@{} completionHandler:^(BOOL success) {
            if (success) {
                NSLog(@"Opened \"%@\"", realPath);
            } else {
                NSLog(@"Failed to open \"%@\"", realPath);
            }
            dispatch_group_leave(group);
        }];
    });

    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
}

/**
 * Hooked version of java.lang.UNIXProcess.forkAndExec()
 * which is used to handle the "open" command.
 *
 * iOS 沙箱禁止 fork/exec，原生 forkAndExec 必然失败并可能导致进程崩溃。
 * 此处对非 "open" 命令不再透传给原生实现，而是抛出明确的 Java IOException，
 * 让调用方（如 Forge/NeoForge installer.jar 的 processor 步骤）能优雅失败而非原生崩溃。
 * "open" 命令仍走 URL scheme 转发到 Files/Filza 等外部应用。
 */
jint
hooked_ProcessImpl_forkAndExec(JNIEnv *env, jobject process, jint mode, jbyteArray helperpath, jbyteArray prog, jbyteArray argBlock, jint argc, jbyteArray envBlock, jint envc, jbyteArray dir, jintArray std_fds, jboolean redirectErrorStream) {
    char *pProg = (char *)((*env)->GetByteArrayElements(env, prog, NULL));

    // Here we only handle the "open" command
    if (strcmp(basename(pProg), "open")) {
        // 非 "open" 命令：iOS 沙箱禁止 fork/exec，透传给原生实现会导致
        // "Operation not permitted" 或直接崩溃。改为抛 IOException 让上层优雅失败。
        NSLog(@"[input_bridge] Blocked fork/exec of '%s' (iOS sandbox forbids fork/exec)", pProg);
        (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
        jclass exClass = (*env)->FindClass(env, "java/io/IOException");
        if (exClass != NULL) {
            (*env)->ThrowNew(env, exClass, "fork/exec not permitted on iOS sandbox");
            (*env)->DeleteLocalRef(env, exClass);
        }
        return -1;
    }

    char *path = (char *)((*env)->GetByteArrayElements(env, argBlock, NULL));
    openURLGlobal(@(path));

    (*env)->ReleaseByteArrayElements(env, prog, (jbyte *)pProg, 0);
    (*env)->ReleaseByteArrayElements(env, argBlock, (jbyte *)path, 0);
    return 0;
}

/**
 * Hooked version of java.lang.ProcessHandleImpl.isAlive0()
 * which is used to ignore "Operation not permitted"
 */
jlong hooked_ProcessHandleImpl_isAlive0(JNIEnv *env, jclass clazz, jlong jpid) {
    jlong result = orig_ProcessHandleImpl_isAlive0(env, clazz, jpid);
    if ((*env)->ExceptionOccurred(env)) {
        (*env)->ExceptionClear(env);
    }
    return result;
}

// Part of awt_bridge
void CTCClipboard_nQuerySystemClipboard(JNIEnv *env, jclass clazz) {
    if(method_SystemClipboardDataReceived == NULL) {
        class_CTCClipboard = (*env)->NewGlobalRef(env, clazz);
        method_SystemClipboardDataReceived = (*env)->GetStaticMethodID(env, clazz, "systemClipboardDataReceived", "(Ljava/lang/String;Ljava/lang/String;)V");
    }
    // From Java_net_kdt_pojavlaunch_AWTInputBridge_nativeClipboardReceived
    // Note: we cannot use main_queue here as it will cause deadlock
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        JNIEnv *env;
        (*runtimeJavaVMPtr)->AttachCurrentThread(runtimeJavaVMPtr, &env, NULL);
        const char* mimeChars = "text/plain";
        (*env)->CallStaticVoidMethod(env, class_CTCClipboard, method_SystemClipboardDataReceived,
            UIKit_accessClipboard(env, CLIPBOARD_PASTE, NULL),
            (*env)->NewStringUTF(env, mimeChars));
        (*runtimeJavaVMPtr)->DetachCurrentThread(runtimeJavaVMPtr);
    });
}

void CTCClipboard_nPutClipboardData(JNIEnv* env, jclass clazz, jstring clipboardData, jstring clipboardDataMime) {
    // TODO: handle non-text data(?)
    UIKit_accessClipboard(env, CLIPBOARD_COPY, clipboardData);
}

void CTCDesktopPeer_openGlobal(JNIEnv *env, jclass clazz, jstring path) {
    const char* stringChars = (*env)->GetStringUTFChars(env, path, NULL);
    openURLGlobal(@(stringChars));
    (*env)->ReleaseStringUTFChars(env, path, stringChars);
}

void registerOpenHandler(JNIEnv *env) {
    jclass cls;

    // Hook forkAndExec
    orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_UNIXProcess_forkAndExec");
    if (!orig_ProcessImpl_forkAndExec) {
        orig_ProcessImpl_forkAndExec = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessImpl_forkAndExec");
        cls = (*env)->FindClass(env, "java/lang/ProcessImpl");
    } else {
        cls = (*env)->FindClass(env, "java/lang/UNIXProcess");
    }
    JNINativeMethod forkAndExecMethod[] = {
        {"forkAndExec", "(I[B[B[BI[BI[B[IZ)I", (void *)&hooked_ProcessImpl_forkAndExec}
    };
    (*env)->RegisterNatives(env, cls, forkAndExecMethod, 1);

    // (Java 17 only) Hook isAlive0
    cls = (*env)->FindClass(env, "java/lang/ProcessHandleImpl");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 8
        (*env)->ExceptionClear(env);
    } else {
        orig_ProcessHandleImpl_isAlive0 = dlsym(RTLD_DEFAULT, "Java_java_lang_ProcessHandleImpl_isAlive0");
        JNINativeMethod isAlive0Method[] = {
            {"isAlive0", "(J)J", (void *)&hooked_ProcessHandleImpl_isAlive0}
        };
        (*env)->RegisterNatives(env, cls, isAlive0Method, 1);
    }

    // Register CTCClipboard natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCClipboard");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17
        (*env)->ExceptionClear(env);
        cls = (*env)->FindClass(env, "com/github/caciocavallosilano/cacio/ctc/CTCClipboard");
    }
    JNINativeMethod clipboardMethods[] = {
        {"nQuerySystemClipboard", "()V", (void *)&CTCClipboard_nQuerySystemClipboard},
        {"nPutClipboardData", "(Ljava/lang/String;Ljava/lang/String;)V", (void *)&CTCClipboard_nPutClipboardData}
    };
    (*env)->RegisterNatives(env, cls, clipboardMethods, 2);

    // Register CTCDesktopPeer natives
    cls = (*env)->FindClass(env, "net/java/openjdk/cacio/ctc/CTCDesktopPeer");
    if ((*env)->ExceptionOccurred(env)) {
        // Java 17, not available
        //(*env)->ExceptionDescribe(env);
        (*env)->ExceptionClear(env);
        return;
    }
    JNINativeMethod peerOpenMethods[] = {
        {"openFile", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal},
        {"openUri", "(Ljava/lang/String;)V", (void *)&CTCDesktopPeer_openGlobal}
    };
    (*env)->RegisterNatives(env, cls, peerOpenMethods, 2);
}

// JNI_OnLoad
void JNI_OnLoadGLFW() {
    if (runtimeJNIEnvPtr == NULL) {
        NSLog(@"[JNI] JNI_OnLoadGLFW: runtimeJNIEnvPtr is NULL, skipping");
        return;
    }
    jclass clazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    if (clazz == NULL) {
        if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
            (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
            (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        }
        NSLog(@"[JNI] JNI_OnLoadGLFW: FindClass(org/lwjgl/glfw/GLFW) returned NULL, skipping registration");
        return;
    }
    vmGlfwClass = (*runtimeJNIEnvPtr)->NewGlobalRef(runtimeJNIEnvPtr, clazz);
    method_internalWindowSizeChanged = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, vmGlfwClass, "internalWindowSizeChanged", "(JII)V");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        method_internalWindowSizeChanged = NULL;
    }
    jfieldID field_keyDownBuffer = (*runtimeJNIEnvPtr)->GetStaticFieldID(runtimeJNIEnvPtr, vmGlfwClass, "keyDownBuffer", "Ljava/nio/ByteBuffer;");
    if ((*runtimeJNIEnvPtr)->ExceptionOccurred(runtimeJNIEnvPtr)) {
        (*runtimeJNIEnvPtr)->ExceptionDescribe(runtimeJNIEnvPtr);
        (*runtimeJNIEnvPtr)->ExceptionClear(runtimeJNIEnvPtr);
        field_keyDownBuffer = NULL;
    }
    if (field_keyDownBuffer != NULL) {
        jobject keyDownBufferJ = (*runtimeJNIEnvPtr)->GetStaticObjectField(runtimeJNIEnvPtr, vmGlfwClass, field_keyDownBuffer);
        if (keyDownBufferJ != NULL) {
            keyDownBuffer = (*runtimeJNIEnvPtr)->GetDirectBufferAddress(runtimeJNIEnvPtr, keyDownBufferJ);
        }
    }
    NSLog(@"[JNI] JNI_OnLoadGLFW registered, class=%p, method=%p, keyDownBuffer=%p", (void *)vmGlfwClass, (void *)method_internalWindowSizeChanged, (void *)keyDownBuffer);
}

jint JNI_OnLoad(JavaVM* vm, void* reserved) {
    runtimeJavaVMPtr = vm;

    // Initialize SDL3 event function pointers for MC 26.3+ input
    initSDLEventFuncs();

    JNIEnv *env;
    (*runtimeJavaVMPtr)->GetEnv(runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    registerOpenHandler(env);
    if (!getenv("POJAV_SKIP_JNI_GLFW")) {
        runtimeJNIEnvPtr = env;
        JNI_OnLoadGLFW();
    }

    return JNI_VERSION_1_4;
}

// Should be?
void JNI_OnUnload(JavaVM* vm, void* reserved) {
    runtimeJNIEnvPtr = NULL;
}

#define ADD_CALLBACK_WWIN(NAME) \
JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(JNIEnv * env, jclass cls, jlong window, jlong callbackptr) { \
    void** oldCallback = (void**) &GLFW_invoke_##NAME; \
    GLFW_invoke_##NAME = (GLFW_invoke_##NAME##_func*) (uintptr_t) callbackptr; \
    return (jlong) (uintptr_t) *oldCallback; \
}

ADD_CALLBACK_WWIN(Char)
ADD_CALLBACK_WWIN(CharMods)
ADD_CALLBACK_WWIN(CursorEnter)
ADD_CALLBACK_WWIN(CursorPos)
ADD_CALLBACK_WWIN(FramebufferSize)
ADD_CALLBACK_WWIN(Key)
ADD_CALLBACK_WWIN(MouseButton)
ADD_CALLBACK_WWIN(Scroll)
ADD_CALLBACK_WWIN(WindowPos)
ADD_CALLBACK_WWIN(WindowSize)

#undef ADD_CALLBACK_WWIN

void handleFramebufferSizeJava(void* window, int w, int h) {
    if(GLFW_invoke_CursorEnter)GLFW_invoke_CursorEnter(window, 1);
    if(GLFW_invoke_WindowPos)GLFW_invoke_WindowPos(window, 0, 0);
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, vmGlfwClass, method_internalWindowSizeChanged, (long)window, w, h);
}

void pojavPumpEvents(void* window) {
    static BOOL setInputReady = NO;
    static int pumpCount = 0;
    if(!setInputReady) {
        setInputReady = YES;
        CallbackBridge_nativeSetInputReady(YES);
        NSLog(@"[InputDiag] pojavPumpEvents: isInputReady set to YES, showingWindow=%p", (void*)showingWindow);
    }
    pumpCount++;

    // Poll SDL relative mouse mode periodically (not just on touch) so cursor
    // hides automatically when entering the map, without needing a touch first.
    if (g_sdlWindow && pumpCount % 30 == 0) {
        typedef bool (*GetRelModeFunc)(void*);
        static GetRelModeFunc getRelMode = NULL;
        static bool inited = false;
        if (!inited) {
            getRelMode = (GetRelModeFunc)dlsym(RTLD_DEFAULT, "SDL_GetWindowRelativeMouseMode");
            inited = true;
        }
        if (getRelMode) {
            bool relMode = getRelMode(g_sdlWindow);
            if (relMode != isGrabbing) {
                BOOL wasGrabbing = isGrabbing;
                isGrabbing = relMode;
                // Task66：兑底路径同样复位摇杆方向去重状态
                AmeControlJoystickOnGrabChange(relMode);

                if (!wasGrabbing && relMode) {
                    pushSDLMouseButton(1, false, (float)cursorX, (float)cursorY);
                }

                typedef bool (*VoidFunc)(void);
                static VoidFunc hideCursor = NULL;
                static VoidFunc showCursor = NULL;
                if (!hideCursor) hideCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_HideCursor");
                if (!showCursor) showCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_ShowCursor");
                if (relMode && hideCursor) hideCursor();
                else if (!relMode && showCursor) showCursor();

                dispatch_async(dispatch_get_main_queue(), ^{
                    @try {
                        SurfaceViewController *vc = (SurfaceViewController *)UIWindow.mainWindow.rootViewController;
                        if (vc) [vc updateGrabState];
                    } @catch (NSException *e) {}
                });

                NSLog(@"[InputDiag] isGrabbing synced from SDL (pump): %d", isGrabbing);
            }
        }
    }
    if (pumpCount <= 5 || pumpCount % 300 == 0) {
        NSLog(@"[InputDiag] pojavPumpEvents #%d: window=%p GLFW_invoke_Key=%p GLFW_invoke_CursorPos=%p GLFW_invoke_Char=%p isGrabbing=%d isUseStackQueue=%d eventCounter=%d",
            pumpCount, window,
            (void*)GLFW_invoke_Key, (void*)GLFW_invoke_CursorPos, (void*)GLFW_invoke_Char,
            isGrabbing, isUseStackQueueCall,
            (int)atomic_load_explicit(&eventCounter, memory_order_relaxed));
    }
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if((cLastX != cursorX || cLastY != cursorY) && GLFW_invoke_CursorPos) {
        cLastX = cursorX;
        cLastY = cursorY;
        if (isUseStackQueueCall)
            GLFW_invoke_CursorPos(window, cursorX, cursorY);
    }
    for(size_t i = 0; i < counter; i++) {
        GLFWInputEvent event = events[i];
        switch(event.type) {
            case EVENT_TYPE_CHAR:
                if(GLFW_invoke_Char) GLFW_invoke_Char(window, event.i1);
                break;
            case EVENT_TYPE_CHAR_MODS:
                if(GLFW_invoke_CharMods) GLFW_invoke_CharMods(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_KEY:
                if(GLFW_invoke_Key) GLFW_invoke_Key(window, event.i1, event.i2, event.i3, event.i4);
                break;
            case EVENT_TYPE_MODIFIERS:
                CallbackBridge_syncModifiersToMC(event.i1);
                break;
            case EVENT_TYPE_MOUSE_BUTTON:
                if(GLFW_invoke_MouseButton) GLFW_invoke_MouseButton(window, event.i1, event.i2, event.i3);
                break;
            case EVENT_TYPE_SCROLL:
                if(GLFW_invoke_Scroll) GLFW_invoke_Scroll(window, event.f1, event.f2);
                break;
            case EVENT_TYPE_FRAMEBUFFER_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_FramebufferSize) GLFW_invoke_FramebufferSize(window, event.i1, event.i2);
                break;
            case EVENT_TYPE_WINDOW_SIZE:
                handleFramebufferSizeJava(window, event.i1, event.i2);
                if(GLFW_invoke_WindowSize) GLFW_invoke_WindowSize(window, event.i1, event.i2);
                break;
        }
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}
void pojavRewindEvents() {
    atomic_store_explicit(&eventCounter, 0, memory_order_release);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(JNIEnv *env, jclass clazz, jlong window, jobject xpos,
                                          jobject ypos) {
    *(double*)(*env)->GetDirectBufferAddress(env, xpos) = cursorX;
    *(double*)(*env)->GetDirectBufferAddress(env, ypos) = cursorY;
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(JNIEnv *env, jclass clazz, jlong window,
                                            jdoubleArray xpos, jdoubleArray ypos) {
    (*env)->SetDoubleArrayRegion(env, xpos, 0,1, &cursorX);
    (*env)->SetDoubleArrayRegion(env, ypos, 0,1, &cursorY);
}

JNIEXPORT void JNICALL
Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(JNIEnv *env, jclass clazz, jlong window, jdouble xpos,
                                          jdouble ypos) {
    cLastX = cursorX = xpos;
    cLastY = cursorY = ypos;
}

void sendData(short type, int i1, int i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->i1 = i1;
        event->i2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void sendDataFloat(short type, float i1, float i2, short i3, short i4) {
    size_t counter = atomic_load_explicit(&eventCounter, memory_order_acquire);
    if (counter < 7999) {
        GLFWInputEvent *event = &events[counter++];
        event->type = type;
        event->f1 = i1;
        event->f2 = i2;
        event->i3 = i3;
        event->i4 = i4;
    }
    atomic_store_explicit(&eventCounter, counter, memory_order_release);
}

void closeGLFWWindow() {
    NSLog(@"Closing GLFW window");

    /*
    jclass glfwClazz = (*runtimeJNIEnvPtr)->FindClass(runtimeJNIEnvPtr, "org/lwjgl/glfw/GLFW");
    assert(glfwClazz != NULL);
    jmethodID glfwMethod = (*runtimeJNIEnvPtr)->GetStaticMethodID(runtimeJNIEnvPtr, glfwMethod, "glfwSetWindowShouldClose", "(JZ)V");
    assert(glfwMethod != NULL);
    
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(
        runtimeJNIEnvPtr,
        glfwClazz, glfwMethod,
        (jlong) showingWindow, JNI_TRUE
    );
    */
    exit(-1);
}

const int hotbarKeys[9] = {
    GLFW_KEY_1, GLFW_KEY_2, GLFW_KEY_3,
    GLFW_KEY_4, GLFW_KEY_5, GLFW_KEY_6,
    GLFW_KEY_7, GLFW_KEY_8, GLFW_KEY_9
};
int guiScale = 1;
int mcscale(CGFloat input) {
    return (int)((guiScale * input)/resolutionScale);
}

// ============================================================================
// Task 63：guiScale 原生直读（物品栏点击修复）
//
// 现象（7c4bff5 构建日志实锤）：grab 状态每次切换都打印
//   "updateMCGuiScale skipped: no JNIEnv for this thread"
// —— GetEnv 与 AttachCurrentThread 在同步线程上双双失败，Java 侧
// UIKit.updateMCGuiScale() 从未被调用，guiScale 永远卡在初始值 1。
// 后果：mcscale() 把 hotbar 命中区缩到约 180x20 物理像素（2360x1640
// 屏上），点击物品栏几乎必然落空，被当作普通游戏触摸消费。
//
// 修复思路：不再依赖 JNIEnv。options.txt 就在 POJAV_GAME_DIR（= cwd
// = -Duser.dir，main.m 已 setenv）下，native 直接解析 guiScale 行，
// 复刻 Java 侧 UIKit.updateMCGuiScale() 的完整算法：
//   raw = options.txt 的 guiScale（0/缺省 = auto）
//   auto = max(min(mGLFWWindowWidth/320, mGLFWWindowHeight/240), 1)
//   scale = (raw == 0 || auto < raw) ? auto : raw
// 其中 mGLFWWindow* 与 native 全局 windowWidth/windowHeight 同源
// （launchJVM 告知的启动器像素口径）。
//
// 刷新时机：grab 状态每次切换（进游戏/开菜单/关菜单）。用户在 MC
// 设置里改 GUI 大小必然经过"开菜单(grab off) → 改 → 关菜单(grab on)"，
// 下一次切换即拿到新值。文件只在切换沿读取（状态不变不读），开销可忽略。
// ============================================================================
static int readGuiScaleFromOptions(void) {
    // Task179：CWD 优先——实例的 options.txt 在【自定义 gameDir】里。
    // 病历（9aacebb 装机 latestlog.1，mg FO 26.3 实例会话）：POJAV_GAME_DIR
    // 是 main.m 时代指向 instances/<multidir> 符号链接的固定值，而 modrinth/
    // 自定义实例的实际游戏目录是 instances/<multidir>/custom_gamedir/…
    // （Task97 CwdAlign 把进程 CWD 对齐到它，MC 读写 options.txt 也用
    // 相对路径落在那里）。旧实现读的永远是基础实例的文件：日志实锤
    // "raw=0 auto=4"（实例里明明设了 guiScale）——用户改界面尺寸后
    // 物品栏命中矩形永远按旧 scale 计算 = “调节尺寸后错位”的存活根因。
    // MC 运行期间 CWD == 实际 gameDir，优先读 ./options.txt。
    char path[PATH_MAX];
    FILE *f = fopen("options.txt", "r");
    if (f == NULL) {
        const char *gameDir = getenv("POJAV_GAME_DIR");
        if (gameDir == NULL) return 0;
        if (snprintf(path, sizeof(path), "%s/options.txt", gameDir) >= (int)sizeof(path)) return 0;
        f = fopen(path, "r");
    }
    if (f == NULL) return 0;
    int value = 0;
    char line[256];
    while (fgets(line, sizeof(line), f) != NULL) {
        if (strncmp(line, "guiScale:", 9) == 0) {
            value = atoi(line + 9);
            break;
        }
    }
    fclose(f);
    return value;   // 0 = 未找到行（视为 auto）
}

static void refreshGuiScaleNatively(void) {
    int raw = readGuiScaleFromOptions();
    if (windowWidth <= 0 || windowHeight <= 0) return;   // 启动早期兜底
    int autoScale = MAX(MIN(windowWidth / 320, windowHeight / 240), 1);
    int newScale = (raw == 0 || autoScale < raw) ? autoScale : raw;
    if (newScale != guiScale) {
        NSLog(@"[HotbarDiag] Task63 native guiScale refresh: %d -> %d (raw=%d auto=%d win=%dx%d)",
              guiScale, newScale, raw, autoScale, windowWidth, windowHeight);
        guiScale = newScale;
    }
}

// ============================================================================
// Task 67：options.txt 移动键位净化器（"按 Shift 才能动"终极根因收网）
//
// 证据链（0cc265f 日志，8ce4c18 构建，Task66 修复全生效后症状依旧）：
//   1. 摇杆 WASD 事件全链绿：sendKey→Task64 consumed→Task65 resolve 1:1
//      咬合，keyPress 确认执行（resolve 在 lambda 内求值）。
//   2. F3+F4 游戏模式切换 9 次成功（sendKey #200 key=293→sc=61 实锤）——
//      F3/F4 是**默认键位**（debugKeys 不经 options.txt 加载路径）。
//   3. WASD 走的是 Options.load → key_key.* 路径；反编译确认默认
//      keyUp=Key(26)="key.keyboard.w"（26.3 InputConstants 为 SDL 扫描码
//      空间：a=4..z=29、space=44、f3=60、f4=61、lctrl=224、lshift=225）。
//   4. KeyboardHandler.keyPress→KeyMapping.set(Key(26))→KeyboardInput.tick
//      →LocalPlayer.applyInput 全链反编译复核无瑕疵；无 setAll/releaseAll
//      高频清键（死区阶段零 grab 翻转）；无焦点事件；无暂停屏。
//
// 推论（唯一幸存假设）：用户设备 options.txt 的移动/跳跃/潜行/疾跑键位
// 已被写坏（最可能场景：输入损坏时代用户打开"按键设置"想自救，绑定捕获
// 对话框把当时的垃圾事件当成新键位——例如把"前进"绑到了唯一有反应的
// Shift 上，从此"按住 Shift 才能走"）。键位坏档无法自愈：每次启动 MC
// 都从 options.txt 加载坏绑定，所有事件层修复对其无效。
//
// 修复：launchJVM 早期（MC 读 options.txt 之前）扫描并回归默认值：
//   key_key.forward→key.keyboard.w   key_key.left→key.keyboard.a
//   key_key.back→key.keyboard.s      key_key.right→key.keyboard.d
//   key_key.jump→key.keyboard.space  key_key.sneak→key.keyboard.left.shift
//   key_key.sprint→key.keyboard.left.ctrl
// 仅重写"存在且偏离默认"的行；改写前备份 options.txt.amethyst-bak；
// 幂等（全部正常时零写盘）。同时全量 dump key_key.* 与 toggleCrouch/
// toggleSprint 行——下轮日志直接实锤或证伪本假设。
// ============================================================================
static const struct { const char *opt; const char *defv; } ame67_canonicalKeys[] = {
    { "key_key.forward", "key.keyboard.w" },
    { "key_key.left",    "key.keyboard.a" },
    { "key_key.back",    "key.keyboard.s" },
    { "key_key.right",   "key.keyboard.d" },
    { "key_key.jump",    "key.keyboard.space" },
    { "key_key.sneak",   "key.keyboard.left.shift" },
    { "key_key.sprint",  "key.keyboard.left.control" },   // 注意：真名是 .control（224），.ctrl 不存在（verify D9 抓获）
};
#define AME67_CANONICAL_COUNT (sizeof(ame67_canonicalKeys) / sizeof(ame67_canonicalKeys[0]))

void ame67_sanitizeOptionsKeybinds(void) {
    // Task179：实例 gameDir 优先（AME67_INSTANCE_GAME_DIR，JavaLauncher 在
    // gameDir 解析后 setenv 再调用本函数）→ CWD → POJAV_GAME_DIR 兜底。
    // 病历：POJAV_GAME_DIR 指向 instances/<multidir> 符号链接，自定义实例
    // 的 options.txt 实际在 custom_gamedir/… 下——旧实现净化错了文件，
    // "keybind sanitize: 0 repairs" 看似正常实则空转。
    char path[PATH_MAX];
    const char *ame67_dir = getenv("AME67_INSTANCE_GAME_DIR");
    if (ame67_dir != NULL && ame67_dir[0] != '\0') {
        if (snprintf(path, sizeof(path), "%s/options.txt", ame67_dir) >= (int)sizeof(path)) return;
    } else {
        snprintf(path, sizeof(path), "options.txt");
    }
    FILE *f = fopen(path, "rb");
    if (f == NULL) {
        const char *gameDir = getenv("POJAV_GAME_DIR");
        if (gameDir == NULL) {
            NSLog(@"[Task67] keybind sanitize skipped: no options.txt (cwd or POJAV_GAME_DIR)");
            return;
        }
        if (snprintf(path, sizeof(path), "%s/options.txt", gameDir) >= (int)sizeof(path)) return;
        f = fopen(path, "rb");
    }
    if (f == NULL) {
        NSLog(@"[Task67] options.txt absent (first run?) — MC will create defaults, nothing to sanitize");
        return;
    }
    // Task181（右 Shift 键位被反复洗掉根修）：旧实现每次启动都把 7 个移动
    // 键位强制重置为默认值——病历（afa23a6 装机，用户实测"shift依旧使用不了
    // 而另一个控件却正常"）：用户把潜行键改绑到 key.keyboard.right.shift
    // （移动端常见），每次启动净化器发现它 ≠ 默认 left.shift 就 REPAIR
    // 洗回——游戏内按右 Shift 事件链全绿但 MC 的 sneak 绑定已不在右 Shift
    // 上，表现为"右 Shift 无效"；左 Shift 按钮（或绑在默认键位的控件）正常。
    // 修法：强制重置只做【一次】（历史坏档已被洗干净，坏档成因=输入损坏
    // 时代的绑定捕获，Task66 之后不会再产生）。标记文件与 options.txt 同
    // 目录；存在则只保留 dump 取证、不再改写任何键位。删标记可重新强制
    // 一次（分诊逃生口）。
    char ame181_marker[PATH_MAX];
    if (snprintf(ame181_marker, sizeof(ame181_marker), "%s.amethyst-keybinds-v1", path) >= (int)sizeof(ame181_marker)) {
        // 路径超长：保守起见继续走旧逻辑（强制净化，宁洗勿坏）
        ame181_marker[0] = '\0';
    }
    BOOL ame181_alreadySanitized = NO;
    if (ame181_marker[0] != '\0') {
        FILE *mf = fopen(ame181_marker, "rb");
        if (mf != NULL) {
            fclose(mf);
            ame181_alreadySanitized = YES;
            NSLog(@"[Task181] keybind marker present (%s) — user customizations preserved, no forced reset this launch", ame181_marker);
        }
    }
    // Task183（右 Shift 键位损伤修复）：v1 标记存在 = 用户经历过 Task67
    // 洗回时代（每次启动把 sneak 强制重置 left.shift，用户改绑的
    // right.shift 被反复洗掉）。v1 修复只止住了未来洗涤，但【最后一次
    // 洗涤造成的损伤还在档里】（59d4b48 装机实锤：latestlog.txt 显示
    // marker present + sneak 仍处 left.shift 被洗态 = "shift 依旧用不了"）。
    // v2 一次性反向修复：v1 存在 && v2 不存在 && sneak 处于被洗默认态时
    // 恢复 right.shift（新旧两种键值格式都处理）；用户已自行改绑则尊重
    // 现状。全新安装（无 v1）直接写 v2，不受影响。
    char ame183_marker[PATH_MAX];
    if (snprintf(ame183_marker, sizeof(ame183_marker), "%s.amethyst-keybinds-v2", path) >= (int)sizeof(ame183_marker)) {
        ame183_marker[0] = '\0';
    }
    BOOL ame183_v2Needed = NO;
    if (ame183_marker[0] != '\0') {
        FILE *mf = fopen(ame183_marker, "rb");
        if (mf != NULL) {
            fclose(mf);
        } else {
            ame183_v2Needed = ame181_alreadySanitized;  // 仅损伤 cohorts
        }
    }
    // 读全文（options.txt 通常 < 64KB）
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 4 * 1024 * 1024) { fclose(f); return; }
    char *buf = (char *)malloc((size_t)sz + 1);
    if (buf == NULL) { fclose(f); return; }
    size_t rd = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[rd] = '\0';

    // 逐行扫描：dump 诊断 + 收集需重写行
    NSLog(@"[Task67] ===== options.txt keybind dump (pre-sanitize) =====");
    int repairs = 0;
    int suspicious = 0;
    // 重建输出缓冲（重写时用）
    NSMutableString *out = [NSMutableString stringWithCapacity:(NSUInteger)sz + 256];
    char *saveptr = NULL;
    char *line = strtok_r(buf, "\n", &saveptr);
    BOOL firstLine = YES;
    while (line != NULL) {
        NSString *nsline = [NSString stringWithFormat:@"%s", line];
        if (nsline == nil) {
            // 非 UTF-8 字节行（损坏档）：跳过该行（appendString:nil 会抛异常）
            NSLog(@"[Task67] SKIP non-UTF-8 line (corrupted options.txt line dropped)");
            line = strtok_r(NULL, "\n", &saveptr);
            continue;
        }
        if ([nsline hasPrefix:@"key_key."]) {
            NSRange colon = [nsline rangeOfString:@":"];
            if (colon.location != NSNotFound) {
                NSLog(@"[Task67]   %@", nsline);
                NSString *name = [nsline substringToIndex:colon.location];
                NSString *value = [[nsline substringFromIndex:colon.location + 1]
                                   stringByTrimmingCharactersInSet:
                                   [NSCharacterSet characterSetWithCharactersInString:@"\r "]];
                BOOL repaired = NO;
                for (size_t i = 0; i < AME67_CANONICAL_COUNT; i++) {
                    if ([name isEqualToString:@(ame67_canonicalKeys[i].opt)]) {
                        // Task181：一次性化——标记存在后不再强制重置（用户
                        // 自定义键位存活；仅无标记的首轮执行历史坏档清洗）。
                        if (!ame181_alreadySanitized &&
                            ![value isEqualToString:@(ame67_canonicalKeys[i].defv)]) {
                            NSLog(@"[Task67] REPAIR %@: %@ -> %@ (canonical default; was broken-era remap?)",
                                  name, value, @(ame67_canonicalKeys[i].defv));
                            nsline = [NSString stringWithFormat:@"%@:%@",
                                      name, @(ame67_canonicalKeys[i].defv)];
                            repairs++;
                            repaired = YES;
                        }
                        break;
                    }
                }
                // Task183：v2 一次性恢复——仅 sneak、仅被洗默认态。新格式
                //（key.keyboard.*，MC 1.13+）与旧数字格式（LWJGL2，MC<=1.12）
                // 分别对应 right.shift / 54。
                if (ame183_v2Needed && [name isEqualToString:@"key_key.sneak"]) {
                    NSString *ame183_target = nil;
                    if ([value isEqualToString:@"key.keyboard.left.shift"]) {
                        ame183_target = @"key.keyboard.right.shift";
                    } else if ([value isEqualToString:@"42"]) {
                        ame183_target = @"54";
                    }
                    if (ame183_target != nil) {
                        NSLog(@"[Task183] keybind v2 RESTORE sneak: %@ -> %@ (repairing Task67-era wash damage; one-shot)",
                              value, ame183_target);
                        nsline = [NSString stringWithFormat:@"key_key.sneak:%@", ame183_target];
                        repairs++;
                        repaired = YES;
                    }
                }
                if (!repaired && [value hasPrefix:@"key.keyboard.unknown"]) {
                    NSLog(@"[Task67] SUSPICIOUS (unknown-scancode binding, left as-is): %@", nsline);
                    suspicious++;
                }
            }
        } else if ([nsline hasPrefix:@"toggleCrouch:"] || [nsline hasPrefix:@"toggleSprint:"]) {
            NSLog(@"[Task67]   %@ (sneak/sprint toggle mode)", nsline);
        }
        if (!firstLine) [out appendString:@"\n"];
        [out appendString:nsline];
        firstLine = NO;
        line = strtok_r(NULL, "\n", &saveptr);
    }
    free(buf);

    if (repairs > 0) {
        // 备份 + 原子写回。
        // Task179（CI 修复轮）：旧代码此处引用 gameDir 变量——上方 Task179
        // 改造把函数开头的 gameDir 声明换成了 ame67_dir/CWD 三级解析后，
        // 这个残留引用成了 "use of undeclared identifier 'gameDir'"（CI run
        // 462/463/464 实锤）。备份路径改为从实际解析出的 path 派生——
        // 备份文件永远躺在被修复的那份 options.txt 旁边，语义更准。
        NSString *bak = [NSString stringWithFormat:@"%s.amethyst-bak", path];
        NSString *src = [NSString stringWithFormat:@"%s", path];
        NSError *err = nil;
        [[NSFileManager defaultManager] removeItemAtPath:bak error:nil];
        BOOL copied = [[NSFileManager defaultManager] copyItemAtPath:src toPath:bak error:&err];
        if (!copied) {
            NSLog(@"[Task67] WARN: backup copy failed (%@), abort repair to avoid data loss",
                  err.localizedDescription);
        } else {
            BOOL ok = [out writeToFile:src atomically:YES
                             encoding:NSUTF8StringEncoding error:nil];
            NSLog(@"[Task67] ===== keybind sanitize: %d repaired, %d suspicious, backup=%@, write=%@ =====",
                  repairs, suspicious, bak, ok ? @"OK" : @"FAILED");
        }
    } else {
        NSLog(@"[Task67] ===== keybind sanitize: 0 repairs needed (all canonical / defaults) =====");
    }
    // Task181：本轮净化跑完（无论是否发生修复）落一次性标记——下轮起用户
    // 键位自定义不再被强制重置。标记创建失败只影响下次多做一次强制（安全
    // 方向失败），不阻断启动。
    if (ame181_marker[0] != '\0' && !ame181_alreadySanitized) {
        FILE *mf = fopen(ame181_marker, "wb");
        if (mf != NULL) {
            fputs("Amethyst one-shot keybind canonicalization done (Task181). Delete this file to re-run.\n", mf);
            fclose(mf);
            NSLog(@"[Task181] keybind marker written (%s) — future launches preserve user customizations", ame181_marker);
        } else {
            NSLog(@"[Task181] WARN: marker write failed (%s) — forced reset will run once more next launch", ame181_marker);
        }
    }
    // Task183：v2 标记落盘（无论本轮是否发生恢复——只要 v1 存在或本轮跑
    // 过 v1 首次净化，就视为损伤 cohorts 已处理完毕；全新安装也直接落 v2
    // 免得未来重装组合出误恢复窗口）。
    if (ame183_marker[0] != '\0' && !ame183_v2Needed) {
        // v2Needed==NO 且 v1 标记刚写或本就是新安装：写 v2
        FILE *mf = fopen(ame183_marker, "wb");
        if (mf != NULL) {
            fputs("Amethyst keybind v2 right-shift restore evaluated (Task183). Delete this file to re-run.\n", mf);
            fclose(mf);
        }
    } else if (ame183_marker[0] != '\0' && ame183_v2Needed) {
        // v2Needed==YES：本轮已做恢复判定（恢复或尊重现状），落标记防重复
        FILE *mf = fopen(ame183_marker, "wb");
        if (mf != NULL) {
            fputs("Amethyst keybind v2 right-shift restore evaluated (Task183). Delete this file to re-run.\n", mf);
            fclose(mf);
            NSLog(@"[Task183] keybind v2 marker written (%s)", ame183_marker);
        }
    }
}

// Task67：暴露 Task66 状态数组指针给 sdl3_hook 的 GetKeyboardState 钩子对证
const bool *Ame66GetKbState(void) {
    return (const bool *)ame66_kbState;
}
int Ame66GetKbNumKeys(void) {
    return ame66_kbNumKeys;
}
int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y) {
    // 诊断：物品栏点不动时，靠这段代码一次性定位卡在哪一环。
    // 可能的失败原因互不相关，只看现象无法区分：
    //   1. isGrabbing 恒为 0 —— SDL3 下抓取状态没同步过来（最常见）
    //   2. guiScale 卡在初始值 1 —— mcscale() 把命中区域缩小到约 60x6 像素
    //   3. 传入坐标与 physicalWidth/Height 不同坐标系（rootView vs surfaceView）
    //   4. resolutionScale 异常
    // 限频：每 20 次打印一次，避免触摸时刷屏。
    static int hotbarDiagCount = 0;
    BOOL shouldLog = ((hotbarDiagCount++ % 20) == 0);

    if (isGrabbing == JNI_FALSE) {
        if (shouldLog) {
            NSLog(@"[HotbarDiag] REJECT isGrabbing=0 | x=%.1f y=%.1f | phys=%dx%d guiScale=%d resScale=%.2f sdlWin=%p",
                  x, y, (int)physicalWidth, (int)physicalHeight, guiScale,
                  (double)resolutionScale, g_sdlWindow);
        }
        return -1;
    }

    // Task 171：物品栏命中矩形改为 FSR 感知。
    // 病历（f26337d 装机日志 latestlog.old.txt，mg + FSR preset3 scale=1.70，
    // phys=2360x1640 / MC 窗口信念 1388x964 / guiScale=4）：
    //   [HotbarDiag] REJECT above bar | y=1516.0 < barY=1560
    //   [HotbarDiag] REJECT above bar | y=1556.0 < barY=1560
    // MC 画在【窗口空间】（1388x964）底部的物品栏（22 GUI 像素高 = 88 窗口
    // 像素），经 FSR 放大到物理表面后视觉顶边在 1640 - 88*1.70 ≈ 1490；
    // 而旧几何 barY = physH - 20*guiScale = 1560 —— 视觉物品栏的上半段
    // （1490~1560，约 70 物理像素）全部被 REJECT，用户必须点到物品栏的
    // 下半截才能选中槽位（实测"物品栏点击位置有点偏下"）。X 方向同理：
    // 旧 barW=720 只覆盖视觉 1238 宽的中间一段，左右各两个槽位点不到、
    // 中段槽位映射整体左偏一格。
    // 修法：用"物理像素 / MC 窗口像素"的单一事实源比例（= fsr/resolutionScale
    // 的合成，windowHeight 是 updateSavedResolution 单点写入的 MC 窗口信念）
    // 把 MC 的 182x22 精灵矩形放大到物理空间。注意不能用 mcscale()——它内部
    // 已除以 resolutionScale，而本比例同样含该因子，叠加会双重除法。无 FSR
    // 且 resolutionScale=100% 时比例恒 1.0，新几何 22*guiScale 比旧
    // 20*guiScale 只宽出精灵自带上边框（2*guiScale 像素），命中区更贴合
    // 视觉、行为无回退。比例异常（窗口未初始化/旋转间隙）回退 1.0 保持旧行为。
    // Task175：比例优先取 ame_windowToPhysRatio（updateSavedResolution 单点
    // 写入，environ.h 全局）——本地 physicalHeight/windowHeight 重算降级为
    // 该全局为 0（未就绪）时的回退。动机：windowWidth/Height 还会被
    // CallbackBridge_nativeSendScreenSize（Java 侧屏幕尺寸回报）改写，而
    // ame_windowToPhysRatio 只随旋转/分辨率/FSR 档位变化（用户实测"切换
    // 界面尺寸或更换分辨率后位置/大小偏移"的防复发加固）。
    float ame171_winToPhys = 1.0f;
    int ame175_ratioSource = 0;  // 0=回退1.0 / 1=全局单点 / 2=本地重算
    if (ame_windowToPhysRatio > 0.0f) {
        ame171_winToPhys = ame_windowToPhysRatio;
        ame175_ratioSource = 1;
    } else if (windowHeight > 0 && physicalHeight > 0) {
        float ratio = (float)physicalHeight / (float)windowHeight;
        if (ratio >= 0.25f && ratio <= 8.0f) {
            ame171_winToPhys = ratio;
            ame175_ratioSource = 2;
        }
    }
    // Task175：guiScale 节流保鲜——旧机制只在 grab 翻转沿重读 options.txt，
    // 用户改完界面尺寸立即点物品栏时命中矩形仍按旧 scale 计算（偏移窗口）。
    // 每次命中测试最多重读一次（2 秒节流，文件 ~1KB，触摸线程零负担）。
    {
        static double s_ame175_lastScaleRefresh = 0.0;
        double ame175_now = (double)clock() / (double)CLOCKS_PER_SEC;
        if (ame175_now - s_ame175_lastScaleRefresh > 2.0) {
            s_ame175_lastScaleRefresh = ame175_now;
            refreshGuiScaleNatively();
        }
    }
    int barHeight = (int)((float)(22 * guiScale) * ame171_winToPhys + 0.5f);
    // Task176：选中槽位高亮的视觉边距——MC 的选中框 sprite 是 24x24（比
    // 182x22 的物品栏上下各多出 1 GUI 像素），选中箭头再向上伸 1 像素。
    // 装机实测（latestlog.1）：y=1482 的点击被判 above-bar 拒收，而 barY=1490
    // ——差 8 物理像素 = 正好高亮/箭头的视觉范围。把命中矩形向上扩
    // 2*guiScale*ratio（≈14px）覆盖高亮与箭头，用户“点到物品栏顶部没反应”
    // 的偏移感随之消失。X/底部不变。
    int ame176_topMargin = (int)((float)(2 * guiScale) * ame171_winToPhys + 0.5f);
    int barY = physicalHeight - barHeight - ame176_topMargin;
    {
        static bool s_task171Logged = false;
        if (!s_task171Logged && ame171_winToPhys != 1.0f) {
            s_task171Logged = true;
            NSLog(@"[HotbarDiag] Task171 FSR-aware hotbar geometry: phys=%dx%d win=%dx%d ratio=%.2f barH=%d barY=%d (was barY=%d, old 20xguiScale/resScale)",
                  (int)physicalWidth, (int)physicalHeight, windowWidth, windowHeight,
                  (double)ame171_winToPhys, barHeight, barY,
                  (int)(physicalHeight - mcscale(20)));
        }
        // Task175 取证：一次性全量输入快照（phys/surface/win/fsr/resScale/
        // guiScale/比例来源）。下轮"偏移"装机日志凭这一行直接钉死是哪个
        // 变量走样——不再需要多轮猜测。
        // Task176：改为【变化触发】——旧的一次性快照只覆盖会话首个命中，
        // 用户中途改界面尺寸/分辨率后的新几何看不到（本轮正是这个盲区）。
        // guiScale/比例/物理尺寸任一变化即重新落一行。
        static bool s_task175Logged = false;
        static int s_ame176_lastScale = -1;
        static float s_ame176_lastRatio = -1.0f;
        static int s_ame176_lastPhysH = -1;
        if (!s_task175Logged || guiScale != s_ame176_lastScale ||
            ame171_winToPhys != s_ame176_lastRatio || (int)physicalHeight != s_ame176_lastPhysH) {
            s_task175Logged = true;
            s_ame176_lastScale = guiScale;
            s_ame176_lastRatio = ame171_winToPhys;
            s_ame176_lastPhysH = (int)physicalHeight;
            NSLog(@"[HotbarDiag] Task175 geometry snapshot: phys=%dx%d surface=%dx%d win=%dx%d resScale=%.2f guiScale=%d ratio=%.3f (source=%d: 1=savedResolution-global 2=local-recompute 0=fallback-1.0) barY=%d barH=%d topMargin=%d",
                  (int)physicalWidth, (int)physicalHeight, ame_surfaceWidth, ame_surfaceHeight,
                  windowWidth, windowHeight, (double)resolutionScale, guiScale,
                  (double)ame171_winToPhys, ame175_ratioSource, barY, barHeight, ame176_topMargin);
        }
    }
    if (y < barY) {
        if (shouldLog) {
            NSLog(@"[HotbarDiag] REJECT above bar | y=%.1f < barY=%d (barH=%d physH=%d guiScale=%d resScale=%.2f ratio=%.2f)",
                  y, barY, barHeight, (int)physicalHeight, guiScale, (double)resolutionScale,
                  (double)ame171_winToPhys);
        }
        return -1;
    }

    int barWidth = (int)((float)(182 * guiScale) * ame171_winToPhys + 0.5f);
    int barX = (physicalWidth / 2) - (barWidth / 2);
    if (x < barX || x >= barX + barWidth) {
        if (shouldLog) {
            NSLog(@"[HotbarDiag] REJECT outside bar | x=%.1f not in [%d,%d) barW=%d physW=%d guiScale=%d resScale=%.2f",
                  x, barX, barX + barWidth, barWidth, (int)physicalWidth, guiScale, (double)resolutionScale);
        }
        return -1;
    }

    int slot = hotbarKeys[(int) MathUtils_map(x, barX, barX + barWidth, 0, 9)];
    if (shouldLog) {
        NSLog(@"[HotbarDiag] HIT slot key=%d | x=%.1f barX=%d barW=%d physW=%d guiScale=%d",
              slot, x, barX, barWidth, (int)physicalWidth, guiScale);
    }
    return slot;
}

JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_updateMCGuiScale(JNIEnv* env, jclass clazz, jint scale) {
    guiScale = scale;
}

JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(JNIEnv* env, jclass clazz, jint action, jstring copySrc) {
    NSDebugLog(@"Debug: Clipboard access is going on\n");
    return UIKit_accessClipboard(env, action, copySrc);
}

JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(JNIEnv* env, jclass clazz, jboolean grabbing, jfloat xset, jfloat yset) {
    isGrabbing = grabbing;

    // Task162：GLFW 路径补齐 guiScale 原生刷新（与 SDL 路径
    // CallbackBridge_syncGrabStateFromSDL 的 Task63 调用对齐）。
    // 旧链路依赖 Java 侧 GLFW.glfwSetInputMode → UIKit.updateMCGuiScale()
    // 推送（launcher.jar 独有类），Forge 的 MC-BOOTSTRAP 模块层不可见 →
    // NoClassDefFoundError 存档闪退（Task162 已把 Java 侧调用移除）；
    // native 直读 options.txt 无 JNIEnv/类可见性依赖，算法与 Java 侧
    // 完全一致（见 readGuiScaleFromOptions 注释块），物品栏命中判定
    // （mcscale）在两种加载器形态下都保持新鲜。
    refreshGuiScaleNatively();

    // Manage SDL cursor visibility: hide when grabbing (in-game), show when not (menu)
    static SDL_HideCursor_func *pSDL_HideCursor = NULL;
    static SDL_ShowCursor_func *pSDL_ShowCursor = NULL;
    static BOOL cursorFuncsResolved = NO;
    if (!cursorFuncsResolved) {
        pSDL_HideCursor = dlsym(RTLD_DEFAULT, "SDL_HideCursor");
        pSDL_ShowCursor = dlsym(RTLD_DEFAULT, "SDL_ShowCursor");
        cursorFuncsResolved = YES;
    }
    if (pSDL_HideCursor && pSDL_ShowCursor) {
        if (grabbing) {
            pSDL_HideCursor();
            NSLog(@"[InputDiag] nativeSetGrabbing: SDL_HideCursor called");
        } else {
            pSDL_ShowCursor();
            NSLog(@"[InputDiag] nativeSetGrabbing: SDL_ShowCursor called");
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        SurfaceViewController *vc = [SurfaceViewController currentInstance];
        if (vc) {
            [vc updateGrabState];
        }
    });
}

JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeIsGrabbing(JNIEnv* env, jclass clazz) {
    return isGrabbing;
}

void CallbackBridge_nativeSetInputReady(BOOL inputReady) {
    isInputReady = inputReady;
    if (inputReady) {
        if (GLFW_invoke_FramebufferSize) {
            GLFW_invoke_FramebufferSize((void*) showingWindow, windowWidth, windowHeight);
        }
        // Task181（26.1.2 NeoForge 早期显示窗口 pc=0 崩溃根修）：
        // 病历（hs_err_pid1381，elapsed 1.17s）：NeoForge 26.1.2.100 的
        // earlydisplay DisplayWindow.initWindow 只注册 WindowSize 回调
        // （不注册 FramebufferSize），本分支旧代码判空的是
        // GLFW_invoke_WindowSize、调用的却是 GLFW_invoke_FramebufferSize——
        // WindowSize 非空而 FramebufferSize 为 NULL 时 BLR 0 → pc=0x0、
        // SIGSEGV si_code=SEGV_ACCERR si_addr=0（执行空指针的特征签名），
        // 崩溃帧符号化错位到 CallbackBridge_nativeSetInputReady+0xd8。
        // 26.3 走 SDL3 路径不经过此函数，只有 ≤26.2 的 GLFW 线（及
        // NeoForge earlydisplay）暴露本 bug。
        if (GLFW_invoke_WindowSize) {
            GLFW_invoke_WindowSize((void*) showingWindow, windowWidth, windowHeight);
        }
    }
}

// Queue modifier synchronization from UIKit callbacks. JNI work is consumed
// by pojavPumpEvents on the game thread, where runtimeJNIEnvPtr is valid.
void CallbackBridge_queueModifierSync(int mods) {
    if (!isInputReady) return;
    sendData(EVENT_TYPE_MODIFIERS, mods, 0, 0, 0);
}

// ============================================================================
// issue #27 修复（参照 FCL commit 08c0716）：物理键盘 modifier 同步
//
// MC 1.21.9+ 不再仅依赖 key 回调中的 mods 参数，而是通过
// InputConstants.isKeyDown(window, GLFW_KEY_LEFT_SHIFT) 查询 modifier 状态。
// 该状态由 MC 内部缓存维护，仅靠 GLFW key callback 无法同步，
// 必须显式调用 Java 端 setModifiers 才能更新。
//
// 此处通过 JNI 反射调用 com.mojang.blaze3d.platform.InputConstants
// 的内部方法（如果存在），实现 modifier 缓存的显式同步。
// 旧版本 MC 没有此机制，调用会安全失败（找不到方法直接返回）。
//
// 由 KeyboardInput.m 在物理键盘事件中调用（pressesBegan/pressesEnded），
// 也可被 Java 端 CallbackBridge.nativeSetModifiers 调用。
// ============================================================================
void CallbackBridge_syncModifiersToMC(int mods) {
    if (!runtimeJavaVMPtr || !isInputReady) return;

    JNIEnv *env = NULL;
    jint envStatus = (*runtimeJavaVMPtr)->GetEnv(
        runtimeJavaVMPtr, (void **)&env, JNI_VERSION_1_4);
    if (envStatus != JNI_OK || !env) return;

    jclass inputConstantsClass = (*env)->FindClass(env, "com/mojang/blaze3d/platform/InputConstants");
    if (!inputConstantsClass) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        return;
    }
    jmethodID setModifiersMethod = (*env)->GetStaticMethodID(env, inputConstantsClass, "setModifiers", "(I)V");
    if (!setModifiersMethod) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        (*env)->DeleteLocalRef(env, inputConstantsClass);
        return;
    }
    (*env)->CallStaticVoidMethod(env, inputConstantsClass, setModifiersMethod, (jint)mods);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
    }
    (*env)->DeleteLocalRef(env, inputConstantsClass);
}

// JNI wrapper：供 Java 端 CallbackBridge.nativeSetModifiers(int) 调用
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetModifiers(JNIEnv* env, jclass clazz, jint mods) {
    CallbackBridge_syncModifiersToMC(mods);
}

BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */) {
    if (GLFW_invoke_Char && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_CHAR, codepoint, 0, 0, 0);
        } else {
            GLFW_invoke_Char((void*) showingWindow, (unsigned int) codepoint);
            // return lwjgl2_triggerCharEvent(codepoint);
        }
        return YES;
    }
    // Path B: SDL3 text-input events (MC 26.3+) -- Task 82
    // 虚拟键盘字符在 26.3 下的唯一通道：GLFW_invoke_Char 为 NULL 时改推
    // SDL_EVENT_TEXT_INPUT，MC 的 SDLEventHandler.handleTextInputEvent 消费。
    if (!GLFW_invoke_Char && g_sdlWindow) {
        pushSDLTextInput(codepoint);
        return YES;
    }
    return NO;
}

BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods) {
    if (GLFW_invoke_CharMods && isInputReady) {
        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_CHAR_MODS, (unsigned int) codepoint, mods, 0, 0);
        } else {
            GLFW_invoke_CharMods((void*) showingWindow, codepoint, mods);
        }
        return YES;
    }
    return NO;
}
/*
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSendCursorEnter(JNIEnv* env, jclass clazz, jint entered) {
    if (GLFW_invoke_CursorEnter && isInputReady) {
        GLFW_invoke_CursorEnter(showingWindow, entered);
    }
}
*/

// ============================================================================
// grab 状态同步（MC 26.3 / SDL3）
//
// MC 26.3 改用 SDL3 后不再调用 glfwSetInputMode，于是 CallbackBridge_nativeSetGrabbing
// 与 pojavPumpEvents 都不会被触发，isGrabbing 只能从 SDL 侧同步。
//
// 原先只靠 CallbackBridge_nativeSendCursorPos 里的轮询，而它有两个致命缺陷：
//   1. 必须由触摸事件驱动 —— 进世界后玩家不碰屏幕就永远同步不了
//   2. 若 MC 根本不启用 SDL relative mouse mode，轮询结果恒为 false
// 实测日志中 isGrabbing 全程为 0，正是这条链路断了。
//
// isGrabbing 直接决定游戏内物品栏能否点击：
//   callback_SurfaceViewController_touchHotbar() 首行即 `if (isGrabbing == JNI_FALSE) return -1;`
// 同时 guiScale 也只有在本函数里才会刷新，而 mcscale() 用它计算物品栏命中区域；
// guiScale 卡在初始值 1 会让区域缩小到约 60x6 像素，等于点不中。
// 两者任一失效都会表现为"hotbar 点不动"，即上游 issue 里反馈的那个现象。
//
// 调用方：
//   1. main_hook.m 的 hooked_dlsym 拦截 SDL_SetWindowRelativeMouseMode（主路径）
//   2. CallbackBridge_nativeSendCursorPos 的轮询（兜底）
//
// 注意这里可能在任意线程被调用（渲染线程 / UI 主线程），因此 JNI 调用必须
// 获取本线程自己的 JNIEnv，不能复用 runtimeJNIEnvPtr。
// ============================================================================
void CallbackBridge_syncGrabStateFromSDL(BOOL relMode, const char *source) {
    static BOOL lastRelMode = NO;
    static BOOL haveLast = NO;

    if (haveLast && relMode == lastRelMode) return;
    haveLast = YES;
    lastRelMode = relMode;

    BOOL wasGrabbing = isGrabbing;
    isGrabbing = relMode;
    NSLog(@"[InputDiag] grab state -> %d (was %d, source=%s)",
          relMode, wasGrabbing, source ? source : "?");

    // Task66：抓取切换时复位摇杆方向去重状态。1→0（开界面）时摇杆补发
    // WASD 释放；两个沿都把 lastDirection 复位，迫使下次推杆重发全量状态
    // （配合 ame66_syncKeyboardState，setAll 恢复的 SDL 态从此与虚拟键一致）。
    AmeControlJoystickOnGrabChange(relMode);


    // 进入抓取时补发一次左键释放：菜单里那次 ACTION_DOWN 否则永远不会抬起
    if (!wasGrabbing && relMode) {
        pushSDLMouseButton(1, false, (float)cursorX, (float)cursorY);
        NSLog(@"[InputDiag] Released stale mouse button on grab enter");
    }

    // 光标显隐
    typedef bool (*VoidFunc)(void);
    static VoidFunc hideCursor = NULL;
    static VoidFunc showCursor = NULL;
    if (!hideCursor) hideCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_HideCursor");
    if (!showCursor) showCursor = (VoidFunc)dlsym(RTLD_DEFAULT, "SDL_ShowCursor");
    if (relMode && hideCursor) hideCursor();
    else if (!relMode && showCursor) showCursor();

    // 刷新 guiScale（物品栏命中判定依赖它）。
    // Task 63：改用 native 直读 options.txt。旧 JNI 链（GetEnv/Attach 后
    // 调 Java 侧 UIKit.updateMCGuiScale）在同步线程上双双失败，日志
    // "updateMCGuiScale skipped: no JNIEnv for this thread" 每次 grab
    // 切换都出现，guiScale 永远卡 1。native 直读不依赖 JNIEnv，
    // 算法与 Java 侧完全一致（见 readGuiScaleFromOptions 注释块）。
    // Java_..._UIKit_updateMCGuiScale JNI 导出保留：LWJGL 路径下
    // Java 侧（GLFW.java glfwSetInputMode 链）仍会主动推送。
    refreshGuiScaleNatively();

    // UI 侧（虚拟鼠标指针等）切回主线程刷新
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            SurfaceViewController *vc = (SurfaceViewController *)UIWindow.mainWindow.rootViewController;
            if (vc) {
                [vc updateGrabState];
            } else {
                NSLog(@"[InputDiag] updateGrabState: UIWindow.mainWindow is nil");
            }
        } @catch (NSException *e) {
            NSLog(@"[InputDiag] updateGrabState exception: %@", e);
        }
    });
}

void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y) {
    static int cursorSendCount = 0;
    cursorSendCount++;
    if (cursorSendCount <= 10 || cursorSendCount % 50 == 0) {
        NSLog(@"[InputDiag] sendCursorPos #%d: event=%d x=%.1f y=%.1f GLFW_invoke_CursorPos=%p isInputReady=%d g_sdlWindow=%p isGrabbing=%d",
            cursorSendCount, event, x, y,
            (void*)GLFW_invoke_CursorPos, isInputReady, g_sdlWindow, isGrabbing);
    }

    // Sync isGrabbing from SDL's relative mouse mode (MC 26.3 uses SDL, not GLFW).
    //
    // 主同步路径已移到 main_hook.m —— 那里通过 hooked_dlsym 拦截 MC 对
    // SDL_SetWindowRelativeMouseMode 的调用，MC 一切换立即同步，不要求玩家先触摸。
    // 这里保留轮询仅作兜底（例如 MC 改用其它 API 设置该状态时）。
    if (g_sdlWindow) {
        typedef bool (*GetRelModeFunc)(void*);
        static GetRelModeFunc getRelMode = NULL;
        static bool cursorFuncsInited = NO;
        if (!cursorFuncsInited) {
            getRelMode = (GetRelModeFunc)dlsym(RTLD_DEFAULT, "SDL_GetWindowRelativeMouseMode");
            cursorFuncsInited = YES;
            NSLog(@"[InputDiag] SDL_GetWindowRelativeMouseMode resolved: %p", (void *)getRelMode);
        }
        if (getRelMode) {
            CallbackBridge_syncGrabStateFromSDL(getRelMode(g_sdlWindow), "poll");
        }
    }

    // Update cursor position tracking regardless
    switch (event) {
        case ACTION_DOWN:
        case ACTION_UP:
            if (!isGrabbing) {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE:
            if (isGrabbing) {
                cursorX += x - cLastX;
                cursorY += y - cLastY;
            } else {
                cursorX = x;
                cursorY = y;
            }
            break;

        case ACTION_MOVE_MOTION:
            cursorX += x;
            cursorY += y;
            break;
    }

    // Path A: GLFW callbacks (older MC versions)
    if (GLFW_invoke_CursorPos && isInputReady) {
        if (!isUseStackQueueCall) {
            GLFW_invoke_CursorPos((void*) showingWindow, (double) cursorX, (double) cursorY);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    // When GLFW callbacks are NULL, we inject SDL mouse events directly.
    //
    // The raw touch path NEVER sends mouse buttons.
    // All clicks are handled by the gesture system:
    //   - surfaceOnClick (tap)     → SDL right-click (place) or left-click (menu)
    //   - surfaceOnLongpress (hold) → SDL left-click (break)
    //   - touchesMoved (drag)      → ACTION_MOVE_MOTION → camera rotation
    //
    // If we also sent buttons here, every tap would double-click
    // (once from raw touch, once from gesture).
    if (!GLFW_invoke_CursorPos && g_sdlWindow) {
        if (event == ACTION_MOVE_MOTION) {
            pushSDLMouseMotion((float)cursorX, (float)cursorY, (float)x, (float)y);
        } else {
            // Menu or in-game: always send cursor position (absolute or delta)
            pushSDLMouseMotion((float)cursorX, (float)cursorY, 0, 0);
        }
    }
}

char getKeyModifiers(int key, int action) {
    static char currMods;
    char mod;
    switch (key) {
        case GLFW_KEY_LEFT_SHIFT:
        case GLFW_KEY_RIGHT_SHIFT:
            mod = GLFW_MOD_SHIFT;
            break;
        case GLFW_KEY_LEFT_CONTROL:
        case GLFW_KEY_RIGHT_CONTROL:
            mod = GLFW_MOD_CONTROL;
            break;
        case GLFW_KEY_LEFT_ALT:
        case GLFW_KEY_RIGHT_ALT:
            mod = GLFW_MOD_ALT;
            break;
        case GLFW_KEY_LEFT_SUPER:
        case GLFW_KEY_RIGHT_SUPER:
            mod = GLFW_MOD_SUPER;
            break;
        case GLFW_KEY_CAPS_LOCK:
            mod = GLFW_MOD_CAPS_LOCK;
            break;
        case GLFW_KEY_NUM_LOCK:
            mod = GLFW_MOD_NUM_LOCK;
            break;
        default:
            return currMods;
    }
    if (action) {
        currMods |= mod;
    } else {
        currMods &= ~mod;
    }
    return currMods;
}

// ============================================================================
// Task161：GLFW 路径（MC ≤26.2）聊天自动弹出键盘——按键侧记录器。
//
// 病历（用户反馈"26.3 遇到光标能正常弹出键盘，而 26.2 及以下都不行"）：
//   MC 26.3 走 SDL3，EditBox 聚焦时调用 SDL_StartTextInputWithProperties，
//   SDL_ENABLE_SCREEN_KEYBOARD hint（Task114）让 SDL 的 iOS 后端拉起系统
//   软键盘——26.3 自动弹。MC ≤26.2 走 GLFW，而 GLFW 协议没有"开始文本
//   输入"概念：vanilla 在 EditBox 聚焦时不发任何可观察信号，启动器无从
//   得知"光标在闪"。
//   务实方案（本记录器 + SurfaceViewController.updateGrabState 消费）：
//   启动器知道自己刚把哪个键发给了 MC——游戏内按 T / 斜杠几乎必然是
//   打开聊天/命令行（vanilla 惯例），而聊天必然伴随 grab→false（开界面）。
//   "最近 1.5s 内发过 T/SLASH + grab 转 false"即判定聊天打开，主线程
//   inputTextField becomeFirstResponder（与 ⌨ 按钮同一路径）。
//   菜单/告示牌/书与笔等无键前驱的开界面不自动弹（歧义大，⌨ 手动兜底）；
//   自动弹出的键盘在 grab 恢复 true 时自动收起（ame161_autoShown 标记，
//   ⌨ 手动唤出的不受影响）。
// ============================================================================
static int ame161_lastSentKey = -1;
static CFAbsoluteTime ame161_lastSentKeyTime = 0.0;

BOOL ame161_lastSentKeyWasChatOpener(NSTimeInterval withinSeconds) {
    // GLFW_KEY_T=84 / GLFW_KEY_SLASH=53（输入侧统一 GLFW 键码，与
    // nativeSendKey 的 key 参数同口径）。
    if (ame161_lastSentKey != 84 && ame161_lastSentKey != 53) return NO;
    CFAbsoluteTime ame161_now = CFAbsoluteTimeGetCurrent();
    return (ame161_now - ame161_lastSentKeyTime) <= withinSeconds;
}

// Task161（CI 9b57650 修复）：g_sdlWindow 是本文件的 static，SurfaceViewController
// 不能直接引用（首次提交 use of undeclared identifier 'g_sdlWindow' 编译错误）。
// 导出判定函数：YES = GLFW 输入路径（MC ≤26.2，聊天键盘自动弹的唯一适用面）；
// NO = SDL3 路径（MC 26.3+，系统键盘由 SDL screen keyboard 协议自理）。
BOOL ame161_inputPathIsGLFW(void) {
    return g_sdlWindow == NULL;
}

void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {
    static int keySendCount = 0;
    keySendCount++;
    if (keySendCount <= 10 || keySendCount % 50 == 0) {
        NSLog(@"[InputDiag] sendKey #%d: key=%d scancode=%d action=%d mods=%d GLFW_invoke_Key=%p isInputReady=%d g_sdlWindow=%p",
            keySendCount, key, scancode, action, mods,
            (void*)GLFW_invoke_Key, isInputReady, g_sdlWindow);
    }

    // Task224：shift 键全量取证（用户报"右 Shift 又失效"——静态链左右对称、
    // 端到端核验无缺失；下一轮装机日志须能直接定位断点：控件未触发 /
    // 映射丢弃 / 双路径均未命中 / 事件送达但 MC 不消费）。
    if (key == GLFW_KEY_LEFT_SHIFT || key == GLFW_KEY_RIGHT_SHIFT) {
        const char *ame224_path =
            (GLFW_invoke_Key && isInputReady) ? "A(GLFW)"
            : ((!GLFW_invoke_Key && g_sdlWindow) ? "B(SDL)" : "NONE(event lost)");
        NSLog(@"[InputDiag] Task224 shiftKey: key=%d action=%d mods=%d path=%s GLFW_invoke_Key=%p isInputReady=%d g_sdlWindow=%p",
              key, action, mods, ame224_path, (void*)GLFW_invoke_Key, isInputReady, g_sdlWindow);
    }

    // Task161：记录最近一次按下（action==1）的键——聊天自动弹键盘判定用。
    if (action == 1) {
        ame161_lastSentKey = key;
        ame161_lastSentKeyTime = CFAbsoluteTimeGetCurrent();
    }

    // Path A: GLFW callbacks (older MC versions)
    if (GLFW_invoke_Key && isInputReady) {
        keyDownBuffer[MAX(0, key-31)]=(jbyte)action;
        if (mods == 0) {
            mods = getKeyModifiers(key, action);
        }

        if (isUseStackQueueCall) {
            sendData(EVENT_TYPE_KEY, key, scancode, action, mods);
        } else {
            GLFW_invoke_Key((void*) showingWindow, key, scancode, action, mods);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_Key && g_sdlWindow) {
        int sdlScancode = glfwKeyToSDLScancode(key);
        if (sdlScancode != 0) {
            pushSDLKeyboardEvent(sdlScancode, action != 0);
        } else {
            // Task64：键无法映射到 SDL 扫描码 = 事件被静默丢弃。旧代码零日志，
            // "按键没反应"时无从分辨是控件没触发还是映射丢失。glfwKeyToSDLScancode
            // 的 default 分支返回 0（如 GLFW_KEY_UNKNOWN=0 或未覆盖的特殊键）。
            static _Atomic int s_task64DroppedKeys = 0;
            int dk = atomic_fetch_add(&s_task64DroppedKeys, 1) + 1;
            if (dk <= 20 || dk % 100 == 0) {
                NSLog(@"[InputDiag] Task64 key DROPPED (no SDL scancode mapping) #%d: glfwKey=%d action=%d -- button silently dead",
                      dk, key, action);
            }
        }
    }

    // On macOS, Minecraft expects the Command key
    if (key == GLFW_KEY_LEFT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SUPER, 0, action, mods);
    } else if (key == GLFW_KEY_RIGHT_CONTROL) {
        CallbackBridge_nativeSendKey(GLFW_KEY_RIGHT_SUPER, 0, action, mods);
    }
}

void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {
    // Path A: GLFW callbacks (older MC versions)
    if (isInputReady) {
        if (button == -1) {
        } else if (GLFW_invoke_MouseButton) {
            if (mods == 0) {
                mods = getKeyModifiers(0, action);
            }

            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_MOUSE_BUTTON, button, action, mods, 0);
            } else {
                GLFW_invoke_MouseButton((void*) showingWindow, button, action, mods);
            }
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_MouseButton && g_sdlWindow && button >= 0) {
        pushSDLMouseButton(glfwButtonToSDLButton(button), action != 0, (float)cursorX, (float)cursorY);
    }
}

void CallbackBridge_nativeSendScreenSize(int width, int height) {
    windowWidth = width;
    windowHeight = height;

    if (isInputReady) {
        if (GLFW_invoke_FramebufferSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_FRAMEBUFFER_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_FramebufferSize((void*) showingWindow, width, height);
            }
        }
        if (GLFW_invoke_WindowSize) {
            if (isUseStackQueueCall) {
                sendData(EVENT_TYPE_WINDOW_SIZE, width, height, 0, 0);
            } else {
                GLFW_invoke_WindowSize((void*) showingWindow, width, height);
            }
        }
    }

    // ---------------------------------------------------------------
    // Task 83b（SDL3 路径窗口尺寸下发，Path B）：
    //
    // 根因（zink+FSR 绿屏实锤，be276a0 装机日志）：本函数旧实现只有 GLFW
    // 回调通道——26.3 走 SDL3 时 GLFW_invoke_* 恒 NULL，且 isInputReady 全程
    // 为 0，于是"下发尺寸"实际只更新了全局变量，MC 永远不知道。osm_bridge
    // 的 FSR 兜底（EASU 编译失败时恢复窗口=表面）正是被这条路坑死：MC 继
    // 续按 1815x1261 小窗渲染，2360x1640 全尺寸 OSMesa 缓冲的未写区域 =
    // realloc 出来的未初始化堆内存直接上屏 = 用户看到的"FSR 提升部分绿
    // 色花屏"。
    //
    // 修法照 sendKey/sendChar 的 Path B 惯例：GLFW 通道不可用时推合成
    // SDL_WINDOW_RESIZED(0x207)，data1/data2 携带像素尺寸。Task61 已实证
    // MC 26.3 把 0x207 的 data1/data2 当像素窗口尺寸直接消费；sdl3_hook
    // 的 Task61 改写器会把它重写为 windowWidth×windowHeight（本函数刚写
    // 入的全局值）= 恒等，无拉锯。
    //
    // 去重：与上次下发值相同则不推（分辨率滑条拖动会高频触发本函数，
    // 相同尺寸的重推只会给 MC 塞无意义的重建风暴）。
    // ---------------------------------------------------------------
    if (!GLFW_invoke_WindowSize && !GLFW_invoke_FramebufferSize && g_sdlWindow) {
        static int s_task83b_lastW = -1, s_task83b_lastH = -1;
        if (width != s_task83b_lastW || height != s_task83b_lastH) {
            s_task83b_lastW = width;
            s_task83b_lastH = height;
            if (pSDL_PushEvent) {
                SDL3_Event ev;
                memset(&ev, 0, sizeof(ev));
                SDL3_WindowEvent *we = (SDL3_WindowEvent *)&ev;
                we->type = SDL3_EVENT_WINDOW_RESIZED;
                we->windowID = getSDLWindowID();
                we->data1 = width;
                we->data2 = height;
                pSDL_PushEvent((void *)&ev);
                static int s_task83b_pushed = 0;
                s_task83b_pushed++;
                if (s_task83b_pushed <= 10 || s_task83b_pushed % 50 == 0) {
                    NSLog(@"[InputDiag] Task83b window size -> SDL 0x207 %dx%d #%d (MC-side resize; FSR fallback now actually restores full-res)",
                          width, height, s_task83b_pushed);
                }
            }
        }
    }

    // return (isInputReady && (GLFW_invoke_FramebufferSize || GLFW_invoke_WindowSize));
}

void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset) {
    // Path A: GLFW callbacks
    if (GLFW_invoke_Scroll && isInputReady) {
        if (isUseStackQueueCall) {
            sendDataFloat(EVENT_TYPE_SCROLL, xoffset, yoffset, 0, 0);
        } else {
            GLFW_invoke_Scroll((void*) showingWindow, (double) xoffset, (double) yoffset);
        }
    }

    // Path B: SDL3 events (MC 26.3+)
    if (!GLFW_invoke_Scroll && g_sdlWindow) {
        pushSDLMouseWheel((float)xoffset, (float)yoffset);
    }
}
JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(JNIEnv* env, jclass clazz, jlong window) {
    showingWindow = (long) window;
}

void CallbackBridge_pauseGameIfNeed() {
    // ★ [FG] 上游 d76301816 同步（Task222）：切后台暂停在 26.3(SDL3) 上原是空操作。
    //   原判据只有 isGrabbing。SDL3 路径下 isGrabbing 由 SDL 的相对鼠标模式
    //   同步而来，实测恒为 0（本文件 [HotbarDiag] / pojavPumpEvents 注释原话：
    //   "isGrabbing 全程为 0，正是这条链路断了"）。于是 SceneDelegate 的
    //   sceneDidEnterBackground -> 这里什么都不做。
    //   与此同时 sdl3_hook 的 Task56 又掐掉了 SDL_EVENT_WINDOW_MINIMIZED，
    //   并把 SDL_GetWindowFlags 的 INPUT_FOCUS(0x200) 恒置 1 —— MC 因此永远
    //   以为自己在前台、有焦点、未最小化，切后台后仍按前台全速渲染，回前台时
    //   呈现链路停在半截状态（表现为卡死/黑屏）。
    //   修复：判据从"只有 isGrabbing"放宽为"输入链路已就绪"——GLFW 路径看
    //   isInputReady，SDL3 路径看 g_sdlWindow 是否已建立。isGrabbing 仍保留为
    //   充分条件（抓取中必然在游戏中）。
    BOOL liveSession = (isGrabbing || isInputReady || (g_sdlWindow != NULL));
    if (!liveSession) {
        NSLog(@"[InputDiag] pauseGameIfNeed: skipped (no live session: "
              @"isGrabbing=%d isInputReady=%d sdlWindow=%p)",
              isGrabbing, isInputReady, g_sdlWindow);
        return;
    }
    NSLog(@"[InputDiag] pauseGameIfNeed: ESC -> MC (isGrabbing=%d isInputReady=%d sdlWindow=%p)",
          isGrabbing, isInputReady, g_sdlWindow);
    CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 1, 0);
    CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 0, 0);
}

// ★ [FG] 上游 d76301816 同步（Task222）：回前台：补发一组"焦点/恢复"信号，
//   让 MC 知道自己重新可见。与上面的暂停成对：只暂停不恢复同样会让 MC 停在暂停态。
void CallbackBridge_resumeGameIfNeed(void) {
    BOOL liveSession = (isGrabbing || isInputReady || (g_sdlWindow != NULL));
    if (!liveSession) return;
    NSLog(@"[InputDiag] resumeGameIfNeed: live session (isGrabbing=%d isInputReady=%d sdlWindow=%p)",
          isGrabbing, isInputReady, g_sdlWindow);
    // 只做无害的窗口尺寸重申：SDL3/MC 收到 WINDOW_RESIZED / PIXEL_SIZE_CHANGED
    // 会重新同步 framebuffer 尺寸，是恢复呈现面最安全的一针。不合成 ESC，
    // 避免误关暂停菜单。尺寸未定（0）时绝不发，避免把 framebuffer 打成 0x0。
    if (windowWidth > 0 && windowHeight > 0) {
        CallbackBridge_nativeSendScreenSize(windowWidth, windowHeight);
    } else {
        NSLog(@"[InputDiag] resumeGameIfNeed: skip resize re-announce (size %dx%d invalid)",
              windowWidth, windowHeight);
    }

    // ===== Task224：SDL 输入能力重建（“MG 后台回来后屏幕无法输入”根修）=====
    // 装机证据（10-06 latestlog.2，Metallum/SDL 会话）：恢复后渲染健康
    // （fps=58、swapOK 持续增长）、键盘事件可达 MC（Task64 #3/#4 MC-side），
    // 但触控全无反应——sendCursorPos #50/#100/#150 持续推进（UIKit 触达
    // 且事件照常 SDL_PushEvent）。断点只能在 SDL/MC 侧输入状态：后台化时
    // SDL UIKit backend 拆了 mouse focus/内部鼠标态，恢复时无人重建。
    // 三针齐下（全部幂等无害）：
    //   1. SDL_WarpMouseInWindow（公开 API）——内部走 SDL_SendMouseMotion，
    //      把 mouse focus 重新钉到 g_sdlWindow 并同步 SDL 内部鼠标位置；
    //   2. 合成 WINDOW_MOUSE_ENTER + WINDOW_FOCUS_GAINED——SDL 焦点态的
    //      标准事件对（Task118 只改 GetWindowFlags 谎言位，MC 事件驱动的
    //      焦点状态没喂）；
    //   3. 嵌入视图 z 序 + 宿主 key window 重钉（sdl3_hook 公开包装；
    //      SDL 后台期窗口操作可能打乱 z 序，此前只有 ShowWindow 钩子修）。
    if (g_sdlWindow && pSDL_PushEvent) {
        static bool (*ame224_pWarpMouseInWindow)(void *window, float x, float y) = NULL;
        static bool ame224_warpResolved = false;
        if (!ame224_warpResolved) {
            ame224_warpResolved = true;
            ame224_pWarpMouseInWindow = (bool (*)(void *, float, float))dlsym(RTLD_DEFAULT, "SDL_WarpMouseInWindow");
        }
        if (ame224_pWarpMouseInWindow) {
            ame224_pWarpMouseInWindow(g_sdlWindow, ame51_px_to_pt((float)cursorX), ame51_px_to_pt((float)cursorY));
        }
        SDL3_WindowEvent ame224_we;
        memset(&ame224_we, 0, sizeof(ame224_we));
        ame224_we.windowID = getSDLWindowID();
        ame224_we.type = SDL3_EVENT_WINDOW_MOUSE_ENTER;
        pSDL_PushEvent(&ame224_we);
        ame224_we.type = SDL3_EVENT_WINDOW_FOCUS_GAINED;
        pSDL_PushEvent(&ame224_we);
        ame224_refrontEmbeddedViewSafe();
        NSLog(@"[InputDiag] Task224 SDL input re-established on resume (warp=%d mouseEnter+focusGained pushed windowID=%u cursor=%ld,%ld)",
              ame224_pWarpMouseInWindow ? 1 : 0, (unsigned)getSDLWindowID(), (long)cursorX, (long)cursorY);
    }
}

// JNI bridge: MC 26.1/26.2 use LWJGL 3.4.1 Java bindings which declare
// native method "nsetupEnvData" (with "n" prefix), but the prebuilt
// liblwjgl.dylib built from 3.4.1 sources exports "setupEnvData"
// (without "n" prefix) — 3.4.1 dropped the "n" on the C side only.
// This function bridges the name mismatch by forwarding to the real
// implementation.
JNIEXPORT jlong JNICALL Java_org_lwjgl_system_ThreadLocalUtil_nsetupEnvData(
    JNIEnv *env, jclass clazz, jint functionCount) {
    typedef jlong (*SetupEnvDataFunc)(JNIEnv*, jclass, jint);
    static SetupEnvDataFunc realFunc = NULL;
    static bool resolved = false;
    if (!resolved) {
        realFunc = (SetupEnvDataFunc)dlsym(RTLD_DEFAULT,
            "Java_org_lwjgl_system_ThreadLocalUtil_setupEnvData");
        resolved = true;
        if (!realFunc) {
            NSLog(@"[LWJGL Bridge] nsetupEnvData: setupEnvData not found in loaded libraries!");
        }
    }
    if (realFunc) {
        return realFunc(env, clazz, functionCount);
    }
    NSLog(@"[LWJGL Bridge] nsetupEnvData: FATAL - no implementation found");
    return 0;
}
