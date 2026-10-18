//
//  StikDebugEngine.h
//  Amethyst
//
//  ★ Task291（PocketJ 对标移植 · 内置 JIT 第一阶段）：
//  PocketJ Natives/stikdebug/StikDebugEngine 的 Prisma 适配版。
//  上游：StikDebug（https://github.com/StikDebug/StikDebug，AGPL-3.0）→
//  PocketJLauncher ObjC 集成层 → 本仓。
//  本阶段职责 = 配对文件生命周期管理（导入/导出/删除/Documents 自动同步）
//  + LocalDevVPN 连通性探针（10.7.0.1:49152 socket 试连）。
//  进程内自附加被 PocketJ 上游 #if 0 定案（debugserver vAttach 即挂起
//  目标进程，同进程无法应答 = 确定性自锁死），独立执行进程轨（iOS 26
//  AppExtensionProcess helper + StikJIT framework）已于 Task293 第二阶段
//  落地（Natives/stikjit/ + Makefile jit_helper 轨）；本引擎继续负责
//  配对文件生命周期与 VPN 探针，"开启 JIT"动作内置轨优先、深链降级。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface StikDebugEngine : NSObject

+ (instancetype)sharedEngine;

/// App Support/Pairing/pairingFile.plist（引擎私有权威副本）
@property(nonatomic, readonly, copy) NSString *pairingFilePath;
/// Documents/pairingFile.plist（用户可经由文件 App/Finder 放置的落地副本）
@property(nonatomic, readonly, copy) NSString *documentsPairingFilePath;
/// 权威副本是否在位
@property(nonatomic, readonly) BOOL hasPairingFile;

/// 从 Documents 副本同步到权威路径（用户拖入后进入页面即生效）；无源文件时幂等返回现状
- (BOOL)synchronizePairingFileFromDocuments:(NSError **)error;

/// 文档选择器导入（security-scoped 读取 + 双副本落盘 + 0600 权限）
- (BOOL)importPairingFileAtURL:(NSURL *)URL error:(NSError **)error;

/// 删除两处副本
- (BOOL)deletePairingFile:(NSError **)error;

/// 导出用 Documents 副本 URL（先同步再校验，失败返回 nil 并带出错误）
- (nullable NSURL *)exportablePairingFileURL:(NSError **)error;

/// LocalDevVPN 连通性探测（后台线程 socket 试连 10.7.0.1:49152，600ms 超时，主线程回调）
- (void)checkLocalDevVPNWithCompletion:(void (^)(BOOL connected))completion;

@end

NS_ASSUME_NONNULL_END
