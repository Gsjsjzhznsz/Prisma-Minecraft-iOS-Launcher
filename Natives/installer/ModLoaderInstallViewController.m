#import "utils.h"
//
//  ModLoaderInstallViewController.m
//  Amethyst
//
//  参照 FCL (FoldCraftLauncher) page_installer.xml + view_installer_item.xml 重构。
//  - 顶部紧凑 toolbar：版本名输入框 + 右上角下载图标按钮（替代原底部 72pt 大按钮）
//
//  Task184 重写（用户三轮口径"重写，按照上一级也就是版本号选择界面写"）：
//  三个 cell 类与 VersionCardCell（下载页版本号选择列表，用户认可形态）
//  完全同构——外层 cell 全透明（含杀掉系统 inset-grouped 白底 = "钉死的
//  底层白框"根修），视觉由内层 cardContainer（圆角 12 continuous、上下
//  4pt 内缩）承载，凸起管线 applyCardEffectToView 在 init 挂一次
//  （兼顾新拟态开关）；图标 40x40 圆角 10 品牌色淡底容器，名称 16
//  semibold / 状态 12 规格文字色，右侧 chevron 14pt，全部 = 版本卡规格。
//  - 加载器列表每行一独立 section（Task136 保留，行高 64 = 版本卡同款）
//  - 每行：左 40x40 图标容器 + 中间名称/状态双行 + 右侧 chevron/选中徽章
//  - 附加选项（Fabric API / OptiFine 共存）作为独立 section 的开关行（同配方）
//  - 版本选择子页面条目同样换卡式配方
//  - 互斥逻辑与 FCL 完全一致
//

#import "ModLoaderInstallViewController.h"
#import "NeoForgeVersionFetcher.h"
#import "LauncherPreferences.h"
#import "BackgroundManager.h"
#import "../UIKit+NativeSurface.h" // Task210：卡面文字色符号（AmeCardPrimary/SecondaryTextColor，原新拟态色族改名保留）
#import "ModLoaderIconHelper.h"
#import "ScreenUtils.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Data Models

/// 加载器元数据
@interface ModLoaderRow : NSObject
@property (nonatomic, copy) NSString *identifier;   // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *name;         // 显示名
@property (nonatomic, copy) NSString *desc;         // 描述
@property (nonatomic, copy) NSString *iconName;     // SF Symbol 名（PNG 缺失时回退用）
@property (nonatomic, strong) UIColor *iconColor;   // 图标主色
@property (nonatomic, assign) BOOL compatible;      // 与当前游戏版本是否兼容
@property (nonatomic, copy, nullable) NSString *selectedVersion; // 选中版本（nil 表示未选）
@end
@implementation ModLoaderRow
@end

#pragma mark - Loader Row Cell（Task184 重写：与 VersionCardCell 完全同构）

// Task184：干掉 InsetGrouped 的系统 cell 镀层——iOS 会为 grouped/inset-grouped
// 表格的 cell 自动装一个 secondarySystemGroupedBackground 白色背景视图（以及
// 灰色选中高亮）；凸起管线挂在"内层卡片容器"上时，那层白底垫在卡片外面就是
// 用户实测的"钉死的底层白框 + 白框里一条边的假新拟态"。换装空透明
// 背景/选中视图（空 UIView 默认 clear 底），init 与 prepareForReuse 双点
// 重放（幂等，防系统在复用时重新装底）。
static void AME184ClearTableViewCellChrome(UITableViewCell *cell) {
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
    cell.layer.masksToBounds = NO;
    UIView *clearBg = [[UIView alloc] init];
    clearBg.backgroundColor = [UIColor clearColor];
    clearBg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cell.backgroundView = clearBg;
    UIView *clearSel = [[UIView alloc] init];
    clearSel.backgroundColor = [UIColor clearColor];
    clearSel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cell.selectedBackgroundView = clearSel;
}

// 与 VersionCardCell（Natives/VersionCardCell.m，用户认可的版本号选择界面）
// 同构的构造范式：外层 cell 全透明（含杀掉系统 inset-grouped 白底）→ 内层
// cardContainer（圆角 12 continuous、上下 4pt 内缩）承载视觉 → 凸起管线
// applyCardEffectToView 在 init 挂一次（开关开 = Task177 渐变卡面 +
// 双阴影规格，关 = 旧毛玻璃/平贴管线，由 BackgroundManager 内部裁定；出列
// 不再重铺——引擎 layoutSubviews 按 bounds 自刷，VersionCardCell 同款单次
// 挂载范式）。
@interface ModLoaderRowCell : UITableViewCell
@property (nonatomic, strong) UIView *cardContainer;   // 整张卡片的视觉宿主
@property (nonatomic, strong) UIView *iconContainer;   // 左侧 40x40 圆角方块图标容器
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UIImageView *chevronView;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation ModLoaderRowCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self ame183_setupViews];
    }
    return self;
}

- (void)ame183_setupViews {
    AME184ClearTableViewCellChrome(self);
    self.selectionStyle = UITableViewCellSelectionStyleDefault;

    // ----- 卡片容器（VersionCardCell 同规格：圆角 12 continuous、上下内缩 4pt）-----
    _cardContainer = [[UIView alloc] init];
    _cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _cardContainer.layer.cornerRadius = 12;
    _cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self.contentView addSubview:_cardContainer];
    [[BackgroundManager sharedManager] applyCardEffectToView:_cardContainer];

    // ----- 左侧图标容器：40x40 圆角 10 淡底方块 + 居中图标（Task216：
    // 用户六轮重写仍"与游戏版本列表不一样"的收口——Task212 曾把本表压到
    // 50pt/32 图标并声称"版本选择表 50pt"，但 VersionCardCell 实际行高 64、
    // 图标容器 40x40/圆角 10/左缘 14，本轮逐项对齐真基准）-----
    // 图标内容由 ModLoaderIconHelper.configureImageView 配置（PNG 保原色 /
    // SF Symbol 着品牌色），容器底色 = 品牌色 0.15 淡底（与该助手的
    // createIconBadgeForLoader 徽章规格同源）。
    _iconContainer = [[UIView alloc] init];
    _iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _iconContainer.layer.cornerRadius = 10;
    _iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
    _iconContainer.layer.masksToBounds = YES;
    _iconContainer.backgroundColor = [UIColor systemGreenColor];
    [_cardContainer addSubview:_iconContainer];

    _iconView = [[UIImageView alloc] init];
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.contentMode = UIViewContentModeScaleAspectFit;
    [_iconContainer addSubview:_iconView];

    // ----- 名称/状态两行（Task212：15 semibold + 11，与版本表 cell 文字规格
    // 同档；顶 8 / 间距 2 在 42pt 卡内垂直居中）-----
    _nameLabel = [[UILabel alloc] init];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _nameLabel.textColor = AmeCardPrimaryTextColor();
    _nameLabel.numberOfLines = 1;
    _nameLabel.adjustsFontSizeToFitWidth = YES;
    _nameLabel.minimumScaleFactor = 0.75;
    _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_cardContainer addSubview:_nameLabel];

    _stateLabel = [[UILabel alloc] init];
    _stateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stateLabel.font = [UIFont systemFontOfSize:11];
    _stateLabel.textColor = AmeCardSecondaryTextColor();
    _stateLabel.numberOfLines = 1;
    _stateLabel.adjustsFontSizeToFitWidth = YES;
    _stateLabel.minimumScaleFactor = 0.7;
    _stateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_cardContainer addSubview:_stateLabel];

    // ----- 右侧 chevron（版本卡规格：14x14 tertiary，提示可点进版本选择）-----
    _chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
    _chevronView.tintColor = [UIColor tertiaryLabelColor];
    _chevronView.contentMode = UIViewContentModeScaleAspectFit;
    [_cardContainer addSubview:_chevronView];

    // ----- 选中徽章：20pt 绿圆 + 白勾（与 chevron 互斥，configure 里切换）-----
    _selectedBadge = [[UIView alloc] init];
    _selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _selectedBadge.backgroundColor = [UIColor systemGreenColor];
    _selectedBadge.layer.cornerRadius = 10;
    _selectedBadge.layer.masksToBounds = YES;
    _selectedBadge.hidden = YES;
    [_cardContainer addSubview:_selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [_selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        // 卡片容器充满 contentView（上下各留 4pt，与版本卡 sectionInset 语义一致）
        [_cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
        [_cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],
        [_cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        // 图标容器：左 14，垂直居中，40x40；图标 22x22 居中（Task216：
        // VersionCardCell 同规格——14/40/10/22 逐项对齐）
        [_iconContainer.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:14],
        [_iconContainer.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_iconContainer.widthAnchor constraintEqualToConstant:40],
        [_iconContainer.heightAnchor constraintEqualToConstant:40],
        [_iconView.centerXAnchor constraintEqualToAnchor:_iconContainer.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconContainer.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:22],
        [_iconView.heightAnchor constraintEqualToConstant:22],

        // 名称：紧跟图标右侧 +14、顶 14（Task216：VersionCardCell 同规格——
        // 旧 12/8 的"图标-文字间距"与"行内上边距"正是用户指出的两处错位）
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_iconContainer.trailingAnchor constant:14],
        [_nameLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:14],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevronView.leadingAnchor constant:-8],

        // 状态行：与名称左对齐，紧跟下方 +3（Task216：VersionCardCell 日期行同距）
        [_stateLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_stateLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:3],
        [_stateLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_chevronView.leadingAnchor constant:-8],

        // chevron：右 -14，垂直居中，14x14
        [_chevronView.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_chevronView.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:14],
        [_chevronView.heightAnchor constraintEqualToConstant:14],

        // 选中徽章：右 -14，垂直居中，20x20
        [_selectedBadge.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_selectedBadge.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_selectedBadge.widthAnchor constraintEqualToConstant:20],
        [_selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:_selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:_selectedBadge.centerYAnchor],
    ]];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // Task184：复用时重放镀层清理（幂等）+ 状态字段复位，其余由 configure 决定
    AME184ClearTableViewCellChrome(self);
    self.iconView.alpha = 1.0;
    self.iconContainer.alpha = 1.0;
    self.selectedBadge.hidden = YES;
    self.chevronView.hidden = NO;
    self.nameLabel.textColor = AmeCardPrimaryTextColor();
    self.stateLabel.textColor = AmeCardSecondaryTextColor();
    self.contentView.userInteractionEnabled = YES;
}

