#pragma once

#import <UIKit/UIKit.h>

#include <stdbool.h>
#include <string.h>
#include "environ.h"
#include "jni.h"

// Task 83（FSR 独立化 / ObjC++ 化）：本头自 Task83 起被 C++ TU（ctxbridges/
// osm_bridge.mm）包含。函数声明无 extern "C" 防护时，C++ 侧按 Itanium ABI
// 修饰名引用（如 "customNSLog(char const*, int, ...)"），C TU（utils.m 等）
// 的未修饰定义与之无法会合 → 链接失败（CI run 35036079381）。本头纯 C 声明
// （函数/宏/变量，无 ObjC 结构），整体包 extern "C" 安全。
#ifdef __cplusplus
extern "C" {
#endif

// Remove date + time from NSLog, unneeded
#define NSLog(args...) customNSLog(__FILE__,__LINE__,__PRETTY_FUNCTION__,args);

// Control button actions
#define ACTION_DOWN 0
#define ACTION_UP 1
#define ACTION_MOVE 2
#define ACTION_MOVE_MOTION 3

#define BUTTON1_DOWN_MASK 1 << 10 // left btn
#define BUTTON2_DOWN_MASK 1 << 11 // mid btn
#define BUTTON3_DOWN_MASK 1 << 12 // right btn

// GLFW event types
#define EVENT_TYPE_CHAR 1000
#define EVENT_TYPE_CHAR_MODS 1001
#define EVENT_TYPE_CURSOR_ENTER 1002
#define EVENT_TYPE_CURSOR_POS 1003
#define EVENT_TYPE_FRAMEBUFFER_SIZE 1004
#define EVENT_TYPE_KEY 1005
#define EVENT_TYPE_MOUSE_BUTTON 1006
#define EVENT_TYPE_SCROLL 1007
#define EVENT_TYPE_WINDOW_POS 1008
#define EVENT_TYPE_WINDOW_SIZE 1009
#define EVENT_TYPE_MODIFIERS 1010

#define GLFW_FOCUSED 0x00020001
#define GLFW_VISIBLE 0x00020004

// Task212：holy gl4es（libgl4es_114.dylib）已退役删除。历史存量值由
// main.m 的 ame212_migrateHolyGl4es 一次性迁移到 ZL2 经典版
// （RENDERER_NAME_GL4ESZL2）；egl_bridge/JavaLauncher 的 auto 兜底同步
// 改道。迁移判定用字面量 "libgl4es_114.dylib"（宏已随渲染器退役）。
#define RENDERER_NAME_MTL_ANGLE "libtinygl4angle.dylib"
// Task173：VGPU 渲染器（PojavLauncherTeam/VGPU，gl4es 分支 + 强化着色器
// 语法转换，旧版 MC <1.13 生态；FCL 同款可选渲染器，iOS 移植见
// Natives/external/vgpu 各文件 Task173 标记与 CMakeLists 的 vgpu 目标）。
#define RENDERER_NAME_VGPU "libvgpu.dylib"
#define RENDERER_NAME_MOBILEGLUES "libmobileglues.dylib"
#define RENDERER_NAME_VK_ZINK "libOSMesa.8.dylib"
// Task 215：VirGLRenderer(≤26.2)（ZL2 移植，Task212 预留）—— Mesa virgl guest + 进程内 vtest server
#define RENDERER_NAME_VIRGL "libOSMesaVirgl.dylib"
#define RENDERER_NAME_VULKAN "libMoltenVK.dylib"
// Metal 渲染器（metallum / MetalUniversal，Task201 随上游同步移植）：图形后端
// 由 metallum agent（javaagent 注入）走原生 Metal（直接 MTLDevice），不经 EGL
// 渲染器转译。JavaLauncher 检测到该选择后置 AMETHYST_METAL=1（agent 据此打开
// 渲染 patch），并把 AMETHYST_RENDERER 回落 auto（Surface 的 GL 上下文仍由
// ANGLE 提供），与 metallum 官方集成一致。仅在 MC major >= 26 时挂载 agent
// （其 class 文件版本 65.0 需 Java 21+，老版本 MC 的 Java 8 加载即崩）。
// 渲染器 dylib 由 agent jar 自带（natives/ios/libmetallum.dylib，运行期解出）；
// Frameworks 里的入库副本仅为渲染器选择器的存在性过滤服务。
#define RENDERER_NAME_METAL "libmetallum.dylib"
// LTW (Large Thin Wrapper) - OpenGL Core 3.3 → OpenGL ES 3 转译层
// 复刻自官方 MojoLauncher/LTW 仓库，完美支持 Sodium + Iris 光影：
//   - 伪装成 OpenGL 3.3 Core Profile 让 MC 1.17+ 正常运行
//   - 主动声明 GL_ARB_buffer_storage 等 ARB 扩展，让 Sodium 的
//     persistent mapped buffers / texture buffers 正常工作
//   - Fragment shader 编译失败时忽略错误，让 BSL/Mellow 等光影包能运行
#define RENDERER_NAME_LTW "libltw.dylib"

// NG-GL4ES（"Krypton Wrapper"，BZLZHH/NG-GL4ES）—— ZalithLauncher 2 所用的
// gl4es（ptitSeb/gl4es + PojavLauncherTeam/gl4es-114-extra 进化 fork，MIT）。
// 着色器转换走 glslang GLSL→SPIR-V + SPIRV-Cross SPIR-V→ESSL（glsl_for_es.cpp），
// 官方口径"几乎全版本 MC 可跑"（上游 README）。Task206 从上游 main 分支
// vendor 到 ThirdParty/ZalithLauncher2（源码、适配 CMake、生成式 darwin 别名
// 见 scripts/task206_gen_nggl4es_aliases.py）；构建走 Makefile 的 dep_nggl4es
// 目标（glslang 静态库复用 dep_mg 的 15.0.0 + 双崩溃补丁树，SPIRV-Cross 复用
// 随包预编译 impl dylib）。与 gl4es/vgpu 同族：导出全套桌面 GL API，运行时
// 经 NOEGL 的 proc_address 解析后端（宿主用导出的 set_getprocaddress 钉
// ame204_gl4esProcResolver——Task204 同款通道，见 egl_bridge.m Task206 块）。
// 用户的 vgpu（1.8.9 材质损坏，Task204/205 两轮根修未愈）由此接替。
#define RENDERER_NAME_NGGL4ES "libnggl4es.dylib"

// Task211：ZL2 经典版 gl4es（PojavLauncherTeam/gl4es_extra_extra——ZL2 的
// 传统 "gl4es" 渲染器，ZL2 随包的 libgl4es_114.so 即此源码树）。纯 C 的
// 字符串改写式 GLSL→ESSL 转换器（shaderconv.c），无 glslang/SPIRV-Cross
// 依赖（dep_gl4eszl2 独立目标，不排 glslang 静态库）。与 holy gl4es
// （预构建 libgl4es_114.dylib）和 Krypton Wrapper（NG 改写版）三者并存
// 互为备选——用户点名要的 ZL2 同款。运行时同族：NOEGL 的 proc_address
// 后端解析 + 宿主 set_getprocaddress 钉 resolver（Task204 通道）+ 上下文
// current 后显式 initialize_gl4es（Task208 时机，ame211_gl4eszl2_boot）。
#define RENDERER_NAME_GL4ESZL2 "libgl4eszl2.dylib"

// Mithril 渲染器 - OpenGL 3.3 Core → Vulkan/Metal 转译层（libmithril.dylib）。
// 自带完整的 EGL 1.5 + GL 实现（Vulkan backend，经 MoltenVK 到 Metal），
// 必须从自身 dylib 解析 EGL 符号：若复用 ANGLE 的 EGL，会创建 ANGLE 的 Metal
// 上下文而非 Mithril 的 swapchain，且 eglChooseConfig 在 Mithril 的属性组合下
// 可能返回 0 个配置，触发 gl_init_context 的 assert(bundle->config)。
// 参考：Uniaball/Mithril-Wrapper 仓库 launcher-patch/ 下对 Prisma 的接入方式。
#define RENDERER_NAME_MITHRIL "libmithril.dylib"

// MobileGL - MobileGL-Dev 的桌面 OpenGL 实现（LGPL-3.0）。
// 两个变体共用同一个 libMobileGL.dylib 二进制，由环境变量
// MOBILEGL_BACKEND_TYPE 在运行时选择后端：
//   libMobileGL.dylib       -> DirectVulkan（GL -> Vulkan -> MoltenVK -> Metal）
//   libMobileGL-gles.dylib  -> DirectGLES（GL -> OpenGL ES）
// 与 Mithril 一样自带 EGL 实现，必须从自身 dylib 解析 EGL 符号。
// 参考：Swung0x48/Amethyst-iOS 提交 dc57bfd3d2 "feat: add MobileGL renderer support"。
#define RENDERER_NAME_MOBILEGL "libMobileGL.dylib"
#define RENDERER_NAME_MOBILEGL_GLES "libMobileGL-gles.dylib"

static inline bool isMobileGLRenderer(const char *renderer) {
    return renderer && (!strcmp(renderer, RENDERER_NAME_MOBILEGL) ||
                        !strcmp(renderer, RENDERER_NAME_MOBILEGL_GLES));
}

static inline bool isMithrilRenderer(const char *renderer) {
    return renderer && !strcmp(renderer, RENDERER_NAME_MITHRIL);
}

// 自带 EGL 实现的渲染器：EGL 符号要从渲染器自己的 dylib 解析，不能用 ANGLE。
static inline bool isSelfEglRenderer(const char *renderer) {
    return isMithrilRenderer(renderer) || isMobileGLRenderer(renderer);
}
// Task 138：-gles 逻辑键到物理 dylib 名的统一映射。
// 渲染器菜单里的 libMobileGL-gles.dylib 是逻辑键（物理文件不随包，共享
// libMobileGL.dylib 二进制，后端由 MOBILEGL_BACKEND_TYPE 选择）。Java 侧
// 的 opengl.libname 映射早已存在（JavaLauncher），egl_bridge 的
// JNI_LWJGL_changeRenderer 与预加载 dlopen 也有（Task 131），但
// gl_bridge.m 的 dlsym_EGL 与 sdl3_hook.m 的 ame_rendererHandle 兜底
// 漏了同一映射——本轮 26.2 会话（libMobileGL-gles 渲染器）装机日志实证：
// dlopen("@rpath/libMobileGL-gles.dylib") 必败（文件不存在）→
// dlsym_EGL 返回 false → pojavInitOpenGL 报 br_init 失败 →
// pojavCreateContext 仍走 br_init_context → gl_init_context 空函数
// 指针 → SIGSEGV(pc=0)。此助手把三处语义收敛为一份。
static inline const char *ame_physical_renderer_dylib(const char *renderer) {
    if (renderer && strcmp(renderer, RENDERER_NAME_MOBILEGL_GLES) == 0) {
        return RENDERER_NAME_MOBILEGL;
    }
    return renderer;
}

// Task 139：FSR 渲染兜底自愈后的输入缩放复位（实现在 SurfaceViewController.m，
// mgl_fsr.mm / osm_bridge.mm 的兜底点调用）。MC 窗口被恢复为全表面分辨率时，
// 输入换算的 mgFsrScale 除数必须同步归一，否则触点只发一半 = 输入错位。
void ame139_fsr_heal_reset_input_scale(void);


// 导出 desktop OpenGL（而非 OpenGL ES）的渲染器：
// 需要 EGL_OPENGL_BIT 配置 + eglBindAPI(EGL_OPENGL_API)。
static inline bool isDesktopGLRenderer(const char *renderer) {
    return isMobileGLRenderer(renderer) || isMithrilRenderer(renderer) ||
           (renderer && !strcmp(renderer, RENDERER_NAME_MTL_ANGLE));
}

#define SPECIALBTN_KEYBOARD -1
#define SPECIALBTN_TOGGLECTRL -2
#define SPECIALBTN_MOUSEPRI -3
#define SPECIALBTN_MOUSESEC -4
#define SPECIALBTN_VIRTUALMOUSE -5
#define SPECIALBTN_MOUSEMID -6
#define SPECIALBTN_SCROLLUP -7
#define SPECIALBTN_SCROLLDOWN -8
#define SPECIALBTN_MENU -9

#define NSDebugLog(...) if (debugLogEnabled) { NSLog(__VA_ARGS__); }
// Task 122 链接修复（CI 35459629168：osm_bridge 与 mgl_fsr 两个 C++ TU 各自
// 强定义这对全局 -> 4 个重复符号）。environ.h 的 AME_ENVIRON_DECL 同款守卫：
// C++ TU 只见 extern 声明，存储由各 C TU 的 tentative 定义承担（-fcommon 合并）。
#ifdef __cplusplus
extern BOOL debugLogEnabled, isJailbroken;
#else
BOOL debugLogEnabled, isJailbroken;
#endif

//__weak UIViewController *viewController;

#define CS_DEBUGGED 0x10000000
int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
BOOL isJITEnabled(BOOL checkCSOps);
// Task96：MeloNX 风格信息卡数据源（右面板「设备」「系统」卡片）。
// getDeviceMarketingName：hw.machine（如 iPad15,3）→ Apple 营销名
//（如 "iPad Air 11-inch (M3)"）；未收录机型回退 hw.machine 原始标识，宁缺毋错。
// getSystemVersionDisplay："iPadOS 18.3.2 (22D2082)"（系统名+版本+构建号，
// iPhone 上前缀为 iOS；构建号读不到时只显示系统版本）。
NSString* getDeviceMarketingName(void);
NSString* getSystemVersionDisplay(void);
// Check if a debugger is likely still attached (iOS 26+ TXM workaround).
// When FORCE_MIRRORED + HAS_TXM, brk #0x69 in JavaLauncher requires a
// debugger to be actively attached.  getppid() returns launchd's PID (1)
// when no debugger is present, and the debugger's PID otherwise.
BOOL JIT26IsLikelyDebuggerKeepAttached(void);
// Live "debugger attached right now" check via the kernel P_TRACED flag
// (sysctl KERN_PROC_PID).  Covers debuggers that attach to an
// already-running process by pid (StikJIT/SideJIT), where getppid()
// stays 1 for the whole session.
BOOL JIT26DebuggerAttachedViaPtrace(void);
// Live "debugger holds our task" check via Mach exception ports
// (task_get_exception_ports on EXC_BREAKPOINT|EXC_SOFTWARE).  lldb/debugserver
// keep serving breakpoints through task-level exception ports after
// PT_DETACH, with P_TRACED back at 0 -- this is what actually services the
// JIT26 brk #0x69 / brk #0xf00d traps in that state.
BOOL JIT26DebuggerViaExceptionPorts(void);
// legacy method used to check if we're using universal script
void* JIT26CreateRegionLegacy(size_t len);
// Task91：JIT26CreateRegionLegacy 的 SIGTRAP 安全网包装。
// TXM 设备上 brk #0x69 无人应答（JIT26 调试器未就绪/脚本未挂载/调试器提前
// 脱离）时，裸函数会直接 SIGTRAP 致死（"开启 JIT 后闪退"）。包装器在调用
// 窗口内捕获 SIGTRAP 并返回 NULL，由调用方走优雅报错路径；调试器正常应答
// 时行为与裸函数完全一致。
void* JIT26CreateRegionLegacySafe(size_t len);
// Task91：TrollStore 真实安装判定（entitlement 标记 AND bundle 旁 _TrollStore
// 目录）。签名里预写的 jb.pmap_cs.custom_trust 字符串在普通侧载包上同样存在，
// 单独使用会把非 TrollStore 环境误导入 apple-magnifier:// 死路。
BOOL isTrollStoreInstall(void);
// Task169：JIT 等待轮询的有界版本（最长 timeout 秒；每 10s 心跳日志；
// 超时返回 NO）。替代三处 invokeAfterJITEnabled 里的裸
// while (!isJITEnabled) 死循环——stikjit:// 偶发没开成 JIT 时旧循环
// 永不退出（装机实测"启动卡在启动器界面"，只能杀进程）。
BOOL ame169_waitForJITCondition(BOOL (^condition)(void), NSTimeInterval timeout, NSString *label);
// Task185：JIT 等待成功后的自愈式主队列派发。病历（11e4b63 装机 latestlog.2）：
// condition satisfied（后台态 3.8s，traced=1 exn=1）之后 dispatch_async(main)
// 的续接块【从未执行】——Task183 锚点 "wait-completed block entered" 缺失，
// 会话就此卡死。同一构建的三个成功会话（版本列表页启动）同代码主队列照常
// 排空（锚点全部在后台态打出）；卡死会话的独有环境 = 版本设置二级菜单
// （ProfileSettings 在导航栈里）+ 拼音键盘活动（开场即有 keyplane 日志）。
// GCD 不丢弃块，唯一解释：主线程在后台被楔死（键盘/输入服务会话是头号
// 嫌疑）。三道防线：①常规派发（快路径与旧代码完全等价）；②前台激活监听
// 重派（后台楔死的主线程在 UIKit 激活流程中被解锁——didBecomeActive 后
// 重派一次必然送达）；③后台队列看门狗（每 2s 复查；App 在前台而未达 =
// 派发被吞形态，立即重派；120s 全程未达 → 钉死锚点日志）。delivered 的
// 检查与置位只在主队列串行发生（attempt 内），多重派发不会导致块双跑。
void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label);
// used for large memory regions
void* JIT26PrepareRegion(void *addr, size_t len);

