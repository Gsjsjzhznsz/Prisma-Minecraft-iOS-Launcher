#import "utils.h"
//
//  MultiplayerManager.m
//  Amethyst
//
//  基于 ZeroTier Apple Framework 的 Minecraft 联机功能管理器实现
//
//  ============================================================================
//  设计理念与参照来源
//  ============================================================================
//
//  本文件参照了以下开源项目的联机管理器设计思路：
//
//  1. FCL (FoldCraftLauncher) - Android 平台的 MC 启动器
//     - 其 MultiplayerManager 通过 JNI 调用 libzt 直接在进程内建立 ZeroTier
//       虚拟网络，无需依赖外部 app。本实现采用相同的进程内运行思路。
//     - FCL 启动一个本地 SOCKS5 代理（基于 libzt socket），将 Minecraft 流量
//       转发到 ZeroTier 网络。本实现完全复刻此设计。
//
//  2. ZL2 (ZalithLauncher) - Android 平台的 MC 启动器（PojavLauncher 分支）
//     - 其 LanServerManager 同样基于 ZeroTier，提供了房间卡片 UI、
//       分享码导入、以及与 MC 内置"添加服务器"功能的联动。
//
//  3. ShardLauncher-iOS - iOS 平台的 MC 启动器
//     - 通过 git submodule 引入 zerotier-sockets-apple-framework (zt.framework)
//     - 使用 ZeroTierBridge 单例封装 libzt C API
//     - 缺陷：创建房间时跳转到 my.zerotier.com 官网，本实现修复此问题，
//       在 App 内完成全流程（输入 Network ID 即可加入，无需跳转）。
//
//  iOS 实现策略：
//    1. 直接链接 zt.framework（zerotier-sockets-apple-framework），在进程内运行
//       ZeroTier 节点。无需 NetworkExtension 权限，纯用户态运行。
//    2. 启动本地 SOCKS5 代理（127.0.0.1:1080），通过 libzt 的 BSD socket API
//       将流量转发到 ZeroTier 虚拟网络。
//    3. Minecraft 通过 JVM 参数 -DsocksProxyHost=127.0.0.1 -DsocksProxyPort=1080
//       走 SOCKS5 代理，所有 Minecraft 流量经 ZeroTier 网络到达房主服务器。
//    4. 启动器本地维护"联机房间"列表（房间名 + Network ID + 房主 IP + 端口），
//       使用 NSUserDefaults + NSKeyedArchiver（NSSecureCoding）持久化。
//    5. 启动器提供"分享文本"功能，将房间信息打包成一段带格式的文本，
//       方便通过微信/QQ/iMessage 等社交渠道发送给好友。
//
//  ZeroTier 网络 ID 说明：
//    - 16 位十六进制字符串（64 位无符号整数）
//    - 由用户在 https://my.zerotier.com 后台创建网络后获得
//    - 房主需在后台将网络设为"Private"并授权成员，或设为"Public"让任何人可加入
//    - 加入网络后，ZeroTier 会为每个节点分配一个虚拟 IP（如 10.147.17.x）
//
//  ZeroTier Framework 集成：
//    参考 ShardLauncher-iOS，将 zerotier-sockets-apple-framework 作为 git submodule
//    引入（Natives/external/ZeroTierFramework），随仓库一起 checkout/更新，避免手动
//    复制导致版本陈旧。构建时直接链接 submodule 中的预编译 zt.framework。
//    若 submodule 未初始化，CMake 会报错并提示运行 git submodule update --init。
//
//  ============================================================================

#import "MultiplayerManager.h"
#import "ZeroTierBridge.h"
#import "SOCKS5Proxy.h"
#import "PortForwarder.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import <UIKit/UIKit.h>  // UIApplicationDidEnterBackgroundNotification 等（P0-B 生命周期监听）

#pragma mark - 常量定义

/// NSUserDefaults 中存储房间列表的 key
///
/// 关键修复（移除保存历史房间功能）：此 key 仅用于一次性迁移清理，
/// 不再用于持久化房间列表。用户明确表示不需要保存历史房间功能
/// （FCL 也没有此功能），每次启动器启动时房间列表应为空。
/// 启动时如果检测到旧数据，会主动清除。
static NSString * const kMultiplayerSavedRoomsKey = @"multiplayer_saved_rooms";

/// NSUserDefaults 中存储联机启用状态的 key
/// 用于持久化用户的联机启用意图，独立于节点实际启动状态。
static NSString * const kMultiplayerEnabledKey = @"multiplayer.enabled";

/// MC 默认服务器端口
static NSString * const kDefaultMCPort = @"25565";

/// 分享文本中的各种前缀标记（用于生成和解析）
/// Task222 CI fix：原 static NSString * const = localize(...) 是 C 编译期常量违规
/// （localize 是函数调用，文件域初始化器必须为编译期常量；基线从未编译过此文件，
/// MP-RESTORE 重新纳入构建后暴露）。改在使用点直接 localize()，与下方 636-639 同风格，
/// 且顺带修正语义——分享时按当前语言取值而非进程首次加载时的语言。

/// SOCKS5 代理默认端口（与 SOCKS5Proxy.h 中的 SOCKS5ProxyDefaultPort 一致）
static uint16_t const kMultiplayerDefaultSOCKS5Port = 1080;

/// 传递给 JavaLauncher 的环境变量名，值为 "127.0.0.1:port"
/// JavaLauncher 检测到此环境变量后会注入 -DsocksProxyHost/-DsocksProxyPort 参数
static NSString * const kAMETHYSTSOCKS5ProxyEnvVar = @"AMETHYST_SOCKS5_PROXY";

/// 等待 ZeroTier 节点上线的超时时间（秒）
static NSTimeInterval const kNodeOnlineTimeout = 30.0;

/// 等待 ZeroTier 网络就绪的超时时间（秒）
static NSTimeInterval const kNetworkReadyTimeout = 30.0;

/// ZeroTier 节点身份文件存储目录名（位于 app Documents 目录下）
static NSString * const kZeroTierHomeDirName = @"zerotier_home";

/// 错误域名
static NSString * const kMultiplayerErrorDomain = @"MultiplayerManagerErrorDomain";

/// 错误码
typedef NS_ENUM(NSInteger, MultiplayerErrorCode) {
    MultiplayerErrorCodeRoomNotFound         = 1001, // 房间未找到
    MultiplayerErrorCodeRoomAlreadyExist     = 1002, // 房间已存在（roomId 重复）
    MultiplayerErrorCodeInvalidNetworkId     = 1003, // Network ID 格式无效
    MultiplayerErrorCodeInvalidRoom          = 1004, // 房间对象无效
    MultiplayerErrorCodeParseShareTextFailed = 1005, // 解析分享文本失败
    MultiplayerErrorCodeFrameworkUnavailable = 1006, // zt.framework 不可用（stub 模式）
    MultiplayerErrorCodeNodeStartFailed      = 1007, // ZeroTier 节点启动失败
    MultiplayerErrorCodeNodeOnlineTimeout    = 1008, // 等待节点上线超时
    MultiplayerErrorCodeJoinNetworkFailed    = 1009, // 加入网络失败
    MultiplayerErrorCodeNetworkReadyTimeout  = 1010, // 等待网络就绪超时
    MultiplayerErrorCodeSOCKS5ProxyStartFailed = 1011, // SOCKS5 代理启动失败
};

#pragma mark - MultiplayerRoom 实现

@implementation MultiplayerRoom

/// NSSecureCoding 要求：声明该类支持安全编码
+ (BOOL)supportsSecureCoding {
    return YES;
}

/// 便捷初始化方法
- (instancetype)initWithId:(NSString *)roomId
                      name:(NSString *)name
                 networkId:(NSString *)networkId
                    hostIP:(NSString *)hostIP
                  hostPort:(NSString *)hostPort {
    self = [super init];
    if (self) {
        _roomId = roomId ?: [[NSUUID UUID] UUIDString];
        _name = [name copy] ?: @"";
        _networkId = [networkId copy] ?: @"";
        _hostIP = [hostIP copy] ?: @"";
        _hostPort = [hostPort copy] ?: kDefaultMCPort;
        _roomDescription = @"";
        _status = MultiplayerRoomStatusDisconnected;
        _role = MultiplayerRoomRoleUnknown;
        _ownerName = @"";
        _createdAt = [NSDate date];
        _lastConnectedAt = nil;
    }
    return self;
}

#pragma mark - NSSecureCoding / NSCoding

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _roomId = [coder decodeObjectOfClass:[NSString class] forKey:@"roomId"] ?: @"";
        _name = [coder decodeObjectOfClass:[NSString class] forKey:@"name"] ?: @"";
        _networkId = [coder decodeObjectOfClass:[NSString class] forKey:@"networkId"] ?: @"";
        _hostIP = [coder decodeObjectOfClass:[NSString class] forKey:@"hostIP"] ?: @"";
        _hostPort = [coder decodeObjectOfClass:[NSString class] forKey:@"hostPort"] ?: kDefaultMCPort;
        _roomDescription = [coder decodeObjectOfClass:[NSString class] forKey:@"description"] ?: @"";
        _ownerName = [coder decodeObjectOfClass:[NSString class] forKey:@"ownerName"] ?: @"";

        _createdAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"createdAt"];
        _lastConnectedAt = [coder decodeObjectOfClass:[NSDate class] forKey:@"lastConnectedAt"];

        NSInteger statusValue = [coder decodeIntegerForKey:@"status"];
        if (statusValue < MultiplayerRoomStatusDisconnected ||
            statusValue > MultiplayerRoomStatusError) {
            statusValue = MultiplayerRoomStatusDisconnected;
        }
        _status = (MultiplayerRoomStatus)statusValue;

        // 关键修复：role 字段。旧数据可能不含此 key，decodeObjectForKey:ForKey 会返回 0
        // （NSKeyedArchiver 对未编码的 key 调用 decodeIntegerForKey 返回 0），
        // 即 MultiplayerRoomRoleUnknown，调用方会回退到 IP 启发式以保持兼容。
        NSInteger roleValue = [coder decodeIntegerForKey:@"role"];
        if (roleValue < MultiplayerRoomRoleUnknown ||
            roleValue > MultiplayerRoomRoleGuest) {
            roleValue = MultiplayerRoomRoleUnknown;
        }
        _role = (MultiplayerRoomRole)roleValue;
    }
    return self;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:self.roomId forKey:@"roomId"];
    [coder encodeObject:self.name forKey:@"name"];
    [coder encodeObject:self.networkId forKey:@"networkId"];
    [coder encodeObject:self.hostIP forKey:@"hostIP"];
    [coder encodeObject:self.hostPort forKey:@"hostPort"];
    [coder encodeObject:self.roomDescription forKey:@"description"];
    [coder encodeObject:self.ownerName forKey:@"ownerName"];
    [coder encodeObject:self.createdAt forKey:@"createdAt"];
    [coder encodeObject:self.lastConnectedAt forKey:@"lastConnectedAt"];
    [coder encodeInteger:(NSInteger)self.status forKey:@"status"];
    [coder encodeInteger:(NSInteger)self.role forKey:@"role"];
}

#pragma mark - 描述方法（便于调试）

- (NSString *)description {
    return [NSString stringWithFormat:@"<MultiplayerRoom: %p roomId=%@ name=%@ networkId=%@ host=%@:%@ status=%ld>",
            self,
            self.roomId,
            self.name,
            self.networkId,
            self.hostIP,
            self.hostPort,
            (long)self.status];
}

#pragma mark - 复制与相等性（便于去重和比较）

- (id)copyWithZone:(NSZone *)zone {
    MultiplayerRoom *copy = [[MultiplayerRoom alloc] init];
    copy.roomId = [self.roomId copy];
    copy.name = [self.name copy];
    copy.networkId = [self.networkId copy];
    copy.hostIP = [self.hostIP copy];
    copy.hostPort = [self.hostPort copy];
    copy.roomDescription = [self.roomDescription copy];
    copy.status = self.status;
    copy.role = self.role;
    copy.ownerName = [self.ownerName copy];
    copy.createdAt = [self.createdAt copy];
    copy.lastConnectedAt = [self.lastConnectedAt copy];
    return copy;
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[MultiplayerRoom class]]) return NO;
    MultiplayerRoom *other = (MultiplayerRoom *)object;
    return [self.roomId isEqualToString:other.roomId];
}

- (NSUInteger)hash {
    return self.roomId.hash;
}

@end

#pragma mark - MultiplayerManager 实现

@interface MultiplayerManager () <ZeroTierBridgeDelegate>
{
    /// 用于保护房间列表读写操作的锁
    dispatch_queue_t _serializationQueue;

    /// 保护 _currentRoom / _currentLocalIP / _nodeStarted 等连接状态的锁
    NSLock *_stateLock;
}

/// 可读写的房间列表（头文件中声明为 readonly）
@property (nonatomic, strong, readwrite) NSMutableArray<MultiplayerRoom *> *internalRooms;

/// 可读写的当前房间（头文件中声明为 readonly）
/// 关键修复（M1）：改为 atomic，保证 setter 的原子性，避免多线程读写时读到中间状态。
@property (atomic, strong, readwrite, nullable) MultiplayerRoom *currentRoom;

/// 可读写的 SOCKS5 端口
/// 关键修复（M1）：改为 atomic，与头文件声明保持一致
@property (atomic, assign, readwrite) uint16_t currentSOCKS5Port;

/// 可读写的本地 IP
/// 关键修复（M1）：改为 atomic，与头文件声明保持一致
@property (atomic, copy, readwrite, nullable) NSString *currentLocalIP;

