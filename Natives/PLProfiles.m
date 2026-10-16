//
//  PLProfiles.m
//  Amethyst
//
//  Profile manager with JSON-safe save
//

#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

static PLProfiles* current;

@interface PLProfiles()
@end

@implementation PLProfiles

+ (id)defaultProfiles {
    return @{
        @"profiles": @{
            @"(Default)": @{
                @"name": @"(Default)",
                @"lastVersionId": @"latest-release"
            }
        },
        @"selectedProfile": @"(Default)"
    }.mutableCopy;
}

+ (PLProfiles *)current {
    // ★ Task274-h S3：单例创建/整体替换本身收进类锁——两线程同见 nil 会双建实例
    // （后建者胜，先建实例上未落盘的写全部丢失）。updateCurrent 供会话中重载
    // （AI 安装流等），原子性同样由类锁保证。锁序：类锁 → 实例锁（init 内 save），
    // 实例方法从不回调 +current/+updateCurrent，无环。
    @synchronized (self) {
        if (!current) {
            [self updateCurrent];
        }
        return current;
    }
}

+ (void)updateCurrent {
    @synchronized (self) {
        current = [[PLProfiles alloc] initWithCurrentInstance];
    }
}

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key {
    id rawValue = profile[key];
    // 兼容 javaVersion 字段：Mojang 规范是 NSDictionary（{component, majorVersion}），
    // 但部分代码（如 ForgeDirectInstaller）也写入 NSDictionary。PLProfiles 期望返回 NSString。
    if ([rawValue isKindOfClass:[NSDictionary class]]) {
        // javaVersion: 返回 majorVersion 的字符串值；缺失则落入下方 valueDefaults
        id major = rawValue[@"majorVersion"];
        if (major) return [major description];
        // 落入下方 valueDefaults 逻辑，避免返回 nil 破坏调用方
    } else if ([rawValue isKindOfClass:[NSString class]] && [(NSString *)rawValue length] > 0) {
        return rawValue;
    }

    NSDictionary *valueDefaults = @{
        @"javaVersion": @"0",
        // LWJGL 版本："auto" = MC 26.x 及以上用 3.4.1，其余用 3.3.3。
        // profile 里显式存 "333"/"341" 时以显式值为准。
        @"lwjglVersion": @"auto",
        @"gameDir": @"."
    };
    if (valueDefaults[key]) {
        return valueDefaults[key];
    }

    NSDictionary *prefDefaults = @{
        @"defaultTouchCtrl": @"control.default_ctrl",
        @"defaultGamepadCtrl": @"control.default_gamepad_ctrl",
        @"javaArgs": @"java.java_args",
        // Task159：分辨率缩放实例化（与上方退役的 renderer 回退同款机制，
        // [可撤销]）——profile 有 resolution 键（NSString）→ 实例显式值；
        // 无键 → 回退全局 video.resolution（存量设备平滑：全局行虽从设置页
        // 移除，存量值仍生效，直到用户在实例里显式设置）。撤销 = 删本行 +
        // 恢复设置页全局行。
        @"resolution": @"video.resolution",
        // Task 150（[可撤销] 删除渲染器全局控制）：renderer 的全局回退键退役
        // ——每个实例强制单独选择渲染器，profile 无 renderer 键时由
        // ame_effective_renderer 落到 "auto"（用户确认的缺省），不再读取
        // 全局 video.renderer（该键随设置页渲染器行一并退役，仅存量设备
        // 偏好文件中残留、无读取方）。撤销 = 恢复本行映射 + 设置页行。
        // @"renderer": @"video.renderer",
        // MC 26.2+ Graphics API（OpenGL/Vulkan 游戏内切换），缺省为 "default"
        // 该字段仅在 MC 26.2+ 生效，旧版本会被 MC 忽略，无副作用。
        @"graphicsApi": @"video.graphics_api"
    };
    // Task 150：nil 守卫——映射里没有的键（如退役后的 renderer）直接返回
    // nil（getPrefObject(nil) 会抛 NSInvalidArgumentException）
    id prefKey = prefDefaults[key];
    return prefKey ? getPrefObject(prefKey) : nil;
}