// ============================================================================
// Task185：加载器版本 ↔ 游戏版本等价匹配（Forge/NeoForge >26 找不到根修）。
// 病历（11e4b63 装机反馈）：Minecraft 26.x 起版本号去掉 "1." 前缀（26.3、
// 26.1.2），而三处提取器仍把 NeoForge 26.3.x 解析成 MC "1.26.3"、把 Forge
// 复合版本 "26.3-66.0.5" 的 MC 段判为 "Unknown"（^1\. 正则不匹配新格式）
// → gameVersion 过滤器把全部条目跳过 = 列表全空。
// 本匹配器不做单向提取，而是双向候选集等价判定：
//   loaderVersion 侧候选 = {去 "-suffix" 后全文, 再去最后一个点分量}
//     （覆盖 "26.3-66.0.5"→26.3、"21.1.5"→21.1、"26.1.2.71"→26.1.2、
//       "26.3.0.5-beta"→26.3.0）
//   gameVersion 侧候选 = {原文, 去 "1." 前缀, 二分量补 ".0"}
//     （覆盖 "1.21"→21/21.0、"1.20.1"→20.1、"26.3"→26.3/26.3.0）
// 另保留两族特殊形态：NeoForge legacy "47.x"/含 "1.20.1"（1.20.1 专用坐标）、
// "0.<snapshot>.x"（愚人节快照专用）。
// 消费方：NeoForgeVersionFetcher.filterVersions、
// ForgeInstallViewController 双过滤器、ModLoaderInstallViewController。
// ============================================================================
BOOL ame185_loaderVersionMatchesGameVersion(NSString *loaderVersion, NSString *gameVersion);
// same as JIT26PrepareRegion, but used for smaller memory regions
// and retain content instead of filling 0x69
void JIT26PrepareRegionForPatching(void *addr, size_t len);
void JIT26SetDetachAfterFirstBr(BOOL value);
void JIT26SendJITScript(NSString* script);

