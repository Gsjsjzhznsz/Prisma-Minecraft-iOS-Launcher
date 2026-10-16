//
//  ResourceListViewController.m
//  Amethyst
//
//  资源管理列表页公共基类实现。
//  背景模式与 ModsManagerViewController / ShadersManagerViewController 现有做法一致：
//  makeViewControllerTransparent + applyEffectToView:（毛玻璃/半透明随用户设置自适应）。
//

#import "ResourceListViewController.h"
#import "BackgroundManager.h"
#import "LauncherPreferences.h"
#import "DownloadTaskItem.h"
#import "DownloadTaskManager.h"
#import "utils.h"

CGFloat const ResourceListCardSpacing = 4.0;    // space-sm：卡片垂直间距（Prisma-Design 4.1）
CGFloat const ResourceListCardSideInset = 16.0; // space-3xl：列表左右边距

static CGFloat const kBatchToolbarHeight = 48.0;
static CGFloat const kBatchToolbarBottomGap = 12.0; // 工具栏与安全区底部的间隙

@interface ResourceListViewController ()
// 基础视图（.h 中 readonly，内部可写）
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, copy) NSString *pageTitle;
@property (nonatomic, copy) NSString *resourceTypeIcon;
@property (nonatomic, strong) UIColor *resourceTypeIconColor;
// 空状态
@property (nonatomic, strong) UIView *emptyStateView;
@property (nonatomic, strong) UIImageView *emptyIconView;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UIButton *emptyActionButton;
@property (nonatomic, copy, nullable) void (^emptyActionHandler)(void);
// 加载态
@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
// 批量选择模式
@property (nonatomic, assign) BOOL selectModeEnabled;
@property (nonatomic, strong) UIView *batchToolbar;
@property (nonatomic, strong) UIButton *selectAllButton;
@property (nonatomic, strong) UIButton *cancelButton;
@property (nonatomic, strong) UIStackView *batchActionStack;
@end

@implementation ResourceListViewController

#pragma mark - Init

- (instancetype)initWithTitle:(NSString *)title resourceTypeIcon:(NSString *)icon iconColor:(UIColor *)color {
    // 等价于 initWithNibName:nil bundle:nil，避免调用本类 NS_UNAVAILABLE 的初始化方法
    self = [super init];
    if (self) {
        _pageTitle = [title copy];
        _resourceTypeIcon = [icon copy];
        _resourceTypeIconColor = color;
    }
    return self;
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    if (self.pageTitle.length > 0) {
        self.title = self.pageTitle;
    }
    self.view.backgroundColor = [UIColor systemBackgroundColor]; // Task136：主题化页面底色
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    [self setupUI];

    // 给 view 添加毛玻璃遮挡层，防止 push 转场时透出栈底页面内容（与现有管理页一致）
    [[BackgroundManager sharedManager] applyEffectToView:self.view];

    // 监听背景效果变化通知，背景切换时重新应用透明效果
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // 监听资源下载完成通知：文件落盘后自动重载列表。
    // 关键修复（下载成功后资源管理页不刷新）：DownloadTaskManager 在任务进入
    // Completed 终态时统一发 DownloadTaskManagerTaskCompletedNotification，
    // 子类实现 -reloadResourceList 完成各自的列表刷新。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleDownloadTaskCompletedNotification:)
                                                 name:DownloadTaskManagerTaskCompletedNotification
                                               object:nil];

    // ★ Task275（P2-b7）：选中实例变化实时跟随——四资源管理页的“跟随”此前只跟到
    //   扫描时刻（服务层解析 selected），页面在场期间实例被迁移/合并/切换时列表
    //   陈旧；ModsManager 已有同款观察者，基类统一补齐，子类钩子各自重扫。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame275_selectedProfileDidChange)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

/// Task275（P2-b7）：选中实例变化子类钩子（默认空实现，见 viewDidLoad 注释）。
- (void)ame275_selectedProfileDidChange {
}

