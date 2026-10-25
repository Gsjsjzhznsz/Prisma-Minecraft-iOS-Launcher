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
#import "AmePluginPermissions.h"
#import "utils.h" // localize

#import <JavaScriptCore/JavaScriptCore.h>
#import <objc/message.h>

#pragma mark - 内部状态

/// 事件订阅表内层类型（嵌套泛型 typedef 化——clang 对 static 声明中的
/// 多层嵌套泛型实参报 "neither an Objective-C object nor a block type"）。
typedef NSMutableDictionary<NSString *, NSMutableArray<JSValue *> *> Ame318HandlerMap;

/// pluginId → JSContext（运行中插件表）。
static NSMutableDictionary<NSString *, JSContext *> *s_ame318_contexts = nil;
/// pluginId → {event → [JSValue handler]}（事件订阅表）。
static NSMutableDictionary<NSString *, Ame318HandlerMap *> *s_ame318_handlers = nil;
/// pluginId → 最近 JS 异常文本。
static NSMutableDictionary<NSString *, NSString *> *s_ame318_lastError = nil;
/// ★ Task329：贡献行注册表 pluginId → [{rowId,title,detail,onTap}]（注册序）。
static NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *s_ame318_rows = nil;
/// ★ Task329：贡献行全局注册序号（排序键）。
static NSUInteger s_ame318_rowOrder = 0;
/// 行面变更通知名。
static NSString * const s_ame318_rowsChangedNotification = @"AmePluginRowsChanged";
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
        s_ame318_rows = [NSMutableDictionary dictionary];
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

// ★ Task329：贡献行值对象（类扩展只读→读写 + 内部工厂）。
// 结构红线：@implementation 块禁止嵌套（Task318 r1 同族编译雷）——
// AmePluginRow 的扩展与实现整体置于 AmePluginRuntime 实现块之前。
@interface AmePluginRow ()
@property(nonatomic, copy, readwrite) NSString *pluginId;
@property(nonatomic, copy, readwrite) NSString *rowId;
@property(nonatomic, copy, readwrite) NSString *title;
@property(nonatomic, copy, readwrite) NSString *detail;
@property(nonatomic, assign, readwrite) NSUInteger order;
@end

@implementation AmePluginRow
@end

/// 注册表条目 → 值对象（主线程快照用；onTap JSValue 不外泄，
/// 点击回调经 enqueueBlock 回串行队列后由桥接层按 pluginId+rowId 查找）。
/// 注意：赋值走属性点语法（扩展内 readwrite 可见），禁 ivar 直访——
/// 属性合成 ivar 为 _pluginId 族名，无下划线直访 = undeclared 编译雷。
static AmePluginRow *ame329_rowFromEntry(NSDictionary *entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    AmePluginRow *row = [[AmePluginRow alloc] init];
    row.pluginId = [entry[@"pluginId"] isKindOfClass:[NSString class]] ? entry[@"pluginId"] : @"";
    row.rowId = [entry[@"rowId"] isKindOfClass:[NSString class]] ? entry[@"rowId"] : @"";
    row.title = [entry[@"title"] isKindOfClass:[NSString class]] ? entry[@"title"] : @"";
    row.detail = [entry[@"detail"] isKindOfClass:[NSString class]] ? entry[@"detail"] : @"";
    row.order = [entry[@"order"] isKindOfClass:[NSNumber class]] ? [entry[@"order"] unsignedIntegerValue] : 0;
    return row;
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
    BOOL ame329_hadRows = (s_ame318_rows[pluginId].count > 0);
    [s_ame318_rows removeObjectForKey:pluginId];   // ★ Task329：行随插件停而清（onTap JSValue 引用一并释放）
    [s_ame318_lock unlock];
    if (ame329_hadRows) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
             postNotificationName:s_ame318_rowsChangedNotification object:nil];
        });
    }
}

#pragma mark - Task329：贡献行注册表（注册/刷新/快照）

/// 注册或替换行（同 rowId 幂等替换；串行队列上调用，锁保护主线程读）。
static void ame329_registerRow(NSString *pluginId, NSDictionary *spec) {
    if (pluginId.length == 0 || ![spec isKindOfClass:[NSDictionary class]]) return;
    NSString *rowId = spec[@"id"];
    if (![rowId isKindOfClass:[NSString class]] || rowId.length == 0) {
        NSLog(@"[Ame329] registerRow rejected: missing 'id' (%@)", pluginId);
        return;
    }
    NSString *title = [spec[@"title"] isKindOfClass:[NSString class]] ? spec[@"title"] : @"";
    NSString *detail = [spec[@"detail"] isKindOfClass:[NSString class]] ? spec[@"detail"] : @"";
    JSValue *onTap = [spec[@"onTap"] isKindOfClass:[JSValue class]] ? spec[@"onTap"] : nil;
    [s_ame318_lock lock];
    NSMutableArray *list = s_ame318_rows[pluginId];
    if (!list) {
        list = [NSMutableArray array];
        s_ame318_rows[pluginId] = list;
    }
    NSUInteger ame329_order = UINT_MAX;
    for (NSDictionary *old in list) {
        if ([old[@"rowId"] isEqualToString:rowId]) {
            ame329_order = [old[@"order"] unsignedIntegerValue];
            [list removeObject:old];
            break;
        }
    }
    if (ame329_order == UINT_MAX) ame329_order = s_ame318_rowOrder++;
    NSDictionary *entry = @{@"rowId": rowId,
                            @"pluginId": pluginId,
                            @"title": title,
                            @"detail": detail,
                            @"onTap": onTap ?: [NSNull null],
                            @"order": @(ame329_order)};
    [list addObject:entry];
    [s_ame318_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
         postNotificationName:s_ame318_rowsChangedNotification object:nil];
    });
}

