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
#import "BackgroundManager.h"  // Task226: hasBackground
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Task224 存储键与广播名

/// 界面风格存储键（auto / native / liquid_glass，默认 auto）
static NSString * const kLGCPrefInterfaceStyleKey = @"prisma.interface_style";
/// 界面缩放存储键（0.85-1.25 步进 0.05，默认 1.0）
static NSString * const kLGCPrefUIScaleKey = @"prisma.ui_scale";
/// 文字缩放存储键（Task225 #13：0.85-1.30 步进 0.05，默认 1.0；只作用于字号）
static NSString * const kLGCPrefTextScaleKey = @"prisma.text_scale";
/// 文字动态反色开关（Task225 #12/#13：默认开；关 = 固定 labelColor 语义）
static NSString * const kLGCPrefTextAutoContrastKey = @"prisma.text_auto_contrast";

NSNotificationName const LGCInterfaceStyleChangedNotification = @"LGCInterfaceStyleChanged";
NSNotificationName const LGCUIScaleChangedNotification = @"LGCUIScaleChanged";
NSNotificationName const LGCTextScaleChangedNotification = @"LGCTextScaleChanged";
NSNotificationName const LGCTextContrastChangedNotification = @"LGCTextContrastChanged";

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

// ★ Task239（用户指令：iOS 26 原生液态玻璃 API 重写所有悬浮菜单）：系统
//   真 UIGlassEffect 工厂。与 Task228 时代的 _LGCCreateGlassEffect 的三点
//   本质区别：
//   ① 编译期 SDK 门控——CI 已实锤用 Xcode 26.3 / iPhoneOS 26.2 SDK 构建
//     （run 38035649720 日志："★ iPhoneOS SDK = 26.2"），SDK 头里有
//     UIGlassEffect 声明，直接 [[UIGlassEffect alloc] init]（编译器完整
//     类型检查 + 弱链接），不再走 NSClassFromString + objc_msgSend 的
//     无类型裸调（Task228 的 regularEffect 选择器在 SDK 头里并不存在，
//     运行时 respondsToSelector 探测后落到裸 alloc/init——路径对但无
//     编译期保障）；老 SDK 本地构建走运行时类探测回退。
//   ② 诊断开关反向：AME239_NO_SYSTEM_GLASS=1 可一键退回材质磨砂
//     （Task228 的黑屏观察若在新路径上复现，装机侧无需重编译即可分诊）。
//   ③ 只用于"玻璃风格下的悬浮菜单呈现层"，配防御性底色（调用方持有），
//     文字恒为效果层之上的子视图——玻璃若在个别进程环境渲染异常，
//     面板仍是可读的半透明浮层，绝无"透明面板 + 悬浮文字"。
static BOOL ame239_nativeGlassCache = NO;
static BOOL ame239_nativeGlassDecided = NO;

UIVisualEffect *LGCNativeGlassEffect(void) {
    if (!LGCIsLiquidGlassAvailable()) return nil;
    // 诊断开关：装机侧一键禁用（返回 nil = 调用方走材质回退）
    static NSInteger ame239_decision = 0;   // 0=未决 1=启用 -1=禁用
    if (ame239_decision == 0) {
        const char *ame239_env = getenv("AME239_NO_SYSTEM_GLASS");
        ame239_decision = (ame239_env && strcmp(ame239_env, "1") == 0) ? -1 : 1;
    }
    if (ame239_decision == -1) {
        ame239_nativeGlassCache = NO;
        ame239_nativeGlassDecided = YES;
        return nil;
    }
#if defined(__IPHONE_26_0)
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *ame239_glass = [[UIGlassEffect alloc] init];
        if (ame239_glass != nil) {
            ame239_nativeGlassCache = YES;
            ame239_nativeGlassDecided = YES;
            return ame239_glass;
        }
    }
#else
    // 老 SDK（无 UIGlassEffect 声明）的运行时回退：类存在才用（26+ 系统
    // 上弱链接类恒在；26 以下 LGCIsLiquidGlassAvailable 已提前拦截）。
    Class ame239_cls = NSClassFromString(@"UIGlassEffect");
    if (ame239_cls != nil) {
        id ame239_effect = [[ame239_cls alloc] init];
        if ([ame239_effect isKindOfClass:[UIVisualEffect class]]) {
            ame239_nativeGlassCache = YES;
            ame239_nativeGlassDecided = YES;
            return (UIVisualEffect *)ame239_effect;
        }
    }
#endif
    ame239_nativeGlassCache = NO;
    ame239_nativeGlassDecided = YES;
    return nil;
}

