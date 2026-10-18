#import "BaseAuthenticator.h"

@implementation LocalAuthenticator

- (void)loginWithCallback:(Callback)callback {
    self.authData[@"username"] = self.authData[@"input"];
    self.authData[@"profileId"] = @"00000000-0000-0000-0000-000000000000";
    // Task290（PocketJ 同名账户共存移植）：重复添加同用户名的离线账户时复用既有
    // 本地账户的 accountId（update-in-place，列表不再出同身份多条目）；首次添加
    // 仍铸造随机 UUID。仅匹配本地类型——同名微软/第三方账户身份键不同，共存不受影响。
    NSString *ame290_reuse = [BaseAuthenticator ame290_existingLocalAccountIdForUsername:self.authData[@"username"]];
    if (ame290_reuse.length > 0) {
        self.authData[@"accountId"] = ame290_reuse;
    } else {
        self.authData[@"accountId"] = [[NSUUID UUID] UUIDString];
    }
    // Task 128：显式账户类型标记（防键位嗅探串类，见 BaseAuthenticator.loadSavedName）
    self.authData[@"accountType"] = @"local";
    // 使用Minecraft Headshot API加载头像
    self.authData[@"profilePicURL"] = [NSString stringWithFormat:@"https://api.rms.net.cn/head/%@", self.authData[@"username"]];
    callback(nil, [super saveChanges]);
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Nothing to do
    callback(nil, YES);
}

@end
