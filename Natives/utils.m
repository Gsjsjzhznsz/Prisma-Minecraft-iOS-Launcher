#import <SafariServices/SafariServices.h>

#include "jni.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>
#include <dirent.h>
#include <string.h>
#include <setjmp.h>
#include <signal.h>
#include <sys/sysctl.h>
// Task173：os_proc_available_memory（Jetsam 剩余量，iOS 13+）。iOS SDK 的
// 公共头不带 <libproc.h>（CI 实测 file not found）——按 dyld_get_active_platform
// 的 Task108 先例裸 extern 声明（链接期由 libSystem 解析）。
extern uint64_t os_proc_available_memory(void);

#include "utils.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "NMToast.h"

CFTypeRef SecTaskCopyValueForEntitlement(void* task, NSString* entitlement, CFErrorRef  _Nullable *error);
void* SecTaskCreateFromSelf(CFAllocatorRef allocator);

BOOL getEntitlementValue(NSString *key) {
    // Task88 修复：原实现 SecTaskCreateFromSelf 被调用了两次（secTask 与内联各一次）
    // 但只释放其中之一，每次调用泄漏一个 SecTaskRef。主界面状态标签（Task88）会在
    // 每次回到前台时调用本函数，故顺手收紧：单次创建 + nil 守卫 + 判断后释放。
    void *secTask = SecTaskCreateFromSelf(NULL);
    if (!secTask) {
        return NO;
    }
    CFTypeRef value = SecTaskCopyValueForEntitlement(secTask, key, nil);
    CFRelease(secTask);
    if (value == nil) {
        return NO;
    }
    BOOL result = ![(__bridge id)value isKindOfClass:NSNumber.class] || [(__bridge id)value boolValue];
    CFRelease(value);
    return result;
}

// Task93：Task90 的"签名+描述文件双确认"方案已整体移除（getEffectiveEntitlementValue /
// CopyEmbeddedProfileEntitlements）——用户实测双确认在重签工具同时写入描述文件时
// 依然误报。内存标识现与启动日志 [Pre-init] Entitlements availability 完全同源，
// 均直接使用上方 getEntitlementValue()（SecTask 签名口径）。

// ============================================================================
// Task96：MeloNX 风格信息卡数据源（右面板「设备」「系统」卡片）。
// hw.machine（如 iPad15,3）→ Apple 营销名（如 "iPad Air 11-inch (M3)"）。
// 未收录机型如实回退原始标识，宁缺毋错（错名比原名更有害）。
// 标识符对照已联网核实（Apple 支持文档 / 机型选型库，2026-09 核对）：
//   iPad15,3 / iPad15,4 = iPad Air 11/13-inch (M3)
//   iPad15,7 / iPad15,8 = iPad (11th generation, A16)
//   iPad16,1 / iPad16,2 = iPad mini (A17 Pro)
//   iPad16,3-16,6       = iPad Pro 11/13-inch (M4)
// ============================================================================
static NSString *ame96_machineIdentifier(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        size_t len = 0;
        if (sysctlbyname("hw.machine", NULL, &len, NULL, 0) != 0 || len == 0) return;
        char *buf = malloc(len);
        if (!buf) return;
        if (sysctlbyname("hw.machine", buf, &len, NULL, 0) != 0) {
            free(buf);
            return;
        }
        cached = [NSString stringWithUTF8String:buf];
        free(buf);
    });
    return cached;
}

NSString *getDeviceMarketingName(void) {
    NSString *machine = ame96_machineIdentifier();
    if (machine.length == 0) {
        return [UIDevice currentDevice].model ?: localize(@"ame189.common.unknown_device", nil);
    }
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            // iPad（新→旧）
            @"iPad16,1": @"iPad mini (A17 Pro)",
            @"iPad16,2": @"iPad mini (A17 Pro)",
            @"iPad16,3": @"iPad Pro 11-inch (M4)",
            @"iPad16,4": @"iPad Pro 11-inch (M4)",
            @"iPad16,5": @"iPad Pro 13-inch (M4)",
            @"iPad16,6": @"iPad Pro 13-inch (M4)",
            @"iPad15,3": @"iPad Air 11-inch (M3)",
            @"iPad15,4": @"iPad Air 13-inch (M3)",
            @"iPad15,7": @"iPad (11th generation)",
            @"iPad15,8": @"iPad (11th generation)",
            @"iPad14,8": @"iPad Air 11-inch (M2)",
            @"iPad14,9": @"iPad Air 13-inch (M2)",
            @"iPad14,3": @"iPad Pro 11-inch (M2)",
            @"iPad14,4": @"iPad Pro 11-inch (M2)",
            @"iPad14,5": @"iPad Pro 12.9-inch (M2)",
            @"iPad14,6": @"iPad Pro 12.9-inch (M2)",
            @"iPad14,1": @"iPad mini (6th generation)",
            @"iPad14,2": @"iPad mini (6th generation)",
            @"iPad13,16": @"iPad Air (5th generation)",
            @"iPad13,17": @"iPad Air (5th generation)",
            @"iPad13,18": @"iPad (10th generation)",
            @"iPad13,19": @"iPad (10th generation)",
            @"iPad13,1": @"iPad Air (4th generation)",
            @"iPad13,2": @"iPad Air (4th generation)",
            @"iPad13,4": @"iPad Pro 11-inch (M1)",
            @"iPad13,5": @"iPad Pro 11-inch (M1)",
            @"iPad13,6": @"iPad Pro 11-inch (M1)",
            @"iPad13,7": @"iPad Pro 11-inch (M1)",
            @"iPad13,8": @"iPad Pro 12.9-inch (M1)",
            @"iPad13,9": @"iPad Pro 12.9-inch (M1)",
            @"iPad13,10": @"iPad Pro 12.9-inch (M1)",
            @"iPad13,11": @"iPad Pro 12.9-inch (M1)",
            @"iPad12,1": @"iPad (9th generation)",
            @"iPad12,2": @"iPad (9th generation)",
            @"iPad11,6": @"iPad (8th generation)",
            @"iPad11,7": @"iPad (8th generation)",
            @"iPad11,1": @"iPad mini (5th generation)",
            @"iPad11,2": @"iPad mini (5th generation)",
            @"iPad8,1": @"iPad Pro 11-inch (1st generation)",
            @"iPad8,2": @"iPad Pro 11-inch (1st generation)",
            @"iPad8,3": @"iPad Pro 11-inch (1st generation)",
            @"iPad8,4": @"iPad Pro 11-inch (1st generation)",
            @"iPad8,5": @"iPad Pro 12.9-inch (3rd generation)",
            @"iPad8,6": @"iPad Pro 12.9-inch (3rd generation)",
            @"iPad8,7": @"iPad Pro 12.9-inch (3rd generation)",
            @"iPad8,8": @"iPad Pro 12.9-inch (3rd generation)",
            @"iPad8,9": @"iPad Pro 11-inch (2nd generation)",
            @"iPad8,10": @"iPad Pro 11-inch (2nd generation)",
            @"iPad8,11": @"iPad Pro 12.9-inch (4th generation)",
            @"iPad8,12": @"iPad Pro 12.9-inch (4th generation)",
            @"iPad7,11": @"iPad (7th generation)",
            @"iPad7,12": @"iPad (7th generation)",
            @"iPad6,11": @"iPad (5th generation)",
            @"iPad6,12": @"iPad (5th generation)",
            @"iPad5,3": @"iPad Air 2",
            @"iPad5,4": @"iPad Air 2",
            @"iPad5,1": @"iPad mini 4",
            @"iPad5,2": @"iPad mini 4",
            // iPhone
            @"iPhone17,1": @"iPhone 16 Pro",
            @"iPhone17,2": @"iPhone 16 Pro Max",
            @"iPhone17,3": @"iPhone 16",
            @"iPhone17,4": @"iPhone 16 Plus",
            @"iPhone17,5": @"iPhone 16e",
            @"iPhone16,1": @"iPhone 15 Pro",
            @"iPhone16,2": @"iPhone 15 Pro Max",
            @"iPhone15,4": @"iPhone 15",
            @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone15,2": @"iPhone 14 Pro",
            @"iPhone15,3": @"iPhone 14 Pro Max",
            @"iPhone14,7": @"iPhone 14",
            @"iPhone14,8": @"iPhone 14 Plus",
            @"iPhone14,6": @"iPhone SE (3rd generation)",
            @"iPhone14,2": @"iPhone 13 Pro",
            @"iPhone14,3": @"iPhone 13 Pro Max",
            @"iPhone14,4": @"iPhone 13 mini",
            @"iPhone14,5": @"iPhone 13",
            @"iPhone13,1": @"iPhone 12 mini",
            @"iPhone13,2": @"iPhone 12",
            @"iPhone13,3": @"iPhone 12 Pro",
            @"iPhone13,4": @"iPhone 12 Pro Max",
            @"iPhone12,8": @"iPhone SE (2nd generation)",
            @"iPhone12,1": @"iPhone 11",
            @"iPhone12,3": @"iPhone 11 Pro",
            @"iPhone12,5": @"iPhone 11 Pro Max",
            @"iPhone11,8": @"iPhone XR",
            @"iPhone11,2": @"iPhone XS",
            @"iPhone11,4": @"iPhone XS Max",
            @"iPhone11,6": @"iPhone XS Max",
            @"iPhone10,1": @"iPhone 8",
            @"iPhone10,2": @"iPhone 8 Plus",
            @"iPhone10,3": @"iPhone X",
            @"iPhone10,6": @"iPhone X",
            @"iPhone9,1": @"iPhone 7",
            @"iPhone9,3": @"iPhone 7",
            @"iPhone9,2": @"iPhone 7 Plus",
            @"iPhone9,4": @"iPhone 7 Plus",
            @"iPhone8,1": @"iPhone 6s",
            @"iPhone8,2": @"iPhone 6s Plus",
            @"iPhone8,4": @"iPhone SE (1st generation)",
        };
    });
    NSString *name = table[machine];
    return name ?: machine;
}

