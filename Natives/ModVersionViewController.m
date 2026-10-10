#import "utils.h"
#import "ModVersionViewController.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "ModVersion.h"
#import "ModVersionTableViewCell.h"
#import "ModDependencyResolver.h"
#import "installer/modpack/ModrinthAPI.h"
#import "installer/modpack/CurseForgeAPI.h"
#import "AssetDetailHeaderView.h"
#import "BackgroundManager.h"
#import <objc/runtime.h>   // Task230：前置快速入口按钮的关联对象传参
// Task235（前置快速入口直跳模组下载页）：下载服务 + 实例名 + 悬浮提示
#import "ModService.h"
#import "PLProfiles.h"
#import "NMToast.h"

// ============================================================================
// 下载源常量（与 ModVersion.apiSource 字段保持一致：1=Modrinth, 2=CurseForge）
// ============================================================================
// Task232：前置详情页（@implementation 在文件尾；使用点在 817 行附近，
// alloc/init 需要完整接口可见——接口前置，实现后置）
// ★ Task235（用户：“前置快捷入口为什么没有自己跳转到对应的模组下载
//   页”）：旧详情页只给“介绍 + 浏览器兜底”，没有启动器内的【下载页】
//   落地。新增“前往下载页”入口：push 本项目自己的版本列表页
//   （ModVersionViewController），选中版本后直接下载到当前实例。
@interface Ame232DepDetailViewController : UIViewController <ModVersionViewControllerDelegate>
- (instancetype)initWithPid:(NSString *)pid name:(NSString *)name source:(NSInteger)source;
/// Task235：透传当前 profile 的偏好版本/加载器（版本列表自动选中匹配
/// chip 并置顶，与下载页主流程同体验）。
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;
@end

static const NSInteger kSourceModrinth    = 1;
static const NSInteger kSourceCurseForge  = 2;

// ============================================================================
// 排序方式常量（参照 FCL/ZL2 的排序选项）
// ============================================================================
static NSString *const kSortRelevance = @"relevance"; // 相关性（保持 API 原始顺序）
static NSString *const kSortDownloads = @"downloads"; // 下载量（版本级别无此字段，回退为原始顺序）
static NSString *const kSortUpdated   = @"updated";   // 最新更新（datePublished 降序）
static NSString *const kSortCreated   = @"created";   // 创建时间（datePublished 升序）

// 排序选项显示文案（与常量一一对应，用于 chips 渲染）
static NSArray<NSDictionary *> *SortOptionItems(void) {
    static NSArray *items = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        items = @[
            @{ @"key": kSortRelevance, @"title": localize(@"i18n_str_162", nil) },
            @{ @"key": kSortDownloads, @"title": localize(@"i18n_str_32", nil) },
            @{ @"key": kSortUpdated,   @"title": localize(@"i18n_str_33", nil) },
            @{ @"key": kSortCreated,   @"title": localize(@"i18n_str_34", nil) },
        ];
    });
    return items;
}

@interface ModVersionViewController () <UITableViewDataSource, UITableViewDelegate, ModVersionViewControllerDelegate>

// 主表格视图（展示版本列表）
@property (nonatomic, strong) UITableView *tableView;

// ===== 侧边筛选面板（参照 FCL/ZL2 的水平滚动 chips 筛选条）=====
// 筛选面板容器（半透明 + 毛玻璃背景，固定在 tableView 上方不随列表滚动）
@property (nonatomic, strong) UIView *filterContainerView;
// 主垂直 stack（容纳 4 行筛选：来源 / 版本 / 加载器 / 排序）
@property (nonatomic, strong) UIStackView *filterMainStack;

// --- 下载源筛选行 ---
@property (nonatomic, strong) UIScrollView *sourceScrollView;   // 水平滚动容器
@property (nonatomic, strong) UIStackView  *sourceChipStack;    // chips 水平排列

// --- 游戏版本筛选行 ---
@property (nonatomic, strong) UIScrollView *versionScrollView;
@property (nonatomic, strong) UIStackView  *versionChipStack;

// --- 模组加载器筛选行 ---
@property (nonatomic, strong) UIScrollView *loaderScrollView;
@property (nonatomic, strong) UIStackView  *loaderChipStack;

// --- 排序方式筛选行 ---
@property (nonatomic, strong) UIScrollView *sortScrollView;
@property (nonatomic, strong) UIStackView  *sortChipStack;

// ===== 当前选中的筛选状态 =====
@property (nonatomic, assign) NSInteger selectedSource;  // 1=Modrinth, 2=CurseForge
@property (nonatomic, copy)   NSString *selectedSort;    // 排序方式 key

// ===== 数据源 =====
@property (nonatomic, strong) NSArray<ModVersion *> *allVersions;
@property (nonatomic, strong) NSArray<ModVersion *> *filteredVersions;

// 可选的筛选选项列表（从版本数据中动态提取）
@property (nonatomic, strong) NSArray<NSString *> *availableGameVersions;
@property (nonatomic, strong) NSArray<NSString *> *availableLoaders;

// 当前选中的版本 / 加载器（"全部" 表示不过滤）
@property (nonatomic, strong) NSString *selectedGameVersion;
@property (nonatomic, strong) NSString *selectedLoader;

// 项目详情头部视图（展示项目封面图/标题/作者/下载量/标签/描述，补齐信息显示缺口）
@property (nonatomic, strong) AssetDetailHeaderView *detailHeaderView;

// ★ Task238（用户：“模组前置能不能像其他启动器一样摆在最上面合理的地方，
//   下面太不明显”）：前置区从表尾（tableFooterView）上移到【详情头之下、
//   版本列表之上】——tableHeaderView 已被项目详情头占用，这里用堆叠容器
//   把 [详情头 + 前置区] 合成一个头部。前置区存在性变化时重装头部。
@property (nonatomic, strong, nullable) UIView *ame238_depsSectionView;   // 前置区（nil = 无）
@property (nonatomic, strong, nullable) UIView *ame238_headerStackView;  // 堆叠容器（复用）

@end

@implementation ModVersionViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.modItem.displayName;
    self.view.backgroundColor = [UIColor systemBackgroundColor]; // Task136：主题化页面底色
    // 适配自定义启动器背景：透明化当前 VC，让全局背景图/毛玻璃透出
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 初始化筛选状态（默认 Modrinth 源 + 相关性排序）
    // 关键修复（CurseForge 搜索结果丢失来源）：版本页优先沿用搜索结果携带的 API 来源
    // （apiSource=2 时默认 CurseForge），否则拿 CurseForge 数字 ID 请求 Modrinth 拉不到版本
    self.selectedSource = (self.apiSource == kSourceCurseForge) ? kSourceCurseForge : kSourceModrinth;
    self.selectedSort = kSortRelevance;

    [self setupSideFilterPanel];
    [self setupTableView];
    [self setupActivityIndicator];
    [self setupDetailHeader];

    // 透明化 tableView 背景，避免遮挡全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;

    [self fetchVersionsFromCurrentSource];

    // 监听背景效果变化通知，背景切换时重新应用透明效果
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)reapplyBackgroundEffect {
    // 背景效果改变时重新透明化当前 VC
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    // 重新设置 tableView 背景为透明，确保背景效果切换后仍透出全局背景
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    // 移除通知观察者，避免dealloc后收到通知导致崩溃
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Detail Header（项目信息展示）

/// 创建并配置项目详情头部视图，设置为 tableView.tableHeaderView
/// 补齐之前版本页缺少的项目封面图/标题/作者/下载量/标签/描述等信息显示
- (void)setupDetailHeader {
    self.detailHeaderView = [[AssetDetailHeaderView alloc] init];

    // 描述展开/收起时重新计算 header 高度（避免循环引用，用 weak）
    __weak typeof(self) weakSelf = self;
    self.detailHeaderView.onSizeChanged = ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) [strongSelf updateTableHeaderHeight];
    };

    // 用搜索阶段已有的 modItem 数据填充（无需额外 API 调用）
    [self.detailHeaderView configureWithIconURL:self.modItem.iconURL
                                          title:self.modItem.displayName
                                         author:self.modItem.author
                                      downloads:self.modItem.downloads
                                          likes:self.modItem.likes
                                descriptionText:self.modItem.modDescription
                                    categories:self.modItem.categories
                                   lastUpdated:self.modItem.lastUpdated
                           placeholderSymbolName:@"puzzlepiece.extension.fill"
                               placeholderColor:[UIColor systemOrangeColor]];

    [self updateTableHeaderHeight];
    self.tableView.tableHeaderView = self.detailHeaderView;
}

