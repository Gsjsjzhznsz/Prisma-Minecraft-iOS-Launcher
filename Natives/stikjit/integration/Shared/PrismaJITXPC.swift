import Foundation

// ★ Task293（PocketJ JITIntegration · StikJIT 对标移植 · 内置 JIT 第二阶段）：
//   宿主 App 与 Helper appex 之间的 XPC 消息协议（同谱系 PocketJ 的
//   PocketJJITXPC.swift 同构移植，命名空间换 Prisma）。宿主把目标 PID 与
//   配对文件数据（Data 跨进程传递，Helper 进程内落临时文件即用即删，避免
//   App Group 依赖——INTEGRATION.md 推荐做法）发给 Helper；Helper 回包
//   success/message。双端共同编译本文件保证 Codable 布局一致。

public struct PrismaJITMessage: Codable, Sendable {
    public let targetPID: Int32
    public let pairingData: Data

    public init(targetPID: Int32, pairingData: Data) {
        self.targetPID = targetPID
        self.pairingData = pairingData
    }

    public struct Response: Codable, Sendable {
        public let success: Bool
        public let message: String

        public init(success: Bool, message: String) {
            self.success = success
            self.message = message
        }
    }
}
