#import <Foundation/Foundation.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <mach/mach_time.h>
#include "environ.h"
#include "utils.h"

#include "bridge_tbl.h"
#include "osm_bridge.h"
#include "osmesa_internal.h"

// Task 83（FSR 独立化）：复用 MobileGlues 的 FSR1 EASU shader（#version 450，
// MG 上下文原生编译）。Task 83b 修正：zink 经 MoltenVK 的 GLSL 上限只有
// 4.10（装机日志实锤），需版本自适应后才能编过（见 ame83_adapt_shader_version）。
// 该头是纯字符串字面量（clang/gcc 的 C/ObjC 模式均接受 raw string 字面量），
// 每个包含它的 TU 各持一份私有拷贝——启动器主二进制与 libmobileglues.dylib
// 互不可见，无符号冲突。
#include "../external/MobileGlues/MobileGlues-cpp/gl/FSR1/FSRShaderSource.h"
// Task 130：RCAS 锐化 pass 2 源（static const，internal linkage——本 TU 私有
// 副本，与 FSRShaderSource.h 的非 static 全局定义划清界限，bd71210 教训）。
#include "FSRRCASSource.h"

static osmesa_library handle;
static void *s_osmDL = NULL;   // libOSMesa 句柄（dlsym_OSMesa 保存，FSR GL 惰性解析用）

// Task 83（ObjC++ 化）：C++ 禁止 void* → 函数指针的隐式转换（C 放行，
// CI run 34993498502 报 "converts between void pointer and function pointer"）。
// 用 __typeof__ 显式转型（clang GNU 扩展，C/C++ 双模式可用），零行为变化。
#define AME83_DLSYM_SLOT(slot, sym) (slot) = (__typeof__(slot))dlsym(dl_handle, (sym))

void dlsym_OSMesa() {
    void* dl_handle = dlopen([NSString stringWithFormat:@"@rpath/%s", getenv("AMETHYST_RENDERER")].UTF8String, RTLD_GLOBAL);
    assert(dl_handle);
    s_osmDL = dl_handle;
    AME83_DLSYM_SLOT(handle.OSMesaMakeCurrent, "OSMesaMakeCurrent");
    AME83_DLSYM_SLOT(handle.OSMesaGetCurrentContext, "OSMesaGetCurrentContext");
    AME83_DLSYM_SLOT(handle.OSMesaCreateContext, "OSMesaCreateContext");
    AME83_DLSYM_SLOT(handle.OSMesaDestroyContext, "OSMesaDestroyContext");
    AME83_DLSYM_SLOT(handle.OSMesaPixelStore, "OSMesaPixelStore");
    AME83_DLSYM_SLOT(handle.glGetString, "glGetString");
    AME83_DLSYM_SLOT(handle.glClearColor, "glClearColor");
    AME83_DLSYM_SLOT(handle.glClear, "glClear");
    AME83_DLSYM_SLOT(handle.glFinish, "glFinish");
}

bool osm_init() {
    dlsym_OSMesa();
    return true; // no more specific initialization required
}

osm_render_window_t* osm_init_context(osm_render_window_t* share) {
    // Task 83（ObjC++ 化）：calloc 返回 void*，C++ 禁止隐式转结构体指针（显式转型）
    osm_render_window_t* render_window = (osm_render_window_t*)calloc(1, sizeof(osm_render_window_t));
    OSMesaContext context = handle.OSMesaCreateContext(GL_RGBA, share ? share->context : NULL);
    if(!context) {
        NSLog(@"OSMBridge: FAILED to create context");
        free(render_window);
        return NULL;
    }
    render_window->context = context;
    return render_window;
}

// ============================================================================
// Task 83（FSR 独立化）：zink 通用 FSR1 EASU——呈现前升采样
//
// 语义（与 MG 内置 FSR1 的 Task78 联动同构）：
//   - MC 窗口信念 windowWidth×windowHeight = surface / fsr_scale（渲染分辨率），
//     由 SurfaceViewController 的 Task83 联动下发；
//   - OSMesa 缓冲 = 全尺寸表面（ame_surfaceWidth×Height，全局单点写入），
//     MC 以自己的视口把帧画进缓冲的 window 尺寸区域（GL 原点左下）；
//   - 本 pass 在 osm_swap_buffers（glFinish 之后）把该区域 EASU 升采样
//     铺满整个缓冲，CGImage 上屏即全幅。EASU shader 与 MobileGlues 逐字
//     相同（uniform：uInputTex/uViewportSize/uTargetSize）。
//
// 逐帧成本：glCopyTexSubImage2D（GPU 侧拷贝，zink 映射为 Vulkan 图像拷贝）
// + 一次全屏 EASU 绘制。窗口==缓冲（FSR 关）时零开销跳过。
//
// 兜底：shader 编译失败（exotic Mesa）→ 一次性回调 nativeSendScreenSize
// 恢复窗口=表面（MC 下一帧起全分辨率直渲，画面不再缩角），日志留痕。
// ============================================================================

// GL 2.0+ 枚举（GL/gl.h 只有 1.1；OSMesa 桌面 GL 4.6 全量支持）。
// Task 143 勘误（对 Task 84 错误"勘误"的再勘误）：GL_FRAGMENT_SHADER
// 规范值是 0x8B30（35632）——mesa glext.h:599 同款；Task83 的原值才是
// 对的。0x8B92（35730）是 GL_PALETTE4_R5_G6_B5_OES（GLES1 调色板纹理
// 格式），不是任何 shader 类型枚举。Task84 把装机日志里 stage=35632
// 的编译失败误诊为"错值在跑"（真实败因另有其他），反向"勘误"成
// 0x8B92 后 zink 链 FSR 的片元着色器从此 glCreateShader 恒返回 0 +
// GL_INVALID_ENUM，静默自愈回全分辨率——与 mgl_fsr（Task119 复制了
// 同一错值）一起构成"FSR 从未在启动器侧两条链上工作过"的完整病历。
// 75c5e14 会话当年的编译错误信息来自别处，勿再据日志反推枚举规范值。
#ifndef GL_VERTEX_SHADER
#define GL_VERTEX_SHADER    0x8B31
#endif
#ifndef GL_FRAGMENT_SHADER
#define GL_FRAGMENT_SHADER  0x8B30
#endif
#ifndef GL_COMPILE_STATUS
#define GL_COMPILE_STATUS   0x8B81
#endif
#ifndef GL_LINK_STATUS
#define GL_LINK_STATUS      0x8B82
#endif
#ifndef GL_CURRENT_PROGRAM
#define GL_CURRENT_PROGRAM  0x8B8D
#endif
#ifndef GL_TEXTURE_BINDING_2D
#define GL_TEXTURE_BINDING_2D 0x8069
#endif
#ifndef GL_ARRAY_BUFFER
#define GL_ARRAY_BUFFER     0x8892
#endif
// Task 143：0x8B8C 实为 GL_SHADING_LANGUAGE_VERSION；GL_ARRAY_BUFFER_
// BINDING 规范值 0x8894——ame83_rcas_engage 的 glGetIntegerv(
// GL_ARRAY_BUFFER_BINDING, &saveVbo) 实际引用了本定义，旧错值让 VBO
// 绑定保存恒查到 GLSL 版本语义的 pname（静默失效），与 mgl_fsr 同源同修。
#ifndef GL_ARRAY_BUFFER_BINDING
#define GL_ARRAY_BUFFER_BINDING 0x8894
#endif
#ifndef GL_VERTEX_ARRAY_BINDING
#define GL_VERTEX_ARRAY_BINDING 0x85B5
#endif
#ifndef GL_STATIC_DRAW
#define GL_STATIC_DRAW      0x88E4
#endif
#ifndef GL_TEXTURE_MAX_LEVEL
#define GL_TEXTURE_MAX_LEVEL 0x813D
#endif
// Task 85（画面分裂修复）：EASU pass 的封闭性保障——显式绑回默认帧缓冲。
// MC 26.x+Sodium 在 swap 时通常已绑 fb0（Task 75 取证），但任何模组/路径
// 留下 FBO 绑定时，拷贝源与绘制目标都必须强制指向即将上屏的默认帧缓冲，
// 否则升采样写进离屏 FBO，上屏画面维持分裂。
#ifndef GL_FRAMEBUFFER
#define GL_FRAMEBUFFER            0x8D40
#endif
#ifndef GL_DRAW_FRAMEBUFFER
#define GL_DRAW_FRAMEBUFFER       0x8CA6
#endif
#ifndef GL_READ_FRAMEBUFFER
#define GL_READ_FRAMEBUFFER       0x8CA9
#endif
#ifndef GL_DRAW_FRAMEBUFFER_BINDING
#define GL_DRAW_FRAMEBUFFER_BINDING 0x8CA6
#endif
#ifndef GL_READ_FRAMEBUFFER_BINDING
#define GL_READ_FRAMEBUFFER_BINDING 0x8CAA
#endif
#ifndef GL_STENCIL_TEST
#define GL_STENCIL_TEST           0x0B90
#endif
// Task 99（修复 B）：EASU pass 加固所需枚举——显式锁定纹理单元 0 +
// 单次 glReadPixels GPU 侧探针 + glGetError 清扫。
#ifndef GL_ACTIVE_TEXTURE
#define GL_ACTIVE_TEXTURE        0x84B0
#endif
#ifndef GL_TEXTURE0
#define GL_TEXTURE0              0x84C0
#endif
#ifndef GL_UNSIGNED_BYTE
#define GL_UNSIGNED_BYTE          0x1401
#endif
// Task 100（权威呈现）：glReadPixels 全幅回读需锁 pack 像素存储状态
//（ROW_LENGTH 非零时行距会错位；SKIP_* 偏移同理；dstW*4 恒为 4 的倍数，
// 对齐无实际影响，但一并归零保证确定性）。
#ifndef GL_PACK_ROW_LENGTH
#define GL_PACK_ROW_LENGTH        0x0D02
#endif
#ifndef GL_PACK_SKIP_ROWS
#define GL_PACK_SKIP_ROWS         0x0D03
#endif
#ifndef GL_PACK_SKIP_PIXELS
#define GL_PACK_SKIP_PIXELS       0x0D04
#endif
#ifndef GL_PACK_ALIGNMENT
#define GL_PACK_ALIGNMENT          0x0D05
#endif

typedef unsigned int ame83_gluint;
typedef int ame83_glint;
typedef char ame83_glchar;
typedef void (*ame83_glshaderfn)(unsigned int, GLsizei, const char* const*, const GLint*);
typedef void (*ame83_glgetshaderiv)(unsigned int, unsigned int, int*);
typedef void (*ame83_gllogfn)(unsigned int, GLsizei, GLsizei*, char*);

typedef struct {
    // shader/program
    ame83_gluint (*glCreateShader)(unsigned int);
    ame83_glshaderfn glShaderSource;
    void (*glCompileShader)(unsigned int);
    ame83_glgetshaderiv glGetShaderiv;
    ame83_gllogfn glGetShaderInfoLog;
    ame83_gluint (*glCreateProgram)(void);
    void (*glAttachShader)(unsigned int, unsigned int);
    void (*glLinkProgram)(unsigned int);
    ame83_glgetshaderiv glGetProgramiv;
    ame83_gllogfn glGetProgramInfoLog;
    void (*glDeleteShader)(unsigned int);
    ame83_glint (*glGetUniformLocation)(unsigned int, const char*);
    void (*glUseProgram)(unsigned int);
    void (*glUniform2f)(unsigned int, float, float);
    void (*glUniform1f)(int, float); // Task 103：哨兵 uniform（markerCode/255.0f）
    void (*glUniform1i)(int, int);
    // texture
    void (*glGenTextures)(GLsizei, unsigned int*);
    void (*glDeleteTextures)(GLsizei, const unsigned int*);
    void (*glBindTexture)(unsigned int, unsigned int);
    void (*glTexParameteri)(unsigned int, unsigned int, int);
    void (*glTexImage2D)(unsigned int, int, int, int, int, int, unsigned int, unsigned int, const void*);  // Task 130：easuTex 分配（RCAS ping-pong）
    void (*glCopyTexImage2D)(unsigned int, int, unsigned int, int, int, GLsizei, GLsizei, int);
    void (*glCopyTexSubImage2D)(unsigned int, int, int, int, int, int, GLsizei, GLsizei);
    void (*glActiveTexture)(unsigned int);
    // vertex
    void (*glGenVertexArrays)(GLsizei, unsigned int*);
    void (*glBindVertexArray)(unsigned int);
    void (*glGenBuffers)(GLsizei, unsigned int*);
    void (*glBindBuffer)(unsigned int, unsigned int);
    void (*glBufferData)(unsigned int, long, const void*, unsigned int);
    void (*glVertexAttribPointer)(unsigned int, int, unsigned int, unsigned char, GLsizei, const void*);
    void (*glEnableVertexAttribArray)(unsigned int);
    // draw/state
    void (*glBindFramebuffer)(unsigned int, unsigned int);
    // Task 130：RCAS ping-pong（EASU -> 中间纹理 -> RCAS -> fb0）需要 FBO 对象
    void (*glGenFramebuffers)(GLsizei, unsigned int*);
    void (*glDeleteFramebuffers)(GLsizei, const unsigned int*);
    void (*glFramebufferTexture2D)(unsigned int, unsigned int, unsigned int, unsigned int, int);
    int  (*glCheckFramebufferStatus)(unsigned int);
    void (*glDrawArrays)(unsigned int, int, GLsizei);
    void (*glViewport)(int, int, GLsizei, GLsizei);
    void (*glDisable)(unsigned int);
    void (*glGetIntegerv)(unsigned int, int*);
    void (*glReadPixels)(int, int, int, int, unsigned int, unsigned int, void*);
    void (*glPixelStorei)(unsigned int, int);
    unsigned int (*glGetError)(void);
} ame83_gl_t;