/// 重新计算 tableHeaderView 高度并刷新（在 viewDidLayoutSubviews 和描述展开/收起时调用）
/// ★ Task238：头部堆叠——无前置区 = 仅详情头（逐字节旧路径）；有前置区 =
/// [详情头 + 前置区] 垂直堆叠进同一 tableHeaderView（前置上移到列表上方）。
- (void)updateTableHeaderHeight {
    if (!self.detailHeaderView) return;
    CGFloat width = self.tableView.bounds.size.width;
    if (width <= 0) width = self.view.bounds.size.width;
    if (width <= 0) width = [UIScreen mainScreen].bounds.size.width;
    CGFloat height = [self.detailHeaderView fittingHeightForWidth:width];

    UIView *ame238_deps = self.ame238_depsSectionView;
    if (![ame238_deps isKindOfClass:[UIView class]]) {
        // 无前置区：旧路径（仅详情头；高度未变则跳过重赋值）
        CGRect frame = self.detailHeaderView.frame;
        if (fabs(frame.size.height - height) < 1 &&
            self.tableView.tableHeaderView == self.detailHeaderView) return;
        frame.size.height = height;
        self.detailHeaderView.frame = frame;
        // 重新赋值触发 tableView 重新布局 header
        self.tableView.tableHeaderView = self.detailHeaderView;
        return;
    }

    // 有前置区：堆叠头部（详情头在上，前置区紧随其下，都在版本列表之上）
    CGFloat ame238_depsH = ceil([ame238_deps systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)].height);
    CGFloat ame238_totalH = ceil(height) + ame238_depsH;
    CGRect ame238_stackFrame = CGRectMake(0, 0, width, ame238_totalH);
    if (self.ame238_headerStackView == nil) {
        self.ame238_headerStackView = [[UIView alloc] init];
    }
    if (fabs(self.ame238_headerStackView.frame.size.height - ame238_totalH) < 1 &&
        self.tableView.tableHeaderView == self.ame238_headerStackView &&
        fabs(self.detailHeaderView.frame.size.height - height) < 1 &&
        ame238_deps.superview == self.ame238_headerStackView) {
        return;   // 几何未变且当前前置区已入栈（CF 回填重渲染的新视图必须入栈，不能早退）
    }
    self.ame238_headerStackView.frame = ame238_stackFrame;
    self.detailHeaderView.frame = CGRectMake(0, 0, width, ceil(height));
    ame238_deps.frame = CGRectMake(0, ceil(height), width, ame238_depsH);
    if (ame238_deps.superview != self.ame238_headerStackView) {
        // 新前置区入栈：清掉旧的前置区（CF 富元数据回填后重渲染会生成新
        // 视图，旧视图不能残留在堆叠里重复显示）。
        for (UIView *ame238_old in [self.ame238_headerStackView.subviews copy]) {
            if (ame238_old != self.detailHeaderView && ame238_old != ame238_deps) {
                [ame238_old removeFromSuperview];
            }
        }
        [self.ame238_headerStackView addSubview:ame238_deps];
    }
    if (self.detailHeaderView.superview != self.ame238_headerStackView) {
        [self.ame238_headerStackView addSubview:self.detailHeaderView];
    } else {
        [self.ame238_headerStackView bringSubviewToFront:self.detailHeaderView];
    }
    // 重新赋值触发 tableView 重新布局 header
    self.tableView.tableHeaderView = self.ame238_headerStackView;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // 首次 layout 后 tableView 宽度才确定，此时更新一次 header 高度
    if (self.detailHeaderView) {
        [self updateTableHeaderHeight];
    }
}

#pragma mark - 侧边筛选面板（参照 FCL/ZL2 水平滚动 chips）

