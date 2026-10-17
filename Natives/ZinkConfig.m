#import "ZinkConfig.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

#import <sys/utsname.h>
#import <UIKit/UIKit.h>

NSString *const ZinkPrefSection = @"zink";
static AppleGPUGeneration _cachedGPUGeneration = AppleGPUGenerationUnknown;

@implementation ZinkConfig

#pragma mark - Device Detection

+ (AppleGPUGeneration)deviceGPUGeneration {
    if (_cachedGPUGeneration != AppleGPUGenerationUnknown) {
        return _cachedGPUGeneration;
    }

    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *machine = [NSString stringWithUTF8String:systemInfo.machine];

    NSDictionary *deviceMap = @{
        @"iPhone8,1": @(AppleGPUGenerationA9),
        @"iPhone8,2": @(AppleGPUGenerationA9),
        @"iPhone8,4": @(AppleGPUGenerationA9),
        @"iPhone9,1": @(AppleGPUGenerationA10),
        @"iPhone9,2": @(AppleGPUGenerationA10),
        @"iPhone9,3": @(AppleGPUGenerationA10),
        @"iPhone9,4": @(AppleGPUGenerationA10),
        @"iPhone10,1": @(AppleGPUGenerationA11),
        @"iPhone10,2": @(AppleGPUGenerationA11),
        @"iPhone10,3": @(AppleGPUGenerationA11),
        @"iPhone10,4": @(AppleGPUGenerationA11),
        @"iPhone10,5": @(AppleGPUGenerationA11),
        @"iPhone10,6": @(AppleGPUGenerationA11),
        @"iPhone11,2": @(AppleGPUGenerationA12),
        @"iPhone11,4": @(AppleGPUGenerationA12),
        @"iPhone11,6": @(AppleGPUGenerationA12),
        @"iPhone11,8": @(AppleGPUGenerationA12),
        @"iPhone12,1": @(AppleGPUGenerationA13),
        @"iPhone12,3": @(AppleGPUGenerationA13),
        @"iPhone12,5": @(AppleGPUGenerationA13),
        @"iPhone12,8": @(AppleGPUGenerationA13),
        @"iPhone13,1": @(AppleGPUGenerationA14),
        @"iPhone13,2": @(AppleGPUGenerationA14),
        @"iPhone13,3": @(AppleGPUGenerationA14),
        @"iPhone13,4": @(AppleGPUGenerationA14),
        @"iPhone14,2": @(AppleGPUGenerationA15),
        @"iPhone14,3": @(AppleGPUGenerationA15),
        @"iPhone14,4": @(AppleGPUGenerationA15),
        @"iPhone14,5": @(AppleGPUGenerationA15),
        @"iPhone14,6": @(AppleGPUGenerationA15),
        @"iPhone14,7": @(AppleGPUGenerationA15),
        @"iPhone14,8": @(AppleGPUGenerationA15),
        @"iPhone15,2": @(AppleGPUGenerationA16),
        @"iPhone15,3": @(AppleGPUGenerationA16),
        @"iPhone15,4": @(AppleGPUGenerationA16),
        @"iPhone15,5": @(AppleGPUGenerationA16),
        @"iPhone16,1": @(AppleGPUGenerationA17),
        @"iPhone16,2": @(AppleGPUGenerationA17),
        @"iPhone17,1": @(AppleGPUGenerationA18),
        @"iPhone17,2": @(AppleGPUGenerationA18),
        @"iPhone17,3": @(AppleGPUGenerationA18),
        @"iPhone17,4": @(AppleGPUGenerationA18),

        @"iPad6,11": @(AppleGPUGenerationA9),
        @"iPad6,12": @(AppleGPUGenerationA9),
        @"iPad7,5": @(AppleGPUGenerationA10),
        @"iPad7,6": @(AppleGPUGenerationA10),
        @"iPad8,1": @(AppleGPUGenerationA12),
        @"iPad8,2": @(AppleGPUGenerationA12),
        @"iPad8,3": @(AppleGPUGenerationA12),
        @"iPad8,4": @(AppleGPUGenerationA12),
        @"iPad8,5": @(AppleGPUGenerationA12),
        @"iPad8,6": @(AppleGPUGenerationA12),
        @"iPad8,7": @(AppleGPUGenerationA12),
        @"iPad8,8": @(AppleGPUGenerationA12),
        @"iPad11,1": @(AppleGPUGenerationA12),
        @"iPad11,2": @(AppleGPUGenerationA12),
        @"iPad11,3": @(AppleGPUGenerationA12),
        @"iPad11,4": @(AppleGPUGenerationA12),
        @"iPad11,6": @(AppleGPUGenerationA12),
        @"iPad11,7": @(AppleGPUGenerationA12),
        @"iPad13,1": @(AppleGPUGenerationM1),
        @"iPad13,2": @(AppleGPUGenerationM1),
        @"iPad13,4": @(AppleGPUGenerationM1),
        @"iPad13,5": @(AppleGPUGenerationM1),
        @"iPad13,6": @(AppleGPUGenerationM1),
        @"iPad13,7": @(AppleGPUGenerationM1),
        @"iPad13,8": @(AppleGPUGenerationM1),
        @"iPad13,9": @(AppleGPUGenerationM1),
        @"iPad13,10": @(AppleGPUGenerationM1),
        @"iPad13,11": @(AppleGPUGenerationM1),
        @"iPad13,16": @(AppleGPUGenerationM1),
        @"iPad13,17": @(AppleGPUGenerationM1),
        @"iPad13,18": @(AppleGPUGenerationM1),
        @"iPad13,19": @(AppleGPUGenerationM1),
        @"iPad14,1": @(AppleGPUGenerationA14),
        @"iPad14,2": @(AppleGPUGenerationA14),
        @"iPad14,3": @(AppleGPUGenerationM2),
        @"iPad14,4": @(AppleGPUGenerationM2),
        @"iPad14,5": @(AppleGPUGenerationA15),
        @"iPad14,6": @(AppleGPUGenerationA15),
    };

    NSNumber *genNum = deviceMap[machine];
    if (genNum) {
        _cachedGPUGeneration = (AppleGPUGeneration)[genNum integerValue];
    } else {
        NSString *model = UIDevice.currentDevice.model;
        if ([model containsString:@"iPad"]) {
            if ([machine containsString:@"iPad8"] || [machine containsString:@"iPad13"]) {
                _cachedGPUGeneration = AppleGPUGenerationM1;
            } else if ([machine containsString:@"iPad14"]) {
                if ([[machine substringFromIndex:7] intValue] >= 3) {
                    _cachedGPUGeneration = AppleGPUGenerationM2;
                } else {
                    _cachedGPUGeneration = AppleGPUGenerationA14;
                }
            } else {
                _cachedGPUGeneration = AppleGPUGenerationA12;
            }
        } else {
            _cachedGPUGeneration = AppleGPUGenerationA14;
        }
    }
    return _cachedGPUGeneration;
}

