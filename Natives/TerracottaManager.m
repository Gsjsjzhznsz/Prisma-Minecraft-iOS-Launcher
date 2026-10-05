#import "utils.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "SilentAudioPlayer.h"
// Task223：公共 EasyTier peer 预检（BSD socket 探测）
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <fcntl.h>
#include <sys/select.h>
#include <errno.h>
#include <string.h>

NSNotificationName TerracottaManagerStateDidChangeNotification = @"TerracottaManagerStateDidChange";

@interface TerracottaManager ()
@property(nonatomic, assign) TerracottaStatus status;
@property(nonatomic, assign) TerracottaRole role;
@property(nonatomic, copy, nullable) NSString *currentInviteCode;
@property(nonatomic, assign) uint16_t currentPort;
@property(nonatomic, copy, nullable) NSString *stageDescription;
@property(nonatomic, copy, nullable) NSArray<TerracottaPlayerProfile *> *players;
@property(nonatomic, copy, nullable) NSString *directConnectURL;
@property(nonatomic, copy, nullable) NSString *lastError;
@property(nonatomic, assign) BOOL initialized;
@end

@implementation TerracottaManager {
    dispatch_source_t _pollTimer;
    NSInteger _lastStateKind;
    NSInteger _lastStateIndex;
    dispatch_queue_t _pollQueue;
}

#pragma mark - Singleton

+ (instancetype)shared {
    static TerracottaManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[TerracottaManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _status = TerracottaStatusDisconnected;
        _role = TerracottaRoleNone;
        _pollQueue = dispatch_queue_create("terracotta.poll", dispatch_queue_attr_make_with_qos_class(
            DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
        /* 单例触发 init 时自动初始化 Terracotta（若库可用） */
        [self initializeTerracotta];
    }
    return self;
}

#pragma mark - Initialization

- (void)initializeTerracotta {
    if (self.initialized) return;
    if (![TerracottaBridge isAvailable]) {
        NSLog(@"[TerracottaManager] libterracotta not linked, multiplayer disabled");
        return;
    }

    NSString *docsDir = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docsDir == nil) docsDir = NSTemporaryDirectory();

    /* 用独立的 terracotta/ 子目录存放工作数据 */
    NSString *workDir = [docsDir stringByAppendingPathComponent:@"terracotta"];
    [[NSFileManager defaultManager] createDirectoryAtPath:workDir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *logPath = [workDir stringByAppendingPathComponent:@"terracotta.log"];

    BOOL ok = [TerracottaBridge startWithWorkingDirectory:workDir loggingPath:logPath];
    if (!ok) {
        NSLog(@"[TerracottaManager] terracotta_ios_start failed");
        self.lastError = localize(@"i18n_str_996", nil);
        self.status = TerracottaStatusError;
        return;
    }
    NSLog(@"[TerracottaManager] Terracotta initialized at %@", workDir);
    self.initialized = YES;
}

#pragma mark - Session Control

- (void)createRoomWithPort:(uint16_t)port
                inviteCode:(NSString *)inviteCode
                playerName:(NSString *)playerName {
    [self resetSessionState];
    self.role = TerracottaRoleHost;
    self.currentPort = port;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = localize(@"i18n_str_997", nil);
    self.lastError = nil;

    [[SilentAudioPlayer shared] startKeepingAlive];

    BOOL ok = [TerracottaBridge startHostWithRoom:inviteCode
                                              port:port
                                        playerName:playerName];
    if (!ok) {
        self.status = TerracottaStatusError;
        self.lastError = localize(@"i18n_str_998", nil);
        [[SilentAudioPlayer shared] stopKeepingAlive];
        [self notifyStateChanged];
        return;
    }
    [self startPolling];
    [self notifyStateChanged];
}

- (BOOL)joinRoomWithInviteCode:(NSString *)inviteCode
                    playerName:(NSString *)playerName {
    if (![TerracottaBridge verifyRoomCode:inviteCode]) {
        self.lastError = localize(@"i18n_str_999", nil);
        return NO;
    }
    [self resetSessionState];
    self.role = TerracottaRoleClient;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = localize(@"terracotta.stage.precheck", nil);
    self.lastError = nil;

    [[SilentAudioPlayer shared] startKeepingAlive];

    // ★ Task223（清单第 11 项）：公共服务器预检——2832c2b terracotta.log 实锤
    //   “Cannot find scaffolding server” = 访客 15s 内未在 EasyTier 网络里
    //   看到 “scaffolding-mc-server-*” 房主。两大成因：①房主不在线；②四个
    //   公共 peer 全部不可达（断网/防火墙）。预检把 ② 提前到加入前给出明确
    //   报错（不再让用户看三轮 15s 的 PingHostFail）；①保持原有自动重试。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *peers = @[
            @"public.easytier.top:11010",
            @"public2.easytier.cn:54321",
        ];
        // Task223 CI 修复：异步探测块内赋值 → 必须 __block（同 DataTransferService lastUi 病例）。
        __block BOOL anyReachable = NO;
        dispatch_group_t g = dispatch_group_create();
        for (NSString *peer in peers) {
            dispatch_group_enter(g);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSArray *parts = [peer componentsSeparatedByString:@":"];
                if (parts.count == 2) {
                    int fd = socket(AF_INET, SOCK_STREAM, 0);
                    if (fd >= 0) {
                        struct sockaddr_in addr;
                        memset(&addr, 0, sizeof(addr));
                        addr.sin_family = AF_INET;
                        addr.sin_port = htons((uint16_t)[parts[1] intValue]);
                        struct hostent *he = gethostbyname(parts[0].UTF8String);
                        if (he != NULL && he->h_addrtype == AF_INET && he->h_addr_list[0] != NULL) {
                            memcpy(&addr.sin_addr, he->h_addr_list[0], he->h_length);
                            // 非阻塞 connect + 2s 轮询（无 libevent 依赖的极简探测）
                            int flags = fcntl(fd, F_GETFL, 0);
                            fcntl(fd, F_SETFL, flags | O_NONBLOCK);
                            int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
                            if (rc == 0) {
                                anyReachable = YES;
                            } else if (rc < 0 && errno == EINPROGRESS) {
                                fd_set wset;
                                FD_ZERO(&wset);
                                FD_SET(fd, &wset);
                                struct timeval tv = {2, 0};
                                if (select(fd + 1, NULL, &wset, NULL, &tv) > 0) {
                                    int soerr = 0;
                                    socklen_t slen = sizeof(soerr);
                                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen);
                                    if (soerr == 0) anyReachable = YES;
                                }
                            }
                        }
                        close(fd);   // Task223 CI 修复：DNS 失败路径同样关闭（原在 if 内 → fd 泄漏）
                    }
                }
                dispatch_group_leave(g);
            });
        }
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!anyReachable) {
                self.status = TerracottaStatusError;
                self.lastError = localize(@"terracotta.error.no_public_peer", nil);
                [[SilentAudioPlayer shared] stopKeepingAlive];
                NSLog(@"[Terracotta] Task223: all public EasyTier peers unreachable -- join aborted with guidance");
                [self notifyStateChanged];
                return;
            }
            NSLog(@"[Terracotta] Task223: public peer precheck passed");
            self.stageDescription = localize(@"i18n_str_1000", nil);
            BOOL ok = [TerracottaBridge setGuestingWithRoom:inviteCode playerName:playerName];
            if (!ok) {
                self.status = TerracottaStatusError;
                self.lastError = localize(@"i18n_str_1001", nil);
                [[SilentAudioPlayer shared] stopKeepingAlive];
                [self notifyStateChanged];
                return;
            }
            [self startPolling];
            [self notifyStateChanged];
        });
    });
    return YES;
}

