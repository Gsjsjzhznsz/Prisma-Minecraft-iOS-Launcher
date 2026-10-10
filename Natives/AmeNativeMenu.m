//
//  AmeNativeMenu.m
//  Amethyst
//
//  ★ Task240：系统原生 UIMenu 菜单呈现器（设计契约见 AmeNativeMenu.h）。
//
//  实现要点：
//    - UIContextMenuInteraction 的 delegate 弱引用 → 使用永不释放的
//      单例实例承担 delegate（Class 级生命周期，避免悬垂）；
//    - 菜单快照挂在交互实例的 associated object 上，menuProvider 惰性
//      取用——ame240_presentMenu 每次调用都会刷新快照，多次呈现同一
//      锚点永远拿到最新菜单；
//    - handler 只能从字典协议取（公开 API）——UIAction/UIAlertAction
//      的 handler 均非公开属性，KVC 取用属 Task239 炸弹家族禁忌，
//      从已构建 UIMenu 反取在 iOS 26.2 SDK 为编译错误（Task241 CI r1
//      双雷实证）。UIAlertAction 仅在 actionSheet 兜底中作为呈现容器
//      （Task241 第三级），动作语义仍全部来自字典协议。
//

#import "AmeNativeMenu.h"
#import <objc/runtime.h>

// ★ Task240 CI r3 兼容性声明：CI iOS 26.2 SDK 实测（run 38049707856）
// presentMenu 类目声明在本构建配置下不可见（主 @interface /
// initWithDelegate 均正常编译；LauncherPrefManageJRE 旧实现退回私有
// _presentMenuAtLocation 即同域先例）。此处自声明与系统同名的类目方法
// ——纯声明、无定义（链接期不产生新 IMP）。
//
// ★ Task241（用户装机实测：“悬浮菜单全部打开崩溃”）：上赌注破产——
//   纯声明赌的是“运行期由 UIKit 系统实现响应”，而真机 iOS 26 运行时
//   并无 -[UIContextMenuInteraction presentMenu] 这个 IMP，38 处调用点
//   一点开即 unrecognized selector 崩溃。本轮改为【运行时探测 + 三级
//   降级】：presentMenu → _presentMenuAtLocation:（UIKit+hook.h 同域
//   先例，iOS 13+ 长期稳定）→ 系统 actionSheet 弹窗兜底；任一环节
//   respondsToSelector 不响应或 @try 抛出即降下一级，绝不再以
//   unrecognized selector 崩溃；双私有入口缺失时功能仍不断供。
//
// ★ Task241 CI r1（编译雷两族）：兜底拍平从字典协议直驱——
//   UIAction.handler 非公开属性（本文件头禁忌原文即此，Task241 首版
//   自踩），从已构建 UIMenu 反取在 iOS 26.2 SDK 为编译错误（:79 双雷），
//   KVC 反取属运行时炸弹；dictsForFallback: 把字典快照送入呈现链，
//   全部取用为公开 API。另 ：85 C 函数调用误包方括号当消息表达式
//   （Task240-ci r4 括号教训的镜像：裸 continuation 缺 [] vs C 调用
//   多 []，括号平衡门双盲区），整函数重写后此行消失。
@interface UIContextMenuInteraction (Ame240PresentMenuCompat)
- (void)presentMenu;
- (void)_presentMenuAtLocation:(CGPoint)location;
@end

@interface AmeNativeMenu () <UIContextMenuInteractionDelegate,
                             UIAdaptivePresentationControllerDelegate>
// Task241：单例访问器提升为本文件可见——静态降级函数（actionSheet 兜底
// 挂 adaptive delegate）在 @implementation 之前即可合法调用，避免
// "no known class method"（Task240 CI r1 同款错误家族）。
+ (instancetype)ame240_shared;
@end

/// 菜单快照的 associated object key（文件级唯一——presentMenu 写入与
/// delegate 惰性读取必须同 key，局部 static 地址不同会导致取不到菜单）。
static char ame240_menuSnapshotKey;
/// 消失回调（onDismiss）的 associated object key。
static char ame240_dismissKey;
/// 动作已选中标记（同帧全局唯一：系统同一时刻至多一个上下文菜单可见，
/// 主线程串行访问，无竞态面）。didEnd 时未选中任何动作才回调 onDismiss。
static BOOL ame240_actionFired = NO;
/// Task241：actionSheet 兜底呈现期间的待回调 onDismiss（主线程串行，
/// 用户点按动作/关闭弹窗时消费；系统菜单路径不经过此变量）。
static void (^ame240_fallbackDismiss)(void);

#pragma mark - Task241 presentation chain

