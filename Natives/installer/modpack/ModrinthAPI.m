#import "utils.h"
#import "ModrinthAPI.h"
#import "PLMirrorCenter.h"

/// 经 PLMirrorCenter 按资源下载（AssetDownload）策略应用镜像
/// （Modrinth CDN 文件 → MCIM 镜像），URL 为空或无法解析时回退原始字符串
static NSString *MRAMirrorResolvedURL(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return urlString;
    NSURL *resolved = [PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:urlString]
                                                    resourceType:PLMirrorResourceTypeAssetDownload];
    return resolved.absoluteString ?: urlString;
}

@implementation ModrinthAPI

@dynamic reachedLastPage, lastError;

/// 重写 baseURL getter，根据 PLMirrorCenter 的资源搜索（AssetSearch）策略
/// 动态返回官方或 MCIM 镜像 URL，这样所有使用 self.baseURL 的请求（搜索/版本列表/详情）都会自动走镜像
- (NSString *)baseURL {
    return [PLMirrorCenter modrinthAPIBaseURL];
}

+ (instancetype)sharedInstance {
    static ModrinthAPI *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

#pragma mark - Helper

- (BOOL)boolValueFromObject:(id)obj {
    if (obj == nil || obj == [NSNull null]) return NO;
    if ([obj isKindOfClass:[NSNumber class]]) return [(NSNumber *)obj boolValue];
    if ([obj isKindOfClass:[NSString class]]) return [(NSString *)obj boolValue];
    return NO;
}

#pragma mark - Sync Search (支持 projectType)

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(NSMutableArray *)modrinthSearchResult {
    int limit = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：未指定 projectType 但声明 isModpack 时按整合包搜索，避免误搜 Mod
        projectType = [searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }

    // 修复 #50: 必须把 loader（categories facet）传给 Modrinth API，否则筛选 neoforge/fabric 不生效
    // Modrinth 的 loader 类别：fabric / quilt / forge / neoforge / liteloader / rift 等
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    if (searchFilters[@"mcVersion"].length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", searchFilters[@"mcVersion"]];
    }
    NSString *loader = searchFilters[@"loader"] ?: searchFilters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];

    NSDictionary *params = @{
        @"facets": facetString,
        @"query": [searchFilters[@"name"] stringByReplacingOccurrencesOfString:@" " withString:@"+"] ?: @"",
        @"limit": @(limit),
        // Task173：同步路径同款排序映射（见异步路径注释）
        @"index": [ModrinthAPI ame173_indexForSort:searchFilters[@"sort"] query:searchFilters[@"name"]],
        @"offset": @(modrinthSearchResult.count)
    };
    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) return nil;
    
    NSMutableArray *result = modrinthSearchResult ?: [NSMutableArray new];
    for (NSDictionary *hit in response[@"hits"]) {
        BOOL isModpack = [hit[@"project_type"] isEqualToString:@"modpack"];
        [result addObject:@{
            @"apiSource": @(1),
            @"isModpack": @(isModpack),
            @"projectType": hit[@"project_type"] ?: projectType,
            @"id": hit[@"project_id"] ?: hit[@"slug"] ?: @"",
            @"title": hit[@"title"] ?: @"",
            @"description": hit[@"description"] ?: @"",
            @"imageUrl": hit[@"icon_url"] ?: @"",
            @"author": hit[@"author"] ?: @"",
            @"downloads": hit[@"downloads"] ?: @0,
            @"likes": hit[@"follows"] ?: @0,
            @"categories": hit[@"categories"] ?: @[],
            @"lastUpdated": hit[@"date_modified"] ?: @""
        }.mutableCopy];
    }
    self.reachedLastPage = result.count >= [response[@"total_hits"] unsignedLongValue];
    return result;
}