/// 下载任务完成通知处理：该任务属于资源类型任务（mod/shader/resourcepack/datapack/world）时，
/// 通知子类重载列表。下载中心通用任务（如 Minecraft 本体）不影响资源列表。
- (void)handleDownloadTaskCompletedNotification:(NSNotification *)notification {
    DownloadTaskItem *task = notification.userInfo[DownloadTaskManagerTaskKey];
    NSString *type = task.resourceType;
    if (![type isKindOfClass:[NSString class]] || type.length == 0) return;

    static NSSet<NSString *> *resourceTypes = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        resourceTypes = [NSSet setWithObjects:
            DownloadTaskResourceTypeMod,
            DownloadTaskResourceTypeShader,
            DownloadTaskResourceTypeResourcePack,
            DownloadTaskResourceTypeDataPack,
            DownloadTaskResourceTypeWorld,
            nil];
    });
    if (![resourceTypes containsObject:type]) return;

    // 主线程延迟一帧重载，确保文件系统状态已刷新（与 UI 刷新节奏一致）
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf reloadResourceList];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // viewDidLoad 时 self.view.bounds 可能为 zero，applyEffectToView: 插入的 blurView
    // frame 为 zero；在 viewWillAppear 中重新应用（此时 bounds 已正确）
    [[BackgroundManager sharedManager] applyEffectToView:self.view];

    // 关键修复（下载成功后资源管理页不刷新）：每次页面显示时重载列表，
    // 覆盖从下载页/前台返回、切换实例等场景下"文件已落盘但页面不更新"的情况。
    [self reloadResourceList];
}

- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[BackgroundManager sharedManager] applyEffectToView:self.view];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
    // 毛玻璃↔半透明切换后，搜索栏输入框背景需刷新并重打胶囊样式
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
    [self applyCapsuleStyleToSearchField];
    // 重新加载 cell，让每个 cell 重新应用 applyEffectToView:（毛玻璃/半透明）
    [self.tableView reloadData];
}

#pragma mark - UI 构建

- (void)setupUI {
    [self setupSearchBar];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupEmptyStateView];
    [self setupBatchToolbar];

    [NSLayoutConstraint activateConstraints:@[
        // 搜索栏：safeArea 顶部 + 8，左右 16
        [self.searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [self.searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:ResourceListCardSideInset],
        [self.searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-ResourceListCardSideInset],

        // tableView：搜索栏以下、safeArea 底部以上，左右留出卡片边距
        [self.tableView.topAnchor constraintEqualToAnchor:self.searchBar.bottomAnchor constant:4],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:ResourceListCardSideInset],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-ResourceListCardSideInset],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],

        // 空状态视图覆盖 tableView 区域
        [self.emptyStateView.topAnchor constraintEqualToAnchor:self.tableView.topAnchor],
        [self.emptyStateView.leadingAnchor constraintEqualToAnchor:self.tableView.leadingAnchor],
        [self.emptyStateView.trailingAnchor constraintEqualToAnchor:self.tableView.trailingAnchor],
        [self.emptyStateView.bottomAnchor constraintEqualToAnchor:self.tableView.bottomAnchor],

        // 批量工具栏：底部贴 safeArea，左右 16，固定高度
        [self.batchToolbar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:ResourceListCardSideInset],
        [self.batchToolbar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-ResourceListCardSideInset],
        [self.batchToolbar.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-kBatchToolbarBottomGap],
        [self.batchToolbar.heightAnchor constraintEqualToConstant:kBatchToolbarHeight],
    ]];
}

- (void)setupSearchBar {
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectZero];
    self.searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    // 适配自定义启动器背景：透明化 searchBar 默认不透明背景
    [[BackgroundManager sharedManager] applyEffectToSearchBar:self.searchBar];
    [self applyCapsuleStyleToSearchField];
    [self.view addSubview:self.searchBar];
}

- (void)applyCapsuleStyleToSearchField {
    // 胶囊形搜索输入框：圆角 = 高度/2、半透明背景（白 0.08）、保留系统放大镜图标
    UISearchTextField *field = self.searchBar.searchTextField;
    field.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    field.layer.cornerRadius = 18.0; // 输入框标准高度 36 / 2
    field.layer.cornerCurve = kCACornerCurveContinuous;
    field.layer.masksToBounds = YES;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
}

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    // 卡片自带间距与背景，禁用系统分隔线；rowHeight 由子类决定
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.tableFooterView = [UIView new];
    // 批量选择模式：编辑态下允许多选勾选
    self.tableView.allowsMultipleSelectionDuringEditing = YES;
    [self.view addSubview:self.tableView];
}

