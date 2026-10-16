//
//  AiInstancesTool.h
//  Prisma
//
//  Prisma AI Agent 实例/版本工具：
//    - list_instances（只读）：列出启动器的游戏实例（游戏目录/版本）及其资源数量。
//    - list_game_versions（只读）：拉取真实 MC 版本列表（含 30 分钟缓存）。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiInstancesTool : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

/// 指定该实例化对象对应的工具名（list_instances / list_game_versions）
- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END