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
//    - ★ Task266（IMG_0399 iPhone XS Max iOS 18.7.10 装机崩溃根修）：
//      NSInternalInconsistencyException "The presentation controller of an
//      alert controller presenting as an alert must not have its delegate
//      modified"——iOS 18+ 起 UIKit 对【以 alert 形态呈现】的
//      UIAlertController 禁止修改 presentationController.delegate；iPhone
//      竖屏 compact 宽度下 actionSheet 同样解析为 alert 形态（私有
//      _UIAlertControlleriOSPresentationController 自持 delegate 驱动
//      popover→alert 自适应），三处赋值点（原生档直通/玻璃镜像失败兜底/
//      双私有入口缺失 fallback）在 iPhone 上必崩（堆栈：presentMenu →
//      presentStyleRoutedWithMenu → presentViaNativeSheet，设置页
//      general.interface_style / JRE 管理选择即触发）。iPad regular 宽度
//      popover 形态不受限（装机 iPadOS 27 实证零崩溃）。
//      【Task266 定案：delegate 赋值按呈现形态门控】
//      ① popover 形态（regular 宽度且非 iPhone）→ 保留赋值（自适应
//         didDismiss 取消语义不变）+ @try 双护栏（未来 iOS 再收紧时降级
//         而非崩溃）；
//      ② alert 形态（compact / iPhone 一律）→ 不赋值，取消语义改由
//         cancel 承载：字典协议含 cancel 项时物化为
//         UIAlertActionStyleCancel（iOS 9+ 点按外部即触发其 handler，
//         同 onDismiss 口径；iPhone 上多一行可见取消钮，可及性反而更佳）；
//         无 cancel 项且 onDismiss 非 nil 时按现状降级（外部点按无回调，
//         下次呈现自然覆盖 fallbackDismiss，无悬挂状态）。
//    - handler 唯一合法来源 = 字典协议（公开 API）：UIAction/
//      UIAlertAction.handler 均非公开属性，从已构建 UIMenu 反取在
//      iOS 26.2 SDK 为编译错误（Task241 CI r1 :79 双雷实证），KVC
//      反取属 Task239 炸弹家族禁忌。字典快照经呈现链 dictsForFallback:
//      下传（37 处调用点全部走字典便捷入口）。
//    - ★ Task282（用户："连点多下出现伪液态玻璃弹窗"第三轮定案）：真玻
//      璃档启动器内路由的沉降窗改道撤收为【仅会话真实存活】——装机日志
//      00:14:41-45 实锤连点重开全部落沉降窗 = 恒出磨砂面板（伪玻璃乱入
//      本体）；连点重开窗内 presentMenu 的真实失败形态是可捕获异常
//      （Task267 装机实锤），ame245_presentViaSystemMenu 新增 0.32s 单次
//      原生快速重试消化之，连点全程真液态玻璃，磨砂面板仅剩会话内改道
//      （Task273 病历本体）与真实静默丢弃兜底两处。
//    - ★ Task283（用户："依旧多次伪弹窗"，28a08ac 装机日志 01:22:15-18
//      实锤：语言选择器连点 5 次全部落【会话存活】分支 = 每次重 tap 都
//      出磨砂伪玻璃面板——Task282 收窄后的残余本体）：会话存活分支不再
//      直出玻璃面板，改 iOS16+ 公开 API dismissMenu 收掉活会话 → 0.45s
//      后经 ame245 原生重开新请求（内建 0.32s 单次重试消化收尾动画窗
//      口），连点全程真液态玻璃；dismissMenu 不可用/抛异常时保留即时
//      玻璃面板接管作末级保底（不回归静默丢弃）。
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
// ★ Task266：ame240_actionSheetFallback（@implementation 之外的 static C
//   函数）需调用形态门控助手——同 Task240 家族，前向声明提升为本文件可见。
+ (void)ame266_assignPresentationDelegateSafely:(UIAlertController *)alert
                                           host:(UIViewController *)host;
+ (void)ame266_addCancelCarrierIfNeeded:(UIAlertController *)alert
                                  dicts:(NSArray<NSDictionary *> *)dicts
                              onDismiss:(void (^)(void))onDismiss
                                   host:(UIViewController *)host;
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

