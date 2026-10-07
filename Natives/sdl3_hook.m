// sdl3_hook.m — SDL3 兼容层，移植自 ZalithLauncher2 的
// ZalithLauncher/src/main/jni/sdl_hook.c（Android 端，基于 bytehook）。
//
// iOS 上没有 bytehook，等价机制是 main_hook.m 里 fishhook 住的 dlsym
// （hooked_dlsym）。LWJGL 通过 dlsym 取 SDL 函数指针后直接调用，不走
// __la_symbol_ptr，所以必须在 dlsym 层拦 —— 这和 SDL_SetWindowMouseGrab
// 用的是同一条路子。SDL 内部调用自己的函数不经过 dlsym，因此不会被误伤。
//
// 解决的问题（均与 MC 26.x 的 RenderPearl 相关）：
//
// 1. 移动渲染器都是 OpenGL ES 实现，而 MC 按桌面 GL 惯例初始化 SDL，
//    非 ES 的 profile 请求会被宿主拒绝。建窗前强制切到 ES profile。
//
// 2. MC 26.3 ss9+ 在设备初始化时先建一个隐藏工具窗口（GL 上下文依附其上），
//    随后主窗口创建被拒；销毁工具窗口又会使其上的 GL surface 失效。
//    故把后续建窗请求重定向到首个窗口。
//
// 3. MC 26.3 要求 SDL 与 LWJGL 使用同一 Vulkan 加载器实例（校验
//    vkGetInstanceProcAddr 指针一致），而 SDL 只能按路径加载。若启动器已
//    持有句柄（记录在环境变量里），SDL 加载 libvulkan 时把该句柄还回去。
//
// 4. EGL 代理：eglChooseConfig / eglCreateContext 首选请求失败后做兼容
//    重试（RENDERABLE_TYPE 归一化、剔除 KHR 版本属性、CV=2 兜底）。
//
// 全部行为可用环境变量关闭，默认只在对移动 ES 渲染器时生效：
//   AMETHYST_SDL_GLES_COMPAT=0    关闭 ES profile 强制与 EGL 代理
//   AMETHYST_SDL_REUSE_WINDOW=0   关闭主窗口复用
//   AMETHYST_VULKAN_PTR=<hex>     启用 SDL_LoadObject 句柄共享

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "utils.h"

#include <dlfcn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>   // strcasecmp
#include <sys/types.h>
#include <objc/runtime.h>
// Task 132：libjnidispatch GOT 重绑定所需的 Mach-O 遍历头（与
// dyld_patch_platform.m 同款集合；vm_protect 经 <mach/mach.h>）
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <unistd.h>
// Task 133：JVM 链重绑定需要 main_hook.m 的钩子与原函数指针 + 互斥锁
#include <pthread.h>
extern void *hooked_dlopen(const char *path, int mode);
extern void *hooked_dlsym(void *handle, const char *name);
extern void *(*orig_dlopen)(const char *path, int mode);
// Task 135：_dlsym 槽重绑定通道需要（CI 35512461717 教训：跨 TU 引用先声明）
extern void *(*orig_dlsym)(void *handle, const char *name);

#pragma mark - SDL3 常量（与 SDL_video.h 对齐，避免依赖 SDL 头文件）

// SDL_GLAttr：从 0 开始顺序计数，CONTEXT_PROFILE_MASK 是第 21 个
#define AME_SDL_GL_CONTEXT_PROFILE_MASK 20
// SDL_GLProfile
#define AME_SDL_GL_CONTEXT_PROFILE_ES 0x0004

#pragma mark - EGL 常量（自给自足，不依赖 EGL 头文件是否存在）

#define AME_EGL_NONE 0x3038
#define AME_EGL_RENDERABLE_TYPE 0x3040
#define AME_EGL_OPENGL_ES_BIT 0x0001
#define AME_EGL_OPENGL_ES2_BIT 0x0004
#define AME_EGL_OPENGL_ES3_BIT 0x0040
#define AME_EGL_OPENGL_BIT 0x0008
// 注意：EGL_CONTEXT_MAJOR_VERSION 与 EGL_CONTEXT_CLIENT_VERSION 同为 0x3098，
// 这是 EGL 的历史遗留（ZL2 代码里也是这个值）。
#define AME_EGL_CONTEXT_CLIENT_VERSION 0x3098
#define AME_EGL_CONTEXT_MAJOR_VERSION_KHR 0x3098
#define AME_EGL_CONTEXT_MINOR_VERSION_KHR 0x30FB

#pragma mark - 真实 SDL 函数指针

// SDL3 里 bool 就是 C99 _Bool（1 字节），这里用 int 做 ABI 安全的返回类型，
// 只取其"非零即成功"的语义，避免与 Objective-C 的 BOOL 混淆。
typedef bool (*ame_fn_SDL_GL_SetAttribute)(int attr, int value);
typedef void *(*ame_fn_SDL_CreateWindow)(const char *title, int w, int h, uint32_t flags);
typedef void *(*ame_fn_SDL_CreateWindowWithProperties)(uint32_t props);
typedef void (*ame_fn_SDL_DestroyWindow)(void *window);
typedef void *(*ame_fn_SDL_LoadFunction)(void *handle, const char *name);
typedef void *(*ame_fn_SDL_EGL_GetProcAddress)(const char *proc);
typedef void *(*ame_fn_SDL_LoadObject)(const char *path);
typedef void (*ame_fn_SDL_UnloadObject)(void *handle);

// SDL3 GL 入口（被接管后转交启动器 EGL bridge）
typedef bool (*ame_fn_SDL_GL_LoadLibrary)(const char *path);
typedef void *(*ame_fn_SDL_GL_CreateContext)(void *window);
typedef bool (*ame_fn_SDL_GL_MakeCurrent)(void *window, void *context);
typedef bool (*ame_fn_SDL_GL_SwapWindow)(void *window);
typedef void *(*ame_fn_SDL_GL_GetProcAddress)(const char *proc);
typedef bool (*ame_fn_SDL_GL_SetSwapInterval)(int interval);
typedef bool (*ame_fn_SDL_GL_DestroyContext)(void *context);
typedef void *(*ame_fn_SDL_GL_GetCurrentContext)(void);

// ============================================================================
// 黑屏取证（Task 32）：窗口生命周期 + 事件泵钩子（全部透传 + 日志，零行为改动）
//
// 动机：MC 26.3 设备实测（latestlog b199c07）游戏完整启动但黑屏、约 20 秒后
// exit(0) 干净退出。现有日志看不出：
//   a) MC 何时对（复用的）SDL 窗口调用 ShowWindow/SetWindowSize —— 若真实
//      SDL UIKit 窗口被显示，它会不会盖住 SurfaceVC 的 CAMetalLayer；
//   b) MC 的事件泵到底收到了什么 —— 尤其触发干净退出的 QUIT /
//      WINDOW_CLOSE_REQUESTED 事件从何而来（用户只按了 7 次 ESC，推给 SDL
//      的都是 KEY_DOWN/UP + MOUSE_MOTION，正常不足以退游戏）。
// 这些钩子只记录、不改变任何行为，一次设备日志即可回答上述问题。
// ============================================================================
typedef bool (*ame_fn_SDL_ShowWindow)(void *window);
typedef bool (*ame_fn_SDL_HideWindow)(void *window);
typedef bool (*ame_fn_SDL_SetWindowSize)(void *window, int w, int h);
typedef bool (*ame_fn_SDL_SetWindowPosition)(void *window, int x, int y);
typedef bool (*ame_fn_SDL_SetWindowFullscreen)(void *window, bool fullscreen);
typedef bool (*ame_fn_SDL_PollEvent)(void *event);
// Task 50：SDL_WindowFlags 是 Uint32（SDL_video.h）
typedef unsigned int (*ame_fn_SDL_GetWindowFlags)(void *window);
// Task 65：SDL_GetWindowFromEvent（SDL_events.h：const SDL_Event* -> SDL_Window*）
typedef void *(*ame_fn_SDL_GetWindowFromEvent)(const void *event);
// Task 61：SDL3 尺寸查询（SDL_video.h：返回 bool，出参 int*）
typedef bool (*ame_fn_SDL_GetWindowSize)(void *window, int *w, int *h);
typedef bool (*ame_fn_SDL_GetWindowSizeInPixels)(void *window, int *w, int *h);
// Task 67：SDL_GetKeyboardState（SDL_keyboard.h：const bool *SDL_GetKeyboardState(int *numkeys)）
// MC 的 InputConstants.isKeyDown/setAll/hasShiftDown 全部经此口轮询键盘态。
typedef const bool *(*ame_fn_SDL_GetKeyboardState)(int *numkeys);

// Task 114：文本输入族——SDL 的 iOS 后端在这些入口里直接操作 UIKit
//（-[SDL_uikitviewcontroller setTextFieldProperties:] 等），而 MC 从渲染线程
// 调用它们，必须主线程化（见 ame_dispatchTextInputToMain 处的完整说明）。
typedef bool (*ame_fn_SDL_StartTextInput)(void *window);
typedef bool (*ame_fn_SDL_StartTextInputWithProperties)(void *window,
                                                        unsigned long long props);
typedef bool (*ame_fn_SDL_StopTextInput)(void *window);
typedef bool (*ame_fn_SDL_SetTextInputArea)(void *window, const void *rect, int cursor);
typedef bool (*ame_fn_SDL_OpenURL)(const char *url);   // Task227：SDL 原生开 URL（MC 26.3 Blaze3D.openUri 走这里）
// Task 114：子系统初始化——SDL hint 必须在 SDL_Init 之前设置才生效，
// 挂在 InitSubSystem 上、调用原函数之前设置（对齐上游 caf6822 实测有效的做法）。
typedef bool (*ame_fn_SDL_InitSubSystem)(uint32_t flags);
typedef bool (*ame_fn_SDL_SetHint)(const char *name, const char *value);

// SDL3 的 SDL_Rect：{ float x, float y, float w, float h; }
typedef struct { float x, y, w, h; } ame_SDLRect;

static ame_fn_SDL_GL_SetAttribute ame_real_GL_SetAttribute = NULL;
static ame_fn_SDL_CreateWindow ame_real_CreateWindow = NULL;
static ame_fn_SDL_CreateWindowWithProperties ame_real_CreateWindowWithProperties = NULL;
static ame_fn_SDL_DestroyWindow ame_real_DestroyWindow = NULL;
static ame_fn_SDL_LoadFunction ame_real_LoadFunction = NULL;
static ame_fn_SDL_EGL_GetProcAddress ame_real_EGL_GetProcAddress = NULL;
static ame_fn_SDL_LoadObject ame_real_LoadObject = NULL;
static ame_fn_SDL_UnloadObject ame_real_UnloadObject = NULL;

static ame_fn_SDL_GL_LoadLibrary ame_real_GL_LoadLibrary = NULL;
static ame_fn_SDL_GL_CreateContext ame_real_GL_CreateContext = NULL;
static ame_fn_SDL_GL_MakeCurrent ame_real_GL_MakeCurrent = NULL;
static ame_fn_SDL_GL_SwapWindow ame_real_GL_SwapWindow = NULL;
static ame_fn_SDL_GL_GetProcAddress ame_real_GL_GetProcAddress = NULL;
static ame_fn_SDL_GL_SetSwapInterval ame_real_GL_SetSwapInterval = NULL;
static ame_fn_SDL_GL_DestroyContext ame_real_GL_DestroyContext = NULL;
static ame_fn_SDL_GL_GetCurrentContext ame_real_GL_GetCurrentContext = NULL;

// Task 32 窗口生命周期 / 事件泵钩子对应的真实函数指针
static ame_fn_SDL_ShowWindow ame_real_ShowWindow = NULL;
static ame_fn_SDL_HideWindow ame_real_HideWindow = NULL;
static ame_fn_SDL_SetWindowSize ame_real_SetWindowSize = NULL;
static ame_fn_SDL_SetWindowPosition ame_real_SetWindowPosition = NULL;
static ame_fn_SDL_SetWindowFullscreen ame_real_SetWindowFullscreen = NULL;
static ame_fn_SDL_PollEvent ame_real_PollEvent = NULL;
static ame_fn_SDL_GetWindowFlags ame_real_GetWindowFlags = NULL;
// Task 65：键盘事件窗口句柄解析救援（实现见 5) 节）
static ame_fn_SDL_GetWindowFromEvent ame_real_GetWindowFromEvent = NULL;
static ame_fn_SDL_GetWindowSize ame_real_GetWindowSize = NULL;
static ame_fn_SDL_GetWindowSizeInPixels ame_real_GetWindowSizeInPixels = NULL;
// Task 67：键盘状态数组轮询钩子（实现见 5) 节 Task67 块）
static ame_fn_SDL_GetKeyboardState ame_real_GetKeyboardState = NULL;
// Task 114：文本输入主线程化 + 启动器 hint（实现见 ame_dispatchTextInputToMain 节）
static ame_fn_SDL_StartTextInput ame_real_StartTextInput = NULL;
static ame_fn_SDL_StartTextInputWithProperties ame_real_StartTextInputWithProperties = NULL;
static ame_fn_SDL_StopTextInput ame_real_StopTextInput = NULL;
static ame_fn_SDL_SetTextInputArea ame_real_SetTextInputArea = NULL;
static ame_fn_SDL_OpenURL ame_real_OpenURL = NULL;   // Task227
// Task227 CI r1 修复：hook 分发表（前部）先于函数定义（后部）引用——补前置声明。
static bool ame_SDL_OpenURL(const char *url);
static ame_fn_SDL_InitSubSystem ame_real_InitSubSystem = NULL;
static ame_fn_SDL_SetHint ame_real_SetHint = NULL;

// Task 32 embed：嵌入宿主层级的 SDL 视图（主线程赋值；定义见 "7) Amethyst embed" 一节）
static UIView *ame_embeddedSDLView = NULL;

#pragma mark - EGL 真实函数（首次解析后固定，避免跨 loader 调用）

typedef int (*ame_fn_eglChooseConfig)(void *dpy, const int *attrib_list, void **configs,
                                      int config_size, int *num_config);
typedef void *(*ame_fn_eglCreateContext)(void *dpy, void *config, void *share,
                                         const int *attrib_list);
typedef int (*ame_fn_eglSwapBuffers)(void *dpy, void *surface);

static ame_fn_eglChooseConfig ame_orig_eglChooseConfig = NULL;
static ame_fn_eglCreateContext ame_orig_eglCreateContext = NULL;
static ame_fn_eglSwapBuffers ame_orig_eglSwapBuffers = NULL;

#pragma mark - 外部依赖

// main_hook.m 提供的"绕过 hook"的 dlsym，避免本文件内解析 SDL 符号时
// 又绕回 hooked_dlsym 造成递归。
extern void *amethyst_orig_dlsym(void *handle, const char *name);

static void *ame_real_dlsym(const char *name) {
    if (amethyst_orig_dlsym) {
        void *p = amethyst_orig_dlsym(RTLD_DEFAULT, name);
        if (p != NULL) return p;
    }
    return dlsym(RTLD_DEFAULT, name);
}

#pragma mark - 渲染器分类

static bool ame_envFlagOn(const char *name, bool defaultValue) {
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') return defaultValue;
    return !(strcmp(v, "0") == 0 || strcasecmp(v, "false") == 0 ||
             strcasecmp(v, "no") == 0 || strcasecmp(v, "off") == 0);
}

// 启动器把 EGL 库路径放在 POJAVEXEC_EGL（Android 传统），iOS 侧沿用
// AMETHYST_RENDERER。两个都查，保持与 ZL2 语义一致。
static bool ame_isMobileGluesEgl(void) {
    const char *egl = getenv("POJAVEXEC_EGL");
    if (egl == NULL) return false;
    const char *base = strrchr(egl, '/');
    base = (base != NULL) ? base + 1 : egl;
    return strstr(base, "mobileglues") != NULL;
}

// GLES 兼容层（强制 ES profile、EGL 重试）只对移动 ES 渲染器生效，
// 桌面 / OSMesa 路径不得被 ES 化 —— 否则 zink 会被错误处理。
static bool ame_sdlGlesCompatEnabled(void) {
    if (!ame_envFlagOn("AMETHYST_SDL_GLES_COMPAT", true)) return false;

    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return ame_isMobileGluesEgl();

    if (strstr(renderer, "desktopgl") != NULL) return false;
    if (strncmp(renderer, "gallium_", 8) == 0) return false;      // OSMesa 系
    if (strncmp(renderer, "libOSMesa", 9) == 0) return false;     // zink（含版本号）
    if (strcmp(renderer, "vulkan_zink") == 0) return false;       // zink
    if (strstr(renderer, "libMoltenVK") != NULL) return false;    // 原生 Vulkan
    if (strncmp(renderer, "opengles", 8) == 0) return true;       // 内置 GL4ES
    if (strstr(renderer, "libMobileGL") != NULL) return true;     // MobileGL 双后端
    // MobileGlues：iOS 的 dylib 名是全小写（RENDERER_NAME_MOBILEGLUES =
    // "libmobileglues.dylib"），上面 "libMobileGL" 是大小写敏感的 strstr，
    // 对它不命中。26.3 实测（构建 f6adca3）：此函数因此对 MG 返回 false，
    // ES profile 强制与主窗口复用全部未启用 —— 第二个 SDL_CreateWindow 被
    // SDL UIKit 后端以 "Only one window allowed per display." 拒绝（SDL3.4.0
    // SDL_uikitwindow.m：iOS 每个显示器只允许一个窗口），MC 抛
    // "Failed to create window" 崩溃。故必须显式识别小写名字。
    if (strstr(renderer, "mobileglues") != NULL) return true;     // MobileGlues
    if (strstr(renderer, "libmithril") != NULL) return true;      // Mithril
    return ame_isMobileGluesEgl();                                // POJAVEXEC_EGL 兜底
}

#pragma mark - 1) 强制 ES profile

static bool ame_forcedEsProfile = false;

static void ame_forceEglProfileEs(void) {
    if (!ame_sdlGlesCompatEnabled()) return;
    if (ame_real_GL_SetAttribute == NULL) {
        ame_real_GL_SetAttribute = (ame_fn_SDL_GL_SetAttribute)ame_real_dlsym("SDL_GL_SetAttribute");
    }
    if (ame_real_GL_SetAttribute != NULL) {
        ame_real_GL_SetAttribute(AME_SDL_GL_CONTEXT_PROFILE_MASK, AME_SDL_GL_CONTEXT_PROFILE_ES);
        ame_forcedEsProfile = true;
        NSDebugLog(@"[SDLHook] forced SDL_GL_CONTEXT_PROFILE_MASK = ES");
    } else {
        NSDebugLog(@"[SDLHook] SDL_GL_SetAttribute unresolved, cannot force ES profile");
    }
}

#pragma mark - 2) 主窗口复用

static void *ame_primaryWindow = NULL;
static unsigned int ame_primaryWindowRefs = 0;

// 前置声明：实现在第 4 节 "SDL GL bridge"（Task 79）。此处只需它的布尔结果。
static bool ame_glBridgeEnabled(void);

static bool ame_shouldReusePrimaryWindow(void) {
    // 移动 ES 渲染器（MobileGlues / GL4ES / Mithril / MobileGL）——原有判定。
    if (ame_sdlGlesCompatEnabled()) {
        return ame_envFlagOn("AMETHYST_SDL_REUSE_WINDOW", true);
    }
    // Task 80：GL bridge 接管的渲染器（zink / libOSMesa / gallium_* / vulkan_zink，
    // 以及 gl4es / ltw 等 EGL 转译层）同样必须复用主窗口。
    //
    // 设备证据（0441401，用户上报“zink 在 26.3 仍回退”）：Task 79 的 provider-mirror
    // 让 LoadLibrary / CreateContext / MakeCurrent 全部通过（log 实锤 zink 上下文
    // 创建成功、MoltenVK 1.4.2 Vulkan 1.4.357 初始化），但 26.3 renderpearl 的
    // GlDevice 构造器随后创建第二个 "Hidden Test Window" 探针（创建后立即销毁，
    // 仅用于验证 GL 环境健康）——iOS UIKit 后端每个显示器只允许一个窗口，
    // 真实 SDL_CreateWindow 返回 NULL → BackendCreationException: "Failed to
    // create window for OpenGL after creating context" → 回退原生 Vulkan，
    // ZinkConfig / stride fix / shaderc 缓存全部空转。
    //
    // MobileGlues 路径早已靠复用迈过这道门（0cc265f 实证：reusing primary
    // window, refs=2 → DestroyWindow skipped, refs=1 → Using graphics backend
    // OpenGL）。zink 呈现走 osm_swap_buffers → SurfaceViewController.surface.layer，
    // 不依赖任何 SDL 窗口，复用无副作用；引丹计数（refs）天然消化探针窗口的
    // 立即销毁。逃生阀不变：AMETHYST_ZINK_GL_BRIDGE=0 → glBridgeEnabled 对 zink
    // 返回 false → 复用同步关闭，回到 Task 79 之前的旧行为。
    if (ame_glBridgeEnabled()) {
        return ame_envFlagOn("AMETHYST_SDL_REUSE_WINDOW", true);
    }
    return false;
}