NSString *getSystemVersionDisplay(void) {
    static NSString *cached;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIDevice *device = [UIDevice currentDevice];
        NSString *prefix = [device userInterfaceIdiom] == UIUserInterfaceIdiomPad
            ? @"iPadOS" : @"iOS";
        // 构建号（如 22D2082）：kern.osbuildversion，读不到时只显示系统版本
        NSString *build = nil;
        size_t len = 0;
        if (sysctlbyname("kern.osbuildversion", NULL, &len, NULL, 0) == 0 && len > 0) {
            char *buf = malloc(len);
            if (buf) {
                if (sysctlbyname("kern.osbuildversion", buf, &len, NULL, 0) == 0) {
                    build = [NSString stringWithUTF8String:buf];
                }
                free(buf);
            }
        }
        if (build.length > 0) {
            cached = [NSString stringWithFormat:@"%@ %@ (%@)", prefix, device.systemVersion, build];
        } else {
            cached = [NSString stringWithFormat:@"%@ %@", prefix, device.systemVersion];
        }
    });
    return cached;
}

// Task91：TrollStore 真实安装判定——签名标记 AND 磁盘标记（bundle 旁的
// _TrollStore 目录，与 main.m 的 POJAV_DETECTEDINST 判定同源）。
// 背景：entitlements.sideload.xml 模板给普通侧载包也预写了
// jb.pmap_cs.custom_trust 字符串，SecTask 如实报告"有"，导致非 TrollStore
// 环境的 invokeAfterJITEnabled 误走 apple-magnifier://（TrollStore JIT）
// 死路——JIT 永远无法自动开启。此处做 AND 确认后该路径只在真实
// TrollStore 安装上生效，普通侧载回到 stikjit:// 正常流程。
BOOL isTrollStoreInstall(void) {
    if (!getEntitlementValue(@"jb.pmap_cs.custom_trust")) return NO;
    NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
    return access(tsPath.UTF8String, F_OK) == 0;
}

// ============================================================================
// Task185：加载器版本候选集（去 "-suffix"、去最后一个点分量），供
// ame185_loaderVersionMatchesGameVersion 内部使用。
// ============================================================================
static NSArray<NSString *> *ame185_loaderCandidates(NSString *loaderVersion) {
    if (loaderVersion.length == 0) return @[];
    NSString *clean = loaderVersion;
    NSRange hyphen = [loaderVersion rangeOfString:@"-"];
    if (hyphen.location != NSNotFound) {
        clean = [loaderVersion substringToIndex:hyphen.location];
    }
    if (clean.length == 0) return @[];
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObject:clean];
    NSRange lastDot = [clean rangeOfString:@"." options:NSBackwardsSearch];
    if (lastDot.location != NSNotFound && lastDot.location > 0) {
        [candidates addObject:[clean substringToIndex:lastDot.location]];
    }
    return candidates;
}

// Task185：游戏版本候选集（原文、去 "1." 前缀、二分量补 ".0"）。
static NSArray<NSString *> *ame185_gameCandidates_PLACEHOLDER(NSString *gameVersion) {
    if (gameVersion.length == 0) return @[];
    NSMutableArray<NSString *> *candidates = [NSMutableArray arrayWithObject:gameVersion];
    NSCharacterSet *nonNum = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([gameVersion hasPrefix:@"1."] && gameVersion.length > 2) {
        NSString *stripped = [gameVersion substringFromIndex:2];
        NSArray *parts = [stripped componentsSeparatedByString:@"."];
        BOOL numeric = parts.count >= 1;
        for (NSString *p in parts) {
            if (p.length == 0 || [p rangeOfCharacterFromSet:nonNum].location != NSNotFound) { numeric = NO; break; }
        }
        if (numeric) {
            [candidates addObject:stripped];
            if (parts.count == 1) {
                [candidates addObject:[NSString stringWithFormat:@"%@.0", stripped]];
            }
        }
    }
    // 纯数字二分量（如 26.3、21.0）补一个 ".0" 变体（对应 NeoForge 三分量首段）
    {
        NSArray *parts = [gameVersion componentsSeparatedByString:@"."];
        BOOL numeric = parts.count == 2;
        for (NSString *p in parts) {
            if (p.length == 0 || [p rangeOfCharacterFromSet:nonNum].location != NSNotFound) { numeric = NO; break; }
        }
        if (numeric) {
            [candidates addObject:[NSString stringWithFormat:@"%@.0", gameVersion]];
        }
    }
    return candidates;
}

