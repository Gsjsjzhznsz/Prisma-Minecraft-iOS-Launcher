#import "DataExportViewController.h"
#import "BackgroundManager.h"
#import "DataTransferService.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStage.h"
#import "utils.h"
#import "LauncherPreferences.h"   // accentColor()（同 AboutViewController 先例）
#import "UIKit+hook.h"   // UIWindow.mainWindow 分类声明（destination picker 取最顶层 VC）
#import "UnzipKit.h"   // 仓内约定：CMake include 路径含 external/UnzipKit（同 ModpackImportService）
#import <objc/runtime.h>   // Task224：accessibilityIdentifier 复用无需关联对象（保留头以防后续扩展）

@interface DataExportViewController () {
    NSUInteger _fileCount;
    unsigned long long _totalBytes;
}
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *summaryLabel;
@property (nonatomic, strong) UIStackView *sectionRowsStack;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *sectionOn;
@property (nonatomic, copy) NSArray<NSDictionary *> *sectionStats;
@property (nonatomic, strong) UISegmentedControl *levelSegment;
@property (nonatomic, strong) UILabel *levelHintLabel;
@property (nonatomic, strong) UIButton *startButton;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation DataExportViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"dataexport.title", nil);
    self.view.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.sectionOn = [NSMutableDictionary dictionary];
    for (NSDictionary *def in [DataTransferService ame224_sectionDefinitions]) {
        self.sectionOn[def[@"id"]] = def[@"defaultOn"];
    }

    self.scrollView = [[UIScrollView alloc] init];
    self.scrollView.alwaysBounceVertical = YES;
    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.scrollView];

    self.stack = [[UIStackView alloc] init];
    self.stack.axis = UILayoutConstraintAxisVertical;
    self.stack.spacing = 22;
    self.stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.scrollView addSubview:self.stack];

    [self.stack addArrangedSubview:[self ame223_card:^(UIView *card, UIStackView *inner) {
        UILabel *title = [self ame223_label:localize(@"dataexport.summary.title", nil)
                                       font:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
                                      color:[UIColor labelColor]];
        [inner addArrangedSubview:title];
        self.summaryLabel = [self ame223_label:@" "
                                          font:[UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular]
                                         color:[UIColor secondaryLabelColor]];
        self.summaryLabel.numberOfLines = 3;
        [inner addArrangedSubview:self.summaryLabel];
    }]];

    // Task224（#12）：内容分区选择——勾选要导出的内容，扫描统计（文件数/体积）
    // 逐行显示；instance 勾选时覆盖五个实例子分区（引擎侧语义）。
    [self.stack addArrangedSubview:[self ame223_card:^(UIView *card, UIStackView *inner) {
        UILabel *title = [self ame223_label:localize(@"dataexport.sections.title", nil)
                                       font:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
                                      color:[UIColor labelColor]];
        [inner addArrangedSubview:title];
        self.sectionRowsStack = [[UIStackView alloc] init];
        self.sectionRowsStack.axis = UILayoutConstraintAxisVertical;
        self.sectionRowsStack.spacing = 4;
        self.sectionRowsStack.translatesAutoresizingMaskIntoConstraints = NO;
        [inner addArrangedSubview:self.sectionRowsStack];
    }]];

    [self.stack addArrangedSubview:[self ame223_card:^(UIView *card, UIStackView *inner) {
        UILabel *title = [self ame223_label:localize(@"dataexport.level.title", nil)
                                       font:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]
                                      color:[UIColor labelColor]];
        [inner addArrangedSubview:title];
        self.levelSegment = [[UISegmentedControl alloc] initWithItems:@[
            localize(@"dataexport.level.none", nil),
            localize(@"dataexport.level.fast", nil),
            localize(@"dataexport.level.best", nil),
        ]];
        self.levelSegment.selectedSegmentIndex = 0;
        [self.levelSegment addTarget:self action:@selector(ame223_levelChanged:)
                      forControlEvents:UIControlEventValueChanged];
        [inner addArrangedSubview:self.levelSegment];
        self.levelHintLabel = [self ame223_label:@""
                                            font:[UIFont systemFontOfSize:12]
                                           color:[UIColor tertiaryLabelColor]];
        self.levelHintLabel.numberOfLines = 3;
        [inner addArrangedSubview:self.levelHintLabel];
        [self ame223_levelChanged:self.levelSegment];
    }]];

    self.startButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.startButton setTitle:[NSString stringWithFormat:@"🚀 %@", localize(@"dataexport.start", nil)]
                      forState:UIControlStateNormal];
    [self.startButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.startButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.startButton.backgroundColor = accentColor();
    self.startButton.layer.cornerRadius = 14.0;
    self.startButton.contentEdgeInsets = UIEdgeInsetsMake(14, 20, 14, 20);
    self.startButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.startButton addTarget:self action:@selector(ame223_startTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.stack addArrangedSubview:self.startButton];

    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = NO;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stack addArrangedSubview:self.spinner];
    [self.spinner startAnimating];

    [NSLayoutConstraint activateConstraints:@[
        [self.scrollView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.scrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.scrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.scrollView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.stack.topAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.topAnchor constant:24],
        [self.stack.leadingAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.leadingAnchor constant:24],
        [self.stack.trailingAnchor constraintEqualToAnchor:self.scrollView.frameLayoutGuide.trailingAnchor constant:-24],
        [self.stack.bottomAnchor constraintEqualToAnchor:self.scrollView.contentLayoutGuide.bottomAnchor constant:-24],
        [self.startButton.heightAnchor constraintEqualToConstant:50],
    ]];

    [self ame224_preflightSections];
}

- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI helpers（卡片语言与关于页一致）

- (UIView *)ame223_card:(void(^)(UIView *card, UIStackView *inner))builder {
    UIView *card = [[UIView alloc] init];
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 16.0;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *inner = [[UIStackView alloc] init];
    inner.axis = UILayoutConstraintAxisVertical;
    inner.spacing = 10;
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
        [inner.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:16],
        [inner.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-16],
        [inner.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    ]];
    if (builder) builder(card, inner);
    return card;
}

- (UILabel *)ame223_label:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = font;
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

#pragma mark - Task224：分区扫描 + 选择 UI

/// Task224（#12/#13）：分区级预检（只 stat 不读内容，替代旧整树枚举）——
/// 每个分区显示文件数与体积；勾选态决定导出范围（旧实现整树必导，
/// 用户要"选择 + 进度显示"）。
- (void)ame224_preflightSections {
    [[DataTransferService sharedService] ame224_scanSectionsWithCompletion:^(NSArray<NSDictionary *> *stats, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.spinner stopAnimating];
            self.spinner.hidden = YES;
            if (error) {
                [self ame223_preflightFailed:error.localizedDescription];
                return;
            }
            self.sectionStats = stats;
            [self.sectionRowsStack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
            for (NSDictionary *def in [DataTransferService ame224_sectionDefinitions]) {
                NSString *sid = def[@"id"];
                NSDictionary *st = nil;
                for (NSDictionary *s in stats) {
                    if ([s[@"id"] isEqualToString:sid]) { st = s; break; }
                }
                [self.sectionRowsStack addArrangedSubview:[self ame224_sectionRow:def stats:st]];
            }
            [self ame224_refreshSummary];
            NSLog(@"[ExportOps] Task224 section scan done: %lu section(s)", (unsigned long)stats.count);
        });
    }];
}