#pragma mark - 3) EGL 兼容重试

// RENDERABLE_TYPE 归一化为 ES2_BIT：宿主若不支持请求的 ES3/桌面 GL 位，
// 退回 ES2 至少能拿到一个可用 config。
static int ame_normalizeEglChooseConfigList(const int *attrib_list, int *fixed, int cap) {
    if (attrib_list == NULL) return 0;
    int n = 0;
    for (int i = 0; n < cap - 2; i += 2) {
        int attr = attrib_list[i];
        int val = attrib_list[i + 1];
        if (attr == AME_EGL_NONE) {
            fixed[n] = AME_EGL_NONE;
            fixed[n + 1] = 0;
            n += 2;
            break;
        }
        if (attr == AME_EGL_RENDERABLE_TYPE) {
            if ((val & (AME_EGL_OPENGL_ES3_BIT | AME_EGL_OPENGL_BIT)) != 0 &&
                (val & AME_EGL_OPENGL_ES2_BIT) == 0) {
                val = (val & ~(AME_EGL_OPENGL_ES3_BIT | AME_EGL_OPENGL_BIT)) |
                      AME_EGL_OPENGL_ES2_BIT;
            }
        }
        fixed[n] = attr;
        fixed[n + 1] = val;
        n += 2;
    }
    return n > 0;
}

// 剔除宿主不识别的 KHR 版本属性，生成兼容重试表；返回请求的主版本号（无则 0）
static int ame_normalizeEglContextAttribs(const int *attrib_list, int *fixed, int cap,
                                          bool esSemantics) {
    int version = 0;
    bool hasClientVersion = false;
    if (attrib_list == NULL) return 0;
    int n = 0;
    for (int i = 0; n < cap - 2; i += 2) {
        int attr = attrib_list[i];
        int val = attrib_list[i + 1];
        if (attr == AME_EGL_NONE) break;
        if (attr == AME_EGL_CONTEXT_MAJOR_VERSION_KHR) {  // 记录主版本后剔除
            if (version == 0) version = val;
            continue;
        }
        if (attr == AME_EGL_CONTEXT_MINOR_VERSION_KHR) continue;
        if (attr == AME_EGL_CONTEXT_CLIENT_VERSION) {
            hasClientVersion = true;
            if (version == 0) version = val;
        }
        if (n >= cap - 2) return 0;
        fixed[n++] = attr;
        fixed[n++] = val;
    }
    // 仅 ES 语义下补写 CLIENT_VERSION（避免退化成驱动默认版本）；
    // desktop 语义不补写 —— 桌面 context 不使用 CLIENT_VERSION
    if (esSemantics && version > 0 && !hasClientVersion) {
        if (n >= cap - 2) return 0;
        fixed[n++] = AME_EGL_CONTEXT_CLIENT_VERSION;
        fixed[n++] = version;
    }
    if (n >= cap - 2) return 0;
    fixed[n++] = AME_EGL_NONE;
    fixed[n++] = 0;
    return version;
}

static void *ame_proxyEglCreateContext(void *dpy, void *config, void *share,
                                       const int *attrib_list) {
    if (ame_orig_eglCreateContext == NULL) {
        NSDebugLog(@"[SDLHook] eglCreateContext was not resolved");
        return NULL;
    }

    void *ctx = ame_orig_eglCreateContext(dpy, config, share, attrib_list);
    if (ctx != NULL || !ame_sdlGlesCompatEnabled()) return ctx;

    bool esSemantics = ame_forcedEsProfile;
    int fixed[64];
    int version = ame_normalizeEglContextAttribs(attrib_list, fixed, 64, esSemantics);
    if (version == 0) return ctx;

    NSDebugLog(@"[SDLHook] retrying eglCreateContext without KHR version attrs (CV=%d)", version);
    ctx = ame_orig_eglCreateContext(dpy, config, share, fixed);
    if (ctx != NULL || !esSemantics || version <= 2) return ctx;  // CV=2 为移动端最后兜底

    NSDebugLog(@"[SDLHook] retrying eglCreateContext with CV=2 after CV=%d failed", version);
    int es2[3] = {AME_EGL_CONTEXT_CLIENT_VERSION, 2, AME_EGL_NONE};
    return ame_orig_eglCreateContext(dpy, config, share, es2);
}

static int ame_proxyEglChooseConfig(void *dpy, const int *attrib_list, void **configs,
                                    int config_size, int *num_config) {
    if (ame_orig_eglChooseConfig == NULL) {
        NSDebugLog(@"[SDLHook] eglChooseConfig was not resolved");
        return 0;
    }

    int result = ame_orig_eglChooseConfig(dpy, attrib_list, configs, config_size, num_config);
    if (result && num_config != NULL && *num_config > 0) return result;
    if (!ame_sdlGlesCompatEnabled()) return result;  // 兼容 fallback 仅限移动 ES 渲染器

    int fixed[64];
    if (!ame_normalizeEglChooseConfigList(attrib_list, fixed, 64)) return result;
    int fallbackCount = 0;
    int fallbackResult = ame_orig_eglChooseConfig(dpy, fixed, configs, config_size, &fallbackCount);
    if (fallbackResult && num_config != NULL) *num_config = fallbackCount;
    NSDebugLog(@"[SDLHook] eglChooseConfig fallback result=%d count=%d",
               fallbackResult, fallbackCount);
    return fallbackResult;
}

static int ame_proxyEglSwapBuffers(void *dpy, void *surface) {
    if (ame_orig_eglSwapBuffers == NULL) {
        NSDebugLog(@"[SDLHook] eglSwapBuffers was not resolved");
        return 0;
    }
    return ame_orig_eglSwapBuffers(dpy, surface);
}

// 把原始指针换成代理。orig 为 NULL 时不覆盖（ZL2 语义：首次解析后固定）。
static void ame_maybeWrapEgl(const char *name, void **out) {
    if (name == NULL || *out == NULL) return;
    if (strcmp(name, "eglChooseConfig") == 0) {
        if (ame_orig_eglChooseConfig == NULL) ame_orig_eglChooseConfig = (ame_fn_eglChooseConfig)*out;
        if (*out != (void *)ame_proxyEglChooseConfig) *out = (void *)ame_proxyEglChooseConfig;
    } else if (strcmp(name, "eglCreateContext") == 0) {
        if (ame_orig_eglCreateContext == NULL) ame_orig_eglCreateContext = (ame_fn_eglCreateContext)*out;
        if (*out != (void *)ame_proxyEglCreateContext) *out = (void *)ame_proxyEglCreateContext;
    } else if (strcmp(name, "eglSwapBuffers") == 0) {
        if (ame_orig_eglSwapBuffers == NULL) ame_orig_eglSwapBuffers = (ame_fn_eglSwapBuffers)*out;
        if (*out != (void *)ame_proxyEglSwapBuffers) *out = (void *)ame_proxyEglSwapBuffers;
    }
}

#pragma mark - SDL 函数包装

// Task 32 embed 前置声明（实现在文件后部 "7) Amethyst embed" 一节）
static bool ame_embedSDLViewIntoHost(void);
static void ame_refrontEmbeddedViewOnMain(void);

// Task 32 窗口生命周期/事件泵钩子前置声明（实现在 "6) 窗口生命周期" 一节；
// 供 ame_maybeWrapWindowHook（SDL_LoadFunction 解析路径）引用）
static bool ame_SDL_ShowWindow(void *window);
static bool ame_SDL_HideWindow(void *window);
static bool ame_SDL_SetWindowSize(void *window, int w, int h);
static bool ame_SDL_SetWindowPosition(void *window, int x, int y);
static bool ame_SDL_SetWindowFullscreen(void *window, bool fullscreen);
static bool ame_SDL_PollEvent(void *event);
static unsigned int ame_SDL_GetWindowFlags(void *window);   // Task 50（实现见 5) 节，供 maybeWrapWindowHook 前向引用）
static void *ame_SDL_GetWindowFromEvent(const void *event); // Task 65（实现见 5) 节，键盘句柄解析救援）
static bool ame_SDL_GetWindowSize(void *window, int *w, int *h);            // Task 61（实现见 5) 节）
static bool ame_SDL_GetWindowSizeInPixels(void *window, int *w, int *h);   // Task 61（实现见 5) 节）
static const bool *ame_SDL_GetKeyboardState(int *numkeys);                  // Task 67（实现见 5) 节）
// Task 114：文本输入主线程化 + 启动器 hint（实现见 ame_dispatchTextInputToMain 节）
static bool ame_SDL_StartTextInput(void *window);
static bool ame_SDL_StartTextInputWithProperties(void *window, unsigned long long props);
static bool ame_SDL_StopTextInput(void *window);
static bool ame_SDL_SetTextInputArea(void *window, const void *rect, int cursor);
static bool ame_SDL_InitSubSystem(uint32_t flags);
// Task 131：SDL 事件回调入口拦截（JNA closure 不可执行防御，实现见
// ame_SDL_SetEventFilter 节）
static bool ame_SDL_SetEventFilter(void *filter, void *userdata);
static void ame_SDL_AddEventWatch(void *filter, void *userdata);

// Task 32：当 MC 通过 SDL_LoadFunction（而非 dlsym）解析符号时，同样把
// 窗口生命周期/事件泵钩子装上（防御性双路覆盖，与 amethyst_sdl3_hook_resolve
// 一致；设备实测 MC 走 dlsym 路径，但保留此路径防未来变化）。
static void ame_maybeWrapWindowHook(const char *name, void **out) {
    if (name == NULL || out == NULL || *out == NULL) return;
    if (strcmp(name, "SDL_ShowWindow") == 0) {
        if (ame_real_ShowWindow == NULL)
            ame_real_ShowWindow = (ame_fn_SDL_ShowWindow)*out;
        *out = (void *)ame_SDL_ShowWindow;
    } else if (strcmp(name, "SDL_HideWindow") == 0) {
        if (ame_real_HideWindow == NULL)
            ame_real_HideWindow = (ame_fn_SDL_HideWindow)*out;
        *out = (void *)ame_SDL_HideWindow;
    } else if (strcmp(name, "SDL_SetWindowSize") == 0) {
        if (ame_real_SetWindowSize == NULL)
            ame_real_SetWindowSize = (ame_fn_SDL_SetWindowSize)*out;
        *out = (void *)ame_SDL_SetWindowSize;
    } else if (strcmp(name, "SDL_SetWindowPosition") == 0) {
        if (ame_real_SetWindowPosition == NULL)
            ame_real_SetWindowPosition = (ame_fn_SDL_SetWindowPosition)*out;
        *out = (void *)ame_SDL_SetWindowPosition;
    } else if (strcmp(name, "SDL_SetWindowFullscreen") == 0) {
        if (ame_real_SetWindowFullscreen == NULL)
            ame_real_SetWindowFullscreen = (ame_fn_SDL_SetWindowFullscreen)*out;
        *out = (void *)ame_SDL_SetWindowFullscreen;
    } else if (strcmp(name, "SDL_PollEvent") == 0) {
        if (ame_real_PollEvent == NULL)
            ame_real_PollEvent = (ame_fn_SDL_PollEvent)*out;
        *out = (void *)ame_SDL_PollEvent;
    } else if (strcmp(name, "SDL_GetWindowFlags") == 0) {
        if (ame_real_GetWindowFlags == NULL)
            ame_real_GetWindowFlags = (ame_fn_SDL_GetWindowFlags)*out;
        *out = (void *)ame_SDL_GetWindowFlags;
    } else if (strcmp(name, "SDL_GetWindowFromEvent") == 0) {
        // Task 65：键盘事件窗口句柄解析救援（NULL 回落主窗口）
        if (ame_real_GetWindowFromEvent == NULL)
            ame_real_GetWindowFromEvent = (ame_fn_SDL_GetWindowFromEvent)*out;
        *out = (void *)ame_SDL_GetWindowFromEvent;
    } else if (strcmp(name, "SDL_GetWindowSize") == 0) {
        if (ame_real_GetWindowSize == NULL)
            ame_real_GetWindowSize = (ame_fn_SDL_GetWindowSize)*out;
        *out = (void *)ame_SDL_GetWindowSize;
    } else if (strcmp(name, "SDL_GetWindowSizeInPixels") == 0) {
        if (ame_real_GetWindowSizeInPixels == NULL)
            ame_real_GetWindowSizeInPixels = (ame_fn_SDL_GetWindowSizeInPixels)*out;
        *out = (void *)ame_SDL_GetWindowSizeInPixels;
    } else if (strcmp(name, "SDL_GetKeyboardState") == 0) {
        // Task 67：MC 键盘态轮询口观测（指针对证 + 关键键位值采样）
        if (ame_real_GetKeyboardState == NULL)
            ame_real_GetKeyboardState = (ame_fn_SDL_GetKeyboardState)*out;
        *out = (void *)ame_SDL_GetKeyboardState;
    } else if (strcmp(name, "SDL_StartTextInput") == 0) {
        // Task 114：文本输入主线程化（键盘自动弹出修复）
        if (ame_real_StartTextInput == NULL)
            ame_real_StartTextInput = (ame_fn_SDL_StartTextInput)*out;
        *out = (void *)ame_SDL_StartTextInput;
    } else if (strcmp(name, "SDL_StartTextInputWithProperties") == 0) {
        // Task 114：同上（带属性版，MC 26.x 走 SDL3 时实际调用的是这个入口）
        if (ame_real_StartTextInputWithProperties == NULL)
            ame_real_StartTextInputWithProperties = (ame_fn_SDL_StartTextInputWithProperties)*out;
        *out = (void *)ame_SDL_StartTextInputWithProperties;
    } else if (strcmp(name, "SDL_StopTextInput") == 0) {
        // Task 114：停止文本输入（收起键盘）同样需要主线程化
        if (ame_real_StopTextInput == NULL)
            ame_real_StopTextInput = (ame_fn_SDL_StopTextInput)*out;
        *out = (void *)ame_SDL_StopTextInput;
    } else if (strcmp(name, "SDL_SetTextInputArea") == 0) {
        // Task 114：输入框区域上报（软键盘避让），rect 栈上持有需堆拷贝
        if (ame_real_SetTextInputArea == NULL)
            ame_real_SetTextInputArea = (ame_fn_SDL_SetTextInputArea)*out;
        *out = (void *)ame_SDL_SetTextInputArea;
    } else if (strcmp(name, "SDL_OpenURL") == 0) {
        // ★ Task227：MC 26.3 打开文件夹/链接的真正入口（非 AWT/CTC 链）。
        if (ame_real_OpenURL == NULL)
            ame_real_OpenURL = (ame_fn_SDL_OpenURL)*out;
        *out = (void *)ame_SDL_OpenURL;
    } else if (strcmp(name, "SDL_InitSubSystem") == 0) {
        // Task 114：SDL hint 注入点（必须在真实初始化前设置）
        if (ame_real_InitSubSystem == NULL)
            ame_real_InitSubSystem = (ame_fn_SDL_InitSubSystem)*out;
        *out = (void *)ame_SDL_InitSubSystem;
    }
}

static void *ame_SDL_CreateWindow(const char *title, int w, int h, uint32_t flags) {
    ame_forceEglProfileEs();
    NSDebugLog(@"[SDLHook] SDL_CreateWindow title=%s %dx%d flags=0x%x",
               title ? title : "(null)", w, h, flags);
    bool reuse = ame_shouldReusePrimaryWindow();
    if (reuse && ame_primaryWindow != NULL) {
        ame_primaryWindowRefs++;
        NSDebugLog(@"[SDLHook] reusing primary window %p, refs=%u",
                   ame_primaryWindow, ame_primaryWindowRefs);
        return ame_primaryWindow;
    }
    void *wnd = ame_real_CreateWindow ? ame_real_CreateWindow(title, w, h, flags) : NULL;
    if (reuse && wnd != NULL) {
        ame_primaryWindow = wnd;
        ame_primaryWindowRefs = 1;
        // Task 32 黑屏修复：首个真实 SDL 窗口创建成功后立即执行 embed。
        // 原生 UIKit_CreateWindow 内部已经把 UIKit 工作派发到主线程完成，
        // 此处主线程处于空闲 runloop 状态，dispatch_sync 安全（launchJVM 在
        // 后台线程，主线程没有任何等待渲染线程的锁）。若嵌入失败，保持现状
        // 并留日志（行为回退到修复前，不引入新风险）。
        static bool s_embedTried = false;
        if (!s_embedTried) {
            s_embedTried = true;
            __block bool embedOK = false;
            if ([NSThread isMainThread]) {
                embedOK = ame_embedSDLViewIntoHost();
            } else {
                dispatch_sync(dispatch_get_main_queue(), ^{
                    embedOK = ame_embedSDLViewIntoHost();
                });
            }
            if (!embedOK) {
                NSDebugLog(@"[AmethystEmbed] embed FAILED -- falling back to legacy behavior (SDL will own a separate UIWindow; expect black screen if MC calls SDL_ShowWindow)");
            }
        }
    }
    NSDebugLog(@"[SDLHook] SDL_CreateWindow -> %p", wnd);
    return wnd;
}

static void *ame_SDL_CreateWindowWithProperties(uint32_t props) {
    ame_forceEglProfileEs();
    NSDebugLog(@"[SDLHook] SDL_CreateWindowWithProperties props=%u", props);
    bool reuse = ame_shouldReusePrimaryWindow();
    if (reuse && ame_primaryWindow != NULL) {
        ame_primaryWindowRefs++;
        NSDebugLog(@"[SDLHook] reusing primary window %p, refs=%u",
                   ame_primaryWindow, ame_primaryWindowRefs);
        return ame_primaryWindow;
    }
    void *wnd = ame_real_CreateWindowWithProperties
                    ? ame_real_CreateWindowWithProperties(props)
                    : NULL;
    if (reuse && wnd != NULL) {
        ame_primaryWindow = wnd;
        ame_primaryWindowRefs = 1;
    }
    NSDebugLog(@"[SDLHook] SDL_CreateWindowWithProperties -> %p", wnd);
    return wnd;
}

static void ame_SDL_DestroyWindow(void *window) {
    if (window != NULL && window == ame_primaryWindow) {
        if (ame_primaryWindowRefs > 0) ame_primaryWindowRefs--;
        if (ame_primaryWindowRefs > 0) {
            NSDebugLog(@"[SDLHook] DestroyWindow %p skipped, refs=%u",
                       window, ame_primaryWindowRefs);
            return;
        }
        ame_primaryWindow = NULL;
        ame_primaryWindowRefs = 0;
    }
    if (ame_real_DestroyWindow) ame_real_DestroyWindow(window);
}

static void *ame_SDL_LoadFunction(void *handle, const char *name) {
    void *r = ame_real_LoadFunction ? ame_real_LoadFunction(handle, name) : NULL;
    ame_maybeWrapEgl(name, &r);
    ame_maybeWrapWindowHook(name, &r);
    return r;
}

// SDL 公共 EGL 解析入口，可绕过 SDL_LoadFunction；补齐同样的代理
static void *ame_SDL_EGL_GetProcAddress(const char *proc) {
    void *r = ame_real_EGL_GetProcAddress ? ame_real_EGL_GetProcAddress(proc) : NULL;
    if (proc == NULL || r == NULL) return r;
    ame_maybeWrapEgl(proc, &r);
    return r;
}

