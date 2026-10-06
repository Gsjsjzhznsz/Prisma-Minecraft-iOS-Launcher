//
//  LiquidGlassCompat.m
//  AngelAuraAmethyst
//
//  iOS 26/27 液态玻璃（Liquid Glass）适配层实现
//
//  关键点：
//  1. 项目用 iPhoneOS 17.5 SDK（Xcode 15.4/16）构建，SDK 中没有 UIGlassEffect 声明，
//     因此不能直接 [UIGlassEffect alloc]，必须用 NSClassFromString + objc_msgSend
//     在运行时安全访问 iOS 26+ 的类。
//  2. iOS 26+ 标准控件（UINavigationBar/UITabBar/UIToolbar）会自动获得液态玻璃，
//     前提是移除自定义背景。本文件提供适配函数，让调用方在 iOS 26+ 移除自定义背景。
//  3. 低版本（< iOS 26）完全保持现状，回退到 UIBlurEffectStyleSystemMaterialDark。
//
//  Task224（#4/#19）：新增界面风格中枢（prisma.interface_style）与界面缩放
//  （prisma.ui_scale）的存取/解析/换算；LGCApplyGlassToView 提供分层玻璃
//  （效果层 + 高光渐变层 + 发丝描边）安装原语，native 解析时恒返回 NO，
//  调用方继续既有原生管线——native 模式零视觉回归。
//

#import "LiquidGlassCompat.h"
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Task224 存储键与广播名

/// 界面风格存储键（auto / native / liquid_glass，默认 auto）
static NSString * const kLGCPrefInterfaceStyleKey = @"prisma.interface_style";
/// 界面缩放存储键（0.85-1.25 步进 0.05，默认 1.0）
static NSString * const kLGCPrefUIScaleKey = @"prisma.ui_scale";

NSNotificationName const LGCInterfaceStyleChangedNotification = @"LGCInterfaceStyleChanged";
NSNotificationName const LGCUIScaleChangedNotification = @"LGCUIScaleChanged";

/// 玻璃效果层 tag（安装于宿主视图的 UIVisualEffectView）
static NSInteger const kLGCGlassEffectTag = 888901;
/// 高光渐变 + 发丝描边承载层 tag
static NSInteger const kLGCGlassSheenTag = 888902;

#pragma mark - Task224 界面风格（Interface Style）

/// 检查 iOS 26+ 液态玻璃是否可用
BOOL LGCIsLiquidGlassAvailable(void) {
    // 用 NSProcessInfo 检查系统版本，避免依赖 SDK 中不存在的 API
    NSOperatingSystemVersion osVersion = [[NSProcessInfo processInfo] operatingSystemVersion];
    return osVersion.majorVersion >= 26;
}

NSString *LGCStringFromInterfaceStyle(LGCInterfaceStyle style) {
    switch (style) {
        case LGCInterfaceStyleNative:       return @"native";
        case LGCInterfaceStyleLiquidGlass:  return @"liquid_glass";
        case LGCInterfaceStyleAuto:
        default:                            return @"auto";
    }
}

LGCInterfaceStyle LGCInterfaceStyleFromString(NSString *string) {
    if ([string isKindOfClass:[NSString class]]) {
        if ([string isEqualToString:@"native"]) return LGCInterfaceStyleNative;
        if ([string isEqualToString:@"liquid_glass"]) return LGCInterfaceStyleLiquidGlass;
    }
    return LGCInterfaceStyleAuto;
}

LGCInterfaceStyle LGCStoredInterfaceStyle(void) {
    NSString *raw = [[NSUserDefaults standardUserDefaults] stringForKey:kLGCPrefInterfaceStyleKey];
    return LGCInterfaceStyleFromString(raw);
}

/// 玻璃能力的完整判定：iOS 26+ 且用户未开启「降低透明度」辅助功能
/// （透明材质对开启该辅助的用户是可及性障碍，硬闸门优先于视觉偏好）
static BOOL LGCGlassCapable(void) {
    if (!LGCIsLiquidGlassAvailable()) return NO;
    if (UIAccessibilityIsReduceTransparencyEnabled()) return NO;
    return YES;
}

LGCInterfaceStyle LGCResolvedInterfaceStyle(void) {
    LGCInterfaceStyle stored = LGCStoredInterfaceStyle();
    if (stored == LGCInterfaceStyleNative) return LGCInterfaceStyleNative;
    // auto 与 liquid_glass 共用同一能力判定：能力不足一律回退 native
    return LGCGlassCapable() ? LGCInterfaceStyleLiquidGlass : LGCInterfaceStyleNative;
}

BOOL LGCIsGlassStyleActive(void) {
    return LGCResolvedInterfaceStyle() == LGCInterfaceStyleLiquidGlass;
}

