//
//  AiSettingsTools.m
//  Prisma
//

#import "AiSettingsTools.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

@interface AiSettingsTools ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiSettingsTools

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = [name copy] ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    if ([self.internalName isEqualToString:@"set_setting"]) {
        return AiToolPermissionControlledWrite;
    }
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"list_settings"]) {
        return @"列出启动器支持的设置键与取值说明。"
               "\n无参数。"
               "\n返回键表：video.renderer（渲染器，实例级：auto/GL4ES/Krypton Wrapper（原 NG-GL4ES，≤26.2 老版本首选）/gl4es（ZL2 经典版）/ANGLE/MobileGlues/Zink/MoltenVK/LTW）、"
               "video.graphics_api（图形 API，实例级，MC 26.2+ 生效：default/prefer_vulkan/prefer_opengl）、"
               "java.allocated_memory（游戏内存 MB，全局）、java.auto_ram（自动分配内存，全局，true/false）、"
               "java.java_args（JVM 参数，全局+实例级覆盖）、general.download_source（下载源，全局：official/bmclapi）、"
               "general.game_directory（当前游戏目录名，全局）、control.default_ctrl（默认控制布局，全局）。";
    }
    if ([self.internalName isEqualToString:@"get_setting"]) {
        return @"读取指定设置键的当前值。"
               "\n参数：key（string，必填，见 list_settings）、instance（string，可选，实例/profile 名，缺省当前选中实例）。"
               "\n返回：全局值 + 实例生效值（实例值优先于全局，实例未设置时回退全局）。";
    }
    // set_setting
    return @"修改启动器设置。"
           "\n参数：key（string，必填）、value（string/number/boolean，必填）、instance（string，可选，缺省修改当前选中实例或全局）。"
           "\n说明：video.renderer / video.graphics_api 为实例级设置（写入指定实例的 profile）；"
           "其余键为全局设置。渲染器可传友好名（MoltenVK/Zink/MobileGlues/GL4ES/Krypton Wrapper/NG-GL4ES/gl4es ZL2/ANGLE/auto），内部自动映射为存储键。"
           "\n写成功后返回新值并广播刷新通知。除 YOLO 模式外执行前会请求用户确认。";
}

#pragma mark - 键元数据

/// 实例级键 → profile 字段名
+ (NSDictionary<NSString *, NSString *> *)profileKeyMap {
    return @{
        @"video.renderer": @"renderer",
        @"video.graphics_api": @"graphicsApi",
        @"java.java_args": @"javaArgs",
    };
}

/// 渲染器友好名 → 存储键（getRendererKeys 的实际值）
+ (NSString *)rendererStorageKeyForValue:(NSString *)value {
    if (value.length == 0) return nil;
    NSString *lower = [value lowercaseString];
    // 传入的已是存储键（libxxx.dylib / auto）则原样返回
    NSArray *keys = getRendererKeys(NO);
    for (NSString *key in keys) {
        if ([key.lowercaseString isEqualToString:lower]) return key;
    }
    if ([lower isEqualToString:@"auto"] || [lower containsString:@"自动"]) return @"auto";
    if ([lower containsString:@"moltenvk"] || [lower containsString:@"vulkan"]) return @(RENDERER_NAME_VULKAN);
    // Task 215：VirGL 匹配必须在 zink/osmesa 之前（libOSMesaVirgl 同样含 osmesa 字样）
    if ([lower containsString:@"virgl"] || [lower containsString:@"virgil"]) return @(RENDERER_NAME_VIRGL);
    if ([lower containsString:@"zink"] || [lower containsString:@"mesa"] || [lower containsString:@"osmesa"]) return @(RENDERER_NAME_VK_ZINK);
    if ([lower containsString:@"mobileglues"] || [lower isEqualToString:@"mg"]) return @(RENDERER_NAME_MOBILEGLUES);
    if ([lower containsString:@"angle"] || [lower containsString:@"tinygl4"]) return @(RENDERER_NAME_MTL_ANGLE);
    // 必须排在 angle 之后："MetalANGLE" 同样含 "metal" 子串（Task201 随上游同步）
    if ([lower containsString:@"metallum"] || [lower containsString:@"metal"]) return @(RENDERER_NAME_METAL);
    // 必须排在 gl4es 之前："nggl4es" 同样含 "gl4es" 子串（Task206；krypton =
    // 上游别名 Krypton Wrapper）。Task212：holy gl4es 退役后，裸 "gl4es"
    // 一词由 ZL2 经典版（gl4es(≤26.2)）接棒匹配。
    if ([lower containsString:@"nggl4es"] || [lower containsString:@"krypton"]) return @(RENDERER_NAME_NGGL4ES);
    if ([lower containsString:@"gl4eszl2"] || [lower containsString:@"zl2classic"] ||
        [lower containsString:@"gl4es"] || [lower containsString:@"zl2 经典"]) return @(RENDERER_NAME_GL4ESZL2);
    if ([lower containsString:@"ltw"]) return @(RENDERER_NAME_LTW);
    return nil;
}

