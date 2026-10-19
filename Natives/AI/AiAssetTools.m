//
//  AiAssetTools.m
//  Prisma
//
//  Prisma AI Agent 资源/网络工具（Phase 3b）实现：
//  - AiAssetSearchTool：Modrinth 搜索（search_mods / search_resourcepacks / search_shaders /
//    search_datapacks / search_modpacks / search_worlds）。
//  - AiAssetInstallTool：直接安装（HMCL AE 式全自动）：
//      install_mod / install_resourcepack / install_shader / install_datapack（Modrinth 下载 + gameVersion 匹配）；
//      install_game_version（MinecraftResourceDownloadTask 直接安装本体，下载中心 6 阶段进度）；
//      install_loader（Fabric/Quilt 直接安装：自动预装原版 + meta profile + Fabric API；
//                     Forge/NeoForge/OptiFine 涉及 JVM 图形安装器，保留下载页引导）。
//  两类工具共享文件内私有 helper（AiAssetNetworkUtil / AiAssetInstaller）。
//  - 网络统一用 NSURLSession GET JSON（参考 AnnouncementService）。
//  - 文件下载统一走 PLDownloadClient，并注册到 DownloadTaskManager 以便进度页跟踪。
//  - 传统中括号语法 + ARC；结果一律调度回主线程回调。
//
//  enhance-ai-agent 第二轮增强：
//  - Modrinth 请求链：官方 → MCIM 镜像（mod.mcimirror.top）→ 官方重试；下载文件双候选
//    （官方 CDN → cdn.mcimirror.top 镜像），失败自动切换（PLDownloadClient candidateURLs）。
//  - 版本清单链：BMCLAPI 默认 → official 兜底（不依赖 general.download_source 偏好）。
//  - latest 别名：install_loader 的 loaderVersion 与资源安装的 versionId 均可传
//    "latest"/"latest-release"，等价于自动选择最新稳定版，无需先拉版本列表。
//  - install_mod 检测 Sodium 自动连带安装 Podium（或 Podium Port）；Iris 附带 Zink 渲染器提醒；
//    安装完成统一附「可能缺少依赖 Mod，建议启动测试」提醒。
//  - install_* 支持 wait 参数（默认 true）：wait=false 时后台执行，立即返回任务信息，
//    AI 可用 check_downloads 查询进度。
//

#import "AiAssetTools.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "ModService.h"
#import "ShaderService.h"
#import "ResourcePackService.h"
#import "DataPackService.h"
#import "PLDownloadClient.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "MinecraftResourceDownloadTask.h"
#import "PLTaskStages.h"
#import "AiSafetyManager.h"
#import "../utils.h"   // Task271-e：工具结果/错误文案 i18n 接线需要 localize()

/// 工具错误域与常见错误码
static NSString * const kAiAssetToolDomain = @"AiAssetTool";

/// 解析 wait 参数（默认 YES；"false"/"no"/"0"/JSON false → NO）
static BOOL aiWaitRequested(NSDictionary *params) {
    id v = params[@"wait"];
    if (v == nil) return YES;
    if ([v isKindOfClass:[NSNumber class]]) return [v boolValue];
    if ([v isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)v lowercaseString];
        if ([s isEqualToString:@"false"] || [s isEqualToString:@"no"] || [s isEqualToString:@"0"]) return NO;
        return YES;
    }
    return YES;
}

/// 判断字符串是否为 latest 别名（latest / latest-release）
static BOOL aiIsLatestAlias(NSString *s) {
    return [s isEqualToString:@"latest"] || [s isEqualToString:@"latest-release"];
}

#pragma mark - 文件内私有工具类：网络与路径

/// 网络 / 路径 / 安全文件名等通用 helper（文件内私有）
@interface AiAssetNetworkUtil : NSObject

/// GET JSON（对象或数组均可）；统一调度回主线程
+ (void)getJSONFromURL:(NSURL *)url completion:(void (^)(id _Nullable json, NSError * _Nullable error))completion;

/// Modrinth API GET JSON（官方 → MCIM 镜像 → 官方重试）：
/// apiPath 为以 / 开头的 v2 路径（如 /search?... 或 /project/xxx/version）。
/// completion 返回 json、实际使用的源（Modrinth / Modrinth-MCIM镜像）与错误。
+ (void)getModrinthJSONWithPath:(NSString *)apiPath
                     completion:(void (^)(id _Nullable json, NSString * _Nullable usedSource, NSError * _Nullable error))completion;

/// 把文件名安全化（去掉会破坏路径的分隔符）
+ (NSString *)safeFileName:(NSString *)rawName;

/// 解析目标 profile（instance 参数优先，缺省取当前选中 profile）
+ (NSString *)resolveProfileName:(NSDictionary *)params;

/// 解析 profile 的 gameDir 绝对路径（相对路径相对 POJAV_GAME_DIR 展开）
+ (NSString *)resolveGameDirForProfile:(NSString *)profileName;

/// 判断某实例（gameDir）下是否已安装对应 MC 版本的 vanilla 本体
+ (BOOL)isGameVersionInstalled:(NSString *)mcVersion inGameDir:(NSString *)gameDir;

/// 拉取 Mojang/BMCLAPI 版本清单，返回指定版本的清单条目（含 id/url）。
/// versionId 支持 latest-release / latest-snapshot / latest（别名 latest-release）。
+ (void)fetchVersionEntry:(NSString *)versionId
               completion:(void (^)(NSDictionary * _Nullable entry, NSError * _Nullable error))completion;

/// 确保 versions/{versionId}/{versionId}.json 已存在（不存在则从清单下载，含 BMCLAPI 域名替换）
+ (void)ensureVersionJSONExists:(NSString *)versionId
                     completion:(void (^)(BOOL success))completion;

/// 解析参数对应的游戏版本：优先 params.gameVersion，否则取实例 profile 的
/// lastVersionId 并归一化（剥离 fabric/forge/neoforge/quilt/optifine 加载器后缀）
+ (NSString *)resolveGameVersionForParams:(NSDictionary *)params;

/// 向主线程 post ShowDownloadPage 通知（引导用户到内置下载页）
+ (void)postShowDownloadPage;

@end

#pragma mark - 文件内私有工具类：文件下载（PLDownloadClient + DownloadTaskManager）

@interface AiAssetInstaller : NSObject

/// 下载一个文件到目标目录，注册 DownloadTask 进度，完成回调主线程
+ (void)downloadFileFromURL:(NSURL *)url
                   filename:(NSString *)filename
                     folder:(NSString *)folder
                displayName:(NSString *)displayName
               resourceType:(NSString *)resourceType
                expectedSHA1:(nullable NSString *)expectedSHA1
                 completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion;

/// 下载一个文件到目标目录（增强版）：
/// - 下载候选含 MCIM 镜像（cdn.modrinth.com → cdn.mcimirror.top），失败自动切换；
/// - waitForCompletion=NO 时注册任务后立即回调「已加入后台下载」，下载继续后台进行，
///   终态仅回调 onFinished（可为 nil）；
/// - waitForCompletion=YES 时行为同旧版（completion 在终态回调），onFinished 亦会触发。
+ (void)downloadFileFromURL:(NSURL *)url
                   filename:(NSString *)filename
                     folder:(NSString *)folder
                displayName:(NSString *)displayName
               resourceType:(NSString *)resourceType
                expectedSHA1:(nullable NSString *)expectedSHA1
          waitForCompletion:(BOOL)waitForCompletion
                 completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion
                 onFinished:(nullable void (^)(BOOL success, NSString * _Nullable message))onFinished;

/// 直接安装 MC 原版本体（version JSON + libraries + assets）：
/// 1) 拉取版本清单条目并确保 version JSON 落盘；
/// 2) MinecraftResourceDownloadTask downloadVersion: 执行完整下载——其内部自动注册到
///    DownloadTaskManager（6 阶段 + autoPresentDetail），下载中心/统一进度页实时展示进度；
/// 3) 轮询 progress.finished（最长 30 分钟，与 ensureVanillaInstalled 一致）；
/// 4) 成功后创建并选中对应实例 profile，post ReloadProfileList 刷新版本列表。
+ (void)installVanillaVersionId:(NSString *)versionId
                     completion:(void (^)(BOOL success, NSString * _Nullable message))completion;

@end

@implementation AiAssetSearchTool {
    NSString *_internalName;
}

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return _internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionExternalNetwork;
}

- (NSString *)summary {
    if ([_internalName isEqualToString:@"search_resourcepacks"]) {
        return @"在 Modrinth 搜索资源包。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_shaders"]) {
        return @"在 Modrinth 搜索光影包（着色器）。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_datapacks"]) {
        return @"在 Modrinth 搜索数据包。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_modpacks"]) {
        return @"在 Modrinth 搜索整合包。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    if ([_internalName isEqualToString:@"search_worlds"]) {
        return @"在 Modrinth 搜索世界存档。"
               "\n参数：query（string，必填，搜索关键词）。"
               "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
    }
    // search_mods
    return @"在 Modrinth 搜索模组。"
           "\n参数：query（string，必填，搜索关键词）、facets（string，可选，mod/resourcepack/shaderpack/datapack/world/modpack，默认 mod）。"
           "\n返回最多 8 条 JSON 数组 [{slug,title,description,downloads,project_id}]；无结果显示「未找到相关项目」。";
}

