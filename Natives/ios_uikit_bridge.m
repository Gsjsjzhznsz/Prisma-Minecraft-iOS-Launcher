#import "authenticator/BaseAuthenticator.h"
#import "AppDelegate.h"
#import "SceneDelegate.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherSplitViewController.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"

#include <objc/runtime.h>
#include "ios_uikit_bridge.h"
#include "utils.h"

void internal_showDialog(NSString* title, NSString* message) {
    NSLog(@"[UI] Dialog shown: %@: %@", title, message);

    UIAlertController* alert = [UIAlertController alertControllerWithTitle:title
        message:message
        preferredStyle:UIAlertControllerStyleAlert];
    //text.dataDetectorTypes = UIDataDetectorTypeLink;
    // Task 126：OK 后必须回收承载 window。旧实现 handler 为 nil——alert 消失
    // 但 level-1000 的新 window 泄漏在场并占着 key window，用户被迫"手动删
    // 系统弹窗"（5.1.0 实测反馈：正版登录提示弹窗关不掉）。修复：记下原
    // key window，OK 时隐藏弹窗 window 并把 key 交还原窗口。
    UIWindow *previousKeyWindow = UIWindow.mainWindow;
    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction * action) {
        UIWindow *w = objc_getAssociatedObject(alert, @selector(alertWindow));
        if (w) {
            w.hidden = YES;
            if (previousKeyWindow && previousKeyWindow != w) {
                [previousKeyWindow makeKeyAndVisible];
            }
        }
    }];
    [alert addAction:okAction];

    UIWindow *alertWindow = [[UIWindow alloc] initWithWindowScene:UIWindow.mainWindow.windowScene];
    alertWindow.frame = UIScreen.mainScreen.bounds;
    alertWindow.rootViewController = [UIViewController new];
    alertWindow.windowLevel = 1000;
    [alertWindow makeKeyAndVisible];
    objc_setAssociatedObject(alert, @selector(alertWindow), alertWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
}

void showDialog(NSString* title, NSString* message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        internal_showDialog(title, message);
    });
}

