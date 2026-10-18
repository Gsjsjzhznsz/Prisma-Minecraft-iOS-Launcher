//
//  ModsManagerViewController.m
//  Amethyst
//
//  Mod 管理页实现（继承 ResourceListViewController）。
//  参照 ZL2 ModsManagerScreen 模式：顶栏"检查更新"内置更新流程
//  （并发检测 → 确认弹窗 → 并发下载到临时目录 → 删旧移新 → 刷新 + 徽章）。
//

#import "ModsManagerViewController.h"
#import "ModTableViewCell.h"
#import "ModService.h"
#import "ModItem.h"
#import "ModUpdateService.h"
#import "ModpackExportService.h" // Task217: parseVersionId（26.x 版本解析）
#import "ModpackImportService.h" // Task269：启动迁移兑底（升级自动合并重复实例）
#import "ModVersion.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "DownloadViewController.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "ProfileSettingsViewController.h"   // Task225：隔离徽标 → 版本设置入口
#import "utils.h"
#import <CommonCrypto/CommonDigest.h>

#pragma mark - 内部模型与枚举

/// 更新下载任务（检查命中后的一次待更新项）
@interface ModUpdateTask : NSObject
/// 更新检查结果（含本地文件路径与候选版本）
@property (nonatomic, strong) ModUpdateResult *result;
/// 对应的本地 ModItem（用于名称显示与文件替换）
@property (nonatomic, strong) ModItem *mod;
/// 目标版本（candidateVersions 首个，即最新候选）
@property (nonatomic, strong) ModVersion *targetVersion;
/// 下载完成后的临时文件路径（下载成功时非空）
@property (nonatomic, copy) NSString *tempPath;
/// 下载是否成功
@property (nonatomic, assign) BOOL downloadSucceeded;
@end

@implementation ModUpdateTask
@end

/// 状态筛选模式
typedef NS_ENUM(NSInteger, ModsFilterMode) {
    ModsFilterModeAll = 0,
    ModsFilterModeEnabled,
    ModsFilterModeDisabled,
};

/// 排序模式
typedef NS_ENUM(NSInteger, ModsSortMode) {
    ModsSortModeName = 0,
    ModsSortModeModifiedDate,
};

#pragma mark - 工具函数

/// 流式计算文件 SHA1（CommonCrypto 分块，支持大文件），失败返回 nil
static NSString *ModsManagerSHA1ForFile(NSString *path) {
    if (path.length == 0) return nil;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    CC_SHA1_CTX ctx;
    CC_SHA1_Init(&ctx);
    @try {
        while (YES) {
            @autoreleasepool {
                NSData *chunk = [handle readDataOfLength:1 << 16];
                if (chunk.length == 0) break;
                CC_SHA1_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
            }
        }
    } @catch (NSException *exception) {
        [handle closeFile];
        return nil;
    }
    [handle closeFile];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

#pragma mark - 类扩展

@interface ModsManagerViewController () <UITableViewDataSource, UITableViewDelegate, ModTableViewCellDelegate, UISearchBarDelegate, UIDocumentPickerDelegate>

// ===== 数据 =====
@property (nonatomic, strong) NSMutableArray<ModItem *> *localMods;       // 全量本地 Mod
@property (nonatomic, strong) NSMutableArray<ModItem *> *filteredLocalMods; // 搜索 + 筛选 + 排序后
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *modDates; // filePath → 文件修改时间（排序用）

// ===== 筛选 / 排序 =====
@property (nonatomic, assign) ModsFilterMode filterMode;
@property (nonatomic, assign) ModsSortMode sortMode;
@property (nonatomic, strong) UIScrollView *chipsScrollView;   // chips 水平滚动容器
@property (nonatomic, strong) UIStackView *chipsStack;         // chips 排列
@property (nonatomic, strong) NSArray<UIButton *> *filterChips;
@property (nonatomic, strong) UIButton *sortChipButton;
@property (nonatomic, strong) UIButton *ame219_isoChip;   // ★ Task271：隔离徽标引用（实时刷新用）

// ===== 导航按钮 =====
@property (nonatomic, strong) UIBarButtonItem *closeButtonItem;
@property (nonatomic, strong) UIBarButtonItem *refreshButton;
@property (nonatomic, strong) UIBarButtonItem *checkUpdateButton;
@property (nonatomic, strong) UIBarButtonItem *importButton;
@property (nonatomic, strong) UIBarButtonItem *selectButtonItem;
@property (nonatomic, strong) UIBarButtonItem *doneButtonItem;
@property (nonatomic, strong) UIBarButtonItem *navSpinnerItem;
@property (nonatomic, strong) UIActivityIndicatorView *navSpinner;

// ===== 批量操作按钮（batchActionStack 内容）=====
@property (nonatomic, strong) UIButton *batchEnableButton;
@property (nonatomic, strong) UIButton *batchDisableButton;
@property (nonatomic, strong) UIButton *batchDeleteButton;

// ===== 更新流程状态 =====
/// 更新流程是否进行中（检查中 / 下载替换中均为 YES，期间按钮禁用防重复触发）
@property (nonatomic, assign) BOOL isUpdateBusy;
/// 更新流程的阶段提示文本（显示在导航标题位置）
@property (nonatomic, copy) NSString *updateBusyText;
/// 检查更新命中（可更新）的结果：filePath → result，用于 Cell 徽章
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModUpdateResult *> *updateResultsByPath;

// ===== 其他 =====
@property (nonatomic, assign) BOOL hasPlayedInitialAnimation; // 首次加载连锁动画只播一次

// ★ Task266：跨实例下载横幅（"游戏加载了、管理页不显示"实例错位自解释）
@property (nonatomic, copy) NSString *ame265_crossProfileDest;   // 待切换目标实例
@property (nonatomic, strong) UIView *ame265_crossProfileBanner; // 当前横幅视图（tableHeaderView）

// ★ Task267：实例切换器 + 下载落点对账（终局修复：下载进别的实例但列表不显示）
@property (nonatomic, strong) UIButton *ame267_profileChip;      // 导航栏 titleView：当前生效实例，点击弹切换器
@property (nonatomic, assign) double ame267_lastReconciledDLTs;  // 已对账的最近下载时间戳（去重）

@end

@implementation ModsManagerViewController

#pragma mark - Task265：profile 自适应解析

/// Task265（"新安装的 mod 在模组管理不显示"第三轮根修）：本页所有 profile
/// 消费点（扫描/徽标/表尾/导入/跳转下载）统一走本解析——显式绑定优先；
/// 抽屉等未绑定入口（LauncherRoot/LauncherCardLayout 走 alloc]init] 且从
/// 未设置 profileName）自适应跟随【当前选中实例】，而非退化到 "default"
/// 主目录。此前 nil → "default" 与下载/游戏侧（selectedProfile 的隔离目录）
/// 永世错位 = 用户反复反馈的"游戏里加载了、模组管理不显示"（装机
/// a5e8e1e latestlog：下载 TouchController 落隔离目录且游戏已加载，
/// 而管理页扫描 default 主目录）。自适应语义：不管哪个入口进来，页面
/// 编辑的都是用户当前选中的实例——与下载目标/启动目标天然同源。
- (NSString *)ame265_effectiveProfileName {
    // Task267 终局语义（装机 3b97d2d latestlog 双锚实锤：下载落 (2) 号实例
    // BB10129F、管理页钉在旧实例 CA336076——快照式绑定永不过期）：
    //   钉定模式（语义入口/用户切换）→ 锁定 profileName；
    //   跟随模式（默认，抽屉入口）→ 实时跟随 selectedProfileName，
    //   SelectedProfileChanged 即重扫（viewDidLoad 观察者），页面永不过期。
    if (self.ame267_pinProfile && self.profileName.length > 0) {
        // Task269 自愈：钉定实例若已被升级自动迁移合并删除（条目不在 profile 表）→
        // 回落跟随模式，杜绝钉在尸体实例上扫出空列表。
        if ([[[PLProfiles current] profiles] objectForKey:self.profileName]) return self.profileName;
        NSLog(@"[ModsManager] Task269: pinned profile \"%@\" no longer exists (migrated) -> follow mode", self.profileName);
        self.ame267_pinProfile = NO;
        self.profileName = nil;
    }
    NSString *ame265_sel = PLProfiles.current.selectedProfileName;
    if (ame265_sel.length > 0) return ame265_sel;
    return self.profileName.length > 0 ? self.profileName : @"default";
}

#pragma mark - Task288：实例加载器错配标记（PocketJ 对标移植）

/// ★ Task288（PocketJ 移植·实例级模组管理第三件）：从生效实例的
///   lastVersionId 推断实例加载器族（NeoForge/Forge/Fabric/Quilt；
///   vanilla/未知返回 nil 不标记）。PocketJ 的 loader 来自显式选择器，
///   本仓 profile 表无 loader 字段，版本 id 启发式同源推断（实例名
///   "NeoForge-26.1.2.122"/"fabric-loader-*" 形态覆盖全部加载器实例）。
- (nullable NSString *)ame288_profileLoaderForDisplay {
    NSString *ame288_profName = [self ame265_effectiveProfileName];
    NSDictionary *ame288_prof = [[PLProfiles current] profiles][ame288_profName];
    NSString *ame288_vid = [ame288_prof isKindOfClass:[NSDictionary class]]
        ? ame288_prof[@"lastVersionId"] : nil;
    if (![ame288_vid isKindOfClass:[NSString class]] || ame288_vid.length == 0) return nil;
    NSString *ame288_lower = ame288_vid.lowercaseString;
    if ([ame288_lower containsString:@"neoforge"]) return @"NeoForge";
    if ([ame288_lower containsString:@"forge"]) return @"Forge";
    if ([ame288_lower containsString:@"quilt"]) return @"Quilt";
    if ([ame288_lower containsString:@"fabric"]) return @"Fabric";
    return nil;
}

/// mod 加载器族 vs 实例加载器错配判定（本地列表标记用；装机实锤：
/// NeoForge 实例共享目录里的 fabric-api/beryl/VulkanMod 被 FML
/// "Skipping jar ... is a Fabric mod" 整包跳过 = 装了等于没装）。
- (BOOL)ame288_mod:(ModItem *)mod mismatchesProfileLoader:(NSString *)loader {
    if (loader.length == 0) return NO;
    NSString *ame288_l = loader.lowercaseString;
    BOOL ame288_forgFamily = mod.isForge || mod.isNeoForge;
    if ([ame288_l isEqualToString:@"fabric"] || [ame288_l isEqualToString:@"quilt"]) {
        return ame288_forgFamily;   // Fabric/Quilt 实例不装 Forge 系 mod
    }
    if ([ame288_l isEqualToString:@"forge"] || [ame288_l isEqualToString:@"neoforge"]) {
        return mod.isFabric;        // Forge/NeoForge 实例不装 Fabric mod
    }
    return NO;
}

#pragma mark - Init

- (instancetype)init {
    // 兼容现有调用点 [[ModsManagerViewController alloc] init]：
    // 转调基类便利初始化（标题 + Mod 语义色 puzzlepiece.fill / systemOrange）
    return [self initWithTitle:localize(@"resman.mods.title", nil)
              resourceTypeIcon:@"puzzlepiece.fill"
                      iconColor:[UIColor systemOrangeColor]];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad]; // 基类构建背景/搜索栏/表格/空态/加载态/批量工具栏

    self.localMods = [NSMutableArray array];
    self.filteredLocalMods = [NSMutableArray array];
    self.modDates = [NSMutableDictionary dictionary];
    self.updateResultsByPath = [NSMutableDictionary dictionary];

    // 搜索栏
    self.searchBar.delegate = self;
    self.searchBar.placeholder = localize(@"resman.mods.search_placeholder", nil);

    [self setupNavigationButtons];
    [self setupChipsRow];
    [self setupTableViewExtras];

    // Task269 兑底：打开管理页也触发一次迁移检查（幂等空转；启动钩子已覆盖主路径，
    // 此处覆盖"后台迁移收口前用户抢先开页"窗口，重复触发由忙标自拒绝）。
    [ModpackImportService ame269_migrateDuplicateModpackInstancesIfNeeded];

    // ★ Task267：导航栏实例切换器（当前生效实例常驻可见，点击弹选择器）
    [self ame267_setupProfileChip];
    // ★ Task267：跟随模式实时性——选中实例变化即重扫（页面不过期；
    //   钉定模式下收到通知仅刷新切换器，不改绑定）。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame267_selectedProfileChanged:)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
    // ★ Task267：下载先于开页场景对账——页面打开时若最近一次 mod 下载
    //   落在别的实例，横幅自解释（Task266 实时通知只覆盖页面在场场景）。
    [self ame267_reconcileLastDownloadIfNeeded];

    [self loadMods];
}