#pragma mark - 执行

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    // facets 类型映射（固定或按 facets 参数）
    NSString *type = [self fixedType];
    NSString *query = [params[@"query"] isKindOfClass:[NSString class]] ? params[@"query"] : @"";
    if (query.length == 0) {
        NSError *err = [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.missing_query", nil)}];
        completion(nil, err);
        return;
    }
    // search_mods 允许 facets 覆盖；其余工具 facets 固定
    if ([_internalName isEqualToString:@"search_mods"]) {
        NSString *f = [params[@"facets"] isKindOfClass:[NSString class]] ? params[@"facets"] : @"";
        if (f.length > 0) type = f;
    }

    NSString *encQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *facetsJSON = [NSString stringWithFormat:@"[[[\"project_type:%@\"]]]", type ?: @"mod"];
    NSString *encFacets = [facetsJSON stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSString *apiPath = [NSString stringWithFormat:@"/search?query=%@&facets=%@&limit=8", encQuery, encFacets];

    // Modrinth 官方 → MCIM 镜像 → 官方重试（源切换由 helper 内部完成）
    [AiAssetNetworkUtil getModrinthJSONWithPath:apiPath completion:^(id _Nullable json, NSString * _Nullable usedSource, NSError * _Nullable error) {
        if (error) {
            completion(nil, error);
            return;
        }
        NSArray *hits = nil;
        if ([json isKindOfClass:[NSDictionary class]]) {
            hits = json[@"hits"];
        } else if ([json isKindOfClass:[NSArray class]]) {
            hits = json;
        }
        if (![hits isKindOfClass:[NSArray class]] || hits.count == 0) {
            completion(localize(@"ai.asset.no_results", nil), nil);
            return;
        }
        NSMutableArray *items = [NSMutableArray array];
        for (id hit in hits) {
            if (![hit isKindOfClass:[NSDictionary class]] || items.count >= 8) continue;
            NSString *title = hit[@"title"];
            NSString *desc = hit[@"description"];
            if (![desc isKindOfClass:[NSString class]]) desc = @"";
            // 描述截断 120 字符
            if (desc.length > 120) desc = [NSString stringWithFormat:@"%@…", [desc substringToIndex:120]];
            NSString *slug = hit[@"slug"];
            NSString *pid = hit[@"project_id"];
            NSNumber *downloads = hit[@"downloads"];
            if (![slug isKindOfClass:[NSString class]]) slug = @"";
            [items addObject:@{
                @"slug": slug,
                @"title": [title isKindOfClass:[NSString class]] ? title : @"",
                @"description": desc,
                @"downloads": ([downloads isKindOfClass:[NSNumber class]] ? downloads : @0),
                @"project_id": [pid isKindOfClass:[NSString class]] ? pid : @"",
            }];
        }
        if (items.count == 0) {
            completion(localize(@"ai.asset.no_results", nil), nil);
            return;
        }
        NSData *data = [NSJSONSerialization dataWithJSONObject:items options:0 error:nil];
        NSString *jsonStr = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
        completion([NSString stringWithFormat:localize(@"ai.tools.source_line_fmt", nil), jsonStr, usedSource ?: @"Modrinth"], nil);
    }];
}

/// 工具对应的固定 project_type（search_mods 默认 mod）
- (NSString *)fixedType {
    if ([_internalName isEqualToString:@"search_resourcepacks"]) return @"resourcepack";
    if ([_internalName isEqualToString:@"search_shaders"]) return @"shaderpack";
    if ([_internalName isEqualToString:@"search_datapacks"]) return @"datapack";
    if ([_internalName isEqualToString:@"search_modpacks"]) return @"modpack";
    if ([_internalName isEqualToString:@"search_worlds"]) return @"world";
    return @"mod";
}

@end

#pragma mark - AiAssetInstallTool

@implementation AiAssetInstallTool {
    NSString *_internalName;
}

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = name ?: @"";
    }
    return self;
}

- (NSString *)name {
    return _internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionControlledWrite;
}

- (NSString *)summary {
    if ([_internalName isEqualToString:@"install_resourcepack"]) {
        return @"从 Modrinth 下载并安装资源包到资源包目录，全自动完成，进度在下载中心展示。"
               "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，可传 \"latest\" 表示最新版）、gameVersion（string，可选，按 MC 版本过滤）、instance（string，可选，实例名）、wait（boolean，可选，默认 true；false 时后台下载立即返回，可用 check_downloads 查进度）。"
               "\n说明：默认源 Modrinth，失败自动切换 MCIM 镜像再回退官方。目录不存在会自动创建。返回安装结果说明。";
    }
    if ([_internalName isEqualToString:@"install_shader"]) {
        return @"从 Modrinth 下载并安装光影包到光影目录，全自动完成，进度在下载中心展示。"
               "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，可传 \"latest\" 表示最新版）、gameVersion（string，可选，按 MC 版本过滤）、instance（string，可选，实例名）、wait（boolean，可选，默认 true；false 时后台下载立即返回，可用 check_downloads 查进度）。"
               "\n说明：默认源 Modrinth，失败自动切换 MCIM 镜像再回退官方。若安装 Iris 光影，建议提醒用户把渲染器切换为 Zink。返回安装结果说明。";
    }
    if ([_internalName isEqualToString:@"install_datapack"]) {
        return @"从 Modrinth 下载并安装数据包到数据包目录，全自动完成，进度在下载中心展示。"
               "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，可传 \"latest\" 表示最新版）、gameVersion（string，可选，按 MC 版本过滤）、instance（string，可选，实例名）、wait（boolean，可选，默认 true；false 时后台下载立即返回，可用 check_downloads 查进度）。"
               "\n说明：默认源 Modrinth，失败自动切换 MCIM 镜像再回退官方。返回安装结果说明。";
    }
    if ([_internalName isEqualToString:@"install_game_version"]) {
        return @"直接下载并安装指定 Minecraft 原版本体（版本 JSON + 库文件 + 资源文件），全自动完成，进度在下载中心实时展示，无需用户操作。"
               "\n参数：versionId（string，必填，如 1.20.1，也支持 latest-release / latest-snapshot / latest）、wait（boolean，可选，默认 true；false 时后台安装立即返回，可用 check_downloads 查进度）。"
               "\n说明：版本清单默认从 BMCLAPI 镜像获取，失败自动切换官方源。行为：安装完成后自动创建并选中对应实例。返回安装结果说明。";
    }
    if ([_internalName isEqualToString:@"install_loader"]) {
        return @"直接安装模组加载器（全自动，进度在下载中心展示）。"
               "\n参数：mcVersion（string，必填，目标 MC 版本）、loaderType（string，必填，fabric/forge/neoforge/quilt/optifine）、loaderVersion（string，可选，可传 \"latest\" 表示最新稳定版，无需先拉版本列表）、instance（string，可选，实例名）、wait（boolean，可选，默认 true；false 时后台安装立即返回，可用 check_downloads 查进度）。"
               "\n行为：Fabric/Quilt 直接安装——若原版本体未安装会先自动安装原版，随后写入加载器版本 JSON 并注册实例，Fabric 还会自动安装 Fabric API；"
               "Forge/NeoForge/OptiFine 安装器需要运行 Java 图形安装器/处理器，暂无法全自动，将打开内置下载页引导用户完成。";
    }
    // install_mod
    return @"从 Modrinth 下载并安装模组到 mods 目录，全自动完成，进度在下载中心展示。"
           "\n参数：slugOrId（string，必填，Modrinth 项目 slug 或 id）、versionId（string，可选，可传 \"latest\" 表示最新版，无需先拉版本列表）、gameVersion（string，可选，指定 MC 版本过滤，缺省自动取实例当前 MC 版本）、instance（string，可选，实例名）、wait（boolean，可选，默认 true；false 时后台下载立即返回，可用 check_downloads 查进度）。"
           "\n说明：默认源 Modrinth，失败自动切换 MCIM 镜像再回退官方；若安装 Sodium 会自动连带安装 Podium（或 Podium Port）。返回安装结果说明。";
}

#pragma mark - 执行

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    if ([_internalName isEqualToString:@"install_game_version"]) {
        [self performInstallGameVersion:params completion:completion];
        return;
    }
    if ([_internalName isEqualToString:@"install_loader"]) {
        [self performInstallLoader:params completion:completion];
        return;
    }
    [self performResourceInstall:params completion:completion];
}

#pragma mark - 资源安装（mod / resourcepack / shader / datapack）

/// 目标目录解析：根据工具名返回对应 Service 的 ensure 目录
- (nullable NSString *)resolvedFolderForParams:(NSDictionary *)params {
    NSString *profile = [AiAssetNetworkUtil resolveProfileName:params];
    NSError *err = nil;
    if ([_internalName isEqualToString:@"install_mod"]) {
        return [[ModService sharedService] ensureModsFolderForProfile:profile error:&err];
    }
    if ([_internalName isEqualToString:@"install_resourcepack"]) {
        return [[ResourcePackService sharedService] ensureResourcePacksFolderForProfile:profile error:&err];
    }
    if ([_internalName isEqualToString:@"install_shader"]) {
        return [[ShaderService sharedService] ensureShadersFolderForProfile:profile error:&err];
    }
    if ([_internalName isEqualToString:@"install_datapack"]) {
        return [[DataPackService sharedService] ensureDataPacksFolderForProfile:profile error:&err];
    }
    return nil;
}

/// Install 工具对应的资源类型（注册 DownloadTask 用）
- (NSString *)resourceTypeForTool {
    if ([_internalName isEqualToString:@"install_mod"]) return DownloadTaskResourceTypeMod;
    if ([_internalName isEqualToString:@"install_resourcepack"]) return DownloadTaskResourceTypeResourcePack;
    if ([_internalName isEqualToString:@"install_shader"]) return DownloadTaskResourceTypeShader;
    if ([_internalName isEqualToString:@"install_datapack"]) return DownloadTaskResourceTypeDataPack;
    return DownloadTaskResourceTypeMod;
}

