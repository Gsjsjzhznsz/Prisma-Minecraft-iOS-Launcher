#import "FolderBrowserViewController.h"
#import "BackgroundManager.h"
#import "LiquidGlassCompat.h"   // Task224（#4）：界面风格解析（文件夹浏览器头部随风格）
#import "utils.h"
#import <QuickLook/QuickLook.h>
#include <objc/runtime.h>

@interface FolderBrowserViewController () {
    NSArray<NSDictionary *> *_rows;   // {name, path, isDir, size, date}
}
@property (nonatomic, copy) NSString *currentPath;
@property (nonatomic, copy, nullable) NSURL *ame223_previewURL;
@end

@implementation FolderBrowserViewController

+ (UINavigationController *)wrappedControllerForPath:(NSString *)path {
    FolderBrowserViewController *vc = [[FolderBrowserViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.rootPath = path;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 16.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        if (sheet) {
            sheet.detents = @[UISheetPresentationControllerDetent.largeDetent];
            sheet.prefersEdgeAttachedInCompactHeight = YES;
        }
    }
    return nav;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Task229 (feedback #5: "folder opens with only a frosted overlay and the
    // folder name, nothing else"): this browser is a page-sheet modal ON TOP
    // of the game -- the launcher-wide transparency pipeline (clear view +
    // clear tableView + washed cells) over the sheet's own frosted chrome
    // left rows and even the empty-state label invisible, and the global
    // white-fill/stroke font swizzle finished the job. Opt out entirely: a
    // SOLID sheet exactly like the system Files app is the readable answer
    // for a file listing, and the sheet chrome itself already carries the
    // launcher look.
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.tableView.backgroundView = nil;
    // ★ Task228：浏览器头部"交还系统玻璃"退役（与全局栏管线一致——用户
    // 指令软件 UI 保持原样、玻璃只用于悬浮弹窗；系统玻璃渲染在本进程
    // 不可靠，Task225/228 两次实锤黑面）。头部恒走既有栏管线。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // Task224（#4）：风格切换广播——可见状态下浏览器头部跟随重铺。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame224_handleInterfaceStyleChanged)
                                                 name:LGCInterfaceStyleChangedNotification
                                               object:nil];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(actionDone)];
    // Task223：currentPath 已由 ame223_setRootAndLoad 预置（子页下钻）时优
    // 先用之；否则加载根目录。
    if (self.currentPath.length > 0) {
        [self ame223_loadPath:self.currentPath];
    } else if (self.rootPath.length > 0) {
        [self ame223_loadPath:self.rootPath];
    }
}

- (void)reapplyBackgroundEffect {
    // Task229: the browser is a SOLID sheet now (see viewDidLoad) -- the old
    // transparency reapply would wash it back to the invisible frosted state
    // on every background-effect broadcast. Reassert the solid colors.
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.tableView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    // Task228：头部不再随风格切换交还系统（见 viewDidLoad 注释）。
}

