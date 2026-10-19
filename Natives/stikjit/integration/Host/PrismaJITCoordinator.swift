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
//
// ★ Task299（装机 7672dd9 latestlog 实锤 + PocketJ v1.4 官方 IPA 逐字节对照）：
//   ① appexpt 对齐上游编译器生成形态（EXVersion=2 + 点键字典仅
//      EXExtensionPointName；Task298 的 _EXScopeRestriction/EXPresentsUser
//      Interface 双键是 torrent7 私有形态，装机 Code=19 证伪）；
//   ② discovery 在部分装机链路上仍可能不可用（三次重试均 Code=19）——
//      新增直启兜底轨：posix_spawn appex 内 PrismaJITDirect 二进制（子进程
//      继承宿主沙盒），env 传 target PID/配对文件/结果文件，Helper 侧
//      StikJIT.enableJIT 全链不变，结果文件握手回包。XPC 轨仍优先
//      （有进度回包），兜底轨仅在 discovery 不可用时启用。

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
                // ★ Task295（装机 latestlog 实锤 Code=19 "Failed to add observer"）：
                //   Monitor 初始化即抛——extensionkitd 拒绝注册观察者。PocketJ 上游
                //   build_pocketj.sh 注释定案同款病历：宿主包缺 Extensions/*.appexpt
                //   （扩展点定义，Xcode 构建由 Swift 编译器写入，swiftc 直编需自嵌）。
                //   构建侧已补 appexpt + appex 落 Extensions/；此处加固：①Monitor
                //   三次重试（extensionkitd 偶发未就绪）②失败错误带 [discovery]
                //   阶段前缀 + 指向打包缺口，装机弹窗/日志直达卡点。
                var identities: [AppExtensionIdentity] = []
                var monitorError: Error?
                for attempt in 1...3 {
                    do {
                        let monitor = try await AppExtensionPoint.Monitor(
                            appExtensionPoint: .prismaJITHelper)
                        // Task294 取证：装机"无法开启 JIT"分层定位（discovery 层）。
                        // identities 为空最常见于签名工具未重签 appex / 定义缺失。
                        identities = monitor.identities
                        monitorError = nil
                        break
                    } catch {
                        monitorError = error
                        NSLog("[JIT] Task295 monitor attempt \(attempt)/3 failed: \(error)")
                        if attempt < 3 {
                            try? await Task.sleep(nanoseconds: 300_000_000)
                        }
                    }
                }
                if identities.first == nil {
                    // ★ Task299 直启兜底轨：discovery 不可用（monitor Code=19 三次
                    //   重试耗尽 / 观察者可用但 identities 为空）不再直接判死——
                    //   posix_spawn appex 内 PrismaJITDirect（绕过 ExtensionKit）。
                    NSLog("[JIT] Task299 discovery unavailable (monitorError=\(monitorError.map { String(describing: $0) } ?? "identities-empty")) -- direct-spawn fallback (bypassing ExtensionKit)")
                    let (ok, message) = try await PrismaJITCoordinator.directSpawnEnableJIT(
                        targetPID: targetPID, pairingData: pairingData)
                    DispatchQueue.main.async {
                        completion(ok, message)
                    }
                    return
                }
                let identity = identities.first!
                NSLog("[JIT] Task299 monitor: \(identities.count) helper identity(ies) discovered, first=\(identity.bundleIdentifier ?? "none")")

                let process: AppExtensionProcess
                do {
                    process = try await AppExtensionProcess(configuration: .init(
                        appExtensionIdentity: identity,
                        onInterruption: { activeSession = nil }))
                } catch {
                    NSLog("[JIT] Task295 spawn failed: \(error)")
                    throw NSError(domain: "PrismaJIT", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "[spawn] \(error.localizedDescription)"])
                }
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
                // Task294/299 取证：discovery/spawn/activate/direct-spawn 层失败进 latestlog
                NSLog("[JIT] Task299 coordinator error: \(error)")
                activeSession = nil
                completion(false, error.localizedDescription)
            }
        }
    }

    // ★ Task299 直启兜底轨：posix_spawn appex 内 PrismaJITDirect，
    //   env 握手（target PID / 配对文件 / 结果文件），轮询结果文件回包。
    //   首跑含 DDI 下载可能耗时数分钟 → 轮询上限 600s；子进程无结果即退
    //   也要报错（stage 日志在 [PrismaJITDirect] 前缀下可对单）。
    private static func directSpawnEnableJIT(targetPID: Int32,
                                             pairingData: Data) async throws -> (Bool, String) {
        // ★ Task302：LiveContainer guest 结构性短路——LC guest 内
        //   Bundle.main.executablePath 位于 Documents/Applications/ 下
        //   （装机 c3e70c5 实锤：spawn 目标即该路径），posix_spawn 必被
        //   AMFI 拒（rc=1 errno=2），fork errno=1、ExtensionKit Code=19。
        //   三轨全死时不再给误导性 "re-sign with PlugIns/ intact" 建议
        //   （PlugIns 完好也没用）——直接如实报错指向外部开启工具。
        if let ame302Exec = Bundle.main.executablePath,
           ame302Exec.contains("/Documents/Applications/") {
            throw NSError(domain: "PrismaJIT", code: 25,
                          userInfo: [NSLocalizedDescriptionKey:
                            "[livecontainer] guest environment detected (exec under Documents/Applications) -- iOS refuses to spawn JIT helper processes here (ExtensionKit Code=19, posix_spawn errno=2, fork errno=1). Enable JIT via StikDebug/SideStore instead."])
        }
        let manager = FileManager.default
        let root = manager.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrismaJIT", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let pairingURL = root.appendingPathComponent("pairing-direct.plist")
        try pairingData.write(to: pairingURL, options: .atomic)
        let resultPath = root.appendingPathComponent("direct-result.txt").path
        try? manager.removeItem(atPath: resultPath)

        // ★ Task301 三候选自检序列（自重拉起轨优先）：①主二进制自身 ——
        //   exec 必合法（它正在跑；装机 2c6458a 实锤 LC guest 重签后 appex
        //   内嵌二进制被 AMFI 拒 errno=2），env 加 PRISMA_JIT_HELPER_CHILD=1
        //   + PRISMA_JIT_COORDINATOR_DYLIB，main.m 顶端分支 dlopen 协调器后
        //   调 @_cdecl("prisma_jit_direct_main") 入口（同单元 StikJIT 全链）；
        //   ②③ appex 内 PrismaJITDirect 两副本降为兜底（重签覆盖 PlugIns/
        //   的装机链路可救）。Task300 双路径解析语义保留。
        let bundleRoot = Bundle.main.bundlePath
        var ame301Candidates: [(path: String, isSelf: Bool)] = []
        if let ame301_mainExec = Bundle.main.executablePath {
            let ame301_dylibCandidates = [
                bundleRoot + "/Frameworks/libPrismaJITCoordinator.dylib"
            ]
            if let ame301_dylib = ame301_dylibCandidates.first(where: { manager.fileExists(atPath: $0) }) {
                ame301Candidates.append((ame301_mainExec, true))
                ame301_selfDylibOverride = ame301_dylib
            } else {
                NSLog("[JIT] Task301 self-relaunch skipped: coordinator dylib not found under %@/Frameworks", bundleRoot)
            }
        }
        if ame301Candidates.isEmpty {
            NSLog("[JIT] Task301 self-relaunch unavailable (executablePath=%@) -- appex fallback only",
                  Bundle.main.executablePath ?? "nil")
        }
        ame301Candidates.append((bundleRoot + "/PlugIns/PrismaJITHelper.appex/PrismaJITDirect", false))
        ame301Candidates.append((bundleRoot + "/Extensions/PrismaJITHelper.appex/PrismaJITDirect", false))
        guard let ame301_chosen = ame301Candidates.first(where: { manager.fileExists(atPath: $0.path) }) else {
            let ame300Probe = ame301Candidates
                .map { "\($0.path)=\(manager.fileExists(atPath: $0.path))" }
                .joined(separator: " ")
            throw NSError(domain: "PrismaJIT", code: 21,
                          userInfo: [NSLocalizedDescriptionKey:
                            "[direct-spawn] no spawnable JIT helper candidate (\(ame300Probe)) -- reinstall a build with the embedded JIT helper (keep PlugIns/ when re-signing)"])
        }
        let execPath = ame301_chosen.path

        var envLines: [String] = ProcessInfo.processInfo.environment.map { "\($0.key)=\($0.value)" }
        envLines.append("PRISMA_JIT_TARGET_PID=\(targetPID)")
        envLines.append("PRISMA_JIT_PAIRING_FILE=\(pairingURL.path)")
        envLines.append("PRISMA_JIT_RESULT_FILE=\(resultPath)")
        if ame301_chosen.isSelf, let ame301_dylib = ame301_selfDylibOverride {
            envLines.append("PRISMA_JIT_HELPER_CHILD=1")
            envLines.append("PRISMA_JIT_COORDINATOR_DYLIB=\(ame301_dylib)")
        }

        var childPID: pid_t = 0
        let rc = execDirectBinary(path: execPath, envLines: envLines, pidOut: &childPID)
        if rc != 0 {
            let spawnErrno = errno
            // Task300：带上被拒路径与体积。Task306：文案中性化——非越狱
            // 直装（无 no-sandbox/dynamic-codesigning entitlement）下
            // posix_spawn 结构性被拒（Task43 shaderc 真机恒 EPERM 同源），
            // 重签 PlugIns/ 救不了，不再给误导性 re-sign 建议（宿主侧
            // Task306 gate 已拦截绝大多数此类调用，本串为兜底日志）。
            let binSize = (try? manager.attributesOfItem(atPath: execPath))?[.size] as? Int ?? -1
            throw NSError(domain: "PrismaJIT", code: 22,
                          userInfo: [NSLocalizedDescriptionKey:
                            "[direct-spawn] posix_spawn rc=\(rc) errno=\(spawnErrno) on \(execPath) (size=\(binSize)) -- exec denied by sandbox/AMFI on this install (non-jailbroken hosts without no-sandbox/dynamic-codesigning entitlements deny spawning structurally; re-signing will not help). Enable JIT via the StikDebug deep-link track instead (set JIT enabler to Auto)."])
        }
        NSLog("[JIT] Task299 direct helper spawned pid=%d result=%@", childPID, resultPath as NSString)

        // 轮询结果文件（首跑 DDI 下载可达数分钟）+ 子进程退出侦测
        for _ in 0..<300 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            if let raw = try? String(contentsOfFile: resultPath, encoding: .utf8),
               !raw.isEmpty {
                let parts = raw.split(separator: "\t", maxSplits: 1,
                                      omittingEmptySubsequences: false)
                let ok = parts.first.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                } ?? false
                let message = parts.count > 1
                    ? String(parts[1])
                    : raw.trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[JIT] Task299 direct track result: ok=\(ok) message=\(message)")
                return (ok, message)
            }
            var exitStatus: Int32 = 0
            if waitpid(childPID, &exitStatus, WNOHANG) == childPID {
                throw NSError(domain: "PrismaJIT", code: 23,
                              userInfo: [NSLocalizedDescriptionKey:
                                "[direct-spawn] helper exited (status=\(exitStatus)) without result -- see [PrismaJITDirect] stage logs (reachability/DDI/attach/script)"])
            }
        }
        throw NSError(domain: "PrismaJIT", code: 24,
                      userInfo: [NSLocalizedDescriptionKey:
                        "[direct-spawn] timeout (600s) waiting for helper result -- first-run DDI download slow, or LocalDevVPN/pairing not ready"])
    }

    // posix_spawn（char** 手工封组；strdup 区在 spawn 返回后统一释放）
    private static func execDirectBinary(path: String,
                                         envLines: [String],
                                         pidOut: UnsafeMutablePointer<pid_t>) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] = []
        var envp: [UnsafeMutablePointer<CChar>?] = []
        var arena: [UnsafeMutablePointer<CChar>] = []
        let arg0 = strdup(path)!; arena.append(arg0); argv.append(arg0)
        argv.append(nil)
        for line in envLines {
            let p = strdup(line)!; arena.append(p); envp.append(p)
        }
        envp.append(nil)
        defer { for p in arena { free(p) } }
        return posix_spawn(pidOut, path, nil, nil, &argv, &envp)
    }

    // Task301：自重拉起轨的协调器 dylib 路径（directSpawnEnableJIT 内局部传递；
    // 声明为静态存储避免闭包捕获复杂度）
    private static var ame301_selfDylibOverride: String?
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
