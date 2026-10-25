//
//  AmePluginPermissions.m
//  Amethyst
//
//  Task318：插件权限中心实现。授权账本落 PLPreferences 的 plugin.perm_map
//  （动态字典值；键注册是硬前提——PLPreferences.setObject:value: 对未注册
//  键静默 return NO，Task313 地区门卡 2/3 同族病历，默认值已在
//  defaultPrefForGlobal 的 Task318 块播种）。
//

#import "AmePluginPermissions.h"
#import "LauncherPreferences.h"   // getPrefObject / setPrefObject
#import "utils.h" // localize

#pragma mark - 权限 ID 定义

NSString * const AmePluginPermEvents        = @"events";
NSString * const AmePluginPermNotify        = @"notify";
NSString * const AmePluginPermProfileRead   = @"profile.read";
NSString * const AmePluginPermProfileWrite  = @"profile.write";
NSString * const AmePluginPermRendererRead  = @"renderer.read";
NSString * const AmePluginPermRendererWrite = @"renderer.write";
NSString * const AmePluginPermThemeWrite    = @"theme.write";
NSString * const AmePluginPermFilesPlugin   = @"files.plugin";

@implementation AmePluginPermissions

#pragma mark - 目录

+ (NSArray<NSString *> *)allPermissionIds {
    static NSArray<NSString *> *s_ame318_catalog = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 有意保持显式列表（不用宏生成）：权限边界是安全面，可读性优先，
        // 新增权限必须显式出现这里 + i18n 两键 + 桥接消费点三处。
        s_ame318_catalog = @[
            AmePluginPermEvents,
            AmePluginPermNotify,
            AmePluginPermProfileRead,
            AmePluginPermProfileWrite,
            AmePluginPermRendererRead,
            AmePluginPermRendererWrite,
            AmePluginPermThemeWrite,
            AmePluginPermFilesPlugin,
        ];
    });
    return s_ame318_catalog;
}

+ (AmePluginDanger)dangerForPermission:(NSString *)permissionId {
    // 高危 = 写路径碰渲染器/实例配置（写错值 = 游戏黑屏/配置损坏的家法
    // 判例源）；中危 = 观感与插件私有数据；低危 = 只读/通知/事件。
    if ([permissionId isEqualToString:AmePluginPermRendererWrite] ||
        [permissionId isEqualToString:AmePluginPermProfileWrite]) {
        return AmePluginDangerHigh;
    }
    if ([permissionId isEqualToString:AmePluginPermThemeWrite] ||
        [permissionId isEqualToString:AmePluginPermFilesPlugin]) {
        return AmePluginDangerModerate;
    }
    return AmePluginDangerSafe;
}

+ (NSString *)localizedTitleForPermission:(NSString *)permissionId {
    // 显式逐键映射（不动态拼键名）：i18n 审计门（task248/250）对字面量
    // 键做四表齐备校验，动态族需要脚本枚举登记，字面量映射是最省路径。
    if ([permissionId isEqualToString:AmePluginPermEvents])        return localize(@"ame318.perm.events", nil);
    if ([permissionId isEqualToString:AmePluginPermNotify])        return localize(@"ame318.perm.notify", nil);
    if ([permissionId isEqualToString:AmePluginPermProfileRead])   return localize(@"ame318.perm.profile.read", nil);
    if ([permissionId isEqualToString:AmePluginPermProfileWrite])  return localize(@"ame318.perm.profile.write", nil);
    if ([permissionId isEqualToString:AmePluginPermRendererRead])  return localize(@"ame318.perm.renderer.read", nil);
    if ([permissionId isEqualToString:AmePluginPermRendererWrite]) return localize(@"ame318.perm.renderer.write", nil);
    if ([permissionId isEqualToString:AmePluginPermThemeWrite])    return localize(@"ame318.perm.theme.write", nil);
    if ([permissionId isEqualToString:AmePluginPermFilesPlugin])   return localize(@"ame318.perm.files.plugin", nil);
    return localize(@"ame318.perm.unknown", nil);
}

+ (NSString *)localizedDetailForPermission:(NSString *)permissionId {
    if ([permissionId isEqualToString:AmePluginPermEvents])        return localize(@"ame318.perm.events.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermNotify])        return localize(@"ame318.perm.notify.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermProfileRead])   return localize(@"ame318.perm.profile.read.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermProfileWrite])  return localize(@"ame318.perm.profile.write.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermRendererRead])  return localize(@"ame318.perm.renderer.read.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermRendererWrite]) return localize(@"ame318.perm.renderer.write.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermThemeWrite])    return localize(@"ame318.perm.theme.write.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermFilesPlugin])   return localize(@"ame318.perm.files.plugin.detail", nil);
    return @"";
}

#pragma mark - 授权账本（plugin.perm_map）

/// 读取账本顶层字典（防御性拷贝；plist 反序列化产物可能是不可变嵌套）。
+ (NSMutableDictionary<NSString *, NSMutableDictionary *> *)ame318_permMap {
    id raw = getPrefObject(@"plugin.perm_map");
    if (![raw isKindOfClass:[NSDictionary class]]) return [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *map = [NSMutableDictionary dictionary];
    for (NSString *key in (NSDictionary *)raw) {
        id entry = ((NSDictionary *)raw)[key];
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSMutableDictionary *inner = [NSMutableDictionary dictionary];
        for (NSString *perm in (NSDictionary *)entry) {
            id flag = ((NSDictionary *)entry)[perm];
            if ([flag isKindOfClass:[NSNumber class]]) inner[perm] = flag;
        }
        map[key] = inner;
    }
    return map;
}

+ (BOOL)isGranted:(NSString *)permissionId forPlugin:(NSString *)pluginId {
    if (permissionId.length == 0 || pluginId.length == 0) return NO;
    NSDictionary *map = [self ame318_permMap];
    NSNumber *flag = map[pluginId][permissionId];
    return flag.boolValue;
}

+ (void)setGranted:(BOOL)granted
        permission:(NSString *)permissionId
         forPlugin:(NSString *)pluginId {
    if (permissionId.length == 0 || pluginId.length == 0) return;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *map = [self ame318_permMap];
    NSMutableDictionary *inner = map[pluginId];
    if (!inner) {
        inner = [NSMutableDictionary dictionary];
        map[pluginId] = inner;
    }
    inner[permissionId] = @(granted);
    setPrefObject(@"plugin.perm_map", map);
    NSLog(@"[Ame318] permission %@ -> %@ : %@", permissionId, pluginId, granted ? @"GRANTED" : @"REVOKED");
}

+ (NSDictionary<NSString *, NSNumber *> *)grantsForPlugin:(NSString *)pluginId {
    if (pluginId.length == 0) return @{};
    NSDictionary *map = [self ame318_permMap];
    NSDictionary *inner = map[pluginId];
    return inner ?: @{};
}

+ (void)clearGrantsForPlugin:(NSString *)pluginId {
    if (pluginId.length == 0) return;
    NSMutableDictionary *map = [self ame318_permMap];
    if (!map[pluginId]) return;
    [map removeObjectForKey:pluginId];
    setPrefObject(@"plugin.perm_map", map);
}

@end
