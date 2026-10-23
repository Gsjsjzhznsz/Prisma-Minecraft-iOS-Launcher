//
//  AmePluginRepoViewController.m
//  Amethyst
//
//  Task318：插件仓库页实现。
//  数据面 = bundle Resources/BuiltinPlugins/*.zip（Makefile payload 随包拷贝）；
//  安装前展示权限要求（peek manifest），确认走 UIAlertController。
//

#import "AmePluginRepoViewController.h"
#import "AmePluginManager.h"
#import "AmePluginPermissions.h"
#import "AmePluginRuntime.h"
#import "PrismaUI.h"
#import "NMToast.h"
#import "utils.h"

@interface AmePluginRepoViewController ()
/// 仓库条目（zip 路径 + 解析出的清单）。
@property(nonatomic, copy) NSArray<NSString *> *ame318_packPaths;
@property(nonatomic, copy) NSArray<AmePluginManifest *> *ame318_manifests;
@end

@implementation AmePluginRepoViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"ame318.repo.title", nil);
    [self.tableView registerClass:[PrismaListCell class]
           forCellReuseIdentifier:@"ame318.repo.cell"];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, [PrismaTheme spacingL], 0, 0);
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ame318_rescan];
}

- (void)ame318_rescan {
    self.ame318_packPaths = [[AmePluginManager shared] builtinPackPaths];
    NSMutableArray<AmePluginManifest *> *manifests = [NSMutableArray array];
    for (NSString *path in self.ame318_packPaths) {
        AmePluginManifest *m = [[AmePluginManager shared] peekManifestOfZip:path error:nil];
        [manifests addObject:m ?: [AmePluginManifest new]];
    }
    self.ame318_manifests = [manifests copy];
    [self.tableView reloadData];
}

#pragma mark - 数据源

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return MAX(1, (NSInteger)self.ame318_packPaths.count);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PrismaListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ame318.repo.cell"
                                                          forIndexPath:indexPath];
    cell.accessoryView = nil;
    if (indexPath.row >= (NSInteger)self.ame318_packPaths.count) {
        cell.prismaTitle = localize(@"ame318.repo.empty", nil);
        cell.prismaSubtitle = nil;
        cell.prismaIconName = @"shippingbox";
        cell.showsChevron = NO;
        return cell;
    }
    AmePluginManifest *m = self.ame318_manifests[indexPath.row];
    cell.prismaTitle = m.name ?: localize(@"ame318.repo.unnamed", nil);
    cell.prismaSubtitle = [NSString stringWithFormat:@"v%@ · %@", m.version ?: @"?", m.pluginDescription ?: @""];
    cell.prismaIconName = @"puzzlepiece.extension";

    if ([[AmePluginManager shared] isInstalled:m.pluginId]) {
        // 已安装：对勾标示（重装走行点按确认流的"重新安装"语义）。
        cell.showsChevron = YES;
    } else {
        cell.showsChevron = YES;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.ame318_packPaths.count) return;
    [self ame318_confirmInstallAtIndex:indexPath.row];
}

#pragma mark - 安装流

- (void)ame318_confirmInstallAtIndex:(NSUInteger)index {
    if (index >= self.ame318_packPaths.count) return;
    NSString *zipPath = self.ame318_packPaths[index];
    AmePluginManifest *m = self.ame318_manifests[index];
    if (!m.pluginId.length) return; // 清单坏包不进确认流

    // 权限要求全列（中危/高危带级差提示由详情页承担，这里列出标题即可）。
    NSMutableArray<NSString *> *permTitles = [NSMutableArray array];
    for (NSString *perm in m.permissions) {
        [permTitles addObject:[AmePluginPermissions localizedTitleForPermission:perm]];
    }
    NSString *permSummary = permTitles.count
        ? [permTitles componentsJoinedByString:@"、"]
        : localize(@"ame318.repo.no_perms", nil);
    BOOL reinstall = [[AmePluginManager shared] isInstalled:m.pluginId];

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"ame318.repo.confirm.title", nil)
                         message:[NSString stringWithFormat:
                                  localize(@"ame318.repo.confirm.msg", nil),
                                  m.name ?: m.pluginId, permSummary]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:
                      reinstall ? localize(@"ame318.repo.reinstall", nil)
                                : localize(@"ame318.repo.install", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *action) {
        NSError *error = [[AmePluginManager shared] installFromZip:zipPath];
        if (error) {
            [NMToast showMessage:[NSString stringWithFormat:
                localize(@"ame318.toast.install_failed", nil),
                error.localizedDescription ?: @""]];
        } else {
            [NMToast showMessage:[NSString stringWithFormat:
                localize(@"ame318.toast.installed", nil), m.name ?: m.pluginId]];
            // 覆盖重装后保持旧启停态；新装的插件默认停用（用户到详情页显式开启）。
            if ([AmePluginRuntime isRunning:m.pluginId]) {
                [AmePluginRuntime restartPlugin:m.pluginId];
            }
        }
        [self ame318_rescan];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
