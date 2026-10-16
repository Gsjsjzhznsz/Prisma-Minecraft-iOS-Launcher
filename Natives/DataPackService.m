#import "utils.h"
//
//  DataPackService.m
//  Amethyst
//
//  数据包服务实现，结构参照 ShaderService/ModService
//  API 签名统一使用 NSString *profileName
//  修改：文件下载改走 PLDownloadClient 统一下载器（镜像候选 + SHA1 校验 + 增量下载 + 断点续传），
//        移除自建 NSURLSession 下载 delegate（spec optimize-download-system Task 4.2 / 5.1 / 5.2）
//  实现 pack.mcmeta 解析（pack_format / description）
//  支持 worldName 参数下载到指定世界的 datapacks 目录
//

#import "DataPackService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ModService.h"   // Task274-h S11: Task225 isolation sniff (ame225_sniffedIsolationGameDirForProfile)
#import "DataPackItem.h"
#import "UZKArchive.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "LauncherPreferences.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"

@interface DataPackService ()
// ---- PLDownloadClient 下载跟踪（key = DownloadTaskItem.taskId，即 PLDownloadRequest.taskIdentifier）----
@property (nonatomic, strong) NSLock *downloadStateLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadTaskItem *> *downloadTaskItems;
// 强持有当前 operation：pause 后 PLDownloadClient 会移除内部 task 映射，
// 需由 Service 保活，DownloadTaskManager 的 rawTask（weak）才能继续 pause/resume
@property (nonatomic, strong) NSMutableDictionary<NSString *, PLDownloadOperation *> *downloadOperations;
// 重试代数：retryHandler 重建请求后旧 operation 的迟到回调（如取消）按此丢弃
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadGenerations;
// 进度累计（PLDownloadClient 为 delta 语义，含镜像切换/重试的负 delta 回退，直接累加即可）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadAccumulatedBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadTotalBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadLastSpeeds;
// 请求描述缓存：retryHandler 复用同一请求（同 taskIdentifier 可复用断点语义）
@property (nonatomic, strong) NSMutableDictionary<NSString *, PLDownloadRequest *> *downloadRequests;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DataPackDownloadProgressHandler> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DataPackDownloadCompletionHandler> *downloadCompletionHandlers;
@end

@implementation DataPackService

+ (instancetype)sharedService {
    static DataPackService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[DataPackService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _onlineSearchEnabled = NO;

        // 下载已改走 [PLDownloadClient sharedClient]（镜像候选 + SHA1 校验 + 断点续传），
        // 不再自建 NSURLSession download delegate
        _downloadStateLock = [[NSLock alloc] init];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadOperations = [NSMutableDictionary dictionary];
        _downloadGenerations = [NSMutableDictionary dictionary];
        _downloadAccumulatedBytes = [NSMutableDictionary dictionary];
        _downloadTotalBytes = [NSMutableDictionary dictionary];
        _downloadLastSpeeds = [NSMutableDictionary dictionary];
        _downloadRequests = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
    }
    return self;
}

#pragma mark - 工具方法

// 计算 URL 字符串的 SHA1，用作图标缓存文件名
// ★ Task270（屎山 A1）：逐字节克隆收敛 utils.m 单点 AMEIconCachePathForURL（行为零变更）。
- (NSString *)iconCachePathForURL:(NSString *)urlString {
    return AMEIconCachePathForURL(urlString, @"datapack_icons");
}

// 从 zip 中读取指定条目的数据
- (nullable NSData *)readFileFromZip:(NSString *)zipPath entryName:(NSString *)entryName {
    if (!zipPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&err];
    if (!archive || err) return nil;
    NSData *data = [archive extractDataFromFile:entryName error:&err];
    return data;
}

