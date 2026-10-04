//
//  IconLoader.m
//  Amethyst
//
//  统一的项目图标加载器实现（参照 FCL Glide + ZL2 Coil 的最佳实践）
//
//  实现要点：
//    1. 双层缓存：
//       - 内存：NSCache（自动响应内存警告，线程安全），容量 20MB / 200 个
//       - 磁盘：Library/Caches/IconLoader/，按 url+size 的 MD5 命名，容量上限 256MB
//       （对应 FCL 250MB + ZL2 512MB 的折中值，移动端 256MB 更保守）
//    2. 降采样：使用 CGImageSourceCreateThumbnailAtIndex，按目标尺寸解码
//       （对应 ZL2 .size(pxSize)，避免按 1024x1024 原图解码后缩放显示）
//    3. 异步解码：在 dispatch_get_global_queue 后台线程解码，主线程仅渲染
//    4. 并发上限：dispatch_semaphore 限制最多 6 个并发下载
//       （对应 Glide/Coil 的线程池上限，避免列表滚动时数十并发请求）
//    5. 同 URL 去重：inFlightRequests 字典合并同 URL 的多个回调
//       （对应 Glide 的 RequestCoordinator + Coil 的 shared flow）
//    6. CDN 镜像：cdn.modrinth.com / edge.forgecdn.net → MCIM 镜像
//       （经 PLMirrorCenter 统一收敛，对应 ZL2 的模组镜像方案）
//    7. 取消机制：每个 imageView 关联一个 token，cell 复用时旧 token 失效
//       （对应 Glide 的 clear() + ZL2 的 Compose 组合取消）
//    8. 预取：prefetchIconWithURL: 接口，仅触发下载+缓存写入，不绑定 imageView
//       （对应 ZL2 imageLoader.enqueue）
//

#import "IconLoader.h"
#import "LauncherPreferences.h"
#import "PLMirrorCenter.h"
#import "utils.h"
#import <CommonCrypto/CommonCrypto.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

/// 内存缓存上限：20MB（对应 ZL2 的 20MB 配置）
static const NSUInteger kMemoryCacheCostLimit = 20 * 1024 * 1024;
static const NSUInteger kMemoryCacheCountLimit = 200;

/// 磁盘缓存上限：256MB（FCL 250MB 与 ZL2 512MB 的折中）
static const unsigned long long kDiskCacheSizeLimit = 256ULL * 1024 * 1024;

/// 并发下载上限（提升到 15 以加快列表图标并发加载速度）
/// 参照 FCL Glide 的线程池上限（默认 4 个 CPU 核数，移动端列表图标场景需要更高并发）
static const NSInteger kMaxConcurrentDownloads = 15;

/// 网络请求超时（秒）—— 缩短到 8 秒，快速失败后允许其他排队请求更快获得槽位
static const NSTimeInterval kRequestTimeout = 8.0;

/// 单例实例
static IconLoader *_sharedLoader = nil;

/// 进行中的请求字典：key = cacheKey（url+size 的 MD5），value = NSMutableArray<callback-block>
/// 用于同 URL 去重，避免重复下载（对应 Glide 的 RequestCoordinator）
static NSMutableDictionary<NSString *, NSMutableArray<void(^)(UIImage * _Nullable)> *> *_inFlightRequests = nil;

/// imageView → 当前请求的 cacheKey 关联对象 key
/// 用于在 cell 复用时取消旧请求（对应 Glide 的 clear()）
static const void *kIconLoaderImageViewKey = &kIconLoaderImageViewKey;

#pragma mark - 内部加载上下文

@interface IconLoader ()
/// 内存缓存
@property (nonatomic, strong) NSCache<NSString *, UIImage *> *memoryCache;
/// 内存缓存的 key 跟踪集合（NSCache 不暴露 count，也不支持枚举，
/// 用独立的 NSMutableSet 跟踪当前已缓存的 key，用于 memoryCacheCount 统计）
@property (nonatomic, strong) NSMutableSet<NSString *> *memoryCacheKeys;
/// 并发下载信号量
@property (nonatomic, strong) dispatch_semaphore_t downloadSemaphore;
/// 串行队列，保护 _inFlightRequests 字典和 memoryCacheKeys 的线程安全
@property (nonatomic, strong) dispatch_queue_t syncQueue;
/// 磁盘缓存目录
@property (nonatomic, copy) NSString *diskCacheDirectory;
/// 是否启用 CDN 镜像替换
@property (nonatomic, assign) BOOL mirrorEnabled;
/// NSURLSession（使用 ephemeral 配置，避免与 AFNetworking 的 cookie 混用）
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation IconLoader

