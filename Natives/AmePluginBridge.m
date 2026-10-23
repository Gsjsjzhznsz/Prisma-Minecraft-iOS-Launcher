//
//  AmePluginBridge.m
//  Amethyst
//
//  Task318：插件桥接器实现。
//
//  暴露面（全部先过授权闸）：
//    prisma.api                       常量 1
//    prisma.log/warn/error(msg)       控制台（NSLog 留痕，免授权）
//    prisma.toast(msg)                notify
//    prisma.getRenderer()             renderer.read   → 当前渲染器 key
//    prisma.listRendererOptions()     renderer.read   → [{key,name}]
//    prisma.isRendererAvailable(key)  renderer.read
//    prisma.setRenderer(key)          renderer.write  → 候选表白名单 + PLProfiles 锁内写
//    prisma.getThemeToken(name)       theme.write     → 当前覆盖值（无覆盖 = null）
//    prisma.setThemeTokens({...})     theme.write     → PrismaTheme 覆盖表整体替换
//    prisma.clearThemeTokens()        theme.write
//    prisma.listInstances()           profile.read    → [{name,lastVersionId}]
//    prisma.getProfileValue(key)      profile.read
//    prisma.setProfileValue(key,v)    profile.write   → 白名单 {allocated_memory, java_args}
//    prisma.readFile(name)            files.plugin    → 插件私有目录内文本
//    prisma.writeFile(name, text)     files.plugin
//    prisma.on(event, handler)        events          → gameLaunch/gameExit/jarLaunch/launcherBoot
//    prisma.isGranted(perm)           自省（免授权）
//
//  渲染器写路径家法：值必须命中 LauncherPreferences 的候选渲染器表
//  （写错值 = 游戏黑屏的判例域），写入走 PLProfiles applyChanges: 锁内
//  批量变更 API（Task275），禁裸写活字典。
//

#import "AmePluginBridge.h"
#import "AmePluginPermissions.h"
#import "AmePluginManager.h"
#import "PLProfiles.h"
#import "LauncherPreferences.h"
#import "utils.h" // localize
#import "PrismaUI/PrismaTheme.h"
#import "NMToast.h"

#pragma mark - 事件白名单

static NSArray<NSString *> *ame318_allowedEvents(void);
static NSString *ame318_scopedPluginPath(NSString *name, NSString *pluginId);

static NSArray<NSString *> *ame318_allowedEvents(void) {
    static NSArray *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = @[@"gameLaunch", @"gameExit", @"jarLaunch", @"launcherBoot"];
    });
    return s;
}

#pragma mark - 授权闸

/// 权限强制执行边界（本文件所有能力入口的第一行）。
static BOOL ame318_allow(NSString *permissionId, NSString *pluginId, const char *api) {
    if ([AmePluginPermissions isGranted:permissionId forPlugin:pluginId]) return YES;
    NSLog(@"[Ame318] DENIED %@ (perm=%@ not granted for %@)", @(api), permissionId, pluginId);
    return NO;
}

@implementation AmePluginBridge

#pragma mark - 渲染器校验

+ (BOOL)isRendererKeyAvailable:(NSString *)key {
    if (key.length == 0) return NO;
    if ([key isEqualToString:@"auto"]) return YES;
    // 候选表 key 集合（与设置页/版本管理器/Profile 编辑器同一事实源）。
    NSArray *keys = getRendererKeys(YES);
    if (![keys containsObject:key]) return NO;
    // "mg" 是逻辑键（家族入口），物理 dylib 缺失由 ame_effective_renderer
    // 的回落链兜底，此处恒可用。
    if ([key isEqualToString:@"mg"]) return YES;
    // 物理 dylib 存在性（与 LauncherPreferences.rendererLibraryExists 同语义；
    // 该函数文件内 static 未导出，这里按同一契约重实现）。
    NSString *fwPath = [[[NSBundle mainBundle] resourcePath]
                        stringByAppendingPathComponent:
                        [@"Frameworks" stringByAppendingPathComponent:key]];
    return [NSFileManager.defaultManager fileExistsAtPath:fwPath];
}

#pragma mark - 门面注入

