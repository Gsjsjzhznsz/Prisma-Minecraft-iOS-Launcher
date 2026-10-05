#import "Ame223CoachMarksView.h"
#import "utils.h"

@interface Ame223CoachMarksView ()
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, copy) void (^finish)(void);
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *bodyLabel;
@property (nonatomic, strong) UILabel *hintLabel;
@property (nonatomic, strong) CAShapeLayer *maskLayer;
@property (nonatomic, strong) CAShapeLayer *ringLayer;
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *activeConstraints;
@end

@implementation Ame223CoachMarksView

+ (CGRect)screenRectForView:(UIView *)view {
    if (view == nil || view.window == nil || CGRectIsEmpty(view.bounds)) {
        return CGRectNull;
    }
    return [view convertRect:view.bounds toView:nil];
}

+ (void)showSequence:(NSArray<NSDictionary *> *)items
          completion:(void(^)(void))completion {
    // 过滤无效锚点（RectNull / 离屏）
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (NSDictionary *it in items) {
        NSValue *v = it[@"rect"];
        if (![v isKindOfClass:NSValue.class]) continue;
        CGRect r = [v CGRectValue];
        if (CGRectIsNull(r) || CGRectIsEmpty(r)) continue;
        if (r.origin.x < -50 || r.origin.y < -50 ||
            r.origin.x > UIScreen.mainScreen.bounds.size.width + 50 ||
            r.origin.y > UIScreen.mainScreen.bounds.size.height + 50) continue;
        [valid addObject:it];
    }
    if (valid.count == 0) {
        if (completion) completion();
        return;
    }

    UIWindow *window = UIWindow.mainWindow;
    if (window == nil) {
        if (completion) completion();
        return;
    }
    Ame223CoachMarksView *marks = [[Ame223CoachMarksView alloc] initWithFrame:window.bounds];
    marks.items = valid;
    marks.finish = completion ?: ^{};
    marks.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:marks];
    [marks ame223_showIndex:0];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];

        // 镂空蒙版层（灰幕挖洞：全屏路径 - 圆/圆角矩形，奇偶填充）
        _maskLayer = [CAShapeLayer layer];
        _maskLayer.fillRule = kCAFillRuleEvenOdd;
        _maskLayer.fillColor = [UIColor blackColor].CGColor;
        _maskLayer.frame = frame;
        [self.layer addSublayer:_maskLayer];

        // 高亮呼吸圈
        _ringLayer = [CAShapeLayer layer];
        _ringLayer.fillColor = [UIColor clearColor].CGColor;
        _ringLayer.strokeColor = [UIColor colorWithRed:1.0 green:0.78 blue:0.24 alpha:1.0].CGColor;
        _ringLayer.lineWidth = 3.0;
        _ringLayer.shadowColor = [UIColor whiteColor].CGColor;
        _ringLayer.shadowOpacity = 0.7;
        _ringLayer.shadowRadius = 6.0;
        [self.layer addSublayer:_ringLayer];

        // 说明卡（标题 + 正文 + “点按继续”）
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.numberOfLines = 0;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];

        _bodyLabel = [[UILabel alloc] init];
        _bodyLabel.font = [UIFont systemFontOfSize:14];
        _bodyLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.85];
        _bodyLabel.numberOfLines = 0;
        _bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_bodyLabel];

        _hintLabel = [[UILabel alloc] init];
        _hintLabel.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
        _hintLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
        _hintLabel.textAlignment = NSTextAlignmentRight;
        _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_hintLabel];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(ame223_tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)ame223_showIndex:(NSUInteger)index {
    _index = index;
    NSDictionary *it = _items[index];
    CGRect r = [it[@"rect"] CGRectValue];
    BOOL round = it[@"round"] ? [it[@"round"] boolValue] : YES;

    // 镂空路径（屏幕坐标 → 本视图坐标：autoresizing 同尺寸，直接用）
    UIBezierPath *holePath = round
        ? [UIBezierPath bezierPathWithOvalInRect:CGRectInset(r, -10, -10)]
        : [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, -8, -8) cornerRadius:16];
    UIBezierPath * fullPath = [UIBezierPath bezierPathWithRect:self.bounds];
    [fullPath appendPath:holePath];
    _maskLayer.path = fullPath.CGPath;

    // 呼吸圈路径 + 线宽呼吸动画（全屏坐标 path；呼吸感用 lineWidth）
    UIBezierPath *ringPath = round
        ? [UIBezierPath bezierPathWithOvalInRect:CGRectInset(r, -12, -12)]
        : [UIBezierPath bezierPathWithRoundedRect:CGRectInset(r, -10, -10) cornerRadius:18];
    _ringLayer.frame = self.bounds;
    _ringLayer.path = ringPath.CGPath;
    [_ringLayer removeAnimationForKey:@"ame223_pulse"];
    CABasicAnimation *lw = [CABasicAnimation animationWithKeyPath:@"lineWidth"];
    lw.fromValue = @2.0;
    lw.toValue = @5.0;
    lw.duration = 0.9;
    lw.autoreverses = YES;
    lw.repeatCount = CGFLOAT_MAX;
    lw.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_ringLayer addAnimation:lw forKey:@"ame223_pulse"];

    // 说明卡位置：优先放在圆圈下方，不够放则放上方
    _titleLabel.text = it[@"title"];
    _bodyLabel.text = it[@"body"];
    _hintLabel.text = [NSString stringWithFormat:localize(@"coachmarks.hint", nil),
                       (unsigned long)(index + 1), (unsigned long)_items.count];

    [self setNeedsLayout];
    [self layoutIfNeeded];
    CGFloat const cardW = self.bounds.size.width - 48;
    CGSize titleSize = [_titleLabel sizeThatFits:CGSizeMake(cardW, CGFLOAT_MAX)];
    CGSize bodySize = [_bodyLabel sizeThatFits:CGSizeMake(cardW, CGFLOAT_MAX)];
    CGFloat cardH = titleSize.height + bodySize.height + 44;
    CGFloat cardY = CGRectGetMaxY(r) + 28;
    if (cardY + cardH > self.bounds.size.height - 24) {
        cardY = CGRectGetMinY(r) - cardH - 28;
        if (cardY < 24) cardY = 24;   // 兜底：贴顶
    }
    // Task223：仅作废自己持有的约束（UIKit 无全局 deactivateActive API）。
    if (self.activeConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.activeConstraints];
        self.activeConstraints = nil;
    }
    self.activeConstraints = @[
        [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:cardY],
        [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
        [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
        [_bodyLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:6],
        [_bodyLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:24],
        [_bodyLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
        [_hintLabel.topAnchor constraintEqualToAnchor:_bodyLabel.bottomAnchor constant:10],
        [_hintLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-24],
    ];
    [NSLayoutConstraint activateConstraints:self.activeConstraints];

    // 说明卡入场（淡入 + 轻微上浮）
    _titleLabel.alpha = 0;
    _bodyLabel.alpha = 0;
    _hintLabel.alpha = 0;
    CGAffineTransform base = _titleLabel.transform;
    [UIView animateWithDuration:0.35 delay:0.05 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        _titleLabel.alpha = 1;
        _bodyLabel.alpha = 1;
        _hintLabel.alpha = 1;
        _titleLabel.transform = CGAffineTransformTranslate(base, 0, -6);
    } completion:nil];
}

- (void)ame223_tapped {
    if (_index + 1 >= _items.count) {
        void (^finish)(void) = _finish;
        [UIView animateWithDuration:0.25 animations:^{ self.alpha = 0; }
                         completion:^(BOOL f) {
            [self removeFromSuperview];
            finish();
        }];
    } else {
        [self ame223_showIndex:_index + 1];
    }
}

@end
