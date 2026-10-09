#import "Ame223CoachMarksView.h"
#import "utils.h"
#import "UIKit+hook.h"   // UIWindow.mainWindow 分类声明（同 NMToast/ControlJoystick 先例）
#import "LauncherPreferences.h"   // Task224 CI 修复 r1：accentColor() 声明（预检工具抓的头闭包缺口）

#pragma mark - item 字典键（集中声明，避免裸字符串散落）

static NSString * const ame224_kIcon  = @"icon";
static NSString * const ame224_kRect  = @"rect";
static NSString * const ame224_kTitle = @"title";
static NSString * const ame224_kBody  = @"body";
static NSString * const ame224_kRound = @"round";

@interface Ame223CoachMarksView () <UIGestureRecognizerDelegate>
/// 归一化后的页序列（特性页补 icon 键，锚点页保留 rect/round 键）。
@property (nonatomic, strong) NSArray<NSDictionary *> *items;
@property (nonatomic, assign) NSUInteger index;
@property (nonatomic, copy) void (^finish)(void);
/// 收尾防重入（Next 按钮与点按手势可能竞争）。
@property (nonatomic, assign) BOOL ame224_finishing;
/// 灰幕（黑色 45%，真半透明——反馈 #15 的“不透明黑”根治：旧版把不透明
/// 黑形状层画在幕上，本版幕本身就是唯一暗层，洞用 mask 挖出来）。
@property (nonatomic, strong) UIView *ame224_dimView;
/// 灰幕的镂空（dimView.layer.mask，奇偶填充：全屏 + 洞）。
@property (nonatomic, strong) CAShapeLayer *ame224_holeLayer;
/// 洞外圈呼吸光晕。
@property (nonatomic, strong) CAShapeLayer *ame224_ringLayer;
/// 特性页图标圆盘（锚点页隐藏；圆洞打在它身上）。
@property (nonatomic, strong) UIView *ame224_stage;
@property (nonatomic, strong) UIImageView *ame224_stageIcon;
/// 说明卡（毛玻璃 + 标题 + 正文）。
@property (nonatomic, strong) UIView *ame224_card;
@property (nonatomic, strong) UILabel *ame224_titleLabel;
@property (nonatomic, strong) UILabel *ame224_bodyLabel;
/// 页点 / 按钮。
@property (nonatomic, strong) UIStackView *ame224_dotRow;
@property (nonatomic, strong) UIButton *ame224_nextButton;
@property (nonatomic, strong) UIButton *ame224_skipButton;
/// 每页重建的约束（切页时先作废自己持有的这批）。
@property (nonatomic, strong) NSArray<NSLayoutConstraint *> *ame224_pageConstraints;
@end

@implementation Ame223CoachMarksView

+ (CGRect)screenRectForView:(UIView *)view {
    if (view == nil || view.window == nil || CGRectIsEmpty(view.bounds)) {
        return CGRectNull;
    }
    return [view convertRect:view.bounds toView:nil];
}

#pragma mark - 公共入口

+ (void)showSequence:(NSArray<NSDictionary *> *)items
          completion:(void(^)(void))completion {
    [self ame224_presentItems:items featureMode:NO completion:completion];
}

+ (void)showFeatureSequence:(NSArray<NSDictionary *> *)items
                 completion:(void(^)(void))completion {
    [self ame224_presentItems:items featureMode:YES completion:completion];
}