+ (NSString *)deviceGPUGenerationName {
    switch ([self deviceGPUGeneration]) {
        case AppleGPUGenerationA9:  return @"A9";
        case AppleGPUGenerationA10: return @"A10";
        case AppleGPUGenerationA11: return @"A11";
        case AppleGPUGenerationA12: return @"A12";
        case AppleGPUGenerationA13: return @"A13";
        case AppleGPUGenerationA14: return @"A14";
        case AppleGPUGenerationA15: return @"A15";
        case AppleGPUGenerationA16: return @"A16";
        case AppleGPUGenerationA17: return @"A17 Pro";
        case AppleGPUGenerationA18: return @"A18";
        case AppleGPUGenerationM1:  return @"M1";
        case AppleGPUGenerationM2:  return @"M2";
        case AppleGPUGenerationM3:  return @"M3";
        case AppleGPUGenerationM4:  return @"M4";
        default: return @"Unknown";
    }
}

#pragma mark - API Support

+ (ZinkAPIFeatures)supportedAPIFeaturesForGPUGeneration:(AppleGPUGeneration)gen {
    ZinkAPIFeatures features = ZinkAPIFeatureNone;

    features |= ZinkAPIFeatureTextureAnisotropic;

    switch (gen) {
        case AppleGPUGenerationA9:
        case AppleGPUGenerationA10:
            features |= ZinkAPIFeatureTessellationShader;
            features |= ZinkAPIFeatureGeometryShader;
            break;

        case AppleGPUGenerationA11:
            features |= ZinkAPIFeatureTessellationShader;
            features |= ZinkAPIFeatureGeometryShader;
            features |= ZinkAPIFeatureComputeShader;
            features |= ZinkAPIFeatureMultiDrawIndirect;
            break;

        case AppleGPUGenerationA12:
        case AppleGPUGenerationA13:
            features |= ZinkAPIFeatureTessellationShader;
            features |= ZinkAPIFeatureGeometryShader;
            features |= ZinkAPIFeatureComputeShader;
            features |= ZinkAPIFeatureMultiDrawIndirect;
            features |= ZinkAPIFeatureDirectStateAccess;
            break;

        case AppleGPUGenerationA14:
        case AppleGPUGenerationA15:
        case AppleGPUGenerationA16:
            features |= ZinkAPIFeatureTessellationShader;
            features |= ZinkAPIFeatureGeometryShader;
            features |= ZinkAPIFeatureComputeShader;
            features |= ZinkAPIFeatureMultiDrawIndirect;
            features |= ZinkAPIFeatureDirectStateAccess;
            break;

        case AppleGPUGenerationA17:
        case AppleGPUGenerationA18:
        case AppleGPUGenerationM1:
        case AppleGPUGenerationM2:
        case AppleGPUGenerationM3:
        case AppleGPUGenerationM4:
            features |= ZinkAPIFeatureTessellationShader;
            features |= ZinkAPIFeatureGeometryShader;
            features |= ZinkAPIFeatureComputeShader;
            features |= ZinkAPIFeatureMultiDrawIndirect;
            features |= ZinkAPIFeatureDirectStateAccess;
            break;

        default:
            features |= ZinkAPIFeatureDirectStateAccess;
            break;
    }

    return features;
}

