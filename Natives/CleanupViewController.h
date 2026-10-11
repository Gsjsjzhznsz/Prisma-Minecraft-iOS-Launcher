//
//  CleanupViewController.h
//  AngelAuraAmethyst
//
//  ★ Task255（清单 6）：清理垃圾中心——启动器常见垃圾 + MC 常见垃圾 +
//  扫描无引用版本供用户选择清理。入口 = 版本管理页扫描 FAB。
//  版本扫描器由调用方注入（ame255_versionScanner），与"恢复版本"
//  功能共用同一扫描口径（VersionManagerViewController.ame255_scanInstalledVersions）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CleanupViewController : UITableViewController

/// 版本扫描回调（注入式，避免 Cleanup → VersionManager 的头文件依赖）。
/// 返回字典数组：id / path / jsonOK / referenced / sizeBytes。
@property(nonatomic, copy, nullable) NSArray<NSDictionary *> *(^ame255_versionScanner)(void);

@end

NS_ASSUME_NONNULL_END