#pragma mark - 导航按钮

- (void)setupNavigationButtons {
    self.closeButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                         target:self
                                                                         action:@selector(closeTapped)];
    self.closeButtonItem.accessibilityLabel = localize(@"resman.common.close", nil);

    self.refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                       target:self
                                                                       action:@selector(handleRefresh:)];
    self.refreshButton.accessibilityLabel = localize(@"resman.common.refresh", nil);

    UIImage *checkImage = [UIImage systemImageNamed:@"arrow.triangle.2.circlepath"];
    self.checkUpdateButton = [[UIBarButtonItem alloc] initWithImage:checkImage
                                                              style:UIBarButtonItemStylePlain
                                                             target:self
                                                             action:@selector(checkForUpdates)];
    self.checkUpdateButton.accessibilityLabel = localize(@"resman.mods.check_update", nil);

    UIImage *importImage = [UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"plus"];
    self.importButton = [[UIBarButtonItem alloc] initWithImage:importImage
                                                         style:UIBarButtonItemStylePlain
                                                        target:self
                                                        action:@selector(importModTapped)];
    self.importButton.accessibilityLabel = localize(@"resman.mods.import", nil);

    UIImage *selectImage = [UIImage systemImageNamed:@"checklist"] ?: [UIImage systemImageNamed:@"checkmark.circle"];
    self.selectButtonItem = [[UIBarButtonItem alloc] initWithImage:selectImage
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(enterSelectMode)];
    self.selectButtonItem.accessibilityLabel = localize(@"resman.common.select", nil);

    self.doneButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                        target:self
                                                                        action:@selector(exitSelectMode)];
    self.doneButtonItem.accessibilityLabel = localize(@"resman.common.done", nil);

    // 更新流程忙态的导航栏转圈指示
    self.navSpinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.navSpinner.hidesWhenStopped = YES;
    self.navSpinnerItem = [[UIBarButtonItem alloc] initWithCustomView:self.navSpinner];

    [self updateNavigationButtons];
}

/// 按当前状态（普通 / 选择模式 / 更新忙态）刷新导航栏按钮与标题
- (void)updateNavigationButtons {
    if (self.selectModeEnabled) {
        self.navigationItem.leftBarButtonItem = self.closeButtonItem;
        self.navigationItem.rightBarButtonItems = @[self.doneButtonItem];
        [self updateSelectModeTitle];
    } else if (self.isUpdateBusy) {
        // 更新流程进行中：仅显示转圈指示，禁用其余操作防止重复触发
        self.navigationItem.leftBarButtonItem = self.closeButtonItem;
        self.navigationItem.rightBarButtonItems = @[self.navSpinnerItem];
        [self.navSpinner startAnimating];
        self.navigationItem.title = self.updateBusyText ?: localize(@"resman.mods.processing", nil);
    } else {
        self.navigationItem.leftBarButtonItem = self.closeButtonItem;
        // 从右到左：导入、刷新、检查更新、选择
        self.navigationItem.rightBarButtonItems = @[self.importButton, self.refreshButton, self.checkUpdateButton, self.selectButtonItem];
        self.navigationItem.title = self.pageTitle;
    }
}

/// 选择模式标题：显示已选数量
- (void)updateSelectModeTitle {
    if (self.selectModeEnabled) {
        self.navigationItem.title = [NSString stringWithFormat:localize(@"resman.common.selected_count", nil), (long)self.selectedIndexPaths.count];
    }
}

- (void)closeTapped {
    // 兼容两种容器：push 进导航栈 → pop；present 弹窗 → dismiss
    if (self.navigationController && self.navigationController.viewControllers.firstObject != self) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)handleRefresh:(id)sender {
    // 刷新前退出选择模式，避免选择状态与新数据不一致
    if (self.selectModeEnabled) {
        [self setSelectMode:NO];
    }
    [self loadMods];
    [self ame271_refreshIsolationBadge];   // ★ Task271：手动刷新同步徽标/表尾
}

#pragma mark - 筛选 chips 行（搜索栏下方）

