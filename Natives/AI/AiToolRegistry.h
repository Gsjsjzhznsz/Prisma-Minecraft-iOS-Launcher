//
//  AiToolRegistry.h
//  Prisma
//
//  Prisma AI Agent 工具注册表：登记所有内置工具，向 LLM 暴露 OpenAI 风格 schema，
//  并把 LLM 传来的参数规范化后分发给对应工具执行。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiToolRegistry : NSObject

/// 单例
+ (instancetype)sharedRegistry;

/// 注册一个工具（重复 name 会覆盖旧工具）
- (void)registerTool:(id<AiTool>)tool;

/// 转换为 OpenAI function calling 的 tools 数组
/// 结构：[{type:function, function:{name, description, parameters:{type:object, properties, required}}}]
- (NSArray<NSDictionary *> *)openAIToolSchemas;

/// 按工具名查找；未找到返回 nil
- (id<AiTool> _Nullable)toolForName:(NSString *)name;

/// 参数规范化：键名小写化 + 抹平分隔符/大小写差异 → 统一小写 camelCase，
/// 丢弃 value 为空的键；返回新字典（不改原字典）。
- (NSDictionary * _Nonnull)normalizedParams:(NSDictionary * _Nonnull)params;

/// 按名称执行工具（先 normalizedParams 再透传；结果一律回调到主线程）
- (void)executeToolNamed:(NSString *)name
                  params:(NSDictionary *)params
              completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END