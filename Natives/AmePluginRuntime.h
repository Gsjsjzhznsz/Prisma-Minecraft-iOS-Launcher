//
//  AmePluginRuntime.h
//  Amethyst
//
//  Task318：插件运行时 —— JSContext 生命周期 + 启动器事件分发。
//
//  事件面（桥接白名单同名）：launcherBoot / gameLaunch / gameExit /
//  jarLaunch。插桩点：
//    · bootAll —— SceneDelegate willConnect（PrismaTheme install 之后）；
//    · gameLaunch/gameExit —— SurfaceViewController 主游戏启动链
//      （launchJVM 前后两支）；
//    · jarLaunch —— JavaGUIViewController 的 jar 直启链。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AmePluginRuntime : NSObject

/// 启动全部已启用插件（重入安全：先全停再全起）+ 分发 launcherBoot 事件。
+ (void)bootAll;

/// 全停（退出启动器/全量重载用）。
+ (void)stopAll;

/// 重启单个插件（详情页启停开关直通）。
+ (void)restartPlugin:(NSString *)pluginId;

/// 停止单个插件（详情页开关关闭/卸载链；幂等，未运行 = no-op）。
+ (void)stopPlugin:(NSString *)pluginId;

/// 单插件运行态。
+ (BOOL)isRunning:(NSString *)pluginId;

/// 单插件最近一次 JS 异常（详情页错误信息行；nil = 无）。
+ (nullable NSString *)lastErrorForPlugin:(NSString *)pluginId;

#pragma mark - 事件分发（启动管线插桩调用）

/// 主游戏启动（SurfaceViewController launchJVM 调用前；versionId 可空）。
+ (void)dispatchGameLaunchWithVersion:(nullable NSString *)versionId;

/// 主游戏退出（SurfaceViewController launchJVM 返回后两支；code=0 正常）。
+ (void)dispatchGameExitWithVersion:(nullable NSString *)versionId code:(int)code;

/// jar/安装器 GUI 直启（JavaGUIViewController）。
+ (void)dispatchJarLaunchWithPath:(nullable NSString *)path;

@end

NS_ASSUME_NONNULL_END
