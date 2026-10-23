//
//  AmePluginDetailViewController.h
//  Amethyst
//
//  Task318：插件详情页 —— 信息 / 启停 / 权限组实时开关 / 危险区卸载。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AmePluginDetailViewController : UITableViewController

- (instancetype)initWithPluginId:(NSString *)pluginId NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(nullable NSString *)reuseIdentifier NS_UNAVAILABLE;
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
