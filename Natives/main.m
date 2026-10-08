#import <mach-o/dyld.h>
#import <spawn.h>
#import <sys/sysctl.h>
#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "customcontrols/CustomControlsUtils.h"
#import "HostManagerBridge.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "UIKit+hook.h"
#import "config.h"

#include <libgen.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <errno.h>
#include "utils.h"
#include "codesign.h"

// Task 43：shaderc 编译 fork server（实现于 Natives/shaderc_sandbox.m，
// CMake 同时编进本可执行文件）。在 init_redirectStdio 之后调用——见
// main() 内注释。
int ame_sb_fork_server_early(void);

#define CS_PLATFORM_BINARY 0x4000000
#define PT_TRACE_ME 0
#define PT_DETACH 11 
int ptrace(int, pid_t, caddr_t, int);
#define fm NSFileManager.defaultManager
extern char** environ;

void printEntitlementAvailability(NSString *key) {
    NSLog(@"* %@: %@", key, getEntitlementValue(key) ? @"YES" : @"NO");
}

void uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"Uncaught exception: %@", exception.description);
    NSLog(@"Call stack: %@", exception.callStackSymbols);
    // Task 27：ObjC 未捕获异常也直写 fatal_trace（同 abort/exit 取证通道），
    // 避免 latestlog 管道丢尾导致现场丢失
    NSString *reasonStr = [NSString stringWithFormat:@"NSException: %@ — %@",
        exception.name, exception.reason ?: @"(no reason)"];
    ame_write_fatal_trace(reasonStr.UTF8String);
    usleep(10000);
    handle_fatal_exit(SIGABRT);
}