// ★ Task273：系统菜单重入/静默丢弃自愈状态机（装机 latestlog f71c88b
//   实锤：用户在"版本隔离"选择器（系统原生菜单）里点"隔离此版本"，
//   handler 内再呈现"迁移并开启"子菜单——同锚点同交互实例的 context
//   menu 会话正在收尾，UIKit 把新的 presentMenu 静默丢弃（不崩不报，
//   面板永不出现）——用户连点 10 次 route 日志 10 连发零呈现 =
//   "无法切换回隔离"病灶本体。两层自愈：
//   甲（重入改道）：菜单动作刚触发/会话未收尾的窗口内，玻璃档改走
//     磨砂面板（UIAlertController 家族呈现不受 context menu 收尾
//     影响——同机 alert #2/#3 在 handler 内呈现成功实锤）；
//   乙（静默丢弃看门狗）：系统路由后 1.1s 内 delegate 未被询问（Task274-g 宽限
//     延长 + 兜底前再探呈现迹象，慢设备 delegate 晚到不再双 UI）
//     （configurationForMenuAtLocation 未回调 = 系统根本没开菜单）
//     自动转磨砂面板/actionSheet 兜底，任何未来 iOS 版本再出现新
//     丢弃形态也自动兜住（自适应恢复，用户铁律）。
static CFAbsoluteTime ame273_lastMenuActionAt = 0;   ///< UIAction/UIAlertAction handler 最近触发时刻
static BOOL ame273_systemMenuSessionActive = NO;     ///< 系统 context menu 会话进行中（delegate 已询问未收尾；读取时需过 5s 自过期门，Task274-g G3）
static CFAbsoluteTime ame273_sessionStartAt = 0;     ///< 会话起点（Task274-g G3：5s 自过期依据 / G4：呈现迹象判断）
static CFAbsoluteTime ame273_lastSessionEndAt = 0;   ///< 上一会话收尾时刻
static CFAbsoluteTime ame273_presentRequestAt = 0;   ///< 最近一次系统路由请求时刻（Task274-g G4：兜底前再探基准）
static BOOL ame273_systemMenuOpenExpected = NO;      ///< 已请求系统开菜单但 delegate 尚未确认
static int ame273_openGeneration = 0;                ///< 呈现代次（防陈旧定时器误兜底）
/// ★ Task283：活会话交互实例（delegate 询问时登记/didEnd 注销，weak 防
///   悬垂——视图释放后自动落 nil，dismissMenu 不可用自然落玻璃面板保底）。
static __weak UIContextMenuInteraction *ame283_liveSessionInteraction = nil;

/// ★ Task284（"优化连点悬浮菜单延迟"）：dismissMenu 收口后的重开请求块——
///   didEnd 完成回调前触发（沉降后即重开）+ 0.45s 后备定时器双通道；块内
///   捕获代次，ame284_representFiredGen 防双火（早触发后后备定时器空转）。
static dispatch_block_t ame284_pendingRepresent = nil;
static int ame284_representFiredGen = 0;
/// ★ Task285（"连点菜单延迟太高"根修）：armed 窗内最新请求参数容器——
///   Task284 的 gen 顶替语义在连点序列下自吞：每次点击都 gen++ 作废上一
///   armed 块再重新 dismiss+armed，菜单在连点期间永不落地（装机日志
///   a94669c 12:03:46-58 连 12 次 dismissed/re-present armed 无一落地）。
///   修后 armed 窗内后续连点只【更新容器参数】，不顶替不作废；armed 块
///   触发时读容器 = "最后一次点击的菜单"开一次即达。容器生命周期 =
///   armed 窗（≤0.45s），strong 持有源视图防中途释放（menu 打开期间
///   cell/按钮必然存活，窗内窗口极短，无悬垂风险）。
static UIMenu *ame285_pendingMenu = nil;
static UIView *ame285_pendingSrc = nil;
static NSArray *ame285_pendingDicts = nil;
static void (^ame285_pendingOnDismiss)(void) = nil;
/// ★ Task281：Task278 重试代次退役——延迟重试链整体移除后不存在并发链
///   （见 ame242_presentStyleRoutedWithMenu 分轨注释）。

