//
//  AiProviderStore.h
//  Prisma
//
//  AI 提供商存储：单例。providers 读写 Documents/AI/providers.json，
//  selectedProviderId 存 NSUserDefaults（ai.selected_provider_id）。
//

#import <Foundation/Foundation.h>
#import "AiProvider.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiProviderStore : NSObject

/// 已配置的提供商列表（读时懒加载，首次不存在时用 defaultPresets 播种）
@property (nonatomic, strong, readonly) NSMutableArray<AiProvider *> *providers;

/// 当前选中的提供商（依据 ai.selected_provider_id；未配置或不存在时返回 nil）
@property (nonatomic, strong, nullable) AiProvider *selectedProvider;

/// 单例
+ (instancetype)sharedStore;

/// 三个预设提供商字典（DeepSeek / OpenAI / Ollama），供首次创建界面与播种使用
+ (NSArray<NSDictionary *> *)defaultPresets;

/// 显式触发加载（幂等；首次访问 providers 已自动加载）
- (void)loadIfNeeded;

/// 持久化 providers 到磁盘
- (void)save;

- (void)addProvider:(AiProvider *)provider;
- (void)updateProvider:(AiProvider *)provider;
- (void)deleteProvider:(AiProvider *)provider;
- (nullable AiProvider *)providerById:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END