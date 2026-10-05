/* Task179: unit test for the glGetString identity spoof functions.
   Extracts ame179_spoofDesktopVersion / ame179_spoofDesktopGlsl from the
   harness-translated tinygl4angle and exercises the exact ANGLE string shapes. */
#include <stdio.h>
#include <string.h>
#include "task179_inc/Foundation/Foundation.h"
#define NSLog(...) do { } while (0)
#include "task179_inc/GL/gl.h"
#include "task179_inc/ame179_prod_marker.h"
extern void *eglGetProcAddress(const char *p);
#include "task179_inc/tinygl4angle_harness.c"

int main(void) {
    // ES3 context strings (exact ANGLE shapes)
    const char *ver_es = "OpenGL ES 3.2.0 (ANGLE 2.1.2440 git hash: 6024e9c05548)";
    const char *glsl_es = "OpenGL ES GLSL ES 3.20 (ANGLE 2.1.2440 git hash: 6024e9c05548)";
    // facade-session strings (what the desktop context used to return)
    const char *ver_desk = "3.3.0 (ANGLE 2.1.2440 git hash: 6024e9c05548)";
    const char *glsl_desk = "OpenGL GLSL 3.30 (ANGLE 2.1.2440 git hash: 6024e9c05548)";

    const char *v = ame179_spoofDesktopVersion(ver_es);
    printf("GL_VERSION: '%s' -> '%s' match=%d\n", ver_es, v, strcmp(v, ver_desk) == 0);
    if (strcmp(v, ver_desk) != 0) return 1;

    const char *g = ame179_spoofDesktopGlsl(glsl_es);
    printf("GLSL: '%s' -> '%s' match=%d\n", glsl_es, g, strcmp(g, glsl_desk) == 0);
    if (strcmp(g, glsl_desk) != 0) return 1;

    // Fail-safe: non-ES shapes return the original pointer
    if (ame179_spoofDesktopVersion(ver_desk) != ver_desk) { printf("FAIL: version passthrough\n"); return 1; }
    if (ame179_spoofDesktopGlsl(glsl_desk) != glsl_desk) { printf("FAIL: glsl passthrough\n"); return 1; }
    if (ame179_spoofDesktopVersion(NULL) != NULL) { printf("FAIL: null\n"); return 1; }
    // ES 2.x shape (unexpected) -> passthrough (fail-safe)
    const char *es2 = "OpenGL ES 2.0 Mesa";
    if (ame179_spoofDesktopVersion(es2) != es2) { printf("FAIL: es2 passthrough\n"); return 1; }
    printf("SPOOF ALL PASS\n");
    return 0;
}

/* stubs for linking (same set as the harness) */
void glClearDepthf(float d) { (void)d; }
void glDepthRangef(float n, float f) { (void)n; (void)f; }
void glGetFloatv(GLenum p, GLfloat *v) { (void)p; (void)v; }
void glGetBooleanv(GLenum p, GLboolean *v) { (void)p; (void)v; }
/* Task220 剔重守卫（同 tinygl 驱动）：生产镜像自带 Task203 空安全包装器。 */
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
void glGetIntegerv(GLenum p, GLint *v) { (void)p; (void)v; }
#endif
void glVertexAttrib4fv(GLuint i, const GLfloat *v) { (void)i; (void)v; }
void *dlsym(void *h, const char *n);
void *eglGetProcAddress(const char *p) { (void)p; return NULL; }
