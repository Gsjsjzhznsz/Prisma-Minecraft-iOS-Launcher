//
//  ZeroTierBridge.m
//  Angel Aura Amethyst
//
//  ZeroTier libzt C API 的 Objective-C 封装层实现（精简版）
//
//  实现要点：单例 + NSLock 保护状态；静态 C 函数在回调线程同步提取数据
//  为 NSDictionary，通过 dispatch_async 转发到主线程；框架检测通过
//  zts_node_start() 返回值检测；等待操作使用 dispatch_semaphore_t。
//

#import "ZeroTierBridge.h"
#import "utils.h"

#include <string.h>
#include <stdlib.h>
#include <arpa/inet.h>

static NSString * const kZeroTierErrorDomain = @"ZeroTierBridgeErrorDomain";

typedef NS_ENUM(NSInteger, ZeroTierErrorCode) {
    ZeroTierErrorCodeFrameworkUnavailable = 1, ZeroTierErrorCodeNodeNotStarted = 2,
    ZeroTierErrorCodeNodeStartFailed = 3, ZeroTierErrorCodeNetworkJoinFailed = 4,
    ZeroTierErrorCodeTimeout = 5, ZeroTierErrorCodeInvalidArgument = 6, ZeroTierErrorCodeSocketError = 7,
};

@interface ZeroTierBridge () {
    ZeroTierNodeStatus _nodeStatus;
    NSMutableDictionary<NSNumber *, NSNumber *> *_networkStatuses;
    NSMutableDictionary<NSNumber *, NSString *> *_ipv4Addresses;
    NSMutableDictionary<NSNumber *, NSString *> *_ipv6Addresses;
    BOOL _isStarted;
    BOOL _frameworkAvailable;
    BOOL _frameworkChecked;
    uint64_t _nodeID;
    NSString *_homeDirectory;
    dispatch_semaphore_t _nodeOnlineSemaphore;
    dispatch_semaphore_t _networkEventSemaphore;
    NSLock *_lock;
}
- (void)handleEventData:(NSDictionary *)eventData;
- (BOOL)isNetworkReady:(uint64_t)networkID;
@end

#pragma mark - 事件回调（静态 C 函数）

/// libzt 事件回调入口：在回调线程同步提取数据，封装为 NSDictionary 后转发到主线程
static void zeroTierEventCallback(void *msgPtr) {
    zts_event_msg_t *msg = (zts_event_msg_t *)msgPtr;
    if (!msg) return;

    NSMutableDictionary *eventData = [NSMutableDictionary dictionary];
    eventData[@"eventCode"] = @(msg->event_code);
    if (msg->node) eventData[@"nodeID"] = @(msg->node->node_id);
    if (msg->network) eventData[@"netID"] = @(msg->network->net_id);

    if (msg->addr) {
        eventData[@"addrNetID"] = @(msg->addr->net_id);
        char ipBuf[ZTS_IP_MAX_STR_LEN] = {0};
        struct zts_sockaddr_storage *ss = &msg->addr->addr;
        int family = ss->ss_family;
        void *srcAddr = (family == ZTS_AF_INET)
            ? (void *)&((struct zts_sockaddr_in *)ss)->sin_addr
            : (void *)&((struct zts_sockaddr_in6 *)ss)->sin6_addr;
        if (zts_inet_ntop(family, srcAddr, ipBuf, sizeof(ipBuf))) {
            eventData[@"addrStr"] = [NSString stringWithUTF8String:ipBuf];
            eventData[@"addrFamily"] = @(family);
        }
    }

    NSDictionary *immutableData = [eventData copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[ZeroTierBridge sharedInstance] handleEventData:immutableData];
    });
}

#pragma mark - ZeroTierBridge 实现

@implementation ZeroTierBridge

+ (instancetype)sharedInstance {
    static ZeroTierBridge *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _nodeStatus = ZeroTierNodeStatusStopped;
        _networkStatuses = [[NSMutableDictionary alloc] init];
        _ipv4Addresses = [[NSMutableDictionary alloc] init];
        _ipv6Addresses = [[NSMutableDictionary alloc] init];
        _nodeOnlineSemaphore = dispatch_semaphore_create(0);
        _networkEventSemaphore = dispatch_semaphore_create(0);
        _lock = [[NSLock alloc] init];
    }
    return self;
}