void LGCSetStoredInterfaceStyle(LGCInterfaceStyle style) {
    LGCInterfaceStyle ame224_old = LGCStoredInterfaceStyle();
    [[NSUserDefaults standardUserDefaults] setObject:LGCStringFromInterfaceStyle(style)
                                              forKey:kLGCPrefInterfaceStyleKey];
    LGCInterfaceStyle ame224_resolved = LGCResolvedInterfaceStyle();
    NSLog(@"[ThemeOps] Task224 interface style: stored %@ -> %@, resolved %@ (OS 26+ %d, reduceTransparency %d)",
          LGCStringFromInterfaceStyle(ame224_old), LGCStringFromInterfaceStyle(style),
          LGCStringFromInterfaceStyle(ame224_resolved),
          LGCIsLiquidGlassAvailable(), UIAccessibilityIsReduceTransparencyEnabled());
    [[NSNotificationCenter defaultCenter] postNotificationName:LGCInterfaceStyleChangedNotification
                                                        object:@(ame224_resolved)];
}

#pragma mark - Task224 界面缩放（Interface Zoom）

CGFloat LGCUIScaleMultiplier(void) {
    // 0.85-1.25 之外的历史/异常值一律钳回默认 1.0
    double raw = [[NSUserDefaults standardUserDefaults] doubleForKey:kLGCPrefUIScaleKey];
    if (raw < 0.849 || raw > 1.251) return 1.0;
    return (CGFloat)raw;
}

void LGCSetUIScaleMultiplier(CGFloat scale) {
    // 0.05 步进取整 + 双端钳制
    CGFloat ame224_snapped = (CGFloat)(roundf((float)scale / 0.05f) * 0.05f);
    if (ame224_snapped < 0.85f) ame224_snapped = 0.85f;
    if (ame224_snapped > 1.25f) ame224_snapped = 1.25f;
    [[NSUserDefaults standardUserDefaults] setDouble:(double)ame224_snapped
                                             forKey:kLGCPrefUIScaleKey];
    NSLog(@"[ThemeOps] Task224 ui scale -> %.2f", (double)ame224_snapped);
    [[NSNotificationCenter defaultCenter] postNotificationName:LGCUIScaleChangedNotification
                                                        object:@(ame224_snapped)];
}

CGFloat LGCScaledFontSize(CGFloat baseSize) {
    CGFloat scale = LGCUIScaleMultiplier();
    if (scale == 1.0) return baseSize;
    return baseSize * scale;
}

CGFloat LGCScaledValue(CGFloat baseValue) {
    CGFloat scale = LGCUIScaleMultiplier();
    if (scale == 1.0) return baseValue;
    return baseValue * scale;
}

#pragma mark - iOS 26+ 运行时效果访问（自 FETCH_HEAD 移植）

/// 调用 iOS 26+ 的 [UIGlassEffect regularEffect]（或类似工厂方法）
/// 由于 SDK 没有声明，用 objc_msgSend 调用
static UIVisualEffect *_LGCCreateGlassEffect(BOOL isDark) {
    Class glassEffectClass = NSClassFromString(@"UIGlassEffect");
    if (!glassEffectClass) {
        return nil;
    }
    // iOS 26 UIGlassEffect 有两个主要初始化路径：
    // 1. +[UIGlassEffect regularEffect] / +[UIGlassEffect clearEffect]
    // 2. 通过 appearance 属性区分（UIGlassEffectAppearanceRegular / Clear / Prominent）
    // 这里优先尝试 regularEffect（普通液态玻璃），然后通过 appearance 设置深色。
    SEL regularSel = NSSelectorFromString(@"regularEffect");
    if ([glassEffectClass respondsToSelector:regularSel]) {
        // +[UIGlassEffect regularEffect]
        id effect = ((id (*)(id, SEL))objc_msgSend)(glassEffectClass, regularSel);
        if (effect) {
            // 尝试设置 appearance（如果有的话）
            // UIGlassEffect.appearance 是 UIGlassEffectAppearance 枚举
            // 0 = regular, 1 = clear, 2 = prominent
            // 深色变体通过 tintColor 或 background 调整，这里保持 regular
            return effect;
        }
    }
    // 降级：尝试 alloc/init
    id effect = [[glassEffectClass alloc] init];
    if (effect) {
        return effect;
    }
    return nil;
}

/// 调用 iOS 26+ 的 [UIGlassContainerEffect alloc] initWithSpacing:]
static UIVisualEffect *_LGCCreateGlassContainerEffect(CGFloat spacing) {
    Class containerClass = NSClassFromString(@"UIGlassContainerEffect");
    if (!containerClass) {
        return nil;
    }
    id effect = [[containerClass alloc] init];
    if (effect) {
        // 设置 spacing 属性
        SEL setSpacingSel = NSSelectorFromString(@"setSpacing:");
        if ([effect respondsToSelector:setSpacingSel]) {
            ((void (*)(id, SEL, CGFloat))objc_msgSend)(effect, setSpacingSel, spacing);
        }
        return effect;
    }
    return nil;
}