- (void)setupChipsRow {
    // 基类默认把 tableView 顶部锚到 searchBar 底部；插入 chips 行需要先停用该约束
    for (NSLayoutConstraint *constraint in [self.view.constraints copy]) {
        if (constraint.firstItem == self.tableView && constraint.secondItem == self.searchBar
            && constraint.firstAttribute == NSLayoutAttributeTop) {
            constraint.active = NO;
            break;
        }
    }

    // 水平滚动 chips 容器
    self.chipsScrollView = [[UIScrollView alloc] init];
    self.chipsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipsScrollView.showsHorizontalScrollIndicator = NO;
    self.chipsScrollView.alwaysBounceHorizontal = NO;
    [self.view addSubview:self.chipsScrollView];

    self.chipsStack = [[UIStackView alloc] init];
    self.chipsStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.chipsStack.axis = UILayoutConstraintAxisHorizontal;
    self.chipsStack.alignment = UIStackViewAlignmentCenter;
    self.chipsStack.spacing = 8.0;
    [self.chipsScrollView addSubview:self.chipsStack];

    // 三个筛选 chip：全部 / 已启用 / 已禁用
    NSMutableArray<UIButton *> *chips = [NSMutableArray array];
    NSArray<NSString *> *titles = @[localize(@"resman.mods.filter.all", nil),
                                    localize(@"resman.mods.filter.enabled", nil),
                                    localize(@"resman.mods.filter.disabled", nil)];
    for (NSUInteger i = 0; i < titles.count; i++) {
        UIButton *chip = [self makeChipButtonWithTitle:titles[i]];
        chip.tag = i;
        [chip addTarget:self action:@selector(filterChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.chipsStack addArrangedSubview:chip];
        [chips addObject:chip];
    }
    self.filterChips = chips;

    // 行尾排序按钮：名称 / 修改时间 切换
    self.sortChipButton = [self makeChipButtonWithTitle:localize(@"resman.mods.sort.name", nil)];
    [self.sortChipButton setImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]
                  forState:UIControlStateNormal];
    self.sortChipButton.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight; // 图标在左
    [self.sortChipButton addTarget:self action:@selector(sortChipTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.chipsStack addArrangedSubview:self.sortChipButton];

    // Task219（⑪ 版本隔离自动识别）：行尾信息徽标——按当前 profile 的
    // gameDir 自动判定隔离态（隔离 = 蓝底“隔离”，共享 = 灰底“共享目录”），
    // 点击弹说明（下载/扫描只作用于该目录，与 ModService ame219 同口径）。
    NSInteger ame219_iso = [ModService ame219_isolationStateForProfile:[self ame265_effectiveProfileName]]; // Task265：自适应跟随选中实例
    // Task225（#5）：三态徽标（显式隔离 / 嗅探隔离 / 共享），可点——弹
    // 快捷说明 + 前往版本设置的隔离入口（用户反馈"安装模组端依旧默认
    // 共享目录"：多数是没开隔离或开在了别的 profile，这里给一条明路）。
    NSString *ame225_chipKey = (ame219_iso == 1) ? @"ame219.mods.isolated_chip"
        : (ame219_iso == 2) ? @"ame225.mods.sniffed_chip" : @"ame219.mods.shared_chip";
    UIButton *ame219_isoChip = [self makeChipButtonWithTitle:localize(ame225_chipKey, nil)];
    ame219_isoChip.enabled = YES;
    [ame219_isoChip addTarget:self action:@selector(ame225_isolationChipTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    if (ame219_iso == 1) {
        [ame219_isoChip setImage:[UIImage systemImageNamed:@"lock.shield"]
                    forState:UIControlStateNormal];
    } else if (ame219_iso == 2) {
        [ame219_isoChip setImage:[UIImage systemImageNamed:@"sparkle.magnifyingglass"]
                    forState:UIControlStateNormal];
    } else {
        [ame219_isoChip setImage:[UIImage systemImageNamed:@"externaldrive"]
                    forState:UIControlStateNormal];
    }
    ame219_isoChip.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    [self.chipsStack addArrangedSubview:ame219_isoChip];
    self.ame219_isoChip = ame219_isoChip;   // ★ Task271：持有引用供实时刷新
    NSLog(@"[ModsManager] Task219/225: isolation badge for profile %@ -> %@ (bound=%@)",
          [self ame265_effectiveProfileName],
          (ame219_iso == 1) ? @"isolated" : ((ame219_iso == 2) ? @"sniffed-isolated" : @"shared"),
          self.profileName ?: @"(nil→follow selected)"); // Task265：绑定来源一并留痕

    [NSLayoutConstraint activateConstraints:@[
        // chips 行：紧贴搜索栏下方，tableView 改为锚到 chips 行底部
        [self.chipsScrollView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:2],
        [self.chipsScrollView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:ResourceListCardSideInset],
        [self.chipsScrollView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-ResourceListCardSideInset],
        [self.chipsScrollView.heightAnchor constraintEqualToConstant:34],

        [self.chipsStack.topAnchor constraintEqualToAnchor:self.chipsScrollView.topAnchor],
        [self.chipsStack.bottomAnchor constraintEqualToAnchor:self.chipsScrollView.bottomAnchor],
        [self.chipsStack.leadingAnchor constraintEqualToAnchor:self.chipsScrollView.contentLayoutGuide.leadingAnchor],
        [self.chipsStack.trailingAnchor constraintEqualToAnchor:self.chipsScrollView.contentLayoutGuide.trailingAnchor],
        [self.chipsStack.centerYAnchor constraintEqualToAnchor:self.chipsScrollView.centerYAnchor],

        [self.tableView.topAnchor constraintEqualToAnchor:self.chipsScrollView.bottomAnchor constant:2],
    ]];

    [self refreshChipStyles];
}

/// 创建胶囊 chip 按钮（选中 = accent 底白字；未选中 = 半透明底 labelColor 文字）
- (UIButton *)makeChipButtonWithTitle:(NSString *)title {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    chip.contentEdgeInsets = UIEdgeInsetsMake(5, 14, 5, 14);
    chip.layer.cornerRadius = 14.0;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.masksToBounds = YES;
    [chip.heightAnchor constraintEqualToConstant:28].active = YES;
    [chip setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chip setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return chip;
}

/// 应用选中 / 未选中样式
- (void)applyChipStyle:(UIButton *)chip selected:(BOOL)selected {
    if (selected) {
        chip.backgroundColor = accentColor();
        [chip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        chip.tintColor = [UIColor whiteColor];
        chip.layer.borderWidth = 0;
    } else {
        chip.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [chip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        chip.tintColor = [UIColor labelColor];
        chip.layer.borderWidth = 0.5;
        chip.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
    }
}

/// 刷新全部 chip 样式（按当前筛选 / 排序状态）
- (void)refreshChipStyles {
    for (NSUInteger i = 0; i < self.filterChips.count; i++) {
        [self applyChipStyle:self.filterChips[i] selected:((NSInteger)i == self.filterMode)];
    }
    [self applyChipStyle:self.sortChipButton selected:YES]; // 排序按钮常为选中样式（当前生效的排序）
    NSString *sortTitle = (self.sortMode == ModsSortModeName) ? localize(@"resman.mods.sort.name", nil)
                                                              : localize(@"resman.mods.sort.modified", nil);
    [self.sortChipButton setTitle:sortTitle forState:UIControlStateNormal];
}

- (void)filterChipTapped:(UIButton *)sender {
    self.filterMode = (ModsFilterMode)sender.tag;
    [self refreshChipStyles];
    [self applyFilter];
}

/// Task225（#5）：隔离徽标点击——说明当前 mod 安装/扫描的目标目录语义，
/// 并提供「前往版本设置」入口（隔离开关在版本设置页）。
- (void)ame225_isolationChipTapped {
    NSInteger ame225_iso = [ModService ame219_isolationStateForProfile:[self ame265_effectiveProfileName]]; // Task265
    NSString *ame225_msg = nil;
    if (ame225_iso == 1) {
        ame225_msg = localize(@"ame225.mods.isolated_note", nil);
    } else if (ame225_iso == 2) {
        ame225_msg = localize(@"ame225.mods.sniffed_note", nil);
    } else {
        ame225_msg = localize(@"ame225.mods.shared_note", nil);
    }
    UIAlertController *ame225_alert = [UIAlertController
        alertControllerWithTitle:localize(@"profile.isolation.title", nil)
                         message:ame225_msg
                  preferredStyle:UIAlertControllerStyleAlert];
    [ame225_alert addAction:[UIAlertAction
        actionWithTitle:localize(@"ame225.mods.open_settings", nil)
                  style:UIAlertActionStyleDefault
                handler:^(UIAlertAction * _Nonnull action) {
        // 前往版本设置页（隔离开关在那里）
        ProfileSettingsViewController *ame225_ps = [[ProfileSettingsViewController alloc] init];
        ame225_ps.profileName = [self ame265_effectiveProfileName]; // Task265：自适应跟随
        UINavigationController *ame225_nav = [[UINavigationController alloc] initWithRootViewController:ame225_ps];
        ame225_nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [self presentViewController:ame225_nav animated:YES completion:nil];
    }]];
    [ame225_alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil)
                                                      style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:ame225_alert animated:YES completion:nil];
}

- (void)sortChipTapped {
    self.sortMode = (self.sortMode == ModsSortModeName) ? ModsSortModeModifiedDate : ModsSortModeName;
    [self refreshChipStyles];
    [self applyFilter];
}

#pragma mark - TableView 补充配置

- (void)setupTableViewExtras {
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    [self.tableView registerClass:[ModTableViewCell class] forCellReuseIdentifier:@"ModCell"];
    self.tableView.rowHeight = 68.0;
    [self ame264_setupScanFolderFooter];
}

#pragma mark - Task264 扫描目录提示行（中途加 mod 不显示的自解释修复）

/// 表尾提示行：展示当前 profile 实际生效的 mods 目录（与扫描同源），
/// 并提供"在文件中打开"——文件 App 定点打开该目录，用户拷入的 .jar
/// 重扫后必然出现在本页。不展示会话式提示（随时可见，随 profile 联动）。
- (void)ame264_setupScanFolderFooter {
    // ★ Task266：跟随生效实例（ame265_effectiveProfileName）而非裸绑定——
    //   nil 绑定入口（抽屉）此前表尾展示 default 主目录而扫描跟随选中实例，
    //   目录提示行与实际扫描目录不一致（Task265 自适应链上的遗留错位点）。
    NSString *folder = [[ModService sharedService] ame264_effectiveModsFolderForProfile:[self ame265_effectiveProfileName]];
    if (folder.length == 0) {
        self.tableView.tableFooterView = nil;
        return;
    }
    CGFloat width = self.tableView.bounds.size.width;
    CGFloat footerH = 58.0;
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, footerH)];
    footer.autoresizingMask = UIViewAutoresizingFlexibleWidth;

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(12, 8, width - 24, footerH - 16)];
    card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    card.layer.cornerRadius = 12.0;
    card.clipsToBounds = YES;
    [footer addSubview:card];

    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(12, 8, card.bounds.size.width - 60, 16)];
    caption.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    caption.text = localize(@"resman.mods.folder.caption", nil);
    caption.font = [UIFont systemFontOfSize:12.0 weight:UIFontWeightSemibold];
    caption.textColor = [UIColor secondaryLabelColor];
    [card addSubview:caption];

    UILabel *pathLabel = [[UILabel alloc] initWithFrame:CGRectMake(12, 26, card.bounds.size.width - 60, 16)];
    pathLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    pathLabel.text = [self ame264_friendlyFolderPath:folder];
    pathLabel.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightRegular];
    pathLabel.textColor = [UIColor tertiaryLabelColor];
    pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [card addSubview:pathLabel];

    UIButton *openButton = [UIButton buttonWithType:UIButtonTypeSystem];
    openButton.frame = CGRectMake(card.bounds.size.width - 48, 5, 40, 32);
    openButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    [openButton setImage:[UIImage systemImageNamed:@"square.and.arrow.down"] ?: [UIImage systemImageNamed:@"folder"] forState:UIControlStateNormal];
    openButton.accessibilityLabel = localize(@"resman.mods.folder.import", nil);
    openButton.tintColor = [UIColor systemOrangeColor];
    [openButton addTarget:self action:@selector(ame264_openScannedFolder) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:openButton];

    self.tableView.tableFooterView = footer;
}

/// 目录友好显示：优先相对 POJAV_GAME_DIR（整合包实例即 custom_gamedir/<id>/mods），
/// 不在基准下则回退末两级路径。
- (NSString *)ame264_friendlyFolderPath:(NSString *)folder {
    const char *g = getenv("POJAV_GAME_DIR");
    NSString *base = g ? [NSString stringWithUTF8String:g] : NSHomeDirectory();
    if ([folder hasPrefix:base]) {
        NSString *rel = [folder substringFromIndex:base.length];
        if ([rel hasPrefix:@"/"]) rel = [rel substringFromIndex:1];
        if (rel.length > 0) return rel;
    }
    NSArray<NSString *> *parts = folder.pathComponents;
    if (parts.count >= 2) {
        return [NSString stringWithFormat:@"…/%@/%@", parts[parts.count - 2], parts.lastObject];
    }
    return folder;
}

