//
//  DataTransferService.m
//  Amethyst
//
//  Task217：数据导出/导入实现。详见 DataTransferService.h 头注释。
//
//  实现要点：
//  - 压缩/解压走随包 UnzipKit（ModpackExport/ImportService 同款链路）；
//    逐文件 writeData 的峰值内存 = 最大单文件（MC 资产无 GB 级单文件，
//    实测安全）。
//  - 导出文件名：prisma-backup-<yyyyMMdd-HHmmss>.zip。
//  - 导入合并语义：同名文件覆盖、其余保留（新容器多为空，冲突罕见；
//    覆盖 = "以备份为准"的恢复语义）。
//  - zip-slip 防御：解压前 performOnFilesInArchive 全量校验条目路径，
//    含 ".." / 绝对路径 / nil 的一律拒绝整个备份（宁可不恢复也不越界写）。
//

#import "DataTransferService.h"
#import "external/UnzipKit/UZKArchive.h"
#import "utils.h"
#import "LauncherPreferences.h"   // getPrefObject（Task224 分区口径读当前实例名）
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
// Task224：自研 zip 写器直接使用 zlib（deflate/crc32）。libz 已随 UnzipKit
// 加载（其 load commands 链接 /usr/lib/libz.1.dylib），符号经 dlsym 解析，
// 避免本轮修改链接脚本（TouchControllerBridge 的 dlsym 先例）。zlib.h 仅
// 提供 z_stream 与常量定义，代码不直接调用其声明函数，不产生链接期符号。
#include <zlib.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

@interface DataTransferService () <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *presenter;
/// 导出流程的文件选择器正在等待落点（区分导出/导入两条 delegate 回调——
/// 导出落点文件名同样以 .zip 结尾，不能靠扩展名判流）。
@property (nonatomic, assign) BOOL awaitingExportDestination;
@end

/// Task224 导出条目：worker 与写线程之间的交接单元（字段先填好，
/// 全内存屏障后置 ready——写线程仅在 ready 后读取结果）。
@interface Ame224ExportEntry : NSObject
@property (nonatomic, copy) NSString *rel;                 // zip 条目名（相对 POJAV_HOME，与旧版一致）
@property (nonatomic, copy) NSString *abs;                 // 源文件绝对路径
@property (nonatomic, assign) unsigned long long usize;    // stat 尺寸
@property (nonatomic, assign) uint16_t dosTime;            // 条目时间戳（DOS 格式）
@property (nonatomic, assign) uint16_t dosDate;
@property (nonatomic, assign) BOOL serialStream;           // 大文件：写线程流式压缩（data descriptor 收尾）
@property (nonatomic, strong) NSData *payload;             // worker 压缩产物（小文件 deflate）
@property (nonatomic, assign) uint32_t crc;                // worker 预算的 CRC32
@property (nonatomic, assign) unsigned long long csize;    // 实际压缩尺寸
@property (nonatomic, assign) int64_t budgetUnits;         // 领先量预算单位数（1MB/单位）
@property (nonatomic, assign) BOOL skipped;                // 源文件不可读/中途消失：跳过
@property (nonatomic, assign) BOOL ready;                  // worker 结果就绪（或已判 skipped）
@property (nonatomic, assign) uint64_t headerOffset;       // local header 落点（中央目录用）
@end

@implementation Ame224ExportEntry
@end

/// Task224 流水线共享态：数值计数用 C 结构体 + __sync 原子（多 worker 并发），
/// 字符串字段经 atomic 属性上锁（写线程写、10Hz tick 线程读）。
@interface Ame224PipelineCounters : NSObject
@property (nonatomic, copy) NSString *currentFile;   // 写线程当前条目（阶段详情文案）
@property (nonatomic, copy) NSString *failMessage;   // 首个失败原因（失败路径展示）
@end

@implementation Ame224PipelineCounters
@end

/// Task224 速率跟踪：10Hz tick 队列串行访问（无需加锁）。
@interface Ame224SpeedTracker : NSObject
@property (nonatomic, assign) double lastTime;
@property (nonatomic, assign) unsigned long long lastBytes;
@property (nonatomic, assign) double speed;   // EMA 平滑后的字节速率
@end

@implementation Ame224SpeedTracker
@end

@implementation DataTransferService

+ (instancetype)sharedService {
    static DataTransferService *ame217_shared = nil;
    static dispatch_once_t ame217_once;
    dispatch_once(&ame217_once, ^{
        ame217_shared = [[DataTransferService alloc] init];
    });
    return ame217_shared;
}

#pragma mark - Helpers

/// 导出时剔除的运行期垃圾（不构成"数据"）：滚动日志 / JVM 崩溃转储 /
/// auto 渲染器会话哨兵（Task217）。
- (BOOL)ame217_shouldSkipExportEntry:(NSString *)fileName {
    if (fileName.length == 0) return YES;
    if ([fileName hasPrefix:@"latestlog"]) return YES;
    if ([fileName hasPrefix:@"hs_err_pid"]) return YES;
    if ([fileName isEqualToString:@".ame217_session"]) return YES;
    return NO;
}

- (UIAlertController *)ame217_progressAlertWithTitle:(NSString *)title {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *indicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    indicator.translatesAutoresizingMaskIntoConstraints = NO;
    [indicator startAnimating];
    [alert.view addSubview:indicator];
    [NSLayoutConstraint activateConstraints:@[
        [indicator.centerXAnchor constraintEqualToAnchor:alert.view.centerXAnchor],
        [indicator.bottomAnchor constraintEqualToAnchor:alert.view.bottomAnchor constant:-12],
    ]];
    alert.view.userInteractionEnabled = NO;
    return alert;
}

#pragma mark - Export（Task219 重做：预检摘要 + 压缩等级选择 + 进度条详情）

/// 导出前的扫描条目（Task219）：快速预检文件数与总量，供等级选择弹窗展示。
- (void)exportDataFromViewController:(UIViewController *)presenter {
    self.presenter = presenter;
    NSString *home = @(getenv("POJAV_HOME"));
    if (home.length == 0) {
        [self ame217_showToastOrAlert:localize(@"ame217.export.failed", @"Export failed: data directory unavailable")];
        return;
    }

    // 后台快速预检（只 stat 不读内容；GB 级目录在 SSD 上秒级完成）
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:home];
        NSUInteger ame219_files = 0;
        unsigned long long ame219_bytes = 0;
        NSString *rel;
        while ((rel = [enumerator nextObject])) {
            if ([self ame217_shouldSkipExportEntry:rel.lastPathComponent]) {
                [enumerator skipDescendants];
                continue;
            }
            NSString *abs = [home stringByAppendingPathComponent:rel];
            BOOL isDir = NO;
            NSDictionary *attrs = nil;
            if ([fm fileExistsAtPath:abs isDirectory:&isDir] && !isDir) {
                attrs = [fm attributesOfItemAtPath:abs error:nil];
                ame219_files++;
                ame219_bytes += [attrs fileSize];
            }
        }
        NSLog(@"[DataTransfer] Task219 export preflight: %lu files, %.1f MB",
              (unsigned long)ame219_files, ame219_bytes / 1048576.0);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self ame219_showExportLevelSheetWithFiles:ame219_files
                                                bytes:ame219_bytes
                                             presenter:presenter];
        });
    });
}