#pragma mark - 框架检测

/// 首次调用通过 zts_node_start() 返回值检测：ZTS_ERR_OK 为真实 framework，
/// ZTS_ERR_SERVICE 为 stub。检测后清理状态并缓存结果。
- (BOOL)isFrameworkAvailable {
    // ★ Task275（E-P1-4）：探测体 dispatch_once 串行化——原探测无互斥（锁只护
    //   缓存标志），两次并发调用（Multiplayer connect 流跑在 global 并发队列，
    //   快速重试/房主+访客双入口可达）时后到者 zts_node_start 返回非 OK，
    //   frameworkAvailable=NO 被永久缓存，本进程终身不可用。
    static dispatch_once_t ame275_onceToken;
    static BOOL ame275_available = NO;
    dispatch_once(&ame275_onceToken, ^{
        int result = zts_node_start();
        BOOL frameworkAvailable = (result == ZTS_ERR_OK);
        if (frameworkAvailable) {
            // 真实 framework，清理启动的节点
            zts_node_stop();
            NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
            while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
                [NSThread sleepForTimeInterval:0.05];
            }
        }
        NSLog(@"[ZeroTierBridge] framework check: zts_node_start()=%d, available=%@", result, frameworkAvailable ? @"YES" : @"NO");
        ame275_available = frameworkAvailable;
        [_lock lock];
        _frameworkAvailable = frameworkAvailable;
        _frameworkChecked = YES;
        [_lock unlock];
    });
    return ame275_available;
}

#pragma mark - 节点管理

- (BOOL)startNodeWithHomeDirectory:(NSString *)homeDir error:(NSError **)error {
    if (!homeDir.length) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeInvalidArgument userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1099", nil)}];
        return NO;
    }
    if (![self isFrameworkAvailable]) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeFrameworkUnavailable userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1100", nil)}];
        return NO;
    }
    // 已启动则直接返回 YES
    [_lock lock];
    if (_isStarted) { [_lock unlock]; return YES; }
    [_lock unlock];

    // 关键修复（stopNode 状态同步防御）：
    // 若 stopNode 在 2 秒超时后仍未完全关闭节点（zts_node_is_online 仍返回 1），
    // 这里再等待最多 3 秒确保旧节点完全停止，避免 zts_init_from_storage 与旧节点冲突。
    if (zts_node_is_online() == 1) {
        NSLog(@"[ZeroTierBridge] startNode: detected node still online (stop not fully completed), waiting for shutdown...");
        NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 3.0;
        while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
            [NSThread sleepForTimeInterval:0.05];
        }
        if (zts_node_is_online() == 1) {
            NSLog(@"[ZeroTierBridge] startNode: node still not shut down, forcing continue (may cause state conflict)");
        }
    }

    int result = zts_init_from_storage([homeDir UTF8String]);
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeStartFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1101", nil), result]}];
        zts_node_stop();
        return NO;
    }
    result = zts_init_set_event_handler(zeroTierEventCallback);
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeStartFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1102", nil), result]}];
        zts_node_stop();
        return NO;
    }
    result = zts_node_start();
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeStartFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1103", nil), result]}];
        zts_node_stop();
        return NO;
    }

    [_lock lock];
    _isStarted = YES;
    _nodeStatus = ZeroTierNodeStatusStarting;
    _homeDirectory = [homeDir copy];
    [_lock unlock];

    NSLog(@"[ZeroTierBridge] node start request submitted, homeDir = %@", homeDir);
    return YES;
}

