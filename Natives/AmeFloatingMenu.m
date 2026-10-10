//
//  AmeFloatingMenu.m
//  Amethyst
//
//  Task237：统一悬浮菜单（液态玻璃风格 = 全自定义组件；原生风格 = 旧版
//  原生弹窗零魔改直呈现）。设计要点见 AmeFloatingMenu.h 头注释。
//
//  渲染层次（自下而上）：
//    panel.backgroundColor（明暗自适应半透明实底——磨砂在本进程 Metal
//    游戏画面上不合成时它独立承载可读性，Task228/230/236 三轮教训）
//    → UIVisualEffectView（SystemMaterial，index 0 子视图，自带圆角裁剪）
//    → 内容（标题/正文/镜像输入框/菜单行 + 分隔发丝线）
//    → 发丝描边覆盖环（最上层，不参与命中）
//  文字恒在磨砂之上——“打开只有玻璃没有字”的构造性根除。
//

#import "AmeFloatingMenu.h"
#import "LiquidGlassCompat.h"

#pragma mark - 前向声明与工具

@interface Ame237MenuActionMirror : NSObject
@property (nonatomic, strong, nullable) UIAlertAction *orig;
@property (nonatomic, copy, nullable) NSString *title;
@property (nonatomic, assign) NSInteger style;   // 0 default / 1 cancel / 2 destructive
@property (nonatomic, copy, nullable) void (^handler)(UIAlertAction *action);
@property (nonatomic, assign) BOOL enabled;
@end

@implementation Ame237MenuActionMirror
@end

/// 动态明暗颜色：深色模式 = 白 alpha；浅色模式 = 黑 alpha。
static UIColor *Ame237Dyn(CGFloat darkWhiteAlpha, CGFloat lightBlackAlpha) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:1.0 alpha:darkWhiteAlpha]
            : [UIColor colorWithWhite:0.0 alpha:lightBlackAlpha];
    }];
}

/// 面板防御性实底：深色 = 近黑 55%；浅色 = 白 80%（磨砂失效时仍是一块
/// 可读面板——绝不是“透明面板 + 悬浮文字”）。
static UIColor *Ame237PanelBase(void) {
    return [UIColor colorWithDynamicProvider:^UIColor * _Nonnull(UITraitCollection * _Nonnull tc) {
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark)
            ? [UIColor colorWithWhite:0.02 alpha:0.55]
            : [UIColor colorWithWhite:1.0 alpha:0.80];
    }];
}

static CGFloat Ame237TextHeight(NSString *text, UIFont *font, CGFloat width) {
    if (text.length == 0) return 0.0;
    NSAttributedString *s = [[NSAttributedString alloc] initWithString:text
                                                             attributes:@{NSFontAttributeName: font}];
    CGRect r = [s boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                               options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                               context:nil];
    return ceil(r.size.height);
}

#pragma mark - 菜单行控件（图标 + 标题；自带按压反馈；头文件公开供游戏内菜单共用）

@implementation Ame237MenuRow

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _showsIcon = YES;
        _iconView = [[UIImageView alloc] init];
        _iconView.contentMode = UIViewContentModeCenter;
        _iconView.userInteractionEnabled = NO;
        _rowLabel = [[UILabel alloc] init];
        _rowLabel.font = [UIFont systemFontOfSize:16];
        _rowLabel.textAlignment = NSTextAlignmentLeft;
        _rowLabel.userInteractionEnabled = NO;
        [self addSubview:_iconView];
        [self addSubview:_rowLabel];
    }
    return self;
}

- (void)ame237_configureWithIcon:(nullable UIImage *)icon
                           title:(NSString *)title
                       textColor:(UIColor *)textColor
                     symbolTint:(UIColor *)symbolTint
                        emphasis:(BOOL)emphasis {
    self.iconView.image = icon;
    self.iconView.tintColor = symbolTint;
    self.rowLabel.text = title;
    self.rowLabel.textColor = textColor;
    self.rowLabel.font = emphasis
        ? [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold]
        : [UIFont systemFontOfSize:16];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat iconW = 24.0;
    CGFloat iconX = 22.0;
    BOOL iconVisible = self.showsIcon && (self.iconView.image != nil);
    self.iconView.hidden = !iconVisible;
    if (iconVisible) {
        self.iconView.frame = CGRectMake(iconX, (self.bounds.size.height - iconW) / 2.0, iconW, iconW);
        CGFloat labelX = iconX + iconW + 12.0;
        self.rowLabel.frame = CGRectMake(labelX, 0.0,
                                         MAX(0.0, self.bounds.size.width - labelX - 18.0),
                                         self.bounds.size.height);
    } else {
        // 无符号/隐藏图标：标题占满行宽，不留图标空位
        self.rowLabel.frame = CGRectMake(iconX, 0.0,
                                         MAX(0.0, self.bounds.size.width - iconX - 18.0),
                                         self.bounds.size.height);
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [UIView animateWithDuration:0.10 delay:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{
        self.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97) : CGAffineTransformIdentity;
    } completion:nil];
    self.backgroundColor = highlighted ? Ame237Dyn(0.12, 0.06) : nil;
}

