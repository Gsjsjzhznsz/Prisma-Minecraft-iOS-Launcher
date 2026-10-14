#import "VersionManagerViewController.h"
#import "UIKit+NativeSurface.h"
#import "BackgroundManager.h"
#import "PLProfiles.h"
#import "ProfileSettingsViewController.h"
#import "ModsManagerViewController.h"
#import "ShadersManagerViewController.h"
#import "ResourcePacksManagerViewController.h"
#import "DataPacksManagerViewController.h"
#import "WorldsManagerViewController.h"
#import "LauncherPreferences.h"
#import "ScreenUtils.h"
#import "utils.h"
#import "ModLoaderIconHelper.h"
#import "ModpackExportService.h" // for parseVersionId:
#import "CleanupViewController.h"
#import <QuartzCore/QuartzCore.h>

// Section 索引：2 个 section（游戏目录 / 已安装版本）
// 重新设计要点（参照 FCL 100%）：
//   1. 版本管理界面只展示：游戏目录切换 + 已安装版本列表
//   2. 渲染器、图形 API、Mod/光影/资源包管理等全部移到"版本专属设置页"（ProfileSettingsViewController）
//      设置只对该版本生效（FCL 风格）；Task207 起交互拆分：点卡片 = 选用实例，
//      卡片右上 ⋯ 钮 = 进入该页编辑（快捷指令语义，⋯ 只编辑不运行）
//   3. 完全不调用旧 UI（LauncherPrefGameDirViewController / LauncherProfileEditorViewController）
//   4. 游戏目录卡片长按菜单已退役（Task212）：删除入口 = 卡片右上叉号钮；
//   5. 统一使用 accentColor() 与毛玻璃背景，适配启动器新 UI
//   6. Task210 实例卡修订（用户七问定稿）：深浅自适应平贴灰面卡（Task210 全局
//      卡面，不再用 accent 渐变）+ 左上原始彩色实例图标（不着色）+ 右上 ⋯
//      编辑钮（自适应色圆钮、三点 16pt Black）+ 左下名称/版本两行（深浅
//      自适应主/次文字色）+ 选中纯 2pt 原蓝描边内缩环（无光晕无动效）；
//      版本区段列数翻倍（行高提至 104pt 修 iPad 满档字号裁剪）
static NSInteger const kSectionGameDir     = 0;
static NSInteger const kSectionVersions    = 1;

// Task207：快捷指令实例卡布局常量
// 旧版实例单卡行高 84pt 在 iPad 满档 sp（×1.15）下内容需 86pt 被裁
//（用户实测"高度过于矮导致字体被裁减"）；Task210 用户定稿提至 104pt；
// Task212 用户复检"实例卡片实际效果比快捷指令卡片仍矮一圈"再抬一档至
// 128pt（图标同步 22→28 与右上 28pt 圆钮对角平衡，其余定稿几何不动）。
static const CGFloat kVMVersionRowHeight = 128.0;
// ⋯ 编辑钮到卡片边缘的间距；选中高亮环内缩距 = 此值 / 3（动态推导，用户定稿
// "高亮边框宽度为卡片边缘距离省略号按钮距离的1/3"，落地方式 = 边框内缩）。
static const CGFloat kVMCardEllipsisInset = 12.0;
// 高亮环描边粗细（内缩方案下取常规 2pt，用户定稿；Task210 起纯描边无光晕）。
static const CGFloat kVMCardRingBorderWidth = 2.0;
// Task214（用户反馈"快捷指令卡片圆角稍微直了一点，微调一下"）：实例卡与
// 游戏目录卡圆角 12→16pt（更贴近真机快捷指令卡片的连续大圆角，其余几何
// 不动）；磁贴/渲染器卡等其他 VMTileBaseCell 子类保持 12pt（"其他都别改"）。
static const CGFloat kVMCardCornerRadius = 16.0;

#pragma mark - Modern Tile Base Cell

@interface VMTileBaseCell : UICollectionViewCell
@property (nonatomic, strong) UIView *contentContainer;
// 卡片圆角半径（默认 12pt L2 标准；快捷指令卡族在子类里覆写为 16pt，Task214）
@property (nonatomic, assign) CGFloat cardCornerRadius;
- (void)setupViews;
// Task216（CI run 602 病历：方法只写进 @implementation、未进 @interface，
// 子类调用点返回推断为 id，`0.12 * [self ame216_effectOpacityFactor]` 报
// "invalid operands to binary expression"——声明提进接口后返回 CGFloat）
- (CGFloat)ame216_effectOpacityFactor;
- (void)ame216_rebindCardSurface;
@end

@implementation VMTileBaseCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.cardCornerRadius = 12.0; // 默认 L2 标准 12pt；快捷指令卡族子类覆写
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // 阴影：规范 5.2 中阴影档（0.12, 6, (0,3)）
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOffset = CGSizeMake(0, 3);
    self.layer.shadowOpacity = 0.12;
    self.layer.shadowRadius = 6;
    self.layer.masksToBounds = NO;
    // Task152：cell 自身透明 + 无 shadowPath 时 CALayer 回退为直角 bounds 阴影，
    // 圆角卡片四角外露出黑色直角（用户实测"圆角有黑直边"）。
    // 具体路径在 layoutSubviews 中随 contentContainer 实际 frame 更新。

    self.contentContainer = [[UIView alloc] initWithFrame:self.contentView.bounds];
    self.contentContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 规范 5.1：L2 标准卡片圆角 + 连续圆角（Task214：半径可被子类覆写——
    // 快捷指令卡族 16pt / 其余默认 12pt）
    self.contentContainer.layer.cornerRadius = self.cardCornerRadius;
    self.contentContainer.layer.cornerCurve = kCACornerCurveContinuous;
    self.contentContainer.layer.masksToBounds = YES;
    // 规范 6.2：第 1 层浅色半透明基底
    self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    // 规范 5.3：默认卡片描边 0.5pt 白 0.10
    self.contentContainer.layer.borderWidth = 0.5;
    self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    [self.contentView addSubview:self.contentContainer];

    // 规范 6.2：第 2 层 BackgroundManager 毛玻璃
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
}

// Task152：阴影路径随卡片实际 frame 更新——透明 cell 的黑色阴影若无
// shadowPath 会以直角 bounds 绘制，在圆角卡片四角外露出黑色直角。
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect shadowRect = self.contentContainer.frame;
    if (!CGRectIsEmpty(shadowRect)) {
        self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:shadowRect
                                                           cornerRadius:self.cardCornerRadius].CGPath;
    }
}

// Task210（用户定稿"全部磁贴移除"）：点按弹簧缩放动效（touchesBegan/
// touchesEnded/touchesCancelled 三段 0.96 缩放回弹）整链删除——点击即时
// 响应，选中反馈只来自实例卡的内缩描边环。

// Task216（用户"按钮其阴影要始终绑定在一起，调整透明度时有些按钮光没了
// 按钮但是阴影还在，有些按钮始终不变"）：透明度/效果联动三件套——
//   ① 旧况根因一：卡面管线只在 cell init 时挂一次（setupViews），复用池
//      cell 在 reloadData 后永不重铺 → 半透明模式下拖动透明度滑条，部分卡
//      卡面 alpha 永远停在首次创建时的值（"有些按钮始终不变"）；
//   ② 旧况根因二：cell 层投影 shadowOpacity 固定 0.12，卡面随滑条变透时
//      阴影纹丝不动（"光没了按钮但是阴影还在"）；
//   ③ 修复 = configure 时重铺管线（幂等：管线内部先清旧 blur 层再铺新）+
//      阴影/按钮圆底 alpha 统一乘"有效不透明度因子"，与卡面同升同降。
//      快捷指令卡族（实例卡/目录卡）启用；磁贴/渲染器卡保持单次挂载
//      （用户"先只改实例页面的卡片"）。
// 当前管线有效不透明度因子（0~1）：无壁纸 = 1.0（平贴灰面全量）；
// 毛玻璃 = blur 层 alpha 同式 0.3 + blurIntensity×0.7；半透明 = uiOpacity。
- (CGFloat)ame216_effectOpacityFactor {
    BackgroundManager *manager = [BackgroundManager sharedManager];
    if (![manager hasBackground]) return 1.0;
    if (manager.uiEffect == BackgroundUIEffectBlur) {
        return 0.3 + (manager.blurIntensity * 0.7);
    }
    return manager.uiOpacity;
}

// 重铺卡面管线并把 cell 投影绑定到当前有效不透明度（configure 时调用）。
// 阴影基准 0.12（规范 5.2 档）× 因子：卡面越透阴影越淡，不再悬空。
- (void)ame216_rebindCardSurface {
    [[BackgroundManager sharedManager] applyEffectToCollectionViewCell:self];
    CGFloat factor = [self ame216_effectOpacityFactor];
    self.layer.shadowOpacity = 0.12 * factor;
}

@end

#pragma mark - Quick Action Tile Cell

@interface VMQuickActionCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@end

@implementation VMQuickActionCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:24];
    CGFloat titleFont = [ScreenUtils sp:13];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.iconView];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [UIFont systemFontOfSize:titleFont weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor labelColor]; // Task137：语义色（原 Task91 主题色）
    self.titleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.titleLabel];

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor]; // Task137
    self.subtitleLabel.numberOfLines = 0;
    self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.subtitleLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.subtitleLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:12],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:8],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-12],
        [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
        [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:12],
        [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-12],
        [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-10]
    ]];
}

- (void)configureWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle color:(UIColor *)color {
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = color;
    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;
}

@end

#pragma mark - Version Card Cell (Task207 快捷指令样式 / Task210 修订)

// 竖卡布局（参照快捷指令 App 卡片 + 用户两张截图，Task210 七问定稿）：
//   卡底 = 深浅自适应平贴灰面（Task210 全局卡面管线：无壁纸 = AmeCardSurfaceColor
//          浅 #e0e0e0 / 深 #2c2c2c；有壁纸 = 毛玻璃/半透明。accent 渐变卡底
//          随 Task210 退役——它曾跟随新拟态透明度滑条导致"卡片平时透明"）；
//   左上 = 实例图标（沿用 ModLoaderIconHelper 原始彩色直出：PNG 不着色 /
//          SF symbol 品牌色，cube 兜底用主题强调色）；
//   右上 = ⋯ 编辑钮（自适应色圆钮：labelColor 12% 底 + labelColor 三点，
//          三点 16pt Black / 圆底 28pt——Task210 用户定稿"加大加粗两档"）；
//   左下 = 实例名（AmeCardPrimaryTextColor semibold）+ 下一行版本号
//          （AmeCardSecondaryTextColor）——深浅模式自适应"深色和灰色"；
//   选中 = 内缩高亮环：内缩距 = 省略号钮到卡缘间距的 1/3（动态推导），
//          描边 2pt accentColor（原蓝）纯描边——柔光光晕随 Task210 删除
//          （用户定稿"选择高亮后只有边框蓝色"，整卡变色/光晕/按压动效全退）。
// 旧 iconContainer/selectedBadge/isolatedBadge/lastPlayedLabel/chevronView
// 全部退役（用户定稿"纯快捷指令样"）。
@interface VMVersionCardCell : VMTileBaseCell
// 左上实例图标（原 loader 彩色直出 / cube 兜底）
@property (nonatomic, strong) UIImageView *iconView;
// 右上 ⋯ 编辑钮（纯编辑，不改选中）
@property (nonatomic, strong) UIButton *ellipsisButton;
// 选中内缩高亮环（内缩 = 省略号间距/3，描边 2pt accent，纯描边）
@property (nonatomic, strong) UIView *selectionRing;
// 左下名称 + 版本（快捷指令"名称/操作数"位，深浅自适应双色）
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *versionLabel;
// ⋯ 点击回调（VC 在 cellForItem 里捕获 profileName 注入）
@property (nonatomic, copy) void (^ellipsisAction)(void);
@end

