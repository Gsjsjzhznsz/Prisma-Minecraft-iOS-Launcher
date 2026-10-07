//
//  GameMenuOverlayView.m
//  Amethyst
//
//  参照 FCL MenuView.java 与 ZL2 GameScreen.kt 实现
//  关键改进：hitTest 穿透，只有按钮/标签区域拦截触摸，其他区域穿透到游戏画面
//

#import "GameMenuOverlayView.h"
#import "LauncherPreferences.h"

// 位置持久化的 pref key
static NSString *const kPrefMenuButtonX = @"game.menu_button_x";
static NSString *const kPrefMenuButtonY = @"game.menu_button_y";
static NSString *const kPrefStatsLabelX = @"game.stats_label_x";
static NSString *const kPrefStatsLabelY = @"game.stats_label_y";
// FPS/内存显示开关的 pref key
static NSString *const kPrefStatsLabelVisible = @"game.stats_label_visible";

// 按钮尺寸
static const CGFloat kMenuButtonSize = 44.0;
// 拖拽阈值：超过此距离算拖动，否则算点击（参照 FCL MenuView 的 10px 阈值）
static const CGFloat kDragThreshold = 10.0;

@interface GameMenuOverlayView ()

// 设置按钮（圆形）
@property (nonatomic, strong) UIButton *menuButton;
// FPS/内存显示标签
@property (nonatomic, strong) UILabel *statsLabel;
// 拖拽相关状态
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) CGPoint dragStartPoint;
@property (nonatomic, assign) CGPoint dragStartCenter;

@end

@implementation GameMenuOverlayView

- (instancetype)initWithParentView:(UIView *)parentView {
    self = [super initWithFrame:parentView.bounds];
    if (self) {
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.backgroundColor = [UIColor clearColor];
        // 关键：userInteractionEnabled = YES 让子视图能响应触摸
        // 但 hitTest 会过滤掉非按钮/标签区域的触摸，让其穿透到游戏画面
        self.userInteractionEnabled = YES;
        // 默认显示 FPS/内存标签（可通过菜单开关）
        _statsLabelVisible = YES;
        _overlayHidden = NO;

        // 从偏好加载 FPS/内存显示开关状态
        NSNumber *savedVisible = getPrefObject(kPrefStatsLabelVisible);
        if (savedVisible) {
            _statsLabelVisible = [savedVisible boolValue];
        }

        [self setupMenuButton];
        [self setupStatsLabel];
        [parentView addSubview:self];

        [self restorePositions];
        [self applyStatsLabelVisibility];
    }
    return self;
}

- (void)setupMenuButton {
    self.menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.menuButton.frame = CGRectMake(0, 0, kMenuButtonSize, kMenuButtonSize);
    self.menuButton.layer.cornerRadius = kMenuButtonSize / 2;
    // 半透明深色背景，确保在游戏画面上可见
    self.menuButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.6];
    self.menuButton.layer.borderWidth = 1.5;
    self.menuButton.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.4].CGColor;
    // 参照 FCL：使用设置图标（gearshape）
    UIImage *icon = [UIImage systemImageNamed:@"gearshape.fill"]
                    ?: [UIImage systemImageNamed:@"gear"];
    [self.menuButton setImage:icon forState:UIControlStateNormal];
    self.menuButton.tintColor = [UIColor whiteColor];
    // 使用纯 frame 布局（不用 auto layout），因为按钮位置通过 center 手动设置并持久化
    // 不设置 translatesAutoresizingMaskIntoConstraints = NO，保持默认 YES，避免无约束导致 frame 不确定
    // 确保按钮能响应触摸
    self.menuButton.userInteractionEnabled = YES;

    // 添加拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuButtonPan:)];
    pan.minimumNumberOfTouches = 1;
    [self.menuButton addGestureRecognizer:pan];

    // 点击事件
    [self.menuButton addTarget:self action:@selector(menuButtonTouchedDown:) forControlEvents:UIControlEventTouchDown];
    [self.menuButton addTarget:self action:@selector(menuButtonTouchedUp:) forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:self.menuButton];
}

