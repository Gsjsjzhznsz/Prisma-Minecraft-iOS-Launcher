#import <UIKit/UIKit.h>
#import "UIKit+hook.h"

#import "customcontrols/ControlLayout.h"
#import "GameSurfaceView.h"
#import "PLLogOutputView.h"

BOOL canAppendToLog;
dispatch_group_t fatalExitGroup;

CGRect virtualMouseFrame;
CGPoint lastVirtualMousePoint;

@interface SurfaceViewController : UIViewController

@property(nonatomic) ControlLayout *ctrlView;
@property(nonatomic) GameSurfaceView* surfaceView;
@property(nonatomic) UIView *touchView;
@property UIImageView* mousePointerView;
@property(nonatomic) UIPanGestureRecognizer* scrollPanGesture;

@property(nonatomic) UIView* rootView;

- (instancetype)initWithMetadata:(NSDictionary *)metadata;
- (void)sendTouchPoint:(CGPoint)location withEvent:(int)event;
- (void)updateSavedResolution;
- (void)updateGrabState;

+ (GameSurfaceView *)surface;
+ (BOOL)isRunning;
// 获取当前显示的 SurfaceViewController 实例
// 支持作为 rootViewController 或以模态方式呈现两种情况
+ (instancetype)currentInstance;

// LogView category
@property(nonatomic) PLLogOutputView* logOutputView;

// Navigation category
@property(nonatomic) NSArray *menuArray;
// ★ Task237：游戏内菜单面板重写为自定义 UIView（原 UITableView + “往表里
// 塞玻璃层”的补丁路线退役——分层自控：底色永不清空、内容恒在磨砂之上）。
@property(nonatomic) UIView *menuView;
// ★ Task285：游戏内菜单转置容器——menuView/menuDimView 的宿主，⊥ 旋转态
//   由 ame267_rescaleViewStackToSize 与 gameMenuOverlay 同参跟转（同角
//   transform + 转置逻辑 bounds + center 对齐），菜单面板在容器内按逻辑
//   口径铺排 = 与游戏内容同向（"菜单设置不跟随方向"根修）；非 ⊥ 恒等
//   复位 + frame 铺满，全屏语义与直挂 self.view 逐字节一致。
@property(nonatomic) UIView *menuCanvas;
@property(nonatomic) UIScreenEdgePanGestureRecognizer* edgeGesture;
@property(nonatomic) UIView *gameMenuOverlay; // FCL 风格悬浮按钮 + FPS/内存显示

@end

@interface SurfaceViewController(ExternalDisplay)

- (void)switchToExternalDisplay;
- (void)switchToInternalDisplay;

@end

@interface SurfaceViewController(LogView)

- (void)viewWillTransitionToSize_LogView:(CGRect)frame;

@end

@interface SurfaceViewController(Navigation)<UIGestureRecognizerDelegate, UITableViewDataSource, UITableViewDelegate>

- (void)actionOpenNavigationMenu;
- (void)didSelectMenuItem:(int)item;
- (void)viewWillTransitionToSize_Navigation:(CGRect)frame;
// FCL 风格游戏内菜单动作
- (void)actionToggleControls;        // 隐藏/显示控制按钮
- (void)actionToggleVirtualMouse;    // 虚拟鼠标开关
- (void)actionToggleKeyboard;        // 游戏内键盘开关
- (void)actionAdjustResolution;      // 分辨率调整
- (void)actionOpenMultiplayer;       // 联机（ZeroTier）

@end
