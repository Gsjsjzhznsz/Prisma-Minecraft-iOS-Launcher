//
//  PrismaTheme.m
//  Amethyst
//
//  Task314：PrismaUI 令牌层实现。设计依据见同目录 PrismaTheme.h 头注与
//  docs/decisions/2026-10-21-ui-architecture-prisma-ui.md。
//

#import "PrismaTheme.h"
#import "LauncherPreferences.h"  // accentColor()（general.accent_color 用户偏好）

@implementation PrismaTheme

#pragma mark - 色板

/// Fluent 2 动态色便捷构造（iOS 13+ API，iOS 14 全量可用）。
static UIColor *PrismaDynamic(UIColor *light, UIColor *dark) {
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *tc) {
        return (tc.userInterfaceStyle == UIUserInterfaceStyleDark) ? dark : light;
    }];
}

+ (UIColor *)colorAccent {
    // 用户自定义强调色优先（与全应用 accentColor() 消费点同一事实源）；
    // 返回前经 dynamic 包装无意义（偏好值本身是静态解析色），
    // 直接返回快照，组件在重布局时机重取。
    return accentColor();
}

+ (UIColor *)colorCanvas {
    return PrismaDynamic([UIColor colorWithRed:0.9608 green:0.9608 blue:0.9608 alpha:1.0],   // #F5F5F5
                         [UIColor colorWithRed:0.0784 green:0.0784 blue:0.0784 alpha:1.0]);  // #141414
}

+ (UIColor *)colorCard {
    return PrismaDynamic([UIColor whiteColor],
                         [UIColor colorWithRed:0.1490 green:0.1490 blue:0.1490 alpha:1.0]);  // #262626
}

+ (UIColor *)colorCardElevated {
    return PrismaDynamic([UIColor whiteColor],
                         [UIColor colorWithRed:0.1765 green:0.1765 blue:0.1765 alpha:1.0]);  // #2D2D2D
}

+ (UIColor *)colorStroke {
    return PrismaDynamic([UIColor colorWithRed:0.8196 green:0.8196 blue:0.8196 alpha:1.0],   // #D1D1D1
                         [UIColor colorWithRed:0.2196 green:0.2196 blue:0.2196 alpha:1.0]);  // #383838
}

+ (UIColor *)colorTextPrimary {
    return PrismaDynamic([UIColor colorWithRed:0.1412 green:0.1412 blue:0.1412 alpha:1.0],   // #242424
                         [UIColor whiteColor]);
}

+ (UIColor *)colorTextSecondary {
    return PrismaDynamic([UIColor colorWithRed:0.2588 green:0.2588 blue:0.2588 alpha:1.0],   // #424242
                         [UIColor colorWithRed:0.8118 green:0.8118 blue:0.8118 alpha:1.0]);  // #CFCFCF
}

+ (UIColor *)colorTextTertiary {
    return PrismaDynamic([UIColor colorWithRed:0.3804 green:0.3804 blue:0.3804 alpha:1.0],   // #616161
                         [UIColor colorWithRed:0.6039 green:0.6039 blue:0.6039 alpha:1.0]);  // #9A9A9A
}

+ (UIColor *)colorDanger {
    return PrismaDynamic([UIColor colorWithRed:0.7725 green:0.0588 blue:0.1216 alpha:1.0],   // #C50F1F
                         [UIColor colorWithRed:0.9451 green:0.4392 blue:0.4824 alpha:1.0]);  // #F1707B
}

+ (UIColor *)colorSuccess {
    return PrismaDynamic([UIColor colorWithRed:0.0549 green:0.4392 blue:0.0549 alpha:1.0],   // #0E700E
                         [UIColor colorWithRed:0.4235 green:0.7961 blue:0.3725 alpha:1.0]);  // #6CCB5F
}

+ (UIColor *)colorWarning {
    return PrismaDynamic([UIColor colorWithRed:0.7176 green:0.3647 blue:0.0000 alpha:1.0],   // #B75D00
                         [UIColor colorWithRed:0.9686 green:0.6980 blue:0.3608 alpha:1.0]);  // #F7B25C
}

+ (UIColor *)colorAccentSelectedBackground {
    // Task314：与 LauncherMenuViewController 既有选中态配方同值
    // （accent 15%），先收敛成令牌，后续屏迁移时统一走这里。
    return [[self colorAccent] colorWithAlphaComponent:0.15];
}

#pragma mark - 字阶