static struct {
    ame83_gl_t gl;
    bool resolved;      // 函数表已解析（无论成败不再重试）
    bool initFailed;    // shader/program 初始化失败（不再每帧重试编译）
    bool ready;         // program+VAO+texture 就绪
    unsigned int program, vao, vbo, tex;
    int uViewportSize, uTargetSize, uInputTex;
    int uMarker;                    // Task 103：地面真值哨兵 uniform（-1 = 未注入/被优化）
    unsigned markerCode;            // 本帧哨兵字节（1..254；0 = 未启用）
    bool markerArmed;               // 哨兵已成功注入着色器源
    int texW, texH;     // 当前纹理存储尺寸（变更时重建）
    bool engaged;       // 至少跑过一次升采样（一次性日志用）
    bool healed;        // 兜底窗口恢复已触发
    long frames;        // 升采样帧计数（低频日志用）
    // ---- Task 130：RCAS 锐化 pass 2（mpv FSR.glsl 参照）----
    // 管线变更：EASU 不再直画 fb0，改画 easuTex（离屏 FBO）；RCAS 读
    // easuTex 画回 fb0。RCAS 编译/链接失败 → rcasFailed=true，EASU 恢复
    // 直画 fb0（仅 EASU 回退，日志留痕）——原有自愈链不动。
    unsigned int rcasProgram;      // RCAS program（0 = 未建/失败）
    unsigned int easuTex, easuFBO; // EASU 输出中间目标（尺寸=easuW×easuH）
    int easuW, easuH;              // easuTex 存储尺寸（变更时重建）
    int uRcasInputTex, uRcasSharpness;  // RCAS uniforms
    bool rcasFailed;               // RCAS 不可用 → 仅 EASU
    float rcasSharpness;           // 锐化强度（mpv 口径 [0,1]，默认 0.2）
    bool rcasEngaged;              // RCAS 首帧一次性日志
    long rcasFrames;               // RCAS 帧计数（低频日志）
} ame83_fsr = {0};

// Task 130：RCAS 锐化强度（mpv 口径 [0,1] 越大越锐，默认 0.2；负值 = 关闭
// RCAS，仅 EASU）。环境变量 AMETHYST_FSR_RCAS_SHARPNESS 由 JavaLauncher
// 启动前从偏好 mobileglues.fsr_rcas_sharpness 写入（与 MobileGlues 渲染器
// 读 config.json 的 fsr1RcasSharpness 同源——两类渲染器一个偏好键）。
static float ame130_rcas_sharpness(void) {
    const char *s = getenv("AMETHYST_FSR_RCAS_SHARPNESS");
    if (s == NULL || s[0] == 0) return 0.2f;
    float v = atof(s);
    if (v < 0.0f) return v;                      // 负值 = off（原样传递）
    if (!(v >= 0.0f && v <= 1.0f)) return 0.2f;  // NaN/越界回默认
    return v;
}

// Task 99（修复 B）：zink FSR 上屏诊断与兜底状态。
//   swaps       —— osm_swap_buffers 总次数（心跳取证：EASU 条件变量可见）
//   probeHits   —— CPU 侧顶带探针命中（EASU 输出确实落到回读缓冲）帧数
//   probeFrames —— 探针帧数（达到 kAme99ProbeFrames 判决）
//   verdict     —— 0=未判决 1=EASU 落地 -1=未落地→CG 拉伸兜底
//   gpuProbed   —— GPU 侧单次探针（glReadPixels 顶带像素）是否已做
static struct {
    long swaps;
    int probeHits, probeFrames;
    int verdict;        // 0 未判决 / 1 落地 / -1 兜底
    bool gpuProbed;
    // Task 103：哨兵票（地面真值）。mkState：0 未决 / 1 落地 / -1 兜底；
    // mkConsecM/mkConsecMiss 为连中/连失计数——哨兵是确定性机制，3 连即
    // 定性，无需 90 帧统计（旧非零探针保留为回退与取证双重用途）。
    // Task 103：哨兵票需要持续运行（判决可翻转：标题界面哨兵匹配、进世
    // 界后 EASU 断掉的场景需要能切到 CG 拉伸；反向同理）。
    int mkHits, mkState, mkConsecM, mkConsecMiss;
    int mkFarHits;      // Task 104：远角哨兵命中数（全幅覆盖证据；票为双哨兵 AND）
    bool final90Logged;   // 旧 90 帧统计日志一次性门（markerArmed 时仅取证不断 overwrite 判决）
} ame99_fsrdiag = {0, 0, 0, 0, false, 0, 0, 0, 0, 0, false};
#define kAme99ProbeFrames 90

static bool ame83_resolve_gl(void) {
    if (ame83_fsr.resolved) return ame83_fsr.gl.glCreateShader != NULL;
    ame83_fsr.resolved = true;
    if (s_osmDL == NULL) return false;
    static const struct { const char *name; void **slot; } kSyms[] = {
        {"glCreateShader",            (void**)&ame83_fsr.gl.glCreateShader},
        {"glShaderSource",            (void**)&ame83_fsr.gl.glShaderSource},
        {"glCompileShader",           (void**)&ame83_fsr.gl.glCompileShader},
        {"glGetShaderiv",             (void**)&ame83_fsr.gl.glGetShaderiv},
        {"glGetShaderInfoLog",        (void**)&ame83_fsr.gl.glGetShaderInfoLog},
        {"glCreateProgram",           (void**)&ame83_fsr.gl.glCreateProgram},
        {"glAttachShader",            (void**)&ame83_fsr.gl.glAttachShader},
        {"glLinkProgram",             (void**)&ame83_fsr.gl.glLinkProgram},
        {"glGetProgramiv",            (void**)&ame83_fsr.gl.glGetProgramiv},
        {"glGetProgramInfoLog",       (void**)&ame83_fsr.gl.glGetProgramInfoLog},
        {"glDeleteShader",            (void**)&ame83_fsr.gl.glDeleteShader},
        {"glGetUniformLocation",      (void**)&ame83_fsr.gl.glGetUniformLocation},
        {"glUseProgram",              (void**)&ame83_fsr.gl.glUseProgram},
        {"glUniform2f",               (void**)&ame83_fsr.gl.glUniform2f},
        {"glUniform1f",               (void**)&ame83_fsr.gl.glUniform1f},
        {"glUniform1i",               (void**)&ame83_fsr.gl.glUniform1i},
        {"glGenTextures",             (void**)&ame83_fsr.gl.glGenTextures},
        {"glDeleteTextures",          (void**)&ame83_fsr.gl.glDeleteTextures},
        {"glBindTexture",             (void**)&ame83_fsr.gl.glBindTexture},
        {"glTexParameteri",           (void**)&ame83_fsr.gl.glTexParameteri},
        {"glTexImage2D",              (void**)&ame83_fsr.gl.glTexImage2D},
        {"glCopyTexImage2D",          (void**)&ame83_fsr.gl.glCopyTexImage2D},
        {"glCopyTexSubImage2D",       (void**)&ame83_fsr.gl.glCopyTexSubImage2D},
        {"glActiveTexture",           (void**)&ame83_fsr.gl.glActiveTexture},
        {"glGenVertexArrays",         (void**)&ame83_fsr.gl.glGenVertexArrays},
        {"glBindVertexArray",         (void**)&ame83_fsr.gl.glBindVertexArray},
        {"glGenBuffers",              (void**)&ame83_fsr.gl.glGenBuffers},
        {"glBindBuffer",              (void**)&ame83_fsr.gl.glBindBuffer},
        {"glBufferData",              (void**)&ame83_fsr.gl.glBufferData},
        {"glVertexAttribPointer",     (void**)&ame83_fsr.gl.glVertexAttribPointer},
        {"glEnableVertexAttribArray", (void**)&ame83_fsr.gl.glEnableVertexAttribArray},
        {"glBindFramebuffer",          (void**)&ame83_fsr.gl.glBindFramebuffer},
        // Task 130：RCAS ping-pong 所需 FBO 入口
        {"glGenFramebuffers",           (void**)&ame83_fsr.gl.glGenFramebuffers},
        {"glDeleteFramebuffers",         (void**)&ame83_fsr.gl.glDeleteFramebuffers},
        {"glFramebufferTexture2D",       (void**)&ame83_fsr.gl.glFramebufferTexture2D},
        {"glCheckFramebufferStatus",     (void**)&ame83_fsr.gl.glCheckFramebufferStatus},
        {"glDrawArrays",              (void**)&ame83_fsr.gl.glDrawArrays},
        {"glViewport",                (void**)&ame83_fsr.gl.glViewport},
        {"glDisable",                 (void**)&ame83_fsr.gl.glDisable},
        {"glGetIntegerv",             (void**)&ame83_fsr.gl.glGetIntegerv},
        {"glReadPixels",              (void**)&ame83_fsr.gl.glReadPixels},
        {"glPixelStorei",              (void**)&ame83_fsr.gl.glPixelStorei},
        {"glGetError",                (void**)&ame83_fsr.gl.glGetError},
    };
    int missing = 0;
    for (size_t i = 0; i < sizeof(kSyms)/sizeof(kSyms[0]); ++i) {
        *kSyms[i].slot = dlsym(s_osmDL, kSyms[i].name);
        if (*kSyms[i].slot == NULL) {
            ++missing;
            NSLog(@"[OSMBridge] Task83 FSR: missing GL symbol %s", kSyms[i].name);
        }
    }
    return missing == 0;
}

static unsigned int ame83_compile(ame83_gl_t *g, unsigned int stage, const char *src) {
    unsigned int sh = g->glCreateShader(stage);
    g->glShaderSource(sh, 1, &src, NULL);
    g->glCompileShader(sh);
    int ok = 0;
    g->glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        g->glGetShaderInfoLog(sh, sizeof(log), NULL, log);
        NSLog(@"[OSMBridge] Task83 FSR shader compile FAILED (stage=%u): %s", stage, log);
        g->glDeleteShader(sh);
        return 0;
    }
    return sh;
}

// Task 83b（zink 绿屏根治）：FSR 着色器版本自适应。
//
// 背景（be276a0 装机日志实锤）：zink 经 MoltenVK 只给出 GLSL 4.10 上限
// （MoltenVK = Vulkan 1.1 → zink 桌面 GL 4.1），而 FSRShaderSource.h 声明
// #version 450 → 两个 stage 全部编译失败（错误信息为 GLSL 4.50 is not
// supported，注意此处不引用原文以免 ASCII 引号破坏历史括号校验器）
// → 兜底路径触发。而旧兜底只在 GLFW 通道下才能把窗口恢复成表面尺寸
// （26.3 下恒 NULL）→ MC 永远按小窗渲染，全尺寸 OSMesa 缓冲的未写区域
// = 未初始化堆内存上屏 = 用户看到的"FSR 提升部分绿色"。
//
// 着色器主体只需 GLSL 4.00（uintBitsToFloat 是 3.30 内建，
// packUnorm2x16/packUnorm4x8 是 4.00 内建），唯独 packHalf2x16/
// unpackHalf2x16 是 4.20 核心（Task83b 注释称 4.00 内建有误——75c5e14
// 装机日志实锤：适配到 4.10 后编译倒在 no function with name
// packHalf2x16）。Task 84 已把位运算手写回退（RNE/次正规/Inf/NaN，
// 位级对照 numpy float16 验证）烘焙进 FSRShaderSource.h 的
// __VERSION__ < 420 守卫，4.20+ 上下文零变化。因此当上下文版本落在
// 400 以上、450 以下时，用上下文自己的版本号替换首行 #version 即可。
// >= 450 原样；< 400 无法适配（体依赖 3.30+ 位操作内建），保持原样让它
// 以明确的版本错误日志失败。
//
// 探测：glGetString(GL_SHADING_LANGUAGE_VERSION)（dlsym_OSMesa 已解析，
// 本函数在 osm_swap_buffers 调用链上，OSMesaMakeCurrent 已生效）。
// Mesa 桌面版本串形如 "4.10"（十进制两位小数），解析成 410。
static int ame83_probe_glsl_version(void) {
    static int s_probed = -1;
    if (s_probed != -1) return s_probed;
    s_probed = 0;
    if (handle.glGetString) {
        // 真实签名 GLubyte* glGetString(GLenum)（osm_bridge.h）——C++ 下
        // 不能隐式转 const char*，显式转型后 sscanf。
        const GLubyte *gv = handle.glGetString(0x8B8C /* GL_SHADING_LANGUAGE_VERSION */);
        if (gv && gv[0] >= '0' && gv[0] <= '9') {
            int maj = 0, min = 0;
            if (sscanf((const char *)gv, "%d.%d", &maj, &min) == 2) {
                int ver = maj * 100 + (min < 10 ? min * 10 : min);
                if (ver >= 100 && ver <= 999) s_probed = ver;
            }
        }
    }
    return s_probed;
}

