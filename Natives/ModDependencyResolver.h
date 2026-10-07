//
//  ModDependencyResolver.h
//  模组依赖（前置）自动解析
//
//  ★ Task227（反馈 #4 / issue #10 重做）：移植上游 herbrine8403/
//  Amethyst-iOS-MyRemastered bc5ce914bc（含三轮 CI 修复后的最终形态），
//  单例名适配本仓（ModrinthAPI/CurseForgeAPI 均为 sharedInstance）。
//
//  背景：对比 ZalithLauncher2 的 _Download.Dependency.Tasks.kt 与
//  FoldCraftLauncher 的 ModrinthRemoteModRepository.loadDependencies()。
//  Task226 的实现挂在【下载完成后】且仅 Modrinth（CF 无 sha1 直接跳过）
//  ——装机实测零触发（ef1e3e2a 日志无任何 dep-resolve 锚点）。本轮改为
//  【下载前】解析 + 确认单（PCL2CE 式：一起安装 / 仅本体），双源归一。
//
//  职责边界：
//    * 本类只负责「解析出还需要哪些文件」，不负责下载；
//    * 下载交给调用方（ModService），便于复用既有的镜像回退、SHA1 校验；
//    * 不做版本降级/升级决策——同一项目已装其它版本时跳过，交由用户决定。
//
//  两个平台的依赖字段结构不同：
//    Modrinth  version.dependencies[] = { project_id, version_id,
//                                          dependency_type }
//    CurseForge data.dependencies[]   = { modId, relationType }
//  统一归一化成 ModDependencyItem 后再交给上层。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 依赖类型。只处理「必需」与「可选」；不兼容/嵌入/工具类不自动安装。
typedef NS_ENUM(NSInteger, ModDependencyKind) {
    ModDependencyKindRequired = 0,  /* 必需：装不上就不该继续 */
    ModDependencyKindOptional = 1,  /* 可选：提示用户，不默认装 */
};

/// 一条待安装的依赖（来自 Modrinth 或 CurseForge）
@interface ModDependencyItem : NSObject

@property(nonatomic, assign) NSInteger apiSource;         /* 1=Modrinth 2=CurseForge */
@property(nonatomic, copy, nullable) NSString *projectId; /* 项目 id（用于查版本） */
@property(nonatomic, copy, nullable) NSString *versionId; /* 指定版本（Modrinth 可能给出） */
@property(nonatomic, assign) ModDependencyKind kind;
@property(nonatomic, copy, nullable) NSString *displayName; /* 仅用于提示文案 */

@end

/// 解析结果
@interface ModDependencyPlan : NSObject

/// 需要安装的依赖（已按依赖顺序拓扑排序：被依赖者在前）
@property(nonatomic, copy) NSArray<ModDependencyItem *> *required;
/// 可选依赖（仅在 UI 上提示，不自动下载）
@property(nonatomic, copy) NSArray<ModDependencyItem *> *optional;
/// 因为「已安装同项目」而跳过的项目 id
@property(nonatomic, copy) NSArray<NSString *> *skippedAlreadyInstalled;
/// 因超出深度/数量上限而放弃的项目 id（防环 + 防爆）
@property(nonatomic, copy) NSArray<NSString *> *truncated;

@end

@interface ModDependencyResolver : NSObject

+ (instancetype)sharedResolver;

/// 从一份「版本详情」字典解析依赖树。
///
/// @param versionDetail 版本详情。Modrinth：GET project/{id}/version 的某一项
///                      （含 dependencies[]）；CurseForge：GET mods/{id}/files/{fid}
///                      的 data（含 dependencies[]）。
/// @param apiSource     1=Modrinth，2=CurseForge
/// @param installedProjectIds 本地已安装的项目 id 集合（用于跳过已装前置）
/// @param loader        当前实例的加载器（fabric/forge/neoforge/quilt），用于过滤
/// @param gameVersion   当前实例的 MC 版本，用于过滤
/// @param completion    主线程回调。plan 永不为 nil（无依赖时两个数组都为空）。
- (void)resolveDependenciesFromVersionDetail:(NSDictionary *)versionDetail
                                   apiSource:(NSInteger)apiSource
                        installedProjectIds:(nullable NSSet<NSString *> *)installedProjectIds
                                      loader:(nullable NSString *)loader
                                 gameVersion:(nullable NSString *)gameVersion
                                  completion:(void (^)(ModDependencyPlan *plan, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