@end

#pragma mark - 玻璃悬浮菜单视图控制器

@interface Ame237GlassMenuViewController : UIViewController
@property (nonatomic, copy, nullable) NSString *ame237_title;
@property (nonatomic, copy, nullable) NSString *ame237_message;
@property (nonatomic, copy) NSArray<Ame237MenuActionMirror *> *ame237_actions;
@property (nonatomic, copy) NSArray<UITextField *> *ame237_alertFields;
@property (nonatomic, assign) BOOL ame237_animated;
@property (nonatomic, assign) BOOL ame237_dismissing;
@property (nonatomic, assign) BOOL ame237_didEntrance;
@property (nonatomic, assign) CGFloat ame237_kbShift;

@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UIVisualEffectView *blurView;
@property (nonatomic, strong) UIView *borderOverlay;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) NSMutableArray<UITextField *> *mirrorFields;
@property (nonatomic, strong) UIScrollView *rowsScroll;
@property (nonatomic, strong) NSMutableArray<Ame237MenuRow *> *rows;
@property (nonatomic, strong) NSMutableArray<UIView *> *separators;
@end

@implementation Ame237GlassMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.userInteractionEnabled = YES;

    // 遮罩（点击 = 取消/关闭；与游戏内菜单同语义）
    self.dimView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.dimView.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.38];
    self.dimView.userInteractionEnabled = YES;
    UITapGestureRecognizer *dimTap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                              action:@selector(ame237_dimTapped)];
    [self.dimView addGestureRecognizer:dimTap];
    [self.view addSubview:self.dimView];

    // 悬浮面板（防御性实底 + 毛玻璃 + 阴影）
    self.panel = [[UIView alloc] init];
    self.panel.backgroundColor = Ame237PanelBase();
    self.panel.layer.cornerRadius = 26.0;
    self.panel.layer.cornerCurve = kCACornerCurveContinuous;
    self.panel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panel.layer.shadowOpacity = 0.32;
    self.panel.layer.shadowRadius = 26.0;
    self.panel.layer.shadowOffset = CGSizeMake(0, 12);
    self.panel.clipsToBounds = NO;
    [self.view addSubview:self.panel];

    self.blurView = [[UIVisualEffectView alloc] initWithEffect:
                     [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
    self.blurView.userInteractionEnabled = NO;
    self.blurView.layer.cornerRadius = 26.0;
    self.blurView.layer.cornerCurve = kCACornerCurveContinuous;
    self.blurView.layer.masksToBounds = YES;
    [self.panel addSubview:self.blurView];   // index 0：恒在全部内容之下

    // 内容
    if (self.ame237_title.length > 0) {
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.text = self.ame237_title;
        self.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        self.titleLabel.textColor = [UIColor labelColor];
        self.titleLabel.textAlignment = NSTextAlignmentCenter;
        self.titleLabel.numberOfLines = 0;
        [self.panel addSubview:self.titleLabel];
    }
    if (self.ame237_message.length > 0) {
        self.messageLabel = [[UILabel alloc] init];
        self.messageLabel.text = self.ame237_message;
        self.messageLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
        self.messageLabel.textColor = [UIColor secondaryLabelColor];
        self.messageLabel.textAlignment = NSTextAlignmentCenter;
        self.messageLabel.numberOfLines = 0;
        [self.panel addSubview:self.messageLabel];
    }

    // 镜像输入框（alert 自有字段仅作数据源；本组件字段负责交互并双向同步）
    self.mirrorFields = [NSMutableArray array];
    for (UITextField *src in self.ame237_alertFields) {
        if (![src isKindOfClass:[UITextField class]]) continue;
        UITextField *f = [[UITextField alloc] init];
        f.font = [UIFont systemFontOfSize:15];
        f.textColor = [UIColor labelColor];
        f.placeholder = src.placeholder;
        f.text = src.text;
        f.secureTextEntry = src.secureTextEntry;
        f.keyboardType = src.keyboardType;
        f.autocapitalizationType = src.autocapitalizationType;
        f.autocorrectionType = src.autocorrectionType;
        f.clearButtonMode = src.clearButtonMode;
        f.returnKeyType = src.returnKeyType;
        f.tag = src.tag;
        f.backgroundColor = Ame237Dyn(0.12, 0.06);
        f.layer.cornerRadius = 10.0;
        f.layer.borderWidth = 0.5;
        f.layer.borderColor = Ame237Dyn(0.25, 0.12).CGColor;
        f.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *leftPad = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
        f.leftView = leftPad;
        f.leftViewMode = UITextFieldViewModeAlways;
        f.rightViewMode = UITextFieldViewModeAlways;
        [f addTarget:self action:@selector(ame237_fieldChanged:)
            forControlEvents:UIControlEventEditingChanged];
        [self.mirrorFields addObject:f];
        [self.panel addSubview:f];
    }

    // 菜单行（唯一滚动区；高度足够时禁用滚动 = 平铺）
    self.rowsScroll = [[UIScrollView alloc] init];
    self.rowsScroll.showsVerticalScrollIndicator = NO;
    self.rowsScroll.delaysContentTouches = NO;
    self.rowsScroll.layer.cornerRadius = 16.0;
    self.rowsScroll.layer.masksToBounds = YES;
    [self.panel addSubview:self.rowsScroll];

    self.rows = [NSMutableArray array];
    self.separators = [NSMutableArray array];
    NSUInteger idx = 0;
    for (Ame237MenuActionMirror *m in self.ame237_actions) {
        Ame237MenuRow *row = [[Ame237MenuRow alloc] init];
        BOOL checked = (m.title.length > 0 && [m.title hasPrefix:@"\u2713"]);
        NSString *norm = [AmeFloatingMenu iconNameForTitle:m.title];
        NSString *iconName = checked ? @"checkmark.circle.fill" : norm;
        if (iconName == nil) {
            iconName = (m.style == 2) ? @"exclamationmark.circle"
                     : (m.style == 1) ? @"xmark.circle"
                     : @"circle.dotted";
        }
        UIImage *icon = [AmeFloatingMenu symbolImageForName:iconName];
        UIColor *textColor = (m.style == 2) ? [UIColor systemRedColor] : [UIColor labelColor];
        UIColor *symbolTint = (m.style == 2) ? [UIColor systemRedColor]
                            : (m.style == 1) ? [UIColor secondaryLabelColor]
                            : [UIColor systemBlueColor];
        [row ame237_configureWithIcon:icon
                                title:(m.title.length > 0 ? m.title : @"")
                            textColor:textColor
                          symbolTint:symbolTint
                             emphasis:(m.style == 1 || checked)];
        row.tag = (NSInteger)idx;
        row.enabled = m.enabled;
        row.alpha = m.enabled ? 1.0 : 0.4;
        [row addTarget:self action:@selector(ame237_rowTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [self.rowsScroll addSubview:row];
        [self.rows addObject:row];
        if (idx + 1 < self.ame237_actions.count) {
            UIView *sep = [[UIView alloc] init];
            sep.backgroundColor = Ame237Dyn(0.16, 0.10);
            sep.userInteractionEnabled = NO;
            [self.rowsScroll addSubview:sep];
            [self.separators addObject:sep];
        }
        idx++;
    }

    // 发丝描边覆盖环（最上层；空心底环不遮内容、不参与命中）
    self.borderOverlay = [[UIView alloc] init];
    self.borderOverlay.backgroundColor = [UIColor clearColor];
    self.borderOverlay.layer.cornerRadius = 26.0;
    self.borderOverlay.layer.cornerCurve = kCACornerCurveContinuous;
    self.borderOverlay.layer.borderWidth = 0.75;
    self.borderOverlay.layer.borderColor = Ame237Dyn(0.30, 0.10).CGColor;
    self.borderOverlay.userInteractionEnabled = NO;
    [self.panel addSubview:self.borderOverlay];

    // 入场初始态（viewDidAppear 前不可见——无动画路径在此直接摆正）
    if (self.ame237_animated) {
        self.dimView.alpha = 0.0;
        self.panel.alpha = 0.0;
        self.panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    } else {
        self.dimView.alpha = 1.0;
        self.panel.alpha = 1.0;
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame237_keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(ame237_keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self ame237_layout];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.ame237_didEntrance) return;
    self.ame237_didEntrance = YES;
    if (self.ame237_animated) {
        [UIView animateWithDuration:0.20 delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{
            self.dimView.alpha = 1.0;
        } completion:nil];
        [UIView animateWithDuration:0.38 delay:0
             usingSpringWithDamping:0.80 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.panel.alpha = 1.0;
            self.panel.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        self.dimView.alpha = 1.0;
        self.panel.alpha = 1.0;
        self.panel.transform = CGAffineTransformIdentity;
    }
    if (self.mirrorFields.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.mirrorFields.firstObject becomeFirstResponder];
        });
    }
}

#pragma mark - 布局（纯 frame：无 Auto Layout 约束竞态）

- (void)ame237_layout {
    CGFloat bw = self.view.bounds.size.width;
    CGFloat bh = self.view.bounds.size.height;
    if (bw < 40.0 || bh < 40.0) return;
    CGFloat W = MIN(bw - 56.0, 342.0);
    CGFloat textW = W - 44.0;

    BOOL hasHeader = (self.titleLabel != nil || self.messageLabel != nil || self.mirrorFields.count > 0);
    CGFloat y = hasHeader ? 20.0 : 14.0;

    if (self.titleLabel != nil) {
        CGFloat h = Ame237TextHeight(self.ame237_title, self.titleLabel.font, textW);
        self.titleLabel.frame = CGRectMake(22.0, y, textW, h);
        y += h + 6.0;
    }
    if (self.messageLabel != nil) {
        CGFloat h = Ame237TextHeight(self.ame237_message, self.messageLabel.font, textW);
        self.messageLabel.frame = CGRectMake(22.0, y, textW, h);
        y += h + 4.0;
    }
    if (self.mirrorFields.count > 0) {
        if (self.titleLabel != nil || self.messageLabel != nil) y += 8.0;
        for (NSUInteger i = 0; i < self.mirrorFields.count; i++) {
            UITextField *f = self.mirrorFields[i];
            f.frame = CGRectMake(22.0, y, textW, 38.0);
            y += 38.0 + ((i + 1 < self.mirrorFields.count) ? 8.0 : 0.0);
        }
        y += 14.0;
    }

    CGFloat rowsTop = y;
    NSUInteger n = self.rows.count;
    CGFloat rowsH = n * 50.0 + (n > 1 ? (n - 1) * 0.5 : 0.0);
    CGFloat bottomInset = 10.0;
    CGFloat contentH = rowsTop + rowsH + bottomInset;
    CGFloat maxH = floor(bh * 0.72);
    CGFloat panelH = MIN(contentH, maxH);
    CGFloat rowsAvail = panelH - rowsTop - bottomInset;
    if (rowsAvail < 50.0) rowsAvail = MAX(0.0, panelH - rowsTop);

    self.panel.frame = CGRectMake((bw - W) / 2.0, (bh - panelH) / 2.0, W, panelH);
    if (self.ame237_kbShift > 0.0) {
        self.panel.frame = CGRectOffset(self.panel.frame, 0.0, -self.ame237_kbShift);
    }
    self.blurView.frame = self.panel.bounds;
    self.borderOverlay.frame = self.panel.bounds;
    self.rowsScroll.frame = CGRectMake(0.0, rowsTop, W, rowsAvail);
    self.rowsScroll.contentSize = CGSizeMake(W, rowsH);
    self.rowsScroll.scrollEnabled = (rowsH > rowsAvail + 0.5);

    CGFloat ry = 0.0;
    for (NSUInteger i = 0; i < n; i++) {
        Ame237MenuRow *row = self.rows[i];
        row.frame = CGRectMake(0.0, ry, W, 50.0);
        ry += 50.0;
        if (i < self.separators.count) {
            UIView *sep = self.separators[i];
            sep.frame = CGRectMake(22.0, ry, W - 44.0, 0.5);
            ry += 0.5;
        }
    }

    static int ame237_layoutLog = 0;
    ame237_layoutLog++;
    if (ame237_layoutLog <= 5 || ame237_layoutLog % 25 == 0) {
        NSLog(@"[AmeMenu] Task237 panel layout #%d (panel=%@ rows=%lu avail=%.0f scroll=%d)",
              ame237_layoutLog, NSStringFromCGRect(self.panel.frame),
              (unsigned long)n, (double)rowsAvail, (int)self.rowsScroll.isScrollEnabled);
    }
}

#pragma mark - 键盘避让

- (void)ame237_keyboardWillShow:(NSNotification *)note {
    if (self.view.window == nil) return;
    NSValue *frameValue = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    NSNumber *durationValue = note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
    if (![frameValue isKindOfClass:[NSValue class]]) return;
    CGRect kbFrame = [frameValue CGRectValue];
    CGFloat kbTop = [self.view convertRect:kbFrame fromView:nil].origin.y;
    if (kbTop <= 0.0) return;
    CGFloat overlap = CGRectGetMaxY(self.panel.frame) - kbTop + 12.0;
    if (overlap <= 0.0 || self.ame237_kbShift > 0.0) return;
    self.ame237_kbShift = overlap;
    NSTimeInterval dur = durationValue ? durationValue.doubleValue : 0.25;
    [UIView animateWithDuration:dur delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.panel.frame = CGRectOffset(self.panel.frame, 0.0, -overlap);
    } completion:nil];
}