/// 可读写的端口转发本地端口
@property (atomic, assign, readwrite) uint16_t currentForwardingPort;

/// ZeroTier 节点是否已启动（不代表已上线）
@property (nonatomic, assign, readwrite) BOOL nodeStarted;

/// 当前正在连接的 Network ID（uint64_t 形式，用于 ZeroTierBridge 查询状态）
/// 0 表示当前没有正在连接的网络
@property (nonatomic, assign) uint64_t currentNetworkID;

/// 连接流程取消标志（SubTask 4.2：显式取消机制）
///
/// 由 disconnectCurrentRoom 设置为 YES，connectToRoomFlow 在每个步骤前检查。
/// 这与 M5 的"检查 currentRoom 是否变更"不同：
///   - M5 检查 room 对象是否被替换（过度防御，已移除）
///   - 本标志仅在显式断开时设置，是合法的取消机制
@property (atomic, assign, readwrite) BOOL connectionCancelled;
@end

@implementation MultiplayerManager

#pragma mark - 单例模式

+ (instancetype)sharedManager {
    static MultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    static MultiplayerManager *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [super allocWithZone:zone];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serializationQueue = dispatch_queue_create("com.angelaura.multiplayer.serialization", DISPATCH_QUEUE_SERIAL);
        _stateLock = [[NSLock alloc] init];
        _internalRooms = [[NSMutableArray alloc] init];
        _currentRoom = nil;
        _currentSOCKS5Port = 0;
        _currentLocalIP = nil;
        _nodeStarted = NO;
        _currentNetworkID = 0;

        // 关键修复（移除保存历史房间功能）：
        // 不再从 NSUserDefaults 加载历史房间列表，每次启动时房间列表为空。
        // 同时主动清除可能存在的旧数据（一次性迁移），避免残留。
        [self cleanupLegacySavedRooms];

        // 设置 ZeroTierBridge 代理，接收节点/网络状态回调
        [[ZeroTierBridge sharedInstance] setDelegate:self];

        // 关键修复（P0-B）：监听 iOS 应用生命周期通知
        // iOS 后台限制会挂起/回收 ZeroTier 的网络连接，导致节点频繁掉线。
        // 应用进入后台时：记录当前状态，允许 libzt 自愈，不主动停止节点
        // 应用回到前台时：检测节点状态，若掉线则触发自动重连和数据平面恢复
        // 注意：不在进后台时停止节点——iOS 后台 RunLoop 仍能处理 libzt 事件，
        // libzt 自身的 NAT keepalive 会在短时间内维持连接，主动停止反而增加重连成本。
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationWillEnterForeground)
                                                     name:UIApplicationWillEnterForegroundNotification
                                                   object:nil];

        NSLog(@"[MultiplayerManager] Initialization complete (no legacy rooms loaded, room list empty, lifecycle listeners registered)");
    }
    return self;
}

#pragma mark - iOS 应用生命周期处理

/// 应用进入后台
/// iOS 后台策略：
///   - 不主动停止 ZeroTier 节点（libzt 自身有 NAT keepalive，短时间后台能维持）
///   - 记录当前是否有活跃联机房间，用于回前台时判断是否需要恢复
///   - NSTimer 在后台会被挂起，保活定时器会暂时失效，回前台时恢复
- (void)applicationDidEnterBackground {
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    BOOL hasActiveRoom = (room != nil && self.currentNetworkID != 0);
    [_stateLock unlock];

    if (hasActiveRoom) {
        NSLog(@"[MultiplayerManager] App entered background: active multiplayer room exists (%@), "
              @"relying on libzt self-healing, will verify on foreground", room.name);
    } else {
        NSLog(@"[MultiplayerManager] App entered background: no active multiplayer rooms");
    }
}

/// 应用回到前台
///
/// 简化策略（参照 spec）：
///   - 检测节点状态，若仍在线则检查数据平面是否需要恢复
///   - 若掉线则一次性 stopNode + startNodeWithHomeDirectory: + 重新加入网络，
///     不做指数退避（原自动重连逻辑已移除）
- (void)applicationWillEnterForeground {
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    uint64_t netID = _currentNetworkID;
    BOOL hasActiveRoom = (room != nil && netID != 0);
    [_stateLock unlock];

    if (!hasActiveRoom) {
        NSLog(@"[MultiplayerManager] App returned to foreground: no active multiplayer rooms, no recovery needed");
        return;
    }

    NSLog(@"[MultiplayerManager] App returned to foreground: active multiplayer room detected (%@), checking ZeroTier node status", room.name);

    // 异步检测节点状态，避免阻塞主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL nodeOnline = [[ZeroTierBridge sharedInstance] isNodeOnline];
        if (nodeOnline) {
            // 节点仍在线，检查数据平面是否需要恢复
            NSLog(@"[MultiplayerManager] App returned to foreground: ZeroTier node still online, checking data plane");
            [self ensureDataPlaneRunningForCurrentRoom];
            return;
        }

        // 节点已掉线（iOS 后台杀掉了连接），一次性 stopNode + startNode + 重新加入网络
        NSLog(@"[MultiplayerManager] App returned to foreground: ZeroTier node went offline (iOS background limit), restarting node");
        [[ZeroTierBridge sharedInstance] stopNode];

        // 重置节点启动状态标志，确保 ensureNodeStartedWithCompletion 能重新启动
        [self->_stateLock lock];
        self->_nodeStarted = NO;
        [self->_stateLock unlock];

        NSString *homeDir = [self zeroTierHomeDirectory];
        NSError *startError = nil;
        BOOL started = [[ZeroTierBridge sharedInstance] startNodeWithHomeDirectory:homeDir
                                                                             error:&startError];
        if (!started) {
            NSLog(@"[MultiplayerManager] App returned to foreground: node restart failed: %@",
                  startError.localizedDescription ?: localize(@"i18n_str_97", nil));
            return;
        }

        [self->_stateLock lock];
        self->_nodeStarted = YES;
        [self->_stateLock unlock];

        // 等待节点上线
        BOOL online = [[ZeroTierBridge sharedInstance] waitForNodeOnlineWithTimeout:kNodeOnlineTimeout];
        if (!online) {
            NSLog(@"[MultiplayerManager] App returned to foreground: node online timeout (%.0fs)", kNodeOnlineTimeout);
            return;
        }

        // 重新加入网络
        NSError *joinError = nil;
        if (![[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError]) {
            NSLog(@"[MultiplayerManager] App returned to foreground: re-join network failed: %@",
                  joinError.localizedDescription ?: localize(@"i18n_str_97", nil));
            return;
        }

        // 等待网络就绪
        BOOL ready = [[ZeroTierBridge sharedInstance] waitForNetworkReady:netID
                                                                  timeout:kNetworkReadyTimeout];
        if (!ready) {
            NSLog(@"[MultiplayerManager] App returned to foreground: network ready wait failed (%.0fs)", kNetworkReadyTimeout);
            return;
        }

        // 更新本地 IP（网络就绪回调可能也会更新，但这里同步更新一次确保状态正确）
        NSString *localIP = nil;
        if ([self isAdhocNetworkId:room.networkId]) {
            localIP = [[ZeroTierBridge sharedInstance] ipv6AddressForNetwork:netID];
        } else {
            localIP = [[ZeroTierBridge sharedInstance] ipv4AddressForNetwork:netID];
        }
        if (localIP.length > 0) {
            [self->_stateLock lock];
            self.currentLocalIP = localIP;
            [self->_stateLock unlock];
        }

        // 恢复数据平面（SOCKS5 + PortForwarder）
        NSLog(@"[MultiplayerManager] App returned to foreground: node re-online, restoring data plane");
        [self ensureDataPlaneRunningForCurrentRoom];
    });
}

#pragma mark - 对外暴露的只读属性

- (NSArray<MultiplayerRoom *> *)savedRooms {
    // 关键修复（C2）：移除 dispatch_sync(dispatch_get_main_queue())，
    // 因为从后台线程 dispatch_sync 到主线程会与 @synchronized(self) 形成两套锁机制混用，
    // 导致死锁风险（主线程等待 @synchronized 释放，后台线程等待主线程执行）。
    // 修复方案：统一使用 @synchronized 保护 _internalRooms 的读写，
    // 返回不可变副本（copy），调用方修改不影响内部状态。
    @synchronized(self) {
        return [_internalRooms copy];
    }
}

- (BOOL)isSOCKS5ProxyRunning {
    return [[SOCKS5Proxy sharedProxy] isRunning];
}

- (BOOL)isPortForwarderRunning {
    return [[PortForwarder sharedForwarder] isRunning];
}

- (BOOL)isNodeOnline {
    return [[ZeroTierBridge sharedInstance] isNodeOnline];
}

#pragma mark - 联机启用状态管理

/// 用户是否启用了联机（从 NSUserDefaults 读取）
///
/// 此属性独立于 isNodeStarted，表示用户的意图而非节点实际状态。
/// 用于在 ViewController 重新加载时恢复联机开关状态。
- (BOOL)isMultiplayerEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kMultiplayerEnabledKey];
}

/// 设置联机启用状态（持久化到 NSUserDefaults）
- (void)setMultiplayerEnabled:(BOOL)enabled {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if (enabled) {
        [defaults setBool:YES forKey:kMultiplayerEnabledKey];
    } else {
        [defaults setBool:NO forKey:kMultiplayerEnabledKey];
    }
    [defaults synchronize];
    NSLog(@"[MultiplayerManager] Multiplayer enabled state set to %d", enabled);
}

#pragma mark - 数据持久化（已禁用）

/// 清除旧的保存房间数据（一次性迁移）
///
/// 关键修复（移除保存历史房间功能）：
/// 用户明确表示不需要保存历史房间功能（FCL 也没有此功能）。
/// 此方法在 init 中调用，主动清除可能存在于 NSUserDefaults 中的旧房间数据。
/// 清除后，房间列表完全在内存中管理，不进行持久化。
- (void)cleanupLegacySavedRooms {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSData *legacyData = [defaults dataForKey:kMultiplayerSavedRoomsKey];
    if (legacyData && legacyData.length > 0) {
        NSLog(@"[MultiplayerManager] Detected legacy saved room data (%lu bytes), cleaning up...",
              (unsigned long)legacyData.length);
        [defaults removeObjectForKey:kMultiplayerSavedRoomsKey];
        [defaults synchronize];
        NSLog(@"[MultiplayerManager] Legacy room data cleared (room list no longer persisted)");
    }
}

/// loadRooms 已废弃（空操作）
///
/// 关键修复（移除保存历史房间功能）：房间列表不再从 NSUserDefaults 加载。
/// 每次启动器启动时房间列表为空，房间仅在当前会话中存在（内存中）。
/// 此方法保留为空操作是为了兼容现有代码中可能的调用（虽然 init 已不再调用）。
- (void)loadRooms {
    // 空操作：不再从持久化存储加载房间列表
    @synchronized(self) {
        self.internalRooms = [[NSMutableArray alloc] init];
    }
}

/// saveRooms 已废弃（空操作）
///
/// 关键修复（移除保存历史房间功能）：房间列表不再持久化到 NSUserDefaults。
/// 此方法保留为空操作是为了兼容现有代码中大量的 [self saveRooms] 调用，
/// 避免需要修改每一处调用点。房间列表仅在内存中管理，关闭启动器后自动清空。
- (void)saveRooms {
    // 空操作：不再持久化房间列表到 NSUserDefaults
    // 房间列表仅在内存中管理，关闭启动器后自动清空
}

#pragma mark - 框架检测与节点管理

- (BOOL)isFrameworkAvailable {
    return [[ZeroTierBridge sharedInstance] isFrameworkAvailable];
}

- (BOOL)isNodeStarted {
    [_stateLock lock];
    BOOL started = _nodeStarted;
    [_stateLock unlock];
    return started;
}

/// 获取 ZeroTier 节点身份文件存储目录
/// 位于 app Documents 目录下的 zerotier_home 子目录
- (NSString *)zeroTierHomeDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDir = paths.firstObject ?: NSTemporaryDirectory();
    NSString *homeDir = [documentsDir stringByAppendingPathComponent:kZeroTierHomeDirName];

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:homeDir]) {
        [fm createDirectoryAtPath:homeDir
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
    }
    return homeDir;
}

- (void)ensureNodeStartedWithCompletion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // 如果节点已启动，直接回调成功
    if ([self isNodeStarted]) {
        NSLog(@"[MultiplayerManager] ZeroTier node already started, skipping duplicate start");
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, nil);
            });
        }
        return;
    }

    // 检测 framework 是否可用
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[MultiplayerManager] zt.framework unavailable, cannot start ZeroTier node");
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeFrameworkUnavailable
                                              userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_603", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSLog(@"[MultiplayerManager] Starting ZeroTier node...");

    // 在后台线程启动节点，避免阻塞主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *homeDir = [self zeroTierHomeDirectory];
        NSError *startError = nil;
        BOOL success = [[ZeroTierBridge sharedInstance] startNodeWithHomeDirectory:homeDir
                                                                            error:&startError];
        if (success) {
            [self->_stateLock lock];
            self->_nodeStarted = YES;
            [self->_stateLock unlock];
            NSLog(@"[MultiplayerManager] ZeroTier node start request submitted, waiting for online...");
        } else {
            NSLog(@"[MultiplayerManager] ZeroTier node start failed: %@", startError.localizedDescription);
        }

        if (completion) {
            NSError *cbError = success ? nil : [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                     code:MultiplayerErrorCodeNodeStartFailed
                                                                 userInfo:@{NSLocalizedDescriptionKey: startError.localizedDescription ?: localize(@"i18n_str_604", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(success, cbError);
            });
        }
    });
}