#pragma mark - Sync Load Details (修复数组赋值)

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSArray *response = [self getEndpoint:[NSString stringWithFormat:@"project/%@/version", item[@"id"]] params:nil];
    if (!response) return;

    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];

    for (NSDictionary *version in response) {
        NSArray *files = version[@"files"];
        if (![files isKindOfClass:[NSArray class]] || files.count == 0) continue;
        NSDictionary *file = files.firstObject;

        [names addObject:version[@"name"] ?: @"Unknown"];
        NSArray *gameVersions = version[@"game_versions"];
        [mcNames addObject:[gameVersions isKindOfClass:[NSArray class]] ? gameVersions.firstObject : @""];
        [urls addObject:file[@"url"] ?: @""];
        NSDictionary *hashesMap = file[@"hashes"];
        [hashes addObject:hashesMap[@"sha1"] ?: @""];
        [sizes addObject:file[@"size"] ?: @0];
        [fileNames addObject:file[@"filename"] ?: @""];
        [fileTypes addObject:version[@"version_type"] ?: @""];
    }

    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionFileNames"] = fileNames;
    item[@"versionFileTypes"] = fileTypes;
    item[@"versionDetailsLoaded"] = @(YES);
}

/// 异步加载整合包版本详情，避免 dispatch_group_wait 同步阻塞主线程/卡 UI
- (void)loadDetailsOfModAsync:(NSMutableDictionary *)item
                   completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    NSString *modID = item[@"id"];
    if (!modID || modID.length == 0) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:1
                                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1238", nil)}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(NO, [NSError errorWithDomain:@"ModrinthAPIError" code:2
                                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1048", nil)}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            self.lastError = error;
            if (completion) completion(NO, error);
            return;
        }
        if (!data) {
            NSError *err = [NSError errorWithDomain:@"ModrinthAPIError" code:3
                                           userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1239", nil)}];
            self.lastError = err;
            if (completion) completion(NO, err);
            return;
        }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            NSError *err = jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4
                                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_444", nil)}];
            self.lastError = err;
            if (completion) completion(NO, err);
            return;
        }

        NSMutableArray<NSString *> *names = [NSMutableArray new];
        NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
        NSMutableArray<NSString *> *urls = [NSMutableArray new];
        NSMutableArray<NSString *> *hashes = [NSMutableArray new];
        NSMutableArray<NSString *> *sizes = [NSMutableArray new];
        NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
        NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];

        for (NSDictionary *version in jsonResult) {
            NSArray *files = version[@"files"];
            if (![files isKindOfClass:[NSArray class]] || files.count == 0) continue;
            NSDictionary *file = files.firstObject;

            [names addObject:version[@"name"] ?: @"Unknown"];
            NSArray *gameVersions = version[@"game_versions"];
            [mcNames addObject:[gameVersions isKindOfClass:[NSArray class]] ? gameVersions.firstObject : @""];
            [urls addObject:MRAMirrorResolvedURL(file[@"url"] ?: @"")];
            NSDictionary *hashesMap = file[@"hashes"];
            [hashes addObject:hashesMap[@"sha1"] ?: @""];
            [sizes addObject:file[@"size"] ?: @0];
            [fileNames addObject:file[@"filename"] ?: @""];
            [fileTypes addObject:version[@"version_type"] ?: @""];
        }

        item[@"versionNames"] = names;
        item[@"mcVersionNames"] = mcNames;
        item[@"versionSizes"] = sizes;
        item[@"versionUrls"] = urls;
        item[@"versionHashes"] = hashes;
        item[@"versionFileNames"] = fileNames;
        item[@"versionFileTypes"] = fileTypes;
        item[@"versionDetailsLoaded"] = @(YES);

        if (completion) completion(YES, nil);
    }];
    [task resume];
}

#pragma mark - 补充：ModpackAPI 协议方法（支持所有下载）

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    if ([file isKindOfClass:[NSDictionary class]]) {
        NSString *url = file[@"url"];
        if ([url isKindOfClass:[NSString class]] && url.length > 0) {
            return MRAMirrorResolvedURL(url);
        }
    }
    return @"";
}

- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType {
    if (![file isKindOfClass:[NSDictionary class]]) return NO;
    NSString *fileName = file[@"filename"] ?: file[@"fileName"] ?: @"";
    NSString *extension = fileName.pathExtension.lowercaseString;
    NSArray *extensions = [self preferredFileExtensionsForProjectType:projectType];
    return extensions.count == 0 || [extensions containsObject:extension];
}

- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"shader"] ||
        [projectType isEqualToString:@"resourcepack"] ||
        [projectType isEqualToString:@"datapack"] ||
        [projectType isEqualToString:@"modpack"] ||
        [projectType isEqualToString:@"world"]) {
        return @[@"zip"];
    }
    return @[@"jar"];
}

- (NSMutableDictionary *)projectForFileHash:(NSString *)sha1 projectType:(NSString *)projectType {
    if (sha1.length == 0) return nil;
    // 修复：Modrinth 文件反查 API 要求 hash 作为路径参数（GET /v2/version_file/{sha1}?algorithm=sha1）。
    // 原实现把 hash 放进 getEndpoint 的查询参数（生成 ?hash=xxx），该路由不存在，导致反查永远 404。
    // 参照本类 loadDetailsOfMod 中 project/%@/version 的写法，把 sha1 拼进 endpoint 路径，
    // algorithm=sha1 作为查询参数仍由 params 生成。
    NSString *endpoint = [NSString stringWithFormat:@"version_file/%@", sha1];
    NSDictionary *response = [self getEndpoint:endpoint params:@{@"algorithm": @"sha1"}];
    if (![response isKindOfClass:[NSDictionary class]]) return nil;
    
    NSMutableDictionary *result = [NSMutableDictionary new];
    result[@"id"] = response[@"project_id"] ?: @"";
    result[@"title"] = response[@"name"] ?: @"";
    result[@"projectType"] = projectType ?: @"mod";
    result[@"version"] = response[@"version_number"] ?: @"";
    result[@"fileName"] = response[@"filename"] ?: @"";
    result[@"downloadUrl"] = MRAMirrorResolvedURL([response[@"files"] firstObject][@"url"]) ?: @"";
    return result;
}

#pragma mark - Async Mod Search (推荐使用)

/// Task173：UI 排序键（follows/downloads/updated/newest/relevance）→ Modrinth
/// search 的 index 参数。值域恰好同名直通；未选择排序时的旧缺省语义
/// （有搜索词 = relevance，无搜索词 = follows）保持不变。
+ (NSString *)ame173_indexForSort:(NSString *)sort query:(NSString *)query {
    NSArray *ame173_valid = @[@"relevance", @"downloads", @"follows", @"newest", @"updated"];
    if ([sort isKindOfClass:NSString.class] && [ame173_valid containsObject:sort]) {
        return sort;
    }
    return (query.length > 0) ? @"relevance" : @"follows";
}

- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion {
    NSString *projectType = filters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：未指定 projectType 但声明 isModpack 时按整合包搜索，避免误搜 Mod
        projectType = [filters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }
    NSString *query = filters[@"query"] ?: filters[@"name"] ?: @"";
    NSNumber *limitNum = filters[@"limit"] ?: @50;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];
    
    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    if (mcVersion.length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", mcVersion];
    }
    // 修复 #50: 必须把 loader（categories facet）传给 Modrinth API，否则筛选 neoforge/fabric 不生效
    // Task179：无加载器概念的资源类型禁发 categories facet——resourcepack/
    // shader/datapack/world 挂上 categories:fabric 后 Modrinth 只剩 15 个
    // 结果（实测 35467 -> 15），资源包页等于清空。模组/整合包不受影响。
    BOOL ame179_loaderLessType = ([projectType isEqualToString:@"resourcepack"] ||
                                  [projectType isEqualToString:@"shader"] ||
                                  [projectType isEqualToString:@"datapack"] ||
                                  [projectType isEqualToString:@"world"]);
    NSString *loader = filters[@"loader"] ?: filters[@"categories"];
    if (loader.length > 0 && !ame179_loaderLessType) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];
    
    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedFacets = [facetString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *index = [ModrinthAPI ame173_indexForSort:filters[@"sort"] query:query];
    NSString *urlString = [NSString stringWithFormat:@"%@/search?query=%@&limit=%d&offset=%d&facets=%@&index=%@",
                           self.baseURL, encodedQuery, limit, offset, encodedFacets, index];
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) {
            completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        }
        return;
    }

    // Task217：走 ame217 抖动重试取数器（镜像空响应/网关错误单次重试；
    // 解析主体不变）。completion 仍在后台线程回调，调用方自行切主线程。
    [self ame217_fetchJSONWithURL:url completion:^(id json, NSError *fetchError) {
        if (fetchError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, fetchError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        NSArray *hits = json[@"hits"];
        if (![hits isKindOfClass:[NSArray class]]) { if (completion) completion(@[], nil); return; }

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *item in hits) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *modData = [NSMutableDictionary dictionary];
            modData[@"apiSource"] = @(1);
            modData[@"isModpack"] = @([item[@"project_type"] isEqualToString:@"modpack"]);
            modData[@"projectType"] = item[@"project_type"] ?: projectType;
            modData[@"id"] = item[@"project_id"] ?: item[@"slug"] ?: @"";
            modData[@"title"] = item[@"title"] ?: @"Unknown";
            modData[@"description"] = item[@"description"] ?: @"";
            modData[@"author"] = item[@"author"] ?: @"Unknown";
            modData[@"downloads"] = item[@"downloads"] ?: @0;
            modData[@"likes"] = item[@"follows"] ?: @0;
            modData[@"imageUrl"] = item[@"icon_url"] ?: @"";
            modData[@"categories"] = item[@"categories"] ?: @[];
            modData[@"lastUpdated"] = item[@"date_modified"] ?: @"";
            [results addObject:modData];
        }
        if (completion) completion(results, nil);
    }];
}

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable, NSError * _Nullable))completion {
    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    [self ame217_fetchJSONWithURL:url completion:^(id jsonResult, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (![jsonResult isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }
        NSMutableArray<ModVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *dict in jsonResult) {
            ModVersion *version = [[ModVersion alloc] initWithDictionary:dict];
            if (version) [versions addObject:version];
        }
        if (completion) completion(versions, nil);
    }];
}

/// Task217：MCIM 镜像抖动单次重试（搜索 / 版本列表两入口共享）。
/// 实测（2026-10）：镜像偶发空响应 / 网关错误（连续两次空 body 后恢复，
/// 与 Task169 记录的 CurseForge 镜像抖动同源），旧实现一次失败即向
/// UI 报“未找到项目/版本”——组件安装（Fabric API / Sodium+Iris /
/// TouchController）在镜像源上随机全军覆没。失败（传输错误 / 解析失败）
/// 后延迟 1.5s 重试一次，对齐 ame169 CurseForge 的重试语义；有效但为
/// 空的结果不重试（无法与合法空结果区分）。completion 线程语义与旧
/// 内联实现一致（任意线程回调，调用方自行切主线程）。
- (void)ame217_fetchJSONWithURL:(NSURL *)url
                      completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    if (!completion) return;
    void (^ame217_attempt)(NSInteger) = nil;
    ame217_attempt = ^(NSInteger attempt) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.timeoutInterval = 30.0;
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];
        NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error || !data || data.length == 0) {
                if (attempt == 0) {
                    NSLog(@"[ModrinthAPI] Task217: transport failure (%@) -- one retry in 1.5s",
                          error.localizedDescription ?: @"empty body");
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        ame217_attempt(1);
                    });
                    return;
                }
                completion(nil, error ?: [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]);
                return;
            }
            NSError *jsonError = nil;
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (jsonError || !json) {
                if (attempt == 0) {
                    NSLog(@"[ModrinthAPI] Task217: JSON parse failure (%@) -- one retry in 1.5s",
                          jsonError.localizedDescription);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                        ame217_attempt(1);
                    });
                    return;
                }
                completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
                return;
            }
            completion(json, nil);
        }];
        [task resume];
    };
    ame217_attempt(0);
}

#pragma mark - Shader Search (专用方法)

