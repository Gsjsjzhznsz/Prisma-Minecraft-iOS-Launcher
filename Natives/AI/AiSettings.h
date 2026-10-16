//
//  AiSettings.h
//  Prisma
//
//  AI 相关偏好：单例，读取/写入 NSUserDefaults 的 ai.* 键。
//  setters/getters 直接读写 UserDefaults，不做内存缓存。
//

#import <Foundation/Foundation.h>
#import "AiTool.h" // 提供 AiSafetyMode 枚举（唯一定义处）

NS_ASSUME_NONNULL_BEGIN

@interface AiSettings : NSObject

/// 单例
+ (instancetype)sharedSettings;

/// 当前选中的提供商 id（NSUserDefaults ai.selected_provider_id）
@property (nonatomic, copy, nullable) NSString *selectedProviderId;
/// 安全模式（0=Safe/1=Ask/2=YOLO，默认 0）
@property (nonatomic, assign) AiSafetyMode safetyMode;
/// 是否启用 Markdown 渲染（默认 YES）
@property (nonatomic, assign) BOOL markdownEnabled;
/// 自定义系统提示词（默认返回 defaultSystemPrompt）
@property (nonatomic, copy) NSString *systemPrompt;

/// 默认系统提示词（中文），约定 Prisma 行为
+ (NSString *)defaultSystemPrompt;

/// ★ Task267：上游旧默认提示词全文（仅作迁移逐字比对基准，不对用户下发）
+ (NSString *)legacyAmethystSystemPrompt;

@end

NS_ASSUME_NONNULL_END