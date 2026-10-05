#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Task223（清单第 9 项）：应用内文件夹浏览器（游戏内"打开文件夹"的承接页）。
/// 病历（2832c2b 装机反馈"文件夹能打开但什么也不显示，只有一个毛玻璃覆盖层"）：
/// Task222 把目录分支路由到 FileListViewController——但那是自定义控件 JSON
/// 选择器（只列 .json 文件、无标题、无返回、无目录导航），对普通文件夹 =
/// 空列表 = 用户只看到 PageSheet 的毛玻璃。
/// 本浏览器补齐 Files.app 式基础体验：全类型文件 + 目录下钻 + 面包屑标题 +
/// 分享 + 完成。列表排序：目录在前、名称不区分大小写。
@interface FolderBrowserViewController : UITableViewController

/// 要浏览的目录（绝对路径）。设置后立即加载。
@property (nonatomic, copy, nullable) NSString *rootPath;

/// 便捷构造：包一层 UINavigationController（PageSheet 呈现用）。
+ (UINavigationController *)wrappedControllerForPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
