#import <UIKit/UIKit.h>

// ============================================================================
// Task 188（FCL 式控件仓库）：应用内浏览远程控件布局仓库（GitHub 仓库
// controls/ 目录 + index.json 索引，参考 Fold Craft Launcher 的控制仓库
// 设计），一键下载社区布局到本地 controlmap/，随后经编辑器"加载"菜单
// 或游戏内控件设置使用。下载源：raw.githubusercontent.com 主源 +
// jsDelivr CDN 回退。
// ============================================================================
@interface ControlRepoViewController : UITableViewController
/// 下载完成后的回调（文件名不含 .json 后缀，与 actionOpenFilePicker
/// 的 whenItemSelected 语义一致）。
@property (nonatomic, copy) void (^whenLayoutDownloaded)(NSString *fileName);

/// ★ Task230（反馈 #13：允许任何人上传控件）：上传流程入口（仓库页与
/// 控件编辑器共用）。preselect 传 controlmap 下的文件名（如 custom.json）
/// 可跳过选择步；传 nil 则先弹已安装布局选择器。流程：选布局 → 填元信息
/// （名称/作者/描述）→ 结构安全检查 → 系统分享提交文件 或 GitHub 网页
/// 建文件深链（预填路径+内容，一键提 PR）。
+ (void)ame230_presentUploadFlowFrom:(UIViewController *)presenter preselect:(NSString *)preselect;
@end
