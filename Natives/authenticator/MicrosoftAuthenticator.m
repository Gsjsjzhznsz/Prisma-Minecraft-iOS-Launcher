#import "AFNetworking.h"
#import "BaseAuthenticator.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"
#include "jni.h"

typedef void(^XSTSCallback)(NSString *xsts, NSString *uhs);

@implementation MicrosoftAuthenticator

- (void)acquireAccessToken:(NSString *)authcode refresh:(BOOL)refresh callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireAccessToken", nil), YES);

    NSDictionary *data = @{
        @"client_id": @"00000000402b5328",
        (refresh ? @"refresh_token" : @"code"): authcode,
        @"grant_type": refresh ? @"refresh_token" : @"authorization_code",
        @"redirect_url": @"https://login.live.com/oauth20_desktop.srf",
        @"scope": @"service::user.auth.xboxlive.com::MBI_SSL"
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    [manager GET:@"https://login.live.com/oauth20_token.srf" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        self.authData[@"msaRefreshToken"] = response[@"refresh_token"];
        [self acquireXBLToken:response[@"access_token"] callback:callback];
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        // Task223 上游同步（upstream 3a2116c05 / Flux 同款）：无可用网络时
        // 刷新不了 token，但启动器有离线路径，直接走离线而不是拒绝启动。
        // 旧代码只认 NSURLErrorDataNotAllowed（应用被关蜂窝数据），飞行
        // 模式/无 Wi-Fi 的 NotConnectedToInternet 反而进失败分支。
        if (isConnectivityError(error)) {
            self.authData[@"accessToken"] = @"offline";
            callback(nil, YES);
        } else {
            callback(error, NO);
        }
    }];
}

- (void)acquireXBLToken:(NSString *)accessToken callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireXBLToken", nil), YES);

    NSDictionary *data = @{
        @"Properties": @{
            @"AuthMethod": @"RPS",
            @"SiteName": @"user.auth.xboxlive.com",
            @"RpsTicket": accessToken
        },
        @"RelyingParty": @"http://auth.xboxlive.com",
        @"TokenType": @"JWT"
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager POST:@"https://user.auth.xboxlive.com/user/authenticate" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        Callback innerCallback = ^(NSString* status, BOOL success) {
            if (!success) {
                callback(status, NO);
                return;
            } else if (status) {
                return;
            }
            // Obtain XSTS for authenticating to Minecraft
            [self acquireXSTSFor:@"rp://api.minecraftservices.com/" token:response[@"Token"] xstsCallback:^(NSString *xsts, NSString *uhs){
                if (xsts == nil) {
                    callback(nil, NO);
                    return;
                }
                self.authData[@"xuid"] = uhs;
                [self acquireMinecraftToken:uhs xstsToken:xsts callback:callback];
            } callback:callback];
        };

        // Obtain XSTS for getting the Xbox gamertag
        [self acquireXSTSFor:@"http://xboxlive.com" token:response[@"Token"] xstsCallback:^(NSString *xsts, NSString *uhs){
            if (xsts == nil) {
                callback(nil, NO);
                return;
            }
            [self acquireXboxProfile:uhs xstsToken:xsts callback:innerCallback];
        } callback:callback];
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        callback(error, NO);
    }];
}

- (void)acquireXSTSFor:(NSString *)replyingParty token:(NSString *)xblToken xstsCallback:(XSTSCallback)xstsCallback callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireXSTS", nil), YES);

    NSDictionary *data = @{
       @"Properties": @{
           @"SandboxId": @"RETAIL",
           @"UserTokens": @[
               xblToken
           ]
       },
       @"RelyingParty": replyingParty,
       @"TokenType": @"JWT",
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager POST:@"https://xsts.auth.xboxlive.com/xsts/authorize" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        NSString *uhs = response[@"DisplayClaims"][@"xui"][0][@"uhs"];
        xstsCallback(response[@"Token"], uhs);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSString *errorString;
        NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        if (errorData == nil) {
            callback(error, NO);
            return;
        }
        NSDictionary *errorDict = [NSJSONSerialization JSONObjectWithData:errorData options:kNilOptions error:nil];
        switch ((int)([errorDict[@"XErr"] longValue]-2148916230l)) {
            case 3:
                errorString = @"login.msa.error.xsts.noxboxacc";
                break;
            case 5:
                errorString = @"login.msa.error.xsts.noxbox";
                break;
            case 6:
            case 7:
                errorString = @"login.msa.error.xsts.krverify";
                break;
            case 8:
                errorString = @"login.msa.error.xsts.underage";
                break;
            default:
                errorString = [NSString stringWithFormat:@"%@\n\nUnknown XErr code, response:\n%@", error.localizedDescription, errorDict];
                break;
        }
        callback(localize(errorString, nil), NO);
    }];
}