@implementation VMVersionCardCell

- (void)setupViews {
    // Task214：实例卡圆角 12→16pt（用户"圆角稍微直了一点"微调定稿）
    self.cardCornerRadius = kVMCardCornerRadius;
    [super setupViews];

    // 紧凑竖卡（128pt 固定行高）内的几何量用固定 pt，不随屏宽缩放：
    // dp 的 iPad 1.3× 会把图标撑到与底部两行 sp 字在卡内重叠；
    // 字体仍走 sp（上限 1.15×）。行高 Task212 定稿 128pt（Task210 的
    // 104pt 用户复检"仍比快捷指令卡矮一圈"）；图标 22→28 同步放大。
    CGFloat iconSize = 28.0;
    CGFloat nameFont = [ScreenUtils sp:15];
    CGFloat ellipsisSize = 28.0;   // Task210：24 → 28（加大两档）

    // ----- 左上实例图标：原始彩色直出（Task210 定稿，白色模板渲染退役）-----
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    // 兜底 cube 为 SF symbol（模板渲染），用主题强调色；loader PNG 由
    // configureImageView 内部保持原色不着色。
    self.iconView.tintColor = accentColor();
    [self.contentContainer addSubview:self.iconView];

    // ----- 右上 ⋯ 编辑钮（Task210：自适应色圆钮 + 16pt Black 三点）-----
    // 深浅模式自适应：浅色卡 = 深色钮，深色卡 = 白钮（labelColor 动态解析），
    // 替代旧白 0.28 固定色（浅色平贴灰面上不可见）。
    self.ellipsisButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.ellipsisButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.ellipsisButton.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.12];
    self.ellipsisButton.layer.cornerRadius = ellipsisSize / 2.0;
    self.ellipsisButton.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageSymbolConfiguration *ellipsisConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIFontWeightBlack];
    [self.ellipsisButton setImage:[UIImage systemImageNamed:@"ellipsis" withConfiguration:ellipsisConfig]
                          forState:UIControlStateNormal];
    self.ellipsisButton.tintColor = [UIColor labelColor];
    // 复用长按菜单的"编辑配置"文案做无障碍标签（不新增 l10n 键）
    self.ellipsisButton.accessibilityLabel = localize(@"i18n_str_1091", nil);
    [self.ellipsisButton addTarget:self
                            action:@selector(ellipsisTapped)
                  forControlEvents:UIControlEventTouchUpInside];
    [self.contentContainer addSubview:self.ellipsisButton];

    // ----- 选中内缩高亮环（原蓝 accent，用户定稿：内缩 = 省略号间距/3）-----
    // Task210：纯描边——shadowColor/shadowOpacity/shadowRadius 柔光组删除，
    // 选中态不再有光晕与整卡变色。
    // Task214（用户："已选择的卡片无法编辑，未选择的才可以"根因）：环是
    // 普通 UIView 且在 ⋯ 钮之后 addSubview（层级更高），选中后透明环身
    // 拦截整卡触摸 → ⋯/叉钮收不到 touchUpInside。环改为不参与触摸命中。
    self.selectionRing = [[UIView alloc] init];
    self.selectionRing.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectionRing.backgroundColor = [UIColor clearColor];
    self.selectionRing.userInteractionEnabled = NO; // Task214：命中穿透（根因修复）
    self.selectionRing.layer.borderColor = accentColor().CGColor;
    self.selectionRing.layer.borderWidth = kVMCardRingBorderWidth;
    self.selectionRing.layer.cornerRadius = kVMCardCornerRadius - (kVMCardEllipsisInset / 3.0);
    self.selectionRing.layer.cornerCurve = kCACornerCurveContinuous;
    self.selectionRing.hidden = YES;
    [self.contentContainer addSubview:self.selectionRing];

    // ----- 左下名称 + 版本（深浅自适应双色两行，快捷指令位）-----
    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    // Task210（用户定稿"字体按深浅模式调整深色和灰色"）：白字退役，
    // 改 AmeCard 主文字色（浅 #333333 / 深 #f5f5f5）。
    self.nameLabel.textColor = AmeCardPrimaryTextColor();
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.versionLabel = [[UILabel alloc] init];
    self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.versionLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
    // 次要文字色（浅 #888888 / 深 #a0a0a0）——两种模式下都是"灰色"。
    self.versionLabel.textColor = AmeCardSecondaryTextColor();
    self.versionLabel.numberOfLines = 1;
    self.versionLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.versionLabel];

    CGFloat ringInset = kVMCardEllipsisInset / 3.0; // 用户定稿：内缩 = 省略号间距 × 1/3
    // 名称行与图标的最小净距：必选优先级在极端字重/缩放组合下可能无解
    //（104pt 预算内各机型余量充足，此守卫仅为绝对防御），降为 999 静默让位。
    NSLayoutConstraint *nameClearance =
        [self.nameLabel.topAnchor constraintGreaterThanOrEqualToAnchor:self.iconView.bottomAnchor constant:2];
    nameClearance.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        // 图标/⋯钮：统一 kVMCardEllipsisInset 内缩（截图对齐语义）
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:kVMCardEllipsisInset],
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:kVMCardEllipsisInset],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.ellipsisButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-kVMCardEllipsisInset],
        [self.ellipsisButton.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:kVMCardEllipsisInset],
        [self.ellipsisButton.widthAnchor constraintEqualToConstant:ellipsisSize],
        [self.ellipsisButton.heightAnchor constraintEqualToConstant:ellipsisSize],

        // 选中环：四边内缩 ringInset = kVMCardEllipsisInset / 3
        [self.selectionRing.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:ringInset],
        [self.selectionRing.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:ringInset],
        [self.selectionRing.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-ringInset],
        [self.selectionRing.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor constant:-ringInset],

        // 名称/版本：左下角两行，版本行距底 10pt
        nameClearance,
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:kVMCardEllipsisInset],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.trailingAnchor constant:-kVMCardEllipsisInset],
        [self.versionLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.versionLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.trailingAnchor constant:-kVMCardEllipsisInset],
        [self.versionLabel.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor constant:-10]
    ]];
}

/// ⋯ 钮点击 → 转发 VC 注入的编辑回调（纯编辑，不改选中）
- (void)ellipsisTapped {
    if (self.ellipsisAction) self.ellipsisAction();
}

- (void)configureWithName:(NSString *)name version:(NSString *)version isSelected:(BOOL)isSelected {
    // Task216：configure 时重铺卡面管线 + 阴影绑定透明度（复用 cell 永不重铺
    // 的根因修复，见基类 ame216_rebindCardSurface 注释）；⋯ 钮圆底同步绑定。
    [self ame216_rebindCardSurface];
    self.ellipsisButton.backgroundColor =
        [[UIColor labelColor] colorWithAlphaComponent:0.12 * [self ame216_effectOpacityFactor]];
    self.nameLabel.text = name;
    self.versionLabel.text = version ?: localize(@"i18n_str_1052", nil);
    self.selectionRing.hidden = !isSelected;

    // 图标 = 原实例图标来源（Task210 定稿"原始彩色图标"）：
    // loader 品牌图标经 ModLoaderIconHelper 检出——PNG 保持原色、SF symbol
    // 用品牌色（原助手内置语义）；无 loader 时回退 cube 兜底（强调色模板）。
    // Task207 的白色模板重渲染随定稿退役。
    NSString *detectedLoader = [ModLoaderIconHelper detectLoaderFromVersionId:version];
    if (detectedLoader) {
        [ModLoaderIconHelper configureImageView:self.iconView
                                      forLoader:detectedLoader
                                 traitCollection:self.traitCollection];
    } else {
        self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
        self.iconView.tintColor = accentColor();
    }

    // 选中环随主题强调色即时刷新（LauncherAppearanceChanged → reloadData 重走此处）
    self.selectionRing.layer.borderColor = accentColor().CGColor;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = [UIImage systemImageNamed:@"cube.box.fill"];
    self.iconView.tintColor = accentColor();
    self.nameLabel.text = nil;
    self.versionLabel.text = nil;
    self.selectionRing.hidden = YES;
    self.ellipsisAction = nil;
}

@end

#pragma mark - Game Directory Cell (Task212：实例卡完全同构版本隔离卡片)

// Task212 用户定稿"游戏目录卡片的样式改成实例卡片完全相同的"：
// VMGameDirCell 整类重写为 VMVersionCardCell 同构（旧 FCL 横排卡——蓝底白
// folder 方块 + 对勾徽章 + chevron——整体退役）：
//   卡底 = 同一条 Task210 全局卡面管线（VMTileBaseCell 承载，无差异）；
//   左上 = folder 图标"图标本身的颜色"（systemBlue 模板直出，无底色方块，
//          与实例卡的 loader 彩色直出同语义）；
//   右上 = 叉号删除钮（28pt 圆底 + 16pt Black xmark，几何/配色与实例卡
//          ⋯ 钮逐项一致——用 SF Symbol 图标而非文字 x）；点击 → 直接呼出
//          确认删除弹窗（不走长按菜单；目录长按功能随本类重写删除）；
//   左下 = 目录名称（主色）+ 下一行目录大小（次色）；
//   选中 = 内缩高亮环（内缩 = 省略号间距/3、2pt accent 纯描边，同实例卡）；
//   "新建目录"加号卡：绿色 plus 直出 + 绿 0.08 淡底保留，绿色 1pt 描边随
//   Task214 用户定稿（"删除添加目录卡片的绿色边框"）退役，描边回归基类
//   默认（白 0.10 / 0.5pt），布局仍走同一套新几何。
@interface VMGameDirCell : VMTileBaseCell
// 左上目录图标（folder 原色直出 / 加号卡为绿色 plus）
@property (nonatomic, strong) UIImageView *iconView;
// 右上叉号删除钮（纯删除入口，不改选中；加号卡隐藏）
@property (nonatomic, strong) UIButton *deleteButton;
// 选中内缩高亮环（同实例卡：内缩 = 省略号间距/3，描边 2pt accent）
@property (nonatomic, strong) UIView *selectionRing;
// 左下目录名 + 目录大小（快捷指令"名称/操作数"位，深浅自适应双色）
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *detailLabel;
// 叉号点击回调（VC 在 cellForItem 里捕获目录名注入）
@property (nonatomic, copy) void (^deleteAction)(void);
@end

@implementation VMGameDirCell

