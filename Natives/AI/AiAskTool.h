//
//  AiAskTool.h
//  Prisma
//
//  Prisma AI Agent 交互问答工具（只读）：ask。
//  当 AI 需要用户做决策（版本/加载器/目标实例/资源挑选等）时，向用户发起多步选择向导。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiAskTool : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

@end

NS_ASSUME_NONNULL_END