// Task187（keychain 凭据丢失一键修复）：Task185 把死循环弹窗改成了去重 +
// 文案指引（"请删除该账号后重新登录"），但用户仍需手动完成
// 账号列表 → 滑动删除 → 添加账号 → 登录 四步导航。本弹窗提供一步出路：
// 「删除账号并重新登录」→ 就地删除账号 .json 与 keychain 残留 → 拉起账号
// 管理页（登录入口）。launchGame 的 pendingLaunchAfterLogin 链在登录成功
// 后自动接续启动（RightPanel 已有的机制，此处零新增状态）。
void ame187_showAccountRepairDialog(NSString *username, NSString *accountId, NSString *xuid) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController
            alertControllerWithTitle:localize(@"Error", nil)
                             message:[NSString stringWithFormat:
                localize(@"ame189.uikit.account_repair_msg", nil),
                username ?: @"?", username ?: @"?"]
                      preferredStyle:UIAlertControllerStyleAlert];
        UIWindow *previousKeyWindow = UIWindow.mainWindow;
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_2071", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            // 与 AccountListViewController 滑动删除同一套语义：
            // accounts/{accountId}.json + keychain 条目 + selected_account 修正
            NSString *aid = accountId.length > 0 ? accountId : (username ?: @"");
            if (aid.length > 0) {
                NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("POJAV_HOME"), aid];
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
                NSLog(@"[Task187] account repair: removed %@ (keychain residue cleared next login)", path);
            }
            if (xuid.length > 0) {
                // Task187 修复：BaseAuthenticator.h（本文件第 1 行已导入）直接声明了
                // MicrosoftAuthenticator 类与 +clearTokenDataOfProfile: 类方法，
                // 与 AccountListViewController 滑动删除（同文件 619 行）同一调用形式。
                // 直调替代此前的 objc_msgSend 动态派发——后者漏 <objc/message.h>
                // 声明，曾致 CI af86509 构建失败（84:45 implicit function decl）。
                [MicrosoftAuthenticator clearTokenDataOfProfile:xuid];
                NSLog(@"[Task187] account repair: keychain entry cleared for xuid %@", xuid);
            }
            // 若删除的正是当前选中账户，清空选中态（与列表删除一致）
            if ([getPrefObject(@"internal.selected_account") isEqualToString:aid]) {
                setPrefObject(@"internal.selected_account", @"");
                [BaseAuthenticator setCurrent:nil];
            }
            // 关闭承载 window 并还原 key window
            UIWindow *w = objc_getAssociatedObject(alert, @selector(alertWindow));
            if (w) {
                w.hidden = YES;
                if (previousKeyWindow && previousKeyWindow != w) {
                    [previousKeyWindow makeKeyAndVisible];
                }
            }
            // 拉起账号管理页（登录入口）；启动链的 pendingLaunchAfterLogin
            // 在登录成功后自动接续（如本次修复发生在启动流程中）
            [[NSNotificationCenter defaultCenter] postNotificationName:@"ShowAccountManager" object:nil];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil)
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            UIWindow *w = objc_getAssociatedObject(alert, @selector(alertWindow));
            if (w) {
                w.hidden = YES;
                if (previousKeyWindow && previousKeyWindow != w) {
                    [previousKeyWindow makeKeyAndVisible];
                }
            }
        }]];

        UIWindow *alertWindow = [[UIWindow alloc] initWithWindowScene:UIWindow.mainWindow.windowScene];
        alertWindow.frame = UIScreen.mainScreen.bounds;
        alertWindow.rootViewController = [UIViewController new];
        alertWindow.windowLevel = 1000;
        [alertWindow makeKeyAndVisible];
        objc_setAssociatedObject(alert, @selector(alertWindow), alertWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

// Task173：gJvmUsedInProcess 的出路弹窗（“Forge 安装后启动游戏弹 java
// runtime 问题，重启刷新 jit 状态就好”根修的 UI 侧）。
// 机制：进程内 JVM 只能创建一次——Forge/NeoForge 安装器（headless JVM）跑
// 过之后，本进程再 JLI_Launch 必崩。旧实现死路弹窗（“请重启启动器再启动
// 游戏”，用户手动重启 + 重新导航 + 重新点启动）。现在提供一键出路：
// 「重启并启动」→ 写 internal.autolaunch_profile 偏好 → 2 秒后 exit(0)；
// 下次冷启时 LauncherRightPanelViewController 检测该键 → 自动选中该实例
// 并触发 launchGame（JIT 等待链照常接管，与用户手动流程完全一致）。
void ame173_showJvmUsedRestartDialog(NSString *profileName) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"ame189.uikit.restart_title", nil)
            message:[NSString stringWithFormat:
                localize(@"ame189.uikit.restart_msg", nil),
                profileName ?: @"", profileName ?: @""]
            preferredStyle:UIAlertControllerStyleAlert];
        // Task173 CI 修复：previousKeyWindow 必须在 action 捕获之前声明
        //（旧顺序：Cancel handler 引用后才声明 = undeclared identifier）。
        UIWindow *previousKeyWindow = UIWindow.mainWindow;
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                                  style:UIAlertActionStyleCancel
                                                handler:^(UIAlertAction *action) {
            UIWindow *w = objc_getAssociatedObject(alert, @selector(alertWindow));
            if (w) {
                w.hidden = YES;
                if (previousKeyWindow && previousKeyWindow != w) {
                    [previousKeyWindow makeKeyAndVisible];
                }
            }
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"ame189.uikit.restart_button", nil)
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *action) {
            if (profileName.length > 0) {
                setPrefObject(@"internal.autolaunch_profile", profileName);
            }
            NSLog(@"[Task173] autolaunch armed for '%@' -- exiting in 2s", profileName);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                exit(0);
            });
        }]];
        UIWindow *alertWindow = [[UIWindow alloc] initWithWindowScene:UIWindow.mainWindow.windowScene];
        alertWindow.frame = UIScreen.mainScreen.bounds;
        alertWindow.rootViewController = [UIViewController new];
        alertWindow.windowLevel = 1000;
        [alertWindow makeKeyAndVisible];
        objc_setAssociatedObject(alert, @selector(alertWindow), alertWindow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [alertWindow.rootViewController presentViewController:alert animated:YES completion:nil];
    });
}

JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_showError(JNIEnv* env, jclass clazz, jstring title, jstring message, jboolean exitIfOk) {
    const char *title_c = (*env)->GetStringUTFChars(env, title, 0);
    const char *message_c = (*env)->GetStringUTFChars(env, message, 0);
    NSString *title_o = @(title_c);
    NSString *message_o = @(message_c);
    (*env)->ReleaseStringUTFChars(env, title, title_c);
    (*env)->ReleaseStringUTFChars(env, message, message_c);

    if (SurfaceViewController.isRunning) {
        NSLog(@"%@\n%@", title_o, message_o);
        [PLLogOutputView handleExitCode:1];
        return;
    }

dispatch_async(dispatch_get_main_queue(), ^{

    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:title_o message:message_o
        preferredStyle:UIAlertControllerStyleAlert];
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.alignment = NSTextAlignmentLeft;

    NSMutableAttributedString *atrStr = [[NSMutableAttributedString alloc] initWithString:message_o attributes:@{NSParagraphStyleAttributeName:style,NSFontAttributeName:[UIFont systemFontOfSize:13.0]}];

    [alert setValue:atrStr forKey:@"attributedMessage"];

    UIAlertAction* okAction = [UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * action) {
            if (exitIfOk == JNI_TRUE) {
                exit(-1);
            }
        }];
    [alert addAction:okAction];
    
    UIAlertAction* copyAction = [UIAlertAction actionWithTitle:localize(@"ame202.common.copy", @"Copy") style:UIAlertActionStyleDefault
        handler:^(UIAlertAction * action) {
            UIPasteboard.generalPasteboard.string = message_o;
            if (exitIfOk == JNI_TRUE) {
                exit(-1);
            }
        }];
    [alert addAction:copyAction];
    
    [currentVC() presentViewController:alert animated:YES completion:nil];
});
}

jstring UIKit_accessClipboard(JNIEnv* env, jint action, jbyteArray copySrc) {
    if (action == CLIPBOARD_PASTE) {
        // paste request
        if (UIPasteboard.generalPasteboard.hasStrings) {
            return (*env)->NewStringUTF(env, [UIPasteboard.generalPasteboard.string UTF8String]);
        } else {
            return (*env)->NewStringUTF(env, "");
        }
    } else if (action == CLIPBOARD_COPY) {
        // copy request
        const char* copySrcC = (*env)->GetByteArrayElements(env, copySrc, 0);
        if (copySrcC) {
            UIPasteboard.generalPasteboard.string = @(copySrcC);
            (*env)->ReleaseByteArrayElements(env, copySrc, copySrcC, 0);
        }
        return NULL;
    } else {
        // unknown request
        NSLog(@"Warning: unknown clipboard action: %x", action);
        return NULL;
    }
}

// Task172：版本级 TouchController 自动配置（用户指令"顺便自动配置设置
//（udp 模式，屏蔽控件）"）。当前 profile 的 touchController 键为 YES 时，
// 启动前把全局三项自动配好：control.mod_touch_enable=YES、
// control.mod_touch_mode=1（UDP）、control.mod_touch_hide_controls=YES
//（Task140 语义：只隐藏启动器自身控件层，模组自己的虚拟按钮保留）。
// 键缺失/NO 时【不碰】全局设置（用户可能在全局 TouchController 页单独
// 配置过，关闭实例开关不应破坏它）。SurfaceViewController 的
// ame139_modControlsHidden 与 UDP 触摸转发在游戏进程内实时读这些键，
// 此处只需在换根 VC 前落值。
static void ame172_applyProfileTouchController(void) {
    @autoreleasepool {
        NSString *profName = PLProfiles.current.selectedProfileName;
        NSDictionary *prof = profName ? PLProfiles.current.profiles[profName] : nil;
        BOOL on = [prof isKindOfClass:NSDictionary.class] && [prof[@"touchController"] boolValue];
        if (on) {
            // ★ Task223（用户报“手动关闭后又被强制开启”）：全局 TouchController
            //   页手动关闭过的会话（哨兵 control.mod_touch_user_off=YES）不再
            //   被启动时自动配置顶回 ON——那是用户明确的意图，profile 开关
            //   只在用户没有全局表态时才生效（手动重新开启会撤哨兵）。
            if (getPrefBool(@"control.mod_touch_user_off")) {
                NSLog(@"[TouchController] Task172 profile '%@' auto-config SKIPPED (user turned TouchController off globally -- not re-enabling)",
                      profName);
                return;
            }
            setPrefBool(@"control.mod_touch_enable", YES);
            setPrefObject(@"control.mod_touch_mode", @1);  // UDP 协议
            setPrefBool(@"control.mod_touch_hide_controls", YES);
            NSLog(@"[TouchController] Task172 profile auto-config applied for '%@' (enable=1 mode=UDP hideControls=1)",
                  profName);
        } else {
            NSLog(@"[TouchController] Task172 profile '%@' TouchController off -- global settings untouched",
                  profName);
        }
    }
}

