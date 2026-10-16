//
//  AiDownloadProbe.m
//  Prisma
//

#import "AiDownloadProbe.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "../utils.h"   // Task271-e：状态/结果文案 i18n 接线需要 localize()

@interface AiDownloadProbe ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiDownloadProbe

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = [name copy] ?: @"";
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"查询下载中心全部下载任务的实时状态（配合 install_* 工具的 wait=false 后台下载使用）。"
           "\n无参数。"
           "\n返回 JSON：{count, tasks:[{taskId, name, type, state, progress, downloadedBytes, totalBytes, speed, downloadSource}], summary:{各状态数量}}。"
           "\nstate 取值：等待中/下载中/已暂停/已完成/已取消/失败；progress 为 0~1（-1 表示未知）；speed 单位 bytes/s。"
           "\n边界：仅查询不操作，暂停/取消等请引导用户在下载中心手动操作。";
}

+ (NSString *)stateName:(DownloadTaskState)state {
    switch (state) {
        case DownloadTaskStatePending:     return localize(@"taskProgress.state.pending", nil);
        case DownloadTaskStateDownloading: return localize(@"taskProgress.state.downloading", nil);
        case DownloadTaskStatePaused:      return localize(@"taskProgress.state.paused", nil);
        case DownloadTaskStateCompleted:   return localize(@"taskProgress.state.completed", nil);
        case DownloadTaskStateCancelled:   return localize(@"taskProgress.state.cancelled", nil);
        case DownloadTaskStateFailed:      return localize(@"taskProgress.state.failed", nil);
    }
    return localize(@"ame189.common.unknown", nil);
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSArray<DownloadTaskItem *> *tasks = [[DownloadTaskManager sharedManager] allTasks];

    if (tasks.count == 0) {
        completion(localize(@"ai.downloadprobe.no_tasks", nil), nil);
        return;
    }

    NSMutableArray *items = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *summary = [NSMutableDictionary dictionary];
    for (DownloadTaskItem *task in tasks) {
        NSString *state = [AiDownloadProbe stateName:task.state];
        summary[state] = @((summary[state] ? [summary[state] integerValue] : 0) + 1);
        NSString *name = task.displayName.length > 0 ? task.displayName : (task.resourceName ?: @"");
        [items addObject:@{
            @"taskId": task.taskId ?: @"",
            @"name": name ?: @"",
            @"type": task.resourceType ?: @"",
            @"state": state,
            @"progress": @(task.progress),
            @"downloadedBytes": @(task.downloadedSize),
            @"totalBytes": @(task.totalSize),
            @"speed": @(task.speed),
            @"downloadSource": task.downloadSource ?: @"",
        }];
    }

    NSDictionary *result = @{
        @"count": @(items.count),
        @"tasks": items,
        @"summary": summary,
    };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:&jsonError];
    if (!data || jsonError) {
        completion([NSString stringWithFormat:localize(@"ai.downloadprobe.serialize_failed_fmt", nil),
                    (unsigned long)items.count, jsonError.localizedDescription ?: localize(@"resman.common.unknown_error", nil)], nil);
        return;
    }
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    completion(json ?: localize(@"ai.downloadprobe.serialize_failed", nil), nil);
}

@end
