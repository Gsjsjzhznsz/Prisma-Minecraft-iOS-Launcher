//
//  AmePluginDetailViewController.m
//  Amethyst
//
//  Task318：插件详情页实现。
//
//  实时语义：
//    · 权限开关 = 账本即时写（AmePluginPermissions），桥接边界每次调用
//      现查授权 → 写路径类权限开/关即刻生效，无需重启插件；
//    · 撤销 events 授权时若插件在跑 → 重启插件（旧 context 已订阅的
//      handler 作废，符合"撤销即失效"直觉）；
//    · 启停开关 → AmePluginRuntime start/stop（单插件粒度）。
//

#import "AmePluginDetailViewController.h"
#import "AmePluginManager.h"
#import "AmePluginPermissions.h"
#import "AmePluginRuntime.h"
#import "PrismaUI.h"
#import "NMToast.h"
#import "utils.h"

#pragma mark - 行模型

/// 节区编号（固定布局）。
typedef NS_ENUM(NSInteger, Ame318DetailSection) {
    Ame318SectionInfo = 0,       ///< 插件信息（名称/版本/作者 + 简介）
    Ame318SectionRuntime = 1,    ///< 启停（启用开关 + 运行状态/错误）
    Ame318SectionPerms = 2,      ///< 权限组（每权限一行实时开关）
    Ame318SectionDanger = 3,     ///< 危险区（卸载）
};

@interface AmePluginDetailViewController ()
@property(nonatomic, copy) NSString *ame318_pluginId;
@property(nonatomic, strong) AmePluginManifest *ame318_manifest;
@end

@implementation AmePluginDetailViewController

- (instancetype)initWithPluginId:(NSString *)pluginId {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _ame318_pluginId = [pluginId copy];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:[PrismaListCell class]
           forCellReuseIdentifier:@"ame318.detail.cell"];
    [self ame318_reloadManifest];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self ame318_reloadManifest];
}

- (void)ame318_reloadManifest {
    self.ame318_manifest = [[AmePluginManager shared] manifestForPlugin:self.ame318_pluginId];
    self.title = self.ame318_manifest.name ?: self.ame318_pluginId;
    [self.tableView reloadData];
}

