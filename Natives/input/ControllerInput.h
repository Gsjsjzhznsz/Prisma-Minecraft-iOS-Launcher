#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

@interface ControllerInput : NSObject

+ (void)initKeycodeTable;
+ (void)registerControllerCallbacks:(GCController *)controller;
+ (void)unregisterControllerCallbacks:(GCController *)controller;
/// ★ Task310（手柄优化）：手柄断连时释放全部"由手柄按住"的键鼠状态——
///   病历：unregister 只摘 handler，若断连瞬间 W/A/S/D、潜行、鼠标键
///   正处按下态，游戏侧永远等不到 UP = 角色一直走/一直潜行。
///   本方法直接向 native 层补发全量 UP（与映射表无关，因为左手摇杆
///   WASD 本就不走映射），并复位虚拟鼠标与八方向锁存。
+ (void)releaseAllHeld;
+ (void)tick;
/// ★ Task310：模拟滚轮步进统一乘以 control.scroll_speed 系数（触屏布局
///   滚动按钮与手柄滚动键共用；真硬件外设不经过此口）。
+ (CGFloat)scrollStep:(CGFloat)baseStep;

@end