- (void)stopNode {
    [_lock lock];
    if (!_isStarted) { [_lock unlock]; return; }
    [_lock unlock];

    zts_node_stop();
    // 关键修复（stopNode 状态同步）：
    // 之前主线程调用时把 waitBlock dispatch 到后台异步执行，但状态清理在主线程立即完成。
    // 调用方看到 _isStarted = NO 后立即调用 startNode，可能与后台仍未完成的停止逻辑并发，
    // 导致 zts_init_from_storage / zts_node_start 与正在停止的旧节点状态冲突。
    //
    // 修复方案：主线程也同步等待节点下线，但把最大等待时间缩短到 2 秒，避免 UI 长时间卡顿。
    // 2 秒通常足够 libzt 完成节点关闭流程；超过 2 秒则不再等待，但 libzt 自身最终会完成清理。
    // 调用方（如 disconnectCurrentRoom）在主线程调用时会有最多 2 秒的同步等待，这是可接受的——
    // disconnectCurrentRoom 通常由用户显式触发（点击断开按钮），短暂等待比状态不一致更可取。
    NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + 2.0;
    while (zts_node_is_online() == 1 && [NSDate timeIntervalSinceReferenceDate] < deadline) {
        [NSThread sleepForTimeInterval:0.05];
    }

    [_lock lock];
    _isStarted = NO;
    _nodeStatus = ZeroTierNodeStatusStopped;
    _nodeID = 0;
    _homeDirectory = nil;
    [_networkStatuses removeAllObjects];
    [_ipv4Addresses removeAllObjects];
    [_ipv6Addresses removeAllObjects];
    [_lock unlock];
    NSLog(@"[ZeroTierBridge] node stopped");
}

- (BOOL)isNodeOnline {
    [_lock lock];
    BOOL started = _isStarted;
    [_lock unlock];
    return started && zts_node_is_online() == 1;
}

- (uint64_t)nodeID {
    [_lock lock];
    uint64_t id = _nodeID;
    [_lock unlock];
    if (id != 0) return id;
    if (zts_node_is_online()) {
        id = zts_node_get_id();
        if (id != 0) {
            [_lock lock]; _nodeID = id; [_lock unlock];
        }
    }
    return id;
}

- (ZeroTierNodeStatus)nodeStatus {
    [_lock lock];
    ZeroTierNodeStatus status = _nodeStatus;
    [_lock unlock];
    return status;
}

#pragma mark - 网络管理

- (BOOL)joinNetwork:(uint64_t)networkID error:(NSError **)error {
    [_lock lock];
    BOOL started = _isStarted;
    [_lock unlock];
    if (!started) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNodeNotStarted userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1104", nil)}];
        return NO;
    }
    int result = zts_net_join(networkID);
    if (result != ZTS_ERR_OK) {
        if (error) *error = [NSError errorWithDomain:kZeroTierErrorDomain code:ZeroTierErrorCodeNetworkJoinFailed userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_1105", nil), result]}];
        return NO;
    }
    [_lock lock];
    _networkStatuses[@(networkID)] = @(ZeroTierNetworkStatusRequestingConfig);
    [_lock unlock];
    return YES;
}

- (BOOL)leaveNetwork:(uint64_t)networkID {
    int result = zts_net_leave(networkID);
    if (result != ZTS_ERR_OK) return NO;
    [_lock lock];
    [_networkStatuses removeObjectForKey:@(networkID)];
    [_ipv4Addresses removeObjectForKey:@(networkID)];
    [_ipv6Addresses removeObjectForKey:@(networkID)];
    [_lock unlock];
    return YES;
}

- (ZeroTierNetworkStatus)networkStatus:(uint64_t)networkID {
    [_lock lock];
    NSNumber *statusNum = _networkStatuses[@(networkID)];
    [_lock unlock];
    return statusNum ? (ZeroTierNetworkStatus)[statusNum integerValue] : ZeroTierNetworkStatusUnknown;
}

- (nullable NSString *)ipv4AddressForNetwork:(uint64_t)networkID {
    [_lock lock];
    NSString *addr = _ipv4Addresses[@(networkID)];
    [_lock unlock];
    if (addr) return addr;
    char ipBuf[ZTS_IP_MAX_STR_LEN] = {0};
    if (zts_addr_get_str(networkID, ZTS_AF_INET, ipBuf, sizeof(ipBuf)) == ZTS_ERR_OK) {
        NSString *ipStr = [NSString stringWithUTF8String:ipBuf];
        [_lock lock]; _ipv4Addresses[@(networkID)] = ipStr; [_lock unlock];
        return ipStr;
    }
    return nil;
}

