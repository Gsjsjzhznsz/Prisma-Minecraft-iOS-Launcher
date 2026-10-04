#import "AFNetworking.h"
#import "ThirdPartyAuthenticator.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"
#import <Security/Security.h>

// authlib-injector 下载源：BMCLAPI 镜像优先，失败后回退到官方源
// 修复史：
// - 1.2.6 -> 1.2.7（build 55，Task128）：1.2.6 的 ASM 无法识别 Java 25
//   class file version 69，javaagent 加载失败。1.2.7 同时兼容 Java 17/21/25。
// - 1.2.7 -> 1.2.8（build 56，Task132）：第三方账号皮肤不加载的根治。
//   MC 26.3 系列重写了 authlib 的服务发现架构（独立 discovery 链路），
//   1.2.7（2025-12）只改写旧的 minecraftservices/sessionserver URL 常量，
//   新链路绕过改写直连 Mojang 官方端点 -> 第三方 token 被 401 拒绝 ->
//   皮肤/材质全部回落 Steve/Alex。1.2.8（2026-07，新增 httpd/DiscoveryFilter）
//   补上新 discovery 链路的重定向；皮肤站 issue #298/#300 症状与用户
//   装机日志（authlib 正常注入但皮肤不加载）完全吻合，官方以 1.2.8 修复。
//   另：1.2.7 对 --userType mojang 的 msa 改写也会把 MC 推上
//   MinecraftServices 链路（401 同源），1.2.8 一并修正。
//   Java 17/21/25 兼容性（Task128 升级理由）在 1.2.8 保持不变。
#define AUTHLIB_INJECTOR_URL_BMCL  @"https://bmclapi2.bangbang93.com/mirrors/authlib-injector/artifact/56/authlib-injector-1.2.8.jar"
#define AUTHLIB_INJECTOR_URL_GITHUB @"https://authlib-injector.yushi.moe/artifact/56/authlib-injector-1.2.8.jar"
#define AUTHLIB_INJECTOR_FILE @"authlib-injector.jar"
#define AUTHLIB_INJECTOR_VERSION @"1.2.8"
#define AUTHLIB_INJECTOR_VERSION_FILE @"authlib-injector.version"

// Helper function to create NSError
static NSError* createError(NSString *message, NSInteger code) {
    return [NSError errorWithDomain:@"ThirdPartyAuthenticator"
                            code:code
                        userInfo:@{NSLocalizedDescriptionKey: message}];
}

// ---------------------------------------------------------------------------
// Task 133：第三方皮肤头像根治（本地渲染 + file:// URL）
//
// 事故链（b33e550 构建 + 3bcf8c4 装机日志，LittleSkin 实测取证）：
//   1. profile 端点 URL 用了【带连字符】的 profileId——Yggdrasil 规范
//      （authlib-injector 文档，Mojang 官方 sessionserver 同款）要求无连字符
//      形态。实测：47e84d5d-0c12-4d51-…（带连字符）→ 404 Not Found；
//      47e84d5d0c124d51…（无连字符）→ 200 + yiqiu4178 + 皮肤纹理。带连字符
//      404 后代码回落 mc-heads.net/avatar/<用户名>——该服务只认 Mojang 官方
//      玩家，第三方角色名一律渲染默认 Steve。这是头像 Steve 的根因一。
//   2. 即使修好 URL，旧的 helm.png 换算（skinURL 的 ".png" 替换成
//      "/helm.png"）对第三方皮肤站也无效：Blessing Skin 系（littleskin 等）
//      的纹理 URL 是【按请求动态签名的一次性 URL】（实测两次请求同一 profile
//      返回的哈希都不同，过期后 404），且不提供 helm.png 换算端点。这是
//      根因二。
//
// 修复（三层）：
//   1. 三处 profile URL 构造一律用无连字符 profileId（存储键保持带连字符
//      不变——accountId/账户文件/启动日志的既有形态零迁移）；
//   2. 拿到 profile 响应后【立即】下载真实皮肤 PNG（一次性签名 URL 在本次
//      会话内有效），本地渲染头像：脸 8x8 @(8,8) + 帽层 8x8 @(40,8) 合成
//      放大到 128x128（最近邻插值保持像素风），写入 Documents/avatars/
//      skin-<accountId>.png，profilePicURL 存 file:// URL（AvatarManager 的
//      自定义头像键空间是 <accountId>.png，skin- 前缀不冲突；两个消费者
//      AccountList 的 setImageWithURL: 与右面板的 dataWithContentsOfURL:
//      均原生支持 file URL——ModpackImportService:171 已实证）；
//   3. 兜底链保留：本地渲染失败（网络/解码/皮肤尺寸异常）→ 旧 helm.png
//      换算（Mojang 风格纹理主机可能存在）→ mc-heads（仅 Mojang 账户有效）。
//   另外 initWithData 覆写：存量账户（profilePicURL 非 file:// 形态）在
//   加载时自动后台重取一次——升级后无需重新登录即可自愈，且用户在皮肤站
//   换肤后下次启动自动同步。
// ---------------------------------------------------------------------------

/// profileId 去连字符（仅用于 URL 构造；Yggdrasil 规范要求无连字符形态）。
static NSString *ame133_undashedProfileId(NSString *profileId) {
    if (![profileId isKindOfClass:NSString.class] || profileId.length == 0) {
        return profileId;
    }
    return [profileId stringByReplacingOccurrencesOfString:@"-" withString:@""];
}

/// Task 134：profilePicURL 更新 + saveChanges 之后通知 UI 刷新。
/// 病历：存量账户自愈（initWithData 后台重取）与新登录的头像抓取都只写
/// authData + 落盘——首页资料磁贴（LauncherNewsViewController）只在
/// viewDidLoad/账户切换时读一次 profilePicURL，启动时读到的还是旧的失效
/// URL（helm 一次性签名 / mc-heads 404），下载失败后头像停在占位图，
/// 直到重启启动器才显示（重启时 file:// 已落盘）。右面板/账户列表每次
/// 出现都重读所以看起来正常——"档案页有图标、右上角没有"的不对称即此。
/// 解法：所有 profilePicURL 写点收尾时在主线程广播 UpdateAccountInfo
/// （两个展示 VC 均已注册该通知，重读 authData 即拿到 file:// 新值）。
static void ame134_notifyAccountInfoUpdated(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"UpdateAccountInfo"
                                                            object:nil
                                                          userInfo:nil];
    });
}

/// 从皮肤 PNG 本地渲染头像：脸 8x8 @(8,8) + 帽层 8x8 @(40,8) 合成，
/// 最近邻放大到 128x128。兼容 64x64 / 128x128（等比 HD）与 64x32（经典）
/// 布局——三类皮肤的脸/帽层坐标同为 (8s,8s) 与 (40s,8s)，s=宽/64。
static UIImage *ame133_renderAvatarFromSkin(UIImage *skin) {
    if (skin == nil || skin.CGImage == nil) return nil;
    size_t w = CGImageGetWidth(skin.CGImage);
    size_t h = CGImageGetHeight(skin.CGImage);
    // 合法皮肤：宽>=64 且（正方形 或 高=宽/2 的经典布局）
    if (w < 64 || (h != w && h * 2 != w)) return nil;
    CGFloat s = (CGFloat)w / 64.0;
    CGFloat tile = 8.0 * s;
    CGRect faceRect = CGRectMake(8.0 * s, 8.0 * s, tile, tile);
    CGRect hatRect = CGRectMake(40.0 * s, 8.0 * s, tile, tile);
    CGImageRef faceImg = CGImageCreateWithImageInRect(skin.CGImage, faceRect);
    CGImageRef hatImg = CGImageCreateWithImageInRect(skin.CGImage, hatRect);
    if (faceImg == NULL) {
        if (hatImg) CFRelease(hatImg);
        return nil;
    }
    const CGFloat out = 128.0;
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1;
    UIGraphicsImageRenderer *renderer =
        [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(out, out) format:fmt];
    UIImage *result = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        // 最近邻插值保持像素风（系统默认双线性会把 8x8 糊成一团）
        CGContextSetInterpolationQuality(cg, kCGInterpolationNone);
        // UIKit 渲染上下文原点在左上，CGImage 绘制以左下为原点——翻转一次
        CGContextSaveGState(cg);
        CGContextTranslateCTM(cg, 0, out);
        CGContextScaleCTM(cg, 1, -1);
        CGContextDrawImage(cg, CGRectMake(0, 0, out, out), faceImg);
        if (hatImg) {
            CGContextDrawImage(cg, CGRectMake(0, 0, out, out), hatImg);
        }
        CGContextRestoreGState(cg);
    }];
    CFRelease(faceImg);
    if (hatImg) CFRelease(hatImg);
    return result;
}

/// 本地头像落盘路径：Documents/avatars/skin-<accountId>.png
/// （AvatarManager 自定义头像键空间是 <accountId>.png，skin- 前缀互不冲突；
///   与账户 json 同容器共存亡，file:// URL 不会出现跨容器失效）。
static NSString *ame133_skinAvatarPath(NSString *accountId) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSString *dir = [docs stringByAppendingPathComponent:@"avatars"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    NSString *key = [accountId isKindOfClass:NSString.class] && accountId.length > 0
        ? accountId : @"unknown";
    return [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"skin-%@.png", key]];
}