- (UIView *)ame224_sectionRow:(NSDictionary *)def stats:(nullable NSDictionary *)stats {
    NSString *sid = def[@"id"];
    UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.contentEdgeInsets = UIEdgeInsetsMake(8, 4, 8, 4);
    [row addTarget:self action:@selector(ame224_sectionToggled:)
   forControlEvents:UIControlEventTouchUpInside];
    row.accessibilityIdentifier = sid;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.image = [UIImage systemImageNamed:def[@"icon"] ?: @"doc"];
    icon.tintColor = accentColor();
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.userInteractionEnabled = NO;
    [row addSubview:icon];

    UILabel *title = [self ame223_label:localize([NSString stringWithFormat:@"dataexport.section.%@", sid], nil)
                                    font:[UIFont systemFontOfSize:15 weight:UIFontWeightMedium]
                                   color:[UIColor labelColor]];
    title.userInteractionEnabled = NO;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:title];

    UILabel *subtitle = [self ame223_label:@""
                                       font:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular]
                                      color:[UIColor secondaryLabelColor]];
    subtitle.userInteractionEnabled = NO;
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    if (stats != nil) {
        NSDictionary *ame224_show = stats;
        // Task224：instance 行显示整树规模（含五个子分区；扫描器尾部
        // instance_full 项）——引擎侧勾选 instance = 导出整树。
        if ([sid isEqualToString:Ame224SectionIdInstance]) {
            for (NSDictionary *s in self.sectionStats) {
                if ([s[@"id"] isEqualToString:@"instance_full"]) { ame224_show = s; break; }
            }
        }
        subtitle.text = [NSString stringWithFormat:localize(@"dataexport.section.counts_fmt", nil),
            (long)[ame224_show[@"files"] integerValue],
            [NSByteCountFormatter stringFromByteCount:[ame224_show[@"bytes"] longLongValue]
                                          countStyle:NSByteCountFormatterCountStyleFile]];
    }
    [row addSubview:subtitle];

    UIImageView *check = [[UIImageView alloc] init];
    check.image = [UIImage systemImageNamed:@"checkmark.circle.fill"];
    check.tintColor = accentColor();
    check.contentMode = UIViewContentModeScaleAspectFit;
    check.translatesAutoresizingMaskIntoConstraints = NO;
    check.userInteractionEnabled = NO;
    check.accessibilityIdentifier = @"ame224.check";
    [row addSubview:check];

    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [icon.widthAnchor constraintEqualToConstant:24],
        [icon.heightAnchor constraintEqualToConstant:24],
        [title.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:10],
        [title.topAnchor constraintEqualToAnchor:row.topAnchor constant:6],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.bottomAnchor constraintEqualToAnchor:row.bottomAnchor constant:-6],
        [check.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:22],
        [check.heightAnchor constraintEqualToConstant:22],
    ]];
    [self ame224_applyRowVisual:row on:[self.sectionOn[sid] boolValue]];
    return row;
}

- (void)ame224_applyRowVisual:(UIButton *)row on:(BOOL)on {
    for (UIView *sub in row.subviews) {
        if ([sub.accessibilityIdentifier isEqualToString:@"ame224.check"]) {
            sub.alpha = on ? 1.0 : 0.15;
        }
    }
    row.alpha = on ? 1.0 : 0.55;
}

- (void)ame224_sectionToggled:(UIButton *)sender {
    NSString *sid = sender.accessibilityIdentifier;
    if (sid.length == 0) return;
    BOOL now = ![self.sectionOn[sid] boolValue];
    self.sectionOn[sid] = @(now);
    // instance 勾选 = 覆盖五个实例子分区；取消 instance 不动子分区
    if (now && [sid isEqualToString:Ame224SectionIdInstance]) {
        NSArray *sub = @[Ame224SectionIdWorlds, Ame224SectionIdResourcePacks,
                         Ame224SectionIdMods, Ame224SectionIdScreenshots, Ame224SectionIdServers];
        for (NSString *s in sub) self.sectionOn[s] = @NO;
        for (UIView *row in self.sectionRowsStack.arrangedSubviews) {
            [self ame224_applyRowVisual:(UIButton *)row on:[self.sectionOn[row.accessibilityIdentifier] boolValue]];
        }
    } else {
        [self ame224_applyRowVisual:sender on:now];
    }
    [self ame224_refreshSummary];
}

