#import "PLMirrorCenter.h"
#import "LauncherPreferences.h"

#pragma mark - 公开常量（全工程唯一定义处）

/// BMCLAPI 镜像根地址
NSString *const PLMirrorBMCLAPIRootURL = @"https://bmclapi2.bangbang93.com";

/// MCIM 镜像根地址（参考 ZalithLauncher 2 MCIMMirror.kt）
NSString *const PLMirrorMCIMRootURL = @"https://mod.mcimirror.top";

#pragma mark - 偏好键

/// 新版分资源类型策略键（值 official_first / mirror_first）
static NSString *const kPrefFileSource = @"download.fileSource";
static NSString *const kPrefAssetSearchSource = @"download.assetSearchSource";
static NSString *const kPrefAssetDownloadSource = @"download.assetDownloadSource";
static NSString *const kPrefModLoaderSource = @"download.modLoaderSource";

/// 旧版全局下载源键（official / bmclapi / mcim），为 Phase 4 设置项迁移预留回退
static NSString *const kPrefLegacyDownloadSource = @"general.download_source";

@implementation PLMirrorCenter

#pragma mark - 映射表

/// BMCLAPI 官方前缀 → 镜像前缀映射表（顺序敏感：最长前缀优先）
///
/// 参考 ZalithLauncher 2 BMCLAPI.kt 的 REPLACE_MIRROR_HOLDERS 与 Prisma 现有
/// MinecraftResourceDownloadTask.m replaceURLWithDownloadSource:forceSource: 的已验证行为。
+ (NSArray<NSArray<NSString *> *> *)bmclapiPrefixPairs {
    static NSArray<NSArray<NSString *> *> *pairs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pairs = @[
            // Mojang 版本清单 / 版本 JSON（piston-meta / piston-data 为 1.19+ 新域名）
            @[@"https://launchermeta.mojang.com", PLMirrorBMCLAPIRootURL],
            @[@"https://piston-meta.mojang.com", PLMirrorBMCLAPIRootURL],
            @[@"https://piston-data.mojang.com", PLMirrorBMCLAPIRootURL],
            @[@"https://launcher.mojang.com", PLMirrorBMCLAPIRootURL],
            // Mojang 库文件 → /maven（Prisma 现有已验证行为）
            @[@"https://libraries.minecraft.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // Mojang 资产资源 → /assets（数量巨大，MirrorFirst 时仍强制官方优先以减轻镜像压力）
            @[@"http://resources.download.minecraft.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/assets"]],
            @[@"https://resources.download.minecraft.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/assets"]],
            // Forge：Prisma 现有行为整体替换到根，官方 /maven 路径自然映射到根下 /maven
            @[@"https://files.minecraftforge.net", PLMirrorBMCLAPIRootURL],
            @[@"http://files.minecraftforge.net", PLMirrorBMCLAPIRootURL],
            @[@"https://maven.minecraftforge.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // NeoForge：官方 artifact 路径含 /releases 而 BMCLAPI 不含，
            // 必须先吸收 /releases 段（参考 ZL2 / HMCL），故此条目须列在通用条目之前
            @[@"https://maven.neoforged.net/releases", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            @[@"https://maven.neoforged.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // Fabric：meta → /fabric-meta（参考 ZL2），maven → /maven
            @[@"https://meta.fabricmc.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/fabric-meta"]],
            @[@"https://maven.fabricmc.net", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
            // Quilt：meta → /quilt-meta，maven → /maven（BMCLAPI 标准映射）
            @[@"https://meta.quiltmc.org", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/quilt-meta"]],
            @[@"https://maven.quiltmc.org", [PLMirrorBMCLAPIRootURL stringByAppendingString:@"/maven"]],
        ];
    });
    return pairs;
}

/// MCIM 官方前缀 → 镜像前缀映射表
///
/// 保持 Prisma MCIMMirror.m 现有精确行为：API 域名加平台前缀（/modrinth、/curseforge），
/// CDN 域名做简单主机替换到 MCIM 根（无平台前缀，参考 ZL2 MCIMMirror.kt）。
+ (NSArray<NSArray<NSString *> *> *)mcimPrefixPairs {
    static NSArray<NSArray<NSString *> *> *pairs = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        pairs = @[
            // Modrinth API：https://api.modrinth.com/v2/... → https://mod.mcimirror.top/modrinth/v2/...
            @[@"https://api.modrinth.com", [PLMirrorMCIMRootURL stringByAppendingString:@"/modrinth"]],
            // CurseForge API：https://api.curseforge.com/v1/... → https://mod.mcimirror.top/curseforge/v1/...
            @[@"https://api.curseforge.com", [PLMirrorMCIMRootURL stringByAppendingString:@"/curseforge"]],
            // Modrinth CDN：简单主机替换，不加平台前缀（与 MCIMMirror.m 现有行为一致）
            @[@"https://cdn.modrinth.com", PLMirrorMCIMRootURL],
            // CurseForge CDN：简单主机替换，不加平台前缀（与 MCIMMirror.m 中 edge / media 行为一致）
            @[@"https://edge.forgecdn.net", PLMirrorMCIMRootURL],
            @[@"https://mediafilez.forgecdn.net", PLMirrorMCIMRootURL],
            @[@"https://media.forgecdn.net", PLMirrorMCIMRootURL],
        ];
    });
    return pairs;
}