- (void)setupActivityIndicator {
    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];
    [NSLayoutConstraint activateConstraints:@[
        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.tableView.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.tableView.centerYAnchor],
    ]];
}

- (void)setupEmptyStateView {
    // 空状态：60×60 SF Symbol 图标 + 说明文字 + 可选胶囊引导按钮（accent 底白字）
    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];

    self.emptyIconView = [[UIImageView alloc] init];
    self.emptyIconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyIconView.contentMode = UIViewContentModeScaleAspectFit;
    self.emptyIconView.tintColor = [UIColor secondaryLabelColor];
    self.emptyIconView.image = [UIImage systemImageNamed:@"tray"];

    self.emptyLabel = [[UILabel alloc] init];
    self.emptyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; // 启用 Dynamic Type
    self.emptyLabel.textColor = [UIColor secondaryLabelColor];
    self.emptyLabel.textAlignment = NSTextAlignmentCenter;
    self.emptyLabel.numberOfLines = 0;

    self.emptyActionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.emptyActionButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.emptyActionButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.emptyActionButton.backgroundColor = accentColor();
    self.emptyActionButton.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 20);
    self.emptyActionButton.layer.cornerRadius = 20.0; // 高度 40 / 2，完美胶囊端
    self.emptyActionButton.layer.cornerCurve = kCACornerCurveContinuous;
    self.emptyActionButton.layer.masksToBounds = YES;
    self.emptyActionButton.hidden = YES;
    [self.emptyActionButton addTarget:self action:@selector(emptyActionTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyActionButton.heightAnchor constraintEqualToConstant:40].active = YES;

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.emptyIconView, self.emptyLabel, self.emptyActionButton]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    [self.emptyStateView addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [self.emptyIconView.widthAnchor constraintEqualToConstant:60],
        [self.emptyIconView.heightAnchor constraintEqualToConstant:60],
        [stack.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.emptyStateView.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.emptyStateView.leadingAnchor constant:24],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.emptyStateView.trailingAnchor constant:-24],
    ]];
}

- (void)setupBatchToolbar {
    // 批量选择模式底部工具栏：全选 / 取消 + 批量操作按钮区（子类填充）
    self.batchToolbar = [[UIView alloc] init];
    self.batchToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    self.batchToolbar.hidden = YES;
    self.batchToolbar.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.batchToolbar.layer.cornerRadius = 12.0;
    self.batchToolbar.layer.cornerCurve = kCACornerCurveContinuous;
    self.batchToolbar.layer.borderWidth = 0.5;
    self.batchToolbar.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [[BackgroundManager sharedManager] applyEffectToView:self.batchToolbar];
    [self.view addSubview:self.batchToolbar];

    self.selectAllButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.selectAllButton setTitle:localize(@"resman.common.select_all", nil) forState:UIControlStateNormal];
    self.selectAllButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.selectAllButton.tintColor = [UIColor labelColor];
    self.selectAllButton.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    [self.selectAllButton addTarget:self action:@selector(selectAllTapped) forControlEvents:UIControlEventTouchUpInside];

    self.cancelButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.cancelButton setTitle:localize(@"resman.common.cancel", nil) forState:UIControlStateNormal];
    self.cancelButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.cancelButton.tintColor = [UIColor secondaryLabelColor];
    self.cancelButton.contentEdgeInsets = UIEdgeInsetsMake(8, 12, 8, 12);
    [self.cancelButton addTarget:self action:@selector(cancelSelectModeTapped) forControlEvents:UIControlEventTouchUpInside];

    // 批量操作按钮区（弹性占位，子类把具体操作按钮 addArrangedSubview 进来）
    self.batchActionStack = [[UIStackView alloc] init];
    self.batchActionStack.axis = UILayoutConstraintAxisHorizontal;
    self.batchActionStack.alignment = UIStackViewAlignmentCenter;
    self.batchActionStack.spacing = 12.0;
    self.batchActionStack.distribution = UIStackViewDistributionFillProportionally;

    UIView *leadingSpacer = [[UIView alloc] init];
    UIView *trailingSpacer = [[UIView alloc] init];

    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[self.selectAllButton, leadingSpacer, self.batchActionStack, trailingSpacer, self.cancelButton]];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisHorizontal;
    content.alignment = UIStackViewAlignmentCenter;
    [self.batchToolbar addSubview:content];

    [NSLayoutConstraint activateConstraints:@[
        [content.centerYAnchor constraintEqualToAnchor:self.batchToolbar.centerYAnchor],
        [content.leadingAnchor constraintEqualToAnchor:self.batchToolbar.leadingAnchor constant:12],
        [content.trailingAnchor constraintEqualToAnchor:self.batchToolbar.trailingAnchor constant:-12],
        [leadingSpacer.widthAnchor constraintEqualToAnchor:trailingSpacer.widthAnchor],
    ]];
}

