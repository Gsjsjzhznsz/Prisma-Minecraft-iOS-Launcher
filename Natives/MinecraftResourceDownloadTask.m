#include <CommonCrypto/CommonDigest.h>
#include <sys/time.h>

#import "authenticator/BaseAuthenticator.h"
#import "installer/modpack/ModpackAPI.h"
#import "installer/ForgeDirectInstaller.h"
#import "AFNetworking.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "ModpackImportService.h"
#import "PLMirrorCenter.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "PLProfiles.h"   // ★ Task302：实例注册表预登记（吞实例根修）
#import "ios_uikit_bridge.h"
#import "utils.h"

// Task259：随包名迁移 com.air-devs.air → com.prisma-devs.prisma。
// 后台会话标识改名的代价：跨版本升级时旧标识的进行中后台下载无法重接
// （后台 attachment 一次性），仅影响"升级瞬间恰好在后台下载"的极小场景。
NSString * const kMinecraftResourceDownloadBackgroundSessionIdentifier = @"com.prisma-devs.prisma.MinecraftResourceDownloadTask";

// 原版安装 6 步的阶段下标（与 PLTaskStagesVanilla() 一致，redesign-download-ui Phase 3 Task 3.1）
static const NSUInteger kMCStageIndexFetchManifest = 0;
static const NSUInteger kMCStageIndexVersionJSON = 1;
static const NSUInteger kMCStageIndexDownloadClient = 2;
static const NSUInteger kMCStageIndexLibraries = 3;
static const NSUInteger kMCStageIndexAssets = 4;
static const NSUInteger kMCStageIndexVerify = 5;

// ===== Task312 ame312：批量下载吞吐量见证与低速换源（会话内生效，不落盘） =====
// 病历（用户反馈 2026-10-20）：“6.5.5 下载速度比 6.5.0 慢多了”。双 tag 全链
// 审计（v6.5.0→v6.5.5：MinecraftResourceDownloadTask/PLMirrorCenter/
// DownloadTasksViewController/ForgeDirectInstaller/Tools.java 下载核心逐字节
// 零改动）定性：非代码回归，是官方源路由劣化——现有候选轮换只在
// 【彻底失败】后才切镜像，“慢而不断”的官方源永不轮换，用户只能爬。
// 修复：会话内吞吐量见证——按源累计（样本≥512KB 且耗时≥0.5s 的完成任务），
// 官方源平均吞吐 < 128KB/s 且样本≥2 → 本批后续文件换镜像候选在前；
// 镜像自身也被证慢（< 32KB/s 且样本≥2）→ 回退官方，防双向误伤。不改
// 用户偏好，不落盘，每次启动重新观测（网络状况会变，持久化反而粘错）。
typedef struct {
    double bytes;
    double elapsed;
    NSInteger samples;
} ame312_SourceStats;

// [0]=官方源 [1]=镜像源
static ame312_SourceStats ame312_stats[2];
static BOOL ame312_batchPreferMirror = NO;
static BOOL ame312_mirrorProvenSlow = NO;

static double ame312_avgKBps(NSInteger idx) {
    if (ame312_stats[idx].elapsed <= 0) return -1.0;
    return (ame312_stats[idx].bytes / ame312_stats[idx].elapsed) / 1024.0;
}

static void ame312_recordThroughput(NSInteger idx, double bytes, double elapsed) {
    // 小文件/瞬时完成样本无统计意义，跳过（SHA 命中/秒下不计）
    if (bytes < 512.0 * 1024.0 || elapsed < 0.5) return;
    ame312_stats[idx].bytes += bytes;
    ame312_stats[idx].elapsed += elapsed;
    ame312_stats[idx].samples += 1;
    double kbps = ame312_avgKBps(idx);
    NSLog(@"[MCDL] ame312: source[%ld] throughput sample %ld -> avg %.0f KB/s",
          (long)idx, (long)ame312_stats[idx].samples, kbps);
    if (idx == 0 && !ame312_batchPreferMirror && !ame312_mirrorProvenSlow
        && ame312_stats[0].samples >= 2 && kbps >= 0 && kbps < 128.0) {
        ame312_batchPreferMirror = YES;
        NSLog(@"[MCDL] ame312: official source SLOW (%.0f KB/s over %ld samples) -- "
              @"switching remaining batch to mirror-first (session-scoped)",
              kbps, (long)ame312_stats[0].samples);
    }
    if (idx == 1 && ame312_batchPreferMirror && !ame312_mirrorProvenSlow
        && ame312_stats[1].samples >= 2 && kbps >= 0 && kbps < 32.0) {
        ame312_mirrorProvenSlow = YES;
        ame312_batchPreferMirror = NO;
        NSLog(@"[MCDL] ame312: mirror also SLOW (%.0f KB/s over %ld samples) -- "
              @"reverting to official candidates for remaining batch",
              kbps, (long)ame312_stats[1].samples);
    }
}

@interface MinecraftResourceDownloadTask ()
@property AFURLSessionManager* manager;
@property (nonatomic, strong) DownloadTaskItem *currentDownloadTaskItem;
@property (nonatomic, copy) NSString *currentVersionId;
@property (nonatomic, assign) BOOL isObservingTaskProgress;
@property (nonatomic, assign) NSTimeInterval progressLastTime;
@property (nonatomic, assign) int64_t progressLastCompleted;

// ===== 阶段上报（redesign-download-ui Phase 3 Task 3.1）=====
// 仅 downloadVersion:（原版安装链路）启用阶段上报；整合包下载走 ModpackImportService 自行上报
@property (nonatomic, assign) BOOL stageReportingEnabled;
// Task187：downloadVersion: 入口时间零点（验证完整性阶段耗时锚点用）
@property (nonatomic, assign) CFTimeInterval ame187_taskStartTs;
// 库文件/资源文件双维度计数（按下载目标路径分类；versions/ 下的 version JSON 不计入）
@property (nonatomic, assign) NSInteger libTotalFileCount;
@property (nonatomic, assign) NSInteger libCompletedFileCount;
@property (nonatomic, assign) NSInteger assetTotalFileCount;
@property (nonatomic, assign) NSInteger assetCompletedFileCount;

// Task 5.10：在线整合包 zip 下载完成后的统一导入入口（复用 ModpackImportService）
- (void)importDownloadedModpackPackage:(NSString *)packagePath;
@end

@implementation MinecraftResourceDownloadTask

+ (AFURLSessionManager *)sharedBackgroundSessionManager {
    // 参照 main 分支：使用前台 defaultSessionConfiguration 而非后台 backgroundSessionConfiguration。
    //
    // 为什么不用后台 URLSession：
    // 1. 后台会话由系统守护进程 nsurlsessiond 调度，会限流并发数、串行化任务，
    //    导致原版下载（数百个 asset + 数十个 library）极慢，"转圈不下载"。
    // 2. 后台会话的未完成任务会被系统持久化，失败/取消不干净时残留 task 卡住新下载。
    // 3. 前台会话 resume 即立即并发执行，适合启动器这种前台活跃下载场景。
    //
    // 保留单例模式（避免每次 init 都创建新会话），但使用前台配置。
    static AFURLSessionManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        configuration.timeoutIntervalForRequest = 86400;
        // 参考 FCL（FoldCraftLauncher）和 ZalithLauncher2：高并发下载加速。
        // FCL 在 Java 端使用 OkHttp 的线程池并发下载，本项目对应在 NSURLSession
        // 层面提升 HTTPMaximumConnectionsPerHost。从 16 提升到 24，加速原版数百个
        // asset 的并发下载。注意 iOS 系统对单 host 实际并发有调度上限，过高的设置
        // 会被系统降级，24 是经验值。完整性仍由 SHA1 校验保证。
        configuration.HTTPMaximumConnectionsPerHost = 24;
        manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    });
    return manager;
}

