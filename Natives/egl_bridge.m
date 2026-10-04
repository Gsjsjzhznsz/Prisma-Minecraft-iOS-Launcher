#import "SurfaceViewController.h"

#include "jni.h"
#include <assert.h>
#include <dlfcn.h>

#include <pthread.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <time.h>

#include "EGL/egl.h"
#include "EGL/eglext.h"
#include "GL/osmesa.h"

#include "glfw_keycodes.h"
#include "ctxbridges/bridge_tbl.h"
#include "ctxbridges/osmesa_internal.h"
// Task 215：VirGLRenderer(≤26.2)（ZL2 移植，Task212 预留的 stage 2）—— vtest 服务端引导桥
#include "ctxbridges/virgl_server.h"
#include "utils.h"

// 默认 GL 路径，pojavInit() 会重新设置
int clientAPI = GLFW_OPENGL_API;

// ----------------------------------------------------------------------------
// Task 144：线程级"当前上下文"的唯一 TLS 实例（bridge_tbl.h 里 extern 的
// 定义点；egl_bridge.m 必然链接，保证符号恰好一份）。病历见 bridge_tbl.h
// Task144 注释块 —— 此前 static __thread 写在头文件里，每个包含它的编译
// 单元各持一份，egl_bridge.m 这份永远为 NULL，pojavGetCurrentContext() 恒
// 返回空。ame_brLastCurrent：进程级"最近一次 current"登记（br_set_current
// 写入），供 pojavGetCurrentContext 的渲染线程采纳兜底。
__thread basic_render_window_t* ame_brCurrent = NULL;
basic_render_window_t* ame_brLastCurrent = NULL;

// pojavMakeCurrent 定义在本文件后部（Task144 采纳路径前向引用）。
void pojavMakeCurrent(basic_render_window_t* window);

// FPS 计数器（参照 FCL egl_bridge.c 的 atomic_uint 实现）
// 在 pojavSwapBuffers() 中累加，在 SurfaceViewController 读取时重置
static atomic_uint _pojavFpsCounter = 0;

// 阶段13：首帧渲染检测标志（参照 FCL 的 game_ready 回调）
// pojavSwapBuffers() 首次调用时置为 YES 并发送通知，SurfaceViewController 据此移除启动遮罩
static BOOL s_firstFrameRendered = NO;

unsigned int pojavGetAndResetFps() {
    return atomic_exchange(&_pojavFpsCounter, 0);
}

/// 显式递增 FPS 计数器（供 Vulkan 模式使用）
///
/// Vulkan 渲染器不经过 EGL 的 pojavSwapBuffers 路径，而是通过 MoltenVK 的
/// vkQueuePresentKHR 直接 present。因此 pojavSwapBuffers 中的 FPS 计数逻辑
/// 不会触发。SurfaceViewController 在 Vulkan 模式下使用 CADisplayLink 作为
/// 帧率检测 fallback，每帧通过此函数递增计数器。
void pojavIncrementFpsCounter() {
    atomic_fetch_add(&_pojavFpsCounter, 1);

    // 首帧渲染检测（与 pojavSwapBuffers 中的逻辑一致）
    if (!s_firstFrameRendered) {
        s_firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[egl_bridge] First frame rendered (Vulkan displayLink path), game is ready");
        });
    }
}

/// 运行时判定 MC 真实渲染路径是否为 Vulkan。
///
/// 修复 FPS 显示错误的根本问题：
/// 之前 SurfaceViewController 在 viewDidLoad 时通过 graphicsApi 字符串静态推断
/// 是否启用 CADisplayLink fallback 递增 FPS 计数器。但：
///   - graphicsApi=default 时由 MC 内部决定，无法预判（保守起见启用 fallback）
///   - 但若 MC 实际选了 GL 路径，pojavSwapBuffers 也会计数，导致双重计数
///   - 反之若 graphicsApi=prefer_vulkan 但 MC 启动失败回退到 GL，fallback 会错误递增
///
/// 通过 clientAPI 运行时信号（由 MC 调用 glfwWindowHint(GLFW_CLIENT_API, ...) 写入）
/// 可以准确判定 MC 当前实际走的渲染路径：
///   - GLFW_NO_API（0）→ Vulkan 路径，pojavSwapBuffers 不被调用，需要 fallback
///   - 其他值（GLFW_OPENGL_API 等）→ GL 路径，pojavSwapBuffers 会计数，禁用 fallback
///
/// PLDisplayLinkTarget.displayLinkTick: 每帧动态查询此函数，确保 fallback 启用状态
/// 与 MC 实际渲染路径一致，避免双重计数或漏计数。
bool pojavIsActualVulkanPath() {
    // GLFW 模式：clientAPI 由 pojavSetWindowHint(GLFW_CLIENT_API, ...) 写入，
    // pojavInit() 初始化为 GLFW_OPENGL_API。MC 调用 glfwWindowHint(GLFW_NO_API)
    // 切换到 Vulkan 路径。
    if (clientAPI == GLFW_NO_API) return true;

    return false;
}

void JNI_LWJGL_changeRenderer(const char* value_c) {
    if (value_c == NULL) return;

    // 原实现直接 (*runtimeJavaVMPtr)->GetEnv(...) 且不检查返回值。
    // 在非 JVM 线程上（SDL 的视频/事件线程，SDL3 路径的 SDL_GL_LoadLibrary 就发生在
    // 这类线程上）GetEnv 返回 JNI_EDETACHED 并且**不会写 env**，env 保持为未初始化的
    // 栈垃圾，紧接着 (*env)->NewStringUTF(...) 立刻段错误（崩溃点就是本函数 +0x1c）。
    // 这里补齐：VM 判空 -> GetEnv 结果判空 -> AttachCurrentThread 兜底 -> 用完 detach。
    JavaVM *vm = runtimeJavaVMPtr;
    if (vm == NULL) {
        NSLog(@"[egl_bridge] JNI_LWJGL_changeRenderer('%s') skipped: runtimeJavaVMPtr is NULL", value_c);
        return;
    }

    JNIEnv *env = NULL;
    BOOL attached = NO;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_4) != JNI_OK || env == NULL) {
        if ((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) != JNI_OK || env == NULL) {
            NSLog(@"[egl_bridge] JNI_LWJGL_changeRenderer('%s') skipped: cannot obtain JNIEnv", value_c);
            return;
        }
        attached = YES;
    }

    jstring key = (*env)->NewStringUTF(env, "org.lwjgl.opengl.libname");
    jstring value = (*env)->NewStringUTF(env, value_c);
    if (key != NULL && value != NULL) {
        jclass clazz = (*env)->FindClass(env, "java/lang/System");
        if (clazz != NULL) {
            jmethodID method = (*env)->GetStaticMethodID(env, clazz, "setProperty",
                "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;");
            if (method != NULL) {
                (*env)->CallStaticObjectMethod(env, clazz, method, key, value);
            }
            (*env)->DeleteLocalRef(env, clazz);
        }
        (*env)->DeleteLocalRef(env, key);
        (*env)->DeleteLocalRef(env, value);
    }

    if (attached) (*vm)->DetachCurrentThread(vm);
}

void pojavTerminate() {
    CallbackBridge_nativeSetInputReady(NO);
    if (!br_terminate) return;
    br_terminate();
}