/// 压缩等级选择（Task219 用户指令："让用户选择压缩等级"）+ 导出摘要。
/// 等级映射 UnzipKit compressionMethod：None=0（仅打包，最快）/ Default=-1
///（标准）/ Best=9（最小体积，最慢）。
- (void)ame219_showExportLevelSheetWithFiles:(NSUInteger)fileCount
                                      bytes:(unsigned long long)totalBytes
                                   presenter:(UIViewController *)presenter {
    if (fileCount == 0) {
        [self ame217_showToastOrAlert:localize(@"ame219.export.empty", @"No data to export")];
        return;
    }
    NSString *sizeText = [NSByteCountFormatter stringFromByteCount:totalBytes
                                                         countStyle:NSByteCountFormatterCountStyleFile];
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:localize(@"ame219.export.pick_level", nil)
                         message:[NSString stringWithFormat:
                             localize(@"ame219.export.summary", nil),
                             (unsigned long)fileCount, sizeText]
                  preferredStyle:UIAlertControllerStyleActionSheet];
    void (^ame219_add)(NSString *title, UZKCompressionMethod method) = ^(NSString *title, UZKCompressionMethod method) {
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction * _Nonnull action) {
            [self ame219_runExportWithCompression:method];
        }]];
    };
    ame219_add(localize(@"ame219.export.level_none", nil), UZKCompressionMethodNone);
    ame219_add(localize(@"ame219.export.level_default", nil), UZKCompressionMethodDefault);
    ame219_add(localize(@"ame219.export.level_best", nil), UZKCompressionMethodBest);
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    sheet.popoverPresentationController.sourceView = presenter.view;
    sheet.popoverPresentationController.sourceRect = CGRectMake(presenter.view.bounds.size.width / 2.0,
                                                                presenter.view.bounds.size.height / 2.0, 1, 1);
    [presenter presentViewController:sheet animated:YES completion:nil];
}

/// 带进度详情的导出执行（Task219 用户指令："添加进度条等详细信息"）。
/// 进度弹窗 = 总进度条 + "正在压缩 i/N：文件名" + 已写 MB 计数。
- (void)ame219_runExportWithCompression:(UZKCompressionMethod)method {
    NSString *home = @(getenv("POJAV_HOME"));
    if (home.length == 0) {
        [self ame217_showToastOrAlert:localize(@"ame217.export.failed", @"Export failed: data directory unavailable")];
        return;
    }
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *stamp = [fmt stringFromDate:[NSDate date]];
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"prisma-backup-%@.zip", stamp]];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

    // 进度弹窗（进度条 + 文件明细两行；userInteractionEnabled=NO 防误触关闭）
    UIAlertController *progress = [UIAlertController
        alertControllerWithTitle:localize(@"ame217.export.progress", @"Exporting data backup…")
                         message:@"\n\n\n"
                  preferredStyle:UIAlertControllerStyleAlert];
    UIProgressView *bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *fileLabel = [[UILabel alloc] init];
    fileLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    fileLabel.textColor = [UIColor secondaryLabelColor];
    fileLabel.numberOfLines = 2;
    fileLabel.textAlignment = NSTextAlignmentCenter;
    fileLabel.translatesAutoresizingMaskIntoConstraints = NO;
    fileLabel.text = @" ";
    [progress.view addSubview:bar];
    [progress.view addSubview:fileLabel];
    [NSLayoutConstraint activateConstraints:@[
        [bar.leadingAnchor constraintEqualToAnchor:progress.view.leadingAnchor constant:24],
        [bar.trailingAnchor constraintEqualToAnchor:progress.view.trailingAnchor constant:-24],
        [bar.topAnchor constraintEqualToAnchor:progress.view.topAnchor constant:86],
        [fileLabel.leadingAnchor constraintEqualToAnchor:progress.view.leadingAnchor constant:24],
        [fileLabel.trailingAnchor constraintEqualToAnchor:progress.view.trailingAnchor constant:-24],
        [fileLabel.topAnchor constraintEqualToAnchor:bar.bottomAnchor constant:10],
    ]];
    progress.view.userInteractionEnabled = NO;
    [self.presenter presentViewController:progress animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:tmpPath error:&err];
        __block BOOL ok = (archive != nil);
        __block NSString *failMsg = err.localizedDescription;

        NSInteger written = 0;
        unsigned long long writtenBytes = 0;
        NSDate *ame219_lastUi = [NSDate distantPast];
        if (ok) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *root = [home copy];
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
            NSMutableArray<NSString *> *collected = [NSMutableArray array];
            NSString *rel;
            while ((rel = [enumerator nextObject])) {
                if ([self ame217_shouldSkipExportEntry:rel.lastPathComponent]) {
                    [enumerator skipDescendants];
                    continue;
                }
                [collected addObject:rel];
            }
            NSUInteger ame219_total = collected.count;
            for (NSString *relPath in collected) {
                NSString *abs = [root stringByAppendingPathComponent:relPath];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:abs isDirectory:&isDir] || isDir) continue;
                NSData *data = [NSData dataWithContentsOfFile:abs];
                if (data) {
                    // Task219：压缩等级透传（UZK 扩展 writeData 变体；
                    // fileDate 传 nil 走归档默认（保留条目时间戳语义不变））
                    if (![archive writeData:data filePath:relPath fileDate:nil
                            compressionMethod:method password:nil overwrite:YES error:&err]) {
                        ok = NO;
                        failMsg = err.localizedDescription;
                        break;
                    }
                    written++;
                    writtenBytes += data.length;
                }
                // 进度 UI 节流（150ms；主线程串行落地）
                NSDate *ame219_now = [NSDate date];
                if ([ame219_now timeIntervalSinceDate:ame219_lastUi] > 0.15) {
                    ame219_lastUi = ame219_now;
                    NSString *ame219_fileName = relPath.lastPathComponent;
                    NSUInteger ame219_done = written;
                    unsigned long long ame219_bytes = writtenBytes;
                    NSUInteger ame219_tot = ame219_total;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        bar.progress = (ame219_tot > 0) ? ((float)ame219_done / (float)ame219_tot) : 0.0f;
                        fileLabel.text = [NSString stringWithFormat:
                            localize(@"ame219.export.progress_file", @"Compressing %lu/%lu: %@\n%@ written"),
                            (unsigned long)ame219_done, (unsigned long)ame219_tot, ame219_fileName,
                            [NSByteCountFormatter stringFromByteCount:ame219_bytes
                                          countStyle:NSByteCountFormatterCountStyleFile]];
                    });
                }
            }
            // 收尾刷满进度条
            dispatch_async(dispatch_get_main_queue(), ^{
                bar.progress = 1.0f;
            });
            NSLog(@"[DataTransfer] Task219: export wrote %ld files (level=%ld) -> %@ (%@)",
                  (long)written, (long)method, tmpPath.lastPathComponent, ok ? @"ok" : @"FAILED");
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                if (!ok) {
                    NSString *msg = [NSString stringWithFormat:
                        localize(@"ame217.export.failed", @"Export failed: %@"), failMsg ?: @"?"];
                    [self ame217_showToastOrAlert:msg];
                    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
                    return;
                }
                // 导出完成：交给系统文件选择器定落点（Task219 用户指令：
                // "让用户选择导出目录"——Files 面板自由选目录/改名，move 语义
                // 不占双份空间）。
                NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];
                UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                    initForExportingURLs:@[tmpURL] asCopy:NO];
                picker.delegate = self;
                picker.modalPresentationStyle = UIModalPresentationFormSheet;
                self.awaitingExportDestination = YES;
                [self.presenter presentViewController:picker animated:YES completion:nil];
            }];
        });
    });
}

#pragma mark - Import

- (void)importDataFromViewController:(UIViewController *)presenter {
    self.presenter = presenter;
    UTType *zipType = [UTType typeWithIdentifier:@"public.zip-archive"];
    if (!zipType) {
        zipType = [UTType typeWithIdentifier:@"com.pkware.zip-archive"];
    }
    // 部署目标 14.0：initForOpeningContentTypes: 无条件可用（asCopy:YES =
    // 选中即拷贝到临时目录，免安全域时序坑）。
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[zipType] asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [presenter presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    NSURL *picked = urls.firstObject;

    if (self.awaitingExportDestination) {
        // 导出流程收尾：tmp zip 已被移动到用户选择的位置。展示成功提示并
        // 清理等待态（tmp 文件已不在原位，无需删除）。
        self.awaitingExportDestination = NO;
        [self ame217_showToastOrAlert:[NSString stringWithFormat:
            localize(@"ame217.export.done", nil), picked.lastPathComponent ?: @"backup.zip"]];
        return;
    }

    // 导入路径：asCopy=YES 已把安全域文件物化到本地临时目录。
    [self ame217_performImportFromZipAtURL:picked];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // 用户取消：若导出流程的 tmp zip 仍在（move 未发生）则清理。
    self.awaitingExportDestination = NO;
    for (NSString *entry in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil]) {
        if ([entry hasPrefix:@"prisma-backup-"] && [entry hasSuffix:@".zip"]) {
            [[NSFileManager defaultManager] removeItemAtPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:entry] error:nil];
        }
    }
}

