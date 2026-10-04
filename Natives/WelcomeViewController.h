//
//  WelcomeViewController.h
//  Amethyst
//
//  Task218：首次使用欢迎向导（用户指令："在用户首次使用的时候弹出欢迎
//  界面，并帮助用户配置启动器，比如语言，数据导入导出功能，下载源设置
//  等等，这个界面的动画和视觉效果要做足"）。
//
//  流程（四步 + 完成页）：
//    0. 欢迎 Hero —— 图标弹入 + 名称/版本 + 粒子背景
//    1. 语言      —— 跟随系统 / 简体中文 / 繁體中文 / English（即时生效，
//                    完成时经 AppLanguageChanged 重建根视图；54 语言全集
//                    仍在 设置 → 通用 → 语言）
//    2. 下载源    —— 官方优先 / 镜像优先（国内推荐）/ 自动测速（写入
//                    download.fileSource 等四个策略键 + 触发测速引擎）
//    3. 数据迁移  —— 从备份导入（DataTransferService 文件选择器）/ 跳过
//    4. 完成      —— 彩带礼花 + "开始使用"
//
//  触发：SceneDelegate 在根视图就绪后检查 general.welcome_completed
//  （默认 NO），未完成即全屏模态呈现；完成/跳过均置 YES（一次性）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface WelcomeViewController : UIViewController

/// 便捷入口：首次使用（general.welcome_completed == NO）时全屏呈现欢迎
/// 向导。presenter 为当前可见的根控制器；已完成时为空操作。UI 呈现
/// 自动切主线程，可在任意线程调用。
+ (void)presentIfNeededFromViewController:(UIViewController *)presenter;

@end

NS_ASSUME_NONNULL_END
