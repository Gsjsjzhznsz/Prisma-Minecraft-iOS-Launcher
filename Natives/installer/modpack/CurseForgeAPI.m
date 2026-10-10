#import "CurseForgeAPI.h"
#import "AFNetworking.h"
#import "PLPreferences.h"
#import "config.h"
#import "PLMirrorCenter.h"

// CurseForge 静态常量
static const NSInteger kCurseForgeGameIDMinecraft = 432;
static const NSInteger kCurseForgeClassIDBukkitPlugins = 5;
static const NSInteger kCurseForgeClassIDMods = 6;
static const NSInteger kCurseForgeClassIDResourcePacks = 12;
static const NSInteger kCurseForgeClassIDWorlds = 17;
static const NSInteger kCurseForgeClassIDModpacks = 4471;
static const NSInteger kCurseForgeClassIDShaders = 6552;
static const NSInteger kCurseForgeClassIDDataPacks = 6945;
static const NSInteger kCurseForgeCategoryIDServerUtility = 435;

// NSError userInfo keys for diagnostic information
NSString *const CurseForgeResponseContentTypeKey = @"CurseForgeResponseContentTypeKey";
NSString *const CurseForgeResponseSnippetKey = @"CurseForgeResponseSnippetKey";

/// 安全获取编译时 CurseForge API Key（避免 @nil 非法表达式）
/// 参考 CurseForgeAPIKeyViewController.m 中的 CFKCompiledAPIKey() 实现
static NSString *CFACompiledAPIKey(void) {
#define CFA_STR_INNER(x) #x
#define CFA_STR(x) CFA_STR_INNER(x)
    NSString *compiledKey = [NSString stringWithUTF8String:CFA_STR(CONFIG_CURSEFORGE_API_KEY)];
#undef CFA_STR
#undef CFA_STR_INNER
    // 处理字符串字面量两端的引号（CONFIG_CURSEFORGE_API_KEY 宏定义为 "actual_key" 时，字符串化后为 "\"actual_key\""）
    if (compiledKey.length >= 2 && [compiledKey hasPrefix:@"\""] && [compiledKey hasSuffix:@"\""]) {
        compiledKey = [compiledKey substringWithRange:NSMakeRange(1, compiledKey.length - 2)];
    }
    // 宏未定义时预处理器字符串化后得到宏名本身 "CONFIG_CURSEFORGE_API_KEY"，或为 nil 时得到 "nil"
    if ([compiledKey isEqualToString:@"nil"] || compiledKey.length == 0 ||
        [compiledKey isEqualToString:@"CONFIG_CURSEFORGE_API_KEY"] ||
        // Task169：宏被定义为 NULL 指针字面量时（CI 传 -DCONFIG_CURSEFORGE_API_KEY=NULL
        // 或构数系统展开成 ((void *)0)），字符串化产物形如 "((void *)0)"/"NULL"/"0"——
        // 装机 485b18c 实测：这些垃圾（恰好 11 字符）被当成合法 key（日志
        // "compile-time macro (length=11, prefix=((void *...)"），以
        // x-api-key: ((void *)0 污染镜像请求，且 isAPIKeyConfigured=YES 阻断了
        // keyless 设备的强制镜像回退。统一归空，交由镜像 keyless 路径。
        [compiledKey isEqualToString:@"((void *)0)"] ||
        [compiledKey isEqualToString:@"(nil)"] ||
        [compiledKey isEqualToString:@"NULL"] ||
        [compiledKey isEqualToString:@"0"]) {
        return @"";
    }
    return compiledKey;
}

// Task211（CF 403 根治）：占位 Key 判定。病历（17c51003 装机 latestlog.txt）：
// CI secret 未配置时 CONFIG_CURSEFORGE_API_KEY 字面展开为 "((void *)0)"
// （11 字符，与日志 prefix=((void *... 完全一致），它随 x-api-key 发往官方
// API 必得 403 Forbidden: API Key missing or invalid，且 isAPIKeyConfigured
// =YES 阻断 keyless 镜像回退（Task162/171 语义）。Task169 的守卫只护了
// 编译时宏这一层；运行时偏好（优先级最高）此前无守卫，KeyViewController
// 的预填-保存链把同一垃圾写进了设备。本判定供 getter / isAPIKeyConfigured /
// +isPlaceholderAPIKey:（两个 KeyViewController 的预填净化与保存门）共用，
// 垃圾家族与 CFACompiledAPIKey 的表保持一致并加前缀兜底。
static BOOL CFAIsGarbageAPIKey(NSString *key) {
    if (![key isKindOfClass:NSString.class] || key.length == 0) return YES;
    return ([key isEqualToString:@"((void *)0)"] ||
            [key isEqualToString:@"(nil)"] ||
            [key isEqualToString:@"NULL"] ||
            [key isEqualToString:@"nil"] ||
            [key isEqualToString:@"0"] ||
            [key isEqualToString:@"CONFIG_CURSEFORGE_API_KEY"] ||
            [key hasPrefix:@"((void"]);
}

@interface CurseForgeAPI ()
@property (nonatomic, strong) NSURLSession *session;   // 用于异步请求
// 错误诊断辅助方法：将 HTTP 响应信息封装进 NSError userInfo
- (NSError *)errorWithResponse:(NSURLResponse *)response
                          data:(NSData *)data
                 originalError:(NSError *)originalError
                       snippet:(NSString *)snippet;
// 调试日志辅助方法：输出请求/响应/JSON 解析错误的完整信息
- (void)debugLogRequest:(NSURLRequest *)request
               response:(NSURLResponse *)response
                   data:(NSData *)data
              jsonError:(NSError *)jsonError;
// 将 NSData 转为可打印字符串（处理非 UTF-8 内容，最多 maxLen 字节）
- (NSString *)printableStringFromData:(NSData *)data maxLen:(NSUInteger)maxLen;
@end

/// 经 PLMirrorCenter 按资源下载（AssetDownload）策略应用镜像
/// （CurseForge Edge/Media CDN 文件 → MCIM 镜像），URL 为空或无法解析时回退原始字符串
static NSString *CFAMirrorResolvedURL(NSString *urlString) {
    if (![urlString isKindOfClass:[NSString class]] || urlString.length == 0) return urlString;
    NSURL *resolved = [PLMirrorCenter preferredURLForOriginalURL:[NSURL URLWithString:urlString]
                                                    resourceType:PLMirrorResourceTypeAssetDownload];
    return resolved.absoluteString ?: urlString;
}

// ============================================================================
// Task169：镜像网关错误检测 + gameVersion 规范化
//
// 病历（装机 485b18c，"CurseForge 加载源无法使用"）：MCIM 镜像
// (mod.mcimirror.top) 的上游 key 池间歇性失败，此时返回 HTTP 200 + 合法
// JSON，但载荷是 {"error":"Internal Server Error","code":500,"detail":
// "Curseforge API service error: Request failed with status: 403 ..."}——
// 没有 "data" 数组。旧解析把这种响应当"无结果"静默 completion(@[], nil)
// （四种日志路径一条都不走 = 装机日志只见 starting request 不见任何结果），
// UI 空列表无报错；沙盒复现实测同一请求时好时坏（上游 key 池波动）。
// 修复：识别网关错误形态 → 打日志 → 自动重试一次（瞬态故障）→ 仍失败则
// 把 detail 浮出成真 NSError，UI 显示可读错误而非空列表。
// ============================================================================

/// CF gameVersion 规范化：安装器版本筛选传入的是实例版本 id，fabric 快照
/// 形如 "26.3-0a78cefc"（带 7~8 位十六进制构建哈希后缀），原样传给 CF 的
/// gameVersion 精确匹配必然落空 → 空列表。剥掉该形态的构建后缀；其它
/// 形态（如 Modrinth 风格 "1.20.1-1.2.3"）原样保留。
static NSString *CFA169NormalizeGameVersion(NSString *v) {
    if (![v isKindOfClass:NSString.class] || v.length == 0) return v;
    NSRange dash = [v rangeOfString:@"-" options:NSBackwardsSearch];
    if (dash.location == NSNotFound || dash.location == 0) return v;
    NSString *suffix = [v substringFromIndex:dash.location + 1];
    if (suffix.length >= 7 && suffix.length <= 8) {
        static NSCharacterSet *nonHex = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
        });
        if ([suffix rangeOfCharacterFromSet:nonHex].location == NSNotFound) {
            return [v substringToIndex:dash.location];
        }
    }
    return v;
}

@implementation CurseForgeAPI

