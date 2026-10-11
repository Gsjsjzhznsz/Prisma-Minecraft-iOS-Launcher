#import <Foundation/Foundation.h>
#import "TerracottaBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// 联机会话状态（高层状态机：8 个 Rust 底层状态 → 4 个 UI 状态）
typedef NS_ENUM(NSInteger, TerracottaStatus) {
    TerracottaStatusDisconnected = 0,  /* 未联机 */
    TerracottaStatusConnecting   = 1,  /* 连接中（host-scanning/starting, guest-connecting/starting） */
    TerracottaStatusConnected    = 2,  /* 已连接（host-ok, guest-ok） */
    TerracottaStatusError        = 3,  /* 错误（exception） */
};

/// 当前角色
typedef NS_ENUM(NSInteger, TerracottaRole) {
    TerracottaRoleNone   = 0,
    TerracottaRoleHost   = 1,  /* 房主 */
    TerracottaRoleClient = 2,  /* 访客 */
};

/// 状态变化通知名。userInfo 为 nil，调用方通过 [TerracottaManager shared] 读取最新状态。
extern NSNotificationName TerracottaManagerStateDidChangeNotification;

/// 联机管理器单例
///
/// 封装 TerracottaBridge 的状态轮询、状态机映射、SilentAudioPlayer 后台保活。
/// UI 通过 KVO 或 TerracottaManagerStateDidChangeNotification 监听状态变化。
@interface TerracottaManager : NSObject

+ (instancetype)shared;

/// ★ Task256（联机探针确定性闸）：库是否已完成初始化——读静态标志，
///   【不触发】单例创建（[TerracottaManager shared] 首次访问即会懒初始化
///   Terracotta 并孵出 ScaffoldingServer；LanPortDetector 的探测闸用本方法
///   轮询，绝不能自己把 Terracotta 孵化出来）。
+ (BOOL)hasInitializedLibrary;

@property(nonatomic, readonly) TerracottaStatus status;
@property(nonatomic, readonly) TerracottaRole role;
@property(nonatomic, readonly, nullable) NSString *currentInviteCode;  /* 房主的邀请码 */
@property(nonatomic, readonly) uint16_t currentPort;                   /* 房主的 MC LAN 端口 */
@property(nonatomic, readonly, nullable) NSString *stageDescription;   /* UI 显示的阶段文字 */
@property(nonatomic, readonly, nullable) NSArray<TerracottaPlayerProfile *> *players;
@property(nonatomic, readonly, nullable) NSString *directConnectURL;   /* 访客进 MC 直连地址 */
@property(nonatomic, readonly, nullable) NSString *lastError;
@property(nonatomic, readonly) BOOL initialized;

/// App 启动时调用一次（由 SceneDelegate 触发）。libterracotta 未链接时为空操作。
- (void)initializeTerracotta;

/// 房主：创建房间（手动端口模式）。
/// 流程：reset → setConnecting → startKeepingAlive → startHostWithPort → startPolling
- (void)createRoomWithPort:(uint16_t)port
                inviteCode:(nullable NSString *)inviteCode
                playerName:(nullable NSString *)playerName;

/// 访客：加入房间。
/// 流程：verifyRoomCode → reset → setConnecting → startKeepingAlive → setGuesting → startPolling
/// 返回 NO 表示邀请码格式无效（不会发起加入）。
- (BOOL)joinRoomWithInviteCode:(NSString *)inviteCode
                    playerName:(nullable NSString *)playerName;

/// 终止当前会话，回到 Disconnected 状态。
- (void)stopSession;

@end

NS_ASSUME_NONNULL_END