/// 创建侧边筛选面板：4 行水平滚动 chips（下载源 / 游戏版本 / 加载器 / 排序方式）
/// 参照 FCL 安卓版的筛选条设计：每个类别一行，图标+标签前缀，chips 水平滚动，
/// 选中项高亮（主题色背景 + 白字），未选中项半透明背景 + 浅边框。
- (void)setupSideFilterPanel {
    // ===== 筛选面板容器（半透明 + 毛玻璃，固定在顶部不随列表滚动）=====
    self.filterContainerView = [[UIView alloc] init];
    self.filterContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterContainerView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.06];
    self.filterContainerView.layer.cornerRadius = 14;
    self.filterContainerView.layer.cornerCurve = kCACornerCurveContinuous;
    self.filterContainerView.layer.borderWidth = 0.5;
    self.filterContainerView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [self.view addSubview:self.filterContainerView];
    // 应用毛玻璃背景效果，与启动器整体风格一致
    [[BackgroundManager sharedManager] applyEffectToView:self.filterContainerView];

    // ===== 主垂直 stack（4 行筛选，每行 = 图标标签 + 水平滚动 chips）=====
    self.filterMainStack = [[UIStackView alloc] init];
    self.filterMainStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.filterMainStack.axis = UILayoutConstraintAxisVertical;
    self.filterMainStack.spacing = 4;
    self.filterMainStack.alignment = UIStackViewAlignmentFill;
    [self.filterContainerView addSubview:self.filterMainStack];

    // ----- 第 1 行：下载源筛选（Modrinth / CurseForge）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *sourceRow = [self createFilterRowWithIconName:@"globe"
                                                             label:localize(@"i18n_str_462", nil)
                                                        scrollStackOut:&scrollOut
                                                          chipStackOut:&chipOut];
        self.sourceScrollView = scrollOut;
        self.sourceChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:sourceRow];
    }
    [self rebuildSourceChips];

    // ----- 第 2 行：游戏版本筛选（动态填充，初始显示"加载中"）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *versionRow = [self createFilterRowWithIconName:@"gamecontroller.fill"
                                                              label:localize(@"i18n_str_39", nil)
                                                         scrollStackOut:&scrollOut
                                                           chipStackOut:&chipOut];
        self.versionScrollView = scrollOut;
        self.versionChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:versionRow];
    }
    [self addChipToStack:self.versionChipStack title:localize(@"i18n_str_40", nil) selected:NO action:NULL];

    // ----- 第 3 行：模组加载器筛选（动态填充，初始显示"加载中"）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *loaderRow = [self createFilterRowWithIconName:@"puzzlepiece.extension.fill"
                                                             label:localize(@"i18n_str_114", nil)
                                                        scrollStackOut:&scrollOut
                                                          chipStackOut:&chipOut];
        self.loaderScrollView = scrollOut;
        self.loaderChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:loaderRow];
    }
    [self addChipToStack:self.loaderChipStack title:localize(@"i18n_str_40", nil) selected:NO action:NULL];

    // ----- 第 4 行：排序方式筛选（相关性 / 下载量 / 最新更新 / 创建时间）-----
    {
        UIScrollView *scrollOut = nil;
        UIStackView *chipOut = nil;
        UIStackView *sortRow = [self createFilterRowWithIconName:@"arrow.up.arrow.down"
                                                           label:localize(@"i18n_str_41", nil)
                                                      scrollStackOut:&scrollOut
                                                        chipStackOut:&chipOut];
        self.sortScrollView = scrollOut;
        self.sortChipStack = chipOut;
        [self.filterMainStack addArrangedSubview:sortRow];
    }
    [self rebuildSortChips];

    // ===== 容器约束：顶部紧贴安全区域，左右留 8pt 边距 =====
    [NSLayoutConstraint activateConstraints:@[
        [self.filterContainerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:6],
        [self.filterContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [self.filterContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        // 主 stack 内边距
        [self.filterMainStack.topAnchor constraintEqualToAnchor:self.filterContainerView.topAnchor constant:8],
        [self.filterMainStack.bottomAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:-8],
        [self.filterMainStack.leadingAnchor constraintEqualToAnchor:self.filterContainerView.leadingAnchor constant:10],
        [self.filterMainStack.trailingAnchor constraintEqualToAnchor:self.filterContainerView.trailingAnchor constant:-10],
    ]];
}

/// 创建单行筛选布局：左侧图标+标签（固定宽度），右侧水平滚动 chips 容器
/// 参照 FCL 筛选面板的行结构：icon + label + horizontal scrollview
- (UIStackView *)createFilterRowWithIconName:(NSString *)iconName
                                       label:(NSString *)labelText
                                scrollStackOut:(UIScrollView **)scrollStackOut
                                  chipStackOut:(UIStackView **)chipStackOut {
    // --- 左侧：图标 + 标签（固定宽度，不随 chips 滚动）---
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.image = [UIImage systemImageNamed:iconName];
    iconView.tintColor = [UIColor secondaryLabelColor];
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    [iconView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [iconView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [NSLayoutConstraint activateConstraints:@[
        [iconView.widthAnchor constraintEqualToConstant:15],
        [iconView.heightAnchor constraintEqualToConstant:15],
    ]];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = labelText;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentLeft;
    [label setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [label.widthAnchor constraintEqualToConstant:34].active = YES;

    UIStackView *labelStack = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, label]];
    labelStack.translatesAutoresizingMaskIntoConstraints = NO;
    labelStack.axis = UILayoutConstraintAxisHorizontal;
    labelStack.spacing = 3;
    labelStack.alignment = UIStackViewAlignmentCenter;
    [labelStack setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    // --- 右侧：水平滚动 chips 容器 ---
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.showsHorizontalScrollIndicator = NO;
    scrollView.alwaysBounceHorizontal = YES;

    UIStackView *chipStack = [[UIStackView alloc] init];
    chipStack.translatesAutoresizingMaskIntoConstraints = NO;
    chipStack.axis = UILayoutConstraintAxisHorizontal;
    chipStack.spacing = 6;
    chipStack.alignment = UIStackViewAlignmentCenter;
    [scrollView addSubview:chipStack];

    // chipStack 填满 scrollView 的 contentLayoutGuide，高度与 frameLayoutGuide 一致
    [NSLayoutConstraint activateConstraints:@[
        [chipStack.topAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.topAnchor],
        [chipStack.bottomAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.bottomAnchor],
        [chipStack.leadingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.leadingAnchor],
        [chipStack.trailingAnchor constraintEqualToAnchor:scrollView.contentLayoutGuide.trailingAnchor],
        [chipStack.heightAnchor constraintEqualToAnchor:scrollView.frameLayoutGuide.heightAnchor],
    ]];

    // 输出到调用方的属性
    if (scrollStackOut) *scrollStackOut = scrollView;
    if (chipStackOut) *chipStackOut = chipStack;

    // --- 行容器：标签 + 滚动视图 水平排列 ---
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[labelStack, scrollView]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 6;
    row.alignment = UIStackViewAlignmentCenter;
    // 固定行高，让 4 行总高度可控
    [row.heightAnchor constraintEqualToConstant:30].active = YES;
    return row;
}

/// 创建单个筛选 chip 按钮（pill 样式，参照 FCL/ZL2 的标签条）
/// 选中态：主题色(systemBlue)背景 + 白字；未选中态：半透明背景 + 标签色文字 + 浅边框
- (UIButton *)createFilterChipWithTitle:(NSString *)title selected:(BOOL)selected {
    UIButton *chip = [UIButton buttonWithType:UIButtonTypeSystem];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    [chip setTitle:title forState:UIControlStateNormal];
    chip.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    chip.titleLabel.adjustsFontSizeToFitWidth = YES;
    chip.titleLabel.minimumScaleFactor = 0.75;
    chip.contentEdgeInsets = UIEdgeInsetsMake(4, 12, 4, 12);
    chip.layer.cornerRadius = 14;
    chip.layer.cornerCurve = kCACornerCurveContinuous;
    chip.layer.masksToBounds = YES;
    // 固定高度，防止内容变化导致高度跳动
    [chip.heightAnchor constraintEqualToConstant:28].active = YES;
    [chip setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [chip setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self applyChipStyle:chip selected:selected];
    return chip;
}

/// 应用 chip 选中/未选中样式
- (void)applyChipStyle:(UIButton *)chip selected:(BOOL)selected {
    if (selected) {
        // 选中态：主题色背景 + 白字（参照 FCL 选中标签高亮）
        chip.backgroundColor = [UIColor systemBlueColor];
        [chip setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0;
    } else {
        // 未选中态：半透明背景 + 标签色文字 + 浅边框
        chip.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
        [chip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
        chip.layer.borderWidth = 0.5;
        chip.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.15].CGColor;
    }
}

/// 向 chipStack 添加一个 chip（快捷方法，用于初始占位）
- (void)addChipToStack:(UIStackView *)stack title:(NSString *)title selected:(BOOL)selected action:(SEL)action {
    UIButton *chip = [self createFilterChipWithTitle:title selected:selected];
    if (action) {
        [chip addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    }
    [stack addArrangedSubview:chip];
}

/// 清空 chipStack 中所有已排列的子视图（用于重建 chips）
- (void)clearChipStack:(UIStackView *)stack {
    [stack.arrangedSubviews makeObjectsPerformSelector:@selector(removeFromSuperview)];
}

#pragma mark - 重建各筛选行 chips

/// 重建下载源 chips（Modrinth / CurseForge）
- (void)rebuildSourceChips {
    [self clearChipStack:self.sourceChipStack];

    // Modrinth chip
    UIButton *modrinthChip = [self createFilterChipWithTitle:@"Modrinth"
                                                    selected:(self.selectedSource == kSourceModrinth)];
    modrinthChip.tag = kSourceModrinth;
    [modrinthChip addTarget:self action:@selector(sourceChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceChipStack addArrangedSubview:modrinthChip];

    // CurseForge chip
    UIButton *curseforgeChip = [self createFilterChipWithTitle:@"CurseForge"
                                                      selected:(self.selectedSource == kSourceCurseForge)];
    curseforgeChip.tag = kSourceCurseForge;
    [curseforgeChip addTarget:self action:@selector(sourceChipTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.sourceChipStack addArrangedSubview:curseforgeChip];
}

/// 重建游戏版本 chips（从 availableGameVersions 动态填充，含"全部"）
- (void)rebuildVersionChips {
    [self clearChipStack:self.versionChipStack];
    if (!self.availableGameVersions || self.availableGameVersions.count == 0) {
        [self addChipToStack:self.versionChipStack title:localize(@"i18n_str_463", nil) selected:NO action:NULL];
        return;
    }
    for (NSString *version in self.availableGameVersions) {
        BOOL isSelected = [self.selectedGameVersion isEqualToString:version];
        UIButton *chip = [self createFilterChipWithTitle:version selected:isSelected];
        [chip addTarget:self action:@selector(versionChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.versionChipStack addArrangedSubview:chip];
    }
    // 滚动到选中项位置（让用户能看到当前选中的 chip）
    [self scrollToSelectedChipInStack:self.versionChipStack withTitle:self.selectedGameVersion];
}

/// 重建加载器 chips（从 availableLoaders 动态填充，含"全部"）
- (void)rebuildLoaderChips {
    [self clearChipStack:self.loaderChipStack];
    if (!self.availableLoaders || self.availableLoaders.count == 0) {
        [self addChipToStack:self.loaderChipStack title:localize(@"i18n_str_464", nil) selected:NO action:NULL];
        return;
    }
    for (NSString *loader in self.availableLoaders) {
        BOOL isSelected = [self.selectedLoader isEqualToString:loader];
        UIButton *chip = [self createFilterChipWithTitle:loader selected:isSelected];
        [chip addTarget:self action:@selector(loaderChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.loaderChipStack addArrangedSubview:chip];
    }
    // 滚动到选中项位置
    [self scrollToSelectedChipInStack:self.loaderChipStack withTitle:self.selectedLoader];
}

/// 重建排序方式 chips（固定 4 个选项：相关性 / 下载量 / 最新更新 / 创建时间）
- (void)rebuildSortChips {
    [self clearChipStack:self.sortChipStack];
    for (NSDictionary *item in SortOptionItems()) {
        NSString *key = item[@"key"];
        NSString *title = item[@"title"];
        BOOL isSelected = [self.selectedSort isEqualToString:key];
        UIButton *chip = [self createFilterChipWithTitle:title selected:isSelected];
        chip.accessibilityIdentifier = key; // 用 accessibilityIdentifier 存储 sort key
        [chip addTarget:self action:@selector(sortChipTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.sortChipStack addArrangedSubview:chip];
    }
}

/// 滚动 scrollView 使指定标题的 chip 可见
- (void)scrollToSelectedChipInStack:(UIStackView *)stack withTitle:(NSString *)title {
    if (!title || title.length == 0) return;
    UIScrollView *scrollView = (UIScrollView *)stack.superview;
    if (![scrollView isKindOfClass:[UIScrollView class]]) return;
    for (UIButton *chip in stack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        NSString *chipTitle = chip.titleLabel.text;
        if ([chipTitle isEqualToString:title]) {
            CGRect frameInScroll = [chip.superview convertRect:chip.frame toView:scrollView];
            CGFloat targetX = frameInScroll.origin.x - scrollView.bounds.size.width / 2 + frameInScroll.size.width / 2;
            targetX = MAX(0, targetX);
            CGFloat maxOffset = scrollView.contentSize.width - scrollView.bounds.size.width;
            targetX = MIN(targetX, MAX(0, maxOffset));
            [scrollView setContentOffset:CGPointMake(targetX, 0) animated:YES];
            break;
        }
    }
}

#pragma mark - Chip 点击事件处理

/// 下载源 chip 点击：切换 Modrinth / CurseForge，并重新拉取版本列表
- (void)sourceChipTapped:(UIButton *)sender {
    NSInteger newSource = sender.tag;
    if (newSource == self.selectedSource) return; // 未切换则忽略

    // CurseForge 源：Task162 起免 key 可用（无 key 时 baseURL 强制落 MCIM 镜像，
    // 实测 200），门控改用 isSourceAvailable——key 仅官方直连需要。
    if (newSource == kSourceCurseForge && ![CurseForgeAPI isSourceAvailable]) {
        [self showSourceAlertWithTitle:localize(@"i18n_str_465", nil)
                                message:localize(@"i18n_str_466", nil)];
        return;
    }

    self.selectedSource = newSource;
    // 更新 chips 选中样式
    for (UIButton *chip in self.sourceChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:(chip.tag == self.selectedSource)];
    }
    // 清空已有数据，重新拉取
    self.allVersions = nil;
    self.filteredVersions = nil;
    [self.tableView reloadData];
    [self fetchVersionsFromCurrentSource];
}

/// 游戏版本 chip 点击：切换选中版本，重新筛选
- (void)versionChipTapped:(UIButton *)sender {
    NSString *newVersion = sender.titleLabel.text;
    if ([newVersion isEqualToString:self.selectedGameVersion]) return;
    self.selectedGameVersion = newVersion;
    // 更新 chips 选中样式
    for (UIButton *chip in self.versionChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:self.selectedGameVersion]];
    }
    [self applyFiltersAndSort];
}

/// 加载器 chip 点击：切换选中加载器，重新筛选
- (void)loaderChipTapped:(UIButton *)sender {
    NSString *newLoader = sender.titleLabel.text;
    if ([newLoader isEqualToString:self.selectedLoader]) return;
    self.selectedLoader = newLoader;
    // 更新 chips 选中样式
    for (UIButton *chip in self.loaderChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.titleLabel.text isEqualToString:self.selectedLoader]];
    }
    [self applyFiltersAndSort];
}

/// 排序方式 chip 点击：切换排序，重新排序并刷新列表
- (void)sortChipTapped:(UIButton *)sender {
    NSString *newSort = sender.accessibilityIdentifier;
    if (!newSort || [newSort isEqualToString:self.selectedSort]) return;
    self.selectedSort = newSort;
    // 更新 chips 选中样式
    for (UIButton *chip in self.sortChipStack.arrangedSubviews) {
        if (![chip isKindOfClass:[UIButton class]]) continue;
        [self applyChipStyle:chip selected:[chip.accessibilityIdentifier isEqualToString:self.selectedSort]];
    }
    [self applyFiltersAndSort];
}

/// 显示来源切换失败提示
- (void)showSourceAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                    message:message
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TableView 设置

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.dataSource = self;
    self.tableView.delegate = self;
    // 启用自动行高，让紧凑卡片自适应内容
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 78;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.tableView registerClass:[ModVersionTableViewCell class] forCellReuseIdentifier:@"ModVersionCell"];
    [self.view addSubview:self.tableView];

    // tableView 紧贴筛选面板下方
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.filterContainerView.bottomAnchor constant:6],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)setupActivityIndicator {
    self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
    self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.activityIndicator.hidesWhenStopped = YES;
    [self.view addSubview:self.activityIndicator];

    [NSLayoutConstraint activateConstraints:@[
        [self.activityIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.activityIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];
}

#pragma mark - 数据拉取

/// 根据当前选中的下载源拉取版本列表
/// Modrinth 源 → ModrinthAPI；CurseForge 源 → CurseForgeAPI
- (void)fetchVersionsFromCurrentSource {
    [self.activityIndicator startAnimating];

    if (self.selectedSource == kSourceCurseForge) {
        // ===== CurseForge 源 =====
        // CurseForgeAPI.getVersionsForModWithID: 返回 ModVersion 数组（含 CurseForge 的 fileId/projectId）
        [[CurseForgeAPI sharedInstance] getVersionsForModWithID:self.modItem.onlineID
                                                     completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleVersionsResponse:versions error:error];
            });
        }];
    } else {
        // ===== Modrinth 源（默认）=====
        [[ModrinthAPI sharedInstance] getVersionsForModWithID:self.modItem.onlineID
                                                   completion:^(NSArray<ModVersion *> * _Nullable versions, NSError * _Nullable error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self handleVersionsResponse:versions error:error];
            });
        }];
    }
}

