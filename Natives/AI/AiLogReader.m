//
//  AiLogReader.m
//  Prisma
//

#import "AiLogReader.h"
#import "LauncherPreferences.h"
#import "../utils.h"   // Task271-e：结果/错误文案 i18n 接线需要 localize()

@interface AiLogReader ()
@property (nonatomic, copy) NSString *internalName;
@end

@implementation AiLogReader

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
    if ([self.internalName isEqualToString:@"read_crash_report"]) {
        return @"读取最新一份崩溃报告（crash-report 目录中修改时间最新的 .txt 文件）。"
               "\n参数：instance（string，可选，实例/游戏目录名，缺省当前选中实例）。"
               "\n说明：优先读取 logs/crash-reports/ 目录，其次回退到 crash-reports/ 目录，返回最新 .txt 的内容，截断为末尾 6000 字符。"
               "\n边界：目录或文件不存在时返回「未找到崩溃报告」。";
    }
    if ([self.internalName isEqualToString:@"read_logs"]) {
        return @"一次并行读取多份日志（排查问题首选工具）。"
               "\n参数：logs（array，可选，元素：latest.log=游戏日志 / latestlog.txt=启动器日志 / latestlog.old.txt=上次启动器日志 / crash-report=最新崩溃报告）、"
               "all（boolean，可选，true 时读取全部上述日志）、instance（string，可选，实例名，缺省当前选中实例）。"
               "\n重要：启动器日志 latestlog.txt 通常已包含游戏日志（stdout/stderr 重定向），排查时优先读取它。"
               "\n返回 JSON 数组：{key, path, size, lastModified, content（各自截断末尾 4000 字符）}；不存在的文件标注缺失。";
    }
    // read_latest_log
    return @"读取实例的最近启动日志（logs/latest.log）。"
           "\n参数：instance（string，可选，实例/游戏目录名，缺省当前选中实例）。"
           "\n说明：返回日志末尾 4000 字符（过长时起始部分被截断并注明）。文件不存在时返回「未找到日志」。"
           "\n提示：启动器级日志（POJAV_HOME/latestlog.txt，含游戏日志）请改用 read_logs。"
           "\n边界：仅读取 .log 文件，绝不读取其它类型文件。";
}

#pragma mark - 路径

/// 启动器主目录（POJAV_HOME，回退 Documents）
+ (NSString *)launcherHome {
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) return @(home);
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

/// 当前实例根目录（POJAV_GAME_DIR 或其回退）
+ (NSString *)currentGameRoot {
    const char *root = getenv("POJAV_GAME_DIR");
    if (root && strlen(root) > 0) return @(root);
    const char *home = getenv("POJAV_HOME");
    if (home && strlen(home) > 0) {
        NSString *name = getPrefObject(@"general.game_directory");
        if (name.length == 0) name = @"default";
        return [NSString stringWithFormat:@"%s/instances/%@", home, name];
    }
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
}

/// 解析 instance 参数 → 实例根目录（<POJAV_HOME>/instances/<instance>，缺省当前实例）
+ (NSString *)gameRootForParams:(NSDictionary *)params {
    NSString *instance = [params[@"instance"] isKindOfClass:[NSString class]] ? params[@"instance"] : @"";
    if (instance.length == 0) return [self currentGameRoot];
    // 目录名安全化，防止 ../ 逃逸
    NSArray *parts = [instance componentsSeparatedByCharactersInSet:
                      [NSCharacterSet characterSetWithCharactersInString:@"/\\:"]];
    NSString *safe = [parts componentsJoinedByString:@"_"];
    NSString *root = [NSString stringWithFormat:@"%@/instances/%@", [self launcherHome], safe];
    BOOL isDir = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] && isDir) {
        return root;
    }
    // 回退：视为当前实例（不存在的目录返回原拼接路径，由读取侧报缺失）
    return root;
}

/// 截断内容：保留末尾 N 字符，若被截断则在开头注明
- (NSString *)truncatedContent:(NSString *)content maxChars:(NSUInteger)max header:(NSString *)header {
    if (content.length <= max) return content;
    NSString *tail = [content substringFromIndex:(content.length - max)];
    return [header stringByAppendingString:tail];
}

