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

@end

NS_ASSUME_NONNULL_END