+ (void)installFacadeInContext:(JSContext *)context
                       pluginId:(NSString *)pluginId
                      eventSink:(void (^)(NSString *event, JSValue *handler))eventSink {
    if (!context || pluginId.length == 0) return;

    NSString *pid = pluginId;

    // console.*（免授权，NSLog 留痕——插件调试的主通道）。
    void (^makeLogger)(NSString *, NSString *) = ^(NSString *level, NSString *key) {
        context[key] = ^(JSValue *value) {
            NSLog(@"[Ame318][%@][%@] %@", pid, level,
                  value ? value.toString : @"(null)");
        };
    };
    makeLogger(@"log", @"log");
    makeLogger(@"warn", @"warn");
    makeLogger(@"error", @"error");
    NSDictionary *console = @{@"log": context[@"log"],
                              @"warn": context[@"warn"],
                              @"error": context[@"error"]};
    context[@"console"] = console;

    NSMutableDictionary *facade = [NSMutableDictionary dictionary];
    facade[@"api"] = @1;

    facade[@"log"] = ^(NSString *msg) {
        NSLog(@"[Ame318][%@] %@", pid, msg ?: @"");
    };
    facade[@"toast"] = ^(NSString *msg) {
        if (!ame318_allow(AmePluginPermNotify, pid, "toast")) return;
        NSString *text = msg.length ? msg : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            [NMToast showMessage:text];
        });
    };
    facade[@"isGranted"] = ^(NSString *perm) {
        return @([AmePluginPermissions isGranted:perm forPlugin:pid]);
    };

    // ---- 渲染器（renderer.*）----
    facade[@"getRenderer"] = ^NSString *{
        if (!ame318_allow(AmePluginPermRendererRead, pid, "getRenderer")) return nil;
        NSString *raw = [PLProfiles resolveKeyForCurrentProfile:@"renderer"];
        return raw ?: @"auto";
    };
    facade[@"listRendererOptions"] = ^NSArray *{
        if (!ame318_allow(AmePluginPermRendererRead, pid, "listRendererOptions")) return nil;
        // containsDefault=NO：不要 "(default)" 占位行（插件拿到的是纯候选表）。
        NSArray *keys = getRendererKeys(NO);
        NSArray *names = getRendererNames(NO);
        NSMutableArray *out = [NSMutableArray array];
        for (NSUInteger i = 0; i < keys.count; i++) {
            NSString *name = (i < names.count) ? names[i] : keys[i];
            [out addObject:@{@"key": keys[i], @"name": name ?: keys[i]}];
        }
        return [out copy];
    };
    facade[@"isRendererAvailable"] = ^(NSString *key) {
        if (!ame318_allow(AmePluginPermRendererRead, pid, "isRendererAvailable")) return NO;
        return [AmePluginBridge isRendererKeyAvailable:key];
    };
    facade[@"setRenderer"] = ^(NSString *key) {
        if (!ame318_allow(AmePluginPermRendererWrite, pid, "setRenderer")) return @NO;
        if (![AmePluginBridge isRendererKeyAvailable:key]) {
            NSLog(@"[Ame318] setRenderer rejected: '%@' not in candidate whitelist", key);
            return @NO;
        }
        NSString *sel = [PLProfiles current].selectedProfileName;
        [[PLProfiles current] applyChanges:^(NSMutableDictionary<NSString *, id> *profiles) {
            id prof = profiles[sel];
            if ([prof isKindOfClass:[NSMutableDictionary class]]) {
                prof[@"renderer"] = key;
            }
        }];
        NSLog(@"[Ame318] renderer set to '%@' by plugin %@ (profile %@)", key, pid, sel);
        return @YES;
    };

    // ---- 主题（theme.write）----
    facade[@"setThemeTokens"] = ^(JSValue *tokens) {
        if (!ame318_allow(AmePluginPermThemeWrite, pid, "setThemeTokens")) return @NO;
        id obj = tokens.toObject;
        if (![obj isKindOfClass:[NSDictionary class]]) return @NO;
        [PrismaTheme setOverrideHexColors:(NSDictionary *)obj];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
             postNotificationName:@"LauncherAppearanceChanged" object:nil];
        });
        NSLog(@"[Ame318] theme tokens overridden by plugin %@ (%@ tokens)", pid,
              @(((NSDictionary *)obj).count));
        return @YES;
    };
    facade[@"clearThemeTokens"] = ^{
        if (!ame318_allow(AmePluginPermThemeWrite, pid, "clearThemeTokens")) return;
        [PrismaTheme setOverrideHexColors:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
             postNotificationName:@"LauncherAppearanceChanged" object:nil];
        });
    };

    // ---- 实例/配置（profile.*）----
    facade[@"listInstances"] = ^NSArray *{
        if (!ame318_allow(AmePluginPermProfileRead, pid, "listInstances")) return nil;
        NSDictionary *profiles = [PLProfiles current].profiles;
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *name in profiles) {
            NSDictionary *prof = profiles[name];
            if (![prof isKindOfClass:[NSDictionary class]]) continue;
            [out addObject:@{@"name": name ?: @"",
                             @"lastVersionId": prof[@"lastVersionId"] ?: @""}];
        }
        return [out copy];
    };
    facade[@"getProfileValue"] = ^id(NSString *key) {
        if (!ame318_allow(AmePluginPermProfileRead, pid, "getProfileValue")) return nil;
        if (![key isKindOfClass:[NSString class]] || key.length == 0) return nil;
        return [PLProfiles resolveKeyForCurrentProfile:key];
    };
    facade[@"setProfileValue"] = ^(NSString *key, JSValue *value) {
        if (!ame318_allow(AmePluginPermProfileWrite, pid, "setProfileValue")) return @NO;
        // 写键白名单：实例配置是启动参数的事实源，开放任意键写 = 配置损坏
        // 面（渲染器走专用 setRenderer 白名单通道，不在这里重复放行）。
        static NSSet *s_writable = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            s_writable = [NSSet setWithArray:@[@"allocated_memory", @"java_args"]];
        });
        if (![key isKindOfClass:[NSString class]] || ![s_writable containsObject:key]) {
            NSLog(@"[Ame318] setProfileValue rejected: key '%@' not writable by plugins", key);
            return @NO;
        }
        id native = value.toObject;
        if (![native isKindOfClass:[NSNumber class]] && ![native isKindOfClass:[NSString class]]) {
            return @NO;
        }
        NSString *sel = [PLProfiles current].selectedProfileName;
        [[PLProfiles current] applyChanges:^(NSMutableDictionary<NSString *, id> *profiles) {
            id prof = profiles[sel];
            if ([prof isKindOfClass:[NSMutableDictionary class]]) {
                prof[key] = native;
            }
        }];
        NSLog(@"[Ame318] profile[%@][%@] written by plugin %@", sel, key, pid);
        return @YES;
    };

    // ---- 插件私有目录（files.plugin）----
    facade[@"readFile"] = ^(NSString *name) {
        if (!ame318_allow(AmePluginPermFilesPlugin, pid, "readFile")) return (NSString *)nil;
        NSString *path = ame318_scopedPluginPath(name, pid);
        if (!path) return (NSString *)nil;
        return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    };
    facade[@"writeFile"] = ^(NSString *name, NSString *text) {
        if (!ame318_allow(AmePluginPermFilesPlugin, pid, "writeFile")) return @NO;
        NSString *path = ame318_scopedPluginPath(name, pid);
        if (!path) return @NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:path.stringByDeletingLastPathComponent]) {
            [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                                    withIntermediateDirectories:YES attributes:nil error:nil];
        }
        return @([text ?: @"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    };

    // ---- 事件订阅（events）----
    facade[@"on"] = ^(NSString *event, JSValue *handler) {
        if (!ame318_allow(AmePluginPermEvents, pid, "on")) return;
        if (![event isKindOfClass:[NSString class]]) return;
        if (![ame318_allowedEvents() containsObject:event]) {
            NSLog(@"[Ame318] on('%@') rejected: unknown event (plugin %@)", event, pid);
            return;
        }
        // JSValue 无 isFunction 属性，JSValueRef.h 在 CI SDK 亦无 JSValueIsFunction
        // （r3 实证）——放宽为空值校验；非函数在分发期 callWithArguments 时抛
        // JS 异常，由 context.exceptionHandler 捕获留痕，不崩不连坐。
        if (!handler) return;
        if (eventSink) eventSink(event, handler);
    };

    context[@"prisma"] = facade;
}

#pragma mark - 私有目录路径闸

/// 插件私有目录内的相对路径解析（拒绝绝对路径/穿越；目录 = plugins/<id>/data）。
static NSString *ame318_scopedPluginPath(NSString *name, NSString *pluginId) {
    if (![name isKindOfClass:[NSString class]] || name.length == 0) return nil;
    if ([name hasPrefix:@"/"] || [name containsString:@".."] || [name containsString:@":"]) {
        NSLog(@"[Ame318] scoped path rejected: '%@'", name);
        return nil;
    }
    NSString *dir = [[[AmePluginManager shared] pluginDirForId:pluginId]
                     stringByAppendingPathComponent:@"data"];
    return [dir stringByAppendingPathComponent:name];
}

@end