- (void)ame237_keyboardWillHide:(NSNotification *)note {
    if (self.view.window == nil) return;
    if (self.ame237_kbShift <= 0.0) return;
    CGFloat shift = self.ame237_kbShift;
    self.ame237_kbShift = 0.0;
    NSNumber *durationValue = note.userInfo[UIKeyboardAnimationDurationUserInfoKey];
    NSTimeInterval dur = durationValue ? durationValue.doubleValue : 0.25;
    [UIView animateWithDuration:dur delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.panel.frame = CGRectOffset(self.panel.frame, 0.0, shift);
    } completion:nil];
}

#pragma mark - 交互

- (void)ame237_fieldChanged:(UITextField *)mirrorField {
    NSUInteger i = [self.mirrorFields indexOfObject:mirrorField];
    if (i != NSNotFound && i < self.ame237_alertFields.count) {
        UITextField *src = self.ame237_alertFields[i];
        if ([src isKindOfClass:[UITextField class]]) src.text = mirrorField.text;
    }
}

- (void)ame237_syncAllFields {
    NSUInteger n = MIN(self.mirrorFields.count, self.ame237_alertFields.count);
    for (NSUInteger i = 0; i < n; i++) {
        UITextField *src = self.ame237_alertFields[i];
        if ([src isKindOfClass:[UITextField class]]) src.text = self.mirrorFields[i].text;
    }
}

