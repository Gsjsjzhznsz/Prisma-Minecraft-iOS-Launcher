#import "utils.h"
#import "TerracottaManager.h"
#import "TerracottaBridge.h"
#import "SilentAudioPlayer.h"
#import "LanPortDetector.h"   // ★ Task256：init 后叫停在飞回环扫描（防探针打崩刚孵出的 ScaffoldingServer）
// Task223：公共 EasyTier peer 预检（BSD socket 探测）
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <fcntl.h>
#include <sys/select.h>
#include <errno.h>
#include <string.h>

NSNotificationName TerracottaManagerStateDidChangeNotification = @"TerracottaManagerStateDidChange";

/// ★ Task256：库初始化静态标志。用静态而非实例属性承载，是为了让
///   +hasInitializedLibrary 能在不创建单例的前提下读到——LanPortDetector
///   的探针闸高频轮询本标志，若经由 [TerracottaManager shared] 访问，
///   探测器自己就会把 Terracotta（连同 ScaffoldingServer）孵化出来。
///   写入点唯一（initializeTerracotta 成功路径），BOOL 平坦读写无需锁。
static BOOL g_ame256_terraLibInitialized = NO;

@interface TerracottaManager ()
@property(nonatomic, assign) TerracottaStatus status;
@property(nonatomic, assign) TerracottaRole role;
@property(nonatomic, copy, nullable) NSString *currentInviteCode;
@property(nonatomic, assign) uint16_t currentPort;
@property(nonatomic, copy, nullable) NSString *stageDescription;
@property(nonatomic, copy, nullable) NSArray<TerracottaPlayerProfile *> *players;
// ★ Task275（E-P2-5）：加入代际令牌——预检窗（最长 ~6s）内用户 stopSession/
// 重复加入时，预检完成回调无条件 setGuesting+startPolling = 会话“复活”/
// 双 guest 流程互踩（PortForwarder _acceptGeneration 同款模式）。
@property(nonatomic, assign) NSInteger ame275_joinGeneration;
@property(nonatomic, copy, nullable) NSString *directConnectURL;
@property(nonatomic, copy, nullable) NSString *lastError;
@property(nonatomic, assign) BOOL initialized;
@end

@implementation TerracottaManager {
    dispatch_source_t _pollTimer;
    NSInteger _lastStateKind;
    NSInteger _lastStateIndex;
    dispatch_queue_t _pollQueue;
    /* ★ Task256：访客 PingHostFail 自动重试账本。
       _guestRetryCount：已自动重试次数（上限 2）。
       _guestRetryArmed：待执行重试的在飞标志（stopSession 撤闸用）。
       _guestRetryPlayerName：重试时原样回传的玩家名（Rust 侧用于向房主
       标识访客；nil 会让房主玩家列表少名字）。 */
    NSInteger _guestRetryCount;
    BOOL _guestRetryArmed;
    NSString *_guestRetryPlayerName;
}

