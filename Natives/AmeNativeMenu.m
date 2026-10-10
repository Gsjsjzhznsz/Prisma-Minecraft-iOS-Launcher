//
//  AmeNativeMenu.m
//  Amethyst
//
//  ★ Task240：统一菜单呈现器（字典协议单一事实源，设计契约见
//    AmeNativeMenu.h）。呈现路径演进：
//    - Task240：系统 UIContextMenu/UIMenu 程序化呈现（私有 presentMenu
//      裸调）——真机 iOS 26 unrecognized selector 全崩（Task241）；
//    - Task241/241-ci：运行时探测 + 三级降级（presentMenu →
//      _presentMenuAtLocation: → actionSheet）+ 字典协议直驱拍平；
//    - ★ Task242（用户装机实测推翻程序化系统菜单主路径）：
//      ① "魔改的悬浮弹窗用在联机菜单等地方是非常好的，等你适配" +
//        "为什么毛玻璃效果没有生效（游戏内菜单/内存设置）"——程序化
//        呈现的系统上下文菜单在真机上的材质不是用户要的玻璃；
//      ② "界面风格在为原生的时候还是使用的液态玻璃"——原生档走
//        系统 UIContextMenu 仍是 iOS 26 系统玻璃材质，名实不符。
//      【Task242 定案：菜单呈现按界面风格分轨】
//      玻璃档 → AmeFloatingMenu 真液态玻璃面板（UIGlassEffect，Task237/239
//      既有组件，用户实测"非常好"）接管全部菜单；
//      原生档 → 旧版系统 actionSheet 直通（Task237 契约"原生 = 旧版
//      弹窗"），绝不经系统 UIContextMenu。
//      私有 API 三级降级链（presentMenu/_presentMenuAtLocation: 类目
//      声明 + 运行时探测）随之整体退役——全链回归公开 API +
//      UIAlertController(actionSheet) 数据源 + Task237 组件渲染。
//    - ★ Task245（IMG_0380 用户定案"这些选择项就应该使用系统原生的
//      液态玻璃" + "这透视有问题吧"）：玻璃档按【锚点域】重新分轨——
//      ①启动器内选择菜单 → 系统原生液态玻璃直出（Task241 三级降级链
//      复活：presentMenu 探测 → _presentMenuAtLocation: → 字典
//      actionSheet 兜底，玻璃档兜底由磨砂面板接管；IMG_0370 基准）；
//      ②Metal 游戏面（SurfaceViewController 层级/gameMenuOverlay）→
//      保持魔改快照磨砂面板（系统上下文菜单磨砂在 Metal 上不合成，
//      Task228/230/236 三轮装机实锤同族）；③魔改磨砂面板专属域 =
//      输入类弹窗（内存数值输入等中央路由 UIAlertController 接管不变；
//      快照显示改窗口对位真透视，见 AmeFloatingMenu Task245）。
//    - ★ Task246（用户指令：“在界面风格再添加一个伪液态玻璃，把之前写的
//      魔改玻璃用上去。新添在一开始的欢迎界面供用户选择并提供预览”）：
//      玻璃家族新增【伪液态玻璃档】（prisma.interface_style = pseudo_glass，
//      LGCInterfaceStylePseudoGlass）——魔改快照自绘磨砂面板全接管：启动
//      器内选择菜单也走磨砂面板（真玻璃档仅 Metal 游戏面保留该轨）；快照
//      自绘不依赖 iOS 26 能力，低版本同样可用。真液态玻璃档路由不变
//      （Task245：启动器内系统原生直出 / Metal 面磨砂面板）。欢迎向导
//      新增风格选择步骤（WelcomeViewController Task246，真实预览菜单直出）。
//    - handler 唯一合法来源 = 字典协议（公开 API）：UIAction/
//      UIAlertAction.handler 均非公开属性，从已构建 UIMenu 反取在
//      iOS 26.2 SDK 为编译错误（Task241 CI r1 :79 双雷实证），KVC
//      反取属 Task239 炸弹家族禁忌。字典快照经呈现链 dictsForFallback:
//      下传（37 处调用点全部走字典便捷入口）。
//

#import "AmeNativeMenu.h"
#import "AmeFloatingMenu.h"
#import "LiquidGlassCompat.h"
#import <objc/runtime.h>

