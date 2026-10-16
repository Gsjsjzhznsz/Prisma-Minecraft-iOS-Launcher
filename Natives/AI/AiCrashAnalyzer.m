//
//  AiCrashAnalyzer.m
//  Prisma
//

#import "AiCrashAnalyzer.h"
#import "../utils.h"   // Task271-e：分析结果文案 i18n 接线需要 localize()

@implementation AiCrashAnalyzer

- (NSString *)name {
    return @"match_known_errors";
}

- (AiToolPermission)permission {
    return AiToolPermissionReadOnly;
}

- (NSString *)summary {
    return @"分析日志或崩溃报告，识别已知错误类型并给出通俗的解释与修复建议。"
           "\n参数（二选一）："
           "\n  - log（string，可选）：启动日志全文（通常来自 read_latest_log）。"
           "\n  - crashReport（string，可选）：崩溃报告全文（通常来自 read_crash_report）。"
           "\n至少提供一个入参。返回 JSON：{matched, category, explanation, suggestions}。"
           "\ncategory 取值：内存不足 / JNI 初始化失败 / 图形初始化失败 / Java 版本不符 / 数值越界 / "
           "iOS-妙控键盘崩溃 / iOS-MC 26.2 OpenGL 语法错误 / iOS-MC 26.3 SDL 通路报错 / "
           "iOS-启动器自身闪退 / iOS-LWJGL 兼容问题 / iOS-启动黑屏/直接闪退（JIT） / 未知。"
           "\n边界：仅内置规则匹配，不承诺 100% 命中；未命中时给出通用排查建议。";
}

