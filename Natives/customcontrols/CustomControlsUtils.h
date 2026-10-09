#import <UIKit/UIKit.h>
#import "ControlButton.h"

#define BTN_RECT 80.0, 30.0
#define BTN_SQUARE 50.0, 50.0

NSMutableDictionary* createButton(NSString* name, int* keycodes, NSString* dynamicX, NSString* dynamicY, CGFloat width, CGFloat height);
NSMutableDictionary* createGamepadButton(NSString* name, int gamepad_button, int keycode);
UIColor* convertARGB2UIColor(int argb);
int convertUIColor2ARGB(UIColor* color);
int convertUIColor2RGB(UIColor* color);
BOOL convertLayoutIfNecessary(NSMutableDictionary* dict);
void generateAndSaveDefaultControl();
void generateAndSaveCustomControl();
void generateAndSaveDefaultControlForGamepad();
/// Task 64（恢复默认控件）：强制重建出厂布局文件。
/// 删除 $POJAV_HOME/controlmap/default.json 与 custom.json 后从出厂来源重新生成
/// （default.json = 程序化 v5 布局；custom.json = App Bundle 内置模板），
/// 并把当前档案/偏好 defaultTouchCtrl 复位为 default.json。
/// 返回 nil = 成功；非 nil = 错误描述（调用方用 showDialog 展示）。
/// 与 generateAndSaveCustomControl 的区别：后者只在文件不存在时复制（升级 App
/// 不会刷新旧布局——这正是 Task 63 模板升级后旧布局残留的根源），本函数是
/// 显式的“恢复出厂”，永远覆盖重建。
NSString* restoreDefaultCustomControl();
void loadControlObject(UIView* targetView, NSMutableDictionary* controlDictionary);

/// Task233（反馈 #1 纠偏）：视图是否为纯装饰控件（背景板）——供
/// SurfaceViewController 的重叠取证复用 ame83b 同一判定（单一事实源，
/// 不在调用方重写粗糙版）。非 ControlButton 一律返回 NO。
BOOL ame233_viewIsDecorativeControlButton(UIView *view);

void initKeycodeTable(NSMutableArray* keyCodeMap, NSMutableArray* keyValueMap);