/// 统一处理版本拉取回调
- (void)handleVersionsResponse:(NSArray<ModVersion *> *)versions error:(NSError *)error {
    [self.activityIndicator stopAnimating];
    if (error) {
        NSLog(@"[ModVersionVC] Error fetching versions (source=%ld): %@", (long)self.selectedSource, error);
        // 修复"下载版本点击下载按钮后没有反应"：
        // 之前版本列表拉取失败时仅 NSLog，用户看到空白列表毫无反馈，误以为按钮失灵。
        // 现在补 UIAlertController 提示（与 ShaderVersionViewController 保持一致）。
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil)
                                                                        message:localize(@"i18n_str_467", nil)
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    if (!versions || versions.count == 0) {
        // 列表为空时也给出反馈，避免用户误以为"按钮无反应"
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil)
                                                                        message:localize(@"i18n_str_468", nil)
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    self.allVersions = versions;
    [self processFilters];
    [self applyFiltersAndSort];
    [self ame227_refreshDependenciesFooter];
}

/// ★ Task227（反馈 #4：打开模组没有显示前置）：版本列表加载完成后，解析
/// 最新版本的必需依赖并展示在表尾（"本模组需要以下前置，下载时会询问
/// 是否一起安装"）。解析失败静默（footer 不出现，不影响列表）。
- (void)ame227_refreshDependenciesFooter {
    // ★ Task238（用户："cf源没有显示前置" + "前置摆在最上面"）：
    //   ① 数据源探测——最新版本的 dependencies[] 可能为空（老文件字段
    //      缺失 / 镜像裁剪），逐个向后探测最多 6 个版本直到找到携带
    //      依赖清单的一个，CF 源"看不到前置"的一路根因消除；
    //   ② 展示位从表尾上移到详情头之下、版本列表之上（头部堆叠）。
    NSDictionary *ame238_detail = nil;
    NSInteger ame238_src = 0;
    NSUInteger ame238_probe = MIN((NSUInteger)6, self.allVersions.count);
    for (NSUInteger ame238_i = 0; ame238_i < ame238_probe; ame238_i++) {
        ModVersion *ame238_v = self.allVersions[ame238_i];
        if (![ame238_v isKindOfClass:[ModVersion class]] || ame238_v.rawDictionary == nil) continue;
        id ame238_depsArr = ame238_v.rawDictionary[@"dependencies"];
        if ([ame238_depsArr isKindOfClass:[NSArray class]] && ((NSArray *)ame238_depsArr).count > 0) {
            ame238_detail = ame238_v.rawDictionary;
            ame238_src = ame238_v.apiSource;
            break;
        }
    }
    if (ame238_detail == nil) {
        self.ame238_depsSectionView = nil;
        [self updateTableHeaderHeight];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[ModDependencyResolver sharedResolver] resolveDependenciesFromVersionDetail:ame238_detail
                                                                       apiSource:ame238_src
                                                            installedProjectIds:nil
                                                                          loader:nil
                                                                     gameVersion:nil
                                                                      completion:^(ModDependencyPlan *plan, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSArray<ModDependencyItem *> *ame227_req = plan.required ?: @[];
        if (ame227_req.count == 0) {
            strongSelf.ame238_depsSectionView = nil;
            [strongSelf updateTableHeaderHeight];
            return;
        }
        // ★ Task236（富条目沿用）：每行【图标 + 名称 + 介绍】内联展示，
        //   点按直接 push 该模组自己的版本下载页，ⓘ 保留详情页入口。
        //   数据：Modrinth /v2/project；CF 走 Task238 的 /mods/{id} 回填。
        [strongSelf ame236_buildDependencyFooterWithItems:ame227_req];
    }];
}


/// Task236：前置数据抓取（图标 + 介绍一步到位）→ 主线程渲染富条目 footer。
- (void)ame236_buildDependencyFooterWithItems:(NSArray<ModDependencyItem *> *)items {
    if (items.count == 0) {
        self.ame238_depsSectionView = nil;
        [self updateTableHeaderHeight];
        return;
    }
    __weak typeof(self) ame236_wself = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSMutableDictionary *> *ame236_rows = [NSMutableArray array];
        for (ModDependencyItem *ame236_dep in items) {
            NSString *ame236_name = ame236_dep.displayName ?: ame236_dep.projectId;
            NSString *ame236_desc = @"";
            NSString *ame236_icon = @"";
            if (ame236_dep.apiSource == kSourceModrinth && ame236_dep.projectId.length > 0) {
                NSURL *ame236_url = [NSURL URLWithString:
                    [NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@", ame236_dep.projectId]];
                NSData *ame236_data = ame236_url != nil ? [NSData dataWithContentsOfURL:ame236_url] : nil;
                if (ame236_data != nil) {
                    id ame236_obj = [NSJSONSerialization JSONObjectWithData:ame236_data options:0 error:nil];
                    if ([ame236_obj isKindOfClass:[NSDictionary class]]) {
                        NSString *ame236_t = ame236_obj[@"title"];
                        if ([ame236_t isKindOfClass:[NSString class]] && ame236_t.length > 0) ame236_name = ame236_t;
                        NSString *ame236_d = ame236_obj[@"description"];
                        if ([ame236_d isKindOfClass:[NSString class]]) ame236_desc = ame236_d;
                        NSString *ame236_ic = ame236_obj[@"icon_url"];
                        if ([ame236_ic isKindOfClass:[NSString class]]) ame236_icon = ame236_ic;
                    }
                }
            } else if (ame236_dep.apiSource == kSourceCurseForge && ame236_dep.projectId.length > 0) {
                // ★ Task238（用户："cf源没有显示前置"）：CF 前置行先给来源
                //   提示占位，渲染后由主线程的 /mods/{id} 富元数据回填。
                ame236_desc = [NSString stringWithFormat:localize(@"ame232.deps.cf_desc", nil),
                               ame236_name];
            }
            [ame236_rows addObject:[NSMutableDictionary dictionaryWithDictionary:@{
                @"pid":  ame236_dep.projectId ?: @"",
                @"name": ame236_name ?: @"",
                @"desc": ame236_desc ?: @"",
                @"icon": ame236_icon ?: @"",
                @"src":  @(ame236_dep.apiSource),
                @"kind": @(ame236_dep.kind),
            }]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(ame236_wself) ame236_sself = ame236_wself;
            if (!ame236_sself) return;
            [ame236_sself ame236_renderDependencyFooter:ame236_rows];
            // ★ Task238：CF 前置行的富元数据回填（全链主线程，无跨线程
            //   写入；全部回填完成后重渲染一次）。占位先行 → 名称/介绍/
            //   图标到达后升级为与 Modrinth 同款的富卡片。
            NSMutableArray<NSString *> *ame238_cfPids = [NSMutableArray array];
            for (NSDictionary *ame238_row in ame236_rows) {
                if ([ame238_row[@"src"] integerValue] == kSourceCurseForge &&
                    [ame238_row[@"pid"] isKindOfClass:[NSString class]] &&
                    ((NSString *)ame238_row[@"pid"]).length > 0) {
                    [ame238_cfPids addObject:ame238_row[@"pid"]];
                }
            }
            if (ame238_cfPids.count == 0) return;
            dispatch_group_t ame238_group = dispatch_group_create();
            for (NSString *ame238_pid in ame238_cfPids) {
                dispatch_group_enter(ame238_group);
                [[CurseForgeAPI sharedInstance] ame238_fetchProjectInfo:ame238_pid completion:^(NSDictionary * _Nullable info, NSError * _Nullable error) {
                    if ([info isKindOfClass:[NSDictionary class]]) {
                        for (NSMutableDictionary *ame238_row in ame236_rows) {
                            if ([ame238_row[@"pid"] isEqualToString:ame238_pid]) {
                                NSString *ame238_n = info[@"name"];
                                if ([ame238_n isKindOfClass:[NSString class]] && ame238_n.length > 0) {
                                    ame238_row[@"name"] = ame238_n;
                                }
                                NSString *ame238_s = info[@"summary"];
                                if ([ame238_s isKindOfClass:[NSString class]] && ame238_s.length > 0) {
                                    ame238_row[@"desc"] = ame238_s;
                                }
                                NSString *ame238_ic = info[@"icon"];
                                if ([ame238_ic isKindOfClass:[NSString class]] && ame238_ic.length > 0) {
                                    ame238_row[@"icon"] = ame238_ic;
                                }
                            }
                        }
                    }
                    dispatch_group_leave(ame238_group);
                }];
            }
            dispatch_group_notify(ame238_group, dispatch_get_main_queue(), ^{
                __strong typeof(ame236_wself) ame238_sself2 = ame236_wself;
                if (!ame238_sself2) return;
                [ame238_sself2 ame236_renderDependencyFooter:ame236_rows];
                NSLog(@"[ModVersionVC] Task238 CF dependency rows enriched (%lu project lookups)",
                      (unsigned long)ame238_cfPids.count);
            });
        });
    });
}