BOOL LGCNativeGlassEngaged(void) {
    if (!ame239_nativeGlassDecided) {
        (void)LGCNativeGlassEffect();
    }
    return ame239_nativeGlassCache;
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
    // Task225（#13）：字号只乘【文字缩放】——与界面缩放（LGCScaledValue）
    // 分家。旧版字号乘 ui_scale，用户调界面缩放时文字跟着变，且没有独立的
    // 文字缩放入口（反馈原话：“界面缩放有了，文字缩放怎么没有了”）。
    CGFloat scale = LGCTextScaleMultiplier();
    if (scale == 1.0) return baseSize;
    return baseSize * scale;
}

CGFloat LGCScaledValue(CGFloat baseValue) {
    CGFloat scale = LGCUIScaleMultiplier();
    if (scale == 1.0) return baseValue;
    return baseValue * scale;
}

#pragma mark - Task225 文字缩放（#13）与文字反色开关（#12）

CGFloat LGCTextScaleMultiplier(void) {
    // 0.85-1.30 之外的历史/异常值一律钳回默认 1.0
    double raw = [[NSUserDefaults standardUserDefaults] doubleForKey:kLGCPrefTextScaleKey];
    if (raw < 0.849 || raw > 1.301) return 1.0;
    return (CGFloat)raw;
}

void LGCSetTextScaleMultiplier(CGFloat scale) {
    // 0.05 步进取整 + 双端钳制（0.85-1.30，文字上限比界面略宽——小字号
    // 提到大 1.30 是常见的可及性诉求）
    CGFloat ame225_snapped = (CGFloat)(roundf((float)scale / 0.05f) * 0.05f);
    if (ame225_snapped < 0.85f) ame225_snapped = 0.85f;
    if (ame225_snapped > 1.30f) ame225_snapped = 1.30f;
    [[NSUserDefaults standardUserDefaults] setDouble:(double)ame225_snapped
                                             forKey:kLGCPrefTextScaleKey];
    NSLog(@"[ThemeOps] Task225 text scale -> %.2f", (double)ame225_snapped);
    [[NSNotificationCenter defaultCenter] postNotificationName:LGCTextScaleChangedNotification
                                                        object:@(ame225_snapped)];
}

BOOL LGCTextAutoContrastEnabled(void) {
    // 默认开：只有显式写 NO 才关（objectForKey nil = 从未设置 = 开）
    NSNumber *raw = [[NSUserDefaults standardUserDefaults] objectForKey:kLGCPrefTextAutoContrastKey];
    if (![raw isKindOfClass:[NSNumber class]]) return YES;
    return raw.boolValue;
}

void LGCSetTextAutoContrastEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled
                                             forKey:kLGCPrefTextAutoContrastKey];
    NSLog(@"[ThemeOps] Task225 text auto contrast -> %d", (int)enabled);
    [[NSNotificationCenter defaultCenter] postNotificationName:LGCTextContrastChangedNotification
                                                        object:(enabled ? @YES : @NO)];
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
    // ★ Task225（#4）：组合玻璃的保底层改用系统材质（明暗随系统），
    // 避免旧版 SystemMaterialDark 恒深色在浅色模式下现得突兀；深色请求
    // （isDark=YES）保留深色变体。
    // ★ Task226（反馈 #6：液态玻璃时许多界面都黑了）：SystemThinMaterial
    // 在深色模式下仍偏重，卡片叠深后用户感知为“黑界面”。升级为
    // SystemUltraThinMaterial（最通透的系统材质，壁纸/背景透出最多）；
    // 无壁纸场景的可读性由 LGCApplyGlassToView 的淡染色兑底承担，
    // 不再依赖厚材质压底。
    if (@available(iOS 13.0, *)) {
        return [UIBlurEffect effectWithStyle:isDark ? UIBlurEffectStyleSystemMaterialDark
                                                   : UIBlurEffectStyleSystemUltraThinMaterial];
    } else {
        return [UIBlurEffect effectWithStyle:isDark ? UIBlurEffectStyleDark : UIBlurEffectStyleLight];
    }
}