// 返回适配后的着色器源（首行 #version 替换为上下文版本；不适用则原样）。
static std::string ame83_adapt_shader_version(const char *src, const char *stageName) {
    std::string out(src);
    int ver = ame83_probe_glsl_version();
    if (ver >= 450 || ver < 400) return out;   // 原样（≥4.5 无需改；<4.0 改了也编不过，保留明确报错）
    const char *nl = strchr(src, '\n');
    if (!nl || strncmp(src, "#version", 8) != 0) return out;
    static bool s_logged = false;
    if (!s_logged) {
        s_logged = true;
        NSLog(@"[OSMBridge] Task83b FSR shader #version adapted: 450 -> %d (context GLSL cap %d, zink/MoltenVK path) -- first %s stage", ver, ver, stageName);
    }
    out = "#version ";
    out += std::to_string(ver);
    out += '\n';
    out += (nl + 1);
    return out;
}

static bool ame83_fsr_init(void) {
    if (ame83_fsr.ready) return true;
    if (ame83_fsr.initFailed) return false;
    if (!ame83_resolve_gl()) { ame83_fsr.initFailed = true; return false; }
    ame83_gl_t *g = &ame83_fsr.gl;

    // Task 83b：版本自适应后再缩（zink/GLSL 4.10 上限下也能编过）。
    std::string vsSrc = ame83_adapt_shader_version(FSR_VSSource, "vertex");
    std::string fsSrc = ame83_adapt_shader_version(FSR_FSSource, "fragment");
    // Task 103：地面真值哨兵注入（字符串手术，只改本桥编译的源；
    // MobileGlues 共享头零改动，MG 自身 FSR 路径不受影响）。着色器在输出
    // 像素 (0,0)（GL 左下角；present 翻转后 = 屏幕左下角）的 alpha 通道
    // 写入每帧变化的哨兵 k/255：
    //   · CGImage 用 kCGImageAlphaNoneSkipLast，alpha 不参与显示——零视觉影响
    //   · 呈现路径 glReadPixels 后核对该字节：匹配 = EASU 绘制落地且回读
    //     诚实；不匹配 = pre-EASU/陈旧传输或绘制未落地 → CG 拉伸兜底。
    //     Task 99/100 的非零探针分不清残影与新鲜 EASU——446b2a0 装机日志
    //     实证其误报 verdict=1（fb/driver 双探针 89/90 非零，屏幕仍蜷角）。
    //   · 哨兵字节取 1..254（255 是常规不透明帧 alpha，0 是 uniform 默认值）
    //   · 注入失败（上游源结构变化）→ markerArmed=false，回退旧逻辑
    ame83_fsr.markerArmed = false;
    do {
        static const char kDeclAnchor[] = "out vec4 oFragColor;";
        static const char kWriteAnchor[] = "oFragColor = vec4(color, 1.0);";
        size_t declAt = fsSrc.find(kDeclAnchor);
        size_t writeAt = fsSrc.find(kWriteAnchor);
        if (declAt == std::string::npos || writeAt == std::string::npos) break;
        fsSrc.insert(declAt + (sizeof(kDeclAnchor) - 1),
                     "\nuniform float uMarker; // Task 103: per-frame sentinel (k/255)");
        writeAt = fsSrc.find(kWriteAnchor); // insert 可能重分配，重新定位
        if (writeAt == std::string::npos) break;
        fsSrc.insert(writeAt + (sizeof(kWriteAnchor) - 1),
                     "\n    if (ip.x == 0u && ip.y == 0u) oFragColor.a = uMarker; // Task 103: bottom-left pixel alpha carries the sentinel"
                     "\n    if (float(ip.x) >= uTargetSize.x - 4.0 && float(ip.y) >= uTargetSize.y - 4.0) oFragColor.a = uMarker; // Task 104: far-corner sentinel -- full-surface rasterization proof (corner-only coverage fails here)");
        ame83_fsr.markerArmed = true;
    } while (false);
    unsigned int vs = ame83_compile(g, GL_VERTEX_SHADER, vsSrc.c_str());
    if (vs == 0) { ame83_fsr.initFailed = true; return false; }
    unsigned int fs = ame83_compile(g, GL_FRAGMENT_SHADER, fsSrc.c_str());
    if (fs == 0) { g->glDeleteShader(vs); ame83_fsr.initFailed = true; return false; }

    unsigned int prog = g->glCreateProgram();
    g->glAttachShader(prog, vs);
    g->glAttachShader(prog, fs);
    g->glLinkProgram(prog);
    int ok = 0;
    g->glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    g->glDeleteShader(vs);
    g->glDeleteShader(fs);
    if (!ok) {
        char log[1024];
        g->glGetProgramInfoLog(prog, sizeof(log), NULL, log);
        NSLog(@"[OSMBridge] Task83 FSR program link FAILED: %s", log);
        ame83_fsr.initFailed = true;
        return false;
    }

    // 全屏四边形（与 MG InitFullscreenQuad 同款布局：pos(2f)+uv(2f)×6 顶点）
    static const float quad[] = {
        -1.0f,  1.0f, 0.0f, 1.0f,
        -1.0f, -1.0f, 0.0f, 0.0f,
         1.0f, -1.0f, 1.0f, 0.0f,
        -1.0f,  1.0f, 0.0f, 1.0f,
         1.0f, -1.0f, 1.0f, 0.0f,
         1.0f,  1.0f, 1.0f, 1.0f,
    };
    g->glGenVertexArrays(1, &ame83_fsr.vao);
    g->glBindVertexArray(ame83_fsr.vao);
    g->glGenBuffers(1, &ame83_fsr.vbo);
    g->glBindBuffer(GL_ARRAY_BUFFER, ame83_fsr.vbo);
    g->glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    g->glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)0);
    g->glEnableVertexAttribArray(0);
    g->glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 4 * sizeof(float), (void*)(2 * sizeof(float)));
    g->glEnableVertexAttribArray(1);
    g->glBindBuffer(GL_ARRAY_BUFFER, 0);
    g->glBindVertexArray(0);

    g->glGenTextures(1, &ame83_fsr.tex);
    ame83_fsr.program = prog;
    ame83_fsr.uViewportSize = g->glGetUniformLocation(prog, "uViewportSize");
    ame83_fsr.uTargetSize = g->glGetUniformLocation(prog, "uTargetSize");
    // Task 99：采样器 uniform 显式钉到单元 0（防御 MC/模组留下非 0 活动单元）
    ame83_fsr.uInputTex = g->glGetUniformLocation(prog, "uInputTex");
    // Task 103：哨兵 uniform（注入失败/被优化掉 → 关闭哨兵，回退旧逻辑）
    ame83_fsr.uMarker = ame83_fsr.markerArmed ? g->glGetUniformLocation(prog, "uMarker") : -1;
    if (ame83_fsr.markerArmed && ame83_fsr.uMarker < 0) ame83_fsr.markerArmed = false;
    ame83_fsr.markerCode = 0;
    ame83_fsr.ready = true;
    NSLog(@"[OSMBridge] Task83 FSR1 EASU ready (zink): program=%u uViewportSize=%d uTargetSize=%d marker=%d -- same EASU shader as MobileGlues",
          ame83_fsr.program, ame83_fsr.uViewportSize, ame83_fsr.uTargetSize,
          ame83_fsr.markerArmed ? 1 : 0);

    // ---- Task 130：RCAS 锐化 pass（独立 program，失败不拖 EASU 下水）----
    // EASU ready 后才尝试；任何一步失败 → rcasFailed=true，本会话仅 EASU
    // （EASU 直画 fb0 的旧路径），日志留痕（用户要求的不支持回退口径）。
    // VS 重新编译一份：EASU 的 vs 在 link 后已删除（GL 允许 link 后删 shader），
    // RCAS program 需要自己的附件；源同 FSR_VSSource（布局 aPosition/vTexCoord）。
    ame83_fsr.rcasSharpness = ame130_rcas_sharpness();
    do {
        if (g->glGenFramebuffers == NULL || g->glFramebufferTexture2D == NULL) {
            NSLog(@"[OSMBridge] Task130 RCAS unavailable: FBO entry points missing -- EASU-only (zink)");
            break;
        }
        std::string rcasVs = ame83_adapt_shader_version(FSR_VSSource, "rcas-vertex");
        std::string rcasFs = ame83_adapt_shader_version(FSR_RCAS_FSSource, "rcas-fragment");
        unsigned int rvs = ame83_compile(g, GL_VERTEX_SHADER, rcasVs.c_str());
        if (rvs == 0) {
            NSLog(@"[OSMBridge] Task130 RCAS vertex compile FAILED -- falling back to EASU-only (zink)");
            break;
        }
        unsigned int rfs = ame83_compile(g, GL_FRAGMENT_SHADER, rcasFs.c_str());
        if (rfs == 0) {
            g->glDeleteShader(rvs);
            NSLog(@"[OSMBridge] Task130 RCAS fragment compile FAILED -- falling back to EASU-only (zink)");
            break;
        }
        unsigned int rprog = g->glCreateProgram();
        g->glAttachShader(rprog, rvs);
        g->glAttachShader(rprog, rfs);
        g->glLinkProgram(rprog);
        int rok = 0;
        g->glGetProgramiv(rprog, GL_LINK_STATUS, &rok);
        g->glDeleteShader(rvs);
        g->glDeleteShader(rfs);
        if (!rok) {
            char log[1024];
            g->glGetProgramInfoLog(rprog, sizeof(log), NULL, log);
            NSLog(@"[OSMBridge] Task130 RCAS program link FAILED: %s -- EASU-only (zink)", log);
            break;
        }
        ame83_fsr.rcasProgram = rprog;
        ame83_fsr.uRcasInputTex = g->glGetUniformLocation(rprog, "uInputTex");
        ame83_fsr.uRcasSharpness = g->glGetUniformLocation(rprog, "uSharpness");
        NSLog(@"[OSMBridge] Task130 RCAS ready (zink): program=%u sharpness=%.3f (mpv-scale [0,1], default 0.2) -- EASU now draws offscreen, RCAS presents",
              ame83_fsr.rcasProgram, (double)ame83_fsr.rcasSharpness);
    } while (false);
    if (ame83_fsr.rcasProgram == 0) ame83_fsr.rcasFailed = true;
    return true;
}

