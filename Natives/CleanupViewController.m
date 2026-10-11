//
//  CleanupViewController.m
//  AngelAuraAmethyst
//
//  ★ Task255（清单 6）：清理垃圾中心。
//  扫描并清理：
//    ① 启动器日志（latestlog 历史/old、fatal_trace、terracotta 运行日志；
//       在用的 latestlog.txt 永不触碰）；
//    ② MC 日志（共享根与版本隔离 game 目录下的 logs/、crash-reports/、
//       hs_err_pid*.log、debug.log）；
//    ③ 无引用版本（versions/ 中存在但无任何实例 lastVersionId 引用的
//       版本目录，逐个确认删除——与 Task255 deleteProfile 连带删除同口径）。
//  设计约束：只删"可再生数据"（日志/崩溃报告/无引用版本），绝不触碰
//  saves/、资源库、assets、libraries 等耗时下载资产。
//

#import "CleanupViewController.h"
#import "PLProfiles.h"
#import "utils.h"

// 行模型：title / detail / cleanupBlock（点击执行，已含确认弹窗）
@interface CleanupViewController ()
@property(nonatomic, copy) NSArray<NSDictionary *> *ame255_rows;
@end

@implementation CleanupViewController

#pragma mark - Path helpers

/// 游戏/启动器共享根（POJAV_HOME；Task226 起共享根与 default 实例同源）。
+ (NSString *)ame255_home {
    const char *home = getenv("POJAV_HOME");
    if (home != NULL && home[0] != '\0') return [NSString stringWithUTF8String:home];
    return NSTemporaryDirectory();
}

/// 递归目录大小。
+ (unsigned long long)ame255_sizeOfPath:(NSString *)path {
    unsigned long long total = 0;
    NSDirectoryEnumerator *en = [NSFileManager.defaultManager enumeratorAtPath:path];
    NSString *rel;
    while ((rel = [en nextObject])) {
        NSDictionary *attrs = [NSFileManager.defaultManager
            attributesOfItemAtPath:[path stringByAppendingPathComponent:rel] error:nil];
        total += [attrs fileSize];
    }
    return total;
}

/// 目录下全部文件（不含子目录本身），可选扩展名/前缀过滤。
+ (NSArray<NSString *> *)ame255_filesInDir:(NSString *)dir
                                 pathPrefix:(NSArray<NSString *> *)prefixes {
    NSMutableArray<NSString *> *files = [NSMutableArray array];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:dir error:nil];
    for (NSString *e in entries) {
        NSString *full = [dir stringByAppendingPathComponent:e];
        BOOL isDir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] || isDir) continue;
        BOOL match = (prefixes.count == 0);
        for (NSString *p in prefixes) {
            if ([e hasPrefix:p] || [e hasSuffix:p]) { match = YES; break; }
        }
        if (match) [files addObject:full];
    }
    return files;
}