/// 在映射表中查找并替换前缀，返回镜像 URL 字符串；无匹配返回 nil
+ (nullable NSString *)mirrorURLStringForOriginalURLString:(NSString *)urlString
                                               prefixPairs:(NSArray<NSArray<NSString *> *> *)pairs {
    for (NSArray<NSString *> *pair in pairs) {
        NSString *origin = pair.firstObject;
        NSString *mirror = pair.lastObject;
        // 要求前缀后紧跟 "/"，避免误匹配同前缀的其它主机名
        if ([urlString hasPrefix:[origin stringByAppendingString:@"/"]]) {
            return [mirror stringByAppendingString:[urlString substringFromIndex:origin.length]];
        }
    }
    return nil;
}


#pragma mark - Task 138 加载速度快优先（FCL 式测速）

/// 测速体系（两大镜像体系各一条竞速赛道）
typedef NS_ENUM(NSInteger, PLMirrorSpeedFamily) {
    /// BMCLAPI vs Mojang（GameFile + ModLoader）
    PLMirrorSpeedFamilyBMCLAPI = 0,
    /// MCIM vs Modrinth/CurseForge（AssetSearch + AssetDownload）
    PLMirrorSpeedFamilyMCIM = 1,
};

/// 测速缓存有效期（秒）：24 小时内复用上一次结果
static const NSTimeInterval kAme138ProbeTTL = 24 * 3600.0;
/// 测速请求超时：4 秒（超时即负，对手直接获胜）
static const NSTimeInterval kAme138ProbeTimeout = 4.0;

/// 内存缓存：family -> @{@"winner": ..., @"ts": ...}
static NSMutableDictionary<NSNumber *, NSDictionary *> *ame138_probeMemo = nil;
/// 探测在跑标志：防止重复发起
static BOOL ame138_probeInFlight[2] = {NO, NO};

/// 资源类型 -> 测速体系
+ (PLMirrorSpeedFamily)ame138_familyForType:(PLMirrorResourceType)type {
    switch (type) {
        case PLMirrorResourceTypeGameFile:
        case PLMirrorResourceTypeModLoader:
            return PLMirrorSpeedFamilyBMCLAPI;
        case PLMirrorResourceTypeAssetSearch:
        case PLMirrorResourceTypeAssetDownload:
            return PLMirrorSpeedFamilyMCIM;
    }
    return PLMirrorSpeedFamilyBMCLAPI;
}

