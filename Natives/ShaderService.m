#import "utils.h"
//
//  ShaderService.m
//  Amethyst
//
//  Shader service implementation - Fixed version
//  修复：文件下载改走 PLDownloadClient 统一下载器（镜像候选 + SHA1 校验 + 断点续传），
//        移除自建 NSURLSession 下载 delegate（spec optimize-download-system Task 4.2 / 5.1 / 5.2）
//

#import "ShaderService.h"
#import "ModService.h"   // Task275 F2: Task225 isolation sniff (ame225_sniffedIsolationGameDirForProfile)
// ★ Task274-h S14：CommonCrypto import 随零调用 sha1ForFileAtPath 删除（全文件 CC_ 族
//   仅该方法使用，rg 亲证）
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ShaderItem.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "LauncherPreferences.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"

@interface ShaderService ()
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
@property (nonatomic, strong) NSMutableDictionary<NSString *, void(^)(NSProgress *)> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ShaderDownloadHandler> *downloadCompletionHandlers;
@end

@implementation ShaderService

+ (instancetype)sharedService {
    static ShaderService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ShaderService alloc] init];
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

#pragma mark - Helpers

// ★ Task274-h S14：sha1ForFileAtPath 零调用副本已删除（rg 亲证全文件仅此 1 处定义
//   零调用；活副本在 ModpackExportService:939 有分块实现）。

// ★ Task270（屎山 A1）：逐字节克隆收敛 utils.m 单点 AMEIconCachePathForURL（行为零变更）。
- (NSString *)iconCachePathForURL:(NSString *)urlString {
    return AMEIconCachePathForURL(urlString, @"shader_icons");
}

#pragma mark - Shaders folder detection & scan

/// 解析 profile 的 gameDir 为绝对路径。
/// 与 ModService.resolveAbsoluteGameDirForProfile: 对齐：
/// profile gameDir 通常是相对路径（如 "./custom_gamedir/{name}"），需相对于 POJAV_GAME_DIR 解析。
/// 之前 ShaderService 直接使用相对路径，导致 shaderpacks 目录找不到（fileExistsAtPath 基于 cwd 解析），
/// 用户点击下载光影按钮后没反应（实际是 ensureShadersFolderForProfile 创建目录到错误位置，
/// 下载完成后 moveItem 失败但 handler 已切主线程报错，用户感知"无反应"）。
- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName {
    // Task270 M1/M8：nil 入参跟随当前选中实例（ame267 语义），不再落恒 miss 的
    // @"default" 字面量（真实默认键 "(Default)"）——抽屉入口/导入传 nil 时
    // 光影不再错位到共享目录。
    if (!profileName.length) profileName = PLProfiles.current.selectedProfileName ?: @"(Default)";
    NSString *profile = profileName;
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if (![prof isKindOfClass:[NSDictionary class]]) return nil;
        NSString *gameDir = prof[@"gameDir"];
        // ★ Task275 F2（Task274-h S11 补漏）：gameDir 缺失/空/"." 时先按目录形状嗅探
        //   versions/<lastVersionId>/game 隔离——'.' 实例的 mods 已走嗅探隔离而光影
        //   仍落共享根（Shader 是五服务唯一漏平移嗅探的一家，同会话落点分居）。
        if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0 || [gameDir isEqualToString:@"."]) {
            NSString *ame225_sniffed = [ModService ame225_sniffedIsolationGameDirForProfile:prof];
            if (ame225_sniffed.length > 0) {
                NSLog(@"[ShaderService] Task275: auto-sniffed isolation for profile %@ -> %@ (mods/saves present)",
                      profile, ame225_sniffed.lastPathComponent);
                return ame225_sniffed;
            }
        }
        if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0) return nil;
        if ([gameDir isEqualToString:@"."]) {
            const char *env = getenv("POJAV_GAME_DIR");
            return env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        }
        if ([gameDir isAbsolutePath]) {
            return gameDir;
        }
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *baseDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        NSString *cleanGameDir = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
        return [baseDir stringByAppendingPathComponent:cleanGameDir];
    } @catch (NSException *ex) {
        return nil;
    }
}