// Task185：等价匹配主入口（机制与覆盖范围见 utils.h 大注释）。
BOOL ame185_loaderVersionMatchesGameVersion(NSString *loaderVersion, NSString *gameVersion) {
    if (loaderVersion.length == 0 || gameVersion.length == 0) return NO;
    NSArray *gameCandidates = ame185_gameCandidates_PLACEHOLDER(gameVersion);
    if (gameCandidates.count == 0) return NO;

    // 特殊形态一：NeoForge legacy 1.20.1 专用坐标（47.x.y / 含 1.20.1 子串）
    if ([loaderVersion hasPrefix:@"47."] || [loaderVersion containsString:@"1.20.1"]) {
        return [gameCandidates containsObject:@"1.20.1"] || [gameCandidates containsObject:@"20.1"];
    }
    // 特殊形态二：NeoForge 愚人节快照专用（0.25w14craftmine.3）
    if ([loaderVersion hasPrefix:@"0."]) {
        for (NSString *cand in ame185_loaderCandidates([loaderVersion substringFromIndex:2])) {
            if ([gameCandidates containsObject:cand]) return YES;
        }
        return NO;
    }

    // 通用形态 A：复合版本 "<mc>-<forge>"（Forge 全系 + NeoForge legacy）。
    // 注意失配时【不短路】，落穿到形态 B——NeoForge 预发布版本带 "-beta"
    // 后缀（如 "26.3.0.5-beta"），连字符前缀 "26.3.0.5" 不是完整 MC 版本，
    // 需要形态 B 的去后缀 + 去尾分量候选集（→"26.3.0"）才能命中 game
    // "26.3"（其候选集含 "26.3.0"）。单测 Task185-matcher-18 抓出的缺陷。
    NSRange hyphen = [loaderVersion rangeOfString:@"-"];
    if (hyphen.location != NSNotFound && hyphen.location > 0) {
        NSString *mcPortion = [loaderVersion substringToIndex:hyphen.location];
        if ([gameCandidates containsObject:mcPortion]) return YES;
    }

    // 通用形态 B：NeoForge 新旧格式（21.1.5 / 26.3.7 / 26.1.2.71 / 26.3.0.5-beta）
    for (NSString *cand in ame185_loaderCandidates(loaderVersion)) {
        if ([gameCandidates containsObject:cand]) return YES;
    }
    return NO;
}

// ============================================================================
// Task185：JIT 等待成功后的自愈式主队列派发（机制与病历见 utils.h 注释）。
// ============================================================================
void ame185_dispatchToMainSelfHealing(dispatch_block_t block, NSString *label) {
    if (!block) return;
    // delivered 只在主队列（attempt 内）读写；看门狗线程只做轮询读取。
    // arm64 上对齐单字节读写天然原子，volatile 保证编译器不缓存轮询值。
    __block volatile BOOL delivered = NO;
    __block id ame185_obs = nil;
    void (^ame185_cleanup)(void) = ^{
        if (ame185_obs) {
            [[NSNotificationCenter defaultCenter] removeObserver:ame185_obs];
            ame185_obs = nil;
        }
    };
    dispatch_block_t attempt = ^{
        if (delivered) return;
        delivered = YES;
        ame185_cleanup();
        block();
    };
    // 防线①：常规派发（快路径，与旧 dispatch_async(main) 完全等价）。
    dispatch_async(dispatch_get_main_queue(), attempt);
    // 防线②：前台激活瞬间重派。后台被楔死的主线程会在 UIKit 激活流程中
    // 被解锁（动画/键盘相关 XPC 恢复），此刻重派一次即送达。
    ame185_obs = [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                 usingBlock:^(NSNotification *ame185_note) {
        if (delivered) { ame185_cleanup(); return; }
        NSLog(@"[JIT] Task185 self-healing dispatch: refire on foreground (label=%@)", label);
        dispatch_async(dispatch_get_main_queue(), attempt);
    }];
    // 防线③：看门狗（后台队列，窗口 120s 与 JIT 等待对齐）。Task223 升级：
    // 无条件重派（旧版仅前台态重派——后台断言存活的会话里主队列若被楔死，
    // ①已排队但永不执行、②要等回前台；若用户回前台时主【线程】仍卡在
    // present 半途，②的激活通知同样无法送达 = 永久卡死。每 10s 盲重派一次
    // 让 ①的队列里始终有新鲜块等着，delivered 检查保证不会双跑）。
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        for (int ame185_i = 0; ame185_i < 60; ame185_i++) {
            if (delivered) { ame185_cleanup(); return; }
            usleep(2 * 1000 * 1000);
            if (delivered) { ame185_cleanup(); return; }
            if ((ame185_i % 5) == 4) {  // 每 10s 一次（循环节拍 2s）
                NSLog(@"[JIT] Task185 self-healing dispatch: watchdog redispatch #%d (label=%@)",
                      ame185_i + 1, label);
                dispatch_async(dispatch_get_main_queue(), attempt);
            }
        }
        if (!delivered) {
            NSLog(@"[JIT] Task185 self-healing dispatch: NOT delivered after 120s -- main queue wedged (label=%@)", label);
        }
        ame185_cleanup();
    });
}

// ============================================================================
// Task223：后台 GPU 提交禁令的渲染线程驻车（机制与病历见 utils.h 注释）。
// ============================================================================
#include <pthread.h>

static pthread_mutex_t ame223_park_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ame223_park_cond = PTHREAD_COND_INITIALIZER;
static volatile BOOL ame223_parked = NO;
static volatile BOOL ame223_park_logged = NO;

void ame223_bg_park_begin(void) {
    // 主线程（UIKit 生命周期回调）调用。置位即可——渲染线程在下一次
    // 交换边界自会驻车（resign 到 background 之间的转场动画期 GPU 仍合法，
    // 本帧已完成提交 + 下一帧尚未开始 = 安全窗口）。
    pthread_mutex_lock(&ame223_park_mutex);
    if (!ame223_parked) {
        ame223_parked = YES;
        ame223_park_logged = NO;
        NSLog(@"[BG-Park] Task223 render thread parking armed (willResignActive)");
    }
    pthread_mutex_unlock(&ame223_park_mutex);
}

void ame223_bg_park_end(void) {
    pthread_mutex_lock(&ame223_park_mutex);
    if (ame223_parked) {
        ame223_parked = NO;
        pthread_cond_broadcast(&ame223_park_cond);
        NSLog(@"[BG-Park] Task223 render thread released (foreground lifecycle)");
    }
    pthread_mutex_unlock(&ame223_park_mutex);
}

void ame223_bg_park_wait(const char *swapSite) {
    // 交换边界（渲染线程）调用。无驻车时 = 一次原子读 + 立即返回（快路径
    // 开销：一帧一次锁检查，fsr 心跳的 6ms 粒度下不可测）。
    pthread_mutex_lock(&ame223_park_mutex);
    if (ame223_parked) {
        if (!ame223_park_logged) {
            ame223_park_logged = YES;
            NSLog(@"[BG-Park] Task223 render thread PARKED at %s -- no GPU submission while inactive",
                  swapSite ?: "swap");
        }
        while (ame223_parked) {
            // 挂起态由 iOS 掌握（进程冻结时等待自动冻结，恢复后继续等），
            // 不设超时：唯一解锁条件是前台生命周期回调。
            pthread_cond_wait(&ame223_park_cond, &ame223_park_mutex);
        }
        NSLog(@"[BG-Park] Task223 render thread RESUMED at %s", swapSite ?: "swap");
    }
    pthread_mutex_unlock(&ame223_park_mutex);
}

