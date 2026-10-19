//
//  StikDebugViewController.m
//  Amethyst
//
//  ★ Task291（PocketJ 对标移植 · 内置 JIT 第一阶段）：实现见头文件注释。
//  移植自 PocketJLauncher Natives/stikdebug/StikDebugViewController.m，
//  适配本仓：localize 四表 i18n / 原生 inset-grouped 表格（无 ModernUITheme
//  依赖）/ 错误分类提示（配对错误 vs 连接错误）保持上游语义。
//  ★ Task293（内置 JIT 第二阶段）：开启动作升级——iOS 26+ 且 Helper appex
//  在位时走 PrismaJITCoordinator（AppExtensionProcess 独立进程轨，PocketJ
//  enableEmbeddedJITWithCompletion 同构：dlopen + NSClassFromString 弱接入、
//  100ms 轮询 isJITEnabled 提前交付成功态）；门禁序遵 INTEGRATION.md
//  （get-task-allow → 配对文件）；内置轨失败不静默回退深链，显式弹窗
//  征求同意后再走 stikjit://（上游 "Do not silently fall through"）。
//  ★ Task294：①内置轨提取为类方法 +ame294_enableBuiltinJITWithCompletion
//  （PocketJ 同款全局入口）——JIT 页 / RightPanel Task134 / JavaLauncher
//  Task139 三处共用，jit_enabler 选项新增 builtin（启动器自带）后按选择
//  分发；②会话级祝福标记 +ame294_scriptCompletedThisSession 供 JIT26
//  重挂启发式区分“完成的内置祝福”与“中断式半附加”；③显示根修：开启
//  按钮 subview 曾只在按钮行分支摘除，复用池把旧按钮 cell 发给普通行时
//  绿色“开启 JIT”漂浮在配对/删除等行上（装机 IMG_0439 实锤）——改为
//  每条 cellForRow 路径先摘除。
//

#import "StikDebugViewController.h"
#import "StikDebugEngine.h"
#import "utils.h"

#import <dlfcn.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// Task293：宿主侧协调器弱接入协议（libPrismaJITCoordinator.dylib 内
// PrismaJITCoordinator 的 ObjC 投影，dlopen 成功后才可命中）
@protocol PrismaJITCoordinatorAPI <NSObject>
+ (void)enableJITWithTargetPID:(int32_t)targetPID
                   pairingData:(NSData *)pairingData
                    completion:(void (^)(BOOL success, NSString *message))completion;
@end

@interface StikDebugViewController () <UIDocumentPickerDelegate>
@property(nonatomic) BOOL enabling;
@property(nonatomic) BOOL jitEnabled;
@property(nonatomic) BOOL pairingImportFailed;
@property(nonatomic) BOOL vpnChecking;
@property(nonatomic) BOOL vpnConnected;
@property(nonatomic, copy) NSString *lastStatus;
@end

@implementation StikDebugViewController

/// Task294：会话级内置轨祝福标记（见头文件注释）
static BOOL ame294_builtinScriptCompleted = NO;

/// 前置声明：+ame294_enableBuiltinJITWithCompletion / +ame294_builtinTrackAvailable
/// 在文件前部调用（定义在下方 #pragma mark 开启 JIT 区）——C 静态函数先声明后用。
static BOOL ame293_hasGetTaskAllow(void);
/// Task306：spawn 可行性门（见 ame294 区实现注释）——SideStore/AltStore
/// 直装无 no-sandbox/dynamic-codesigning entitlement 时 builtin 派生轨结构性必死。
static BOOL ame306_spawnDerivable(void);

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

#pragma mark - 内置轨共享助手（Task294）

