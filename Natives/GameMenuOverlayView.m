//
//  GameMenuOverlayView.m
//  Amethyst
//
//  参照 FCL MenuView.java 与 ZL2 GameScreen.kt 实现
//  关键改进：hitTest 穿透，只有按钮/标签区域拦截触摸，其他区域穿透到游戏画面
//

#import "GameMenuOverlayView.h"
#import "LiquidGlassCompat.h"   // Task232: 悬浮栏玻璃
#import "LauncherPreferences.h"
#import "utils.h"        // Task230：localize（齿轮标签文案）
#import "NMToast.h"     // Task230：预留（未绑定提示等悬浮提示）

// 位置持久化的 pref key
static NSString *const kPrefMenuButtonX = @"game.menu_button_x";
static NSString *const kPrefMenuButtonY = @"game.menu_button_y";
static NSString *const kPrefStatsLabelX = @"game.stats_label_x";
static NSString *const kPrefStatsLabelY = @"game.stats_label_y";
// FPS/内存显示开关的 pref key
static NSString *const kPrefStatsLabelVisible = @"game.stats_label_visible";

// 按钮尺寸
static const CGFloat kMenuButtonSize = 44.0;
// ★ Task227（反馈 #8）：吸边阈值与 docked 把手几何。用户指令：
// ①只有拖拽结束时【近边】才吸住（不是一直吸）；②吸住后不再是按钮
// 形态，而是侧边栏把手（半嵌入竖胶囊，点击拉出侧滑面板）。
static const CGFloat kAme227DockThreshold = 96.0;   // 距边小于此值才吸附
static const CGFloat kAme227HandleWidth = 26.0;    // 把手宽
static const CGFloat kAme227HandleHeight = 96.0;   // 把手高
static NSString * const kAme227DockedPref = @"game.gear.docked";
// ★ Task239（装机日志 4db827cf 实锤：全部游戏启动崩溃）：本键原为
//   @"game.gear.docked.left"——PLPreferences 的 valueForKeyPath: 语义下
//   它不是"gear 字典里的 docked_left 标量"，而是 game→gear→docked→left
//   四跳路径：第三跳落在 game.gear.docked 的【布尔值】上，第四跳对
//   __NSCFBoolean 取 left → NSUnknownKeyException（valueForUndefinedKey:）
//   → 启动游戏必崩（Task238 构建每次进游戏闪退的直接根因）。改为与
//   PLPreferences 注册默认值一致的 game.gear.docked_left（下划线，单跳）。
static NSString * const kAme227DockedSidePref = @"game.gear.docked_left";
// 拖拽阈值：超过此距离算拖动，否则算点击（参照 FCL MenuView 的 10px 阈值）
static const CGFloat kDragThreshold = 10.0;

@interface GameMenuOverlayView ()

// 设置按钮（圆形）
@property (nonatomic, strong) UIButton *menuButton;
/// ★ Task230（反馈 #9：齿轮未贴边时无文字显示）：悬浮齿轮下方的小标题
/// （“菜单”，本地化）。拖到边缘吸附成把手后隐藏；拖拽中额外提示可贴边。
@property (nonatomic, strong) UILabel *ame230_captionLabel;
// FPS/内存显示标签
@property (nonatomic, strong) UILabel *statsLabel;
// 拖拽相关状态
@property (nonatomic, assign) BOOL isDragging;
@property (nonatomic, assign) CGPoint dragStartPoint;
@property (nonatomic, assign) CGPoint dragStartCenter;

@end