+ (ZinkAPIFeatures)supportedAPIFeatures {
    return [self supportedAPIFeaturesForGPUGeneration:[self deviceGPUGeneration]];
}

#pragma mark - Optimization Level

+ (ZinkOptimizationLevel)recommendedOptimizationLevel {
    AppleGPUGeneration gen = [self deviceGPUGeneration];
    switch (gen) {
        case AppleGPUGenerationA9:
        case AppleGPUGenerationA10:
            return ZinkOptimizationLevelLow;
        case AppleGPUGenerationA11:
            return ZinkOptimizationLevelMedium;
        case AppleGPUGenerationA12:
        case AppleGPUGenerationA13:
            return ZinkOptimizationLevelMedium;
        case AppleGPUGenerationA14:
            return ZinkOptimizationLevelHigh;
        case AppleGPUGenerationA15:
        case AppleGPUGenerationA16:
        case AppleGPUGenerationA17:
        case AppleGPUGenerationA18:
        case AppleGPUGenerationM1:
        case AppleGPUGenerationM2:
        case AppleGPUGenerationM3:
        case AppleGPUGenerationM4:
            return ZinkOptimizationLevelUltra;
        default:
            return ZinkOptimizationLevelMedium;
    }
}

+ (BOOL)isZinkRenderSelected {
    NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
    return [renderer hasPrefix:@"libOSMesa"];
}

#pragma mark - Environment Setup

