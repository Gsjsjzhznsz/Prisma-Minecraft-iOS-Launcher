#import "utils.h"
#import "TerracottaBridge.h"
#import "terracotta.h"
#import <fcntl.h>
#import <unistd.h>

#pragma mark - Data Models

@implementation TerracottaPlayerProfile
@end

@implementation TerracottaState
@end

#pragma mark - Bridge Implementation

@implementation TerracottaBridge

/* 把可选 NSString 当作 const char * 传给 C 函数。nil 转 NULL。 */
static void terracottaCallWithOptionalCString(NSString *s, void (^body)(const char *)) {
    if (s != nil) {
        body([s UTF8String]);
    } else {
        body(NULL);
    }
}

#pragma mark - Availability

+ (BOOL)isAvailable {
    return terracotta_ios_available() ? YES : NO;
}

#pragma mark - Lifecycle

+ (BOOL)startWithWorkingDirectory:(NSString *)workingDirectory
                       loggingPath:(NSString *)loggingPath {
    if (!terracotta_ios_available()) {
        NSLog(@"[TerracottaBridge] libterracotta not linked, start ignored");
        return NO;
    }
    int fd = -1;
    if (loggingPath != nil) {
        /* C 标准八进制：O_WRONLY=01, O_CREAT=0100, O_TRUNC=01000, O_APPEND=02000, mode=0644
         * 注意：不能用 C++14 的 0o 前缀（C 语言不支持，AppleClang 会报 invalid suffix） */
        fd = open([loggingPath UTF8String], 02000 | 0100 | 01000, 0644);
    }
    @try {
        return terracotta_ios_start([workingDirectory UTF8String], fd) == 0 ? YES : NO;
    } @finally {
        if (fd >= 0) close(fd);
    }
}

+ (void)setWaiting {
    if (terracotta_ios_available()) terracotta_ios_set_waiting();
}

+ (void)setScanningWithRoom:(NSString *)room
                 playerName:(NSString *)playerName {
    if (!terracotta_ios_available()) return;
    terracottaCallWithOptionalCString(room, ^(const char *roomCStr) {
        terracottaCallWithOptionalCString(playerName, ^(const char *playerCStr) {
            terracotta_ios_set_scanning(roomCStr, playerCStr);
        });
    });
}

+ (BOOL)startHostWithRoom:(NSString *)room
                     port:(uint16_t)port
               playerName:(NSString *)playerName {
    if (!terracotta_ios_available()) return NO;
    __block BOOL result = NO;
    terracottaCallWithOptionalCString(room, ^(const char *roomCStr) {
        terracottaCallWithOptionalCString(playerName, ^(const char *playerCStr) {
            result = (terracotta_ios_start_host_with_port(roomCStr, port, playerCStr) == 1) ? YES : NO;
        });
    });
    return result;
}

+ (BOOL)setGuestingWithRoom:(NSString *)room
                 playerName:(NSString *)playerName {
    if (!terracotta_ios_available()) return NO;
    if (room == nil || room.length == 0) return NO;
    __block BOOL result = NO;
    terracottaCallWithOptionalCString(room, ^(const char *roomCStr) {
        terracottaCallWithOptionalCString(playerName, ^(const char *playerCStr) {
            result = (terracotta_ios_set_guesting(roomCStr, playerCStr) == 1) ? YES : NO;
        });
    });
    return result;
}

+ (BOOL)verifyRoomCode:(NSString *)code {
    if (!terracotta_ios_available()) return NO;
    if (code == nil || code.length == 0) return NO;
    return terracotta_ios_verify_room_code([code UTF8String]) == 3 ? YES : NO;
}

#pragma mark - State Polling

+ (TerracottaState *)pollState {
    if (!terracotta_ios_available()) return nil;
    char *raw = terracotta_ios_get_state();
    if (raw == NULL) return nil;
    @try {
        NSString *jsonStr = [NSString stringWithUTF8String:raw];
        if (jsonStr == nil) return nil;
        NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
        if (data == nil) return nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (json == nil || ![json isKindOfClass:[NSDictionary class]]) return nil;
        return [self parseStateFromJSON:json];
    } @catch (NSException *e) {
        NSLog(@"[TerracottaBridge] pollState parse exception: %@", e);
        return nil;
    } @finally {
        terracotta_ios_free_string(raw);
    }
}

