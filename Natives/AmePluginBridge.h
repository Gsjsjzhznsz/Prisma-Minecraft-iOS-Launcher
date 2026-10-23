//
//  AmePluginBridge.h
//  Amethyst
//
//  Task318：插件桥接器 —— JS 门面（全局 `prisma` 对象），权限强制执行边界。
//
//  设计定案：所有权限检查集中在本文件的方法入口——JS 侧能摸到的每一个
//  能力都先过授权闸，未授权 = NSLog 留痕 + 拒绝（返回 null/false），JS 无法
//  绕过（context 里只有这个 facade，没有裸露的 ObjC 原生对象）。
//

#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

NS_ASSUME_NONNULL_BEGIN

@interface AmePluginBridge : NSObject

/// 在指定 JSContext 注入 `prisma` 门面。
/// eventSink：插件通过 prisma.on(event, handler) 订阅事件时回调
/// （events 权限已在桥接层验过，sink 只管收）。
+ (void)installFacadeInContext:(JSContext *)context
                       pluginId:(NSString *)pluginId
                      eventSink:(void (^)(NSString *event, JSValue *handler))eventSink;

/// 渲染器 key 是否合法且可用（候选表 + dylib 存在性；"auto"/"mg" 恒真）。
/// 供运行时预检与调试页使用。
+ (BOOL)isRendererKeyAvailable:(NSString *)key;

@end

NS_ASSUME_NONNULL_END
