#import <Foundation/Foundation.h>
#import "ModpackAPI.h"
#import "ModVersion.h"
#import "ShaderVersion.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModrinthAPI : ModpackAPI
+ (instancetype)sharedInstance;

// 同步方法
- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters 
                      previousPageResult:(NSMutableArray *)modrinthSearchResult;

// 异步方法（推荐）
- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

/// ★ Task227（issue #10）：按项目 id 取展示名（依赖确认单用）
- (void)ame227_fetchProjectTitle:(NSString *)projectID
                       completion:(void (^)(NSString * _Nullable title, NSError * _Nullable error))completion;

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error))completion;

/// 异步加载整合包版本详情（修复点击整合包后加载列表过慢的问题）
/// 直接使用 NSURLSession，避免 dispatch_group_wait 同步阻塞
- (void)loadDetailsOfModAsync:(NSMutableDictionary *)item
                   completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

- (void)searchShaderWithFilters:(NSDictionary *)filters
                     completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

- (void)getVersionsForShaderWithID:(NSString *)shaderID
                        completion:(void (^)(NSArray<ShaderVersion *> * _Nullable versions, NSError * _Nullable error))completion;

#pragma mark - Server Projects (Modrinth Server Projects API)

/// 异步搜索服务器项目：优先使用 project_type=server，若结果为空则回退到 project_type=modpack
/// @param filters 搜索过滤条件（query/limit/offset/mcVersion/loader 等）
/// @param completion 完成回调，返回字典数组（含 apiSource=1, projectType 字段）
- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable results, NSError * _Nullable error))completion;

#pragma mark - Task226 (issue #10): Mod Dependencies (PCL2CE-style auto-download)

/// 按文件 SHA1 反查版本完整 JSON（GET /v2/version_file/{hash}）。
/// 返回的字典含 dependencies 数组（{version_id, project_id, dependency_type}）。
/// 仅依赖解析用；失败静默（依赖功能降级，不影响主下载）。
- (void)ame226_fetchVersionByFileSHA1:(NSString *)sha1
                            completion:(void (^)(NSDictionary * _Nullable versionJSON, NSError * _Nullable error))completion;

/// 取项目的最新兼容版本（GET /v2/project/{id}/version?game_versions&loaders）。
/// 返回 {filename, url, sha1, versionName, projectTitle}；无兼容版本返回 nil。
- (void)ame226_fetchLatestVersionForProject:(NSString *)projectID
                                 gameVersion:(NSString *)gameVersion
                                      loader:(NSString *)loader
                                  completion:(void (^)(NSDictionary * _Nullable info, NSError * _Nullable error))completion;

/// 异步获取服务器项目详情（含 server_address、关联整合包等字段）
/// @param serverID Modrinth 项目 ID
- (void)getServerDetailsForID:(NSString *)serverID
                   completion:(void (^)(NSDictionary * _Nullable details, NSError * _Nullable error))completion;

// 工具方法（供下载器调用）
- (NSString *)downloadURLForFile:(NSDictionary *)file;
- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType;
- (NSMutableDictionary *)projectForFileHash:(NSString *)sha1 projectType:(NSString *)projectType;

@property (nonatomic, assign) BOOL reachedLastPage;
@property (nonatomic, strong, nullable) NSError *lastError;

@end

NS_ASSUME_NONNULL_END