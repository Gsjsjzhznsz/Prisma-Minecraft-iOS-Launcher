//
//  AiProvider.h
//  Prisma
//
//  AI 提供商数据模型：描述一个 OpenAI 兼容的 LLM 服务端点。
//  支持系列化到/从 JSON（NSJSONSerialization 友好），供 AiProviderStore 持久化。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AiProvider : NSObject

/// 唯一标识（UUID）
@property (nonatomic, copy) NSString *identifier;
/// 显示名称，如 DeepSeek / OpenAI / Ollama
@property (nonatomic, copy) NSString *name;
/// API 协议，默认 @"openai_compatible"
@property (nonatomic, copy) NSString *protocol;
/// 服务基础地址，如 https://api.deepseek.com/v1
@property (nonatomic, copy) NSString *baseURL;
/// API Key（可空，apiKey 为空时请求不携带 Authorization）
@property (nonatomic, copy) NSString *apiKey;
/// 模型名称，如 deepseek-chat
@property (nonatomic, copy) NSString *model;
/// 采样温度，默认 0.7
@property (nonatomic, assign) double temperature;
/// 最大生成 token 数，默认 4096
@property (nonatomic, assign) NSInteger maxTokens;
/// 上下文窗口长度，默认 8192
@property (nonatomic, assign) NSInteger contextWindow;

/// 从 JSON 字典创建（字段缺失使用默认值兜底）
+ (nullable instancetype)providerWithDictionary:(NSDictionary *)dict;
- (nullable instancetype)initWithDictionary:(NSDictionary *)dict;
/// 转为 JSON 友好字典
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END