// ★ Task245：私有呈现入口同名自声明（纯声明、无 IMP——链接期不产生
//   新选择器；消费端一律 respondsToSelector 探测 + @try 双护栏，
//   Task241 全链实证模式，绝不会 unrecognized selector 崩溃）。
@interface UIContextMenuInteraction (Ame240PresentMenuCompat)
- (void)presentMenu;
- (void)_presentMenuAtLocation:(CGPoint)location;
@end

@interface AmeNativeMenu () <UIContextMenuInteractionDelegate,
                             UIAdaptivePresentationControllerDelegate>
// 单例访问器提升为本文件可见——类方法在其 @implementation 之前被
// 静态/实例上下文引用时避免 "no known class method"（Task240 CI r1
// 同款错误家族）。
+ (instancetype)ame240_shared;
@end

/// 动作已选中标记（主线程串行访问，无竞态面）。presentationControllerDidDismiss
/// 据此区分"选中动作后关闭"（不回调）与"外部点按取消"（回调 onDismiss）。
static BOOL ame240_actionFired = NO;
/// actionSheet 呈现期间待回调的 onDismiss（原生档直通路径；主线程串行）。
static void (^ame240_fallbackDismiss)(void);
/// ★ Task245：系统菜单快照与消失回调（挂交互实例，delegate 惰性读取；
///   每次呈现前刷新——同一锚点重复呈现永远拿到最新菜单）。
static char ame240_menuSnapshotKey;
static char ame240_dismissKey;

#pragma mark - 字典协议 → UIAlertAction 拍平

/// Task241-ci 定型：字典协议 → UIAlertAction（子菜单递归降一级缩进，
/// 语义保留：destructive 红字 / disabled 置灰 / handler 透传并置已选中
/// 标记）。跨行消息表达式整体带 []（Task240-ci r4 教训：裸 continuation
/// 与 C 调用误包 [] 是括号平衡门双盲区的对偶雷）。
static void ame240_addDictItemsToAlert(NSArray<NSDictionary *> *items,
                                       NSMutableArray<UIAlertAction *> *out,
                                       NSString *prefix) {
    for (NSDictionary *ame241_it in items) {
        if (![ame241_it isKindOfClass:[NSDictionary class]]) continue;
        // cancel 项跳过：actionSheet/玻璃面板外部点按即关闭，取消语义由
        // presentationControllerDidDismiss / 面板 onDismiss 承担（同口径）。
        if ([ame241_it[@"cancel"] boolValue]) continue;
        NSString *ame241_title = ame241_it[@"title"];
        if (![ame241_title isKindOfClass:[NSString class]]) continue;

        // 子菜单（@"subitems" 非空）递归降一级缩进
        NSArray *ame241_sub = ame241_it[@"subitems"];
        if ([ame241_sub isKindOfClass:[NSArray class]] && ame241_sub.count > 0) {
            NSString *ame241_next = [prefix stringByAppendingString:@"· "];
            ame240_addDictItemsToAlert(ame241_sub, out, ame241_next);
            continue;
        }

        BOOL ame241_destructive = [ame241_it[@"destructive"] boolValue];
        BOOL ame241_disabled = [ame241_it[@"disabled"] boolValue];
        void (^ame241_handler)(void) = ame241_it[@"handler"];
        NSString *ame241_fullTitle = [prefix stringByAppendingString:ame241_title];
        UIAlertAction *ame241_aa = [UIAlertAction
            actionWithTitle:ame241_fullTitle
                      style:(ame241_destructive ? UIAlertActionStyleDestructive
                                                : UIAlertActionStyleDefault)
                    handler:^(UIAlertAction *ame241_ignored) {
                ame240_actionFired = YES;
                if (ame241_handler) ame241_handler();
            }];
        ame241_aa.enabled = !ame241_disabled;
        [out addObject:ame241_aa];
    }
}

#pragma mark - Task245 系统菜单呈现链（Task241 三级降级复活）