/// 体系 -> 持久化键（download.speed_probe.bmclapi / .mcim）
+ (NSString *)ame138_probePrefKeyForFamily:(PLMirrorSpeedFamily)family {
    return family == PLMirrorSpeedFamilyBMCLAPI
        ? @"download.speed_probe.bmclapi"
        : @"download.speed_probe.mcim";
}

/// 体系 -> 探测端点（官方 / 镜像）。根路径 GET 的响应体极小，测的是
/// DNS + TCP + TLS + 首包 RTT——正是下载体验的主导成本。
+ (NSArray<NSURL *> *)ame138_probeEndpointsForFamily:(PLMirrorSpeedFamily)family {
    if (family == PLMirrorSpeedFamilyBMCLAPI) {
        return @[
            [NSURL URLWithString:@"https://piston-meta.mojang.com/"],
            [NSURL URLWithString:@"https://bmclapi2.bangbang93.com/"]
        ];
    }
    return @[
        [NSURL URLWithString:@"https://api.modrinth.com/"],
        [NSURL URLWithString:@"https://mod.mcimirror.top/"]
    ];
}

/// 读缓存赢家（内存 -> 偏好持久层），过期返回 nil。纯读，不发起探测。
+ (nullable NSString *)ame138_cachedWinnerForFamily:(PLMirrorSpeedFamily)family {
    NSNumber *ame138_key = @(family);
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        ame138_probeMemo = [NSMutableDictionary dictionary];
    });
    NSDictionary *ame138_entry = ame138_probeMemo[ame138_key];
    if (!ame138_entry) {
        ame138_entry = getPrefObject([self ame138_probePrefKeyForFamily:family]);
        if ([ame138_entry isKindOfClass:NSDictionary.class]) {
            ame138_probeMemo[ame138_key] = ame138_entry;
        }
    }
    if (![ame138_entry isKindOfClass:NSDictionary.class]) return nil;
    NSString *ame138_winner = ame138_entry[@"winner"];
    NSNumber *ame138_ts = ame138_entry[@"ts"];
    if (![ame138_winner isKindOfClass:NSString.class] || ![ame138_ts isKindOfClass:NSNumber.class]) {
        return nil;
    }
    if (fabs([ame138_ts doubleValue] - [[NSDate date] timeIntervalSince1970]) > kAme138ProbeTTL) {
        return nil;
    }
    return ame138_winner;
}

/// 资源类型视角的缓存赢家
+ (nullable NSString *)ame138_speedWinnerForType:(PLMirrorResourceType)type {
    return [self ame138_cachedWinnerForFamily:[self ame138_familyForType:type]];
}

/// 需要时发起该体系的探测（结果未落地 / 在跑标志清零）
+ (void)ame138_kickProbeIfNeededForType:(PLMirrorResourceType)type {
    [self ame138_startProbeForFamily:[self ame138_familyForType:type]];
}

