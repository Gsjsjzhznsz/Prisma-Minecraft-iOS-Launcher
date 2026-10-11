#import "utils.h"
//
//  MinecraftNewsService.m
//  Amethyst
//

#import "MinecraftNewsService.h"
#import "MinecraftNewsItem.h"

NSString * const MCNewsErrorDomain = @"MCNewsErrorDomain";

/// 基础 API URL（locale 段由实例 locale 属性决定）
static NSString * const MCNewsBaseAPIURL = @"https://net-secondary.web.minecraft-services.net/api/v1.0";

@interface MinecraftNewsService ()
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation MinecraftNewsService

+ (instancetype)sharedService {
    static MinecraftNewsService *s = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        s = [[MinecraftNewsService alloc] init];
    });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 默认跟随系统语言：zh-Hans/zh-Hant -> zh-cn，其他默认 en-us
        NSString *preferredLang = [[NSBundle mainBundle] preferredLocalizations].firstObject ?: @"en";
        if ([preferredLang hasPrefix:@"zh-Hans"] || [preferredLang hasPrefix:@"zh-CN"]) {
            _locale = @"zh-cn";
        } else if ([preferredLang hasPrefix:@"zh-Hant"] || [preferredLang hasPrefix:@"zh-TW"]) {
            _locale = @"zh-tw";
        } else if ([preferredLang hasPrefix:@"ja"]) {
            _locale = @"ja-jp";
        } else {
            _locale = @"en-us";
        }

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30.0;
        config.timeoutIntervalForResource = 60.0;
        config.HTTPMaximumConnectionsPerHost = 4;
        _session = [NSURLSession sessionWithConfiguration:config delegate:nil delegateQueue:nil];
    }
    return self;
}

- (void)fetchNewsWithPage:(NSInteger)page
                 pageSize:(NSInteger)pageSize
               completion:(MCNewsFetchHandler)completion {
    if (page < 1) page = 1;
    if (pageSize < 1) pageSize = 24;

    NSString *path = [NSString stringWithFormat:@"%@/%@/search", MCNewsBaseAPIURL, self.locale];
    NSURLComponents *comp = [NSURLComponents componentsWithString:path];
    comp.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"pageSize" value:[NSString stringWithFormat:@"%ld", (long)pageSize]],
        [NSURLQueryItem queryItemWithName:@"sortType" value:@"Recent"],
        [NSURLQueryItem queryItemWithName:@"category" value:@"News"],
        [NSURLQueryItem queryItemWithName:@"newsOnly" value:@"true"],
        [NSURLQueryItem queryItemWithName:@"page" value:[NSString stringWithFormat:@"%ld", (long)page]],
    ];
    NSURL *url = comp.URL;
    if (!url) {
        if (completion) completion(@[], 0, [NSError errorWithDomain:MCNewsErrorDomain
                                                                 code:MCNewsErrorCodeNetwork
                                                             userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_443", nil)}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:30.0];
    [request setHTTPMethod:@"GET"];
    // 参考 PCL-CE HttpSenderExtension：自定义 UA 提升稳定性，避免被识别为爬虫拦截
    [request setValue:@"PrismaLauncher/1.0 (iOS; Minecraft Launcher)" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:@"gzip, deflate" forHTTPHeaderField:@"Accept-Encoding"];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request
                                                 completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(@[], 0, error);
            });
            return;
        }

        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode != 200) {
            NSError *statusError = [NSError errorWithDomain:MCNewsErrorDomain
                                                       code:MCNewsErrorCodeNetwork
                                                   userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"HTTP %ld", (long)httpResp.statusCode]}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(@[], 0, statusError);
            });
            return;
        }

        NSError *parseError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                             options:NSJSONReadingAllowFragments
                                                               error:&parseError];
        if (parseError || ![json isKindOfClass:[NSDictionary class]]) {
            NSError *err = [NSError errorWithDomain:MCNewsErrorDomain
                                               code:MCNewsErrorCodeParsing
                                           userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_444", nil)}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(@[], 0, err);
            });
            return;
        }

        // 响应结构：{ "result": { "results": [...], "numFound": N, "page": N } }
        NSDictionary *result = json[@"result"];
        if (![result isKindOfClass:[NSDictionary class]]) {
            // 某些 locale 可能返回空 result，做容错
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(@[], 0, nil);
            });
            return;
        }
        NSArray *rawItems = result[@"results"];
        NSInteger totalCount = [result[@"numFound"] integerValue];

        NSMutableArray<MinecraftNewsItem *> *items = [NSMutableArray array];
        for (NSDictionary *dict in rawItems) {
            MinecraftNewsItem *item = [MinecraftNewsItem itemFromDictionary:dict];
            if (item && item.title.length > 0) {
                [items addObject:item];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion([items copy], totalCount, nil);
        });
    }];
    [task resume];
}

- (void)fetchLatestNewsWithCompletion:(MCNewsFetchHandler)completion {
    [self fetchNewsWithPage:1 pageSize:24 completion:completion];
}

+ (BOOL)isSafeNewsLink:(NSString *)urlString {
    if (urlString.length == 0) return NO;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    NSString *host = url.host.lowercaseString;
    if (host.length == 0) return NO;
    // 白名单：minecraft.net / minecraft-services.net / microsoft.com 及其子域
    NSArray<NSString *> *allowedSuffixes = @[@"minecraft.net", @"minecraft-services.net", @"microsoft.com"];
    for (NSString *suffix in allowedSuffixes) {
        if ([host isEqualToString:suffix] || [host hasSuffix:[NSString stringWithFormat:@".%@", suffix]]) {
            return YES;
        }
    }
    return NO;
}

@end