#pragma mark - 三态（空 / 加载）

- (void)showEmptyStateWithIcon:(NSString *)sfSymbol
                     iconColor:(UIColor *)color
                       message:(NSString *)message
                  actionTitle:(NSString *)actionTitle
                actionHandler:(void (^)(void))handler {
    self.emptyActionHandler = [handler copy];

    // 图标未指定时回退到初始化时的资源类型图标
    NSString *iconName = sfSymbol.length > 0 ? sfSymbol
                        : (self.resourceTypeIcon.length > 0 ? self.resourceTypeIcon : @"tray");
    self.emptyIconView.image = [UIImage systemImageNamed:iconName] ?: [UIImage systemImageNamed:@"tray"];
    self.emptyIconView.tintColor = color ?: self.resourceTypeIconColor ?: [UIColor secondaryLabelColor];

    self.emptyLabel.text = message;

    if (actionTitle.length > 0) {
        [self.emptyActionButton setTitle:actionTitle forState:UIControlStateNormal];
        self.emptyActionButton.backgroundColor = accentColor(); // 主题色实时读取
        self.emptyActionButton.hidden = NO;
    } else {
        self.emptyActionButton.hidden = YES;
    }

    self.emptyStateView.alpha = 0.0;
    self.emptyStateView.hidden = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self.emptyStateView.alpha = 1.0;
    }];
}

- (void)hideEmptyState {
    if (self.emptyStateView.hidden) return;
    [UIView animateWithDuration:0.2
        animations:^{
            self.emptyStateView.alpha = 0.0;
        }
        completion:^(BOOL finished) {
            self.emptyStateView.hidden = YES;
        }];
}

- (void)setLoading:(BOOL)loading {
    if (loading) {
        [self.activityIndicator startAnimating];
    } else {
        [self.activityIndicator stopAnimating];
    }
}

- (void)emptyActionTapped {
    if (self.emptyActionHandler) {
        self.emptyActionHandler();
    }
}

#pragma mark - 连锁进场动画（Prisma-Design 15.3）

- (void)animateCellsInChain {
    // 首屏 ≤10 个 cell 参与连锁：每项延迟 50ms 从 -40pt 滑入 + 淡入，
    // Spring 0.85 阻尼 + 0.4 初始速度，时长 500ms
    NSArray<UITableViewCell *> *cells = self.tableView.visibleCells;
    if (cells.count == 0) return;

    NSUInteger count = MIN(cells.count, (NSUInteger)10);
    for (NSUInteger i = 0; i < count; i++) {
        UITableViewCell *cell = cells[i];
        cell.transform = CGAffineTransformMakeTranslation(0, -40);
        cell.alpha = 0.0;
        [UIView animateWithDuration:0.5
                              delay:i * 0.05
             usingSpringWithDamping:0.85
              initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
                             cell.transform = CGAffineTransformIdentity;
                             cell.alpha = 1.0;
                         }
                         completion:nil];
    }
}

#pragma mark - 批量选择模式

- (NSArray<NSIndexPath *> *)selectedIndexPaths {
    return self.tableView.indexPathsForSelectedRows ?: @[];
}

- (void)setSelectMode:(BOOL)enabled {
    if (self.selectModeEnabled == enabled) return;
    _selectModeEnabled = enabled;

    // 进入/退出前先清空选择，保证状态干净
    [self deselectAllRows];
    [self.tableView setEditing:enabled animated:YES];
    [self updateSelectAllButtonTitle];
    [self updateBatchToolbarAnimated:YES];
    [self selectModeDidChange:enabled];
}