- (void)dealloc {
    if (self.isObservingTaskProgress && self.progress) {
        @try {
            [self.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            // ignore
        }
        self.isObservingTaskProgress = NO;
    }
}

- (instancetype)init {
    self = [super init];
    self.manager = [MinecraftResourceDownloadTask sharedBackgroundSessionManager];
    self.fileList = [NSMutableArray new];
    self.progressList = [NSMutableArray new];
    // 阶段5修复：初始化失败文件列表（参照 FCL 的失败汇总机制）
    self.failedFiles = [NSMutableArray new];
    return self;
}

// 根据配置选择下载源并替换URL
- (NSString *)replaceURLWithDownloadSource:(NSString *)originalURL {
    return [self replaceURLWithDownloadSource:originalURL forceSource:nil];
}

/// 生成游戏文件的镜像候选列表（接入 PLMirrorCenter 镜像中心）
/// 候选包含原始（官方）URL 与 BMCLAPI 镜像 URL，已去重并按当前镜像策略排序；
/// 无法识别的主机仅返回原始 URL。镜像前缀映射统一收敛在 PLMirrorCenter，
/// 本类不再硬编码镜像根 URL。
- (NSArray<NSURL *> *)mirrorCandidatesForOriginalURL:(NSString *)originalURL {
    NSURL *url = [NSURL URLWithString:originalURL];
    if (!url) return @[];
    return [PLMirrorCenter candidateURLsForOriginalURL:url
                                          resourceType:PLMirrorResourceTypeGameFile];
}

/// 镜像源替换核心实现（接入 PLMirrorCenter，spec Task 4.2）。
/// 参考 FCL（FoldCraftLauncher）和 ZalithLauncher2：支持多镜像源 fallback。
/// @param originalURL 原始 URL
/// @param forceSource 强制使用的源（保留旧参数语义）：
///                    nil=按 PLMirrorCenter 当前策略取首选（策略内部含旧键回退）；
///                    @"official"=锁定官方原始 URL；
///                    @"bmclapi"=锁定 BMCLAPI 镜像候选（无镜像候选时回退原始 URL）；
///                    @"mcim"=沿用旧行为：MCIM 不覆盖 Mojang 系游戏文件，原样返回。
- (NSString *)replaceURLWithDownloadSource:(NSString *)originalURL forceSource:(nullable NSString *)forceSource {
    if (!originalURL) return originalURL;

    NSArray<NSURL *> *candidates = [self mirrorCandidatesForOriginalURL:originalURL];
    if (candidates.count == 0) return originalURL;

    if (forceSource.length == 0) {
        // nil → 按 PLMirrorCenter 策略取首选候选
        return candidates.firstObject.absoluteString ?: originalURL;
    }
    if ([forceSource isEqualToString:@"official"] || [forceSource isEqualToString:@"mcim"]) {
        // 官方源直连；mcim 沿用旧行为（游戏文件不走 MCIM 改写）
        return originalURL;
    }
    if ([forceSource isEqualToString:@"bmclapi"]) {
        // 锁定 BMCLAPI 镜像候选（候选中与原始 URL 不同的那一项）
        for (NSURL *candidate in candidates) {
            if (![candidate.absoluteString isEqualToString:originalURL]) {
                return candidate.absoluteString;
            }
        }
        return originalURL;
    }
    // 未知源值：按策略取首选
    return candidates.firstObject.absoluteString ?: originalURL;
}

// Add file to the queue
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:0 success:success];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path retryCount:(NSInteger)retryCount success:(void (^)())success {
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    // logSuccess?
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        // 阶段计数：已存在且校验通过的文件计入"库/资源"维度（重试调用不会进入此分支）
        if (retryCount == 0) {
            [self mc_recordStageFileStartedAtPath:path];
            [self mc_recordStageFileFinishedAtPath:path];
        }
        if (success) success();
        return nil;
    } else if (![self checkAccessWithDialog:YES]) {
        return nil;
    }
    // 阶段计数：首次创建时计入总量（重试轮换不重复计数）
    if (retryCount == 0) {
        [self mc_recordStageFileStartedAtPath:path];
    }

    NSString *name = altName ?: path.lastPathComponent;
    // 镜像候选与故障转移（接入 PLMirrorCenter，spec Task 4.2）：
    // 候选列表按当前镜像策略排序（如 [官方, BMCLAPI 镜像]）。重试时同一候选耗尽
    // 单候选重试预算后轮换到下一候选继续重试，全部候选耗尽才最终失败，
    // 避免单一镜像源故障导致整批下载卡死（参考 FCL / ZalithLauncher2 的多源 fallback）。
    // SHA1 校验仍照常进行，不破坏下载完整性。
    NSArray<NSURL *> *mirrorCandidates = [self mirrorCandidatesForOriginalURL:url];
    if (mirrorCandidates.count == 0) {
        // URL 无法解析的极端情况：退化为仅含原始 URL 的单候选，保持旧行为
        NSURL *fallbackURL = [NSURL URLWithString:url];
        mirrorCandidates = fallbackURL ? @[fallbackURL] : @[];
    }
    NSInteger maxRetry = self.maxRetryCount > 0 ? self.maxRetryCount : 3;
    // ame312：吞吐量见证判官方源低速时，本批后续文件镜像候选在前（会话内
    // 生效，见文件头部 ame312 契约注释）。必须先交换候选序、再算 candidateIndex。
    if (ame312_batchPreferMirror && mirrorCandidates.count == 2) {
        mirrorCandidates = @[[mirrorCandidates.lastObject copy],
                             [mirrorCandidates.firstObject copy]];
    }
    // 总尝试次数 = 单候选重试预算 × 候选数（全部候选耗尽才最终失败）
    NSInteger attemptCount = MAX((NSInteger)mirrorCandidates.count, 1) * maxRetry;
    // 当前尝试对应的候选索引：第 0~(maxRetry-1) 次尝试用候选 0，耗尽后轮换下一候选
    NSUInteger candidateIndex = mirrorCandidates.count > 0
        ? MIN((NSUInteger)(MAX(retryCount, 0) / MAX(maxRetry, 1)), mirrorCandidates.count - 1)
        : 0;
    NSString *replacedURL = mirrorCandidates.count > 0
        ? (mirrorCandidates[candidateIndex].absoluteString ?: url)
        : url;
    if (retryCount > 0) {
        NSLog(@"[MCDL] Retry %@ (attempt %ld/%ld, mirror candidate %lu/%lu)",
              name, (long)(retryCount + 1), (long)attemptCount,
              (unsigned long)(candidateIndex + 1), (unsigned long)mirrorCandidates.count);
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:replacedURL]];
    // ame312：本任务走的源（0=官方 1=镜像）与起始时刻，完成时回填吞吐量样本
    BOOL ame312_isMirror = ![replacedURL isEqualToString:url];
    CFTimeInterval ame312_startTs = CFAbsoluteTimeGetCurrent();
    __block NSProgress *progress;
    __weak MinecraftResourceDownloadTask *weakSelf = self;
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[MCDL] Downloading %@", name);
        // ★ Task259（清单 6）：文件级明细（统一进度页详情区 + 下载中心 cell）
        [weakSelf mc_reportCurrentFileAtPath:path altName:altName];
        if (!weakSelf) {
            [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            return [NSURL fileURLWithPath:path];
        }
        progress = [weakSelf.manager downloadProgressForTask:task];
        if (!size && task) {
            [weakSelf addDownloadTaskToProgress:task size:response.expectedContentLength];
            [weakSelf.fileList addObject:name];
        }
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        if (self.progress.cancelled) {
            // Ignore any further errors
        } else if (error != nil) {
            // 重试机制（候选轮换故障转移：同候选耗尽预算换下一候选，全部候选耗尽才最终失败）
            if (retryCount + 1 < attemptCount) {
                NSInteger nextRetry = retryCount + 1;
                NSLog(@"[MCDL] Retrying %@ (attempt %ld/%ld)", name, (long)(nextRetry + 1), (long)attemptCount);

                if (weakSelf.retryCallback) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        weakSelf.retryCallback(nextRetry, attemptCount);
                    });
                }
                
                // 延迟重试（缩短到 0.5 秒，避免数百个文件重试时累加延迟过长）
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURLSessionDownloadTask *retryTask = [weakSelf createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:nextRetry success:success];
                    if (retryTask) {
                        [retryTask resume];
                    }
                });
            } else {
                [weakSelf finishDownloadWithError:error file:name];
                // 阶段计数：最终失败的文件也计入完成数（避免计数卡住）
                [weakSelf mc_recordStageFileFinishedAtPath:path];
                // 阶段5修复（参照 FCL）：单文件失败后必须手动推进进度，否则父 progress
                // 永远不会达到 100%（failed 子 progress 的份额无人填补），
                // 用户会看到下载条卡住不动，误以为下载未完成。
                // 注意：destination block 只在下载成功时才会被调用，所以这里 progress
                // 可能为 nil。需要重新从 manager 取该 task 对应的子 progress。
                NSProgress *taskProgress = progress ?: [weakSelf.manager downloadProgressForTask:task];
                if (taskProgress) {
                    int64_t pending = taskProgress.totalUnitCount - taskProgress.completedUnitCount;
                    if (pending > 0) {
                        taskProgress.completedUnitCount = taskProgress.totalUnitCount;
                    }
                } else if (weakSelf.progress.totalUnitCount > weakSelf.progress.completedUnitCount) {
                    // 极端兜底：连子 progress 都拿不到（如 size 未知且 destination 未触发），
                    // 直接给父 progress 推 1 个单位，避免下载条卡死。
                    weakSelf.progress.completedUnitCount += 1;
                }
            }
        } else if (![self checkSHA:sha forFile:path altName:altName]) {
            // SHA1 校验失败也尝试重试（同样按候选列表轮换故障转移）
            if (retryCount + 1 < attemptCount) {
                NSInteger nextRetry = retryCount + 1;
                NSLog(@"[MCDL] SHA1 mismatch, retrying %@ (attempt %ld/%ld)", name, (long)(nextRetry + 1), (long)attemptCount);

                // 删除损坏的文件
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];

                // SHA 失败重试延迟缩短到 0.3 秒
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSURLSessionDownloadTask *retryTask = [weakSelf createDownloadTask:url size:size sha:sha altName:altName toPath:path retryCount:nextRetry success:success];
                    if (retryTask) {
                        [retryTask resume];
                    }
                });
            } else {
                // 阶段5修复（参照 FCL）：SHA1 校验失败也记录到 failedFiles，不取消整批任务
                @synchronized(weakSelf.failedFiles) {
                    [weakSelf.failedFiles addObject:@{
                        @"name": path.lastPathComponent ?: @"unknown",
                        @"error": @"SHA1 mismatch"
                    }];
                }
                NSLog(@"[MCDL] SHA1 mismatch for '%@', added to failedFiles (total failed: %lu), other downloads will continue",
                      path.lastPathComponent, (unsigned long)weakSelf.failedFiles.count);
                // 阶段计数：SHA 校验最终失败的文件也计入完成数
                [weakSelf mc_recordStageFileFinishedAtPath:path];
                // 阶段5修复：与上面 error 分支一致，推进父 progress 避免卡死
                NSProgress *taskProgress2 = progress ?: [weakSelf.manager downloadProgressForTask:task];
                if (taskProgress2) {
                    int64_t pending = taskProgress2.totalUnitCount - taskProgress2.completedUnitCount;
                    if (pending > 0) {
                        taskProgress2.completedUnitCount = taskProgress2.totalUnitCount;
                    }
                } else if (weakSelf.progress.totalUnitCount > weakSelf.progress.completedUnitCount) {
                    weakSelf.progress.completedUnitCount += 1;
                }
            }
        } else {
            progress.totalUnitCount = progress.completedUnitCount;
            [self mc_recordStageFileFinishedAtPath:path];
            // ame312：成功任务回填吞吐量样本（镜像/官方源择路依据，见文件头契约）
            {
                double ame312_bytes = (double)task.countOfBytesReceived;
                double ame312_elapsed = CFAbsoluteTimeGetCurrent() - ame312_startTs;
                if (ame312_bytes <= 0) ame312_bytes = (double)size;
                ame312_recordThroughput(ame312_isMirror ? 1 : 0, ame312_bytes, ame312_elapsed);
            }
            if (success) success();
        }
    }];

    if (size && task) {
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:name];
    }

    if (task && self.currentDownloadTaskItem) {
        task.taskDescription = self.currentDownloadTaskItem.taskId;
    }

    return task;
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSInteger)size {
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    NSUInteger fileSize = size>0 ? size : 1;
    progress.kind = NSProgressKindFile;
    if (size > 0) {
        progress.totalUnitCount = fileSize;
    }
    [self.progressList addObject:progress];
    [self.progress addChild:progress withPendingUnitCount:fileSize];
    self.progress.totalUnitCount += fileSize;
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success {
    // Download base json
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }

    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), versionStr];
    // Find it again to resolve latest-*
    // Task300：重命名实例时清单查找必须用原始 id——新目录名不在远端清单里，
    // 直接 findVersion 必失败 → 误入本地版本分支报"json 丢失"。ame300_origId
    // 由 downloadVersion: 命名流写入，其余路径（latest-*/普通下载）不含该键。
    NSString *ame300_lookupId = version[@"ame300_origId"];
    BOOL ame300_renamed = [ame300_lookupId isKindOfClass:[NSString class]] && ame300_lookupId.length > 0;
    if (!ame300_renamed) ame300_lookupId = versionStr;
    version = (id)[MinecraftResourceUtils findVersion:ame300_lookupId inList:remoteVersionList];

    void(^completionBlock)(void) = ^{
        self.metadata = parseJSONFromFile(path);
        if (self.metadata[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[self.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (self.metadata[@"inheritsFrom"]) {
            NSString *parentJsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), self.metadata[@"inheritsFrom"]];
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile(parentJsonPath);
            if (!inheritsFromDict || inheritsFromDict[@"NSErrorObject"]) {
                // Task 70 修复：父版本 JSON 缺失或损坏（半截写入/解析失败）时，旧实现直接弹
                // “缺少父版本 %@ 的 version.json”死路——用户明明预装过原版（如 26.2）也会因
                // 文件损坏被误报“丢失”，未预装时也不会尝试自动补拉。现在：删除坏文件 → 走
                // ForgeDirectInstaller.ensureParentVersionExists（官方/BMCLAPI 候选轮换 + 3 次
                // 重试自动补拉）→ 重新解析，仍失败才报错。
                [NSFileManager.defaultManager removeItemAtPath:parentJsonPath error:nil];
                NSError *healError = nil;
                if ([ForgeDirectInstaller ensureParentVersionExists:self.metadata[@"inheritsFrom"] error:&healError]) {
                    NSLog(@"[MCDL] Task70 parent version JSON re-fetched from manifest: %@", parentJsonPath);
                    inheritsFromDict = parseJSONFromFile(parentJsonPath);
                } else {
                    NSLog(@"[MCDL] Task70 parent version manifest fetch failed: %@", healError.localizedDescription ?: @"unknown");
                }
            }
            if (inheritsFromDict && !inheritsFromDict[@"NSErrorObject"]) {  // 添加错误字典检测
                // 修复：parseJSONFromFile 返回错误字典而非 nil，
                //   导致 inheritsFrom 父版本缺失时错误字典被当作 metadata
                [MinecraftResourceUtils processVersion:self.metadata inheritsFrom:inheritsFromDict];
                self.metadata = inheritsFromDict;
            } else {
                // 父版本不存在或损坏，报错
                [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"i18n_str_446", nil), self.metadata[@"inheritsFrom"]]];
                return;
            }
        }
        [MinecraftResourceUtils tweakVersionJson:self.metadata];
        success();
    };

    // ★ Task303：改名流清单查找失败兜底（点启动弹改名窗的因果根）。
    // 病历（装机 2026-10-19 实锤）：Task300 renamed 后 2s 即报 ParseJSON
    // “26.1.2 2.json 不存在”——remoteVersionList 是被 LauncherRootVC/DownloadVC/
    // CardLayout 三源 removeAllObjects 重建的非线程安全全局，改名确认瞬间正逢
    // Task218 piston 重载进行中 → findVersion 返回 nil → 误入本地版本分支读
    // 不存在的新路径。更糟的是 prepareForDownload 已建残根目录 → 用户点启动
    // 该实例 → 补拉链撞残根弹残根/命名窗 = “点启动游戏出现重命名实例”。
    // 兑底语义：改名流的前置就是原始 id 目录已存在 → 原始 json 在 → 直接复制
    // json+jar 到新名目录（json 内部 id 重写为新名，Task71 同语义），库/资产
    // 阶段按 SHA 自动跳过，零下载秒完成；原始 json 也不在才报清单错误。
    if (!version && ame300_renamed) {
        NSString *ame303_srcJson = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                                    getenv("POJAV_GAME_DIR"), ame300_lookupId];
        NSMutableDictionary *ame303_json = parseJSONFromFile(ame303_srcJson);
        if (ame303_json && !ame303_json[@"NSErrorObject"]) {
            [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                    withIntermediateDirectories:YES attributes:nil error:nil];
            ame303_json[@"id"] = versionStr;
            NSError *ame303_writeErr = nil;
            NSData *ame303_data = [NSJSONSerialization dataWithJSONObject:ame303_json
                                                                  options:NSJSONWritingPrettyPrinted
                                                                    error:&ame303_writeErr];
            BOOL ame303_ok = ame303_data && [ame303_data writeToFile:path options:NSDataWritingAtomic error:&ame303_writeErr];
            NSString *ame303_srcJar = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.jar",
                                       getenv("POJAV_GAME_DIR"), ame300_lookupId];
            NSString *ame303_dstJar = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.jar",
                                       getenv("POJAV_GAME_DIR"), versionStr];
            if ([NSFileManager.defaultManager fileExistsAtPath:ame303_srcJar]
                && ![NSFileManager.defaultManager fileExistsAtPath:ame303_dstJar]) {
                [NSFileManager.defaultManager copyItemAtPath:ame303_srcJar toPath:ame303_dstJar error:nil];
            }
            if (ame303_ok) {
                NSLog(@"[MCDL] Task303 renamed local-copy fallback: %@ -> %@ (remote manifest race/absent)",
                      ame300_lookupId, versionStr);
                completionBlock();
                return;
            }
            NSLog(@"[MCDL] Task303 local-copy write failed: %@", ame303_writeErr.localizedDescription ?: @"unknown");
            [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"ame303.copy_failed", nil), versionStr]];
            return;
        }
        NSLog(@"[MCDL] Task303 renamed lookup miss + no local base json (%@)", ame300_lookupId);
        [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"ame303.manifest_missing", nil), ame300_lookupId]];
        return;
    }

    if (!version) {
        // This is likely local version, check if json exists and has inheritsFrom
        NSMutableDictionary *json = parseJSONFromFile(path);
        if (json[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[json[@"NSErrorObject"] localizedDescription]];
            return;
        }

        // ===== Task 71 修复（启动侧自愈）：版本 JSON 内部 id 与目录名不一致 =====
        // 场景：整合包导入（Task 5.6 versionId 唯一化，目录名带 -<hash8> 后缀）但
        // installModLoader 写入的 Fabric/Quilt meta profile 内部 id 是无后缀标准名
        // （旧构建已落盘的坏档）。后果链：
        //   metadata.id = 内部 id（无后缀）→ JavaLauncher 以其为 args[1] →
        //   Java Tools.getVersionInfo 读 versions/<无后缀>/<无后缀>.json →
        //   文件实际在带后缀目录 → FileNotFoundException（用户看到的"json丢失"）→ exit(1)。
        // 自愈动作（对已存在的坏档）：①把 JSON 内部 id 重写为目录名 versionStr；
        // ②把此前被无后缀 id 误导而下载到无后缀目录的 client.jar 迁移到本目录
        // （避免整包重下）；③旧目录搬空后清理，避免版本列表出现幽灵条目。
        // 不一致只可能出现在"目录名 != JSON id"的坏档上，正常安装（两者一致）零影响。
        NSString *task71InternalId = [json[@"id"] isKindOfClass:[NSString class]] ? json[@"id"] : nil;
        if (versionStr.length > 0 && task71InternalId.length > 0 && ![task71InternalId isEqualToString:versionStr]) {
            NSLog(@"[MCDL] Task71 version JSON id mismatch: folder=%@ internal=%@ — healing",
                  versionStr, task71InternalId);
            json[@"id"] = versionStr;
            NSError *task71WriteError = saveJSONToFile(json, path);
            if (task71WriteError) {
                // 非致命：写回失败时仅内存修正（本次启动仍可用），下轮再自愈
                NSLog(@"[MCDL] Task71 heal write failed (non-fatal): %@",
                      task71WriteError.localizedDescription);
            } else {
                NSLog(@"[MCDL] Task71 version JSON id healed: %@ -> %@",
                      task71InternalId, versionStr);
            }

            // client.jar 迁移：versions/<internalId>/<internalId>.jar -> versions/<versionStr>/<versionStr>.jar
            NSString *task71OldJar = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.jar",
                                      getenv("POJAV_GAME_DIR"), task71InternalId];
            NSString *task71NewJar = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.jar",
                                      getenv("POJAV_GAME_DIR"), versionStr];
            NSFileManager *task71FM = [NSFileManager defaultManager];
            if ([task71FM fileExistsAtPath:task71OldJar] && ![task71FM fileExistsAtPath:task71NewJar]) {
                NSError *task71MoveError = nil;
                if ([task71FM moveItemAtPath:task71OldJar toPath:task71NewJar error:&task71MoveError]) {
                    NSLog(@"[MCDL] Task71 client jar migrated: %@ -> %@",
                          task71OldJar.lastPathComponent, task71NewJar.lastPathComponent);
                    // 旧目录搬空后清理（目录内仍有 json 等文件时保留，不做破坏性删除）
                    NSString *task71OldDir = task71OldJar.stringByDeletingLastPathComponent;
                    NSArray *task71Remaining = [task71FM contentsOfDirectoryAtPath:task71OldDir error:nil];
                    if (task71Remaining.count == 0) {
                        [task71FM removeItemAtPath:task71OldDir error:nil];
                        NSLog(@"[MCDL] Task71 empty legacy version dir removed: %@", task71OldDir);
                    }
                } else {
                    // 迁移失败不阻断：client.jar 走正常下载路径补齐（SHA 校验兜底）
                    NSLog(@"[MCDL] Task71 client jar migration failed (will re-download): %@",
                          task71MoveError.localizedDescription);
                }
            }
        }
        // ===== Task 71 自愈结束 =====

        if (json[@"inheritsFrom"]) {
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            if (version) {
                path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
            } else {
                // 阶段5修复（参照 FCL ModpackHelper.ensureCompleteVersion）：
                // findVersion 失败通常因为 remoteVersionList 尚未加载（整合包导入在后台线程，
                // 不经过 DownloadViewController 的清单加载流程）。
                // Task 70 修复：本地父版本 JSON 也不存在时，不再直接弹
                // “缺少父版本 %@ 的 version.json，且远程版本清单未加载”死路（用户只能手动预装
                // 原版再重试），而是主动走 ForgeDirectInstaller.ensureParentVersionExists 从
                // Mojang/BMCLAPI 版本清单拉取（候选轮换 + 重试）——与用户“提前下载原版”等价，
                // 但无需任何手动操作。只有清单也拉不到（网络完全不可用）才报错。
                NSString *parentJsonPath = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json",
                                            getenv("POJAV_GAME_DIR"), json[@"inheritsFrom"]];
                if (![NSFileManager.defaultManager fileExistsAtPath:parentJsonPath]) {
                    NSError *fetchError = nil;
                    if ([ForgeDirectInstaller ensureParentVersionExists:json[@"inheritsFrom"] error:&fetchError]) {
                        NSLog(@"[MCDL] Task70 parent version JSON fetched from manifest: %@", parentJsonPath);
                    } else {
                        NSLog(@"[MCDL] Task70 parent version manifest fetch failed: %@", fetchError.localizedDescription ?: @"unknown");
                        [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"i18n_str_447", nil), json[@"inheritsFrom"]]];
                        return;
                    }
                }
                NSLog(@"[MCDL] remoteVersionList not loaded, but parent version JSON exists: %@", parentJsonPath);
                completionBlock();
                return;
            }
        } else {
            completionBlock();
            return;
        }
    }

    // Task300：重命名实例保持落盘目录用新名——远端清单对象的 id 是原始名，
    // 此处重提取会吞掉新名（ame300_renamed 仅重命名流为 YES；latest-* 与普通
    // 下载不受影响，仍走清单对象 id 重提取）。
    if (!ame300_renamed) {
        versionStr = version[@"id"];
    }
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:path success:completionBlock];
    [task resume];
}