- (void)acquireXboxProfile:(NSString *)xblUhs xstsToken:(NSString *)xblXsts callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireXboxProfile", nil), YES);

    NSDictionary *headers = @{
        @"x-xbl-contract-version": @"2",
        @"Authorization": [NSString stringWithFormat:@"XBL3.0 x=%@;%@", xblUhs, xblXsts]
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    [manager GET:@"https://profile.xboxlive.com/users/me/profile/settings?settings=PublicGamerpic,Gamertag" parameters:nil headers:headers progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"%@&h=120&w=120", response[@"profileUsers"][0][@"settings"][0][@"value"]];
        self.authData[@"xboxGamertag"] = response[@"profileUsers"][0][@"settings"][1][@"value"];
        callback(nil, YES);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        callback(error, NO);
    }];
}

- (void)acquireMinecraftToken:(NSString *)xblUhs xstsToken:(NSString *)xblXsts callback:(Callback)callback {
    callback(localize(@"login.msa.progress.acquireMCToken", nil), YES);

    NSDictionary *data = @{
        @"identityToken": [NSString stringWithFormat:@"XBL3.0 x=%@;%@", xblUhs, xblXsts]
    };

    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager POST:@"https://api.minecraftservices.com/authentication/login_with_xbox" parameters:data headers:nil progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        self.authData[@"accessToken"] = response[@"access_token"];
        [self checkMCProfile:response[@"access_token"] callback:callback];
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        callback(error, NO);
    }];
}

- (void)checkMCProfile:(NSString *)mcAccessToken callback:(Callback)callback {
    self.authData[@"expiresAt"] = @((long)[NSDate.date timeIntervalSince1970] + 86400);
    // Task 128：显式账户类型标记（防键位嗅探串类，见 BaseAuthenticator.loadSavedName）
    self.authData[@"accountType"] = @"microsoft";

    callback(localize(@"login.msa.progress.checkMCProfile", nil), YES);

    NSDictionary *headers = @{
        @"Authorization": [NSString stringWithFormat:@"Bearer %@", mcAccessToken]
    };
    AFHTTPSessionManager *manager = AFHTTPSessionManager.manager;
    manager.requestSerializer = AFJSONRequestSerializer.serializer;
    [manager GET:@"https://api.minecraftservices.com/minecraft/profile" parameters:nil headers:headers progress:nil success:^(NSURLSessionDataTask *task, NSDictionary *response) {
        NSString *uuid = response[@"id"];
        self.authData[@"profileId"] = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
            [uuid substringWithRange:NSMakeRange(0, 8)],
            [uuid substringWithRange:NSMakeRange(8, 4)],
            [uuid substringWithRange:NSMakeRange(12, 4)],
            [uuid substringWithRange:NSMakeRange(16, 4)],
            [uuid substringWithRange:NSMakeRange(20, 12)]
        ];
        // Task185：先落 username——旧顺序在首登时 username 尚为 nil，拼出的
        // 头像 URL 存成字面 "head/(null)"；之后刷新链若在 checkMCProfile
        // 之前断掉（如 keychain 丢失），坏 URL 永久留在 .json 里 =
        // “正版账号没有皮肤”的直接根源之一。
        self.authData[@"username"] = response[@"name"];
        // Task220：不再写 api.rms.net.cn 皮肤头镜像——该域名 DNS 已失效
        //（装机实测 "Task169 avatar fetch failed ... 未能找到使用指定主机名的
        // 服务器"，同会话连续 4 次），写进去等于给每个正版账号埋一个必死的
        // 头像主 URL。同链上一步 acquireXboxProfile 刚写入 Xbox 官方 gamerpic
        //（带 &h=120&w=120 尾参），保留即可；仅当现值为脏数据（"(null)"
        // /"(nil)" 子串）时删除该键，让展示层回退链（crafatar UUID /
        // minotar username）接管。
        NSString *ame220_pic = self.authData[@"profilePicURL"];
        if ([ame220_pic isKindOfClass:NSString.class] &&
            ([ame220_pic containsString:@"(null)"] || [ame220_pic containsString:@"(nil)"])) {
            [self.authData removeObjectForKey:@"profilePicURL"];
            NSLog(@"[Task220] checkMCProfile: dropped dirty profilePicURL (gamerpic retained / fallback chain takes over, user=%@)",
                  self.authData[@"username"]);
        }
        // 微软账户用 xuid 作为 accountId（全局唯一且稳定），使同名账户可共存
        self.authData[@"accountId"] = self.authData[@"xuid"];
        callback(nil, [self saveChanges]);
    } failure:^(NSURLSessionDataTask *task, NSError *error) {
        NSData *errorData = error.userInfo[AFNetworkingOperationFailingURLResponseDataErrorKey];
        NSDictionary *errorDict = [NSJSONSerialization JSONObjectWithData: errorData options:kNilOptions error:nil];
        if ([errorDict[@"error"] isEqualToString:@"NOT_FOUND"]) {
            // If there is no profile, use the Xbox gamertag as username with Demo mode
            self.authData[@"profileId"] = @"00000000-0000-0000-0000-000000000000";
            self.authData[@"username"] = [NSString stringWithFormat:@"Demo.%@", self.authData[@"xboxGamertag"]];
            // Demo 账户同样用 xuid 作为 accountId
            self.authData[@"accountId"] = self.authData[@"xuid"];

            if ([self saveChanges]) {
                callback(@"DEMO", YES);
                callback(nil, YES);
            } else {
                callback(nil, NO);
            }
            return;
        }

        callback(error, NO);
    }];
}

