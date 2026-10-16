//
//  AiInstancesTool.m
//  Prisma
//

#import "AiInstancesTool.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "../utils.h"   // Task271-e：结果/错误文案 i18n 接线需要 localize()

@interface AiInstancesTool ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiInstancesTool

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"list_game_versions"]) {
        return @"拉取 Minecraft Java 版的真实版本列表（默认只返回正式版 release，避免快照等版本过多占用上下文）。"
               "\n参数：includeSnapshots（boolean，可选，默认 false；为 true 时额外附加最新一条快照版本）。"
               "\n说明：默认从 BMCLAPI 镜像获取版本清单，失败自动切换官方源重试；返回每个版本的 id（版本号）与 type（release/snapshot）。"
               "\n内部有 30 分钟缓存（保存在 Documents/AI/game_versions.json，缓存完整清单）。"
               "\n边界：若网络失败会返回错误信息，不会编造版本号。"
               "\n示例：调用后得到 [{'id':'1.21.1','type':'release'}, ...]";
    }
    // list_instances
    return @"列出启动器中已创建的游戏实例（即游戏目录下的版本/目录）。"
           "\n无参数。"
           "\n说明：每个实例项包含 profile 名称 name、gameDir、lastVersionId、当前是否选中 selected、"
           "实例完整路径 path，以及已安装的 mods/resourcepacks/shaders/datapacks 数量（counts 子对象）。"
           "\n数据来源为 POJAV_HOME/instances/ 目录与 launcher_profiles.json 的 profiles。"
           "\n边界：实例目录不存在时回退返回当前实例信息。";
}

#pragma mark - 路径与常量

+ (NSString *)pojavHome {
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) return @(home);
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

+ (NSString *)instancesDirectory {
    return [[self pojavHome] stringByAppendingPathComponent:@"instances"];
}

+ (NSString *)currentInstanceName {
    NSString *name = getPrefObject(@"general.game_directory");
    return (name.length > 0) ? name : @"default";
}

+ (NSString *)currentGameRoot {
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return @(root);
    return [[self instancesDirectory] stringByAppendingPathComponent:[self currentInstanceName]];
}

#pragma mark - 资源计数

- (NSUInteger)countOfDirectory:(NSString *)dir {
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    NSUInteger count = 0;
    for (NSString *item in items) {
        if ([item hasPrefix:@"."]) continue;
        count++;
    }
    return count;
}

- (NSDictionary *)resourceCountsForDirectory:(NSString *)gameRoot {
    return @{
        @"mods": @([self countOfDirectory:[gameRoot stringByAppendingPathComponent:@"mods"]]),
        @"resourcepacks": @([self countOfDirectory:[gameRoot stringByAppendingPathComponent:@"resourcepacks"]]),
        @"shaders": @([self countOfDirectory:[gameRoot stringByAppendingPathComponent:@"shaderpacks"]]),
        @"datapacks": @([self countOfDirectory:[gameRoot stringByAppendingPathComponent:@"datapacks"]]),
    };
}