- (void)setIncompatible:(BOOL)incompatible reason:(NSString *)reason {
    if (incompatible) {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = reason ?: localize(@"i18n_str_1199", nil);
        self.stateLabel.textColor = [UIColor systemRedColor];
        self.nameLabel.textColor = [UIColor tertiaryLabelColor];
        self.iconView.alpha = 0.45;
        self.iconContainer.alpha = 0.45;
        self.selectedBadge.hidden = YES;
        self.chevronView.hidden = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.contentView.userInteractionEnabled = NO;
    } else {
        // 恢复分支：版本卡规格文字色
        self.nameLabel.textColor = AmeCardPrimaryTextColor();
        self.stateLabel.textColor = AmeCardSecondaryTextColor();
        self.iconView.alpha = 1.0;
        self.iconContainer.alpha = 1.0;
        self.chevronView.hidden = NO;
        self.selectionStyle = UITableViewCellSelectionStyleDefault;
        self.contentView.userInteractionEnabled = YES;
    }
}

- (void)setSelectedVersionText:(NSString *)text {
    if (text.length > 0) {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = text;
        self.stateLabel.textColor = [UIColor systemGreenColor];
    } else {
        self.stateLabel.hidden = NO;
        self.stateLabel.text = localize(@"i18n_str_1200", nil);
        self.stateLabel.textColor = AmeCardSecondaryTextColor();
    }
}

- (void)clearStatusText {
    self.stateLabel.hidden = NO;
    self.stateLabel.text = localize(@"i18n_str_1201", nil);
    self.stateLabel.textColor = AmeCardSecondaryTextColor();
}

- (void)configureWithRow:(ModLoaderRow *)row
            isSelected:(BOOL)isSelected
      selectedVersionDisplay:(NSString *)versionDisplay
                incompatible:(BOOL)incompatible
                     reason:(NSString *)reason {
    self.nameLabel.text = row.name;

    // 图标：ModLoaderIconHelper 统一配置（PNG 保原色 / SF 着品牌色）
    [ModLoaderIconHelper configureImageView:self.iconView
                                  forLoader:row.identifier
                             traitCollection:self.traitCollection];
    UIColor *ame183Brand = [ModLoaderIconHelper brandColorForLoader:row.identifier];
    self.iconContainer.backgroundColor = [ame183Brand colorWithAlphaComponent:0.15];

    if (incompatible) {
        [self setIncompatible:YES reason:reason];
        return;
    }

    [self setIncompatible:NO reason:nil];

    if (isSelected) {
        if (versionDisplay.length > 0) {
            [self setSelectedVersionText:versionDisplay];
        } else if ([row.identifier isEqualToString:@"vanilla"]) {
            [self setSelectedVersionText:localize(@"i18n_str_1202", nil)];
        } else {
            [self setSelectedVersionText:nil];
        }
        self.selectedBadge.hidden = NO;
        self.chevronView.hidden = YES;
    } else {
        [self clearStatusText];
        self.selectedBadge.hidden = YES;
        self.chevronView.hidden = NO;
    }
}

@end

#pragma mark - Switch Row Cell（Task184 重写：VersionCardCell 同构 / Fabric API、OptiFine 共存开关行）

@interface ModLoaderSwitchCell : UITableViewCell
@property (nonatomic, strong) UIView *cardContainer;   // 整张卡片的视觉宿主
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *descLabel;
@property (nonatomic, strong) UISwitch *switchControl;
@end

@implementation ModLoaderSwitchCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self ame183_setupViews];
    }
    return self;
}

- (void)ame183_setupViews {
    AME184ClearTableViewCellChrome(self);
    self.selectionStyle = UITableViewCellSelectionStyleNone;

    // ----- 卡片容器（同 RowCell：圆角 12 continuous、上下内缩 4pt、凸起管线 init 挂一次）-----
    _cardContainer = [[UIView alloc] init];
    _cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _cardContainer.layer.cornerRadius = 12;
    _cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self.contentView addSubview:_cardContainer];
    [[BackgroundManager sharedManager] applyCardEffectToView:_cardContainer];

    // ----- 标题/描述两行（15/11 与 RowCell 同档；顶 14 / 间距 3 =
    // Task216：VersionCardCell 文字块同节奏）-----
    _titleLabel = [[UILabel alloc] init];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _titleLabel.textColor = AmeCardPrimaryTextColor();
    _titleLabel.numberOfLines = 1;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.75;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_cardContainer addSubview:_titleLabel];

    _descLabel = [[UILabel alloc] init];
    _descLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _descLabel.font = [UIFont systemFontOfSize:11];
    _descLabel.textColor = AmeCardSecondaryTextColor();
    _descLabel.numberOfLines = 0;
    _descLabel.lineBreakMode = NSLineBreakByWordWrapping;
    _descLabel.adjustsFontForContentSizeCategory = NO;
    [_cardContainer addSubview:_descLabel];

    _switchControl = [[UISwitch alloc] init];
    _switchControl.translatesAutoresizingMaskIntoConstraints = NO;
    [_cardContainer addSubview:_switchControl];

    [NSLayoutConstraint activateConstraints:@[
        [_cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
        [_cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],
        [_cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        [_titleLabel.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:16],
        [_titleLabel.topAnchor constraintEqualToAnchor:_cardContainer.topAnchor constant:14],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_switchControl.leadingAnchor constant:-12],

        [_descLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_descLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3],
        [_descLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_switchControl.leadingAnchor constant:-12],

        [_switchControl.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_switchControl.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
    ]];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    AME184ClearTableViewCellChrome(self);
    self.titleLabel.text = nil;
    self.descLabel.text = nil;
}

@end

#pragma mark - Version Row Cell（版本选择子页面，Task184 重写：VersionCardCell 同构）

@interface ModLoaderVersionCell : UITableViewCell
@property (nonatomic, strong) UIView *cardContainer;   // 整张卡片的视觉宿主
@property (nonatomic, strong) UILabel *versionLabel;
@property (nonatomic, strong) UIView *selectedBadge;
@end

@implementation ModLoaderVersionCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self ame183_setupViews];
    }
    return self;
}

- (void)ame183_setupViews {
    AME184ClearTableViewCellChrome(self);
    self.selectionStyle = UITableViewCellSelectionStyleDefault;

    // ----- 卡片容器（同款配方；行高 50 = 卡 42）-----
    _cardContainer = [[UIView alloc] init];
    _cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
    _cardContainer.layer.cornerRadius = 12;
    _cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
    [self.contentView addSubview:_cardContainer];
    [[BackgroundManager sharedManager] applyCardEffectToView:_cardContainer];

    _versionLabel = [[UILabel alloc] init];
    _versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _versionLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    _versionLabel.textColor = AmeCardPrimaryTextColor();
    _versionLabel.numberOfLines = 1;
    _versionLabel.adjustsFontSizeToFitWidth = YES;
    _versionLabel.minimumScaleFactor = 0.75;
    _versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_cardContainer addSubview:_versionLabel];

    _selectedBadge = [[UIView alloc] init];
    _selectedBadge.translatesAutoresizingMaskIntoConstraints = NO;
    _selectedBadge.backgroundColor = [UIColor systemGreenColor];
    _selectedBadge.layer.cornerRadius = 10;
    _selectedBadge.layer.masksToBounds = YES;
    _selectedBadge.hidden = YES;
    [_cardContainer addSubview:_selectedBadge];

    UIImageView *checkmark = [[UIImageView alloc] init];
    checkmark.translatesAutoresizingMaskIntoConstraints = NO;
    checkmark.image = [UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:9 weight:UIFontWeightBold]];
    checkmark.tintColor = [UIColor whiteColor];
    [_selectedBadge addSubview:checkmark];

    [NSLayoutConstraint activateConstraints:@[
        [_cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
        [_cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
        [_cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],
        [_cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

        [_versionLabel.leadingAnchor constraintEqualToAnchor:_cardContainer.leadingAnchor constant:16],
        [_versionLabel.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_versionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_selectedBadge.leadingAnchor constant:-8],

        [_selectedBadge.trailingAnchor constraintEqualToAnchor:_cardContainer.trailingAnchor constant:-14],
        [_selectedBadge.centerYAnchor constraintEqualToAnchor:_cardContainer.centerYAnchor],
        [_selectedBadge.widthAnchor constraintEqualToConstant:20],
        [_selectedBadge.heightAnchor constraintEqualToConstant:20],
        [checkmark.centerXAnchor constraintEqualToAnchor:_selectedBadge.centerXAnchor],
        [checkmark.centerYAnchor constraintEqualToAnchor:_selectedBadge.centerYAnchor],
    ]];
}

- (void)prepareForReuse {
    [super prepareForReuse];
    AME184ClearTableViewCellChrome(self);
    self.versionLabel.text = nil;
    self.selectedBadge.hidden = YES;
}

- (void)configureWithVersion:(NSString *)version isSelected:(BOOL)isSelected {
    // OptiFine packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
    NSString *display = version;
    if ([version containsString:@"\x1f"]) {
        NSArray *parts = [version componentsSeparatedByString:@"\x1f"];
        if (parts.count >= 4) display = parts[3];
        else if (parts.count >= 1) display = parts[0];
    }
    self.versionLabel.text = display;
    self.selectedBadge.hidden = !isSelected;
}

@end


#pragma mark - Version Picker View Controller (版本选择子页面，扁平 UITableView)

@interface ModLoaderVersionPickerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, NSXMLParserDelegate>
@property (nonatomic, copy) NSString *loaderId;
@property (nonatomic, copy) NSString *gameVersion;
@property (nonatomic, copy) NSString *selectedVersion;
@property (nonatomic, copy) void (^onSelected)(NSString *version);
@property (nonatomic, copy) void (^onCancelled)(void);
@end

@interface ModLoaderVersionPickerViewController ()
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *loadingIndicator;
@property (nonatomic, strong) UILabel *emptyLabel;
@property (nonatomic, strong) UILabel *errorLabel;
@property (nonatomic, strong) NSArray *versions;
// Forge XML 解析
@property (nonatomic, strong) NSMutableArray *forgeVersionList;
@property (nonatomic, strong) NSMutableString *currentVersionValue;
@property (nonatomic, assign) BOOL isParsingForge;
// Task185：Fabric/Quilt 列表精选——显示全部开关态（默认只展前 30 个）
@property (nonatomic, assign) BOOL fabricQuiltShowAll;
// Task185：Fabric/Quilt 网络全量结果缓存（“显示全部”展开免二次请求）
@property (nonatomic, strong) NSArray *fabricQuiltFullList;
// Task185：Forge 竞速重写的解析基础设施——sink = 当前 XML 的输出缓冲
//（竞速下每个 payload 解析到独立 sink，验证过才允许收尾），completion =
// 该 payload 的验证回调。
@property (nonatomic, strong) NSMutableArray *forgeParseSink;
@property (nonatomic, copy) void (^forgeParseCompletion)(NSArray *parsed);
// Task185：BMCL 按版本 JSON 兜底任务（两个 XML 源都拿不到匹配时第三路）
@property (nonatomic, strong) NSURLSessionDataTask *forgeFallbackTask;
// 网络任务
@property (nonatomic, strong) NSURLSessionDataTask *currentTask;
@property (nonatomic, strong) NSURLSessionDataTask *bmclTask;
@end

/// Task185：Fabric/Quilt 列表尾部“显示全部”哨兵行（didSelectRow 特判展开）
static NSString *ame185ShowAllSentinel(void) {
    return @"__AME185_SHOW_ALL__";
}

/// Task185：哨兵行打包格式——复用 ModLoaderVersionCell 的 \x1f 显示约定
/// （type\x1fpatch\x1ffilename\x1fdisplay，cell 取 parts[3] 展示）。
/// 哨兵前缀保证 didSelectRow 能识别，显示文案按语言切换。
static NSString *ame185ShowAllRow(NSInteger hiddenCount) {
    NSString *lang = getPrefObject(@"general.app_language");
    if (![lang isKindOfClass:NSString.class] || lang.length == 0 || [lang isEqualToString:@"system"]) {
        lang = NSLocale.preferredLanguages.firstObject ?: @"en";
    }
    NSString *display = [lang hasPrefix:@"zh"]
        ? [NSString stringWithFormat:localize(@"ame193.misc.12", @"显示全部（还有 %ld 个更早的版本）"), (long)hiddenCount]
        : [NSString stringWithFormat:@"Show all (%ld older versions)", (long)hiddenCount];
    return [NSString stringWithFormat:@"%@\x1f\x1f\x1f%@", ame185ShowAllSentinel(), display];
}

@implementation ModLoaderVersionPickerViewController

- (void)dealloc {
    if (_currentTask) { [_currentTask cancel]; _currentTask = nil; }
    if (_bmclTask) { [_bmclTask cancel]; _bmclTask = nil; }
    if (_forgeFallbackTask) { [_forgeFallbackTask cancel]; _forgeFallbackTask = nil; }   // Task185
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self pickerTitle];
    self.view.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(backTapped)];

    [self setupTableView];
    [self startLoading];
}