// 解析 pack.mcmeta，提取 pack_format 和 description
- (void)parsePackMcmetaForItem:(DataPackItem *)item {
    if (!item.filePath) return;
    NSData *mcmetaData = [self readFileFromZip:item.filePath entryName:@"pack.mcmeta"];
    if (!mcmetaData) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:mcmetaData options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    NSDictionary *pack = json[@"pack"];
    if (![pack isKindOfClass:[NSDictionary class]]) return;

    id packFormatValue = pack[@"pack_format"];
    if ([packFormatValue isKindOfClass:[NSNumber class]]) {
        item.packFormat = packFormatValue;
    } else if ([packFormatValue respondsToSelector:@selector(integerValue)]) {
        item.packFormat = @([packFormatValue integerValue]);
    }

    id descValue = pack[@"description"];
    if ([descValue isKindOfClass:[NSString class]]) {
        item.dataPackDescription = descValue;
    } else if ([descValue respondsToSelector:@selector(description)]) {
        item.dataPackDescription = [descValue description];
    }
}

// 解析 profile 的 gameDir，返回 gameDir 或 nil
- (nullable NSString *)gameDirForProfile:(NSString *)profileName {
    // Task270 M1 服务层语义对齐：nil 入参跟随当前选中实例（ame267 语义），
    // 不再落恒 miss 的 @"default" 字面量（真实默认键 "(Default)"）。
    if (!profileName.length) profileName = PLProfiles.current.selectedProfileName ?: @"(Default)";
    NSString *profile = profileName;
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if ([prof isKindOfClass:[NSDictionary class]]) {
            NSString *gameDir = prof[@"gameDir"];
            // Task269-r3：相对路径（如 ./custom_gamedir/<id>）统一相对 POJAV_GAME_DIR
            // 解析成绝对路径——裸相对依赖进程 CWD，而 CWD 会被启动链 chdir 永久切走，
            // 玩过一局后存档/资源包/数据包全部错位（review-c H1；与 ModService 同口径）。
            if ([gameDir isKindOfClass:[NSString class]] && gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
                if ([gameDir isAbsolutePath]) return gameDir;
                NSString *clean = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
                const char *baseC = getenv("POJAV_GAME_DIR");
                return baseC ? [[NSString stringWithUTF8String:baseC] stringByAppendingPathComponent:clean] : gameDir;
            }
            // ★ Task274-h S11（Task225 嗅探平移·双保险）：gameDir 缺失/空/"." 时先按
            //   目录形状嗅探 versions/<lastVersionId>/game 隔离（与 ModService resolve
            //   逐行同口径）——'.' 实例（AiInstanceCreator 仍写 '.'、A3 sweep 仅启动期
            //   收敛）的数据包下载此前落共享根，与 mods 落点短暂分居。
            {
                NSString *ame225_sniffed = [ModService ame225_sniffedIsolationGameDirForProfile:prof];
                if (ame225_sniffed.length > 0) {
                    NSLog(@"[DataPackService] Task225 auto-sniffed isolation for profile %@ -> %@ (mods/saves present)",
                          profile, ame225_sniffed.lastPathComponent);
                    return ame225_sniffed;
                }
            }
            if ([gameDir isKindOfClass:[NSString class]] && [gameDir isEqualToString:@"."]) {
                const char *baseC = getenv("POJAV_GAME_DIR");
                if (baseC) return [NSString stringWithUTF8String:baseC];
            }
        }
    } @catch (NSException *ex) { }

    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        return [NSString stringWithUTF8String:gameDirC];
    }
    return nil;
}

#pragma mark - DataPacks folder detection & scan

// 查找指定 profile 的 datapacks 目录（已存在时返回路径，否则返回 nil）
- (nullable NSString *)existingDataPacksFolderForProfile:(NSString *)profileName {
    NSFileManager *fm = [NSFileManager defaultManager];

    @try {
        // Task270 P1：主分支改经 gameDirForProfile 绝对化解析（Task269-r3
        // 修复落点错位同族残留，对齐 ResourcePackService r3 模式）。
        NSString *gameDir = [self gameDirForProfile:profileName];
        if (gameDir.length > 0) {
            NSString *dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:dataPacksPath isDirectory:&isDir] && isDir) {
                return dataPacksPath;
            }
        }
    } @catch (NSException *ex) { }

    // 回退：读取 POJAV_GAME_DIR 环境变量
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:dataPacksPath isDirectory:&isDir] && isDir) {
            return dataPacksPath;
        }
    }
    return nil;
}