/// 渲染器存储键 → 友好名（输出给 AI 看）
+ (NSString *)rendererFriendlyName:(NSString *)storageKey {
    if ([storageKey isEqualToString:@"auto"]) return @"auto";
    if ([storageKey isEqualToString:@(RENDERER_NAME_VULKAN)]) return @"MoltenVK (libMoltenVK.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_VK_ZINK)]) return @"Zink (libOSMesa.8.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_MOBILEGLUES)]) return @"MobileGlues (libmobileglues.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_MTL_ANGLE)]) return @"ANGLE/MetalANGLE (libtinygl4angle.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_METAL)]) return @"Metal (libmetallum.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_LTW)]) return @"LTW (libltw.dylib)";
    if ([storageKey isEqualToString:@(RENDERER_NAME_NGGL4ES)]) return @"Krypton Wrapper/NG-GL4ES (libnggl4es.dylib)"; // Task209：改名后新名在前，旧名保留供 AI 对话兼容
    if ([storageKey isEqualToString:@(RENDERER_NAME_GL4ESZL2)]) return @"gl4es(≤26.2) (libgl4eszl2.dylib)"; // Task211 引入；Task212 用户定名
    // Task 215：VirGLRenderer(≤26.2)（ZL2 移植，libOSMesaVirgl guest + 进程内 vtest server）
    if ([storageKey isEqualToString:@(RENDERER_NAME_VIRGL)]) return @"VirGLRenderer(≤26.2) (libOSMesaVirgl.dylib)";
    return storageKey;
}

+ (NSString *)graphicsApiStorageKeyForValue:(NSString *)value {
    if (value.length == 0) return nil;
    NSString *lower = [value lowercaseString];
    if ([lower isEqualToString:@"default"] || [lower containsString:@"默认"]) return @"default";
    if ([lower containsString:@"vulkan"]) return @"prefer_vulkan";
    if ([lower containsString:@"opengl"] || [lower containsString:@"gl"]) return @"prefer_opengl";
    return nil;
}

/// 解析目标 profile 名（instance 参数优先，缺省当前选中）
+ (NSString *)profileNameForParams:(NSDictionary *)params {
    NSString *instance = [params[@"instance"] isKindOfClass:[NSString class]] ? params[@"instance"] : @"";
    if (instance.length > 0) return instance;
    NSString *name = [PLProfiles current].selectedProfileName;
    return name.length > 0 ? name : @"(Default)";
}

/// 目标 profile 字典（不存在时返回 nil）
+ (NSMutableDictionary *)profileDictionaryForName:(NSString *)profileName {
    NSDictionary *profiles = [PLProfiles current].profiles;
    if (![profiles isKindOfClass:[NSDictionary class]]) return nil;
    id prof = profiles[profileName];
    return [prof isKindOfClass:[NSMutableDictionary class]] ? prof : nil;
}

+ (NSString *)stringFromValue:(id)value {
    if (!value || [value isKindOfClass:[NSNull class]]) return localize(@"ai.settings.unset", nil);
    if ([value isKindOfClass:[NSString class]]) return value;
    return [value description];
}