+ (id)resolveKeyForCurrentProfile:(id)key {
    return [self profile:self.current.selectedProfile resolveKey:key];
}

- (id)initWithCurrentInstance {
    self = [super init];
    self.profilePath = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:@"launcher_profiles.json"];
    self.profileDict = parseJSONFromFile(self.profilePath);
    if (self.profileDict[@"NSErrorObject"]) {
        self.profileDict = PLProfiles.defaultProfiles;
        [self save];
    }

    return self;
}

- (id)profiles {
    // ★ Task274-h S3：惰性可变换 + 读全部收进实例锁（写方 saveProfile/save 同锁，
    // 消除跨线程 NSMutableDictionary 结构竞态）。返回的仍是活字典（外部直接
    // 变更方依赖该语义，本轮不改变）。
    @synchronized (self) {
        id profiles = self.profileDict[@"profiles"];
        if (![profiles isKindOfClass:[NSDictionary class]]) {
            profiles = [NSMutableDictionary dictionary];
            self.profileDict[@"profiles"] = profiles;
        } else if (![profiles isKindOfClass:[NSMutableDictionary class]]) {
            profiles = [profiles mutableCopy];
            self.profileDict[@"profiles"] = profiles;
        }
        return profiles;
    }
}

- (id)selectedProfile {
    return self.profiles[self.selectedProfileName];
}

- (NSString *)selectedProfileName {
    @synchronized (self) {
        return (id)self.profileDict[@"selectedProfile"];
    }
}

- (void)setSelectedProfileName:(NSString *)name {
    // ★ Task274-h S3：字典写 + save 收进实例锁；SelectedProfileChanged 通知必须发在
    //   锁外——观察者可能同步重入 PLProfiles，锁内发通知构成重入/他线程等待死锁面。
    @synchronized (self) {
        self.profileDict[@"selectedProfile"] = (id)name;
        [self save];
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:name];
}

/// 递归清理 NSDate 等非法 JSON 类型，确保保存不崩溃
- (id)jsonSanitizedObject:(id)obj {
    if ([obj isKindOfClass:[NSDate class]]) {
        static NSDateFormatter *formatter = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            formatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        });
        return [formatter stringFromDate:obj];
    } else if ([obj isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *clean = [NSMutableDictionary dictionaryWithCapacity:[obj count]];
        [obj enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            // ★ Task274-h S9：非字符串键统一走清洗（NSDate→ISO 串、NSURL→absoluteString、
            //   其余→description）——JSON 对象键必须为字符串，此前仅 NSDate 键被处理。
            id safeKey = [key isKindOfClass:[NSString class]] ? key : [self jsonSanitizedObject:key];
            clean[safeKey] = [self jsonSanitizedObject:val];
        }];
        return clean;
    } else if ([obj isKindOfClass:[NSArray class]]) {
        NSMutableArray *clean = [NSMutableArray arrayWithCapacity:[obj count]];
        for (id item in obj) {
            [clean addObject:[self jsonSanitizedObject:item]];
        }
        return clean;
    } else if ([obj isKindOfClass:[NSURL class]]) {
        // ★ Task274-h S9：NSURL 安全化（JSON 非法类型，整树枚举时一并转字符串）
        return [obj absoluteString] ?: @"";
    }
    // ★ Task274-h S9：兜底——未知类型（NSSet/NSValue/NSNull 等）转 NSString 描述，
    //   绝不抛异常；此前直透传 → isValidJSONObject 失败 → 整次保存被静默丢弃。
    return [obj description] ?: @"";
}