/// ★ Task282（用户："连点多下出现伪液态玻璃弹窗"第三轮定案）：会话
///   活性判定收窄——只有【系统 context menu 会话真实存活】（delegate
///   已询问未收尾，5s 自过期门内）才认定"系统直出必被静默丢弃"（Task273
///   病历本体 = 动作 handler 内再呈现，此刻 didEnd 未回调）。沉降窗两个
///   子窗（动作后 1.2s / didEnd 后 0.6s）不再改道磨砂面板：连点重开窗
///   内 presentMenu 的实际失败形态是【可捕获异常】（Task267 装机实锤
///   = dismiss 动画未完成），不是静默丢弃——改走原生路由 + Task282
///   0.32s 单次快速重试（见 ame245_presentViaSystemMenu），连点全程
///   真液态玻璃，伪玻璃面板仅在真实静默丢弃时兜底。
///   纯 C 函数（本文件内部消费，无需 ObjC 派发）。
static BOOL ame273_systemMenuSessionLive(void) {
    if (!ame273_systemMenuSessionActive) return NO;
    // ★ Task274-g（G3）：5s 自过期——didEndMenuForConfiguration 一次不达
    //   （UIKit 偶发不回调）不再永久粘滞（粘滞 = 此后所有系统菜单恒
    //   改道磨砂面板直至重启）。超窗后按"会话已收尾"处理。
    if (ame273_sessionStartAt <= 0) return NO;
    return (CFAbsoluteTimeGetCurrent() - ame273_sessionStartAt) < 5.0;
}

