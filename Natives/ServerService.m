#import "utils.h"
//
//  ServerService.m
//  Amethyst
//

#import "ServerService.h"
#import <CommonCrypto/CommonCrypto.h>
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "PLPreferences.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "MinecraftResourceDownloadTask.h"

@interface ServerService () <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *downloadSession;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, ServerDownloadHandler> *downloadCompletionHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadDestinationPaths;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, ServerProgressHandler> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSURLSessionTask *, NSString *> *downloadTaskIDs;
// ★ Task274-h S4：四字典此前零锁跨线程读写（主线程登记 vs delegate 串行队列读写）
//   = NSMutableDictionary 并发消息崩溃面；对齐 WorldService Task270 downloadStateLock
//   同款锁纪律（六区段：登记/重试重建/didFinish 读+清/didWriteData 读/didComplete 读+清）。
@property (nonatomic, strong) NSLock *downloadStateLock;
@end

@implementation ServerService

+ (instancetype)sharedService {
    static ServerService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ServerService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 120.0;
        config.timeoutIntervalForResource = 600.0;
        config.allowsCellularAccess = YES;
        config.HTTPMaximumConnectionsPerHost = 4;
        _downloadSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];
        _downloadDestinationPaths = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadTaskIDs = [NSMutableDictionary dictionary];
        _downloadStateLock = [NSLock new];
    }
    return self;
}

+ (ServerDownloadAPI)currentAPI {
    NSString *source = [PLPreferences currentDownloadSourceForType:@"server"];
    return [source isEqualToString:@"curseforge"] ? ServerDownloadAPICurseForge : ServerDownloadAPIModrinth;
}

// ★ Task270（屎山 A1）：逐字节克隆收敛 utils.m 单点 AMEIconCachePathForURL（行为零变更）。
- (NSString *)iconCachePathForURL:(NSString *)urlString {
    return AMEIconCachePathForURL(urlString, @"server_icons");
}

#pragma mark - 搜索服务器

- (void)searchServersWithAPI:(ServerDownloadAPI)api
                     filters:(NSDictionary *)filters
                  completion:(ServerListHandler)completion {
    NSDictionary *f = filters ?: @{};
    void (^transform)(NSArray * _Nullable, NSError * _Nullable) = ^(NSArray * _Nullable results, NSError * _Nullable error) {
        if (error) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(@[], error); });
            return;
        }
        NSMutableArray<ServerItem *> *items = [NSMutableArray array];
        for (NSDictionary *dict in results) {
            if (![dict isKindOfClass:[NSDictionary class]]) continue;
            ServerItem *item = [[ServerItem alloc] initWithSearchData:dict];
            item.apiSource = api;
            if (item.associatedModpackID.length == 0 && [item.projectType isEqualToString:@"modpack"]) {
                // CurseForge/Modrinth modpack 回退场景：服务器自身即整合包
                item.associatedModpackID = item.serverID;
                item.associatedModpackSource = api;
            }
            [items addObject:item];
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(items, nil); });
    };

    if (api == ServerDownloadAPICurseForge) {
        [[CurseForgeAPI sharedInstance] searchServersWithFilters:f completion:transform];
    } else {
        [[ModrinthAPI sharedInstance] searchServersWithFilters:f completion:transform];
    }
}

#pragma mark - 获取服务器详情

- (void)getServerDetailsWithAPI:(ServerDownloadAPI)api
                       serverID:(NSString *)serverID
                      completion:(ServerDetailHandler)completion {
    if (serverID.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"ServerService" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_978", nil)}]);
        });
        return;
    }

    if (api == ServerDownloadAPIModrinth) {
        [[ModrinthAPI sharedInstance] getServerDetailsForID:serverID completion:^(NSDictionary * _Nullable details, NSError * _Nullable error) {
            if (error || !details) {
                if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                    completion(nil, error ?: [NSError errorWithDomain:@"ServerService" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_979", nil)}]);
                });
                return;
            }
            ServerItem *item = [[ServerItem alloc] initWithSearchData:details];
            item.apiSource = ServerDownloadAPIModrinth;
            [item applyDetailData:details];
            // modpack 回退场景：服务器自身即整合包
            if (item.associatedModpackID.length == 0 && [item.projectType isEqualToString:@"modpack"]) {
                item.associatedModpackID = item.serverID;
                item.associatedModpackSource = ServerDownloadAPIModrinth;
            }
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(item, nil); });
        }];
        return;
    }

    // CurseForge：复用 modpack 详情接口，并额外尝试拉取 server pack 文件
    NSMutableDictionary *itemDict = [@{@"id": serverID, @"projectType": @"modpack"} mutableCopy];
    [[CurseForgeAPI sharedInstance] loadDetailsOfMod:itemDict completion:^(NSError * _Nullable error) {
        if (error) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, error); });
            return;
        }
        ServerItem *item = [[ServerItem alloc] initWithSearchData:@{
            @"apiSource": @(2),
            @"serverID": serverID,
            @"projectType": @"modpack",
            @"title": itemDict[@"title"] ?: @"Unknown",
            @"description": itemDict[@"description"] ?: @""
        }];
        item.apiSource = ServerDownloadAPICurseForge;
        item.associatedModpackID = serverID;
        item.associatedModpackSource = ServerDownloadAPICurseForge;

        // 进一步拉取 server pack 文件列表，填充 downloadURL
        [[CurseForgeAPI sharedInstance] getServerPackFilesForModpack:serverID completion:^(NSArray * _Nullable files, NSError * _Nullable spError) {
            if (!spError && files.count > 0) {
                NSDictionary *sp = files.firstObject;
                [item applyDetailData:sp];
            }
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(item, nil); });
        }];
    }];
}