- (NSString *)jsonStringFromObject:(id)object {
    if ([NSJSONSerialization isValidJSONObject:object] == NO) return @"[]";
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    if (!data) return @"[]";
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

#pragma mark - 执行

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([self.internalName isEqualToString:@"list_game_versions"]) {
        BOOL includeSnapshots = NO;
        id v = params[@"includeSnapshots"];
        if ([v isKindOfClass:[NSString class]]) {
            NSString *s = [(NSString *)v lowercaseString];
            includeSnapshots = [s hasPrefix:@"t"] || [s isEqualToString:@"1"];
        } else if (v != nil && ![v isKindOfClass:[NSNull class]]) {
            includeSnapshots = [v boolValue];
        }
        [self performListGameVersionsIncludeSnapshots:includeSnapshots completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"list_instances"]) {
        [self performListInstances:completion];
        return;
    }

    NSError *err = [NSError errorWithDomain:@"AiTool" code:404
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.tools.unknown_tool_fmt", nil), self.internalName]}];
    completion(nil, err);
}

#pragma mark - list_instances

- (void)performListInstances:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *instancesDir = [[self class] instancesDirectory];
    NSString *currentInstanceName = [[self class] currentInstanceName];
    PLProfiles *profiles = [PLProfiles current];
    NSDictionary *profileDict = [profiles profiles];

    NSMutableArray *entries = [NSMutableArray array];

    // 列举 instances/ 下的子目录（每个实例 = 一个游戏目录）
    NSArray *subdirs = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:instancesDir error:nil];
    for (NSString *dirname in subdirs) {
        NSString *fullPath = [instancesDir stringByAppendingPathComponent:dirname];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:fullPath isDirectory:&isDir] == NO || !isDir) {
            continue;
        }
        if ([dirname hasPrefix:@"."]) continue;

        // 从 launcher_profiles.json 匹配 profile（按 name 匹配目录名）
        NSDictionary *profile = [profileDict isKindOfClass:[NSDictionary class]] ? profileDict[dirname] : nil;
        NSString *profileName = dirname;
        NSString *lastVersionId = @"";
        NSString *gameDir = @".";
        if ([profile isKindOfClass:[NSDictionary class]]) {
            if ([profile[@"name"] isKindOfClass:[NSString class]] && [profile[@"name"] length] > 0) profileName = profile[@"name"];
            if ([profile[@"lastVersionId"] isKindOfClass:[NSString class]]) lastVersionId = profile[@"lastVersionId"];
            if ([profile[@"gameDir"] isKindOfClass:[NSString class]] && [profile[@"gameDir"] length] > 0) gameDir = profile[@"gameDir"];
        }

        [entries addObject:@{
            @"name": profileName ?: dirname,
            @"gameDir": [fullPath stringByAppendingPathComponent:gameDir],
            @"lastVersionId": lastVersionId ?: @"",
            @"selected": @([dirname isEqualToString:currentInstanceName]),
            @"path": fullPath,
            @"counts": [self resourceCountsForDirectory:fullPath],
        }];
    }

    // 取不到实例目录时，回退返回当前实例信息
    if (entries.count == 0) {
        NSString *currentRoot = [[self class] currentGameRoot];
        [entries addObject:@{
            @"name": [profiles selectedProfileName] ?: currentInstanceName,
            @"gameDir": currentRoot,
            @"lastVersionId": [PLProfiles resolveKeyForCurrentProfile:@"lastVersionId"] ?: @"",
            @"selected": @YES,
            @"path": currentRoot,
            @"counts": [self resourceCountsForDirectory:currentRoot],
        }];
    }

    completion([self jsonStringFromObject:entries], nil);
}

#pragma mark - list_game_versions

/// 版本清单缓存目录：Documents/AI/game_versions.json（30 分钟有效）
- (NSString *)gameVersionsCachePath {
    NSString *aiDir = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
                       stringByAppendingPathComponent:@"AI"];
    [[NSFileManager defaultManager] createDirectoryAtPath:aiDir withIntermediateDirectories:YES attributes:nil error:nil];
    return [aiDir stringByAppendingPathComponent:@"game_versions.json"];
}

- (BOOL)isCacheFreshAtPath:(NSString *)path {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate];
    if (!mtime) return NO;
    return ([[NSDate date] timeIntervalSinceDate:mtime] < 30 * 60); // 30 分钟
}

/// 版本清单源列表：默认 BMCLAPI 镜像，失败自动切官方源重试
- (NSArray<NSString *> *)versionManifestURLStrings {
    return @[
        @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json",
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json",
    ];
}

- (void)performListGameVersions:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    [self performListGameVersionsIncludeSnapshots:NO completion:completion];
}

