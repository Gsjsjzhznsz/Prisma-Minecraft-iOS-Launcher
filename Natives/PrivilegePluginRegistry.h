//
// PrivilegePluginRegistry.h — Task296 第三方权限插件宿主（发现/同意/挂载/降级）
//
// ★ 主仓库零漏洞纪律：本类只做"能力协商"，插件内部实现不可知。
//   发现路径（保守白名单，只认文件名前缀，不递归不乱载）：
//     - 自注册：插件 constructor 调 privilege_plugin_self_register() 打标记
//     - dlopen：bundle 根目录/Frameworks/ 下前缀匹配
//       PrivilegePlugin*.dylib / dsplugin*.dylib（大小写不敏感）
//   同意门：privilege_plugin.enabled（默认 NO）——无明示同意永不 dlopen/
//   挂载； TrollStore（no-sandbox 已足）时整链路 no-op。
//

#import <Foundation/Foundation.h>
#import "PrivilegePlugin.h"

NS_ASSUME_NONNULL_BEGIN

/// 插件宿主运行态（卡片正文/诊断日志共用口径）
typedef NS_ENUM(NSInteger, PPHostState) {
    PPHostStateTSFull = 0,   ///< 安装态已具备 no-sandbox（TrollStore 等），无需插件
    PPHostStateAbsent = 1,   ///< 未发现插件
    PPHostStateNoConsent = 2,///< 已发现、未明示同意
    PPHostStateReady = 3,    ///< 已同意、待会话挂载
    PPHostStateAcquired = 4, ///< 会话挂载成功
    PPHostStateFailed = 5,   ///< 会话挂载失败（本次进程不再重试）
    PPHostStateInvalid = 6,  ///< dylib 存在但 ABI/符号校验不过
};

@interface PrivilegePluginRegistry : NSObject

+ (instancetype)shared;

/// 当前宿主状态
@property (nonatomic, readonly) PPHostState state;
/// 已授予能力位（PP_CAP_* 或集；仅 state==Acquired 时非零）
@property (nonatomic, readonly) pp_caps_t acquiredCaps;
/// 最近一次失败原因（诊断/卡片悬浮提示）
@property (nonatomic, readonly, nullable, copy) NSString *lastError;

/// 状态摘要（本地化，供信息卡正文直接使用）
- (NSString *)localizedStateSummary;

/// 用户知情同意（privilege_plugin.enabled；默认 NO）
- (BOOL)userConsented;
- (void)setUserConsented:(BOOL)on;

/// 发现插件（dlopen 白名单扫描 + 符号校验；无同意时仅做"存在性"探测，
/// 不加载——卡片能显示"未授权"而不触发任何插件代码）
- (BOOL)probePluginPresence;

/// 会话挂载（Task296 单次/进程；失败零重试零阻塞；内部自带同意门与
/// TrollStore 短路）。应在启动流程后台线程调用，宿主侧同步执行、
/// 插件侧契约数秒内返回。
- (void)acquireForGameSession;

@end

/// 插件 constructor 可选自注册钩子：仅设置"有插件在场"标记，
/// 实际加载仍走白名单 dlopen + 符号校验（未同意前不发生）。
void privilege_plugin_self_register(void);

NS_ASSUME_NONNULL_END
