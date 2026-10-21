//
//  PrismaListCell.h
//  Amethyst
//
//  Task314：PrismaUI 组件层 —— Fluent 2 列表项单元格。
//
//  结构：可选前导图标槽（32×32 圆角容器）+ 标题（body1）+ 可选副标题
//  （caption1）+ 尾随 chevron。选中态 = accent 8% 底。
//  设计基准高：44pt（单行）/ 56pt（双行），intrinsic 已兜底。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PrismaListCell : UITableViewCell

/// 标题（body1 / textPrimary）。
@property(nonatomic, copy, nullable) NSString *prismaTitle;

/// 副标题（caption1 / textTertiary；nil 时隐藏，行高回落单行档）。
@property(nonatomic, copy, nullable) NSString *prismaSubtitle;

/// 前导图标（SF Symbol 名；nil 时隐藏图标槽）。
@property(nonatomic, copy, nullable) NSString *prismaIconName;

/// 是否显示尾随 chevron（默认 YES，导航型列表项）。
@property(nonatomic, assign) BOOL showsChevron;

/// 图标槽是否着强调色（默认 YES；传入普通图片时按 tint 渲染）。
@property(nonatomic, assign) BOOL iconTintedWithAccent;

/// 明暗切换 / 强调色偏好变更时重算。
- (void)refreshTheme;

@end

NS_ASSUME_NONNULL_END
