//
//  AiAssetTools.h
//  Prisma
//
//  Prisma AI Agent 资源/网络工具（Phase 3b）：
//  - AiAssetSearchTool：Modrinth 搜索类（search_mods / search_resourcepacks / search_shaders /
//    search_datapacks / search_modpacks / search_worlds），权限 ExternalNetwork。
//  - AiAssetInstallTool：安装类（install_mod / install_resourcepack / install_shader /
//    install_datapack / install_game_version / install_loader），权限 ControlledWrite。
//  两类工具均在 AiAssetTools.m 内共用一套文件内私有 helper（NSURLSession 网络 / PLDownloadClient 下载）。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

/// Modrinth 搜索 / 安装资源工具（按 internalName 区分具体工具名）
@interface AiAssetSearchTool : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

/// 指定该实例化对象对应的工具名
- (instancetype)initWithName:(NSString *)name;

@end

/// 资源安装 / 加载器工具（按 internalName 区分具体工具名）
@interface AiAssetInstallTool : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

/// 指定该实例化对象对应的工具名
- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END