/// MC 侧日志类垃圾全集：实例根（GAME_DIR）+ 共享根（HOME 兜底）+ 每个版本
/// 隔离 game 目录。★ Task255 r2 路径根修正：真机 MC 日志真身在实例根
/// （instances/<当前>/logs、crash-reports —— 装机 latestlog.txt:7508 实证
/// crash-reports 落实例内），POJAV_GAME_DIR 即实例根软链；POJAV_HOME 根仅
/// 旧版布局兜底。版本隔离 game 目录同样挂 GAME_DIR/versions/*/game。
+ (NSMutableArray<NSString *> *)ame255_mcLogPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    const char *gameDir = getenv("POJAV_GAME_DIR");
    NSString *instanceRoot = (gameDir != NULL && gameDir[0] != '\0')
        ? [NSString stringWithUTF8String:gameDir] : nil;
    NSString *home = [self ame255_home];
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if (instanceRoot != nil) [roots addObject:instanceRoot];
    if (home != nil && ![home isEqualToString:instanceRoot]) [roots addObject:home];
    for (NSString *root in @[instanceRoot ?: home]) {
        if (root == nil) continue;
        NSString *versionsDir = [root stringByAppendingPathComponent:@"versions"];
        NSArray<NSString *> *vdirs = [NSFileManager.defaultManager
            contentsOfDirectoryAtPath:versionsDir error:nil];
        for (NSString *vd in vdirs) {
            NSString *game = [versionsDir stringByAppendingPathComponent:
                [NSString stringWithFormat:@"%@/game", vd]];
            BOOL isDir = NO;
            if ([NSFileManager.defaultManager fileExistsAtPath:game isDirectory:&isDir] && isDir) {
                [roots addObject:game];
            }
        }
    }
    for (NSString *root in roots) {
        [paths addObjectsFromArray:[self ame255_filesInDir:[root stringByAppendingPathComponent:@"logs"]
                                               pathPrefix:@[@".log", @".txt", @".gz"]]];
        [paths addObjectsFromArray:[self ame255_filesInDir:[root stringByAppendingPathComponent:@"crash-reports"]
                                               pathPrefix:@[@".txt", @".log"]]];
        [paths addObjectsFromArray:[self ame255_filesInDir:root
                                               pathPrefix:@[@"hs_err_pid", @"debug.log", @"latest.log"]]];
    }
    return paths;
}

/// 启动器侧日志垃圾全集（在用的 latestlog.txt 永不触碰）。
+ (NSMutableArray<NSString *> *)ame255_launcherLogPaths {
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    NSString *home = [self ame255_home];
    [paths addObjectsFromArray:[self ame255_filesInDir:home
                                           pathPrefix:@[@"latestlog.old", @"latestlog.1", @"latestlog.2", @"latestlog.3",
                                                        /* ★ Task255：崩溃会话另存轮（main.m init_redirectStdio 同源） */
                                                        @"latestlog.crash"]]];
    NSString *fatal = [home stringByAppendingPathComponent:@"fatal_trace.txt"];
    if ([NSFileManager.defaultManager fileExistsAtPath:fatal]) [paths addObject:fatal];
    // Terracotta 运行日志（Documents/terracotta，与 TerracottaManager 初始化同源）
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: home];
    NSString *tcLog = [docs stringByAppendingPathComponent:@"terracotta/terracotta.log"];
    if ([NSFileManager.defaultManager fileExistsAtPath:tcLog]) [paths addObject:tcLog];
    return paths;
}

#pragma mark - Row building