// Task 50：SDL_GetWindowFlags 剥离 MINIMIZED 位（0x40）。
// embed（Task 32/49）隐藏 SDL 自有 UIWindow 是防"空窗黑盖子"的必要动作，
// 但 SDL/UIKit 会把隐藏的窗口标记为 minimized。renderpearl 26.3 的
// GlSurface.acquireNextTexture 查询窗口 flags，看到 MINIMIZED 即抛
// "Cannot acquire minimized window" 跳帧（622166a 实测两次）。
// 对 MC 撒一个无害的谎：窗口永不 minimized —— 画面/输入不受影响，
// 真正的后台切换由 SDL_APP_WILL_ENTER_BACKGROUND 等事件表达，语义完整。
//
// Task 110：INPUT_FOCUS 位（0x200）置 1 + HIDDEN 位（0x4）一并剥离。
// 同一隐藏动作的第二个后果：隐藏的 SDL 窗口既不持有输入焦点（0x200=0）
// 又被标 HIDDEN（0x4）。Task50 只剥了 MINIMIZED，焦点位漏网——
// dynamic_fps 3.11.10 的 WindowObserver 构造时直接查
// SDL_GetWindowFlags & 0x200（不走 vanilla Window.focused，后者初始
// true 且只由我们不喂的 526/527 事件驱动——所以纯原版 26.3 完全正常，
// 698c6fe 双会话实锤），恒判"未聚焦"；其状态机
//   focused ? (idle?ABANDONED:…FOCUSED) : (hovered?HOVERED:(iconified?INVISIBLE:UNFOCUSED))
// 三输入全坏（0x200=0、0x400=0、0x40||0x4=true）→ 稳态落 UNFOCUSED/
// INVISIBLE 降频档（mod 默认 unfocused=1fps/invisible=0fps；用户整合包
// 实测钉 30fps，关 mod 即恢复）。这是"整合包卡 30、原版正常"的根因。
// 补完同一个无害的谎：embed 模式下游戏视图就是前台焦点与可见画面——
// iOS app 活跃时恒真；app 进后台本就被冻结/停摆不渲染，恒 1 无副作用。
// 置 1 后状态机短路进 FOCUSED 分支（Config.ACTIVE，frame_rate_target=-1
// 不限帧）；idle 档（ABANDONED,10fps）由 Task104 的 45s 滚轮心跳喂养
// mod 的 IdleHandler.onActivity（事件 1536-1539 族）而永不误触。
// vanilla 侧唯一 flags 消费点是 Window.isFullscreen() 的 & 1（FULLSCREEN）
// ——不受影响；MINIMIZED 剥离（renderpearl）保持。
//
// Task 118（后台焦点释放）：上面"恒 1 无副作用"的论证在两种真实场景下
// 不成立——(a) 进后台后的过渡期（iOS 给 app 留几秒执行时间，音乐/音频
// 会话活跃时更长），此时进程仍在渲染，恒 1 让 dynamic_fps 类模组全程
// 满帧白白烧电；(b) 越过暂停即恢复的前台切换。正确语义是分状态撒谎：
//   前台：0x200 恒置 1（Task 110 行为不变，根治 30fps 钉死）
//   后台：0x200 不置（释放焦点），仍剥离 0x40/0x4 —— dynamic_fps 状态机
//         读到 focused=0, hovered=0, iconified=0 → UNFOCUSED 档
//        （默认 1fps，即"取消焦点让模组识别后台降低 fps"）。
// 刻意不放进 INVISIBLE 档（HIDDEN 0x4 放行 → 0fps）：个别模组对"窗口
// 不可见"有激进副作用（跳渲染/断线），UNFOCUSED 是最保守的后台态。
// 观察者惰性注册（本函数首次被调时，dispatch_once + 转主线程）——
// mod 每帧轮询 flags，状态切换在下一帧即被感知，无需事件投递。
static _Atomic bool ame118_appBackgrounded = false;
static dispatch_once_t ame118_observerOnce;

static void ame118_installLifecycleObservers(void) {
    dispatch_once(&ame118_observerOnce, ^{
        void (^install)(void) = ^{
            NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
            [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                             object:nil queue:nil
                        usingBlock:^(NSNotification *note) {
                if (!atomic_exchange(&ame118_appBackgrounded, true)) {
                    NSLog(@"[SDLHook] Task118: app entered background -- SDL focus released (mods may throttle fps)");
                }
            }];
            [nc addObserverForName:UIApplicationWillEnterForegroundNotification
                             object:nil queue:nil
                        usingBlock:^(NSNotification *note) {
                if (atomic_exchange(&ame118_appBackgrounded, false)) {
                    NSLog(@"[SDLHook] Task118: app returning to foreground -- SDL focus restored (Task110)");
                }
            }];
        };
        if ([NSThread isMainThread]) {
            install();
        } else {
            dispatch_async(dispatch_get_main_queue(), install);
        }
    });
}

static unsigned int ame_SDL_GetWindowFlags(void *window) {
    ame118_installLifecycleObservers();
    unsigned int f = ame_real_GetWindowFlags ? ame_real_GetWindowFlags(window) : 0;
    if (ame118_appBackgrounded) {
        // Task 118 后台：不置焦点位（模组读到 UNFOCUSED → 后台限帧档），
        // MINIMIZED/HIDDEN 剥离保持（renderpearl + 保守 iconified 语义）。
        return f & ~0x40u & ~0x4u;
    }
    // Task 110 前台：0x200 = SDL_WINDOW_INPUT_FOCUS 置 1；0x40 = MINIMIZED、0x4 = HIDDEN 剥离
    return (f | 0x200u) & ~0x40u & ~0x4u;
}

// ============================================================================
// Task 65（键盘事件静默丢弃根治 —— "进游戏动不了"的真正根因）：
//
// 证据链（bd7d528 日志，7d18163 构建）：
//   1. 虚拟控件触发 ✓（sendKey W/A/S/D 全在）
//   2. SDL 事件推送 ✓（glfwKeyToSDLScancode 映射无误）
//   3. MC 事件泵消费 ✓（"Task64 key consumed" 52 条，scancode/key/down 全对）
//   4. 玩家不动 ✗ —— 丢弃点在 MC Java 侧第一道检查。
//
// 反编译 client.jar（26.3-rc-2）定案：KeyboardHandler.keyPress 首行
//   if (handle == 0L || handle != window.handle()) return;
// handle 来自 SDLEvents.SDL_GetWindowFromEvent(event)。MC 26.3 的
// SDLEventHandler 五个事件处理器里，handleKeyEvent 是唯一把 getWindowHandle
// 放在 minecraft.execute(lambda) 内部懒惰求值的（mouse motion/button/wheel/
// text 全部在 lambda 外急切求值成 long）。lambda 延迟执行时，pollEvents 的
// while 循环已把 SDL_Event 缓冲区复用给后续事件（或已随 try-with-resources
// 释放）——getWindowHandle 读到的是复用/释放后的数据，type 不在有效集合 →
// SDL_GetWindowFromEvent 返回 NULL → keyPress 首行 handle==0 直接 return →
// 键盘事件全灭。鼠标因急切求值全程无恙——与实测"相机/点击正常、移动键死"
// 完全吻合。桌面端 lambda 在渲染线程可重入 executor 上立即执行，缓冲区仍
// 有效，此 MC 侧缺陷不显现（本移植的线程时序让它暴露）。
//
// 修复：钩住 SDL_GetWindowFromEvent。真实解析返回 NULL 时回落
// ame_primaryWindow（= MC 经我们 SDL_CreateWindow 钩子拿到的窗口 =
// window.handle()，三处指针对证日志一致）。全 MC 反编译确认该函数仅
// SDLEventHandler.getWindowHandle 一个调用方；本进程单窗口，回落值与正确
// 解析值恒等，正常路径零行为变化；键盘 lambda 从此恒拿正确句柄。
// 同时输出观测日志：键盘类解析逐条记录（含真实返回值与回落标记），
// 鼠标类采样记录——下轮日志可直接验证根因与修复效果。
// ============================================================================
static void *ame_SDL_GetWindowFromEvent(const void *event) {
    void *w = ame_real_GetWindowFromEvent ? ame_real_GetWindowFromEvent(event) : NULL;
    static _Atomic unsigned long s_task65Calls = 0;
    static _Atomic unsigned long s_task65Fallbacks = 0;
    unsigned long n = atomic_fetch_add(&s_task65Calls, 1) + 1;
    bool fellBack = NO;
    if (w == NULL && ame_primaryWindow != NULL) {
        w = ame_primaryWindow;
        fellBack = YES;
        atomic_fetch_add(&s_task65Fallbacks, 1);
    }
    uint32_t type = (event != NULL) ? *(const uint32_t *)event : 0;
    if (type == 0x300 || type == 0x301) {
        // 键盘类解析：离散低频，逐条记录（前 60 + 每 100）
        static _Atomic unsigned long s_task65KeyCalls = 0;
        unsigned long kn = atomic_fetch_add(&s_task65KeyCalls, 1) + 1;
        if (kn <= 60 || kn % 100 == 0) {
            uint32_t kwid = *(const uint32_t *)((const char *)event + 16);
            NSDebugLog(@"[SDLHook] Task65 key window resolve #%lu type=0x%x windowID=%u -> %p%s (fb %lu/%lu)",
                       (unsigned long)kn, type, (unsigned)kwid, w, fellBack ? " FALLBACK" : "",
                       (unsigned long)atomic_load(&s_task65Fallbacks),
                       (unsigned long)atomic_load(&s_task65Calls));
        }
    } else if (n <= 20 || n % 500 == 0) {
        NSDebugLog(@"[SDLHook] Task65 window resolve #%lu type=0x%x -> %p%s",
                   (unsigned long)n, (unsigned)type, w, fellBack ? " FALLBACK" : "");
    }
    return w;
}

// ============================================================================
// Task 67：SDL_GetKeyboardState 钩子（MC 键盘态轮询口观测）
//
// 目的：终结“Task66 数组直写是否被 MC 看到”的不确定性。
// InputConstants.isKeyDown / KeyMapping.setAll / Minecraft.hasShiftDown
// 全部经 LWJGL→dlsym→本钩子轮询键盘态。采样记录：
//   1. MC 侧拿到的数组指针 vs input_bridge 直写指针（Ame66GetKbState）
//      ——不一致 = 存在两个 SDL 实例/两块数组，Task66 修复失效的实锤；
//   2. 关键扫描位的即时值（A=4 D=7 S=22 W=26 Space=44 F3=60 F4=61
//      LCtrl=224 LShift=225）——MC 轮询瞬间虚拟键是否可见。
// 纯透传零行为变化；isKeyDown 低频调用（事件/换界面触发），采样日志
// 开销可忽略。
// ============================================================================
static const bool *ame_SDL_GetKeyboardState(int *numkeys) {
    const bool *r = ame_real_GetKeyboardState ? ame_real_GetKeyboardState(numkeys) : NULL;
    static _Atomic unsigned long s_task67KbPolls = 0;
    unsigned long n = atomic_fetch_add(&s_task67KbPolls, 1) + 1;
    if (n <= 10 || n % 2000 == 0) {
        const bool *ours = Ame66GetKbState();
        int nk = (numkeys != NULL) ? *numkeys : 0;
        int vA = 0, vD = 0, vS = 0, vW = 0, vSpc = 0, vF3 = 0, vF4 = 0, vLC = 0, vLS = 0;
        if (r != NULL && nk >= 256) {
            vA = r[4] ? 1 : 0;      vD = r[7] ? 1 : 0;
            vS = r[22] ? 1 : 0;     vW = r[26] ? 1 : 0;
            vSpc = r[44] ? 1 : 0;   vF3 = r[60] ? 1 : 0;
            vF4 = r[61] ? 1 : 0;    vLC = r[224] ? 1 : 0;
            vLS = r[225] ? 1 : 0;
        }
        NSDebugLog(@"[SDLHook] Task67 MC kb-state poll #%lu: ptr=%p ours=%p match=%d numkeys=%d | A=%d S=%d D=%d W=%d Spc=%d F3=%d F4=%d LCtrl=%d LShift=%d",
                   (unsigned long)n, (const void *)r, (const void *)ours,
                   (r == ours) ? 1 : 0, nk,
                   vA, vS, vD, vW, vSpc, vF3, vF4, vLC, vLS);
    }
    return r;
}

// ============================================================================
// Task 61（SDL3 路径分辨率根因修复，44fef06 日志定案）：
//
//   现象：Task60 表面侧已全绿（drawableSize=2360x1640 scale=2.00，
//   eglQuerySurface=2360x1640），但 swap 探针 viewport=1180x820 ≠
//   surface=2360x1640 → Task49 geo-heal 每帧 2x 升采样 blit（1180x820 →
//   scratch 2360x1640 → FBO0）＝用户实测“SDL 的分辨率还是不行”（全屏模糊）。
//
//   根因：SDL3 uikit 驱动的窗口以“点”为单位——Task51 钳制把 MC 的
//   2360x1640（像素语义）压到 1180x820 点；随后 uikit 发出本会话唯一的
//   尺寸事件 SDL_EVENT_WINDOW_RESIZED(0x207) data1/data2=1180x820（点），
//   MC 26.3 按像素语义消费（日志实测：0x207 后 viewport 即 1180x820）→
//   渲染分辨率被压半。与此同时 MC 的输入基准来自像素路径
//   （SDL_GetWindowSizeInPixels：1180x820 点 x screenScale 2 = 2360x1640，
//   == 启动器告知值，Task59 输入直通已实证）——桌面平台两条路径恒相等，
//   iOS retina 上分裂 2x：画面半分辨率、输入却全尺寸，即本症状。
//
//   修复（三路同值，全部收敛到启动器像素口径 windowWidth×windowHeight，
//   == launchJVM 告知 == EGL surface(Task60) == MC 输入基准(Task59)）：
//     1) SDL_GetWindowSize（点路径）→ 上报 windowWidth×windowHeight；
//     2) SDL_GetWindowSizeInPixels → 钉到 windowWidth×windowHeight
//        （当前本就等于该值——钉住后不再依赖 UIKit 窗口点尺寸）；
//     3) 0x207/0x208 事件 data1/data2 改写（见 PollEvent 内 Task61 块）。
//   UIKit 真实窗口仍由 Task51 钳制保持在 1180x820 点——几何/嵌入/触摸
//   路由零改动；MC 侧看到的世界与已“完全正常”的 LWJGL/MG 26.2 路径
//   （viewport==surface==2360x1640）完全对齐。viewport==surface 后
//   Task50 恢复分支自动退出 geo-heal，逐帧 blit 开销随之消失。
//
//   注：windowWidth/windowHeight 为 SurfaceViewController::updateSavedResolution
//   主线程写、此处渲染线程读的 plain int（environ.h 全局）；会话期间值稳定，
//   旋转时与 drawableSize 同步更新（Task60 统一写入者），口径始终一致。
// ============================================================================
static bool ame_SDL_GetWindowSize(void *window, int *w, int *h) {
    bool r = ame_real_GetWindowSize ? ame_real_GetWindowSize(window, w, h) : false;
    if (window != NULL && windowWidth > 0 && windowHeight > 0) {
        if (r && w != NULL && h != NULL) {
            static _Atomic unsigned long s_task61_q1 = 0;
            unsigned long n61 = atomic_fetch_add(&s_task61_q1, 1) + 1;
            if (n61 <= 20 || n61 % 500 == 0) {
                NSLog(@"[SDLHook] Task61 SDL_GetWindowSize: %dx%d (SDL pts) -> %dx%d (launcher px; render res unified)",
                      *w, *h, windowWidth, windowHeight);
            }
        }
        if (w != NULL) *w = windowWidth;
        if (h != NULL) *h = windowHeight;
    }
    return r;
}

static bool ame_SDL_GetWindowSizeInPixels(void *window, int *w, int *h) {
    bool r = ame_real_GetWindowSizeInPixels ? ame_real_GetWindowSizeInPixels(window, w, h) : false;
    if (window != NULL && windowWidth > 0 && windowHeight > 0) {
        if (r && w != NULL && h != NULL) {
            static _Atomic unsigned long s_task61_q2 = 0;
            unsigned long n62 = atomic_fetch_add(&s_task61_q2, 1) + 1;
            if (n62 <= 20 || n62 % 500 == 0) {
                NSLog(@"[SDLHook] Task61 SDL_GetWindowSizeInPixels: %dx%d (native) -> %dx%d (pinned launcher px)",
                      *w, *h, windowWidth, windowHeight);
            }
        }
        if (w != NULL) *w = windowWidth;
        if (h != NULL) *h = windowHeight;
    }
    return r;
}

// Vulkan 加载器一致性：MC 26.3 起 RenderPearl 要求 SDL 与 LWJGL 使用同一
// 加载器实例（校验 vkGetInstanceProcAddr 指针一致），而 SDL 仅能按路径加载。
// 启动器若已持有句柄（十六进制记录在 AMETHYST_VULKAN_PTR），此处直接还回。
// 对应句柄的引用计数由启动器持有，故忽略 SDL 侧的卸载。
static void *ame_SDL_LoadObject(const char *path) {
    if (path != NULL && (strstr(path, "vulkan") != NULL || strstr(path, "MoltenVK") != NULL)) {
        const char *vkptr = getenv("AMETHYST_VULKAN_PTR");
        if (vkptr != NULL && vkptr[0] != '\0') {
            void *handle = (void *)(uintptr_t)strtoull(vkptr, NULL, 16);
            if (handle != NULL) {
                NSDebugLog(@"[SDLHook] SDL_LoadObject('%s') -> shared handle %p", path, handle);
                return handle;
            }
        }
    }
    return ame_real_LoadObject ? ame_real_LoadObject(path) : NULL;
}

static void ame_SDL_UnloadObject(void *handle) {
    const char *vkptr = getenv("AMETHYST_VULKAN_PTR");
    if (vkptr != NULL && vkptr[0] != '\0') {
        void *vulkan_handle = (void *)(uintptr_t)strtoull(vkptr, NULL, 16);
        if (handle == vulkan_handle) {
            NSDebugLog(@"[SDLHook] SDL_UnloadObject(%p) ignored (shared handle)", handle);
            return;
        }
    }
    if (ame_real_UnloadObject) ame_real_UnloadObject(handle);
}

#pragma mark - 5) SDL GL 入口 → 启动器 EGL bridge

// 为什么需要接管：
//   SDL 的 UIKit 后端走的是 EAGL / CAEAGLLayer（iOS 系统 OpenGLES 框架），
//   而 MobileGL / Mithril / MobileGlues 提供的是 **EGL + GL** 符号。两者不是
//   同一套 ABI，SDL 自己建的上下文拿不到渲染器的 GL 函数，MC 26.3 的
//   GlBackend 因此判定 OpenGL 不可用并回落到原生 Vulkan。
//
//   启动器的 EGL bridge（gl_bridge.m）早已在 GLFW 路径（26.2 及以下）验证可用，
//   且 gl_init_context() 直接从 SurfaceViewController 的 layer 建 EGL surface，
//   不依赖 SDL 建了哪个 view —— 所以可以整条搬到 SDL3 路径上复用。
//
// 判定复用 ame_sdlGlesCompatEnabled() 那套渲染器名单，但语义相反：ES 化豁免
// ≠ GL bridge 豁免。Task 79 起 zink（libOSMesa/gallium_/vulkan_zink）也走
// bridge——见下方函数内的 Task 79 注释；ES 强制化（ame_sdlGlesCompatEnabled）
// 依然排除 zink，两套判定互不牵连。
static bool ame_glBridgeEnabled(void) {
    if (!ame_envFlagOn("AMETHYST_SDL_GL_BRIDGE", true)) return false;

    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return false;

    // Task 79：zink（libOSMesa/gallium_/vulkan_zink）从【绝不接管】改为【接管】。
    //
    // 旧排除（c71dcfa，2026-09-01）的语境：当时 renderpearl 的
    // GlBackend.loadLibrary 指针一致性检查还没被 provider-mirror 机制攻克
    // （那正是 c71dcfa 为 MobileGlues 引入 ame_SDL_GL_GetProcAddress 镜像链的
    // 缘由），zink 过不了检查 → 回落 Vulkan 是彼时唯一能进世界的路径，
    // “一个字节都不能动”是对那个未修复状态的保护，不是 zink 不能用 GL。
    //
    // 现在的设备证据（8a31d1b，用户上报“zink 在 26.3 的启动回退”）：
    //   [SDLGL] SDL_GL_LoadLibrary(.../libOSMesa.8.dylib) -> failed: OpenGL
    //           library already loaded（main_hook 兑装成功，但真实 SDL 拒载）
    //   [Render thread/ERROR]: Failed to create backend OpenGL
    //           BackendCreationException: glGetError mismatch
    //   → Using graphics backend Vulkan (MoltenVK 1.4.2) —— ZinkConfig 全部
    //     空转，用户选的 zink 实际跑的是 MC 原生 Vulkan 后端。
    //
    // 修法与 MobileGlues 同构：bridge 接管 SDL_GL_LoadLibrary（真实 SDL 从不被
    // 调 → “already loaded” 无从谈起）+ SDL_GL_GetProcAddress 镜像 LWJGL 解析链
    // （同一 NOLOAD 句柄 + 同一 eglGetProcAddress/OSMesaGetProcAddress 链 →
    // 指针一致性按构造成立）→ GL backend 被接受 → 上下文/呈现走与 ≤26.2 完全
    // 相同的 OSMesa bridge（osm_init_context / osm_make_current / osm_swap_buffers）。
    // MG 侧已验证的对照日志（2d321fa）：hooked SDL_GL_LoadLibrary -> EGL bridge →
    // “Using graphics backend OpenGL, using drivers: 4.0.0 MobileGlues 2.0.17”。
    //
    // 逃生阀：AMETHYST_ZINK_GL_BRIDGE=0 一行环境变量即回退到旧行为（不接管 →
    // 回落 Vulkan），供设备上 A/B 对照或万一 GL 路径出问题时应急处置。
    if (strncmp(renderer, "libOSMesa", 9) == 0) {    // zink（带版本号）
        return ame_envFlagOn("AMETHYST_ZINK_GL_BRIDGE", true);
    }
    if (strncmp(renderer, "gallium_", 8) == 0) {     // OSMesa 系
        return ame_envFlagOn("AMETHYST_ZINK_GL_BRIDGE", true);
    }
    if (strcmp(renderer, "vulkan_zink") == 0) {      // zink
        return ame_envFlagOn("AMETHYST_ZINK_GL_BRIDGE", true);
    }
    // 原生 Vulkan 自身走 Vulkan 路径，不需要 GL bridge
    if (strstr(renderer, "libMoltenVK") != NULL) return false;

    // Task 171：ANGLE（libtinygl4angle.dylib）加入接管列表。
    // 病历（f26337d 装机日志 latestlog.txt，FO 整合包选 ANGLE 渲染器）：
    //   [SDLGL] SDL_GL_LoadLibrary(.../libtinygl4angle.dylib) -> failed:
    //           OpenGL library already loaded（真实 SDL 拒载，本 bridge 未接管）
    //   [Render thread/ERROR]: Failed to create backend OpenGL
    //           BackendCreationException: glGetError mismatch
    //   → renderpearl 回落 MC 原生 Vulkan 后端（MoltenVK）→ 整合包里的
    //     Iris 在 RenderSystem.initRenderer 阶段 GL.getCapabilities() 拿到
    //     空（GL 上下文从未建立）→ ExceptionInInitializerError 崩溃。
    // tinygl4angle 此前从未进过本列表（Task 79 只收编了 zink 系）——它
    // 与 opengles/gl4es 同为 raw ANGLE 家族（EGL 经其依赖的 libEGL 解析，
    // isDesktopGLRenderer 早已包含 MTL_ANGLE = EGL_OPENGL_BIT + eglBindAPI
    // 路径就绪），bridge 接管后 SDL_GL_LoadLibrary/GetProcAddress 走镜像
    // 链（同一 NOLOAD 句柄 + 同一 eglGetProcAddress/dlsym 链），指针一致性
    // 按构造成立 → GL backend 被接受 → 不再回落 Vulkan → Iris 正常。
    // 逃生阀与 zink 同款：AMETHYST_ANGLE_GL_BRIDGE=0 一行回退旧行为。
    if (strstr(renderer, "libtinygl4angle") != NULL) {
        return ame_envFlagOn("AMETHYST_ANGLE_GL_BRIDGE", true);
    }

    // 需要 EGL bridge 的转译型渲染器：它们提供 EGL + GL 符号，SDL 的 EAGL
    // 后端无法对接，必须由 bridge 建上下文并供给 GL 函数指针。
    if (strstr(renderer, "libMobileGL") != NULL) return true;    // MobileGL 双后端
    if (strstr(renderer, "libmithril") != NULL) return true;     // Mithril
    if (strstr(renderer, "mobileglues") != NULL) return true;    // MobileGlues
    if (strstr(renderer, "gl4es") != NULL) return true;          // GL4ES
    if (strstr(renderer, "libltw") != NULL) return true;         // LTW
    if (strncmp(renderer, "opengles", 8) == 0) return true;      // 内置 GLES

    return ame_isMobileGluesEgl();
}

