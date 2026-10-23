//
//  AmePluginRuntime.m
//  Amethyst
//
//  Task318：插件运行时实现。
//
//  线程模型：单条串行队列（ame318_plugin_queue）承载全部 JSContext 求值
//  与事件回调——JSC 的 context 非线程安全，串行化是硬约束；启动链侧的
//  dispatch 调用（任意线程）只做入队，不阻塞游戏启动。
//  事件回调把 handler(JSValue) 持引用保留在 dispatch_block 内，插件停止
//  时全表清空（运行中卸载由详情页先 stop 再 uninstall 的两步语义兜底）。
//

#import "AmePluginRuntime.h"
#import "AmePluginManager.h"
#import "AmePluginBridge.h"
#import "utils.h" // localize

#import <JavaScriptCore/JavaScriptCore.h>

#pragma mark - 内部状态

/// pluginId → JSContext（运行中插件表）。
static NSMutableDictionary<NSString *, JSContext *> *s_ame318_contexts = nil;
/// pluginId → {event → [JSValue handler]}（事件订阅表）。
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableArray<JSValue *> *>> *s_ame318_handlers = nil;
/// pluginId → 最近 JS 异常文本。
static NSMutableDictionary<NSString *, NSString *> *s_ame318_lastError = nil;
/// 状态保护（运行表/订阅表/错误表的互斥；JS 求值本身走串行队列）。
static NSRecursiveLock *s_ame318_lock = nil;
/// JS 求值与事件回调的串行队列。
static dispatch_queue_t s_ame318_queue = nil;

static void ame318_ensure_state(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_ame318_contexts = [NSMutableDictionary dictionary];
        s_ame318_handlers = [NSMutableDictionary dictionary];
        s_ame318_lastError = [NSMutableDictionary dictionary];
        s_ame318_lock = [NSRecursiveLock new];
        s_ame318_queue = dispatch_queue_create("ame318.plugin.queue", DISPATCH_QUEUE_SERIAL);
    });
}

/// 在串行队列上分发一个事件（异步；快照当前订阅，handler 报错不连坐）。
static void ame318_dispatch_event(NSString *event, NSDictionary *payload) {
    ame318_ensure_state();
    dispatch_async(s_ame318_queue, ^{
        [s_ame318_lock lock];
        // 快照（事件回调里插件可能再订阅/停止，避免边遍历边改）。
        NSMutableArray<JSValue *> *targets = [NSMutableArray array];
        for (NSString *pid in s_ame318_handlers) {
            NSMutableArray<JSValue *> *list = s_ame318_handlers[pid][event];
            if (list.count) [targets addObjectsFromArray:list];
        }
        [s_ame318_lock unlock];
        for (JSValue *handler in targets) {
            @try {
                [handler callWithArguments:payload ? @[payload] : @[]];
            } @catch (NSException *e) {
                NSLog(@"[Ame318] event '%@' handler threw: %@", event, e.reason);
            }
        }
    });
}

@implementation AmePluginRuntime

#pragma mark - 单插件生命周期

/// 拉起单插件（串行队列上执行；异常一律记录不抛出）。
static void ame318_start_plugin_locked(NSString *pluginId, AmePluginManifest *manifest) {
    if (!manifest) return;
    // 幂等：已在运行先停。
    ame318_stop_plugin_locked(pluginId);

    JSContext *ctx = [[JSContext alloc] init];
    ctx.name = [NSString stringWithFormat:@"ame318:%@", pluginId];
    ctx.exceptionHandler = ^(JSContext *c, JSValue *exception) {
        NSString *msg = exception ? exception.toString : @"(unknown exception)";
        NSLog(@"[Ame318][%@] JS exception: %@", pluginId, msg);
        [s_ame318_lock lock];
        s_ame318_lastError[pluginId] = msg ?: @"";
        [s_ame318_lock unlock];
    };

    // 权限门面注入（事件订阅回灌到订阅表）。
    [AmePluginBridge installFacadeInContext:ctx pluginId:pluginId eventSink:^
        (NSString *event, JSValue *handler) {
        [s_ame318_lock lock];
        NSMutableDictionary<NSString *, NSMutableArray<JSValue *> *> *perPlugin =
            s_ame318_handlers[pluginId];
        if (!perPlugin) {
            perPlugin = [NSMutableDictionary dictionary];
            s_ame318_handlers[pluginId] = perPlugin;
        }
        NSMutableArray<JSValue *> *list = perPlugin[event];
        if (!list) {
            list = [NSMutableArray array];
            perPlugin[event] = list;
        }
        [list addObject:handler];
        [s_ame318_lock unlock];
    }];

    // 入口求值。
    NSString *entryPath = [[[AmePluginManager shared] pluginDirForId:pluginId]
                           stringByAppendingPathComponent:manifest.entry];
    NSString *script = [NSString stringWithContentsOfFile:entryPath
                                                 encoding:NSUTF8StringEncoding error:nil];
    if (script.length == 0) {
        NSString *msg = [NSString stringWithFormat:localize(@"ame318.error.entry_unreadable", nil), manifest.entry];
        NSLog(@"[Ame318][%@] %@", pluginId, msg);
        s_ame318_lastError[pluginId] = msg;
        return;
    }
    s_ame318_contexts[pluginId] = ctx;
    [ctx evaluateScript:script withSourceURL:[NSURL fileURLWithPath:entryPath]];
    NSLog(@"[Ame318] plugin %@ started (entry %@)", pluginId, manifest.entry);
}

