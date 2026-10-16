//
//  AiSleepTool.m
//  Prisma
//

#import "AiSleepTool.h"

/// 单次最长等待（防模型传入超大值卡死会话）
static const double kAiSleepMaxSeconds = 120.0;

@implementation AiSleepTool

- (NSString *)name {
    return @"sleep";
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"等待指定秒数后返回（用于等待后台下载推进或模拟任务间隔）。"
           "\n参数：seconds（number，可选，默认 1，上限 120）。"
           "\n返回「已等待 N 秒」。";
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    double seconds = 1.0;
    id v = params[@"seconds"];
    if ([v isKindOfClass:[NSNumber class]]) {
        seconds = [(NSNumber *)v doubleValue];
    } else if ([v isKindOfClass:[NSString class]]) {
        seconds = [(NSString *)v doubleValue];
    }
    if (seconds < 0) seconds = 0;
    if (seconds > kAiSleepMaxSeconds) seconds = kAiSleepMaxSeconds;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        completion([NSString stringWithFormat:@"已等待 %.1f 秒", seconds], nil);
    });
}

@end