typedef enum {
    JIT_FLAG_IS_IOS_26 = 1 << 0,
    JIT_FLAG_FORCE_MIRRORED = 1 << 1,
    JIT_FLAG_HAS_TXM = 1 << 2,
} JITFlags;
JITFlags DeviceGetJITFlags(BOOL refresh);
BOOL DeviceHasJITFlags(JITFlags flags);

// Init functions
void init_bypassDyldLibValidation();
void init_hookFunctions();

// Zink (Mesa 25.0.7) + MoltenVK vertex stride 4 字节对齐 fix
// 仅在 zink 渲染器被选中时激活（需在 AMETHYST_RENDERER 环境变量设置后调用）
// 详见 main_hook.m 中的实现注释
void installZinkStrideFix();
// 在新 image（libOSMesa / libMoltenVK）加载后调用，重新执行 fishhook
// 捕获新 image 对 Vulkan loader 函数的符号引用
void rebindZinkStrideFixForNewImage();
void init_hookUIKitConstructor();
void init_setupMultiDir();

// Task 132（sdl3_hook.m 实现）：libjnidispatch 加载后重绑定其 _dlsym
// 指针槽为 hook_fn——JNA 的符号解析由此进 hooked_dlsym /
// amethyst_sdl3_hook_resolve，Task131 的 JNA closure 守卫对 JNA 路径生效。
// handle = 真实 dlopen 返回的句柄（= image mach header 地址）。
void amethyst_task132_rebind_jna_dlsym(void *handle, void *hook_fn);

