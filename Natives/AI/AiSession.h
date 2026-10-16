//
//  AiSession.h
//  Prisma
//
//  AI 会话数据模型：包含消息列表与元信息，支持 JSON 系列化以便持久化。
//

#import <Foundation/Foundation.h>
#import "AiMessage.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiSession : NSObject

/// 会话唯一标识（UUID）
@property (nonatomic, copy) NSString *identifier;
/// 会话标题（自动命名，来自首条用户消息）
@property (nonatomic, copy) NSString *title;
/// 创建时间
@property (nonatomic, strong) NSDate *createdAt;
/// 最后更新时间
@property (nonatomic, strong) NSDate *updatedAt;
/// 是否置顶
@property (nonatomic, assign) BOOL pinned;
/// 消息列表
@property (nonatomic, strong) NSMutableArray<AiMessage *> *messages;

/// 便捷构造：identifier 用 NSUUID，created/updated 为当前时间
+ (instancetype)sessionWithTitle:(NSString *)title;

/// JSON 系列化
- (instancetype)initWithDictionary:(NSDictionary *)dict;
- (NSDictionary *)toDictionary;

@end

NS_ASSUME_NONNULL_END