#pragma mark - 单例

+ (instancetype)sharedLoader {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedLoader = [[IconLoader alloc] init];
    });
    return _sharedLoader;
}

// 注意：不实现 +load 方法。
// 原因：+load 在 main() 之前执行，此时偏好设置系统（PLPreferences/LauncherPreferences）可能尚未初始化，
// 调用 getPrefObject 可能返回 nil 或导致崩溃。改为在 init（首次 sharedLoader 调用时）惰性初始化镜像开关，
// 此时应用已完成基本启动，偏好设置已就绪。

- (instancetype)init {
    self = [super init];
    if (self) {
        // 初始化内存缓存
        _memoryCache = [[NSCache alloc] init];
        _memoryCache.totalCostLimit = kMemoryCacheCostLimit;
        _memoryCache.countLimit = kMemoryCacheCountLimit;
        // NSCache 在收到 UIApplicationDidReceiveMemoryWarningNotification 时会自动清空，
        // 无需手动监听（但额外监听也无害，可加快响应）

        // key 跟踪集合（用于 memoryCacheCount 统计，因为 NSCache 不暴露 count）
        _memoryCacheKeys = [NSMutableSet set];

        // 并发下载信号量
        _downloadSemaphore = dispatch_semaphore_create(kMaxConcurrentDownloads);

        // 同步队列（保护 _inFlightRequests）
        _syncQueue = dispatch_queue_create("com.angelaura.iconloader.sync", DISPATCH_QUEUE_SERIAL);

        // 进行中请求字典
        _inFlightRequests = [NSMutableDictionary dictionary];

        // 磁盘缓存目录
        NSString *cachesDir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
        _diskCacheDirectory = [cachesDir stringByAppendingPathComponent:@"IconLoader"];
        [[NSFileManager defaultManager] createDirectoryAtPath:_diskCacheDirectory
                                  withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:nil];

        // NSURLSession（ephemeral 配置，不持久化 cookie/cache，避免与 AFNetworking 混用）
        // 提升并发连接数到 16，加快列表页大量图标的并发加载速度
        // 参照 FCL Glide 的磁盘缓存线程池 + 活跃请求队列，列表滚动时可能同时有 20+ 图标请求
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = kRequestTimeout;
        config.timeoutIntervalForResource = 15.0;
        config.HTTPMaximumConnectionsPerHost = 16;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        // 启用 HTTP/2 多路复用（iOS 9+ 默认支持，显式设置确保生效）
        config.HTTPShouldUsePipelining = YES;
        _session = [NSURLSession sessionWithConfiguration:config];

        // 监听内存警告：清空内存缓存
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleMemoryWarning)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];

        // 监听应用进入后台：取消所有进行中的下载（避免后台下载被系统杀掉）
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(handleEnterBackground)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];

        // 默认根据偏好判断是否启用镜像
        _mirrorEnabled = [self shouldMirrorByDefault];

        NSDebugLog(@"[IconLoader] Initialization complete, disk cache directory: %@, mirror enabled: %@", _diskCacheDirectory, _mirrorEnabled ? @"YES" : @"NO");
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 公共接口：加载图标

