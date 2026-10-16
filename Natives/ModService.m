#import "utils.h"
//
//  ModService.m
//  AmethystMods
//
//  修改：增加文件修改时间缓存，大幅提升扫描速度
//  修改：文件下载改走 PLDownloadClient 统一下载器（镜像候选 + SHA1 校验 + 断点续传），
//        移除自建 NSURLSession 下载 delegate（spec optimize-download-system Task 4.2 / 5.1 / 5.2）
//

#import "ModService.h"
// ★ Task274-h S14：CommonCrypto import 随零调用 sha1ForFileAtPath 删除（全文件 CC_ 族
//   仅该方法使用，rg 亲证）
#import <UIKit/UIKit.h>
#import "PLProfiles.h"
#import "ModpackImportService.h"  // Task275 F6: ame269_isImportBusy 让路守卫
#import "UnzipKit.h"
#import "DownloadTaskManager.h"
#import "DownloadTaskItem.h"
#import "PLTaskStages.h"
#import "LauncherPreferences.h"
#import "PLDownloadClient.h"
#import "PLMirrorCenter.h"

@interface ModService ()
// ---- PLDownloadClient 下载跟踪（key = DownloadTaskItem.taskId，即 PLDownloadRequest.taskIdentifier）----
@property (nonatomic, strong) NSLock *downloadStateLock;
@property (nonatomic, strong) NSMutableDictionary<NSString *, DownloadTaskItem *> *downloadTaskItems;
// 强持有当前 operation：pause 后 PLDownloadClient 会移除内部 task 映射，
// 需由 Service 保活，DownloadTaskManager 的 rawTask（weak）才能继续 pause/resume
@property (nonatomic, strong) NSMutableDictionary<NSString *, PLDownloadOperation *> *downloadOperations;
// 重试代数：retryHandler 重建请求后旧 operation 的迟到回调（如取消）按此丢弃
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadGenerations;
// 进度累计（PLDownloadClient 为 delta 语义，含镜像切换/重试的负 delta 回退，直接累加即可）
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadAccumulatedBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadTotalBytes;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *downloadLastSpeeds;
// 请求描述缓存：retryHandler 复用同一请求（同 taskIdentifier 可复用断点语义）
@property (nonatomic, strong) NSMutableDictionary<NSString *, PLDownloadRequest *> *downloadRequests;
@property (nonatomic, strong) NSMutableDictionary<NSString *, void(^)(NSProgress *)> *downloadProgressHandlers;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModDownloadHandler> *downloadCompletionHandlers;

// 缓存
@property (nonatomic, strong) NSMutableDictionary<NSString *, ModItem *> *metadataCache;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDate *> *checkpointTimes;
@property (nonatomic, strong) dispatch_queue_t cacheQueue;
@end

@implementation ModService

// ---------- TOML 解析（未修改）----------
- (nullable id)parseTomlValue:(NSString *)valPart inLines:(NSArray<NSString *> *)lines atIndex:(NSUInteger *)i {
    NSString *trimmedVal = [valPart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSString *delimiter = nil;
    if ([trimmedVal hasPrefix:@"'''"]) delimiter = @"'''";
    else if ([trimmedVal hasPrefix:@"\"\"\""]) delimiter = @"\"\"\"";

    if (delimiter) {
        NSMutableString *multiLineContent = [[trimmedVal substringFromIndex:3] mutableCopy];
        if ([multiLineContent hasSuffix:delimiter]) {
            return [multiLineContent substringToIndex:multiLineContent.length - 3];
        } else {
            NSMutableArray<NSString *> *contentLines = [NSMutableArray array];
            [contentLines addObject:multiLineContent];
            (*i)++;
            while (*i < lines.count) {
                NSString *nextLine = lines[*i];
                NSRange endDelimiterRange = [nextLine rangeOfString:delimiter];
                if (endDelimiterRange.location != NSNotFound) {
                    [contentLines addObject:[nextLine substringToIndex:endDelimiterRange.location]];
                    break;
                } else {
                    [contentLines addObject:nextLine];
                }
                (*i)++;
            }
            return [contentLines componentsJoinedByString:@"\n"];
        }
    }

    if (([trimmedVal hasPrefix:@"\""] && [trimmedVal hasSuffix:@"\""]) ||
        ([trimmedVal hasPrefix:@"'"] && [trimmedVal hasSuffix:@"'"])) {
        if (trimmedVal.length > 1) {
            return [trimmedVal substringWithRange:NSMakeRange(1, trimmedVal.length - 2)];
        }
        return @"";
    }
    return trimmedVal;
}

- (NSDictionary<NSString *, id> *)parseTomlString:(NSString *)s {
    if (!s) return nil;
    NSMutableDictionary<NSString *, id> *root = [NSMutableDictionary dictionary];
    NSMutableDictionary *currentTable = root;
    NSString *currentTableName = nil;
    NSArray<NSString *> *lines = [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trimmed hasPrefix:@"#"] || trimmed.length == 0) continue;

        if ([trimmed hasPrefix:@"[["] && [trimmed hasSuffix:@"]]"]) {
            currentTableName = [trimmed substringWithRange:NSMakeRange(2, trimmed.length - 4)];
            NSMutableArray *array = root[currentTableName] ?: [NSMutableArray array];
            root[currentTableName] = array;
            currentTable = [NSMutableDictionary dictionary];
            [array addObject:currentTable];
            continue;
        } else if ([trimmed hasPrefix:@"["] && [trimmed hasSuffix:@"]"]) {
            currentTableName = [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
            currentTable = [NSMutableDictionary dictionary];
            root[currentTableName] = currentTable;
            continue;
        }

        NSRange eqRange = [trimmed rangeOfString:@"="];
        if (eqRange.location != NSNotFound) {
            NSString *key = [[trimmed substringToIndex:eqRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *valPart = [trimmed substringFromIndex:NSMaxRange(eqRange)];
            id value = [self parseTomlValue:valPart inLines:lines atIndex:&i];
            if (value) {
                currentTable[key] = value;
            }
        }
    }
    return root;
}

// ---------- 初始化 ----------
+ (instancetype)sharedService {
    static ModService *s;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[ModService alloc] init];
    });
    return s;
}

