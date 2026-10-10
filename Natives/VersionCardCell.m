#import "utils.h"
// VersionCardCell.m
// 参照 FCL (item_remote_version.xml) 与 ZL2 (VersionItemLayout) 的单列横向列表行设计：
// - 左侧：类型图标容器（40x40 圆角方块，类型色背景 + 白色 SF Symbol）
// - 中间：版本号（16pt semibold）+ 类型小标签（pill） 在同一行 / 发布日期（12pt secondary）在下一行
// - 右侧：chevron 指示可点击
// - 已安装标记：图标容器右上角的绿色小圆点徽章（ZL2 风格，不遮挡右侧 chevron）
// 替代原 100x120 纵向网格卡片，信息密度更高、更接近 FCL/ZL2 视觉。

#import "VersionCardCell.h"
#import "BackgroundManager.h"
#import "UIKit+NativeSurface.h"

// Task137："正式版/测试版"类型胶囊改用共享的 AmeBadgeLabel
// （UIKit+NativeSurface.h）：完整实现 intrinsicContentSize = 文字尺寸 +
// 左右内边距，自动布局下宽度随字体动态且永不截断（Task136 的 InsetTypeLabel
// 缺少 intrinsicContentSize 补偿，所有胶囊都被裁成"…"，本类修复该回归）；
// 圆角随高度取半保持胶囊形状。

@interface VersionCardCell ()
// 容器视图：整张卡片的圆角背景（毛玻璃 + 半透明）
@property (nonatomic, strong) UIView *cardContainer;
// 左侧类型图标容器（带圆角与类型色背景）
@property (nonatomic, strong) UIView *iconContainer;
// 顶行水平 stack：装 versionLabel + typeLabel，自动处理间距与裁剪
@property (nonatomic, strong) UIStackView *topRowStack;
// 右侧 chevron 指示
@property (nonatomic, strong) UIImageView *chevronView;
@end