/// "导入到此目录"：直接复用既有导入流（importModTapped 已随 Task264 改走
/// self.profileName 解析——文件必然落入与本页扫描同源的隔离目录，重扫即见）。
/// 不采用 forOpeningContentAt 定点开目录：该 API 家族在本仓库部署目标/SDK
/// 组合下不可用（CI iPhoneOS26.2 实测 no visible @interface），仓库既有
/// picker 先例全部为 initForOpeningContentTypes 家族。
- (void)ame264_openScannedFolder {
    [self importModTapped];
}

#pragma mark - Task266 跨实例下载横幅（实例错位自解释 + 一键切换）

/// 下载完成通知（重写基类 ResourceListViewController 同名方法——基类实现未
/// 在 .h 暴露，此处复制其行为后扩展 Task266 比对逻辑）。
/// 基类行为：mod/shader/rp/dp/world 资源任务完成 → 主线程重载列表。
/// Task266 扩展：mod 任务携带 targetProfileName（ModService 中央站点标注）
/// 时与本页生效实例比对：不一致 = 跨实例下载（文件落在别的实例）→ 展示
/// 横幅 + 一键切换查看目标实例；一致 = 本实例下载，撤除历史横幅。
- (void)handleDownloadTaskCompletedNotification:(NSNotification *)notification {
    DownloadTaskItem *task = notification.userInfo[DownloadTaskManagerTaskKey];
    NSString *type = task.resourceType;
    // ★ Task268（scan-d #2）：恢复基类同款资源类型过滤——重写时丢失，
    //   MC 本体/JRE 等任意任务完成也触发 mods 全量重扫（无谓 IO + 日志刷屏）。
    static NSSet<NSString *> *ame268_resTypes = nil;
    static dispatch_once_t ame268_onceToken;
    dispatch_once(&ame268_onceToken, ^{
        ame268_resTypes = [NSSet setWithObjects:
            DownloadTaskResourceTypeMod,
            DownloadTaskResourceTypeShader,
            DownloadTaskResourceTypeResourcePack,
            DownloadTaskResourceTypeDataPack,
            DownloadTaskResourceTypeWorld,
            nil];
    });
    if (![type isKindOfClass:[NSString class]] || type.length == 0 ||
        ![ame268_resTypes containsObject:type]) return;
    if ([type isEqualToString:DownloadTaskResourceTypeMod]) {
        NSString *ame265_dest = task.targetProfileName;
        NSString *ame265_effective = [self ame265_effectiveProfileName];
        if (ame265_dest.length > 0 && ![ame265_dest isEqualToString:ame265_effective]) {
            NSLog(@"[ModsManager] Task266: cross-profile download (dest=%@ viewing=%@ file=%@)",
                  ame265_dest, ame265_effective, task.displayName ?: task.resourceName ?: @"(nil)");
            [self ame265_showCrossProfileBannerForProfile:ame265_dest
                                                    file:(task.displayName.length > 0 ? task.displayName : task.resourceName)];
        } else if (self.ame265_crossProfileBanner != nil) {
            [self ame265_hideCrossProfileBanner]; // 本实例下载命中：横幅使命完成即撤
        }
    }
    // 基类行为复制：主线程延迟一帧重载（文件系统状态刷新后列表立即可见）
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf reloadResourceList];
    });
}

/// 跨实例横幅（tableHeaderView 卡片，风格对齐 Task264 表尾提示行）。
/// 双语键：resman.mods.cross_profile.text（文件名/目标实例/当前实例三参）、
/// resman.mods.cross_profile.switch（切换按钮）。
- (void)ame265_showCrossProfileBannerForProfile:(NSString *)destProfile file:(NSString *)fileName {
    self.ame265_crossProfileDest = destProfile;
    CGFloat ame265_width = self.tableView.bounds.size.width;
    if (ame265_width <= 0) ame265_width = 320.0; // 首帧 bounds 未定兜底
    // ★ Task275（P3-b8）：横幅定高截断根修——三参长文件名/长实例名在 96pt/2 行
    //   下溢出即截尾。先测文本实际高度，横幅/卡片/按钮全部随动。
    NSString *ame265_text = [NSString stringWithFormat:localize(@"resman.mods.cross_profile.text", NULL),
                             fileName ?: @"", destProfile ?: @"", [self ame265_effectiveProfileName] ?: @""];
    CGFloat ame265_textH = [ame265_text boundingRectWithSize:CGSizeMake(ame265_width - 48.0, CGFLOAT_MAX)
                                                     options:NSStringDrawingUsesLineFragmentOrigin
                                                  attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12.5]}
                                                     context:nil].size.height;
    ame265_textH = MAX(36.0, MIN(ceil(ame265_textH) + 4.0, 78.0));   // 2~4 行自适应封顶
    CGFloat ame265_bannerH = 10.0 + ame265_textH + 6.0 + 26.0 + 12.0 + 8.0;
    UIView *ame265_banner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, ame265_width, ame265_bannerH)];
    ame265_banner.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UIView *ame265_card = [[UIView alloc] initWithFrame:CGRectMake(12, 8, ame265_width - 24, ame265_bannerH - 16)];
    ame265_card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    ame265_card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    ame265_card.layer.cornerRadius = 12.0;
    ame265_card.clipsToBounds = YES;
    [ame265_banner addSubview:ame265_card];

    UILabel *ame265_label = [[UILabel alloc] initWithFrame:CGRectMake(12, 10, ame265_card.bounds.size.width - 24, ame265_textH)];
    ame265_label.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    ame265_label.numberOfLines = 0;
    ame265_label.font = [UIFont systemFontOfSize:12.5];
    ame265_label.textColor = [UIColor labelColor];
    ame265_label.text = ame265_text;
    [ame265_card addSubview:ame265_label];

    UIButton *ame265_switch = [UIButton buttonWithType:UIButtonTypeSystem];
    ame265_switch.frame = CGRectMake(12, 10 + ame265_textH + 6.0, ame265_card.bounds.size.width - 24, 26);
    ame265_switch.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [ame265_switch setTitle:localize(@"resman.mods.cross_profile.switch", NULL) forState:UIControlStateNormal];
    [ame265_switch setTitleColor:[UIColor systemOrangeColor] forState:UIControlStateNormal];
    ame265_switch.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
    ame265_switch.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightSemibold];
    [ame265_switch addTarget:self action:@selector(ame265_switchToCrossProfileTarget) forControlEvents:UIControlEventTouchUpInside];
    [ame265_card addSubview:ame265_switch];

    self.ame265_crossProfileBanner = ame265_banner;
    self.tableView.tableHeaderView = ame265_banner;
}

/// 一键切换：本页改绑目标实例 → 撤横幅 → 表尾目录行联动 → 重扫。
/// 切换后列表展示目标实例 mods 目录（用户下载的文件立即可见）。
- (void)ame265_switchToCrossProfileTarget {
    NSString *ame265_dest = self.ame265_crossProfileDest;
    if (ame265_dest.length == 0) return;
    NSLog(@"[ModsManager] Task266: switch manager binding to cross-profile target %@", ame265_dest);
    [self ame267_pinToProfile:ame265_dest]; // Task267：一键切换 = 用户显式钉定（同款刷新链）
}

- (void)ame265_hideCrossProfileBanner {
    if (self.tableView.tableHeaderView == self.ame265_crossProfileBanner) {
        self.tableView.tableHeaderView = nil;
    }
    self.ame265_crossProfileBanner = nil;
}

#pragma mark - Data Loading

/// 基类刷新钩子：下载完成通知 / viewWillAppear 时重载 Mod 列表。
/// 关键修复（下载成功后资源管理页不刷新）：文件落盘后自动刷新页面。
- (void)reloadResourceList {
    [self loadMods];
}

#pragma mark - Task267 实例切换器 + 跟随/钉定 + 下载落点对账

/// ★ Task271（271-a RC2 根修）：隔离徽标实时刷新——旧实现 setupChipsRow 一次性
///   计算后永不更新（viewWillAppear/钉定/跟随/重扫全不刷新徽标）：用户在版本
///   设置切完隔离回页，列表已扫新目录而徽标仍显示"共享目录"（"切了还是共享"
///   的直接来源）。按当前生效实例重算三态 + 同步表尾扫描目录行。
- (void)ame271_refreshIsolationBadge {
    if (!self.ame219_isoChip) return;
    NSInteger ame271_iso = [ModService ame219_isolationStateForProfile:[self ame265_effectiveProfileName]];
    NSString *ame271_chipKey = (ame271_iso == 1) ? @"ame219.mods.isolated_chip"
        : (ame271_iso == 2) ? @"ame225.mods.sniffed_chip" : @"ame219.mods.shared_chip";
    [self.ame219_isoChip setTitle:localize(ame271_chipKey, nil) forState:UIControlStateNormal];
    UIImage *ame271_icon = (ame271_iso == 1) ? [UIImage systemImageNamed:@"lock.shield"]
        : (ame271_iso == 2) ? [UIImage systemImageNamed:@"sparkle.magnifyingglass"]
        : [UIImage systemImageNamed:@"externaldrive"];
    [self.ame219_isoChip setImage:ame271_icon forState:UIControlStateNormal];
    [self ame264_setupScanFolderFooter];
    NSLog(@"[ModsManager] Task271: isolation badge refresh for profile %@ -> %@ (bound=%@)",
          [self ame265_effectiveProfileName],
          (ame271_iso == 1) ? @"isolated" : ((ame271_iso == 2) ? @"sniffed-isolated" : @"shared"),
          self.profileName ?: @"(nil→follow selected)");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Task267：每次回页都对账一次（用户可能在下载页新下过 mod）。
    [self ame267_reconcileLastDownloadIfNeeded];
    [self ame267_updateProfileChip];
    // ★ Task271：回页即刷新隔离徽标/表尾（版本设置切隔离后回页立见新态）。
    [self ame271_refreshIsolationBadge];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:@"SelectedProfileChanged" object:nil];
}