/// 创建模糊效果（低版本回退）
static UIVisualEffect *_LGCCreateBlurEffect(BOOL isDark) {
    if (@available(iOS 13.0, *)) {
        // UIBlurEffectStyleSystemMaterialDark 始终深色变体
        // UIBlurEffectStyleSystemMaterial 系统自适应
        return [UIBlurEffect effectWithStyle:isDark ? UIBlurEffectStyleSystemMaterialDark : UIBlurEffectStyleSystemMaterial];
    } else {
        return [UIBlurEffect effectWithStyle:isDark ? UIBlurEffectStyleDark : UIBlurEffectStyleLight];
    }
}

UIVisualEffectView *LGCCreateGlassEffectView(BOOL isDark) {
    UIVisualEffect *effect = nil;
    if (LGCIsLiquidGlassAvailable()) {
        effect = _LGCCreateGlassEffect(isDark);
    }
    if (!effect) {
        effect = _LGCCreateBlurEffect(isDark);
    }
    UIVisualEffectView *effectView = [[UIVisualEffectView alloc] initWithEffect:effect];
    effectView.frame = CGRectZero;
    effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    effectView.userInteractionEnabled = NO;
    return effectView;
}

UIVisualEffectView *LGCCreateGlassContainerView(CGFloat spacing, BOOL isDark) {
    UIVisualEffect *effect = nil;
    if (LGCIsLiquidGlassAvailable()) {
        effect = _LGCCreateGlassContainerEffect(spacing);
    }
    if (!effect) {
        effect = _LGCCreateBlurEffect(isDark);
    }
    UIVisualEffectView *effectView = [[UIVisualEffectView alloc] initWithEffect:effect];
    effectView.frame = CGRectZero;
    effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    effectView.userInteractionEnabled = NO;
    return effectView;
}

UIVisualEffectView *LGCApplyGlassBackgroundToView(UIView *view, BOOL isDark) {
    if (!view) return nil;
    // 移除已有的 UIVisualEffectView 子视图（标记）
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIVisualEffectView class]]) {
            [sub removeFromSuperview];
        }
    }
    UIVisualEffectView *effectView = LGCCreateGlassEffectView(isDark);
    effectView.frame = view.bounds;
    effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view insertSubview:effectView atIndex:0];
    return effectView;
}

#pragma mark - Task224 分层玻璃（效果层 + 高光层 + 发丝描边）

/// 高光渐变 + 发丝描边的承载视图。CAGradientLayer 不会随视图 bounds
/// 自动拉伸，用 layoutSubviews 同步 frame（autoresizing 只作用于视图层）。
@interface _LGCSheenView : UIView
@property (nonatomic, strong) CAGradientLayer *sheenLayer;
@end

@implementation _LGCSheenView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;
        self.sheenLayer = [CAGradientLayer layer];
        // 对角高光：左上亮 -> 中段近透明 -> 右下微亮（玻璃折光的常规语言）
        self.sheenLayer.colors = @[
            (id)[[UIColor colorWithWhite:1.0 alpha:0.20] CGColor],
            (id)[[UIColor colorWithWhite:1.0 alpha:0.02] CGColor],
            (id)[[UIColor colorWithWhite:1.0 alpha:0.09] CGColor],
        ];
        self.sheenLayer.locations = @[@0.0, @0.5, @1.0];
        self.sheenLayer.startPoint = CGPointMake(0.0, 0.0);
        self.sheenLayer.endPoint = CGPointMake(1.0, 1.0);
        self.sheenLayer.frame = self.bounds;
        [self.layer addSublayer:self.sheenLayer];
        // 发丝描边：0.75pt 白色低透明度（iOS 26 玻璃边缘的典型观感）
        self.layer.borderWidth = 0.75;
        self.layer.borderColor = [[UIColor colorWithWhite:1.0 alpha:0.32] CGColor];
        self.layer.cornerCurve = kCACornerCurveContinuous;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.sheenLayer.frame = self.bounds;
}

@end

void LGCRemoveGlassFromView(UIView *view) {
    if (!view) return;
    for (UIView *sub in [view.subviews copy]) {
        if (sub.tag == kLGCGlassEffectTag || sub.tag == kLGCGlassSheenTag) {
            [sub removeFromSuperview];
        }
    }
}

