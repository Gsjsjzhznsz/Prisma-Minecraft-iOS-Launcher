//
//  GameMenuOverlayView.h
//  Amethyst
//
//  参照 FCL MenuView 与 ZL2 GameScreen 的悬浮按钮设计：
//  - 可拖拽的圆形设置按钮（位置持久化），替代原来的右滑条带
//  - 可拖拽的 FPS/内存显示标签（位置持久化），可通过菜单开关
//  - 点击设置按钮触发回调（打开菜单）
//  - hitTest 穿透：只有按钮/标签区域拦截触摸，其他区域穿透到游戏画面
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 游戏内悬浮覆盖层：设置按钮 + FPS/内存显示
/// 参照 FCL MenuView.java 与 ZL2 GameScreen.kt 的悬浮按钮设计
@interface GameMenuOverlayView : UIView

/// 设置按钮点击回调（打开菜单）
@property (nonatomic, copy, nullable) void (^onMenuButtonTapped)(void);

/// 显示/隐藏整个覆盖层（FCL 的 hideMenuView 概念）
@property (nonatomic, assign) BOOL overlayHidden;

/// 是否显示 FPS/内存统计标签（可通过菜单开关，参照 FCL）
@property (nonatomic, assign) BOOL statsLabelVisible;

/// 初始化并添加到指定父视图
- (instancetype)initWithParentView:(UIView *)parentView;

/// 更新 FPS 和内存显示（由游戏循环驱动，调用频率建议 500ms~1s）
/// 必须在主线程调用
- (void)updateFPS:(NSInteger)fps memoryUsageMB:(double)memoryMB;

/// 从偏好加载持久化的位置
- (void)restorePositions;

/// 保存当前位置到偏好
- (void)savePositions;

/// 切换 FPS/内存显示的开关状态
- (void)toggleStatsLabel;

/// ★ Task227（反馈 #8）：齿轮是否吸边成侧边栏把手（近边拖拽结束时吸附）
@property (nonatomic, assign, readonly) BOOL isDocked;

/// ★ Task227：吸边在哪一侧（YES=左，NO=右；仅 isDocked 时有意义）
@property (nonatomic, assign, readonly) BOOL dockedLeft;

@end

NS_ASSUME_NONNULL_END