/// 统一入口：过滤无效项（锚点页验 rect，特性页验 icon）→ 挂主窗口。
+ (void)ame224_presentItems:(NSArray<NSDictionary *> *)items
                featureMode:(BOOL)featureMode
                 completion:(void(^)(void))completion {
    NSMutableArray<NSDictionary *> *valid = [NSMutableArray array];
    for (NSDictionary *it in items) {
        if (![it isKindOfClass:NSDictionary.class]) continue;
        NSString *ame224_title = [it[ame224_kTitle] isKindOfClass:NSString.class] ? it[ame224_kTitle] : nil;
        NSString *ame224_body = [it[ame224_kBody] isKindOfClass:NSString.class] ? it[ame224_kBody] : nil;
        if (featureMode) {
            NSString *ame224_icon = [it[ame224_kIcon] isKindOfClass:NSString.class] ? it[ame224_kIcon] : nil;
            if (ame224_icon.length == 0 || ame224_title.length == 0) continue;
            [valid addObject:@{
                ame224_kIcon: ame224_icon,
                ame224_kTitle: ame224_title,
                ame224_kBody: ame224_body ?: @"",
            }];
        } else {
            NSValue *ame224_v = [it[ame224_kRect] isKindOfClass:NSValue.class] ? it[ame224_kRect] : nil;
            NSString *ame224_title = [it[ame224_kTitle] isKindOfClass:NSString.class] ? it[ame224_kTitle] : nil;
            // ★ Task232（反馈 #14）：锚点页也要求非空标题——此前空标题锚点
            //   页会以“空卡片”呈现（用户看到“无文字介绍”）；没有可说的
            //   就不生成这一页。
            if (ame224_title.length == 0) continue;
            if (ame224_v == nil) continue;
            CGRect ame224_r = [ame224_v CGRectValue];
            if (CGRectIsNull(ame224_r) || CGRectIsEmpty(ame224_r)) continue;
            if (ame224_r.origin.x < -50 || ame224_r.origin.y < -50 ||
                ame224_r.origin.x > UIScreen.mainScreen.bounds.size.width + 50 ||
                ame224_r.origin.y > UIScreen.mainScreen.bounds.size.height + 50) continue;
            [valid addObject:@{
                ame224_kRect: ame224_v,
                ame224_kTitle: ame224_title ?: @"",
                ame224_kBody: ame224_body ?: @"",
                ame224_kRound: it[ame224_kRound] ?: @YES,
            }];
        }
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
    marks.ame224_stage.hidden = !featureMode;
    marks.finish = completion ?: ^{};
    marks.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:marks];
    marks.alpha = 0;
    [UIView animateWithDuration:0.3 animations:^{ marks.alpha = 1; }];
    [marks ame224_showIndex:0];
}