- (instancetype)init {
    if (self = [super init]) {
        _onlineSearchEnabled = NO;

        // 下载已改走 [PLDownloadClient sharedClient]（镜像候选 + SHA1 校验 + 断点续传），
        // 不再自建 NSURLSession download delegate
        _downloadStateLock = [[NSLock alloc] init];
        _downloadTaskItems = [NSMutableDictionary dictionary];
        _downloadOperations = [NSMutableDictionary dictionary];
        _downloadGenerations = [NSMutableDictionary dictionary];
        _downloadAccumulatedBytes = [NSMutableDictionary dictionary];
        _downloadTotalBytes = [NSMutableDictionary dictionary];
        _downloadLastSpeeds = [NSMutableDictionary dictionary];
        _downloadRequests = [NSMutableDictionary dictionary];
        _downloadProgressHandlers = [NSMutableDictionary dictionary];
        _downloadCompletionHandlers = [NSMutableDictionary dictionary];

        // 初始化缓存
        _metadataCache = [NSMutableDictionary dictionary];
        _checkpointTimes = [NSMutableDictionary dictionary];
        _cacheQueue = dispatch_queue_create("com.amethyst.modcache", DISPATCH_QUEUE_CONCURRENT);
    }
    return self;
}

// ---------- 辅助方法 ----------
// ★ Task274-h S14：sha1ForFileAtPath 零调用副本已删除（rg 亲证全文件仅此 1 处定义
//   零调用；活副本在 ModpackExportService:939 有分块实现）。
// ★ Task270（屎山 A1）：逐字节克隆收敛 utils.m 单点 AMEIconCachePathForURL（行为零变更）。
- (NSString *)iconCachePathForURL:(NSString *)urlString {
    return AMEIconCachePathForURL(urlString, @"mod_icons");
}

- (nullable NSData *)readFileFromJar:(NSString *)jarPath entryName:(NSString *)entryName {
    if (!jarPath || !entryName) return nil;
    NSError *err = nil;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:jarPath error:&err];
    if (!archive || err) return nil;
    NSData *data = [archive extractDataFromFile:entryName error:&err];
    return data;
}

/// 解析 profile 的 gameDir 为绝对路径。
/// profile gameDir 通常是相对路径（如 "./custom_gamedir/{name}"），需相对于 POJAV_GAME_DIR 解析。
/// 之前直接使用相对路径会导致 mods 文件夹找不到（fileExistsAtPath 对相对路径基于 cwd 解析，
/// 而 cwd 不一定是 POJAV_GAME_DIR）。
/// ★ Task225（反馈 #5：安装模组端默认共享目录——上游 PCL VER-ISOLATE 嗅探
///   语义补齐）：gameDir 缺失或 "." 时，若 versions/<lastVersionId>/game
///   （或旧口径 versions/<lastVersionId>/）下已有 mods/saves 等用户数据，
///   【自动解析为该隔离目录】——与上游 amePCLVersionIsolationForProfile 的
///   第 2 步（ShouldBeIndie 启发式）同源：目录形状说明用户已把该版本当
///   隔离实例用，mod 安装/扫描只认隔离目录，不再落到共享根。
- (nullable NSString *)resolveAbsoluteGameDirForProfile:(NSString *)profileName {
    // ★ Task274-h S7：nil 入参跟随当前选中实例（ame267 语义），不再落恒 miss 的
    // @"default" 字面量（真实默认键 "(Default)"；对齐 Task270 M1 服务层口径）。
    if (!profileName.length) profileName = PLProfiles.current.selectedProfileName ?: @"(Default)";
    NSString *profile = profileName;
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if (![prof isKindOfClass:[NSDictionary class]]) return nil;
        NSString *gameDir = prof[@"gameDir"];
        if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0 || [gameDir isEqualToString:@"."]) {
            // Task225：无显式隔离 → 嗅探版本目录形状（auto 语义）。
            NSString *ame225_sniffed = [ModService ame225_sniffedIsolationGameDirForProfile:prof];
            if (ame225_sniffed.length > 0) {
                NSLog(@"[ModService] Task225 auto-sniffed isolation for profile %@ -> %@ (mods/saves present)",
                      profile, ame225_sniffed.lastPathComponent);
                return ame225_sniffed;
            }
            // "." 表示主目录
            const char *env = getenv("POJAV_GAME_DIR");
            return env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        }
        if ([gameDir isAbsolutePath]) {
            return gameDir;
        }
        // 相对路径，相对于 POJAV_GAME_DIR 解析
        const char *env = getenv("POJAV_GAME_DIR");
        NSString *baseDir = env ? [NSString stringWithUTF8String:env] : NSHomeDirectory();
        // 去掉 "./" 前缀（如果有），stringByAppendingPathComponent 能正确处理
        NSString *cleanGameDir = [gameDir hasPrefix:@"./"] ? [gameDir substringFromIndex:2] : gameDir;
        return [baseDir stringByAppendingPathComponent:cleanGameDir];
    } @catch (NSException *ex) {
        return nil;
    }
}

/// Task225：目录形状嗅探（上游 ameVISniffVersionFolder / PCL ShouldBeIndie
/// 同源规则）——versions/<vid>/game 优先，旧口径 versions/<vid>/ 兑底；
/// mods 或 saves 目录下存在任一非隐藏条目即判“已隔离”。返回隔离目录的
/// 绝对路径；不命中返回 nil。静态方法：ModsManager 徽标 / 启动链都可调。
+ (nullable NSString *)ame225_sniffedIsolationGameDirForProfile:(NSDictionary *)prof {
    if (![prof isKindOfClass:[NSDictionary class]]) return nil;
    NSString *vid = prof[@"lastVersionId"];
    if (![vid isKindOfClass:[NSString class]] || vid.length == 0) return nil;
    const char *env = getenv("POJAV_GAME_DIR");
    if (!env || !*env) return nil;
    NSString *base = [NSString stringWithUTF8String:env];
    if (base.length == 0) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rel in @[
        [NSString stringWithFormat:@"versions/%@/game", vid],
        [NSString stringWithFormat:@"versions/%@", vid],
    ]) {
        NSString *dir = [base stringByAppendingPathComponent:rel];
        for (NSString *leaf in @[@"mods", @"saves"]) {
            NSString *probe = [dir stringByAppendingPathComponent:leaf];
            NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:probe error:nil];
            for (NSString *e in entries) {
                if (![e hasPrefix:@"."]) {
                    return dir;
                }
            }
        }
    }
    return nil;
}

