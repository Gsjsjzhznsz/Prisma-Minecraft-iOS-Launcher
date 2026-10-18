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

@end

NS_ASSUME_NONNULL_END
