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

/// 字号换算：基准字号 x 倍率（1.0 时与传入值逐字节一致）
FOUNDATION_EXPORT CGFloat LGCScaledFontSize(CGFloat baseSize);

/// 间距/尺寸换算：基准值 x 倍率
FOUNDATION_EXPORT CGFloat LGCScaledValue(CGFloat baseValue);

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
FOUNDATION_EXPORT void LGCAdaptBar(UIBar *bar);

/// 适配 UIBarButtonItem customView：在 iOS 26+ 隐藏共享玻璃背景。
FOUNDATION_EXPORT void LGCAdaptBarButtonItem(UIBarButtonItem *item);

NS_ASSUME_NONNULL_END
