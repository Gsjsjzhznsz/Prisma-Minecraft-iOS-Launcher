#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LauncherPreferences.h"
#import "UIKit+hook.h"
#import "utils.h"
#import "LiquidGlassCompat.h"   // Task235：UIAlertController 液态玻璃化

__weak UIWindow *mainWindow, *externalWindow;

void swizzle(Class class, SEL originalAction, SEL swizzledAction) {
    method_exchangeImplementations(class_getInstanceMethod(class, originalAction), class_getInstanceMethod(class, swizzledAction));
}

void swizzleClass(Class class, SEL originalAction, SEL swizzledAction) {
    method_exchangeImplementations(class_getClassMethod(class, originalAction), class_getClassMethod(class, swizzledAction));
}

void swizzleUIImageMethod(SEL originalAction, SEL swizzledAction) {
    Class class = [UIImage class];
    Method originalMethod = class_getInstanceMethod(class, originalAction);
    Method swizzledMethod = class_getInstanceMethod(class, swizzledAction);
    
    if (originalMethod && swizzledMethod) {
        method_exchangeImplementations(originalMethod, swizzledMethod);
    } else {
        NSLog(@"[UIKit+hook] Warning: Could not swizzle UIImage methods (%@ and %@)", 
              NSStringFromSelector(originalAction), 
              NSStringFromSelector(swizzledAction));
    }
}