/// 停止单插件（串行队列上执行；幂等）。
static void ame318_stop_plugin_locked(NSString *pluginId) {
    [s_ame318_lock lock];
    [s_ame318_contexts removeObjectForKey:pluginId];
    [s_ame318_handlers removeObjectForKey:pluginId];
    [s_ame318_lock unlock];
}

#pragma mark - 公共 API

+ (void)bootAll {
    ame318_ensure_state();
    dispatch_async(s_ame318_queue, ^{
        [s_ame318_lock lock];
        // 全停再全起（重入安全；详情页启停走单插件路径不受影响）。
        NSArray *running = [s_ame318_contexts.allKeys copy];
        [s_ame318_lock unlock];
        for (NSString *pid in running) ame318_stop_plugin_locked(pid);

        for (AmePluginManifest *manifest in [[AmePluginManager shared] installedPlugins]) {
            if (![[AmePluginManager shared] isEnabled:manifest.pluginId]) continue;
            [s_ame318_lock lock];
            ame318_start_plugin_locked(manifest.pluginId, manifest);
            [s_ame318_lock unlock];
        }
        NSLog(@"[Ame318] bootAll complete: %lu plugin context(s) live",
              (unsigned long)s_ame318_contexts.count);
    });
    ame318_dispatch_event(@"launcherBoot", nil);
}

+ (void)stopAll {
    ame318_ensure_state();
    dispatch_async(s_ame318_queue, ^{
        [s_ame318_lock lock];
        NSArray *running = [s_ame318_contexts.allKeys copy];
        [s_ame318_lock unlock];
        for (NSString *pid in running) ame318_stop_plugin_locked(pid);
        NSLog(@"[Ame318] stopAll complete (%lu stopped)", (unsigned long)running.count);
    });
}

+ (void)restartPlugin:(NSString *)pluginId {
    ame318_ensure_state();
    if (pluginId.length == 0) return;
    dispatch_async(s_ame318_queue, ^{
        [s_ame318_lock lock];
        if (![[AmePluginManager shared] isEnabled:pluginId]) {
            ame318_stop_plugin_locked(pluginId);
            [s_ame318_lock unlock];
            return;
        }
        AmePluginManifest *manifest = [[AmePluginManager shared] manifestForPlugin:pluginId];
        ame318_start_plugin_locked(pluginId, manifest);
        [s_ame318_lock unlock];
    });
}

+ (void)stopPlugin:(NSString *)pluginId {
    ame318_ensure_state();
    if (pluginId.length == 0) return;
    dispatch_async(s_ame318_queue, ^{
        ame318_stop_plugin_locked(pluginId);
        NSLog(@"[Ame318] plugin %@ stopped", pluginId);
    });
}

+ (BOOL)isRunning:(NSString *)pluginId {
    ame318_ensure_state();
    if (pluginId.length == 0) return NO;
    [s_ame318_lock lock];
    BOOL running = (s_ame318_contexts[pluginId] != nil);
    [s_ame318_lock unlock];
    return running;
}

+ (nullable NSString *)lastErrorForPlugin:(NSString *)pluginId {
    ame318_ensure_state();
    if (pluginId.length == 0) return nil;
    [s_ame318_lock lock];
    NSString *err = s_ame318_lastError[pluginId];
    [s_ame318_lock unlock];
    return err;
}

#pragma mark - 事件分发

+ (void)dispatchGameLaunchWithVersion:(NSString *)versionId {
    ame318_dispatch_event(@"gameLaunch",
                          @{@"version": versionId ?: @"", @"code": @0});
}

+ (void)dispatchGameExitWithVersion:(NSString *)versionId code:(int)code {
    ame318_dispatch_event(@"gameExit",
                          @{@"version": versionId ?: @"", @"code": @(code)});
}

+ (void)dispatchJarLaunchWithPath:(NSString *)path {
    ame318_dispatch_event(@"jarLaunch", @{@"path": path ?: @""});
}

@end