- (nullable NSString *)existingShadersFolderForProfile:(NSString *)profileName {
    NSFileManager *fm = [NSFileManager defaultManager];

    // 优先用 profile gameDir（已解析为绝对路径；nil 跟随语义在 resolve 内）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profileName];
    if (resolvedGameDir.length > 0) {
        NSString *shadersPath = [resolvedGameDir stringByAppendingPathComponent:@"shaderpacks"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:shadersPath isDirectory:&isDir] && isDir) {
            return shadersPath;
        }
    }

    // 回退到 POJAV_GAME_DIR/shaderpacks
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *shadersPath = [gameDir stringByAppendingPathComponent:@"shaderpacks"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:shadersPath isDirectory:&isDir] && isDir) {
            return shadersPath;
        }
    }
    return nil;
}

/// 获取当前 profile 的 shaderpacks 目录，不存在时自动创建
- (nullable NSString *)ensureShadersFolderForProfile:(NSString *)profileName error:(NSError **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *shadersPath = nil;

    // 优先用 profile gameDir（已解析为绝对路径；nil 跟随语义在 resolve 内）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profileName];
    if (resolvedGameDir.length > 0) {
        shadersPath = [resolvedGameDir stringByAppendingPathComponent:@"shaderpacks"];
    }

    if (!shadersPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            shadersPath = [gameDir stringByAppendingPathComponent:@"shaderpacks"];
        }
    }

    if (!shadersPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"ShaderService" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_105", nil)}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:shadersPath isDirectory:&isDir]) {
        NSError *createError = nil;
        [fm createDirectoryAtPath:shadersPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[ShaderService] Created shaderpacks directory: %@", shadersPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"ShaderService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_451", nil), shadersPath]}];
        }
        return nil;
    }
    return shadersPath;
}