- (void)loginWithCallback:(Callback)callback {
    [self acquireAccessToken:self.authData[@"input"] refresh:NO callback:callback];
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Task185→Task220：历史脏数据（首登顺序 bug 存下的 "head/(null)" 头像
    // URL）双修。旧版只在内存里换成 api.rms.net.cn 镜像 URL，两个问题：
    //（a）该域名 DNS 已失效，换过去仍是死链（装机实测拉取必败）；（b）内存
    // 态修复不落盘，刷新链一旦因 keychain 丢失而走不完，坏值每次启动都从
    // .json 里满血复活（latestlog (2).txt 实锤：反复 "no clean profilePicURL"
    // + 回退链接管）。现在：直接删除脏键（展示层回退链 crafatar/minotar
    // 接管，下次成功重登时 acquireXboxProfile 会写入干净的 gamerpic），并把
    // 清理结果写回账号文件——绕过 saveChanges（那条路需要 accessToken 写
    // keychain，无令牌时会弹保存失败对话框）。
    {
        NSString *ame185_pic = self.authData[@"profilePicURL"];
        if ([ame185_pic isKindOfClass:NSString.class] &&
            ([ame185_pic containsString:@"(null)"] || [ame185_pic containsString:@"(nil)"])) {
            [self.authData removeObjectForKey:@"profilePicURL"];
            NSString *ame220_aid = self.authData[@"accountId"];
            if ([ame220_aid isKindOfClass:NSString.class] && ame220_aid.length > 0) {
                NSString *ame220_path = [NSString stringWithFormat:@"%s/accounts/%@.json",
                    getenv("POJAV_HOME"), ame220_aid];
                NSMutableDictionary *ame220_disk = parseJSONFromFile(ame220_path);
                if ([ame220_disk isKindOfClass:NSDictionary.class] &&
                    ame220_disk[@"profilePicURL"] != nil) {
                    [ame220_disk removeObjectForKey:@"profilePicURL"];
                    saveJSONToFile(ame220_disk, ame220_path);
                }
            }
            NSLog(@"[Task220] scrubbed dirty profilePicURL in memory + on disk (was: %@)", ame185_pic);
        }
    }
    if (!self.tokenData) {
        // Task185：会话内去重 + 可行动文案。旧版每次刷新链都弹一次（他人
        // 装机日志一场会话弹 5 次）；根因：keychain 条目带
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly——更换安装方式（换侧载
        // /TrollStore 重签）、换机迁移、恢复备份都会丢该条目；而账号 .json
        // 在容器里还在（列表有账号）→ token 已失但账号在列 = 必须重登才能
        // 恢复正版皮肤/多人。
        // Task187：文案指引升级为一键修复弹窗——「删除账号并重新登录」就地
        // 删账号（.json + keychain 残留）并拉起登录页，免去四步手动导航
        //（用户反馈"账号凭据已丢失…请删除该账号后重新登录"仍是一堵墙）。
        static BOOL ame185_shown = NO;
        if (!ame185_shown) {
            ame185_shown = YES;
            ame187_showAccountRepairDialog(self.authData[@"username"],
                                           self.authData[@"accountId"],
                                           self.authData[@"xuid"]);
        } else {
            NSLog(@"[Task185] keychain token still missing (dialog suppressed this session)");
        }
        callback(nil, YES);
        return;
    }

    if ([NSDate.date timeIntervalSince1970] > [self.authData[@"expiresAt"] longValue]) {
        [self acquireAccessToken:self.tokenData[@"refreshToken"] refresh:YES callback:callback];
    } else {
        callback(nil, YES);
    }
}