+ (void)applyZinkEnvironmentForOptimizationLevel:(ZinkOptimizationLevel)level {
    if (level == ZinkOptimizationLevelAuto) {
        level = [self recommendedOptimizationLevel];
    }

    // GL 4.1 / GLSL 410 is used for Minecraft 1.21.4+'s core shader pipeline
    // which relies on GL_ARB_separate_shader_objects (glCreateShaderProgramv)
    // introduced in GL 4.1. Minecraft 1.17–1.21 also works at 4.1 without issue.
    // GL_ARB_shader_draw_parameters is force-enabled via MESA_EXTENSION_OVERRIDE
    // since Mesa 21.0.0 Zink does not expose it by default on Metal/MoltenVK.
    // If compatibility issues arise, users can set zink.gl_override to 3.3 or 4.0.
    //
    // 关键修复（Mesa 25.0.7 + 光影兼容性）：
    //   原实现按优化级别禁用 compute/tessellation/geometry/MultiDraw/DSA 等扩展，
    //   但这些扩展是 Iris/OptiFine 光影渲染植被（草方块、树叶、藤蔓）所必需：
    //     - compute shader：Iris 阴影、SSAO、bloom 后处理
    //     - tessellation shader：部分光影的位移映射
    //     - geometry shader：部分光影的粒子/billboard
    //   Mesa 25.0.7 升级后用户反馈草方块无法渲染，根因是 Auto 级别在 A9-A13 设备
    //   推荐为 Low/Medium，禁用了 compute shader，Iris 的植被渲染 pipeline 崩溃。
    //   修复策略（保守默认 + 显式覆盖）：
    //     1. 所有优化级别默认保留所有 GL 扩展（仅禁用 MoltenVK 不支持的 Transform Feedback）
    //     2. 只调整 GLSL cache 大小和 mesa_glthread
    //     3. 用户可通过 zink.api_features 显式禁用扩展（极端性能优化场景）
    ZinkAPIFeatures supported = [self supportedAPIFeatures];
    // 保守默认：保留所有支持的扩展，仅禁用 Transform Feedback（MoltenVK 限制）
    ZinkAPIFeatures enabledFeatures = supported & ~ZinkAPIFeatureTransformFeedback;
    BOOL enableGLThread = YES;
    int glslCacheSize = 32;

    switch (level) {
        case ZinkOptimizationLevelOff:
            // Off 级别也保守：保留所有光影所需扩展
            glslCacheSize = 128;
            enableGLThread = YES;
            break;

        case ZinkOptimizationLevelSafe:
            // Safe 级别：最小缓存，关闭 glthread
            glslCacheSize = 16;
            enableGLThread = NO;
            break;

        case ZinkOptimizationLevelLow:
            glslCacheSize = 32;
            break;

        case ZinkOptimizationLevelMedium:
            glslCacheSize = 64;
            break;

        case ZinkOptimizationLevelHigh:
            glslCacheSize = 128;
            break;

        case ZinkOptimizationLevelUltra:
            glslCacheSize = 256;
            break;

        default:
            break;
    }

    setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);
    setenv("MESA_GLSL_VERSION_OVERRIDE", "410", 1);

    // 仅当用户显式设置 zink.api_features 时才覆盖扩展列表，
    // applyZinkEnvironmentFromPreferences 会处理此情况。
    // 此处设置保守默认（保留所有扩展 + 强制启用 shader_draw_parameters）。
    NSString *extOverrides = [self extensionDisableStringForLevel:enabledFeatures];
    if (extOverrides.length > 0) {
        setenv("MESA_EXTENSION_OVERRIDE", extOverrides.UTF8String, 1);
    } else {
        unsetenv("MESA_EXTENSION_OVERRIDE");
    }

    if (enableGLThread) {
        setenv("mesa_glthread", "true", 1);
    } else {
        setenv("mesa_glthread", "false", 1);
    }

    char cacheSizeStr[16];
    snprintf(cacheSizeStr, sizeof(cacheSizeStr), "%d", glslCacheSize);
    setenv("MESA_GLSL_CACHE_MAX_SIZE", cacheSizeStr, 1);
}

+ (void)applyZinkAPIFeatureOverride:(ZinkAPIFeatures)enabledFeatures {
    setenv("MESA_EXTENSION_OVERRIDE",
        [self extensionDisableStringForLevel:enabledFeatures].UTF8String, 1);
}