/// Task 133：下载真实皮肤 PNG 并本地渲染头像（在后台线程回调）。
/// 成功返回 file:// URL 字符串，失败返回 nil（调用方走 helm/mc-heads 兜底）。
/// 注意：skinURL 是 profile 响应里的一次性签名 URL，必须立即下载——
/// 不能把 URL 存下来延迟使用（LittleSkin 实测过期即 404）。
static void ame133_downloadAndCacheAvatar(NSString *skinURL,
                                          NSString *accountId,
                                          NSString *username,
                                          void (^completion)(NSString *picURL)) {
    NSURL *url = [NSURL URLWithString:skinURL];
    if (url == nil || completion == NULL) {
        if (completion) completion(nil);
        return;
    }
    [[[NSURLSession sharedSession] dataTaskWithURL:url
                                  completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSString *result = nil;
        if (data != nil && error == nil) {
            UIImage *skin = [UIImage imageWithData:data];
            UIImage *avatar = ame133_renderAvatarFromSkin(skin);
            if (avatar != nil) {
                NSData *png = UIImagePNGRepresentation(avatar);
                NSString *path = ame133_skinAvatarPath(accountId);
                if (png != nil && [png writeToFile:path atomically:YES]) {
                    result = [NSURL fileURLWithPath:path].absoluteString;
                    NSLog(@"[ThirdPartyAuthenticator] Task133: skin avatar rendered locally for %@ -> %@",
                          username ?: @"(null)", path);
                }
            }
        }
        if (result == nil) {
            NSLog(@"[ThirdPartyAuthenticator] Task133: local avatar render failed for %@ "
                  @"(skinURL download/decode), falling back to helm/mc-heads",
                  username ?: @"(null)");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result);
        });
    }] resume];
}


// ---------------------------------------------------------------------------
// Task 131：第三方登录凭据的 Keychain 存取（免密切换角色的根基）
//
// 背景（1d4082f 装机日志 latestlog.old.txt + Blessing Skin 服务端源码取证）：
//   用户在账号卡片上切换角色（switchToProfile HuaJicow_kqm8f13）被服务器
//   拒绝，报"访问令牌已经分配了角色"。Blessing Skin（littleskin.cn 及全部
//   BS 系皮肤站）的 refresh 语义（bs-community/yggdrasil-api AuthController）：
//   token 一旦绑定 profileId，任何带 selectedProfile 的 refresh 都抛
//   ForbiddenOperationException——【无密码切换在已绑定 token 上不可能】。
//   唯一路径：重新 /authenticate（邮箱+密码）拿全新未绑定 token，再
//   refresh+selectedProfile 绑定新角色。FCL 参照实现同理（YggdrasilAccount
//   构造时保留密码；其"多角色"= 登录时 CharacterSelector 选择，无运行期
//   无密码换绑）。
//
// 凭据存放：iOS Keychain（kSecClassGenericPassword）——系统加密保管，不落
// 明文文件（BaseAuthenticator saveChanges 刻意剥离 input/password 的既有
// 安全纪律不变）。键 = authserver + "|" + 登录标识（邮箱/用户名）。账户
// json 新增 loginIdentifier 字段（登录标识持久化，供切换时反查 Keychain）。
// 注意 authData[@"username"] 是【角色名】不是登录标识，故必须单存。
// ---------------------------------------------------------------------------

/// Keychain 服务的稳定标识（Bundle identifier 在重签名安装间可能变化，不用它）
static NSString *const ame131_keychainService = @"com.air-devs.air.ame131.credentials";

/// Task217（包名迁移配套）：历史 Keychain 服务名回退链。keychain-access-groups
/// 授权为 $(TEAMID).* 通配——同签名链下旧服务名里的凭据仍然可读。包名在
/// 本仓库历史上的多次变更（com.air-devs.air → com.air-devs.prisma →
/// com.prisma-devs.prisma → com.air-devs → Task218 起临时 com.air-devs.air
/// （上游同款包名 = 上游用户原地更新通道），终态 com.prisma-devs）
/// 每次都会换服务名；查不到新服务时按链回退读取，读到后回写到新服务名
/// （自迁移，用户无感）。
static NSArray<NSString *> *ame217_legacyKeychainServices(void) {
    static NSArray<NSString *> *ame217_chain = nil;
    static dispatch_once_t ame217_once;
    dispatch_once(&ame217_once, ^{
        ame217_chain = @[
            @"com.prisma-devs.prisma.ame131.credentials",   // Task216-217 代
            @"com.air-devs.ame131.credentials",             // Task217 过渡代（本轮身份）
            @"com.air-devs.prisma.ame131.credentials",      // Task213 前后代
            @"com.air-devs.air.ame131.credentials"          // 上游同源代（本轮主键）
        ];
    });
    return ame217_chain;
}

static NSString *ame131_credentialKey(NSString *authserver, NSString *loginIdentifier) {
    NSString *server = authserver ?: @"";
    if (![server hasSuffix:@"/"]) server = [server stringByAppendingString:@"/"];
    return [NSString stringWithFormat:@"%@|%@", server, loginIdentifier ?: @""];
}

static void ame131_storeCredentials(NSString *authserver, NSString *loginIdentifier, NSString *password) {
    if (loginIdentifier.length == 0 || password.length == 0) return;
    NSString *key = ame131_credentialKey(authserver, loginIdentifier);
    NSData *value = [password dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: ame131_keychainService,
                            (__bridge id)kSecAttrAccount: key};
    NSDictionary *attrs = @{(__bridge id)kSecValueData: value,
                            (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock};
    // ARC：CF 接口必须显式 __bridge（CI run 35498188445 教训：
    // SecItemUpdate 直传 NSDictionary = "incompatible pointer types
    // passing retainable parameter"）
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = [query mutableCopy];
        [add addEntriesFromDictionary:attrs];
        st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
    if (st != errSecSuccess) {
        NSLog(@"[ThirdPartyAuthenticator] Task131: keychain store failed (OSStatus %d)", (int)st);
    }
}

static NSString *ame131_readCredentials(NSString *authserver, NSString *loginIdentifier) {
    if (loginIdentifier.length == 0) return nil;
    NSString *account = ame131_credentialKey(authserver, loginIdentifier);
    NSDictionary *query = @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                            (__bridge id)kSecAttrService: ame131_keychainService,
                            (__bridge id)kSecAttrAccount: account,
                            (__bridge id)kSecReturnData: @YES,
                            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne};
    // CF_RETURNS_RETAINED 出参类型是 CFTypeRef*（CFDataRef* 直传 = CI 错误 3）
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &out) != errSecSuccess || !out) {
        // Task217：新服务名未命中 → 历史服务名回退链（包名迁移期间凭据
        // 仍活在旧服务名下；读到后回写新服务名完成自迁移）。
        for (NSString *legacy in ame217_legacyKeychainServices()) {
            NSMutableDictionary *legacyQuery = [query mutableCopy];
            legacyQuery[(__bridge id)kSecAttrService] = legacy;
            CFTypeRef legacyOut = NULL;
            if (SecItemCopyMatching((__bridge CFDictionaryRef)legacyQuery, &legacyOut) == errSecSuccess && legacyOut) {
                NSString *legacyPw = [[NSString alloc] initWithData:(__bridge_transfer NSData *)legacyOut
                                                          encoding:NSUTF8StringEncoding];
                if (legacyPw.length > 0) {
                    NSLog(@"[ThirdPartyAuthenticator] Task217: credential found under legacy service %@ -- re-storing under current service", legacy);
                    ame131_storeCredentials(authserver, loginIdentifier, legacyPw);
                    return legacyPw;
                }
            }
        }
        return nil;
    }
    NSString *pw = [[NSString alloc] initWithData:(__bridge_transfer NSData *)out encoding:NSUTF8StringEncoding];
    return pw.length > 0 ? pw : nil;
}

@implementation ThirdPartyAuthenticator

// Task 133：存量账户头像自愈——加载时发现 profilePicURL 不是 file:// 形态
// （旧构建写入的失效 helm/mc-heads URL），后台重取一次。修复上线后用户
// 无需重新登录即可看到真实皮肤头像；此后皮肤站换肤也在下次启动同步。
// 自终止：成功路径写入 file:// URL，下次加载不再触发；失败路径每次加载
// 至多一次后台请求（AFNetworking 异步，不阻塞 UI）。内存防抖集合避免
// 同一 accountId 在列表重载时并发重复请求。
- (id)initWithData:(NSMutableDictionary *)data {
    self = [super initWithData:data];
    if (self) {
        NSString *ame133_pic = data[@"profilePicURL"];
        NSString *ame133_aid = data[@"accountId"];
        // 自愈条件：有 accountId 且头像 URL 不是本地 file:// 形态
        // （覆盖：旧构建写入的失效 helm/mc-heads URL + 更早期无该字段的账户）
        BOOL ame133_stale = ![ame133_pic isKindOfClass:NSString.class] ||
                            ![ame133_pic hasPrefix:@"file://"];
        if (ame133_aid.length > 0 && ame133_stale) {
            static NSMutableSet *ame133_inflight;
            static dispatch_once_t ame133_once;
            dispatch_once(&ame133_once, ^{
                ame133_inflight = [NSMutableSet set];
            });
            if (![ame133_inflight containsObject:ame133_aid]) {
                @synchronized (ame133_inflight) {
                    if (![ame133_inflight containsObject:ame133_aid]) {
                        [ame133_inflight addObject:ame133_aid];
                        NSLog(@"[ThirdPartyAuthenticator] Task133: stale avatar URL for %@, refetching in background", ame133_aid);
                        __weak typeof(self) weakSelf = self;
                        [self fetchProfileTextureWithCallback:^(NSError *ame133_err, BOOL ame133_ok) {
                            @synchronized (ame133_inflight) {
                                [ame133_inflight removeObject:ame133_aid];
                            }
                            (void)weakSelf; (void)ame133_err; (void)ame133_ok;
                        }];
                    }
                }
            }
        }
    }
    return self;
}