+ (BOOL)hasInitializedLibrary {
    return g_ame256_terraLibInitialized;
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
    g_ame256_terraLibInitialized = YES;
    /* ★ Task256：库初始化 = ScaffoldingServer 已在本机监听。若 LanPortDetector
       的周期扫描还在跑，立刻叫停（防打崩；与探测闸双保险）。 */
    [[LanPortDetector sharedInstance] stopAutoDetection];
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
    /* ★ Task256：新一次加入重置重试账本（上次加入的重试计数不清零会让
       本次加入只剩残余次数）。 */
    _guestRetryCount = 0;
    _guestRetryArmed = NO;
    _guestRetryPlayerName = [playerName copy];
    self.role = TerracottaRoleClient;
    self.currentInviteCode = inviteCode;
    self.status = TerracottaStatusConnecting;
    self.stageDescription = localize(@"terracotta.stage.precheck", nil);
    self.lastError = nil;
    // ★ Task275（E-P2-5）：新 join 递增代际，预检回调快照比对（见下方回调头）。
    self.ame275_joinGeneration++;
    NSInteger ame275_gen = self.ame275_joinGeneration;

    [[SilentAudioPlayer shared] startKeepingAlive];

    // ★ Task223（清单第 11 项）：公共服务器预检——2832c2b terracotta.log 实锤
    //   “Cannot find scaffolding server” = 访客 15s 内未在 EasyTier 网络里
    //   看到 “scaffolding-mc-server-*” 房主。两大成因：①房主不在线；②四个
    //   公共 peer 全部不可达（断网/防火墙）。预检把 ② 提前到加入前给出明确
    //   报错（不再让用户看三轮 15s 的 PingHostFail）；①保持原有自动重试。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // ★ Task255（清单 2：联机备用线路参考 FCL/PCL2CE）：预检 peer 与
        //   libterracotta 内嵌端点对齐（strings libterracotta.a 实证 4 个）。
        //   Task223 旧列表只探前 2 个 TCP——若它们宕/被墙而 etnode 两个
        //   https 端点活着，旧预检会误拦 join（用户被迫干等），与"备用线
        //   路"语义相悖。现 4 端点全部纳入：TCP 2 个走原非阻塞 connect，
        //   https 2 个走轻量 HEAD（2s 超时）；任一可达即放行（库内 EasyTier
        //   自带 peer 轮换，预检只负责"全网全断"的早退拦截）。
        NSArray<NSString *> *peers = @[
            @"public.easytier.top:11010",
            @"public2.easytier.cn:54321",
        ];
        NSArray<NSString *> *httpsPeers = @[
            @"https://etnode.zkitefly.eu.org/node1",
            @"https://etnode.zkitefly.eu.org/node2",
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
                        struct hostent *he = gethostbyname([parts[0] UTF8String]);   // Task223 CI 修复：id 接收者不能点语法（分号曾误入注释——r6 教训）
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
        // ★ Task255：https 端点探测（etnode 两个备用线路；轻量 HEAD + 2s 超时，
        //   任一 2xx/3xx 即算可达——EasyTier 对 https peer 只需 HTTP(S) 层连通）。
        for (NSString *hpeer in httpsPeers) {
            dispatch_group_enter(g);
            NSMutableURLRequest *hreq = [NSMutableURLRequest
                requestWithURL:[NSURL URLWithString:hpeer]
                cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                timeoutInterval:2.0];
            hreq.HTTPMethod = @"HEAD";
            NSURLSession *hs = [NSURLSession sessionWithConfiguration:
                NSURLSessionConfiguration.ephemeralSessionConfiguration];
            __block NSURLSession *ame255_hs = hs;   // 保活至回调完成
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                // ★ Task255 r2 CI 修复（run 795 TerracottaManager.m:211 incompatible
                //   block pointer types）：本仓 dataTaskWithRequest: completionHandler
                //   签名为老顺序 (NSData, NSURLResponse, NSError)（AnnouncementService.m:199 /
                //   ControlRepoViewController 先例同款），标准 (NSURLResponse, NSData, …) 顺序不兼容。
                [[ame255_hs dataTaskWithRequest:hreq
                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                    NSHTTPURLResponse *hresp = (NSHTTPURLResponse *)resp;
                    if (err == nil && hresp.statusCode >= 200 && hresp.statusCode < 400) {
                        anyReachable = YES;
                        NSLog(@"[Terracotta] Task255: https peer reachable: %@", hpeer);
                    }
                    dispatch_group_leave(g);
                    [ame255_hs finishTasksAndInvalidate];
                }] resume];
            });
        }
        dispatch_group_wait(g, DISPATCH_TIME_FOREVER);
        dispatch_async(dispatch_get_main_queue(), ^{
            // ★ Task275（E-P2-5）：代际失效即退出（stopSession/新 join 已使本轮回调作废）
            if (ame275_gen != self.ame275_joinGeneration) {
                NSLog(@"[Terracotta] Task275: join precheck callback stale (gen %ld != %ld) -- dropped",
                      (long)ame275_gen, (long)self.ame275_joinGeneration);
                return;
            }
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
    /* ★ Task256：用户主动停会话 = 撤销在飞的自动重试（4s 延迟窗内
       点停止的竞态面）。 */
    _guestRetryArmed = NO;
    self.ame275_joinGeneration++;   // ★ Task275（E-P2-5）：在飞预检回调作废
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
        // ★ Task275（E-P3-13）：dedup 分支更新 players 后直接 return 无任何通知，
        //   Rust 侧 index 不随 roster 变化时 UI 列表滞留。内容有变才补发通知
        //   （幂等去抖：内容相同不打扰）。
        if (state.profiles != nil) {
            BOOL ame275_changed = ![state.profiles isEqualToArray:self.players];
            self.players = state.profiles;
            if (ame275_changed) [self notifyStateChanged];
        }
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
            /* ★ Task256（用户清单 2：联机参考 FCL/PCL2CE 的重试语义）：
               访客 PingHostFail（type 0，55456d9 装机日志 01:30:39→01:30:56
               实锤：GuestStarting 后 ~17s RoomExperiment 找不到房主即判死）
               自动重试至多 2 次（间隔 4s）——首次组网时 EasyTier 发现/打洞
               慢于 17s 窗口是常态，房主稍后出现在网络里即可被第二/三次
               捕获。用户点停止（stopSession）即撤闸；重试耗尽后照旧报错
               （i18n_str_989 文案已含“确认房主仍在线”指引）。 */
            if (self.role == TerracottaRoleClient &&
                state.exceptionType == 0 &&
                _guestRetryCount < 2) {
                _guestRetryCount++;
                _guestRetryArmed = YES;
                NSInteger ame256_seq = _guestRetryCount;
                NSString *ame256_stage = [NSString stringWithFormat:
                    localize(@"terracotta.stage.retry", @"正在重试连接房主（第 %lu/2 次）…"),
                    (unsigned long)ame256_seq];
                self.stageDescription = ame256_stage;
                NSLog(@"[TerracottaManager] Task256: guest PingHostFail -- auto-retry %lu/2 in 4s", (unsigned long)ame256_seq);
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strongSelf = weakSelf;
                    if (strongSelf == nil) return;
                    if (!strongSelf->_guestRetryArmed) {
                        NSLog(@"[TerracottaManager] Task256: retry %lu cancelled (user stop)", (unsigned long)ame256_seq);
                        return;
                    }
                    strongSelf->_guestRetryArmed = NO;
                    /* 用户在延迟窗内点了停止/新会话 → role 已被 reset */
                    if (strongSelf.role != TerracottaRoleClient || strongSelf.currentInviteCode.length == 0) {
                        NSLog(@"[TerracottaManager] Task256: retry %lu dropped (session reset)", (unsigned long)ame256_seq);
                        return;
                    }
                    NSLog(@"[TerracottaManager] Task256: retry %lu firing (room %@)", (unsigned long)ame256_seq, strongSelf.currentInviteCode);
                    strongSelf.status = TerracottaStatusConnecting;
                    /* ★ Task257（清单 2：自动重试在生产上从未生效的根修）：
                       da21223 装机日志 latestlog.txt 实锤——retry 1 firing 后 26ms
                       内 keeping-alive started→stopped = Exception 态直呼
                       terracotta_ios_set_guesting 被 Rust 状态机拒绝（返回 0），
                       随后 Core 才自行复位 Waiting。重试必须先显式复位 Waiting
                       （与用户手动"停止→重连"同构，FCL/PCL2CE 重试语义），
                       给 1.5s 沉降后再重入访客流程；轮询此时已停（Exception
                       分支 stopPolling），复位态不会被误报上 UI。 */
                    [TerracottaBridge setWaiting];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        __strong typeof(weakSelf) strongSelf2 = weakSelf;
                        if (strongSelf2 == nil) return;
                        /* 沉降窗内用户停止/新会话 → 放弃本次重试 */
                        if (strongSelf2.role != TerracottaRoleClient || strongSelf2.currentInviteCode.length == 0) {
                            NSLog(@"[TerracottaManager] Task257: retry %lu dropped after Waiting reset (session reset)", (unsigned long)ame256_seq);
                            return;
                        }
                        [[SilentAudioPlayer shared] startKeepingAlive];
                        BOOL ok = [TerracottaBridge setGuestingWithRoom:strongSelf2.currentInviteCode
                                                             playerName:strongSelf2->_guestRetryPlayerName];
                        if (!ok) {
                            NSLog(@"[TerracottaManager] Task257: retry %lu set_guesting failed after Waiting reset -- giving up with host-online guidance", (unsigned long)ame256_seq);
                            strongSelf2.status = TerracottaStatusError;
                            strongSelf2.lastError = localize(@"i18n_str_989", nil);
                            [[SilentAudioPlayer shared] stopKeepingAlive];
                            [strongSelf2 notifyStateChanged];
                            return;
                        }
                        NSLog(@"[TerracottaManager] Task257: retry %lu re-entered guest flow", (unsigned long)ame256_seq);
                        [strongSelf2 startPolling];
                        [strongSelf2 notifyStateChanged];
                    });
                });
            }
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