#pragma mark - Import implementation

- (void)ame217_performImportFromZipAtURL:(NSURL *)zipURL {
    UIAlertController *progress = [self ame217_progressAlertWithTitle:
        localize(@"ame217.import.progress", @"Importing data backup…")];
    [self.presenter presentViewController:progress animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *home = @(getenv("POJAV_HOME"));
        NSError *err = nil;
        __block NSString *failMsg = nil;

        // staging：解压中转目录（先解压再合并，避免半写状态直接进 POJAV_HOME）
        NSString *staging = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"prisma-restore-%@", [[NSUUID UUID] UUIDString]]];
        [fm removeItemAtPath:staging error:nil];
        [fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil];

        UZKArchive *archive = [[UZKArchive alloc] initWithURL:zipURL error:&err];
        if (!archive) {
            failMsg = err.localizedDescription;
        } else {
            // zip-slip 净化：全量条目路径校验（".." / 绝对路径 / 空名）。
            __block BOOL pathOk = YES;
            [archive performOnFilesInArchive:^(UZKFileInfo *fileInfo, BOOL *stop) {
                NSString *p = fileInfo.filename;
                if (p.length == 0 || [p hasPrefix:@"/"] || [p containsString:@"../"] || [p isEqualToString:@".."]) {
                    pathOk = NO;
                    *stop = YES;
                }
            } error:nil];
            if (!pathOk) {
                failMsg = @"unsafe entry path in archive";
            } else if (![archive extractFilesTo:staging overwrite:YES error:&err]) {
                failMsg = err.localizedDescription;
            }
        }

        NSInteger restored = 0;
        if (!failMsg) {
            // 逐文件合并回 POJAV_HOME（同名覆盖 = 恢复语义）。
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:staging];
            NSString *rel;
            while ((rel = [enumerator nextObject])) {
                NSString *srcAbs = [staging stringByAppendingPathComponent:rel];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:srcAbs isDirectory:&isDir]) continue;
                NSString *dstAbs = [home stringByAppendingPathComponent:rel];
                if (isDir) {
                    if (![fm fileExistsAtPath:dstAbs]) {
                        [fm createDirectoryAtPath:dstAbs withIntermediateDirectories:YES attributes:nil error:nil];
                    }
                    continue;
                }
                NSError *mkErr = nil;
                NSString *dstDir = [dstAbs stringByDeletingLastPathComponent];
                if (![fm fileExistsAtPath:dstDir]) {
                    [fm createDirectoryAtPath:dstDir withIntermediateDirectories:YES attributes:nil error:&mkErr];
                }
                [fm removeItemAtPath:dstAbs error:nil];
                if (![fm moveItemAtPath:srcAbs toPath:dstAbs error:&err]) {
                    failMsg = err.localizedDescription;
                    break;
                }
                restored++;
            }
        }

        [fm removeItemAtPath:staging error:nil];
        NSLog(@"[DataTransfer] Task217: import restored %ld files%@",
              (long)restored, failMsg ? [NSString stringWithFormat:@" (FAILED: %@)", failMsg] : @" (ok)");

        dispatch_async(dispatch_get_main_queue(), ^{
            [progress dismissViewControllerAnimated:YES completion:^{
                if (failMsg) {
                    NSString *msg = [NSString stringWithFormat:
                        localize(@"ame217.import.failed", @"Import failed: %@"), failMsg];
                    [self ame217_showToastOrAlert:msg];
                    return;
                }
                [self ame217_showToastOrAlert:
                    localize(@"ame217.import.done", @"Data restored. Please restart the launcher for it to take effect.")];
            }];
        });
    });
}

#pragma mark - Alert helpers

- (void)ame217_showToastOrAlert:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = self.presenter;
        if (presenter) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                           message:message
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", @"OK")
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil]];
            [presenter presentViewController:alert animated:YES completion:nil];
        } else {
            NSLog(@"[DataTransfer] Task217: %@", message);
        }
    });
}

#pragma mark - Task224：分区选择导出 + 并行压缩 zip 写器（清单第 12/13 项二轮根修）

NSString * const Ame224SectionIdWorlds = @"worlds";
NSString * const Ame224SectionIdResourcePacks = @"resourcepacks";
NSString * const Ame224SectionIdMods = @"mods";
NSString * const Ame224SectionIdScreenshots = @"screenshots";
NSString * const Ame224SectionIdServers = @"servers";
NSString * const Ame224SectionIdInstance = @"instance";
NSString * const Ame224SectionIdLauncher = @"launcher";
NSString * const Ame224SectionIdGameFiles = @"gamefiles";

/// 流水线常量：4MB 读块（热循环每块一次 read，替代旧 64KB 级碎读）；
/// 3 个压缩 worker（A 系 6 核留余量给 UI/IO）；> 64MB 的文件不走
/// 并行压缩（改由写线程流式处理，内存上界 = 4MB 入 + 4MB 出）；
/// worker 领先量预算 192MB（结果缓冲驻留内存上界）。
static const NSUInteger Ame224ReadChunkBytes = 4u * 1024u * 1024u;
static const NSUInteger Ame224ParallelFileCap = 64u * 1024u * 1024u;
static const NSUInteger Ame224WorkerCount = 3;
static const NSUInteger Ame224BudgetUnits = 192;

typedef struct {
    volatile int64_t nextIndex;    // worker 领号（原子 fetch_add）
    volatile int64_t bytesDone;    // 写线程累计，tick 原子读
    volatile int64_t filesDone;
    volatile int32_t failed;       // 任一 worker/写线程失败
    volatile int32_t phase;        // 0 collect / 1 pipeline / 2 finalize
} Ame224PipelineState;

// zlib 函数指针（dlsym 解析，签名对齐 zlib.h）
typedef int (*ame224_z_deflateInit2_fn)(z_streamp, int, int, int, int, int, const char *, int);
typedef int (*ame224_z_deflate_fn)(z_streamp, int);
typedef int (*ame224_z_deflateEnd_fn)(z_streamp);
typedef unsigned long (*ame224_z_crc32_fn)(unsigned long, const Bytef *, unsigned int);
typedef unsigned long (*ame224_z_deflateBound_fn)(z_streamp, unsigned long);

static ame224_z_deflateInit2_fn ame224_z_deflateInit2_ = NULL;
static ame224_z_deflate_fn ame224_z_deflate = NULL;
static ame224_z_deflateEnd_fn ame224_z_deflateEnd = NULL;
static ame224_z_crc32_fn ame224_z_crc32 = NULL;
static ame224_z_deflateBound_fn ame224_z_deflateBound = NULL;

static BOOL ame224_zlibResolve(void) {
    static dispatch_once_t ame224_once;
    static BOOL ame224_ok = NO;
    dispatch_once(&ame224_once, ^{
        ame224_z_deflateInit2_ = (ame224_z_deflateInit2_fn)dlsym(RTLD_DEFAULT, "deflateInit2_");
        ame224_z_deflate = (ame224_z_deflate_fn)dlsym(RTLD_DEFAULT, "deflate");
        ame224_z_deflateEnd = (ame224_z_deflateEnd_fn)dlsym(RTLD_DEFAULT, "deflateEnd");
        ame224_z_crc32 = (ame224_z_crc32_fn)dlsym(RTLD_DEFAULT, "crc32");
        ame224_z_deflateBound = (ame224_z_deflateBound_fn)dlsym(RTLD_DEFAULT, "deflateBound");
        ame224_ok = (ame224_z_deflateInit2_ != NULL && ame224_z_deflate != NULL &&
                     ame224_z_deflateEnd != NULL && ame224_z_crc32 != NULL);
        if (!ame224_ok) {
            NSLog(@"[ExportOps] Task224 zlib resolve FAILED (deflateInit2_=%p deflate=%p crc32=%p)",
                  ame224_z_deflateInit2_, ame224_z_deflate, ame224_z_crc32);
        }
    });
    return ame224_ok;
}

static inline BOOL ame224_isCancelled(NSProgress *p) {
    return (p != nil && [p isCancelled]);
}