// Task 133（sdl3_hook.m 实现，26.1.2 controlify/JNA SIGBUS 根治）：
// 增量扫描已加载镜像——libjli/libjvm 的 _dlopen 槽改绑到 hooked_dlopen
// （JVM 的 System.load 链由此可见），libjnidispatch（含 jna*.tmp 解包形态，
// 按 LC_ID_DYLIB install name 识别）触发 Task132 重绑定。由 hooked_dlopen
// （JVM/JNA 相关路径加载后）与 hooked_dlsym（入口）驱动；游标设计，
// 无新镜像时开销 = 一次 dyld 计数调用。
void amethyst_task133_ensure_jvm_chain(void);

// Task 134（sdl3_hook.m 实现）：JVM 镜像扫描看门狗——主队列 200ms 定时
// 器持续调 ensure_jvm_chain，链路无关地兜底检出 libjnidispatch（取证：
// JNA 加载 jnilib 到 controlify 解析 SDL 符号相隔秒级，窗口充足）。
// 检出 JVM 家族镜像时自动启动，也可外部主动调用提前启动。
void amethyst_task134_jvm_watchdog_start(void);

BOOL PLPatchMachOPlatformForFile(const char *path);

UIViewController* currentVC();
void openLink(UIViewController* sender, NSURL* link);
void handle_fatal_exit(int code);
// Task 27：fatal 通道取证 —— 把 abort/exit/断言的调用线程名+符号化回溯
// O_APPEND 直写 $POJAV_HOME/fatal_trace.txt（绕过 latestlog 管道，防丢尾）
void ame_write_fatal_trace(const char *reason);

