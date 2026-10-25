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
#import "AmePluginManager.h"      // ★ Task329：seed 消费 AmePluginManifest 属性
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
// ★ Task329：插件可用性补面两权限 —— ui（贡献行/弹窗，低危）/ network
//   （联网取数，高危；Modrinth 热门榜等内置插件的数据通道）。
NSString * const AmePluginPermUI            = @"ui";
NSString * const AmePluginPermNetwork       = @"network";

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
            AmePluginPermUI,          // Task329
            AmePluginPermNetwork,     // Task329（高危）
        ];
    });
    return s_ame318_catalog;
}

+ (AmePluginDanger)dangerForPermission:(NSString *)permissionId {
    // 高危 = 写路径碰渲染器/实例配置（写错值 = 游戏黑屏/配置损坏的家法
    // 判例源）；中危 = 观感与插件私有数据；低危 = 只读/通知/事件。
    if ([permissionId isEqualToString:AmePluginPermRendererWrite] ||
        [permissionId isEqualToString:AmePluginPermProfileWrite] ||
        [permissionId isEqualToString:AmePluginPermNetwork]) {
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
    if ([permissionId isEqualToString:AmePluginPermUI])            return localize(@"ame318.perm.ui", nil);
    if ([permissionId isEqualToString:AmePluginPermNetwork])       return localize(@"ame318.perm.network", nil);
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
    if ([permissionId isEqualToString:AmePluginPermUI])            return localize(@"ame318.perm.ui.detail", nil);
    if ([permissionId isEqualToString:AmePluginPermNetwork])       return localize(@"ame318.perm.network.detail", nil);
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

#pragma mark - Task329：开箱即用授权播种

+ (void)seedSafeDefaultGrantsForManifest:(AmePluginManifest *)manifest {
    // 只补缺账不改账：显式撤销（NO）与显式授权（YES）永不覆盖；
    // Safe 级（events/notify/ui/renderer.read/profile.read）+ files.plugin
    // （私有目录，设备版指南口径 = 不列入默认拒绝清单）装机即授。
    NSString *pid = manifest.pluginId;
    if (pid.length == 0 || manifest.permissions.count == 0) return;
    NSDictionary *existing = [self grantsForPlugin:pid];
    for (NSString *perm in manifest.permissions) {
        if (![perm isKindOfClass:[NSString class]] || perm.length == 0) continue;
        if ([existing objectForKey:perm] != nil) continue;   // 有账（含显式 NO）不动
        BOOL ame329_safe =
            [self dangerForPermission:perm] == AmePluginDangerSafe ||
            [perm isEqualToString:AmePluginPermFilesPlugin];
        if (!ame329_safe) continue;
        [self setGranted:YES permission:perm forPlugin:pid];
    }
    NSLog(@"[Ame329] safe-perm seeded for %@ (%@ perms in manifest)", pid, @(manifest.permissions.count));
}

@end
