#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>

#define GL_GLEXT_PROTOTYPES

#include "GL/gl.h"
#include "GL/glext.h"
//#include "GLES3/gl32.h"
// Task173：iOS SDK 不带 <EGL/egl.h>（libEGL.framework 是自定义产物）。
// eglGetProcAddress 手写 extern 声明（链接期由 -framework libEGL 解析）。
extern void *eglGetProcAddress(const char *procname);
#include "string_utils.h"

// Task224：ES3/ANGLE 需要 sized 深度内部格式。桌面 GL 调用方传非 sized 的
// GL_DEPTH_COMPONENT/GL_DEPTH_STENCIL，ANGLE(Metal) 直接 1282 拒绝
// （“Invalid combination of format, type and internalFormat”），深度附件
// 永不成立 → MC 死于 GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT（1.20.1
// ANGLE 会话 latestlog.txt 2026-10-06 实证：glTexImage2D ifmt=0x1902
// fmt=0x1902 type=0x1406 → 1282 → egv.b 抛 RuntimeException）。
// vendored 头文件对以下常量覆盖不全，全部 #ifndef 本地定义。
// Task225（Task212 A6 语法门债务修复）：GL_DEPTH_COMPONENT（0x1902）与
// GL_STENCIL_INDEX（0x1901）在 vendored 头覆盖不全——真实构建的 include
// 链里有，但 193 语法门的独立编译环境没有（Task224 深度重映射引入的
// 引用）。补 #ifndef 本地定义，两个环境都对。
#ifndef GL_DEPTH_COMPONENT
#define GL_DEPTH_COMPONENT 0x1902
#endif
#ifndef GL_DEPTH_COMPONENT16
#define GL_DEPTH_COMPONENT16 0x81A5
#endif
#ifndef GL_DEPTH_COMPONENT24
#define GL_DEPTH_COMPONENT24 0x81A6
#endif
#ifndef GL_DEPTH_COMPONENT32F
#define GL_DEPTH_COMPONENT32F 0x8CAC
#endif
#ifndef GL_DEPTH24_STENCIL8
#define GL_DEPTH24_STENCIL8 0x88F0
#endif
#ifndef GL_DEPTH_STENCIL
#define GL_DEPTH_STENCIL 0x84F1
#endif
#ifndef GL_UNSIGNED_INT_24_8
#define GL_UNSIGNED_INT_24_8 0x84FA
#endif

// ============================================================================
// Task182: gles_ 解析钉死（ANGLE 渲染器 pipeline/gui 崩溃根修——命名空间
// 分裂）。病历（bc1941b 装机 latestlog.txt，ANGLE 26.3 FO 会话，Task181
// 取证数据回收）：
//   [tinygl4angle] Task181 glShaderSource #1: len0=435 head48='#version 300 es...'
//   [tinygl4angle] Task181 glCompileShader #1: shader=1 COMPILE_STATUS=0 logHead=''
//   → MC 的 ES300 源【确实送达】本 dylib（Task175 重写链全程正常），
//     但编译后 status=0 且 infoLog 为空 = 典型 GL_INVALID_OPERATION
//     （shader id 在编译器所在的库里不存在）。
// 机制：本 dylib 的 gles_ 前缀函数此前用裸 dlsym(RTLD_NEXT) 解析——命中
// 全局搜索序里本 dylib 之后的【下一个提供者】，真机上那是系统
// /usr/lib/libGLESv2；而 MC 的 glCreateSymbol 走 dlsym(本 dylib handle)
// 的导出闭包（自身 + 依赖的 ANGLE libGLESv2 framework，见 Task173 注释）
// = app Frameworks 副本。两份 ANGLE = 两个 id 命名空间：
//   - 上一轮（afa23a6，glCompileSymbol 未导出）：MC compile 直连 Frameworks
//     副本（id=1 在那创建）而源码被本 dylib 上传到系统副本（无效丢弃）
//     → Frameworks 副本编译【空源码】 → "ERROR: 1:1: '' : syntax error"；
//   - 本轮（Task181 导出 glCompileShader 抢到符号）：编译也进了本 dylib
//     → LOOKUP_FUNC 落系统副本 → 那里 id=1 无效 → status=0 + 空 log。
// 两轮形态全部闭环，且 EGL 上下文（gl_bridge 从 ANGLE 框架解析）= Frameworks
// 副本——一切 gles_ 调用都必须落在它上面才对得上 current context。
// 修法（对齐 vgpu pack/load.c 的 Task173 先例 + ame173_gpa 同链）：
//   eglGetProcAddress（当前 client API 的入口，与上下文同源）→
//   显式 dlopen @rpath/libGLESv2.framework/libGLESv2（app 副本句柄）→
//   RTLD_NEXT / RTLD_DEFAULT 兜底。
// ============================================================================
static void *ame182_gles2 = NULL;  // Frameworks 副本句柄（dlopen 幂等，竞态无害）
static int ame182_pinLogs = 0;
static void *ame182_resolve(const char *name) {
    void *p = (void *)eglGetProcAddress(name);
    if (p != NULL) {
        if (ame182_pinLogs < 2) { ame182_pinLogs++; printf("[tinygl4angle] Task182 gles pin: %s via eglGetProcAddress (context-sourced)\n", name); }
        return p;
    }
    if (ame182_gles2 == NULL) {
        ame182_gles2 = dlopen("@rpath/libGLESv2.framework/libGLESv2", RTLD_LAZY | RTLD_LOCAL);
        if (ame182_gles2 == NULL) {
            ame182_gles2 = dlopen("@executable_path/Frameworks/libGLESv2.framework/libGLESv2", RTLD_LAZY | RTLD_LOCAL);
        }
    }
    if (ame182_gles2 != NULL) {
        p = dlsym(ame182_gles2, name);
        if (p != NULL) {
            if (ame182_pinLogs < 2) { ame182_pinLogs++; printf("[tinygl4angle] Task182 gles pin: %s via frameworks handle\n", name); }
            return p;
        }
    }
    p = dlsym(RTLD_NEXT, name);
    if (p != NULL) {
        if (ame182_pinLogs < 2) { ame182_pinLogs++; printf("[tinygl4angle] Task182 gles pin: %s via RTLD_NEXT (legacy)\n", name); }
        return p;
    }
    p = dlsym(RTLD_DEFAULT, name);
    return p;
}

#define LOOKUP_FUNC(func) \
    if (!gles_##func) { \
        gles_##func = ame182_resolve(#func); \
    }