#pragma mark - 兼容旧 API（已废弃）

- (BOOL)isZeroTierAppInstalled {
    // 旧 API：检测外部 ZeroTier One app 是否安装
    // 新版本：检测 zt.framework 是否可用
    return [self isFrameworkAvailable];
}

- (void)setZeroTierInstalledOverride:(BOOL)installed {
    // 旧 API：用户手动覆盖 ZeroTier 安装状态
    // 新版本：进程内框架无需此机制，空操作
    NSLog(@"[MultiplayerManager] setZeroTierInstalledOverride:%d is deprecated, no longer needed in new version", installed);
}

- (BOOL)isZeroTierInstallOverridden {
    // 旧 API：用户是否已手动覆盖
    // 新版本：始终返回 NO
    return NO;
}

- (void)openZeroTierApp {
    // 旧 API：打开外部 ZeroTier One app
    // 新版本：进程内框架，无需打开外部 app，空操作
    NSLog(@"[MultiplayerManager] openZeroTierApp is deprecated, new version uses in-process framework");
}

#pragma mark - 网络加入与离开

- (void)joinNetwork:(NSString *)networkId
         completion:(void (^)(BOOL, NSError * _Nullable))completion {
    if (!networkId || networkId.length == 0) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_605", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if (![self isValidNetworkId:trimmedNetworkId]) {
        NSLog(@"[MultiplayerManager] joinNetwork: Invalid Network ID format: %@", trimmedNetworkId);
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_606", nil), trimmedNetworkId]}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    // 确保节点已启动后再加入网络
    [self ensureNodeStartedWithCompletion:^(BOOL nodeStarted, NSError * _Nullable nodeError) {
        if (!nodeStarted) {
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, nodeError);
                });
            }
            return;
        }

        // 在后台线程执行 joinNetwork（ZeroTierBridge 是同步调用，但内部只是提交请求）
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:trimmedNetworkId];
            if (netID == 0) {
                if (completion) {
                    NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                          code:MultiplayerErrorCodeInvalidNetworkId
                                                      userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_607", nil)}];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(NO, error);
                    });
                }
                return;
            }

            NSError *joinError = nil;
            BOOL success = [[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError];
            if (success) {
                NSLog(@"[MultiplayerManager] Joined ZeroTier network %@, waiting for network ready...", trimmedNetworkId);
            } else {
                NSLog(@"[MultiplayerManager] Join ZeroTier network failed: %@", joinError.localizedDescription);
            }

            if (completion) {
                NSError *cbError = success ? nil : [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                          code:MultiplayerErrorCodeJoinNetworkFailed
                                                                      userInfo:@{NSLocalizedDescriptionKey: joinError.localizedDescription ?: localize(@"i18n_str_608", nil)}];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(success, cbError);
                });
            }
        });
    }];
}

- (BOOL)leaveNetwork:(NSString *)networkId {
    if (!networkId || networkId.length == 0) {
        NSLog(@"[MultiplayerManager] leaveNetwork: networkId is nil");
        return NO;
    }

    NSString *trimmedNetworkId = [networkId stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:trimmedNetworkId];
    if (netID == 0) {
        NSLog(@"[MultiplayerManager] leaveNetwork: Network ID parse failed: %@", trimmedNetworkId);
        return NO;
    }

    BOOL success = [[ZeroTierBridge sharedInstance] leaveNetwork:netID];
    if (success) {
        NSLog(@"[MultiplayerManager] Left ZeroTier network %@", trimmedNetworkId);
    } else {
        NSLog(@"[MultiplayerManager] Leave ZeroTier network failed: %@", trimmedNetworkId);
    }

    // 清理当前网络 ID 跟踪
    [_stateLock lock];
    if (_currentNetworkID == netID) {
        _currentNetworkID = 0;
    }
    [_stateLock unlock];
    return success;
}

#pragma mark - 房间管理（增删改查）

- (void)addRoom:(MultiplayerRoom *)room {
    if (!room) {
        NSLog(@"[MultiplayerManager] addRoom: room is nil");
        return;
    }

    if (!room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] addRoom: roomId is nil, auto-generating");
        room.roomId = [[NSUUID UUID] UUIDString];
    }

    if (!room.name || room.name.length == 0) {
        room.name = localize(@"i18n_str_609", nil);
    }

    if (!room.hostPort || room.hostPort.length == 0) {
        room.hostPort = kDefaultMCPort;
    }

    if (!room.createdAt) {
        room.createdAt = [NSDate date];
    }

    @synchronized(self) {
        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                NSLog(@"[MultiplayerManager] addRoom: roomId already exists: %@", room.roomId);
                return;
            }
        }

        [self.internalRooms addObject:room];
        [self sortRoomsByCreatedAt];
    }

    NSLog(@"[MultiplayerManager] Room added: %@ (%@)", room.name, room.roomId);
    [self saveRooms];
}

- (void)removeRoom:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        NSLog(@"[MultiplayerManager] removeRoom: roomId is nil");
        return;
    }

    // 关键修复（M6）：不在 @synchronized 内调用 disconnectCurrentRoom。
    // 之前在 @synchronized 内调用 disconnectCurrentRoom，后者会调用
    // [[SOCKS5Proxy sharedProxy] stop]，stop 会等待客户端线程退出（最长 2 秒）。
    // 此期间 @synchronized(self) 被持有，阻塞所有房间列表操作
    // （savedRooms、addRoom:、updateRoom:、roomWithId: 等），可能导致主线程 UI 卡顿。
    //
    // 修复方案：
    //   1. 在 @synchronized 内只做房间列表的修改和判断是否需要断开
    //   2. 把 disconnectCurrentRoom 的调用移到 @synchronized 外面
    //
    // 关键修复（M2）：移除冗余的 self.currentRoom = nil 和 roomToDisconnect.status = ...
    // disconnectCurrentRoom 已经在 _stateLock 内清空了 currentRoom 和更新了 room.status，
    // 不需要再次设置（且在无 _stateLock 时写入 currentRoom 构成数据竞争）。

    BOOL needsDisconnect = NO;
    @synchronized(self) {
        NSMutableArray *roomsToKeep = [[NSMutableArray alloc] init];
        MultiplayerRoom *roomToRemove = nil;

        for (MultiplayerRoom *room in self.internalRooms) {
            if ([room.roomId isEqualToString:roomId]) {
                roomToRemove = room;
            } else {
                [roomsToKeep addObject:room];
            }
        }

        if (!roomToRemove) {
            NSLog(@"[MultiplayerManager] removeRoom: roomId not found: %@", roomId);
            return;
        }

        self.internalRooms = roomsToKeep;

        // 检查是否需要断开当前连接（在 _stateLock 内读取 currentRoom）
        [_stateLock lock];
        needsDisconnect = (self.currentRoom != nil &&
                           [self.currentRoom.roomId isEqualToString:roomId]);
        [_stateLock unlock];
    }

    // 在锁外断开当前连接（避免长时间持锁）
    if (needsDisconnect) {
        NSLog(@"[MultiplayerManager] Removing currently connected room, disconnecting first");
        [self disconnectCurrentRoom];
    }

    NSLog(@"[MultiplayerManager] Room deleted: %@", roomId);
    [self saveRooms];
}

- (void)updateRoom:(MultiplayerRoom *)room {
    if (!room || !room.roomId || room.roomId.length == 0) {
        NSLog(@"[MultiplayerManager] updateRoom: room or roomId is nil");
        return;
    }

    // 关键修复（M3）：currentRoom 的读写必须通过 _stateLock 保护，
    // 不能与 @synchronized(self) 混用。
    // 之前在 @synchronized(self) 内直接读写 self.currentRoom，但 currentRoom
    // 在其他所有位置（connectToRoom、disconnectCurrentRoom、connectToRoomFlow 等）
    // 都通过 _stateLock 保护。两套锁机制混用导致：
    //   - 后台线程通过 @synchronized 写入 currentRoom
    //   - 主线程通过 _stateLock 读取 currentRoom
    //   - 两者无共同的内存屏障，可能导致主线程读到旧值
    //
    // 修复方案：在 @synchronized 内只更新 internalRooms，
    // currentRoom 的读写单独通过 _stateLock 保护。

    @synchronized(self) {
        BOOL found = NO;
        NSMutableArray *updatedRooms = [[NSMutableArray alloc] init];

        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                [updatedRooms addObject:room];
                found = YES;
            } else {
                [updatedRooms addObject:existing];
            }
        }

        if (!found) {
            NSLog(@"[MultiplayerManager] updateRoom: roomId not found: %@", room.roomId);
            return;
        }

        self.internalRooms = updatedRooms;
        [self sortRoomsByCreatedAt];
    }

    // 在 _stateLock 内同步更新 currentRoom 引用
    [_stateLock lock];
    if (self.currentRoom && [self.currentRoom.roomId isEqualToString:room.roomId]) {
        self.currentRoom = room;
    }
    [_stateLock unlock];

    NSLog(@"[MultiplayerManager] Room updated: %@ (%@)", room.name, room.roomId);
    [self saveRooms];
}

- (nullable MultiplayerRoom *)roomWithId:(NSString *)roomId {
    if (!roomId || roomId.length == 0) {
        return nil;
    }

    @synchronized(self) {
        for (MultiplayerRoom *room in self.internalRooms) {
            if ([room.roomId isEqualToString:roomId]) {
                return room;
            }
        }
    }
    return nil;
}

- (void)sortRoomsByCreatedAt {
    [self.internalRooms sortUsingComparator:^NSComparisonResult(MultiplayerRoom *room1, MultiplayerRoom *room2) {
        NSDate *date1 = room1.createdAt;
        NSDate *date2 = room2.createdAt;

        if (!date1 && !date2) return NSOrderedSame;
        if (!date1) return NSOrderedAscending;
        if (!date2) return NSOrderedDescending;

        NSComparisonResult result = [date2 compare:date1];
        if (result == NSOrderedSame) {
            return [room1.roomId compare:room2.roomId];
        }
        return result;
    }];
}

#pragma mark - 连接管理

- (void)connectToRoom:(MultiplayerRoom *)room
           completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    if (!room) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidRoom
                                              userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_610", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    if (!room.networkId || room.networkId.length == 0) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeInvalidNetworkId
                                              userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_611", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    // 检测 framework 可用性
    if (![[ZeroTierBridge sharedInstance] isFrameworkAvailable]) {
        NSLog(@"[MultiplayerManager] zt.framework unavailable, cannot connect to room");
        room.status = MultiplayerRoomStatusError;
        [self updateRoom:room];
        if (completion) {
            NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                                  code:MultiplayerErrorCodeFrameworkUnavailable
                                              userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_612", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, error);
            });
        }
        return;
    }

    NSLog(@"[MultiplayerManager] Starting connection to room: %@ (Network ID: %@)", room.name, room.networkId);

    // 1. 设置当前房间并更新状态为连接中
    //
    // 关键修复（严重1）：room.status 的修改必须在 _stateLock 内完成，
    // 与 currentRoom 的赋值保持原子性。之前在锁外修改 room.status，
    // 如果 disconnectCurrentRoom 并发执行，会出现：
    //   - connectToRoom 设置 currentRoom = room（持锁）
    //   - disconnectCurrentRoom 读到 currentRoom = room（持锁）
    //   - connectToRoom 写 room.status = Connecting（已释放锁）
    //   - disconnectCurrentRoom 写 room.status = Disconnected（已释放锁，覆盖）
    //   - 最终 status 与实际状态不符
    [_stateLock lock];
    // 关键修复（connectionCancelled 重置竞态）：
    // 在持 _stateLock 期间重置 connectionCancelled = NO。
    // 此时 currentRoom 尚未设置（下一行才设置），disconnectCurrentRoom 即使能拿到锁，
    // 也会因为 currentRoom == nil 而提前 return，不会设置 YES。
    // 这保证了"重置取消标志"与"设置 currentRoom"在锁内原子完成，
    // 避免了之前在 connectToRoomFlow 后台线程重置导致取消信号被覆盖的竞态。
    self.connectionCancelled = NO;
    self.currentRoom = room;
    self.currentNetworkID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
    room.status = MultiplayerRoomStatusConnecting;
    room.lastConnectedAt = [NSDate date];
    [_stateLock unlock];

    // 关键修复：如果房间不在列表中，先添加到列表，否则后续 updateRoom 都会因找不到 roomId 而失败
    if (![self roomWithId:room.roomId]) {
        NSLog(@"[MultiplayerManager] Room not in list, adding first: %@", room.roomId);
        [self addRoom:room];
    }
    [self updateRoom:room];

    // 2. 完整连接流程（在后台线程执行，避免阻塞主线程）
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self connectToRoomFlow:room completion:^(BOOL success, NSError * _Nullable error) {
            if (success) {
                NSLog(@"[MultiplayerManager] Room connection succeeded: %@", room.name);
                room.status = MultiplayerRoomStatusConnected;
            } else {
                NSLog(@"[MultiplayerManager] Room connection failed: %@ - %@", room.name, error.localizedDescription);
                room.status = MultiplayerRoomStatusError;

                // 关键修复（M4）：连接失败时清空 currentRoom/currentNetworkID 等状态引用。
                // 之前只更新了 room.status 但未清空 manager 持有的 currentRoom 引用，
                // 导致：
                //   - self.currentRoom 仍指向失败房间，UI 显示错误的"当前连接"
                //   - _currentNetworkID 仍匹配该网络，导致后续 zeroTierNetworkReady: 回调
                //     仍会匹配并更新已放弃连接的状态
                //   - 重试连接同一房间时状态不一致
                //
                // 修复方案：在 _stateLock 内检查 currentRoom 是否仍是同一个 room，
                // 只有当 currentRoom 仍是 room 时才清空（避免清空用户已切换到的新房间）。
                [self->_stateLock lock];
                if (self.currentRoom && [self.currentRoom.roomId isEqualToString:room.roomId]) {
                    self.currentRoom = nil;
                    self.currentNetworkID = 0;
                    self.currentLocalIP = nil;
                    self.currentSOCKS5Port = 0;
                    self.currentForwardingPort = 0;
                    NSLog(@"[MultiplayerManager] Connection failed, cleared currentRoom state reference");
                } else {
                    NSLog(@"[MultiplayerManager] Connection failed but currentRoom changed (user may have switched rooms), not clearing state");
                }
                [self->_stateLock unlock];
            }
            [self updateRoom:room];

            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(success, error);
                });
            }
        }];
    });
}