bool init_checkForsubstrated() {
    // Please kindly tell pwn20wnd that he sucks
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    size_t size;
    int st = sysctl(mib, miblen, NULL, &size, NULL, 0);
    struct kinfo_proc * process = NULL;
    struct kinfo_proc * newprocess = NULL;
    do {
        size += size / 10;
        newprocess = realloc(process, size);
        if (!newprocess){
            if (process){
                free(process);
            }
            return nil;
        }
        process = newprocess;
        st = sysctl(mib, miblen, process, &size, NULL, 0);
    } while (st == -1 && errno == ENOMEM);
    if (st == 0){
        if (size % sizeof(struct kinfo_proc) == 0){
            int nprocess = size / sizeof(struct kinfo_proc);
            if (nprocess){
                for (int i = nprocess - 1; i >= 0; i--){
                    if(strcmp(process[i].kp_proc.p_comm,"substrated") == 0) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

bool init_checkForJailbreak() {
    if (NSProcessInfo.processInfo.macCatalystApp) {
        // macOS doesn't automatically enable JIT.
        return false;
    } else if (init_checkForsubstrated()) {
        return true;
    }

    // Check if posix_spawn is hooked
    for (int i=0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i),"/usr/lib/pspawn_payload-stg2.dylib") == 0 ||
            strstr(_dyld_get_image_name(i),"/systemhook.dylib") != NULL) {
            return true;
        }
    }

    // Check if we have platform bit set
    uint32_t flags;
    csops(0, CS_OPS_STATUS, &flags, sizeof(flags));
    if ((flags & CS_PLATFORM_BINARY) != 0) {
        return true;
    }

    return opendir("/Applications") != NULL;
}

void init_logDeviceAndVer(char *argument) {
    // Amethyst version
    // Task223（清单第 23 项“log 里遗留旧名字”）：横幅先报本 fork 身份
    //（Prisma，Task218 改名后的仓库名），上游出处行保持致谢语义不变。
    NSLog(@"[Pre-Init] Prisma Launcher (fork of Amethyst iOS Remastered) INIT!");
    NSLog(@"[Pre-Init] Fork: https://github.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher");
    NSLog(@"[Pre-Init] Upstream: https://github.com/herbrine8403/Amethyst-iOS-MyRemastered");
    NSLog(@"[Pre-Init] Please try not to post this log of the remastered launcher to the original GitHub Issues for help.");
    NSLog(@"[Pre-Init] Version: %@", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"], CONFIG_TYPE);
    NSLog(@"[Pre-Init] Commit: %s (%s)", CONFIG_COMMIT, CONFIG_BRANCH);
    
    NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
    const char *type;
    if (!access(tsPath.UTF8String, F_OK)) {
        type = "TrollStore";
    } else if (isJailbroken) {
        type = "Jailbroken";
    } else {
        type = "Unjailbroken";
    }
    setenv("POJAV_DETECTEDINST", type, 1);
    
    NSLog(@"[Pre-Init] Device: %@", [HostManager GetModelName]);
    NSLog(@"[Pre-Init] %@ (%s)", UIDevice.currentDevice.completeOSVersion, type);
    
    NSLog(@"[Pre-init] Entitlements availability:");
    printEntitlementAvailability(@"com.apple.developer.kernel.extended-virtual-addressing");
    printEntitlementAvailability(@"com.apple.developer.kernel.increased-memory-limit");
    printEntitlementAvailability(@"com.apple.private.security.no-sandbox");
    // JIT-relevant entitlements: TrollStore grants jb.pmap_cs.custom_trust
    // (kernel-level JIT without a debugger), which isJITEnabled() fast-paths
    // on. dynamic-codesigning is the per-app JIT entitlement (iOS 18+).
    // Logging them here settles "did the launcher even see my JIT entitlement"
    // questions from latestlog alone.
    printEntitlementAvailability(@"jb.pmap_cs.custom_trust");
    printEntitlementAvailability(@"dynamic-codesigning");
}

void init_redirectStdio() {
    if (getenv("LOG_TO_CONSOLE") != NULL) {
        NSLog(@"[Pre-init] LOG_TO_CONSOLE is set, not logging to latestlog.txt");
        return;
    }

    NSLog(@"[Pre-init] Starting logging STDIO to latestlog.txt\n");

    NSString *home = @(getenv("POJAV_HOME"));
    NSString *currName = [home stringByAppendingPathComponent:@"latestlog.txt"];
    NSString *oldName = [home stringByAppendingPathComponent:@"latestlog.old.txt"];
    // Task 171：异常死亡证据保全（多人游戏偶发崩溃的日志总被轮换吃掉）。
    // 病历：用户报"多人游戏有时候会崩溃，参考上一个提交的 log.old.txt"，
    // 但该文件是干净的 26.3 多人会话（mysv.dpdns.org，60fps，干净
    // exit(0)）——崩溃会话的 latestlog 在下一次启动的"先删后移"轮换里
    // 只能存活一代，用户再玩一局就永远丢了（本会话日志即被覆盖）。
    // 保全员：轮换前读旧 latestlog.txt 尾部 8KB，若没有 hooked_exit 的
    // "exit(N) called" 终止标记（正常退出/退出码非零都会留痕；原生
    // SIGSEGV/SIGKILL 类死亡无标记），把它复制为 latestlog.crash.txt
    // （只保留最近一份，不参与轮换链）。下次崩溃后从应用容器直接取回
    // 完整现场。
    {
        NSString *crashName = [home stringByAppendingPathComponent:@"latestlog.crash.txt"];
        if ([fm fileExistsAtPath:currName]) {
            NSData *tail = nil;
            NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:currName];
            if (h) {
                unsigned long long len = [h seekToEndOfFile];
                unsigned long long off = (len > 8192) ? (len - 8192) : 0;
                [h seekToFileOffset:off];
                tail = [h readDataToEndOfFile];
                [h closeFile];
            }
            BOOL hasExitMarker = NO;
            if (tail) {
                NSString *tailStr = [[NSString alloc] initWithData:tail
                                                           encoding:NSUTF8StringEncoding];
                hasExitMarker = (tailStr != nil) && [tailStr containsString:@") called"];
            }
            if (!hasExitMarker) {
                NSError *cpErr = nil;
                [fm removeItemAtPath:crashName error:nil];
                if ([fm copyItemAtPath:currName toPath:crashName error:&cpErr]) {
                    NSLog(@"[Pre-init] Task171: previous session died without an exit marker -- log preserved to latestlog.crash.txt (unclean-death forensics)");
                } else {
                    NSLog(@"[Pre-init] Task171: crash-log preservation failed: %@", cpErr.localizedDescription);
                }
            }
        }
    }
    [fm removeItemAtPath:oldName error:nil];
    [fm moveItemAtPath:currName toPath:oldName error:nil];

    [fm createFileAtPath:currName contents:nil attributes:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:currName];

    if (!file) {
        NSLog(@"[Pre-init] Error: failed to open %@", currName);
        assert(0 && "Failed to open latestlog.txt. Check oslog for more details.");
    }

    setvbuf(stdout, 0, _IOLBF, 0); // make stdout line-buffered
    setvbuf(stderr, 0, _IONBF, 0); // make stderr unbuffered

    /* create the pipe and redirect stdout and stderr */
    static int pfd[2];
    pipe(pfd);
    dup2(pfd[1], fileno(stdout));
    dup2(pfd[1], fileno(stderr));

    /* create the logging thread */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        static BOOL filteredSessionID;
        ssize_t rsize;
        char buf[2048];
        // Task 27 加固：
        // ① read() EINTR 重试 —— 信号中断曾可能让读取线程意外退出，
        //    此后全部日志丢失（latestlog 冻结在退出点）。
        // ② 每次迭代包 @try —— 单次异常不再杀死整个读取循环。
        // ③ Session ID 审查改为定界 splice（见内注释），不再丢 chunk 尾数据。
        while (YES) {
            do {
                rsize = read(pfd[0], buf, sizeof(buf)-1);
            } while (rsize < 0 && errno == EINTR);
            if (rsize <= 0) break;
            @try {
            if (rsize < 2048) {
                buf[rsize] = '\0';
            }
            // Filter out Session ID here
            // Task 27 修复：旧实现 strcpy(censor) 后 rsize=strlen(buf)，
            // ① chunk 内审查点之后的既有数据全部丢掉（写文件长度被截短）；
            // ② 匹配落在 chunk 末尾时会越界写入陈旧缓冲区。
            // 改为定界 splice：仅当结束符 ')' 在本 chunk 内才替换，尾部数据
            // 整体前移，rsize 只缩短实际长度差；ID 跨 chunk 则留待下一块。
            if (!filteredSessionID) {
                static const char kCensor[] = "(Session ID is <censored>)";
                char *sessionStr = strstr(buf, "(Session ID is ");
                if (sessionStr) {
                    ptrdiff_t off = sessionStr - buf;
                    const char *closeParen = memchr(sessionStr, ')', (size_t)(rsize - off));
                    if (closeParen) {
                        size_t idLen = (size_t)(closeParen - sessionStr) + 1;
                        size_t censorLen = sizeof(kCensor) - 1;
                        size_t tailLen = (size_t)rsize - (size_t)off - idLen;
                        if (censorLen != idLen) {
                            memmove(sessionStr + censorLen, closeParen + 1, tailLen);
                        }
                        memcpy(sessionStr, kCensor, censorLen);
                        rsize = (ssize_t)((size_t)off + censorLen + tailLen);
                        filteredSessionID = true;
                    }
                }
            }
            if (canAppendToLog) {
                // canAppendToLog=YES 时，通过 appendToLog: 同时更新 UI 表格和发送通知
                [PLLogOutputView appendToLog:@(buf)];
            } else {
                // canAppendToLog=NO 时（默认状态，用户未打开日志面板），
                // PLLogOutputView 不会更新 UI，但 LanPortDetector 仍需要实时检测
                // MC "对局域网开放"端口。直接在后台线程发送通知，
                // LanPortDetector 的处理是线程安全的（processLogLine: 是无状态的，
                // setPort:source: 内部 dispatch_async 到主线程）。
                //
                // 关键修复：之前 canAppendToLog=NO 时完全不发送通知，
                // 导致 LanPortDetector 无法实时检测端口，用户先"对局域网开放"
                // 再点"当房主"时无法生成分享代码。
                NSString *logString = @(buf);
                NSArray *lines = [logString componentsSeparatedByCharactersInSet:
                    [NSCharacterSet newlineCharacterSet]];
                for (NSString *line in lines) {
                    if (line.length > 0) {
                        [[NSNotificationCenter defaultCenter] postNotificationName:@"PLLogOutputLineNotification"
                                                                            object:nil
                                                                          userInfo:@{@"line": line}];
                    }
                }
            }
            [file writeData:[NSData dataWithBytes:buf length:rsize]];
            [file synchronizeFile];
            } @catch (NSException *e) {
                // 读取线程绝不能因单次异常死亡：死亡 = 后续日志全部丢失（Task 26 教训）
                NSLog(@"[Pre-init] latestlog reader exception: %@", e);
            }
        }
        [file closeFile];
    });

    // We can start catching exception right now
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
}