- (void)scanShadersForProfile:(NSString *)profileName completion:(ShaderListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ★ Task275 F1（P0·ame219 隔离优先语义平移）：扫描不再走"隔离目录缺失→共享根
        //   兑底"——新隔离实例的 shaderpacks 尚未创建时列表必须为空（本实例确实没有），
        //   而不是显示共享根/隔壁实例列表（跨实例串目录病史同构，mods 已修四类漏网）。
        //   ensure-first：缺目录即建；创建受限再退"存在即用"。
        NSError *ame275DirError = nil;
        NSString *shadersFolder = [self ensureShadersFolderForProfile:profileName error:&ame275DirError];
        if (!shadersFolder) {
            shadersFolder = [self existingShadersFolderForProfile:profileName];
        }
        NSMutableArray<ShaderItem *> *items = [NSMutableArray array];

        if (!shadersFolder) {
            if (completion) {
                // ★ Task270 P2：早退分支补派主线程（正常路径 246 经 dispatch_group_notify
                //   主线程，此处原在 global 队列直呼 = 回调越线程，管理页刷新越线程风险）。
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(items);
                });
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:shadersFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".zip"] || [fileName.lowercaseString hasSuffix:@".zip.disabled"]) {
                NSString *fullPath = [shadersFolder stringByAppendingPathComponent:fileName];
                ShaderItem *shader = [[ShaderItem alloc] initWithFilePath:fullPath];
                [items addObject:shader];

                dispatch_group_enter(group);
                [self fetchMetadataForShader:shader completion:^(ShaderItem *populatedShader, NSError * _Nullable error) {
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            [items sortUsingComparator:^NSComparisonResult(ShaderItem *obj1, ShaderItem *obj2) {
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

- (void)fetchMetadataForShader:(ShaderItem *)shader completion:(ShaderMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // For shaders, we don't have embedded metadata like mods do
        // Just return the shader as-is
        if (completion) completion(shader, nil);
    });
}

#pragma mark - File operations

- (BOOL)toggleEnableForShader:(ShaderItem *)shader error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = shader.filePath;
    NSString *newPath;

    if (shader.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".zip.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - [@".disabled" length]];
        } else {
            if (error) *error = [NSError errorWithDomain:@"ShaderServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:@"File state inconsistent, cannot enable."}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        shader.filePath = newPath;
        shader.fileName = [newPath lastPathComponent];
        [shader refreshDisabledFlag];
    }

    return success;
}

- (BOOL)deleteShader:(ShaderItem *)shader error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:shader.filePath error:error];
}

#pragma mark - Online Shader Downloading（PLDownloadClient 统一下载器）

- (void)downloadShader:(ShaderItem *)shader toProfile:(NSString *)profileName completion:(ShaderDownloadHandler)completion {
    [self downloadShader:shader toProfile:profileName expectedSHA1:nil progress:nil completion:completion];
}

#pragma mark - Online Shader Downloading with progress

- (void)downloadShader:(ShaderItem *)shader
             toProfile:(NSString *)profileName
              progress:(void (^)(NSProgress *downloadProgress))progress
            completion:(ShaderDownloadHandler)completion {
    [self downloadShader:shader toProfile:profileName expectedSHA1:nil progress:progress completion:completion];
}

// ---------- 带 SHA1 校验的下载（spec Task 5.1：expectedSHA1 传入即启用校验）----------
- (void)downloadShader:(ShaderItem *)shader
             toProfile:(NSString *)profileName
          expectedSHA1:(nullable NSString *)expectedSHA1
              progress:(nullable void (^)(NSProgress *downloadProgress))progress
            completion:(ShaderDownloadHandler)completion {
    // ★ Task275 F7（Task269 末梢自愈平移）：目标实例不存在（ame269 迁移合并/
    //   改名后残留的旧实例名引用）→ 回落当前选中实例，杜绝下载进死名后被
    //   resolve 兑底静默落共享根（ModService.m:734 同款）。
    if (profileName.length > 0 && !PLProfiles.current.profiles[profileName]) {
        NSString *ame275_fallback = PLProfiles.current.selectedProfileName;
        NSLog(@"[ShaderService] Task275: target profile \"%@\" gone -> fallback to selected \"%@\"",
              profileName, ame275_fallback ?: @"(nil)");
        profileName = ame275_fallback;
    }
    // Ensure shaderpacks folder exists
    // ★ Task270（ame219 隔离优先对齐）：下载落点 ensure-first——profile 配置了
    //   gameDir（隔离/自定义）时只认隔离目录缺目录即建，绝不回退共享目录
    //   （旧 existing-first：隔离实例首下载落全局 shaderpacks 游戏内不可见，
    //   与 ModService.m:311 同款语义；ensure 失败再退 existing 保旧下限）。
    NSError *ame270DirError = nil;
    NSString *shadersFolder = [self ensureShadersFolderForProfile:profileName error:&ame270DirError];
    if (!shadersFolder) {
        shadersFolder = [self existingShadersFolderForProfile:profileName];   // 兜底：创建受限时退"存在即用"
    }
    if (!shadersFolder) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ShaderServiceError"
                                                 code:1
            userInfo:@{NSLocalizedDescriptionKey: ame270DirError.localizedDescription ?: @"Failed to create shaderpacks folder, please check storage permissions."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    // Validate URL
    NSURL *url = [NSURL URLWithString:shader.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ShaderServiceError"
                                                 code:2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Invalid download link."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    // Ensure filename is valid
    NSString *fileName = shader.fileName;
    if (!fileName || fileName.length == 0) {
        fileName = [url lastPathComponent];
    }
    if (!fileName || fileName.length == 0) {
        fileName = @"shaderpack.zip";
    }
    if (![fileName.lowercaseString hasSuffix:@".zip"]) {
        fileName = [fileName stringByAppendingString:@".zip"];
    }

    NSString *destinationPath = [shadersFolder stringByAppendingPathComponent:fileName];

    // 注册到统一下载任务管理器（rawTask 稍后赋值为 PLDownloadOperation；悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = shader.fileName.length > 0 ? shader.fileName : (shader.displayName.length > 0 ? shader.displayName : @"shader");
    NSString *displayName = shader.displayName.length > 0 ? shader.displayName : resourceName;
    // Task218：来源标签收敛到 PLMirrorCenter（显示层专用 token；路由一律走候选链）。
    NSString *downloadSource = [PLMirrorCenter legacySourceTokenForType:PLMirrorResourceTypeAssetDownload];
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeShader
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:nil
                      supportsResume:YES
                             iconURL:shader.iconURL];
    taskItem.downloadURL = shader.selectedVersionDownloadURL;
    // ★ Task270 M2：下载目标实例随任务标注（对齐 ModService Task266 中央落点
    // ——跨实例对账/死名回落此前仅 mods 享有，四服务统一）。
    taskItem.targetProfileName = profileName;
    // redesign-download-ui Phase 4：单文件下载接入统一进度页——
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
    // （PLMirrorCenter 统一收敛，替代旧版独立镜像工具类）
    request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                          resourceType:PLMirrorResourceTypeAssetDownload];
    // Task 5.1：expectedSHA1（版本模型 files[].hashes.sha1）传入即启用 SHA1 校验
    request.expectedSHA1 = expectedSHA1;
    // Task 5.2：目标文件已存在且校验通过 → 零流量直接成功（增量下载）；
    // 目标路径语义与原实现一致（shaderpacks/<fileName>.zip）
    request.destinationPath = destinationPath;
    // taskIdentifier 用 DownloadTaskManager 的 taskId，断点续传数据跨次下载可复用
    request.taskIdentifier = taskItem.taskId;
    // 无 SHA1 时对 .zip 做 EOCD 兜底完整性校验
    request.allowZipFallbackCheck = YES;

    [self startPLDownloadWithRequest:request taskItem:taskItem progress:progress completion:completion];

    NSLog(@"[ShaderService] Starting download task (with progress) for shader: %@ -> %@", url, destinationPath);
}

#pragma mark - PLDownloadClient 封装（进度 delta 累计 / 速率采样 / 完成分发）

/// 发起（或重发）PLDownloadClient 请求并挂接进度、速率、完成回调。
/// progress/completion 传 nil 时不覆盖已登记的回调（retryHandler 重发时复用首次回调）。
- (nullable PLDownloadOperation *)startPLDownloadWithRequest:(PLDownloadRequest *)request
                                                     taskItem:(DownloadTaskItem *)taskItem
                                                     progress:(nullable void(^)(NSProgress *))progress
                                                   completion:(nullable ShaderDownloadHandler)completion {
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
    // redesign-download-ui Phase 4：单阶段任务进入下载时将阶段0 置为 Running
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
    void (^progressHandler)(NSProgress *) = self.downloadProgressHandlers[taskId];
    [self.downloadStateLock unlock];

    double fraction = totalStored > 0 ? (double)accumulated / (double)totalStored : -1.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 progress:fraction
                                               totalBytes:totalStored
                                          downloadedBytes:accumulated];
    // redesign-download-ui Phase 4：单阶段任务的阶段进度与任务总进度保持一致
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  progress:fraction
                                                 message:nil];

    if (!progressHandler) return;

    // 构造带 throughput/ETA 的 NSProgress，供调用方（DownloadViewController）
    // 在 FCL 风格的下载进度卡片上显示速度和 ETA
    NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:totalStored > 0 ? totalStored : -1];
    downloadProgress.completedUnitCount = accumulated;
    if (lastSpeed > 0) {
        downloadProgress.throughput = @(lastSpeed);
        if (totalStored > accumulated) {
            downloadProgress.estimatedTimeRemaining = @((double)(totalStored - accumulated) / lastSpeed);
        }
    }
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
- (void)handlePLDownloadCompletion:(BOOL)success
                             error:(nullable NSError *)error
                            taskId:(NSString *)taskId
                         generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    ShaderDownloadHandler completion = self.downloadCompletionHandlers[taskId];
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
        NSError *capturedError = success ? nil : error;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(capturedError);
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