+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize
                      options:(IconLoaderOptions)options
                   completion:(nullable IconLoaderCompletion)completion {
    IconLoader *loader = [self sharedLoader];

    // 1. 取消该 imageView 上之前的请求（cell 复用场景）
    if (imageView) {
        [self cancelLoadingForImageView:imageView];
    }

    // 2. 设置占位图
    if (imageView) {
        if (placeholder) {
            imageView.image = placeholder;
        } else if (!imageView.image) {
            // 无占位图且当前也无图，给一个透明背景避免残留旧图
            imageView.image = nil;
        }
    }

    // 3. URL 为空：直接回调 nil（让调用方显示兜底）
    if (!url || url.length == 0) {
        if (fallback && imageView) {
            imageView.image = fallback;
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil);
            });
        }
        return;
    }

    // 4. 应用 CDN 镜像替换
    NSString *finalURL = url;
    if (!(options & IconLoaderOptionsNoMirror)) {
        finalURL = [self applyMirrorToURL:url];
    }

    // 5. 计算缓存 key
    NSString *cacheKey = [loader cacheKeyForURL:finalURL targetSize:targetSize options:options];

    // 6. 绑定 imageView 与 cacheKey（用于取消）
    if (imageView) {
        objc_setAssociatedObject(imageView, kIconLoaderImageViewKey, cacheKey, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // 7. 优先命中内存缓存
    UIImage *cached = [loader.memoryCache objectForKey:cacheKey];
    if (cached) {
        if (imageView) {
            imageView.image = cached;
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(cached);
            });
        }
        return;
    }

    // 8. 加入进行中请求字典（同 URL 去重）
    __weak UIImageView *weakImageView = imageView;
    void (^wrappedCallback)(UIImage * _Nullable) = ^(UIImage * _Nullable image) {
        // 校验：cell 复用后 imageView 可能已绑定新的 cacheKey，避免旧请求覆盖新图
        // （对应 Glide 的 clear() 后旧请求不再 set Drawable）
        if (weakImageView) {
            NSString *currentKey = objc_getAssociatedObject(weakImageView, kIconLoaderImageViewKey);
            if (![currentKey isEqualToString:cacheKey]) {
                // 该 imageView 已经发起新请求，旧回调放弃更新
                if (completion) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(nil);
                    });
                }
                return;
            }
            if (image) {
                weakImageView.image = image;
            } else if (fallback) {
                weakImageView.image = fallback;
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(image);
            });
        }
    };

    BOOL isNewRequest = [loader addCallback:wrappedCallback forCacheKey:cacheKey];
    if (!isNewRequest) {
        // 已有相同 URL 的请求在进行中，回调已加入队列，等待合并返回
        return;
    }

    // 9. 发起下载（后台线程）
    // 传入原始 URL（镜像前的）用于回退重试：
    // 如果镜像 URL 失败（HTTP 4xx/5xx、超时、Content-Type 非 image、解码失败），
    // 会自动用原始 URL 重试一次。这是图标完全不加载的关键修复——
    // BMCLAPI 的 MCIM 镜像路径（/mcim/modrinth/）可能不提供 cdn.modrinth.com 的
    // 静态图标资源，导致所有镜像后的图标请求返回 404/HTML，但原始 CDN 可以正常访问。
    [loader startDownloadForURL:finalURL
                  originalURL:url
                      cacheKey:cacheKey
                     targetSize:targetSize
                        options:options];
}

+ (void)loadIconForImageView:(nullable UIImageView *)imageView
                         URL:(nullable NSString *)url
                 placeholder:(nullable UIImage *)placeholder
                    fallback:(nullable UIImage *)fallback
                   targetSize:(CGSize)targetSize {
    [self loadIconForImageView:imageView
                           URL:url
                   placeholder:placeholder
                      fallback:fallback
                     targetSize:targetSize
                        options:IconLoaderOptionsDefault
                     completion:nil];
}

#pragma mark - 公共接口：预取

+ (void)prefetchIconWithURL:(NSString *)url targetSize:(CGSize)targetSize {
    if (!url || url.length == 0) return;

    IconLoader *loader = [self sharedLoader];
    NSString *finalURL = [self applyMirrorToURL:url];
    NSString *cacheKey = [loader cacheKeyForURL:finalURL targetSize:targetSize options:IconLoaderOptionsDefault];

    // 内存缓存命中：无需预取
    if ([loader.memoryCache objectForKey:cacheKey]) {
        return;
    }

    // 磁盘缓存命中：直接加载到内存缓存
    NSString *diskPath = [loader diskPathForCacheKey:cacheKey];
    if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
        [loader loadDiskImageToMemoryCacheAtPath:diskPath cacheKey:cacheKey];
        return;
    }

    // 已有相同请求在进行中：无需重复预取
    __block BOOL alreadyInFlight = NO;
    dispatch_sync(loader.syncQueue, ^{
        if (_inFlightRequests[cacheKey]) {
            alreadyInFlight = YES;
        }
    });
    if (alreadyInFlight) return;

    // 发起预取请求（回调为空，仅做缓存写入）
    [loader addCallback:^(UIImage * _Nullable image) {
        // 预取不需要更新 UI，仅依赖下载流程写入缓存
    } forCacheKey:cacheKey];

    [loader startDownloadForURL:finalURL
                  originalURL:url
                      cacheKey:cacheKey
                     targetSize:targetSize
                        options:IconLoaderOptionsDefault];
}

#pragma mark - 公共接口：取消

+ (void)cancelLoadingForImageView:(UIImageView *)imageView {
    if (!imageView) return;
    NSString *cacheKey = objc_getAssociatedObject(imageView, kIconLoaderImageViewKey);
    if (!cacheKey) return;
    // 清除关联，使进行中的回调不再更新该 imageView
    objc_setAssociatedObject(imageView, kIconLoaderImageViewKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // 注意：不主动取消下载任务本身，因为同 URL 可能有其他 imageView 在等待
    // （对应 Glide 的 clear() 仅取消目标 ImageView 的绑定，不取消共享请求）
}

+ (void)cancelAllLoadings {
    IconLoader *loader = [self sharedLoader];
    dispatch_sync(loader.syncQueue, ^{
        [_inFlightRequests removeAllObjects];
    });
    // 取消所有 NSURLSession 任务
    [loader.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks, NSArray<NSURLSessionUploadTask *> *uploadTasks, NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
        for (NSURLSessionTask *task in dataTasks) {
            [task cancel];
        }
    }];
}