+ (BOOL)ame169_isGatewayErrorJSON:(NSDictionary *)json {
    if (![json isKindOfClass:NSDictionary.class]) return NO;
    if ([json[@"data"] isKindOfClass:NSArray.class]) return NO;              // 正常载荷
    if ([json[@"pagination"] isKindOfClass:NSDictionary.class]) return NO;   // 正常分页响应
    return (json[@"error"] != nil || json[@"code"] != nil);
}

+ (NSError *)ame169_gatewayErrorFromJSON:(NSDictionary *)json {
    NSString *detail = [json[@"detail"] isKindOfClass:NSString.class] ? json[@"detail"] :
                       ([json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : @"unknown");
    return [NSError errorWithDomain:@"CurseForgeAPI" code:543
                           userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:
            @"CurseForge mirror gateway error (transient upstream failure, retried once already): %@", detail]
    }];
}

/// 重写 baseURL getter，根据 PLMirrorCenter 的资源搜索（AssetSearch）策略
/// 动态返回官方或 MCIM 镜像 URL，这样所有使用 self.baseURL 的请求都会自动走镜像
- (NSString *)baseURL {
    NSString *ame162_resolved = [PLMirrorCenter curseForgeAPIBaseURL];
    // Task162(CurseForge source completely unusable root fix): when no API key is configured, force fallback to
    // MCIM mirror. Official api.curseforge.com always returns 403 for requests without x-api-key,
    // and the default policy official_first makes keyless devices always hit official -> field-tested "curseforge
    // loading source completely unusable". MCIM mirror is keyless (server comes with public key,
    // field-tested GET /mods/search without x-api-key returns 200); devices with a key configured keep the original
    // mirror policy semantics (official_first/mirror_first/speed_first all take effect as before).
    if ([self apiKey].length == 0 && [ame162_resolved containsString:@"api.curseforge.com"]) {
        return [PLMirrorCenter mcimCurseForgeAPIBaseURL];
    }
    return ame162_resolved;
}

+ (instancetype)sharedInstance {
    static CurseForgeAPI *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super initWithURL:@"https://api.curseforge.com/v1"];
    if (self) {
        _session = [NSURLSession sharedSession];
    }
    return self;
}

#pragma mark - API Key 和 Headers

- (NSString *)apiKey {
    // 1. 运行时偏好（优先级最高；Task211：占位垃圾键视为未配置——装机实测
    // 它随 x-api-key 发出即 403，且阻断 keyless 镜像回退）
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    if ([runtimeKey isKindOfClass:NSString.class] && runtimeKey.length > 0 &&
        !CFAIsGarbageAPIKey(runtimeKey)) {
        NSLog(@"[CurseForgeAPI] API Key source: runtime preference (length=%lu, prefix=%@...)",
              (unsigned long)runtimeKey.length,
              runtimeKey.length >= 8 ? [runtimeKey substringToIndex:8] : runtimeKey);
        return runtimeKey;
    }
    static BOOL s_task211GarbageLogged = NO;
    if (!s_task211GarbageLogged && [runtimeKey isKindOfClass:NSString.class] && runtimeKey.length > 0) {
        s_task211GarbageLogged = YES;
        NSLog(@"[CurseForgeAPI] Task211: runtime preference holds a placeholder key (length=%lu) -- rejected as unset, falling through to compile-time macro / Info.plist / keyless mirror",
              (unsigned long)runtimeKey.length);
    }
    // 2. 编译时宏（使用字符串化宏方案，避免 @nil 边界问题）
    NSString *compiledKey = CFACompiledAPIKey();
    if (compiledKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: compile-time macro (length=%lu, prefix=%@...)",
              (unsigned long)compiledKey.length,
              compiledKey.length >= 8 ? [compiledKey substringToIndex:8] : compiledKey);
        return compiledKey;
    }
    // 3. Info.plist
    NSString *infoPlistKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CurseForgeAPIKey"];
    if ([infoPlistKey isKindOfClass:NSString.class] && infoPlistKey.length > 0) {
        NSLog(@"[CurseForgeAPI] API Key source: Info.plist (length=%lu, prefix=%@...)",
              (unsigned long)infoPlistKey.length,
              infoPlistKey.length >= 8 ? [infoPlistKey substringToIndex:8] : infoPlistKey);
        return infoPlistKey;
    }
    NSLog(@"[CurseForgeAPI] Warning: API Key not configured!");
    return @"";
}

- (NSDictionary *)headers {
    // Task 171：keyless 不再返回 nil。旧实现把 [self headers] == nil 当作
    // "API key 缺失"的致命门（getEndpoint / postEndpoint / searchModWithFilters
    // 三处直接返回 missingAPIKeyError，请求根本不发出）——而 baseURL getter
    // 在无 key 时早已强制回落 MCIM 镜像（Task162），镜像无 key 实测 200
    // （sandbox 复测：GET /mods/search 无任何 x-api-key 返回 200，冷启动首
    // 请求 ~11s、后续 ~2s；官方 API 无 key 恒 403）。两条路径的语义互相
    // 打架：镜像回退成了死代码，无 key 设备（构建时 GitHub secret
    // CONFIG_CURSEFORGE_API_KEY 未配置 = 所有 CI 构建）在 CurseForge 源
    // 上一律报 "CurseForge API key is missing..." 错误——用户实测
    // "curseforge 的 key 构建时没有设置，导致错误"。
    // 新语义：keyless = 照常发请求但不带 x-api-key（走镜像），有 key 照旧。
    NSString *key = [self apiKey];
    if (key.length == 0) {
        static BOOL s_task171Logged = NO;
        if (!s_task171Logged) {
            s_task171Logged = YES;
            NSLog(@"[CurseForgeAPI] Task171: no API key configured -- requests go keyless to the MCIM mirror (field-tested 200)");
        }
        return @{@"Accept" : @"application/json"};
    }
    return @{
        @"Accept": @"application/json",
        @"x-api-key": key
    };
}

+ (BOOL)isAPIKeyConfigured {
    // 与 apiKey getter 保持一致的三层 fallback，避免 UI 门控与实际请求判断不一致
    // Task211：占位垃圾键不算已配置（与 getter 的运行时拒绝同表）
    NSString *runtimeKey = [PLPreferences curseForgeAPIKey];
    if ([runtimeKey isKindOfClass:NSString.class] && runtimeKey.length > 0 &&
        !CFAIsGarbageAPIKey(runtimeKey)) {
        return YES;
    }
    NSString *compiledKey = CFACompiledAPIKey();
    if (compiledKey.length > 0) {
        return YES;
    }
    NSString *infoPlistKey = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CurseForgeAPIKey"];
    if ([infoPlistKey isKindOfClass:NSString.class] && infoPlistKey.length > 0) {
        return YES;
    }
    return NO;
}

// Task162: CurseForge source availability (for UI gating). Difference from isAPIKeyConfigured:
// the key is only an entry pass for direct official connection; when no key is configured, baseURL already
// forcibly falls back to the MCIM mirror (keyless, field-tested 200), the source is available to everyone. The
// "check key before switching to CurseForge source" gates should use this method -- the old gate
// directly blocked keyless users and sent them to the settings page to configure a key, while registering a
// CurseForge developer key is nearly infeasible for ordinary users, equivalent to "completely unusable".
// The API key settings entry is retained: devices with a key configured can go official via the mirror policy.
+ (BOOL)isSourceAvailable {
    return YES;
}

/// Task211：占位 API Key 判定（编译期 NULL 字面量字符串化产物家族，如
/// "((void *)0)"）。KeyViewController 的预填净化与保存门使用，与 apiKey
/// getter 的运行时拒绝共用同一张垃圾表（CFAIsGarbageAPIKey）。
+ (BOOL)isPlaceholderAPIKey:(NSString *)key {
    return CFAIsGarbageAPIKey(key);
}