/// Task236：渲染前置区——模组列表同款富条目（图标 + 名称 + 介绍内联，
/// 点按直跳该模组版本下载页，ⓘ 进详情页）。高度按内容手动定 frame。
/// ★ Task238：目标从表尾（tableFooterView）改为头部堆叠前置区（最上面）。
- (void)ame236_renderDependencyFooter:(NSArray<NSDictionary *> *)rows {
    CGFloat ame236_w = self.tableView.bounds.size.width;
    if (ame236_w < 32) ame236_w = 320;
    UIView *ame236_footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, ame236_w, 0)];

    // 头部说明：原有统计文案 + Task236 直跳提示
    NSMutableString *ame236_names = [NSMutableString string];
    for (NSDictionary *ame236_row in rows) {
        if (ame236_names.length > 0) [ame236_names appendString:@", "];
        [ame236_names appendString:ame236_row[@"name"]];
    }
    UILabel *ame236_header = [[UILabel alloc] init];
    ame236_header.numberOfLines = 0;
    ame236_header.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    ame236_header.textColor = [UIColor secondaryLabelColor];
    ame236_header.text = [NSString stringWithFormat:@"%@\n%@",
                          [NSString stringWithFormat:localize(@"ame227.deps.footer", nil),
                           (unsigned long)rows.count, ame236_names],
                          localize(@"ame236.deps.hint", nil)];
    ame236_header.translatesAutoresizingMaskIntoConstraints = NO;
    [ame236_footer addSubview:ame236_header];
    [ame236_footer addConstraints:@[
        [NSLayoutConstraint constraintWithItem:ame236_header attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual
            toItem:ame236_footer attribute:NSLayoutAttributeTop multiplier:1 constant:10],
        [NSLayoutConstraint constraintWithItem:ame236_header attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual
            toItem:ame236_footer attribute:NSLayoutAttributeLeading multiplier:1 constant:16],
        [NSLayoutConstraint constraintWithItem:ame236_header attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual
            toItem:ame236_footer attribute:NSLayoutAttributeTrailing multiplier:1 constant:-16],
    ]];

    UIView *ame236_prev = ame236_header;
    for (NSDictionary *ame236_row in rows) {
        UIView *ame236_rowView = [self ame236_dependencyRow:ame236_row];
        ame236_rowView.translatesAutoresizingMaskIntoConstraints = NO;
        [ame236_footer addSubview:ame236_rowView];
        [ame236_footer addConstraints:@[
            [NSLayoutConstraint constraintWithItem:ame236_rowView attribute:NSLayoutAttributeTop relatedBy:NSLayoutRelationEqual
                toItem:ame236_prev attribute:NSLayoutAttributeBottom multiplier:1 constant:8],
            [NSLayoutConstraint constraintWithItem:ame236_rowView attribute:NSLayoutAttributeLeading relatedBy:NSLayoutRelationEqual
                toItem:ame236_footer attribute:NSLayoutAttributeLeading multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:ame236_rowView attribute:NSLayoutAttributeTrailing relatedBy:NSLayoutRelationEqual
                toItem:ame236_footer attribute:NSLayoutAttributeTrailing multiplier:1 constant:0],
            [NSLayoutConstraint constraintWithItem:ame236_rowView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual
                toItem:nil attribute:NSLayoutAttributeNotAnAttribute multiplier:1 constant:64],
        ]];
        ame236_prev = ame236_rowView;
    }
    [ame236_footer addConstraint:
        [NSLayoutConstraint constraintWithItem:ame236_prev attribute:NSLayoutAttributeBottom relatedBy:NSLayoutRelationEqual
            toItem:ame236_footer attribute:NSLayoutAttributeBottom multiplier:1 constant:-12]];

    [ame236_footer setNeedsLayout];
    [ame236_footer layoutIfNeeded];
    CGSize ame236_fit = [ame236_footer systemLayoutSizeFittingSize:CGSizeMake(ame236_w, UILayoutFittingCompressedSize.height)];
    ame236_footer.frame = CGRectMake(0, 0, ame236_w, ceil(ame236_fit.height));
    // ★ Task238：渲染目标从 tableFooterView（列表底部，用户反馈"下面太
    //   不明显"）改为头部堆叠前置区——存属性 + updateTableHeaderHeight
    //   把 [详情头 + 前置区] 合成 tableHeaderView，前置摆在最上面。
    self.ame238_depsSectionView = ame236_footer;
    [self updateTableHeaderHeight];
    NSLog(@"[ModVersionVC] Task238 dependency section pinned above version list: %lu row(s) (inline icon+intro, tap=direct jump)",
          (unsigned long)rows.count);
}