// ★ Task227（CI r2 修复）：dock 状态改文件级静态——类扩展内的 ivar 块被
// 编译配置拒绝（44:1 expected identifier or '('）。覆盖层每会话仅一个
// 实例，静态即实例语义；readonly 属性 getter 读静态。
static BOOL ame227_g_docked = NO;
static BOOL ame227_g_dockedLeft = NO;

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
        // ★ Task235（用户：“现在启动游戏都闪退，是所有版本”）：Task232 把
        //   ame232_applyFloatingGlass 放在 setupMenuButton 里调用——那时
        //   statsLabel（setupStatsLabel 之后才建）与 ame230_captionLabel
        //   （setupMenuButton 尾部才建）都还是 nil，而玻璃函数里
        //   @[menuButton, statsLabel, caption] 数组字面量遇到 nil 元素直接
        //   抛 NSInvalidArgumentException（“attempt to insert nil object
        //   from objects[1]”，latestlog 51327919 装机实锤：玻璃风格一旦
        //   激活，每次进游戏必崩、与版本无关）。两修：①函数内部数组改
        //   nil 安全收集；②init 末尾三件套全部就绪后再统一铺一次玻璃
        //   （此前 statsLabel/“菜单”标签首次从未真正上过玻璃）。
        [self ame232_applyFloatingGlass];
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
    // ★ Task232（反馈 #6：液态玻璃悬浮栏没有任何效果，仍是原生与液态玻璃
    //   混杂样式）：悬浮栏本体（齿轮球 + FPS/内存统计条 + “菜单”标签）
    //   此前恒为原生半透明深色——切了液态玻璃风格的用户眼里，菜单弹层有
    //   玻璃而常驻悬浮件没有 = “混杂”。玻璃风格激活时给三件套上同款
    //   组合玻璃并换成重磨砂深色（游戏帧上可读）；非玻璃风格保持原生。
    //   applyInView 系插入 atIndex:0（位于图标/文字之下，不碰命中测试）。
    [self ame232_applyFloatingGlass];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame232_floatingGlassStyleChanged)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
    // 使用纯 frame 布局（不用 auto layout），因为按钮位置通过 center 手动设置并持久化
    // 不设置 translatesAutoresizingMaskIntoConstraints = NO，保持默认 YES，避免无约束导致 frame 不确定
    // 确保按钮能响应触摸
    self.menuButton.userInteractionEnabled = YES;

    // 添加拖拽手势
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleMenuButtonPan:)];
    pan.minimumNumberOfTouches = 1;
    // ★ Task229：拖拽起手阈值委托——位移 < 24pt 时拒绝 pan 开始，触摸归还
    // 按钮（游戏内用力轻点的自然漂移 10-20pt 常态超 UIKit 默认 ~10pt 的
    // pan 识别线 → TouchUpInside 被取消 = "悬浮球点不开"；把手区域大反而
    // 能点开 = "拖到边上才有反应"的形状完全吻合）。
    pan.delegate = self;
    [self.menuButton addGestureRecognizer:pan];

    // 点击事件
    [self.menuButton addTarget:self action:@selector(menuButtonTouchedDown:) forControlEvents:UIControlEventTouchDown];
    [self.menuButton addTarget:self action:@selector(menuButtonTouchedUp:) forControlEvents:UIControlEventTouchUpInside];

    [self addSubview:self.menuButton];

    // ★ Task230（反馈 #9）：悬浮齿轮的文字标签——未贴边（悬浮态）时齿轮
    //   只有图标、用户看不出它是菜单入口（“未贴边时无文字显示”）；贴边
    //   把手自带形态语义无需文字。标签不接触摸（纯展示），跟随按钮位置。
    self.ame230_captionLabel = [[UILabel alloc] init];
    self.ame230_captionLabel.text = localize(@"ame230.gamemenu.caption", nil);
    self.ame230_captionLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    self.ame230_captionLabel.textColor = [UIColor whiteColor];
    self.ame230_captionLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
    self.ame230_captionLabel.layer.cornerRadius = 5;
    self.ame230_captionLabel.layer.masksToBounds = YES;
    self.ame230_captionLabel.textAlignment = NSTextAlignmentCenter;
    self.ame230_captionLabel.userInteractionEnabled = NO;
    [self.ame230_captionLabel sizeToFit];
    self.ame230_captionLabel.frame = CGRectInset(self.ame230_captionLabel.frame, -6, -3);
    [self addSubview:self.ame230_captionLabel];
}

/// Task230：跟随齿轮位置排布文字标签（悬浮态显示、把手态隐藏）。
- (void)ame230_layoutCaption {
    if (self.ame230_captionLabel == nil) return;
    BOOL ame230_show = !ame227_g_docked && !self.overlayHidden;
    self.ame230_captionLabel.hidden = !ame230_show;
    if (!ame230_show) return;
    CGSize ame230_sz = self.ame230_captionLabel.bounds.size;
    self.ame230_captionLabel.center = CGPointMake(self.menuButton.center.x,
                                                   CGRectGetMaxY(self.menuButton.frame) + 6 + ame230_sz.height / 2.0);
    // 钳在屏内（贴左/右边缘时标签不溢出）
    CGFloat ame230_halfW = ame230_sz.width / 2.0;
    self.ame230_captionLabel.center = CGPointMake(
        MAX(ame230_halfW, MIN(self.bounds.size.width - ame230_halfW, self.ame230_captionLabel.center.x)),
        MIN(self.bounds.size.height - ame230_sz.height / 2.0, self.ame230_captionLabel.center.y));
}