- (NSError *)missingAPIKeyError {
    return [NSError errorWithDomain:@"CurseForgeAPI"
                               code:401
                           userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API key is missing. Set CURSEFORGE_API_KEY before building."}];
}

#pragma mark - 错误诊断辅助

- (NSError *)errorWithResponse:(NSURLResponse *)response
                          data:(NSData *)data
                 originalError:(NSError *)originalError
                       snippet:(NSString *)snippet {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];

    // 取响应体前 1024 字节作为 snippet（如果调用方未提供）
    if (!snippet && data.length > 0) {
        snippet = [self printableStringFromData:data maxLen:1024];
    }

    // 构造 userInfo
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (originalError) {
        [userInfo addEntriesFromDictionary:originalError.userInfo];
        if (originalError.localizedDescription.length > 0) {
            userInfo[NSLocalizedDescriptionKey] = originalError.localizedDescription;
        }
    } else {
        userInfo[NSLocalizedDescriptionKey] = @"CurseForge API request failed";
    }
    if (statusCode > 0) {
        userInfo[@"CurseForgeHTTPStatusCodeKey"] = @(statusCode);
    }
    if (contentType.length > 0) {
        userInfo[CurseForgeResponseContentTypeKey] = contentType;
    }
    if (snippet.length > 0) {
        userInfo[CurseForgeResponseSnippetKey] = snippet;
    }

    // Task211（403 友好化）：装机实测 403 以 text/plain 返回 "Forbidden:
    // API Key missing or invalid"，先死在 JSON 解析上——用户看到的是解析
    // 器的"未能读取数据，因为它的格式不正确。"（即"未知错误"）。把
    // API-Key 类 403 翻译成可读信息并指路设置页；其余 403 保持原语义。
    if (statusCode == 403 && [snippet rangeOfString:@"api key"
                                           options:NSCaseInsensitiveSearch].location != NSNotFound) {
        userInfo[NSLocalizedDescriptionKey] =
            @"CurseForge 拒绝了请求：API Key 缺失或无效（403）。请到「设置 → CurseForge API Key」检查；留空即可自动走免 Key 镜像，无需注册。";
    }

    // 打印诊断日志
    NSLog(@"[CurseForgeAPI] ❌ Request failed - statusCode=%ld, contentType=%@, error=%@, snippet=%@",
          (long)statusCode, contentType, originalError.localizedDescription, snippet);

    return [NSError errorWithDomain:@"CurseForgeAPI"
                               code:originalError.code ?: 0
                           userInfo:[userInfo copy]];
}

#pragma mark - 调试日志辅助

// 将 NSData 转为可打印字符串（处理非 UTF-8 内容，最多 maxLen 字节）
- (NSString *)printableStringFromData:(NSData *)data maxLen:(NSUInteger)maxLen {
    if (!data || data.length == 0) return @"";
    NSUInteger len = MIN(data.length, maxLen);
    NSData *subData = [data subdataWithRange:NSMakeRange(0, len)];
    // 尝试 UTF-8
    NSString *str = [[NSString alloc] initWithData:subData encoding:NSUTF8StringEncoding];
    if (str) return str;
    // 尝试 ISO-8859-1（Latin-1，能解码任意字节）
    str = [[NSString alloc] initWithData:subData encoding:NSISOLatin1StringEncoding];
    if (str) return str;
    // 兜底：十六进制
    NSMutableString *hex = [NSMutableString stringWithCapacity:len * 3];
    const char *bytes = subData.bytes;
    for (NSUInteger i = 0; i < len; i++) {
        [hex appendFormat:@"%02x ", (unsigned char)bytes[i]];
    }
    return [NSString stringWithFormat:@"(non-text data, hex) %@", hex];
}

// 输出请求/响应/JSON 解析错误的完整调试日志
- (void)debugLogRequest:(NSURLRequest *)request
               response:(NSURLResponse *)response
                   data:(NSData *)data
              jsonError:(NSError *)jsonError {
    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    NSInteger statusCode = httpResponse.statusCode;
    NSString *contentType = httpResponse.allHeaderFields[@"Content-Type"];
    NSURL *url = request.URL;
    NSString *method = request.HTTPMethod ?: @"GET";

    NSLog(@"\n"
          "========== [CurseForgeAPI] DEBUG ==========\n"
          "📍 Request: %@ %@\n"
          "📍 Request Headers:",
          method, url.absoluteString ?: @"<nil URL>");

    // 打印请求头（脱敏 API Key）
    NSDictionary *reqHeaders = request.allHTTPHeaderFields ?: @{};
    for (NSString *key in reqHeaders) {
        NSString *value = reqHeaders[key];
        if ([key.lowercaseString containsString:@"api"] || [key.lowercaseString containsString:@"key"]) {
            // 只显示前 8 位 + 长度
            if (value.length > 8) {
                NSLog(@"    %@: %@... (len=%lu)", key, [value substringToIndex:8], (unsigned long)value.length);
            } else {
                NSLog(@"    %@: (len=%lu)", key, (unsigned long)value.length);
            }
        } else {
            NSLog(@"    %@: %@", key, value);
        }
    }

    NSLog(@"📍 Response: statusCode=%ld, contentType=%@, dataLength=%lu",
          (long)statusCode, contentType ?: @"<none>", (unsigned long)(data.length));

    if (httpResponse) {
        // 打印响应头（最多 20 项）
        NSDictionary *respHeaders = httpResponse.allHeaderFields;
        NSUInteger i = 0;
        for (NSString *key in respHeaders) {
            if (i++ >= 20) break;
            NSLog(@"    %@: %@", key, respHeaders[key]);
        }
    }

    if (jsonError) {
        NSLog(@"📍 JSON Parse Error: domain=%@, code=%ld, desc=%@",
              jsonError.domain, (long)jsonError.code,
              jsonError.localizedDescription ?: @"<no description>");
    }

    if (data.length > 0) {
        NSString *bodyStr = [self printableStringFromData:data maxLen:2048];
        NSLog(@"📍 Response Body (first 2048 bytes):\n%@", bodyStr);
    } else {
        NSLog(@"📍 Response Body: (empty)");
    }
    NSLog(@"========== [CurseForgeAPI] END DEBUG ==========");
}

#pragma mark - 同步网络请求（原有 AFNetworking 实现，保持兼容）

- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSDictionary *headers = [self headers];
    // Task 171：keyless 镜像路径不再拦截（headers 恒非 nil，见其实现注释）。

    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    // Task169：网关错误（HTTP 200 + JSON 无 "data"）是瞬态上游故障，最多
    // 试 2 次（间隔 1.5s），仍失败置 lastError 返回 nil——同步调用方
    // （searchModWithFilters:previousPageResult: 等）拿 nil 后会把
    // lastError 浮出到错误 UI，不再是无声空列表。
    for (NSUInteger ame169_attempt = 0; ame169_attempt < 2; ame169_attempt++) {
        if (ame169_attempt > 0) {
            NSLog(@"[CurseForgeAPI] getEndpoint retrying %@ after gateway error (attempt %lu)",
                  endpoint, (unsigned long)(ame169_attempt + 1));
            [NSThread sleepForTimeInterval:1.5];
        }
        __block id result;
        __block NSError *failure = nil;
        dispatch_group_t group = dispatch_group_create();
        dispatch_group_enter(group);
        AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
        [manager GET:url parameters:params headers:headers progress:nil
              success:^(NSURLSessionTask *task, id obj) {
            // Task169：网关错误检测（镜像上游 key 池瞬态 403/500 包装）。
            if ([obj isKindOfClass:NSDictionary.class] && [CurseForgeAPI ame169_isGatewayErrorJSON:obj]) {
                NSLog(@"[CurseForgeAPI] getEndpoint gateway error on %@ (attempt %lu): error=%@ detail=%@",
                      endpoint, (unsigned long)(ame169_attempt + 1),
                      obj[@"error"], obj[@"detail"]);
                result = nil;
                failure = [CurseForgeAPI ame169_gatewayErrorFromJSON:obj];
            } else {
                result = obj;
            }
            dispatch_group_leave(group);
        } failure:^(NSURLSessionTask *operation, NSError *error) {
        failure = error;
        // Task172：镜像 5xx（AFNetworking 把 HTTP 502/504 归为 failure）同
        // 网关错误待遇——包装成 code 543 让下方既有重试循环接管（装机日志
        // 实锤 502 瞬态，几秒后重发即成功）。
        if ([operation respondsToSelector:@selector(response)]) {
            NSURLResponse *resp = [(NSURLSessionTask *)operation response];
            if ([self ame172_isTransientServerStatus:resp]) {
                NSInteger sc = [(NSHTTPURLResponse *)resp statusCode];
                NSLog(@"[CurseForgeAPI] getEndpoint mirror %ld server error on %@ (attempt %lu) -- will retry",
                      (long)sc, endpoint, (unsigned long)(ame169_attempt + 1));
                failure = [NSError errorWithDomain:@"CurseForgeAPI"
                                               code:543
                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"mirror server error %ld", (long)sc]}];
            }
        }
        dispatch_group_leave(group);
        }];
        dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
        if (result != nil) return result;
        if (failure != nil) {
            self.lastError = failure;
            // 网关错误才重试；普通网络错误（离线/超时）直接返回
            if (![failure.domain isEqualToString:@"CurseForgeAPI"] || failure.code != 543) return nil;
        }
    }
    return nil;
}