- (void)setupViews {
    // Task214：目录卡圆角与实例卡同步 12→16pt（同属"快捷指令卡片"族）
    self.cardCornerRadius = kVMCardCornerRadius;
    [super setupViews];

    // 几何量与 VMVersionCardCell 逐项一致（固定 pt，不随屏宽缩放）
    CGFloat iconSize = 28.0;
    CGFloat nameFont = [ScreenUtils sp:15];
    CGFloat deleteSize = 28.0;

    // ----- 左上目录图标：folder 本色直出（无底色方块，Task212 定稿）-----
    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    [self.contentContainer addSubview:self.iconView];

    // ----- 右上叉号删除钮（与实例卡 ⋯ 钮同构：自适应色圆底 + 16pt Black）-----
    self.deleteButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.deleteButton.backgroundColor = [[UIColor labelColor] colorWithAlphaComponent:0.12];
    self.deleteButton.layer.cornerRadius = deleteSize / 2.0;
    self.deleteButton.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageSymbolConfiguration *xConfig = [UIImageSymbolConfiguration configurationWithPointSize:16.0 weight:UIFontWeightBlack];
    [self.deleteButton setImage:[UIImage systemImageNamed:@"xmark" withConfiguration:xConfig]
                       forState:UIControlStateNormal];
    self.deleteButton.tintColor = [UIColor labelColor];
    self.deleteButton.accessibilityLabel = localize(@"i18n_str_1083", nil);
    [self.deleteButton addTarget:self
                          action:@selector(deleteTapped)
                forControlEvents:UIControlEventTouchUpInside];
    [self.contentContainer addSubview:self.deleteButton];

    // ----- 选中内缩高亮环（同实例卡：accent 纯描边，无光晕）-----
    // Task214 同实例卡：环不参与触摸命中（透明环身曾拦截叉号钮触摸）。
    self.selectionRing = [[UIView alloc] init];
    self.selectionRing.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectionRing.backgroundColor = [UIColor clearColor];
    self.selectionRing.userInteractionEnabled = NO; // Task214：命中穿透（根因修复）
    self.selectionRing.layer.borderColor = accentColor().CGColor;
    self.selectionRing.layer.borderWidth = kVMCardRingBorderWidth;
    self.selectionRing.layer.cornerRadius = kVMCardCornerRadius - (kVMCardEllipsisInset / 3.0);
    self.selectionRing.layer.cornerCurve = kCACornerCurveContinuous;
    self.selectionRing.hidden = YES;
    [self.contentContainer addSubview:self.selectionRing];

    // ----- 左下目录名 + 大小（深浅自适应双色两行，与实例卡同位同规格）-----
    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:nameFont weight:UIFontWeightSemibold];
    self.nameLabel.textColor = AmeCardPrimaryTextColor();
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.detailLabel = [[UILabel alloc] init];
    self.detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
    self.detailLabel.textColor = AmeCardSecondaryTextColor();
    self.detailLabel.numberOfLines = 1;
    self.detailLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.detailLabel];

    CGFloat ringInset = kVMCardEllipsisInset / 3.0; // 同实例卡：内缩 = 钮间距 × 1/3
    NSLayoutConstraint *nameClearance =
        [self.nameLabel.topAnchor constraintGreaterThanOrEqualToAnchor:self.iconView.bottomAnchor constant:2];
    nameClearance.priority = 999;
    [NSLayoutConstraint activateConstraints:@[
        // 图标/叉号钮：统一 kVMCardEllipsisInset 内缩（与实例卡逐项对齐）
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:kVMCardEllipsisInset],
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:kVMCardEllipsisInset],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.deleteButton.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-kVMCardEllipsisInset],
        [self.deleteButton.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:kVMCardEllipsisInset],
        [self.deleteButton.widthAnchor constraintEqualToConstant:deleteSize],
        [self.deleteButton.heightAnchor constraintEqualToConstant:deleteSize],

        // 选中环：四边内缩 ringInset（同实例卡）
        [self.selectionRing.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:ringInset],
        [self.selectionRing.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:ringInset],
        [self.selectionRing.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-ringInset],
        [self.selectionRing.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor constant:-ringInset],

        // 名称/大小：左下角两行，大小行距底 10pt（同实例卡）
        nameClearance,
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:kVMCardEllipsisInset],
        [self.nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.deleteButton.leadingAnchor constant:-8],
        [self.detailLabel.leadingAnchor constraintEqualToAnchor:self.nameLabel.leadingAnchor],
        [self.detailLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.detailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.deleteButton.leadingAnchor constant:-8],
        [self.detailLabel.bottomAnchor constraintEqualToAnchor:self.contentContainer.bottomAnchor constant:-10]
    ]];
}

/// 叉号点击 → 转发 VC 注入的删除回调（直接呼出确认删除弹窗）
- (void)deleteTapped {
    if (self.deleteAction) self.deleteAction();
}

- (void)configureWithName:(NSString *)name detail:(NSString *)detail isSelected:(BOOL)isSelected isAddButton:(BOOL)isAddButton {
    // Task216：configure 时重铺卡面管线 + 阴影绑定透明度（同实例卡根因修复）；
    // 叉钮圆底同步绑定。加号卡的绿淡底在本调用之后覆盖管线卡面（保持原语义）。
    [self ame216_rebindCardSurface];
    self.deleteButton.backgroundColor =
        [[UIColor labelColor] colorWithAlphaComponent:0.12 * [self ame216_effectOpacityFactor]];
    if (isAddButton) {
        // "新建目录"加号卡：Task214（用户"删除添加目录卡片的绿色边框"）——
        // 绿色 1pt 描边退役，描边回归基类默认（白 0.10 / 0.5pt）；绿色 plus
        // 直出与绿 0.08 淡底保留；布局走同一套新几何；叉号与选中环隐藏。
        self.iconView.image = [UIImage systemImageNamed:@"plus"];
        self.iconView.tintColor = [UIColor systemGreenColor];
        self.nameLabel.text = localize(@"i18n_str_1053", nil);
        self.detailLabel.text = localize(@"i18n_str_1054", nil);
        self.deleteButton.hidden = YES;
        self.selectionRing.hidden = YES;
        self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
        self.contentContainer.layer.borderWidth = 0.5;
        self.contentContainer.backgroundColor = [[UIColor systemGreenColor] colorWithAlphaComponent:0.08];
        return;
    }

    // 目录卡：folder 本色直出 + 名称 + 大小；选中 = 内缩环（同实例卡）。
    // 卡底交由 ame216_rebindCardSurface 重铺的管线决定（半透明/毛玻璃随
    // 设置页实时同步）——旧硬编码 white 0.08 会盖掉管线卡面随透明度滑条
    // 的实时变化，随 Task216 移除；描边仍按基类默认（白 0.10 / 0.5pt）。
    self.deleteButton.hidden = NO;
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    self.nameLabel.text = name;
    self.detailLabel.text = detail ?: @"";
    self.selectionRing.hidden = !isSelected;
    self.selectionRing.layer.borderColor = accentColor().CGColor;
    self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    self.contentContainer.layer.borderWidth = 0.5;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    self.iconView.image = [UIImage systemImageNamed:@"folder.fill"];
    self.iconView.tintColor = [UIColor systemBlueColor];
    self.nameLabel.text = nil;
    self.detailLabel.text = nil;
    self.selectionRing.hidden = YES;
    self.deleteButton.hidden = NO;
    self.deleteAction = nil;
    self.contentContainer.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.10].CGColor;
    self.contentContainer.layer.borderWidth = 0.5;
    self.contentContainer.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
}

@end


#pragma mark - Renderer Card Cell (图形 API 选择卡片，FCL 风格)

@interface VMRendererCell : VMTileBaseCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation VMRendererCell

- (void)setupViews {
    [super setupViews];

    CGFloat iconSize = [ScreenUtils dp:22];

    self.iconView = [[UIImageView alloc] init];
    self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    [self.contentContainer addSubview:self.iconView];

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightSemibold];
    self.nameLabel.textColor = [UIColor labelColor]; // Task137：语义色（原 Task91 主题色）
    self.nameLabel.numberOfLines = 1;
    self.nameLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.nameLabel];

    self.descLabel = [[UILabel alloc] init];
    self.descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.descLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:10] weight:UIFontWeightRegular];
    self.descLabel.textColor = [UIColor secondaryLabelColor]; // Task137
    self.descLabel.numberOfLines = 2;
    self.descLabel.lineBreakMode = NSLineBreakByWordWrapping;
    self.descLabel.adjustsFontForContentSizeCategory = NO;
    [self.contentContainer addSubview:self.descLabel];

    self.selectedBadge = [[UIView alloc] init];
    self.selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.selectedBadge.backgroundColor = accentColor();
    self.selectedBadge.layer.cornerRadius = 8;
    self.selectedBadge.hidden = YES;
    [self.contentContainer addSubview:self.selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:8 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [self.selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [self.iconView.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:10],
        [self.iconView.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.iconView.widthAnchor constraintEqualToConstant:iconSize],
        [self.iconView.heightAnchor constraintEqualToConstant:iconSize],
        [self.nameLabel.topAnchor constraintEqualToAnchor:self.iconView.bottomAnchor constant:6],
        [self.nameLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.nameLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.descLabel.topAnchor constraintEqualToAnchor:self.nameLabel.bottomAnchor constant:2],
        [self.descLabel.leadingAnchor constraintEqualToAnchor:self.contentContainer.leadingAnchor constant:10],
        [self.descLabel.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-10],
        [self.descLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentContainer.bottomAnchor constant:-8],
        [self.selectedBadge.topAnchor constraintEqualToAnchor:self.contentContainer.topAnchor constant:8],
        [self.selectedBadge.trailingAnchor constraintEqualToAnchor:self.contentContainer.trailingAnchor constant:-8],
        [self.selectedBadge.widthAnchor constraintEqualToConstant:16],
        [self.selectedBadge.heightAnchor constraintEqualToConstant:16],
        [checkmark.centerXAnchor constraintEqualToAnchor:self.selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:self.selectedBadge.centerYAnchor]
    ]];
}

- (void)configureWithIcon:(NSString *)iconName
                     name:(NSString *)name
                  details:(NSString *)details
              isSelected:(BOOL)isSelected
                  isBest:(BOOL)isBest {
    self.iconView.image = [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = isBest ? accentColor() : [UIColor systemGrayColor];
    self.nameLabel.text = name;
    self.descLabel.text = details;
    self.selectedBadge.hidden = !isSelected;
    self.selectedBadge.backgroundColor = accentColor();

    if (isSelected) {
        self.contentView.layer.borderColor = accentColor().CGColor;
        self.contentView.layer.borderWidth = 1.5;
    } else if (isBest) {
        self.contentView.layer.borderColor = [[accentColor() colorWithAlphaComponent:0.4] CGColor];
        self.contentView.layer.borderWidth = 1.0;
    } else {
        self.contentView.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12].CGColor;
        self.contentView.layer.borderWidth = 0.5;
    }
    self.contentView.layer.cornerRadius = 12;
    self.contentView.layer.masksToBounds = YES;
}

@end

#pragma mark - Header View

@interface VMSectionHeaderView : UICollectionReusableView
@property (nonatomic, strong) UIView *accentBar;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UILabel *countBadge;
- (void)configureWithIcon:(NSString *)iconName title:(NSString *)title subtitle:(NSString *)subtitle count:(NSInteger)count;
@end