/// Task273：静默丢弃看门狗（系统路由 1.1s 无 delegate 询问且无呈现迹象 → 兜底；Task274-g 宽限+再探）。
/// 声明前置：实现在 ame245_presentViaSystemMenu 内联 dispatch_after。
static void ame240_actionSheetFallback(UIContextMenuInteraction *ix,
                                       UIMenu *menu,
                                       NSArray<NSDictionary *> *dicts,
                                       void (^onDismiss)(void));

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
                ame273_lastMenuActionAt = CFAbsoluteTimeGetCurrent(); // ★ Task273：重入窗口起点
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
        } @catch (NSException *ame240_e) {
            // ★ Task267（用户："液态玻璃档多擑几次会弹出伪液态玻璃"）：
            //   异常路径必须留痕——连续快速触发时上一次菜单 dismiss 动画
            //   未完成，presentMenu 会抛 UIKit 内部异常被 @catch 吩掉，
            //   下游 fallback 落到磨砂面板 = 伪玻璃乱入。装机日志凭这行
            //   直接定谳竞争窗口。
            NSLog(@"[AmeNativeMenu] Task267: presentMenu exception: %@ (%@)",
                  ame240_e.name, ame240_e.reason);
        }
    }
    if ([ix respondsToSelector:@selector(_presentMenuAtLocation:)]) {
        UIView *ame240_v = ix.view;
        if (ame240_v != nil) {
            CGPoint ame240_p = CGPointMake(CGRectGetMidX(ame240_v.bounds),
                                           CGRectGetMidY(ame240_v.bounds));
            @try {
                [ix _presentMenuAtLocation:ame240_p];
                return YES;
            } @catch (NSException *ame240_e) {
                NSLog(@"[AmeNativeMenu] Task267: _presentMenuAtLocation: exception: %@ (%@)",
                      ame240_e.name, ame240_e.reason);
            }
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

    // ★ Task267：磨砂面板兜底收窄到伪玻璃档专属。真液态玻璃档系统菜单
    //   呈现失败（连续触发竞争）时不再落入磨砂面板（用户观感 = "伪液态
    //   玻璃乱入"），改直通 stock actionSheet（系统原生弹窗，观感同族）。
    if (LGCIsPseudoGlassStyleActive()) {
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
    // ★ Task266：iPhone compact 宽度下本呈现解析为 alert 形态——delegate
    //   赋值即崩（iOS 18+）。popover 形态（iPad regular）保留赋值。
    //   本函数为 @implementation 之外的 static C 函数（无 self），类名直调。
    [AmeNativeMenu ame266_assignPresentationDelegateSafely:ame245_alert host:ame245_host];
    [AmeNativeMenu ame266_addCancelCarrierIfNeeded:ame245_alert dicts:dicts onDismiss:onDismiss host:ame245_host];
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

#pragma mark - Task266 呈现形态门控（iPhone alert 形态 delegate 崩溃根修）

/// Task266：本次呈现是否解析为 popover 形态（唯一允许修改 presentation
/// controller.delegate 的形态）。alert 形态（compact 宽度或 iPhone 任意
/// 形态）下 UIKit 自持 delegate，外部赋值即 NSInternalInconsistencyException
/// （iOS 18+ 实证崩，IMG_0399 iOS 18.7.10）。iPhone 即便 regular 宽度
/// （Plus/Max 横屏）也保守跳过——presentViaNativeSheet 路径的 onDismiss
/// 消费方（设置页选择项）传 nil，降级零损。
+ (BOOL)ame266_popoverPresentationCapableForHost:(UIViewController *)host {
    if (host == nil) return NO;
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPhone) return NO;
    UITraitCollection *ame266_tc = host.view.window.traitCollection ?: host.traitCollection;
    return (ame266_tc.horizontalSizeClass == UIUserInterfaceSizeClassRegular);
}

/// Task266：delegate 安全赋值（popover 形态才赋 + @try 双护栏）。非 popover
/// 形态静默跳过（取消语义由 ame266 cancel 承载或按现状降级）。
+ (void)ame266_assignPresentationDelegateSafely:(UIAlertController *)alert
                                          host:(UIViewController *)host {
    if (alert == nil || host == nil) return;
    if (![self ame266_popoverPresentationCapableForHost:host]) {
        NSLog(@"[AmeNativeMenu] Task266: alert-style presentation (compact/iPhone) -- presentationController.delegate assignment skipped (iOS 18+ NSInternalInconsistencyException guard)");
        return;
    }
    @try {
        alert.presentationController.delegate = [self ame240_shared];
    } @catch (NSException *ame266_e) {
        NSLog(@"[AmeNativeMenu] Task266: delegate assignment rejected by UIKit (%@) -- continuing without didDismiss callback", ame266_e.name);
    }
}

/// Task266：alert 形态下的取消语义承载——字典协议中的 cancel 项物化为
/// 真正的 UIAlertActionStyleCancel（iOS 9+ 点按 actionSheet 外部即触发
/// cancel handler，与 presentationControllerDidDismiss 同口径回调
/// onDismiss；选中动作路径仍由 ame240_actionFired 幂等短路）。仅 alert
/// 形态调用（popover 形态继续走 delegate didDismiss，不新增可见取消钮）。
+ (void)ame266_addCancelCarrierIfNeeded:(UIAlertController *)alert
                                 dicts:(NSArray<NSDictionary *> *)dicts
                             onDismiss:(void (^)(void))onDismiss
                                  host:(UIViewController *)host {
    if (alert == nil || onDismiss == nil || dicts.count == 0) return;
    if ([self ame266_popoverPresentationCapableForHost:host]) return; // popover 形态：delegate 语义保留，不加重
    for (NSDictionary *ame266_it in dicts) {
        if (![ame266_it isKindOfClass:[NSDictionary class]]) continue;
        if (![ame266_it[@"cancel"] boolValue]) continue;
        NSString *ame266_title = ame266_it[@"title"];
        if (![ame266_title isKindOfClass:[NSString class]] || ame266_title.length == 0) continue;
        UIAlertAction *ame266_aa = [UIAlertAction
            actionWithTitle:ame266_title
                      style:UIAlertActionStyleCancel
                    handler:^(UIAlertAction *ame266_ignored) {
                ame240_actionFired = YES; // 选中取消 = 同口径短路 didDismiss（popover 复用场景）
                onDismiss();
            }];
        [alert addAction:ame266_aa];
        NSLog(@"[AmeNativeMenu] Task266: alert-style cancel carrier added (title=%@)", ame266_title);
        return; // 只取第一个 cancel 项
    }
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
                             dicts:(NSArray<NSDictionary *> *)dicts
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
    // ★ Task266：同 ame242_presentViaNativeSheet——形态门控 + cancel 承载。
    [self ame266_assignPresentationDelegateSafely:alert host:host];
    [self ame266_addCancelCarrierIfNeeded:alert dicts:dicts onDismiss:onDismiss host:host];
    [host presentViewController:alert animated:YES completion:nil];
}

/// ★ Task242 原生档呈现：旧版系统 actionSheet 直通（Task237 契约
/// "原生 = 旧版弹窗"）。绝不走系统 UIContextMenu 程序化呈现——iOS 26
/// 其材质恒为系统玻璃，与原生档语义冲突（用户实测"风格为原生时还是
/// 液态玻璃"的病灶）。中央路由 hook 在原生档直透，无接管的可能。
+ (void)ame242_presentViaNativeSheet:(UIAlertController *)alert
                                view:(UIView *)anchor
                                host:(UIViewController *)host
                               dicts:(NSArray<NSDictionary *> *)dicts
                           onDismiss:(void (^)(void))onDismiss {
    ame240_fallbackDismiss = onDismiss;
    // ★ Task266（IMG_0399 崩溃点）：iPhone compact 宽度下 actionSheet 解析为
    //   alert 形态——此处直赋 delegate 即 NSInternalInconsistencyException
    //   （用户堆栈 presentMenu→presentStyleRoutedWithMenu→presentViaNativeSheet
    //   正是本方法）。改为形态门控赋值（仅 iPad popover）+ alert 形态取消
    //   语义由 cancel 项承载。
    [self ame266_assignPresentationDelegateSafely:alert host:host];
    [self ame266_addCancelCarrierIfNeeded:alert dicts:dicts onDismiss:onDismiss host:host];
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
    // ★ Task273：静默丢弃自愈看门狗——presentMenu 调用成功不代表菜单真的
    //   开了（前一会话收尾窗口内 UIKit 静默丢弃，无异常无回调）。delegate
    //   configurationForMenuAtLocation 被询问 = 菜单真开了（清除标记）；
    //   1.1s 后仍悬挂且无呈现迹象 = 确认丢弃 → 自动转磨砂面板/actionSheet 兜底
    //   （ame240_actionSheetFallback 内建玻璃档磨砂面板主路径 + popover
    //   锚定直通兜底，自适应恢复零人工）。代次计数防陈旧定时器误兜底。
    //   ★ Task274-g（G4）：宽限 0.7s→1.1s（慢设备 delegate 晚到留头寸）+
    //   兜底前再探呈现迹象（sessionStartAt 晚于本次请求 = delegate
    //   刚被询问 = 菜单在开）——context menu 不走 VC 呈现链
    //   （presentedViewController 守卫拦不住），只能以 delegate 会话状态为准；
    //   否则磨砂面板先出、系统菜单随后照开 = 双 UI。
    ame273_openGeneration++;
    int ame273_myGen = ame273_openGeneration;
    ame273_systemMenuOpenExpected = YES;
    ame273_presentRequestAt = CFAbsoluteTimeGetCurrent();
    UIMenu *ame273_menu = menu;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BOOL ame273_menuDidStartOpening =
            (ame273_sessionStartAt > ame273_presentRequestAt);
        if (ame273_myGen == ame273_openGeneration && ame273_systemMenuOpenExpected &&
            !ame273_menuDidStartOpening) {
            ame273_systemMenuOpenExpected = NO;
            ame273_lastSessionEndAt = CFAbsoluteTimeGetCurrent();
            NSLog(@"[AmeNativeMenu] Task273: system menu silent-drop confirmed (1.1s no delegate query) -- glass panel fallback (self-heal)");
            ame240_actionSheetFallback(ame245_ix, ame273_menu, dicts, onDismiss);
        }
    });
    if (!ame240_openInteractionMenu(ame245_ix)) {
        // ★ Task282（"连点多下出现伪液态玻璃弹窗"根修）：openInteractionMenu
        //   返回 NO 的主体形态是双入口【抛异常】（Task267 装机实锤：上一
        //   次菜单 dismiss 动画未完成时 presentMenu 抛 UIKit 内部异常，可
        //   捕获）——不等于双入口缺失。旧实现立即落 fallback（磨砂面板/
        //   stock sheet）= 连点重开恒出伪玻璃乱入。改：单次 0.32s 原生
        //   重试（dismiss 动画时长量级）后仍失败才落 fallback；重试期间
        //   看门狗语义保留（presentRequestAt 刷新，不会提前误兜底）。代次
        //   防陈旧重试与新请求互踩；双入口真缺失（理论路径）多付 0.32s
        //   换连点真玻璃，可接受。
        ame273_systemMenuOpenExpected = NO;
        int ame282_gen = ame273_openGeneration;
        NSLog(@"[AmeNativeMenu] Task282: presentMenu rejected (dismiss window?) -- single native retry in 0.32s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.32 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (ame282_gen != ame273_openGeneration) return; // 已被新请求取代
            if (ame240_openInteractionMenu(ame245_ix)) {
                ame273_systemMenuOpenExpected = YES; // 重试已上路，看门狗继续值守
                ame273_presentRequestAt = CFAbsoluteTimeGetCurrent();
                NSLog(@"[AmeNativeMenu] Task282: native retry accepted -- real liquid glass on rapid re-tap");
                return;
            }
            NSLog(@"[AmeNativeMenu] Task282: native retry rejected -- fallback");
            ame240_actionSheetFallback(ame245_ix, menu, dicts, onDismiss);
        });
    }
}