/// 获取当前 profile 的 datapacks 目录，不存在时自动创建
- (nullable NSString *)ensureDataPacksFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dataPacksPath = nil;

    @try {
        // Task270 P1：同 existing——主分支改经 gameDirForProfile 绝对化解析。
        NSString *gameDir = [self gameDirForProfile:profileName];
        if (gameDir.length > 0) {
            dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
        }
    } @catch (NSException *ex) { }

    if (!dataPacksPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            dataPacksPath = [gameDir stringByAppendingPathComponent:@"datapacks"];
        }
    }

    if (!dataPacksPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"DataPackService" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_105", nil)}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dataPacksPath isDirectory:&isDir]) {
        NSError *createError = nil;
        [fm createDirectoryAtPath:dataPacksPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[DataPackService] Created datapacks directory: %@", dataPacksPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"DataPackService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ is not a directory", dataPacksPath]}];
        }
        return nil;
    }
    return dataPacksPath;
}

- (void)scanDataPacksForProfile:(NSString *)profileName completion:(DataPackListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ★ Task275 F1（P0·ame219 隔离优先语义平移）：扫描不再走"隔离目录缺失→共享根
        //   兑底"——新隔离实例列表必须为空而非显示共享根/隔壁实例列表（跨实例串目录）。
        NSError *ame275DirError = nil;
        NSString *dataPacksFolder = [self ensureDataPacksFolderForProfile:profileName error:&ame275DirError];
        if (!dataPacksFolder) {
            dataPacksFolder = [self existingDataPacksFolderForProfile:profileName];
        }
        NSMutableArray<DataPackItem *> *items = [NSMutableArray array];

        if (!dataPacksFolder) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dataPacksFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".zip"] || [fileName.lowercaseString hasSuffix:@".zip.disabled"]) {
                NSString *fullPath = [dataPacksFolder stringByAppendingPathComponent:fileName];
                DataPackItem *dataPack = [[DataPackItem alloc] initWithFilePath:fullPath];
                [items addObject:dataPack];

                dispatch_group_enter(group);
                [self fetchMetadataForDataPack:dataPack completion:^(DataPackItem *populatedItem, NSError * _Nullable error) {
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [items sortUsingComparator:^NSComparisonResult(DataPackItem *obj1, DataPackItem *obj2) {
                NSString *name1 = obj1.displayName ?: obj1.fileName;
                NSString *name2 = obj2.displayName ?: obj2.fileName;
                return [name1 localizedCaseInsensitiveCompare:name2];
            }];

            if (completion) {
                completion(items);
            }
        });
    });
}

#pragma mark - Metadata fetch

// 解析 zip 内的 pack.mcmeta，获取 pack_format 和 description
- (void)fetchMetadataForDataPack:(DataPackItem *)item completion:(DataPackMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            [self parsePackMcmetaForItem:item];
        } @catch (NSException *exception) {
            NSLog(@"[DataPackService] Exception parsing pack.mcmeta for %@: %@", item.fileName, exception);
        }
        if (completion) completion(item, nil);
    });
}

#pragma mark - File operations

// 启用/禁用数据包：通过加/去 .disabled 后缀实现
- (BOOL)toggleEnableForDataPack:(DataPackItem *)item error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = item.filePath;
    NSString *newPath;

    if (item.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".zip.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - [@".disabled" length]];
        } else {
            if (error) *error = [NSError errorWithDomain:@"DataPackServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:@"File state mismatch, cannot enable."}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        item.filePath = newPath;
        item.fileName = [newPath lastPathComponent];
        [item refreshDisabledFlag];
    }

    return success;
}

// 删除数据包文件
- (BOOL)deleteDataPack:(DataPackItem *)item error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:item.filePath error:error];
}

#pragma mark - Online DataPack Downloading（PLDownloadClient 统一下载器）