void init_hookUIKitConstructor(void) {
    // Task 129g：iPad 机型永远使用真实 Pad idiom（用户实测："iPad9 被识别成
    // 小屏幕设备，右边的新侧边栏变成小屏幕专用的简略侧边栏"）。
    // 旧逻辑无条件把 idiom 压成 Phone（除非 debug_ipad_ui），仅靠
    // PLPreferences 里 realUIIdiom==Pad 的默认值兜底——该默认值的求值时机
    // 依赖构造器顺序/历史落盘，一旦求值时 idiom 已被改写或旧版本存过 NO，
    // iPad 就永久落入 Phone 形态（弹窗变底部横条、popover 变全屏、整体
    // "小屏幕专用"观感）。UIDevice.model 不受任何 hook 影响，是最可靠的
    // 形态判据：iPad 机型直接 Pad；iPhone 保留原"解锁 iPad UI"开关语义。
    BOOL ame129g_isIPad = [[[UIDevice currentDevice].model lowercaseString]
        containsString:@"ipad"];
    UIUserInterfaceIdiom idiom;
    if (ame129g_isIPad) {
        idiom = UIUserInterfaceIdiomPad;
    } else {
        idiom = getPrefBool(@"debug.debug_ipad_ui") ? UIUserInterfaceIdiomPad : UIUserInterfaceIdiomPhone;
    }
    [UIDevice.currentDevice _setActiveUserInterfaceIdiom:idiom];
    [UIScreen.mainScreen _setUserInterfaceIdiom:idiom];
    
    swizzle(UIImageView.class, @selector(setImage:), @selector(hook_setImage:));
    if(UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        swizzle(UIPointerInteraction.class, @selector(_updateInteractionIsEnabled), @selector(hook__updateInteractionIsEnabled));
    }

    // ★ Task235（用户：“现在为什么依旧使用的是原生悬浮弹窗而不是液态玻璃”）：
    //   UIAlertController 全局液态玻璃化（安装点；实现见文件尾
    //   UIAlertController(Ame235GlassAlert) 分类）。所有权守卫：
    //   class_getInstanceMethod 会沿父类链查找——若 viewWillAppear: 并非
    //   UIAlertController 自身实现（未来系统变化），交换会波及全部 VC，
    //   必须放弃安装（原生外观，优雅降级）。
    {
        Method ame235_orig = class_getInstanceMethod([UIAlertController class], @selector(viewWillAppear:));
        Method ame235_hook = class_getInstanceMethod([UIAlertController class], @selector(ame235_hook_viewWillAppear:));
        BOOL ame235_owns = NO;
        unsigned int ame235_mcount = 0;
        Method *ame235_mlist = class_copyMethodList([UIAlertController class], &ame235_mcount);
        for (unsigned int ame235_i = 0; ame235_i < ame235_mcount; ame235_i++) {
            if (method_getName(ame235_mlist[ame235_i]) == @selector(viewWillAppear:)) {
                ame235_owns = YES;
                break;
            }
        }
        if (ame235_mlist != NULL) free(ame235_mlist);
        if (ame235_orig != NULL && ame235_hook != NULL && ame235_owns) {
            method_exchangeImplementations(ame235_orig, ame235_hook);
            NSLog(@"[ThemeOps] Task235 UIAlertController glass hook installed (viewWillAppear owned)");
        } else {
            NSLog(@"[ThemeOps] Task235 UIAlertController glass hook SKIPPED (viewWillAppear not owned -- native look kept)");
        }
    }

    // ★ Task236（用户：“悬浮弹窗还是旧iOS的，不是新iOS26加点液态玻璃悬浮
    //   弹窗”）：Task235 的 viewWillAppear: 交换带所有权守卫——若用户的
    //   系统上 UIAlertController 并不【自身拥有】viewWillAppear:（沿父类
    //   链），钩子整个不装 = 弹窗零变化（“还是旧iOS”的装机实锤）。补一条
    //   【必定安装】的路径：交换 UIViewController 基类自有的
    //   presentViewController:animated:completion:（基类必有实现；交换只
    //   影响基类实现，子类覆写不经 super 的罕见路径不受波及），弹窗呈现后
    //   双延时补玻璃（0s：viewDidLoad 层级已建；0.45s：越过转场与 UIKit
    //   自身的底色回写）。钩子内部只对 UIAlertController + 玻璃风格激活
    //   时才做事，其余呈现零开销直透。
    {
        Method ame236_orig = class_getInstanceMethod([UIViewController class],
                                                      @selector(presentViewController:animated:completion:));
        Method ame236_hook = class_getInstanceMethod([UIViewController class],
                                                      @selector(ame236_hook_presentViewController:animated:completion:));
        if (ame236_orig != NULL && ame236_hook != NULL) {
            method_exchangeImplementations(ame236_orig, ame236_hook);
            NSLog(@"[ThemeOps] Task236 alert glass present-hook installed (UIViewController base owns the selector)");
        } else {
            NSLog(@"[ThemeOps] Task236 alert glass present-hook SKIPPED (base selector missing -- unexpected)");
        }
    }
    
    // Add this line to swizzle the _imageWithSize: method
    swizzleUIImageMethod(NSSelectorFromString(@"_imageWithSize:"), @selector(hook_imageWithSize:));

    if (realUIIdiom == UIUserInterfaceIdiomTV) {
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            // If you are about to test iPadOS idiom on tvOS, there's no better way for this
            class_setSuperclass(NSClassFromString(@"UITableConstants_Pad"), NSClassFromString(@"UITableConstants_TV"));
#pragma clang diagnostic pop
        }
        swizzle(UINavigationController.class, @selector(toolbar), @selector(hook_toolbar));
        swizzle(UINavigationController.class, @selector(setToolbar:), @selector(hook_setToolbar:));
        swizzleClass(UISwitch.class, @selector(visualElementForTraitCollection:), @selector(hook_visualElementForTraitCollection:));
   }
}

@implementation UIDevice(hook)

- (NSString *)completeOSVersion {
    return [NSString stringWithFormat:@"%@ %@ (%@)", self.systemName, self.systemVersion, self.buildVersion];
}

@end

// Patch: emulate scaleToFill for table views
@implementation UIImageView(hook)

- (BOOL)isSizeFixed {
    return [objc_getAssociatedObject(self, @selector(isSizeFixed)) boolValue];
}