#pragma mark - 公共接口：缓存管理

+ (void)clearMemoryCache {
    IconLoader *loader = [self sharedLoader];
    [loader clearMemoryCacheInternal];
}

+ (void)clearDiskCacheWithCompletion:(nullable dispatch_block_t)completion {
    IconLoader *loader = [self sharedLoader];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error;
        if ([fm fileExistsAtPath:loader.diskCacheDirectory]) {
            [fm removeItemAtPath:loader.diskCacheDirectory error:&error];
            if (error) {
                NSDebugLog(@"[IconLoader] Failed to clear disk cache: %@", error);
            } else {
                // 重新创建空目录
                [fm createDirectoryAtPath:loader.diskCacheDirectory
                      withIntermediateDirectories:YES
                                      attributes:nil
                                           error:nil];
            }
        }
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }
    });
}

+ (unsigned long long)diskCacheSize {
    IconLoader *loader = [self sharedLoader];
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long totalSize = 0;
    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:loader.diskCacheDirectory];
    NSString *fileName;
    while ((fileName = [enumerator nextObject])) {
        NSString *filePath = [loader.diskCacheDirectory stringByAppendingPathComponent:fileName];
        NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
        if (attrs) {
            totalSize += [attrs fileSize];
        }
    }
    return totalSize;
}

+ (NSUInteger)memoryCacheCount {
    IconLoader *loader = [self sharedLoader];
    // NSCache 不暴露 count 属性，也不支持 enumerateKeysAndObjectsUsingBlock:（这是 NSDictionary 的方法）。
    // 用独立的 memoryCacheKeys 集合来统计当前已缓存的条目数。
    // 注：NSCache 可能在内存压力下静默驱逐条目而不通知，此时 memoryCacheKeys 可能略多于实际缓存数，
    // 但此方法仅用于设置页统计显示，非热点路径，轻微高估可接受。
    __block NSUInteger count = 0;
    dispatch_sync(loader.syncQueue, ^{
        count = loader.memoryCacheKeys.count;
    });
    return count;
}

#pragma mark - 公共接口：CDN 镜像

+ (void)setMirrorEnabled:(BOOL)enabled {
    IconLoader *loader = [self sharedLoader];
    loader.mirrorEnabled = enabled;
}

+ (NSString *)applyMirrorToURL:(NSString *)url {
    if (!url || url.length == 0) return url;

    // 优先经 PLMirrorCenter 按资源下载（AssetDownload）策略应用 MCIM 镜像
    // （PLMirrorCenter 统一收敛镜像配置）。MCIM 镜像支持 Modrinth/CurseForge 的
    // API 和 CDN 图标资源，镜像优先时把 cdn.modrinth.com / edge.forgecdn.net /
    // media.forgecdn.net 替换为 mod.mcimirror.top，加速国内图标加载；
    // 官方优先或不适用镜像的 URL 保持原始值，走后续逻辑。
    NSURL *preferredURL = [PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:url]
                                                        resourceType:PLMirrorResourceTypeAssetDownload];
    NSString *mirrored = preferredURL.absoluteString;
    if (mirrored.length > 0 && ![mirrored isEqualToString:url]) {
        return mirrored;
    }

    IconLoader *loader = [self sharedLoader];
    // 每次实时读取偏好，确保用户在设置中切换下载源后立即生效
    // （不依赖缓存的 mirrorEnabled，避免偏好变更后镜像设置不同步）
    if (![loader shouldMirrorByDefault]) return url;

    // ⚠️ 关键修复：不对 Modrinth/CurseForge CDN 上的图标资源做 BMCLAPI 镜像替换。
    //
    // 原因：BMCLAPI 的 MCIM 镜像路径（/mcim/modrinth/、/mcim/curseforge/）只缓存
    // API 接口数据和文件下载资源，不缓存 CDN 上的项目图标资源。实测所有
    // cdn.modrinth.com / edge.forgecdn.net / media.forgecdn.net 的图标 URL
    // 经 BMCLAPI 镜像后均返回 HTTP 404（Content-Type: text/plain）。
    //
    // 此前实现的"镜像 404 → 回退原始 URL"机制虽能恢复加载，但带来两个问题：
    //   1. 每个图标都要走双倍流程（BMCLAPI 404 约 0.1s + 原始 URL 约 2-4s），
    //      导致列表图标加载耗时翻倍，用户感知"图标加载不出来"。
    //   2. 并发限制 15 个 permit 中，部分被"已 404 即将回退"的请求占用，
    //      新请求被阻塞，加剧其他 tab 图标加载延迟。
    //
    // 实测原始 CDN 在国内均可直接访问：
    //   - cdn.modrinth.com 通过 307 重定向到 cdn-alt.modrinth.com，返回 image/png|webp
    //   - edge.forgecdn.net / media.forgecdn.net 直连可达
    // 因此直接走原始 CDN 是更优选择，避免镜像 404 失败 + 回退重试的额外耗时。
    //
    // 方法保留（prefetchIconWithURL: 等其他调用方仍可调用），但不再对任何 CDN
    // 图标做镜像替换。若将来 BMCLAPI 修复了对 CDN 图标的支持，可在此处有选择地恢复。
    return url;
}