NSString* localize(NSString* key, NSString* comment);
NSMutableDictionary* parseJSONFromFile(NSString *path);
NSError* saveJSONToFile(NSDictionary *dict, NSString *path);
void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...);

static inline CGFloat clamp(CGFloat x, CGFloat lower, CGFloat upper) {
    return fmin(upper, fmax(x, lower));
}
CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2);
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max);
CGFloat dpToPx(CGFloat dp);
CGFloat pxToDp(CGFloat px);
void setButtonPointerInteraction(UIButton *button);
void _CGDataProviderReleaseBytePointerCallback(void *info,const void *pointer);
void dismissModalViewController(UIViewController *viewController);

jboolean attachThread(bool isAndroid, JNIEnv** secondJNIEnvPtr);

void sendData(short type, int i1, int i2, short i3, short i4);
void sendDataFloat(short type, float i1, float i2, short i3, short i4);

void closeGLFWWindow();
void callback_LauncherViewController_installMinecraft();
void callback_SurfaceViewController_launchMinecraft(int width, int height);
int callback_SurfaceViewController_touchHotbar(CGFloat x, CGFloat y);

// FPS 计数器：在 pojavSwapBuffers() 中累加，调用此函数读取并重置（参照 FCL/ZL2）
unsigned int pojavGetAndResetFps();
// 显式递增 FPS 计数器（供 Vulkan 模式 CADisplayLink fallback 使用）
void pojavIncrementFpsCounter();
// 黑屏取证（Task 32）：eglSwapBuffers 真实成功/失败计数（gl_bridge.m 实现）。
// 与上面的 FPS 计数器区分：FPS 计 pojavSwapBuffers 入口调用（成功与否都+1），
// 这两个计数器计 eglSwapBuffers 的真实返回值，用于判断呈现路径是否断裂。
void ame_egl_swap_stats(unsigned long *ok, unsigned long *fail);
// Task 76（帧节奏诊断）：读取并重置 5 秒窗口内的 swap 帧间隔统计
//（gl_bridge.m 实现，渲染线程侧记录）。maxGap=窗口内最大帧间隔（尖峰），
// avgGap=平均帧间隔。读取即重置，由 [RenderDiag] 心跳（SurfaceViewController
// updateGameStats 的 5 秒档）调用。帧率均值掩盖节奏问题——vsync 锁 60 下
// maxGap 的阶梯分布（33/50/100/200ms）才是"30fps 看得像 10fps"的直接度量。
void ame_egl_swap_framegap(unsigned int *maxGapMs, unsigned int *avgGapMs);
// Task 77（帧相位归因）：读取并重置 5 秒窗口内渲染线程帧循环的两相位
// 计时（gl_bridge.m 实现，渲染线程侧记录）：
//   present = eglSwapBuffers 本体耗时（ANGLE Metal 编码提交/nextDrawable/
//             GPU 追赶；maxDrawableCount=3 耗尽时阻塞在此）
//   build   = 上次 present 返回 → 本次 swap 入口（MC tick+事件泵+GL 编码
//             穿 MobileGlues/ANGLE 的 CPU 税）
// avg/max 均折算毫秒，读取即重置。MG 卡顿归因的判读法：presAvg≈avgGap
// → 停在呈现/GPU 侧；buildAvg≈avgGap → 停在 CPU 帧构造侧。
void ame_egl_swap_phase_stats(unsigned int *presentAvgMs, unsigned int *presentMaxMs,
                              unsigned int *buildAvgMs, unsigned int *buildMaxMs);