- (void)setupStatsLabel {
    self.statsLabel = [[UILabel alloc] init];
    self.statsLabel.text = @"FPS: -- | MEM: --";
    self.statsLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightBold];
    self.statsLabel.textColor = [UIColor whiteColor];
    self.statsLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5];
    self.statsLabel.layer.cornerRadius = 4;
    self.statsLabel.layer.masksToBounds = YES;
    self.statsLabel.textAlignment = NSTextAlignmentCenter;
    self.statsLabel.numberOfLines = 1;
    // 使用纯 frame 布局，位置通过 center 手动设置并持久化
    self.statsLabel.frame = CGRectMake(0, 0, 130, 24);
    // Task214（用户："窗口太窄，一直显示成 MEM: 328…"）：固定 130pt 宽度装不下
    // 长统计串时曾被 tail 截断成省略号；改按宽度自动缩字（最小缩到 50%）
    // —— 显示不下就缩小，而不是省略。
    self.statsLabel.adjustsFontSizeToFitWidth = YES;
    self.statsLabel.minimumScaleFactor = 0.5;

    // 拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleStatsLabelPan:)];
    [self.statsLabel addGestureRecognizer:pan];
    self.statsLabel.userInteractionEnabled = YES;

    [self addSubview:self.statsLabel];
}

#pragma mark - hitTest 穿透（关键：让触摸穿透到游戏画面）

/// 重写 hitTest:withEvent: 实现：只有 menuButton 和 statsLabel 的区域拦截触摸，
/// 其他区域返回 nil，让触摸穿透到下面的游戏画面（surfaceView/ctrlView）
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || !self.userInteractionEnabled || self.overlayHidden) {
        return nil;
    }
    // 检查 menuButton 是否包含触摸点
    if (self.menuButton && !self.menuButton.hidden && self.menuButton.userInteractionEnabled) {
        CGPoint btnPoint = [self convertPoint:point toView:self.menuButton];
        if (CGRectContainsPoint(self.menuButton.bounds, btnPoint)) {
            return [self.menuButton hitTest:btnPoint withEvent:event];
        }
    }
    // 检查 statsLabel 是否包含触摸点（且可见）
    if (self.statsLabel && !self.statsLabel.hidden && self.statsLabelVisible && self.statsLabel.userInteractionEnabled) {
        CGPoint labelPoint = [self convertPoint:point toView:self.statsLabel];
        if (CGRectContainsPoint(self.statsLabel.bounds, labelPoint)) {
            return [self.statsLabel hitTest:labelPoint withEvent:event];
        }
    }
    // 其他区域返回 nil，触摸穿透到游戏画面
    return nil;
}

#pragma mark - 位置持久化

- (void)restorePositions {
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;

    // 设置按钮默认位置：右上角偏下（避开状态栏和右上角控件）
    CGFloat defaultBtnX = bw - kMenuButtonSize - 20;
    CGFloat defaultBtnY = bh * 0.3;

    // 哨兵值 -1 表示未设置（PLPreferences 默认值），回退到硬编码默认位置
    NSNumber *savedX = getPrefObject(kPrefMenuButtonX);
    NSNumber *savedY = getPrefObject(kPrefMenuButtonY);
    if (savedX && savedY && [savedX floatValue] >= 0 && [savedY floatValue] >= 0) {
        CGFloat x = [savedX floatValue] * bw;
        CGFloat y = [savedY floatValue] * bh;
        self.menuButton.center = CGPointMake(x, y);
    } else {
        self.menuButton.center = CGPointMake(defaultBtnX, defaultBtnY);
    }

    // 统计标签默认位置：左上角
    CGFloat defaultLabelX = 70;
    CGFloat defaultLabelY = bh * 0.05 + 30;

    NSNumber *savedLX = getPrefObject(kPrefStatsLabelX);
    NSNumber *savedLY = getPrefObject(kPrefStatsLabelY);
    if (savedLX && savedLY && [savedLX floatValue] >= 0 && [savedLY floatValue] >= 0) {
        CGFloat x = [savedLX floatValue] * bw;
        CGFloat y = [savedLY floatValue] * bh;
        self.statsLabel.center = CGPointMake(x, y);
    } else {
        self.statsLabel.center = CGPointMake(defaultLabelX, defaultLabelY);
    }

    [self clampViewsToScreen];
}

