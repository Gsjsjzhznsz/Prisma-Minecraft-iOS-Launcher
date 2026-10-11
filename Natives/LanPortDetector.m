//
//  LanPortDetector.m
//  Amethyst
//
//  See LanPortDetector.h for the design notes.
//

#import "LanPortDetector.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <unistd.h>

NSString *const LanPortDetectorDidDetectPortNotification = @"LanPortDetectorDidDetectPort";

#pragma mark - Log location

/// <POJAV_HOME>/latestlog.txt -- the file the game process writes to.
static NSString *_Nullable AmeLatestLogPath(void) {
    const char *home = getenv("POJAV_HOME");
    if (home == NULL || home[0] == '\0') return nil;
    return [NSString stringWithFormat:@"%s/latestlog.txt", home];
}

#pragma mark - Patterns

/// Ordered most-specific first.  Keep them anchored on the real game wording:
/// a loose "port 1234" pattern matches unrelated log lines.
static NSArray<NSString *> *AmePortPatterns(void) {
    static NSArray<NSString *> *patterns;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        patterns = @[
            /* en: "Local game hosted on port 54321" / "... on port [54321]" */
            @"hosted\\s+on\\s+port\\s*[:：\\[\\(]?\\s*(\\d{2,5})",
            /* en variant: "Local game hosted on 0.0.0.0:54321" / "on *:54321" */
            @"hosted\\s+on\\s+[\\d\\.\\*]+\\s*[:：]\\s*(\\d{2,5})",
            /* "Started serving on 54321" / "Started serving on port 54321" */
            @"started\\s+serving\\s+on\\s+(?:port\\s*[:：]?\\s*)?(\\d{2,5})",
            /* zh-Hans: "本地游戏已在端口 54321 上开放" */
            @"本地游戏已在端口\\s*[:：]?\\s*(\\d{2,5})",
            /* zh-Hant: "本機遊戲已在連接埠 54321 上開啟" */
            @"本機遊戲已在(?:連接埠|端口)\\s*[:：]?\\s*(\\d{2,5})",
            /* zh variant seen on some builds: "...已在端口:54321 开放" */
            @"已在端口\\s*[:：]\\s*(\\d{2,5})",
        ];
    });
    return patterns;
}

static NSArray<NSRegularExpression *> *AmeCompiledPatterns(void) {
    static NSArray<NSRegularExpression *> *compiled;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSMutableArray<NSRegularExpression *> *list = [NSMutableArray array];
        for (NSString *pattern in AmePortPatterns()) {
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                               options:NSRegularExpressionCaseInsensitive
                                                                                 error:nil];
            if (re != nil) [list addObject:re];
        }
        compiled = [list copy];
    });
    return compiled;
}

#pragma mark - Raw TCP helpers

/// Non-blocking connect to 127.0.0.1:<port>.  Returns YES when the port
/// accepted the connection.  Loopback either connects or refuses instantly,
/// so the wait is bounded by kLoopbackWaitUs.
static const int kLoopbackWaitUs = 150000; /* 150 ms */

static BOOL AmePortAcceptsConnection(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) {
        (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_len = (uint8_t)sizeof(addr);
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    BOOL accepted = NO;
    int rc = connect(fd, (struct sockaddr *)&addr, (socklen_t)sizeof(addr));
    if (rc == 0) {
        accepted = YES;
    } else if (rc < 0 && errno == EINPROGRESS) {
        fd_set writeSet;
        FD_ZERO(&writeSet);
        FD_SET(fd, &writeSet);
        struct timeval tv;
        tv.tv_sec = 0;
        tv.tv_usec = kLoopbackWaitUs;
        int sel = select(fd + 1, NULL, &writeSet, NULL, &tv);
        if (sel > 0 && FD_ISSET(fd, &writeSet)) {
            int sockErr = 0;
            socklen_t errLen = sizeof(sockErr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) == 0 && sockErr == 0) {
                accepted = YES;
            }
        }
    }
    close(fd);
    return accepted;
}

