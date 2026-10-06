//
//  virgl_server.m
//  Amethyst-iOS-MyRemastered
//
//  Task 111：VirGLRenderer(≤26.2)（ZalithLauncher2 移植）—— 服务端引导桥。
//
//  架构（对齐 ZL2 virgl_bridge.c 的进程内模型，宿主 GL 换成我们的 ANGLE/Metal）：
//
//    MC(LWJGL) --gl*--> libOSMesaVirgl.dylib(Mesa 25.0.7 virgl 驱动, GALLIUM_DRIVER=virgl)
//        --vtest 协议(unix socket, VTEST_SOCKET_NAME)--> libvtestserver.dylib
//        (virglrenderer 1.3.0 + libepoxy) --epoxy(EGL/GLES)--> ANGLE 框架 --> Metal
//
//    呈现：复用 osm_bridge 的 zink 链路（OSMesaMakeCurrent + swap 时
//    glReadPixels 权威回读 + CGImage 上屏）。guest 的 glReadPixels 经
//    vtest transfer 从服务端取回像素，天然正确。
//
//  本文件只做三件事：
//    1. 确定 socket 路径并设置 VTEST_SOCKET_NAME / GALLIUM_DRIVER=virgl
//    2. 用随 app 打包的 ANGLE 框架创建一个离屏(1x1 pbuffer) ES3 宿主上下文
//    3. 起一个线程：MakeCurrent 后调 libvtestserver.dylib 的 vtest_main(
//       "--no-loop-or-fork" "--use-gles" "--socket-path" <path>)
//       （vrend 内部经 epoxy 在同一 EGL display 上按需创建自己的 GLES 上下文）
//
//  注意：vtest_server 内部错误路径会 exit(1)（上游行为，ZL2 同款），
//  socket 采用 unlink+bind，二次启动安全；--no-loop-or-fork 单客户端
//  单发服务，guest 断开即返回。
//

#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <errno.h>

// Task219（用户报 VirGL 崩溃，6cd2cbfb 双日志判读）：本文件此前【没有】
// import utils.h——而 utils.h 把 NSLog 宏重定义为 customNSLog（走 latestlog
// 管道），于是本文件里全部 [VirGL] 诊断走的是真 NSLog = 只进 os_log，
// latestlog 一条不见（装机日志实锤：egl_bridge 报“check [VirGL] logs
// above”而日志里零条 [VirGL]）。诊断盲区必须先修，后修根因。
#import "utils.h"

#include "virgl_server.h"

// ---------------------------------------------------------------------------
// raw ANGLE EGL 函数指针（从随 app 打包的 libEGL.framework 解析；
// 与 gl_bridge.m 的 raw ANGLE 同款做法，保持本文件自包含）
// ---------------------------------------------------------------------------
typedef unsigned int EGLBoolean;
typedef void *EGLDisplay;
typedef void *EGLConfig;
typedef void *EGLSurface;
typedef void *EGLContext;
typedef intptr_t EGLNativeDisplayType;
// ★ Task223（用户报“VirGL 依旧崩溃”，2832c2b 日志判读）：EGLint 必须是
// 32 位 int——此前 typedef intptr_t（arm64 上 64 位）导致传给真 ANGLE
// eglChooseConfig 的属性数组被按 32 位消费时错位（名值对变成
// (0x3033, 0) + 非法属性名 1 = EGL_BAD_ATTRIBUTE → EGL_FALSE），两轮
// pass 全部报“found no pbuffer config”、引导 rc=-1 → zink 兜底。ABI 修
// 正后 pbuffer 查询与 ctx_attribs/pbuffer_attribs 三处同时恢复正确。
typedef int EGLint;

static EGLBoolean (*ame_vs_eglGetError)(void);
static const char *(*ame_vs_eglQueryString)(EGLDisplay, unsigned int);
#define AME_VS_EGL_EXTENSIONS 0x3055
#define AME_VS_EGL_NO_SURFACE  ((EGLSurface)0)
#define AME_VS_EGL_OPENGL_ES3_BIT_KHR 0x0040

