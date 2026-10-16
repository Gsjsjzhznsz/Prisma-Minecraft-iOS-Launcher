//
//  AiTodoTool.m
//  Prisma
//

#import "AiTodoTool.h"
#import "../utils.h"   // Task271-e：工具结果/错误文案 i18n 接线需要 localize()

static NSString *const kAiTodoFileName = @"todos.json";
static const NSInteger kAiTodoMaxItems = 200;

@interface AiTodoTool ()
@property (nonatomic, copy) NSString *internalName;
/// 串行队列：todos.json 读写与 id 分配的线程安全保护
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation AiTodoTool

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (self) {
        _internalName = [name copy] ?: @"";
        _queue = dispatch_queue_create("ai.todo.tool", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (NSString *)name {
    return self.internalName;
}

- (AiToolPermission)permission {
    if ([self.internalName isEqualToString:@"todo_list"]) {
        return AiToolPermissionReadOnly;
    }
    return AiToolPermissionControlledWrite;
}

- (NSString *)summary {
    if ([self.internalName isEqualToString:@"todo_create"]) {
        return @"创建一条待办事项（多步任务的执行清单）。"
               "\n参数：title（string，必填）、description（string，可选）。"
               "\n返回新条目 id。";
    }
    if ([self.internalName isEqualToString:@"todo_list"]) {
        return @"列出全部待办事项（含已完成）。"
               "\n无参数。"
               "\n返回 JSON 数组：{id, title, description, done, createdAt}。";
    }
    if ([self.internalName isEqualToString:@"todo_update"]) {
        return @"更新待办事项：勾选完成/取消完成，或修改标题与描述。"
               "\n参数：id（number，必填）、done（boolean，可选，true=完成 false=未完成）、title（string，可选）、description（string，可选）。"
               "\n返回更新后的条目。";
    }
    // todo_delete
    return @"删除一条待办事项。"
           "\n参数：id（number，必填）。"
           "\n返回「已删除」。";
}

#pragma mark - 存储

+ (NSString *)todosFilePath {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    return [[docs stringByAppendingPathComponent:@"AI"] stringByAppendingPathComponent:kAiTodoFileName];
}

+ (NSMutableArray *)loadTodos {
    NSString *path = [AiTodoTool todosFilePath];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) return [NSMutableArray array];
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [json isKindOfClass:[NSMutableArray class]] ? json : [NSMutableArray array];
}

+ (BOOL)saveTodos:(NSArray *)todos {
    NSString *path = [AiTodoTool todosFilePath];
    [[NSFileManager defaultManager] createDirectoryAtPath:[path stringByDeletingLastPathComponent]
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:todos options:NSJSONWritingPrettyPrinted error:&err];
    if (!data || err) return NO;
    return [data writeToFile:path options:NSDataWritingAtomic error:nil];
}

/// 生成新 id：现有最大 id + 1（从 1 开始）
+ (NSInteger)nextIdInTodos:(NSArray *)todos {
    NSInteger maxId = 0;
    for (NSDictionary *item in todos) {
        NSInteger cur = [item[@"id"] integerValue];
        if (cur > maxId) maxId = cur;
    }
    return maxId + 1;
}

+ (NSString *)itemDescription:(NSDictionary *)item {
    if (![item isKindOfClass:[NSDictionary class]]) return localize(@"ai.todo.invalid_item", nil);
    NSString *done = [item[@"done"] boolValue] ? localize(@"ai.todo.done_tag", nil) : localize(@"ai.todo.undone_tag", nil);
    NSString *desc = [item[@"description"] isKindOfClass:[NSString class]] ? item[@"description"] : @"";
    if (desc.length > 0) {
        return [NSString stringWithFormat:@"#%@ %@ %@ — %@", [item[@"id"] description], done, item[@"title"] ?: @"", desc];
    }
    return [NSString stringWithFormat:@"#%@ %@ %@", [item[@"id"] description], done, item[@"title"] ?: @""];
}

#pragma mark - 执行分发

- (void)execute:(NSDictionary<NSString *, id> *)params
     completion:(void (^)(NSString * _Nullable result, NSError * _Nullable error))completion {
    if (!completion) return;

    dispatch_async(self.queue, ^{
        NSString *result = nil;
        NSError *error = nil;

        if ([self.internalName isEqualToString:@"todo_create"]) {
            result = [self performCreate:params error:&error];
        } else if ([self.internalName isEqualToString:@"todo_list"]) {
            result = [self performList];
        } else if ([self.internalName isEqualToString:@"todo_update"]) {
            result = [self performUpdate:params error:&error];
        } else if ([self.internalName isEqualToString:@"todo_delete"]) {
            result = [self performDelete:params error:&error];
        } else {
            error = [NSError errorWithDomain:@"AiTool" code:404
                                    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.tools.unknown_tool_fmt", nil), self.internalName]}];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            completion(result, error);
        });
    });
}

- (NSString *)performCreate:(NSDictionary *)params error:(NSError **)error {
    NSString *title = [params[@"title"] isKindOfClass:[NSString class]] ? params[@"title"] : @"";
    if (title.length == 0) {
        if (error) *error = [NSError errorWithDomain:@"AiTool" code:400
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.todo.param_title_required", nil)}];
        return nil;
    }
    NSString *desc = [params[@"description"] isKindOfClass:[NSString class]] ? params[@"description"] : @"";

    NSMutableArray *todos = [AiTodoTool loadTodos];
    if (todos.count >= kAiTodoMaxItems) {
        if (error) *error = [NSError errorWithDomain:@"AiTool" code:409
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.todo.list_full", nil)}];
        return nil;
    }
    NSInteger newId = [AiTodoTool nextIdInTodos:todos];
    NSDictionary *item = @{
        @"id": @(newId),
        @"title": title,
        @"description": desc ?: @"",
        @"done": @NO,
        @"createdAt": [[NSDate date] description],
    };
    [todos addObject:item];
    if (![AiTodoTool saveTodos:todos]) {
        if (error) *error = [NSError errorWithDomain:@"AiTool" code:500
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.todo.save_failed", nil)}];
        return nil;
    }
    return [NSString stringWithFormat:localize(@"ai.todo.created_fmt", nil), (long)newId, title];
}

- (NSString *)performList {
    NSMutableArray *todos = [AiTodoTool loadTodos];
    if (todos.count == 0) return localize(@"ai.todo.empty", nil);

    NSMutableString *out = [NSMutableString string];
    NSInteger doneCount = 0;
    for (NSDictionary *item in todos) {
        if ([item[@"done"] boolValue]) doneCount++;
        [out appendFormat:@"%@\n", [AiTodoTool itemDescription:item]];
    }
    [out appendFormat:localize(@"ai.todo.summary_fmt", nil),
        (unsigned long)todos.count, (long)doneCount];
    return out;
}

- (NSString *)performUpdate:(NSDictionary *)params error:(NSError **)error {
    NSDictionary *target = nil;
    NSMutableArray *todos = [AiTodoTool loadTodos];
    NSInteger itemId = [params[@"id"] integerValue];
    for (NSUInteger i = 0; i < todos.count; i++) {
        NSDictionary *item = todos[i];
        if ([item isKindOfClass:[NSDictionary class]] && [item[@"id"] integerValue] == itemId) {
            target = item;
            break;
        }
    }
    if (!target) {
        if (error) *error = [NSError errorWithDomain:@"AiTool" code:404
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.todo.not_found_fmt", nil), (long)itemId]}];
        return nil;
    }

    NSMutableDictionary *updated = [target mutableCopy];
    id doneVal = params[@"done"];
    if (doneVal != nil && ![doneVal isKindOfClass:[NSNull class]]) {
        BOOL doneFlag;
        if ([doneVal isKindOfClass:[NSString class]]) {
            NSString *s = [(NSString *)doneVal lowercaseString];
            doneFlag = [s hasPrefix:@"t"] || [s isEqualToString:@"1"] || [s isEqualToString:@"yes"];
        } else {
            doneFlag = [doneVal boolValue];
        }
        updated[@"done"] = @(doneFlag);
    }
    NSString *title = [params[@"title"] isKindOfClass:[NSString class]] ? params[@"title"] : nil;
    if (title.length > 0) updated[@"title"] = title;
    NSString *desc = [params[@"description"] isKindOfClass:[NSString class]] ? params[@"description"] : nil;
    if (desc.length > 0) updated[@"description"] = desc;

    NSUInteger idx = [todos indexOfObject:target];
    if (idx != NSNotFound) todos[idx] = updated;
    if (![AiTodoTool saveTodos:todos]) {
        if (error) *error = [NSError errorWithDomain:@"AiTool" code:500
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.todo.save_failed", nil)}];
        return nil;
    }
    return [NSString stringWithFormat:localize(@"ai.todo.updated_fmt", nil), [AiTodoTool itemDescription:updated]];
}

- (NSString *)performDelete:(NSDictionary *)params error:(NSError **)error {
    NSMutableArray *todos = [AiTodoTool loadTodos];
    NSInteger itemId = [params[@"id"] integerValue];
    NSDictionary *target = nil;
    for (NSDictionary *item in todos) {
        if ([item isKindOfClass:[NSDictionary class]] && [item[@"id"] integerValue] == itemId) {
            target = item;
            break;
        }
    }
    if (!target) {
        if (error) *error = [NSError errorWithDomain:@"AiTool" code:404
                                            userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:localize(@"ai.todo.not_found_fmt", nil), (long)itemId]}];
        return nil;
    }
    [todos removeObject:target];
    if (![AiTodoTool saveTodos:todos]) {
        if (error) *error = [NSError errorWithDomain:@"AiTool" code:500
                                            userInfo:@{NSLocalizedDescriptionKey: localize(@"ai.todo.save_failed", nil)}];
        return nil;
    }
    return [NSString stringWithFormat:localize(@"ai.todo.deleted_fmt", nil), (long)itemId];
}

@end