- (void)refreshBackgroundEffect {
    // 背景效果切换时刷新 cell 毛玻璃外观
    [_tableView reloadData];
}

- (NSString *)pickerTitle {
    if ([_loaderId isEqualToString:@"fabric"])   return localize(@"i18n_str_1203", nil);
    if ([_loaderId isEqualToString:@"forge"])    return localize(@"i18n_str_1204", nil);
    if ([_loaderId isEqualToString:@"neoforge"]) return localize(@"i18n_str_1205", nil);
    if ([_loaderId isEqualToString:@"quilt"])    return localize(@"i18n_str_1206", nil);
    if ([_loaderId isEqualToString:@"optifine"]) return localize(@"i18n_str_1207", nil);
    return localize(@"i18n_str_38", nil);
}

- (void)setupTableView {
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 64;
    _tableView.estimatedRowHeight = 64;
    // Task184：卡式 cell 不需要系统分隔线（画在透明 cell 上会横切卡面）
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.separatorInset = UIEdgeInsetsZero;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    // extendedLayoutIncludesOpaqueBars / edgesForExtendedLayout 是 UIViewController 的属性，
    // 不能设置到 UITableView 上，否则编译报 "property not found on object of type 'UITableView *'"
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;
    [_tableView registerClass:[ModLoaderVersionCell class] forCellReuseIdentifier:@"VersionCell"];
    [self.view addSubview:_tableView];

    _loadingIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _loadingIndicator.translatesAutoresizingMaskIntoConstraints = NO;
    _loadingIndicator.hidesWhenStopped = YES;
    [self.view addSubview:_loadingIndicator];

    _emptyLabel = [[UILabel alloc] init];
    _emptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _emptyLabel.text = localize(@"i18n_str_1208", nil);
    _emptyLabel.textAlignment = NSTextAlignmentCenter;
    _emptyLabel.textColor = [UIColor secondaryLabelColor];
    _emptyLabel.font = [UIFont systemFontOfSize:15];
    _emptyLabel.hidden = YES;
    [self.view addSubview:_emptyLabel];

    _errorLabel = [[UILabel alloc] init];
    _errorLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _errorLabel.text = localize(@"i18n_str_1209", nil);
    _errorLabel.textAlignment = NSTextAlignmentCenter;
    _errorLabel.textColor = [UIColor systemRedColor];
    _errorLabel.font = [UIFont systemFontOfSize:15];
    _errorLabel.numberOfLines = 0;
    _errorLabel.hidden = YES;
    [self.view addSubview:_errorLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [self.loadingIndicator.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.loadingIndicator.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.emptyLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.emptyLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],

        [self.errorLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.errorLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [self.errorLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [self.errorLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)backTapped {
    if (_onCancelled) _onCancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)startLoading {
    _versions = nil;
    _fabricQuiltShowAll = NO;   // Task185：每次重新加载重置精选开关
    _fabricQuiltFullList = nil; // Task185：全量缓存随加载周期重置
    [_tableView reloadData];
    _emptyLabel.hidden = YES;
    _errorLabel.hidden = YES;
    [_loadingIndicator startAnimating];

    if ([_loaderId isEqualToString:@"fabric"] || [_loaderId isEqualToString:@"quilt"]) {
        [self loadFabricLikeVersions:_loaderId];
    } else if ([_loaderId isEqualToString:@"forge"]) {
        [self loadForgeVersions];
    } else if ([_loaderId isEqualToString:@"neoforge"]) {
        [self loadNeoForgeVersions];
    } else if ([_loaderId isEqualToString:@"optifine"]) {
        [self loadOptiFineVersions];
    } else {
        [self finishLoadingWithVersions:@[] error:nil];
    }
}

#pragma mark Fabric / Quilt

- (void)loadFabricLikeVersions:(NSString *)loaderType {
    NSString *metaBase = [loaderType isEqualToString:@"quilt"]
        ? @"https://meta.quiltmc.org/v3/versions/loader"
        : @"https://meta.fabricmc.net/v2/versions/loader";
    NSString *urlString = [NSString stringWithFormat:@"%@/%@", metaBase, _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *versions = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!versions || jsonError) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *list = [NSMutableArray array];
            for (NSDictionary *ver in versions) {
                if (![ver isKindOfClass:[NSDictionary class]]) continue;
                NSString *loaderVersion = ver[@"loader"][@"version"];
                if (loaderVersion && ![list containsObject:loaderVersion]) {
                    [list addObject:loaderVersion];
                }
            }
            // Task185：列表精选（用户反馈“一点开是所有版本放在一起”）。
            // fabric-meta 对【任意】游戏版本都返回全部 ~253 个 loader（实测
            // 26.3 与 1.20.1 返回完全同序列表、最新在前）——loader 本就跨
            // 游戏版本通用，API 没有也不能按版本筛。默认只展示最新 30 个
            //（覆盖整合包常见需求），尾部追加“显示全部”开关行；点开后从
            // 缓存展开全量（免二次请求）。N 选 30 而非 stable 过滤的原因：
            // fabric meta 全列表仅 1 个 stable=true，单独过滤只剩 1 条。
            strongSelf->_fabricQuiltFullList = [list copy];
            if (list.count > 30 && !strongSelf->_fabricQuiltShowAll) {
                NSArray *head = [list subarrayWithRange:NSMakeRange(0, 30)];
                NSMutableArray *capped = [NSMutableArray arrayWithArray:head];
                [capped addObject:ame185ShowAllRow((NSInteger)list.count - 30)];
                [strongSelf finishLoadingWithVersions:capped error:nil];
            } else {
                [strongSelf finishLoadingWithVersions:list error:nil];
            }
        });
    }];
    [_currentTask resume];
}

#pragma mark Forge (并发竞速 + 结果验证，Task185 重写)