+ (void)resolveAuthserverURL:(NSString *)inputURL
                  completion:(void (^)(NSString *resolvedURL, NSString *_Nullable metadata))completion {
    if (inputURL.length == 0) {
        if (completion) completion(inputURL, nil);
        return;
    }

    // 1. 缺协议时补 HTTPS（规范要求不允许降级到 HTTP）
    NSString *urlStr = inputURL;
    if (![urlStr hasPrefix:@"http://"] && ![urlStr hasPrefix:@"https://"]) {
        urlStr = [@"https://" stringByAppendingString:urlStr];
    }

    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url || !url.scheme || !url.host) {
        // URL 非法，回退返回原始输入
        if (completion) completion(inputURL, nil);
        return;
    }

    // 2. GET 请求该 URL，检查 X-Authlib-Injector-API-Location 响应头
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 30;
    // 允许跟随重定向（GitHub releases 等 302 跳转）
    config.HTTPShouldUsePipelining = YES;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    // 不缓存，避免 ALI 头被缓存层吞掉
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    __block NSString *resolvedURL = urlStr;
    __block NSString *metadata = nil;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[ThirdPartyAuthenticator] ALI resolution failed: %@", error.localizedDescription);
                // 解析失败回退到原始 URL，登录仍可尝试
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(inputURL, nil);
                });
                return;
            }

            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            if ([httpResponse isKindOfClass:[NSHTTPURLResponse class]]) {
                // 3. 检查 ALI 头
                NSString *ali = httpResponse.allHeaderFields[@"X-Authlib-Injector-API-Location"];
                if (ali.length > 0) {
                    // 解析 ALI 为绝对 URL
                    NSURL *aliURL = [NSURL URLWithString:ali relativeToURL:httpResponse.URL];
                    if (aliURL) {
                        // 如果 ALI 不指向自身，更新 resolvedURL
                        NSString *aliStr = aliURL.absoluteString;
                        if (![aliStr isEqualToString:httpResponse.URL.absoluteString]) {
                            NSLog(@"[ThirdPartyAuthenticator] ALI redirect: %@ -> %@", urlStr, aliStr);
                            resolvedURL = aliStr;
                            // ALI 指向新地址，需要重新请求获取元数据
                            [self fetchMetadataFromURL:aliURL completion:completion originalInput:inputURL];
                            return;
                        }
                    }
                }
            }

            // 4. 无 ALI 头或 ALI 指向自身：当前 URL 即为 API Root，复用响应体作为元数据
            if (data.length > 0) {
                metadata = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                // 校验是否为合法 JSON（元数据必须是 JSON）
                if (metadata) {
                    NSData *check = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:kNilOptions
                                                                     error:nil] ? data : nil;
                    if (!check) {
                        NSLog(@"[ThirdPartyAuthenticator] Response body is not valid JSON, discarding metadata");
                        metadata = nil;
                    }
                }
            }

            // 规范化：确保末尾带斜杠（与 buildAuthURLForServer 的处理一致）
            if (![resolvedURL hasSuffix:@"/"]) {
                resolvedURL = [resolvedURL stringByAppendingString:@"/"];
            }

            NSLog(@"[ThirdPartyAuthenticator] ALI resolution complete: %@ (metadata=%@)", resolvedURL, metadata ? @"YES" : @"NO");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(resolvedURL, metadata);
            });
        }];
    [task resume];
}

/// 辅助方法：从指定 URL 获取服务器元数据（ALI 重定向后的二次请求）
+ (void)fetchMetadataFromURL:(NSURL *)url
                  completion:(void (^)(NSString *, NSString *_Nullable))completion
               originalInput:(NSString *)originalInput {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSString *resolvedURL = url.absoluteString;
            NSString *metadata = nil;

            if (error) {
                NSLog(@"[ThirdPartyAuthenticator] Metadata secondary request failed: %@", error.localizedDescription);
            } else if (data.length > 0) {
                metadata = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                // 校验 JSON 合法性
                if (![NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil]) {
                    NSLog(@"[ThirdPartyAuthenticator] Secondary response body is not valid JSON, discarding metadata");
                    metadata = nil;
                }
            }

            if (![resolvedURL hasSuffix:@"/"]) {
                resolvedURL = [resolvedURL stringByAppendingString:@"/"];
            }

            NSLog(@"[ThirdPartyAuthenticator] Metadata secondary request complete: %@ (metadata=%@)", resolvedURL, metadata ? @"YES" : @"NO");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(resolvedURL, metadata);
            });
        }];
    [task resume];
}

- (NSString *)getAuthlibInjectorPath {
    NSString *path = [NSString stringWithFormat:@"%s/authlib-injector/%@", getenv("POJAV_HOME"), AUTHLIB_INJECTOR_FILE];
    return path;
}

// Task 128（zl2 同款思路）：随包内置的 authlib-injector 兜底路径。
// 旧实现把 jar 的在线下载作为登录前置（ensureAuthlibInjectorWithCompletion
// 是 loginWithCallback 第一步），下载失败 = 第三方登录完全不可用。
// 现在应用包内常备同版本 jar（Natives/resources/authlib-injector-1.2.8.jar，
// 由 payload 随包拷入），POJAV_HOME 侧缺文件/版本不匹配时直接从包内复制
// （本地操作，零网络依赖），在线下载仅作为包内文件缺失的最后回退。
- (NSString *)bundledAuthlibInjectorPath {
    return [NSBundle.mainBundle pathForResource:@"authlib-injector-" AUTHLIB_INJECTOR_VERSION
                                         ofType:@"jar"];
}

- (NSString *)getAuthlibInjectorVersionPath {
    NSString *path = [NSString stringWithFormat:@"%s/authlib-injector/%@", getenv("POJAV_HOME"), AUTHLIB_INJECTOR_VERSION_FILE];
    return path;
}

- (BOOL)isAuthlibInjectorDownloaded {
    NSString *path = [self getAuthlibInjectorPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return NO;
    }
    // 版本检查：已下载的 jar 版本必须与当前期望版本一致
    // 修复：旧版 1.2.7 jar 在 MC 26.3+ 新 authlib discovery 链路上不生效
    // （第三方皮肤不加载，Task132 根因），必须升级到 1.2.8
    NSString *versionPath = [self getAuthlibInjectorVersionPath];
    NSString *downloadedVersion = [NSString stringWithContentsOfFile:versionPath encoding:NSUTF8StringEncoding error:nil];
    if (downloadedVersion.length == 0 || ![downloadedVersion isEqualToString:AUTHLIB_INJECTOR_VERSION]) {
        NSLog(@"[ThirdPartyAuthenticator] authlib-injector version outdated (current: %@, required: %@), needs re-download",
              downloadedVersion.length > 0 ? downloadedVersion : @"unknown", AUTHLIB_INJECTOR_VERSION);
        return NO;
    }
    return YES;
}

/// 下载成功后保存版本标记
- (void)saveAuthlibInjectorVersion {
    NSString *versionPath = [self getAuthlibInjectorVersionPath];
    [AUTHLIB_INJECTOR_VERSION writeToFile:versionPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)downloadAuthlibInjector:(void (^)(BOOL success, NSError *error))completion {
    [self downloadAuthlibInjectorFromURL:AUTHLIB_INJECTOR_URL_BMCL attempt:1 completion:completion];
}

/// 逐个尝试下载源：BMCLAPI 失败后回退到 GitHub 官方源
- (void)downloadAuthlibInjectorFromURL:(NSString *)urlString
                               attempt:(NSInteger)attempt
                            completion:(void (^)(BOOL success, NSError *error))completion {
    NSString *dirPath = [NSString stringWithFormat:@"%s/authlib-injector", getenv("POJAV_HOME")];
    NSString *filePath = [self getAuthlibInjectorPath];

    // Create directory if it doesn't exist
    NSError *dirError;
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) {
        completion(NO, dirError);
        return;
    }

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 120;
    AFURLSessionManager *manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];

    NSURL *URL = [NSURL URLWithString:urlString];
    // 使用 NSMutableURLRequest 以允许重定向跟随（GitHub releases 会 302 跳转）
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:URL];
    request.HTTPShouldUsePipelining = YES;

    NSLog(@"[ThirdPartyAuthenticator] Attempting to download authlib-injector (source %ld): %@", (long)attempt, urlString);

    NSURLSessionDownloadTask *downloadTask = [manager downloadTaskWithRequest:request progress:nil destination:^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        return [NSURL fileURLWithPath:filePath];
    } completionHandler:^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        if (error) {
            NSLog(@"[ThirdPartyAuthenticator] Download failed (source %ld): %@", (long)attempt, error.localizedDescription);
            // BMCLAPI 失败后尝试 GitHub 官方源
            if (attempt == 1) {
                [self downloadAuthlibInjectorFromURL:AUTHLIB_INJECTOR_URL_GITHUB attempt:2 completion:completion];
            } else {
                completion(NO, error);
            }
        } else {
            NSLog(@"[ThirdPartyAuthenticator] Download succeeded (source %ld)", (long)attempt);
            // 保存版本标记，用于后续版本检查
            [self saveAuthlibInjectorVersion];
            completion(YES, nil);
        }
    }];
    [downloadTask resume];
}

