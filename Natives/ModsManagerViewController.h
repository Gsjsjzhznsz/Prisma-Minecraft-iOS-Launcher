//
//  ModsManagerViewController.h
//  Amethyst
//
//  Mod 管理页（继承 ResourceListViewController 基类）
//  基类提供：毛玻璃背景、胶囊搜索栏、卡片表格、空/加载态、
//  批量选择模式底部工具栏、连锁进场动画。
//  本类负责：Mod 数据加载、筛选（全部/已启用/已禁用）与排序、
//  批量启用/禁用/删除、内置更新检测与下载替换。
//

#import "ResourceListViewController.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModsManagerViewController : ResourceListViewController

/// 目标 profile 名（nil 时按 default 处理）
@property (nonatomic, copy, nullable) NSString *profileName;

/// Task267：本页 profile 绑定语义。
/// NO（默认）= 跟随模式——实时跟随 PLProfiles.selectedProfileName
///（SelectedProfileChanged 即重扫），页面永不过期；
/// YES = 钉定模式——锁定 profileName，选中实例变化不再跟走。
/// 语义入口（版本管理"管理此版本模组"/设置页 gameDir 入口）与用户在
/// 切换器里的显式选择都会置 YES；抽屉主入口不设置 → 全程跟随。
@property (nonatomic, assign) BOOL ame267_pinProfile;

/// Task267：钉定到指定实例（profileName + ame267_pinProfile=YES）并刷新
/// 切换器/表尾/列表。版本管理、设置页等语义入口与切换器共用。
- (void)ame267_pinToProfile:(nullable NSString *)profileName;

@end

NS_ASSUME_NONNULL_END
