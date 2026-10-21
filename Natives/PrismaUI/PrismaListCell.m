//
//  PrismaListCell.m
//  Amethyst
//
//  Task314：PrismaUI 列表项实现。
//

#import "PrismaListCell.h"
#import "PrismaTheme.h"

@interface PrismaListCell ()
@property(nonatomic, strong) UIView *iconContainer;        ///< 32×32 圆角图标槽
@property(nonatomic, strong) UIImageView *iconView;
@property(nonatomic, strong) UILabel *titleLabel;
@property(nonatomic, strong) UILabel *subtitleLabel;
@property(nonatomic, strong) UIImageView *chevronView;
// 纵向双态约束组（各建一次，切换只动 active/constant，防累积防歧义）：
@property(nonatomic, strong) NSLayoutConstraint *titleCenterYConstraint; ///< 单行态：标题垂直居中
@property(nonatomic, strong) NSLayoutConstraint *titleTopConstraint;     ///< 双行态：标题钉顶
@property(nonatomic, strong) NSLayoutConstraint *heightConstraint;       ///< 行高兜底 44/56
@end

@implementation PrismaListCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _iconContainer = [[UIView alloc] init];
        _iconContainer.translatesAutoresizingMaskIntoConstraints = NO;
        _iconContainer.layer.cornerRadius = [PrismaTheme radiusControl];
        _iconContainer.backgroundColor = [PrismaTheme colorAccentSelectedBackground];
        _iconContainer.hidden = YES;
        [self.contentView addSubview:_iconContainer];

        _iconView = [[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        [_iconContainer addSubview:_iconView];

        _titleLabel = [[UILabel alloc] init];
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _titleLabel.numberOfLines = 1;
        [self.contentView addSubview:_titleLabel];

        _subtitleLabel = [[UILabel alloc] init];
        _subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _subtitleLabel.numberOfLines = 1;
        _subtitleLabel.hidden = YES;
        [self.contentView addSubview:_subtitleLabel];

        _chevronView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
        _chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        _chevronView.contentMode = UIViewContentModeScaleAspectFit;
        [self.contentView addSubview:_chevronView];

        [self installConstraints];
        [self refreshTheme];
    }
    return self;
}

- (void)installConstraints {
    CGFloat pad = [PrismaTheme spacingL];
    CGFloat iconSlot = 32.0;

    _titleCenterYConstraint = [_titleLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor];
    _titleTopConstraint = [_titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                                                constant:[PrismaTheme spacingM]];
    _titleTopConstraint.active = NO;  // 默认单行态
    _titleCenterYConstraint.active = YES;
    _heightConstraint = [self.contentView.heightAnchor constraintEqualToConstant:44.0];
    _heightConstraint.priority = UILayoutPriorityDefaultHigh;  // caller 显式行高可覆盖

    [NSLayoutConstraint activateConstraints:@[
        _heightConstraint,

        [_iconContainer.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:pad],
        [_iconContainer.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_iconContainer.widthAnchor constraintEqualToConstant:iconSlot],
        [_iconContainer.heightAnchor constraintEqualToConstant:iconSlot],

        [_iconView.centerXAnchor constraintEqualToAnchor:_iconContainer.centerXAnchor],
        [_iconView.centerYAnchor constraintEqualToAnchor:_iconContainer.centerYAnchor],
        [_iconView.widthAnchor constraintEqualToConstant:18.0],
        [_iconView.heightAnchor constraintEqualToConstant:18.0],

        _titleCenterYConstraint,
        _titleTopConstraint,
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:pad],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor
                                                             constant:-pad - 20.0],

        [_subtitleLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:2.0],
        [_subtitleLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
        [_subtitleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor
                                                                constant:-pad],
        [_subtitleLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                    constant:-[PrismaTheme spacingM]],

        [_chevronView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-pad],
        [_chevronView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_chevronView.widthAnchor constraintEqualToConstant:12.0],
        [_chevronView.heightAnchor constraintEqualToConstant:16.0],
    ]];
}

/// 单行/双行纵向布局切换（refreshTheme 与副标题 setter 共用入口）。
- (void)updateVerticalLayout {
    BOOL singleLine = self.subtitleLabel.hidden;
    _titleCenterYConstraint.active = singleLine;
    _titleTopConstraint.active = !singleLine;
    _heightConstraint.constant = singleLine ? 44.0 : 56.0;
}

- (void)setPrismaTitle:(NSString *)prismaTitle {
    _prismaTitle = [prismaTitle copy];
    self.titleLabel.text = _prismaTitle;
}

- (void)setPrismaSubtitle:(NSString *)prismaSubtitle {
    _prismaSubtitle = [prismaSubtitle copy];
    self.subtitleLabel.text = _prismaSubtitle;
    self.subtitleLabel.hidden = (_prismaSubtitle.length == 0);
    [self updateVerticalLayout];
}

- (void)setPrismaIconName:(NSString *)prismaIconName {
    _prismaIconName = [prismaIconName copy];
    UIImage *icon = _prismaIconName.length ? [UIImage systemImageNamed:_prismaIconName] : nil;
    self.iconView.image = icon;
    self.iconContainer.hidden = (icon == nil);
}

- (void)setShowsChevron:(BOOL)showsChevron {
    _showsChevron = showsChevron;
    self.chevronView.hidden = !showsChevron;
}

- (void)setIconTintedWithAccent:(BOOL)iconTintedWithAccent {
    _iconTintedWithAccent = iconTintedWithAccent;
    [self refreshTheme];
}

- (void)refreshTheme {
    self.titleLabel.font = [PrismaTheme fontForRole:PrismaTextBody1];
    self.titleLabel.textColor = [PrismaTheme colorTextPrimary];

    self.subtitleLabel.font = [PrismaTheme fontForRole:PrismaTextCaption1];
    self.subtitleLabel.textColor = [PrismaTheme colorTextTertiary];

    self.iconContainer.backgroundColor = [PrismaTheme colorAccentSelectedBackground];
    self.iconView.tintColor = self.iconTintedWithAccent ? [PrismaTheme colorAccent]
                                                        : [PrismaTheme colorTextSecondary];
    self.chevronView.tintColor = [PrismaTheme colorTextTertiary];

    [self updateVerticalLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self refreshTheme];
}

/// 设计基准高：单行 44 / 双行 56（供 caller 估算行高）。
- (CGSize)sizeThatFits:(CGSize)size {
    return CGSizeMake(size.width, self.subtitleLabel.hidden ? 44.0 : 56.0);
}

@end