+ (NSString *)activeConfigSummary {
    AppleGPUGeneration gen = [self deviceGPUGeneration];
    NSString *genName = [self deviceGPUGenerationName];

    id rawLevel = getPrefObject(@"zink.optimization_level");
    ZinkOptimizationLevel level = ZinkOptimizationLevelAuto;
    if (rawLevel) {
        level = (ZinkOptimizationLevel)[rawLevel integerValue];
        if (level < ZinkOptimizationLevelOff || level > ZinkOptimizationLevelUltra) {
            level = ZinkOptimizationLevelAuto;
        }
    }

    NSString *levelName;
    switch (level) {
        case ZinkOptimizationLevelAuto: levelName = @"Auto"; break;
        case ZinkOptimizationLevelOff:  levelName = @"Off (0)"; break;
        case ZinkOptimizationLevelSafe: levelName = @"Safe (1)"; break;
        case ZinkOptimizationLevelLow:  levelName = @"Low (2)"; break;
        case ZinkOptimizationLevelMedium: levelName = @"Medium (3)"; break;
        case ZinkOptimizationLevelHigh: levelName = @"High (4)"; break;
        case ZinkOptimizationLevelUltra: levelName = @"Ultra (5)"; break;
        default: levelName = @"Unknown"; break;
    }

    ZinkOptimizationLevel resolvedLevel = level;
    if (resolvedLevel == ZinkOptimizationLevelAuto) {
        resolvedLevel = [self recommendedOptimizationLevel];
    }

    NSString *resolvedLevelName;
    switch (resolvedLevel) {
        case ZinkOptimizationLevelOff:  resolvedLevelName = @"Off (0)"; break;
        case ZinkOptimizationLevelSafe: resolvedLevelName = @"Safe (1)"; break;
        case ZinkOptimizationLevelLow:  resolvedLevelName = @"Low (2)"; break;
        case ZinkOptimizationLevelMedium: resolvedLevelName = @"Medium (3)"; break;
        case ZinkOptimizationLevelHigh: resolvedLevelName = @"High (4)"; break;
        case ZinkOptimizationLevelUltra: resolvedLevelName = @"Ultra (5)"; break;
        default: resolvedLevelName = @"Unknown"; break;
    }

    id glOverride = getPrefObject(@"zink.gl_override");
    NSString *glVer = (glOverride && [glOverride isKindOfClass:[NSString class]] && [glOverride length] > 0 && ![(NSString *)glOverride isEqualToString:@"0"])
        ? (NSString *)glOverride : @"4.1 (from level)";

    id glThread = getPrefObject(@"zink.enable_gl_thread");
    NSString *glThreadStr = glThread ? ([glThread boolValue] ? @"YES" : @"NO") : @"YES";

    id cacheSize = getPrefObject(@"zink.glsl_cache_size");
    NSString *cacheStr = cacheSize ? [NSString stringWithFormat:@"%ld MB", (long)[cacheSize integerValue]] : @"32 MB";

    id apiFeatures = getPrefObject(@"zink.api_features");
    NSString *apiStr;
    if (apiFeatures) {
        NSInteger apiVal = [apiFeatures integerValue];
        switch (apiVal) {
            case 0: apiStr = @"Minimal"; break;
            case 1: apiStr = @"Basic"; break;
            case 2: apiStr = @"Standard"; break;
            case 3: apiStr = @"Full"; break;
            default: apiStr = @"Full (default)"; break;
        }
    } else {
        apiStr = @"Full (default)";
    }

    NSString *renderer = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];

    return [NSString stringWithFormat:
        @"[Zink Config]\n"
        @"Renderer: %@\n"
        @"GPU: %@ (recommended: %@)\n"
        @"Setting / Resolved: %@ / %@\n"
        @"GL: %@ / GL Thread: %@\n"
        @"Cache: %@ / API: %@",
        renderer, genName, [self deviceRecommendationString],
        levelName, resolvedLevelName,
        glVer, glThreadStr,
        cacheStr, apiStr];
}

+ (void)applyZinkEnvironmentFromPreferences {
    [self applyZinkEnvironmentFromPreferencesWithMCMajor:0];
}