// egl_bridge.m 的上下文入口。这些函数没有公开头文件，故在此 extern 声明。
// 参数用 void* 以避开 basic_render_window_t 的类型依赖。
// SDL3 路径用 ForSDL3 变体：不写 org.lwjgl.opengl.libname（该属性由 JavaLauncher
// 在 JVM 启动时以 -D 传入，LWJGL 早已读取；此处再设无效且需 attach 非 JVM 线程）。
extern int   pojavInitOpenGLForSDL3(void);
extern void *pojavCreateContext(void *contextSrc);
extern void  pojavMakeCurrent(void *window);
extern void  pojavSwapBuffers(void);
extern void  pojavSwapInterval(int interval);

static bool   g_glBridgeInited = false;
static void  *g_glContext = NULL;      // 充当 SDL_GLContext
static void  *g_rendererHandle = NULL; // 渲染器 dylib 句柄（缓存，避免重复 dlopen）
// LWJGL OpenGL FunctionProvider 所用库的确切路径（SDL_GL_LoadLibrary 的入参
// = GL.getFunctionProvider().getPath()）。26.3 renderpearl 的
// GlBackend.loadLibrary 要求 LWJGL provider 与 SDL_GL_GetProcAddress 对同一
// 名字返回同一指针，所以本钩子必须与 LWJGL 绑定到同一镜像：NOLOAD 按该
// 路径取回“已加载”的句柄，绝不映射第二份。
static char   g_lwjglGLLibPath[1024] = {0};

static void *ame_rendererHandle(void) {
    if (g_rendererHandle != NULL) return g_rendererHandle;

    // 首选：LWJGL provider 的确切路径（ame_SDL_GL_LoadLibrary 捕获）。
    // LWJGL 打开渲染器用的正是这个字符串，NOLOAD 返回同一 Loader 的句柄 ——
    // 本钩子的 dlsym 落点与 LWJGL 完全一致，也不会重复映射。
    if (g_lwjglGLLibPath[0] != '\0') {
        g_rendererHandle = dlopen(g_lwjglGLLibPath, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
        if (g_rendererHandle != NULL) {
            NSDebugLog(@"[SDLHook] renderer handle <- LWJGL provider path (NOLOAD): %s",
                       g_lwjglGLLibPath);
            return g_rendererHandle;
        }
        NSDebugLog(@"[SDLHook] renderer NOLOAD dlopen('%s') failed: %s -- falling back",
                   g_lwjglGLLibPath, dlerror() ?: "unknown");
    }

    const char *renderer = getenv("AMETHYST_RENDERER");
    if (renderer == NULL || renderer[0] == '\0') return NULL;
    // Task 138：同 gl_bridge 的 dlsym_EGL——-gles 逻辑键先映射回共享二进制。
    NSString *path = [NSString stringWithFormat:@"@rpath/%s", ame_physical_renderer_dylib(renderer)];
    // 渲染器已由 LWJGL（org.lwjgl.opengl.libname）加载。先 NOLOAD 取同一
    // 句柄；万一失败（@rpath 展开差异等），退回普通 dlopen —— dyld 按文件
    // 身份去重，不会真的映射第二份。
    g_rendererHandle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
    if (g_rendererHandle == NULL) {
        g_rendererHandle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
    }
    if (g_rendererHandle == NULL) {
        NSDebugLog(@"[SDLHook] renderer dlopen('%@') failed: %s",
                   path, dlerror() ?: "unknown");
    }
    return g_rendererHandle;
}

// 库已由启动器预加载，这里只负责初始化 bridge
static bool ame_SDL_GL_LoadLibrary(const char *path) {
    // 记录 LWJGL provider 的确切路径（= GL.getFunctionProvider().getPath()），
    // ame_rendererHandle 据此取回同一镜像的句柄。在任何 GlBackend 调用
    // SDL_GL_GetProcAddress 之前必然先经过这里（loadLibrary 的顺序）。
    if (path != NULL && path[0] != '\0' && g_lwjglGLLibPath[0] == '\0') {
        strlcpy(g_lwjglGLLibPath, path, sizeof(g_lwjglGLLibPath));
    }
    if (!g_glBridgeInited) {
        g_glBridgeInited = true;
        int r = pojavInitOpenGLForSDL3();
        NSDebugLog(@"[SDLHook] SDL_GL_LoadLibrary('%s') -> pojavInitOpenGLForSDL3()=%d (EGL bridge)",
                   path ?: "<null>", r);
    }
    return true;
}

static void *ame_SDL_GL_CreateContext(void *window) {
    // MC 26.3 ss9+ 在设备初始化时先建一个隐藏工具窗口（flags 含 SDL_WINDOW_HIDDEN），
    // 随后再建主窗口。而 EGL bridge 的上下文生命周期与进程一致
    // （SDL_GL_DestroyContext 不真正销毁，见下），若每次调用都新建，就会在同一个
    // CALayer 上叠加第二个 EGLSurface —— 部分 EGL 实现（含 MobileGL）会直接失败，
    // 即便成功也会让 eglMakeCurrent 在两个 surface 间反复切换。
    // 故复用首个上下文，与 ZL2 的 shouldReusePrimaryWindow() 同一思路。
    if (g_glContext != NULL) {
        NSDebugLog(@"[SDLHook] SDL_GL_CreateContext(%p) -> reuse existing %p", window, g_glContext);
        // 复用时也要保证它处于 current 状态：MC 建完上下文后必然调 MakeCurrent，
        // 这里不额外处理。
        return g_glContext;
    }
    void *ctx = pojavCreateContext(NULL);
    if (ctx != NULL) g_glContext = ctx;
    NSDebugLog(@"[SDLHook] SDL_GL_CreateContext(%p) -> %p (EGL bridge)", window, ctx);
    return ctx;
}

static bool ame_SDL_GL_MakeCurrent(void *window, void *context) {
    if (context != NULL) g_glContext = context;
    pojavMakeCurrent(context);
    NSDebugLog(@"[SDLHook] SDL_GL_MakeCurrent(%p, %p) -> EGL bridge", window, context);
    return true;
}

static bool ame_SDL_GL_SwapWindow(void *window) {
    pojavSwapBuffers();
    return true;
}

// GL 函数必须来自渲染器自身。若误返回系统 GLES / EAGL 的实现，
// LWJGL 拿到的函数指针与 EGL 上下文不匹配，会直接崩。
//
// 26.3 renderpearl 的 GlBackend.loadLibrary 还要求指针一致：LWJGL 的
// GL FunctionProvider（GL$1，macOS 分支）与 SDL 的 SDL_GL_GetProcAddress
// （本钩子）对 "glGetError" 必须返回同一地址。2.0.15 在 MG 侧用 RTLD_SELF
// 自解析对齐两条链，但设备实测 3c13d5e5 依旧 mismatch —— dyld 对特殊句柄
// 的“caller image”判定被启动器的全局 dlsym 重绑定带偏，任何依赖
// RTLD_SELF / 镜像顺序的方案都不可靠。
//
// 2.0.16 改为按构造对齐：ame_rendererHandle() 通过 LWJGL provider 的确切
// 路径（NOLOAD）取回 LWJGL 正在使用的同一镜像句柄，然后逐条镜像 GL$1
// 的 macOS 解析链。Task 172 修正镜像本身：对本仓 JavaApp/libs/lwjgl-333/
// lwjgl-opengl.jar 里 GL$1.class 的 CFR 反编译实证，macOS 平台分支的
// 构造链是 ——
//   switch (Platform.get()) { case LINUX: glXGetProcAddress / ARB;
//                              case WINDOWS: wglGetProcAddress; }   // macOS 无 case
//   if (GetProcAddress == 0) GetProcAddress = OSMesaGetProcAddress;
//   查询：GetProcAddress(name) 非空则取其结果，否则 library.getFunctionAddress(name)
//         （= dlsym(lib, name)）。
// 即 GL$1 在 macOS 上【从不查询 eglGetProcAddress】。旧镜像的
// “eglGetProcAddress 优先”是错误的反推：对 MG/zink 恰好两条链殊途同归
// （要么都不导出 eglGetProcAddress，要么 GPA 与 dlsym 同址），装机验证
// 通过纯属侥幸；对 libtinygl4angle（ANGLE 家族，依赖链的 libEGL 导出
// eglGetProcAddress，而 glGetError 是依赖链 libGLESv2 的直接导出）则
// 两条链拿到不同地址 —— 9be2b53 装机日志（latestlog.old，FO 包 26.3）
// 实锤：bridge 已接管（"hooked SDL_GL_LoadLibrary -> EGL bridge"）但
// GlBackend.loadLibrary 仍报 "glGetError mismatch" → 回落 Vulkan →
// Iris No GLCapabilities 崩溃。修法 = 镜像链逐字对齐 GL$1 的 macOS 分支
// （只查 OSMesaGetProcAddress），指针一致性对所有渲染器按构造成立。
/// Task202：SDL_GL_GetProcAddress 解析观察器——首 12 个成功解析记名
/// （含来源路径：黑屏裁决需要知道 MC 的函数从哪条链拿到）+ NULL 去重
/// 全量记名（ANGLE 黑屏定谳：点名缺失函数）。纯取证，零行为改变。
static void ame202_gpaObserve(const char *proc, const char *src, void *result) {
    if (result != NULL) {
        static int s_ame202_ok = 0;
        if (s_ame202_ok < 12) {
            s_ame202_ok++;
            NSLog(@"[SDLGL] Task202: GetProcAddress OK #%d: %s (via %s)",
                  s_ame202_ok, proc, src);
        }
    } else {
        static const char *s_ame202_seen[160];
        static int s_ame202_n = 0;
        for (int i = 0; i < s_ame202_n; i++) {
            if (strcmp(s_ame202_seen[i], proc) == 0) return;
        }
        if (s_ame202_n < 160) s_ame202_seen[s_ame202_n++] = proc;
        NSLog(@"[SDLGL] Task202: GetProcAddress NULL (dedup #%d): %s -- MC will see a NULL pointer",
              s_ame202_n, proc);
    }
}

static void *ame_SDL_GL_GetProcAddress(const char *proc) {
    if (proc == NULL) return NULL;
    void *h = ame_rendererHandle();
    if (h != NULL) {
        // 镜像 GL$1 的 FunctionProvider 解析（macOS 平台分支：仅
        // OSMesaGetProcAddress —— eglGetProcAddress 从不参与，见上方注释）
        static void *g_lwjglMirrorGPA = NULL;
        static bool  g_lwjglMirrorTried = false;
        if (!g_lwjglMirrorTried) {
            g_lwjglMirrorTried = true;
            g_lwjglMirrorGPA = dlsym(h, "OSMesaGetProcAddress");
            NSDebugLog(@"[SDLHook] Task172 GL$1 mirror: OSMesaGetProcAddress=%p (renderer image %p; eglGetProcAddress deliberately NOT consulted per decompiled GL.1 macOS branch)",
                       g_lwjglMirrorGPA, h);
        }
        if (g_lwjglMirrorGPA != NULL) {
            void *p = ((void *(*)(const char *))g_lwjglMirrorGPA)(proc);
            if (p != NULL) {
                ame202_gpaObserve(proc, "OSMesa mirror", p);
                return p;
            }
        }
        // 对齐 GL$1 的回退：dlsym(lib, name)
        void *p = dlsym(h, proc);
        if (p != NULL) {
            ame202_gpaObserve(proc, "renderer dlsym", p);
            return p;
        }
    }
    void *r = ame_real_GL_GetProcAddress ? ame_real_GL_GetProcAddress(proc) : NULL;
    if (r == NULL) r = dlsym(RTLD_DEFAULT, proc);
    ame202_gpaObserve(proc, "real SDL / RTLD_DEFAULT", r);
    return r;
}

static bool ame_SDL_GL_SetSwapInterval(int interval) {
    pojavSwapInterval(interval);
    return true;
}

// 上下文由 EGL bridge 持有，生命周期与进程一致。这里不真正销毁，
// 只摘掉引用 —— 否则 SDL 会用 EAGL 的语义去释放一个 EGL 对象而崩溃。
static bool ame_SDL_GL_DestroyContext(void *context) {
    NSDebugLog(@"[SDLHook] SDL_GL_DestroyContext(%p) ignored (owned by EGL bridge)", context);
    if (g_glContext == context) g_glContext = NULL;
    return true;
}

static void *ame_SDL_GL_GetCurrentContext(void) {
    return g_glContext;
}

#pragma mark - 6) Task 32 窗口生命周期 / 事件泵取证（透传 + 日志）

// 全部透传到真实 SDL，行为零改动；只把调用记录下来。
// SDL3 ABI：bool SDL_ShowWindow(SDL_Window*) / bool SDL_SetWindowSize(SDL_Window*, int, int) 等。

static bool ame_SDL_ShowWindow(void *window) {
    // Task 32 黑屏修复：embedded 时绝不让 SDL 自己的 UIWindow 保持可见
    // （原生 makeKeyAndVisible 的空窗口会盖住 GameSurfaceView = 黑屏）。
    // 但仍然调用真实的 UIKit_ShowWindow（补上 SDL 内部状态：鼠标焦点等）。
    // 注意：原生 SDL3 的 UIKit_ShowWindow 直接在调用线程 makeKeyAndVisible，
    // 而调用方是 JVM 渲染线程 —— 离主线程调 UIKit 在 iOS 16+ 会被线程保护命中。
    // 所以：在主线程同步跑真实函数，随后立即中和覆盖（隐藏 SDL 窗口 +
    // re-front 嵌入视图 + 恢复宿主 key window）。整个过程同步完成，
    // 无中间可感知的黑窗闪烁。
    if (ame_embeddedSDLView != NULL) {
        __block bool r = false;
        if ([NSThread isMainThread]) {
            if (ame_real_ShowWindow) r = ame_real_ShowWindow(window);
            ame_refrontEmbeddedViewOnMain();
        } else {
            dispatch_sync(dispatch_get_main_queue(), ^{
                if (ame_real_ShowWindow) r = ame_real_ShowWindow(window);
                ame_refrontEmbeddedViewOnMain();
            });
        }
        NSDebugLog(@"[SDLHook] SDL_ShowWindow(%p) -> %d (embedded path: real call on main, SDL UIWindow re-hidden, embedded view re-fronted)",
                   window, (int)r);
        return r;
    }
    // 未嵌入：旧路径。原生函数直接在调用线程执行（与修复前行为一致）。
    bool r = ame_real_ShowWindow ? ame_real_ShowWindow(window) : false;
    NSDebugLog(@"[SDLHook] SDL_ShowWindow(%p) -> %d (NOT embedded: real call, SDL's own UIWindow becomes key+visible)", window, (int)r);
    return r;
}

static bool ame_SDL_HideWindow(void *window) {
    bool r = ame_real_HideWindow ? ame_real_HideWindow(window) : false;
    NSDebugLog(@"[SDLHook] SDL_HideWindow(%p) -> %d", window, (int)r);
    return r;
}

// Task51 Fix E：Pojav/Java 侧以“像素”语义调 SDL_SetWindowSize（2360x1640），
// 而 SDL3-on-iOS 是“点”语义（屏幕 1180x820 点）。e6886e2 日志铁证：
// 创建正确的 EGL surface（1180x820）在其后第 342 行被
//   [SDLHook] SDL_SetWindowSize(0x12fd53800, 2360, 1640) -> 1
//   [SDLHook] SDL_SetWindowPosition(0x12fd53800, -590, -410) -> 0
// 连锁击穿——超屏 SDL 窗口把嵌入的 SDL_uikitview 拉成 2360x1640 点 +
// 负偏移，ANGLE 表面随之被转置锁死 820x1180 全程不恢复（swap#1..#200
// surface 恒 820x1180），present 纹理与 drawable 失配 = 黑屏。
// 钳制规则：宽或高超过屏幕点数 → 除 2（像素→点）；仍超则硬钳屏幕点数。
// 屏幕点数来源：UIScreen.mainScreen.bounds（Apple 文档确认 UIScreen 属性
// 线程安全，可在 SDL 的 Java 调用线程上读；首次调用后 static 缓存）。
// 注：CGDisplayBounds/CGMainDisplayID 是 macOS 专属 API，iOS 不可用
//（c56e03f 首次 CI 构建实测报 undeclared function，本版已回退 UIKit 路径）。
static CGSize ame51_display_pts(void) {
    static CGSize pts = {0, 0};
    if (pts.width <= 0 || pts.height <= 0) {
        CGFloat w = 0, h = 0;
        @try {
            CGRect b = [UIScreen mainScreen].bounds;   // 线程安全属性
            w = b.size.width; h = b.size.height;
        } @catch (NSException *e) {
            NSLog(@"[SDLHook] Task51 mainScreen bounds exception: %@", e);
        }
        if (w <= 0 || h <= 0) {            // 异常兜底：iPad Air M4 量级
            w = 1180; h = 820;
        }
        // UIScreen 返回竖屏口径（820x1180）时翻成横屏口径（Info.plist 已锁横屏）
        if (w < h) { CGFloat t = w; w = h; h = t; }
        pts = CGSizeMake(w, h);
        NSLog(@"[SDLHook] Task51 display pts cached: %.0fx%.0f", pts.width, pts.height);
    }
    return pts;
}

static bool ame_SDL_SetWindowSize(void *window, int w, int h) {
    int cw = w, ch = h;
    if (w > 0 && h > 0) {
        CGSize pts = ame51_display_pts();
        int maxW = (int)pts.width, maxH = (int)pts.height;
        if (maxW > 0 && maxH > 0 && (w > maxW || h > maxH)) {
            cw = (w > maxW) ? (w / 2) : w;   // 像素语义折半 = 点语义
            ch = (h > maxH) ? (h / 2) : h;
            if (cw > maxW) cw = maxW;
            if (ch > maxH) ch = maxH;
            NSLog(@"[SDLHook] Task51 SetWindowSize pixel->point clamp: %dx%d -> %dx%d (display %dx%d pts)",
                  w, h, cw, ch, maxW, maxH);
        }
    }
    bool r = ame_real_SetWindowSize ? ame_real_SetWindowSize(window, cw, ch) : false;
    NSDebugLog(@"[SDLHook] SDL_SetWindowSize(%p, %d, %d) -> %d", window, cw, ch, (int)r);
    return r;
}

static bool ame_SDL_SetWindowPosition(void *window, int x, int y) {
    int cx = x, cy = y;
    if (x < 0 || y < 0) {
        // Task51：超屏窗口（像素语义）居中产生的负偏移，把嵌入的 SDL 视图
        // 坐标系拖离屏幕原点 → 触摸命中区域错位。钳回 (0,0)。
        if (cx < 0) cx = 0;
        if (cy < 0) cy = 0;
        NSLog(@"[SDLHook] Task51 SetWindowPosition clamp: %d,%d -> %d,%d", x, y, cx, cy);
    }
    bool r = ame_real_SetWindowPosition ? ame_real_SetWindowPosition(window, cx, cy) : false;
    NSDebugLog(@"[SDLHook] SDL_SetWindowPosition(%p, %d, %d) -> %d", window, cx, cy, (int)r);
    return r;
}

static bool ame_SDL_SetWindowFullscreen(void *window, bool fullscreen) {
    bool r = ame_real_SetWindowFullscreen ? ame_real_SetWindowFullscreen(window, fullscreen) : false;
    NSDebugLog(@"[SDLHook] SDL_SetWindowFullscreen(%p, %d) -> %d", window, (int)fullscreen, (int)r);
    return r;
}

// SDL_PollEvent：MC 渲染线程每帧调用，是"事件泵活着"的最强证据，也是
// 捕获 QUIT / 窗口关闭事件的唯一位置。日志策略（避免爆炸）：
//   - QUIT 类（0x100-0x10F，含 SDL_EVENT_QUIT/TERMINATING/LOW_MEMORY/后台切换）
//     与窗口类（0x200-0x20F，含 CLOSE_REQUESTED/SHOWN/HIDDEN/RESIZED/FOCUS）：
//     每一条都打
//   - 其余类型（我们注入的 0x300 键 / 0x400 鼠标等高频事件）：前 30 条逐条打，
//     之后每 500 条打 1 条采样
//   - 无事件（返回 false）不打
//
// Task 56（退后台/切窗"崩溃"根治，1bd9f32 日志取证 + client.jar 反编译定案）：
//   MC 26.3 经 LWJGL 3.4.1（SDL 3.4.x 枚举）把 SDL_EVENT_WINDOW_MINIMIZED(0x209)
//   交给 Window.handleEvent → onIconified(true) → Minecraft.createSurface 传给
//   renderpearl 的 BooleanSupplier 就是 window::isIconified（反编译实锤）→
//   GlSurface.acquireNextTexture 见 iconified 即抛 SurfaceException("Cannot
//   acquire minimized window")。renderFrame 虽 catch 住了异常，但随即置
//   surfaceIsInvalid=true + windowSurfaceNeedsReconfiguring=true；回前台后
//   configure() 在同一 CAMetalLayer 上二次建 EGL window surface 必败
//   EGL_BAD_ALLOC（Task50 实证）→ 表面永久失效 → 游戏冻结/黑屏 = 用户看到的
//   "崩溃"。本移植里真正的呈现面是宿主 GameSurfaceView 的 CAMetalLayer，
//   SDL 窗口只是被隐藏的"事件壳"（Task32 embed）——它"最小化"纯属谎言：
//   画面根本不在那个窗口里，呈现面在退后台前后始终有效。
//   修复：在事件出口掐断 MINIMIZED(0x209)，MC 永不进入 iconified 状态，
//   后台/前台往返零异常风暴、零表面失效。MAXIMIZED(0x20a)/RESTORED(0x20b)
//   仍放行（它们调 onIconified(false)，是纵深防御）。
static bool ame_SDL_PollEvent(void *event) {
    if (!ame_real_PollEvent) return false;
    for (;;) {
        bool r = ame_real_PollEvent(event);
        if (!r || event == NULL) return r;
        uint32_t type = *(const uint32_t *)event;
        if (type == 0x209) {  // SDL_EVENT_WINDOW_MINIMIZED（SDL 3.4.0 实测枚举）
            static _Atomic unsigned long s_minDropCount = 0;
            unsigned long dn = atomic_fetch_add(&s_minDropCount, 1) + 1;
            if (dn <= 10 || dn % 50 == 0) {
                NSDebugLog(@"[SDLHook] Task56 drop SDL_EVENT_WINDOW_MINIMIZED #%lu (iconified 源头掐断：宿主 CAMetalLayer 仍可呈现)", dn);
            }
            continue;  // 丢弃，取下一条
        }
        // ---------------------------------------------------------------
        // Task 61（SDL3 路径分辨率根因修复）：uikit 驱动的窗口事件以“点”为
        // 单位——RESIZED(0x207) 携带 Task51 钳制后的 1180x820 点，MC 26.3 按
        // 像素语义消费（本会话仅此一条尺寸事件，44fef06 实测）→ 渲染分辨率
        // 压半。改写 data1/data2 为启动器像素口径 windowWidth×windowHeight
        // （== launchJVM 告知 == EGL surface(Task60) == MC 输入基准(Task59)）。
        // PIXEL_SIZE_CHANGED(0x208) 同改（防御性：uikit 当前不发此事件，若
        // 未来 SDL 版本发出，两路口径仍一致）。SDL_WindowEvent 布局：
        // type@0 reserved@4 timestamp@8 windowID@16 data1@20 data2@24（与
        // 0x400 鼠标事件 x/y@28/32 同系布局，input_bridge_v3.m 推送侧互证）。
        // ---------------------------------------------------------------
        if (type == 0x207 /*SDL_EVENT_WINDOW_RESIZED*/ ||
            type == 0x208 /*SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED*/) {
            int d61a = *(int *)((char *)event + 20);
            int d61b = *(int *)((char *)event + 24);
            if (windowWidth > 0 && windowHeight > 0 &&
                (d61a != windowWidth || d61b != windowHeight)) {
                *(int *)((char *)event + 20) = windowWidth;
                *(int *)((char *)event + 24) = windowHeight;
                static _Atomic unsigned long s_task61_rewrites = 0;
                unsigned long rn61 = atomic_fetch_add(&s_task61_rewrites, 1) + 1;
                if (rn61 <= 20 || rn61 % 500 == 0) {
                    NSLog(@"[SDLHook] Task61 window-size event 0x%x rewritten: %dx%d -> %dx%d (pts->px; UIKit window untouched, MC renders native res)",
                          type, d61a, d61b, windowWidth, windowHeight);
                }
            }
        }
        if ((type >= 0x100 && type <= 0x10F) || (type >= 0x200 && type <= 0x20F)) {
            if (type >= 0x200 && type <= 0x20F) {
                int wd1 = *(const int *)((const char *)event + 20);
                int wd2 = *(const int *)((const char *)event + 24);
                NSDebugLog(@"[SDLHook] SDL_PollEvent got type=0x%x data1=%d data2=%d (window-class, Task32/61 forensics)",
                           type, wd1, wd2);
            } else {
                NSDebugLog(@"[SDLHook] SDL_PollEvent got type=0x%x (quit-class, Task32)", type);
            }
        } else {
            static _Atomic unsigned long s_pollCount = 0;
            unsigned long n = atomic_fetch_add(&s_pollCount, 1) + 1;
            // Task64：键盘类事件（0x300 KEY_DOWN / 0x301 KEY_UP）单独计数并
            // 逐条记录（虚拟控件按键是离散低频事件，不会刷屏；旧采样窗口
            // n<=30/%500 基本永远漏掉键盘事件——上一轮日志只看到 sendKey 入口
            // 与 mouse consumed，键盘消费侧完全不可见，"移动键是否送达 MC"
            // 无法裁定）。布局与 input_bridge_v3.m 推送侧 SDL3_KeyboardEvent
            // 一致：scancode@24(int) key@28(u32) down@36(bool)。
            if (type == 0x300 || type == 0x301) {
                static _Atomic unsigned long s_task64KeyCount = 0;
                unsigned long kn = atomic_fetch_add(&s_task64KeyCount, 1) + 1;
                if (kn <= 50 || kn % 100 == 0) {
                    int ksc = *(const int *)((const char *)event + 24);
                    uint32_t kkey = *(const uint32_t *)((const char *)event + 28);
                    uint8_t kdown = *(const uint8_t *)((const char *)event + 36);
                    // Task65：附带 windowID@16 —— 与 GetWindowFromEvent 钩子的
                    // 解析观测对证（推送侧 windowID 是否始终正确）。
                    uint32_t kwid = *(const uint32_t *)((const char *)event + 16);
                    NSDebugLog(@"[SDLHook] Task64 key consumed #%lu type=0x%x scancode=%d key=%u down=%d windowID=%u (MC-side)",
                               (unsigned long)kn, type, ksc, kkey, kdown, (unsigned)kwid);
                }
            } else if (n <= 30 || n % 500 == 0) {
                // Task59：鼠标类事件附带坐标——0x400 motion / 0x401 button down /
                // 0x402 button up 的 x/y 同在偏移 28/32（与 input_bridge_v3.m 推送
                // 用的 SDL3 结构体布局一致）。直接观测“MC 实际消费的鼠标坐标”，
                // 与 InputDiag sendCursorPos（入口）逐值对照，闭环输入对齐取证。
                if (type >= 0x400 && type <= 0x402) {
                    float ex = *(const float *)((const char *)event + 28);
                    float ey = *(const float *)((const char *)event + 32);
                    NSDebugLog(@"[SDLHook] Task59 mouse consumed #%lu type=0x%x x=%.1f y=%.1f (MC-side coords)",
                               (unsigned long)n, type, ex, ey);
                } else {
                    NSDebugLog(@"[SDLHook] SDL_PollEvent #%lu type=0x%x (sampled, event loop alive)",
                               (unsigned long)n, type);
                }
            }
        }
        return r;
    }
}

#pragma mark - 7) Amethyst embed：把 SDL UIKit 视图嵌入宿主层级（Task 32 黑屏修复）

// ============================================================================
// 黑屏根因（Task 32，经反汇编实锤）：
//   patches/sdl3-amethyst.patch 描述了 "embed SDL view into host window" 设计，
//   但随包发布的 libSDL3.dylib 只包含最小补丁（Amethyst_SetSDLWindow 的
//   dlsym 注册有代码引用；embed 相关字符串——ControlLayout / GameSurfaceView /
//   [AmethystSDL] 各日志——全部是零引用的孤儿字符串）。
//   结果：GL 路径（MobileGlues/gl4es/Mithril/MobileGL）下 MC 通过我们的
//   EGL bridge 渲染进 GameSurfaceView 的 CAMetalLayer；而 MC 建窗后调用
//   SDL_ShowWindow 时，原生 UIKit_ShowWindow 会 makeKeyAndVisible SDL 自己的
//   UIWindow——一个没有任何渲染内容的窗口——盖在 GameSurfaceView 上 = 全黑。
//   zink/Vulkan 路径不受影响：Vulkan surface 建在 SDL 窗口自己的 view 上，
//   内容就渲染进那个"盖子"里，所以那条路径历史上可见。
//
// 修复（在启动器侧实现 patch 的 embed 设计）：
//   1) 首个真实 SDL_CreateWindow 返回后，找到 SDL 的 UIWindow
//      （rootViewController 类名含 SDL_uikitviewcontroller）；
//   2) 把它的 view 嵌入宿主 touchView（GameSurfaceView 之上）。
//      与 patch 的差异：不隐藏 GameSurfaceView —— 我们的 GL 渲染目标正是
//      它的 layer；SDL 视图保持透明让画面透出来；
//   3) 隐藏 SDL 自己的 UIWindow，此后 SDL_ShowWindow 被本钩子接管
//      （embedded 分支只 re-front 嵌入视图，绝不再 makeKeyAndVisible）；
//   4) 运行时给 SDL 视图类补 hitTest:withEvent: -> nil（与 patch 一致：
//      触摸全部回落给 touchView，由启动器输入桥处理，避免 SDL 自己
//      的 UIKit 触摸处理与启动器手势双路冲突）。
//   附加收益：SurfaceViewController::findSDL_uikitview（键盘事件转发）
//      从此能在 self.view 层级里找到 SDL 视图 —— 物理键盘开始工作。
// ============================================================================

// static UIView *ame_embeddedSDLView = NULL;  // 已提前声明于文件头部（供 ShowWindow/CreateWindow 钩子使用）

static UIView *ame_findSubviewOfClass(UIView *root, Class cls) {
    if (cls == nil) return nil;
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = ame_findSubviewOfClass(sub, cls);
        if (found) return found;
    }
    return nil;
}

