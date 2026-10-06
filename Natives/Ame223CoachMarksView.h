#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// ★ Task223 引入、Task224（反馈 #15）重建：zl2 风格灰屏圆圈焦点介绍。
///
/// Task223 版病历（用户原话：“现在是黑色的，完全不透明，一点透明度都没
/// 有，介绍内容也太少”）：镂空是用【不透明黑色 CAShapeLayer 画在 0.62
/// 黑幕之上】实现的——形状层把整屏涂黑、只留圆洞，等效全屏不透明黑；
/// 内容只有三页且每页一句话。
///
/// Task224 重建要点（zl2 引导层同款观感）：
///   - 蒙层 = 独立 dim 视图（黑色 45% 透明度，壁纸/下层界面真实透出），
///     圆/圆角矩形镂空用 layer.mask 实现（真透明洞，不是画黑块）；
///   - 镂空外圈呼吸光晕（描边 + 白色柔光阴影）；
///   - 说明卡 = 毛玻璃材质卡（systemMaterial + 24pt 连续圆角），
///     标题 + 2-3 行正文；
///   - 底部 Next 按钮 + 右上 Skip 按钮 + 页点指示（点按任意处也可前进）；
///   - showFeatureSequence：无需真实界面锚点的特性页序列——大图标圆盘
///     居中偏上充当焦点目标，圆圈镂空打在圆盘上。
@interface Ame223CoachMarksView : UIView

/// 锚点序列（真实界面元素）：items 每项 {rect: NSValue(CGFilledRect)
/// （屏幕坐标）, title: NSString, body: NSString, round: @(BOOL)
/// （圆圈/圆角矩形高亮）}。传入空数组时直接回调 completion。
+ (void)showSequence:(NSArray<NSDictionary *> *)items
          completion:(void(^)(void))completion;

/// Task224 特性页序列：items 每项 {icon: NSString（SF Symbol 名）,
/// title: NSString, body: NSString}。圆盘焦点居中，页面内容依次展示。
+ (void)showFeatureSequence:(NSArray<NSDictionary *> *)items
                 completion:(void(^)(void))completion;

/// 便捷锚点：视图在窗口内的包围盒（convert 后取屏幕坐标）。view 不在
/// 窗口上时返回 CGRectNull（调用方应剔除该锚点）。
+ (CGRect)screenRectForView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