void* pojavGetCurrentContext() {
    // Task 144：渲染线程上下文采纳（defense-in-depth）。
    // POJAV_RENDERER 修复（JavaLauncher 侧 setenv 激活 LWJGL 补丁的
    // fixPojavGLContext）已让 createCapabilities 前主动重绑；此处兜底其余
    // 调用方（MC/mod 的 GLFW.glfwGetCurrentContext）：本线程 TLS 为空但
    // 进程里存在"最近一次 current"的上下文时，直接在本线程重新 make current
    // （EGL 语义 = 上下文从旧线程迁移到本线程，MC 单渲染线程模型安全）。
    // pthread_main_np 排除主线程：主线程即便查询也只该读到，不该抢占。
    if (br_get_current() == NULL && ame_brLastCurrent != NULL && pthread_main_np() == 0) {
        NSLog(@"[egl_bridge] Task144: adopting last-current context %p onto calling thread (no TLS binding yet)",
              (void *)ame_brLastCurrent);
        pojavMakeCurrent(ame_brLastCurrent);
    }
    return br_get_current();
}

int pojavInit(BOOL useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = 1;
    isUseStackQueueCall = useStackQueue;
    return JNI_TRUE;
}

/// OpenGL 子系统是否已初始化成功（渲染器 bridge + br_init()）。
///
/// 必须是全局的而不是 pojavCreateContext 里的局部 static：SDL3 路径下
/// SDL_GL_LoadLibrary 已经调过 pojavInitOpenGLForSDL3() 完成初始化，
/// 若 pojavCreateContext 再凭自己的局部 static 判定"未初始化"，就会再调一次
/// 完整的 pojavInitOpenGL()——那会在 SDL 的原生线程上执行 JNI 调用
/// （JNI_LWJGL_changeRenderer），正是 fc0d838 上报的
/// `C [AngelAuraAmethyst+0x220df8] JNI_LWJGL_changeRenderer+0x1c` 崩溃。
static BOOL s_openGLInited = NO;

BOOL pojavIsOpenGLInited(void) {
    return s_openGLInited;
}

/// 统一收口初始化结果，成功后置位幂等标志。
static int pojavFinishOpenGLInit(int result) {
    if (result == 0) {
        s_openGLInited = YES;
    } else {
        NSLog(@"[egl_bridge] pojavInitOpenGL failed (br_init() returned %d); "
              @"not marking as initialised", result);
    }
    return result;
}

// ============================================================================
// Task204：gl4es 后端解析根治（_gles/_egl 句柄注入 + resolver_global）
//
// 病历（a599782 装机 latestlog.1，1.8.9-forge + gl4es 会话）：
//   MC 死于 java.lang.RuntimeException "glCheckFramebufferStatus returned
//   unknown status:0"（Framebuffer.java:178，Minecraft.init 早期）——构造器
//   崩溃已由 Task203 v2 补丁根治、mod 全部加载、GL caps 识别正常，死点后移
//   到首个 FBO 检查。
//
// 根因（二进制反汇编 + 三会话 tri-probe 对拍闭环）：
//   libgl4es_114 的每个 GL wrapper（framebuffers.c 等）对后端函数做惰性
//   解析：`dlsym(_gles, "glXXX")`，而 `_gles`/`_egl` 两个全局（符号表
//   0x1de038/0x1de040，__DATA 初值 = -1 = RTLD_NEXT）从未被改写——
//   RTLD_NEXT 从 libgl4es 出发搜索"其后"的镜像：tinygl4angle 不导出这些
//   名字（部分导出表），最终命中【系统 /usr/lib/libGLESv2】（共享缓存里
//   的系统 ANGLE——tri-probe 实锤 default=0x25bcb6d70 且 ver=<NULL>，与
//   Task36/Task182 的"SYMBOL THEFT"同源）。系统 ANGLE 上【无当前上下文】
//   → glCheckFramebufferStatus 返回 0 → MC 抛异常。旧一轮的构造器
//   strstr(NULL) 崩溃（Task202 病历）与此【同根】：proc_address 的
//   dlsym(RTLD_DEFAULT) 同样命中系统 GLESv2。
//
//   为什么 caps 阶段 GL_MAJOR_VERSION=3 却活得好好的：LWJGL 的
//   glGetIntegerv 指向 gl4es 自身导出（handle 定向解析），gl4es 内部
//   应答；只有 wrapper 惰性解析的后端指针被劫走。
//
// 修法（三层，全部在 Task193 引导块 dlopen 之后、任何 wrapper 运行之前）：
//   ① _egl（已导出）直接 dlsym 写入 bundled libEGL.framework 句柄；
//   ② _gles（PEXT 私有符号，dlsym 不可见）用布局锚定位：离线核验本二进制
//      _egl 槽 = base+0x1de040、_gles 槽 = base+0x1de038；若运行时
//      dlsym("egl") == base+0x1de040 且 +0x1de038 处仍为 -1（RTLD_NEXT
//      初值指纹），则布局无漂移，安全写入 base+0x1de038；
//   ③ set_getprocaddress(our_resolver)（导出符号；写 proc_address 优先
//      检查的 resolver_global 槽 0x1E3F98，单参签名 void*(*)(const char*)
//      ——proc_address 反汇编实证）：egl* → bundled libEGL 句柄；gl* →
//      eglGetProcAddress（上下文同源，Task182 同链）→ bundled libGLESv2
//      句柄 → 不回落 RTLD_DEFAULT（那正是系统 GLESv2 的劫持通道）。
//   此后所有 wrapper 的惰性 dlsym(_gles=真句柄, name) 与 proc_address
//   解析全部落在 bundled ANGLE 上（与游戏上下文同实例）。
//   构造器自身不走此路（dlopen 期间已跑完）——Task203 v2 补丁继续兜底，
//   其代价（vendor 缓存 NULL、扩展检测失明）保持现状，本轮不动。
// ============================================================================
static void *ame204_gl4esGles2 = NULL;   // bundled libGLESv2.framework 句柄
static void *ame204_gl4esEgl = NULL;     // bundled libEGL.framework 句柄
static void *(*ame204_gl4esEgpa)(const char *) = NULL;  // bundled eglGetProcAddress

static void *ame204_gl4esProcResolver(const char *name) {
    if (name == NULL) return NULL;
    if (name[0] == 'g' && name[1] == 'l') {
        if (ame204_gl4esEgpa != NULL) {
            void *ame204_p = ame204_gl4esEgpa(name);
            if (ame204_p != NULL) return ame204_p;
        }
        if (ame204_gl4esGles2 != NULL) {
            void *ame204_p = dlsym(ame204_gl4esGles2, name);
            if (ame204_p != NULL) return ame204_p;
        }
        return NULL;   // gl* 绝不回落 RTLD_DEFAULT —— 那是系统 GLESv2 的劫持通道
    }
    if (strncmp(name, "egl", 3) == 0 && ame204_gl4esEgl != NULL) {
        void *ame204_p = dlsym(ame204_gl4esEgl, name);
        if (ame204_p != NULL) return ame204_p;
    }
    return dlsym(RTLD_DEFAULT, name);
}