/// 导航栏实例切换器：titleView 常驻展示当前生效实例名 + 下拉箭头。
- (void)ame267_setupProfileChip {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.font = [UIFont systemFontOfSize:15.0 weight:UIFontWeightSemibold];
    chip.tintColor = [UIColor systemOrangeColor];
    chip.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    [chip addTarget:self action:@selector(ame267_profileChipTapped) forControlEvents:UIControlEventTouchUpInside];
    self.ame267_profileChip = chip;
    [self ame267_updateProfileChip];
    self.navigationItem.titleView = chip;
}

- (void)ame267_updateProfileChip {
    if (!self.ame267_profileChip) return;
    NSString *effective = [self ame265_effectiveProfileName] ?: @"default";
    NSString *title = [NSString stringWithFormat:localize(@"resman.mods.profile_chip", NULL), effective];
    [self.ame267_profileChip setTitle:title forState:UIControlStateNormal];
    [self.ame267_profileChip sizeToFit];
}

/// 选中实例变化：跟随模式下换绑重扫（页面永不过期）；钉定模式仅刷新切换器。
- (void)ame267_selectedProfileChanged:(NSNotification *)note {
    NSLog(@"[ModsManager] Task267: SelectedProfileChanged -> %@ (pin=%d bound=%@)",
          note.object ?: @"(nil)", (int)self.ame267_pinProfile, self.profileName ?: @"(nil)");
    if (self.ame267_pinProfile) {
        [self ame267_updateProfileChip];
        [self ame271_refreshIsolationBadge];   // ★ Task271：钉定态也随选中变化刷新
        return;
    }
    self.ame265_crossProfileDest = nil;
    [self ame265_hideCrossProfileBanner];
    [self ame264_setupScanFolderFooter];
    [self ame267_updateProfileChip];
    [self ame271_refreshIsolationBadge];   // ★ Task271：钉定换绑同步徽标
    [self reloadResourceList];
}

/// 切换器点击：列出全部实例（勾选当前生效项）+ 跟随当前选中实例。
- (void)ame267_profileChipTapped {
    NSString *effective = [self ame265_effectiveProfileName] ?: @"default";
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:localize(@"resman.mods.profile_picker.title", NULL)
                                                                    message:nil
                                                             preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    // 跟随当前选中实例（跟随模式下勾选态由 title 前缀表达；钉定模式下可选回跟随）
    NSString *followTitle = [NSString stringWithFormat:@"%@%@",
        self.ame267_pinProfile ? @"" : @"✓ ",
        localize(@"resman.mods.profile_follow", NULL)];
    [picker addAction:[UIAlertAction actionWithTitle:followTitle
                                               style:UIAlertActionStyleDefault
                                             handler:^(UIAlertAction *action) {
        [weakSelf ame267_followSelection];
    }]];
    // 全部实例（字典键名排序；PLProfiles profiles 键即实例名）
    NSDictionary *profiles = [[PLProfiles current] profiles];
    NSArray *names = [profiles.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in names) {
        NSString *row = [name isEqualToString:effective]
            ? [NSString stringWithFormat:@"✓ %@", name] : name;
        [picker addAction:[UIAlertAction actionWithTitle:row
                                                   style:UIAlertActionStyleDefault
                                                 handler:^(UIAlertAction *action) {
            [weakSelf ame267_pinToProfile:name];
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", NULL)
                                               style:UIAlertActionStyleCancel
                                             handler:nil]];
    [self presentViewController:picker animated:YES completion:nil];
}

/// 钉定到指定实例（语义入口与切换器共用）：换绑 + 撤历史横幅 + 表尾联动 + 重扫。
- (void)ame267_pinToProfile:(NSString *)profileName {
    NSLog(@"[ModsManager] Task267: pin to profile %@", profileName ?: @"(nil)");
    self.ame267_pinProfile = YES;
    self.profileName = profileName;
    self.ame265_crossProfileDest = nil;
    [self ame265_hideCrossProfileBanner];
    [self ame264_setupScanFolderFooter];
    [self ame267_updateProfileChip];
    [self ame271_refreshIsolationBadge];   // ★ Task271：跟随换绑同步徽标
    [self reloadResourceList];
}

/// 回到跟随模式：清钉定与旧绑定，重扫即落在当前选中实例。
- (void)ame267_followSelection {
    NSLog(@"[ModsManager] Task267: follow selected profile (pin cleared)");
    self.ame267_pinProfile = NO;
    self.profileName = nil;
    self.ame265_crossProfileDest = nil;
    [self ame265_hideCrossProfileBanner];
    [self ame264_setupScanFolderFooter];
    [self ame267_updateProfileChip];
    [self ame271_refreshIsolationBadge];   // ★ Task271：回跟随时同步徽标
    [self reloadResourceList];
}

/// 下载落点对账：最近一次成功落盘的 mod 下载若落在别的实例且尚未对过账，
/// 横幅自解释（复用 Task266 横幅视图与一键切换）。
- (void)ame267_reconcileLastDownloadIfNeeded {
    NSDictionary *record = [ModService ame267_lastModDownload];
    if (!record) return;
    double ts = [record[@"ts"] doubleValue];
    if (ts <= 0.0 || ts <= self.ame267_lastReconciledDLTs) return;
    NSString *dest = record[@"profile"];
    NSString *file = record[@"file"];
    if (dest.length == 0) return;
    NSString *effective = [self ame265_effectiveProfileName];
    self.ame267_lastReconciledDLTs = ts; // 无论是否跨实例，看过即对过账
    if ([dest isEqualToString:effective]) return;
    NSLog(@"[ModsManager] Task267: reconcile mismatch (lastDL=%@ viewing=%@ file=%@) -- showing banner", dest, effective, file);
    [self ame265_showCrossProfileBannerForProfile:dest file:file];
}

- (void)loadMods {
    [self setLoading:YES];
    NSString *profile = [self ame265_effectiveProfileName]; // Task265：nil 不再退化 default，跟随选中实例（与下载/启动同源）
    NSLog(@"[ModsManager] Task265 scan profile=%@ (bound=%@)", profile, self.profileName ?: @"(nil→follow selected)");
    __weak typeof(self) weakSelf = self;
    [[ModService sharedService] scanModsForProfile:profile completion:^(NSArray<ModItem *> *mods) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf.localMods removeAllObjects];
            [strongSelf.localMods addObjectsFromArray:mods];
            [strongSelf cacheModificationDates];
            [strongSelf applyFilter];
            [strongSelf setLoading:NO];
            // 首次加载播放连锁进场动画（Prisma-Design 15.3）
            if (!strongSelf.hasPlayedInitialAnimation && strongSelf.localMods.count > 0) {
                strongSelf.hasPlayedInitialAnimation = YES;
                [strongSelf animateCellsInChain];
            }
        });
    }];
}

/// 缓存各 Mod 文件修改时间（排序用，避免比较器内反复 IO）
- (void)cacheModificationDates {
    [self.modDates removeAllObjects];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (ModItem *mod in self.localMods) {
        if (mod.filePath.length == 0) continue;
        NSDate *date = [[fm attributesOfItemAtPath:mod.filePath error:nil] fileModificationDate];
        if (date) self.modDates[mod.filePath] = date;
    }
}

/// 搜索 + 状态筛选 + 排序 → filteredLocalMods + 空态刷新
- (void)applyFilter {
    NSString *query = [self.searchBar.text lowercaseString];
    NSMutableArray<ModItem *> *result = [NSMutableArray array];
    for (ModItem *mod in self.localMods) {
        // 状态筛选
        if (self.filterMode == ModsFilterModeEnabled && mod.disabled) continue;
        if (self.filterMode == ModsFilterModeDisabled && !mod.disabled) continue;
        // 搜索过滤
        if (query.length > 0) {
            NSString *name = mod.displayName.lowercaseString ?: @"";
            NSString *file = mod.fileName.lowercaseString ?: @"";
            if (![name containsString:query] && ![file containsString:query]) continue;
        }
        [result addObject:mod];
    }

    // 排序
    if (self.sortMode == ModsSortModeName) {
        [result sortUsingComparator:^NSComparisonResult(ModItem *_Nonnull a, ModItem *_Nonnull b) {
            NSString *nameA = a.displayName ?: a.fileName;
            NSString *nameB = b.displayName ?: b.fileName;
            return [nameA localizedCaseInsensitiveCompare:nameB];
        }];
    } else {
        // 修改时间降序（最新改动的在前，无时间的排后）
        [result sortUsingComparator:^NSComparisonResult(ModItem *_Nonnull a, ModItem *_Nonnull b) {
            NSDate *dateA = self.modDates[a.filePath];
            NSDate *dateB = self.modDates[b.filePath];
            if (!dateA && !dateB) return NSOrderedSame;
            if (!dateA) return NSOrderedDescending;
            if (!dateB) return NSOrderedAscending;
            return [dateB compare:dateA];
        }];
    }

    [self.filteredLocalMods removeAllObjects];
    [self.filteredLocalMods addObjectsFromArray:result];

    // 空态
    if (result.count == 0) {
        if (self.localMods.count == 0) {
            __weak typeof(self) weakSelf = self;
            [self showEmptyStateWithIcon:nil
                               iconColor:nil
                                 message:localize(@"resman.mods.empty", nil)
                            actionTitle:localize(@"resman.common.go_download", nil)
                          actionHandler:^{
                [weakSelf openDownloadPage];
            }];
        } else {
            [self showEmptyStateWithIcon:@"magnifyingglass"
                               iconColor:[UIColor secondaryLabelColor]
                                 message:localize(@"resman.mods.search_empty", nil)
                            actionTitle:nil
                          actionHandler:nil];
        }
    } else {
        [self hideEmptyState];
    }

    // "选择"按钮可用性
    self.selectButtonItem.enabled = (result.count > 0);

    [self.tableView reloadData];
}