/// 根据下载源偏好自动判断是否启用镜像
+ (void)refreshMirrorEnabledFromPreference {
    IconLoader *loader = [self sharedLoader];
    loader.mirrorEnabled = [loader shouldMirrorByDefault];
}

/// 默认镜像启用判断：bmclapi / auto（中国大陆默认走 BMCLAPI）时启用
/// 安全处理 nil 偏好（偏好系统未初始化时返回 NO，避免 +load 早期调用崩溃）
- (BOOL)shouldMirrorByDefault {
    // Task218：判定收敛到 PLMirrorCenter（AssetDownload 策略的体系化布尔
    // 口径）。旧实现读冻结的旧键 general.download_source——用户在新版
    // "下载镜像策略"里的选择对它永远不生效（双轨制病灶）。
    return [PLMirrorCenter mirrorPreferredForType:PLMirrorResourceTypeAssetDownload];
}

#pragma mark - 内部：缓存 key 与磁盘路径

/// 生成缓存 key：MD5(url + targetSize + options)
- (NSString *)cacheKeyForURL:(NSString *)url targetSize:(CGSize)targetSize options:(IconLoaderOptions)options {
    NSString *keyString = [NSString stringWithFormat:@"%@|%.0fx%.0f|%lu",
                           url,
                           targetSize.width, targetSize.height,
                           (unsigned long)options];
    return [self md5OfString:keyString];
}

/// 磁盘缓存文件路径
- (NSString *)diskPathForCacheKey:(NSString *)cacheKey {
    return [self.diskCacheDirectory stringByAppendingPathComponent:cacheKey];
}

- (NSString *)md5OfString:(NSString *)string {
    const char *cStr = [string UTF8String];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), result);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]];
}

#pragma mark - 内部：进行中请求管理（同 URL 去重）

/// 添加回调到进行中请求字典
/// @return YES 表示这是该 URL 的第一个请求（需要发起下载），NO 表示已有请求在进行中（仅合并回调）
- (BOOL)addCallback:(void(^)(UIImage * _Nullable))callback forCacheKey:(NSString *)cacheKey {
    __block BOOL isNew = NO;
    dispatch_sync(self.syncQueue, ^{
        NSMutableArray *callbacks = _inFlightRequests[cacheKey];
        if (!callbacks) {
            callbacks = [NSMutableArray array];
            _inFlightRequests[cacheKey] = callbacks;
            isNew = YES;
        }
        if (callback) {
            [callbacks addObject:[callback copy]];
        }
    });
    return isNew;
}

/// 移除并取出该 cacheKey 的所有回调
- (NSArray<void(^)(UIImage * _Nullable)> *)popCallbacksForCacheKey:(NSString *)cacheKey {
    __block NSArray *result = nil;
    dispatch_sync(self.syncQueue, ^{
        result = [_inFlightRequests[cacheKey] copy];
        [_inFlightRequests removeObjectForKey:cacheKey];
    });
    return result;
}

#pragma mark - 内部：下载与解码