- (void)performResourceInstall:(NSDictionary *)params
                    completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *slugOrId = [params[@"slugOrId"] isKindOfClass:[NSString class]] ? params[@"slugOrId"] : @"";
    if (slugOrId.length == 0) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.missing_slug", nil)}]);
        return;
    }

    // 目标目录
    NSString *folder = [self resolvedFolderForParams:params];
    if (folder.length == 0) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:500 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.cannot_resolve_folder", nil)}]);
        return;
    }
    // latest 别名：等价于不指定版本（自动选最新 release）
    NSString *versionId = [params[@"versionId"] isKindOfClass:[NSString class]] ? params[@"versionId"] : @"";
    if (aiIsLatestAlias(versionId)) versionId = @"";
    // 版本匹配（HMCL AE 式自动化关键）：install_mod 自动按实例 MC 版本过滤，
    // 其余资源类型仅在显式传入 gameVersion 时过滤
    NSString *gameVersion = [params[@"gameVersion"] isKindOfClass:[NSString class]] ? params[@"gameVersion"] : @"";
    if (gameVersion.length == 0 && [_internalName isEqualToString:@"install_mod"]) {
        gameVersion = [AiAssetNetworkUtil resolveGameVersionForParams:params];
    }

    NSString *encSlug = [slugOrId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    // 1. 项目信息（取项目名做 displayName；官方 → MCIM → 官方兜底）
    NSString *projectPath = [NSString stringWithFormat:@"/project/%@", encSlug];
    [AiAssetNetworkUtil getModrinthJSONWithPath:projectPath completion:^(id _Nullable projectJSON, NSString * _Nullable projectSource, NSError * _Nullable projectError) {
        if (projectError) {
            completion(nil, projectError);
            return;
        }
        NSString *projectTitle = @"";
        if ([projectJSON isKindOfClass:[NSDictionary class]] && [projectJSON[@"title"] isKindOfClass:[NSString class]]) {
            projectTitle = projectJSON[@"title"];
        }
        [self fetchVersionsForSlug:encSlug versionId:versionId gameVersion:gameVersion completion:^(NSString * _Nullable filename, NSURL * _Nullable fileURL, NSString * _Nullable sha1, NSError * _Nullable verError) {
            if (verError) {
                completion(nil, verError);
                return;
            }
            NSString *displayName = projectTitle.length > 0 ? projectTitle : filename;
            NSString *safeFile = [AiAssetNetworkUtil safeFileName:filename];

            // Sodium 连带 Podium/Podium Port（屏蔽 Sodium 的启动器检测，否则游戏强制崩溃）
            BOOL isModInstall = [_internalName isEqualToString:@"install_mod"];
            NSString *lowerIdent = [NSString stringWithFormat:@"%@ %@", slugOrId, projectTitle].lowercaseString;
            BOOL needsPodium = isModInstall && ([lowerIdent rangeOfString:@"sodium"].location != NSNotFound);
            // Iris 提醒（建议渲染器切 Zink）
            BOOL isIris = [lowerIdent rangeOfString:@"iris"].location != NSNotFound;

            BOOL wait = aiWaitRequested(params);

            // 组装最终完成文案（依赖提醒 + Iris 提醒 + Podium 连带说明）
            void (^finishWithNote)(NSString * _Nullable, NSString * _Nullable podiumNote) = ^(NSString * _Nullable result, NSString * _Nullable podiumNote) {
                NSMutableString *final = [NSMutableString stringWithString:result ?: @""];
                if (podiumNote.length > 0) [final appendFormat:localize(@"ai.asset.note_join_fmt", nil), podiumNote];
                [final appendString:localize(@"ai.asset.note_missing_deps", nil)];
                if (isIris) {
                    [final appendString:localize(@"ai.asset.note_iris_zink", nil)];
                }
                completion(final, nil);
            };

            if (wait) {
                [AiAssetInstaller downloadFileFromURL:fileURL
                                             filename:safeFile
                                               folder:folder
                                          displayName:displayName
                                         resourceType:[self resourceTypeForTool]
                                          expectedSHA1:sha1
                                    waitForCompletion:YES
                                           completion:^(NSString * _Nullable result, NSError * _Nullable error) {
                    if (error) {
                        completion(nil, error);
                        return;
                    }
                    if (needsPodium) {
                        // Sodium：先连带安装 Podium（或 Podium Port），再回调最终文案
                        [self installPodiumCompanionForGameVersion:(gameVersion.length > 0 ? gameVersion : @"")
                                                            profile:[AiAssetNetworkUtil resolveProfileName:params]
                                                         completion:^(BOOL podOK, NSString * _Nullable podName, NSString * _Nullable podMsg) {
                            NSString *note = podOK
                                ? [NSString stringWithFormat:localize(@"ai.asset.podium_installed_fmt", nil), podName ?: @"Podium"]
                                : localize(@"ai.asset.podium_failed_note", nil);
                            finishWithNote(result, note);
                        }];
                    } else {
                        finishWithNote(result, nil);
                    }
                }
                                          onFinished:nil];
            } else {
                // 后台执行：注册任务后立即返回，下载继续，完成后自动连带 Podium（不回调 AI）
                [AiAssetInstaller downloadFileFromURL:fileURL
                                             filename:safeFile
                                               folder:folder
                                          displayName:displayName
                                         resourceType:[self resourceTypeForTool]
                                          expectedSHA1:sha1
                                    waitForCompletion:NO
                                           completion:^(NSString * _Nullable bgResult, NSError * _Nullable bgError) {
                    if (bgError) {
                        completion(nil, bgError);
                        return;
                    }
                    NSMutableString *final = [NSMutableString stringWithString:bgResult ?: @""];
                    if (needsPodium) {
                        [final appendString:localize(@"ai.asset.bg_podium_note", nil)];
                    }
                    [final appendString:localize(@"ai.asset.bg_task_note", nil)];
                    completion(final, nil);
                }
                                          onFinished:^(BOOL success, NSString * _Nullable message) {
                    // 后台下载终态：成功且为 Sodium → 后台连带安装 Podium（结果不回调 AI）
                    if (!success || !needsPodium) return;
                    [self installPodiumCompanionForGameVersion:(gameVersion.length > 0 ? gameVersion : @"")
                                                        profile:[AiAssetNetworkUtil resolveProfileName:params]
                                                     completion:^(BOOL podOK, NSString * _Nullable podName, NSString * _Nullable podMsg) {
                        if (!podOK) {
                            NSLog(@"[AI] Sodium 连带安装 Podium 失败：%@", podMsg ?: @"");
                        }
                    }];
                }];
            }
        }];
    }];
}

/// Sodium 连带安装：依次尝试 Podium / Podium Port（按 gameVersion 匹配版本，装到 mods 目录）
- (void)installPodiumCompanionForGameVersion:(NSString *)gameVersion
                                      profile:(NSString *)profile
                                   completion:(void (^)(BOOL success, NSString * _Nullable installedName, NSString * _Nullable message))completion {
    NSArray *candidateSlugs = @[@"podium", @"podium-port"];
    __weak typeof(self) weakSelf = self;

    void (^tryAtIndex)(NSUInteger) = ^(NSUInteger idx) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (idx >= candidateSlugs.count) {
            completion(NO, nil, localize(@"ai.asset.podium_both_failed", nil));
            return;
        }
        NSString *slug = candidateSlugs[idx];
        NSError *err = nil;
        NSString *modsFolder = [[ModService sharedService] ensureModsFolderForProfile:profile error:&err];
        if (modsFolder.length == 0) {
            completion(NO, nil, localize(@"ai.asset.cannot_resolve_mods_dir", nil));
            return;
        }
        [strongSelf fetchVersionsForSlug:slug
                                versionId:@""
                              gameVersion:gameVersion
                               completion:^(NSString * _Nullable filename, NSURL * _Nullable fileURL, NSString * _Nullable sha1, NSError * _Nullable verError) {
            if (verError || !fileURL) {
                // 当前 slug 不适配 → 尝试下一个（如仅某版本有 Port）
                tryAtIndex(idx + 1);
                return;
            }
            NSString *safeFile = [AiAssetNetworkUtil safeFileName:filename];
            [AiAssetInstaller downloadFileFromURL:fileURL
                                         filename:safeFile
                                           folder:modsFolder
                                      displayName:[slug isEqualToString:@"podium"] ? @"Podium" : @"Podium Port"
                                     resourceType:DownloadTaskResourceTypeMod
                                      expectedSHA1:sha1
                                waitForCompletion:YES
                                       completion:^(NSString * _Nullable result, NSError * _Nullable error) {
                if (error) {
                    tryAtIndex(idx + 1);
                    return;
                }
                completion(YES, [slug isEqualToString:@"podium"] ? @"Podium" : @"Podium Port", nil);
            }
                                       onFinished:nil];
        }];
    };
    tryAtIndex(0);
}