#define AliasDecl(NAME, EXT) \
    asm(".global _"# NAME "\n_" #NAME ": b _" #NAME #EXT);

#define AliasDeclPriv(NAME) \
    asm(".global _gl"# NAME "\n_gl" #NAME ": b _GL_" #NAME);

// Core OpenGL 2.0
AliasDecl(glGetTexImage, ANGLE)
AliasDecl(glMapBuffer, OES)

// GL_KHR_debug
AliasDecl(glDebugMessageCallback, KHR)
AliasDecl(glDebugMessageControl, KHR)
AliasDecl(glDebugMessageInsert, KHR)
AliasDecl(glGetDebugMessageLog, KHR)
AliasDecl(glGetObjectLabel, KHR)
AliasDecl(glObjectLabel, KHR)
AliasDecl(glPopDebugGroup, KHR)
AliasDecl(glPushDebugGroup, KHR)

// GL_EXT_blend_func_extended
AliasDecl(glBindFragDataLocation, EXT)
AliasDecl(glBindFragDataLocationIndexed, EXT)

// Hidden functions
AliasDeclPriv(DrawBuffer)
AliasDeclPriv(PolygonMode)

int proxy_width, proxy_height, proxy_intformat, maxTextureSize;

void(*gles_glCopyTexSubImage2D)(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height);
//void glGetBufferParameteriv(GLenum target, GLenum value, GLint * data);
void(*gles_glGetTexLevelParameteriv)(GLenum target, GLint level, GLenum pname, GLint *params);
void(*gles_glShaderSource)(GLuint shader, GLsizei count, const GLchar * const *string, const GLint *length);
// Task183：glBindTexture 转发（buffer 纹理目标重定向用）
void(*gles_glBindTexture)(GLenum target, GLuint texture);
void(*gles_glTexImage2D)(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *data);
void(*gles_glTexSubImage2D)(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const GLvoid *data);
void(*gles_glTexParameterfv)(GLenum target, GLenum pname, const GLfloat *params);

// Task 215 前置声明（定义在下方 Task215 块，引用在此处之前）
static float ame215_clear_depth = 1.0f;
static int ame215_depth_fix_state = -1;

void glClearDepth(GLdouble depth) {
    ame215_clear_depth = (float)depth;
    glClearDepthf(depth);
}

// ============================================================================
// Task 215: ANGLE-Metal 深度清除 workaround（ANGLE 渲染器“方块透明/透视”修复）
//
// 病灶：ANGLE(Metal) 的 glClear(GL_DEPTH_BUFFER_BIT) 在部分帧缓冲上静默失效，
// 深度缓冲残留上一帧数据 → 地形片元深度测试错误失败 → 方块成片“透明/消失”
// （透视效果），天空/实体/UI 因绘制顺序与深度依赖不同而表现正常。
// 佐证：MobileGlues 对同一 ANGLE 有两级修复（angle_depth_clear_fix_mode，
// Mode1=z=1 全屏三角重写深度 / Mode2=glClearBufferfv 显式清除），证明该
// 驱动缺陷在本机真实存在；raw ANGLE（本垫片）路径此前没有任何防护。
// Task212 的三探针（地形 mega-draw 着陆探针等）保留不动：本修复与它们
// 正交，装机日志双向定证。
//
// 修复（Mode2 同款，零着色器依赖）：拦截 glClear，凡带 DEPTH 位且清除值
// ≈1.0 时，先用 glClearBufferfv(GL_DEPTH) 显式写深度，再走原 glClear。
// 开关：AME_TINYGL4_DEPTH_CLEAR_FIX=0 关闭（默认开启）。
// ============================================================================

void(*gles_glClear)(GLbitfield mask);
void(*gles_glClearBufferfv)(GLenum buffer, GLint drawbuffer, const GLfloat *value);

void glClear(GLbitfield mask) {
    LOOKUP_FUNC(glClear)
    if (mask & 0x00000100 /*GL_DEPTH_BUFFER_BIT*/) {
        if (ame215_depth_fix_state < 0) {
            const char *ame215_env = getenv("AME_TINYGL4_DEPTH_CLEAR_FIX");
            ame215_depth_fix_state = (ame215_env && !strcmp(ame215_env, "0")) ? 0 : 1;
            if (ame215_depth_fix_state) {
                printf("[tinygl4angle] Task215 ANGLE-Metal depth-clear workaround armed (stale-depth x-ray fix; AME_TINYGL4_DEPTH_CLEAR_FIX=0 to disable)\n");
            }
        }
        if (ame215_depth_fix_state == 1 && fabsf(ame215_clear_depth - 1.0f) <= 0.001f) {
            LOOKUP_FUNC(glClearBufferfv)
            if (gles_glClearBufferfv) {
                const GLfloat ame215_d = ame215_clear_depth;
                gles_glClearBufferfv(0x0180 /*GL_DEPTH*/, 0, &ame215_d);
            }
        }
    }
    gles_glClear(mask);
}

// ============================================================================
// Task173: 桌面 GL 补全层（ANGLE 渲染器 pipeline/gui 崩溃根修）。
//
// 病历（FO pack + libtinygl4angle 装机会话 latestlog.old.txt）：GL 后端
// 首次被接受（Task172 镜像链生效），但 MC 26.3 的 minecraft:pipeline/gui
// 预编译抛 IllegalStateException（LWJGL NULL 函数指针——“No context is
// current or a function that is not available...”）→ Failed to find or load
// pipeline → 崩溃。机制：LWJGL GL$1 的 macOS 分支（反编译实证）只做
// OSMesaGetProcAddress（本 dylib 无此导出，恒 0x0）→ dlsym 回退到本
// dylib 的导出闭包（自身 + 依赖的 ANGLE libGLESv2 framework）。ES 框架
// 的导出表是 ES API 集——桌面 GL 独有的名字（glDepthRange 双精度版/
// glQueryCounter/BaseVertex 绘制族/分槽 blend 族等）在闭包里恒 NULL，
// MC 26.3 的 GL 后端（renderpearl）直接调用这些 GL33 核心函数。
//
// 修复：在本 dylib 里实现这些桌面名（dlsym 因此命中我们），首调用时经
// eglGetProcAddress 解析真实指针（ANGLE 的 EGL 对当前绑定的 client API
// 提供桌面 GL 入口；上下文已建立时有效），EXT 后缀变体兜底；纯桌面语义
// 无 ES 对应（glLogicOp）时安全 no-op + 一次性日志。另附 Task173 取证：
// 首次 glGetString 时逐项记录解析结果（装机日志可直接钉死残余缺项）。
// ============================================================================

static pthread_mutex_t ame173_mtx = PTHREAD_MUTEX_INITIALIZER;

/// 单名字解析：eglGetProcAddress → RTLD_NEXT（跳过自身，防自递归）→ NULL
static void *ame173_gpa(const char *name) {
    void *p = (void *)eglGetProcAddress(name);
    if (!p) {
        p = dlsym(RTLD_NEXT, name);
    }
    return p;
}

/// 多名字解析：主名 + 后缀变体（EXT/OES/KHR/NV/ARB）依序尝试
static void *ame173_gpa_multi(const char *name) {
    static const char *ame173_suffixes[] = {"", "EXT", "OES", "KHR", "NV", "ARB"};
    char buf[128];
    for (size_t s = 0; s < sizeof(ame173_suffixes) / sizeof(ame173_suffixes[0]); s++) {
        if (s == 0) {
            void *p = ame173_gpa(name);
            if (p) return p;
        } else {
            snprintf(buf, sizeof(buf), "%s%s", name, ame173_suffixes[s]);
            void *p = ame173_gpa(buf);
            if (p) return p;
        }
    }
    return NULL;
}

#define AME173_RESOLVE(var, name) \
    do { \
        if (!(var)) { \
            pthread_mutex_lock(&ame173_mtx); \
            if (!(var)) { (var) = ame173_gpa_multi(name); } \
            pthread_mutex_unlock(&ame173_mtx); \
        } \
    } while (0)

// ---- 取证：Task173 解析结果一次性日志（首次 glGetString 时，上下文已就位）----
static void ame173_forensics(void) {
    static dispatch_once_t onceTok;
    dispatch_once(&onceTok, ^{
        NSArray *ame173_names = @[
            @"glQueryCounter", @"glDrawElementsBaseVertex", @"glDrawRangeElementsBaseVertex",
            @"glDrawElementsInstancedBaseVertex", @"glMultiDrawElementsBaseVertex",
            @"glMultiDrawArrays", @"glMultiDrawElements", @"glColorMaski", @"glEnablei",
            @"glDisablei", @"glBlendFuncSeparatei", @"glBlendEquationSeparatei",
            @"glFramebufferTexture", @"glTexBuffer", @"glTexBufferRange",
            @"glVertexAttribDivisor", @"glCopyImageSubData", @"glTexImage1D",
            @"glGetQueryObjectiv", @"glGetQueryObjecti64v"
        ];
        int ok = 0, miss = 0;
        NSMutableArray *misses = [NSMutableArray array];
        for (NSString *n in ame173_names) {
            if (ame173_gpa_multi(n.UTF8String)) { ok++; }
            else { miss++; [misses addObject:n]; }
        }
        printf("[TinyGL] Task173 desktop-GL completion layer: %d/%lu resolved via eglGetProcAddress%s\n",
              ok, (unsigned long)ame173_names.count,
              miss ? [[NSString stringWithFormat:@", MISSING: %@", [misses componentsJoinedByString:@", "]] UTF8String] : " (all present)");
    });
}

// ---- 桌面独有：类型适配（GLdouble → GLfloat / glGetFloatv 加宽）----

void glDepthRange(GLdouble nearVal, GLdouble farVal) {
    glDepthRangef((GLfloat)nearVal, (GLfloat)farVal);
}

void glGetDoublev(GLenum pname, GLdouble *params) {
    GLfloat fparams[64];
    int n = 1;
    // Task173：元素数表（欠拷贝安全——未列出的 pname 按 1 处理，绝不越界写）。
    switch (pname) {
        case 0x0BA6: case 0x0BA7: case 0x0BA8:          // MODELVIEW/PROJECTION/TEXTURE_MATRIX
        case 0x8659:                                    // GL_TEXTURE_MATRIX_ARRAY (GL_NV)
            n = 16; break;
        case 0x0BA2: n = 4; break;                      // VIEWPORT
        case 0x0C23: n = 4; break;                      // COLOR_WRITEMASK
        case 0x84E5: case 0x84E6: case 0x84E7:          // SECONDARY/FOG/TEXTURE_COLOR (1..4)
        case 0x0B52: case 0x0B53: case 0x0B54:          // 0x0B52..: 4 元
            n = 4; break;
        default: n = 1; break;
    }
    glGetFloatv(pname, fparams);
    for (int i = 0; i < n && i < 64; i++) params[i] = (GLdouble)fparams[i];
}

// ---- 取证 + GLSL 版本串规范化（Iris 兼容）----
// 病历：Iris StandardMacros.SEMVER_PATTERN 要求版本串以数字开头，而
// Apple ANGLE 返回 "OpenGL GLSL 3.30 (ANGLE ...)"——正则不匹配 →
// “Could not parse GL version from ...” → 光影包被跳过。这里把
// GL_SHADING_LANGUAGE_VERSION 的 "OpenGL GLSL " 前缀剥掉（返回指针后移）。
static const GLubyte * (*ame173_real_glGetString)(GLenum) = NULL;

// Task179：ES3 上下文的桌面身份伪装。
// 病历（9aacebb 装机 latestlog.old.txt）：ost ANGLE 的桌面 facade 上下文
// （eglBindAPI(EGL_OPENGL_API) + 3.3 Core）里用户着色器从未编译成功过
// ——Task175 的 ES300 重写已自证送达源合法，错误仍是空源特征的
// "ERROR: 1:1: '' : syntax error"；本地 harness 证明 tinygl4angle 上传链
// 逐字节无损。gl_init_context 已改为创建真 ES3 上下文（Task179），
// 但 MC 26.3 RenderPearl 的 GL 后端要求桌面 GL 3.3 身份（LWJGL caps 解析
// GL_VERSION 字符串）。这里把 ES 上下文的版本串改写回 facade 会话的同形
// 字串（装机验证过 caps 创建成功的那两串）：
//   GL_VERSION:                   "OpenGL ES 3.2.0 (ANGLE ...)" -> "3.3.0 (ANGLE ...)"
//   GL_SHADING_LANGUAGE_VERSION:  "OpenGL ES GLSL ES 3.20 (ANGLE ...)" -> "OpenGL GLSL 3.30 (ANGLE ...)"
// （后者接着走下方 Task173 的 Iris 规范化剥前缀 → "3.30 (ANGLE ...)"。）
// 任何形态不匹配返回原串（失败安全，不破坏非 ANGLE 会话——本函数只在
// tinygl4angle 镜像内存在，其它渲染器不经过这里）。
static const char *ame179_spoofDesktopVersion(const char *s) {
    static char ame179_buf[256];
    if (s == NULL) return NULL;
    if (strncmp(s, "OpenGL ES 3.", 12) == 0) {
        // s = "OpenGL ES <maj>.<min>.<patch> (ANGLE ...)"；取版本号后的首个空格
        const char *v = s + 10;                 // 跳过 "OpenGL ES "（10 字符）
        const char *sp = strchr(v, ' ');
        if (sp != NULL && strlen(sp) + 6 < sizeof(ame179_buf)) {
            snprintf(ame179_buf, sizeof(ame179_buf), "3.3.0%s", sp);
            return ame179_buf;
        }
    }
    return s;
}

static const char *ame179_spoofDesktopGlsl(const char *s) {
    static char ame179_buf[256];
    if (s == NULL) return NULL;
    if (strncmp(s, "OpenGL ES GLSL ES ", 18) == 0) {
        // s = "OpenGL ES GLSL ES <maj>.<min> (ANGLE ...)"
        const char *v = s + 18;
        const char *sp = strchr(v, ' ');
        if (sp != NULL && strlen(sp) + 19 < sizeof(ame179_buf)) {
            snprintf(ame179_buf, sizeof(ame179_buf), "OpenGL GLSL 3.30%s", sp);
            return ame179_buf;
        }
    }
    return s;
}

static const GLubyte *ame193_appendExtString(const GLubyte *real);   // Task193 前置声明（定义在 ame193 DSA 块）

const GLubyte * glGetString(GLenum name) {
    AME173_RESOLVE(ame173_real_glGetString, "glGetString");
    const GLubyte *result = ame173_real_glGetString ? ame173_real_glGetString(name) : NULL;
    ame173_forensics();
    // Task203：状态查询观察器（printf 版，NSLog 在 dylib 内静默不进日志）。
    // MC/LWJGL 的 caps 构建到底问了什么、拿到了什么——首 12 次记名。
    {
        static int s_ame203_gs = 0;
        if (s_ame203_gs < 12) {
            s_ame203_gs++;
            printf("[tinygl4angle] Task203 query: glGetString #%d name=0x%04X -> \"%.60s\"\n",
                   s_ame203_gs, (unsigned)name, result ? (const char *)result : "<NULL>");
        }
    }
    // Task193：旧式扩展枚举路径与索引式（glGetStringi）同口径——追加
    // GL_ARB_direct_state_access（DSA 通告，见 ame193 块注释）。
    // Task197：通告默认撤回（默认原样返回真实串，仅 env 门控时追加）。
    if (name == GL_EXTENSIONS && result) {
        return ame193_appendExtString(result);
    }
    if (name == GL_VERSION && result) {
        const char *ame179_s = ame179_spoofDesktopVersion((const char *)result);
        if (ame179_s != (const char *)result) {
            printf("[TinyGL] Task179 desktop identity: GL_VERSION '%s' -> '%s' (ES3 context, facade-form spoof)\n",
                  (const char *)result, ame179_s);
            return (const GLubyte *)ame179_s;
        }
        return result;
    }
    if (name == GL_SHADING_LANGUAGE_VERSION && result) {
        // Task179：先做 ES->facade 伪装，再走 Task173 的 Iris 规范化（剥
        // "OpenGL GLSL " 前缀）——两步串联后 MC/Iris 拿到的最终串与 facade
        // 会话逐字相同（"3.30 (ANGLE ...)"），caps 与光影包解析双不受影响。
        const char *s = (const char *)result;
        const char *ame179_s = ame179_spoofDesktopGlsl(s);
        if (ame179_s != s) {
            printf("[TinyGL] Task179 desktop identity: GLSL '%s' -> '%s' (ES3 context, facade-form spoof)\n",
                  s, ame179_s);
            s = ame179_s;
        }
        size_t l = strlen(s);
        static char ame173_glslbuf[256];
        if (l > 12 && strncmp(s, "OpenGL GLSL ", 12) == 0 && l - 12 < sizeof(ame173_glslbuf)) {
            strlcpy(ame173_glslbuf, s + 12, sizeof(ame173_glslbuf));
            printf("[TinyGL] Task173 GLSL version string normalized: '%s' -> '%s' (Iris semver parse)\n", s, ame173_glslbuf);
            return (const GLubyte *)ame173_glslbuf;
        }
        return (const GLubyte *)s;
    }
    return result;
}

// ---- 同签名转发族：首调用解析 + EXT 变体兜底，解析失败安全 no-op ----

typedef void (*ame173_fn_glQueryCounter)(GLuint, GLenum);
static ame173_fn_glQueryCounter ame173_ptr_glQueryCounter;
void glQueryCounter(GLuint id, GLenum target) {
    AME173_RESOLVE(ame173_ptr_glQueryCounter, "glQueryCounter");
    if (ame173_ptr_glQueryCounter) ame173_ptr_glQueryCounter(id, target);
}

// ---- Task187：desktop-only glEnable 无害化（ANGLE 噪音静默）----
// 病历（8cca75a latestlog.txt，ANGLE 会话）：MC 26.3 RenderPearl 的 GlDevice
// 构造【无条件】调用 glEnable(GL_TEXTURE_CUBE_MAP_SEAMLESS=0x884F) 与
// glEnable(GL_PROGRAM_POINT_SIZE=0x8642)（26.3 client 反编译 GlDevice.java
// 第 147-148 行实证）。ES 3.0 上下文上 ANGLE 拒绝这两个 cap 并通过
// KHR_debug 回调打 "Enum 0x884F is currently not supported." HIGH 级错误
// （MC 全量记录 = 日志噪音 + 每 cap 一条假错误）。同会话的 MobileGlues
// 前端吞掉了这两个调用（0 条 debug message）= 上游同样视其为桌面门面噪音。
// 处理：两个 cap 本地 no-op + 一次性锚点日志，其余 cap 原样转发（零回归）。
// 功能影响：无——ES 3.0 上无缝立方图与程序点尺寸本来就不存在，MC 的
// fallback 路径已经跑了 8 轮日志（渲染循环 58fps 无任何相关副作用）。
typedef void (*ame187_fn_glEnable)(GLenum);
static ame187_fn_glEnable ame187_ptr_glEnable;
void glEnable(GLenum cap) {
    if (cap == 0x884Fu /* GL_TEXTURE_CUBE_MAP_SEAMLESS (desktop-only) */ ||
        cap == 0x8642u /* GL_PROGRAM_POINT_SIZE (desktop-only) */) {
        static int s_ame187_logged = 0;
        if (s_ame187_logged < 2) {
            ++s_ame187_logged;
            printf("[tinygl4angle] Task187: accepted desktop-only glEnable(0x%04X) as no-op (RenderPearl unconditional init; ES rejects with HIGH debug error)\n", (unsigned)cap);
        }
        return;
    }
    AME173_RESOLVE(ame187_ptr_glEnable, "glEnable");
    if (ame187_ptr_glEnable) ame187_ptr_glEnable(cap);
}

typedef void (*ame173_fn_glGetQueryObjectiv)(GLuint, GLenum, GLint *);
static ame173_fn_glGetQueryObjectiv ame173_ptr_glGetQueryObjectiv;
void glGetQueryObjectiv(GLuint id, GLenum pname, GLint *params) {
    AME173_RESOLVE(ame173_ptr_glGetQueryObjectiv, "glGetQueryObjectiv");
    if (ame173_ptr_glGetQueryObjectiv) ame173_ptr_glGetQueryObjectiv(id, pname, params);
}

typedef void (*ame173_fn_glGetQueryObjecti64v)(GLuint, GLenum, GLint64 *);
static ame173_fn_glGetQueryObjecti64v ame173_ptr_glGetQueryObjecti64v;
void glGetQueryObjecti64v(GLuint id, GLenum pname, GLint64 *params) {
    AME173_RESOLVE(ame173_ptr_glGetQueryObjecti64v, "glGetQueryObjecti64v");
    if (ame173_ptr_glGetQueryObjecti64v) ame173_ptr_glGetQueryObjecti64v(id, pname, params);
}

typedef void (*ame173_fn_glGetQueryObjectui64v)(GLuint, GLenum, GLuint64 *);
static ame173_fn_glGetQueryObjectui64v ame173_ptr_glGetQueryObjectui64v;
void glGetQueryObjectui64v(GLuint id, GLenum pname, GLuint64 *params) {
    AME173_RESOLVE(ame173_ptr_glGetQueryObjectui64v, "glGetQueryObjectui64v");
    if (ame173_ptr_glGetQueryObjectui64v) ame173_ptr_glGetQueryObjectui64v(id, pname, params);
}

// ---- Task209（ANGLE 方块透明四叉取证）----
// 病历（59b4f25 装机日志 88fa3f6）：用户判读"angle方块透明"。PC 红鲱鱼已
// 清算（spvc_shim Task209 定谳注释：26.3 全部着色器零 push_constant 块，
// _push_constants NOT FOUND 属正常现象）。编译链全绿（32 shader 全
// COMPILE_STATUS=1、sodium 的 #version 460 frag 经 option 路径 ES 重写
// 成功）、UBO 链健康（terrain _uniform_00_00..03 全命中 + uboBind=98
// 活跃）、零 GL 错误——但该日志的绘制探针只覆盖 glDrawArraysInstanced
// （全样本 count=3/6 小三角形 = GUI/字形级），Task173 的 BaseVertex 族
// 转发【零探针】= 地形绘制在普查里完全不可见（无法排除"地形压根没画"）。
// 本轮四叉：
//   (a) BaseVertex 族（Elements/RangeElements/ElementsInstanced/
//       MultiDrawElements 的 BaseVertex 变体）计数+抽样——地形绘制的
//       存在性与规模直接现形；
//   (b) 抽样绘制点的状态快照（blend/depth/colorMask/drawFb + 纹理单元
//       0-3 绑定）——alpha 通路病灶（混合态/遮罩/图集绑定）的黄金证据；
//   (c) 纹理上传格式法证（glTexImage2D/TexSubImage2D：首 24 次 + 每次
//       >=1M 像素 + 每 4096 次抽一条——图集/光照图的 internalFormat/
//       format/type/尺寸全记录）；
//   (d) 地形族 ESSL 全文 dump（前两个含 sphericalVertexDistance 的源 +
//       前两个 >=3800 字节的大源，全文带 begin/end 标记——块名/采样器
//       声明/输出路径全可见）。
typedef void (*ame209_fn_glGetIntegerv)(GLenum, GLint *);
static ame209_fn_glGetIntegerv ame209_ptr_getInt;
typedef void (*ame209_fn_glActiveTexture)(GLenum);
static ame209_fn_glActiveTexture ame209_ptr_activeTex;

/// Task209 (b)：绘制时刻状态快照（只在抽样命中时调用，查询成本可控；
/// 纹理单元扫描后恢复原 active texture——纯读操作，不改绘制语义）。
static void ame209_draw_state(const char *ame209_tag) {
    AME173_RESOLVE(ame209_ptr_getInt, "glGetIntegerv");
    if (ame209_ptr_getInt == NULL) return;
    GLint ame209_blend = 0, ame209_bsrc = 0, ame209_bdst = 0, ame209_depth = 0,
          ame209_dfunc = 0, ame209_cm[4] = {0, 0, 0, 0}, ame209_fb = 0, ame209_act = 0;
    ame209_ptr_getInt(GL_BLEND, &ame209_blend);
    ame209_ptr_getInt(GL_BLEND_SRC_RGB, &ame209_bsrc);
    ame209_ptr_getInt(GL_BLEND_DST_RGB, &ame209_bdst);
    ame209_ptr_getInt(GL_DEPTH_TEST, &ame209_depth);
    ame209_ptr_getInt(GL_DEPTH_FUNC, &ame209_dfunc);
    ame209_ptr_getInt(GL_COLOR_WRITEMASK, ame209_cm);
    ame209_ptr_getInt(GL_DRAW_FRAMEBUFFER_BINDING, &ame209_fb);
    ame209_ptr_getInt(GL_ACTIVE_TEXTURE, &ame209_act);
    printf("[tinygl4angle] Task209 state (%s): blend=%d src=0x%04X dst=0x%04X "
           "depth=%d func=0x%04X mask=%d%d%d%d drawFb=%u actUnit=%d\n",
           ame209_tag, ame209_blend, (unsigned)ame209_bsrc, (unsigned)ame209_bdst,
           ame209_depth, (unsigned)ame209_dfunc, ame209_cm[0], ame209_cm[1],
           ame209_cm[2], ame209_cm[3], (unsigned)ame209_fb,
           (int)(ame209_act - GL_TEXTURE0));
    AME173_RESOLVE(ame209_ptr_activeTex, "glActiveTexture");
    if (ame209_ptr_activeTex != NULL) {
        for (int ame209_u = 0; ame209_u < 4; ++ame209_u) {
            GLint ame209_tex = 0;
            ame209_ptr_activeTex(GL_TEXTURE0 + ame209_u);
            ame209_ptr_getInt(GL_TEXTURE_BINDING_2D, &ame209_tex);
            printf("[tinygl4angle] Task209 state (%s): unit%d tex2d=%u\n",
                   ame209_tag, ame209_u, (unsigned)ame209_tex);
        }
        ame209_ptr_activeTex((GLenum)ame209_act);
    }
}

/// Task209 (a)：BaseVertex 族统一计数（跨函数共享——MC 的地形提交走哪条
/// 就在哪条现形；no 用于抽样与大规模必采双通道）。
static unsigned ame209_bv_no = 0;
static unsigned ame209_bv_big = 0;
static int ame209_bv_sample(int ame209_big) {
    ++ame209_bv_no;
    if (ame209_big) ++ame209_bv_big;
    return ame209_bv_no <= 8 || (ame209_bv_no % 4000) == 0 ||
           (ame209_big && (ame209_bv_big <= 12 || (ame209_bv_big % 512) == 0));
}

typedef void (*ame173_fn_glDrawElementsBaseVertex)(GLenum, GLsizei, GLenum, const void *, GLint);
static ame173_fn_glDrawElementsBaseVertex ame173_ptr_glDrawElementsBaseVertex;
void glDrawElementsBaseVertex(GLenum mode, GLsizei count, GLenum type, const void *indices, GLint basevertex) {
    AME173_RESOLVE(ame173_ptr_glDrawElementsBaseVertex, "glDrawElementsBaseVertex");
    // Task209 (a)：盲区普查（此前零探针）。
    if (ame209_bv_sample(count >= 1024)) {
        printf("[tinygl4angle] Task209 draw: glDrawElementsBaseVertex #%u mode=%u count=%d base=%d\n",
               ame209_bv_no, (unsigned)mode, (int)count, (int)basevertex);
        ame209_draw_state("DrawElementsBaseVertex");
    }
    if (ame173_ptr_glDrawElementsBaseVertex) {
        ame173_ptr_glDrawElementsBaseVertex(mode, count, type, indices, basevertex);
    } else {
        glDrawElements(mode, count, type, indices);
    }
}

typedef void (*ame173_fn_glDrawRangeElementsBaseVertex)(GLenum, GLuint, GLuint, GLsizei, GLenum, const void *, GLint);
static ame173_fn_glDrawRangeElementsBaseVertex ame173_ptr_glDrawRangeElementsBaseVertex;
void glDrawRangeElementsBaseVertex(GLenum mode, GLuint start, GLuint end, GLsizei count, GLenum type, const void *indices, GLint basevertex) {
    AME173_RESOLVE(ame173_ptr_glDrawRangeElementsBaseVertex, "glDrawRangeElementsBaseVertex");
    // Task209 (a)：盲区普查。
    if (ame209_bv_sample(count >= 1024)) {
        printf("[tinygl4angle] Task209 draw: glDrawRangeElementsBaseVertex #%u mode=%u count=%d base=%d\n",
               ame209_bv_no, (unsigned)mode, (int)count, (int)basevertex);
        ame209_draw_state("DrawRangeElementsBaseVertex");
    }
    if (ame173_ptr_glDrawRangeElementsBaseVertex) {
        ame173_ptr_glDrawRangeElementsBaseVertex(mode, start, end, count, type, indices, basevertex);
    } else {
        glDrawElements(mode, count, type, indices);
    }
}

/// Task212（ANGLE 方块透明，巨型地形绘制落地探针）：76e2564 装机日志
/// 实证 in-world 期存在 count=222534 的 glDrawElementsInstancedBaseVertex
/// 常驻巨型绘制（drawFb=3 = sodium chunk 目标）。在其提交后从【当前帧
/// 缓冲】做 1x1 中心回读：非黑 rgb => 地形像素已落地 chunk 目标（病灶在
/// 其后的合成链）；全黑 => 绘制被丢弃/未光栅化；rgb 非黑但 alpha=0 =>
/// alpha 通路坏（SRC_ALPHA 混合下地形整体透明——与“方块透明”病形直
/// 接对号）。每会话至多 2 次（Task75 SIGBUS 纪律：1x1 独立小读）。
static void ame212_terrain_landing_probe(GLsizei count) {
    if (count < 100000) return;
    static int s_ame212_tl = 0;
    if (s_ame212_tl >= 2) return;
    s_ame212_tl++;
    AME173_RESOLVE(ame209_ptr_getInt, "glGetIntegerv");
    typedef void (*ame212_fn_readpx)(int, int, GLsizei, GLsizei, unsigned, unsigned, void *);
    static ame212_fn_readpx ame212_readpx = NULL;
    AME173_RESOLVE(ame212_readpx, "glReadPixels");
    typedef unsigned (*ame212_fn_geterr)(void);
    static ame212_fn_geterr ame212_geterr = NULL;
    AME173_RESOLVE(ame212_geterr, "glGetError");
    if (ame209_ptr_getInt == NULL || ame212_readpx == NULL) return;
    GLint ame212_vp[4] = {0, 0, 0, 0}, ame212_fb = 0;
    ame209_ptr_getInt(0x0BA2 /*GL_VIEWPORT*/, ame212_vp);
    ame209_ptr_getInt(0x8CA6 /*GL_FRAMEBUFFER_BINDING (Task204: 0x8CAA 被 ANGLE 拒绝)*/, &ame212_fb);
    if (ame212_vp[2] < 2 || ame212_vp[3] < 2) return;
    while (ame212_geterr && ame212_geterr()) {}
    unsigned char ame212_px[4] = {0, 0, 0, 0};
    ame212_readpx(ame212_vp[0] + ame212_vp[2] / 2, ame212_vp[1] + ame212_vp[3] / 2,
                  1, 1, 0x1908 /*GL_RGBA*/, 0x1401 /*GL_UNSIGNED_BYTE*/, ame212_px);
    unsigned ame212_err = ame212_geterr ? ame212_geterr() : 0;
    printf("[tinygl4angle] Task212 terrain landing probe #%d count=%d fb=%u vp=(%d,%d %dx%d) center=(%d,%d,%d,%d) glErr=0x%x -- nonzero rgb => terrain landed in chunk target (look downstream at compositing); black => draw dropped/never rasterized; rgb nonzero with alpha=0 => alpha path broken (SRC_ALPHA blend makes terrain invisible)\n",
           s_ame212_tl, (int)count, (unsigned)ame212_fb,
           ame212_vp[0], ame212_vp[1], ame212_vp[2], ame212_vp[3],
           ame212_px[0], ame212_px[1], ame212_px[2], ame212_px[3], ame212_err);
}

typedef void (*ame173_fn_glDrawElementsInstancedBaseVertex)(GLenum, GLsizei, GLenum, const void *, GLsizei, GLint);
static ame173_fn_glDrawElementsInstancedBaseVertex ame173_ptr_glDrawElementsInstancedBaseVertex;
void glDrawElementsInstancedBaseVertex(GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount, GLint basevertex) {
    AME173_RESOLVE(ame173_ptr_glDrawElementsInstancedBaseVertex, "glDrawElementsInstancedBaseVertex");
    // Task209 (a)：盲区普查（per-section 地形提交的高概率路径）。
    if (ame209_bv_sample(count >= 1024 || instancecount >= 4)) {
        printf("[tinygl4angle] Task209 draw: glDrawElementsInstancedBaseVertex #%u mode=%u count=%d inst=%d base=%d\n",
               ame209_bv_no, (unsigned)mode, (int)count, (int)instancecount, (int)basevertex);
        ame209_draw_state("DrawElementsInstancedBaseVertex");
    }
    if (ame173_ptr_glDrawElementsInstancedBaseVertex) {
        ame173_ptr_glDrawElementsInstancedBaseVertex(mode, count, type, indices, instancecount, basevertex);
    } else {
        glDrawElementsInstanced(mode, count, type, indices, instancecount);
    }
    // Task212：巨型绘制提交后立即回读当前目标（见函数头注释；放提交后
    // 才能读到本绘制的输出）。
    ame212_terrain_landing_probe(count);
}

typedef void (*ame173_fn_glMultiDrawElementsBaseVertex)(GLenum, const GLsizei *, GLenum, const void *const *, GLsizei, const GLint *);
static ame173_fn_glMultiDrawElementsBaseVertex ame173_ptr_glMultiDrawElementsBaseVertex;
void glMultiDrawElementsBaseVertex(GLenum mode, const GLsizei *count, GLenum type, const void *const *indices, GLsizei drawcount, const GLint *basevertex) {
    AME173_RESOLVE(ame173_ptr_glMultiDrawElementsBaseVertex, "glMultiDrawElementsBaseVertex");
    // Task209 (a)：盲区普查（drawcount + 首批 count——多条绘制路径的规模现形）。
    {
        GLsizei ame209_c0 = (count != NULL && drawcount > 0) ? count[0] : 0;
        if (ame209_bv_sample(ame209_c0 >= 1024 || drawcount >= 16)) {
            printf("[tinygl4angle] Task209 draw: glMultiDrawElementsBaseVertex #%u mode=%u drawcount=%d count0=%d\n",
                   ame209_bv_no, (unsigned)mode, (int)drawcount, (int)ame209_c0);
            ame209_draw_state("MultiDrawElementsBaseVertex");
        }
    }
    // Task211（ANGLE 方块透明决战）：multidraw 一律拆解为逐 draw 提交。
    // 病历（17c51003 装机日志，Task209 四叉取证链定谳）：地形绘制提交完全
    // 健康（sodium 的 chunk 多绘制在跑、drawcount=6-7、状态快照干净、零
    // GL 错误），唯独方块不可见——与安卓端 Espryt/MobileGlues-ES 系同族
    // 病灶（Task156 家族病形）：批提交在翻译层→驱动段被整体丢弃。本地无
    // 复现条件，经验疗法 = 拆解为逐 draw（安卓端同族修复正是如此）。逐
    // draw 走本文件自己的包装 = Task209 普查自动覆盖拆解后的每个子绘制
    // （下轮装机日志全可见）。指针解析保留（符号解析证据链不变），但不再
    // 用它提交。
    {
        static unsigned s_task211_mdebv = 0;
        ++s_task211_mdebv;
        if (s_task211_mdebv <= 8 || (s_task211_mdebv % 2048) == 0) {
            printf("[tinygl4angle] Task211 decompose: glMultiDrawElementsBaseVertex #%u drawcount=%d -> per-draw\n",
                   s_task211_mdebv, (int)drawcount);
        }
    }
    for (GLsizei i = 0; i < drawcount; i++) {
        glDrawElementsBaseVertex(mode, count[i], type, indices[i],
                                 (basevertex != NULL) ? basevertex[i] : 0);
    }
}

typedef void (*ame173_fn_glMultiDrawArrays)(GLenum, const GLint *, const GLsizei *, GLsizei);
static ame173_fn_glMultiDrawArrays ame173_ptr_glMultiDrawArrays;
void glMultiDrawArrays(GLenum mode, const GLint *first, const GLsizei *count, GLsizei drawcount) {
    AME173_RESOLVE(ame173_ptr_glMultiDrawArrays, "glMultiDrawArrays");
    // Task211：同 glMultiDrawElementsBaseVertex 的拆解决战（指针解析保留
    // 作证据链，提交一律逐 draw）。
    {
        static unsigned s_task211_mda = 0;
        ++s_task211_mda;
        if (s_task211_mda <= 8 || (s_task211_mda % 2048) == 0) {
            printf("[tinygl4angle] Task211 decompose: glMultiDrawArrays #%u drawcount=%d -> per-draw\n",
                   s_task211_mda, (int)drawcount);
        }
    }
    if (first != NULL && count != NULL) {
        for (GLsizei i = 0; i < drawcount; i++) {
            glDrawArrays(mode, first[i], count[i]);
        }
    }
}

typedef void (*ame173_fn_glMultiDrawElements)(GLenum, const GLsizei *, GLenum, const void *const *, GLsizei);
static ame173_fn_glMultiDrawElements ame173_ptr_glMultiDrawElements;
void glMultiDrawElements(GLenum mode, const GLsizei *count, GLenum type, const void *const *indices, GLsizei drawcount) {
    AME173_RESOLVE(ame173_ptr_glMultiDrawElements, "glMultiDrawElements");
    // Task211：同 glMultiDrawElementsBaseVertex 的拆解决战。
    {
        static unsigned s_task211_mde = 0;
        ++s_task211_mde;
        if (s_task211_mde <= 8 || (s_task211_mde % 2048) == 0) {
            printf("[tinygl4angle] Task211 decompose: glMultiDrawElements #%u drawcount=%d -> per-draw\n",
                   s_task211_mde, (int)drawcount);
        }
    }
    if (count != NULL && indices != NULL) {
        for (GLsizei i = 0; i < drawcount; i++) {
            glDrawElements(mode, count[i], type, indices[i]);
        }
    }
}

typedef void (*ame173_fn_glColorMaski)(GLuint, GLboolean, GLboolean, GLboolean, GLboolean);
static ame173_fn_glColorMaski ame173_ptr_glColorMaski;
void glColorMaski(GLuint buf, GLboolean r, GLboolean g, GLboolean b, GLboolean a) {
    AME173_RESOLVE(ame173_ptr_glColorMaski, "glColorMaski");
    if (ame173_ptr_glColorMaski) {
        ame173_ptr_glColorMaski(buf, r, g, b, a);
    } else if (buf == 0) {
        glColorMask(r, g, b, a);
    }
}

typedef void (*ame173_fn_glEnablei)(GLenum, GLuint);
static ame173_fn_glEnablei ame173_ptr_glEnablei;
void glEnablei(GLenum cap, GLuint index) {
    AME173_RESOLVE(ame173_ptr_glEnablei, "glEnablei");
    if (ame173_ptr_glEnablei) {
        ame173_ptr_glEnablei(cap, index);
    } else if (index == 0) {
        glEnable(cap);
    }
}

typedef void (*ame173_fn_glDisablei)(GLenum, GLuint);
static ame173_fn_glDisablei ame173_ptr_glDisablei;
void glDisablei(GLenum cap, GLuint index) {
    AME173_RESOLVE(ame173_ptr_glDisablei, "glDisablei");
    if (ame173_ptr_glDisablei) {
        ame173_ptr_glDisablei(cap, index);
    } else if (index == 0) {
        glDisable(cap);
    }
}

typedef void (*ame173_fn_glBlendFuncSeparatei)(GLuint, GLenum, GLenum, GLenum, GLenum);
static ame173_fn_glBlendFuncSeparatei ame173_ptr_glBlendFuncSeparatei;
void glBlendFuncSeparatei(GLuint buf, GLenum sfRGB, GLenum dfRGB, GLenum sfA, GLenum dfA) {
    AME173_RESOLVE(ame173_ptr_glBlendFuncSeparatei, "glBlendFuncSeparatei");
    if (ame173_ptr_glBlendFuncSeparatei) {
        ame173_ptr_glBlendFuncSeparatei(buf, sfRGB, dfRGB, sfA, dfA);
    } else if (buf == 0) {
        glBlendFuncSeparate(sfRGB, dfRGB, sfA, dfA);
    }
}

typedef void (*ame173_fn_glBlendEquationSeparatei)(GLuint, GLenum, GLenum);
static ame173_fn_glBlendEquationSeparatei ame173_ptr_glBlendEquationSeparatei;
void glBlendEquationSeparatei(GLuint buf, GLenum modeRGB, GLenum modeAlpha) {
    AME173_RESOLVE(ame173_ptr_glBlendEquationSeparatei, "glBlendEquationSeparatei");
    if (ame173_ptr_glBlendEquationSeparatei) {
        ame173_ptr_glBlendEquationSeparatei(buf, modeRGB, modeAlpha);
    } else if (buf == 0) {
        glBlendEquationSeparate(modeRGB, modeAlpha);
    }
}

typedef void (*ame173_fn_glFramebufferTexture)(GLenum, GLenum, GLuint, GLint);
static ame173_fn_glFramebufferTexture ame173_ptr_glFramebufferTexture;
void glFramebufferTexture(GLenum target, GLenum attachment, GLuint texture, GLint level) {
    AME173_RESOLVE(ame173_ptr_glFramebufferTexture, "glFramebufferTexture");
    if (ame173_ptr_glFramebufferTexture) {
        ame173_ptr_glFramebufferTexture(target, attachment, texture, level);
    } else {
        // ES 降级：2D 纹理挂 2D 挂点（MC 主用 2D RT；cube/3D 场景罕见）
        glFramebufferTexture2D(target, attachment, GL_TEXTURE_2D, texture, level);
    }
}

// ============================================================================
// Task203：ANGLE 黑屏定谳流量观察器（64fdaf2 装机 latestlog.1 复盘）。
// 病历核心矛盾：swapOK=185（渲染循环活着）+ 着色器编译全过 + 图集尺寸
// 正常 + 回读 (0,0,0,0)（真黑内容），但 Task191/192 的 UBO 族调用记录
// 为零（glBindBufferBase/Range/UniformBlockBinding/glBindBuffersBase
// 一个都没被调）——std140 uniform block 声明在着色器里，矩阵却从未
// 经任何可见路径上传。同时 NSLog 在本 dylib 内整体静默（主二进制走
// 重定向进日志，dylib 的 NSLog 落 os_log 不被捕获）——此前"锚点未
// 出现 = 代码未执行"的推理全部作废，本轮全部转 printf 后重开取证。
// 观察器三组（全部 printf、首 N 次 + 绘制类周期抽样，指针解析失败
// 安全 no-op 与转发族同款）：
//   (1) 状态查询族：glGetString/glGetIntegerv/glGetStringi 首几次的
//       name/pname+结果头 —— MC 的 caps 构建路径与扩展表真相；
//   (2) 矩阵上传族：glUniformMatrix4fv/glUniform4fv/glUniform1iv/
//       glUniform1f —— 若 MC 走经典 uniform 路径而非 UBO，这里现形；
//   (3) 绘制族：glUseProgram/glDrawElements/glDrawArrays/
//       glDrawElementsInstanced/glDrawArraysInstanced（sodium 区块管线）
//       —— 若一个 draw 都没有 = 几何从未提交，黑屏定谳。
// ============================================================================
// (2) 矩阵/标量 uniform 转发 + 计数（经典 uniform 路径取证）。
// 注：glUniformMatrix4fv 已由 Task186 的 AME186 转置桥覆盖（transpose
// 语义根修）——其调用计数观察器直接并入 AME186_MATRIX_FN 宏（见下），
// 此处不重定义；下列为 Task186 未覆盖的向量/标量族。
typedef void (*ame203_fn_glUniform4fv)(GLint, GLsizei, const GLfloat *);
static ame203_fn_glUniform4fv ame203_ptr_u4fv;
void glUniform4fv(GLint location, GLsizei count, const GLfloat *value) {
    AME173_RESOLVE(ame203_ptr_u4fv, "glUniform4fv");
    static unsigned s_ame203_u4 = 0;
    unsigned ame203_no = ++s_ame203_u4;
    if (ame203_no <= 8) {
        printf("[tinygl4angle] Task203 uniform: glUniform4fv #%u loc=%d count=%d\n",
               ame203_no, (int)location, (int)count);
    }
    if (ame203_ptr_u4fv) ame203_ptr_u4fv(location, count, value);
}

typedef void (*ame203_fn_glUniform1f)(GLint, GLfloat);
static ame203_fn_glUniform1f ame203_ptr_u1f;
void glUniform1f(GLint location, GLfloat v0) {
    AME173_RESOLVE(ame203_ptr_u1f, "glUniform1f");
    if (ame203_ptr_u1f) ame203_ptr_u1f(location, v0);
}

typedef void (*ame203_fn_glUniform2f)(GLint, GLfloat, GLfloat);
static ame203_fn_glUniform2f ame203_ptr_u2f;
void glUniform2f(GLint location, GLfloat v0, GLfloat v1) {
    AME173_RESOLVE(ame203_ptr_u2f, "glUniform2f");
    if (ame203_ptr_u2f) ame203_ptr_u2f(location, v0, v1);
}

typedef void (*ame203_fn_glUniform3f)(GLint, GLfloat, GLfloat, GLfloat);
static ame203_fn_glUniform3f ame203_ptr_u3f;
void glUniform3f(GLint location, GLfloat v0, GLfloat v1, GLfloat v2) {
    AME173_RESOLVE(ame203_ptr_u3f, "glUniform3f");
    if (ame203_ptr_u3f) ame203_ptr_u3f(location, v0, v1, v2);
}

// ============================================================================
// Task204：ANGLE 黑屏第二轮流量观察器（a599782 装机 latestlog.old.txt 判读）。
// 定谳进展：几何已提交（glDrawArraysInstanced #4000+，6 顶点实例化四边形
// = GUI/图集瓦片）、caps 路径健康（glGetStringi 索引式扩展枚举 12 条 +
// GL_MAJOR/MINOR/NUM_EXTENSIONS 全过）、着色器在用（glUseProgram prog=3/6/9）
// 、swap 58fps——但中心像素 (0,0,0,0)（clearColor 同值）→ 一切几何落在
// 视口外（identity 变换 → 像素坐标几何全部出 NDC → 只剩 clearColor）。
// 且 Task191 的 UBO 绑定观察器（glBindBufferBase/Range/
// glUniformBlockBinding，printf 版）【零触发】+ Task203 矩阵族零触发
// → MC 26.3 画了 4000 个四边形却从未绑定 UBO、从未设置 uniform——
// 数据上传路径整体静默。本轮补齐 Task191/203 都没盯的数据面：
//   glBufferSubData/glBufferData/glMapBufferRange —— 缓冲分配/写入
//   （UBO 若有创建/填充，这里现形；零触发 = MC 压根没走 buffer 路径）；
//   glUniform1i/1iv —— 经典 sampler/标量绑定（计数化升级，Task203 静默版
//   保留语义、补计数）。
// 判读口径：绑定零 + 数据面零 = MC 的 uniform 管线在 Java 侧就被关闭
// （caps 判定问题，下轮反编译 26.3 client.jar 定位具体 gate）；
// 绑定零 + 数据面有 = 绑定调用本身丢失（native 侧，本层可修）。
// ============================================================================
typedef void (*ame204_fn_glBufferSubData)(GLenum, GLintptr, GLsizeiptr, const void *);
static ame204_fn_glBufferSubData ame204_ptr_bsd;
void glBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void *data) {
    AME173_RESOLVE(ame204_ptr_bsd, "glBufferSubData");
    static unsigned s_ame204_bsd = 0;
    unsigned ame204_no = ++s_ame204_bsd;
    if (ame204_no <= 8 || (ame204_no % 2000) == 0) {
        printf("[tinygl4angle] Task204 ubo: glBufferSubData #%u target=0x%04X off=%lld size=%lld\n",
               ame204_no, (unsigned)target, (long long)offset, (long long)size);
    }
    if (ame204_ptr_bsd) ame204_ptr_bsd(target, offset, size, data);
}

typedef void (*ame204_fn_glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
static ame204_fn_glBufferData ame204_ptr_bd;
void glBufferData(GLenum target, GLsizeiptr size, const void *data, GLenum usage) {
    AME173_RESOLVE(ame204_ptr_bd, "glBufferData");
    static unsigned s_ame204_bd = 0;
    unsigned ame204_no = ++s_ame204_bd;
    if (ame204_no <= 8 || (ame204_no % 2000) == 0) {
        printf("[tinygl4angle] Task204 ubo: glBufferData #%u target=0x%04X size=%lld usage=0x%04X\n",
               ame204_no, (unsigned)target, (long long)size, (unsigned)usage);
    }
    if (ame204_ptr_bd) ame204_ptr_bd(target, size, data, usage);
}

typedef void *(*ame204_fn_glMapBufferRange)(GLenum, GLintptr, GLsizeiptr, GLbitfield);
static ame204_fn_glMapBufferRange ame204_ptr_mbr;
void *glMapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    AME173_RESOLVE(ame204_ptr_mbr, "glMapBufferRange");
    static unsigned s_ame204_mbr = 0;
    unsigned ame204_no = ++s_ame204_mbr;
    if (ame204_no <= 8 || (ame204_no % 2000) == 0) {
        printf("[tinygl4angle] Task204 ubo: glMapBufferRange #%u target=0x%04X off=%lld len=%lld access=0x%08X\n",
               ame204_no, (unsigned)target, (long long)offset, (long long)length, (unsigned)access);
    }
    if (ame204_ptr_mbr) return ame204_ptr_mbr(target, offset, length, access);
    return NULL;
}

typedef void (*ame204_fn_glUniform1i)(GLint, GLint);
static ame204_fn_glUniform1i ame204_ptr_u1i;
void glUniform1i(GLint location, GLint v0) {
    AME173_RESOLVE(ame204_ptr_u1i, "glUniform1i");
    static unsigned s_ame204_u1i = 0;
    unsigned ame204_no = ++s_ame204_u1i;
    if (ame204_no <= 8 || (ame204_no % 2000) == 0) {
        printf("[tinygl4angle] Task204 uniform: glUniform1i #%u loc=%d v=%d\n",
               ame204_no, (int)location, (int)v0);
    }
    if (ame204_ptr_u1i) ame204_ptr_u1i(location, v0);
}

typedef void (*ame204_fn_glUniform1iv)(GLint, GLsizei, const GLint *);
static ame204_fn_glUniform1iv ame204_ptr_u1iv;
void glUniform1iv(GLint location, GLsizei count, const GLint *value) {
    AME173_RESOLVE(ame204_ptr_u1iv, "glUniform1iv");
    static unsigned s_ame204_u1iv = 0;
    unsigned ame204_no = ++s_ame204_u1iv;
    if (ame204_no <= 8 || (ame204_no % 2000) == 0) {
        printf("[tinygl4angle] Task204 uniform: glUniform1iv #%u loc=%d count=%d head=%d\n",
               ame204_no, (int)location, (int)count, (value && count > 0) ? (int)value[0] : -1);
    }
    if (ame204_ptr_u1iv) ame204_ptr_u1iv(location, count, value);
}

// (3) 绘制族转发 + 计数（几何提交取证）。
typedef void (*ame203_fn_glUseProgram)(GLuint);
static ame203_fn_glUseProgram ame203_ptr_useProgram;
void glUseProgram(GLuint program) {
    AME173_RESOLVE(ame203_ptr_useProgram, "glUseProgram");
    static unsigned s_ame203_pu = 0;
    unsigned ame203_no = ++s_ame203_pu;
    if (ame203_no <= 8 || (ame203_no % 5000) == 0) {
        printf("[tinygl4angle] Task203 draw: glUseProgram #%u prog=%u\n", ame203_no, (unsigned)program);
    }
    if (ame203_ptr_useProgram) ame203_ptr_useProgram(program);
}

typedef void (*ame203_fn_glDrawElements)(GLenum, GLsizei, GLenum, const void *);
static ame203_fn_glDrawElements ame203_ptr_drawElems;
void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices) {
    AME173_RESOLVE(ame203_ptr_drawElems, "glDrawElements");
    static unsigned s_ame203_de = 0;
    unsigned ame203_no = ++s_ame203_de;
    if (ame203_no <= 8 || (ame203_no % 4000) == 0) {
        printf("[tinygl4angle] Task203 draw: glDrawElements #%u mode=%u count=%d\n",
               ame203_no, (unsigned)mode, (int)count);
    }
    if (ame203_ptr_drawElems) ame203_ptr_drawElems(mode, count, type, indices);
}

