//
//  AmePluginManager.m
//  Amethyst
//
//  Task318：插件管理器实现。
//  安全面三道闸（全部在解包/落盘前）：
//    1) manifest.json 必须可解析且必填字段齐备，permissions 全部命中
//       AmePluginPermissions 目录（未知权限拒装——权限边界完整性优先）；
//    2) 解包总量上限（8 MB）+ 条目数上限（128）+ 单层路径规范校验
//       （拒绝绝对路径 / ../ 穿越，Zip Slip 家族防御）；
//    3) 安装落位固定 $POJAV_HOME/plugins/<id>/，id 白名单字符集
//       （[A-Za-z0-9._-]，禁止以 . 开头）——目录名直接拼路径，先钉死字符集。
//

#import "AmePluginManager.h"
#import "AmePluginPermissions.h"
#import "UnzipKit.h"          // 仓内约定：UZKArchive（CMake include external/UnzipKit）
#import "LauncherPreferences.h" // getPrefObject / setPrefObject
#import "utils.h" // localize

#pragma mark - 常量

/// 解包总量上限（字节）：内置插件均为 KB 级，8MB 已是数量级冗余。
static const NSUInteger kAme318MaxUncompressedBytes = 8 * 1024 * 1024;
/// 解包条目数上限。
static const NSUInteger kAme318MaxEntries = 128;

@implementation AmePluginManifest

@end

#pragma mark - 单例与发现

@implementation AmePluginManager {
    NSRecursiveLock *_ame318_lock;
}

#pragma mark - 清单解析

+ (nullable AmePluginManifest *)parseManifestDictionary:(NSDictionary *)dict
                                                  error:(NSError **)error {
    // 必填字段逐一校验（错误信息带键名，装不上时 toast 直接可读）。
    NSString *pid = [self ame318_stringField:dict[@"id"]];
    NSString *name = [self ame318_stringField:dict[@"name"]];
    NSString *version = [self ame318_stringField:dict[@"version"]];
    NSString *main = [self ame318_stringField:dict[@"main"]] ?: @"main.js";

    if (pid.length == 0 || name.length == 0 || version.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"Ame318PluginInstall" code:1
                                      userInfo:@{NSLocalizedDescriptionKey:
                          localize(@"ame318.error.manifest_incomplete", nil)}];
        }
        return nil;
    }
    // id 字符集闸（目录名拼接路径前的硬约束；禁 . 开头防 ".." 变体）。
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    NSCharacterSet *disallowed = [allowed invertedSet];
    if (pid.length > 64 || [pid hasPrefix:@"."] || [pid rangeOfCharacterFromSet:disallowed].location != NSNotFound) {
        if (error) {
            *error = [NSError errorWithDomain:@"Ame318PluginInstall" code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                          localize(@"ame318.error.bad_id", nil)}];
        }
        return nil;
    }

    // 权限目录闸：未知权限一律拒装（桥接边界只认识目录内权限，
    // 放未知权限进账本会让"权限系统"变成装饰）。
    id permsRaw = dict[@"permissions"];
    if (![permsRaw isKindOfClass:[NSArray class]]) permsRaw = @[];
    NSMutableArray<NSString *> *perms = [NSMutableArray array];
    for (id p in (NSArray *)permsRaw) {
        if (![p isKindOfClass:[NSString class]]) continue;
        if ([AmePluginPermissions.allPermissionIds containsObject:p]) {
            [perms addObject:p];
        } else {
            NSLog(@"[Ame318] manifest rejected: unknown permission '%@' (id=%@)", p, pid);
            if (error) {
                *error = [NSError errorWithDomain:@"Ame318PluginInstall" code:3
                                          userInfo:@{NSLocalizedDescriptionKey:
                              [NSString stringWithFormat:localize(@"ame318.error.unknown_perm", nil), p]}];
            }
            return nil;
        }
    }

    AmePluginManifest *m = [AmePluginManifest new];
    // 只读模型用 KVC 私有写（readonly 对外；本文件内赋值）。
    [(AmePluginManifest *)m setValue:pid forKey:@"pluginId"];
    [(AmePluginManifest *)m setValue:name forKey:@"name"];
    [(AmePluginManifest *)m setValue:version forKey:@"version"];
    [(AmePluginManifest *)m setValue:[self ame318_stringField:dict[@"author"]] ?: @"" forKey:@"author"];
    [(AmePluginManifest *)m setValue:[self ame318_stringField:dict[@"description"]] ?: @"" forKey:@"pluginDescription"];
    [(AmePluginManifest *)m setValue:main forKey:@"entry"];
    [(AmePluginManifest *)m setValue:[perms copy] forKey:@"permissions"];
    return m;
}

