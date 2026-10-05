#import <Security/Security.h>
#import "BaseAuthenticator.h"
#import "ThirdPartyAuthenticator.h"
#import "../LauncherPreferences.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"
#import "../AvatarManager.h"

// Task180：复制 bug 双保险①——记录当前实例上一次已成功落盘的 accountId。
// refresh 链（选择账号必经）会改写 accountId（3P=profileId/微软=xuid），
// 而 saveChanges 只写新文件不删旧文件 → 旧账号 .json 残留 → 列表重复
//（用户实测"多次选择并报错后会复制"）。同仓库两处改 ID 流程（loadSaved-
// Name 迁移 / ThirdParty switchToProfile）都配了对删除，唯独 refresh 链
// 漏配——本属性使 saveChanges 能感知漂移并在写盘成功后统一迁移头像 +
// 清理旧文件（write-side cleanup；读侧去重在 AccountListViewController
// reloadAccountList，双保险②）。
@interface BaseAuthenticator ()
@property (nonatomic, copy, nullable) NSString *ame180_savedAccountId;
@end

@implementation BaseAuthenticator

static BaseAuthenticator *current = nil;

+ (id)current {
    if (current == nil) {
        // selected_account 现在存储的是 accountId（旧版存储 username，loadSavedName 会自动迁移）
        NSString *savedAccount = getPrefObject(@"internal.selected_account");
        if (savedAccount.length > 0) {
            [self loadSavedName:savedAccount];
        }
    }
    return current;
}

+ (void)setCurrent:(BaseAuthenticator *)auth {
    current = auth;
}

