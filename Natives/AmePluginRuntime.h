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
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

/// Task329：插件贡献行值对象（插件页"插件贡献的启动器行"分区数据源）。
/// title/detail 为宿主持有的纯字符串（插件经 prisma.updateRow 自行刷新，
/// 宿主不跨线程调 JS 求值——JSContext 非线程安全，全部求值走插件串行队列）；
/// onTap 仅为 JSValue 引用，宿主在串行队列上回调。
@interface AmePluginRow : NSObject
@property(nonatomic, copy, readonly) NSString *pluginId;
@property(nonatomic, copy, readonly) NSString *rowId;
@property(nonatomic, copy, readonly) NSString *title;
@property(nonatomic, copy, readonly) NSString *detail;
/// 唯一排序键（注册序，跨插件单调递增）。
@property(nonatomic, assign, readonly) NSUInteger order;
@end

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

#pragma mark - Task329：贡献行注册表 + 串行队列出口

/// 插件串行队列公开出口（桥接层异步回调必须回同队列——JSContext 非线程
/// 安全的硬约束；httpGet 完成回调 / onTap 回调都经此入队）。
+ (void)enqueueBlock:(void (^)(void))block;

/// 全部存活贡献行快照（注册序；线程安全，主线程读）。
+ (NSArray<AmePluginRow *> *)allRows;

/// 行面变更通知名（插件页监听 reload；main 队列派发）。
+ (NSString *)rowsChangedNotification;

/// 注册/替换贡献行（桥接层入口；内部串行队列上落账）。
+ (void)registerRowForPlugin:(NSString *)pluginId spec:(NSDictionary *)spec;

/// 刷新贡献行文案（桥接层入口；幂等，行不存在 = no-op）。
+ (void)updateRowForPlugin:(NSString *)pluginId rowId:(NSString *)rowId patch:(NSDictionary *)patch;

/// 行点击分发（插件页主线程调用；onTap 在串行队列上回放，异常不连坐）。
+ (void)dispatchRowTapForPlugin:(NSString *)pluginId rowId:(NSString *)rowId;

@end

NS_ASSUME_NONNULL_END