- (void)ame237_rowTapped:(Ame237MenuRow *)sender {
    if (self.ame237_dismissing) return;
    NSInteger i = sender.tag;
    if (i < 0 || (NSUInteger)i >= self.ame237_actions.count) return;
    [self ame237_dismissWithAction:self.ame237_actions[i]];
}

- (void)ame237_dimTapped {
    if (self.ame237_dismissing) return;
    Ame237MenuActionMirror *cancel = nil;
    for (Ame237MenuActionMirror *m in self.ame237_actions) {
        if (m.style == 1) { cancel = m; break; }
    }
    [self ame237_dismissWithAction:cancel];
}

- (void)ame237_dismissWithAction:(nullable Ame237MenuActionMirror *)action {
    if (self.ame237_dismissing) return;
    self.ame237_dismissing = YES;
    [self ame237_syncAllFields];
    [self.view endEditing:YES];
    void (^finish)(void) = ^{
        [self dismissViewControllerAnimated:NO completion:^{
            if (action != nil && action.handler != nil) {
                action.handler(action.orig);
            }
        }];
    };
    if (self.ame237_animated) {
        [UIView animateWithDuration:0.18 delay:0
                            options:UIViewAnimationOptionCurveEaseIn
                         animations:^{
            self.dimView.alpha = 0.0;
            self.panel.alpha = 0.0;
            self.panel.transform = CGAffineTransformMakeScale(0.96, 0.96);
        } completion:^(BOOL finished) {
            finish();
        }];
    } else {
        finish();
    }
}