// 下载数据包到默认 datapacks 目录（无 worldName）
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    [self downloadDataPack:item toProfile:profileName worldName:nil expectedSHA1:nil progress:progress completion:completion];
}

// 下载数据包，worldName 不为空时下载到 saves/<worldName>/datapacks/
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
               worldName:(nullable NSString *)worldName
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    [self downloadDataPack:item toProfile:profileName worldName:worldName expectedSHA1:nil progress:progress completion:completion];
}

// ---------- 带 SHA1 校验的下载（spec Task 5.1：expectedSHA1 传入即启用校验）----------
- (void)downloadDataPack:(DataPackItem *)item
               toProfile:(NSString *)profileName
               worldName:(nullable NSString *)worldName
            expectedSHA1:(nullable NSString *)expectedSHA1
                progress:(DataPackDownloadProgressHandler _Nullable)progress
              completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    // ★ Task275 F7（Task269 末梢自愈平移）：目标实例不存在→回落当前选中实例
    //   （ModService.m:734 同款，杜绝死名 resolve 兑底静默落共享根）。
    if (profileName.length > 0 && !PLProfiles.current.profiles[profileName]) {
        NSString *ame275_fallback = PLProfiles.current.selectedProfileName;
        NSLog(@"[DataPackService] Task275: target profile \"%@\" gone -> fallback to selected \"%@\"",
              profileName, ame275_fallback ?: @"(nil)");
        profileName = ame275_fallback;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *dataPacksFolder = nil;

    // 根据是否指定 worldName 决定下载目录
    if (worldName.length > 0) {
        // 下载到 saves/<worldName>/datapacks/
        NSString *gameDir = [self gameDirForProfile:profileName];
        if (!gameDir) {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                     code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: @"Cannot find game directory."}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
            }
            return;
        }
        NSString *savesDir = [gameDir stringByAppendingPathComponent:@"saves"];
        NSString *worldDir = [savesDir stringByAppendingPathComponent:worldName];
        dataPacksFolder = [worldDir stringByAppendingPathComponent:@"datapacks"];
        // 确保目标目录存在（含 saves/<worldName>/datapacks/）
        NSError *dirError = nil;
        BOOL created = [fm createDirectoryAtPath:dataPacksFolder
                     withIntermediateDirectories:YES
                                      attributes:nil
                                           error:&dirError];
        if (!created || dirError) {
            if (completion) {
                NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                     code:1
                                                 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create world datapacks directory: %@", dirError.localizedDescription ?: @"Unknown error"]}];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
            }
            return;
        }
    } else {
        // 默认下载到 <gameDir>/datapacks/
        // ★ Task275 F1：ensure-first（原 existing-first 在隔离叶目录未建时把
        //   下载落到共享根——同扫描病灶）。
        dataPacksFolder = [self ensureDataPacksFolderForProfile:profileName error:nil];
        if (!dataPacksFolder) {
            dataPacksFolder = [self existingDataPacksFolderForProfile:profileName];
        }
        if (!dataPacksFolder) {
            NSString *gameDir = [self gameDirForProfile:profileName];
            if (gameDir) {
                dataPacksFolder = [gameDir stringByAppendingPathComponent:@"datapacks"];
                NSError *dirError = nil;
                BOOL created = [fm createDirectoryAtPath:dataPacksFolder
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&dirError];
                if (!created || dirError) {
                    if (completion) {
                        NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                             code:1
                                                         userInfo:@{NSLocalizedDescriptionKey: @"Failed to create datapacks directory, please check storage permissions."}];
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                    }
                    return;
                }
            } else {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                         code:1
                                                     userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_106", nil)}];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                }
                return;
            }
        }
    }

    // 校验下载链接
    NSURL *url = [NSURL URLWithString:item.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"DataPackServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid download URL."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
        }
        return;
    }

    // 确保文件名有效
    NSString *fileName = item.fileName;
    if (!fileName || fileName.length == 0) {
        fileName = [url lastPathComponent];
    }
    if (!fileName || fileName.length == 0) {
        fileName = @"datapack.zip";
    }
    if (![fileName.lowercaseString hasSuffix:@".zip"]) {
        fileName = [fileName stringByAppendingString:@".zip"];
    }

    NSString *destinationPath = [dataPacksFolder stringByAppendingPathComponent:fileName];

    // 注册到统一下载任务管理器（rawTask 稍后赋值为 PLDownloadOperation；悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = item.fileName.length > 0 ? item.fileName : (item.displayName.length > 0 ? item.displayName : @"datapack");
    NSString *displayName = item.displayName.length > 0 ? item.displayName : resourceName;
    // Task218：来源标签收敛到 PLMirrorCenter（显示层专用 token；路由一律走候选链）。
    NSString *downloadSource = [PLMirrorCenter legacySourceTokenForType:PLMirrorResourceTypeAssetDownload];
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeDataPack
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:nil
                      supportsResume:YES
                             iconURL:item.iconURL];
    taskItem.downloadURL = item.selectedVersionDownloadURL;
    // ★ Task270 M2：下载目标实例随任务标注（对齐 ModService Task266 中央落点
    // ——跨实例对账/死名回落此前仅 mods 享有，四服务统一）。
    taskItem.targetProfileName = profileName;
    // redesign-download-ui Phase 3：单文件下载接入统一进度页——
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出 PLTaskProgressViewController
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId stages:PLTaskStagesSingleFile()];
    taskItem.autoPresentDetail = YES;

    // retryHandler：FCL 风格重新下载，复用同一 taskItem，重新发起 PLDownloadClient 请求
    __weak typeof(self) weakSelf = self;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        return [strongSelf restartPLDownloadForTaskId:taskItemRef.taskId];
    };

    PLDownloadRequest *request = [[PLDownloadRequest alloc] init];
    // 镜像候选列表：原始 CDN URL + MCIM 镜像，按 download.assetDownloadSource 策略排序
    // （PLMirrorCenter 统一收敛镜像映射与策略读取）
    request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                          resourceType:PLMirrorResourceTypeAssetDownload];
    // Task 5.1：expectedSHA1（版本模型 files[].hashes.sha1）传入即启用 SHA1 校验，
    // 校验失败由 PLDownloadClient 内部按镜像/退避节奏重试
    request.expectedSHA1 = expectedSHA1;
    // Task 5.2：目标文件已存在且校验通过 → 零流量直接成功（增量下载）；
    // 目标路径语义与原实现一致（datapacks/<fileName>.zip 或 saves/<worldName>/datapacks/<fileName>.zip），
    // 落盘由 PLDownloadClient 原子替换完成
    request.destinationPath = destinationPath;
    // taskIdentifier 用 DownloadTaskManager 的 taskId，resumeData 断点数据跨次下载可复用
    request.taskIdentifier = taskItem.taskId;
    // 无 SHA1 时对 .zip 做 EOCD 兜底完整性校验
    request.allowZipFallbackCheck = YES;

    [self startPLDownloadWithRequest:request taskItem:taskItem progress:progress completion:completion];

    NSLog(@"[DataPackService] Starting download task (with progress) for datapack: %@ -> %@", url, destinationPath);
}

