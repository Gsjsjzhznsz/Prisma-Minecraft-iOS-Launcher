//
//  LiquidGlassCompat.h
//  AngelAuraAmethyst
//
//  iOS 26/27 液态玻璃（Liquid Glass）适配层
//  在 iOS 26+ 使用 UIGlassEffect/UIGlassContainerEffect，
//  低版本回退到 UIBlurEffectStyleSystemMaterialDark 等现有模糊效果。
//
//  Task224（反馈 #4/#19）：本层升格为界面风格（Interface Style）中枢。
//  设置页新增「外观」分区（键 prisma.interface_style：auto / native /
//  liquid_glass，默认 auto）。解析规则：auto = iOS 26+ 且系统未开启
//  「降低透明度」时用液态玻璃，否则原生；native = 与今日外观逐字节一致；
//  liquid_glass = 强制玻璃（iOS 26 以下或降低透明度开启时自动回退原生）。
//  同文件附带界面缩放（prisma.ui_scale，0.85-1.25 步进 0.05，默认 1.0）
//  的取值/写值与换算助手（反馈 #19）。
//
//  Task225（反馈 #4/#12/#13）：
//  ★ 卡面玻璃改【组合玻璃】（保底系统材质模糊 + 高光渐变 + 发丝描边），
//    不再直接使用 UIGlassEffect（旧 SDK 进程上渲染不完整 → 黑屏实锤）；
//    标准控件仍交还系统绘制真液态玻璃。
//  ★ 文字缩放（prisma.text_scale，0.85-1.30）独立成键——字号只乘它，
//    界面尺寸只乘 ui_scale。
//  ★ 文字动态反色开关（prisma.text_auto_contrast，默认开）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 界面风格（存储值，prisma.interface_style）
typedef NS_ENUM(NSInteger, LGCInterfaceStyle) {
    LGCInterfaceStyleAuto = 0,
    LGCInterfaceStyleNative,
    LGCInterfaceStyleLiquidGlass
};

/// 界面风格变化广播（object = 解析后的 LGCInterfaceStyle 包装为 NSNumber）
FOUNDATION_EXPORT NSNotificationName const LGCInterfaceStyleChangedNotification;
/// 界面缩放变化广播（object = 新倍率包装为 NSNumber）
FOUNDATION_EXPORT NSNotificationName const LGCUIScaleChangedNotification;
/// 文字缩放变化广播（Task225 #13；object = 新倍率包装为 NSNumber）
FOUNDATION_EXPORT NSNotificationName const LGCTextScaleChangedNotification;
/// 文字动态反色开关变化广播（Task225 #12；object = NSNumber BOOL）
FOUNDATION_EXPORT NSNotificationName const LGCTextContrastChangedNotification;

/// 判断当前系统是否支持液态玻璃（iOS 26+）
FOUNDATION_EXPORT BOOL LGCIsLiquidGlassAvailable(void);

// ============================================================================
// Task224（#4）：界面风格存取与解析
// ============================================================================

/// 读取存储的风格（NSUserDefaults 键 prisma.interface_style，默认 auto）
FOUNDATION_EXPORT LGCInterfaceStyle LGCStoredInterfaceStyle(void);

/// 写入风格并广播 LGCInterfaceStyleChangedNotification
FOUNDATION_EXPORT void LGCSetStoredInterfaceStyle(LGCInterfaceStyle style);

/// 解析为实际生效风格：
/// - auto：iOS 26+ 且未开启「降低透明度」→ LiquidGlass，否则 Native
/// - native：恒 Native
/// - liquid_glass：iOS 26+ 且未开启「降低透明度」→ LiquidGlass，否则 Native
/// （即「降低透明度」是硬闸门——辅助功能优先于视觉偏好）
FOUNDATION_EXPORT LGCInterfaceStyle LGCResolvedInterfaceStyle(void);

/// 便捷判定：当前是否应呈现液态玻璃外观（native 恒 NO = 原路径零回归）
FOUNDATION_EXPORT BOOL LGCIsGlassStyleActive(void);

/// ★ Task239（用户指令："请用 iOS 26 原生液态玻璃 API 重写所有悬浮菜单…
///   使用 .glassEffect()（SwiftUI）或 UIGlassEffect（UIKit）实现真正的
///   液态玻璃弹窗"）：系统原生 UIGlassEffect 工厂。iOS 26+ 返回真玻璃
///   效果对象；取不到（<iOS 26 / 老 SDK 运行时类缺失 / 诊断开关
///   AME239_NO_SYSTEM_GLASS=1）返回 nil，调用方回退系统材质磨砂
///   （UIBlurEffect SystemMaterial 家族），绝不回退 UIAlertController。
///   玻璃风格下所有悬浮菜单统一走本工厂；原生风格不经过此处。
///   （CI r1 教训：顶层 C 函数声明的可空性必须用 "* _Nullable" 后缀
///   形式——非下划线 nullable 前缀是 ObjC 方法/属性专属语法，clang 在
///   函数声明处报 unknown type name 并丢弃整个声明。）
FOUNDATION_EXPORT UIVisualEffect * _Nullable LGCNativeGlassEffect(void);

/// Task239：LGCNativeGlassEffect() 是否真的取到了系统 UIGlassEffect
/// （供调用方选择防御性底色浓度与日志锚点；NO = 走了材质回退）。
FOUNDATION_EXPORT BOOL LGCNativeGlassEngaged(void);