- (void)searchShaderWithFilters:(NSDictionary *)filters
                     completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSMutableDictionary *shaderFilters = [filters mutableCopy];
    shaderFilters[@"projectType"] = @"shader";
    [self searchModWithFilters:shaderFilters completion:completion];
}

- (void)getVersionsForShaderWithID:(NSString *)shaderID
                        completion:(void (^)(NSArray<ShaderVersion *> * _Nullable, NSError * _Nullable))completion {
    if (shaderID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid shader ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@/version", self.baseURL, shaderID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSession *session = [NSURLSession sharedSession];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        id jsonResult = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![jsonResult isKindOfClass:[NSArray class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        NSMutableArray<ShaderVersion *> *versions = [NSMutableArray array];
        for (NSDictionary *dict in jsonResult) {
            ShaderVersion *version = [[ShaderVersion alloc] initWithDictionary:dict];
            if (version) [versions addObject:version];
        }
        if (completion) completion(versions, nil);
    }];
    [task resume];
}

#pragma mark - Server Projects 搜索

/// 内部工具：发起一次 server 或 modpack 的搜索请求
- (void)_searchServerWithProjectType:(NSString *)projectType
                              filters:(NSDictionary *)filters
                           completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *query = filters[@"query"] ?: filters[@"name"] ?: @"";
    NSNumber *limitNum = filters[@"limit"] ?: @30;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];

    NSMutableString *facetString = [NSMutableString new];
    [facetString appendString:@"["];
    [facetString appendFormat:@"[\"project_type:%@\"]", projectType];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    if (mcVersion.length > 0) {
        [facetString appendFormat:@", [\"versions:%@\"]", mcVersion];
    }
    NSString *loader = filters[@"loader"] ?: filters[@"categories"];
    if (loader.length > 0) {
        [facetString appendFormat:@", [\"categories:%@\"]", loader];
    }
    [facetString appendString:@"]"];

    NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *encodedFacets = [facetString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *index = [ModrinthAPI ame173_indexForSort:filters[@"sort"] query:query];
    NSString *urlString = [NSString stringWithFormat:@"%@/search?query=%@&limit=%d&offset=%d&facets=%@&index=%@",
                           self.baseURL, encodedQuery, limit, offset, encodedFacets, index];

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        NSArray *hits = json[@"hits"];
        if (![hits isKindOfClass:[NSArray class]]) { if (completion) completion(@[], nil); return; }

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *item in hits) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *serverData = [NSMutableDictionary dictionary];
            serverData[@"apiSource"] = @(1);
            serverData[@"projectType"] = item[@"project_type"] ?: projectType;
            serverData[@"serverID"] = item[@"project_id"] ?: item[@"slug"] ?: @"";
            serverData[@"title"] = item[@"title"] ?: @"Unknown";
            serverData[@"description"] = item[@"description"] ?: @"";
            serverData[@"author"] = item[@"author"] ?: @"Unknown";
            serverData[@"downloads"] = item[@"downloads"] ?: @0;
            serverData[@"likes"] = item[@"follows"] ?: @0;
            serverData[@"icon_url"] = item[@"icon_url"] ?: @"";
            serverData[@"page_url"] = item[@"page_url"] ?: @"";
            serverData[@"categories"] = item[@"categories"] ?: @[];
            serverData[@"date_modified"] = item[@"date_modified"] ?: @"";
            [results addObject:serverData];
        }
        if (completion) completion(results, nil);
    }];
    [task resume];
}

- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    // 优先使用 project_type=server（Modrinth Server Projects，2026 年新功能）
    __weak typeof(self) weakSelf = self;
    [self _searchServerWithProjectType:@"server" filters:filters completion:^(NSArray * _Nullable serverResults, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (error) {
            // server 类型 API 不可用，直接回退到 modpack 搜索
            NSLog(@"[ModrinthAPI] Server Projects search failed, falling back to modpack search: %@", error.localizedDescription);
            [strongSelf _searchServerWithProjectType:@"modpack" filters:filters completion:completion];
            return;
        }
        if (serverResults.count > 0) {
            if (completion) completion(serverResults, nil);
            return;
        }
        // server 类型结果为空，回退到 modpack 搜索（作为"服务器整合包"展示）
        NSLog(@"[ModrinthAPI] Server Projects result is empty, falling back to modpack search");
        [strongSelf _searchServerWithProjectType:@"modpack" filters:filters completion:completion];
    }];
}