typedef void (*ame203_fn_glDrawArrays)(GLenum, GLint, GLsizei);
static ame203_fn_glDrawArrays ame203_ptr_drawArrays;
void glDrawArrays(GLenum mode, GLint first, GLsizei count) {
    AME173_RESOLVE(ame203_ptr_drawArrays, "glDrawArrays");
    static unsigned s_ame203_da = 0;
    unsigned ame203_no = ++s_ame203_da;
    if (ame203_no <= 8 || (ame203_no % 4000) == 0) {
        printf("[tinygl4angle] Task203 draw: glDrawArrays #%u mode=%u first=%d count=%d\n",
               ame203_no, (unsigned)mode, (int)first, (int)count);
    }
    // Task211 (b)：全屏四边形普查。MC post 链的最终合成（blit_screen →
    // fb0）是一次全屏 glDrawArrays（mode=TRIANGLES/STRIP/FAN、count
    // 3-6）——Task209 探针只采样 BaseVertex 族，最终合成的可见度为零
    // （四叉链没切开的原因之一）。这里对“四边形形状”的 draw 计数+抽样，
    // 下轮装机日志直接回答“最终合成有没有被提交”。
    if ((mode == 4u || mode == 5u || mode == 6u) && count >= 3 && count <= 6) {
        static unsigned s_task211_fsq = 0;
        ++s_task211_fsq;
        if (s_task211_fsq <= 12 || (s_task211_fsq % 4096) == 0) {
            printf("[tinygl4angle] Task211 fsq: fullscreen-quad candidate #%u mode=%u first=%d count=%d (final-blit census; drawArrays #%u so far)\n",
                   s_task211_fsq, (unsigned)mode, (int)first, (int)count, ame203_no);
        }
    }
    if (ame203_ptr_drawArrays) ame203_ptr_drawArrays(mode, first, count);
}