void UIKit_launchMinecraftSurfaceVC(UIWindow* window, NSDictionary* metadata) {
    // Leave this pref, might be useful later for launching with Quick Actions/Shortcuts/URL Scheme
    //setPreference(@"internal_launch_on_boot", getPreference(@"restart_before_launch"));
    BaseAuthenticator *currentAuth = BaseAuthenticator.current;
    // selected_account 存储 accountId（唯一标识），确保重启后能按 accountId 恢复登录状态
    setPrefObject(@"internal.selected_account", currentAuth.authData[@"accountId"]);
    // Task172：版本级 TouchController 自动配置（必须在 SurfaceViewController
    // 读控件/触摸偏好之前落值——本函数是两条启动路径共用的换根入口）
    ame172_applyProfileTouchController();
    // Task183（JIT 二级菜单卡死终章）：换根 VC 不再包在 UIView 动画的
    // completion 里。病历（59d4b48 装机 latestlog.1，RightPanel 启动，
    // Task182 同步化修复后）：JIT 等待链全程健康（wait begin -> openURL
    // -> 后台化 -> condition satisfied 3.0s），但主队列续接块静默丢失、
    // 游戏零启动日志 = 卡死；同构建的另两个会话（latestlog.txt/
    // latestlog.old.txt）同一代码成功。Task182 已修 dismiss 族悬空，这里
    // 是启动链上【最后一个 completion 依赖】：后台态下动画时钟冻结，
    // [UIView animateWithDuration:completion:] 与 presentViewController 同族
    // —— completion 可能永不回调，SurfaceViewController 永远建不出来。
    // 修法：同步直接换根（换根本身不依赖动画），淡入淡出视觉降级为异步
    // fire-and-forget（alpha 动画只影响观感，不再阻塞正确性）。
    NSLog(@"[SurfaceSwap] Task183 launching SurfaceViewController (synchronous root swap; version=%@)",
          metadata[@"version"]);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (tmpRootVC == nil) {
            tmpRootVC = window.rootViewController;
        }
        window.rootViewController = [[SurfaceViewController alloc] initWithMetadata:metadata];
        [window makeKeyAndVisible];
        // 视觉淡入 fire-and-forget（无 completion 依赖）
        window.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{
            window.alpha = 1;
        }];
    });
}

void UIKit_returnToSplitView() {
    // Researching memory-safe ways to return from SurfaceViewController to the split view
    // so that the app doesn't close when quitting the game (similar behaviour to Android)
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIWindow.mainWindow;

        // Return from JavaGUIViewController
        if ([window.rootViewController isKindOfClass:LauncherSplitViewController.class]) {
            [currentVC() dismissViewControllerAnimated:YES completion:nil];
            return;
        }

        // Return from SurfaceViewController
        // Task183：同 launchMinecraftSurfaceVC —— 同步换根，动画 fire-and-forget
        //（后台态动画 completion 悬空风险，与 JIT 启动链同族病灶）。
        NSLog(@"[SurfaceSwap] Task183 returning to split view (synchronous root swap)");
        if (tmpRootVC) {
            window.rootViewController = tmpRootVC;
            tmpRootVC = nil;
        } else {
            window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
        }
        [window makeKeyAndVisible];
        window.alpha = 0;
        [UIView animateWithDuration:0.2 animations:^{
            window.alpha = 1;
        }];
    });
}

void launchInitialViewController(UIWindow *window) {
    window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
#if 0
    if (getPrefBool(@"internal.internal_launch_on_boot")) {
        window.rootViewController = [[SurfaceViewController alloc] init];
    } else {
        window.rootViewController = [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    }
#endif
}