- (void)getServerDetailsForID:(NSString *)serverID
                   completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    if (serverID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid server ID"}]);
        return;
    }

    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@", self.baseURL, serverID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 30.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"Amethyst-iOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { if (completion) completion(nil, error); return; }
        if (!data) { if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:3 userInfo:@{NSLocalizedDescriptionKey: @"No data"}]); return; }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, jsonError ?: [NSError errorWithDomain:@"ModrinthAPIError" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}]);
            return;
        }

        // 提取关键字段，统一字段命名以便 ServerItem.applyDetailData: 处理
        NSMutableDictionary *details = [NSMutableDictionary dictionary];
        details[@"serverID"] = json[@"id"] ?: json[@"slug"] ?: @"";
        details[@"title"] = json[@"title"] ?: @"";
        details[@"description"] = json[@"description"] ?: @"";
        details[@"projectType"] = json[@"project_type"] ?: @"server";
        details[@"icon_url"] = json[@"icon_url"] ?: @"";
        details[@"page_url"] = json[@"page_url"] ?: @"";
        details[@"downloads"] = json[@"downloads"] ?: @0;
        details[@"likes"] = json[@"followers"] ?: @0;
        details[@"date_modified"] = json[@"updated"] ?: @"";

        // Server Projects 详情可能直接包含 server_address 字段
        id addrObj = json[@"server_address"] ?: json[@"ip"] ?: json[@"address"];
        if ([addrObj isKindOfClass:[NSString class]]) {
            NSString *addr = (NSString *)addrObj;
            if (addr.length > 0) {
                details[@"serverAddress"] = addr;
            }
        }
        // 关联整合包 ID
        id mpIDObj = json[@"modpack_project_id"] ?: json[@"modpack_id"];
        if ([mpIDObj isKindOfClass:[NSString class]]) {
            NSString *mpID = (NSString *)mpIDObj;
            if (mpID.length > 0) {
                details[@"modpack_project_id"] = mpID;
            }
        }

        if (completion) completion(details, nil);
    }];
    [task resume];
}

// Task 5.10：在线整合包下载路径统一——zip 下载完成后由
// MinecraftResourceDownloadTask.importDownloadedModpackPackage:detail: 复用
// ModpackImportService 统一导入（解析/解压/依赖下载/加载器/游戏文件/profile），
// 此处不再维护 API 侧的整合包解包双轨逻辑。

#pragma mark - Task226 (issue #10): Mod Dependencies (PCL2CE-style auto-download)

// 病历（用户议题 #10）：启动器下载模组不显示依赖项，缺依赖的模组导致
// 启动游戏崩溃。参考 PCL2CE：主模组下载完成后，解析 Modrinth 版本的
// dependencies 列表，把【必需】依赖以确认单形式列出，一键全部下载到
// 同一 mods 目录。

- (void)ame226_fetchVersionByFileSHA1:(NSString *)sha1
                            completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    if (sha1.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:20 userInfo:@{NSLocalizedDescriptionKey: @"no sha1"}]);
        return;
    }
    NSString *urlString = [NSString stringWithFormat:@"https://api.modrinth.com/v2/version_file/%@?algorithm=sha1", sha1];
    // 镜像同源：baseURL 是 /v2 前缀（api.modrinth.com 或 MCIM 镜像），直接拼 version_file
    NSString *mirrored = [NSString stringWithFormat:@"%@/version_file/%@?algorithm=sha1", self.baseURL, sha1];
    NSURL *url = [NSURL URLWithString:mirrored.length > 0 ? mirrored : urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:21 userInfo:@{NSLocalizedDescriptionKey: @"invalid URL"}]);
        return;
    }
    [self ame217_fetchJSONWithURL:url completion:^(id json, NSError *error) {
        if (error || ![json isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, error ?: [NSError errorWithDomain:@"ModrinthAPIError" code:22 userInfo:@{NSLocalizedDescriptionKey: @"bad JSON"}]);
            return;
        }
        if (completion) completion((NSDictionary *)json, nil);
    }];
}