/// 协调器加载（dispatch_once 幂等，成功后不 dlclose——后续调用复用）。失败
/// 带 dlerror 取证进 latestlog（宿主进程内 NSLog 直接可见，下轮装机可定位
/// “无法开启 JIT”卡在 dlopen 还是发现还是 XPC）。
+ (Class)ame294_coordinatorClass {
    static Class klass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (@available(iOS 26.0, *)) {} else { return; }
        NSString *frameworkPath = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Frameworks/libPrismaJITCoordinator.dylib"];
        void *handle = dlopen(frameworkPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            NSString *altPath = [NSBundle.mainBundle.privateFrameworksPath
                stringByAppendingPathComponent:@"libPrismaJITCoordinator.dylib"];
            handle = dlopen(altPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        }
        if (!handle) {
            NSLog(@"[JIT] Task294 dlopen libPrismaJITCoordinator.dylib failed: %s", dlerror());
            return;
        }
        klass = NSClassFromString(@"PrismaJITCoordinator");
        if (!klass) {
            NSLog(@"[JIT] Task294 dylib loaded but PrismaJITCoordinator class missing (swift projection not registered)");
        } else {
            NSLog(@"[JIT] Task294 coordinator loaded -- builtin track ready");
        }
    });
    return klass;
}

+ (BOOL)ame294_builtinTrackAvailable {
    if (@available(iOS 26.0, *)) {
        // ★ Task302：LiveContainer guest 结构性短路——三条派生轨全死
        //   （EXKit Code=19 / posix_spawn errno=2 / fork errno=1），builtin
        //   可用性直接回 NO：auto 模式直通 stikjit:// 深链，不再做注定
        //   失败的内置尝试（装机 2c6458a/c3e70c5 两代实锤）。
        if (ame302_isLiveContainerGuest()) return NO;
        // ★ Task306：非越狱直装（SideStore/AltStore）spawn 结构性必死短路
        //   （IMG_0449 直装实测 rc=1 errno=2 + Task43 shaderc 真机恒 EPERM
        //   先例）——auto 模式继续直通 stikjit:// 深链，不再做注定失败的
        //   内置尝试。
        if (!ame306_spawnDerivable()) return NO;
        if (!ame293_hasGetTaskAllow()) return NO;
        [StikDebugEngine.sharedEngine synchronizePairingFileFromDocuments:nil];
        if (!StikDebugEngine.sharedEngine.hasPairingFile) return NO;
        return [self ame294_coordinatorClass] != nil;
    }
    return NO;
}

+ (BOOL)ame294_scriptCompletedThisSession {
    return ame294_builtinScriptCompleted;
}