/// ★ Task283（GitHub 议题 #15 "Renderer bug (added log)" 启动器侧根修）：
///   MC 版本感知的 GL 版本下限。议题装机日志（c7b5878，iPhone XS Max/
///   A12）实锤：Zink 会话报告 "4.1 (Compatibility Profile) Mesa 25.0.7"
///   ——本类历史把 MESA_GL_VERSION_OVERRIDE 硬钉 4.1（为 1.17-1.21.x
///   管线定案），而 MC 26.x 新光照引擎（GpuSurfaceBackend 世代）需要
///   GL 4.4+/SSBO：4.1 封顶 = 能进世界但光照数据上传路径缺失 = 用户
///   "光照异常、整个画面一片漆黑"。本方法在用户未显式钉 zink.gl_override
///   且 MC major >= 26 时自动把下限抬到 4.5（Mesa zink 在 MoltenVK
///   argument-buffer tier2 设备上实际支持 SSBO，报低是保守默认）；显式
///   钉过版本（3.3/4.0/4.1 或新承认的 4.3/4.5/4.6）永远优先，行为不
///   变。1.x 谱系（major=1/0 未知）保持 4.1 原状零回归。
+ (void)applyZinkEnvironmentFromPreferencesWithMCMajor:(NSInteger)mcMajor {
    id rawLevel = getPrefObject(@"zink.optimization_level");
    ZinkOptimizationLevel level = ZinkOptimizationLevelAuto;
    if (rawLevel) {
        level = (ZinkOptimizationLevel)[rawLevel integerValue];
        if (level < ZinkOptimizationLevelOff || level > ZinkOptimizationLevelUltra) {
            level = ZinkOptimizationLevelAuto;
        }
    }

    ZinkOptimizationLevel resolvedLevel = level;
    if (resolvedLevel == ZinkOptimizationLevelAuto) {
        resolvedLevel = [self recommendedOptimizationLevel];
    }

    [self applyZinkEnvironmentForOptimizationLevel:level];

    // Store active config for in-game display (available via System.getenv in Java)
    NSString *summary = [self activeConfigSummary];
    setenv("ZINK_ACTIVE_CONFIG", summary.UTF8String, 1);
    NSLog(@"[ZinkConfig] %@", summary);

    id customGlVersion = getPrefObject(@"zink.gl_override");
    if (customGlVersion && [customGlVersion isKindOfClass:[NSString class]]) {
        NSString *verStr = (NSString *)customGlVersion;
        if ([verStr isEqualToString:@"3.3"]) {
            setenv("MESA_GL_VERSION_OVERRIDE", "3.3", 1);
            setenv("MESA_GLSL_VERSION_OVERRIDE", "330", 1);
        } else if ([verStr isEqualToString:@"4.0"]) {
            setenv("MESA_GL_VERSION_OVERRIDE", "4.0", 1);
            setenv("MESA_GLSL_VERSION_OVERRIDE", "400", 1);
        } else if ([verStr isEqualToString:@"4.1"]) {
            setenv("MESA_GL_VERSION_OVERRIDE", "4.1", 1);
            setenv("MESA_GLSL_VERSION_OVERRIDE", "410", 1);
        } else if ([verStr isEqualToString:@"4.3"]) {
            // ★ Task283：新承认档位——SSBO 起点（MC 26.x 光照引擎最低需求 4.4 之下的过渡档）
            setenv("MESA_GL_VERSION_OVERRIDE", "4.3", 1);
            setenv("MESA_GLSL_VERSION_OVERRIDE", "430", 1);
        } else if ([verStr isEqualToString:@"4.5"]) {
            // ★ Task283：MC 26.x 推荐档（SSBO/4.4+ 光照引擎全量可用）
            setenv("MESA_GL_VERSION_OVERRIDE", "4.5", 1);
            setenv("MESA_GLSL_VERSION_OVERRIDE", "450", 1);
        } else if ([verStr isEqualToString:@"4.6"]) {
            // ★ Task283：上限试探档（zink/MoltenVK 实际能力封顶由 Mesa 自行裁定）
            setenv("MESA_GL_VERSION_OVERRIDE", "4.6", 1);
            setenv("MESA_GLSL_VERSION_OVERRIDE", "460", 1);
        }
    } else if (mcMajor >= 26) {
        // ★ Task283：MC 26.x 自动抬下限（用户未显式钉版本时）——默认 4.1
        //   在 26.x 上即议题 #15 的全黑本体；1.x/未知版本不进本支零回归。
        setenv("MESA_GL_VERSION_OVERRIDE", "4.5", 1);
        setenv("MESA_GLSL_VERSION_OVERRIDE", "450", 1);
        NSLog(@"[ZinkConfig] Task283: MC major %ld detected -- GL floor raised 4.1 -> 4.5 (26.x light engine needs GL4.4+/SSBO; pin zink.gl_override to revert)",
              (long)mcMajor);
    }

    id enableGLThread = getPrefObject(@"zink.enable_gl_thread");
    if (enableGLThread) {
        setenv("mesa_glthread", [enableGLThread boolValue] ? "true" : "false", 1);
    } else {
        // Disable glthread on A11 and older to reduce memory pressure
        AppleGPUGeneration gen = [self deviceGPUGeneration];
        if (gen <= AppleGPUGenerationA11) {
            setenv("mesa_glthread", "false", 1);
        }
    }

    // On A11 and older: disable MoltenVK command buffer prefilling to reduce GPU memory pressure
    AppleGPUGeneration gen = [self deviceGPUGeneration];
    if (gen <= AppleGPUGenerationA11) {
        setenv("MVK_CONFIG_PREFILL_METAL_COMMAND_BUFFERS", "0", 1);
    }

    // Iris 光影 fragment shader 接口兼容性：
    //   MoltenVK 编译 pipeline 时，若 fragment shader 声明了 vertex shader 未写入
    //   的 input（如 `user(locn1_2)`），Metal pipeline 编译可能失败。
    //   Iris 1.8.8+ 已内置兼容性补丁，会自动为未写入的 fragment input 添加初始化
    //   （见日志 "compatibility-patched by adding an initialization for it"）。
    //
    //   注：MVK_CONFIG_SHADER_INTERFACE_LINKING 环境变量在 MoltenVK 1.2.9 中
    //   不存在（已通过 strings 验证），此设置会被忽略。保留作为未来 MoltenVK
    //   版本的兼容性预留。Iris 的内置补丁已足够处理此问题。
    setenv("MVK_CONFIG_SHADER_INTERFACE_LINKING", "false", 1);

    // Set shader cache to a writable path (Documents/.mesa_shader_cache)
    NSArray *docPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (docPaths.count > 0) {
        NSString *cacheDir = [docPaths[0] stringByAppendingPathComponent:@".mesa_shader_cache"];
        NSError *err = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:&err];
        if (!err) {
            setenv("MESA_SHADER_CACHE_DIR", cacheDir.UTF8String, 1);
            setenv("MESA_GLSL_CACHE_DIR", cacheDir.UTF8String, 1);
        }
    }

    id cacheSize = getPrefObject(@"zink.glsl_cache_size");
    if (cacheSize && [cacheSize integerValue] > 0) {
        char buf[16];
        snprintf(buf, sizeof(buf), "%ld", (long)[cacheSize integerValue]);
        setenv("MESA_GLSL_CACHE_MAX_SIZE", buf, 1);
        setenv("MESA_SHADER_CACHE_MAX_SIZE", buf, 1);
    }

    id customAPIOverride = getPrefObject(@"zink.api_features");
    if (customAPIOverride) {
        NSInteger apiVal = [customAPIOverride integerValue];
        ZinkAPIFeatures baseFeatures = [self supportedAPIFeatures];
        ZinkAPIFeatures enabledFeatures;

        switch (apiVal) {
            case 0: // Minimal
                enabledFeatures = ZinkAPIFeatureTextureAnisotropic;
                break;
            case 1: // Basic
                enabledFeatures = ZinkAPIFeatureTextureAnisotropic |
                                  ZinkAPIFeatureTessellationShader |
                                  ZinkAPIFeatureGeometryShader;
                break;
            case 2: // Standard
                enabledFeatures = baseFeatures & ~ZinkAPIFeatureTransformFeedback;
                if (resolvedLevel <= ZinkOptimizationLevelLow) {
                    enabledFeatures &= ~ZinkAPIFeatureComputeShader;
                }
                if (resolvedLevel <= ZinkOptimizationLevelSafe) {
                    enabledFeatures &= ~(ZinkAPIFeatureDirectStateAccess | ZinkAPIFeatureMultiDrawIndirect);
                }
                break;
            case 3: // Full
            default:
                enabledFeatures = baseFeatures & ~ZinkAPIFeatureTransformFeedback;
                break;
        }
        [self applyZinkAPIFeatureOverride:enabledFeatures];
    }
}