+ (void)ame138_startProbeForFamily:(PLMirrorSpeedFamily)family {
    if (ame138_probeInFlight[family]) return;
    if ([self ame138_cachedWinnerForFamily:family] != nil) return;
    ame138_probeInFlight[family] = YES;

    NSArray<NSURL *> *ame138_endpoints = [self ame138_probeEndpointsForFamily:family];
    NSURL *ame138_official = ame138_endpoints.firstObject;
    NSURL *ame138_mirror = ame138_endpoints.lastObject;

    /// 单端竞速：完成（成功或失败）即回调耗时（失败为 DBL_MAX）
    void (^ame138_race)(NSURL *, void (^)(double)) = ^(NSURL *url, void (^done)(double)) {
        NSURLSessionConfiguration *ame138_cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        ame138_cfg.timeoutIntervalForRequest = kAme138ProbeTimeout;
        ame138_cfg.timeoutIntervalForResource = kAme138ProbeTimeout + 1.0;
        ame138_cfg.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSURLSession *ame138_session = [NSURLSession sessionWithConfiguration:ame138_cfg];
        CFAbsoluteTime ame138_t0 = CFAbsoluteTimeGetCurrent();
        NSURLSessionDataTask *ame138_task = [ame138_session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error != nil) {
                done(DBL_MAX);
            } else {
                done(CFAbsoluteTimeGetCurrent() - ame138_t0);
            }
            [ame138_session finishTasksAndInvalidate];
        }];
        [ame138_task resume];
    };

    // 结算走专用串行队列：两个 dataTask 回调来自不同 session 队列，
    // 直接写共享标志存在数据竞争（曾会让 in-flight 标志永久卡死）。
    dispatch_queue_t ame138_settleQueue =
        dispatch_queue_create("ame138.probe.settle", DISPATCH_QUEUE_SERIAL);
    __block double ame138_officialMs = -1;
    __block double ame138_mirrorMs = -1;

    void (^ame138_settle)(void) = ^{
        if (ame138_officialMs < 0 || ame138_mirrorMs < 0) return;
        NSString *ame138_winner = nil;
        if (ame138_officialMs < ame138_mirrorMs) {
            ame138_winner = @"official";
        } else if (ame138_mirrorMs < ame138_officialMs) {
            ame138_winner = @"mirror";
        } // 双失败（均为 DBL_MAX）不落库，下次再测
        if (ame138_winner != nil) {
            NSDictionary *ame138_entry = @{
                @"winner": ame138_winner,
                @"ts": @([[NSDate date] timeIntervalSince1970])
            };
            ame138_probeMemo[@(family)] = ame138_entry;
            setPrefObject([self ame138_probePrefKeyForFamily:family], ame138_entry);
            NSLog(@"[PLMirrorCenter] Task138 speed probe (family=%ld): %@ won "
                  @"(official=%.0fms mirror=%.0fms)",
                  (long)family, ame138_winner, ame138_officialMs * 1000, ame138_mirrorMs * 1000);
        }
        ame138_probeInFlight[family] = NO;
    };

    ame138_race(ame138_official, ^(double ms) {
        dispatch_async(ame138_settleQueue, ^{
            ame138_officialMs = ms;
            ame138_settle();
        });
    });
    ame138_race(ame138_mirror, ^(double ms) {
        dispatch_async(ame138_settleQueue, ^{
            ame138_mirrorMs = ms;
            ame138_settle();
        });
    });
}

+ (void)startSpeedProbesIfNeeded {
    // 任意体系当前策略为 speed_first 且缓存缺失/过期时补测
    NSArray<NSNumber *> *ame138_types = @[
        @(PLMirrorResourceTypeGameFile),
        @(PLMirrorResourceTypeAssetSearch)
    ];
    for (NSNumber *ame138_t in ame138_types) {
        if ([self policyForType:ame138_t.integerValue] == PLMirrorPolicySpeedFirst) {
            [self ame138_startProbeForFamily:[self ame138_familyForType:ame138_t.integerValue]];
        }
    }
}

#pragma mark - 公开 API