+ (void)ame294_enableBuiltinJITWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    // 门禁序（INTEGRATION.md）：① iOS 26+ ② get-task-allow ③ 配对文件
    // ④ 协调器。①②③④ 任一不过立即回包（caller 决定是否降级深链）。
    if (@available(iOS 26.0, *)) {
        // ★ Task302：LC guest 如实报错（不再给误导性重签建议）
        if (ame302_isLiveContainerGuest()) {
            NSLog(@"[JIT] Task302 gate: LiveContainer guest -- builtin spawn tracks structurally unavailable (EXKit Code=19 / spawn errno=2 / fork errno=1)");
            completion(NO, localize(@"ame302.jit.lc_guest", nil));
            return;
        }
        // ★ Task306：非越狱直装 spawn 必死如实报错（不再走注定失败的
        //   posix_spawn，不再弹误导性 "re-sign the IPA" 建议——IMG_0449
        //   实锤 SideStore 直装 PlugIns/ 完好依旧 errno=2，重签救不了
        //   沙盒拒绝 spawn 行为本身）。
        if (!ame306_spawnDerivable()) {
            NSLog(@"[JIT] Task306 gate: spawn not derivable (no no-sandbox/dynamic-codesigning entitlement) -- builtin track denied, advise StikDebug deep-link");
            completion(NO, localize(@"ame306.jit.spawn_denied", nil));
            return;
        }
        if (!ame293_hasGetTaskAllow()) {
            NSLog(@"[JIT] Task294 gate: get-task-allow missing");
            completion(NO, localize(@"ame293.jit.gettask_fail", nil));
            return;
        }
        [StikDebugEngine.sharedEngine synchronizePairingFileFromDocuments:nil];
        NSData *pairingData = [NSData dataWithContentsOfFile:
            StikDebugEngine.sharedEngine.pairingFilePath];
        if (pairingData.length == 0) {
            NSLog(@"[JIT] Task294 gate: pairing file missing/empty");
            completion(NO, localize(@"ame291.jit.pairing_empty", nil));
            return;
        }
        Class<PrismaJITCoordinatorAPI> coordinator =
            (Class<PrismaJITCoordinatorAPI>)[self ame294_coordinatorClass];
        if (!coordinator) {
            NSLog(@"[JIT] Task294 gate: coordinator unavailable");
            completion(NO, localize(@"ame293.jit.builtin_missing", nil));
            return;
        }

        // ★ Task295：扩展发现取证——ExtensionKit 要求宿主包 Extensions/ 内
        //   同时有 <点>.appexpt（扩展点定义）与 <点>.appex（泛用 appex 落位，
        //   PocketJ 上游 build_pocketj.sh 注释点名：缺 appexpt 即 "Failed to
        //   add observer"）。目录清单直落 latestlog，再失败可直接对单。
        NSString *ame295_extDir = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"Extensions"];
        NSString *ame295_plugDir = [NSBundle.mainBundle.bundlePath
            stringByAppendingPathComponent:@"PlugIns"];
        NSFileManager *ame295_fm = [NSFileManager defaultManager];
        NSLog(@"[JIT] Task295 bundle fs: Extensions=%@ PlugIns=%@",
              [ame295_fm contentsOfDirectoryAtPath:ame295_extDir error:NULL] ?: @"(absent)",
              [ame295_fm contentsOfDirectoryAtPath:ame295_plugDir error:NULL] ?: @"(absent)");
        // ★ Task295：配对文件健全性——装机 latestlog 出现 pairing=501 bytes
        //   （真实 .mobiledevicepairing 是多 KB plist，含证书键）。非 plist
        //   直接拒启（StikJIT 下游必卡），是 plist 则把键清单落日志（缺证书
        //   键只警告放行，下游 stage 错误回包定音）。
        if (pairingData.length) {
            NSDictionary *ame295_pairing = [NSPropertyListSerialization
                propertyListWithData:pairingData options:0 format:NULL error:NULL];
            if (!ame295_pairing) {
                NSLog(@"[JIT] Task295 pairing sanity: NOT a plist (%zu bytes) -- rejecting (StikJIT cannot consume this file)",
                      (unsigned long)pairingData.length);
                completion(NO, @"[pairing] not a plist -- re-import a real .mobiledevicepairing file");
                return;
            }
            NSLog(@"[JIT] Task295 pairing sanity: bytes=%zu plist-keys=%@",
                  (unsigned long)pairingData.length, ame295_pairing.allKeys);
        }
        NSLog(@"[JIT] Task294 builtin track start (pid=%d, pairing=%zu bytes)", getpid(), (unsigned long)pairingData.length);
        __block BOOL delivered = NO;
        __block dispatch_source_t stateTimer = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        void (^deliver)(BOOL, NSString *) = ^(BOOL success, NSString *message) {
            if (delivered) return;
            delivered = YES;
            if (stateTimer) {
                dispatch_source_cancel(stateTimer);
                stateTimer = nil;
            }
            // 回包迟到时目标可能已被 100ms 轮询判定成功（StikJIT 完成收尾
            // 前目标已可执行）——以进程实际状态为准。
            BOOL effectiveSuccess = success || isJITEnabled(YES);
            if (effectiveSuccess) {
                ame294_builtinScriptCompleted = YES;
                NSLog(@"[JIT] Task294 builtin track OK (response=%d, script blessed)", success);
            } else {
                NSLog(@"[JIT] Task294 builtin track FAILED: %@", message ?: @"(no message)");
            }
            completion(effectiveSuccess, message ?: @"");
        };
        // PocketJ 同款 100ms 轮询：StikJIT 回包可能晚于目标已可执行
        dispatch_source_set_timer(stateTimer, DISPATCH_TIME_NOW,
            100 * NSEC_PER_MSEC, 20 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(stateTimer, ^{
            if (isJITEnabled(YES)) deliver(YES, localize(@"ame293.jit.builtin_ok", nil));
        });
        dispatch_resume(stateTimer);

        [coordinator enableJITWithTargetPID:getpid()
                                pairingData:pairingData
                                 completion:^(BOOL success, NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSLog(@"[JIT] Task294 coordinator response: success=%d message=%@", success, message);
                deliver(success, message ?: @"");
            });
        }];
        return;
    }
    NSLog(@"[JIT] Task294 gate: iOS < 26");
    completion(NO, localize(@"ame293.jit.builtin_missing", nil));
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
    // Task294 显示根修：开启按钮（tag 8291）曾只在按钮行分支摘除——复用池
    // 把旧按钮 cell 发给普通行时旧按钮滞留 contentView（约束仍钉在该 cell
    // 的 margins 上），绿色“开启 JIT”/“正在开启 JIT…”漂浮在配对文件/删除
    // 等行上（装机 IMG_0439 实锤）。移到公共路径：每行先摘再装配。
    [[cell.contentView viewWithTag:8291] removeFromSuperview];
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
        // 开启 JIT 按钮行（tag 8291 已在公共路径摘除，见 cellForRow 顶部）
        cell.textLabel.text = nil;
        cell.detailTextLabel.text = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

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

