//
//  PrismaCardView.h
//  Amethyst
//
//  Task314：PrismaUI 组件层 —— Fluent 2 表面卡片。
//
//  结构：外层容器承载阴影（PrismaElevation），内层 contentView 承载圆角
//  裁剪与 hairline 描边——解决"masksToBounds 吃阴影"与"圆角裁剪"的共存
//  问题（见 PrismaTheme applyElevation 注释）。子视图一律加到 contentView。
//

#import <UIKit/UIKit.h>
#import "PrismaTheme.h"  // PrismaElevation 枚举（组件头自含依赖，避免 caller 忘 import）

NS_ASSUME_NONNULL_BEGIN

@interface PrismaCardView : UIView

/// 内容容器（圆角已裁剪，子视图加这里）。
@property(nonatomic, strong, readonly) UIView *contentView;

/// 是否启用 hairline 描边（默认 YES）。
@property(nonatomic, assign) BOOL showsStroke;

/// 启用阴影并指定档位（默认 None；设置后外层容器生效，不与描边互斥）。
@property(nonatomic, assign) PrismaElevation elevation;

/// 明暗切换时重算底色/描边。
- (void)refreshTheme;

@end

NS_ASSUME_NONNULL_END