static EGLDisplay (*ame_vs_eglGetDisplay)(EGLNativeDisplayType);  /* Task216 hotfix 4: return type is EGLDisplay (void*), not EGLBoolean -- clang 15+ promotes -Wint-conversion to error at the ame_vs_display assignment (run 605) */
static EGLBoolean (*ame_vs_eglInitialize)(EGLDisplay, EGLint *, EGLint *);
static EGLBoolean (*ame_vs_eglBindAPI)(unsigned int);
static EGLBoolean (*ame_vs_eglChooseConfig)(EGLDisplay, const EGLint *, EGLConfig *, EGLint, EGLint *);
static EGLSurface (*ame_vs_eglCreatePbufferSurface)(EGLDisplay, EGLConfig, const EGLint *);
static EGLContext (*ame_vs_eglCreateContext)(EGLDisplay, EGLConfig, EGLContext, const EGLint *);
static EGLBoolean (*ame_vs_eglMakeCurrent)(EGLDisplay, EGLSurface, EGLSurface, EGLContext);

static EGLDisplay ame_vs_display;
static EGLSurface ame_vs_pbuffer;
static EGLContext ame_vs_context;
static char ame_vs_socket_path[512];
static int ame_vs_started = 0;
static BOOL ame223_use_surfaceless = NO;  // Task223：EGL_KHR_surfaceless_context 兑底路径

// Task219：多候选 dlopen（对齐 gl_bridge.m 的 kEglCandidates 三级链）。
// 病历（6cd2cbfb latestlog.old.txt，VirGL 会话）：旧代码只试
// “@rpath/libEGL.framework/libEGL” 单一路径——LiveContainer 环境下
// @rpath 解析可能落到宿主 App.app 而非内嵌应用，dlopen 失败即引导
// rc=-1；而同 build 的 ANGLE 会话（gl_bridge 走 @executable_path 优先）
// 一切正常。宿主 GL 上下文与 vtest server 库都改走候选链。
static void *ame219_dlopen_first(const char *const *candidates) {
    for (int i = 0; candidates[i] != NULL; ++i) {
        void *h = dlopen(candidates[i], RTLD_NOW | RTLD_LOCAL);
        if (h != NULL) {
            if (i > 0) {
                NSLog(@"[VirGL] Task219 dlopen resolved via candidate #%d: %s", i + 1, candidates[i]);
            }
            return h;
        }
        NSLog(@"[VirGL] Task219 dlopen candidate failed: %s (%s)", candidates[i], dlerror() ?: "unknown");
    }
    return NULL;
}