#pragma mark - 构建

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        // ★ Task230（反馈 #12）：整树豁免兜底——Task229 的单标签豁免保留，
        //   树级豁免覆盖本视图内未来新增的一切标签（卡片均实底自适应色）。
        {
            extern void ame230_setViewTreeStrokeExempt(UIView *, BOOL);
            ame230_setViewTreeStrokeExempt(self, YES);
        }

        // 灰幕：黑色 45%（透出下层——反馈 #15 “完全不透明”根治）
        _ame224_dimView = [[UIView alloc] initWithFrame:self.bounds];
        _ame224_dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _ame224_dimView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
        _ame224_dimView.userInteractionEnabled = NO;
        [self addSubview:_ame224_dimView];

        // 镂空：奇偶填充路径（全屏 + 洞）做 dim 的 layer.mask——洞内真透明
        _ame224_holeLayer = [CAShapeLayer layer];
        _ame224_holeLayer.fillRule = kCAFillRuleEvenOdd;
        _ame224_holeLayer.fillColor = [UIColor blackColor].CGColor;
        _ame224_dimView.layer.mask = _ame224_holeLayer;

        // 呼吸光晕圈
        _ame224_ringLayer = [CAShapeLayer layer];
        _ame224_ringLayer.fillColor = [UIColor clearColor].CGColor;
        _ame224_ringLayer.strokeColor = [UIColor colorWithRed:1.0 green:0.80 blue:0.35 alpha:1.0].CGColor;
        _ame224_ringLayer.lineWidth = 2.5;
        _ame224_ringLayer.shadowColor = [UIColor whiteColor].CGColor;
        _ame224_ringLayer.shadowOpacity = 0.65;
        _ame224_ringLayer.shadowRadius = 8.0;
        _ame224_ringLayer.shadowOffset = CGSizeZero;
        [self.layer addSublayer:_ame224_ringLayer];

        // 特性页图标圆盘（圆角连续的圆形毛玻璃 + 大号 SF Symbol）
        // ★ Task227（反馈 #10：圆圈焦点介绍显示空白）：stage/card 原为
        // UIVisualEffectView（SystemMaterial）——玻璃/背景管线的嵌套效
        // 果视图清理（LGCApplyGlassBackgroundToView 形制）与 iOS 27 组合
        // 下偶发整层不渲染（用户只见圆环不见内容）。改为实底自适应卡片：
        // systemBackground 0.94 + 发丝描边，任何管线下都稳定可读。
        _ame224_stage = [[UIView alloc] init];
        _ame224_stage.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.94];
        _ame224_stage.frame = CGRectMake(0, 0, 172, 172);
        _ame224_stage.layer.cornerRadius = 86;
        _ame224_stage.layer.cornerCurve = kCACornerCurveContinuous;
        _ame224_stage.layer.masksToBounds = YES;
        _ame224_stage.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.35].CGColor;
        _ame224_stage.layer.borderWidth = 1.0;
        _ame224_stage.userInteractionEnabled = NO;
        _ame224_stageIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles"]];
        _ame224_stageIcon.tintColor = accentColor();
        _ame224_stageIcon.contentMode = UIViewContentModeScaleAspectFit;
        _ame224_stageIcon.translatesAutoresizingMaskIntoConstraints = NO;
        [_ame224_stage addSubview:_ame224_stageIcon];
        [NSLayoutConstraint activateConstraints:@[
            [_ame224_stageIcon.centerXAnchor constraintEqualToAnchor:_ame224_stage.centerXAnchor],
            [_ame224_stageIcon.centerYAnchor constraintEqualToAnchor:_ame224_stage.centerYAnchor],
            [_ame224_stageIcon.widthAnchor constraintEqualToConstant:64],
            [_ame224_stageIcon.heightAnchor constraintEqualToConstant:64],
        ]];
        [self addSubview:_ame224_stage];

        // 说明卡（毛玻璃材质 + 24pt 连续圆角，iPadOS 26/27 卡语言）
        _ame224_card = [[UIView alloc] init];
        // ★ Task232（反馈 #14）：卡底 0.96 → 1.0 全实底 + 投影。
        //   ★ Task233（第四轮加固）：底色 systemBackground 在深色模式下是
        //   纯黑——与 45% 黑幕几乎同色，卡存在感趋零（浅色模式下白卡在
        //   压暗背景上倒是清晰）。改用 secondarySystemGroupedBackground
        //   （浅色 ≈ 白、深色 ≈ 深灰）：两种模式下卡都与幕布拉开层次，
        //   文字卡永远不会“融进背景”。masksToBounds 保持关闭放行投影。
        _ame224_card.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
        _ame224_card.layer.shadowColor = [UIColor blackColor].CGColor;
        _ame224_card.layer.shadowOpacity = 0.45;
        _ame224_card.layer.shadowRadius = 18.0;
        _ame224_card.layer.shadowOffset = CGSizeMake(0, 8);
        _ame224_card.layer.borderColor = [[UIColor separatorColor] colorWithAlphaComponent:0.6].CGColor;
        _ame224_card.layer.borderWidth = 0.5;
        _ame224_card.translatesAutoresizingMaskIntoConstraints = NO;
        _ame224_card.layer.cornerRadius = 24.0;
        _ame224_card.layer.cornerCurve = kCACornerCurveContinuous;
        _ame224_card.userInteractionEnabled = NO;
        [self addSubview:_ame224_card];

        _ame224_titleLabel = [[UILabel alloc] init];
        // Task229 (feedback #9: welcome tour showed blank cards): coach-mark
        // labels sit on SOLID adaptive cards -- the global white-fill/stroke
        // swizzle would paint them white-on-white (invisible). Opt out; the
        // exempted labels keep labelColor on the card background.
        extern void ame229_labelSetStrokeExempt(UILabel *, BOOL);
        ame229_labelSetStrokeExempt(_ame224_titleLabel, YES);
        _ame224_titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightBold];
        _ame224_titleLabel.textColor = [UIColor labelColor];
        _ame224_titleLabel.numberOfLines = 0;
        _ame224_titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [_ame224_card addSubview:_ame224_titleLabel];

        _ame224_bodyLabel = [[UILabel alloc] init];
        ame229_labelSetStrokeExempt(_ame224_bodyLabel, YES);   // Task229: see title label
        // ★ Task234（“文字依旧不显示”第五轮——静默了四轮的真根因）：body
        //   标签自 Task223 建类起就漏了 translatesAutoresizingMask=NO
        //   （title 标签一直有，故标题能显示）。骨架约束（top/leading/
        //   trailing/bottom/height≥34）与 autoresizing 掩码从【零初始帧】
        //   生成的四条必需约束同优先级冲突，求解器打破显式约束后正文恒为
        //   0x0 钉在卡片原点 = 标题在、介绍文字永不见（“无文字介绍”五连
        //   报的残留真凶）。前四轮修的锚点/透明度/z序都是真问题但都不是
        //   这一个。
        _ame224_bodyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _ame224_bodyLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        _ame224_bodyLabel.textColor = [UIColor secondaryLabelColor];
        _ame224_bodyLabel.numberOfLines = 0;
        [_ame224_card addSubview:_ame224_bodyLabel];

        // 页点行
        _ame224_dotRow = [[UIStackView alloc] init];
        _ame224_dotRow.axis = UILayoutConstraintAxisHorizontal;
        _ame224_dotRow.spacing = 8;
        _ame224_dotRow.userInteractionEnabled = NO;
        _ame224_dotRow.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_ame224_dotRow];

        // Next（胶囊主色）与 Skip（右上角描边胶囊）
        _ame224_nextButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _ame224_nextButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        [_ame224_nextButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _ame224_nextButton.backgroundColor = accentColor();
        _ame224_nextButton.layer.cornerRadius = 24;
        _ame224_nextButton.layer.cornerCurve = kCACornerCurveContinuous;
        _ame224_nextButton.contentEdgeInsets = UIEdgeInsetsMake(0, 34, 0, 34);
        [_ame224_nextButton addTarget:self action:@selector(ame224_nextTapped)
                     forControlEvents:UIControlEventTouchUpInside];
        _ame224_nextButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_ame224_nextButton];

        _ame224_skipButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _ame224_skipButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        [_ame224_skipButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _ame224_skipButton.layer.cornerRadius = 17;
        _ame224_skipButton.layer.cornerCurve = kCACornerCurveContinuous;
        _ame224_skipButton.layer.borderColor = [[UIColor whiteColor] colorWithAlphaComponent:0.55].CGColor;
        _ame224_skipButton.layer.borderWidth = 1.0;
        _ame224_skipButton.contentEdgeInsets = UIEdgeInsetsMake(6, 16, 6, 16);
        [_ame224_skipButton addTarget:self action:@selector(ame224_skipTapped)
                     forControlEvents:UIControlEventTouchUpInside];
        _ame224_skipButton.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_ame224_skipButton];

        // 常驻骨架约束（卡片内文字 + 圆盘内图标 + 按钮位置）
        [NSLayoutConstraint activateConstraints:@[
            [_ame224_titleLabel.topAnchor constraintEqualToAnchor:_ame224_card.topAnchor constant:18],
            [_ame224_titleLabel.leadingAnchor constraintEqualToAnchor:_ame224_card.leadingAnchor constant:20],
            [_ame224_titleLabel.trailingAnchor constraintEqualToAnchor:_ame224_card.trailingAnchor constant:-20],
            [_ame224_bodyLabel.topAnchor constraintEqualToAnchor:_ame224_titleLabel.bottomAnchor constant:6],
            [_ame224_bodyLabel.leadingAnchor constraintEqualToAnchor:_ame224_card.leadingAnchor constant:20],
            [_ame224_bodyLabel.trailingAnchor constraintEqualToAnchor:_ame224_card.trailingAnchor constant:-20],
            [_ame224_bodyLabel.bottomAnchor constraintEqualToAnchor:_ame224_card.bottomAnchor constant:-18],
            [_ame224_bodyLabel.heightAnchor constraintGreaterThanOrEqualToConstant:34],

            [_ame224_nextButton.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_ame224_nextButton.widthAnchor constraintGreaterThanOrEqualToConstant:190],
            [_ame224_nextButton.heightAnchor constraintEqualToConstant:48],
            [_ame224_dotRow.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_ame224_dotRow.topAnchor constraintEqualToAnchor:_ame224_nextButton.topAnchor constant:-22],
            [_ame224_dotRow.heightAnchor constraintEqualToConstant:8],
            [_ame224_skipButton.topAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.topAnchor constant:10],
            [_ame224_skipButton.trailingAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.trailingAnchor constant:-16],
            [_ame224_skipButton.heightAnchor constraintEqualToConstant:34],
        ]];

        // 点按任意处前进（zl2 引导层惯例；按钮优先命中——控件上的触点
        // 不进手势，交给 UIControl 自己分发，Skip 不会被误吃成翻页）
        UITapGestureRecognizer *ame224_tap = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(ame224_nextTapped)];
        ame224_tap.delegate = self;
        [self addGestureRecognizer:ame224_tap];
    }
    return self;
}

