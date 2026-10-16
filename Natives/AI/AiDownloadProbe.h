//
//  AiDownloadProbe.h
//  Prisma
//
//  下载进度查询工具（check_downloads）：遍历 DownloadTaskManager 全部任务，
//  返回名称/资源类型/状态/进度/速度/下载源。
//  供 AI 在 install_* wait=false 后台下载后轮询进度（enhance-ai-agent Task 8.2）。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiDownloadProbe : NSObject <AiTool>

/// internalName 当前仅支持 check_downloads
- (instancetype)initWithName:(NSString *)name;

@end

NS_ASSUME_NONNULL_END