/// 字符串字段容错读取（非字符串 = nil）。
+ (nullable NSString *)ame318_stringField:(id)raw {
    if ([raw isKindOfClass:[NSString class]] && ((NSString *)raw).length > 0) return raw;
    return nil;
}


+ (instancetype)shared {
    static AmePluginManager *s_ame318_manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s_ame318_manager = [AmePluginManager new];
    });
    return s_ame318_manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _ame318_lock = [NSRecursiveLock new];
    }
    return self;
}

- (NSString *)pluginsRoot {
    // POJAV_HOME 是启动器数据主目录契约（main.m 派生，Java 侧同源）；
    // 插件目录挂在它下面，与游戏目录布局（instances 等）解耦。
    NSString *home = @(getenv("POJAV_HOME") ?: "");
    if (home.length == 0) home = NSHomeDirectory();
    return [home stringByAppendingPathComponent:@"plugins"];
}

- (NSString *)pluginDirForId:(NSString *)pluginId {
    return [[self pluginsRoot] stringByAppendingPathComponent:pluginId];
}

- (BOOL)isInstalled:(NSString *)pluginId {
    if (pluginId.length == 0) return NO;
    return [NSFileManager.defaultManager fileExistsAtPath:[self pluginDirForId:pluginId]];
}

- (NSArray<AmePluginManifest *> *)installedPlugins {
    [_ame318_lock lock];
    @try {
        NSMutableArray<AmePluginManifest *> *result = [NSMutableArray array];
        NSString *root = [self pluginsRoot];
        NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:nil];
        for (NSString *dir in entries) {
            if (![dir isKindOfClass:[NSString class]] || [dir hasPrefix:@"."]) continue;
            AmePluginManifest *m = [self manifestForPlugin:dir];
            if (m) [result addObject:m];
        }
        // 稳定序：按 id 排序（重扫不跳行）。
        [result sortUsingComparator:^NSComparisonResult(AmePluginManifest *a, AmePluginManifest *b) {
            return [a.pluginId compare:b.pluginId];
        }];
        return [result copy];
    } @finally {
        [_ame318_lock unlock];
    }
}

- (nullable AmePluginManifest *)manifestForPlugin:(NSString *)pluginId {
    NSString *manifestPath = [[self pluginDirForId:pluginId]
                              stringByAppendingPathComponent:@"manifest.json"];
    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    if (!data) return nil;
    NSError *jsonError = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    return [AmePluginManager parseManifestDictionary:obj error:nil];
}

#pragma mark - 启停状态（plugin.enabled_map）

- (BOOL)isEnabled:(NSString *)pluginId {
    if (pluginId.length == 0) return NO;
    id raw = getPrefObject(@"plugin.enabled_map");
    if (![raw isKindOfClass:[NSDictionary class]]) return NO;
    NSNumber *flag = ((NSDictionary *)raw)[pluginId];
    return flag.boolValue;
}

- (void)setEnabled:(BOOL)enabled pluginId:(NSString *)pluginId {
    if (pluginId.length == 0) return;
    id raw = getPrefObject(@"plugin.enabled_map");
    NSMutableDictionary *map = [raw isKindOfClass:[NSDictionary class]]
        ? [((NSDictionary *)raw) mutableCopy] : [NSMutableDictionary dictionary];
    map[pluginId] = @(enabled);
    setPrefObject(@"plugin.enabled_map", map);
    NSLog(@"[Ame318] enabled_map[%@] = %@", pluginId, enabled ? @"YES" : @"NO");
}

#pragma mark - 安装