/// Task236：单条前置富条目（64pt）：44pt 图标 + 名称 + "必需/可选 · 介绍"两行
/// + ⓘ 详情。整行点按 = 直跳该模组版本下载页（tap 按钮垫在最底层，文字/
/// 图标默认不拦截触摸）；ⓘ 沿用既有详情页（统计/浏览器兜底）。
- (UIView *)ame236_dependencyRow:(NSDictionary *)row {
    UIView *ame236_row = [[UIView alloc] init];
    ame236_row.backgroundColor = [UIColor secondarySystemFillColor];
    ame236_row.layer.cornerRadius = 12;
    ame236_row.layer.cornerCurve = kCACornerCurveContinuous;

    // 整行点按层（垫底）：直跳该模组的版本下载页
    UIButton *ame236_tap = [UIButton buttonWithType:UIButtonTypeCustom];
    ame236_tap.translatesAutoresizingMaskIntoConstraints = NO;
    [ame236_tap addTarget:self action:@selector(ame236_openDependencyDownload:)
         forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(ame236_tap, "ame230.dep.pid", row[@"pid"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ame236_tap, "ame230.dep.name", row[@"name"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ame236_tap, "ame230.dep.src", row[@"src"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ame236_row addSubview:ame236_tap];

    // 图标（44pt 圆角方片，占位拼图符号；异步加载真实图标）
    UIImageView *ame236_icon = [[UIImageView alloc] init];
    ame236_icon.translatesAutoresizingMaskIntoConstraints = NO;
    ame236_icon.contentMode = UIViewContentModeScaleAspectFill;
    ame236_icon.clipsToBounds = YES;
    ame236_icon.layer.cornerRadius = 10;
    ame236_icon.layer.cornerCurve = kCACornerCurveContinuous;
    ame236_icon.backgroundColor = [UIColor tertiarySystemFillColor];
    ame236_icon.image = [UIImage systemImageNamed:@"puzzlepiece.fill"];
    ame236_icon.tintColor = [UIColor secondaryLabelColor];
    [ame236_row addSubview:ame236_icon];

    UILabel *ame236_title = [[UILabel alloc] init];
    ame236_title.translatesAutoresizingMaskIntoConstraints = NO;
    ame236_title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    ame236_title.textColor = [UIColor labelColor];
    ame236_title.numberOfLines = 1;
    ame236_title.text = row[@"name"];
    [ame236_row addSubview:ame236_title];

    UILabel *ame236_desc = [[UILabel alloc] init];
    ame236_desc.translatesAutoresizingMaskIntoConstraints = NO;
    ame236_desc.font = [UIFont systemFontOfSize:12];
    ame236_desc.textColor = [UIColor secondaryLabelColor];
    ame236_desc.numberOfLines = 2;
    NSString *ame236_kindText = ([row[@"kind"] integerValue] == ModDependencyKindRequired)
        ? localize(@"ame230.deps.required", nil)
        : localize(@"ame230.deps.optional", nil);
    NSString *ame236_intro = row[@"desc"];
    ame236_desc.text = ame236_intro.length > 0
        ? [NSString stringWithFormat:@"%@ · %@", ame236_kindText, ame236_intro]
        : [NSString stringWithFormat:@"%@ · %@", ame236_kindText, localize(@"ame232.deps.no_desc", nil)];
    [ame236_row addSubview:ame236_desc];

    // ⓘ：进既有详情页（图标大图/下载量/关注数/浏览器兜底）
    UIButton *ame236_info = [UIButton buttonWithType:UIButtonTypeSystem];
    ame236_info.translatesAutoresizingMaskIntoConstraints = NO;
    [ame236_info setImage:[UIImage systemImageNamed:@"info.circle"] forState:UIControlStateNormal];
    ame236_info.tintColor = [UIColor tertiaryLabelColor];
    [ame236_info addTarget:self action:@selector(ame230_openDependencyPage:)
         forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(ame236_info, "ame230.dep.pid", row[@"pid"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ame236_info, "ame230.dep.name", row[@"name"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ame236_info, "ame230.dep.src", row[@"src"], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [ame236_row addSubview:ame236_info];

    [NSLayoutConstraint activateConstraints:@[
        [ame236_tap.topAnchor constraintEqualToAnchor:ame236_row.topAnchor],
        [ame236_tap.leadingAnchor constraintEqualToAnchor:ame236_row.leadingAnchor],
        [ame236_tap.trailingAnchor constraintEqualToAnchor:ame236_row.trailingAnchor],
        [ame236_tap.bottomAnchor constraintEqualToAnchor:ame236_row.bottomAnchor],
        [ame236_icon.leadingAnchor constraintEqualToAnchor:ame236_row.leadingAnchor constant:12],
        [ame236_icon.centerYAnchor constraintEqualToAnchor:ame236_row.centerYAnchor],
        [ame236_icon.widthAnchor constraintEqualToConstant:44],
        [ame236_icon.heightAnchor constraintEqualToConstant:44],
        [ame236_title.topAnchor constraintEqualToAnchor:ame236_row.topAnchor constant:10],
        [ame236_title.leadingAnchor constraintEqualToAnchor:ame236_icon.trailingAnchor constant:12],
        [ame236_title.trailingAnchor constraintLessThanOrEqualToAnchor:ame236_info.leadingAnchor constant:-8],
        [ame236_desc.topAnchor constraintEqualToAnchor:ame236_title.bottomAnchor constant:2],
        [ame236_desc.leadingAnchor constraintEqualToAnchor:ame236_icon.trailingAnchor constant:12],
        [ame236_desc.trailingAnchor constraintLessThanOrEqualToAnchor:ame236_info.leadingAnchor constant:-8],
        [ame236_desc.bottomAnchor constraintLessThanOrEqualToAnchor:ame236_row.bottomAnchor constant:-10],
        [ame236_info.trailingAnchor constraintEqualToAnchor:ame236_row.trailingAnchor constant:-12],
        [ame236_info.centerYAnchor constraintEqualToAnchor:ame236_row.centerYAnchor],
        [ame236_info.widthAnchor constraintEqualToConstant:28],
        [ame236_info.heightAnchor constraintEqualToConstant:28],
    ]];

    // 异步加载图标（占位先上，取回后替换）
    NSString *ame236_iconURL = row[@"icon"];
    if ([ame236_iconURL isKindOfClass:[NSString class]] && ame236_iconURL.length > 0) {
        NSURL *ame236_iu = [NSURL URLWithString:ame236_iconURL];
        if (ame236_iu != nil) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                NSData *ame236_idata = [NSData dataWithContentsOfURL:ame236_iu];
                UIImage *ame236_img = ame236_idata != nil ? [UIImage imageWithData:ame236_idata] : nil;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (ame236_img != nil) ame236_icon.image = ame236_img;
                });
            });
        }
    }
    return ame236_row;
}

/// Task236：前置条目点按——直跳该模组【自己的版本下载页】（push，非弹层），
/// 偏好版本/加载器透传（chip 自动选中置顶）；本页作为 delegate，选中版本
/// 即下载到当前实例（见 modVersionViewController:didSelectVersion:）。
- (void)ame236_openDependencyDownload:(UIButton *)sender {
    NSString *ame236_pid = objc_getAssociatedObject(sender, "ame230.dep.pid");
    NSString *ame236_name = objc_getAssociatedObject(sender, "ame230.dep.name");
    NSInteger ame236_src = [objc_getAssociatedObject(sender, "ame230.dep.src") integerValue];
    if (![ame236_pid isKindOfClass:[NSString class]] || ame236_pid.length == 0) {
        [NMToast showMessage:localize(@"ame232.deps.no_desc", nil)];
        return;
    }
    ModItem *ame236_item = [[ModItem alloc] init];
    ame236_item.onlineID = ame236_pid;
    ame236_item.displayName = ame236_name.length > 0 ? ame236_name : ame236_pid;
    ModVersionViewController *ame236_vc = [[ModVersionViewController alloc] init];
    ame236_vc.modItem = ame236_item;
    ame236_vc.delegate = self;
    ame236_vc.title = ame236_item.displayName;
    ame236_vc.apiSource = (ame236_src == kSourceCurseForge) ? kSourceCurseForge : kSourceModrinth;
    ame236_vc.preferredGameVersion = self.preferredGameVersion;
    ame236_vc.preferredLoader = self.preferredLoader;
    [self.navigationController pushViewController:ame236_vc animated:YES];
    NSLog(@"[ModVersionVC] Task236 dependency row direct-jump (in-app version list): %@ (pid=%@ src=%ld)",
          ame236_name, ame236_pid, (long)ame236_src);
}

/// ★ Task236：前置直跳页的版本选择回调——与 Ame232DepDetailViewController
///   同链路下载到当前实例（ModService + SHA1 + NMToast）。版本页 didSelectRow
///   回调后会自行 pop 回本页，这里不重蹈 DownloadVC 式双弹。
- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *ame236_primary = version.primaryFile;
    if (![ame236_primary[@"url"] isKindOfClass:[NSString class]]) {
        [NMToast showMessage:localize(@"i18n_str_265", nil)];
        return;
    }
    ModItem *ame236_dl = viewController.modItem;
    ame236_dl.selectedVersionDownloadURL = ame236_primary[@"url"];
    ame236_dl.fileName = ame236_primary[@"filename"] ?: [NSString stringWithFormat:@"%@.jar", ame236_dl.displayName];
    NSDictionary *ame236_hashes = ame236_primary[@"hashes"];
    if ([ame236_hashes[@"sha1"] isKindOfClass:[NSString class]]) {
        ame236_dl.fileSHA1 = ame236_hashes[@"sha1"];
    }
    NSString *ame236_profile = [PLProfiles current].selectedProfileName ?: @"default";
    [NMToast showMessage:[NSString stringWithFormat:localize(@"launcher.mcl.downloading_file", nil), ame236_dl.displayName]];
    [[ModService sharedService] downloadMod:ame236_dl
                                  toProfile:ame236_profile
                               expectedSHA1:ame236_dl.fileSHA1
                                   progress:nil
                                 completion:^(NSError * _Nullable ame236_err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ame236_err != nil) {
                [NMToast showMessage:ame236_err.localizedDescription];
                return;
            }
            [NMToast showMessage:[NSString stringWithFormat:localize(@"i18n_str_266", nil), ame236_dl.displayName]];
        });
    }];
}