+ (TerracottaState *)parseStateFromJSON:(NSDictionary *)json {
    TerracottaState *state = [[TerracottaState alloc] init];
    NSString *stateStr = json[@"state"];
    state.kind = [self stateKindFromString:stateStr];
    state.index = [json[@"index"] integerValue];
    state.room = json[@"room"];
    state.directConnectURL = json[@"url"];
    state.profileIndex = [json[@"profile_index"] integerValue];
    state.exceptionType = [json[@"type"] integerValue];

    /* 解析玩家列表 */
    NSArray *profilesArray = json[@"profiles"];
    if ([profilesArray isKindOfClass:[NSArray class]]) {
        NSMutableArray<TerracottaPlayerProfile *> *profiles = [NSMutableArray array];
        for (NSDictionary *p in profilesArray) {
            if (![p isKindOfClass:[NSDictionary class]]) continue;
            TerracottaPlayerProfile *profile = [[TerracottaPlayerProfile alloc] init];
            profile.name = p[@"name"];
            profile.machineId = p[@"machine_id"];
            profile.easytierId = p[@"easytier_id"];
            profile.vendor = p[@"vendor"];
            profile.kind = p[@"kind"];
            [profiles addObject:profile];
        }
        state.profiles = profiles;
    }
    return state;
}

+ (TerracottaStateKind)stateKindFromString:(NSString *)s {
    if (s == nil) return TerracottaStateKindWaiting;
    static NSDictionary<NSString *, NSNumber *> *mapping;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mapping = @{
            @"waiting":           @(TerracottaStateKindWaiting),
            @"host-scanning":     @(TerracottaStateKindHostScanning),
            @"host-starting":     @(TerracottaStateKindHostStarting),
            @"host-ok":           @(TerracottaStateKindHostOk),
            @"guest-connecting":  @(TerracottaStateKindGuestConnecting),
            @"guest-starting":    @(TerracottaStateKindGuestStarting),
            @"guest-ok":          @(TerracottaStateKindGuestOk),
            @"exception":         @(TerracottaStateKindException),
        };
    });
    NSNumber *num = mapping[s];
    if (num == nil) return TerracottaStateKindWaiting;
    return (TerracottaStateKind)[num integerValue];
}

#pragma mark - Metadata

+ (NSDictionary<NSString *, id> *)metadata {
    if (!terracotta_ios_available()) return nil;
    char *raw = terracotta_ios_get_metadata();
    if (raw == NULL) return nil;
    @try {
        /* Rust 侧返回 NUL 分隔的 UTF-8："<version>\0<ts_ms>\0<et_version>\0"
         * strlen 不能用（内部有 NUL），手动扫描 3 个 NUL 计算总长度 */
        size_t totalLen = 0;
        char *cursor = raw;
        int nulCount = 0;
        // ★ Task275（E-P1-2）：无界 NUL 扫描加硬上限——Rust 侧返回串不足 3 个 NUL
        //   （版本字段缺失/异常/老版本库）时指针扫过缓冲区末尾 = 堆越界读，
        //   totalLen 随之膨胀、后续 bytes[i] 同样越界。
        while (nulCount < 3 && totalLen < 256) {
            char ch = *cursor;
            totalLen += 1;
            if (ch == 0) nulCount += 1;
            cursor += 1;
        }
        if (nulCount < 3) {
            NSLog(@"[TerracottaBridge] Task275: metadata has <3 NUL separators within 256 bytes -- treating as invalid");
            return nil;
        }
        /* 按 \0 切分 */
        NSMutableArray<NSString *> *segments = [NSMutableArray array];
        const uint8_t *bytes = (const uint8_t *)raw;
        size_t segStart = 0;
        for (size_t i = 0; i < totalLen; i++) {
            if (bytes[i] == 0) {
                if (i > segStart) {
                    NSString *seg = [[NSString alloc] initWithBytes:bytes + segStart
                                                             length:i - segStart
                                                           encoding:NSUTF8StringEncoding];
                    if (seg != nil) [segments addObject:seg];
                }
                segStart = i + 1;
            }
        }
        if (segments.count != 3) return nil;
        long long ts = [segments[1] longLongValue];
        return @{
            @"version":           segments[0],
            @"compileTimestamp":  @(ts),
            @"easytierVersion":   segments[2]
        };
    } @catch (NSException *e) {
        NSLog(@"[TerracottaBridge] metadata parse exception: %@", e);
        return nil;
    } @finally {
        terracotta_ios_free_string(raw);
    }
}

#pragma mark - Exception Description

+ (NSString *)describeException:(NSInteger)type {
    switch (type) {
        case 0: return localize(@"i18n_str_989", nil);
        case 1: return localize(@"i18n_str_990", nil);
        case 2: return localize(@"i18n_str_991", nil);
        case 3: return localize(@"i18n_str_992", nil);
        case 4: return localize(@"i18n_str_993", nil);
        case 5: return localize(@"i18n_str_994", nil);
        default: return [NSString stringWithFormat:localize(@"i18n_str_995", nil), (long)type];
    }
}

@end