#pragma mark - Minecraft Server-List-Ping

static void AmeAppendVarInt(NSMutableData *data, int32_t value) {
    uint32_t u = (uint32_t)value;
    while (1) {
        uint8_t byte = (uint8_t)(u & 0x7F);
        u >>= 7;
        if (u != 0) byte |= 0x80;
        [data appendBytes:&byte length:1];
        if (u == 0) break;
    }
}

static void AmeAppendString(NSMutableData *data, NSString *value) {
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    NSUInteger length = (utf8 == nil) ? 0 : utf8.length;
    AmeAppendVarInt(data, (int32_t)length);
    if (length > 0) [data appendData:utf8];
}

static void AmeAppendUShort(NSMutableData *data, uint16_t value) {
    uint16_t be = htons(value);
    [data appendBytes:&be length:2];
}

/// Send a 1.7+ handshake (next state = status) followed by a status request and
/// check that the answer looks like the MC status JSON.  Cheap and conclusive:
/// an unrelated listener either closes the socket or answers with garbage.
static BOOL AmePortAnswersLikeMinecraft(uint16_t port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;

    struct timeval tv;
    tv.tv_sec = 2;
    tv.tv_usec = 0;
    (void)setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    (void)setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_len = (uint8_t)sizeof(addr);
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = inet_addr("127.0.0.1");

    if (connect(fd, (struct sockaddr *)&addr, (socklen_t)sizeof(addr)) < 0) {
        close(fd);
        return NO;
    }

    /* handshake: id 0x00, protocol version, server address, port, next state 1 */
    NSMutableData *payload = [NSMutableData data];
    AmeAppendVarInt(payload, 0x00);
    AmeAppendVarInt(payload, 47); /* 1.8 -- universally accepted for status */
    AmeAppendString(payload, @"localhost");
    AmeAppendUShort(payload, port);
    AmeAppendVarInt(payload, 1);

    NSMutableData *packet = [NSMutableData data];
    AmeAppendVarInt(packet, (int32_t)payload.length);
    [packet appendData:payload];

    /* status request: length 1, id 0x00 */
    AmeAppendVarInt(packet, 1);
    AmeAppendVarInt(packet, 0x00);

    BOOL looksLikeMC = NO;
    ssize_t sent = send(fd, packet.bytes, packet.length, 0);
    if (sent == (ssize_t)packet.length) {
        uint8_t buffer[4096];
        ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
        if (received > 0) {
            NSData *response = [NSData dataWithBytes:buffer length:(NSUInteger)received];
            NSString *text = [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
            if (text.length > 0) {
                looksLikeMC = ([text rangeOfString:@"\"players\""].location != NSNotFound ||
                               [text rangeOfString:@"\"version\""].location != NSNotFound ||
                               [text rangeOfString:@"\"description\""].location != NSNotFound);
            }
        }
    }
    close(fd);
    return looksLikeMC;
}

#pragma mark - Detector

@interface LanPortDetector () {
    dispatch_source_t _timer;
    dispatch_queue_t _queue;
    off_t _readOffset;            /* bytes of latestlog.txt already inspected */
    NSString *_partialLine;        /* tail of the previous chunk, not newline-terminated */
    uint16_t _port;
    LanPortSource _source;
    BOOL _detecting;
    /* ★ Task249: repeating loopback scan state */
    dispatch_source_t _scanTimer;
    void (^_scanProgress)(NSUInteger scanned, NSUInteger total);
    BOOL _scanRepeating;
    BOOL _scanSweepBusy;
}
@end

@implementation LanPortDetector

+ (instancetype)sharedInstance {
    static LanPortDetector *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[LanPortDetector alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _queue = dispatch_queue_create("net.amethyst.lanportdetector", DISPATCH_QUEUE_SERIAL);
        _readOffset = 0;
        _port = 0;
        _source = LanPortSourceUnknown;
        _detecting = NO;
    }
    return self;
}

- (uint16_t)detectedPort {
    return _port;
}

- (LanPortSource)source {
    return _source;
}

- (BOOL)isDetecting {
    return _detecting;
}

#pragma mark - Parsing

+ (uint16_t)parsePortFromLogLine:(NSString *)line {
    if (line.length == 0) return 0;

    for (NSRegularExpression *re in AmeCompiledPatterns()) {
        NSTextCheckingResult *match = [re firstMatchInString:line
                                                     options:0
                                                       range:NSMakeRange(0, line.length)];
        if (match == nil || match.numberOfRanges < 2) continue;
        NSRange group = [match rangeAtIndex:1];
        if (group.location == NSNotFound || group.length == 0) continue;

        NSString *digits = [line substringWithRange:group];
        int value = [digits intValue];
        if (value < 1024 || value > 65535) continue;
        return (uint16_t)value;
    }
    return 0;
}

#pragma mark - Auto detection (log tailing)

- (void)startAutoDetection {
    dispatch_async(_queue, ^{
        if (self->_detecting) return;
        if (AmeLatestLogPath() == nil) {
            NSLog(@"[LanPortDetector] POJAV_HOME unavailable, auto detection skipped");
            return;
        }
        self->_detecting = YES;
        self->_readOffset = 0;
        self->_partialLine = nil;
        NSLog(@"[LanPortDetector] auto detection started");
        [self scheduleTimer];
    });
}

/// Must be called on _queue only.
- (void)stopTimerOnQueue {
    if (_timer != nil) {
        dispatch_source_cancel(_timer);
        _timer = nil;
    }
    _detecting = NO;
}

- (void)stopAutoDetection {
    dispatch_async(_queue, ^{
        if (self->_detecting) {
            [self stopTimerOnQueue];
            NSLog(@"[LanPortDetector] auto detection stopped");
        }
        /* ★ Task249：一个开关同时控制两路——日志尾随与周期回环扫描同停。 */
        if (self->_scanRepeating) {
            [self stopLoopbackScanRepeating];
        }
    });
}

- (void)scheduleTimer {
    if (_timer != nil) dispatch_source_cancel(_timer);
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    if (_timer == nil) return;
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                              (uint64_t)(0.8 * NSEC_PER_SEC), (uint64_t)(0.2 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        [strongSelf pollLogFile];
    });
    dispatch_resume(_timer);
}