typedef void (*ame203_fn_glDrawElementsInstanced)(GLenum, GLsizei, GLenum, const void *, GLsizei);
static ame203_fn_glDrawElementsInstanced ame203_ptr_drawElemsInst;
void glDrawElementsInstanced(GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei instancecount) {
    AME173_RESOLVE(ame203_ptr_drawElemsInst, "glDrawElementsInstanced");
    static unsigned s_ame203_dei = 0;
    unsigned ame203_no = ++s_ame203_dei;
    if (ame203_no <= 8 || (ame203_no % 4000) == 0) {
        printf("[tinygl4angle] Task203 draw: glDrawElementsInstanced #%u mode=%u count=%d inst=%d\n",
               ame203_no, (unsigned)mode, (int)count, (int)instancecount);
    }
    if (ame203_ptr_drawElemsInst) ame203_ptr_drawElemsInst(mode, count, type, indices, instancecount);
}

typedef void (*ame203_fn_glDrawArraysInstanced)(GLenum, GLint, GLsizei, GLsizei);
static ame203_fn_glDrawArraysInstanced ame203_ptr_drawArraysInst;
void glDrawArraysInstanced(GLenum mode, GLint first, GLsizei count, GLsizei instancecount) {
    AME173_RESOLVE(ame203_ptr_drawArraysInst, "glDrawArraysInstanced");
    static unsigned s_ame203_dai = 0;
    unsigned ame203_no = ++s_ame203_dai;
    // Task209 (a)+(b)：既有抽样补状态快照 + 大规模必采（count>=1024 的首
    // 12 次 + 每 512 次——地形绘制若走本函数立即现形，且带全状态）。
    if (ame203_no <= 8 || (ame203_no % 4000) == 0) {
        printf("[tinygl4angle] Task203 draw: glDrawArraysInstanced #%u mode=%u count=%d inst=%d\n",
               ame203_no, (unsigned)mode, (int)count, (int)instancecount);
        ame209_draw_state("DrawArraysInstanced");
    } else if (count >= 1024 || instancecount >= 4) {
        static unsigned s_ame209_daiBig = 0;
        ++s_ame209_daiBig;
        if (s_ame209_daiBig <= 12 || (s_ame209_daiBig % 512) == 0) {
            printf("[tinygl4angle] Task209 draw: glDrawArraysInstanced BIG #%u mode=%u count=%d inst=%d first=%d\n",
                   s_ame209_daiBig, (unsigned)mode, (int)count, (int)instancecount, (int)first);
            ame209_draw_state("DrawArraysInstancedBIG");
        }
    }
    // Task212（合成普查补盲）：76e2564 装机日志实证 MC 26.3 的最终合成/
    // blit 走 glDrawArraysInstanced（mode=TRIANGLES(4)、count=6、inst=1 的
    // 全屏双三角，in-world 期 #4000+ 常驻），Task211 的 glDrawArrays 版
    // fsq 普查全程零命中——普查对象搞错了入口。这里补 instanced 版：计数
    // + 首批样本带状态快照（drawFb/混合态/纹理单元——合成 pass 的目标与
    // 输入一次性现形）。
    if ((mode == 4u || mode == 5u || mode == 6u) && count >= 3 && count <= 6 &&
        instancecount >= 1 && instancecount <= 4) {
        static unsigned s_ame212_fsq = 0;
        ++s_ame212_fsq;
        if (s_ame212_fsq <= 12 || (s_ame212_fsq % 4096) == 0) {
            printf("[tinygl4angle] Task212 fsq-instanced: fullscreen-quad candidate #%u mode=%u first=%d count=%d inst=%d (composite census; drawArraysInstanced #%u so far)\n",
                   s_ame212_fsq, (unsigned)mode, (int)first, (int)count, (int)instancecount, ame203_no);
            if (s_ame212_fsq <= 4) ame209_draw_state("Task212FSQInstanced");
        }
    }
    if (ame203_ptr_drawArraysInst) ame203_ptr_drawArraysInst(mode, first, count, instancecount);
}

// ---- Task183：buffer 纹理 -> 2D 纹理 PBO 桥（与 spvc-shim 的 C 族着色器
// 模拟配套）。病历（59d4b48 装机 latestlog.txt，ANGLE 26.3 FO 会话）：
// clouds.vsh 用 `uniform isamplerBuffer CloudFaces` + texelFetch 线性取数；
// spvc-shim 已把着色器侧换成 isampler2D + ivec2((idx) & 255, (idx) >> 8)
// 折叠坐标，本侧必须把 MC 的 glTexBuffer 数据按【固定宽 256】铺成 2D 纹理
// 才能对上。ANGLE ES 3.0 无 GL_TEXTURE_BUFFER 目标（glBindTexture 直接
// GL_INVALID_ENUM、绑定不成立），因此：
//   glBindTexture(GL_TEXTURE_BUFFER, t) -> 重定向为 GL_TEXTURE_2D 绑定；
//   glTexBuffer(GL_TEXTURE_BUFFER, fmt, buf) -> 绑 buf 为 PBO 查尺寸，
//   glTexImage2D(NULL) 零拷贝上传（宽 256，高 = ceil(元素数/256)）。
// texelFetch 不走采样器过滤，无需 filter；mip 0 完整即 texture complete。
#ifndef GL_TEXTURE_BUFFER
#define GL_TEXTURE_BUFFER 0x8C2A
#endif
#ifndef GL_PIXEL_UNPACK_BUFFER
#define GL_PIXEL_UNPACK_BUFFER 0x88EC
#endif
#ifndef GL_PIXEL_UNPACK_BUFFER_BINDING
#define GL_PIXEL_UNPACK_BUFFER_BINDING 0x88EF
#endif
#ifndef GL_BUFFER_SIZE
#define GL_BUFFER_SIZE 0x8764
#endif
#ifndef GL_R8I
#define GL_R8I 0x8231
#endif
#ifndef GL_R8UI
#define GL_R8UI 0x8232
#endif
#ifndef GL_R16I
#define GL_R16I 0x8233
#endif
#ifndef GL_R16UI
#define GL_R16UI 0x8234
#endif
#ifndef GL_R32I
#define GL_R32I 0x8235
#endif
#ifndef GL_R32UI
#define GL_R32UI 0x8236
#endif
#ifndef GL_R8
#define GL_R8 0x8229
#endif
#ifndef GL_R16
#define GL_R16 0x822A
#endif
#ifndef GL_R16F
#define GL_R16F 0x822D
#endif
#ifndef GL_R32F
#define GL_R32F 0x822E
#endif
#ifndef GL_RG
#define GL_RG 0x8227
#endif
#ifndef GL_RED_INTEGER
#define GL_RED_INTEGER 0x8D94
#endif
#ifndef GL_INT
#define GL_INT 0x1404
#endif

typedef void (*ame183_fn_glBindTexture)(GLenum, GLuint);
static ame183_fn_glBindTexture ame183_ptr_glBindTexture;
void glBindTexture(GLenum target, GLuint texture) {
    LOOKUP_FUNC(glBindTexture)
    // Task183：buffer 纹理目标重定向（ANGLE ES3 无此目标，原样转发只会
    // GL_INVALID_ENUM 且绑定不成立 -> 后续 glTexBuffer 桥拿不到纹理）。
    if (target == GL_TEXTURE_BUFFER) target = GL_TEXTURE_2D;
    gles_glBindTexture(target, texture);
}

/// Task183：内部状态查询/绑定助手（PBO 桥用，同样走钉死链）。
typedef void (*ame183_fn_glBindBuffer)(GLenum, GLuint);
static ame183_fn_glBindBuffer ame183_ptr_glBindBuffer;
typedef void (*ame183_fn_glGetIntegerv)(GLenum, GLint *);
static ame183_fn_glGetIntegerv ame183_ptr_glGetIntegerv;
typedef void (*ame183_fn_glGetBufferParameteriv)(GLenum, GLenum, GLint *);
static ame183_fn_glGetBufferParameteriv ame183_ptr_glGetBufferParameteriv;

typedef struct { GLenum ifmt; GLenum fmt; GLenum type; int px; } ame183_tbfmt_t;
static const ame183_tbfmt_t ame183_tbfmt_table[] = {
    { 0x8229 /*R8*/,    0x1903 /*RED*/,   0x1401 /*UBYTE*/,  1 },
    { 0x8231 /*R8I*/,   0x8D94 /*RED_INT*/, 0x1400 /*BYTE*/, 1 },
    { 0x8232 /*R8UI*/,  0x8D94,           0x1401,            1 },
    { 0x822A /*R16*/,   0x1903,           0x1403 /*USHORT*/, 2 },
    { 0x8233 /*R16I*/,  0x8D94,           0x1402 /*SHORT*/,  2 },
    { 0x8234 /*R16UI*/, 0x8D94,           0x1403,            2 },
    { 0x822D /*R16F*/,  0x1903,           0x140B /*HALF*/,   2 },
    { 0x822E /*R32F*/,  0x1903,           0x1406 /*FLOAT*/,  4 },
    { 0x8235 /*R32I*/,  0x8D94,           0x1404 /*INT*/,    4 },
    { 0x8236 /*R32UI*/, 0x8D94,           0x1405 /*UINT*/,   4 },
    { 0x8058 /*RGBA8*/, 0x1908 /*RGBA*/,  0x1401,            4 },
};

/// Task183：buffer 数据按固定宽 256 铺 2D 纹理（PBO 零拷贝）。
static void ame183_texbuffer_to_2d(GLenum internalformat, GLuint buffer) {
    if (buffer == 0) return;
    AME173_RESOLVE(ame183_ptr_glBindBuffer, "glBindBuffer");
    AME173_RESOLVE(ame183_ptr_glGetIntegerv, "glGetIntegerv");
    AME173_RESOLVE(ame183_ptr_glGetBufferParameteriv, "glGetBufferParameteriv");
    if (!ame183_ptr_glBindBuffer || !ame183_ptr_glGetIntegerv ||
        !ame183_ptr_glGetBufferParameteriv || !gles_glTexImage2D) {
        return;
    }
    GLint prevPB = 0;
    ame183_ptr_glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING, &prevPB);
    GLint size = 0;
    ame183_ptr_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, buffer);
    ame183_ptr_glGetBufferParameteriv(GL_PIXEL_UNPACK_BUFFER, GL_BUFFER_SIZE, &size);
    ame183_ptr_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, (GLuint)prevPB);
    if (size <= 0) return;
    const ame183_tbfmt_t *f = NULL;
    for (size_t i = 0; i < sizeof(ame183_tbfmt_table) / sizeof(ame183_tbfmt_table[0]); ++i) {
        if (ame183_tbfmt_table[i].ifmt == internalformat) { f = &ame183_tbfmt_table[i]; break; }
    }
    if (f == NULL) {
        static int s_ame183_tbUnknown = 0;
        if (s_ame183_tbUnknown < 2) {
            ++s_ame183_tbUnknown;
            printf("[tinygl4angle] Task183 texbuffer bridge: unknown internalformat 0x%X "
                   "(size=%d) -- skipping upload\n", (unsigned)internalformat, size);
        }
        return;
    }
    int elements = size / f->px;
    if (elements <= 0) return;
    int width = 256;
    int height = (elements + width - 1) / width;
    // PBO 源 = 刚才解绑了 —— 重新绑上再传（TexImage 从 PBO 读）
    ame183_ptr_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, buffer);
    gles_glTexImage2D(GL_TEXTURE_2D, 0, (GLint)internalformat, width, height, 0,
                      f->fmt, f->type, NULL);
    ame183_ptr_glBindBuffer(GL_PIXEL_UNPACK_BUFFER, (GLuint)prevPB);
    static int s_ame183_tbLogged = 0;
    if (s_ame183_tbLogged < 4) {
        ++s_ame183_tbLogged;
        printf("[tinygl4angle] Task183 texbuffer bridge: %d bytes -> 2D %dx%d "
               "(fmt 0x%X, px %d)\n", size, width, height, (unsigned)internalformat, f->px);
    }
}

typedef void (*ame173_fn_glTexBuffer)(GLenum, GLenum, GLuint);
static ame173_fn_glTexBuffer ame173_ptr_glTexBuffer;
void glTexBuffer(GLenum target, GLenum internalformat, GLuint buffer) {
    // Task183：ES3.0 无 texture buffer —— 先走 2D 桥；桥不认识再试原生
    //（未来 ES3.1+ 上下文可用原生路径）。
    if (target == GL_TEXTURE_BUFFER) {
        ame183_texbuffer_to_2d(internalformat, buffer);
        return;
    }
    AME173_RESOLVE(ame173_ptr_glTexBuffer, "glTexBuffer");
    if (ame173_ptr_glTexBuffer) {
        ame173_ptr_glTexBuffer(target, internalformat, buffer);
    }
}

typedef void (*ame173_fn_glTexBufferRange)(GLenum, GLenum, GLuint, GLintptr, GLsizeiptr);
static ame173_fn_glTexBufferRange ame173_ptr_glTexBufferRange;
void glTexBufferRange(GLenum target, GLenum internalformat, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    AME173_RESOLVE(ame173_ptr_glTexBufferRange, "glTexBufferRange");
    if (ame173_ptr_glTexBufferRange) {
        ame173_ptr_glTexBufferRange(target, internalformat, buffer, offset, size);
    }
}

typedef void (*ame173_fn_glVertexAttribDivisor)(GLuint, GLuint);
static ame173_fn_glVertexAttribDivisor ame173_ptr_glVertexAttribDivisor;
void glVertexAttribDivisor(GLuint index, GLuint divisor) {
    AME173_RESOLVE(ame173_ptr_glVertexAttribDivisor, "glVertexAttribDivisor");
    if (ame173_ptr_glVertexAttribDivisor) {
        ame173_ptr_glVertexAttribDivisor(index, divisor);
    }
}

// ============================================================================
// Task191（ANGLE 黑屏第三轮取证）：UBO 绑定族显式转发 + 参数日志。
// 背景：RenderPearl 纯 UBO 上传矩阵（Task187 反编译定案），Task188 readback
// 裁决"真黑内容"（中心像素 rgba=(0,0,0,0) + layer opaque=1 + 58fps 全速
// + 零编译错误）→ 剩余假设空间集中在"UBO 数据未到达着色器"（MVP 全 0 →
// 全部片元被裁剪 → 只剩 clearColor 黑）。
// 本层此前【未实现】glBindBufferRange/glBindBufferBase——LWJGL 的 dlsym 落到
// ANGLE libGLESv2 的 ES 原生符号（desktop 与 ES 3.0 同签名同语义，功能上
// 等价可用），因此这不是缺失修复而是取证布点：把绑定流引到本层打参数，
// 前几次日志即可裁决 (a) MC 是否真的绑定 UBO（零调用 = 绑定路径断裂）
// 与 (b) offset 是否违反 GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT（ES 驱动会
// GL_INVALID_VALUE 拒绝绑定 → 矩阵丢失；desktop GL 对 UBO 同样要求对齐，
// 但 RenderPearl 在真桌面 GL 上从未触发——若这里出现非对齐 offset 即是
// ANGLE 桥的语义差异点）。
// 装机锚点："[tinygl4angle] Task191 ubo: ..." 系列。
// ============================================================================
typedef void (*ame191_fn_glBindBufferRange)(GLenum, GLuint, GLuint, GLintptr, GLsizeiptr);
static ame191_fn_glBindBufferRange ame191_ptr_glBindBufferRange;
void glBindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    AME173_RESOLVE(ame191_ptr_glBindBufferRange, "glBindBufferRange");
    if (ame191_ptr_glBindBufferRange) {
        ame191_ptr_glBindBufferRange(target, index, buffer, offset, size);
    }
    static int ame191_uboLogs = 0;
    if (target == 0x8A11 /*GL_UNIFORM_BUFFER*/ && ame191_uboLogs < 8) {
        ame191_uboLogs++;
        printf("[tinygl4angle] Task191 ubo: glBindBufferRange(idx=%u buf=%u offset=%lld size=%lld%s)\n",
              (unsigned)index, (unsigned)buffer, (long long)offset, (long long)size,
              ((offset & 0xFF) != 0) ? " [UNALIGNED-256!]" : "");
    }
}

typedef void (*ame191_fn_glBindBufferBase)(GLenum, GLuint, GLuint);
static ame191_fn_glBindBufferBase ame191_ptr_glBindBufferBase;
void glBindBufferBase(GLenum target, GLuint index, GLuint buffer) {
    AME173_RESOLVE(ame191_ptr_glBindBufferBase, "glBindBufferBase");
    if (ame191_ptr_glBindBufferBase) {
        ame191_ptr_glBindBufferBase(target, index, buffer);
    }
    static int ame191_uboBaseLogs = 0;
    if (target == 0x8A11 /*GL_UNIFORM_BUFFER*/ && ame191_uboBaseLogs < 8) {
        ame191_uboBaseLogs++;
        printf("[tinygl4angle] Task191 ubo: glBindBufferBase(idx=%u buf=%u)\n", (unsigned)index, (unsigned)buffer);
    }
}

typedef void (*ame191_fn_glUniformBlockBinding)(GLuint, GLuint, GLuint);
static ame191_fn_glUniformBlockBinding ame191_ptr_glUniformBlockBinding;
void glUniformBlockBinding(GLuint program, GLuint uniformBlockIndex, GLuint uniformBlockBinding) {
    AME173_RESOLVE(ame191_ptr_glUniformBlockBinding, "glUniformBlockBinding");
    if (ame191_ptr_glUniformBlockBinding) {
        ame191_ptr_glUniformBlockBinding(program, uniformBlockIndex, uniformBlockBinding);
    }
    static int ame191_ubbLogs = 0;
    if (ame191_ubbLogs < 8) {
        ame191_ubbLogs++;
        printf("[tinygl4angle] Task191 ubo: glUniformBlockBinding(prog=%u block=%u bind=%u)\n", (unsigned)program, (unsigned)uniformBlockIndex, (unsigned)uniformBlockBinding);
    }
}

