//
//  PrismaTheme.h
//  Amethyst
//
//  Task314：PrismaUI 令牌层 —— Fluent 2 设计令牌的原生实现（iOS 14+）。
//
//  色板基准取 Fluent 2 公开规范值（brand-80 #0F6CBD / brand-100 #479EF5、
//  中性面/文字三级、语义色），并叠加本项目两条既有事实：
//    1) 强调色尊重用户偏好 general.accent_color（复用 LauncherPreferences
//       的 accentColor()，默认 #429CF5）——PrismaUI 是视觉事实源，但不是
//       用户偏好之上的暴君；
//    2) 明暗双态一律 dynamic provider 跟随系统，供 BackgroundManager 自定
//       义背景透出的屏幕（clearColor 屏）与标准屏各自成立。
//
//  所有取值 iOS 14 可用：动态色用 colorWithDynamicProvider:（iOS 13+），
//  字体用 systemFontOfSize:weight:（随系统动态字体缩放），不触碰任何
//  iOS 15+ API（UIButtonConfiguration/UISheetPresentationController 等）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Fluent 2 字阶（type ramp）槽位。字号为基准值，UIFont 默认随动态字体缩放。
typedef NS_ENUM(NSInteger, PrismaTextRole) {
    PrismaTextCaption1  = 0,  ///< 12pt regular —— 辅助说明/时间戳
    PrismaTextBody1     = 1,  ///< 14pt regular —— 正文/列表标题
    PrismaTextBody2     = 2,  ///< 16pt regular —— 大正文/输入内容
    PrismaTextSubtitle2 = 3,  ///< 16pt semibold —— 小节标题/卡片标题
    PrismaTextSubtitle1 = 4,  ///< 20pt semibold —— 页面级标题
    PrismaTextTitle1    = 5,  ///< 28pt semibold —— 大标题/欢迎语
};

/// Fluent 2 elevation 档位（阴影强度）。
typedef NS_ENUM(NSInteger, PrismaElevation) {
    PrismaElevationNone = 0,  ///< 无阴影（hairline 描边承担层次）
    PrismaElevation2    = 1,  ///< y1 blur3  α0.15 —— 轻浮层（卡片悬浮态）
    PrismaElevation8    = 2,  ///< y2 blur8  α0.14 —— 中浮层（弹窗卡片）
    PrismaElevation16   = 3,  ///< y4 blur14 α0.13 —— 重浮层（模态）
};

@interface PrismaTheme : NSObject

#pragma mark - 色板（dynamic，明暗双态）

/// 品牌强调色。委托 accentColor()：用户偏好 general.accent_color 优先，
/// 默认 #429CF5。注意返回的是静态解析色（用户偏好运行时可变，取值即快照；
/// 组件在 willMove/trait 观察处重取）。
+ (UIColor *)colorAccent;

/// 画布底色（窗口/大面背景）：亮 #F5F5F5 / 暗 #141414（Fluent neutral-2 / -6）。
+ (UIColor *)colorCanvas;

/// 卡片/表面色：亮 #FFFFFF / 暗 #262626。
+ (UIColor *)colorCard;

/// 卡片悬浮态表面（elevation 下略亮一档）：亮 #FFFFFF / 暗 #2D2D2D。
+ (UIColor *)colorCardElevated;

/// 描边/hairline：亮 #D1D1D1 / 暗 #383838（Fluent neutral stroke）。
+ (UIColor *)colorStroke;

/// 文字一级（标题/正文主色）：亮 #242424 / 暗 #FFFFFF。
+ (UIColor *)colorTextPrimary;

/// 文字二级（副标题/说明）：亮 #424242 / 暗 #CFCFCF。
+ (UIColor *)colorTextSecondary;

/// 文字三级（占位/禁用/时间戳）：亮 #616161 / 暗 #9A9A9A。
+ (UIColor *)colorTextTertiary;

/// 语义色（Fluent 2 规范值；暗态提亮一档保对比度）。
+ (UIColor *)colorDanger;   ///< 亮 #C50F1F / 暗 #F1707B
+ (UIColor *)colorSuccess;  ///< 亮 #0E700E / 暗 #6CCB5F
+ (UIColor *)colorWarning;  ///< 亮 #B75D00 / 暗 #F7B25C

/// 强调色选中态底（菜单高亮等）：强调色 15% 透明度。
+ (UIColor *)colorAccentSelectedBackground;

#pragma mark - 字阶 / 圆角 / 间距 / 阴影

/// 字阶槽位取字体（ systemFontOfSize:weight: ，随系统动态字体缩放）。
+ (UIFont *)fontForRole:(PrismaTextRole)role;

/// 圆角令牌：控件 4 / 表面 8。
+ (CGFloat)radiusControl;
+ (CGFloat)radiusSurface;

/// 4pt 网格间距令牌。
+ (CGFloat)spacingXS;   ///<  4
+ (CGFloat)spacingS;    ///<  8
+ (CGFloat)spacingM;    ///< 12
+ (CGFloat)spacingL;    ///< 16
+ (CGFloat)spacingXL;   ///< 24
+ (CGFloat)spacingXXL;  ///< 32

/// 把 elevation 阴影应用到 layer（含圆角裁剪共存处理；caller 自管 cornerRadius）。
+ (void)applyElevation:(PrismaElevation)elevation toLayer:(CALayer * _Nullable)layer;

#pragma mark - 全局外观

/// 一次性安装全局外观（UIAppearance）：NavBar/TabBar/Switch/Slider/
/// ProgressView/PageControl/RefreshControl 等系统控件 Fluent 化。
/// 在 SceneDelegate willConnectToSession 早期调用一次。
/// 保守清单：不碰 UIWindow 背景与 UILabel 默认色——BackgroundManager
/// 自定义背景体系与各屏既有配色零回归。
+ (void)install;

#pragma mark - Task318：插件主题令牌覆盖

/// 插件主题覆盖（权限中心 theme.write 授权后由桥接层写入）。
/// key 为令牌短名：accent / canvas / card / cardElevated / stroke /
/// textPrimary / textSecondary / textTertiary / danger / success / warning；
/// 值为 #RRGGBB / #RRGGBBAA。整体替换语义（nil = 清空恢复默认）；
/// 非法键/非法色值静默丢弃并留痕。写入后由调用方广播
/// LauncherAppearanceChanged 触发组件重取。
+ (void)setOverrideHexColors:(nullable NSDictionary<NSString *, NSString *> *)hexByToken;

@end

NS_ASSUME_NONNULL_END