+ (NSArray<NSURL *> *)candidateURLsForOriginalURL:(NSURL *)originalURL
                                     resourceType:(PLMirrorResourceType)type {
    if (!originalURL) return @[];

    NSString *urlString = originalURL.absoluteString;

    // 资产资源文件数量巨大：即使镜像优先也保持官方在前，减轻镜像源压力（参考 ZL2）
    BOOL isAssetsFile = ([urlString hasPrefix:@"http://resources.download.minecraft.net/"] ||
                         [urlString hasPrefix:@"https://resources.download.minecraft.net/"]);

    NSString *mirrorURLString = nil;
    switch (type) {
        case PLMirrorResourceTypeGameFile:
        case PLMirrorResourceTypeModLoader:
            mirrorURLString = [self mirrorURLStringForOriginalURLString:urlString
                                                           prefixPairs:[self bmclapiPrefixPairs]];
            break;
        case PLMirrorResourceTypeAssetSearch:
        case PLMirrorResourceTypeAssetDownload:
            mirrorURLString = [self mirrorURLStringForOriginalURLString:urlString
                                                           prefixPairs:[self mcimPrefixPairs]];
            break;
    }

    // 无法识别的主机（或已是镜像 URL / 重写后与原始相同）：原样返回仅含原始 URL 的数组
    if (mirrorURLString.length == 0 || [mirrorURLString isEqualToString:urlString]) {
        return @[originalURL];
    }

    NSURL *mirrorURL = [NSURL URLWithString:mirrorURLString];
    if (!mirrorURL) return @[originalURL];

    PLMirrorPolicy policy = [self policyForType:type];
    if (isAssetsFile && policy != PLMirrorPolicySpeedFirst) {
        // 资产资源数量巨大：镜像优先档保持官方在前以减轻镜像源压力
        // （参考 ZL2）；speed_first 档按用户明确意图跟随测速结果。
        policy = PLMirrorPolicyOfficialFirst;
    }

    if (policy == PLMirrorPolicySpeedFirst) {
        // Task 138：按测速赢家排序；结果未落地前临时镜像在前（CN 用户
        // 群体镜像几乎恒快，竞速完成后自动纠正），同时确保探测在跑。
        [self ame138_kickProbeIfNeededForType:type];
        NSString *ame138_winner = [self ame138_speedWinnerForType:type];
        if ([ame138_winner isEqualToString:@"official"]) {
            return @[originalURL, mirrorURL];
        }
        return @[mirrorURL, originalURL];
    }
    if (policy == PLMirrorPolicyMirrorFirst) {
        return @[mirrorURL, originalURL];
    }
    return @[originalURL, mirrorURL];
}

+ (NSURL *)preferredURLForOriginalURL:(NSURL *)url
                         resourceType:(PLMirrorResourceType)type {
    return [self candidateURLsForOriginalURL:url resourceType:type].firstObject ?: url;
}

+ (NSString *)modrinthAPIBaseURL {
    PLMirrorPolicy ame138_policy = [self policyForType:PLMirrorResourceTypeAssetSearch];
    if (ame138_policy == PLMirrorPolicyMirrorFirst) {
        return [NSString stringWithFormat:@"%@/modrinth/v2", PLMirrorMCIMRootURL];
    }
    if (ame138_policy == PLMirrorPolicySpeedFirst) {
        [self ame138_kickProbeIfNeededForType:PLMirrorResourceTypeAssetSearch];
        NSString *ame138_winner = [self ame138_speedWinnerForType:PLMirrorResourceTypeAssetSearch];
        if ([ame138_winner isEqualToString:@"official"]) {
            return @"https://api.modrinth.com/v2";
        }
        return [NSString stringWithFormat:@"%@/modrinth/v2", PLMirrorMCIMRootURL];
    }
    return @"https://api.modrinth.com/v2";
}

+ (NSString *)curseForgeAPIBaseURL {
    PLMirrorPolicy ame138_policy = [self policyForType:PLMirrorResourceTypeAssetSearch];
    if (ame138_policy == PLMirrorPolicyMirrorFirst) {
        return [NSString stringWithFormat:@"%@/curseforge/v1", PLMirrorMCIMRootURL];
    }
    if (ame138_policy == PLMirrorPolicySpeedFirst) {
        [self ame138_kickProbeIfNeededForType:PLMirrorResourceTypeAssetSearch];
        NSString *ame138_winner = [self ame138_speedWinnerForType:PLMirrorResourceTypeAssetSearch];
        if ([ame138_winner isEqualToString:@"official"]) {
            return @"https://api.curseforge.com/v1";
        }
        return [NSString stringWithFormat:@"%@/curseforge/v1", PLMirrorMCIMRootURL];
    }
    return @"https://api.curseforge.com/v1";
}