@implementation VMSectionHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // Task160：标题后的 SystemMaterial 毛玻璃块整块退役（用户指令：
        // "显示壁纸时文字的背景会挡住，去掉，例如游戏目录和已安装的版本
        // 标题"）——标题/副标题直接浮在壁纸上，仅保留强调条/图标/计数胶囊

        // 规范 9.5：前导强调色条（4pt 宽，圆角，accentColor）
        self.accentBar = [[UIView alloc] init];
        self.accentBar.translatesAutoresizingMaskIntoConstraints = NO;
        self.accentBar.backgroundColor = accentColor();
        self.accentBar.layer.cornerRadius = 2;
        self.accentBar.layer.cornerCurve = kCACornerCurveContinuous;
        [self addSubview:self.accentBar];

        // 规范 8.2：图标容器（用 SF Symbol，tint = accentColor）
        self.iconView = [[UIImageView alloc] init];
        self.iconView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconView.tintColor = accentColor();
        [self addSubview:self.iconView];

        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:16] weight:UIFontWeightBold];
        // 规范 2.1：强制使用系统色
        self.titleLabel.textColor = AmeCardPrimaryTextColor(); // Task160 规格主文字
        [self addSubview:self.titleLabel];

        self.subtitleLabel = [[UILabel alloc] init];
        self.subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:11] weight:UIFontWeightRegular];
        // 规范 2.1：副文字 secondaryLabelColor
        self.subtitleLabel.textColor = AmeCardSecondaryTextColor(); // Task160 规格次要文字
        self.subtitleLabel.numberOfLines = 0;
        self.subtitleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        [self addSubview:self.subtitleLabel];

        // Task137：计数胶囊统一用 AmeBadgeLabel（与下载版本类型胶囊同实现）：
        // 宽度随字体动态（intrinsic 完整补偿，永不截断）、高 24 ≈ 两行 12pt 字、
        // 圆角随高度取半、垂直居中于整块；位置靠右固定（远离卡片边缘）。
        self.countBadge = [[AmeBadgeLabel alloc] init];
        self.countBadge.translatesAutoresizingMaskIntoConstraints = NO;
        self.countBadge.font = [UIFont systemFontOfSize:[ScreenUtils sp:12] weight:UIFontWeightSemibold];
        self.countBadge.textColor = [UIColor whiteColor];
        self.countBadge.backgroundColor = accentColor();
        self.countBadge.hidden = YES;
        [self addSubview:self.countBadge];

        [NSLayoutConstraint activateConstraints:@[
            // 前导强调条：左侧 18pt，垂直居中，4pt 宽，18pt 高
            [self.accentBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18],
            [self.accentBar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.accentBar.widthAnchor constraintEqualToConstant:4],
            [self.accentBar.heightAnchor constraintEqualToConstant:18],
            // 图标：紧贴强调条右侧 8pt，垂直居中，16x16
            [self.iconView.leadingAnchor constraintEqualToAnchor:self.accentBar.trailingAnchor constant:8],
            [self.iconView.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
            [self.iconView.widthAnchor constraintEqualToConstant:16],
            [self.iconView.heightAnchor constraintEqualToConstant:16],
            // 标题：图标右侧 6pt
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.iconView.trailingAnchor constant:6],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.countBadge.leadingAnchor constant:-8],
            // 副标题：标题下方 2pt
            [self.subtitleLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.subtitleLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.subtitleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [self.subtitleLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-4],
            // 计数徽章：右侧 18pt（远离卡片边缘），垂直居中对齐左侧两行文字块，
            // 高 24；宽度由字体自适应（AmeBadgeLabel intrinsic + 8pt 内边距）
            [self.countBadge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18],
            [self.countBadge.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.countBadge.heightAnchor constraintEqualToConstant:24]
        ]];
    }
    return self;
}

/// 配置 Header（图标 + 标题 + 副标题 + 计数）
- (void)configureWithIcon:(NSString *)iconName
                    title:(NSString *)title
                 subtitle:(NSString *)subtitle
                    count:(NSInteger)count {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightSemibold];
    self.iconView.image = [UIImage systemImageNamed:iconName withConfiguration:config] ?: [UIImage systemImageNamed:iconName];
    self.iconView.tintColor = accentColor();
    self.accentBar.backgroundColor = accentColor();
    self.countBadge.backgroundColor = accentColor();

    self.titleLabel.text = title;
    self.subtitleLabel.text = subtitle;

    if (count >= 0) {
        // Task137：内边距由 AmeBadgeLabel 的 textInsets 保证，不再用空格凑宽度
        self.countBadge.text = [NSString stringWithFormat:@"%ld", (long)count];
        self.countBadge.hidden = NO;
    } else {
        self.countBadge.hidden = YES;
    }
}

@end

#pragma mark - View Controller

@interface VersionManagerViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UICollectionView *collectionView;
@property (nonatomic, strong) NSArray<NSString *> *profileList;
@property (nonatomic, strong) NSString *selectedProfile;
@property (nonatomic, strong) NSMutableArray<NSString *> *gameDirList;
@property (nonatomic, strong) NSString *currentGameDir;
// 空状态视图（无版本时显示引导）
@property (nonatomic, strong) UIView *emptyStateView;
// 渲染器 section 数据（启动器 native 渲染器库选择，LWJGL 层）
@property (nonatomic, strong) NSArray<NSString *> *rendererKeys;
@property (nonatomic, strong) NSArray<NSString *> *rendererNames;
@property (nonatomic, strong) NSArray<NSString *> *rendererIcons;
@property (nonatomic, strong) NSArray<NSString *> *rendererDescs;
// 图形 API section 数据（MC 26.2+ 游戏内 OpenGL/Vulkan 切换，游戏层）
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiKeys;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiNames;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiIcons;
@property (nonatomic, strong) NSArray<NSString *> *graphicsApiDescs;
@end

@implementation VersionManagerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // 不设置 self.title，避免顶部导航栏出现"版本管理"标题黑条（参照 FCL 无 title 风格）
    self.view.backgroundColor = [UIColor clearColor];
    // 彻底隐藏导航栏黑条（仅当作为非 modal 根页面且是栈中唯一 VC 时）
    // 快捷入口（showModsManager 等）会预 push 子页面，此时 count > 1，不隐藏导航栏
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.viewControllers.count == 1) {
        self.navigationController.navigationBarHidden = YES;
    }
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [self setupRendererData];
    [self setupGraphicsApiData];
    [self setupCollectionView];
    [self setupEmptyStateView];
    [self setupNavigationBar];
    [self setupLongPressGesture];
    [self loadProfiles];
    [self loadGameDirList];
    [self updateEmptyState];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"SelectedProfileChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(profileChanged)
                                                 name:@"ReloadProfileList"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleBackgroundUIEffectChanged:)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleAccentColorChanged)
                                                 name:@"LauncherAppearanceChanged"
                                               object:nil];
}

/// FCL 风格：浮动"+"按钮放置在视图右上角，点击进入下载/新建版本页面
/// 无论导航栏是否可见都使用浮动按钮，确保按钮在所有模式下都可访问
- (void)setupNavigationBar {
    UIButton *fab = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *plusConfig = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIFontWeightBold];
    UIImage *plusImg = [UIImage systemImageNamed:@"plus" withConfiguration:plusConfig];
    [fab setImage:plusImg forState:UIControlStateNormal];
    fab.tintColor = [UIColor whiteColor];
    // 规范 2.6：使用 accentColor() 而非 systemBlueColor
    fab.backgroundColor = accentColor();
    // 规范 5.1：FAB 完全圆形（22pt 圆角 = 44/2）
    fab.layer.cornerRadius = 22;
    fab.layer.cornerCurve = kCACornerCurveContinuous;
    // 规范 5.2：FAB 阴影档（0.20, 8, (0,4)）—— 比 L2 卡片阴影更强
    fab.layer.shadowColor = [UIColor blackColor].CGColor;
    fab.layer.shadowOffset = CGSizeMake(0, 4);
    fab.layer.shadowOpacity = 0.20;
    fab.layer.shadowRadius = 8;
    // 注意：不能用 masksToBounds=YES，否则会裁掉阴影
    fab.layer.masksToBounds = NO;
    fab.translatesAutoresizingMaskIntoConstraints = NO;
    fab.accessibilityLabel = localize(@"i18n_str_2027", nil);
    [fab addTarget:self action:@selector(fabTouchDown) forControlEvents:UIControlEventTouchDown];
    [fab addTarget:self action:@selector(fabTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    [fab addTarget:self action:@selector(createNewVersion) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:fab];
    [self.view bringSubviewToFront:fab];

    [NSLayoutConstraint activateConstraints:@[
        // 规范 4.1：FAB 44x44（更好的触控目标，符合 iOS HIG）
        [fab.widthAnchor constraintEqualToConstant:44],
        [fab.heightAnchor constraintEqualToConstant:44],
        [fab.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [fab.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    ]];

    // 规范 15.4：FAB 进场动画（JellyBounce 果冻回弹）
    fab.transform = CGAffineTransformMakeScale(0.3, 0.3);
    [UIView animateWithDuration:0.6
                          delay:0.15
         usingSpringWithDamping:0.55
          initialSpringVelocity:0.8
                         options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        fab.transform = CGAffineTransformIdentity;
    } completion:nil];

    // ★ Task255：第二颗 FAB（扫描/恢复/清理入口）——T5"扫描目录中存在的
    //   版本供用户恢复" + T6"清理垃圾"的统一入口。同 FAB 几何，叠放其下。
    UIButton *scan = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *scanConfig = [UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIFontWeightBold];
    UIImage *scanImg = [UIImage systemImageNamed:@"magnifyingglass" withConfiguration:scanConfig];
    [scan setImage:scanImg forState:UIControlStateNormal];
    scan.tintColor = [UIColor whiteColor];
    scan.backgroundColor = accentColor();
    scan.layer.cornerRadius = 22;
    scan.layer.cornerCurve = kCACornerCurveContinuous;
    scan.layer.shadowColor = [UIColor blackColor].CGColor;
    scan.layer.shadowOffset = CGSizeMake(0, 4);
    scan.layer.shadowOpacity = 0.20;
    scan.layer.shadowRadius = 8;
    scan.layer.masksToBounds = NO;
    scan.translatesAutoresizingMaskIntoConstraints = NO;
    scan.accessibilityLabel = localize(@"vm.scan.title", @"扫描版本");
    [scan addTarget:self action:@selector(ame255_showScanActionSheet) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:scan];
    [self.view bringSubviewToFront:fab];
    [NSLayoutConstraint activateConstraints:@[
        [scan.widthAnchor constraintEqualToConstant:44],
        [scan.heightAnchor constraintEqualToConstant:44],
        [scan.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:62],
        [scan.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    ]];
}

/// FAB 按下：缩放反馈（规范 9.3）
- (void)fabTouchDown {
    [UIView animateWithDuration:0.15 delay:0 usingSpringWithDamping:0.7 initialSpringVelocity:0.8 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        UIButton *fab = [self findFabButton];
        fab.transform = CGAffineTransformMakeScale(0.90, 0.90);
        fab.layer.shadowOpacity = 0.12;
        fab.layer.shadowRadius = 4;
    } completion:nil];
}

/// FAB 抬起：回弹反馈
- (void)fabTouchUp {
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.9 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        UIButton *fab = [self findFabButton];
        fab.transform = CGAffineTransformIdentity;
        fab.layer.shadowOpacity = 0.20;
        fab.layer.shadowRadius = 8;
    } completion:nil];
}

/// 找到视图中的 FAB 按钮
- (UIButton *)findFabButton {
    for (UIView *v in self.view.subviews) {
        if ([v isKindOfClass:[UIButton class]] && [v.accessibilityLabel isEqualToString:localize(@"i18n_str_2027", @"新建版本")]) {
            return (UIButton *)v;
        }
    }
    return nil;
}

/// 长按手势：实例卡片直接呼出确认删除弹窗（Task212；目录卡片不再响应长按）
- (void)setupLongPressGesture {
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc]
        initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.5;
    [self.collectionView addGestureRecognizer:longPress];
}

- (void)createNewVersion {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowDownloadPage" object:nil];
}

#pragma mark - Empty State