- (id)postEndpoint:(NSString *)endpoint params:(NSDictionary *)params {
    NSDictionary *headers = [self headers];
    // Task 171：keyless 镜像路径不再拦截（headers 恒非 nil）。
    
    __block id result;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    NSString *url = [self.baseURL stringByAppendingPathComponent:endpoint];
    AFHTTPSessionManager *manager = [AFHTTPSessionManager manager];
    manager.requestSerializer = [AFJSONRequestSerializer serializer];
    [manager POST:url parameters:params headers:headers progress:nil
           success:^(NSURLSessionTask *task, id obj) {
        result = obj;
        dispatch_group_leave(group);
    } failure:^(NSURLSessionTask *operation, NSError *error) {
        self.lastError = error;
        dispatch_group_leave(group);
    }];
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return result;
}

#pragma mark - 项目类型映射

- (NSNumber *)classIDForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"modpack"]) {
        return @(kCurseForgeClassIDModpacks);
    }
    if ([projectType isEqualToString:@"plugin"]) {
        return @(kCurseForgeClassIDBukkitPlugins);
    }
    if ([projectType isEqualToString:@"datapack"]) {
        return @(kCurseForgeClassIDDataPacks);
    }
    if ([projectType isEqualToString:@"shader"]) {
        return @(kCurseForgeClassIDShaders);
    }
    if ([projectType isEqualToString:@"resourcepack"]) {
        return @(kCurseForgeClassIDResourcePacks);
    }
    if ([projectType isEqualToString:@"world"]) {
        return @(kCurseForgeClassIDWorlds);
    }
    return @(kCurseForgeClassIDMods);
}

- (NSArray<NSString *> *)preferredFileExtensionsForProjectType:(NSString *)projectType {
    if ([projectType isEqualToString:@"shader"] ||
        [projectType isEqualToString:@"resourcepack"] ||
        [projectType isEqualToString:@"datapack"] ||
        [projectType isEqualToString:@"modpack"] ||
        [projectType isEqualToString:@"world"]) {
        return @[@"zip"];
    }
    return @[@"jar"];
}

#pragma mark - 文件校验与 URL 构造

- (BOOL)file:(NSDictionary *)file matchesProjectType:(NSString *)projectType {
    if (![file isKindOfClass:NSDictionary.class]) return NO;
    if ([file[@"isAvailable"] respondsToSelector:@selector(boolValue)] &&
        ![file[@"isAvailable"] boolValue]) {
        return NO;
    }
    if ([projectType isEqualToString:@"modpack"] && [file[@"isServerPack"] boolValue]) {
        return NO;
    }
    
    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSString *extension = fileName.pathExtension.lowercaseString;
    NSArray *extensions = [self preferredFileExtensionsForProjectType:projectType];
    return extensions.count == 0 || [extensions containsObject:extension];
}

- (NSString *)imageURLForProject:(NSDictionary *)project {
    NSDictionary *logo = [project[@"logo"] isKindOfClass:NSDictionary.class] ? project[@"logo"] : nil;
    NSString *image = logo[@"thumbnailUrl"];
    if (![image isKindOfClass:NSString.class] || image.length == 0) {
        image = logo[@"url"];
    }
    return [image isKindOfClass:NSString.class] ? image : @"";
}

- (NSMutableDictionary *)projectFromCurseForgeProject:(NSDictionary *)project projectType:(NSString *)projectType {
    NSString *title = project[@"name"];
    NSString *description = project[@"summary"];
    return @{
        @"apiSource": @(2),
        @"isModpack": @([projectType isEqualToString:@"modpack"]),
        @"projectType": projectType ?: @"mod",
        @"id": [project[@"id"] description] ?: @"",
        @"title": [title isKindOfClass:NSString.class] ? title : @"",
        @"description": [description isKindOfClass:NSString.class] ? description : @"",
        // Task175ï¼ä¸è½½ééä¼ ï¼ç¨æ·å®æµ"CF ä¸æ¾ç¤ºä¸è½½é"ï¼ãCF ååºå­æ®µæ¯
        // downloadCountï¼NSNumberï¼ï¼UI å¡çè¯»çæ¯ downloads é®ï¼Modrinth ä¾§
        // ååé®ï¼formatDownloadCount:ï¼ââæ§è½¬æ¢æè¯¥å­æ®µæ´ä¸ªä¸¢äºï¼ææ CF
        // æ¡ç®ææ¾ "0 æ¬¡ä¸è½½"ãéåå®æµï¼mod.mcimirror.top è£æºæ¥å¿ + æ¬å°
        // curl åè¯ï¼downloadCount ä¸ç´å¨ååºéï¼çº¯å±å­æ®µåæ­å±ã
        @"downloads": [project[@"downloadCount"] isKindOfClass:NSNumber.class]
            ? project[@"downloadCount"] : @0,
        @"imageUrl": [self imageURLForProject:project]
    }.mutableCopy;
}

- (NSString *)sha1ForFile:(NSDictionary *)file {
    NSArray *hashes = [file[@"hashes"] isKindOfClass:NSArray.class] ? file[@"hashes"] : @[];
    for (NSDictionary *hash in hashes) {
        if ([hash[@"algo"] integerValue] == 1 && [hash[@"value"] isKindOfClass:NSString.class]) {
            return hash[@"value"];
        }
    }
    return @"";
}