#pragma mark - 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 4;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == Ame318SectionInfo) return 2;          // 名称行 + 简介行
    if (section == Ame318SectionRuntime) return 2;       // 启用开关 + 状态
    if (section == Ame318SectionPerms) {
        return (NSInteger)self.ame318_manifest.permissions.count ?: 1;
    }
    return 1;                                            // 卸载
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case Ame318SectionRuntime: return nil;
        case Ame318SectionPerms:   return localize(@"ame318.detail.section.perms", nil);
        case Ame318SectionDanger:  return localize(@"ame318.detail.section.danger", nil);
        default:                   return nil;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 56.0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == Ame318SectionInfo && indexPath.row == 1) {
        // 简介行（纯文本， tertiary）。
        UITableViewCell *plain = [tableView dequeueReusableCellWithIdentifier:@"ame318.desc"];
        if (!plain) {
            plain = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                          reuseIdentifier:@"ame318.desc"];
            plain.textLabel.numberOfLines = 0;
            plain.textLabel.font = [PrismaTheme fontForRole:PrismaTextCaption1];
            plain.textLabel.textColor = [PrismaTheme colorTextTertiary];
        }
        plain.textLabel.text = self.ame318_manifest.pluginDescription.length
            ? self.ame318_manifest.pluginDescription
            : localize(@"ame318.detail.no_description", nil);
        return plain;
    }
    if (indexPath.section == Ame318SectionDanger) {
        PrismaListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ame318.detail.cell"
                                                              forIndexPath:indexPath];
        cell.showsChevron = NO;
        cell.accessoryView = nil;
        cell.prismaTitle = localize(@"ame318.detail.uninstall", nil);
        cell.prismaSubtitle = nil;
        cell.prismaIconName = @"trash";
        cell.iconTintedWithAccent = NO;
        cell.titleOverrideColor = [PrismaTheme colorDanger]; // 卸载行红字（复用池重设防串色）
        return cell;
    }

    PrismaListCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ame318.detail.cell"
                                                          forIndexPath:indexPath];
    cell.accessoryView = nil;
    cell.showsChevron = NO;

    if (indexPath.section == Ame318SectionInfo) {
        AmePluginManifest *m = self.ame318_manifest;
        cell.prismaTitle = m.name ?: self.ame318_pluginId;
        cell.prismaSubtitle = [NSString stringWithFormat:@"v%@ · %@",
                               m.version ?: @"?", m.author ?: @"-"];
        cell.prismaIconName = @"puzzlepiece.extension";
        return cell;
    }
    if (indexPath.section == Ame318SectionRuntime) {
        if (indexPath.row == 0) {
            cell.prismaTitle = localize(@"ame318.detail.enabled", nil);
            cell.prismaSubtitle = nil;
            cell.prismaIconName = @"power";
            UISwitch *sw = [[UISwitch alloc] init];
            sw.on = [[AmePluginManager shared] isEnabled:self.ame318_pluginId];
            [sw addTarget:self action:@selector(ame318_toggleEnabled:)
               forControlEvents:UIControlEventValueChanged];
            cell.accessoryView = sw;
        } else {
            cell.prismaTitle = localize(@"ame318.detail.state", nil);
            cell.prismaSubtitle = [self ame318_stateText];
            cell.prismaIconName = @"bolt.horizontal";
        }
        return cell;
    }

    // 权限行（每权限一个实时开关；高危行红字）。
    NSUInteger permIndex = indexPath.row;
    NSArray<NSString *> *perms = self.ame318_manifest.permissions;
    if (permIndex >= perms.count) return cell;
    NSString *perm = perms[permIndex];
    cell.prismaTitle = [AmePluginPermissions localizedTitleForPermission:perm];
    cell.prismaSubtitle = [AmePluginPermissions localizedDetailForPermission:perm];
    cell.prismaIconName = [AmePluginPermissions dangerForPermission:perm] == AmePluginDangerHigh
        ? @"exclamationmark.shield.fill" : @"checkmark.shield";
    BOOL highDanger = [AmePluginPermissions dangerForPermission:perm] == AmePluginDangerHigh;
    // 高危权限行红字（titleOverrideColor 为组件公开覆盖位）。
    cell.titleOverrideColor = highDanger ? [PrismaTheme colorDanger] : nil;
    UISwitch *sw = [[UISwitch alloc] init];
    sw.on = [AmePluginPermissions isGranted:perm forPlugin:self.ame318_pluginId];
    sw.tag = permIndex;
    [sw addTarget:self action:@selector(ame318_togglePerm:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (NSString *)ame318_stateText {
    NSString *pid = self.ame318_pluginId;
    if ([AmePluginRuntime isRunning:pid]) return localize(@"ame318.detail.state.running", nil);
    if (![[AmePluginManager shared] isEnabled:pid]) return localize(@"ame318.detail.state.stopped", nil);
    NSString *err = [AmePluginRuntime lastErrorForPlugin:pid];
    if (err.length > 0) {
        return [NSString stringWithFormat:localize(@"ame318.detail.state.failed_fmt", nil), err];
    }
    return localize(@"ame318.detail.state.pending", nil);
}

#pragma mark - 开关动作

/// 启停开关。
- (void)ame318_toggleEnabled:(UISwitch *)sw {
    NSString *pid = self.ame318_pluginId;
    if (sw.on) {
        [[AmePluginManager shared] setEnabled:YES pluginId:pid];
        [AmePluginRuntime restartPlugin:pid];
    } else {
        [[AmePluginManager shared] setEnabled:NO pluginId:pid];
        [AmePluginRuntime stopPlugin:pid];
    }
    [self.tableView reloadData];
}

/// 权限实时开关（撤销 events 且在跑 → 重启插件使旧订阅作废）。
- (void)ame318_togglePerm:(UISwitch *)sw {
    NSUInteger idx = sw.tag;
    NSArray<NSString *> *perms = self.ame318_manifest.permissions;
    if (idx >= perms.count) return;
    NSString *perm = perms[idx];
    NSString *pid = self.ame318_pluginId;
    [AmePluginPermissions setGranted:sw.on permission:perm forPlugin:pid];
    if (!sw.on && [perm isEqualToString:AmePluginPermEvents] && [AmePluginRuntime isRunning:pid]) {
        [AmePluginRuntime restartPlugin:pid];
    }
    [self.tableView reloadData];
}

#pragma mark - 卸载

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != Ame318SectionDanger) return;
    // 危险区确认走 UIAlertController（Task240 分工边界；弹窗不是菜单）。
    NSString *name = self.ame318_manifest.name ?: self.ame318_pluginId;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:localize(@"ame318.detail.uninstall.confirm.title", nil)
                         message:[NSString stringWithFormat:
                                  localize(@"ame318.detail.uninstall.confirm.msg", nil), name]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                              style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame318.detail.uninstall", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) {
        [AmePluginRuntime stopPlugin:self.ame318_pluginId];
        [[AmePluginManager shared] uninstallPlugin:self.ame318_pluginId];
        [NMToast showMessage:[NSString stringWithFormat:
                              localize(@"ame318.toast.uninstalled", nil), name]];
        [self.navigationController popViewControllerAnimated:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
