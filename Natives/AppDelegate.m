#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "ios_uikit_bridge.h"
#import "utils.h"
#import "AFNetworking.h"
#import "MinecraftResourceDownloadTask.h"
#import "LauncherPreferences.h"

// SurfaceViewController
extern dispatch_group_t fatalExitGroup;

@interface AppDelegate ()
@property (nonatomic, copy) void (^backgroundURLSessionCompletionHandler)(void);
@end

@implementation AppDelegate

#pragma mark - UISceneSession lifecycle

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
    // Task189：异常处理器晚装复挂。main.m 预初始化里装的
    // NSSetUncaughtExceptionHandler 被 LiveContainer 宿主（其共享框架在
    // invokeAppMain 前后装载自己的崩溃处理链）覆盖——c3f4623 会话的
    // insertObject:atIndex: nil 崩溃走的是系统默认输出（latestlog 只有
    // "*** Terminating ..." 裸地址栈，无我方 handler 的符号化栈与
    // fatal trace），证据 = 装了等于没装。此处 + SceneDelegate willConnect
    // 双点重挂（后装者生效），把符号化崩溃捕获抢回来：任何 NSException
    // 崩溃下一次装机日志直接给出 App 符号栈。
    {
        extern void uncaughtExceptionHandler(NSException *exception);
        NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
        NSLog(@"[AppDelegate] Task189: uncaught-exception handler re-armed after container setup");
    }

    // 一次性迁移旧版全局下载源偏好到分类镜像策略键（幂等，早于任何 UI 读取偏好）
    migrateDownloadSourcePreferences();

    // Task 144：旧包名并存检测（仅日志取证，零 UI 噪音）。
    // 用户报告设备上出现"2 个一模一样的版本"：commit 9659740a（2026-07-24）
    // 把包名从 org.angelauramcremastered.amethyst 改为 com.air-devs.prisma，
    // iOS 按包名视为两个不同 App —— 新 IPA 不再覆盖旧装，主屏并存双图标
    // （旧图标 = 迁移前的旧代码 + 旧偏好容器，行为自然不同）。此非本仓库
    // bug，检测到旧包时打日志便于装机日志分诊；删除旧图标即消除重复。
    {
        Class ame144_lsw = NSClassFromString(@"LSApplicationWorkspace");
        if (ame144_lsw) {
            @try {
                id ame144_ws = [(id)ame144_lsw performSelector:NSSelectorFromString(@"defaultWorkspace")];
                SEL ame144_sel = NSSelectorFromString(@"applicationIsInstalled:");
                if (ame144_ws && [ame144_ws respondsToSelector:ame144_sel]) {
                    BOOL ame144_old = (BOOL)[ame144_ws performSelector:ame144_sel
                                                            withObject:@"org.angelauramcremastered.amethyst"];
                    if (ame144_old) {
                        NSLog(@"[Prisma] Task144: legacy bundle 'org.angelauramcremastered.amethyst' (pre-rename AngelAuraAmethyst) still installed alongside this app -- two identical-looking home-screen icons; the OLD icon can be deleted (its container is separate from this app's data)");
                    }
                    // ★ Task259（清单 4）：包名迁移 com.air-devs.air →
                    //   com.prisma-devs.prisma 的并存取证（log-only，同 Task144
                    //   语义）。检测到旧包时提示数据导出/导入迁移链路：
                    //   旧 App（air 包名）导出 → 新 App（prisma 包名）导入。
                    BOOL ame259_air = (BOOL)[ame144_ws performSelector:ame144_sel
                                                           withObject:@"com.air-devs.air"];
                    if (ame259_air) {
                        NSLog(@"[Prisma] Task259: legacy bundle 'com.air-devs.air' still installed alongside this app -- data does NOT carry over (iOS containers are per-bundle-id); export from the OLD app via its data-export, import into THIS app, then delete the old icon");
                    }
                }
            } @catch (NSException *ame144_e) {
                NSLog(@"[Prisma] Task144: legacy bundle detection unavailable (%@)", ame144_e.name);
            }
        }
    }
    // Task 77：一次性迁移默认触控布局出厂值 default.json -> custom.json
    //（幂等，哨兵键保证只执行一次；用户自选的其他布局不受影响）
    migrateDefaultControlPref();
    // Task 130：一次性治愈 MobileGlues 性能默认值（v5.1.0 持久化的旧默认
    // 0/32 压制 Task129d 新默认 1/128；幂等，仅匹配旧默认值，自选值不动）
    // Task 167 修订：本挂载点只在【新建】场景会话时被 UIKit 调用，既有
    // 会话的设备永不再触发（Task166 的 DSA 反向迁移因此从未执行）——
    // 常跑调用点已搬到 main.m（toggleIsolatedPref 之后），此处保留作为
    // 新装机/场景重建时的最早触发点，哨兵保证两处幂等互斥。
    ame130_migrateMgPerfDefaults();
    // Called when a new scene session is being created.
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
    // Called when the user discards a scene session.
}

- (void)applicationWillTerminate:(UIApplication *)application {
    if (fatalExitGroup != nil) {
        dispatch_group_leave(fatalExitGroup);
        fatalExitGroup = nil;
    }
}

#pragma mark - Background URL Session

- (void)application:(UIApplication *)application handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
    if (![identifier isEqualToString:kMinecraftResourceDownloadBackgroundSessionIdentifier]) {
        if (completionHandler) {
            completionHandler();
        }
        return;
    }

    self.backgroundURLSessionCompletionHandler = completionHandler;

    AFURLSessionManager *manager = [MinecraftResourceDownloadTask sharedBackgroundSessionManager];
    __weak typeof(self) weakSelf = self;
    [manager setDidFinishEventsForBackgroundURLSessionBlock:^(NSURLSession *session) {
        if (weakSelf.backgroundURLSessionCompletionHandler) {
            weakSelf.backgroundURLSessionCompletionHandler();
            weakSelf.backgroundURLSessionCompletionHandler = nil;
        }
    }];
}

#pragma mark - Orientation Support

- (UIInterfaceOrientationMask)application:(UIApplication *)application supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    // Force landscape only
    return UIInterfaceOrientationMaskLandscape;
}

@end