- (nullable NSError *)installFromZip:(NSString *)zipPath {
    if (zipPath.length == 0 || ![NSFileManager.defaultManager fileExistsAtPath:zipPath]) {
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:10
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.zip_unreadable", nil)}];
    }

    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&archiveError];
    if (!archive || archiveError) {
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:11
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.zip_unreadable", nil)}];
    }

    // 闸 1：解包前预算（Zip bomb 防御——总量/条目数双上限，超限即拒）。
    NSArray *fileInfos = [archive listFileInfo:&archiveError];
    if (!fileInfos || archiveError) {
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:12
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.zip_unreadable", nil)}];
    }
    unsigned long long totalBytes = 0;
    NSUInteger entryCount = 0;
    for (UZKFileInfo *info in fileInfos) {
        if ([info.filename hasSuffix:@"/"]) continue; // 目录条目不计
        entryCount++;
        totalBytes += info.uncompressedSize;
    }
    if (entryCount > kAme318MaxEntries || totalBytes > kAme318MaxUncompressedBytes) {
        NSLog(@"[Ame318] pack rejected: entries=%lu bytes=%llu (limits %lu / %lu)",
              (unsigned long)entryCount, totalBytes,
              (unsigned long)kAme318MaxEntries, (unsigned long)kAme318MaxUncompressedBytes);
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:13
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.pack_too_large", nil)}];
    }

    // 闸 2：路径规范预检（绝对路径 / .. 穿越，Zip Slip 家族）。
    for (UZKFileInfo *info in fileInfos) {
        NSString *fn = info.filename;
        if (fn.length == 0) continue;
        if ([fn hasPrefix:@"/"] || [fn hasPrefix:@"\\"] ||
            [fn rangeOfString:@".."].location != NSNotFound ||
            [fn rangeOfString:@":"].location != NSNotFound) {
            NSLog(@"[Ame318] pack rejected: unsafe path '%@'", fn);
            return [NSError errorWithDomain:@"Ame318PluginInstall" code:14
                                    userInfo:@{NSLocalizedDescriptionKey:
                        localize(@"ame318.error.unsafe_path", nil)}];
        }
    }

    // 清单定位：根级 manifest.json，否则唯一顶层目录内的 manifest.json。
    NSString *manifestEntry = nil;
    NSString *stripPrefix = @"";
    for (UZKFileInfo *info in fileInfos) {
        if ([info.filename isEqualToString:@"manifest.json"]) {
            manifestEntry = @"manifest.json";
            break;
        }
    }
    if (!manifestEntry) {
        NSString *onlyDir = nil;
        for (UZKFileInfo *info in fileInfos) {
            NSArray *comps = [info.filename pathComponents];
            if (comps.count < 2) continue;
            NSString *top = comps[0];
            if ([top isEqualToString:@"/"]) continue;
            if (!onlyDir) onlyDir = top;
            else if (![onlyDir isEqualToString:top]) { onlyDir = nil; break; }
        }
        if (onlyDir) {
            NSString *nested = [NSString stringWithFormat:@"%@/manifest.json", onlyDir];
            for (UZKFileInfo *info in fileInfos) {
                if ([info.filename isEqualToString:nested]) {
                    manifestEntry = nested;
                    stripPrefix = [onlyDir stringByAppendingString:@"/"];
                    break;
                }
            }
        }
    }
    if (!manifestEntry) {
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:15
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.no_manifest", nil)}];
    }

    // 闸 3：清单解析（字段 + 权限目录）。
    NSError *dataError = nil;
    NSData *manifestData = [archive extractDataFromFile:manifestEntry error:&dataError];
    if (!manifestData || dataError) {
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:16
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.no_manifest", nil)}];
    }
    id manifestObj = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    if (![manifestObj isKindOfClass:[NSDictionary class]]) {
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:17
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.manifest_incomplete", nil)}];
    }
    NSError *parseError = nil;
    AmePluginManifest *manifest = [AmePluginManager parseManifestDictionary:manifestObj
                                                                      error:&parseError];
    if (!manifest) return parseError;

    // 入口文件必须真实存在（防"装得上跑不起"的哑包）。
    BOOL entryFound = NO;
    for (UZKFileInfo *info in fileInfos) {
        if ([info.filename isEqualToString:[stripPrefix stringByAppendingString:manifest.entry]]) {
            entryFound = YES;
            break;
        }
    }
    if (!entryFound) {
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:18
                                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:localize(@"ame318.error.entry_missing", nil), manifest.entry]}];
    }

    // 落位：先解到暂存目录，校验全通过后原子换装（覆盖重装同 id）。
    NSString *staging = [[self pluginsRoot] stringByAppendingPathComponent:
                         [NSString stringWithFormat:@".staging-%@", manifest.pluginId]];
    NSString *finalDir = [self pluginDirForId:manifest.pluginId];
    NSString *backup = [staging stringByAppendingString:@".old"];
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    [NSFileManager.defaultManager removeItemAtPath:backup error:nil];

    NSError *extractError = nil;
    // extractFilesTo: 会保留包内目录结构；带顶层目录前缀的包已在
    // stripPrefix 语义下原样解出（目录保留无害，entry 路径按含前缀核对过）。
    BOOL ok = [archive extractFilesTo:staging overwrite:YES error:&extractError];
    if (!ok || extractError) {
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        NSLog(@"[Ame318] extract failed: %@", extractError.localizedDescription);
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:19
                                userInfo:@{NSLocalizedDescriptionKey:
                    localize(@"ame318.error.extract_failed", nil)}];
    }
    // 唯一顶层目录形态：解包产物是 staging/<onlyDir>/...，内层目录即插件本体。
    NSString *payloadDir = staging;
    if (stripPrefix.length > 0) {
        payloadDir = [staging stringByAppendingPathComponent:
                      [stripPrefix substringToIndex:stripPrefix.length - 1]];
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:[self pluginsRoot]]) {
        [NSFileManager.defaultManager createDirectoryAtPath:[self pluginsRoot]
                                withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([NSFileManager.defaultManager fileExistsAtPath:finalDir]) {
        // 覆盖重装：旧目录先挪备份（挪不动 = 运行中文件占用，拒绝半装）。
        if (![NSFileManager.defaultManager moveItemAtPath:finalDir toPath:backup error:nil]) {
            [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
            return [NSError errorWithDomain:@"Ame318PluginInstall" code:21
                                    userInfo:@{NSLocalizedDescriptionKey:
                                localize(@"ame318.error.replace_failed", nil)}];
        }
    }
    if (![NSFileManager.defaultManager moveItemAtPath:payloadDir toPath:finalDir error:nil]) {
        // 回滚备份，尽量不留半装状态。
        if ([NSFileManager.defaultManager fileExistsAtPath:backup]) {
            [NSFileManager.defaultManager moveItemAtPath:backup toPath:finalDir error:nil];
        }
        [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
        return [NSError errorWithDomain:@"Ame318PluginInstall" code:22
                                userInfo:@{NSLocalizedDescriptionKey:
                            localize(@"ame318.error.extract_failed", nil)}];
    }
    [NSFileManager.defaultManager removeItemAtPath:backup error:nil];
    [NSFileManager.defaultManager removeItemAtPath:staging error:nil];
    NSLog(@"[Ame318] installed plugin %@ v%@ (perms: %@)",
          manifest.pluginId, manifest.version, [manifest.permissions componentsJoinedByString:@","]);
        // ★ Task329：Safe 级 + 插件私有目录装机即授（开箱即用；显式撤销账永不覆盖，高危权限维持详情页授权）。
    [AmePluginPermissions seedSafeDefaultGrantsForManifest:manifest];
    return nil;
}

#pragma mark - 卸载

- (void)uninstallPlugin:(NSString *)pluginId {
    if (pluginId.length == 0) return;
    [_ame318_lock lock];
    @try {
        NSError *rmError = nil;
        [NSFileManager.defaultManager removeItemAtPath:[self pluginDirForId:pluginId]
                                                 error:&rmError];
        if (rmError) NSLog(@"[Ame318] uninstall rm failed (%@): %@", pluginId, rmError.localizedDescription);
        [self setEnabled:NO pluginId:pluginId];
        [AmePluginPermissions clearGrantsForPlugin:pluginId];
        NSLog(@"[Ame318] uninstalled plugin %@", pluginId);
    } @finally {
        [_ame318_lock unlock];
    }
}

#pragma mark - 内置仓库

- (NSArray<NSString *> *)builtinPackPaths {
    NSString *dir = [[[NSBundle mainBundle] resourcePath]
                     stringByAppendingPathComponent:@"BuiltinPlugins"];
    NSArray *entries = [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *name in [entries sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name.pathExtension.lowercaseString isEqualToString:@"zip"]) {
            [paths addObject:[dir stringByAppendingPathComponent:name]];
        }
    }
    return [paths copy];
}

- (nullable AmePluginManifest *)peekManifestOfZip:(NSString *)zipPath
                                            error:(NSError **)error {
    NSError *archiveError = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:zipPath error:&archiveError];
    if (!archive || archiveError) {
        if (error) *error = archiveError;
        return nil;
    }
    NSData *data = [archive extractDataFromFile:@"manifest.json" error:&archiveError];
    // 唯一顶层目录形态的兜底。
    if (!data) {
        NSArray *names = [archive listFilenames:&archiveError];
        for (NSString *name in names) {
            if ([name isEqualToString:@"manifest.json"]) break;
            NSArray *comps = [name pathComponents];
            if (comps.count == 2 && [comps[1] isEqualToString:@"manifest.json"]) {
                data = [archive extractDataFromFile:name error:&archiveError];
                break;
            }
        }
    }
    if (!data) {
        if (error) *error = archiveError;
        return nil;
    }
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    return [AmePluginManager parseManifestDictionary:obj error:error];
}

@end