/// 控件（Next/Skip 按钮）上的触点不进“点按任意处”手势。
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if ([touch.view isKindOfClass:UIControl.class]) return NO;
    return YES;
}

#pragma mark - 翻页

- (void)ame224_showIndex:(NSUInteger)index {
    _index = index;
    NSDictionary *it = _items[index];
    BOOL ame224_last = (index + 1 >= _items.count);

    // ---- 焦点区域：特性页 = 圆盘 frame；锚点页 = 传入 rect ----
    CGRect ame224_spot = CGRectNull;
    BOOL ame224_round = YES;
    if (_ame224_stage.hidden) {
        ame224_spot = [it[ame224_kRect] CGRectValue];
        ame224_round = it[ame224_kRound] ? [it[ame224_kRound] boolValue] : YES;
    } else {
        CGFloat ame224_d = CGRectGetWidth(_ame224_stage.bounds);
        CGFloat ame224_top = floor(self.bounds.size.height * 0.20);
        _ame224_stage.center = CGPointMake(self.bounds.size.width / 2.0, ame224_top + ame224_d / 2.0);
        ame224_spot = _ame224_stage.frame;
        UIImage *ame224_img = [UIImage systemImageNamed:it[ame224_kIcon]];
        if (ame224_img == nil) ame224_img = [UIImage systemImageNamed:@"sparkles"];
        _ame224_stageIcon.image = ame224_img;
    }

    // ---- 镂空路径（幕上挖洞）+ 光晕圈路径，切页时做路径动画 ----
    UIBezierPath *ame224_hole = ame224_round
        ? [UIBezierPath bezierPathWithOvalInRect:CGRectInset(ame224_spot, -12, -12)]
        : [UIBezierPath bezierPathWithRoundedRect:CGRectInset(ame224_spot, -10, -10) cornerRadius:20];
    UIBezierPath *ame224_full = [UIBezierPath bezierPathWithRect:self.bounds];
    [ame224_full appendPath:ame224_hole];
    CGPathRef ame224_oldHole = _ame224_holeLayer.path;
    _ame224_holeLayer.frame = self.bounds;
    _ame224_holeLayer.path = ame224_full.CGPath;
    _ame224_ringLayer.frame = self.bounds;
    _ame224_ringLayer.path = ame224_hole.CGPath;
    if (ame224_oldHole != NULL) {
        // 同构路径（5 段指令）可插值：洞从上一页位置滑到本页
        CABasicAnimation *ame224_move = [CABasicAnimation animationWithKeyPath:@"path"];
        ame224_move.fromValue = (__bridge id)ame224_oldHole;
        ame224_move.toValue = (__bridge id)ame224_full.CGPath;
        ame224_move.duration = 0.38;
        ame224_move.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_ame224_holeLayer addAnimation:ame224_move forKey:@"ame224_hole_move"];
    }
    // 光晕呼吸（线宽 2.0 - 5.0 往复）
    [_ame224_ringLayer removeAnimationForKey:@"ame224_pulse"];
    CABasicAnimation *ame224_pulse = [CABasicAnimation animationWithKeyPath:@"lineWidth"];
    ame224_pulse.fromValue = @2.0;
    ame224_pulse.toValue = @5.0;
    ame224_pulse.duration = 0.9;
    ame224_pulse.autoreverses = YES;
    ame224_pulse.repeatCount = CGFLOAT_MAX;
    ame224_pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_ame224_ringLayer addAnimation:ame224_pulse forKey:@"ame224_pulse"];

    // ---- 文案 + 按钮 + 页点 ----
    _ame224_titleLabel.text = it[ame224_kTitle];
    _ame224_bodyLabel.text = it[ame224_kBody];
    // ★ Task233（第四轮加固）：文字可见性零动画依赖——旧版 alpha 0→1 动画
    //   若被打断/被批渲染异常，模型值虽为 1 但任何链路跟疵都会把“无文字”
    //   放大；直接可见，仅保留卡的上浮弹入动效。
    _ame224_titleLabel.alpha = 1.0;
    _ame224_bodyLabel.alpha = 1.0;
    _ame224_titleLabel.hidden = NO;
    _ame224_bodyLabel.hidden = NO;
    _ame224_card.hidden = NO;
    [_ame224_nextButton setTitle:localize(ame224_last ? @"coachmarks.done" : @"coachmarks.next", nil)
                         forState:UIControlStateNormal];
    [_ame224_skipButton setTitle:localize(@"coachmarks.skip", nil) forState:UIControlStateNormal];
    _ame224_skipButton.hidden = ame224_last;

    while (_ame224_dotRow.arrangedSubviews.count > 0) {
        UIView *ame224_oldDot = _ame224_dotRow.arrangedSubviews.lastObject;
        [_ame224_dotRow removeArrangedSubview:ame224_oldDot];
        [ame224_oldDot removeFromSuperview];   // removeArrangedSubview 不移除 subview，防止页点累积
    }
    for (NSUInteger i = 0; i < _items.count; i++) {
        UIView *ame224_dot = [[UIView alloc] init];
        ame224_dot.backgroundColor = (i == index)
            ? [UIColor whiteColor]
            : [[UIColor whiteColor] colorWithAlphaComponent:0.35];
        ame224_dot.layer.cornerRadius = 4;
        ame224_dot.layer.cornerCurve = kCACornerCurveContinuous;
        ame224_dot.translatesAutoresizingMaskIntoConstraints = NO;
        [_ame224_dotRow addArrangedSubview:ame224_dot];
        [ame224_dot.widthAnchor constraintEqualToConstant:8].active = YES;
        [ame224_dot.heightAnchor constraintEqualToConstant:8].active = YES;
    }

    // ---- 说明卡位置：焦点下方优先，放不下则上方 ----
    [self setNeedsLayout];
    [self layoutIfNeeded];
    CGFloat ame224_maxW = MIN(self.bounds.size.width - 32, 460);
    CGSize ame224_titleSize = [_ame224_titleLabel sizeThatFits:CGSizeMake(ame224_maxW - 40, CGFLOAT_MAX)];
    CGSize ame224_bodySize = [_ame224_bodyLabel sizeThatFits:CGSizeMake(ame224_maxW - 40, CGFLOAT_MAX)];
    // 正文有 ≥34pt 的内部约束（空文案也有呼吸空间）——卡高同步取 MAX 防冲突
    CGFloat ame224_bodyH = MAX(ame224_bodySize.height, 34);
    CGFloat ame224_cardH = ame224_titleSize.height + ame224_bodyH + 42;
    CGFloat ame224_cardW = MIN(ame224_maxW, MAX(280, MAX(ame224_titleSize.width, ame224_bodySize.width) + 40));
    CGFloat ame224_cardY = CGRectGetMaxY(ame224_spot) + 32;
    if (ame224_cardY + ame224_cardH > self.bounds.size.height - 110) {
        ame224_cardY = MAX(24, CGRectGetMinY(ame224_spot) - ame224_cardH - 32);
    }
    // ★ Task227：巨型语义区域锚点（Task226 加入的整区 rect）会把上方回退
    // 位也顶出屏（spot 高达 42% 屏高）。双端钳制：卡永远完整落在屏内、
    // 且不与 Next 按钮带（底部 110pt）重叠。
    ame224_cardY = MIN(ame224_cardY, self.bounds.size.height - 110 - ame224_cardH);
    ame224_cardY = MAX(24, ame224_cardY);

    // 仅作废自己持有的页约束（UIKit 无全局 deactivateActive API）
    if (self.ame224_pageConstraints.count > 0) {
        [NSLayoutConstraint deactivateConstraints:self.ame224_pageConstraints];
        self.ame224_pageConstraints = nil;
    }
    // ★ Task232（反馈 #14）：每页取证——洞/卡矩形 + 文案长度落日志，
    //   下一轮装机日志直接区分“卡在屏外”还是“文案为空”。
    NSLog(@"[CoachMarks] Task232 page %lu/%lu: spot=%@ titleLen=%lu bodyLen=%lu cardY=%.0f cardH=%.0f self=%@",
          (unsigned long)index + 1, (unsigned long)_items.count,
          NSStringFromCGRect(ame224_spot),
          (unsigned long)[(it[ame224_kTitle] ?: @"") length],
          (unsigned long)[(it[ame224_kBody] ?: @"") length],
          ame224_cardY, ame224_cardH, NSStringFromCGRect(self.bounds));
    self.ame224_pageConstraints = @[
        [_ame224_nextButton.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-18],
        [_ame224_card.topAnchor constraintEqualToAnchor:self.topAnchor constant:ame224_cardY],
        [_ame224_card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_ame224_card.widthAnchor constraintEqualToConstant:ame224_cardW],
        [_ame224_card.heightAnchor constraintEqualToConstant:ame224_cardH],
    ];
    [NSLayoutConstraint activateConstraints:self.ame224_pageConstraints];

    // ★ Task233（第四轮加固）：文字卡/按钮每页强制置顶——挂窗子视图可能被
    //   其他层（玻璃/覆盖层）压住，显式 bringSubviewToFront 消除任何
    //   z 序不确定性；随后强制布局并验证卡在窗口内（越界即钉回屏内）。
    [self bringSubviewToFront:_ame224_dimView];
    [self bringSubviewToFront:_ame224_stage];
    [self bringSubviewToFront:_ame224_card];
    [self bringSubviewToFront:_ame224_dotRow];
    [self bringSubviewToFront:_ame224_nextButton];
    [self bringSubviewToFront:_ame224_skipButton];
    [self setNeedsLayout];
    [self layoutIfNeeded];
    {
        CGRect ame233_cardFrame = _ame224_card.frame;
        if (CGRectIsEmpty(ame233_cardFrame) ||
            CGRectGetMaxY(ame233_cardFrame) > self.bounds.size.height + 1 ||
            ame233_cardFrame.origin.y < -1) {
            NSLog(@"[CoachMarks] Task233 card frame abnormal after layout: %@ (self=%@) -- forcing centered fallback",
                  NSStringFromCGRect(ame233_cardFrame), NSStringFromCGRect(self.bounds));
            [NSLayoutConstraint deactivateConstraints:self.ame224_pageConstraints];
            CGFloat ame233_fixH = MIN(ame224_cardH, self.bounds.size.height - 140);
            self.ame224_pageConstraints = @[
                [_ame224_nextButton.bottomAnchor constraintEqualToAnchor:self.safeAreaLayoutGuide.bottomAnchor constant:-18],
                [_ame224_card.topAnchor constraintEqualToAnchor:self.topAnchor constant:MAX(24, ame224_cardY)],
                [_ame224_card.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
                [_ame224_card.widthAnchor constraintEqualToConstant:ame224_cardW],
                [_ame224_card.heightAnchor constraintEqualToConstant:MAX(ame233_fixH, 80)],
            ];
            [NSLayoutConstraint activateConstraints:self.ame224_pageConstraints];
            [self layoutIfNeeded];
        }
    }
    // ★ Task234：布局后帧取证——卡/标题/正文最终 frame 落日志，下一轮装机
    //   日志直接验证“正文 0x0”根因修复（body 恒为 0x0 即约束仍冲突）。
    NSLog(@"[CoachMarks] Task234 post-layout: card=%@ title=%@ body=%@",
          NSStringFromCGRect(_ame224_card.frame),
          NSStringFromCGRect(_ame224_titleLabel.frame),
          NSStringFromCGRect(_ame224_bodyLabel.frame));

    // 入场（卡上浮弹入；文字恒可见——Task233 去除 alpha 依赖）。
    // Task233：transform 每页先归零——旧版以【当前 transform】为基数累加
    // -6pt，5 页累计 -30pt 上漂（约束定位被视觉偏移吃掉）。
    _ame224_card.transform = CGAffineTransformIdentity;
    [UIView animateWithDuration:0.35 delay:0.05 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        _ame224_card.transform = CGAffineTransformMakeTranslation(0, -6);
    } completion:nil];
}

#pragma mark - 交互

- (void)ame224_nextTapped {
    if (self.hidden || self.ame224_finishing) return;
    if (_index + 1 >= _items.count) {
        [self ame224_finishNow];
    } else {
        [self ame224_showIndex:_index + 1];
    }
}

- (void)ame224_skipTapped {
    [self ame224_finishNow];
}

- (void)ame224_finishNow {
    if (self.ame224_finishing) return;
    self.ame224_finishing = YES;
    void (^ame224_finish)(void) = _finish;
    _finish = nil;   // 防重入（Next 与点按手势可能竞争）
    [UIView animateWithDuration:0.28 animations:^{ self.alpha = 0; }
                     completion:^(BOOL ame224_done) {
        [self removeFromSuperview];
        if (ame224_finish) ame224_finish();
    }];
}

@end