/// 空状态"去下载"：跳转统一下载页（无参数化资源类型入口，进入默认页）
- (void)openDownloadPage {
    DownloadViewController *vc = [[DownloadViewController alloc] init];
    // 关键修复（目标实例不一致）：传入本管理页生效的 profileName（Task265：
    // 含 nil 绑定时的自适应跟随），保证下载写入的实例与当前打开的实例一致
    vc.targetProfileName = [self ame265_effectiveProfileName];
    if (self.navigationController) {
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

#pragma mark - UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self applyFilter];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark - UITableViewDataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredLocalMods.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModCell" forIndexPath:indexPath];
    cell.delegate = self;

    ModItem *mod = self.filteredLocalMods[indexPath.row];
    [cell configureWithMod:mod displayMode:ModTableViewCellDisplayModeLocal];

    // 更新徽章：检测命中（可更新）的 Mod 显示 arrow.up.circle.fill
    [cell setUpdateAvailable:(self.updateResultsByPath[mod.filePath] != nil)];

    // ★ Task288（PocketJ 移植）：实例加载器错配标记——错配时橙色警告徽章
    //   + 元信息行尾说明；不错配传 nil 清除复用残留。
    NSString *ame288_loader = [self ame288_profileLoaderForDisplay];
    if (ame288_loader.length > 0 && [self ame288_mod:mod mismatchesProfileLoader:ame288_loader]) {
        [cell setLoaderIncompatibleDetail:
            [NSString stringWithFormat:localize(@"resman.mods.badge.loader_mismatch", nil), ame288_loader]];
    } else {
        [cell setLoaderIncompatibleDetail:nil];
    }

    // 选择模式下隐藏启用开关（避免与勾选视觉冲突），普通模式恢复
    cell.toggleSwitch.hidden = self.selectModeEnabled;

    return cell;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [ResourceListViewController cardSpacingHeaderView];
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    return ResourceListCardSpacing;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectModeEnabled) {
        // 编辑（勾选）模式：行点击切换勾选，更新标题计数
        [self updateSelectModeTitle];
    } else {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (void)tableView:(UITableView *)tableView didDeselectRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.selectModeEnabled) {
        [self updateSelectModeTitle];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 选择模式下禁用滑动删除，避免误操作
    if (self.selectModeEnabled) return nil;

    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                               title:localize(@"resman.common.delete", nil)
                                                                             handler:^(UIContextualAction *_Nonnull action, __kindof UIView *_Nonnull sourceView, void (^_Nonnull completionHandler)(BOOL)) {
        ModItem *modToDelete = self.filteredLocalMods[indexPath.row];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.confirm_delete", nil)
                                                                       message:[NSString stringWithFormat:localize(@"resman.common.delete_message_irreversible", nil), modToDelete.displayName]
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *_Nonnull a) {
            completionHandler(NO);
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_Nonnull a) {
            NSError *error = nil;
            [[ModService sharedService] deleteMod:modToDelete error:&error];
            if (error) {
                NSLog(@"[ModsManager] Error deleting mod: %@", error);
                completionHandler(NO);
            } else {
                // 同步数据源并删除行
                NSUInteger idxFull = [self.localMods indexOfObject:modToDelete];
                if (idxFull != NSNotFound) [self.localMods removeObjectAtIndex:idxFull];
                [self.modDates removeObjectForKey:modToDelete.filePath];
                [self.updateResultsByPath removeObjectForKey:modToDelete.filePath];
                [self.filteredLocalMods removeObjectAtIndex:indexPath.row];
                [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
                completionHandler(YES);
            }
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
    deleteAction.backgroundColor = [UIColor systemRedColor];

    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

#pragma mark - 批量选择模式（基类工具栏整合）

- (void)enterSelectMode {
    if (self.filteredLocalMods.count == 0) return;
    [self setSelectMode:YES]; // 基类处理编辑模式 + 工具栏滑入 + selectModeDidChange:
}

- (void)exitSelectMode {
    [self setSelectMode:NO];
}

- (void)selectModeDidChange:(BOOL)enabled {
    if (enabled) {
        // 填充批量操作按钮（首次懒创建，之后保持在 stack 中随工具栏显隐）
        if (!self.batchEnableButton) {
            self.batchEnableButton = [self makeBatchActionButtonWithTitle:localize(@"resman.common.enable", nil) tintColor:[UIColor systemGreenColor]];
            [self.batchEnableButton addTarget:self action:@selector(batchEnableTapped) forControlEvents:UIControlEventTouchUpInside];

            self.batchDisableButton = [self makeBatchActionButtonWithTitle:localize(@"resman.common.disable", nil) tintColor:[UIColor systemOrangeColor]];
            [self.batchDisableButton addTarget:self action:@selector(batchDisableTapped) forControlEvents:UIControlEventTouchUpInside];

            self.batchDeleteButton = [self makeBatchActionButtonWithTitle:localize(@"resman.common.delete", nil) tintColor:[UIColor systemRedColor]];
            [self.batchDeleteButton addTarget:self action:@selector(batchDeleteTapped) forControlEvents:UIControlEventTouchUpInside];

            [self.batchActionStack addArrangedSubview:self.batchEnableButton];
            [self.batchActionStack addArrangedSubview:self.batchDisableButton];
            [self.batchActionStack addArrangedSubview:self.batchDeleteButton];
        }
    }
    [self updateNavigationButtons];
    [self.tableView reloadData];
}

/// 批量操作胶囊按钮
- (UIButton *)makeBatchActionButtonWithTitle:(NSString *)title tintColor:(UIColor *)color {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [button setTitleColor:color forState:UIControlStateNormal];
    button.backgroundColor = [color colorWithAlphaComponent:0.14];
    button.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    button.layer.cornerRadius = 15.0;
    button.layer.cornerCurve = kCACornerCurveContinuous;
    button.layer.masksToBounds = YES;
    [button.heightAnchor constraintEqualToConstant:30].active = YES;
    [button setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return button;
}

/// 当前勾选的 ModItem 列表（基于基类 selectedIndexPaths）
- (NSArray<ModItem *> *)selectedModItems {
    NSMutableArray<ModItem *> *items = [NSMutableArray array];
    NSArray<NSIndexPath *> *indexPaths = [self.selectedIndexPaths sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
        return [a compare:b];
    }];
    for (NSIndexPath *indexPath in indexPaths) {
        if (indexPath.row < (NSInteger)self.filteredLocalMods.count) {
            [items addObject:self.filteredLocalMods[indexPath.row]];
        }
    }
    return items;
}

- (void)batchEnableTapped {
    [self batchSetDisabled:NO];
}

- (void)batchDisableTapped {
    [self batchSetDisabled:YES];
}

/// 批量启用（target=NO）/ 禁用（target=YES）：仅对状态不符的项执行切换
- (void)batchSetDisabled:(BOOL)target {
    NSArray<ModItem *> *mods = [self selectedModItems];
    if (mods.count == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.none_selected", nil)];
        return;
    }

    NSInteger success = 0, failed = 0;
    for (ModItem *mod in mods) {
        if (mod.disabled == target) continue; // 状态已符合，跳过
        NSError *error = nil;
        if ([[ModService sharedService] toggleEnableForMod:mod error:&error]) {
            success++;
        } else {
            failed++;
            NSLog(@"[ModsManager] Batch toggle failed: %@ - %@", mod.displayName, error);
        }
    }

    [self setSelectMode:NO];
    [self loadMods]; // 文件名（.disabled 后缀）已变化，重新扫描

    NSString *verb = target ? localize(@"resman.common.disable", nil) : localize(@"resman.common.enable", nil);
    if (failed > 0) {
        [self showDialogWithTitle:[NSString stringWithFormat:localize(@"resman.mods.batch.toggle_complete", nil), verb]
                         message:[NSString stringWithFormat:localize(@"resman.mods.batch.result_message", nil), (long)success, (long)failed]];
    }
}

- (void)batchDeleteTapped {
    NSArray<ModItem *> *mods = [self selectedModItems];
    if (mods.count == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.none_selected", nil)];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"resman.common.batch_delete", nil)
                                                                   message:[NSString stringWithFormat:localize(@"resman.mods.batch.delete_message", nil), (long)mods.count]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.delete", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSMutableArray<ModItem *> *failedMods = [NSMutableArray array];
        for (ModItem *mod in mods) {
            NSError *error = nil;
            if (![[ModService sharedService] deleteMod:mod error:&error]) {
                NSLog(@"[ModsManager] Batch delete failed: %@ - %@", mod.displayName, error);
                [failedMods addObject:mod];
            } else {
                [strongSelf.modDates removeObjectForKey:mod.filePath];
                [strongSelf.updateResultsByPath removeObjectForKey:mod.filePath];
            }
        }

        [strongSelf setSelectMode:NO];
        [strongSelf loadMods]; // 重新扫描同步数据源

        if (failedMods.count > 0) {
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (ModItem *m in failedMods) [names addObject:m.displayName ?: m.fileName];
            [strongSelf showDialogWithTitle:[NSString stringWithFormat:localize(@"resman.common.delete_complete_failures", nil), (long)failedMods.count]
                                    message:[names componentsJoinedByString:@"\n"]];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Import Mod

- (void)importModTapped {
    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:[self ame265_effectiveProfileName] error:&dirError]; // Task264+265：跟随生效 profile（nil 绑定自适应跟随选中实例），不再恒写 default 主目录
    if (!modsDir) {
        [self showDialogWithTitle:localize(@"resman.common.cannot_import", nil) message:dirError.localizedDescription ?: localize(@"resman.mods.dir_not_found", nil)];
        return;
    }

    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.sun.java.jar", @"public.item"]
                                                                                                   inMode:UIDocumentPickerModeImport];
    picker.allowsMultipleSelection = YES;
    picker.delegate = self;
    picker.title = localize(@"resman.mods.picker_title", nil);
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;

    NSError *dirError = nil;
    NSString *modsDir = [[ModService sharedService] ensureModsFolderForProfile:[self ame265_effectiveProfileName] error:&dirError]; // Task264+265：跟随生效 profile
    if (!modsDir) {
        [self showDialogWithTitle:localize(@"resman.common.import_failed", nil) message:dirError.localizedDescription ?: localize(@"resman.mods.dir_not_found", nil)];
        return;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSInteger successCount = 0;
    NSMutableArray<NSString *> *failedFiles = [NSMutableArray array];

    for (NSURL *url in urls) {
        if ([url hasDirectoryPath]) continue; // Task264：目录 URL（文件 App 定点打开回调）不参与拷贝
        BOOL accessing = [url startAccessingSecurityScopedResource];
        @try {
            NSString *fileName = url.lastPathComponent;
            NSString *destPath = [modsDir stringByAppendingPathComponent:fileName];
            // 同名文件处理
            // 同名文件处理（★ Task268 scan-d #6：循环探测 _copy/_copy_N——
            // 旧版只试一次，_copy 也被占时 copyItemAtPath 直接失败）。
            if ([fm fileExistsAtPath:destPath]) {
                NSString *baseName = [fileName stringByDeletingPathExtension];
                NSString *ext = [fileName pathExtension];
                NSString *ame268_cand = nil;
                for (NSInteger ame268_n = 1; ame268_n < 1000; ame268_n++) {
                    NSString *ame268_name = (ame268_n == 1)
                        ? [NSString stringWithFormat:@"%@_copy.%@", baseName, ext]
                        : [NSString stringWithFormat:@"%@_copy_%ld.%@", baseName, (long)(ame268_n - 1), ext];
                    NSString *ame268_path = [modsDir stringByAppendingPathComponent:ame268_name];
                    if (![fm fileExistsAtPath:ame268_path]) { ame268_cand = ame268_path; break; }
                }
                if (ame268_cand) destPath = ame268_cand;
            }
            NSError *copyError = nil;
            [fm copyItemAtPath:url.path toPath:destPath error:&copyError];
            if (copyError) {
                [failedFiles addObject:[NSString stringWithFormat:@"%@: %@", fileName, copyError.localizedDescription]];
            } else {
                successCount++;
            }
        } @finally {
            if (accessing) [url stopAccessingSecurityScopedResource];
        }
    }

    [self loadMods];

    if (failedFiles.count > 0) {
        [self showDialogWithTitle:[NSString stringWithFormat:localize(@"resman.common.import_result", nil), (long)successCount, (long)failedFiles.count]
                          message:[failedFiles componentsJoinedByString:@"\n"]];
    } else {
        NSLog(@"[ModsManager] Successfully imported %ld mods", (long)successCount);
    }
}

#pragma mark - ModTableViewCellDelegate

- (void)modCellDidTapToggle:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ModItem *mod = self.filteredLocalMods[indexPath.row];
    NSError *error = nil;
    BOOL success = [[ModService sharedService] toggleEnableForMod:mod error:&error];
    if (!success) {
        // Task217（"部分 Mod 无法点击"根修）：旧实现失败只 NSLog，开关随后被
        // updateToggleState 按模型状态弹回——用户视角 = 点了完全没反应。
        // 病灶家族：① 源文件已被移动/删除（更新替换 / 文件 App 整理后的
        // 陈旧列表项）；② 目标同名冲突（foo.jar 与 foo.jar.disabled 并存）。
        // 现在：失败一律弹窗给出真实原因；ModServiceError 201（源缺失）
        // 额外触发自愈重扫，幽灵条目即刻从列表消失。
        NSLog(@"[ModsManager] Task217: toggle failed for %@ -- %@", mod.filePath, error);
        [self showDialogWithTitle:localize(@"mods.toggle.failed", nil)
                          message:error.localizedDescription ?: localize(@"common.unknown_error", nil)];   // ★ Task275（i18n）
        if ([error.domain isEqualToString:@"ModServiceError"] && error.code == 201) {
            [self loadMods];
        }
    }
    // 无论成败按服务端状态回滚/刷新开关视觉（失败时 mod.disabled 未变）
    if ([cell isKindOfClass:[ModTableViewCell class]]) {
        [(ModTableViewCell *)cell updateToggleState:mod.disabled];
    }
}

- (void)modCellDidTapOpenLink:(UITableViewCell *)cell {
    NSIndexPath *indexPath = [self.tableView indexPathForCell:cell];
    if (!indexPath) return;

    ModItem *modItem = self.filteredLocalMods[indexPath.row];
    if (modItem.onlineID.length > 0) {
        NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://modrinth.com/mod/%@", modItem.onlineID]];
        if (url) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
        }
    } else {
        [self showDialogWithTitle:localize(@"resman.mods.link_unavailable", nil) message:localize(@"resman.mods.link_unavailable_message", nil)];
    }
}

#pragma mark - 内置更新流程（状态机：空闲 → 检查中 → 确认 → 下载替换中 → 完成 → 空闲）

/// 进入更新忙态：禁用按钮、导航栏转圈 + 阶段文本
- (void)enterUpdateBusyWithText:(NSString *)text {
    self.isUpdateBusy = YES;
    self.updateBusyText = [text copy];
    [self updateNavigationButtons];
}

/// 更新忙态内更新阶段文本（仅改标题，不重建按钮组）
- (void)setUpdateBusyTextOnly:(NSString *)text {
    self.updateBusyText = [text copy];
    self.navigationItem.title = self.updateBusyText;
}

/// 退出更新忙态：恢复按钮与标题
- (void)exitUpdateBusy {
    self.isUpdateBusy = NO;
    self.updateBusyText = nil;
    [self.navSpinner stopAnimating];
    [self updateNavigationButtons];
}

/// 顶栏"检查更新"入口：
/// 1) 补齐每个 Mod 的 SHA1（Modrinth 反查依赖）
/// 2) dispatch_group + 限流 3 并发调 ModUpdateService checkUpdateForMod
/// 3) 结果三分类：可更新 / 最新（已识别无更新）/ 无法识别（双源未命中）
/// 4) 可更新 > 0 → 确认弹窗；否则提示"所有 Mod 均为最新版本"
- (void)checkForUpdates {
    if (self.isUpdateBusy) return; // 防重复触发
    if (self.localMods.count == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.no_local_for_update", nil)];
        return;
    }

    // 从当前 profile 的 lastVersionId 解析 gameVersion 和 loader
    NSString *lastVersionId = PLProfiles.current.selectedProfile[@"lastVersionId"];
    if (lastVersionId.length == 0) {
        [self showDialogWithTitle:localize(@"resman.common.notice", nil) message:localize(@"resman.mods.no_version_info", nil)];
        return;
    }
    // Task217：与 ProfileSettings currentGameVersion 同源——旧内联解析只认
    // "-<loader>-" 中缀式，fabric 的 "fabric-loader-<loaderVer>-<mcVer>" 前缀式
    // 直接漏网（gameVersion=nil → "检查更新"对 Fabric 实例永远走无版本分支）。
    // 改用 ModpackExportService parseVersionId（26.x + 全形态覆盖）。
    NSDictionary *ame217_parsed = [ModpackExportService parseVersionId:lastVersionId];
    NSString *gameVersion = ame217_parsed[@"minecraft"];
    NSString *loader = ame217_parsed[@"loader"];
    if (![gameVersion isKindOfClass:[NSString class]] || gameVersion.length == 0) {
        // 纯 <mc> 格式，无 loader
        gameVersion = lastVersionId;
        loader = nil;
    }

    // 若处于选择模式先退出（后续数据可能变化）
    if (self.selectModeEnabled) {
        [self setSelectMode:NO];
    }

    NSArray<ModItem *> *mods = [self.localMods copy];
    [self enterUpdateBusyWithText:localize(@"resman.mods.update.checking", nil)];

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        // 阶段 1：补齐 SHA1（Modrinth 反查必需；大文件流式计算放后台）
        for (ModItem *mod in mods) {
            if (mod.fileSHA1.length == 0) {
                mod.fileSHA1 = ModsManagerSHA1ForFile(mod.filePath);
            }
        }

        // 阶段 2：并发检查（dispatch_group 汇总 + 信号量限流 3）
        dispatch_group_t group = dispatch_group_create();
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(3);
        NSObject *lock = [[NSObject alloc] init];
        NSMutableArray<ModUpdateResult *> *updatable = [NSMutableArray array];
        __block NSInteger unrecognized = 0;
        __block NSInteger completed = 0;
        NSInteger total = mods.count;

        for (ModItem *mod in mods) {
            dispatch_group_enter(group);
            dispatch_async(queue, ^{
                dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
                [[ModUpdateService sharedService] checkUpdateForMod:mod
                                                        gameVersion:gameVersion
                                                             loader:loader
                                                        projectType:@"mod"
                                                         completion:^(ModUpdateResult *_Nullable result) {
                    // 服务保证主线程回调
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    @synchronized(lock) {
                        if (result) {
                            if ([result hasUpdate]) [updatable addObject:result];
                        } else {
                            unrecognized++; // 双源未命中 → 无法识别
                        }
                        completed++;
                    }
                    if (strongSelf) {
                        [strongSelf setUpdateBusyTextOnly:[NSString stringWithFormat:localize(@"resman.mods.update.checking_progress", nil), (long)completed, (long)total]];
                    }
                    dispatch_semaphore_signal(semaphore);
                    dispatch_group_leave(group);
                }];
            });
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf exitUpdateBusy];

            // 徽章：命中更新的 Mod 显示更新标记
            [strongSelf.updateResultsByPath removeAllObjects];
            for (ModUpdateResult *result in updatable) {
                if (result.localFilePath.length > 0) {
                    strongSelf.updateResultsByPath[result.localFilePath] = result;
                }
            }
            [strongSelf.tableView reloadData];

            if (updatable.count == 0) {
                NSString *message = localize(@"resman.mods.update.all_latest", nil);
                if (unrecognized > 0) {
                    message = [NSString stringWithFormat:localize(@"resman.mods.update.all_latest_skipped", nil), (long)unrecognized];
                }
                [strongSelf showDialogWithTitle:localize(@"resman.mods.check_update", nil) message:message];
            } else {
                [strongSelf presentUpdateConfirmAlertWithResults:[updatable copy] skipped:unrecognized];
            }
        });
    });
}