+ (NSString *)extensionDisableStringForLevel:(ZinkAPIFeatures)enabledFeatures {
    NSMutableArray *disableExts = [NSMutableArray array];

    // Force-enable GL_ARB_shader_draw_parameters (required by Minecraft 1.17+
    // rendering pipeline). Zink/Mesa 21.0.0 does not expose this extension by
    // default even when the underlying Vulkan/Metal supports it.
    [disableExts addObject:@"+GL_ARB_shader_draw_parameters"];

    if (!(enabledFeatures & ZinkAPIFeatureTransformFeedback)) {
        [disableExts addObject:@"-GL_ARB_transform_feedback"];
        [disableExts addObject:@"-GL_ARB_transform_feedback2"];
        [disableExts addObject:@"-GL_ARB_transform_feedback3"];
        [disableExts addObject:@"-GL_NV_transform_feedback"];
    }

    if (!(enabledFeatures & ZinkAPIFeatureComputeShader)) {
        [disableExts addObject:@"-GL_ARB_compute_shader"];
    }

    if (!(enabledFeatures & ZinkAPIFeatureTessellationShader)) {
        [disableExts addObject:@"-GL_ARB_tessellation_shader"];
    }

    if (!(enabledFeatures & ZinkAPIFeatureGeometryShader)) {
        [disableExts addObject:@"-GL_ARB_geometry_shader4"];
    }

    if (!(enabledFeatures & ZinkAPIFeatureMultiDrawIndirect)) {
        [disableExts addObject:@"-GL_ARB_multi_draw_indirect"];
        [disableExts addObject:@"-GL_ARB_draw_indirect"];
    }

    if (!(enabledFeatures & ZinkAPIFeatureDirectStateAccess)) {
        [disableExts addObject:@"-GL_ARB_direct_state_access"];
    }

    if (!(enabledFeatures & ZinkAPIFeatureTextureAnisotropic)) {
        [disableExts addObject:@"-GL_EXT_texture_filter_anisotropic"];
    }

    return [disableExts componentsJoinedByString:@" "];
}