/// 拉取项目版本列表并选择目标版本文件：
/// - versionId 非空：精确匹配该版本 id；
/// - gameVersion 非空：仅在其 game_versions 包含该 MC 版本的版本中选择（无匹配则报错）；
/// - 否则选 release 最新版本。
- (void)fetchVersionsForSlug:(NSString *)encSlug
                   versionId:(NSString *)versionId
                 gameVersion:(NSString *)gameVersion
                  completion:(void (^)(NSString * _Nullable filename, NSURL * _Nullable fileURL, NSString * _Nullable sha1, NSError * _Nullable error))completion {
    // featured=true 会在按 gameVersion 过滤时漏掉大量仅标记非 featured 的兼容版本，
    // 直接拉全量版本列表自行过滤（官方 → MCIM → 官方兜底）
    NSString *apiPath = [NSString stringWithFormat:@"/project/%@/version", encSlug];
    [AiAssetNetworkUtil getModrinthJSONWithPath:apiPath completion:^(id _Nullable json, NSString * _Nullable usedSource, NSError * _Nullable error) {
        if (error) {
            completion(nil, nil, nil, error);
            return;
        }
        NSArray *versions = [json isKindOfClass:[NSArray class]] ? json : nil;
        if (versions.count == 0) {
            completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.no_versions", nil)}]);
            return;
        }
        // gameVersion 兼容性过滤（Modrinth 版本对象的 game_versions 数组）
        if (gameVersion.length > 0) {
            NSMutableArray *filtered = [NSMutableArray array];
            for (id v in versions) {
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                NSArray *gvs = v[@"game_versions"];
                if ([gvs isKindOfClass:[NSArray class]] && [gvs containsObject:gameVersion]) {
                    [filtered addObject:v];
                }
            }
            if (filtered.count == 0) {
                completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404
                                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.no_version_for_mc_fmt", nil), gameVersion]}]);
                return;
            }
            versions = filtered;
        }
        // 选择版本
        NSDictionary *chosen = nil;
        if (versionId.length > 0) {
            for (id v in versions) {
                if ([v isKindOfClass:[NSDictionary class]] && [v[@"id"] isEqualToString:versionId]) { chosen = v; break; }
            }
            if (!chosen) {
                completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404
                                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.version_not_found_fmt", nil), versionId]}]);
                return;
            }
        } else {
            // 优先 release / latest，回退首个
            for (id v in versions) {
                if (![v isKindOfClass:[NSDictionary class]]) continue;
                id vt = v[@"version_type"];
                if ([vt isKindOfClass:[NSString class]] && [vt isEqualToString:@"release"]) { chosen = v; break; }
            }
            if (!chosen) chosen = [versions firstObject];
        }
        NSArray *files = [chosen isKindOfClass:[NSDictionary class]] ? chosen[@"files"] : nil;
        NSDictionary *file = ([files isKindOfClass:[NSArray class]] && files.count > 0) ? files[0] : nil;
        if (![file isKindOfClass:[NSDictionary class]]) {
            completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.no_files", nil)}]);
            return;
        }
        NSString *fileURLStr = file[@"url"];
        NSString *filename = file[@"filename"];
        NSString *sha1 = nil;
        NSDictionary *hashes = file[@"hashes"];
        if ([hashes isKindOfClass:[NSDictionary class]] && [hashes[@"sha1"] isKindOfClass:[NSString class]]) {
            sha1 = hashes[@"sha1"];
        }
        NSURL *fileURL = [NSURL URLWithString:[fileURLStr isKindOfClass:[NSString class]] ? fileURLStr : @""];
        if (![filename isKindOfClass:[NSString class]]) filename = @"download";
        if (!fileURL) {
            completion(nil, nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:404 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.invalid_download_url", nil)}]);
            return;
        }
        completion(filename, fileURL, sha1, nil);
    }];
}

#pragma mark - install_game_version（HMCL AE 式全自动直接安装）

- (void)performInstallGameVersion:(NSDictionary *)params
                       completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *versionId = [params[@"versionId"] isKindOfClass:[NSString class]] ? params[@"versionId"] : @"";
    if (versionId.length == 0) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.missing_version_id", nil)}]);
        return;
    }

    // wait=false：后台安装，立即返回（结果不回调，进度可用 check_downloads 查询）
    if (!aiWaitRequested(params)) {
        completion([NSString stringWithFormat:localize(@"ai.asset.bg_install_game_fmt", nil), versionId], nil);
        [AiAssetInstaller installVanillaVersionId:versionId completion:^(BOOL bgSuccess, NSString * _Nullable bgMessage) {
            if (!bgSuccess) {
                NSLog(@"[AI] 后台安装 MC %@ 失败：%@", versionId, bgMessage ?: @"");
            }
        }];
        return;
    }

    // 直接安装：进度由 MinecraftResourceDownloadTask 自动注册到下载中心（6 阶段 + autoPresentDetail），
    // 用户可在下载中心实时查看；无需打开下载页引导手动操作。
    [AiAssetInstaller installVanillaVersionId:versionId completion:^(BOOL success, NSString * _Nullable message) {
        if (success) {
            completion([NSString stringWithFormat:localize(@"ai.asset.game_installed_fmt", nil), versionId], nil);
        } else {
            completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:500
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.install_game_failed_fmt", nil), versionId, message ?: localize(@"resman.common.unknown_error", nil)]}]);
        }
    }];
}

#pragma mark - install_loader（Fabric/Quilt 直接安装；Forge/NeoForge/OptiFine 引导下载页）

- (void)performInstallLoader:(NSDictionary *)params
                  completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    NSString *mcVersion = [params[@"mcVersion"] isKindOfClass:[NSString class]] ? params[@"mcVersion"] : @"";
    NSString *loaderType = [params[@"loaderType"] isKindOfClass:[NSString class]] ? [params[@"loaderType"] lowercaseString] : @"";
    if (mcVersion.length == 0) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.missing_mc_version", nil)}]);
        return;
    }
    NSSet *validLoaders = [NSSet setWithObjects:@"fabric", @"forge", @"neoforge", @"quilt", @"optifine", nil];
    if (![validLoaders containsObject:loaderType]) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.invalid_loader_type", nil)}]);
        return;
    }

    // Fabric/Quilt：meta API 直装（profile JSON + 版本注册 + Fabric API），全程进度在下载中心展示
    if ([loaderType isEqualToString:@"fabric"] || [loaderType isEqualToString:@"quilt"]) {
        [self performFabricLikeLoaderInstall:params mcVersion:mcVersion loaderType:loaderType completion:completion];
        return;
    }

    // Forge/NeoForge/OptiFine：安装器需要运行 Java 图形安装器/处理器（进程内 JVM 只能创建一次），
    // 无法安全全自动，保留下载页引导
    NSString *profile = [AiAssetNetworkUtil resolveProfileName:params];
    NSString *gameDir = [AiAssetNetworkUtil resolveGameDirForProfile:profile];
    BOOL installed = [AiAssetNetworkUtil isGameVersionInstalled:mcVersion inGameDir:gameDir];

    [AiAssetNetworkUtil postShowDownloadPage];
    if (!installed) {
        completion([NSString stringWithFormat:localize(@"ai.asset.gui_installer_no_vanilla_fmt", nil), [loaderType capitalizedString], mcVersion, loaderType], nil);
    } else {
        completion([NSString stringWithFormat:localize(@"ai.asset.gui_installer_fmt", nil), [loaderType capitalizedString], mcVersion, loaderType], nil);
    }
}

/// Fabric/Quilt 直接安装（参考 DownloadViewController installFabricLikeLoader，去 UI 依赖）：
/// 1) 原版本体未装 → 自动先直装原版（installVanillaVersionId）；
/// 2) 解析 loader 版本（缺省取最新稳定版）→ 拉取 meta profile JSON；
/// 3) 注册安装任务（Modloader + Fabric 3 阶段 + autoPresentDetail）→ 写入 versions/{id}/{id}.json；
/// 4) 注册并选中实例 profile，post ReloadProfileList；
/// 5) Fabric（非 Quilt）自动安装 Fabric API 到 mods 目录（独立 Mod 下载任务）。
- (void)performFabricLikeLoaderInstall:(NSDictionary *)params
                             mcVersion:(NSString *)mcVersion
                            loaderType:(NSString *)loaderType
                            completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    BOOL isQuilt = [loaderType isEqualToString:@"quilt"];
    NSString *displayName = isQuilt ? @"Quilt" : @"Fabric";
    NSString *metaBase = isQuilt ? @"https://meta.quiltmc.org/v3/versions/loader"
                                 : @"https://meta.fabricmc.net/v2/versions/loader";
    // latest 别名：等价于不指定版本（下方自动取最新稳定版）
    NSString *loaderVersion = [params[@"loaderVersion"] isKindOfClass:[NSString class]] ? params[@"loaderVersion"] : @"";
    if (aiIsLatestAlias(loaderVersion)) loaderVersion = @"";

    // wait=false：后台安装，立即返回；后续 completion 全部吞掉（下载中心/check_downloads 可查进度）
    if (!aiWaitRequested(params)) {
        completion([NSString stringWithFormat:localize(@"ai.asset.bg_install_loader_fmt", nil), displayName, mcVersion, isQuilt ? @"" : localize(@"ai.asset.fabric_api_suffix", nil)], nil);
        completion = ^(NSString * _Nullable r, NSError * _Nullable e) {
            // 后台执行：终态结果不回传（进度与结果均可见于下载中心）
        };
    }

    // 阶段下标与 PLTaskStagesFabricExtra() 一致
    static const NSUInteger kAiFabricStageProfile = 0;
    static const NSUInteger kAiFabricStageLoaderLibs = 1;
    static const NSUInteger kAiFabricStageWriteJSON = 2;

    __weak typeof(self) weakSelf = self;

    // 原版预装检查 + 安装
    NSString *profile = [AiAssetNetworkUtil resolveProfileName:params];
    NSString *gameDir = [AiAssetNetworkUtil resolveGameDirForProfile:profile];
    BOOL vanillaInstalled = [AiAssetNetworkUtil isGameVersionInstalled:mcVersion inGameDir:gameDir];

    void (^continueWithLoader)(void) = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf continueFabricInstallWithMetaBase:metaBase
                                           displayName:displayName
                                               isQuilt:isQuilt
                                             mcVersion:mcVersion
                                         loaderVersion:loaderVersion
                                         profileStage:kAiFabricStageProfile
                                            libsStage:kAiFabricStageLoaderLibs
                                            jsonStage:kAiFabricStageWriteJSON
                                            completion:completion];
    };

    if (vanillaInstalled) {
        continueWithLoader();
        return;
    }

    // 自动预装原版（HMCL AE 式全自动；进度在下载中心以独立 MC 任务展示）
    [AiAssetInstaller installVanillaVersionId:mcVersion completion:^(BOOL success, NSString * _Nullable message) {
        if (!success) {
            completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:500
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.preinstall_vanilla_failed_fmt", nil), mcVersion, message ?: localize(@"resman.common.unknown_error", nil), displayName]}]);
            return;
        }
        continueWithLoader();
    }];
}