/// 通知 delegate 连接流程进度
///
/// 在 connectToRoomFlow: 的各个步骤中调用，让 UI 能实时显示当前进度。
/// 通过 dispatch_async 到主线程调用，确保线程安全。
///
/// @param message 进度描述文本
- (void)notifyConnectionProgress:(NSString *)message {
    if ([self.delegate respondsToSelector:@selector(multiplayerConnectionProgress:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerConnectionProgress:message];
        });
    }
}

/// 房间连接的完整流程（在后台线程执行）
///
/// 6 步流程（参照 spec）：
///   1. 启动 ZeroTier 节点（如果尚未启动）
///   2. 等待节点上线
///   3. 加入 ZeroTier 网络
///   4. 等待网络就绪（IPv4 或 Ad-hoc IPv6 已分配）
///   5. 启动本地 SOCKS5 代理
///   6. 设置 AMETHYST_SOCKS5_PROXY 环境变量 + 端口转发器（仅房客模式启动）
///
/// 简化说明（参照 spec）：
///   - 移除 M5 的"步骤间检查 currentRoom 是否变更"过度防御逻辑，
///     由 disconnectCurrentRoom 显式取消流程即可。
///   - 房主模式不启动 PortForwarder，等待 UI 层调用
///     startHostPortForwarderWithListenPort:localHostPort: 启动房主模式。
- (void)connectToRoomFlow:(MultiplayerRoom *)room
               completion:(void (^)(BOOL success, NSError * _Nullable error))completion {
    // 性能诊断：记录连接流程总耗时与每步耗时，便于优化和问题定位
    CFAbsoluteTime flowStartTime = CFAbsoluteTimeGetCurrent();
    CFAbsoluteTime stepStartTime = flowStartTime;
#define MP_LOG_STEP_TIME(stepName) do { \
    CFAbsoluteTime _now = CFAbsoluteTimeGetCurrent(); \
    NSLog(@"[MultiplayerManager] [ConnectFlow] [Timing] %@ took %.2fs (cumulative %.2fs)", \
          (stepName), _now - stepStartTime, _now - flowStartTime); \
    stepStartTime = _now; \
} while(0)

    // SubTask 4.2：取消标志已在 connectToRoom: 主线程持锁阶段重置（见下方 connectToRoom:）。
    // 这里不再重置——避免与 disconnectCurrentRoom 设置 YES 的竞态：
    //   - 之前在此处重置：dispatch_async 调度到后台线程开始执行的窗口内，
    //     若 disconnectCurrentRoom 设置了 YES，会被本行立即覆盖为 NO，导致取消信号丢失。
    //   - 现在重置点在 connectToRoom: 设置 currentRoom 之前（主线程持 _stateLock 期间），
    //     disconnectCurrentRoom 必须先获取 _stateLock 才能读到 currentRoom 并触发取消，
    //     因此重置与可能的取消设置不会重叠。

    // 步骤 1 前增加取消检查（与步骤 2/3/4/5 保持一致），
    // 防止 dispatch_async 调度期间用户已显式取消时仍启动节点
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 1, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_613", nil)}]);
        }
        return;
    }

    // 步骤 1：启动节点
    //
    // 直接调用 ZeroTierBridge 的 startNodeWithHomeDirectory:error: 同步 API，
    // 避免经过 main_queue 分发（connectToRoomFlow 已在后台 utility queue 执行）。
    // framework 可用性检查在 connectToRoom 入口已做，此处不再重复。
    if (![self isNodeStarted]) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Step 1: Starting ZeroTier node");
        [self notifyConnectionProgress:localize(@"i18n_str_614", nil)];
        NSString *homeDir = [self zeroTierHomeDirectory];
        NSError *startError = nil;
        BOOL nodeStartSuccess = [[ZeroTierBridge sharedInstance] startNodeWithHomeDirectory:homeDir
                                                                                     error:&startError];
        if (nodeStartSuccess) {
            [_stateLock lock];
            _nodeStarted = YES;
            [_stateLock unlock];
            NSLog(@"[MultiplayerManager] [ConnectFlow] ZeroTier node start request submitted, waiting for online...");
        } else {
            NSLog(@"[MultiplayerManager] [ConnectFlow] ZeroTier node start failed: %@", startError.localizedDescription);
            if (completion) {
                completion(NO, startError ?: [NSError errorWithDomain:kMultiplayerErrorDomain
                                                                   code:MultiplayerErrorCodeNodeStartFailed
                                                               userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_604", nil)}]);
            }
            return;
        }
    } else {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Step 1: Node already started, skipping");
    }
    MP_LOG_STEP_TIME(@"Step 1: Start node");

    // 步骤 2：等待节点上线
    // SubTask 4.2：检查取消标志
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 2, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_613", nil)}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 2: Waiting for node online (timeout %.0fs)", kNodeOnlineTimeout);
    [self notifyConnectionProgress:localize(@"i18n_str_615", nil)];
    if (![[ZeroTierBridge sharedInstance] isNodeOnline]) {
        BOOL online = [[ZeroTierBridge sharedInstance] waitForNodeOnlineWithTimeout:kNodeOnlineTimeout];
        if (!online) {
            if (completion) {
                completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                    code:MultiplayerErrorCodeNodeOnlineTimeout
                                                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_616", nil), kNodeOnlineTimeout]}]);
            }
            return;
        }
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Node is online");
    MP_LOG_STEP_TIME(@"Step 2: Wait for node online");

    // 步骤 3：加入网络
    // SubTask 4.2：检查取消标志
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 3, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_613", nil)}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 3: Joining ZeroTier network %@", room.networkId);
    [self notifyConnectionProgress:[NSString stringWithFormat:localize(@"i18n_str_617", nil), room.networkId]];
    uint64_t netID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
    if (netID == 0) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeInvalidNetworkId
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_607", nil)}]);
        }
        return;
    }

    NSError *joinError = nil;
    if (![[ZeroTierBridge sharedInstance] joinNetwork:netID error:&joinError]) {
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeJoinNetworkFailed
                                            userInfo:@{NSLocalizedDescriptionKey: joinError.localizedDescription ?: localize(@"i18n_str_608", nil)}]);
        }
        return;
    }
    MP_LOG_STEP_TIME(@"Step 3: Join network");

    // 步骤 4：等待网络就绪
    //
    // Private 网络中未授权的节点加入时，ZeroTier 控制器会忽略该节点（不分配 IP），
    // 但可能不立即发送 ACCESS_DENIED 事件。启动一个 8 秒后的后台定时器，
    // 检查网络状态：如果已 OK 但没有 IP，说明节点未授权，发送提示进度。
    // SubTask 4.2：检查取消标志
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 4, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_613", nil)}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 4: Waiting for network ready (timeout %.0fs)", kNetworkReadyTimeout);
    [self notifyConnectionProgress:localize(@"i18n_str_618", nil)];

    // 8 秒后检查是否需要授权提示
    // SubTask 5.7：如果 8 秒内未分配到 IP，显示房客自己的 ZeroTier 节点 ID 供房主查找
    __block BOOL step4Done = NO;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (step4Done) return;
        // 关键修复：8 秒检查块必须响应取消，否则用户已断开后仍会收到
        // "你的节点可能未被授权" 等误导性进度提示
        if (weakSelf.connectionCancelled) {
            NSLog(@"[MultiplayerManager] [ConnectFlow] 8s check: cancellation detected, skipping");
            return;
        }
        ZeroTierNetworkStatus status = [[ZeroTierBridge sharedInstance] networkStatus:netID];
        NSString *ipv4 = [[ZeroTierBridge sharedInstance] ipv4AddressForNetwork:netID];
        NSString *ipv6 = [[ZeroTierBridge sharedInstance] ipv6AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [ConnectFlow] 8s check: status=%ld, ipv4=%@, ipv6=%@",
              (long)status, ipv4, ipv6);
        if (status == ZeroTierNetworkStatusOk && !ipv4.length && !ipv6.length) {
            // 已加入网络但没有 IP = Private 网络未授权
            // 显示房客自己的 ZeroTier 节点 ID，方便房主在 central.zerotier.com 后台查找并授权
            uint64_t myNodeID = [[ZeroTierBridge sharedInstance] nodeID];
            NSString *nodeIDStr = (myNodeID != 0) ? [ZeroTierBridge formatNetworkID:myNodeID] : localize(@"i18n_str_619", nil);
            [weakSelf notifyConnectionProgress:[NSString stringWithFormat:localize(@"i18n_str_620", nil), nodeIDStr]];
        } else if (status == ZeroTierNetworkStatusUnknown || status == ZeroTierNetworkStatusRequestingConfig) {
            // 仍在请求加入网络
            [weakSelf notifyConnectionProgress:localize(@"i18n_str_621", nil)];
        }
    });

    BOOL ready = [[ZeroTierBridge sharedInstance] waitForNetworkReady:netID
                                                              timeout:kNetworkReadyTimeout];
    step4Done = YES;

    if (!ready) {
        // 网络就绪等待失败时，离开已加入的网络，避免资源泄漏。
        NSLog(@"[MultiplayerManager] [ConnectFlow] Network ready wait failed, cleaning up joined network %@", room.networkId);
        [[ZeroTierBridge sharedInstance] leaveNetwork:netID];

        // 检查网络状态，给出更精确的错误信息
        // SubTask 5.6 + 5.7：房客流程错误细化，在未授权场景下显示房客自己的 ZeroTier 节点 ID 供房主查找
        ZeroTierNetworkStatus failStatus = [[ZeroTierBridge sharedInstance] networkStatus:netID];
        // 获取房客自己的 ZeroTier 节点 ID（用于未授权场景提示房主查找）
        uint64_t myNodeID = [[ZeroTierBridge sharedInstance] nodeID];
        NSString *myNodeIDStr = (myNodeID != 0) ? [ZeroTierBridge formatNetworkID:myNodeID] : nil;
        NSString *failDesc = nil;
        if (failStatus == ZeroTierNetworkStatusAccessDenied) {
            failDesc = myNodeIDStr
                ? [NSString stringWithFormat:localize(@"i18n_str_622", nil), myNodeIDStr]
                : localize(@"i18n_str_623", nil);
        } else if (failStatus == ZeroTierNetworkStatusNotFound) {
            failDesc = localize(@"i18n_str_624", nil);
        } else if (failStatus == ZeroTierNetworkStatusClientTooOld) {
            failDesc = localize(@"i18n_str_625", nil);
        } else if (failStatus == ZeroTierNetworkStatusDown) {
            failDesc = localize(@"i18n_str_626", nil);
        } else if (failStatus == ZeroTierNetworkStatusOk) {
            failDesc = myNodeIDStr
                ? [NSString stringWithFormat:localize(@"i18n_str_627", nil), myNodeIDStr]
                : localize(@"i18n_str_628", nil);
        } else {
            failDesc = [NSString stringWithFormat:localize(@"i18n_str_629", nil), kNetworkReadyTimeout];
        }

        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeNetworkReadyTimeout
                                            userInfo:@{NSLocalizedDescriptionKey: failDesc}]);
        }
        return;
    }

    // 获取分配的 IP 地址
    // 标准模式：获取 IPv4 地址
    // Ad-hoc 模式（快速模式）：只有 IPv6 地址，需要特殊处理
    NSString *localIP = nil;
    BOOL isAdhoc = [self isAdhocNetworkId:room.networkId];
    if (isAdhoc) {
        // Ad-hoc 网络只有 IPv6 地址
        localIP = [[ZeroTierBridge sharedInstance] ipv6AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [ConnectFlow] Ad-hoc mode, local ZeroTier IPv6: %@", localIP ?: @"(not assigned)");
    } else {
        // 标准模式：获取 IPv4 地址
        localIP = [[ZeroTierBridge sharedInstance] ipv4AddressForNetwork:netID];
        NSLog(@"[MultiplayerManager] [ConnectFlow] Standard mode, local ZeroTier IPv4: %@", localIP ?: @"(not assigned)");
    }

    // 如果获取不到本地 IP，说明网络虽就绪但 IP 分配异常，
    // 此时也应清理已加入的网络，避免后续重连时状态混乱。
    if (!localIP || localIP.length == 0) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cannot obtain local ZeroTier IP, cleaning up joined network %@", room.networkId);
        [[ZeroTierBridge sharedInstance] leaveNetwork:netID];

        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeNetworkReadyTimeout
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_630", nil)}]);
        }
        return;
    }
    MP_LOG_STEP_TIME(@"Step 4: Wait for network ready");

    // 同步本机 ZeroTier IP 到 currentLocalIP，并在房主模式下同步到 room.hostIP
    //
    // 房主与房客区分（关键修复：替代 IP 启发式）：
    //   - 优先使用 room.role：role == Host 即为房主
    //   - role == Unknown 时回退到 IP 启发式以保持兼容：
    //     - 房主首次连接：room.hostIP 为空 → 需要填充本机 IP 用于分享
    //     - 房主重连（IP 不变）：room.hostIP == 本机 IP → 无变化，允许同步
    //     - 房客连接：room.hostIP == 房主 IP（来自分享代码）≠ 本机 IP → 不覆盖
    [_stateLock lock];
    self.currentLocalIP = localIP;
    if (localIP.length > 0 && self.currentRoom) {
        NSString *existingHostIP = self.currentRoom.hostIP;
        MultiplayerRoomRole currentRole = self.currentRoom.role;
        BOOL isHostByRole = (currentRole == MultiplayerRoomRoleHost);
        BOOL isHostByIPFallback = (currentRole == MultiplayerRoomRoleUnknown &&
                                   (existingHostIP.length == 0 || [existingHostIP isEqualToString:localIP]));
        BOOL isHost = isHostByRole || isHostByIPFallback;
        if (isHost) {
            self.currentRoom.hostIP = localIP;
            // 房主首次设置时，确保 role 被标记为 Host（兼容旧路径）
            if (currentRole == MultiplayerRoomRoleUnknown) {
                self.currentRoom.role = MultiplayerRoomRoleHost;
            }
            NSLog(@"[MultiplayerManager] [ConnectFlow] Synced host ZeroTier IP to room %@ (role=%ld): %@",
                  self.currentRoom.name, (long)self.currentRoom.role, localIP);
        } else {
            // 房客：保留分享代码中的房主 IP，不覆盖
            NSLog(@"[MultiplayerManager] [ConnectFlow] Guest mode (role=%ld): keeping host IP %@, not using local IP %@",
                  (long)currentRole, existingHostIP, localIP);
        }
    }
    MultiplayerRoom *roomForIPUpdate = self.currentRoom;
    [_stateLock unlock];

    // 同步房主 IP 到房间列表
    if (roomForIPUpdate && localIP.length > 0) {
        [self updateRoom:roomForIPUpdate];
    }

    // 步骤 5：启动 SOCKS5 代理
    // SubTask 4.2：检查取消标志
    if (self.connectionCancelled) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cancelled before step 5, exiting");
        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeRoomNotFound
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_613", nil)}]);
        }
        return;
    }
    NSLog(@"[MultiplayerManager] [ConnectFlow] Step 5: Starting SOCKS5 proxy");
    [self notifyConnectionProgress:localize(@"i18n_str_631", nil)];
    NSError *proxyError = nil;
    BOOL proxyStarted = [[SOCKS5Proxy sharedProxy] startWithPort:kMultiplayerDefaultSOCKS5Port
                                                            error:&proxyError];
    if (!proxyStarted) {
        NSLog(@"[MultiplayerManager] [ConnectFlow] SOCKS5 proxy start failed: %@", proxyError.localizedDescription);
        // SOCKS5 代理启动失败时，同样需要离开已加入的网络，
        // 否则下一次连接尝试会因为节点已加入网络而出现状态不一致。
        NSLog(@"[MultiplayerManager] [ConnectFlow] Cleaning up joined network %@", room.networkId);
        [[ZeroTierBridge sharedInstance] leaveNetwork:netID];

        if (completion) {
            completion(NO, [NSError errorWithDomain:kMultiplayerErrorDomain
                                                code:MultiplayerErrorCodeSOCKS5ProxyStartFailed
                                            userInfo:@{NSLocalizedDescriptionKey: proxyError.localizedDescription ?: localize(@"i18n_str_632", nil)}]);
        }
        return;
    }

    uint16_t actualPort = [[SOCKS5Proxy sharedProxy] listeningPort];

    [_stateLock lock];
    self.currentSOCKS5Port = actualPort;
    [_stateLock unlock];

    NSLog(@"[MultiplayerManager] [ConnectFlow] SOCKS5 proxy started, listening on 127.0.0.1:%u", actualPort);
    MP_LOG_STEP_TIME(@"Step 5: Start SOCKS5 proxy");

    // 步骤 6：设置环境变量 + 启动端口转发器（仅房客模式）
    //
    // 端口转发器说明：
    //   SOCKS5 代理只对 java.net.Socket 有效（登录认证等），但 MC 的多人游戏连接
    //   使用 Netty 的 NioSocketChannel（基于 java.nio.channels.SocketChannel），
    //   不走 Java 的 SOCKS5 代理。因此需要额外启动一个本地端口转发器：
    //     - 房客模式：在 127.0.0.1:25565（或下一个可用端口）监听 TCP，
    //       通过 libzt socket 转发到房主的 ZeroTier IP:MC LAN 端口。
    //       房客在 MC 中输入 127.0.0.1:25565 即可连接。
    //     - 房主模式：不在此处启动，等待 UI 层调用
    //       startHostPortForwarderWithListenPort:localHostPort: 启动房主模式
    //       （ZeroTier 网络监听 25565 → 转发到本地 MC LAN 端口）。
    [self notifyConnectionProgress:localize(@"i18n_str_633", nil)];
    NSString *proxyValue = [NSString stringWithFormat:@"127.0.0.1:%u", actualPort];
    setenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String], [proxyValue UTF8String], 1);
    NSLog(@"[MultiplayerManager] [ConnectFlow] Set environment variable %@=%@", kAMETHYSTSOCKS5ProxyEnvVar, proxyValue);

    // 仅当房间有 hostIP 和 hostPort 时启动房客模式端口转发器
    // 房主模式（hostIP 为空或为本机 IP）不启动，等待 UI 层调用房主模式 API
    //
    // 关键修复（替代 IP 启发式）：
    // 优先使用 room.role 判断房客身份；若 role == Unknown（旧数据/异常路径），
    // 回退到 IP 启发式以保持兼容。这样消除了"hostIP 与 localIP 恰好相同"导致
    // 房客被误判为房主、PortForwarder 不启动、MC 无法连接的脆弱场景。
    NSString *hostIP = room.hostIP;
    NSString *hostPortStr = room.hostPort;
    MultiplayerRoomRole role = room.role;
    BOOL isGuestByRole = (role == MultiplayerRoomRoleGuest);
    BOOL isGuestByIPFallback = (role == MultiplayerRoomRoleUnknown &&
                                hostIP.length > 0 &&
                                hostPortStr.length > 0 &&
                                localIP.length > 0 &&
                                ![hostIP isEqualToString:localIP]);
    BOOL isGuestMode = isGuestByRole || isGuestByIPFallback;
    if (isGuestMode && hostIP.length > 0 && hostPortStr.length > 0) {
        uint16_t hostPort = (uint16_t)[hostPortStr integerValue];
        if (hostPort > 0) {
            NSLog(@"[MultiplayerManager] [ConnectFlow] Guest mode (role=%ld): starting port forwarder 127.0.0.1:%u -> %@:%u",
                  (long)role, PortForwarderDefaultLocalPort, hostIP, hostPort);

            BOOL forwardStarted = [[PortForwarder sharedForwarder] startGuestModeWithLocalPort:PortForwarderDefaultLocalPort
                                                                                         hostIP:hostIP
                                                                                       hostPort:hostPort];
            if (forwardStarted) {
                uint16_t forwardPort = [[PortForwarder sharedForwarder] listeningPort];
                NSLog(@"[MultiplayerManager] [ConnectFlow] Port forwarder started: 127.0.0.1:%u -> %@:%u",
                      forwardPort, hostIP, hostPort);

                [_stateLock lock];
                self.currentForwardingPort = forwardPort;
                [_stateLock unlock];
            } else {
                NSLog(@"[MultiplayerManager] [ConnectFlow] Port forwarder start failed (SOCKS5 proxy unaffected)");
                // 端口转发器失败不中断整个连接流程（SOCKS5 代理仍然有效）
            }
        } else {
            NSLog(@"[MultiplayerManager] [ConnectFlow] Host port invalid: %@, skipping port forward", hostPortStr);
        }
    } else {
        NSLog(@"[MultiplayerManager] [ConnectFlow] Host mode (role=%ld): skipping guest port forward, waiting for UI to call startHostPortForwarderWithListenPort:localHostPort:",
              (long)role);
    }
    MP_LOG_STEP_TIME(@"Step 6: Env vars + port forward");
    NSLog(@"[MultiplayerManager] [ConnectFlow] Connect flow completed, total time %.2fs", CFAbsoluteTimeGetCurrent() - flowStartTime);

    if (completion) {
        completion(YES, nil);
    }
