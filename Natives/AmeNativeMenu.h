//
//  AmeNativeMenu.h
//  Amethyst
//
//  ★ Task240（用户指令："改成 IMG_0370 那种原生液态玻璃，要改全部"）：
//
//  系统原生 UIMenu 菜单呈现器。历史包袱：应用内"菜单/选择器"类交互散落
//  三套呈现——①UIAlertControllerStyleActionSheet（原生风格直通 = 旧材质
//  深色分块列表，即用户截图 IMG_0372）；②AmeFloatingMenu 自绘玻璃路由
//  （Task237，自绘面板贴 UIGlassEffect，形似而非神似）；③ame227 dim+panel
//  自绘菜单（Task227）。三者都产不出系统真液态玻璃。
//
//  本组件把全部菜单类交互统一换装为【系统 UIMenu 体系】呈现：
//    - iOS 26+：系统自动渲染原生 Liquid Glass（磨砂 + 折光 + 边缘高光 +
//      标题区，即用户基准截图 IMG_0370），零自定义代码、零材质拼接；
//    - iOS 14-25：系统标准上下文菜单（原生观感，与长按菜单完全一致）。
//
//  呈现机制：UIContextMenuInteraction（associated object 挂锚点视图，
//  重复呈现复用同一交互实例）+ presentMenu——菜单快照在每次呈现前刷新，
//  无状态陈旧风险；锚点即触发控件（按钮/单元格/图标），iPad 上自动
//  popover 锚定，无需调用方再配 popoverPresentationController。
//
//  分工边界（Task240 定案）：
//    - 菜单/选择器（操作菜单、单选器、带图标动作列表）→ 本组件；
//    - 确认（破坏性二次确认）/输入/纯提示弹窗 → 保留 UIAlertController
//      （弹窗不是菜单，Task237 玻璃路由对弹窗的原有接管不变）。
//
//  兼容性演进（Task241 → ★Task242 用户装机实测定案）：
//    - Task240 曾裸赌私有 presentMenu 存在（真机 iOS 26 unrecognized
//      selector 38 处全崩，Task241 三级降级链根治；Task241-ci 修编译雷）；
//    - ★ Task242：程序化系统菜单主路径被装机实测推翻——①系统上下文
//      菜单程序化呈现的材质不是用户要的液态玻璃（"毛玻璃没生效"）；
//      ②原生档走系统 UIContextMenu 仍是系统玻璃（"原生时还是液态玻璃"）。
//      【菜单呈现按界面风格分轨】（呈现机制与私有 API 链整体退役）：
//      玻璃档（LGCIsGlassStyleActive）→ AmeFloatingMenu 真液态玻璃面板
//      接管（UIGlassEffect，Task237/239 组件；用户实测"非常好"）；
//      原生档 → 旧版系统 actionSheet 直通（Task237 契约"原生 = 旧版
//      弹窗"）。全链回归公开 API，零私有选择器。
//    - handler 唯一合法来源 = 字典协议（公开 API）：UIAction/
//      UIAlertAction.handler 均非公开属性，反取在 iOS 26.2 SDK 为编译
//      错误（Task241 CI r1 双雷实证）；字典快照经 dictsForFallback:
//      随呈现链下传，37 处调用点全部走字典便捷入口。
//    - 外部点按关闭且未选中任何动作 → onDismiss 回调（取消语义不悬死）。
//    - ★ Task245（IMG_0380 用户定案"这些选择项就应该使用系统原生的
//      液态玻璃"）：玻璃档按【锚点域】重新分轨——启动器内选择菜单回归
//      系统 UIMenu 直出（Task241 三级降级链复活：presentMenu 探测 →
//      _presentMenuAtLocation: → 字典 actionSheet 兜底，玻璃档兜底由磨砂
//      面板接管；IMG_0370 基准）；Metal 游戏面（SurfaceViewController 层级
//      /gameMenuOverlay）保持磨砂面板（系统上下文菜单磨砂在 Metal 上
//      不合成，Task228/230/236 同族实锤）。魔改磨砂面板专属域 = 输入类
//      弹窗（内存数值输入等中央路由 UIAlertController 接管不变，快照改
//      窗口对位真透视，见 AmeFloatingMenu Task245）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 系统原生 UIMenu 菜单呈现器（Task240）。
@interface AmeNativeMenu : NSObject

/// 以系统 UIMenu 呈现菜单，锚定 sourceView。
/// 同一 sourceView 重复调用 = 复用交互实例、刷新菜单快照。
/// @param menu       已构建的 UIMenu（title 会随菜单显示）
/// @param sourceView 锚点视图（触发按钮/单元格/图标；须已在窗口层级）
+ (void)ame240_presentMenu:(UIMenu *)menu
                sourceView:(UIView *)sourceView;

/// 带消失回调的呈现：外部点按导致菜单消失且【未选中任何动作】时回调
/// onDismiss——承接旧 actionSheet 取消项语义（如"取消角色选择 →
/// complete(nil)"），避免外部点按造成等待回调的流程悬死。
+ (void)ame240_presentMenu:(UIMenu *)menu
                sourceView:(UIView *)sourceView
                onDismiss:(nullable void (^)(void))onDismiss;

/// 便捷构造：菜单项字典数组 → UIMenu。
/// 字典协议与 Task223 ame223_accountMenuItemsAtIndexPath 同源并扩展：
///   @"title"       NSString（必填）
///   @"systemImage" NSString SF Symbol 名（可选，缺省无图标）
///   @"destructive" BOOL（可选，YES = 红字破坏性）
///   @"handler"     void(^)(void)（可选）
///   @"subitems"    NSArray<NSDictionary *>（可选，嵌套子菜单）
///   @"cancel"      BOOL（可选，YES = 该项被丢弃——系统菜单点按外部
///                  即消失，不需要取消项；兼容旧调用点直迁）
/// @param title 菜单标题（账号名等；传 nil 则无标题区）
+ (UIMenu *)ame240_menuWithTitle:(nullable NSString *)title
                       dictItems:(NSArray<NSDictionary *> *)items;

/// 一站式便捷入口：构建 + 呈现。
+ (void)ame240_presentMenuWithTitle:(nullable NSString *)title
                          dictItems:(NSArray<NSDictionary *> *)items
                         sourceView:(UIView *)sourceView;

/// 一站式便捷入口（带消失回调，语义同 ame240_presentMenu:onDismiss:）。
+ (void)ame240_presentMenuWithTitle:(nullable NSString *)title
                          dictItems:(NSArray<NSDictionary *> *)items
                         sourceView:(UIView *)sourceView
                          onDismiss:(nullable void (^)(void))onDismiss;

@end

NS_ASSUME_NONNULL_END
