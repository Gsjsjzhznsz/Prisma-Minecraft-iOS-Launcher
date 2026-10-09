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

@end
