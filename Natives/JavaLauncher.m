#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach.h>
#include "utils.h"
#include "ZinkConfig.h"

// god knows why Copilot was trying to add this.
#import "authenticator/BaseAuthenticator.h"
#import "authenticator/ThirdPartyAuthenticator.h"
#import "NMToast.h"
#import "CrashAnalyzer.h"   // Task218：崩溃识别引擎（hs_err 分型/渲染器归因）
// 鬼知道为什么copilot要把这玩意加里头……

#import "ios_uikit_bridge.h"
#import "StikDebugViewController.h" // Task294：内置 JIT 轨（jit_enabler=builtin / auto 优先）
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"
#import "ModService.h"   // Task225：隔离嗅探（与 ModService/ModsManager 同源）
#import "MinecraftResourceUtils.h"

#define fm NSFileManager.defaultManager

extern char **environ;

BOOL validateVirtualMemorySpace(size_t size) {
    size <<= 20; // convert to MB
    void *map = mmap(0, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    // check if process successfully maps and unmaps a contiguous range
    if(map == MAP_FAILED || munmap(map, size) != 0)
        return NO;
    return YES;
}

void init_loadDefaultEnv() {
    /* Define default env */

    // Silent Caciocavallo NPE error in locating Android-only lib
    setenv("LD_LIBRARY_PATH", "", 1);

    // Ignore mipmap for performance(?) seems does not affect iOS
    //setenv("LIBGL_MIPMAP", "3", 1);

    // Disable overloaded functions hack for Minecraft 1.17+
    setenv("LIBGL_NOINTOVLHACK", "1", 1);

    // Fix white color on banner and sheep, since GL4ES 1.1.5
    setenv("LIBGL_NORMALIZE", "1", 1);

    // Task205：日志等级（启动器设置"调试日志"行，general.debug_logging——复用既有键，
    // Task202 前它只控启动器侧 NSDebugLog，本轮起同时驱动渲染器诊断粒度）。
    // debug 级全线放宽渲染器诊断粒度：
    //   - vgpu：Task202 材质探针/Task189 绘制归因/Task193 四步归因/Task205
    //     墓碑的限频放宽 + realize_glenv 属性装配 tracer 上线（材质损坏/
    //     UV 错位类问题一击定位）
    //   - tinygl4angle：Task191/203/204 观察器扩容（首 N 次 → 更多）
    //   - 预编译 gl4es：开 LIBGL_LOGSHADERERROR（唯一可用杠杆，无源码）
    // 标准级保持既有限频，零额外开销。env 在 JVM 启动前设置，游戏会话
    // 全程生效；设置变更下次会话生效（行内 NSLog 已提示）。
    if (getPrefBool(@"general.debug_logging")) {
        setenv("AMETHYST_LOG_LEVEL", "debug", 1);
        setenv("LIBGL_LOGSHADERERROR", "1", 1);
        NSLog(@"[JavaLauncher] Task205: AMETHYST_LOG_LEVEL=debug (renderer diagnostics verbose)");
    } else {
        setenv("AMETHYST_LOG_LEVEL", "standard", 1);
    }

    // Override OpenGL version to 4.1 for Zink
    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);

    // Suppress [mvk-info] log spam (swapchain creation, etc.)
    // 对齐 Ynnyny 仓库：抑制 MoltenVK 日志刷屏，便于诊断启动问题
    // 但当帧率解锁开启时，临时启用性能跟踪以诊断 present mode 问题
    if (getPrefBool(@"video.disable_game_vsync")) {
        // 帧率解锁诊断：启用 MoltenVK 性能跟踪，输出帧率和 swapchain 信息
        // 有助于确认 Vulkan 模式下 present mode 是否为 IMMEDIATE
        setenv("MVK_CONFIG_PERFORMANCE_TRACKING", "1", 1);
        setenv("MVK_CONFIG_LOG_LEVEL", "2", 1); // 仍然抑制 info 级别，但 performance log 会输出
        // 尝试强制 present mode 为 IMMEDIATE（不等 vsync）。
        //
        // 核实结论（升级到 MoltenVK 1.4.2 时对比二进制确认）：
        // MVK_CONFIG_SWAPCHAIN_PRESENT_MODE 这个配置项在 MoltenVK 里并不存在——
        // 1.2.9 与 1.4.2 的 MVK_CONFIG_* 列表中都没有它（只有
        // MVK_CONFIG_SWAPCHAIN_MAG_FILTER_USE_NEAREST 等少数几项）。
        // 因此下面这行 setenv 当前不会生效，保留它只为前向兼容，不要依赖它。
        //
        // Vulkan 模式的帧率解锁实际由另两层完成（见下方"三层机制"注释）：
        //   1. Java 层：enableVsync=false + maxFps=260
        //   2. EGL 层：eglSwapInterval(0) → zink 据此选 IMMEDIATE present mode
        setenv("MVK_CONFIG_SWAPCHAIN_PRESENT_MODE", "0", 1);
        NSLog(@"[JavaLauncher] MoltenVK performance tracking + IMMEDIATE present mode requested for VSync diagnosis");
    } else {
        setenv("MVK_CONFIG_LOG_LEVEL", "2", 1);
    }

    // Runs JVM in a separate thread
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);

    // 解锁帧率（关闭垂直同步）：读取启动器偏好，通过环境变量传递给 Java 层和 native 桥接层。
    //
    // 帧率解锁的三层机制（各层独立生效，互为兜底）：
    //
    // 1. Java 层（PojavLauncher.java）读取 POJAV_DISABLE_VSYNC=1 后：
    //    a) 强制写 enableVsync=false → MC 不再调用 glfwSwapInterval(1)
    //    b) 强制写 maxFps=260 → MC 1.16+ 源码中 maxFps>=260 视为"无限制"
    //       （之前用 maxFps=0 会被 MC 当作无效值忽略，导致帧率仍被 maxFps=120 限制）
    //
    // 2. native 桥接层（egl_bridge.m pojavSwapInterval）读取 POJAV_DISABLE_VSYNC=1 后：
    //    拦截 MC 的 glfwSwapInterval(1) 请求，强制改为 interval=0
    //    （会记录每次拦截，帮助诊断 mod 运行时重新启用 VSync 的情况）
    //
    // 3. EGL 初始化层（gl_bridge.m gl_make_current）读取 POJAV_DISABLE_VSYNC=1 后：
    //    在 eglMakeCurrent 成功后立即调用 eglSwapInterval(0)。
    //    这是 zink 渲染器帧率解锁的关键——Mesa 21.0 的 zink 在延迟创建 Vulkan swapchain
    //    时根据当前 eglSwapInterval 选择 present mode：
    //      interval=0 → VK_PRESENT_MODE_IMMEDIATE_KHR（不等 vsync，帧率可超 60）
    //      interval=1 → VK_PRESENT_MODE_FIFO_KHR（等 vsync，锁在屏幕刷新率）
    //    如果等 MC 调用 glfwSwapInterval 时才设置，swapchain 可能已用 FIFO 创建，
    //    Mesa 21.0 的 zink 不会动态重建 swapchain，导致帧率锁死在屏幕刷新率。
    //
    // 关于 MoltenVK 配置与 Vulkan 帧率解锁研究：
    //   实际运行的 MoltenVK 版本为 1.4.3（Task309 恢复：用户实测 1.4.3 正常，
    //   WINDOW_IN_USE 双崩元凶实为帧率解锁钩子已整体回退退役；
    //   历史链 1.2.9 → 1.4.2 → 1.4.3（Task246 起，Task309 驳回 308 误伤回退））。
    //   设备是否支持 IMMEDIATE present mode 由 MVKPhysicalDeviceMetalFeatures.presentModeImmediate
    //   自动检测（大多数 iOS 设备支持）。
    //
    //   注意：MVK_CONFIG_SWAPCHAIN_PRESENT_MODE 并非 MoltenVK 的真实配置项，
    //   1.2.9 / 1.4.2 中均未实现，设置它不会改变 present mode。
    //
    //   Vulkan 模式帧率解锁的多层机制：
    //   1. MC 选项层：enableVsync=false + maxFps=260（MC 1.16+ 视 260 为 unlimited）
    //   2. EGL 层：eglSwapInterval(0) —— zink（GL→Vulkan）据此在创建 swapchain
    //      时选择 IMMEDIATE present mode，这是实际生效的那层
    //   3. MC 26.2 兼容：同时写入 maxFps/maxFramerate/framerateLimit 多种选项名
    //
    // 各渲染器的帧率解锁效果：
    // - zink（GL→Vulkan）：通过 eglSwapInterval(0) → IMMEDIATE present mode 完全解锁
    // - Vulkan（LWJGL3）：无环境变量可用，依赖 MC 自身 enableVsync=false；
    //                     若锁帧需配合渲染器切换到 zink 走 eglSwapInterval(0)
    // - ANGLE Metal：eglSwapInterval(0) 让 ANGLE 不等 vsync，渲染线程不阻塞
    // - ProMotion 设备：通过 CADisableMinimumFrameDurationOnPhone + preferredFrameRateRange 启用 120Hz
    setenv("POJAV_DISABLE_VSYNC", getPrefBool(@"video.disable_game_vsync") ? "1" : "0", 1);

    // 帧率解锁诊断日志：记录关键环境变量和偏好设置
    // Task300-r2 勘误：maximumFramesPerSecond 在 iPhoneOS26.2 SDK 是只读属性
    // （CI run 39225659390 "assignment to readonly property" 实锤）——它报告的是
    // 面板能力上限（本机 60Hz，iPad Air M4 非 ProMotion），不可赋值也不可突破。
    // 帧率解锁的完整能力面=渲染侧 presentMode=IMMEDIATE（ame298/300 双层钩子
    // 已 Task309 整体回退退役，装机定性为 WINDOW_IN_USE 双崩元凶；zink 路径
    // 不受影响），MC 侧 maxFps=260 与 EGL interval(0) 已在位；显示层无锁可解，
    // 此处仅落诊断值供装机日志对单。
    NSLog(@"[JavaLauncher] Framerate unlock configuration:");
    NSLog(@"[JavaLauncher]   video.disable_game_vsync=%d", getPrefBool(@"video.disable_game_vsync"));
    NSLog(@"[JavaLauncher]   POJAV_DISABLE_VSYNC=%s", getenv("POJAV_DISABLE_VSYNC"));
    NSLog(@"[JavaLauncher]   UIScreen.maximumFramesPerSecond=%d (readonly panel capability)", (int)UIScreen.mainScreen.maximumFramesPerSecond);
}

void init_loadCustomEnv() {
    NSString *envvars = getPrefObject(@"java.env_variables");
    if (envvars == nil) return;
    NSLog(@"[JavaLauncher] Reading custom environment variables");
    for (NSString *line in [envvars componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (![line containsString:@"="]) {
            NSLog(@"[JavaLauncher] Warning: skipped empty value custom env variable: %@", line);
            continue;
        }
        NSRange range = [line rangeOfString:@"="];
        NSString *key = [line substringToIndex:range.location];
        NSString *value = [line substringFromIndex:range.location+range.length];
        setenv(key.UTF8String, value.UTF8String, 1);
        NSLog(@"[JavaLauncher] Added custom env variable: %@", line);
    }
}

/// 加载 MobileGlues 配置并写入 config.json
///
/// 将用户偏好设置写入 <POJAV_HOME>/MG/config.json，供 MobileGlues 渲染器读取。
///
/// 渲染器与 MobileGlues 的关系（重要）：
/// - MobileGlues 渲染器（libmobileglues.dylib）：直接加载 MobileGlues，config.json 生效。
/// - MobileGL 家族（Task142 "mg" 逻辑键解析出的 libMobileGL / -gles / mithril）：
///   Task 144 起同样写入 config.json —— Task142 把渲染器层改成 "mg" 逻辑键后，
///   旧白名单（mobileglues/auto/vulkan）全部 miss，家族后端从未拿到 config.json
///   与 MG_DIR_PATH，用户在 MobileGlues 分区改的全部偏好（no_error / multidraw /
///   FSR 等）对 mg 会话静默失效（装机日志 20:39/20:40 会话
///   "MobileGlues config not written (renderer is not mobileglues/auto/vulkan)"）。
///   本函数改读 ame_effective_renderer()（解析后的家族物理键），家族键入白名单。
/// - Auto 渲染器：Task 144 起在 launchJVM 中按 MC 版本解析 —— 1.17+ 优先
///   MobileGL（Vulkan 直连，装机验证最快路径，dylib 缺失回退 ANGLE），
///   旧版本仍 ANGLE。渲染器为 auto 时 MobileGlues 不会被加载，config.json
///   虽然会写入但不会被读取（保持既有语义）。
/// - Vulkan 渲染器：Vulkan 模式下 OpenGL 回退库使用 MobileGlues（对齐 Ynnyny 仓库），
///   config.json 会被 MobileGlues 读取并生效。
/// Task 130：导出 FSR1 RCAS 锐化强度环境变量并返回规整后的值。
/// 偏好键 mobileglues.fsr_rcas_sharpness 是唯一用户入口（PLPreferences 默认值
/// 表提供 0.2）。mpv 口径 [0,1] 越大越锐；负值 = 显式关闭（仅 EASU）；
/// NaN/越界回默认 0.2。三路分发同源：
///   ① MobileGlues 渲染器：config.json 的 fsr1RcasSharpness（settings.cpp 读，
///      本函数返回值写入）；
///   ② MobileGL/zink 路径：环境变量 AMETHYST_FSR_RCAS_SHARPNESS
///      （mgl_fsr.mm / osm_bridge.mm 的 ame130_rcas_sharpness 解析）；
///   ③ setenv 在所有渲染器路径导出（含上方 usesMobileGlues 早退分支）。
/// setenv 内部拷贝字符串，临时 NSString 的 UTF8String 无悬垂问题。
static double ame130_export_rcas_env(void) {
    id sharpObj = getPrefObject(@"mobileglues.fsr_rcas_sharpness");
    double sharpness = 0.2;
    if ([sharpObj isKindOfClass:NSNumber.class]) {
        sharpness = [(NSNumber *)sharpObj doubleValue];
    } else if ([sharpObj isKindOfClass:NSString.class]) {
        // Task 130：设置页 pick 行存字符串（pickKeys 如 @"0.2" / @"-1"）；
        // 默认表则是 NSNumber @0.2——双态解析， stringValue 相同语义。
        sharpness = [(NSString *)sharpObj doubleValue];
    }
    if (!(sharpness >= -1.0 && sharpness <= 1.0) || sharpness != sharpness) {
        sharpness = 0.2;   // NaN/超出 [-1,1] 回默认
    }
    setenv("AMETHYST_FSR_RCAS_SHARPNESS",
           [[NSString stringWithFormat:@"%.4f", sharpness] UTF8String], 1);
    NSLog(@"[JavaLauncher] Task130: AMETHYST_FSR_RCAS_SHARPNESS=%.4f exported (RCAS sharpness, mpv scale, default 0.2, negative = off)", sharpness);
    return sharpness;
}

void init_loadMobileGluesConfig() {
    // Task 144：改读 ame_effective_renderer()（单一事实源）而非裸 profile 键。
    // Task142 后 profile 存的是 "mg" 逻辑键，旧白名单永远 miss；解析后拿到的
    // 是家族物理键（libMobileGL / -gles / mithril），与"auto"同表判断。
    NSString *renderer = ame_effective_renderer();
    NSLog(@"[JavaLauncher] init_loadMobileGluesConfig: renderer=%@", renderer);

    BOOL usesMobileGlues = [renderer isEqualToString:@ RENDERER_NAME_MOBILEGLUES] ||
        [renderer isEqualToString:@"auto"] ||
        [renderer isEqualToString:@ RENDERER_NAME_VULKAN] ||
        [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL] ||
        [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL_GLES] ||
        [renderer isEqualToString:@ RENDERER_NAME_MITHRIL];

    if (!usesMobileGlues) {
        NSLog(@"[JavaLauncher] MobileGlues config not written (renderer is not mobileglues/auto/vulkan/mgfamily)");
        // Task 130：config.json 不写，但 RCAS 锐化环境变量仍需导出——
        // zink / MobileGL 路径的 mgl_fsr.mm / osm_bridge.mm 读的是
        // AMETHYST_FSR_RCAS_SHARPNESS（与渲染器无关的统一出口）。
        ame130_export_rcas_env();
        return;
    }

    // 警告：auto 渲染器（mg 后端=Vulkan 直连/默认时保持 auto）按 MC 版本解析
    // Task144/161：1.17+ → libMobileGL（Vulkan 直连，config.json 不读，
    // MobileGlues 分区偏好在两端 inert 但无害）；≤1.16 → ANGLE。需要
    // MobileGlues 完整配置（含 FSR1 联动）请选 GLES / OpenGL 4.0 后端
    // （Task161 起 auto 同样跟随后端键，见 ame_effective_renderer）。
    if ([renderer isEqualToString:@"auto"]) {
        NSLog(@"[JavaLauncher] renderer 'auto' (mg backend = Vulkan direct / default): "
              @"resolved per MC version (1.17+ -> libMobileGL, else ANGLE). "
              @"MobileGlues config is inert on libMobileGL. Pick the GLES / "
              @"OpenGL 4.0 backend for MobileGlues + FSR1 (Task161 auto-follows the backend key).");
    } else if ([renderer isEqualToString:@ RENDERER_NAME_VULKAN]) {
        NSLog(@"[JavaLauncher] Vulkan renderer detected, MobileGlues used as GL fallback. Config will take effect.");
    } else {
        NSLog(@"[JavaLauncher] MobileGlues renderer detected, config will take effect.");
    }

    NSString *mgDirPath = [NSString stringWithFormat:@"%s/MG", getenv("POJAV_HOME")];
    setenv("MG_DIR_PATH", mgDirPath.UTF8String, 1);

    NSMutableDictionary *config = [NSMutableDictionary dictionary];

    // 安全默认值
    // 注意：MobileGlues 的 Version(int code) 构造函数把数字转为字符串后取前 3 位
    // 作为 Major.Minor.Patch（settings.h 第 102-116 行）。例如 40 → "40" → 4.0.0。
    // customGLVersion 约束（settings.cpp 第 71-79 行）：>46 截断为 46，<32 且非 0 截断为 32，
    // 33-39 截断为 33，0 使用默认值 40。
    // 因此必须写入十进制数（40, 41, 42, ..., 46），不能写入十六进制 0x040000。
    //
    // Task 166：DSA 默认改为【关】。三会话 A/B 实锤（同机同模组包同
    // MobileGlues 2.0.17）：9e6fc27 两档（latestlog.es/.4.0，
    // enable_ext_direct_state_access=0）→ "DSA support not detected" →
    // 全程可玩 + FSR 生效；Task158 后的会话（cc9bfe4 双黑 + 3368468 新黑，
    // =1）→ "ARB_direct_state_access detected, enabling DSA" → 黑屏
    // （swap 100% 健康 + render-texture 探针全零 + 首秒固定 10 次一次性
    // "No context is current"）。机理：MobileGlues 2.0.17 的 DSA 是
    // DSAWrapper 模拟层（temporarilyBindFramebuffer 的状态往返在 FSR1
    // fb0 重定向下的自洽性未经上游验证，上游 core 仓后续才有“stop asking
    // the driver what we know”类的 DSA 状态修复），MC 26.x 的 DSA 路径
    // 一旦激活即不再走经典路径。Task129d 开启它的性能依据来自 zink 会话
    // （Mesa 原生 DSA，与 MobileGlues 无关）。用户偏好分区
    // mobileglues.enable_ext_direct_state_access 仍可强制开回（下方覆盖链）。
    config[@"enableExtDirectStateAccess"] = @0;
    config[@"maxGlslCacheSize"] = @128;
    // 默认 GL 4.0（MobileGlues 2.0.0 DEFAULT_GL_VERSION=40，
    // 内置 glslang+SPIRV-Cross 从源码编译，GLSL→SPIRV→ESSL 转换链可靠工作）
    config[@"customGLVersion"] = @40;

    // Task 158：mg 家族 GLES / OpenGL 4.0 后端重映射到 MobileGlues 后的
    // 配置强制（5.1.0 正式版同款形态——9e6fc27 装机日志 latestlog.es /
    // latestlog.4.0 实证两档全程可玩且 FSR 生效）。
    //   mode 1（mg GLES 后端）：enableANGLE=3（ForceEnable，绕过 iOS 上
    //     hasVulkan12()==0 的 ANGLE 支持检测）+ customGLVersion=32——ANGLE
    //     在 iOS 的实际上限是 GLES 3.0/3.1，桌面 GLSL（#version 400）会被
    //     ANGLE 编译器拒收导致方块不渲染（5.1.0 时代的同款修复）；
    //   mode 2（mg OpenGL 4.0 后端）：enableANGLE=0（DisableIfPossible →
    //     MobileGlues 自有 glslang→SPIRV→ESSL 转译链）+ customGLVersion=40；
    //   mode 0：独立 MobileGlues 直选或 mg+Vulkan 直连——不强制，
    //     mobileglues.custom_gl_version 用户分区偏好照常透传（5.1.0 语义；
    //     Vulkan 直连下 libMobileGL 不读 config.json，Task153 strings 实证，
    //     写入无害）。
    // 模式来自 ame158_mg_mobileglues_mode()（存储层判定，与
    // ame_effective_renderer 的 mg→libmobileglues 重映射天然一致）。
    int ame158_mode = ame158_mg_mobileglues_mode();
    if (ame158_mode == 1) {
        config[@"enableANGLE"] = @3;
        config[@"customGLVersion"] = @32;
        NSLog(@"[JavaLauncher] Task158: mg GLES backend -> MobileGlues (enableANGLE=3 ForceEnable, customGLVersion=32; 5.1.0 semantics, FSR1 linkage follows fsr1_setting)");
    } else if (ame158_mode == 2) {
        config[@"enableANGLE"] = @0;
        config[@"customGLVersion"] = @40;
        NSLog(@"[JavaLauncher] Task158: mg OpenGL 4.0 backend -> MobileGlues (enableANGLE=0, customGLVersion=40; 5.1.0 semantics, FSR1 linkage follows fsr1_setting)");
    }

    id enableNoError = getPrefObject(@"mobileglues.enable_no_error");
    if (enableNoError) {
        config[@"enableNoError"] = @([enableNoError intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.enable_no_error = %@ -> enableNoError = %@", enableNoError, config[@"enableNoError"]);
    }

    id enableExtTimerQuery = getPrefObject(@"mobileglues.enable_ext_timer_query");
    if (enableExtTimerQuery) {
        config[@"enableExtTimerQuery"] = [enableExtTimerQuery boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_timer_query = %@ -> enableExtTimerQuery = %@", enableExtTimerQuery, config[@"enableExtTimerQuery"]);
    }

    id enableExtComputeShader = getPrefObject(@"mobileglues.enable_ext_compute_shader");
    if (enableExtComputeShader) {
        config[@"enableExtComputeShader"] = [enableExtComputeShader boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_compute_shader = %@ -> enableExtComputeShader = %@", enableExtComputeShader, config[@"enableExtComputeShader"]);
    }

    id enableExtDirectStateAccess = getPrefObject(@"mobileglues.enable_ext_direct_state_access");
    if (enableExtDirectStateAccess) {
        config[@"enableExtDirectStateAccess"] = [enableExtDirectStateAccess boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.enable_ext_direct_state_access = %@ -> enableExtDirectStateAccess = %@", enableExtDirectStateAccess, config[@"enableExtDirectStateAccess"]);
    }

    id maxGlslCacheSize = getPrefObject(@"mobileglues.max_glsl_cache_size");
    if (maxGlslCacheSize) {
        config[@"maxGlslCacheSize"] = @([maxGlslCacheSize intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.max_glsl_cache_size = %@ -> maxGlslCacheSize = %@", maxGlslCacheSize, config[@"maxGlslCacheSize"]);
    }

    id multidrawMode = getPrefObject(@"mobileglues.multidraw_mode");
    if (multidrawMode) {
        // Task 79（借鉴调研落地）：MG 2.0.16 起多重绘制后端选择改为"优先序"
        // 机制——config 键 multidrawOrder（逗号分隔、best-first，全局序可含
        // 伪项 native=各入口同形的 GLES core/EXT 函数；每入口可用
        // multidrawOrder<EntryPoint> 覆盖）。旧的 multidrawMode 整数键已被
        // 弃用：settings.cpp 只打 legacy 警告、从不读取——此前这里写进去的
        // 值一直是静默 no-op（用户在 UI 里切"间接/模拟"毫无效果）。
        // 三个既有档位映射为等价的优先序（与 settings.cpp 的默认序对齐）：
        //   0 Auto     = MG 默认序：native/EXT 优先，单调用批量后端优先于
        //                逐子绘制循环，compute 垫底
        //   1 Indirect = 间接族优先：multiindirect/indirect 打头（GPU 整批
        //                提交，转译开销最小），不用 native 伪项
        //   2 Emulated = CPU 循环优先：unroll/basevertex 打头（最保守，驱动
        //                缺扩展时的兜底形态）
        NSString *mdOrder = nil;
        switch ([multidrawMode intValue]) {
            case 1:
                mdOrder = @"multiindirect,indirect,multibasevertex,multiarrays,basevertex,unroll,compute";
                break;
            case 2:
                mdOrder = @"unroll,basevertex,indirect,multiindirect,multibasevertex,multiarrays,compute";
                break;
            default:
                mdOrder = @"native,multiindirect,multibasevertex,multiarrays,indirect,basevertex,unroll,compute";
                break;
        }
        config[@"multidrawOrder"] = mdOrder;
        NSLog(@"[JavaLauncher]   mobileglues.multidraw_mode = %@ -> multidrawOrder = %@ (旧键 multidrawMode 已被 MG 2.0.16+ 弃用，不再写入)",
              multidrawMode, mdOrder);
    }

    id angleDepthClearFixMode = getPrefObject(@"mobileglues.angle_depth_clear_fix_mode");
    if (angleDepthClearFixMode) {
        config[@"angleDepthClearFixMode"] = [angleDepthClearFixMode boolValue] ? @1 : @0;
        NSLog(@"[JavaLauncher]   mobileglues.angle_depth_clear_fix_mode = %@ -> angleDepthClearFixMode = %@", angleDepthClearFixMode, config[@"angleDepthClearFixMode"]);
    }

    // Task 158：mg 重映射会话（mode 1/2）下，ANGLE/GL 版本轴由后端选择独占
    //（这正是后端浮窗的语义），custom_gl_version 用户偏好只在 mode 0 生效。
    id customGlVersion = (ame158_mode == 0) ? getPrefObject(@"mobileglues.custom_gl_version") : nil;
    if (customGlVersion) {
        NSString *verStr = [customGlVersion description];
        NSLog(@"[JavaLauncher]   mobileglues.custom_gl_version = %@ (raw)", customGlVersion);
        // MobileGlues 期望十进制数：Version(int code) 把 code 转字符串后取前 3 位作为
        // Major.Minor.Patch。例如 40 → "40" → 4.0.0，46 → "46" → 4.6.0。
        // 不能用十六进制 0x040000（=262144），会被截断为 46（4.6.0）。
        if ([verStr isEqualToString:@"3.0"]) config[@"customGLVersion"] = @30;
        else if ([verStr isEqualToString:@"3.1"]) config[@"customGLVersion"] = @31;
        else if ([verStr isEqualToString:@"3.2"]) config[@"customGLVersion"] = @32;
        else if ([verStr isEqualToString:@"3.3"]) config[@"customGLVersion"] = @33;
        else if ([verStr isEqualToString:@"4.0"]) config[@"customGLVersion"] = @40;
        else if ([verStr isEqualToString:@"4.1"]) config[@"customGLVersion"] = @41;
        else if ([verStr isEqualToString:@"4.2"]) config[@"customGLVersion"] = @42;
        else if ([verStr isEqualToString:@"4.3"]) config[@"customGLVersion"] = @43;
        else if ([verStr isEqualToString:@"4.4"]) config[@"customGLVersion"] = @44;
        else if ([verStr isEqualToString:@"4.5"]) config[@"customGLVersion"] = @45;
        else if ([verStr isEqualToString:@"4.6"]) config[@"customGLVersion"] = @46;
        // verStr == @"0" 时不匹配任何条件，保留默认值 @40（即 GL 4.0）
        NSLog(@"[JavaLauncher]   -> customGLVersion = %d (decimal, MobileGlues Version(int) format)",
              [config[@"customGLVersion"] intValue]);
    }

    id fsr1Setting = getPrefObject(@"mobileglues.fsr1_setting");
    if (fsr1Setting) {
        config[@"fsr1Setting"] = @([fsr1Setting intValue]);
        NSLog(@"[JavaLauncher]   mobileglues.fsr1_setting = %@ -> fsr1Setting = %@", fsr1Setting, config[@"fsr1Setting"]);
    }

    // Task 130：FSR1 RCAS 锐化强度写入 MobileGlues config（fsr1RcasSharpness，
    // settings.cpp 读）；环境变量同步导出（ame130_export_rcas_env，见函数定义处
    // 的三路分发注释）。
    config[@"fsr1RcasSharpness"] = @(ame130_export_rcas_env());

    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData) {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [fm createDirectoryAtPath:mgDirPath withIntermediateDirectories:YES attributes:nil error:nil];
        [jsonString writeToFile:[mgDirPath stringByAppendingPathComponent:@"config.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSLog(@"[JavaLauncher] MobileGlues config written to %@/config.json", mgDirPath);
        NSLog(@"[JavaLauncher] config.json content:\n%@", jsonString);
    } else {
        NSLog(@"[JavaLauncher] Failed to serialize MobileGlues config: %@", error);
    }
}

/// ★ Task256（清单 8）：JVM 预设单一事实源解析——profile.jvm_preset（版本
///   设置页"JVM 预设"行，实例级覆写）→ java.jvm_preset（全局设置页）→
///   @"normal"。init_loadCustomJvmFlags 的 custom 参数注入与 launchJVM 的
///   GC 段注入两处共用，解析永不漂移。
///   ★ Task285（用户定案"肯定是版本设置的jvm预设优先"）：Task284 的
///   performance 升格【撤销】——global=performance 不再盖过实例非定制
///   值，恢复 profile → global → normal 原序（custom 任一层声明仍最高）。
///   病历复盘：Task284 误判"用户全局选了性能优先被实例压制"，装机日志
///   (a94669c) 实锤全局 java.jvm_preset 根本不存在（"Getter could not
///   find preference java.jvm_preset"）——用户是在版本设置里选了 memory，
///   版本设置优先本就是既定设计；要性能优先应在 版本设置 → 高级 → JVM
///   预设 选"性能优先"（Task256 已提供该档，选中即生效）。本轮另加
///   来源日志：生效预设 + 来源层 + 双层冲突提示，下轮日志一眼定音。
static NSString *ame256_effectiveJvmPreset(void) {
    NSString *ame256_profile = [PLProfiles resolveKeyForCurrentProfile:@"jvm_preset"];
    NSString *ame256_global = getPrefObject(@"java.jvm_preset");
    BOOL ame284_profileValid = [ame256_profile isKindOfClass:[NSString class]] && ame256_profile.length > 0;
    BOOL ame284_globalValid = [ame256_global isKindOfClass:[NSString class]] && ame256_global.length > 0;
    // custom 档 = 用户显式自管参数，保持最高优先（任一层声明即生效）
    if ([ame256_profile isEqualToString:@"custom"] || [ame256_global isEqualToString:@"custom"]) {
        return @"custom";
    }
    // ★ Task285：恢复 profile（版本设置）优先原序——Task284 performance
    //   升格撤销（用户定案"版本设置的jvm预设优先"）。
    if (ame284_profileValid) {
        static dispatch_once_t ame256_once;
        dispatch_once(&ame256_once, ^{
            NSLog(@"[JavaLauncher] Task285: JVM preset='%@' (source=profile/版本设置; global=%@%@" ,
                  ame256_profile,
                  ame284_globalValid ? ame256_global : @"<unset>",
                  ame284_globalValid ? @", unused -- 版本设置优先)" : @")");
            if (ame284_globalValid && ![ame256_global isEqualToString:ame256_profile]) {
                NSLog(@"[JavaLauncher] Task285: preset conflict profile='%@' vs global='%@' -- profile wins (版本设置优先); switch in 版本设置→高级→JVM 预设 if intended",
                      ame256_profile, ame256_global);
            }
        });
        return ame256_profile;
    }
    if (ame284_globalValid) {
        static dispatch_once_t ame285_once;
        dispatch_once(&ame285_once, ^{
            NSLog(@"[JavaLauncher] Task285: JVM preset='%@' (source=global/全局设置)", ame256_global);
        });
        return ame256_global;
    }
    return @"normal";
}

void init_loadCustomJvmFlags(int* argc, const char** argv) {
    // ★ Task255（清单 11）：JVM 预设 custom 档的自定义参数注入。
    //   java.jvm_preset=custom 时，java.jvm_preset_custom_args 的内容与
    //   javaArgs 同链注入（同 purge 规则：Xms/Xmx/d32/d64 由启动器内存
    //   分配体系独占，用户侧重复指定会被忽略并记日志）。
    static NSMutableArray<NSString *> *retainedCustomFlags = nil;
    if (retainedCustomFlags == nil) {
        retainedCustomFlags = [NSMutableArray array];
    }
    // 注意：不清空 retainedCustomFlags，因为 launchJava 在进程生命周期内只调用一次。
    // 如果未来变为可多次调用，需要在调用前清空。

    void (^ame255_pushFlag)(NSString *) = ^(NSString *jvmarg) {
        if (jvmarg.length == 0) return;
        NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                return;
            }
        }
        if (*argc + 1 >= 1000) {
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding custom JVM flag: -%@", jvmarg);
            return;
        }
        NSString *flagStr = [@"-" stringByAppendingString:jvmarg];
        [retainedCustomFlags addObject:flagStr];
        ++*argc;
        argv[*argc] = flagStr.UTF8String;
        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
    };

    /* ★ Task256（清单 8）：实例级覆写优先——profile.jvm_preset（版本设置
       页"JVM 预设"行）有值时盖过全局 java.jvm_preset；无键回退全局
       （行为与 Task255 全量一致）。ame256_effectiveJvmPreset 同时供 GC
       注入点复用，两处解析永不漂移。 */
    NSString *ame255_preset = ame256_effectiveJvmPreset();
    BOOL ame255_custom = [ame255_preset isKindOfClass:[NSString class]] &&
                         [ame255_preset isEqualToString:@"custom"];
    if (ame255_custom) {
        NSString *ame255_customArgs = getPrefObject(@"java.jvm_preset_custom_args");
        if ([ame255_customArgs isKindOfClass:[NSString class]] &&
            ame255_customArgs.length > 0) {
            ame255_customArgs = [ame255_customArgs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            NSLog(@"[JavaLauncher] Task255: JVM preset=custom -- injecting jvm_preset_custom_args");
            for (NSString *arg in [ame255_customArgs componentsSeparatedByString:@" "]) {
                ame255_pushFlag([arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]);
            }
        } else {
            NSLog(@"[JavaLauncher] Task255: JVM preset=custom but jvm_preset_custom_args empty (GC tuning skipped, JVM defaults apply)");
        }
    }

    NSString *jvmargs = [PLProfiles resolveKeyForCurrentProfile:@"javaArgs"];
    if (jvmargs == nil) return;
    // Make the separator happy
    jvmargs = [jvmargs stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    jvmargs = [@" " stringByAppendingString:jvmargs];

    // 关键修复（N3+N4）：retainedCustomFlags 强引用所有自定义 JVM flag 字符串，
    // 防止 [@"-" stringByAppendingString:jvmarg].UTF8String 返回的 C 字符串悬垂。
    //
    // 之前 argv[*argc] = [@"-" stringByAppendingString:jvmarg].UTF8String 直接取临时
    // NSString 的 UTF8String，autoreleased NSString 在 runloop drain 后会释放，
    // 导致 argv 中的指针悬垂。虽然 launchJava 通常在 JVM 启动前不会 drain autoreleasepool，
    // 但这是脆弱的隐式依赖。retainedCustomFlags 作为静态变量，生命周期覆盖整个进程，
    // 保证字符串在 pJLI_Launch 调用期间有效。

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        ame255_pushFlag(jvmarg);
    }
}

// 进程内 JVM 只能创建一次（第二次 JLI_Launch 会崩溃）。
// launchJVM 与 launchHeadlessJVM 在调用 JLI_Launch 前都会置位；
// launchJVM 检测到该标记时拒绝再次创建 JVM 并引导用户重启 app。
static BOOL gJvmUsedInProcess = NO;

BOOL JVMUsedInProcess(void) {
    return gJvmUsedInProcess;
}

// Task98：从任意形态的版本 ID 提取 MC 主版本号（年份制口径）。
//
// 病历（2af8c45 装机日志，6c3d49d 构建，MC 26.3 Fabric 整合包 110 mods，
// MG/zink 渲染器无关，iPad Air M4）：版本 ID 是 Fabric 形态
// "fabric-loader-0.19.5-26.3-e4ecd7db"，旧解析按 "." 切分取 parts[0] =
// "fabric-loader-0"（intValue=0）→ 错选 LWJGL 333 → lwjgl-341 集合里的
// lwjgl-sdl.jar（org.lwjgl.sdl.*，MC 26.3 的 NativeLibrariesBootstrap 第五个
// 加载项）不在 classpath → NoClassDefFoundError: org/lwjgl/sdl/SDL →
// "Loading library SDL" 崩溃。此前所有 26.3 装机会话（26.3-pre/rc、zink/MG
// SDL3 基建验证）都是原版形态 ID（"26.3-rc2" 以 "26" 开头），旧解析恰好正确，
// Fabric 整合包首次暴露盲区。
//
// 解析口径（两层，与 ForgeDirectInstaller/ModpackImportService 的年份锚定
// 先例同族，含两处为 LWJGL 选择专门加的防误伤）：
//   1) 1.x 谱系优先短路（返回 1）：命中 "(?:^|[-_])1\.\d" 即认定 1.x 线。
//      既覆盖 "1.20.1"，也覆盖 "fabric-loader-0.19.3-1.20.1-9c2ee306"；更重要
//      的是挡住 "1.20.1-forge-47.3.0" 里 forge 构建号（47.x）被年份正则误读
//      为 >= 26（旧解析对这类 ID 取 parts[0]="1" 同样回落 333，行为不变）。
//   2) 年份制主版本：锚定在串首或 [-_] 之后的两位数字，后随 "." 或 "w"+数字
//      （"(?:^|[-_])(\d{2})(?=[.w])"）：
//        "26.3" → 26；"26.2-rc1" → 26；"26w14a"（快照）→ 26；
//        "fabric-loader-0.19.5-26.3-e4ecd7db" → 26（"-26." 命中）；
//        "25w45a" → 25（<26，放行 333）。
//      [-_] 锚定 + 后随 [.w] 共同排除两类误伤：loader 版本段 "0.19.5" 的 "19"
//      前面是 "."（非锚点）；十六进制哈希段（如 "e4ecd7db"、假想的 "26f3a1b2"）
//      不含 "."，'w' 也绝不出现在十六进制里。
NSInteger ame98_mcMajorFromVersionId(NSString *versionId) {
    if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) {
        return 0;
    }
    // (1) 1.x 谱系短路。
    NSRegularExpression *legacyRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:^|[-_])1\\.\\d" options:0 error:nil];
    if ([legacyRegex firstMatchInString:versionId
                                options:0
                                  range:NSMakeRange(0, versionId.length)]) {
        return 1;
    }
    // (2) 年份制主版本。
    NSRegularExpression *yearRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(?:^|[-_])(\\d{2})(?=[.w])" options:0 error:nil];
    NSTextCheckingResult *match = [yearRegex firstMatchInString:versionId
                                                        options:0
                                                          range:NSMakeRange(0, versionId.length)];
    if (match && match.numberOfRanges >= 2) {
        return [[versionId substringWithRange:[match rangeAtIndex:1]] integerValue];
    }
    return 0;
}

// 解析 profile 的 lwjglVersion 设置为具体的 LWJGL 版本：
//   "333" / "341" -> 原样使用
//   "auto"        -> MC 26.x 及以上用 3.4.1，其余用 3.3.3
//
// MC 26.3 起窗口与键盘系统从 GLFW 迁到 SDL3，只有 3.4.1 带真正的 SDL3 绑定
// （lwjgl-sdl.jar 加载真实 libSDL3），因此 26.x 及以上必须选 341。
// Task98：版本号提取改用 ame98_mcMajorFromVersionId（Fabric/NeoForge/Forge
// 前缀形态的 ID 也能读到真实 MC 主版本，详见其头注释）。
static NSString *ResolveLwjglVersion(NSString *profileValue, NSString *mcVersionId) {
    if ([profileValue isEqualToString:@"333"] || [profileValue isEqualToString:@"341"]) {
        return profileValue;
    }
    NSInteger mcMajor = ame98_mcMajorFromVersionId(mcVersionId);
    if (mcMajor >= 26) {
        NSLog(@"[LWJGLSel] Task98: MC major %ld extracted from version id \"%@\" -> LWJGL 341 (SDL3 bindings)",
              (long)mcMajor, mcVersionId);
        return @"341";
    }
    return @"333";
}

// 把 "libXxx.dylib" 形式的磁盘文件名转成 LWJGL 期望的"裸名"（"Xxx"）。
//
// LWJGL 加载 native 库时（Platform.mapLibraryName 的 macOS 分支）先用正则
//     (?:^|/)lib\w+(?:[.]\d+)*[.]dylib$
// 判断传入的 libname 是否"已经是 dylib 文件名"：是则原样使用，否则交给
// System.mapLibraryName 补 "lib" 前缀与 ".dylib" 后缀。
//
// 问题在 \w 不含连字符：像 "libMobileGL-gles.dylib" 这种带 '-' 的文件名反而不匹配该
// 正则，被当成裸名再补一层 -> "liblibMobileGL-gles.dylib.dylib"，磁盘上没有这个文件，
// 于是 UnsatisfiedLinkError。名字里没有连字符的库（mobileglues / OSMesa.8 / gl4es_114
// / MobileGL / MoltenVK 等）恰好都能匹配，所以长期只有 GLES 这一个库受影响。
//
// 传裸名则一定安全：裸名不以 "lib" 开头，必定不匹配该正则，统一走 System.mapLibraryName
// 补回前缀后缀，结果与磁盘文件名逐字一致，且不依赖文件名里是否有特殊字符。
static NSString *lwjglBareLibName(const char *fileName) {
    if (fileName == NULL) {
        return nil;
    }
    NSString *name = [NSString stringWithUTF8String:fileName];
    // "lib".length == 3，".dylib".length == 6，合计 9。
    if (name.length > 9 && [name hasPrefix:@"lib"] && [name hasSuffix:@".dylib"]) {
        return [name substringWithRange:NSMakeRange(3, name.length - 9)];
    }
    // 不是标准命名（例如别名）就原样返回，保持原有行为。
    return name;
}

// Task 87：桌面弹窗类 mod 预检 ----------------------------------------------
// 病历（7b88b69 latestlog.old.txt，6054498 构建，BMC2 [FABRIC] 1.20.1，537 mods）：
// 整合包主线程在 Fabric setupLanguageAdapters 的 Class.forName 阶段被
// toni.missingmodschecker.MissingModsWindow.open 的 Object.wait() 硬阻塞
// （[LaunchWatchdog] Task86 两个采样实证，用户 30s 后强制取消，"卡在启动界面"）。
// MissingModsChecker 是 CurseForge/Modrinth 上的正规桌面工具 mod：检测到缺失依赖
// 时弹 Swing 窗口等待用户点击确认。iOS 上该窗口永远无法显示 → 无限阻塞。
// 而 Fabric 自身的依赖解析此时已完成（本例仅 2 条 recommends 级警告，无硬缺失），
// 弹窗纯属桌面端体验增强——去掉它整合包照常启动。
//
// 对策：JVM 启动前扫描 mods 目录，把实证的"桌面弹窗类"mod 改名为 .jar.disabled
// （Fabric 只加载 .jar 结尾的文件；想恢复把文件名改回即可）。
// 名单原则：只收真机实证过的案犯，宁缺毋滥——missingmodschecker 是叶子工具
// mod（依赖树里没有任何 mod 依赖它），禁用不会破坏依赖解析。
// ★ Task225（反馈 #2：ANGLE 非 SDL 版本报错——实为 assets 缺文件）：
// 02a3fe1 日志集 latestlog.txt（1.20.1 + tinygl4angle）铁证：渲染链健康
//（37 帧 swap、深度格式重映射生效），死亡点 = enn.<init> 资源加载时
// java.nio.file.NoSuchFileException:
// .../assets/objects/f0/f0065754...——assets 个体文件缺失（下载中断/被
// 清理），MC 1.20.1 直接崩（不会自补）。修法：JVM 启动前的【资源完整性
// 预检 + 自动补齐】——读 assets/indexes/<id>.json，逐 object stat，
// 缺失者从官方资源服串行补下（预算 20s / 上限 300 个；超限只告警不强撑，
// 下轮继续补）。镜像走 PLMirrorCenter 不引入（预检路径保持零依赖）。
static int ame225_healMissingAssets(NSString *versionId) {
    if (versionId.length == 0) return 0;
    const char *gameRootC = getenv("POJAV_GAME_DIR");
    if (!gameRootC || !*gameRootC) return 0;
    NSString *gameRoot = [NSString stringWithUTF8String:gameRootC];

    // 1. 版本 JSON → assets 索引名（"assets" 字段，如 "5"）
    NSString *versionJsonPath = [gameRoot stringByAppendingPathComponent:
        [NSString stringWithFormat:@"versions/%@/%@.json", versionId, versionId]];
    NSDictionary *versionJson = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:versionJsonPath] options:0 error:nil];
    NSString *indexId = [versionJson isKindOfClass:[NSDictionary class]]
        ? versionJson[@"assets"] : nil;
    if (![indexId isKindOfClass:[NSString class]] || indexId.length == 0) {
        return 0;  // 老版本/异常 JSON：无从预检，交给既有流程
    }

    // 2. 索引 JSON → objects
    NSString *indexPath = [gameRoot stringByAppendingPathComponent:
        [NSString stringWithFormat:@"assets/indexes/%@.json", indexId]];
    NSDictionary *indexJson = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:indexPath] options:0 error:nil];
    NSDictionary *objects = [indexJson isKindOfClass:[NSDictionary class]]
        ? indexJson[@"objects"] : nil;
    if (![objects isKindOfClass:[NSDictionary class]] || objects.count == 0) {
        return 0;  // 索引缺失（全新安装会整包下载）或形状异常
    }

    // 3. 逐 object stat，收集缺失
    NSFileManager *ame225_fm = [NSFileManager defaultManager];
    NSMutableArray<NSDictionary *> *missing = [NSMutableArray array];
    NSUInteger checked = 0;
    for (NSString *name in objects) {
        NSDictionary *obj = objects[name];
        NSString *hash = [obj isKindOfClass:[NSDictionary class]] ? obj[@"hash"] : nil;
        if (![hash isKindOfClass:[NSString class]] || hash.length < 4) continue;
        checked++;
        // ★ Task226（反馈 #2：非 SDL 版本报错——"Couldn't set icon" +
        // NoSuchFileException 堆栈）：旧实现按"安装器同款约定"跳过
        // icons/minecraft.icns（省流量的历史习惯），但 Mac 伪装平台下
        // MC 1.20.1 的 Minecraft 构造器会读它（java.nio
        // NoSuchFileException f0065754... = icons/minecraft.icns，
        // 官方 index-5 实证）。异常虽被 MC 捕获不致命，但用户在日志里
        // 看到整段红色堆栈 = "报错"。修法：icns 纳入预检补齐（~100KB
        // 一次性下载，换日志干净）。
        NSString *rel = [NSString stringWithFormat:@"assets/objects/%@/%@",
            [hash substringToIndex:2], hash];
        NSString *abs = [gameRoot stringByAppendingPathComponent:rel];
        if (![ame225_fm fileExistsAtPath:abs]) {
            [missing addObject:@{@"name": name, @"hash": hash, @"rel": rel}];
        }
    }
    if (missing.count == 0) {
        NSLog(@"[AssetsHeal] Task225 assets integrity OK (%lu objects checked, index=%@)", (unsigned long)checked, indexId);
        return 0;
    }
    NSLog(@"[AssetsHeal] Task225 %lu/%lu asset object(s) MISSING (index=%@) -- healing",
          (unsigned long)missing.count, (unsigned long)checked, indexId);

    // 4. 串行补齐（预算 20s / 上限 300 个）
    NSUInteger cap = MIN((NSUInteger)300, missing.count);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20.0];
    int healed = 0;
    for (NSUInteger i = 0; i < cap; i++) {
        if ([NSDate.date compare:deadline] == NSOrderedDescending) {
            NSLog(@"[AssetsHeal] Task225 budget exhausted after %d heal(s); %lu remain for next launch",
                  healed, (unsigned long)(missing.count - i));
            break;
        }
        NSDictionary *m = missing[i];
        // ★ Task227（反馈 #1 第二半）：heal 下载 URL 用了完整 rel 路径
        // （resources.download.minecraft.net/assets/objects/f0/<hash>）——
        // 官方资源端点只认 <hash 前 2 字符>/<hash>（ef1e3e2a 装机实锤：
        // "download failed for icons/minecraft.icns (未能打开文件"f0065…"）"
        // = 404 映射成 NSCocoaError 256）。修法：URL 改官方两段式 + 落盘前
        // 建中间目录（缺失资产的 objects/f0/ 层目录可能从未创建）+
        // 国内镜像 bmclapi 回退（主站不可达时第二跳）。
        NSString *ame227_hash = [m[@"hash"] isKindOfClass:[NSString class]] ? m[@"hash"] : nil;
        if (ame227_hash.length < 4) continue;
        NSString *ame227_two = [ame227_hash substringToIndex:2];
        NSURL *assetURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://resources.download.minecraft.net/%@/%@", ame227_two, ame227_hash]];
        NSURL *ame227_mirrorURL = [NSURL URLWithString:[NSString stringWithFormat:
            @"https://bmclapi2.bangbang93.com/assets/%@/%@", ame227_two, ame227_hash]];
        if (assetURL == nil) continue;
        NSError *err = nil;
        NSData *data = [NSData dataWithContentsOfURL:assetURL
                                         options:NSDataReadingMappedIfSafe
                                           error:&err];
        if (data.length == 0 && ame227_mirrorURL != nil) {
            NSLog(@"[AssetsHeal] Task227 primary fetch failed (%@) -- retrying via bmclapi mirror", err.localizedDescription ?: @"?");
            err = nil;
            data = [NSData dataWithContentsOfURL:ame227_mirrorURL
                                     options:NSDataReadingMappedIfSafe
                                       error:&err];
        }
        if (data.length > 0) {
            NSString *dst = [gameRoot stringByAppendingPathComponent:m[@"rel"]];
            // Task227：缺失资产的目标层目录（如 objects/f0/）可能不存在，
            // writeToFile 对缺失父目录直接失败——先递归建层再原子落位。
            NSString *dstDir = [dst stringByDeletingLastPathComponent];
            if (dstDir.length > 0 && ![ame225_fm fileExistsAtPath:dstDir]) {
                [ame225_fm createDirectoryAtPath:dstDir
                          withIntermediateDirectories:YES attributes:nil error:nil];
            }
            // .tmp 原子落位（半写文件比缺失更难排查）
            NSString *tmp = [dst stringByAppendingString:@".ametmp"];
            if ([data writeToFile:tmp atomically:YES] &&
                [ame225_fm moveItemAtPath:tmp toPath:dst error:nil]) {
                healed++;
            }
        } else {
            NSLog(@"[AssetsHeal] Task227 download failed for %@ via both primary+mirror (%@)", m[@"name"],
                  err.localizedDescription ?: @"unknown");
        }
    }
    NSLog(@"[AssetsHeal] Task225 healed %d/%lu missing object(s)", healed, (unsigned long)missing.count);
    return healed;
}

static int ame87_disableDesktopDialogMods(NSString *gameDir) {
    if (gameDir.length == 0) {
        return 0;
    }
    NSString *modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    BOOL isDir = NO;
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    if (![fileMgr fileExistsAtPath:modsDir isDirectory:&isDir] || !isDir) {
        return 0;
    }
    NSArray<NSString *> *files = [fileMgr contentsOfDirectoryAtPath:modsDir error:nil];
    if (files.count == 0) {
        return 0;
    }
    // 实证名单（小写子串匹配 .jar 文件名）
    NSArray<NSString *> *patterns = @[@"missingmodschecker"];
    int disabled = 0;
    for (NSString *file in files) {
        NSString *lower = file.lowercaseString;
        if (![lower hasSuffix:@".jar"]) {
            continue; // 已是 .disabled / 非 jar 一律跳过
        }
        BOOL matched = NO;
        for (NSString *pattern in patterns) {
            if ([lower rangeOfString:pattern].location != NSNotFound) {
                matched = YES;
                break;
            }
        }
        if (!matched) {
            continue;
        }
        NSString *srcPath = [modsDir stringByAppendingPathComponent:file];
        NSString *dstPath = [srcPath stringByAppendingString:@".disabled"];
        if ([fileMgr moveItemAtPath:srcPath toPath:dstPath error:nil]) {
            disabled++;
            NSLog(@"[ModDialogGuard] Task87: disabled desktop dialog mod \"%@\" (renamed to .disabled; rename back to re-enable) -- Swing dialogs can never be shown on iOS and would block startup forever (7b88b69 evidence)", file);
        } else {
            NSLog(@"[ModDialogGuard] Task87: FAILED to disable \"%@\" (rename error) -- startup may stall if this mod opens a dialog", file);
        }
    }
    return disabled;
}

// ★ Task287（PocketJ 对标移植）：IMBlocker / InputMethodBlocker 桌面输入法
//   阻断类 mod 自动禁用——此类 mod 携带 macOS 桌面 JNA 输入监听库，iOS
//   App 内 ffi closure 非可执行（Task138 controlify 同域结论），Java 17+
//   会话加载即 UnsatisfiedLinkError/NoClassDef 打崩启动。改名 .jar.disabled
//   保留可恢复（改名回即还原）。上游 PocketJ 同款门（Java>=17，其 8 会话
//   存量路径不触碰）。
static int ame287_disableUnsupportedInputMods(NSString *gameDir) {
    if (gameDir.length == 0) {
        return 0;
    }
    NSString *modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
    BOOL isDir = NO;
    NSFileManager *fileMgr = [NSFileManager defaultManager];
    if (![fileMgr fileExistsAtPath:modsDir isDirectory:&isDir] || !isDir) {
        return 0;
    }
    NSArray<NSString *> *files = [fileMgr contentsOfDirectoryAtPath:modsDir error:nil];
    if (files.count == 0) {
        return 0;
    }
    int disabled = 0;
    for (NSString *file in files) {
        NSString *lower = file.lowercaseString;
        if (![lower hasSuffix:@".jar"]) {
            continue; // 已是 .disabled / 非 jar 一律跳过
        }
        if (![lower containsString:@"imblocker"] &&
            ![lower containsString:@"inputmethodblocker"]) {
            continue;
        }
        NSString *srcPath = [modsDir stringByAppendingPathComponent:file];
        NSString *dstPath = [srcPath stringByAppendingString:@".disabled"];
        NSUInteger duplicateIndex = 2;
        while ([fileMgr fileExistsAtPath:dstPath]) {
            dstPath = [srcPath stringByAppendingFormat:@".%lu.disabled",
                (unsigned long)duplicateIndex++];
        }
        NSError *error = nil;
        if ([fileMgr moveItemAtPath:srcPath toPath:dstPath error:&error]) {
            disabled++;
            NSLog(@"[ModCompat] Task287: disabled desktop input-method mod \"%@\" (renamed to .disabled) -- its macOS JNA library cannot run inside an iOS app (PocketJ 同款防御)", file);
        } else {
            NSLog(@"[ModCompat] Task287: FAILED to disable \"%@\": %@", file, error.localizedDescription);
        }
    }
    return disabled;
}

// ★ Task287（PocketJ 对标移植）：Forge URI-safe 游戏根——版本 id 含
//   "forge" 且游戏目录路径含空格时，把启动 gameDir/POJAV_GAME_DIR 重指到
//   POJAV_HOME 下无空格符号链接别名；Forge 工具链（processor/安装器）对
//   空格路径的 URL/引号处理存在炸面（上游 PocketJ 同款防御，其 alias 命名
//   .pocketj-loader-runtime 同构）。非命中条件时执行还原（env 回真实根），
//   幂等可重入。iOS 常规容器路径无空格 = 本防御平时零行为变化。
//
// ★ Task288-r1（装机实锤："版本隔离出现异常，打开模组管理都没有这几个
//   fabric 模组"；gamelog 双锚：ModsManager Task265 扫描隔离目录
//   versions/NeoForge-26.1.2.122/game/mods jars=2，而 Task287 日志
//   "real: .../Library/Application Support/minecraft"＝共享根）：
//   旧实现 realRoot 优先取 getenv("POJAV_GAME_DIR")——该 env 是 main.m
//   启动期设定的【全局共享根】（含空格 "Application Support"），而启动链
//   传入的 gameDir 才是本次启动的生效目录（Task275/Task225 已解析出隔离
//   实例目录）。对隔离实例的 forge 启动：env(共享根,含空格) 命中 forge+
//   空格双条件 → 别名重指共享根 → chdir/POJAV_GAME_DIR 全部落共享根 →
//   游戏读共享 mods/（管理页扫隔离 mods/）＝ 两张皮，隔离静默失效。
//   修复：realRoot 一律取入参 gameDir（生效目录）；env 仅用于识别
//   "上次 forge 命中遗留的别名指针"以做还原。隔离目录无空格时本函数
//   自然零行为（ forge 版本装在默认共享布局才需要别名）。
static NSString *ame287_configureForgeUriSafeRoot(NSString *versionId, NSString *gameDir) {
    if (gameDir.length == 0) {
        return gameDir;
    }
    const char *ame287_envC = getenv("POJAV_GAME_DIR");
    BOOL ame287_envIsAlias = (ame287_envC && strstr(ame287_envC, "ame287_forge") != NULL);
    BOOL ame287_forge = [versionId.lowercaseString containsString:@"forge"];
    if (!ame287_forge || ![gameDir containsString:@" "]) {
        // 未命中：若 env 还指着别名（上次 forge 命中遗留），还原到别名目标
        //（= 当时的真实根，通常为共享根）；否则 env 不动（全局语义由
        //  main.m 维护，禁止把本次生效目录写回全局 env——隔离启动会毒化
        //  ModService 等以 env 为共享根基准的解析）。
        if (ame287_envIsAlias) {
            NSString *ame287_prev = [NSFileManager.defaultManager
                destinationOfSymbolicLinkAtPath:@(ame287_envC) error:nil];
            if (ame287_prev.length > 0) {
                setenv("POJAV_GAME_DIR", ame287_prev.UTF8String, 1);
                NSLog(@"[JavaLauncher] Task288: POJAV_GAME_DIR alias residue restored -> %@", ame287_prev);
            }
        }
        return gameDir;
    }
    NSString *ame287_realRoot = gameDir;
    const char *ame287_homeC = getenv("POJAV_HOME");
    if (!ame287_homeC) {
        return gameDir;
    }
    NSFileManager *ame287_fm = NSFileManager.defaultManager;
    NSString *ame287_alias = [@(ame287_homeC) stringByAppendingPathComponent:@".ame287_forge_root"];
    NSString *ame287_target = [ame287_fm destinationOfSymbolicLinkAtPath:ame287_alias error:nil];
    if (![ame287_target isEqualToString:ame287_realRoot]) {
        if ([[ame287_fm attributesOfItemAtPath:ame287_alias error:nil][NSFileType]
                isEqualToString:NSFileTypeSymbolicLink]) {
            [ame287_fm removeItemAtPath:ame287_alias error:nil];
        }
        if (![ame287_fm fileExistsAtPath:ame287_alias]) {
            [ame287_fm createSymbolicLinkAtPath:ame287_alias
                          withDestinationPath:ame287_realRoot error:nil];
        }
    }
    if ([[ame287_fm destinationOfSymbolicLinkAtPath:ame287_alias error:nil]
            isEqualToString:ame287_realRoot]) {
        setenv("POJAV_GAME_DIR", ame287_alias.UTF8String, 1);
        NSLog(@"[JavaLauncher] Task287: Forge URI-safe game root -> %@ (real: %@)", ame287_alias, ame287_realRoot);
        return ame287_alias;
    }
    return gameDir;
}

// Task 95：整合包完整性提醒门 ----------------------------------------------
// 病历（96c527f latestlog.txt，1ee7111 构建，BMC2 [FABRIC] 1.20.1，536 mods）：
//   实例 mods 目录缺失 FTB 全家桶 + balm + terrablender + kleeslabs 等 8+ 个
//   jar（导入期 404 跳过/失败未修复），config/fabric-loader.json 的
//   dependencyOverrides 掩盖了 Fabric 依赖解析的硬缺失报错，游戏死在 main
//   entrypoint 的 NoClassDefFoundError 链——用户只能看到"启动 24 秒后闪退"。
// 对策：ModpackImportService Task95 会在实例根目录写 import_report.json；
//   启动前读取该报告，若有未确认的 failed/skipped 条目则弹一次性提醒
//   （acknowledged 置位后不再打扰；重新导入会重写报告并复位该标志）。
//   不做硬阻断：缺失的可能是可选 mod，是否继续由用户决定；崩溃发生时由
//   PLCrashView Task95 分析器给出精确的缺失类清单与修复指引兜底。
static void ame95_warnIncompleteImport(NSString *gameDir) {
    if (gameDir.length == 0) {
        return;
    }
    NSString *reportPath = [gameDir stringByAppendingPathComponent:@"import_report.json"];
    NSData *data = [NSData dataWithContentsOfFile:reportPath];
    if (data.length == 0) {
        return; // 无报告 = 非 Task95 路径导入（老实例/手装 mod），不打扰
    }
    NSError *parseError = nil;
    NSDictionary *report = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:&parseError];
    if (![report isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[ImportGuard] Task95: import report unreadable (%@) -- skipping reminder", parseError.localizedDescription ?: @"(bad json)");
        return;
    }
    NSUInteger failedCount = [report[@"failedCount"] unsignedLongValue];
    NSUInteger skippedCount = [report[@"skippedCount"] unsignedLongValue];
    if (failedCount == 0 && skippedCount == 0) {
        return; // 完整导入（或重导入已修复），无需提醒
    }
    if ([report[@"acknowledged"] boolValue]) {
        return; // 用户已确认过本报告，不再重复打扰
    }
    // 提醒后立即置位 acknowledged（防多弹）；重新导入会重写报告复位
    NSMutableDictionary *ack = [report mutableCopy];
    ack[@"acknowledged"] = @YES;
    NSError *writeError = nil;
    NSData *out = [NSJSONSerialization dataWithJSONObject:ack options:0 error:&writeError];
    if (out && !writeError) {
        [out writeToFile:reportPath options:NSDataWritingAtomic error:nil];
    }
    // 组装提醒文案：计数 + 最多 5 个缺失文件名 + 修复指引
    NSArray<NSDictionary *> *failed = [report[@"failed"] isKindOfClass:[NSArray class]] ? report[@"failed"] : @[];
    NSArray<NSDictionary *> *skipped = [report[@"skipped"] isKindOfClass:[NSArray class]] ? report[@"skipped"] : @[];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSArray<NSDictionary *> *list in @[failed, skipped]) {
        for (NSDictionary *entry in list) {
            NSString *n = entry[@"fileName"];
            if ([n isKindOfClass:[NSString class]] && n.length > 0 && ![names containsObject:n]) {
                [names addObject:n];
                if (names.count >= 5) break;
            }
        }
        if (names.count >= 5) break;
    }
    NSMutableString *msg = [NSMutableString stringWithFormat:
        localize(@"ame189.jl.missing_header", nil),
        (unsigned long)(failedCount + skippedCount), (unsigned long)failedCount, (unsigned long)skippedCount];
    if (names.count > 0) {
        for (NSString *n in names) {
            [msg appendFormat:@"  • %@\n", n];
        }
        NSUInteger totalMissing = failedCount + skippedCount;
        if (totalMissing > names.count) {
            [msg appendFormat:localize(@"ame189.jl.missing_more", nil), (unsigned long)totalMissing];
        }
        [msg appendString:@"\n"];
    }
    [msg appendString:localize(@"ame189.jl.missing_footer", nil)];
    NSLog(@"[ImportGuard] Task95: incomplete import detected (failed=%lu skipped=%lu) -- one-shot reminder shown; launch continues",
          (unsigned long)failedCount, (unsigned long)skippedCount);
    showDialog(localize(@"Warning", nil), msg);
}