/// ★ Task271（271-a F2 自适应恢复·用户铁律"写个自适应恢复"）：启动自愈——
///   注册表与运行时行为对齐。运行时嗅探（ame225/JavaLauncher 同口径）早已
///   把 versions/<vid>/game|/ 视作隔离目录，但 profile 条目 gameDir 缺失/
///   "." 时（历史安装器写入 gameDir="."、旧版整条替换 saveProfile 抹键等，
///   装机实锤：fabric-loader-* 实例模组列表变共享目录），模组管理页与下载
///   落点仍走共享。启动时把【实际存在隔离数据】的 profile 落定为隔离：
///   幂等（已显式配置的条目绝不碰）、保守（只认非空 mods/saves）、单键覆写
///   （其余字段原样存活）。
+ (void)ame271_selfHealStrandedIsolation {
    // ★ Task275 F6：导入/迁移进行中让路（幂等，下轮启动再愈）——原自愈写与
    //   后台导入写者无锁竞跑（iPad 多窗口 willConnect 可重入放大触发面）。
    if ([ModpackImportService ame269_isImportBusy]) {
        NSLog(@"[Ame271] self-heal skipped: import busy");
        return;
    }
    const char *ame271_env = getenv("POJAV_GAME_DIR");
    if (!ame271_env || !*ame271_env) return;
    NSString *ame271_base = [NSString stringWithUTF8String:ame271_env];
    if (ame271_base.length == 0) return;
    NSDictionary *ame271_profiles = PLProfiles.current.profiles;
    if (![ame271_profiles isKindOfClass:[NSDictionary class]] || ame271_profiles.count == 0) return;
    NSInteger ame271_healed = 0;
    for (NSString *ame271_key in [ame271_profiles allKeys]) {
        NSDictionary *ame271_prof = ame271_profiles[ame271_key];
        if (![ame271_prof isKindOfClass:[NSDictionary class]]) continue;
        NSString *ame271_gd = ame271_prof[@"gameDir"];
        BOOL ame271_unset = (![ame271_gd isKindOfClass:[NSString class]] || ame271_gd.length == 0
            || [ame271_gd isEqualToString:@"."] || [ame271_gd isEqualToString:@"./"]);
        if (!ame271_unset) continue;                       // 已显式配置：绝不碰
        NSString *ame271_hit = [self ame225_sniffedIsolationGameDirForProfile:ame271_prof];
        if (ame271_hit.length == 0) continue;              // 无隔离数据：空转零 IO
        // 嗅探命中 → 反推注册表相对路径（优先新口径 versions/<vid>/game）
        NSString *ame271_vid = ame271_prof[@"lastVersionId"];
        if (![ame271_vid isKindOfClass:[NSString class]] || ame271_vid.length == 0) continue;
        NSString *ame271_rel = [NSString stringWithFormat:@"versions/%@/game", ame271_vid];
        if (![ame271_hit isEqualToString:[ame271_base stringByAppendingPathComponent:ame271_rel]]) {
            ame271_rel = [NSString stringWithFormat:@"versions/%@", ame271_vid];
        }
        NSMutableDictionary *ame271_updated = [ame271_prof mutableCopy];
        ame271_updated[@"gameDir"] = ame271_rel;
        [PLProfiles.current applyChanges:^(NSMutableDictionary<NSString *, id> *ame275_profiles) {
            ame275_profiles[ame271_key] = ame271_updated;
        }];
        ame271_healed++;
        NSLog(@"[Ame271] self-heal: profile \"%@\" gameDir '%@' -> %@ (stranded isolation data)",
              ame271_key, ame271_gd ?: @"(nil)", ame271_rel);
    }
    // ★ Task272（默认隔离收敛清扫·用户铁律"自适应恢复"第二阶段）：F2 只治
    //   "有滞留隔离数据"的条目；隔离目录为空/不存在的旧条目（gameDir='.' 且
    //   从未显式选择）永远滞留共享根 = 跨实例串目录（装机实锤：26.2 实例模组
    //   列表显示的是隔壁 26.1.2 的模组）。本清扫把从未被用户显式配置过的 '.'
    //   条目收敛到 versions/<vid>/game（与 Task242 新实例默认隔离语义对齐）：
    //   - gameDirExplicit 标记（三态选择器/自定义路径写入）= 用户显式选择，绝不碰
    //   - default 主实例不参与（它就是共享根本体）
    //   - 整合包实例 gameDir 为 ./custom_gamedir/... 非 '.'，天然不在范围
    //   - 幂等：跑过一次后 gameDir 已非 '.'；隔离目录由 ensureModsFolder 惰性创建
    NSInteger ame272_swept = 0;
    for (NSString *ame272_key in [ame271_profiles allKeys]) {
        // Task274: 真实默认键是 "(Default)"（旧守卫 @"default" 恒不匹配 =
        // (Default) 主实例会被误 sweep 进隔离，共享模组从列表"消失"）；
        // 两个键名都排除，宁可漏扫不可误扫。
        if ([ame272_key isEqualToString:@"(Default)"] || [ame272_key isEqualToString:@"default"]) continue;
        NSDictionary *ame272_prof = ame271_profiles[ame272_key];
        if (![ame272_prof isKindOfClass:[NSDictionary class]]) continue;
        if (ame272_prof[@"gameDirExplicit"] != nil) continue;   // 显式选择过：尊重用户
        NSString *ame272_gd = ame272_prof[@"gameDir"];
        BOOL ame272_unset = (![ame272_gd isKindOfClass:[NSString class]] || ame272_gd.length == 0
            || [ame272_gd isEqualToString:@"."] || [ame272_gd isEqualToString:@"./"]);
        if (!ame272_unset) continue;
        NSString *ame272_vid = ame272_prof[@"lastVersionId"];
        if (![ame272_vid isKindOfClass:[NSString class]] || ame272_vid.length == 0) continue;
        NSMutableDictionary *ame272_updated = [ame272_prof mutableCopy];
        ame272_updated[@"gameDir"] = [NSString stringWithFormat:@"versions/%@/game", ame272_vid];
        [PLProfiles.current applyChanges:^(NSMutableDictionary<NSString *, id> *ame275_profiles) {
            ame275_profiles[ame272_key] = ame272_updated;
        }];
        ame272_swept++;
        NSLog(@"[Ame271] default-isolation sweep: profile \"%@\" gameDir '%@' -> versions/%@/game (never explicitly configured)",
              ame272_key, ame272_gd ?: @"(nil)", ame272_vid);
    }
    if (ame272_swept > 0) {
        ame271_healed += ame272_swept;
        NSLog(@"[Ame271] default-isolation sweep: %ld profile(s) converged to versions/<id>/game",
              (long)ame272_swept);
    }
    if (ame271_healed > 0) {
        [PLProfiles.current save];
        NSLog(@"[Ame271] self-heal done: %ld profile(s) re-isolated", (long)ame271_healed);
    }
}