- (void)ensureAuthlibInjectorWithCompletion:(void (^)(BOOL success, NSError *error))completion {
    if ([self isAuthlibInjectorDownloaded]) {
        completion(YES, nil);
        return;
    }
    // Task 128（zl2 同款思路）：优先从应用包内复制（本地、即时、零网络依赖）。
    // 旧实现把 jar 的在线下载作为登录前置——下载失败 = 第三方登录完全不可用。
    // 包内常备同版本 jar（Natives/resources/authlib-injector-1.2.8.jar，
    // payload 随包拷入）；在线下载仅作为包内文件缺失的最后回退。
    NSString *ame128_bundled = [self bundledAuthlibInjectorPath];
    if (ame128_bundled.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:ame128_bundled]) {
        NSString *ame128_dir = [NSString stringWithFormat:@"%s/authlib-injector", getenv("POJAV_HOME")];
        NSString *ame128_dest = [self getAuthlibInjectorPath];
        NSError *ame128_copyErr = nil;
        [NSFileManager.defaultManager createDirectoryAtPath:ame128_dir
                                withIntermediateDirectories:YES attributes:nil error:nil];
        // 目标已存在（版本不匹配的旧 jar）时先移除再复制
        if ([NSFileManager.defaultManager fileExistsAtPath:ame128_dest]) {
            [NSFileManager.defaultManager removeItemAtPath:ame128_dest error:nil];
        }
        if ([NSFileManager.defaultManager copyItemAtPath:ame128_bundled toPath:ame128_dest error:&ame128_copyErr]) {
            NSLog(@"[ThirdPartyAuthenticator] Task128: authlib-injector installed from bundled copy");
            [self saveAuthlibInjectorVersion];
            completion(YES, nil);
            return;
        }
        NSLog(@"[ThirdPartyAuthenticator] Task128: bundled copy failed (%@), falling back to network", ame128_copyErr.localizedDescription);
    }
    {
        NSLog(@"[ThirdPartyAuthenticator] Downloading authlib-injector (BMCLAPI preferred, falls back to GitHub)");
        [self downloadAuthlibInjector:^(BOOL success, NSError *error) {
            if (!success) {
                NSLog(@"[ThirdPartyAuthenticator] Failed to download authlib-injector: %@", error.localizedDescription);
                
                // Create a more informative error message
                NSString *errorMessage = [NSString stringWithFormat:@"Failed to download authlib-injector for third party authentication: %@", error.localizedDescription];
                NSError *customError = [NSError errorWithDomain:@"ThirdPartyAuthenticator" 
                                                          code:1001 
                                                      userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
                
                completion(NO, customError);
            } else {
                NSLog(@"[ThirdPartyAuthenticator] Successfully downloaded authlib-injector");
                completion(YES, nil);
            }
        }];
    }
}

// Method to get JVM arguments for authlib-injector
- (NSArray *)getJvmArgsForAuthlib {
    NSString *injectorPath = [self getAuthlibInjectorPath];

    // Check file existence（Task 128：POJAV_HOME 副本缺失时回退包内 jar——
    // 启动时 agent 永不因文件缺失而静默丢失，这正是 401 蜷缩链的断点之一）
    if (![[NSFileManager defaultManager] fileExistsAtPath:injectorPath]) {
        NSString *ame128_bundled = [self bundledAuthlibInjectorPath];
        if (ame128_bundled.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:ame128_bundled]) {
            injectorPath = ame128_bundled;
            NSLog(@"[ThirdPartyAuthenticator] Task128: using bundled authlib-injector at launch");
        } else {
            NSLog(@"[ThirdPartyAuthenticator] Warning: authlib-injector file not found at %@", injectorPath);
            return @[];
        }
    }

    // Get server URL from authData or use default Ely.by server
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";

    NSString *jvmArg = [NSString stringWithFormat:@"-javaagent:%@=%@", injectorPath, serverURL];

    NSMutableArray *args = [NSMutableArray arrayWithArray:@[jvmArg, @"-Dauthlibinjector.side=client"]];

    // 参照 HMCL AuthlibInjectorAuthInfo：传递 prefetched 元数据
    // 将服务器元数据 base64 编码后通过 -Dauthlibinjector.yggdrasil.prefetched 传入，
    // 避免游戏运行时再次请求服务器元数据，提升皮肤加载可靠性
    NSString *metadata = self.authData[@"prefetchedMetadata"];
    if (metadata.length > 0) {
        // 去除 JSON 多余空白（规范要求紧凑形式，减少参数长度）
        NSData *jsonData = [metadata dataUsingEncoding:NSUTF8StringEncoding];
        NSError *jsonError = nil;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:&jsonError];
        if (jsonObj && !jsonError) {
            NSData *compactData = [NSJSONSerialization dataWithJSONObject:jsonObj
                                                                  options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                                    error:nil];
            if (compactData) {
                NSString *compactStr = [[NSString alloc] initWithData:compactData encoding:NSUTF8StringEncoding];
                NSString *base64 = [[compactStr dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
                if (base64.length > 0) {
                    NSString *prefetchedArg = [NSString stringWithFormat:@"-Dauthlibinjector.yggdrasil.prefetched=%@", base64];
                    [args addObject:prefetchedArg];
                    NSLog(@"[ThirdPartyAuthenticator] Added prefetched metadata parameter (length=%lu)", (unsigned long)base64.length);
                }
            }
        } else {
            NSLog(@"[ThirdPartyAuthenticator] Prefetched metadata JSON parse failed, skipping parameter");
        }
    } else {
        // 登录时未缓存元数据，尝试现场获取（同步，可能阻塞，仅作兜底）
        NSLog(@"[ThirdPartyAuthenticator] No cached metadata, attempting on-the-fly fetch");
        [self fetchMetadataSynchronouslyForServerURL:serverURL];
        NSString *cachedMeta = self.authData[@"prefetchedMetadata"];
        if (cachedMeta.length > 0) {
            NSData *jsonData = [cachedMeta dataUsingEncoding:NSUTF8StringEncoding];
            id jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:kNilOptions error:nil];
            if (jsonObj) {
                NSData *compactData = [NSJSONSerialization dataWithJSONObject:jsonObj
                                                                      options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                                        error:nil];
                if (compactData) {
                    NSString *compactStr = [[NSString alloc] initWithData:compactData encoding:NSUTF8StringEncoding];
                    NSString *base64 = [[compactStr dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
                    if (base64.length > 0) {
                        NSString *prefetchedArg = [NSString stringWithFormat:@"-Dauthlibinjector.yggdrasil.prefetched=%@", base64];
                        [args addObject:prefetchedArg];
                        NSLog(@"[ThirdPartyAuthenticator] Added on-the-fly fetched prefetched metadata parameter");
                    }
                }
            }
        }
    }

    return args;
}

/// 同步获取服务器元数据并缓存到 authData（getJvmArgsForAuthlib 兜底用）
- (void)fetchMetadataSynchronouslyForServerURL:(NSString *)serverURL {
    if (serverURL.length == 0) return;
    NSString *urlStr = serverURL;
    if (![urlStr hasSuffix:@"/"]) {
        urlStr = [urlStr stringByAppendingString:@"/"];
    }
    // 元数据在 API Root 直接 GET 获取
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) return;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 10;

    NSError *requestError = nil;
    NSHTTPURLResponse *response = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:request
                                         returningResponse:&response
                                                     error:&requestError];
    if (requestError || !data || data.length == 0) {
        NSLog(@"[ThirdPartyAuthenticator] On-the-fly metadata fetch failed: %@", requestError.localizedDescription);
        return;
    }

    // 校验 JSON 合法性
    id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
    if (!jsonObj) {
        NSLog(@"[ThirdPartyAuthenticator] On-the-fly fetched metadata is not valid JSON");
        return;
    }

    // 检查 ALI 头，若指向其他地址则需二次请求
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSString *ali = response.allHeaderFields[@"X-Authlib-Injector-API-Location"];
        if (ali.length > 0) {
            NSURL *aliURL = [NSURL URLWithString:ali relativeToURL:response.URL];
            if (aliURL && ![aliURL.absoluteString isEqualToString:response.URL.absoluteString]) {
                // ALI 指向其他地址，二次请求
                NSMutableURLRequest *aliRequest = [NSMutableURLRequest requestWithURL:aliURL];
                aliRequest.HTTPMethod = @"GET";
                aliRequest.timeoutInterval = 10;
                NSError *aliError = nil;
                NSData *aliData = [NSURLConnection sendSynchronousRequest:aliRequest
                                                       returningResponse:nil
                                                                   error:&aliError];
                if (!aliError && aliData.length > 0) {
                    if ([NSJSONSerialization JSONObjectWithData:aliData options:kNilOptions error:nil]) {
                        self.authData[@"prefetchedMetadata"] = [[NSString alloc] initWithData:aliData encoding:NSUTF8StringEncoding];
                        return;
                    }
                }
                return;
            }
        }
    }

    self.authData[@"prefetchedMetadata"] = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSLog(@"[ThirdPartyAuthenticator] On-the-fly metadata fetch succeeded");
}

// Method to handle re-authentication with two-factor authentication
- (void)loginWithTwoFactorToken:(NSString *)token callback:(Callback)callback {
    NSString *username = self.authData[@"input"];
    NSString *password = self.authData[@"password"];
    
    if (username.length == 0 || password.length == 0) {
        NSError *error = createError(localize(@"login.error.fields.empty", nil), 1002);
        callback(error, NO);
        return;
    }
    
    // Add two-factor token to password
    NSString *passwordWithToken = [NSString stringWithFormat:@"%@:%@", password, token];
    
    NSDictionary *data = @{
        @"agent": @{@"name": @"Minecraft", @"version": @1},
        @"username": username,
        @"password": passwordWithToken,
        @"clientToken": [[NSUUID UUID] UUIDString],
        @"requestUser": @YES
    };
    
    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    
    [self sendAuthenticateRequest:data manager:manager callback:callback];
}