- (NSString *)downloadURLForFile:(NSDictionary *)file {
    NSString *url = file[@"downloadUrl"];
    if ([url isKindOfClass:NSString.class] && url.length > 0) {
        return CFAMirrorResolvedURL(url);
    }

    NSString *modId = [file[@"modId"] description];
    NSString *fileId = [file[@"id"] description];
    if (modId.length == 0 || fileId.length == 0) {
        return @"";
    }
    NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files/%@/download-url", modId, fileId] params:nil];
    NSString *fallback = [response isKindOfClass:NSDictionary.class] ? response[@"data"] : nil;
    if ([fallback isKindOfClass:NSString.class] && fallback.length > 0) {
        return CFAMirrorResolvedURL(fallback);
    }

    // 最终 fallback：Edge CDN
    NSString *fileName = [file[@"fileName"] isKindOfClass:NSString.class] ? file[@"fileName"] : @"";
    NSInteger numericFileId = fileId.integerValue;
    if (numericFileId <= 0 || fileName.length == 0) {
        return @"";
    }
    NSString *encodedName = [fileName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    // Task173：路径段去补零——旧 %03ld 形式（/files/8697/067/xxx.zip）经
    // MCIM 镜像 302 到 mediafilez 后被 403 拒（镜像不重写路径，mediafilez
    // 只认未补零的 /8697/67/ 形式；实测：补零→403 AccessDenied，未补零→200）。
    // edge.forgecdn.net 自身的 302 会正确重写补零路径，但镜像链不会——
    // 统一改用未补零形式（与 CF API downloadUrl 字段返回的格式一致）。
    NSString *cdnURL = [NSString stringWithFormat:@"https://edge.forgecdn.net/files/%ld/%ld/%@",
            (long)(numericFileId / 1000),
            (long)(numericFileId % 1000),
            encodedName ?: fileName];
    return CFAMirrorResolvedURL(cdnURL);
}

- (NSString *)gameVersionSummaryForFile:(NSDictionary *)file {
    NSArray<NSString *> *gameVersions = [file[@"gameVersions"] isKindOfClass:NSArray.class] ? file[@"gameVersions"] : @[];
    NSMutableArray<NSString *> *minecraftVersions = [NSMutableArray new];
    NSMutableArray<NSString *> *loaders = [NSMutableArray new];
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    for (NSString *value in gameVersions) {
        if (![value isKindOfClass:NSString.class] || value.length == 0) continue;
        unichar first = [value characterAtIndex:0];
        if ([digits characterIsMember:first]) {
            [minecraftVersions addObject:value];
        } else if ([value rangeOfString:@"client" options:NSCaseInsensitiveSearch].location == NSNotFound &&
                   [value rangeOfString:@"server" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            [loaders addObject:value];
        }
    }
    NSString *mcVersion = minecraftVersions.firstObject ?: @"";
    NSString *loader = loaders.firstObject ?: @"";
    if (mcVersion.length > 0 && loader.length > 0) {
        return [NSString stringWithFormat:@"%@/%@", mcVersion, loader];
    }
    return mcVersion.length > 0 ? mcVersion : loader;
}

/// Task173：排序/加载器参数适配（同步/异步搜索共用）。
/// 病历（用户实测“CF 列表完全没有根据排序方式排列”）：DownloadViewController
/// 传的是 Modrinth 风格的 sort 值（follows/downloads/updated/newest/relevance）
/// 与 loader 值（fabric/forge/quilt/neoforge），而 CF 搜索 API 需要的是
/// sortField（数字枚举）+ sortOrder + modLoaderType（数字枚举）——旧代码
/// 两个参数都没映射，请求里压根不带，CF 用默认 Featured/Popularity 排序，
/// 加载器筛选也整体失效。
/// 映射表（CF 官方 sortField：1=Featured 2=Popularity 3=LastUpdated
/// 4=Name 5=Author 6=TotalDownloads；modLoaderType：0=Any 1=Forge
/// 3=LiteLoader 4=Fabric 5=Quilt 6=NeoForge）：
///   follows  -> sortField=2  desc（人气≈关注）
///   downloads-> sortField=6  desc
///   updated  -> sortField=3  desc
///   newest   -> sortField=3  desc（CF 无“创建时间”排序，LastUpdated 最近似）
///   relevance-> 不带参数（searchFilter 存在时 CF 默认即相关度）
+ (void)ame173_applySortAndLoaderParams:(NSDictionary *)filters
                                  params:(NSMutableDictionary *)params {
    NSString *sort = [filters[@"sort"] isKindOfClass:NSString.class] ? filters[@"sort"] : nil;
    if (sort.length > 0) {
        if ([sort isEqualToString:@"follows"]) {
            params[@"sortField"] = @2;
            params[@"sortOrder"] = @"desc";
        } else if ([sort isEqualToString:@"downloads"]) {
            params[@"sortField"] = @6;
            params[@"sortOrder"] = @"desc";
        } else if ([sort isEqualToString:@"updated"] || [sort isEqualToString:@"newest"]) {
            params[@"sortField"] = @3;
            params[@"sortOrder"] = @"desc";
        }
        // relevance：不带 sortField（CF 默认）
    }
    NSString *loader = [filters[@"loader"] isKindOfClass:NSString.class] ? filters[@"loader"] : nil;
    // Task179：无加载器概念的资源类型禁发 modLoaderType。
    // 病历（用户实测“CF 资源文件页为空”）：autoApplyProfileFiltersIfNeeded
    // 把当前 profile 的加载器（如 fabric）自动预选到资源包/光影/数据包/
    // 世界 tab，而 CF 的 mods/search 对 classId=12/6552/6945/17 附带
    // modLoaderType 时返回零结果（镜像实测：classId=12&modLoaderType=4 ->
    // totalCount=0；同查询去掉 modLoaderType -> 1274）。整合包（4471）在
    // CF 有加载器标签不受影响。版本（gameVersion）参数保留——对全部
    // 类型有效。请求层统一拦截：手动在侧边栏选了加载器也不发。
    NSString *ame179_projectType = [filters[@"projectType"] isKindOfClass:NSString.class] ? filters[@"projectType"] : nil;
    BOOL ame179_loaderLessType = ([ame179_projectType isEqualToString:@"resourcepack"] ||
                                  [ame179_projectType isEqualToString:@"shader"] ||
                                  [ame179_projectType isEqualToString:@"datapack"] ||
                                  [ame179_projectType isEqualToString:@"world"]);
    if (ame179_loaderLessType) {
        return;
    }
    if (loader.length > 0) {
        NSDictionary<NSString *, NSNumber *> *ame173_loaderMap = @{
            @"forge": @1,
            @"liteloader": @3,
            @"fabric": @4,
            @"quilt": @5,
            @"neoforge": @6,
        };
        NSNumber *loaderType = ame173_loaderMap[loader.lowercaseString];
        if (loaderType) {
            params[@"modLoaderType"] = loaderType;
        }
    }
}

#pragma mark - 同步搜索（原始实现）

- (NSMutableArray *)searchModWithFilters:(NSDictionary<NSString *, NSString *> *)searchFilters
                     previousPageResult:(NSMutableArray *)previousPageResult {
    int pageSize = 50;
    NSString *projectType = searchFilters[@"projectType"];
    if (projectType.length == 0) {
        projectType = searchFilters[@"isModpack"] ? ([searchFilters[@"isModpack"] boolValue] ? @"modpack" : @"mod") : @"modpack";
    }
    
    NSMutableDictionary *params = @{
        @"gameId": @(kCurseForgeGameIDMinecraft),
        @"classId": [self classIDForProjectType:projectType],
        @"pageSize": @(pageSize),
        @"index": @(previousPageResult.count)
    }.mutableCopy;
    NSString *query = [searchFilters[@"name"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (query.length > 0) {
        params[@"searchFilter"] = query;
    }
    if (searchFilters[@"mcVersion"].length > 0) {
        // Task169：剥 fabric 构建哈希后缀（"26.3-0a78cefc" -> "26.3"）
        params[@"gameVersion"] = CFA169NormalizeGameVersion(searchFilters[@"mcVersion"]);
    }
    // Task173：排序 + 加载器（同步路径同款适配）
    [CurseForgeAPI ame173_applySortAndLoaderParams:searchFilters params:params];
    if ([projectType isEqualToString:@"minecraft_java_server"]) {
        params[@"categoryId"] = @(kCurseForgeCategoryIDServerUtility);
    }
    
    NSDictionary *response = [self getEndpoint:@"mods/search" params:params];
    if (!response) return nil;
    
    NSMutableArray *result = previousPageResult ?: [NSMutableArray new];
    NSArray *projects = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
    for (NSDictionary *project in projects) {
        if (![project isKindOfClass:NSDictionary.class]) continue;
        [result addObject:[self projectFromCurseForgeProject:project projectType:projectType]];
    }
    
    NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
    NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
    NSUInteger index = [pagination[@"index"] unsignedIntegerValue];
    NSUInteger count = [pagination[@"resultCount"] unsignedIntegerValue];
    self.reachedLastPage = total == 0 || index + count >= total;
    return result;
}

#pragma mark - 同步加载详情

- (void)loadDetailsOfMod:(NSMutableDictionary *)item {
    NSString *projectId = [item[@"id"] description];
    if (projectId.length == 0) return;
    
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    NSMutableArray<NSString *> *mcNames = [NSMutableArray new];
    NSMutableArray<NSString *> *urls = [NSMutableArray new];
    NSMutableArray<NSString *> *hashes = [NSMutableArray new];
    NSMutableArray<NSString *> *sizes = [NSMutableArray new];
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableArray<NSString *> *fileTypes = [NSMutableArray new];
    NSString *projectType = item[@"projectType"] ?: @"mod";
    
    NSUInteger index = 0;
    NSUInteger total = NSUIntegerMax;
    while (index < total) {
        NSDictionary *response = [self getEndpoint:[NSString stringWithFormat:@"mods/%@/files", projectId]
                                            params:@{@"pageSize": @10000, @"index": @(index)}];
        if (!response) return;
        
        NSArray *files = [response[@"data"] isKindOfClass:NSArray.class] ? response[@"data"] : @[];
        for (NSDictionary *file in files) {
            [self addFile:file toNames:names mcNames:mcNames urls:urls hashes:hashes sizes:sizes fileNames:fileNames fileTypes:fileTypes projectType:projectType];
        }
        
        NSDictionary *pagination = [response[@"pagination"] isKindOfClass:NSDictionary.class] ? response[@"pagination"] : @{};
        total = [pagination[@"totalCount"] unsignedIntegerValue];
        NSUInteger resultCount = [pagination[@"resultCount"] unsignedIntegerValue];
        if (resultCount == 0) break;
        index += resultCount;
    }
    
    if (names.count == 0) {
        self.lastError = [NSError errorWithDomain:@"CurseForgeAPI"
                                             code:404
                                         userInfo:@{NSLocalizedDescriptionKey: @"No downloadable files were found for this CurseForge project."}];
        return;
    }
    
    item[@"versionNames"] = names;
    item[@"mcVersionNames"] = mcNames;
    item[@"versionSizes"] = sizes;
    item[@"versionUrls"] = urls;
    item[@"versionHashes"] = hashes;
    item[@"versionFileNames"] = fileNames;
    item[@"versionFileTypes"] = fileTypes;
    item[@"versionDetailsLoaded"] = @(YES);
}

// 辅助：添加单个文件信息到数组（供 loadDetailsOfMod 内部调用）
- (void)addFile:(NSDictionary *)file toNames:(NSMutableArray *)names mcNames:(NSMutableArray *)mcNames urls:(NSMutableArray *)urls hashes:(NSMutableArray *)hashes sizes:(NSMutableArray *)sizes fileNames:(NSMutableArray *)fileNames fileTypes:(NSMutableArray *)fileTypes projectType:(NSString *)projectType {
    if (![self file:file matchesProjectType:projectType]) return;
    NSString *url = [self downloadURLForFile:file];
    if (url.length == 0) return;
    
    NSString *name = file[@"displayName"];
    if (![name isKindOfClass:NSString.class] || name.length == 0) {
        name = file[@"fileName"];
    }
    NSString *fileName = file[@"fileName"];
    if (![fileName isKindOfClass:NSString.class] || fileName.length == 0) {
        fileName = url.lastPathComponent;
    }
    
    [names addObject:name ?: @"Download"];
    [mcNames addObject:[self gameVersionSummaryForFile:file] ?: @""];
    [sizes addObject:file[@"fileLength"] ?: @0];
    [urls addObject:url];
    [hashes addObject:[self sha1ForFile:file] ?: @""];
    [fileNames addObject:fileName ?: @"download"];
    [fileTypes addObject:@""];
}

#pragma mark - 异步搜索（新增，推荐）

- (void)searchModWithFilters:(NSDictionary *)filters
                  completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSString *projectType = filters[@"projectType"];
    if (projectType.length == 0) {
        // 防御性回退：与同步版本一致，未指定 projectType 但声明 isModpack 时按整合包搜索
        projectType = [filters[@"isModpack"] boolValue] ? @"modpack" : @"mod";
    }
    NSString *query = filters[@"query"] ?: filters[@"name"] ?: @"";
    NSNumber *limitNum = filters[@"limit"] ?: @50;
    int limit = [limitNum intValue];
    NSNumber *offsetNum = filters[@"offset"] ?: @0;
    int offset = [offsetNum intValue];
    NSString *mcVersion = filters[@"mcVersion"] ?: filters[@"version"];
    
    // 构造 URL
    NSMutableString *urlString = [NSMutableString stringWithFormat:@"%@/mods/search?gameId=%ld&classId=%@&pageSize=%d&index=%d",
                                  self.baseURL,
                                  (long)kCurseForgeGameIDMinecraft,
                                  [self classIDForProjectType:projectType],
                                  limit, offset];
    if (query.length > 0) {
        NSString *encodedQuery = [query stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
        [urlString appendFormat:@"&searchFilter=%@", encodedQuery];
    }
    if (mcVersion.length > 0) {
        // Task169：剥 fabric 构建哈希后缀（"26.3-0a78cefc" -> "26.3"）
        [urlString appendFormat:@"&gameVersion=%@", CFA169NormalizeGameVersion(mcVersion)];
    }
    // Task173：排序 + 加载器参数（用户反馈“CF 列表没有按排序方式排列”）。
    // sortField/sortOrder/modLoaderType 直接拼 URL；值域映射见
    // ame173_applySortAndLoaderParams 的注释。
    {
        NSMutableDictionary *ame173_params = [NSMutableDictionary dictionary];
        [CurseForgeAPI ame173_applySortAndLoaderParams:filters params:ame173_params];
        if (ame173_params[@"sortField"]) {
            [urlString appendFormat:@"&sortField=%@&sortOrder=%@",
                ame173_params[@"sortField"], ame173_params[@"sortOrder"] ?: @"desc"];
        }
        if (ame173_params[@"modLoaderType"]) {
            [urlString appendFormat:@"&modLoaderType=%@", ame173_params[@"modLoaderType"]];
        }
    }
    
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    NSDictionary *headers = [self headers];
    // Task 171：keyless 镜像路径不再拦截（旧：headers==nil -> missingAPIKeyError，
    // Task162 的镜像回退成死代码）；headers 无 key 时也返回 Accept-only 字典。
    for (NSString *key in headers) {
        [request setValue:headers[key] forHTTPHeaderField:key];
    }
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] searchModWithFilters starting request: %@", urlString);

    [self ame169_issueSearchRequest:request attempt:0 projectType:projectType completion:completion];
}

/// Task169：异步搜索请求的实际执行（带网关错误检测 + 一次自动重试）。
/// 从 searchModWithFilters:completion: 拆出：NSURLRequest 不可变可安全复用，
/// 镜像网关错误（HTTP 200 + JSON 但无 "data"）为瞬态上游故障，隔 1.5s
/// 重发一次；仍失败才把错误浮出。
/// Task172：镜像 5xx 判定（NSHTTPURLResponse 状态码 >= 500 = 瞬态上游
/// 故障，值得自动重试；4xx 是确定性错误不重试）。
- (BOOL)ame172_isTransientServerStatus:(NSURLResponse *)response {
    if (![response isKindOfClass:NSHTTPURLResponse.class]) return NO;
    return ((NSHTTPURLResponse *)response).statusCode >= 500;
}

/// Task172：搜索请求退避重试（2s，后台队列；attempt 上限由调用方把关）。
- (void)ame172_retrySearchRequest:(NSURLRequest *)request
                          attempt:(NSUInteger)attempt
                       projectType:(NSString *)projectType
                        completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion
                           reason:(NSString *)reason {
    NSLog(@"[CurseForgeAPI] Task172 retrying search after %@ (attempt %lu -> %lu)",
          reason, (unsigned long)(attempt + 1), (unsigned long)(attempt + 2));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [self ame169_issueSearchRequest:request attempt:attempt + 1 projectType:projectType completion:completion];
    });
}

- (void)ame169_issueSearchRequest:(NSURLRequest *)request
                          attempt:(NSUInteger)attempt
                        projectType:(NSString *)projectType
                       completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // 网络错误：透传原 NSError 并附带 HTTP 诊断信息（如可获取）
            NSLog(@"[CurseForgeAPI] searchModWithFilters network error: %@", error.localizedDescription);
            // Task212：瞬态网络错误（超时/连接重置/DNS）自动退避重试一次。
            // 2026-10-02 沙盒直连 MCIM 镜像实测：同一合法查询时好时坏（一次
            // 网络错误、重发即成功）。旧逻辑直接浮出错误 = 用户视角
            // "筛选/搜索时好时坏"。仅 NSURLErrorDomain（传输层瞬态）重试；其余域例如自定义
            // 取消错误仍直接浮出。
            if (attempt < 1 && [error.domain isEqualToString:NSURLErrorDomain]) {
                [self ame172_retrySearchRequest:request attempt:attempt projectType:projectType completion:completion
                                        reason:[NSString stringWithFormat:@"transient network error %ld", (long)error.code]];
                return;
            }
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }
        if (!data || data.length == 0) {
            // 响应数据为空：返回包含 HTTP 状态码的 NSError
            NSLog(@"[CurseForgeAPI] searchModWithFilters empty response");
            [self debugLogRequest:request response:response data:data jsonError:nil];
            // Task212：空体本身就是镜像瞬态波动（沙盒实测命中
            // 过一次空 200）——不再要求 5xx 才重试，任意状态码的空体都退避一次。
            // Task172：5xx 空体也是镜像瞬态——同 502 HTML 页待遇，退避重试
            if (attempt < 1 || ([self ame172_isTransientServerStatus:response] && attempt < 2)) {
                [self ame172_retrySearchRequest:request attempt:attempt projectType:projectType completion:completion reason:@"empty 5xx body"];
                return;
            }
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:emptyError snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            // JSON 解析失败：输出完整调试日志，便于诊断 401 HTML 错误页等场景
            NSLog(@"[CurseForgeAPI] searchModWithFilters JSON parse failed");
            [self debugLogRequest:request response:response data:data jsonError:jsonError];
            // Task172：镜像 5xx（如 502 Bad Gateway HTML 页）是瞬态上游故障
            // ——760c07c 装机日志实锤：classId=4471 搜索 502，用户手动重刷
            // 5 秒后即成功。旧代码直接把 502 浮出为错误（用户被迫手动重试），
            // 现与网关错误同待遇：退避 2s 自动重试（最多 2 次）。
            if ([self ame172_isTransientServerStatus:response] && attempt < 2) {
                [self ame172_retrySearchRequest:request attempt:attempt projectType:projectType completion:completion reason:@"5xx non-JSON body"];
                return;
            }
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI"
                                                                   code:3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned non-JSON response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:baseError snippet:nil];
            if (completion) completion(nil, diagnosticError);
            return;
        }

        NSArray *projects = json[@"data"];
        if (![projects isKindOfClass:NSArray.class]) {
            // Task169：网关错误 JSON（镜像把上游 403/500 包成 HTTP 200 的
            // {"error":..,"code":..}，无 "data"）。旧代码在这里静默
            // completion(@[], nil) —— UI 空列表、日志零痕迹（装机
            // 485b18c 四连空搜索的根因）。现在：识别 → 日志 → 重试一次
            // → 仍失败浮出真错误。
            if ([CurseForgeAPI ame169_isGatewayErrorJSON:json]) {
                NSLog(@"[CurseForgeAPI] searchModWithFilters gateway error (attempt %lu): %@",
                      (unsigned long)(attempt + 1),
                      [self printableStringFromData:data maxLen:512]);
                if (attempt < 1) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                   dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
                        NSLog(@"[CurseForgeAPI] searchModWithFilters retrying after gateway error");
                        [self ame169_issueSearchRequest:request attempt:attempt + 1 projectType:projectType completion:completion];
                    });
                    return;
                }
                if (completion) completion(nil, [CurseForgeAPI ame169_gatewayErrorFromJSON:json]);
                return;
            }
            // Task179：无 data 数组且非网关错误（如 {"data":null}）不再静默回空列表——
            // 用户实测“cf 资源文件页为空”的唙形之一（空页、无错误提示、日志只有
            // 成功码）。退避重试一次；仍无 data 则浮出真错误（不再伪装成功的空结果）。
            NSLog(@"[CurseForgeAPI] Task179 search response missing data array (attempt %lu, projectType=%@): %@",
                  (unsigned long)(attempt + 1), projectType,
                  [self printableStringFromData:data maxLen:256]);
            if (attempt < 1) {
                [self ame172_retrySearchRequest:request attempt:attempt projectType:projectType completion:completion reason:@"missing data array"];
                return;
            }
            NSError *ame179_noData = [NSError errorWithDomain:@"CurseForgeAPI"
                                                          code:4
                                                      userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned no data array"}];
            if (completion) completion(nil, ame179_noData);
            return;
        }

        NSMutableArray *results = [NSMutableArray array];
        for (NSDictionary *project in projects) {
            if (![project isKindOfClass:NSDictionary.class]) continue;
            [results addObject:[self projectFromCurseForgeProject:project projectType:projectType]];
        }

        // 更新分页状态
        NSDictionary *pagination = json[@"pagination"] ?: @{};
        NSUInteger total = [pagination[@"totalCount"] unsignedIntegerValue];
        NSUInteger idx = [pagination[@"index"] unsignedIntegerValue];
        NSUInteger count = [pagination[@"resultCount"] unsignedIntegerValue];
        self.reachedLastPage = total == 0 || idx + count >= total;

        NSLog(@"[CurseForgeAPI] searchModWithFilters success: returned %lu items (total=%lu)",
              (unsigned long)results.count, (unsigned long)total);
        if (completion) completion(results, nil);
    }];
    [task resume];
}