#pragma mark - Info Strings

+ (NSString *)deviceRecommendationString {
    AppleGPUGeneration gen = [self deviceGPUGeneration];
    ZinkOptimizationLevel rec = [self recommendedOptimizationLevel];

    NSString *genName = [self deviceGPUGenerationName];
    NSString *levelName;
    switch (rec) {
        case ZinkOptimizationLevelSafe:   levelName = @"Safe (1)"; break;
        case ZinkOptimizationLevelLow:    levelName = @"Low (2)"; break;
        case ZinkOptimizationLevelMedium: levelName = @"Medium (3)"; break;
        case ZinkOptimizationLevelHigh:   levelName = @"High (4)"; break;
        case ZinkOptimizationLevelUltra:  levelName = @"Ultra (5)"; break;
        default: levelName = @"Auto"; break;
    }

    return [NSString stringWithFormat:@"%@ GPU → Recommended: %@", genName, levelName];
}

+ (NSString *)apiSupportSummaryForGPUGeneration:(AppleGPUGeneration)gen {
    ZinkAPIFeatures features = [self supportedAPIFeaturesForGPUGeneration:gen];
    NSMutableString *summary = [NSMutableString string];

    [summary appendFormat:@"%@ GPU:\n", [self deviceGPUGenerationName]];
    [summary appendFormat:@"✓ Transform Feedback: %@\n",
        (features & ZinkAPIFeatureTransformFeedback) ? @"OFF (forced)" : @"OFF (unsupported)"];
    [summary appendFormat:@"✓ Compute Shader: %@\n",
        (features & ZinkAPIFeatureComputeShader) ? @"ON" : @"OFF"];
    [summary appendFormat:@"✓ Tessellation: %@\n",
        (features & ZinkAPIFeatureTessellationShader) ? @"ON" : @"OFF"];
    [summary appendFormat:@"✓ Multi Draw Indirect: %@\n",
        (features & ZinkAPIFeatureMultiDrawIndirect) ? @"ON" : @"OFF"];
    [summary appendFormat:@"✓ Direct State Access: %@\n",
        (features & ZinkAPIFeatureDirectStateAccess) ? @"ON" : @"OFF"];

    return summary;
}

@end
