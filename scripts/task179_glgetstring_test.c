/* Task179: E2E test of glGetString with the spoof + normalization chain.
   The fake dlsym returns canned strings per query name; verify the final
   strings match the facade-session forms byte-for-byte. */
#include <stdio.h>
#include <string.h>
#include "task179_inc/Foundation/Foundation.h"
#include "task179_inc/GL/gl.h"
#include "task179_inc/ame179_prod_marker.h"

/* canned responses fed through ame173_real_glGetString */
static const char *g_ver_es = "OpenGL ES 3.2.0 (ANGLE 2.1.2440 git hash: 6024e9c05548)";
static const char *g_glsl_es = "OpenGL ES GLSL ES 3.20 (ANGLE 2.1.2440 git hash: 6024e9c05548)";
static const char *g_renderer = "ANGLE (Apple, ANGLE Metal Renderer: Apple M4 GPU)";
static const char *g_vendor = "Google Inc. (Apple)";

static const GLubyte *fake_glGetString_impl(GLenum name) {
    if (name == GL_VERSION) return (const GLubyte *)g_ver_es;
    if (name == GL_SHADING_LANGUAGE_VERSION) return (const GLubyte *)g_glsl_es;
    if (name == GL_RENDERER) return (const GLubyte *)g_renderer;
    if (name == GL_VENDOR) return (const GLubyte *)g_vendor;
    return (const GLubyte *)"";
}
static void *fake_dlsym(void *h, const char *n) {
    if (strcmp(n, "glGetString") == 0) return (void *)&fake_glGetString_impl;
    return NULL;
}
void *dlsym(void *handle, const char *name) { return fake_dlsym(handle, name); }
void *eglGetProcAddress(const char *p) { (void)p; return NULL; }
#define GL_GLEXT_PROTOTYPES
#include "task179_inc/tinygl4angle_harness.c"

/* stubs */
void glClearDepthf(float d) { (void)d; }
void glDepthRangef(float n, float f) { (void)n; (void)f; }
void glGetFloatv(GLenum p, GLfloat *v) { (void)p; (void)v; }
void glGetBooleanv(GLenum p, GLboolean *v) { (void)p; (void)v; }
/* Task220 剔重守卫：生产镜像（task179_inc/tinygl4angle_harness.c）自带
 * Task203 空安全包装器时（AME179_PROD_GL_STUBS），停用本驱动桩，
 * 语义等价（未解析指针 = no-op，同旧桩）。 */
#ifndef AME179_PROD_GL_STUBS
void glDrawElements(GLenum m, GLsizei c, GLenum t, const void *i) { (void)m;(void)c;(void)t;(void)i; }
void glDrawElementsInstanced(GLenum m, GLsizei c, GLenum t, const void *i, GLsizei p) { (void)m;(void)c;(void)t;(void)i;(void)p; }
void glDrawArrays(GLenum m, GLint f, GLsizei c) { (void)m;(void)f;(void)c; }
#endif
void glColorMask(GLboolean r, GLboolean g, GLboolean b, GLboolean a) { (void)r;(void)g;(void)b;(void)a; }
// Task187: 本地 glEnable 桩退役——镜像 harness 自带 Task187 包装（desktop-only no-op + 转发），语义等价
void glDisable(GLenum c) { (void)c; }
void glBlendFuncSeparate(GLenum a, GLenum b, GLenum c, GLenum d) { (void)a;(void)b;(void)c;(void)d; }
void glBlendEquationSeparate(GLenum a, GLenum b) { (void)a;(void)b; }
void glFramebufferTexture2D(GLenum a, GLenum b, GLenum c, GLuint d, GLint e) { (void)a;(void)b;(void)c;(void)d;(void)e; }
#ifndef AME179_PROD_GL_STUBS
void glGetIntegerv(GLenum p, GLint *v) { (void)p;(void)v; }
#endif
void glVertexAttrib4fv(GLuint i, const GLfloat *v) { (void)i; (void)v; }

int main(void) {
    const char *ver = (const char *)glGetString(GL_VERSION);
    printf("GL_VERSION  = '%s'\n", ver);
    if (strcmp(ver, "3.3.0 (ANGLE 2.1.2440 git hash: 6024e9c05548)") != 0) { printf("FAIL ver\n"); return 1; }
    const char *glsl = (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION);
    printf("GLSL final  = '%s'\n", glsl);
    if (strcmp(glsl, "3.30 (ANGLE 2.1.2440 git hash: 6024e9c05548)") != 0) { printf("FAIL glsl\n"); return 1; }
    const char *rend = (const char *)glGetString(GL_RENDERER);
    if (strcmp(rend, g_renderer) != 0) { printf("FAIL renderer passthrough\n"); return 1; }
    printf("GLGETSTRING CHAIN ALL PASS\n");
    return 0;
}