#pragma mark - 异步获取版本

- (void)getVersionsForModWithID:(NSString *)modID
                     completion:(void (^)(NSArray<ModVersion *> * _Nullable, NSError * _Nullable))completion {
    if (modID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod ID"}]);
        return;
    }

    // 直接异步调用 loadDetailsOfMod:completion:，避免阻塞调用线程
    NSMutableDictionary *item = [@{@"id": modID, @"projectType": @"mod"} mutableCopy];
    [self loadDetailsOfMod:item completion:^(NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        if (completion) completion(item[@"versions"], nil);
    }];
}

// Task 5.10：在线整合包下载路径统一——zip 下载完成后由
// MinecraftResourceDownloadTask.importDownloadedModpackPackage:detail: 复用
// ModpackImportService 统一导入（解析/解压/依赖下载/加载器/游戏文件/profile），
// 此处不再维护 API 侧的整合包解包双轨逻辑（modpackDependencyInfoFromManifest:/
// fileForProjectID:fileID:/filesByFileID:/submitDownloadTasksFromPackage: 已删除）。

- (NSMutableDictionary *)projectForFileHash:(NSNumber *)fingerprint projectType:(NSString *)projectType {
    // 修复：本方法接收的是 MurmurHash2 指纹数字（由 CurseForgeMurmurHash 对文件计算得到），
    // 原签名接收 NSString 且内部 [murmurHash longLongValue]，调用方传入文件路径时恒为 0，永不命中
    if (![fingerprint isKindOfClass:[NSNumber class]]) return nil;
    NSString *urlStr = [NSString stringWithFormat:@"%@/fingerprints/%ld", self.baseURL, (long)kCurseForgeGameIDMinecraft];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    // Task 171：空 key 不发空 x-api-key 头（空值头会被镜像网关当成坏请求）
    {
        NSString *ame171_key = [self apiKey];
        if (ame171_key.length > 0) {
            [request setValue:ame171_key forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"fingerprints": @[fingerprint]};
    NSError *jsonError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (jsonError) return nil;
    request.HTTPBody = bodyData;

    __block NSMutableDictionary *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *exactMatches = [json isKindOfClass:NSDictionary.class] ? json[@"data"][@"exactMatches"] : nil;
            if ([exactMatches isKindOfClass:NSArray.class] && exactMatches.count > 0) {
                NSDictionary *match = [exactMatches[0] isKindOfClass:NSDictionary.class] ? exactMatches[0] : nil;
                NSDictionary *file = [match[@"file"] isKindOfClass:NSDictionary.class] ? match[@"file"] : nil;
                if (file) {
                    result = [NSMutableDictionary dictionary];
                    // 修复：exactMatches[].id 是文件 ID 而非项目 ID，项目 ID 必须取 file.modId，
                    // 否则后续 mods/{id}/files 拉版本列表会查错项目
                    result[@"id"] = [file[@"modId"] stringValue];
                    result[@"fileId"] = [file[@"id"] stringValue];
                    result[@"name"] = file[@"displayName"];
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return result;
}

#pragma mark - 批量指纹反查

- (NSArray<NSMutableDictionary *> *)fileFingerprints:(NSArray<NSNumber *> *)fingerprints {
    if (!fingerprints || fingerprints.count == 0) return @[];
    NSString *urlStr = [NSString stringWithFormat:@"%@/fingerprints/%ld", self.baseURL, (long)kCurseForgeGameIDMinecraft];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return @[];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    // Task 171：空 key 不发空 x-api-key 头（空值头会被镜像网关当成坏请求）
    {
        NSString *ame171_key = [self apiKey];
        if (ame171_key.length > 0) {
            [request setValue:ame171_key forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSDictionary *body = @{@"fingerprints": fingerprints};
    NSError *bodyError = nil;
    NSData *bodyData = [NSJSONSerialization dataWithJSONObject:body options:0 error:&bodyError];
    if (bodyError) return @[];
    request.HTTPBody = bodyData;

    __block NSMutableArray *results = [NSMutableArray array];
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && data) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *exactMatches = [json isKindOfClass:NSDictionary.class] ? json[@"data"][@"exactMatches"] : nil;
            if ([exactMatches isKindOfClass:NSArray.class]) {
                for (NSDictionary *match in exactMatches) {
                    if (![match isKindOfClass:NSDictionary.class]) continue;
                    NSDictionary *file = [match[@"file"] isKindOfClass:[NSDictionary class]] ? match[@"file"] : nil;
                    if (!file) continue;
                    NSMutableDictionary *item = [NSMutableDictionary dictionary];
                    // 修复：与 projectForFileHash 一致，项目 ID 取 file.modId（exactMatches[].id 是文件 ID），
                    // 名称取 file.displayName（顶层无 name 字段）
                    item[@"id"] = [file[@"modId"] stringValue];
                    item[@"fileId"] = [file[@"id"] stringValue];
                    item[@"name"] = file[@"displayName"];
                    [results addObject:item];
                }
            }
        }
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));
    return results;
}

#pragma mark - 异步详情加载

- (void)loadDetailsOfMod:(NSMutableDictionary *)item completion:(void (^)(NSError * _Nullable error))completion {
    NSString *modID = [item[@"id"] description];
    if (modID.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid mod ID"}]);
        });
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:@"%@/mods/%@/files", self.baseURL, modID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{
            completion([NSError errorWithDomain:@"CurseForgeAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // Task 171：空 key 不发空 x-api-key 头（keyless 镜像路径；两处同构调用点）
    {
        NSString *ame171_key = [self apiKey];
        if (ame171_key.length > 0) {
            [request setValue:ame171_key forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] loadDetailsOfMod starting request modID=%@: %@", modID, urlStr);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            // 网络错误：透传并附带诊断信息
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod network error: %@", error.localizedDescription);
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }
        if (!data || data.length == 0) {
            // 响应数据为空
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod empty response");
            [self debugLogRequest:request response:response data:data jsonError:nil];
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI"
                                                      code:2
                                                  userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:emptyError snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }

        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            // JSON 解析失败：输出完整调试日志
            NSLog(@"[CurseForgeAPI] loadDetailsOfMod JSON parse failed");
            [self debugLogRequest:request response:response data:data jsonError:jsonError];
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI"
                                                                   code:3
                                                               userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned non-JSON response"}];
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:baseError snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(diagnosticError); });
            return;
        }

        NSArray *files = [json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil;
        if (![files isKindOfClass:NSArray.class]) files = @[];
        NSMutableArray *versions = [NSMutableArray array];
        for (NSDictionary *file in files) {
            if (![file isKindOfClass:NSDictionary.class]) continue;
            ModVersion *mv = [[ModVersion alloc] initWithDictionary:file];
            if (mv) [versions addObject:mv];
        }
        item[@"versions"] = versions;
        NSLog(@"[CurseForgeAPI] loadDetailsOfMod success: modID=%@, %lu versions",
              modID, (unsigned long)versions.count);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
    }];
    [task resume];
}

#pragma mark - Server Packs（服务端整合包）

- (void)searchServersWithFilters:(NSDictionary *)filters
                      completion:(void (^)(NSArray * _Nullable, NSError * _Nullable))completion {
    // CurseForge 没有独立的 server 类型，使用 modpack（classId=4471）作为"服务器整合包"展示
    NSMutableDictionary *serverFilters = [filters mutableCopy] ?: [NSMutableDictionary dictionary];
    serverFilters[@"projectType"] = @"modpack";
    // 复用现有的异步 modpack 搜索逻辑
    [self searchModWithFilters:serverFilters completion:^(NSArray * _Nullable results, NSError * _Nullable error) {
        if (error) {
            if (completion) completion(nil, error);
            return;
        }
        // 在每个结果中追加 serverID 字段，便于 ServerItem 统一识别
        NSMutableArray *serverResults = [NSMutableArray array];
        for (NSDictionary *item in results) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *serverItem = [item mutableCopy];
            serverItem[@"serverID"] = item[@"id"] ?: @"";
            serverItem[@"projectType"] = @"modpack";
            [serverResults addObject:serverItem];
        }
        if (completion) completion(serverResults, nil);
    }];
}

- (void)getServerPackFilesForModpack:(NSString *)modpackID
                          completion:(void (^)(NSArray * _Nullable, NSError * _Nullable error))completion {
    if (modpackID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Invalid modpack ID"}]);
        return;
    }

    // 拉取该 modpack 的所有文件，筛选 isServerPack=true 的文件
    NSString *urlStr = [NSString stringWithFormat:@"%@/mods/%@/files?pageSize=10000", self.baseURL, modpackID];
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    // Task 171：空 key 不发空 x-api-key 头（keyless 镜像路径；两处同构调用点）
    {
        NSString *ame171_key = [self apiKey];
        if (ame171_key.length > 0) {
            [request setValue:ame171_key forHTTPHeaderField:@"x-api-key"];
        }
    }
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    request.timeoutInterval = 30.0;
    NSLog(@"[CurseForgeAPI] 🔍 getServerPackFilesForModpack: %@", urlStr);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            NSError *diagnosticError = [self errorWithResponse:response data:data originalError:error snippet:nil];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, diagnosticError); });
            return;
        }
        if (!data || data.length == 0) {
            NSError *emptyError = [NSError errorWithDomain:@"CurseForgeAPI" code:3 userInfo:@{NSLocalizedDescriptionKey: @"CurseForge API returned empty response"}];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, emptyError); });
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError || ![json isKindOfClass:NSDictionary.class]) {
            NSError *baseError = jsonError ?: [NSError errorWithDomain:@"CurseForgeAPI" code:4 userInfo:@{NSLocalizedDescriptionKey: @"Invalid JSON"}];
            if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, baseError); });
            return;
        }

        NSArray *files = [json[@"data"] isKindOfClass:[NSArray class]] ? json[@"data"] : @[];
        NSMutableArray *serverPacks = [NSMutableArray array];
        for (NSDictionary *file in files) {
            if (![file isKindOfClass:[NSDictionary class]]) continue;
            // 筛选 isServerPack=true 的文件（与 loadDetailsOfMod 中排除 server pack 的逻辑相反）
            if (![file[@"isServerPack"] boolValue]) continue;
            // 解析下载 URL 和文件名
            NSString *dlURL = [self downloadURLForFile:file];
            NSString *fileName = [file[@"fileName"] isKindOfClass:[NSString class]] ? file[@"fileName"] : @"";
            NSString *displayName = [file[@"displayName"] isKindOfClass:[NSString class]] ? file[@"displayName"] : fileName;
            [serverPacks addObject:@{
                @"serverPackDownloadURL": dlURL ?: @"",
                @"serverPackFileName": fileName ?: @"",
                @"serverPackDisplayName": displayName ?: fileName ?: @"",
                @"serverPackFileSize": file[@"fileLength"] ?: @0,
                @"fileId": [file[@"id"] description] ?: @"",
                @"modpackId": modpackID
            }];
        }
        NSLog(@"[CurseForgeAPI] getServerPackFilesForModpack success: modpackID=%@, %lu server packs",
              modpackID, (unsigned long)serverPacks.count);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(serverPacks, nil); });
    }];
    [task resume];
}