/// Task242/245 分轨调度：host/alert 装配 → 按界面风格与锚点域选择呈现路径。
/// ★ Task281：Task278 外壳/代次与 ame278_retries 重试变体退役——延迟重试
///   链移除后不再存在并发重试链，单一入口直达分轨（历史病灶见分轨注释）。
+ (void)ame242_presentStyleRoutedWithMenu:(UIMenu *)menu
                               sourceView:(UIView *)sourceView
                                    dicts:(NSArray<NSDictionary *> *)dicts
                                onDismiss:(void (^)(void))onDismiss {
    UIViewController *ame242_host = [self ame242_hostViewControllerForView:sourceView];
    UIAlertController *ame242_alert = [self ame242_actionSheetFromDicts:dicts
                                                              menuTitle:menu.title];
    // ★ Task271（271-b D4）：host 已有呈现时沿链上溯到顶端，而非静默取消——
    //   旧实现 host.presentedViewController != nil 一律 "treated as cancel"：
    //   页面上残留任何面板/弹层（上一次菜单收尾中、toast 呈现中）时用户点
    //   选择器毫无反应（"无法切换回隔离"观感的另一来源）。上溯到呈现链顶端
    //   呈现即可；顶端正在收尾（isBeingDismissed）→ 0.4s 后单次重试。
    NSInteger ame271_walk = 0;
    while (ame242_host.presentedViewController != nil &&
           !ame242_host.presentedViewController.isBeingDismissed && ame271_walk < 8) {
        ame242_host = ame242_host.presentedViewController;
        ame271_walk++;
    }
    if (ame242_host == nil || ame242_alert == nil) {
        NSLog(@"[AmeNativeMenu] Task271: presentation unavailable (host=%@ alert=%@), treated as cancel",
              ame242_host, ame242_alert);
        if (onDismiss) onDismiss();
        return;
    }
    if (ame242_host.presentedViewController != nil) {
        // 顶端正在收尾（walk=0 即首个子层就在收尾）：单次延迟重试（0.4s 后重走全流程）
        NSLog(@"[AmeNativeMenu] Task271: top presenter dismissing, single retry in 0.4s");
        void (^ame271_onDismiss)(void) = onDismiss;
        UIView *ame271_src = sourceView;
        UIMenu *ame271_menu = menu;
        NSArray *ame271_dicts = dicts;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self ame242_presentStyleRoutedWithMenu:ame271_menu
                                         sourceView:ame271_src
                                              dicts:ame271_dicts
                                          onDismiss:ame271_onDismiss];
        });
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
            NSLog(@"[AmeNativeMenu] Task246/245: glass panel route (pseudo=%d inGame=%d)",
                  (int)LGCIsPseudoGlassStyleActive(),
                  (int)[self ame245_anchorInsideGameSurface:sourceView]);
            [self ame242_presentViaGlassMenu:ame242_alert
                                        host:ame242_host
                                       dicts:dicts
                                   onDismiss:onDismiss];
        } else if (ame273_systemMenuSessionLive()) {
            // ★ Task281/282 历史：仅【系统菜单会话真实存活】（delegate 已
            //   询问未收尾）→ 玻璃面板接管（Task281 引入；Task282 撤收沉降
            //   窗全口径后仅剩本支）。
            // ★ Task283（用户"依旧多次伪弹窗"根修，28a08ac 装机日志
            //   01:22:15-18 实锤：语言选择器连点 5 次全部落本分支 = 会话存
            //   活内每次重 tap 都新出一块磨砂伪玻璃面板——Task282 收窄后的
            //   残余本体）：本支不再直出玻璃面板。改 iOS16+ 公开 API
            //   dismissMenu 收掉活会话（didEnd 随 dismissal 回调复位会话态，
            //   ame283_liveSessionInteraction 于 configurationForMenuAtLocation
            //   登记/didEnd 注销）→ 0.45s（dismiss 动画量级）后经 ame245
            //   原生重开新请求——ame245 内建 0.32s 单次重试消化收尾动画窗
            //   口，Task273 看门狗继续兜底极端静默丢弃 → 连点全程真液态
            //   玻璃。dismissMenu 不可用/抛异常（iOS<16/运行时缺失）→ 保
            //   底即时玻璃面板接管（Task281 观感，不回归静默丢弃）。
            //   代次先行推进：0.45s 等待窗内更晚请求会 gen++ 顶替本块（连
            //   点不排队，只保最新一次重开）；ame273_presentRequestAt 同步
            //   刷新保看门狗语义连续。
            //   ★ Task284（延迟优化）：上述固定 0.45s 拆双通道——主通道 =
            //   didEndMenuForConfiguration 收尾完成回调前触发（沉降后即重
            //   开，较固定 0.45s 提前 ~0.2-0.3s，连点重开即点即达）；后备
            //   定时器降级为 0.45s 极端兑底（didEnd 未达时才生效）；
            //   ame284_representFiredGen 同代次只放行一次防双火。
            //   ★ Task285（"连点菜单延迟太高"根修）：armed 窗内后续连点
            //   【合并】而非【顶替】——下方入口先查 ame284_pendingRepresent
            //   存活即更新容器参数直接 return（不 dismissMenu 不 gen++），
            //   armed 块触发时读容器 = 最后一次点击的菜单开一次；连点序列
            //   从"开 N-1 次×关 N-1 次"变"只开 1 次（最新）"，全程零吞并。
            UIContextMenuInteraction *ame283_live = ame283_liveSessionInteraction;
            BOOL ame283_dismissed = NO;
            // ★ Task285：armed 窗内连点合并——已有待重开请求在飞时，本请求
            //   只刷新容器参数与看门狗时点，不再 dismissMenu/gen++ 顶替
            //   （连点不互相作废，菜单最终一次开最新内容）。
            if (ame284_pendingRepresent != nil) {
                ame285_pendingMenu = menu;
                ame285_pendingSrc = sourceView;
                ame285_pendingDicts = dicts;
                ame285_pendingOnDismiss = onDismiss;
                ame273_presentRequestAt = CFAbsoluteTimeGetCurrent();
                NSLog(@"[AmeNativeMenu] Task285: rapid re-tap coalesced into armed request (no dismiss/re-arm)");
                return;
            }
            if (ame283_live != nil && [ame283_live respondsToSelector:@selector(dismissMenu)]) {
                @try {
                    [ame283_live dismissMenu];
                    ame283_dismissed = YES;
                    NSLog(@"[AmeNativeMenu] Task283/284: live session dismissed via dismissMenu -- re-present armed (didEnd-early + 0.45s backstop)");
                } @catch (NSException *ame283_e) {
                    NSLog(@"[AmeNativeMenu] Task283: dismissMenu exception (%@) -- glass panel fallback", ame283_e.name);
                }
            }
            if (ame283_dismissed) {
                ame273_openGeneration++;
                int ame283_gen = ame273_openGeneration;
                ame273_presentRequestAt = CFAbsoluteTimeGetCurrent();
                // ★ Task285：参数入容器（armed 块触发时读最新值）
                ame285_pendingMenu = menu;
                ame285_pendingSrc = sourceView;
                ame285_pendingDicts = dicts;
                ame285_pendingOnDismiss = onDismiss;
                dispatch_block_t ame284_represent = ^{
                    if (ame283_gen != ame273_openGeneration) return; // 已被更新请求取代
                    if (ame284_representFiredGen == ame283_gen) return; // didEnd 早触发已完成
                    ame284_representFiredGen = ame283_gen;
                    ame284_pendingRepresent = nil;
                    // ★ Task285：读容器最新参数（armed 窗内后续连点合并的终点）
                    UIMenu *ame285_menu = ame285_pendingMenu ?: menu;
                    UIView *ame285_src = ame285_pendingSrc ?: sourceView;
                    NSArray *ame285_dicts = ame285_pendingDicts ?: dicts;
                    void (^ame285_onDismiss)(void) = ame285_pendingOnDismiss ?: onDismiss;
                    ame285_pendingMenu = nil;
                    ame285_pendingSrc = nil;
                    ame285_pendingDicts = nil;
                    ame285_pendingOnDismiss = nil;
                    NSLog(@"[AmeNativeMenu] Task285: armed re-present fired (gen=%d) -- opening latest coalesced menu", ame283_gen);
                    [self ame245_presentViaSystemMenu:ame285_menu
                                           sourceView:ame285_src
                                                dicts:ame285_dicts
                                           onDismiss:ame285_onDismiss];
                };
                ame284_pendingRepresent = [ame284_represent copy];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ame284_represent);
            } else {
                NSLog(@"[AmeNativeMenu] Task283: dismissMenu unavailable (live=%@) -- instant glass-panel takeover (legacy fallback)",
                      ame283_live != nil ? @"nil" : @"no-sel");
                [self ame242_presentViaGlassMenu:ame242_alert
                                            host:ame242_host
                                           dicts:dicts
                                       onDismiss:onDismiss];
            }
        } else {
            // ★ Task245（IMG_0380 用户定案）：真液态玻璃档启动器内选择菜单 =
            //   系统原生液态玻璃直出；磨砂面板退役到输入类弹窗专属。
            //   ★ Task282：沉降窗两子窗（didEnd 后 0.6s / 动作后 1.2s）并
            //   入本支——dismiss 动画窗口内的 presentMenu 异常由
            //   ame245_presentViaSystemMenu 的 0.32s 单次原生重试消化，
            //   连点重开零伪玻璃乱入（Task281 用户定案保序）。
            [self ame245_presentViaSystemMenu:menu
                                   sourceView:sourceView
                                        dicts:dicts
                                    onDismiss:onDismiss];
        }
    } else {
        [self ame242_presentViaNativeSheet:ame242_alert
                                      view:sourceView
                                      host:ame242_host
                                     dicts:dicts
                                 onDismiss:onDismiss];
    }
}