/// Task219：vtest socket 路径缩短 + 唯一化。
/// 病历（同上）：旧路径 "$POJAV_HOME/.virgl_test" 在多容器布局下长达
/// ~170 字节，远超 sockaddr_un.sun_path 的 104 字节上限——vtest_main 的
/// bind() 必败（上游错误路径直接 exit(1)）。改用 App 沙盒 tmp 下的短路径
/// + pid 后缀（guest 与 server 同进程，任何可写路径都可用；pid 后缀防
/// LiveContainer 多开撞名）。仍保留长度守卫：极端长 tmp 兜底 /tmp 根。
/// Task225（反馈 #1：VirGL 依旧崩溃——02a3fe1 日志集 latestlog.old.txt 实锤）：
/// 旧实现 getenv("TMPDIR") 在 LiveContainer 环境下解析到全局 /tmp——iOS
/// 沙盒对共享目录禁止 bind(AF_UNIX)（"Failed to setup socket.: Operation not
/// permitted" → vtest_main exit(1) 杀进程，用户表现为闪退）。修法：【目录
/// 候选链 + 探测验证】——NSTemporaryDirectory()（App 容器内 tmp，沙盒保证
/// 可写可 bind）优先，TMPDIR / POJAV_HOME 兜底；每个候选目录用一次性 probe
/// socket（bind+close+unlink；探针是我们自己的，不碰 vtest 单发服务的唯一
/// 连接名额）验证 bind 权限，首个通过者胜。全部失败时保留 /tmp 短路径
/// （长度守卫不变）——此时 vtest_server.c 的 Task225 修复把失败从 exit(1)
/// 降级为线程返回，客户端 15s 等待超时后走 zink 兜底，绝不杀进程。
static BOOL ame225_dir_allows_unix_bind(const char *dir) {
    if (!dir || !*dir) return NO;
    char probe[512];
    int n = snprintf(probe, sizeof(probe), "%s/ame_virgl_probe_%d.sock", dir, (int)getpid());
    if (n < 0 || (size_t)n >= sizeof(probe) ||
        n >= (int)(sizeof(((struct sockaddr_un *)0)->sun_path)) - 2) {
        return NO;  // 目录过长 → 后续真 socket 也会超限，直接判不过
    }
    int fd = socket(PF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_un un;
    memset(&un, 0, sizeof(un));
    un.sun_family = AF_UNIX;
    strncpy(un.sun_path, probe, sizeof(un.sun_path) - 1);
    unlink(probe);  // 清旧探针
    BOOL ok = NO;
    if (bind(fd, (struct sockaddr *)&un, sizeof(un)) == 0) {
        // bind 成功即为充分证据（listen 紧随 bind，无独立失败面）；立即拆探针
        ok = YES;
    } else {
        NSLog(@"[VirGL] Task225 unix-bind probe FAILED in %s (errno=%d: %s)",
              dir, errno, strerror(errno));
    }
    close(fd);
    unlink(probe);
    return ok;
}

static void ame219_compute_socket_path(void) {
    // Task225：候选链 = NSTemporaryDirectory() → TMPDIR → POJAV_HOME → /tmp，
    // 每个候选先探针验证 bind 权限（旧版直接信 TMPDIR，LiveContainer 下
    // TMPDIR=/tmp → EPERM → exit(1) 闪退，装机实锤）。
    const char *candidates[4] = { NULL, NULL, NULL, NULL };
    static char ame225_nstmp[384];
    NSString *nstmp = NSTemporaryDirectory();
    if (nstmp.length > 0 && nstmp.length < sizeof(ame225_nstmp) - 1) {
        // 统一尾部斜杠语义（拼接时不再双斜杠）
        strncpy(ame225_nstmp, nstmp.UTF8String, sizeof(ame225_nstmp) - 1);
        ame225_nstmp[sizeof(ame225_nstmp) - 1] = '\0';
        size_t ame225_len = strlen(ame225_nstmp);
        if (ame225_len > 0 && ame225_nstmp[ame225_len - 1] == '/') {
            ame225_nstmp[ame225_len - 1] = '\0';
        }
        candidates[0] = ame225_nstmp;
    }
    const char *tmpdir_env = getenv("TMPDIR");
    if (tmpdir_env && *tmpdir_env) candidates[1] = tmpdir_env;
    const char *pojav_home = getenv("POJAV_HOME");
    if (pojav_home && *pojav_home) candidates[2] = pojav_home;
    candidates[3] = "/tmp";

    const char *chosen = NULL;
    for (int i = 0; i < 4 && chosen == NULL; ++i) {
        const char *dir = candidates[i];
        if (!dir || !*dir) continue;
        if (ame225_dir_allows_unix_bind(dir)) {
            chosen = dir;
        }
    }
    if (chosen == NULL) {
        chosen = "/tmp";
        NSLog(@"[VirGL] Task225 NO candidate dir allows unix bind -- keeping /tmp (vtest failure will degrade, not crash)");
    }
    int n = snprintf(ame_vs_socket_path, sizeof(ame_vs_socket_path),
                     "%s/ame_virgl_%d.sock", chosen, (int)getpid());
    if (n < 0 || (size_t)n >= sizeof(ame_vs_socket_path) ||
        n >= (int)(sizeof(((struct sockaddr_un *)0)->sun_path)) - 2) {
        snprintf(ame_vs_socket_path, sizeof(ame_vs_socket_path),
                 "/tmp/ame_virgl_%d.sock", (int)getpid());
    }
    NSLog(@"[VirGL] Task225 socket dir chosen: %s (socket=%s)", chosen, ame_vs_socket_path);
    // 换代滑理：旧会话可能残留同 pid 的 socket 文件（vtest unlink+bind 兜底，
    // 这里先行清理一次双保险）。
    unlink(ame_vs_socket_path);
}

// vtest server 入口（libvtestserver.dylib 导出；上游 vtest_server.c:135）
static int (*ame_vs_vtest_main)(int argc, char **argv);

// EGL 常量（避免引入 EGL 头依赖）
#define AME_VS_EGL_DEFAULT_DISPLAY   ((EGLNativeDisplayType)0)
#define AME_VS_EGL_OPENGL_ES_API     0x30A0
#define AME_VS_EGL_SURFACE_TYPE      0x3033
#define AME_VS_EGL_PBUFFER_BIT       0x0001
#define AME_VS_EGL_RENDERABLE_TYPE   0x3040
#define AME_VS_EGL_OPENGL_ES2_BIT    0x0004
#define AME_VS_EGL_RED_SIZE          0x3024
#define AME_VS_EGL_GREEN_SIZE        0x3023
#define AME_VS_EGL_BLUE_SIZE         0x3022
#define AME_VS_EGL_ALPHA_SIZE        0x3021
#define AME_VS_EGL_WIDTH             0x3057
#define AME_VS_EGL_HEIGHT            0x3056
#define AME_VS_EGL_CONTEXT_CLIENT_VERSION 0x3098
#define AME_VS_EGL_NONE              0x3038

static void *ame_vs_server_thread(void *arg __unused)
{
    // ZL2 同款顺序：先 MakeCurrent（vrend 经 epoxy 感知当前上下文/display），
    // 再进 vtest 主循环。
    // Task223：surfaceless 模式下用 EGL_NO_SURFACE（上游 vrend_winsys_egl.c
    // 的原生形态）；pbuffer 模式维持宿主载体表面。
    EGLSurface ame223_draw = ame223_use_surfaceless ? AME_VS_EGL_NO_SURFACE : ame_vs_pbuffer;
    if (ame_vs_eglMakeCurrent(ame_vs_display, ame223_draw, ame223_draw, ame_vs_context) != 1) {
        NSLog(@"[VirGL] Task111 host eglMakeCurrent failed (surfaceless=%d, eglError=0x%x) -- server thread aborting",
              (int)ame223_use_surfaceless, ame_vs_eglGetError ? (int)ame_vs_eglGetError() : -1);
        return NULL;
    }

    static const char *const kAme219VtestLibs[] = {
        "@executable_path/Frameworks/" AME_VIRGL_VTEST_SERVER_LIB,
        "@rpath/" AME_VIRGL_VTEST_SERVER_LIB,
        NULL,
    };
    void *vs = ame219_dlopen_first(kAme219VtestLibs);
    if (!vs) {
        NSLog(@"[VirGL] Task219 dlopen %s failed on all candidates", AME_VIRGL_VTEST_SERVER_LIB);
        return NULL;
    }
    NSLog(@"[VirGL] Task219 vtest server thread entering (socket=%s)", ame_vs_socket_path);
    ame_vs_vtest_main = (int (*)(int, char **))dlsym(vs, "vtest_main");
    if (!ame_vs_vtest_main) {
        NSLog(@"[VirGL] Task111 vtest_main not found in %s", AME_VIRGL_VTEST_SERVER_LIB);
        return NULL;
    }

    NSLog(@"[VirGL] Task111 starting vtest server (no-loop-or-fork, use-gles, socket=%s)", ame_vs_socket_path);
    // getopt_long 要求 argv[argc] == NULL；参数与 ZL2 完全一致（外加显式 socket 路径）
    char arg0[] = "vtest";
    char arg1[] = "--no-loop-or-fork";
    char arg2[] = "--use-gles";
    char arg3[] = "--socket-path";
    char *argv[] = { arg0, arg1, arg2, arg3, ame_vs_socket_path, NULL };
    int rc = ame_vs_vtest_main(5, argv);
    NSLog(@"[VirGL] Task111 vtest server finished with rc=%d (guest disconnected?)", rc);
    return NULL;
}

int ame_virgl_start_server(void)
{
    if (ame_vs_started) {
        return 0; // 幂等
    }

    // ---- 1. socket 路径（Task219 短路径 + pid 唯一化）+ guest 环境变量
    //（必须在 osm_bridge dlopen guest 之前）----
    ame219_compute_socket_path();
    setenv("VTEST_SOCKET_NAME", ame_vs_socket_path, 1);
    setenv("GALLIUM_DRIVER", "virgl", 1);
    NSLog(@"[VirGL] Task219 socket path = %s (len=%lu, sun_path cap=%lu)",
          ame_vs_socket_path, (unsigned long)strlen(ame_vs_socket_path),
          (unsigned long)sizeof(((struct sockaddr_un *)0)->sun_path));

    // ---- 2. raw ANGLE EGL：离屏宿主上下文（Task219 候选链 dlopen）----
    static const char *const kAme219EglLibs[] = {
        "@executable_path/Frameworks/libEGL.framework/libEGL",
        "@rpath/libEGL.framework/libEGL",
        "libEGL",
        NULL,
    };
    void *egl = ame219_dlopen_first(kAme219EglLibs);
    if (!egl) {
        NSLog(@"[VirGL] Task219 dlopen ANGLE libEGL failed on all candidates");
        return -1;
    }
    ame_vs_eglGetDisplay = (void *)dlsym(egl, "eglGetDisplay");
    ame_vs_eglInitialize = (void *)dlsym(egl, "eglInitialize");
    ame_vs_eglBindAPI = (void *)dlsym(egl, "eglBindAPI");
    ame_vs_eglChooseConfig = (void *)dlsym(egl, "eglChooseConfig");
    ame_vs_eglCreatePbufferSurface = (void *)dlsym(egl, "eglCreatePbufferSurface");
    ame_vs_eglCreateContext = (void *)dlsym(egl, "eglCreateContext");
    ame_vs_eglMakeCurrent = (void *)dlsym(egl, "eglMakeCurrent");
    ame_vs_eglGetError = (void *)dlsym(egl, "eglGetError");
    ame_vs_eglQueryString = (void *)dlsym(egl, "eglQueryString");
    if (!ame_vs_eglGetDisplay || !ame_vs_eglInitialize || !ame_vs_eglChooseConfig ||
        !ame_vs_eglCreatePbufferSurface || !ame_vs_eglCreateContext || !ame_vs_eglMakeCurrent ||
        !ame_vs_eglBindAPI) {
        NSLog(@"[VirGL] Task111 ANGLE EGL symbol resolution incomplete");
        return -1;
    }

    ame_vs_display = ame_vs_eglGetDisplay(AME_VS_EGL_DEFAULT_DISPLAY);
    if (!ame_vs_display) {
        NSLog(@"[VirGL] Task111 eglGetDisplay failed");
        return -1;
    }
    if (ame_vs_eglInitialize(ame_vs_display, NULL, NULL) != 1) {
        NSLog(@"[VirGL] Task111 eglInitialize failed");
        return -1;
    }
    ame_vs_eglBindAPI(AME_VS_EGL_OPENGL_ES_API);

    // Task219：配置回退链（ES3_BIT 优先，ES2_BIT 兑底）+ 逐档日志。
    // 旧代码只试 PBUFFER+ES2_BIT 一档，失败无从分辨是哪档断了。
    EGLConfig config = NULL;
    EGLint num_configs = 0;
    static const EGLint ame219_es3_bit = 0x0040; // EGL_OPENGL_ES3_BIT
    BOOL ame219_configOk = NO;
    for (int ame219_pass = 0; ame219_pass < 2 && !ame219_configOk; ++ame219_pass) {
        const EGLint config_attribs[] = {
            AME_VS_EGL_SURFACE_TYPE, AME_VS_EGL_PBUFFER_BIT,
            AME_VS_EGL_RENDERABLE_TYPE, (ame219_pass == 0) ? ame219_es3_bit : AME_VS_EGL_OPENGL_ES2_BIT,
            AME_VS_EGL_RED_SIZE, 8,
            AME_VS_EGL_GREEN_SIZE, 8,
            AME_VS_EGL_BLUE_SIZE, 8,
            AME_VS_EGL_ALPHA_SIZE, 8,
            AME_VS_EGL_NONE
        };
        if (ame_vs_eglChooseConfig(ame_vs_display, config_attribs, &config, 1, &num_configs) == 1 &&
            config && num_configs >= 1) {
            ame219_configOk = YES;
            NSLog(@"[VirGL] Task219 eglChooseConfig pass#%d (ES%d_BIT) ok (%d config)",
                  ame219_pass + 1, (ame219_pass == 0) ? 3 : 2, (int)num_configs);
        } else {
            // Task223：区分“调用失败（EGL_FALSE + 错误码）”与“零匹配”，
            // 下一轮装机日志不再两眼一抹黑。
            NSLog(@"[VirGL] Task219 eglChooseConfig pass#%d (ES%d_BIT) found no pbuffer config (ret=%d eglError=0x%x)",
                  ame219_pass + 1, (ame219_pass == 0) ? 3 : 2,
                  (int)(ame_vs_eglChooseConfig ? 0 : -1),
                  ame_vs_eglGetError ? (int)ame_vs_eglGetError() : -1);
        }
    }
    if (!ame219_configOk) {
        // ★ Task223：pbuffer 档全败时的 surfaceless 兑底（上游 vrend_winsys_egl.c
        // 本就全程 eglMakeCurrent(dpy, EGL_NO_SURFACE, EGL_NO_SURFACE, ctx)——
        // 1x1 pbuffer 只是宿主上下文载体，从不是渲染必需品）。ANGLE Metal 若
        // 在某些构建里不暴露 PBUFFER 位配置，这里改用任意 ES3 配置 +
        // EGL_KHR_surfaceless_context 完成 MakeCurrent，VirGL 链路照常工作。
        const char *ame223_ext = ame_vs_eglQueryString
            ? ame_vs_eglQueryString(ame_vs_display, AME_VS_EGL_EXTENSIONS) : NULL;
        BOOL ame223_surfaceless = (ame223_ext != NULL &&
            strstr(ame223_ext, "EGL_KHR_surfaceless_context") != NULL);
        NSLog(@"[VirGL] Task223 pbuffer configs unavailable; surfaceless fallback: ext=%@",
              ame223_surfaceless ? @"YES" : @"NO");
        if (ame223_surfaceless) {
            const EGLint sl_attribs[] = {
                AME_VS_EGL_RENDERABLE_TYPE, ame219_es3_bit,
                AME_VS_EGL_RED_SIZE, 8,
                AME_VS_EGL_GREEN_SIZE, 8,
                AME_VS_EGL_BLUE_SIZE, 8,
                AME_VS_EGL_NONE
            };
            if (ame_vs_eglChooseConfig(ame_vs_display, sl_attribs, &config, 1, &num_configs) == 1 &&
                config && num_configs >= 1) {
                ame219_configOk = YES;
                ame223_use_surfaceless = YES;
                NSLog(@"[VirGL] Task223 surfaceless config chosen (ES3, any surface type)");
            }
        }
    }
    if (!ame219_configOk) {
        return -1;
    }

    const EGLint pbuffer_attribs[] = {
        AME_VS_EGL_WIDTH, 1,
        AME_VS_EGL_HEIGHT, 1,
        AME_VS_EGL_NONE
    };
    if (!ame223_use_surfaceless) {
        ame_vs_pbuffer = ame_vs_eglCreatePbufferSurface(ame_vs_display, config, pbuffer_attribs);
        if (!ame_vs_pbuffer) {
            NSLog(@"[VirGL] Task111 eglCreatePbufferSurface failed (eglError=0x%x)",
                  ame_vs_eglGetError ? (int)ame_vs_eglGetError() : -1);
            return -1;
        }
    }

    const EGLint ctx_attribs[] = {
        AME_VS_EGL_CONTEXT_CLIENT_VERSION, 3,
        AME_VS_EGL_NONE
    };
    ame_vs_context = ame_vs_eglCreateContext(ame_vs_display, config, NULL /* no share */, ctx_attribs);
    if (!ame_vs_context) {
        NSLog(@"[VirGL] Task111 eglCreateContext(ES3) failed");
        return -1;
    }

    // ---- 3. 服务线程 ----
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    // vrend 着色器编译可能在服务端深度递归，给足栈（对齐 main_hook 32MB 经验值）
    pthread_attr_setstacksize(&attr, 16 * 1024 * 1024);
    int rc = pthread_create(&thread, &attr, ame_vs_server_thread, NULL);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        NSLog(@"[VirGL] Task111 pthread_create failed: %d", rc);
        return -1;
    }

    // ZL2 同款：给服务端 100ms 完成 bind+listen 进入 accept（backlog 也会兜住
    // 更早到来的连接，这里只是额外保险）。
    // Task219：引导后验证（socket 文件已建 + 确为 socket 类型）。旧代码
    // pthread_create 成功即返 0，但 vtest_main 的 bind/listen 可能同步瞬间
    // 失败（上游错误路径直接 exit(1) 或线程早退）——guest 连不上就在
    // virgl_vtest_negotiate_version 里 abort 崩进程。⚠️ 只查文件、绝不
    // connect 探测：vtest --no-loop-or-fork 是【单发】服务，探针连接会
    // 占掉唯一名额（探针 close = EOF = vtest_main 返回 = 服务下线），
    // guest 真连接反而被拒——等于自己造出引导失败。bind() 成功必然创建
    // socket 文件，文件存在 + S_ISSOCK 即为“服务已 bind”的充分证据
    //（bind 是长路径/权限类的失败点；listen 紧随 bind，无独立失败面）。
    // Task224: vrend init (epoxy dlsym + Mesa virgl driver + shader cache
    // warm-up) takes far longer than the old fixed 100ms sleep on device.
    // Poll for the socket file (bind() creates it) up to 15s, 250ms steps,
    // 3s-interval wait anchors. Still file-stat only, never connect-probing
    // (single-shot server semantics, see Task219 comment above).
    struct stat ame219_st;
    int ame224_bound = 0;
    int ame224_waited_ms = 0;
    while (ame224_waited_ms <= 15000) {
        if (stat(ame_vs_socket_path, &ame219_st) == 0 && S_ISSOCK(ame219_st.st_mode)) {
            ame224_bound = 1;
            break;
        }
        usleep(250 * 1000);
        ame224_waited_ms += 250;
        if (ame224_waited_ms > 0 && (ame224_waited_ms % 3000) == 0) {
            NSLog(@"[VirGL] Task224 still waiting for vtest bind (%.1fs, socket=%s)",
                  ame224_waited_ms / 1000.0, ame_vs_socket_path);
        }
    }
    if (!ame224_bound) {
        NSLog(@"[VirGL] Task219 post-bootstrap check FAILED after %dms (Task224 wait): socket file missing or not a socket (%s) -- server never bound",
              ame224_waited_ms, ame_vs_socket_path);
        return -2;
    }
    NSLog(@"[VirGL] Task219 post-bootstrap check ok (bound after %dms of Task224 wait): socket at %s",
          ame224_waited_ms, ame_vs_socket_path);

    ame_vs_started = 1;
    NSLog(@"[VirGL] Task111 server bootstrap complete (socket=%s, ES3 host ctx=%p, surfaceless=%d)",
          ame_vs_socket_path, ame_vs_context, (int)ame223_use_surfaceless);
    return 0;
}