- (void)loadForgeVersions {
    // Task185：竞速结果验证重写。病历（11e4b63 装机反馈，国内网络）：
    // BMCL 竞速源实际返回 2022 年的陈旧 maven-metadata（最新条目
    // 1.18-38.0.17，仅 1 条 version；官方源几百条）——旧"谁先到谁赢"
    // 让陈旧镜像把官方结果挤掉，26.x 等新版本匹配数为 0 = "Forge 找不到"。
    // 新规则：
    //   1. payload 解析后【匹配当前 gameVersion 的条目 > 0】才有资格收尾；
    //   2. 陈旧/不匹配的源标记终态，把机会留给另一源；
    //   3. 首个 XML 源证明无匹配时，立即拉 BMCL 按版本 JSON 接口
    //      （/forge/minecraft/<mc>，实测有 26.3 数据）作第三路兜底，
    //      与另一个 XML 源继续竞速；
    //   4. 三路全部无匹配 → 空列表（该版本确实没有 Forge 是合法状态，
    //      显示"暂无版本"而非报错；全部网络错误则展示错误）。
    NSString *bmclURL = @"https://bmclapi2.bangbang93.com/maven/net/minecraftforge/forge/maven-metadata.xml";
    NSString *officialURL = @"https://maven.minecraftforge.net/net/minecraftforge/forge/maven-metadata.xml";

    _forgeVersionList = [NSMutableArray array];
    _forgeParseSink = nil;
    _forgeParseCompletion = nil;
    _isParsingForge = YES;

    __weak typeof(self) weakSelf = self;
    __block BOOL settled = NO;        // 已有可用结果完成收尾
    __block BOOL bmclEnded = NO;      // BMCL XML 到达终态（usable/无匹配/错）
    __block BOOL officialEnded = NO;  // 官方 XML 到达终态
    __block BOOL fallbackFired = NO;  // 兜底 JSON 已在途
    __block BOOL fallbackEnded = NO;  // 兜底 JSON 到达终态
    __block NSError *lastError = nil; // 三路全败时的错误展示（可为 nil）

    NSString *userAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";

    // 收尾：排序 + finish（主线程）
    void (^finishWith)(NSArray *) = ^(NSArray *list) {
        NSArray *sorted = [list sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [b compare:a options:NSNumericSearch];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf finishLoadingWithVersions:sorted error:nil];
        });
    };

    // 三路全部终态且无人收尾 → 空收尾（有错展示错，无错展示"暂无版本"）
    void (^checkAllEnded)(void) = ^{
        BOOL shouldFinish = NO;
        @synchronized(weakSelf) {
            if (!settled && bmclEnded && officialEnded && (!fallbackFired || fallbackEnded)) {
                settled = YES;
                shouldFinish = YES;
            }
        }
        if (shouldFinish) {
            NSLog(@"[Task185] Forge: all sources ended without a match (bmcl=%d official=%d fallback=%d)",
                  bmclEnded, officialEnded, fallbackEnded);
            NSError *err = nil;
            @synchronized(weakSelf) { err = lastError; }
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) return;
                [strongSelf finishLoadingWithVersions:@[] error:err];
            });
        }
    };

    // 单源到达终态（无匹配/失败）：按需发兜底 + 查全局终态
    void (^sourceEnded)(BOOL) = ^(BOOL isOfficial) {
        BOOL fireFallback = NO;
        @synchronized(weakSelf) {
            if (settled) return;
            if (isOfficial) officialEnded = YES; else bmclEnded = YES;
            if (!fallbackFired) {
                fallbackFired = YES;
                fireFallback = YES;
            }
        }
        NSLog(@"[Task185] Forge XML source ended without match (official=%d) — settled=%d fallbackFired=%d",
              isOfficial, settled, fallbackFired);
        if (fireFallback) {
            // 首个 XML 源证明无匹配：立即拉 BMCL 按版本 JSON（数据实测是新的），
            // 与另一个 XML 源继续竞速——国内用户官方源可能 20s 超时，不必干等。
            [weakSelf ame185_fetchForgeFallbackJSON:^(NSArray *list) {
                BOOL useIt = NO;
                @synchronized(weakSelf) {
                    if (!settled && list.count > 0) {
                        settled = YES;
                        useIt = YES;
                    } else {
                        fallbackEnded = YES;
                    }
                }
                if (useIt) {
                    NSLog(@"[Task185] Forge: BMCL per-version JSON won with %lu entries", (unsigned long)list.count);
                    finishWith(list);
                } else {
                    checkAllEnded();
                }
            }];
        }
        checkAllEnded();
    };

    // 解析 + 验证一个 payload（解析在回调线程同步执行，收尾统一切主线程）。
    // Task185 竞态防护：旧"谁先到谁赢"里 settled 短路保证同一时刻只有一个
    // 解析器在跑；新逻辑两路 XML 都要解析验证，而委托状态（_currentVersion-
    // Value / _forgeParseSink / _forgeParseCompletion）是 VC 级共享——两个
    // NSXMLParser 在不同回调线程并发解析会互相踩文本缓冲。整个"装 sink →
    // 解析 → completion"临界区用 @synchronized(self) 串行化（objc 锁可重入，
    // didEndElement 内无需再加）。
    void (^processData)(NSData *, BOOL) = ^(NSData *data, BOOL isOfficial) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized(weakSelf) { if (settled) return; }
        if (!data || data.length == 0) { sourceEnded(isOfficial); return; }
        @synchronized(strongSelf) {
            NSMutableArray *sink = [NSMutableArray array];
            __block BOOL ame185_completed = NO;   // completion 是否被 metadata 闭合消费
            strongSelf->_forgeParseSink = sink;
            strongSelf->_forgeParseCompletion = ^(NSArray *parsed) {
                ame185_completed = YES;
                BOOL useIt = NO;
                @synchronized(weakSelf) {
                    if (!settled && parsed.count > 0) {
                        settled = YES;
                        useIt = YES;
                    }
                }
                if (useIt) {
                    NSLog(@"[Task185] Forge: XML source won with %lu matches (official=%d)",
                          (unsigned long)parsed.count, isOfficial);
                    finishWith(parsed);
                } else {
                    sourceEnded(isOfficial);
                }
            };
            NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
            parser.delegate = strongSelf;
            [parser parse];
            // 解析同步完成后（didEndElement:metadata 已触发 completion 并清空
            // sink/completion），此处补一道防御性清理，防异常路径残留。
            strongSelf->_forgeParseSink = nil;
            strongSelf->_forgeParseCompletion = nil;
            // Task185 防挂死：XML 截断/坏格式时 metadata 闭合标签永不到达，
            // completion 不被消费 = 该源永不终态 → checkAllEnded 永不触发
            //（旧代码同样暴露此形态，5s 宽限只盖网络错误）。此处补终态。
            if (!ame185_completed) {
                NSLog(@"[Task185] Forge XML parse incomplete, marking source ended (official=%d, parserError=%@)",
                      isOfficial, parser.parserError.localizedDescription ?: @"nil");
                sourceEnded(isOfficial);
            }
        }
    };

    NSMutableURLRequest *bmclRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:bmclURL]];
    bmclRequest.timeoutInterval = 20.0;
    [bmclRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    _bmclTask = [[NSURLSession sharedSession] dataTaskWithRequest:bmclRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            @synchronized(weakSelf) { if (settled) return; lastError = error ?: lastError; }
            sourceEnded(NO);
            return;
        }
        processData(data, NO);
    }];

    NSMutableURLRequest *officialRequest = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:officialURL]];
    officialRequest.timeoutInterval = 20.0;
    [officialRequest setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    _currentTask = [[NSURLSession sharedSession] dataTaskWithRequest:officialRequest completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) {
            @synchronized(weakSelf) { if (settled) return; lastError = error ?: lastError; }
            sourceEnded(YES);
            return;
        }
        processData(data, YES);
    }];

    [_bmclTask resume];
    [_currentTask resume];
}

/// Task185：BMCL 按版本 Forge JSON 兜底（/forge/minecraft/<mc>）。
/// 返回纯 Forge 版本号列表（"66.0.5" 形态，与 XML 路径的 sink 口径一致）；
/// 任何失败（404/网络/解析）都按"该版本无数据"处理，回调空数组。
- (void)ame185_fetchForgeFallbackJSON:(void (^)(NSArray *list))completion {
    // Task185 CI 修正：原写法 isKindOfClass:NSBlock.class——NSBlock 在 iOS SDK
    // 不是公开声明的类（run 36317248542 实锤 "use of undeclared identifier
    // 'NSBlock'"），仅 macOS 可用。nil 检查对本防御已足够。
    if (!completion) return;
    NSString *encodedMC = [_gameVersion stringByReplacingOccurrencesOfString:@"-" withString:@"_"];
    if (encodedMC.length == 0) { completion(@[]); return; }
    NSString *urlString = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/forge/minecraft/%@", encodedMC];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlString]];
    req.timeoutInterval = 15.0;
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15" forHTTPHeaderField:@"User-Agent"];
    __weak typeof(self) weakSelf = self;
    _forgeFallbackTask = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableArray *out = [NSMutableArray array];
        if (data && !error) {
            NSArray *tokens = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([tokens isKindOfClass:NSArray.class]) {
                for (NSDictionary *token in tokens) {
                    if (![token isKindOfClass:NSDictionary.class]) continue;
                    NSString *ver = token[@"version"];
                    id branchRaw = token[@"branch"];
                    NSString *branch = [branchRaw isKindOfClass:NSString.class] ? branchRaw : nil;
                    if (![ver isKindOfClass:NSString.class] || ver.length == 0) continue;
                    // 与 XML 路径口径一致：纯 Forge 版本号（可选 -branch 后缀）
                    [out addObject:(branch.length > 0)
                        ? [NSString stringWithFormat:@"%@-%@", ver, branch]
                        : ver];
                }
            }
        } else {
            NSLog(@"[Task185] Forge fallback JSON failed: %@", error.localizedDescription ?: @"no data");
        }
        NSLog(@"[Task185] Forge fallback JSON: %lu entries for MC %@", (unsigned long)out.count, encodedMC);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            (void)strongSelf;   // completion 与 UI 解耦，仅在主线程回调
            completion([out copy]);
        });
    }];
    [_forgeFallbackTask resume];
}

#pragma mark NeoForge

- (void)loadNeoForgeVersions {
    __weak typeof(self) weakSelf = self;
    [NeoForgeVersionFetcher fetchVersionsForGameVersion:_gameVersion completion:^(NSArray *versions, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf finishLoadingWithVersions:versions ?: @[] error:error];
        });
    }];
}

#pragma mark OptiFine (BMCLAPI 列表)

- (void)loadOptiFineVersions {
    NSString *urlString = [NSString stringWithFormat:@"https://bmclapi2.bangbang93.com/optifine/%@", _gameVersion];
    NSURL *url = [NSURL URLWithString:urlString];

    __weak typeof(self) weakSelf = self;
    _currentTask = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error && error.code != NSURLErrorCancelled) {
                [strongSelf finishLoadingWithVersions:@[] error:error];
                return;
            }
            if (!data || error) {
                [strongSelf finishLoadingWithVersions:@[] error:nil];
                return;
            }
            NSError *jsonError;
            NSArray *list = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
            if (!list || jsonError || ![list isKindOfClass:[NSArray class]]) {
                [strongSelf finishLoadingWithVersions:@[] error:jsonError];
                return;
            }
            NSMutableArray *versions = [NSMutableArray array];
            for (NSDictionary *item in list) {
                if (![item isKindOfClass:[NSDictionary class]]) continue;
                NSString *type = item[@"type"] ?: @"";
                NSString *patch = item[@"patch"] ?: @"";
                NSString *filename = item[@"filename"] ?: @"";
                if (patch.length == 0) continue;
                // 显示格式：HD_U_I6 (filename)
                NSString *display = [NSString stringWithFormat:@"%@_%@", type, patch];
                if (filename.length > 0) {
                    display = [NSString stringWithFormat:@"%@_%@ (%@)", type, patch, filename];
                }
                // 把完整信息打包进 version 字符串，用 \x1f 分隔（unit separator）
                NSString *packed = [NSString stringWithFormat:@"%@\x1f%@\x1f%@\x1f%@", type, patch, filename, display];
                [versions addObject:packed];
            }
            [strongSelf finishLoadingWithVersions:versions error:nil];
        });
    }];
    [_currentTask resume];
}