// Task 50：GL 呈现层所有权（gl_bridge.m 实现）。GL 路径创建 EGL surface
// 成功后为真——SurfaceViewController.updateSavedResolution 据此把呈现层
// 对齐到 1x 点数（bounds 跟随旋转），与 MC viewport/ANGLE surface 保持
// 单一事实源。Vulkan 路径恒为假（MoltenVK 自管 drawableSize，行为不变）。
bool ame_gl_surface_owns_layer();
// Task 53：EGL surface 与 MC viewport 几何失配（转置锁死且重对齐未治愈）
// 期间为真（gl_bridge.m 实现，交换路径逐帧刷新）。updateSavedResolution
// 据此停写 drawableSize——失配期由 Task52 guard 以 surface 尺寸独占写权
// （present 自洽），避免两写者拉锯产生"左半屏压扁 + 右半屏残帧"的分裂
// 画面；重对齐成功后 surface==bounds，正常写入恢复为同值 no-op。
bool ame_gl_surface_transposed();
// 运行时判定 MC 真实渲染路径是否为 Vulkan（clientAPI == GLFW_NO_API）。
// 比 SurfaceViewController 在 viewDidLoad 时的静态字符串推断更准确：
// - 真正 Vulkan 路径（graphicsApi=prefer_vulkan 或 default 走 Vulkan）→ 返回 true
// - Vulkan 渲染器但 MC 实际选 OpenGL 路径（prefer_opengl）→ 返回 false，避免双重计数
// 此函数读取 egl_bridge.m 中的 clientAPI 全局变量，由 pojavSetWindowHint(GLFW_CLIENT_API, ...) 写入。
bool pojavIsActualVulkanPath();