- (void)savePositions {
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;
    if (bw <= 0 || bh <= 0) return;

    // 保存为屏幕宽高的百分比（参照 FCL menuPositionX/Y），旋转后仍正确
    CGFloat btnXPercent = self.menuButton.center.x / bw;
    CGFloat btnYPercent = self.menuButton.center.y / bh;
    setPrefObject(kPrefMenuButtonX, @(btnXPercent));
    setPrefObject(kPrefMenuButtonY, @(btnYPercent));

    CGFloat labelXPercent = self.statsLabel.center.x / bw;
    CGFloat labelYPercent = self.statsLabel.center.y / bh;
    setPrefObject(kPrefStatsLabelX, @(labelXPercent));
    setPrefObject(kPrefStatsLabelY, @(labelYPercent));
}

- (void)clampViewsToScreen {
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;
    if (bw <= 0 || bh <= 0) return;

    // 设置按钮限制在屏幕内
    CGFloat btnHalf = kMenuButtonSize / 2;
    CGFloat btnX = MAX(btnHalf, MIN(bw - btnHalf, self.menuButton.center.x));
    CGFloat btnY = MAX(btnHalf, MIN(bh - btnHalf, self.menuButton.center.y));
    self.menuButton.center = CGPointMake(btnX, btnY);

    // 统计标签限制在屏幕内
    CGFloat labelHalfW = self.statsLabel.frame.size.width / 2;
    CGFloat labelHalfH = self.statsLabel.frame.size.height / 2;
    CGFloat labelX = MAX(labelHalfW, MIN(bw - labelHalfW, self.statsLabel.center.x));
    CGFloat labelY = MAX(labelHalfH, MIN(bh - labelHalfH, self.statsLabel.center.y));
    self.statsLabel.center = CGPointMake(labelX, labelY);
}

#pragma mark - 设置按钮手势

- (void)handleMenuButtonPan:(UIPanGestureRecognizer *)sender {
    CGPoint translation = [sender translationInView:self];

    if (sender.state == UIGestureRecognizerStateBegan) {
        self.isDragging = NO;
        self.dragStartPoint = [sender locationInView:self];
        self.dragStartCenter = self.menuButton.center;
        // 拖拽时高亮
        self.menuButton.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:0.8];
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = [sender locationInView:self].x - self.dragStartPoint.x;
        CGFloat dy = [sender locationInView:self].y - self.dragStartPoint.y;
        CGFloat distance = sqrt(dx * dx + dy * dy);
        if (distance > kDragThreshold) {
            self.isDragging = YES;
        }
        if (self.isDragging) {
            CGPoint newCenter = CGPointMake(self.dragStartCenter.x + translation.x,
                                            self.dragStartCenter.y + translation.y);
            // 限制在屏幕内
            CGFloat half = kMenuButtonSize / 2;
            newCenter.x = MAX(half, MIN(self.bounds.size.width - half, newCenter.x));
            newCenter.y = MAX(half, MIN(self.bounds.size.height - half, newCenter.y));
            self.menuButton.center = newCenter;
        }
    } else if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        // 恢复背景
        self.menuButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.6];
        if (self.isDragging) {
            // ★ Task226（反馈 #12：齿轮 ⚙️ 不挡视线——拖拽结束自动吸边）：
            // 横向磁吸到最近的屏幕边（半嵌入：球心贴边留 1/3 露出可再拖），
            // 纵向保持用户放置的位置。视频播放器悬浮窗同款交互。
            CGFloat ame226_half = kMenuButtonSize / 2.0;
            CGFloat ame226_x = self.menuButton.center.x;
            CGFloat ame226_targetX = (ame226_x < self.bounds.size.width / 2.0)
                ? (ame226_half * 0.66)                      // 吸左：露 2/3
                : (self.bounds.size.width - ame226_half * 0.66);  // 吸右
            [UIView animateWithDuration:0.32 delay:0
                             usingSpringWithDamping:0.72 initialSpringVelocity:0.5
                              options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                           animations:^{
                self.menuButton.center = CGPointMake(ame226_targetX, self.menuButton.center.y);
            } completion:^(BOOL finished) {
                // 吸边落位后保存（持久化目标位而非起拖位）
                [self savePositions];
            }];
        }
        self.isDragging = NO;
    }
}