- (void)setIsSizeFixed:(BOOL)fixed {
    objc_setAssociatedObject(self, @selector(isSizeFixed), @(fixed), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)hook_setImage:(UIImage *)image {
    if (self.isSizeFixed) {
        UIImage *resizedImage = [image _imageWithSize:self.frame.size];
        [self hook_setImage:resizedImage];
    } else {
        [self hook_setImage:image];
    }
}

@end

// Implementation of UIImage hook for proper sizing across iOS versions
@implementation UIImage(hook)

- (UIImage *)hook_imageWithSize:(CGSize)size {
    if (CGSizeEqualToSize(self.size, size)) {
        return self;
    }
    
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = self.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];
    
    UIImage *newImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        // Calculate proper proportions
        CGFloat widthRatio = size.width / self.size.width;
        CGFloat heightRatio = size.height / self.size.height;
        CGFloat ratio = MIN(widthRatio, heightRatio);
        
        CGFloat newWidth = self.size.width * ratio;
        CGFloat newHeight = self.size.height * ratio;
        
        // Center the image
        CGFloat x = (size.width - newWidth) / 2;
        CGFloat y = (size.height - newHeight) / 2;
        
        [self drawInRect:CGRectMake(x, y, newWidth, newHeight)];
    }];
    
    return [newImage imageWithRenderingMode:self.renderingMode];
}

@end

// Patch: unimplemented get/set UIToolbar functions on tvOS
@implementation UINavigationController(hook)