/// ★ Task227（issue #10）：按项目 id 取展示名（依赖确认单用）。
/// GET /project/{id} → title。失败回 nil（调用方回退显示 projectId）。
- (void)ame227_fetchProjectTitle:(NSString *)projectID
                       completion:(void (^)(NSString * _Nullable title, NSError * _Nullable error))completion {
    if (projectID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:30 userInfo:@{NSLocalizedDescriptionKey: @"no project id"}]);
        return;
    }
    NSString *urlString = [NSString stringWithFormat:@"%@/project/%@", self.baseURL, projectID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:31 userInfo:@{NSLocalizedDescriptionKey: @"invalid URL"}]);
        return;
    }
    [self ame217_fetchJSONWithURL:url completion:^(id json, NSError *error) {
        if ([json isKindOfClass:[NSDictionary class]] && [json[@"title"] isKindOfClass:[NSString class]]) {
            if (completion) completion(json[@"title"], nil);
        } else {
            if (completion) completion(nil, error ?: [NSError errorWithDomain:@"ModrinthAPIError" code:32 userInfo:@{NSLocalizedDescriptionKey: @"no title"}]);
        }
    }];
}

- (void)ame226_fetchLatestVersionForProject:(NSString *)projectID
                                 gameVersion:(NSString *)gameVersion
                                      loader:(NSString *)loader
                                  completion:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))completion {
    if (projectID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:23 userInfo:@{NSLocalizedDescriptionKey: @"no project id"}]);
        return;
    }
    // game_versions=["x"]&loaders=["y"]（URL 编码的 JSON 数组，官方查询格式）
    NSMutableString *qs = [NSMutableString stringWithFormat:@"%@/project/%@/version", self.baseURL, projectID];
    BOOL hasQ = NO;
    if (gameVersion.length > 0) {
        NSString *enc = [NSString stringWithFormat:@"[\"%@\"]", gameVersion];
        [qs appendFormat:@"%@game_versions=%@", hasQ ? @"&" : @"?", [enc stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
        hasQ = YES;
    }
    if (loader.length > 0) {
        NSString *enc = [NSString stringWithFormat:@"[\"%@\"]", loader];
        [qs appendFormat:@"%@loaders=%@", hasQ ? @"&" : @"?", [enc stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    }
    NSURL *url = [NSURL URLWithString:qs];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"ModrinthAPIError" code:24 userInfo:@{NSLocalizedDescriptionKey: @"invalid URL"}]);
        return;
    }
    [self ame217_fetchJSONWithURL:url completion:^(id json, NSError *error) {
        if (error || ![json isKindOfClass:[NSArray class]] || ((NSArray *)json).count == 0) {
            // 无兼容版本不算错误：静默跳过该依赖（调用方过滤 nil）
            if (completion) completion(nil, nil);
            return;
        }
        NSDictionary *ver = ((NSArray *)json).firstObject;
        if (![ver isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, nil);
            return;
        }
        NSArray *files = ver[@"files"];
        NSDictionary *file = [files isKindOfClass:[NSArray class]] ? files.firstObject : nil;
        if (![file isKindOfClass:[NSDictionary class]]) {
            if (completion) completion(nil, nil);
            return;
        }
        NSDictionary *hashes = file[@"hashes"];
        NSString *sha1 = [hashes isKindOfClass:[NSDictionary class]] ? hashes[@"sha1"] : nil;
        NSDictionary *info = @{
            @"filename": file[@"filename"] ?: @"",
            @"url": file[@"url"] ?: @"",
            @"sha1": sha1 ?: @"",
            @"versionName": ver[@"version_number"] ?: (ver[@"name"] ?: @""),
            @"projectID": projectID,
        };
        if (completion) completion(info, nil);
    }];
}


@end