/// 刷新行文案（不存在时忽略；串行队列上调用）。
static void ame329_updateRow(NSString *pluginId, NSString *rowId, NSDictionary *patch) {
    if (pluginId.length == 0 || rowId.length == 0 || ![patch isKindOfClass:[NSDictionary class]]) return;
    [s_ame318_lock lock];
    NSMutableArray *list = s_ame318_rows[pluginId];
    for (NSUInteger i = 0; list && i < list.count; i++) {
        NSMutableDictionary *entry = [list[i] mutableCopy];
        if (![entry[@"rowId"] isEqualToString:rowId]) continue;
        if ([patch[@"title"] isKindOfClass:[NSString class]]) entry[@"title"] = patch[@"title"];
        if ([patch[@"detail"] isKindOfClass:[NSString class]]) entry[@"detail"] = patch[@"detail"];
        list[i] = entry;
        [s_ame318_lock unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
             postNotificationName:s_ame318_rowsChangedNotification object:nil];
        });
        return;
    }
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
            // ★ Task329：开箱即用授权播种（存量装也覆盖——Task318 时代装上的
            //   插件没有安装期播种，boot 期只补缺账，显式撤销永不覆盖）。
            [AmePluginPermissions seedSafeDefaultGrantsForManifest:manifest];
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

#pragma mark - Task329：贡献行公共 API

+ (void)enqueueBlock:(void (^)(void))block {
    ame318_ensure_state();
    if (!block) return;
    dispatch_async(s_ame318_queue, block);
}

+ (NSArray<AmePluginRow *> *)allRows {
    ame318_ensure_state();
    [s_ame318_lock lock];
    NSMutableArray<NSDictionary *> *flat = [NSMutableArray array];
    for (NSString *pid in s_ame318_rows) {
        [flat addObjectsFromArray:s_ame318_rows[pid]];
    }
    [s_ame318_lock unlock];
    [flat sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@([a[@"order"] unsignedIntegerValue]) compare:@([b[@"order"] unsignedIntegerValue])];
    }];
    NSMutableArray<AmePluginRow *> *out = [NSMutableArray array];
    for (NSDictionary *entry in flat) {
        AmePluginRow *row = ame329_rowFromEntry(entry);
        if (row) [out addObject:row];
    }
    return out;
}

+ (NSString *)rowsChangedNotification {
    return s_ame318_rowsChangedNotification;
}

+ (void)registerRowForPlugin:(NSString *)pluginId spec:(NSDictionary *)spec {
    ame318_ensure_state();
    if (pluginId.length == 0) return;
    dispatch_async(s_ame318_queue, ^{ ame329_registerRow(pluginId, spec); });
}

+ (void)updateRowForPlugin:(NSString *)pluginId rowId:(NSString *)rowId patch:(NSDictionary *)patch {
    ame318_ensure_state();
    if (pluginId.length == 0 || rowId.length == 0) return;
    dispatch_async(s_ame318_queue, ^{ ame329_updateRow(pluginId, rowId, patch); });
}

+ (void)dispatchRowTapForPlugin:(NSString *)pluginId rowId:(NSString *)rowId {
    ame318_ensure_state();
    if (pluginId.length == 0 || rowId.length == 0) return;
    dispatch_async(s_ame318_queue, ^{
        [s_ame318_lock lock];
        JSValue *onTap = nil;
        for (NSDictionary *entry in s_ame318_rows[pluginId]) {
            if ([entry[@"rowId"] isEqualToString:rowId]) {
                onTap = [entry[@"onTap"] isKindOfClass:[JSValue class]] ? entry[@"onTap"] : nil;
                break;
            }
        }
        [s_ame318_lock unlock];
        if (!onTap) return;
        @try {
            [onTap callWithArguments:@[]];
        } @catch (NSException *e) {
            NSLog(@"[Ame329] row onTap threw (%@/%@): %@", pluginId, rowId, e.reason);
        }
    });
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
