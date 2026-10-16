//
//  AIViewController.h
//  Prisma
//
//  AI 聊天主界面。展示会话消息、输入栏，负责与 AiAgent 交互与流式刷新。
//

#import <UIKit/UIKit.h>
#import "AiSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface AIViewController : UIViewController

/// 指定会话；传 nil 时由 AiSessionStore 新建一个
- (instancetype)initWithSession:(nullable AiSession *)session;

@end

NS_ASSUME_NONNULL_END