/// 根据账户数据生成唯一 accountId。
/// - 微软账户：使用 xuid（Xbox User Hash，全局唯一且稳定，登录后不变）
/// - 第三方账户：使用 profileId（角色 UUID，由认证服务器分配，唯一稳定）
/// - 本地账户：无天然唯一 ID，生成随机 UUID
/// 这样同名账户也能通过 accountId 区分，文件名不再冲突。
+ (NSString *)generateAccountIdForData:(NSMutableDictionary *)authData {
    // 微软账户：优先使用 xuid（XSTS 响应中的 uhs，全局唯一且稳定）
    NSString *xuid = authData[@"xuid"];
    if (xuid && [xuid length] > 0) {
        return xuid;
    }
    // 第三方账户：使用 profileId（角色 UUID，由认证服务器分配，唯一稳定）
    NSString *profileId = authData[@"profileId"];
    if (profileId && [profileId length] > 0 &&
        ![profileId isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
        return profileId;
    }
    // 本地账户：无天然唯一 ID，生成随机 UUID
    return [[NSUUID UUID] UUIDString];
}

+ (id)loadSavedName:(NSString *)accountId {
    // accountId 可能是新格式的 accountId，也可能是旧格式的 username（迁移场景）
    NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
    NSMutableDictionary *authData = parseJSONFromFile(path);
    if (authData[@"NSErrorObject"] != nil) {
        NSError *error = ((NSError *)authData[@"NSErrorObject"]);
        if (error.code != NSFileReadNoSuchFileError) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
        return nil;
    }

    // 根据账户数据创建对应类型的 authenticator（initWithData 会设置 current 单例）
    // Task 128：优先读显式 accountType 标记（zl2 的 AccountType 思路；登录时
    // 由各 authenticator 写入）。旧文件的键位嗅探保留为回退（expiresAt/clientToken），
    // 三处判别器（此处 / AccountList 的 clientToken 嗅探 / Java 端 clientToken+xuid）
    // 口径不一导致的串类自此统一。

    // Task220：混合文件防御性剥离 + 脏头像 URL 落盘自愈（先于类分发执行，
    // 让本方法返回的 authData 与磁盘文件都收敛到干净态）。
    // 病历（Oct-4 四份装机日志）：游戏以微软账号身份启动（authlib-injector
    // 自检 "Setting accountType to msa"）却带着 LittleSkin 的 authlib 注入、
    // 正版皮肤/联机全废——账号文件同时携带 xuid（微软）与 authserver/
    // clientToken（第三方）时，三处判别器各自取到不同的半边字段。现在以
    // 显式 accountType 为准，把对方阵营的键就地剥离并回写文件：
    //   microsoft  → 删 authserver / clientToken / prefetchedMetadata
    //   thirdparty → 删 xuid / xboxGamertag
    // 无 accountType 的旧文件不动（交给下次成功登录时的全量重写收编）。
    BOOL ame220_rewritten = NO;
    NSString *ame220_type = authData[@"accountType"];
    if ([ame220_type isKindOfClass:NSString.class]) {
        if ([ame220_type isEqualToString:@"microsoft"]) {
            for (NSString *ame220_k in @[@"authserver", @"clientToken", @"prefetchedMetadata"]) {
                if (authData[ame220_k] != nil) {
                    [authData removeObjectForKey:ame220_k];
                    ame220_rewritten = YES;
                }
            }
        } else if ([ame220_type isEqualToString:@"thirdparty"]) {
            for (NSString *ame220_k in @[@"xuid", @"xboxGamertag"]) {
                if (authData[ame220_k] != nil) {
                    [authData removeObjectForKey:ame220_k];
                    ame220_rewritten = YES;
                }
            }
        }
    }
    // 脏 profilePicURL（"(null)"/"(nil)" 子串——首登顺序 bug 的历史产物）：
    // 从文件里永久清除，展示层回退链（crafatar UUID / minotar username）
    // 接管。此前仅刷新链内存态修复（Task185），keychain 丢失、刷新走不完
    // 时脏值每次启动都原样复活（latestlog (2).txt 实锤）。
    NSString *ame220_pic = authData[@"profilePicURL"];
    if ([ame220_pic isKindOfClass:NSString.class] &&
        ([ame220_pic containsString:@"(null)"] || [ame220_pic containsString:@"(nil)"])) {
        [authData removeObjectForKey:@"profilePicURL"];
        ame220_rewritten = YES;
        NSLog(@"[Task220] loadSavedName: scrubbed dirty profilePicURL from %@.json", accountId);
    }
    if (ame220_rewritten) {
        saveJSONToFile(authData, path);
        NSLog(@"[Task220] loadSavedName: hybrid keys / dirty avatar scrubbed, file rewritten (%@.json)", accountId);
    }

    BaseAuthenticator *auth = nil;
    NSString *ame128_type = authData[@"accountType"];
    if ([ame128_type isEqualToString:@"thirdparty"]) {
        auth = [[ThirdPartyAuthenticator alloc] initWithData:authData];
    } else if ([ame128_type isEqualToString:@"microsoft"]) {
        auth = [[MicrosoftAuthenticator alloc] initWithData:authData];
    } else if ([ame128_type isEqualToString:@"local"]) {
        auth = [[LocalAuthenticator alloc] initWithData:authData];
    } else if ([authData[@"expiresAt"] longValue] == 0) {
        auth = [[LocalAuthenticator alloc] initWithData:authData];
    } else if (authData[@"clientToken"] != nil) {
        // If there is a clientToken, this is a third-party account
        auth = [[ThirdPartyAuthenticator alloc] initWithData:authData];
    } else {
        auth = [[MicrosoftAuthenticator alloc] initWithData:authData];
    }

    // 迁移旧格式账户：若 authData 没有 accountId 字段，说明是旧版按 username 命名的账户。
    // 生成 accountId，保存到新文件 <accountId>.json，删除旧文件 <username>.json，
    // 迁移头像文件，并更新 selected_account。
    NSString *existingAccountId = authData[@"accountId"];
    if (existingAccountId == nil || [existingAccountId length] == 0) {
        NSString *newAccountId = [BaseAuthenticator generateAccountIdForData:authData];
        authData[@"accountId"] = newAccountId;

        NSString *newPath = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), newAccountId];
        NSError *saveError = saveJSONToFile(authData, newPath);

        if (saveError == nil) {
            // 删除旧文件（如果 accountId 入参与生成的 newAccountId 不同，说明入参是旧 username）
            if (![accountId isEqualToString:newAccountId]) {
                [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            }
            // 迁移头像文件：<username>.png → <accountId>.png
            // 头像目录是 <Documents>/avatars/，与账户目录（POJAV_HOME/accounts/）分离
            NSString *username = authData[@"username"];
            if (username && username.length > 0 && ![username isEqualToString:newAccountId]) {
                NSString *docsDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                NSString *oldAvatarPath = [NSString stringWithFormat:@"%@/avatars/%@.png", docsDir, username];
                NSString *newAvatarPath = [NSString stringWithFormat:@"%@/avatars/%@.png", docsDir, newAccountId];
                // 仅当旧头像存在且新头像不存在时迁移，避免覆盖
                if ([NSFileManager.defaultManager fileExistsAtPath:oldAvatarPath] &&
                    ![NSFileManager.defaultManager fileExistsAtPath:newAvatarPath]) {
                    [NSFileManager.defaultManager moveItemAtPath:oldAvatarPath toPath:newAvatarPath error:nil];
                }
            }
            // 更新 selected_account：若当前选中的是旧 username/accountId，改为新的 accountId
            if ([getPrefObject(@"internal.selected_account") isEqualToString:accountId]) {
                setPrefObject(@"internal.selected_account", newAccountId);
            }
        }
    }

    // Task180：记录本次加载已稳定的 accountId，供 saveChanges 感知后续漂移
    auth.ame180_savedAccountId = authData[@"accountId"];

    return auth;
}