#pragma mark - PLDownloadClient 封装（进度 delta 累计 / 速率采样 / 完成分发）

/// 发起（或重发）PLDownloadClient 请求并挂接进度、速率、完成回调。
/// progress/completion 传 nil 时不覆盖已登记的回调（retryHandler 重发时复用首次回调）。
- (nullable PLDownloadOperation *)startPLDownloadWithRequest:(PLDownloadRequest *)request
                                                     taskItem:(DownloadTaskItem *)taskItem
                                                     progress:(DataPackDownloadProgressHandler _Nullable)progress
                                                   completion:(DataPackDownloadCompletionHandler _Nullable)completion {
    NSString *taskId = taskItem.taskId;
    __weak typeof(self) weakSelf = self;

    [self.downloadStateLock lock];
    NSInteger generation = [self.downloadGenerations[taskId] integerValue] + 1;
    self.downloadGenerations[taskId] = @(generation);
    self.downloadTaskItems[taskId] = taskItem;
    self.downloadRequests[taskId] = request;
    if (progress) self.downloadProgressHandlers[taskId] = progress;
    if (completion) self.downloadCompletionHandlers[taskId] = completion;
    // 重发从头下载：归零累计（PLDownloadClient 的负 delta 回退语义在单次 operation 内自洽）
    self.downloadAccumulatedBytes[taskId] = @(0);
    self.downloadTotalBytes[taskId] = @(-1);
    self.downloadLastSpeeds[taskId] = @(0.0);
    [self.downloadStateLock unlock];

    PLDownloadOperation *operation = [[PLDownloadClient sharedClient] startRequest:request
                                                                          progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadDelta:deltaBytes total:totalExpectedBytes taskId:taskId generation:generation];
    }
                                                                             speed:^(int64_t bytesPerSecond) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadSpeed:bytesPerSecond taskId:taskId generation:generation];
    }
                                                                        completion:^(BOOL success, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadCompletion:success error:error taskId:taskId generation:generation];
    }];
    if (!operation) {
        // 参数错误：PLDownloadClient 会异步回调 completion（error），由统一失败路径收尾
        return nil;
    }

    [self.downloadStateLock lock];
    self.downloadOperations[taskId] = operation;
    [self.downloadStateLock unlock];

    // rawTask 为 weak 引用：operation 由 PLDownloadClient 与本 Service 共同持有，
    // DownloadTaskManager 据此对 PLDownloadOperation 做 pause/resume/cancel
    taskItem.rawTask = operation;
    // 占用并发槽位（满则由 DownloadTaskManager 自动 pauseOperation 排队）
    [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
    // redesign-download-ui Phase 3：单阶段任务进入下载时将阶段0 置为 Running
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  status:PLTaskStageStatusRunning];
    return operation;
}