static BOOL ame224_writeAll(int fd, const void *buf, size_t len) {
    const unsigned char *p = (const unsigned char *)buf;
    while (len > 0) {
        ssize_t w = write(fd, p, len);
        if (w < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        p += w;
        len -= (size_t)w;
    }
    return YES;
}

static void ame224_put16(unsigned char *p, uint16_t v) {
    p[0] = (unsigned char)(v & 0xFFu);
    p[1] = (unsigned char)((v >> 8) & 0xFFu);
}

static void ame224_put32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v & 0xFFu);
    p[1] = (unsigned char)((v >> 8) & 0xFFu);
    p[2] = (unsigned char)((v >> 16) & 0xFFu);
    p[3] = (unsigned char)((v >> 24) & 0xFFu);
}

static void ame224_put64(unsigned char *p, uint64_t v) {
    ame224_put32(p, (uint32_t)(v & 0xFFFFFFFFu));
    ame224_put32(p + 4, (uint32_t)(v >> 32));
}

static void ame224_dosDateTime(NSDate *date, uint16_t *dosTime, uint16_t *dosDate) {
    time_t t = (time_t)[date timeIntervalSince1970];
    struct tm tmv;
    localtime_r(&t, &tmv);
    if (tmv.tm_year < 80) {
        tmv.tm_year = 80; tmv.tm_mon = 0; tmv.tm_mday = 1;
        tmv.tm_hour = 0; tmv.tm_min = 0; tmv.tm_sec = 0;
    }
    uint16_t y = (uint16_t)(tmv.tm_year - 80);
    if (y > 127) y = 127;
    *dosDate = (uint16_t)(((uint16_t)y << 9) | (((uint16_t)tmv.tm_mon + 1) << 5) | (uint16_t)tmv.tm_mday);
    *dosTime = (uint16_t)(((uint16_t)tmv.tm_hour << 11) | ((uint16_t)tmv.tm_min << 5) | ((uint16_t)tmv.tm_sec >> 1));
}

+ (NSArray<NSDictionary *> *)ame224_sectionDefinitions {
    return @[
        @{ @"id": Ame224SectionIdWorlds, @"icon": @"globe", @"defaultOn": @YES },
        @{ @"id": Ame224SectionIdResourcePacks, @"icon": @"paintpalette", @"defaultOn": @YES },
        @{ @"id": Ame224SectionIdMods, @"icon": @"puzzlepiece", @"defaultOn": @YES },
        @{ @"id": Ame224SectionIdScreenshots, @"icon": @"camera", @"defaultOn": @YES },
        @{ @"id": Ame224SectionIdServers, @"icon": @"server.rack", @"defaultOn": @YES },
        @{ @"id": Ame224SectionIdInstance, @"icon": @"folder", @"defaultOn": @NO },
        @{ @"id": Ame224SectionIdLauncher, @"icon": @"gearshape", @"defaultOn": @YES },
        @{ @"id": Ame224SectionIdGameFiles, @"icon": @"arrow.down.circle", @"defaultOn": @NO },
    ];
}

/// 互斥分桶（顺序敏感：当前实例的五个子目录优先于 instance 整树桶）。
- (NSString *)ame224_bucketForRelPath:(NSString *)rel gameDirPrefix:(NSString *)gdPrefix {
    if ([rel hasPrefix:gdPrefix]) {
        NSString *sub = [rel substringFromIndex:gdPrefix.length];
        if ([sub hasPrefix:@"saves/"]) return Ame224SectionIdWorlds;
        if ([sub hasPrefix:@"resourcepacks/"]) return Ame224SectionIdResourcePacks;
        if ([sub hasPrefix:@"shaderpacks/"]) return Ame224SectionIdResourcePacks;
        if ([sub hasPrefix:@"mods/"]) return Ame224SectionIdMods;
        if ([sub hasPrefix:@"config/"]) return Ame224SectionIdMods;
        if ([sub hasPrefix:@"screenshots/"]) return Ame224SectionIdScreenshots;
        if ([sub isEqualToString:@"servers.dat"]) return Ame224SectionIdServers;
        if ([sub isEqualToString:@"servers.dat_old"]) return Ame224SectionIdServers;
    }
    if ([rel hasPrefix:@"instances/"]) return Ame224SectionIdInstance;
    if ([rel hasPrefix:@"versions/"]) return Ame224SectionIdGameFiles;
    if ([rel hasPrefix:@"libraries/"]) return Ame224SectionIdGameFiles;
    if ([rel hasPrefix:@"assets/"]) return Ame224SectionIdGameFiles;
    if ([rel hasPrefix:@"java_runtimes/"]) return Ame224SectionIdGameFiles;
    return Ame224SectionIdLauncher;
}

/// 深度遍历 POJAV_HOME：剔除运行期垃圾与符号链接。
/// ★ Task226（反馈 #13：备份导入无效果）：旧实现整体跳过根级 Library/
/// ——而 legacy 布局的游戏数据（saves/mods/options.txt 等）恰好住在
/// <POJAV_HOME>/Library/Application Support/minecraft（上游老版本/更新
/// 残留的真实目录）。导出跳过它 = 备份里根本没有游戏数据 → 恢复后
/// "导入无效果"。修法：只跳过运行期垃圾（Library/Caches 等已知项），
/// 其余 Library/ 内容全部纳入备份；符号链接本就一律跳过（旧注释担心的
/// "指向实例目录的符号链接双份导出"由该防御继续兜住，且 Task226 起
/// main.m 对 legacy 真实目录做迁移归档，链接不再指向实例）。
- (BOOL)ame224_walkHome:(NSString *)home
          cancelProgress:(nullable NSProgress *)cancelProgress
                visitor:(void(^)(NSString *rel, unsigned long long size, NSDate *mtime))visitor {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *e = [fm enumeratorAtPath:home];
    NSString *rel = nil;
    NSUInteger ame224_ticks = 0;
    while ((rel = [e nextObject])) {
        if ((++ame224_ticks & 0x1FF) == 0 && [cancelProgress isCancelled]) return NO;
        if ([self ame217_shouldSkipExportEntry:rel.lastPathComponent] ||
            // Task226：仅排除已知运行期垃圾，保留 legacy 游戏数据
            [rel hasPrefix:@"Library/Caches/"] || [rel isEqualToString:@"Library/Caches"]) {
            [e skipDescendants];
            continue;
        }
        NSString *abs = [home stringByAppendingPathComponent:rel];
        NSDictionary *attrs = [fm attributesOfItemAtPath:abs error:nil];
        if (!attrs) continue;
        NSString *ft = [attrs fileType];
        if ([ft isEqualToString:NSFileTypeSymbolicLink]) {
            // 防御：无论枚举器是否跟随链接，符号链接一律不导出
            [e skipDescendants];
            continue;
        }
        if ([ft isEqualToString:NSFileTypeDirectory]) continue;
        visitor(rel, [attrs fileSize], [attrs fileModificationDate]);
    }
    return YES;
}

- (void)ame224_scanSectionsWithCompletion:(void(^)(NSArray<NSDictionary *> *stats, NSError *error))completion {
    NSString *home = @(getenv("POJAV_HOME"));
    if (home.length == 0) {
        completion(nil, [NSError errorWithDomain:@"DataTransferService" code:100
                                     userInfo:@{NSLocalizedDescriptionKey: @"POJAV_HOME unset"}]);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        id ame224_gdRaw = getPrefObject(@"general.game_directory");
        NSString *ame224_gd = [ame224_gdRaw isKindOfClass:[NSString class]] ? (NSString *)ame224_gdRaw : @"default";
        if ([ame224_gd length] == 0) ame224_gd = @"default";
        NSString *ame224_gdPrefix = [NSString stringWithFormat:@"instances/%@/", ame224_gd];
        NSMutableDictionary *ame224_counts = [NSMutableDictionary dictionary];
        NSMutableDictionary *ame224_sizes = [NSMutableDictionary dictionary];
        // Task224 CI 修复 r1：块内自增的值类型捕获必须 __block
        // （Task223 CI 教训复用——块内赋值的局部值类型一律 __block）。
        __block unsigned long long ame224_instanceFullBytes = 0;
        __block NSUInteger ame224_instanceFullFiles = 0;
        [self ame224_walkHome:home cancelProgress:nil visitor:^(NSString *rel, unsigned long long size, NSDate *mtime) {
            NSString *bucket = [self ame224_bucketForRelPath:rel gameDirPrefix:ame224_gdPrefix];
            ame224_counts[bucket] = @([ame224_counts[bucket] unsignedIntegerValue] + 1);
            ame224_sizes[bucket] = @([ame224_sizes[bucket] unsignedLongLongValue] + size);
            if ([rel hasPrefix:@"instances/"]) {
                ame224_instanceFullBytes += size;
                ame224_instanceFullFiles++;
            }
        }];
        NSMutableArray *ame224_result = [NSMutableArray array];
        for (NSDictionary *def in [DataTransferService ame224_sectionDefinitions]) {
            NSString *sid = def[@"id"];
            [ame224_result addObject:@{
                @"id": sid,
                @"files": ame224_counts[sid] ?: @0,
                @"bytes": ame224_sizes[sid] ?: @0,
            }];
        }
        // instance 分区行显示整树规模（含五个子分区），勾选逻辑在导出侧覆盖
        [ame224_result addObject:@{
            @"id": @"instance_full",
            @"files": @(ame224_instanceFullFiles),
            @"bytes": @(ame224_instanceFullBytes),
        }];
        NSLog(@"[ExportOps] Task224 scan: %@", ame224_result);
        completion(ame224_result, nil);
    });
}