// ---- Task208：NG-GL4ES 初始化时序根修（99a61eb latestlog.old 装机定谳）----
//
// 病历：Task206 假设 NG dylib 由 LWJGL 在上下文 current 后 dlopen——错。
// 真实链：pojavCreateContext → pojavInitOpenGL → 统一预加载
// dlopen("@rpath/libnggl4es.dylib", RTLD_GLOBAL)（本函数尾部统一块），
// 此时 br_init_context 尚未运行、线程无任何 EGL 上下文；NG 上游的
// constructor(101) initialize_gl4es 在 dlopen 期间即跑 GetHardwareExtensions：
//   glGetString(GL_EXTENSIONS) → proc_address 的 __APPLE__ 分支
//   dlsym(RTLD_NEXT,...) → 系统 /usr/lib/libGLESv2（Task204 符号劫持同源，
//   vgpu 会话 tri-probe default=0x... ver=<NULL> 实锤）→ 无上下文返回 NULL
//   → src/glx/hardext.c strstr(Exts,...) → SIGSEGV。
// 后果放大器：JVM fatal 的 abort() 被 hooked_abort 拦截后 park，进程不死、
// Client 线程永卡 JNI.invokePP（watchdog 采样 #1-#5），用户被迫重启 iOS。
//
// 修法（与 vendored CMakeLists 的 -DNO_INIT_CONSTRUCTOR 配套）：
//   构造器消失后，由本函数在【上下文真正 current 之后】显式调用导出的
//   initialize_gl4es()。挂点选 pojavMakeCurrent 尾部（br_make_current 返回
//   即 current；GLFW/LWJGL2 与 SDL3 两条路径都汇到这里——vgpu 装机实证：
//   "Task146 make-current" 之后才出现 "LIBGL: Initialising"）。
//   调用前先注册 set_getprocaddress(ame204_gl4esProcResolver)：proc_address
//   的宿主 resolver 分支优先于 __APPLE__ 的 dlsym(RTLD_NEXT)，从根上关闭
//   系统 GLESv2 劫持通道（硬件探测 + 后续所有惰性解析一并免疫）。
//   eglGetCurrentContext 门：无 current 上下文时跳过并打点（防御性——
//   initialize_gl4es 自带 inited 幂等，但探测必须在真上下文上才有意义）。
static void ame208_nggl4es_boot(void) {
    static volatile int s_ame208_done = 0;
    if (s_ame208_done) return;
    const char *ame208_renderer = getenv("AMETHYST_RENDERER");
    if (ame208_renderer == NULL || strcmp(ame208_renderer, RENDERER_NAME_NGGL4ES) != 0) return;

    // RTLD_NOLOAD：预加载 dlopen 已把镜像载入，这里只取句柄（引用计数 +1，
    // 不会二次跑初始化——NO_INIT_CONSTRUCTOR 下本也无构造器）。
    void *ame208_ng = dlopen("@rpath/" RENDERER_NAME_NGGL4ES, RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL);
    if (ame208_ng == NULL) {
        NSLog(@"[egl_bridge] Task208: NG-GL4ES image not loaded (RTLD_NOLOAD) -- initialize_gl4es NOT called");
        return;
    }

    // 后端钉扎（Task204 resolver 复用）。句柄全局只开一次；resolver 注册
    // 必须先于 initialize_gl4es——硬件探测的 LOAD_GLES 就要走它。
    if (ame204_gl4esEgpa == NULL) {
        ame204_gl4esGles2 = dlopen("@executable_path/Frameworks/libGLESv2.framework/libGLESv2",
                                    RTLD_NOW | RTLD_LOCAL);
        ame204_gl4esEgl = dlopen("@executable_path/Frameworks/libEGL.framework/libEGL",
                                  RTLD_NOW | RTLD_LOCAL);
        ame204_gl4esEgpa = ame204_gl4esEgl
            ? (void *(*)(const char *))dlsym(ame204_gl4esEgl, "eglGetProcAddress")
            : NULL;
    }
    int ame208_resolver = 0;
    if (ame204_gl4esEgpa != NULL) {
        void (*ame208_sgpa)(void *(*)(const char *)) =
            (void (*)(void *(*)(const char *)))dlsym(ame208_ng, "set_getprocaddress");
        if (ame208_sgpa != NULL) {
            ame208_sgpa(ame204_gl4esProcResolver);
            ame208_resolver = 1;
        }
    }

    // 门：确认线程上确有 current 上下文（经由捆绑 ANGLE EGL 查询）。
    if (ame204_gl4esEgl != NULL) {
        void *(*ame208_getCurCtx)(void) =
            (void *(*)(void))dlsym(ame204_gl4esEgl, "eglGetCurrentContext");
        if (ame208_getCurCtx != NULL && ame208_getCurCtx() == NULL) {
            NSLog(@"[egl_bridge] Task208: NG-GL4ES boot deferred -- no current EGL context on this thread");
            return;
        }
    }

    void (*ame208_init)(void) = (void (*)(void))dlsym(ame208_ng, "initialize_gl4es");
    if (ame208_init == NULL) {
        NSLog(@"[egl_bridge] Task208: initialize_gl4es symbol missing -- NG-GL4ES cannot init");
        return;
    }
    ame208_init();   // 上下文已 current：硬件探测/能力缓存全部落真上下文
    s_ame208_done = 1;
    NSLog(@"[egl_bridge] Task208: NG-GL4ES initialize_gl4es() called post-MakeCurrent "
          "(resolver=%@, handle=%p) -- hardware probe ran on the real game context",
          ame208_resolver ? @"YES" : @"NO(egpa-missing)", ame208_ng);
}

// Task211：ZL2 经典版 gl4es 的初始化点——ame208_nggl4es_boot 的同构镜像
// （同一棵 vendored 树的同一套 Task208 三件套：NO_INIT_CONSTRUCTOR +
// MakeCurrent 后显式 initialize_gl4es + set_getprocaddress 钉 Task204
// resolver）。与 NG 唯一差异：dylib 名。非本渲染器时立即返回（一次
// getenv 比较，零副作用）；幂等门 s_ame211_done。
static void ame211_gl4eszl2_boot(void) {
    static volatile int s_ame211_done = 0;
    if (s_ame211_done) return;
    const char *ame211_renderer = getenv("AMETHYST_RENDERER");
    if (ame211_renderer == NULL || strcmp(ame211_renderer, RENDERER_NAME_GL4ESZL2) != 0) return;

    void *ame211_g4 = dlopen("@rpath/" RENDERER_NAME_GL4ESZL2, RTLD_NOW | RTLD_NOLOAD | RTLD_GLOBAL);
    if (ame211_g4 == NULL) {
        NSLog(@"[egl_bridge] Task211: ZL2 classic gl4es image not loaded (RTLD_NOLOAD) -- initialize_gl4es NOT called");
        return;
    }

    // 后端钉扎（Task204 resolver 复用，与 NG 帧同一套全局句柄）。
    if (ame204_gl4esEgpa == NULL) {
        ame204_gl4esGles2 = dlopen("@executable_path/Frameworks/libGLESv2.framework/libGLESv2",
                                   RTLD_NOW | RTLD_LOCAL);
        ame204_gl4esEgl = dlopen("@executable_path/Frameworks/libEGL.framework/libEGL",
                                 RTLD_NOW | RTLD_LOCAL);
        ame204_gl4esEgpa = ame204_gl4esEgl
            ? (void *(*)(const char *))dlsym(ame204_gl4esEgl, "eglGetProcAddress")
            : NULL;
    }
    int ame211_resolver = 0;
    if (ame204_gl4esEgpa != NULL) {
        void (*ame211_sgpa)(void *(*)(const char *)) =
            (void (*)(void *(*)(const char *)))dlsym(ame211_g4, "set_getprocaddress");
        if (ame211_sgpa != NULL) {
            ame211_sgpa(ame204_gl4esProcResolver);
            ame211_resolver = 1;
        }
    }

    // 门：确认线程上确有 current 上下文（经由捆绑 ANGLE EGL 查询）。
    if (ame204_gl4esEgl != NULL) {
        void *(*ame211_getCurCtx)(void) =
            (void *(*)(void))dlsym(ame204_gl4esEgl, "eglGetCurrentContext");
        if (ame211_getCurCtx != NULL && ame211_getCurCtx() == NULL) {
            NSLog(@"[egl_bridge] Task211: ZL2 classic gl4es boot deferred -- no current EGL context on this thread");
            return;
        }
    }

    void (*ame211_init)(void) = (void (*)(void))dlsym(ame211_g4, "initialize_gl4es");
    if (ame211_init == NULL) {
        NSLog(@"[egl_bridge] Task211: initialize_gl4es symbol missing -- ZL2 classic gl4es cannot init");
        return;
    }
    ame211_init();   // 上下文已 current：硬件探测/能力缓存全部落真上下文
    s_ame211_done = 1;
    NSLog(@"[egl_bridge] Task211: ZL2 classic gl4es initialize_gl4es() called post-MakeCurrent "
          "(resolver=%@, handle=%p) -- hardware probe ran on the real game context",
          ame211_resolver ? @"YES" : @"NO(egpa-missing)", ame211_g4);
}