#pragma mark - 加入服务器（写入 profile 配置）

- (BOOL)joinServer:(NSString *)address
        forProfile:(NSString *)profileName
             error:(NSError **)error {
    if (address.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"ServerService" code:3 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_980", nil)}];
        return NO;
    }

    NSString *profile = profileName.length ? profileName : [PLProfiles.current selectedProfileName];
    if (profile.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"ServerService" code:4 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_981", nil)}];
        return NO;
    }

    // 直接写入 profile 字典（serverIp 字段可能由另一个任务添加到 PLProfiles.h，
    // 此处使用通用字典写入，兼容已有结构）
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *prof = [profiles[profile] mutableCopy];
    if (!prof) {
        prof = [NSMutableDictionary dictionary];
    }
    prof[@"serverIp"] = [address copy];
    profiles[profile] = prof;
    [PLProfiles.current save];
    NSLog(@"[ServerService] Saved server address %@ to profile %@", address, profile);
    return YES;
}

#pragma mark - 下载服务端整合包

- (void)downloadServerPack:(ServerItem *)serverItem
                 toProfile:(NSString *)profileName
                  progress:(ServerProgressHandler)progress
                completion:(ServerDownloadHandler)completion {
    if (!serverItem.serverPackDownloadURL || serverItem.serverPackDownloadURL.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"ServerService" code:5 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_982", nil)}]);
        });
        return;
    }

    // 目标目录：缓存目录下的 server_packs（服务端整合包不放入 client mods 目录）
    NSString *cacheDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString *destDir = [cacheDir stringByAppendingPathComponent:@"server_packs"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:destDir]) {
        [fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:nil];
    }

    NSString *fileName = serverItem.serverPackFileName.length ? serverItem.serverPackFileName : [serverItem.serverPackDownloadURL.lastPathComponent componentsSeparatedByString:@"?"].firstObject;
    if (fileName.length == 0) {
        fileName = [NSString stringWithFormat:@"%@_serverpack.zip", serverItem.serverID ?: @"unknown"];
    }
    NSString *destPath = [destDir stringByAppendingPathComponent:fileName];
    if ([fm fileExistsAtPath:destPath]) {
        [fm removeItemAtPath:destPath error:nil];
    }

    NSURL *url = [NSURL URLWithString:serverItem.serverPackDownloadURL];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"ServerService" code:6 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_254", nil)}]);
        });
        return;
    }

    NSURLSessionDownloadTask *task = [self.downloadSession downloadTaskWithURL:url];
    // ★ Task274-h S4：登记区跨线程加锁
    [self.downloadStateLock lock];
    self.downloadCompletionHandlers[task] = completion;
    self.downloadDestinationPaths[task] = destPath;
    if (progress) {
        self.downloadProgressHandlers[task] = progress;
    }
    [self.downloadStateLock unlock];

    // 注册到 DownloadTaskManager（统一进度跟踪）
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeModpack
                       resourceName:fileName
                        displayName:serverItem.title ?: fileName
                     downloadSource:serverItem.apiSource == ServerDownloadAPICurseForge ? @"curseforge" : @"modrinth"
                            rawTask:task
                     supportsResume:YES
                            iconURL:serverItem.iconURL];
    taskItem.downloadURL = serverItem.serverPackDownloadURL;
    [self.downloadStateLock lock];
    self.downloadTaskIDs[task] = taskItem.taskId;
    [self.downloadStateLock unlock];
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId state:DownloadTaskStateDownloading];

    // 设置 retryHandler：FCL 风格重新下载
    __weak typeof(self) weakSelf = self;
    NSString *capturedDestPath = destPath;
    ServerDownloadHandler capturedCompletion = completion;
    void (^capturedProgress)(NSProgress *) = progress;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        NSURL *retryURL = [NSURL URLWithString:taskItemRef.downloadURL] ?: url;
        if (!retryURL) return nil;
        NSURLSessionDownloadTask *newTask = [strongSelf.downloadSession downloadTaskWithURL:retryURL];
        // ★ Task274-h S4：重试重建区跨线程加锁（锁内不调 DownloadTaskManager）
        [strongSelf.downloadStateLock lock];
        strongSelf.downloadCompletionHandlers[newTask] = capturedCompletion;
        strongSelf.downloadDestinationPaths[newTask] = capturedDestPath;
        if (capturedProgress) {
            strongSelf.downloadProgressHandlers[newTask] = capturedProgress;
        }
        strongSelf.downloadTaskIDs[newTask] = taskItemRef.taskId;
        [strongSelf.downloadStateLock unlock];
        [[DownloadTaskManager sharedManager] setTaskWithId:taskItemRef.taskId state:DownloadTaskStateDownloading];
        [newTask resume];
        return newTask;
    };

    [task resume];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    // ★ Task274-h S4：读区跨线程加锁
    [self.downloadStateLock lock];
    ServerDownloadHandler handler = self.downloadCompletionHandlers[downloadTask];
    NSString *destinationPath = self.downloadDestinationPaths[downloadTask];
    NSString *taskID = self.downloadTaskIDs[downloadTask];
    [self.downloadStateLock unlock];

    // 关键修复（旧任务覆盖新任务）：暂停→继续→重试重建任务后，被取消的旧 downloadTask
    // 的完成回调不得操作新任务。rawTask 指向当前活动任务，不一致即旧任务残留：丢弃。
    if (taskID) {
        DownloadTaskItem *item = [[DownloadTaskManager sharedManager] taskWithId:taskID];
        if (item && item.rawTask != downloadTask) {
            return;
        }
    }

    // ★ Task274-h S4：清区跨线程加锁
    [self.downloadStateLock lock];
    [self.downloadCompletionHandlers removeObjectForKey:downloadTask];
    [self.downloadDestinationPaths removeObjectForKey:downloadTask];
    [self.downloadProgressHandlers removeObjectForKey:downloadTask];
    [self.downloadTaskIDs removeObjectForKey:downloadTask];
    [self.downloadStateLock unlock];

    if (!handler || !destinationPath) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *moveError = nil;
    NSString *dir = [destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:destinationPath]) {
        [fm removeItemAtPath:destinationPath error:nil];
    }

    if (taskID) {
        if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError]) {
            [[DownloadTaskManager sharedManager] setTaskWithId:taskID completedWithError:moveError];
            dispatch_async(dispatch_get_main_queue(), ^{ handler(moveError); });
        } else {
            [[DownloadTaskManager sharedManager] setTaskWithId:taskID completedWithError:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ handler(nil); });
        }
    } else {
        if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destinationPath] error:&moveError]) {
            dispatch_async(dispatch_get_main_queue(), ^{ handler(moveError); });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ handler(nil); });
        }
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    // ★ Task274-h S4：读区跨线程加锁
    [self.downloadStateLock lock];
    void(^progress)(NSProgress *) = self.downloadProgressHandlers[downloadTask];
    NSString *taskID = self.downloadTaskIDs[downloadTask];
    [self.downloadStateLock unlock];

    // 关键修复（旧任务覆盖新任务）：旧 downloadTask 的进度回调不得推进新任务进度
    if (taskID) {
        DownloadTaskItem *item = [[DownloadTaskManager sharedManager] taskWithId:taskID];
        if (item && item.rawTask != downloadTask) {
            return;
        }
    }

    if (taskID && totalBytesExpectedToWrite > 0) {
        double p = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
        [[DownloadTaskManager sharedManager] updateTaskWithId:taskID
                                                     progress:p
                                                   totalBytes:totalBytesExpectedToWrite
                                              downloadedBytes:totalBytesWritten];
    }

    if (!progress) return;
    NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:totalBytesExpectedToWrite];
    downloadProgress.completedUnitCount = totalBytesWritten;
    dispatch_async(dispatch_get_main_queue(), ^{
        progress(downloadProgress);
    });
}