/// ★ Task281：玻璃档系统弹窗呈现路由——未经中央路由的直呈 UIAlertController
///   （JIT 等待/重挂/超时重试族）在玻璃风格下此前恒为旧式原生外观（用户
///   2026-10-17："等待 jit 变成了原生，而不是伪液态玻璃"——系统玻璃在不
///   支持呈现的弹窗类/场景上不可用，而玻璃档此前没有伪玻璃兜底层，直接
///   裸奔旧式原生）。本助手按界面风格分轨：玻璃档（真液态玻璃 + 伪玻璃）
///   → 磨砂玻璃面板镜像接管（Task237 组件；Task275 dismiss 镜像保证后续
///   代码对源 alert 的 dismissViewControllerAnimated 仍能收掉面板）；镜像
///   拒收（原生档/host 忙/动作 KVC 镜像失败）→ 保持原生直呈零变化。
///   animated:NO 契约保留（Task223：后台转场瞬间的动画 present 是主线程
///   楔死头号嫌疑类——JIT 等待弹窗恰在该窗口内呈现）。
+ (void)ame281_presentSystemAlert:(UIAlertController *)alert
                         fromHost:(UIViewController *)host {
    if (alert == nil || host == nil) return;
    if (LGCIsGlassStyleActive()) {
        BOOL ok = [AmeFloatingMenu presentGlassMenuForAlert:alert
                                              fromPresenter:host
                                                   animated:NO
                                                 completion:nil];
        if (ok) {
            NSLog(@"[AmeNativeMenu] Task281: system alert mirrored to glass panel (title=%@)",
                  alert.title ?: @"");
            return;
        }
        NSLog(@"[AmeNativeMenu] Task281: glass mirror declined -- native passthrough");
    }
    [host presentViewController:alert animated:NO completion:nil];
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
    // ★ Task268（scan-a #5）：早退分支统一取消语义——nil 锚点/空菜单静默
    //   return 不回调 onDismiss，依赖 onDismiss 复位的调用方悬挂。
    if (menu == nil || sourceView == nil || menu.children.count == 0) {
        if (onDismiss) onDismiss();
        return;
    }
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
                ame273_lastMenuActionAt = CFAbsoluteTimeGetCurrent(); // ★ Task273：重入窗口起点
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
    // ★ Task273：delegate 被询问 = 系统真在开菜单——撤销静默丢弃看门狗。
    ame273_systemMenuOpenExpected = NO;
    ame273_systemMenuSessionActive = YES;
    ame273_sessionStartAt = CFAbsoluteTimeGetCurrent(); // ★ Task274-g（G3/G4）：会话起点（5s 自过期 + 呈现迹象）
    ame283_liveSessionInteraction = interaction;        // ★ Task283：活会话实例登记（dismissMenu 收口用）
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
    // ★ Task273：会话收尾——重入窗口口径之一（0.6s 内再呈现系统菜单仍会
    //   被丢，玻璃档改道；之后自然恢复系统原生路由）。
    ame273_systemMenuSessionActive = NO;
    ame273_lastSessionEndAt = CFAbsoluteTimeGetCurrent();
    if (ame283_liveSessionInteraction == interaction) {
        ame283_liveSessionInteraction = nil;            // ★ Task283：会话收尾注销
    }
    // ★ Task284：会话收尾 = dismissal 完成回调 → 待重开请求主通道前触发
    //   （didEnd 本身即收尾动画完成后的回调，无需再沉降——★ Task285：
    //   0.12s 沉降降到下一 runloop 即发，present 若撞收尾残帧由 ame245
    //   的 0.32s 单次原生重试兜底，比白等 0.12s 更快且不劣化）；
    //   无待重开请求（正常选中/外部点按收尾）零成本直落。
    if (ame284_pendingRepresent != nil) {
        dispatch_block_t ame284_early = ame284_pendingRepresent;
        ame284_pendingRepresent = nil;
        dispatch_async(dispatch_get_main_queue(), ame284_early);
    }
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