static int pojavInitOpenGLInternal(BOOL setLwjglProperty) {
    if (s_openGLInited) {
        // 幂等：重复初始化会二次 dlopen 渲染器、二次 br_init()（eglInitialize），
        // 且在 SDL3 路径上会触发无意义的 JNI 调用。
        NSDebugLog(@"[egl_bridge] pojavInitOpenGL skipped: already initialised");
        return 0;
    }
    NSString *renderer = NSProcessInfo.processInfo.environment[@"AMETHYST_RENDERER"];
    BOOL isAuto = [renderer isEqualToString:@"auto"];
    if (isAuto || [renderer isEqualToString:@"libgl4es_114.dylib"]) {
        // Task212：holy gl4es（libgl4es_114.dylib）整体退役（用户明令删除）。
        // auto 兜底与历史存量值（libgl4es_114.dylib，迁移见 main.m Task212）
        // 一律改道 ZL2 经典版 gl4es（gl4es(≤26.2)，libgl4eszl2.dylib——同
        // gl4es 1.1.4 血统、从源码构建，Task211 移植）。旧 holy 专属的构造器
        // 引导链（Task192 RTLD_GLOBAL 预载 → Task193 一次性 pbuffer+ES3 上下文
        // 铺垫 → Task202 入口锚点 → Task204 二进制布局指纹句柄注入）随 dylib
        // 一并退役：gl4eszl2 构建带 NO_INIT_CONSTRUCTOR（Task208 三件套），
        // 初始化走 pojavMakeCurrent 尾部的 ame211_gl4eszl2_boot（自带 Task204
        // resolver 钉扎），构造器根本不存在，无需任何 dlopen 前铺垫。
        renderer = @ RENDERER_NAME_GL4ESZL2;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        NSLog(@"[egl_bridge] Task212: renderer '%@' -> ZL2 classic gl4es (holy gl4es retired; constructor bootstrap chain retired with it)",
              isAuto ? @"auto" : @"libgl4es_114.dylib");
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES]) {
        renderer = @ RENDERER_NAME_MOBILEGLUES;
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        // Task 145：同上，不再导出 POJAV_RENDERER。
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MTL_ANGLE]) {
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VGPU]) {
        // Task173：VGPU 渲染器（PojavLauncherTeam/VGPU——gl4es 分支 + 强化
        // 着色器语法转换，旧版 MC 生态；FCL 同款）。与 gl4es 同形：导出全套
        // 桌面 GL 1.x/2.x API，运行时 dlopen ANGLE 框架解析 GLES（pack/load.c
        // 的 Task173 iOS 补丁把库名指向 libGLESv2.framework）。EGL 同样经
        // gl_bridge 从 ANGLE 框架解析——与 gl4es 完全同链路。
        NSLog(@"[egl_bridge] VGPU renderer: gl4es-family GL-on-ES translation (legacy MC)");
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_LTW]) {
        // LTW (Large Thin Wrapper) - OpenGL Core 3.3 → OpenGL ES 3 转译层
        // 复刻自官方 MojoLauncher/LTW 仓库，完美支持 Sodium + Iris 光影。
        //
        // 关键：LTW 的 constructor（proc.c）需要通过 dlsym 找到 eglGetProcAddress
        // 等 EGL 函数符号。LTW 自身只导出 eglCreateContext / eglDestroyContext /
        // eglMakeCurrent 三个 wrapper，其他 EGL 函数直接转发给 host EGL（ANGLE）。
        // 所以必须先 dlopen ANGLE（RTLD_GLOBAL）让 ANGLE 的 EGL 符号进入全局符号表，
        // LTW constructor 才能成功初始化。
        //
        // gl_bridge.m 的 dlsym_EGL() 在 LTW 模式下会从 libltw.dylib 直接 dlsym
        // 这三个 wrapper 函数，其余 EGL 函数仍从 ANGLE 解析。
        NSLog(@"[egl_bridge] LTW renderer: preloading ANGLE as host EGL before LTW init");
        dlopen("@rpath/" RENDERER_NAME_MTL_ANGLE, RTLD_GLOBAL);
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_NGGL4ES]) {
        // Task206→Task208：NG-GL4ES（"Krypton Wrapper"，ZL2 的 gl4es）。
        // Task206 的初始设计假设（"dylib 由 LWJGL 在游戏上下文 current 后
        // dlopen，constructor(101) 探测落真上下文"）被 99a61eb 装机日志证伪：
        // 真实调用链是 pojavCreateContext → pojavInitOpenGL → 本函数尾部的
        // 统一预加载 dlopen(RTLD_GLOBAL) —— 发生在 br_init_context 之前，
        // 线程上没有任何 EGL 上下文 → 构造器 GetHardwareExtensions 的
        // glGetString（经 proc_address 的 Apple 分支 dlsym(RTLD_NEXT) 解析
        // 到系统 /usr/lib/libGLESv2，Task204 符号劫持同源）返回 NULL →
        // hardext.c 的 strstr(Exts,...) SIGSEGV（崩溃栈 _platform_strstr ←
        // GetHardwareExtensions ← initialize_gl4es ← dyld dlopen 链），
        // 且 abort() 被 hook 后 park，Client 线程永卡 JNI.invokePP，
        // 用户被迫重启 iOS。修法（Task208 三件套）：
        //   ① vendored 构建加 -DNO_INIT_CONSTRUCTOR（上游自带开关）——
        //      initialize_gl4es 变成普通导出函数，构造器消失；
        //   ② 本文件 pojavMakeCurrent 尾部的 ame208_nggl4es_boot()：上下文
        //      真正 current 之后显式调用 initialize_gl4es()（vgpu 惰性初始化
        //      的等效时机，装机实证流：Task146 make-current 后才出现
        //      "LIBGL: Initialising"）；
        //   ③ boot 内注册 set_getprocaddress(ame204_gl4esProcResolver)——
        //      proc_address 的宿主 resolver 优先分支，关闭 Apple 分支
        //      dlsym(RTLD_NEXT) 的系统 GLESv2 劫持通道（Task204 同源病）。
        // EGL 仍全部由宿主 gl_bridge 从 ANGLE 框架提供（本分支零 EGL 动作）。
        NSLog(@"[egl_bridge] Task206: NG-GL4ES renderer: gl4es-family GL-on-ES "
              "translation (glslang+SPIRV-Cross shader pipeline, ZL2 Krypton Wrapper)");
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_GL4ESZL2]) {
        // Task211：ZL2 经典版 gl4es（PojavLauncherTeam/gl4es_extra_extra，
        // ZL2 的传统 "gl4es"——用户点名移植，与 holy gl4es / Krypton
        // Wrapper 三者并存互为备选）。纯 C 字符串改写式着色器转换
        // （shaderconv.c），无 glslang/spvc。构建带同款 Task208 三件套
        // （NO_INIT_CONSTRUCTOR + MakeCurrent 后 ame211_gl4eszl2_boot
        // 显式 initialize_gl4es + set_getprocaddress 钉 Task204 resolver）
        // + hardext.c 的 NULL 守卫（Task208 同源防御）。EGL 仍全部由宿主
        // gl_bridge 从 ANGLE 框架提供（本分支零 EGL 动作）。
        NSLog(@"[egl_bridge] Task211: ZL2 classic gl4es renderer: gl4es-family "
              "GL-on-ES translation (pure-C string-rewrite shader pipeline)");
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_MITHRIL]) {
        // Mithril 渲染器：EGL 1.5 + GL 3.3 Core 全部由 libmithril.dylib 提供
        // （Vulkan backend，经 MoltenVK 到 Metal）。
        // gl_bridge.m 的 dlsym_EGL() 会从 libmithril.dylib 解析 EGL 符号，
        // gl_init_context 用 EGL_OPENGL_BIT + EGL_OPENGL_API 创建 desktop GL 上下文。
        // 下方的统一逻辑会把它设为 LWJGL 的 opengl.libname 并 RTLD_GLOBAL 预加载。
        NSLog(@"[egl_bridge] Mithril renderer: EGL/GL provided by libmithril.dylib (Vulkan backend)");
        set_gl_bridge_tbl();
    } else if (isMobileGLRenderer(renderer.UTF8String)) {
        // MobileGL 渲染器：EGL + GL 由 libMobileGL.dylib 提供。
        // 两个变体共用同一个二进制，用 MOBILEGL_BACKEND_TYPE 选择后端：
        //   libMobileGL.dylib      -> DirectVulkan (GL -> Vulkan -> MoltenVK -> Metal)
        //   libMobileGL-gles.dylib -> DirectGLES   (GL -> OpenGL ES)
        setenv("MOBILEGL_BACKEND_TYPE",
            [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL_GLES] ? "DirectGLES" : "DirectVulkan",
            1);
        // Task156：ES 后端 multidraw 保守档（与 JavaLauncher 主导出处同步；
        // 本路径是无 Java 侧初始化的兑底，已有值不覆盖）。
        const char *ame156_backend = getenv("MOBILEGL_BACKEND_TYPE");
        if (ame156_backend != NULL && strcmp(ame156_backend, "DirectGLES") == 0 &&
            getenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE") == NULL) {
            setenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE", "drawelements", 1);
            NSLog(@"[egl_bridge] Task156: Espryt multidraw tier forced to 'drawelements' (ES blocks-invisible workaround)");
        }
        NSLog(@"[egl_bridge] MobileGL renderer: backend=%s",
            getenv("MOBILEGL_BACKEND_TYPE") ?: "<unset>");
        set_gl_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VIRGL]) {
        // Task 215：VirGLRenderer(≤26.2)（ZL2 移植，Task212 stage 2 落地）
        // guest = libOSMesaVirgl.dylib（Mesa 25.0.7 virgl 驱动，GALLIUM_DRIVER=virgl）
        // 经 VTEST_SOCKET_NAME 连接进程内 vtest server（libvtestserver.dylib，
        // virglrenderer 1.3.0 + libepoxy，宿主 GL = ANGLE/Metal）。
        // 桥接复用 osm_bridge（zink 同款 OSMesaMakeCurrent + glReadPixels 权威呈现）。
        // 注意：本分支必须位于 libOSMesa 前缀分支（zink）之前——
        // libOSMesaVirgl.dylib 同样命中该前缀。
        NSLog(@"[egl_bridge] VirGL renderer: bootstrapping in-process vtest server (Task 215)");
        int ame215_vs_rc = ame_virgl_start_server();
        if (ame215_vs_rc != 0) {
            // Task219：引导失败 → 优雅回退 Zink，绝不放行 guest 去 abort。
            // 病历（6cd2cbfb latestlog.old.txt）：vtest server 起不来时 guest
            //（libOSMesaVirgl）仍会尝试连接，virgl_vtest_negotiate_version
            // 里直接 abort() = 整个进程崩（fatal trace 实锤）。此时 osm 桥
            // 尚未 dlopen guest——把 AMETHYST_RENDERER 换成 zink 前端
            //（libOSMesa.8.dylib）+ GALLIUM_DRIVER=zink，dlsym_OSMesa 会按
            // 新值加载，游戏在 Zink 上继续跑（未调优的 Zink 环境可接受：
            // 这正是“渲染器降级”而非“崩溃”的语义；ZinkConfig 调优在
            // JavaLauncher 的 zink 分支，仅 virgl 会话才会走到这里）。
            NSLog(@"[egl_bridge] Task219 VirGL server bootstrap FAILED (rc=%d) -- diverting renderer to Zink (crash prevention)", ame215_vs_rc);
            setenv("AMETHYST_RENDERER", RENDERER_NAME_VK_ZINK, 1);
            setenv("GALLIUM_DRIVER", "zink", 1);
            renderer = @ RENDERER_NAME_VK_ZINK; // pojavCreateContext 后续日志口径一致
            // 主线程弹一次性说明（不阻塞游戏线程；游戏照常启动）。
            dispatch_async(dispatch_get_main_queue(), ^{
                UIAlertController *ame219_alert = [UIAlertController
                    alertControllerWithTitle:localize(@"ame219.virgl.fallback.title", nil)
                                     message:localize(@"ame219.virgl.fallback.body", nil)
                              preferredStyle:UIAlertControllerStyleAlert];
                [ame219_alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", @"好的")
                                                                  style:UIAlertActionStyleDefault
                                                                handler:nil]];
                // 顶层 VC 手工回溯（无全局 category 可用；仅取 keyWindow 链）。
                UIViewController *ame219_top = nil;
                for (UIScene *ame219_scene in UIApplication.sharedApplication.connectedScenes) {
                    if ([ame219_scene isKindOfClass:[UIWindowScene class]]) {
                        UIViewController *ame219_root = ((UIWindowScene *)ame219_scene).keyWindow.rootViewController;
                        while (ame219_root.presentedViewController != nil) {
                            ame219_root = ame219_root.presentedViewController;
                        }
                        ame219_top = ame219_root;
                        break;
                    }
                }
                if (ame219_top != nil) {
                    [ame219_top presentViewController:ame219_alert animated:YES completion:nil];
                }
            });
        }
        set_osm_bridge_tbl();
    } else if ([renderer hasPrefix:@"libOSMesa"]) {
        setenv("GALLIUM_DRIVER","zink",1);
        set_osm_bridge_tbl();
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VULKAN]) {
        // 关键修复（MoltenVK + OpenGL 黑屏 + 图形 API 切换无效）：
        //
        // 之前 Vulkan 渲染器单向调用 set_vk_bridge_tbl()，一旦设置所有 GL 调用都走
        // vk_bridge 的 stub（vk_init_context 返回 dummy，vk_make_current 空实现）。
        // 当 MC 26.2+ 选 prefer_opengl 时仍走 GL 路径（clientAPI != GLFW_NO_API），
        // 但 bridge 已是 vk stub → 无真实 GL 上下文 → 黑屏。
        //
        // 修复策略（参照 FCL/HMCL 的 renderer + graphicsApi 联动逻辑）：
        //   1. 始终初始化 GL bridge（set_gl_bridge_tbl），让 GL 路径有真实上下文
        //   2. 同时预加载 libMoltenVK.dylib（Vulkan 路径需要）
        //   3. pojavCreateContext 根据 clientAPI 动态决定返回值：
        //      - GLFW_NO_API（Vulkan 路径）→ 返回 CAMetalLayer，MC/LWJGL 自管 Vulkan
        //      - 其他（GL 路径）→ 调用 br_init_context 创建真实 EGL/GL 上下文
        //
        // 这样无论 MC 选 OpenGL 还是 Vulkan 路径都能正常工作：
        //   - prefer_vulkan：MC 走 Vulkan 路径，glfwWindowHint(GLFW_NO_API) → CAMetalLayer
        //   - prefer_opengl：MC 走 GL 路径，glfwWindowHint(GLFW_OPENGL_API) → EGL 上下文
        //   - default：MC 内部决定，两种路径都能处理
        //
        // 注意：JavaLauncher.m 已在 Vulkan 模式下设置 org.lwjgl.opengl.libname=libmobileglues.dylib，
        // 所以 LWJGL 加载的 GL 库是 MobileGlues（GL→Vulkan 翻译层），能通过 Vulkan 后端路由 GL 调用。
        // 这就是用户说的"用 OpenGL 渲染游戏加用 MoltenVK，帧率才能达到 120"的实现原理：
        // MC 走 GL 路径 → EGL 上下文（ANGLE Metal）→ MobileGlues 翻译 → Vulkan → MoltenVK → Metal
        // MobileGlues 的 Vulkan 后端使用 IMMEDIATE present mode，可超过屏幕刷新率。
        NSLog(@"[egl_bridge] Vulkan renderer: initializing GL bridge for OpenGL path fallback (graphicsApi linkage)");
        set_gl_bridge_tbl();
        // 预加载 libMoltenVK.dylib（Vulkan 路径需要，GL 路径不影响）
        dlopen("@rpath/" RENDERER_NAME_VULKAN, RTLD_GLOBAL);
        // Vulkan 模式下 LWJGL OpenGL 库使用 MobileGlues（由 JavaLauncher.m 设置）
        // 不再调用 JNI_LWJGL_changeRenderer(RENDERER_NAME_MTL_ANGLE)，
        // 因为 JavaLauncher.m 已通过 -Dorg.lwjgl.opengl.libname=libmobileglues.dylib 设置
        if (setLwjglProperty) JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
        // 跳过下方的统一 JNI_LWJGL_changeRenderer 和 dlopen（已处理）
        return pojavFinishOpenGLInit(!br_init());
    }
    if (!isMobileGLRenderer(renderer.UTF8String)) {
        // 切换渲染器后清掉 MobileGL 专用环境变量，避免残留影响下一次启动
        unsetenv("MOBILEGL_BACKEND_TYPE");
        unsetenv("MOBILEGL_LOG_FILE_PATH");
        unsetenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE");
    }
    if (setLwjglProperty && strcmp(renderer.UTF8String, RENDERER_NAME_VULKAN) != 0) {
        // Task 131：-gles 变体是逻辑键（物理 dylib 不随包，共享 libMobileGL.dylib
        // 二进制，靠上方分支设置的 MOBILEGL_BACKEND_TYPE=DirectGLES 切后端）。
        // 传给 Java 侧的 libname 必须是磁盘上真实存在的文件——LWJGL 的
        // Platform.mapLibraryName 对含连字符的名字还会二次包装出
        // "liblibMobileGL-gles.dylib.dylib"（JavaLauncher 的 opengl.libname 修复
        // 注释有完整分析），此处直接映射到共享二进制名。
        const char *ame131_libname = strcmp(renderer.UTF8String, RENDERER_NAME_MOBILEGL_GLES) == 0
            ? RENDERER_NAME_MOBILEGL
            : renderer.UTF8String;
        JNI_LWJGL_changeRenderer(ame131_libname);
    }
    // Preload renderer library
    // Task 131：同上，-gles 逻辑键映射回共享的 libMobileGL.dylib 后再 dlopen。
    {
        const char *ame131_load = strcmp(renderer.UTF8String, RENDERER_NAME_MOBILEGL_GLES) == 0
            ? RENDERER_NAME_MOBILEGL
            : renderer.UTF8String;
        dlopen([NSString stringWithFormat:@"@rpath/%s", ame131_load].UTF8String, RTLD_GLOBAL);
    }

    return pojavFinishOpenGLInit(!br_init());
    //return 0;
}

