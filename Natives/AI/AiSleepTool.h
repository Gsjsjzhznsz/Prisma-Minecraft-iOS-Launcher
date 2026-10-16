//
//  AiSleepTool.h
//  Prisma
//
//  sleep 工具（enhance-ai-agent Task 12.1）：seconds（默认 1）异步等待后返回，
//  供 AI 等待后台下载/任务间隔使用。READ_ONLY 无副作用。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiSleepTool : NSObject <AiTool>
@end

NS_ASSUME_NONNULL_END