- (nullable NSString *)existingModsFolderForProfile:(NSString *)profileName {
    // ★ Task274-h S7：nil 入参跟随当前选中实例（ame267 语义），不再落恒 miss 的
    // @"default" 字面量（真实默认键 "(Default)"；对齐 Task270 M1 服务层口径）。
    if (!profileName.length) profileName = PLProfiles.current.selectedProfileName ?: @"(Default)";
    NSString *profile = profileName;
    NSFileManager *fm = [NSFileManager defaultManager];

    // 优先用 profile gameDir（已解析为绝对路径）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        NSString *modsPath = [resolvedGameDir stringByAppendingPathComponent:@"mods"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:modsPath isDirectory:&isDir] && isDir) {
            return modsPath;
        }
    }

    // 回退到 POJAV_GAME_DIR/mods
    const char *gameDirC = getenv("POJAV_GAME_DIR");
    if (gameDirC) {
        NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
        NSString *modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:modsPath isDirectory:&isDir] && isDir) {
            return modsPath;
        }
    }
    return nil;
}

/// Task219（⑪ 版本隔离深度优化·用户指令“支持自动识别是否开启版本隔离，
/// 比如 Mod 端”）：隔离优先的 mods 目录解析——profile 一旦配置了 gameDir
///（隔离此版本 / 自定义目录），下载与扫描【只认】隔离目录，缺目录即创建，
/// 绝不回退共享目录。旧 existingModsFolderForProfile 的“隔离目录还没建
/// mods/ 就回退 POJAV_GAME_DIR/mods”语义 = 隔离版本下载的 mod 落到共享
/// 目录，游戏里永远看不到（装机可复现：新开隔离 → 装模组 → 进游戏无此
/// 模组）。返回 nil 仅当两条路径都无法解析。
- (nullable NSString *)ame219_isolationFirstModsFolderForProfile:(NSString *)profileName {
    NSError *ame219_err = nil;
    NSString *ame219_path = [self ensureModsFolderForProfile:profileName error:&ame219_err];
    if (ame219_path.length > 0) {
        return ame219_path;
    }
    // 兑底：ensure 失败（如创建受限）退回“存在即用”语义，保持旧行为下限
    return [self existingModsFolderForProfile:profileName];
}

/// Task264：当前 profile 实际生效的 mods 目录（与 scanModsForProfile 同源同目录，
/// Task219 隔离优先语义）。模组管理页展示"扫描目录"提示行 + 文件 App 定点打开。
/// 用户中途放入该目录的 .jar 重扫后必然可见；此前导入按钮走 ensureModsFolderForProfile(nil)
/// 恒解析到 default 主目录，整合包实例的隔离目录永远收不到文件——中途加 mod 不显示根因。
- (nullable NSString *)ame264_effectiveModsFolderForProfile:(NSString *)profileName {
    return [self ame219_isolationFirstModsFolderForProfile:profileName];
}

/// Task219：当前 profile 的隔离态对外暴露（ModsManager 徽标用）。
/// 0 = 不隔离（gameDir 缺失或 "." 且嗅探未命中）；1 = 显式隔离
/// （gameDir 为 versions/<id>/... 或自定义目录）；2 = 嗅探隔离（Task225：
/// gameDir 为 "." 但 versions/<vid>/ 下已有 mods/saves——上游 auto 语义）。
+ (NSInteger)ame219_isolationStateForProfile:(NSString *)profileName {
    // ★ Task274-h S7：nil 入参跟随当前选中实例（ame267 语义），不再落恒 miss 的
    // @"default" 字面量（真实默认键 "(Default)"；对齐 Task270 M1 服务层口径）。
    if (!profileName.length) profileName = PLProfiles.current.selectedProfileName ?: @"(Default)";
    NSString *profile = profileName;
    @try {
        NSDictionary *profiles = PLProfiles.current.profiles;
        NSDictionary *prof = profiles[profile];
        if (![prof isKindOfClass:[NSDictionary class]]) return 0;
        NSString *gameDir = prof[@"gameDir"];
        if (![gameDir isKindOfClass:[NSString class]] || gameDir.length == 0) {
            // Task225：无显式 gameDir → 嗅探（auto 语义）
            return [self ame225_sniffedIsolationGameDirForProfile:prof] != nil ? 2 : 0;
        }
        if ([gameDir isEqualToString:@"."]) {
            return [self ame225_sniffedIsolationGameDirForProfile:prof] != nil ? 2 : 0;
        }
        return 1;
    } @catch (NSException *ex) {
        return 0;
    }
}

/// 获取当前 profile 的 mods 目录，不存在时自动创建
- (nullable NSString *)ensureModsFolderForProfile:(NSString *)profileName error:(NSError **)error {
    // ★ Task274-h S7：nil 入参跟随当前选中实例（ame267 语义），不再落恒 miss 的
    // @"default" 字面量（真实默认键 "(Default)"；对齐 Task270 M1 服务层口径）。
    if (!profileName.length) profileName = PLProfiles.current.selectedProfileName ?: @"(Default)";
    NSString *profile = profileName;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *modsPath = nil;

    // 优先用 profile gameDir（已解析为绝对路径）
    NSString *resolvedGameDir = [self resolveAbsoluteGameDirForProfile:profile];
    if (resolvedGameDir.length > 0) {
        modsPath = [resolvedGameDir stringByAppendingPathComponent:@"mods"];
    }

    if (!modsPath) {
        const char *gameDirC = getenv("POJAV_GAME_DIR");
        if (gameDirC) {
            NSString *gameDir = [NSString stringWithUTF8String:gameDirC];
            modsPath = [gameDir stringByAppendingPathComponent:@"mods"];
        }
    }

    if (!modsPath) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModService" code:1 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_105", nil)}];
        }
        return nil;
    }

    BOOL isDir = NO;
    if (![fm fileExistsAtPath:modsPath isDirectory:&isDir]) {
        // 目录不存在，创建
        NSError *createError = nil;
        [fm createDirectoryAtPath:modsPath withIntermediateDirectories:YES attributes:nil error:&createError];
        if (createError) {
            if (error) *error = createError;
            return nil;
        }
        NSLog(@"[ModService] Created mods directory: %@", modsPath);
    } else if (!isDir) {
        if (error) {
            *error = [NSError errorWithDomain:@"ModService" code:2 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"i18n_str_451", nil), modsPath]}];
        }
        return nil;
    }
    return modsPath;
}

// ---------- 缓存方法 ----------
- (BOOL)needsRescanForPath:(NSString *)path {
    __block BOOL needs = YES;
    dispatch_sync(self.cacheQueue, ^{
        NSDate *lastScan = self.checkpointTimes[path];
        if (lastScan) {
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            NSDate *modifyDate = attrs[NSFileModificationDate];
            if (modifyDate && [modifyDate isEqualToDate:lastScan]) {
                needs = NO;
            }
        }
    });
    return needs;
}

- (void)updateCheckpointForPath:(NSString *)path {
    dispatch_barrier_async(self.cacheQueue, ^{
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *modifyDate = attrs[NSFileModificationDate];
        if (modifyDate) {
            self.checkpointTimes[path] = modifyDate;
        }
    });
}

