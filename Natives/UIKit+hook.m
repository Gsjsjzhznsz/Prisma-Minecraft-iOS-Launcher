#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "LauncherPreferences.h"
#import "UIKit+hook.h"
#import "utils.h"
#import "AmeFloatingMenu.h"   // ★ Task237：悬浮菜单中央路由（钩子实现所在）

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

    // ★ Task237（用户指令：“彻底重写所有悬浮菜单样式。不要使用原生
    //   UIAlertController 加魔改，也不要出现原生与液态玻璃混杂”）：
    //   Task235/236 的“UIAlertController 玻璃化”双钩子整体退役——那套
    //   方案把玻璃层塞进系统弹窗的私有视图层级，装机两轮实锤“原生与
    //   玻璃混杂”。新架构：交换 UIViewController 基类自有的
    //   presentViewController:animated:completion:（Task236 已验证该
    //   交换点在本工程可用），玻璃风格下 UIAlertController 【永不上屏】，
    //   由 AmeFloatingMenu 的全自定义液态玻璃悬浮菜单整体接管渲染
    //   （镜像失败/非玻璃风格一律零开销直透 = 原生弹窗逐字节不变）。
    //   实现见 Natives/AmeFloatingMenu.m 尾部的
    //   UIViewController(Ame237FloatingMenuRouter) 分类。
    {
        Method ame237_orig = class_getInstanceMethod([UIViewController class],
                                                      @selector(presentViewController:animated:completion:));
        Method ame237_hook = class_getInstanceMethod([UIViewController class],
                                                      @selector(ame237_hook_presentViewController:animated:completion:));
        if (ame237_orig != NULL && ame237_hook != NULL) {
            method_exchangeImplementations(ame237_orig, ame237_hook);
            NSLog(@"[AmeMenu] Task237 floating-menu router installed (glass style presents custom menus; native style passes through)");
        } else {
            NSLog(@"[AmeMenu] Task237 floating-menu router SKIPPED (base selector missing -- unexpected)");
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

// Task237：Task235/236 的 UIAlertController(Ame235GlassAlert) 与
// UIViewController(Ame236GlassPresent) 两个魔改分类已随本轮“悬浮菜单
// 彻底重写”整体退役（玻璃化改由 Natives/AmeFloatingMenu.m 的全自定义
// 液态玻璃悬浮菜单整体接管，原生弹窗在玻璃风格下永不上屏）。