#undef MP_LOG_STEP_TIME
}

- (void)disconnectCurrentRoom {
    // SubTask 4.2：设置取消标志，通知正在执行的 connectToRoomFlow 停止后续步骤
    // 这与 M5 的"检查 currentRoom 是否变更"不同——本标志仅在显式断开时设置
    self.connectionCancelled = YES;

    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    NSString *networkId = room.networkId;
    [_stateLock unlock];

    if (!room) {
        NSLog(@"[MultiplayerManager] disconnectCurrentRoom: No current room connected");
        return;
    }

    NSLog(@"[MultiplayerManager] Disconnecting room: %@ (Network ID: %@)", room.name, networkId);

    // 1. 停止 SOCKS5 代理
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }

    // 1.5 停止端口转发器（房主模式或房客模式）
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping port forwarder (mode=%ld)", (long)[[PortForwarder sharedForwarder] mode]);
        [[PortForwarder sharedForwarder] stop];
    }

    [_stateLock lock];
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    self.currentLocalIP = nil;
    [_stateLock unlock];

    // 2. 清除环境变量
    unsetenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String]);
    NSLog(@"[MultiplayerManager] Cleared environment variable %@", kAMETHYSTSOCKS5ProxyEnvVar);

    // 3. 离开 ZeroTier 网络
    // 关键修复：检查 leaveNetwork 返回值，失败时强制 stopNode 彻底清理。
    // 之前不检查返回值，若 leaveNetwork 失败（libzt 内部错误、节点异常等），
    // 节点实际仍在网络中，但 Manager 状态已清空，后续重连同一网络可能出现状态不一致。
    // 现在失败时强制 stopNode 重置整个节点状态，确保下次连接从干净状态开始。
    if (networkId && networkId.length > 0) {
        BOOL leaveSuccess = [self leaveNetwork:networkId];
        if (!leaveSuccess) {
            NSLog(@"[MultiplayerManager] disconnectCurrentRoom: leaveNetwork failed, forcing stopNode for full cleanup");
            [[ZeroTierBridge sharedInstance] stopNode];
            [_stateLock lock];
            _nodeStarted = NO;
            [_stateLock unlock];
        }
    }

    // 4. 更新房间状态为已断开
    room.status = MultiplayerRoomStatusDisconnected;

    @synchronized(self) {
        for (MultiplayerRoom *existing in self.internalRooms) {
            if ([existing.roomId isEqualToString:room.roomId]) {
                existing.status = MultiplayerRoomStatusDisconnected;
                break;
            }
        }
    }

    // 5. 清空当前房间引用
    [_stateLock lock];
    self.currentRoom = nil;
    self.currentNetworkID = 0;
    [_stateLock unlock];

    // 6. 持久化
    [self saveRooms];

    // 7. 关键修复（P0-A）：清除 PLProfiles 中残留的 serverIp
    // 问题：connectToRoomFlow 会在连接成功后把房主 IP:port 写入 profile 的 serverIp
    // 字段（下次启动 MC 时自动连接）。但断开联机后若不清空，下次启动 MC 仍会
    // 尝试连接旧服务器——此时 SOCKS5 代理未运行、ZeroTier 未加入，连接会失败，
    // 但 MC 仍会显示"正在连接服务器"界面，造成"进游戏必显示连接服务器"的 bug。
    // 修复：断开联机时同步清空当前 profile 的 serverIp。
    @try {
        NSString *currentProfile = [[PLProfiles current] selectedProfileName];
        if (currentProfile.length > 0) {
            [[PLProfiles current] setServerIp:@"" forProfile:currentProfile];
            NSLog(@"[MultiplayerManager] Cleared serverIp for profile '%@'", currentProfile);
        }
    } @catch (NSException *e) {
        NSLog(@"[MultiplayerManager] Failed to clear serverIp: %@", e);
    }

    NSLog(@"[MultiplayerManager] Room disconnected");
}

#pragma mark - ZeroTierBridgeDelegate

- (void)zeroTierNodeOnlineWithID:(uint64_t)nodeID {
    NSLog(@"[MultiplayerManager] ZeroTier node went online, nodeID = %llu", nodeID);
    if ([self.delegate respondsToSelector:@selector(multiplayerNodeOnline)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerNodeOnline];
        });
    }
}

