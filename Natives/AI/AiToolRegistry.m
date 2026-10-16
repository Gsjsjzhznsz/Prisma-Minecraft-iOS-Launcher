//
//  AiToolRegistry.m
//  Prisma
//

#import "AiToolRegistry.h"
#import "AiToolBootstrapper.h"

@interface AiToolRegistry ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<AiTool>> *tools;
@end

@implementation AiToolRegistry

+ (instancetype)sharedRegistry {
    static AiToolRegistry *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiToolRegistry alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _tools = [NSMutableDictionary dictionary];
        // 关键修复（AI 不知道自己能用工具）：此前 [AiToolBootstrapper registerBuiltinTools]
        // 从未被任何地方调用，工具列表始终为空，openAIToolSchemas 返回空数组，
        // 模型收不到任何工具定义，表现为 AI 完全不知道能调用工具。这里在单例 init 时自动注册。
        [AiToolBootstrapper registerBuiltinToolsIntoRegistry:self];
    }
    return self;
}

- (void)registerTool:(id<AiTool>)tool {
    if (!tool || tool.name.length == 0) return;
    self.tools[tool.name] = tool;
}

- (id<AiTool> _Nullable)toolForName:(NSString *)name {
    if (name.length == 0) return nil;
    return self.tools[name];
}

/// OpenAI 风格 schema：description 直接用 summary；parameters 用宽松 object 描述，
/// 让模型可自由传参（宁可宽松，参数说明已写入 summary）。
- (NSArray<NSDictionary *> *)openAIToolSchemas {
    NSMutableArray<NSDictionary *> *schemas = [NSMutableArray array];
    NSArray<NSString *> *sortedNames = [self.tools.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sortedNames) {
        id<AiTool> tool = self.tools[name];
        [schemas addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": tool.name,
                @"description": tool.summary ?: @"",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{},
                    @"required": @[],
                },
            },
        }];
    }
    return schemas;
}

#pragma mark - 参数规范化

/// 把一个键规范化成小写 camelCase（例如 "game-version"→"gameVersion"、"InstanceName"→"instanceName"）。
- (NSString *)normalizedKeyCamel:(NSString *)key {
    if (key.length == 0) return key;

    NSUInteger length = key.length;
    // 记录每个"词"的起始下标（词与词之间由分隔符或大小写驼峰边界隔开）
    NSMutableIndexSet *wordStarts = [NSMutableIndexSet indexSet];
    [wordStarts addIndex:0];
    for (NSUInteger i = 1; i < length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c == '_' || c == '-' || c == '.' || c == ' ' || c == '/') {
            continue; // 分隔符本身不成为词头
        }
        unichar prev = [key characterAtIndex:i - 1];
        BOOL prevIsSep = (prev == '_' || prev == '-' || prev == '.' || prev == ' ' || prev == '/');
        BOOL prevIsLower = (prev >= 'a' && prev <= 'z') || (prev >= '0' && prev <= '9');
        BOOL isUpper = (c >= 'A' && c <= 'Z');
        if (prevIsSep) {
            [wordStarts addIndex:i];
        } else if (isUpper && prevIsLower) {
            // 驼峰边界：小写/数字后紧跟大写（兼顾 PascalCase 与 camelCase）
            [wordStarts addIndex:i];
        }
    }

    NSMutableString *result = [NSMutableString string];
    NSMutableString *currentWord = [NSMutableString string];
    __block BOOL isFirstWord = YES;

    void (^flush)(void) = ^{
        if (currentWord.length == 0) return;
        if (isFirstWord) {
            // 首词整体保持小写
            [result appendString:currentWord];
            isFirstWord = NO;
        } else {
            // 后续词首字母大写、其余小写
            NSString *word = currentWord;
            NSString *capitalized = [word stringByReplacingCharactersInRange:NSMakeRange(0, 1)
                                                                  withString:[[word substringToIndex:1] uppercaseString]];
            [result appendString:capitalized];
        }
        [currentWord setString:@""];
    };

    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [key characterAtIndex:i];
        if (c == '_' || c == '-' || c == '.' || c == ' ' || c == '/') {
            flush();
            continue;
        }
        if (i > 0 && [wordStarts containsIndex:i]) {
            flush();
        }
        // 统一转小写
        unichar lower = (c >= 'A' && c <= 'Z') ? (unichar)(c - 'A' + 'a') : c;
        [currentWord appendString:[NSString stringWithFormat:@"%C", lower]];
    }
    flush();
    return result;
}

/// 判断 value 是否"为空"（丢弃的键包括 nil、NSNull、空字符串）
- (BOOL)isEmptyValue:(id)value {
    if (value == nil || [value isKindOfClass:[NSNull class]]) return YES;
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value length] == 0;
    }
    return NO;
}

- (NSDictionary * _Nonnull)normalizedParams:(NSDictionary * _Nonnull)params {
    if (![params isKindOfClass:[NSDictionary class]]) return @{};
    NSMutableDictionary *normalized = [NSMutableDictionary dictionary];
    [params enumerateKeysAndObjectsUsingBlock:^(id rawKey, id value, BOOL *stop) {
        NSString *key = [rawKey isKindOfClass:[NSString class]] ? (NSString *)rawKey : [rawKey description];
        NSString *camelKey = [self normalizedKeyCamel:key];
        if (camelKey.length == 0) return;
        if ([self isEmptyValue:value]) return; // 丢弃 value 为空 的键
        normalized[camelKey] = value;
    }];
    return normalized;
}

#pragma mark - 执行

- (void)executeToolNamed:(NSString *)name
                  params:(NSDictionary *)params
              completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    id<AiTool> tool = [self toolForName:name];
    if (!tool) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *err = [NSError errorWithDomain:@"AiTool" code:404
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"未知工具 %@", name ?: @""]}];
                completion(nil, err);
            });
        }
        return;
    }

    // 先规范化参数再透传给工具 execute
    NSDictionary *normalized = [self normalizedParams:params];
    // ★ Task275（E-P2-8）：工具执行改后台队列——grep_files/list_files/read_file 的
    //   同步 NSFileManager 遍历/全量读此前全在主线程（AiAgent 工具阶段主队列），
    //   几十 MB 模组目录递归可冻结 UI 数秒。completion 本就回主线程，语义不变。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [tool execute:normalized completion:^(NSString * _Nullable result, NSError * _Nullable error) {
            // 统一把结果回调到主线程
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(result, error);
                }
            });
        }];
    });
}

@end