- (BOOL)saveChanges {
    BOOL savedToKeychain = [self setAccessToken:self.authData[@"accessToken"] refreshToken:self.authData[@"msaRefreshToken"]];
    if (!savedToKeychain) {
        showDialog(localize(@"Error", nil), @"Failed to save account tokens to keychain");
        return NO;
    }
    [self.authData removeObjectsForKeys:@[@"accessToken", @"msaRefreshToken"]];
    return [super saveChanges];
}

#pragma mark Keychain

+ (NSDictionary *)keychainQueryForKey:(NSString *)profile extraInfo:(NSDictionary *)extra {
    NSMutableDictionary *dict = @{
        (id)kSecClass: (id)kSecClassGenericPassword,
        (id)kSecAttrService: @"AccountToken",
        (id)kSecAttrAccount: profile,
    }.mutableCopy;
    if (extra) {
        [dict addEntriesFromDictionary:extra];
    }
    return dict;
}

+ (NSDictionary *)tokenDataOfProfile:(NSString *)profile {
    NSDictionary *dict = [MicrosoftAuthenticator keychainQueryForKey:profile extraInfo:@{
        (id)kSecMatchLimit: (id)kSecMatchLimitOne,
        (id)kSecReturnData: (id)kCFBooleanTrue
    }];
    CFTypeRef result = nil;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)dict, &result);
    if (status == errSecSuccess) {
        NSDictionary *ame185_tokens = [NSKeyedUnarchiver unarchivedObjectOfClass:NSDictionary.class fromData:(__bridge NSData *)result error:nil];
        if (!ame185_tokens) {
            // Task185：取证锚点——条目在但解档失败（数据损坏）
            NSLog(@"[Task185] keychain token read: SecItem OK but unarchive failed for profile %@", profile);
            // Task220：损坏条目自清——数据已不可用，留着只会让后续每次读取
            // 都走一遍“损坏”分支，状态含混（存在但读不出，重登前永远如此）。
            // 清掉后状态收敛为干净的“缺失”；重登（setAccessToken 的
            // delete+add）本就能覆盖写入，无副作用。
            SecItemDelete((__bridge CFDictionaryRef)[MicrosoftAuthenticator keychainQueryForKey:profile extraInfo:nil]);
            NSLog(@"[Task220] keychain corrupt entry self-cleared for profile %@", profile);
        }
        return ame185_tokens;
    }
    // Task185：状态码取证（errSecItemNotFound=-25300 常见于重签/换机/恢复
    // 备份后 ThisDeviceOnly 条目丢失；-25308=设备锁定期读取被拒）。旧版
    // 无差别返回 nil，丢失原因无从分辨。
    NSLog(@"[Task185] keychain token read failed for profile %@: OSStatus %d", profile, (int)status);
    return nil;
}

+ (void)clearTokenDataOfProfile:(NSString *)profile {
    NSDictionary *dict = [MicrosoftAuthenticator keychainQueryForKey:profile extraInfo:nil];
    SecItemDelete((__bridge CFDictionaryRef)dict);
}

- (BOOL)setAccessToken:(NSString *)accessToken refreshToken:(NSString *)refreshToken {
    if (!accessToken || !refreshToken) {
        NSDebugLog(@"[MicrosoftAuthenticator] BUG: nil accessToken:%d, refreshToken:%d", !accessToken, !refreshToken);
        return NO;
    }
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:@{
        @"accessToken": accessToken,
        @"refreshToken": refreshToken,
    } requiringSecureCoding:YES error:nil];
    NSDictionary *dict = [MicrosoftAuthenticator keychainQueryForKey:self.authData[@"xuid"] extraInfo:@{
        (id)kSecAttrAccessible: (id)kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        (id)kSecValueData: data
    }];
    SecItemDelete((__bridge CFDictionaryRef)dict);
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)dict, NULL);
    return status == errSecSuccess;
}

- (NSDictionary *)tokenData {
    return [MicrosoftAuthenticator tokenDataOfProfile:self.authData[@"xuid"]];
}

@end