// 把默认帧缓冲 (0,0)-(srcW,srcH) 区域 EASU 升采样铺满 (dstW,dstH)。
// 返回 false = 不可用（调用方走兜底）。
static bool ame83_fsr_upscale(int srcW, int srcH, int dstW, int dstH) {
    if (srcW <= 0 || srcH <= 0 || dstW <= srcW || dstH <= srcH) return false;
    if (!ame83_fsr_init()) return false;
    ame83_gl_t *g = &ame83_fsr.gl;

    // 最小状态保存（MC 每帧重设自己的管线状态；这里只还回关键绑定）。
    // Task 85：新增 draw/read FBO 绑定保存（EASU 强制绑 fb0，见下）。
    // Task 99（修复 B）：新增活动纹理单元保存——旧代码把 FSR 纹理绑到
    // “当时活动”的单元（MC/模组可留在任意单元），而着色器采样器默认读
    // 单元 0：若活动单元非 0，纹理进错单元，采样密不可料。现在显式
    // 切到单元 0 绑定/采样，还回时恢复原单元与单元 0 的旧绑定。
    GLint saveVp[4] = {0}, saveProg = 0, saveVao = 0, saveVbo = 0;
    GLint saveDrawFbo = 0, saveReadFbo = 0, saveActiveTex = 0, saveTexUnit0 = 0;
    g->glGetIntegerv(GL_VIEWPORT, saveVp);
    g->glGetIntegerv(GL_CURRENT_PROGRAM, &saveProg);
    g->glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &saveVao);
    g->glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &saveVbo);
    g->glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &saveDrawFbo);
    g->glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &saveReadFbo);
    g->glGetIntegerv(GL_ACTIVE_TEXTURE, &saveActiveTex);
    g->glActiveTexture(GL_TEXTURE0);
    g->glGetIntegerv(GL_TEXTURE_BINDING_2D, &saveTexUnit0);

    g->glDisable(GL_DEPTH_TEST);
    g->glDisable(GL_SCISSOR_TEST);
    g->glDisable(GL_STENCIL_TEST);
    g->glDisable(GL_BLEND);
    g->glDisable(GL_CULL_FACE);

    // Task 85：拷贝源与绘制目标都锁定默认帧缓冲（读窗口区域、写全幅）。
    g->glBindFramebuffer(GL_FRAMEBUFFER, 0);

    // (1) 帧的区域 → 纹理（GPU 侧拷贝；存储尺寸变化时重建）
    g->glBindTexture(GL_TEXTURE_2D, ame83_fsr.tex);
    if (ame83_fsr.texW != srcW || ame83_fsr.texH != srcH) {
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, 0x812F /*GL_CLAMP_TO_EDGE*/);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, 0x812F);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        g->glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 0, 0, srcW, srcH, 0);
        ame83_fsr.texW = srcW;
        ame83_fsr.texH = srcH;
    } else {
        g->glCopyTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, 0, 0, srcW, srcH);
    }

    // ---- Task 130：RCAS ping-pong 目标惰性建/重建（尺寸=dstW×dstH）----
    // RCAS 不可用（编译失败/FBO 缺失/sharpness<0 关闭）时 ame130_rcasOn=false，
    // 给下方的 EASU 保持旧直画 fb0 路径（仅 EASU 回退，零行为变化）。
    float ame130_sharp = ame130_rcas_sharpness();
    bool ame130_rcasOn = ame130_sharp >= 0.0f &&
                         !ame83_fsr.rcasFailed && ame83_fsr.rcasProgram != 0;
    if (ame130_rcasOn && (ame83_fsr.easuW != dstW || ame83_fsr.easuH != dstH)) {
        if (ame83_fsr.easuTex != 0) g->glDeleteTextures(1, &ame83_fsr.easuTex);
        if (ame83_fsr.easuFBO != 0) g->glDeleteFramebuffers(1, &ame83_fsr.easuFBO);
        ame83_fsr.easuTex = ame83_fsr.easuFBO = 0;
        ame83_fsr.easuW = ame83_fsr.easuH = 0;
        unsigned int tex = 0, fbo = 0;
        g->glGenTextures(1, &tex);
        g->glBindTexture(GL_TEXTURE_2D, tex);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, 0x812F);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, 0x812F);
        g->glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
        g->glTexImage2D(GL_TEXTURE_2D, 0, 0x8058 /*GL_RGBA8*/, dstW, dstH, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        g->glGenFramebuffers(1, &fbo);
        g->glBindFramebuffer(GL_FRAMEBUFFER, fbo);
        g->glFramebufferTexture2D(GL_FRAMEBUFFER, 0x8CE0 /*GL_COLOR_ATTACHMENT0*/, GL_TEXTURE_2D, tex, 0);
        if (g->glCheckFramebufferStatus != NULL &&
            g->glCheckFramebufferStatus(GL_FRAMEBUFFER) != 0x8CD5 /*GL_FRAMEBUFFER_COMPLETE*/) {
            NSLog(@"[OSMBridge] Task130 RCAS offscreen target incomplete (%dx%d) -- falling back to EASU-only (zink)", dstW, dstH);
            g->glDeleteTextures(1, &tex);
            g->glDeleteFramebuffers(1, &fbo);
            g->glBindFramebuffer(GL_FRAMEBUFFER, 0);
            ame83_fsr.rcasFailed = true;
            ame130_rcasOn = false;
        } else {
            ame83_fsr.easuTex = tex;
            ame83_fsr.easuFBO = fbo;
            ame83_fsr.easuW = dstW;
            ame83_fsr.easuH = dstH;
            g->glBindFramebuffer(GL_FRAMEBUFFER, 0);
        }
    }

    // (2) EASU 全屏绘制：RCAS 就绪时 → 离屏 easuTex；否则直画 fb0（旧路径）。
    //     注：哨兵像素 alpha 写进 EASU 输出（easuTex 或 fb0），RCAS 的
    //     alpha 透传保证哨兵最终落在 fb0 —— Task103/104 验证链不断。
    if (ame130_rcasOn) {
        g->glBindFramebuffer(GL_FRAMEBUFFER, ame83_fsr.easuFBO);
    }
    // EASU 绘制（目标见上：RCAS 就绪 = easuTex，否则 = fb0 全幅）
    g->glUseProgram(ame83_fsr.program);
    // Task 99：uInputTex 显式钉单元 0（若着色器把该 uniform 优化掉，
    // glGetUniformLocation 返回 -1，glUniform1i(-1,..) 是合法空操作——零回归）
    if (ame83_fsr.uInputTex >= 0) g->glUniform1i(ame83_fsr.uInputTex, 0);
    g->glUniform2f(ame83_fsr.uViewportSize, (float)srcW, (float)srcH);
    g->glUniform2f(ame83_fsr.uTargetSize, (float)dstW, (float)dstH);
    // Task 103：本帧哨兵（在绘制前设置；present 路径回读后核对）。
    if (ame83_fsr.markerArmed) {
        unsigned code = 1u + (unsigned)(ame83_fsr.frames % 254u);
        g->glUniform1f(ame83_fsr.uMarker, (float)code / 255.0f);
        ame83_fsr.markerCode = code;
    }
    g->glBindVertexArray(ame83_fsr.vao);
    g->glViewport(0, 0, dstW, dstH);
    // Task 104（蜷缩闭环取证）：视口验证——341c110 装机日志实锤 BMC2
    //（1.20.1/GLFW）会话哨兵在 (0,0) 连中（mk=2519/2519）但 fb0 顶带首帧
    // 全黑、屏幕蜷角：EASU 光栅化只覆盖了游戏尺寸区域。此处读回驱动
    // 实际持有的视口，与请求值分叉即一眼定位（clamp/忽略/别的写入者）。
    {
        static bool s_ame104_vpLogged = false;
        if (!s_ame104_vpLogged) {
            s_ame104_vpLogged = true;
            GLint vpNow[4] = {0, 0, 0, 0};
            g->glGetIntegerv(GL_VIEWPORT, vpNow);
            NSLog(@"[OSMBridge] Task104 EASU viewport check: requested 0,0 %dx%d -> driver holds %d,%d %dx%d%s",
                  dstW, dstH, vpNow[0], vpNow[1], vpNow[2], vpNow[3],
                  (vpNow[2] == dstW && vpNow[3] == dstH)
                      ? " (intact)"
                      : " (CLAMPED/MISMATCH -- rasterization coverage suspect; far-corner sentinel gates the verdict)");
        }
    }
    g->glDrawArrays(GL_TRIANGLES, 0, 6);

    // (1z) Task 130：RCAS 锐化 pass —— easuTex → fb0（1:1，5-tap 十字）。
    //     开销口径：全屏 fragment 5 次 texelFetch + 纯 ALU，无中间回读、
    //     无额外同步——实测目标 <0.5ms（M 系 GPU 全屏 2360x1640 量级）。
    //     uSharpness 每帧下发（运行期环境变量变更不重启也生效，调试友好）。
    if (ame130_rcasOn) {
        g->glBindFramebuffer(GL_FRAMEBUFFER, 0);
        g->glActiveTexture(GL_TEXTURE0);
        g->glBindTexture(GL_TEXTURE_2D, ame83_fsr.easuTex);
        g->glUseProgram(ame83_fsr.rcasProgram);
        if (ame83_fsr.uRcasInputTex >= 0) g->glUniform1i(ame83_fsr.uRcasInputTex, 0);
        if (ame83_fsr.uRcasSharpness >= 0) {
            g->glUniform1f(ame83_fsr.uRcasSharpness, ame130_sharp);
        }
        g->glViewport(0, 0, dstW, dstH);
        g->glDrawArrays(GL_TRIANGLES, 0, 6);
        ame83_fsr.rcasFrames++;
        if (!ame83_fsr.rcasEngaged) {
            ame83_fsr.rcasEngaged = true;
            NSLog(@"[OSMBridge] Task130 RCAS engaged (zink): EASU %dx%d -> offscreen %dx%d -> RCAS -> fb0, sharpness=%.3f",
                  srcW, srcH, dstW, dstH, (double)ame130_sharp);
        } else if (ame83_fsr.rcasFrames == 600) {
            NSLog(@"[OSMBridge] Task130 RCAS steady: 600 frames sharpened (zink)");
        }
    }
    // (2b) Task 99（修复 B）：GPU 侧单次探针 + 错误清扫——读回默认帧缓冲
    // 顶带（GL y≈dstH，即 EASU 输出覆盖、游戏窗口区域之外的条带）的
    // 一个像素。若此处非零而回读缓冲顶带全零，则“绘制已落地 GPU、
    // 回读未携带”一眼分晓（区分绘制层故障 vs 回读层故障）。
    if (!ame99_fsrdiag.gpuProbed) {
        ame99_fsrdiag.gpuProbed = true;
        unsigned char px[4] = {0, 0, 0, 0};
        if (g->glReadPixels) {
            g->glReadPixels(dstW - 8, dstH - 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, px);
        }
        // Task 103：哨兵像素单次直读（glFinish 之前的地面真值：此刻若哨兵
        // 已可读回，说明绘制与直读均健康，后续若屏幕仍蜷角则断会在
        // glFinish 之后的传输层；若此刻哨兵缺失，则绘制未落地或直读
        // 已被劫持——与 90 帧哨兵票交叉定位断层层级）。
        unsigned char mk[4] = {0, 0, 0, 0};
        if (g->glReadPixels && ame83_fsr.markerArmed) {
            g->glReadPixels(0, 0, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, mk);
        }
        // Task 104：远角哨兵单次直读（GL 右上 = 全幅光栅化的必经之地；
        // BMC2 型“只覆盖游戏区域”的绘制在此处必缺）。
        unsigned char mkFar[4] = {0, 0, 0, 0};
        if (g->glReadPixels && ame83_fsr.markerArmed && dstW >= 8 && dstH >= 8) {
            g->glReadPixels(dstW - 2, dstH - 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, mkFar);
        }
        unsigned int glerr = g->glGetError ? g->glGetError() : 0;
        NSLog(@"[OSMBridge] Task99 GPU probe: fb0 top-strip pixel (x=%d,y=%d) rgba=%02x%02x%02x%02x glErr=0x%04x; Task103 sentinel pixel (0,0) alpha=%02x expect=%02x %s; Task104 far-corner (%d,%d) alpha=%02x %s",
              dstW - 8, dstH - 4, px[0], px[1], px[2], px[3], glerr,
              mk[3], (unsigned)(ame83_fsr.markerCode & 0xffu),
              (ame83_fsr.markerArmed && mk[3] == (unsigned char)ame83_fsr.markerCode)
                  ? "MATCH (draw + direct readback healthy pre-glFinish)"
                  : "MISMATCH (draw did not land, or direct readback already stale)",
              dstW - 2, dstH - 2, mkFar[3],
              (ame83_fsr.markerArmed && mkFar[3] == (unsigned char)ame83_fsr.markerCode)
                  ? "MATCH (full-surface coverage)"
                  : "MISS (coverage limited to game region -- CG stretch fallback will engage)");
    }

    // (3) 还原（FBO 双通道分别还回，模组的非对称 read/draw 绑定不受扰动；
    //     纹理：先还单元 0 的旧绑定，再还原活动单元）
    g->glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (unsigned int)saveDrawFbo);
    g->glBindFramebuffer(GL_READ_FRAMEBUFFER, (unsigned int)saveReadFbo);
    g->glBindVertexArray((unsigned int)saveVao);
    g->glBindBuffer(GL_ARRAY_BUFFER, (unsigned int)saveVbo);
    g->glUseProgram((unsigned int)saveProg);
    g->glBindTexture(GL_TEXTURE_2D, (unsigned int)saveTexUnit0);
    g->glActiveTexture((unsigned int)saveActiveTex);
    g->glViewport(saveVp[0], saveVp[1], saveVp[2], saveVp[3]);

    ame83_fsr.frames++;
    if (!ame83_fsr.engaged) {
        ame83_fsr.engaged = true;
        NSLog(@"[OSMBridge] Task83 FSR1 upscale engaged (zink): render %dx%d -> surface %dx%d (EASU pre-readback ordering, Task 85, RCAS=%d)",
              srcW, srcH, dstW, dstH, ame130_rcasOn ? 1 : 0);
    } else if (ame83_fsr.frames == 600) {
        NSLog(@"[OSMBridge] Task83 FSR1 upscale steady: 600 frames upsampled (zink)");
    }
    return true;
}

