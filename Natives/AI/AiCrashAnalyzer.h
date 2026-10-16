//
//  AiCrashAnalyzer.h
//  Prisma
//
//  Prisma AI Agent 崩溃分析工具（只读）：match_known_errors。
//  对传入的日志/崩溃报告做内置规则关键词匹配，返回结构化分析结果。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiCrashAnalyzer : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

@end

NS_ASSUME_NONNULL_END