// Task 49：旧的 hitTest 穿透 shim 已移除——MC 26.3 输入走 SDL3 事件泵，
// 触摸必须命中 SDL 视图（详见 ame_embedSDLViewIntoHost 步骤 4 注释）。

// 只在主线程调用。返回 true 表示嵌入成功。
static bool ame_embedSDLViewIntoHost(void) {
    @autoreleasepool {
        // 1. 定位 SDL 自己的 UIWindow（rootViewController 为 SDL_uikitviewcontroller）
        UIWindow *sdlWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            UIViewController *rc = w.rootViewController;
            if (rc != nil &&
                [NSStringFromClass(rc.class) rangeOfString:@"SDL_uikitviewcontroller"].location != NSNotFound) {
                sdlWindow = w;
                break;
            }
        }
        if (sdlWindow == nil) {
            NSLog(@"[AmethystEmbed] no SDL UIWindow found in %lu app windows (embed skipped)",
                  (unsigned long)[UIApplication sharedApplication].windows.count);
            return false;
        }
        UIView *sdlView = sdlWindow.rootViewController.view;
        if (sdlView == nil) {
            NSLog(@"[AmethystEmbed] SDL window %p has no view (embed skipped)", (__bridge void *)sdlWindow);
            return false;
        }
        NSLog(@"[AmethystEmbed] SDL window=%p view=%p class=%@ frame=%@",
              (__bridge void *)sdlWindow, (__bridge void *)sdlView, NSStringFromClass(sdlView.class),
              NSStringFromCGRect(sdlView.frame));

        // 2. 定位宿主游戏区：任何非 SDL 窗口里的 GameSurfaceView，其 superview 即 touchView
        UIView *gameSurface = nil;
        UIWindow *hostWindow = nil;
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (w == sdlWindow) continue;
            UIView *found = ame_findSubviewOfClass(w, NSClassFromString(@"GameSurfaceView"));
            if (found != nil) {
                gameSurface = found;
                hostWindow = w;
                break;
            }
        }
        if (gameSurface == nil || gameSurface.superview == nil) {
            NSLog(@"[AmethystEmbed] GameSurfaceView not found in host windows (embed failed: is SurfaceViewController presented?)");
            return false;
        }
        UIView *touchView = gameSurface.superview;

        // 3. Task 52（黑屏本因根治）：供应商 libSDL3.dylib 打了 Zalith 同源嵌入
        //    补丁（UIKit_CreateWindow → Amethyst_CreateWindowOnMain →
        //    Amethyst_EmbedSDLViewIntoHostWindow，反汇编实锤 @0x152e6c），
        //    它在自己的嵌入流程里按类名找到 GameSurfaceView 并执行
        //    [GameSurfaceView setHidden:YES] —— 因为 Zalith 架构里 SDL 的
        //    metal view 才是渲染目标。但本启动器 GL/EGL 与 Vulkan/MoltenVK
        //    的渲染目标恰恰是 GameSurfaceView 的 CAMetalLayer：帧全部呈现
        //    进一个被隐藏的 layer = 渲染指标全绿 + 永久黑屏（Task 48-51 的
        //    几何修复治标不治本的真正原因）。其 NSLog 是真 NSLog（本 app 把
        //    NSLog 宏重定义为 printf），所以 latestlog 里完全不可见。
        //    本嵌入后于它运行（真 SDL_CreateWindow 返回之后），此处揭开并
        //    钉住层级；gl_bridge 的每帧卫兵（Task52 guard）负责持续执法。
        BOOL task52WasHidden = gameSurface.hidden || gameSurface.layer.hidden;
        gameSurface.hidden = NO;
        gameSurface.layer.hidden = NO;
        // 3.5 嵌入：SDL 视图置于 touchView 内（GameSurfaceView 之上），保持透明。
        //    不隐藏 GameSurfaceView —— GL 路径下它是真正的渲染呈现层。
        [sdlView removeFromSuperview];
        sdlView.frame = touchView.bounds;
        sdlView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        sdlView.backgroundColor = nil;
        sdlView.opaque = NO;
        [touchView addSubview:sdlView];
        // 把 touchView 里其它子视图（虚拟鼠标指针等）重新压到 SDL 视图之上。
        // Task 52：GameSurfaceView 除外 —— 它必须保持在 SDL 触摸视图之下
        //（画面在下、触摸层在上；旧循环把它也压到顶，只因当时它已被供应商
        //  补丁藏起来而 hitTest 跳过、侥幸不挡输入）。
        for (UIView *sub in [touchView.subviews copy]) {
            if (sub != sdlView && sub != gameSurface) [touchView bringSubviewToFront:sub];
        }
        // Task 52：z 序终局钉扎 —— GameSurfaceView 紧贴 SDL 触摸视图之下
        //（两个嵌入的 re-front 循环都可能把它抬到 SDL 视图之上）。
        [touchView insertSubview:gameSurface belowSubview:sdlView];
        if (task52WasHidden) {
            NSLog(@"[AmethystEmbed] Task52: GameSurfaceView was HIDDEN by SDL provider embed patch -- UN-HIDDEN and pinned below SDL touch view (it is our render target; black-screen root cause fixed)");
        }

        // 4. Task 49：不再安装 hitTest 穿透 shim。
        //    旧设计把 SDL 视图的 hitTest 返回 nil，让触摸落到 touchView，走
        //    Pojav 的 GLFW 回调链。但 latestlog 53febda 铁证：该链已死
        //    （InputDiag sendCursorPos GLFW_invoke_CursorPos=0x0、isInputReady=0，
        //    触摸全部丢弃），而 MC 26.3 的输入走 SDL3 事件泵（SDL_EVENT_*，
        //    需要触摸命中 SDL 视图）。移除 shim 后：触摸命中 SDL 视图 →
        //    SDL3 合成 finger/mouse 事件 → MC 输入恢复；虚拟鼠标指针等
        //    touchView 子视图已在步骤 3 压回 SDL 视图之上，控制按钮不受影响；
        //    touchView 上的手势识别器仍能观察子视图触摸（UIKit 语义）。
        NSLog(@"[AmethystEmbed] hitTest shim NOT installed (Task49: SDL3 native input needs real touches)");

        // 5. SDL 自己的 UIWindow 退场（永远隐藏；ShowWindow 钩子不再 makeKeyAndVisible）
        sdlWindow.hidden = YES;

        ame_embeddedSDLView = sdlView;
        NSLog(@"[AmethystEmbed] SUCCESS: SDL view embedded into host touchView=%@ (window=%p); GameSurfaceView kept VISIBLE (GL render target); SDL UIWindow hidden",
              NSStringFromClass(touchView.class), (__bridge void *)hostWindow);
        return true;
    }
}

static void ame_refrontEmbeddedViewOnMain(void) {
    UIView *v = ame_embeddedSDLView;
    if (v == nil) return;
    // 1. 重新隐藏任何被真实 ShowWindow 重新显示的 SDL UIWindow，并恢复宿主 key window
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *rc = w.rootViewController;
        if (rc != nil &&
            [NSStringFromClass(rc.class) rangeOfString:@"SDL_uikitviewcontroller"].location != NSNotFound &&
            !w.hidden) {
            w.hidden = YES;
            // key window 可能刚被切到这个即将隐藏的窗口上，挑一个可见的宿主窗口按回去
            for (UIWindow *w2 in [UIApplication sharedApplication].windows) {
                if (w2 != w && !w2.hidden && w2.rootViewController != nil) {
                    [w2 makeKeyWindow];
                    break;
                }
            }
        }
    }
    // 2. 在宿主容器里 re-front 嵌入视图，并把容器内其它子视图（虚拟鼠标指针等）压在上面
    UIView *container = v.superview;
    if (container == nil) return;
    [v removeFromSuperview];
    [container addSubview:v];
    // Task 52：GameSurfaceView 不参与 re-front（画面层必须保持在触摸层之下）
    UIView *task52GS = ame_findSubviewOfClass(container, NSClassFromString(@"GameSurfaceView"));
    for (UIView *sub in [container.subviews copy]) {
        if (sub != v && sub != task52GS) [container bringSubviewToFront:sub];
    }
    // Task 52：揭 hide + z 序钉扎（SDL 供应商补丁的 ShowEmbeddedTask / 任何
    // 后续嵌入重跑都可能再次 setHidden:YES —— 见 ame_embedSDLViewIntoHost 步骤 3 注释）
    if (task52GS != nil && task52GS != v) {
        if (task52GS.hidden || task52GS.layer.hidden) {
            task52GS.hidden = NO;
            task52GS.layer.hidden = NO;
            NSLog(@"[AmethystEmbed] Task52 re-front: GameSurfaceView re-hidden by external code -- UN-HIDDEN again");
        }
        if (task52GS.superview == container &&
            [container.subviews indexOfObjectIdenticalTo:task52GS] > [container.subviews indexOfObjectIdenticalTo:v]) {
            [container insertSubview:task52GS belowSubview:v];
        }
    }
}

