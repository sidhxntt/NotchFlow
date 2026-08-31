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

    private var queue = AgentApprovalQueue()
    private var connections: [String: HookConnection] = [:]
    private var listenFD: Int32 = -1
    private var hierarchyObservation: UUID?

    private static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentNotch/notch.sock").path
    }

    var hasPendingApprovals: Bool { !sessionQueues.isEmpty }

    private init() {
        hierarchyObservation = AgentSessionActivityStore.shared.observeCodexHierarchy { [weak self] hierarchy in
            self?.queue.regroup(using: hierarchy)
            self?.publishQueue()
        }
    }

    func startIfNeeded() {
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
        // AgentNotch owns this compatibility endpoint. A stale socket is not
        // permission to take over its protocol: doing so dropped its Claude
        // gate records before AgentNotch could see them.
        if FileManager.default.fileExists(atPath: "/Applications/AgentNotch.app") {
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