- (void)startDownloadForURL:(NSString *)urlString
               originalURL:(NSString *)originalURLString
                   cacheKey:(NSString *)cacheKey
                 targetSize:(CGSize)targetSize
                    options:(IconLoaderOptions)options {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        [self completeRequestWithCacheKey:cacheKey image:nil];
        return;
    }

    // 优先检查磁盘缓存（在后台线程）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *diskPath = [self diskPathForCacheKey:cacheKey];
        if ([[NSFileManager defaultManager] fileExistsAtPath:diskPath]) {
            // 磁盘缓存命中：加载到内存并返回
            UIImage *image = [self loadDiskImageToMemoryCacheAtPath:diskPath cacheKey:cacheKey];
            if (image) {
                [self completeRequestWithCacheKey:cacheKey image:image];
                return;
            }
            // 磁盘缓存文件损坏：删除后继续走网络下载
            [[NSFileManager defaultManager] removeItemAtPath:diskPath error:nil];
        }

        // 网络下载（传入原始 URL 用于镜像失败时回退重试）
        [self downloadFromURL:url
                originalURLString:originalURLString
                      cacheKey:cacheKey
                     targetSize:targetSize
                        options:options];
    });
}

/// 从磁盘加载图像到内存缓存
- (nullable UIImage *)loadDiskImageToMemoryCacheAtPath:(NSString *)path cacheKey:(NSString *)cacheKey {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data) return nil;
    UIImage *image = [UIImage imageWithData:data];
    if (image) {
        [self storeInMemoryCache:image forKey:cacheKey];
    }
    return image;
}

- (void)downloadFromURL:(NSURL *)url
       originalURLString:(NSString *)originalURLString
               cacheKey:(NSString *)cacheKey
             targetSize:(CGSize)targetSize
                options:(IconLoaderOptions)options {
    // 信号量限流：等待可用槽位（对应 Glide 的线程池上限）
    dispatch_semaphore_wait(self.downloadSemaphore, DISPATCH_TIME_FOREVER);

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            // 防御性写法：单例不会触发，但仍释放信号量避免泄漏
            dispatch_semaphore_signal(weakSelf.downloadSemaphore);
            return;
        }

        // 释放信号量槽位
        dispatch_semaphore_signal(strongSelf.downloadSemaphore);

        // ── HTTP 响应校验（关键修复：防止 404/HTML 错误页被当作图片数据）──
        //
        // 之前的 bug：完全没有校验 statusCode 和 Content-Type，
        // 镜像 URL 返回 404 时 error 为 nil、data 非空（HTML 错误页），
        // 三条 if 判断全部不命中，HTML 被送进解码器，
        // CGImageSourceCreateWithData 失败返回 nil，静默吞掉，
        // 最终只剩 fallback 拼图占位图标。
        NSInteger statusCode = 0;
        NSString *contentType = nil;
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            statusCode = httpResponse.statusCode;
            contentType = httpResponse.allHeaderFields[@"Content-Type"];
        }

        BOOL isNetworkError = (error != nil);
        BOOL isEmptyData = (!data || data.length == 0);
        BOOL isHTTPError = (statusCode >= 400);
        BOOL isNonImageContentType = NO;
        if (contentType && contentType.length > 0) {
            NSString *lowerCT = [contentType lowercaseString];
            // 严格的 Content-Type 校验：只接受 image/* 类型
            // HTML 错误页的 Content-Type 通常是 text/html，应被拒绝
            if (![lowerCT hasPrefix:@"image/"]) {
                isNonImageContentType = YES;
            }
        }

        BOOL shouldFallbackToOriginal = NO;

        if (isNetworkError) {
            NSLog(@"[IconLoader] Network error: %@ - %@", url, error.localizedDescription);
            shouldFallbackToOriginal = YES;
        } else if (isEmptyData) {
            NSLog(@"[IconLoader] Response data is empty: %@ (HTTP %ld)", url, (long)statusCode);
            shouldFallbackToOriginal = YES;
        } else if (isHTTPError) {
            NSLog(@"[IconLoader] HTTP error: %@ (status=%ld, Content-Type=%@)", url, (long)statusCode, contentType);
            shouldFallbackToOriginal = YES;
        } else if (isNonImageContentType) {
            NSLog(@"[IconLoader] Content-Type is not image: %@ (Content-Type=%@)", url, contentType);
            shouldFallbackToOriginal = YES;
        }

        // ── 镜像失败回退到原始 URL 重试（关键修复）──
        //
        // 如果当前请求使用的是镜像 URL（与原始 URL 不同）且失败了，
        // 自动用原始 URL 重试一次。这是图标完全不加载的核心修复——
        // BMCLAPI 的 MCIM 镜像路径（/mcim/modrinth/）可能不提供 cdn.modrinth.com 的
        // 静态图标资源，但原始 CDN 可以正常访问。
        //
        // 即使在"中国大陆"环境下，cdn.modrinth.com 和 edge.forgecdn.net 的
        // 小图标资源通常也能正常访问（延迟稍高但不会失败），因此回退到原始 URL 是安全的。
        if (shouldFallbackToOriginal && originalURLString && originalURLString.length > 0) {
            NSString *currentURLString = url.absoluteString;
            // 仅当当前 URL 与原始 URL 不同时才回退（避免无限重试）
            if (![currentURLString isEqualToString:originalURLString]) {
                NSLog(@"[IconLoader] Falling back to original URL: %@", originalURLString);
                NSURL *originalURL = [NSURL URLWithString:originalURLString];
                if (originalURL) {
                    // 递归调用自身，但传入 nil 作为 originalURLString 防止再次回退
                    [strongSelf downloadFromURL:originalURL
                              originalURLString:nil
                                      cacheKey:cacheKey
                                     targetSize:targetSize
                                        options:options];
                    return;
                }
            }
        }

        if (shouldFallbackToOriginal) {
            // 所有重试都已穷尽，最终失败
            NSLog(@"[IconLoader] Icon loading ultimately failed (all URLs unavailable): %@", url);
            [strongSelf completeRequestWithCacheKey:cacheKey image:nil];
            return;
        }

        // ── 后台线程解码 + 降采样 ──
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            UIImage *decodedImage = [strongSelf decodeImageData:data
                                                     targetSize:targetSize
                                                        options:options];
            if (decodedImage) {
                // 写入双层缓存
                [strongSelf storeInMemoryCache:decodedImage forKey:cacheKey];

                // 写入磁盘缓存（除非指定 MemoryCacheOnly）
                if (!(options & IconLoaderOptionsMemoryCacheOnly)) {
                    [strongSelf writeDataToDisk:data cacheKey:cacheKey];
                }
            } else {
                // 解码失败：可能是数据损坏或非图片数据伪装成 image Content-Type
                // 尝试回退到原始 URL（如果尚未回退过）
                NSLog(@"[IconLoader] Image decoding failed, data may be corrupted or not an image: %@ (data.length=%lu)", url, (unsigned long)data.length);
                if (originalURLString && originalURLString.length > 0) {
                    NSString *currentURLString = url.absoluteString;
                    if (![currentURLString isEqualToString:originalURLString]) {
                        NSLog(@"[IconLoader] Decode failure, falling back to original URL: %@", originalURLString);
                        NSURL *originalURL = [NSURL URLWithString:originalURLString];
                        if (originalURL) {
                            [strongSelf downloadFromURL:originalURL
                                      originalURLString:nil
                                              cacheKey:cacheKey
                                             targetSize:targetSize
                                                options:options];
                            return;
                        }
                    }
                }
            }
            [strongSelf completeRequestWithCacheKey:cacheKey image:decodedImage];
        });
    }];
    [task resume];
}

