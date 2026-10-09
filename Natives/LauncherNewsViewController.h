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

// MARK: - LauncherNewsViewController

@interface LauncherNewsViewController : UIViewController

@end