// ============================================================================
// Task97: 进程 CWD 与 -Duser.dir 对齐（桌面启动器等价行为）
// ============================================================================
// 2f90d13 装机日志实锤（BMC2 [FABRIC] 1.20.1, 474 mods, 6c3d49d 构建, zink,
// iPad Air M4 / iPadOS 27）：启动史上最深推进（474 mods 全量加载、窗口初始化、
// 资源加载），随后死在两个 mod 的 'main' entrypoint，且两类崩溃同根同源：
//   * paintings (Paintings++ 11.0.0.1) PaintingPackReader.scanPacks:
//       filter Files.exists/isDirectory("./resourcepacks") == true（java.nio
//       按 user.dir 解析 → 游戏目录，整合包自带 resourcepacks/），随后
//       folder.toFile().listFiles() 返回 NULL（java.io.File 按进程 CWD 解析，
//       CWD 里没有该目录）→ Arrays.stream(null) → NPE；
//   * sparsestructures 2.1.2 onInitialize:
//       CONFIG_FILE_PATH.toFile().exists() == false（进程 CWD，守卫放行）→
//       Files.createDirectories("config/sparsestructures.json5")（user.dir =
//       游戏目录）命中整合包自带同名「文件」→ FileAlreadyExistsException。
// 根因：本启动器只传 -Duser.dir=<gameDir> 而从未 chdir，java.io（进程 CWD）
// 与 java.nio（user.dir）两套相对路径解析各看各的目录；桌面启动器永远以
// CWD == 游戏目录启动 java，故同样的 mod 在桌面无恙。
// 本地 JDK 行为复现（scripts/verify_task97.py D 区）：listFiles()==NULL 与
// FileAlreadyExistsException 两签名与真机崩溃逐字一致。
// 副作用审计（Task97, 2026-09）：latestlog.txt 走绝对路径 pipe 捕获（main.m）；
// 全部 dlopen 经 @rpath/@loader_path 解析；ObjC 侧文件 IO 均
// NSHomeDirectory/NSBundle 绝对路径——chdir 无相对路径受害者。对齐后 log4j
// 的 logs/latest.log 也会正确落进实例目录（桌面等价行为），早前
// "Cannot access RandomAccessFile logs/latest.log" ENOENT 一并消失。
// 失败策略：chdir 失败仅告警不阻断（维持旧行为，日志留 [CwdAlign] 取证）。
static void ame97_alignProcessCwdToGameDir(NSString *gameDir) {
    if (gameDir.length == 0) {
        NSLog(@"[CwdAlign] Task97: gameDir empty, skipping CWD alignment");
        return;
    }
    const char *dir = gameDir.fileSystemRepresentation;
    if (chdir(dir) != 0) {
        int savedErrno = errno;
        NSLog(@"[CwdAlign] Task97: FAILED to chdir(%@) errno=%d -- continuing with unaligned CWD "
              "(mods mixing java.io/java.nio relative paths may misbehave)", gameDir, savedErrno);
        return;
    }
    setenv("PWD", dir, 1);
    // 权威取证：chdir 后回读 getcwd（NSFileManager currentDirectoryPath 内部即 getcwd）
    NSString *nowCwd = [[NSFileManager defaultManager] currentDirectoryPath];
    NSLog(@"[CwdAlign] Task97: process CWD aligned to game dir: %@", nowCwd);
}

// ============================================================================
// Task 99（修复 A）：MC 26.3 Window 初始化的 AppKit 菜单集成崩溃
//
// 证据链（b919e0f/2253a10 上传日志对，7ed3d01 构建，fabric-loader-0.19.5-
// 26.3-e4ecd7db，110 mods，zink，iPad Air M4）：
//   * Task97/98 修复双双生效——[LWJGLSel] Task98 正确选出 LWJGL 341（对照
//     2af8c45 的错选 333），[CwdAlign] Task97 对齐成功，SDL/EGL 桥、zink/
//     MoltenVK、主窗口 "Minecraft* 26.3 1572x1092"、GL 4.1 Mesa 全部就绪，
//     渲染线程跑到 Minecraft.<init>；
//   * 然后死于：
//       java.lang.RuntimeException: java.lang.NoSuchMethodException:
//         Method cannot be found for signature 8958362280
//         at ca.weblite.objc.RuntimeUtils.msg / Client.sendProxy
//         at com.mojang.blaze3d.platform.MacosUtil.disableCloseWindowMenuItem
//         at com.mojang.blaze3d.platform.Window.<init>(Window.java:121)
//       Description: Initializing game
//   * 26.3-rc-3（f17ef7b，同一代码路径）完整游玩无恙——Mojang 在 rc-3 之后
//     到 26.3 正式版之间改动了 Window 构造里的 macOS 集成调用（正式版新增/
//     改为 disableCloseWindowMenuItem），首次暴露本层。
//
// 根因：启动器为了让 LWJGL/JNA 在 iOS 上工作而伪装 os.name=Mac OS X，
// MC 26.3 的 Window.<init> 因此认定自己跑在 macOS 上，调用 MacosUtil 的
// AppKit 集成（经 jna-objc 桥 ca.weblite.objc.Client.sendProxy
// ("NSApplication","sharedApplication") 起步，随后走 mainMenu →
// numberOfItems → itemAtIndex: → submenu → title → setEnabled: 的标准菜单
// 巡游）。iOS 只有 UIKit，没有 AppKit——objc_getClass("NSApplication")
// 落空，jna-objc 的方法解析随之抛 NoSuchMethodException，MC 以
// "Initializing game" 崩溃。与渲染器无关（崩在任何 GL 呈现之前）。
//
// 修复：在 JLI_Launch 之前用 ObjC 运行时公开 API 注册三个最小桩类
// （objc_allocateClassPair + class_addMethod + objc_registerClassPair）：
//   NSApplication : +sharedApplication → 单例；-mainMenu → 单例桩菜单；
//                   -windows → 真 NSArray @[]（Foundation 在 iOS 存在）
//   NSMenu       : -numberOfItems → 0（MC 的巡游循环零次即返回），
//                   -itemAtIndex: → nil，-title → @""
//   NSMenuItem   : -title → @""，-submenu → nil，-setEnabled: → 无操作
// 守卫：仅当 objc_getClass("NSApplication") == NULL 时注册（真 macOS 永不
// 触碰；iOS 恒触发；绝不覆盖真实类）。
// 安全网：三个桩类都装 +resolveInstanceMethod: —— 若 26.3+ 的菜单巡游
// 触到未实现选择子，动态补一个返回 nil 的无操作 IMP 并响亮留痕（优于
// doesNotRecognizeSelector 的硬崩溃；MC 侧巡游代码对 null 返回有守卫）。
// 幂等：静态标志，重复调用零副作用。
// ============================================================================
#include <objc/runtime.h>
#include <objc/message.h>

static id ame99_shared_app_stub(void);
static id ame99_shared_menu_stub(void);

// —— IMP 实现（类型编码与 AppKit 真实声明一致，jna-objc 按编码选 marshaller）
static id ame99_app_sharedApplication(id self, SEL _cmd) { return ame99_shared_app_stub(); }
static id ame99_app_mainMenu(id self, SEL _cmd) { return ame99_shared_menu_stub(); }
// Task 100（修复 A 续）：NSApplication 的全部菜单出口都返回共享菜单桩。
// 病历（7a30912 装机日志，ccabe82 构建）：Task99 桩让 sharedApplication 成功
// 返回桩实例后，MC 26.3 的 MacosUtil 继续取 windowsMenu——该选择子当时未
// 显式实现，resolveInstanceMethod 兜底返回 nil，jna-objc 把 nil 包装成 Java
// null 返回，MacosUtil.java:27 第一句 windowsMenu.sendInt(...) 即 NPE：
//   java.lang.NullPointerException: Cannot invoke "ca.weblite.objc.Proxy.sendInt"
//     because "windowsMenu" is null  at MacosUtil.disableCloseWindowMenuItem(:27)
// 修复：windowsMenu 显式返回 NSMenu 桩（numberOfItems=0 → 巡游零次返回），
// appleMenu/helpMenu/servicesMenu 同批补齐（同一菜单访问器家族，防下一层
// 踩空；宁可多补不可再 NPE）。
static id ame99_app_windowsMenu(id self, SEL _cmd) {
    static bool s_logged = false;
    if (!s_logged) {
        s_logged = true;
        NSLog(@"[AppKitStub] Task100: windowsMenu requested -> NSMenu stub returned "
              @"(7a30912 NPE at MacosUtil.java:27 fixed; menu walk no-ops)");
    }
    return ame99_shared_menu_stub();
}
static NSArray *ame99_app_windows(id self, SEL _cmd) { return @[]; }
static long ame99_menu_numberOfItems(id self, SEL _cmd) { return 0; }          // NSInteger
static id ame99_menu_itemAtIndex(id self, SEL _cmd, long index) { return nil; }
static NSString *ame99_any_title(id self, SEL _cmd) { return @""; }
static BOOL ame99_item_isEnabled(id self, SEL _cmd) { return NO; }
static id ame99_item_submenu(id self, SEL _cmd) { return nil; }
static void ame99_noop_vBB(id self, SEL _cmd, BOOL b) {}
static void ame99_noop_vq(id self, SEL _cmd, long q) {}
static void ame99_noop_v_id(id self, SEL _cmd, id o) {}

// 兜底 IMP：任何未预期选择子 → 返回 nil（配合 resolveInstanceMethod:）
static id ame99_generic_nil(id self, SEL _cmd) { return nil; }

// Task230 (feedback #1: ANGLE/non-SDL 1.20.1 crash, second layer): the generic
// no-op used to be registered with a FIXED 0-argument type encoding "@@:".
// jna-objc's RuntimeUtils.msg (java-objc-bridge 1.1) validates the Java-side
// argument count against the ObjC method signature BEFORE dispatching --
// vanilla 1.20.1 MacosUtil calls
//   sharedApplication.send("setApplicationIconImage:", nsimage)
// with ONE argument, the stub advertised ZERO
// ("requires 0 arguments, but received 1" -> RuntimeException ->
// "Initializing game" crash, 39633e4 latestlog.old.txt:498 with our own
// Task99 log line "unexpected selector <setApplicationIconImage:>" right
// above it). Fix: derive the argument count from the selector's colons and
// advertise one '@' (id) argument per colon, returning id (nil). Every
// java-objc-bridge Client.send argument is an id, so this signature is
// exactly what the Java-side validator expects. Capped at 8 for safety
// against pathological selector names.
static BOOL ame230_addGenericNoop(Class cls, SEL name) {
    if (!cls || name == NULL) return NO;
    const char *ame230_sel = sel_getName(name);
    NSUInteger ame230_colons = 0;
    for (const char *p = ame230_sel; *p != '\0'; ++p) {
        if (*p == ':') ++ame230_colons;
    }
    if (ame230_colons > 8) ame230_colons = 8;
    char ame230_types[16];
    // "@ @ :" = return id, self id, _cmd SEL, then N x id (one per colon)
    NSUInteger ame230_i = 0;
    ame230_types[ame230_i++] = '@';   // return: id (nil -> Java null)
    ame230_types[ame230_i++] = '@';   // self
    ame230_types[ame230_i++] = ':';   // _cmd
    for (NSUInteger c = 0; c < ame230_colons; ++c) ame230_types[ame230_i++] = '@';
    ame230_types[ame230_i] = '\0';
    return class_addMethod(cls, name, (IMP)ame99_generic_nil, ame230_types);
}

// 安全网：未实现选择子 → 动态补无操作 IMP（返回 nil）+ 留痕
static BOOL ame99_resolveInstanceMethod(Class self, SEL _cmd, SEL name) {
    NSLog(@"[AppKitStub] Task99: unexpected selector <%s> on %s -- generic nil no-op installed "
          "(Task230 colon-aware signature)", sel_getName(name), class_getName(self));
    if (!ame230_addGenericNoop(self, name)) return NO;
    return YES;
}