- (void)stopSession {
    [TerracottaBridge setWaiting];
    [self stopPolling];
    [[SilentAudioPlayer shared] stopKeepingAlive];
    [self resetSessionState];
    [self notifyStateChanged];
}

#pragma mark - State Reset

- (void)resetSessionState {
    self.role = TerracottaRoleNone;
    self.status = TerracottaStatusDisconnected;
    self.currentInviteCode = nil;
    self.currentPort = 0;
    self.stageDescription = nil;
    self.players = nil;
    self.directConnectURL = nil;
    /* lastError 不在此清除，让 UI 能在 stopSession 后仍看到上次错误（如果有） */
    _lastStateKind = -1;
    _lastStateIndex = -1;
}

#pragma mark - Polling

- (void)startPolling {
    [self stopPolling];
    /* dispatch_source_t 定时器，0.5s 间隔，QOS_CLASS_UTILITY 队列避免阻塞主线程 */
    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pollQueue);
    dispatch_time_t start = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_timer(_pollTimer, start,
                              (uint64_t)(0.5 * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) return;
        TerracottaState *state = [TerracottaBridge pollState];
        if (state != nil) {
            [strongSelf applyState:state];
        }
    });
    dispatch_resume(_pollTimer);
}

- (void)stopPolling {
    if (_pollTimer != nil) {
        dispatch_source_cancel(_pollTimer);
        _pollTimer = nil;
    }
}

#pragma mark - State Mapping

/// 把 Rust 侧 8 个底层状态映射到 4 个高层状态，更新所有 @property。
/// 状态去重：state.kind 和 state.index 都没变时跳过通知。
- (void)applyState:(TerracottaState *)state {
    if (state.kind == _lastStateKind && state.index == _lastStateIndex) {
        /* 状态没变，但玩家列表可能变化（新玩家加入），仍更新 */
        if (state.profiles != nil) self.players = state.profiles;
        return;
    }
    _lastStateKind = state.kind;
    _lastStateIndex = state.index;

    switch (state.kind) {
        case TerracottaStateKindWaiting:
            self.status = TerracottaStatusDisconnected;
            self.stageDescription = nil;
            break;
        case TerracottaStateKindHostScanning:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1002", nil);
            break;
        case TerracottaStateKindHostStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1003", nil);
            break;
        case TerracottaStateKindHostOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = localize(@"i18n_str_1004", nil);
            break;
        case TerracottaStateKindGuestConnecting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1005", nil);
            break;
        case TerracottaStateKindGuestStarting:
            self.status = TerracottaStatusConnecting;
            self.stageDescription = localize(@"i18n_str_1003", nil);
            break;
        case TerracottaStateKindGuestOk:
            self.status = TerracottaStatusConnected;
            self.stageDescription = localize(@"i18n_str_1006", nil);
            break;
        case TerracottaStateKindException:
            self.status = TerracottaStatusError;
            self.lastError = [TerracottaBridge describeException:state.exceptionType];
            self.stageDescription = self.lastError;
            /* 异常时停止轮询和保活 */
            [self stopPolling];
            [[SilentAudioPlayer shared] stopKeepingAlive];
            break;
    }

    /* 更新邀请码和直连地址（仅 Rust 侧有值时覆盖） */
    if (state.room.length > 0) self.currentInviteCode = state.room;
    if (state.directConnectURL.length > 0) self.directConnectURL = state.directConnectURL;
    if (state.profiles != nil) self.players = state.profiles;

    [self notifyStateChanged];
}

#pragma mark - Notification

- (void)notifyStateChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
            postNotificationName:TerracottaManagerStateDidChangeNotification object:self];
    });
}

@end
