//
//  AmePluginListViewController.m
//  Amethyst
//
//  Task318：插件管理列表页实现（PrismaUI 组件 + AmeNativeMenu 菜单家法 +
//  NMToast 反馈家法；文件选择器走 AccountListViewController 的
//  initForOpeningContentTypes 先例）。
//

#import "AmePluginListViewController.h"
#import "AmePluginManager.h"
#import "AmePluginRuntime.h"
#import "AmePluginDetailViewController.h"
#import "AmePluginRepoViewController.h"
#import "AmeNativeMenu.h"
#import "NMToast.h"
#import "PrismaUI.h"
#import "utils.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface AmePluginListViewController ()
@property(nonatomic, copy) NSArray<AmePluginManifest *> *ame318_plugins;
@end

@implementation AmePluginListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"ame318.page.title", nil);
    [self.tableView registerClass:[PrismaListCell class]
           forCellReuseIdentifier:@"ame318.list.cell"];
    self.tableView.separatorInset = UIEdgeInsetsMake(0, [PrismaTheme spacingL], 0, 0);

    // 右上角 "+"：仓库 / 导入（菜单走 AmeNativeMenu 家法；确认类交互留给
    // UIAlertController——Task240 分工边界）。
    UIBarButtonItem *add = [[UIBarButtonItem alloc]
                            initWithImage:[UIImage systemImageNamed:@"plus"]
                            style:UIBarButtonItemStylePlain
                            target:self
                            action:@selector(ame318_showAddMenu)];
    self.navigationItem.rightBarButtonItem = add;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ame318_rescan];
}

- (void)ame318_rescan {
    self.ame318_plugins = [[AmePluginManager shared] installedPlugins];
    [self.tableView reloadData];
}

#pragma mark - 菜单

- (void)ame318_showAddMenu {
    [AmeNativeMenu ame240_presentMenuWithTitle:nil
                                     dictItems:@[
        @{@"title": localize(@"ame318.list.repo", nil),
          @"systemImage": @"shippingbox.fill",
          @"handler": ^{ [self ame318_openRepo]; }},
        @{@"title": localize(@"ame318.list.import", nil),
          @"systemImage": @"square.and.arrow.down",
          @"handler": ^{ [self ame318_pickZip]; }},
    ]                                     sourceView:self.view];
}

- (void)ame318_openRepo {
    AmePluginRepoViewController *repo = [[AmePluginRepoViewController alloc] init];
    [self.navigationController pushViewController:repo animated:YES];
}

- (void)ame318_pickZip {
    // UTTypeZIP（UniformTypeIdentifiers，iOS 14+；框架已在 CMake 链接）。
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP]];
    picker.allowsMultipleSelection = NO;
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1; // 仓库入口
    return MAX(1, (NSInteger)self.ame318_plugins.count); // 空态占 1 行
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return nil;
    return localize(@"ame318.list.section.installed", nil);
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PrismaListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ame318.list.cell"
                                                          forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.showsChevron = YES;
    if (indexPath.section == 0) {
        cell.prismaTitle = localize(@"ame318.list.repo", nil);
        cell.prismaSubtitle = localize(@"ame318.list.repo_detail", nil);
        cell.prismaIconName = @"shippingbox.fill";
        return cell;
    }
    if (indexPath.row >= (NSInteger)self.ame318_plugins.count) {
        // 空态（不可点）。
        cell.prismaTitle = localize(@"ame318.list.empty", nil);
        cell.prismaSubtitle = localize(@"ame318.list.empty_hint", nil);
        cell.prismaIconName = @"puzzlepiece.extension";
        cell.showsChevron = NO;
        return cell;
    }
    AmePluginManifest *m = self.ame318_plugins[indexPath.row];
    NSString *state;
    if ([AmePluginRuntime isRunning:m.pluginId]) {
        state = localize(@"ame318.list.state.on", nil);
    } else if ([[AmePluginManager shared] isEnabled:m.pluginId]) {
        state = [AmePluginRuntime lastErrorForPlugin:m.pluginId]
            ? localize(@"ame318.list.state.error", nil)
            : localize(@"ame318.list.state.enabled", nil);
    } else {
        state = localize(@"ame318.list.state.off", nil);
    }
    cell.prismaTitle = m.name;
    cell.prismaSubtitle = [NSString stringWithFormat:@"v%@ · %@", m.version, state];
    cell.prismaIconName = @"puzzlepiece.extension";
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0) {
        [self ame318_openRepo];
        return;
    }
    if (indexPath.row >= (NSInteger)self.ame318_plugins.count) return;
    AmePluginManifest *m = self.ame318_plugins[indexPath.row];
    AmePluginDetailViewController *detail = [[AmePluginDetailViewController alloc]
                                             initWithPluginId:m.pluginId];
    [self.navigationController pushViewController:detail animated:YES];
}

#pragma mark - 导入回调

- (void)documentPicker:(UIDocumentPickerViewController *)controller
didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    // 安全范围 URL：先 startAccessingSecurityScopedResource 再读。
    NSURL *url = urls.firstObject;
    [url startAccessingSecurityScopedResource];
    @try {
        NSString *path = url.path;
        AmePluginManifest *peek = [[AmePluginManager shared] peekManifestOfZip:path error:nil];
        NSError *error = [[AmePluginManager shared] installFromZip:path];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                [NMToast showMessage:[NSString stringWithFormat:
                    localize(@"ame318.toast.install_failed", nil),
                    error.localizedDescription ?: @""]];
            } else {
                AmePluginManifest *m = peek;
                if (!m) m = self.ame318_plugins.firstObject;
                [NMToast showMessage:[NSString stringWithFormat:
                    localize(@"ame318.toast.installed", nil), m.name ?: @""]];
            }
            [self ame318_rescan];
        });
    } @finally {
        [url stopAccessingSecurityScopedResource];
    }
}

@end