#pragma mark - Task232：悬浮栏玻璃（齿轮球/统计条/菜单标签）

- (void)ame232_floatingGlassStyleChanged {
    [self ame232_applyFloatingGlass];
}

/// 玻璃风格激活 → 齿轮球组合玻璃；否则还原原生半透明深色。
/// ★ Task236（用户：“游戏界面齿轮图标和文件菜单都消失了”）：装机实测
///   Task235 构建里悬浮栏整体不可见——两处构造性雷：
///   ① LGCApplyGlassToView 接管卡面时会把宿主底色清空，而磨砂层在本进程
///     游戏画面（Metal 层）之上能否合成是未验证的（Task228 实锤过
///     UIGlassEffect 在本进程渲染为黑；Task230 见过 UltraThin 在游戏帧上
///     几乎不可见）——底色一清，磨砂再不渲染 = 整个悬浮件透明消失。
///   ② 磨砂/高光层插进 UILabel 内部会【盖在标签自己的文字上】——UILabel
///     的文字画在自己的图层，任何子视图（含磨砂层）都在其上：statsLabel/
///     “菜单”标签的文字被重磨砂深色完全盖住 = “什么都不显示”。
///   修法（防御性可见性，不磨掉玻璃质感）：
///   - 齿轮球：保留 LGC 组合玻璃，但铺完后【重铺半透明深色底】（底色在
///     磨砂层之下参与采样，磨砂可用时是加深的玻璃，磨砂失效时是独立可
///     见的深色球）；玻璃圆角跟随按钮【当前】圆角（把手态 13 / 悬浮态 22）。
///   - 两个文本件：不再往标签内插任何磨砂层——改实底半透明深色胶囊 +
///     0.75pt 白色发丝描边（iOS 26 玻璃边缘语言），文字永远画在最上层。
- (void)ame232_applyFloatingGlass {
    if (!LGCIsGlassStyleActive()) {
        // 非玻璃风格：还原原生外观（清玻璃层 + 恢复原底色 + 清 Task236 发丝描边）
        LGCRemoveGlassFromView(self.menuButton);
        LGCRemoveGlassFromView(self.statsLabel);
        LGCRemoveGlassFromView(self.ame230_captionLabel);
        self.menuButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.6];
        self.statsLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.5];
        self.statsLabel.layer.borderWidth = 0;
        self.ame230_captionLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        self.ame230_captionLabel.layer.borderWidth = 0;
        return;
    }
    // 齿轮球：组合玻璃（圆角跟随当前形态）+ 防御性深色底（Task236）
    CGFloat ame236_gearRadius = self.menuButton.layer.cornerRadius > 0.5
        ? self.menuButton.layer.cornerRadius
        : kMenuButtonSize / 2.0;
    LGCRemoveGlassFromView(self.menuButton);
    LGCApplyGlassToView(self.menuButton, ame236_gearRadius);
    // ★ 底色重铺：LGC 接管时清空了宿主底色（clearColor）——磨砂层若在本进程
    //   游戏画面上不合成，这就是“齿轮消失”的直接根因。半透明深色底永远
    //   在磨砂层之下参与渲染：磨砂可用 = 加深的玻璃质感；磨砂失效 = 独立
    //   可见的深色球，白色齿轮图标仍在最上层（imageView 是子视图，恒在玻璃层上）。
    self.menuButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.55];
    // ★ Task239（用户指令：iOS 26 原生液态玻璃 API）：齿轮球的磨砂层升级——
    //   玻璃风格下优先换成【系统原生 UIGlassEffect】（真液态玻璃）；取不到
    //   （<iOS 26 / AME239_NO_SYSTEM_GLASS=1 诊断开关）保持 SystemMaterialDark
    //   （Task230 游戏帧可读性教训的装机验证路径）。0.55 深色底 + 白色发丝
    //   描边保留：玻璃在游戏帧上渲染异常时齿轮仍是可见的深色球。
    UIVisualEffect *ame239_gearEffect = LGCNativeGlassEffect();
    for (UIView *ame232_sub in self.menuButton.subviews) {
        if ([ame232_sub isKindOfClass:UIVisualEffectView.class]) {
            [(UIVisualEffectView *)ame232_sub setEffect:(ame239_gearEffect != nil)
                ? ame239_gearEffect
                : [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark]];
        }
    }
    // 两个文本件：实底半透明深色胶囊 + 发丝描边（绝不往标签内插磨砂层——
    // UILabel 文字画在自己图层，子视图永远盖在文字上，见方法头注释 ②）。
    LGCRemoveGlassFromView(self.statsLabel);
    LGCRemoveGlassFromView(self.ame230_captionLabel);
    self.statsLabel.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0.55];
    self.statsLabel.layer.borderWidth = 0.75;
    self.statsLabel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.32].CGColor;
    self.statsLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.ame230_captionLabel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.5];
    self.ame230_captionLabel.layer.borderWidth = 0.75;
    self.ame230_captionLabel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.32].CGColor;
    self.ame230_captionLabel.layer.cornerCurve = kCACornerCurveContinuous;
    // Task236 取证：下一轮装机日志直接读出三件套的帧/透明度/子视图构成
    NSLog(@"[GameMenu] Task236 floating bar hardened (gear %@ r=%.1f subs=%lu; stats %@; caption %@)",
          NSStringFromCGRect(self.menuButton.frame), (double)ame236_gearRadius,
          (unsigned long)self.menuButton.subviews.count,
          self.statsLabel != nil ? NSStringFromCGRect(self.statsLabel.frame) : @"nil",
          self.ame230_captionLabel != nil ? NSStringFromCGRect(self.ame230_captionLabel.frame) : @"nil");
    NSLog(@"[GameMenu] Task232 floating bar glass applied (gear + stats + caption, heavy dark material)");
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

