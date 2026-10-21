//
//  PrismaFilledButton.m
//  Amethyst
//
//  Task314：PrismaUI 按钮实现。按压反馈采用 alpha/亮度微调（Fluent 2
//  按压态观感），不引入 iOS 15+ 专用 API。
//

#import "PrismaFilledButton.h"
#import "PrismaTheme.h"

@interface PrismaFilledButton ()
@property(nonatomic, assign) PrismaButtonStyle style;
@end

@implementation PrismaFilledButton

+ (instancetype)buttonWithTitle:(NSString *)title style:(PrismaButtonStyle)style {
    PrismaFilledButton *btn = [self buttonWithType:UIButtonTypeSystem];
    btn.style = style;
    [btn setTitle:title forState:UIControlStateNormal];
    [btn applyStyleTokens];
    return btn;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.style = PrismaButtonStyleFilled;
        [self applyStyleTokens];
        // 高度收敛为 Fluent 2 medium 控件档（intrinsic 高度兜底，
        // 显式约束由 caller 决定时以 40pt 为设计基准）
        [self setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    }
    return self;
}

- (void)setPrismaStyle:(PrismaButtonStyle)style {
    if (_style == style) return;
    _style = style;
    [self applyStyleTokens];
}

- (PrismaButtonStyle)prismaStyle {
    return _style;
}

/// 按令牌重算全套观感（初始化/切形态/明暗切换共用入口）。
- (void)applyStyleTokens {
    self.layer.cornerRadius = [PrismaTheme radiusControl];
    self.titleLabel.font = [PrismaTheme fontForRole:PrismaTextBody1];
    self.contentEdgeInsets = UIEdgeInsetsMake(0, [PrismaTheme spacingL], 0, [PrismaTheme spacingL]);

    UIColor *accent = [PrismaTheme colorAccent];
    switch (self.style) {
        case PrismaButtonStyleFilled:
            self.backgroundColor = accent;
            [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.layer.borderWidth = 0.0;
            break;
        case PrismaButtonStyleOutline:
            self.backgroundColor = [UIColor clearColor];
            [self setTitleColor:accent forState:UIControlStateNormal];
            self.layer.borderWidth = 1.0;
            self.layer.borderColor = accent.CGColor;
            break;
        case PrismaButtonStyleSubtle:
            self.backgroundColor = [UIColor clearColor];
            [self setTitleColor:accent forState:UIControlStateNormal];
            self.layer.borderWidth = 0.0;
            break;
    }
}

/// 明暗切换 / 强调色偏好变更时重算（系统会经 traitCollection 触达）。
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    [self applyStyleTokens];
}

/// 按压态：整体压暗一档（Fluent 2 pressed 观感的轻量实现）。
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    CGFloat alpha = highlighted ? 0.75 : 1.0;
    [UIView animateWithDuration:0.10 animations:^{
        self.alpha = alpha;
    }];
}

/// 设计基准高度 40pt（Fluent 2 medium）。
- (CGSize)intrinsicContentSize {
    CGSize s = [super intrinsicContentSize];
    return CGSizeMake(s.width + 2.0, MAX(40.0, s.height));
}

@end