/// ★ Task227（issue #10）：按 modId 取展示名（依赖确认单用）。
/// GET /mods/{id} → data.name。getEndpoint 是同步方法——包一层全局队列。
- (void)ame227_fetchModTitle:(NSString *)modID
                  completion:(void (^)(NSString * _Nullable title, NSError * _Nullable error))completion {
    if (modID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:60 userInfo:@{NSLocalizedDescriptionKey: @"no mod id"}]);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *resp = [self getEndpoint:[NSString stringWithFormat:@"mods/%@", modID] params:nil];
        NSString *title = nil;
        if ([resp isKindOfClass:[NSDictionary class]]) {
            id data = resp[@"data"];
            if ([data isKindOfClass:[NSDictionary class]] && [data[@"name"] isKindOfClass:[NSString class]]) {
                title = data[@"name"];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(title, title ? nil : (self.lastError ?: [NSError errorWithDomain:@"CurseForgeAPI" code:61 userInfo:@{NSLocalizedDescriptionKey: @"no title"}]));
        });
    });
}


- (void)ame238_fetchProjectInfo:(NSString *)modID
                     completion:(void (^)(NSDictionary * _Nullable info, NSError * _Nullable error))completion {
    // ★ Task238（用户："cf源没有显示前置"）：与 ame227_fetchModTitle 同一
    //   端点（GET /mods/{id}），但完整取出 name / summary / logo.thumbnailUrl
    //   ——前置富卡片（图标+名称+介绍）在 CF 源下的数据一步到位。
    if (modID.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"CurseForgeAPI" code:62 userInfo:@{NSLocalizedDescriptionKey: @"no mod id"}]);
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *resp = [self getEndpoint:[NSString stringWithFormat:@"mods/%@", modID] params:nil];
        NSDictionary *info = nil;
        if ([resp isKindOfClass:[NSDictionary class]]) {
            id data = resp[@"data"];
            if ([data isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *ame238_out = [NSMutableDictionary dictionary];
                if ([data[@"name"] isKindOfClass:[NSString class]]) ame238_out[@"name"] = data[@"name"];
                if ([data[@"summary"] isKindOfClass:[NSString class]]) ame238_out[@"summary"] = data[@"summary"];
                id ame238_logo = data[@"logo"];
                if ([ame238_logo isKindOfClass:[NSDictionary class]] &&
                    [ame238_logo[@"thumbnailUrl"] isKindOfClass:[NSString class]]) {
                    ame238_out[@"icon"] = ame238_logo[@"thumbnailUrl"];
                }
                if (ame238_out.count > 0) info = ame238_out;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(info, info ? nil : (self.lastError ?: [NSError errorWithDomain:@"CurseForgeAPI" code:63 userInfo:@{NSLocalizedDescriptionKey: @"no project info"}]));
        });
    });
}

@end