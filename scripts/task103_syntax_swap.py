#!/usr/bin/env python3
"""Task103: osm_swap_buffers 呈现/投票段独立语法门（g++，task85 D1 变换约定）

覆盖本任务新增的哨兵票/翻转判决/心跳扩展 + Task99/100 既有呈现逻辑的
完整 osm_swap_buffers 函数体。ObjC 结构按 D1 惯例变换：
  NSLog(@"...") -> printf("...")   @"..." -> "..."
  dispatch_async(q, ^{...}) -> dispatch_async(q, [&]() { ... })
  (__bridge id)x -> (id)x
CG/Surface/桥接符号用桩（语法门只验 C/C++ 语义结构；行为断言由
verify_task103 的文本锚点覆盖）。
"""
import re, subprocess, tempfile, os, sys

SRC = 'Natives/ctxbridges/osm_bridge.mm'
src = open(SRC, encoding='utf-8').read()

seg = src[src.index('void osm_swap_buffers() {'):]
seg = seg[:seg.index('void osm_swap_interval')]

# ObjC -> C++ 变换
seg = seg.replace('NSLog(@"', 'printf("')
seg = re.sub(r'@"((?:[^"\\]|\\.)*)"', r'"\1"', seg)
seg = seg.replace('(__bridge id)', '(id)')
seg = seg.replace('dispatch_async(dispatch_get_main_queue(), ^{',
                  'dispatch_async(dispatch_get_main_queue(), [&]() {')

header = r'''
#include <stdint.h>
#include <stddef.h>
#include <cstdio>
#include <cstring>
#include <string>
// ---- 桩：类型/枚举（与 osm_bridge.h 语义等价的最小面）----
typedef unsigned int uint32_t_bogus_unused;
typedef int GLsizei;
typedef unsigned int GLenum;
typedef void *id;
typedef void *CGDataProviderRef;
typedef void *CGImageRef;
typedef void *CGColorSpaceRef;
#define kCGImageAlphaNoneSkipLast 0
#define kCGBitmapByteOrderDefault 0
#define kCGRenderingIntentDefault 0
#define FALSE 0
// ---- 桩：桥接全局（osm_bridge 真实符号的声明面）----
extern int windowWidth, windowHeight;
typedef struct osm_render_window_stub {
    uint32_t width, height;
    void *buffer;
    void *color_space;
} osm_render_window_t;
struct basic_render_window_stub { osm_render_window_t osm; };
extern basic_render_window_stub *currentBundle;
static struct { void (*glFinish)(void); } handle_stub;
#define handle handle_stub
static void CallbackBridge_nativeSendScreenSize(int, int) {}
// ---- 桩：Task 83/99/100/103 状态（真实定义在文件前段的语法等价物）----
struct ame83_stub {
    bool markerArmed; unsigned markerCode; long frames; bool healed;
    struct { void (*glGetIntegerv)(unsigned int, int *); } gl;   // Task105：视口自适应读取
};
static ame83_stub ame83_fsr;
static bool ame83_resolve_gl(void) { return true; }   // Task105：真实实现幂等（resolved 旗标）
#define GL_VIEWPORT 0x0BA2   // Task105：桩枚举（真实 TU 由 Mesa 头提供）
struct ame99_stub {
    long swaps; int probeHits, probeFrames; int verdict; bool gpuProbed;
    int mkHits, mkState, mkConsecM, mkConsecMiss; int mkFarHits; bool final90Logged;
};
static ame99_stub ame99_fsrdiag;
#define kAme99ProbeFrames 90
static struct {
    unsigned char *scratch; unsigned char *present;
    int bufW, bufH; bool engaged, broken; int drvHits, drvFrames;
} ame100_present;
static bool ame104_filters_linear = false;   // Task104：呈现层滤镜状态（swap 两个分支共享）
// ---- Task106 桩（真实定义在文件前段：bundle-direct 状态/计时/哨兵 + 票核心）----
static struct {
    bool active; int warm, misses; long frames, hits; bool engagedLogged, fallbackLogged;
    double tPreUs, tFinUs, tReadUs, tSwapUs, tPreMax, tFinMax, tReadMax, tSwapMax;
    double lastEntryUs, gapSumUs, gapMaxUs; int gapN, winN;
} ame106;
static double ame106_us(uint64_t m) { (void)m; return 0; }
static bool ame106_bundle_sentinels(const unsigned char *b, uint32_t w, uint32_t h, unsigned char c) { (void)b;(void)w;(void)h;(void)c; return false; }
static void ame103_marker_vote(bool hit, osm_render_window_t b) { (void)hit; (void)b; }
// ---- Task109 桩（真实定义在文件前段：no-finish 取证窗口状态机）----
static struct { long frame; bool inWindow; double winSwapUs; long winN; double baseSwapUs; long baseN; } ame109;
static bool ame109_window_active(long f) { (void)f; return false; }
static bool ame109_trial_gate(bool fsrActive) { (void)fsrActive; return false; }
static uint64_t mach_absolute_time(void) { return 0; }
struct osm_bundle_t { uint32_t width, height; void *buffer; void *color_space; };
// ---- Task212 门修复：补 Task109 之后加入 osm_swap_buffers 的符号桩 ----
// （bridge_tbl 的 br_get_current 与 Task139 的输入缩放复位钩子；本门
// 自 Task109 后未随之更新，先于本轮即已 SYNTAX FAIL——git 实证与 Task212
// 改动无关，这里修复恢复门的守护力。）
static basic_render_window_stub *br_get_current(void) { return currentBundle; }
static void ame139_fsr_heal_reset_input_scale(void) {}
// ---- Task223 桩：渲染线程后台驻车（真实定义在 utils.m，声明在 utils.h；
// osm_swap_buffers 交换边界等待点。utils.h 经条件编译链在此提取段不可见，
// 语义等价桩保持门的守护力。）----
static void ame223_bg_park_wait(const char *swapSite) { (void)swapSite; }
// ---- 桩：CG / Surface / dispatch ----
static void *dispatch_get_main_queue(void) { return (void *)1; }
template <typename F> static void dispatch_async(void *, F) {}
static CGDataProviderRef CGDataProviderCreateWithData(void *, const void *, size_t, void *) { return 0; }
static CGImageRef CGImageCreate(uint32_t, uint32_t, int, int, size_t, void *, int, CGDataProviderRef, void *, int, int) { return 0; }
static void CGImageRelease(CGImageRef) {}
static void CGDataProviderRelease(CGDataProviderRef) {}
static struct { struct { struct { id contents; id magnificationFilter; id minificationFilter; } layer; } surface; } SurfaceViewController;
#define kCAFilterLinear ((id)1)
#define kCAFilterNearest ((id)2)
// ---- osm_apply_current_ll / ame83_fsr_upscale / ame100_present_frame 桩 ----
static void osm_apply_current_ll(void) {}
static bool ame83_fsr_upscale(int, int, int, int) { return true; }
static bool ame100_present_frame(int, int) { return true; }
'''

footer = '''
int main(void) { osm_swap_buffers(); return 0; }
'''

with tempfile.NamedTemporaryFile('w', suffix='.cpp', delete=False) as f:
    f.write(header + seg + footer)
    tmp = f.name
r = subprocess.run(['g++', '-std=gnu++17', '-fsyntax-only', '-Wall', tmp],
                   capture_output=True, text=True)
os.unlink(tmp)
if r.returncode != 0:
    print('SYNTAX FAIL:\n' + r.stderr)
    sys.exit(1)
print('osm_bridge.mm osm_swap_buffers section (Task103 vote/present): syntax OK')
