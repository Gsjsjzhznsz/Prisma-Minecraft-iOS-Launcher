//
//  AiSessionStore.h
//  Prisma
//
//  AI 会话存储：单例。sessions 读写 Documents/AI/sessions.json（按 updatedAt 倒序），
//  最近会话 id 存 NSUserDefaults（ai.last_session_id）。
//

#import <Foundation/Foundation.h>
#import "AiSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiSessionStore : NSObject

/// 会话列表（懒加载，按 updatedAt 倒序排序）
@property (nonatomic, strong, readonly) NSMutableArray<AiSession *> *sessions;

/// 单例
+ (instancetype)sharedStore;

/// 创建并持久化一个新会话，置为最近会话
- (AiSession *)newSession;
- (void)deleteSession:(AiSession *)session;
- (void)updateSession:(AiSession *)session;
- (nullable AiSession *)sessionById:(NSString *)identifier;

/// 按标题关键字搜索（大小写不敏感）
- (NSArray<AiSession *> *)sessionsMatchingQuery:(NSString *)query;

/// 自动命名：取消息前 20 个字符（可额外拼接省略号）
+ (NSString *)autoTitleForMessage:(NSString *)message;

/// 最近会话：优先 aI.last_session_id 对应的会话，否则返回时间上最新的会话，无则为 nil
- (nullable AiSession *)lastActiveSession;
- (void)setLastActiveSessionId:(NSString *)identifier;

@end

NS_ASSUME_NONNULL_END