- (nullable ModItem *)cachedModForPath:(NSString *)path {
    __block ModItem *item = nil;
    dispatch_sync(self.cacheQueue, ^{
        item = self.metadataCache[path];
    });
    return item;
}

- (void)cacheModItem:(ModItem *)item forPath:(NSString *)path {
    dispatch_barrier_async(self.cacheQueue, ^{
        self.metadataCache[path] = item;
    });
}

// ---------- 扫描模组（核心优化）----------
- (void)scanModsForProfile:(NSString *)profileName completion:(ModListHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Task219（⑪）：扫描改隔离优先——隔离 profile 只扫隔离目录（缺目录
        // 视为空列表，不再被共享目录的 mod 假装成"已安装"；下载侧同款
        // 语义，装哪儿扫哪儿）。
        NSString *modsFolder = [self ame219_isolationFirstModsFolderForProfile:profileName];
        NSMutableArray<ModItem *> *items = [NSMutableArray array];

        if (!modsFolder) {
            NSLog(@"[ModService] Task265 scan: profile=%@ folder=(nil) jars=0", profileName ?: @"(nil)");
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(items); });
            }
            return;
        }

        NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:modsFolder error:nil];
        dispatch_group_t group = dispatch_group_create();

        for (NSString *fileName in contents) {
            if ([fileName.lowercaseString hasSuffix:@".jar"] || [fileName.lowercaseString hasSuffix:@".jar.disabled"]) {
                NSString *fullPath = [modsFolder stringByAppendingPathComponent:fileName];

                // 检查缓存
                if (![self needsRescanForPath:fullPath]) {
                    ModItem *cached = [self cachedModForPath:fullPath];
                    if (cached) {
                        [items addObject:cached];
                        continue;
                    }
                }

                ModItem *mod = [[ModItem alloc] initWithFilePath:fullPath];
                [items addObject:mod];

                dispatch_group_enter(group);
                [self fetchMetadataForMod:mod completion:^(ModItem *populatedMod, NSError *error) {
                    if (!error) {
                        [self cacheModItem:populatedMod forPath:fullPath];
                        [self updateCheckpointForPath:fullPath];
                    }
                    dispatch_group_leave(group);
                }];
            }
        }

        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            // ★ Task265：扫描结果锚——与 download dest 锚成对，目录错位一轮日志定音
            NSLog(@"[ModService] Task265 scan: profile=%@ folder=%@ jars=%ld",
                  profileName ?: @"(nil)", modsFolder, (long)items.count);
            [items sortUsingComparator:^NSComparisonResult(ModItem *obj1, ModItem *obj2) {
                NSString *name1 = obj1.displayName ?: obj1.fileName;
                NSString *name2 = obj2.displayName ?: obj2.fileName;
                return [name1 localizedCaseInsensitiveCompare:name2];
            }];
            if (completion) completion(items);
        });
    });
}

// ---------- 元数据获取（原逻辑，仅被上面调用）----------
- (void)fetchMetadataForMod:(ModItem *)mod completion:(ModMetadataHandler)completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            // Fabric
            NSData *fabricData = [self readFileFromJar:mod.filePath entryName:@"fabric.mod.json"];
            if (fabricData) {
                NSDictionary *json = [NSJSONSerialization JSONObjectWithData:fabricData options:0 error:nil];
                if ([json isKindOfClass:[NSDictionary class]]) {
                    mod.isFabric = YES;
                    mod.onlineID = json[@"id"];
                    mod.version = json[@"version"];
                    mod.displayName = json[@"name"];
                    mod.modDescription = json[@"description"];
                    mod.author = [json[@"authors"] componentsJoinedByString:@", "];

                    NSDictionary *deps = json[@"depends"];
                    if ([deps isKindOfClass:[NSDictionary class]] && [deps[@"minecraft"] isKindOfClass:[NSString class]]) {
                        mod.gameVersion = deps[@"minecraft"];
                    }

                    NSString *iconPath = json[@"icon"];
                    if ([iconPath isKindOfClass:[NSString class]]) {
                        NSData *iconData = [self readFileFromJar:mod.filePath entryName:iconPath];
                        if (iconData) mod.icon = [[UIImage alloc] initWithData:iconData];
                    }
                    if (completion) completion(mod, nil);
                    return;
                }
            }

            // Forge / NeoForge
            NSData *tomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/mods.toml"];
            if (tomlData) {
                mod.isForge = YES;
            } else {
                tomlData = [self readFileFromJar:mod.filePath entryName:@"META-INF/neoforge.mods.toml"];
                if (tomlData) mod.isNeoForge = YES;
            }

            if (tomlData) {
                NSString *tomlString = [[NSString alloc] initWithData:tomlData encoding:NSUTF8StringEncoding];
                NSDictionary<NSString *, id> *toml = [self parseTomlString:tomlString];
                NSArray *mods = toml[@"mods"];
                if ([mods isKindOfClass:[NSArray class]] && mods.count > 0) {
                    NSDictionary *modInfo = mods.firstObject;
                    if ([modInfo isKindOfClass:[NSDictionary class]]) {
                        mod.onlineID = modInfo[@"modId"];
                        mod.version = modInfo[@"version"];
                        mod.displayName = modInfo[@"displayName"];
                        mod.modDescription = modInfo[@"description"];
                        mod.author = modInfo[@"authors"];

                        NSArray *deps = nil;
                        for (NSString *key in toml) {
                            if ([key hasPrefix:@"dependencies"]) {
                                deps = toml[key];
                                break;
                            }
                        }
                        if ([deps isKindOfClass:[NSArray class]]) {
                            for (NSDictionary *depInfo in deps) {
                                if ([depInfo isKindOfClass:[NSDictionary class]] && [depInfo[@"modId"] isEqualToString:@"minecraft"]) {
                                    mod.gameVersion = depInfo[@"versionRange"];
                                    break;
                                }
                            }
                        }

                        NSString *logoFile = modInfo[@"logoFile"];
                        if (logoFile.length > 0) {
                            NSData *logoData = [self readFileFromJar:mod.filePath entryName:logoFile];
                            if (logoData) mod.icon = [[UIImage alloc] initWithData:logoData];
                        }
                        if (completion) completion(mod, nil);
                        return;
                    }
                }
            }
        } @catch (NSException *exception) {
            NSLog(@"[ModService] CRITICAL: Exception while parsing %@: %@", mod.fileName, exception);
        }
        if (completion) completion(mod, nil);
    });
}