// ============================================================================
// Task205（ANGLE 黑屏根修验证探针 + 日志等级）：glGetUniformBlockIndex 记名。
// 根修背景见 spvc_shim.c Task205 块注释——重命名（_uniform_%02d_%02d /
// _push_constants）经 ES 重写丢失 → 本查询全 GL_INVALID_INDEX → UBO 线全灭。
// 这个探针让下轮装机日志【一行定谳修复是否生效】：
//   idx != GL_INVALID_INDEX = 块找到了（重放成功，若仍黑屏看别处）
//   idx == GL_INVALID_INDEX = 重放仍失败（看 [spvc-shim] Task205 rename replay 日志）
// 限频：前 12 条全打 + 之后每 512 条抽样；AMETHYST_LOG_LEVEL=debug 时全打
// （首 128 条）。装机锚点："[tinygl4angle] Task205 blockIdx:"。
// Task205c 返回类型勘误：mesa glext.h（及全部 Khronos 系头）声明本函数
// 返回 GLuint（GL_INVALID_INDEX=0xFFFFFFFFu 表未找到）——初版写成 GLint
// （用 -1 判未找到）与真头冲突，CI run 36739697080 编译报 conflicting
// types。本地门用 stub 头抓不到此类冲突，已在 stub glext.h 补上真原型。
// ============================================================================
typedef GLuint (*ame205_fn_glGetUniformBlockIndex)(GLuint, const GLchar *);
static ame205_fn_glGetUniformBlockIndex ame205_ptr_blockIdx;
GLuint glGetUniformBlockIndex(GLuint program, const GLchar *name) {
    AME173_RESOLVE(ame205_ptr_blockIdx, "glGetUniformBlockIndex");
    GLuint ame205_idx = GL_INVALID_INDEX;
    if (ame205_ptr_blockIdx) {
        ame205_idx = ame205_ptr_blockIdx(program, name);
    }
    static unsigned ame205_blockCalls = 0;
    unsigned ame205_no = ++ame205_blockCalls;
    int ame205_debug = (getenv("AMETHYST_LOG_LEVEL") != NULL &&
                        strcmp(getenv("AMETHYST_LOG_LEVEL"), "debug") == 0);
    if (ame205_no <= 12 || (ame205_debug && ame205_no <= 128) ||
        (ame205_no % 512) == 0 || ame205_idx == GL_INVALID_INDEX) {
        printf("[tinygl4angle] Task205 blockIdx: glGetUniformBlockIndex(prog=%u name='%s') -> %u%s\n",
               (unsigned)program, (name ? name : "(null)"), (unsigned)ame205_idx,
               (ame205_idx == GL_INVALID_INDEX) ? " [NOT FOUND]" : "");
    }
    return ame205_idx;
}

// ============================================================================
// Task192（ANGLE 黑屏第四轮）：DSA buffer 族实现 + 参数日志。
// 病历（956ea9b 装机 latestlog.txt，ANGLE 26.3 FO 会话）三铁证：
//   (1) [Render thread/INFO]: DSA support not detected.
//   (2) Thread[#3,Render thread,...]: No context is current or a function
//       that is not available...（LWJGL NULL 函数指针异常，DSA 探测即抛）
//   (3) Task191 UBO 探针零命中：glBindBufferRange/Base/glUniformBlockBinding
//       经本 dylib 的转发【零调用】——RenderPearl 的矩阵上传根本不走传统
//       bind 路径；combined with readback=(0,0,0,0) + 58fps + 零编译错误 =
//       MVP 全零裁剪一切片元。
// 推论：MC 26.3 的 GL 后端 DSA 优先（glCreateBuffers 探测），探测失败后
// 的"降级"路径未覆盖我们这套 ES3 + 无 DSA 符号的环境（探测本身抛的 NULL
// 函数异常即 line-803 打印）。修法：在本 dylib 实现 DSA buffer 族——
// ES3 无 DSA，用 GL_COPY_WRITE_BUFFER 通用绑定点做 bind-free 语义
// （保存/改绑/操作/恢复，四步原子）；探测命中后 MC 走 DSA 路径，
// 矩阵经 glNamedBufferSubData 上传 + glBindBuffersRange/Base 批量绑点。
// 装机锚点："[tinygl4angle] Task192 dsa: ..." 系列（探测成功 + 首批调用
// 参数）+ Task188 swap 探针的 uboBind 从 0 变非 0。
// ============================================================================
#ifndef GL_COPY_WRITE_BUFFER
#define GL_COPY_WRITE_BUFFER 0x8F37
#endif
#ifndef GL_COPY_READ_BUFFER
#define GL_COPY_READ_BUFFER 0x8F36
#endif

static int ame192_dsaLogs = 0;

typedef void (*ame192_fn_glGenBuffers)(GLsizei, GLuint *);
static ame192_fn_glGenBuffers ame192_ptr_glGenBuffers;
void glCreateBuffers(GLsizei n, GLuint *buffers) {
    // DSA 语义：只生成名字，不绑定。ES3 的 glGenBuffers 同语义。
    AME173_RESOLVE(ame192_ptr_glGenBuffers, "glGenBuffers");
    if (ame192_ptr_glGenBuffers) {
        ame192_ptr_glGenBuffers(n, buffers);
    }
    if (ame192_dsaLogs < 8) {
        ame192_dsaLogs++;
        printf("[tinygl4angle] Task192 dsa: glCreateBuffers(n=%d) -> first=%u (DSA probe should now SUCCEED)\n", (int)n, (n > 0 && buffers) ? (unsigned)buffers[0] : 0u);
    }
}

typedef void (*ame192_fn_glBindBuffer)(GLenum, GLuint);
static ame192_fn_glBindBuffer ame192_ptr_glBindBuffer;
typedef void (*ame192_fn_glGetIntegerv)(GLenum, GLint *);
static ame192_fn_glGetIntegerv ame192_ptr_glGetIntegerv;
typedef void (*ame192_fn_glBufferData)(GLenum, GLsizeiptr, const void *, GLenum);
static ame192_fn_glBufferData ame192_ptr_glBufferData;
typedef void (*ame192_fn_glBufferSubData)(GLenum, GLintptr, GLsizeiptr, const void *);
static ame192_fn_glBufferSubData ame192_ptr_glBufferSubData;

static void ame192_resolve_buffer_helpers(void) {
    AME173_RESOLVE(ame192_ptr_glBindBuffer, "glBindBuffer");
    AME173_RESOLVE(ame192_ptr_glGetIntegerv, "glGetIntegerv");
    AME173_RESOLVE(ame192_ptr_glBufferData, "glBufferData");
    AME173_RESOLVE(ame192_ptr_glBufferSubData, "glBufferSubData");
}

void glNamedBufferData(GLuint buffer, GLsizeiptr size, const void *data, GLenum usage) {
    ame192_resolve_buffer_helpers();
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame192_ptr_glBufferData) return;
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    ame192_ptr_glBufferData(GL_COPY_WRITE_BUFFER, size, data, usage);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
    if (ame192_dsaLogs < 8) {
        ame192_dsaLogs++;
        printf("[tinygl4angle] Task192 dsa: glNamedBufferData(buf=%u size=%lld usage=0x%X)\n", (unsigned)buffer, (long long)size, (unsigned)usage);
    }
}

void glNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, const void *data) {
    ame192_resolve_buffer_helpers();
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame192_ptr_glBufferSubData) return;
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    ame192_ptr_glBufferSubData(GL_COPY_WRITE_BUFFER, offset, size, data);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
    if (ame192_dsaLogs < 8) {
        ame192_dsaLogs++;
        printf("[tinygl4angle] Task192 dsa: glNamedBufferSubData(buf=%u off=%lld size=%lld) -- MVP upload path\n", (unsigned)buffer, (long long)offset, (long long)size);
    }
}

typedef void (*ame191_fn_glBindBufferBase)(GLenum, GLuint, GLuint);
typedef void (*ame191_fn_glBindBufferRange)(GLenum, GLuint, GLuint, GLintptr, GLsizeiptr);

void glBindBuffersBase(GLenum target, GLuint first, GLsizei count, const GLuint *buffers) {
    AME173_RESOLVE(ame191_ptr_glBindBufferBase, "glBindBufferBase");
    if (!ame191_ptr_glBindBufferBase) return;
    if (buffers == NULL) {
        // NULL 数组 = 解绑 [first, first+count) 全部绑定点
        for (GLsizei i = 0; i < count; i++) {
            ame191_ptr_glBindBufferBase(target, first + (GLuint)i, 0);
        }
    } else {
        for (GLsizei i = 0; i < count; i++) {
            ame191_ptr_glBindBufferBase(target, first + (GLuint)i, buffers[i]);
        }
    }
    if (ame192_dsaLogs < 8) {
        ame192_dsaLogs++;
        printf("[tinygl4angle] Task192 dsa: glBindBuffersBase(target=0x%X first=%u count=%d, firstBuf=%u)\n", (unsigned)target, (unsigned)first, (int)count, (buffers && count > 0) ? (unsigned)buffers[0] : 0u);
    }
}

void glBindBuffersRange(GLenum target, GLuint first, GLsizei count, const GLuint *buffers, const GLintptr *offsets, const GLsizeiptr *sizes) {
    AME173_RESOLVE(ame191_ptr_glBindBufferRange, "glBindBufferRange");
    if (!ame191_ptr_glBindBufferRange) return;
    if (buffers == NULL) {
        for (GLsizei i = 0; i < count; i++) {
            ame191_ptr_glBindBufferRange(target, first + (GLuint)i, 0, 0, 0);
        }
    } else {
        for (GLsizei i = 0; i < count; i++) {
            ame191_ptr_glBindBufferRange(target, first + (GLuint)i, buffers[i],
                                         (offsets ? offsets[i] : 0), (sizes ? sizes[i] : 0));
        }
    }
    if (ame192_dsaLogs < 8) {
        ame192_dsaLogs++;
        printf("[tinygl4angle] Task192 dsa: glBindBuffersRange(target=0x%X first=%u count=%d, firstBuf=%u off=%lld size=%lld%s)\n",
              (unsigned)target, (unsigned)first, (int)count,
              (buffers && count > 0) ? (unsigned)buffers[0] : 0u,
              (long long)((offsets && count > 0) ? offsets[0] : 0),
              (long long)((sizes && count > 0) ? sizes[0] : 0),
              ((offsets && count > 0 && (offsets[0] & 0xFF) != 0) ? " [UNALIGNED-256!]" : ""));
    }
}

typedef void (*ame192_fn_glGetBufferParameteriv)(GLenum, GLenum, GLint *);
static ame192_fn_glGetBufferParameteriv ame192_ptr_glGetBufferParameteriv;
void glGetNamedBufferParameteriv(GLuint buffer, GLenum pname, GLint *params) {
    ame192_resolve_buffer_helpers();
    AME173_RESOLVE(ame192_ptr_glGetBufferParameteriv, "glGetBufferParameteriv");
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame192_ptr_glGetBufferParameteriv) return;
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    ame192_ptr_glGetBufferParameteriv(GL_COPY_WRITE_BUFFER, pname, params);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
}

// ============================================================================
// Task193：DSA 能力通告 + 索引式扩展枚举 + Map/VAO 命名族。
//
// 病历（727a291 latestlog.txt，fabric 26.3 + tinygl4angle 会话）：
//   [Render thread/INFO]: DSA support not detected.
//   Thread[#3,Render thread]: No context is current or a function that is
//   not available in the current context was called...
//   Using graphics device extensions: GL_KHR_debug, GL_EXT_texture_filter_anisotropic
// MC 26.3 RenderPearl 以 LWJGL caps 判 DSA（GL_ARB_direct_state_access 或
// OpenGL 4.5+），而 caps 由扩展表构建——tinygl4angle 从不导出 glGetStringi
// 也不拦 GL_NUM_EXTENSIONS，索引式枚举拿到的东西支离破碎（设备扩展只剩
// 2 条）。Task192 实现的 6 个 buffer-DSA 函数从未被调用（无 "Task192
// dsa:" 日志）—— MC 在探测阶段就判了 not detected，非 DSA 回退路径上
// 又踩了 NULL 函数（黑屏，swap 58fps 但 readback rgba(0,0,0,0)）。
//
// 修法（三层）：
//   (1) 扩展表补全：glGetStringi + glGetIntegerv(GL_NUM_EXTENSIONS) 拦截
//       （真实列表 + 追加 GL_ARB_direct_state_access —— Task192 已实现
//       buffer-DSA 六函数 + 本轮 Map/VAO 族补齐）；glGetString(GL_EXTENSIONS)
//       同步追加（旧式枚举路径一致）。
//   (2) buffer-DSA Map/Storage 族：glMapNamedBuffer(Range)/glUnmapNamedBuffer/
//       glGetNamedBufferSubData/glNamedBufferStorage/glFlushMappedNamedBufferRange/
//       glClearNamedBufferSubData（GL_COPY_WRITE_BUFFER 换绑法，与 Task192 同构）。
//   (3) VAO-DSA 族：glCreateVertexArrays/glVertexArrayElementBuffer/
//       glVertexArrayVertexBuffer/glVertexArrayAttribFormat/
//       glVertexArrayAttribBinding/glEnableVertexArrayAttrib/
//       glDisableVertexArrayAttrib/glVertexArrayBindingDivisor（ELEMENT/
//       ARRAY/VERTEX_ARRAY 绑定保存恢复法）。MC 若走 VAO-DSA 也不再踩 NULL。
// 遗留观测：hooked_dlsym 的 [dlsym] Task193 GL NULL 日志将点名残余缺项。
//
// ============================================================================
// Task197 判决（装机复盘，详见 ame193_extraExts 定义处的取证注）：
// 上述第 (1) 层的 DSA 通告被【撤回】—— 26.3 装机实证 DSA 开启后
// DirectStateAccess.Core 每帧把附件/draw-buffers 操作打到默认帧缓冲
// （1547 × 1282 HIGH），渲染目标错位 → 真黑 + 有声音。扩展表补全
// （glGetStringi / GL_NUM_EXTENSIONS 拦截）保留；(2)(3) 层的 DSA 函数
// 实现保留（导出无害）。通告默认关闭，AME193_DSA_ADVERTISE=1 可复原。
// ============================================================================
#ifndef GL_NUM_EXTENSIONS
#define GL_NUM_EXTENSIONS 0x821D
#endif
#ifndef GL_MAP_READ_BIT
#define GL_MAP_READ_BIT 0x0001
#define GL_MAP_WRITE_BIT 0x0002
#define GL_MAP_INVALIDATE_RANGE_BIT 0x0004
#define GL_MAP_INVALIDATE_BUFFER_BIT 0x0008
#define GL_MAP_FLUSH_EXPLICIT_BIT 0x0010
#define GL_MAP_UNSYNCHRONIZED_BIT 0x0020
#endif
#ifndef GL_READ_ONLY
#define GL_READ_ONLY 0x88B8
#define GL_WRITE_ONLY 0x88B9
#define GL_READ_WRITE 0x88BA
#endif
#ifndef GL_VERTEX_ARRAY_BINDING
#define GL_VERTEX_ARRAY_BINDING 0x85B5
#endif
#ifndef GL_ARRAY_BUFFER_BINDING
#define GL_ARRAY_BUFFER_BINDING 0x8B8C
#endif
#ifndef GL_VERTEX_ATTRIB_ARRAY_ENABLED
#define GL_VERTEX_ATTRIB_ARRAY_ENABLED 0x8622
#endif
#ifndef GL_VERTEX_ATTRIB_ARRAY_POINTER
#define GL_VERTEX_ATTRIB_ARRAY_POINTER 0x8645
#endif
#ifndef GL_VERTEX_ATTRIB_ARRAY_DIVISOR
#define GL_VERTEX_ATTRIB_ARRAY_DIVISOR 0x88FE
#endif

// Task197（ANGLE 黑屏终局）：DSA 通告默认撤回 —— env 门控可复原。
// 装机铁证（latestlog.old.txt，26.3 + tinygl4angle 会话）：
//   00:52:08 "ARB_direct_state_access detected, enabling DSA"（GlDevice 构造期）
//   随后 1547 × "Only NONE or BACK are valid draw buffers for the default
//   framebuffer"（id=1282 HIGH）+ 2234 个 1282 总错 —— MC 走
//   DirectStateAccess.Core 后把附件/draw-buffers 操作打到默认帧缓冲，
//   渲染目标错位 → 真黑（中心像素 rgba(0,0,0,0)）但 swap 58fps + 有声音。
//   与 Task166 在 MobileGlues 上 A/B 实证的孪生根因（DSA 开=黑屏、关=可玩
//   且 FSR 生效）同源；上游 herbrine#143 同病未修。撤回通告后 MC 走
//   DirectStateAccess.Emulated 经典路径（bind-then-operate），Task193 的
//   扩展表补全保留 —— "DSA-off + 扩展缓存"组合此前从未装机测过
//   （Task193 当时同时改了两个变量）。Task192/193 已实现的 DSA 函数体
//   保留（导出无害，MC 不再主动探测调用）。
//   取证通道：AME193_DSA_ADVERTISE=1 可强制开回通告（诊断用，勿出厂）。
#define AME193_DSA_EXT "GL_ARB_direct_state_access"
static const char *const ame193_extraExts[] = {
    AME193_DSA_EXT,
};
#define AME193_EXTRA_EXT_COUNT (sizeof(ame193_extraExts) / sizeof(ame193_extraExts[0]))
// Task197：生效的追加扩展数（默认 0 = 撤回；env 门控可复原为全量）。
// 注意：两处消费点（索引式缓存 + 旧式字符串追加）都必须走本函数。
static size_t ame197_effectiveExtCount(void) {
    static int cached = -1;
    if (cached < 0) {
        const char *env = getenv("AME193_DSA_ADVERTISE");
        cached = (env != NULL && strcmp(env, "1") == 0) ? 1 : 0;
    }
    return (size_t)(cached ? AME193_EXTRA_EXT_COUNT : 0);
}
static char **ame193_extCache = NULL;   // 真实 + 追加 的完整扩展串列表
static GLuint ame193_extCount = 0;

static void ame193_buildExtCache(void) {
    if (ame193_extCache != NULL) return;
    typedef void (*ame193_fn_getIntegerv)(GLenum, GLint *);
    typedef const GLubyte *(*ame193_fn_getStringi)(GLenum, GLuint);
    static ame193_fn_getStringi ame193_real_getStringi = NULL;
    ame193_fn_getIntegerv ame193_getInt = NULL;
    if (ame192_ptr_glGetIntegerv != NULL) {
        ame193_getInt = ame192_ptr_glGetIntegerv;
    } else {
        ame192_resolve_buffer_helpers();
        ame193_getInt = ame192_ptr_glGetIntegerv;
    }
    AME173_RESOLVE(ame193_real_getStringi, "glGetStringi");
    if (ame193_getInt == NULL || ame193_real_getStringi == NULL) {
        printf("[tinygl4angle] Task193: ext cache build skipped (getIntegerv=%p getStringi=%p)\n",
              (void *)ame193_getInt, (void *)ame193_real_getStringi);
        return;
    }
    GLint n = 0;
    ame193_getInt(GL_NUM_EXTENSIONS, &n);
    if (n <= 0) {
        printf("[tinygl4angle] Task193: GL_NUM_EXTENSIONS=%d (driver reports none) -- indexed enumeration unavailable\n", (int)n);
        return;
    }
    char **cache = (char **)calloc((size_t)n + ame197_effectiveExtCount(), sizeof(char *));
    GLuint filled = 0;
    for (GLint i = 0; i < n; i++) {
        const GLubyte *s = ame193_real_getStringi(GL_EXTENSIONS, (GLuint)i);
        if (s == NULL) continue;
        cache[filled++] = strdup((const char *)s);
    }
    size_t ame197_append = ame197_effectiveExtCount();
    for (size_t k = 0; k < ame197_append; k++) {
        cache[filled++] = strdup(ame193_extraExts[k]);
    }
    ame193_extCache = cache;
    ame193_extCount = filled;
    if (ame197_append > 0) {
        printf("[tinygl4angle] Task193: extension cache built: %d real + %zu appended (GL_ARB_direct_state_access advertised; MC DSA probe should now SUCCEED)\n",
              (int)n, ame197_append);
    } else {
        printf("[tinygl4angle] Task197: DSA advertisement WITHDRAWN (extension cache keeps %d real entries; MC takes DirectStateAccess.Emulated classic path). Set AME193_DSA_ADVERTISE=1 to re-enable for forensics\n",
              (int)n);
    }
}

const GLubyte *glGetStringi(GLenum name, GLuint index) {
    // Task203：索引式枚举观察器（MC 的 caps 到底走不走这条路径）。
    {
        static int s_ame203_gsi = 0;
        if (s_ame203_gsi < 12) {
            s_ame203_gsi++;
            printf("[tinygl4angle] Task203 query: glGetStringi #%d name=0x%04X index=%u\n",
                   s_ame203_gsi, (unsigned)name, (unsigned)index);
        }
    }
    if (name == GL_EXTENSIONS) {
        ame193_buildExtCache();
        if (ame193_extCache != NULL) {
            if (index < ame193_extCount) return (const GLubyte *)ame193_extCache[index];
            return NULL;   // 越界：GL 语义 = NULL
        }
    }
    typedef const GLubyte *(*ame193_fn_getStringi)(GLenum, GLuint);
    static ame193_fn_getStringi ame193_real_getStringi = NULL;
    AME173_RESOLVE(ame193_real_getStringi, "glGetStringi");
    return ame193_real_getStringi ? ame193_real_getStringi(name, index) : NULL;
}