/// 读文件（UTF-8 → Latin1 回退）
+ (NSString *)contentAtPath:(NSString *)path {
    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!content) content = [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:nil];
    return content;
}

/// 布尔参数解析（兼容 JSON true/false、NSNumber、字符串 "true"/"false"）
+ (BOOL)boolFromValue:(id)value {
    if (!value || [value isKindOfClass:[NSNull class]]) return NO;
    if ([value isKindOfClass:[NSString class]]) {
        NSString *s = [(NSString *)value lowercaseString];
        return [s hasPrefix:@"t"] || [s isEqualToString:@"1"] || [s isEqualToString:@"yes"];
    }
    return [value boolValue];
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *gameRoot = [[self class] gameRootForParams:params];

    if ([self.internalName isEqualToString:@"read_crash_report"]) {
        NSString *content = [self latestCrashReportInGameRoot:gameRoot];
        completion(content ?: localize(@"ai.logreader.crash_not_found", nil), nil);
        return;
    }
    if ([self.internalName isEqualToString:@"read_logs"]) {
        [self performReadLogs:params gameRoot:gameRoot completion:completion];
        return;
    }
    if ([self.internalName isEqualToString:@"read_latest_log"]) {
        NSString *logPath = [gameRoot stringByAppendingPathComponent:@"logs/latest.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:logPath isDirectory:&isDir] || isDir) {
            completion(localize(@"ai.logreader.log_not_found", nil), nil);
            return;
        }
        NSString *content = [AiLogReader contentAtPath:logPath];
        if (!content) {
            completion(localize(@"ai.logreader.read_failed", nil), nil);
            return;
        }
        NSString *result = [self truncatedContent:content
                                          maxChars:4000
                                            header:localize(@"ai.logreader.truncated_latest_hdr", nil)];
        completion(result, nil);
        return;
    }

    NSError *err = [NSError errorWithDomain:@"AiTool" code:404
                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.tools.unknown_tool_fmt", nil), self.internalName]}];
    completion(nil, err);
}

#pragma mark - read_logs

- (void)performReadLogs:(NSDictionary *)params
               gameRoot:(NSString *)gameRoot
             completion:(void (^)(NSString *, NSError *))completion {
    // 收集要读的日志 key 列表
    NSMutableArray *keys = [NSMutableArray array];
    BOOL all = [AiLogReader boolFromValue:params[@"all"]];
    id logsParam = params[@"logs"];
    if (all) {
        [keys addObjectsFromArray:@[@"latestlog.txt", @"latestlog.old.txt", @"latest.log", @"crash-report"]];
    } else if ([logsParam isKindOfClass:[NSArray class]]) {
        for (id item in (NSArray *)logsParam) {
            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0) {
                [keys addObject:item];
            }
        }
    } else if ([logsParam isKindOfClass:[NSString class]] && [(NSString *)logsParam length] > 0) {
        [keys addObject:logsParam];
    }
    if (keys.count == 0) {
        keys = [@[ @"latestlog.txt", @"latest.log" ] mutableCopy]; // 缺省读启动器日志 + 游戏日志
    }
    // 去重（保持顺序）
    NSMutableArray *uniqueKeys = [NSMutableArray array];
    for (NSString *k in keys) {
        if (![uniqueKeys containsObject:k]) [uniqueKeys addObject:k];
    }

    // key → 物理路径解析（latestlog* 在 POJAV_HOME；其余在实例目录）
    NSString *home = [AiLogReader launcherHome];
    __block NSMutableArray *entries = [NSMutableArray array];
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t readQueue = dispatch_queue_create("ai.log.read", DISPATCH_QUEUE_CONCURRENT);

    for (NSString *key in uniqueKeys) {
        dispatch_group_enter(group);
        dispatch_async(readQueue, ^{
            NSString *path = nil;
            if ([key isEqualToString:@"latestlog.txt"]) {
                path = [home stringByAppendingPathComponent:@"latestlog.txt"];
            } else if ([key isEqualToString:@"latestlog.old.txt"]) {
                path = [home stringByAppendingPathComponent:@"latestlog.old.txt"];
            } else if ([key isEqualToString:@"latest.log"] || [key containsString:@"latest.log"]) {
                path = [gameRoot stringByAppendingPathComponent:@"logs/latest.log"];
            } else if ([key containsString:@"crash"]) {
                path = [self latestCrashReportPathInGameRoot:gameRoot];
            } else {
                path = key; // 直接传路径：仅允许实例目录内相对路径
                if (![path hasPrefix:@"/"]) path = [gameRoot stringByAppendingPathComponent:path];
            }

            if (path.length == 0) {
                @synchronized (entries) {
                    [entries addObject:@{@"key": key, @"missing": @YES}];
                }
                dispatch_group_leave(group);
                return;
            }

            NSFileManager *fm = [NSFileManager defaultManager];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
                @synchronized (entries) {
                    [entries addObject:@{@"key": key, @"missing": @YES, @"path": path}];
                }
                dispatch_group_leave(group);
                return;
            }

            NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
            NSString *content = [AiLogReader contentAtPath:path];
            NSString *truncated = content
                ? [self truncatedContent:content maxChars:4000
                                  header:localize(@"ai.logreader.truncated_hdr", nil)]
                : localize(@"ai.logreader.read_error", nil);
            NSDate *mtime = attrs[NSFileModificationDate];
            @synchronized (entries) {
                [entries addObject:@{
                    @"key": key,
                    @"path": path,
                    @"size": @([attrs[NSFileSize] integerValue]),
                    @"lastModified": mtime ? [mtime description] : @"",
                    @"content": truncated ?: @"",
                }];
            }
            dispatch_group_leave(group);
        });
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        // 按原始 key 顺序排序输出
        NSMutableArray *sorted = [NSMutableArray array];
        for (NSString *key in uniqueKeys) {
            for (NSDictionary *e in entries) {
                if ([e[@"key"] isEqualToString:key]) {
                    [sorted addObject:e];
                    break;
                }
            }
        }
        NSError *jsonError = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"logs": sorted}
                                                    options:NSJSONWritingPrettyPrinted
                                                      error:&jsonError];
        if (!data || jsonError) {
            completion([NSString stringWithFormat:localize(@"ai.logreader.multi_serialize_failed_fmt", nil), (unsigned long)sorted.count], nil);
            return;
        }
        completion([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], nil);
    });
}