int pojavInitOpenGL(void) {
    return pojavInitOpenGLInternal(YES);
}

/// SDL3 路径专用入口：不写 org.lwjgl.opengl.libname。
///
/// 该属性由 JavaLauncher 在 JVM 启动时以 -D 传入，LWJGL 在 bootstrap 阶段就已读取
/// 并 dlopen 了渲染器库（这正是 MC 26.3 报 "OpenGL library already loaded" 的来源）。
/// 等到 SDL_GL_LoadLibrary 再设这个属性既无效果（LWJGL 的 System property 只在类
/// 初始化时读一次），又要为此把非 JVM 线程 attach 到 VM，属于纯粹的收益为负的操作。
int pojavInitOpenGLForSDL3(void) {
    return pojavInitOpenGLInternal(NO);
}

void pojavSetWindowHint(int hint, int value) {
    if (hint == GLFW_CLIENT_API) {
        clientAPI = value;
    } else if (strcmp(getenv("AMETHYST_RENDERER"), "auto")==0 && hint == GLFW_CONTEXT_VERSION_MAJOR) {
        switch (value) {
            case 1:
            case 2:
                // Task212：legacy 默认渲染器随 holy gl4es 退役改道 ZL2 经典版。
                setenv("AMETHYST_RENDERER", RENDERER_NAME_GL4ESZL2, 1);
                // Task 145：不再导出 POJAV_RENDERER（Sodium 反 Pojav 检测，见主导出处）。
                JNI_LWJGL_changeRenderer(RENDERER_NAME_GL4ESZL2);
                break;
            // case 4: use Zink?
            default:
                setenv("AMETHYST_RENDERER", RENDERER_NAME_MOBILEGLUES, 1);
                // Task 145：同上。
                JNI_LWJGL_changeRenderer(RENDERER_NAME_MOBILEGLUES);
                break;
        }
    }
}