- (void)selectModeDidChange:(BOOL)enabled {
    // 子类重写：填充/清理 batchActionStack 中的批量操作按钮
}

- (void)selectionDidChange {
    // 子类重写：同步"已选 N 个"等选择数量 UI
}

- (void)updateBatchToolbarAnimated:(BOOL)animated {
    // 工具栏滑入/滑出 + tableView 底部内边距联动（避免最后一行被遮挡）
    UIEdgeInsets inset = self.tableView.contentInset;
    UIEdgeInsets target = inset;
    target.bottom = self.selectModeEnabled ? (kBatchToolbarHeight + kBatchToolbarBottomGap * 2) : 0.0;

    if (self.selectModeEnabled) {
        self.batchToolbar.hidden = NO;
        self.batchToolbar.alpha = 0.0;
        self.batchToolbar.transform = CGAffineTransformMakeTranslation(0, kBatchToolbarHeight + kBatchToolbarBottomGap);
    }

    void (^changes)(void) = ^{
        self.batchToolbar.alpha = self.selectModeEnabled ? 1.0 : 0.0;
        self.batchToolbar.transform = self.selectModeEnabled
            ? CGAffineTransformIdentity
            : CGAffineTransformMakeTranslation(0, kBatchToolbarHeight + kBatchToolbarBottomGap);
        self.tableView.contentInset = target;
        self.tableView.scrollIndicatorInsets = target;
    };
    void (^completion)(BOOL) = ^(BOOL finished) {
        if (!self.selectModeEnabled) {
            self.batchToolbar.hidden = YES;
        }
    };

    if (animated) {
        [UIView animateWithDuration:0.25 animations:changes completion:completion];
    } else {
        changes();
        completion(YES);
    }
}

#pragma mark - 全选 / 取消

- (void)selectAllTapped {
    if ([self isAllRowsSelected]) {
        [self deselectAllRows];
    } else {
        [self selectAllRows];
    }
}

- (void)cancelSelectModeTapped {
    [self setSelectMode:NO];
}

- (NSInteger)totalRowCount {
    id<UITableViewDataSource> dataSource = self.tableView.dataSource;
    if (!dataSource || ![dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
        return 0;
    }
    NSInteger sections = [dataSource numberOfSectionsInTableView:self.tableView];
    NSInteger total = 0;
    for (NSInteger section = 0; section < sections; section++) {
        total += [dataSource tableView:self.tableView numberOfRowsInSection:section];
    }
    return total;
}

- (BOOL)isAllRowsSelected {
    NSInteger total = [self totalRowCount];
    return total > 0 && self.selectedIndexPaths.count == (NSUInteger)total;
}

- (void)selectAllRows {
    id<UITableViewDataSource> dataSource = self.tableView.dataSource;
    if (!dataSource) return;
    NSInteger sections = [dataSource numberOfSectionsInTableView:self.tableView];
    for (NSInteger section = 0; section < sections; section++) {
        NSInteger rows = [dataSource tableView:self.tableView numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows; row++) {
            [self.tableView selectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]
                                        animated:NO
                                  scrollPosition:UITableViewScrollPositionNone];
        }
    }
    [self updateSelectAllButtonTitle];
    [self selectionDidChange];
}

- (void)deselectAllRows {
    for (NSIndexPath *indexPath in [self.tableView indexPathsForSelectedRows]) {
        [self.tableView deselectRowAtIndexPath:indexPath animated:NO];
    }
    [self updateSelectAllButtonTitle];
    [self selectionDidChange];
}

- (void)updateSelectAllButtonTitle {
    NSString *title = [self isAllRowsSelected] ? localize(@"resman.common.deselect_all", nil)
                                               : localize(@"resman.common.select_all", nil);
    [self.selectAllButton setTitle:title forState:UIControlStateNormal];
}

#pragma mark - 卡片间距辅助

+ (UIView *)cardSpacingHeaderView {
    UIView *view = [[UIView alloc] init];
    view.backgroundColor = [UIColor clearColor];
    view.userInteractionEnabled = NO;
    return view;
}

@end