- (void)URLSession:(NSURLSession *)session
          task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        // ★ Task274-h S4：读区跨线程加锁
        [self.downloadStateLock lock];
        ServerDownloadHandler handler = self.downloadCompletionHandlers[task];
        NSString *taskID = self.downloadTaskIDs[task];
        [self.downloadStateLock unlock];

        // 关键修复（旧任务覆盖新任务）：暂停→继续→重试重建任务后，被取消/替换的旧任务
        // 的取消回调不得把新任务打成 Failed。rawTask 指向当前活动任务，不一致即旧任务残留。
        if (taskID) {
            DownloadTaskItem *item = [[DownloadTaskManager sharedManager] taskWithId:taskID];
            if (item && item.rawTask != task) {
                return;
            }
        }

        if (taskID) {
            [[DownloadTaskManager sharedManager] setTaskWithId:taskID completedWithError:error];
        }
        if (handler) {
            dispatch_async(dispatch_get_main_queue(), ^{ handler(error); });
            // ★ Task274-h S4：清区跨线程加锁
            [self.downloadStateLock lock];
            [self.downloadCompletionHandlers removeObjectForKey:task];
            [self.downloadDestinationPaths removeObjectForKey:task];
            [self.downloadProgressHandlers removeObjectForKey:task];
            [self.downloadTaskIDs removeObjectForKey:task];
            [self.downloadStateLock unlock];
        }
    }
}

@end