/// Task230：前置详情入口。★ Task236 起由富条目右侧的 ⓘ 按钮触发（整行
/// 点按已直跳版本下载页）——打开 Ame232DepDetailViewController 详情页
/// （图标大图 + 介绍 + 下载量/关注 + 浏览器兜底）。
- (void)ame230_openDependencyPage:(UIButton *)sender {
    NSString *ame230_pid = objc_getAssociatedObject(sender, "ame230.dep.pid");
    NSString *ame230_name = objc_getAssociatedObject(sender, "ame230.dep.name");
    NSInteger ame230_src = [objc_getAssociatedObject(sender, "ame230.dep.src") integerValue];
    NSURL *ame230_url = nil;
    if (ame230_src == 1 && ame230_pid.length > 0) {
        ame230_url = [NSURL URLWithString:[NSString stringWithFormat:@"https://modrinth.com/mod/%@", ame230_pid]];
    } else if (ame230_pid.length > 0) {
        ame230_url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.curseforge.com/minecraft/search?search=%@", ame230_name ?: ame230_pid]];
    }
    // ★ Task232（反馈 #8）：快速入口改在【启动器内】打开项目详情页
    //   （图标 + 标题 + 介绍 + 下载量 + 浏览器入口兜底），不再直接跳网页。
    if (ame230_pid.length == 0 && ame230_name.length == 0) return;
    NSLog(@"[ModVersionVC] Task232 dependency quick-entry (in-app detail): %@ (pid=%@ src=%ld)",
          ame230_name, ame230_pid, (long)ame230_src);
    Ame232DepDetailViewController *detail = [[Ame232DepDetailViewController alloc]
        initWithPid:ame230_pid name:ame230_name source:ame230_src];
    // ★ Task235：透传偏好版本/加载器——“前往下载页”里自动选中匹配
    //   chip 并置顶（与下载页主流程同体验）。
    detail.preferredGameVersion = self.preferredGameVersion;
    detail.preferredLoader = self.preferredLoader;
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:detail];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)processFilters {
    // 从版本数据中提取所有可选的游戏版本和加载器
    NSMutableSet<NSString *> *gameVersions = [NSMutableSet setWithObject:localize(@"resman.mods.filter.all", nil)];
    NSMutableSet<NSString *> *loaders = [NSMutableSet setWithObject:localize(@"resman.mods.filter.all", nil)];

    for (ModVersion *version in self.allVersions) {
        for (NSString *gameVersion in version.gameVersions) {
            [gameVersions addObject:gameVersion];
        }
        for (NSString *loader in version.loaders) {
            [loaders addObject:[loader capitalizedString]]; // 首字母大写用于显示
        }
    }

    // 游戏版本按语义版本号降序排列（新的在前），"全部"始终在最前
    self.availableGameVersions = [[gameVersions allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        if ([obj1 isEqualToString:localize(@"ame193.misc.1", @"全部")]) return NSOrderedAscending;
        if ([obj2 isEqualToString:localize(@"ame193.misc.1", @"全部")]) return NSOrderedDescending;
        return [obj2 compare:obj1 options:NSNumericSearch];
    }];

    // 加载器按字母序排列，"全部"始终在最前
    self.availableLoaders = [[loaders allObjects] sortedArrayUsingSelector:@selector(compare:)];

    // FCL 风格：默认选中"全部"，但如果 preferredGameVersion/preferredLoader
    // 在可选列表中，则自动选中匹配项（让用户无需手动筛选）
    self.selectedGameVersion = self.availableGameVersions.firstObject ?: localize(@"resman.mods.filter.all", nil);
    self.selectedLoader = self.availableLoaders.firstObject ?: localize(@"resman.mods.filter.all", nil);

    // 自动选中 preferred 版本（大小写不敏感比较）
    if (self.preferredGameVersion.length > 0) {
        NSString *preferred = self.preferredGameVersion;
        for (NSString *gv in self.availableGameVersions) {
            if ([gv caseInsensitiveCompare:preferred] == NSOrderedSame) {
                self.selectedGameVersion = gv;
                break;
            }
        }
    }
    // 自动选中 preferred 加载器（preferredLoader 是小写如 "fabric"，
    // availableLoaders 是首字母大写如 "Fabric"）
    if (self.preferredLoader.length > 0) {
        NSString *preferredCapitalized = [self.preferredLoader capitalizedString];
        for (NSString *ld in self.availableLoaders) {
            if ([ld caseInsensitiveCompare:preferredCapitalized] == NSOrderedSame) {
                self.selectedLoader = ld;
                break;
            }
        }
    }

    // 重建版本/加载器 chips（从"加载中..."替换为实际数据）
    [self rebuildVersionChips];
    [self rebuildLoaderChips];
}

#pragma mark - 筛选 + 排序

/// 应用筛选 + 排序并刷新表格
/// 先按游戏版本/加载器过滤，再按排序方式排序
- (void)applyFiltersAndSort {
    // ----- 1. 筛选：游戏版本 + 加载器 -----
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(ModVersion *evaluatedObject, NSDictionary *bindings) {
        BOOL gameVersionMatch = [self.selectedGameVersion isEqualToString:localize(@"ame193.misc.1", @"全部")] ||
                                 [evaluatedObject.gameVersions containsObject:self.selectedGameVersion];
        BOOL loaderMatch = [self.selectedLoader isEqualToString:localize(@"ame193.misc.1", @"全部")] ||
                            [evaluatedObject.loaders containsObject:self.selectedLoader.lowercaseString];
        return gameVersionMatch && loaderMatch;
    }];
    NSArray<ModVersion *> *filtered = [self.allVersions filteredArrayUsingPredicate:predicate];

    // ----- 2. 排序：按选中的排序方式 -----
    NSArray<ModVersion *> *sorted = [self sortVersions:filtered];

    // ----- 3. FCL 风格：把匹配 preferred 版本+加载器的版本置顶 -----
    // 用户从 profile（如 neoforge + 1.21.1）进入版本列表时，
    // 自动把完全匹配的版本置顶，避免在长列表中手动查找
    if (self.preferredGameVersion.length > 0 || self.preferredLoader.length > 0) {
        NSMutableArray<ModVersion *> *pinned = [NSMutableArray array];
        NSMutableArray<ModVersion *> *rest = [NSMutableArray array];
        for (ModVersion *v in sorted) {
            BOOL versionMatch = (self.preferredGameVersion.length == 0) ||
                                [v.gameVersions containsObject:self.preferredGameVersion];
            BOOL loaderMatch = (self.preferredLoader.length == 0) ||
                               [v.loaders containsObject:self.preferredLoader.lowercaseString];
            if (versionMatch && loaderMatch) {
                [pinned addObject:v];
            } else {
                [rest addObject:v];
            }
        }
        // 置顶的部分按原排序顺序，其余接在后面
        if (pinned.count > 0 && pinned.count < sorted.count) {
            sorted = [pinned arrayByAddingObjectsFromArray:rest];
        }
    }

    self.filteredVersions = sorted;

    [self.tableView reloadData];
}

/// 对版本数组按当前选中的排序方式进行排序
- (NSArray<ModVersion *> *)sortVersions:(NSArray<ModVersion *> *)versions {
    if (!versions || versions.count <= 1) return versions;

    // 相关性 / 下载量：保持 API 原始顺序
    // （ModVersion 模型无单版本下载量字段，下载量排序回退为原始顺序，
    //   下载量数据仅存在于项目级别 ModItem.downloads）
    if ([self.selectedSort isEqualToString:kSortRelevance] ||
        [self.selectedSort isEqualToString:kSortDownloads]) {
        return versions;
    }

    // 最新更新 / 创建时间：按 datePublished 排序
    NSISO8601DateFormatter *dateFormatter = [[NSISO8601DateFormatter alloc] init];
    NSMutableArray<ModVersion *> *sorted = [versions mutableCopy];
    __weak typeof(self) weakSelf = self;
    [sorted sortUsingComparator:^NSComparisonResult(ModVersion *v1, ModVersion *v2) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSDate *d1 = [dateFormatter dateFromString:v1.datePublished];
        NSDate *d2 = [dateFormatter dateFromString:v2.datePublished];
        if (!d1) d1 = [NSDate distantPast];
        if (!d2) d2 = [NSDate distantPast];

        if ([strongSelf.selectedSort isEqualToString:kSortUpdated]) {
            // 最新更新：降序（新的在前）
            return [d2 compare:d1];
        } else if ([strongSelf.selectedSort isEqualToString:kSortCreated]) {
            // 创建时间：升序（旧的在前）
            return [d1 compare:d2];
        }
        return NSOrderedSame;
    }];
    return [sorted copy];
}


#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.filteredVersions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModVersionTableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ModVersionCell" forIndexPath:indexPath];
    ModVersion *version = self.filteredVersions[indexPath.row];
    [cell configureWithVersion:version];
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ModVersion *selectedVersion = self.filteredVersions[indexPath.row];
    if ([self.delegate respondsToSelector:@selector(modVersionViewController:didSelectVersion:)]) {
        [self.delegate modVersionViewController:self didSelectVersion:selectedVersion];
    }
    [self.navigationController popViewControllerAnimated:YES];
}

@end


// ============================================================================
// ★ Task232（反馈 #8）：前置项目详情页——像 PCL2CE 一样在启动器内打开，
//   带介绍和图标显示；浏览器入口收进页内按钮（数据不全时的兜底）。
//   Modrinth：公开 API /v2/project/{id}（标题/介绍/图标/下载量/关注数）；
//   CurseForge：无公开免鉴权详情端点，标题沿用既有 ame227_fetchModTitle:，
//   其余字段留空 + 浏览器兜底。标签全部豁免全局描边字体（实底页）。
// ============================================================================
@implementation Ame232DepDetailViewController {
    NSString *_pid;
    NSString *_name;
    NSInteger _source;
    UIImageView *_iconView;
    UILabel *_titleLabel;
    UILabel *_descLabel;
    UILabel *_statsLabel;
    UILabel *_placeholder;
    UIActivityIndicatorView *_spinner;
}