BOOL LGCApplyGlassToView(UIView *view, CGFloat cornerRadius) {
    if (!view) return NO;
    // 幂等：先清旧层再重建（重复调用安全）
    LGCRemoveGlassFromView(view);
    if (!LGCIsGlassStyleActive()) return NO;
    if (cornerRadius <= 0.5) return NO;

    // 第一层：模糊/玻璃效果（iOS 26+ 为 UIGlassEffect，否则系统材质模糊）
    UIVisualEffectView *effectView = LGCCreateGlassEffectView(NO);
    effectView.tag = kLGCGlassEffectTag;
    effectView.frame = view.bounds;
    effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    effectView.layer.cornerRadius = cornerRadius;
    effectView.layer.cornerCurve = kCACornerCurveContinuous;
    // 宿主若只圆部分角（VS 布局侧栏仅外侧圆角），玻璃层跟随同一组角
    effectView.layer.maskedCorners = view.layer.maskedCorners;
    effectView.layer.masksToBounds = YES;
    [view insertSubview:effectView atIndex:0];

    // 第二层：高光渐变 + 发丝描边（在效果层之上、内容之下）
    _LGCSheenView *sheenView = [[_LGCSheenView alloc] initWithFrame:view.bounds];
    sheenView.tag = kLGCGlassSheenTag;
    sheenView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sheenView.layer.cornerRadius = cornerRadius;
    sheenView.layer.maskedCorners = view.layer.maskedCorners;
    [view insertSubview:sheenView aboveSubview:effectView];

    // 玻璃接管卡面后宿主底色清空（原生管线的底色/毛玻璃由 LGCRemoveGlass
    // + 调用方重铺还原）
    view.backgroundColor = [UIColor clearColor];
    NSLog(@"[ThemeOps] Task224 layered glass applied (radius %.1f)", (double)cornerRadius);
    return YES;
}

#pragma mark - iOS 26+ 标准控件适配（自 FETCH_HEAD 移植）

void LGCAdaptNavigationBar(UINavigationBar *navigationBar) {
    if (!navigationBar) return;
    if (!LGCIsLiquidGlassAvailable()) return;
    // iOS 26+: 移除自定义背景，让系统接管液态玻璃
    // 标准做法：使用 transparent 背景，让 scrollEdgeAppearance 的标准配置生效
    // 1. 设置标准 Appearance 为 transparent
    if (@available(iOS 13.0, *)) {
        UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
        [appearance configureWithTransparentBackground];
        navigationBar.standardAppearance = appearance;
        navigationBar.scrollEdgeAppearance = appearance;
        // iOS 26+ compactAppearance 也设置
        navigationBar.compactAppearance = appearance;
    }
    // 2. 移除背景图片（如果有）
    [navigationBar setBackgroundImage:nil forBarMetrics:UIBarMetricsDefault];
    [navigationBar setShadowImage:nil];
    // 3. 设置 translucent = YES（液态玻璃需要透明）
    navigationBar.translucent = YES;
}

void LGCAdaptBar(UIBar *bar) {
    if (!bar) return;
    if (!LGCIsLiquidGlassAvailable()) return;
    // UIToolbar / UITabBar 通用适配：移除自定义背景
    if ([bar isKindOfClass:[UIToolbar class]]) {
        UIToolbar *toolbar = (UIToolbar *)bar;
        if (@available(iOS 13.0, *)) {
            UIToolbarAppearance *appearance = [UIToolbarAppearance new];
            [appearance configureWithTransparentBackground];
            toolbar.standardAppearance = appearance;
            toolbar.compactAppearance = appearance;
            if (@available(iOS 15.0, *)) {
                toolbar.scrollEdgeAppearance = appearance;
            }
        }
        toolbar.barStyle = UIBarStyleDefault;
        [toolbar setBarTintColor:nil];
    } else if ([bar isKindOfClass:[UITabBar class]]) {
        UITabBar *tabBar = (UITabBar *)bar;
        if (@available(iOS 13.0, *)) {
            UITabBarAppearance *appearance = [UITabBarAppearance new];
            [appearance configureWithTransparentBackground];
            tabBar.standardAppearance = appearance;
            if (@available(iOS 15.0, *)) {
                tabBar.scrollEdgeAppearance = appearance;
            }
        }
        tabBar.barStyle = UIBarStyleDefault;
        [tabBar setBarTintColor:nil];
    }
}

void LGCAdaptBarButtonItem(UIBarButtonItem *item) {
    if (!item) return;
    if (!LGCIsLiquidGlassAvailable()) return;
    // iOS 26+: 隐藏 customView 周围的共享玻璃背景
    // hidesSharedBackground 是 iOS 26+ 新属性
    SEL hidesSharedBackgroundSel = NSSelectorFromString(@"setHidesSharedBackground:");
    if ([item respondsToSelector:hidesSharedBackgroundSel]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(item, hidesSharedBackgroundSel, YES);
    }
}