/// 程序化呈现降级链。返回 YES = 已呈现；NO = 双私有入口均缺失（调用方
/// 转 actionSheet 兜底）。每级 respondsToSelector 探测 + @try 双护栏：
/// presentMenu（部分 iOS 26 运行时无 IMP）→ _presentMenuAtLocation:（锚点
/// 中心；iOS 13+ 长期稳定，LauncherPrefManageJRE 同域先例）。绝不
/// unrecognized selector 崩溃（Task241 全链实证模式）。
static BOOL ame240_openInteractionMenu(UIContextMenuInteraction *ix) {
    if (ix == nil) return NO;
    if ([ix respondsToSelector:@selector(presentMenu)]) {
        @try {
            [ix presentMenu];
            return YES;
        } @catch (NSException *ame240_e) {}
    }
    if ([ix respondsToSelector:@selector(_presentMenuAtLocation:)]) {
        UIView *ame240_v = ix.view;
        if (ame240_v != nil) {
            CGPoint ame240_p = CGPointMake(CGRectGetMidX(ame240_v.bounds),
                                           CGRectGetMidY(ame240_v.bounds));
            @try {
                [ix _presentMenuAtLocation:ame240_p];
                return YES;
            } @catch (NSException *ame240_e) {}
        }
    }
    NSLog(@"[AmeNativeMenu] Task245: neither presentMenu nor _presentMenuAtLocation: responded");
    return NO;
}