/// 节点掉线恢复后数据平面（SOCKS5Proxy + PortForwarder）不重启的修复。
///
/// 背景：zeroTierNodeOffline 会主动停止 SOCKS5/PortForwarder 以释放资源，
/// 但当节点恢复上线时，原实现只更新 currentLocalIP，不重启数据平面。导致：
///   - UI 仍显示"已连接"
///   - 但 Minecraft 流量无代理可用，连接立即断开
///   - 用户必须手动断开房间再重新连接
///
/// 本方法在 zeroTierNetworkReady: 和 applicationWillEnterForeground 中被调用，
/// 仅当当前房间有 currentRoom 且代理未运行时重启。
/// 首次连接时数据平面已由 connectToRoomFlow 启动，此方法不会重复启动（避免端口冲突）。
///
/// 房主模式的 PortForwarder 不在此处自动恢复（需要 MC LAN 端口，由 UI 层调用
/// startHostPortForwarderWithListenPort:localHostPort: 重新启动）。
- (void)ensureDataPlaneRunningForCurrentRoom {
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    NSString *hostIP = room.hostIP;
    NSString *hostPortStr = room.hostPort;
    NSString *localIP = self.currentLocalIP;
    uint16_t savedSocksPort = _currentSOCKS5Port;
    uint16_t savedForwardPort = _currentForwardingPort;
    uint64_t currentNetID = _currentNetworkID;
    [_stateLock unlock];

    // 没有当前房间或没有正在连接的网络，无需重启数据平面
    if (!room || currentNetID == 0) {
        return;
    }

    // SOCKS5 代理重启（仅在未运行时）
    if (![[SOCKS5Proxy sharedProxy] isRunning] || savedSocksPort == 0) {
        NSLog(@"[MultiplayerManager] [Data plane recovery] Restarting SOCKS5 proxy (room: %@)", room.name);
        NSError *proxyError = nil;
        BOOL proxyStarted = [[SOCKS5Proxy sharedProxy] startWithPort:kMultiplayerDefaultSOCKS5Port
                                                                error:&proxyError];
        if (proxyStarted) {
            uint16_t actualPort = [[SOCKS5Proxy sharedProxy] listeningPort];
            [_stateLock lock];
            self.currentSOCKS5Port = actualPort;
            [_stateLock unlock];
            NSString *proxyValue = [NSString stringWithFormat:@"127.0.0.1:%u", actualPort];
            setenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String], [proxyValue UTF8String], 1);
            NSLog(@"[MultiplayerManager] [Data plane recovery] SOCKS5 proxy restarted, listening on 127.0.0.1:%u", actualPort);
        } else {
            NSLog(@"[MultiplayerManager] [Data plane recovery] SOCKS5 proxy restart failed: %@",
                  proxyError.localizedDescription ?: @"Unknown error");
        }
    }

    // PortForwarder 房客模式重启（仅在未运行且为房客模式时）
    // 房客模式判断：
    //   - 优先使用 room.role == Guest
    //   - role == Unknown 时回退到 IP 启发式（hostIP 不为空、hostPort 有效、hostIP 不等于本机 IP）
    // 房主模式的 PortForwarder 不自动恢复（需要 MC LAN 端口，由 UI 层重新启动）
    MultiplayerRoomRole role = room.role;
    BOOL isGuestByRole = (role == MultiplayerRoomRoleGuest);
    BOOL isGuestByIPFallback = (role == MultiplayerRoomRoleUnknown &&
                                hostIP.length > 0 &&
                                hostPortStr.length > 0 &&
                                localIP.length > 0 &&
                                ![hostIP isEqualToString:localIP]);
    BOOL isGuestMode = isGuestByRole || isGuestByIPFallback;
    if (isGuestMode &&
        (![[PortForwarder sharedForwarder] isRunning] || savedForwardPort == 0)) {
        uint16_t hostPort = (uint16_t)[hostPortStr integerValue];
        if (hostPort > 0) {
            NSLog(@"[MultiplayerManager] [Data plane recovery] Restarting port forwarder (guest mode): 127.0.0.1:%u → %@:%u",
                  PortForwarderDefaultLocalPort, hostIP, hostPort);
            BOOL forwardStarted = [[PortForwarder sharedForwarder] startGuestModeWithLocalPort:PortForwarderDefaultLocalPort
                                                                                         hostIP:hostIP
                                                                                       hostPort:hostPort];
            if (forwardStarted) {
                uint16_t forwardPort = [[PortForwarder sharedForwarder] listeningPort];
                [_stateLock lock];
                self.currentForwardingPort = forwardPort;
                [_stateLock unlock];
                NSLog(@"[MultiplayerManager] [Data plane recovery] Port forwarder restarted: 127.0.0.1:%u → %@:%u",
                      forwardPort, hostIP, hostPort);
            } else {
                NSLog(@"[MultiplayerManager] [Data plane recovery] Port forwarder restart failed");
            }
        }
    }
}

- (void)zeroTierNodeOffline {
    NSLog(@"[MultiplayerManager] ZeroTier node went offline");

    // 关键稳定性优化：节点离线时，PortForwarder 和 SOCKS5Proxy 已无法转发数据，
    // 应该立即停止它们，避免房客在 MC 中看到"连接中"长时间卡住。
    // 不调用 disconnectCurrentRoom（会清空 currentRoom），仅停止代理和转发器。
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Node offline, stopping port forwarder");
        [[PortForwarder sharedForwarder] stop];
    }
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Node offline, stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }

    [_stateLock lock];
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    [_stateLock unlock];

    if ([self.delegate respondsToSelector:@selector(multiplayerNodeOffline)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.delegate multiplayerNodeOffline];
        });
    }
}

- (void)zeroTierNodeDown {
    NSLog(@"[MultiplayerManager] ZeroTier node shut down (zts_node_stop complete)");

    [_stateLock lock];
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    self.currentLocalIP = nil;
    _nodeStarted = NO;
    [_stateLock unlock];

    // 节点已关闭，停止数据平面
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Node shut down, stopping port forwarder");
        [[PortForwarder sharedForwarder] stop];
    }
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Node shut down, stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }
    unsetenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String]);
}

- (void)zeroTierNetworkReady:(uint64_t)networkID
                        ipv4:(NSString *)ipv4
                        ipv6:(NSString *)ipv6 {
    NSLog(@"[MultiplayerManager] ZeroTier network ready: networkID=%llu ipv4=%@ ipv6=%@",
          networkID, ipv4 ?: @"(nil)", ipv6 ?: @"(nil)");

    // 关键修复（N8）：将 currentRoom 读取、isAdhoc 判断、effectiveIP 计算全部移入 _stateLock 内。
    //
    // 问题：之前在锁外读取 self.currentRoom，然后计算 isAdhoc 和 effectiveIP，
    // 再进入锁内检查 _currentNetworkID。在锁外读取与锁内检查之间存在时间窗口，
    // 在此窗口内 disconnectCurrentRoom 可能清空 currentRoom 和 currentNetworkID。
    // 虽然实际影响有限（effectiveIP 已被计算但不会被写入，因为 _currentNetworkID 已被清空），
    // 但仍存在以下风险：
    //   - 在锁外读取的 currentRoom 在进入锁内时可能已被替换为另一个房间（切换房间场景）
    //   - 导致 effectiveIP 使用旧房间的 isAdhoc 判断写入到新房间的 currentLocalIP
    //
    // 修复方案：所有相关读取和判断都在 _stateLock 内完成，确保状态一致性。
    [_stateLock lock];

    // 判断当前网络是否为 Ad-hoc 网络
    // Ad-hoc 网络只有 IPv6 地址，需要使用 ipv6 而非 ipv4
    MultiplayerRoom *currentRoom = self.currentRoom;
    BOOL isAdhoc = currentRoom && [self isAdhocNetworkId:currentRoom.networkId];
    NSString *effectiveIP = isAdhoc ? ipv6 : ipv4;

    // 更新当前房间的本地 IP
    if (_currentNetworkID == networkID) {
        self.currentLocalIP = effectiveIP;
        // 关键修复（对标 FCL/HMCL）：ZeroTier 网络就绪回调可能晚于 connectToRoomFlow 完成，
        // 此处也需将 IP 同步到 room.hostIP，确保分享文本能输出正确的服务器地址。
        // Ad-hoc 模式下使用 IPv6，标准模式下使用 IPv4。

        // 关键修复（P0-1）：节点掉线恢复后数据平面（SOCKS5/PortForwarder）不重启的修复。
        // zeroTierNodeOffline 已停止代理；此处当网络就绪后调用 ensureDataPlaneRunningForCurrentRoom
        // 重启数据平面。首次连接时代理已运行，方法内部 isRunning 检查会跳过重启，无副作用。
        // 注意：此调用在 _stateLock 内会有死锁风险（ensureDataPlaneRunningForCurrentRoom 内部也获取 _stateLock），
        // 所以在 unlock 之后调用。
    }
    MultiplayerRoom *room = currentRoom;
    BOOL needsUpdate = NO;
    BOOL needsDataPlaneRestore = (_currentNetworkID == networkID);
    if (room && effectiveIP && effectiveIP.length > 0) {
        // 关键修复（房客连接失败根因）：只有房主才应将本机 ZeroTier IP 同步到 room.hostIP。
        // 之前无条件同步导致房客的 hostIP 被本机 IP 覆盖，PortForwarder 转发到房客自己。
        // 房客的 hostIP 来自分享代码（房主 IP），必须保留，不能被本机 IP 覆盖。
        //
        // 关键修复（替代 IP 启发式）：
        // 优先使用 room.role 判断；role == Unknown 时回退到 IP 启发式以保持兼容。
        NSString *existingHostIP = room.hostIP;
        BOOL isHostByRole = (room.role == MultiplayerRoomRoleHost);
        BOOL isHostByIPFallback = (room.role == MultiplayerRoomRoleUnknown &&
                                   (existingHostIP.length == 0 || [existingHostIP isEqualToString:effectiveIP]));
        BOOL isHost = isHostByRole || isHostByIPFallback;
        if (isHost) {
            // 房主：更新本机 IP 到 hostIP（用于分享给房客）
            if (![existingHostIP isEqualToString:effectiveIP]) {
                room.hostIP = effectiveIP;
                needsUpdate = YES;
            }
            NSLog(@"[MultiplayerManager] Updated local IP for room %@ (%@, role=%ld): %@",
                  room.name, isAdhoc ? @"IPv6" : @"IPv4", (long)room.role, effectiveIP);
        } else {
            // 房客：保留房主 IP，仅更新 currentLocalIP（已在上方更新）
            NSLog(@"[MultiplayerManager] Guest mode (role=%ld): keeping host IP %@, local IP %@ (not overwriting hostIP)",
                  (long)room.role, existingHostIP, effectiveIP);
        }
    }
    [_stateLock unlock];

    // 关键修复（P0-1）：在锁外调用 ensureDataPlaneRunningForCurrentRoom，
    // 避免与 _stateLock 嵌套获取造成死锁。
    if (needsDataPlaneRestore) {
        [self ensureDataPlaneRunningForCurrentRoom];
    }

    // 持久化到房间列表（后台异步写入）
    if (needsUpdate && room) {
        [self updateRoom:room];
    }

    // 通知 delegate 刷新 UI（IP 显示可能需要更新）
    //
    // 关键修复（H6）：dispatch_async 内必须再次检查 currentRoom 是否仍是同一个 room。
    // 之前直接捕获外部 room 变量在 dispatch_async 块内使用，存在以下风险：
    //   - 网络就绪事件可能在用户切换房间后才被投递到主线程
    //   - 此时 self.currentRoom 已经变成了另一个房间，但回调仍在通知旧的 room
    //   - 导致 UI 显示与新房间不一致的连接成功状态
    // 修复方案：在 dispatch_async 内重新读取 self.currentRoom，并与 room 比对，
    // 只有当 currentRoom 仍是 room 时才通知 delegate。
    if (room && [self.delegate respondsToSelector:@selector(multiplayerRoomConnected:)]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MultiplayerRoom *currentNow = self.currentRoom;
            if (currentNow && [currentNow.roomId isEqualToString:room.roomId]) {
                [self.delegate multiplayerRoomConnected:room];
            } else {
                NSLog(@"[MultiplayerManager] Network ready callback arrived on main thread but current room changed, skipping notification (roomId=%@)",
                      room.roomId);
            }
        });
    }
}

/// 通用网络失败处理：将网络失败事件转换为 delegate 通知
///
/// @param networkID 失败的网络 ID
/// @param errorDescription 失败的本地化描述
- (void)handleNetworkFailure:(uint64_t)networkID
              errorDescription:(NSString *)errorDescription {
    NSLog(@"[MultiplayerManager] ZeroTier network failure: networkID=%llu desc=%@", networkID, errorDescription);

    [_stateLock lock];
    MultiplayerRoom *room = (_currentNetworkID == networkID) ? self.currentRoom : nil;
    [_stateLock unlock];

    if (!room) {
        return;
    }

    room.status = MultiplayerRoomStatusError;
    [self updateRoom:room];

    if (![self.delegate respondsToSelector:@selector(multiplayerRoom:didFailWithError:)]) {
        return;
    }

    NSError *error = [NSError errorWithDomain:kMultiplayerErrorDomain
                                          code:MultiplayerErrorCodeJoinNetworkFailed
                                      userInfo:@{NSLocalizedDescriptionKey: errorDescription}];

    // dispatch_async 到主线程期间，用户可能切换了房间，需要再次校验
    // currentRoom 仍是同一个 room，避免向 delegate 通知过时的房间状态。
    dispatch_async(dispatch_get_main_queue(), ^{
        MultiplayerRoom *currentNow = self.currentRoom;
        if (currentNow && [currentNow.roomId isEqualToString:room.roomId]) {
            [self.delegate multiplayerRoom:room didFailWithError:error];
        } else {
            NSLog(@"[MultiplayerManager] Network failure callback arrived on main thread but current room changed, skipping notification (roomId=%@)",
                  room.roomId);
        }
    });
}

- (void)zeroTierNetworkNotFound:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier network not found: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:localize(@"i18n_str_634", nil)];
}

- (void)zeroTierNetworkAccessDenied:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier network access denied: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:localize(@"i18n_str_623", nil)];
}

- (void)zeroTierNetworkClientTooOld:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier client too old: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:localize(@"i18n_str_625", nil)];
}