static id ame99_shared_app_stub(void) {
    static id sApp = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("NSApplication");
        if (cls) sApp = class_createInstance(cls, 0);   // 桩类自身
    });
    return sApp;
}

static id ame99_shared_menu_stub(void) {
    static id sMenu = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = objc_getClass("NSMenu");
        if (cls) sMenu = class_createInstance(cls, 0);
    });
    return sMenu;
}

static void ame99_installAppKitMenuStubs(void) {
    static bool installed = false;
    if (installed) return;
    installed = true;

    // 守卫：真实 AppKit 存在（真 macOS）则绝不插桩。iOS 上恒 NULL。
    if (objc_getClass("NSObject") == NULL) {
        NSLog(@"[AppKitStub] Task99: ObjC runtime unavailable, skipping");
        return;
    }
    if (objc_getClass("NSApplication") != NULL) {
        NSLog(@"[AppKitStub] Task99: real AppKit present, stubs not needed");
        return;
    }

    // —— NSMenu（先建：NSApplication.mainMenu 要返回它）
    Class menuCls = objc_allocateClassPair(objc_getClass("NSObject"), "NSMenu", 0);
    if (menuCls) {
        class_addMethod(menuCls, @selector(numberOfItems), (IMP)ame99_menu_numberOfItems, "q@:");
        class_addMethod(menuCls, @selector(itemAtIndex:), (IMP)ame99_menu_itemAtIndex, "@@:q");
        class_addMethod(menuCls, @selector(title), (IMP)ame99_any_title, "@@:");
        class_addMethod(menuCls, @selector(setTitle:), (IMP)ame99_noop_v_id, "v@:@");
        class_addMethod(menuCls, @selector(setAutoenablesItems:), (IMP)ame99_noop_vBB, "v@:B");
        class_addMethod(menuCls, @selector(removeItemAtIndex:), (IMP)ame99_noop_vq, "v@:q");
        class_addMethod(menuCls, @selector(addItem:), (IMP)ame99_noop_v_id, "v@:@");
        class_addMethod(object_getClass(menuCls), @selector(resolveInstanceMethod:),
                        (IMP)ame99_resolveInstanceMethod, "B@::");
        objc_registerClassPair(menuCls);
    }

    // —— NSMenuItem
    Class itemCls = objc_allocateClassPair(objc_getClass("NSObject"), "NSMenuItem", 0);
    if (itemCls) {
        class_addMethod(itemCls, @selector(title), (IMP)ame99_any_title, "@@:");
        class_addMethod(itemCls, @selector(setTitle:), (IMP)ame99_noop_v_id, "v@:@");
        class_addMethod(itemCls, @selector(setEnabled:), (IMP)ame99_noop_vBB, "v@:B");
        class_addMethod(itemCls, @selector(isEnabled), (IMP)ame99_item_isEnabled, "B@:");
        class_addMethod(itemCls, @selector(submenu), (IMP)ame99_item_submenu, "@@:");
        class_addMethod(itemCls, @selector(setSubmenu:), (IMP)ame99_noop_v_id, "v@:@");
        class_addMethod(object_getClass(itemCls), @selector(resolveInstanceMethod:),
                        (IMP)ame99_resolveInstanceMethod, "B@::");
        objc_registerClassPair(itemCls);
    }

    // —— NSApplication
    Class appCls = objc_allocateClassPair(objc_getClass("NSObject"), "NSApplication", 0);
    if (appCls) {
        class_addMethod(object_getClass(appCls), @selector(sharedApplication),
                        (IMP)ame99_app_sharedApplication, "@@:");
        class_addMethod(appCls, @selector(mainMenu), (IMP)ame99_app_mainMenu, "@@:");
        // Task 100（修复 A 续）：菜单访问器全家族（windowsMenu 是 7a30912 实锤
        // 崩溃点；appleMenu/helpMenu/servicesMenu 为同族预防性补齐）
        class_addMethod(appCls, @selector(windowsMenu), (IMP)ame99_app_windowsMenu, "@@:");
        class_addMethod(appCls, @selector(appleMenu), (IMP)ame99_app_windowsMenu, "@@:");
        class_addMethod(appCls, @selector(helpMenu), (IMP)ame99_app_windowsMenu, "@@:");
        class_addMethod(appCls, @selector(servicesMenu), (IMP)ame99_app_windowsMenu, "@@:");
        class_addMethod(appCls, @selector(setMainMenu:), (IMP)ame99_noop_v_id, "v@:@");
        class_addMethod(appCls, @selector(windows), (IMP)ame99_app_windows, "@@:");
        class_addMethod(appCls, @selector(delegate), (IMP)ame99_generic_nil, "@@:");
        class_addMethod(appCls, @selector(setDelegate:), (IMP)ame99_noop_v_id, "v@:@");
        class_addMethod(object_getClass(appCls), @selector(resolveInstanceMethod:),
                        (IMP)ame99_resolveInstanceMethod, "B@::");
        objc_registerClassPair(appCls);
    }

    NSLog(@"[AppKitStub] Task99: NSApplication/NSMenu/NSMenuItem stubs installed "
          "(iOS has no AppKit; MC 26.3 MacosUtil menu walk no-ops, numberOfItems=0)");
}

// ============================================================================
// Task 229 (feedback #1: "ANGLE errors on non-SDL build" -- actually an
// MC 1.20.1 all-renderer startup crash): vanilla 1.20.1's
// MacosUtil.loadIcon(IoSupplier) drives the ca.weblite.objc bridge
// (java-objc-bridge 1.1, loaded via the version json osx rule) with:
//   Client.sendProxy("NSData","alloc").send("initWithBase64Encoding:", b64)
//   Client.sendProxy("NSImage","alloc").send("initWithData:", data)
//   Client.sendProxy("NSApplication","sharedApplication").send(
//       "setApplicationIconImage:", img)
// jna-objc's msg() probes the target via methodSignatureForSelector: -- iOS
// NSData has NO initWithBase64Encoding: (macOS 10.9 legacy selector, iOS
// never had it; iOS uses initWithBase64EncodedString:options:) and NSImage
// does not exist as a class at all -- either miss throws
// NoSuchMethodException: Method cannot be found for signature 8668353440
// -> "Initializing game" hard crash (e24a60a9 latestlog.old crash report:
// ehg.a:45 = MacosUtil.loadIcon, ehn.a:154 = Window.setIcon; ProGuard
// official mapping proof: enn=Minecraft, ehn=Window, ehg=MacosUtil).
//
// Why the 226/227 builds did NOT crash but 228 does (causal chain):
//   * Task226 fixed the JNA re-signing -> the ca.weblite bridge went from
//     NoClassDefFoundError (swallowed upstream, degraded) to actually usable;
//   * Task227 fixed AssetsHeal (official <2char>/<hash> URL + bmclapi
//     fallback) -> icons/minecraft.icns now really lands on disk (device log
//     "Task225 healed 2/2" proof);
//   * with both in place, loadIcon's IoSupplier reads real icns bytes for
//     the first time and walks into the ObjC bridge -- previously the
//     missing icns degraded via NoSuchFileException (which is why the
//     1.20.1+ANGLE crash in the Task227 forensics happened later, at the
//     shader stage). Renderer-independent (dies before any GL present);
//     ANGLE was simply the renderer the user picked.
//
// Fix (Task99 stub system extension, zero Java-side changes):
//   (1) register an NSImage stub class (iOS has none): NSObject subclass,
//       -initWithData: returns self, +resolveInstanceMethod: safety net
//       (same shape as the Task99 stubs);
//   (2) class_addMethod the macOS legacy selector initWithBase64Encoding:
//       onto the real Foundation NSData (returns self; the payload is never
//       consumed -- the chain ends in the NSApplication stub's no-op). The
//       runtime allows adding methods to existing classes and no iOS system
//       code ever calls this macOS-only selector;
//   (3) setApplicationIconImage: is already covered by the Task99
//       NSApplication stub's resolveInstanceMethod: generic nil no-op.
// Guards identical to Task99: real macOS (AppKit present) never touches
// this; idempotent.
// ============================================================================
static id ame229_image_initWithData(id self, SEL _cmd, id data) { return self; }

static BOOL ame229_resolveInstanceMethod(Class self, SEL _cmd, SEL name) {
    NSLog(@"[AppKitStub] Task229: unexpected selector <%s> on %s -- generic nil no-op installed "
          "(Task230 colon-aware signature)",
          sel_getName(name), class_getName(self));
    if (!ame230_addGenericNoop(self, name)) return NO;
    return YES;
}

static id ame229_nsdata_initWithBase64Encoding(id self, SEL _cmd, id b64String) {
    // Payload is not decoded: the NSImage stub's initWithData: does not
    // consume it either and the chain ends in the NSApplication stub no-op.
    // This IMP only needs methodSignatureForSelector: to succeed.
    static bool s_logged = false;
    if (!s_logged) {
        s_logged = true;
        NSLog(@"[AppKitStub] Task229: NSData initWithBase64Encoding: (macOS legacy) served by stub -- MC 1.20.1 loadIcon proceeds");
    }
    return self;
}

static void ame229_installIconPathStubs(void) {
    static bool installed = false;
    if (installed) return;
    installed = true;

    if (objc_getClass("NSObject") == NULL) return;
    // Real macOS has a real NSImage and real selectors -- never stub.
    if (objc_getClass("NSImage") != NULL) {
        NSLog(@"[AppKitStub] Task229: real NSImage present, icon stubs not needed");
        return;
    }

    // (1) NSImage stub (+alloc inherited from NSObject; -initWithData: -> self)
    Class imgCls = objc_allocateClassPair(objc_getClass("NSObject"), "NSImage", 0);
    if (imgCls) {
        class_addMethod(imgCls, @selector(initWithData:), (IMP)ame229_image_initWithData, "@@:@");
        class_addMethod(imgCls, @selector(init), (IMP)ame229_image_initWithData, "@@:");
        class_addMethod(object_getClass(imgCls), @selector(resolveInstanceMethod:),
                        (IMP)ame229_resolveInstanceMethod, "B@::");
        objc_registerClassPair(imgCls);
    }

    // (2) NSData gains the macOS legacy selector (iOS never had it)
    Class nsDataCls = objc_getClass("NSData");
    if (nsDataCls && class_getInstanceMethod(nsDataCls, @selector(initWithBase64Encoding:)) == NULL) {
        class_addMethod(nsDataCls, @selector(initWithBase64Encoding:),
                        (IMP)ame229_nsdata_initWithBase64Encoding, "@@:@");
    }

    NSLog(@"[AppKitStub] Task229: NSImage stub + NSData legacy-b64 selector installed "
          "(MC 1.20.1 MacosUtil.loadIcon no-ops instead of crashing; AppKit-free iOS)");
}


// ---------------------------------------------------------------------------
// Task 134 → Task 140：TouchController mod 侧配置处理的历史与现状。
//
// Task134 曾在此向 mod 写入空布局预设（"Amethyst Clean"，layout=[]）+
// config.json 指针，配合 mod_touch_hide_controls 开关达成"界面无控件"；
// Task138 修复了 plist→JSON 序列化使 mod 真正读到；Task139 又叠加隐藏
// 启动器自身 ctrlView —— 最终效果是屏幕上一个按钮都没有，而用户期望
// "屏蔽启动器自带控件、保留模组自己的虚拟按钮"（上游内置预设自带
// 完整按钮：摇杆/跳跃/聊天/暂停等，见 BuiltinPresetsProviderImpl）。
//
// Task140（现行）：mod 的配置启动器【永不写入】——屏蔽控件开关只作用于
// 启动器自身控件层（SurfaceViewController.ame139_modControlsHidden）；
// 本文件仅保留 ame140_remediateTouchControllerConfig 的一次性修复：把
// Task134-139 污染的空布局指针恢复/移除，让 mod 回落内置默认预设。
// mod 的配置体系（fifthlight/TouchController，kotlinx.serialization）：
//   <gameDir>/config/touchcontroller/config.json          全局配置（preset 字段选预设）
//   <gameDir>/config/touchcontroller/preset/<uuid>.json   自定义布局预设
//   <gameDir>/config/touchcontroller/order.json           预设顺序表（uuid 数组）
// ---------------------------------------------------------------------------
// Task 138：JSON 读写全面替换 Task134 的 plist 序列化。
//
// 病历（本轮 latestlog.txt.old.txt 26.2 会话实锤）：Task134 用
// NSDictionary/NSArray 的 writeToFile 写 config.json 与 order.json——
// 该 API 输出的是 plist XML（文件头为 <?xml version="1.0" ...），而 mod
// 侧 GlobalConfigHolder.load 与 PresetsContainer 用 kotlinx.serialization
// 按 JSON 解析，读到首个字符为 < 直接抛 JsonDecodingException
// （期望 JSON 对象开头，却读到了 XML 声明）→ 全局配置读取失败回落默认 → preset 指针
// 丢失 → 屏蔽控件失效；读取侧同病：dictionaryWithContentsOfFile/
// arrayWithContentsOfFile 对 mod 写出的合法 JSON 恒返回 nil，"保留 mod
// 已有设置"的读改写逻辑从未生效过（每次启动都把 mod 的全部设置清成只剩
// preset 一个键，且还是 XML 形态）。本函数现全部改用 NSJSONSerialization
// 读写两个文件，mod 侧 "Reading TouchController config file" 不再报错，
// 读改写真正保留 mod 设置；存量被污染的 XML 文件会在下一次启动被合法
// JSON 覆盖（XML 解析失败按"无既有配置"处理，与全新安装等价）。
static NSDictionary *ame138_readJSONDictionary(NSString *path) {
    NSData *ame138_data = [NSData dataWithContentsOfFile:path];
    if (!ame138_data) return nil;
    id ame138_obj = [NSJSONSerialization JSONObjectWithData:ame138_data
        options:0 error:nil];
    return [ame138_obj isKindOfClass:NSDictionary.class] ? ame138_obj : nil;
}

static NSArray *ame138_readJSONArray(NSString *path) {
    NSData *ame138_data = [NSData dataWithContentsOfFile:path];
    if (!ame138_data) return nil;
    id ame138_obj = [NSJSONSerialization JSONObjectWithData:ame138_data
        options:0 error:nil];
    return [ame138_obj isKindOfClass:NSArray.class] ? ame138_obj : nil;
}
// Task 140 注：ame138_readJSONArray 暂无调用者（Task134 的 order.json 读写
// 随 mod 侧空布局写入一并退役）；保留为 JSON 工具集的一部分（与
// ame138_readJSONDictionary/ame138_writeJSON 同族，未来 mod 配置类功能复用）。

static BOOL ame138_writeJSON(id obj, NSString *path) {
    if (![NSJSONSerialization isValidJSONObject:obj]) return NO;
    NSData *ame138_out = [NSJSONSerialization dataWithJSONObject:obj
        options:NSJSONWritingPrettyPrinted error:nil];
    if (!ame138_out) return NO;
    return [ame138_out writeToFile:path options:NSDataWritingAtomic error:nil];
}

// Task 140：mod 侧配置处理重构 —— 从“写空布局”改为“只修复”。
//
// 病历（用户本轮反馈“静态库的触碰可以使用了，但是虚拟按钮没有显示”）：
// Task134 起本函数在 mod_touch_hide_controls 开启时向 mod 写入空布局
// 预设（"Amethyst Clean"，layout=[]）+ config.json 指针；Task139 又叠加
// 隐藏启动器自身 ctrlView —— 两层一起 = 屏幕上一个按钮都没有。用户要的
// 是“屏蔽启动器自带控件、用模组自己的按钮”（TouchController 的内置
// 预设自带完整虚拟按钮：摇杆/跳跃/聊天/暂停等，见上游
// BuiltinPresetsProviderImpl）。此外备份键 control.mod_touch_prev_preset_json
// 在真实设备上从未落盘（装机日志 "Getter could not find preference"），
// 关闭开关后无从恢复 —— mod 被永久锁死在空布局上，虚拟按钮再也不显示。
//
// 新语义（Task140）：
//   - 屏蔽控件开关只作用于启动器自身控件层（SurfaceViewController 的
//     ame139_modControlsHidden 门控），mod 的布局/配置启动器【永不触碰】；
//   - 本函数仅做一次性修复：config.json 的 preset 指针若指向我们写过的
//     空布局 uuid（Task134-139 污染），恢复备份或直接移除指针（mod 回落
//     内置默认预设 = 完整虚拟按钮）；用户手动在 mod 界面选的其它预设
//     一律不动。空布局预设文件保留（用户仍可在 mod 配置界面选用）。
// ★ Task261（右 Shift"又出问题了"根修——新实例默认键位家族）：
// 历轮病例链：Task181 净化器洗键（v1 标记止血）/ Task224 隔离目录换代重洗
// （v2 恢复）/ Task225 恢复只覆盖 v2 cohort（v3）。结构性盲区 = 【全新
// 实例】（新装实例、隔离新档、迁移后新建 instance）：options.txt 由 MC
// 生成默认 key_key.sneak=key.keyboard.left.shift，而用户布局里的潜行按钮
// 是右SHIFT(344) —— 按键事件链全绿但 MC 的潜行键位根本不在右 Shift =
// "右 SHIFT 按钮打空"（Task229 根因 (c) 同族）。Task229 的跨实例键位
// 同步只补【缺失】键行，默认行已存在 → 永不修复。
// 修法（JVM 启动前、MC 读 options.txt 之前）：活动控件布局含 344 按钮
// && 当前 options.txt 的 sneak 处于原版默认态 && v4 标记缺席 → 改绑
// key.keyboard.right.shift（旧数字格式 42→54）+ 写 v4 标记（一次性：
// 用户此后在游戏内主动改回左 Shift 不再被翻转，尊重用户后续选择）。
static void ame261_repairSneakBindingForRightShiftLayout(NSString *gameDir) {
    if (gameDir.length == 0) return;
    // 1. 活动布局是否含 344（profile 的 defaultTouchCtrl → controlmap/<名>）
    NSString *ame261_ctrlName = [PLProfiles resolveKeyForCurrentProfile:@"defaultTouchCtrl"];
    if (![ame261_ctrlName isKindOfClass:[NSString class]] || ame261_ctrlName.length == 0) return;
    NSString *ame261_ctrlPath = [NSString stringWithFormat:@"%s/controlmap/%@",
        getenv("POJAV_HOME"), ame261_ctrlName];
    NSData *ame261_ctrlData = [NSData dataWithContentsOfFile:ame261_ctrlPath];
    if (ame261_ctrlData.length == 0) return;
    id ame261_ctrlJson = [NSJSONSerialization JSONObjectWithData:ame261_ctrlData
                                                         options:0 error:nil];
    BOOL ame261_hasRShift = NO;
    NSMutableArray<id> *ame261_stack = [NSMutableArray array];
    if (ame261_ctrlJson != nil) [ame261_stack addObject:ame261_ctrlJson];
    while (ame261_stack.count > 0 && !ame261_hasRShift) {
        id ame261_node = ame261_stack.lastObject;
        [ame261_stack removeLastObject];
        if ([ame261_node isKindOfClass:[NSArray class]]) {
            for (id ame261_sub in (NSArray *)ame261_node) [ame261_stack addObject:ame261_sub];
        } else if ([ame261_node isKindOfClass:[NSDictionary class]]) {
            NSDictionary *ame261_dict = (NSDictionary *)ame261_node;
            for (id ame261_sub in ame261_dict.allValues) [ame261_stack addObject:ame261_sub];
            id ame261_kcs = ame261_dict[@"keycodes"];
            if ([ame261_kcs isKindOfClass:[NSArray class]]) {
                for (id ame261_kc in (NSArray *)ame261_kcs) {
                    if ([ame261_kc isKindOfClass:[NSNumber class]] && [ame261_kc intValue] == 344) {
                        ame261_hasRShift = YES;
                        break;
                    }
                }
            }
        }
    }
    if (!ame261_hasRShift) {
        NSLog(@"[Task261] sneak rebind repair: no RIGHT_SHIFT(344) button in active layout (%@), skip",
              ame261_ctrlName);
        return;
    }

    // 2. 当前实例 options.txt 的 sneak 现状
    NSString *ame261_optPath = [gameDir stringByAppendingPathComponent:@"options.txt"];
    NSString *ame261_content = [NSString stringWithContentsOfFile:ame261_optPath
                                                         encoding:NSUTF8StringEncoding
                                                            error:nil];
    if (ame261_content.length == 0) return;
    NSString *ame261_target = nil;
    for (NSString *ame261_ln in [ame261_content componentsSeparatedByString:@"\n"]) {
        if ([ame261_ln hasPrefix:@"key_key.sneak:"]) {
            NSString *ame261_val = [[ame261_ln substringFromIndex:@"key_key.sneak:".length]
                stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@"\r "]];
            // 仅在原版默认态修复（新键名/旧数字格式双形态，与 Task225 v3 同口径）
            if ([ame261_val isEqualToString:@"key.keyboard.left.shift"]) {
                ame261_target = @"key.keyboard.right.shift";
            } else if ([ame261_val isEqualToString:@"42"]) {
                ame261_target = @"54";
            }
            break;
        }
    }
    if (ame261_target == nil) {
        NSLog(@"[Task261] sneak rebind repair: sneak not in vanilla-default state, keep as-is");
        return;
    }

    // 3. v4 一次性标记（同目录，与 v1/v2/v3 同族）
    NSString *ame261_marker = [ame261_optPath stringByAppendingString:@".amethyst-keybinds-v4"];
    if ([NSFileManager.defaultManager fileExistsAtPath:ame261_marker]) {
        NSLog(@"[Task261] sneak rebind repair: v4 marker present, skip (one-shot)");
        return;
    }

    // 4. 备份 + 原子重写 + 写标记
    NSString *ame261_bak = [ame261_optPath stringByAppendingString:@".amethyst-bak"];
    [NSFileManager.defaultManager removeItemAtPath:ame261_bak error:nil];
    if (![NSFileManager.defaultManager copyItemAtPath:ame261_optPath
                                              toPath:ame261_bak
                                               error:nil]) {
        NSLog(@"[Task261] sneak rebind repair: backup failed, abort to avoid data loss");
        return;
    }
    NSMutableArray<NSString *> *ame261_out = [NSMutableArray array];
    for (NSString *ame261_ln in [ame261_content componentsSeparatedByString:@"\n"]) {
        if ([ame261_ln hasPrefix:@"key_key.sneak:"]) {
            [ame261_out addObject:[NSString stringWithFormat:@"key_key.sneak:%@", ame261_target]];
        } else {
            [ame261_out addObject:ame261_ln];
        }
    }
    NSString *ame261_new = [ame261_out componentsJoinedByString:@"\n"];
    BOOL ame261_ok = [ame261_new writeToFile:ame261_optPath atomically:YES
                                    encoding:NSUTF8StringEncoding error:nil];
    [@"" writeToFile:ame261_marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"[Task261] sneak rebind repair: layout has RIGHT_SHIFT(344), sneak was vanilla-default "
          @"-> %@ (write=%@, marker=v4, options=%@)",
          ame261_target, ame261_ok ? @"OK" : @"FAILED", ame261_optPath);
}

static void ame140_remediateTouchControllerConfig(NSString *gameDir) {
    if (gameDir.length == 0) {
        return;
    }
    NSString *configFile = [gameDir stringByAppendingPathComponent:
        @"config/touchcontroller/config.json"];
    // Task134-139 曾写入的空布局预设 uuid（识别污染指针用）
    NSString *cleanUuid = @"0196a1ba-6e9a-7b4c-8d5e-3f2a1c0e9b7d";

    NSMutableDictionary *config = [NSMutableDictionary dictionary];
    NSDictionary *ame138_loaded = ame138_readJSONDictionary(configFile);
    if (ame138_loaded) {
        config = ame138_loaded.mutableCopy;
    }

    // 只在指针指向【我们的】空布局时动手（用户自选预设不动）
    NSDictionary *preset = [config[@"preset"] isKindOfClass:NSDictionary.class]
        ? config[@"preset"] : nil;
    BOOL pointsToClean = [preset isKindOfClass:NSDictionary.class] &&
        [preset[@"uuid"] isKindOfClass:NSString.class] &&
        [preset[@"uuid"] isEqualToString:cleanUuid];

    if (!pointsToClean) {
        // 从未污染，或用户已自选其它预设：不动配置
        return;
    }

    // 有备份（Task134 语义下存的）→ 恢复原值；无备份 → 移除指针回落内置默认
    NSString *backup = getPrefObject(@"control.mod_touch_prev_preset_json");
    if ([backup isKindOfClass:NSString.class] && backup.length > 0) {
        NSData *raw = [backup dataUsingEncoding:NSUTF8StringEncoding];
        id restored = [NSJSONSerialization JSONObjectWithData:raw options:0 error:nil];
        if (restored) {
            config[@"preset"] = restored;
        }
        setPrefObject(@"control.mod_touch_prev_preset_json", @"");
        ame138_writeJSON(config, configFile);
        NSLog(@"[TouchController] Task140: polluted empty-layout pointer remediated (backup restored) -- mod default/custom buttons return");
    } else {
        [config removeObjectForKey:@"preset"];
        ame138_writeJSON(config, configFile);
        NSLog(@"[TouchController] Task140: polluted empty-layout pointer removed -- mod falls back to built-in default preset (full virtual buttons)");
    }
}

// ============================================================================
// Task 158（Fix B）：JVM 启动前的游戏库完整性自愈闸门（非阻断）
//
// 病历（latestlog.forge，10cee5d 构建，1.20.1-forge-47.4.13 + 116 mods，
// Forge 走到 Minecraft.<init> 即闪退）：
//   java.lang.NoClassDefFoundError: com/mojang/text2speech/Narrator
//     at net.minecraft.client.GameNarrator.<init>
//
// 机制闭环（BootstrapLauncher 1.1.2 + securejarhandler 2.1.10 源码逐行实证，
// 见 scripts/task158_bl/ 取证产物）：
//   ① BootstrapLauncher.loadLegacyClassPath 回退读 java.class.path；我们的
//      PojavClassLoader.addURL 重写会把 generateLaunchClassPath 的每个游戏
//      jar 路径追加进该属性（Java 侧 generateLaunchClassPath 对不存在的文件
//      "Ignored non-exists file" 直接跳过）；
//   ② MC-BOOTSTRAP / GAME 模块层由这些 jar 模块化构成；ModuleClassLoader 的
//      父链是 boot/platform 层——系统类加载器（-cp 上的 launcher.jar 影子类）
//      对模块层【完全不可见】（Task154 起 launcher.jar 正确地在 ignoreList 里，
//      那次修复的代价就是模块层失去了 launcher.jar 携带的 com.mojang 桩）；
//   ③ 模块层里 com.mojang.text2speech 桩已由随包的 mojang-stubs.jar 补齐
//      （JavaApp/Makefile Task158 规则——它恒在 -cp → 恒在 java.class.path →
//      自动成为 MC-BOOTSTRAP 模块，GameNarrator 可加载）；
//   ④ 但【真实游戏库】缺失仍是模块层的静默黑洞：BootstrapLauncher 对不
//      存在的路径 Files.notExists → continue，磁盘上缺哪个 jar，哪个 jar 的
//      全部类就在模块层凭空消失——游戏内第一个触类点抛 NoClassDefFoundError，
//      用户看到的只是"Forge 闪退"。
//
// 本闸门把④变成可自愈/可诊断：JVM 启动前遍历合并版 JSON 的 libraries，
// 逐个核对磁盘存在性，缺者同步下载（官方源 → BMCLAPI 镜像双路），失败仅
// 记日志点名（非阻断——历史证明部分库缺失可被容忍，如 oshi/objc-bridge；
// 阻断会把"可容忍缺失"误伤成"无法启动"）。
// ============================================================================
static NSData *ame158_fetchSynchronous(NSString *urlString) {
    NSURL *ame158_url = [NSURL URLWithString:urlString];
    if (!ame158_url) return nil;
    NSURLSessionConfiguration *ame158_cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    ame158_cfg.timeoutIntervalForRequest = 20.0;
    ame158_cfg.timeoutIntervalForResource = 45.0;
    NSURLSession *ame158_session = [NSURLSession sessionWithConfiguration:ame158_cfg];
    dispatch_semaphore_t ame158_sem = dispatch_semaphore_create(0);
    __block NSData *ame158_result = nil;
    NSURLSessionDataTask *ame158_task = [ame158_session dataTaskWithURL:ame158_url
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error == nil && data.length > 0 &&
                [response isKindOfClass:NSHTTPURLResponse.class] &&
                [(NSHTTPURLResponse *)response statusCode] == 200) {
                ame158_result = data;
            }
            dispatch_semaphore_signal(ame158_sem);
        }];
    [ame158_task resume];
    dispatch_semaphore_wait(ame158_sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50.0 * NSEC_PER_SEC)));
    [ame158_task cancel];
    return ame158_result;
}

// BMCLAPI 镜像改写（与 ForgeDirectInstaller/PLMirrorCenter 同源的host 映射）
static NSString *ame158_bmclapiMirror(NSString *urlString) {
    NSString *ame158_mojang = @"https://libraries.minecraft.net/";
    NSString *ame158_forge = @"https://maven.minecraftforge.net/";
    if ([urlString hasPrefix:ame158_mojang]) {
        return [@"https://bmclapi2.bangbang93.com/libraries/"
            stringByAppendingString:[urlString substringFromIndex:ame158_mojang.length]];
    }
    if ([urlString hasPrefix:ame158_forge]) {
        return [@"https://bmclapi2.bangbang93.com/maven/"
            stringByAppendingString:[urlString substringFromIndex:ame158_forge.length]];
    }
    return nil;
}

static void ame158_repairMissingLibraries(NSDictionary *launchTarget) {
    const char *ame158_gameDir = getenv("POJAV_GAME_DIR");
    if (!ame158_gameDir || !*ame158_gameDir) return;
    NSArray *ame158_libs = [launchTarget[@"libraries"] isKindOfClass:NSArray.class]
        ? launchTarget[@"libraries"] : nil;
    if (ame158_libs.count == 0) return;

    NSFileManager *ame158_fm = NSFileManager.defaultManager;
    NSString *ame158_libRoot = [@(ame158_gameDir) stringByAppendingPathComponent:@"libraries"];
    NSUInteger ame158_present = 0, ame158_repaired = 0, ame158_failed = 0, ame158_skipped = 0;

    for (NSDictionary *ame158_lib in ame158_libs) {
        if (![ame158_lib isKindOfClass:NSDictionary.class]) continue;
        NSString *ame158_name = [ame158_lib[@"name"] isKindOfClass:NSString.class]
            ? ame158_lib[@"name"] : nil;
        // 与 Java 侧 preProcessLibraries 的 _skip 集合同步：LWJGL 自带、
        // text2speech 由 mojang-stubs 桩提供（真实 jar 进 classpath 会与桩
        // split-package，Task158 语义下必须留在 classpath 之外）、twitch 弃用。
        if (!ame158_name ||
            [ame158_name hasPrefix:@"org.lwjgl:"] ||
            [ame158_name hasPrefix:@"com.mojang:text2speech"] ||
            [ame158_name hasPrefix:@"net.java.dev.jna:platform:"] ||
            [ame158_name hasPrefix:@"tv.twitch"]) {
            ame158_skipped++;
            continue;
        }
        // client 伪库条目（tweakVersionJson 添加，path 相对 libraries 的 ../versions）
        if ([ame158_lib[@"skip"] boolValue]) { ame158_skipped++; continue; }
        // OS 规则（iOS 视作 osx）：规则不允许的 natives 类库不需要
        id ame158_rules = ame158_lib[@"rules"];
        if ([ame158_rules isKindOfClass:NSArray.class] &&
            [(NSArray *)ame158_rules count] > 0 &&
            ![MinecraftResourceUtils evaluateRules:(NSArray *)ame158_rules]) {
            ame158_skipped++;
            continue;
        }
        NSDictionary *ame158_artifact =
            [ame158_lib[@"downloads"][@"artifact"] isKindOfClass:NSDictionary.class]
                ? ame158_lib[@"downloads"][@"artifact"] : nil;
        NSString *ame158_rel = [ame158_artifact[@"path"] isKindOfClass:NSString.class]
            ? ame158_artifact[@"path"] : nil;
        // 相对路径含 ".."（版本 jar 伪条目）或无 path 的条目不由本闸门处理
        if (!ame158_rel || [ame158_rel containsString:@".."]) { ame158_skipped++; continue; }
        NSString *ame158_dest = [ame158_libRoot stringByAppendingPathComponent:ame158_rel];
        if ([ame158_fm fileExistsAtPath:ame158_dest]) { ame158_present++; continue; }

        NSString *ame158_url = [ame158_artifact[@"url"] isKindOfClass:NSString.class]
            ? ame158_artifact[@"url"] : nil;
        if (!ame158_url) {
            ame158_failed++;
            NSLog(@"[JavaLauncher] Task158: library jar missing and no download URL: %@ (%@)",
                  ame158_name, ame158_dest.lastPathComponent);
            continue;
        }
        NSLog(@"[JavaLauncher] Task158: downloading missing library jar: %@", ame158_name);
        NSData *ame158_blob = ame158_fetchSynchronous(ame158_url);
        if (!ame158_blob) {
            NSString *ame158_mirror = ame158_bmclapiMirror(ame158_url);
            if (ame158_mirror) {
                ame158_blob = ame158_fetchSynchronous(ame158_mirror);
            }
        }
        if (ame158_blob) {
            NSString *ame158_parent = ame158_dest.stringByDeletingLastPathComponent;
            [ame158_fm createDirectoryAtPath:ame158_parent
                      withIntermediateDirectories:YES attributes:nil error:nil];
            if ([ame158_blob writeToFile:ame158_dest options:NSDataWritingAtomic error:nil]) {
                ame158_repaired++;
                NSLog(@"[JavaLauncher] Task158: repaired %@ (%lu bytes)",
                      ame158_dest.lastPathComponent, (unsigned long)ame158_blob.length);
                continue;
            }
        }
        ame158_failed++;
        NSLog(@"[JavaLauncher] Task158: could NOT download missing library %@ -- classes in this jar will be absent (possible in-game NoClassDefFoundError)", ame158_name);
    }

    if (ame158_repaired > 0 || ame158_failed > 0) {
        NSLog(@"[JavaLauncher] Task158: library gate summary: %lu present, %lu repaired, %lu failed, %lu skipped",
              (unsigned long)ame158_present, (unsigned long)ame158_repaired,
              (unsigned long)ame158_failed, (unsigned long)ame158_skipped);
    } else {
        NSLog(@"[JavaLauncher] Task158: library gate clean (%lu present, %lu skipped)",
              (unsigned long)ame158_present, (unsigned long)ame158_skipped);
    }
}