/// 原版就绪后的 Fabric/Quilt 安装主体（解析 loader 版本 → meta profile → 写 JSON → Fabric API）
- (void)continueFabricInstallWithMetaBase:(NSString *)metaBase
                               displayName:(NSString *)displayName
                                   isQuilt:(BOOL)isQuilt
                                 mcVersion:(NSString *)mcVersion
                              loaderVersion:(NSString *)loaderVersion
                               profileStage:(NSUInteger)profileStage
                                  libsStage:(NSUInteger)libsStage
                                  jsonStage:(NSUInteger)jsonStage
                                completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    __weak typeof(self) weakSelf = self;

    void (^startWithLoaderVersion)(NSString *) = ^(NSString *resolvedLoaderVersion) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
        NSString *downloadSource = getPrefObject(@"general.download_source") ?: @"official";
        NSString *taskName = [NSString stringWithFormat:@"%@-%@-%@", isQuilt ? @"quilt" : @"fabric", mcVersion, resolvedLoaderVersion];
        DownloadTaskItem *task = [manager registerTaskWithResourceType:DownloadTaskResourceTypeModloader
                                                          resourceName:taskName
                                                           displayName:[NSString stringWithFormat:@"%@ %@ (%@)", displayName, resolvedLoaderVersion, mcVersion]
                                                        downloadSource:downloadSource
                                                               rawTask:nil
                                                        supportsResume:NO
                                                               iconURL:nil];
        if (!task) {
            completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:500
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.register_task_failed", nil)}]);
            return;
        }
        [manager setTaskWithId:task.taskId stages:PLTaskStagesFabricExtra()];
        task.autoPresentDetail = YES;
        [manager setTaskWithId:task.taskId state:DownloadTaskStateDownloading];

        // 阶段0：获取加载器 profile
        [manager updateTaskWithId:task.taskId stageAtIndex:profileStage status:PLTaskStageStatusRunning];
        [manager updateTaskWithId:task.taskId currentStageIndex:profileStage];

        NSString *profileURLStr = [NSString stringWithFormat:@"%@/%@/%@/profile/json", metaBase, mcVersion, resolvedLoaderVersion];
        NSURL *profileURL = [NSURL URLWithString:profileURLStr];
        if (!profileURL) {
            [manager updateTaskWithId:task.taskId stageAtIndex:profileStage status:PLTaskStageStatusFailed];
            NSError *err = [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.invalid_profile_url", nil)}];
            [manager setTaskWithId:task.taskId completedWithError:err];
            completion(nil, err);
            return;
        }

        [AiAssetNetworkUtil getJSONFromURL:profileURL completion:^(id _Nullable json, NSError * _Nullable pError) {
            if (pError || ![json isKindOfClass:[NSDictionary class]]) {
                [manager updateTaskWithId:task.taskId stageAtIndex:profileStage status:PLTaskStageStatusFailed];
                [manager updateTaskWithId:task.taskId stageAtIndex:profileStage progress:0 message:pError.localizedDescription];
                NSError *err = pError ?: [NSError errorWithDomain:kAiAssetToolDomain code:2
                                                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.fetch_profile_failed_fmt", nil), displayName]}];
                [manager setTaskWithId:task.taskId completedWithError:err];
                completion(nil, err);
                return;
            }
            [manager updateTaskWithId:task.taskId stageAtIndex:profileStage status:PLTaskStageStatusCompleted];

            // 阶段2：写入版本 JSON（与 DownloadViewController installFabricLikeLoader 一致，用 POJAV_GAME_DIR）
            [manager updateTaskWithId:task.taskId stageAtIndex:jsonStage status:PLTaskStageStatusRunning];
            [manager updateTaskWithId:task.taskId currentStageIndex:jsonStage];

            NSDictionary *profileJson = (NSDictionary *)json;
            NSString *versionId = [profileJson[@"id"] isKindOfClass:[NSString class]] ? profileJson[@"id"] : @"";
            if (versionId.length == 0) {
                [manager updateTaskWithId:task.taskId stageAtIndex:jsonStage status:PLTaskStageStatusFailed];
                NSError *err = [NSError errorWithDomain:kAiAssetToolDomain code:3
                                                userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.profile_missing_id", nil)}];
                [manager setTaskWithId:task.taskId completedWithError:err];
                completion(nil, err);
                return;
            }

            const char *env = getenv("POJAV_GAME_DIR");
            NSString *gameDirRoot = (env && strlen(env) > 0) ? [NSString stringWithUTF8String:env] : NSHomeDirectory();

            // ★ Task303：AI 链静默唯一化（"下载模组端被吞"同源根治）。与 DVC
            //   弹窗链同源不同交互：AI 工具场景无 UI 命名窗预期，versions/<id>/
            //   已存在时自动 +2 后缀落新实例，防静默覆盖旧档；写入 JSON 内部
            //   id 同步重写保持与目录名一致（DVC 弹窗链见 installFabricLikeLoader）。
            NSString *ame303_aiDir = [gameDirRoot stringByAppendingPathComponent:
                                      [NSString stringWithFormat:@"versions/%@", versionId]];
            if ([NSFileManager.defaultManager fileExistsAtPath:ame303_aiDir]) {
                NSString *ame303_unique = [MinecraftResourceDownloadTask ame303_uniqueSuggestionForId:versionId];
                NSMutableDictionary *ame303_mutable = [profileJson mutableCopy];
                ame303_mutable[@"id"] = ame303_unique;
                profileJson = ame303_mutable;
                NSLog(@"[AI] Task303 loader install id uniquified: %@ -> %@", versionId, ame303_unique);
                versionId = ame303_unique;
            }

            NSString *jsonPath = [gameDirRoot stringByAppendingPathComponent:
                                  [NSString stringWithFormat:@"versions/%@/%@.json", versionId, versionId]];
            [[NSFileManager defaultManager] createDirectoryAtPath:[jsonPath stringByDeletingLastPathComponent]
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:nil];
            NSError *saveError = nil;
            NSData *jsonData = [NSJSONSerialization dataWithJSONObject:profileJson options:NSJSONWritingPrettyPrinted error:&saveError];
            if (!jsonData || ![jsonData writeToFile:jsonPath options:NSDataWritingAtomic error:&saveError]) {
                [manager updateTaskWithId:task.taskId stageAtIndex:jsonStage status:PLTaskStageStatusFailed];
                NSError *err = [NSError errorWithDomain:kAiAssetToolDomain code:4
                                                userInfo:@{NSLocalizedDescriptionKey: saveError.localizedDescription ?: localize(@"ai.asset.write_version_json_failed", nil)}];
                [manager setTaskWithId:task.taskId completedWithError:err];
                completion(nil, err);
                return;
            }

            // 注册并选中实例 profile（与正常安装流程一致）
            NSMutableDictionary *prof = [NSMutableDictionary dictionary];
            prof[@"name"] = versionId;
            prof[@"lastVersionId"] = versionId;
            // ★ Task271（271-a F3）：AI 安装流同步隔离口径 versions/<id>/game
            prof[@"gameDir"] = [NSString stringWithFormat:@"versions/%@/game", versionId];
            prof[@"type"] = @"custom";
            prof[@"created"] = [NSDate date].description;
            [PLProfiles.current saveProfile:prof withName:versionId];
            PLProfiles.current.selectedProfileName = versionId;
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
            [manager updateTaskWithId:task.taskId stageAtIndex:jsonStage status:PLTaskStageStatusCompleted];

            // Fabric 自动安装 Fabric API（独立 Mod 下载任务）；Quilt 用 QSL/QFAPI，跳过
            if (!isQuilt) {
                [manager updateTaskWithId:task.taskId stageAtIndex:libsStage status:PLTaskStageStatusRunning];
                [manager updateTaskWithId:task.taskId currentStageIndex:libsStage];
                [strongSelf installFabricAPIForGameVersion:mcVersion completion:^(BOOL apiOK, NSString * _Nullable apiMessage) {
                    if (apiOK) {
                        [manager updateTaskWithId:task.taskId stageAtIndex:libsStage status:PLTaskStageStatusCompleted];
                    } else {
                        // Fabric API 失败不阻塞加载器安装本身，仅标注阶段失败原因
                        [manager updateTaskWithId:task.taskId stageAtIndex:libsStage status:PLTaskStageStatusFailed];
                        [manager updateTaskWithId:task.taskId stageAtIndex:libsStage progress:0 message:apiMessage];
                    }
                    [manager setTaskWithId:task.taskId completedWithError:nil];
                    NSString *result = apiOK
                        ? [NSString stringWithFormat:localize(@"ai.asset.loader_done_fabricapi_fmt", nil), displayName, resolvedLoaderVersion, mcVersion]
                        : [NSString stringWithFormat:localize(@"ai.asset.loader_done_api_failed_fmt", nil), displayName, resolvedLoaderVersion, mcVersion, apiMessage ?: localize(@"ai.asset.unknown_reason", nil)];
                    completion(result, nil);
                }];
            } else {
                [manager updateTaskWithId:task.taskId stageAtIndex:libsStage status:PLTaskStageStatusSkipped];
                [manager setTaskWithId:task.taskId completedWithError:nil];
                completion([NSString stringWithFormat:localize(@"ai.asset.quilt_done_fmt", nil), resolvedLoaderVersion, mcVersion], nil);
            }
        }];
    };

    if (loaderVersion.length > 0) {
        startWithLoaderVersion(loaderVersion);
        return;
    }

    // 未指定 loader 版本：取最新稳定版（fallback 首个）
    NSString *listURLStr = [NSString stringWithFormat:@"%@/%@", metaBase, mcVersion];
    NSURL *listURL = [NSURL URLWithString:listURLStr];
    if (!listURL) {
        completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400
                                        userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.invalid_loader_list_url", nil)}]);
        return;
    }
    [AiAssetNetworkUtil getJSONFromURL:listURL completion:^(id _Nullable json, NSError * _Nullable error) {
        if (error) {
            NSLog(@"[AI] %@ 加载器版本列表请求失败（URL: %@，错误: %@）", displayName, listURLStr, error);
            completion(nil, error);
            return;
        }
        NSArray *list = [json isKindOfClass:[NSArray class]] ? json : nil;
        if (list.count == 0) {
            // 响应非数组或为空：打印实际类型与响应摘要，便于定位镜像劫持/错误网关
            NSString *body = [json isKindOfClass:[NSDictionary class]] ? [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:json options:0 error:nil] encoding:NSUTF8StringEncoding] : ([json isKindOfClass:[NSString class]] ? json : NSStringFromClass([json class]));
            NSLog(@"[AI] %@ 加载器版本列表为空（URL: %@，响应类型: %@，内容: %@）", displayName, listURLStr, NSStringFromClass([json class]), [body substringToIndex:MIN(body.length, 200)]);
            completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:404
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.no_loader_versions_fmt", nil), mcVersion, displayName]}]);
            return;
        }
        // 关键修复（install_loader "latest" 无法解析版本）：Fabric/Quilt meta 版本在嵌套的
        // loader.version，stable 在 loader.stable；兼容历史实现直接放顶层的 version/stable。
        NSString *picked = nil;
        for (id v in list) {
            if (![v isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *loaderObj = [v[@"loader"] isKindOfClass:[NSDictionary class]] ? v[@"loader"] : nil;
            NSString *ver = [loaderObj[@"version"] isKindOfClass:[NSString class]] ? loaderObj[@"version"] : nil;
            if (ver.length == 0 && [v[@"version"] isKindOfClass:[NSString class]]) ver = v[@"version"];
            BOOL stable = (loaderObj && [loaderObj[@"stable"] isKindOfClass:[NSNumber class]])
                ? [loaderObj[@"stable"] boolValue]
                : [v[@"stable"] boolValue];
            if (ver.length > 0 && stable) {
                picked = ver;
                break;
            }
        }
        if (!picked) {
            // fallback：没有标记 stable 时取首个条目
            NSDictionary *first = [list.firstObject isKindOfClass:[NSDictionary class]] ? list.firstObject : nil;
            NSDictionary *firstLoader = [first[@"loader"] isKindOfClass:[NSDictionary class]] ? first[@"loader"] : nil;
            if ([firstLoader[@"version"] isKindOfClass:[NSString class]] && [firstLoader[@"version"] length] > 0) picked = firstLoader[@"version"];
            else if ([first[@"version"] isKindOfClass:[NSString class]] && [first[@"version"] length] > 0) picked = first[@"version"];
        }
        if (picked.length == 0) {
            NSLog(@"[AI] 无法解析 %@ 加载器版本号（URL: %@，已遍历 %lu 个条目，首个条目: %@）", displayName, listURLStr, (unsigned long)list.count, list.firstObject);
            completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:404
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.cannot_parse_loader_version", nil)}]);
            return;
        }
        startWithLoaderVersion(picked);
    }];
}

/// 自动安装 Fabric API（slug=fabric-api，按 gameVersion 匹配版本，下载到 mods 目录，独立 Mod 任务）
- (void)installFabricAPIForGameVersion:(NSString *)mcVersion
                            completion:(void (^)(BOOL success, NSString * _Nullable message))completion {
    NSError *err = nil;
    NSString *modsFolder = [[ModService sharedService] ensureModsFolderForProfile:[AiAssetNetworkUtil resolveProfileName:@{}] error:&err];
    if (modsFolder.length == 0) {
        completion(NO, localize(@"ai.asset.cannot_resolve_mods_dir", nil));
        return;
    }
    [self fetchVersionsForSlug:@"fabric-api"
                     versionId:@""
                   gameVersion:mcVersion
                    completion:^(NSString * _Nullable filename, NSURL * _Nullable fileURL, NSString * _Nullable sha1, NSError * _Nullable verError) {
        if (verError) {
            completion(NO, verError.localizedDescription);
            return;
        }
        NSString *safeFile = [AiAssetNetworkUtil safeFileName:filename];
        [AiAssetInstaller downloadFileFromURL:fileURL
                                     filename:safeFile
                                       folder:modsFolder
                                  displayName:@"Fabric API"
                                 resourceType:DownloadTaskResourceTypeMod
                                  expectedSHA1:sha1
                                   completion:^(NSString * _Nullable result, NSError * _Nullable dError) {
            if (dError) {
                completion(NO, dError.localizedDescription);
            } else {
                completion(YES, nil);
            }
        }];
    }];
}

@end

#pragma mark - AiAssetNetworkUtil 实现

@implementation AiAssetNetworkUtil

+ (void)getJSONFromURL:(NSURL *)url completion:(void (^)(id _Nullable, NSError * _Nullable))completion {
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.empty_url", nil)}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"Prisma/1.0 (iOS)" forHTTPHeaderField:@"User-Agent"];
    request.timeoutInterval = 20.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error || !data) {
                if (completion) completion(nil, error ?: [NSError errorWithDomain:kAiAssetToolDomain code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.network_request_failed", nil)}]);
                return;
            }
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (status < 200 || status >= 300) {
                NSString *msg = (status == 404) ? localize(@"ai.asset.not_found_404", nil) : [NSString stringWithFormat:localize(@"ai.net.http_error_fmt", nil), (long)status];
                if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:status userInfo:@{NSLocalizedDescriptionKey: msg}]);
                return;
            }
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (completion) completion(json, nil);
        });
    }];
    [task resume];
}