// ★ Task227：readonly 公开属性的 getter（backed by 文件级静态，见类扩展后 CI r2 注释）
- (BOOL)isDocked { return ame227_g_docked; }
- (BOOL)dockedLeft { return ame227_g_dockedLeft; }

- (void)restorePositions {
    CGFloat bw = self.bounds.size.width;
    CGFloat bh = self.bounds.size.height;

    // ★ Task238（用户："在默认边边没有贴边，需要手动刷新状态再拖出来才有
    //   显示"）：默认形态从"右侧悬浮球（距边 20pt）"改为【右侧吸边把手】
    //   ——与其他启动器一致：齿轮默认就是贴边的侧边栏把手，点击拉出侧滑
    //   菜单；拖离边缘即回悬浮球。首启即落盘（位置 + 吸边态），后续会话
    //   与用户显式操作同链路。
    NSNumber *savedX = getPrefObject(kPrefMenuButtonX);
    NSNumber *savedY = getPrefObject(kPrefMenuButtonY);
    BOOL ame238_hasSaved = (savedX && savedY &&
                            [savedX floatValue] >= 0 && [savedY floatValue] >= 0);

    // ★ Task227：dock 状态恢复（上次吸边的把手形态跨会话保持；
    //   Task238 注册键后本读取才真正生效——旧版写入被静默丢弃）
    BOOL ame238_dockPref = getPrefBool(kAme227DockedPref);

    if (!ame238_hasSaved) {
        // 首次使用：右侧吸边把手，垂直位置 45%（拇指自然高度）
        ame227_g_docked = YES;
        ame227_g_dockedLeft = NO;
        self.menuButton.center = CGPointMake(kAme227HandleWidth * 0.66,
                                             bh > 0 ? bh * 0.45 : 300.0);
        [self ame227_applyDockedAppearanceAnimated:NO];
        if (bw > 0 && bh > 0) {
            setPrefObject(kPrefMenuButtonX, @(self.menuButton.center.x / bw));
            setPrefObject(kPrefMenuButtonY, @(self.menuButton.center.y / bh));
            setPrefBool(kAme227DockedPref, YES);
            setPrefBool(kAme227DockedSidePref, NO);
        }
        NSLog(@"[GameMenu] Task238 gear default: docked right handle (first run)");
    } else {
        CGFloat x = [savedX floatValue] * bw;
        CGFloat y = [savedY floatValue] * bh;
        self.menuButton.center = CGPointMake(x, y);
        if (ame238_dockPref) {
            ame227_g_docked = YES;
            ame227_g_dockedLeft = getPrefBool(kAme227DockedSidePref);
            [self ame227_applyDockedAppearanceAnimated:NO];
        } else {
            // ★ Task238：存量设备兜底——旧版吸边态从不持久化（注册缺失），
            //   齿轮常以"贴着边但没吸住"的悬浮球恢复（用户本次反馈的形态）。
            //   与拖拽结束同规则：恢复位置落在吸边阈值内 → 直接吸附成把手。
            CGFloat ame238_half = kMenuButtonSize / 2.0;
            CGFloat ame238_distL = self.menuButton.center.x - ame238_half;
            CGFloat ame238_distR = bw - self.menuButton.center.x - ame238_half;
            if (ame238_distL < kAme227DockThreshold || ame238_distR < kAme227DockThreshold) {
                BOOL ame238_left = (self.menuButton.center.x < bw / 2.0);
                ame227_g_docked = YES;
                ame227_g_dockedLeft = ame238_left;
                [self ame227_applyDockedAppearanceAnimated:NO];
                setPrefBool(kAme227DockedPref, YES);
                setPrefBool(kAme227DockedSidePref, ame238_left);
                NSLog(@"[GameMenu] Task238 gear auto-docked on restore (legacy near-edge floating state healed)");
            }
        }
    }
    [self ame230_layoutCaption];

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
            [self ame230_layoutCaption];
        }
    } else if (sender.state == UIGestureRecognizerStateEnded || sender.state == UIGestureRecognizerStateCancelled) {
        // 恢复背景
        self.menuButton.backgroundColor = [UIColor colorWithRed:0.1 green:0.1 blue:0.1 alpha:0.6];
        // ★ Task230：恢复按压缩放（pan 抢占触摸后 TouchUp 不会来，
        //   menuButtonTouchedDown 的 0.9 缩放无人复位会卡在小态）。
        self.menuButton.transform = CGAffineTransformIdentity;
        if (self.isDragging) {
            // ★ Task227（反馈 #8：只在靠边时吸住 + 吸成侧边把手）：
            // Task226 的实现【无条件】吸到最近边——用户拖到哪都立刻被
            // 拽走（"而不是一直吸"）。新语义：拖拽结束时距边 <
            // kAme227DockThreshold 才吸附，吸附时变形为竖胶囊把手
            //（半嵌入，视觉上是侧边栏而非悬浮球）；否则留在原地悬浮。
            CGFloat ame227_half = kMenuButtonSize / 2.0;
            CGFloat ame227_x = self.menuButton.center.x;
            CGFloat ame227_bw = self.bounds.size.width;
            CGFloat ame227_distLeft = ame227_x - ame227_half;
            CGFloat ame227_distRight = ame227_bw - ame227_x - ame227_half;
            BOOL ame227_nearEdge = (ame227_distLeft < kAme227DockThreshold ||
                                    ame227_distRight < kAme227DockThreshold);
            if (ame227_nearEdge) {
                BOOL ame227_dockLeft = (ame227_x < ame227_bw / 2.0);
                ame227_g_docked = YES;
                ame227_g_dockedLeft = ame227_dockLeft;
                [self ame227_applyDockedAppearanceAnimated:YES];
                setPrefBool(kAme227DockedPref, YES);
                setPrefBool(kAme227DockedSidePref, ame227_dockLeft);
            } else {
                // 不近边：解除 dock（若原先 docked），留在用户放置的位置
                if (ame227_g_docked) {
                    ame227_g_docked = NO;
                    [self ame227_applyDockedAppearanceAnimated:NO];
                    setPrefBool(kAme227DockedPref, NO);
                }
            }
            [self savePositions];
            [self ame230_layoutCaption];
        } else {
            // ★ Task230：pan 恒开始后 UIKit 取消按钮的 TouchUpInside——
            //   未达拖拽阈值的手势在这里人工补发点击（"点开菜单"）。
            //   轻点带自然漂移（游戏内 10-20pt 常态）也能打开，不再吞点。
            static int ame230_manualTap = 0;
            ame230_manualTap++;
            if (ame230_manualTap <= 10 || ame230_manualTap % 50 == 0) {
                NSLog(@"[GameMenu] Task230 gear manual tap-fire #%d (pan armed always; UIKit cancelled TouchUpInside)",
                      ame230_manualTap);
            }
            if (self.onMenuButtonTapped) {
                self.onMenuButtonTapped();
            }
        }
        self.isDragging = NO;
    }
}