// ---------- 文件操作（启用/禁用、删除）----------
- (BOOL)toggleEnableForMod:(ModItem *)mod error:(NSError **)error {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *currentPath = mod.filePath;

    // Task217（"部分 Mod 无法点击"根修前置）：源文件存在性预检。列表项可能
    // 因更新替换 / 文件 App 手工整理后指向不存在的路径（moveItemAtPath 的
    // ENOENT 以前一路裸抛，管理页只 NSLog，开关被 updateToggleState 弹回 =
    // 用户视角"点了没反应"）。返回明确本地化错误；调用方据此弹窗 + 自愈重扫。
    BOOL ame217_srcIsDir = NO;
    if (currentPath.length == 0 ||
        ![fileManager fileExistsAtPath:currentPath isDirectory:&ame217_srcIsDir] || ame217_srcIsDir) {
        if (error) *error = [NSError errorWithDomain:@"ModServiceError" code:201
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"mods.toggle.source_missing", nil),
                currentPath.length > 0 ? currentPath.lastPathComponent : @"?"]}];
        return NO;
    }

    NSString *newPath;

    if (mod.disabled) {
        if ([currentPath.lowercaseString hasSuffix:@".jar.disabled"]) {
            newPath = [currentPath substringToIndex:currentPath.length - 9];
        } else {
            if (error) *error = [NSError errorWithDomain:@"ModServiceError" code:101 userInfo:@{NSLocalizedDescriptionKey:localize(@"i18n_str_452", nil)}];
            return NO;
        }
    } else {
        newPath = [currentPath stringByAppendingString:@".disabled"];
    }

    // Task217：目标同名预检。mods/ 同时存在 foo.jar 与 foo.jar.disabled 时
    // "启用旧档"必然撞名（更新流程与手工整理的常见残留）；裸 moveItemAtPath
    // 只会给出不可读的 NSFileWriteFileExists。明确告知冲突文件名，用户可在
    // 文件 App（本应用已开 UIFileSharing）或滑动删除里自行清理。
    if ([fileManager fileExistsAtPath:newPath]) {
        if (error) *error = [NSError errorWithDomain:@"ModServiceError" code:202
            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"mods.toggle.dest_exists", nil),
                newPath.lastPathComponent]}];
        return NO;
    }

    BOOL success = [fileManager moveItemAtPath:currentPath toPath:newPath error:error];
    if (success) {
        mod.filePath = newPath;
        mod.fileName = [newPath lastPathComponent];
        [mod refreshDisabledFlag];
    }
    return success;
}

- (BOOL)deleteMod:(ModItem *)mod error:(NSError **)error {
    return [[NSFileManager defaultManager] removeItemAtPath:mod.filePath error:error];
}

// ---------- 下载（PLDownloadClient 统一下载器：镜像候选 + SHA1 校验 + 增量命中 + 断点续传）----------
- (void)downloadMod:(ModItem *)mod toProfile:(NSString *)profileName completion:(ModDownloadHandler)completion {
    [self downloadMod:mod toProfile:profileName expectedSHA1:nil progress:nil completion:completion];
}

// ---------- 带进度回调的下载 ----------
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString *)profileName
            progress:(void (^)(NSProgress *downloadProgress))progress
          completion:(ModDownloadHandler)completion {
    [self downloadMod:mod toProfile:profileName expectedSHA1:nil progress:progress completion:completion];
}

// ---------- 带 SHA1 校验的下载（spec Task 5.1：expectedSHA1 传入即启用校验）----------
- (void)downloadMod:(ModItem *)mod
          toProfile:(NSString *)profileName
       expectedSHA1:(nullable NSString *)expectedSHA1
           progress:(nullable void (^)(NSProgress *downloadProgress))progress
         completion:(ModDownloadHandler)completion {
    // Task269 末梢自愈：目标实例不存在（升级迁移合并后残留的旧实例名引用）→
    // 回落当前选中实例，杜绝"下载进不存在的实例"再次制造错位。
    if (profileName.length > 0 && !PLProfiles.current.profiles[profileName]) {
        NSString *ame269_fallback = PLProfiles.current.selectedProfileName;
        NSLog(@"[ModService] Task269: target profile \"%@\" gone -> fallback to selected \"%@\"",
              profileName, ame269_fallback ?: @"(nil)");
        profileName = ame269_fallback;
    }
    NSString *modsFolder = [self ame219_isolationFirstModsFolderForProfile:profileName];
    // ★ Task265：下载目标锚——今后任何"下载了但游戏/管理页看不到"直接看这行
    NSLog(@"[ModService] Task265 download dest: profile=%@ folder=%@ file=%@",
          profileName ?: @"(nil)", modsFolder, mod.fileName ?: @"(nil)");
    if (!modsFolder) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ModServiceError" code:1 userInfo:@{NSLocalizedDescriptionKey:localize(@"i18n_str_453", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    NSURL *url = [NSURL URLWithString:mod.selectedVersionDownloadURL];
    if (!url) {
        if (completion) {
            NSError *error = [NSError errorWithDomain:@"ModServiceError" code:2 userInfo:@{NSLocalizedDescriptionKey:localize(@"i18n_str_454", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(error); });
        }
        return;
    }

    NSString *destinationPath = [modsFolder stringByAppendingPathComponent:mod.fileName];

    // 注册到统一下载任务管理器（rawTask 稍后赋值为 PLDownloadOperation；悬浮球已移除，始终注册以便下载任务列表跟踪）
    NSString *resourceName = mod.fileName.length > 0 ? mod.fileName : (mod.displayName.length > 0 ? mod.displayName : @"mod");
    NSString *displayName = mod.displayName.length > 0 ? mod.displayName : resourceName;
    // ★ Task274-h S8：退役键 general.download_source（Task218 声明无写入方，恒 nil
    //   → @"official" 来源标签失真）→ PLMirrorCenter legacySourceTokenForType
    //   （Task218 收敛口径，对齐 World/DP/RP/Shader 四服务）。
    NSString *downloadSource = [PLMirrorCenter legacySourceTokenForType:PLMirrorResourceTypeAssetDownload];
    DownloadTaskItem *taskItem = [[DownloadTaskManager sharedManager]
        registerTaskWithResourceType:DownloadTaskResourceTypeMod
                        resourceName:resourceName
                         displayName:displayName
                      downloadSource:downloadSource
                             rawTask:nil
                      supportsResume:YES
                             iconURL:mod.iconURL];
    taskItem.downloadURL = mod.selectedVersionDownloadURL;
    // ★ Task266：下载目标实例随任务标注——资源管理页据 targetProfileName
    //   与本页生效实例比对，跨实例下载展示横幅+一键切换（"游戏加载了、
    //   管理页不显示"的实例错位自解释修复；同锚 Task265 download dest）。
    taskItem.targetProfileName = profileName;
    // redesign-download-ui Phase 4：单文件下载接入统一进度页——
    // PLTaskStagesSingleFile 单阶段 + autoPresentDetail 自动弹出 PLTaskProgressViewController
    [[DownloadTaskManager sharedManager] setTaskWithId:taskItem.taskId stages:PLTaskStagesSingleFile()];
    taskItem.autoPresentDetail = YES;

    // retryHandler：FCL 风格重新下载，复用同一 taskItem，重新发起 PLDownloadClient 请求
    __weak typeof(self) weakSelf = self;
    taskItem.retryHandler = ^id(DownloadTaskItem *taskItemRef) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return nil;
        return [strongSelf restartPLDownloadForTaskId:taskItemRef.taskId];
    };

    PLDownloadRequest *request = [[PLDownloadRequest alloc] init];
    // 镜像候选列表：原始 CDN URL（cdn.modrinth.com / edge.forgecdn.net 等）+ MCIM 镜像，
    // 按 download.assetDownloadSource 策略排序（PLMirrorCenter 统一收敛，替代旧版独立镜像工具类）
    request.candidateURLs = [PLMirrorCenter candidateURLsForOriginalURL:url
                                                          resourceType:PLMirrorResourceTypeAssetDownload];
    // Task 5.1：expectedSHA1（版本模型 files[].hashes.sha1）传入即启用 SHA1 校验，
    // 校验失败由 PLDownloadClient 内部按镜像/退避节奏重试
    request.expectedSHA1 = expectedSHA1;
    // Task 5.2：目标文件已存在且校验通过 → PLDownloadClient 零流量直接成功（增量下载）；
    // 目标路径语义与原实现一致（mods/<fileName>.jar）
    request.destinationPath = destinationPath;
    // taskIdentifier 用 DownloadTaskManager 的 taskId，resumeData 断点数据跨次下载可复用
    request.taskIdentifier = taskItem.taskId;
    // 无 SHA1 时对 .jar（zip 格式）做 EOCD 兜底完整性校验
    request.allowZipFallbackCheck = YES;

    [self startPLDownloadWithRequest:request taskItem:taskItem progress:progress completion:completion];
}

