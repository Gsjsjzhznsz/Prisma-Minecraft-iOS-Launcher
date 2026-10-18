#pragma once
#import <UIKit/UIKit.h>
#include "jni.h"

#define CLIPBOARD_COPY 2000
#define CLIPBOARD_PASTE 2001

UIViewController* tmpRootVC;

void showDialog(NSString* title, NSString* message);
// Task173：gJvmUsedInProcess（安装器占用进程内 JVM）出路弹窗——「重启并启动」
// 写 internal.autolaunch_profile 后 exit(0)，下次冷启由 RightPanel 自动启动。
void ame173_showJvmUsedRestartDialog(NSString *profileName);
// Task187：keychain 凭据丢失一键修复弹窗——删除账号（.json + keychain 残留）
// 并拉起账号管理页登录入口（登录成功后启动链自动接续）。
void ame187_showAccountRepairDialog(NSString *username, NSString *accountId, NSString *xuid);
// Task294：内置 JIT 失败双选弹窗（专用 level-1000 window 承载，JIT 等待环
// 存续期间也可弹出）。fallbackTitle 为空则只显示 OK（同 showDialog）；
// 否则展示「fallbackTitle / Cancel」双 action，点 fallback 执行 fallbackBlock。
void ame294_showJITActionDialog(NSString *title, NSString *message,
                                NSString *fallbackTitle, void (^fallbackBlock)(void));
// Task295：同上 + 取消回调——装机实锤点取消的语义是"终止 JIT 等待环"
// （旧版取消被吞，等待环只能耗到 120s 超时）。cancelBlock 可空。
void ame294_showJITActionDialogEx(NSString *title, NSString *message,
                                  NSString *fallbackTitle, void (^fallbackBlock)(void),
                                  void (^cancelBlock)(void));
jstring UIKit_accessClipboard(JNIEnv* env, jint action, jstring copySrc);
void UIKit_launchMinecraftSurfaceVC(UIWindow *window, NSDictionary *metadata);
void UIKit_returnToSplitView();
void launchInitialViewController(UIWindow *window);

void AWTInputBridge_sendKey(int keycode);
