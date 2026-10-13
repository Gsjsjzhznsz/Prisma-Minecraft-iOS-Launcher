#import <UIKit/UIKit.h>
#import <UIKit/UIKit.h>
#import "ModItem.h"
#import "ModVersion.h"

NS_ASSUME_NONNULL_BEGIN

@class ModVersionViewController;

@protocol ModVersionViewControllerDelegate <NSObject>
- (void)modVersionViewController:(ModVersionViewController *)viewController didSelectVersion:(ModVersion *)version;
@end

@interface ModVersionViewController : UIViewController

@property (nonatomic, strong) UIActivityIndicatorView *activityIndicator;
@property (nonatomic, strong) ModItem *modItem;
@property (nonatomic, weak) id<ModVersionViewControllerDelegate> delegate;

// FCL 风格：传入当前 profile 的偏好版本和加载器
// ModVersionViewController 会优先选中匹配的 chip，并把匹配的版本置顶
// 不传则保持原有"全部"默认行为
@property (nonatomic, copy, nullable) NSString *preferredGameVersion;
@property (nonatomic, copy, nullable) NSString *preferredLoader;

// ★ Task265（模组管理"新装 mod 不显示"第三轮根修）：目标实例锁定——
// 来源页（模组管理/下载页）显式传入后，本页所有下载/依赖下载统一写入
// 该实例的隔离 mods 目录；未传入时回退实时 selectedProfileName（旧语义）。
// 此前本页无视来源绑定、每次下载实时读 selectedProfileName，与来源页
// 绑定的实例错位时文件落错目录 = 游戏加载了、管理页不显示。
@property (nonatomic, copy, nullable) NSString *targetProfileName;

// API 来源：1 = Modrinth（默认），2 = CurseForge。
// 关键修复（CurseForge 搜索结果丢失来源）：Mod 搜索结果可能来自 CurseForge（数字 project ID），
// 进入版本页时必须沿用搜索时的 API 来源，否则会拿 CurseForge 数字 ID 请求 Modrinth API
// 导致版本列表拉不到。参照 ZL2 的 platform 枚举贯穿搜索→详情→版本全链路。
@property (nonatomic, assign) NSInteger apiSource;

@end

NS_ASSUME_NONNULL_END