- (void)finishLoadingWithVersions:(NSArray *)versions error:(NSError *)error {
    [_loadingIndicator stopAnimating];
    _isParsingForge = NO;

    if (error && versions.count == 0) {
        _versions = @[];
        _errorLabel.hidden = NO;
        _emptyLabel.hidden = YES;
        _errorLabel.text = [NSString stringWithFormat:localize(@"i18n_str_1210", nil), error.localizedDescription ?: localize(@"i18n_str_97", nil)];
    } else {
        _versions = versions ?: @[];
        _errorLabel.hidden = YES;
        _emptyLabel.hidden = (_versions.count > 0);
    }
    [_tableView reloadData];

    // 若当前已选中版本，滚动到选中行
    if (_selectedVersion.length > 0 && _versions.count > 0) {
        NSUInteger idx = [_versions indexOfObject:_selectedVersion];
        if (idx != NSNotFound) {
            NSIndexPath *path = [NSIndexPath indexPathForRow:idx inSection:0];
            [_tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionMiddle animated:NO];
        }
    }
}

#pragma mark NSXMLParserDelegate (Forge)

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributeDict {
    if ([elementName isEqualToString:@"version"]) {
        _currentVersionValue = [NSMutableString new];
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [_currentVersionValue appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if (!_isParsingForge) return;
    if ([elementName isEqualToString:@"version"]) {
        NSString *raw = [_currentVersionValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (raw.length > 0) {
            // Forge 版本格式：<mcver>-<forgever>，例如 "1.20.1-47.2.0" / "26.3-66.0.5"
            // Task185：过滤逻辑换共享等价匹配器（26.x 新纪元 + legacy 全兼容，
            // 见 utils.h ame185_loaderVersionMatchesGameVersion 病历）。旧
            // "<gameVersion>-" 前缀对 "26.3-66.0.5" 形态其实能命中，但
            // 对跨纪元等价形态（gameVersion "1.21" vs 复合首段等）覆盖不全。
            // 解析结果写入 Task185 竞速 sink（无 sink 时回退旧列表，双保险）。
            NSMutableArray *sink = _forgeParseSink ?: _forgeVersionList;
            if (ame185_loaderVersionMatchesGameVersion(raw, _gameVersion)) {
                NSRange hyphen = [raw rangeOfString:@"-"];
                NSString *forgeVer = (hyphen.location != NSNotFound && hyphen.location > 0)
                    ? [raw substringFromIndex:hyphen.location + 1]
                    : raw;
                if (forgeVer.length > 0 && ![sink containsObject:forgeVer]) {
                    [sink addObject:forgeVer];
                }
            }
        }
        _currentVersionValue = nil;
    } else if ([elementName isEqualToString:@"metadata"]) {
        _isParsingForge = NO;
        // Task185：解析完成——结果交给竞速验证回调（sink 里只有匹配当前
        // gameVersion 的条目，count>0 才有资格收尾）；无回调时（理论不可达，
        // 兼容田路径）保留旧排序收尾行为。
        NSArray *parsed = [(_forgeParseSink ?: _forgeVersionList) copy];
        void (^completion)(NSArray *) = _forgeParseCompletion;
        _forgeParseCompletion = nil;
        _forgeParseSink = nil;
        if (completion) {
            completion(parsed);
        } else {
            NSArray *sorted = [parsed sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
                return [b compare:a options:NSNumericSearch];
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self finishLoadingWithVersions:sorted error:nil];
            });
        }
    }
}

#pragma mark UITableViewDataSource / UITableViewDelegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _versions.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModLoaderVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"VersionCell" forIndexPath:indexPath];
    NSString *version = _versions[indexPath.row];
    BOOL isSelected = [_selectedVersion isEqualToString:version];
    [cell configureWithVersion:version isSelected:isSelected];
    // Task184：cell 视觉自洽（cardContainer init 挂凸起管线，开关开 = 规格卡
    // 面，关 = 旧毛玻璃/平贴管线）；不再逐帧 applyEffectToCell——那会往卡片
    // 底下再垫一层半透明底，与卡面打架。
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *raw = _versions[indexPath.row];

    // Task185：Fabric/Quilt“显示全部”哨兵行——从缓存展开全量（免二次网络
    // 请求），滚回展开点附近。
    if ([raw isKindOfClass:NSString.class] && [raw hasPrefix:ame185ShowAllSentinel()]) {
        _fabricQuiltShowAll = YES;
        if (_fabricQuiltFullList.count > 0) {
            _versions = [_fabricQuiltFullList copy];
            [_tableView reloadData];
            NSIndexPath *path = [NSIndexPath indexPathForRow:MIN(30, (NSInteger)_versions.count - 1) inSection:0];
            [_tableView scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionTop animated:NO];
        } else {
            // 缓存意外丢失（理论上不可达）：重新拉取（并保留展开态）
            [self startLoading];
        }
        return;
    }

    // 立即更新选中状态视觉反馈
    _selectedVersion = raw;
    [tableView reloadData];

    // 短暂展示选中状态后 pop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.onSelected) self.onSelected(raw);
        if (self.navigationController.viewControllers.count > 1) {
            [self.navigationController popViewControllerAnimated:YES];
        } else {
            [self dismissViewControllerAnimated:YES completion:nil];
        }
    });
}

@end

#pragma mark - Game Version Picker（Task323 嵌入模式「安装」tab 游戏版本选择子页）

/// Task323：远端版本清单选择页（与 ModLoaderVersionPickerViewController 同
/// 视觉语言：InsetGrouped + ModLoaderVersionCell 卡式行），数据 =
/// DownloadViewController.versionList 同源字典数组（id/type/releaseTime）。
/// 搜索框按版本号过滤（大小写不敏感 contains）。选中即回调并返回本页。
@interface ModLoaderGameVersionPickerViewController : UIViewController <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, copy) NSArray *gameVersions;      // 远端清单字典数组
@property (nonatomic, copy) NSString *selectedId;
@property (nonatomic, copy) void (^onSelected)(NSString *vid);
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, copy) NSArray *filtered;          // 搜索过滤后的展示集
@end

@implementation ModLoaderGameVersionPickerViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"i18n_str_38", nil);
    self.view.backgroundColor = [UIColor clearColor];
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame323_reloadForEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(ame323_backTapped)];
    [self ame323_setupViews];
    [self ame323_applyFilter:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)ame323_reloadForEffect {
    [_tableView reloadData];
}

- (void)ame323_backTapped {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)ame323_setupViews {
    _searchBar = [[UISearchBar alloc] init];
    _searchBar.translatesAutoresizingMaskIntoConstraints = NO;
    _searchBar.delegate = self;
    _searchBar.placeholder = localize(@"i18n_str_155", nil);
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_searchBar];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 50;
    _tableView.estimatedRowHeight = 50;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.separatorInset = UIEdgeInsetsZero;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    [_tableView registerClass:[ModLoaderVersionCell class] forCellReuseIdentifier:@"GameVersionCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_searchBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:4],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],
        [_searchBar.heightAnchor constraintEqualToConstant:36],

        [_tableView.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:4],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (void)ame323_applyFilter:(NSString *)query {
    NSMutableArray *ame323_out = [NSMutableArray array];
    for (NSDictionary *ame323_v in _gameVersions) {
        if (![ame323_v isKindOfClass:[NSDictionary class]]) continue;
        NSString *ame323_id = ame323_v[@"id"];
        if (![ame323_id isKindOfClass:[NSString class]] || ame323_id.length == 0) continue;
        if (query.length > 0 && [ame323_id rangeOfString:query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        [ame323_out addObject:ame323_v];
    }
    _filtered = [ame323_out copy];
    [_tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _filtered.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModLoaderVersionCell *cell = [tableView dequeueReusableCellWithIdentifier:@"GameVersionCell" forIndexPath:indexPath];
    NSDictionary *v = _filtered[indexPath.row];
    NSString *vid = [v[@"id"] isKindOfClass:[NSString class]] ? v[@"id"] : @"";
    NSString *type = [v[@"type"] isKindOfClass:[NSString class]] ? v[@"type"] : @"";
    // 展示附加类型徽标语义：release 原样、snapshot 前缀快照（本地化沿用
    // 版本 tab 的既有键，缺表时回落英文 type 原文，task248 零硬编码口径）
    NSString *typeTag = @"";
    if (type.length > 0 && ![type isEqualToString:@"release"]) {
        typeTag = [NSString stringWithFormat:@"  · %@", type];
    }
    [cell configureWithVersion:[vid stringByAppendingString:typeTag]
                    isSelected:[vid isEqualToString:_selectedId]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *v = _filtered[indexPath.row];
    NSString *vid = [v[@"id"] isKindOfClass:[NSString class]] ? v[@"id"] : nil;
    if (vid.length == 0) return;
    if (_onSelected) _onSelected(vid);
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

#pragma mark UISearchBarDelegate

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    [self ame323_applyFilter:searchText];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [self ame323_applyFilter:searchBar.text];
}

@end

#pragma mark - Main Controller

@interface ModLoaderInstallViewController () <UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UITextField *versionNameField;
@property (nonatomic, strong) UIView *nameBar;
// ★ Task323：嵌入模式页内头部（游戏版本选择芯片 + 安装按钮，替代导航栏按钮）
@property (nonatomic, strong) UIView *ame323_headerBar;
@property (nonatomic, strong) UIButton *ame323_gameVersionChip;
@property (nonatomic, strong) UIButton *ame323_installButton;

// 数据
@property (nonatomic, strong) NSMutableArray<ModLoaderRow *> *loaders;
@property (nonatomic, copy) NSString *selectedLoaderId;       // "vanilla"/"fabric"/"forge"/"neoforge"/"quilt"/"optifine"
@property (nonatomic, copy) NSString *selectedFabricVersion;
@property (nonatomic, copy) NSString *selectedForgeVersion;
@property (nonatomic, copy) NSString *selectedNeoForgeVersion;
@property (nonatomic, copy) NSString *selectedQuiltVersion;
@property (nonatomic, copy) NSString *selectedOptiFineVersion;
@property (nonatomic, copy) NSString *selectedOptiFineType;     // HD_U 等
@property (nonatomic, copy) NSString *selectedOptiFinePatch;
@property (nonatomic, copy) NSString *selectedOptiFineFilename;

// 选项
@property (nonatomic, assign) BOOL installFabricAPI;
@property (nonatomic, assign) BOOL installOptiFine;  // 仅 forge 选中时显示

// 用户是否手动修改过版本名
@property (nonatomic, assign) BOOL nameManuallyModified;
@end

@implementation ModLoaderInstallViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"i18n_str_1211", nil);
    self.view.backgroundColor = [UIColor clearColor];
    if (self.navigationController) {
        [[BackgroundManager sharedManager] applyEffectToNavigationBar:self.navigationController.navigationBar];
    }
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];

    // ★ Task323：嵌入模式（下载中心「安装」tab）——导航栏返回/安装按钮退位，
    //   页内头部条（游戏版本芯片 + 安装按钮）接管；取消/返回语义归嵌入方。
    if (_ame323_embedded) {
        [self ame323_setupHeader];
    } else {
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.left"]
                                                                                  style:UIBarButtonItemStylePlain
                                                                                 target:self
                                                                                 action:@selector(backTapped)];

        // FCL 风格：右上角下载图标按钮（替代原底部 72pt 大按钮）
        UIBarButtonItem *installItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle.fill"]
                                                                          style:UIBarButtonItemStyleDone
                                                                         target:self
                                                                         action:@selector(installTapped)];
        installItem.tintColor = [UIColor systemGreenColor];
        self.navigationItem.rightBarButtonItem = installItem;
    }

    _installFabricAPI = YES;  // Fabric 默认勾选 Fabric API（与 FCL 默认行为一致）

    [self setupLoaders];
    [self setupNameBar];
    [self setupTableView];
    [self refreshIncompatibilities];
    [self refreshVersionName];
    if (_ame323_embedded) {
        [self ame323_updateChipTitle];
    }
}