// Task169：JIT 等待轮询的有界版本。病历（装机 485b18c，zink 冷启动首次
// 启动）：三处 invokeAfterJITEnabled 的等待循环都是裸
// while (!isJITEnabled(false)) usleep(200ms)——无超时、无日志、无出路。
// stikjit:// 偶发没把 JIT 开成时（工具未驻留/系统竞态），用户面对的是
// 永不消失的"正在开启 JIT"弹窗 = "启动卡在启动器界面"，只能杀进程。
// 本助手：最长 timeout 秒（超时返回 NO，调用方走超时弹窗/重试），每 10s
// 打一条心跳日志（装机日志从此能看到等待状态而不是静默死等）。
// JIT26 附加等待（JIT26IsLikelyDebuggerKeepAttached）同样复用。
BOOL ame169_waitForJITCondition(BOOL (^condition)(void), NSTimeInterval timeout, NSString *label) {
    NSDate *start = [NSDate date];
    NSDate *ame179_lastIter = [NSDate date];
    // Task181（JIT 二级菜单卡死取证）：成功路径此前完全静默（return YES 不打
    // 任何日志）——病历（afa23a6 装机 latestlog.1）日志止于 "still waiting
    // after 0s"+openURL+entered background，用户回前台后是"等待成功进入
    // 启动"还是"循环冻死"无从分辨。补三针：①首查快照（等待开始时各检测
    // 分量的瞬时值）；②成功一行（含净等待时长）；③循环内进程前台态翻转
    // （UIApplicationState 变化）打点。下一轮装机日志直接钉死断点在哪。
    BOOL ame181_foreground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
    int ame181_csFlags = 0;
    csops(getpid(), 0, &ame181_csFlags, sizeof(ame181_csFlags));
    NSLog(@"[JIT] Task181 %@ wait begin: startForeground=%d traced=%d exn=%d csdbg=%d",
          label ?: @"JIT", ame181_foreground, JIT26DebuggerAttachedViaPtrace(),
          JIT26DebuggerViaExceptionPorts(), (ame181_csFlags & CS_DEBUGGED) != 0);
    for (;;) {
        if (condition()) {
            NSTimeInterval ame181_waited = -[start timeIntervalSinceNow];
            NSLog(@"[JIT] Task181 %@ condition satisfied after %.1fs (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_waited, JIT26DebuggerAttachedViaPtrace(),
                  JIT26DebuggerViaExceptionPorts());
            return YES;
        }
        // Task181：前台态翻转打点（后台回前台是恢复等待的关键事件，此前零观测）。
        BOOL ame181_nowForeground = (UIApplication.sharedApplication.applicationState == UIApplicationStateActive);
        if (ame181_nowForeground != ame181_foreground) {
            NSLog(@"[JIT] Task181 %@ app %s while waiting (traced=%d exn=%d)",
                  label ?: @"JIT", ame181_nowForeground ? "returned to FOREGROUND" : "went to BACKGROUND",
                  JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            ame181_foreground = ame181_nowForeground;
        }
        // Task179：挂起间隙不计入超时预算。
        // 病历（9aacebb 装机 latestlog.2，版本设置二级菜单启动）：stikjit://
        // 把 App 切后台 → iOS 挂起本进程（后台断言宽限未兑现，心跳只打了
        // 0s 一条就冻结）→ 用户在 StikJIT 里启用 JIT 后切回 → NSDate 墙钟
        // 已走过 120s 预算 → 恢复后第一轮循环即 TIMED OUT = 用户实测的
        // "二级菜单启动卡死、最后超时闪退"。修法：两次迭代间隔超过 2s 视为
        // 挂起间隙（正常循环节拍 0.2s），把 start 前推该间隙——挂起多久都
        // 不消耗等待预算；同时落一行间隙日志供装机日志核对。
        NSTimeInterval ame179_gap = -[ame179_lastIter timeIntervalSinceNow];
        if (ame179_gap > 2.0) {
            NSLog(@"[JIT] Task179 %@: suspension gap of %.0fs excluded from timeout budget (app was backgrounded/suspended; wall-clock no longer burns the wait)",
                  label ?: @"JIT", ame179_gap);
            start = [start dateByAddingTimeInterval:ame179_gap];
        }
        ame179_lastIter = [NSDate date];
        NSTimeInterval waited = -[start timeIntervalSinceNow];
        if (waited >= timeout) {
            NSLog(@"[JIT] Task169 %@ wait TIMED OUT after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
            return NO;
        }
        if (fmod(waited, 10.0) < 0.2) {
            NSLog(@"[JIT] Task169 %@: still waiting after %.0fs (traced=%d exn=%d)",
                  label ?: @"JIT", waited, JIT26DebuggerAttachedViaPtrace(), JIT26DebuggerViaExceptionPorts());
        }
        usleep(1000 * 200);
    }
}

#ifndef P_TRACED
#define P_TRACED 0x00000800 /* process is being traced by a debugger (ptrace) */
#endif

// Ask the kernel whether a ptrace relationship is currently alive for this
// process.  P_TRACED is set in kinfo_proc for the entire lifetime of a
// debugger attach and is cleared the moment the debugger detaches, so it is
// the accurate "debugger still here" signal for debuggers that attach to an
// already-running process.
BOOL JIT26DebuggerAttachedViaPtrace(void) {
    struct kinfo_proc info;
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return NO;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// Detect a debugger that holds this task via Mach exception ports instead of
// (or in addition to) ptrace.  lldb/debugserver on iOS attach with
// ptrace(PT_ATTACH) to obtain the task port and then PT_DETACH while KEEPING
// the port -- after that P_TRACED reads 0 even though the debugger is fully
// alive and still receiving EXC_BREAKPOINT (which is exactly how the JIT26
// brk #0x69 / brk #0xf00d breakpoints get serviced).  A live task-level
// handler for BREAKPOINT/SOFTWARE is therefore the reliable "JIT26 debugger
// in place" signal once CS_DEBUGGED is set.
// NOTE: this only reports TASK-level ports.  The in-process hardware-breakpoint
// dlopen redirect (main_hook.m, non-TXM path) registers THREAD-level ports,
// which do not show up here -- so this cannot mistake our own handler for an
// external debugger.  And JIT26IsLikelyDebuggerKeepAttached() is only ever
// consulted on TXM devices, where main_hook's path is not used at all.
BOOL JIT26DebuggerViaExceptionPorts(void) {
    exception_mask_t masks[EXC_TYPES_COUNT];
    exception_handler_t handlers[EXC_TYPES_COUNT];
    exception_behavior_t behaviors[EXC_TYPES_COUNT];
    thread_state_flavor_t flavors[EXC_TYPES_COUNT];
    mach_msg_type_number_t count = EXC_TYPES_COUNT;
    kern_return_t kr = task_get_exception_ports(mach_task_self(),
                                                EXC_MASK_BREAKPOINT | EXC_MASK_SOFTWARE,
                                                masks, &count, handlers, behaviors, flavors);
    if (kr != KERN_SUCCESS) {
        return NO;
    }
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (handlers[i] != MACH_PORT_NULL) {
            return YES;
        }
    }
    return NO;
}

BOOL JIT26IsLikelyDebuggerKeepAttached(void) {
    // getppid() returns launchd's PID (1) unless a debugger SPAWNED this
    // process (debugserver-style parent).  This is the check Hynis-JE uses.
    if (getppid() != 1) {
        return YES;
    }
    // StikJIT / SideJIT instead attach to an ALREADY-RUNNING app by pid
    // (the launcher hands its own getpid() over via the stikjit:// URL),
    // which leaves ppid == 1 for the whole session even though the debugger
    // is actively attached and handling JIT26 breakpoints.  Worse, the
    // enabler may exit after enabling, getting the app re-parented to
    // launchd (ppid 1) while CS_DEBUGGED stays set -- so ppid alone
    // misclassifies a fully working JIT session as "no debugger attached".
    // That caused the permanent "JIT not enabled" status label and a
    // redundant stikjit:// script round trip on every game launch.
    // Fall back to the live ptrace flag: it is set exactly while a debugger
    // is attached, so this neither misses the attach flow nor weakens the
    // "debugger really detached" case (P_TRACED returns to 0 on detach).
    if (JIT26DebuggerAttachedViaPtrace()) {
        return YES;
    }
    // lldb/debugserver detach (PT_DETACH) as soon as it holds the task port
    // and then keep serving EXC_BREAKPOINT through Mach exception ports with
    // P_TRACED == 0 -- measured on-device as CS_DEBUGGED=1 ppid=1 traced=0
    // with the JIT26 mapping request succeeding moments later.  Treat a live
    // task-level BREAKPOINT/SOFTWARE handler as "debugger attached": it is
    // the entity that must service the brk #0x69 traps, which is the whole
    // point of this check.  See JIT26DebuggerViaExceptionPorts() for why the
    // app's own handlers cannot false-positive here.
    return JIT26DebuggerViaExceptionPorts();
}

BOOL isJITEnabled(BOOL checkCSFlags) {
    // Fast path: these entitlements/policies mean JIT is available without
    // needing CS_DEBUGGED:
    // - dynamic-codesigning: per-app JIT entitlement
    // - jb.pmap_cs.custom_trust: TrollStore pmap trust chain — grants
    //   kernel-level JIT on unjailbroken devices with NO debugger attached,
    //   so CS_DEBUGGED is NOT set and must not be required (this is what
    //   made isJITEnabled() return NO on TrollStore installs and trigger
    //   unnecessary stikjit:// / apple-magnifier:// redirects)
    // - isJailbroken: jailbroken devices
    if (!checkCSFlags && (getEntitlementValue(@"dynamic-codesigning") ||
                          getEntitlementValue(@"jb.pmap_cs.custom_trust") ||
                          isJailbroken)) {
        return YES;
    }

    // NOTE: the tail below deliberately matches upstream semantics exactly
    // (cf. 31d83637 which first simplified it this way): CS_DEBUGGED alone
    // decides.  A TXM "debugger keep-attached" gate reintroduced by 9c6cdb53
    // broke status display AND the launch path on StikJIT/SideJIT/NB-style
    // tools: they attach externally (ppid stays 1, P_TRACED unset by the
    // time we look, no task-level exception ports), yet the JIT26 mapping
    // service keeps working -- measured on-device as CS_DEBUGGED=1 ppid=1
    // traced=0 exn=0 with "[JIT26] Got JIT mapping from debugger" succeeding
    // right after.  Gating on debugger-attach state misreported such fully
    // working sessions as "JIT not enabled" and forced a redundant
    // stikjit:// round trip on every launch.  The helpers
    // JIT26IsLikelyDebuggerKeepAttached() / JIT26DebuggerAttachedViaPtrace()
    // / JIT26DebuggerViaExceptionPorts() are still exported for diagnostics.
    int flags;
    csops(getpid(), 0, &flags, sizeof(flags));
    return (flags & CS_DEBUGGED) != 0;
}

void openLink(UIViewController* sender, NSURL* link) {
    if (NSClassFromString(@"SFSafariViewController") == nil) {
        NSData *data = [link.absoluteString dataUsingEncoding:NSUTF8StringEncoding];
        CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
        [filter setValue:data forKey:@"inputMessage"];
        UIImage *image = [UIImage imageWithCIImage:filter.outputImage scale:1.0 orientation:UIImageOrientationUp];
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(300, 300), NO, 0.0);
        CGRect frame = CGRectMake(0, 0, 300, 300);
        [image drawInRect:frame];
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:frame];
        imageView.image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();

        UIAlertController* alert = [UIAlertController alertControllerWithTitle:nil
            message:link.absoluteString
            preferredStyle:UIAlertControllerStyleAlert];

        UIViewController *vc = UIViewController.new;
        vc.view = imageView;
        [alert setValue:vc forKey:@"contentViewController"];

        UIAlertAction* doneAction = [UIAlertAction actionWithTitle:localize(@"Done", nil) style:UIAlertActionStyleCancel handler:nil];
        [alert addAction:doneAction];
        [sender presentViewController:alert animated:YES completion:nil];
    } else {
        SFSafariViewController *vc = [[SFSafariViewController alloc] initWithURL:link];
        [sender presentViewController:vc animated:YES completion:nil];
    }
}