- (nullable NSString *)ipv6AddressForNetwork:(uint64_t)networkID {
    [_lock lock];
    NSString *addr = _ipv6Addresses[@(networkID)];
    [_lock unlock];
    if (addr) return addr;
    char ipBuf[ZTS_IP_MAX_STR_LEN] = {0};
    if (zts_addr_get_str(networkID, ZTS_AF_INET6, ipBuf, sizeof(ipBuf)) == ZTS_ERR_OK) {
        NSString *ipStr = [NSString stringWithUTF8String:ipBuf];
        [_lock lock]; _ipv6Addresses[@(networkID)] = ipStr; [_lock unlock];
        return ipStr;
    }
    return nil;
}

#pragma mark - 等待操作

- (BOOL)waitForNodeOnlineWithTimeout:(NSTimeInterval)timeout {
    if ([self isNodeOnline]) return YES;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if ([self nodeStatus] == ZeroTierNodeStatusStopped) return NO;
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) break;
        dispatch_semaphore_wait(_nodeOnlineSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
        if ([self isNodeOnline]) return YES;
    }
    return NO;
}

- (BOOL)waitForNetworkReady:(uint64_t)networkID timeout:(NSTimeInterval)timeout {
    if ([self isNetworkReady:networkID]) return YES;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        ZeroTierNetworkStatus cachedStatus = [self networkStatus:networkID];
        if (cachedStatus == ZeroTierNetworkStatusAccessDenied ||
            cachedStatus == ZeroTierNetworkStatusNotFound ||
            cachedStatus == ZeroTierNetworkStatusClientTooOld) {
            return NO;
        }
        if ([self isNetworkReady:networkID]) return YES;
        NSTimeInterval remaining = [deadline timeIntervalSinceNow];
        if (remaining <= 0) break;
        dispatch_semaphore_wait(_networkEventSemaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(remaining * NSEC_PER_SEC)));
    }
    return NO;
}

/// 网络就绪判定：传输层就绪且对应地址族已分配（Ad-hoc 网络用 IPv6）
- (BOOL)isNetworkReady:(uint64_t)networkID {
    if (zts_net_transport_is_ready(networkID) != 1) return NO;
    uint8_t highByte = (uint8_t)((networkID >> 56) & 0xFF);
    if (highByte == 0xFF) {
        return zts_addr_is_assigned(networkID, ZTS_AF_INET6) == 1;
    }
    return zts_addr_is_assigned(networkID, ZTS_AF_INET) == 1;
}

#pragma mark - 事件处理（主线程）

