//
//  AmePluginManager.h
//  Amethyst
//
//  Task318：插件管理器 —— 清单模型 / 发现 / 安装 / 卸载 / 启停状态 / 内置仓库。
//
//  插件包形态：.zip（UnzipKit 解包），根（或唯一顶层目录）内含
//    manifest.json + main.js（entry 可自定义）。
//  安装落位：$POJAV_HOME/plugins/<id>/。
//  内置仓库：bundle Resources/BuiltinPlugins/*.zip（Makefile payload 整目录
//  拷贝随包，见 Makefile `cp -R Natives/resources/*` 行）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 解析并校验后的插件清单（必填 id/name/version/main；permissions 全部
/// 必须命中权限中心目录，未知权限 = 拒装）。
@interface AmePluginManifest : NSObject
@property(nonatomic, copy, readonly) NSString *pluginId;
@property(nonatomic, copy, readonly) NSString *name;
@property(nonatomic, copy, readonly) NSString *version;
@property(nonatomic, copy, readonly) NSString *author;
@property(nonatomic, copy, readonly) NSString *pluginDescription;
@property(nonatomic, copy, readonly) NSString *entry;               ///< 默认 main.js
@property(nonatomic, copy, readonly) NSArray<NSString *> *permissions;
@end

@interface AmePluginManager : NSObject

+ (instancetype)shared;

/// 已安装插件清单（每次调用重扫盘；目录名 = 插件 id）。
- (NSArray<AmePluginManifest *> *)installedPlugins;

/// 插件根目录（$POJAV_HOME/plugins）。
- (NSString *)pluginsRoot;

/// 单插件落位目录。
- (NSString *)pluginDirForId:(NSString *)pluginId;

/// 指定插件是否已安装。
- (BOOL)isInstalled:(NSString *)pluginId;

/// 直接读取某插件目录的清单（目录损坏返回 nil）。
- (nullable AmePluginManifest *)manifestForPlugin:(NSString *)pluginId;

#pragma mark - 启停状态（plugin.enabled_map）

/// 是否启用（未记录 = 默认 NO，装完在详情页显式打开；防静默执行）。
- (BOOL)isEnabled:(NSString *)pluginId;

- (void)setEnabled:(BOOL)enabled pluginId:(NSString *)pluginId;

#pragma mark - 安装 / 卸载

/// 从 .zip 安装（覆盖重装同 id）。同步执行（内置仓库包 ≤ 几十 KB）。
/// 校验失败/超限返回描述性 NSError，成功返回 nil。
- (nullable NSError *)installFromZip:(NSString *)zipPath;

/// 卸载：删目录 + 清启停位 + 清授权账本。运行中的插件由调用方先停。
- (void)uninstallPlugin:(NSString *)pluginId;

#pragma mark - 内置仓库

/// bundle 内 BuiltinPlugins/*.zip 的全路径列表（按文件名排序）。
- (NSArray<NSString *> *)builtinPackPaths;

/// 只读窥视 zip 内清单（不解包落盘；供仓库页展示权限要求）。
- (nullable AmePluginManifest *)peekManifestOfZip:(NSString *)zipPath
                                            error:(NSError **)error;

/// 清单解析（UI 层展示/校验共用）。
+ (nullable AmePluginManifest *)parseManifestDictionary:(NSDictionary *)dict
                                                  error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