/// worker 侧：整文件 CRC32（store 模式；顺带预热页缓存，写线程重读走内存）。
- (uint32_t)ame224_crcFileAtPath:(NSString *)absPath
                          readBuf:(unsigned char *)rbuf
                     expectedSize:(unsigned long long)usize
                        sizeDrift:(BOOL *)driftOut {
    uint32_t crc = (uint32_t)ame224_z_crc32(0, Z_NULL, 0);
    unsigned long long got = 0;
    int fd = open([absPath fileSystemRepresentation], O_RDONLY);
    if (fd < 0) {
        if (driftOut) *driftOut = YES;
        return crc;
    }
    for (;;) {
        ssize_t r = read(fd, rbuf, Ame224ReadChunkBytes);
        if (r == 0) break;
        if (r < 0) {
            if (errno == EINTR) continue;
            if (driftOut) *driftOut = YES;
            break;
        }
        crc = (uint32_t)ame224_z_crc32(crc, rbuf, (unsigned)r);
        got += (unsigned long long)r;
    }
    close(fd);
    if (got != usize && driftOut) *driftOut = YES;
    return crc;
}

/// worker 侧：整文件压缩（≤ 64MB；输出缓冲按 deflateBound 一次到位，
/// 零中间拷贝）。返回 nil 表示读失败（调用方跳过该条目）。
- (NSData *)ame224_deflateFileAtPath:(NSString *)absPath
                              readBuf:(unsigned char *)rbuf
                                level:(int)level
                             expected:(unsigned long long)usize
                                  crc:(uint32_t *)crcOut {
    int fd = open([absPath fileSystemRepresentation], O_RDONLY);
    if (fd < 0) return nil;
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    if (ame224_z_deflateInit2_(&zs, level, Z_DEFLATED, -15, 9, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(z_stream)) != Z_OK) {
        close(fd);
        return nil;
    }
    unsigned long bound = ame224_z_deflateBound ? (unsigned long)ame224_z_deflateBound(&zs, usize)
                                                : (unsigned long)(usize + usize / 64 + 4096);
    if (bound < 4096) bound = 4096;
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)bound];
    unsigned char *ob = (unsigned char *)[out mutableBytes];
    size_t olen = 0;
    uint32_t crc = (uint32_t)ame224_z_crc32(0, Z_NULL, 0);
    BOOL ok = YES;
    unsigned long long got = 0;
    for (;;) {
        ssize_t r = read(fd, rbuf, Ame224ReadChunkBytes);
        if (r == 0) break;
        if (r < 0) {
            if (errno == EINTR) continue;
            ok = NO;   // 读失败：跳过该条目（沿用旧版容错语义）
            break;
        }
        crc = (uint32_t)ame224_z_crc32(crc, rbuf, (unsigned)r);
        got += (unsigned long long)r;
        zs.next_in = rbuf;
        zs.avail_in = (unsigned)r;
        while (zs.avail_in > 0) {
            zs.next_out = ob + olen;
            zs.avail_out = (unsigned)(bound - olen);
            int ret = ame224_z_deflate(&zs, Z_NO_FLUSH);
            olen = (size_t)(bound - zs.avail_out);
            if (ret != Z_OK || (zs.avail_out == 0 && zs.avail_in > 0)) { ok = NO; break; }   // 界定不足防御（理论不可达）
        }
        if (!ok) break;
    }
    if (ok) {
        for (;;) {
            zs.next_in = NULL;
            zs.avail_in = 0;
            zs.next_out = ob + olen;
            zs.avail_out = (unsigned)(bound - olen);
            int ret = ame224_z_deflate(&zs, Z_FINISH);
            olen = (size_t)(bound - zs.avail_out);
            if (ret == Z_STREAM_END) break;
            if (ret != Z_OK || zs.avail_out == 0) { ok = NO; break; }
        }
    }
    ame224_z_deflateEnd(&zs);
    close(fd);
    if (!ok || got != usize) return nil;
    [out setLength:olen];
    if (crcOut) *crcOut = crc;
    return out;
}

