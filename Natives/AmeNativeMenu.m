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
//    - UIAlertAction 不参与本组件（其 handler 非公开属性，KVC 取用属
//      Task239 炸弹家族禁忌）——调用点一律走字典协议（公开 API）。
//

#import "AmeNativeMenu.h"
#import <objc/runtime.h>

@interface AmeNativeMenu () <UIContextMenuInteractionDelegate>
@end

/// 菜单快照的 associated object key（文件级唯一——presentMenu 写入与
delegate 惰性读取必须同 key，局部 static 地址不同会导致取不到菜单）。
static char ame240_menuSnapshotKey;
/// 消失回调（onDismiss）的 associated object key。
static char ame240_dismissKey;
/// 动作已选中标记（同帧全局唯一：系统同一时刻至多一个上下文菜单可见，
/// 主线程串行访问，无竞态面）。didEnd 时未选中任何动作才回调 onDismiss。
static BOOL ame240_actionFired = NO;

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

        // 视图尚未进窗口时 presentMenu 静默无效——防御性回退一跑循环
        // （同帧刚构建的锚点可能尚未 layout；下帧必在窗口）。
        if (sourceView.window == nil) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (sourceView.window != nil) [ame240_ix presentMenu];
            });
        } else {
            [ame240_ix presentMenu];
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
    UIMenu *ame240_menu = [self ame240_menuWithTitle:title dictItems:items];
    [self ame240_presentMenu:ame240_menu sourceView:sourceView];
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

@end
