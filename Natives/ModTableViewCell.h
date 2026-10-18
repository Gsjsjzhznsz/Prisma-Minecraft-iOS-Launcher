//
//  ModTableViewCell.h
//  Amethyst
//
//  Mod 卡片 Cell（继承 ResourceCardTableViewCell，Prisma-Design L2 标准卡片）
//  卡片背景 / 圆角 / 阴影 / 图标容器 / 文字层级 / accessory 插槽均由基类提供，
//  本类只负责：Mod 专属图标（jar 内嵌图标 / 加载器品牌图标）、
//  ModItem 内容配置、启用开关、更新徽章与在线模式按钮。
//

#import <UIKit/UIKit.h>
#import "ResourceCardTableViewCell.h"

@class ModItem;

NS_ASSUME_NONNULL_BEGIN

// Display mode for the cell
typedef NS_ENUM(NSInteger, ModTableViewCellDisplayMode) {
    ModTableViewCellDisplayModeLocal,
    ModTableViewCellDisplayModeOnline
};

@protocol ModTableViewCellDelegate <NSObject>
- (void)modCellDidTapToggle:(UITableViewCell *)cell;
- (void)modCellDidTapOpenLink:(UITableViewCell *)cell;
@optional // Optional because it's only for online mode
- (void)modCellDidTapDownload:(UITableViewCell *)cell;
@end

@interface ModTableViewCell : ResourceCardTableViewCell

// --- Configuration ---
- (void)configureWithMod:(ModItem *)mod displayMode:(ModTableViewCellDisplayMode)mode;

// --- State Updates ---
/// 同步启用开关状态（disabled=YES 时开关关闭且卡片内容降透明度）
- (void)updateToggleState:(BOOL)disabled;

/// 显示/隐藏更新徽章（arrow.up.circle.fill accent 色，由管理页检测更新后传入）
- (void)setUpdateAvailable:(BOOL)available;

/// ★ Task288（PocketJ 对标移植·实例级模组管理：加载器不兼容标记）：
/// 本地模组与生效实例加载器错配时显示橙色警告徽章（exclamationmark.
/// triangle.fill），并把说明文本追加到元信息行尾（如"加载器不兼容
/// （NeoForge 实例）"）。detail 传 nil 清除标记（复用/错配解除路径）。
- (void)setLoaderIncompatibleDetail:(nullable NSString *)detail;

@property (nonatomic, weak) id<ModTableViewCellDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
