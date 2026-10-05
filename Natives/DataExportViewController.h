#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// ★ Task223（清单第 12/13 项）：数据导出二级入口页（用户指令：
///   "抛弃悬浮菜单，改为二级入口，借用版本下载界面进行选择和显示进度"）。
///   旧交互（设置点导出 → 压缩等级 ActionSheet 悬浮菜单 → 模态进度弹窗）
///   三宗罪：iPad 上 popover 锚点漂移（"往上跑，要多点几下上滑才能找到"）、
///   模态弹窗阻塞整个启动器、串行读写 10s/10MB 的龟速。
///   新交互：push 进本页 → 预检摘要卡 + 压缩等级分段控件（无任何弹层）→
///   开始后注册进 DownloadTaskManager（版本下载同款任务体系，autoPresentDetail
///   自动跳转任务详情页显示阶段/文件数/字节进度，且可随意离开页面后台继续）。
@interface DataExportViewController : UIViewController

@end

NS_ASSUME_NONNULL_END