/// Read whatever was appended to latestlog.txt and look for a port in it.
- (void)pollLogFile {
    NSString *path = AmeLatestLogPath();
    if (path == nil) return;

    struct stat info;
    if (stat(path.fileSystemRepresentation, &info) != 0) return;
    off_t size = info.st_size;

    if (size < _readOffset) {
        /* Game restarted and truncated the log -- restart from the beginning. */
        _readOffset = 0;
        _partialLine = nil;
    }
    if (size <= _readOffset) return;

    static const off_t kMaxChunk = 256 * 1024;
    off_t start = _readOffset;
    if (size - start > kMaxChunk) start = size - kMaxChunk;

    FILE *file = fopen(path.fileSystemRepresentation, "rb");
    if (file == NULL) return;
    if (fseek(file, (long)start, SEEK_SET) != 0) {
        fclose(file);
        return;
    }
    size_t wanted = (size_t)(size - start);
    char *raw = (char *)malloc(wanted + 1);
    if (raw == NULL) {
        fclose(file);
        return;
    }
    size_t got = fread(raw, 1, wanted, file);
    fclose(file);
    raw[got] = '\0';

    _readOffset = size;
    if (got == 0) {
        free(raw);
        return;
    }

    NSData *chunkData = [NSData dataWithBytesNoCopy:raw length:got freeWhenDone:NO];
    NSString *chunk = [[NSString alloc] initWithData:chunkData encoding:NSUTF8StringEncoding];
    if (chunk == nil) {
        chunk = [[NSString alloc] initWithData:chunkData encoding:NSISOLatin1StringEncoding];
    }
    free(raw);
    if (chunk.length == 0) return;

    NSString *text = (_partialLine.length > 0) ? [_partialLine stringByAppendingString:chunk] : chunk;

    /* Split into lines, keeping the unterminated tail for the next pass. */
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger cursor = 0;
    NSUInteger length = text.length;
    NSUInteger lastBreak = NSNotFound;
    for (NSUInteger i = 0; i < length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c == '\n' || c == '\r') {
            NSRange piece = NSMakeRange(cursor, i - cursor);
            [lines addObject:[text substringWithRange:piece]];
            cursor = i + 1;
            lastBreak = i;
        }
    }
    if (lastBreak == NSNotFound) {
        /* No newline at all -- the whole chunk is a partial line. */
        _partialLine = text;
    } else if (cursor < length) {
        _partialLine = [text substringFromIndex:cursor];
    } else {
        _partialLine = nil;
    }

    for (NSString *line in lines) {
        uint16_t port = [LanPortDetector parsePortFromLogLine:line];
        if (port == 0) continue;
        NSLog(@"[LanPortDetector] port %u found in log: %@", port, line);
        [self publishPort:port source:LanPortSourceAuto];
        /* A port is all we need -- stop burning a timer on the log. */
        [self stopTimerOnQueue];
        return;
    }
}