#pragma mark - Task267 最近 mod 下载落点记录（模组管理页对账数据源）

// 下载先于开页场景：Task266 横幅靠实时通知，页面不在场时通知够不着。
// 本记录持久于进程生命周期，模组管理页每次 viewWillAppear 对账补挂横幅。
// 回调线程为 PLDownloadClient 完成队列（非主线程），@synchronized 护账。
static NSString *_ame267_lastDLProfile = nil;
static NSString *_ame267_lastDLFile = nil;
static double _ame267_lastDLTs = 0.0;

+ (void)ame267_noteLastModDownloadToProfile:(NSString *)profileName file:(NSString *)fileName {
    @synchronized ([ModService class]) {
        _ame267_lastDLProfile = [profileName copy];
        _ame267_lastDLFile = [fileName copy];
        _ame267_lastDLTs = [[NSDate date] timeIntervalSince1970];
    }
    NSLog(@"[ModService] Task267 last-download record: profile=%@ file=%@", profileName ?: @"(nil)", fileName ?: @"(nil)");
}

+ (nullable NSDictionary<NSString *, id> *)ame267_lastModDownload {
    @synchronized ([ModService class]) {
        if (_ame267_lastDLTs <= 0.0) return nil;
        return @{ @"profile": _ame267_lastDLProfile ?: @"",
                  @"file":    _ame267_lastDLFile ?: @"",
                  @"ts":      @(_ame267_lastDLTs) };
    }
}

#pragma mark - PLDownloadClient 封装（进度 delta 累计 / 速率采样 / 完成分发）

/// 发起（或重发）PLDownloadClient 请求并挂接进度、速率、完成回调。
/// progress/completion 传 nil 时不覆盖已登记的回调（retryHandler 重发时复用首次回调）。
- (nullable PLDownloadOperation *)startPLDownloadWithRequest:(PLDownloadRequest *)request
                                                     taskItem:(DownloadTaskItem *)taskItem
                                                     progress:(nullable void(^)(NSProgress *))progress
                                                   completion:(nullable ModDownloadHandler)completion {
    NSString *taskId = taskItem.taskId;
    __weak typeof(self) weakSelf = self;

    [self.downloadStateLock lock];
    NSInteger generation = [self.downloadGenerations[taskId] integerValue] + 1;
    self.downloadGenerations[taskId] = @(generation);
    self.downloadTaskItems[taskId] = taskItem;
    self.downloadRequests[taskId] = request;
    if (progress) self.downloadProgressHandlers[taskId] = progress;
    if (completion) self.downloadCompletionHandlers[taskId] = completion;
    // 重发从头下载：归零累计（PLDownloadClient 的负 delta 回退语义在单次 operation 内自洽）
    self.downloadAccumulatedBytes[taskId] = @(0);
    self.downloadTotalBytes[taskId] = @(-1);
    self.downloadLastSpeeds[taskId] = @(0.0);
    [self.downloadStateLock unlock];

    PLDownloadOperation *operation = [[PLDownloadClient sharedClient] startRequest:request
                                                                          progress:^(int64_t deltaBytes, int64_t totalExpectedBytes) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadDelta:deltaBytes total:totalExpectedBytes taskId:taskId generation:generation];
    }
                                                                             speed:^(int64_t bytesPerSecond) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadSpeed:bytesPerSecond taskId:taskId generation:generation];
    }
                                                                        completion:^(BOOL success, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf handlePLDownloadCompletion:success error:error taskId:taskId generation:generation];
    }];
    if (!operation) {
        // 参数错误：PLDownloadClient 会异步回调 completion（error），由统一失败路径收尾
        return nil;
    }

    [self.downloadStateLock lock];
    self.downloadOperations[taskId] = operation;
    [self.downloadStateLock unlock];

    // rawTask 为 weak 引用：operation 由 PLDownloadClient 与本 Service 共同持有，
    // DownloadTaskManager 据此对 PLDownloadOperation 做 pause/resume/cancel
    taskItem.rawTask = operation;
    // 占用并发槽位（满则由 DownloadTaskManager 自动 pauseOperation 排队）
    [[DownloadTaskManager sharedManager] setTaskWithId:taskId state:DownloadTaskStateDownloading];
    // redesign-download-ui Phase 4：单阶段任务进入下载时将阶段0 置为 Running
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  status:PLTaskStageStatusRunning];
    return operation;
}

/// retryHandler 入口：复用登记的请求描述重新发起下载
- (nullable id)restartPLDownloadForTaskId:(NSString *)taskId {
    [self.downloadStateLock lock];
    PLDownloadRequest *request = self.downloadRequests[taskId];
    DownloadTaskItem *taskItem = self.downloadTaskItems[taskId];
    [self.downloadStateLock unlock];
    if (!request || !taskItem) return nil;
    return [self startPLDownloadWithRequest:request taskItem:taskItem progress:nil completion:nil];
}

