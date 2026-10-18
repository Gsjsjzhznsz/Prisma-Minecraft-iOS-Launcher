import ExtensionFoundation
import Foundation
import XPC

// ★ Task293（内置 JIT 第二阶段 · Helper appex 进程，PocketJJITHelper 同构）：
//   独立进程内串行执行 StikJIT.enableJIT（RSD 探测 → DDI 下载/挂载 →
//   debugserver vAttach 宿主 PID → universal 脚本协议 → detach）。配对文件
//   由宿主以 Data 跨进程传入，Helper 写入自己沙盒的 Library/PrismaJIT/
//   pairingFile.plist 即用即删（INTEGRATION.md 推荐模式，免 App Group）；
//   DDI 缓存持久放 Helper 自己的 Library/PrismaJIT/DDI。
//
//   ⚠️ StikJIT 的准备/开启 API 是同步阻塞式——按上游要求固定单条串行
//   队列执行，不拆并发、不包 async。
//   注：StikJIT 源文件与 Helper 同一 swiftc 编译单元（run#906 实锤
//   "no such module 'StikJIT'"——没有独立 StikJIT module 可 import），
//   同模块内 StikJIT.enableJIT 直接可见，无需 import。

private struct PrismaJITMessageHandler: XPCPeerHandler {
    func handleIncomingRequest(_ message: PrismaJITMessage) -> (any Encodable)? {
        let manager = FileManager.default
        // Helper 进程自有可写沙盒：配对文件与个性化 DDI 缓存都在这里
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrismaJIT", isDirectory: true)
        let pairingURL = root.appendingPathComponent("pairingFile.plist")
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try message.pairingData.write(to: pairingURL, options: .atomic)
            defer { try? manager.removeItem(at: pairingURL) }

            let paths = DDIPaths.default(in: root)
            try StikJIT.enableJIT(
                targetPID: message.targetPID,
                pairingFile: pairingURL,
                ddiPaths: paths,
                script: .universal,
                progress: { NSLog("[PrismaJIT] %@", $0) })
            return PrismaJITMessage.Response(
                success: true,
                message: "JIT enabled by the built-in Prisma JIT Helper.")
        } catch {
            return PrismaJITMessage.Response(
                success: false,
                message: error.localizedDescription)
        }
    }
}

@main
struct PrismaJITHelperExtension: AppExtension {
    @AppExtensionPoint.Bind
    var extensionPoint: AppExtensionPoint {
        AppExtensionPoint.Identifier(
            host: "com.prisma-devs.prisma",
            name: "PrismaJITHelper")
    }

    var configuration: some AppExtensionConfiguration {
        ConnectionHandler(onSessionRequest: { request in
            request.accept { _ in
                PrismaJITMessageHandler()
            }
        })
    }
}
