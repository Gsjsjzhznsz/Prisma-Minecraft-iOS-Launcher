#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Task218：崩溃识别引擎（用户指令："依据判断脚本和参考 FCL 改进崩溃识别"）。
///
/// 设计输入：
///   - 本仓库验证器脚本（verify_task106/107/109/110 等）在历次装机取证中
///     沉淀的 hs_err / 信号级死亡的判读口径：JVM 收到 SIGSEGV/SIGILL/
///     SIGABRT/SIGBUS/SIGFPE/SIGTRAP 时由 -XX:ErrorFile 落 hs_err_pid*.log
///     （Task 27 定向到 POJAV_HOME）；FastQuit / 正常退出走 exit(0) 不落
///     文件；SIGKILL（jetsam）不落文件（保守方向的假阴性，不学不误学）。
///   - FCL（Fold Craft Launcher）的崩溃诊断交互：崩溃后向用户呈现
///     "崩溃类型 + 可能原因 + 处置建议"，而不是只在自己肚子里记一笔。
///
/// 分型与归因规则（JavaLauncher 的 auto 渲染器崩溃自学自此升级）：
///   1. OOM 分型——头部命中 "There is insufficient memory for the Java
///      Runtime Environment to continue."：内存不足不是渲染器的锅，
///      连败计数不 +1，诊断建议降内存 / 砍模组；
///   2. 渲染器归因——Problematic frame 或 Native frames 前段命中渲染器
///      家族库（libOSMesa / libOSMesaVirgl / libMobileGL / libmobileglues /
///      libmithril / libgl4eszl2 / libtinygl4angle / libMoltenVK）时，
///      连败记在被归因的渲染器头上（即使 auto 会话解析的是另一个）；
///   3. 未归因的信号级死亡——维持 Task217 语义：记 auto 会话渲染器
///      （宁可漏学不误学的保守方向）。
@interface CrashAnalyzer : NSObject

/// 崩溃库文件名 -> 渲染器层存储键（渲染器键即 dylib 文件名，见
/// utils.h 的 RENDERER_NAME_* 宏族）。非渲染器库返回 nil。
/// libvtestserver.dylib（VirGL 的服务端伴生库）归并到 VirGL 渲染器键。
+ (nullable NSString *)rendererKeyForLibraryName:(NSString *)libName;

/// 解析 hs_err_pid*.log（只读头部与帧区，64KB 上限足够覆盖）。
///
/// 返回字典键（全部为 NSString/NSNumber，缺席表示未命中）：
///   signal           — "SIGSEGV" 等（头部 # SIGxxx 行；无 = "(unknown)"）
///   isOOM            — NSNumber BOOL：JVM 内存不足分型命中
///   blamedRenderer   — 归因到的渲染器键（OOM / 无渲染器帧 = 缺席）
///   problematicFrame — "C [libX.dylib+0x1234]" 摘要（Problematic frame 行）
///   nativeFrames     — 前 N 条 native 帧的库摘要（诊断展示用，逗号连接）
+ (NSDictionary *)analyzeHsErrFile:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