#pragma mark - Minecraft installation

- (void)downloadAssetMetadataWithSuccess:(void (^)())success {
    NSDictionary *assetIndex = self.metadata[@"assetIndex"];
    if (!assetIndex) {
        success();
        return;
    }
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndex[@"id"]];
    NSString *path = [@(getenv("POJAV_GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    }];
    [task resume];
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("POJAV_GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MDCL] Skipped library %@", name);
            continue;
        }

        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    if (!assets) {
        return @[];
    }
    for (NSString *name in assets[@"objects"]) {
        NSDictionary *object = assets[@"objects"][name];
        NSString *hash = object[@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];

        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("POJAV_GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("POJAV_GAME_DIR"), pathname];
        }

        /* Special case for 1.19+
         * Since 1.19-pre1, setting the window icon on macOS invokes ObjC.
         * However, if an IOException occurs, it won't try to set.
         * We skip downloading the icon file to workaround this. */
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }

        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (void)downloadVersion:(NSDictionary *)version {
    // ===== Task300：重复实例吞包根修（用户 2026-10-19"下载的新实例被吞了"）=====
    // 根因链：downloadVersion: 直接以 version[@"id"] 落盘 versions/<id>/，目标
    // 目录已存在时下载文件全部静默合并进旧实例（旧 json 被 SHA 通过的新 json
    // 覆盖），版本列表观感="新实例被吞了"。
    // 修法（对齐 HMCL/PCL 重复实例交互）：目标目录已存在 → 先弹命名窗（预填
    // 自增唯一名），取消则干净终止；确认后以新名落盘。远端清单查找仍用原始
    // id（ame300_origId 随 dict 透传，见 downloadVersionMetadata:），json 内部
    // id 与目录名不一致由 Task71 自愈链兜底对齐。
    NSString *ame300_origId = version[@"id"];
    NSString *ame300_target = [NSString stringWithFormat:@"%s/versions/%@",
                              getenv("POJAV_GAME_DIR"), ame300_origId];
    BOOL ame300_isDir = NO;
    if (ame300_origId.length > 0
        && ![ame300_origId hasPrefix:@"latest-"]   // latest-* 由元数据阶段二次解析，此处不拦
        && [NSFileManager.defaultManager fileExistsAtPath:ame300_target isDirectory:&ame300_isDir]
        && ame300_isDir) {
        // ★ Task301：残根目录分流——目录存在但 <id>.json 缺失 = 上次下载
        //   被中断的残根（版本列表只认完整实例→列表不可见，重下永远撞名
        //   = 用户实测"26.1.2 被吞"的死循环根）。弹清理确认而非命名窗。
        NSString *ame301_jsonPath = [ame300_target stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", ame300_origId]];
        if (![NSFileManager.defaultManager fileExistsAtPath:ame301_jsonPath]) {
            NSLog(@"[MCDL] Task301 residual dir detected (json missing): %@ -- prompting cleanup/rename", ame300_target);
            [self ame301_promptResidualForVersion:version originalId:ame300_origId];
            return;
        }
        // ★ Task304：启动校验链语义分离（用户 2026-10-19"依旧点启动弹改名窗"
        //   + 装机 ed7ae10 日志实锤模组端二次改名链）。病历：RightPanel/
        //   NavigationController 的 launchMinecraft 启动前完整性校验（HMCL
        //   风格"缺啥补啥"）也是调 downloadVersion: 实现的——本地完整实例
        //   （目录+json 都在）启动时必然撞目录 → Task300 命名窗每次启动必弹；
        //   模组端装完（installFabricLikeLoader 已写 json+注册 profile）顺手
        //   点启动 → 校验链再撞刚写的目录 → 二次改名 " 2 2" + mods 目录错位。
        //   修法：调用方带 ame300_launchcheck=YES（启动校验语义）时，目录+json
        //   完整 = 正是本校验的目标实例，直接放行走 SHA 校验补全，零弹窗；
        //   残根（json 缺）仍弹 Task301 三选窗保护 mods；下载安装链不带键
        //   = Task300 重复实例检测语义原样保留。
        if ([version[@"ame300_launchcheck"] boolValue]) {
            NSLog(@"[MCDL] Task304 launch-check path: existing complete instance %@ -- verify-and-continue (no rename prompt)", ame300_origId);
            [self ame300_downloadVersionChecked:version];
            return;
        }
        [self ame300_promptRenameForVersion:version
                                 originalId:ame300_origId
                                 suggestion:[self ame300_uniqueSuggestionForId:ame300_origId]];
        return;
    }
    [self ame300_downloadVersionChecked:version];
}

// Task300：预填唯一建议名 "<id> 2"、"<id> 3"...（目标目录不存在即采纳）
- (NSString *)ame300_uniqueSuggestionForId:(NSString *)origId {
    for (NSUInteger i = 2; i < 100; ++i) {
        NSString *cand = [NSString stringWithFormat:@"%@ %lu", origId, (unsigned long)i];
        NSString *candDir = [NSString stringWithFormat:@"%s/versions/%@",
                             getenv("POJAV_GAME_DIR"), cand];
        if (![NSFileManager.defaultManager fileExistsAtPath:candDir]) return cand;
    }
    return [NSString stringWithFormat:@"%@ %lu", origId,
            (unsigned long)[NSDate date].timeIntervalSince1970];
}

// ★ Task303：类方法版唯一名建议（模组端安装链与原版命名窗共用，语义同上）
+ (NSString *)ame303_uniqueSuggestionForId:(NSString *)origId {
    for (NSUInteger i = 2; i < 100; ++i) {
        NSString *cand = [NSString stringWithFormat:@"%@ %lu", origId, (unsigned long)i];
        NSString *candDir = [NSString stringWithFormat:@"%s/versions/%@",
                             getenv("POJAV_GAME_DIR"), cand];
        if (![NSFileManager.defaultManager fileExistsAtPath:candDir]) return cand;
    }
    return [NSString stringWithFormat:@"%@ %lu", origId,
            (unsigned long)[NSDate date].timeIntervalSince1970];
}

// ★ Task303：模组端安装链重复实例检测入口（DVC.installFabricLikeLoader 等）。
// 病历（用户 2026-10-19“下载原版有改名提示，模组端依旧被吞”）：原版下载链
// 有 Task300/301 重复检测+命名窗，模组端（Fabric/Quilt）写 versions/<id>/
// 前零检测——同 id 重复安装静默覆盖旧实例（“被吞”）。修法：目录已存在 →
// 弹 Task300 同款命名窗；取消 → cancelled=YES 调用方干净终止；目录不存在
// 直接回调原 id。completion 恒在主线程回调。
+ (void)ame303_resolveDuplicateVersionId:(NSString *)versionId
                              completion:(void (^)(NSString *finalId, BOOL cancelled))completion {
    NSString *target = [NSString stringWithFormat:@"%s/versions/%@",
                        getenv("POJAV_GAME_DIR"), versionId];
    BOOL isDir = NO;
    if (versionId.length == 0
        || ![NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&isDir]
        || !isDir) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(versionId, NO); });
        return;
    }
    NSString *suggestion = [self ame303_uniqueSuggestionForId:versionId];
    NSString *message = [NSString stringWithFormat:localize(@"ame300.dup.message", nil), versionId];
    ame300_promptRenameInstance(localize(@"ame300.dup.title", nil), message, suggestion,
        ^(NSString *chosenName) {
            if (chosenName.length == 0) {
                NSLog(@"[MCDL] Task303 loader-install duplicate naming cancelled (id=%@)", versionId);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, YES); });
                return;
            }
            NSString *chosenDir = [NSString stringWithFormat:@"%s/versions/%@",
                                   getenv("POJAV_GAME_DIR"), chosenName];
            if ([NSFileManager.defaultManager fileExistsAtPath:chosenDir]) {
                NSLog(@"[MCDL] Task303 chosen name still collides (%@) -- re-prompt", chosenName);
                [self ame303_resolveDuplicateVersionId:chosenName completion:completion];
                return;
            }
            NSLog(@"[MCDL] Task303 loader-install duplicate renamed: %@ -> %@", versionId, chosenName);
            dispatch_async(dispatch_get_main_queue(), ^{ completion(chosenName, NO); });
        });
}

