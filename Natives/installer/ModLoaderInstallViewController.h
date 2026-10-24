//
//  ModLoaderInstallViewController.h
//  Amethyst
//
//  参照 FCL (FoldCraftLauncher) 的模组加载器选择界面重构。
//  - 加载器列表用 UITableView Grouped 风格，行卡片式选择
//  - 互斥逻辑：forge/fabric/quilt/neoforge 互斥；
//              optifine 与 fabric/quilt/neoforge 互斥（与 forge 可共存）；
//              fabricApi 依赖 fabric，与 forge/optifine/neoforge 互斥
//  - 版本选择 push 到独立的 ModLoaderVersionPickerViewController，避免主页面布局挤压
//  - 底部安装按钮钉在 safeArea 底部，iPhone 上不会显示不全
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 加载器类型标识（与外部安装分发器约定一致）
typedef NS_ENUM(NSInteger, ModLoaderKind) {
    ModLoaderKindVanilla  = 0,
    ModLoaderKindFabric   = 1,
    ModLoaderKindForge    = 2,
    ModLoaderKindNeoForge = 3,
    ModLoaderKindQuilt    = 4,
    ModLoaderKindOptiFine = 5,  // 单独安装 OptiFine（不与 Forge 共存），作为版本补丁
};

/// 模组加载器安装选择 VC（参照 FCL InstallerListPage + VersionInstallInfoPage）
@interface ModLoaderInstallViewController : UIViewController

/// 待安装的游戏版本，如 "1.20.1"
@property (nonatomic, copy) NSString *gameVersion;

/// 完成回调：loaderId 为 @"vanilla"/@"fabric"/@"forge"/@"neoforge"/@"quilt"/@"optifine"，
/// installFabricAPI 仅在 fabric 选中时可能为 YES，
/// installOptiFine 在 forge 选中时（作为 mod 共存）或 optifine 单独选中时为 YES，
/// loaderVersion 为加载器版本号（vanilla 时为 nil）
@property (nonatomic, copy) void (^completion)(NSString *loaderId,
                                               BOOL installFabricAPI,
                                               BOOL installOptiFine,
                                               NSString * _Nullable loaderVersion);

/// 取消回调
@property (nonatomic, copy) void (^cancelled)(void);

/// ★ Task323（下载中心「安装」tab 嵌入模式）：置 YES 时本页作为
/// DownloadViewController「安装」tab 的子 VC 内嵌呈现——不装返回/安装
/// 导航按钮，改用页内头部条（游戏版本选择芯片 + 安装按钮）；cancelled
/// 回调不再携带导航语义（pop/dismiss 由嵌入方管理）。
@property (nonatomic, assign) BOOL ame323_embedded;

/// Task323：嵌入模式游戏版本候选（远端版本清单字典数组，与
/// DownloadViewController.versionList 同源同形）；空数组时芯片置灰。
@property (nonatomic, copy, nullable) NSArray *ame323_gameVersions;

/// Task323：嵌入模式切换目标游戏版本（重建兼容性行 + 自动版本名）。
- (void)ame323_applyGameVersion:(NSString *)vid;

@end

NS_ASSUME_NONNULL_END