/// Task224：公开包装——后台恢复链（CallbackBridge_resumeGameIfNeed）在
/// SDL/MC 焦点态重建后调用，把嵌入视图 z 序与宿主 key window 再钉一遍。
/// 病历：后台化期间 SDL UIKit 的窗口操作可能打乱 z 序/焦点；此前只有
/// ShowWindow 钩子路径会修（游戏主动 ShowWindow 时），后台恢复链无人
/// 调用 = "MG 后台回来后屏幕无法输入"的候选根因之一。自带主线程调度。
void ame224_refrontEmbeddedViewSafe(void) {
    if (ame_embeddedSDLView == nil) return;
    if ([NSThread isMainThread]) {
        ame_refrontEmbeddedViewOnMain();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            ame_refrontEmbeddedViewOnMain();
        });
    }
}

/// Task 52：gl_bridge 的每帧可见性卫兵需要拿到嵌入的 SDL 触摸视图（z 序执法）。
/// 返回裸指针（__bridge，不转移所有权；调用方只做只读比较，不当 ARC 对象持有）。
void *ame_hook_getEmbeddedSDLView(void) {
    return (__bridge void *)ame_embeddedSDLView;
}

#pragma mark - Task 114：文本输入主线程化 + 启动器 hint（键盘自动弹出修复）

// Task172 病历（760c07c 装机 latestlog.old.txt，26.3 多人会话键盘段）：
//   用户反馈"键盘输入依旧异常"——每次按 ✎ 输入法按钮日志都是
//   "becomeFirstResponder=1"（而非 "dismissing"）= 启动器字段反复丢失
//   first responder；字符全部经启动器字段（Task82 pushSDLTextInput）到达
//   MC，而 SDL 自己的 UIKit textField 一条都没送达。机理：MC 26.3 的
//   EditBox 聚焦时调用 SDL_StartTextInputWithProperties → SDL 的 iOS 后端
//   把自己的 textField（位于被 Task32 隐藏的 SDL UIWindow 里）立为
//   first responder、抢走启动器字段——但它的文本投递链在本嵌入架构下
//   不可靠，用户的击键石沉大海，直到再按一次 ✎ 把启动器字段抢回来。
//   Task171 的哨兵空格 + 自愈重挂只治了启动器字段的会话竞争，治不了
//   SDL 字段的反复抢占（自愈重挂零触发即为证据）。
//   修法：Start/Stop 钩子在真实调用之后追加通知（AME172_SDLStartTextInput /
//   AME172_SDLStopTextInput），SurfaceViewController 收到后把 inputTextField
//   立为/退出 first responder——真实调用保持 SDL 内部状态一致，通知保证
//   键盘服务的是经过验证的启动器投递链；Stop 时同步收起，键盘不再滞留。
//   通知在本钩子的主队列 block 内同步派发，顺序必然在 SDL UIKit 操作之后
//   （启动器字段稳赢 first responder 竞争）。

// 病历（用户反馈：输入框有闪竖线时键盘不自动弹出；上游正常）：
//   (1) MC 26.x 桌面惯例在 SDL_Init 前把 SDL_ENABLE_SCREEN_KEYBOARD 设为 0
//      （自绘 IME UI 用），移动端恰恰依赖 SDL 唤起系统软键盘——不覆盖回来，
//      EditBox 聚焦（游戏内光标闪烁）时 SDL 的 iOS 后端不会拉起键盘。
//      上游在 InitSubSystem 钩子里把该 hint 覆盖回 "1"（实测有效，设备日志
//      "[SDLHook] hooked SDL_InitSubSystem -> launcher hints"）。
//   (2) SDL 的 iOS 后端在 SDL_StartTextInputWithProperties 里直接操作 UIKit
//      （-[SDL_uikitviewcontroller setTextFieldProperties:]）。MC 从渲染线程
//      调用它，出现 "modifying the autolayout engine from a background thread"
//      ——异常虽被 SDL 侧 catch，但布局未完成，软键盘行为不可预期。
//      修法：非主线程就 dispatch 到主线程执行。文本输入低频，用 async 避免阻塞
//      渲染线程（也避免主线程同步等待造成死锁）。
static bool ame_dispatchTextInputToMain(void (^work)(void)) {
    if (work == nil) return false;
    if ([NSThread isMainThread]) {
        work();
        return true;
    }
    dispatch_async(dispatch_get_main_queue(), work);
    return true;
}

static bool ame_SDL_StartTextInput(void *window) {
    return ame_dispatchTextInputToMain(^{
        if (ame_real_StartTextInput != NULL) ame_real_StartTextInput(window);
        // Task172：路由到启动器输入框（见下方 Task172 病历注释）
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AME172_SDLStartTextInput" object:nil];
    });
}

static bool ame_SDL_StartTextInputWithProperties(void *window,
                                                 unsigned long long props) {
    return ame_dispatchTextInputToMain(^{
        if (ame_real_StartTextInputWithProperties != NULL) {
            ame_real_StartTextInputWithProperties(window, props);
        }
        // Task172：真实调用先行（SDL 内部状态保持一致），随后启动器字段
        // 抢占 first responder——SDL UIKit 自己的 textField 位于被隐藏的
        // SDL UIWindow 里，其文本投递链在本嵌入架构下不可靠。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AME172_SDLStartTextInput" object:nil];
    });
}

static bool ame_SDL_StopTextInput(void *window) {
    return ame_dispatchTextInputToMain(^{
        if (ame_real_StopTextInput != NULL) ame_real_StopTextInput(window);
        // Task172：MC 关闭文本上下文（聊天发送/ESC）时同步收起启动器字段，
        // 键盘跟随 MC 的输入状态而非永久滞留。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"AME172_SDLStopTextInput" object:nil];
    });
}

static bool ame_SDL_OpenURL(const char *url) {
    // ★ Task227（反馈 #5：SDL 版本打开文件夹无反应）：MC 26.3 的
    // Blaze3D.openUri 走 org.lwjgl.sdl.SDLMisc.SDL_OpenURL（26.3 jar
    // 常量池实证），不走 java.awt.Desktop/CTC 桥——SDL 自带的 iOS
    // openURL 对沙盒内 file:// 目录返回失败（ef1e3e2a 装机铁证：
    // [Download-3/WARN] "Failed to open uri file:///...resourcepacks/:
    // No handler registered for this type of URL" ×6，用户点击零反应）。
    // 修法：钩住 SDL_OpenURL——file:// 目录路由到应用内 FolderBrowser
    // （同 CTC openFile 链），http(s) 路由到系统浏览器，其余交回真实现。
    if (url == NULL) return ame_real_OpenURL ? ame_real_OpenURL(NULL) : false;
    NSString *ame227_url = [NSString stringWithUTF8String:url];
    NSLog(@"[SDLHook] Task227 SDL_OpenURL intercepted: %@", ame227_url);
    if ([ame227_url hasPrefix:@"file:"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            // 复用 CTC 链同源路由（input_bridge 的 openURLGlobal：
            // 目录 → FolderBrowser，文件 → Files/Filza；主线程派发）。
            extern void openURLGlobal(NSString *path);
            openURLGlobal(ame227_url);
        });
        return true;   // 对 MC 报成功——浏览器已异步拉起，不再走 SDL 失败路径
    }
    if ([ame227_url hasPrefix:@"http:"] || [ame227_url hasPrefix:@"https:"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            extern void openURLGlobal(NSString *path);
            openURLGlobal(ame227_url);
        });
        return true;
    }
    return ame_real_OpenURL ? ame_real_OpenURL(url) : false;
}

static bool ame_SDL_SetTextInputArea(void *window, const void *rect, int cursor) {
    // rect 由调用方栈上持有，且 block 是异步执行的 —— 不能把局部变量的地址
    // 传进 block（函数返回后失效）。改堆分配，由 block 在使用后释放。
    ame_SDLRect *heapRect = NULL;
    if (rect != NULL) {
        heapRect = (ame_SDLRect *)malloc(sizeof(ame_SDLRect));
        if (heapRect != NULL) memcpy(heapRect, rect, sizeof(ame_SDLRect));
    }

    if ([NSThread isMainThread]) {
        bool r = ame_real_SetTextInputArea != NULL
                     ? ame_real_SetTextInputArea(window, heapRect, cursor)
                     : false;
        free(heapRect);
        return r;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (ame_real_SetTextInputArea != NULL) {
            ame_real_SetTextInputArea(window, heapRect, cursor);
        }
        free(heapRect);
    });
    return true;
}

// hint 必须在 SDL_Init 之前设置才生效，因此挂在 InitSubSystem 上、在调用
// 原函数之前设置（与上游 caf6822 的做法逐字对齐）：
//   SDL_RETURN_KEY_HIDES_IME       启动器的正常行为（SDL 默认 false）
//   SDL_ENABLE_SCREEN_KEYBOARD=1   覆盖 MC 的桌面惯例 0（见上方病历第 1 条）
//   SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER=0
//                                  转译型渲染器（gl bridge）无法传入正确的
//                                  EGL 参数支持它；仅对走 EGL bridge 的渲染器关闭
// Task172 补充：SDL_ENABLE_SCREEN_KEYBOARD=1 保留不动（MC 的
// HasScreenKeyboardSupport 查询仍报“有”）；键盘由 AME172_SDLStartTextInput
// 通知路由到启动器自己的 inputTextField（见 ame_SDL_StartTextInput* 注释）。
static bool ame_SDL_InitSubSystem(uint32_t flags) {
    if (ame_real_SetHint == NULL) {
        ame_real_SetHint = (ame_fn_SDL_SetHint)ame_real_dlsym("SDL_SetHint");
    }
    if (ame_real_SetHint != NULL) {
        ame_real_SetHint("SDL_RETURN_KEY_HIDES_IME", "true");
        if (ame_glBridgeEnabled()) {
            ame_real_SetHint("SDL_OPENGL_FORCE_SRGB_FRAMEBUFFER", "0");
        }
        ame_real_SetHint("SDL_ENABLE_SCREEN_KEYBOARD", "1");
        NSDebugLog(@"[SDLHook] Task114 SDL hint set (screenKeyboard=1, srgb=%s)",
                   ame_glBridgeEnabled() ? "off" : "default");
    }
    if (ame_real_InitSubSystem != NULL) {
        return ame_real_InitSubSystem(flags);
    }
    return false;
}

#pragma mark - 对 main_hook.m 的接入点

/// 由 hooked_dlsym 在返回 orig_dlsym 之前调用。
/// 返回非 NULL 表示本模块接管了该符号；否则返回 NULL 让调用方走原路径。
// ---------------------------------------------------------------------------
// Task 131：SDL 事件回调入口拦截（26.1.2 整合包 controlify 崩溃根治）
//
// 事故链（1d4082f 装机日志 latestlog.old.txt，SIGBUS at pc=0x12e550010）：
//   1. 26.1.2 整合包含 controlify 3.0.1（26.3 包不含——两包同构建对照的
//      唯一差异面），其依赖 dev_isxander:libsdl4j 经 JNA 加载 SDL3；
//   2. controlify.jar 内嵌 darwin-aarch64/libSDL3.dylib（macOS 构建，链接
//      Cocoa/AppKit/Carbon/ForceFeedback——iOS 上不存在，dlopen 必败），
//      JNA 解包尝试失败后按名字回退 dlopen("libSDL3.dylib") -> rpath 命中
//      本启动器 Frameworks 里的 iOS 版 libSDL3.dylib（LWJGL 已加载的同一
//      实例；日志中两行 NativeLibrary + 一行 Structure 的 Platform.isMac
//      调用轨迹与此一致）；
//   3. SDL_Init 成功（子系统引用计数叠加）后，SDLControllerManager 构造
//      调 SDL_SetEventFilter(JNA closure, NULL)——JNA 把 Java 回调包装成
//      libffi closure，其 trampoline 页在无 JIT 权限的 iOS 进程里只能是
//      RW 不可执行；
//   4. 本启动器游戏侧每帧 pojavPumpEvents -> SDL_PumpEvents -> SDL 内部
//      SDL_PushEvent 触发事件过滤器 -> 跳进 0x12e550010 的 RW trampoline
//      -> ARM64 Darwin 对"执行不可执行页"投递 SIGBUS（PC=页基址+0x10，
//      恰为 trampoline 入口布局），JVM 致命错误退出。
//
// 修复：在 dlsym 解析层把 SDL_SetEventFilter / SDL_AddEventWatch 替换为
// no-op（按名字分发，LWJGL 与 JNA 的符号解析都会命中；SDL 内部自调用不经
// dlsym，不受影响）。controlify 的热插拔事件仍经 SDL_PollEvent 轮询送达
// （其 tick() 主路径），仅失去"过滤器即时消费"这一优化路径，功能不受损。
// 启动器自身与 MC/LWJGL 均不使用事件过滤器（全仓 grep 验证），零误伤。
// ---------------------------------------------------------------------------
static bool ame_SDL_SetEventFilter(void *filter, void *userdata) {
    (void)filter; (void)userdata;
    static bool ame131_logged = false;
    if (!ame131_logged) {
        ame131_logged = true;
        NSLog(@"[SDLHook] Task131: SDL_SetEventFilter(%p) blocked -- callback points into a "
              @"JNA/libffi closure, which is not executable on iOS (no JIT entitlement); "
              @"hotplug events still arrive via SDL_PollEvent", filter);
    }
    return true; // 假装注册成功，调用方（controlify）不会因此走异常路径
}

static void ame_SDL_AddEventWatch(void *filter, void *userdata) {
    (void)filter; (void)userdata;
    static bool ame131_logged = false;
    if (!ame131_logged) {
        ame131_logged = true;
        NSLog(@"[SDLHook] Task131: SDL_AddEventWatch(%p) blocked -- same JNA closure "
              @"non-executable reason as SDL_SetEventFilter", filter);
    }
}

// ---------------------------------------------------------------------------
// Task 132：libjnidispatch 的 _dlsym 槽位重绑定（26.1.2 整合包 controlify/
// JNA closure SIGBUS 的补完，43ef4ae 装机日志定案）
//
// Task131 的守卫拦在 dlsym 解析层（下方 amethyst_sdl3_hook_resolve 按名
// 分发 SDL_SetEventFilter / SDL_AddEventWatch），LWJGL 路径由此根治——
// LWJGL 经启动器进程自己的 dlsym 调用链取符号，该链路被 init_hookFunctions
// 的 fishhook 重绑定覆盖。但 43ef4ae 崩溃会话（26.1.2 整合包，SIGBUS at
// pc=0x1167b8010，native 栈 0x163e70a84 递归闭包帧）证明 JNA 路径漏网：
//   controlify 3.0.1 -> libsdl4j 3.2.18 -> JNA NativeLibrary dlopen 命中
//   Frameworks 的 iOS libSDL3.dylib 后，libjnidispatch 内部经【它自己的
//   __la_symbol_ptr 槽】调用 dlsym 解析 SDL_SetEventFilter——该槽属于后续
//   dlopen 的新 image，init_hookFunctions 传的是栈上 rebindings 数组，
//   其对后续 image 的重绑定不可依赖（同会话里 LWJGL 被拦、JNA 未被拦的
//   分裂行为与栈数组生命周期解释一致）。于是 JNA 拿到真函数，把 Java
//   回调闭包注册进 SDL；SDL3 的 SDL_SetEventFilter 注册即对 pending 队列
//   逐事件同步调用 filter -> 跳进 RW 不可执行的 libffi trampoline 页
//   -> SIGBUS（崩溃日志最后三行 "Initializing Controlify..." /
//   "[SDLNativesLoader] Attempting to load SDL3 from SDL3" /
//   "Platform.isMac called from com.sun.jna.Structure" 与该链完全吻合，
//   且全篇没有 Task131 守卫日志 = JNA 的符号解析根本没进过 hook）。
//
// 修复：hooked_dlopen 检出 libjnidispatch 加载（JVM 的 System.load 走被
// hook 的 dlopen——Task106 的 libasyncProfiler 拦截已在装机日志实证同一
// 链路），真实 dlopen 返回后立即遍历该 image 的间接符号表，把
// __la_symbol_ptr（S_LAZY_SYMBOL_POINTERS）/ __got（S_NON_LAZY_SYMBOL_
// POINTERS）中符号名为 _dlsym 的指针槽改写为传入的 hook 函数（main_hook.m
// 的 hooked_dlsym）。此后 JNA 的一切符号解析都先进 amethyst_sdl3_hook_
// resolve：Task131 守卫对 JNA 路径同样生效（SDL_SetEventFilter /
// SDL_AddEventWatch 换成 no-op 守卫），真 SDL_ 符号照常透传，非 SDL 符号
// 原样回落，零误伤。
//
// 实现细节（jna-5.13.0 darwin-aarch64 libjnidispatch 二进制实测）：
//   - 传统 LC_DYLD_INFO 布局（无 chained fixups）；_dlsym 间接表项 2 处
//     （__stubs 代码段符号引用 + __la_symbol_ptr 指针槽），真正的指针槽
//     位于可写 __DATA——改写后经 stub 的调用全部改道；
//   - __LINKEDIT 基址换算用 fishhook 同款算法（slide + vmaddr - fileoff），
//     不假设 vmaddr == fileoff；
//   - 页大小取运行时 sysconf(_SC_PAGESIZE)（arm64 iOS 为 16KB，硬编码
//     4096 会让 vm_protect 失败）；
//   - vm_protect 用 RW|COPY（fishhook 同款，对已可写页无副作用），不恢复
//     原保护——与既有 zink 重绑定路径行为一致；
//   - 幂等：槽位已是目标值时跳过（JNA 重复加载同一 image 安全）。
// ---------------------------------------------------------------------------
// Task 134：核心重绑定——直传 hdr+slide，返回【读回验证过】的槽数。
// 病历（df10f70/3756a05 双会话实证）：本函数被调用后【零输出】——旧实现
// 唯一无日志的提前返回是句柄重查失败（ame132_hdr == NULL）。Task133 的
// 扫描刚从 _dyld_get_image_header(i) 拿到该指针，函数内重查却拿不到
// （dyld 列表并发加载窗口的可见性问题）。修复：扫描侧直接传 hdr+slide
// 消灭重查；所有提前返回落日志；未验证的绑定由看门狗每 200ms 重试。
static int amethyst_task132_rebind_jna_dlsym_ex(const struct mach_header_64 *ame132_hdr,
                                                intptr_t ame132_slide,
                                                void *hook_fn) {
    if (ame132_hdr == NULL || hook_fn == NULL) {
        NSLog(@"[SDLHook] Task134: jna rebind rejected null args (hdr=%p hook=%p)",
              (void *)ame132_hdr, hook_fn);
        return 0;
    }
    if (ame132_hdr->magic != MH_MAGIC_64) {
        NSLog(@"[SDLHook] Task134: jna rebind bad magic %08x", ame132_hdr->magic);
        return 0;
    }

    // 第一遍：收集 SYMTAB / DYSYMTAB / __LINKEDIT 定位信息
    struct symtab_command ame132_symtab;
    struct dysymtab_command ame132_dysym;
    memset(&ame132_symtab, 0, sizeof(ame132_symtab));
    memset(&ame132_dysym, 0, sizeof(ame132_dysym));
    uint64_t ame132_le_vmaddr = 0, ame132_le_fileoff = 0;
    bool ame132_has_symtab = false, ame132_has_le = false;
    const struct load_command *ame132_cmd =
        (const struct load_command *)(ame132_hdr + 1);
    for (uint32_t c = 0; c < ame132_hdr->ncmds; c++) {
        if (ame132_cmd->cmd == LC_SYMTAB) {
            ame132_symtab = *(const struct symtab_command *)ame132_cmd;
            ame132_has_symtab = true;
        } else if (ame132_cmd->cmd == LC_DYSYMTAB) {
            ame132_dysym = *(const struct dysymtab_command *)ame132_cmd;
        } else if (ame132_cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)ame132_cmd;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                ame132_le_vmaddr = seg->vmaddr;
                ame132_le_fileoff = seg->fileoff;
                ame132_has_le = true;
            }
        }
        ame132_cmd = (const struct load_command *)
            ((const uint8_t *)ame132_cmd + ame132_cmd->cmdsize);
    }
    if (!ame132_has_symtab || !ame132_has_le || ame132_dysym.nindirectsyms == 0) {
        NSLog(@"[SDLHook] Task132: libjnidispatch image missing symtab/linkedit "
              @"(layout change?), dlsym rebind skipped");
        return 0;
    }
    // fishhook 同款 __LINKEDIT 基址换算（slide + vmaddr - fileoff）
    uintptr_t ame132_base = (uintptr_t)ame132_slide + ame132_le_vmaddr - ame132_le_fileoff;
    const struct nlist_64 *ame132_syms =
        (const struct nlist_64 *)(ame132_base + ame132_symtab.symoff);
    const char *ame132_strs = (const char *)(ame132_base + ame132_symtab.stroff);
    const uint32_t *ame132_indirect =
        (const uint32_t *)(ame132_base + ame132_dysym.indirectsymoff);

    // 第二遍：扫 __la_symbol_ptr / __got 类指针段的间接符号表，找 _dlsym 槽
    vm_size_t ame132_ps = (vm_size_t)sysconf(_SC_PAGESIZE);
    int ame132_hits = 0;
    ame132_cmd = (const struct load_command *)(ame132_hdr + 1);
    for (uint32_t c = 0; c < ame132_hdr->ncmds; c++) {
        if (ame132_cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)ame132_cmd;
            const struct section_64 *sect = (const struct section_64 *)
                ((const uint8_t *)seg + sizeof(struct segment_command_64));
            for (uint32_t s = 0; s < seg->nsects; s++, sect++) {
                uint32_t stype = sect->flags & SECTION_TYPE;
                if (stype != S_LAZY_SYMBOL_POINTERS &&
                    stype != S_NON_LAZY_SYMBOL_POINTERS) {
                    continue;
                }
                uint32_t stride = sect->reserved2 ? sect->reserved2 : (uint32_t)sizeof(void *);
                if (stride == 0) continue;
                uint32_t n = (uint32_t)(sect->size / stride);
                for (uint32_t j = 0; j < n; j++) {
                    uint32_t idx = sect->reserved1 + j;
                    if (idx >= ame132_dysym.nindirectsyms) continue;
                    uint32_t symIdx = ame132_indirect[idx];
                    // INDIRECT_SYMBOL_LOCAL（0x80000000，含 LOCAL|1）与
                    // INDIRECT_SYMBOL_ABS（0x40000000）都不是符号表下标
                    if ((symIdx & INDIRECT_SYMBOL_LOCAL) != 0) continue;
                    if (symIdx == INDIRECT_SYMBOL_ABS) continue;
                    if (symIdx >= ame132_symtab.nsyms) continue;
                    uint32_t n_strx = ame132_syms[symIdx].n_un.n_strx;
                    if (n_strx == 0 || n_strx >= ame132_symtab.strsize) continue;
                    const char *sym_name = ame132_strs + n_strx;
                    if (strcmp(sym_name, "_dlsym") != 0) continue;
                    void **slot = (void **)(ame132_slide + sect->addr +
                                            (uint64_t)j * stride);
                    // Task 135：幂等命中不再静默——装机日志（6235baf 三会话）
                    // 实证本函数被调用后零输出，而本函数唯一无日志出口就是
                    // 这里（槽已是 hooked_dlsym）。加日志让下一轮装机日志能
                    // 直接判读：若此行出现，说明 fishhook 的 add-image 回调
                    // （或更早的扫描）已先一步重绑了该槽——JNA 解析绕行
                    // hooked_dlsym 的机制必须另找；若不出现而走下方写路径，
                    // 则历史静默另有其因。
                    if (*slot == hook_fn) {
                        ame132_hits++;
                        NSLog(@"[SDLHook] Task135: _dlsym slot %p already == "
                              @"hooked_dlsym (idempotent hit, %s,%s) -- fishhook "
                              @"add-image callback or earlier pass won the race",
                              (void *)slot, seg->segname, sect->sectname);
                        continue;
                    }
                    vm_address_t page = (vm_address_t)((uintptr_t)slot &
                        ~((uintptr_t)ame132_ps - 1));
                    kern_return_t kr = vm_protect(mach_task_self(), page,
                        ame132_ps, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    if (kr != KERN_SUCCESS) {
                        NSLog(@"[SDLHook] Task132: vm_protect failed for "
                              @"libjnidispatch _dlsym slot %p (kr=%d)", slot, kr);
                        continue;
                    }
                    *slot = hook_fn;
                    // Task 134：读回验证——只有写后槽值等于 hook 才计入
                    // 返回值（未验证的绑定触发看门狗重试）
                    if (*slot != hook_fn) {
                        NSLog(@"[SDLHook] Task132: READBACK FAILED for _dlsym slot "
                              @"%p (value=%p expected=%p) -- JNA stays unhooked, retry scheduled!",
                              (void *)slot, *slot, hook_fn);
                    } else {
                        ame132_hits++;
                        NSLog(@"[SDLHook] Task132: libjnidispatch _dlsym slot rebound "
                              @"(%s[%s] slot=%p verified) -- JNA symbol resolution now routes "
                              @"through hooked_dlsym (Task131 guard covers the JNA path)",
                              seg->segname, sect->sectname, (void *)slot);
                    }
                }
            }
        }
        ame132_cmd = (const struct load_command *)
            ((const uint8_t *)ame132_cmd + ame132_cmd->cmdsize);
    }
    if (ame132_hits == 0) {
        NSLog(@"[SDLHook] Task132: libjnidispatch loaded but no verified _dlsym "
              @"pointer slot (unexpected layout or write race -- retry scheduled)");
    }
    return ame132_hits;
}