// Task181：老 Forge（1.x 谱系）SplashProgress 禁用（1.8.9+vgpu 会话崩溃根修）。
// 病历（afa23a6 装机 latestlog.txt，Forge 11.15.1.2318 + libvgpu）：
//   1. Forge 1.7.x–1.12.2 的 SplashProgress 在独立线程（Thread-7）里抢 GL
//      上下文做闪屏纹理——日志实锤 "Texture creation: Invalid enum"
//      （SplashProgress.checkGLError）+ eglCreateWindowSurface 0x3003；
//   2. 随后主线程 LoadingScreenRenderer 构造 Framebuffer 时
//      glCheckFramebufferStatus 返回 unknown status:0 → 崩溃（splash 线程
//      与主线程的 GL 状态在共享 ctx 上互相踩踏）。
// 移动端单上下文环境无法承载 SplashProgress 的多线程 GL 模型，Pojav 系
// 对老 Forge 的标准处理就是禁用 splash。规则：文件不存在 → 写
// enabled=false 最小配置；存在且 enabled=true → 备份后就地改 false；
// 已是 false → 不动。仅 Forge 1.x 谱系生效（vanilla/fabric/neoforge 不写；
// 1.13+ Forge 已移除 SplashProgress，写了也无害，但一并限 1.x 保持最小面）。
static void ame181_disableLegacyForgeSplash(NSString *gameDir, NSString *versionId) {
    if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0) return;
    if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) return;
    NSString *ame181_lower = versionId.lowercaseString;
    if ([ame181_lower rangeOfString:@"neoforge"].location != NSNotFound) return;  // NeoForge 26.x earlydisplay 另案（Task181 已修 GLFW 指针错位）
    if ([ame181_lower rangeOfString:@"forge"].location == NSNotFound) return;
    if (ame98_mcMajorFromVersionId(versionId) != 1) return;  // 仅 1.x 谱系

    NSString *ame181_cfgDir = [gameDir stringByAppendingPathComponent:@"config"];
    NSString *ame181_path = [ame181_cfgDir stringByAppendingPathComponent:@"splash.properties"];
    NSFileManager *ame181_fm = [NSFileManager defaultManager];
    if (![ame181_fm fileExistsAtPath:ame181_path]) {
        [ame181_fm createDirectoryAtPath:ame181_cfgDir
              withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *ame181_body = @"# Written by Amethyst (Task181): SplashProgress disabled -- its background-thread GL breaks single-context mobile renderers.\nenabled=false\n";
        if ([ame181_body writeToFile:ame181_path atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            NSLog(@"[JavaLauncher] Task181: legacy Forge splash disabled (wrote %@, versionId=%@)", ame181_path.lastPathComponent, versionId);
        }
        return;
    }
    // 已有文件：只改 enabled 行（备份 .amethyst-bak）。
    NSString *ame181_old = [NSString stringWithContentsOfFile:ame181_path encoding:NSUTF8StringEncoding error:nil];
    if (![ame181_old isKindOfClass:[NSString class]]) return;
    if ([ame181_old rangeOfString:@"enabled=false"].location != NSNotFound) return;  // 已禁用
    NSArray<NSString *> *ame181_lines = [ame181_old componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *ame181_out = [NSMutableArray arrayWithCapacity:ame181_lines.count];
    BOOL ame181_flipped = NO;
    for (NSString *ame181_line in ame181_lines) {
        if (!ame181_flipped && [ame181_line hasPrefix:@"enabled"]) {
            [ame181_out addObject:@"enabled=false"];
            ame181_flipped = YES;
        } else {
            [ame181_out addObject:ame181_line];
        }
    }
    if (!ame181_flipped) {
        // 文件里没有 enabled 行（异常档案）：追加一行。
        [ame181_out addObject:@"enabled=false"];
        ame181_flipped = YES;
    }
    NSString *ame181_bak = [ame181_path stringByAppendingString:@".amethyst-bak"];
    [ame181_fm removeItemAtPath:ame181_bak error:nil];
    if ([ame181_fm copyItemAtPath:ame181_path toPath:ame181_bak error:nil]) {
        NSString *ame181_new = [ame181_out componentsJoinedByString:@"\n"];
        if ([ame181_new writeToFile:ame181_path atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
            NSLog(@"[JavaLauncher] Task181: legacy Forge splash disabled (flipped enabled->false in existing %@, backup kept, versionId=%@)",
                  ame181_path.lastPathComponent, versionId);
        }
    } else {
        NSLog(@"[JavaLauncher] Task181: WARN backup failed, leaving splash.properties untouched (%@)", ame181_path.lastPathComponent);
    }
}

// ==================== Task 217：自动渲染器智能化（崩溃自学 + 决策留痕） ====================
//
// 设计要点（病历与边界）：
// - 裁决信号选用 hs_err_pid*.log 的 mtime：JVM 收到 SIGSEGV/SIGILL/SIGABRT
//   等致命信号时由 -XX:ErrorFile 写出（Task 27 定向到 POJAV_HOME）；而
//   FastQuit / 正常退出走 exit(0)，不落 hs_err——两类死亡天然可区分。
//   SIGKILL（内存 jetsam）不落 hs_err，会被误判为"干净"——保守方向的
//   假阴性（宁可漏学不误学），内存类死亡另有诊断链（Task106 病历）。
// - 计数与拉黑存实例偏好（launcher_preferences.plist，get/setPrefObject
//   通道）：auto 渲染器本就是 profile 级语义，实例粒度已覆盖单版本实例
//   的主流形态；多 profile 共实例时共享一份学习状态，方向仍正确。
// - 显式选择的渲染器永远不经此链（本函数只在 AMETHYST_RENDERER=="auto"
//   分支被调用）；用户手动显式选回被拉黑的渲染器时，顺手清掉其拉黑态
//   （逃生舱：学习永不绑架用户意图）。
// - 连败阈值 2：一次崩溃可能是偶发（mod 冲突/瞬时资源），两次连续信号级
//   死亡才定性为渲染器问题；干净会话即清零计数。

/// 渲染器在主 bundle Frameworks/ 下的存在性（与 Task144 内联检查同口径）。
static BOOL ame217_rendererDylibPresent(const char *rendererName) {
    if (!rendererName || !rendererName[0]) return NO;
    NSString *path = [NSBundle.mainBundle.bundlePath
        stringByAppendingPathComponent:[@"Frameworks" stringByAppendingPathComponent:@(rendererName)]];
    return [NSFileManager.defaultManager fileExistsAtPath:path];
}

/// Task217：裁决上一会话（崩溃自学的记分员）。在每次 auto 解析前调用。
/// 读哨兵（.ame217_session："<renderer>|<epoch>"）→ 扫描 POJAV_HOME 下
/// mtime 晚于哨兵时间的 hs_err_pid*.log：有 = 上一会话信号级死亡 → 经
/// CrashAnalyzer 分型后记连败（OOM 不记锅、渲染器归因优先）；无 = 干净
/// 会话 → 清该渲染器连败。哨兵读后即删（幂等，单次裁决）。
///
/// Task218 升级（用户指令："依据判断脚本和参考 FCL 改进崩溃识别"）：
///   1. 取"最新"hs_err（旧实现对目录序首个命中即 break，多崩溃文件并存的
///      场景可能裁决到旧文件）；
///   2. 读 hs_err 内容分型（信号 / OOM / Problematic frame / native 帧），
///      而不是只看文件存在；
///   3. OOM 不记渲染器连败（内存不足不是渲染器的锅），诊断走降内存建议；
///   4. 渲染器归因：崩溃帧命中渲染器家族库时，连败记在被归因渲染器头上
///      （即使 auto 会话解析的是另一个——同库族伴生崩溃不再张冠李戴）；
///   5. FCL 式诊断弹窗：每个崩溃文件只弹一次，呈现分型 + 处置建议 +
///      "查看崩溃报告"（系统分享面板导出 hs_err 原文件）。

/// Task218：FCL 式崩溃诊断弹窗（定义见下方；先声明供裁决器调用）。
static void ame218_showCrashDiagnosis(NSDictionary *diag, NSString *hsErrPath,
                                      BOOL blacklisted, NSString *failRenderer);

static void ame217_autoRendererAdjudicateLastSession(void) {
    NSString *home = @(getenv("POJAV_HOME"));
    if (home.length == 0) return;
    NSString *sentinelPath = [home stringByAppendingPathComponent:@".ame217_session"];
    NSString *sentinel = [NSString stringWithContentsOfFile:sentinelPath
        encoding:NSUTF8StringEncoding error:nil];
    [NSFileManager.defaultManager removeItemAtPath:sentinelPath error:nil];
    if (sentinel.length == 0) return;

    NSArray<NSString *> *parts = [sentinel componentsSeparatedByString:@"|"];
    if (parts.count < 2) return;
    NSString *renderer = parts[0];
    long long epoch = [parts[1] longLongValue];
    if (renderer.length == 0 || epoch <= 0) return;

    // Task218：多崩溃文件并存时取 mtime 最新的一份（旧实现目录序首个即
    // break——裁决到旧文件会把上上会话的死法记到本会话头上）。
    NSString *newestHsErr = nil;
    NSTimeInterval newestMtime = 0;
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:home error:nil]) {
        if (![entry hasPrefix:@"hs_err_pid"] || ![entry hasSuffix:@".log"]) continue;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:
            [home stringByAppendingPathComponent:entry] error:nil];
        NSDate *mtime = attrs.fileModificationDate;
        if (!mtime) continue;
        NSTimeInterval t = [mtime timeIntervalSince1970];
        if (t >= (NSTimeInterval)(epoch - 2) && t > newestMtime) {
            newestMtime = t;
            newestHsErr = entry;
        }
    }

    if (newestHsErr) {
        // ---- Task218 分型（CrashAnalyzer：信号 / OOM / 渲染器归因）----
        NSString *hsErrPath = [home stringByAppendingPathComponent:newestHsErr];
        NSDictionary *diag = [CrashAnalyzer analyzeHsErrFile:hsErrPath];
        BOOL isOOM = [diag[@"isOOM"] boolValue];
        NSString *blamed = diag[@"blamedRenderer"];

        if (isOOM) {
            // OOM：内存不足不是渲染器的锅（判断脚本口径：insufficient memory
            // 头）。连败不动，诊断弹窗给降内存/砍模组建议。
            NSLog(@"[JavaLauncher] Task218: last session (%@) classified OOM (signal %@) -- renderer fail counts untouched",
                  newestHsErr, diag[@"signal"]);
        } else {
            // 归因优先：崩溃帧命中渲染器家族库 -> 连败记它；否则记 auto
            // 会话渲染器（Task217 保守语义）。
            NSString *failRenderer = blamed ?: renderer;
            if (blamed && ![blamed isEqualToString:renderer]) {
                NSLog(@"[JavaLauncher] Task218: crash frames blame '%@' while auto session ran '%@' -- counting against the blamed renderer",
                      blamed, renderer);
            }
            NSString *failKey = [NSString stringWithFormat:@"ame217.autoRendererFails.%@", failRenderer];
            NSInteger fails = getPrefInt(failKey) + 1;
            if (fails >= 2) {
                NSString *blacklist = getPrefObject(@"ame217.autoRendererBlacklist");
                NSString *entry = [NSString stringWithFormat:@",%@", failRenderer];
                if (![blacklist isKindOfClass:[NSString class]] ||
                    ![blacklist containsString:failRenderer]) {
                    NSString *merged = ([blacklist isKindOfClass:[NSString class]] && blacklist.length > 0)
                        ? [blacklist stringByAppendingString:entry] : failRenderer;
                    setPrefObject(@"ame217.autoRendererBlacklist", merged);
                    NSLog(@"[JavaLauncher] Task217: auto renderer '%@' BLACKLISTED after %ld consecutive hs_err sessions (last: %@) -- auto falls to next candidate",
                          failRenderer, (long)fails, newestHsErr);
                }
                setPrefObject(failKey, @0);
                // 拉黑即弹诊断（含降级提示），不复用文件级去重键
                ame218_showCrashDiagnosis(diag, hsErrPath, YES, failRenderer);
                return;
            } else {
                setPrefObject(failKey, @(fails));
                NSLog(@"[JavaLauncher] Task217: last session (%@) died with hs_err under auto renderer '%@' (blamed: %@) -- fail count %ld/2",
                      newestHsErr, renderer, blamed ?: renderer, (long)fails);
            }
        }

        // ---- FCL 式诊断弹窗（每个崩溃文件只弹一次）----
        NSString *shownKey = @"ame218.crashDialogShownFor";
        NSString *shownFor = getPrefObject(shownKey);
        if (![shownFor isKindOfClass:[NSString class]] || ![shownFor isEqualToString:newestHsErr]) {
            setPrefObject(shownKey, newestHsErr);
            ame218_showCrashDiagnosis(diag, hsErrPath, NO, nil);
        }
    } else {
        NSString *failKey = [NSString stringWithFormat:@"ame217.autoRendererFails.%@", renderer];
        if (getPrefInt(failKey) > 0) {
            NSLog(@"[JavaLauncher] Task217: last session under auto renderer '%@' was clean -- fail count reset", renderer);
        }
        setPrefObject(failKey, @0);
    }
}

/// Task218：FCL 式崩溃诊断弹窗（参考 Fold Craft Launcher 的崩溃呈现：
/// 崩溃类型 + 可能原因 + 处置建议，而不是只在后台记一笔）。非阻塞——
/// 弹窗出现时本次启动照常进行；"查看崩溃报告"经系统分享面板导出
/// hs_err 原文件（与 Task175 弹窗同款 top-VC 呈现链，本文件已验证）。
static void ame218_showCrashDiagnosis(NSDictionary *diag, NSString *hsErrPath, BOOL blacklisted, NSString *failRenderer) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *signal = diag[@"signal"] ?: @"(unknown)";
        NSString *frame = diag[@"problematicFrame"] ?: @"";
        NSString *body = nil;
        if ([diag[@"isOOM"] boolValue]) {
            body = [NSString stringWithFormat:localize(@"ame218.crash.oom.body", nil), signal];
        } else if (diag[@"blamedRenderer"]) {
            body = [NSString stringWithFormat:localize(@"ame218.crash.renderer.body", nil),
                    signal, diag[@"blamedRenderer"], frame];
        } else {
            body = [NSString stringWithFormat:localize(@"ame218.crash.unknown.body", nil), signal, frame];
        }
        if (blacklisted) {
            body = [body stringByAppendingString:
                [NSString stringWithFormat:localize(@"ame218.crash.blacklisted", nil), failRenderer ?: @""]];
        }

        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"ame218.crash.title", nil)
                             message:body
                      preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame218.crash.view", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            // 系统分享面板导出 hs_err 原文件（存储到"文件"App / AirDrop / 反馈渠道）
            NSURL *ame218_fileURL = [NSURL fileURLWithPath:hsErrPath];
            UIActivityViewController *ame218_share =
                [[UIActivityViewController alloc] initWithActivityItems:@[ame218_fileURL]
                                                 applicationActivities:nil];
            UIViewController *ame218_top = nil;
            for (UIWindowScene *ame218_scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
                if (ame218_scene.activationState == UISceneActivationStateForegroundActive &&
                    ame218_scene.windows.count > 0) {
                    ame218_top = ame218_scene.windows.firstObject.rootViewController;
                    while (ame218_top.presentedViewController != nil) {
                        ame218_top = ame218_top.presentedViewController;
                    }
                    break;
                }
            }
            if (ame218_top) {
                [ame218_top presentViewController:ame218_share animated:YES completion:nil];
            }
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame218.crash.ok", nil)
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        UIViewController *ame218_presenter = nil;
        for (UIWindowScene *ame218_scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
            if (ame218_scene.activationState == UISceneActivationStateForegroundActive &&
                ame218_scene.windows.count > 0) {
                ame218_presenter = ame218_scene.windows.firstObject.rootViewController;
                while (ame218_presenter.presentedViewController != nil) {
                    ame218_presenter = ame218_presenter.presentedViewController;
                }
                break;
            }
        }
        if (ame218_presenter) {
            [ame218_presenter presentViewController:alert animated:YES completion:nil];
        }
    });
}

/// Task217：auto 候选链决策。版本基线（Task144/173/212）+ dylib 存在性 +
/// 拉黑过滤；全部候选不可用时回落链首（保留可用性兜底，不让拉黑把路堵死）。
static NSString *ame217_autoRendererDecide(NSInteger minVersion) {
    // ★ Task255（清单 8：自动渲染器优化）：≤1.16（minVersion<=8 谱系）候选
    //   链头插 kw（NG-GL4ES，Task206 "Krypton Wrapper"——glslang+SPIRV-Cross
    //   着色器管线，官方口径几乎全版本可跑，老版本 MC 生态的现役首选；
    //   用户指令"1.17 版本以下应使用 kw（nogl4se）渲染器"）。原 ZL2 经典
    //   gl4es 降为第二顺位兜底，dylib 缺失/拉黑过滤链不变。
    NSArray<NSString *> *chain = (minVersion > 8)
        ? @[@ RENDERER_NAME_MOBILEGL, @ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE]
        : @[@ RENDERER_NAME_NGGL4ES, @ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE, @ RENDERER_NAME_MOBILEGL];
    NSString *blacklist = getPrefObject(@"ame217.autoRendererBlacklist");
    BOOL hasBlacklist = [blacklist isKindOfClass:[NSString class]] && blacklist.length > 0;

    NSString *picked = nil;
    NSString *reason = nil;
    for (NSString *candidate in chain) {
        if (!ame217_rendererDylibPresent(candidate.UTF8String)) {
            NSLog(@"[JavaLauncher] Task217: auto candidate %@ skipped (dylib missing from bundle)", candidate);
            continue;
        }
        if (hasBlacklist && [blacklist containsString:candidate]) {
            NSLog(@"[JavaLauncher] Task217: auto candidate %@ skipped (blacklisted by crash learning)", candidate);
            continue;
        }
        picked = candidate;
        reason = (minVersion > 8)
            ? @"modern MC baseline (Task144: 1.17+ MobileGL Vulkan direct)"
            : @"legacy MC baseline (Task255: 1.17- kw/NG-GL4ES first, ZL2 classic gl4es fallback)";
        break;
    }
    if (!picked) {
        picked = chain.firstObject;
        reason = @"all candidates unavailable/blacklisted -- availability fallback to chain head";
    }
    NSLog(@"[JavaLauncher] Task217/255: auto renderer decision: minVersion=%ld chain=%@ blacklist=%@ -> %@ (%@)",
          (long)minVersion, chain, hasBlacklist ? blacklist : @"(none)", picked, reason);
    return picked;
}

// ==================== Task 217 结束 ====================

// ★ Task286（PocketJ 对标移植）：新实例 options.txt 首启性能播种——
//   MC 首启生成的默认档（mipmap 4 / 粒子全量 / 视距 12 / 模拟距离 12）
//   对移动端过重，首启即"掉帧+烫"的差评窗口。JVM 启动前、MC
//   Options.load 之前写入一份均衡档（仅 options.txt 不存在时 = 新实例
//   首启；已有实例的玩家选择零触碰）。取值与上游 PocketJ
//   MinecraftOptionUtils 同思路但视距放宽（其 2 为超低端定标，本仓取 8
//   作 iOS 均衡默认；游戏内均可再调）。
static void ame286_seedFirstLaunchPerformanceOptions(NSString *gameDir) {
    if (gameDir.length == 0) return;
    NSString *ame286_optPath = [gameDir stringByAppendingPathComponent:@"options.txt"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:ame286_optPath]) return;
    NSString *ame286_seed = @"mipmapLevels:0\n"
                            @"particleStatus:1\n"
                            @"renderDistance:8\n"
                            @"simulationDistance:6\n"
                            @"fullscreen:false\n";
    if ([ame286_seed writeToFile:ame286_optPath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
        NSLog(@"[JavaLauncher] Task286: first-launch options.txt performance seed written (%@)",
              gameDir.lastPathComponent);
    } else {
        NSLog(@"[JavaLauncher] Task286: first-launch options.txt seed write failed, MC defaults will apply");
    }
}

// ★ Task302：死调试器残留异常端口清除（"游戏卡在准备"根修）。
// 病历（Task301 看门狗只能兜底报错，救不了启动）：StikDebug 会话中途被杀
// （用户上滑 StikDebug）后，debugserver 曾在本任务登记的 task/thread 级
// 断点/软件异常端口变成死名——后续 JIT26CreateRegionLegacy 的 brk #0x69
// 异常投递进死端口 mach_msg 永久等待，SIGTRAP 安全网（JIT26TrapCatch）
// 永远收不到信号，启动界面停在"正在准备运行环境…"（装机日志 2026-10-19
// "游戏依旧卡在准备"）。修法：区域创建前扫描本任务与全部线程的
// EXC_BREAKPOINT/EXC_SOFTWARE 端口，mach_port_kobject 命中死名
// （KERN_INVALID_RIGHT/KERN_INVALID_NAME）即 set_exception_ports 置空
// 回收——brk 随即回落 BSD 层 SIGTRAP → 安全网接管建区 → 无调试器
// （jitless）也能继续启动。活调试器端口（kobject 命中）绝不触碰，
// StikDebug 附加中的会话不受影响。
static void ame302_clearStaleDebuggerPorts(void) {
    mach_port_t ame302_task = mach_task_self();
    exception_mask_t ame302_want = EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE;
    exception_mask_t ame302_masks[EXC_TYPES_COUNT];
    mach_port_t ame302_ports[EXC_TYPES_COUNT];
    exception_behavior_t ame302_behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t ame302_flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t ame302_count = EXC_TYPES_COUNT;
    if (task_get_exception_ports(ame302_task, ame302_want, ame302_masks,
                                 &ame302_count, ame302_ports,
                                 ame302_behaviors, ame302_flavors) == KERN_SUCCESS) {
        for (mach_msg_type_number_t ame302_i = 0; ame302_i < ame302_count; ame302_i++) {
            if (ame302_ports[ame302_i] == MACH_PORT_NULL) continue;
            mach_port_type_t ame302_ptype = 0;
            kern_return_t ame302_kr = mach_port_type(ame302_task, ame302_ports[ame302_i], &ame302_ptype);
            if (ame302_kr == KERN_SUCCESS && (ame302_ptype & MACH_PORT_TYPE_DEAD_NAME)) {
                task_set_exception_ports(ame302_task, ame302_masks[ame302_i], MACH_PORT_NULL,
                                         ame302_behaviors[ame302_i], ame302_flavors[ame302_i]);
                NSLog(@"[JIT] [JavaLauncher] Task302 stale TASK exception port cleared (mask=0x%x ptype=0x%x) -- brk falls back to SIGTRAP net",
                      ame302_masks[ame302_i], ame302_ptype);
            } else if (ame302_kr == KERN_SUCCESS) {
                NSLog(@"[JIT] [JavaLauncher] Task302 live debugger TASK port present (ptype=0x%x) -- untouched", ame302_ptype);
            }
        }
    }
    // 线程级清扫（debugserver 部分路径挂 thread 端口）
    thread_act_array_t ame302_threads = NULL;
    mach_msg_type_number_t ame302_tcount = 0;
    if (task_threads(ame302_task, &ame302_threads, &ame302_tcount) == KERN_SUCCESS) {
        for (mach_msg_type_number_t ame302_t = 0; ame302_t < ame302_tcount; ame302_t++) {
            mach_msg_type_number_t ame302_tn = EXC_TYPES_COUNT;
            exception_mask_t ame302_tm[EXC_TYPES_COUNT];
            mach_port_t ame302_tp[EXC_TYPES_COUNT];
            exception_behavior_t ame302_tb[EXC_TYPES_COUNT];
            thread_state_flavor_t ame302_tf[EXC_TYPES_COUNT];
            if (thread_get_exception_ports(ame302_threads[ame302_t], ame302_want,
                                           ame302_tm, &ame302_tn, ame302_tp,
                                           ame302_tb, ame302_tf) == KERN_SUCCESS) {
                for (mach_msg_type_number_t ame302_j = 0; ame302_j < ame302_tn; ame302_j++) {
                    if (ame302_tp[ame302_j] == MACH_PORT_NULL) continue;
                    mach_port_type_t ame302_tptype = 0;
                    kern_return_t ame302_tkr = mach_port_type(ame302_task, ame302_tp[ame302_j], &ame302_tptype);
                    if (ame302_tkr == KERN_SUCCESS && (ame302_tptype & MACH_PORT_TYPE_DEAD_NAME)) {
                        thread_set_exception_ports(ame302_threads[ame302_t], ame302_tm[ame302_j], MACH_PORT_NULL,
                                                   ame302_tb[ame302_j], ame302_tf[ame302_j]);
                        NSLog(@"[JIT] [JavaLauncher] Task302 stale THREAD exception port cleared (thread=%u mask=0x%x)",
                              ame302_threads[ame302_t], ame302_tm[ame302_j]);
                    }
                }
            }
        }
        if (ame302_threads) {
            vm_deallocate(ame302_task, (vm_address_t)ame302_threads,
                          ame302_tcount * sizeof(thread_act_t));
        }
    }
}

// ★ Task301：JIT26 brk 握手有界看门狗（launchJVM / launchHeadlessJVM 共用）。
// 病历（用户 2026-10-19"启动不了游戏呢，卡住了"）：isJITEnabled=CS_DEBUGGED
// 是进程级持久态——早前 StikDebug 会话成功附加过后，即使调试器已被用户杀掉，
// CS_DEBUGGED 仍为 1，启动门秒过；而死调试器残留的任务级断点异常端口让
// brk #0x69 进 mach_msg 永久等待，SIGTRAP 安全网（JIT26TrapCatch）根本收
// 不到信号 = heap ceiling/mods 扫描后零后续日志零弹窗的"永久卡住"。
// 修法：区域创建放后台线程 + 20s 有界等待；超时自动跑内置 JIT 轨（其
// debugserver 接管后应答挂起的 brk），再给 brk 线程 90s 收尾窗口；仍无果
// 返回 NULL 走既有优雅失败弹窗。泄漏一条阻塞线程优于整机永久卡死。
static void* ame301_createRegionWithWatchdog(void) {
    // ★ Task302：区域创建前先清死调试器残留端口（根修见函数注释）——
    //   brk #0x69 从此回落 SIGTRAP 安全网，jitless 也能建区继续启动。
    ame302_clearStaleDebuggerPorts();
    dispatch_semaphore_t ame301_done = dispatch_semaphore_create(0);
    __block void *ame301_region = NULL;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ame301_region = JIT26CreateRegionLegacySafe(getpagesize());
        dispatch_semaphore_signal(ame301_done);
    });
    // 第一轮 20s：活调试器在场的正常握手毫秒级完成
    if (dispatch_semaphore_wait(ame301_done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)20 * NSEC_PER_SEC)) == 0) {
        return ame301_region;
    }
    NSLog(@"[JIT] [JavaLauncher] Task301 brk handshake stalled >20s (dead debugger exception port?) -- auto-running builtin JIT track to service it");
    BOOL ame301_builtinAvail = [StikDebugViewController ame294_builtinTrackAvailable];
    if (ame301_builtinAvail) {
        dispatch_semaphore_t ame301_builtinSem = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_main_queue(), ^{
            [StikDebugViewController ame294_enableBuiltinJITWithCompletion:^(BOOL success, NSString *message) {
                NSLog(@"[JIT] [JavaLauncher] Task301 watchdog builtin track: success=%d msg=%@", success, message);
                dispatch_semaphore_signal(ame301_builtinSem);
            }];
        });
        // 内置轨首跑含 DDI 下载可达数分钟（600s 上限）；期间 brk 线程若先完成
        // （新调试器接管应答了挂起的 brk）则提前出线
        for (int ame301_i = 0; ame301_i < 600; ame301_i++) {
            if (dispatch_semaphore_wait(ame301_builtinSem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)1 * NSEC_PER_SEC)) == 0) break;
            if (dispatch_semaphore_wait(ame301_done, DISPATCH_TIME_NOW) == 0) {
                NSLog(@"[JIT] [JavaLauncher] Task301 stalled brk thread got serviced mid-builtin -- resuming launch");
                return ame301_region;
            }
        }
        NSLog(@"[JIT] [JavaLauncher] Task301 builtin track done -- 90s grace for the stalled brk thread");
    } else {
        NSLog(@"[JIT] [JavaLauncher] Task301 builtin track unavailable -- 60s grace for the stalled brk thread");
        if (dispatch_semaphore_wait(ame301_done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)60 * NSEC_PER_SEC)) == 0) {
            return ame301_region;
        }
        return NULL;
    }
    if (dispatch_semaphore_wait(ame301_done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)90 * NSEC_PER_SEC)) == 0) {
        return ame301_region;
    }
    NSLog(@"[JIT] [JavaLauncher] Task301 brk handshake never serviced -- failing launch gracefully (JIT dialog follows)");
    return NULL;
}