/// Modrinth 请求源链：官方 → MCIM 镜像（mod.mcimirror.top）→ 官方重试
+ (void)getModrinthJSONWithPath:(NSString *)apiPath
                     completion:(void (^)(id _Nullable json, NSString * _Nullable usedSource, NSError * _Nullable error))completion {
    NSArray *bases = @[
        @"https://api.modrinth.com/v2",        // 官方（默认）
        @"https://mod.mcimirror.top/modrinth/v2", // MCIM 镜像
        @"https://api.modrinth.com/v2",        // 官方重试（镜像不可用时回退）
    ];
    [self getModrinthJSONFromBases:bases index:0 path:apiPath lastError:nil completion:completion];
}

+ (void)getModrinthJSONFromBases:(NSArray<NSString *> *)bases
                           index:(NSUInteger)index
                            path:(NSString *)path
                       lastError:(NSError * _Nullable)lastError
                       completion:(void (^)(id _Nullable json, NSString * _Nullable usedSource, NSError * _Nullable error))completion {
    if (!completion) return;
    if (path.length == 0) {
        completion(nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.empty_api_path", nil)}]);
        return;
    }
    if (index >= bases.count) {
        NSString *detail = lastError.localizedDescription ?: localize(@"resman.common.unknown_error", nil);
        completion(nil, nil, [NSError errorWithDomain:kAiAssetToolDomain code:1
                                             userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.both_sources_unavailable_fmt", nil), detail]}]);
        return;
    }
    NSURL *url = [NSURL URLWithString:[bases[index] stringByAppendingString:path]];
    if (!url) {
        [self getModrinthJSONFromBases:bases index:index + 1 path:path lastError:lastError completion:completion];
        return;
    }
    [self getJSONFromURL:url completion:^(id _Nullable json, NSError * _Nullable error) {
        if (json) {
            NSString *source = [bases[index] containsString:@"mcimirror"] ? localize(@"ai.asset.mcim_source_name", nil) : @"Modrinth";
            completion(json, source, nil);
            return;
        }
        // 当前源失败（网络错误/HTTP 非 2xx/JSON 解析失败）→ 切换下一源
        [self getModrinthJSONFromBases:bases index:index + 1 path:path lastError:error completion:completion];
    }];
}

+ (NSString *)safeFileName:(NSString *)rawName {
    if (rawName.length == 0) return @"download";
    NSMutableCharacterSet *bad = [NSMutableCharacterSet characterSetWithCharactersInString:@"/\\:"];
    NSArray *parts = [rawName componentsSeparatedByCharactersInSet:bad];
    return [parts componentsJoinedByString:@"_"];
}

+ (NSString *)resolveProfileName:(NSDictionary *)params {
    NSString *instance = [params[@"instance"] isKindOfClass:[NSString class]] ? params[@"instance"] : @"";
    if (instance.length > 0) return instance;
    NSString *name = [[PLProfiles current] selectedProfileName];
    return (name.length > 0) ? name : @"default";
}

+ (NSString *)resolveGameDirForProfile:(NSString *)profileName {
    NSString *profile = profileName.length ? profileName : @"default";
    @try {
        NSDictionary *profiles = [PLProfiles current].profiles;
        NSDictionary *prof = [profiles isKindOfClass:[NSDictionary class]] ? profiles[profile] : nil;
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0) {
                if ([gameDir isEqualToString:@"."]) {
                    const char *env = getenv("POJAV_GAME_DIR");
                    return env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
                }
                if ([gameDir isAbsolutePath]) return gameDir;
                const char *env = getenv("POJAV_GAME_DIR");
                NSString *base = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
                NSString *clean = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
                return [base stringByAppendingPathComponent:clean];
            }
        }
    } @catch (NSException *ex) {
        // ignore
    }
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return [NSString stringWithUTF8String:root];
    return NSHomeDirectory();
}

+ (BOOL)isGameVersionInstalled:(NSString *)mcVersion inGameDir:(NSString *)gameDir {
    if (mcVersion.length == 0 || gameDir.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    // 1. <gameDir>/versions/<mcVersion>/（目录含 .json）
    NSString *versionsDir = [gameDir stringByAppendingPathComponent:@"versions"];
    NSString *verPath = [versionsDir stringByAppendingPathComponent:mcVersion];
    if ([fm fileExistsAtPath:verPath isDirectory:&isDir] && isDir) return YES;
    if ([fm fileExistsAtPath:[verPath stringByAppendingPathExtension:@"json"]]) return YES;
    // 2. <gameDir>/<mcVersion>.json
    if ([fm fileExistsAtPath:[gameDir stringByAppendingPathComponent:[mcVersion stringByAppendingPathExtension:@"json"]]]) return YES;
    return NO;
}

+ (void)fetchVersionEntry:(NSString *)versionId
               completion:(void (^)(NSDictionary * _Nullable entry, NSError * _Nullable error))completion {
    // 版本清单源：默认 BMCLAPI 镜像，失败自动切官方源重试（不依赖 general.download_source 偏好）
    NSArray *manifestURLStrs = @[
        @"https://bmclapi2.bangbang93.com/mc/game/version_manifest_v2.json",
        @"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json",
    ];
    [self fetchVersionEntryFromManifests:manifestURLStrs
                                    index:0
                               versionId:versionId
                               lastError:nil
                               completion:completion];
}

+ (void)fetchVersionEntryFromManifests:(NSArray<NSString *> *)manifestURLStrs
                                 index:(NSUInteger)index
                             versionId:(NSString *)versionId
                             lastError:(NSError * _Nullable)lastError
                             completion:(void (^)(NSDictionary * _Nullable entry, NSError * _Nullable error))completion {
    if (index >= manifestURLStrs.count) {
        NSString *detail = lastError.localizedDescription ?: localize(@"resman.common.unknown_error", nil);
        if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:500
                                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.manifest_failed_fmt", nil), detail]}]);
        return;
    }
    NSURL *manifestURL = [NSURL URLWithString:manifestURLStrs[index]];
    if (!manifestURL) {
        [self fetchVersionEntryFromManifests:manifestURLStrs index:index + 1 versionId:versionId lastError:lastError completion:completion];
        return;
    }
    [self getJSONFromURL:manifestURL completion:^(id _Nullable json, NSError * _Nullable error) {
        if (error) {
            // 当前源失败 → 切换下一源（BMCLAPI → official）重试
            [self fetchVersionEntryFromManifests:manifestURLStrs index:index + 1 versionId:versionId lastError:error completion:completion];
            return;
        }
        NSDictionary *manifest = [json isKindOfClass:[NSDictionary class]] ? json : nil;
        NSArray *versions = [manifest[@"versions"] isKindOfClass:[NSArray class]] ? manifest[@"versions"] : nil;
        if (versions.count == 0) {
            [self fetchVersionEntryFromManifests:manifestURLStrs index:index + 1 versionId:versionId
                                      lastError:[NSError errorWithDomain:kAiAssetToolDomain code:2
                                                                  userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.invalid_manifest", nil)}]
                                      completion:completion];
            return;
        }

        // latest 别名解析（latest-release/latest/latest-snapshot）
        NSString *target = versionId;
        if ([target isEqualToString:@"latest"] || [target isEqualToString:@"latest-release"]) {
            NSDictionary *latest = [manifest[@"latest"] isKindOfClass:[NSDictionary class]] ? manifest[@"latest"] : nil;
            NSString *release = [latest[@"release"] isKindOfClass:[NSString class]] ? latest[@"release"] : nil;
            target = release.length > 0 ? release : getPrefObject(@"internal.latest_version.release");
        } else if ([target isEqualToString:@"latest-snapshot"]) {
            NSDictionary *latest = [manifest[@"latest"] isKindOfClass:[NSDictionary class]] ? manifest[@"latest"] : nil;
            NSString *snapshot = [latest[@"snapshot"] isKindOfClass:[NSString class]] ? latest[@"snapshot"] : nil;
            target = snapshot.length > 0 ? snapshot : getPrefObject(@"internal.latest_version.snapshot");
        }
        if (![target isKindOfClass:[NSString class]] || target.length == 0) {
            if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:404
                                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.cannot_resolve_target_version", nil)}]);
            return;
        }

        for (id v in versions) {
            if (![v isKindOfClass:[NSDictionary class]]) continue;
            if ([v[@"id"] isEqualToString:target]) {
                if (completion) completion(v, nil);
                return;
            }
        }
        if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:404
                                                        userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.asset.version_missing_in_manifest_fmt", nil), target]}]);
    }];
}

+ (void)ensureVersionJSONExists:(NSString *)versionId
                     completion:(void (^)(BOOL success))completion {
    if (versionId.length == 0) {
        if (completion) completion(NO);
        return;
    }
    const char *env = getenv("POJAV_GAME_DIR");
    NSString *gameDir = (env && strlen(env) > 0) ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
    if (gameDir.length == 0) {
        const char *home = getenv("POJAV_HOME");
        gameDir = (home && strlen(home) > 0) ? [NSString stringWithUTF8String:home] : NSHomeDirectory();
    }
    NSString *versionDir = [gameDir stringByAppendingPathComponent:
                            [NSString stringWithFormat:@"versions/%@", versionId]];
    NSString *versionJsonPath = [versionDir stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@.json", versionId]];

    // 1. 已存在，直接成功
    if ([NSFileManager.defaultManager fileExistsAtPath:versionJsonPath]) {
        if (completion) completion(YES);
        return;
    }

    // 2. 拉清单取条目 → 下载 version JSON → 落盘
    [self fetchVersionEntry:versionId completion:^(NSDictionary * _Nullable entry, NSError * _Nullable error) {
        if (!entry) {
            if (completion) completion(NO);
            return;
        }
        NSString *versionJSONURL = [entry[@"url"] isKindOfClass:[NSString class]] ? entry[@"url"] : nil;
        if (versionJSONURL.length == 0) {
            if (completion) completion(NO);
            return;
        }
        NSURL *jsonURL = [NSURL URLWithString:versionJSONURL];
        if (!jsonURL) {
            if (completion) completion(NO);
            return;
        }
        [self getJSONFromURL:jsonURL completion:^(id _Nullable json, NSError * _Nullable jError) {
            if (jError || ![json isKindOfClass:[NSDictionary class]]) {
                // 官方域名失败 → BMCLAPI 镜像域名替换后重试（下载源自动兜底）
                NSString *mirrored = [versionJSONURL stringByReplacingOccurrencesOfString:@"piston-meta.mojang.com"
                                                                                withString:@"bmclapi2.bangbang93.com"];
                mirrored = [mirrored stringByReplacingOccurrencesOfString:@"launchermeta.mojang.com"
                                                               withString:@"bmclapi2.bangbang93.com"];
                if ([mirrored isEqualToString:versionJSONURL]) {
                    if (completion) completion(NO);
                    return;
                }
                NSURL *mirrorURL = [NSURL URLWithString:mirrored];
                if (!mirrorURL) {
                    if (completion) completion(NO);
                    return;
                }
                [self getJSONFromURL:mirrorURL completion:^(id _Nullable mJson, NSError * _Nullable mError) {
                    if (mError || ![mJson isKindOfClass:[NSDictionary class]]) {
                        if (completion) completion(NO);
                        return;
                    }
                    [self writeVersionJSON:mJson toPath:versionJsonPath versionDir:versionDir completion:completion];
                }];
                return;
            }
            [self writeVersionJSON:json toPath:versionJsonPath versionDir:versionDir completion:completion];
        }];
    }];
}

/// 版本 JSON 落盘（创建目录 + 原子写入）
+ (void)writeVersionJSON:(NSDictionary *)json
                  toPath:(NSString *)versionJsonPath
               versionDir:(NSString *)versionDir
               completion:(void (^)(BOOL success))completion {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) {
        if (completion) completion(NO);
        return;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:versionDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
    BOOL ok = [data writeToFile:versionJsonPath options:NSDataWritingAtomic error:nil];
    if (completion) completion(ok);
}

+ (NSString *)resolveGameVersionForParams:(NSDictionary *)params {
    // 1. 显式 gameVersion 参数优先
    NSString *explicit = [params[@"gameVersion"] isKindOfClass:[NSString class]] ? params[@"gameVersion"] : @"";
    if (explicit.length > 0) return explicit;

    // 2. 实例 profile 的 lastVersionId（归一化剥离加载器后缀）
    NSString *profileName = [self resolveProfileName:params];
    @try {
        NSDictionary *profiles = [PLProfiles current].profiles;
        NSDictionary *prof = [profiles isKindOfClass:[NSDictionary class]] ? profiles[profileName] : nil;
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *lastVersionId = [prof[@"lastVersionId"] isKindOfClass:[NSString class]] ? prof[@"lastVersionId"] : @"";
            if (lastVersionId.length > 0) {
                return [self normalizeGameVersion:lastVersionId];
            }
        }
    } @catch (NSException *ex) {
        // ignore
    }
    return @"";
}

/// 归一化版本号：剥离 fabric/forge/neoforge/quilt/optifine 加载器后缀。
/// 例：1.20.1-forge-47.2.0 → 1.20.1；fabric-loader-0.16.9-1.20.1 → 1.20.1；1.20.1 原样返回。
+ (NSString *)normalizeGameVersion:(NSString *)rawVersion {
    if (rawVersion.length == 0) return @"";
    NSArray *parts = [rawVersion componentsSeparatedByString:@"-"];
    if (parts.count == 1) return rawVersion;
    NSSet *loaderTokens = [NSSet setWithObjects:@"fabric", @"forge", @"neoforge", @"quilt", @"optifine", @"loader", nil];
    for (NSUInteger i = 0; i < parts.count; i++) {
        if (![loaderTokens containsObject:[parts[i] lowercaseString]]) continue;
        // 优先取 loader token 前一组件（1.20.1-forge-47.2.0），否则后一组件（fabric-loader-x-1.20.1）
        if (i > 0 && [self isPlausibleMCVersion:parts[i - 1]]) return parts[i - 1];
        if (i + 1 < parts.count && [self isPlausibleMCVersion:parts[i + 1]]) return parts[i + 1];
    }
    return rawVersion;
}

/// 判断字符串是否像 MC 版本号（1.20.1 / 1.7.10 / 24w14a 等）
+ (BOOL)isPlausibleMCVersion:(NSString *)s {
    if (s.length < 2) return NO;
    if (!isdigit([s characterAtIndex:0])) return NO;
    if ([s containsString:@"."]) return YES;
    // 快照形如 24w14a：数字开头 + w + 数字 + 字母结尾
    if (s.length >= 4 && [s characterAtIndex:s.length - 1] >= 'a' && [s characterAtIndex:s.length - 1] <= 'z') return YES;
    return NO;
}

+ (void)postShowDownloadPage {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
    });
}

@end

#pragma mark - AiAssetInstaller 实现

@implementation AiAssetInstaller

+ (void)downloadFileFromURL:(NSURL *)url
                   filename:(NSString *)filename
                     folder:(NSString *)folder
                displayName:(NSString *)displayName
               resourceType:(NSString *)resourceType
                expectedSHA1:(nullable NSString *)expectedSHA1
                 completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    [self downloadFileFromURL:url
                     filename:filename
                       folder:folder
                  displayName:displayName
                 resourceType:resourceType
                  expectedSHA1:expectedSHA1
            waitForCompletion:YES
                   completion:completion
                   onFinished:nil];
}

