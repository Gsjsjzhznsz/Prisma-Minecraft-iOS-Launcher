//
//  PrismaCardView.m
//  Amethyst
//
//  Task314：PrismaUI 卡片实现。
//

#import "PrismaCardView.h"
#import "PrismaTheme.h"

@interface PrismaCardView ()
@property(nonatomic, strong) UIView *strokeContainer;  ///< 圆角+描边层（内容承载）
@end

@implementation PrismaCardView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _elevation = PrismaElevationNone;
        _showsStroke = YES;

        self.backgroundColor = [UIColor clearColor];

        _strokeContainer = [[UIView alloc] init];
        _strokeContainer.translatesAutoresizingMaskIntoConstraints = NO;
        _strokeContainer.layer.cornerRadius = [PrismaTheme radiusSurface];
        _strokeContainer.layer.masksToBounds = YES;  // 内容圆角裁剪在此层
        _strokeContainer.userInteractionEnabled = YES;
        [self addSubview:_strokeContainer];

        // contentView：留给 caller 布局子视图的容器（自身透明）
        _contentView = [[UIView alloc] init];
        _contentView.translatesAutoresizingMaskIntoConstraints = NO;
        _contentView.backgroundColor = [UIColor clearColor];
        [_strokeContainer addSubview:_contentView];

        [NSLayoutConstraint activateConstraints:@[
            [_strokeContainer.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_strokeContainer.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_strokeContainer.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_strokeContainer.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],

            [_contentView.topAnchor constraintEqualToAnchor:_strokeContainer.topAnchor],
            [_contentView.bottomAnchor constraintEqualToAnchor:_strokeContainer.bottomAnchor],
            [_contentView.leadingAnchor constraintEqualToAnchor:_strokeContainer.leadingAnchor],
            [_contentView.trailingAnchor constraintEqualToAnchor:_strokeContainer.trailingAnchor],
        ]];

        [self refreshTheme];
    }
    return self;
}

- (void)setShowsStroke:(BOOL)showsStroke {
    _showsStroke = showsStroke;
    [self refreshTheme];
}

- (void)setElevation:(PrismaElevation)elevation {
    _elevation = elevation;
    [PrismaTheme applyElevation:elevation toLayer:self.layer];
}

- (void)refreshTheme {
    self.strokeContainer.backgroundColor = [PrismaTheme colorCard];
    if (self.showsStroke) {
        self.strokeContainer.layer.borderWidth = 1.0 / [UIScreen mainScreen].scale;  // hairline
        self.strokeContainer.layer.borderColor = [PrismaTheme colorStroke].CGColor;
    } else {
        self.strokeContainer.layer.borderWidth = 0.0;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self refreshTheme];
}

@end