/// Task241-ci：字典协议 → UIAlertAction 拍平（子菜单降一级缩进，语义
/// 保留：destructive 红字 / disabled 置灰 / handler 透传并置已选中标记）。
/// ★ handler 只能从字典协议取——UIAction.handler 与 UIAlertAction.handler
/// 同属非公开属性（Task240 定案禁忌，本文件头注释原文即此），从已构建
/// UIMenu 反取在 iOS 26.2 SDK 即编译错误（Task241 CI r1 :79 双雷），
/// KVC 反取属 Task239 运行时炸弹家族，均不可行；字典快照经呈现链
/// dictsForFallback: 传入，此处全部取用为公开 API。跨行消息表达式
/// 整体带 []（Task240-ci r4 教训：裸 continuation 与 C 调用误包 []
/// 是括号平衡门双盲区的对偶雷）。
static void ame240_addDictItemsToAlert(NSArray<NSDictionary *> *items,
                                       NSMutableArray<UIAlertAction *> *out,
                                       NSString *prefix) {
    for (NSDictionary *ame241_it in items) {
        if (![ame241_it isKindOfClass:[NSDictionary class]]) continue;
        // cancel 项跳过：actionSheet 外部点按即关闭，取消语义由
        // presentationControllerDidDismiss 承担（同系统菜单口径）。
        if ([ame241_it[@"cancel"] boolValue]) continue;
        NSString *ame241_title = ame241_it[@"title"];
        if (![ame241_title isKindOfClass:[NSString class]]) continue;

        // 子菜单（@"subitems" 非空）递归降一级缩进（与旧 UIMenu 树拍平同语义）
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

/// Task241 第三级兜底：双私有呈现入口都缺失（理论不可达——防未来 iOS
/// 移除私有 API）时，退回系统 actionSheet 弹窗（经 Task237 AmeFloatingMenu
/// 既有玻璃路由接管，风格与全局弹窗一致），保证菜单功能不断供；外部
/// 点按关闭且未选中动作时回调 onDismiss（承接取消语义，流程不悬死）。
/// 呈现失败（无宿主 VC 等）立即回调 onDismiss。
///
/// ★ Task241-ci：动作重建只能走字典快照 dicts（handler 不可从已构建
///   UIMenu 反取，见 ame240_addDictItemsToAlert 注释）——dicts 缺失或
///   拍平为零动作时【不呈现假菜单】（点了没反应的空壳劣于不出现），
///   按取消语义回调 onDismiss。
static void ame240_actionSheetFallback(UIContextMenuInteraction *ix,
                                       UIMenu *menu,
                                       NSArray<NSDictionary *> *dicts,
                                       void (^onDismiss)(void)) {
    UIView *anchor = ix.view;
    if (anchor == nil || dicts.count == 0) {
        NSLog(@"[AmeNativeMenu] Task241-ci: fallback unavailable (anchor=%p dicts=%lu), treated as cancel",
              anchor, (unsigned long)dicts.count);
        if (onDismiss) onDismiss();
        return;
    }
    UIResponder *ame240_r = anchor;
    while (ame240_r != nil && ![ame240_r isKindOfClass:[UIViewController class]]) {
        ame240_r = ame240_r.nextResponder;
    }
    UIViewController *hostVC = (UIViewController *)ame240_r;
    if (hostVC == nil || hostVC.presentedViewController != nil) {
        if (onDismiss) onDismiss();
        return;
    }

    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:(menu.title.length > 0 ? menu.title : nil)
                         message:nil
                  preferredStyle:UIAlertControllerStyleActionSheet];
    NSMutableArray<UIAlertAction *> *items = [NSMutableArray array];
    ame240_addDictItemsToAlert(dicts, items, @"");
    if (items.count == 0) { // 字典全为 cancel/无效项 → 无可呈现动作
        if (onDismiss) onDismiss();
        return;
    }
    for (UIAlertAction *aa in items) [alert addAction:aa];

    ame240_fallbackDismiss = onDismiss;
    alert.presentationController.delegate = [AmeNativeMenu ame240_shared];
    // iPad 必须 popover 锚定（不设 sourceView 直接崩）；iPhone 忽略。
    alert.popoverPresentationController.sourceView = anchor;
    alert.popoverPresentationController.sourceRect = anchor.bounds;
    alert.popoverPresentationController.permittedArrowDirections =
        UIPopoverArrowDirectionAny;
    [hostVC presentViewController:alert animated:YES completion:nil];
    NSLog(@"[AmeNativeMenu] Task241: private presentation unavailable, actionSheet fallback in use");
}

/// Task241：程序化呈现降级链。返回 YES = 已呈现；NO = 私有入口全缺失
/// （调用方转 actionSheet 兜底）。
static BOOL ame240_openInteractionMenu(UIContextMenuInteraction *ix) {
    if (ix == nil) return NO;
    // ① presentMenu（无参）——Task240 首选入口；部分 iOS 26 运行时无此 IMP
    //   （真机实测崩溃根因），respondsToSelector 探测失败即静默降级。
    if ([ix respondsToSelector:@selector(presentMenu)]) {
        @try {
            [ix presentMenu];
            return YES;
        } @catch (NSException *ame240_e) {}
    }
    // ② _presentMenuAtLocation:（锚点中心）——UIKit+hook.h 同域先例，
    //    iOS 13+ 长期稳定的程序化呈现私有 API。
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
    NSLog(@"[AmeNativeMenu] Task241: neither presentMenu nor _presentMenuAtLocation: responded");
    return NO;
}

@implementation AmeNativeMenu

#pragma mark - Singleton delegate

+ (instancetype)ame240_shared {
    static AmeNativeMenu *ame240_shared = nil;
    static dispatch_once_t ame240_once;
    dispatch_once(&ame240_once, ^{
        ame240_shared = [[AmeNativeMenu alloc] init];
    });
    return ame240_shared;
}

#pragma mark - Public

+ (void)ame240_presentMenu:(UIMenu *)menu
                sourceView:(UIView *)sourceView {
    [self ame240_presentMenu:menu sourceView:sourceView onDismiss:nil];
}

+ (void)ame240_presentMenu:(UIMenu *)menu
                sourceView:(UIView *)sourceView
                onDismiss:(void (^)(void))onDismiss {
    // Task241-ci：UIMenu 直构入口无字典快照——兜底链在双私有入口缺失的
    // 理论场景下按取消语义回调（不呈现点了没反应的假菜单）。业务调用
    // 一律走 ame240_presentMenuWithTitle:dictItems:（唯一持有 handler
    // 的入口；全仓唯一 UIMenu 入口调用点 Multiplayer 已于 Task241-ci
    // 收编字典入口，37 处调用点全部统一）。
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
        static char ame240_interactionKey;
        static char ame240_firedKey;

        UIContextMenuInteraction *ame240_ix =
            objc_getAssociatedObject(sourceView, &ame240_interactionKey);
        if (ame240_ix == nil) {
            ame240_ix = [[UIContextMenuInteraction alloc]
                initWithDelegate:[self ame240_shared]];
            [sourceView addInteraction:ame240_ix];
            objc_setAssociatedObject(sourceView, &ame240_interactionKey,
                                     ame240_ix, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }

        // 菜单快照 + 消失回调 + 已选中标记挂交互实例（delegate 惰性读取；
        // didEnd 时未选中任何动作才回调 onDismiss——承接旧 actionSheet
        // 取消项语义，避免外部点按使等待回调的流程悬死）。
        objc_setAssociatedObject(ame240_ix, &ame240_menuSnapshotKey, menu,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(ame240_ix, &ame240_dismissKey, onDismiss,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(ame240_ix, &ame240_firedKey, @NO,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // ★ Task241：呈现改走三级降级链（详见文件头注释）——裸调
        //   presentMenu 在真机 iOS 26 上 unrecognized selector 崩溃。
        //   视图尚未进窗口时防御性回退一跑循环（同帧刚构建的锚点可能
        //   尚未 layout；下帧必在窗口）；无法呈现时回调 onDismiss
        //   （语义 = 菜单未打开即取消，等待回调的流程不悬死）。
        if (sourceView.window == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (sourceView.window != nil) {
                    if (!ame240_openInteractionMenu(ame240_ix)) {
                        ame240_actionSheetFallback(ame240_ix, menu, dicts,
                                                   onDismiss);
                    }
                } else if (onDismiss) {
                    onDismiss();
                }
            });
        } else if (!ame240_openInteractionMenu(ame240_ix)) {
            ame240_actionSheetFallback(ame240_ix, menu, dicts, onDismiss);
        }
    }
    // < iOS 14 不可达（部署目标 14.0）；真出现时静默不呈现 = 不劣于现状。
}

+ (UIMenu *)ame240_menuWithTitle:(NSString *)title
                       dictItems:(NSArray<NSDictionary *> *)items {
    NSMutableArray<UIMenuElement *> *ame240_children = [NSMutableArray array];
    for (NSDictionary *ame240_it in items) {
        if (![ame240_it isKindOfClass:[NSDictionary class]]) continue;

        // Cancel 项丢弃（系统菜单点按外部即消失，无取消语义）
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
                ame240_actionFired = YES; // didEnd 据此区分“选中动作后关闭”与“外部点按取消”
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
    // Task241-ci：字典快照随呈现链下传——actionSheet 兜底的 handler
    // 只能从字典取（UIAction 反取非公开属性不可行，见文件头注释）。
    [self ame240_presentMenu:ame240_menu sourceView:sourceView
                   onDismiss:onDismiss dictsForFallback:items];
}

#pragma mark - UIContextMenuInteractionDelegate

// delegate 为弱引用；单例永不释放 → 安全。菜单快照自 associated object
// 惰性读取（ame240_presentMenu 每次呈现前已刷新）。
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

// Task241：actionSheet 兜底的关闭回调——外部点按关闭且未选中任何动作
// 时回调 onDismiss（选中动作的路径已置 ame240_actionFired，天然短路）。
- (void)presentationControllerDidDismiss:
    (UIPresentationController *)presentationController {
    if (!ame240_actionFired && ame240_fallbackDismiss) {
        ame240_fallbackDismiss();
    }
    ame240_fallbackDismiss = nil;
    ame240_actionFired = NO;
}

@end