#pragma mark - Repeating loopback scan (Task249/250)

- (BOOL)isLoopbackScanRepeating {
    return _scanRepeating;
}

/// ★ Task250（反馈 7）：端口验活——已知端口是否仍是活着的 MC 服务器。
///   用于 startHostTapped 快捷路径防陈旧端口（上局世界端口已死，直接
///   建房必连不上）。
- (BOOL)isPortStillAlive:(uint16_t)port {
    if (port == 0) return NO;
    return AmePortAcceptsConnection(port) && AmePortAnswersLikeMinecraft(port);
}

- (void)stopLoopbackScanRepeating {
    dispatch_async(_queue, ^{
        if (!self->_scanRepeating && self->_scanTimer == nil) return;
        if (self->_scanTimer != nil) {
            dispatch_source_cancel(self->_scanTimer);
            self->_scanTimer = nil;
        }
        self->_scanRepeating = NO;
        self->_scanProgress = nil;
        self->_scanSweepBusy = NO;
        NSLog(@"[LanPortDetector] repeating loopback scan stopped");
    });
}

- (void)startLoopbackScanRepeatingWithProgress:(void (^)(NSUInteger, NSUInteger))progress {
    dispatch_async(_queue, ^{
        if (self->_scanRepeating) {
            // ★ Task250（反馈 7 三号洞）：已在扫时不再静默丢弃新调用方——
            //   病历：用户重启检测（新 TVC）→ 老周期扫仍在跑 → 新进度块被
            //   丢弃 + 已知端口命中时 tick 静默收工不通知 = 新界面永远
            //   停在检测中。改为：换绑新进度块 + 已知端口立即重播（新
            //   调用方马上收口），扫描状态保持。
            self->_scanProgress = [progress copy];
            uint16_t ame250_known = self->_port;
            if (ame250_known != 0) {
                NSLog(@"[LanPortDetector] Task250: repeating scan already running, re-publish known port %u to new listener", ame250_known);
                [self republishCurrentPort];
            }
            return;
        }
        self->_scanRepeating = YES;
        self->_scanProgress = [progress copy];
        self->_scanSweepBusy = NO;
        NSLog(@"[LanPortDetector] repeating loopback scan started (tick 3s: fast + ephemeral)");

        /* 首轮立即深扫（快端口 + 临时段 + 低位段全范围），兼作旧
         * scanLocalPortsWithProgress 的一次性行为兼容。 */
        [self scanLocalPortsWithProgress:progress completion:nil];

        /* 周期哨兵：世界加载完成后（服务器 bind 端口）的下一轮即命中。
         * 3s 周期 × 每轮仅快端口+临时段（闭端口回环即时 RST，一轮
         * 万余次 connect 总耗时 <1s），CPU/电量可忽略。 */
        if (self->_scanTimer != nil) dispatch_source_cancel(self->_scanTimer);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
        self->_scanTimer = timer;
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                                  (uint64_t)(3.0 * NSEC_PER_SEC),
                                  (uint64_t)(0.5 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil) return;
            if (!strongSelf->_scanRepeating) return;
            if (strongSelf->_scanSweepBusy) return;          /* 上轮未完，本轮跳过 */
            if (strongSelf->_port != 0) {                    /* 已命中（日志路/深扫），收工 */
                // ★ Task250：收工前重播通知（已知端口可能是本次检测开始前
                //   命中的——publishPort 的同值去重不会再次发通知，当前
                //   监听方永远收不到 = 检测页永远等待。重播后收工。）
                NSLog(@"[LanPortDetector] Task250: tick hit known port %u -- re-publishing before stop", strongSelf->_port);
                [strongSelf republishCurrentPort];
                [strongSelf stopLoopbackScanRepeating];
                return;
            }
            strongSelf->_scanSweepBusy = YES;
            void (^prog)(NSUInteger, NSUInteger) = strongSelf->_scanProgress;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                BOOL found = [strongSelf ame249_quickSweepWithProgress:prog];
                dispatch_async(strongSelf->_queue, ^{
                    strongSelf->_scanSweepBusy = NO;
                    if (found || !strongSelf->_scanRepeating) {
                        if (found) [strongSelf stopLoopbackScanRepeating];
                    }
                });
            });
        });
        dispatch_resume(timer);
    });
}