// Task 134：旧入口保留（hooked_dlopen 的显式命名路径触发）——句柄查找
// 失败现在落日志（此前是静默 return，装机日志无法判读断点）。
void amethyst_task132_rebind_jna_dlsym(void *handle, void *hook_fn) {
    if (handle == NULL || hook_fn == NULL) return;
    const struct mach_header_64 *ame132_hdr = NULL;
    intptr_t ame132_slide = 0;
    uint32_t ame132_count = _dyld_image_count();
    for (uint32_t i = 0; i < ame132_count; i++) {
        if ((const void *)_dyld_get_image_header(i) == handle) {
            ame132_hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
            ame132_slide = _dyld_get_image_vmaddr_slide(i);
            break;
        }
    }
    if (ame132_hdr == NULL) {
        NSLog(@"[SDLHook] Task134: jna rebind handle %p not found in dyld image "
              @"list (dlopen-path trigger) -- giving up this trigger", handle);
        return;
    }
    amethyst_task132_rebind_jna_dlsym_ex(ame132_hdr, ame132_slide, hook_fn);
}

// ---------------------------------------------------------------------------
// Task 133：JVM 侧 dlopen 调用链重绑定（26.1.2 controlify/JNA SIGBUS 的
// 真正根治——Task132 的触发链从未接通，3bcf8c4 装机日志实证）。
//
// 事故复盘（b33e550 构建 + 3bcf8c4 日志，对照 26.3 正常会话）：
//   1. Task132 假设"JVM 的 System.load 走被 hook 的 dlopen"（引 Task106
//      libasyncProfiler 拦截为证）——该假设错误。实际调用链是：
//      启动器主二进制 dlopen(libjli.dylib)【可见 ✓ 主二进制 GOT 早已重绑定】
//      → libjli 自己的 GOT 槽调 dlopen(libjvm.dylib)【不可见——libjli 在
//      init_hookFunctions 之后才加载，fishhook 从未重绑定它】
//      → libjvm 的 System.load 经它自己的 GOT 槽 dlopen(libjnidispatch)
//      【不可见】→ libjnidispatch dlopen(SDL3)+dlsym(SDL_SetEventFilter)
//      【不可见】。
//      3bcf8c4 日志全篇零 Task132/Task131 守卫行 = 链条从 libjli 就断了。
//   2. 第二个断点：即便 libjnidispatch 的加载进了 hooked_dlopen，
//      strstr(path, "libjnidispatch") 也大概率不匹配——JNA 5.13 从 jar
//      解包到临时文件（文件名形如 jna<随机>.tmp），路径里没有
//      "libjnidispatch"字样；镜像身份只能靠 LC_ID_DYLIB install name
//      （解包文件与 jar 内原始二进制逐字节一致，install name 不变）。
//   3. 第三个断点：java-25-openjdk（2025 构建）几乎必然使用
//      LC_DYLD_CHAINED_FIXUPS——本仓库 fishhook（283 行经典实现）不支持
//      chained fixups，经典间接符号表遍历对这类镜像一无所获。chained
//      镜像的 GOT 槽在 dyld 完成绑定后就是"已解析的裸指针"，可以按
//      【值】扫描改写，无需解析链式结构。
//
// 修复（三层，全部幂等）：
//   层一（确定性主链）：hooked_dlopen 每次成功加载后跑 ensure 扫描——
//     libjli/libjvm 镜像的 _dlopen 槽改绑到 hooked_dlopen。此后
//     libjvm 的一切 System.load 都进 hooked_dlopen，Task132 的
//     libjnidispatch 检测由此接通（按镜像身份而非路径匹配）。
//   层二（兜底触发）：hooked_dlsym 入口也跑 ensure 扫描——主二进制自身
//     的 dlsym（initSDLEventFuncs 等）在 JNA 类初始化之后、controlify
//     注册回调之前必然发生（MC 建窗在 mod 初始化之前），即使 dlopen 链
//     因意外形态失守，也能在窗口期内把 libjnidispatch 绑上。
//   层三（双法改写）：每个目标镜像先走经典间接符号表遍历（Task132 同款，
//     覆盖传统 LC_DYLD_INFO 布局），再走 __DATA/__DATA_CONST 全段
//     【值扫描】（qword == 真实 dlopen/dlsym 地址即改写，覆盖 chained
//     fixups 布局与任何已绑定的 lazy 槽）。改写语义透明：hooked_dlopen
//     对非拦截路径完全透传，误改任何"恰好存着该地址"的数据槽也无害。
//
// 安全边界（刻意收窄）：
//   - 只改 libjli/libjvm 的 _dlopen 槽与 libjnidispatch 的 _dlsym 槽，
//     不碰 JVM 侧任何 dlsym（JVM 自己的 os::dll_lookup 全走真 dlsym，
//     RTLD_NEXT 语义零风险）；JNA dispatch.c 只用显式句柄 dlsym。
//   - PLPatchMachOPlatformForFile 对平台已匹配的库提前返回 NO（不写回），
//     JVM 运行时库全部预打 iOS 平台标签，新可见的加载零副作用。
//   - 增量游标扫描（新镜像只处理一次；dlclose 回落时全量重扫，重绑定
//     幂等），重复 dlopen 同一库零副作用。
// ---------------------------------------------------------------------------
// 内部：把一张镜像的 _dlopen 指针槽改绑为 hook_fn。
// 经典间接表遍历（符号名匹配）+ __DATA* 值扫描（chained fixups 兜底）。
static void amethyst_task133_rebind_image_dlopen(const struct mach_header_64 *hdr,
                                                 intptr_t slide,
                                                 void *hook_fn, void *orig_fn,
                                                 const char *t135_sym) {
    if (hdr == NULL || hdr->magic != MH_MAGIC_64 || hook_fn == NULL || orig_fn == NULL) {
        return;
    }
    // ---- 收集 SYMTAB / DYSYMTAB / __LINKEDIT（经典遍历用）----
    struct symtab_command t133_symtab;
    struct dysymtab_command t133_dysym;
    memset(&t133_symtab, 0, sizeof(t133_symtab));
    memset(&t133_dysym, 0, sizeof(t133_dysym));
    uint64_t t133_le_vmaddr = 0, t133_le_fileoff = 0;
    bool t133_has_symtab = false, t133_has_le = false;
    const struct load_command *t133_cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t c = 0; c < hdr->ncmds; c++) {
        if (t133_cmd->cmdsize == 0) break;
        if (t133_cmd->cmd == LC_SYMTAB) {
            t133_symtab = *(const struct symtab_command *)t133_cmd;
            t133_has_symtab = true;
        } else if (t133_cmd->cmd == LC_DYSYMTAB) {
            t133_dysym = *(const struct dysymtab_command *)t133_cmd;
        } else if (t133_cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)t133_cmd;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) {
                t133_le_vmaddr = seg->vmaddr;
                t133_le_fileoff = seg->fileoff;
                t133_has_le = true;
            }
        }
        t133_cmd = (const struct load_command *)((const uint8_t *)t133_cmd + t133_cmd->cmdsize);
    }
    const struct nlist_64 *t133_syms = NULL;
    const char *t133_strs = NULL;
    const uint32_t *t133_indirect = NULL;
    if (t133_has_symtab && t133_has_le && t133_dysym.nindirectsyms > 0) {
        uintptr_t t133_base = (uintptr_t)slide + t133_le_vmaddr - t133_le_fileoff;
        t133_syms = (const struct nlist_64 *)(t133_base + t133_symtab.symoff);
        t133_strs = (const char *)(t133_base + t133_symtab.stroff);
        t133_indirect = (const uint32_t *)(t133_base + t133_dysym.indirectsymoff);
    }

    vm_size_t t133_ps = (vm_size_t)sysconf(_SC_PAGESIZE);
    int t133_hits = 0;
    t133_cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t c = 0; c < hdr->ncmds; c++) {
        if (t133_cmd->cmdsize == 0) break;
        if (t133_cmd->cmd != LC_SEGMENT_64) {
            t133_cmd = (const struct load_command *)((const uint8_t *)t133_cmd + t133_cmd->cmdsize);
            continue;
        }
        const struct segment_command_64 *seg =
            (const struct segment_command_64 *)t133_cmd;
        // ---- A. 经典遍历：S_LAZY / S_NON_LAZY 指针段的间接符号表 ----
        const struct section_64 *t133_sect = (const struct section_64 *)
            ((const uint8_t *)seg + sizeof(struct segment_command_64));
        for (uint32_t s = 0; s < seg->nsects; s++, t133_sect++) {
            uint32_t stype = t133_sect->flags & SECTION_TYPE;
            if (stype != S_LAZY_SYMBOL_POINTERS && stype != S_NON_LAZY_SYMBOL_POINTERS) {
                continue;
            }
            // __auth_got（arm64e 带指针认证的 GOT）刻意跳过：往认证槽写裸
            // 指针会直接崩溃；JVM/JNA 运行时库均为普通 arm64（无认证 GOT），
            // 鱼与熊掌兼得——目标镜像全覆盖，认证镜像零接触。
            if (strncmp(t133_sect->sectname, "__auth_got", 10) == 0) {
                continue;
            }
            uint32_t stride = t133_sect->reserved2 ? t133_sect->reserved2 : (uint32_t)sizeof(void *);
            if (stride == 0 || t133_indirect == NULL) continue;
            uint32_t n = (uint32_t)(t133_sect->size / stride);
            for (uint32_t j = 0; j < n; j++) {
                uint32_t idx = t133_sect->reserved1 + j;
                if (idx >= t133_dysym.nindirectsyms) continue;
                uint32_t symIdx = t133_indirect[idx];
                if ((symIdx & INDIRECT_SYMBOL_LOCAL) != 0) continue;
                if (symIdx == INDIRECT_SYMBOL_ABS) continue;
                if (symIdx >= t133_symtab.nsyms) continue;
                uint32_t n_strx = t133_syms[symIdx].n_un.n_strx;
                if (n_strx == 0 || n_strx >= t133_symtab.strsize) continue;
                if (strcmp(t133_strs + n_strx, t135_sym) != 0) continue;
                void **slot = (void **)(slide + t133_sect->addr + (uint64_t)j * stride);
                if (*slot == hook_fn) { t133_hits++; continue; } // 幂等
                vm_address_t page = (vm_address_t)((uintptr_t)slot & ~((uintptr_t)t133_ps - 1));
                if (vm_protect(mach_task_self(), page, t133_ps, false,
                               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
                    continue;
                }
                *slot = hook_fn;
                t133_hits++;
            }
        }
        // ---- B. 值扫描兜底：chained fixups 镜像（无间接符号表），以及
        //      已被 dyld 绑定过的 lazy 槽——槽内已是真实 dlopen 地址 ----
        if (strncmp(seg->segname, "__DATA", 6) != 0) {
            t133_cmd = (const struct load_command *)((const uint8_t *)t133_cmd + t133_cmd->cmdsize);
            continue;
        }
        uintptr_t start = (uintptr_t)slide + (uintptr_t)seg->vmaddr;
        uintptr_t end = start + (uintptr_t)seg->vmsize;
        if (end <= start) {
            t133_cmd = (const struct load_command *)((const uint8_t *)t133_cmd + t133_cmd->cmdsize);
            continue;
        }
        for (uintptr_t p = start; p + sizeof(void *) <= end; p += sizeof(void *)) {
            void *v = *(void **)p;
            if (v != orig_fn) continue;
            void **slot = (void **)p;
            if (*slot == hook_fn) continue; // 幂等（不可达，v==orig_fn 已排除）
            vm_address_t page = (vm_address_t)(p & ~((uintptr_t)t133_ps - 1));
            if (vm_protect(mach_task_self(), page, t133_ps, false,
                           VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
                continue;
            }
            *slot = hook_fn;
            t133_hits++;
        }
        t133_cmd = (const struct load_command *)((const uint8_t *)t133_cmd + t133_cmd->cmdsize);
    }
    NSLog(@"[SDLHook] Task133: %s slots rebound for %s (hits=%d, "
          @"classic+value-scan) -- JVM-side %s chain now routes through "
          @"the hook", t135_sym, hdr->magic == MH_MAGIC_64 ? "image" : "?",
          t133_hits, t135_sym);
    (void)t133_hits;
}

// 内部：读镜像的 LC_ID_DYLIB install name（无则返回 NULL）。
static const char *amethyst_task133_install_name(const struct mach_header_64 *hdr) {
    if (hdr == NULL) return NULL;
    const struct load_command *cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t c = 0; c < hdr->ncmds; c++) {
        if (cmd->cmdsize == 0) break;
        if (cmd->cmd == LC_ID_DYLIB) {
            const struct dylib_command *dylib = (const struct dylib_command *)cmd;
            return (const char *)dylib + dylib->dylib.name.offset;
        }
        cmd = (const struct load_command *)((const uint8_t *)cmd + cmd->cmdsize);
    }
    return NULL;
}

