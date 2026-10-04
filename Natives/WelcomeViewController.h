//
//  WelcomeViewController.h
//  Amethyst
//
//  Task218：首次使用欢迎向导（用户指令："在用户首次使用的时候弹出欢迎
//  界面，并帮助用户配置启动器，比如语言，数据导入导出功能，下载源设置
//  等等，这个界面的动画和视觉效果要做足"）。
//
//  Task219（用户装机反馈重做，六项修正）：
//   ⑧ 布局根因修复——旧实现把每步内容容器约束到【上一步容器】再移除旧
//      容器，AutoLayout 随移除清掉引用约束 → 内容容器 0 尺寸钉死左上角
//      且点击测试越界失败（"缩在左上角/无法点击"）。新架构：内容区是
//      常驻 UIScrollView，每步只换 step 子视图，约束永不引用临时视图。
//      视觉全面 iPadOS 化（系统底色 + 卡片语言 + SF Symbols 图标位），
//      补返回上一步按钮；App 图标多候选加载（bundle 根 PNG 实名）。
//   ② 新增环境检测步：LiveContainer 识别（LoadedImage 扫描）+ 包名
//      一致性检查（ mainBundle vs 宿主 App.app ），不一致时给出
//      "Please open use livecontainer's bundle id in livecontainer" 指引。
//   ③ 新增 JIT 开启方式选择（复用 debug.jit_enabler 七选项与右面板
//      Task134 同一 URL 分发语义）+ 状态实时显示 + 立即开启。
//   ⑥ 完成步收尾后自动打开关于页（跳过路径不打扰）。
//
//  流程（五步 + 完成页）：
//    0. 欢迎 Hero  —— 图标弹入 + 名称/版本
//    1. 语言       —— 跟随系统 / 简体中文 / 繁體中文 / English（完成时经
//                     AppLanguageChanged 重建根视图；54 语言全集仍在
//                     设置 → 通用 → 语言）
//    2. 环境与 JIT —— LiveContainer 检测 + 包名指引；JIT 开启方式选择
//    3. 下载源     —— 官方优先 / 镜像优先（国内推荐）/ 自动测速（写入
//                     download.fileSource 等四个策略键 + 触发测速引擎）
//    4. 数据迁移   —— 从备份导入（DataTransferService 文件选择器）/ 跳过
//    5. 完成       —— 彩带礼花 + "开始使用" → 自动打开关于页
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

/// Task219：是否运行在 LiveContainer 环境（进程内已加载
/// LiveContainerShared.framework）。可在任意线程调用。
+ (BOOL)runningInLiveContainer;

/// Task219：LiveContainer 宿主 App（App.app）的包名；不在 LC 环境或
/// 解析失败时返回 nil。
+ (nullable NSString *)liveContainerHostBundleId;

@end

NS_ASSUME_NONNULL_END
