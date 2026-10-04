#import "utils.h"
//
//  AnnouncementService.m
//  Amethyst
//

#import "AnnouncementService.h"
#import "AnnouncementItem.h"
#import "LauncherPreferences.h"

/// 缓存有效期：30 分钟
static NSTimeInterval const kAnnouncementCacheInterval = 30 * 60;

/// 缓存键
static NSString * const kCachedAnnouncementsKey = @"cached_announcements";
static NSString * const kCachedAnnouncementsTimestampKey = @"cached_announcements_timestamp";

/// Task 130：公告源迁至本仓库托管（用户需求：“启动器公告改为仓库托管 JSON
/// 文件，摆脱上游依赖”）。旧默认源 air-api.vercel.app/api/announcements.php
/// 已 404 且不受我们控制；仓库根目录 announcements.json 随代码同仓维护，
/// 提交后全端即时生效（发版/修复公告不再依赖任何第三方在线服务）。
static NSString * const kRepoAnnouncementURL =
    @"https://raw.githubusercontent.com/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher/main/announcements.json";
/// 同一文件的 jsDelivr CDN 镜像：国内可达性更好，代价是 CDN 缓存延迟
/// （最长 12 小时）。作为 raw.githubusercontent.com 不可达时的第二源。
static NSString * const kRepoAnnouncementMirrorURL =
    @"https://cdn.jsdelivr.net/gh/Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher@main/announcements.json";
/// 旧上游默认源（已 404）。仅用于把历史存量偏好值识别为“未自定义”，
/// 不再实际请求。
static NSString * const kLegacyAnnouncementURL =
    @"https://air-api.vercel.app/api/announcements.php";
/// Task218：仓库名去 air（Air-Minecraft-iOS-Launcher -> Prisma-Minecraft-iOS-Launcher）
/// 之前的旧默认源。旧版 defaults 会把 news_url 物化进 plist——改名后这些
/// 存量值必须继续被识别为“未自定义”（否则会被当成用户自定义源独占拉取，
/// 丢失 jsDelivr 回退）；GitHub 对改名仓库的 raw/CDN 请求虽会重定向，但
/// 归一到新级联不依赖重定向，更稳。
static NSString * const kPreRenameAnnouncementURL =
    @"https://raw.githubusercontent.com/Gsjsjzhznsz/Air-Minecraft-iOS-Launcher/main/announcements.json";
static NSString * const kPreRenameAnnouncementMirrorURL =
    @"https://cdn.jsdelivr.net/gh/Gsjsjzhznsz/Air-Minecraft-iOS-Launcher@main/announcements.json";

@implementation AnnouncementService

+ (instancetype)sharedService {
    static AnnouncementService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AnnouncementService alloc] init];
    });
    return instance;
}

- (NSString *)apiURLString {
    // 从偏好设置读取 news_url；空值回退到仓库托管源（Task 130）。
    // PLPreferences 默认表已同步切换（news_url = kRepoAnnouncementURL）；
    // 历史安装若持久化过旧上游默认值，announcementSourceURLs 会把它
    // 识别为“未自定义”并归一到仓库源级联。
    NSString *url = getPrefObject(@"general.news_url");
    if (url.length == 0) {
        url = kRepoAnnouncementURL;
    }
    return url;
}

/// Task 130：公告源 URL 级联。
/// - 用户自定义（general.news_url 设为非默认值）：独占，只拉这一个源；
/// - 未自定义 / 等于任一已知默认值（旧上游 air-api.vercel.app、本仓库
///   raw 地址或 jsDelivr 镜像地址）：依次尝试仓库原始文件与 jsDelivr 镜像。
/// raw.githubusercontent.com 提交后即时生效；jsDelivr 镜像国内可达性更好
/// （CDN 缓存最长 12 小时）。任一源成功即写入缓存并接管展示。
- (NSArray<NSString *> *)announcementSourceURLs {
    NSString *url = [self apiURLString];
    BOOL customized = url.length > 0
        && ![url isEqualToString:kRepoAnnouncementURL]
        && ![url isEqualToString:kRepoAnnouncementMirrorURL]
        && ![url isEqualToString:kPreRenameAnnouncementURL]
        && ![url isEqualToString:kPreRenameAnnouncementMirrorURL]
        && ![url isEqualToString:kLegacyAnnouncementURL];
    if (customized) {
        return @[url];
    }
    return @[kRepoAnnouncementURL, kRepoAnnouncementMirrorURL];
}

- (NSArray<AnnouncementItem *> *)cachedAnnouncements {
    NSData *data = [[NSUserDefaults standardUserDefaults] dataForKey:kCachedAnnouncementsKey];
    if (!data) return nil;
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || !json) return nil;
    return [self parseAnnouncementsFromJSON:json];
}

// Task 129h：随包内置的离线公告（Natives/resources/announcements-fallback.json，
// payload 的 "cp -R resources/*" 自动打包）。在线源不可达且无缓存时兜底，
// 使首页公告磁贴与公告列表始终有内容可显示。
- (NSArray<AnnouncementItem *> *)builtinAnnouncements {
    static NSArray<AnnouncementItem *> *cached = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"announcements-fallback" ofType:@"json"];
        if (path.length == 0) {
            cached = @[];
            return;
        }
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) {
            cached = @[];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            cached = @[];
            return;
        }
        cached = [self parseAnnouncementsFromJSON:json] ?: @[];
    });
    return cached;
}