// ============================================================================
// Task 100（修复 B 续）：权威呈现路径（authoritative present path）。
//
// 病灶（7a30912 装机日志，BMC2 1.20.1 + zink + FSR preset2，ccabe82 构建）：
//   Task99 三件套全部给出"绿灯"证据，用户看到的却是活的低清游戏蜷在
//   左下角（60fps、还能在角落里打字）：
//     · GPU 探针：EASU 绘制后 fb0 顶带像素 000000ff（alpha 已写入，非全零）
//     · CPU 探针：bundle.buffer 顶带 88/90 帧非零 → verdict=1（判"已落地"）
//     · 心跳：easuFrames 每帧递增、win=1572x1092 osm=2360x1640 恒稳、
//       会话 1080 swaps 到退出为止全程稳定
//   唯一自洽的解释：屏幕显示的 bundle.buffer 里，左下角落 = 驱动 glFinish
//   回读写入的 EASU 之前（或来源错误）的裸游戏帧；顶带 = 滞后/陈旧内容
//   ——探针只验"非零"，分不清新鲜 EASU 与一帧残影，因此误报 verdict=1。
//   结论：自定义 libOSMesa 的 glFinish 回读在 GLFW/1.20.1 路径上不可信
//   （对照组 26.3-rc-3/SDL3 路径正常——断层在 MC 版本路径的 GL 终态，
//   驱动侧黑盒无法再深挖，也不必再挖）。
//
// 修复（理论免疫，不再依赖任何驱动侧假设）：FSR 帧由本桥自己完成呈现——
//   glFinish 之后显式绑定 fb0、glReadPixels 全幅权威回读到 scratch，
//   行序翻转（GL 底起 → OSMESA_Y_UP=0 顶起）拷入独立 present 缓冲，
//   CGImage 改包 present 缓冲。驱动回读写什么、何时写、写到哪，从此
//   无所谓——present 缓冲驱动永不触碰，不存在任何被覆盖的时序窗口。
//   bundle.buffer 保留纯取证用途：driver 探针继续采样它，下一轮装机日志
//   与 fb 探针（scratch = fb0 直读）对照，即可一眼定位断层层级。
//
// 探针双轨化（90 帧多数表决，verdict 仍由顶带着陆探针驱动）：
//   · fb 探针（scratch 顶带，GL 行序：行 gameH 到 bufH）——EASU 绘制层
//     健康。verdict=1 → present 全幅上屏；verdict=-1 → CG 拉伸兜底。
//   · driver 探针（bundle.buffer 顶带，top-down 行 1 到 bufH-gameH）
//     ——驱动传输层取证，仅记录，不影响控制流。
// ============================================================================
static struct {
    unsigned char *scratch;      // glReadPixels 目标（GL 行序：行 0 = GL y=0 = 底行）
    unsigned char *present;      // 翻转后的 top-down 呈现缓冲（CGImage 数据源）
    int bufW, bufH;              // 已分配尺寸（变更时重分配）
    bool engaged;                // 首帧一次性日志
    bool broken;                 // glReadPixels 出错/分配失败 → 本会话停用，回退驱动路径
    int drvHits, drvFrames;      // driver 探针（bundle.buffer 顶带）——纯取证
} ame100_present = {0};

// Task 104：呈现层滤镜状态（CG 拉伸兜底期 Linear，EASU 落地还原 Nearest）。
// 文件级单一事实源：swap 的两个分支（兜底/全幅）读写同一旗标。
static bool ame104_filters_linear = false;

// ============================================================================
// Task 106（26.3 30fps 第 1 轮）：bundle-direct 呈现 + 相位计时
// ============================================================================
// 41cdff0 装机日志判读（2e1ea09 构建）：preset=1（1814×1262）与 preset=4
// （1180×820，渲染像素 -58%）帧率同为 28-30——帧耗时的主导项是分辨率无关
// 的呈现常数。zink 路径每帧实际做了两次全幅 GPU→CPU 传输：驱动 glFinish
// 回读（15.5MB，OSMesa 契约，不可避免）+ Task100 权威 glReadPixels（15.5MB）
// + 15.5MB 行翻 memcpy。Task100 不信任驱动回读的历史原因（BMC2 蜷角年代
// 的 stale 传输）现在有了逐帧地面真值：Task103 双哨兵（markerCode 每帧
// 1..254 轮换，近角+远角 AND）——bundle.buffer 若同时持有本帧双哨兵，即
// 持有本帧全幅 EASU 输出，可直接上屏（OSMESA_Y_UP=0 本就是 top-down，
// 行翻也一并省去）。
//
// 协议（保守激活、快速退出）：
//   · warmup：连续 30 帧双哨兵命中（期间权威路径照跑，交叉验证）→ 激活；
//   · 激活后：跳过权威回读+行翻，CGImage 直接包 bundle.buffer（复用既有
//     legacy 全幅包装分支）；mk 票改由 bundle 哨兵供养（同一状态机）；
//   · 2 连失（EASU 停摆/驱动传输劣化）→ 立即退回权威路径重新 warmup；
//   · fsrActiveThisFrame 为 false 的帧不参与（healed/非 FSR 会话零影响）。
//
// 相位计时（心跳窗口累计）：pre+easu / glFinish / 权威回读 / swap 全段
// 四相 + 帧间隔（gap）。gap - swap = MC 侧帧耗时——下一次装机日志可把
// ~33ms 帧预算精确分解到 MC 渲染 / 驱动回读 / 我们的重复劳动。
static struct {
    bool active;          // bundle-direct 呈现中
    int  warm;            // warmup 连中计数
    int  misses;          // 激活态连失计数
    long frames, hits;    // 激活态帧数 / 哨兵命中数（心跳取证）
    bool engagedLogged, fallbackLogged;
    // 相位计时（μs，心跳窗口累计 + 峰值；心跳打印后清零）
    double tPreUs, tFinUs, tReadUs, tSwapUs;
    double tPreMax, tFinMax, tReadMax, tSwapMax;
    double lastEntryUs, gapSumUs, gapMaxUs;
    int    gapN, winN;
} ame106 = {0};

static double ame106_us(uint64_t mach) {
    static mach_timebase_info_data_t tb;
    if (tb.denom == 0) mach_timebase_info(&tb);
    return (double)mach * (double)tb.numer / (double)tb.denom / 1000.0;
}

// Task 106：bundle.buffer（OSMESA_Y_UP=0，top-down）双哨兵核对。
// GL(0,0)（底左）→ top-down 行 H-1 列 0；GL(W-2,H-2)（顶右）→ 行 1 列 W-2。
static bool ame106_bundle_sentinels(const unsigned char *buf, uint32_t w, uint32_t h,
                                    unsigned char code) {
    if (buf == NULL || w < 8 || h < 8) return false;
    size_t stride = (size_t)w * 4;
    size_t nearIdx = (size_t)(h - 1) * stride + 3;
    size_t farIdx = stride + (size_t)(w - 2) * 4 + 3;
    size_t total = (size_t)w * (size_t)h * 4;
    if (nearIdx >= total || farIdx >= total) return false;
    return buf[nearIdx] == code && buf[farIdx] == code;
}

// Task 109：no-finish 取证窗口（26.3 锁 30fps 第 3 轮，A/B 实验）。
//
// 背景（698c6fe 双会话实测，38fb316 构建）：
//   · 原版 26.3：MC-side 中位 3.3ms + 我们呈现 ~10ms（glFinish 相位 8.5-13.7）
//     → frame 中位 18.6ms（53fps）——用户判"完全正常"；
//   · 整合包 26.3（110 mods，进世界前 13 秒）：MC-side 21-36ms + 同款呈现
//     ~10ms → 21-30fps——用户判"锁 30"。Task110 定案：真凶是 dynamic_fps
//     3.11.10（整合包含、原版不含）看到"未聚焦窗口"的降频档（SDL 焦点
//     位从未置 1，见 sdl3_hook.m Task110）；vanilla 限帧器们全程 0 命中
//     （FramerateLimiter、maxFps=260、无 vsync、AFK 心跳在岗）；
//   · 两会话 glFinish 相位区间重叠（主体 8-15ms，重载的整合包会话反而
//     更低 = 非场景 GPU 负载）= 固定驱动同步/回读常数；而我们自己的权威
//     回读（glReadPixels 全幅 + 行翻，Task100 路径）实测每事件仅 ~4ms——
//     数据搬运本身不贵，贵的是驱动 glFinish 内部的同步机制（待解剖：
//     拷贝 vs swizzle vs 全队列等待）。
//
// 实验：在两个固定 FSR 帧窗口（FSR 帧 300-419 与 1020-1139，各 120 帧）内跳过驱动
// glFinish，强制权威路径呈现（glReadPixels 的内部同步接管）。若 zink 的
// glReadPixels 同步比 OSMesa 定制 glFinish 回读便宜，窗口内心跳的 t=swap
// 将显著低于邻窗——下一轮据此决定是否把"无驱动回读"固化为常驻模式；
// 若无收益则证明等待是 GPU 完成所固有，下一步只剩 CA 直呈（IOSurface
// 零拷贝）架构项。安全性：权威路径即每会话前 30 帧的既有行为（含熔断）；
// 窗口内哨兵票跳过（bundle 必然 stale，防误判 fallback 日志）；权威失败
// 时补一次迟到 glFinish，legacy 包装仍能上屏正确帧——屏幕永不坏。
// 非 FSR 帧 / 非 FSR 会话零影响（legacy 呈现依赖驱动回读，永不跳过）。
static struct {
    long frame;                    // FSR 帧计数（仅 fsrActiveThisFrame 帧递增）
    bool inWindow;
    double winSwapUs; long winN;   // 窗口内 swap 全段累计
    double baseSwapUs; long baseN; // 窗口外（基线）swap 全段累计
} ame109 = {0};

static bool ame109_window_active(long f) {
    return (f >= 300 && f < 420) || (f >= 1020 && f < 1140);
}

// 返回 true = 本帧跳过驱动 glFinish（窗口内且权威路径健康）。
static bool ame109_trial_gate(bool fsrActive) {
    if (!fsrActive) return false;
    long f = ++ame109.frame;
    bool inW = ame109_window_active(f);
    if (inW && !ame109.inWindow) {
        ame109.inWindow = true;
        ame106.active = false;   // 退出窗口后按既有 warmup 纪律自然重臂（30 连中）
        ame106.warm = 0;
        NSLog(@"[OSMBridge] Task109 no-finish trial: window opens at FSR frame %ld "
              "(120 frames skip driver glFinish, authoritative glReadPixels present; "
              "watch [glFinish ~0 | readback +sync] vs neighbors in heartbeats)", f);
    } else if (!inW && ame109.inWindow) {
        ame109.inWindow = false;
        double trialAvg = ame109.winN ? ame109.winSwapUs / ame109.winN / 1000.0 : 0.0;
        double baseAvg = ame109.baseN ? ame109.baseSwapUs / ame109.baseN / 1000.0 : 0.0;
        NSLog(@"[OSMBridge] Task109 no-finish trial: window closed -- trial avg swap %.1fms "
              "(%ld frames) vs baseline %.1fms (%ld frames); bundle-direct re-arms in 30 fresh frames",
              trialAvg, ame109.winN, baseAvg, ame109.baseN);
        ame109.winSwapUs = ame109.winN = 0;
        ame109.baseSwapUs = ame109.baseN = 0;
    }
    return ame109.inWindow && !ame100_present.broken;
}

// Task 103/106：哨兵票核心（计数 + 状态迁移 + 迁移取证日志）。
// 原实现内联在 scratch 探针分支；Task106 bundle-direct 分支复用同一状态机
// （票源不同：scratch = 权威回读，bundle = 驱动回读；状态语义完全一致）。
// 迁移时的 present-vs-bundle memcmp 取证：bundle-direct 票时 present 缓冲
// 有意滞后（按设计不再每帧回读），"differs" 属预期，尾注说明。
static void ame103_marker_vote(bool mkHit, osm_render_window_t bundle) {
    if (mkHit) {
        ++ame99_fsrdiag.mkHits;
        ++ame99_fsrdiag.mkFarHits;
        ++ame99_fsrdiag.mkConsecM;
        ame99_fsrdiag.mkConsecMiss = 0;
    } else {
        ++ame99_fsrdiag.mkConsecMiss;
        ame99_fsrdiag.mkConsecM = 0;
    }
    int newState = ame99_fsrdiag.mkState;
    if (newState == 0) {
        if (ame99_fsrdiag.mkConsecM >= 3) newState = 1;
        else if (ame99_fsrdiag.mkConsecMiss >= 3) newState = -1;
    } else if (newState == 1 && ame99_fsrdiag.mkConsecMiss >= 10) {
        newState = -1;
    } else if (newState == -1 && ame99_fsrdiag.mkConsecM >= 10) {
        newState = 1;
    }
    if (newState != ame99_fsrdiag.mkState) {
        ame99_fsrdiag.mkState = newState;
        ame99_fsrdiag.verdict = newState;
        // 状态迁移一次性取证：present 与 bundle 全幅 memcmp
        //（相等 = glReadPixels 与驱动回读同源；不等 = 独立传输）
        bool sameAsBundle =
            (bundle.width > 0 && bundle.height > 0 &&
             ame100_present.present != NULL && bundle.buffer != NULL &&
             memcmp(ame100_present.present, bundle.buffer,
                    (size_t)bundle.width * (size_t)bundle.height * 4) == 0);
        NSLog(@"[OSMBridge] Task103 EASU sentinel verdict: %s (marker %d/%d probe frames, %d consecutive %s); present buffer %s bundle.buffer -- %s; Task104 far-corner hits %d/%d (both sentinels required for LANDED)%s",
              newState == 1
                  ? "LANDED -- full-surface EASU present"
                  : "NOT LANDED -- CG stretch fallback engaged (raw game region stretched full-screen by CoreAnimation)",
              ame99_fsrdiag.mkHits, ame99_fsrdiag.probeFrames,
              newState == 1 ? ame99_fsrdiag.mkConsecM : ame99_fsrdiag.mkConsecMiss,
              newState == 1 ? "matches" : "mismatches",
              sameAsBundle ? "byte-identical to" : "differs from",
              newState == 1
                  ? "end-to-end verified: draw landed + readback honest"
                  : "pre-EASU/stale transport or draw not landing; geometry still corrected via CG stretch",
              ame99_fsrdiag.mkFarHits, ame99_fsrdiag.probeFrames,
              ame106.active
                  ? "; Task106 note: vote fed by driver buffer (present buffer intentionally stale in bundle-direct mode)"
                  : "");
    }
}

