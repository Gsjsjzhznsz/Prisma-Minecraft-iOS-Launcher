//
//  BackgroundManager.h
//  Amethyst
//
//  Background wallpaper manager - Global support for all view controllers
//

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BackgroundType) {
    BackgroundTypeNone = 0,
    BackgroundTypeImage,
    BackgroundTypeVideo
};

typedef NS_ENUM(NSInteger, BackgroundUIEffect) {
    BackgroundUIEffectTranslucent = 0,  // 半透明
    BackgroundUIEffectBlur              // 毛玻璃效果
};

@interface BackgroundManager : NSObject

+ (instancetype)sharedManager;

// Background type
@property (nonatomic, readonly) BackgroundType currentType;
@property (nonatomic, readonly, nullable) NSString *currentBackgroundPath;

// UI effect settings (for custom background)
@property (nonatomic, assign) BackgroundUIEffect uiEffect;
@property (nonatomic, assign) CGFloat uiOpacity;  // 0.0 ~ 1.0
@property (nonatomic, assign) CGFloat blurIntensity; // 0.0 ~ 1.0, 背景模糊程度

// Task210（用户定稿"删除所有新拟态代码和其选项和设置"）：新拟态界面开关
// 与卡片本体透明度偏好（cardsNeumorphEnabled / cardsNeumorphOpacity）
// 整链删除。卡面唯一管线 = 壁纸感知的单路径：有壁纸走毛玻璃/半透明
//（设置页其余 UI 效果选项），无壁纸走平贴灰面（AmeCardSurfaceColor）。

// Global background container
@property (nonatomic, strong, readonly, nullable) UIView *globalBackgroundContainer;

// Apply background globally
- (void)applyBackgroundToWindow:(UIWindow *)window;
- (void)applyBackgroundToSplitViewController:(UISplitViewController *)splitVC;
- (void)removeGlobalBackground;

// Legacy compatibility
- (void)applyBackgroundToView:(UIView *)view;
- (void)removeBackgroundFromView:(UIView *)view;

// Set background
- (void)setImageBackground:(UIImage *)image completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)setVideoBackgroundWithURL:(NSURL *)videoURL completion:(void (^)(BOOL success, NSError * _Nullable error))completion;
- (void)clearBackground;

// Task151：Bing 每日壁纸联动（来源标记机制）
// 当前背景是否由 Bing 壁纸链路设置（source == @"bing"）。
// 语义：用户手动设置的图片/视频来源为 user，优先于 Bing 自动应用；
// 无背景或来源为 bing 时，BingWallpaperManager 可每日自动换图。
@property (nonatomic, readonly) BOOL isBingSource;
// Task162：背景容器是否真实挂在活窗口上（自愈判定）。
// 状态层（currentBackgroundPath）与视图层（globalBackgroundContainer）
// 可能脱节——例如历史会话的首次应用只落了状态、容器插入失败/宿主引用
// 丢失，用户实测“Bing 壁纸加载完成还要重启才有图”。Bing 链路用它判断
// 是否需要重放应用，避免静默跳过。
- (BOOL)isBackgroundLiveAttached;
// 将已存在于磁盘的 Bing 壁纸图直接登记为当前背景（不再复制到 backgrounds/
// 目录，避免每日图双份存储；来源标记为 bing）。
- (void)setBingBackgroundImageAtPath:(NSString *)path completion:(void (^)(BOOL success, NSError * _Nullable error))completion;

// Check if has background
- (BOOL)hasBackground;
- (BOOL)hasImageBackground;
- (BOOL)hasVideoBackground;

// Get background preview
- (nullable UIImage *)backgroundPreview;

// ============================================================================
// Task223（清单第 14/21 项）：壁纸直取 + 亮度自适应（动态反色）。
// 病历：启动遮罩/欢迎向导此前的"透底"方案依赖全局背景容器在视图栈最底层
// ——根视图换到 SurfaceViewController / 向导全屏呈现后，不透明宿主视图把
// 容器盖住 = "依旧没有显示自定义壁纸"。新方案：需要透壁纸的界面【自带】
// 壁纸图层（currentWallpaperImage 直取磁盘缓存），与视图层级无关。
// 动态反色（第 21 项）：wallpaperLuminanceIsDark 对当前壁纸做降采样平均
// 亮度判定（阈值 0.45），亮壁纸上用深色文字、暗壁纸上用浅色文字，避免
// 壁纸影响可读性。背景变化时广播 Ame223WallpaperChanged 供已打开界面
// 重取颜色。
// ============================================================================
- (nullable UIImage *)ame223_currentWallpaperImage;
- (BOOL)ame223_wallpaperLuminanceIsDark;   // 无壁纸时按当前系统外观判定
- (UIColor *)ame223_adaptiveTextColor;      // 深壁纸→白字 / 亮壁纸→黑字
- (UIColor *)ame223_adaptiveSecondaryTextColor;