// Helper method to build authentication URL based on server
- (NSString *)buildAuthURLForServer:(NSString *)serverURL {
    // Ensure serverURL ends with a slash
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    
    // For Ely.by, use the old method
    if ([serverURL isEqualToString:@"https://authserver.ely.by/"]) {
        return [NSString stringWithFormat:@"%@auth/authenticate", serverURL];
    }
    // For other servers, use the standard Yggdrasil API method
    else {
        return [NSString stringWithFormat:@"%@authserver/authenticate", serverURL];
    }
}

// Helper method to build refresh URL based on server
- (NSString *)buildRefreshURLForServer:(NSString *)serverURL {
    // Ensure serverURL ends with a slash
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    
    // For Ely.by, use the old method
    if ([serverURL isEqualToString:@"https://authserver.ely.by/"]) {
        return [NSString stringWithFormat:@"%@auth/refresh", serverURL];
    }
    // For other servers, use the standard Yggdrasil API method
    else {
        return [NSString stringWithFormat:@"%@authserver/refresh", serverURL];
    }
}

// Helper method to send authentication request
/// 多角色场景：调用 refresh 把选定角色绑定到 token
/// 参照 HMCL YggdrasilService.refresh：请求体含 accessToken/clientToken/selectedProfile/requestUser
- (void)refreshToBindProfile:(NSDictionary *)profileToSelect
                  accessToken:(NSString *)accessToken
                  clientToken:(NSString *)clientToken
                     callback:(Callback)callback {
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    NSString *refreshURL = [self buildRefreshURLForServer:serverURL];

    NSDictionary *data = @{
        @"accessToken": accessToken,
        @"clientToken": clientToken,
        @"selectedProfile": @{
            @"id": profileToSelect[@"id"],
            @"name": profileToSelect[@"name"]
        },
        @"requestUser": @YES
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;

    NSLog(@"[ThirdPartyAuthenticator] Refresh bind profile request: %@", refreshURL);

    __weak typeof(self) weakSelf = self;
    [manager POST:refreshURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        @try {
            if (![response isKindOfClass:[NSDictionary class]] ||
                !response[@"accessToken"] || !response[@"clientToken"] ||
                !response[@"selectedProfile"]) {
                NSError *error = createError(localize(@"i18n_str_1106", nil), 1020);
                callback(error, NO);
                return;
            }

            NSDictionary *boundProfile = response[@"selectedProfile"];
            // 校验绑定的角色与请求选择的角色一致
            if (![boundProfile[@"id"] isEqualToString:profileToSelect[@"id"]]) {
                NSError *error = createError(localize(@"i18n_str_1107", nil), 1021);
                callback(error, NO);
                return;
            }

            weakSelf.authData[@"accessToken"] = response[@"accessToken"];
            weakSelf.authData[@"clientToken"] = response[@"clientToken"];
            weakSelf.authData[@"username"] = boundProfile[@"name"];
            weakSelf.authData[@"uuid"] = boundProfile[@"id"];
            weakSelf.authData[@"profileId"] = boundProfile[@"id"];

            // 格式化 UUID（补连字符）
            NSString *uuid = boundProfile[@"id"];
            if (uuid.length == 32) {
                weakSelf.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                    [uuid substringWithRange:NSMakeRange(0, 8)],
                    [uuid substringWithRange:NSMakeRange(8, 4)],
                    [uuid substringWithRange:NSMakeRange(12, 4)],
                    [uuid substringWithRange:NSMakeRange(16, 4)],
                    [uuid substringWithRange:NSMakeRange(20, 12)]
                ];
            }
            // 第三方账户用 profileId（角色 UUID）作为 accountId，使同名账户可共存
            weakSelf.authData[@"accountId"] = weakSelf.authData[@"profileId"];
            // Task 128 根因修复（多角色路径的键缺失）：refreshToBindProfile ->
            // fetchProfileTextureWithCallback 的所有保存分支此前既不设 expiresAt
            // 也不设 accountType，保存出的 json 在 loadSavedName 判别时落入
            // local 分支（expiresAt==0 优先）-> current 变成"带着第三方数据的
            // LocalAuthenticator" -> JavaLauncher 的 isKindOfClass 检查失败 ->
            // authlib-injector 不注入 -> 原版 authlib 拿 LittleSkin 令牌请求
            // Mojang -> 401 InvalidCredentialsException（"第三方登录完全使用
            // 不了"的准确根因；4288040bc 日志：登录全绿 + 启动无 agent 行 +
            // YggdrasilUserApiService 401 三证齐全）。两个键都在进入头像
            // 异步流程前设置，所有下游 saveChanges 一并继承。
            weakSelf.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
            weakSelf.authData[@"accountType"] = @"thirdparty";

            // 异步获取头像（与单角色路径一致）
            [weakSelf fetchProfileTextureWithCallback:callback];
        } @catch (NSException *exception) {
            NSError *error = createError([NSString stringWithFormat:localize(@"i18n_str_1108", nil), exception.reason], 1022);
            callback(error, NO);
        }
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSString *errMsg = [self parseErrorMessageFromError:error];
        NSError *callbackError = createError(errMsg ?: localize(@"i18n_str_1109", nil), 1023);
        callback(callbackError, NO);
    }];
}

// Task 129b（FCL 多角色管理）：为已保存的多角色账户切换绑定角色。
// profile 来自该账户 authData[@"availableProfiles"]（登录时由 Task129b 保存）。
// 链路：当前 accessToken + 新 selectedProfile 走 refreshToBindProfile（更新
// tokens/username/uuid/profileId/accountId/expiresAt/accountType + 头像 + saveChanges
// ——saveChanges 以新 accountId 落盘并迁移 selected_account），随后清理旧
// accountId 的账户文件（角色切换 = 文件换名，与登录路径同一语义）。
- (void)switchToProfile:(NSDictionary *)profile callback:(Callback)callback {
    if (![profile isKindOfClass:[NSDictionary class]] ||
        ![profile[@"id"] isKindOfClass:[NSString class]] ||
        ((NSString *)profile[@"id"]).length == 0) {
        NSError *error = createError(localize(@"login.error.invalid_response", @"Invalid profile"), 1031);
        callback(error, NO);
        return;
    }

    NSString *accessToken = self.authData[@"accessToken"];
    NSString *clientToken = self.authData[@"clientToken"];
    if (![accessToken isKindOfClass:[NSString class]] || accessToken.length == 0 ||
        ![clientToken isKindOfClass:[NSString class]] || clientToken.length == 0) {
        NSError *error = createError(localize(@"i18n_str_1106", nil), 1032);
        callback(error, NO);
        return;
    }

    // 切换前记录旧 accountId：成功后若 profileId 变化则删除旧文件
    NSString *ame129b_oldAccountId = self.authData[@"accountId"];
    NSLog(@"[ThirdPartyAuthenticator] Task129b: switchToProfile %@ (old accountId %@)",
          profile[@"name"], ame129b_oldAccountId);

    __weak typeof(self) weakSelf = self;
    [self refreshToBindProfile:profile
                    accessToken:accessToken
                   clientToken:clientToken
                      callback:^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            if (success) {
                NSString *newAccountId = weakSelf.authData[@"accountId"];
                if (ame129b_oldAccountId.length > 0 && newAccountId.length > 0 &&
                    ![ame129b_oldAccountId isEqualToString:newAccountId]) {
                    NSString *oldPath = [NSString stringWithFormat:@"%s/accounts/%@.json",
                                         getenv("POJAV_HOME"), ame129b_oldAccountId];
                    [NSFileManager.defaultManager removeItemAtPath:oldPath error:nil];
                    NSLog(@"[ThirdPartyAuthenticator] Task129b: removed old account file %@", ame129b_oldAccountId);
                }
                if (callback) callback(status, YES);
                return;
            }
            // Task 131：refresh 绑定被拒（Blessing Skin 系服务器对已绑定 token
            // 一律拒绝换绑——"访问令牌已经分配了角色"；也覆盖 token 过期等其它
            // 失败形态）。降级路径：用 Keychain 里的登录凭据重新 authenticate
            // 拿全新未绑定 token，再绑定目标角色（见 ame131_retrySwitch… 注释）。
            NSLog(@"[ThirdPartyAuthenticator] Task131: refresh-bind rejected (%@) -- falling back to re-authentication with secured credentials",
                  [status isKindOfClass:[NSError class]] ? ((NSError *)status).localizedDescription : @"unknown error");
            [weakSelf ame131_retrySwitchWithStoredCredentials:profile
                                                 oldAccountId:ame129b_oldAccountId
                                                      callback:callback];
        });
    }];
}