#pragma mark - 执行分发

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([self.internalName isEqualToString:@"list_settings"]) {
        [self performListSettings:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"get_setting"]) {
        [self performGetSetting:params completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"set_setting"]) {
        [self performSetSetting:params completion:completion];
        return;
    }

    NSError *err = [NSError errorWithDomain:@"AiTool" code:404
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.tools.unknown_tool_fmt", nil), self.internalName]}];
    completion(nil, err);
}

#pragma mark - list_settings

- (void)performListSettings:(void (^)(NSString *, NSError *))completion {
    NSDictionary *table = @{
        @"video.renderer": @{
            @"scope": @"实例级",
            @"values": @"auto / GL4ES / ANGLE(MetalANGLE) / MobileGlues / Zink / MoltenVK / LTW",
            @"note": @"渲染器。MC 26.2 遇 OpenGL 语法错误时切换为 MoltenVK；Iris 光影建议 Zink",
        },
        @"video.graphics_api": @{
            @"scope": @"实例级",
            @"values": @"default / prefer_vulkan / prefer_opengl",
            @"note": @"MC 26.2+（含 1.21.8+）游戏内图形 API 选择",
        },
        @"java.allocated_memory": @{
            @"scope": @"全局",
            @"values": @"整数（MB），如 2048",
            @"note": @"游戏分配内存；java.auto_ram 开启时由启动器自动决定",
        },
        @"java.auto_ram": @{
            @"scope": @"全局",
            @"values": @"true / false",
            @"note": @"自动分配内存",
        },
        @"java.java_args": @{
            @"scope": @"全局（实例可覆盖）",
            @"values": @"JVM 参数字符串，如 -XX:+UseG1GC",
            @"note": @"实例 profile 的 javaArgs 字段可覆盖全局值",
        },
        @"general.download_source": @{
            @"scope": @"全局",
            @"values": @"official / bmclapi",
            @"note": @"Minecraft 本体下载源（资源类走 Modrinth 自动兜底链）",
        },
        @"general.game_directory": @{
            @"scope": @"全局",
            @"values": @"实例目录名",
            @"note": @"当前游戏目录；新建实例请用 create_instance 工具，不建议直接改此键",
        },
        @"control.default_ctrl": @{
            @"scope": @"全局",
            @"values": @"控制布局文件名（不含扩展名）",
            @"note": @"默认触屏控制布局",
        },
    };

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:table options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!data || jsonError) {
        completion(localize(@"ai.settings.serialize_failed", nil), nil);
        return;
    }
    completion([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], nil);
}

#pragma mark - get_setting

- (void)performGetSetting:(NSDictionary *)params
              completion:(void (^)(NSString *, NSError *))completion {
    NSString *key = [params[@"key"] isKindOfClass:[NSString class]] ? params[@"key"] : @"";
    if (key.length == 0) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.settings.param_key_required", nil)}]);
        return;
    }

    NSString *profileName = [AiSettingsTools profileNameForParams:params];
    NSString *profileField = [AiSettingsTools profileKeyMap][key];

    // 实例生效值：resolveKey 语义（实例值优先，回退全局）
    id effective = nil;
    if (profileField) {
        NSMutableDictionary *prof = [AiSettingsTools profileDictionaryForName:profileName];
        effective = [PLProfiles profile:prof resolveKey:profileField];
    }
    // 全局值
    id global = getPrefObject(key);

    NSString *globalDesc = [AiSettingsTools stringFromValue:global];
    if ([key isEqualToString:@"video.renderer"]) {
        globalDesc = [AiSettingsTools rendererFriendlyName:[AiSettingsTools stringFromValue:global]];
    }

    NSString *effectiveDesc = profileField ? [AiSettingsTools stringFromValue:effective] : globalDesc;
    if (profileField && [key isEqualToString:@"video.renderer"]) {
        effectiveDesc = [AiSettingsTools rendererFriendlyName:[AiSettingsTools stringFromValue:effective]];
    }

    completion([NSString stringWithFormat:
                localize(@"ai.settings.get_result_fmt", nil),
                key, globalDesc, profileName, effectiveDesc,
                [AiSettingsTools stringFromValue:getPrefObject(@"general.game_directory")]], nil);
}