// 内部：basename of a POSIX path（尾部斜杠容错）。
static const char *amethyst_task133_basename(const char *path) {
    if (path == NULL) return NULL;
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// Task 134 前向声明（定义在 ensure 之后）：JVM 镜像检出时启动看门狗。
static void amethyst_task134_watchdog_maybe_start(void);

// Task 134：JNA 重绑定重试状态（未验证 = 看门狗每 200ms 重试，直到读回
// 验证通过或 100 次上限。病历：装机日志双会话实证首次绑定可静默失败，
// 而 JNA 加载 jnilib 到 controlify 解析 SDL 符号相隔秒级——重试窗口充足）
static const struct mach_header_64 *t134_jna_hdr = NULL;
static intptr_t t134_jna_slide = 0;
static int t134_jna_attempts = 0;

static void amethyst_task134_jna_retry_arm(const struct mach_header_64 *hdr, intptr_t slide) {
    t134_jna_hdr = hdr;
    t134_jna_slide = slide;
    if (t134_jna_attempts == 0) {
        NSLog(@"[SDLHook] Task134: JNA rebind unverified -- watchdog will retry "
              @"every 200ms (hdr=%p)", (void *)hdr);
    }
}

static void amethyst_task134_jna_retry_clear(void) {
    if (t134_jna_hdr != NULL) {
        NSLog(@"[SDLHook] Task134: JNA rebind verified after %d attempt(s) -- retries stopped",
              t134_jna_attempts + 1);
    }
    t134_jna_hdr = NULL;
    t134_jna_slide = 0;
    t134_jna_attempts = 0;
}

static void amethyst_task134_retry_pending_jna(void) {
    if (t134_jna_hdr == NULL || t134_jna_attempts >= 100) {
        return;
    }
    t134_jna_attempts++;
    if (amethyst_task132_rebind_jna_dlsym_ex(t134_jna_hdr, t134_jna_slide,
                                             (void *)hooked_dlsym) > 0) {
        amethyst_task134_jna_retry_clear();
    } else if (t134_jna_attempts == 1 || t134_jna_attempts % 10 == 0) {
        NSLog(@"[SDLHook] Task134: JNA rebind still unverified (attempt %d, hdr=%p)",
              t134_jna_attempts, (void *)t134_jna_hdr);
    }
}

// Task 133 主入口：扫描已加载镜像，把 JVM 侧 dlopen 调用链接进 hook。
// 由 hooked_dlopen（JVM/JNA 相关路径加载后）与 hooked_dlsym（入口）调用。
// 增量扫描：dyld 追加式注册新镜像，游标只进不退；镜像数回落（dlclose，
// 罕见）时游标归零全量重扫（重绑定幂等，代价可忽略）。无新镜像时开销
// = 一次 dyld 计数调用 + 一次比较。
void amethyst_task133_ensure_jvm_chain(void) {
    // Task 134：未验证的 JNA 重绑定重试（看门狗 tick 驱动；必须在游标
    // 早退之前处理——否则无新镜像时永远不会重试）。重试体幂等，跨线程
    // 并发重试的最坏结果是一次多余的段保护调用，无害。
    amethyst_task134_retry_pending_jna();
    static pthread_mutex_t t133_lock = PTHREAD_MUTEX_INITIALIZER;
    static uint32_t t133_cursor = 0;
    static bool t133_initialized = false;

    uint32_t count = _dyld_image_count();
    if (t133_initialized && count == t133_cursor) {
        return; // 无新镜像，早退
    }
    pthread_mutex_lock(&t133_lock);
    // 双检：等锁期间另一线程可能已扫完同一批镜像
    count = _dyld_image_count();
    if (t133_initialized && count == t133_cursor) {
        pthread_mutex_unlock(&t133_lock);
        return;
    }
    // 镜像数回落（dlclose 后复用下标）时全量重扫，防下标复用漏检
    uint32_t start = (count >= t133_cursor) ? t133_cursor : 0;
    for (uint32_t i = start; i < count; i++) {
        const struct mach_header_64 *hdr =
            (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (hdr == NULL || hdr->magic != MH_MAGIC_64) continue;

        const char *path = _dyld_get_image_name(i);
        const char *base = amethyst_task133_basename(path);
        const char *install = amethyst_task133_install_name(hdr);
        const char *installBase = amethyst_task133_basename(install);
        bool isJli = (base && strstr(base, "libjli")) || (installBase && strstr(installBase, "libjli"));
        bool isJvm = (base && strstr(base, "libjvm")) || (installBase && strstr(installBase, "libjvm"));
        // libjnidispatch：JNA 从 jar 解包的临时文件（jna<随机>.tmp）路径不含该
        // 名字，必须按 install name 识别（解包文件与 jar 内二进制逐字节
        // 一致，LC_ID_DYLIB 保留原名）——Task132 只按路径 strstr 匹配因此
        // 从未命中，这是 26.1.2 拦截链断开的第二个断点
        bool isJna = (base && strstr(base, "libjnidispatch")) ||
                     (installBase && strstr(installBase, "libjnidispatch"));
        // Task193：LWJGL natives（liblwjgl.jni / liblwjgl.dylib，可能从 jar
        // 解包成临时文件名）——重绑其 _dlsym 槽到 hooked_dlsym，使
        // hooked_dlsym 的 GL NULL 解析取证（[dlsym] Task193: GL symbol
        // resolution FAILED: ...）能覆盖 LWJGL 的 GL$1 函数解析链。
        bool isLwjglNative = (base && strstr(base, "lwjgl")) ||
                             (installBase && strstr(installBase, "lwjgl"));
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (isJli || isJvm) {
            NSLog(@"[SDLHook] Task133: %@ image detected (%s) -- rebinding its "
                  @"_dlopen slots", isJli ? @"libjli" : @"libjvm", path ?: "(null)");
            amethyst_task133_rebind_image_dlopen(hdr, slide,
                (void *)hooked_dlopen, (void *)orig_dlopen, "_dlopen");
            // Task 135：同一镜像的 _dlsym 槽也重绑——FFM loaderLookup / JVM
            // 内部 os::dll_lookup 走 libjvm 自己的 dlsym 槽，此前只靠
            // fishhook 的 add-image 回调覆盖（26.2 会话实证该路径已被拦，
            // 但 26.1.2 会话 JNA 解析绕行说明回调覆盖存在盲区——这里补上
            // 确定性直连）。
            amethyst_task133_rebind_image_dlopen(hdr, slide,
                (void *)hooked_dlsym, (void *)orig_dlsym, "_dlsym");
            // Task 134：JVM 家族镜像已出现——启动链路无关的看门狗扫描
            amethyst_task134_watchdog_maybe_start();
        } else if (isJna) {
            // dlopen 句柄即 mach header 地址（Task132 同款对应关系），
            // 直接复用既有的 _dlsym 槽位重绑定
            NSLog(@"[SDLHook] Task133: libjnidispatch image detected (%s / "
                  @"install %s) -- invoking Task132 dlsym rebind (direct hdr+slide)",
                  path ?: "(null)", install ?: "(null)");
            if (amethyst_task132_rebind_jna_dlsym_ex(hdr, slide, (void *)hooked_dlsym) > 0) {
                amethyst_task134_jna_retry_clear();
            } else {
                amethyst_task134_jna_retry_arm(hdr, slide);
            }
            amethyst_task134_watchdog_maybe_start();
        } else if (isLwjglNative) {
            // Task193：LWJGL natives 的 _dlsym 槽重绑（GL NULL 解析取证，
            // 见 hooked_dlsym 的 [dlsym] Task193 日志与 main_hook.m 触发面注释）
            NSLog(@"[SDLHook] Task193: LWJGL native image detected (%s / "
                  @"install %s) -- rebinding its _dlsym slots (GL NULL-resolution forensics)",
                  path ?: "(null)", install ?: "(null)");
            amethyst_task132_rebind_jna_dlsym_ex(hdr, slide, (void *)hooked_dlsym);
        }
    }
    t133_cursor = _dyld_image_count();
    t133_initialized = true;
    pthread_mutex_unlock(&t133_lock);
}

// ---------------------------------------------------------------------------
// Task 134：JVM 镜像扫描看门狗（26.1.2 controlify/JNA SIGBUS 的链路无关
// 兜底层）。
//
// 动机：Task133 的拦截链依赖"libjli/libjvm 的 _dlopen 槽被成功重绑定"，
// 装机日志（3bcf8c4）实证该链在真机上存在未知断点（用户在 9fa66fb 构建
// 上仍报告崩溃，但未附新日志无法定位）。取证显示 JNA 在 Native 类静态
// 初始化时加载 libjnidispatch（日志 21:33:2x），而 controlify 解析
// SDL_SetEventFilter 的崩溃发生在 21:33:23——两者相隔【秒级】。这给了
// 一个不依赖 JVM dlopen 链的兜底窗口：只要 libjnidispatch 镜像在 dyld
// 列表里存在超过 200ms，定时器扫描就能检出它并执行 Task132 的 _dlsym
// 槽重绑定（JNA 后续的符号解析即进入 hooked_dlsym，Task131 守卫生效）。
//
// 开销：主队列 200ms 定时器，空闲时一次 _dyld_image_count() + 整数比较
// 即早退（ensure_jvm_chain 幂等 + 增量游标）。首次检出 JVM 家族镜像
// （libjli/libjvm/jna）时启动，进程生命周期内常驻。
// ---------------------------------------------------------------------------
void amethyst_task134_jvm_watchdog_start(void);

static void amethyst_task134_watchdog_maybe_start(void) {
    static dispatch_once_t t134_once;
    dispatch_once(&t134_once, ^{
        dispatch_source_t timer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        if (timer == NULL) return;
        dispatch_source_set_timer(timer,
            dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC),
            200 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            amethyst_task133_ensure_jvm_chain();
        });
        dispatch_resume(timer);
        // 进程级持有（定时器常驻；空闲 tick 是一次 dyld 计数调用，可忽略）
        static dispatch_source_t t134_retain_anchor;
        t134_retain_anchor = timer;
        NSLog(@"[SDLHook] Task134: JVM image watchdog started (200ms dyld scan, "
              @"chain-independent JNA rebind backstop)");
    });
}

void amethyst_task134_jvm_watchdog_start(void) {
    amethyst_task134_watchdog_maybe_start();
}

void *amethyst_sdl3_hook_resolve(void *handle, const char *name) {
    if (name == NULL) return NULL;

    // 先记下真实指针（无论本次是否接管，后续包装都要用到）
    if (strcmp(name, "SDL_CreateWindow") == 0) {
        if (ame_real_CreateWindow == NULL) {
            ame_real_CreateWindow = (ame_fn_SDL_CreateWindow)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_CreateWindow (real=%p)", (void *)ame_real_CreateWindow);
        return (void *)ame_SDL_CreateWindow;
    }
    if (strcmp(name, "SDL_CreateWindowWithProperties") == 0) {
        if (ame_real_CreateWindowWithProperties == NULL) {
            ame_real_CreateWindowWithProperties =
                (ame_fn_SDL_CreateWindowWithProperties)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_CreateWindowWithProperties (real=%p)",
                   (void *)ame_real_CreateWindowWithProperties);
        return (void *)ame_SDL_CreateWindowWithProperties;
    }
    if (strcmp(name, "SDL_DestroyWindow") == 0) {
        if (ame_real_DestroyWindow == NULL) {
            ame_real_DestroyWindow = (ame_fn_SDL_DestroyWindow)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_DestroyWindow;
    }
    if (strcmp(name, "SDL_LoadFunction") == 0) {
        if (ame_real_LoadFunction == NULL) {
            ame_real_LoadFunction = (ame_fn_SDL_LoadFunction)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_LoadFunction;
    }
    if (strcmp(name, "SDL_EGL_GetProcAddress") == 0) {
        if (ame_real_EGL_GetProcAddress == NULL) {
            ame_real_EGL_GetProcAddress =
                (ame_fn_SDL_EGL_GetProcAddress)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_EGL_GetProcAddress;
    }
    if (strcmp(name, "SDL_LoadObject") == 0) {
        if (ame_real_LoadObject == NULL) {
            ame_real_LoadObject = (ame_fn_SDL_LoadObject)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_LoadObject;
    }
    if (strcmp(name, "SDL_UnloadObject") == 0) {
        if (ame_real_UnloadObject == NULL) {
            ame_real_UnloadObject = (ame_fn_SDL_UnloadObject)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_UnloadObject;
    }
    // Task 32 窗口生命周期 / 事件泵取证钩子（透传 + 日志）。
    // 注意：这些钩子不依赖渲染器类型 —— zink / Vulkan 路径同样需要知道
    // MC 的窗口显示行为与事件泵状态（黑屏取证对所有渲染路径都有意义）。
    if (strcmp(name, "SDL_ShowWindow") == 0) {
        if (ame_real_ShowWindow == NULL) {
            ame_real_ShowWindow = (ame_fn_SDL_ShowWindow)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_ShowWindow (real=%p)", (void *)ame_real_ShowWindow);
        return (void *)ame_SDL_ShowWindow;
    }
    if (strcmp(name, "SDL_HideWindow") == 0) {
        if (ame_real_HideWindow == NULL) {
            ame_real_HideWindow = (ame_fn_SDL_HideWindow)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_HideWindow (real=%p)", (void *)ame_real_HideWindow);
        return (void *)ame_SDL_HideWindow;
    }
    if (strcmp(name, "SDL_SetWindowSize") == 0) {
        if (ame_real_SetWindowSize == NULL) {
            ame_real_SetWindowSize = (ame_fn_SDL_SetWindowSize)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_SetWindowSize (real=%p)", (void *)ame_real_SetWindowSize);
        return (void *)ame_SDL_SetWindowSize;
    }
    if (strcmp(name, "SDL_SetWindowPosition") == 0) {
        if (ame_real_SetWindowPosition == NULL) {
            ame_real_SetWindowPosition = (ame_fn_SDL_SetWindowPosition)amethyst_orig_dlsym(handle, name);
        }
        return (void *)ame_SDL_SetWindowPosition;
    }
    if (strcmp(name, "SDL_SetWindowFullscreen") == 0) {
        if (ame_real_SetWindowFullscreen == NULL) {
            ame_real_SetWindowFullscreen = (ame_fn_SDL_SetWindowFullscreen)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_SetWindowFullscreen (real=%p)", (void *)ame_real_SetWindowFullscreen);
        return (void *)ame_SDL_SetWindowFullscreen;
    }
    if (strcmp(name, "SDL_PollEvent") == 0) {
        if (ame_real_PollEvent == NULL) {
            ame_real_PollEvent = (ame_fn_SDL_PollEvent)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_PollEvent (real=%p)", (void *)ame_real_PollEvent);
        return (void *)ame_SDL_PollEvent;
    }
    if (strcmp(name, "SDL_GetWindowFlags") == 0) {
        if (ame_real_GetWindowFlags == NULL) {
            ame_real_GetWindowFlags = (ame_fn_SDL_GetWindowFlags)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_GetWindowFlags (real=%p, MINIMIZED stripped)", (void *)ame_real_GetWindowFlags);
        return (void *)ame_SDL_GetWindowFlags;
    }
    // Task 65：键盘事件窗口句柄解析救援（真实解析 NULL 回落主窗口，
    // 见 5) 节注释——MC 26.3 handleKeyEvent 懒惰求值 + 缓冲区复用缺陷）。
    if (strcmp(name, "SDL_GetWindowFromEvent") == 0) {
        if (ame_real_GetWindowFromEvent == NULL) {
            ame_real_GetWindowFromEvent = (ame_fn_SDL_GetWindowFromEvent)amethyst_orig_dlsym(handle, name);
        }
        NSDebugLog(@"[SDLHook] hooked SDL_GetWindowFromEvent (real=%p, Task65 keyboard handle rescue)", (void *)ame_real_GetWindowFromEvent);
        return (void *)ame_SDL_GetWindowFromEvent;
    }
    // Task 61：尺寸查询接管（pts->px 语义统一，见 5) 节注释）。
    if (strcmp(name, "SDL_GetWindowSize") == 0) {
        if (ame_real_GetWindowSize == NULL) {
            ame_real_GetWindowSize = (ame_fn_SDL_GetWindowSize)amethyst_orig_dlsym(handle, name);
        }
        NSLog(@"[SDLHook] hooked SDL_GetWindowSize (real=%p, Task61 px semantics: windowWidth x windowHeight)",
              (void *)ame_real_GetWindowSize);
        return (void *)ame_SDL_GetWindowSize;
    }
    if (strcmp(name, "SDL_GetWindowSizeInPixels") == 0) {
        if (ame_real_GetWindowSizeInPixels == NULL) {
            ame_real_GetWindowSizeInPixels = (ame_fn_SDL_GetWindowSizeInPixels)amethyst_orig_dlsym(handle, name);
        }
        NSLog(@"[SDLHook] hooked SDL_GetWindowSizeInPixels (real=%p, Task61 pinned to launcher px)",
              (void *)ame_real_GetWindowSizeInPixels);
        return (void *)ame_SDL_GetWindowSizeInPixels;
    }
    // Task 67：键盘态轮询口观测（MC isKeyDown/setAll/hasShiftDown 的必经
    // 之路；纯透传 + 指针对证 + 关键键位值采样，见 5) 节 Task67 块注释）。
    if (strcmp(name, "SDL_GetKeyboardState") == 0) {
        if (ame_real_GetKeyboardState == NULL) {
            ame_real_GetKeyboardState = (ame_fn_SDL_GetKeyboardState)amethyst_orig_dlsym(handle, name);
        }
        NSLog(@"[SDLHook] hooked SDL_GetKeyboardState (real=%p, Task67 kb-state poll observability)",
              (void *)ame_real_GetKeyboardState);
        return (void *)ame_SDL_GetKeyboardState;
    }
    // Task 114：文本输入族 + InitSubSystem hint（键盘自动弹出修复，实现见
    // "Task 114" 一节；上游 caf6822 设备验证过的同款钩子组合）。
    if (strcmp(name, "SDL_StartTextInput") == 0) {
        if (ame_real_StartTextInput == NULL)
            ame_real_StartTextInput = (ame_fn_SDL_StartTextInput)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_StartTextInput -> main thread");
        return (void *)ame_SDL_StartTextInput;
    }
    if (strcmp(name, "SDL_StartTextInputWithProperties") == 0) {
        if (ame_real_StartTextInputWithProperties == NULL)
            ame_real_StartTextInputWithProperties =
                (ame_fn_SDL_StartTextInputWithProperties)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_StartTextInputWithProperties -> main thread");
        return (void *)ame_SDL_StartTextInputWithProperties;
    }
    if (strcmp(name, "SDL_StopTextInput") == 0) {
        if (ame_real_StopTextInput == NULL)
            ame_real_StopTextInput = (ame_fn_SDL_StopTextInput)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_StopTextInput -> main thread");
        return (void *)ame_SDL_StopTextInput;
    }
    if (strcmp(name, "SDL_SetTextInputArea") == 0) {
        if (ame_real_SetTextInputArea == NULL)
            ame_real_SetTextInputArea = (ame_fn_SDL_SetTextInputArea)amethyst_orig_dlsym(handle, name);
        NSDebugLog(@"[SDLHook] hooked SDL_SetTextInputArea -> main thread");
        return (void *)ame_SDL_SetTextInputArea;
    }
    if (strcmp(name, "SDL_InitSubSystem") == 0) {
        if (ame_real_InitSubSystem == NULL)
            ame_real_InitSubSystem = (ame_fn_SDL_InitSubSystem)amethyst_orig_dlsym(handle, name);
        NSLog(@"[SDLHook] hooked SDL_InitSubSystem -> Task114 launcher hints");
        return (void *)ame_SDL_InitSubSystem;
    }
    // Task 131：事件回调入口拦截（controlify/JNA closure 崩溃根治，见上方
    // ame_SDL_SetEventFilter 节的完整事故链）。按名字分发 -> JNA 的 dlsym
    // 解析（libjnidispatch 同样被 fishhook 重绑定）与 LWJGL 路径都会命中。
    if (strcmp(name, "SDL_SetEventFilter") == 0) {
        NSLog(@"[SDLHook] hooked SDL_SetEventFilter -> Task131 JNA closure guard");
        return (void *)ame_SDL_SetEventFilter;
    }
    if (strcmp(name, "SDL_AddEventWatch") == 0) {
        NSLog(@"[SDLHook] hooked SDL_AddEventWatch -> Task131 JNA closure guard");
        return (void *)ame_SDL_AddEventWatch;
    }
    // SDL_GL_SetAttribute 不接管：MC 自己调用它设属性是合法行为，我们只在
    // 建窗前主动调用同一个函数来强制 ES profile（见 ame_forceEglProfileEs）。

    // SDL GL 上下文接管（MobileGL / Mithril / MobileGlues / gl4es / LTW）
    if (ame_glBridgeEnabled()) {
        if (strcmp(name, "SDL_GL_LoadLibrary") == 0) {
            if (ame_real_GL_LoadLibrary == NULL)
                ame_real_GL_LoadLibrary = (ame_fn_SDL_GL_LoadLibrary)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_LoadLibrary -> EGL bridge");
            return (void *)ame_SDL_GL_LoadLibrary;
        }
        if (strcmp(name, "SDL_GL_CreateContext") == 0) {
            if (ame_real_GL_CreateContext == NULL)
                ame_real_GL_CreateContext = (ame_fn_SDL_GL_CreateContext)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_CreateContext -> EGL bridge");
            return (void *)ame_SDL_GL_CreateContext;
        }
        if (strcmp(name, "SDL_GL_MakeCurrent") == 0) {
            if (ame_real_GL_MakeCurrent == NULL)
                ame_real_GL_MakeCurrent = (ame_fn_SDL_GL_MakeCurrent)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_MakeCurrent -> EGL bridge");
            return (void *)ame_SDL_GL_MakeCurrent;
        }
        if (strcmp(name, "SDL_GL_SwapWindow") == 0) {
            if (ame_real_GL_SwapWindow == NULL)
                ame_real_GL_SwapWindow = (ame_fn_SDL_GL_SwapWindow)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_SwapWindow -> EGL bridge");
            return (void *)ame_SDL_GL_SwapWindow;
        }
        if (strcmp(name, "SDL_GL_GetProcAddress") == 0) {
            if (ame_real_GL_GetProcAddress == NULL)
                ame_real_GL_GetProcAddress = (ame_fn_SDL_GL_GetProcAddress)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_GetProcAddress -> renderer dlsym");
            return (void *)ame_SDL_GL_GetProcAddress;
        }
        if (strcmp(name, "SDL_GL_SetSwapInterval") == 0) {
            if (ame_real_GL_SetSwapInterval == NULL)
                ame_real_GL_SetSwapInterval = (ame_fn_SDL_GL_SetSwapInterval)amethyst_orig_dlsym(handle, name);
            NSDebugLog(@"[SDLHook] hooked SDL_GL_SetSwapInterval -> EGL bridge");
            return (void *)ame_SDL_GL_SetSwapInterval;
        }
        if (strcmp(name, "SDL_GL_DestroyContext") == 0) {
            if (ame_real_GL_DestroyContext == NULL)
                ame_real_GL_DestroyContext = (ame_fn_SDL_GL_DestroyContext)amethyst_orig_dlsym(handle, name);
            return (void *)ame_SDL_GL_DestroyContext;
        }
        if (strcmp(name, "SDL_GL_GetCurrentContext") == 0) {
            if (ame_real_GL_GetCurrentContext == NULL)
                ame_real_GL_GetCurrentContext = (ame_fn_SDL_GL_GetCurrentContext)amethyst_orig_dlsym(handle, name);
            return (void *)ame_SDL_GL_GetCurrentContext;
        }
    }

    return NULL;
}
