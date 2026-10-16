//
//  AISessionListViewController.h
//  Prisma
//
//  AI 会话列表页：展示全部历史会话（按更新时间排序，置顶会话优先），
//  支持搜索、侧滑删除、新建会话；点击会话通过回调返回给调用方。
//

#import <UIKit/UIKit.h>
#import "AiSession.h"

NS_ASSUME_NONNULL_BEGIN

@interface AISessionListViewController : UIViewController

/// 点击某个会话时的回调
@property (nonatomic, copy, nullable) void (^onSelectSession)(AiSession *session);
/// 新建会话成功后的回调
@property (nonatomic, copy, nullable) void (^onNewSession)(AiSession *session);

@end

NS_ASSUME_NONNULL_END