- (instancetype)initWithPid:(NSString *)pid name:(NSString *)name source:(NSInteger)source {
    self = [super init];
    if (self) {
        _pid = [pid copy];
        _name = [name copy];
        _source = source;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    self.title = _name.length > 0 ? _name : (_pid ?: @"");
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self action:@selector(ame232_done)];

    // 图标（96pt 圆角方片，加载失败显示占位）
    _iconView = [[UIImageView alloc] init];
    _iconView.contentMode = UIViewContentModeScaleAspectFill;
    _iconView.clipsToBounds = YES;
    _iconView.layer.cornerRadius = 20.0;
    _iconView.layer.cornerCurve = kCACornerCurveContinuous;
    _iconView.backgroundColor = [UIColor secondarySystemFillColor];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_iconView];

    _titleLabel = [self ame232_label:20 weight:UIFontWeightBold color:[UIColor labelColor] lines:1];
    _descLabel = [self ame232_label:14 weight:UIFontWeightRegular color:[UIColor secondaryLabelColor] lines:0];
    _statsLabel = [self ame232_label:13 weight:UIFontWeightMedium color:[UIColor tertiaryLabelColor] lines:1];

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    _spinner.hidesWhenStopped = YES;
    [_spinner startAnimating];
    [self.view addSubview:_spinner];

    // 浏览器兜底按钮（CurseForge 数据不全 / 用户想看原页时）
    UIButton *browser = [UIButton buttonWithType:UIButtonTypeSystem];
    [browser setTitle:localize(@"ame232.deps.browser", nil) forState:UIControlStateNormal];
    browser.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [browser addTarget:self action:@selector(ame232_openBrowser) forControlEvents:UIControlEventTouchUpInside];
    browser.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:browser];

    // ★ Task235（用户：“前置快捷入口为什么没有自己跳转到对应的模组下载
    //   页”）：详情页新增【前往下载页】主操作——在本页导航栈里 push 该
    //   项目的版本列表（ModVersionViewController），选中版本即下载到
    //   当前实例。浏览器入口降为兜底。
    UIButton *ame235_goDl = [UIButton buttonWithType:UIButtonTypeSystem];
    [ame235_goDl setTitle:localize(@"ame235.deps.godl", nil) forState:UIControlStateNormal];
    ame235_goDl.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    ame235_goDl.tintColor = [UIColor whiteColor];
    ame235_goDl.backgroundColor = [UIColor systemBlueColor];
    ame235_goDl.layer.cornerRadius = 12;
    ame235_goDl.layer.cornerCurve = kCACornerCurveContinuous;
    [ame235_goDl addTarget:self action:@selector(ame235_openDownloadPage) forControlEvents:UIControlEventTouchUpInside];
    ame235_goDl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:ame235_goDl];

    [NSLayoutConstraint activateConstraints:@[
        [_iconView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24],
        [_iconView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:96],
        [_iconView.heightAnchor constraintEqualToConstant:96],
        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_spinner.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:28],
        [_titleLabel.topAnchor constraintEqualToAnchor:_iconView.bottomAnchor constant:20],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_descLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:8],
        [_descLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_descLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [_statsLabel.topAnchor constraintEqualToAnchor:_descLabel.bottomAnchor constant:12],
        [_statsLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_statsLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],
        [ame235_goDl.topAnchor constraintEqualToAnchor:_statsLabel.bottomAnchor constant:20],
        [ame235_goDl.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [ame235_goDl.heightAnchor constraintEqualToConstant:44],
        [ame235_goDl.widthAnchor constraintGreaterThanOrEqualToConstant:180],
        [browser.topAnchor constraintEqualToAnchor:ame235_goDl.bottomAnchor constant:12],
        [browser.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];

    _titleLabel.text = _name.length > 0 ? _name : (_pid ?: @"");
    _descLabel.text = localize(@"ame232.deps.loading", nil);
    [self ame232_fetchDetails];
}

- (UILabel *)ame232_label:(CGFloat)size weight:(UIFontWeight)weight color:(UIColor *)color lines:(NSInteger)lines {
    UILabel *l = [[UILabel alloc] init];
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.numberOfLines = lines;
    l.textAlignment = NSTextAlignmentCenter;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    // 实底页：豁免全局白底黑边描边字体（白字浅底隐形）
    extern void ame229_labelSetStrokeExempt(UILabel *, BOOL);
    ame229_labelSetStrokeExempt(l, YES);
    [self.view addSubview:l];
    return l;
}

- (void)ame232_fetchDetails {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSString *ame232_desc = nil;
        NSString *ame232_icon = nil;
        NSString *ame232_stats = nil;
        if (self->_source == kSourceModrinth && self->_pid.length > 0) {
            NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://api.modrinth.com/v2/project/%@", self->_pid]];
            NSData *data = [NSData dataWithContentsOfURL:url];
            if (data != nil) {
                id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([obj isKindOfClass:[NSDictionary class]]) {
                    NSString *t = [obj objectForKey:@"title"];
                    if ([t isKindOfClass:[NSString class]] && t.length > 0) self->_name = t;
                    NSString *d = [obj objectForKey:@"description"];
                    if ([d isKindOfClass:[NSString class]]) ame232_desc = d;
                    NSString *ic = [obj objectForKey:@"icon_url"];
                    if ([ic isKindOfClass:[NSString class]]) ame232_icon = ic;
                    long long dl = [[obj objectForKey:@"downloads"] longLongValue];
                    long long fl = [[obj objectForKey:@"followers"] longLongValue];
                    ame232_stats = [NSString stringWithFormat:localize(@"ame232.deps.stats", nil),
                                    (long long)dl, (long long)fl];
                }
            }
        } else if (self->_pid.length > 0) {
            // CurseForge：沿用既有标题抓取（详情字段无公开免鉴权端点）
            __block BOOL waited = NO;
            dispatch_group_t g = dispatch_group_create();
            dispatch_group_enter(g);
            __weak typeof(self) ame232_wself = self;
            [[CurseForgeAPI sharedInstance] ame227_fetchModTitle:self->_pid completion:^(NSString *title, NSError *err) {
                typeof(self) ame232_sself = ame232_wself;
                if (ame232_sself && title.length > 0) ame232_desc = [NSString stringWithFormat:localize(@"ame232.deps.cf_desc", nil), title];
                waited = YES;
                dispatch_group_leave(g);
            }];
            dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)));
            (void)waited;
        }
        NSString *iconURL = ame232_icon, *desc = ame232_desc, *stats = ame232_stats, *name = self->_name;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_spinner stopAnimating];
            self->_titleLabel.text = name.length > 0 ? name : (self->_pid ?: @"");
            self->_descLabel.text = desc.length > 0 ? desc : localize(@"ame232.deps.no_desc", nil);
            self->_statsLabel.text = stats ?: @"";
            if (iconURL.length > 0) {
                NSURL *iu = [NSURL URLWithString:iconURL];
                if (iu != nil) {
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        NSData *idata = [NSData dataWithContentsOfURL:iu];
                        UIImage *img = idata != nil ? [UIImage imageWithData:idata] : nil;
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (img != nil) self->_iconView.image = img;
                        });
                    });
                }
            }
            NSLog(@"[ModVersionVC] Task232 dep detail loaded (pid=%@ desc=%@ icon=%d stats=%@)",
                  self->_pid, desc.length > 0 ? @"yes" : @"no", iconURL.length > 0, stats ?: @"-");
        });
    });
}

- (void)ame232_openBrowser {
    NSURL *url = nil;
    if (_source == kSourceModrinth && _pid.length > 0) {
        url = [NSURL URLWithString:[NSString stringWithFormat:@"https://modrinth.com/mod/%@", _pid]];
    } else if (_name.length > 0) {
        url = [NSURL URLWithString:[NSString stringWithFormat:@"https://www.curseforge.com/minecraft/search?search=%@", _name]];
    }
    if (url == nil) return;
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

/// ★ Task235：前往下载页——在本页导航栈里 push 该项目的版本列表
/// （ModVersionViewController），选中版本即下载到当前实例。
- (void)ame235_openDownloadPage {
    if (_pid.length == 0) {
        [NMToast showMessage:localize(@"ame232.deps.no_desc", nil)];
        return;
    }
    ModItem *ame235_item = [[ModItem alloc] init];
    ame235_item.onlineID = _pid;
    ame235_item.displayName = _name.length > 0 ? _name : _pid;
    ModVersionViewController *ame235_vc = [[ModVersionViewController alloc] init];
    ame235_vc.modItem = ame235_item;
    ame235_vc.delegate = self;
    ame235_vc.title = ame235_item.displayName;
    ame235_vc.apiSource = (_source == kSourceCurseForge) ? kSourceCurseForge : kSourceModrinth;
    ame235_vc.preferredGameVersion = self.preferredGameVersion;
    ame235_vc.preferredLoader = self.preferredLoader;
    [self.navigationController pushViewController:ame235_vc animated:YES];
    NSLog(@"[ModVersionVC] Task235 dep go-to-download: %@ (pid=%@ src=%ld)",
          _name, _pid, (long)_source);
}

/// ★ Task235：选中版本 → 直接下载到当前实例（与 DownloadViewController
///   startDownloadForModItem 同链路：ModService + SHA1 + 完成提示）。
- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version {
    NSDictionary *ame235_primary = version.primaryFile;
    if (![ame235_primary[@"url"] isKindOfClass:[NSString class]]) {
        [NMToast showMessage:localize(@"i18n_str_265", nil)];
        return;
    }
    ModItem *ame235_dl = viewController.modItem;
    ame235_dl.selectedVersionDownloadURL = ame235_primary[@"url"];
    ame235_dl.fileName = ame235_primary[@"filename"] ?: [NSString stringWithFormat:@"%@.jar", ame235_dl.displayName];
    NSDictionary *ame235_hashes = ame235_primary[@"hashes"];
    if ([ame235_hashes[@"sha1"] isKindOfClass:[NSString class]]) {
        ame235_dl.fileSHA1 = ame235_hashes[@"sha1"];
    }
    NSString *ame235_profile = [PLProfiles current].selectedProfileName ?: @"default";
    [NMToast showMessage:[NSString stringWithFormat:localize(@"launcher.mcl.downloading_file", nil), ame235_dl.displayName]];
    [[ModService sharedService] downloadMod:ame235_dl
                                  toProfile:ame235_profile
                               expectedSHA1:ame235_dl.fileSHA1
                                   progress:nil
                                 completion:^(NSError * _Nullable ame235_err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ame235_err != nil) {
                [NMToast showMessage:ame235_err.localizedDescription];
                return;
            }
            [NMToast showMessage:[NSString stringWithFormat:localize(@"i18n_str_266", nil), ame235_dl.displayName]];
        });
    }];
    // 注：不在这里 pop——ModVersionViewController 的 didSelectRowAtIndexPath
    // 在回调返回后会自行 pop 回本页（DownloadVC 委托里的 pop 依赖 UIKit
    // 的转场期忽略才没双弹，这里直接不重蹈）。
}

- (void)ame232_done {
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end