#pragma mark - 开启 JIT（Task293：内置 Helper 优先，深链降级需用户确认）

/// Task293：get-task-allow 自检（INTEGRATION.md 宿主侧门禁——接收 JIT 的
/// 进程必须带 get-task-allow，否则 debugserver 拒绝附加）。Security SPI
/// 走 dlsym 弱接入（非 App Store 分发面，本仓 sideload/codesign 体系内用）。
static BOOL ame293_hasGetTaskAllow(void) {
    void *(*ame293_taskCreate)(CFAllocatorRef) =
        (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*ame293_taskValue)(void *, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(void *, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!ame293_taskCreate || !ame293_taskValue) return NO;
    void *task = ame293_taskCreate(NULL);
    if (!task) return NO;
    CFTypeRef value = ame293_taskValue(task, CFSTR("get-task-allow"), NULL);
    BOOL result = (value == kCFBooleanTrue);
    if (value) CFRelease(value);
    CFRelease(task);
    return result;
}

/// Task306：单 entitlement 存在性（值非空即视为持有——no-sandbox 是 BOOL 型
/// entitlement，dynamic-codesigning 在部分签名链上为空值/布尔，统一按存在性判）。
static BOOL ame306_hasEntitlement(CFStringRef ame306_ent) {
    void *(*ame306_taskCreate)(CFAllocatorRef) =
        (void *(*)(CFAllocatorRef))dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CFTypeRef (*ame306_taskValue)(void *, CFStringRef, CFErrorRef *) =
        (CFTypeRef (*)(void *, CFStringRef, CFErrorRef *))dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!ame306_taskCreate || !ame306_taskValue) return NO;
    void *ame306_task = ame306_taskCreate(NULL);
    if (!ame306_task) return NO;
    CFTypeRef ame306_value = ame306_taskValue(ame306_task, ame306_ent, NULL);
    BOOL ame306_result = (ame306_value != NULL);
    if (ame306_value) CFRelease(ame306_value);
    CFRelease(ame306_task);
    return ame306_result;
}