/// retryHandler 入口：复用登记的请求描述重新发起下载
- (nullable id)restartPLDownloadForTaskId:(NSString *)taskId {
    [self.downloadStateLock lock];
    PLDownloadRequest *request = self.downloadRequests[taskId];
    DownloadTaskItem *taskItem = self.downloadTaskItems[taskId];
    [self.downloadStateLock unlock];
    if (!request || !taskItem) return nil;
    return [self startPLDownloadWithRequest:request taskItem:taskItem progress:nil completion:nil];
}

/// 进度 delta 累计：负 delta（镜像切换/重试/断点失效回退）直接累加即可贴合真实进度
- (void)handlePLDownloadDelta:(int64_t)delta total:(int64_t)total taskId:(NSString *)taskId generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    int64_t accumulated = [self.downloadAccumulatedBytes[taskId] longLongValue] + delta;
    if (accumulated < 0) accumulated = 0;
    if (total > 0) self.downloadTotalBytes[taskId] = @(total);
    int64_t totalStored = [self.downloadTotalBytes[taskId] longLongValue];
    self.downloadAccumulatedBytes[taskId] = @(accumulated);
    double lastSpeed = [self.downloadLastSpeeds[taskId] doubleValue];
    DataPackDownloadProgressHandler progressHandler = self.downloadProgressHandlers[taskId];
    [self.downloadStateLock unlock];

    double fraction = totalStored > 0 ? (double)accumulated / (double)totalStored : -1.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 progress:fraction
                                               totalBytes:totalStored
                                          downloadedBytes:accumulated];
    // redesign-download-ui Phase 3：单阶段任务的阶段进度与任务总进度保持一致
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  progress:fraction
                                                 message:nil];

    if (!progressHandler) return;

    // 构造带 throughput/ETA 的 NSProgress，供调用方在下载进度 UI 上显示速度和 ETA
    NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:totalStored > 0 ? totalStored : -1];
    downloadProgress.completedUnitCount = accumulated;
    if (lastSpeed > 0) {
        downloadProgress.throughput = @(lastSpeed);
        if (totalStored > accumulated) {
            downloadProgress.estimatedTimeRemaining = @((double)(totalStored - accumulated) / lastSpeed);
        }
    }
    // progress 回调在主线程执行（UI 更新安全）
    dispatch_async(dispatch_get_main_queue(), ^{
        progressHandler(downloadProgress);
    });
}