UIVisualEffectView *LGCCreateGlassEffectView(BOOL isDark) {
    // ★ Task228（用户反馈：切回液态玻璃出现黑色）：Task227 曾把默认切到
    // 真系统 UIGlassEffect（推理：CI 已用 Xcode 26+ SDK 构建，Task225 的
    // "旧 17.5 SDK 构建进程渲染为黑"前提应已消失）。装机实测推翻该推理——
    // 该进程环境（LiveContainer/侧载容器）下系统 UIGlassEffect 依然渲染
    // 为黑，Task225 与 Task228 两次装机实锤。默认改回 Task225 组合玻璃
    // （系统超薄材质 + 调用方高光层 + 发丝描边，装机验证过的渲染路径）；
    // 系统 UIGlassEffect 降级为实验开关：AME227_SYSTEM_GLASS=1 显式开启
    // （分诊用/未来系统侧修复后重试），取不到 regularEffect 也自动回退。
    static NSInteger ame228_glassDecision = 0;   // 0=未决 1=用系统 -1=用组合
    if (ame228_glassDecision == 0) {
        const char *ame228_env = getenv("AME227_SYSTEM_GLASS");
        ame228_glassDecision = (ame228_env && strcmp(ame228_env, "1") == 0) ? 1 : -1;
    }
    if (ame228_glassDecision == 1) {
        UIVisualEffect *ame228_sys = _LGCCreateGlassEffect(isDark);
        if (ame228_sys != nil) {
            static int ame228_sysUsed = 0;
            if (ame228_sysUsed < 3) {
                ame228_sysUsed++;
                NSLog(@"[ThemeOps] Task228 system UIGlassEffect engaged (OPT-IN via AME227_SYSTEM_GLASS=1, use #%d, isDark=%d)",
                      ame228_sysUsed, isDark);
            }
            UIVisualEffectView *ame228_ev = [[UIVisualEffectView alloc] initWithEffect:ame228_sys];
            ame228_ev.frame = CGRectZero;
            ame228_ev.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            ame228_ev.userInteractionEnabled = NO;
            return ame228_ev;
        }
    }
    // Task228 默认路径：组合玻璃（一次性锚点日志，装机可检索）
    static BOOL ame228_compositeLogged = NO;
    if (!ame228_compositeLogged) {
        ame228_compositeLogged = YES;
        NSLog(@"[ThemeOps] Task228 composite glass default (system UIGlassEffect renders black in this process; opt-in trial via AME227_SYSTEM_GLASS=1)");
    }
    UIVisualEffect *effect = _LGCCreateBlurEffect(isDark);
    UIVisualEffectView *effectView = [[UIVisualEffectView alloc] initWithEffect:effect];
    effectView.frame = CGRectZero;
    effectView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    effectView.userInteractionEnabled = NO;
    return effectView;
}

UIVisualEffectView *LGCCreateGlassContainerView(CGFloat spacing, BOOL isDark) {
    // ★ Task225 同上：容器玻璃同样退回系统材质模糊（spacing 语义仅在真
    // UIGlassContainerEffect 下有意义，组合玻璃下由调用方的卡片间距承担）。
    (void)spacing;
    UIVisualEffect *effect = _LGCCreateBlurEffect(isDark);
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
        // Task226：+1 染色兜底层（kLGCGlassSheenTag+1）随玻璃同生命周期拆除
        if (sub.tag == kLGCGlassEffectTag || sub.tag == kLGCGlassSheenTag ||
            sub.tag == kLGCGlassSheenTag + 1) {
            [sub removeFromSuperview];
        }
    }
}

BOOL LGCApplyGlassToView(UIView *view, CGFloat cornerRadius) {
    if (!view) return NO;
    // ★ Task225（#4 崩溃根修）：宿主自身是 UIVisualEffectView 时绝不在其
    // 内部再加效果视图（UIKit 断言 UIVisualEffectView 只能加 contentView；
    // 装机实锤：latestlog.1 终末 NSInternalInconsistencyException
    // "effect=none has been added as a subview to <UIVisualEffectView...>"）。
    // 上移到 superview 再铺（玻璃盖住整个卡面容器，视觉等价）；没有
    // superview 则拒绝（返回 NO 走原生管线，绝不崩溃）。
    if ([view isKindOfClass:[UIVisualEffectView class]]) {
        if (view.superview != nil) {
            NSLog(@"[ThemeOps] Task225 glass host was a UIVisualEffectView -- hoisting to superview (nest guard)");
            view = view.superview;
        } else {
            return NO;
        }
    }
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
    // ★ Task226（反馈 #6：“许多界面都黑了”/无壁纸可读性）：玻璃层接管后
    // 宿主底色清空透壁纸；但【无自定义壁纸】时纯色底直接透进来，深色
    // 模式下显得“黑界面”。补一层极淡的 systemBackground 染色（明暗
    // 自适应 14%）——玻璃质感保留、卡面在任何底色上都有“体”，不裸透。
    if (![[BackgroundManager sharedManager] hasBackground]) {
        UIView *ame226_tint = [[UIView alloc] initWithFrame:view.bounds];
        ame226_tint.tag = kLGCGlassSheenTag + 1;  // 随玻璃层同生命周期清理
        ame226_tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        ame226_tint.layer.cornerRadius = cornerRadius;
        ame226_tint.layer.maskedCorners = view.layer.maskedCorners;
        ame226_tint.layer.masksToBounds = YES;
        ame226_tint.userInteractionEnabled = NO;
        if (@available(iOS 13.0, *)) {
            ame226_tint.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.14];
        } else {
            ame226_tint.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.14];
        }
        [view insertSubview:ame226_tint belowSubview:sheenView];
    }

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

void LGCAdaptBar(UIView *bar) {
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