/// 创建空状态视图（无版本时显示引导，参照规范 10.1 空状态）
- (void)setupEmptyStateView {
    self.emptyStateView = [[UIView alloc] init];
    self.emptyStateView.translatesAutoresizingMaskIntoConstraints = NO;
    self.emptyStateView.hidden = YES;
    [self.view addSubview:self.emptyStateView];
    [self.view bringSubviewToFront:self.emptyStateView];

    // 规范 10.1：图标容器（80x80 圆形，accentColor 0.12 浅底）
    UIView *iconContainer = [[UIView alloc] init];
    iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    iconContainer.backgroundColor = [accentColor() colorWithAlphaComponent:0.12];
    iconContainer.layer.cornerRadius = 40;
    iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self.emptyStateView addSubview:iconContainer];

    UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIFontWeightRegular];
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    iconView.contentMode = UIViewContentModeScaleAspectFit;
    iconView.image = [UIImage systemImageNamed:@"cube.box" withConfiguration:iconConfig];
    iconView.tintColor = accentColor();
    [iconContainer addSubview:iconView];

    // 规范 2.1：标题用 labelColor
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:18] weight:UIFontWeightBold];
    titleLabel.textColor = AmeCardPrimaryTextColor(); // Task160 规格主文字
    titleLabel.text = localize(@"i18n_str_1056", nil);
    titleLabel.textAlignment = NSTextAlignmentCenter;
    [self.emptyStateView addSubview:titleLabel];

    // 规范 2.1：副标题用 secondaryLabelColor
    UILabel *subtitleLabel = [[UILabel alloc] init];
    subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    subtitleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightRegular];
    subtitleLabel.textColor = AmeCardSecondaryTextColor(); // Task160 规格次要文字
    subtitleLabel.text = localize(@"i18n_str_1057", nil);
    subtitleLabel.textAlignment = NSTextAlignmentCenter;
    subtitleLabel.numberOfLines = 0;
    [self.emptyStateView addSubview:subtitleLabel];

    // 规范 9.2：CTA 按钮（accentColor 背景 + 白字 + 圆角）
    UIButton *ctaButton = [UIButton buttonWithType:UIButtonTypeSystem];
    ctaButton.translatesAutoresizingMaskIntoConstraints = NO;
    UIImageSymbolConfiguration *btnIconConfig = [UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIFontWeightBold];
    UIImage *btnIcon = [UIImage systemImageNamed:@"arrow.down.circle.fill" withConfiguration:btnIconConfig];
    [ctaButton setImage:btnIcon forState:UIControlStateNormal];
    [ctaButton setTitle:[@"  " stringByAppendingString:localize(@"i18n_str_2028", nil)] forState:UIControlStateNormal];
    ctaButton.titleLabel.font = [UIFont systemFontOfSize:[ScreenUtils sp:15] weight:UIFontWeightSemibold];
    [ctaButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    ctaButton.tintColor = [UIColor whiteColor];
    ctaButton.backgroundColor = accentColor();
    ctaButton.layer.cornerRadius = 22;
    ctaButton.layer.cornerCurve = kCACornerCurveContinuous;
    ctaButton.layer.shadowColor = [UIColor blackColor].CGColor;
    ctaButton.layer.shadowOffset = CGSizeMake(0, 3);
    ctaButton.layer.shadowOpacity = 0.15;
    ctaButton.layer.shadowRadius = 6;
    ctaButton.layer.masksToBounds = NO;
    ctaButton.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 20);
    [ctaButton addTarget:self action:@selector(createNewVersion) forControlEvents:UIControlEventTouchUpInside];
    [self.emptyStateView addSubview:ctaButton];

    [NSLayoutConstraint activateConstraints:@[
        // 空状态视图居中
        [self.emptyStateView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyStateView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.emptyStateView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-64],
        // 图标容器：顶部对齐，居中，80x80
        [iconContainer.topAnchor constraintEqualToAnchor:self.emptyStateView.topAnchor],
        [iconContainer.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [iconContainer.widthAnchor constraintEqualToConstant:80],
        [iconContainer.heightAnchor constraintEqualToConstant:80],
        // 图标居中
        [iconView.centerXAnchor constraintEqualToAnchor:iconContainer.centerXAnchor],
        [iconView.centerYAnchor constraintEqualToAnchor:iconContainer.centerYAnchor],
        [iconView.widthAnchor constraintEqualToConstant:36],
        [iconView.heightAnchor constraintEqualToConstant:36],
        // 标题：图标下方 16pt
        [titleLabel.topAnchor constraintEqualToAnchor:iconContainer.bottomAnchor constant:16],
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [titleLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        // 副标题：标题下方 6pt
        [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:6],
        [subtitleLabel.leadingAnchor constraintEqualToAnchor:self.emptyStateView.leadingAnchor],
        [subtitleLabel.trailingAnchor constraintEqualToAnchor:self.emptyStateView.trailingAnchor],
        // CTA 按钮：副标题下方 24pt
        [ctaButton.topAnchor constraintEqualToAnchor:subtitleLabel.bottomAnchor constant:24],
        [ctaButton.centerXAnchor constraintEqualToAnchor:self.emptyStateView.centerXAnchor],
        [ctaButton.heightAnchor constraintEqualToConstant:44],
        [ctaButton.bottomAnchor constraintEqualToAnchor:self.emptyStateView.bottomAnchor]
    ]];
}

/// 根据版本列表数量显示/隐藏空状态视图
- (void)updateEmptyState {
    BOOL isEmpty = (self.profileList.count == 0);
    self.emptyStateView.hidden = !isEmpty;
    self.collectionView.hidden = isEmpty;

    if (isEmpty) {
        // 规范 15.4：空状态进场动画（果冻回弹 + 淡入）
        self.emptyStateView.alpha = 0;
        self.emptyStateView.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [UIView animateWithDuration:0.5
                              delay:0.1
             usingSpringWithDamping:0.7
              initialSpringVelocity:0.6
                             options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.emptyStateView.alpha = 1;
            self.emptyStateView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    CGPoint point = [gesture locationInView:self.collectionView];
    NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
    if (!indexPath) return;

    if (indexPath.section == kSectionGameDir) {
        // Task212（用户定稿）：游戏目录长按功能删除——切换 = 点卡片，
        // 删除 = 点叉号钮；长按不再响应任何菜单。
        return;
    } else if (indexPath.section == kSectionVersions) {
        // Task212（用户定稿）：长按实例卡片 = 直接呼出确认删除弹窗
        //（旧"选择/编辑/删除"操作菜单退役：选择 = 点卡片本体，
        // 编辑 = 卡片右上 ⋯ 钮，两个入口仍在，菜单纯属冗余）；
        // deleteProfile 内含最后一个实例不可删守卫 + 二次确认。
        if (indexPath.item >= (NSInteger)self.profileList.count) return;
        [self deleteProfile:self.profileList[indexPath.item]];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 重新隐藏导航栏黑条（pop 回根页面时 topViewController == self）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil &&
        self.navigationController.topViewController == self) {
        self.navigationController.navigationBarHidden = YES;
        // 规范 4.1：导航栏隐藏时，顶部 inset 需为 FAB 留出空间
        CGFloat topInset = self.view.safeAreaInsets.top + 8 + 44 + 8;
        self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 24, 0);
        self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(topInset, 0, 24, 0);
    }
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // push 子页面时显示导航栏（子页面需要返回按钮）
    if (self.navigationController &&
        self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController == nil) {
        self.navigationController.navigationBarHidden = NO;
    }
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)profileChanged {
    [PLProfiles updateCurrent];
    [self loadProfiles];
    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

- (void)handleBackgroundUIEffectChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
    });
}

- (void)handleAccentColorChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.collectionView reloadData];
        [self updateEmptyState];
    });
}

#pragma mark - Renderer Data Setup

/// 初始化渲染器选项数据（启动器 native 渲染器库选择，LWJGL 层）
/// 参照 FCL/HMCL 的渲染器选择面板，提供 7 个选项及对应描述
/// 注意：名称使用简短标识，不使用 getRendererNames 返回的长本地化字符串
- (void)setupRendererData {
    // Task 142：读前迁移（幂等；旧版家族键直写 video.renderer/profile 的
    // 存量数据入位——渲染器层 "mg" + 后端键），保证本面板取到的键表
    // 与设置页/实例页同源。
    ame142_migrateRendererStorage();
    self.rendererKeys = getRendererKeys(NO);
    // 简短渲染器名称（不使用 getRendererNames 的长本地化字符串）
    // Task 140：按【键值】映射而非按下标配对。旧实现硬编码 7 个短名并
    // 假设与 getRendererKeys() 顺序一致——但该列表按 dylib 存在性动态
    // 过滤（本构建缺 libtinygl4angle/libmobileglues/libltw，实际只有
    // 4 项），下标错位会让“点 ANGLE 写 zink”式静默错写。键值映射天然
    // 免疫过滤与顺序变化；未知名回退键值本身。
    // 注：本面板与 selectRendererAtIndex: 当前无调用者（渲染器编辑已
    // 移交 ProfileSettingsViewController），此处修正是防复活的地雷。
    // Task 142：+"mg" 逻辑键（MobileGL 家族唯一渲染器层入口，不写后端）。
    NSDictionary *ame140_shortNames = @{
        @"auto": @"Auto",
        @ RENDERER_KEY_MG: @"MobileGlues",
        @ RENDERER_NAME_MTL_ANGLE: @"ANGLE",
        @ RENDERER_NAME_VGPU: @"VGPU", // Task173：旧版 MC 专用渲染器
        @ RENDERER_NAME_MOBILEGLUES: @"MobileGlues",
        @ RENDERER_NAME_VK_ZINK: @"Zink",
        @ RENDERER_NAME_LTW: @"LTW",
        @ RENDERER_NAME_VULKAN: @"MoltenVK",
        @ RENDERER_NAME_MOBILEGL: @"MobileGL",
        @ RENDERER_NAME_MOBILEGL_GLES: @"MobileGL GLES",
        @ RENDERER_NAME_MITHRIL: @"Mithril",
        @ RENDERER_NAME_NGGL4ES: @"Krypton Wrapper", // Task209：用户点名改名（≤26.2 定位；原 NG-GL4ES，ZL2 的 gl4es）
        @ RENDERER_NAME_GL4ESZL2: @"gl4es(≤26.2)", // Task211 引入；Task212 用户定名（holy gl4es 已退役）
    };
    NSMutableArray *ame140_names = [NSMutableArray array];
    for (NSString *ame140_key in self.rendererKeys) {
        [ame140_names addObject:ame140_shortNames[ame140_key] ?: ame140_key];
    }
    self.rendererNames = ame140_names;
    self.rendererIcons = @[
        @"wand.and.stars",
        @"cpu",
        @"rectangle.stack.fill",
        @"bolt.fill",
        @"circle.hexagongrid.fill",
        @"square.stack.3d.up.fill",
        @"flame.fill"
    ];
    self.rendererDescs = @[
        localize(@"i18n_str_1059", nil),
        localize(@"i18n_str_1060", nil),
        localize(@"i18n_str_1061", nil),
        localize(@"i18n_str_1062", nil),
        localize(@"i18n_str_1063", nil),
        localize(@"i18n_str_1064", nil),
        localize(@"i18n_str_1065", nil)
    ];
}

#pragma mark - Graphics API Data Setup (MC 26.2+)

/// 初始化图形 API 选项数据（MC 26.2+ 游戏内 OpenGL/Vulkan 切换，游戏层）
///
/// Mojang 在 MC 26.2 Snapshot 1 引入了 "Graphics API" 视频设置项，有 3 个值：
///   - default        由 Mojang 决定（snapshot-1~7 为 Vulkan，snapshot-8+ 为 OpenGL）
///   - prefer_vulkan  优先使用 Vulkan，失败时回退 OpenGL
///   - prefer_opengl  优先使用 OpenGL，失败时回退 Vulkan
///
/// 注意：与渲染器（renderer）是两个不同维度
- (void)setupGraphicsApiData {
    self.graphicsApiKeys = @[@"default", @"prefer_vulkan", @"prefer_opengl"];
    self.graphicsApiNames = @[localize(@"i18n_str_943", nil), localize(@"i18n_str_941", nil), localize(@"i18n_str_942", nil)];
    self.graphicsApiIcons = @[
        @"wand.and.stars",
        @"flame.fill",
        @"rectangle.stack.fill"
    ];
    self.graphicsApiDescs = @[
        localize(@"i18n_str_1066", nil),
        localize(@"i18n_str_1067", nil),
        localize(@"i18n_str_1068", nil)
    ];
}