FOUNDATION_EXPORT NSNotificationName const Ame223WallpaperChangedNotification;

// ============================================================================
// Task224（反馈 #18）：通用动态反色文字——欢迎页之外的壁纸透出文字
// （主菜单磁贴、右面板标题等）统一取色入口。无壁纸时回落 Task210 卡面
// 规格色（与既有外观逐字节一致）；有壁纸时按亮度反色 + 软阴影兜底。
// 壁纸变化重算走 Ame223WallpaperChangedNotification（复用欢迎页链路）。
// ============================================================================
+ (UIColor *)ame224_adaptiveTextColor;
+ (UIColor *)ame224_adaptiveSecondaryTextColor;
/// 颜色 + 软阴影一次到位（无壁纸时清阴影，零新视觉）
+ (void)ame224_applyAdaptiveTextToLabel:(UILabel *)label secondary:(BOOL)secondary;
/// 富文本版（标题等需要整体属性的场景）
+ (NSAttributedString *)ame224_adaptiveAttributedTitle:(NSString *)title
                                              fontSize:(CGFloat)fontSize
                                             secondary:(BOOL)secondary;

// Pause/Resume video (for app lifecycle)
- (void)pauseVideo;
- (void)resumeVideo;

// Update background frame (call on rotation)
- (void)updateBackgroundFrame;

// Make view controllers transparent (for global background visibility)
- (void)makeViewControllerTransparent:(UIViewController *)viewController;
- (void)makeSplitViewControllerTransparent:(UISplitViewController *)splitVC;

// Task152：背景"从无到有"时（Bing 首次联网拉到图 / 用户首次设置图片或视频）
// 对当前窗口整棵 VC 树重新执行透明化管线——否则已加载的 VC 保持不透明底色，
// 新插入的背景容器被完全盖住，表现为"壁纸要重启软件后才显示"。
- (void)refreshTransparencyForWindowUI;

// Apply UI effect to any UIView (blur or translucent based on settings)
- (void)applyEffectToView:(UIView *)view;
- (void)applyEffectToCollectionViewCell:(UICollectionViewCell *)cell;
/// 表格 cell 卡面管线入口（Task190 泛型实现共用；Task210 起无开关感知，
/// 单路径：有壁纸 = 毛玻璃/半透明，无壁纸 = 平贴灰面），
/// 账号列表卡片（已安装版本页同构）由此获得与版本卡逐字节一致的行为。
- (void)applyEffectToTableViewCell:(UITableViewCell *)cell;
- (void)applyEffectToCell:(UITableViewCell *)cell;
/// Task136：表格 cell 的"卡片化"样式（下载页模组加载器等与上级菜单
/// 对齐的页面专用）——Task210 起与 applyEffectToCell: 同一单路径管线。
- (void)applyCardEffectToCell:(UITableViewCell *)cell;
/// Task163：独立卡片容器的卡面管线（下载版本卡等"该改的"）。
/// Task210 改名（原 applyNeumorphCardEffectToView:）：新拟态退役后
/// 恒为壁纸感知单路径（毛玻璃/半透明/平贴灰面），无开关无透明度。
- (void)applyCardEffectToView:(UIView *)view;
// 适配 UISearchBar：移除默认不透明背景，让 searchBar 透出底层自定义启动器背景
- (void)applyEffectToSearchBar:(UISearchBar *)searchBar;

// Apply UI effect to navigation bar and toolbar
- (void)applyEffectToNavigationBar:(UINavigationBar *)navigationBar;
- (void)applyEffectToToolbar:(UIToolbar *)toolbar;

// Apply UI effect settings to current split view controller
- (void)refreshUIEffect;

@end

NS_ASSUME_NONNULL_END