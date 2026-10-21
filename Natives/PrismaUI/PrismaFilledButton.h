//
//  PrismaFilledButton.h
//  Amethyst
//
//  Task314：PrismaUI 组件层 —— Fluent 2 按钮。
//
//  三种形态（Fluent 2 button 规范）：
//    Filled  强调底色 + 白字，主操作；
//    Outline 描边 + 强调色字，次操作；
//    Subtle  无底无框 + 强调色字，弱操作。
//
//  实现约束：经典 UIControl/UIButton 路径（UIButtonConfiguration 是 iOS 15+，
//  禁用）；高度 40pt（Fluent 2 medium 控件档），圆角走令牌 radiusControl(4)。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PrismaButtonStyle) {
    PrismaButtonStyleFilled  = 0,
    PrismaButtonStyleOutline = 1,
    PrismaButtonStyleSubtle  = 2,
};

@interface PrismaFilledButton : UIButton

/// 便捷构造：标题 + 形态。字体/配色/圆角全部走 PrismaTheme 令牌。
+ (instancetype)buttonWithTitle:(NSString *)title style:(PrismaButtonStyle)style;

/// 运行时切换形态（重算配色）。
- (void)setPrismaStyle:(PrismaButtonStyle)style;
- (PrismaButtonStyle)prismaStyle;

@end

NS_ASSUME_NONNULL_END
