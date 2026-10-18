//
//  StikDebugViewController.h
//  Amethyst
//
//  ★ Task291（PocketJ 对标移植 · 内置 JIT 第一阶段）：内置 JIT 管理页。
//  四段式：JIT 状态 / 连接准备（配对文件 + LocalDevVPN）/ 配对文件管理 /
//  开启 JIT。"开启"动作走 stikjit:// 深链（bundle-id + pid + script-data，
//  与 JavaLauncher ame139 自动 enabler 同一条家法 URL），把附加交给外部
//  StikDebug 执行——同一 iOS 进程自附加 = debugserver 挂起后自锁死，
//  PocketJ 上游已定案（其 iOS 26 轨为 appex 独立进程，属第二阶段）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 内置 JIT 就绪四态（PocketJ PocketJJITSetupState 同语义）
typedef NS_ENUM(NSInteger, Ame291JITSetupState) {
    Ame291JITSetupStateEnabled,             /// JIT 已生效
    Ame291JITSetupStateReady,               /// 配对文件在位，可开启
    Ame291JITSetupStateWaitingConfiguration,/// 缺配对文件
    Ame291JITSetupStateUnavailable,         /// 系统不支持（< iOS 17.4）
};

@interface StikDebugViewController : UITableViewController

+ (Ame291JITSetupState)ame291_setupState;

/// Task294：内置轨可用性速查（iOS 26+ 且 get-task-allow 与配对文件在位且
/// 协调器 dylib 可加载）。Task134/139 分发用；纯查询，dlopen 幂等。
+ (BOOL)ame294_builtinTrackAvailable;

/// Task294：内置 JIT 开启共享入口（PocketJ +enableEmbeddedJITWithCompletion
/// 同构类方法）。JIT 管理页开启按钮 / RightPanel Task134 / JavaLauncher
/// Task139 三处共用。completion 必达：门禁不过立即回包；成功走 100ms
/// isJITEnabled 轮询提前交付（StikJIT 回包可能晚于目标已可执行）；
/// 失败回包 message 为可展示的 localize 文案或底层错误描述。
+ (void)ame294_enableBuiltinJITWithCompletion:(void (^)(BOOL success, NSString *message))completion;

/// Task294：本会话内置轨是否已成功完成 universal 脚本祝福（含 100ms 轮询
/// 提前交付的成功）。RightPanel/JavaLauncher 的 JIT26 重挂启发式用它区分
/// "完成的内置祝福（无需再附）"与"stikjit:// 中断式半附加（需重挂）"。
+ (BOOL)ame294_scriptCompletedThisSession;

@end

NS_ASSUME_NONNULL_END