/// 判断当前选中 profile 的版本是否为 MC 26.2+（即 1.21.8+ 后的新版本号方案）
/// 26.x 系列 = 1.21.8 起的快照/正式版采用的新版本号格式
- (BOOL)isCurrentProfileModernVersion {
    if (!self.selectedProfile) return NO;
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *versionId = profile[@"lastVersionId"];
    if (!versionId) return NO;
    // 修复 Fabric/Quilt/Forge loader profile 的版本号识别：
    //   原实现用 digits 字符集截取 prefix，但 fabric-loader-0.16.0-26.2 的第 0 个
    //   字符 'f' 不是数字，prefix 截成空字符串，导致 MC 26.2+ Fabric profile
    //   看不到"图形 API"选项。
    //   修复：先用 ModpackExportService.parseVersionId 提取 minecraft 版本号，
    //   再用提取后的版本号判断。也支持 forge/neoforge 形如 "26.2-forge-..."。
    NSDictionary *parsed = [ModpackExportService parseVersionId:versionId];
    NSString *mcVersion = parsed[@"minecraft"] ?: versionId;
    // 26.x 系列
    if ([mcVersion hasPrefix:@"26."]) return YES;
    if ([mcVersion hasPrefix:@"26w"]) return YES;
    // 1.21.8 及以上
    if ([mcVersion hasPrefix:@"1.21."]) {
        NSString *minorStr = [mcVersion substringFromIndex:5];
        NSInteger minor = [minorStr integerValue];
        if (minor >= 8) return YES;
    }
    return NO;
}

/// 获取当前选中 profile 的渲染器（如未设置则回退到全局偏好）
- (NSString *)currentRendererForSelectedProfile {
    if (!self.selectedProfile) return @"auto";
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *r = profile[@"renderer"];
    if (r.length == 0) {
        r = getPrefObject(@"video.renderer");
    }
    return r.length > 0 ? r : @"auto";
}

/// 获取当前选中 profile 的图形 API（MC 26.2+，如未设置则回退到全局偏好，再回退到 default）
- (NSString *)currentGraphicsApiForSelectedProfile {
    if (!self.selectedProfile) return @"default";
    NSDictionary *profile = PLProfiles.current.profiles[self.selectedProfile];
    NSString *g = profile[@"graphicsApi"];
    if (g.length == 0) {
        g = getPrefObject(@"video.graphics_api");
    }
    return g.length > 0 ? g : @"default";
}

#pragma mark - Setup

- (void)setupCollectionView {
    UICollectionViewLayout *layout = [self createLayout];
    self.collectionView = [[UICollectionView alloc] initWithFrame:self.view.bounds collectionViewLayout:layout];
    self.collectionView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.collectionView.backgroundColor = [UIColor clearColor];
    self.collectionView.dataSource = self;
    self.collectionView.delegate = self;
    self.collectionView.alwaysBounceVertical = YES;
    self.collectionView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    // 规范 4.1：顶部 inset 需为 FAB 留出空间（FAB 44pt + 顶部 8pt + 间距 8pt = 60pt）
    // 避免第一个 section header 的 count badge 被 FAB 遮挡
    CGFloat topInset;
    if (self.navigationController && self.navigationController.navigationBarHidden) {
        // 导航栏隐藏：FAB 位于 safeAreaTop + 8，高度 44
        topInset = self.view.safeAreaInsets.top + 8 + 44 + 8;
    } else {
        // 导航栏可见：FAB 位于 navBar 底部 + 8，高度 44
        CGFloat navBarHeight = 44.0;
        if (self.navigationController && self.navigationController.navigationBar.bounds.size.height > 0) {
            navBarHeight = self.navigationController.navigationBar.bounds.size.height;
        }
        topInset = navBarHeight + 8 + 44 + 8;
    }
    self.collectionView.contentInset = UIEdgeInsetsMake(topInset, 0, 24, 0);
    self.collectionView.scrollIndicatorInsets = UIEdgeInsetsMake(topInset, 0, 24, 0);

    [self.collectionView registerClass:[VMGameDirCell class] forCellWithReuseIdentifier:@"GameDirCell"];
    [self.collectionView registerClass:[VMVersionCardCell class] forCellWithReuseIdentifier:@"VersionCell"];
    [self.collectionView registerClass:[VMSectionHeaderView class] forSupplementaryViewOfKind:UICollectionElementKindSectionHeader withReuseIdentifier:@"HeaderView"];

    [self.view addSubview:self.collectionView];
}

- (UICollectionViewLayout *)createLayout {
    return [[UICollectionViewCompositionalLayout alloc] initWithSectionProvider:^NSCollectionLayoutSection * _Nullable(NSInteger sectionIndex, id<NSCollectionLayoutEnvironment> _Nonnull layoutEnvironment) {
        CGFloat width = layoutEnvironment.container.contentSize.width;
        BOOL isiPad = width > 700;

        // 规范 4.1：Header 估计高度 48pt
        NSCollectionLayoutSize *headerSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                              heightDimension:[NSCollectionLayoutDimension estimatedDimension:48]];
        NSCollectionLayoutBoundarySupplementaryItem *header = [NSCollectionLayoutBoundarySupplementaryItem boundarySupplementaryItemWithLayoutSize:headerSize elementKind:UICollectionElementKindSectionHeader alignment:NSRectAlignmentTop];
        header.contentInsets = NSDirectionalEdgeInsetsMake(0, 0, 0, 0);

        if (sectionIndex == kSectionGameDir) {
            // 游戏目录区段：横向滚动卡片列表
            // Task212：目录卡与实例卡"完全相同"——卡宽 = 同屏实例卡的整卡宽
            //（iPad 四分之 / iPhone 二分之一屏宽，扣除与版本区段相同的 16pt
            // 边距 + 8pt 列间距），卡高 = kVMVersionRowHeight（128pt），上下
            // 内缩 4pt、左右 8pt 与版本区段逐项一致（旧 160/180×70pt 矮卡退役）。
            // 横向滚动语义保留：目录多时左右滑，不挤压版面。
            CGFloat itemWidth = isiPad ? ((width - 32 - 3 * 8) / 4.0) : ((width - 32 - 8) / 2.0);
            CGFloat itemHeight = kVMVersionRowHeight;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            // 规范 4.1：卡片间距 8pt（上下各 4pt），左右 8pt（与版本区段一致）
            item.contentInsets = NSDirectionalEdgeInsetsMake(4, 8, 4, 8);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension absoluteDimension:itemWidth]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            section.orthogonalScrollingBehavior = UICollectionLayoutSectionOrthogonalScrollingBehaviorContinuous;
            // 规范 4.1：边距 16pt，section 间距 8pt
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 8, 16);
            section.boundarySupplementaryItems = @[header];
            return section;
        } else {
            // 版本卡片区段：快捷指令样式网格（Task207 用户创新定稿）
            // 列数在旧版基础上翻倍（旧：iPhone 单列 / iPad 双列 → 新：2 / 4）——
            // "原来一张卡的位置显示两张卡"；横向组按剩余宽度自动重复子项，
            // 0.5/0.25 分数宽即每行 2/4 张。
            CGFloat itemWidth = isiPad ? 0.25 : 0.5;
            // Task212：行高定稿 128pt（Task210 的 104pt 复检仍矮一圈，再抬一档）
            CGFloat itemHeight = kVMVersionRowHeight;
            NSCollectionLayoutSize *itemSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:itemWidth]
                                                                                       heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutItem *item = [NSCollectionLayoutItem itemWithLayoutSize:itemSize];
            // 规范 4.1：卡片间距 8pt（上下各 4pt），左右 8pt
            item.contentInsets = NSDirectionalEdgeInsetsMake(4, 8, 4, 8);

            NSCollectionLayoutSize *groupSize = [NSCollectionLayoutSize sizeWithWidthDimension:[NSCollectionLayoutDimension fractionalWidthDimension:1.0]
                                                                                          heightDimension:[NSCollectionLayoutDimension absoluteDimension:itemHeight]];
            NSCollectionLayoutGroup *group = [NSCollectionLayoutGroup horizontalGroupWithLayoutSize:groupSize subitems:@[item]];

            NSCollectionLayoutSection *section = [NSCollectionLayoutSection sectionWithGroup:group];
            // 规范 4.1：列间距 8pt（iPad 双列时）
            section.interGroupSpacing = isiPad ? 8 : 0;
            // 规范 4.1：边距 16pt，底部 24pt（留出底部呼吸空间）
            section.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 24, 16);
            section.boundarySupplementaryItems = @[header];
            return section;
        }
    }];
}

#pragma mark - Data

- (void)loadProfiles {
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableArray *list = [NSMutableArray array];
    for (NSString *key in profiles.allKeys) {
        [list addObject:key];
    }
    self.profileList = [list sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        return [obj2 compare:obj1];
    }];
    self.selectedProfile = PLProfiles.current.selectedProfileName;
}

/// 加载游戏目录（实例）列表
- (void)loadGameDirList {
    NSMutableArray *list = [NSMutableArray array];
    [list addObject:@"default"];

    NSString *instancesPath = [NSString stringWithFormat:@"%s/instances", getenv("POJAV_HOME")];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:instancesPath error:nil];
    BOOL isDir = NO;
    for (NSString *file in files) {
        NSString *fullPath = [instancesPath stringByAppendingPathComponent:file];
        if ([fm fileExistsAtPath:fullPath isDirectory:&isDir] && isDir && ![file isEqualToString:@"default"]) {
            [list addObject:file];
        }
    }
    self.gameDirList = list;
    id raw = getPrefObject(@"general.game_directory");
    self.currentGameDir = [raw isKindOfClass:[NSString class]] ? raw : @"default";
}

#pragma mark - UICollectionViewDataSource

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)collectionView {
    return 2;
}

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    if (section == kSectionGameDir) {
        return self.gameDirList.count + 1;  // 末尾追加"新建目录"按钮
    } else {
        return self.profileList.count;
    }
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == kSectionGameDir) {
        VMGameDirCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"GameDirCell" forIndexPath:indexPath];

        if (indexPath.item == (NSInteger)self.gameDirList.count) {
            [cell configureWithName:nil detail:nil isSelected:NO isAddButton:YES];
            return cell;
        }

        NSString *dirName = self.gameDirList[indexPath.item];
        BOOL isSelected = [dirName isEqualToString:self.currentGameDir];

        // Task213 hotfix：weakSelf 在本分支只声明一次（异步大小块与叉号回调
        // 共用）——CI 实锤双声明 redefinition（本地静态门无 clang 未拦）。
        __weak typeof(self) weakSelf = self;

        // 异步计算目录大小（Task212：小字 = 目录大小本体，旧 i18n_str_134
        // 占位文案退役——初始为空，算完即填）
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            unsigned long long folderSize = 0;
            NSString *directory = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), dirName];
            [weakSelf calculateFolderSizeAtPath:directory size:&folderSize];
            NSString *sizeStr = [NSByteCountFormatter stringFromByteCount:folderSize countStyle:NSByteCountFormatterCountStyleMemory];
            dispatch_async(dispatch_get_main_queue(), ^{
                VMGameDirCell *targetCell = (VMGameDirCell *)[collectionView cellForItemAtIndexPath:indexPath];
                if (targetCell && [targetCell isKindOfClass:[VMGameDirCell class]]) {
                    targetCell.detailLabel.text = sizeStr;
                }
            });
        });

        [cell configureWithName:dirName detail:nil isSelected:isSelected isAddButton:NO];
        // Task212：叉号钮 = 删除入口（点击直接呼出确认删除弹窗；默认目录/
        // 当前目录在回调内先行拦截并说明，不走旧长按菜单）
        cell.deleteAction = ^{
            [weakSelf handleGameDirDeleteTapped:dirName];
        };
        return cell;
    } else {
        VMVersionCardCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"VersionCell" forIndexPath:indexPath];

        NSString *profileName = self.profileList[indexPath.item];
        NSDictionary *profile = PLProfiles.current.profiles[profileName];
        NSString *versionId = profile[@"lastVersionId"] ?: localize(@"i18n_str_1052", nil);
        BOOL isSelected = [profileName isEqualToString:self.selectedProfile];

        [cell configureWithName:profileName version:versionId isSelected:isSelected];
        // Task207：⋯ 钮 = 纯编辑（不改选中；点卡片本体才选用）
        __weak typeof(self) weakSelf = self;
        cell.ellipsisAction = ^{
            [weakSelf editProfile:profileName];
        };
        return cell;
    }
}

