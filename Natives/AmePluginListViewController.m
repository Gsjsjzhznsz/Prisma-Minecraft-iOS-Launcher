//
//  AmePluginListViewController.m
//  Amethyst
//
//  Task318：插件管理列表页实现（PrismaUI 组件 + AmeNativeMenu 菜单家法 +
//  NMToast 反馈家法；文件选择器走 AccountListViewController 的
//  initForOpeningContentTypes 先例）。
//
//  ★ Task329（用户复诉"插件还是无法使用"根修）：宿主可用性补面 ——
//    ①列表页重构四分区：已安装插件（行内启停开关，原生 UISwitch =
//    圆形旋钮，失传构建自绘开关的方块旋钮病灶一并根治）/ 插件贡献的
//    启动器行（registerRow 注册表面，插件效果从此有可见落点）/ 关于
//    （API 版本单一事实源，失传构建"关于复读插件描述"病灶不复现）/
//    插件使用指南（安装/授权/AI 写插件三行）。
//    ②开关直通详情页同款语义：开 = setEnabled:YES + restartPlugin；
//    关 = setEnabled:NO + stopPlugin（贡献行随停随清，通知驱动刷新）。
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

/// 分区常量（四分区；Task329 重构后语义）。
typedef NS_ENUM(NSInteger, Ame329ListSection) {
    Ame329SectionInstalled = 0,   ///< 已安装插件（启停开关）
    Ame329SectionRows      = 1,   ///< 插件贡献的启动器行
    Ame329SectionAbout     = 2,   ///< 关于（API 版本）
    Ame329SectionGuide     = 3,   ///< 插件使用指南
};

@interface AmePluginListViewController ()
@property(nonatomic, copy) NSArray<AmePluginManifest *> *ame318_plugins;
@property(nonatomic, copy) NSArray<AmePluginRow *> *ame329_rows;
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

    // ★ Task329：贡献行随插件生命周期即时刷新（启停/注册/刷新三源同通知）。
    [[NSNotificationCenter defaultCenter]
     addObserver:self selector:@selector(ame329_rowsChanged)
     name:[AmePluginRuntime rowsChangedNotification] object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ame318_rescan];
}

- (void)ame318_rescan {
    self.ame318_plugins = [[AmePluginManager shared] installedPlugins];
    self.ame329_rows = [AmePluginRuntime allRows];
    [self.tableView reloadData];
}

