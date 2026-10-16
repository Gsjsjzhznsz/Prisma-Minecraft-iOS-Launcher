#import <Foundation/Foundation.h>

@interface PLProfiles : NSObject

@property(nonatomic) NSString *profilePath;
@property(nonatomic) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *> *profileDict;

+ (PLProfiles *)current;
+ (void)updateCurrent;

+ (id)profile:(NSMutableDictionary *)profile resolveKey:(id)key;
+ (NSString *)resolveKeyForCurrentProfile:(id)key;

- (id)initWithCurrentInstance;
- (NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *)profiles;

- (NSMutableDictionary<NSString *, NSString *> *)selectedProfile;
- (NSString *)selectedProfileName;
- (void)setSelectedProfileName:(NSString *)name;
- (void)save;

// 新增：修复构建错误 - 添加缺失的方法声明
- (void)saveProfile:(NSMutableDictionary<NSString *, NSString *> *)profile withName:(NSString *)name;

/// Task275 F6：锁内批量变更 API——外部对 `profiles` 活字典的裸写（后台导入
/// 线程 vs 主线程写者）构成“枚举中变更”崩溃面与读改写丢更新；统一收口：
/// block 在实例锁内直接改活字典，出锁前自动 save（save 同锁可重入）。
- (void)applyChanges:(void (NS_NOESCAPE ^)(NSMutableDictionary<NSString *, id> *profiles))changes;

// 服务器地址（FCL 风格：启动后自动加入服务器，留空则不加入）
- (NSString *)serverIpForCurrentProfile;
- (NSString *)serverIpForProfile:(NSString *)profileName;
- (void)setServerIp:(NSString *)serverIp forProfile:(NSString *)profileName;

@end