- (UIToolbar *)hook_toolbar {
    UIToolbar *toolbar = objc_getAssociatedObject(self, @selector(toolbar));
    if (toolbar == nil) {
        toolbar = [[UIToolbar alloc] initWithFrame:
            CGRectMake(self.view.bounds.origin.x, self.view.bounds.size.height - 100,
            self.view.bounds.size.width, 100)];
        toolbar.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        toolbar.backgroundColor = UIColor.systemBackgroundColor;
        objc_setAssociatedObject(self, @selector(toolbar), toolbar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [self performSelector:@selector(_configureToolbar)];
    }
    return toolbar;
}

- (void)hook_setToolbar:(UIToolbar *)toolbar {
    objc_setAssociatedObject(self, @selector(toolbar), toolbar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end

// Patch: UISwitch crashes if platform == tvOS
@implementation UISwitch(hook)
+ (id)hook_visualElementForTraitCollection:(UITraitCollection *)collection {
    if (collection.userInterfaceIdiom == UIUserInterfaceIdiomTV) {
        UITraitCollection *override = [UITraitCollection traitCollectionWithUserInterfaceIdiom:UIUserInterfaceIdiomPad];
        UITraitCollection *new = [UITraitCollection traitCollectionWithTraitsFromCollections:@[collection, override]];
        return [self hook_visualElementForTraitCollection:new];
    }
    return [self hook_visualElementForTraitCollection:collection];
}
@end

@implementation UITraitCollection(hook)

- (UIUserInterfaceSizeClass)horizontalSizeClass {
    return UIUserInterfaceSizeClassRegular;
}

- (UIUserInterfaceSizeClass)verticalSizeClass {
    return UIUserInterfaceSizeClassRegular;
}

@end

@implementation UIWindow(hook)

+ (UIWindow *)mainWindow {
    return mainWindow;
}

+ (UIWindow *)externalWindow {
    return externalWindow;
}

- (UIViewController *)visibleViewController {
    // 修复上游 Issue #41：防御性检查 ——
    // 如果 self 不是 UIWindow（例如 __weak 全局变量被错误指向了其他对象），
    // 直接返回 nil 而不是访问 rootViewController 触发 unrecognized selector 崩溃。
    if (![self isKindOfClass:[UIWindow class]]) {
        return nil;
    }
    UIViewController *current = self.rootViewController;
    while (current.presentedViewController) {
        if ([current.presentedViewController isKindOfClass:UIAlertController.class] || [current.presentedViewController isKindOfClass:NSClassFromString(@"UIInputWindowController")]) {
            break;
        }
        current = current.presentedViewController;
    }
    if ([current isKindOfClass:UINavigationController.class]) {
        return [(UINavigationController *)current visibleViewController];
    } else {
        return current;
    }
}

@end

// This forces the navigation bar to keep its height (44dp) in landscape
@implementation UINavigationBar(forceFullHeightInLandscape)
- (BOOL)forceFullHeightInLandscape {
    return YES;
    //UIScreen.mainScreen.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
}
@end

// Patch: allow UIHoverGestureRecognizer on iPhone
// from TrollPad (https://github.com/khanhduytran0/TrollPad/commit/8eab1b20315e73ed7d5319ff0833564fe2819b30#diff-98dd369a9e94e4f3a4b45dc0288b6b5ec666b35eae93c9cde4375921cbb20e48)
@implementation UIPointerInteraction(hook)
- (void)hook__updateInteractionIsEnabled {
    UIView *view = self.view;
    BOOL enabled = self.enabled; // && view.traitCollection.userInterfaceIdiom == UIUserInterfaceIdiomPad
    if([self respondsToSelector:@selector(drivers)]) {
        for(id<_UIPointerInteractionDriver> driver in self.drivers) {
            driver.view = enabled ? view : nil;
        }
    } else {
        self.driver.view = enabled ? view : nil;
    }
    // to keep it fast, ivar offset is cached for later direct access
    static ptrdiff_t ivarOff = 0;
    if(!ivarOff) {
        ivarOff = ivar_getOffset(class_getInstanceVariable(self.class, "_observingPresentationNotification"));
    }

    BOOL *observingPresentationNotification = (BOOL *)((uint64_t)(__bridge void *)self + ivarOff);
    if(!enabled && *observingPresentationNotification) {
        [NSNotificationCenter.defaultCenter removeObserver:self name:UIPresentationControllerPresentationTransitionWillBeginNotification object:nil];
        *observingPresentationNotification = NO;
    }
}
@end

UIViewController* currentVC() {
    UIWindow *window = UIWindow.mainWindow;
    if (!window) return nil;
    return window.visibleViewController;
}

// ============================================================================
// ★ Task235（用户：“现在为什么依旧使用的是原生悬浮弹窗而不是液态玻璃”）：
//   UIAlertController 全局液态玻璃化。Task228 的分类口径是“软件 UI 原样、
//   玻璃只给悬浮件”——游戏内悬浮菜单（Task229）与悬浮栏（Task232）先后
//   上玻璃后，最大的“悬浮弹窗”家族（系统确认弹窗/动作表）仍是原生不透明
//   底。这里给弹窗私有容器（_UIAlertController*View）铺 T225 组合玻璃
//   （装机验证过的渲染路径）+ 重磨砂深色 + 白标题/正文（Task230 菜单同款
//   可读性教训；按钮内标签不动，保 tint 色）；Task232 同款拆无壁纸兑底
//   染色层（888903）。非玻璃风格零接触（原生外观逐字节不变）。安装点带
//   所有权守卫（见 init_hookUIKitConstructor）。
// ============================================================================
@implementation UIAlertController (Ame235GlassAlert)

- (void)ame235_hook_viewWillAppear:(BOOL)animated {
    [self ame235_hook_viewWillAppear:animated];   // 交换后 = 原实现
    @try {
        if (!LGCIsGlassStyleActive()) return;
        [self ame235_applyGlassToAlert];
    } @catch (NSException *ame235_e) {
        // 私有层级任何意外都绝不影响弹窗主链
    }
}

/// 找到弹窗私有容器并铺玻璃。容器类名含 “_UIAlertController”
/// （alert: _UIAlertControllerView / actionSheet:
/// _UIAlertControllerActionSheetView），BFS 深搜；找不到 = 优雅降级原生。
- (void)ame235_applyGlassToAlert {
    UIView *ame235_container = nil;
    NSMutableArray<UIView *> *ame235_stack = [NSMutableArray arrayWithObject:self.view];
    int ame235_visited = 0;
    while (ame235_stack.count > 0 && ame235_visited < 64) {
        UIView *ame235_v = [ame235_stack firstObject];
        [ame235_stack removeObjectAtIndex:0];
        ame235_visited++;
        if ([NSStringFromClass(ame235_v.class) containsString:@"_UIAlertController"]) {
            ame235_container = ame235_v;
            break;
        }
        [ame235_stack addObjectsFromArray:ame235_v.subviews];
    }
    if (ame235_container == nil) return;
    // 原生不透明底清空（宿主底色 + 图层底色都清，玻璃才能透出内容）
    ame235_container.backgroundColor = [UIColor clearColor];
    ame235_container.layer.backgroundColor = [UIColor clearColor].CGColor;
    CGFloat ame235_radius = ame235_container.layer.cornerRadius > 0.5
        ? ame235_container.layer.cornerRadius : 14.0;
    BOOL ame235_ok = LGCApplyGlassToView(ame235_container, ame235_radius);
    if (ame235_ok) {
        // ★ Task236（弹窗液态玻璃 v2）：
        // ① 防御性半透明底——LGC 接管时把宿主底色清成了 clearColor，磨砂层
        //   在本进程的可靠性两轮实锤存疑（Task228 黑面 / Task230 隐形）：
        //   systemBackground 55%（明暗自适应）铺在磨砂之下参与采样，磨砂
        //   可用 = 加深的玻璃弹窗，磨砂失效 = 仍是一块可读的半透明面板，
        //   绝不会变成“透明面板 + 悬浮文字”。
        ame235_container.backgroundColor = [[UIColor systemBackgroundColor]
            colorWithAlphaComponent:0.55];
        // ② 材质自适应（iOS 26 语义：浅色模式浅玻璃 / 深色模式深玻璃）——
        //   旧版恒 SystemMaterialDark，浅色模式下是一块突兀的黑。游戏内
        //   弹窗的深背景可读性由 ① 的半透明底承担。
        for (UIView *ame235_sub in [ame235_container.subviews copy]) {
            if (ame235_sub.tag == 888901 && [ame235_sub isKindOfClass:[UIVisualEffectView class]]) {
                [(UIVisualEffectView *)ame235_sub setEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterial]];
            }
            if (ame235_sub.tag == 888903) {
                [ame235_sub removeFromSuperview];
            }
        }
        // ③ 文字自适应（labelColor：深色模式白 / 浅色模式黑；旧版恒白在
        //   浅色玻璃上是白字白底）；按钮内标签不动，保系统 tint 色。
        NSMutableArray<UIView *> *ame235_lstack = [NSMutableArray arrayWithObject:ame235_container];
        while (ame235_lstack.count > 0) {
            UIView *ame235_lv = [ame235_lstack firstObject];
            [ame235_lstack removeObjectAtIndex:0];
            if ([ame235_lv isKindOfClass:[UILabel class]] &&
                ![ame235_lv.superview isKindOfClass:[UIControl class]]) {
                [(UILabel *)ame235_lv setTextColor:[UIColor labelColor]];
            }
            [ame235_lstack addObjectsFromArray:ame235_lv.subviews];
        }
    }
    static int ame235_logCount = 0;
    ame235_logCount++;
    if (ame235_logCount <= 5 || ame235_logCount % 25 == 0) {
        NSLog(@"[ThemeOps] Task236 alert glass v2 (#%d style=%ld ok=%d; present-hook double-shot, adaptive material+base)",
              ame235_logCount, (long)self.preferredStyle, (int)ame235_ok);
    }
}

@end

// ============================================================================
// ★ Task236：弹窗玻璃的【必定安装】钩子——交换 UIViewController 基类自有的
//   presentViewController:animated:completion:（Task235 的 viewWillAppear:
//   所有权守卫在用户系统上不成立时整链不装，弹窗维持原生 = “还是旧iOS”
//   的装机实锤）。弹窗呈现后双延时补玻璃：0s（viewDidLoad 层级已建）+
//   0.45s（越过转场与 UIKit 自身的底色回写）。只对 UIAlertController 且
//   玻璃风格激活时做事，其余呈现零开销直透。安体见 init_hookUIKitConstructor
//   的 Task236 块。
// ============================================================================
@implementation UIViewController (Ame236GlassPresent)

- (void)ame236_hook_presentViewController:(UIViewController *)viewControllerToPresent
                                  animated:(BOOL)flag
                                completion:(void (^)(void))completion {
    // 交换后 = 原实现
    [self ame236_hook_presentViewController:viewControllerToPresent animated:flag completion:completion];
    @try {
        if (![viewControllerToPresent isKindOfClass:[UIAlertController class]]) return;
        if (!LGCIsGlassStyleActive()) return;
        UIAlertController *ame236_alert = (UIAlertController *)viewControllerToPresent;
        dispatch_async(dispatch_get_main_queue(), ^{
            [ame236_alert ame235_applyGlassToAlert];
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [ame236_alert ame235_applyGlassToAlert];
        });
    } @catch (NSException *ame236_e) {
        // 任何意外绝不影响呈现主链
    }
}

@end