- (void)ame224_runBackupExportWithMethod:(NSInteger)method
                                sectionIds:(NSArray<NSString *> *)sectionIds
                             cancelProgress:(NSProgress *)cancelProgress
                                   progress:(Ame224ExportProgressBlock)progress
                                 completion:(void(^)(NSString *tmpPath, NSError *error))completion {
    NSString *home = @(getenv("POJAV_HOME"));
    if (home.length == 0) {
        completion(nil, [NSError errorWithDomain:@"DataTransferService" code:100
                                     userInfo:@{NSLocalizedDescriptionKey: @"POJAV_HOME unset"}]);
        return;
    }
    if (!ame224_zlibResolve()) {
        completion(nil, [NSError errorWithDomain:@"DataTransferService" code:104
                                     userInfo:@{NSLocalizedDescriptionKey: @"zlib unavailable"}]);
        return;
    }
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"prisma-backup-%@.zip", [fmt stringFromDate:[NSDate date]]]];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDate *t0 = [NSDate date];
        // method 沿用 UZKCompressionMethod 语义：0=None（store）、-1=Default、9=Best
        BOOL storeMode = (method == 0);
        int level = (method == 9) ? 9 : Z_DEFAULT_COMPRESSION;

        // ---- 阶段 0：收集（分类 + 单文件 zip32 守卫）----
        if (progress) progress(0, 0, 0, 0, 0, 0.0, @"");
        id gdRaw = getPrefObject(@"general.game_directory");
        NSString *gd = [gdRaw isKindOfClass:[NSString class]] ? (NSString *)gdRaw : @"default";
        if ([gd length] == 0) gd = @"default";
        NSString *gdPrefix = [NSString stringWithFormat:@"instances/%@/", gd];
        NSSet *selected = [NSSet setWithArray:(sectionIds ?: @[])];
        BOOL instanceFull = [selected containsObject:Ame224SectionIdInstance];

        NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
        [self ame224_walkHome:home cancelProgress:cancelProgress visitor:^(NSString *rel, unsigned long long size, NSDate *mtime) {
            [found addObject:@{ @"rel": rel, @"size": @(size), @"mtime": mtime ?: [NSDate date] }];
        }];
        if (ame224_isCancelled(cancelProgress)) {
            completion(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
            return;
        }

        NSMutableArray<Ame224ExportEntry *> *entries = [NSMutableArray array];
        // Task224 CI 修复 r1：块内赋值的捕获局部（对象指针同样需要 __block）。
        __block NSString *oversizeFile = nil;
        for (NSDictionary *f in found) {
            NSString *rel = f[@"rel"];
            NSString *bucket = [self ame224_bucketForRelPath:rel gameDirPrefix:gdPrefix];
            BOOL include = [selected containsObject:bucket];
            if (!include && instanceFull) {
                include = ([bucket isEqualToString:Ame224SectionIdWorlds] ||
                           [bucket isEqualToString:Ame224SectionIdResourcePacks] ||
                           [bucket isEqualToString:Ame224SectionIdMods] ||
                           [bucket isEqualToString:Ame224SectionIdScreenshots] ||
                           [bucket isEqualToString:Ame224SectionIdServers]);
            }
            if (!include) continue;
            unsigned long long size = [f[@"size"] unsignedLongLongValue];
            if (size >= 0xFFFFFFFFull) {
                // zip32 单条目上限（本写器不做单文件 zip64，明确报错优于静默截断）
                oversizeFile = rel;
                break;
            }
            Ame224ExportEntry *entry = [[Ame224ExportEntry alloc] init];
            entry.rel = rel;
            entry.abs = [home stringByAppendingPathComponent:rel];
            entry.usize = size;
            // Task224 CI 修复 r1：属性表达式不可取址（&entry.dosTime 非法）
            // ——经局部变量中转。
            uint16_t ame224_dt = 0, ame224_dd = 0;
            ame224_dosDateTime(f[@"mtime"], &ame224_dt, &ame224_dd);
            entry.dosTime = ame224_dt;
            entry.dosDate = ame224_dd;
            entry.serialStream = (!storeMode && size > Ame224ParallelFileCap);
            entry.budgetUnits = (int64_t)((size + 1048575ull) / 1048576ull);
            [entries addObject:entry];
        }
        if (oversizeFile) {
            completion(nil, [NSError errorWithDomain:@"DataTransferService" code:105
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    localize(@"dataexport.error.toolarge", @"File too large for zip: %@"), oversizeFile]}]);
            return;
        }
        [entries sortUsingComparator:^NSComparisonResult(Ame224ExportEntry *a, Ame224ExportEntry *b) {
            return [a.rel compare:b.rel];
        }];
        NSUInteger count = entries.count;
        unsigned long long totalBytes = 0;
        for (Ame224ExportEntry *entry in entries) totalBytes += entry.usize;
        if (count == 0) {
            completion(nil, [NSError errorWithDomain:@"DataTransferService" code:101
                userInfo:@{NSLocalizedDescriptionKey: localize(@"ame219.export.empty", @"No data to export")}]);
            return;
        }
        NSLog(@"[ExportOps] Task224 export start: method=%ld store=%d files=%lu bytes=%llu workers=%lu sections=%lu",
              (long)method, (int)storeMode, (unsigned long)count, totalBytes,
              (unsigned long)Ame224WorkerCount, (unsigned long)selected.count);
        if (progress) progress(1, 0, count, 0, totalBytes, 0.0, @"");

        // ---- 流水线共享态 ----
        Ame224PipelineState *st = (Ame224PipelineState *)calloc(1, sizeof(Ame224PipelineState));
        Ame224PipelineCounters *counters = [[Ame224PipelineCounters alloc] init];
        Ame224SpeedTracker *tracker = [[Ame224SpeedTracker alloc] init];
        dispatch_queue_t workerQueue = dispatch_queue_create_with_target(
            "ame224.export.workers", DISPATCH_QUEUE_CONCURRENT,
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t slotReady = dispatch_semaphore_create(0);
        dispatch_semaphore_t budget = dispatch_semaphore_create((long)Ame224BudgetUnits);

        // 10Hz 进度合并上报（热循环零主线程派发；tick 串行队列独享 tracker）
        dispatch_queue_t tickQueue = dispatch_queue_create("ame224.export.tick", DISPATCH_QUEUE_SERIAL);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, tickQueue);
        NSUInteger tickTotalFiles = count;
        unsigned long long tickTotalBytes = totalBytes;
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 100LL * NSEC_PER_MSEC),
                                  100LL * NSEC_PER_MSEC, 20LL * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(timer, ^{
            if (!progress) return;
            double now = CFAbsoluteTimeGetCurrent();
            unsigned long long b = (unsigned long long)__sync_add_and_fetch(&st->bytesDone, 0);
            if (tracker.lastTime <= 0.0) {
                tracker.lastTime = now;
                tracker.lastBytes = b;
                return;
            }
            double dt = now - tracker.lastTime;
            if (dt >= 0.4) {
                double inst = ((double)b - (double)tracker.lastBytes) / dt;
                tracker.speed = (tracker.speed <= 0.0) ? inst : tracker.speed * 0.6 + inst * 0.4;
                tracker.lastTime = now;
                tracker.lastBytes = b;
            }
            progress((NSUInteger)st->phase,
                     (NSUInteger)__sync_add_and_fetch(&st->filesDone, 0), tickTotalFiles,
                     b, tickTotalBytes, tracker.speed, counters.currentFile);
        });
        dispatch_resume(timer);

        // ---- 阶段 1：3 路 worker 并行压缩（或 store 模式并行 CRC）----
        for (NSUInteger w = 0; w < Ame224WorkerCount; w++) {
            dispatch_group_enter(group);
            dispatch_async(workerQueue, ^{
                @autoreleasepool {
                    unsigned char *rbuf = (unsigned char *)malloc(Ame224ReadChunkBytes);
                    if (!rbuf) {
                        __sync_lock_test_and_set(&st->failed, 1);
                        counters.failMessage = @"worker buffer alloc failed";
                        dispatch_group_leave(group);
                        return;
                    }
                    int64_t idx;
                    while ((idx = __sync_fetch_and_add(&st->nextIndex, 1)) < (int64_t)count) {
                        if (st->failed || ame224_isCancelled(cancelProgress)) break;
                        Ame224ExportEntry *e = entries[idx];
                        if (e.serialStream) continue;   // 大文件由写线程流式处理
                        // 领先量预算（1MB/单位；写线程消费后归还）
                        BOOL budgeted = YES;
                        for (int64_t u = 0; u < e.budgetUnits && budgeted; u++) {
                            while (dispatch_semaphore_wait(budget, dispatch_time(DISPATCH_TIME_NOW, 20LL * NSEC_PER_MSEC)) != 0) {
                                if (st->failed || ame224_isCancelled(cancelProgress)) { budgeted = NO; break; }
                            }
                        }
                        if (!budgeted) break;
                        if (storeMode) {
                            BOOL drift = NO;
                            e.crc = [self ame224_crcFileAtPath:e.abs readBuf:rbuf expectedSize:e.usize sizeDrift:&drift];
                            e.skipped = drift;
                        } else {
                            uint32_t crc = 0;
                            NSData *payload = [self ame224_deflateFileAtPath:e.abs readBuf:rbuf
                                                                       level:level expected:e.usize crc:&crc];
                            if (payload) {
                                e.payload = payload;
                                e.crc = crc;
                                e.csize = payload.length;
                            } else {
                                // 单文件读失败：跳过（沿用旧版容错语义）
                                e.skipped = YES;
                            }
                        }
                        if (e.skipped) {
                            for (int64_t u = 0; u < e.budgetUnits; u++) dispatch_semaphore_signal(budget);
                        }
                        __sync_synchronize();
                        e.ready = YES;
                        dispatch_semaphore_signal(slotReady);
                    }
                    free(rbuf);
                    dispatch_group_leave(group);
                }
            });
        }

        // ---- 写线程（本线程）：按序写 local header + 数据，条目顺序即 zip 布局 ----
        int outFd = open([tmpPath fileSystemRepresentation], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        BOOL writeFailed = (outFd < 0);
        if (writeFailed) counters.failMessage = @"archive create failed";
        uint64_t curOffset = 0;
        NSUInteger skippedCount = 0;
        NSMutableData *hdr = [NSMutableData dataWithCapacity:256];
        unsigned char *wbuf = NULL;
        unsigned char *sout = NULL;
        // Task224 CI 修复 r1：chunkBound 提升到共享作用域（serialStream 分支
        // 在 per-entry 循环里使用，原声明被埋在 if (!writeFailed) 块内）。
        unsigned long chunkBound = 0;
        if (!writeFailed) {
            wbuf = (unsigned char *)malloc(Ame224ReadChunkBytes);
            chunkBound = ame224_z_deflateBound ? (unsigned long)ame224_z_deflateBound(NULL, Ame224ReadChunkBytes) + 64u : Ame224ReadChunkBytes + Ame224ReadChunkBytes / 64u + 4096u;
            sout = (unsigned char *)malloc(chunkBound);
            if (!wbuf || !sout) {
                writeFailed = YES;
                counters.failMessage = @"writer buffer alloc failed";
            }
        }
        for (NSUInteger i = 0; i < count && !writeFailed; i++) {
            if (st->failed || ame224_isCancelled(cancelProgress)) break;
            Ame224ExportEntry *e = entries[i];
            if (!e.serialStream) {
                while (!e.ready) {
                    if (st->failed || ame224_isCancelled(cancelProgress)) break;
                    if (dispatch_semaphore_wait(slotReady, dispatch_time(DISPATCH_TIME_NOW, 50LL * NSEC_PER_MSEC)) != 0) continue;
                }
                if (!e.ready) break;
                __sync_synchronize();   // acquire：ready 之后的 payload/crc 读取屏障
            }
            if (e.skipped) {
                skippedCount++;
                continue;
            }
            counters.currentFile = e.rel;
            e.headerOffset = curOffset;
            const char *nameBytes = [e.rel UTF8String];
            size_t nlen = strlen(nameBytes);
            uint16_t flags = 0x0800;   // UTF-8 名称位
            uint16_t methodField = 8;
            uint32_t lfhCrc = e.crc;
            uint32_t lfhCsize = (uint32_t)e.csize;
            uint32_t lfhUsize = (uint32_t)e.usize;
            if (e.serialStream) {
                flags |= 0x0008;       // data descriptor（尺寸压缩后才知晓）
                lfhCrc = 0; lfhCsize = 0; lfhUsize = 0;
            }
            if (storeMode) methodField = 0;
            [hdr setLength:30 + nlen];
            unsigned char *h = (unsigned char *)[hdr mutableBytes];
            ame224_put32(h, 0x04034b50u);
            ame224_put16(h + 4, 20);
            ame224_put16(h + 6, flags);
            ame224_put16(h + 8, methodField);
            ame224_put16(h + 10, e.dosTime);
            ame224_put16(h + 12, e.dosDate);
            ame224_put32(h + 14, lfhCrc);
            ame224_put32(h + 18, lfhCsize);
            ame224_put32(h + 22, lfhUsize);
            ame224_put16(h + 26, (uint16_t)nlen);
            ame224_put16(h + 28, 0);
            memcpy(h + 30, nameBytes, nlen);
            if (!ame224_writeAll(outFd, h, 30 + nlen)) { writeFailed = YES; break; }
            curOffset += 30 + nlen;

            if (e.serialStream) {
                // 大文件：写线程流式 deflate（4MB 入 + 界定输出块）
                int inFd = open([e.abs fileSystemRepresentation], O_RDONLY);
                if (inFd < 0) {
                    writeFailed = YES;
                    counters.failMessage = [NSString stringWithFormat:@"open failed: %@", e.rel];
                    break;
                }
                z_stream zs;
                memset(&zs, 0, sizeof(zs));
                if (ame224_z_deflateInit2_(&zs, level, Z_DEFLATED, -15, 9, Z_DEFAULT_STRATEGY, ZLIB_VERSION, (int)sizeof(z_stream)) != Z_OK) {
                    close(inFd);
                    writeFailed = YES;
                    counters.failMessage = @"deflateInit2 failed";
                    break;
                }
                uint32_t crc = (uint32_t)ame224_z_crc32(0, Z_NULL, 0);
                unsigned long long gotU = 0, gotC = 0;
                BOOL streamOk = YES;
                for (;;) {
                    ssize_t r = read(inFd, wbuf, Ame224ReadChunkBytes);
                    if (r == 0) break;
                    if (r < 0) {
                        if (errno == EINTR) continue;
                        streamOk = NO;
                        break;
                    }
                    crc = (uint32_t)ame224_z_crc32(crc, wbuf, (unsigned)r);
                    gotU += (unsigned long long)r;
                    zs.next_in = wbuf;
                    zs.avail_in = (unsigned)r;
                    while (zs.avail_in > 0 && streamOk) {
                        zs.next_out = sout;
                        zs.avail_out = (unsigned)chunkBound;
                        int ret = ame224_z_deflate(&zs, Z_NO_FLUSH);
                        unsigned long produced = chunkBound - zs.avail_out;
                        if (ret != Z_OK || (zs.avail_out == 0 && zs.avail_in > 0)) { streamOk = NO; break; }
                        if (produced > 0) {
                            if (!ame224_writeAll(outFd, sout, produced)) { streamOk = NO; break; }
                            gotC += produced;
                            curOffset += produced;
                            __sync_add_and_fetch(&st->bytesDone, (int64_t)r);
                        }
                    }
                    if (ame224_isCancelled(cancelProgress) || st->failed) { streamOk = NO; break; }
                }
                if (streamOk) {
                    for (;;) {
                        zs.next_in = NULL;
                        zs.avail_in = 0;
                        zs.next_out = sout;
                        zs.avail_out = (unsigned)chunkBound;
                        int ret = ame224_z_deflate(&zs, Z_FINISH);
                        unsigned long produced = chunkBound - zs.avail_out;
                        if (produced > 0) {
                            if (!ame224_writeAll(outFd, sout, produced)) { streamOk = NO; break; }
                            gotC += produced;
                            curOffset += produced;
                        }
                        if (ret == Z_STREAM_END) break;
                        if (ret != Z_OK || zs.avail_out == 0) { streamOk = NO; break; }
                    }
                }
                ame224_z_deflateEnd(&zs);
                close(inFd);
                if (!streamOk && !ame224_isCancelled(cancelProgress) && !st->failed) {
                    writeFailed = YES;
                    counters.failMessage = [NSString stringWithFormat:@"stream deflate failed: %@", e.rel];
                    break;
                }
                if (streamOk) {
                    e.crc = crc;
                    e.csize = gotC;
                    e.usize = gotU;
                    unsigned char dd[16];
                    ame224_put32(dd, 0x08074b50u);
                    ame224_put32(dd + 4, e.crc);
                    ame224_put32(dd + 8, (uint32_t)e.csize);
                    ame224_put32(dd + 12, (uint32_t)e.usize);
                    if (!ame224_writeAll(outFd, dd, 16)) { writeFailed = YES; break; }
                    curOffset += 16;
                }
            } else if (storeMode) {
                // store：4MB 直通写盘（CRC 已由 worker 并行算好）
                int inFd = open([e.abs fileSystemRepresentation], O_RDONLY);
                if (inFd < 0) {
                    writeFailed = YES;
                    counters.failMessage = [NSString stringWithFormat:@"open failed: %@", e.rel];
                    break;
                }
                unsigned long long got = 0;
                BOOL copyOk = YES;
                for (;;) {
                    ssize_t r = read(inFd, wbuf, Ame224ReadChunkBytes);
                    if (r == 0) break;
                    if (r < 0) {
                        if (errno == EINTR) continue;
                        copyOk = NO;
                        break;
                    }
                    if (!ame224_writeAll(outFd, wbuf, (size_t)r)) { copyOk = NO; break; }
                    got += (unsigned long long)r;
                    curOffset += (uint64_t)r;
                    __sync_add_and_fetch(&st->bytesDone, (int64_t)r);
                    if (ame224_isCancelled(cancelProgress)) { copyOk = NO; break; }
                }
                close(inFd);
                if (!copyOk) {
                    writeFailed = YES;
                    counters.failMessage = [NSString stringWithFormat:@"store copy failed: %@", e.rel];
                    break;
                }
                if (got != e.usize) {
                    writeFailed = YES;
                    counters.failMessage = [NSString stringWithFormat:@"size drift: %@", e.rel];
                    break;
                }
            } else {
                // 小文件 deflate：整块写 worker 产物
                if (!ame224_writeAll(outFd, e.payload.bytes, e.payload.length)) { writeFailed = YES; break; }
                curOffset += e.payload.length;
                __sync_add_and_fetch(&st->bytesDone, (int64_t)e.usize);
            }
            if (!writeFailed) {
                __sync_add_and_fetch(&st->filesDone, 1);
                if (!e.serialStream) {
                    // 预算归还仅限 worker 预留过的条目（流式大文件从未占用）
                    for (int64_t u = 0; u < e.budgetUnits; u++) dispatch_semaphore_signal(budget);
                }
                e.payload = nil;   // 归还内存（预算信号量同步释放）
            }
        }
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

        // ---- 阶段 2：中央目录 + EOCD（zip64 按需）----
        st->phase = 2;
        BOOL cancelled = ame224_isCancelled(cancelProgress);
        BOOL failed = (writeFailed || st->failed != 0);
        NSString *failMsg = (writeFailed || st->failed != 0) ? (counters.failMessage ?: @"zip write failed") : nil;
        if (!failed && !cancelled) {
            uint64_t cdOffset = curOffset;
            uint64_t cdSize = 0;
            for (Ame224ExportEntry *e in entries) {
                if (e.skipped) continue;
                const char *nameBytes = [e.rel UTF8String];
                size_t nlen = strlen(nameBytes);
                BOOL entryZip64 = (e.headerOffset >= 0xFFFFFFFFull);
                size_t extraLen = entryZip64 ? 28 : 0;
                [hdr setLength:46 + extraLen + nlen];
                unsigned char *h = (unsigned char *)[hdr mutableBytes];
                ame224_put32(h, 0x02014b50u);
                ame224_put16(h + 4, 20);
                ame224_put16(h + 6, entryZip64 ? 45 : 20);
                ame224_put16(h + 8, (uint16_t)(0x0800 | (e.serialStream ? 0x0008 : 0)));
                ame224_put16(h + 10, storeMode ? 0 : 8);
                ame224_put16(h + 12, e.dosTime);
                ame224_put16(h + 14, e.dosDate);
                ame224_put32(h + 16, e.crc);
                ame224_put32(h + 20, (uint32_t)(entryZip64 ? 0xFFFFFFFFull : e.csize));
                ame224_put32(h + 24, (uint32_t)(entryZip64 ? 0xFFFFFFFFull : e.usize));
                ame224_put16(h + 28, (uint16_t)nlen);
                ame224_put16(h + 30, (uint16_t)extraLen);
                ame224_put16(h + 32, 0);
                ame224_put16(h + 34, 0);
                ame224_put16(h + 36, 0);
                ame224_put16(h + 38, 0);
                ame224_put32(h + 40, 0);
                ame224_put32(h + 42, (uint32_t)(entryZip64 ? 0xFFFFFFFFull : e.headerOffset));
                if (entryZip64) {
                    ame224_put16(h + 46, 0x0001);
                    ame224_put16(h + 48, 24);
                    ame224_put64(h + 50, e.usize);
                    ame224_put64(h + 58, e.csize);
                    ame224_put64(h + 66, e.headerOffset);
                }
                memcpy(h + 46 + extraLen, nameBytes, nlen);
                if (!ame224_writeAll(outFd, h, 46 + extraLen + nlen)) {
                    writeFailed = YES;
                    failed = YES;
                    failMsg = @"central directory write failed";
                    break;
                }
                cdSize += 46 + extraLen + nlen;
            }
            if (!writeFailed) {
                NSUInteger writtenCount = 0;
                for (Ame224ExportEntry *e in entries) { if (!e.skipped) writtenCount++; }
                BOOL needZip64EOCD = (writtenCount > 0xFFFF || cdOffset >= 0xFFFFFFFFull || cdSize >= 0xFFFFFFFFull);
                if (needZip64EOCD) {
                    unsigned char z64[56];
                    ame224_put32(z64, 0x06064b50u);
                    ame224_put64(z64 + 4, 44);
                    ame224_put16(z64 + 12, 45);
                    ame224_put16(z64 + 14, 45);
                    ame224_put32(z64 + 16, 0);
                    ame224_put32(z64 + 20, 0);
                    ame224_put64(z64 + 24, (uint64_t)writtenCount);
                    ame224_put64(z64 + 32, (uint64_t)writtenCount);
                    ame224_put64(z64 + 40, cdSize);
                    ame224_put64(z64 + 48, cdOffset);
                    unsigned char loc[20];
                    ame224_put32(loc, 0x07064b50u);
                    ame224_put32(loc + 4, 0);
                    ame224_put64(loc + 8, cdOffset + cdSize);
                    ame224_put32(loc + 16, 1);
                    if (!ame224_writeAll(outFd, z64, 56) || !ame224_writeAll(outFd, loc, 20)) {
                        writeFailed = YES; failed = YES; failMsg = @"zip64 eocd write failed";
                    }
                }
                if (!writeFailed) {
                    unsigned char eocd[22];
                    ame224_put32(eocd, 0x06054b50u);
                    ame224_put16(eocd + 4, 0);
                    ame224_put16(eocd + 6, 0);
                    ame224_put16(eocd + 8, (uint16_t)(writtenCount > 0xFFFF ? 0xFFFF : writtenCount));
                    ame224_put16(eocd + 10, (uint16_t)(writtenCount > 0xFFFF ? 0xFFFF : writtenCount));
                    ame224_put32(eocd + 12, (uint32_t)(cdSize >= 0xFFFFFFFFull ? 0xFFFFFFFFull : cdSize));
                    ame224_put32(eocd + 16, (uint32_t)(cdOffset >= 0xFFFFFFFFull ? 0xFFFFFFFFull : cdOffset));
                    ame224_put16(eocd + 20, 0);
                    if (!ame224_writeAll(outFd, eocd, 22)) {
                        writeFailed = YES; failed = YES; failMsg = @"eocd write failed";
                    }
                }
            }
        }
        if (outFd >= 0) close(outFd);
        dispatch_source_cancel(timer);
        free(wbuf);
        free(sout);

        unsigned long long finalBytes = (unsigned long long)__sync_add_and_fetch(&st->bytesDone, 0);
        NSUInteger finalFiles = (NSUInteger)__sync_add_and_fetch(&st->filesDone, 0);
        free(st);

        if (cancelled || failed) {
            [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
            if (cancelled) {
                NSLog(@"[ExportOps] Task224 cancelled at %lu/%lu files (%llu bytes)", (unsigned long)finalFiles, (unsigned long)count, finalBytes);
                completion(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]);
            } else {
                NSLog(@"[ExportOps] Task224 export FAILED: %@", failMsg);
                completion(nil, [NSError errorWithDomain:@"DataTransferService" code:103
                    userInfo:@{NSLocalizedDescriptionKey: failMsg}]);
            }
            return;
        }
        if (progress) progress(2, count, count, totalBytes, totalBytes, 0.0, @"");
        NSTimeInterval elapsed = -[t0 timeIntervalSinceNow];
        NSLog(@"[ExportOps] Task224 summary: files=%lu bytes=%llu seconds=%.2f avg=%.1f MB/s archive=%@ method=%ld skipped=%lu",
              (unsigned long)finalFiles, finalBytes, elapsed, finalBytes / 1048576.0 / MAX(elapsed, 0.001),
              tmpPath.lastPathComponent, (long)method, (unsigned long)skippedCount);
        completion(tmpPath, nil);
    });
}