- (void)refreshBackgroundEffect {
    // 背景效果切换时刷新 cell 与 nameBar 的毛玻璃外观
    [_tableView reloadData];
}

#pragma mark Task323（嵌入模式：页内头部条 + 游戏版本切换）

/// Task323：嵌入模式页内头部条——左「游戏版本」芯片（点按 push 远端版本
/// 选择子页），右「安装」主按钮（点按走 installTapped，与导航档安装键同
/// 一语义）。ZL2 风格：圆角卡片芯片 + 填充主按钮， iPad 全宽不挤不截断。
- (void)ame323_setupHeader {
    _ame323_headerBar = [[UIView alloc] init];
    _ame323_headerBar.translatesAutoresizingMaskIntoConstraints = NO;
    _ame323_headerBar.backgroundColor = [UIColor clearColor];
    [self.view addSubview:_ame323_headerBar];

    _ame323_gameVersionChip = [UIButton buttonWithType:UIButtonTypeSystem];
    _ame323_gameVersionChip.translatesAutoresizingMaskIntoConstraints = NO;
    _ame323_gameVersionChip.layer.cornerRadius = 10;
    _ame323_gameVersionChip.layer.cornerCurve = kCACornerCurveContinuous;
    _ame323_gameVersionChip.backgroundColor = [UIColor secondarySystemFillColor];
    _ame323_gameVersionChip.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    _ame323_gameVersionChip.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [_ame323_gameVersionChip addTarget:self action:@selector(ame323_showGameVersionPicker) forControlEvents:UIControlEventTouchUpInside];
    [_ame323_headerBar addSubview:_ame323_gameVersionChip];

    _ame323_installButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _ame323_installButton.translatesAutoresizingMaskIntoConstraints = NO;
    _ame323_installButton.layer.cornerRadius = 10;
    _ame323_installButton.layer.cornerCurve = kCACornerCurveContinuous;
    _ame323_installButton.backgroundColor = [UIColor systemGreenColor];
    _ame323_installButton.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 18);
    _ame323_installButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [_ame323_installButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_ame323_installButton setTitle:localize(@"i18n_str_904", nil) forState:UIControlStateNormal];
    [_ame323_installButton addTarget:self action:@selector(installTapped) forControlEvents:UIControlEventTouchUpInside];
    [_ame323_headerBar addSubview:_ame323_installButton];

    [NSLayoutConstraint activateConstraints:@[
        [_ame323_headerBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [_ame323_headerBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_ame323_headerBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_ame323_headerBar.heightAnchor constraintEqualToConstant:40],

        [_ame323_gameVersionChip.leadingAnchor constraintEqualToAnchor:_ame323_headerBar.leadingAnchor],
        [_ame323_gameVersionChip.centerYAnchor constraintEqualToAnchor:_ame323_headerBar.centerYAnchor],
        [_ame323_gameVersionChip.heightAnchor constraintEqualToAnchor:_ame323_headerBar.heightAnchor],

        [_ame323_installButton.trailingAnchor constraintEqualToAnchor:_ame323_headerBar.trailingAnchor],
        [_ame323_installButton.centerYAnchor constraintEqualToAnchor:_ame323_headerBar.centerYAnchor],
        [_ame323_installButton.heightAnchor constraintEqualToAnchor:_ame323_headerBar.heightAnchor],
        [_ame323_gameVersionChip.trailingAnchor constraintLessThanOrEqualToAnchor:_ame323_installButton.leadingAnchor constant:-8],
    ]];
}

/// Task323：芯片标题同步（游戏版本：X；空版本回落占位文案）。
- (void)ame323_updateChipTitle {
    NSString *ame323_title = _gameVersion.length > 0
        ? [NSString stringWithFormat:@"%@：%@  ▾", localize(@"i18n_str_38", nil), _gameVersion]
        : [NSString stringWithFormat:@"%@  ▾", localize(@"i18n_str_38", nil)];
    [_ame323_gameVersionChip setTitle:ame323_title forState:UIControlStateNormal];
    [_ame323_gameVersionChip setTitleColor:[UIColor labelColor] forState:UIControlStateNormal];
}

/// Task323：嵌入模式切换目标游戏版本——重建加载器兼容性行 + 自动版本名 +
/// 芯片标题；选中加载器的版本选择按新版本重判（旧选择保留，不兼容时由
/// refreshIncompatibilities 红字提示）。
- (void)ame323_applyGameVersion:(NSString *)vid {
    if (![vid isKindOfClass:[NSString class]] || vid.length == 0) return;
    if ([vid isEqualToString:_gameVersion]) { [self ame323_updateChipTitle]; return; }
    _gameVersion = [vid copy];
    [self setupLoaders];
    [self refreshIncompatibilities];
    [self refreshVersionName];
    [self ame323_updateChipTitle];
}

/// Task323：push 远端游戏版本选择子页（数据 = 嵌入方注入的远端清单）。
- (void)ame323_showGameVersionPicker {
    ModLoaderGameVersionPickerViewController *picker = [[ModLoaderGameVersionPickerViewController alloc] init];
    picker.gameVersions = _ame323_gameVersions ?: @[];
    picker.selectedId = _gameVersion;
    __weak typeof(self) weakSelf = self;
    picker.onSelected = ^(NSString *vid) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf ame323_applyGameVersion:vid];
    };
    if (self.navigationController) {
        [self.navigationController pushViewController:picker animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
        nav.modalPresentationStyle = UIModalPresentationFormSheet;
        [self presentViewController:nav animated:YES completion:nil];
    }
}

#pragma mark Setup

- (void)setupLoaders {
    _loaders = [NSMutableArray array];

    BOOL fabricCompatible = [self isFabricCompatible];
    BOOL quiltCompatible = [self isQuiltCompatible];
    BOOL forgeCompatible = [self isForgeCompatible];
    BOOL neoForgeCompatible = [self isNeoForgeCompatible];
    BOOL optiFineCompatible = [self isOptiFineCompatible];

    // 通过 ModLoaderIconHelper 统一获取加载器图标和品牌色（优先 PNG，回退 SF Symbol）
    NSArray *defs = @[
        @{ @"id": @"vanilla",  @"name": localize(@"i18n_str_1212", nil), @"desc": localize(@"i18n_str_1213", nil), @"compatible": @YES },
        @{ @"id": @"fabric",   @"name": @"Fabric",        @"desc": localize(@"i18n_str_1214", nil),      @"compatible": @(fabricCompatible) },
        @{ @"id": @"forge",    @"name": @"Forge",         @"desc": localize(@"i18n_str_1215", nil),        @"compatible": @(forgeCompatible) },
        @{ @"id": @"neoforge", @"name": @"NeoForge",      @"desc": localize(@"i18n_str_1216", nil),          @"compatible": @(neoForgeCompatible) },
        @{ @"id": @"quilt",    @"name": @"Quilt",         @"desc": localize(@"i18n_str_1217", nil),         @"compatible": @(quiltCompatible) },
        @{ @"id": @"optifine", @"name": @"OptiFine",      @"desc": localize(@"i18n_str_1218", nil),  @"compatible": @(optiFineCompatible) },
    ];

    for (NSDictionary *d in defs) {
        ModLoaderRow *row = [ModLoaderRow new];
        row.identifier = d[@"id"];
        row.name = d[@"name"];
        row.desc = d[@"desc"];
        // 通过 ModLoaderIconHelper 统一获取图标符号名和品牌色（PNG 缺失时回退用）
        row.iconName = [ModLoaderIconHelper symbolNameForLoader:d[@"id"]];
        row.compatible = [d[@"compatible"] boolValue];
        row.iconColor = [ModLoaderIconHelper brandColorForLoader:d[@"id"]];
        [_loaders addObject:row];
    }
}