- (void)handleEventData:(NSDictionary *)eventData {
    int eventCode = [eventData[@"eventCode"] intValue];
    id<ZeroTierBridgeDelegate> delegate = self.delegate;
    uint64_t netID = [eventData[@"netID"] unsignedLongLongValue];

    switch (eventCode) {
        case ZTS_EVENT_NODE_ONLINE: {
            uint64_t nodeID = [eventData[@"nodeID"] unsignedLongLongValue];
            [_lock lock]; _nodeID = nodeID; _nodeStatus = ZeroTierNodeStatusOnline; [_lock unlock];
            dispatch_semaphore_signal(_nodeOnlineSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNodeOnlineWithID:)]) [delegate zeroTierNodeOnlineWithID:nodeID];
            break;
        }
        case ZTS_EVENT_NODE_OFFLINE: {
            [_lock lock]; _nodeStatus = ZeroTierNodeStatusOffline; [_lock unlock];
            dispatch_semaphore_signal(_nodeOnlineSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNodeOffline)]) [delegate zeroTierNodeOffline];
            break;
        }
        case ZTS_EVENT_NODE_DOWN: {
            [_lock lock]; _nodeStatus = ZeroTierNodeStatusStopped; _isStarted = NO; [_lock unlock];
            if ([delegate respondsToSelector:@selector(zeroTierNodeDown)]) [delegate zeroTierNodeDown];
            break;
        }
        case ZTS_EVENT_NETWORK_OK: {
            // 关键修复（iOS 后台事件堆积缓解）：
            // iOS 应用进入后台后主 RunLoop 暂停，libzt 事件全部堆积在主队列。
            // 回到前台时一次性执行，可能多次触发同一网络的 NETWORK_OK 事件。
            // 这里通过状态去重：若该网络已处于 OK 状态，跳过信号量与 delegate 回调，
            // 避免上层 waitForNetworkReady 误触发、UI 重复刷新抖动。
            // 首次 OK 事件（_networkStatuses 中无记录或状态不同）正常处理。
            [_lock lock];
            NSNumber *existingStatus = _networkStatuses[@(netID)];
            BOOL isDuplicate = (existingStatus != nil &&
                                existingStatus.integerValue == ZeroTierNetworkStatusOk);
            _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusOk);
            [_lock unlock];
            if (isDuplicate) {
                NSLog(@"[ZeroTierBridge] received duplicate NETWORK_OK event (netID=%llu), skipping signal and callback", netID);
                break;
            }
            dispatch_semaphore_signal(_networkEventSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)]) {
                [delegate zeroTierNetworkReady:netID ipv4:[self ipv4AddressForNetwork:netID] ipv6:[self ipv6AddressForNetwork:netID]];
            }
            break;
        }
        case ZTS_EVENT_NETWORK_REQ_CONFIG: {
            [_lock lock]; _networkStatuses[@(netID)] = @(ZeroTierNetworkStatusRequestingConfig); [_lock unlock];
            dispatch_semaphore_signal(_networkEventSemaphore);
            break;
        }
        // 网络失败事件统一处理：更新状态 + 触发信号量 + 调用对应回调
        case ZTS_EVENT_NETWORK_ACCESS_DENIED:
        case ZTS_EVENT_NETWORK_NOT_FOUND:
        case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD:
        case ZTS_EVENT_NETWORK_DOWN: {
            ZeroTierNetworkStatus status = ZeroTierNetworkStatusUnknown;
            SEL callback = NULL;
            switch (eventCode) {
                case ZTS_EVENT_NETWORK_ACCESS_DENIED: status = ZeroTierNetworkStatusAccessDenied; callback = @selector(zeroTierNetworkAccessDenied:); break;
                case ZTS_EVENT_NETWORK_NOT_FOUND: status = ZeroTierNetworkStatusNotFound; callback = @selector(zeroTierNetworkNotFound:); break;
                case ZTS_EVENT_NETWORK_CLIENT_TOO_OLD: status = ZeroTierNetworkStatusClientTooOld; callback = @selector(zeroTierNetworkClientTooOld:); break;
                case ZTS_EVENT_NETWORK_DOWN: status = ZeroTierNetworkStatusDown; callback = @selector(zeroTierNetworkDown:); break;
            }
            // 状态去重：与 NETWORK_OK 同理，避免后台堆积的同类失败事件批量触发
            [_lock lock];
            NSNumber *existingStatus = _networkStatuses[@(netID)];
            BOOL isDuplicate = (existingStatus != nil &&
                                existingStatus.integerValue == (NSInteger)status);
            _networkStatuses[@(netID)] = @(status);
            [_lock unlock];
            if (isDuplicate) {
                NSLog(@"[ZeroTierBridge] received duplicate network failure event (code=%d, netID=%llu), skipping signal and callback",
                      eventCode, netID);
                break;
            }
            dispatch_semaphore_signal(_networkEventSemaphore);
            if (callback && [delegate respondsToSelector:callback]) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:[(id)delegate methodSignatureForSelector:callback]];
                [inv setTarget:(id)delegate];
                [inv setSelector:callback];
                [inv setArgument:&netID atIndex:2];
                [inv invoke];
            }
            break;
        }
        case ZTS_EVENT_ADDR_ADDED_IP4:
        case ZTS_EVENT_ADDR_ADDED_IP6: {
            uint64_t addrNetID = [eventData[@"addrNetID"] unsignedLongLongValue];
            NSString *addr = eventData[@"addrStr"];
            int family = [eventData[@"addrFamily"] intValue];
            BOOL addrChanged = NO;
            if (addr) {
                [_lock lock];
                if (family == ZTS_AF_INET) {
                    NSString *old = _ipv4Addresses[@(addrNetID)];
                    addrChanged = ![addr isEqualToString:old];
                    _ipv4Addresses[@(addrNetID)] = addr;
                } else if (family == ZTS_AF_INET6) {
                    NSString *old = _ipv6Addresses[@(addrNetID)];
                    addrChanged = ![addr isEqualToString:old];
                    _ipv6Addresses[@(addrNetID)] = addr;
                }
                [_lock unlock];
            }
            // 关键修复（iOS 后台事件堆积缓解）：
            // 若地址未变化（重复 ADDR_ADDED 事件），跳过信号量与 delegate 回调，
            // 避免后台堆积的同地址事件批量触发 zeroTierNetworkReady: 造成 UI 抖动。
            // 首次分配地址时 _ipv4Addresses/_ipv6Addresses 中无记录，addrChanged=YES，正常处理。
            if (!addrChanged) {
                NSLog(@"[ZeroTierBridge] received duplicate ADDR_ADDED event (netID=%llu), skipping signal and callback", addrNetID);
                break;
            }
            dispatch_semaphore_signal(_networkEventSemaphore);
            if ([delegate respondsToSelector:@selector(zeroTierNetworkReady:ipv4:ipv6:)] && [self isNetworkReady:addrNetID]) {
                [delegate zeroTierNetworkReady:addrNetID ipv4:[self ipv4AddressForNetwork:addrNetID] ipv6:[self ipv6AddressForNetwork:addrNetID]];
            }
            break;
        }
        default:
            break;
    }
}