// ★ Task301：残根目录三选窗（清理并重装 / 重命名继续 / 取消）。
// 残根 = versions/<id>/ 在但 <id>.json 缺失（下载中断遗留，列表不可见）。
// 清理 = 删除残根后按原始 id 正常下载；重命名 = 走 Task300 命名闭环；
// 取消 = Task300 同款干净终止（prepareForDownload+cancel，防
// vanillaPreinstall 30min 空转）。
- (void)ame301_promptResidualForVersion:(NSDictionary *)version originalId:(NSString *)origId {
    NSString *message = [NSString stringWithFormat:localize(@"ame301.residual.message", nil), origId];
    ame301_promptResidualInstance(
        localize(@"ame301.residual.title", nil),
        message,
        localize(@"ame301.residual.clean", nil),
        localize(@"ame301.residual.rename", nil),
        [self ame300_uniqueSuggestionForId:origId],
        ^{
            NSString *target = [NSString stringWithFormat:@"%s/versions/%@",
                                getenv("POJAV_GAME_DIR"), origId];
            NSError *ame301_err = nil;
            BOOL ame301_ok = [NSFileManager.defaultManager removeItemAtPath:target error:&ame301_err];
            NSLog(@"[MCDL] Task301 residual cleanup ok=%d target=%@ err=%@", ame301_ok, target, ame301_err);
            [self ame300_downloadVersionChecked:version];
        },
        ^(NSString *chosenName) {
            if (chosenName.length == 0) {
                [self ame301_cancelBeforeStart:origId];
                return;
            }
            NSString *chosenDir = [NSString stringWithFormat:@"%s/versions/%@",
                                   getenv("POJAV_GAME_DIR"), chosenName];
            if ([NSFileManager.defaultManager fileExistsAtPath:chosenDir]) {
                NSLog(@"[MCDL] Task301 chosen name still collides (%@) -- fall through to rename loop", chosenName);
                [self ame300_promptRenameForVersion:version originalId:origId
                                         suggestion:[self ame300_uniqueSuggestionForId:chosenName]];
                return;
            }
            NSMutableDictionary *renamed = [version mutableCopy];
            renamed[@"ame300_origId"] = origId;
            renamed[@"id"] = chosenName;
            NSLog(@"[MCDL] Task301 residual renamed download: %@ -> %@ (manifest lookup keeps %@)",
                  origId, chosenName, origId);
            [self ame300_downloadVersionChecked:renamed];
        },
        ^{
            [self ame301_cancelBeforeStart:origId];
        });
}