void CallbackBridge_nativeSetInputReady(BOOL inputReady);
BOOL CallbackBridge_nativeSendChar(jchar codepoint /* jint codepoint */);
BOOL CallbackBridge_nativeSendCharMods(jchar codepoint, int mods);
// Task83：控件按钮键盘打字支持——executebtn 在按键按下时对本键补发
// 字符事件（MC 1.13+ 聊天框只认 charTyped/text-input，纯 key 事件不进文本）。
// 仅由按钮路径调用（SurfaceViewController executebtn），硬件键盘不走这里。
BOOL CallbackBridge_buttonKeySynthesizeText(int key);
// Task161：GLFW 路径（MC ≤26.2）聊天自动弹键盘——查询"最近 withinSeconds
// 秒内发给 MC 的最后一次按键是否为 T / 斜杠"（vanilla 聊天/命令行的标准
// 开键）。SurfaceViewController.updateGrabState 在 grab 转 false 时消费。
// 实现于 input_bridge_v3.m（nativeSendKey 侧记录）。
BOOL ame161_lastSentKeyWasChatOpener(NSTimeInterval withinSeconds);
// Task161（CI 修复）：输入路径判定——YES = GLFW（MC ≤26.2），NO = SDL3（26.3+）。
// g_sdlWindow 是 input_bridge_v3.m 的 static，导出本函数供 UI 侧判定。
BOOL ame161_inputPathIsGLFW(void);
void CallbackBridge_nativeSendCursorPos(char event, CGFloat x, CGFloat y);
void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods);
void CallbackBridge_nativeSendMouseButton(int button, int action, int mods);
void CallbackBridge_nativeSendScreenSize(int width, int height);
void CallbackBridge_nativeSendScroll(CGFloat xoffset, CGFloat yoffset);
void CallbackBridge_sendKeycode(int keycode, jchar keychar, int scancode, int modifiers, BOOL isDown);
void CallbackBridge_pauseGameIfNeed();
// ★ [FG] 上游 d76301816 同步（Task222）：与上面成对——回前台时重申窗口尺寸，
//   让 MC 重新同步 framebuffer（内部已做 0 尺寸兜底）。配合 SceneDelegate 的
//   呈现面自愈，修切后台再回前台的卡死/黑屏（对 zink/mg/所有渲染器生效）。
void CallbackBridge_resumeGameIfNeed(void);
// issue #27 修复（参照 FCL commit 08c0716）：物理键盘 modifier 同步
// 显式同步 MC 1.21.9+ 内部的 InputConstants modifier 缓存。
// 由 KeyboardInput.m 在物理键盘按下/释放事件中调用。
void CallbackBridge_syncModifiersToMC(int mods);
void CallbackBridge_queueModifierSync(int mods);