NSMutableDictionary* parseJSONFromFile(NSString *path) {
    NSError *error;

    NSString *content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (content == nil) {
        NSLog(@"[ParseJSON] Error: could not read %@: %@", path, error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }

    NSData* data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error) {
        NSLog(@"[ParseJSON] Error: could not parse JSON: %@", error.localizedDescription);
        return @{@"NSErrorObject": error}.mutableCopy;
    }
    return dict;
}

NSError* saveJSONToFile(NSDictionary *dict, NSString *path) {
    // TODO: handle rename
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:NSJSONWritingPrettyPrinted error:&error];
    if (jsonData == nil) {
        return error;
    }
    BOOL success = [jsonData writeToFile:path options:NSDataWritingAtomic error:&error];
    if (!success) {
        return error;
    }
    return nil;
}

// Task223 上游同步（upstream 3a2116c05 / Flux 同款）：该错误是否意味着设备
// 根本连不上网。值得穷举：原来微软登录只认 NSURLErrorDataNotAllowed（应用
// 被关蜂窝数据这一种窄形态），而最常见的离线形态——飞行模式、无 Wi-Fi——
// 是 NSURLErrorNotConnectedToInternet，反而走不进离线分支直接报错。
BOOL isConnectivityError(NSError *error) {
    if (![error.domain isEqualToString:NSURLErrorDomain]) return NO;
    switch (error.code) {
        case NSURLErrorNotConnectedToInternet:   // 飞行模式、无 Wi-Fi、无信号
        case NSURLErrorDataNotAllowed:           // 应用被关蜂窝数据
        case NSURLErrorNetworkConnectionLost:    // 请求中途掉线
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
        case NSURLErrorResourceUnavailable:
            return YES;
        default:
            return NO;
    }
}

