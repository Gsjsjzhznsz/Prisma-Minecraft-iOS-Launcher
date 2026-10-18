//
// PrivilegePlugin.h — Task296 第三方权限插件 ABI v1（宿主侧契约头）
//
// ★ 架构定性（Task296 调研定案，详见 worklog）：
//   本启动器主仓库【永不包含】任何漏洞利用代码。本头文件只定义"能力提供方"
//   契约：由用户在签名安装阶段自行注入的第三方 dylib（如社区 FilzaEscapedDS
//   同形态插件）可在运行时向宿主声明并交付沙盒外能力（跨容器文件 / IOKit
//   GPU 直访 / 内存墙放宽）。宿主对其内部实现完全不可知、不参与、不分发。
//
//   契约三方：
//     - 插件（第三方 dylib）：实现本头文件的 pp_plugin_* 六函数，自行决定
//       支持的 iOS 版本窗口与设备（宿主不硬编码漏洞窗口）。
//     - 宿主（本启动器）：发现 → 声明 → 用户明示同意 → 会话期挂载 → 失败
//       零阻塞降级（现行为不变：TrollStore 用户 entitlements 全套、JIT 走
//       StikJIT 深链，均不受本插件影响）。
//     - 用户：通过右侧面板「权限插件」信息卡完成知情同意（默认关闭，
//       无同意永不加载/挂载）。
//
//   注入方式（对齐 FilzaEscapedDS 工作流）：签名重签工具（Sideloadly/
//   全能签等）Advanced Options → Tweak injection 勾选插件 dylib 一并打入
//   IPA。插件会被 LC_LOAD_DYLIB 自动加载，或按本契约命名被发现后 dlopen。
//
#ifndef PRIVILEGE_PLUGIN_H
#define PRIVILEGE_PLUGIN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// ABI 版本（宿主与插件大版本不匹配时拒载）
#define PP_ABI_VERSION 1

/// 能力位（Task296 调研：no-sandbox entitlement 五项红利中无既有替代路径的
/// 三项；JIT 位保留——StikJIT 深链已覆盖，宿主当前不消费）
typedef uint64_t pp_caps_t;
#define PP_CAP_FILESYSTEM (1ULL << 0)  ///< 跨容器/系统区文件访问
#define PP_CAP_IOKIT_GPU  (1ULL << 1)  ///< IOKit GPU user client 直访
#define PP_CAP_MEM_WALL   (1ULL << 2)  ///< 内存墙/Jetsam 放宽
#define PP_CAP_JIT        (1ULL << 3)  ///< （保留位，宿主暂不消费）

/// 插件状态码
#define PP_STATUS_IDLE      0  ///< 未挂载
#define PP_STATUS_ACQUIRING 1  ///< 挂载中
#define PP_STATUS_ACQUIRED  2  ///< 已挂载（能力随进程存活期有效）
#define PP_STATUS_FAILED    3  ///< 挂载失败（errOut 可读原因）
#define PP_STATUS_RELEASED  4  ///< 已释放（进程级逃逸通常不可逆，仅语义位）

/// 挂载结果码
#define PP_ACQUIRE_OK          0
#define PP_ACQUIRE_UNSUPPORTED 1   ///< 当前版本/设备不受支持
#define PP_ACQUIRE_DECLINED    2   ///< 插件内部拒绝（如完整性自检失败）
#define PP_ACQUIRE_ERROR       3   ///< 执行失败（errOut 可读原因）

// ===== 插件必须导出的六函数（宿主经 dlsym 弱探测，缺一即判无效） =====

/// ABI 版本：返回 PP_ABI_VERSION
int pp_plugin_abi_version(void);

/// 能力声明位图（PP_CAP_* 按或组合）
pp_caps_t pp_plugin_capabilities(void);

/// 环境自检：1 支持 / 0 不支持 / -1 未知。版本窗口与设备判定责任全在插件侧，
/// 宿主不携带任何漏洞窗口常量（主仓库洁净纪律）。
int pp_plugin_environment_supported(void);

/// 挂载：请求 caps 位集。errOut（可空）写人类可读失败原因，长度 errOutLen。
/// 契约：本函数应在数秒内返回；成功后能力随进程存活期有效；宿主单进程内
/// 最多调用一次，失败不重试（内核态操作重试=整机重启风险，明令禁止）。
int pp_plugin_acquire(pp_caps_t caps, char *errOut, int errOutLen);

/// 查询当前状态（PP_STATUS_*）
int pp_plugin_status(void);

/// 释放（尽力而为；进程级逃逸通常仅在进程退出时真正回收）
void pp_plugin_release(void);

#ifdef __cplusplus
}
#endif

#endif /* PRIVILEGE_PLUGIN_H */