#pragma mark - 内部：降采样解码（对应 ZL2 .size(pxSize)）

/// 解码图像数据，按目标尺寸降采样
/// 使用 CGImageSourceCreateThumbnailAtIndex 实现按需解码，避免加载完整原图到内存
- (nullable UIImage *)decodeImageData:(NSData *)data
                           targetSize:(CGSize)targetSize
                              options:(IconLoaderOptions)options {
    if (!data || data.length == 0) return nil;

    // 跳过降采样：直接解码原图
    if (options & IconLoaderOptionsNoDownsample || CGSizeEqualToSize(targetSize, CGSizeZero)) {
        UIImage *directImage = [UIImage imageWithData:data];
        if (!directImage) {
            NSLog(@"[IconLoader] decodeImageData: UIImage imageWithData: returned nil (data.length=%lu)", (unsigned long)data.length);
        }
        return directImage;
    }

    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nil);
    if (!source) {
        NSLog(@"[IconLoader] decodeImageData: CGImageSourceCreateWithData failed (data.length=%lu)", (unsigned long)data.length);
        return nil;
    }

    CFIndex imageCount = CGImageSourceGetCount(source);
    if (imageCount == 0) {
        NSLog(@"[IconLoader] decodeImageData: CGImageSourceGetCount returned 0 (data.length=%lu)", (unsigned long)data.length);
        CFRelease(source);
        return nil;
    }

    // 计算目标尺寸（考虑屏幕 scale）
    CGFloat scale = [UIScreen mainScreen].scale;
    NSInteger maxPixelSize = MAX(targetSize.width, targetSize.height) * scale;
    // 给一点余量，避免缩放后模糊（对应 Coil 的 1.1x 容差）
    maxPixelSize = (NSInteger)(maxPixelSize * 1.1);

    NSDictionary *optionsDict = @{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceShouldCache: @YES,                    // 解码后立即缓存到内存
        (id)kCGImageSourceShouldCacheImmediately: @YES,         // 强制立即解码（避免延迟解码卡顿）
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,   // 应用 EXIF 方向
        (id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize)
    };

    CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)optionsDict);
    CFRelease(source);

    if (!thumbnail) {
        // 降采样失败，退回直接解码（可能数据本身没问题但 thumbnail 创建失败）
        UIImage *fallbackImage = [UIImage imageWithData:data];
        if (!fallbackImage) {
            NSLog(@"[IconLoader] decodeImageData: both downsampling and direct decode failed (data.length=%lu)", (unsigned long)data.length);
        }
        return fallbackImage;
    }

    UIImage *result = [UIImage imageWithCGImage:thumbnail scale:scale orientation:UIImageOrientationUp];
    CGImageRelease(thumbnail);

    return result;
}

