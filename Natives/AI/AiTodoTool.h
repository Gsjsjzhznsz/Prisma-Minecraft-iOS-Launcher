//
//  AiTodoTool.h
//  Prisma
//
//  to-do 清单工具（enhance-ai-agent Task 11）：
//  - todo_create（CONTROLLED_WRITE）：创建条目
//  - todo_list（READ_ONLY）：列出条目（含完成态）
//  - todo_update（CONTROLLED_WRITE）：改标题/描述/勾选 done
//  - todo_delete（CONTROLLED_WRITE）：删除条目
//
//  持久化：Documents/AI/todos.json（JSON 数组，条目含 id/title/description/done/createdAt）。
//  读写经串行队列保护线程安全；id 为单调递增整数。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiTodoTool : NSObject <AiTool>

/// internalName 支持：todo_create / todo_list / todo_update / todo_delete
- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