- (void)zeroTierNetworkDown:(uint64_t)networkID {
    NSLog(@"[MultiplayerManager] ZeroTier network controller unreachable: networkID=%llu", networkID);
    [self handleNetworkFailure:networkID
              errorDescription:localize(@"i18n_str_626", nil)];
}

#pragma mark - 分享功能

- (NSString *)shareTextForRoom:(MultiplayerRoom *)room {
    if (!room) {
        return @"";
    }

    NSString *name = room.name ?: localize(@"i18n_str_609", nil);
    NSString *networkId = room.networkId ?: @"";
    // hostIP 可能为空字符串（房主尚未连接房间时），此时显示提示
    NSString *hostIP = (room.hostIP && room.hostIP.length > 0) ? room.hostIP : localize(@"i18n_str_635", nil);
    NSString *hostPort = (room.hostPort && room.hostPort.length > 0) ? room.hostPort : kDefaultMCPort;

    // 关键修复（M7）：IPv6 地址在 host:port 格式中必须用方括号包裹。
    // 之前直接拼接为 host:port，对 IPv6 地址（如 2001:db8::1）会得到 2001:db8::1:25565，
    // 端口号与地址中的冒号无法区分，Minecraft 客户端无法正确解析。
    // RFC 3986 规定 IPv6 地址在 URI 中必须用 [和] 包裹，例如 [2001:db8::1]:25565。
    // 检测方法：如果 hostIP 包含冒号，则视为 IPv6 地址。
    NSString *serverAddress;
    BOOL isIPv6 = ([hostIP rangeOfString:@":"].location != NSNotFound);
    if (isIPv6) {
        serverAddress = [NSString stringWithFormat:@"[%@]:%@", hostIP, hostPort];
    } else {
        serverAddress = [NSString stringWithFormat:@"%@:%@", hostIP, hostPort];
    }

    NSMutableString *text = [NSMutableString string];

    [text appendString:localize(@"i18n_str_599", nil)];
    [text appendString:@"\n"];

    [text appendString:localize(@"i18n_str_600", nil)];
    [text appendString:name];
    [text appendString:@"\n"];

    [text appendString:localize(@"i18n_str_601", nil)];
    [text appendString:networkId];
    [text appendString:@"\n"];

    [text appendString:localize(@"i18n_str_602", nil)];
    [text appendString:serverAddress];
    [text appendString:@"\n"];

    [text appendString:@"\n"];
    [text appendString:localize(@"i18n_str_636", nil)];
    [text appendString:localize(@"i18n_str_637", nil)];
    [text appendString:localize(@"i18n_str_638", nil)];
    [text appendFormat:localize(@"i18n_str_639", nil), serverAddress];
    [text appendString:@"\n\n"];
    [text appendString:localize(@"i18n_str_640", nil)];

    return [text copy];
}

- (nullable MultiplayerRoom *)parseRoomFromShareText:(NSString *)text {
    if (!text || text.length == 0) {
        return nil;
    }

    NSString *roomName = nil;
    NSString *networkId = nil;
    NSString *hostIP = nil;
    NSString *hostPort = nil;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];

    // ========== 1. 逐行匹配带前缀的字段 ==========

    NSRegularExpression *nameRegex = [NSRegularExpression
        regularExpressionWithPattern:localize(@"i18n_str_641", nil)
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    NSRegularExpression *networkIdRegex = [NSRegularExpression
        regularExpressionWithPattern:localize(@"i18n_str_642", nil)
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];

    // 关键修复（M8）：addressRegex 同时匹配 IPv4 和 IPv6 地址。
    // 之前仅匹配 IPv4 格式（[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}），
    // 导致 Ad-hoc 模式下分享文本中的 IPv6 服务器地址（如 [2001:db8::1]:25565）
    // 完全无法被解析，从分享文本导入 Ad-hoc 房间时 hostIP 始终为空。
    //
    // 修复方案：正则中增加 IPv6 分支，匹配带方括号的 IPv6 地址（\[[0-9a-fA-F:]+\]）。
    // 注意：shareTextForRoom 总是以 [IPv6]:port 格式输出 IPv6 地址（M7 修复），
    // 所以解析时只需匹配带方括号的格式即可。
    // IPv6 地址中的方括号会保留在 hostIP 中，便于后续识别地址类型。
    NSRegularExpression *addressRegex = [NSRegularExpression
        regularExpressionWithPattern:localize(@"i18n_str_643", nil)
                             options:0
                               error:nil];

    for (NSString *line in lines) {
        NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedLine.length == 0) continue;

        if (!roomName) {
            NSTextCheckingResult *nameMatch = [nameRegex firstMatchInString:trimmedLine
                                                                   options:0
                                                                     range:NSMakeRange(0, trimmedLine.length)];
            if (nameMatch && nameMatch.numberOfRanges >= 2) {
                roomName = [trimmedLine substringWithRange:[nameMatch rangeAtIndex:1]];
                roomName = [roomName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }

        if (!networkId) {
            NSTextCheckingResult *networkMatch = [networkIdRegex firstMatchInString:trimmedLine
                                                                            options:0
                                                                              range:NSMakeRange(0, trimmedLine.length)];
            if (networkMatch && networkMatch.numberOfRanges >= 2) {
                networkId = [trimmedLine substringWithRange:[networkMatch rangeAtIndex:1]];
                networkId = [networkId lowercaseString];
            }
        }

        if (!hostIP) {
            NSTextCheckingResult *addressMatch = [addressRegex firstMatchInString:trimmedLine
                                                                          options:0
                                                                            range:NSMakeRange(0, trimmedLine.length)];
            if (addressMatch && addressMatch.numberOfRanges >= 2) {
                hostIP = [trimmedLine substringWithRange:[addressMatch rangeAtIndex:1]];
                if (addressMatch.numberOfRanges >= 3) {
                    NSRange portRange = [addressMatch rangeAtIndex:2];
                    if (portRange.location != NSNotFound && portRange.length > 0) {
                        hostPort = [trimmedLine substringWithRange:portRange];
                    }
                }
            }
        }
    }

    // ========== 2. 兜底：未匹配到 Network ID 时，在整个文本中搜索 ==========

    if (!networkId) {
        NSRegularExpression *rawHexRegex = [NSRegularExpression
            regularExpressionWithPattern:@"\\b([0-9a-fA-F]{16})\\b"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *rawHexMatch = [rawHexRegex firstMatchInString:text
                                                                   options:0
                                                                     range:NSMakeRange(0, text.length)];
        if (rawHexMatch && rawHexMatch.numberOfRanges >= 2) {
            networkId = [[text substringWithRange:[rawHexMatch rangeAtIndex:1]] lowercaseString];
        }
    }

    // ========== 3. 兜底：未匹配到服务器地址时，在整个文本中搜索 ==========

    if (!hostIP) {
        // 关键修复（M8）：rawAddressRegex 同样支持 IPv6 地址（带方括号格式）。
        NSRegularExpression *rawAddressRegex = [NSRegularExpression
            regularExpressionWithPattern:@"((?:[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}\\.[0-9]{1,3}|\\[[0-9a-fA-F:]+\\]))(?::([0-9]{1,5}))?"
                                 options:0
                                   error:nil];
        NSTextCheckingResult *rawAddressMatch = [rawAddressRegex firstMatchInString:text
                                                                           options:0
                                                                             range:NSMakeRange(0, text.length)];
        if (rawAddressMatch && rawAddressMatch.numberOfRanges >= 2) {
            hostIP = [text substringWithRange:[rawAddressMatch rangeAtIndex:1]];
            if (rawAddressMatch.numberOfRanges >= 3) {
                NSRange portRange = [rawAddressMatch rangeAtIndex:2];
                if (portRange.location != NSNotFound && portRange.length > 0) {
                    hostPort = [text substringWithRange:portRange];
                }
            }
        }
    }

    // ========== 4. 校验解析结果 ==========

    if (!networkId || networkId.length != 16) {
        NSLog(@"[MultiplayerManager] Parsing share text failed: Network ID invalid or missing");
        return nil;
    }

    if (![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] Parsing share text failed: Network ID format validation failed: %@", networkId);
        return nil;
    }

    if (!roomName || roomName.length == 0) {
        roomName = localize(@"i18n_str_644", nil);
    }

    if (!hostPort || hostPort.length == 0) {
        hostPort = kDefaultMCPort;
    }

    if (!hostIP) {
        hostIP = @"";
        NSLog(@"[MultiplayerManager] Parsing share text: server IP not found, user may need to manually add it later");
    }

    // ========== 5. 构造房间对象 ==========

    MultiplayerRoom *room = [[MultiplayerRoom alloc] initWithId:nil
                                                            name:roomName
                                                       networkId:networkId
                                                          hostIP:hostIP
                                                        hostPort:hostPort];
    room.roomDescription = localize(@"i18n_str_645", nil);
    room.status = MultiplayerRoomStatusDisconnected;

    NSLog(@"[MultiplayerManager] Successfully parsed share text: name=%@, networkId=%@, host=%@:%@",
          roomName, networkId, hostIP, hostPort);

    return room;
}

#pragma mark - 辅助方法

- (NSString *)generateRoomId {
    return [[NSUUID UUID] UUIDString];
}

- (BOOL)isValidNetworkId:(NSString *)networkId {
    if (!networkId || networkId.length != 16) {
        return NO;
    }

    NSCharacterSet *hexCharset = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
    for (NSUInteger i = 0; i < networkId.length; i++) {
        unichar ch = [networkId characterAtIndex:i];
        if (![hexCharset characterIsMember:ch]) {
            return NO;
        }
    }

    NSString *lowercase = [networkId lowercaseString];
    if ([lowercase isEqualToString:@"0000000000000000"]) {
        return NO;
    }

    return YES;
}

- (BOOL)isValidIPAddress:(NSString *)ipAddress {
    if (!ipAddress || ipAddress.length == 0) {
        return NO;
    }

    NSArray *components = [ipAddress componentsSeparatedByString:@"."];
    if (components.count != 4) {
        return NO;
    }

    for (NSString *component in components) {
        if (component.length == 0 || component.length > 3) {
            return NO;
        }

        NSCharacterSet *digitCharset = [NSCharacterSet decimalDigitCharacterSet];
        for (NSUInteger i = 0; i < component.length; i++) {
            unichar ch = [component characterAtIndex:i];
            if (![digitCharset characterIsMember:ch]) {
                return NO;
            }
        }

        NSInteger value = [component integerValue];
        if (value < 0 || value > 255) {
            return NO;
        }

        if (component.length > 1 && [component hasPrefix:@"0"]) {
            return NO;
        }
    }

    return YES;
}

#pragma mark - 分享代码（FCL 风格 Base64 编码）

/// 分享代码的 JSON key 常量
static NSString * const kShareCodeKeyNetworkId = @"n";
static NSString * const kShareCodeKeyHostIP = @"h";
static NSString * const kShareCodeKeyHostPort = @"p";
static NSString * const kShareCodeKeyRoomName = @"r";

/// 预设 Network ID 的偏好键
static NSString * const kPresetNetworkIdPrefKey = @"multiplayer.preset_network_id";

- (NSString *)generateShareCodeForRoom:(MultiplayerRoom *)room {
    if (!room || !room.networkId) {
        return @"";
    }

    // 构建 JSON 字典
    NSMutableDictionary *jsonDict = [NSMutableDictionary dictionary];
    // Network ID 大小写归一化：统一用小写，避免大小写不一致导致同一房间产生不同分享码
    jsonDict[kShareCodeKeyNetworkId] = [room.networkId lowercaseString];
    if (room.hostIP && room.hostIP.length > 0) {
        jsonDict[kShareCodeKeyHostIP] = room.hostIP;
    }
    if (room.hostPort && room.hostPort.length > 0) {
        jsonDict[kShareCodeKeyHostPort] = room.hostPort;
    } else {
        jsonDict[kShareCodeKeyHostPort] = kDefaultMCPort;
    }
    if (room.name && room.name.length > 0) {
        jsonDict[kShareCodeKeyRoomName] = room.name;
    }

    // 序列化为 JSON Data
    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:jsonDict
                                                       options:NSJSONWritingSortedKeys
                                                         error:&jsonError];
    if (jsonError || !jsonData) {
        NSLog(@"[MultiplayerManager] Generating share code failed: JSON serialization failed - %@", jsonError);
        return @"";
    }

    // Base64 编码：iOS NSData 的 Base64EncodingOptions 没有 URL-safe 选项（Swift 6.2+ 才有），
    // 这里先用标准 Base64 编码，再手动把 + 替换为 -、/ 替换为 _，得到 URL-safe 形式。
    // 避免分享码经过 IM / URL / 邮件传递时 + 被转为空格、/ 被转为 _ 等导致解析失败。
    NSString *base64String = [jsonData base64EncodedStringWithOptions:0];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    base64String = [base64String stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    // 标准编码不会产生换行，仍去除空格以防万一
    base64String = [base64String stringByReplacingOccurrencesOfString:@" " withString:@""];

    NSLog(@"[MultiplayerManager] Share code generated (length=%lu): %@...",
          (unsigned long)base64String.length,
          base64String.length > 20 ? [base64String substringToIndex:20] : base64String);

    return base64String;
}

- (nullable MultiplayerRoom *)parseShareCode:(NSString *)code {
    if (!code || code.length == 0) {
        return nil;
    }

    // 清理输入：去除首尾空白和换行符
    NSString *cleanCode = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanCode.length == 0) {
        return nil;
    }

    // 兼容旧版/被 IM 转换过的分享码：
    // - 新版生成端使用 URL-safe Base64（- 和 _）
    // - 旧版生成端使用标准 Base64（+ 和 /）
    // - 某些 IM / URL 处理会自动把 + 转为空格、/ 转为 _ 等
    // 解析策略：先把空格还原为 +、把 URL-safe 字符（- _）还原为标准字符（+ /），
    // 然后用标准 Base64 解码。这样可同时兼容新旧格式与被转换过的码。
    NSMutableString *normalized = [cleanCode mutableCopy];
    [normalized replaceOccurrencesOfString:@" " withString:@"+" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, normalized.length)];
    [normalized replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, normalized.length)];

    // Base64 解码（仍用 IgnoreUnknownCharacters 兜底，忽略其他意外字符）
    NSData *jsonData = [[NSData alloc] initWithBase64EncodedString:normalized
                                                            options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (!jsonData || jsonData.length == 0) {
        NSLog(@"[MultiplayerManager] Parsing share code failed: Base64 decoding failed");
        return nil;
    }

    // JSON 反序列化
    NSError *jsonError = nil;
    NSDictionary *jsonDict = [NSJSONSerialization JSONObjectWithData:jsonData
                                                            options:0
                                                              error:&jsonError];
    if (jsonError || !jsonDict || ![jsonDict isKindOfClass:[NSDictionary class]]) {
        NSLog(@"[MultiplayerManager] Parsing share code failed: JSON deserialization failed - %@", jsonError);
        return nil;
    }

    // 提取字段
    NSString *networkId = jsonDict[kShareCodeKeyNetworkId];
    NSString *hostIP = jsonDict[kShareCodeKeyHostIP];
    NSString *hostPort = jsonDict[kShareCodeKeyHostPort];
    NSString *roomName = jsonDict[kShareCodeKeyRoomName];

    // Network ID 大小写归一化：统一转小写，避免大小写不一致影响 ZeroTier 网络加入
    if (networkId) {
        networkId = [networkId lowercaseString];
    }

    // 校验 Network ID
    if (!networkId || ![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] Parsing share code failed: Invalid Network ID - %@", networkId);
        return nil;
    }

    // 构建房间对象
    MultiplayerRoom *room = [[MultiplayerRoom alloc] init];
    room.roomId = [self generateRoomId];
    room.networkId = networkId;
    room.hostIP = hostIP ?: @"";
    room.hostPort = hostPort ?: kDefaultMCPort;
    room.name = roomName ?: [NSString stringWithFormat:@"%@...", [networkId substringToIndex:8]];
    room.roomDescription = @"";
    room.ownerName = @"";
    room.status = MultiplayerRoomStatusDisconnected;
    // 关键修复：解析分享代码得到的房间一定是房客角色
    room.role = MultiplayerRoomRoleGuest;
    room.createdAt = [NSDate date];

    NSLog(@"[MultiplayerManager] Share code parsed: roomName=%@ networkId=%@ hostIP=%@ hostPort=%@",
          room.name, room.networkId, room.hostIP, room.hostPort);

    return room;
}