- (void)ame329_rowsChanged {
    // 通知可能在任意线程 post（运行时内部已保证 main 派发）；双保险主队列。
    dispatch_async(dispatch_get_main_queue(), ^{
        self.ame329_rows = [AmePluginRuntime allRows];
        [self.tableView reloadData];
    });
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

#pragma mark - 启停开关（详情页同款语义）

- (void)ame318_switchChanged:(UISwitch *)sw {
    NSString *pluginId = sw.accessibilityIdentifier;
    if (pluginId.length == 0) return;
    BOOL on = sw.on;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AmePluginManager shared] setEnabled:on pluginId:pluginId];
        if (on) {
            [AmePluginRuntime restartPlugin:pluginId];
        } else {
            [AmePluginRuntime stopPlugin:pluginId];   // 贡献行随停清空 + 通知刷新
        }
        [self ame318_rescan];
    });
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case Ame329SectionInstalled:
            return MAX(1, (NSInteger)self.ame318_plugins.count);   // 空态占 1 行
        case Ame329SectionRows:
            return MAX(1, (NSInteger)self.ame329_rows.count);      // 空态占 1 行
        case Ame329SectionAbout:
            return 1;
        case Ame329SectionGuide:
            return 3;
        default:
            return 0;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case Ame329SectionInstalled: return localize(@"ame318.list.section.installed", nil);
        case Ame329SectionRows:      return localize(@"ame318.list.section.rows", nil);
        case Ame329SectionAbout:     return localize(@"ame318.list.section.about", nil);
        case Ame329SectionGuide:     return localize(@"ame318.list.section.guide", nil);
        default: return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == Ame329SectionInstalled) return 72.0;   // 标题+描述双行
    if (indexPath.section == Ame329SectionGuide) return 72.0;
    return 60.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    PrismaListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ame318.list.cell"
                                                          forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.titleOverrideColor = nil;
    switch (indexPath.section) {
        case Ame329SectionInstalled: {
            if (indexPath.row >= (NSInteger)self.ame318_plugins.count) {
                // 空态（不可点）。
                cell.prismaTitle = localize(@"ame318.list.empty", nil);
                cell.prismaSubtitle = localize(@"ame318.list.empty_hint", nil);
                cell.prismaIconName = @"puzzlepiece.extension";
                cell.showsChevron = NO;
                return cell;
            }
            AmePluginManifest *m = self.ame318_plugins[indexPath.row];
            cell.prismaTitle = m.name;
            cell.prismaSubtitle = [NSString stringWithFormat:@"v%@ · %@",
                                   m.version, m.pluginDescription ?: @""];
            cell.prismaIconName = @"puzzlepiece.extension";
            cell.showsChevron = NO;
            // ★ Task329：行内启停开关（原生 UISwitch = 圆形旋钮；PrismaTheme
            // appearance 已全局着色 onTintColor，方块旋钮病灶结构性不复发）。
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [[AmePluginManager shared] isEnabled:m.pluginId];
            sw.accessibilityIdentifier = m.pluginId;
            [sw addTarget:self action:@selector(ame318_switchChanged:)
          forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
            cell.showsChevron = NO;
            return cell;
        }
        case Ame329SectionRows: {
            if (indexPath.row >= (NSInteger)self.ame329_rows.count) {
                cell.prismaTitle = localize(@"ame318.rows.empty", nil);
                cell.prismaSubtitle = localize(@"ame318.rows.empty_hint", nil);
                cell.prismaIconName = @"sparkles";
                cell.showsChevron = NO;
                return cell;
            }
            AmePluginRow *row = self.ame329_rows[indexPath.row];
            cell.prismaTitle = row.title.length ? row.title : row.rowId;
            cell.prismaSubtitle = row.detail;
            cell.prismaIconName = @"sparkles";
            cell.showsChevron = YES;
            return cell;
        }
        case Ame329SectionAbout: {
            cell.prismaTitle = [NSString stringWithFormat:
                localize(@"ame318.list.about.api", nil), @1];
            cell.prismaSubtitle = nil;
            cell.prismaIconName = @"info.circle";
            cell.showsChevron = NO;
            return cell;
        }
        case Ame329SectionGuide: {
            NSString *titleKey = nil, *detailKey = nil;
            NSString *icon = nil;
            switch (indexPath.row) {
                case 0: titleKey = @"ame318.guide.install.title"; detailKey = @"ame318.guide.install.detail"; icon = @"shippingbox.fill"; break;
                case 1: titleKey = @"ame318.guide.perm.title";    detailKey = @"ame318.guide.perm.detail";    icon = @"hand.raised.fill"; break;
                default: titleKey = @"ame318.guide.ai.title";     detailKey = @"ame318.guide.ai.detail";      icon = @"wand.and.stars"; break;
            }
            cell.prismaTitle = localize(titleKey, nil);
            cell.prismaSubtitle = localize(detailKey, nil);
            cell.prismaIconName = icon;
            cell.showsChevron = NO;
            return cell;
        }
        default:
            return cell;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case Ame329SectionInstalled: {
            if (indexPath.row >= (NSInteger)self.ame318_plugins.count) return;
            AmePluginManifest *m = self.ame318_plugins[indexPath.row];
            AmePluginDetailViewController *detail = [[AmePluginDetailViewController alloc]
                                                     initWithPluginId:m.pluginId];
            [self.navigationController pushViewController:detail animated:YES];
            return;
        }
        case Ame329SectionRows: {
            if (indexPath.row >= (NSInteger)self.ame329_rows.count) return;
            AmePluginRow *row = self.ame329_rows[indexPath.row];
            // onTap 在插件串行队列上回放（JSContext 线程安全硬约束）。
            [AmePluginRuntime dispatchRowTapForPlugin:row.pluginId rowId:row.rowId];
            return;
        }
        default:
            return;
    }
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