// Task228：风格切换 → 头部重铺（恒走既有栏管线，不再交还系统）。
- (void)ame224_handleInterfaceStyleChanged {
    [self reapplyBackgroundEffect];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setRootPath:(NSString *)rootPath {
    _rootPath = [rootPath copy];
    if (self.isViewLoaded) {
        [self ame223_loadPath:rootPath];
    }
}

- (void)ame223_loadPath:(NSString *)path {
    [self ame224_loadPath:path retryCount:0];
}

/// Task224：0 条目自动重试 + 错误浮出 + 空态显示。
/// 病历（10-06 latestlog.old:678-700）：mcworld 提取目录 3 次打开均
/// "loaded 0 entries"——旧代码吞掉 contentsOfDirectory 的 NSError，
/// 无法区分真空目录 / 读取失败 / 提取器竞态（目录已建、内容未落盘或
/// 落在别的 tmp 根）。修法：错误入日志；空结果退避重试（0.3s/1s/3s，
/// 用户导航离开即中止）；重试耗尽仍空 → 空态文案（真空目录语义）。
- (void)ame224_loadPath:(NSString *)path retryCount:(int)retry {
    self.currentPath = path;
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *ame224_err = nil;
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:path error:&ame224_err];
    if (ame224_err != nil) {
        NSLog(@"[FolderBrowser] Task224 contentsOfDirectory error (domain=%@ code=%ld): %@",
              ame224_err.domain, (long)ame224_err.code, ame224_err.localizedDescription);
    }
    for (NSString *name in names) {
        NSString *full = [path stringByAppendingPathComponent:name];
        BOOL isDir = NO;
        NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
        isDir = [[attrs fileType] isEqualToString:NSFileTypeDirectory];
        [rows addObject:@{
            @"name": name,
            @"path": full,
            @"isDir": @(isDir),
            @"size": @(attrs.fileSize),
            @"date": attrs.fileModificationDate ?: [NSDate distantPast],
        }];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        BOOL aDir = [a[@"isDir"] boolValue];
        BOOL bDir = [b[@"isDir"] boolValue];
        if (aDir != bDir) return aDir ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] caseInsensitiveCompare:b[@"name"]];
    }];
    _rows = rows;
    // 面包屑式标题：根目录用目录名；下钻后显示「根名 / 子目录」。
    NSString *rootName = self.rootPath.lastPathComponent ?: @"";
    if (rootName.length == 0) rootName = @"/";
    if ([path isEqualToString:self.rootPath]) {
        self.title = rootName;
    } else {
        NSString *rel = [self ame223_relativeDisplayOf:path];
        self.title = [NSString stringWithFormat:@"%@ / %@", rootName, rel];
    }
    [self.tableView reloadData];
    NSLog(@"[FolderBrowser] Task223 loaded %lu entries (retry=%d): %@",
          (unsigned long)rows.count, retry, path);

    // Task224：空结果退避重试（提取器竞态窗口）
    if (rows.count == 0 && retry < 3) {
        NSTimeInterval ame224_delay = (retry == 0) ? 0.3 : ((retry == 1) ? 1.0 : 3.0);
        NSString *ame224_target = path;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ame224_delay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (![strongSelf.currentPath isEqualToString:ame224_target]) return;
            NSLog(@"[FolderBrowser] Task224 empty result auto-retry #%d after %.1fs",
                  retry + 1, ame224_delay);
            [strongSelf ame224_loadPath:ame224_target retryCount:retry + 1];
        });
    }

    // Task224：空态显示。Task229：空态标签从 backgroundView 迁至
    // tableHeaderView——makeViewControllerTransparent（其他页面仍在用）对
    // UITableViewController 会把 backgroundView 清成 nil，这正是装机上
    // 空态文字消失在毛玻璃后面的机制。header 只归本类管，且同样豁免
    // 全局描边字体（白字浅底会隐形）。
    if (rows.count == 0) {
        UILabel *ame224_empty = [[UILabel alloc] init];
        ame224_empty.numberOfLines = 0;
        ame224_empty.textAlignment = NSTextAlignmentCenter;
        ame224_empty.textColor = [UIColor secondaryLabelColor];
        ame224_empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        ame224_empty.text = (retry < 3)
            ? localize(@"folderbrowser.empty.retrying", nil)
            : localize(@"folderbrowser.empty.title", nil);
        [ame224_empty sizeToFit];
        CGRect ame229_hf = CGRectMake(0, 0, self.tableView.bounds.size.width,
                                      MAX(64.0, ame224_empty.bounds.size.height + 40.0));
        UIView *ame229_hv = [[UIView alloc] initWithFrame:ame229_hf];
        ame224_empty.frame = CGRectMake(16.0,
                                        (ame229_hf.size.height - ame224_empty.bounds.size.height) / 2.0,
                                        ame229_hf.size.width - 32.0,
                                        ame224_empty.bounds.size.height);
        [ame229_hv addSubview:ame224_empty];
        extern void ame229_labelSetStrokeExempt(UILabel *, BOOL);
        ame229_labelSetStrokeExempt(ame224_empty, YES);
        self.tableView.tableHeaderView = ame229_hv;
    } else {
        self.tableView.tableHeaderView = nil;
    }
}

- (NSString *)ame223_relativeDisplayOf:(NSString *)path {
    if (![path hasPrefix:self.rootPath]) return path.lastPathComponent;
    NSString *rel = [path substringFromIndex:self.rootPath.length];
    if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
    return rel;
}

