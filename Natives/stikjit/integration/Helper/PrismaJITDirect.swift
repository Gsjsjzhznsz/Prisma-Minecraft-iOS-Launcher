import Foundation

// ★ Task299（内置 JIT · 直启兜底二进制）：装机 7672dd9 latestlog 实锤
//   AppExtensionPoint.Monitor 在用户设备上三次重试均 Code=19 "Failed to add
//   observer"（Task295 老格式 / Task298 torrent7 全键格式双双证伪）——
//   discovery 层在该装机链路上不可用。本文件提供不经 ExtensionKit 的第二条
//   执行路径：宿主协调器 posix_spawn 本二进制（子进程继承宿主沙盒，可读
//   宿主 Library 的配对文件），由 env 传入 target PID / 配对文件 / 回写文件，
//   直接串行执行 StikJIT.enableJIT（RSD 探测 → DDI 下载/挂载 → debugserver
//   vAttach 宿主 PID → universal 脚本协议），结果原子写回 RESULT_FILE 后退出。
//
//   与 Helper appex（XPC 轨）并存互不影响：discovery 可用走 XPC（有进度），
//   不可用走本轨（无进度但有结果回包）。同一 swiftc 源集合，仅 main 不同。

// 与 PrismaJITHelper.swift 同语义的阶段感知执行核心（直启轨独立实现，
// 不与 XPC 轨共享文件以隔离改动面）。
@main
struct PrismaJITDirect {
    static func writeResult(_ path: String, _ ok: Bool, _ message: String) {
        let payload = "\(ok ? 1 : 0)\t\(message)"
        // 原子写：协调器轮询以文件存在+内容为准
        try? payload.write(toFile: path, atomically: true, encoding: .utf8)
        // 兜底再写一份带 O_SYNC 语义的（try? 已覆盖主路径；此处仅日志）
        if !FileManager.default.fileExists(atPath: path) {
            NSLog("[PrismaJITDirect] result write FAILED to %@", path)
        }
    }

    static func main() {
        let env = ProcessInfo.processInfo.environment
        guard let pidStr = env["PRISMA_JIT_TARGET_PID"], let targetPID = Int32(pidStr),
              let pairingPath = env["PRISMA_JIT_PAIRING_FILE"],
              let resultPath = env["PRISMA_JIT_RESULT_FILE"] else {
            NSLog("[PrismaJITDirect] missing env (TARGET_PID/PAIRING_FILE/RESULT_FILE) -- nothing to do")
            exit(2)
        }
        NSLog("[PrismaJITDirect] direct track start (pid=%d, pairing=%@)", targetPID, pairingPath as NSString)

        let manager = FileManager.default
        // 与 XPC 轨一致的持久布局：DDI 缓存放 Library/PrismaJIT/DDI
        // （直启子进程继承宿主沙盒，Library 即宿主 Library，跨会话持久）
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrismaJIT", isDirectory: true)
        var lastStage = "init"
        do {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            let pairingURL = URL(fileURLWithPath: pairingPath)
            guard manager.fileExists(atPath: pairingPath) else {
                throw NSError(domain: "PrismaJITDirect", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "pairing file missing at \(pairingPath)"])
            }
            let paths = DDIPaths.default(in: root)
            lastStage = "prepare(reachability/ddi)"
            try StikJIT.enableJIT(
                targetPID: targetPID,
                pairingFile: pairingURL,
                ddiPaths: paths,
                script: .universal,
                preparationProgress: { stage in
                    switch stage {
                    case .checkingReachability: lastStage = "check-reachability(LocalDevVPN 10.7.0.1:49152)"
                    case .checkingDDI: lastStage = "check-ddi"
                    case .downloadingDDI(let fraction, _): lastStage = String(format: "download-ddi(%.0f%%)", fraction * 100)
                    case .mountingDDI(let fraction): lastStage = String(format: "mount-ddi(%.0f%%)", fraction * 100)
                    case .verifyingDDI: lastStage = "verify-ddi"
                    case .ready: lastStage = "device-ready"
                    }
                    NSLog("[PrismaJITDirect] prepare: %@", lastStage)
                },
                progress: { line in
                    lastStage = "script: \(line)"
                    NSLog("[PrismaJITDirect] %@", line)
                })
            NSLog("[PrismaJITDirect] JIT enabled for pid %d", targetPID)
            writeResult(resultPath, true,
                        "JIT enabled by the built-in Prisma JIT Helper (direct track).")
            exit(0)
        } catch {
            NSLog("[PrismaJITDirect] FAILED at stage '%@': %@", lastStage, "\(error)")
            writeResult(resultPath, false, "[\(lastStage)] \(error.localizedDescription)")
            exit(1)
        }
    }
}