NSString* localize(NSString* key, NSString* comment) {
    // 检查用户是否在设置中手动选择了语言
    NSString *langOverride = getPrefObject(@"general.app_language");
    NSBundle *targetBundle = nil;

    if (langOverride && ![langOverride isEqualToString:@"system"]) {
        // 用户手动选择了特定语言，使用对应的 .lproj bundle
        NSString *lprojPath = [NSBundle.mainBundle pathForResource:langOverride ofType:@"lproj"];
        if (lprojPath) {
            targetBundle = [NSBundle bundleWithPath:lprojPath];
        }
    }

    NSString *value;
    if (targetBundle) {
        value = [targetBundle localizedStringForKey:key value:key table:nil];
        // 如果用户选择的语言缺少该 key，回退到英文
        if ([value isEqualToString:key]) {
            NSString *enPath = [NSBundle.mainBundle pathForResource:@"en" ofType:@"lproj"];
            NSBundle *enBundle = [NSBundle bundleWithPath:enPath];
            value = [enBundle localizedStringForKey:key value:nil table:nil];
            if ([value isEqualToString:key]) {
                // Task191：zh-Hans 兜底（en.lproj 曾因一行值内未转义引号整表解析
                // 失败，用户手动切换语言后全界面显示 "i18n_str_N" 裸键名——任何
                // 单一语言表损坏/缺键时，退到最全的 zh-Hans 表而不是把键名
                // 直接暴露给用户。
                NSString *zhPath = [NSBundle.mainBundle pathForResource:@"zh-Hans" ofType:@"lproj"];
                NSBundle *zhBundle = [NSBundle bundleWithPath:zhPath];
                value = [zhBundle localizedStringForKey:key value:nil table:nil];
                if ([value isEqualToString:key]) {
                    // 英文也没有，尝试 UIKit 系统翻译
                    value = [[NSBundle bundleWithIdentifier:@"com.apple.UIKit"] localizedStringForKey:key value:nil table:nil];
                }
            }
        }
    } else {
        // 跟随系统语言（默认行为）
        value = NSLocalizedString(key, nil);
        if (![NSLocale.preferredLanguages[0] isEqualToString:@"en"] && [value isEqualToString:key]) {
            NSString* path = [NSBundle.mainBundle pathForResource:@"en" ofType:@"lproj"];
            NSBundle* languageBundle = [NSBundle bundleWithPath:path];
            value = [languageBundle localizedStringForKey:key value:nil table:nil];
            if ([value isEqualToString:key]) {
                // Task191：zh-Hans 兜底（同上，系统语言表损坏/缺键时的防线）
                NSString *zhPath = [NSBundle.mainBundle pathForResource:@"zh-Hans" ofType:@"lproj"];
                NSBundle *zhBundle = [NSBundle bundleWithPath:zhPath];
                value = [zhBundle localizedStringForKey:key value:nil table:nil];
                if ([value isEqualToString:key]) {
                    value = [[NSBundle bundleWithIdentifier:@"com.apple.UIKit"] localizedStringForKey:key value:nil table:nil];
                }
            }
        }
    }

    // Task192：localize() 永不返回 nil 加固。
    // 病历（956ea9b 装机 latestlog.1）：insertObject:atIndex: object cannot be
    // nil 崩溃 + 数组字面量/pickList 均以 localize() 结果为元素——上方的
    // UIKit 系统翻译层是唯一可能返回 nil 的出口：
    //   ① bundleWithIdentifier:@"com.apple.UIKit" 查找失败 → [nil ...] = nil；
    //   ② 各中间层 [value isEqualToString:key] 对 nil receiver 恒为 NO，
    //     "未命中"分支永不触发——nil 一路穿透返回。
    // 修复：任何出口为 nil/空时回落为 key 本身（与既有"裸键显示"语义一致，
    // 用户至少看到 i18n 键名而不是崩溃/空串）。
    if (value == nil || [value length] == 0) {
        return key;
    }

    return value;
}

void customNSLog(const char *file, int lineNumber, const char *functionName, NSString *format, ...)
{
    va_list ap; 
    va_start (ap, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:ap];
    printf("%s", [body UTF8String]);
    if (![format hasSuffix:@"\n"]) {
        printf("\n");
    }
    va_end (ap);
}

CGFloat MathUtils_dist(CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
    const CGFloat x = (x2 - x1);
    const CGFloat y = (y2 - y1);
    return (CGFloat) hypot(x, y);
}

//Ported from https://www.arduino.cc/reference/en/language/functions/math/map/
CGFloat MathUtils_map(CGFloat x, CGFloat in_min, CGFloat in_max, CGFloat out_min, CGFloat out_max) {
    return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

CGFloat dpToPx(CGFloat dp) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return dp * screenScale;
}

CGFloat pxToDp(CGFloat px) {
    CGFloat screenScale = [[UIScreen mainScreen] scale];
    return px / screenScale;
}

void setButtonPointerInteraction(UIButton *button) {
    button.pointerInteractionEnabled = YES;
    button.pointerStyleProvider = ^ UIPointerStyle* (UIButton* button, UIPointerEffect* proposedEffect, UIPointerShape* proposedShape) {
        UITargetedPreview *preview = [[UITargetedPreview alloc] initWithView:button];
        return [NSClassFromString(@"UIPointerStyle") styleWithEffect:[NSClassFromString(@"UIPointerHighlightEffect") effectWithPreview:preview] shape:proposedShape];
    };
}

__attribute__((noinline,optnone,naked))
void* JIT26CreateRegionLegacy(size_t len) {
    asm("brk #0x69 \n"
        "ret");
}

// Task91：SIGTRAP 安全网。见 utils.h 注释——brk #0x69 无人应答时裸函数
// 直接 SIGTRAP 致死（用户实测"开启 JIT 后闪退"），这里在调用窗口内捕获
// 并返回 NULL，把必死崩溃转成调用方的优雅报错；调试器正常应答时走
// 调试器例外端口/ptrace，本信号处理器不会被触发，行为不变。
static sigjmp_buf g_jit26TrapEnv;
static volatile sig_atomic_t g_jit26TrapArmed = 0;

static void JIT26TrapCatch(int sig) {
    if (!g_jit26TrapArmed) {
        // 不属于本安全网的 SIGTRAP：恢复默认语义原样致死，不吞异常
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }
    g_jit26TrapArmed = 0;
    siglongjmp(g_jit26TrapEnv, 1);
}

void* JIT26CreateRegionLegacySafe(size_t len) {
    struct sigaction sa, oldsa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = JIT26TrapCatch;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_NODEFER;
    sigaction(SIGTRAP, &sa, &oldsa);

    void *result = NULL;
    if (sigsetjmp(g_jit26TrapEnv, 1) == 0) {
        g_jit26TrapArmed = 1;
        result = JIT26CreateRegionLegacy(len);
        g_jit26TrapArmed = 0;
    } else {
        result = NULL;
    }
    sigaction(SIGTRAP, &oldsa, NULL);
    return result;
}

