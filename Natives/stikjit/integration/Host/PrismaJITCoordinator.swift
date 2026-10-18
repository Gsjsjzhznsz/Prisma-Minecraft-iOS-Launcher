import ExtensionFoundation
import Foundation
import XPC

// ★ Task293（内置 JIT 第二阶段 · 宿主侧协调器，PocketJJITCoordinator 同构）：
//   iOS 26 AppExtensionProcess 机制——宿主进程派生独立 Helper appex 进程，
//   由 Helper 通过 RSD/LocalDevVPN → debugserver vAttach 目标 PID（避免
//   同进程自附加死锁，PocketJ 上游已定案 vAttach 挂起即自锁死），挂载
//   DDI 并按 universal 脚本协议完成 JIT 授予。本类编译为独立 dylib
//   （libPrismaJITCoordinator.dylib，min target 26.0），由 ObjC 侧在
//   @available(iOS 26) 分支 dlopen（不强链，iOS 26 以下不加载——
//   INTEGRATION.md "Do not strongly link" 要求）。

@available(iOS 26.0, *)
@objc(PrismaJITCoordinator)
public final class PrismaJITCoordinator: NSObject {
    private static var activeSession: AnyObject?

    @objc(enableJITWithTargetPID:pairingData:completion:)
    public static func enableJIT(targetPID: Int32, pairingData: Data,
                                 completion: @escaping (Bool, String) -> Void) {
        guard #available(iOS 26.0, *) else {
            completion(false, "Built-in JIT requires iOS 26 or later.")
            return
        }

        Task { @MainActor in
            do {
                let monitor = try await AppExtensionPoint.Monitor(
                    appExtensionPoint: .prismaJITHelper)
                // Task294 取证：装机“无法开启 JIT”分层定位（discovery 层）。
                // identities 为空最常见于签名工具未重签 PlugIns 内 appex。
                let identities = monitor.identities
                let firstID = identities.first?.bundleIdentifier ?? "none"
                NSLog("[JIT] Task294 monitor: \(identities.count) helper identity(ies) discovered, first=\(firstID)")
                guard let identity = identities.first else {
                    throw NSError(domain: "PrismaJIT", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "Prisma JIT Helper was not found in this installation."])
                }

                let process = try await AppExtensionProcess(configuration: .init(
                    appExtensionIdentity: identity,
                    onInterruption: { activeSession = nil }))
                let xpcSession = try process.makeXPCSession()
                try xpcSession.activate()
                NSLog("[JIT] Task294 helper process launched + XPC activated")
                activeSession = PrismaJITSession(process: process, session: xpcSession)
                let request = PrismaJITMessage(targetPID: targetPID,
                                               pairingData: pairingData)
                try xpcSession.send(request) {
                    (result: Result<PrismaJITMessage.Response, any Error>) in
                    activeSession = nil
                    switch result {
                    case .success(let response):
                        NSLog("[JIT] Task294 XPC response: success=\(response.success) msg=\(response.message)")
                        DispatchQueue.main.async {
                            completion(response.success, response.message)
                        }
                    case .failure(let error):
                        // Task294 取证：XPC 层失败（Helper 中途退出/编码失败等）
                        NSLog("[JIT] Task294 XPC send failed: \(error)")
                        DispatchQueue.main.async {
                            completion(false, error.localizedDescription)
                        }
                    }
                }
            } catch {
                // Task294 取证：discovery/spawn/activate 层失败进 latestlog
                NSLog("[JIT] Task294 coordinator error: \(error)")
                activeSession = nil
                completion(false, error.localizedDescription)
            }
        }
    }
}

// 会话持有物：进程+XPC 会话存活的锚点；deinit 时取消会话并失效进程
// （PocketJJITSession 同语义——请求结束/中断后释放 Helper 进程）。
@available(iOS 26.0, *)
private final class PrismaJITSession {
    let process: AppExtensionProcess
    let session: XPCSession

    init(process: AppExtensionProcess, session: XPCSession) {
        self.process = process
        self.session = session
    }

    deinit {
        session.cancel(reason: "Prisma JIT request finished")
        process.invalidate()
    }
}