#pragma mark - Socket 客户端操作

- (int)createTCPSocket {
    return zts_bsd_socket(ZTS_AF_INET, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
}

- (int)createTCPSocketForFamily:(int)family {
    return zts_bsd_socket(family, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
}

- (int)connectSocket:(int)fd toHost:(NSString *)host port:(uint16_t)port timeout:(NSTimeInterval)timeout {
    if (!host.length || fd < 0) return ZTS_ERR_ARG;

    // 设置 recv/send 超时
    if (timeout > 0) {
        struct zts_timeval tv;
        tv.tv_sec = (long)timeout;
        tv.tv_usec = (long)((timeout - (NSTimeInterval)tv.tv_sec) * 1000000);
        if (tv.tv_usec < 0) tv.tv_usec = 0;
        zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_RCVTIMEO, &tv, sizeof(tv));
        zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_SNDTIMEO, &tv, sizeof(tv));
    }

    // 准备目标地址
    const char *hostCStr = [host UTF8String];
    struct zts_sockaddr_storage addrStorage;
    memset(&addrStorage, 0, sizeof(addrStorage));
    socklen_t addrLen = 0;

    BOOL isIPv6 = (zts_inet_pton(ZTS_AF_INET6, hostCStr, NULL) == 1);
    if (isIPv6) {
        struct zts_sockaddr_in6 *addr6 = (struct zts_sockaddr_in6 *)&addrStorage;
        addr6->sin6_len = sizeof(struct zts_sockaddr_in6);
        addr6->sin6_family = ZTS_AF_INET6;
        addr6->sin6_port = htons(port);
        if (zts_inet_pton(ZTS_AF_INET6, hostCStr, &addr6->sin6_addr) != 1) return ZTS_ERR_ARG;
        addrLen = sizeof(struct zts_sockaddr_in6);
    } else {
        struct zts_sockaddr_in *addr = (struct zts_sockaddr_in *)&addrStorage;
        addr->sin_len = sizeof(struct zts_sockaddr_in);
        addr->sin_family = ZTS_AF_INET;
        addr->sin_port = htons(port);
        if (zts_inet_pton(ZTS_AF_INET, hostCStr, &addr->sin_addr) != 1) return ZTS_ERR_ARG;
        addrLen = sizeof(struct zts_sockaddr_in);
    }

    // 非阻塞 connect + select 实现超时控制
    int origFlags = zts_bsd_fcntl(fd, ZTS_F_GETFL, 0);
    if (origFlags < 0) {
        return zts_bsd_connect(fd, (const struct zts_sockaddr *)&addrStorage, addrLen);
    }
    zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags | ZTS_O_NONBLOCK);

    int connectResult = zts_bsd_connect(fd, (const struct zts_sockaddr *)&addrStorage, addrLen);
    if (connectResult == ZTS_ERR_OK) {
        zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
        return ZTS_ERR_OK;
    }
    if (zts_errno != ZTS_EINPROGRESS) {
        zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
        return connectResult;
    }

    zts_fd_set writeFds;
    ZTS_FD_ZERO(&writeFds);
    ZTS_FD_SET(fd, &writeFds);
    struct zts_timeval selectTimeout;
    selectTimeout.tv_sec = (long)timeout;
    selectTimeout.tv_usec = (long)((timeout - (NSTimeInterval)selectTimeout.tv_sec) * 1000000);
    if (selectTimeout.tv_usec < 0) selectTimeout.tv_usec = 0;

    int selectResult = zts_bsd_select(fd + 1, NULL, &writeFds, NULL, &selectTimeout);
    zts_bsd_fcntl(fd, ZTS_F_SETFL, origFlags);
    if (selectResult <= 0) return ZTS_ERR_SOCKET;

    int socketError = 0;
    socklen_t errorLen = sizeof(socketError);
    if (zts_bsd_getsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_ERROR, &socketError, &errorLen) != ZTS_ERR_OK) return ZTS_ERR_SOCKET;
    if (socketError != 0) return ZTS_ERR_SOCKET;

    // 设置 TCP_NODELAY 降低实时交互延迟
    int noDelay = 1;
    zts_bsd_setsockopt(fd, ZTS_IPPROTO_TCP, ZTS_TCP_NODELAY, &noDelay, sizeof(noDelay));
    return ZTS_ERR_OK;
}