__attribute__((noinline,optnone,naked))
void* JIT26PrepareRegion(void *addr, size_t len) {
    asm("mov x16, #1 \n"
        "brk #0xf00d \n"
        "ret");
}
__attribute__((noinline,optnone,naked))
void BreakSendJITScript(char* script, size_t len) {
   asm("mov x16, #2 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26SetDetachAfterFirstBr(BOOL value) {
   asm("mov x16, #3 \n"
       "brk #0xf00d \n"
       "ret");
}
__attribute__((noinline,optnone,naked))
void JIT26PrepareRegionForPatching(void *addr, size_t size) {
   asm("mov x16, #4 \n"
       "brk #0xf00d \n"
       "ret");
}
void JIT26SendJITScript(NSString* script) {
    NSCAssert(script, @"Script must not be nil");
    BreakSendJITScript((char*)script.UTF8String, script.length);
}

BOOL DeviceCanCreateRXMap(void) {
    uint32_t *map = mmap(NULL, getpagesize(), PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (map == MAP_FAILED) {
        NSLog(@"DeviceCanCreateRXMap: mmap failed: %s", strerror(errno));
        return NO;
    }
    *map = 0xFFFFFFFF;
    int ret = mprotect(map, getpagesize(), PROT_READ | PROT_EXEC) | mprotect(map, getpagesize(), PROT_READ | PROT_EXEC);
    munmap(map, getpagesize());
    return ret == 0;
}

static BOOL DeviceHasTXMReal(void) {
    DIR *d = opendir("/private/preboot");
    if (!d) {
        // /private/preboot is no longer readable on iOS 26.6 and iOS 27.
        // Fall back to a conservative hardware/OS heuristic.
        NSUInteger (*MGGetSInt64Answer)(NSString *) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
        if (MGGetSInt64Answer == NULL) {
            if (@available(iOS 19.0, *)) return YES;
            return NO;
        }
        NSUInteger chipID = MGGetSInt64Answer(@"ChipID");
        switch (chipID) {
            case 0x8020: // A12
            case 0x8027: // A12X/Z
                return NO;
            case 0x8030: // A13
            case 0x8101: // A14
            case 0x8103: // M1
                if (@available(iOS 27.0, *)) return YES;
                return NO;
            default:
                if (@available(iOS 19.0, *)) return YES;
                return NO;
        }
    }
    struct dirent *dir;
    char txmPath[PATH_MAX];
    while ((dir = readdir(d)) != NULL) {
        if(strlen(dir->d_name) == 96) {
            snprintf(txmPath, sizeof(txmPath), "/private/preboot/%s/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", dir->d_name);
            break;
        }
    }
    closedir(d);
    return access(txmPath, F_OK) == 0;
}

BOOL DeviceHasTXM(void) {
    return DeviceHasJITFlags(JIT_FLAG_HAS_TXM);
}

JITFlags DeviceGetJITFlags(BOOL refresh) {
    static os_unfair_lock cacheLock = OS_UNFAIR_LOCK_INIT;
    static JITFlags cachedFlags = 0;
    static BOOL cacheInitialized = NO;

    os_unfair_lock_lock(&cacheLock);
    if (refresh || !cacheInitialized) {
        JITFlags flags = 0;
        const char *s = getenv("JIT_FLAGS");
        if (s) {
            if (s[0] == '0' && tolower(s[1]) == 'b') {
                flags = strtoul(s + 2, NULL, 2);
            } else {
                flags = strtoul(s, NULL, 0);
            }
            NSLog(@"[JIT] Using overridden JIT flags: 0x%X", flags);
        } else {
            if (@available(iOS 26.0, *)) {
                flags |= JIT_FLAG_IS_IOS_26;
                if (!DeviceCanCreateRXMap()) {
                    flags |= JIT_FLAG_FORCE_MIRRORED;
                }
            }
            if (DeviceHasTXMReal()) {
                flags |= JIT_FLAG_HAS_TXM;
            }
        }

        cachedFlags = flags;
        cacheInitialized = YES;
    }
    JITFlags result = cachedFlags;
    os_unfair_lock_unlock(&cacheLock);
    return result;
}

BOOL DeviceHasJITFlags(JITFlags flags) {
    return (DeviceGetJITFlags(NO) & flags) == flags;
}

void dismissModalViewController(UIViewController *viewController) {
    [viewController.navigationController dismissViewControllerAnimated:YES completion:nil];
}

// ============================================================================
// Task173: 进程内存天花板（Jetsam 安全堆顶）。
// 病历（惊变100天/Zombie Invade 100 Days 装机会话 latestlog.old）：
// 实例内存滑到 7165MB（= 0.8 × 物理内存，ProfileSettings 的 maxMemory 公式），
// 244 mods 的 1.20.1 Forge 重包加载 53 秒后进程被静默击杀（无 hs_err、无
// exit 标记 = Jetsam SIGKILL）——堆 7165MB + JVM 原生侧（metaspace/代码缓存/
// GC 结构）+ 渲染器表面合计超过 iOS 进程上限。0.8 × 物理内存对 iOS 是
// 错误公式：带 increased-memory-limit 权限的进程上限约为物理内存的 75%，
// 没权限时更低。
// 修复：用 os_proc_available_memory()（iOS 13+，返回“距离 Jetsam 击杀还剩
// 多少字节”的权威值）推算安全堆顶。调用时机越早越准（启动器冷启时进程
// 自身驻留小，读数接近真实上限）。
// ============================================================================
int ame173_safeHeapCeilingMB(void) {
    static int cachedCeilingMB = -1;
    if (cachedCeilingMB > 0) {
        return cachedCeilingMB;
    }
    int ceilingMB = 0;
    {
        // os_proc_available_memory 在 <libproc.h>（iOS 13+）。返回 0 表示不支持
        // （老系统/模拟器），此时退回保守比例：物理内存 × 0.6。
        uint64_t avail = os_proc_available_memory();
        if (avail > 0) {
            int availMB = (int)(avail >> 20);
            // 剩余可用 − 1.2GB 原生预留（JVM 非堆 + 渲染面 + 系统开销）
            // = 可安全承诺的 -Xmx。
            // Task223 上游同步（upstream 862f8b48d [fix/1024-floor]）：权威读数
            // 路径不再做 1024 下限。iPhone X（3GB，extended VA）实测：
            // available=1807MB -> 安全堆顶 607MB，旧代码把 607 强抬到 1024，
            // 等于把钳制整个架空——偏高的设置值"未超 1024" -> 不钳 ->
            // footprint 爬过顶后被 jetsam SIGKILL（无崩溃记录、latestlog 凭空
            // 断在字体加载 = SIGKILL 特征）。本 fork 用户主力 ≥4GB 时下限
            // 无副作用，但 3GB 设备上它把"必死的 SIGKILL"换成"可控的 GC 抖动"。
            // 权威路径宁可要小堆：堆小只是慢，超顶是死。
            ceilingMB = availMB - 1200;
            NSLog(@"[Task173] safe heap ceiling: os_proc_available_memory=%dMB -> Xmx ceiling %dMB (native reserve 1200MB, no floor on authoritative path)",
                  availMB, ceilingMB);
        }
    }
    if (ceilingMB <= 0) {
        long long physMB = (NSProcessInfo.processInfo.physicalMemory >> 20);
        ceilingMB = (int)(physMB * 0.6);
        if (ceilingMB < 1024) ceilingMB = 1024;
        NSLog(@"[Task173] safe heap ceiling: fallback 60 percent of physical = %dMB (phys=%lldMB)",
              ceilingMB, physMB);
    }
    cachedCeilingMB = ceilingMB;
    return ceilingMB;
}

// ============================================================================
// Task141: launch-time memory resolution (see utils.h for the contract).
// Instance slider (profile allocatedMemory) first; untouched profiles fall
// back to the pre-Task141 auto ratio (java.auto_ram UI retired).
// Task173: 任何来源的内存值（实例滑条/自动比例）都要过安全堆顶钳制——
// 惊变100天会话的 7165MB 直接击穿 Jetsam 上限，启动前钳制并留日志/提示。
// ============================================================================
int ame141_currentLaunchAllocMem(void) {
    int mem = 0;
    @try {
        NSDictionary *profile = [PLProfiles current].selectedProfile;
        NSInteger profMem = [profile[@"allocatedMemory"] integerValue];
        if (profMem > 0) {
            NSLog(@"[Task141] launch memory from instance profile: %ld MB", (long)profMem);
            mem = (int)profMem;
        }
    } @catch (NSException *e) {
        NSLog(@"[Task141] instance memory read failed (%@), falling back to auto ratio", e);
    }
    if (mem <= 0) {
        // Task223 上游同步（upstream 455c3f5a0，Flux 同款修复）：jetsam 上限
        // 有两条抬升路径——越狱的 com.apple.private.memorystatus，以及带
        // profile 签名的 com.apple.developer.kernel.increased-memory-limit。
        // 只查前者会把正确 entitled 的包按无 entitlement 的 0.25 算，
        // 小堆在加载界面静默 GC 空转。
        BOOL raisedCeiling = getEntitlementValue(@"com.apple.private.memorystatus")
            || getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit");
        CGFloat autoRatio = raisedCeiling ? 0.5 : 0.25;
        mem = (int)roundf((NSProcessInfo.processInfo.physicalMemory >> 20) * autoRatio);
        NSLog(@"[Task141] launch memory from auto ratio: %d MB", mem);
    }
    // 防呆下限（upstream 同款）：滑条存档损坏读出极小值时保住 MC 最低可启动堆。
    if (mem < 256) mem = 256;
    // Task223 上游同步（upstream 455c3f5a0 后续 [fix/memorystatus-gate]）：
    // 带 com.apple.private.memorystatus entitlement 的构建【不钳】——
    // SurfaceViewController 的 updateJetsamControl 会用 memorystatus_control
    // 把 jetsam 任务限额提到 mem + 1024（越狱设备实证可设）。此时按冷启动
    // os_proc_available_memory 算出的堆顶钳制反而有害：用户手动调大的实例
    // 内存会被压回未抬升前的旧口径，制造 limit 偏低的低顶。无 entitlement
    // （限额提不上去，只能吃系统默认）时保持钳制作为安全网；
    // increased-memory-limit 路径的抬升会被 os_proc_available_memory 权威
    // 读数如实反映，钳制依然准确。AMETHYST_MEM_NO_CLAMP=1 为调试逃生门。
    const char *ame223_noClamp = getenv("AMETHYST_MEM_NO_CLAMP");
    BOOL ame223_canRaiseJetsamLimit = getEntitlementValue(@"com.apple.private.memorystatus");
    if (ame223_canRaiseJetsamLimit) {
        NSLog(@"[Task173] memorystatus entitlement present -- jetsam limit will be raised to %d MB (allocmem %d + 1024 native); heap clamp bypassed",
              mem + 1024, mem);
        return mem;
    }
    if (ame223_noClamp && ame223_noClamp[0] == '1') {
        NSLog(@"[Task173] AMETHYST_MEM_NO_CLAMP=1 -- heap clamp bypassed (debug escape hatch)");
        return mem;
    }
    // Task173：Jetsam 安全钳制（惊变100天根修）。
    int ame173_ceiling = ame173_safeHeapCeilingMB();
    if (mem > ame173_ceiling) {
        NSLog(@"[Task173] launch memory %dMB exceeds safe ceiling %dMB -- clamping (profile value preserved on disk)",
              mem, ame173_ceiling);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NMToast showMessage:[NSString stringWithFormat:
                localize(@"ame189.utils.mem_clamped", nil),
                mem, ame173_ceiling, mem, ame173_ceiling]];
        });
        mem = ame173_ceiling;
    }
    return mem;
}