/// ★ Task227：dock 形态切换——按钮（44×44 圆）⇄ 侧边把手（26×96 竖胶囊，
/// 半嵌入边内 1/3，中心线贴边）。点击语义不变（onMenuButtonTapped），
/// 由上层根据 isDocked 决定拉侧滑面板还是底部弹层。
- (void)ame227_applyDockedAppearanceAnimated:(BOOL)animated {
    CGFloat ame227_w = ame227_g_docked ? kAme227HandleWidth : kMenuButtonSize;
    CGFloat ame227_h = ame227_g_docked ? kAme227HandleHeight : kMenuButtonSize;
    CGFloat ame227_radius = ame227_g_docked ? kAme227HandleWidth / 2.0 : kMenuButtonSize / 2.0;
    CGFloat ame227_cx;
    if (ame227_g_docked) {
        // 半嵌入：中心距边 1/3 把手宽（2/3 露出）
        ame227_cx = ame227_g_dockedLeft
            ? (kAme227HandleWidth * 0.66)
            : (self.bounds.size.width - kAme227HandleWidth * 0.66);
    } else {
        ame227_cx = self.menuButton.center.x;
    }
    CGFloat ame227_cy = self.menuButton.center.y;
    CGRect ame227_target = CGRectMake(ame227_cx - ame227_w / 2.0,
                                      ame227_cy - ame227_h / 2.0,
                                      ame227_w, ame227_h);
    void (^ame227_apply)(void) = ^{
        self.menuButton.bounds = CGRectMake(0, 0, ame227_w, ame227_h);
        self.menuButton.center = CGPointMake(ame227_cx, ame227_cy);
        self.menuButton.layer.cornerRadius = ame227_radius;
        self.menuButton.layer.cornerCurve = kCACornerCurveContinuous;
        if (ame227_g_docked) {
            // 把手态：仅朝屏内一侧圆角（半嵌入侧直角）
            self.menuButton.layer.maskedCorners = ame227_g_dockedLeft
                ? kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner
                : kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
        } else {
            self.menuButton.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner
                | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
        }
    };
    if (animated) {
        [UIView animateWithDuration:0.32 delay:0
                         usingSpringWithDamping:0.78 initialSpringVelocity:0.5
                          options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                       animations:ame227_apply
                       completion:^(BOOL finished) {
            // ★ Task236：形态切换后玻璃层圆角/尺寸跟随新几何（把手 13 / 球 22）
            [self ame232_applyFloatingGlass];
        }];
    } else {
        ame227_apply();
        // ★ Task236：同上，非动画路径立即重铺（恢复把手态时圆角已变）。
        [self ame232_applyFloatingGlass];
    }
    NSLog(@"[GameMenu] Task227 gear dock state: %@ (%@)",
          ame227_g_docked ? @"DOCKED handle" : @"floating button",
          ame227_g_dockedLeft ? @"left edge" : @"right edge");
}

