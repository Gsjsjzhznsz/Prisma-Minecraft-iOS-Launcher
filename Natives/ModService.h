//
//  ModService.h
//  AmethystMods
//
//  Created by Copilot on 2025-08-22.
//

#import <Foundation/Foundation.h>
#import "ModItem.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^ModListHandler)(NSArray<ModItem *> *mods);
typedef void(^ModMetadataHandler)(ModItem *item, NSError * _Nullable error);
typedef void(^ModDownloadHandler)(NSError * _Nullable error); // Added for download completion

@interface ModService : NSObject

@property (nonatomic, assign) BOOL onlineSearchEnabled;

+ (instancetype)sharedService;

// --- Local Mod Management ---
- (void)scanModsForProfile:(NSString *)profileName completion:(ModListHandler)completion;
- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion;
- (BOOL)toggleEnableForMod:(ModItem *)mod error:(NSError **)error;
- (BOOL)deleteMod:(ModItem *)mod error:(NSError **)error;

/// Task264：当前 profile 实际生效的 mods 目录（与 scanModsForProfile 同源同目录，
/// Task219 隔离优先语义）。模组管理页用于展示扫描目录提示行，并支持在文件 App 中定点打开。
- (nullable NSString *)ame264_effectiveModsFolderForProfile:(NSString *)profileName;

/// Task267（模组管理“下载了但列表不显示”终局修复——下载先于开页场景）：
/// 记录最近一次成功落盘的 mod 下载目标（profile/文件/时间戳）。
/// handlePLDownloadCompletion 成功路径调用；模组管理页 viewWillAppear 时与本页
/// 生效实例对账——页面在下载完成之后才打开（Task266 横幅的实时通知够不着）
/// 也能自解释“文件去了哪个实例”。
+ (void)ame267_noteLastModDownloadToProfile:(nullable NSString *)profileName
                                       file:(nullable NSString *)fileName;

/// Task267：读取最近一次 mod 下载落点记录。
/// 返回 @{ @"profile": NSString, @"file": NSString, @"ts": NSNumber(double) }；
/// 从未成功落盘过 mod 时返回 nil。
+ (nullable NSDictionary<NSString *, id> *)ame267_lastModDownload;

// --- Online Mod Downloading ---
- (void)downloadMod:(ModItem *)mod toProfile:(NSString *)profileName completion:(ModDownloadHandler)completion;

/// 下载 Mod 并上报进度
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString *)profileName
            progress:(void (^)(NSProgress *downloadProgress))progress
          completion:(ModDownloadHandler)completion;

/// 下载 Mod 并启用 SHA1 校验（spec Task 5.1）。
/// expectedSHA1 来自版本模型 primaryFile[@"hashes"][@"sha1"]（Modrinth files[].hashes.sha1 /
/// CurseForge hashes algo=1），传入即启用校验，校验失败由统一下载器按镜像/退避节奏重试；
/// 为 nil 时不做 SHA1 校验，靠 zip EOCD 兜底校验保证完整性。
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString *)profileName
       expectedSHA1:(nullable NSString *)expectedSHA1
           progress:(nullable void (^)(NSProgress *downloadProgress))progress
         completion:(ModDownloadHandler)completion;

// --- Utility ---
- (NSString *)iconCachePathForURL:(NSString *)urlString;

/// 获取当前 profile 的 mods 目录，不存在时自动创建
- (nullable NSString *)ensureModsFolderForProfile:(NSString *)profileName error:(NSError **)error;

/// Task219（⑪ 版本隔离自动识别）：profile 的隔离态。0 = 不隔离（gameDir
/// 缺失或 "." 且嗅探未命中）；1 = 显式隔离（versions/<id> 或自定义
/// gameDir）；2 = 嗅探隔离（Task225：gameDir 为 "." 但 versions/<vid>/
/// 下已有 mods/saves——上游 PCL auto 语义）。
+ (NSInteger)ame219_isolationStateForProfile:(NSString *)profileName;

/// Task225：目录形状嗅探（上游 ameVISniffVersionFolder 同源规则）——
/// versions/<vid>/game 优先、旧口径 versions/<vid>/ 兑底，mods/saves 有
/// 任一非隐藏条目即返回该隔离目录绝对路径；不命中返回 nil。
+ (nullable NSString *)ame225_sniffedIsolationGameDirForProfile:(NSDictionary *)prof;

/// ★ Task271（271-a F2 自适应恢复）：启动自愈——注册表与运行时行为对齐。
/// 对 gameDir 缺失/"." 且嗅探命中隔离数据的 profile，落定 gameDir 为隔离
/// 目录（幂等；已显式配置的条目绝不碰；SceneDelegate 启动钩子调用）。
+ (void)ame271_selfHealStrandedIsolation;

@end

NS_ASSUME_NONNULL_END