- (void)setupNameBar {
    // FCL 风格 name_bar：紧凑横向条目（"版本名" label + 输入框），高度 40pt
    _nameBar = [[UIView alloc] init];
    _nameBar.translatesAutoresizingMaskIntoConstraints = NO;
    // 适配自定义启动器背景：有全局背景时用毛玻璃，否则用默认实色
    if ([[BackgroundManager sharedManager] hasBackground]) {
        _nameBar.backgroundColor = [UIColor clearColor];
        [[BackgroundManager sharedManager] applyEffectToView:_nameBar];
        _nameBar.layer.cornerRadius = 10;
        _nameBar.layer.masksToBounds = YES;
    } else {
        // Task136：无背景时与上级菜单（版本卡列表）同语言——新拟态凸出卡片
        // （surface 底色 + 暗/亮双外阴影），圆角基准 50（引擎按高度夹断）
        _nameBar.layer.cornerRadius = 10;  // Task137：回归原生圆角
        [[BackgroundManager sharedManager] applyEffectToView:_nameBar];
    }
    [self.view addSubview:_nameBar];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = localize(@"i18n_str_1219", nil);
    label.font = [UIFont systemFontOfSize:[ScreenUtils sp:13] weight:UIFontWeightMedium];
    label.textColor = [UIColor secondaryLabelColor];
    label.adjustsFontForContentSizeCategory = NO;
    [_nameBar addSubview:label];

    _versionNameField = [[UITextField alloc] init];
    _versionNameField.translatesAutoresizingMaskIntoConstraints = NO;
    _versionNameField.font = [UIFont systemFontOfSize:[ScreenUtils sp:14]];
    _versionNameField.textColor = [UIColor labelColor];
    _versionNameField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:localize(@"i18n_str_1220", nil)
                                                                             attributes:@{
        NSForegroundColorAttributeName: [UIColor placeholderTextColor]
    }];
    _versionNameField.borderStyle = UITextBorderStyleNone;
    _versionNameField.returnKeyType = UIReturnKeyDone;
    _versionNameField.delegate = self;
    _versionNameField.autocorrectionType = UITextAutocorrectionTypeNo;
    _versionNameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _versionNameField.clearButtonMode = UITextFieldViewModeWhileEditing;
    [_nameBar addSubview:_versionNameField];

    // ★ Task323：嵌入模式时 nameBar 顶部锚在页内头部条下方；push 模式锚 safeArea
    NSLayoutConstraint *ame323_top = _ame323_embedded
        ? [_nameBar.topAnchor constraintEqualToAnchor:_ame323_headerBar.bottomAnchor constant:8]
        : [_nameBar.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8];
    [NSLayoutConstraint activateConstraints:@[
        ame323_top,
        [_nameBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_nameBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_nameBar.heightAnchor constraintEqualToConstant:40],

        [label.leadingAnchor constraintEqualToAnchor:_nameBar.leadingAnchor constant:12],
        [label.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],

        [_versionNameField.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10],
        [_versionNameField.trailingAnchor constraintEqualToAnchor:_nameBar.trailingAnchor constant:-12],
        [_versionNameField.centerYAnchor constraintEqualToAnchor:_nameBar.centerYAnchor],
        [_versionNameField.heightAnchor constraintEqualToAnchor:_nameBar.heightAnchor],
    ]];
}

- (void)setupTableView {
    // FCL 风格：扁平 UITableView InsetGrouped，加载器列表 + 附加选项 section
    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.backgroundView = nil;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    // Task216（用户六轮重写仍"与选择游戏版本列表样式不同"的真收口）：
    // Task212 曾把本表压到 50pt 并声称"版本选择表 50pt"——但游戏版本表
    //（DownloadViewController versionCollectionView / VersionCardCell）实际
    // 行高 64pt、图标容器 40x40、图标-文字间距 14pt。本轮行高回 64（卡 56），
    // RowCell 内部几何同步对齐 VersionCardCell 真基准。
    _tableView.rowHeight = 64;
    _tableView.estimatedRowHeight = 64;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    // extendedLayoutIncludesOpaqueBars / edgesForExtendedLayout 是 UIViewController 的属性，
    // 不能设置到 UITableView 上，否则编译报 "property not found on object of type 'UITableView *'"
    self.extendedLayoutIncludesOpaqueBars = YES;
    self.edgesForExtendedLayout = UIRectEdgeAll;
    _tableView.sectionHeaderTopPadding = 0;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.separatorInset = UIEdgeInsetsZero;
    [_tableView registerClass:[ModLoaderRowCell class] forCellReuseIdentifier:@"LoaderRowCell"];
    [_tableView registerClass:[ModLoaderSwitchCell class] forCellReuseIdentifier:@"SwitchCell"];
    [self.view addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_tableView.topAnchor constraintEqualToAnchor:_nameBar.bottomAnchor constant:8],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

#pragma mark Compatibility checks (与原 LoaderSelectionViewController 一致)

- (BOOL)isFabricCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 14) return YES;
    return NO;
}

- (BOOL)isQuiltCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 18) return YES;
    return NO;
}

- (BOOL)isForgeCompatible {
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major == 1 && minor >= 1) return YES;
    if (major > 1) return YES;
    return NO;
}

- (BOOL)isNeoForgeCompatible {
    if (!_gameVersion) return NO;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return NO;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    NSInteger patch = (c.count > 2) ? [c[2] integerValue] : 0;
    if (major > 1) return YES;
    if (major == 1 && minor == 20 && patch >= 1) return YES;
    if (major == 1 && minor > 20) return YES;
    return NO;
}

- (BOOL)isOptiFineCompatible {
    // OptiFine 1.14+ 与 Forge 兼容，1.13 及以下独立装为版本补丁
    if (!_gameVersion) return YES;
    NSArray *c = [_gameVersion componentsSeparatedByString:@"."];
    if (c.count < 2) return YES;
    NSInteger major = [c[0] integerValue];
    NSInteger minor = [c[1] integerValue];
    if (major > 1) return YES;
    if (major == 1 && minor >= 8) return YES;
    return NO;
}

#pragma mark Compatibility (互斥逻辑，参照 FCL InstallerItemGroup)

- (NSString *)incompatibleReasonForLoaderId:(NSString *)loaderId {
    // fabricApi 与 forge/optifine/neoforge 互斥
    // optifine 与 fabric/quilt/neoforge 互斥（与 forge 可共存）
    // forge/fabric/quilt/neoforge 互斥

    if ([loaderId isEqualToString:@"vanilla"]) return nil;

    BOOL fabricSelected  = [_selectedLoaderId isEqualToString:@"fabric"];
    BOOL forgeSelected   = [_selectedLoaderId isEqualToString:@"forge"];
    BOOL neoSelected     = [_selectedLoaderId isEqualToString:@"neoforge"];
    BOOL quiltSelected   = [_selectedLoaderId isEqualToString:@"quilt"];
    BOOL optiSelected    = [_selectedLoaderId isEqualToString:@"optifine"];

    if ([loaderId isEqualToString:@"fabric"] || [loaderId isEqualToString:@"forge"] ||
        [loaderId isEqualToString:@"neoforge"] || [loaderId isEqualToString:@"quilt"]) {
        // 加载器组互斥
        if (fabricSelected  && ![loaderId isEqualToString:@"fabric"])  return localize(@"i18n_str_1221", nil);
        if (forgeSelected   && ![loaderId isEqualToString:@"forge"])   return localize(@"i18n_str_1222", nil);
        if (neoSelected     && ![loaderId isEqualToString:@"neoforge"]) return localize(@"i18n_str_1223", nil);
        if (quiltSelected   && ![loaderId isEqualToString:@"quilt"])   return localize(@"i18n_str_1224", nil);
        // optifine 与 fabric/quilt/neoforge 互斥
        if (optiSelected) {
            if ([loaderId isEqualToString:@"fabric"])  return localize(@"i18n_str_1225", nil);
            if ([loaderId isEqualToString:@"quilt"])   return localize(@"i18n_str_1225", nil);
            if ([loaderId isEqualToString:@"neoforge"]) return localize(@"i18n_str_1225", nil);
        }
    }

    if ([loaderId isEqualToString:@"optifine"]) {
        if (fabricSelected)  return localize(@"i18n_str_1221", nil);
        if (quiltSelected)   return localize(@"i18n_str_1224", nil);
        if (neoSelected)     return localize(@"i18n_str_1223", nil);
    }

    return nil;
}

- (void)refreshIncompatibilities {
    // 重新渲染所有行，互斥/兼容状态在 cellForRowAtIndexPath 中计算
    [_tableView reloadData];
}

#pragma mark Version name (参照 FCL VersionInstallInfoPage.generateVersionName)

- (NSString *)generateVersionName {
    if (!_gameVersion) return @"";
    NSMutableString *name = [NSMutableString stringWithString:_gameVersion];

    // 已选加载器追加 -loaderName
    NSString *loaderId = _selectedLoaderId;
    if (loaderId.length > 0 && ![loaderId isEqualToString:@"vanilla"]) {
        NSString *loaderName = nil;
        if ([loaderId isEqualToString:@"fabric"])   loaderName = @"fabric";
        else if ([loaderId isEqualToString:@"forge"])    loaderName = @"forge";
        else if ([loaderId isEqualToString:@"neoforge"]) loaderName = @"neoforge";
        else if ([loaderId isEqualToString:@"quilt"])    loaderName = @"quilt";
        else if ([loaderId isEqualToString:@"optifine"]) loaderName = @"OptiFine";
        if (loaderName) [name appendFormat:@"-%@", loaderName];
    }

    // 若同时勾选了 OptiFine（与 Forge 共存），追加 -OptiFine
    if (_installOptiFine && [loaderId isEqualToString:@"forge"]) {
        if (![_selectedLoaderId isEqualToString:@"optifine"]) {
            [name appendString:@"-OptiFine"];
        }
    }

    return [name copy];
}

- (void)refreshVersionName {
    if (_nameManuallyModified) return;
    // 注意：变量名不能使用 "auto"，因为 auto 是 C/C++/Objective-C 的保留关键字
    // （存储类说明符），作为标识符会导致 "expected identifier or '('" 编译错误。
    // 改用 autoGeneratedName 以避免与关键字冲突。
    NSString *autoGeneratedName = [self generateVersionName];
    if (![autoGeneratedName isEqualToString:_versionNameField.text]) {
        // programmatic edit, ignore text change notification
        _versionNameField.text = autoGeneratedName;
    }
}

#pragma mark Actions

