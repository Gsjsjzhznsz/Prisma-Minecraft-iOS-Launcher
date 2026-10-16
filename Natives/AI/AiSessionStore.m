//
//  AiSessionStore.m
//  Prisma
//

#import "AiSessionStore.h"

@implementation AiSessionStore {
    NSMutableArray<AiSession *> *_sessions;
    BOOL _loaded;
}

static NSString * const kLastSessionIdKey = @"ai.last_session_id";
/// 自动命名时最多取前 20 个字符
static const NSUInteger kAutoTitleMaxLength = 20;

+ (instancetype)sharedStore {
    static AiSessionStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AiSessionStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _sessions = [NSMutableArray array];
        _loaded = NO;
    }
    return self;
}

#pragma mark - 文件路径

- (NSString *)aiDirectoryPath {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = [paths firstObject];
    NSString *aiDir = [docDir stringByAppendingPathComponent:@"AI"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:aiDir]) {
        [fm createDirectoryAtPath:aiDir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return aiDir;
}

- (NSString *)filePath {
    return [[self aiDirectoryPath] stringByAppendingPathComponent:@"sessions.json"];
}

#pragma mark - 排序

/// 按 updatedAt 倒序（最新在前）
- (void)reloadSort {
    [_sessions sortUsingComparator:^NSComparisonResult(AiSession *a, AiSession *b) {
        return [b.updatedAt compare:a.updatedAt];
    }];
}

#pragma mark - 加载 / 保存

- (NSMutableArray<AiSession *> *)sessions {
    [self loadIfNeeded];
    // 返回内部可变引用，但外部调用方应避免直接乱序修改；如需修改请走 updateSession
    return _sessions;
}

- (void)loadIfNeeded {
    if (_loaded) return;
    _loaded = YES;

    NSString *path = [self filePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        NSError *error = nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (!error && [obj isKindOfClass:[NSArray class]]) {
            [_sessions removeAllObjects];
            for (NSDictionary *dict in obj) {
                AiSession *session = [[AiSession alloc] initWithDictionary:dict];
                if (session) [_sessions addObject:session];
            }
            [self reloadSort];
            return;
        }
    }
}

- (void)save {
    [self reloadSort];
    NSMutableArray *array = [NSMutableArray array];
    for (AiSession *session in _sessions) {
        if (session.messages.count == 0 && session.title == nil) continue;
        [array addObject:[session toDictionary]];
    }
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:array options:NSJSONWritingPrettyPrinted error:&error];
    if (json && !error) {
        [json writeToFile:[self filePath] options:NSDataWritingAtomic error:nil];
    }
}

#pragma mark - CRUD

- (AiSession *)newSession {
    [self loadIfNeeded];
    AiSession *session = [AiSession sessionWithTitle:nil];
    [_sessions insertObject:session atIndex:0];
    [self setLastActiveSessionId:session.identifier];
    [self save];
    return session;
}

- (void)deleteSession:(AiSession *)session {
    if (!session) return;
    [self loadIfNeeded];
    [_sessions removeObject:session];
    // 若删除的是最近会话，清空记录
    NSString *lastId = [[NSUserDefaults standardUserDefaults] stringForKey:kLastSessionIdKey];
    if ([session.identifier isEqualToString:lastId]) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kLastSessionIdKey];
    }
    [self save];
}

- (void)updateSession:(AiSession *)session {
    if (!session) return;
    [self loadIfNeeded];
    session.updatedAt = [NSDate date];
    [self save];
}

- (nullable AiSession *)sessionById:(NSString *)identifier {
    if (identifier.length == 0) return nil;
    [self loadIfNeeded];
    for (AiSession *session in _sessions) {
        if ([session.identifier isEqualToString:identifier]) {
            return session;
        }
    }
    return nil;
}

- (NSArray<AiSession *> *)sessionsMatchingQuery:(NSString *)query {
    [self loadIfNeeded];
    if (query.length == 0) return [_sessions copy];
    NSString *lower = [query lowercaseString];
    NSMutableArray *result = [NSMutableArray array];
    for (AiSession *session in _sessions) {
        if ([[session.title lowercaseString] containsString:lower]) {
            [result addObject:session];
        }
    }
    return result;
}

+ (NSString *)autoTitleForMessage:(NSString *)message {
    if (message.length == 0) return @"新会话";
    NSString *trimmed = [message stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *single = [[trimmed stringByReplacingOccurrencesOfString:@"\n" withString:@" "] stringByReplacingOccurrencesOfString:@"\r" withString:@" "];
    if (single.length <= kAutoTitleMaxLength) {
        return single;
    }
    return [[single substringToIndex:kAutoTitleMaxLength] stringByAppendingString:@"…"];
}

#pragma mark - 最近会话

- (nullable AiSession *)lastActiveSession {
    [self loadIfNeeded];
    NSString *lastId = [[NSUserDefaults standardUserDefaults] stringForKey:kLastSessionIdKey];
    AiSession *byId = [self sessionById:lastId];
    if (byId) return byId;
    // 无记录或记录失效：返回最新会话（sessions 已按 updatedAt 倒序）
    return _sessions.count > 0 ? _sessions[0] : nil;
}

- (void)setLastActiveSessionId:(NSString *)identifier {
    if (identifier.length == 0) return;
    [[NSUserDefaults standardUserDefaults] setObject:identifier forKey:kLastSessionIdKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end