- (BOOL)isCacheValid {
    NSTimeInterval timestamp = [[NSUserDefaults standardUserDefaults] doubleForKey:kCachedAnnouncementsTimestampKey];
    if (timestamp == 0) return NO;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - timestamp;
    return elapsed < kAnnouncementCacheInterval;
}

- (void)fetchAnnouncementsWithCompletion:(AnnouncementFetchHandler)completion {
    // 缓存有效时直接返回缓存
    if ([self isCacheValid]) {
        NSArray *cached = [self cachedAnnouncements];
        if (cached) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cached, nil);
            });
            return;
        }
    }
    [self forceRefreshWithCompletion:completion];
}

- (void)forceRefreshWithCompletion:(AnnouncementFetchHandler)completion {
    // Task 130：仓库托管源级联拉取（源列表与自定义识别见 announcementSourceURLs）
    NSArray<NSString *> *sources = [self announcementSourceURLs];
    [self ame130_fetchFromSources:sources index:0 completion:completion];
}

// Task 130：顺序尝试公告源列表。单个源失败（网络错误 / 非 200 / JSON 解析
// 失败）自动降级到下一个源；全部在线源失败走 Task129h 兜底链（缓存 ->
// 随包内置离线公告 -> 错误回调）。首个成功的源写入缓存并接管展示，缓存
// 时间戳仍只由网络成功写入（在线源恢复后自动接管，离线兜底不会"粘住"）。
- (void)ame130_fetchFromSources:(NSArray<NSString *> *)sources
                          index:(NSUInteger)index
                     completion:(AnnouncementFetchHandler)completion {
    if (index >= sources.count) {
        // 所有在线源都失败：先尝试返回缓存
        NSArray *cached = [self cachedAnnouncements];
        if (cached.count > 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cached, nil);
            });
            return;
        }
        // Task 129h：缓存也为空 -> 返回随包内置的离线公告（用户实测：
        // "主页的启动器公告加载失败"——旧默认源 air-api.vercel.app 已
        // 404（域名被改作他用），全新安装无缓存时公告列表只剩错误文案。
        // Task 130 起公告源迁至本仓库 announcements.json（raw + jsDelivr
        // 级联），此兜底降级为"网络完全不可达"时的最后防线，与 Task128
        // 的 authlib-injector 内置化同一思路：核心内容不依赖单点在线服务。
        NSArray<AnnouncementItem *> *builtin = [self builtinAnnouncements];
        if (builtin.count > 0) {
            NSLog(@"[AnnouncementService] Task130: all announcement sources unreachable (%@), serving bundled offline announcements", sources);
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(builtin, nil);
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(@[], [NSError errorWithDomain:@"AnnouncementService" code:2 userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_24", nil)}]);
        });
        return;
    }

    NSString *urlString = sources[index];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        // URL 非法（自定义源手误输入）：直接试下一个源
        NSLog(@"[AnnouncementService] Task130: invalid announcement source URL (%@), trying next", urlString);
        [self ame130_fetchFromSources:sources index:index + 1 completion:completion];
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request setHTTPMethod:@"GET"];
    [request setValue:@"Prisma/1.0 (iOS)" forHTTPHeaderField:@"User-Agent"];
    // 单源 10s：两级源最坏 20s 内必出结果（原单源 15s），下拉刷新不会久等
    request.timeoutInterval = 10.0;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data || ((NSHTTPURLResponse *)response).statusCode != 200) {
            NSLog(@"[AnnouncementService] Task130: announcement source failed (%@, HTTP %ld), trying next",
                  urlString, (long)((NSHTTPURLResponse *)response).statusCode);
            [self ame130_fetchFromSources:sources index:index + 1 completion:completion];
            return;
        }

        // 缓存原始 JSON 数据
        [[NSUserDefaults standardUserDefaults] setObject:data forKey:kCachedAnnouncementsKey];
        [[NSUserDefaults standardUserDefaults] setDouble:[[NSDate date] timeIntervalSince1970] forKey:kCachedAnnouncementsTimestampKey];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // 解析
        NSError *parseError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        if (parseError || !json) {
            NSLog(@"[AnnouncementService] Task130: announcement JSON parse failed (%@), trying next", urlString);
            [self ame130_fetchFromSources:sources index:index + 1 completion:completion];
            return;
        }

        NSArray *items = [self parseAnnouncementsFromJSON:json];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items, nil);
        });
    }];
    [task resume];
}

- (NSArray<AnnouncementItem *> *)parseAnnouncementsFromJSON:(NSDictionary *)json {
    NSArray *rawArray = json[@"announcements"];
    if (![rawArray isKindOfClass:[NSArray class]]) return @[];

    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *dict in rawArray) {
        AnnouncementItem *item = [AnnouncementItem itemFromDictionary:dict];
        if (item) [items addObject:item];
    }
    // Task169：置顶优先（"pin": true 的公告无条件排最前——用户点名把
    // 服务器推荐摆到第一个），置顶组内与其余项各自仍按日期降序。
    [items sortUsingComparator:^NSComparisonResult(AnnouncementItem *a, AnnouncementItem *b) {
        if (a.pinned != b.pinned) {
            return a.pinned ? NSOrderedAscending : NSOrderedDescending;
        }
        return [b.date compare:a.date];
    }];
    return [items copy];
}

@end
