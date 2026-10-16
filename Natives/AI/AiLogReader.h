//
//  AiLogReader.h
//  Prisma
//
//  Prisma AI Agent 日志读取工具（只读）：
//    - read_latest_log：读取当前选中实例的 logs/latest.log（截断末尾 4000 字符）。
//    - read_crash_report：读取最新的崩溃报告 .txt（截断 6000 字符）。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiLogReader : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

/// 指定工具名（read_latest_log / read_crash_report）
- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END