@implementation VersionCardCell

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 外层 cell 透明，由 cardContainer 提供视觉
        self.backgroundColor = [UIColor clearColor];
        self.contentView.backgroundColor = [UIColor clearColor];
        self.layer.masksToBounds = NO;

        // ----- 卡片容器（Task137：原生卡片表面，圆角回摑 Task136 之前的 12pt）-----
        // 保留圆角供 applyEffectToView 读取；底色移交 UIKit+NativeSurface 管理
        self.cardContainer = [[UIView alloc] init];
        self.cardContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.cardContainer.layer.cornerRadius = 12;
        self.cardContainer.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentView addSubview:self.cardContainer];

        // 应用原生卡片效果（Task163：applyCardEffectToView 检测切换：
        // 有背景照片时转调毛玻璃/半透明旧管线，无背景时挂新拟态规格双阴影
        // ——用户实测"下载页面版本选项一点没改"的修复落点）
        [[BackgroundManager sharedManager] applyCardEffectToView:self.cardContainer];

        // ----- 左侧图标容器：40x40 圆角方块，类型色背景 -----
        self.iconContainer = [[UIView alloc] init];
        self.iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconContainer.layer.cornerRadius = 10;
        self.iconContainer.layer.cornerCurve = kCACornerCurveContinuous;
        self.iconContainer.layer.masksToBounds = YES;
        self.iconContainer.backgroundColor = [UIColor systemGreenColor];
        [self.cardContainer addSubview:self.iconContainer];

        // 图标本体：白色 SF Symbol，居中
        self.iconImageView = [[UIImageView alloc] init];
        self.iconImageView.translatesAutoresizingMaskIntoConstraints = NO;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.tintColor = [UIColor whiteColor];
        self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
        [self.iconContainer addSubview:self.iconImageView];

        // ----- 版本号 -----
        self.versionLabel = [[UILabel alloc] init];
        self.versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.versionLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.versionLabel.textColor = AmeCardPrimaryTextColor(); // Task160 规格主文字
        self.versionLabel.adjustsFontSizeToFitWidth = YES;
        // Task141：缩小下限 = 12/16 = 0.75 —— 用户实测"主标题字号比时间灰字还小"
        // 根因：旧下限 0.7 允许标题缩到 11.2pt < 日期 12pt；现在标题最小渲染尺寸
        // 与日期一致（极端长版本号时两者同字号），不再出现"标题比灰字小"。
        self.versionLabel.minimumScaleFactor = 0.75;
        self.versionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        // 版本号 hugging 高（不主动拉伸），compression 低（空间不足时优先被压缩→触发字号缩小）
        [self.versionLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
        [self.versionLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

        // ----- 类型标签（Task137：右侧独立胶囊，按字体宽度自适应且永不截断） -----
        // AmeBadgeLabel：宽度 = 文字 + 左右 8pt 内边距（随字体动态，intrinsic
        // 完整补偿）；固定高 24（≈两行 12pt 字），圆角随高度取半；靠右固定在
        // chevron 左侧，永不贴近卡片边缘被裁剪；hugging/compression 均为
        // Required：胶囊永不压缩变形（不再出现"…"）。
        self.typeLabel = [[AmeBadgeLabel alloc] init];
        self.typeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.typeLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        self.typeLabel.textColor = [UIColor whiteColor];
        self.typeLabel.textAlignment = NSTextAlignmentCenter;
        // 类型标签尺寸由 intrinsicContentSize 保证，空间不足时由版本号侧压缩
        [self.cardContainer addSubview:self.typeLabel];

        // ----- 顶行 stack：仅版本号（Task136：类型胶囊移出 stack 独立靠右） -----
        self.topRowStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.versionLabel]];
        self.topRowStack.translatesAutoresizingMaskIntoConstraints = NO;
        self.topRowStack.axis = UILayoutConstraintAxisHorizontal;
        self.topRowStack.alignment = UIStackViewAlignmentCenter;
        self.topRowStack.distribution = UIStackViewDistributionFill;
        self.topRowStack.spacing = 8;
        [self.cardContainer addSubview:self.topRowStack];

        // ----- 日期 -----
        self.dateLabel = [[UILabel alloc] init];
        self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.dateLabel.font = [UIFont systemFontOfSize:12];
        self.dateLabel.textColor = AmeCardSecondaryTextColor(); // Task160 规格次要文字
        self.dateLabel.adjustsFontSizeToFitWidth = YES;
        self.dateLabel.minimumScaleFactor = 0.7;
        self.dateLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.cardContainer addSubview:self.dateLabel];

        // ----- 右侧 chevron：提示可点击进入加载器选择 -----
        self.chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        self.chevronView.tintColor = [UIColor tertiaryLabelColor];
        self.chevronView.contentMode = UIViewContentModeScaleAspectFit;
        // chevron 固定尺寸，不被拉伸
        [self.chevronView setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.chevronView setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [self.cardContainer addSubview:self.chevronView];

        // ----- 已安装徽章：图标容器右上角的绿色小圆点（ZL2 风格）-----
        // 不再用大块绿色 ✓ 占据卡片右上角，改用 14pt 小圆点贴在 iconContainer 右上角，
        // 既保留"已安装"指示，又不遮挡右侧 chevron 与版本号。
        self.installedBadge = [[UIView alloc] init];
        self.installedBadge.translatesAutoresizingMaskIntoConstraints = NO;
        self.installedBadge.backgroundColor = [UIColor systemGreenColor];
        self.installedBadge.layer.cornerRadius = 7;
        self.installedBadge.layer.masksToBounds = YES;
        self.installedBadge.layer.borderColor = [UIColor systemBackgroundColor].CGColor;
        self.installedBadge.layer.borderWidth = 1.5;
        self.installedBadge.hidden = YES;
        [self.cardContainer addSubview:self.installedBadge];

        // 内部小 ✓（白色，居中）
        UIImageView *checkmark = [[UIImageView alloc] init];
        checkmark.translatesAutoresizingMaskIntoConstraints = NO;
        checkmark.image = [UIImage systemImageNamed:@"checkmark"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:7 weight:UIFontWeightBold]];
        checkmark.tintColor = [UIColor whiteColor];
        [self.installedBadge addSubview:checkmark];

        // ----- 布局约束 -----
        [NSLayoutConstraint activateConstraints:@[
            // cardContainer 充满 contentView（留 0 外边距，间距由 collection layout 的 sectionInset 控制）
            [self.cardContainer.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:4],
            [self.cardContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:0],
            [self.cardContainer.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:0],
            [self.cardContainer.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4],

            // 图标容器：左 14，垂直居中，40x40
            [self.iconContainer.leadingAnchor constraintEqualToAnchor:self.cardContainer.leadingAnchor constant:14],
            [self.iconContainer.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor],
            [self.iconContainer.widthAnchor constraintEqualToConstant:40],
            [self.iconContainer.heightAnchor constraintEqualToConstant:40],

            // 图标在容器内居中，22x22
            [self.iconImageView.centerXAnchor constraintEqualToAnchor:self.iconContainer.centerXAnchor],
            [self.iconImageView.centerYAnchor constraintEqualToAnchor:self.iconContainer.centerYAnchor],
            [self.iconImageView.widthAnchor constraintEqualToConstant:22],
            [self.iconImageView.heightAnchor constraintEqualToConstant:22],

            // 顶行 stack：紧跟图标容器右侧 +14，顶部对齐 cardContainer 顶部 +13
            // 右侧到类型胶囊之间留 8pt；胶囊靠右独立固定
            // ★ Task236：14→13（配合行高 64→72 的垂直挤压根修，见 DownloadViewController
            //   setupVersionCollectionView 注释——旧几何下日期标签被压到 ~8pt 高，
            //   文字溢出与版本号相碰 = “字体重叠”的布局层根因）
            [self.topRowStack.leadingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:14],
            [self.topRowStack.topAnchor constraintEqualToAnchor:self.cardContainer.topAnchor constant:13],
            [self.topRowStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.typeLabel.leadingAnchor constant:-8],

            // Task136/137：类型胶囊——右侧锚定 chevron 左侧 8pt（不贴卡片边缘），
            // 垂直居中于左侧两行文字块（版本号+日期），高 24（≈两行 12pt 字）
            [self.typeLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
            [self.typeLabel.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor],
            [self.typeLabel.heightAnchor constraintEqualToConstant:24],

            // 日期：与顶行 stack 左对齐，紧跟顶行下方 +2。
            // Task141：右侧改锚到 chevron 左侧 8pt（不再锚到顶行 stack 尾部——
            // 旧约束让日期宽度被短版本号拖窄，"2026年5月1日"被截成"2026-…"；
            // 贴齐卡片右缘后 12pt 日期完整显示，超出时缩字不截断）
            // ★ Task236：间距 3→2 + 底距 12→10 —— 配合行高 64→72 的垂直挤压
            //   根修（见 DownloadViewController setupVersionCollectionView 注释）：
            //   卡片 64pt 下内容链 13+19+2+14.3+10 ≈ 58.5pt，余量 ~5.5pt，
            //   日期标签不再被 Auto Layout 压到 8pt 高（旧几何文字溢出上下
            //   边界与版本号相碰 = "字体重叠"的布局层根因）。
            [self.dateLabel.leadingAnchor constraintEqualToAnchor:self.topRowStack.leadingAnchor],
            [self.dateLabel.topAnchor constraintEqualToAnchor:self.topRowStack.bottomAnchor constant:2],
            [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.chevronView.leadingAnchor constant:-8],
            [self.dateLabel.bottomAnchor constraintLessThanOrEqualToAnchor:self.cardContainer.bottomAnchor constant:-10],

            // chevron：右侧 -14，垂直居中，14x14
            [self.chevronView.trailingAnchor constraintEqualToAnchor:self.cardContainer.trailingAnchor constant:-14],
            [self.chevronView.centerYAnchor constraintEqualToAnchor:self.cardContainer.centerYAnchor],
            [self.chevronView.widthAnchor constraintEqualToConstant:14],
            [self.chevronView.heightAnchor constraintEqualToConstant:14],

            // 已安装徽章：贴在 iconContainer 右上角，14x14
            [self.installedBadge.topAnchor constraintEqualToAnchor:self.iconContainer.topAnchor constant:-4],
            [self.installedBadge.trailingAnchor constraintEqualToAnchor:self.iconContainer.trailingAnchor constant:4],
            [self.installedBadge.widthAnchor constraintEqualToConstant:14],
            [self.installedBadge.heightAnchor constraintEqualToConstant:14],
            [checkmark.centerXAnchor constraintEqualToAnchor:self.installedBadge.centerXAnchor],
            [checkmark.centerYAnchor constraintEqualToAnchor:self.installedBadge.centerYAnchor]
        ]];
    }
    return self;
}