/// Task306：builtin 派生轨 spawn 可行性统一门。判定依据（装机实证链）：
///   ① IMG_0449（SideStore 直装 579453c8）：主二进制在场 size=23471680，
///      posix_spawn rc=1 errno=2 —— 沙盒/AMFI 拒绝 spawn 行为本身，重签无解；
///   ② Task43 shaderc_sandbox.m 病历：真机无 no-sandbox entitlement 时
///      posix_spawn 恒 EPERM（失败一次记死）——同一结构性约束；
///   ③ Pre-Init entitlement 快照：SideStore/AltStore/LC 装机
///      no-sandbox=NO 且 dynamic-codesigning=NO。TrollStore/越狱装机二者
///      至少其一在场，spawn 才有活的可能。
/// 判 NO 时调用方给如实报错（ame306.jit.spawn_denied），不再空跑 spawn。
static BOOL ame306_spawnDerivable(void) {
    static BOOL ame306_cached = NO;
    static dispatch_once_t ame306_once;
    dispatch_once(&ame306_once, ^{
        ame306_cached =
            ame306_hasEntitlement(CFSTR("com.apple.private.security.no-sandbox")) ||
            ame306_hasEntitlement(CFSTR("dynamic-codesigning"));
        NSLog(@"[JIT] Task306 spawn-derivable=%d (no-sandbox || dynamic-codesigning; SideStore/AltStore direct installs deny posix_spawn structurally)", ame306_cached);
    });
    return ame306_cached;
}

- (void)ame291_enableJIT {
    if (self.enabling || self.jitEnabled) return;

    // Task293/294 门禁序（INTEGRATION.md）：① iOS 26+（builtin 轨前提）
    // ② get-task-allow ③ 配对文件。②失败是签名问题→专用指引弹窗（无降级
    // 项）；③缺失时不拦截——外部 StikDebug 有自己的配对导入，深链轨仍可用。
    // 实际开启动作统一走 +ame294_enableBuiltinJITWithCompletion（与启动链
    // Task134/139 共用同一实现，页内仅维护 enabling 状态与弹窗）。
    if (@available(iOS 26.0, *)) {
        if (!ame293_hasGetTaskAllow()) {
            [self ame291_showDialog:localize(@"ame293.jit.gettask_fail_title", nil)
                            message:localize(@"ame293.jit.gettask_fail", nil)];
            return;
        }
        [StikDebugEngine.sharedEngine synchronizePairingFileFromDocuments:nil];
        if (StikDebugEngine.sharedEngine.hasPairingFile) {
            self.enabling = YES;
            self.lastStatus = localize(@"ame293.jit.builtin_enabling", nil);
            [self.tableView reloadData];
            __weak typeof(self) weakSelf = self;
            [StikDebugViewController ame294_enableBuiltinJITWithCompletion:^(BOOL success, NSString *message) {
                weakSelf.enabling = NO;
                weakSelf.jitEnabled = isJITEnabled(YES);
                weakSelf.lastStatus = success
                    ? localize(@"ame293.jit.builtin_ok", nil)
                    : (message.length ? message : localize(@"ame293.jit.builtin_fail_title", nil));
                [weakSelf.tableView reloadData];
                if (!success) [weakSelf ame291_offerStikDebugFallback:weakSelf.lastStatus];
            }];
            return;
        }
    }
    [self ame291_handoffToStikDebug];
}

// Task294：原实例方法 ame291_enableBuiltinJITWithPairingData: 已删除——
// 职责并入 +ame294_enableBuiltinJITWithCompletion（JIT 页 / Task134 / Task139
// 三处共用同一实现，避免双份轮询/门禁逻辑漂移）。

/// Task293：内置轨失败后的显式降级弹窗（不静默回退——上游
/// "Do not silently fall through to a different method after a failure"）。
- (void)ame291_offerStikDebugFallback:(NSString *)detail {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:
        localize(@"ame293.jit.builtin_fail_title", nil)
        message:[NSString stringWithFormat:@"%@\n%@", detail,
                 localize(@"ame293.jit.fallback_hint", nil)]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame291.jit.cancel", nil)
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame293.jit.fallback_ok", nil)
        style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakSelf ame291_handoffToStikDebug];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 原深链轨（第一阶段家法，ame139 同构）：stikjit:// 交给外部 StikDebug。
- (void)ame291_handoffToStikDebug {
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
