//
//  AiProvider.m
//  Prisma
//

#import "AiProvider.h"

@implementation AiProvider

- (instancetype)init {
    self = [super init];
    if (self) {
        _identifier = [NSUUID UUID].UUIDString;
        _name = @"";
        _protocol = @"openai_compatible";
        _baseURL = @"";
        _apiKey = @"";
        _model = @"";
        _temperature = 0.7;
        _maxTokens = 4096;
        _contextWindow = 8192;
    }
    return self;
}

- (nullable instancetype)initWithDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    self = [self init];
    if (!self) return nil;

    if ([dict[@"identifier"] isKindOfClass:[NSString class]] && [dict[@"identifier"] length] > 0) {
        _identifier = dict[@"identifier"];
    }
    _name = [dict[@"name"] isKindOfClass:[NSString class]] ? dict[@"name"] : @"";
    if ([dict[@"protocol"] isKindOfClass:[NSString class]] && [dict[@"protocol"] length] > 0) {
        _protocol = dict[@"protocol"];
    }
    _baseURL = [dict[@"baseURL"] isKindOfClass:[NSString class]] ? dict[@"baseURL"] : @"";
    _apiKey = [dict[@"apiKey"] isKindOfClass:[NSString class]] ? dict[@"apiKey"] : @"";
    _model = [dict[@"model"] isKindOfClass:[NSString class]] ? dict[@"model"] : @"";

    NSNumber *temperature = dict[@"temperature"];
    if ([temperature isKindOfClass:[NSNumber class]]) _temperature = temperature.doubleValue;
    NSNumber *maxTokens = dict[@"maxTokens"];
    if ([maxTokens isKindOfClass:[NSNumber class]]) _maxTokens = maxTokens.integerValue;
    NSNumber *contextWindow = dict[@"contextWindow"];
    if ([contextWindow isKindOfClass:[NSNumber class]]) _contextWindow = contextWindow.integerValue;

    return self;
}

+ (nullable instancetype)providerWithDictionary:(NSDictionary *)dict {
    return [[AiProvider alloc] initWithDictionary:dict];
}

- (NSDictionary *)toDictionary {
    return @{
        @"identifier": self.identifier ?: @"",
        @"name": self.name ?: @"",
        @"protocol": self.protocol ?: @"openai_compatible",
        @"baseURL": self.baseURL ?: @"",
        @"apiKey": self.apiKey ?: @"",
        @"model": self.model ?: @"",
        @"temperature": @(self.temperature),
        @"maxTokens": @(self.maxTokens),
        @"contextWindow": @(self.contextWindow),
    };
}

@end