/// 进度 delta 累计：负 delta（镜像切换/重试/断点失效回退）直接累加即可贴合真实进度
- (void)handlePLDownloadDelta:(int64_t)delta total:(int64_t)total taskId:(NSString *)taskId generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    int64_t accumulated = [self.downloadAccumulatedBytes[taskId] longLongValue] + delta;
    if (accumulated < 0) accumulated = 0;
    if (total > 0) self.downloadTotalBytes[taskId] = @(total);
    int64_t totalStored = [self.downloadTotalBytes[taskId] longLongValue];
    self.downloadAccumulatedBytes[taskId] = @(accumulated);
    double lastSpeed = [self.downloadLastSpeeds[taskId] doubleValue];
    void (^progressHandler)(NSProgress *) = self.downloadProgressHandlers[taskId];
    [self.downloadStateLock unlock];

    double fraction = totalStored > 0 ? (double)accumulated / (double)totalStored : -1.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                 progress:fraction
                                               totalBytes:totalStored
                                          downloadedBytes:accumulated];
    // redesign-download-ui Phase 4：单阶段任务的阶段进度与任务总进度保持一致
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                              stageAtIndex:0
                                                  progress:fraction
                                                 message:nil];

    if (!progressHandler) return;

    // 构造带 throughput/ETA 的 NSProgress，供调用方（DownloadViewController）
    // 在 FCL 风格的下载进度卡片上显示速度和 ETA
    NSProgress *downloadProgress = [NSProgress progressWithTotalUnitCount:totalStored > 0 ? totalStored : -1];
    downloadProgress.completedUnitCount = accumulated;
    if (lastSpeed > 0) {
        downloadProgress.throughput = @(lastSpeed);
        if (totalStored > accumulated) {
            downloadProgress.estimatedTimeRemaining = @((double)(totalStored - accumulated) / lastSpeed);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        progressHandler(downloadProgress);
    });
}

/// 速率采样（PLDownloadClient 每秒回调一次；结束/暂停时回调 0）
- (void)handlePLDownloadSpeed:(int64_t)bytesPerSecond taskId:(NSString *)taskId generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    self.downloadLastSpeeds[taskId] = @(bytesPerSecond);
    int64_t total = [self.downloadTotalBytes[taskId] longLongValue];
    int64_t accumulated = [self.downloadAccumulatedBytes[taskId] longLongValue];
    [self.downloadStateLock unlock];

    double eta = (bytesPerSecond > 0 && total > accumulated)
        ? (double)(total - accumulated) / (double)bytesPerSecond : 0.0;
    [[DownloadTaskManager sharedManager] updateTaskWithId:taskId
                                                    speed:(double)bytesPerSecond
                                  estimatedTimeRemaining:eta];
}

/// 完成分发：更新 DownloadTaskManager 状态并回调业务方（主线程）
- (void)handlePLDownloadCompletion:(BOOL)success
                             error:(nullable NSError *)error
                            taskId:(NSString *)taskId
                         generation:(NSInteger)generation {
    [self.downloadStateLock lock];
    if ([self.downloadGenerations[taskId] integerValue] != generation) {
        [self.downloadStateLock unlock];
        return;
    }
    ModDownloadHandler completion = self.downloadCompletionHandlers[taskId];
    // Task267：taskItem 在 cleanup 中被移除，落点记录需在清理前捕获
    DownloadTaskItem *ame267_item = self.downloadTaskItems[taskId];
    // ★ Task268（scan-d #1）：失败/取消保留 request+taskItem——retryHandler
    //   →restartPLDownloadForTaskId 靠 downloadRequests 命中，旧版一律清空
    //   = "重试"恒 nil → 任务永久卡"等待中"。成功路径才全量清理。
    if (success) {
        [self cleanupPLDownloadStateForTaskId:taskId];
    } else {
        [self.downloadOperations removeObjectForKey:taskId];
        [self.downloadGenerations removeObjectForKey:taskId];
        [self.downloadAccumulatedBytes removeObjectForKey:taskId];
        [self.downloadTotalBytes removeObjectForKey:taskId];
        [self.downloadLastSpeeds removeObjectForKey:taskId];
        [self.downloadProgressHandlers removeObjectForKey:taskId];
        [self.downloadCompletionHandlers removeObjectForKey:taskId];
    }
    [self.downloadStateLock unlock];

    DownloadTaskManager *manager = [DownloadTaskManager sharedManager];
    if (success) {
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusCompleted];
        [manager setTaskWithId:taskId state:DownloadTaskStateCompleted];
        // Task267：成功落盘才记入“最近 mod 下载落点”（模组管理页对账数据源）
        if ([ame267_item.resourceType isEqualToString:DownloadTaskResourceTypeMod]) {
            [ModService ame267_noteLastModDownloadToProfile:ame267_item.targetProfileName
                                                       file:(ame267_item.resourceName.length > 0 ? ame267_item.resourceName : ame267_item.displayName)]; // Task268：记实际落盘文件名（scan-d #7）
        }
    } else if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        // 用户取消（DownloadTaskManager 已置 Cancelled，这里幂等对齐）
        // ★ Task268（scan-d #8）：阶段行同步置 Skipped——旧版停在 Running，
        //   统一进度页显示"进行中"直到页面关闭。
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusSkipped];
        [manager setTaskWithId:taskId state:DownloadTaskStateCancelled];
    } else {
        [manager updateTaskWithId:taskId stageAtIndex:0 status:PLTaskStageStatusFailed];
        [manager updateTaskWithId:taskId error:error];
        [manager setTaskWithId:taskId state:DownloadTaskStateFailed];
    }

    if (completion) {
        NSError *capturedError = success ? nil : error;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(capturedError);
        });
    }
}

/// 清理指定任务的全部跟踪状态（须在 downloadStateLock 内调用）
- (void)cleanupPLDownloadStateForTaskId:(NSString *)taskId {
    [self.downloadTaskItems removeObjectForKey:taskId];
    [self.downloadOperations removeObjectForKey:taskId];
    [self.downloadGenerations removeObjectForKey:taskId];
    [self.downloadAccumulatedBytes removeObjectForKey:taskId];
    [self.downloadTotalBytes removeObjectForKey:taskId];
    [self.downloadLastSpeeds removeObjectForKey:taskId];
    [self.downloadRequests removeObjectForKey:taskId];
    [self.downloadProgressHandlers removeObjectForKey:taskId];
    [self.downloadCompletionHandlers removeObjectForKey:taskId];
}

@end