- (void)menuButtonTouchedDown:(UIButton *)sender {
    // 按下时缩小动画
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.9, 0.9);
    }];
}

- (void)menuButtonTouchedUp:(UIButton *)sender {
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformIdentity;
    }];
    // 如果是拖拽则不触发点击
    if (!self.isDragging) {
        if (self.onMenuButtonTapped) {
            self.onMenuButtonTapped();
        }
    }
}

#pragma mark - 统计标签手势

- (void)handleStatsLabelPan:(UIPanGestureRecognizer *)sender {
    CGPoint translation = [sender translationInView:self];

    if (sender.state == UIGestureRecognizerStateBegan) {
        self.isDragging = NO;
        self.dragStartCenter = self.statsLabel.center;
    } else if (sender.state == UIGestureRecognizerStateChanged) {
        self.isDragging = YES;
        CGPoint newCenter = CGPointMake(self.dragStartCenter.x + translation.x,
                                        self.dragStartCenter.y + translation.y);
        CGFloat halfW = self.statsLabel.frame.size.width / 2;
        CGFloat halfH = self.statsLabel.frame.size.height / 2;
        newCenter.x = MAX(halfW, MIN(self.bounds.size.width - halfW, newCenter.x));
        newCenter.y = MAX(halfH, MIN(self.bounds.size.height - halfH, newCenter.y));
        self.statsLabel.center = newCenter;
    } else if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        if (self.isDragging) {
            [self savePositions];
        }
        self.isDragging = NO;
    }
}

#pragma mark - 公共方法

- (void)setOverlayHidden:(BOOL)overlayHidden {
    _overlayHidden = overlayHidden;
    self.menuButton.hidden = overlayHidden;
    self.statsLabel.hidden = overlayHidden || !_statsLabelVisible;
}

- (void)setStatsLabelVisible:(BOOL)statsLabelVisible {
    _statsLabelVisible = statsLabelVisible;
    [self applyStatsLabelVisibility];
    // 持久化开关状态
    setPrefObject(kPrefStatsLabelVisible, @(statsLabelVisible));
}

- (void)applyStatsLabelVisibility {
    self.statsLabel.hidden = self.overlayHidden || !_statsLabelVisible;
}

/// 切换 FPS/内存显示的开关状态（参照 FCL 的 toggleStatsView）
- (void)toggleStatsLabel {
    self.statsLabelVisible = !self.statsLabelVisible;
}

- (void)updateFPS:(NSInteger)fps memoryUsageMB:(double)memoryMB {
    // 在主线程更新（参照 FCL/ZL2 由游戏循环驱动）
    // 使用 dispatch_async 避免阻塞调用方
    dispatch_async(dispatch_get_main_queue(), ^{
        if (fps >= 0) {
            self.statsLabel.text = [NSString stringWithFormat:@"FPS: %ld | MEM: %.0fMB",
                                    (long)fps, memoryMB];
        }
    });
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 屏幕旋转后重新约束位置
    [self clampViewsToScreen];
}

@end