// ============================================================================
// Task 67（options.txt 移动键位净化 + Task66 状态数组对证）
// - ame67_sanitizeOptionsKeybinds：launchJVM 早期调用（MC 读 options.txt 前）。
//   dump 全部 key_key.* 行；把 forward/left/back/right/jump/sneak/sprint
//   七键中"存在且偏离默认"的行回归规范值（备份 options.txt.amethyst-bak）。
//   根因假设：输入损坏时代按键设置捕获对话框把垃圾事件写成键位（例如
//   forward 绑到 Shift），事件层全绿也救不了坏绑定。
// - Ame66GetKbState/Ame66GetKbNumKeys：暴露 Task66 直写的 SDL 键盘状态
//   数组指针，供 sdl3_hook 的 SDL_GetKeyboardState 钩子对证 MC 轮询侧
//   与写入侧是否同一块内存。
// ============================================================================
void ame67_sanitizeOptionsKeybinds(void);
const bool *Ame66GetKbState(void);
int Ame66GetKbNumKeys(void);

// ============================================================================
// Task141: launch-time memory resolution (single shared source of truth).
// Returns the JVM -Xmx in MB for the CURRENT selected instance: the
// per-instance memory slider (instance editor > Advanced > Memory) decides;
// when the profile carries no value (0), fall back to the same auto ratio
// as before (0.5 of physical memory with the memorystatus entitlement,
// 0.25 without). The global Settings rows java.auto_ram /
// java.allocated_memory are retired from the UI (user decree) — BOTH
// call sites (JavaLauncher -Xmx and SurfaceViewController Jetsam limit)
// MUST read through this helper so they stay in lockstep (Task68 lesson:
// mismatched Jetsam limit vs Xmx = launch-time SIGKILL).
// ============================================================================
int ame141_currentLaunchAllocMem(void);

// ============================================================================
// Task173: Jetsam-safe heap ceiling in MB for THIS process.
// Derived from os_proc_available_memory() (authoritative "bytes left before
// the process gets killed") minus a 1.2GB native reserve (JVM non-heap +
// renderer surfaces), floored at 1024MB; falls back to 60% of physical memory
// when the API is unavailable. ame141_currentLaunchAllocMem clamps every
// -Xmx through this (device session: 7165MB slider value = silent Jetsam
// SIGKILL 53s into a 244-mod pack load). Also used to cap the memory slider
// in ProfileSettingsViewController so users cannot pre-select doomed values.
// ============================================================================
int ame173_safeHeapCeilingMB(void);

// ============================================================================
// Task 187（iPhone 刘海/挖孔适配）：启动器为 iPad 设计的卡片布局用
// view 边缘 + 固定 outerMargin 定位；iPhone 横屏下左侧（或右侧，随设备
// 朝向）的刘海/挖孔 + 灵动岛会直接压住侧栏卡片内容。本助手返回
// 【仅 iPhone】的额外水平避让量（取 safeAreaInsets 对应边，iPad 恒 0
// ——iPad 主力机型零布局回归）。调用方把它加进 leading/trailing 边距：
//   constant = outerMargin + ame187_iphoneNotchInset(view, isLeading)
// 垂直边（状态栏已隐藏、home indicator 由不透明卡片背景自然覆盖）
// 维持既有对称 outerMargin 设计（Task "下面过宽" 修复的语义不变）。
// 游戏表面（SurfaceViewController surfaceView）不经此路径——真全面屏
// 全出血渲染不受影响。
// ============================================================================
double ame187_iphoneNotchInset(UIView *view, BOOL isLeading);

// ============================================================================
// Task 188（安装器目录杂散文件自愈）：递归建目录，路径上任意一级"目录位
// 置被同名普通文件占用"（历史安装失败残留）时自动移除后重建。
// 病历：NeoForge 26.1.2.109 安装时 libraries/net/neoforged/neoforge/
// 26.1.2.109 处的杂散文件令 universal jar 解压/下载双败而安装仍报成功
// → 启动报 "The NeoForge jar is missing"。返回 YES 当且仅当路径最终为
// 可用目录。供 NeoForgeDirectInstaller / ForgeDirectInstaller 全部
// 建目录点替换调用（含下载与解压落盘路径）。
// ============================================================================
BOOL ame188_ensureDirectoryHealed(NSString *path);

#ifdef __cplusplus
}
#endif