/// 单个匹配规则：catgeory + alternatives（每组 alt 的关键词需全部命中才算该 alt 匹配）
- (NSArray<NSDictionary *> *)ruleTable {
    return @[
        @{
            @"category": @"内存不足",
            @"alternatives": @[
                @[@"OutOfMemoryError"],
            ],
            @"explanation": localize(@"ai.crash.oom.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.oom.sugg1", nil),
                localize(@"ai.crash.oom.sugg2", nil),
                localize(@"ai.crash.oom.sugg3", nil),
            ],
        },
        @{
            @"category": @"JNI 初始化失败",
            @"alternatives": @[
                @[@"Failed to initialize JNI", @"META-INF"],
                @[@"java.lang.UnsatisfiedLinkError"],
            ],
            @"explanation": localize(@"ai.crash.jni.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.jni.sugg1", nil),
                localize(@"ai.crash.jni.sugg2", nil),
                localize(@"ai.crash.jni.sugg3", nil),
            ],
        },
        @{
            @"category": @"图形初始化失败",
            @"alternatives": @[
                @[@"OpenGL", @"GLFW error"],
                @[@"GLX"],
            ],
            @"explanation": localize(@"ai.crash.gl.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.gl.sugg1", nil),
                localize(@"ai.crash.gl.sugg2", nil),
                localize(@"ai.crash.gl.sugg3", nil),
            ],
        },
        @{
            @"category": @"Java 版本不符",
            @"alternatives": @[
                @[@"Unsupported Java version"],
                @[@"Java 8"],
            ],
            @"explanation": localize(@"ai.crash.javaver.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.javaver.sugg1", nil),
                localize(@"ai.crash.javaver.sugg2", nil),
            ],
        },
        @{
            @"category": @"数值越界",
            @"alternatives": @[
                @[@"Zombie"],
                @[@"invalid range"],
            ],
            @"explanation": localize(@"ai.crash.range.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.range.sugg1", nil),
                localize(@"ai.crash.range.sugg2", nil),
            ],
        },
        // ===== iOS 环境已知错误（enhance-ai-agent Task 17）=====
        @{
            @"category": @"iOS-妙控键盘崩溃",
            @"alternatives": @[
                @[@"Magic Keyboard", @"crash"],
                @[@"妙控键盘"],
            ],
            @"explanation": localize(@"ai.crash.magickeyboard.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.magickeyboard.sugg1", nil),
                localize(@"ai.crash.magickeyboard.sugg2", nil),
            ],
        },
        @{
            @"category": @"iOS-MC 26.2 OpenGL 语法错误",
            @"alternatives": @[
                @[@"26.2", @"OpenGL", @"syntax"],
                @[@"GL_INVALID_OPERATION", @"syntax error"],
            ],
            @"explanation": localize(@"ai.crash.gl262.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.gl262.sugg1", nil),
                localize(@"ai.crash.gl262.sugg2", nil),
            ],
        },
        @{
            @"category": @"iOS-MC 26.3 SDL 通路报错",
            @"alternatives": @[
                @[@"26.3-Snapshot4"],
                @[@"SDL3"],
            ],
            @"explanation": localize(@"ai.crash.sdl3.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.sdl3.sugg1", nil),
            ],
        },
        @{
            @"category": @"iOS-启动器自身闪退",
            @"alternatives": @[
                @[@"启动器", @"闪退"],
                @[@"launcher", @"SIGKILL"],
            ],
            @"explanation": localize(@"ai.crash.launchercrash.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.launchercrash.sugg1", nil),
                localize(@"ai.crash.launchercrash.sugg2", nil),
            ],
        },
        @{
            @"category": @"iOS-LWJGL 兼容问题",
            @"alternatives": @[
                @[@"LWJGL", @"UnsatisfiedLinkError"],
                @[@"LWJGL", @"no such function"],
                @[@"LWJGL", @"NoSuchMethodError"],
            ],
            @"explanation": localize(@"ai.crash.lwjgl.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.lwjgl.sugg1", nil),
                localize(@"ai.crash.lwjgl.sugg2", nil),
            ],
        },
        @{
            @"category": @"iOS-启动黑屏/直接闪退（JIT）",
            @"alternatives": @[
                @[@"JIT", @"SIGSEGV"],
                @[@"JIT", @"SIGTRAP"],
                @[@"ptrace", @"debugged"],
            ],
            @"explanation": localize(@"ai.crash.jit.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.jit.sugg1", nil),
                localize(@"ai.crash.jit.sugg2", nil),
            ],
        },
    ];
}

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    NSString *log = params[@"log"];
    NSString *crash = params[@"crashReport"];
    if (![log isKindOfClass:[NSString class]]) log = nil;
    if (![crash isKindOfClass:[NSString class]]) crash = nil;

    if (log.length == 0 && crash.length == 0) {
        NSError *err = [NSError errorWithDomain:@"AiTool" code:400
                                       userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.crash.missing_params", nil)}];
        completion(nil, err);
        return;
    }

    NSString *combined = [NSString stringWithFormat:@"%@\n%@", (log ?: @""), (crash ?: @"")];

    // 内置规则匹配
    NSDictionary *matchedResult = nil;
    for (NSDictionary *rule in [self ruleTable]) {
        BOOL ruleMatched = NO;
        for (NSArray *alternative in rule[@"alternatives"]) {
            BOOL allHit = YES;
            for (NSString *keyword in alternative) {
                if ([combined rangeOfString:keyword options:NSCaseInsensitiveSearch].location == NSNotFound) {
                    allHit = NO;
                    break;
                }
            }
            if (allHit) { ruleMatched = YES; break; }
        }
        if (ruleMatched) {
            matchedResult = @{
                @"matched": @YES,
                @"category": rule[@"category"],
                @"explanation": rule[@"explanation"],
                @"suggestions": rule[@"suggestions"],
            };
            break;
        }
    }

    if (!matchedResult) {
        matchedResult = @{
            @"matched": @NO,
            @"category": @"未知",
            @"explanation": localize(@"ai.crash.nomatch.explanation", nil),
            @"suggestions": @[
                localize(@"ai.crash.nomatch.sugg1", nil),
                localize(@"ai.crash.nomatch.sugg2", nil),
                localize(@"ai.crash.nomatch.sugg3", nil),
            ],
        };
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:matchedResult options:0 error:nil];
    NSString *resultJSON = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    completion(resultJSON, nil);
}

@end