/// 简易目录大小计算（递归）
- (void)calculateFolderSizeAtPath:(NSString *)path size:(unsigned long long *)size {
    [VersionManagerViewController ame256_calculateFolderSizeAtPath:path size:size];
}

+ (void)ame256_calculateFolderSizeAtPath:(NSString *)path size:(unsigned long long *)size {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:path];
    NSString *relativePath;
    while ((relativePath = [enumerator nextObject])) {
        NSString *fullPath = [path stringByAppendingPathComponent:relativePath];
        NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
        if (attrs) {
            *size += [attrs fileSize];
        }
    }
}

/// 将 lastPlayed 时间戳格式化为"最后游玩：xxx"
- (NSString *)formatLastPlayed:(id)lastPlayedRaw {
    if (!lastPlayedRaw) return @"";
    NSTimeInterval ts;
    if ([lastPlayedRaw isKindOfClass:[NSNumber class]]) {
        ts = [lastPlayedRaw doubleValue];
    } else if ([lastPlayedRaw isKindOfClass:[NSString class]]) {
        ts = [(NSString *)lastPlayedRaw doubleValue];
    } else {
        return @"";
    }
    if (ts <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale currentLocale];
    fmt.doesRelativeDateFormatting = YES;
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    return [NSString stringWithFormat:localize(@"i18n_str_1069", nil), [fmt stringFromDate:date]];
}

- (UICollectionReusableView *)collectionView:(UICollectionView *)collectionView viewForSupplementaryElementOfKind:(NSString *)kind atIndexPath:(NSIndexPath *)indexPath {
    if (kind == UICollectionElementKindSectionHeader) {
        VMSectionHeaderView *header = [collectionView dequeueReusableSupplementaryViewOfKind:kind withReuseIdentifier:@"HeaderView" forIndexPath:indexPath];
        switch (indexPath.section) {
            case kSectionGameDir:
                [header configureWithIcon:@"folder.badge.gearshape"
                                     title:localize(@"i18n_str_1070", nil)
                                  subtitle:localize(@"i18n_str_1071", nil)
                                     count:(NSInteger)self.gameDirList.count];
                break;
            case kSectionVersions:
                [header configureWithIcon:@"cube.box.fill"
                                     title:localize(@"i18n_str_1072", nil)
                                  subtitle:localize(@"i18n_str_1073", nil)
                                     count:(NSInteger)self.profileList.count];
                break;
            default:
                [header configureWithIcon:@""
                                     title:@""
                                  subtitle:@""
                                     count:-1];
                break;
        }
        return header;
    }
    return [UICollectionReusableView new];
}

#pragma mark - UICollectionViewDelegate

- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    [collectionView deselectItemAtIndexPath:indexPath animated:YES];

    if (indexPath.section == kSectionGameDir) {
        if (indexPath.item == (NSInteger)self.gameDirList.count) {
            [self showCreateGameDirAlert];
        } else {
            NSString *dirName = self.gameDirList[indexPath.item];
            if (![dirName isEqualToString:self.currentGameDir]) {
                [self switchGameDirTo:dirName];
            }
        }
    } else if (indexPath.section == kSectionVersions) {
        // Task207：点卡片 = 选用该实例（快捷指令"点击即运行"语义）；
        // Task212：编辑 = 卡片右上 ⋯ 钮；长按 = 直接呼出确认删除弹窗
        //（旧长按"选择/编辑/删除"三件套菜单退役）。
        NSString *profileName = self.profileList[indexPath.item];
        [self selectProfileNamed:profileName];
    }
}

#pragma mark - Game Directory Actions

/// 切换游戏目录（实例），重建符号链接
- (void)switchGameDirTo:(NSString *)name {
    if (getenv("DEMO_LOCK")) return;

    setPrefObject(@"general.game_directory", name);
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSString *lasmPath = @(getenv("POJAV_GAME_DIR"));
    NSError *removeError = nil;
    [NSFileManager.defaultManager removeItemAtPath:lasmPath error:&removeError];

    NSError *linkError = nil;
    BOOL linkOK = [NSFileManager.defaultManager createSymbolicLinkAtPath:lasmPath
                                                       withDestinationPath:multidirPath
                                                                     error:&linkError];
    if (!linkOK) {
        NSLog(@"[VersionMgr] createSymbolicLink failed: %@", linkError.localizedDescription);
        [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1074", nil), linkError.localizedDescription]];
        return;
    }
    [NSFileManager.defaultManager changeCurrentDirectoryPath:lasmPath];
    toggleIsolatedPref(NO);
    [PLProfiles updateCurrent];

    [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];

    [self loadGameDirList];
    [self loadProfiles];
    [self.collectionView reloadData];
    [self updateEmptyState];
}

/// 弹出新建游戏目录对话框
- (void)showCreateGameDirAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_1075", nil)
                                                                   message:localize(@"i18n_str_1076", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = localize(@"i18n_str_1077", nil);
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.delegate = self;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_1078", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *name = alert.textFields.firstObject.text;
        if (name.length == 0) return;
        [self createGameDirWithName:name];
    }]];

    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        alert.popoverPresentationController.sourceView = self.view;
        alert.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width / 2, self.view.bounds.size.height / 2, 1, 1);
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)createGameDirWithName:(NSString *)name {
    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), name];
    NSError *error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1079", nil), error.localizedDescription]];
        return;
    }
    [self switchGameDirTo:name];
}

/// Task212：目录卡叉号点击 → 直接呼出确认删除弹窗（旧长按操作菜单整体
/// 退役：切换 = 点卡片本体，删除 = 叉号钮，无需中间层菜单）。默认目录
/// 与正在使用的目录不可删，点击时即时说明（不先弹确认再拒）。
- (void)handleGameDirDeleteTapped:(NSString *)dirName {
    if ([dirName isEqualToString:@"default"]) {
        [self showAlert:localize(@"i18n_str_1087", nil)];
        return;
    }
    if ([dirName isEqualToString:self.currentGameDir]) {
        [self showAlert:localize(@"i18n_str_1084", nil)];
        return;
    }
    [self confirmDeleteGameDir:dirName];
}

/// 二次确认删除游戏目录
- (void)confirmDeleteGameDir:(NSString *)dirName {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_1085", nil)
                                                                     message:[NSString stringWithFormat:localize(@"i18n_str_1086", nil), dirName]
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_457", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        [self deleteGameDir:dirName];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}

/// 删除指定游戏目录
- (void)deleteGameDir:(NSString *)dirName {
    if ([dirName isEqualToString:@"default"]) {
        [self showAlert:localize(@"i18n_str_1087", nil)];
        return;
    }
    if ([dirName isEqualToString:self.currentGameDir]) {
        [self showAlert:localize(@"i18n_str_1084", nil)];
        return;
    }

    NSString *dest = [NSString stringWithFormat:@"%s/instances/%@", getenv("POJAV_HOME"), dirName];
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtPath:dest error:&error]) {
        [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1088", nil), error.localizedDescription]];
        return;
    }

    [self loadGameDirList];
    [self.collectionView reloadData];
    [self updateEmptyState];
    [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1089", nil), dirName]];
}

#pragma mark - Renderer Selection (启动器 native 库选择)

/// 选择渲染器并保存到当前 profile
- (void)selectRendererAtIndex:(NSInteger)index {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    if (index >= (NSInteger)self.rendererKeys.count) return;

    NSString *key = self.rendererKeys[index];
    NSString *displayName = index < (NSInteger)self.rendererNames.count ? self.rendererNames[index] : key;

    // 写入当前 profile 的 renderer 字段
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[self.selectedProfile] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"renderer"] = key;
    profiles[self.selectedProfile] = profile;
    [PLProfiles.current save];

    // 同步到全局偏好（保证启动游戏时 LauncherRightPanelViewController 能读到）
    setPrefString(@"video.renderer", key);

    [self.collectionView reloadData];

    NSLog(@"[VersionMgr] Renderer for profile '%@' set to '%@' (%@)", self.selectedProfile, key, displayName);
}

#pragma mark - Graphics API Selection (MC 26.2+ 游戏内 OpenGL/Vulkan)

/// 选择图形 API 并保存到当前 profile
/// 注意：graphicsApi 与 renderer 是两个不同维度：
///   - renderer：LWJGL 加载哪个 native 库（libgl4es/libMoltenVK 等）
///   - graphicsApi：MC 26.2+ 内部走 OpenGL 路径还是 Vulkan 路径
/// 当用户选择 prefer_vulkan 时建议同步将 renderer 设为 libMoltenVK.dylib，
/// 但此处不强制联动，允许高级用户分开配置。
- (void)selectGraphicsApiAtIndex:(NSInteger)index {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    if (index >= (NSInteger)self.graphicsApiKeys.count) return;

    NSString *key = self.graphicsApiKeys[index];
    NSString *displayName = index < (NSInteger)self.graphicsApiNames.count ? self.graphicsApiNames[index] : key;

    // 写入当前 profile 的 graphicsApi 字段
    NSMutableDictionary *profiles = PLProfiles.current.profiles;
    NSMutableDictionary *profile = [profiles[self.selectedProfile] mutableCopy];
    if (!profile) {
        profile = [NSMutableDictionary dictionary];
    }
    profile[@"graphicsApi"] = key;
    profiles[self.selectedProfile] = profile;
    [PLProfiles.current save];

    // 同步到全局偏好
    setPrefString(@"video.graphics_api", key);

    [self.collectionView reloadData];

    NSLog(@"[VersionMgr] Graphics API for profile '%@' set to '%@' (%@)", self.selectedProfile, key, displayName);
}

#pragma mark - Quick Actions