/// 查找最新崩溃报告路径（优先 logs/crash-reports/，回退 crash-reports/）
- (NSString *)latestCrashReportPathInGameRoot:(NSString *)gameRoot {
    NSArray *candidates = @[
        [gameRoot stringByAppendingPathComponent:@"logs/crash-reports"],
        [gameRoot stringByAppendingPathComponent:@"crash-reports"],
    ];
    NSString *bestPath = nil;
    NSDate *bestDate = nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    for (NSString *dir in candidates) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) continue;
        NSArray *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString *file in files) {
            if (![file hasSuffix:@".txt"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:file];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            if (!attrs[NSFileType] || [NSFileTypeDirectory isEqualToString:attrs[NSFileType]]) continue;
            NSDate *mtime = attrs[NSFileModificationDate];
            if (!mtime) mtime = [NSDate distantPast];
            if (bestDate == nil || [mtime compare:bestDate] == NSOrderedDescending) {
                bestDate = mtime;
                bestPath = full;
            }
        }
    }
    return bestPath;
}

/// 查找最新崩溃报告内容（优先 logs/crash-reports/，回退 crash-reports/）
- (NSString *)latestCrashReportInGameRoot:(NSString *)gameRoot {
    NSString *bestPath = [self latestCrashReportPathInGameRoot:gameRoot];
    if (!bestPath) return nil;

    NSString *content = [AiLogReader contentAtPath:bestPath];
    if (!content) return nil;

    return [self truncatedContent:content maxChars:6000 header:localize(@"ai.logreader.truncated_crash_hdr", nil)];
}

@end