- (void)ame223_presentDestinationPickerForTmpPath:(NSString *)tmpPath
                                              from:(UIViewController *)presenter {
    if (tmpPath.length == 0 || !presenter) return;
    self.presenter = presenter;
    NSURL *tmpURL = [NSURL fileURLWithPath:tmpPath];
    dispatch_async(dispatch_get_main_queue(), ^{
        // 完成提示 + 直接落点选择（move 语义不占双份空间）。
        UIAlertController *doneAlert = [UIAlertController
            alertControllerWithTitle:localize(@"dataexport.done.title", nil)
                             message:tmpPath.lastPathComponent
                      preferredStyle:UIAlertControllerStyleAlert];
        [doneAlert addAction:[UIAlertAction actionWithTitle:localize(@"dataexport.save_to_files", nil)
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(UIAlertAction *a) {
            UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                initForExportingURLs:@[tmpURL] asCopy:NO];
            picker.delegate = self;
            picker.modalPresentationStyle = UIModalPresentationFormSheet;
            self.awaitingExportDestination = YES;
            [presenter presentViewController:picker animated:YES completion:nil];
        }]];
        [doneAlert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", @"OK")
                                                      style:UIAlertActionStyleCancel
                                                    handler:^(UIAlertAction *a) {
            // 不保存：清理 tmp
            [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
        }]];
        [presenter presentViewController:doneAlert animated:YES completion:nil];
    });
}

@end
