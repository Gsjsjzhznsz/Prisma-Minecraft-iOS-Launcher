//
//  StikDebugViewController.m
//  Amethyst
//
//  ★ Task291（PocketJ 对标移植 · 内置 JIT 第一阶段）：实现见头文件注释。
//  移植自 PocketJLauncher Natives/stikdebug/StikDebugViewController.m，
//  适配本仓：localize 四表 i18n / 原生 inset-grouped 表格（无 ModernUITheme
//  依赖）/ 开启动作改走 stikjit:// 家法深链（PocketJ 的 iOS26 appex 轨
//  第二阶段再评估）/ 错误分类提示（配对错误 vs 连接错误）保持上游语义。
//

#import "StikDebugViewController.h"
#import "StikDebugEngine.h"
#import "utils.h"

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface StikDebugViewController () <UIDocumentPickerDelegate>
@property(nonatomic) BOOL enabling;
@property(nonatomic) BOOL jitEnabled;
@property(nonatomic) BOOL pairingImportFailed;
@property(nonatomic) BOOL vpnChecking;
@property(nonatomic) BOOL vpnConnected;
@property(nonatomic, copy) NSString *lastStatus;
@end

@implementation StikDebugViewController

+ (Ame291JITSetupState)ame291_setupState {
    if (@available(iOS 17.4, *)) {
        [StikDebugEngine.sharedEngine synchronizePairingFileFromDocuments:nil];
        if (isJITEnabled(YES)) return Ame291JITSetupStateEnabled;
        return StikDebugEngine.sharedEngine.hasPairingFile
            ? Ame291JITSetupStateReady
            : Ame291JITSetupStateWaitingConfiguration;
    }
    return Ame291JITSetupStateUnavailable;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"ame291.jit.nav_title", nil);
    self.jitEnabled = isJITEnabled(YES);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 68;
    [NSNotificationCenter.defaultCenter addObserver:self
        selector:@selector(ame291_didBecomeActive:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [self ame291_refreshLocalDevVPNStatus];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)ame291_didBecomeActive:(NSNotification *)notification {
    [StikDebugEngine.sharedEngine synchronizePairingFileFromDocuments:nil];
    self.jitEnabled = isJITEnabled(YES);
    [self ame291_refreshLocalDevVPNStatus];
    [self.tableView reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    NSError *syncError = nil;
    if (![StikDebugEngine.sharedEngine synchronizePairingFileFromDocuments:&syncError] && syncError) {
        self.pairingImportFailed = YES;
        self.lastStatus = syncError.localizedDescription;
    }
    self.jitEnabled = isJITEnabled(YES);
    if (self.jitEnabled) self.enabling = NO;
    [self ame291_refreshLocalDevVPNStatus];
    [self.tableView reloadData];
}

- (void)ame291_refreshLocalDevVPNStatus {
    if (self.vpnChecking) return;
    self.vpnChecking = YES;
    __weak typeof(self) weakSelf = self;
    [StikDebugEngine.sharedEngine checkLocalDevVPNWithCompletion:^(BOOL connected) {
        weakSelf.vpnChecking = NO;
        weakSelf.vpnConnected = connected;
        if (weakSelf.isViewLoaded) [weakSelf.tableView reloadData];
    }];
}

#pragma mark - Table 数据源

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 3) return 1;
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return localize(@"ame291.jit.status_header", nil);
    if (section == 1) return localize(@"ame291.jit.prep_header", nil);
    if (section == 2) return localize(@"ame291.jit.pairing_header", nil);
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1) return localize(@"ame291.jit.prep_footer", nil);
    if (section == 2) return localize(@"ame291.jit.pairing_footer", nil);
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"Ame291JITCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
    cell.textLabel.numberOfLines = 2;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    Ame291JITSetupState state = [StikDebugViewController ame291_setupState];

    if (indexPath.section == 0 && indexPath.row == 0) {
        cell.imageView.image = [UIImage systemImageNamed:
            self.jitEnabled ? @"bolt.circle.fill" : @"bolt.slash.circle"];
        cell.textLabel.text = localize(@"ame291.jit.run_state", nil);
        cell.detailTextLabel.text = self.jitEnabled
            ? localize(@"ame291.jit.on", nil) : localize(@"ame291.jit.off", nil);
        cell.detailTextLabel.textColor = self.jitEnabled
            ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 0) {
        BOOL supported = (state != Ame291JITSetupStateUnavailable);
        cell.imageView.image = [UIImage systemImageNamed:
            supported ? @"checkmark.shield.fill" : @"xmark.shield"];
        cell.textLabel.text = localize(@"ame291.jit.support_state", nil);
        cell.detailTextLabel.text = supported
            ? localize(@"ame291.jit.support_ok", nil)
            : localize(@"ame291.jit.support_bad", nil);
        cell.detailTextLabel.textColor = supported
            ? UIColor.systemGreenColor : UIColor.systemRedColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.imageView.image = [UIImage systemImageNamed:@"doc.badge.plus"];
        cell.textLabel.text = localize(@"ame291.jit.import_pairing", nil);
        BOOL imported = StikDebugEngine.sharedEngine.hasPairingFile;
        cell.detailTextLabel.text = imported
            ? localize(@"ame291.jit.imported", nil)
            : (self.pairingImportFailed
                ? (self.lastStatus.length ? self.lastStatus : localize(@"ame291.jit.import_failed", nil))
                : localize(@"ame291.jit.not_imported", nil));
        cell.detailTextLabel.textColor = imported
            ? UIColor.systemGreenColor : UIColor.systemRedColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 1) {
        cell.imageView.image = [UIImage systemImageNamed:@"network.badge.shield.half.filled"];
        cell.textLabel.text = localize(@"ame291.jit.vpn", nil);
        cell.detailTextLabel.text = self.vpnChecking
            ? localize(@"ame291.jit.vpn_checking", nil)
            : (self.vpnConnected ? localize(@"ame291.jit.vpn_ok", nil)
                                 : localize(@"ame291.jit.vpn_bad", nil));
        cell.detailTextLabel.textColor = self.vpnConnected
            ? UIColor.systemGreenColor : UIColor.systemRedColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        cell.imageView.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
        cell.textLabel.text = localize(@"ame291.jit.export", nil);
        BOOL has = StikDebugEngine.sharedEngine.hasPairingFile;
        cell.detailTextLabel.text = has
            ? localize(@"ame291.jit.export_hint", nil)
            : localize(@"ame291.jit.export_missing", nil);
        cell.selectionStyle = has ? UITableViewCellSelectionStyleDefault
                                  : UITableViewCellSelectionStyleNone;
        cell.accessoryType = has ? UITableViewCellAccessoryDisclosureIndicator
                                 : UITableViewCellAccessoryNone;
    } else if (indexPath.section == 2) {
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.textLabel.text = localize(@"ame291.jit.delete", nil);
        cell.detailTextLabel.text = localize(@"ame291.jit.delete_hint", nil);
        cell.selectionStyle = StikDebugEngine.sharedEngine.hasPairingFile
            ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
        cell.textLabel.textColor = UIColor.systemRedColor;
    } else {
        // 开启 JIT 按钮行
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        [[cell.contentView viewWithTag:8291] removeFromSuperview];

        NSString *title;
        if (state == Ame291JITSetupStateEnabled) title = localize(@"ame291.jit.action_enabled", nil);
        else if (state == Ame291JITSetupStateUnavailable) title = localize(@"ame291.jit.action_unavailable", nil);
        else if (state == Ame291JITSetupStateWaitingConfiguration) title = localize(@"ame291.jit.action_waiting", nil);
        else if (self.enabling) title = localize(@"ame291.jit.action_enabling", nil);
        else title = localize(@"ame291.jit.action_enable", nil);

        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = 8291;
        button.layer.cornerRadius = 14;
        button.layer.masksToBounds = YES;
        button.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        [button setTitle:title forState:UIControlStateNormal];
        BOOL actionable = (state == Ame291JITSetupStateReady && !self.enabling);
        if (state == Ame291JITSetupStateEnabled) {
            button.backgroundColor = [UIColor systemGreenColor];
            [button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        } else {
            button.backgroundColor = actionable ? [UIColor systemGreenColor] : [UIColor tertiarySystemFillColor];
            [button setTitleColor:actionable ? UIColor.whiteColor : UIColor.secondaryLabelColor
                         forState:UIControlStateNormal];
        }
        button.enabled = actionable;
        [button addTarget:self action:@selector(ame291_enableJIT) forControlEvents:UIControlEventTouchUpInside];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:button];
        [NSLayoutConstraint activateConstraints:@[
            [button.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],
            [button.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],
            [button.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8.0],
            [button.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8.0],
            [button.heightAnchor constraintGreaterThanOrEqualToConstant:50.0],
        ]];
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0) {
        NSMutableArray<UTType *> *types = [NSMutableArray arrayWithObject:UTTypePropertyList];
        UTType *pairing = [UTType typeWithFilenameExtension:@"mobiledevicepairing" conformingToType:UTTypeData];
        if (pairing) [types addObject:pairing];
        UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
        picker.delegate = self;
        picker.allowsMultipleSelection = NO;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (indexPath.section == 1) {
        // App Store 的 LocalDevVPN 页（PocketJ 同款引导）
        NSURL *URL = [NSURL URLWithString:@"https://apps.apple.com/us/app/localdevvpn/id6755608044"];
        [UIApplication.sharedApplication openURL:URL options:@{} completionHandler:nil];
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        if (!StikDebugEngine.sharedEngine.hasPairingFile) return;
        NSError *error = nil;
        NSURL *URL = [StikDebugEngine.sharedEngine exportablePairingFileURL:&error];
        if (!URL) {
            [self ame291_showDialog:localize(@"ame291.jit.export_failed", nil)
                            message:error.localizedDescription ?: localize(@"ame291.jit.unknown_error", nil)];
            return;
        }
        UIActivityViewController *share = [[UIActivityViewController alloc]
            initWithActivityItems:@[URL] applicationActivities:nil];
        share.popoverPresentationController.sourceView = [tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:share animated:YES completion:nil];
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        if (!StikDebugEngine.sharedEngine.hasPairingFile) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:
            localize(@"ame291.jit.delete_confirm_title", nil)
            message:localize(@"ame291.jit.delete_confirm_msg", nil)
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame291.jit.cancel", nil)
            style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame291.jit.delete_ok", nil)
            style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
                NSError *error = nil;
                if (![StikDebugEngine.sharedEngine deletePairingFile:&error]) {
                    [weakSelf ame291_showDialog:localize(@"ame291.jit.delete_failed", nil)
                                        message:error.localizedDescription ?: localize(@"ame291.jit.unknown_error", nil)];
                    return;
                }
                weakSelf.pairingImportFailed = NO;
                weakSelf.lastStatus = nil;
                [weakSelf.tableView reloadData];
            }]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