- (void)ame255_reloadRows {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];

        // ① 启动器日志
        NSArray *ame255_launcher = [CleanupViewController ame255_launcherLogPaths];
        if (ame255_launcher.count > 0) {
            unsigned long long sz = 0;
            for (NSString *p in ame255_launcher) sz += [CleanupViewController ame255_sizeOfPath:p];
            [rows addObject:@{
                @"title": localize(@"cleanup.launcher_logs", @"启动器日志"),
                @"detail": [NSString stringWithFormat:localize(@"cleanup.row_detail", @"%lu 个文件 · %@"),
                            (unsigned long)ame255_launcher.count,
                            [NSByteCountFormatter stringFromByteCount:sz countStyle:NSByteCountFormatterCountStyleMemory]],
                @"paths": ame255_launcher,
                @"confirm": localize(@"cleanup.launcher_logs.confirm", @"删除全部历史日志？正在使用的 latestlog.txt 不受影响。"),
            }];
        }

        // ② MC 日志 / 崩溃报告
        NSArray *ame255_mc = [CleanupViewController ame255_mcLogPaths];
        if (ame255_mc.count > 0) {
            unsigned long long sz = 0;
            for (NSString *p in ame255_mc) sz += [CleanupViewController ame255_sizeOfPath:p];
            [rows addObject:@{
                @"title": localize(@"cleanup.mc_logs", @"MC 日志与崩溃报告"),
                @"detail": [NSString stringWithFormat:localize(@"cleanup.row_detail", @"%lu 个文件 · %@"),
                            (unsigned long)ame255_mc.count,
                            [NSByteCountFormatter stringFromByteCount:sz countStyle:NSByteCountFormatterCountStyleMemory]],
                @"paths": ame255_mc,
                @"confirm": localize(@"cleanup.mc_logs.confirm", @"删除全部 MC 日志与崩溃报告？（仅删日志类文件，不影响存档与资源）"),
            }];
        }

        // ③ 无引用版本（扫描器注入；逐个删除）
        if (self.ame255_versionScanner != nil) {
            for (NSDictionary *v in self.ame255_versionScanner()) {
                if ([v[@"referenced"] boolValue]) continue;   // 有实例引用：不可清理
                if (![v[@"jsonOK"] boolValue]) continue;      // 非正式版本目录：跳过
                NSString *vid = v[@"id"];
                unsigned long long sz = [v[@"sizeBytes"] unsignedLongLongValue];
                NSString *path = v[@"path"];
                [rows addObject:@{
                    @"title": [NSString stringWithFormat:localize(@"cleanup.orphan_row", @"无引用版本：%@"),
                               [vid isKindOfClass:[NSString class]] && vid.length > 0 ? vid : @"?"],
                    @"detail": [NSByteCountFormatter stringFromByteCount:sz countStyle:NSByteCountFormatterCountStyleMemory],
                    @"paths": @[path],
                    @"confirm": [NSString stringWithFormat:
                        localize(@"cleanup.orphan_confirm", @"删除无引用版本「%@」及其隔离数据目录？（Task242 隔离的 game 目录一并删除，存档不保留）"), vid],
                }];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.ame255_rows = rows;
            [self.tableView reloadData];
        });
    });
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"cleanup.title", @"清理垃圾");
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:localize(@"cleanup.close", @"关闭")
                style:UIBarButtonItemStylePlain
               target:self action:@selector(ame255_close)];
    if (@available(iOS 13.0, *)) {
        self.navigationItem.rightBarButtonItem.tintColor = [UIColor labelColor];
    }
    [self ame255_reloadRows];
    NSLog(@"[Cleanup] Task255: cleanup center opened");
}

- (void)ame255_close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)self.ame255_rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *reuse = @"CleanupRow";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:reuse];
    if (cell == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
        if (@available(iOS 13.0, *)) {
            cell.textLabel.textColor = [UIColor labelColor];
            cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        }
        cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    }
    NSDictionary *row = self.ame255_rows[indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.detailTextLabel.text = row[@"detail"];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:18];
        cell.imageView.image = [UIImage systemImageNamed:@"trash" withConfiguration:cfg];
        cell.imageView.tintColor = [UIColor systemRedColor];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.ame255_rows[indexPath.row];
    NSArray<NSString *> *paths = row[@"paths"];
    if (paths.count == 0) return;

    UIAlertController *confirm = [UIAlertController
        alertControllerWithTitle:row[@"title"]
                         message:row[@"confirm"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                                style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_306", nil)
                                                style:UIAlertActionStyleDestructive
                                              handler:^(__unused UIAlertAction *a) {
        NSError *lastError = nil;
        NSUInteger deleted = 0;
        unsigned long long freed = 0;
        for (NSString *p in paths) {
            unsigned long long sz = [CleanupViewController ame255_sizeOfPath:p];
            if ([NSFileManager.defaultManager removeItemAtPath:p error:&lastError]) {
                deleted++;
                freed += sz;
            }
        }
        NSLog(@"[Cleanup] Task255: deleted %lu path(s), freed %@ (last error: %@)",
              (unsigned long)deleted,
              [NSByteCountFormatter stringFromByteCount:freed countStyle:NSByteCountFormatterCountStyleMemory],
              lastError.localizedDescription ?: @"none");
        [self ame255_reloadRows];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

@end