/// 更新确认弹窗：列出每项（名称 当前版本 → 新版本），全部更新 / 取消
- (void)presentUpdateConfirmAlertWithResults:(NSArray<ModUpdateResult *> *)results skipped:(NSInteger)skipped {
    if (results.count == 0) return;

    // 构建列表文本（超长时截断保护，最多列 8 项）
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger maxLines = 8;
    for (NSUInteger i = 0; i < results.count && i < maxLines; i++) {
        ModUpdateResult *result = results[i];
        NSString *name = result.localFilePath.lastPathComponent ?: localize(@"resman.common.unknown_file", nil);
        // 优先用 ModItem 显示名
        for (ModItem *mod in self.localMods) {
            if ([mod.filePath isEqualToString:result.localFilePath] && mod.displayName.length > 0) {
                name = mod.displayName;
                break;
            }
        }
        NSString *current = result.currentVersion.versionNumber ?: @"?";
        NSString *target = result.candidateVersions.firstObject.versionNumber ?: localize(@"resman.mods.update.latest", nil);
        [lines addObject:[NSString stringWithFormat:@"%@\n%@ → %@", name, current, target]];
    }
    if (results.count > maxLines) {
        [lines addObject:[NSString stringWithFormat:localize(@"resman.mods.update.more_total", nil), (long)results.count]];
    }
    if (skipped > 0) {
        [lines addObject:[NSString stringWithFormat:localize(@"resman.mods.update.skipped_line", nil), (long)skipped]];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:localize(@"resman.mods.update.found_title", nil), (long)results.count]
                                                                   message:[lines componentsJoinedByString:@"\n"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.mods.update.update_all", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *_Nonnull action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf performModUpdatesWithResults:results skipped:skipped];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/// 执行更新：并发下载到临时目录（PLDownloadClient，带 SHA1 校验 + 镜像候选）
/// → 全部下载完成后替换文件（删旧 → 移新，保留旧文件的禁用状态）
/// → 清徽章、重新加载列表、汇总提示
- (void)performModUpdatesWithResults:(NSArray<ModUpdateResult *> *)results skipped:(NSInteger)skipped {
    if (results.count == 0 || self.isUpdateBusy) return;

    // 构建下载任务列表
    NSMutableArray<ModUpdateTask *> *tasks = [NSMutableArray array];
    for (ModUpdateResult *result in results) {
        ModVersion *target = result.candidateVersions.firstObject;
        if (!target) continue; // 无候选版本，跳过
        ModUpdateTask *task = [[ModUpdateTask alloc] init];
        task.result = result;
        task.targetVersion = target;
        for (ModItem *mod in self.localMods) {
            if ([mod.filePath isEqualToString:result.localFilePath]) {
                task.mod = mod;
                break;
            }
        }
        [tasks addObject:task];
    }
    if (tasks.count == 0) return;

    // 临时目录
    NSString *tempDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ModUpdate_%@", [[NSUUID UUID] UUIDString]]];
    NSError *mkError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:tempDir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:&mkError];
    if (mkError) {
        [self showDialogWithTitle:localize(@"resman.mods.update.failed_title", nil)
                         message:[NSString stringWithFormat:localize(@"resman.mods.update.temp_dir_failed", nil), mkError.localizedDescription]];
        return;
    }

    [self enterUpdateBusyWithText:[NSString stringWithFormat:localize(@"resman.mods.update.downloading", nil), 0L, (long)tasks.count]];

    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_t group = dispatch_group_create();
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(4);
    NSObject *progressLock = [[NSObject alloc] init];
    __block NSInteger downloadDone = 0;
    NSInteger total = tasks.count;
    __weak typeof(self) weakSelf = self;

    for (ModUpdateTask *task in tasks) {
        // 从 primaryFile 提取下载信息（url / filename / sha1）
        NSDictionary *primaryFile = task.targetVersion.primaryFile;
        if (![primaryFile isKindOfClass:[NSDictionary class]]) {
            task.downloadSucceeded = NO;
            continue;
        }
        NSString *urlString = [primaryFile[@"url"] isKindOfClass:[NSString class]] ? primaryFile[@"url"] : nil;
        NSString *fileName = [primaryFile[@"filename"] isKindOfClass:[NSString class]] ? primaryFile[@"filename"] : nil;
        NSDictionary *hashes = [primaryFile[@"hashes"] isKindOfClass:[NSDictionary class]] ? primaryFile[@"hashes"] : nil;
        NSString *sha1 = [hashes[@"sha1"] isKindOfClass:[NSString class]] ? hashes[@"sha1"] : nil;
        NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;

        if (!url || fileName.length == 0) {
            task.downloadSucceeded = NO;
            continue;
        }

        dispatch_group_enter(group);
        dispatch_async(queue, ^{
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

            PLDownloadRequest *request = [[PLDownloadRequest alloc] init];
            // 镜像候选列表（官方 CDN + MCIM 镜像，按用户策略排序）
            request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                                   resourceType:PLMirrorResourceTypeAssetDownload];
            // 版本文件自带 SHA1 → 启用校验（失败由下载器按镜像/退避节奏重试）
            request.expectedSHA1 = sha1.length > 0 ? sha1 : nil;
            request.destinationPath = [tempDir stringByAppendingPathComponent:fileName];
            request.taskIdentifier = [NSString stringWithFormat:@"modupdate-%@", [[NSUUID UUID] UUIDString]];
            request.allowZipFallbackCheck = YES; // 无 SHA1 时 zip EOCD 兜底

            [[PLDownloadClient sharedClient] startRequest:request
                                                 progress:nil
                                                    speed:nil
                                               completion:^(BOOL success, NSError *_Nullable error) {
                // 回调在下载器内部串行队列（非主线程）
                if (success) {
                    task.downloadSucceeded = YES;
                    task.tempPath = request.destinationPath;
                } else {
                    task.downloadSucceeded = NO;
                    task.tempPath = nil;
                    NSLog(@"[ModsManager] Update download failed (%@): %@", fileName, error);
                }

                NSInteger done;
                @synchronized(progressLock) { downloadDone++; done = downloadDone; }
                dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf) {
                        [strongSelf setUpdateBusyTextOnly:[NSString stringWithFormat:localize(@"resman.mods.update.downloading", nil), (long)done, (long)total]];
                    }
                });

                dispatch_semaphore_signal(semaphore);
                dispatch_group_leave(group);
            }];
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            [[NSFileManager defaultManager] removeItemAtPath:tempDir error:nil];
            return;
        }

        // 阶段：替换文件（后台执行文件操作，完成后回主线程汇总）
        [strongSelf setUpdateBusyTextOnly:localize(@"resman.mods.update.replacing", nil)];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSFileManager *fm = [NSFileManager defaultManager];
            NSInteger successCount = 0;
            NSInteger failCount = 0;

            for (ModUpdateTask *task in tasks) {
                NSString *fileName = task.result.localFilePath.lastPathComponent ?: localize(@"resman.common.unknown_file", nil);
                if (!task.downloadSucceeded || task.tempPath.length == 0) {
                    failCount++;
                    continue;
                }
                // 下载文件名优先（新版本文件名可能变化）
                NSDictionary *primaryFile = task.targetVersion.primaryFile;
                NSString *downloadName = [primaryFile isKindOfClass:[NSDictionary class]]
                    ? ([primaryFile[@"filename"] isKindOfClass:[NSString class]] ? primaryFile[@"filename"] : nil)
                    : nil;
                if (downloadName.length > 0) fileName = downloadName;

                NSString *oldPath = task.result.localFilePath;
                NSString *oldDir = [oldPath stringByDeletingLastPathComponent];
                // 旧文件处于禁用状态（.disabled 后缀）时，新文件同样禁用，保留用户意图
                BOOL keepDisabled = [oldPath.lowercaseString hasSuffix:@".disabled"];
                NSString *newPath = [oldDir stringByAppendingPathComponent:fileName];
                if (keepDisabled && ![newPath.lowercaseString hasSuffix:@".disabled"]) {
                    newPath = [newPath stringByAppendingString:@".disabled"];
                }

                @try {
                    // 删旧 → 移新（ZL2 ModUpdater 替换逻辑）
                    if ([fm fileExistsAtPath:oldPath]) {
                        [fm removeItemAtPath:oldPath error:nil];
                    }
                    if (![newPath isEqualToString:oldPath] && [fm fileExistsAtPath:newPath]) {
                        [fm removeItemAtPath:newPath error:nil];
                    }
                    NSError *moveError = nil;
                    if ([fm moveItemAtPath:task.tempPath toPath:newPath error:&moveError]) {
                        successCount++;
                        task.tempPath = nil; // 已移走，避免后续误判
                    } else {
                        failCount++;
                        NSLog(@"[ModsManager] Update replace failed (%@): %@", fileName, moveError);
                    }
                } @catch (NSException *exception) {
                    failCount++;
                    NSLog(@"[ModsManager] Update replace exception (%@): %@", fileName, exception);
                }
            }

            // 清理临时目录
            [fm removeItemAtPath:tempDir error:nil];

            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) innerSelf = weakSelf;
                if (!innerSelf) return;
                // 清除更新徽章 + 退出忙态 + 重新加载列表
                [innerSelf.updateResultsByPath removeAllObjects];
                [innerSelf exitUpdateBusy];
                [innerSelf loadMods];
                [innerSelf showDialogWithTitle:localize(@"resman.mods.update.done_title", nil)
                                      message:[NSString stringWithFormat:localize(@"resman.mods.update.done_message", nil),
                                               (long)successCount, (long)failCount, (long)skipped]];
            });
        });
    });
}

#pragma mark - 工具方法

- (void)showDialogWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.ok", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