@end

#pragma mark - 图标启发式（标题语义 → SF Symbol）

@implementation AmeFloatingMenu

+ (NSString *)iconNameForTitle:(NSString *)title {
    if (![title isKindOfClass:[NSString class]] || title.length == 0) return nil;
    // 归一化：剥 ✓ 与空白，小写
    static NSCharacterSet *trim = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        trim = [NSCharacterSet characterSetWithCharactersInString:@"\u2713\u00a0 \t"];
    });
    NSString *t = [[title stringByTrimmingCharactersInSet:trim] lowercaseString];
    if (t.length == 0) return nil;

    // 有序规则表（含 CJK 关键词子串匹配 / 短 ASCII 词精确匹配）
    static NSArray<NSArray<NSString *> *> *rules = nil;
    static dispatch_once_t rulesOnce;
    dispatch_once(&rulesOnce, ^{
        rules = @[
            @[@"\u53d6\u6d88", @"xmark.circle"],            // 取消
            @[@"cancel", @"xmark.circle"],
            @[@"\u5173\u95ed", @"xmark.circle"],            // 关闭
            @[@"\u5220\u9664", @"trash.fill"],              // 删除
            @[@"delete", @"trash.fill"],
            @[@"\u79fb\u9664", @"trash.fill"],              // 移除
            @[@"remove", @"trash.fill"],
            @[@"\u6e05\u9664", @"trash.fill"],              // 清除
            @[@"\u786e\u5b9a", @"checkmark.circle.fill"],   // 确定
            @[@"\u786e\u8ba4", @"checkmark.circle.fill"],   // 确认
            @[@"\u597d\u7684", @"checkmark.circle.fill"],   // 好的
            @[@"\u4fdd\u5b58", @"square.and.arrow.down"],   // 保存
            @[@"save", @"square.and.arrow.down"],
            @[@"\u5206\u4eab", @"square.and.arrow.up"],     // 分享
            @[@"share", @"square.and.arrow.up"],
            @[@"\u590d\u5236", @"doc.on.doc"],              // 复制
            @[@"copy", @"doc.on.doc"],
            @[@"\u62f7\u8d1d", @"doc.on.doc"],              // 拷贝
            @[@"\u7f16\u8f91", @"pencil"],                  // 编辑
            @[@"edit", @"pencil"],
            @[@"\u91cd\u547d\u540d", @"pencil"],            // 重命名
            @[@"rename", @"pencil"],
            @[@"\u4e0b\u8f7d", @"arrow.down.circle"],       // 下载
            @[@"download", @"arrow.down.circle"],
            @[@"\u6253\u5f00", @"folder"],                  // 打开
            @[@"open", @"folder"],
            @[@"\u6d4f\u89c8", @"safari"],                  // 浏览（浏览器打开）
            @[@"browser", @"safari"],
            @[@"\u66f4\u591a", @"ellipsis.circle"],         // 更多
            @[@"more", @"ellipsis.circle"],
            @[@"\u9000\u51fa", @"power"],                   // 退出
            @[@"quit", @"power"],
            @[@"exit", @"power"],
            @[@"\u5f3a\u5236\u5173\u95ed", @"power"],      // 强制关闭
            @[@"force close", @"power"],
            @[@"\u767b\u5f55", @"person.crop.circle"],      // 登录
            @[@"login", @"person.crop.circle"],
            @[@"log in", @"person.crop.circle"],
            @[@"\u5e2e\u52a9", @"questionmark.circle"],     // 帮助
            @[@"help", @"questionmark.circle"],
            @[@"\u662f", @"checkmark.circle.fill"],         // 是
            @[@"yes", @"checkmark.circle.fill"],
            @[@"\u5426", @"xmark.circle"],                  // 否
            @[@"no", @"xmark.circle"],
            @[@"ok", @"checkmark.circle.fill"],
            @[@"done", @"checkmark.circle.fill"],
        ];
    });

    for (NSArray<NSString *> *r in rules) {
        NSString *kw = r[0];
        BOOL isCJK = ([kw lengthOfBytesUsingEncoding:NSUTF8StringEncoding] != kw.length);
        if (isCJK || kw.length > 5) {
            if ([t containsString:kw]) return r[1];
        } else {
            if ([t isEqualToString:kw]) return r[1];
        }
    }
    return nil;
}