/// 系统菜单双私有入口缺失时的 actionSheet 兜底（理论不可达——防未来
/// iOS 移除私有 API）。动作语义全部来自字典快照（handler 只能从字典
/// 取，见文件头）；玻璃档由磨砂面板接管（与输入类弹窗同观感，取消
/// 语义由面板 onDismiss 承接），接管失败回退直通 actionSheet（iPad
/// 必须 popover 锚定）；原生档直通（中央路由 hook 不会截胡）。无可
/// 呈现动作时按取消语义回调 onDismiss（不呈现点了没反应的空壳）。
static void ame240_actionSheetFallback(UIContextMenuInteraction *ix,
                                       UIMenu *menu,
                                       NSArray<NSDictionary *> *dicts,
                                       void (^onDismiss)(void)) {
    UIView *ame245_anchor = ix.view;
    if (ame245_anchor == nil || dicts.count == 0) {
        NSLog(@"[AmeNativeMenu] Task245: fallback unavailable (anchor=%p dicts=%lu), treated as cancel",
              ame245_anchor, (unsigned long)dicts.count);
        if (onDismiss) onDismiss();
        return;
    }
    UIResponder *ame245_r = ame245_anchor;
    while (ame245_r != nil && ![ame245_r isKindOfClass:[UIViewController class]]) {
        ame245_r = ame245_r.nextResponder;
    }
    UIViewController *ame245_host = (UIViewController *)ame245_r;
    if (ame245_host == nil || ame245_host.presentedViewController != nil) {
        if (onDismiss) onDismiss();
        return;
    }
    UIAlertController *ame245_alert = [UIAlertController
        alertControllerWithTitle:(menu.title.length > 0 ? menu.title : nil)
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSMutableArray<UIAlertAction *> *ame245_items = [NSMutableArray array];
    ame240_addDictItemsToAlert(dicts, ame245_items, @"");
    if (ame245_items.count == 0) {
        if (onDismiss) onDismiss();
        return;
    }
    for (UIAlertAction *ame245_aa in ame245_items) [ame245_alert addAction:ame245_aa];

    if (LGCIsGlassStyleActive()) {
        BOOL ame245_ok = [AmeFloatingMenu presentGlassMenuForAlert:ame245_alert
                                                     fromPresenter:ame245_host
                                                          animated:YES
                                                        completion:nil
                                                         onDismiss:onDismiss];
        if (ame245_ok) {
            NSLog(@"[AmeNativeMenu] Task245: system menu unavailable, glass panel fallback");
            return;
        }
    }
    ame240_fallbackDismiss = onDismiss;
    ame245_alert.presentationController.delegate = [AmeNativeMenu ame240_shared];
    ame245_alert.popoverPresentationController.sourceView = ame245_anchor;
    ame245_alert.popoverPresentationController.sourceRect = ame245_anchor.bounds;
    ame245_alert.popoverPresentationController.permittedArrowDirections =
        UIPopoverArrowDirectionAny;
    [ame245_host presentViewController:ame245_alert animated:YES completion:nil];
    NSLog(@"[AmeNativeMenu] Task245: system menu unavailable, stock actionSheet fallback");
}

#pragma mark - 呈现装配（Task242/245）

@implementation AmeNativeMenu

#pragma mark - Singleton

+ (instancetype)ame240_shared {
    static AmeNativeMenu *ame240_shared = nil;
    static dispatch_once_t ame240_once;
    dispatch_once(&ame240_once, ^{
        ame240_shared = [[AmeNativeMenu alloc] init];
    });
    return ame240_shared;
}

#pragma mark - 装配私有方法

/// 锚点视图 → 宿主 UIViewController（responder 链上溯；宿主已在呈现
/// 别的控制器时不覆盖，按取消语义回调由调用方处理）。
+ (UIViewController *)ame242_hostViewControllerForView:(UIView *)view {
    UIResponder *ame242_r = view;
    while (ame242_r != nil && ![ame242_r isKindOfClass:[UIViewController class]]) {
        ame242_r = ame242_r.nextResponder;
    }
    return (UIViewController *)ame242_r;
}

/// 字典快照 → actionSheet 数据源（title = 菜单标题）。返回 nil = 字典
/// 缺失/全为 cancel 或无效项（无可呈现动作，调用方按取消语义处理——
/// 不呈现"点了没反应"的空壳）。
+ (UIAlertController *)ame242_actionSheetFromDicts:(NSArray<NSDictionary *> *)dicts
                                         menuTitle:(NSString *)menuTitle {
    if (dicts.count == 0) return nil;
    UIAlertController *ame242_alert = [UIAlertController
        alertControllerWithTitle:(menuTitle.length > 0 ? menuTitle : nil)
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSMutableArray<UIAlertAction *> *ame242_items = [NSMutableArray array];
    ame240_addDictItemsToAlert(dicts, ame242_items, @"");
    if (ame242_items.count == 0) return nil;
    for (UIAlertAction *ame242_aa in ame242_items) [ame242_alert addAction:ame242_aa];
    return ame242_alert;
}

/// ★ Task245 域收窄：玻璃档磨砂面板呈现，仅服务两个域——①Metal 游戏
///   面上的选择菜单（系统上下文菜单磨砂在 Metal 上不合成，Task228/
///   230/236 同族实锤）；②系统菜单双私有入口缺失时的兜底。启动器内
///   选择菜单主路径已回归系统 UIMenu（Task245），磨砂面板专属域 =
///   输入类弹窗（中央路由 hook 接管，不经本方法）。
/// onDismiss = 未选实质动作关闭（面板内 dim 点按/cancel 项）时回调。
/// 镜像失败（理论边缘）→ presentViewController 兜底：中央路由 hook 会
/// 再次尝试玻璃接管，仍失败则直通原生 actionSheet（功能保底，取消
/// 语义由 adaptive delegate 承接）。
+ (void)ame242_presentViaGlassMenu:(UIAlertController *)alert
                              host:(UIViewController *)host
                         onDismiss:(void (^)(void))onDismiss {
    BOOL ame242_ok = [AmeFloatingMenu presentGlassMenuForAlert:alert
                                                 fromPresenter:host
                                                      animated:YES
                                                    completion:nil
                                                     onDismiss:onDismiss];
    if (ame242_ok) {
        NSLog(@"[AmeNativeMenu] Task245: glass panel route (snapshot frost, Metal domain)");
        return;
    }
    NSLog(@"[AmeNativeMenu] Task242: glass mirror failed, router passthrough");
    ame240_fallbackDismiss = onDismiss;
    alert.presentationController.delegate = [self ame240_shared];
    [host presentViewController:alert animated:YES completion:nil];
}

/// ★ Task242 原生档呈现：旧版系统 actionSheet 直通（Task237 契约
/// "原生 = 旧版弹窗"）。绝不走系统 UIContextMenu 程序化呈现——iOS 26
/// 其材质恒为系统玻璃，与原生档语义冲突（用户实测"风格为原生时还是
/// 液态玻璃"的病灶）。中央路由 hook 在原生档直透，无接管的可能。
+ (void)ame242_presentViaNativeSheet:(UIAlertController *)alert
                                view:(UIView *)anchor
                                host:(UIViewController *)host
                           onDismiss:(void (^)(void))onDismiss {
    ame240_fallbackDismiss = onDismiss;
    alert.presentationController.delegate = [self ame240_shared];
    // iPad 必须 popover 锚定（不设 sourceView 直接崩）；iPhone 忽略。
    alert.popoverPresentationController.sourceView = anchor;
    alert.popoverPresentationController.sourceRect = anchor.bounds;
    alert.popoverPresentationController.permittedArrowDirections =
        UIPopoverArrowDirectionAny;
    [host presentViewController:alert animated:YES completion:nil];
    NSLog(@"[AmeNativeMenu] Task242: native sheet route (stock style)");
}

/// ★ Task245：锚点是否处于游戏内渲染面（Metal）之上——SurfaceViewController
///   层级 / gameMenuOverlay 之内。系统上下文菜单的磨砂材质在 Metal 上
///   不合成（Task228/230/236 三轮装机实锤同族），游戏内选择菜单保持
///   魔改快照磨砂面板；启动器内一律系统原生液态玻璃。
+ (BOOL)ame245_anchorInsideGameSurface:(UIView *)view {
    UIResponder *ame245_r = view;
    while (ame245_r != nil) {
        NSString *ame245_cls = NSStringFromClass([ame245_r class]);
        if ([ame245_cls hasPrefix:@"SurfaceViewController"] ||
            [ame245_cls isEqualToString:@"GameMenuOverlayView"]) {
            return YES;
        }
        ame245_r = ame245_r.nextResponder;
    }
    return NO;
}

/// ★ Task245：启动器内选择菜单 = 系统原生液态玻璃直出（IMG_0370 基准，
///   用户定案"选择项就应该使用系统原生的液态玻璃"）。UIContextMenuInteraction
///   挂锚点视图（associated object 复用同一交互实例）+ 菜单快照/消失
///   回调随挂 + Task241 三级降级链呈现。进入本方法前外层调度已保证
///   sourceView 在窗口内（window == nil 的防御回退在外层统一处理）。
+ (void)ame245_presentViaSystemMenu:(UIMenu *)menu
                         sourceView:(UIView *)sourceView
                              dicts:(NSArray<NSDictionary *> *)dicts
                          onDismiss:(void (^)(void))onDismiss {
    static char ame245_interactionKey;
    UIContextMenuInteraction *ame245_ix =
        objc_getAssociatedObject(sourceView, &ame245_interactionKey);
    if (ame245_ix == nil) {
        ame245_ix = [[UIContextMenuInteraction alloc]
            initWithDelegate:[self ame240_shared]];
        [sourceView addInteraction:ame245_ix];
        objc_setAssociatedObject(sourceView, &ame245_interactionKey,
                                 ame245_ix, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(ame245_ix, &ame240_menuSnapshotKey, menu,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(ame245_ix, &ame240_dismissKey, onDismiss,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[AmeNativeMenu] Task245: system menu route (native liquid glass, IMG_0370)");
    if (!ame240_openInteractionMenu(ame245_ix)) {
        ame240_actionSheetFallback(ame245_ix, menu, dicts, onDismiss);
    }
}

/// Task242/245 分轨调度：host/alert 装配 → 按界面风格与锚点域选择呈现路径。
+ (void)ame242_presentStyleRoutedWithMenu:(UIMenu *)menu
                               sourceView:(UIView *)sourceView
                                    dicts:(NSArray<NSDictionary *> *)dicts
                                onDismiss:(void (^)(void))onDismiss {
    UIViewController *ame242_host = [self ame242_hostViewControllerForView:sourceView];
    UIAlertController *ame242_alert = [self ame242_actionSheetFromDicts:dicts
                                                              menuTitle:menu.title];
    if (ame242_host == nil || ame242_alert == nil ||
        ame242_host.presentedViewController != nil) {
        NSLog(@"[AmeNativeMenu] Task242: presentation unavailable (host=%@ alert=%@), treated as cancel",
              ame242_host, ame242_alert);
        if (onDismiss) onDismiss();
        return;
    }
    ame240_actionFired = NO; // 本轮会话开始，重新计数
    if (LGCIsGlassStyleActive()) {
        if (LGCIsPseudoGlassStyleActive() ||
            [self ame245_anchorInsideGameSurface:sourceView]) {
            // ★ Task246：伪液态玻璃档 = 魔改磨砂面板全接管（含启动器内选择
            //   菜单——用户指令把魔改玻璃升格为独立风格档）；真液态玻璃档下
            //   仅 Metal 游戏面保持磨砂面板（系统上下文菜单磨砂在 Metal 上
            //   不合成，Task228/230/236 三轮装机实锤同族）。
            [self ame242_presentViaGlassMenu:ame242_alert
                                        host:ame242_host
                                   onDismiss:onDismiss];
        } else {
            // ★ Task245（IMG_0380 用户定案）：真液态玻璃档启动器内选择菜单 =
            //   系统原生液态玻璃直出；磨砂面板退役到输入类弹窗专属。
            [self ame245_presentViaSystemMenu:menu
                                   sourceView:sourceView
                                        dicts:dicts
                                    onDismiss:onDismiss];
        }
    } else {
        [self ame242_presentViaNativeSheet:ame242_alert
                                      view:sourceView
                                      host:ame242_host
                                 onDismiss:onDismiss];
    }
}

#pragma mark - Public

+ (void)ame240_presentMenu:(UIMenu *)menu
                sourceView:(UIView *)sourceView {
    [self ame240_presentMenu:menu sourceView:sourceView onDismiss:nil];
}

+ (void)ame240_presentMenu:(UIMenu *)menu
                sourceView:(UIView *)sourceView
                onDismiss:(void (^)(void))onDismiss {
    // UIMenu 直构入口无字典快照（dicts=nil → actionSheetFromDicts 返回
    // nil → 按取消语义回调）。业务调用一律走
    // ame240_presentMenuWithTitle:dictItems:（唯一持有 handler 的入口；
    // 全仓唯一 UIMenu 入口调用点 Multiplayer 已于 Task241-ci 收编字典
    // 入口，37 处调用点全部统一）。
    [self ame240_presentMenu:menu sourceView:sourceView
                   onDismiss:onDismiss dictsForFallback:nil];
}

+ (void)ame240_presentMenu:(UIMenu *)menu
                sourceView:(UIView *)sourceView
                  onDismiss:(void (^)(void))onDismiss
          dictsForFallback:(NSArray<NSDictionary *> *)dicts {
    if (menu == nil || sourceView == nil) return;
    if (menu.children.count == 0) return; // 空菜单（全部项被丢弃）不呈现
    if (@available(iOS 14.0, *)) {
        // 视图尚未进窗口时防御性回退一跑循环（同帧刚构建的锚点可能
        // 尚未 layout；下帧 responder 链与 window 均就绪）。
        if (sourceView.window == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self ame242_presentStyleRoutedWithMenu:menu
                                             sourceView:sourceView
                                                  dicts:dicts
                                              onDismiss:onDismiss];
            });
        } else {
            [self ame242_presentStyleRoutedWithMenu:menu
                                         sourceView:sourceView
                                              dicts:dicts
                                          onDismiss:onDismiss];
        }
    }
    // < iOS 14 不可达（部署目标 14.0）；真出现时静默不呈现 = 不劣于现状。
}

+ (UIMenu *)ame240_menuWithTitle:(NSString *)title
                       dictItems:(NSArray<NSDictionary *> *)items {
    // Task242 后 UIMenu 仅承担 children 空校验 + 标题透传（呈现不再
    // 消费 UIMenu 树——动作语义全部来自字典快照）；构建保留以维持
    // 37 处调用点的字典协议契约与空菜单拦截。
    NSMutableArray<UIMenuElement *> *ame240_children = [NSMutableArray array];
    for (NSDictionary *ame240_it in items) {
        if (![ame240_it isKindOfClass:[NSDictionary class]]) continue;

        // Cancel 项丢弃（actionSheet/玻璃面板点按外部即消失，取消语义
        // 由 onDismiss 体系承担）
        if ([ame240_it[@"cancel"] boolValue]) continue;

        NSString *ame240_title = ame240_it[@"title"];
        if (![ame240_title isKindOfClass:[NSString class]]) continue;

        // 子菜单（@"subitems" 非空 → 递归构建嵌套 UIMenu）
        NSArray *ame240_sub = ame240_it[@"subitems"];
        if ([ame240_sub isKindOfClass:[NSArray class]] && ame240_sub.count > 0) {
            UIMenu *ame240_subMenu = [self ame240_menuWithTitle:ame240_title
                                                    dictItems:ame240_sub];
            if (ame240_subMenu != nil) [ame240_children addObject:ame240_subMenu];
            continue;
        }

        UIImage *ame240_icon = nil;
        NSString *ame240_sym = ame240_it[@"systemImage"];
        if ([ame240_sym isKindOfClass:[NSString class]] && ame240_sym.length > 0) {
            ame240_icon = [UIImage systemImageNamed:ame240_sym];
        }

        void (^ame240_handler)(void) = ame240_it[@"handler"];
        UIAction *ame240_action = [UIAction
            actionWithTitle:ame240_title
                      image:ame240_icon
                 identifier:nil
                    handler:^(__kindof UIAction *ame240_a) {
                ame240_actionFired = YES;
                if (ame240_handler) ame240_handler();
            }];
        if ([ame240_it[@"destructive"] boolValue]) {
            ame240_action.attributes = UIMenuElementAttributesDestructive;
        }
        if ([ame240_it[@"disabled"] boolValue]) {
            ame240_action.attributes |= UIMenuElementAttributesDisabled;
        }
        [ame240_children addObject:ame240_action];
    }
    return [UIMenu menuWithTitle:(title ?: @"") children:ame240_children];
}

+ (void)ame240_presentMenuWithTitle:(NSString *)title
                          dictItems:(NSArray<NSDictionary *> *)items
                         sourceView:(UIView *)sourceView {
    [self ame240_presentMenuWithTitle:title dictItems:items sourceView:sourceView onDismiss:nil];
}

+ (void)ame240_presentMenuWithTitle:(NSString *)title
                          dictItems:(NSArray<NSDictionary *> *)items
                         sourceView:(UIView *)sourceView
                          onDismiss:(void (^)(void))onDismiss {
    UIMenu *ame240_menu = [self ame240_menuWithTitle:title dictItems:items];
    // 字典快照随呈现链下传——动作 handler 只能从字典取（公开 API，
    // 见文件头注释）。
    [self ame240_presentMenu:ame240_menu sourceView:sourceView
                   onDismiss:onDismiss dictsForFallback:items];
}

#pragma mark - UIContextMenuInteractionDelegate（Task245 复活）

// delegate 为弱引用；单例永不释放 → 安全。菜单快照自 associated object
// 惰性读取（ame245_presentViaSystemMenu 每次呈现前已刷新）。
- (UIContextMenuConfiguration *)contextMenuInteraction:
    (UIContextMenuInteraction *)interaction
    configurationForMenuAtLocation:(CGPoint)location {
    UIMenu *ame240_menu = objc_getAssociatedObject(interaction, &ame240_menuSnapshotKey);
    if (ame240_menu == nil) return nil;
    ame240_actionFired = NO; // 本轮会话开始，重新计数
    return [UIContextMenuConfiguration
        configurationWithIdentifier:nil
                     previewProvider:nil
                      actionProvider:^UIMenu *_Nullable(
                          NSArray<UIMenuElement *> *_Nonnull suggestedActions) {
            return ame240_menu;
        }];
}

// 外部点按导致菜单消失且未选中任何动作 → 回调 onDismiss（承接旧
// actionSheet 取消项语义；选中动作后的菜单关闭不触发）。
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    didEndMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                       animator:(nullable id<UIContextMenuInteractionAnimating>)animator {
    void (^ame240_onDismiss)(void) = objc_getAssociatedObject(interaction, &ame240_dismissKey);
    if (!ame240_actionFired && ame240_onDismiss) {
        ame240_onDismiss();
    }
    ame240_actionFired = NO;
}

#pragma mark - UIAdaptivePresentationControllerDelegate

// actionSheet（原生档直通 / 玻璃档镜像失败兜底）的关闭回调——外部点按
// 关闭且未选中任何动作时回调 onDismiss（选中动作的路径已置
// ame240_actionFired，天然短路）。玻璃面板主路径不经此方法（面板自身
// onDismiss 机制，见 AmeFloatingMenu Task242 变体）。
- (void)presentationControllerDidDismiss:
    (UIPresentationController *)presentationController {
    if (!ame240_actionFired && ame240_fallbackDismiss) {
        ame240_fallbackDismiss();
    }
    ame240_fallbackDismiss = nil;
    ame240_actionFired = NO;
}

@end
