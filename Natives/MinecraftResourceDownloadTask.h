#import <UIKit/UIKit.h>

@class AFURLSessionManager;
@class ModpackAPI;

extern NSString * const kMinecraftResourceDownloadBackgroundSessionIdentifier;

@interface MinecraftResourceDownloadTask : NSObject

+ (AFURLSessionManager *)sharedBackgroundSessionManager;

@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
@property(nonatomic, copy) void(^modpackDownloadCompletion)(void);

// 重试相关属性
@property(nonatomic) NSInteger maxRetryCount;
@property(nonatomic, readonly) NSInteger currentRetryCount;
@property(nonatomic, copy) void(^retryCallback)(NSInteger retryCount, NSInteger maxRetryCount);

// 阶段5修复（参照 FCL）：失败的文件列表，单文件下载失败不再取消整批任务，
// 而是记录到此数组，最终汇总报告给用户。每个元素是 @{@"name": ..., "error": ...}
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *failedFiles;

// 新增方法声明（用于账户检查）
- (BOOL)checkAccessWithDialog:(BOOL)show;

- (void)prepareForDownload;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success;

// 带重试的下载任务创建
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path retryCount:(NSInteger)retryCount success:(void (^)())success;

- (void)finishDownloadWithErrorString:(NSString *)error;

/// 取消整个下载流程（redesign-download-ui Phase 3）：
/// 供 DownloadTaskManager.cancelRawTask: 通过 respondsToSelector:@selector(cancel)
/// 调用——统一进度页的取消按钮取消任务时，取消内部 NSProgress 以中断流程，
/// KVO 观察到 cancelled 后按既有路径收尾（置 Cancelled 状态并移除观察者）。
- (void)cancel;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

#pragma mark - Task303：跨安装链共用（原版/模组端重复实例检测）

/// 目标版本目录已存在时弹 Task300 同款命名窗，返回用户确认后的唯一 id；
/// 目录不存在直接回调原始 id；用户取消回调 finalId=nil。completion 恒在主线程回调。
/// 供 DVC.installFabricLikeLoader 等模组端安装链复用（对齐原版 Task300 行为）。
+ (void)ame303_resolveDuplicateVersionId:(NSString *)versionId
                              completion:(void (^)(NSString *finalId, BOOL cancelled))completion;

/// 预填唯一建议名 "<id> 2"、"<id> 3"...（目标目录不存在即采纳）
+ (NSString *)ame303_uniqueSuggestionForId:(NSString *)origId;

@end