+ (void)downloadFileFromURL:(NSURL *)url
                   filename:(NSString *)filename
                     folder:(NSString *)folder
                displayName:(NSString *)displayName
               resourceType:(NSString *)resourceType
                expectedSHA1:(nullable NSString *)expectedSHA1
          waitForCompletion:(BOOL)waitForCompletion
                 completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion
                 onFinished:(nullable void (^)(BOOL success, NSString * _Nullable message))onFinished {
    if (!url || folder.length == 0 || filename.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, [NSError errorWithDomain:kAiAssetToolDomain code:400 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.incomplete_download_params", nil)}]);
        });
        return;
    }

    NSString *resourceName = filename;
    NSString *dispName = displayName.length > 0 ? displayName : filename;
    DownloadTaskItem *task = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:resourceType
                        resourceName:resourceName
                         displayName:dispName
                      downloadSource:@"Modrinth"
                             rawTask:nil
                      supportsResume:YES
                             iconURL:nil];
    task.downloadURL = url.absoluteString;
    [[DownloadTaskManager sharedManager] setTaskWithId:task.taskId state:DownloadTaskStateDownloading];

    // 下载候选：官方 CDN 优先，MCIM 镜像兜底（cdn.modrinth.com → cdn.mcimirror.top）
    NSMutableArray<NSURL *> *candidates = [NSMutableArray arrayWithObject:url];
    NSString *urlStr = url.absoluteString ?: @"";
    if ([urlStr containsString:@"cdn.modrinth.com"]) {
        NSString *mirrored = [urlStr stringByReplacingOccurrencesOfString:@"https://cdn.modrinth.com"
                                                                withString:@"https://cdn.mcimirror.top"];
        NSURL *mirrorURL = [NSURL URLWithString:mirrored];
        if (mirrorURL) [candidates addObject:mirrorURL];
    }

    PLDownloadRequest *request = [[PLDownloadRequest alloc] init];
    request.candidateURLs = candidates;
    if (expectedSHA1.length > 0) request.expectedSHA1 = expectedSHA1;
    request.destinationPath = [folder stringByAppendingPathComponent:filename];
    request.taskIdentifier = task.taskId;
    request.allowZipFallbackCheck = YES;

    // wait=false：任务已注册，立即回调「已加入后台下载」，AI 可继续其它工作
    if (!waitForCompletion) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion([NSString stringWithFormat:localize(@"ai.asset.bg_download_fmt", nil), dispName, task.taskId, [folder lastPathComponent], filename], nil);
            }
        });
    }

    __block int64_t downloadedBytes = 0;
    __block NSTimeInterval lastReport = 0;
    __block int64_t reportedTotal = -1;

    [[PLDownloadClient sharedClient] startRequest:request
        progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
            // 进度回调节流 ≤ 200ms
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            if ((now - lastReport) < 0.2) return;
            lastReport = now;
            downloadedBytes += deltaBytes;
            if (totalExpectedBytes > 0) reportedTotal = totalExpectedBytes;
            double progress = -1;
            if (reportedTotal > 0) progress = (double)downloadedBytes / (double)reportedTotal;
            [[DownloadTaskManager sharedManager] updateTaskWithId:task.taskId
                                                         progress:progress
                                                       totalBytes:reportedTotal
                                                  downloadedBytes:downloadedBytes];
        }
        speed:^(int64_t bytesPerSecond) {
            [[DownloadTaskManager sharedManager] updateTaskWithId:task.taskId
                                                            speed:(double)bytesPerSecond
                                           estimatedTimeRemaining:-1];
        }
        completion:^(BOOL success, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!success) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:task.taskId
                                                      completedWithError:error ?: [NSError errorWithDomain:kAiAssetToolDomain code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.download_failed", nil)}]];
                    if (onFinished) onFinished(NO, error.localizedDescription ?: localize(@"ai.asset.download_failed", nil));
                    if (waitForCompletion && completion) {
                        completion(nil, error ?: [NSError errorWithDomain:kAiAssetToolDomain code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.asset.download_failed", nil)}]);
                    }
                    return;
                }
                [[DownloadTaskManager sharedManager] setTaskWithId:task.taskId completedWithError:nil];
                if (onFinished) onFinished(YES, nil);
                if (waitForCompletion && completion) {
                    NSString *result = [NSString stringWithFormat:localize(@"ai.asset.installed_fmt", nil), dispName, [folder lastPathComponent], filename];
                    completion(result, nil);
                }
            });
        }];
}