// Task162：MCIM CurseForge 镜像基址（唯一定义处；无 key 设备的强制回落目标）。
+ (NSString *)mcimCurseForgeAPIBaseURL {
    return [NSString stringWithFormat:@"%@/curseforge/v1", PLMirrorMCIMRootURL];
}

+ (PLMirrorPolicy)policyForType:(PLMirrorResourceType)type {
    // 优先读取新版分资源类型策略键（值 official_first / mirror_first）
    NSString *key = nil;
    switch (type) {
        case PLMirrorResourceTypeGameFile:
            key = kPrefFileSource;
            break;
        case PLMirrorResourceTypeAssetSearch:
            key = kPrefAssetSearchSource;
            break;
        case PLMirrorResourceTypeAssetDownload:
            key = kPrefAssetDownloadSource;
            break;
        case PLMirrorResourceTypeModLoader:
            key = kPrefModLoaderSource;
            break;
    }
    NSString *value = getPrefObject(key);
    if ([value isKindOfClass:[NSString class]]) {
        if ([value isEqualToString:@"official_first"]) return PLMirrorPolicyOfficialFirst;
        if ([value isEqualToString:@"mirror_first"]) return PLMirrorPolicyMirrorFirst;
        // Task 138：加载速度快优先（参考 FCL 的下载源测速策略）
        if ([value isEqualToString:@"speed_first"]) return PLMirrorPolicySpeedFirst;
    }

    // 回退旧键 general.download_source：official → 官方优先，bmclapi / mcim → 镜像优先
    NSString *legacy = getPrefObject(kPrefLegacyDownloadSource);
    if ([legacy isKindOfClass:[NSString class]]) {
        if ([legacy isEqualToString:@"official"]) return PLMirrorPolicyOfficialFirst;
        if ([legacy isEqualToString:@"bmclapi"] || [legacy isEqualToString:@"mcim"]) {
            return PLMirrorPolicyMirrorFirst;
        }
    }

    // 默认官方优先
    return PLMirrorPolicyOfficialFirst;
}

#pragma mark - Task218 双轨收敛辅助

/// Task218：镜像偏好的体系化布尔判定（头文件注释见 PLMirrorCenter.h）。
/// 病历（用户主诉"下载源设置外面显示的是用户选择过的，里面莫名其妙被
/// 启动器改了"）：Task138 重构后全工程留下两套并行的"下载源"判定——
/// 新版分类镜像策略键（download.fileSource 等四个，值 official_first /
/// mirror_first / speed_first）与旧版全局键 general.download_source（值
/// official / bmclapi，迁移后冻结不再有人写）。旧键消费者（根页/卡片页
/// 版本清单的 bmclapi-vs-官方硬切换、IconLoader 图标镜像开关、七处下载
/// 任务来源标签）永远读冻结的旧值 = 设置页里选什么都不生效，行为停留在
/// 迁移那一刻的旧值上——用户眼中的"被启动器改了"。本方法把布尔判定
/// 收敛到策略层，旧键自此只剩 policyForType 的回退链一处消费者。
+ (BOOL)mirrorPreferredForType:(PLMirrorResourceType)type {
    PLMirrorPolicy policy = [self policyForType:type];
    if (policy == PLMirrorPolicyMirrorFirst) return YES;
    if (policy == PLMirrorPolicyOfficialFirst) return NO;
    // speed_first：跟随测速赢家；结果未落地时镜像在前（与 candidateURLs
    // 的临时序一致，测速完成后自动纠正）。
    NSString *winner = [self ame138_speedWinnerForType:type];
    return ![winner isEqualToString:@"official"];
}

/// Task218：镜像策略 -> 旧式下载源 token（official / bmclapi）。
/// 仅供 DownloadTaskItem.downloadSource 这类历史显示字段适配，禁止用于
/// 路由决策（路由必须走 candidateURLsForOriginalURL / policyForType）。
+ (NSString *)legacySourceTokenForType:(PLMirrorResourceType)type {
    return [self mirrorPreferredForType:type] ? @"bmclapi" : @"official";
}

@end