+ (UIFont *)fontForRole:(PrismaTextRole)role {
    // systemFontOfSize:weight: 返回值自带动态字体缩放（iOS 11+ 全量行为），
    // 无需 UIFontMetrics 手动匹配——iOS 14 兼容的最省路径。
    switch (role) {
        case PrismaTextCaption1:  return [UIFont systemFontOfSize:12.0 weight:UIFontWeightRegular];
        case PrismaTextBody1:     return [UIFont systemFontOfSize:14.0 weight:UIFontWeightRegular];
        case PrismaTextBody2:     return [UIFont systemFontOfSize:16.0 weight:UIFontWeightRegular];
        case PrismaTextSubtitle2: return [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
        case PrismaTextSubtitle1: return [UIFont systemFontOfSize:20.0 weight:UIFontWeightSemibold];
        case PrismaTextTitle1:    return [UIFont systemFontOfSize:28.0 weight:UIFontWeightSemibold];
    }
    return [UIFont systemFontOfSize:14.0];
}

#pragma mark - 圆角 / 间距

+ (CGFloat)radiusControl { return 4.0; }
+ (CGFloat)radiusSurface { return 8.0; }

+ (CGFloat)spacingXS  { return 4.0;  }
+ (CGFloat)spacingS   { return 8.0;  }
+ (CGFloat)spacingM   { return 12.0; }
+ (CGFloat)spacingL   { return 16.0; }
+ (CGFloat)spacingXL  { return 24.0; }
+ (CGFloat)spacingXXL { return 32.0; }

#pragma mark - 阴影

+ (void)applyElevation:(PrismaElevation)elevation toLayer:(CALayer *)layer {
    if (layer == nil) return;
    CGFloat y, blur, alpha;
    switch (elevation) {
        case PrismaElevation2:  y = 1.0; blur = 3.0;  alpha = 0.15; break;
        case PrismaElevation8:  y = 2.0; blur = 8.0;  alpha = 0.14; break;
        case PrismaElevation16: y = 4.0; blur = 14.0; alpha = 0.13; break;
        default:
            layer.shadowOpacity = 0.0;
            return;
    }
    layer.shadowColor = [UIColor blackColor].CGColor;
    layer.shadowOpacity = alpha;
    layer.shadowOffset = CGSizeMake(0, y);
    layer.shadowRadius = blur;
    // 阴影沿不透明内容裁剪；caller 若开 masksToBounds 会吃掉阴影，
    // 由 caller 在"圆角+描边"与"阴影"之间按层级拆分（卡片外层浮层承载阴影）。
    layer.masksToBounds = NO;
}

#pragma mark - 全局外观安装

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        UIColor *accent = [self colorAccent];

        // 导航栏：卡片面 + 一级文字 + 系统默认 hairline 保留（层次感保守优先）
        UINavigationBarAppearance *nav = [[UINavigationBarAppearance alloc] init];
        [nav configureWithDefaultBackground];
        nav.backgroundColor = [self colorCard];
        nav.titleTextAttributes = @{ NSForegroundColorAttributeName: [self colorTextPrimary] };
        nav.largeTitleTextAttributes = @{ NSForegroundColorAttributeName: [self colorTextPrimary] };
        [UINavigationBar appearance].standardAppearance = nav;
        [UINavigationBar appearance].compactAppearance = nav;
        [UINavigationBar appearance].tintColor = accent;
        // scrollEdgeAppearance 是 iOS 15+ API（iOS 14 上赋值 = unrecognized
        // selector 必崩），必须在 @available 内写入。
        if (@available(iOS 15.0, *)) {
            [UINavigationBar appearance].scrollEdgeAppearance = nav;
        }

        // 标签栏（本启动器当前少用，但浮层复用其容器体系时保持一致）
        UITabBarAppearance *tab = [[UITabBarAppearance alloc] init];
        [tab configureWithDefaultBackground];
        tab.backgroundColor = [self colorCard];
        [UITabBar appearance].standardAppearance = tab;
        [UITabBar appearance].tintColor = accent;
        [UITabBar appearance].unselectedItemTintColor = [self colorTextTertiary];

        // 表单控件强调色统一
        [UISwitch appearance].onTintColor = accent;
        [UISlider appearance].minimumTrackTintColor = accent;
        [UISlider appearance].thumbTintColor = accent;
        [UIProgressView appearance].progressTintColor = accent;
        [UIProgressView appearance].trackTintColor = [self colorStroke];
        [UIPageControl appearance].currentPageIndicatorTintColor = accent;
        [UIPageControl appearance].pageIndicatorTintColor = [self colorStroke];
        [UIRefreshControl appearance].tintColor = accent;
        [UIActivityIndicatorView appearance].color = accent;

        // 搜索框：光标/编辑强调
        [UITextField appearance].tintColor = accent;
    });
}

@end