+ (void)installVanillaVersionId:(NSString *)versionId
                     completion:(void (^)(BOOL success, NSString * _Nullable message))completion {
    if (versionId.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, localize(@"ai.asset.missing_version", nil)); });
        return;
    }

    // 1. 拉清单条目（含 version JSON 的下载 url；latest-release/latest-snapshot 在此解析）
    [AiAssetNetworkUtil fetchVersionEntry:versionId completion:^(NSDictionary * _Nullable entry, NSError * _Nullable error) {
        if (!entry) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, error.localizedDescription ?: localize(@"ai.asset.version_not_in_manifest", nil));
            });
            return;
        }
        NSString *resolvedId = [entry[@"id"] isKindOfClass:[NSString class]] ? entry[@"id"] : versionId;

        // 2. 先确保 version JSON 落盘（BMCLAPI 域名替换；也保证 remoteVersionList 未加载时
        //    downloadVersionMetadata: 走本地 JSON 分支仍可继续下载 libraries/assets）
        [AiAssetNetworkUtil ensureVersionJSONExists:resolvedId completion:^(BOOL jsonOK) {
            if (!jsonOK) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(NO, localize(@"ai.asset.download_version_json_failed", nil));
                });
                return;
            }

            // 3. MinecraftResourceDownloadTask 完整安装（版本 JSON/库/资源）。
            //    downloadVersion: 内部自动注册 DownloadTaskManager 任务（6 阶段 + autoPresentDetail），
            //    下载中心/统一进度页实时展示进度；对已存在且 SHA1 正确的文件自动跳过。
            dispatch_async(dispatch_get_main_queue(), ^{
                __block BOOL errored = NO;
                MinecraftResourceDownloadTask *task = [MinecraftResourceDownloadTask new];
                task.maxRetryCount = 3;
                task.handleError = ^{
                    errored = YES;
                };

                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    [task downloadVersion:entry];

                    // 轮询等待完成（最长 30 分钟，与 ensureVanillaInstalled 一致）。
                    // prepareForDownload 会重建 progress，故每轮重新取值，避免 KVO 悬空。
                    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:30 * 60];
                    BOOL succeeded = NO;
                    while ([deadline timeIntervalSinceNow] > 0) {
                        if (errored) break;
                        NSProgress *p = task.progress;
                        if (p && p.finished) {
                            succeeded = !p.cancelled;
                            break;
                        }
                        [NSThread sleepForTimeInterval:0.5];
                    }

                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (succeeded) {
                            // 4. 注册并选中实例 profile（与 downloadVanillaVersion: 一致），刷新版本列表
                            NSMutableDictionary *profile = [NSMutableDictionary dictionary];
                            profile[@"name"] = resolvedId;
                            profile[@"lastVersionId"] = resolvedId;
                            // ★ Task271（271-a F3）：AI 原版安装同步隔离口径 versions/<id>/game
                            profile[@"gameDir"] = [NSString stringWithFormat:@"versions/%@/game", resolvedId];
                            profile[@"type"] = @"custom";
                            profile[@"created"] = [NSDate date].description;
                            [PLProfiles.current saveProfile:profile withName:resolvedId];
                            PLProfiles.current.selectedProfileName = resolvedId;
                            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
                            if (completion) completion(YES, nil);
                        } else {
                            NSString *msg = errored ? localize(@"ai.asset.download_error", nil)
                                                    : localize(@"ai.asset.install_timeout", nil);
                            if (completion) completion(NO, msg);
                        }
                    });
                });
            });
        }];
    }];
}

@end