- (void)ame224_refreshSummary {
    NSUInteger files = 0;
    unsigned long long bytes = 0;
    BOOL instanceFull = [self.sectionOn[Ame224SectionIdInstance] boolValue];
    if (instanceFull) {
        for (NSDictionary *st in self.sectionStats) {
            if ([st[@"id"] isEqualToString:@"instance_full"]) {
                files = [st[@"files"] unsignedIntegerValue];
                bytes = [st[@"bytes"] unsignedLongLongValue];
                break;
            }
        }
    } else {
        for (NSDictionary *st in self.sectionStats) {
            NSString *sid = st[@"id"];
            if ([sid isEqualToString:@"instance_full"] ||
                [sid isEqualToString:Ame224SectionIdInstance]) continue;
            if ([self.sectionOn[sid] boolValue]) {
                files += [st[@"files"] unsignedIntegerValue];
                bytes += [st[@"bytes"] unsignedLongLongValue];
            }
        }
    }
    _fileCount = files;
    _totalBytes = bytes;
    if (files == 0) {
        self.summaryLabel.text = localize(@"dataexport.empty", nil);
        self.startButton.enabled = NO;
        self.startButton.backgroundColor = [UIColor tertiarySystemFillColor];
        return;
    }
    self.startButton.enabled = YES;
    self.startButton.backgroundColor = accentColor();
    self.summaryLabel.text = [NSString stringWithFormat:localize(@"dataexport.selected_summary_fmt", nil),
        (unsigned long)files,
        [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile]];
}

- (void)ame223_preflightFailed:(NSString *)reason {
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.summaryLabel.text = [NSString stringWithFormat:localize(@"dataexport.failed", nil), reason];
    self.startButton.enabled = NO;
    self.startButton.backgroundColor = [UIColor tertiarySystemFillColor];
}

#pragma mark - Level

- (void)ame223_levelChanged:(UISegmentedControl *)sender {
    switch (sender.selectedSegmentIndex) {
        case 0: self.levelHintLabel.text = localize(@"dataexport.level.none.hint", nil); break;
        case 1: self.levelHintLabel.text = localize(@"dataexport.level.fast.hint", nil); break;
        default: self.levelHintLabel.text = localize(@"dataexport.level.best.hint", nil); break;
    }
}

#pragma mark - Start（注册进版本下载任务体系，阶段/文件/字节/速率/当前文件全维度）