// Task301：下载未启动前的干净终止（ame300 取消分支同款语义）
- (void)ame301_cancelBeforeStart:(NSString *)origId {
    [self prepareForDownload];
    [self.progress cancel];
    NSLog(@"[MCDL] Task301 residual dialog cancelled -- download aborted before start (id=%@)", origId);
    if (self.currentDownloadTaskItem) {
        [[DownloadTaskManager sharedManager] setTaskWithId:self.currentDownloadTaskItem.taskId
                                                    state:DownloadTaskStateCancelled];
    }
}

// Task300：命名窗循环（确认名仍重复 → 带自增建议重弹；取消 → 干净终止）
- (void)ame300_promptRenameForVersion:(NSDictionary *)version
                           originalId:(NSString *)origId
                           suggestion:(NSString *)suggestion {
    NSString *message = [NSString stringWithFormat:localize(@"ame300.dup.message", nil), origId];
    ame300_promptRenameInstance(localize(@"ame300.dup.title", nil), message, suggestion,
        ^(NSString *chosenName) {
            if (chosenName.length == 0) {
                // 取消：先走 prepareForDownload 建立进度对象再 cancel——整合包
                // 预装轮询器（vanillaPreinstall）靠 progress.finished 退出，若不
                // 建 progress 会空转 30 分钟；cancel 后 finished=YES 且
                // succeeded=!p.cancelled=NO，调用方 completion(NO) 即刻出线。
                [self prepareForDownload];
                [self.progress cancel];
                NSLog(@"[MCDL] Task300 duplicate-instance naming cancelled -- download aborted before start (id=%@)", origId);
                if (self.currentDownloadTaskItem) {
                    [[DownloadTaskManager sharedManager] setTaskWithId:self.currentDownloadTaskItem.taskId
                                                                 state:DownloadTaskStateCancelled];
                }
                return;
            }
            NSString *chosenDir = [NSString stringWithFormat:@"%s/versions/%@",
                                   getenv("POJAV_GAME_DIR"), chosenName];
            if ([NSFileManager.defaultManager fileExistsAtPath:chosenDir]) {
                NSLog(@"[MCDL] Task300 chosen name still collides (%@) -- re-prompt", chosenName);
                [self ame300_promptRenameForVersion:version originalId:origId
                                         suggestion:[self ame300_uniqueSuggestionForId:chosenName]];
                return;
            }
            NSMutableDictionary *renamed = [version mutableCopy];
            renamed[@"ame300_origId"] = origId;
            renamed[@"id"] = chosenName;
            NSLog(@"[MCDL] Task300 duplicate instance renamed: %@ -> %@ (manifest lookup keeps %@)",
                  origId, chosenName, origId);
            [self ame300_downloadVersionChecked:renamed];
        });
}