/// 快扫一轮：快端口表 + 临时端口段（MC "对局域网开放" 自动端口的家）。
/// 命中即 publishPort 并返回 YES。在全局队列上调用（不占 _queue）。
- (BOOL)ame249_quickSweepWithProgress:(void (^)(NSUInteger, NSUInteger))progress {
    static const uint16_t kFastPorts[] = { 25565, 25575, 25576, 25577, 25578 };
    NSUInteger fastCount = sizeof(kFastPorts) / sizeof(kFastPorts[0]);
    NSUInteger total = fastCount + (65535 - 49152 + 1);
    NSUInteger scanned = 0;

    for (NSUInteger i = 0; i < fastCount; i++) {
        uint16_t port = kFastPorts[i];
        if (AmePortAcceptsConnection(port) && AmePortAnswersLikeMinecraft(port)) {
            NSLog(@"[LanPortDetector] Task249 quick sweep hit: %u", port);
            dispatch_async(_queue, ^{
                [self publishPort:port source:LanPortSourceAuto];
            });
            return YES;
        }
        scanned++;
        if (progress != nil) progress(scanned, total);
    }
    for (uint32_t port = 49152; port <= 65535; port++) {
        if (AmePortAcceptsConnection((uint16_t)port) &&
            AmePortAnswersLikeMinecraft((uint16_t)port)) {
            NSLog(@"[LanPortDetector] Task249 quick sweep hit: %u", (uint16_t)port);
            uint16_t ame249_hit = (uint16_t)port;
            dispatch_async(_queue, ^{
                [self publishPort:ame249_hit source:LanPortSourceAuto];
            });
            return YES;
        }
        scanned++;
        if ((scanned & 0x3FF) == 0 && progress != nil) progress(scanned, total);
    }
    return NO;
}

#pragma mark - Port bookkeeping

- (void)publishPort:(uint16_t)port source:(LanPortSource)source {
    if (port == 0) return;
    if (_port == port && _source == source) return; /* already known */

    _port = port;
    _source = source;

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LanPortDetectorDidDetectPortNotification
                                                           object:self
                                                         userInfo:@{ @"port": @(port), @"source": @(source) }];
    });
}