/// 风格 <-> 存储字符串（"auto" / "native" / "liquid_glass"）
FOUNDATION_EXPORT NSString *LGCStringFromInterfaceStyle(LGCInterfaceStyle style);
FOUNDATION_EXPORT LGCInterfaceStyle LGCInterfaceStyleFromString(NSString *string);

// ============================================================================
// Task224（#19）：界面缩放（Interface Zoom）存取与换算
// ============================================================================

/// 读取缩放倍率（NSUserDefaults 键 prisma.ui_scale，默认 1.0，钳制 0.85-1.25）
FOUNDATION_EXPORT CGFloat LGCUIScaleMultiplier(void);

/// 写入缩放（会做 0.05 步进取整 + 0.85-1.25 钳制）并广播
/// LGCUIScaleChangedNotification
FOUNDATION_EXPORT void LGCSetUIScaleMultiplier(CGFloat scale);

/// 字号换算：基准字号 x 【文字缩放倍率】（Task225 #13 分家；1.0 时与传入值逐字节一致）
FOUNDATION_EXPORT CGFloat LGCScaledFontSize(CGFloat baseSize);

/// 间距/尺寸换算：基准值 x 【界面缩放倍率】
FOUNDATION_EXPORT CGFloat LGCScaledValue(CGFloat baseValue);

// ============================================================================
// Task225（#13）：文字缩放（Text Scale）存取
// ============================================================================

/// 读取文字缩放倍率（NSUserDefaults 键 prisma.text_scale，默认 1.0，钳制 0.85-1.30）
FOUNDATION_EXPORT CGFloat LGCTextScaleMultiplier(void);

/// 写入文字缩放（0.05 步进取整 + 0.85-1.30 钳制）并广播 LGCTextScaleChangedNotification
FOUNDATION_EXPORT void LGCSetTextScaleMultiplier(CGFloat scale);

// ============================================================================
// Task225（#12/#13）：文字动态反色开关存取
// ============================================================================

/// 读取文字动态反色开关（键 prisma.text_auto_contrast，默认开）
FOUNDATION_EXPORT BOOL LGCTextAutoContrastEnabled(void);

/// 写入开关并广播 LGCTextContrastChangedNotification
FOUNDATION_EXPORT void LGCSetTextAutoContrastEnabled(BOOL enabled);

// ============================================================================
// 液态玻璃视图工厂与适配（自 ui/fcl-liquid-glass 分支 23cd527e 移植）
// ============================================================================

/// 创建一个液态玻璃 UIVisualEffectView。
/// - iOS 26+：使用 UIGlassEffect（普通变体）
/// - 低版本：回退到 UIBlurEffectStyleSystemMaterialDark
/// @param isDark 是否使用深色变体（低版本回退时区分深浅色）
FOUNDATION_EXPORT UIVisualEffectView *LGCCreateGlassEffectView(BOOL isDark);

/// 创建一个液态玻璃容器 UIVisualEffectView（用于多个 glass 元素组合）。
/// - iOS 26+：使用 UIGlassContainerEffect
/// - 低版本：回退到普通模糊
/// @param spacing 元素间距（仅 iOS 26+ 生效）
FOUNDATION_EXPORT UIVisualEffectView *LGCCreateGlassContainerView(CGFloat spacing, BOOL isDark);

/// 给视图应用液态玻璃背景（替换 BackgroundManager 的模糊效果）。
/// 如果视图已有 UIVisualEffectView 子视图会被替换。
/// - iOS 26+：UIGlassEffect
/// - 低版本：UIBlurEffectStyleSystemMaterialDark
/// @param view 目标视图
/// @param isDark 深色变体
/// @return 应用的 UIVisualEffectView（便于后续配置）
FOUNDATION_EXPORT UIVisualEffectView *LGCApplyGlassBackgroundToView(UIView *view, BOOL isDark);

/// Task224（#4）核心：给卡片表面安装「分层玻璃」——模糊/玻璃效果层 +
/// 高光渐变（sheen）层 + 发丝描边（hairline border）。幂等：重复调用先
/// 移除旧层再重建；LGCRemoveGlassFromView 可完整还原。
/// 返回 NO 时（风格解析为 native，或 cornerRadius <= 0）调用方继续走
/// 既有的原生管线——native 模式零视觉回归由该返回值保证。
/// @param view 目标视图（圆角/描边随 cornerRadius 参数）
/// @param cornerRadius 玻璃层圆角（通常与宿主 layer.cornerRadius 一致）
FOUNDATION_EXPORT BOOL LGCApplyGlassToView(UIView *view, CGFloat cornerRadius);

/// 移除 LGCApplyGlassToView 安装的全部玻璃层（含高光/描边）
FOUNDATION_EXPORT void LGCRemoveGlassFromView(UIView *view);

/// 适配 UINavigationBar：在 iOS 26+ 移除自定义背景让系统接管液态玻璃。
/// 低版本保持现状（由调用方自行配置标准Appearance）。
FOUNDATION_EXPORT void LGCAdaptNavigationBar(UINavigationBar *navigationBar);

/// 适配 UIToolbar/UITabBar：在 iOS 26+ 移除自定义背景。
FOUNDATION_EXPORT void LGCAdaptBar(UIView *bar);   // Task224 CI r2：UIBar 非真实 UIKit 类型（分支原生笔误），UIView 参数承接 UIToolbar/UITabBar

/// 适配 UIBarButtonItem customView：在 iOS 26+ 隐藏共享玻璃背景。
FOUNDATION_EXPORT void LGCAdaptBarButtonItem(UIBarButtonItem *item);

NS_ASSUME_NONNULL_END