// Task 131：切换角色的重新认证回退（Blessing Skin 系服务器的唯一可行路径，
// 见文件头部注释）。流程：Keychain 读凭据 -> 原始 /authenticate（不触发
// onProfileSelection 选择器 UI、不动 authData）-> 全新未绑定 token ->
// refreshToBindProfile 绑定目标角色 -> 原有的 authData 更新/落盘/旧文件
// 清理全部复用。凭据缺失（本版本之前登录的老账户）-> 明确引导重登一次。
- (void)ame131_retrySwitchWithStoredCredentials:(NSDictionary *)profile
                                    oldAccountId:(NSString *)oldAccountId
                                         callback:(Callback)callback {
    NSString *login = self.authData[@"loginIdentifier"];
    if (![login isKindOfClass:[NSString class]] || login.length == 0) {
        login = self.authData[@"input"];
    }
    NSString *password = ame131_readCredentials(self.authData[@"authserver"], login);
    if (password == nil) {
        NSLog(@"[ThirdPartyAuthenticator] Task131: no secured credentials for this account -- one re-login is required to enable password-free switching");
        NSError *error = createError(localize(@"account.switch_role.relogin_required",
            @"This server does not allow switching profiles on the current access token. Please log in to this account once more; after that, switching becomes password-free."), 1033);
        callback(error, NO);
        return;
    }

    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    NSString *authURL = [self buildAuthURLForServer:serverURL];
    NSDictionary *data = @{
        @"agent": @{@"name": @"Minecraft", @"version": @1},
        @"username": login,
        @"password": password,
        @"clientToken": [[NSUUID UUID] UUIDString],
        @"requestUser": @YES
    };
    NSLog(@"[ThirdPartyAuthenticator] Task131: re-authenticating with secured credentials to obtain a fresh unbound token");

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;

    __weak typeof(self) weakSelf = self;
    [manager POST:authURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!weakSelf) return;
            if (![response isKindOfClass:[NSDictionary class]] ||
                ![response[@"accessToken"] isKindOfClass:[NSString class]] ||
                ![response[@"clientToken"] isKindOfClass:[NSString class]]) {
                NSError *error = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1034);
                callback(error, NO);
                return;
            }
            NSLog(@"[ThirdPartyAuthenticator] Task131: fresh token obtained, binding target profile via refresh");
            [weakSelf refreshToBindProfile:profile
                              accessToken:response[@"accessToken"]
                             clientToken:response[@"clientToken"]
                                callback:^(id status2, BOOL success2) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!weakSelf) return;
                    if (success2) {
                        NSString *newAccountId = weakSelf.authData[@"accountId"];
                        if (oldAccountId.length > 0 && newAccountId.length > 0 &&
                            ![oldAccountId isEqualToString:newAccountId]) {
                            NSString *oldPath = [NSString stringWithFormat:@"%s/accounts/%@.json",
                                                 getenv("POJAV_HOME"), oldAccountId];
                            [NSFileManager.defaultManager removeItemAtPath:oldPath error:nil];
                            NSLog(@"[ThirdPartyAuthenticator] Task129b: removed old account file %@", oldAccountId);
                        }
                        NSLog(@"[ThirdPartyAuthenticator] Task131: profile switch completed via re-authentication path");
                    }
                    if (callback) callback(status2, success2);
                });
            }];
        });
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSString *errMsg = [self parseErrorMessageFromError:error];
        NSLog(@"[ThirdPartyAuthenticator] Task131: re-authentication failed (%@)", errMsg);
        // 凭据重放失败 = 存储的密码已失效（服务器侧改密/2FA 变更），用既有键
        NSError *callbackError = createError(errMsg ?: localize(@"login.error.invalid_credentials", nil), 1035);
        callback(callbackError, NO);
    }];
}

/// 异步获取角色纹理并设置头像 URL，完成后触发 callback
- (void)fetchProfileTextureWithCallback:(Callback)callback {
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    // Task 133：Yggdrasil 规范要求无连字符 UUID（带连字符形态 LittleSkin 等
    // 严格服务器直接 404，此前一直回落 mc-heads → Steve——实测铁证）。
    NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, ame133_undashedProfileId(self.authData[@"profileId"])];

    __weak typeof(self) weakSelf = self;
    [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
            NSArray *properties = response[@"properties"];
            for (NSDictionary *property in properties) {
                if ([property[@"name"] isEqualToString:@"textures"]) {
                    NSString *textures = property[@"value"];
                    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                    if (decodedData) {
                        NSError *error = nil;
                        NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                        if (texturesDict && !error) {
                            NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                            if (skinURL) {
                                // Task 133：下载真实皮肤 PNG → 本地渲染头像（脸+帽层
                                // 8x8 裁剪放大）→ file:// URL。helm.png 换算对
                                // Blessing Skin 系一次性签名 URL 无效，仅作兑底。
                                ame133_downloadAndCacheAvatar(skinURL,
                                    weakSelf.authData[@"accountId"], weakSelf.authData[@"username"],
                                    ^(NSString *ame133_picURL) {
                                    if (ame133_picURL) {
                                        weakSelf.authData[@"profilePicURL"] = ame133_picURL;
                                    } else {
                                        weakSelf.authData[@"profilePicURL"] = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                    }
                                    [weakSelf saveChanges];
                                    if (callback) callback(nil, YES);
                                });
                                return;
                            }
                        }
                    }
                }
            }
        }
        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
        [weakSelf saveChanges];
        ame134_notifyAccountInfoUpdated();
        callback(nil, YES);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
        [weakSelf saveChanges];
        ame134_notifyAccountInfoUpdated();
        callback(nil, YES);
    }];
}

/// 从 AFNetworking 错误中解析 Yggdrasil 服务器返回的 errorMessage
- (NSString *)parseErrorMessageFromError:(NSError *)error {
    NSData *data = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
    if (data) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:nil];
        if (json) {
            NSString *msg = json[@"errorMessage"] ?: json[@"error"];
            if (msg.length > 0) return msg;
        }
    }
    return error.localizedDescription;
}

