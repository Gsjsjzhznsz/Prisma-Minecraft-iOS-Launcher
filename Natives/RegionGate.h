#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Task312：服务地区门（Region Gate）。
///
/// 用户指令（2026-10-20）：明面上启动器不对中国大陆地区用户开放——多角度
/// 检测到疑似大陆用户时弹出「服务地区声明」弹窗；弹窗下方提供
/// 「我不是大陆用户」按钮；连续多次提示（3 次）之后放行。
///
/// 检测角度（多角度互证，任一强信号或组合信号命中即弹）：
///   1. 设备地区   NSLocale regionCode == "CN"（强）
///   2. 运营商     CTCarrier mobileCountryCode == "460"（强，weak_framework 容错）
///   3. 时区       Asia/Shanghai 系（中）
///   4. 语言       zh-Hans（中，仅作互证不作独立判据）
///   5. IP 归属地  异步探测 ipapi.co / ipwho.is / freeipapi.com（强，失败不误伤）
/// 同步信号命中 → 0.2s 内即弹；未命中 → 异步 IP 兜底探测，命中且有一个
/// 以上中/强信号互证时补弹（防改区伪装，也防旅行者误伤——纯 IP 无互证只记日志）。
///
/// 放行语义：每次点「我不是大陆用户」计数 +1（regiongate.confirm_count，
/// 持久化）；计满 3 置 regiongate.passed=YES，此后本安装周期永不再弹
///（用户指令「多几次提示之后放行」）。中途强退的设备下次启动从剩余次数
/// 继续。「退出」按钮 → exit(0)（带 ame312 日志锚点）。
@interface RegionGate : NSObject

/// 在 presenter 上运行地区门。
/// - 已放行（regiongate.passed）或未命中任何信号 → 同步立即调 completion；
/// - 命中 → 弹窗链走完（3 次确认）后才调 completion（挂载点用它串接
///   WelcomeViewController 向导，保证门在向导之前）。
/// - 异步 IP 补弹场景（同步未命中、IP 命中）：completion 已先行调用，
///   弹窗链独立呈现在最顶层 VC 上，不再阻塞启动流程。
+ (void)runGateFromViewController:(UIViewController *)presenter
                       completion:(void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