- (void)ame300_downloadVersionChecked:(NSDictionary *)version {
    // Task187：验证阶段耗时锚点的时间零点（CFAbsoluteTime，CoreFoundation 恒可用）
    self.ame187_taskStartTs = CFAbsoluteTimeGetCurrent();

    self.currentVersionId = version[@"id"];

    // ===== ★ Task302：实例注册表预登记（吞实例三催根修）=====
    // 病历（用户 2026-10-19"依旧吞实例/重复实例重命名没有出现过"）：下载
    // 入口有三条（DownloadVC / RightPanel 快捷 / NavigationController），
    // 只有 DownloadVC.downloadVanillaVersion: 在下载前 saveProfile（3820
    // 家法）；RightPanel startDownloadWithVersion 全链零注册——版本实体
    // 落盘后实例注册表（launcher_profiles.json）无条目，实例列表按注册
    // 表枚举永远看不见 = "被吞"。Task300/301 改名闭环只解决目录撞名，
    // 解决不了注册缺失：改名下载照样隐身。
    // 修法：任务层统一预登记（对齐 DVC 家法：下载前即登记，中断下载也
    // 立即可见可删）。守卫：①latest-* 元数据二次解析阶段不登记（此刻
    // id 尚未定型）②同名 profile 已存在不覆盖（防误写用户定制）③已有
    // profile 引用该版本（lastVersionId 命中）不重复登记。
    {
        NSString *ame302_vid = version[@"id"];
        if ([ame302_vid isKindOfClass:NSString.class] && ame302_vid.length > 0
            && ![ame302_vid hasPrefix:@"latest-"]) {
            BOOL ame302_needRegister = YES;
            for (NSString *ame302_key in PLProfiles.current.profiles) {
                NSDictionary *ame302_p = PLProfiles.current.profiles[ame302_key];
                if (![ame302_p isKindOfClass:NSDictionary.class]) continue;
                if ([ame302_key isEqualToString:ame302_vid] ||
                    [ame302_p[@"lastVersionId"] isEqualToString:ame302_vid]) {
                    ame302_needRegister = NO;
                    break;
                }
            }
            if (ame302_needRegister) {
                NSMutableDictionary *ame302_profile = [NSMutableDictionary dictionary];
                ame302_profile[@"name"] = ame302_vid;
                ame302_profile[@"lastVersionId"] = ame302_vid;
                ame302_profile[@"gameDir"] = [NSString stringWithFormat:@"versions/%@/game", ame302_vid];
                ame302_profile[@"type"] = @"custom";
                ame302_profile[@"created"] = [NSDate date].description;
                [PLProfiles.current saveProfile:ame302_profile withName:ame302_vid];
                NSLog(@"[MCDL] Task302 profile auto-registered upfront: %@ (RightPanel/Navigation paths were invisible)", ame302_vid);
                [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
            }
        }
    }
    [self prepareForDownload];

    // ===== 阶段上报初始化（redesign-download-ui Phase 3 Task 3.1）=====
    // 原版 6 步：获取版本清单→下载版本JSON→下载客户端→下载库文件→下载资源文件→验证完整性
    // Task 70 修复：stageReportingEnabled 原本在 prepareForDownload 之前置 YES，而
    // prepareForDownload 内 addObserver(NSKeyValueObservingOptionInitial) 会立即同步触发
    // 一次 KVO 回调 → 此时 vanilla 6 阶段尚未 setTaskWithId:stages: 写入 →
    // "updateTaskWithId:stageAtIndex:rate: invalid stage index 3/4" 噪音每次必现
    // （见 2d321fa 日志 128-129 行）。移到阶段写入完成后才开启。
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSString *taskId = self.currentDownloadTaskItem.taskId;
    [manager setTaskWithId:taskId stages:PLTaskStagesVanilla()];
    self.stageReportingEnabled = YES;
    self.currentDownloadTaskItem.autoPresentDetail = YES;
    // 阶段0 版本清单：版本对象由调用方（版本列表/预装流程）解析提供，直接标记完成
    [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexFetchManifest status:PLTaskStageStatusCompleted];
    // 阶段2 下载客户端：iOS 启动器使用自有渲染管线，client.jar 由 Java 端启动时按需下载
    [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexDownloadClient status:PLTaskStageStatusSkipped];
    // 阶段1 下载版本 JSON 进行中（不确定进度：JSON 较小无需百分比）
    [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexVersionJSON status:PLTaskStageStatusRunning];
    [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexVersionJSON progress:-1 message:nil];
    [manager updateTaskWithId:taskId currentStageIndex:kMCStageIndexVersionJSON];

    __weak MinecraftResourceDownloadTask *weakSelf = self;
    [self downloadVersionMetadata:version success:^{
        __strong MinecraftResourceDownloadTask *strongSelf = weakSelf;
        if (!strongSelf) return;
        [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexVersionJSON status:PLTaskStageStatusCompleted];
        [strongSelf downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [strongSelf downloadClientLibraries];
            NSArray *assetTasks = [strongSelf downloadClientAssets];
            // Drop the 1 byte we set initially
            strongSelf.progress.totalUnitCount--;
            strongSelf.textProgress.totalUnitCount--;
            if (strongSelf.progress.totalUnitCount == 0) {
                // We have nothing to download, invoke completion observer
                strongSelf.progress.totalUnitCount = 1;
                strongSelf.progress.completedUnitCount = 1;
                strongSelf.textProgress.totalUnitCount = 1;
                strongSelf.textProgress.completedUnitCount = 1;
                return;
            }
            // 阶段3/4：库文件与资源文件并发下载（progress 不确定，靠双维度文件计数推进）
            [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexLibraries status:PLTaskStageStatusRunning];
            [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexAssets status:PLTaskStageStatusRunning];
            [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexLibraries progress:-1 message:nil];
            [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexAssets progress:-1 message:nil];
            [manager updateTaskWithId:taskId currentStageIndex:kMCStageIndexLibraries];
            [strongSelf mc_reportStageFileCounts];
            [libTasks makeObjectsPerformSelector:@selector(resume)];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            [strongSelf.metadata removeObjectForKey:@"assetIndexObj"];

            if (strongSelf.currentDownloadTaskItem) {
                [[DownloadTaskManager sharedManager] setTaskWithId:strongSelf.currentDownloadTaskItem.taskId
                                                              state:DownloadTaskStateDownloading];
            }
        }];
    }];
}

#pragma mark - Modpack installation

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    self.stageReportingEnabled = NO; // 整合包阶段上报由 ModpackImportService 负责（Phase 5）
    // Task 5.10：zip 下载阶段以整合包身份展示（显示名/类型/图标），
    // 导入阶段由 ModpackImportService 注册 6 阶段整合包主任务承接。
    NSString *title = [modDetail[@"title"] isKindOfClass:[NSString class]] ? modDetail[@"title"] : nil;
    self.currentVersionId = title.length > 0 ? title : localize(@"i18n_str_118", nil);
    [self prepareForDownload];
    if (self.currentDownloadTaskItem) {
        self.currentDownloadTaskItem.resourceType = DownloadTaskResourceTypeModpack;
        NSString *iconURL = [modDetail[@"imageUrl"] isKindOfClass:[NSString class]] ? modDetail[@"imageUrl"] : nil;
        self.currentDownloadTaskItem.iconURL = iconURL.length > 0 ? iconURL : nil;
    }

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *name = [[modDetail[@"title"] lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", name];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
        // Task 5.10：在线整合包下载路径统一——zip 下载完成后复用 ModpackImportService
        // 统一导入流程（解析 → 6 阶段主任务 → 解压/依赖下载/加载器/游戏文件/profile），
        // 消除 ModrinthAPI/CurseForgeAPI submitDownloadTasksFromPackage: 双轨逻辑。
        [self importDownloadedModpackPackage:packagePath];
    }];
    [task resume];
}

/// Task 5.10：在线整合包 zip 下载完成后的统一导入入口。
///   1. 用 ModpackImportService 解析 zip（Modrinth/CurseForge/MMC/MCBBS/Plain ZIP 均可识别）；
///   2. 解析失败走 finishDownloadWithErrorString:（任务标失败 + 弹窗 + 恢复 UI）；
///   3. 解析成功后收口 zip 下载任务（推满父 progress → KVO 标记任务完成 →
///      LauncherNavigationController 移除观察并恢复交互），再后台执行 importModpack:，
///      由 service 注册 6 阶段整合包主任务（autoPresentDetail 自动弹统一进度页）。
- (void)importDownloadedModpackPackage:(NSString *)packagePath {
    ModpackImportService *service = [[ModpackImportService alloc] init];
    [service resetCancelState];

    NSError *parseError = nil;
    NSDictionary *modpackInfo = [service parseModpackAtURL:[NSURL fileURLWithPath:packagePath] error:&parseError];
    if (!modpackInfo) {
        [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to parse modpack package: %@",
                                             parseError.localizedDescription ?: @"unknown error"]];
        return;
    }

    // 在线整合包补充 API 图标：zip 内无 icon 时回退列表图标
    // （ModpackInstallViewController 触发下载前已写入 tmp icon.png）
    NSMutableDictionary *info = [modpackInfo mutableCopy];
    NSString *archiveIcon = info[@"iconBase64"];
    if (![archiveIcon isKindOfClass:[NSString class]] || archiveIcon.length == 0) {
        NSString *tmpIconPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"icon.png"];
        NSData *iconData = [NSData dataWithContentsOfFile:tmpIconPath];
        if (iconData.length > 0) {
            info[@"iconBase64"] = [NSString stringWithFormat:@"data:image/png;base64,%@",
                                   [iconData base64EncodedStringWithOptions:0]];
        }
    }

    // 收口 zip 下载任务：推满父 progress（清掉 prepareForDownload 预留的 1 字节单位），
    // KVO 完成分支将 DownloadTaskItem 标记为完成，LauncherNavigationController 同步恢复交互；
    // 后续导入进度全部由 service 的整合包主任务（统一进度页）承接。
    if (self.progress.totalUnitCount > self.progress.completedUnitCount) {
        self.progress.completedUnitCount = self.progress.totalUnitCount;
    }

    // 后台执行统一导入（6 阶段进度上报 + autoPresentDetail 统一进度页）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSError *importError = nil;
        BOOL success = [service importModpack:info progress:nil error:&importError];
        if (success) {
            NSLog(@"[ModpackImport] Online modpack '%@' imported", info[@"name"]);
        } else {
            NSLog(@"[ModpackImport] Online modpack import failed: %@", importError.localizedDescription);
        }
        // 导入结束（成功/失败/取消）后清理 zip 临时文件
        [NSFileManager.defaultManager removeItemAtPath:packagePath error:nil];
        // 成功后刷新 profile 列表（与 Fabric/Forge 安装完成后的 ReloadProfileList 通知一致）
        if (success) {
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
        }
    });
}

#pragma mark - Utilities

