//
//  AmePluginPermissions.h
//  Amethyst
//
//  Task318：插件权限中心 —— 权限目录 / 危险等级 / 授权状态持久化。
//
//  设计定案（与用户对齐的插件系统大架构）：
//    · 所有权限检查集中在桥接器（AmePluginBridge）边界执行——JS 侧拿到的
//      facade 每个方法入口先查授权，未授权 = 静默拒绝 + NSLog 留痕；
//    · 授权状态持久化进 PLPreferences（plugin.perm_map，键注册见
//      PLPreferences defaultPrefForGlobal 的 Task318 块）；
//    · 危险权限（renderer.write / profile.write）在详情页以红色高危行
//      呈现，用户可随时实时开/关（开关立即生效：授权即放行，撤销即拒绝）。
//

#import <Foundation/Foundation.h>

@class AmePluginManifest;

NS_ASSUME_NONNULL_BEGIN

/// 权限危险等级（详情页展示分层）。
typedef NS_ENUM(NSInteger, AmePluginDanger) {
    AmePluginDangerSafe     = 0,  ///< 低危（信息读取/事件/提示）
    AmePluginDangerModerate = 1,  ///< 中危（主题覆盖/插件私有目录）
    AmePluginDangerHigh     = 2,  ///< 高危（渲染器/实例配置写路径，红色标注）
};

#pragma mark - 权限 ID 常量（目录见 AmePluginPermissions.m 的白名单表）

extern NSString * const AmePluginPermEvents;         ///< 订阅启动器事件
extern NSString * const AmePluginPermNotify;         ///< 弹出 toast 提示
extern NSString * const AmePluginPermProfileRead;    ///< 读取实例配置
extern NSString * const AmePluginPermProfileWrite;   ///< 修改实例配置（高危）
extern NSString * const AmePluginPermRendererRead;   ///< 读取渲染器设置
extern NSString * const AmePluginPermRendererWrite;  ///< 修改渲染器（高危）
extern NSString * const AmePluginPermThemeWrite;     ///< 覆盖界面主题令牌
extern NSString * const AmePluginPermFilesPlugin;    ///< 插件私有目录读写
extern NSString * const AmePluginPermUI;             ///< 贡献启动器行/弹窗（Task329，低危）
extern NSString * const AmePluginPermNetwork;        ///< 联网取数（Task329，高危）

@interface AmePluginPermissions : NSObject

/// 全部合法权限 ID（清单校验用；未知权限 = 拒装）。
+ (NSArray<NSString *> *)allPermissionIds;

/// 权限危险等级（未知权限回落 Safe）。
+ (AmePluginDanger)dangerForPermission:(NSString *)permissionId;

/// 本地化标题（ame318.perm.<id>，i18n 54 表）。
+ (NSString *)localizedTitleForPermission:(NSString *)permissionId;

/// 本地化说明（ame318.perm.<id>.detail）。
+ (NSString *)localizedDetailForPermission:(NSString *)permissionId;

#pragma mark - 授权状态（持久化 plugin.perm_map）

/// 是否已授权（未记录 = NO；插件卸载即清账）。
+ (BOOL)isGranted:(NSString *)permissionId forPlugin:(NSString *)pluginId;

/// 实时开/关授权（详情页开关直通；立即生效，无需重启插件）。
+ (void)setGranted:(BOOL)granted
        permission:(NSString *)permissionId
         forPlugin:(NSString *)pluginId;

/// 某插件的全部授权快照（pluginId → {permId: BOOL}）。
+ (NSDictionary<NSString *, NSNumber *> *)grantsForPlugin:(NSString *)pluginId;

/// 清除某插件的全部授权（卸载时调用）。
+ (void)clearGrantsForPlugin:(NSString *)pluginId;

/// ★ Task329：Safe 级 + 插件私有目录装机即授（开箱即用根修——此前全部
///   权限默认拒绝，插件装完即聋 = "无法使用"主诉的结构性根源之一）。
///   只补缺账，绝不覆盖显式撤销记录；中危（theme.write）与高危
///   （network/renderer.write/profile.write）维持默认拒绝，详情页授权。
+ (void)seedSafeDefaultGrantsForManifest:(AmePluginManifest *)manifest;

@end

NS_ASSUME_NONNULL_END
