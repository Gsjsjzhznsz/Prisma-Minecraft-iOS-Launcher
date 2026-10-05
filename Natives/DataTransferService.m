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
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface DataTransferService () <UIDocumentPickerDelegate>
@property (nonatomic, weak) UIViewController *presenter;
/// 导出流程的文件选择器正在等待落点（区分导出/导入两条 delegate 回调——
/// 导出落点文件名同样以 .zip 结尾，不能靠扩展名判流）。
@property (nonatomic, assign) BOOL awaitingExportDestination;
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

#pragma mark - Task223：并发读 + 串行写流水线导出（清单第 12/13 项根修）

- (void)ame223_runPipelinedBackupExportWithMethod:(NSInteger)method
                                          progress:(void(^)(NSUInteger done, NSUInteger total, unsigned long long writtenBytes))progress
                                      stageAdvance:(void(^)(NSUInteger stage))stageAdvance
                                        completion:(void(^)(NSString *tmpPath, NSError *error))completion {
    NSString *home = @(getenv("POJAV_HOME"));
    if (home.length == 0) {
        completion(nil, [NSError errorWithDomain:@"DataTransferService" code:100
                                     userInfo:@{NSLocalizedDescriptionKey: @"POJAV_HOME unset"}]);
        return;
    }
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"prisma-backup-%@.zip", [fmt stringFromDate:[NSDate date]]]];
    [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        // ---- 阶段 0：收集（枚举 + 属性一次拿全，避免写入循环里二次 stat）----
        NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:home];
        NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
        NSString *rel;
        while ((rel = [enumerator nextObject])) {
            if ([self ame217_shouldSkipExportEntry:rel.lastPathComponent]) {
                [enumerator skipDescendants];
                continue;
            }
            NSString *abs = [home stringByAppendingPathComponent:rel];
            NSDictionary *attrs = [fm attributesOfItemAtPath:abs error:nil];
            if (attrs && ![attrs.fileType isEqualToString:NSFileTypeDirectory]) {
                [entries addObject:@{@"rel": rel, @"abs": abs, @"size": @(attrs.fileSize)}];
            }
        }
        NSUInteger total = entries.count;
        if (total == 0) {
            completion(nil, [NSError errorWithDomain:@"DataTransferService" code:101
                                         userInfo:@{NSLocalizedDescriptionKey: localize(@"ame219.export.empty", @"No data to export")}]);
            return;
        }
        if (stageAdvance) stageAdvance(0);   // collect 完成 → compress 开始

        // ---- 阶段 1：流水线（4 路并发读 + 串行写）----
        NSError *archiveErr = nil;
        UZKArchive *archive = [[UZKArchive alloc] initWithPath:tmpPath error:&archiveErr];
        if (archive == nil) {
            completion(nil, archiveErr ?: [NSError errorWithDomain:@"DataTransferService" code:102
                                                      userInfo:@{NSLocalizedDescriptionKey: @"archive init failed"}]);
            return;
        }

        // 在飞上限：平均文件 < 8MB 时取 8 个文件、否则按 64MB 预算折算，
        // 防大文件会话（材质包/.jar 数百 MB）读侧内存失控。
        unsigned long long totalSize = 0;
        for (NSDictionary *e in entries) totalSize += [e[@"size"] unsignedLongLongValue];
        NSUInteger avg = (NSUInteger)MAX((double)totalSize / (double)total, 1.0);
        NSUInteger maxInFlight = (NSUInteger)MAX(8.0, MIN(48.0, 64.0 * 1048576.0 / (double)avg));

        dispatch_queue_t writeQueue = dispatch_queue_create("ame223.export.write", DISPATCH_QUEUE_SERIAL);
        dispatch_group_t writeGroup = dispatch_group_create();
        dispatch_semaphore_t inFlight = dispatch_semaphore_create((long)maxInFlight);
        __block NSUInteger done = 0;
        __block unsigned long long writtenBytes = 0;
        __block BOOL failed = NO;
        __block NSError *failErr = nil;
        __block NSDate *lastUi = [NSDate distantPast];

        // 读侧：全局并发队列按序取号（保持条目顺序，zip 内目录顺序友好）。
        for (NSDictionary *e in entries) {
            if (failed) break;
            dispatch_semaphore_wait(inFlight, DISPATCH_TIME_FOREVER);
            if (failed) break;
            NSString *abs = e[@"abs"];
            NSString *relPath = e[@"rel"];
            dispatch_group_enter(writeGroup);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                @autoreleasepool {
                    if (!failed) {
                        NSData *data = [NSData dataWithContentsOfFile:abs];
                        // 写侧：串行队列保证 UZKArchive 单线程访问（线程安全硬约束）；
                        // 读完成即释放一个在飞名额（读写重叠的稳态来源）。
                        dispatch_async(writeQueue, ^{
                            @autoreleasepool {
                                if (!failed && data != nil) {
                                    NSError *werr = nil;
                                    if (![archive writeData:data filePath:relPath fileDate:nil
                                                compressionMethod:(UZKCompressionMethod)method
                                                      password:nil overwrite:YES error:&werr]) {
                                        failed = YES;
                                        failErr = werr;
                                    } else {
                                        done++;
                                        writtenBytes += data.length;
                                    }
                                } else if (!failed && data == nil) {
                                    // 读失败（文件被并发删除等）：跳过该条目，不判整体失败
                                    done++;
                                }
                                dispatch_group_leave(writeGroup);
                            }
                        });
                    } else {
                        dispatch_group_leave(writeGroup);
                    }
                    // 进度节流（150ms）+ 尾部强刷
                    NSDate *now = [NSDate date];
                    if (progress && ([now timeIntervalSinceDate:lastUi] > 0.15 || done == total)) {
                        lastUi = now;
                        NSUInteger d = done, t = total;
                        unsigned long long b = writtenBytes;
                        progress(d, t, b);
                    }
                    dispatch_semaphore_signal(inFlight);
                }
            });
        }
        // 等全部写入落盘
        dispatch_group_wait(writeGroup, DISPATCH_TIME_FOREVER);

        if (failed) {
            [[NSFileManager defaultManager] removeItemAtPath:tmpPath error:nil];
            completion(nil, failErr ?: [NSError errorWithDomain:@"DataTransferService" code:103
                                                    userInfo:@{NSLocalizedDescriptionKey: @"zip write failed"}]);
            return;
        }
        if (progress) progress(done, total, writtenBytes);
        NSLog(@"[DataTransfer] Task223 pipelined export: %lu files, %llu bytes, method=%ld -> %@",
              (unsigned long)done, writtenBytes, (long)method, tmpPath.lastPathComponent);
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