- (int)closeSocket:(int)fd { return zts_bsd_close(fd); }
- (int)shutdownSocket:(int)fd how:(int)how { return zts_bsd_shutdown(fd, how); }
- (ssize_t)sendData:(int)fd buffer:(const void *)buf length:(size_t)len { return zts_bsd_send(fd, buf, len, 0); }
- (ssize_t)recvData:(int)fd buffer:(void *)buf length:(size_t)len { return zts_bsd_recv(fd, buf, len, 0); }

#pragma mark - Socket 服务端 API（供 PortForwarder 房主模式使用）

- (int)createListenSocket {
    return zts_bsd_socket(ZTS_AF_INET, ZTS_SOCK_STREAM, ZTS_IPPROTO_TCP);
}

- (int)bindSocket:(int)fd toPort:(uint16_t)port {
    if (fd < 0) return ZTS_ERR_ARG;
    int reuse = 1;
    zts_bsd_setsockopt(fd, ZTS_SOL_SOCKET, ZTS_SO_REUSEADDR, &reuse, sizeof(reuse));
    struct zts_sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_len = sizeof(struct zts_sockaddr_in);
    addr.sin_family = ZTS_AF_INET;
    addr.sin_port = htons(port);
    addr.sin_addr.s_addr = ZTS_INADDR_ANY;
    return zts_bsd_bind(fd, (const struct zts_sockaddr *)&addr, sizeof(addr));
}

- (int)listenOnSocket:(int)fd {
    if (fd < 0) return ZTS_ERR_ARG;
    return zts_bsd_listen(fd, 128);
}

- (int)acceptOnSocket:(int)fd {
    if (fd < 0) return ZTS_ERR_ARG;
    return zts_bsd_accept(fd, NULL, NULL);
}

#pragma mark - 工具方法

+ (uint64_t)parseNetworkIDFromString:(NSString *)networkIDStr {
    if (!networkIDStr.length) return 0;
    return strtoull([networkIDStr UTF8String], NULL, 16);
}

+ (NSString *)formatNetworkID:(uint64_t)networkID {
    return [NSString stringWithFormat:@"%016llx", networkID];
}

@end