/// 速率采样（PLDownloadClient 每秒回调一次；结束/暂停时回调 0）
- (void)handlePLDownloadSpeed:(int64_t)bytesPerSecond taskId:(NSString *)taskId generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    self.downloadLastSpeeds[taskId] = @(bytesPerSecond);
    int64_t total = [self.downloadTotalBytes[taskId] longLongValue];
    int64_t accumulated = [self.downloadAccumulatedBytes[taskId] longLongValue];
    [self.downloadStateLock unlock];

    double eta = (bytesPerSecond > 0 && total > accumulated)
        ? (double)(total - accumulated) / (double)bytesPerSecond : 0.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                    speed:(double)bytesPerSecond
                                  estimatedTimeRemaining:eta];
}

/// 完成分发：更新 DownloadTaskManager 状态并回调业务方（主线程）
/// 文件落盘由 PLDownloadClient 校验通过后原子替换到 destinationPath，无需再手动移动
- (void)handlePLDownloadCompletion:(BOOL)success
                             error:(nullable NSError *)error
                            taskId:(NSString *)taskId
                         generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    DataPackDownloadCompletionHandler completion = self.downloadCompletionHandlers[taskId];
    // ★ Task270（scan-d #1 修法平移，同 ModService.m:914-927）：失败/取消保留
    //   request+taskItem——retryHandler→restartPLDownloadForTaskId 靠
    //   downloadRequests 命中，旧版一律清空 = "重试"恒 nil → 任务永久卡
    //   "等待中"。成功路径才全量清理。
    if (success) {
        [self cleanupPLDownloadStateForTaskId:taskId];
    } else {
        [self.downloadOperations removeObjectForKey:taskId];
        [self.downloadGenerations removeObjectForKey:taskId];
        [self.downloadAccumulatedBytes removeObjectForKey:taskId];
        [self.downloadTotalBytes removeObjectForKey:taskId];
        [self.downloadLastSpeeds removeObjectForKey:taskId];
        [self.downloadProgressHandlers removeObjectForKey:taskId];
        [self.downloadCompletionHandlers removeObjectForKey:taskId];
    }
    [self.downloadStateLock unlock];

    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    if (success) {
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
        [manager setTaskWithId:taskId state:DownloadTaskStateCompleted];
    } else if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        // 用户取消（DownloadTaskManager 已置 Cancelled，这里幂等对齐）
        // ★ Task270（scan-d #8 平移）：阶段行同步置 Skipped——旧版停在 Running，
        //   统一进度页显示"进行中"直到页面关闭。
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusSkipped];
        [manager setTaskWithId:taskId state:DownloadTaskStateCancelled];
    } else {
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
        [manager updateTaskWithId:taskId error:error];
        [manager setTaskWithId:taskId state:DownloadTaskStateFailed];
    }

    if (completion) {
        BOOL successFlag = success ? YES : NO;
        NSError *capturedError = success ? nil : error;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(successFlag, capturedError);
        });
    }
}

/// 清理指定任务的全部跟踪状态（须在 downloadStateLock 内调用）
- (void)cleanupPLDownloadStateForTaskId:(NSString *)taskId {
    [self.downloadTaskItems removeObjectForKey:taskId];
    [self.downloadOperations removeObjectForKey:taskId];
    [self.downloadGenerations removeObjectForKey:taskId];
    [self.downloadAccumulatedBytes removeObjectForKey:taskId];
    [self.downloadTotalBytes removeObjectForKey:taskId];
    [self.downloadLastSpeeds removeObjectForKey:taskId];
    [self.downloadRequests removeObjectForKey:taskId];
    [self.downloadProgressHandlers removeObjectForKey:taskId];
    [self.downloadCompletionHandlers removeObjectForKey:taskId];
}

@end
