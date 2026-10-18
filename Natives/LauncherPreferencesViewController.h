#import <UIKit/UIKit.h>
#import "PLPrefTableViewController.h"

@interface LauncherPreferencesViewController : PLPrefTableViewController <UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIColorPickerViewControllerDelegate>

// Task156：深链目标键（右侧边栏信息卡点击直达）。设置后，viewDidAppear 会
// 滚动到 prefContents 中首个 key 匹配的行并高亮闪一下；nil = 普通打开。
// 已知目标：check_update / jit_enabler / memory_limit_help。
@property (nonatomic, copy, nullable) NSString *ameDeepLinkKey;

// ★ Task286（"游戏过程中调节启动器设置不会立即生效"根修）：游戏内呈现
//   标记——SurfaceViewController+Navigation actionOpenPreferences 置 YES；
//   viewWillDisappear 据此回调 presenter 的 applyInGamePreferenceChanges
//   （对齐上游 PocketJ 的 presentedInGame 机制）。默认 NO = 启动器内
//   旧 updatePreferenceChanges 语义不变。
@property (nonatomic, assign) BOOL presentedInGame;

@end