// ★ Task304：主启动链 JIT 自动申请（用户 2026-10-19"启动重命名之后显示启动
//   画面了，但是没有依据用户选择的jit启动器申请权限，比如我的是stikdebug"）。
//   病历：RightPanel/NavigationController/DownloadVC 三条启动入口都有
//   Task134/139/267 式申请+等待链（ame169_waitForJITCondition），唯
//   SurfaceViewController 主链（点启动 → 启动画面 → launchJVM）零 JIT 申请
//   ——用户按 debug.jit_enabler 偏好选了 StikDebug，启动时却从未被带去申请，
//   区域创建在无调试器下看门狗空转后优雅失败（体感"没申请权限"）。
//   语义（launchHeadlessJVM Task139 段同构，主链场景去掉了"正在开启 JIT"
//   等待提示弹窗——启动画面本身就是反馈；builtin 显式失败的如实报错保留；
//   manual 模式保留提示弹窗否则零反馈）：
//   - isJITEnabled=YES → 立即返回 YES（零开销）；
//   - debug_skip_wait_jit=YES → 返回 YES（旧语义直接放行）；
//   - 否则按 debug.jit_enabler 偏好发起申请（stikjit:// / trollstore /
//     sidestore / stosdebug / jitstreamer / builtin；LC guest 下 Task302
//     builtinTrackAvailable=NO → auto 自动降级深链），ame169 等待环 120s
//     有界轮询。
//   返回 YES = 已开启/无需申请/等待成功；NO = 超时（调用方继续走既有区域
//   创建看门狗，jitless 优雅失败路径不受影响——不新增 return 路径）。
//   线程约定：launchJVM 运行线程（后台）；openURL 必须主线程——非主线程
//   dispatch_sync(main) 派发申请体（headless 同款模式），主线程上下文直接
//   执行；等待环纯轮询无主队列依赖（utils.m ame169 实现），两态皆安全。
static BOOL ame304_requestAndAwaitJITIfNeeded(NSString *tag) {
    if (isJITEnabled(NO)) {
        return YES;
    }
    if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"[JIT] [%@] Task304: debug_skip_wait_jit set -- proceeding without JIT", tag);
        return YES;
    }
    NSLog(@"[JIT] [%@] Task304: JIT not enabled -- auto-requesting via configured enabler", tag);

    __block BOOL ame304_requested = NO;
    void (^ame304_request)(void) = ^{
        NSString *ame304_enabler = getPrefObject(@"debug.jit_enabler");
        if (![ame304_enabler isKindOfClass:NSString.class] || ame304_enabler.length == 0) {
            ame304_enabler = @"auto";
        }
        BOOL ame304_noScript = getPrefBool(@"debug.jit26_script_disable");
        NSString *ame304_bundleId = NSBundle.mainBundle.bundleIdentifier;
        // Task294/302 同口径：builtin 显式 + auto 非 TS 环境按可用性
        BOOL ame304_isTrollStore = getEntitlementValue(@"jb.pmap_cs.custom_trust") && isTrollStoreInstall();
        BOOL ame304_builtinAvail = [StikDebugViewController ame294_builtinTrackAvailable];
        BOOL ame304_useBuiltin = NO;
        if ([ame304_enabler isEqualToString:@"builtin"]) {
            ame304_useBuiltin = YES;
        } else if ([ame304_enabler isEqualToString:@"auto"] && !ame304_isTrollStore) {
            ame304_useBuiltin = ame304_builtinAvail;
        }
        NSLog(@"[JIT] [%@] Task304 enabler=%@ noScript=%d builtin=%d (avail=%d ts=%d)",
              tag, ame304_enabler, ame304_noScript, ame304_useBuiltin, ame304_builtinAvail, ame304_isTrollStore);
        NSURL *ame304_url = nil;
        if (ame304_useBuiltin) {
            ame304_requested = YES;
            [StikDebugViewController ame294_enableBuiltinJITWithCompletion:^(BOOL success, NSString *message) {
                if (success || isJITEnabled(YES)) {
                    NSLog(@"[JIT] [%@] Task304 builtin track OK", tag);
                    return;
                }
                NSLog(@"[JIT] [%@] Task304 builtin track failed: %@", tag, message);
                if ([ame304_enabler isEqualToString:@"builtin"]) {
                    // 显式 builtin：如实报错，不擅自跳第三方（Task294 语义）
                    NSString *detail = message.length ? message : localize(@"ame293.jit.builtin_fail_title", nil);
                    if ([detail localizedCaseInsensitiveContainsString:@"Timed out connecting"] ||
                        [detail localizedCaseInsensitiveContainsString:@"not ready for JIT"]) {
                        detail = [detail stringByAppendingFormat:@"\n\n%@", localize(@"ame294.jit.localdevvpn_hint", nil)];
                    }
                    showDialog(localize(@"ame293.jit.builtin_fail_title", nil), detail);
                } else if (@available(iOS 17.4, *)) {
                    // auto：降级 stikjit:// 深链（等待环继续轮询）
                    NSString *sd = @"";
                    if (!ame304_noScript) {
                        NSData *s = [NSData dataWithContentsOfFile:
                            [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                        if (s) sd = [@"&script-data=" stringByAppendingString:[s base64EncodedStringWithOptions:0]];
                    }
                    [UIApplication.sharedApplication openURL:[NSURL URLWithString:
                        [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", ame304_bundleId, getpid(), sd]]
                        options:@{} completionHandler:nil];
                }
            }];
            return;
        }
        if ([ame304_enabler isEqualToString:@"trollstore"]) {
            ame304_url = [NSURL URLWithString:[NSString stringWithFormat:
                @"apple-magnifier://enable-jit?bundle-id=%@", ame304_bundleId]];
        } else if ([ame304_enabler isEqualToString:@"sidestore"]) {
            ame304_url = [NSURL URLWithString:[NSString stringWithFormat:
                @"sidestore://enable-jit?bundle-id=%@", ame304_bundleId]];
        } else if ([ame304_enabler isEqualToString:@"stosdebug"]) {
            NSString *ame304_appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Amethyst";
            NSMutableString *ame304_u = [NSMutableString stringWithFormat:
                @"stosdebug://enableJIT?bundleId=%@&appName=%@", ame304_bundleId, ame304_appName];
            if (!ame304_noScript) {
                NSData *ame304_script = [NSData dataWithContentsOfFile:
                    [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                if (ame304_script) {
                    [ame304_u appendFormat:@"&script=%@", [ame304_script base64EncodedStringWithOptions:0]];
                }
            }
            ame304_url = [NSURL URLWithString:ame304_u];
        } else if ([ame304_enabler isEqualToString:@"jitstreamer"]) {
            ame304_url = [NSURL URLWithString:[NSString stringWithFormat:
                @"http://[fd00::]:9172/launch_app/%@", ame304_bundleId]];
        } else if ([ame304_enabler isEqualToString:@"manual"]) {
            // 手动模式：不跳转（维持旧语义），仅提示弹窗（主链无此弹窗则零反馈）
            showDialog(localize(@"i18n_str_437", nil), localize(@"i18n_str_439", nil));
        } else if (@available(iOS 17.4, *)) {
            // auto / stikjit 共用 stikjit://
            NSString *ame304_scriptData = @"";
            if (!ame304_noScript) {
                NSData *ame304_script = [NSData dataWithContentsOfFile:
                    [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                if (ame304_script) {
                    ame304_scriptData = [@"&script-data=" stringByAppendingString:[ame304_script base64EncodedStringWithOptions:0]];
                }
            }
            ame304_url = [NSURL URLWithString:[NSString stringWithFormat:
                @"stikjit://enable-jit?bundle-id=%@&pid=%d%@", ame304_bundleId, getpid(), ame304_scriptData]];
        } else {
            ame304_url = [NSURL URLWithString:[NSString stringWithFormat:
                @"sidestore://sidejit-enable?pid=%d", getpid()]];
        }
        if (ame304_url) {
            [UIApplication.sharedApplication openURL:ame304_url options:@{} completionHandler:nil];
        }
        ame304_requested = YES;
    };
    if ([NSThread isMainThread]) {
        ame304_request();
    } else {
        dispatch_sync(dispatch_get_main_queue(), ame304_request);
    }
    if (!ame304_requested) {
        // 申请体未跑成（防御：manual 且无弹窗路径等），按放行处理交看门狗兜底
        NSLog(@"[JIT] [%@] Task304: no request issued (enabler config?) -- proceeding", tag);
        return YES;
    }
    BOOL ame304_ok = ame169_waitForJITCondition(^{ return isJITEnabled(NO); }, 120.0,
        [NSString stringWithFormat:@"%@-JIT", tag] ?: @"Launch-JIT");
    if (!ame304_ok) {
        NSLog(@"[JIT] [%@] Task304 JIT wait timed out (120s) -- continuing (region watchdog will fail gracefully without JIT)", tag);
    } else {
        NSLog(@"[JIT] [%@] Task304 JIT became enabled, continuing launch", tag);
    }
    return ame304_ok;
}

int launchJVM(NSString *accountId, id launchTarget, int width, int height, int minVersion) {
    NSLog(@"[JavaLauncher] Beginning JVM launch");

    // Task175：占位 mainClass 预检（用户实测"forge1.8.9 装整合包后启动 =
    // ClassNotFoundException: net.angelaura.installer.MissingLoader 裸崩"）。
    // ModpackImportService 在 loader 安装失败时写占位 JSON（mainClass 指向
    // 不存在的类）——旧路径让 JVM 起来后在 loadClass 处炸出原始堆栈，
    // 用户无从知道"是装包时加载器没装上"。此处提前拦下：弹窗复用
    // i18n_str_555（"此整合包需要 %@ %@ 加载器，自动安装失败。请通过下载
    // 界面手动安装。"——与导入期报错同文案），不进 JVM 直接返回。
    if ([launchTarget isKindOfClass:NSDictionary.class] &&
        [launchTarget[@"mainClass"] isEqualToString:@"net.angelaura.installer.MissingLoader"]) {
        // 占位 JSON 的 _comment_ 是导入期就写好的本地化完整句（i18n_str_555
        // 展开），比运行时重新拼更可靠；缺席时退回 555 现场展开。
        NSString *ame175_message = [launchTarget[@"_comment_"] isKindOfClass:NSString.class]
            ? launchTarget[@"_comment_"]
            : [NSString stringWithFormat:localize(@"i18n_str_555", nil), @"Forge", @""];
        NSLog(@"[JavaLauncher] Task175: refusing to launch placeholder version JSON (mainClass=net.angelaura.installer.MissingLoader) -- loader install had failed for this modpack");
        dispatch_async(dispatch_get_main_queue(), ^{
            // 标题留空（无现成"加载器安装失败"短标题键，正文自带完整语境；
            // 零新增 l10n）
            UIAlertController *ame175_alert = [UIAlertController
                alertControllerWithTitle:nil
                message:ame175_message
                preferredStyle:UIAlertControllerStyleAlert];
            [ame175_alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.ok", nil)
                                                             style:UIAlertActionStyleDefault handler:nil]];
            UIViewController *ame175_top = nil;
            for (UIWindowScene *ame175_scene in UIApplication.sharedApplication.connectedScenes.allObjects) {
                if (ame175_scene.activationState == UISceneActivationStateForegroundActive &&
                    ame175_scene.windows.count > 0) {
                    ame175_top = ame175_scene.windows.firstObject.rootViewController;
                    while (ame175_top.presentedViewController != nil) {
                        ame175_top = ame175_top.presentedViewController;
                    }
                    break;
                }
            }
            [ame175_top presentViewController:ame175_alert animated:YES completion:nil];
        });
        return 1;
    }

    // 防御检查：headless JVM（Forge/NeoForge 直装 processors 阶段）已在当前进程
    // 创建过 JVM。进程内 JVM 只能创建一次，再次 JLI_Launch 必然崩溃。
    // Task173：死路弹窗升级为一键出路——「重启并启动」写 internal.autolaunch_profile
    // 后 exit(0)，下次冷启 RightPanel 检测该键自动启动（用户实测"Forge 申请
    // JIT 安装完成后启动游戏弹 java runtime 弹窗，重启刷新 JIT 状态就好"，
    // 旧弹窗把整个重启+导航+重启动的手动流程丢给用户）。
    if (gJvmUsedInProcess) {
        UIKit_returnToSplitView();
        NSString *ame173_profile = PLProfiles.current.selectedProfileName ?: @"";
        NSLog(@"[JavaLauncher] Task173: in-process JVM already used by the mod installer -- offering restart-and-launch for '%@'", ame173_profile);
        ame173_showJvmUsedRestartDialog(ame173_profile);
        return 1;
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    // Task67：MC 读取 options.txt 之前净化移动键位（含全量 dump 诊断）。
    // 必须在 JLI_Launch 之前——MC 的 Options.load 在 JVM 启动早期执行。
    // Task179：调用点后移到 gameDir 解析之后（约 +320 行，Task179 注释块）——
    // 旧位置只能读 POJAV_GAME_DIR 符号链接（基础实例），自定义实例的
    // 键位净化一直在错误的文件上空转。

    DeviceGetJITFlags(YES);
    BOOL requiresTXMWorkaround = DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM);
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    // On TXM devices the dyld Library Validation bypass itself needs the
    // debugger: redirectFunctionMirrored() calls JIT26PrepareRegionForPatching()
    // which executes `brk #0xf00d` — that breakpoint must be handled by the
    // JIT26 debugger script.  Force jit26AlwaysAttached BEFORE
    // JIT26SetDetachAfterFirstBr() so the debugger stays attached to service
    // both brk #0x69 (HotSpot) and brk #0xf00d (dyld hooks).  Without this,
    // the debugger detaches after the first brk #0x69 and the later
    // brk #0xf00d kills the process (SIGSEGV after "Platform.isMac").
    if (requiresTXMWorkaround && !jit26AlwaysAttached) {
        NSLog(@"[DyldLVBypass] TXM debug JIT mapping active — keeping debugger attached for dyld bypass");
        jit26AlwaysAttached = YES;
    }
    if (requiresTXMWorkaround) {
        // ★ Task304：主启动链 JIT 自动申请（SurfaceViewController 链此前零
        //   JIT 申请，见 ame304 函数头病历）——按 debug.jit_enabler 偏好
        //   （用户实测选 StikDebug）发起 stikjit:// 等深链并 120s 有界等待；
        //   超时/失败不 return，继续走下方区域创建看门狗的既有优雅失败。
        if (!ame304_requestAndAwaitJITIfNeeded(@"Launch")) {
            NSLog(@"[JIT] [JavaLauncher] Task304 JIT request/wait did not succeed -- proceeding to region watchdog (graceful failure path intact)");
        }
        static void *result;
        // Task91：SIGTRAP 安全网——brk 无应答（JIT26 调试器未就绪/脚本未挂载）
        // 时原裸函数直接 SIGTRAP 致死（用户实测"开启 JIT 后闪退"），改走优雅报错
        // ★ Task301：SIGTRAP 安全网只救得了"无异常端口"场景；死调试器残留
        // 端口下 brk 进 mach_msg 永久阻塞（用户实测"启动卡住"）——改走有界
        // 看门狗：超时自动跑内置 JIT 轨服务挂起的 brk，仍无果才优雅失败。
        if(!result) result = ame301_createRegionWithWatchdog();
        if (!result) {
            NSLog(@"[JIT26] JIT26CreateRegionLegacy returned NULL — JIT26 debugger not servicing brk; aborting launch gracefully");
            showDialog(localize(@"Error", nil), localize(@"i18n_str_jit26_not_ready", nil));
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        if ((uint32_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            // legacy script 只允许调用一次 breakpoint，必须切换到 UniversalJIT26
            NSString *inBundleScriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
            NSString *lcAppInfoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSMutableDictionary *lcAppInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            if(lcAppInfo) {
                // LiveContainer 内：自动分配 script 并提示用户重启
                lcAppInfo[@"jitLaunchScriptJs"] = [[NSData dataWithContentsOfFile:inBundleScriptPath] base64EncodedStringWithOptions:0];
                if([lcAppInfo writeToFile:lcAppInfoPath atomically:YES]) {
                    showDialog(localize(@"Error", nil), localize(@"ame267.jit.legacy_lc", @"Prisma was launched with a legacy JIT script. It has been updated to the Universal script automatically, please restart LiveContainer to continue."));
                    [PLLogOutputView handleExitCode:1];
                    return 1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), localize(@"ame267.jit.legacy_stik", @"Support for legacy JIT scripts has been removed, please switch to the Universal JIT script. Current StikDebug builds auto-assign the script by app name (older sideloaded builds bundled the same script as Amethyst-MeloNX.js), so updating StikDebug is the easiest fix. To assign manually: long-press on the launcher app when enabling JIT in StikDebug, tap \"Assign Script\", then pick UniversalJIT26.js from the launcher's Documents directory (exported automatically at every startup)."));
            [PLLogOutputView handleExitCode:1];
            return 1;
        }
        JIT26SendJITScript([NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"]]);
        JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        // make sure we don't get stuck in EXC_BAD_ACCESS
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }

    if (jit26AlwaysAttached) {
        // Only allow StikDebug to catch our breakpoints to prevent any stutters
        task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_BREAKPOINT, 0,
            EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    }
    // Always activate Library Validation bypass for external runtime and dylibs (JNA, etc).
    // Previously this was skipped when requiresTXMWorkaround was true, which caused
    // JNA and other unsigned dylibs to fail with code signature errors.
    // The TXM hardware breakpoint mechanism (brk #0x69) does not conflict with dlopen hooks.
    init_bypassDyldLibValidation();

    // 加载 MobileGlues 配置（仅当用户手动选择 MobileGlues 渲染器时生效）
    init_loadMobileGluesConfig();

    // --- [更新] TouchController 通信方式支持 ---
    // 检查是否启用了 TouchController 以及选择的通信方式
    if (getPrefBool(@"control.mod_touch_enable")) {
        NSInteger mode = [getPrefObject(@"control.mod_touch_mode") integerValue];
        if (mode == 1) { // UDP 模式
            setenv("TOUCH_CONTROLLER_PROXY", "12450", 1);
            NSLog(@"[JavaLauncher] Enabled TouchController with UDP mode");
        } else if (mode == 2) { // 静态库模式
            // 设置 Unix Domain Socket 路径
            setenv("TOUCH_CONTROLLER_PROXY_SOCKET", "/tmp/touchcontroller.sock", 1);
            // Task 135：追加 legacy UDP 环境变量作为自动回落。mod 0.3.1-alpha14
            // 的 iOS 静态分支是上游重写传输层时留下的半成品：loadPlatform 里
            // `if (isIos) { IosPlatform().also { resize } }` 创建实例后【没有
            // return】（alpha13 是 `return { IosPlatform(socketPath) }` 完整形
            // 态），随后 probeNativeLibraryInfo 按 os.name（本启动器伪装为
            // "Mac OS X"）落入 Cocoa/Unknown 分支返回 null —— 静态模式在当前
            // mod 版本下必然 "No platform loaded"，进世界后弹"不支持的操作系统
            // iOS"警告（displayName 经 /var/mobile 探测判为 iOS，与 os.name
            // 无关）。mod 的 loadPlatform 检查顺序：TOUCH_CONTROLLER_PROXY（
            // legacy UDP，最优先）→ iOS 静态分支 → 按窗口类型探测。因此双环境
            // 变量并存时 alpha14 自动走 ProxyPlatform（UDP 单向通道：启动器→
            // mod 触点事件，协议已逐字节核对——AddPointer type=1 共 16 字节 /
            // RemovePointer type=2 共 8 字节，大端，与 SurfaceViewController
            // 的 TouchSender 完全匹配）。未来 mod 修复静态分支并调整检查顺序
            // 后可移除该回落。
            setenv("TOUCH_CONTROLLER_PROXY", "12450", 1);
            NSLog(@"[JavaLauncher] Enabled TouchController with Static Library mode "
                  @"(+ UDP fallback: mod 0.3.1-alpha14 iOS static branch is upstream "
                  @"WIP, legacy UDP is the only working path)");
        }
    }
    // ------------------------------------------

    // Task 138：26.1.2 controlify 3.0.1+26.1 JNA 直连 SIGBUS 根治。
    //
    // 崩溃链（本轮四日志判读 + JNA 5.13 dispatch.c 反编译实锤）：
    //   controlify 3.0.1+26.1 捆绑 libsdl4j 3.2.18（JNA 版 SDL3 绑定），
    //   加载链 = SDLNativesLoader.tryLoad → loadLibSDL3FromFilePathNow →
    //   NativeLibrary.getInstance("SDL3") → startSDL3 → SdlHints.SDL_SetHint
    //   首次调用触发 SdlHints 类初始化 → Native.register（JNA direct mapping）→
    //   jnidispatch 的 registerMethod：ffi_closure_alloc +
    //   ffi_prep_closure_loc + RegisterNatives(闭包跳板)。
    //   aarch64 上 libffi 的可执行跳板就在闭包页内；iOS 普通进程拿不到
    //   匿名可执行内存，该页只读可写不可执行 → 首个 direct-mapped 调用
    //   跳入 RW 页 → SIGBUS 于页基址+0x10（libffi 页首空闲链表头占 0x10，
    //   两次独立崩溃 0x134ea0010 与 0x119a70010 的 +0x10 形态完全吻合）。
    //   Task131/132/133/135 的符号重绑与 SDL3 二进制守卫在装机日志中全部
    //   如实生效（idempotent hit 与 verified 锚点齐全），但崩溃点位于 JNA
    //   自身的 ffi 闭包基础设施、先于任何 SDL 函数解析——守卫覆盖不到。
    //
    // 修复：设置 POJAV_NATIVEDIR。controlify 的 CUtil.IS_POJAV_LAUNCHER
    // 判定 = 该环境变量非空；检测到 Pojav 系启动器后 SDLNativesLoader 改从
    // POJAV_NATIVEDIR 下的 libSDL3.so 加载。该文件不存在时
    // NativeLibrary.getInstance 抛 UnsatisfiedLinkError，tryLoad 的
    // catch (UnsatisfiedLinkError) 兜住并记 "Failed to find SDL"，
    // initializeControlify 随即回落 GLFWControllerManager（GLFW 手柄路径，
    // 与本启动器 LWJGL 栈兼容）——游戏正常继续，不再 SIGBUS。
    //
    // 取值指向 POJAV_HOME（Documents 根，无任何 .so）：语义上符合 Pojav
    // 系约定，且绝不误中（本 app 的 SDL3 是 Frameworks 里的 libSDL3.dylib，
    // 非 .so 命名）。影响面核查：controlify 3.0.1+26.1 全 jar 仅
    // SDLNativesLoader 与 CUtil 两处读该变量；controlify 3.5.0 起（26.2
    // 会话在用）SDLNativesLoader 已改为 FFM 四级加载链（controlify_natives
    // → LWJGL → nativesInJar → loadFromSystem），不读该变量、不受影响；
    // 本启动器 ObjC 与 Java 两侧均无该变量的既有读写点。
    // 用户侧指引：26.1.2 想要完整 SDL 手柄支持，把 controlify 升级到
    // 3.5.0+mc26.1 或更新（FFM 路径，与本启动器完全兼容，26.2 会话实证）。
    {
        const char *pojavNativeDir138 = getenv("POJAV_HOME");
        if (pojavNativeDir138 && *pojavNativeDir138) {
            setenv("POJAV_NATIVEDIR", pojavNativeDir138, 1);
            NSLog(@"[JavaLauncher] Task138: POJAV_NATIVEDIR=%s (controlify JNA direct-mapping guard: "
                  @"libsdl4j ffi closure thunks are non-executable on iOS, steer Pojav-aware mods "
                  @"to graceful GLFW fallback)", pojavNativeDir138);
        }
    }

    BOOL launchJar = NO;
    NSString *gameDir;
    NSString *defaultJRETag;
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        // Task 158（Fix B）：启动前游戏库完整性自愈闸门——见上方
        // ame158_repairMissingLibraries 病历（Forge text2speech CNFE 根修 +
        // 未来任何缺库的静默黑洞自愈）。非阻断：失败只记日志点名。
        ame158_repairMissingLibraries(launchTarget);

        // Get preferred Java version from current profile
        // 26.x 官方强制要求 Java 25（Mojang 自 26.x 起将 javaVersion.majorVersion 设为 25），
        // 不再对 preferredJavaVersion 做任何钳制，直接采纳 Profile 指定的 Java 版本。
        // caciocavallo 三路切换会根据实际 Java 版本选择对应 jar（三个独立文件夹）：
        // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT）
        // - Java 17/21 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译）
        // - Java 25    → libs_caciocavallo25（1.18-SNAPSHOT 含 Java 24 class，catsruledogs iOS）
        int preferredJavaVersion = [PLProfiles resolveKeyForCurrentProfile:@"javaVersion"].intValue;
        if (preferredJavaVersion > 0) {
            if (minVersion > preferredJavaVersion) {
                NSLog(@"[JavaLauncher] Profile's preferred Java version (%d) does not meet the minimum version (%d), dropping request", preferredJavaVersion, minVersion);
            } else {
                NSDebugLog(@"[PLProfiles] Applying javaVersion (%d)", preferredJavaVersion);
                minVersion = preferredJavaVersion;
            }
        }
        if (minVersion <= 8) {
            defaultJRETag = @"1_16_5_older";
        } else if (minVersion >= 25) {
            // Task159：26.x 官方强制 Java 25（javaVersion.majorVersion=25），
            // 新增独立预选槽位，避免 26.x 误选 1_17_newer 槽的 Java 17 启动即崩
            defaultJRETag = @"1_26_newer";
        } else {
            defaultJRETag = @"1_17_newer";
        }

        // Setup AMETHYST_RENDERER
        NSString *profileRenderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        // Task 113 -> Task 120 -> Task 131（形态变迁，详注见 LauncherPreferences.m）：
        // MobileGL 家族（Vulkan / GLES / Mithril 三后端）的设置入口现为渲染器
        // 悬浮菜单里的三个条目（上游形态，Task131 恢复）；Task120 的独立
        // mobilegl_backend 设置行已退役，但其 legacy 解析（renderer=auto +
        // mobilegl_backend=1/2/3）保留在 ame_effective_renderer——存量设备
        // 行为不变，直到用户显式改选。【显式渲染器选择永远优先】（Task124：
        // layerClass 与实际渲染器必须同源，否则 MobileGL 内部 MoltenVK 向普通
        // CALayer 发送 naturalDrawableSizeMVK -> unrecognized selector 崩溃）。
        // 解析逻辑与 LauncherPreferences.m 的 ame_effective_renderer() 逐字一致
        // （单一事实源；此处内联展开仅为保留原日志点）。
        NSString *renderer = ame_effective_renderer();
        // ★ Task256（清单 5：自动选择器 1.8.9 崩溃根修）：55456d9 装机
        //   latestlog.txt 实锤——1.8.9-forge 会话 profile renderer=(null)，
        //   ame_effective_renderer 的 auto 分支按 legacy 档位键
        //   mobileglues.mobilegl_backend（版本无关！）返回 libMobileGL.dylib
        //   （日志 "[Prisma] Task120: MobileGL backend override active
        //   (profile renderer was (null) -> libMobileGL.dylib)"）→ 非常量
        //   "auto" → 下方 ame217 版本感知候选链（Task255 已头插 kw）根本
        //   不跑 → MobileGL Vulkan 后端的 glslang 不认 GL1.x 兼容内建
        //   ftransform → "Vertex shader compile error: 'ftransform' : no
        //   matching overloaded function found" → 1.8.9 启动即崩。
        //   修法：MC ≤1.16（minVersion<=8 谱系，与 defaultJRETag 分界同源）
        //   且 profile 未【显式】选择渲染器（nil/空/auto）时，家族覆盖
        //   一律让位 auto → 下方决策链按版本选 kw(NG-GL4ES)→gl4es(ZL2)
        //   →ANGLE→MobileGL。显式选择（profile 键是具体渲染器名）永远
        //   优先，老用户手动选的 MobileGL 玩 1.8.9 也不被绑架。
        if (minVersion <= 8) {
            BOOL ame256_profileExplicit = [profileRenderer isKindOfClass:NSString.class] &&
                profileRenderer.length > 0 &&
                ![profileRenderer isEqualToString:@"auto"];
            if (!ame256_profileExplicit && ![renderer isEqualToString:@"auto"]) {
                NSLog(@"[Prisma] Task256: legacy MC (<=1.16) with non-explicit profile renderer "
                      @"(profile=%@, resolved=%@) -- restoring 'auto' so the version-aware "
                      @"kw-first decide chain runs (MobileGL glslang lacks ftransform on legacy GLSL)",
                      profileRenderer, renderer);
                renderer = @"auto";
            }
        }
        if (![renderer isEqualToString:profileRenderer]) {
            NSLog(@"[Prisma] Task120: MobileGL backend override active (profile renderer was %@ -> %@)",
                  profileRenderer, renderer);
            // ★ Task233（反馈 #3 纠偏，Task232 steer 退役）：Task232 曾把
            //   "家族覆盖解析出 MobileGL 且 MC >= 26" 强制改道 tinygl4angle
            //   （依据 4bdd916 单次会话的 ENTER_WORLD 冻结）。用户实测纠错：
            //   MobileGL 同存档【第二次进入正常】，冻结是概率性问题，且用户
            //   日常就是用 MGL——静默换渲染器等于夺走用户的选择。steer 移除，
            //   渲染器永远尊重解析结果；概率性冻结改由渲染停滞看门狗
            //   （SurfaceViewController Task233，25s 零换帧一次性提示
            //   "退出重进可恢复"）承接，取证留给下一轮设备日志。
        }
        // Metal 渲染器（libmetallum.dylib，Task201 随上游同步移植）：图形后端由
        // metallum agent 走原生 Metal（直接 MTLDevice），不经过 EGL 渲染器。
        // 渲染器回落 auto（→ANGLE）仅为 Surface 提供 GL 上下文，与 metallum
        // 官方集成一致（渲染器只管 GL/Vulkan 回退）。★ 必须置 AMETHYST_METAL=1：
        // agent 只认这个开关来打开渲染 patch（MetallumAgent.IS_METAL_RENDERER），
        // 否则整段渲染 patch 关闭 —— 日志 "non-Metal renderer: ... render patches
        // disabled"，26.2 起不来。
        if ([renderer isEqualToString:@ RENDERER_NAME_METAL]) {
            setenv("AMETHYST_METAL", "1", 1);
            NSLog(@"[JavaLauncher] Metal renderer selected: AMETHYST_METAL=1 (EGL renderer falls back to auto for surface)");
            renderer = @"auto";
        }
        NSLog(@"[JavaLauncher] RENDERER is set to %@\n", renderer);
        setenv("AMETHYST_RENDERER", renderer.UTF8String, 1);
        // Task 147：彻底不再导出 POJAV_RENDERER（含 Mithril）。Task 145 的
        // "Mithril 需要重绑门"前提被 Run #356 实测推翻：make-current #1/#2 的
        // Task140 读回 + Task146 三指针探针证明绑定健康（renderer 侧
        // glGetString 返回 "3.3.0 Mithril-Wrapper (Vulkan 1.2 / MoltenVK)"），
        // 而 POJAV_RENDERER 在场时 createCapabilities 反而崩——补丁门在
        // make-current #2 之后触发 fixPojavGLContext 重绑，日志无 make-current
        // #3、且桥的 make_current(NULL) 释放分支当时不留痕：重绑以隐式释放/
        // 异路线重绑收场，上下文在 createCapabilities 读取前丢失 ->
        // "no OpenGL context"（latestlog.txt 07:25:25 实锤）。绑定健康时
        // 门没有任何正向价值；unsetenv 兜底同时清掉同 app 会话内上一次
        // 残留，Sodium 反 Pojav 检测（env 存在即抛）继续安全。
        unsetenv("POJAV_RENDERER");

        // Task 215：VirGLRenderer(≤26.2)（ZL2 移植）：
        // GALLIUM_DRIVER/VTEST_SOCKET_NAME 在 egl_bridge 的 ame_virgl_start_server()
        // 里统一设置（osm_bridge dlopen guest 之前生效即可）；此处仅日志标记，
        // 并防止下方 zink 的 libOSMesa 前缀分支误伤 virgl。
        if ([renderer isEqualToString:@ RENDERER_NAME_VIRGL]) {
            NSLog(@"[JavaLauncher] VirGL renderer active: GALLIUM_DRIVER=virgl + in-process vtest server (Task 215)");
        }
        // Apply Zink-specific environment variables if Zink renderer is selected
        // Mesa 25.0.7 zink 升级配套：根据设备 GPU 代际自动调优 MESA_GL_VERSION_OVERRIDE、
        // MESA_GLSL_VERSION_OVERRIDE、MESA_EXTENSION_OVERRIDE、mesa_glthread、shader cache 等。
        // ZinkConfig 默认 Auto 级别会保留所有光影所需的 GL 扩展（compute/tessellation/geometry
        // shader 等），仅禁用 MoltenVK 支持不佳的 Transform Feedback，不影响 Iris/OptiFine。
        // Task 215：libOSMesaVirgl.dylib（virgl guest）同样命中 libOSMesa 前缀——排除。
        if ([renderer hasPrefix:@"libOSMesa"] && ![renderer isEqualToString:@ RENDERER_NAME_VIRGL]) {
            // ★ Task283（GitHub 议题 #15）：MC 版本感知 GL 下限——26.x 光照
            //   引擎需要 GL 4.4+/SSBO，旧默认 4.1 封顶 = 能进世界但光照异常
            //   全黑（A12/Zink+MoltenVK 装机日志实锤 "4.1 (Compatibility
            //   Profile)"）。MC major 由 launchTarget 版本 id 提取（ame98
            //   同源提取器），传给 ZinkConfig 做 4.5 自动抬升（显式钉
            //   zink.gl_override 永远优先）。1.x 谱系行为零变化。
            NSString *ame283_verId = nil;
            if ([launchTarget isKindOfClass:NSDictionary.class]) {
                ame283_verId = [launchTarget[@"id"] description];
            } else if ([launchTarget isKindOfClass:NSString.class]) {
                ame283_verId = (NSString *)launchTarget;
            }
            [ZinkConfig applyZinkEnvironmentFromPreferencesWithMCMajor:ame98_mcMajorFromVersionId(ame283_verId)];
            NSString *configSummary = [ZinkConfig activeConfigSummary];
            NSLog(@"[ZinkConfig] ========== Zink Renderer Active (Mesa 25) ==========");
            NSLog(@"[ZinkConfig] %@", configSummary);
            setenv("ZINK_ACTIVE_CONFIG", configSummary.UTF8String, 1);

            // 安装 zink vertex stride 4 字节对齐 fix
            // 修复 Mesa 25.0.7 zink + MoltenVK 在启用光影时因 stride 未 4 字节对齐
            // 导致 vkCreateGraphicsPipelines 失败 → SIGSEGV 的崩溃（详见 main_hook.m）
            // 必须在 libOSMesa 被 dlopen 之前调用，确保 fishhook 能拦截后续符号引用
            installZinkStrideFix();
        }

        // Apply LTW-specific environment variables if LTW renderer is selected
        // LTW (Large Thin Wrapper) OpenGL Core 3.3 → ES 3 转译层
        // 不设置 LTW_* 环境变量，使用 LTW main.c constructor 的默认值（与 Android 端一致）
        //   - LIBGL_ES：LTW 自动检测 ES 版本
        //   - LTW_NEVER_FLUSH_BUFFERS：默认 true
        //   - LTW_COHERENT_DYNAMIC_STORAGE：默认 true
        // 仅设置 POJAVEXEC_EGL 标识 EGL 由 LTW 提供（对齐 Android 端语义）
        if ([renderer isEqualToString:@ RENDERER_NAME_LTW]) {
            setenv("POJAVEXEC_EGL", RENDERER_NAME_LTW, 1);
            NSLog(@"[JavaLauncher] LTW renderer active: using LTW defaults (same as Android)");
        }

        // Task206：NG-GL4ES（"Krypton Wrapper"，ZL2 的 gl4es）。NGG_DIR_PATH
        // 指向 POJAV_HOME 下的 ngg/（上游默认 /sdcard/NGG 在 iOS 必然 fopen
        // 失败——config_refresh 对缺失文件静默返回，无 config.json 时行为与
        // 默认完全一致；指到可写目录只是让高级用户可以放 config.json 调参）。
        // 其余零环境需求：EGL 由宿主 gl_bridge 提供，dylib 由 LWJGL 作为
        // opengl.libname 在游戏上下文 current 后加载（vgpu 同款流）。
        if ([renderer isEqualToString:@ RENDERER_NAME_NGGL4ES]) {
            const char *ame206_home = getenv("POJAV_HOME");
            if (ame206_home && *ame206_home) {
                char ame206_path[1024];
                snprintf(ame206_path, sizeof(ame206_path), "%s/ngg", ame206_home);
                setenv("NGG_DIR_PATH", ame206_path, 1);
            }
            NSLog(@"[JavaLauncher] Task206: NG-GL4ES renderer active (NGG_DIR_PATH=%s)",
                  getenv("NGG_DIR_PATH") ?: "<unset>");
            // ★ Task280（kw"锁30"缓解杠杆——可选小 draw 批量转译）：Task279 装
            //   机归因 BUILD-bound（NG-GL4ES 逐 draw CPU 转译税；1/4 分辨率仍
            //   30fps 已排除像素瓶颈）。LIBGL_BATCH=30 = gl4es 官方合并杠杆
            //   （相邻 glDraw* 首个 ≤3000 顶点即入批，GL state 变化/超限断批
            //   ——ZL2 USAGE.md §LIBGL_BATCH）——MC1.8.x 实体/粒子级小 draw
            //   密集场景的标准减税路径。默认关：Task279 的 BUILD-bound 归因
            //   未排除 MC 内部 maxFps 上限（build 相位含游戏侧 fps limiter 睡
            //   眠，两边在 pres/build 计量里同貌），归因终审看 Task280 fps-cap
            //   posture 行；确认 BUILD-bound 的机器打开本偏好验证帧率抬升后
            //   再评估转默认。plist-only（ame259_quic_guard 同款，无 UI 行）。
            if (getPrefBool(@"debug.ame280_kw_batch")) {
                setenv("LIBGL_BATCH", "30", 1);
                NSLog(@"[JavaLauncher] Task280: LIBGL_BATCH=30 (debug.ame280_kw_batch=ON) -- NG-GL4ES small-draw batching engaged");
            }
        }

        // Apply MobileGL-specific environment variables
        // MobileGL（MobileGL-Dev，LGPL-3.0）两个变体共用同一个 libMobileGL.dylib 二进制，
        // 靠 MOBILEGL_BACKEND_TYPE 在运行时选择后端：
        //   libMobileGL.dylib      -> DirectVulkan (GL -> Vulkan -> MoltenVK -> Metal)
        //   libMobileGL-gles.dylib -> DirectGLES   (GL -> OpenGL ES)
        // 必须在 JVM 启动前设置：MobileGL 的 constructor 在 dlopen 时就读取该变量。
        // Task 120：GLES 档位（mobilegl_backend=2）与 libMobileGL-gles.dylib 文件名
        // 两种形态都解析为 DirectGLES——设置页的 GLES 档复用同一个 Vulkan 二进制，
        // 只切后端环境变量，不要求 -gles 变体 dylib 随包。
        //
        // MOBILEGL_LOG_FILE_PATH 指向 POJAV_HOME 下的 mobilegl.log，便于导出诊断。
        // 日志量较大，仅在选中 MobileGL 时开启。
        if (isMobileGLRenderer(renderer.UTF8String)) {
            const char *backend = [renderer isEqualToString:@ RENDERER_NAME_MOBILEGL_GLES]
                ? "DirectGLES"
                : ((getPrefInt(@"mobileglues.mobilegl_backend") == 2) ? "DirectGLES" : "DirectVulkan");
            setenv("MOBILEGL_BACKEND_TYPE", backend, 1);
            const char *pojavHome = getenv("POJAV_HOME");
            if (pojavHome && *pojavHome) {
                NSString *logPath = [NSString stringWithFormat:@"%s/mobilegl.log", pojavHome];
                setenv("MOBILEGL_LOG_FILE_PATH", logPath.UTF8String, 1);
            }
            // Task156：ES（DirectGLES）后端的 multidraw 换保守档。
            // 病历：ES 档自 Task131 上架以来方块一直不渲染/透明（天空/实体/UI 正常、
            // swap 链健康、零 GL 报错）——Task140/153/154 修完启动器侧全部嫌疑后
            // 仍复现，定案为 MobileGL 26.08-dev Espryt(ANGLE) 翻译层的 native/ext
            // multidraw 路径静默丢绘制（地形批绘制走 glMultiDraw* 家族，恰好只剩
            // 方块消失）。二进制 strings 实锤其运行时开关：
            // MOBILEGL_ESPRYT_MULTIDRAW_MODE（值域 ext|multiindirect|indirect|
            // basevertex|drawelements|compute|auto）——强制 drawelements（逐子绘制
            // glDrawElements 循环，最保守）避开坏档。Vulkan(Magma) 后端有独立的
            // MOBILEGL_MAGMA_MULTIDRAW_MODE 且装机验证正常，不触碰。
            // 已有值不覆盖（设备上可用环境变量自由实验其他档位）。
            if (strcmp(backend, "DirectGLES") == 0 && getenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE") == NULL) {
                setenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE", "drawelements", 1);
                NSLog(@"[JavaLauncher] Task156: Espryt multidraw tier forced to 'drawelements' (ES blocks-invisible workaround)");
            }
            NSLog(@"[JavaLauncher] MobileGL renderer active: backend=%s", backend);
        } else {
            // 切换渲染器后清掉，避免残留影响后续启动
            unsetenv("MOBILEGL_BACKEND_TYPE");
            unsetenv("MOBILEGL_LOG_FILE_PATH");
            unsetenv("MOBILEGL_ESPRYT_MULTIDRAW_MODE");
        }

        // Mithril 渲染器（libmithril.dylib）自带 EGL + GL 3.3 Core（Vulkan backend），
        // 不需要额外的环境变量：EGL 符号由 gl_bridge.m 的 dlsym_EGL() 从自身 dylib 解析，
        // GL 上下文由 gl_init_context 用 EGL_OPENGL_BIT + EGL_OPENGL_API 创建。
        // SDL3 在本项目走 uikit video driver（窗口由 UIKit/Metal 提供），
        // 不涉及 SDL 的 EGL 库选择，因此无需设置 SDL 侧 EGL 路径。
        if (isMithrilRenderer(renderer.UTF8String)) {
            NSLog(@"[JavaLauncher] Mithril renderer active: EGL/GL from libmithril.dylib (Vulkan backend)");
        }
        // Setup AMETHYST_GRAPHICS_API（MC 26.2+ Graphics API：default/vulkan/opengl）
        // 仅 MC 26.2+ 识别此选项，旧版本 MC 会忽略 options.txt 中的 graphicsApi 字段。
        //
        // 关键修复（更改图形 API 无效）：
        //   之前仅当 graphicsApi 非空时才设置环境变量，导致：
        //   1. 用户从未设置过 graphicsApi 时环境变量缺失，Java 端无法清除旧值
        //   2. 环境变量缺失时 Java 端完全跳过 graphicsApi 处理逻辑
        //   现在始终设置环境变量（缺省为 "default"），让 Java 端每次启动都能正确处理：
        //   - "default"：清除 options.txt 中的 graphicsApi 行
        //   - prefer_vulkan/prefer_opengl：写入对应值
        NSString *graphicsApi = [PLProfiles resolveKeyForCurrentProfile:@"graphicsApi"];
        if (!graphicsApi || graphicsApi.length == 0) {
            graphicsApi = @"default";
        }
        setenv("AMETHYST_GRAPHICS_API", graphicsApi.UTF8String, 1);
        NSLog(@"[JavaLauncher] GRAPHICS_API is set to %@\n", graphicsApi);

        // Setup gameDir
        // ★ Task275 F5：绝对路径自定义隔离目录原样使用——原实现无条件嵌套拼接
        //   instances/<gd>/<绝对路径>，stringByStandardizingPath 收拢双斜杠后变为
        //   instances/<gd>/var/...：启动 chdir 落进嵌套孤儿树，与服务层五处 resolve
        //   （isAbsolutePath 原样返回）分叉成两套口径（管理页/下载落点在真实目录）。
        {
            NSString *ame275_gd = [PLProfiles resolveKeyForCurrentProfile:@"gameDir"];
            if ([ame275_gd isAbsolutePath]) {
                gameDir = ame275_gd;
            } else {
                gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
                    getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"), ame275_gd]
                    .stringByStandardizingPath;
            }
        }

        // ★ Task225（反馈 #5：与 ModService 同源的隔离嗅探）：profile 的
        // gameDir 为 "."/缺失时，若 versions/<vid>/game（或旧口径
        // versions/<vid>/）下已有 mods/saves 用户数据，启动目录自动解析为
        // 该隔离目录——与上游 PCL VER-ISOLATE 的 auto 语义及 ModService/
        // ModsManager 的解析完全一致（三处同规则，杜绝"游戏跑共享目录而
        // mod 装到隔离目录"的错位）。显式 gameDir（自定义路径）永远优先。
        {
            NSString *ame225_profGameDir = [PLProfiles resolveKeyForCurrentProfile:@"gameDir"];
            BOOL ame225_isShared = ![ame225_profGameDir isKindOfClass:[NSString class]] ||
                ame225_profGameDir.length == 0 || [ame225_profGameDir isEqualToString:@"."];
            if (ame225_isShared) {
                NSDictionary *ame225_prof = [PLProfiles.current.profiles objectForKey:PLProfiles.current.selectedProfileName];
                NSString *ame225_sniffed = [ModService ame225_sniffedIsolationGameDirForProfile:ame225_prof];
                if (ame225_sniffed.length > 0) {
                    gameDir = ame225_sniffed;
                    NSLog(@"[JavaLauncher] Task225 auto-sniffed isolation gameDir -> %@ (mods/saves present; ModService 同源嗅探)", gameDir);
                }
            }
        }

        // ★ Task287（PocketJ 对标移植）：Forge URI-safe 游戏根——先于全部
        //   mods 目录扫描与 chdir（Task97 CwdAlign 消费本 gameDir），命中
        //   时同步重指 POJAV_GAME_DIR（headless/JVM 侧消费者同口径）。
        {
            NSString *ame287_vid = [launchTarget isKindOfClass:[NSDictionary class]]
                ? launchTarget[@"id"] : @"";
            gameDir = ame287_configureForgeUriSafeRoot(ame287_vid, gameDir);
        }

        // Task 87：桌面弹窗类 mod 预检（病历见 ame87_disableDesktopDialogMods 函数头）
        // ——实证案犯自动禁用（改名 .jar.disabled），Fabric 忽略非 .jar 文件。
        int ame87_disabledDialogMods = ame87_disableDesktopDialogMods(gameDir);
        if (ame87_disabledDialogMods > 0) {
            NSLog(@"[ModDialogGuard] Task87: %d desktop dialog mod(s) auto-disabled in %@/mods (rename .disabled -> .jar to restore)", ame87_disabledDialogMods, gameDir.lastPathComponent);
        }

        // ★ Task287：IMBlocker/InputMethodBlocker 自动禁用（Java 17+ 会话门，
        //   PocketJ 同款；8 会话存量路径不触碰）
        if (minVersion >= 17) {
            int ame287_disabledInputMods = ame287_disableUnsupportedInputMods(gameDir);
            if (ame287_disabledInputMods > 0) {
                NSLog(@"[ModCompat] Task287: %d input-method mod(s) auto-disabled in %@/mods (rename .disabled -> .jar to restore)",
                      ame287_disabledInputMods, gameDir.lastPathComponent);
            }
        }

        // Task225（#2）：资源完整性预检 + 自动补齐（assets 缺个体文件 = MC
        // 1.20.1 启动期 NoSuchFileException 自杀的根因；详见函数头病历）。
        {
            NSString *ame225_vid = [launchTarget isKindOfClass:[NSDictionary class]]
                ? launchTarget[@"id"] : nil;
            if (ame225_vid.length > 0) {
                ame225_healMissingAssets(ame225_vid);
            }
        }

        // Task 95：整合包完整性提醒（病历见 ame95_warnIncompleteImport 函数头）
        // ——读实例根目录的 import_report.json，有未确认缺失时一次性提醒，不阻断启动。
        ame95_warnIncompleteImport(gameDir);

        // ★ Task244（Vulkan+光影"启动直接崩溃"取证面包屑）：Vulkan 路径
        //   （MoltenVK 直连渲染器或 graphicsApi=prefer_vulkan）下扫描 mods
        //   目录的 VulkanMod 与 Iris/Oculus 共存——Iris/Oculus 是 GL 渲染管
        //   线注入器，与整体替换渲染器的 VulkanMod 已知不兼容，同装时光影
        //   阶段崩溃是确定性结果（非启动器侧可修，用户应二选一）。非该组
        //   合的崩溃留给 hs_err 诊断弹窗（Task218 机制）+ 本面包屑分诊。
        {
            BOOL ame244_vkPath = [renderer isEqualToString:@(RENDERER_NAME_VULKAN)] ||
                [graphicsApi isEqualToString:@"prefer_vulkan"];
            if (ame244_vkPath) {
                NSString *ame244_modsDir = [gameDir stringByAppendingPathComponent:@"mods"];
                NSArray<NSString *> *ame244_entries = [[NSFileManager defaultManager]
                    contentsOfDirectoryAtPath:ame244_modsDir error:NULL];
                BOOL ame244_hasVulkanMod = NO;
                BOOL ame244_hasIrisLike = NO;
                for (NSString *ame244_name in ame244_entries) {
                    NSString *ame244_low = ame244_name.lowercaseString;
                    if (![ame244_low hasSuffix:@".jar"] &&
                        ![ame244_low hasSuffix:@".jar.disabled"]) continue;
                    if ([ame244_low containsString:@"vulkanmod"]) ame244_hasVulkanMod = YES;
                    if ([ame244_low containsString:@"iris"] ||
                        [ame244_low containsString:@"oculus"]) ame244_hasIrisLike = YES;
                }
                BOOL ame244_shaderpackDir = [[NSFileManager defaultManager]
                    fileExistsAtPath:[gameDir stringByAppendingPathComponent:@"shaderpacks"]];
                if (ame244_hasVulkanMod && ame244_hasIrisLike) {
                    NSLog(@"[Task244] Vulkan forensics: VulkanMod + Iris/Oculus BOTH present under %@/mods — known-incompatible combo, shader-stage crash is deterministic; remove one of them",
                          gameDir.lastPathComponent);
                } else {
                    NSLog(@"[Task244] Vulkan forensics: vulkanmod=%d, iris/oculus=%d, shaderpacks-dir=%d (renderer=%@, graphicsApi=%@) — if crash persists, share the hs_err diagnosis dialog content",
                          ame244_hasVulkanMod, ame244_hasIrisLike, ame244_shaderpackDir,
                          renderer, graphicsApi);
                }
            }
        }

        // Task 140：TouchController mod 侧配置一次性修复（Task134-139 污染的
        // 空布局指针恢复/移除；mod 在 JVM 启动早期读取 config/touchcontroller/，
        // 此处调用当次生效。启动器不再向 mod 写入任何配置）
        ame140_remediateTouchControllerConfig(gameDir);

        // Task179：键位净化移到这里（gameDir 已解析）——经环境变量把实际
        // 实例目录递给净化器，自定义实例的 options.txt 终于能被修到。
        // 仍在 JLI_Launch 前（MC 的 Options.load 在 JVM 启动早期执行）。
        setenv("AME67_INSTANCE_GAME_DIR", gameDir.UTF8String, 1);
        ame67_sanitizeOptionsKeybinds();
        // ★ Task261（右 Shift"又出问题了"根修——新实例默认键位家族）：
        // 活动布局含右SHIFT(344) 按钮而当前实例 options.txt 的 sneak 仍是
        // 原版默认（左 Shift）时，启动前改绑 right.shift（详见函数头病历）。
        // ★ Task286：新实例首启性能播种（仅 options.txt 缺席时写均衡档，
        //   已有实例零触碰；置于 ame261 之前——其 sneak 修复读该文件，
        //   播种档无 sneak 行时其"默认态"判定与文件缺席同语义）。
        ame286_seedFirstLaunchPerformanceOptions(gameDir);
        ame261_repairSneakBindingForRightShiftLayout(gameDir);

        // Task181：老 Forge（1.x）SplashProgress 线程禁用——splash 线程与主线程
        // 在共享 GL 上下文上互相踩踏是 1.8.9 会话 FBO status:0 崩溃的根因
        // （详见函数头病历）。仍在 JLI_Launch 前，Forge 早期配置读取之前。
        ame181_disableLegacyForgeSplash(gameDir,
            [launchTarget isKindOfClass:NSDictionary.class] ? launchTarget[@"id"] : nil);
    } else {
        defaultJRETag = @"execute_jar";
        gameDir = @(getenv("POJAV_GAME_DIR"));
        launchJar = YES;
        // execute_jar 路径（如 OptiFine 安装器）的 caciocavallo 由三路切换自动处理：
        // 实际选中的 Java 运行时是哪个版本，就用对应目录的 caciocavallo jar。
        // 不再在此处对 minVersion 做任何强制提升或钳制。
    }

    // 26.x 版本官方强制要求 Java 25（Mojang 自 26.x 起将 javaVersion.majorVersion 设为 25）。
    // 不再钳制 Profile 的 javaVersion，26.x 必须使用 Java 25 启动。
    // caciocavallo 三路切换（参照 FCL/ZalithLauncher2 二元思路，扩展为三路以兼容 Java 25）：
    // 三个独立的平级文件夹，按实际 Java 版本选择：
    // - Java 8     → libs_caciocavallo（1.10-SNAPSHOT，包名 net.java.openjdk.cacio，bootclasspath/p）
    // - Java 17/21 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    // - Java 25    → libs_caciocavallo25（1.18-SNAPSHOT 含 Java 24 class，包名 com.github.caciocavallosilano.cacio，bootclasspath/a）
    //   来自 catsruledogs/Amethyst-iOS-25。其 CTCGraphicsEnvironment 是 Java 24 class（class version 68），
    //   含 Java 25 兼容修复，纯 Java 17 编译版本会在 get_method_id 阶段 SIGSEGV。
    //   class version 68 仅 Java 24+ 可加载，故 Java 17/21 不能共用，需用 caciocavallo17 目录的纯 Java 17 jar。

    NSLog(@"[JavaLauncher] Looking for Java %d or later", minVersion);
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minVersion);

    if (javaHome == nil) {
        UIKit_returnToSplitView();
        BOOL isExecuteJar = [defaultJRETag isEqualToString:@"execute_jar"];
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            isExecuteJar ? [launchTarget lastPathComponent] : PLProfiles.current.selectedProfile[@"lastVersionId"], minVersion]);
        return 1;
    } else if ([javaHome hasPrefix:@(getenv("POJAV_HOME"))]) {
        // Symlink libawt_xawt.dylib
        NSString *dest = [NSString stringWithFormat:@"%@/lib/libawt_xawt.dylib", javaHome];
        NSString *source = [NSString stringWithFormat:@"%@/Frameworks/libawt_xawt.dylib", NSBundle.mainBundle.bundlePath];
        NSError *error;
        [fm createSymbolicLinkAtPath:dest withDestinationPath:source error:&error];
        if (error) {
            NSLog(@"[JavaLauncher] Symlink libawt_xawt.dylib failed: %@", error.localizedDescription);
        }
    }

    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] JAVA_HOME has been set to %@", javaHome);

    // Task141：启动内存由当前实例的内存分配决定（实例管理 > 高级设置 > 内存分配拉条）。
    // 旧全局链 java.auto_ram / java.allocated_memory 退役（设置页两行已删）。
    // 实例未设置时回退到原自动比例（0.5/0.25）。本计算与 SurfaceViewController
    // updateJetsamControl 必须一致 —— 两处现读同一共享助手 ame141_currentLaunchAllocMem
    // （Task68 教训：Jetsam 上限与 Xmx 错位 = 启动期 SIGKILL，从结构上消除漂移）。
    int allocmem = ame141_currentLaunchAllocMem();
    NSLog(@"[JavaLauncher] Max RAM allocation is set to %d MB", allocmem);
    // ★ Task286（PocketJ 对标移植）：经典/远古版本独立内存兼容轨——
    //   rd-*/c0.*/inf-*/indev-*/a1.*/b1.*（Classic/Indev/Infdev/Alpha/Beta）
    //   世代按现代大堆跑极易在 iOS 虚拟地址空间受限设备上直接启动失败
    //   （Java 8 默认连续预留 128MB 编译堆，远古版只需几 MB，预留过大
    //   在 iOS 上直接失败——上游 PocketJ legacy path 同款结论）。
    //   general.legacy_compatibility 默认 ON，设置页可关。堆帽 192MB
    //   （PocketJ compatibilityLimit 同值）。
    BOOL ame286_legacyVersion = NO;
    if (!launchJar && getPrefBool(@"general.legacy_compatibility")
        && [launchTarget isKindOfClass:NSDictionary.class]) {
        NSString *ame286_vid = [launchTarget[@"id"] isKindOfClass:NSString.class]
            ? [launchTarget[@"id"] lowercaseString] : @"";
        NSString *ame286_vtype = [launchTarget[@"type"] isKindOfClass:NSString.class]
            ? [launchTarget[@"type"] lowercaseString] : @"";
        ame286_legacyVersion =
            [ame286_vid hasPrefix:@"rd-"] || [ame286_vid hasPrefix:@"c0."]
            || [ame286_vid hasPrefix:@"inf-"] || [ame286_vid hasPrefix:@"indev-"] || [ame286_vid hasPrefix:@"in-"]
            || [ame286_vid hasPrefix:@"a1."] || [ame286_vid hasPrefix:@"b1."]
            || [ame286_vtype isEqualToString:@"old_alpha"] || [ame286_vtype isEqualToString:@"old_beta"];
        if (ame286_legacyVersion) {
            if (allocmem > 192) allocmem = 192;
            NSLog(@"[JavaLauncher] Task286: legacy version '%@' (type=%@) -- heap clamped to %d MB + slim CodeCache",
                  launchTarget[@"id"], launchTarget[@"type"], allocmem);
        }
    }
    if (!validateVirtualMemorySpace(allocmem)) {
        UIKit_returnToSplitView();
        if (getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit")) {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Lower memory allocation and try again.");
        } else {
            showDialog(localize(@"Error", nil), @"Insufficient contiguous virtual memory space. Increased Memory Limit entitlement is missing, please add it via GetMoreRam app.");
        }
        return 1;
    }

    int margc = -1;
    const char *margv[1000];

    // 关键修复（N3+N4）：margv 边界检查 + 字符串生命周期管理
    //
    // N3（边界检查）：
    //   margv[1000] 是固定大小数组，每次 margv[++margc] = ... 都没有检查 margc 是否越界。
    //   如果未来扩展参数可能造成栈缓冲区溢出。这里通过 PUSH_MARGV_* 宏做防御性边界检查。
    //
    // N4（悬垂指针）：
    //   [NSString stringWithFormat:...].UTF8String 返回的 C 字符串指针依赖 autoreleased NSString
    //   的生命周期。当前 launchJVM 函数没有显式 @autoreleasepool 包裹整个函数体，autoreleased
    //   对象进入当前线程的 autorelease pool，到下一次 runloop drain 时才释放。由于函数末尾立即
    //   调用 pJLI_Launch(margc, margv, ...)，期间没有显式 drain，所以暂时安全。
    //   但这是脆弱的隐式依赖：如果将来有人在中间插入 @autoreleasepool 块或调用 drain，
    //   所有 margv 中由 stringWithFormat: 生成的指针会立即悬垂，导致 JVM 启动崩溃。
    //
    //   修复方案：用 retainedStrings 数组强引用所有通过 stringWithFormat: 创建的 NSString，
    //   确保其生命周期覆盖 pJLI_Launch 调用。retainedStrings 是局部 strong 引用，随函数
    //   退出自动释放，无需手动管理。
    NSMutableArray<NSString *> *retainedStrings = [NSMutableArray array];

    // 宏：安全地添加一个字面量参数到 margv
    // 字符串字面量（如 "-XstartOnFirstThread"）是静态存储期的 const char*，永不失效
    // 边界检查：margc 达到上限时停止添加，避免栈溢出
    #define PUSH_MARGV_LITERAL(literal) do { \
        if (margc + 1 < 1000) { \
            margv[++margc] = (literal); \
        } else { \
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding literal argument %s", (literal)); \
        } \
    } while (0)

    // 宏：通过 stringWithFormat: 构造参数并添加到 margv
    // 创建的 NSString 会被 retainedStrings 强引用，直到函数返回才释放，
    // 保证 margv 中保存的 UTF8String 指针在 pJLI_Launch 调用期间有效。
    // 注意：NSLog 警告消息不直接用 fmt 作为格式串（避免 % 被错误解析），仅打印字面量提示。
    #define PUSH_MARGV_FORMAT(ns_fmt, ...) do { \
        if (margc + 1 < 1000) { \
            NSString *_tmpStr = [NSString stringWithFormat:(ns_fmt), ##__VA_ARGS__]; \
            [retainedStrings addObject:_tmpStr]; \
            margv[++margc] = _tmpStr.UTF8String; \
        } else { \
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding formatted argument"); \
        } \
    } while (0)

    PUSH_MARGV_FORMAT(@"%@/bin/java", javaHome);
    PUSH_MARGV_LITERAL("-XstartOnFirstThread");
    if (!launchJar) {
        PUSH_MARGV_LITERAL("-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader");
    }
    if (ame286_legacyVersion) {
        // ★ Task286：远古版 Xms 收小——启动即触发全堆 GC 扫描，大 Xms
        //   徒增启动停顿（PocketJ legacy path 同值 64M）。
        PUSH_MARGV_LITERAL("-Xms64M");
    } else {
        PUSH_MARGV_LITERAL("-Xms128M");
    }
    PUSH_MARGV_FORMAT(@"-Xmx%dM", allocmem);
    // ============================================================================
    // Task68: GC / safepoint 停顿观测（「加载区块卡顿」归因层）
    // ============================================================================
    // 目的：把 Java 侧停顿（GC 暂停、safepoint）与 [RenderDiag] fps/mem 行放进同一 latestlog
    // 时间轴；配合 MC 自身的 "Resizing Chunk Sections UBO" 行，下轮日志即可把游戏中掉帧归因到
    // GC 风暴 / 区块网格上传 / UBO 单帧重配 三者之一，不再靠推测。
    // 仅 Java 9+ 注入（minVersion > 8，与 defaultJRETag 的 1_16_5_older 分界同源）：
    // Java 8 无统一日志语法，误注入会导致 JVM 拒绝启动。
    // 输出量可控：gc 与 safepoint 两个 tag（每次 GC/safepoint 一行量级），非 gc* 全量。
    if (minVersion > 8) {
        PUSH_MARGV_LITERAL("-Xlog:gc,safepoint:stdout:time,uptime");
        NSLog(@"[JavaLauncher] Task68 GC/safepoint pause logging enabled (-Xlog:gc,safepoint -> stdout)");
    }
    // library.path: 单一 Frameworks 路径（对齐 Ynnyny 仓库）
    //
    // 关键修复（26.2 启动崩溃）：之前 workspace 将 LWJGL dylib 分裂为 lwjgl33/ 和 lwjgl34/ 子目录，
    // 并通过扫描版本 JSON 的 LWJGL 声明来选择路径。但 Ynnyny 仓库用单一 Frameworks 路径就能正常
    // 启动 26.2，证明分裂路径是多余的，且若 dylib 未按子目录正确摆放会导致加载错误版本 native 库。
    //
    // 现对齐 Ynnyny：所有 native dylib（含 LWJGL 专属和共享库）统一放在 Frameworks/ 根目录，
    // library.path = Frameworks。定制版 root lwjgl.jar（含 iOS 专用 LWJGL 补丁）通过 JavaApp/Makefile
    // 合并进最终 lwjgl.jar，确保 LWJGL 在 iOS 上能正确加载 GL 实现。
    NSString *frameworksPath = [NSString stringWithFormat:@"%@/Frameworks", NSBundle.mainBundle.bundlePath];
    PUSH_MARGV_FORMAT(@"-Djava.library.path=%@", frameworksPath);
    NSLog(@"[JavaLauncher] library.path = %@", frameworksPath);

    // Task 112：钉死 OpenAL 库的解析路径（绝对路径直载）。
    //
    // 崩溃取证（26.3 SoundEngine NPE，Task112 时代）：
    //   net.minecraft.client.sounds.SoundEngine.<init>
    //     -> com.mojang.blaze3d.audio.Library.createDeviceTracker()
    //     -> CallbackDeviceTracker.isSupported()
    //     -> LWJGL SOFTSystemEvents.alcEventIsSupportedSOFT
    //        ICD 函数指针为 NULL -> Checks.check 抛 NullPointerException -> 游戏崩溃。
    //
    // 错配条件 = "库宣称有扩展，但 alcGetProcAddress/dlsym 解析不到函数指针"。
    // 当时归因为 classpath 里被平台重标签的 openal-soft 1.24.x 抢先加载。
    //
    // 修复：ALC.create() 读 org.lwjgl.openal.libname（Configuration.OPENAL_LIBRARY_NAME），
    // 而 Library.loadNative 对【绝对路径】直接 dlopen、完全跳过 classpath 提取。
    // 把该属性钉到 Frameworks/libopenal.dylib 的绝对路径，任何 classpath 劫持即告失效。
    //
    // ⚠️ Task129 论断修正（bd71210 会话 26.1.2 整合包实锤）：
    //   "无扩展 => MC 干净回退"对无守卫的 MC 版本不成立。26.1.2 的
    //   CallbackDeviceTracker.isSupported 没有 alcIsExtensionPresent 前置守卫
    //   （26.3 有——这是同一构建上 26.3 存活、26.1.2 崩溃的全部差异），
    //   直接调 LWJGL 绑定：扩展不在 ALC_EXTENSIONS 串里 => ALCCapabilities 的
    //   32/33/34 号函数槽保持 0 => Checks.check NPE。因此本钉子指向的
    //   Frameworks/libopenal.dylib 已改为 Task129 垫片（re-export 1.20.1 impl
    //   + 宣称 ALC_SOFT_system_events + 桩函数返回 ALC_FALSE），使 MC 走
    //   "result==0 => warn + PollingDeviceTracker" 的干净回退。本钉子继续
    //   保留：垫片与钉子共同构成完整防线（钉子防 classpath 劫持，垫片补扩展面）。
    NSString *task112OpenalPin = [frameworksPath stringByAppendingPathComponent:@"libopenal.dylib"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:task112OpenalPin]) {
        PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.openal.libname=%@", task112OpenalPin);
        NSLog(@"[Prisma] Task112: OpenAL pinned to %@", task112OpenalPin);
    } else {
        NSLog(@"[Prisma] Task112: libopenal.dylib not found, OpenAL left to LWJGL default resolution");
    }

    PUSH_MARGV_FORMAT(@"-Duser.dir=%@", gameDir);
    PUSH_MARGV_FORMAT(@"-Duser.home=%s", getenv("POJAV_HOME"));
    PUSH_MARGV_FORMAT(@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name);
    PUSH_MARGV_FORMAT(@"-DUIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond);

    // 发布 GameSurfaceView 指针，供 Metallum Metal 后端使用
    // +[SurfaceViewController surface] 返回静态变量 pojavWindow，该变量在
    // -[SurfaceViewController viewDidLoad] 中被赋值（早于 launchMinecraft 派发到本后台线程）。
    // 通过系统属性传递指针，可避免 JVM 渲染线程通过 ObjC runtime 查找 UIView 的不确定性。
    Class surfaceVCClass = NSClassFromString(@"SurfaceViewController");
    if (surfaceVCClass && [surfaceVCClass respondsToSelector:@selector(surface)]) {
        id surfaceView = [surfaceVCClass performSelector:@selector(surface)];
        if (surfaceView) {
            PUSH_MARGV_FORMAT(@"-Dmetallum.ios.view.pointer=%p", surfaceView);
            PUSH_MARGV_FORMAT(@"-Dmetallum.ios.screen.scale=%g", (double)UIScreen.mainScreen.scale);
            NSLog(@"[JavaLauncher] Published Metallum surface view: %p (scale=%g)", surfaceView, (double)UIScreen.mainScreen.scale);
        } else {
            NSLog(@"[JavaLauncher] Warning: +[SurfaceViewController surface] returned nil, Metallum will fall back to ObjC runtime lookup");
        }
    } else {
        NSLog(@"[JavaLauncher] Warning: SurfaceViewController class unavailable, Metallum will fall back to ObjC runtime lookup");
    }

    // ★ Task258（清单 4）：首次启动按所选语言设置游戏语言（参考 FCL/PCL2CE：
    // 首启把启动器语言写进 MC 的 options.txt lang 键）。把启动器语言码传给
    // Java 侧，由 Java 在 options.txt 无 lang 键时写入（不覆盖用户已有选择）。
    {
        NSString *ame258_langPref = getPrefObject(@"general.app_language");
        if (![ame258_langPref isKindOfClass:[NSString class]] || ame258_langPref.length == 0) {
            ame258_langPref = @"system";
        }
        NSString *ame258_mcLang = nil;
        if ([ame258_langPref isEqualToString:@"system"]) {
            // 跟随系统：取首选语言，确定性最长前缀匹配到 MC 语言码
            NSString *ame258_sys = [NSLocale.preferredLanguages firstObject] ?: @"en";
            // 有序表：前缀越具体越靠前（zh-Hant 先于 zh），首个命中即用
            NSArray<NSArray<NSString *> *> *ame258_pairs = @[
                @[@"zh-Hant", @"zh_tw"], @[@"zh-HK", @"zh_tw"], @[@"zh-TW", @"zh_tw"],
                @[@"zh-Hans", @"zh_cn"], @[@"zh-CN", @"zh_cn"], @[@"zh", @"zh_cn"],
                @[@"en-GB", @"en_gb"], @[@"en", @"en_us"],
                @[@"pt-BR", @"pt_br"], @[@"pt", @"pt_br"],
                @[@"nb", @"nb_no"], @[@"no", @"nb_no"],
                @[@"ja", @"ja_jp"], @[@"ko", @"ko_kr"], @[@"ru", @"ru_ru"],
                @[@"fr", @"fr_fr"], @[@"de", @"de_de"], @[@"es", @"es_es"],
                @[@"it", @"it_it"], @[@"pl", @"pl_pl"], @[@"nl", @"nl_nl"],
                @[@"tr", @"tr_tr"], @[@"uk", @"uk_ua"], @[@"cs", @"cs_cz"],
                @[@"hu", @"hu_hu"], @[@"fi", @"fi_fi"], @[@"sv", @"sv_se"],
                @[@"da", @"da_dk"], @[@"el", @"el_gr"], @[@"ro", @"ro_ro"],
                @[@"th", @"th_th"], @[@"vi", @"vi_vn"], @[@"id", @"id_id"],
                @[@"ms", @"ms_my"], @[@"he", @"he_il"], @[@"ar", @"ar_sa"],
                @[@"fa", @"fa_ir"], @[@"hi", @"hi_in"],
            ];
            for (NSArray *ame258_pair in ame258_pairs) {
                if ([ame258_sys hasPrefix:ame258_pair[0]]) {
                    ame258_mcLang = ame258_pair[1];
                    break;
                }
            }
            if (ame258_mcLang.length == 0) {
                // 未命中（如小众语言）：主语言段同段晳合（如 "pt-XX" → pt_br），否则 en_us
                NSString *ame258_base = [[ame258_sys componentsSeparatedByString:@"-"] firstObject] ?: @"";
                NSString *ame258_lower = [ame258_base lowercaseString];
                if ([ame258_lower isEqualToString:@"pt"]) ame258_mcLang = @"pt_br";
                else if ([ame258_lower isEqualToString:@"zh"]) ame258_mcLang = @"zh_cn";
                else if ([ame258_lower isEqualToString:@"en"]) ame258_mcLang = @"en_us";
                else if ([ame258_lower isEqualToString:@"nb"]) ame258_mcLang = @"nb_no";
                else if ([ame258_lower isEqualToString:@"no"]) ame258_mcLang = @"nb_no";
                else ame258_mcLang = @"en_us";
            }
        } else {
            // 显式选择的启动器语言码（lproj 目录名）→ MC 语言码
            NSDictionary<NSString *, NSString *> *ame258_map2 = @{
                @"zh-Hans": @"zh_cn", @"zh-CN": @"zh_cn", @"zh-Hant": @"zh_tw",
                @"en": @"en_us", @"en-GB": @"en_gb", @"en-PT": @"en_pt", @"en-UD": @"en_ud",
                @"ja": @"ja_jp", @"ko": @"ko_kr", @"ru": @"ru_ru", @"fr": @"fr_fr",
                @"de": @"de_de", @"es": @"es_es", @"es-AR": @"es_ar", @"es-CL": @"es_cl",
                @"es-EC": @"es_ec", @"es-MX": @"es_mx", @"es-UY": @"es_uy", @"es-VE": @"es_ve",
                @"pt": @"pt_br", @"pt-BR": @"pt_br", @"it": @"it_it", @"pl": @"pl_pl",
                @"nl": @"nl_nl", @"tr": @"tr_tr", @"uk": @"uk_ua", @"cs": @"cs_cz",
                @"hu": @"hu_hu", @"fi": @"fi_fi", @"sv": @"sv_se", @"da": @"da_dk",
                @"no": @"nb_no", @"nb": @"nb_no", @"el": @"el_gr", @"ro": @"ro_ro",
                @"th": @"th_th", @"vi": @"vi_vn", @"id": @"id_id", @"ms": @"ms_my",
                @"he": @"he_il", @"ar": @"ar_sa", @"fa": @"fa_ir", @"hi": @"hi_in",
                @"af": @"af_za", @"sq": @"sq_al", @"az": @"az_az", @"ba": @"ba_ba",
                @"bn": @"bn_in", @"ca": @"ca_es", @"et": @"et_ee", @"fil": @"fil_ph",
                @"kk": @"kk_kz", @"km": @"km_kh", @"lt": @"lt_lt", @"sk": @"sk_sk",
                @"sr": @"sr_sp", @"sr-Latn": @"sr_sp", @"tt": @"tt_ru",
            };
            NSString *ame258_hit = ame258_map2[ame258_langPref];
            if (ame258_hit.length) {
                ame258_mcLang = ame258_hit;
            } else {
                // 未知码：小写 + 下划线兜底（如 "xx-YY" → "xx_yy"），MC 不识别则忽略
                NSArray *ame258_parts = [ame258_langPref componentsSeparatedByString:@"-"];
                if (ame258_parts.count == 2) {
                    ame258_mcLang = [NSString stringWithFormat:@"%@_%@", [ame258_parts[0] lowercaseString], [ame258_parts[1] lowercaseString]];
                } else {
                    ame258_mcLang = [ame258_langPref lowercaseString];
                }
            }
        }
        if (ame258_mcLang.length) {
            PUSH_MARGV_FORMAT(@"-Dame.launcher.lang=%@", ame258_mcLang);
            NSLog(@"[JavaLauncher] Task258: launcher lang pref=%@ -> MC lang=%@", ame258_langPref, ame258_mcLang);
        }
    }

    PUSH_MARGV_LITERAL("-Dorg.lwjgl.glfw.checkThread0=false");
    PUSH_MARGV_LITERAL("-Dorg.lwjgl.system.allocator=system");
    //PUSH_MARGV_LITERAL("-Dorg.lwjgl.util.NoChecks=true");
    PUSH_MARGV_LITERAL("-Dlog4j2.formatMsgNoLookups=true");

    // ============================================================================
    // JNA 加载路径
    // ============================================================================
    // JNA 5.13.0 的 darwin-aarch64 libjnidispatch 从 JAR 中提取后能正常加载。
    // Tools.java / MinecraftResourceUtils.m 已强制将 JNA 替换为 5.13.0
    // （MC 26.3+ 要求的 5.17.0 在 iOS 上会导致 native crash）。
    // 保留 boot.library.path 以便未来内置 iOS arm64 版 libjnidispatch。
    PUSH_MARGV_FORMAT(@"-Djna.boot.library.path=%@", frameworksPath);

    // ============================================================================
    // 帧率解锁第四层：JVM 系统属性
    // ============================================================================
    // 某些 MC 版本/mod 可能通过 System.getProperty 读取帧率限制。
    // 设置 -Dmax.fps=260 作为 options.txt 之外的额外兜底层。
    // 不影响不读取此属性的版本。
    if (getPrefBool(@"video.disable_game_vsync")) {
        PUSH_MARGV_LITERAL("-Dmax.fps=260");
        NSLog(@"[JavaLauncher] Added JVM property -Dmax.fps=260 (frame rate unlock layer 4)");
    }

    // ============================================================================
    // ZeroTier 联机 SOCKS5 代理注入 —— 暂时移除（排查启动崩溃）
    // ============================================================================
    // 原逻辑：检测 AMETHYST_SOCKS5_PROXY 环境变量，注入 -DsocksProxyHost/-DsocksProxyPort
    // ZeroTier 暂时移除后，MultiplayerManager 不再设置该环境变量，此块代码注释掉
    // ============================================================================
    // const char *socks5ProxyEnv = getenv("AMETHYST_SOCKS5_PROXY");
    // if (socks5ProxyEnv && socks5ProxyEnv[0] != '\0') {
    //     NSString *proxyStr = [NSString stringWithUTF8String:socks5ProxyEnv];
    //     NSRange colonRange = [proxyStr rangeOfString:@":"];
    //     if (colonRange.location != NSNotFound && colonRange.location > 0 &&
    //         colonRange.location + 1 < proxyStr.length) {
    //         NSString *proxyHost = [proxyStr substringToIndex:colonRange.location];
    //         NSString *proxyPortStr = [proxyStr substringFromIndex:colonRange.location + 1];
    //         NSInteger portValue = [proxyPortStr integerValue];
    //         if (portValue > 0 && portValue <= 65535) {
    //             PUSH_MARGV_FORMAT(@"-DsocksProxyHost=%@", proxyHost);
    //             PUSH_MARGV_FORMAT(@"-DsocksProxyPort=%@", proxyPortStr);
    //             NSString *nonProxyHosts = @"localhost|127.*|[::1]|"
    //                                       @"*.minecraft.net|*.mojang.com|"
    //                                       @"*.microsoft.com|*.microsoftonline.com|"
    //                                       @"*.xboxlive.com|*.modrinth.com|"
    //                                       @"*.curseforge.com|*.githubusercontent.com|"
    //                                       @"*.github.com|*.amazonaws.com|"
    //                                       @"*.cloudfront.net|*.akamaihd.net|"
    //                                       @"10.*|192.168.*|172.16.*|172.17.*|172.18.*|"
    //                                       @"172.19.*|172.20.*|172.21.*|172.22.*|172.23.*|"
    //                                       @"172.24.*|172.25.*|172.26.*|172.27.*|172.28.*|"
    //                                       @"172.29.*|172.30.*|172.31.*";
    //             PUSH_MARGV_FORMAT(@"-DsocksNonProxyHosts=%@", nonProxyHosts);
    //             NSLog(@"[JavaLauncher] Injected ZeroTier SOCKS5 proxy: %@:%@", proxyHost, proxyPortStr);
    //         }
    //     }
    // }

    // Preset OpenGL libname
    const char *glLibName = getenv("AMETHYST_RENDERER");
    if (glLibName) {
        if (!strcmp(glLibName, "auto")) {
            // Task 144：自动渲染器机制升级（用户指令"优化一下自动渲染器机制"）。
            //
            // 旧逻辑（26.2 时代"始终 ANGLE"）的顾虑是 MobileGlues 缺 config.json
            // 用不安全默认值初始化——该顾虑已被双修复消除：
            //   ① init_loadMobileGluesConfig 现按 ame_effective_renderer 白名单
            //      覆盖家族键，auto 解析出的 libMobileGL 会拿到 config.json +
            //      MG_DIR_PATH（用户 MobileGlues 分区偏好全部生效）；
            //   ② POJAV_RENDERER 环境变量激活 LWJGL 补丁的 fixPojavGLContext，
            //      渲染线程在 glGetString 探针前重绑上下文（Mithril 4.0 装机
            //      闪退的根因，同一机制对 MobileGL 家族同样是正确性收益）。
            // 新逻辑：MC 1.17+（minVersion>8，与 defaultJRETag 分界同源）优先
            // MobileGL Vulkan 直连（用户长期主用的装机验证最快路径；dylib 缺失
            // 或旧版本回退 ANGLE，保持旧行为）。layerClass 侧 auto 与 MobileGL
            // 均返回 CAMetalLayer（GameSurfaceView），Task124 同源约束不受影响。
            // Task 173：auto 的旧版本分支从 ANGLE 改为 gl4es（用户指令
            // "会根据游戏版本自动分配渲染器"）。依据：CMakeLists 对
            // tinygl4angle 的定位是 "ANGLE wrapper for 1.17+"（桌面 GL 3.3
            // 语义），旧版 MC（1.8.9-forge 等装机会话）的 legacy GLSL 120/
            // 固定管线在 gl4es（gl4es 1.1.4，legacy 语义翻译的老兵）上才是
            // 验证过的路径——用户在 1.8.9 会话手动选 gl4es 也是这个原因。
            // Task 212：legacy 默认随 holy gl4es 退役改道 ZL2 经典版
            // gl4es（gl4es(≤26.2)——同 1.1.4 血统、源码构建）。
            //
            // Task 217（增强自动渲染器智能化）：版本基线保持不变，叠加两层：
            //   (a) 崩溃自学（hs_err 裁决 + 实例级拉黑）——每次 auto 解析前，
            //       先裁决上一会话：哨兵文件记录了上次启动的渲染器与时间戳，
            //       若其后出现新的 hs_err_pid*.log（JVM 信号级死亡，区别于
            //       FastQuit 的 exit(0)）则该渲染器连败计数 +1，连续 2 次
            //       即拉黑，auto 沿候选链降档并 toast 告知；干净会话清零。
            //       显式选择的渲染器永远优先（拉黑只影响 auto 解析）。
            //   (b) 决策留痕——每次解析打印输入/候选链/拉黑态/结论，装机
            //       日志可直接复盘 auto 行为，为后续机型/版本维度优化积累证据。
            // 候选链（版本基线 + dylib 存在性 + 拉黑过滤后的首个可用项）：
            //   1.17+：MobileGL → gl4es(≤26.2) → ANGLE
            //   ≤1.16：gl4es(≤26.2) → ANGLE → MobileGL
            {
                // ---- (a) 上一会话裁决（崩溃自学）----
                ame217_autoRendererAdjudicateLastSession();
                // ---- (b) 候选链决策 ----
                NSString *ame217_pick = ame217_autoRendererDecide(minVersion);
                glLibName = ame217_pick.UTF8String;
                setenv("AMETHYST_RENDERER", glLibName, 1);
                // 哨兵：记录本次 auto 解析的渲染器 + 时间，供下一会话裁决。
                NSString *ame217_sentinel = [NSString stringWithFormat:@"%@/.ame217_session",
                    @(getenv("POJAV_HOME"))];
                [[NSString stringWithFormat:@"%@|%lld", ame217_pick,
                    (long long)[[NSDate date] timeIntervalSince1970]]
                    writeToFile:ame217_sentinel atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            // Task 154：auto 解析结果只会是 libMobileGL/gl4es/ANGLE（见上），
            // 三者都是全局上下文模型，不导出 POJAV_RENDERER（导出会触发
            // Sodium 反 Pojav 检测，见 launchJVM 主导出处 Task145 注释）。
            // Task 154（Mithril 同步退役 POJAV_RENDERER）：Task145 为激活
            // fixPojavGLContext 而给 Mithril 保留的导出一并移除——7c32bc3
            // Mithril 会话的 mod 列表含 sodium 0.9.2（PostLaunchChecks 检测
            // 到该变量即抛异常，Task145 自己的发现），且上下文重绑已由
            // Task144 TLS 修复 + Task154 Delegate dlsym 补丁覆盖，该变量
            // 只剩雷点没有收益。全渲染器零导出口径。
        }
        if (strcmp(glLibName, RENDERER_NAME_VULKAN) == 0) {
            // 对齐 Ynnyny 仓库：Vulkan 模式下 OpenGL 回退库使用 MobileGlues
            //
            // libMoltenVK 是 Vulkan loader，不是 GL 实现；绑定它为 opengl.libname 会导致
            // LWJGL 查找 GL 符号失败。但 MC 26.2 的 NativeLibrariesBootstrap.loadOpenGL()
            // 在启动时会初始化 org.lwjgl.opengl.GL（无论游戏最终用哪个渲染器）。
            // 若 opengl.libname 未设置，LWJGL 回退到 MacOSXLibraryBundle.getWithIdentifier
            // ("com.apple.opengl")，iOS 上无系统 OpenGL framework 会失败 →
            //   UnsatisfiedLinkError: Failed to retrieve bundle with identifier: com.apple.opengl
            // 指向 libmobileglues.dylib：MobileGlues 专为 GL-on-Metal/Vulkan 设计，
            // 已使用 shipped libspirv-cross.dylib 做着色器翻译。GL.create() 能找到 GL 函数指针；
            // 若 MC 调用 GL 入口（compat 代码、着色器构建等），MobileGlues 能通过 Vulkan 路由，
            // 而非像无上下文的 gl4es 那样崩溃。
            //
            // 注意：vulkan.libname 不在此设置（对齐 Ynnyny），由 PojavLauncher.java 通过
            // System.setProperty("org.lwjgl.vulkan.libname", "libMoltenVK.dylib") 设置。
            // 若在此用 -D 传 "libMoltenVK.dylib"，LWJGL Library.loadNative 会加 "lib" 前缀和
            // ".dylib" 后缀，得到 "liblibMoltenVK.dylib.dylib"（错误文件名）。
            //
            // MoltenVK 配置（对齐 Ynnyny）：
            // - RESUME_LOST_DEVICE=1：设备丢失后自动恢复
            // - SYNCHRONOUS_QUEUE_SUBMITS=1：同步队列提交（更稳定，避免竞争）
            // - PREFILL_METAL_COMMAND_BUFFERS=1：预填充 Metal 命令缓冲区（减少 GPU 等待，性能优化）
            setenv("MVK_CONFIG_RESUME_LOST_DEVICE", "1", 1);
            setenv("MVK_CONFIG_SYNCHRONOUS_QUEUE_SUBMITS", "1", 1);
            setenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "1", 1);
        }
        // 对齐 Ynnyny：使用独立变量 openglLibName，不修改 glLibName（保持原值用于后续判断）
        const char *openglLibName = (strcmp(glLibName, RENDERER_NAME_VULKAN) == 0)
            ? RENDERER_NAME_MOBILEGLUES
            : glLibName;
        // Task 131：-gles 变体是渲染器菜单里的逻辑键（GLES 档），物理 dylib
        // 不随包——共享 libMobileGL.dylib 二进制，后端由上方 MobileGL 分支
        // 设置的 MOBILEGL_BACKEND_TYPE=DirectGLES 选择。LWJGL 的 libname
        // 必须指向磁盘上真实存在的文件（且含连字符的名字会被
        // Platform.mapLibraryName 二次包装，见下方裸名修复注释），故映射到
        // 共享二进制名。
        if (strcmp(openglLibName, RENDERER_NAME_MOBILEGL_GLES) == 0) {
            openglLibName = RENDERER_NAME_MOBILEGL;
        }

        // 关键修复（libMobileGL-gles 加载失败）：这里必须传"裸名"，不能传完整文件名。
        //
        // LWJGL 的 Platform.mapLibraryName（macOS 分支）先用一个正则判断名字是否"已经是
        // dylib 文件名"，是则原样返回，否则交给 System.mapLibraryName 补 "lib" 前缀和
        // ".dylib" 后缀：
        //     private final Pattern DYLIB =
        //         Pattern.compile("(?:^|/)lib\\w+(?:[.]\\d+)*[.]dylib$");
        //     if (DYLIB.matcher(name).find()) return name;
        //     return System.mapLibraryName(name);
        //
        // \w 不含连字符，所以 "libMobileGL-gles.dylib" 不匹配该正则（"lib"+\w+ 在 '-' 处
        // 断开），被误判为需要补前缀后缀 -> "liblibMobileGL-gles.dylib.dylib"，文件不存在
        // -> UnsatisfiedLinkError。其余渲染器名（mobileglues / OSMesa.8 / gl4es_114 /
        // MobileGL / MoltenVK）都能匹配，所以只有 GLES 这个带连字符的库名中招。
        //
        // 传裸名（去掉 "lib" 前缀与 ".dylib" 后缀）对全部渲染器都成立：裸名一定不匹配
        // DYLIB 正则（开头不是 lib），于是统一走 System.mapLibraryName 补回，得到与磁盘
        // 完全一致的文件名。
        NSString *openglLibBareName = lwjglBareLibName(openglLibName);
        // Task146：Mithril（OpenGL 4.0 档）libname 从裸名升级为绝对路径。
        // 病历：Mithril 会话 make-current 探针证实渲染器自身 glGetString 正常
        // 返回版本号（dlsym 自 dlsym_EGL 记录的句柄），但 LWJGL
        // GL.createCapabilities 拿到的同名解析返回 NULL → "no OpenGL context"。
        // 唯一未定因素：裸名 libname 的 dlopen 能否命中 dlsym_EGL 已加载的
        // 实例取决于 dyld 的路径/安装名匹配。绝对路径使 LWJGL 的 dlopen 与
        // @rpath 预加载指向同一物理文件（dyld 按规范路径去重 → 同一实例），
        // 函数解析必然落在 Mithril 自身实现上。三指针对比探针（gl_bridge
        // make-current 分支）同场留证：修复生效则 RESOLVED-SAME 且 ver 非空。
        // 文件不存在时回退裸名（原行为），其余渲染器路径零改动。
        NSString *openglLibPush = openglLibBareName;
        if (strcmp(glLibName, RENDERER_NAME_MITHRIL) == 0) {
            // Task156：Mithril 的 opengl.libname 优先指向 GL 垫片 libmithril_glshim.dylib
            //（re-export libmithril 全部符号 + 本地 glGetIntegerv/glGetInteger64v 对
            // limit 枚举 0 值补下限——MC 26.2 DynamicUniformStorage 的
            // GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT 除零崩溃根修，见
            // Natives/mithril_gl_shim.c 病历）。垫片缺失时回退 Task146 绝对路径
            //（dlsym-direct 解析仍成立，仅 /0 补底失效），再回退裸名（原行为）。
            NSString *ame156_shim = [[[NSBundle mainBundle] bundlePath]
                stringByAppendingPathComponent:@"Frameworks/libmithril_glshim.dylib"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:ame156_shim]) {
                openglLibPush = ame156_shim;
                NSLog(@"[JavaLauncher] Task156: Mithril libname -> GL shim %@ (re-export + limit floors)", ame156_shim);
            } else {
                NSLog(@"[JavaLauncher] Task156: Mithril GL shim missing (%@), falling back to direct dylib", ame156_shim);
                NSString *ame146_abs = [[[NSBundle mainBundle] bundlePath]
                    stringByAppendingPathComponent:@"Frameworks/libmithril.dylib"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:ame146_abs]) {
                    openglLibPush = ame146_abs;
                    NSLog(@"[JavaLauncher] Task146: Mithril libname -> absolute path %@ (dedupe into dlsym_EGL instance)", ame146_abs);
                } else {
                    NSLog(@"[JavaLauncher] Task146: Mithril abs path missing (%@), fallback to bare name", ame146_abs);
                }
            }
        }
        PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.opengl.libname=%s", openglLibPush.UTF8String);

        // 关键修复（参照 FCL，阶段4：26.2 图形 API 切换无效）：
        // 之前仅在 renderer=libMoltenVK.dylib 时由 PojavLauncher.java 通过 System.setProperty 设置
        // org.lwjgl.vulkan.libname，导致用户保留默认 renderer=auto（解析为 ANGLE）并切换
        // graphicsApi=prefer_vulkan 时，LWJGL 找不到 Vulkan 库 → MC 静默回退 OpenGL。
        //
        // FCL 做法：在 JVM 启动前通过 -D 系统属性同时确定 OpenGL 和 Vulkan 两条路径的 native 库，
        // 无论 MC 最终选哪条路都能找到对应的库。
        //
        // 传裸名（由 lwjglBareLibName 从 RENDERER_NAME_VULKAN 剥出 "MoltenVK"）：裸名不匹配
        // LWJGL 的 DYLIB 正则，必定走 System.mapLibraryName 补回 "lib" 前缀与 ".dylib" 后缀，
        // 得到 "libMoltenVK.dylib"。
        //
        // 顺便修正此处原有注释：它声称传 "libMoltenVK.dylib" 会被二次包装成
        // "liblibMoltenVK.dylib.dylib" —— 实际上 "libMoltenVK.dylib" 是匹配 DYLIB 正则的，
        // 原样返回并不会被二次包装（日志中 Vulkan 正常加载即为佐证）。真正会中招的是
        // 名字含连字符的库（见上方 opengl.libname 的修复）。改传裸名是为了与 opengl 侧
        // 统一口径，也让规则对任何文件名都成立。
        //
        // 安全性：即使 MC 最终走 GL 路径，加载 MoltenVK 也无副作用（GL 路径不调用 Vulkan 入口）。
        PUSH_MARGV_FORMAT(@"-Dorg.lwjgl.vulkan.libname=%s",
                          lwjglBareLibName(RENDERER_NAME_VULKAN).UTF8String);

        // 显式指定 spirv-cross 库名（参照 catsruledogs/Amethyst-iOS-25）：
        // LWJGL spvc 模块默认查找 "spirv-cross" -> 加载 libspirv-cross.dylib（macOS 标准名），
        // 但实际文件名为 libspirv-cross-c-shared.0.dylib（带版本后缀的 SO 名）。
        // 显式设置 -Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0，LWJGL 的 Library.loadNative
        // 会对 libname 加 "lib" 前缀和 ".dylib" 后缀，得到 "libspirv-cross-c-shared.0.dylib"，
        // 从 library.path（Frameworks）找到该文件。
        PUSH_MARGV_LITERAL("-Dorg.lwjgl.spvc.libname=spirv-cross-c-shared.0");
    }

      // 添加authlib-injector参数以支持第三方认证账户的皮肤显示
    if ([accountId length] > 0 && [BaseAuthenticator.current isKindOfClass:[ThirdPartyAuthenticator class]]) {
        BaseAuthenticator *currentAuth = BaseAuthenticator.current;
        if (currentAuth.authData[@"authserver"] != nil) {
            NSLog(@"[JavaLauncher] Adding authlib-injector arguments for third party account");
            NSArray *authlibArgs = [(ThirdPartyAuthenticator *)currentAuth getJvmArgsForAuthlib];
            if (authlibArgs.count > 0) {
                for (NSString *arg in authlibArgs) {
                    // arg 来自 authlibArgs 数组，是 strong 引用；但数组本身可能在循环外
                    // 被释放，为防止悬垂，通过 PUSH_MARGV_FORMAT 持久化
                    PUSH_MARGV_FORMAT(@"%@", arg);
                    NSLog(@"[JavaLauncher] Added authlib-injector arg: %s", arg.UTF8String);
                }     
            } else {
                NSLog(@"[JavaLauncher] Warning: No authlib-injector arguments available");
            }
        }
    }
  
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    PUSH_MARGV_FORMAT(@"-javaagent:%@/patchjna_agent.jar=", librariesPath);
    // [Metallum agent]（Task201 随上游同步）原生 Metal 后端（26.2 / 26.3）：
    //   * jar 由 JavaApp/libs/others/ 随包落在 app/libs/（见根 Makefile 的 payload 目标），
    //     agent 自带 metallum 类集与 natives/ios（libmetallum.dylib、libspvc.dylib），
    //     运行期自行解出到沙盒，不需要 Frameworks 另行放置。
    //   * 注入范围由 agent 自己判定（premain 按 MC 版本 / 加载器分流：26.2 走
    //     classes262 类集、Fabric 缺桩时跳过相应步骤、Forge 走 dummy provider
    //     且不注入自带 slf4j）。
    //   * jar 不在 libs/ 时安静跳过，便于回滚与 A/B。
    //   * [fix/java8-agent] 只对 MC major >= 26 挂载：agent 的 class 文件版本是
    //     65.0（Java 21+ 编译），而老版本 MC 走 Java 8（class 上限 52.0）——
    //     此前"老版本 MC 没有目标类，转换器天然 no-op"的假设漏掉了 agent
    //     本身在 Java 8 上就加载不了这件事（UnsupportedClassVersionError ->
    //     "processing of -javaagent failed" -> JVM 直接 abort，premain 阶段
    //     全灭，GL/SFPEW 代码根本没机会跑）。
    //     26.x 强制 Java 25（ResolveLwjglVersion 同款 major 判定），class 65 可加载。
    if ([[NSFileManager defaultManager] fileExistsAtPath:
            [librariesPath stringByAppendingPathComponent:@"metallum_agent.jar"]]) {
        NSString *metallumMcVersionId = nil;
        if ([launchTarget isKindOfClass:NSDictionary.class]) {
            metallumMcVersionId = [launchTarget[@"id"] description];
        } else if ([launchTarget isKindOfClass:NSString.class]) {
            metallumMcVersionId = (NSString *)launchTarget;
        }
        NSInteger metallumMcMajor = ame98_mcMajorFromVersionId(metallumMcVersionId);
        if (metallumMcMajor >= 26) {
            PUSH_MARGV_FORMAT(@"-javaagent:%@/metallum_agent.jar=", librariesPath);
            // 把实例的 MC 版本 id 传给 agent（按版本选 metallum 类映射）
            if (metallumMcVersionId.length > 0) {
                PUSH_MARGV_FORMAT(@"-Dmetallum.mc.version=%@", metallumMcVersionId);
            }
            NSLog(@"[JavaLauncher] Task201: Metallum agent enabled: -javaagent:metallum_agent.jar (mcVersion=%@)",
                  metallumMcVersionId);
        } else {
            NSLog(@"[JavaLauncher] Task201: Metallum agent skipped: MC major %ld < 26 (agent needs Java 21+ class files, this session runs Java 8)",
                  (long)metallumMcMajor);
        }
    }
    if(getPrefBool(@"general.cosmetica")) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/arc_dns_injector.jar=23.95.137.176", librariesPath);
    }
    if(getPrefBool(@"video.fix_simple_voice_chat_mod")) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/patchsvc.jar=", librariesPath);
    }
    // ★ Task251（反馈 2 四修）：patchsvc agent 改为无条件注入——它的 premain
    //   还承担游戏会话 Java shutdown hook 注册（写 _exit 标记，26.3 退出
    //   挂死双保险的甲路；仅 -Dame.game.session=1 时注册，headless 零影响）。
    //   语音修复 transformer 本身对无关会话零副作用（只拦 6 个音频类）。
    if (!getPrefBool(@"video.fix_simple_voice_chat_mod")) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/patchsvc.jar=", librariesPath);
    }
    // ★ Task251：游戏会话标记（premain 据此决定是否注册 shutdown hook；
    //   headless JVM 不带此属性 = 安装器流程零回归）。
    PUSH_MARGV_LITERAL("-Dame.game.session=1");

    // ★ Task263（⑧大型整合包 Cobblemon showdown 卡死根修）：路径绝对化 agent。
    //   病历（261/262/263 四轮装机 gamelog，挂死签名逐字一致）：Cobblemon 的
    //   GraalShowdownService 用 java.io File("showdown") 相对路径解压 showdown.zip
    //   （系统调用按进程真实 CWD 落盘），而 GraalJS 校验 js.commonjs-require-cwd=
    //   "showdown" 时 TruffleFile.exists() 经自定义 FileSystem checkAccess 走 NIO
    //   UnixPath.toRealPath（相对路径预绝对化到 -Duser.dir 属性基准）。JDK21 桌面
    //   实证：两个基准不同时（java.io=真实 CWD / NIO=属性），解压产物对校验不可见
    //   -> guest Error "Invalid CommonJS root folder: showdown" -> ShowdownThread
    //   未捕获死亡，latch.countDown() 永不执行 -> ShowdownThread.launch() 的
    //   latch.await() 永久驻停 Render thread -> fps=0、SDL 窗口永不创建 -> 黑屏
    //   "无输出"。showdown_agent（premain + ClassFileTransformer，按类名门控两个
    //   Cobblemon 类）把 4 个相对路径 LDC 常量改写为 ame.showdown.home 锚定的绝对
    //   拼接，彻底绕开相对解析基准（本地真 jar 端到端实证：全分歧场景
    //   openConnection 完整成功，106MB 真实 showdown 解压到锚定目录零泄漏）。
    //   agent class 文件为 javac 默认 target（Java 8 兼容），全会话无条件注入
    //   （同 Task251 patchsvc 先例）；无 Cobblemon 会话 transformer 按类名零匹配。
    //   -Dame.showdown.home=<gameDir> 与 -Duser.dir 同源同值（ame97 chdir 同参）。
    if ([[NSFileManager defaultManager] fileExistsAtPath:
            [librariesPath stringByAppendingPathComponent:@"showdown_agent.jar"]]) {
        PUSH_MARGV_FORMAT(@"-javaagent:%@/showdown_agent.jar", librariesPath);
        PUSH_MARGV_FORMAT(@"-Dame.showdown.home=%@", gameDir);
        NSLog(@"[JavaLauncher] Task263: showdown agent enabled (ame.showdown.home=%@)", gameDir);
    } else {
        NSLog(@"[JavaLauncher] Task263: showdown_agent.jar not found in libs, path fix unavailable (Cobblemon modpacks may hang at showdown init)");
    }

    // ★ Task259（清单 10）：FO 整合包 26.3 局域网游戏闪退根修。
    //   病历（456d65e hs_err_pid28441.log，21:08:24，elapsed 35.9s + fatal_trace
    //   21:02:56 三连 abort()）：FO 自带 e4mc 模组，"对局域网开放"时其
    //   e4mc_minecraft-init 线程初始化 netty-incubator-codec-quic（0.0.74.Final
    //   .e4mc.1，fork 版），Quiche.loadNativeLibrary() 从 natives.e4mc.link 下载
    //   libnetty_quiche_osx_aarch_64_74.dylib 落盘后 System.load —— 运行时解包的
    //   dylib 无有效代码签名，iOS 内核在 JNI_OnLoad+0x0 首条指令 SIGBUS，
    //   整个 JVM 当场死亡（用户视角：一开局域网就闪退，三次复现）。
    //   修法（零字节码手术，e4mc fork 自带的发行版打包者接口）：
    //   -Dlink.e4mc.native_path=<不存在路径> 使 loadNativeLibrary 直达
    //   System.load 分支（跳过缓存目录探测/SHA-256/下载），对不存在文件
    //   抛 UnsatisfiedLinkError（无映射无 SIGBUS）→ 其 catch 原样 rethrow →
    //   Quiche.<clinit> 的 afInet 等 JNI 常量调用同样 ULE → EIEE →
    //   e4mc QuiclimeSession.start() 的 try/catch 接住 → fail(t) 记日志 →
    //   init 线程优雅死亡。e4mc 公网中继在 iOS 不可用（原生 quic 无法加载，
    //   设计使然），游戏本体/原版局域网/内置陶瓦联机全部不受影响。
    //   关闭开关：偏好 debug 段设 ame259.quic_guard=false（无此键 = 开启）。
    if (getPrefBool(@"debug.ame259_quic_guard") == NO) {
        PUSH_MARGV_LITERAL("-Dlink.e4mc.native_path=/nonexistent.ame259.quic-disabled");
        NSLog(@"[JavaLauncher] Task259: link.e4mc.native_path stubbed "
              @"(netty-quic native SIGBUS guard; e4mc relay degrades gracefully)");
    } else {
        NSLog(@"[JavaLauncher] Task259: quic guard disabled by preference "
              @"debug.ame259_quic_guard -- e4mc will attempt native quic load");
    }

    // Workaround random stack guard allocation crashes
    PUSH_MARGV_LITERAL("-XX:+UnlockExperimentalVMOptions");
    PUSH_MARGV_LITERAL("-XX:+DisablePrimordialThreadGuardPages");

    // 关键修复（liblwjgl_stb SIGILL 崩溃，CodeCache 满）：
    //   崩溃日志显示 "CodeCache is full. Compiler has been disabled." 紧接 SIGILL
    //   at liblwjgl_stb.dylib+0x4d26c。复现路径包括：
    //   - 1.16.5 + libOSMesa + zink + MoltenVK（Java 8）
    //   - 1.20.1 + Forge + mobileglues（Java 17）
    //   说明根因与渲染器无关，是 CodeCache 容量不足。
    //
    //   项目从未设置 CodeCache 参数，完全依赖 JVM 默认值：
    //   - Java 8 默认 ReservedCodeCacheSize=48MB
    //   - Java 17+ 默认 240MB（仍可能在大量 native 加载下紧张）
    //
    //   CodeCache 满后 JIT 编译中的方法被部分无效化，CPU 执行到损坏的指令序列
    //   → SIGILL（崩溃点落在 liblwjgl_stb 是因为 stb_truetype 字体光栅化是首个
    //   大量 JIT 的 native wrapper，与渲染器无关）。
    //
    //   修复：设置为 64m，对 Java 8/17/21/25 全部生效。
    //   - 64m 仍比 Java 8 默认值（48MB）大 33%，足够避免 CodeCache 满导致的 SIGILL
    //   - InitialCodeCacheSize=16m 避免启动时立即触发 CodeCache 扩容（默认 2.25m
    //     会多次扩容，每次扩容都触发全局锁）
    //   - CodeCacheExpansionSize=4m 减少扩容次数（默认 64K 太小）
    //   - +UnlockExperimentalVMOptions 已在上一行启用，无需重复
    //
    //   iOS 27 SIGBUS fix (non-TXM devices, e.g. A15):
    //   On iOS 26+, -XX:+MirrorMappedCodeCache maps JIT code into RX memory
    //   allocated by the StikDebug debugger. With 256m, the mirrored region
    //   extends into pages whose executability is unreliable, causing intermittent
    //   SIGBUS when JIT-compiled code lands on those pages. The crash is
    //   intermittent because it depends on how much JIT code the JVM generates
    //   at runtime - if it stays within the safe region, the app exits normally.
    //   Reducing to 64m constrains the mirror mapping within the debugger's
    //   reliably allocated RX region, eliminating the SIGBUS.
    //   Repro: iOS 27 + A15 (no TXM) + StikDebug + Java 21 (MC 1.21.1).
    //   Java 25 (MC 26.2+) is unaffected - its JIT handles mirror mapping
    //   more robustly and doesn't trigger the crash even with 256m.
    // ★ Task284（"把 CodeCache 调大"）：分轨放大——镜像映射路径（iOS 26+）
    //   维持 64m：上文 SIGBUS 病历的硬边界，StikDebug 授予的 RX 映射恒
    //   64MB（装机日志 "Requesting 64 MB for JIT mapping" 为外部工具定值，
    //   本仓库不可调），预留超出 = 镜像越界到不可靠页，间歇 SIGBUS 复发；
    //   非镜像路径（iOS < 26：TrollStore/越狱/direct JIT）无此约束放大到
    //   256m——大整合包（Forge 1.12.2 + 17 coremods 装机会话）JIT 体量
    //   余量，杜绝 "CodeCache is full. Compiler has been disabled." 退化
    //   解释执行。
    //   ★ Task285（"性能优先扩大CodeCache"装机追平）：镜像轨 64m 预算内
    //   Initial 16m→48m / Expansion 4m→8m 一次到位——Forge 17+ coremods
    //   类加载 JIT 编译高峰期不再经历多次堆扩张（每次扩张 = RX 映射内
    //   mprotect 页翻转 + 锁窗口），commit 是虚拟预留、物理页按需分配，
    //   驻留零增加；总预算仍锁死 64m 外部硬边界。
    if (ame286_legacyVersion) {
        // ★ Task286：远古版 JIT 体量极小（PocketJ legacy path 同值
        //   2M/16M）——小预留降低 iOS 虚拟地址空间压力，Classic/Alpha
        //   无大 CodeCache 需求；镜像轨 64m 硬边界内富余。
        PUSH_MARGV_LITERAL("-XX:ReservedCodeCacheSize=16m");
        PUSH_MARGV_LITERAL("-XX:InitialCodeCacheSize=2m");
    } else if (@available(iOS 26.0, *)) {
        PUSH_MARGV_LITERAL("-XX:ReservedCodeCacheSize=64m");
        PUSH_MARGV_LITERAL("-XX:InitialCodeCacheSize=48m");
        PUSH_MARGV_LITERAL("-XX:CodeCacheExpansionSize=8m");
    } else {
        PUSH_MARGV_LITERAL("-XX:ReservedCodeCacheSize=256m");
        PUSH_MARGV_LITERAL("-XX:InitialCodeCacheSize=32m");
        PUSH_MARGV_LITERAL("-XX:CodeCacheExpansionSize=8m");
    }

    // On iOS 26, use mirror mapped JIT by default
    if (@available(iOS 26.0, *)) {
        PUSH_MARGV_LITERAL("-XX:+MirrorMappedCodeCache");
    }

    // Disable Forge 1.16.x early progress window
    PUSH_MARGV_LITERAL("-Dfml.earlyprogresswindow=false");
    // Task203：Forge 26.x（64.x）early display 抑制散弹。装机病历
    // （用户实测，Forge 26.1.2 + MobileGlues）：early display 的独立小
    // 上下文在转译层上初始化着色器失败（"An error occurred initializing
    // shaders"）→ Forge 退到 LWJGL tiny file dialogs 的错误弹窗 → iOS 无
    // applescript/kdialog/zenity → "missing software!" 控制台 y/n 回退
    // （stdin=/dev/null，EOF 即返回，不会死锁，但提示吓人且 early display
    // 本身已废）。旧属性名 fml.earlyprogresswindow 对 26.x 已失效，
    // 补齐新代 Forge/NeoForge 的两个属性名；未知属性对 JVM/其他框架
    // 无害（忽略）。early display 被跳过后 Forge 无进度小窗直接进主
    // 渲染——在转译层上反而更稳（少一个异构 GL 上下文）。
    PUSH_MARGV_LITERAL("-Dneoforge.enabledEarlyDisplay=false");
    PUSH_MARGV_LITERAL("-Dforge.disableEarlyDisplay=true");

    // Load java
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome]; // java 8
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome]; // java 11+
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];

    // ============================================================================
    // JVM 性能优化（保守参数，不影响启动稳定性）
    // ============================================================================
    // ★ Task255（清单 11：JVM 预设）：按 java.jvm_preset 四档注入 GC 策略。
    //   memory（省内存）：G1 激进收缩——小年轻代 + 高归还比率，堆占用峰值
    //     显著下降（代价：GC 更频繁，帧生成时间波动略大）；
    //   normal（默认）：既有定稿（G1GC + 50ms + StringDeduplication，历轮
    //     装机验证基线，零回归面）；
    //   performance（性能优先）：大年轻代 + 20ms 停顿目标——减少 GC 触发
    //     频率，吞吐优先（代价：单次 GC 略长、堆占用更高）；
    //   custom：不注入任何 GC 段（用户经 java.jvm_preset_custom_args /
    //     java_args 自管，见 init_loadCustomJvmFlags 的 custom 注入链）。
    // 仅对 Java 17+ 启用 G1GC 调优。Java 8 的 G1GC 不够成熟：memory 档给
    // SerialGC（足迹最小），performance 档给 ParallelGC（吞吐最大）。
    // 不添加 -XX:+AlwaysPreTouch（延长启动时间）、-XX:TieredStopAtLevel=1（降低 JIT 性能）、
    // -XX:CICompilerCount=1（减少编译线程）等可能影响游戏体验的参数。
    // -XX:+UnlockExperimentalVMOptions 已在上方添加，UseStringDeduplication 需要实验模式。
    /* ★ Task256（清单 8）：解析链 profile.jvm_preset → java.jvm_preset → normal
       （ame256_effectiveJvmPreset 单一事实源，与 init_loadCustomJvmFlags 的
       custom 注入点同源）。 */
    NSString *ame255_preset = ame256_effectiveJvmPreset();
    if (![ame255_preset isKindOfClass:[NSString class]] || ame255_preset.length == 0) ame255_preset = @"normal";
    BOOL ame255_isCustom = [ame255_preset isEqualToString:@"custom"];
    if (!isJava8) {
        if (ame255_isCustom) {
            NSLog(@"[JavaLauncher] Task255 JVM preset=custom: GC tuning skipped (user-managed via jvm_preset_custom_args/java_args)");
        } else if ([ame255_preset isEqualToString:@"memory"]) {
            // 省内存档：G1 激进收缩。G1NewSizePercent 5%（默认 5）→ 保持，
            // MaxNewSizePercent 40%（默认 60）压小年轻代；MinHeapFreeRatio 5 /
            // MaxHeapFreeRatio 15（默认 40/70）→ 并发周期后激进归还内存给系统。
            PUSH_MARGV_LITERAL("-XX:+UseG1GC");
            PUSH_MARGV_LITERAL("-XX:MaxGCPauseMillis=200");
            PUSH_MARGV_LITERAL("-XX:+UseStringDeduplication");
            PUSH_MARGV_LITERAL("-XX:G1MaxNewSizePercent=40");
            PUSH_MARGV_LITERAL("-XX:MinHeapFreeRatio=5");
            PUSH_MARGV_LITERAL("-XX:MaxHeapFreeRatio=15");
            NSLog(@"[JavaLauncher] Task255 JVM preset=memory: G1GC shrink-to-heap (pause=200, MaxNew=40%%, free 5..15)");
        } else if ([ame255_preset isEqualToString:@"performance"]) {
            // 性能优先档：大年轻代（30..50）拉长 GC 间隔 + 20ms 停顿软目标。
            PUSH_MARGV_LITERAL("-XX:+UseG1GC");
            PUSH_MARGV_LITERAL("-XX:MaxGCPauseMillis=20");
            PUSH_MARGV_LITERAL("-XX:+UseStringDeduplication");
            PUSH_MARGV_LITERAL("-XX:G1NewSizePercent=30");
            PUSH_MARGV_LITERAL("-XX:G1MaxNewSizePercent=50");
            NSLog(@"[JavaLauncher] Task255 JVM preset=performance: G1GC throughput (pause=20, young 30..50)");
        } else {
            // G1GC：Java 9+ 默认 GC，显式启用确保一致性。
            // 适合大堆内存（MC 通常分配 2-4GB），减少 Full GC 停顿。
            PUSH_MARGV_LITERAL("-XX:+UseG1GC");
            // 目标 GC 停顿 50ms（默认 200ms）。
            // 这是一个软目标，JVM 会尽量满足但不强制，不会导致 OOM。
            // 对 MC 的实时渲染有益，减少 GC 引起的卡顿。
            PUSH_MARGV_LITERAL("-XX:MaxGCPauseMillis=50");
            // 字符串去重：G1GC 特性，自动去重老年代中相同值的 String 对象。
            // MC 有大量重复字符串（方块名、物品名、I18N key 等），可节省 5-10% 堆内存。
            // 仅在 G1GC 下生效，开销极小。
            PUSH_MARGV_LITERAL("-XX:+UseStringDeduplication");
            NSLog(@"[JavaLauncher] JVM GC optimization: G1GC + MaxGCPauseMillis=50 + StringDeduplication (Java 17+; preset=%@)", ame255_preset);
        }
    } else {
        // ★ Task255：Java 8 预设分流（G1 不可用档）。
        if ([ame255_preset isEqualToString:@"memory"]) {
            PUSH_MARGV_LITERAL("-XX:+UseSerialGC");
            NSLog(@"[JavaLauncher] Task255 JVM preset=memory (Java 8): SerialGC (smallest footprint)");
        } else if ([ame255_preset isEqualToString:@"performance"]) {
            PUSH_MARGV_LITERAL("-XX:+UseParallelGC");
            NSLog(@"[JavaLauncher] Task255 JVM preset=performance (Java 8): ParallelGC (max throughput)");
        } else {
            NSLog(@"[JavaLauncher] Java 8 detected, skipping G1GC tuning (using default GC; preset=%@)", ame255_preset);
        }
    }

    // Task223 上游同步（upstream 455c3f5a0 / Flux 同款，仅取 SoftRef 一项）：
    // 软引用宽限从每 MB 空闲堆 1 秒降到 250ms，让材质/模型缓存在内存压力下
    // 及时释放而不是 GC 空转（大整合包加载界面的生死线）。Java 8/17+ 通用，
    // 与 GC 选择无关。注：同提交的 -Xss1m 不移植——本文件下方的 -Xss32M 是
    // MC 26.3 RenderPearl→shaderc(glslang) 深递归打穿 1MB 栈的 SIGSEGV 根修
    // （构建 662d6e2 设备日志实证），压回 1m 会复现该崩溃。
    PUSH_MARGV_LITERAL("-XX:SoftRefLRUPolicyMSPerMB=250");

    // ============================================================================
    // Java 线程栈扩容 —— glslang / spirv-cross 深递归防护（MC 26.3）
    // ============================================================================
    // iOS OpenJDK 运行时会在我们的 argv 之后注入 -Xss1M（hs_err 的 flags 序列
    // 实证："-XX:-UseCompressedClassPointers -Xss1M -XX:StackShadowPages=32"，
    // 前两者由本文件推送，故 -Xss1M/StackShadowPages 来自 JRE 内部追加）。
    // JVM 主线程（= MC 的 Render thread）因此只有 1MB 原生栈。MC 26.3 的
    // RenderPearl 在游戏线程上直接调 shaderc（内含 glslang）编译 GLSL，深递归
    // 实测打穿 1MB 栈：SIGSEGV @ glslang::TParseContext::lValueErrorCheck+0x204
    // （构建 662d6e2 设备日志）。在此推大栈：
    //   - 若覆盖了运行时注入的 1M → 全部 Java 线程 32MB 栈，shaderc/spvc 一并安全
    //   - 若运行时注入仍在其后（1M 胜出）→ main_hook.m 的 shaderc 32MB 栈
    //     重定向兜底（独立于参数顺序，保证生效）
    // 32MB 取值对齐 MobileGlues 自身转换线程（设备日志原文 "dedicated 32MB-stack
    // thread"——同一批着色器、同一库家族在该预算下验证安全）。属虚拟内存预留，
    // 物理内存按实际触页计。
    PUSH_MARGV_LITERAL("-Xss32M");

    // ============================================================================
    // JVM fatal error log 定向 —— hs_err_pid*.log 落到可取位置（Task 27）
    // ============================================================================
    // JVM 收到 SIGSEGV/SIGILL 等致命信号时会写 hs_err 文件，默认落在进程 CWD——
    // iOS 上 CWD 不可控（可能只读或用户找不到），这是此前设备上"没有 hs_err
    // 报告"的原因之一。显式定向到 POJAV_HOME（启动器主目录），%p 由 JVM
    // 展开为 pid。与 main_hook.m 的 fatal_trace.txt（abort/exit 直写取证）
    // 互补：SIGSEGV 类死亡走 hs_err，exit/abort 类死亡走 fatal_trace。
    PUSH_MARGV_FORMAT(@"-XX:ErrorFile=%@/hs_err_pid%%p.log", @(getenv("POJAV_HOME")));

    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void* libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);

    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[Init] JLI lib = NULL: %s", error);
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), @(error));
        return 1;
    }

    // Setup Caciocavallo
    PUSH_MARGV_LITERAL("-Djava.awt.headless=false");
    PUSH_MARGV_LITERAL("-Dcacio.font.fontmanager=sun.awt.X11FontManager");
    PUSH_MARGV_LITERAL("-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler");
    PUSH_MARGV_FORMAT(@"-Dcacio.managed.screensize=%dx%d", width, height);
    PUSH_MARGV_LITERAL("-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel");
    if (isJava8) {
        // Setup Caciocavallo
        PUSH_MARGV_LITERAL("-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit");
        PUSH_MARGV_LITERAL("-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment");
    } else {
        // 启用 native access（Java 17+ 支持，Java 25 强制要求）。
        // 参照 catsruledogs/Amethyst-iOS-25：Java 25 对受限方法（@Restricted，含 JNI、
        // sun.misc.Unsafe、Foreign API）的限制更严格，缺失此参数会导致 caciocavallo/LWJGL/JNA
        // 的 native access 触发警告路径，在 bootclasspath/a 未命名模块类上可能引发
        // get_method_id 访问不一致的类元数据导致 SIGSEGV（26.2 启动崩溃的根因）。
        // 日志中 "WARNING: Use --enable-native-access=ALL-UNNAMED to avoid a warning"
        // 也明确提示需要此参数。Java 17/21 添加此参数无副作用，统一在非 Java 8 分支添加。
        // 关键修复（26.2 启动崩溃）：删除 --enable-native-access=ALL-UNNAMED（对齐 Ynnyny 仓库）
        // Ynnyny 仓库不添加此参数也能正常启动 26.2，证明之前的诊断（Java 25 必需）是错误的。
        // 该参数会改变未命名模块的受限方法警告路径，可能干扰 bootclasspath/a 上 caciocavallo
        // 类的初始化顺序。

        // Required by Cosmetica to inject DNS
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.net=ALL-UNNAMED");

        // ★ [FIX262]（Task201 随上游同步）java.base/java.lang 必须对未命名模块 open：
        //   metallum agent 用 defineClass 把 metallum 类集直接定义进 MC 的类加载器，
        //   走的是 ClassLoader#defineClass 反射 + setAccessible(true)。未命名模块下
        //   setAccessible 需要显式 opens，否则抛 InaccessibleObjectException:
        //     module java.base does not "opens java.lang" to unnamed module
        //   ⇒ defineMetallumClasses 整段失败，metallum 一个类都定义不上 ⇒ 26.2 起不来。
        //   （Forge 下 agent 是命名模块，另由 agent 侧 Instrumentation.redefineModule
        //     打开；这一条对两条路径都安全、无副作用。）
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.lang=ALL-UNNAMED");

        // Setup Caciocavallo
        PUSH_MARGV_LITERAL("-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit");
        PUSH_MARGV_LITERAL("-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment");

        // ★ Task230（反馈 #5：局域网联机首开闪退）：netty 官方开关，跳过原生
        // 传输（kqueue/epoll）的解包与加载。装机日志（39633e4 latestlog.old
        // 尾行）实锤首开 LAN 时 netty kqueue 原生库在重标签/重签窗口被
        // AMFI 击杀（SIGKILL、无崩溃报告）；第二次会话全程纯 Java
        // LocalIoHandler/NIO 联机正常 = 原生传输零收益。与 main_hook 侧
        // hooked_dlopen 的 netty_transport_native 拦截互为双保险。
        PUSH_MARGV_LITERAL("-Dio.netty.transport.noNative=true");

        // Required by Caciocavallo17 to access internal API
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.java2d=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.desktop/sun.font=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-exports=java.base/sun.security.action=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.util=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/java.awt=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/sun.font=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.desktop/sun.java2d=ALL-UNNAMED");
        PUSH_MARGV_LITERAL("--add-opens=java.base/java.lang.reflect=ALL-UNNAMED");
        // 参照 catsruledogs/Amethyst-iOS-25：不添加 sun.awt / sun.awt.image / java.awt.peer 的
        // add-opens。catsruledogs 不加这些 opens 也能正常启动 26.2 + Java 25。
        // workspace 之前多加这 3 条 opens 会导致 Java 25 上 GE 提前初始化，
        // 在 caciocavallo25 的 CTCGraphicsEnvironment 注册完成前触发 get_method_id → SIGSEGV。
        // 纯 Java 17 编译版 caciocavallo17（Java 17/21 用）不依赖这些 opens，
        // 其 CTCGraphicsEnvironment 通过 --add-exports（上方已添加）即可访问所需内部 API。

        // cpw.mods.bootstraplauncher 模块导出：所有 Java 版本均添加（参照 catsruledogs/Amethyst-iOS-25）。
        // 之前仅对 Java 17/21 添加、Java 25 跳过，导致 26.2 + Java 25 启动时类加载混乱，
        // 最终在 get_method_id 阶段 SIGSEGV。catsruledogs 对所有版本统一添加此导出且能正常启动 26.2。
        // TODO: workaround, will be removed once the startup part works without PLaunchApp
        PUSH_MARGV_LITERAL("--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED");
    }

    // Add Caciocavallo bootclasspath
    // 关键修复（26.2 启动崩溃）：caciocavallo 二元切换（对齐 Ynnyny 仓库）
    //
    // 之前 workspace 误判"纯 Java 17 编译版会在 Java 25 上 get_method_id SIGSEGV"，
    // 引入了 caciocavallo25（catsruledogs Java 24 class jar）三路切换。
    // 但 Ynnyny 仓库用纯 Java 17 编译版 caciocavallo17 启动 26.2 完全正常，
    // 证明该诊断是错误的。catsruledogs jar 的 Java 24 class 反而可能是真正的崩溃源。
    //
    // 现对齐 Ynnyny：二元切换
    //   - Java 8     → libs_caciocavallo（1.10-SNAPSHOT，bootclasspath/p）
    //   - Java 17/21/25 → libs_caciocavallo17（1.18-SNAPSHOT 纯 Java 17 编译，bootclasspath/a）
    const char *cacio_bootclasspath_mode;
    NSString *cacio_libs_path;
    if (isJava8) {
        // Java 8: 1.10-SNAPSHOT，bootclasspath/p（前置，覆盖 java.awt 实现）
        cacio_bootclasspath_mode = "p";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo", NSBundle.mainBundle.bundlePath];
    } else {
        // Java 17/21/25: 1.18-SNAPSHOT 纯 Java 17 编译（class version 61），bootclasspath/a
        cacio_bootclasspath_mode = "a";
        cacio_libs_path = [NSString stringWithFormat:@"%@/libs_caciocavallo17", NSBundle.mainBundle.bundlePath];
    }
    NSLog(@"[JavaLauncher] Caciocavallo: isJava8=%d libs=%@ mode=/%s",
          isJava8, cacio_libs_path.lastPathComponent, cacio_bootclasspath_mode);

    NSString *cacio_classpath = [NSString stringWithFormat:@"-Xbootclasspath/%s", cacio_bootclasspath_mode];
    NSArray *files = [fm contentsOfDirectoryAtPath:cacio_libs_path error:nil];
    for(NSString *file in files) {
        // 所有 cacio jar 均放入 -Xbootclasspath/a（或 /p for Java 8）。
        // 参照 catsruledogs/Amethyst-iOS-25：不使用 --patch-module，不使用 stub-surface-manager.jar。
        // 之前用 --patch-module 或 stub jar 注入 sun.java2d.SurfaceManagerFactory，
        // 会破坏 java.desktop 模块封装，导致 get_method_id SIGSEGV。
        if ([file hasSuffix:@".jar"]) {
            cacio_classpath = [NSString stringWithFormat:@"%@:%@/%@", cacio_classpath, cacio_libs_path, file];
        }
    }
    PUSH_MARGV_FORMAT(@"%@", cacio_classpath);

    // stub-surface-manager.jar 已删除（见上方注释）。不再使用 --patch-module。
    // CTCPreloadClassLoader.<clinit> 抛出的 ClassNotFoundException 被吞掉，不影响启动。

    // ★ Task286（PocketJ 对标移植）：iOS 27 拒绝 HotSpot 默认 1GiB
    //   compressed class space 预留——即使持有 extended-virtual-addressing
    //   entitlement 也可能在 Metaspace 初始化期失败（上游 PocketJ
    //   JavaLauncher.m 同款 workaround：majorVersion >= 27 无条件降级）。
    //   代价：klass 指针 64 位、Metaspace 略增，换 iOS 27 上 Java 17+ 的
    //   确定性可启动。
    BOOL ame286_ios27Plus = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27;
    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing") || ame286_ios27Plus) {
        // In jailed environment, where extended virtual addressing entitlement isn't
        // present (for free dev account), allocating compressed space fails.
        // FIXME: does extended VA allow allocating compressed class space?
        PUSH_MARGV_LITERAL("-XX:-UseCompressedClassPointers");
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        for (NSString *arg in launchTarget[@"arguments"][@"jvm_processed"]) {
            // arg 来自 launchTarget[@"arguments"][@"jvm_processed"] 数组，是 strong 引用；
            // 但 launchTarget 可能在循环结束后被释放，为防止悬垂，通过 PUSH_MARGV_FORMAT 持久化
            PUSH_MARGV_FORMAT(@"%@", arg);
        }
    }

    init_loadCustomJvmFlags(&margc, (const char **)margv);
    NSLog(@"[Init] Found JLI lib");

    // LWJGL 双版本：按 MC 版本选择 3.3.3 或 3.4.1（对齐 Ynnyny 仓库）
    //
    // 之前 workspace 用单一合并 lwjgl.jar；现按 LWJGL 版本拆分为
    //   app/libs/lwjgl-333/lwjgl.jar 与 app/libs/lwjgl-341/lwjgl.jar，
    // 由 ResolveLwjglVersion 在运行时选择其一。
    //
    // 两个 jar 在 JavaApp/Makefile 中均已合并定制版 root lwjgl.jar（含 iOS 专用
    // LWJGL 补丁 + LWJGL2 兼容类 org/lwjgl/opengl/Display 等），因此老版本 MC
    // （Java 8 / 1.12.2 及以下）不会因为换成 3.4.1 而失去 LWJGL2 API。
    //
    // MC 26.3 起窗口与输入从 GLFW 迁到 SDL3，必须使用 3.4.1 —— 它带真正的
    // lwjgl-sdl.jar（加载真实 libSDL3），是 SDL3 输入注入的前提。
    // MC 版本：优先用 launchTarget[@"id"]（实际启动的版本字典），
    // 其次回落到当前 profile 的 lastVersionId。
    // 注意 lastVersionId 可能是 "latest-release" 这类别名，直接拿来判断
    // 主版本号会失败，所以 NSDictionary 分支优先用 id。
    NSString *mcVersionId = nil;
    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        mcVersionId = [launchTarget[@"id"] description];
    } else if ([launchTarget isKindOfClass:NSString.class]) {
        mcVersionId = (NSString *)launchTarget;
    }
    if (mcVersionId.length == 0) {
        mcVersionId = [PLProfiles.current.selectedProfile[@"lastVersionId"] description];
    }
    NSString *lwjglVersion = ResolveLwjglVersion(
        [PLProfiles resolveKeyForCurrentProfile:@"lwjglVersion"], mcVersionId);
    NSLog(@"[JavaLauncher] Using LWJGL %@ (mcVersion=%@)", lwjglVersion, mcVersionId);
    PUSH_MARGV_FORMAT(@"-Dpojav.lwjgl.version=%@", lwjglVersion);

    NSString *lwjglDir = [NSString stringWithFormat:@"%@/lwjgl-%@", librariesPath, lwjglVersion];
    NSLog(@"[JavaLauncher] Using LWJGL jar at %@/lwjgl.jar", lwjglDir);

    // 校验目标 LWJGL 目录是否存在，避免静默崩溃。
    // 注意：lwjgl-<ver>/ 是目录，不能用带 "/*" 的 classpath 条目做存在性判断。
    BOOL lwjglDirIsDir = NO;
    if (![fm fileExistsAtPath:lwjglDir isDirectory:&lwjglDirIsDir] || !lwjglDirIsDir) {
        UIKit_returnToSplitView();
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:@"LWJGL jar missing: lwjgl-%@/lwjgl.jar", lwjglVersion]);
        return 1;
    }
    NSString *lwjglJar = [NSString stringWithFormat:@"%@/*", lwjglDir];

    // ---- Task 154：Forge split-package 隔离 v2（BootstrapLauncher ignoreList）----
    // 沿革：4894876 构建的 ResolutionException（"Module minecraft contains
    // package com.mojang.blaze3d.platform, module launcher exports ..."）由
    // launcher.jar 的 com/mojang/** 影子类（26.x 必需）+ BootstrapLauncher 把
    // classpath 上每个 jar 模块化引爆。Task153 曾把启动器侧 jar 整体移入
    // -Xbootclasspath/a —— split 消失，但 7c32bc3 装机日志（3b35b26 构建）
    // 实锤新崩：launcher.jar 里的 MinecraftAccount.<clinit> System.loadLibrary
    // ("AmethystAccountJNI") 改由 boot 加载器执行，其库搜索只覆盖
    // sun.boot.library.path（JDK lib 目录）→ "no AmethystAccountJNI in
    // system library path" 闪退（boot 加载器不搜 java.library.path）。
    // v2 正解（BootstrapLauncher 1.1.2 源码实证）：-DignoreList 按文件名
    // 前缀逗号分隔匹配，命中的 jar 不进 MC-BOOTSTRAP 模块层、留在传统
    // classpath 由父加载器解析。launcher.jar 进 ignoreList 后：无 "launcher"
    // 自动模块（split 根除）、类加载回到系统加载器（loadLibrary 搜
    // java.library.path=Frameworks，AmethystAccountJNI 复活）、com.mojang
    // 影子类经 ModuleClassLoader 的父委托链照常可达（与 Task153 同语义，
    // 但加载器正确）。注意：JSON 自带 -DignoreList 时必须【并入】而非
    // 覆盖（否则把 Forge 自己忽略的 jar 重新模块化）——下方原地改写。
    BOOL isForgeLaunch = NO;
    if (!launchJar && [launchTarget isKindOfClass:NSDictionary.class]) {
        NSString *ame153_mainClass = launchTarget[@"mainClass"];
        // 1.17+ Forge 与 1.20.1 NeoForge 的 mainClass 均为 BootstrapLauncher
        isForgeLaunch = ame153_mainClass.length > 0 &&
                        [ame153_mainClass containsString:@"cpw.mods.bootstraplauncher"];
    }

    // Task 154：注入 ignoreList（-D 同名后者生效——jvm_processed 在上方已
    // 推送，我们的条目排在其后必然胜出；JSON 自带时【并入】其值而非覆盖，
    // 防止把 Forge 自己忽略的 jar 重新模块化）。
    if (isForgeLaunch && [launchTarget isKindOfClass:NSDictionary.class]) {
        NSArray *ame154_jvmArgs = launchTarget[@"arguments"][@"jvm_processed"];
        NSString *ame154_ignore = @"asm,securejarhandler";   // BootstrapLauncher 1.1.2 默认值
        if ([ame154_jvmArgs isKindOfClass:NSArray.class]) {
            for (NSString *ame154_arg in ame154_jvmArgs) {
                if ([ame154_arg isKindOfClass:NSString.class] &&
                    [ame154_arg hasPrefix:@"-DignoreList="]) {
                    ame154_ignore = [ame154_arg substringFromIndex:13];
                    break;
                }
            }
        }
        if (![ame154_ignore containsString:@"launcher.jar"]) {
            ame154_ignore = [ame154_ignore stringByAppendingString:@",launcher.jar"];
        }
        PUSH_MARGV_FORMAT(@"-DignoreList=%@", ame154_ignore);
        NSLog(@"[JavaLauncher] Task154 Forge ignoreList shield: '%@' (launcher.jar stays on -cp -- system classloader keeps loadLibrary/search paths intact -- and is excluded from the BootstrapLauncher module layer; split package rooted without bootclasspath side effects)",
              ame154_ignore);
    }

    NSMutableString *classpathBuilder = [NSMutableString string];
    NSArray *libFiles = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    for (NSString *libFile in libFiles) {
        // 只收集 libs 下的 jar。lwjgl-333/ 与 lwjgl-341/ 是目录，不以 .jar 结尾，
        // 不会被误收；版本化 LWJGL 由下方的 lwjglJar 单独追加。
        // Task 154：启动器侧 jar 回归普通 -cp（Task153 的 bootclasspath 迁移
        // 撤销——boot 加载器劫持 System.loadLibrary 搜索路径，7c32bc3 的
        // AmethystAccountJNI 闪退即此）。launcher.jar 与 minecraft 的 split
        // package 由上方 ignoreList 注入根除。
        if (![libFile hasSuffix:@".jar"]) continue;
        [classpathBuilder appendFormat:@"%@/%@:", librariesPath, libFile];
    }
    [classpathBuilder appendString:lwjglJar];
    NSString *classpath = classpathBuilder;
    if (launchJar) {
        // JAR 放在 classpath 最前面，避免 bundle libs 中的同名类（gson/guava/kotlin-stdlib 等）
        // 优先加载，导致 installer 自带依赖被遮蔽引发 NoSuchMethodError/LinkageError
        // 标准 `java -jar` 语义下 JAR 本应是唯一 classpath，此处保留 bundle libs 仅因 PojavLauncher
        // 与 UIKit bridge 类需要加载，但 installer 自身依赖应优先
        classpath = [NSString stringWithFormat:@"%@:%@", launchTarget, classpath];
    }
    PUSH_MARGV_LITERAL("-cp");
    PUSH_MARGV_FORMAT(@"%@", classpath);
    PUSH_MARGV_LITERAL("net.kdt.pojavlaunch.PojavLauncher");

    if (launchJar) {
        PUSH_MARGV_LITERAL("-jar");
    } else {
        PUSH_MARGV_FORMAT(@"%@", accountId);
    }

    if ([launchTarget isKindOfClass:NSDictionary.class]) {
        PUSH_MARGV_FORMAT(@"%@", launchTarget[@"id"]);
        // 传递服务器地址给 PojavLauncher（FCL 风格）：
        // 留空传 @"", Java 端据此判断不追加任何参数；非空则由 Java 端按 MC 版本
        // 解析为 --server/--port 或 --quickPlayMultiplayer
        NSString *serverIp = [PLProfiles.current serverIpForCurrentProfile] ?: @"";
        PUSH_MARGV_FORMAT(@"%@", serverIp);
    } else {
        PUSH_MARGV_FORMAT(@"%@", launchTarget);
    }
    //PUSH_MARGV_LITERAL("ghidra.GhidraRun");

    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");

    if (NULL == pJLI_Launch) {
        NSLog(@"[Init] JLI_Launch = NULL");
        return -2;
    }

    // Task97：JLI_Launch 前对齐进程 CWD 到游戏目录（桌面启动器等价行为；详见
    // ame97_alignProcessCwdToGameDir 注释：2f90d13 两 mod 崩溃同源于
    // java.io[进程 CWD] 与 java.nio[user.dir] 的相对路径解析分裂）。
    ame97_alignProcessCwdToGameDir(gameDir);

    // Task99（修复 A）：JLI_Launch 前注册 AppKit 菜单桩。必须在 MC
    // Window.<init>（其内 MacosUtil 经 jna-objc 找 NSApplication）之前——
    // JVM 启动早期装好即可；幂等。iOS 无 AppKit，不装则 26.3 正式版
    // "Initializing game" 必崩（b919e0f 实锤）。
    ame99_installAppKitMenuStubs();
    // Task229: 1.20.1 loadIcon 路径的 NSImage/NSData 桩同批安装（详见 Task229 注释块）。
    ame229_installIconPathStubs();

    // ★ Task306：SIGKILL 级闪退感知——会话 marker 立桩（先感知残留：
    //   上次会话未走退出钩子即消失 = SIGKILL 级死亡，现场铸待读报告，
    //   下次冷启动 SceneDelegate 补弹链呈现；本次会话若同样被强杀，
    //   marker 残留即下次感知依据）。
    ame306_beginGameSessionMarker(NULL);

    NSLog(@"[Init] Calling JLI_Launch");

    // Cr4shed known issue: exit after crash dump,
    // reset signal handler so that JVM can catch them
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Free split VC
    tmpRootVC = nil;

    // 标记进程内 JVM 已创建（此后任何 JLI_Launch 都会崩溃，需重启 app）
    gJvmUsedInProcess = YES;

    // ★ Task251（反馈 2 四修）：游戏会话专属——arm 退出挂死双保险（标记
    //   轮询看门狗 + libjvm exit 二次 rebind 线程）。必须在 pJLI_Launch 前：
    //   本调用会阻塞到 JVM 终结，之后无人能 arm。headless 安装器路径
    //   （launchHeadlessJVM）不经过此处，Task144 抑制语义零回归。
    ame251_armShutdownForceExitWatchdog();

    return pJLI_Launch(++margc, margv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   // These values are ignored in Java 17, so keep it anyways
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
}

