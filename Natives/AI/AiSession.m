//
//  AiSession.m
//  Prisma
//

#import "AiSession.h"
#import "../utils.h"   // Task202：默认会话标题 i18n 迁移需要 localize()

@implementation AiSession

+ (instancetype)sessionWithTitle:(NSString *)title {
    AiSession *session = [[AiSession alloc] init];
    if (title.length > 0) session.title = title;
    return session;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = [NSUUID UUID].UUIDString;
        _title = localize(@"ame202.ai.new_session", @"新会话");
        NSDate *now = [NSDate date];
        _createdAt = now;
        _updatedAt = now;
        _pinned = NO;
        _messages = [NSMutableArray array];
    }
    return self;
}

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    self = [self init];
    if (!self) return nil;

    if ([dict[@"identifier"] isKindOfClass:[NSString class]] && [dict[@"identifier"] length] > 0) {
        _identifier = dict[@"identifier"];
    }
    if ([dict[@"title"] isKindOfClass:[NSString class]] && [dict[@"title"] length] > 0) {
        _title = dict[@"title"];
    }
    NSNumber *createdTS = dict[@"createdAt"];
    if ([createdTS isKindOfClass:[NSNumber class]]) {
        _createdAt = [NSDate dateWithTimeIntervalSince1970:createdTS.doubleValue];
    }
    NSNumber *updatedTS = dict[@"updatedAt"];
    if ([updatedTS isKindOfClass:[NSNumber class]]) {
        _updatedAt = [NSDate dateWithTimeIntervalSince1970:updatedTS.doubleValue];
    }
    if ([dict[@"pinned"] isKindOfClass:[NSNumber class]]) {
        _pinned = [dict[@"pinned"] boolValue];
    }
    NSArray *rawMessages = dict[@"messages"];
    if ([rawMessages isKindOfClass:[NSArray class]]) {
        [_messages removeAllObjects];
        for (NSDictionary *m in rawMessages) {
            AiMessage *message = [[AiMessage alloc] initWithDictionary:m];
            if (message) [_messages addObject:message];
        }
    }
    return self;
}

- (NSDictionary *)toDictionary {
    NSMutableArray *messageDicts = [NSMutableArray array];
    for (AiMessage *m in self.messages) {
        [messageDicts addObject:[m toDictionary]];
    }
    return @{
        @"identifier": self.identifier ?: @"",
        @"title": self.title ?: @"",
        @"createdAt": @([self.createdAt timeIntervalSince1970]),
        @"updatedAt": @([self.updatedAt timeIntervalSince1970]),
        @"pinned": @(self.pinned),
        @"messages": messageDicts,
    };
}

@end