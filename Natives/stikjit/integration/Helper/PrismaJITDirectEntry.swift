import Foundation

// ★ Task301（内置 JIT 第三轨 · 自重拉起子进程入口，编入 libPrismaJITCoordinator.dylib）：
//   装机 2c6458a latestlog 实锤 Task299 direct-spawn 轨死因：LC guest 内
//   posix_spawn PlugIns/PrismaJITHelper.appex/PrismaJITDirect（size=5018720 在场）
//   rc=1 errno=2 —— AMFI 拒绝 exec 该嵌套二进制（重签工具未覆盖 appex 内嵌
//   签名/信任链）。主二进制本身 exec 必合法（它正在跑），故第三轨：
//   协调器 posix_spawn【主二进制自身】+ env PRISMA_JIT_HELPER_CHILD=1，
//   main.m 顶端分支 dlopen 协调器 dylib 后调本入口，串行执行与 Direct 轨
//   完全相同的 StikJIT.enableJIT 全链（RSD 探测 → DDI 下载/挂载 → debugserver
//   vAttach 宿主 PID → universal 脚本协议），结果原子写回 RESULT_FILE。
//
//   与 PrismaJITDirect.swift（独立 appex 二进制，@main+exit）同语义：
//   本入口返回码代替 exit()（宿主 main.m 按返回值 _exit），env 三键一致：
//   PRISMA_JIT_TARGET_PID / PRISMA_JIT_PAIRING_FILE / PRISMA_JIT_RESULT_FILE。
//   编译单元与 StikJIT 核心同 swiftc（run#906 家法：同模块直接可见，无 import）。

@_cdecl("prisma_jit_direct_main")
public func prisma_jit_direct_main() -> Int32 {
    let env = ProcessInfo.processInfo.environment
    guard let pidStr = env["PRISMA_JIT_TARGET_PID"], let targetPID = Int32(pidStr),
          let pairingPath = env["PRISMA_JIT_PAIRING_FILE"],
          let resultPath = env["PRISMA_JIT_RESULT_FILE"] else {
        NSLog("[PrismaJITDirect] [self-relaunch] missing env (TARGET_PID/PAIRING_FILE/RESULT_FILE) -- nothing to do")
        return 2
    }
    NSLog("[PrismaJITDirect] [self-relaunch] direct track start (pid=%d, pairing=%@)",
          targetPID, pairingPath as NSString)

    let manager = FileManager.default
    // 与 XPC/Direct 轨一致的持久布局：DDI 缓存放 Library/PrismaJIT/DDI
    // （子进程继承宿主沙盒，Library 即宿主 Library，跨会话持久）
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
                NSLog("[PrismaJITDirect] [self-relaunch] prepare: %@", lastStage)
            },
            progress: { line in
                lastStage = "script: \(line)"
                NSLog("[PrismaJITDirect] [self-relaunch] %@", line)
            })
        NSLog("[PrismaJITDirect] [self-relaunch] JIT enabled for pid %d", targetPID)
        PrismaJITDirectEntry.ame301WriteResult(resultPath, true,
                                               "JIT enabled by the built-in Prisma JIT Helper (self-relaunch track).")
        return 0
    } catch {
        NSLog("[PrismaJITDirect] [self-relaunch] FAILED at stage '%@': %@", lastStage, "\(error)")
        PrismaJITDirectEntry.ame301WriteResult(resultPath, false, "[\(lastStage)] \(error.localizedDescription)")
        return 1
    }
}

private enum PrismaJITDirectEntry {
    // 原子写结果文件（协调器轮询以文件存在+内容为准；PrismaJITDirect 同语义）
    static func ame301WriteResult(_ path: String, _ ok: Bool, _ message: String) {
        let payload = "\(ok ? 1 : 0)\t\(message)"
        try? payload.write(toFile: path, atomically: true, encoding: .utf8)
        if !FileManager.default.fileExists(atPath: path) {
            NSLog("[PrismaJITDirect] [self-relaunch] result write FAILED to %@", path)
        }
    }
}