// glGetIntegerv 拦截：只为 GL_NUM_EXTENSIONS +1（其余原样转发）。
// 注意：tinygl4angle 此前不导出该符号（LWJGL 经依赖闭包直接拿 ANGLE 的），
// 现在由本 dylib 导出接管，全部 pname 语义不变。
typedef void (*ame193_fn_glGetIntegerv)(GLenum, GLint *);
static ame193_fn_glGetIntegerv ame193_ptr_glGetIntegerv;
void glGetIntegerv(GLenum pname, GLint *params) {
    // Task203：整数查询观察器（GL_NUM_EXTENSIONS 是否被 MC 问过；
    // 值在转发后可能被改写，这里只记 pname——名字即证据）。
    {
        static int s_ame203_gi = 0;
        if (s_ame203_gi < 12) {
            s_ame203_gi++;
            printf("[tinygl4angle] Task203 query: glGetIntegerv #%d pname=0x%04X\n",
                   s_ame203_gi, (unsigned)pname);
        }
    }
    if (pname == GL_NUM_EXTENSIONS && params != NULL) {
        ame193_buildExtCache();
        if (ame193_extCache != NULL) {
            *params = (GLint)ame193_extCount;
            return;
        }
    }
    AME173_RESOLVE(ame193_ptr_glGetIntegerv, "glGetIntegerv");
    if (ame193_ptr_glGetIntegerv) ame193_ptr_glGetIntegerv(pname, params);
}

// glGetString(GL_EXTENSIONS) 追加（旧式枚举路径与索引式同口径）。
static char *ame193_extStringCache = NULL;
static const GLubyte *ame193_appendExtString(const GLubyte *real) {
    if (real == NULL) return NULL;
    if (ame193_extStringCache != NULL) return (const GLubyte *)ame193_extStringCache;
    size_t len = strlen((const char *)real);
    size_t ame197_append = ame197_effectiveExtCount();
    size_t extra = 0;
    for (size_t k = 0; k < ame197_append; k++) extra += strlen(ame193_extraExts[k]) + 1;
    ame193_extStringCache = (char *)malloc(len + extra + 2);
    memcpy(ame193_extStringCache, real, len);
    char *w = ame193_extStringCache + len;
    for (size_t k = 0; k < ame197_append; k++) {
        *w++ = ' ';
        size_t l = strlen(ame193_extraExts[k]);
        memcpy(w, ame193_extraExts[k], l);
        w += l;
    }
    *w = '\0';
    if (ame197_append > 0) {
        printf("[tinygl4angle] Task193: GL_EXTENSIONS legacy string appended GL_ARB_direct_state_access (len %zu -> %zu)\n",
              len, (size_t)(w - ame193_extStringCache));
    } else {
        printf("[tinygl4angle] Task197: DSA advertisement WITHDRAWN on legacy GL_EXTENSIONS string too (len %zu unchanged)\n",
              len);
    }
    return (const GLubyte *)ame193_extStringCache;
}

// ---- buffer-DSA Map/Storage 族 ----
typedef void *(*ame193_fn_glMapBufferRange)(GLenum, GLintptr, GLsizeiptr, GLbitfield);
static ame193_fn_glMapBufferRange ame193_ptr_glMapBufferRange;
typedef GLboolean (*ame193_fn_glUnmapBuffer)(GLenum);
static ame193_fn_glUnmapBuffer ame193_ptr_glUnmapBuffer;
typedef void (*ame193_fn_glFlushMappedBufferRange)(GLenum, GLintptr, GLsizeiptr);
static ame193_fn_glFlushMappedBufferRange ame193_ptr_glFlushMappedBufferRange;

static GLbitfield ame193_translateMapAccess(GLenum access) {
    // DSA glMapNamedBuffer 的 access（READ_ONLY/WRITE_ONLY/READ_WRITE）
    // → ES3 glMapBufferRange 的 bit 组合
    if (access == 0x88B8 /* GL_READ_ONLY */) return GL_MAP_READ_BIT;
    if (access == 0x88B9 /* GL_WRITE_ONLY */) return GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT;
    return GL_MAP_READ_BIT | GL_MAP_WRITE_BIT;
}

void *glMapNamedBuffer(GLuint buffer, GLenum access) {
    ame192_resolve_buffer_helpers();
    AME173_RESOLVE(ame193_ptr_glMapBufferRange, "glMapBufferRange");
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame193_ptr_glMapBufferRange) return NULL;
    GLint prev = 0, size = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    // 查 buffer 大小（DSA 语义：size 省略 = 整个 buffer）
    typedef void (*ame193_fn_getBufParam)(GLenum, GLenum, GLint *);
    static ame193_fn_getBufParam ame193_ptr_getBufParam = NULL;
    AME173_RESOLVE(ame193_ptr_getBufParam, "glGetBufferParameteriv");
    if (ame193_ptr_getBufParam) ame193_ptr_getBufParam(GL_COPY_WRITE_BUFFER, 0x8764 /* GL_BUFFER_SIZE */, &size);
    void *p = ame193_ptr_glMapBufferRange(GL_COPY_WRITE_BUFFER, 0, (GLsizeiptr)size, ame193_translateMapAccess(access));
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
    return p;
}

void *glMapNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    ame192_resolve_buffer_helpers();
    AME173_RESOLVE(ame193_ptr_glMapBufferRange, "glMapBufferRange");
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame193_ptr_glMapBufferRange) return NULL;
    // PERSISTENT/COHERENT（桌面 4.4 buffer-storage 语义）在 ES3 上不可模拟，
    // 剥掉并以普通映射兜底（MC 非 buffer-storage 回退路径不会带这些位）。
    GLbitfield es3Access = access & 0x3F;
    if (access & ~0x3F) {
        static int s_ame193_persistWarn = 0;
        if (s_ame193_persistWarn < 4) {
            s_ame193_persistWarn++;
            printf("[tinygl4angle] Task193: glMapNamedBufferRange persistent/coherent bits stripped (0x%X -> 0x%X; ES3 emulation)\n",
                  (unsigned)access, (unsigned)es3Access);
        }
    }
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    void *p = ame193_ptr_glMapBufferRange(GL_COPY_WRITE_BUFFER, offset, length, es3Access);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
    return p;
}

GLboolean glUnmapNamedBuffer(GLuint buffer) {
    ame192_resolve_buffer_helpers();
    AME173_RESOLVE(ame193_ptr_glUnmapBuffer, "glUnmapBuffer");
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame193_ptr_glUnmapBuffer) return GL_FALSE;
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    GLboolean r = ame193_ptr_glUnmapBuffer(GL_COPY_WRITE_BUFFER);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
    return r;
}

void glFlushMappedNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length) {
    ame192_resolve_buffer_helpers();
    AME173_RESOLVE(ame193_ptr_glFlushMappedBufferRange, "glFlushMappedBufferRange");
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame193_ptr_glFlushMappedBufferRange) return;
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    ame193_ptr_glFlushMappedBufferRange(GL_COPY_WRITE_BUFFER, offset, length);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
}

void glGetNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, void *data) {
    // ES3 无 glGetBufferSubData（桌面独有）—— map+memcpy+unmap 模拟
    ame192_resolve_buffer_helpers();
    AME173_RESOLVE(ame193_ptr_glMapBufferRange, "glMapBufferRange");
    AME173_RESOLVE(ame193_ptr_glUnmapBuffer, "glUnmapBuffer");
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame193_ptr_glMapBufferRange) return;
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    void *p = ame193_ptr_glMapBufferRange(GL_COPY_WRITE_BUFFER, offset, size, GL_MAP_READ_BIT);
    if (p != NULL) {
        if (data != NULL) memcpy(data, p, (size_t)size);
        if (ame193_ptr_glUnmapBuffer) ame193_ptr_glUnmapBuffer(GL_COPY_WRITE_BUFFER);
    }
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
}

void glNamedBufferStorage(GLuint buffer, GLsizeiptr size, const void *data, GLbitfield flags) {
    // ES3 无不可变存储（desktop 4.4 / ES3.1 buffer_storage）——用
    // glNamedBufferData 语义兜底（可变但内容一致），flags 仅记录。
    static int s_ame193_storageWarn = 0;
    if (s_ame193_storageWarn < 4) {
        s_ame193_storageWarn++;
        printf("[tinygl4angle] Task193: glNamedBufferStorage(buf=%u size=%lld flags=0x%X) emulated via NamedBufferData (ES3 has no immutable storage)\n",
              (unsigned)buffer, (long long)size, (unsigned)flags);
    }
    glNamedBufferData(buffer, size, data, 0x88E4 /* GL_STATIC_DRAW */);
}

void glClearNamedBufferSubData(GLuint buffer, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void *data) {
    // map + 按字节清零 + unmap（internalformat 精确清零值语义简化为零填充）
    ame192_resolve_buffer_helpers();
    AME173_RESOLVE(ame193_ptr_glMapBufferRange, "glMapBufferRange");
    AME173_RESOLVE(ame193_ptr_glUnmapBuffer, "glUnmapBuffer");
    if (!ame192_ptr_glBindBuffer || !ame192_ptr_glGetIntegerv || !ame193_ptr_glMapBufferRange) return;
    GLint prev = 0;
    ame192_ptr_glGetIntegerv(GL_COPY_WRITE_BUFFER, &prev);
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, buffer);
    void *p = ame193_ptr_glMapBufferRange(GL_COPY_WRITE_BUFFER, offset, size, GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_RANGE_BIT);
    if (p != NULL) {
        memset(p, 0, (size_t)size);
        if (ame193_ptr_glUnmapBuffer) ame193_ptr_glUnmapBuffer(GL_COPY_WRITE_BUFFER);
    }
    ame192_ptr_glBindBuffer(GL_COPY_WRITE_BUFFER, (GLuint)prev);
}

// ---- VAO-DSA 族（绑定保存/恢复法）----
typedef void (*ame193_fn_glBindVertexArray)(GLuint);
static ame193_fn_glBindVertexArray ame193_ptr_glBindVertexArray;
typedef void (*ame193_fn_glGenVertexArrays)(GLsizei, GLuint *);
static ame193_fn_glGenVertexArrays ame193_ptr_glGenVertexArrays;
typedef void (*ame193_fn_glBindVertexBuffer)(GLuint, GLuint, GLintptr, GLsizei);
static ame193_fn_glBindVertexBuffer ame193_ptr_glBindVertexBuffer;
typedef void (*ame193_fn_glVertexAttribFormat)(GLuint, GLint, GLenum, GLboolean, GLuint);
static ame193_fn_glVertexAttribFormat ame193_ptr_glVertexAttribFormat;
typedef void (*ame193_fn_glVertexAttribBinding)(GLuint, GLuint);
static ame193_fn_glVertexAttribBinding ame193_ptr_glVertexAttribBinding;
typedef void (*ame193_fn_glEnableVertexAttribArray)(GLuint);
static ame193_fn_glEnableVertexAttribArray ame193_ptr_glEnableVertexAttribArray;
typedef void (*ame193_fn_glDisableVertexAttribArray)(GLuint);
static ame193_fn_glDisableVertexAttribArray ame193_ptr_glDisableVertexAttribArray;
typedef void (*ame193_fn_glVertexAttribDivisor)(GLuint, GLuint);
static ame193_fn_glVertexAttribDivisor ame193_ptr_glVertexAttribDivisor;

void glCreateVertexArrays(GLsizei n, GLuint *arrays) {
    AME173_RESOLVE(ame193_ptr_glGenVertexArrays, "glGenVertexArrays");
    if (ame193_ptr_glGenVertexArrays) ame193_ptr_glGenVertexArrays(n, arrays);
    static int s_ame193_vaoLogs = 0;
    if (s_ame193_vaoLogs < 4) {
        s_ame193_vaoLogs++;
        printf("[tinygl4angle] Task193 dsa: glCreateVertexArrays(n=%d) -> first=%u\n",
              (int)n, (n > 0 && arrays) ? (unsigned)arrays[0] : 0u);
    }
}

static GLuint ame193_saveVAO(void) {
    ame192_resolve_buffer_helpers();
    if (!ame192_ptr_glGetIntegerv) return 0;
    GLint vao = 0;
    ame192_ptr_glGetIntegerv(GL_VERTEX_ARRAY_BINDING, &vao);
    return (GLuint)vao;
}

void glVertexArrayElementBuffer(GLuint vaobj, GLuint buffer) {
    AME173_RESOLVE(ame193_ptr_glBindVertexArray, "glBindVertexArray");
    if (!ame193_ptr_glBindVertexArray) return;
    GLuint prev = ame193_saveVAO();
    ame193_ptr_glBindVertexArray(vaobj);
    ame192_resolve_buffer_helpers();
    if (ame192_ptr_glBindBuffer) ame192_ptr_glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, buffer);
    ame193_ptr_glBindVertexArray(prev);
}

void glVertexArrayVertexBuffer(GLuint vaobj, GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    AME173_RESOLVE(ame193_ptr_glBindVertexArray, "glBindVertexArray");
    AME173_RESOLVE(ame193_ptr_glBindVertexBuffer, "glBindVertexBuffer");
    if (!ame193_ptr_glBindVertexArray || !ame193_ptr_glBindVertexBuffer) return;
    GLuint prev = ame193_saveVAO();
    ame193_ptr_glBindVertexArray(vaobj);
    ame193_ptr_glBindVertexBuffer(bindingindex, buffer, offset, stride);
    ame193_ptr_glBindVertexArray(prev);
}

void glVertexArrayAttribFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset) {
    AME173_RESOLVE(ame193_ptr_glBindVertexArray, "glBindVertexArray");
    AME173_RESOLVE(ame193_ptr_glVertexAttribFormat, "glVertexAttribFormat");
    if (!ame193_ptr_glBindVertexArray || !ame193_ptr_glVertexAttribFormat) return;
    GLuint prev = ame193_saveVAO();
    ame193_ptr_glBindVertexArray(vaobj);
    ame193_ptr_glVertexAttribFormat(attribindex, size, type, normalized, relativeoffset);
    ame193_ptr_glBindVertexArray(prev);
}

void glVertexArrayAttribBinding(GLuint vaobj, GLuint attribindex, GLuint bindingindex) {
    AME173_RESOLVE(ame193_ptr_glBindVertexArray, "glBindVertexArray");
    AME173_RESOLVE(ame193_ptr_glVertexAttribBinding, "glVertexAttribBinding");
    if (!ame193_ptr_glBindVertexArray || !ame193_ptr_glVertexAttribBinding) return;
    GLuint prev = ame193_saveVAO();
    ame193_ptr_glBindVertexArray(vaobj);
    ame193_ptr_glVertexAttribBinding(attribindex, bindingindex);
    ame193_ptr_glBindVertexArray(prev);
}

void glEnableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    AME173_RESOLVE(ame193_ptr_glBindVertexArray, "glBindVertexArray");
    AME173_RESOLVE(ame193_ptr_glEnableVertexAttribArray, "glEnableVertexAttribArray");
    if (!ame193_ptr_glBindVertexArray || !ame193_ptr_glEnableVertexAttribArray) return;
    GLuint prev = ame193_saveVAO();
    ame193_ptr_glBindVertexArray(vaobj);
    ame193_ptr_glEnableVertexAttribArray(index);
    ame193_ptr_glBindVertexArray(prev);
}

void glDisableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    AME173_RESOLVE(ame193_ptr_glBindVertexArray, "glBindVertexArray");
    AME173_RESOLVE(ame193_ptr_glDisableVertexAttribArray, "glDisableVertexAttribArray");
    if (!ame193_ptr_glBindVertexArray || !ame193_ptr_glDisableVertexAttribArray) return;
    GLuint prev = ame193_saveVAO();
    ame193_ptr_glBindVertexArray(vaobj);
    ame193_ptr_glDisableVertexAttribArray(index);
    ame193_ptr_glBindVertexArray(prev);
}

void glVertexArrayBindingDivisor(GLuint vaobj, GLuint bindingindex, GLuint divisor) {
    AME173_RESOLVE(ame193_ptr_glBindVertexArray, "glBindVertexArray");
    AME173_RESOLVE(ame193_ptr_glVertexAttribDivisor, "glVertexAttribDivisor");
    if (!ame193_ptr_glBindVertexArray || !ame193_ptr_glVertexAttribDivisor) return;
    // 注意：divisor 是 per-attribute（ES3 glVertexAttribDivisor）而非
    // per-binding（桌面 glVertexArrayBindingDivisor）——对 bindingindex
    // 属性设置即近似（MC 的用法里两者一致）。
    GLuint prev = ame193_saveVAO();
    ame193_ptr_glBindVertexArray(vaobj);
    ame193_ptr_glVertexAttribDivisor(bindingindex, divisor);
    ame193_ptr_glBindVertexArray(prev);
}



typedef void (*ame173_fn_glCopyImageSubData)(GLuint, GLenum, GLint, GLint, GLint, GLint, GLuint, GLenum, GLint, GLint, GLint, GLint, GLsizei, GLsizei, GLsizei);
static ame173_fn_glCopyImageSubData ame173_ptr_glCopyImageSubData;
void glCopyImageSubData(GLuint srcName, GLenum srcTarget, GLint srcLevel, GLint srcX, GLint srcY, GLint srcZ,
                        GLuint dstName, GLenum dstTarget, GLint dstLevel, GLint dstX, GLint dstY, GLint dstZ,
                        GLsizei srcWidth, GLsizei srcHeight, GLsizei srcDepth) {
    AME173_RESOLVE(ame173_ptr_glCopyImageSubData, "glCopyImageSubData");
    if (ame173_ptr_glCopyImageSubData) {
        ame173_ptr_glCopyImageSubData(srcName, srcTarget, srcLevel, srcX, srcY, srcZ,
                                      dstName, dstTarget, dstLevel, dstX, dstY, dstZ,
                                      srcWidth, srcHeight, srcDepth);
    }
}

typedef void (*ame173_fn_glTexImage1D)(GLenum, GLint, GLint, GLsizei, GLint, GLenum, GLenum, const void *);
static ame173_fn_glTexImage1D ame173_ptr_glTexImage1D;
void glTexImage1D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLint border, GLenum format, GLenum type, const void *pixels) {
    AME173_RESOLVE(ame173_ptr_glTexImage1D, "glTexImage1D");
    if (ame173_ptr_glTexImage1D) {
        ame173_ptr_glTexImage1D(target, level, internalformat, width, border, format, type, pixels);
    }
    // 解析失败：静默丢弃（ES 无 1D 纹理；调用方拿到 GL_INVALID_ENUM 走降级）
}

// ---- 纯桌面语义无 ES 对应：安全 no-op + 一次性日志 ----
static void ame173_log_once(const char *fn) {
    static dispatch_once_t ame173_once_guard; // 简化：首个触发者带名记录
    dispatch_once(&ame173_once_guard, ^{
        printf("[TinyGL] Task173 desktop-only function with no ES equivalent no-op'd (first: %s)\n", fn);
    });
}

void glLogicOp(GLenum opcode) {
    // ES 无逻辑运算（GL_LOGIC_OP 桌面 1.0 特性）。MC 的 hurt-flash 等
    // 特效依赖 GL_LOGIC_OP 的路径在现代 MC 已退役，安全 no-op。
    ame173_log_once("glLogicOp");
}

void glIndexMask(GLuint mask) {
    ame173_log_once("glIndexMask");
}