static bool ame100_present_frame(int dstW, int dstH) {
    if (ame100_present.broken) return false;
    ame83_gl_t *g = &ame83_fsr.gl;
    if (!g->glReadPixels || !g->glPixelStorei || !g->glGetIntegerv) return false;
    if (dstW <= 0 || dstH <= 0) return false;
    // 惰性分配（尺寸变更时重分配；失败一次性熔断回驱动路径）
    if (ame100_present.bufW != dstW || ame100_present.bufH != dstH) {
        free(ame100_present.scratch);
        free(ame100_present.present);
        size_t sz = (size_t)dstW * (size_t)dstH * 4;
        ame100_present.scratch = (unsigned char *)malloc(sz);
        ame100_present.present = (unsigned char *)malloc(sz);
        if (ame100_present.scratch == NULL || ame100_present.present == NULL) {
            free(ame100_present.scratch);
            free(ame100_present.present);
            ame100_present.scratch = ame100_present.present = NULL;
            ame100_present.broken = true;
            NSLog(@"[OSMBridge] Task100 present: alloc %dx%d failed -- driver readback path retained", dstW, dstH);
            return false;
        }
        ame100_present.bufW = dstW;
        ame100_present.bufH = dstH;
    }
    // GL 状态最小侵占：读/绘 FBO 绑定 + 四项 pack 像素存储。其余状态
    //（program/viewport/纹理）与 glReadPixels 无关，不必触碰。
    int saveDrawFbo = 0, saveReadFbo = 0;
    int saveRowLen = 0, saveAlign = 4, saveSkipPx = 0, saveSkipRows = 0;
    g->glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &saveDrawFbo);
    g->glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING, &saveReadFbo);
    g->glGetIntegerv(GL_PACK_ROW_LENGTH, &saveRowLen);
    g->glGetIntegerv(GL_PACK_ALIGNMENT, &saveAlign);
    g->glGetIntegerv(GL_PACK_SKIP_PIXELS, &saveSkipPx);
    g->glGetIntegerv(GL_PACK_SKIP_ROWS, &saveSkipRows);
    g->glBindFramebuffer(GL_FRAMEBUFFER, 0);
    g->glPixelStorei(GL_PACK_ROW_LENGTH, 0);
    g->glPixelStorei(GL_PACK_ALIGNMENT, 4);
    g->glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
    g->glPixelStorei(GL_PACK_SKIP_ROWS, 0);
    g->glReadPixels(0, 0, dstW, dstH, GL_RGBA, GL_UNSIGNED_BYTE, ame100_present.scratch);
    unsigned int glerr = g->glGetError ? g->glGetError() : 0;
    // 还原（FBO 双通道分别还回，与 ame83_fsr_upscale 同款纪律）
    g->glBindFramebuffer(GL_DRAW_FRAMEBUFFER, (unsigned int)saveDrawFbo);
    g->glBindFramebuffer(GL_READ_FRAMEBUFFER, (unsigned int)saveReadFbo);
    g->glPixelStorei(GL_PACK_ROW_LENGTH, saveRowLen);
    g->glPixelStorei(GL_PACK_ALIGNMENT, saveAlign);
    g->glPixelStorei(GL_PACK_SKIP_PIXELS, saveSkipPx);
    g->glPixelStorei(GL_PACK_SKIP_ROWS, saveSkipRows);
    if (glerr != 0) {
        ame100_present.broken = true;
        NSLog(@"[OSMBridge] Task100 present readback FAILED: glErr=0x%04x -- reverting to driver readback path", glerr);
        return false;
    }
    // 行序翻转：scratch 行 r = GL y=r（底起）；present 行 0 = 图像顶行
    //（OSMESA_Y_UP=0 语义，与驱动回读/CGImage 布局一致）。
    size_t stride = (size_t)dstW * 4;
    for (int row = 0; row < dstH; ++row) {
        memcpy(ame100_present.present + (size_t)row * stride,
               ame100_present.scratch + (size_t)(dstH - 1 - row) * stride, stride);
    }
    if (!ame100_present.engaged) {
        ame100_present.engaged = true;
        NSLog(@"[OSMBridge] Task100 present path engaged: authoritative fb0 readback %dx%d -> present buffer "
              "(driver glFinish readback bypassed for display; bundle.buffer kept for transport forensics)", dstW, dstH);
    }
    return true;
}

void osm_apply_current_ll() {
    // Task 83：缓冲 = 全尺寸表面（FSR 联动下 MC 窗口 < 表面，MC 把帧画进
    // 区域，osm_swap_buffers 再 EASU 铺满）。ame_surfaceWidth==0（启动极早期/
    // 异常路径）回退旧口径 windowWidth（此时二者本就相等，零回归）。
    int bufW = (ame_surfaceWidth > 0) ? ame_surfaceWidth : windowWidth;
    int bufH = (ame_surfaceHeight > 0) ? ame_surfaceHeight : windowHeight;
    if (bufW <= 0 || bufH <= 0) return;
    if (br_get_current()->osm.width == (uint32_t)bufW && br_get_current()->osm.height == (uint32_t)bufH) {
        return;
    }

    br_get_current()->osm.width = bufW;
    br_get_current()->osm.height = bufH;
    br_get_current()->osm.buffer = reallocf(br_get_current()->osm.buffer, bufW * bufH * 4);

    handle.OSMesaMakeCurrent(br_get_current()->osm.context, br_get_current()->osm.buffer, GL_UNSIGNED_BYTE, bufW, bufH);
    handle.OSMesaPixelStore(OSMESA_ROW_LENGTH, bufW);
    handle.OSMesaPixelStore(OSMESA_Y_UP, 0);
}

void osm_make_current(osm_render_window_t* bundle) {
    if(!bundle) {
        // Task 147：br_get_current() 在从未绑定过窗口时返回 NULL——Forge
        // 整合包（OSMesa/zink 渲染器）游戏启动路径的 makeCurrent(NULL)
        // 直达此处，原代码无条件解引用 br_get_current()->osm.buffer，
        // SIGSEGV @ osm_make_current+0x28（Run #356 latestlog.forge 的
        // hs_err 实锤，JVM fatal "Problematic frame"）。空指针守卫后
        // 释放调用安全走完，安装完成（Task 146 标志位已验证生效）之后
        // 的启动崩溃即解。
        basic_render_window_t *ame147_cur = br_get_current();
        if (ame147_cur) {
            free(ame147_cur->osm.buffer);
            CGColorSpaceRelease(ame147_cur->osm.color_space);
            ame147_cur->osm.buffer = NULL;
            ame147_cur->osm.color_space = NULL;
            ame147_cur->osm.width = ame147_cur->osm.height = 0;
        }
        br_set_current(NULL);
        //technically this does nothing as its not possible to unbind a context in OSMesa
        handle.OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
        return;
    }

    br_set_current((basic_render_window_t *)bundle);
    br_get_current()->osm.color_space = CGColorSpaceCreateDeviceRGB();
    osm_apply_current_ll();
}

