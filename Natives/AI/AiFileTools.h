//
//  AiFileTools.h
//  Prisma
//
//  Prisma AI Agent 文件工具：list_files / read_file / grep_files（只读）、
//  write_file / edit_file（受控写入）、delete_file（危险写入）。
//  所有文件操作经沙盒路径安全检查（resolveSafely）限定在 App 沙盒内。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiFileTools : NSObject <AiTool>

@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) NSString *summary;
@property (nonatomic, readonly) AiToolPermission permission;

/// 指定该实例化对象对应的工具名
- (instancetype)initWithName:(NSString *)name;

/// 沙盒路径安全解析。绝对路径（以 / 开头）从 App 沙盒根（Documents）拼接，
/// $GAMEDIR 占位符替换为当前实例 gameDir；相对路径相对当前实例根。
/// 标准化后检查不越出沙盒，越界返回 nil。
+ (nullable NSString *)resolveSafely:(NSString *)path;

@end

NS_ASSUME_NONNULL_END