// ---- Task 39：首帧呈现门控（shaderc 编译风暴静止期） ----
//
// 四份日志交叉时序铁证：
//   * e28e4c3-GL（零崩溃）：首次 eglSwapBuffers 在全部 402 次 shaderc 编译
//     完成之后（6.4s）；其后 2.8s 的 post-effect 编译（#391-402）全部干净，
//     全日志 0 崩溃。
//   * bec59b4 / 2613e41 / 2092d27（三连崩）：首次 present 全部插入编译风暴
//     正中（t≈370-485ms），紧随其后的 terrain/OIT 编译在
//     libshaderc_impl+0x512430（Task 34 cave 内 constArray 指针解链 ldr）读到
//     被踩踏的池内存——si_addr 是 ASCII 源码碎片（释放后复用的堆块）。
//   * bec59b4 的 crash si_addr=0x400000008000c 与 2092d27 的 si_addr 乱码族
//     同源：首次 present 的 Metal 机制（首个 CAMetalLayer drawable 分配/CA
//     注册/遮罩移除/框架内部大块分配）在编译活跃期落地会踩碎 glslang 池块。
//
// 修复：复刻已验证的零崩溃时序 —— 首次真实 present 等 shaderc 编译活动
// 静止 >= 2s（或 15s 强制上限防无限黑屏）才放行。被门控期间丢弃帧（启动
// 遮罩本来就在上屏，用户无感知）。后续 present 不门控：e28e4c3-GL 已实证
// 稳态 present 与后续编译共存安全（title 屏持续 60fps present + #391-402
// 编译全部干净）。Vulkan 路径不经过 pojavSwapBuffers（CAMetalLayer 直呈），
// 零崩溃 Vulkan 运行已实证安全，本门控对其惰性。