void init_setupAccounts() {
    NSString *controlPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"accounts"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
}

// Task92：预启动主动导出 UniversalJIT26.js 到 $POJAV_HOME（Documents）。
// 背景：StikDebug 侧的 JIT26 脚本必须与本启动器的 brk 协议严格配套
// （legacy 0x69 = x0 大小/返回地址，Universal + Extension 才是完整实现）。
// 此前 Documents 副本只在「检测到 legacy 脚本」的启动失败路径里补拷，
// 用户得先失败一次才能在 StikDebug 的 Assign Script 里选到文件。改为
// 每次启动导出（内容一致则跳过写盘），旧版 StikDebug（无按应用名自动
// 分配 universal.js）也能提前手动指派正确脚本，避免协议不配。
void init_exportJIT26Script(void) {
    NSString *inBundle = [NSBundle.mainBundle pathForResource:@"UniversalJIT26" ofType:@"js"];
    if (!inBundle) {
        NSLog(@"[Pre-init] UniversalJIT26.js missing from bundle — skip export");
        return;
    }
    NSString *dst = [NSString stringWithFormat:@"%s/UniversalJIT26.js", getenv("POJAV_HOME")];
    NSData *bundleData = [NSData dataWithContentsOfFile:inBundle];
    NSData *existing = [NSData dataWithContentsOfFile:dst];
    if (bundleData && [bundleData isEqualToData:existing]) {
        return; // 副本已与 IPA 内置版本一致，避免无谓写盘
    }
    if ([fm createFileAtPath:dst contents:bundleData attributes:nil]) {
        NSLog(@"[Pre-init] Exported Universal JIT script to Documents (StikDebug Assign-Script ready)");
    } else {
        NSLog(@"[Pre-init] Failed to export Universal JIT script to %@", dst);
    }
}