// ============================================================================
// Headless JVM（Forge/NeoForge 直装 processors 执行）
// ============================================================================
// 参照 launchJVM 的环境初始化与 JIT 前置，但 JVM 参数最小化：
// - 无 caciocavallo / LWJGL / 渲染相关参数
// - -Djava.awt.headless=true（processor 不需要图形环境）
// - -cp 仅含 bundle libs（launcher.jar 内含 ForgeProcessorRunner，gson 等依赖也在其中）
//
// iOS 禁止 fork/exec，无法像 ZL2 那样为每个 processor spawn 子 JVM，
// 但官方 Forge/NeoForge installer 本身就是在单个 JVM 内以 IsolatedClassLoader
// 逐个执行 processor 的（ForgeProcessorRunner 复刻该行为）。
//
// 注意：调用后进程内 JVM 已创建，游戏启动必须重启 app（见 gJvmUsedInProcess）。
int launchHeadlessJVM(NSString *mainClass, NSArray<NSString *> *args, int minJavaVersion) {
    NSLog(@"[JavaLauncher] Beginning headless JVM launch: %@ (minJava=%d)", mainClass, minJavaVersion);

    if (!mainClass.length) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: mainClass is empty");
        return -6;
    }

    // 进程内 JVM 只能创建一次
    if (gJvmUsedInProcess) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: JVM already created in this process, restart required");
        return -5;
    }

    // Task 139：JIT 前置检查升级为【自动申请 + 等待】。
    //
    // 病历：旧实现只在 JIT 未开启时报错弹窗让用户手动去开（"安装 Forge 时
    // 要求开启 JIT"的用户抱怨）；而且 iOS>26 的 TXM 设备上即使 CS_DEBUGGED
    // 已置位，JIT26 调试器通常早已离场，直接跑 processor 会在
    // JIT26CreateRegionLegacy 的 brk #0x69 上必崩（RightPanel 启动按钮的
    // 再附逻辑就是为这个写的，headless 路径漏了同款处理）。
    //
    // 现在与游戏启动链同构：
    //   (1) JIT 未开启 → 按 debug.jit_enabler 偏好自动跳转申请
    //       （TrollStore/SideStore/StosDebug/JITStreamer/StikDebug/auto 按
    //       版本判定；manual 保持旧行为报错），弹等待框轮询 isJITEnabled，
    //       开启后继续；debug_skip_wait_jit 尊重旧语义直接放行。
    //   (2) JIT 已开启 + TXM 设备 + 无活跃 JIT26 调试器 → stikjit:// 带
    //       script-data 再附（jit26_script_disable 关闭时不带脚本），
    //       轮询 JIT26IsLikelyDebuggerKeepAttached。
    if (!isJITEnabled(NO)) {
        if (getPrefBool(@"debug.debug_skip_wait_jit")) {
            NSLog(@"[JavaLauncher] launchHeadlessJVM: debug_skip_wait_jit set, proceeding without JIT");
        } else {
            NSLog(@"[JavaLauncher] launchHeadlessJVM: Task139 JIT not enabled -- auto-requesting via configured enabler");
            dispatch_sync(dispatch_get_main_queue(), ^{
                NSString *ame139_enabler = getPrefObject(@"debug.jit_enabler");
                if (![ame139_enabler isKindOfClass:NSString.class] || ame139_enabler.length == 0) {
                    ame139_enabler = @"auto";
                }
                BOOL ame139_noScript = getPrefBool(@"debug.jit26_script_disable");
                NSString *ame139_bundleId = NSBundle.mainBundle.bundleIdentifier;
                // Task294：与 RightPanel Task134 同口径——builtin 显式选项 +
                // auto 非巨魔环境内置轨可用时优先；显式 builtin 失败不擅自跳
                // 第三方工具（仅报错），auto 失败降级 stikjit:// 深链继续等。
                BOOL ame294_isTrollStore = getEntitlementValue(@"jb.pmap_cs.custom_trust") && isTrollStoreInstall();
                BOOL ame294_builtinAvail = [StikDebugViewController ame294_builtinTrackAvailable];
                BOOL ame294_useBuiltin = NO;
                if ([ame139_enabler isEqualToString:@"builtin"]) {
                    ame294_useBuiltin = YES;
                } else if ([ame139_enabler isEqualToString:@"auto"] && !ame294_isTrollStore) {
                    ame294_useBuiltin = ame294_builtinAvail;
                }
                NSLog(@"[JIT] [Headless] Task139 enabler=%@ noScript=%d builtin=%d (avail=%d ts=%d)",
                      ame139_enabler, ame139_noScript, ame294_useBuiltin, ame294_builtinAvail, ame294_isTrollStore);
                NSURL *ame139_url = nil;
                if (ame294_useBuiltin) {
                    // Task294：内置轨（PocketJ +enableEmbeddedJIT 同构）。等待环
                    // 不变——内置轨成功后 isJITEnabled 轮询即继续主流程。
                    [StikDebugViewController ame294_enableBuiltinJITWithCompletion:^(BOOL success, NSString *message) {
                        if (success || isJITEnabled(YES)) {
                            NSLog(@"[JIT] [Headless] Task294 builtin track OK");
                            return;
                        }
                        NSLog(@"[JIT] [Headless] Task294 builtin track failed: %@", message);
                        NSString *detail = message.length ? message : localize(@"ame293.jit.builtin_fail_title", nil);
                        if ([detail localizedCaseInsensitiveContainsString:@"Timed out connecting"] ||
                            [detail localizedCaseInsensitiveContainsString:@"not ready for JIT"]) {
                            detail = [detail stringByAppendingFormat:@"\n\n%@", localize(@"ame294.jit.localdevvpn_hint", nil)];
                        }
                        if ([ame139_enabler isEqualToString:@"builtin"]) {
                            // 显式 builtin：报错不跳第三方（等环可取消/超时）
                            showDialog(localize(@"ame293.jit.builtin_fail_title", nil), detail);
                        } else if (@available(iOS 17.4, *)) {
                            // auto：降级 stikjit:// 深链，等待环继续轮询
                            NSString *sd = @"";
                            if (!ame139_noScript) {
                                NSData *s = [NSData dataWithContentsOfFile:
                                    [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                                if (s) sd = [@"&script-data=" stringByAppendingString:[s base64EncodedStringWithOptions:0]];
                            }
                            [UIApplication.sharedApplication openURL:[NSURL URLWithString:
                                [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", ame139_bundleId, getpid(), sd]]
                                options:@{} completionHandler:nil];
                        }
                    }];
                } else if ([ame139_enabler isEqualToString:@"trollstore"]) {
                    ame139_url = [NSURL URLWithString:[NSString stringWithFormat:
                        @"apple-magnifier://enable-jit?bundle-id=%@", ame139_bundleId]];
                } else if ([ame139_enabler isEqualToString:@"sidestore"]) {
                    ame139_url = [NSURL URLWithString:[NSString stringWithFormat:
                        @"sidestore://enable-jit?bundle-id=%@", ame139_bundleId]];
                } else if ([ame139_enabler isEqualToString:@"stosdebug"]) {
                    NSString *ame139_appName = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: @"Amethyst";
                    NSMutableString *ame139_u = [NSMutableString stringWithFormat:
                        @"stosdebug://enableJIT?bundleId=%@&appName=%@", ame139_bundleId, ame139_appName];
                    if (!ame139_noScript) {
                        NSData *ame139_script = [NSData dataWithContentsOfFile:
                            [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                        if (ame139_script) {
                            [ame139_u appendFormat:@"&script=%@", [ame139_script base64EncodedStringWithOptions:0]];
                        }
                    }
                    ame139_url = [NSURL URLWithString:ame139_u];
                } else if ([ame139_enabler isEqualToString:@"jitstreamer"]) {
                    ame139_url = [NSURL URLWithString:[NSString stringWithFormat:
                        @"http://[fd00::]:9172/launch_app/%@", ame139_bundleId]];
                } else if ([ame139_enabler isEqualToString:@"manual"]) {
                    // 手动模式：不跳转（维持旧语义），仅弹窗告知
                } else if (@available(iOS 17.4, *)) {
                    // auto / stikjit 共用 stikjit://
                    NSString *ame139_scriptData = @"";
                    if (!ame139_noScript) {
                        NSData *ame139_script = [NSData dataWithContentsOfFile:
                            [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
                        if (ame139_script) {
                            ame139_scriptData = [@"&script-data=" stringByAppendingString:[ame139_script base64EncodedStringWithOptions:0]];
                        }
                    }
                    ame139_url = [NSURL URLWithString:[NSString stringWithFormat:
                        @"stikjit://enable-jit?bundle-id=%@&pid=%d%@", ame139_bundleId, getpid(), ame139_scriptData]];
                } else {
                    ame139_url = [NSURL URLWithString:[NSString stringWithFormat:
                        @"sidestore://sidejit-enable?pid=%d", getpid()]];
                }
                if (ame139_url) {
                    [UIApplication.sharedApplication openURL:ame139_url options:@{} completionHandler:nil];
                }
                showDialog(localize(@"i18n_str_437", nil), localize(@"i18n_str_439", nil));
            });
            // 后台轮询等待 JIT 生效（与 RightPanel 同款节奏；manual 模式下
            // 用户手动附加后同样能继续）
            // ★ Task275（P2-a3）：无界裸循环改有界等待（Task169/267 修的另外三处，
            //   此处漏网）——stikjit 未驻留时 Forge/NeoForge 安装线程永久空转，
            //   "正在开启 JIT"弹窗永远挂着且 cancel 点了也退不出。120s 超时
            //   走下方既有失败口径（优雅 -1 返回）。
            if (!ame169_waitForJITCondition(^{ return isJITEnabled(NO); }, 120.0, @"Headless-JIT")) {
                NSLog(@"[JavaLauncher] launchHeadlessJVM: Task275 JIT wait timed out (120s) -- failing gracefully");
                return -1;
            }
            NSLog(@"[JavaLauncher] launchHeadlessJVM: Task139 JIT became enabled, continuing");
        }
    }

    init_loadDefaultEnv();
    init_loadCustomEnv();

    DeviceGetJITFlags(YES);
    BOOL requiresTXMWorkaround = DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM);
    BOOL jit26AlwaysAttached = getPrefBool(@"debug.debug_always_attached_jit");
    // Same fix as launchJVM: force the debugger to stay attached on TXM
    // devices so the dyld bypass's brk #0xf00d is serviced (must happen
    // before JIT26SetDetachAfterFirstBr).
    if (requiresTXMWorkaround && !jit26AlwaysAttached) {
        NSLog(@"[DyldLVBypass] TXM debug JIT mapping active — keeping debugger attached for dyld bypass");
        jit26AlwaysAttached = YES;
    }
    // Task 139：TXM 再附（与 RightPanel 启动链同构）。CS_DEBUGGED 只证明
    // JIT 曾为本进程开启过；iOS>26 上 JIT26 调试器通常早已离场，下方
    // JIT26CreateRegionLegacySafe 的 brk #0x69 无人应答 = 必然优雅失败。
    // 在那之前：无活跃调试器且脚本未禁用时，先 stikjit:// 带 script-data
    // 再附并等待（用户诉求：">26 系统不管有没有开启都自动申请 JIT"）。
    if (requiresTXMWorkaround &&
        !JIT26IsLikelyDebuggerKeepAttached() &&
        // Task294：本会话内置轨祝福完成（祝福完即脱）不再附——headless 与
        // RightPanel 同口径，不把用户拖回外部 StikDebug。
        ![StikDebugViewController ame294_scriptCompletedThisSession] &&
        !getPrefBool(@"debug.jit26_script_disable")) {
        NSLog(@"[JIT] [Headless] Task139: CS_DEBUGGED set but no live JIT26 debugger (ppid=%d) — re-attaching script via stikjit://",
              getppid());
        dispatch_sync(dispatch_get_main_queue(), ^{
            NSString *ame139_scriptData = @"";
            NSData *ame139_script = [NSData dataWithContentsOfFile:
                [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            if (ame139_script) {
                ame139_scriptData = [@"&script-data=" stringByAppendingString:[ame139_script base64EncodedStringWithOptions:0]];
            }
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:
                [NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@",
                    NSBundle.mainBundle.bundleIdentifier, getpid(), ame139_scriptData]]
                options:@{} completionHandler:nil];
            showDialog(localize(@"i18n_str_437", nil), localize(@"i18n_str_439", nil));
        });
        // ★ Task275（P2-a3）：同上，有界等待替代无界裸循环。
        if (!ame169_waitForJITCondition(^{ return JIT26IsLikelyDebuggerKeepAttached(); }, 120.0, @"Headless-JIT26")) {
            NSLog(@"[JavaLauncher] launchHeadlessJVM: Task275 JIT26 attach wait timed out (120s) -- failing gracefully");
            return -1;
        }
        NSLog(@"[JIT] [Headless] Task139: JIT26 debugger re-attached, continuing");
    }
    if (requiresTXMWorkaround) {
        static void *result;
        // Task91：同 launchJVM，SIGTRAP 安全网——无应答时优雅报错而非闪退
        // ★ Task301：同 launchJVM 换有界看门狗（死调试器端口下 brk 永久
        // mach_msg 阻塞，SIGTRAP 安全网收不到；超时自动跑内置轨后收尾）。
        if (!result) result = ame301_createRegionWithWatchdog();
        if (!result) {
            NSLog(@"[JIT26] [Headless] JIT26CreateRegionLegacy returned NULL — JIT26 debugger not servicing brk; aborting gracefully");
            showDialog(localize(@"Error", nil), localize(@"i18n_str_jit26_not_ready", nil));
            return -1;
        }
        if ((uint32_t)result != 0x690000E0) {
            munmap(result, getpagesize());
            NSString *inBundleScriptPath = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];            NSString *lcAppInfoPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"];
            NSMutableDictionary *lcAppInfo = [NSMutableDictionary dictionaryWithContentsOfFile:lcAppInfoPath];
            if (lcAppInfo) {
                lcAppInfo[@"jitLaunchScriptJs"] = [[NSData dataWithContentsOfFile:inBundleScriptPath] base64EncodedStringWithOptions:0];
                if ([lcAppInfo writeToFile:lcAppInfoPath atomically:YES]) {
                    showDialog(localize(@"Error", nil), localize(@"ame267.jit.legacy_lc", @"Prisma was launched with a legacy JIT script. It has been updated to the Universal script automatically, please restart LiveContainer to continue."));
                    return -1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), localize(@"ame267.jit.legacy_stik", @"Support for legacy JIT scripts has been removed, please switch to the Universal JIT script. Current StikDebug builds auto-assign the script by app name (older sideloaded builds bundled the same script as Amethyst-MeloNX.js), so updating StikDebug is the easiest fix. To assign manually: long-press on the launcher app when enabling JIT in StikDebug, tap \"Assign Script\", then pick UniversalJIT26.js from the launcher's Documents directory (exported automatically at every startup)."));
            return -1;
        }
        // 关键修复（N5）：同 launchJVM，防止 nil 脚本崩溃
        NSError *headlessScriptError = nil;
        NSString *extensionScript = [NSString stringWithContentsOfFile:[NSBundle.mainBundle pathForResource:@"UniversalJIT26Extension" ofType:@"js"] encoding:NSUTF8StringEncoding error:&headlessScriptError];
        if (extensionScript) {
            JIT26SendJITScript(extensionScript);
            JIT26SetDetachAfterFirstBr(!jit26AlwaysAttached);
        } else {
            NSLog(@"[JavaLauncher] ERROR: Failed to load UniversalJIT26Extension.js (headless): %@", headlessScriptError.localizedDescription);
        }
        task_set_exception_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, 0, EXCEPTION_DEFAULT, MACHINE_THREAD_STATE);
    }

    if (jit26AlwaysAttached) {
        task_set_exception_ports(mach_task_self(), EXC_MASK_ALL & ~EXC_MASK_BREAKPOINT, 0,
            EXCEPTION_DEFAULT, THREAD_STATE_NONE);
    }
    // Always activate Library Validation bypass (see launchJVM for rationale).
    init_bypassDyldLibValidation();

    // JRE 选择：按 minJavaVersion 推断 runtime tag（≥25 用 1_26_newer，≥17 用
    // 1_17_newer，否则 1_16_5_older，Task159 对齐 launchJVM 三档分界），
    // 失败回退 execute_jar。getSelectedJavaHome 内部会在 tag 槽位不满足 minVersion 时
    // 搜索任意满足版本要求的 runtime。
    NSString *defaultJRETag = (minJavaVersion >= 25) ? @"1_26_newer"
                            : ((minJavaVersion >= 17) ? @"1_17_newer" : @"1_16_5_older");
    NSString *javaHome = getSelectedJavaHome(defaultJRETag, minJavaVersion);
    if (javaHome == nil) {
        javaHome = getSelectedJavaHome(@"execute_jar", minJavaVersion);
    }
    if (javaHome == nil) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: no Java runtime >= %d available", minJavaVersion);
        showDialog(localize(@"Error", nil), [NSString stringWithFormat:localize(@"java.error.missing_runtime", nil),
            @"Forge/NeoForge installer", minJavaVersion]);
        return -3;
    }
    setenv("JAVA_HOME", javaHome.UTF8String, 1);
    NSLog(@"[JavaLauncher] Headless JAVA_HOME set to %@", javaHome);

    // user.home 指向独立临时目录，避免 processor 向主目录写入缓存
    NSString *gameDir = @(getenv("POJAV_GAME_DIR"));
    NSString *procHome = [gameDir stringByAppendingPathComponent:@".temp/forge_processor_home"];
    [[NSFileManager defaultManager] createDirectoryAtPath:procHome
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];

    // dlopen libjli（Java 8 与 Java 11+ 双路径，对齐 launchJVM）
    NSString *libjlipath8 = [NSString stringWithFormat:@"%@/lib/jli/libjli.dylib", javaHome];
    NSString *libjlipath11 = [NSString stringWithFormat:@"%@/lib/libjli.dylib", javaHome];
    BOOL isJava8 = [fm fileExistsAtPath:libjlipath8];
    setenv("INTERNAL_JLI_PATH", (isJava8 ? libjlipath8 : libjlipath11).UTF8String, 1);
    void *libjli = dlopen(getenv("INTERNAL_JLI_PATH"), RTLD_GLOBAL);
    if (!libjli) {
        const char *error = dlerror();
        NSLog(@"[JavaLauncher] launchHeadlessJVM: JLI lib = NULL: %s", error ?: "unknown");
        return -4;
    }
    pJLI_Launch = (JLI_Launch_func *)dlsym(libjli, "JLI_Launch");
    if (pJLI_Launch == NULL) {
        NSLog(@"[JavaLauncher] launchHeadlessJVM: JLI_Launch = NULL");
        return -2;
    }

    // 构造最小化 JVM 参数
    int margc = -1;
    const char *margv[256];
    NSMutableArray<NSString *> *retainedStrings = [NSMutableArray array];

    #define PUSH_HARGV_LITERAL(literal) do { \
        if (margc + 1 < 256) { \
            margv[++margc] = (literal); \
        } else { \
            NSLog(@"[JavaLauncher] launchHeadlessJVM: margv limit reached, discarding %s", (literal)); \
        } \
    } while (0)

    #define PUSH_HARGV_FORMAT(ns_fmt, ...) do { \
        if (margc + 1 < 256) { \
            NSString *_tmpStr = [NSString stringWithFormat:(ns_fmt), ##__VA_ARGS__]; \
            [retainedStrings addObject:_tmpStr]; \
            margv[++margc] = _tmpStr.UTF8String; \
        } else { \
            NSLog(@"[JavaLauncher] launchHeadlessJVM: margv limit reached, discarding formatted argument"); \
        } \
    } while (0)

    PUSH_HARGV_FORMAT(@"%@/bin/java", javaHome);
    PUSH_HARGV_LITERAL("-XstartOnFirstThread");
    // headless：无 AWT/Swing 图形环境
    PUSH_HARGV_LITERAL("-Djava.awt.headless=true");
    PUSH_HARGV_LITERAL("-Xms64M");
    PUSH_HARGV_LITERAL("-Xmx1G");
    PUSH_HARGV_FORMAT(@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath);
    PUSH_HARGV_FORMAT(@"-Duser.dir=%@", gameDir);
    PUSH_HARGV_FORMAT(@"-Duser.home=%@", procHome);
    PUSH_HARGV_FORMAT(@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name);
    PUSH_HARGV_LITERAL("-Dlog4j2.formatMsgNoLookups=true");
    // Workaround random stack guard allocation crashes（对齐 launchJVM）
    PUSH_HARGV_LITERAL("-XX:+UnlockExperimentalVMOptions");
    PUSH_HARGV_LITERAL("-XX:+DisablePrimordialThreadGuardPages");
    // CodeCache 参数（对齐 launchJVM Task284 分轨 + Task285 镜像轨 Initial
    // 一次到位：iOS 26+ 镜像映射 64m 硬边界防 SIGBUS；iOS < 26 非镜像路
    // 径 256m 防 CodeCache 满退化）
    if (@available(iOS 26.0, *)) {
        PUSH_HARGV_LITERAL("-XX:ReservedCodeCacheSize=64m");
        PUSH_HARGV_LITERAL("-XX:InitialCodeCacheSize=48m");
        PUSH_HARGV_LITERAL("-XX:CodeCacheExpansionSize=8m");
    } else {
        PUSH_HARGV_LITERAL("-XX:ReservedCodeCacheSize=256m");
        PUSH_HARGV_LITERAL("-XX:InitialCodeCacheSize=32m");
        PUSH_HARGV_LITERAL("-XX:CodeCacheExpansionSize=8m");
    }
    if (@available(iOS 26.0, *)) {
        PUSH_HARGV_LITERAL("-XX:+MirrorMappedCodeCache");
    }
    // ★ Task286：iOS 27 compressed class space 兼容（launchJVM 同款，见彼处
    //   注释）——装机 processors 会话同受 iOS 27 1GiB 类空间预留拒绝影响。
    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")
        || NSProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27) {
        PUSH_HARGV_LITERAL("-XX:-UseCompressedClassPointers");
    }

    // classpath：bundle libs 下全部 jar（launcher.jar 含 ForgeProcessorRunner，gson 等也在其中）
    // + 版本化 LWJGL 目录（lwjgl-333/ 或 lwjgl-341/）
    NSString *librariesPath = [NSString stringWithFormat:@"%@/libs", NSBundle.mainBundle.bundlePath];
    NSMutableString *classpathBuilder = [NSMutableString string];
    NSArray *libFiles = [fm contentsOfDirectoryAtPath:librariesPath error:nil];
    for (NSString *libFile in libFiles) {
        // lwjgl-333/ 与 lwjgl-341/ 是目录，不以 .jar 结尾，不会被误收，
        // 由下方按解析出的版本单独追加。
        if ([libFile hasSuffix:@".jar"]) {
            [classpathBuilder appendFormat:@"%@/%@:", librariesPath, libFile];
        }
    }
    // headless JVM 用于 Forge/NeoForge 安装期的 processors，不运行 MC 本体，
    // 但仍可能引用 LWJGL 类。这里按当前 profile 解析版本并追加对应目录。
    NSString *headlessLwjglVersion = ResolveLwjglVersion(
        [PLProfiles resolveKeyForCurrentProfile:@"lwjglVersion"],
        PLProfiles.current.selectedProfile[@"lastVersionId"]);
    [classpathBuilder appendFormat:@"%@/lwjgl-%@/*:", librariesPath, headlessLwjglVersion];
    NSLog(@"[JavaLauncher] headless JVM using LWJGL %@", headlessLwjglVersion);
    if (classpathBuilder.length > 0 && [classpathBuilder hasSuffix:@":"]) {
        [classpathBuilder deleteCharactersInRange:NSMakeRange(classpathBuilder.length - 1, 1)];
    }
    PUSH_HARGV_LITERAL("-cp");
    PUSH_HARGV_FORMAT(@"%@", classpathBuilder);

    // main class 与其参数
    PUSH_HARGV_FORMAT(@"%@", mainClass);
    for (NSString *arg in args) {
        if (margc + 1 < 256) {
            [retainedStrings addObject:arg];
            margv[++margc] = arg.UTF8String;
        } else {
            NSLog(@"[JavaLauncher] launchHeadlessJVM: margv limit reached, discarding extra argument");
        }
    }

    // Cr4shed known issue（对齐 launchJVM）：重置信号处理器让 JVM 能捕获崩溃信号
    signal(SIGSEGV, SIG_DFL);
    signal(SIGPIPE, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);

    // Task97：headless 路径同样对齐 CWD（Forge/NeoForge 安装期 processors 与
    // 主游戏共用 -Duser.dir=<gameDir> 语义，桌面端安装器也总以 CWD == 游戏目录运行）。
    ame97_alignProcessCwdToGameDir(gameDir);

    NSLog(@"[JavaLauncher] Calling JLI_Launch (headless, %d args)", margc + 1);

    // 标记进程内 JVM 已创建（此后任何 JLI_Launch 都会崩溃，需重启 app）
    gJvmUsedInProcess = YES;

    int ret = pJLI_Launch(++margc, margv,
                   0, NULL,
                   0, NULL,
                   "1.8.0-internal",
                   "1.8",
                   "java", "openjdk",
                   JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
    NSLog(@"[JavaLauncher] Headless JLI_Launch returned %d", ret);
    return ret;
}
