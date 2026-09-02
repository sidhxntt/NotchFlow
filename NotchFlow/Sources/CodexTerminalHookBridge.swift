import Foundation
import AppKit

/// Compatibility listener for Codex sessions started in Terminal.
///
/// The user's existing `~/.codex/hooks.json` already invokes AgentNotch's
/// `notch-codex-hook.py`. Rather than rewriting that user-owned configuration,
/// NotchFlow speaks the same private Unix-socket protocol while it is running.
/// Each hook process remains blocked until the user chooses in the Agent tab.
@MainActor
final class CodexTerminalHookBridge: ObservableObject {
    static let shared = CodexTerminalHookBridge()

    enum Decision { case approve, deny }

    @Published private(set) var sessionQueues: [AgentApprovalSessionQueue] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var lastError: String?
    @Published private(set) var hookConfigurationMessage: String?
    @Published private(set) var canRepairHookConfiguration = false

    private var queue = AgentApprovalQueue()
    private var connections: [String: HookConnection] = [:]
    private var listenFD: Int32 = -1
    private var hierarchyObservation: UUID?
    private var hookConfigurationURL: URL?

    private static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentNotch/notch.sock").path
    }

    private static var currentClaudeHookScriptPath: String? {
        AppSupportPaths.appDirectory?
            .appendingPathComponent("ClaudeHook/claude-hook.py").path
    }

    private static var globalHookConfigurationURLs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".claude/settings.json"),
            home.appendingPathComponent(".codex/hooks.json")
        ]
    }

    var hasPendingApprovals: Bool { !sessionQueues.isEmpty }

    private init() {
        hierarchyObservation = AgentSessionActivityStore.shared.observeCodexHierarchy { [weak self] hierarchy in
            self?.queue.regroup(using: hierarchy)
            self?.publishQueue()
        }
    }

    func startIfNeeded() {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard listenFD < 0 else { return }
        do {
            listenFD = try Self.bindListener(at: Self.socketPath)
        } catch {
            lastError = error.localizedDescription
            return
        }
        let fd = listenFD
        let listener = Thread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    return
                }
                let connection = HookConnection(fd: client)
                let worker = Thread { Self.serve(connection, bridge: self) }
                worker.name = "com.notchflow.codex-terminal-approval"
                worker.start()
            }
        }
        listener.name = "com.notchflow.codex-terminal-approvals"
        listener.start()
        isAvailable = true
        lastError = nil
    }

    func shutdownForLicenseBlock() {
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        unlink(Self.socketPath)
        connections.values.forEach { $0.close() }
        connections.removeAll()
        queue = AgentApprovalQueue()
        publishQueue()
        isAvailable = false
    }

    /// User-owned global hook configs can contain several tools. Inspect them at
    /// launch, but do not write one until the user explicitly chooses Repair.
    func inspectGlobalHookConfiguration() {
        guard let expectedScriptPath = Self.currentClaudeHookScriptPath else { return }
        hookConfigurationMessage = nil
        canRepairHookConfiguration = false
        hookConfigurationURL = nil

        for url in Self.globalHookConfigurationURLs {
            guard let data = try? Data(contentsOf: url),
                  let configuration = try? JSONSerialization.jsonObject(with: data),
                  !HookConfigurationRepair.staleClaudeCommands(in: configuration,
                                                               expectedScriptPath: expectedScriptPath).isEmpty
            else { continue }

            let repaired = HookConfigurationRepair.repairingStaleClaudeCommands(
                in: configuration, expectedScriptPath: expectedScriptPath)
            hookConfigurationURL = url
            canRepairHookConfiguration = repaired.replacements > 0
            let displayPath = url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path,
                                                             with: "~")
            hookConfigurationMessage = repaired.replacements > 0
                ? "\(displayPath) points to an old NotchFlow approval hook. Repair it to restore approvals."
                : "\(displayPath) contains an unfamiliar NotchFlow hook command. Review it before using approvals."
            return
        }
    }

    func repairGlobalHookConfiguration() {
        guard let url = hookConfigurationURL,
              let expectedScriptPath = Self.currentClaudeHookScriptPath,
              let data = try? Data(contentsOf: url),
              let configuration = try? JSONSerialization.jsonObject(with: data)
        else { return }

        let repaired = HookConfigurationRepair.repairingStaleClaudeCommands(
            in: configuration, expectedScriptPath: expectedScriptPath)
        guard repaired.replacements > 0,
              JSONSerialization.isValidJSONObject(repaired.value)
        else { inspectGlobalHookConfiguration(); return }
        do {
            let backupURL = url.deletingPathExtension().appendingPathExtension("notchflow-backup.json")
            try data.write(to: backupURL, options: .atomic)
            let serialized = try JSONSerialization.data(withJSONObject: repaired.value,
                                                        options: [.prettyPrinted, .sortedKeys])
            try serialized.write(to: url, options: .atomic)
            inspectGlobalHookConfiguration()
        } catch {
            lastError = "Could not repair the global hook config: \(error.localizedDescription)"
        }
    }

    func revealGlobalHookConfiguration() {
        guard let url = hookConfigurationURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func decide(_ decision: Decision, for approval: AgentApproval) {
        guard let connection = connections.removeValue(forKey: approval.id) else {
            queue.resolve(id: approval.id)
            publishQueue()
            return
        }
        let mapped: CodexTerminalHookDecision = decision == .approve ? .approve : .deny
        if !connection.send(line: CodexTerminalHookResponse.line(for: mapped)) {
            lastError = "Could not send the Codex decision"
        }
        AgentSessionActivityStore.shared.resolveApproval(approval)
        queue.resolve(id: approval.id)
        publishQueue()
    }

    private nonisolated static func serve(_ connection: HookConnection,
                                          bridge: CodexTerminalHookBridge) {
        defer { connection.close() }
        guard let line = connection.readLine() else { return }
        if let marker = AgentSessionMarker.decode(line) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentSessionActivityStore.shared.record(marker: marker) }
            }
            return
        }
        guard let request = CodexTerminalHookRequest.decode(line) else { return }
        let identity = TerminalConnectionIdentity()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { bridge.enqueue(request, connection: connection, identity: identity) }
        }
        connection.waitForPeerClose()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { bridge.withdraw(identity: identity) }
        }
    }

    private func enqueue(_ request: CodexTerminalHookRequest, connection: HookConnection,
                         identity: TerminalConnectionIdentity) {
        let approval = AgentSessionActivityStore.shared.groupedForPresentation(request.approval)
        let id = approval.id
        identity.approvalID = id
        connections[id] = connection
        queue.enqueue(approval)
        AgentSessionActivityStore.shared.recordApproval(approval)
        publishQueue()
        playApprovalPing()
    }

    /// The hook process ended without an answer — a cancelled or killed run. The
    /// session settles as Session closed. An *answered* approval never comes
    /// through here: that run continues, so `decide` keeps its working marker.
    private func withdraw(identity: TerminalConnectionIdentity) {
        guard let id = identity.approvalID,
              let approval = queue.sessionQueues.lazy.flatMap(\.approvals).first(where: { $0.id == id }),
              connections.removeValue(forKey: id) != nil else { return }
        queue.resolve(id: id)
        AgentSessionActivityStore.shared.record(marker: .transportEnded(for: approval))
        publishQueue()
    }

    private func publishQueue() { sessionQueues = queue.sessionQueues }

    private func playApprovalPing() {
        NSSound(named: NSSound.Name("Ping"))?.play()
    }

    private enum SocketError: LocalizedError {
        case activeAgentNotch
        case failed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .activeAgentNotch: return "AgentNotch is already handling Terminal Codex approvals"
            case let .failed(call, code): return "\(call) failed (\(String(cString: strerror(code))))"
            }
        }
    }

    private static func bindListener(at path: String) throws -> Int32 {
        // This is a compatibility endpoint, so a *running* AgentNotch owns it.
        // Merely having AgentNotch installed is not ownership: the old rule
        // rejected a stale socket after every NotchFlow reinstall and terminal
        // Codex approvals silently failed open even though no process listened.
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == "app.agentnotch.AgentNotch"
        }) {
            throw SocketError.activeAgentNotch
        }
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            if probe >= 0 {
                var address = try socketAddress(path)
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                    }
                }
                Darwin.close(probe)
                if connected == 0 { throw SocketError.activeAgentNotch }
            }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }
        var address = try socketAddress(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let code = errno; Darwin.close(fd); throw SocketError.failed("bind", code) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { let code = errno; Darwin.close(fd); unlink(path); throw SocketError.failed("listen", code) }
        return fd
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError.failed("socket path", ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

private final class TerminalConnectionIdentity: @unchecked Sendable {
    var approvalID: String?
}