+ (UIImage *)symbolImageForName:(NSString *)name {
    if (name.length == 0) return nil;
    UIImage *img = [UIImage systemImageNamed:name];
    if (img == nil) img = [UIImage systemImageNamed:@"circle"];
    if (img == nil) return nil;
    UIImageSymbolConfiguration *cfg =
        [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIFontWeightMedium];
    UIImage *scaled = [img imageByApplyingSymbolConfiguration:cfg];
    return scaled ?: img;
}

+ (BOOL)presentGlassMenuForAlert:(UIAlertController *)alert
                   fromPresenter:(UIViewController *)presenter
                         animated:(BOOL)animated
                       completion:(nullable void (^)(void))completion {
    if (![alert isKindOfClass:[UIAlertController class]]) return NO;
    if (presenter == nil) return NO;

    // 镜像动作（UIAlertAction 无公有读取口，走 KVC；任何异常整体回退原生）
    NSMutableArray<Ame237MenuActionMirror *> *mirrors = [NSMutableArray array];
    @try {
        for (UIAlertAction *a in alert.actions) {
            if (![a isKindOfClass:[UIAlertAction class]]) continue;
            Ame237MenuActionMirror *m = [[Ame237MenuActionMirror alloc] init];
            m.orig = a;
            id titleObj = [a valueForKey:@"title"];
            if ([titleObj isKindOfClass:[NSString class]]) m.title = titleObj;
            id styleObj = [a valueForKey:@"style"];
            if ([styleObj isKindOfClass:[NSNumber class]]) m.style = [(NSNumber *)styleObj integerValue];
            id handlerObj = [a valueForKey:@"handler"];
            if (handlerObj != nil) m.handler = handlerObj;
            id enabledObj = [a valueForKey:@"enabled"];
            if ([enabledObj isKindOfClass:[NSNumber class]]) {
                m.enabled = [(NSNumber *)enabledObj boolValue];
            } else {
                m.enabled = YES;
            }
            [mirrors addObject:m];
        }
    } @catch (NSException *e) {
        NSLog(@"[AmeMenu] Task237 action mirror failed (%@) -- native passthrough", e.name);
        return NO;
    }
    if (mirrors.count == 0) return NO;

    Ame237GlassMenuViewController *menu = [[Ame237GlassMenuViewController alloc] init];
    menu.ame237_title = alert.title;
    menu.ame237_message = alert.message;
    menu.ame237_actions = [mirrors copy];
    menu.ame237_alertFields = [alert.textFields copy];
    menu.ame237_animated = animated;
    menu.modalPresentationStyle = UIModalPresentationOverFullScreen;
    menu.modalPresentationCapturesStatusBarAppearance = NO;

    // 本组件自带入场/退场动画——UIKit 侧恒无动画呈现，避免双重转场
    [presenter presentViewController:menu animated:NO completion:^{
        if (completion != nil) completion();
    }];

    static int replacedCount = 0;
    replacedCount++;
    if (replacedCount <= 5 || replacedCount % 25 == 0) {
        NSLog(@"[AmeMenu] Task237 glass menu replaced native alert #%d (alertStyle=%ld actions=%lu fields=%lu title=%@)",
              replacedCount, (long)alert.preferredStyle, (unsigned long)mirrors.count,
              (unsigned long)alert.textFields.count, alert.title);
    }
    return YES;
}

@end

#pragma mark - 中央路由钩子（安装于 UIKit+hook.m）

@implementation UIViewController (Ame237FloatingMenuRouter)

- (void)ame237_hook_presentViewController:(UIViewController *)viewControllerToPresent
                                 animated:(BOOL)flag
                               completion:(nullable void (^)(void))completion {
    if ([viewControllerToPresent isKindOfClass:[UIAlertController class]] && LGCIsGlassStyleActive()) {
        @try {
            if ([AmeFloatingMenu presentGlassMenuForAlert:(UIAlertController *)viewControllerToPresent
                                            fromPresenter:self
                                                 animated:flag
                                               completion:completion]) {
                return;
            }
        } @catch (NSException *e) {
            NSLog(@"[AmeMenu] Task237 router exception (%@) -- native passthrough", e.name);
        }
    }
    // 原生直通（交换后 = 原实现）
    [self ame237_hook_presentViewController:viewControllerToPresent animated:flag completion:completion];
}

@end
