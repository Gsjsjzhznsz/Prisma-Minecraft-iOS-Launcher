#import <UIKit/UIKit.h>

// FCL风格右侧面板 - 显示账户信息、版本选择和启动按钮

@interface LauncherRightPanelViewController : UIViewController

// 更新账户信息显示
- (void)updateAccountInfo;

// 更新版本信息显示
- (void)updateVersionInfo;

// Task234（欢迎圈圈第五轮，“本来要圈启动按钮变成了执行jar”）：教练标记的
// 启动按钮锚点。Task233 的深搜按“最靠下大按钮”取值——本面板布局里
// 执行Jar/选择版本（38pt，贴底）恰在启动按钮（46pt）之下，位置猜测稳定
// 锚错。直接返回 launchButton 真身，按位置/尺寸的误锚彻底绝迹。
- (UIView *)ame234_launchAnchorView;

// Task235（欢迎圈圈第六轮，“版本与隔离被指向我的个人主页头像”）：
// “版本与隔离”教练页的锚点。旧锚 = 主内容区上半 42% 矩形——Card 布局
// 的主页内容顶部恰好是全宽头像卡，圆圈稳定套在用户头像上。直接返回
// manageVersionBtn（“选择版本”，版本/隔离管理的真实入口）真身。
- (UIView *)ame235_versionAnchorView;

@end