- (id)initWithData:(NSMutableDictionary *)data {
    current = self = [self init];
    self.authData = data;
    return self;
}

- (id)initWithInput:(NSString *)string {
    NSMutableDictionary *data = [[NSMutableDictionary alloc] init];
    data[@"input"] = string;
    return [self initWithData:data];
}

- (void)loginWithCallback:(Callback)callback {
}

- (void)refreshTokenWithCallback:(Callback)callback {
}

- (BOOL)saveChanges {
    NSError *error;

    [self.authData removeObjectForKey:@"input"];
    [self.authData removeObjectForKey:@"password"];
    // oldusername 机制已废弃：文件名改用 accountId，username 变更不再需要重命名文件
    [self.authData removeObjectForKey:@"oldusername"];

    // 确保 accountId 存在（首次保存时兜底生成，正常登录流程已在子类设置）
    NSString *accountId = self.authData[@"accountId"];
    if (accountId == nil || [accountId length] == 0) {
        accountId = [BaseAuthenticator generateAccountIdForData:self.authData];
        self.authData[@"accountId"] = accountId;
    }

    // 文件名使用 accountId（唯一标识），同名账户不再冲突
    NSString *newPath = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), accountId];
    error = saveJSONToFile(self.authData, newPath);

    if (error != nil) {
        showDialog(@"Error while saving file", error.localizedDescription);
    } else {
        // 保存选中的账户（accountId），确保重启后能恢复登录状态
        setPrefObject(@"internal.selected_account", accountId);

        // Task180：复制 bug 双保险①——写盘成功后统一迁移头像 + 清理旧文件。
        // 仅当本实例上一次已保存的 accountId 与本次不同（= refresh 链改写了
        // 身份）时触发；迁移防覆盖幂等（旧不存在/新已存在均为空操作），
        // 旧文件删除在新文件已成功落盘之后执行（失败不清理，防数据丢失）。
        NSString *ame180_old = self.ame180_savedAccountId;
        if (ame180_old.length > 0 && ![ame180_old isEqualToString:accountId]) {
            [[AvatarManager sharedManager] ame180_migrateAvatarFromAccount:ame180_old
                                                                toAccount:accountId];
            NSString *oldPath = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), ame180_old];
            [[NSFileManager defaultManager] removeItemAtPath:oldPath error:nil];
            NSLog(@"[Task180] account file migrated after accountId drift: %@ -> %@", ame180_old, accountId);
        }
        self.ame180_savedAccountId = accountId;
    }
    return error == nil;
}

@end