void osm_swap_buffers() {
    // ★ Task223：后台 GPU 提交禁令驻车点（zink/VirGL/softpipe 一切 osm 系
    // 渲染器的帧边界）。本帧的 GL 提交已全部完成（MC 渲染在本入口之前），
    // 在此睡下 = 冻结渲染线程的下一帧 = 后台零 GPU 提交（VkDevice 不再
    // DEVICE_LOST，MoltenVK 呈现链不再被禁令打断）。
    ame223_bg_park_wait("osm_swap");
    // Task 106：相位计时 t0。gap = 本入口与上次入口之差 = MC 完整帧周期
    //（含 MC 渲染 + 我们的全段）；心跳里 frame - swap = MC 侧帧耗时。
    double t106_0 = ame106_us(mach_absolute_time());
    if (ame106.lastEntryUs > 0.0) {
        double gap106 = t106_0 - ame106.lastEntryUs;
        ame106.gapSumUs += gap106;
        if (gap106 > ame106.gapMaxUs) ame106.gapMaxUs = gap106;
        ++ame106.gapN;
    }
    ame106.lastEntryUs = t106_0;
    ++ame106.winN;
    osm_apply_current_ll();
    // ------------------------------------------------------------------
    // Task 105（蜷缩根治第 4 轮）：视口自适应 EASU 输入区域。
    //
    // c947464 装机日志（bacbf1e 构建）实锤分叉点：BMC2（1.20.1/GLFW/
    // zink+FSR）双哨兵 LANDED（EASU pass 全幅覆盖、present==bundle 字节
    // 一致、fps=60）但 GPU 探针顶带 (2352,1636) RGB=000000——EASU 忠实
    // 放大了输入区域，问题是输入区域内 MC 画的内容本身没填满（其余是黑
    // + 反馈残影）。对照组 26.3（SDL 路径、同构建）同探针 c85e84ff 活色
    // 全屏正常。即：MC 1.20.1/GLFW 路径下 MC 实际铺进 fb0 的区域小于启
    // 动器告知的 windowWidth×windowHeight 信仰，根因在 mod 尺寸链上游
    // （vanilla 1.20.1 已反编译核对：framebuffer 取 glfwGetFramebufferSize
    // = shim 1814×1262，blitToScreen 用同值——非 vanilla 行为）。
    //
    // 修复（理论免疫，不依赖上游根因）：MC 1.20.1 的最终呈现 blit
    // （RenderTarget.a(w,h,..) → _viewport(0,0,w,h) + setOrtho + 全屏四边
    // 形）恰好在 RenderSystem.flipFrame（=本函数）之前把 GL 视口设成 blit
    // 目标尺寸；swap 时刻读 glGetIntegerv(GL_VIEWPORT) 拿到的就是 MC 本帧
    // 实际铺进 fb0 的区域。EASU 输入区域改为跟随它：
    //   · 视口 == 信仰（26.3/正常路径）→ 行为与旧代码完全一致（零回归）；
    //   · 视口 < 信仰（BMC2 型）→ EASU 放大 MC 真实区域 → 几何全屏；
    //   · 视口 == 表面（恢复全分辨率路径）→ 跳过 EASU，直呈（正确）。
    // 闸门（防 aux 视口/异常态误采）：原点必须 (0,0)、尺寸必须为正且不超
    // 表面、面积 ≥ 信仰的 1/4（907×631 型折半命中；阴影/图标等小视口一律
    // 拒绝回退信仰值 = 现行为）。任一不满足 → 维持 windowWidth 信仰 +
    // 证据日志（下轮装机日志可凭 vp= 一眼钉死上游根因的具体数值）。
    // ------------------------------------------------------------------
    int effW = windowWidth, effH = windowHeight;   // EASU 实际输入区域
    int vp105W = 0, vp105H = 0;                    // MC 真实视口（证据/心跳）
    bool vp105Adapted = false;
    if (ame83_resolve_gl() && ame83_fsr.gl.glGetIntegerv &&
        br_get_current() != NULL &&
        br_get_current()->osm.width > 0 && br_get_current()->osm.height > 0) {
        int vp105[4] = {0, 0, 0, 0};
        ame83_fsr.gl.glGetIntegerv(GL_VIEWPORT, vp105);
        vp105W = vp105[2]; vp105H = vp105[3];
        bool anchored105 = (vp105[0] == 0 && vp105[1] == 0);
        bool fits105 = (vp105[2] > 0 && vp105[3] > 0 &&
                        (uint32_t)vp105[2] <= br_get_current()->osm.width &&
                        (uint32_t)vp105[3] <= br_get_current()->osm.height);
        bool area105 = (windowWidth > 0 && windowHeight > 0 &&
                        (long long)vp105[2] * (long long)vp105[3] * 4ll
                            >= (long long)windowWidth * (long long)windowHeight);
        if (anchored105 && fits105 && area105 &&
            (vp105[2] != windowWidth || vp105[3] != windowHeight)) {
            effW = vp105[2];
            effH = vp105[3];
            vp105Adapted = true;
        }
    }
    // 证据行：每个新视口尺寸只打一次（避免高频刷屏；尺寸回切也会再打）
    {
        static int s_vp105W = -1, s_vp105H = -1;
        if (vp105W > 0 && vp105H > 0 && (vp105W != s_vp105W || vp105H != s_vp105H)) {
            s_vp105W = vp105W;
            s_vp105H = vp105H;
            NSLog(@"[OSMBridge] Task105 viewport evidence: MC present viewport 0,0 %dx%d vs launcher window belief %dx%d -- %s",
                  vp105W, vp105H, windowWidth, windowHeight,
                  (vp105W == windowWidth && vp105H == windowHeight)
                      ? "match (vanilla path, no adaptation)"
                      : (vp105Adapted
                             ? "DIVERGED: EASU input follows MC (adaptive) -- geometry restored"
                             : "diverged but gated (origin/area); EASU keeps launcher belief"));
        }
    }
    // Task 99（修复 B）心跳取证：EASU 触发条件变量全可见。b919e0f 装机
    // 日志只有 engaged 一行（会话总帧数 361 < steady 门槛 600，无法证明
    // EASU 是否持续在跑）；本心跳每 120 次交换打一行，一次日志即可判读
    // “条件恒成立但输出未上屏”（绘制/回读层故障）还是“条件中途失效”
    // （尺寸/捆绑层故障）。Task 105 追加 vp=WxH（MC 真实呈现视口）。
    ++ame99_fsrdiag.swaps;
    if ((ame99_fsrdiag.swaps % 120) == 0) {
        // Task 106：相位计时心跳（上一个 120-swap 窗口的均值/峰值）。
        // t=swap 全段（我们的总耗时）/ [pre+easu | glFinish（含驱动回读）|
        // readback（权威回读+行翻；bundle-direct 激活后趋 0）] / frame 帧周期
        // / MC-side = frame - swap。下一轮装机日志据此把帧预算分解到具体层。
        int n106 = ame106.winN > 0 ? ame106.winN : 1;
        int g106 = ame106.gapN > 0 ? ame106.gapN : 1;
        double swapAvg106 = ame106.tSwapUs / (double)n106 / 1000.0;
        double gapAvg106 = ame106.gapSumUs / (double)g106 / 1000.0;
        NSLog(@"[OSMBridge] Task99 swap#%ld: win=%dx%d osm=%ux%u bundle=%p easuFrames=%ld probe=%d/%d verdict=%d present=%d drvProbe=%d/%d mk=%d/%d far=%d/%d vp=%dx%d%s bd=%ld/%ld t=swap %.1f(max %.1f) [pre+easu %.1f glFinish %.1f readback %.1f]ms frame=%.1f MC-side=%.1fms",
              ame99_fsrdiag.swaps, windowWidth, windowHeight,
              br_get_current() ? br_get_current()->osm.width : 0,
              br_get_current() ? br_get_current()->osm.height : 0,
              (void *)br_get_current(), ame83_fsr.frames,
              ame99_fsrdiag.probeHits, ame99_fsrdiag.probeFrames, ame99_fsrdiag.verdict,
              (int)!ame100_present.broken, ame100_present.drvHits, ame100_present.drvFrames,
              ame99_fsrdiag.mkHits, ame99_fsrdiag.probeFrames,
              ame99_fsrdiag.mkFarHits, ame99_fsrdiag.probeFrames,
              vp105W, vp105H, vp105Adapted ? " (adaptive)" : "",
              ame106.hits, ame106.frames,
              swapAvg106, ame106.tSwapMax / 1000.0,
              ame106.tPreUs / (double)n106 / 1000.0,
              ame106.tFinUs / (double)n106 / 1000.0,
              ame106.tReadUs / (double)n106 / 1000.0,
              gapAvg106,
              gapAvg106 > swapAvg106 ? gapAvg106 - swapAvg106 : 0.0);
        // 窗口复位（当前帧的相位尚未累计，归入下一窗口——off-by-one 无诊断意义）
        ame106.winN = ame106.gapN = 0;
        ame106.tPreUs = ame106.tFinUs = ame106.tReadUs = ame106.tSwapUs = 0.0;
        ame106.tPreMax = ame106.tFinMax = ame106.tReadMax = ame106.tSwapMax = 0.0;
        ame106.gapSumUs = ame106.gapMaxUs = 0.0;
    }
    // Task 85（画面分裂根治）：EASU 必须在 glFinish 之前执行。
    //
    // OSMesa 契约：glFinish 触发 GPU→CPU 回读（zink 下本帧数据在 Vulkan
    // image 里，须回读进下方 CGImage 包装的 client buffer；swrast 则本就
    // 同步写入）。Task 83 的旧序是 glFinish → EASU——升采样画在回读之后，
    // 永远到不了 client buffer。真机视觉 = 画面分裂：左下角窗口区域是
    // 本帧原始低清画面，其余区域是上一帧 EASU 输出的残影（Task 84 修齐
    // 编译链后 EASU 首次真跑，本缺陷随之暴露）。
    //
    // 正序：EASU 先把窗口区域升采样铺满 GPU 侧帧缓冲 → glFinish 一次性
    // 回读完整升采样结果 → CGImage 上屏即全幅。
    bool fsrActiveThisFrame = false;
    if (br_get_current()->osm.width > 0 && br_get_current()->osm.height > 0 &&
        (effW > 0 && effH > 0) &&
        ((uint32_t)effW < br_get_current()->osm.width || (uint32_t)effH < br_get_current()->osm.height)) {
        // Task 105：输入区域 = effW×effH（自适应 MC 真实呈现视口；正常
        // 路径 == windowWidth 信仰，零回归）。upscale 内部 glCopyTexSubImage2D
        // 从 fb0 (0,0) 取同区域——正是 MC 本帧 blit 的落点。
        bool ok = ame83_fsr_upscale(effW, effH,
                                    (int)br_get_current()->osm.width, (int)br_get_current()->osm.height);
        if (ok) fsrActiveThisFrame = true;
        if (!ok && !ame83_fsr.healed) {
            ame83_fsr.healed = true;
            NSLog(@"[OSMBridge] Task83 FSR upscale unavailable -- restoring MC window to surface %ux%u (direct full-res render)",
                  br_get_current()->osm.width, br_get_current()->osm.height);
            // Task 83b：nativeSendScreenSize 现已带 SDL3 路径（推 0x207 窗口
            // 尺寸事件）——MC 会真正切回全分辨率渲染，不再出现"小窗渲染 +
            // 未初始化缓冲区域上屏"的绿色花屏。
            CallbackBridge_nativeSendScreenSize((int)br_get_current()->osm.width, (int)br_get_current()->osm.height);
            // Task 139：输入侧同步复位（同 mgl_fsr Task119 兜底）——
            // MC 窗口信念已变为全表面，sendTouchPoint 的 mgFsrScale
            // 除数必须归一，否则触点坐标只发一半 = 输入错位。
            ame139_fsr_heal_reset_input_scale();
        }
    }
    // Task 106 相位计时：t1 = pre+easu 完成（glFinish 前）；
    // t2 = glFinish（含驱动回读）完成。
    double t106_1 = ame106_us(mach_absolute_time());
    // Task 109：窗口内跳过驱动 glFinish（权威 glReadPixels 的内部同步接管）；
    // 非窗口帧 / 非 FSR 帧 / 权威路径熔断时照旧调用（legacy 呈现依赖驱动回读）。
    bool ame109Trial = ame109_trial_gate(fsrActiveThisFrame);
    if (!ame109Trial) {
        handle.glFinish(); // this will force osmesa to write the last rendered image into the buffer
    }
    osm_render_window_t bundle = br_get_current()->osm;
    double t106_2 = ame106_us(mach_absolute_time());
    ame106.tPreUs += t106_1 - t106_0;
    if (t106_1 - t106_0 > ame106.tPreMax) ame106.tPreMax = t106_1 - t106_0;
    ame106.tFinUs += t106_2 - t106_1;
    if (t106_2 - t106_1 > ame106.tFinMax) ame106.tFinMax = t106_2 - t106_1;

    // ------------------------------------------------------------------
    // Task 106（bundle-direct 判定）：glFinish 已把本帧写进 bundle.buffer。
    // 双哨兵（markerCode 每帧 1..254 轮换）同时命中 = 驱动缓冲持有本帧
    // 全幅 EASU 输出——可跳过权威回读+行翻直接上屏（详见文件前段注释）。
    // Task 109：窗口内跳过整段哨兵票——无人调 glFinish 时 bundle 必然
    // stale，miss 会误触 fallback 取证日志；bd 已在进窗时强制退场。
    // ------------------------------------------------------------------
    if (!ame109Trial) {
        bool bundleFresh106 = fsrActiveThisFrame && ame83_fsr.markerArmed &&
                              ame83_fsr.markerCode != 0 &&
                              ame106_bundle_sentinels((const unsigned char *)bundle.buffer,
                                                      bundle.width, bundle.height,
                                                      (unsigned char)ame83_fsr.markerCode);
        if (ame106.active) {
            ++ame106.frames;
            if (bundleFresh106) {
                ame106.misses = 0;
                ++ame106.hits;
            } else if (++ame106.misses >= 2) {
                ame106.active = false;
                ame106.warm = 0;
                if (!ame106.fallbackLogged) {
                    ame106.fallbackLogged = true;
                    NSLog(@"[OSMBridge] Task106 bundle-direct fallback: driver buffer lost per-frame sentinels (stale/pre-EASU transport) -- reverting to authoritative readback path");
                }
            }
        } else if (bundleFresh106) {
            if (++ame106.warm >= 30) {
                ame106.active = true;
                ame106.misses = 0;
                if (!ame106.engagedLogged) {
                    ame106.engagedLogged = true;
                    NSLog(@"[OSMBridge] Task106 bundle-direct present engaged: 30 consecutive fresh full-surface EASU frames in the driver buffer -- duplicate readback + row-flip skipped per frame");
                }
            }
        } else {
            ame106.warm = 0;
        }
    }

    // ------------------------------------------------------------------
    // Task 100（修复 B 续）：权威呈现。FSR 帧不再信任驱动 glFinish 回读——
    // EASU 已在上方画进 fb0，glFinish 已同步完成，此刻显式绑 fb0 全幅
    // glReadPixels 即得权威画面；present 缓冲驱动永不触碰，上屏内容
    // 与驱动回读行为彻底解耦（病历详见 ame100_present_frame 头注）。
    // ------------------------------------------------------------------
    bool presentThisFrame = false;
    if (fsrActiveThisFrame && bundle.width > 0 && bundle.height > 0 && !ame106.active) {
        presentThisFrame = ame100_present_frame((int)bundle.width, (int)bundle.height);
    }
    // Task 109 保底：窗口内权威路径失败（熔断/分配失败）→ 补一次迟到的
    // glFinish，让 legacy bundle 包装仍能上屏本帧正确内容。计入 readback
    // 相位（t2→t3）＝回退成本，语义自洽。
    if (ame109Trial && !presentThisFrame) {
        handle.glFinish();
    }
    // Task 106 相位计时：权威回读+行翻（bundle-direct 激活时本段为空，趋 0）
    {
        double t106_3 = ame106_us(mach_absolute_time());
        ame106.tReadUs += t106_3 - t106_2;
        if (t106_3 - t106_2 > ame106.tReadMax) ame106.tReadMax = t106_3 - t106_2;
    }

    // ------------------------------------------------------------------
    // Task 99/100：EASU 落地探针（双轨）+ CG 拉伸兜底。
    //
    // 探针 A（fb，驱动判决）：scratch = fb0 直读，采样 GL 行序顶带
    //   （行 gameH+1 到 bufH-1——游戏视口永不写、EASU 全幅视口必写）。
    //   16 点任一非零记命中；90 帧多数表决 → verdict=1/-1。
    // 探针 B（driver，纯取证）：bundle.buffer 顶带（top-down 行 1 到
    //   bufH-gameH，与 Task99 旧口径一致）。若 A 命中而 B 未命中，
    //   即实锤驱动传输层断裂（下一轮装机日志可一眼定位）。
    // 判决：verdict=1 → present 全幅上屏（EASU 画面）；verdict=-1 →
    //   CG 拉伸兜底（present/bundle 游戏区域裁剪 → CoreAnimation 全屏）。
    // ------------------------------------------------------------------
    bool cgStretchThisFrame = false;
    // Task 105：探针/兜底裁剪区域同样跟随 effW/effH（MC 真实内容区域）。
    int gameW = effW, gameH = effH;
    if (fsrActiveThisFrame && (ame99_fsrdiag.verdict == 0 || ame83_fsr.markerArmed) &&
        gameW > 0 && gameH > 0 &&
        (uint32_t)gameW < bundle.width && (uint32_t)gameH < bundle.height) {
        size_t stride = (size_t)bundle.width * 4;
        int stripRows = (int)bundle.height - gameH;
        // —— 探针 A：scratch（fb0 直读，GL 行序：高行 = 图像顶带）——
        if (presentThisFrame && stripRows > 2) {
            const unsigned char *fb = ame100_present.scratch;
            int nz = 0;
            for (int i = 0; i < 16; ++i) {
                int row = gameH + 1 + (i * (stripRows - 2)) / 15;   // GL y 从 gameH+1 到 bufH-1
                int col = (int)(((i * 577u) % 1000u) * (bundle.width - 1)) / 999;
                const unsigned char *px = fb + (size_t)row * stride + (size_t)col * 4;
                if (px[0] | px[1] | px[2]) ++nz;
            }
            ++ame99_fsrdiag.probeFrames;
            if (nz > 0) ++ame99_fsrdiag.probeHits;
            // Task 103：哨兵票（地面真值，机制详见 ame83_fsr_init 注释）。
            // scratch[3] = GL(0,0) 像素的 alpha = 本帧哨兵字节（present 全幅
            // 回读已含它，零额外 GL 调用）。初始 3 连即定性；后续 10 连反向
            // 可翻转判决（跨阶段状态变化：标题界面→进世界）。
            if (ame83_fsr.markerArmed && ame83_fsr.markerCode != 0) {
                unsigned char got = ame100_present.scratch[3];
                // Task 104（蜷缩根治）：远角哨兵——341c110 装机日志实锤
                // BMC2（1.20.1/GLFW/zink）会话 (0,0) 哨兵连中 2519/2519 但
                // 屏幕仍蜷角：单左下哨兵只能证明“角落里有 EASU 片元”，
                // 证不了全幅覆盖。远角（GL 右上，present 行序翻转后仍为
                // 屏幕右上）是全幅光栅化的必经之地——只覆盖游戏区域的
                // 绘制在此必缺。票改为双哨兵 AND：任一缺失 = 未落地 →
                // CG 拉伸兜底接管（几何恒全屏）。
                unsigned char gotFar = 0;
                {
                    size_t stride104 = (size_t)bundle.width * 4;
                    size_t farIdx = (size_t)(bundle.height - 2) * stride104
                                    + (size_t)(bundle.width - 2) * 4 + 3;
                    size_t total104 = (size_t)bundle.width * (size_t)bundle.height * 4;
                    if (bundle.width >= 8 && bundle.height >= 8 && farIdx < total104) {
                        gotFar = ame100_present.scratch[farIdx];
                    }
                }
                bool mkHit = (got == (unsigned char)ame83_fsr.markerCode)
                          && (gotFar == (unsigned char)ame83_fsr.markerCode);
                // Task 106：票核心（计数+状态迁移+取证日志）抽取为共享助手，
                // bundle-direct 分支复用同一状态机（票源不同、语义一致）。
                ame103_marker_vote(mkHit, bundle);
            }
        }
        // —— Task 106：bundle-direct 票源（bundle.buffer 双哨兵，top-down 布局：
        //    近角 = 行 H-1 列 0，远角 = 行 1 列 W-2；位置推导见
        //    ame106_bundle_sentinels 注释）。激活期间 scratch 不再回读，
        //    mk 票由此分支供养，判决/翻转语义与权威分支完全一致 ——
        else if (ame106.active && stripRows > 2 && ame83_fsr.markerArmed &&
                 ame83_fsr.markerCode != 0 && bundle.buffer != NULL) {
            ++ame99_fsrdiag.probeFrames;
            size_t stride106 = (size_t)bundle.width * 4;
            size_t nearIdx106 = (size_t)(bundle.height - 1) * stride106 + 3;
            size_t farIdx106 = stride106 + (size_t)(bundle.width - 2) * 4 + 3;
            size_t total106 = (size_t)bundle.width * (size_t)bundle.height * 4;
            unsigned char got106 = 0, gotFar106 = 0;
            if (bundle.width >= 8 && bundle.height >= 8 &&
                nearIdx106 < total106 && farIdx106 < total106) {
                const unsigned char *base106 = (const unsigned char *)bundle.buffer;
                got106 = base106[nearIdx106];
                gotFar106 = base106[farIdx106];
            }
            bool mkHit = (got106 == (unsigned char)ame83_fsr.markerCode)
                      && (gotFar106 == (unsigned char)ame83_fsr.markerCode);
            ame103_marker_vote(mkHit, bundle);
        }
        // —— 探针 B：bundle.buffer（驱动传输取证，top-down 顶带）——
        const unsigned char *base = (const unsigned char *)bundle.buffer;
        if (stripRows > 0 && base != NULL) {
            int nz = 0;
            for (int i = 0; i < 16; ++i) {
                int row = 1 + (i * (stripRows - 2)) / 15;      // 顶带内均匀 16 行
                int col = (int)(((i * 577u) % 1000u) * (bundle.width - 1)) / 999; // 伪随机列
                const unsigned char *px = base + (size_t)row * stride + (size_t)col * 4;
                if (px[0] | px[1] | px[2]) ++nz;
            }
            ++ame100_present.drvFrames;
            if (nz > 0) ++ame100_present.drvHits;
        }
        // Task 103：旧 90 帧非零统计——markerArmed 时仅作取证日志，不
        // overwrite 哨兵判决；未注入哨兵时仍是唯一判决机制（零回归）。
        if (ame99_fsrdiag.probeFrames >= kAme99ProbeFrames &&
            !ame99_fsrdiag.final90Logged) {
            ame99_fsrdiag.final90Logged = true;
            if (!ame83_fsr.markerArmed) {
                ame99_fsrdiag.verdict =
                    (ame99_fsrdiag.probeHits * 3 >= kAme99ProbeFrames) ? 1 : -1;
            }
            if (ame99_fsrdiag.verdict == 1) {
                NSLog(@"[OSMBridge] Task100 EASU landing verified in fb0: top-strip nonzero %d/%d frames (authoritative readback); "
                      "driver transport check: %d/%d -- driver readback %s",
                      ame99_fsrdiag.probeHits, ame99_fsrdiag.probeFrames,
                      ame100_present.drvHits, ame100_present.drvFrames,
                      (ame100_present.drvHits * 3 >= kAme99ProbeFrames)
                          ? "consistent (Task99 misdiagnosis ruled out)"
                          : "stale/partial on this path (present path bypasses it)");
            } else {
                NSLog(@"[OSMBridge] Task100 EASU NOT landing in fb0: top-strip nonzero only %d/%d -- "
                      "engaging CG stretch fallback (game region %dx%d presented full-screen via CoreAnimation; "
                      "geometry correct, bilinear soft); driver transport check: %d/%d",
                      ame99_fsrdiag.probeHits, ame99_fsrdiag.probeFrames, gameW, gameH,
                      ame100_present.drvHits, ame100_present.drvFrames);
            }
        }
    }
    if (ame99_fsrdiag.verdict == -1 &&
        gameW > 0 && gameH > 0 &&
        (uint32_t)gameW < bundle.width && (uint32_t)gameH < bundle.height) {
        cgStretchThisFrame = true;
    }

    // Task 106：swap 全段计时（dispatch 为异步，不计入；分配/探针/CROP
    // 决策等全部计入 tSwap）。
    {
        double t106_end = ame106_us(mach_absolute_time());
        ame106.tSwapUs += t106_end - t106_0;
        if (t106_end - t106_0 > ame106.tSwapMax) ame106.tSwapMax = t106_end - t106_0;
        // Task 109：swap 全段按窗口内外分桶累计（窗口进出日志的 A/B 数据源；
        // 仅 FSR 帧计数，与 ame109.frame 语义对齐，非 FSR 帧不稀释基线）
        if (fsrActiveThisFrame) {
            if (ame109.inWindow) {
                ame109.winSwapUs += t106_end - t106_0;
                ++ame109.winN;
            } else {
                ame109.baseSwapUs += t106_end - t106_0;
                ++ame109.baseN;
            }
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
    // Task 83：CGImage 尺寸 = 表面缓冲尺寸（旧代码用 windowWidth——FSR
    // 联动下窗口<表面，会把整幅升采样结果再裁一遍）。
    if (cgStretchThisFrame) {
        // Task 99 兜底：只包游戏区域（左下 gameW×gameH），bytesPerRow =
        // 全宽 stride；CoreAnimation 把它拉伸到 layer bounds = 几何全屏。
        // Task 100：数据源优先 present 缓冲（fb0 直读权威内容，EASU 未
        // 落地时其角落 = 本帧裸游戏帧）；present 熔断时回退 bundle.buffer。
        // Task 104：兜底拉伸用双线性——layer 默认 Nearest，2x 拉伸会呈
        // 明显块状；Linear 让兜底画质接近 EASU（几何本就全屏）。
        {
            if (!ame104_filters_linear) {
                ame104_filters_linear = true;
                SurfaceViewController.surface.layer.magnificationFilter = kCAFilterLinear;
                SurfaceViewController.surface.layer.minificationFilter = kCAFilterLinear;
                NSLog(@"[OSMBridge] Task104 CG stretch fallback: layer filters Nearest -> Linear (bilinear upscale while EASU coverage is limited)");
            }
        }
        size_t stride = (size_t)bundle.width * 4;
        int topRow = (int)bundle.height - gameH;   // OSMESA_Y_UP=0：GL 的 y 从 0 到 gameH → 底部行区间
        const unsigned char *cropSrc = presentThisFrame ? ame100_present.present
                                                        : (const unsigned char *)bundle.buffer;
        CGDataProviderRef regionProvider = CGDataProviderCreateWithData(
            NULL, cropSrc + (size_t)topRow * stride,
            (size_t)gameH * stride, NULL);
        CGImageRef region = CGImageCreate(gameW, gameH, 8, 32, stride, bundle.color_space,
                                          kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault,
                                          regionProvider, NULL, FALSE, kCGRenderingIntentDefault);
        SurfaceViewController.surface.layer.contents = (__bridge id)region;
        CGImageRelease(region);
        CGDataProviderRelease(regionProvider);
        return;
    }
    if (presentThisFrame) {
        // Task 100 权威呈现：CGImage 包 present 缓冲（fb0 直读 + 行序翻转，
        // 全幅 EASU 升采样画面）。驱动回读何时/如何写 bundle.buffer 与
        // 上屏无关；非 FSR 会话与 present 熔断会话走下方旧路径（零回归）。
        // Task 104：EASU 落地时若先前进过兜底（Linear），还原 Nearest——
        // 全幅 1:1 像素映射下 Nearest 是零插值正确选择。状态用本地旗标
        // 跟踪（避免 ObjC 消息发送，兼容 D1 语法门变换）。
        {
            if (ame104_filters_linear) {
                ame104_filters_linear = false;
                SurfaceViewController.surface.layer.magnificationFilter = kCAFilterNearest;
                SurfaceViewController.surface.layer.minificationFilter = kCAFilterNearest;
                NSLog(@"[OSMBridge] Task104 EASU LANDED: layer filters restored to Nearest (full-surface 1:1 present)");
            }
        }
        CGDataProviderRef presentProvider = CGDataProviderCreateWithData(
            NULL, ame100_present.present, (size_t)bundle.width * bundle.height * 4, NULL);
        CGImageRef presentImg = CGImageCreate(bundle.width, bundle.height, 8, 32, 4 * bundle.width,
                                              bundle.color_space,
                                              kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault,
                                              presentProvider, NULL, FALSE, kCGRenderingIntentDefault);
        SurfaceViewController.surface.layer.contents = (__bridge id)presentImg;
        CGImageRelease(presentImg);
        CGDataProviderRelease(presentProvider);
        return;
    }
    // Task 106（bundle-direct 全幅呈现）：激活期间 presentThisFrame 恒为
    // false，上方两个分支都不命中，落到此处 legacy 全幅包装 bundle.buffer
    //（双哨兵已证明它持有本帧全幅 EASU 输出；OSMESA_Y_UP=0 本就 top-down）。
    // 滤镜还原纪律与 present 分支同款：从兜底（Linear）切回落地时还原
    // Nearest（全幅 1:1 像素映射零插值）。
    if (ame106.active && fsrActiveThisFrame && ame104_filters_linear) {
        ame104_filters_linear = false;
        SurfaceViewController.surface.layer.magnificationFilter = kCAFilterNearest;
        SurfaceViewController.surface.layer.minificationFilter = kCAFilterNearest;
        NSLog(@"[OSMBridge] Task104 EASU LANDED: layer filters restored to Nearest (full-surface 1:1 present)");
    }
    CGDataProviderRef bitmapProvider = CGDataProviderCreateWithData(NULL, bundle.buffer, bundle.width * bundle.height * 4, NULL);
    CGImageRef bitmap = CGImageCreate(bundle.width, bundle.height, 8, 32, 4 * bundle.width, bundle.color_space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault, bitmapProvider, NULL, FALSE, kCGRenderingIntentDefault);
    SurfaceViewController.surface.layer.contents = (__bridge id)bitmap;
    CGImageRelease(bitmap);
    CGDataProviderRelease(bitmapProvider);
    });
}

void osm_swap_interval(int swapInterval) {
    // Nothing to do here
}

void osm_terminate() {
    // Nothing to do here
}

void set_osm_bridge_tbl() {
    br_init = osm_init;
    br_init_context = (br_init_context_t) osm_init_context;
    br_make_current = (br_make_current_t) osm_make_current;
    br_swap_buffers = osm_swap_buffers;
    br_swap_interval = osm_swap_interval;
    br_terminate = osm_terminate;
}
