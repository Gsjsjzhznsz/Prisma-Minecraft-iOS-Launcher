#import <UIKit/UIKit.h>

// MARK: - Tile Type & Size Enums

typedef NS_ENUM(NSInteger, HomeTileType) {
    HomeTileTypeProfile = 0,
    HomeTileTypeAnnouncement,
    HomeTileTypeVersionRelease,
    HomeTileTypeVersionSnapshot,
    HomeTileTypeNews,
    HomeTileTypeShortcut,
};

typedef NS_ENUM(NSInteger, HomeTileSize) {
    HomeTileSizeCompact = 0,  // Half width (two per row)
    HomeTileSizeFull,         // Full width
};

// MARK: - HomeTileConfig

@interface HomeTileConfig : NSObject <NSSecureCoding>

@property (nonatomic, copy) NSString *tileId;
@property (nonatomic, assign) HomeTileType tileType;
@property (nonatomic, assign) HomeTileSize tileSize;
@property (nonatomic, assign) BOOL visible;
@property (nonatomic, copy) NSString *customTitle;
@property (nonatomic, copy) NSString *iconName;
@property (nonatomic, copy) NSString *accentColorHex;
@property (nonatomic, copy) NSString *shortcutAction;  // For HomeTileTypeShortcut

+ (NSArray<HomeTileConfig *> *)defaultTileConfigs;
+ (NSArray<HomeTileConfig *> *)loadSavedConfigs;
+ (void)saveConfigs:(NSArray<HomeTileConfig *> *)configs;
- (UIColor *)accentColor;
- (NSDictionary *)toDictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;

@end

// MARK: - Shortcut Action Constants

extern NSString * const kShortcutActionMods;
extern NSString * const kShortcutActionShaders;
extern NSString * const kShortcutActionModpack;
extern NSString * const kShortcutActionBackground;
extern NSString * const kShortcutActionVersions;
// Task235（用户：“参考上游把联机功能添加到自定义主页那里”）：
// 主页“联机”快捷磁贴（陶瓦联机 Terracotta，页内右上角可切 ZeroTier）。
extern NSString * const kShortcutActionMultiplayer;
// ★ Task256（清单 3：清理垃圾入口太不明显）：主页“清理垃圾”快捷磁贴——
// 清理中心从版本管理页二级 FAB→ActionSheet 三级路径提升为主页一级入口。
extern NSString * const kShortcutActionCleanup;
// ★ Task259（清单 6：版本安装界面关闭之后没有地方再打开）：主页“下载中心”
// 快捷磁贴——统一下载进度页最小化/关闭后的重新打开入口（任务列表 FormSheet）。
extern NSString * const kShortcutActionDownloadCenter;
// ★ Task318：AI 助手主页磁贴（用户："原来的ai功能怎么不见了"）。
extern NSString * const kShortcutActionAI;

// MARK: - LauncherNewsViewController

@interface LauncherNewsViewController : UIViewController

@end
