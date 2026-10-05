#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// ★ Task223（清单第 16 项）：zl2 风格灰屏圆圈焦点介绍（coach marks）。
/// 用户指令原文：“恢复欢迎界面打开关于页前面再插入类似于 zl2 的灰屏圆圈
/// 焦点介绍”。Task222 版做成了特性列表页（且装机黑屏不可用）——本轮
/// 重建为真正的焦点引导层：半透明灰幕 + 圆圈镂空高亮目标区域 + 说明
/// 卡片，点按任意处进入下一焦点，全部走完回调 completion（随后再打开
/// 关于页——顺序与用户描述一致：向导完成 → 焦点介绍 → 关于页）。
@interface Ame223CoachMarksView : UIView

/// items 每项：{rect: NSValue(CGFilledRect)（屏幕坐标）, title: NSString,
///             body: NSString, round: @(BOOL)（圆圈/圆角矩形高亮）}
/// 传入空数组时直接回调 completion（不呈现）。
+ (void)showSequence:(NSArray<NSDictionary *> *)items
          completion:(void(^)(void))completion;

/// 便捷锚点：视图在窗口内的包围盒（convert 后取屏幕坐标）。view 不在
/// 窗口上时返回 CGRectNull（调用方应剔除该锚点）。
+ (CGRect)screenRectForView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
