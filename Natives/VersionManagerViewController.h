#import <UIKit/UIKit.h>

// 版本管理器 - 显示所有下载过的版本，使用现代磁贴风格
@interface VersionManagerViewController : UIViewController

/// ★ Task256（清单 3）：扫描 GAME_DIR/versions 全量版本（id/path/jsonOK/
///   referenced/sizeBytes 字典数组）。清理中心（CleanupViewController 的
///   versionScanner 块）、扫描恢复对话框与主页「清理垃圾」磁贴共用的
///   单一实现；类方法——主页磁贴无实例也能调用。
+ (NSArray<NSDictionary *> *)ame256_scanVersionsForCleanup;

@end