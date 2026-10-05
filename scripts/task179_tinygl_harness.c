// Task179: local harness for tinygl4angle's glShaderSource delivery chain.
// Compiles tinygl4angle.c with stubs: gles_glShaderSource captures the EXACT
// string uploaded. Feed both the ES300 rewrite output shape and the desktop
// 330 shape; verify byte-for-byte what would reach ANGLE.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <pthread.h>

// ---- stubs for tinygl4angle's external deps ----
typedef unsigned int GLenum;
typedef unsigned int GLuint;
typedef int GLsizei;
typedef int GLint;
typedef float GLfloat;
/* GLdouble from stub header */
typedef unsigned char GLubyte;
typedef char GLchar;
typedef void GLvoid;
#define GL_GLEXT_PROTOTYPES
#include "GL/gl_stub.h"
/* Task220：标记头先行（生产镜像在文件尾部才 include，Foundation 依赖所迫，
 * 尾部注入的宏来不及先于本驱动的桩守卫生效——由 transform 生成的独立
 * 标记头承担顺序解耦） */
#include "ame179_prod_marker.h"

static char g_captured[65536];
static int g_capture_count = -1;
static GLuint g_capture_shader = 0;

// capture sink: what ANGLE would receive
void gles_glShaderSource_capture(GLuint shader, GLsizei count, const GLchar *const *string, const GLint *length) {
    g_capture_shader = shader;
    g_capture_count = count;
    g_captured[0] = '\0';
    for (int i = 0; i < count; i++) {
        if (length && length[i] >= 0) strncat(g_captured, string[i], length[i]);
        else strcat(g_captured, string[i]);
    }
}

// The harness provides dlsym returning the capture sink for glShaderSource.
void *dlsym(void *handle, const char *name) {
    if (strcmp(name, "glShaderSource") == 0) return (void *)gles_glShaderSource_capture;
    return NULL;
}

// eglGetProcAddress stub
void *eglGetProcAddress(const char *procname) { return NULL; }


/* ---- harness stubs: ES-side functions referenced by the completion layer ---- */
void glGetFloatv(GLenum pname, GLfloat *params) { (void)pname; (void)params; }
void glGetBooleanv(GLenum pname, GLboolean *params) { (void)pname; (void)params; }
/* Task220 剔重守卫：生产镜像（task179_inc/tinygl4angle_harness.c）自带
 * Task203 空安全包装器时（AME179_PROD_GL_STUBS），停用本驱动桩，
 * 语义等价（未解析指针 = no-op，同旧桩）。 */
#ifndef AME179_PROD_GL_STUBS
void glDrawElements(GLenum mode, GLsizei count, GLenum type, const void *indices) { (void)mode; (void)count; (void)type; (void)indices; }
void glDrawElementsInstanced(GLenum mode, GLsizei count, GLenum type, const void *indices, GLsizei pc) { (void)mode; (void)count; (void)type; (void)indices; (void)pc; }
void glDrawArrays(GLenum mode, GLint first, GLsizei count) { (void)mode; (void)first; (void)count; }
#endif
void glColorMask(GLboolean r, GLboolean g, GLboolean b, GLboolean a) { (void)r;(void)g;(void)b;(void)a; }
// Task187: 本地 glEnable 桩退役——镜像 harness 自带 Task187 包装（desktop-only no-op + 转发），语义等价
void glDisable(GLenum cap) { (void)cap; }
void glBlendFuncSeparate(GLenum a, GLenum b, GLenum c, GLenum d) { (void)a;(void)b;(void)c;(void)d; }
void glBlendEquationSeparate(GLenum a, GLenum b) { (void)a;(void)b; }
void glFramebufferTexture2D(GLenum a, GLenum b, GLenum c, GLuint d, GLint e) { (void)a;(void)b;(void)c;(void)d;(void)e; }
#ifndef AME179_PROD_GL_STUBS
void glGetIntegerv(GLenum pname, GLint *params) { (void)pname; (void)params; }
#endif
void glVertexAttrib4fv(GLuint index, const GLfloat *v) { (void)index; (void)v; }
void glClearDepthf(float d) { (void)d; }
void glDepthRangef(float n, float f) { (void)n; (void)f; }

// ---- include the REAL tinygl4angle source ----
#define __OBJC2__ 1
#include <Foundation/Foundation.h>
// suppress NSLog

#include "tinygl4angle_harness.c"

int main(void) {
    // Case 1: the Task175/176 ES rewrite output shape (option path)
    const char *es_src =
        "#version 300 es\n"
        "\n"
        "layout(std140) uniform Projection {\n"
        "  mat4 mvp;\n"
        "};\n"
        "layout(location = 0) in vec3 Position;\n"
        "void main() { gl_Position = mvp * vec4(Position, 1.0); }\n";
    const GLchar *const arr1[1] = { es_src };
    glShaderSource(77, 1, arr1, NULL);
    printf("case1 ES300: count=%d shader=%u len=%zu first16='%.16s' starts_with_version=%d\n",
           g_capture_count, g_capture_shader, strlen(g_captured), g_captured,
           strncmp(g_captured, "#version 300 es\n", 16) == 0);
    if (strncmp(g_captured, "#version 300 es\n", 16) != 0) {
        printf("  FULL CAPTURE: '%s'\n", g_captured);
        return 1;
    }
    // Byte-for-byte identity check (beyond first 16)
    if (strcmp(g_captured, es_src) != 0) {
        printf("  MISMATCH! captured differs from input!\n  input : '%s'\n  output: '%s'\n", es_src, g_captured);
        return 1;
    }

    // Case 2: spvc option-path fragment shape with precision block
    const char *es_src2 =
        "#version 300 es\n"
        "precision mediump float;\n"
        "precision mediump int;\n"
        "precision highp sampler2D;\n"
        "layout(location = 0) out vec4 fragColor;\n"
        "uniform sampler2D tex;\n"
        "void main() { fragColor = texture(tex, vec2(0.5)); }\n";
    const GLchar *const arr2[1] = { es_src2 };
    glShaderSource(78, 1, arr2, NULL);
    printf("case2 ES300+precision: starts_ok=%d identical=%d\n",
           strncmp(g_captured, "#version 300 es\n", 16) == 0,
           strcmp(g_captured, es_src2) == 0);
    if (strcmp(g_captured, es_src2) != 0) {
        printf("  FULL: '%s'\n", g_captured);
        return 1;
    }

    // Case 3 (regression): desktop 330 shape goes down the conversion path
    const char *desk_src =
        "#version 330\n"
        "\n"
        "layout(std140) uniform Projection { mat4 mvp; };\n"
        "layout(location = 0) in vec3 Position;\n"
        "void main() { gl_Position = mvp * vec4(Position, 1.0); }\n";
    const GLchar *const arr3[1] = { desk_src };
    glShaderSource(79, 1, arr3, NULL);
    printf("case3 desktop330: version_line='%.14s' has_extensions=%d\n",
           g_captured, strstr(g_captured, "#extension") != NULL);

    printf("ALL CASES DELIVERED. tinygl4angle delivery chain verified.\n");
    return 0;
}