- (void)backTapped {
    if (_cancelled) _cancelled();
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)installTapped {
    if (_selectedLoaderId.length == 0) {
        [self showAlert:localize(@"i18n_str_1226", nil) message:nil];
        return;
    }

    if (![_selectedLoaderId isEqualToString:@"vanilla"] && ![_selectedLoaderId isEqualToString:@"optifine"]) {
        NSString *selectedVersion = [self selectedVersionForLoader:_selectedLoaderId];
        if (selectedVersion.length == 0) {
            [self showAlert:localize(@"i18n_str_1227", nil) message:localize(@"i18n_str_1228", nil)];
            return;
        }
    }

    // OptiFine 单独安装时必须有选中版本
    if ([_selectedLoaderId isEqualToString:@"optifine"] && _selectedOptiFineVersion.length == 0) {
        [self showAlert:localize(@"i18n_str_1229", nil) message:nil];
        return;
    }

    BOOL installFabricAPI = NO;
    BOOL installOptiFine = NO;
    NSString *loaderVersion = [self selectedVersionForLoader:_selectedLoaderId];

    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        installFabricAPI = _installFabricAPI;
    } else if ([_selectedLoaderId isEqualToString:@"forge"]) {
        installOptiFine = _installOptiFine;
    } else if ([_selectedLoaderId isEqualToString:@"optifine"]) {
        // 单独安装 OptiFine：作为版本补丁
        installOptiFine = YES;
        // 单独 optifine 时 loaderVersion 为 OptiFine 完整描述（type\x1fpatch\x1ffilename\x1fdisplay）
        loaderVersion = _selectedOptiFineVersion;
    }

    if (_completion) {
        _completion(_selectedLoaderId, installFabricAPI, installOptiFine, loaderVersion);
    }
}

- (NSString *)selectedVersionForLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   return _selectedFabricVersion;
    if ([loaderId isEqualToString:@"forge"])    return _selectedForgeVersion;
    if ([loaderId isEqualToString:@"neoforge"]) return _selectedNeoForgeVersion;
    if ([loaderId isEqualToString:@"quilt"])    return _selectedQuiltVersion;
    if ([loaderId isEqualToString:@"optifine"]) return _selectedOptiFineVersion;
    return nil;
}

- (void)setSelectedVersion:(NSString *)version forLoader:(NSString *)loaderId {
    if ([loaderId isEqualToString:@"fabric"])   self.selectedFabricVersion = version;
    else if ([loaderId isEqualToString:@"forge"])    self.selectedForgeVersion = version;
    else if ([loaderId isEqualToString:@"neoforge"]) self.selectedNeoForgeVersion = version;
    else if ([loaderId isEqualToString:@"quilt"])    self.selectedQuiltVersion = version;
    else if ([loaderId isEqualToString:@"optifine"]) {
        self.selectedOptiFineVersion = version;
        // 解析 packed 格式：type\x1fpatch\x1ffilename\x1fdisplay
        if ([version containsString:@"\x1f"]) {
            NSArray *parts = [version componentsSeparatedByString:@"\x1f"];
            if (parts.count >= 3) {
                self.selectedOptiFineType = parts[0];
                self.selectedOptiFinePatch = parts[1];
                self.selectedOptiFineFilename = parts[2];
            }
        }
    }
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_406", nil) style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - TextField

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    // 用户开始手动编辑
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    // 注意：变量名不能使用 "auto"，因为 auto 是 C/C++/Objective-C 的保留关键字
    // （存储类说明符），作为标识符会导致 "expected identifier or '('" 编译错误。
    // 改用 autoGeneratedName 以避免与关键字冲突。
    NSString *autoGeneratedName = [self generateVersionName];
    if (textField.text.length == 0) {
        _nameManuallyModified = NO;
        textField.text = autoGeneratedName;
    } else if (![textField.text isEqualToString:autoGeneratedName]) {
        _nameManuallyModified = YES;
    }
}

#pragma mark - TableView

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    // Task136：每个加载器一行独立 section（insetGrouped 渲染为独立圆角卡），
    // 附加选项仍为独立末节——与上级菜单（版本卡列表）的卡片样式对齐
    return _loaders.count + ([self currentOptions].count > 0 ? 1 : 0);
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section < (NSInteger)_loaders.count) {
        return 1;  // Task136：每个加载器 section 仅一行卡片
    }
    // 附加选项 section
    return [self currentOptions].count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0) return localize(@"i18n_str_160", nil);
    if (section == (NSInteger)_loaders.count && [self currentOptions].count > 0) {
        return localize(@"i18n_str_2048", nil);
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    // Task136：带标题的 section（首节/附加选项节）自动高度；
    // Task190：其余加载器卡间 section 头高 4pt——卡片自身上下内缩各 4pt，
    // 相邻卡面净距 = 4(下内缩) + 4(头) + 4(上内缩) = 12pt，与上级版本号页
    // （DownloadViewController：minimumLineSpacing 4 + 卡片上下内缩 4+4）
    // 完全一致；旧 10pt 头使净距 18pt，用户实测偏大要求对齐
    if (section == 0) return UITableViewAutomaticDimension;
    if (section < (NSInteger)_loaders.count) return 4;
    return UITableViewAutomaticDimension;
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return 0.01;
}

- (NSMutableArray *)currentOptions {
    NSMutableArray *opts = [NSMutableArray array];
    if ([_selectedLoaderId isEqualToString:@"fabric"]) {
        [opts addObject:@{ @"type": @"fabric_api" }];
    }
    if ([_selectedLoaderId isEqualToString:@"forge"]) {
        [opts addObject:@{ @"type": @"optifine_mod" }];
    }
    return opts;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < (NSInteger)_loaders.count) {
        ModLoaderRowCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LoaderRowCell" forIndexPath:indexPath];
        ModLoaderRow *row = _loaders[indexPath.section];

        BOOL isSelected = [_selectedLoaderId isEqualToString:row.identifier];

        // 计算选中版本的显示文本（OptiFine packed 格式提取 display）
        NSString *versionDisplay = nil;
        if (isSelected && ![row.identifier isEqualToString:@"vanilla"]) {
            NSString *selVer = [self selectedVersionForLoader:row.identifier];
            if (selVer.length > 0) {
                versionDisplay = selVer;
                if ([selVer containsString:@"\x1f"]) {
                    NSArray *parts = [selVer componentsSeparatedByString:@"\x1f"];
                    if (parts.count >= 4) versionDisplay = parts[3];
                    else if (parts.count >= 1) versionDisplay = parts[0];
                }
            }
        }

        // 兼容性 + 互斥判断
        BOOL incompatible = NO;
        NSString *reason = nil;
        if (!row.compatible) {
            incompatible = YES;
            reason = localize(@"i18n_str_1231", nil);
        } else {
            reason = [self incompatibleReasonForLoaderId:row.identifier];
            if (reason) incompatible = YES;
        }

        [cell configureWithRow:row
                    isSelected:isSelected
          selectedVersionDisplay:versionDisplay
                    incompatible:incompatible
                         reason:reason];
        // Task184：cell 视觉自洽——cardContainer 已在 init 挂凸起管线
        //（兼顾新拟态开关），系统 inset-grouped 白底/选中高亮已在 cell 内
        // 清除（"钉死的底层白框"根修）；出列零重铺，与 VersionCardCell
        // 的单次挂载范式一致。
        return cell;
    } else {
        // 附加选项 section（Task136：末节，Fabric API / OptiFine 共存开关）
        ModLoaderSwitchCell *cell = [tableView dequeueReusableCellWithIdentifier:@"SwitchCell" forIndexPath:indexPath];
        NSMutableArray *opts = [self currentOptions];
        NSDictionary *opt = opts[indexPath.row];
        NSString *type = opt[@"type"];

        if ([type isEqualToString:@"fabric_api"]) {
            cell.titleLabel.text = localize(@"i18n_str_1232", nil);
            cell.descLabel.text = localize(@"i18n_str_1233", nil);
            cell.switchControl.on = _installFabricAPI;
            cell.switchControl.tag = 1001;
        } else if ([type isEqualToString:@"optifine_mod"]) {
            cell.titleLabel.text = localize(@"i18n_str_1234", nil);
            cell.descLabel.text = localize(@"i18n_str_1235", nil);
            cell.switchControl.on = _installOptiFine;
            cell.switchControl.tag = 1002;
        } else {
            cell.titleLabel.text = @"";
            cell.descLabel.text = @"";
            cell.switchControl.on = NO;
            cell.switchControl.tag = 0;
        }
        [cell.switchControl removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
        [cell.switchControl addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        // Task184：同上，开关行视觉自洽（cardContainer init 挂管线 + 系统白底已清）
        return cell;
    }
}

- (void)switchChanged:(UISwitch *)sender {
    if (sender.tag == 1001) {
        _installFabricAPI = sender.on;
    } else if (sender.tag == 1002) {
        _installOptiFine = sender.on;
    }
    [self refreshVersionName];
    // Task136：逐节卡片布局下选中状态分布在不同 section，整体重载同步
    [self.tableView reloadData];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section >= (NSInteger)_loaders.count) return;

    ModLoaderRow *row = _loaders[indexPath.section];
    if (!row.compatible) return;

    NSString *reason = [self incompatibleReasonForLoaderId:row.identifier];
    if (reason) {
        [self showAlert:reason message:nil];
        return;
    }

    if ([row.identifier isEqualToString:@"vanilla"]) {
        _selectedLoaderId = @"vanilla";
        // 清空加载器版本（vanilla 无需版本号）
        _installOptiFine = NO;
        _installFabricAPI = NO;
        [self refreshVersionName];
        [tableView reloadData];
        return;
    }

    // 切换加载器
    _selectedLoaderId = row.identifier;
    // 重置互斥选项
    if (![row.identifier isEqualToString:@"fabric"])  _installFabricAPI = NO;
    if (![row.identifier isEqualToString:@"forge"])   _installOptiFine = NO;
    if ([row.identifier isEqualToString:@"fabric"])   _installFabricAPI = YES;

    [self refreshVersionName];

    // 直接 push 版本选择页
    [self pushVersionPickerForLoader:row.identifier];
    [tableView reloadData];
}

- (void)pushVersionPickerForLoader:(NSString *)loaderId {
    ModLoaderVersionPickerViewController *picker = [[ModLoaderVersionPickerViewController alloc] init];
    picker.loaderId = loaderId;
    picker.gameVersion = _gameVersion;
    picker.selectedVersion = [self selectedVersionForLoader:loaderId];

    __weak typeof(self) weakSelf = self;
    picker.onSelected = ^(NSString *version) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf setSelectedVersion:version forLoader:loaderId];
        [strongSelf refreshVersionName];
        [strongSelf.tableView reloadData];
    };
    picker.onCancelled = nil;

    [self.navigationController pushViewController:picker animated:YES];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
