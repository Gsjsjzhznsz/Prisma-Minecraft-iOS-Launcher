//
//  AmeFloatingMenu.h
//  Amethyst
//
//  ★ Task237（用户指令：“彻底重写所有悬浮菜单样式。不要使用原生
//    UIAlertController 加魔改，也不要出现原生与液态玻璃混杂。根据设置
//    中的界面风格适配：当界面风格为液态玻璃时，显示真正的液态玻璃悬浮
//    菜单，使用 UIVisualEffectView 实现毛玻璃半透明背景、圆角、菜单项
//    带图标、整体悬浮于界面上，而不是系统 ActionSheet 分块列表。当界面
//    风格为原生时，显示旧版本的原生悬浮弹窗”）：
//
//    统一悬浮菜单组件 + 中央路由。
//    - 玻璃风格（LGCIsGlassStyleActive）：presentViewController 路由把
//      UIAlertController 【整体替换】为本组件渲染的全自定义液态玻璃悬浮
//      菜单——原生弹窗的视图层级永不上屏，从构造上杜绝“原生与玻璃混杂”；
//      菜单项自动带 SF Symbol 图标（按标题语义启发式匹配），支持文本
//      输入框镜像（含键盘避让与双向同步）。
//    - 原生风格：直通系统 presentViewController——旧版本原生弹窗，
//      逐字节不变、零魔改。
//
//    渲染配方（文字可见性由构造保证，不再依赖“往原生视图里塞玻璃层”）：
//      面板底色（明暗自适应半透明实底，永不清空）
//      → UIVisualEffectView（SystemMaterial 毛玻璃，最底层子视图）
//      → 内容（标题/正文/输入框/菜单行，恒在磨砂之上）
//      → 顶部发丝描边覆盖环。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 悬浮菜单行控件（图标 + 标题 + 自带按压反馈；AmeFloatingMenu 与游戏内
/// 菜单面板共用同一套行语言）。
@interface Ame237MenuRow : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *rowLabel;
/// 是否显示图标（原生风格的游戏内菜单隐藏图标 = 旧版文本行原貌）；
/// 默认 YES；无符号可用时同样自动退化为纯文本行。
@property (nonatomic, assign) BOOL showsIcon;
- (void)ame237_configureWithIcon:(nullable UIImage *)icon
                           title:(NSString *)title
                       textColor:(UIColor *)textColor
                     symbolTint:(UIColor *)symbolTint
                        emphasis:(BOOL)emphasis;
@end

/// 统一悬浮菜单入口（玻璃风格的整体替换渲染器；镜像失败返回 NO =
/// 调用方回退原生呈现，样式永不破坏功能）。
@interface AmeFloatingMenu : NSObject

/// 把一个已配置完毕的 UIAlertController 用自定义液态玻璃悬浮菜单呈现。
/// @param alert     数据源（title/message/actions/textFields 经 KVC/公有
///                  属性镜像；UIAlertAction 的 title/style/handler/enabled
///                  走 valueForKey:，任何异常 → 返回 NO 走原生）
/// @param presenter 呈现方（与原生 presentViewController 同参）
/// @param animated  动画语义（NO = 无动画直现）
/// @param completion 呈现完成回调（语义与原生一致）
/// @return YES = 已由玻璃菜单接管呈现；NO = 调用方必须走原生路径
+ (BOOL)presentGlassMenuForAlert:(UIAlertController *)alert
                   fromPresenter:(UIViewController *)presenter
                         animated:(BOOL)animated
                       completion:(nullable void (^)(void))completion;

/// ★ Task242：带取消语义的接管入口（AmeNativeMenu 菜单分轨呈现用）。
///   onDismiss = 用户未选中任何实质动作而关闭面板（点按面板外部遮罩且
///   无 cancel 项，或点按 cancel 项）时回调——承接系统 UIMenu didEnd 的
///   外部点按取消语义（Task240 定案：等待回调的流程不悬死，如第三方
///   登录角色选择 complete(nil)）。点选实质动作（default/destructive）
///   关闭不回调。
+ (BOOL)presentGlassMenuForAlert:(UIAlertController *)alert
                   fromPresenter:(UIViewController *)presenter
                         animated:(BOOL)animated
                       completion:(nullable void (^)(void))completion
                        onDismiss:(nullable void (^)(void))onDismiss;

/// 标题语义 → SF Symbol 图标名（公开给游戏内菜单共用同一套图标语言）。
+ (nullable NSString *)iconNameForTitle:(NSString *)title;

/// 图标名 → 按 19pt/medium 渲染的符号图（带回退链）。
+ (nullable UIImage *)symbolImageForName:(NSString *)name;

@end

/// 中央路由钩子（安装点：UIKit+hook.m 的 init_hookUIKitConstructor，
/// 交换 UIViewController 基类自有的 presentViewController:）。
/// 玻璃风格 + UIAlertController → AmeFloatingMenu 整体替换；其余全部
/// 零开销直透（原生外观逐字节不变）。
@interface UIViewController (Ame237FloatingMenuRouter)

- (void)ame237_hook_presentViewController:(UIViewController *)viewControllerToPresent
                                 animated:(BOOL)flag
                               completion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