- (void)save {
    // ★ Task274-h S3：全树遍历（jsonSanitizedObject 递归枚举）+ 落盘整体在实例锁内，
    //   防并发变更打断枚举（枚举中字典被改 = 崩溃面）。
    @synchronized (self) {
        id sanitized = [self jsonSanitizedObject:self.profileDict];
        if ([NSJSONSerialization isValidJSONObject:sanitized]) {
            saveJSONToFile(sanitized, self.profilePath);
        } else {
            // ★ Task274-h S9：失败路径可见日志（带上下文+键数量）——此前仅一句
            //   固定文案，isValidJSONObject 不过时整次保存被静默丢弃无从排查。
            NSDictionary *ame274_profiles = ([self.profileDict isKindOfClass:[NSDictionary class]]
                ? self.profileDict[@"profiles"] : nil);
            NSLog(@"[PLProfiles] SAVE FAILED: profileDict still contains invalid JSON types after sanitization"
                  @" (topLevelKeys=%@, profileCount=%ld, selectedProfile=%@, path=%@)",
                  ([self.profileDict isKindOfClass:[NSDictionary class]] ? [self.profileDict allKeys] : nil),
                  (long)([ame274_profiles isKindOfClass:[NSDictionary class]] ? [(NSDictionary *)ame274_profiles count] : -1),
                  self.profileDict[@"selectedProfile"],
                  self.profilePath);
        }
    }
}

- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name {
    // ★ Task274-h S3：读-合并-写全程在实例锁内（save 为同锁可重入）——后台安装器
    //   并发 saveProfile 与主线程读之间此前零锁。
    @synchronized (self) {
    if (!self.profileDict[@"profiles"]) {
        self.profileDict[@"profiles"] = [NSMutableDictionary dictionary];
    }
    // ★ Task271（271-a RC1 根修·自适应恢复）：saveProfile 从【整条替换】改为
    //   【合并覆盖】。旧语义 = 新字典整体顶掉旧条目——同名重装/更新（下载页
    //   Fabric/Quilt、下载页/实例页 OptiFine、AI 安装流等只写部分字段的写入方）
    //   会把既有条目的 gameDir（版本隔离）/icon/javaArgs/renderer/graphicsApi/
    //   jvm_preset/touchController/allocatedMemory/memoryAuto/resolution/serverIp
    //   等全部静默抹掉：用户视角"实例的模组列表变成了共享目录"。合并语义：
    //   既有键保留、新键覆盖同名键——安装器想写的字段照写，其余实例设置原样
    //   存活；全新条目（无同名旧档）行为与旧版一致。
    NSMutableDictionary *ame271_merged =
        [self.profileDict[@"profiles"][name] isKindOfClass:[NSDictionary class]]
            ? [NSMutableDictionary dictionaryWithDictionary:self.profileDict[@"profiles"][name]]
            : [NSMutableDictionary dictionary];
    for (NSString *ame271_key in profile) {
        id ame271_val = profile[ame271_key];
        if (ame271_val == nil) continue;
        ame271_merged[ame271_key] = ame271_val;
    }
    self.profileDict[@"profiles"][name] = ame271_merged;
    [self save];
    }
}

// ★ Task275 F6：锁内批量变更 API（声明见 .h）。
- (void)applyChanges:(void (NS_NOESCAPE ^)(NSMutableDictionary<NSString *, id> *profiles))changes {
    if (!changes) return;
    @synchronized (self) {
        id profiles = self.profileDict[@"profiles"];
        if (![profiles isKindOfClass:[NSMutableDictionary class]]) {
            profiles = [NSMutableDictionary dictionary];
            self.profileDict[@"profiles"] = profiles;
        }
        changes(profiles);
        [self save];   // 同锁可重入（saveProfile 先例）
    }
}

#pragma mark - 服务器地址（FCL 风格：启动后自动加入服务器）

// 获取当前选中 profile 的服务器地址，留空返回 @""
- (NSString *)serverIpForCurrentProfile {
    return [self serverIpForProfile:self.selectedProfileName];
}

// 获取指定 profile 的服务器地址，缺失或为空均返回 @""
- (NSString *)serverIpForProfile:(NSString *)profileName {
    @synchronized (self) {
        NSString *ip = self.profiles[profileName][@"serverIp"];
        return ip ?: @"";
    }
}

// 设置指定 profile 的服务器地址，nil 转为 @""
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName {
    @synchronized (self) {
        NSMutableDictionary *profile = [self.profiles[profileName] mutableCopy];
        if (!profile) {
            profile = [NSMutableDictionary dictionary];
        }
        profile[@"serverIp"] = serverIp ?: @"";
        self.profiles[profileName] = profile;
        [self save];
    }
}

@end
