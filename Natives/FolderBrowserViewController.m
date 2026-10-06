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
    // 适配自定义启动器背景（毛玻璃/半透明规则与其它页一致）。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // Task224（#4）：界面风格 = 液态玻璃时，浏览器头部（导航栏）交还系统——
    // iOS 26+ 移除自定义背景后自动获得液态玻璃；native 解析时
    // LGCAdaptNavigationBar 内部自检不过即 no-op，保持既有外观。
    if (LGCIsGlassStyleActive()) {
        LGCAdaptNavigationBar(self.navigationController.navigationBar);
        NSLog(@"[ThemeOps] Task224 folder browser header handed to system glass");
    }
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
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (LGCIsGlassStyleActive()) {
        LGCAdaptNavigationBar(self.navigationController.navigationBar);
    }
}

// Task224（#4）：风格切换 → 头部重铺（液态玻璃时交还系统，native 保持）。
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

    // Task224：空态显示（重试期间提示等待，耗尽后提示空目录）
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
        self.tableView.backgroundView = ame224_empty;
    } else {
        self.tableView.backgroundView = nil;
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
