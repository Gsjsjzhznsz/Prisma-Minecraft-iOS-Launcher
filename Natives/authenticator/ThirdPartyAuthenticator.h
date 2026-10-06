#import <Foundation/Foundation.h>
#import "BaseAuthenticator.h"

NS_ASSUME_NONNULL_BEGIN

/// Task 129b：多角色选择回调（FCL 参照）。登录遇到多角色账户（Yggdrasil
/// availableProfiles 多于 1 个且无 selectedProfile）时，向 UI 层询问用户选哪个
/// 角色绑定；profiles = availableProfiles 数组（每项含 id/name）；complete 传
/// nil 表示用户取消登录。
typedef void(^ThirdPartyProfileChoice)(NSDictionary *_Nullable profile);
typedef void(^ThirdPartyProfilePicker)(NSArray<NSDictionary *> *profiles,
                                       ThirdPartyProfileChoice complete);

NS_ASSUME_NONNULL_END

@interface ThirdPartyAuthenticator : BaseAuthenticator

- (void)loginWithCallback:(Callback)callback;
- (void)refreshTokenWithCallback:(Callback)callback;
- (NSArray *)getJvmArgsForAuthlib;

/// Task133 皮肤纹理链的对外入口：重取当前角色的皮肤纹理 → 本地渲染头像 →
/// saveChanges。★ Task224 起由账号列表在换肤成功后调用（刷新头像与 UI）。
- (void)fetchProfileTextureWithCallback:(Callback)callback;

/// Task 129b：登录期多角色选择器（由登录页设置；nil 或未设置时沿用旧行为：
/// 自动绑定第一个角色——无 UI 场景（如后台刷新）的安全回退）。
@property (nonatomic, copy, nullable) ThirdPartyProfilePicker onProfileSelection;

/// Task 129b：为已保存的多角色账户切换绑定角色（FCL 多角色管理）。
/// profile 取自该账户 authData[@"availableProfiles"] 的条目（{id, name}）；
/// 切换 = 用当前 accessToken refresh 绑定新角色 + 旧 accountId 文件清理 +
/// 选中状态迁移（新 accountId 成为 selected_account）。回调语义与登录一致。
- (void)switchToProfile:(NSDictionary *)profile callback:(Callback)callback;

/// ★ Task224（反馈第 17 项）：上传皮肤到认证服务器（authlib-injector 生态的
/// 用户 API：PUT <站点根>/api/user/profile/<无连字符UUID>/skin，Bearer
/// accessToken + multipart 字段 model=wide|slim + file=skin.png）。token 过期
/// 时先走既有刷新链；成功后由调用方触发 fetchProfileTextureWithCallback
/// 重取皮肤纹理并本地重渲头像。
- (void)ame224_uploadSkinPNGData:(NSData *)pngData model:(NSString *)model callback:(Callback)callback;

/// 参照 authlib-injector 启动器技术规范解析 ALI（API Location Indication）
/// 将用户输入的简写地址解析为完整 API Root，并预取服务器元数据
/// completion 在主线程回调，resolvedURL 为最终 API Root（解析失败返回原始输入）
/// metadata 为服务器元数据 JSON 字符串（用于 prefetched 参数，失败为 nil）
+ (void)resolveAuthserverURL:(NSString *)inputURL
                  completion:(void (^)(NSString *resolvedURL, NSString *_Nullable metadata))completion;

@end