- (void)prepareForDownload {
    // 清理单例会话上残留的上一次下载任务（前台会话单例模式下必须清理，
    // 否则上一次失败/取消的 task 残留在会话中可能影响新下载）。
    // 注意：不能 invalidate 单例会话（会破坏后续所有下载），只取消任务。
    NSString *oldTaskId = self.currentDownloadTaskItem.taskId;
    if (oldTaskId.length > 0) {
        [self.manager.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks,
                                                              NSArray<NSURLSessionUploadTask *> *uploadTasks,
                                                              NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
            for (NSURLSessionDownloadTask *dt in downloadTasks) {
                if ([dt.taskDescription isEqualToString:oldTaskId]) {
                    [dt cancel];
                }
            }
        }];
    }

    // Create a fake progress which is used to update completedUnitCount properly
    // (completedUnitCount does not update unless subprogress completes)
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = -1;

    self.progress = [NSProgress new];
    // Push 1 byte so it won't accidentally finish after downloading assets index
    self.progress.totalUnitCount = 1;
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];
    // 阶段5修复：重置失败文件列表（参照 FCL）
    [self.failedFiles removeAllObjects];
    // 阶段计数重置（stageReportingEnabled 由各入口自行设置：
    // downloadVersion: 置 YES，downloadModpackFromAPI: 置 NO）
    self.libTotalFileCount = 0;
    self.libCompletedFileCount = 0;
    self.assetTotalFileCount = 0;
    self.assetCompletedFileCount = 0;

    // 注册/更新到统一下载任务管理器
    [self registerOrUpdateTaskItem];

    // 监听总体进度
    if (!self.isObservingTaskProgress) {
        [self.progress addObserver:self
                        forKeyPath:@"fractionCompleted"
                           options:NSKeyValueObservingOptionInitial
                           context:(void *)@"MCDownloadProgressContext"];
        self.isObservingTaskProgress = YES;
        self.progressLastTime = 0;
        self.progressLastCompleted = 0;
    }
}

- (void)registerOrUpdateTaskItem {
    // 悬浮球已移除，始终注册到统一下载任务管理器，以便下载任务列表跟踪
    NSString *displayName = self.currentVersionId ?: (self.metadata[@"id"] ?: @"Minecraft");
    // Task218：来源标签收敛到 PLMirrorCenter（显示层专用 token；路由一律走候选链）。
    NSString *downloadSource = [PLMirrorCenter legacySourceTokenForType:PLMirrorResourceTypeGameFile];

    if (!self.currentDownloadTaskItem) {
        self.currentDownloadTaskItem = [[DownloadTaskManager sharedManager]
            registerTaskWithResourceType:DownloadTaskResourceTypeMinecraft
                            resourceName:displayName
                             displayName:displayName
                          downloadSource:downloadSource
                                 rawTask:self
                          supportsResume:NO
                                 iconURL:nil];
    } else {
        self.currentDownloadTaskItem.resourceName = displayName;
        self.currentDownloadTaskItem.displayName = displayName;
        self.currentDownloadTaskItem.downloadSource = downloadSource;
        self.currentDownloadTaskItem.rawTask = self;
        self.currentDownloadTaskItem.supportsResume = NO;
        self.currentDownloadTaskItem.state = DownloadTaskStatePending;
        self.currentDownloadTaskItem.progress = -1.0;
        self.currentDownloadTaskItem.errorInfo = nil;
    }
}

#pragma mark - Stage Reporting Helpers (redesign-download-ui Phase 3 Task 3.1)

/// 按下载目标路径分类计入阶段文件总量（库文件/资源文件；version JSON 不计入）
- (void)mc_recordStageFileStartedAtPath:(NSString *)path {
    if (!self.stageReportingEnabled) return;
    if ([path containsString:@"/libraries/"]) {
        self.libTotalFileCount++;
    } else if ([path containsString:@"/assets/"] || [path containsString:@"/resources/"]) {
        self.assetTotalFileCount++;
    } else {
        return; // versions/ 下的 version JSON、asset index 归属阶段1/4 的 JSON 下载，不计双维度
    }
    [self mc_reportStageFileCounts];
}

/// ★ Task259（清单 6）：文件级明细喂送（在实际开始下载的时机调用，
///   即 AFNetworking destination 回调——任务创建是同步批量预创建的，
///   创建时机 ≠ 下载时机，喂错时机所有文件名会瞬间刷成队尾文件）。
///   病历：统一进度页详情区渲染 stage.message，而本任务所有阶段上报
///   都传 message:nil；下载中心 cell 只读聚合百分比——"安装页没有
///   显示详细进度的地方 / 下载页只显示百分比，没有显示文件详细"。
- (void)mc_reportCurrentFileAtPath:(NSString *)path altName:(NSString *)altName {
    if (!self.stageReportingEnabled || !self.currentDownloadTaskItem) return;
    NSString *ame259_fileName = altName.length > 0 ? altName : path.lastPathComponent;
    self.currentDownloadTaskItem.currentFile = ame259_fileName;
    DownloadTaskManager *ame259_manager = [DownloadTaskManager sharedManager];
    NSString *ame259_taskId = self.currentDownloadTaskItem.taskId;
    NSUInteger ame259_stageIndex;
    if ([path containsString:@"/libraries/"]) {
        ame259_stageIndex = kMCStageIndexLibraries;
    } else if ([path containsString:@"/assets/"] || [path containsString:@"/resources/"]) {
        ame259_stageIndex = kMCStageIndexAssets;
    } else if ([path containsString:@".json"]) {
        // version JSON / asset index：归属阶段1（版本 JSON）
        ame259_stageIndex = kMCStageIndexVersionJSON;
    } else {
        return;
    }
    [ame259_manager updateTaskWithId:ame259_taskId
                        stageAtIndex:ame259_stageIndex
                            progress:-1
                             message:ame259_fileName];
}

/// 文件到达终态（跳过/成功/最终失败）时计入阶段文件完成数
- (void)mc_recordStageFileFinishedAtPath:(NSString *)path {
    if (!self.stageReportingEnabled) return;
    if ([path containsString:@"/libraries/"]) {
        self.libCompletedFileCount++;
    } else if ([path containsString:@"/assets/"] || [path containsString:@"/resources/"]) {
        self.assetCompletedFileCount++;
    } else {
        return;
    }
    [self mc_reportStageFileCounts];
}

/// 上报库/资源阶段的双维度文件计数
- (void)mc_reportStageFileCounts {
    if (!self.stageReportingEnabled || !self.currentDownloadTaskItem) return;
    NSString *taskId = self.currentDownloadTaskItem.taskId;
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    [manager updateTaskWithId:taskId
                stageAtIndex:kMCStageIndexLibraries
                   fileCount:self.libCompletedFileCount
               totalFileCount:self.libTotalFileCount];
    [manager updateTaskWithId:taskId
                stageAtIndex:kMCStageIndexAssets
                   fileCount:self.assetCompletedFileCount
               totalFileCount:self.assetTotalFileCount];
}

/// 收敛全部阶段状态：error 为 nil 时全部标 Completed（验证阶段先 Running 再 Completed）；
/// 非 nil 时当前阶段标 Failed 并带上错误信息，其后阶段保持 Pending。
- (void)mc_finishAllStagesWithFailure:(nullable NSString *)error {
    if (!self.stageReportingEnabled || !self.currentDownloadTaskItem) return;
    NSString *taskId = self.currentDownloadTaskItem.taskId;
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    NSInteger idx = self.currentDownloadTaskItem.currentStageIndex;

    if (error != nil) {
        // 失败：当前阶段 Failed + message；已完成阶段保持不变
        if (idx >= 0 && (NSUInteger)idx < self.currentDownloadTaskItem.stages.count) {
            [manager updateTaskWithId:taskId
                         stageAtIndex:(NSUInteger)idx
                               status:PLTaskStageStatusFailed];
            [manager updateTaskWithId:taskId
                         stageAtIndex:(NSUInteger)idx
                              progress:0
                                message:error];
        }
        return;
    }

    // 成功：未完成阶段全部标记完成（下载客户端保持 Skipped）
    NSArray<PLTaskStage *> *stages = self.currentDownloadTaskItem.stages;
    for (NSUInteger i = 0; i < stages.count; i++) {
        if (stages[i].status == PLTaskStageStatusPending || stages[i].status == PLTaskStageStatusRunning) {
            [manager updateTaskWithId:taskId stageAtIndex:i status:PLTaskStageStatusCompleted];
        }
    }
    // 验证完整性：SHA1 校验已随每个文件完成，快速推进
    // Task187（巨魔装机“卡在验证完整性”取证 + 看门狗）：本阶段设计上
    // 瞬时完成（SHA1 已内嵌在每个文件的下载完成回调里），但用户报告
    // 启动时界面长时间停在“验证完整性”。两道防线：
    //   1) 入场锚点（含自 downloadVersion: 起的耗时）——装机日志可定位实际卡点；
    //   2) 30s 看门狗：阶段仍 Running 则强制完成（逐文件 SHA1 已保证完整性，
    //      本阶段只是展示层收尾，强推不会引入假阳性）。
    {
        CFTimeInterval ame187_elapsed = 0.0;
        if (self.ame187_taskStartTs > 0.0) {
            ame187_elapsed = CFAbsoluteTimeGetCurrent() - self.ame187_taskStartTs;
        }
        NSLog(@"[MCDL] Task187: verify stage entered (elapsed %.1fs since downloadVersion:)", (double)ame187_elapsed);
    }
    [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexVerify status:PLTaskStageStatusRunning];
    [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexVerify progress:1 message:nil];
    [manager updateTaskWithId:taskId stageAtIndex:kMCStageIndexVerify status:PLTaskStageStatusCompleted];
    [manager updateTaskWithId:taskId currentStageIndex:kMCStageIndexVerify];
    self.stageReportingEnabled = NO;
    // Task187 看门狗：30s 后若“验证完整性”仍 Running（任何上游路径把它留在
    // Running 而没走到上面的完成链，含下载中心详情页的陈旧展示），强制收尾 + 留痕。
    {
        NSString *ame187_taskId = [taskId copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DownloadTaskItem *ame187_item = [[DownloadTaskManager sharedManager] taskWithId:ame187_taskId];
            if (ame187_item != nil &&
                ame187_item.stages.count > kMCStageIndexVerify &&
                ame187_item.stages[kMCStageIndexVerify].status == PLTaskStageStatusRunning) {
                NSLog(@"[MCDL] Task187: verify stage watchdog fired (Running >30s -- force-completed; per-file SHA1 already guarantees integrity)");
                [[DownloadTaskManager sharedManager] updateTaskWithId:ame187_taskId stageAtIndex:kMCStageIndexVerify status:PLTaskStageStatusCompleted];
            }
        });
    }
}

