//
//  AiToolBootstrapper.h
//  Prisma
//
//  Prisma AI Agent 内置工具装配器：集中把 3a 阶段实现的内置工具注册进 AiToolRegistry。
//  3b 阶段的工具将在此文件追加注册（见 registerBuiltinTools 内的「3b 在此追加」注释）。
//

#import <Foundation/Foundation.h>
#import "AiToolRegistry.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiToolBootstrapper : NSObject

/// 把全部内置工具注册进指定 registry（AiToolRegistry 初始化时自动调用，也可外部显式调用）
+ (void)registerBuiltinToolsIntoRegistry:(AiToolRegistry *)registry;

@end

NS_ASSUME_NONNULL_END