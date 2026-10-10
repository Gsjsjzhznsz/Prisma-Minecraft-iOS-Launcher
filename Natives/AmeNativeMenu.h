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
//  兼容性：UIContextMenuInteraction iOS 13+，presentMenu iOS 14+（项目
//  最低部署 iOS 14.0，无需 @available 门）；全程公开 API，无 KVC/私有
//  选择器（Task239 KVC 炸弹家族教训）。
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

@end

NS_ASSUME_NONNULL_END