/// ★ Task250：无条件重播当前已知端口（startLoopback 重入换绑 + tick 收工
///   前通知；publishPort 的同值去重需要绕开时用本入口）。
- (void)republishCurrentPort {
    uint16_t ame250_port = _port;
    LanPortSource ame250_src = _source;
    if (ame250_port == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LanPortDetectorDidDetectPortNotification
                                                           object:self
                                                         userInfo:@{ @"port": @(ame250_port), @"source": @(ame250_src) }];
    });
}

/// ★ Task250：重启周期扫描（清陈旧端口 + 换绑进度块）——新开一局世界
///   端口必变，上一局的 detectedPort 是毒数据（快捷路径误用/去重吞通知
///   双病灶源头）。TVC/MVC 显式检测入口统一走本方法。
- (void)restartLoopbackScanRepeatingWithProgress:(void (^)(NSUInteger, NSUInteger))progress {
    dispatch_async(_queue, ^{
        if (self->_port != 0) {
            NSLog(@"[LanPortDetector] Task250: restart requested -- clearing stale port %u (new world, port will differ)", self->_port);
            self->_port = 0;
            self->_source = LanPortSourceUnknown;
        }
    });
    [self startLoopbackScanRepeatingWithProgress:progress];
}

- (void)setManualPort:(uint16_t)port {
    if (port == 0) return;
    [self stopAutoDetection];
    dispatch_async(_queue, ^{
        [self publishPort:port source:LanPortSourceManual];
    });
}

- (void)clearPort {
    dispatch_async(_queue, ^{
        self->_port = 0;
        self->_source = LanPortSourceUnknown;
    });
}

#pragma mark - Port scan

- (void)scanLocalPortsWithProgress:(void (^ _Nullable)(NSUInteger scanned, NSUInteger total))progress
                        completion:(void (^)(NSArray<NSNumber *> *ports))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSNumber *> *found = [NSMutableArray array];

        /* Stage 1: the ports people actually pick in the LAN dialog. */
        static const uint16_t kFastPorts[] = { 25565, 25575, 25576, 25577, 25578 };
        NSUInteger fastCount = sizeof(kFastPorts) / sizeof(kFastPorts[0]);
        NSUInteger total = fastCount + (65535 - 49152 + 1);
        NSUInteger scanned = 0;

        for (NSUInteger i = 0; i < fastCount; i++) {
            uint16_t port = kFastPorts[i];
            if (AmePortAcceptsConnection(port) && AmePortAnswersLikeMinecraft(port)) {
                [found addObject:@(port)];
            }
            scanned++;
            if (progress != nil) progress(scanned, total);
        }

        /* Stage 2: ephemeral range -- where the OS puts an auto-assigned port. */
        if (found.count == 0) {
            for (uint32_t port = 49152; port <= 65535; port++) {
                if (AmePortAcceptsConnection((uint16_t)port) &&
                    AmePortAnswersLikeMinecraft((uint16_t)port)) {
                    [found addObject:@((uint16_t)port)];
                    break;
                }
                scanned++;
                if ((scanned & 0x3FF) == 0 && progress != nil) progress(scanned, total);
            }
        }

        /* Stage 3: last resort, the rest of the unprivileged range. */
        if (found.count == 0) {
            total = scanned + (49151 - 1024 + 1);
            for (uint32_t port = 1024; port <= 49151; port++) {
                if (AmePortAcceptsConnection((uint16_t)port) &&
                    AmePortAnswersLikeMinecraft((uint16_t)port)) {
                    [found addObject:@((uint16_t)port)];
                    break;
                }
                scanned++;
                if ((scanned & 0x3FF) == 0 && progress != nil) progress(scanned, total);
            }
        }

        NSLog(@"[LanPortDetector] scan finished, %lu candidate(s)", (unsigned long)found.count);
        if (found.count > 0) {
            uint16_t best = (uint16_t)[found.firstObject unsignedIntValue];
            dispatch_async(_queue, ^{
                [self publishPort:best source:LanPortSourceAuto];
            });
        }
        if (completion != nil) {
            NSArray<NSNumber *> *result = [found copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(result);
            });
        }
    });
}

@end