- (void)sendAuthenticateRequest:(NSDictionary *)data manager:(AFHTTPSessionManager *)manager callback:(Callback)callback {
    // Get server URL from authData or use default Ely.by server
    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
    // Ensure serverURL ends with a slash for consistency
    if (![serverURL hasSuffix:@"/"]) {
        serverURL = [serverURL stringByAppendingString:@"/"];
    }
    NSString *authURL = [self buildAuthURLForServer:serverURL];
    
    NSLog(@"[ThirdPartyAuthenticator] Sending authentication request to %@", authURL);
    
    [manager POST:authURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        @try {
            NSLog(@"[ThirdPartyAuthenticator] Authentication success response received");

            // Handle successful response
            if (![response isKindOfClass:[NSDictionary class]]) {
                NSError *error = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1003);
                callback(error, NO);
                return;
            }

            if (!response[@"accessToken"] || !response[@"clientToken"]) {
                NSError *error = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1004);
                callback(error, NO);
                return;
            }

            // Task 131：认证成功即把登录凭据存入 Keychain（后续免密切换角色的
            // 根基，见文件头部注释）。注意用 authData 里的【原始密码】——2FA
            // 路径的 data[@"password"] 是"密码:动态码"拼接版，存了也无法重放。
            // loginIdentifier 同时写入 authData（saveChanges 不剥离该键），
            // 供后续切换角色时反查 Keychain（authData[@"username"] 是角色名，
            // 不是登录标识）。
            {
                NSString *ame131_login = self.authData[@"input"] ?: data[@"username"];
                NSString *ame131_pass = self.authData[@"password"];
                if ([ame131_login isKindOfClass:[NSString class]] && ame131_login.length > 0 &&
                    [ame131_pass isKindOfClass:[NSString class]] && ame131_pass.length > 0) {
                    ame131_storeCredentials(self.authData[@"authserver"], ame131_login, ame131_pass);
                    self.authData[@"loginIdentifier"] = ame131_login;
                    NSLog(@"[ThirdPartyAuthenticator] Task131: credentials secured in keychain for %@ (enables password-free profile switching)", ame131_login);
                }
            }

            // Yggdrasil 规范：当用户有且仅有一个角色时返回 selectedProfile；
            // 有多个角色时只返回 availableProfiles；无角色时两者都缺失。
            // 参照 HMCL：多角色场景下需要调用 refresh 把选定角色绑定到 token，
            // 否则 token 处于"无 profile"状态，游戏 join server 会失败。
            NSDictionary *selectedProfile = response[@"selectedProfile"];
            NSArray *availableProfiles = response[@"availableProfiles"];
            if (![availableProfiles isKindOfClass:[NSArray class]]) {
                availableProfiles = @[];
            }

            // Task 129b（FCL 多角色管理）：登录时保存角色表到 authData，供
            // 账户列表后续"切换角色"使用（每项 {id, name}，plist 安全）。
            if (availableProfiles.count > 0) {
                NSMutableArray *ame129b_profiles = [NSMutableArray array];
                for (NSDictionary *p in availableProfiles) {
                    if (![p isKindOfClass:[NSDictionary class]]) continue;
                    NSString *pid = [p[@"id"] isKindOfClass:[NSString class]] ? p[@"id"] : nil;
                    NSString *pname = [p[@"name"] isKindOfClass:[NSString class]] ? p[@"name"] : @"";
                    if (pid.length == 0) continue;
                    [ame129b_profiles addObject:@{@"id": pid, @"name": pname}];
                }
                if (ame129b_profiles.count > 0) {
                    self.authData[@"availableProfiles"] = ame129b_profiles;
                }
            }

            if (!selectedProfile && availableProfiles.count > 1 && self.onProfileSelection) {
                // Task 129b（FCL 多角色）：多角色且 UI 层提供了选择器 -> 弹出角色
                // 选择（旧实现"移动端简化为选第一个"被用户实测否决：多角色管理
                // 去哪了）。用户取消（complete(nil)）-> 优雅终止登录。
                NSString *accessToken = response[@"accessToken"];
                NSString *clientToken = response[@"clientToken"];
                NSLog(@"[ThirdPartyAuthenticator] Task129b: multi-profile login (%ld profiles), asking user", (unsigned long)availableProfiles.count);
                __weak typeof(self) weakSelf = self;
                self.onProfileSelection(availableProfiles, ^(NSDictionary *chosen) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!weakSelf) return;
                        if (![chosen isKindOfClass:[NSDictionary class]] ||
                            ![chosen[@"id"] isKindOfClass:[NSString class]]) {
                            NSLog(@"[ThirdPartyAuthenticator] Task129b: profile selection cancelled by user");
                            NSError *error = createError(localize(@"login.error.cancelled", @"已取消"), 1030);
                            callback(error, NO);
                            return;
                        }
                        NSLog(@"[ThirdPartyAuthenticator] Task129b: user chose profile %@, refresh binding", chosen[@"name"]);
                        [weakSelf refreshToBindProfile:chosen
                                            accessToken:accessToken
                                           clientToken:clientToken
                                              callback:callback];
                    });
                });
                return;
            }

            if (!selectedProfile && availableProfiles.count > 0) {
                // 多角色但无 UI 选择器（后台/无 UI 场景）：保持旧行为，自动绑定第一个
                NSString *accessToken = response[@"accessToken"];
                NSString *clientToken = response[@"clientToken"];
                NSDictionary *profileToSelect = availableProfiles[0];
                NSLog(@"[ThirdPartyAuthenticator] Multi-profile scenario, refresh binding profile: %@", profileToSelect[@"name"]);
                [self refreshToBindProfile:profileToSelect
                                accessToken:accessToken
                                clientToken:clientToken
                                   callback:callback];
                return;
            }

            if (!selectedProfile) {
                // 有 token 但无任何角色：账户未创建游戏角色
                NSString *errMsg = localize(@"i18n_str_1110", nil);
                NSError *error = createError(errMsg, 1019);
                callback(error, NO);
                return;
            }

            self.authData[@"accessToken"] = response[@"accessToken"];
            self.authData[@"clientToken"] = response[@"clientToken"];
            self.authData[@"username"] = selectedProfile[@"name"];
            self.authData[@"uuid"] = selectedProfile[@"id"];
            self.authData[@"profileId"] = selectedProfile[@"id"];

            // Save information for authlib-injector
        self.authData[@"authserver"] = self.authData[@"authserver"] ?: @"https://authserver.ely.by";

            // Format UUID with hyphens
            NSString *uuid = selectedProfile[@"id"];
            if (uuid.length == 32) { // If UUID without hyphens
                self.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                    [uuid substringWithRange:NSMakeRange(0, 8)],
                    [uuid substringWithRange:NSMakeRange(8, 4)],
                    [uuid substringWithRange:NSMakeRange(12, 4)],
                    [uuid substringWithRange:NSMakeRange(16, 4)],
                    [uuid substringWithRange:NSMakeRange(20, 12)]
                ];
            }
            // 第三方账户用 profileId（角色 UUID）作为 accountId，使同名账户可共存
            self.authData[@"accountId"] = self.authData[@"profileId"];

            // 尝试使用Yggdrasil API获取头像
            NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
            // 确保serverURL以斜杠结尾
            if (![serverURL hasSuffix:@"/"]) {
                serverURL = [serverURL stringByAppendingString:@"/"];
            }

            AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
            manager.requestSerializer = AFJSONRequestSerializer.serializer;
            // Task 133：无连字符 profileId（见 fetchProfileTextureWithCallback 同款注释）
            NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, ame133_undashedProfileId(self.authData[@"profileId"])];
            
            // 保存当前的authData，以便在异步回调中使用
            __block NSMutableDictionary *localAuthData = [self.authData mutableCopy];
            __weak typeof(self) weakSelf = self;
            
            [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
                if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
                    NSArray *properties = response[@"properties"];
                    for (NSDictionary *property in properties) {
                        if ([property[@"name"] isEqualToString:@"textures"]) {
                            // 解析皮肤数据
                            NSString *textures = property[@"value"];
                            NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                            if (decodedData) {
                                NSError *error = nil;
                                NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                                if (texturesDict && !error) {
                                    // 获取皮肤URL
                                    NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                                    if (skinURL) {
                                        // Task 133：真实皮肤 PNG → 本地渲染头像 → file:// URL
                                        ame133_downloadAndCacheAvatar(skinURL,
                                            weakSelf.authData[@"accountId"], weakSelf.authData[@"username"],
                                            ^(NSString *ame133_picURL) {
                                            if (ame133_picURL) {
                                                weakSelf.authData[@"profilePicURL"] = ame133_picURL;
                                            } else {
                                                weakSelf.authData[@"profilePicURL"] = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                            }
                                            [weakSelf saveChanges];
                                        });
                                        return;
                                    }
                                }
                            }
                        }
                    }
                }

                // 如果Yggdrasil API失败，使用 mc-heads.net 头像服务作为回退
                weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                [weakSelf saveChanges];
                ame134_notifyAccountInfoUpdated();
            } failure:^(NSURLSessionDataTask *task, NSError *error) {
                // 如果请求失败，使用 mc-heads.net 头像服务作为回退
                weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                [weakSelf saveChanges];
                ame134_notifyAccountInfoUpdated();
            }];

            // 设置默认头像，避免UI显示问题（异步获取真实皮肤URL后会覆盖并再次保存）
            self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", self.authData[@"username"]];

            // Token expiration time (24 hours)
            self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
            // Task 128：显式账户类型标记（zl2 同款 AccountType 思路）。
            // 旧判别靠 expiresAt/clientToken 键位嗅探，三处判别器口径不一
            // （BaseAuthenticator / AccountList / Java 端各一套），易串类。
            self.authData[@"accountType"] = @"thirdparty";

            // Save changes
            callback(nil, [self saveChanges]);
        } @catch (NSException *exception) {
            NSLog(@"[ThirdPartyAuthenticator] Exception in login success: %@", exception);
            NSError *error = createError([NSString stringWithFormat:@"Error: %@", exception.reason], 1005);
            callback(error, NO);
        }
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSLog(@"[ThirdPartyAuthenticator] Authentication failed: %@", error);
        
        NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        NSHTTPURLResponse *response = error.userInfo[AFNetworkingOperationFailingURLResponseErrorKey];
        
        if (errorData) {
            @try {
                // Log error data for diagnostics
                NSString *rawErrorStr = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding];
                NSLog(@"[ThirdPartyAuthenticator] Raw error data: %@", rawErrorStr);
                
                NSDictionary *errorDict = [NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil];
                NSLog(@"[ThirdPartyAuthenticator] Error dictionary: %@", errorDict);
                
                // Check for two-factor authentication (status code 401 + specific error message)
                if (response.statusCode == 401 && 
                    [errorDict[@"error"] isEqualToString:@"ForbiddenOperationException"] &&
                    [errorDict[@"errorMessage"] isEqualToString:@"Account protected with two factor auth."]) {
                    
                    NSLog(@"[ThirdPartyAuthenticator] Two-factor authentication required");
                    
                    // Request TOTP code via UI
                    UIAlertController *alert = [UIAlertController 
                        alertControllerWithTitle:localize(@"login.3rdparty.2fa.title", @"Two-Factor Authentication")
                        message:localize(@"login.3rdparty.2fa.message", @"Please enter your two-factor authentication code")
                        preferredStyle:UIAlertControllerStyleAlert];
                    
                    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
                        textField.placeholder = localize(@"login.3rdparty.2fa.code", @"Authentication code");
                        textField.keyboardType = UIKeyboardTypeNumberPad;
                    }];
                    
                    UIAlertAction *okAction = [UIAlertAction 
                        actionWithTitle:localize(@"OK", @"OK") 
                        style:UIAlertActionStyleDefault 
                        handler:^(UIAlertAction *action) {
                            NSString *code = alert.textFields.firstObject.text;
                            if (code.length > 0) {
                                [self loginWithTwoFactorToken:code callback:callback];
                            } else {
                                NSError *codeError = createError(localize(@"login.3rdparty.2fa.empty", @"Authentication code cannot be empty"), 1006);
                                callback(codeError, NO);
                            }
                        }];
                    
                    UIAlertAction *cancelAction = [UIAlertAction 
                        actionWithTitle:localize(@"Cancel", @"Cancel") 
                        style:UIAlertActionStyleCancel 
                        handler:^(UIAlertAction *action) {
                            NSError *cancelError = createError(localize(@"login.cancelled", @"Login cancelled"), 1007);
                            callback(cancelError, NO);
                        }];
                    
                    [alert addAction:okAction];
                    [alert addAction:cancelAction];
                    
                    // Get ViewController to present alert
                    UIViewController *rootVC = nil;
                    UIWindow *keyWindow = [UIApplication sharedApplication].delegate.window;
                    if (!keyWindow) {
                        // Fallback for iOS 13+ scene-based apps
                        for (UIWindowScene *windowScene in [UIApplication sharedApplication].connectedScenes) {
                            if (windowScene.activationState == UISceneActivationStateForegroundActive) {
                                keyWindow = windowScene.windows.firstObject;
                                break;
                            }
                        }
                        // If no active scene, use the first available window
                        if (!keyWindow && [UIApplication sharedApplication].connectedScenes.count > 0) {
                            NSSet<UIScene *> *scenes = [UIApplication sharedApplication].connectedScenes;
                            if (scenes.count > 0) {
                                UIWindowScene *firstScene = (UIWindowScene *)[scenes anyObject];
                                if (firstScene.windows.count > 0) {
                                    keyWindow = firstScene.windows.firstObject;
                                }
                            }
                        }
                    }
                    if (keyWindow) {
                        rootVC = keyWindow.rootViewController;
                    }
                    
                    if (rootVC) {
                        [rootVC presentViewController:alert animated:YES completion:nil];
                    } else {
                        NSLog(@"[ThirdPartyAuthenticator] Error: Could not find root view controller to present 2FA alert");
                        NSError *viewError = createError(@"Internal error: Could not present 2FA dialog", 1008);
                        callback(viewError, NO);
                    }
                    return;
                } else if (response.statusCode == 401 && [errorDict[@"error"] isEqualToString:@"ForbiddenOperationException"]) {
                    // Check for specific error for invalid credentials
                    if ([errorDict[@"errorMessage"] isEqualToString:@"Invalid credentials. Invalid username or password."]) {
                        NSError *invalidCredentialsError = createError(localize(@"login.error.invalid_credentials", @"Invalid username or password"), 1020);
                        callback(invalidCredentialsError, NO);
                        return;
                    }
                }
                
                NSString *errorMessage = errorDict[@"errorMessage"] ?: error.localizedDescription;
                NSError *customError = createError(errorMessage, 1009);
                callback(customError, NO);
            } @catch (NSException *exception) {
                NSLog(@"[ThirdPartyAuthenticator] Exception while processing error: %@", exception);
                NSError *exceptionError = createError(error.localizedDescription, 1010);
                callback(exceptionError, NO);
            }
        } else {
            NSError *networkError = createError(error.localizedDescription, 1011);
            callback(networkError, NO);
        }
    }];
}