// ============================================================================
// Task 187（iPhone 刘海/挖孔适配）：见 utils.h 声明处注释。
// iPad（主力机型）恒返回 0，布局零回归；iPhone 横屏返回对应侧的安全区
// 水平内缩（刘海/挖孔/灵动岛侧 47~59pt，另一侧通常 0）。旋转 180° 后
// 左右互换，调用方在 traitCollectionDidChange / viewSafeAreaInsetsDidChange
// 里重取即可。
// ============================================================================
double ame187_iphoneNotchInset(UIView *view, BOOL isLeading) {
    if (view == nil) return 0.0;
    if (view.traitCollection.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return 0.0;
    UIEdgeInsets insets = view.safeAreaInsets;
    // 横屏下左右内缩即设备物理左右（启动器锁定横屏，Info.plist Task187）；
    // 竖屏兜底沿用 top（用户理论上不会见到：方向已锁横屏）。
    if (view.bounds.size.width < view.bounds.size.height) {
        return isLeading ? (double)insets.top : (double)insets.bottom;
    }
    return isLeading ? (double)insets.left : (double)insets.right;
}

// ============================================================================
// Task 188（安装器目录杂散文件自愈）：递归建目录，路径上任意一级"目录位
// 置被同名普通文件占用"（历史安装失败残留 / APFS 不允许文件目录同名共存）
// 时自动移除该杂散文件后重试创建。
// 病历（15fddc2 latestlog.old.1，NeoForge 26.1.2.109 安装）：
//   libraries/net/neoforged/neoforge/26.1.2.109 处存在杂散普通文件
//   → universal jar 的解压（extractAllMavenEntries failed to write）与
//     下载（Failed to create directory ... 已存在同名文件）双双失败，
//   → 但安装流程继续走完并报 "Installation completed successfully"
//   → 启动时 FML 报 "The NeoForge jar is missing"（用户反馈"缺失文件"）。
// ForgeDirectInstaller 的 ensureDirectoryExists: 只查最终一层；本助手
// 沿完整祖先链逐级清理（深层目录首次创建时中间层也可能是杂散文件）。
// ============================================================================
BOOL ame188_ensureDirectoryHealed(NSString *path) {
    if (path.length == 0) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDir]) {
        if (isDir) return YES;   // 已是目录，幂等成功
        // 最终路径本身是普通文件 = 挡路杂散文件（调用方要的是目录）
        NSError *rmErr = nil;
        if (![fm removeItemAtPath:path error:&rmErr]) {
            NSLog(@"[Task188] cannot remove stray file at target %@: %@", path, rmErr.localizedDescription);
            return NO;
        }
        NSLog(@"[Task188] stray file at target removed: %@", path);
    }
    // 尝试直接创建（快路径：无阻塞时零额外 stat）
    NSError *createErr = nil;
    if ([fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&createErr]) {
        return YES;
    }
    // 慢路径：逐级检查祖先链，清理"目录位上的普通文件"后重试
    NSLog(@"[Task188] directory create failed (%@), scanning ancestors for stray files...", createErr.localizedDescription);
    NSArray *comps = path.pathComponents;
    NSString *cur = @"";
    for (NSString *c in comps) {
        if ([c isEqualToString:@"/"]) { cur = @"/"; continue; }
        // stringByAppendingPathComponent 对根目录后拼接会正确去重斜杠
        cur = [cur stringByAppendingPathComponent:c];
        BOOL cd = NO;
        BOOL ex = [fm fileExistsAtPath:cur isDirectory:&cd];
        if (ex && !cd) {
            NSError *rmErr = nil;
            if ([fm removeItemAtPath:cur error:&rmErr]) {
                NSLog(@"[Task188] stray file blocking ancestor removed: %@", cur);
            } else {
                NSLog(@"[Task188] failed removing ancestor stray %@: %@", cur, rmErr.localizedDescription);
            }
        }
    }
    return [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
}