/* ============================================================================
 * Task227：桌面 GLSL → GLSL ES 300 的 ivec 隐式转换修补。
 *
 * 病历（ef1e3e2a latestlog.old，ANGLE/tinygl4angle + 1.20.1）：
 *   ERROR: 1:15: '/' : wrong operand types ... 'in highp 2-component
 *   vector of int' ... 'const float' → clamp/texture/return 三连级联 →
 *   "Invalid shaders/core/rendertype_solid.json" → 启动崩溃。
 *   根源：vanilla light.glsl 的 `uv / 256.0`（ivec2/float）与 5 处
 *   `texCoord2 = UV2;`（ivec2→vec2 赋值）在桌面 GLSL 150 合法（隐式
 *   int→float），GLSL ES 300 一律禁止。Task219 只重写版本头，正文原样。
 *
 * 修法（正文级文本扫描，两形态 + 三重防御）：
 *   形态 A：`<ivec名> / <数字…>` 且除数字面量含 '.'（float）→ 包
 *          vec<D>(名)。除数为整数字面量（ivec/ivec 合法除法）不动。
 *   形态 B：`= <ivec名>;` 且语句回看窗口（上一个 ';'/'{'/'}' 起）不
 *          含 "ivec"（排除 ivec 左值）→ 包 vec<D>(名)。
 *   防御 1：只认全字匹配（前后都是非标识符字符）；
 *   防御 2：名字已处于 "vecD(" 之内（往前 6 字符内）不重复包；
 *   防御 3：任何失败路径返回 NULL，调用方退回原文（不扩大风险面）。
 * ==========================================================================*/
#define AME227_IVEC_MAX 64
#define AME227_IVEC_NAME_MAX 64

typedef struct {
    char name[AME227_IVEC_NAME_MAX];
    int dim;   /* 2/3/4 */
} ame227_ivec_decl;

static int ame227_isIdentChar(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
           (c >= '0' && c <= '9') || c == '_';
}

/* 收集 ivec2/3/4 声明的标识符：`in ivec2 UV2;`、`(sampler2D s, ivec2 uv)`、
 * `ivec2 local = ...` —— 统一模式 = "ivecD" 后跟空白 + 标识符。 */
static int ame227_collectIvecNames(const char *body, ame227_ivec_decl *out, int cap) {
    int n = 0;
    const char *p = body;
    while (*p != '\0' && n < cap) {
        if (p[0] == 'i' && p[1] == 'v' && p[2] == 'e' && p[3] == 'c' &&
            (p[4] == '2' || p[4] == '3' || p[4] == '4') &&
            !ame227_isIdentChar(p[5]) && (p == body || !ame227_isIdentChar(p[-1]))) {
            const char *q = p + 5;
            while (*q == ' ' || *q == '\t' || *q == '\n' || *q == '\r') q++;
            if (ame227_isIdentChar(*q) && !(*q >= '0' && *q <= '9')) {
                const char *s = q;
                while (ame227_isIdentChar(*q)) q++;
                size_t len = (size_t)(q - s);
                if (len > 0 && len < AME227_IVEC_NAME_MAX) {
                    /* 声明位（"ivecD 名"）后面必须是标点/空白——排除函数调用
                     * 形如 ivec2(...)（构造器）。 */
                    if (*q == '\0' || !ame227_isIdentChar(*q)) {
                        int dup = 0;
                        for (int i = 0; i < n; i++) {
                            if (strncmp(out[i].name, s, len) == 0 && out[i].name[len] == '\0') {
                                dup = 1; break;
                            }
                        }
                        if (!dup) {
                            memcpy(out[n].name, s, len);
                            out[n].name[len] = '\0';
                            out[n].dim = (p[4] - '0');
                            n++;
                        }
                    }
                }
            }
            p = q;
            continue;
        }
        p++;
    }
    return n;
}

/* 找 name 在 body 里的全字匹配出现（从 from 起），返回匹配起始指针或 NULL。 */
char *ame227_fixIvecConversions(const char *body) {
    if (body == NULL || body[0] == '\0') return NULL;

    ame227_ivec_decl decls[AME227_IVEC_MAX];
    int ndecl = ame227_collectIvecNames(body, decls, AME227_IVEC_MAX);
    if (ndecl == 0) return NULL;

    /* 输出缓冲：最坏情况 = 每个匹配点包一层 "vecD()" = +8 字节。粗估上界
     * 用 strlen*4 + 64 已远超实际（匹配点数量 << 长度）。 */
    size_t cap = strlen(body) * 4 + 64;
    char *out = (char *)malloc(cap);
    if (out == NULL) return NULL;
    size_t o = 0;
    const char *p = body;
    int wraps = 0;

    while (*p != '\0') {
        /* 逐位置尝试匹配任一 ivec 名（全字） */
        const char *hit = NULL;
        int hitIdx = -1;
        for (int i = 0; i < ndecl; i++) {
            size_t len = strlen(decls[i].name);
            if (strncmp(p, decls[i].name, len) == 0 &&
                (p == body || !ame227_isIdentChar(p[-1])) &&
                !ame227_isIdentChar(p[len])) {
                hit = p;
                hitIdx = i;
                break;
            }
        }
        if (hit == NULL) {
            out[o++] = *p++;
            continue;
        }

        size_t len = strlen(decls[hitIdx].name);
        const char *after = p + len;
        while (*after == ' ' || *after == '\t') after++;

        BOOL wrapped = NO;
        if (*after == '/') {
            /* 形态 A：`名 / <字面量>` —— 字面量须含 '.'（float） */
            const char *num = after + 1;
            while (*num == ' ' || *num == '\t') num++;
            const char *numEnd = num;
            while ((*numEnd >= '0' && *numEnd <= '9') || *numEnd == '.') numEnd++;
            if (numEnd > num && memchr(num, '.', (size_t)(numEnd - num)) != NULL) {
                wrapped = YES;
            }
        } else if (*after == ';') {
            /* 形态 B：`= 名;` —— 回看跳过空白后是 '='，且语句窗口无 ivec */
            const char *back = p;
            while (back > body && (back[-1] == ' ' || back[-1] == '\t')) back--;
            if (back > body && back[-1] == '=') {
                /* 语句窗口 = 上一个 ';'/'}'/'{' 到当前 */
                const char *stmtStart = back - 1;
                while (stmtStart > body && stmtStart[-1] != ';' && stmtStart[-1] != '}' &&
                       stmtStart[-1] != '{' && stmtStart[-1] != '\n') {
                    stmtStart--;
                }
                /* 排除已包裹：窗口尾若是 "vecD(" */
                const char *winEnd = back;
                size_t winLen = (size_t)(winEnd - stmtStart);
                const char *parenTail = (winLen >= 6) ? (winEnd - 6) : NULL;
                BOOL alreadyWrapped = (parenTail != NULL &&
                                       (strncmp(parenTail, "vec2(", 5) == 0 ||
                                        strncmp(parenTail, "vec3(", 5) == 0 ||
                                        strncmp(parenTail, "vec4(", 5) == 0));
                BOOL hasIvecLhs = (memchr(stmtStart, 'i', (size_t)(winEnd - stmtStart)) != NULL &&
                                   strstr(stmtStart, "ivec") != NULL &&
                                   strstr(stmtStart, "ivec") < winEnd);
                if (!alreadyWrapped && !hasIvecLhs) {
                    wrapped = YES;
                }
            }
        }

        if (wrapped) {
            o += (size_t)snprintf(out + o, cap - o, "vec%d(%.*s)", decls[hitIdx].dim,
                                  (int)len, p);
            wraps++;
        } else {
            memcpy(out + o, p, len);
            o += len;
        }
        p += len;
    }
    out[o] = '\0';

    if (wraps == 0) {
        free(out);
        return NULL;   /* 无需改动：调用方退回原文，零开销 */
    }
    printf("[tinygl4angle] Task227 ivec conversion pass: %d wrap(s), %d ivec name(s) tracked\n",
           wraps, ndecl);
    return out;
}


void glShaderSource(GLuint shader, GLsizei count, const GLchar * const *string, const GLint *length) {
    LOOKUP_FUNC(glShaderSource)

    // DBG(printf("glShaderSource(%d, %d, %p, %p)\n", shader, count, string, length);)
    char *source = NULL;
    char *converted;

    // Task181（ANGLE pipeline/gui "ERROR: 1:1: '' : syntax error" 取证）：
    // 反编译 26.3 client.jar 定案 MC 的上传形态 = GlStateManager.glShaderSource
    // （UTF-8 编码 + NUL 终止单段 + length=NULL → nglShaderSource）；spvc 出口
    // 已自证产出合法 "#version 300 es"（head48 日志），本地 harness（task179）
    // 也验证过 ES 直通可编译——中间必有一环没走通。本日志限 8 次，双重目的：
    // (a) 若日志出现 → tinygl4angle 的 glShaderSource 被 MC 命中，且能看到
    //     ANGLE 实收的源码头部（是否为 ES300/是否为空当场钉死）；
    // (b) 若崩溃复现而日志【不】出现 → MC 的 glShaderSource 解析到了本
    //     dylib 之外（Apple 系统 libGLESv2 或直连 ANGLE）——那才是断点。
    {
        static int s_ame181_srcLog = 0;
        if (s_ame181_srcLog < 8) {
            ++s_ame181_srcLog;
            size_t ame181_len0 = 0;
            if (string != NULL && count > 0 && string[0] != NULL) {
                ame181_len0 = (length != NULL && length[0] >= 0)
                    ? (size_t)length[0]
                    : strlen(string[0]);
            }
            const char *ame181_head = (string != NULL && count > 0 && string[0] != NULL) ? string[0] : "";
            printf("[tinygl4angle] Task181 glShaderSource #%d: shader=%u count=%d len0=%zu length=%s head48='%.48s'\n",
                   s_ame181_srcLog, shader, count, ame181_len0,
                   (length == NULL) ? "NULL" : "array", ame181_head);
        }
    }

    // Task209 (d)：地形族 ESSL 全文 dump——前两个含 sphericalVertexDistance
    // 的源（vanilla terrain 的 vert+frag 签名 varying）+ 前两个 >=3800 字节的
    // 大源（sodium block_layer frag 的量级），全文带 begin/end 标记。块名/
    // 采样器声明/精度/输出路径全可见——ES 重写若在结构上动了不该动的东西
    // （Task183 清洗器/精度限定/输出数组复制），此处一眼定谳。上限 4 次
    // 防刷屏；多段源只 dump 首段（MC 的上传形态 = 单段 NUL 终止）。
    {
        static int s_ame209_dumpN = 0;
        if (string != NULL && count > 0 && string[0] != NULL && s_ame209_dumpN < 4) {
            const char *ame209_src = string[0];
            size_t ame209_l0 = (length != NULL && length[0] >= 0)
                ? (size_t)length[0] : strlen(ame209_src);
            int ame209_isTerrain = (strstr(ame209_src, "sphericalVertexDistance") != NULL);
            int ame209_isBig = (ame209_l0 >= 3800);
            int ame209_do = 0;
            if (ame209_isTerrain) {
                static int s_ame209_terrainN = 0;
                if (s_ame209_terrainN < 2) { ++s_ame209_terrainN; ame209_do = 1; }
            } else if (ame209_isBig) {
                static int s_ame209_bigN = 0;
                if (s_ame209_bigN < 2) { ++s_ame209_bigN; ame209_do = 1; }
            }
            if (ame209_do) {
                ++s_ame209_dumpN;
                printf("[tinygl4angle] Task209 ESSL dump #%d begin (%s, len=%zu) >>>\n",
                       s_ame209_dumpN,
                       ame209_isTerrain ? "terrain-signature" : "large-source",
                       ame209_l0);
                fwrite(ame209_src, 1, ame209_l0, stdout);
                printf("\n[tinygl4angle] Task209 ESSL dump #%d end <<<\n", s_ame209_dumpN);
            }
        }
    }

    // get the size of the shader sources and than concatenate in a single string
    int l = 0;
    for (int i=0; i<count; i++) l+=(length && length[i] >= 0)?length[i]:strlen(string[i]);
    if (source) free(source);
    source = calloc(1, l+1);
    // Task183（A 族回归监测锚点）：桌面 GLSL（>=130 且非 es）到达本函数 =
    // spvc-shim 的 ES 重写漏网（59d4b48 病历：注册表 96 槽被 392 活 context
    // 打穿，584/782 静默拿到桌面源 -> ANGLE "ERROR: 0:1" -> 黑屏）。限频
    // 打点让下轮装机日志直接看到漏网量；spvc-shim 侧已配 Task183 跳过日志。
    {
        const char *ame183_h = (string != NULL && count > 0 && string[0] != NULL) ? string[0] : NULL;
        if (ame183_h != NULL && strncmp(ame183_h, "#version ", 9) == 0) {
            int ame183_isEs = (strncmp(&ame183_h[13], "es", 2) == 0);
            long ame183_ver = strtol(&ame183_h[9], NULL, 10);
            if (!ame183_isEs && ame183_ver >= 130) {
                static int s_ame183_desktopLeak = 0;
                ++s_ame183_desktopLeak;
                if (s_ame183_desktopLeak <= 4 || (s_ame183_desktopLeak % 64) == 0) {
                    printf("[tinygl4angle] Task183 DESKTOP source reached GLES upload "
                           "(spvc rewrite missed) #%d head48='%.48s'\n",
                           s_ame183_desktopLeak, ame183_h);
                }
            }
        }
    }
    if(length) {
        for (int i=0; i<count; i++) {
            if(length[i] >= 0)
                strncat(source, string[i], length[i]);
            else
                strcat(source, string[i]);
        }
    } else {
        for (int i=0; i<count; i++)
            strcat(source, string[i]);
    }
    
    char *source2 = strchr(source, '#');
    if (!source2) {
        source2 = source;
    }
    // are there #version?
    if (!strncmp(source2, "#version ", 9)) {
        if (!strncmp(&source2[13], "es", 2)) {
            // This is for gl4es. TODO: maybe remove 'es' aswell?
            // Task173 bug fix（潜伏雷）：旧代码在这里直接 return——shader 源码
            // 从未上传（gles_glShaderSource 没被调用），shader 保持未初始化
            // 源 → 编译出空程序 → 链接失败。ES 版本化着色器应原样上传。
            gles_glShaderSource(shader, 1, (const GLchar * const *)((source2) ? (&source2) : (&source)), NULL);
            free(source);
            return;
        }
        // Task219（用户报“ANGLE 在非 26.3 版本黑屏闪退”，6cd2cbfb latestlog.txt
        // 判读：MC 26.2 FO 会话全部 pipeline 报 "ERROR: 0:1: '' : invalid version
        // directive"， fatal trace 为黑屏后手动强关）：26.3 的着色器走
        // GlslCompiler.compileToSpv → shaderc → SPIRV → spirv-cross 链，
        // ES300 重写在 spvc_shim（Task175/176）里做，送达本函数时已是
        // "#version 300 es"；而 ≤26.2 的 GlProgram 直传路径【完全绕开】
        // spvc——桌面 "#version 330" 原样到达，下面的旧转换只处理 1xx
        // 版本号（converted[9]=='1'），330 头原样上传给 ES3 上下文 = 版本
        // 指令非法 → 全部管线编译失败 → 黑屏。修法：对 >=130 的桌面源做
        // 与 ame176_textual_es_rewrite 同构的头重写（版本行 → "#version 300
        // es" + ES 必需 precision 声明组——该精度组在 26.3 会话经 spvc 链
        // 已装机验证），随后直接上传（等效 ES 早退分支，跳过下方 gl4es
        // 时代的 outColor0/gl_FragData 与扩展注入——那套是桌面 facade
        // 时代的遗产，对 ESSL300 源反而是噪声）。
        {
            long ame219_ver = strtol(&source2[9], NULL, 10);
            if (ame219_ver >= 130) {
                // ★ Task223（用户报“ANGLE 在非 SDL 版本报错”，2832c2b latestlog.old.txt
                // 判读：FO 26.2 会话 141 个着色器全部死在 ERROR 0:14 'image2D' :
                // Illegal use of reserved word——第 14 行正是本头部自己插入的
                // "precision highp image2D;"。GLSL ES 3.00 里 image2D 是保留字、
                // 不能出现在 precision 声明里（image 类型需要 ES 3.10+），而
                // MC 26.2 着色器本体其实不用 image2D（错误计数 141 全部落在我
                // 们的头部行，无一处 body 报错）。修法：三行 image precision
                // 从头部移除。若未来出现真正使用 image2D 的源（ES3.10 特性），
                // 再按需升 310 es + 探测 GL_ES_VERSION_3_1。）
                static const char *const kAme219EsHead =
                    "#version 300 es\n"
                    "precision highp float;\n"
                    "precision highp int;\n"
                    "precision highp sampler2D;\n"
                    "precision highp sampler3D;\n"
                    "precision highp samplerCube;\n"
                    "precision highp sampler2DShadow;\n"
                    "precision highp samplerCubeShadow;\n"
                    "precision highp sampler2DArray;\n"
                    "precision highp isampler2D;\n"
                    "precision highp usampler2D;\n"
                    "precision highp isampler3D;\n"
                    "precision highp usampler3D;\n";
                const char *ame219_eol = strchr(source2, '\n');
                if (ame219_eol != NULL) {
                    size_t ame219_headLen = strlen(kAme219EsHead);
                    size_t ame219_restLen = strlen(ame219_eol + 1);
                    /* ★ Task227（反馈 #1：ANGLE 非 SDL 版本 1.20.1 启动即崩）：
                     * 病历（ef1e3e2a latestlog.old:1050-1070）：vanilla 1.20.1 的
                     * light.glsl:16 `clamp(uv / 256.0, ...)` —— ivec2 / float 在
                     * 桌面 GLSL 150 合法（隐式 int→float），GLSL ES 300 禁止。
                     * Task219 头重写只换版本行，正文原样上传 → ANGLE ES 编译器
                     * 在 '1:15' 报 '/' 错误 → clamp/texture/return 三连级联 →
                     * "Invalid shaders/core/rendertype_solid.json" → 崩溃对话框。
                     * 修法：正文级扫描——收集 ivec2/3/4 声明的标识符，对
                     * ① `<ivec> / <float 字面量>`（除数含 '.'）包 vec<D>(…)
                     * ② `= <ivec>;`（语句回看无 ivec 左值）包 vec<D>(…)
                     * 两形态补显式转换。vanilla 全量核对：唯一违规点就是
                     * light.glsl 的 uv/256.0 与 5 处 `texCoord2 = UV2;`。 */
                    char *ame227_body = ame227_fixIvecConversions(ame219_eol + 1);
                    const char *ame227_bodySrc = (ame227_body != NULL) ? ame227_body : (ame219_eol + 1);
                    size_t ame227_bodyLen = strlen(ame227_bodySrc);
                    char *ame219_es = (char *)malloc(ame219_headLen + ame227_bodyLen + 1);
                    if (ame219_es != NULL) {
                        memcpy(ame219_es, kAme219EsHead, ame219_headLen);
                        memcpy(ame219_es + ame219_headLen, ame227_bodySrc, ame227_bodyLen);
                        ame219_es[ame219_headLen + ame227_bodyLen] = '\0';
                    }
                    free(ame227_body);
                    if (ame219_es != NULL) {
                        {
                            static int s_ame219_rewriteN = 0;
                            ++s_ame219_rewriteN;
                            if (s_ame219_rewriteN <= 4 || (s_ame219_rewriteN % 64) == 0) {
                                printf("[tinygl4angle] Task219 desktop->ES300 head rewrite #%d (was #version %ld, len=%zu)\n",
                                       s_ame219_rewriteN, ame219_ver, ame219_headLen + ame227_bodyLen);
                            }
                        }
                        gles_glShaderSource(shader, 1, (const GLchar * const *)(&ame219_es), NULL);
                        free(ame219_es);
                        free(source);
                        return;
                    }
                    // malloc 失败：跌回下方旧路径（保持旧风险面，不扩大）。
                }
            }
        }
        converted = strdup(source2);
        if (converted[9] == '1') {
            if (converted[10] - '0' < 2) {
                // 100, 110 -> 120
                //converted[10] = '2';
            } else if (converted[10] - '0' < 6) {
                // 130, 140, 150 -> 330
                converted[9] = converted[10] = '3';
            }
        }
        // remove "core", is it safe?
        if (!strncmp(&converted[13], "core", 4)) {
            strncpy(&converted[13], "\n//c", 4);
        }
    } else {
        converted = calloc(1, strlen(source) + 13);
        strcpy(converted, "#version 120\n");
        strcpy(&converted[13], strdup(source));
    }

    int convertedLen = strlen(converted);

#ifdef __APPLE__
    // patch OptiFine 1.17.x
    if (FindString(converted, "\nuniform mat4 textureMatrix = mat4(1.0);")) {
        InplaceReplace(converted, &convertedLen, "\nuniform mat4 textureMatrix = mat4(1.0);", "\n#define textureMatrix mat4(1.0)");
    }
#endif

    // Workaround unassigned outputs: use gl_FragData[] instead of separate color outputs
    char tmpOutFindLine[20];
    char tmpOutReplaceLine[33];
    strncpy(tmpOutFindLine, "out vec4 outColor0;", 20);
    strncpy(tmpOutReplaceLine, "#define outColor0 gl_FragData[0]", 33);
    for (int i = 0; i < 8; i++) {
        tmpOutFindLine[17] = '0'+i;
        if (FindString(converted, tmpOutFindLine)) {
            tmpOutReplaceLine[16] = '0'+i;
            tmpOutReplaceLine[30] = '0'+i;
            converted = InplaceReplace(converted, &convertedLen, tmpOutFindLine, tmpOutReplaceLine);
        }
    }

    // some needed exts
    const char* extensions =
        "#extension GL_EXT_blend_func_extended : enable\n"
        "#extension GL_EXT_draw_buffers : enable\n"
        // For OptiFine (see patch above)
        "#extension GL_EXT_shader_non_constant_global_initializers : enable\n";
    converted = InplaceInsert(GetLine(converted, 1), extensions, converted, &convertedLen);

    //printf("[tinygl4angle] glShaderSource: %s\n", converted);

    gles_glShaderSource(shader, 1, (const GLchar * const*)((converted)?(&converted):(&source)), NULL);

    free(source);
    free(converted);
}