- (void)loginWithCallback:(Callback)callback {
    // First check/download authlib-injector
    [self ensureAuthlibInjectorWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            callback(error, NO);
            return;
        }
        
        // Continue authentication process
        callback(createError(localize(@"login.3rdparty.progress.auth", nil), 0), YES);
        
        NSString *username = self.authData[@"input"];
        NSString *password = self.authData[@"password"];
        
        if (username.length == 0 || password.length == 0) {
            NSError *fieldsError = createError(localize(@"login.error.fields.empty", nil), 1002);
            callback(fieldsError, NO);
            return;
        }
        
        NSDictionary *data = @{
            @"agent": @{@"name": @"Minecraft", @"version": @1},
            @"username": username,
            @"password": password,
            @"clientToken": [[NSUUID UUID] UUIDString],
            @"requestUser": @YES
        };
        
        AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
        manager.requestSerializer = AFJSONRequestSerializer.serializer;
        
        [self sendAuthenticateRequest:data manager:manager callback:callback];
    }];
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // First check/download authlib-injector
    [self ensureAuthlibInjectorWithCompletion:^(BOOL success, NSError *error) {
        if (!success) {
            callback(error, NO);
            return;
        }
        
        callback(createError(localize(@"login.3rdparty.progress.refresh", nil), 0), YES);
        
        NSString *accessToken = self.authData[@"accessToken"];
        NSString *clientToken = self.authData[@"clientToken"];
        
        if (accessToken.length == 0 || clientToken.length == 0) {
            NSError *tokenError = createError(localize(@"login.error.token_missing", @"Access token or client token is missing"), 1012);
            callback(tokenError, NO);
            return;
        }
        
        NSDictionary *data = @{
            @"accessToken": accessToken,
            @"clientToken": clientToken,
            @"requestUser": @YES
        };
        
        AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
        manager.requestSerializer = AFJSONRequestSerializer.serializer;
        
        NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
        // Ensure serverURL ends with a slash for consistency
        if (![serverURL hasSuffix:@"/"]) {
            serverURL = [serverURL stringByAppendingString:@"/"];
        }
        NSString *refreshURL = [self buildRefreshURLForServer:serverURL];
        
        [manager POST:refreshURL parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
            @try {
                // Update tokens
                if (![response isKindOfClass:[NSDictionary class]] || !response[@"accessToken"] || !response[@"clientToken"]) {
                    NSError *invalidError = createError(localize(@"login.error.invalid_response", @"Invalid server response"), 1013);
                    callback(invalidError, NO);
                    return;
                }
                
                self.authData[@"accessToken"] = response[@"accessToken"];
                self.authData[@"clientToken"] = response[@"clientToken"];
                
                // Update selectedProfile if present
                if (response[@"selectedProfile"]) {
                    self.authData[@"username"] = response[@"selectedProfile"][@"name"];
                    self.authData[@"uuid"] = response[@"selectedProfile"][@"id"];
                    
                    // Format UUID with hyphens if needed
                    NSString *uuid = response[@"selectedProfile"][@"id"];
                    if (uuid.length == 32) { // If UUID without hyphens
                        self.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                            [uuid substringWithRange:NSMakeRange(0, 8)],
                            [uuid substringWithRange:NSMakeRange(8, 4)],
                            [uuid substringWithRange:NSMakeRange(12, 4)],
                            [uuid substringWithRange:NSMakeRange(16, 4)],
                            [uuid substringWithRange:NSMakeRange(20, 12)]
                        ];
                    } else {
                        self.authData[@"profileId"] = uuid;
                    }
                    // 第三方账户用 profileId（角色 UUID）作为 accountId，使同名账户可共存
                    self.authData[@"accountId"] = self.authData[@"profileId"];

                    // 尝试使用Yggdrasil API获取头像
                    NSString *serverURL = self.authData[@"authserver"] ?: @"https://authserver.ely.by";
                    // 确保serverURL以斜杠结尾
                    if (![serverURL hasSuffix:@"/"]) {
                        serverURL = [serverURL stringByAppendingString:@"/"];
                    }
                    
                    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
                    manager.requestSerializer = AFJSONRequestSerializer.serializer;
                    // Task 133：无连字符 profileId（见 fetchProfileTextureWithCallback 同款注释）
                    NSString *profileURL = [NSString stringWithFormat:@"%@sessionserver/session/minecraft/profile/%@", serverURL, ame133_undashedProfileId(self.authData[@"profileId"])];
                    
                    // 保存当前的authData，以便在异步回调中使用
                    __block NSMutableDictionary *localAuthData = [self.authData mutableCopy];
                    __weak typeof(self) weakSelf = self;
                    
                    [manager GET:profileURL parameters:nil headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
                        if (response[@"properties"] && [response[@"properties"] isKindOfClass:[NSArray class]]) {
                            NSArray *properties = response[@"properties"];
                            for (NSDictionary *property in properties) {
                                if ([property[@"name"] isEqualToString:@"textures"]) {
                                    // 解析皮肤数据
                                    NSString *textures = property[@"value"];
                                    NSData *decodedData = [[NSData alloc] initWithBase64EncodedString:textures options:0];
                                    if (decodedData) {
                                        NSError *error = nil;
                                        NSDictionary *texturesDict = [NSJSONSerialization JSONObjectWithData:decodedData options:kNilOptions error:&error];
                                        if (texturesDict && !error) {
                                            // 获取皮肤URL
                                            NSString *skinURL = texturesDict[@"textures"][@"SKIN"][@"url"];
                                            if (skinURL) {
                                                // Task 133：真实皮肤 PNG → 本地渲染头像 → file:// URL
                                                ame133_downloadAndCacheAvatar(skinURL,
                                                    weakSelf.authData[@"accountId"], weakSelf.authData[@"username"],
                                                    ^(NSString *ame133_picURL) {
                                                    if (ame133_picURL) {
                                                        weakSelf.authData[@"profilePicURL"] = ame133_picURL;
                                                    } else {
                                                        weakSelf.authData[@"profilePicURL"] = [skinURL stringByReplacingOccurrencesOfString:@".png" withString:@"/helm.png"];
                                                    }
                                                    [weakSelf saveChanges];
                                                });
                                                return;
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // 如果Yggdrasil API失败，使用 mc-heads.net 头像服务作为回退
                        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                        [weakSelf saveChanges];
                        ame134_notifyAccountInfoUpdated();
                    } failure:^(NSURLSessionDataTask *task, NSError *error) {
                        // 如果请求失败，使用 mc-heads.net 头像服务作为回退
                        weakSelf.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", weakSelf.authData[@"username"]];
                        [weakSelf saveChanges];
                        ame134_notifyAccountInfoUpdated();
                    }];

                    // 设置默认头像，避免UI显示问题（异步获取真实皮肤URL后会覆盖并再次保存）
                    self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://mc-heads.net/avatar/%@/100", self.authData[@"username"]];
                }
                
                // Token expiration time (24 hours)
                self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
                // Task 128：显式账户类型标记（同上）
                self.authData[@"accountType"] = @"thirdparty";
                
                // Save changes
                callback(nil, [self saveChanges]);
            } @catch (NSException *exception) {
                NSLog(@"[ThirdPartyAuthenticator] Exception in refresh success: %@", exception);
                NSError *exceptionError = createError([NSString stringWithFormat:@"Error: %@", exception.reason], 1014);
                callback(exceptionError, NO);
            }
        } failure:^(NSURLSessionDataTask *task, NSError *error) {
            NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
            if (errorData) {
                @try {
                    NSDictionary *errorDict = [NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil];
                    
                    // Check for expired token error
                    if ([errorDict[@"error"] isEqualToString:@"ForbiddenOperationException"] && 
                        [errorDict[@"errorMessage"] isEqualToString:@"Token expired."]) {
                        NSError *expiredError = createError(localize(@"login.error.token_expired", @"Authentication token has expired, please log in again"), 1015);
                        callback(expiredError, NO);
                        return;
                    }
                    
                    NSString *errorMessage = errorDict[@"errorMessage"] ?: error.localizedDescription;
                    NSError *customError = createError(errorMessage, 1016);
                    callback(customError, NO);
                } @catch (NSException *exception) {
                    NSError *exceptionError = createError(error.localizedDescription, 1017);
                    callback(exceptionError, NO);
                }
            } else {
                NSError *networkError = createError(error.localizedDescription, 1018);
                callback(networkError, NO);
            }
        }];
    }];
}

@end