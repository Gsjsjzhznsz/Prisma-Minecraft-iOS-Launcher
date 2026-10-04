#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 镜像资源类型（决定 URL 走哪个镜像体系，以及读取哪个策略偏好键）
typedef NS_ENUM(NSInteger, PLMirrorResourceType) {
    /// 游戏本体 / 库 / 资产文件（Mojang 系分发文件），走 BMCLAPI 镜像
    PLMirrorResourceTypeGameFile = 0,
    /// Modrinth / CurseForge API 查询，走 MCIM 镜像
    PLMirrorResourceTypeAssetSearch = 1,
    /// Mod / 光影 / 资源包文件 CDN 下载，走 MCIM 镜像
    PLMirrorResourceTypeAssetDownload = 2,
    /// 加载器 meta / maven / installer 文件，走 BMCLAPI 镜像
    PLMirrorResourceTypeModLoader = 3,
};

/// 镜像使用策略
typedef NS_ENUM(NSInteger, PLMirrorPolicy) {
    /// 官方优先，镜像 URL 作为回退候选
    PLMirrorPolicyOfficialFirst = 0,
    /// 镜像优先，官方 URL 作为回退候选
    PLMirrorPolicyMirrorFirst = 1,
    /// 加载速度快优先（Task 138，参考 FCL）：按测速结果排序官方与镜像，
    /// 快的一方在前；未出结果前临时按镜像优先（目标用户群体镜像几乎
    /// 恒快，测速落地后自动纠正）
    PLMirrorPolicySpeedFirst = 2,
};

/// BMCLAPI 镜像根地址（https://bmclapi2.bangbang93.com，全工程唯一定义处，供他处引用）
FOUNDATION_EXPORT NSString *const PLMirrorBMCLAPIRootURL;

/// MCIM 镜像根地址（https://mod.mcimirror.top，全工程唯一定义处，供他处引用）
FOUNDATION_EXPORT NSString *const PLMirrorMCIMRootURL;

/// 统一镜像配置中心（纯工具类，无网络请求）
///
/// 收敛全工程的镜像 URL 映射与策略读取，替代散落在
/// MinecraftResourceDownloadTask / MCIMMirror / 各 installer 中的重写逻辑：
///   - GameFile / ModLoader → BMCLAPI（参考 ZalithLauncher 2 REPLACE_MIRROR_HOLDERS + Prisma 现有行为）
///   - AssetSearch / AssetDownload → MCIM（保持 MCIMMirror.m 现有精确行为）
///
/// 策略偏好键（值 official_first / mirror_first）：
///   - GameFile      → download.fileSource
///   - AssetSearch   → download.assetSearchSource
///   - AssetDownload → download.assetDownloadSource
///   - ModLoader     → download.modLoaderSource
/// 未设置时回退旧键 general.download_source（official → 官方优先；bmclapi / mcim → 镜像优先），
/// 再回退默认官方优先（为 Phase 4 设置项迁移预留平滑过渡）。
///
/// 特殊规则：MirrorFirst 时 GameFile 的资产资源（resources.download.minecraft.net）
/// 仍官方优先，以减轻镜像源压力（参考 ZalithLauncher 2 的设计）。
///
/// 使用方式：
///   NSURL *url = [PLMirrorCenter preferredURLForOriginalURL:originalURL
///                                               resourceType:PLMirrorResourceTypeGameFile];
///   NSArray<NSURL *> *candidates = [PLMirrorCenter candidateURLsForOriginalURL:originalURL
///                                                                   resourceType:PLMirrorResourceTypeGameFile];
@interface PLMirrorCenter : NSObject

/// 按当前策略返回候选 URL 数组（含原始 URL 与镜像 URL，去重，按尝试顺序排序）
/// 无法识别的主机原样返回仅含原始 URL 的数组
/// @param originalURL 原始（官方）URL
/// @param type 资源类型（决定镜像体系与策略键）
+ (NSArray<NSURL *> *)candidateURLsForOriginalURL:(NSURL *)originalURL
                                     resourceType:(PLMirrorResourceType)type;

/// 便捷方法：取候选数组的第一个（当前策略下的首选 URL）
/// @param url 原始（官方）URL
/// @param type 资源类型（决定镜像体系与策略键）
+ (NSURL *)preferredURLForOriginalURL:(NSURL *)url
                         resourceType:(PLMirrorResourceType)type;

/// Modrinth API base URL（等价 MCIMMirror 同名能力：按 AssetSearch 策略返回官方或 MCIM 镜像基址）
+ (NSString *)modrinthAPIBaseURL;

/// CurseForge API base URL（等价 MCIMMirror 同名能力：按 AssetSearch 策略返回官方或 MCIM 镜像基址）
+ (NSString *)curseForgeAPIBaseURL;

/// Task162：MCIM 的 CurseForge API 镜像基址（https://mod.mcimirror.top/curseforge/v1）。
/// 公开常量口径供 CurseForgeAPI 的无 key 回落使用：MCIM 镜像免 x-api-key
///（服务端自带公共 key，实测 GET /mods/search 200），官方 api.curseforge.com
/// 则强制要求——无 key 设备唯一可用路径就是镜像。
+ (NSString *)mcimCurseForgeAPIBaseURL;

/// 读取指定资源类型当前生效的镜像策略（含旧键回退逻辑）
+ (PLMirrorPolicy)policyForType:(PLMirrorResourceType)type;

/// Task 138：任意策略为 speed_first 且测速缓存缺失/过期时，异步发起
/// 官方 vs 镜像竞速探测（双体系：BMCLAPI 系 / MCIM 系）。幂等可随时调用。
+ (void)startSpeedProbesIfNeeded;

/// Task218：镜像偏好的体系化布尔判定——把"当前策略是否应走镜像"收敛到
/// 唯一定义处，供仍停留在旧双轨判定的消费者（IconLoader 图标镜像等）
/// 迁移。mirror_first -> YES；official_first -> NO；speed_first -> 按当前
/// 测速赢家（结果未落地时镜像在前，与 candidateURLs 的临时序一致）。
+ (BOOL)mirrorPreferredForType:(PLMirrorResourceType)type;

/// Task218：镜像策略 -> 旧式下载源 token（official / bmclapi）。统一下载
/// 任务管理器（DownloadTaskItem.downloadSource 展示字段）的历史口径适配：
/// 显示层专用，任何路由决策都不得使用本方法（路由一律走
/// candidateURLsForOriginalURL / policyForType）。
+ (NSString *)legacySourceTokenForType:(PLMirrorResourceType)type;

@end

NS_ASSUME_NONNULL_END