#pragma mark - set_setting

- (void)performSetSetting:(NSDictionary *)params
              completion:(void (^)(NSString *, NSError *))completion {
    NSString *key = [params[@"key"] isKindOfClass:[NSString class]] ? params[@"key"] : @"";
    id value = params[@"value"];
    if (key.length == 0 || value == nil || [value isKindOfClass:[NSNull class]]) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.settings.key_value_required", nil)}]);
        return;
    }

    // ---- 实例级键：写入 profile ----
    NSString *profileField = [AiSettingsTools profileKeyMap][key];
    if (profileField) {
        NSString *storageValue = nil;
        if ([key isEqualToString:@"video.renderer"]) {
            storageValue = [AiSettingsTools rendererStorageKeyForValue:[AiSettingsTools stringFromValue:value]];
            if (!storageValue) {
                completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 localize(@"ai.settings.invalid_renderer", nil)}]);
                return;
            }
        } else if ([key isEqualToString:@"video.graphics_api"]) {
            storageValue = [AiSettingsTools graphicsApiStorageKeyForValue:[AiSettingsTools stringFromValue:value]];
            if (!storageValue) {
                completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                 localize(@"ai.settings.invalid_graphics_api", nil)}]);
                return;
            }
        } else {
            storageValue = [AiSettingsTools stringFromValue:value];
        }

        NSString *profileName = [AiSettingsTools profileNameForParams:params];
        NSMutableDictionary *prof = [AiSettingsTools profileDictionaryForName:profileName];
        if (!prof) {
            completion(nil, [NSError errorWithDomain:@"AiTool" code:404
                                         userInfo:@{NSLocalizedDescriptionKey:
                                             [NSString stringWithFormat:localize(@"ai.settings.instance_missing_fmt", nil), profileName]}]);
            return;
        }

        // 深拷贝后写回并保存（避免直接改动共享字典引发竞态）
        NSMutableDictionary *mutable = [prof mutableCopy];
        mutable[profileField] = storageValue;
        [PLProfiles.current.profiles setObject:mutable forKey:profileName];
        [PLProfiles.current save];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];

        NSString *display = storageValue;
        if ([key isEqualToString:@"video.renderer"]) {
            display = [AiSettingsTools rendererFriendlyName:storageValue];
        }
        completion([NSString stringWithFormat:localize(@"ai.settings.set_instance_fmt", nil),
                    profileName, key, display], nil);
        return;
    }

    // ---- 全局键：写入 LauncherPreferences ----
    if ([key isEqualToString:@"java.allocated_memory"]) {
        setPrefObject(@"java.allocated_memory", @([value integerValue]));
    } else if ([key isEqualToString:@"java.auto_ram"]) {
        NSString *desc = [value isKindOfClass:[NSString class]] ? (NSString *)value : [value description];
        BOOL on = [desc.lowercaseString hasPrefix:@"t"] || [desc isEqualToString:@"1"] || [desc isEqualToString:@"yes"];
        setPrefObject(@"java.auto_ram", @(on));
    } else if ([key isEqualToString:@"general.game_directory"]) {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         localize(@"ai.settings.game_dir_readonly", nil)}]);
        return;
    } else if ([key isEqualToString:@"general.download_source"] ||
               [key isEqualToString:@"java.java_args"] ||
               [key isEqualToString:@"control.default_ctrl"]) {
        setPrefObject(key, [AiSettingsTools stringFromValue:value]);
    } else {
        completion(nil, [NSError errorWithDomain:@"AiTool" code:400
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:localize(@"ai.settings.unsupported_key_fmt", nil), key]}]);
        return;
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    completion([NSString stringWithFormat:localize(@"ai.settings.set_global_fmt", nil), key, [AiSettingsTools stringFromValue:value]], nil);
}

@end
