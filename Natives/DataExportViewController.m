#import "DataExportViewController.h"
#import "BackgroundManager.h"
#import "DataTransferService.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStage.h"
#import "utils.h"
#import "LauncherPreferences.h"   // accentColor()（同 AboutViewController 先例）
#import "UnzipKit.h"   // 仓内约定：CMake include 路径含 external/UnzipKit（同 ModpackImportService）

@interface DataExportViewController () {
    NSUInteger _fileCount;
    unsigned long long _totalBytes;
}
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *summaryLabel;
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

    [self ame223_preflight];
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

#pragma mark - Preflight

- (void)ame223_preflight {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *home = @(getenv("POJAV_HOME"));
        if (home.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self ame223_preflightFailed:@"POJAV_HOME unset"]; });
            return;
        }
        NSUInteger files = 0;
        unsigned long long bytes = 0;
        DataTransferService *dts = [DataTransferService sharedService];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSDirectoryEnumerator *e = [fm enumeratorAtPath:home];
        NSString *rel;
        while ((rel = [e nextObject])) {
            if ([dts ame217_shouldSkipExportEntry:rel.lastPathComponent]) {
                [e skipDescendants];
                continue;
            }
            NSString *abs = [home stringByAppendingPathComponent:rel];
            NSDictionary *attrs = [fm attributesOfItemAtPath:abs error:nil];
            if (attrs && ![attrs.fileType isEqualToString:NSFileTypeDirectory]) {
                files++;
                bytes += attrs.fileSize;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            _fileCount = files;
            _totalBytes = bytes;
            [self.spinner stopAnimating];
            self.spinner.hidden = YES;
            if (files == 0) {
                self.summaryLabel.text = localize(@"dataexport.empty", nil);
                self.startButton.enabled = NO;
                self.startButton.backgroundColor = [UIColor tertiarySystemFill];
                return;
            }
            self.summaryLabel.text = [NSString stringWithFormat:localize(@"dataexport.summary.body", nil),
                (unsigned long)files,
                [NSByteCountFormatter stringFromByteCount:bytes countStyle:NSByteCountFormatterCountStyleFile]];
            NSLog(@"[DataExport] Task223 preflight: %lu files, %llu bytes", (unsigned long)files, bytes);
        });
    });
}

- (void)ame223_preflightFailed:(NSString *)reason {
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    self.summaryLabel.text = [NSString stringWithFormat:localize(@"dataexport.failed", nil), reason];
    self.startButton.enabled = NO;
    self.startButton.backgroundColor = [UIColor tertiarySystemFill];
}

#pragma mark - Level

- (void)ame223_levelChanged:(UISegmentedControl *)sender {
    switch (sender.selectedSegmentIndex) {
        case 0: self.levelHintLabel.text = localize(@"dataexport.level.none.hint", nil); break;
        case 1: self.levelHintLabel.text = localize(@"dataexport.level.fast.hint", nil); break;
        default: self.levelHintLabel.text = localize(@"dataexport.level.best.hint", nil); break;
    }
}

#pragma mark - Start（注册进版本下载任务体系）

- (void)ame223_startTapped {
    if (_fileCount == 0) return;
    UZKCompressionMethod method = UZKCompressionMethodNone;
    switch (self.levelSegment.selectedSegmentIndex) {
        case 1: method = UZKCompressionMethodDefault; break;
        case 2: method = UZKCompressionMethodBest; break;
        default: method = UZKCompressionMethodNone; break;
    }

    // 注册任务（版本下载同款体系）+ 自动跳转任务详情页（进度显示交给
    // 下载任务的既有 UI：阶段、文件计数、字节数）。
    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    DownloadTaskItem *taskItem = [manager
        registerTaskWithResourceType:DownloadTaskResourceTypeBackup
                        resourceName:[NSString stringWithFormat:@"data-backup-%@", @(self.levelSegment.selectedSegmentIndex)]
                         displayName:localize(@"dataexport.task.name", nil)
                      downloadSource:@"local"
                             rawTask:nil
                      supportsResume:NO
                         iconURL:nil];
    if (!taskItem) return;
    NSString *taskId = taskItem.taskId;
    [manager setTaskWithId:taskId stages:@[
        [PLTaskStage stageWithTitle:@"dataexport.stage.collect" iconName:@"internaldrive"],
        [PLTaskStage stageWithTitle:@"dataexport.stage.compress" iconName:@"doc.zip"],
    ]];
    taskItem.autoPresentDetail = YES;
    [manager setTaskWithId:taskId state:DownloadTaskStateDownloading];
    [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusRunning];

    self.startButton.enabled = NO;
    self.startButton.backgroundColor = [UIColor tertiarySystemFill];

    // ★ Task223 速度根修：并发读 + 串行写流水线（详见 DataTransferService
    //   ame223_runPipelinedBackupExport 注释）。进度回报双维度：文件计数 +
    //   已写字节。
    NSDate *t0 = [NSDate date];
    [[DataTransferService sharedService] ame223_runPipelinedBackupExportWithMethod:method
        progress:^(NSUInteger done, NSUInteger total, unsigned long long writtenBytes) {
            [manager updateTaskWithId:taskId
                     completedFileCount:(NSInteger)done
                         totalFileCount:(NSInteger)total];
            [manager updateTaskWithId:taskId
                             progress:(total > 0) ? ((double)done / (double)total) : 0
                         totalBytes:(int64_t)_totalBytes
                    downloadedBytes:(int64_t)writtenBytes];
        }
        stageAdvance:^(NSUInteger stage) {
            [manager updateTaskWithId:taskId
                          stageAtIndex:(NSInteger)stage
                                status:(stage == 0) ? PLTaskStageStatusCompleted : PLTaskStageStatusRunning];
        }
        completion:^(NSString *tmpPath, NSError *error) {
            NSTimeInterval elapsed = -[t0 timeIntervalSinceNow];
            if (error) {
                [manager updateTaskWithId:taskId stageAtIndex:1 status:PLTaskStageStatusFailed];
                [manager updateTaskWithId:taskId error:error];
                [manager setTaskWithId:taskId state:DownloadTaskStateFailed];
                NSLog(@"[DataExport] Task223 export FAILED after %.1fs: %@", elapsed, error.localizedDescription);
                return;
            }
            [manager updateTaskWithId:taskId stageAtIndex:1 status:PLTaskStageStatusCompleted];
            [manager setTaskWithId:taskId state:DownloadTaskStateCompleted];
            NSLog(@"[DataExport] Task223 export done in %.1fs (%.1f MB/s avg) -> %@",
                  elapsed, (_totalBytes / 1048576.0 / MAX(elapsed, 0.001)), tmpPath.lastPathComponent);
            // 收尾：交给系统文件选择器定落点（move 语义）。从当前最顶层 VC
            // 呈现（用户可能已离开本页跟随任务详情页）。
            dispatch_async(dispatch_get_main_queue(), ^{
                UIViewController *presenter = UIWindow.mainWindow.rootViewController;
                while (presenter.presentedViewController != nil) presenter = presenter.presentedViewController;
                [[DataTransferService sharedService] ame223_presentDestinationPickerForTmpPath:tmpPath
                                                                                     from:presenter];
            });
        }];
}

@end