- (void)openModsManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    ModsManagerViewController *vc = [[ModsManagerViewController alloc] init];
    // Task267：语义入口（管理此版本的模组）= 钉定该实例，选中实例变化不跟走
    [vc ame267_pinToProfile:self.selectedProfile];
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openShadersManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    ShadersManagerViewController *vc = [[ShadersManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ShadersManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openResourcePacksManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    ResourcePacksManagerViewController *vc = [[ResourcePacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = ResourcePacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openDataPacksManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    DataPacksManagerViewController *vc = [[DataPacksManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = DataPacksManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

- (void)openWorldsManager {
    if (!self.selectedProfile) {
        [self showAlert:localize(@"i18n_str_431", nil)];
        return;
    }
    WorldsManagerViewController *vc = [[WorldsManagerViewController alloc] init];
    vc.profileName = self.selectedProfile;
    vc.initialMode = WorldsManagerModeLocal;
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - Profile Actions

// Task212：showProfileActions（实例卡长按"选择/编辑/删除"操作菜单）整体
// 退役——长按 = 直接呼出确认删除弹窗（handleLongPress → deleteProfile），
// 选择 = 点卡片本体（selectProfileNamed），编辑 = 卡片右上 ⋯ 钮
//（editProfile）；三个动作各有直达入口，中间层菜单纯属冗余。

- (void)editProfile:(NSString *)profileName {
    // Task207：纯编辑——⋯ 钮/长按菜单进入编辑页不再顺带把该实例设为当前选中
    //（快捷指令"⋯ 只编辑不运行"语义；选中只由点卡片本体触发）。
    // 旧逻辑的"实例渲染器不生效"补偿随之退役：那是"点卡即编辑且隐式选中"时代
    // 的一致性补丁；新交互下选中态与编辑入口解耦，不存在再错位的问题。
    ProfileSettingsViewController *vc = [[ProfileSettingsViewController alloc] init];
    vc.profileName = profileName;
    [self.navigationController pushViewController:vc animated:YES];
}

/// Task207：选用实例（点卡片本体触发；动作等同旧长按菜单"选用"）。
/// 已是当前实例时静默跳过（同游戏目录切换的防抖语义）。
- (void)selectProfileNamed:(NSString *)profileName {
    if ([profileName isEqualToString:self.selectedProfile]) return;
    PLProfiles.current.selectedProfileName = profileName;
    [PLProfiles.current save];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SelectedProfileChanged" object:nil];
    [self loadProfiles];
    [self.collectionView reloadData];
}

- (void)deleteProfile:(NSString *)profileName {
    if (self.profileList.count <= 1) {
        [self showAlert:localize(@"i18n_str_1092", nil)];
        return;
    }

    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_457", nil)
                                                                     message:[NSString stringWithFormat:localize(@"i18n_str_1093", nil), profileName]
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_306", nil) style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        // ★ Task255（删除版本后数据大小未变化/版本仍存在 根修）：旧实现只
        //   删 PLProfiles 注册表条目，从不碰 versions/<id> 实体——游戏
        //   jar/json/隔离 game 目录全部留在盘上 = 数据大小不变 + 版本仍
        //   在（扫描/下载页仍能看见）。修复：删除注册表条目后，若同一
        //   lastVersionId 不再被任何其他实例引用 → 连带删除
        //   versions/<id> 实体目录（含 Task242 隔离的 versions/<id>/game）。
        NSDictionary *ame255_profile = PLProfiles.current.profiles[profileName];
        NSString *ame255_versionId = [ame255_profile isKindOfClass:NSDictionary.class]
            ? ame255_profile[@"lastVersionId"] : nil;
        [PLProfiles.current.profiles removeObjectForKey:profileName];
        if ([PLProfiles.current.selectedProfileName isEqualToString:profileName]) {
            PLProfiles.current.selectedProfileName = PLProfiles.current.profiles.allKeys.firstObject;
        }
        [PLProfiles.current save];
        // ★ Task255：实体目录连带删除（引用计数守卫：仍被其他实例引用
        //   的版本只退出注册表，文件保留）。
        if ([ame255_versionId isKindOfClass:[NSString class]] && ame255_versionId.length > 0) {
            BOOL ame255_stillReferenced = NO;
            for (NSString *ame255_key in PLProfiles.current.profiles) {
                NSDictionary *ame255_p = PLProfiles.current.profiles[ame255_key];
                if ([ame255_p isKindOfClass:NSDictionary.class] &&
                    [ame255_p[@"lastVersionId"] isKindOfClass:[NSString class]] &&
                    [ame255_p[@"lastVersionId"] isEqualToString:ame255_versionId]) {
                    ame255_stillReferenced = YES;
                    break;
                }
            }
            if (!ame255_stillReferenced) {
                // ★ Task255 r2 路径根修正：版本实体在 POJAV_GAME_DIR/versions
                //   （= instances/<当前实例>/versions；注册表 launcher_profiles.json
                //   亦在 GAME_DIR，PLProfiles.m:98 同源）。POJAV_HOME/versions 仅
                //   旧版布局存在，作降序兜底。装机 latestlog 实锤 instances/default。
                NSString *ame255_vdir = [NSString stringWithFormat:@"%s/versions/%@",
                    getenv("POJAV_GAME_DIR") ? getenv("POJAV_GAME_DIR") : getenv("POJAV_HOME"), ame255_versionId];
                if (![NSFileManager.defaultManager fileExistsAtPath:ame255_vdir]) {
                    const char *ame255_home = getenv("POJAV_HOME");
                    if (ame255_home != NULL) {
                        NSString *ame255_legacy = [NSString stringWithFormat:@"%s/versions/%@",
                            ame255_home, ame255_versionId];
                        if ([NSFileManager.defaultManager fileExistsAtPath:ame255_legacy]) ame255_vdir = ame255_legacy;
                    }
                }
                if ([NSFileManager.defaultManager fileExistsAtPath:ame255_vdir]) {
                    NSError *ame255_err = nil;
                    if ([NSFileManager.defaultManager removeItemAtPath:ame255_vdir error:&ame255_err]) {
                        NSLog(@"[VersionMgr] Task255: removed version folder for deleted profile '%@' -> %@", profileName, ame255_vdir);
                    } else {
                        NSLog(@"[VersionMgr] Task255: failed to remove version folder %@: %@", ame255_vdir, ame255_err.localizedDescription);
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [self showAlert:[NSString stringWithFormat:localize(@"i18n_str_1088", nil), ame255_err.localizedDescription]];
                        });
                    }
                }
            } else {
                NSLog(@"[VersionMgr] Task255: version %@ still referenced by other profile(s), folder kept", ame255_versionId);
            }
        }
        [self loadProfiles];
        [self.collectionView reloadData];
        [self updateEmptyState];
        // ★ Task255：主页 localVersionList 全局快照同步刷新（删除后主页“选择版本”
        //   不再残留已删版本；对齐下载完成同款通知链，行 1641 先例）。
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ReloadProfileList" object:nil];
    }]];

    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)showAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_388", nil) message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Task255: 版本扫描 / 恢复 / 清理入口

/// 扫描 versions/ 目录全部本机版本。返回字典数组：
///   id(NSString) / path(NSString) / jsonOK(BOOL：存在 <id>/<id>.json 正式
///   版本定义) / referenced(BOOL：任一实例的 lastVersionId 引用) /
///   sizeBytes(NSNumber：目录递归大小)。
- (NSArray<NSDictionary *> *)ame255_scanInstalledVersions {
    /* ★ Task256（清单 3）：扫描逻辑下沉到类方法 ame256_scanVersionsForCleanup
       ——主页“清理垃圾”磁贴无实例也能复用同一实现（版本管理页入口与主页
       磁贴入口永不漂移）。本实例方法保留为薄壳，原有调用点零改动。 */
    return [VersionManagerViewController ame256_scanVersionsForCleanup];
}

/// ★ Task256（清单 3）：扫描 GAME_DIR/versions 全量版本（含引用状态与体积），
///   供清理中心/恢复对话框/主页磁贴共用。无实例依赖。
+ (NSArray<NSDictionary *> *)ame256_scanVersionsForCleanup {
    // ★ Task255 r2 路径根修正：扫描 GAME_DIR/versions（真机实体；同 deleteProfile 处注释）。
    NSString *versionsDir = [NSString stringWithFormat:@"%s/versions",
        getenv("POJAV_GAME_DIR") ? getenv("POJAV_GAME_DIR") : getenv("POJAV_HOME")];
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    NSArray<NSString *> *entries = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:versionsDir error:nil];
    if (entries.count == 0) return result;
    NSMutableSet<NSString *> *referenced = [NSMutableSet set];
    for (NSString *key in PLProfiles.current.profiles) {
        NSDictionary *p = PLProfiles.current.profiles[key];
        if ([p isKindOfClass:NSDictionary.class] &&
            [p[@"lastVersionId"] isKindOfClass:[NSString class]]) {
            [referenced addObject:p[@"lastVersionId"]];
        }
    }
    for (NSString *entry in entries) {
        NSString *vdir = [versionsDir stringByAppendingPathComponent:entry];
        BOOL isDir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:vdir isDirectory:&isDir] || !isDir) continue;
        NSString *jsonPath = [vdir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@.json", entry]];
        BOOL jsonOK = [NSFileManager.defaultManager fileExistsAtPath:jsonPath];
        unsigned long long folderSize = 0;
        [VersionManagerViewController ame256_calculateFolderSizeAtPath:vdir size:&folderSize];
        [result addObject:@{
            @"id": entry,
            @"path": vdir,
            @"jsonOK": @(jsonOK),
            @"referenced": @([referenced containsObject:entry]),
            @"sizeBytes": @(folderSize),
        }];
    }
    [result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"id"] compare:b[@"id"]];
    }];
    return result;
}

/// 扫描 FAB 动作：恢复版本 / 清理垃圾 双入口。
- (void)ame255_showScanActionSheet {
    UIAlertController *sheet = [UIAlertController
        alertControllerWithTitle:localize(@"vm.scan.title", @"扫描版本")
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"vm.scan.restore", @"扫描并恢复版本")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [self ame255_showRestoreDialog];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"vm.scan.cleanup", @"清理垃圾")
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [self ame255_showCleanup];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(self.view.bounds.size.width - 70, 60, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

/// T5：无引用版本恢复对话框——versions/ 里存在、但没有任何实例引用的
/// 版本，逐个可一键重建实例（Task242 模板：gameDir = versions/<id>/game）。
- (void)ame255_showRestoreDialog {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSDictionary *> *all = [self ame255_scanInstalledVersions];
        NSMutableArray<NSDictionary *> *orphans = [NSMutableArray array];
        for (NSDictionary *v in all) {
            if ([v[@"jsonOK"] boolValue] && ![v[@"referenced"] boolValue]) {
                [orphans addObject:v];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (orphans.count == 0) {
                [self showAlert:localize(@"vm.scan.no_orphan", @"未发现可恢复的版本：目录中的版本均已被实例引用。")];
                return;
            }
            UIAlertController *alert = [UIAlertController
                alertControllerWithTitle:localize(@"vm.scan.title", @"扫描版本")
                                 message:[NSString stringWithFormat:
                                     localize(@"vm.scan.orphan_msg", @"发现 %lu 个未被实例引用的版本，选择要恢复的："),
                                     (unsigned long)orphans.count]
                          preferredStyle:UIAlertControllerStyleAlert];
            NSUInteger ame255_limit = MIN(orphans.count, (NSUInteger)8);
            for (NSUInteger i = 0; i < ame255_limit; i++) {
                NSDictionary *v = orphans[i];
                NSString *vid = v[@"id"];
                [alert addAction:[UIAlertAction actionWithTitle:vid
                                                          style:UIAlertActionStyleDefault
                                                        handler:^(__unused UIAlertAction *a) {
                    NSMutableDictionary *profile = [NSMutableDictionary dictionary];
                    profile[@"name"] = vid;
                    profile[@"lastVersionId"] = vid;
                    // Task242 口径：新实例自动版本隔离（与下载完成创建一致）
                    profile[@"gameDir"] = [NSString stringWithFormat:@"versions/%@/game", vid];
                    profile[@"type"] = @"custom";
                    profile[@"created"] = [NSDate date].description;
                    [PLProfiles.current saveProfile:profile withName:vid];
                    NSLog(@"[VersionMgr] Task255: restored orphan version '%@' as a new profile", vid);
                    [self loadProfiles];
                    [self.collectionView reloadData];
                    [self updateEmptyState];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                                      style:UIAlertActionStyleCancel handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    });
}

/// T6：清理中心呈现。
- (void)ame255_showCleanup {
    CleanupViewController *cleanup = [[CleanupViewController alloc] init];
    cleanup.ame255_versionScanner = ^NSArray<NSDictionary *> *(void) {
        return [self ame255_scanInstalledVersions];
    };
    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:cleanup];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

#pragma mark - Orientation

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    if ([ScreenUtils isPad]) {
        return UIInterfaceOrientationMaskAll;
    }
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

@end