- (void)menuButtonTouchedDown:(UIButton *)sender {
    // 按下时缩小动画
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformMakeScale(0.9, 0.9);
    }];
}

/// ★ Task229 → Task230 重写（反馈 #9：齿轮未贴边时无法拖动）：旧实现的
/// shouldBegin 阈值用 translationInView: 判位移——该值在手势起手时恒 ≈ 0
/// （pan 在手指移动极小量时就触发 shouldBegin），24pt 门槛永不达标 →
/// pan 永远不开始 → 齿轮完全无法拖动（更无法贴边）。这正是"修点不开矫枉
/// 过正"。新仲裁：pan 恒可开始（shouldBegin 恒 YES），点击/拖拽的竞争
/// 移到 handleMenuButtonPan 的 Ended 分支内处理——未超过 kDragThreshold
/// 的手势视为点击，手动补发 onMenuButtonTapped（pan 识别后 UIKit 已取消
/// 按钮的 TouchUpInside，必须人工补发），超过则进入拖拽（阈值逻辑沿用
/// 既有 kDragThreshold 常量）。
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if ([gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *ame229_pan = (UIPanGestureRecognizer *)gestureRecognizer;
        // 仅对菜单按钮上的 pan 放行（统计标签的 pan 沿用系统默认——
        // 标签是拖拽专用件，无点击语义需要保护）。
        if (ame229_pan.view == self.menuButton) {
            return YES;
        }
    }
    return YES;
}

- (void)menuButtonTouchedUp:(UIButton *)sender {
    [UIView animateWithDuration:0.1 animations:^{
        sender.transform = CGAffineTransformIdentity;
    }];
    // Task229: tap-chain forensics (limited rate) -- the next device log must
    // show whether the up event arrives and whether isDragging ate it.
    static int ame229_tapLog = 0;
    ame229_tapLog++;
    if (ame229_tapLog <= 10 || ame229_tapLog % 50 == 0) {
        NSLog(@"[GameMenu] Task229 gear tap #%d (isDragging=%d, callback=%@)",
              ame229_tapLog, (int)self.isDragging,
              self.onMenuButtonTapped ? @"set" : @"nil");
    }
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
    [self ame230_layoutCaption];
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