- (void)configureWithVersionId:(NSString *)versionId
                          date:(NSString *)date
                          type:(NSString *)type {
    self.versionLabel.text = versionId;
    self.dateLabel.text = date;

    // 类型 → 图标 + 配色映射（参照 ZL2 的 VersionIconPreview 按版本类型切换图标）：
    // release → cube.fill + systemGreen（稳定版）
    // snapshot → hammer.fill + systemOrange（测试版/开发中）
    // old_alpha → clock.fill + systemPurple（远古 alpha）
    // old_beta  → clock.fill + systemPurple（远古 beta）
    NSString *iconName = @"cube.fill";
    UIColor *typeColor = [UIColor systemGreenColor];
    NSString *typeText = localize(@"i18n_str_2058", nil);

    if ([type isEqualToString:localize(@"ame193.misc.3", @"正式版")] || [type isEqualToString:@"release"]) {
        iconName = @"cube.fill";
        typeColor = [UIColor systemGreenColor];
        typeText = localize(@"i18n_str_2058", nil);
    } else if ([type isEqualToString:localize(@"ame193.misc.4", @"测试版")] || [type isEqualToString:@"snapshot"]) {
        iconName = @"hammer.fill";
        typeColor = [UIColor systemOrangeColor];
        typeText = localize(@"i18n_str_2059", nil);
    } else if ([type isEqualToString:@"old_alpha"]) {
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"Alpha";
    } else if ([type isEqualToString:@"old_beta"]) {
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = @"Beta";
    } else {
        // 兜底：远古版（合并 old_alpha + old_beta 时使用）
        iconName = @"clock.fill";
        typeColor = [UIColor systemPurpleColor];
        typeText = localize(@"i18n_str_154", nil);
    }

    UIImage *symbol = [UIImage systemImageNamed:iconName];
    if (symbol) {
        self.iconImageView.image = symbol;
    }
    self.iconImageView.tintColor = [UIColor whiteColor];

    // 修复问题4：使用 HMCL 仓库自带的标准草方块图标（grass.png/grass@2x.png），
    // 已导入 Assets.xcassets 的 VanillaIcon 图片集，与 FCL/ZL2/HMCL 等主流启动器视觉完全一致。
    // 图标铺满容器（AspectFill），背景透明以保留草方块纹理本色。
    UIImage *vanillaIcon = [UIImage imageNamed:@"VanillaIcon"];
    if (vanillaIcon) {
        self.iconImageView.image = vanillaIcon;
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFill;
        self.iconImageView.tintColor = nil; // 取消着色，显示草方块原色
        // 草方块图标自带色彩，图标容器背景设为透明
        self.iconContainer.backgroundColor = [UIColor clearColor];
    } else {
        // 兜底：图片集加载失败时回退 SF Symbol + 类型色背景
        self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
        self.iconImageView.tintColor = [UIColor whiteColor];
        self.iconContainer.backgroundColor = [typeColor colorWithAlphaComponent:0.85];
    }

    // 类型标签：类型色底 + 白字（Task137：尺寸随字体动态且不截断，见布局注释）
    self.typeLabel.text = typeText;
    self.typeLabel.backgroundColor = typeColor;
}

- (void)setInstalled:(BOOL)installed {
    self.installedBadge.hidden = !installed;
}

- (void)prepareForReuse {
    [super prepareForReuse];
    // 重置为 SF Symbol 默认状态（configureWithVersionId 会再次加载 VanillaIcon 覆盖）
    self.iconImageView.image = [UIImage systemImageNamed:@"cube.fill"];
    self.iconImageView.tintColor = [UIColor whiteColor];
    self.iconImageView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconContainer.backgroundColor = [UIColor systemGreenColor];
    self.versionLabel.text = nil;
    self.dateLabel.text = nil;
    self.typeLabel.text = nil;
    self.typeLabel.backgroundColor = [UIColor systemBlueColor];
    self.installedBadge.hidden = YES;
    self.chevronView.tintColor = [UIColor tertiaryLabelColor];
}

@end