- (void)cancel {
    // 取消根 NSProgress：各子任务进度被级联取消，KVO 的 cancelled 分支按既有路径收尾
    [self.progress cancel];
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    // 阶段上报：整流程失败时把当前阶段标记为 Failed
    if (self.stageReportingEnabled) {
        [self mc_finishAllStagesWithFailure:error ?: localize(@"i18n_str_448", nil)];
    }
    if (self.currentDownloadTaskItem && self.currentDownloadTaskItem.state != DownloadTaskStateCancelled) {
        NSError *err = [NSError errorWithDomain:@"MinecraftResourceDownloadTask"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey: error ?: localize(@"i18n_str_448", nil)}];
        [[DownloadTaskManager sharedManager] setTaskWithId:self.currentDownloadTaskItem.taskId
                                          completedWithError:err];
    }

    [self.progress cancel];

    // 取消属于当前任务的所有后台下载任务，避免失败后继续浪费流量
    NSString *taskId = self.currentDownloadTaskItem.taskId;
    [self.manager.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks,
                                                          NSArray<NSURLSessionUploadTask *> *uploadTasks,
                                                          NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
        for (NSURLSessionDownloadTask *downloadTask in downloadTasks) {
            if (taskId.length > 0 && [downloadTask.taskDescription isEqualToString:taskId]) {
                [downloadTask cancel];
            }
        }
    }];

    showDialog(localize(@"Error", nil), error);
    self.handleError();
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);

    // 阶段5修复（参照 FCL）：单文件下载失败不再取消整批任务。
    //
    // 之前调用 finishDownloadWithErrorString: 会：
    //   1. 取消所有同 taskId 的下载任务（正在下载的其他文件全部被取消）
    //   2. 弹出错误对话框中断整个下载流程
    //   3. 导致整合包"下载不完全"——用户报告"下载的模组名称不对、下载不完全"
    //
    // FCL 做法：单文件失败记录到 failedFiles 数组，其他文件继续下载，
    // 最终汇总报告给用户。这与 FCL "单文件失败不影响其他文件"的设计完全一致。
    //
    // 注意：仅整合包多文件下载场景适用此容错策略。单文件版本下载（downloadVersion:）
    // 不应进入此方法（其 completionHandler 已有自己的错误处理路径），但若意外进入，
    // 由于 failedFiles.count == 0 时 finishDownloadWithErrorString: 不会被触发，
    // 行为与原逻辑保持兼容。
    @synchronized(self.failedFiles) {
        [self.failedFiles addObject:@{
            @"name": file ?: @"unknown",
            @"error": error.localizedDescription ?: @"unknown error"
        }];
    }
    NSLog(@"[MCDL] File '%@' added to failedFiles (total failed: %lu), other downloads will continue",
          file, (unsigned long)self.failedFiles.count);
}

#pragma mark - Download Task Manager Reporting

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if (context != (void *)@"MCDownloadProgressContext") {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }

    if (![keyPath isEqualToString:@"fractionCompleted"] || !self.currentDownloadTaskItem) return;

    NSProgress *progress = self.progress;
    double fraction = progress.fractionCompleted;
    int64_t total = progress.totalUnitCount;
    int64_t completed = (int64_t)(total * fraction);

    // 速度 / 预计剩余时间（每秒计算一次）
    struct timeval tv;
    gettimeofday(&tv, NULL);
    NSTimeInterval now = tv.tv_sec + tv.tv_usec / 1000000.0;
    double speed = 0.0;
    NSTimeInterval eta = 0.0;

    if (self.progressLastTime > 0 && now > self.progressLastTime) {
        int64_t delta = completed - self.progressLastCompleted;
        NSTimeInterval timeDelta = now - self.progressLastTime;
        if (timeDelta > 0) {
            speed = (double)delta / timeDelta;
            if (speed > 0 && total > completed) {
                eta = (total - completed) / speed;
            }
        }
    }

    if (self.progressLastTime == 0 || now >= self.progressLastTime + 1.0) {
        self.progressLastTime = now;
        self.progressLastCompleted = completed;
    }

    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    [manager updateTaskWithId:self.currentDownloadTaskItem.taskId
                     progress:fraction
                   totalBytes:total
              downloadedBytes:completed];
    [manager updateTaskWithId:self.currentDownloadTaskItem.taskId
                        speed:speed
       estimatedTimeRemaining:eta];

    // 阶段上报：并发下载的库/资源阶段共享全局速率（progress 为不确定模式，靠文件计数推进）
    if (self.stageReportingEnabled) {
        [manager updateTaskWithId:self.currentDownloadTaskItem.taskId
                    stageAtIndex:kMCStageIndexLibraries
                            rate:speed];
        [manager updateTaskWithId:self.currentDownloadTaskItem.taskId
                    stageAtIndex:kMCStageIndexAssets
                            rate:speed];
    }

    if (progress.cancelled) {
        if (self.currentDownloadTaskItem.state != DownloadTaskStateCancelled &&
            self.currentDownloadTaskItem.state != DownloadTaskStateCompleted &&
            self.currentDownloadTaskItem.state != DownloadTaskStateFailed) {
            [manager setTaskWithId:self.currentDownloadTaskItem.taskId state:DownloadTaskStateCancelled];
        }
        [self removeProgressObserver];
        return;
    }

    if (progress.finished) {
        // 阶段上报：收尾——库/资源阶段完成，验证完整性阶段快速推进后完成
        //（SHA1 校验内嵌于每个文件的下载完成回调中，此处仅收敛阶段状态）
        if (self.stageReportingEnabled) {
            [self mc_finishAllStagesWithFailure:nil];
        }
        if (self.currentDownloadTaskItem.state != DownloadTaskStateCompleted &&
            self.currentDownloadTaskItem.state != DownloadTaskStateFailed &&
            self.currentDownloadTaskItem.state != DownloadTaskStateCancelled) {
            // 阶段5修复（参照 FCL DownloadList.finishAll）：下载流程结束后，
            // 若有失败文件，不能简单标记为"成功完成"——这会让用户以为整合包完整。
            // 应将失败文件信息汇总为 NSError，让 DownloadTaskManager 显示为失败状态，
            // 用户可在下载任务列表中看到具体缺失的文件。
            NSArray<NSDictionary *> *failedSnapshot = [self.failedFiles copy];
            if (failedSnapshot.count > 0) {
                NSMutableString *msg = [NSMutableString stringWithFormat:localize(@"i18n_str_449", nil), (unsigned long)failedSnapshot.count];
                NSUInteger showCount = MIN(failedSnapshot.count, (NSUInteger)5);
                for (NSUInteger k = 0; k < showCount; k++) {
                    NSString *n = failedSnapshot[k][@"name"];
                    [msg appendFormat:@"\n  • %@", n ?: @"(unknown)"];
                }
                if (failedSnapshot.count > showCount) {
                    [msg appendFormat:localize(@"i18n_str_450", nil), (unsigned long)failedSnapshot.count];
                }
                NSLog(@"[MCDL] %@", msg);
                NSError *partialError = [NSError errorWithDomain:@"MinecraftResourceDownloadTask"
                                                            code:2
                                                        userInfo:@{
                                                            NSLocalizedDescriptionKey: [msg copy],
                                                            @"failedFiles": failedSnapshot
                                                        }];
                [manager setTaskWithId:self.currentDownloadTaskItem.taskId completedWithError:partialError];
            } else {
                [manager setTaskWithId:self.currentDownloadTaskItem.taskId completedWithError:nil];
            }
        }
        [self removeProgressObserver];
    }
}

- (void)removeProgressObserver {
    if (self.isObservingTaskProgress) {
        @try {
            [self.progress removeObserver:self forKeyPath:@"fractionCompleted"];
        } @catch (NSException *exception) {
            // ignore
        }
        self.isObservingTaskProgress = NO;
    }
}

// 关键修改：移除本地账户下载限制和提示
- (BOOL)checkAccessWithDialog:(BOOL)show {
    // 无条件允许所有下载请求
    return YES;
}

// Check SHA of the file
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        // When sha = skip, only check for file existence
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    if (!check || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@",
          (check ? @"passed" : @"failed"), 
          (altName ? altName : path.lastPathComponent),
          (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        // 不仅检查文件存在性，还要检查文件大小 > 0（防止空文件被误判为已下载）
        // 修复：原版安装时若文件被错误创建为 0 字节，会被视为已下载，
        //   导致 totalUnitCount 从 1 变 0，触发强制完成（0 字节下载）
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) return NO;
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        unsigned long long fileSize = [attrs fileSize];
        return fileSize > 0;
    }
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

@end