- (void)actionDone {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table view data source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ame223file"];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ame223file"];
    }
    NSDictionary *row = _rows[indexPath.row];
    BOOL isDir = [row[@"isDir"] boolValue];
    cell.textLabel.text = row[@"name"];
    // Task229: exempt from the global white-fill/stroke font (solid cells,
    // light background -- stroke paint would white them out).
    extern void ame229_labelSetStrokeExempt(UILabel *, BOOL);
    ame229_labelSetStrokeExempt(cell.textLabel, YES);
    ame229_labelSetStrokeExempt(cell.detailTextLabel, YES);
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    if (isDir) {
        cell.imageView.image = [UIImage systemImageNamed:@"folder.fill"];
        cell.imageView.tintColor = [UIColor systemBlueColor];
        NSUInteger count = [self ame223_childCountOfPath:row[@"path"]];
        cell.detailTextLabel.text = [NSString stringWithFormat:localize(@"folderbrowser.item_count", nil), (unsigned long)count];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        NSString *ext = [row[@"name"] pathExtension];
        UIImage *icon = nil;
        if (ext.length > 0) {
            icon = [UIImage systemImageNamed:[NSString stringWithFormat:@"doc.%@", ext.lowercaseString]];
        }
        if (icon == nil) icon = [UIImage systemImageNamed:@"doc"];
        cell.imageView.image = icon;
        cell.imageView.tintColor = [UIColor secondaryLabelColor];
        unsigned long long size = [row[@"size"] unsignedLongLongValue];
        cell.detailTextLabel.text = [NSByteCountFormatter stringFromByteCount:size
                                                                  countStyle:NSByteCountFormatterCountStyleFile];
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    return cell;
}

- (NSUInteger)ame223_childCountOfPath:(NSString *)path {
    return [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil].count;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = _rows[indexPath.row];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([row[@"isDir"] boolValue]) {
        FolderBrowserViewController *child = [[FolderBrowserViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [child ame223_setRootAndLoad:self.rootPath current:row[@"path"]];
        [self.navigationController pushViewController:child animated:YES];
    } else {
        // 文件：QLPreviewController 快速查看（图片/文本/PDF/zip 列表）。
        NSURL *fileURL = [NSURL fileURLWithPath:row[@"path"]];
        self.ame223_previewURL = fileURL;
        QLPreviewController *ql = [[QLPreviewController alloc] init];
        ql.dataSource = self;
        [self.navigationController presentViewController:ql animated:YES completion:nil];
    }
}

/// 面包屑根与当前目录一起注入（子页下钻用；子页尚未 loadView，直接预置
/// 后由 viewDidLoad 正常加载，避免 rootPath 懒加载语义双载）。
- (void)ame223_setRootAndLoad:(NSString *)root current:(NSString *)current {
    _rootPath = [root copy];
    _currentPath = [current copy];
}

#pragma mark - Swipe actions（分享）

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
        trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = _rows[indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *share = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
                            title:localize(@"global.share", nil)
                          handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
        NSArray *items = @[row[@"name"], [NSURL fileURLWithPath:row[@"path"]]];
        UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:items applicationActivities:nil];
        avc.popoverPresentationController.sourceView = view ?: weakSelf.view;
        avc.popoverPresentationController.sourceRect = view ? view.bounds : weakSelf.view.bounds;
        [weakSelf presentViewController:avc animated:YES completion:nil];
        done(YES);
    }];
    share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
    share.backgroundColor = [UIColor systemBlueColor];
    return [UISwipeActionsConfiguration configurationWithActions:@[share]];
}

#pragma mark - QLPreviewControllerDataSource

- (NSInteger)numberOfPreviewItemsInPreviewController:(QLPreviewController *)controller {
    return 1;
}

- (id<QLPreviewItem>)previewController:(QLPreviewController *)controller previewItemAtIndex:(NSInteger)index {
    return self.ame223_previewURL ?: (id<QLPreviewItem>)[NSURL fileURLWithPath:self.currentPath ?: @"/"];
}

#include <objc/runtime.h>

@end