- (void)ame223_startTapped {
    if (_fileCount == 0) return;
    UZKCompressionMethod method = UZKCompressionMethodNone;
    switch (self.levelSegment.selectedSegmentIndex) {
        case 1: method = UZKCompressionMethodDefault; break;
        case 2: method = UZKCompressionMethodBest; break;
        default: method = UZKCompressionMethodNone; break;
    }
    NSMutableArray<NSString *> *sectionIds = [NSMutableArray array];
    for (NSDictionary *def in [DataTransferService ame224_sectionDefinitions]) {
        if ([self.sectionOn[def[@"id"]] boolValue]) [sectionIds addObject:def[@"id"]];
    }
    if (sectionIds.count == 0) return;

    // Task224：协作式取消链路（下载任务 rawTask 注册，JRE 导入同款）
    NSProgress *cancelProgress = [NSProgress progressWithTotalUnitCount:1];

    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeBackup
                        resourceName:[NSString stringWithFormat:@"data-backup-%ld-%lu",
                                      (long)self.levelSegment.selectedSegmentIndex, (unsigned long)sectionIds.count]
                         displayName:localize(@"dataexport.task.name", nil)
                      downloadSource:@"local"
                             rawTask:cancelProgress
                      supportsResume:NO
                         iconURL:nil];
    if (!taskItem) return;
    NSString *taskId = taskItem.taskId;
    [manager setTaskWithId:taskId stages:@[
        [PLTaskStage stageWithTitle:@"dataexport.stage.collect" iconName:@"internaldrive"],
        [PLTaskStage stageWithTitle:@"dataexport.stage.compress" iconName:@"doc.zip"],
        [PLTaskStage stageWithTitle:@"dataexport.stage.finalize" iconName:@"checkmark.seal"],
    ]];
    taskItem.autoPresentDetail = YES;
    [manager setTaskWithId:taskId state:DownloadTaskStateDownloading];
    [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusRunning];

    self.startButton.enabled = NO;
    self.startButton.backgroundColor = [UIColor tertiarySystemFillColor];

    // ★ Task224（#12/#13）：分区选择 + 3 路并行 deflate + 单写线程有序落盘
    //   （详见 DataTransferService ame224_runBackupExport 注释）。进度全维度
    //   上报下载任务体系：阶段推进 + 文件计数 + 字节 + 速率 + ETA + 当前
    //   文件（阶段动态文案）。
    NSDate *t0 = [NSDate date];
    [[DataTransferService sharedService] ame224_runBackupExportWithMethod:method
        sectionIds:sectionIds
        cancelProgress:cancelProgress
        progress:^(NSUInteger phase, NSUInteger filesDone, NSUInteger filesTotal,
                   unsigned long long bytesDone, unsigned long long bytesTotal,
                   double bytesPerSecond, NSString *currentFile) {
            NSUInteger stageIdx = (phase == 0) ? 0 : ((phase == 1) ? 1 : 2);
            [manager updateTaskWithId:taskId currentStageIndex:(NSInteger)stageIdx];
            if (phase > 0) {
                [manager updateTaskWithId:taskId stageAtIndex:(NSInteger)(phase - 1)
                    status:PLTaskStageStatusCompleted];
                [manager updateTaskWithId:taskId stageAtIndex:(NSInteger)stageIdx status:PLTaskStageStatusRunning];
            }
            [manager updateTaskWithId:taskId
                      completedFileCount:(NSInteger)filesDone
                          totalFileCount:(NSInteger)filesTotal];
            [manager updateTaskWithId:taskId
                             progress:(filesTotal > 0) ? ((double)filesDone / (double)filesTotal) : 0.0
                         totalBytes:(int64_t)bytesTotal
                    downloadedBytes:(int64_t)bytesDone];
            [manager updateTaskWithId:taskId
                                 speed:bytesPerSecond
                estimatedTimeRemaining:(bytesPerSecond > 1.0)
                    ? (NSTimeInterval)((double)(bytesTotal - bytesDone) / bytesPerSecond) : 0.0];
            // 阶段动态详情：当前正在压缩/写入的文件（用户此前只有干百分比）
            [manager updateTaskWithId:taskId stageAtIndex:(NSInteger)stageIdx
                             progress:(filesTotal > 0) ? ((double)filesDone / (double)filesTotal) : 0.0
                              message:currentFile.lastPathComponent ?: nil];
        }
        completion:^(NSString *tmpPath, NSError *error) {
            NSTimeInterval elapsed = -[t0 timeIntervalSinceNow];
            BOOL cancelled = cancelProgress.cancelled;
            if (error) {
                [manager updateTaskWithId:taskId stageAtIndex:2
                    status:cancelled ? PLTaskStageStatusPending : PLTaskStageStatusFailed];
                [manager setTaskWithId:taskId state:cancelled ? DownloadTaskStateCancelled : DownloadTaskStateFailed];
                if (!cancelled) [manager updateTaskWithId:taskId error:error];
                NSLog(@"[ExportOps] Task224 export %@ after %.1fs: %@",
                      cancelled ? @"CANCELLED" : @"FAILED", elapsed, error.localizedDescription);
                return;
            }
            [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
            [manager updateTaskWithId:taskId stageAtIndex:1 status:PLTaskStageStatusCompleted];
            [manager updateTaskWithId:taskId stageAtIndex:2 status:PLTaskStageStatusCompleted];
            [manager setTaskWithId:taskId state:DownloadTaskStateCompleted];
            NSLog(@"[ExportOps] Task224 export done in %.1fs (%.1f MB/s avg, %lu files, %llu bytes, %lu section(s)) -> %@",
                  elapsed, (_totalBytes / 1048576.0 / MAX(elapsed, 0.001)),
                  (unsigned long)_fileCount, _totalBytes, (unsigned long)sectionIds.count,
                  tmpPath.lastPathComponent);
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *presenter = UIWindow.mainWindow.rootViewController;
                while (presenter.presentedViewController != nil) presenter = presenter.presentedViewController;
                [[DataTransferService sharedService] ame223_presentDestinationPickerForTmpPath:tmpPath
                                                                                     from:presenter];
            });
        }];
}

@end