- (void)performListGameVersionsIncludeSnapshots:(BOOL)includeSnapshots
                                     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *cachePath = [self gameVersionsCachePath];

    // 命中缓存且未过期（缓存完整清单，含全部类型；按参数过滤后返回）
    if ([self isCacheFreshAtPath:cachePath]) {
        NSData *cached = [NSData dataWithContentsOfFile:cachePath];
        if (cached) {
            NSArray *cachedVersions = [NSJSONSerialization JSONObjectWithData:cached options:0 error:nil];
            if ([cachedVersions isKindOfClass:[NSArray class]] && cachedVersions.count > 0) {
                NSString *filtered = [self filteredVersionsJSON:cachedVersions includeSnapshots:includeSnapshots];
                if (filtered.length > 0) {
                    completion(filtered, nil);
                    return;
                }
            }
        }
    }

    NSArray *urlStrings = [self versionManifestURLStrings];
    [self fetchManifestFromSources:urlStrings
                            index:0
                     lastError:nil
                    completion:^(NSArray * _Nullable versions, NSString * _Nullable sourceUsed, NSError * _Nullable error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        // 写缓存（完整清单）
        NSString *fullJSON = [self jsonStringFromObject:versions];
        NSData *resultData = [fullJSON dataUsingEncoding:NSUTF8StringEncoding];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [resultData writeToFile:cachePath atomically:YES];
        });
        NSString *resultJSON = [self filteredVersionsJSON:versions includeSnapshots:includeSnapshots];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSString stringWithFormat:localize(@"ai.tools.source_line_fmt", nil), resultJSON, sourceUsed ?: @"bmclapi"], nil);
        });
    }];
}

/// 依序尝试源列表拉取版本清单（BMCLAPI → official 兜底）
- (void)fetchManifestFromSources:(NSArray<NSString *> *)urlStrings
                           index:(NSUInteger)index
                      lastError:(NSError * _Nullable)lastError
                      completion:(void (^)(NSArray * _Nullable versions, NSString * _Nullable sourceUsed, NSError * _Nullable error))completion {
    if (index >= urlStrings.count) {
        NSString *detail = lastError.localizedDescription ?: localize(@"resman.common.unknown_error", nil);
        completion(nil, nil, [NSError errorWithDomain:@"AiTool" code:500
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.instances.manifest_failed_fmt", nil), detail]}]);
        return;
    }
    NSString *urlString = urlStrings[index];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self fetchManifestFromSources:urlStrings index:index + 1 lastError:lastError completion:completion];
        return;
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSError *parseError = nil;
        NSArray *versions = nil;
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:[NSDictionary class]] && [json[@"versions"] isKindOfClass:[NSArray class]]) {
                NSMutableArray *parsed = [NSMutableArray array];
                for (id item in json[@"versions"]) {
                    if (![item isKindOfClass:[NSDictionary class]]) continue;
                    NSString *vid = item[@"id"];
                    NSString *vtype = item[@"type"];
                    if (![vid isKindOfClass:[NSString class]] || vid.length == 0) continue;
                    [parsed addObject:@{
                        @"id": vid,
                        @"type": [vtype isKindOfClass:[NSString class]] ? (vtype ?: @"") : @"",
                    }];
                }
                if (parsed.count > 0) versions = parsed;
            }
            if (!versions) {
                parseError = [NSError errorWithDomain:@"AiTool" code:500
                                              userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.instances.manifest_malformed", nil)}];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (versions) {
                NSString *sourceUsed = [urlString containsString:@"bmclapi"] ? @"BMCLAPI" : @"official";
                completion(versions, sourceUsed, nil);
                return;
            }
            // 当前源失败 → 切换下一个源重试
            NSError *err = error ?: parseError;
            [self fetchManifestFromSources:urlStrings index:index + 1 lastError:err completion:completion];
        });
    }];
    [task resume];
}

/// 过滤版本清单：默认仅 release；includeSnapshots 时附加最新一条 snapshot
- (NSString *)filteredVersionsJSON:(NSArray *)versions includeSnapshots:(BOOL)includeSnapshots {
    NSMutableArray *filtered = [NSMutableArray array];
    NSDictionary *latestSnapshot = nil;
    for (id item in versions) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *vtype = item[@"type"];
        if ([vtype isEqualToString:@"release"]) {
            [filtered addObject:item];
        } else if (includeSnapshots && [vtype isEqualToString:@"snapshot"] && !latestSnapshot) {
            latestSnapshot = item; // 清单本身按新→旧排序，取首个即最新
        }
    }
    if (latestSnapshot) [filtered addObject:latestSnapshot];
    return [self jsonStringFromObject:filtered];
}

@end