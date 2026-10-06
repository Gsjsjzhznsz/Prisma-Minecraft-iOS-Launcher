#import <Foundation/Foundation.h>

typedef void(^Callback)(id status, BOOL success);

@interface BaseAuthenticator : NSObject

@property (nonatomic, strong) NSMutableDictionary *authData;

+ (id)current;
+ (void)setCurrent:(BaseAuthenticator *)auth;
// 按 accountId 从磁盘加载账户文件。兼容旧版（按 username 命名）账户：
// 若加载到的 authData 没有 accountId 字段，会自动生成并迁移文件、头像、selected_account。
+ (id)loadSavedName:(NSString *)accountId;
// 根据账户数据生成唯一 accountId。微软账户用 xuid，第三方账户用 profileId，本地账户生成 UUID。
+ (NSString *)generateAccountIdForData:(NSMutableDictionary *)authData;

- (id)initWithData:(NSMutableDictionary *)data;
- (id)initWithInput:(NSString *)string;
- (void)loginWithCallback:(Callback)callback;
- (void)refreshTokenWithCallback:(Callback)callback;
- (BOOL)saveChanges;

@end

@interface LocalAuthenticator : BaseAuthenticator
@end

@interface MicrosoftAuthenticator : BaseAuthenticator

+ (void)clearTokenDataOfProfile:(NSString *)profile;
+ (NSDictionary *)tokenDataOfProfile:(NSString *)profile;

// ★ Task224（反馈第 17 项）：微软账号高级操作改为应用内直连 Minecraft
// profile services（旧 Task223 实现仅跳转 minecraft.net 网页）。
// 上传皮肤：multipart POST /minecraft/profile/skins（variant=classic|slim
// + file=skin.png，PNG 64x64 由调用方先行校验）。
- (void)ame224_uploadSkinPNGData:(NSData *)pngData variant:(NSString *)variant callback:(Callback)callback;
// 修改游戏名字：PUT /minecraft/name（JSON name 字段）。400/403 在实现侧
// 映射为本地化错误（名字被占用 / 不允许 / 无可用改名机会）。
- (void)ame224_changePlayerName:(NSString *)newName callback:(Callback)callback;

@end