/// 进程启动起的毫秒数（与 shaderc_shim 的 ame_shim_ms 同款惰性 t0）。
static uint64_t ame_eb_now_ms(void) {
    // Task 41 修复：旧实现 (uint64_t)(now.tv_nsec - t0.tv_nsec) 在秒位进位、
    // 纳秒位退位时无符号下溢（实测打印 18446744074337ms 假值），导致 15s
    // 强制上限在 0.63s 误触发、首帧在编译风暴正中放行。改为同域毫秒差，
    // now >= t0 恒成立（CLOCK_MONOTONIC_RAW 单调），无下溢可能。
    static uint64_t t0_ms = 0;
    static volatile int t0_set = 0;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC_RAW, &now);
    uint64_t now_ms = (uint64_t)now.tv_sec * 1000ull + (uint64_t)now.tv_nsec / 1000000ull;
    if (!t0_set) {
        t0_ms = now_ms;
        t0_set = 1;
    }
    return now_ms - t0_ms;
}

typedef uint64_t (*ame_quiescence_fn_t)(void);

/// 惰性解析 libshaderc.dylib（shaderc_shim.c）导出的编译静默信号。
/// 与 spvc_shim 的主锁协商同款姿势：按已加载镜像 dlopen（仅引用计数 +1，
/// 不会产生第二个实例）后按 handle dlsym，规避 RTLD_LOCAL 不可见问题。
/// RTLD_NOLOAD：镜像未加载（LWJGL 尚未 bootstrap，或非 shaderc 路径）时
/// 返回 NULL —— 无信号即无 shaderc 活动，调用方按"安静"放行（此时也根本
/// 没有 glslang 池可踩）。解析成功后缓存。
static ame_quiescence_fn_t ame_eb_quiescence_fn(void) {
    static ame_quiescence_fn_t s_fn = NULL;
    if (s_fn != NULL) return s_fn;
    static const char *const kCandidates[] = {
        "@rpath/libshaderc.dylib",
        "@loader_path/libshaderc.dylib",
        "libshaderc.dylib",
        NULL,
    };
    for (int i = 0; kCandidates[i] != NULL; ++i) {
        void *h = dlopen(kCandidates[i], RTLD_NOLOAD | RTLD_LAZY);
        if (h == NULL) continue;
        ame_quiescence_fn_t fn =
            (ame_quiescence_fn_t)dlsym(h, "ame_shaderc_compile_quiescence_ms");
        if (fn != NULL) {
            s_fn = fn;
            NSLog(@"[egl_bridge] shaderc quiescence signal acquired -- first-present gate armed (Task 39)");
            break;
        }
    }
    return s_fn;
}

/// 首帧呈现是否放行。YES = 允许本次 present + 首帧通知 + 遮罩移除。
static BOOL ame_eb_first_present_gate_allows(void) {
    // 2s 静止窗口：复刻 e28e4c3-GL 零崩溃时序（首 present 距最后一次编译
    // >= 2s；其后 2.8s 出现的下一批编译全部干净）。
    const uint64_t kQuietMs = 2000;
    // 15s 强制上限：极端场景（超大量光影/资源包、风暴永不停）不能让启动
    // 遮罩无限期挡屏——到点强制放行，代价是回到旧时序的风险。
    const uint64_t kForceCapMs = 15000;
    static uint64_t s_firstAttemptMs = 0;
    static uint64_t s_deferredFrames = 0;

    ame_quiescence_fn_t fn = ame_eb_quiescence_fn();
    uint64_t quiet = (fn != NULL) ? fn() : UINT64_MAX;
    if (quiet >= kQuietMs) return YES; // 从未活动（UINT64_MAX）或已静止

    uint64_t now = ame_eb_now_ms();
    if (s_firstAttemptMs == 0) s_firstAttemptMs = now;
    if (now - s_firstAttemptMs >= kForceCapMs) {
        NSLog(@"[egl_bridge] First present force-released after %llums cap (quiet=%llums, dropped %llu frames) (Task 39)",
              (unsigned long long)(now - s_firstAttemptMs),
              (unsigned long long)quiet,
              (unsigned long long)s_deferredFrames);
        return YES;
    }
    s_deferredFrames++;
    if (s_deferredFrames == 1 || (s_deferredFrames % 120) == 0) {
        NSLog(@"[egl_bridge] First present deferred: shader compile storm active (quiet=%llums < %llu, dropped frames=%llu) (Task 39)",
              (unsigned long long)quiet,
              (unsigned long long)kQuietMs,
              (unsigned long long)s_deferredFrames);
    }
    return NO;
}

void pojavSwapBuffers() {
    // Task 39：首帧呈现门控 —— 在 shaderc 编译风暴静止前，不进行首次
    // eglSwapBuffers/遮罩移除（被门控的帧直接丢弃，遮罩仍在上屏，MC 渲染
    // 线程继续跑）。详见 ame_eb_first_present_gate_allows 的取证注释。
    if (!s_firstFrameRendered && !ame_eb_first_present_gate_allows()) {
        return;
    }

    // FPS 计数（参照 FCL/ZL2 在 native swap buffer 入口计数，反映真实渲染帧率）
    atomic_fetch_add(&_pojavFpsCounter, 1);

    // 阶段13：首帧渲染检测（参照 FCL 的 game_ready 回调）
    // 首次调用 pojavSwapBuffers 表示游戏已渲染第一帧，发送通知移除启动遮罩
    // Task 32 澄清：此处在 eglSwapBuffers 之前触发，只能证明"首次 swap 尝试"，
    // 真实上屏确认看 gl_bridge.m 的 "[RenderDiag] first eglSwapBuffers OK"。
    if (!s_firstFrameRendered) {
        s_firstFrameRendered = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"PojavFirstFrameRendered" object:nil];
            NSLog(@"[egl_bridge] First swap attempted, removing launch overlay (present confirmation: [RenderDiag] first eglSwapBuffers OK)");
        });
    }

    if (!br_swap_buffers) return;
    br_swap_buffers();
}

