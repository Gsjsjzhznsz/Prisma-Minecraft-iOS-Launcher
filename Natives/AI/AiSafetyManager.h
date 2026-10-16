//
//  AiSafetyManager.h
//  Prisma
//
//  Prisma AI Agent 安全机制：根据 AiSettings.safetyMode 判断某权限级别是否需用户确认，
//  并在主线程弹出确认框；同时提供安全模式切换的中文提示。
//

#import <Foundation/Foundation.h>
#import "AiTool.h"

NS_ASSUME_NONNULL_BEGIN

@interface AiSafetyManager : NSObject

/// 单例
+ (instancetype)sharedManager;

/// 当前安全模式（读取 AiSettings.safetyMode）
- (AiSafetyMode)currentMode;

/// 判断某权限级别在当前安全模式下是否需要用户确认
- (BOOL)needsUserConfirmationForPermission:(AiToolPermission)permission;

/// 在主线程弹出确认框；「允许」回调 YES（危险操作按钮为「仍要执行」），「取消」回调 NO。
/// 若无法拿到可 present 的视图控制器，默认按「不允许」处理。
- (void)requestConfirmationWithTitle:(NSString *)title
                             message:(NSString *)message
                          completion:(void (^)(BOOL approved))completion;

/// 安全模式切换时的友好提示（展示当前模式中文说明）
- (void)showSafetyModeChangedHint;

/// 权限级别的中文说明（供提示/确认框复用）
- (NSString *)permissionChineseName:(AiToolPermission)permission;

/// 安全模式的中文说明
+ (NSString *)safetyModeChineseName:(AiSafetyMode)mode;

@end

NS_ASSUME_NONNULL_END