#pragma mark - 内部：完成请求分发

- (void)completeRequestWithCacheKey:(NSString *)cacheKey image:(nullable UIImage *)image {
    NSArray<void(^)(UIImage * _Nullable)> *callbacks = [self popCallbacksForCacheKey:cacheKey];
    if (!callbacks || callbacks.count == 0) return;
    for (void(^cb)(UIImage * _Nullable) in callbacks) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(image);
        });
    }
}

#pragma mark - 内部：磁盘缓存写入与 LRU 清理

- (void)writeDataToDisk:(NSData *)data cacheKey:(NSString *)cacheKey {
    if (!data || data.length == 0) return;

    NSString *path = [self diskPathForCacheKey:cacheKey];
    [data writeToFile:path atomically:YES];

    // 异步触发 LRU 清理（避免每次写入都同步检查）
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [self trimDiskCacheIfNeeded];
    });
}

/// LRU 清理：当磁盘缓存总大小超过上限时，按最后访问时间删除最旧的文件
- (void)trimDiskCacheIfNeeded {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long totalSize = 0;
    NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];

    NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:self.diskCacheDirectory];
    NSString *fileName;
    while ((fileName = [enumerator nextObject])) {
        NSString *filePath = [self.diskCacheDirectory stringByAppendingPathComponent:fileName];
        NSDictionary *attrs = [fm attributesOfItemAtPath:filePath error:nil];
        if (!attrs) continue;
        unsigned long long fileSize = [attrs fileSize];
        NSDate *modDate = attrs[NSFileModificationDate] ?: [NSDate distantPast];
        totalSize += fileSize;
        [entries addObject:@{
            @"path": filePath,
            @"size": @(fileSize),
            @"date": modDate
        }];
    }

    if (totalSize <= kDiskCacheSizeLimit) return;

    // 按修改时间升序排序（最旧的在前）
    [entries sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"date"] compare:b[@"date"]];
    }];

    // 从最旧的开始删除，直到总大小降到上限以下
    unsigned long long targetSize = (unsigned long long)(kDiskCacheSizeLimit * 0.8); // 删除到 80% 以下
    for (NSDictionary *entry in entries) {
        if (totalSize <= targetSize) break;
        NSString *path = entry[@"path"];
        unsigned long long size = [entry[@"size"] unsignedLongLongValue];
        [fm removeItemAtPath:path error:nil];
        totalSize -= size;
    }
}

#pragma mark - 内部：辅助

- (NSUInteger)costForImage:(UIImage *)image {
    // 估算内存占用：width * height * 4 bytes (RGBA)
    return (NSUInteger)(image.size.width * image.scale * image.size.height * image.scale * 4);
}

/// 将图像存入内存缓存，并同步更新 key 跟踪集合
- (void)storeInMemoryCache:(UIImage *)image forKey:(NSString *)cacheKey {
    [self.memoryCache setObject:image
                       forKey:cacheKey
                         cost:[self costForImage:image]];
    dispatch_async(self.syncQueue, ^{
        [self.memoryCacheKeys addObject:cacheKey];
    });
}

/// 清空内存缓存及其 key 跟踪集合
- (void)clearMemoryCacheInternal {
    [self.memoryCache removeAllObjects];
    dispatch_async(self.syncQueue, ^{
        [self.memoryCacheKeys removeAllObjects];
    });
}

#pragma mark - 通知处理

- (void)handleMemoryWarning {
    [self clearMemoryCacheInternal];
    NSDebugLog(@"[IconLoader] Memory warning: cleared memory cache");
}

- (void)handleEnterBackground {
    // 应用进入后台：取消所有进行中的下载（避免后台下载被系统杀掉）
    [IconLoader cancelAllLoadings];
    NSDebugLog(@"[IconLoader] App entered background: cancelled all ongoing downloads");
}

@end