void pojavMakeCurrent(basic_render_window_t* window) {
    if (!br_make_current) return;
    br_make_current(window);
    // Task208：NG-GL4ES 初始化点——br_make_current 返回即上下文 current。
    // 非 nggl4es 渲染器时 ame208_nggl4es_boot 立即返回（一次 getenv 比较，
    // 零副作用）。幂等：boot 内部 s_ame208_done 门。
    ame208_nggl4es_boot();
    // Task211：ZL2 经典版 gl4es 的同构初始化点（同一时机、同一零副作用
    // 早退、同一幂等门）。
    ame211_gl4eszl2_boot();
}

void* pojavCreateContext(basic_render_window_t* contextSrc) {
    // 用全局幂等标志而非局部 static：SDL3 路径下 SDL_GL_LoadLibrary 已通过
    // pojavInitOpenGLForSDL3() 完成初始化，此处若用局部 static 判定为"未初始化"，
    // 会再调一次完整的 pojavInitOpenGL()，在 SDL 的原生线程上触发 JNI 调用。
    if (!pojavIsOpenGLInited()) {
        pojavInitOpenGL();
    }

    const char *renderer = getenv("AMETHYST_RENDERER");
    const char *graphicsApi = getenv("AMETHYST_GRAPHICS_API");
    NSLog(@"[egl_bridge] pojavCreateContext: clientAPI=%d (GLFW_NO_API=%d), renderer=%s, graphicsApi=%s",
          clientAPI, GLFW_NO_API, renderer ?: "<unset>", graphicsApi ?: "<unset>");

    if (clientAPI == GLFW_NO_API) {
        // Game has selected Vulkan API to render
        // MC 26.2+ graphicsApi=prefer_vulkan 或 default（Vulkan 路径）会走这里
        // 返回 CAMetalLayer 作为 Vulkan surface，MC/LWJGL 通过 libMoltenVK.dylib 自管 Vulkan
        NSLog(@"[egl_bridge] Vulkan path: returning CAMetalLayer as Vulkan surface");
        return (__bridge void *)SurfaceViewController.surface.layer;
    }

    // GL 路径（clientAPI == GLFW_OPENGL_API 或 GLFW_OPENGL_ES_API）
    // MC 26.2+ graphicsApi=prefer_opengl 或 default（OpenGL 路径）会走这里
    // 调用 br_init_context 创建真实 EGL/GL 上下文
    // 即使 renderer=libMoltenVK.dylib，pojavInitOpenGL 已设置 GL bridge（set_gl_bridge_tbl），
    // 所以这里会调用 gl_init_context 创建 ANGLE Metal EGL 上下文
    NSLog(@"[egl_bridge] OpenGL path: creating EGL/GL context via br_init_context");
    return br_init_context(contextSrc);
}

void pojavSwapInterval(int interval) {
    // Vulkan 模式诊断：即使 br_swap_interval 为 NULL（Vulkan 不使用 EGL swap interval），
    // 也记录调用以帮助诊断帧率解锁问题
    if (!br_swap_interval) {
        const char* vsyncEnv = getenv("POJAV_DISABLE_VSYNC");
        NSLog(@"[egl_bridge] pojavSwapInterval(%d) called but br_swap_interval is NULL "
              @"(likely Vulkan mode). POJAV_DISABLE_VSYNC=%s. "
              @"Vulkan present mode is controlled by vkCreateSwapchainKHR, not eglSwapInterval.",
              interval, vsyncEnv ?: "<unset>");
        return;
    }
    // 解锁帧率（关闭垂直同步）：当启动器偏好 video.disable_game_vsync 开启时
    // （POJAV_DISABLE_VSYNC=1，由 JavaLauncher.m 设置），强制 swap interval=0，
    // 覆盖游戏 glfwSwapInterval(1) 的垂直同步请求。
    //
    // 这是 GL 类渲染器（gl4es/ANGLE/MobileGlues）真正生效 VSync 的落点
    // （gl_bridge.m gl_swap_interval → eglSwapInterval）。
    //
    // ANGLE Metal 后端对 eglSwapInterval 的处理：
    // - interval=0：eglSwapBuffers 不等待 vblank，渲染线程可立即继续下一帧渲染。
    //   虽然 Core Animation 仍按屏幕刷新率合成（60/120Hz），但渲染线程不被阻塞，
    //   可保持高吞吐量。多余的帧会被 Core Animation 丢弃，但 FPS 计数器反映渲染帧率。
    // - interval=1：eglSwapBuffers 等待 vblank，渲染线程被锁在屏幕刷新率。
    //
    // 与 PojavLauncher.java 写 enableVsync=false 互为兜底：即便游戏在运行时再次请求
    // VSync（某些 mod/版本会重设），native 层也会拦截。
    //
    // 与 Vulkan 渲染器的区别：
    // - GL 类渲染器（含 zink）：VSync 通过 eglSwapInterval 控制（此处生效）
    //   zink 创建 swapchain 时根据 eglSwapInterval 选择 present mode：
    //   interval=0 → IMMEDIATE（不等 vsync），interval=1 → FIFO（等 vsync）
    // - Vulkan 渲染器：VSync 通过 vkCreateSwapchainKHR 的 presentMode 控制
    //   （由 LWJGL 根据 glfwSwapInterval 选择，设备能力由 MoltenVK 自动检测）

    const char* vsyncEnv = getenv("POJAV_DISABLE_VSYNC");
    const char* renderer = getenv("AMETHYST_RENDERER");

    if (vsyncEnv && strcmp(vsyncEnv, "1") == 0) {
        if (interval != 0) {
            // 关键修复（FPS 解锁无效问题）：记录每次 VSync 拦截
            // 某些 mod（如 OptiFine、Sodium）或 MC 版本会在运行时反复调用 glfwSwapInterval(1)
            // 重新启用 VSync。记录每次拦截帮助诊断"帧率被重新锁定"的问题。
            // 之前只记录前几次，无法发现运行中被 mod 重新启用的情况。
            NSLog(@"[egl_bridge] pojavSwapInterval: intercepted VSync request interval=%d -> 0 (POJAV_DISABLE_VSYNC=1, renderer=%s)", interval, renderer ?: "<unset>");
        }
        interval = 0;
    } else {
        // 仅记录前几次调用，帮助诊断
        static int s_logCount = 0;
        if (s_logCount < 3) {
            s_logCount++;
            NSLog(@"[egl_bridge] pojavSwapInterval(%d) called (POJAV_DISABLE_VSYNC=%s, renderer=%s, count=%d)",
                  interval, vsyncEnv ?: "<unset>", renderer ?: "<unset>", s_logCount);
        }
    }

    br_swap_interval(interval);
}

