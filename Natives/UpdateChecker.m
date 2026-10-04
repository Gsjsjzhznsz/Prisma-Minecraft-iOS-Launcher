#import "utils.h"
#import "UpdateChecker.h"
#import <UIKit/UIKit.h>

#pragma mark - UpdateInfo

@implementation UpdateInfo
@end

#pragma mark - UpdateChecker

@implementation UpdateChecker

// Task 115：更新检测指向本仓库（Task218 改名：Gsjsjzhznsz/Prisma-Minecraft-iOS-Launcher），
// 而非上游参考仓库（herbrine8403/Amethyst-iOS-MyRemastered）。
// 此前两处 URL（API + 打开页面）都指向上游：用户点"检查更新"会把上游的
// release 当成自己的更新（版本号/下载链接全部错位）。repoOwner/repoName
// 是这两个 URL 的唯一来源，改这里即全链路生效。
+ (NSString *)repoOwner { return @"Gsjsjzhznsz"; }
+ (NSString *)repoName { return @"Prisma-Minecraft-iOS-Launcher"; }

+ (NSString *)latestReleaseURL {
    /* /releases/latest 接口自动返回最新的非 pre-release（正式版） */
    return [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
            self.repoOwner, self.repoName];
}

+ (NSString *)currentVersion {
    NSString *v = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    if (v == nil) v = @"";
    /* 当前版本号可能是 "5.0.0 Preview"，提取数字部分用于比较 */
    return v;
}

#pragma mark - Check For Update

+ (void)checkForUpdateWithCompletion:(void(^)(UpdateInfo *_Nullable info, NSError *_Nullable error))completion {
    NSString *urlStr = self.latestReleaseURL;
    NSURL *url = [NSURL URLWithString:urlStr];
    if (url == nil) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1048", nil)}]);
        });
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                            cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                        timeoutInterval:15.0];
    [request setHTTPMethod:@"GET"];
    /* GitHub API 要求 User-Agent 头，否则可能被拒绝 */
    [request setValue:@"Amethyst-iOS-UpdateChecker" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, error);
            });
            return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        if (httpResp.statusCode != 200 || data == nil) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:httpResp.statusCode
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:localize(@"i18n_str_1049", nil), (long)httpResp.statusCode]}]);
            });
            return;
        }

        /* 解析 JSON */
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:-2
                                             userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_444", nil)}]);
            });
            return;
        }

        UpdateInfo *info = [self parseReleaseJSON:json];
        if (info == nil) {
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSError errorWithDomain:@"UpdateChecker" code:-3
                                             userInfo:@{NSLocalizedDescriptionKey: localize(@"i18n_str_1050", nil)}]);
            });
            return;
        }
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion(info, nil);
        });
    }];
    [task resume];
}

/// 解析 GitHub Releases API 返回的 JSON
+ (UpdateInfo *)parseReleaseJSON:(NSDictionary *)json {
    UpdateInfo *info = [[UpdateInfo alloc] init];
    info.currentVersion = self.currentVersion;

    /* tag_name 通常是 "v5.0.1" 或 "5.0.1" */
    NSString *tag = json[@"tag_name"];
    if (tag.length == 0) return nil;
    info.latestVersion = [self normalizeVersion:tag];

    info.releaseName = json[@"name"];
    info.releaseNotes = json[@"body"];
    info.htmlURL = json[@"html_url"];
    info.publishedAt = json[@"published_at"];

    /* assets 数组 */
    NSArray *assets = json[@"assets"];
    if ([assets isKindOfClass:[NSArray class]]) {
        NSMutableArray *assetList = [NSMutableArray array];
        for (NSDictionary *a in assets) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            [assetList addObject:@{
                @"name": a[@"name"] ?: @"",
                @"url": a[@"browser_download_url"] ?: @"",
                @"size": a[@"size"] ?: @(0),
                @"contentType": a[@"content_type"] ?: @""
            }];
        }
        info.assets = assetList;
    }

    /* 版本比较：currentVersion 可能是 "5.0.0 Preview"，先提取数字部分 */
    NSString *currentNum = [self extractVersionNumbers:info.currentVersion];
    NSString *latestNum = [self extractVersionNumbers:info.latestVersion];
    if (currentNum.length > 0 && latestNum.length > 0) {
        NSComparisonResult cmp = [self compareVersion:currentNum withVersion:latestNum];
        info.hasUpdate = (cmp == NSOrderedAscending);
    } else {
        /* 无法提取版本号时，直接比较 tag 和当前版本字符串 */
        info.hasUpdate = ![info.currentVersion isEqualToString:info.latestVersion];
    }
    return info;
}

/// 去掉版本号前面的 "v" 或 "V" 前缀
+ (NSString *)normalizeVersion:(NSString *)tag {
    if (tag == nil) return @"";
    NSString *v = [tag stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([v hasPrefix:@"v"] || [v hasPrefix:@"V"]) {
        v = [v substringFromIndex:1];
    }
    return v;
}

/// 从版本字符串中提取数字部分（如 "5.0.0 Preview" → "5.0.0"）
+ (NSString *)extractVersionNumbers:(NSString *)version {
    if (version.length == 0) return @"";
    NSError *err = nil;
    NSRegularExpression *regex = [NSRegularExpression
        regularExpressionWithPattern:@"^([0-9]+(\\.[0-9]+)*)"
                            options:0 error:&err];
    if (regex == nil) return @"";
    NSTextCheckingResult *match = [regex firstMatchInString:version
                                                    options:0
                                                      range:NSMakeRange(0, version.length)];
    if (match == nil) return @"";
    return [version substringWithRange:[match rangeAtIndex:1]];
}

#pragma mark - Version Comparison

+ (NSComparisonResult)compareVersion:(NSString *)v1 withVersion:(NSString *)v2 {
    /* 容错：nil 或空字符串视为 "0" */
    if (v1.length == 0) v1 = @"0";
    if (v2.length == 0) v2 = @"0";

    NSArray *c1 = [v1 componentsSeparatedByString:@"."];
    NSArray *c2 = [v2 componentsSeparatedByString:@"."];
    NSInteger max = MAX(c1.count, c2.count);

    for (NSInteger i = 0; i < max; i++) {
        /* 非数字段（如 "Beta"）按 0 处理 */
        NSInteger n1 = (i < c1.count) ? [c1[i] integerValue] : 0;
        NSInteger n2 = (i < c2.count) ? [c2[i] integerValue] : 0;
        if (n1 < n2) return NSOrderedAscending;
        if (n1 > n2) return NSOrderedDescending;
    }
    return NSOrderedSame;
}

#pragma mark - Open Release Page

+ (void)openReleasePage {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/%@/%@/releases/latest",
                                       self.repoOwner, self.repoName]];
    if (url && [[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

@end
