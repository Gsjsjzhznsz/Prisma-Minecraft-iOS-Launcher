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
    //   实际运行的 MoltenVK 版本为 1.4.3（Task246：上游 main @ 2c28e0c8
    //   2026-10-09 CI 构建，从 libMoltenVK.dylib 二进制 strings 确认；
    //   历史链 1.2.9 → 1.4.2 → 1.4.3，本次领先 v1.4.2 release 54 提交）。
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
    NSLog(@"[JavaLauncher] Framerate unlock configuration:");
    NSLog(@"[JavaLauncher]   video.disable_game_vsync=%d", getPrefBool(@"video.disable_game_vsync"));
    NSLog(@"[JavaLauncher]   POJAV_DISABLE_VSYNC=%s", getenv("POJAV_DISABLE_VSYNC"));
    NSLog(@"[JavaLauncher]   UIScreen.maximumFramesPerSecond=%d", (int)UIScreen.mainScreen.maximumFramesPerSecond);
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

void init_loadCustomJvmFlags(int* argc, const char** argv) {
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
    static NSMutableArray<NSString *> *retainedCustomFlags = nil;
    if (retainedCustomFlags == nil) {
        retainedCustomFlags = [NSMutableArray array];
    }
    // 注意：不清空 retainedCustomFlags，因为 launchJava 在进程生命周期内只调用一次。
    // 如果未来变为可多次调用，需要在调用前清空。

    NSLog(@"[JavaLauncher] Reading custom JVM flags");
    NSArray *argsToPurge = @[@"Xms", @"Xmx", @"d32", @"d64"];
    for (NSString *arg in [jvmargs componentsSeparatedByString:@" -"]) {
        NSString *jvmarg = [arg stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (jvmarg.length == 0) continue;
        BOOL ignore = NO;
        for (NSString *argToPurge in argsToPurge) {
            if ([jvmarg hasPrefix:argToPurge]) {
                NSLog(@"[JavaLauncher] Ignored JVM flag: -%@", jvmarg);
                ignore = YES;
                break;
            }
        }
        if (ignore) continue;

        // N3 边界检查：argv 数组大小由调用方决定（margv[1000]），这里做防御性检查
        if (*argc + 1 >= 1000) {
            NSLog(@"[JavaLauncher] Warning: margv reached limit (1000), discarding custom JVM flag: -%@", jvmarg);
            continue;
        }
        NSString *flagStr = [@"-" stringByAppendingString:jvmarg];
        [retainedCustomFlags addObject:flagStr];
        ++*argc;
        argv[*argc] = flagStr.UTF8String;

        NSLog(@"[JavaLauncher] Added custom JVM flag: %s", argv[*argc]);
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
    NSArray<NSString *> *chain = (minVersion > 8)
        ? @[@ RENDERER_NAME_MOBILEGL, @ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE]
        : @[@ RENDERER_NAME_GL4ESZL2, @ RENDERER_NAME_MTL_ANGLE, @ RENDERER_NAME_MOBILEGL];
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
            : @"legacy MC baseline (Task173/212: ZL2 classic gl4es)";
        break;
    }
    if (!picked) {
        picked = chain.firstObject;
        reason = @"all candidates unavailable/blacklisted -- availability fallback to chain head";
    }
    NSLog(@"[JavaLauncher] Task217: auto renderer decision: minVersion=%ld chain=%@ blacklist=%@ -> %@ (%@)",
          (long)minVersion, chain, hasBlacklist ? blacklist : @"(none)", picked, reason);
    return picked;
}

// ==================== Task 217 结束 ====================

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
        static void *result;
        // Task91：SIGTRAP 安全网——brk 无应答（JIT26 调试器未就绪/脚本未挂载）
        // 时原裸函数直接 SIGTRAP 致死（用户实测"开启 JIT 后闪退"），改走优雅报错
        if(!result) result = JIT26CreateRegionLegacySafe(getpagesize());
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
                    showDialog(localize(@"Error", nil), @"Amethyst was launched with a legacy script. We have updated the script to Universal, please restart LiveContainer to continue.");
                    [PLLogOutputView handleExitCode:1];
                    return 1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to the Universal JIT script. On current StikDebug builds it is auto-assigned to Amethyst by app name (older sideloaded builds bundled the same script as Amethyst-MeloNX.js), so updating StikDebug is the easiest fix. To assign it manually: long-press on Amethyst when enabling JIT in StikDebug, tap \"Assign Script\", then pick UniversalJIT26.js from Amethyst's Documents directory (exported automatically at every startup).");
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
        if (![renderer isEqualToString:profileRenderer]) {
            NSLog(@"[Amethyst] Task120: MobileGL backend override active (profile renderer was %@ -> %@)",
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
            [ZinkConfig applyZinkEnvironmentFromPreferences];
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
        gameDir = [NSString stringWithFormat:@"%s/instances/%@/%@",
            getenv("POJAV_HOME"), getPrefObject(@"general.game_directory"),
            [PLProfiles resolveKeyForCurrentProfile:@"gameDir"]]
            .stringByStandardizingPath;

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

        // Task 87：桌面弹窗类 mod 预检（病历见 ame87_disableDesktopDialogMods 函数头）
        // ——实证案犯自动禁用（改名 .jar.disabled），Fabric 忽略非 .jar 文件。
        int ame87_disabledDialogMods = ame87_disableDesktopDialogMods(gameDir);
        if (ame87_disabledDialogMods > 0) {
            NSLog(@"[ModDialogGuard] Task87: %d desktop dialog mod(s) auto-disabled in %@/mods (rename .disabled -> .jar to restore)", ame87_disabledDialogMods, gameDir.lastPathComponent);
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
    PUSH_MARGV_LITERAL("-Xms128M");
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
        NSLog(@"[Amethyst] Task112: OpenAL pinned to %@", task112OpenalPin);
    } else {
        NSLog(@"[Amethyst] Task112: libopenal.dylib not found, OpenAL left to LWJGL default resolution");
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
    PUSH_MARGV_LITERAL("-XX:ReservedCodeCacheSize=64m");
    PUSH_MARGV_LITERAL("-XX:InitialCodeCacheSize=16m");
    PUSH_MARGV_LITERAL("-XX:CodeCacheExpansionSize=4m");

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
    // 仅对 Java 17+ 启用 G1GC 调优。Java 8 的 G1GC 不够成熟，保持默认 SerialGC。
    // 不添加 -XX:+AlwaysPreTouch（延长启动时间）、-XX:TieredStopAtLevel=1（降低 JIT 性能）、
    // -XX:CICompilerCount=1（减少编译线程）等可能影响游戏体验的参数。
    // -XX:+UnlockExperimentalVMOptions 已在上方添加，UseStringDeduplication 需要实验模式。
    if (!isJava8) {
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
        NSLog(@"[JavaLauncher] JVM GC optimization: G1GC + MaxGCPauseMillis=50 + StringDeduplication (Java 17+)");
    } else {
        NSLog(@"[JavaLauncher] Java 8 detected, skipping G1GC tuning (using default GC)");
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

    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
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
                NSLog(@"[JIT] [Headless] Task139 enabler=%@ noScript=%d", ame139_enabler, ame139_noScript);
                NSURL *ame139_url = nil;
                if ([ame139_enabler isEqualToString:@"trollstore"]) {
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
            while (!isJITEnabled(NO)) {
                usleep(1000 * 200);
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
        while (!JIT26IsLikelyDebuggerKeepAttached()) {
            usleep(1000 * 200);
        }
        NSLog(@"[JIT] [Headless] Task139: JIT26 debugger re-attached, continuing");
    }
    if (requiresTXMWorkaround) {
        static void *result;
        // Task91：同 launchJVM，SIGTRAP 安全网——无应答时优雅报错而非闪退
        if (!result) result = JIT26CreateRegionLegacySafe(getpagesize());
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
                    showDialog(localize(@"Error", nil), @"Amethyst was launched with a legacy script. We have updated the script to Universal, please restart LiveContainer to continue.");
                    return -1;
                }
            }
            [NSFileManager.defaultManager copyItemAtPath:inBundleScriptPath toPath:[NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")] error:nil];
            showDialog(localize(@"Error", nil), @"Support for legacy script has been removed. Please switch to the Universal JIT script. On current StikDebug builds it is auto-assigned to Amethyst by app name (older sideloaded builds bundled the same script as Amethyst-MeloNX.js), so updating StikDebug is the easiest fix. To assign it manually: long-press on Amethyst when enabling JIT in StikDebug, tap \"Assign Script\", then pick UniversalJIT26.js from Amethyst's Documents directory (exported automatically at every startup).");
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
    // CodeCache 参数（对齐 launchJVM：避免 CodeCache 满导致 SIGILL；
    // iOS 26+ mirror mapped JIT 需要 64m 以内避免 SIGBUS）
    PUSH_HARGV_LITERAL("-XX:ReservedCodeCacheSize=64m");
    PUSH_HARGV_LITERAL("-XX:InitialCodeCacheSize=16m");
    PUSH_HARGV_LITERAL("-XX:CodeCacheExpansionSize=4m");
    if (@available(iOS 26.0, *)) {
        PUSH_HARGV_LITERAL("-XX:+MirrorMappedCodeCache");
    }
    if (!getEntitlementValue(@"com.apple.developer.kernel.extended-virtual-addressing")) {
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