#pragma mark - 配对导入回调

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)URLs {
    NSError *error = nil;
    if ([StikDebugEngine.sharedEngine importPairingFileAtURL:URLs.firstObject error:&error]) {
        self.pairingImportFailed = NO;
        self.lastStatus = localize(@"ame291.jit.import_ok", nil);
        [self.tableView reloadData];
    } else {
        self.pairingImportFailed = YES;
        self.lastStatus = error.localizedDescription ?: localize(@"ame291.jit.import_failed", nil);
        [self.tableView reloadData];
    }
}

#pragma mark - 开启 JIT（stikjit:// 家法深链，与 ame139 自动 enabler 同构）

- (void)ame291_enableJIT {
    if (self.enabling || self.jitEnabled) return;
    self.enabling = YES;
    self.lastStatus = localize(@"ame291.jit.handing", nil);
    [self.tableView reloadData];

    NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSString *escaped = [bundleID stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLQueryAllowedCharacterSet];
    // 脚本数据与 ame139 同源：主包根目录 UniversalJIT26.js（构建期打包）
    NSString *scriptData = @"";
    NSData *script = [NSData dataWithContentsOfFile:
        [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
    if (script) {
        scriptData = [@"&script-data=" stringByAppendingString:[script base64EncodedStringWithOptions:0]];
    }
    NSURL *URL = [NSURL URLWithString:[NSString stringWithFormat:
        @"stikjit://enable-jit?bundle-id=%@&pid=%d%@", escaped, getpid(), scriptData]];
    __weak typeof(self) weakSelf = self;
    [UIApplication.sharedApplication openURL:URL options:@{} completionHandler:^(BOOL success) {
        weakSelf.enabling = NO;
        weakSelf.jitEnabled = isJITEnabled(YES);
        weakSelf.lastStatus = success
            ? localize(@"ame291.jit.handed_ok", nil)
            : localize(@"ame291.jit.handed_fail", nil);
        [weakSelf.tableView reloadData];
        if (!success) {
            [weakSelf ame291_showDialog:localize(@"ame291.jit.action_fail_title", nil)
                                message:weakSelf.lastStatus];
        }
    }];
}

#pragma mark - 错误分类与提示

- (void)ame291_showDialog:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame291.jit.ok", nil)
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