#pragma mark - 预设 Network ID 管理（FCL 风格）

- (nullable NSString *)presetNetworkId {
    NSString *networkId = [[NSUserDefaults standardUserDefaults] stringForKey:kPresetNetworkIdPrefKey];
    if (networkId && networkId.length > 0 && [self isValidNetworkId:networkId]) {
        return networkId;
    }
    return nil;
}

- (void)setPresetNetworkId:(nullable NSString *)networkId {
    if (!networkId || networkId.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kPresetNetworkIdPrefKey];
        NSLog(@"[MultiplayerManager] Cleared preset Network ID");
        return;
    }

    // 校验格式
    if (![self isValidNetworkId:networkId]) {
        NSLog(@"[MultiplayerManager] Preset Network ID format invalid, not saved: %@", networkId);
        return;
    }

    [[NSUserDefaults standardUserDefaults] setObject:networkId forKey:kPresetNetworkIdPrefKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    NSLog(@"[MultiplayerManager] Saved preset Network ID: %@", networkId);
}

#pragma mark - Ad-hoc 网络（快速模式，无需注册账号）

- (NSString *)generateAdhocNetworkId {
    // 使用 zts_net_compute_adhoc_id 生成 Ad-hoc 网络 ID
    // 参数：端口范围 0-65535（兼容 MC 所有端口，包括 25565 和 LAN 随机端口）
    // 返回值：uint64_t 类型的网络 ID，需要转换为 16 位十六进制字符串
    uint64_t adhocNetId = zts_net_compute_adhoc_id(0, 65535);

    // 关键修复（H11）：检查 zts_net_compute_adhoc_id 返回值的有效性。
    // 之前不检查返回值，直接格式化为字符串，导致：
    //   - 在 stub 模式（zt.framework 不可用）下，zts_net_compute_adhoc_id 返回 0，
    //     格式化后变成 "0000000000000000"，调用方拿到这个 ID 后会尝试加入一个
    //     不存在的网络，引发各种不可预知的错误。
    //   - 即使 framework 可用，如果端口范围参数非法或 libzt 内部异常，
    //     也可能返回 0 或无效值，同样会导致后续加入网络失败。
    //
    // 修复方案：
    //   1. 检查 adhocNetId 是否为 0（最明显的失败标志）
    //   2. 检查 adhocNetId 的高字节是否为 0xff（Ad-hoc 网络 ID 的规范要求
    //      高字节必须是 0xff，参见 ZeroTierSockets.h 中 zts_net_compute_adhoc_id
    //      的文档说明，例如 ff0000ffff000000）
    //   3. 如果检查失败，返回 nil，由调用方处理（UI 层已检查 nil/空字符串）
    if (adhocNetId == 0) {
        NSLog(@"[MultiplayerManager] generateAdhocNetworkId failed: zts_net_compute_adhoc_id returned 0 (possibly stub mode or libzt error)");
        return nil;
    }

    // Ad-hoc 网络 ID 高字节必须是 0xff（参见 ZeroTierSockets.h 第 1559-1560 行的示例：
    // ff00160016000000、ff0000ffff000000）
    uint8_t highByte = (uint8_t)((adhocNetId >> 56) & 0xFF);
    if (highByte != 0xFF) {
        NSLog(@"[MultiplayerManager] generateAdhocNetworkId failed: high byte of return value 0x%016llx is not 0xff (does not conform to Ad-hoc network ID spec)",
              adhocNetId);
        return nil;
    }

    // 转换为 16 位十六进制字符串（与标准 Network ID 格式一致）
    NSString *adhocNetIdStr = [NSString stringWithFormat:@"%016llx", adhocNetId];

    NSLog(@"[MultiplayerManager] Ad-hoc network ID generated: %@ (raw=%llu)", adhocNetIdStr, adhocNetId);
    return adhocNetIdStr;
}

- (BOOL)isAdhocNetworkId:(NSString *)networkId {
    // Ad-hoc 网络 ID 以 "ff" 开头（如 ff0000ffff000000）
    // 标准网络 ID 以其他字符开头（如 1a2b3c4d5e6f7g8h）
    if (!networkId || networkId.length < 2) {
        return NO;
    }
    NSString *prefix = [[networkId substringToIndex:2] lowercaseString];
    return [prefix isEqualToString:@"ff"];
}


#pragma mark - 存档关闭彻底清理

/// 停止所有联机服务
/// 在存档关闭、应用退出或断开连接时调用，确保所有资源被彻底释放
- (void)stopAllMultiplayerServices {
    NSLog(@"[MultiplayerManager] Stopping all multiplayer services...");

    // 1. 停止 SOCKS5 代理
    if ([[SOCKS5Proxy sharedProxy] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping SOCKS5 proxy");
        [[SOCKS5Proxy sharedProxy] stop];
    }

    // 2. 停止端口转发器
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] Stopping port forwarder");
        [[PortForwarder sharedForwarder] stop];
    }

    // 3. 清除环境变量（防止旧联机码残留）
    unsetenv([kAMETHYSTSOCKS5ProxyEnvVar UTF8String]);
    NSLog(@"[MultiplayerManager] Cleared SOCKS5 environment variable");

    // 4. 离开所有 ZeroTier 网络
    // 关键修复（P1-6）：原代码用 _stateLock 保护 internalRooms 的读取，
    // 但 internalRooms 的所有其他读写（addRoom/removeRoom/updateRoom/savedRooms getter）
    // 都用 @synchronized(self)。_stateLock 与 @synchronized(self) 是两套互不相干的锁，
    // 同时读写可变数组属于未定义行为，可能引发 EXC_BAD_ACCESS 崩溃。
    // 修复：internalRooms 的读取统一使用 @synchronized(self)，与项目其他位置保持一致。
    NSArray *rooms;
    @synchronized(self) {
        rooms = [self.internalRooms copy];
    }

    for (MultiplayerRoom *room in rooms) {
        if (room.networkId && room.networkId.length > 0) {
            // networkId 是 16 位十六进制字符串，必须用 parseNetworkIDFromString 解析，
            // 不能用 unsignedLongLongValue（NSString 无此方法，且默认按十进制解析）
            uint64_t networkID = [ZeroTierBridge parseNetworkIDFromString:room.networkId];
            if (networkID == 0) {
                NSLog(@"[MultiplayerManager] Skipping invalid Network ID: %@", room.networkId);
                continue;
            }
            NSLog(@"[MultiplayerManager] Leaving network: %@", room.networkId);
            [[ZeroTierBridge sharedInstance] leaveNetwork:networkID];
        }
    }

    // 5. 停止 ZeroTier 节点
    NSLog(@"[MultiplayerManager] Stopping ZeroTier node");
    [[ZeroTierBridge sharedInstance] stopNode];

    // 6. 重置所有状态（确保下次开房生成新联机码）
    [_stateLock lock];
    self.currentRoom = nil;
    self.currentNetworkID = 0;
    self.currentLocalIP = nil;
    self.currentSOCKS5Port = 0;
    self.currentForwardingPort = 0;
    _nodeStarted = NO;
    [_stateLock unlock];

    // 7. 关键修复（P0-A）：清除 PLProfiles 中残留的 serverIp
    // 与 disconnectCurrentRoom 同理：防止下次启动 MC 时残留的 serverIp 触发
    // "进游戏必显示连接服务器"的 bug。stopAllMultiplayerServices 在游戏退出
    // /App 进入后台/App 被终止时调用，必须彻底清理。
    @try {
        NSString *currentProfile = [[PLProfiles current] selectedProfileName];
        if (currentProfile.length > 0) {
            [[PLProfiles current] setServerIp:@"" forProfile:currentProfile];
            NSLog(@"[MultiplayerManager] Cleared serverIp for profile '%@'", currentProfile);
        }
    } @catch (NSException *e) {
        NSLog(@"[MultiplayerManager] Failed to clear serverIp: %@", e);
    }

    NSLog(@"[MultiplayerManager] All multiplayer services stopped, state reset");
}

#pragma mark - 房主模式 PortForwarder 启动

/// 启动 PortForwarder 房主模式（反向转发）
///
/// 房主在 MC 中"对局域网开放"并手动输入 MC LAN 端口后调用本方法。
/// PortForwarder 会在 ZeroTier 网络中监听 listenPort，并将连接转发到
/// 本地 127.0.0.1:localHostPort（MC LAN 端口），使 PC/Mac/Android/iOS
/// 房客能通过房主的 ZeroTier IP:listenPort 直接连接进入游戏。
///
/// 调用前提：当前房间已连接成功（self.currentRoom 非 nil 且 status == Connected）。
///
/// @param listenPort 在 ZeroTier 网络中监听的端口（通常为 25565）
/// @param localHostPort 本地 MC LAN 端口（MC 中"对局域网开放"后聊天框显示的端口号）
/// @return YES 表示启动成功，NO 表示失败（如未连接房间或 PortForwarder 启动失败）
- (BOOL)startHostPortForwarderWithListenPort:(uint16_t)listenPort
                               localHostPort:(uint16_t)localHostPort {
    // 校验当前已连接房间
    [_stateLock lock];
    MultiplayerRoom *room = self.currentRoom;
    MultiplayerRoomStatus status = room.status;
    [_stateLock unlock];

    if (!room || status != MultiplayerRoomStatusConnected) {
        NSLog(@"[MultiplayerManager] startHostPortForwarder failed: no room connected (room=%@ status=%ld)",
              room ? room.name : @"nil", (long)status);
        return NO;
    }

    // 若 PortForwarder 已在运行，先停止旧模式
    if ([[PortForwarder sharedForwarder] isRunning]) {
        NSLog(@"[MultiplayerManager] startHostPortForwarder: PortForwarder already running (mode=%ld), stopping first",
              (long)[[PortForwarder sharedForwarder] mode]);
        [[PortForwarder sharedForwarder] stop];

        [_stateLock lock];
        self.currentForwardingPort = 0;
        [_stateLock unlock];
    }

    NSLog(@"[MultiplayerManager] Starting PortForwarder host mode: ZeroTier listening %u → local 127.0.0.1:%u",
          listenPort, localHostPort);

    BOOL started = [[PortForwarder sharedForwarder] startHostModeWithListenPort:listenPort
                                                                  localHostPort:localHostPort];
    if (!started) {
        NSLog(@"[MultiplayerManager] PortForwarder host mode start failed");
        return NO;
    }

    uint16_t actualPort = [[PortForwarder sharedForwarder] listeningPort];
    [_stateLock lock];
    self.currentForwardingPort = actualPort;
    [_stateLock unlock];

    NSLog(@"[MultiplayerManager] PortForwarder host mode started: ZeroTier listening %u → local 127.0.0.1:%u",
          actualPort, localHostPort);
    return YES;
}

@end