void init_setupCustomControls() {
    NSString *controlPath = [@(getenv("POJAV_HOME")) stringByAppendingPathComponent:@"controlmap"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
    generateAndSaveDefaultControl();
    generateAndSaveCustomControl();
    NSString *gamepadControlPath = [controlPath stringByAppendingPathComponent:@"gamepads"];
    [fm createDirectoryAtPath:gamepadControlPath withIntermediateDirectories:NO attributes:nil error:nil];
    generateAndSaveDefaultControlForGamepad();

    // ★ Task230（反馈 #3：持续奔跑没有效果）：存量布局死按钮迁移。装机日志
    //   （39633e4 latestlog.old:5667-5671）实锤用户布局里的"常用\n操作键"
    //   keycodes 全零（Task229 UNBOUND 诊断触发，用户按它期待奔跑却毫无
    //   反应）。出货布局已改为绑定 Left Control 341（sprint 键；配合已开启
    //   的 toggleSprint 即"持续奔跑"），但 generateAndSaveCustomControl 只在
    //   文件缺失时拷贝——存量安装拿不到新 bundle。此处对已安装的
    //   custom.json / classic.json / large-buttons.json 做同款修补：仅当
    //   按钮名含"常用"、四个键码全零时改为 341（用户自绑过的永不动）。
    //   Task231 修复（装机“打开闪退”根因，684915a 实测 latestlog 停在
    //   Task226 symlink 行）：(a) 递归 block 必须 __block——非 __block 自动
    //   变量在字面量求值时按值快照，此刻 ame230_walk 尚未赋值（ARC 零初始
    //   化为 nil），block 捕获 nil 后首次递归调用读 nil->invoke =
    //   EXC_BAD_ACCESS（硬件异常，@try 接不住）→ 无痕 SIGKILL 形态闪退；
    //   顶层 dict 必有 keys，首次递归必触发，每次启动必崩。
    //   (b) 解析必须 MutableContainers——options:0 返回不可变
    //   __NSDictionaryI，setValue:forKey: 抛 NSInvalidArgumentException
    //   被 @catch 吞掉，迁移永远失效（③白修）。
    @try {
        NSArray<NSString *> *ame230_files = @[@"custom.json", @"classic.json", @"large-buttons.json"];
        for (NSString *ame230_fn in ame230_files) {
            NSString *ame230_p = [controlPath stringByAppendingPathComponent:ame230_fn];
            NSData *ame230_data = [NSData dataWithContentsOfFile:ame230_p];
            if (ame230_data == nil) continue;
            id ame230_obj = [NSJSONSerialization JSONObjectWithData:ame230_data
                                                            options:NSJSONReadingMutableContainers
                                                              error:nil];
            if (![ame230_obj isKindOfClass:[NSDictionary class]]) continue;
            __block BOOL ame230_changed = NO;
            __block void (^ame230_walk)(id) = ^(id node) {
                if ([node isKindOfClass:[NSDictionary class]]) {
                    NSString *ame230_nm = [node objectForKey:@"name"];
                    NSArray *ame230_kc = [node objectForKey:@"keycodes"];
                    if ([ame230_nm isKindOfClass:[NSString class]] &&
                        [ame230_nm containsString:@"常用"] &&
                        [ame230_kc isKindOfClass:[NSArray class]] && ame230_kc.count >= 1) {
                        BOOL ame230_allZero = YES;
                        for (id k in ame230_kc) {
                            if ([k isKindOfClass:[NSNumber class]] && [k intValue] != 0) { ame230_allZero = NO; break; }
                        }
                        if (ame230_allZero) {
                            NSMutableArray *ame230_new = [ame230_kc mutableCopy];
                            ame230_new[0] = @341;
                            [node setValue:ame230_new forKey:@"keycodes"];
                            ame230_changed = YES;
                        }
                    }
                    for (NSString *ame230_k in [node allKeys]) ame230_walk([node objectForKey:ame230_k]);
                } else if ([node isKindOfClass:[NSArray class]]) {
                    for (id v in (NSArray *)node) ame230_walk(v);
                }
            };
            ame230_walk(ame230_obj);
            if (ame230_changed) {
                NSData *ame230_out = [NSJSONSerialization dataWithJSONObject:ame230_obj
                                                                    options:NSJSONWritingPrettyPrinted error:nil];
                if (ame230_out != nil && [ame230_out writeToFile:ame230_p options:NSDataWritingAtomic error:nil]) {
                    NSLog(@"[Pre-init] Task230: sprint dead-button migrated to Left Control 341 in %@", ame230_fn);
                }
            }
        }
    } @catch (NSException *ame230_e) {
        NSLog(@"[Pre-init] Task230: layout migration exception (%@)", ame230_e);
    }
}

void init_setupMultiDir() {
    NSString *multidir = getPrefObject(@"general.game_directory");
    if (multidir.length == 0) {
        multidir = @"default";
        setPrefObject(@"general.game_directory", multidir);
        NSLog(@"[Pre-init] Game directory was not set. Defaulting to %@ for future use.\n", multidir);
    } else {
        NSLog(@"[Pre-init] Restored game directory preference (%@)\n", multidir);
    }

    const char *home = getenv("POJAV_HOME");
    NSString *lasmPath = [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", home];
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", home, multidir];


    NSArray *dirsToCreate = @[
        [NSString stringWithFormat:@"%s/.demo", home],
        [NSString stringWithFormat:@"%s/java_runtimes", home],
        lasmPath.stringByDeletingLastPathComponent,
        multidirPath
    ];
    for (NSString *dir in dirsToCreate) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    // ★ Task226（反馈 #5：上游软件更新到本软件，数据要能正常识别）：
    // 旧代码无条件 removeItemAtPath:lasmPath——若这里是【真实目录】
    //（上游老版本 / 更新前残留的游戏数据：saves/mods/config 等全在里面），
    // 整目录被永久删除 = 用户数据无声蒸发。改为三态：
    //   ① 已是符号链接 → 原样保留（幂等重指也不做，目标一致性由下面保证）；
    //   ② 真实目录且有内容 → 先把内容【迁移】进 instances/<multidir>
    //     （仅补缺失条目、绝不覆盖；PCL VER-ISOLATE 哲学：只挪不删），
    //     迁移完成后才把原目录改名归档（.lasm-legacy-backup）再建链接；
    //   ③ 空目录 → 删除建链接（旧行为）。
    // 迁移清单与隔离向导（ProfileSettings ame217_items）同口径：游戏读写
    // 的用户数据，排除共享层（assets/libraries/versions 由安装器管理）。
    BOOL ame226_isSymlink = NO;
    NSDictionary *lasmAttrs = [fm attributesOfItemAtPath:lasmPath error:nil];
    if (lasmAttrs && [lasmAttrs fileType] == NSFileTypeSymbolicLink) {
        ame226_isSymlink = YES;
    }
    if (!ame226_isSymlink && lasmAttrs) {
        // 真实目录：数内容判空
        NSArray *lasmEntries = [fm contentsOfDirectoryAtPath:lasmPath error:nil];
        NSUInteger ame226_legacyCount = lasmEntries.count;
        if (ame226_legacyCount > 0) {
            NSLog(@"[Pre-init] Task226 legacy real game dir detected at %@ (%lu entries) -- migrating into instances/%@ (no data loss)", lasmPath, (unsigned long)ame226_legacyCount, multidir);
            NSArray *ame226_items = @[
                @"saves", @"mods", @"config", @"resourcepacks", @"shaderpacks",
                @"options.txt", @"servers.dat", @"servers.dat_old", @"usercache.json",
                @"screenshots", @"crash-reports", @"logs", @"hotbar.nbt",
                @"options~", @"realms_persistence.json"
            ];
            NSUInteger ame226_moved = 0;
            for (NSString *ame226_item in ame226_items) {
                NSString *src = [lasmPath stringByAppendingPathComponent:ame226_item];
                if (![fm fileExistsAtPath:src]) continue;
                NSString *dst = [multidirPath stringByAppendingPathComponent:ame226_item];
                if ([fm fileExistsAtPath:dst]) continue;  // 目标已有 → 绝不覆盖
                if ([fm moveItemAtPath:src toPath:dst error:nil]) {
                    ame226_moved++;
                }
            }
            // 剩余未识别条目也一并搬走（上游可能带插件数据等）；versions/
            // assets/libraries 等共享层保留原位（链接后经 instances 访问）。
            for (NSString *ame226_left in [fm contentsOfDirectoryAtPath:lasmPath error:nil]) {
                NSString *src = [lasmPath stringByAppendingPathComponent:ame226_left];
                NSString *dst = [multidirPath stringByAppendingPathComponent:ame226_left];
                if ([fm fileExistsAtPath:dst]) continue;
                [fm moveItemAtPath:src toPath:dst error:nil];
            }
            NSLog(@"[Pre-init] Task226 legacy migration done: %lu tracked + leftovers moved (watched-items=%lu)", (unsigned long)ame226_moved, (unsigned long)ame226_items.count);
            // 归档空壳（保名不保数据；万一还有残留条目则保留为备份目录）
            NSString *ame226_archive = [lasmPath stringByAppendingString:@"-lasm-legacy-backup"];
            [fm removeItemAtPath:ame226_archive error:nil];
            if (![fm moveItemAtPath:lasmPath toPath:ame226_archive error:nil]) {
                [fm removeItemAtPath:lasmPath error:nil];
            }
        } else {
            [fm removeItemAtPath:lasmPath error:nil];
        }
    }
    // 符号链接：重指到当前 multidir（实例切换后老链接可能指向旧实例）
    if (ame226_isSymlink) {
        NSString *curTarget = [fm destinationOfSymbolicLinkAtPath:lasmPath error:nil];
        BOOL sameTarget = NO;
        if (curTarget.length > 0) {
            NSString *resolvedCur = [[lasmPath.stringByDeletingLastPathComponent
                stringByAppendingPathComponent:curTarget]
                stringByResolvingSymlinksInPath];
            sameTarget = [resolvedCur isEqualToString:multidirPath.stringByResolvingSymlinksInPath];
        }
        if (!sameTarget) {
            [fm removeItemAtPath:lasmPath error:nil];
            [fm createSymbolicLinkAtPath:lasmPath withDestinationPath:multidirPath error:nil];
            NSLog(@"[Pre-init] Task226 game-dir symlink re-pointed to instances/%@", multidir);
        }
    } else {
        [fm removeItemAtPath:lasmPath error:nil];
        [fm createSymbolicLinkAtPath:lasmPath withDestinationPath:multidirPath error:nil];
    }
    [fm changeCurrentDirectoryPath:lasmPath];
    setenv("POJAV_GAME_DIR", lasmPath.UTF8String, 1);
}

void init_setupResolvConf() {
    // Write known DNS servers to the config
    NSString *path = [NSString stringWithFormat:@"%s/resolv.conf", getenv("POJAV_HOME")];
    if (![fm fileExistsAtPath:path]) {
        [@"nameserver 8.8.8.8\n"
         @"nameserver 8.8.4.4"
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void init_setupHomeDirectory() {
    setenv("HOME", [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject.path.stringByDeletingLastPathComponent.UTF8String, 1);
    NSString *homeDir;
    NSError *homeError;
    
    BOOL isNotSandboxed = [@(getenv("HOME")).lastPathComponent isEqualToString:NSUserName()];
    homeDir = [NSString stringWithFormat:@"%s/Documents%@", getenv("HOME"),
        isNotSandboxed ? @"/AngelAuraAmethyst":@""];

    if (![fm fileExistsAtPath:homeDir] ) {
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:NO attributes:nil error:&homeError];
    }
    
    if(homeError != nil) {
        // TODO: Persistent storage
        homeError = nil;
        homeDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).lastObject;
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:YES attributes:nil error:&homeError];
    }
    
    setenv("POJAV_HOME", realpath(homeDir.UTF8String, NULL), 1);
}

int main(int argc, char *argv[]) {
    // Task 42：shaderc 编译沙箱 helper 子进程分支。必须在【一切】launcher/JVM/
    // hook 初始化之前分支（pJLI_Launch、ptrace JIT 分支都在其后）。父进程的
    // shaderc shim 通过 posix_spawn 以 AME_SHADERC_SANDBOX=1 + AME_SB_FD=3
    // 拉起本进程；此路径只有 dlopen(libshaderc_impl) + 32MB 栈编译循环，
    // 不触碰 UIKit/JavaLauncher/偏好设置。EOF（父退出）即干净返回。
    if (getenv("AME_SHADERC_SANDBOX") != NULL) {
        extern int ame_shaderc_sandbox_child_main(void);
        return ame_shaderc_sandbox_child_main();
    }

    if (pJLI_Launch) {
        return pJLI_Launch(argc, (const char **)argv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
    }

    if (!isJITEnabled(true) && argc == 2) {
        NSLog(@"calling ptrace(PT_TRACE_ME)");
        // Child process can call to PT_TRACE_ME
        // then both parent and child processes get CS_DEBUGGED
        int ret = ptrace(PT_TRACE_ME, 0, 0, 0);
        return ret;
    }

    setenv("BUNDLE_PATH", dirname(argv[0]), 1);
    isJailbroken = init_checkForJailbreak();
    init_setupHomeDirectory();
    init_redirectStdio();
    // Task 43：在此 fork shaderc 编译服务器（不 exec）。位置选择的三个理由：
    //   1) stderr 已接 latestlog 管道——子进程取证（sb_clog raw write）直接
    //      经管道落 latestlog.txt（父进程的日志读取线程活着，跨进程收走）；
    //   2) 进程此刻只有主线程 + 日志读取线程（read() 阻塞中，不持 malloc/
    //      stdio/dyld 锁）——子进程可安全 dlopen impl + malloc；
    //   3) JVM/JIT/hook/ANGLE 均未诞生——进程内堆踩踏的“外部写入者”在子
    //      进程地址空间里从未运行，编译环境天然纯净。
    // 失败（沙盒禁 fork 等）只打日志，launcher 照常继续（shim 自动降级）。
    ame_sb_fork_server_early();
    init_logDeviceAndVer(argv[0]);

    loadPreferences(NO);
    init_hookFunctions();
    init_hookUIKitConstructor();

    debugLogEnabled = getPrefBool(@"general.debug_logging");
    NSLog(@"[Debugging] Debug log enabled: %@", debugLogEnabled ? @"YES" : @"NO");

    init_setupResolvConf();
    init_setupMultiDir();
    toggleIsolatedPref(NO);
    // Task 167：MobileGlues DSA 黑屏反向迁移的【常跑】调用点。原挂载点
    // application:configurationForConnectingSceneSession: 只在新建场景会话时
    // 触发（既有会话设备永不再调——60+ 份历史上传日志零出现该回调内日志，
    // Task166 迁移因此在装机设备上从未执行，DSA 存量 1 压制新默认，
    // GLES/4.0 黑屏修复失效）。本点位于 toggleIsolatedPref 之后（读到的是
    // 生效存储）、任何偏好消费者（JavaLauncher/设置页）之前；哨兵保证
    // 幂等，与 AppDelegate 的保留调用点互为冗余。装机锚点：
    // "[Preferences] Task167 MG DSA black-screen migration ran (stored=1, flipped=1)"。
    ame130_migrateMgPerfDefaults();
    // Task211：CF 源迁 Modrinth + 垃圾 Key 清理（同位置的幂等一次性迁移；
    // 装机锚点 "[Preferences] Task211: ..."，详见 LauncherPreferences.h）
    ame211_migrateCfSourceToModrinth();
    // Task212：holy gl4es 退役——存量渲染器值迁移到 ZL2 经典版（须在
    // updateCurrent 之前，profile 解析拿到的即迁移后的值）。
    ame212_migrateHolyGl4es();
    [PLProfiles updateCurrent];
    init_setupAccounts();
    init_setupCustomControls();
    init_exportJIT26Script();

    // If sandbox is disabled, W^X JIT can be enabled by Amethyst itself
    if (!isJITEnabled(true) && getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        NSLog(@"[Pre-init] no-sandbox: YES, trying to enable JIT");
        int pid;
        int ret = posix_spawnp(&pid, argv[0], NULL, NULL, (char *[]){argv[0], "", NULL}, environ);
        if (ret == 0) {
            // Cleanup child process
            waitpid(pid, NULL, WUNTRACED);
            ptrace(PT_DETACH, pid, NULL, 0);
            kill(pid, SIGTERM);
            wait(NULL);

            if (isJITEnabled(true)) {
                NSLog(@"[Pre-init] JIT has been enabled with PT_TRACE_ME");
            } else {
                NSLog(@"[Pre-init] Failed to enable JIT: unknown reason");
            }
        } else {
            NSLog(@"[Pre-init] Failed to enable JIT: posix_spawn() failed errno %d", errno);
        }
    }

    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