// Task181（ANGLE 编译链取证，与上面 glShaderSource 取证同轮）：
// 本 dylib 之前不导出 glCompileShader/glCreateShader（直接走 ANGLE 原生）。
// 新增【纯转发】导出：行为不变（转发到 LOOKUP_FUNC 解析出的同一 ANGLE
// 函数），但让"MC 的编译调用是否/以何参数命中本 dylib"变得可观测——
// 每次编译后查一次 COMPILE_STATUS（35713），失败时打 infoLog 头 64 字节。
// 若装机日志里这些行【不】出现而崩溃复现 → MC 的编译链解析在本 dylib 之外。
void(*gles_glCompileShader)(GLuint shader);
void(*gles_glGetShaderiv)(GLuint shader, GLenum pname, GLint *params);
void(*gles_glGetShaderInfoLog)(GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *infoLog);
void glCompileShader(GLuint shader) {
    LOOKUP_FUNC(glCompileShader)
    if (gles_glCompileShader) {
        gles_glCompileShader(shader);
    }
    {
        static int s_ame181_compLog = 0;
        if (s_ame181_compLog < 32) {
            ++s_ame181_compLog;
            // Task182：查询函数改走 ame182_resolve 钉死链（旧版裸
            // RTLD_NEXT 落到系统副本 → status/log 读错对象，与编译器
            // 不同库，status=0+空 log 的另一半成因）。
            if (gles_glGetShaderiv == NULL) { gles_glGetShaderiv = ame182_resolve("glGetShaderiv"); }
            GLint ame181_status = 0;
            if (gles_glGetShaderiv != NULL) {
                gles_glGetShaderiv(shader, 35713 /* GL_COMPILE_STATUS */, &ame181_status);
                if (ame181_status == 0) {
                    if (gles_glGetShaderInfoLog == NULL) { gles_glGetShaderInfoLog = ame182_resolve("glGetShaderInfoLog"); }
                    char ame181_log[160];
                    GLsizei ame181_logLen = 0;
                    ame181_log[0] = '\0';
                    if (gles_glGetShaderInfoLog != NULL) {
                        gles_glGetShaderInfoLog(shader, sizeof(ame181_log) - 1, &ame181_logLen, ame181_log);
                        ame181_log[ame181_logLen > 0 && ame181_logLen < (GLsizei)sizeof(ame181_log) - 1 ? ame181_logLen : (GLsizei)sizeof(ame181_log) - 1] = '\0';
                    }
                    printf("[tinygl4angle] Task181 glCompileShader #%d: shader=%u COMPILE_STATUS=0 logHead='%s'\n",
                           s_ame181_compLog, shader, ame181_log);
                } else {
                    printf("[tinygl4angle] Task181 glCompileShader #%d: shader=%u COMPILE_STATUS=1 (ok)\n",
                           s_ame181_compLog, shader);
                }
            }
        }
    }
}

// Task182：补导出 shader 对象生命周期入口（纯转发，与 glCompileShader 同款
// LOOKUP_FUNC 钉死链）。理由：MC 的符号解析走 dlsym(本 dylib handle) 的
// 导出闭包（自身 + 依赖树）——glCreateShader 不在本 dylib 导出面时，它沿
// 依赖树落到的库与本 dylib gles_ 解析链命中的库【不保证同一份】（真机
// 实测即分裂：create 在 Frameworks 副本、upload/compile 在系统副本，
// 两轮装机的 "ERROR: 1:1" 空源码与 "status=0 空 log" 两种形态全由此出）。
// 现在把 create/delete 也拉进本 dylib 的同一解析链：MC 全部 shader 族
// 调用（create→source→compile→query→delete）汇聚到同一份 ANGLE，
// 命名空间彻底闭合。转发本身零语义变化（同一函数，多一层中转）。
GLuint(*gles_glCreateShader)(GLenum type);
void(*gles_glDeleteShader)(GLuint shader);
GLuint glCreateShader(GLenum type) {
    LOOKUP_FUNC(glCreateShader)
    if (gles_glCreateShader) {
        GLuint ame182_id = gles_glCreateShader(type);
        static int s_ame182_createLogs = 0;
        if (s_ame182_createLogs < 4) {
            s_ame182_createLogs++;
            printf("[tinygl4angle] Task182 glCreateShader(type=%u) -> %u (namespace joined: create/source/compile/query now share one ANGLE)\n",
                   (unsigned)type, (unsigned)ame182_id);
        }
        return ame182_id;
    }
    return 0;
}
void glDeleteShader(GLuint shader) {
    LOOKUP_FUNC(glDeleteShader)
    if (gles_glDeleteShader) {
        gles_glDeleteShader(shader);
    }
}

// ============================================================================
// Task186: glUniformMatrix*fv transpose 转置桥（ANGLE 黑屏·内容层头号嫌疑
// 根修 + 取证锚点）。病历（11e4b63 装机 c689d41 latestlog.txt，ANGLE 26.3
// FO 会话）：呈现层全绿（fps=60 swapOK=372、遮罩按 first-swap 移除、音频/
// 输入/主菜单音效俱全、Task183 后无 "Couldn't compile ... for pipeline"
// 刷屏）但屏幕全黑 = MC 画了黑内容。desktop GL 3.3 的 glUniformMatrix*fv
// 允许 transpose=GL_TRUE（行主序输入），ESSL（300/320）强制 transpose=
// GL_FALSE：违反 = GL_INVALID_VALUE 且【调用被整体丢弃】——一旦 MC 某条
// 路径传 TRUE，矩阵 uniform 全灭 → 所有顶点退化为零向量 → 几何全剔除 →
// 只剩 clearColor = 游戏跑着但全黑，与本轮症状逐点吻合。本 dylib 此前
// 不导出矩阵族：MC 的调用沿依赖树直落 ANGLE 原生（ES 语义，无人在场
// 转置）。修法：九函数全族包装——transpose=FALSE 纯转发（零回归）；
// TRUE 时本地转置（行主序→列主序）后以 FALSE 转发（单矩阵 ≤16 float
// 走栈缓冲，热路径零 malloc）；首次 TRUE 打锚点日志（取证修复合一：
// 若装机日志无此行且黑屏仍在，本嫌疑即排除，排查转向 depth/blend 态）。
// GL 语义：glUniformMatrix{cols}x{rows}fv，FALSE=列主序 out[col*rows+row]，
// TRUE=行主序 in[row*cols+col]；转置即 out[col*rows+row]=in[row*cols+col]。
// ============================================================================
static int ame186_transposeLogged = 0;
#define AME186_MATRIX_FN(FN, COLS, ROWS) \
void (*gles_##FN)(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value); \
void FN(GLint location, GLsizei count, GLboolean transpose, const GLfloat *value) { \
    /* Task203：矩阵调用计数观察器（黑屏定谳仪表，printf 版）*/ \
    static unsigned s_ame203_mfn = 0; \
    if (s_ame203_mfn <= 8) { \
        ++s_ame203_mfn; \
        printf("[tinygl4angle] Task203 uniform: %s #%u loc=%d count=%d transpose=%d\n", \
               #FN, s_ame203_mfn, (int)location, (int)count, (int)transpose); \
    } \
    LOOKUP_FUNC(FN) \
    if (!gles_##FN) return; \
    if (transpose == GL_FALSE || value == NULL || count <= 0) { \
        gles_##FN(location, count, transpose, value); \
        return; \
    } \
    const GLsizei ame186_n = (COLS) * (ROWS); \
    GLfloat ame186_stack[16]; \
    GLfloat *ame186_buf = ame186_stack; \
    int ame186_heap = 0; \
    if ((size_t)count * (size_t)ame186_n > 16) { \
        ame186_buf = (GLfloat *)malloc(((size_t)count * (size_t)ame186_n) * sizeof(GLfloat)); \
        if (ame186_buf == NULL) { \
            gles_##FN(location, count, transpose, value); \
            return; \
        } \
        ame186_heap = 1; \
    } \
    for (GLsizei ame186_m = 0; ame186_m < count; ++ame186_m) { \
        const GLfloat *ame186_src = value + (size_t)ame186_m * (size_t)ame186_n; \
        GLfloat *ame186_dst = ame186_buf + (size_t)ame186_m * (size_t)ame186_n; \
        for (int ame186_c = 0; ame186_c < (COLS); ++ame186_c) { \
            for (int ame186_r = 0; ame186_r < (ROWS); ++ame186_r) { \
                ame186_dst[ame186_c * (ROWS) + ame186_r] = ame186_src[ame186_r * (COLS) + ame186_c]; \
            } \
        } \
    } \
    if (ame186_transposeLogged < 4) { \
        ++ame186_transposeLogged; \
        printf("[tinygl4angle] Task186 %s transpose=TRUE -> locally transposed %dx%d x%ld matrix/matrices (ES requires column-major; dropped call was the black-content suspect)\n", \
               #FN, (COLS), (ROWS), (long)count); \
    } \
    gles_##FN(location, count, GL_FALSE, ame186_buf); \
    if (ame186_heap) free(ame186_buf); \
}
AME186_MATRIX_FN(glUniformMatrix2fv, 2, 2)
AME186_MATRIX_FN(glUniformMatrix3fv, 3, 3)
AME186_MATRIX_FN(glUniformMatrix4fv, 4, 4)
AME186_MATRIX_FN(glUniformMatrix2x3fv, 2, 3)
AME186_MATRIX_FN(glUniformMatrix3x2fv, 3, 2)
AME186_MATRIX_FN(glUniformMatrix2x4fv, 2, 4)
AME186_MATRIX_FN(glUniformMatrix4x2fv, 4, 2)
AME186_MATRIX_FN(glUniformMatrix3x4fv, 3, 4)
AME186_MATRIX_FN(glUniformMatrix4x3fv, 4, 3)

int isProxyTexture(GLenum target) {
    switch (target) {
        case GL_PROXY_TEXTURE_1D:
        case GL_PROXY_TEXTURE_2D:
        case GL_PROXY_TEXTURE_3D:
        case GL_PROXY_TEXTURE_RECTANGLE_ARB:
            return 1;
    }
    return 0;
}

static int inline nlevel(int size, int level) {
    if(size) {
        size>>=level;
        if(!size) size=1;
    }
    return size;
}

void glGetTexLevelParameteriv(GLenum target, GLint level, GLenum pname, GLint *params) {
    LOOKUP_FUNC(glGetTexLevelParameteriv)
    // NSLog("glGetTexLevelParameteriv(%x, %d, %x, %p)", target, level, pname, params);
    if (isProxyTexture(target)) {
        switch (pname) {
            case GL_TEXTURE_WIDTH:
                (*params) = nlevel(proxy_width,level);
                break;
            case GL_TEXTURE_HEIGHT: 
                (*params) = nlevel(proxy_height,level);
                break;
            case GL_TEXTURE_INTERNAL_FORMAT:
                (*params) = proxy_intformat;
                break;
        }
    } else {
        gles_glGetTexLevelParameteriv(target, level, pname, params);
    }
}

void glTexImage2D(GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const GLvoid *data) {
    LOOKUP_FUNC(glTexImage2D)

    // Task209 (c)：纹理上传格式法证（首 24 次 + 每次 >=1M 像素 + 每 4096
    // 次——图集/光照图的 internalFormat/format/type/尺寸与 data 空否全
    // 记录；方块透明若源于图集 alpha 通道异常将在此现形）。
    {
        static unsigned s_ame209_texi = 0;
        unsigned ame209_px = (unsigned)width * (unsigned)height;
        ++s_ame209_texi;
        if (s_ame209_texi <= 24 || ame209_px >= 1000000u || (s_ame209_texi % 4096) == 0) {
            printf("[tinygl4angle] Task209 tex: glTexImage2D #%u target=0x%04X level=%d ifmt=0x%04X fmt=0x%04X type=0x%04X %dx%d data=%s\n",
                   s_ame209_texi, (unsigned)target, (int)level, (unsigned)internalformat,
                   (unsigned)format, (unsigned)type, (int)width, (int)height,
                   (data == NULL) ? "NULL" : "ptr");
        }
    }

    if (type == GL_UNSIGNED_INT_8_8_8_8_REV) {
        type = GL_UNSIGNED_BYTE;
    }

    // Task224：非 sized 深度内部格式 → ES3 sized 等价物（ANGLE 必须）。
    // 按 type 语义映射：FLOAT→32F、UNSIGNED_INT→24、其余→16；
    // DEPTH_STENCIL 组合 → DEPTH24_STENCIL8。format 不动（ES3 的
    // glTexImage2D format 仍接受 GL_DEPTH_COMPONENT）。
    if (internalformat == GL_DEPTH_COMPONENT) {
        if (type == GL_FLOAT) {
            internalformat = GL_DEPTH_COMPONENT32F;
        } else if (type == GL_UNSIGNED_INT) {
            internalformat = GL_DEPTH_COMPONENT24;
        } else {
            internalformat = GL_DEPTH_COMPONENT16;
        }
    } else if (internalformat == GL_DEPTH_STENCIL) {
        internalformat = GL_DEPTH24_STENCIL8;
    }

    if (isProxyTexture(target)) {
        if (!maxTextureSize) {
            glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTextureSize);
            // maxTextureSize = 16384;
            // printf("Maximum texture size: %d\n", maxTextureSize);
        }
        proxy_width = ((width<<level)>maxTextureSize)?0:width;
        proxy_height = ((height<<level)>maxTextureSize)?0:height;
        proxy_intformat = internalformat;
        // swizzle_internalformat((GLenum *) &internalformat, format, type);
    } else {
        gles_glTexImage2D(target, level, internalformat, width, height, border, format, type, data);
    }
}


void glTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const GLvoid *data) {
    LOOKUP_FUNC(glTexSubImage2D)
    // Task209 (c)：子图集上传同格式取证（图集拼接的主要路径）。
    {
        static unsigned s_ame209_subi = 0;
        unsigned ame209_px = (unsigned)width * (unsigned)height;
        ++s_ame209_subi;
        if (s_ame209_subi <= 24 || ame209_px >= 1000000u || (s_ame209_subi % 4096) == 0) {
            printf("[tinygl4angle] Task209 tex: glTexSubImage2D #%u target=0x%04X level=%d fmt=0x%04X type=0x%04X %dx%d at(%d,%d) data=%s\n",
                   s_ame209_subi, (unsigned)target, (int)level, (unsigned)format,
                   (unsigned)type, (int)width, (int)height, (int)xoffset, (int)yoffset,
                   (data == NULL) ? "NULL" : "ptr");
        }
    }
    if (type == GL_UNSIGNED_INT_8_8_8_8_REV) {
        type = GL_UNSIGNED_BYTE;
    }
    gles_glTexSubImage2D(target, level, xoffset, yoffset, width, height, format, type, data);
}


void glTexParameterfv(GLenum target, GLenum pname, const GLfloat *params) {
    LOOKUP_FUNC(glTexParameterfv)
    if (pname != GL_TEXTURE_LOD_BIAS) {
        gles_glTexParameterfv(target, pname, params);
    }
}
void glTexParameterf(GLenum target, GLenum pname, GLfloat param) {
    glTexParameterfv(target, pname, &param);
}

// Handle reading depth buffer
void glReadBuffer(GLenum mode) {
    // Override with stub
}

void glCopyTexSubImage2D(GLenum target, GLint level, GLint xoffset, GLint yoffset, GLint x, GLint y, GLsizei width, GLsizei height) {
    if (target != GL_TEXTURE_2D) {
        LOOKUP_FUNC(glCopyTexSubImage2D)
        gles_glCopyTexSubImage2D(target, level, xoffset, yoffset, x, y, width, height);
    }

    // Override with stub
#if 0
    float *pixels = malloc(width*height*sizeof(float));
    for (int i = 0; i < width*height; i++) {
        pixels[i] = 0.5f;
    }
    glTexSubImage2D(target, level, xoffset, yoffset, width, height, GL_DEPTH_COMPONENT, GL_FLOAT, pixels);
    free(pixels);
#endif

#if 0
    static GLuint depthFB;
    if (!depthFB) {
        glGenFramebuffers(1, &depthFB);
    }
    int fbID, texID;
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING, &fbID);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &texID);
    //glBindFramebuffer(GL_READ_FRAMEBUFFER, 0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, depthFB);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, target, texID, level);
    assert(glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE);
    glBlitFramebuffer(xoffset, yoffset, width, height, x, y, width, height, GL_DEPTH_BUFFER_BIT, GL_NEAREST);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, target, 0, level);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbID);
#endif
}

// VertexArray stuff
#define THUNK(suffix, type, M2) \
void  glVertexAttrib1##suffix (GLuint index, type v0) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib2##suffix (GLuint index, type v0, type v1) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; f[1]=v1; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib3##suffix (GLuint index, type v0, type v1, type v2) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; f[1]=v1; f[2]=v2; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib4##suffix (GLuint index, type v0, type v1, type v2, type v3) { GLfloat f[4] = {0,0,0,1}; f[0] =v0; f[1]=v1; f[2]=v2; f[3]=v3; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib1##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib2##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib3##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; f[2]=v[2]; glVertexAttrib4fv(index, f); };
THUNK(s, GLshort, );
THUNK(d, GLdouble, _D);
#undef THUNK
void  glVertexAttrib4dv (GLuint index, const GLdouble *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; f[2]=v[2]; f[3]=v[3]; glVertexAttrib4fv(index, f); };

#define THUNK(suffix, type, norm) \
void  glVertexAttrib4##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]; f[1]=v[1]; f[2]=v[2]; f[3]=v[3]; glVertexAttrib4fv(index, f); }; \
void  glVertexAttrib4N##suffix##v (GLuint index, const type *v) { GLfloat f[4] = {0,0,0,1}; f[0] =v[0]/norm; f[1]=v[1]/norm; f[2]=v[2]/norm; f[3]=v[3]/norm; glVertexAttrib4fv(index, f); };
THUNK(b, GLbyte, 127.0f);
THUNK(ub, GLubyte, 255.0f);
THUNK(s, GLshort, 32767.0f);
THUNK(us, GLushort, 65535.0f);
THUNK(i, GLint, 2147483647.0f);
THUNK(ui, GLuint, 4294967295.0f);
#undef THUNK
void glVertexAttrib4Nub(GLuint index, GLubyte v0, GLubyte v1, GLubyte v2, GLubyte v3) {GLfloat f[4] = {0,0,0,1}; f[0] =v0/255.f; f[1]=v1/255.f; f[2]=v2/255.f; f[3]=v3/255.f; glVertexAttrib4fv(index, f); };
