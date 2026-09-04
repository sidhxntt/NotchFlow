import Foundation
import AppKit

/// Routes Claude Code's tool-permission prompts into the notch, the way
/// `CodexAppServerBridge` does for Codex — same card, same per-session FIFO
/// queue, same red-rimmed island.
///
/// ## Why this looks nothing like the Codex bridge inside
///
/// Codex hands the app one long-lived JSON-RPC connection and delivers approval
/// callbacks on it, so the bridge just answers a request id. Claude Code has no
/// such channel. Its permission extension point is a **`PreToolUse` hook**: for
/// every matched tool call the CLI spawns a short-lived command, writes the
/// request as JSON on that command's stdin, and takes the command's stdout as
/// the decision. (`--permission-prompt-tool` exists but is undocumented and its
/// contract could not be confirmed; the hook contract was verified in both
/// directions against Claude Code 2.1.226.)
///
/// So the piece that has to block until the user clicks is a *different
/// process*, and something has to carry the question into this app and the
/// answer back out. That is this class:
///
/// 1. It generates, under Application Support, a tiny dependency-free Python
///    hook script and an **app-owned** settings JSON that points at it. The
///    user's own `~/.claude/settings.json` is never read or written — the
///    generated file is passed explicitly with `--settings`, so the hook is
///    active only for NotchFlow-launched runs, exactly like the Codex bridge
///    only covers NotchFlow-launched Codex turns.
/// 2. It listens on a Unix domain socket beside those files. The hook process
///    connects, writes its stdin JSON as one line, and blocks on a read.
/// 3. The request becomes an `AgentApproval` in the shared queue. When the user
///    picks Approve or Deny, the decision line is written back on that same
///    connection; the hook prints it and exits.
///
/// A Unix socket (rather than a file/directory drop box, a pipe or a local TCP
/// port) because it is the only option here that is simultaneously
/// filesystem-permissioned to this user, connection-oriented — so "the run was
/// cancelled" arrives as an EOF and the stale card withdraws itself — and
/// exposes nothing on the network.
///
/// ## Fail OPEN, deliberately
///
/// If NotchFlow is not running, the socket is missing, or the user never answers
/// within the bounded wait, the hook prints **nothing** and exits 0. Claude Code
/// then falls back to its own normal permission behaviour for that call.
///
/// That choice is not "less safe than denying" — it is *exactly the behaviour
/// the run would have had if this feature did not exist*, which is the only
/// honest default for a decoration on top of the CLI's own permission system.
/// Failing closed would let a quit app silently sabotage a long agent run the
/// user started deliberately, and hanging forever would wedge the CLI with no
/// way out and no UI to explain it. Verified: with no socket present, the run
/// proceeds under its own `--permission-mode`.
@MainActor
final class ClaudeHookBridge: ObservableObject {
    static let shared = ClaudeHookBridge()

    enum Decision { case approve, deny }

    @Published private(set) var sessionQueues: [AgentApprovalSessionQueue] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var lastError: String? = nil

    private var queue = AgentApprovalQueue()
    /// The open hook connection waiting on each approval's decision.
    private var connections: [String: HookConnection] = [:]
    private var listenFD: Int32 = -1
    private var listenerThread: Thread?

    /// How long the hook process waits for a decision before giving up and
    /// failing open. Long enough that a user who wandered off for a coffee still
    /// finds a live card; short enough that a forgotten prompt cannot pin a hook
    /// process (and the agent run behind it) forever.
    static let decisionTimeout: TimeInterval = 300

    /// The tools gated by the hook. Deliberately only the ones that execute,
    /// mutate, or leave the machine (network): a card for every in-project
    /// `Read`/`Glob`/`Grep` would be unusable, and unusable prompts are how
    /// people learn to click Approve without reading. `WebFetch`/`WebSearch`
    /// reach the network on the user's behalf, which is exactly the class of
    /// action this bridge exists to surface — leaving them ungated meant a
    /// NotchFlow-launched Claude run could fetch/search without ever asking.
    /// `Read` is gated too, but only actually surfaces a card for a path
    /// outside the session's working directory (see `enqueue`) — the same
    /// case Claude's own permission system singles out (a pasted image lands
    /// in a temp directory, not the project), so that prompt now reaches the
    /// notch instead of the terminal, while an ordinary in-project read stays
    /// silent. Verified that `matcher` takes a regex in 2.1.226, so one entry
    /// covers all seven.
    static let gatedTools = ["Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch", "Read"]

    var hasPendingApprovals: Bool { !sessionQueues.isEmpty }

    private init() {}

    // MARK: - Paths

    private static var hookDirectory: URL? {
        AppSupportPaths.appDirectory?.appendingPathComponent("ClaudeHook", isDirectory: true)
    }

    /// The socket lives directly under the app directory (not the hook
    /// subdirectory) purely to keep the path short: `sockaddr_un.sun_path` is
    /// 104 bytes on macOS, and a long home directory eats into that.
    private static var socketURL: URL? {
        AppSupportPaths.appDirectory?.appendingPathComponent("claude-approvals.sock")
    }

    private static var scriptURL: URL? {
        hookDirectory?.appendingPathComponent("notchflow-approval-hook.py")
    }

    private static var settingsURL: URL? {
        hookDirectory?.appendingPathComponent("settings.json")
    }

    // MARK: - Lifecycle

    /// Generates the hook artifacts and starts listening. Idempotent — safe to
    /// call from app launch and again from every spawn.
    func startIfNeeded() {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard listenFD < 0 else { return }
        guard let socketURL = Self.socketURL, let scriptURL = Self.scriptURL,
              let settingsURL = Self.settingsURL, let hookDirectory = Self.hookDirectory else {
            lastError = "Application Support is unavailable"
            return
        }
        do {
            try FileManager.default.createDirectory(at: hookDirectory,
                                                    withIntermediateDirectories: true)
            try Self.writeScript(to: scriptURL, socketPath: socketURL.path)
            try Self.writeSettings(to: settingsURL, scriptPath: scriptURL.path)
            listenFD = try Self.bindListener(at: socketURL.path)
        } catch {
            lastError = error.localizedDescription
            return
        }

        let fd = listenFD
        // A thread per connection rather than a dispatch source: each one spends
        // its life parked in a blocking `read`, which is exactly what a GCD queue
        // must never be used for. There is one per *pending approval card*, so
        // the count is bounded by what a human can be looking at.
        let thread = Thread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR { continue }
                    break   // listener closed
                }
                let connection = HookConnection(fd: client)
                let worker = Thread { Self.serve(connection, bridge: self) }
                worker.name = "com.notchflow.claude-approval"
                worker.stackSize = 256 * 1024
                worker.start()
            }
        }
        thread.name = "com.notchflow.claude-approvals"
        thread.start()
        listenerThread = thread
        isAvailable = true
        lastError = nil
    }

    func shutdownForLicenseBlock() {
        if listenFD >= 0 {
            shutdown(listenFD, SHUT_RDWR)
            Darwin.close(listenFD)
            listenFD = -1
        }
        if let socketURL = Self.socketURL { unlink(socketURL.path) }
        connections.values.forEach { $0.close() }
        connections.removeAll()
        queue = AgentApprovalQueue()
        publishQueue()
        listenerThread = nil
        isAvailable = false
    }

    /// The flags a NotchFlow-launched `claude` invocation needs for its tool
    /// calls to reach the notch. Empty when the listener could not start — the
    /// run then behaves exactly as it did before this existed (see "fail open").
    func launchArguments() -> [String] {
        startIfNeeded()
        guard isAvailable, let settings = Self.settingsURL,
              FileManager.default.fileExists(atPath: settings.path) else { return [] }
        return ["--settings", settings.path]
    }

    // MARK: - Decisions

    /// Answer the head of one session's queue. Resolving here advances only that
    /// session; every other Claude session's queue is untouched.
    func decide(_ decision: Decision, for approval: AgentApproval) {
        guard let connection = connections.removeValue(forKey: approval.id) else {
            // No live hook to answer (it timed out and failed open, or the run
            // was killed). Drop the card rather than leave a button that lies.
            queue.resolve(id: approval.id)
            publishQueue()
            return
        }
        let line = ClaudeHookResponse.line(for: decision == .approve ? .allow : .deny)
        if !connection.send(line: line) {
            lastError = "Could not send the Claude decision"
        }
        AgentSessionActivityStore.shared.resolveApproval(approval)
        queue.resolve(id: approval.id)
        publishQueue()
    }

    // MARK: - Connection handling

    /// Runs on the connection's own thread: read the request, hand it to the
    /// queue, then stay parked on the socket so a cancelled run (which closes it)
    /// withdraws its card instead of leaving a dead prompt on screen.
    private nonisolated static func serve(_ connection: HookConnection,
                                          bridge: ClaudeHookBridge) {
        defer { connection.close() }
        guard let line = connection.readLine() else { return }
        if let marker = AgentSessionMarker.decode(line) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { AgentSessionActivityStore.shared.record(marker: marker) }
            }
            return
        }
        guard let request = ClaudeHookRequest.decode(line) else { return }
        let identity = ConnectionIdentity()
        // `DispatchQueue.main.async`, not `Task { @MainActor }`: these two hops
        // MUST arrive in this order, and only the queue guarantees that. A
        // withdraw that overtook its own enqueue would strand the card.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                bridge.enqueue(request, connection: connection, identity: identity)
            }
        }
        // Blocks until the hook process exits — which it does right after it
        // reads the decision, and also if the whole run is cancelled.
        connection.waitForPeerClose()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { bridge.withdraw(identity: identity) }
        }
    }

    private func enqueue(_ request: ClaudeHookRequest, connection: HookConnection,
                         identity: ConnectionIdentity) {
        // A `Read` inside the session's own working directory is the ordinary
        // case (source files, the project's own assets) — carding it would be
        // the alert-fatigue noise `gatedTools`' doc comment warns about. Only a
        // `Read` reaching outside the project (a pasted image lands in a temp
        // directory, never the project) is worth a card; answer everything
        // else immediately, same as if the hook were not watching `Read` at all.
        if request.toolName == "Read", Self.isWithinWorkingDirectory(request) {
            _ = connection.send(line: ClaudeHookResponse.line(for: .allow))
            return
        }
        // `tool_use_id` is unique per tool call, so this is normally just it. The
        // fallback covers the pathological repeat: the queue dedupes on id, and a
        // silently dropped request would park its hook until the timeout.
        let id = queue.contains(id: request.toolUseID)
            ? "\(request.toolUseID)#\(UUID().uuidString.prefix(8))"
            : request.toolUseID
        let approval = request.approval(idOverride: id)
        identity.approvalID = id
        connections[id] = connection
        queue.enqueue(approval)
        AgentSessionActivityStore.shared.recordApproval(approval)
        publishQueue()
        playApprovalPing()
    }

    /// The hook process went away without a decision (timed out and failed open,
    /// or the run was cancelled). Its card is no longer answerable, so it goes —
    /// and the session it belonged to settles as Session closed rather than
    /// keeping the "needs you" marker this approval put there.
    ///
    /// Only this path records that. An answered approval is the opposite of a
    /// transport ending: the run carries straight on, so `decide` leaves the
    /// working marker `resolveApproval` restores.
    private func withdraw(identity: ConnectionIdentity) {
        guard let id = identity.approvalID,
              let approval = pendingApproval(id: id),
              connections.removeValue(forKey: id) != nil else {
            return   // already decided — the normal path
        }
        queue.resolve(id: id)
        AgentSessionActivityStore.shared.record(marker: .transportEnded(for: approval))
        publishQueue()
    }

    /// Whether a `Read`'s target sits inside the session's own working
    /// directory. Missing data (no path, no cwd) is treated as "outside" —
    /// there is nothing to silently clear, so it takes the card path instead
    /// of guessing.
    private static func isWithinWorkingDirectory(_ request: ClaudeHookRequest) -> Bool {
        guard let filePath = request.filePath, let cwd = request.cwd else { return false }
        let path = (filePath as NSString).standardizingPath
        let directory = (cwd as NSString).standardizingPath
        return path == directory || path.hasPrefix(directory + "/")
    }

    private func pendingApproval(id: String) -> AgentApproval? {
        queue.sessionQueues.lazy.flatMap(\.approvals).first { $0.id == id }
    }

    private func publishQueue() { sessionQueues = queue.sessionQueues }

    private func playApprovalPing() {
        NSSound(named: NSSound.Name("Ping"))?.play()
    }

    // MARK: - Generated artifacts

    /// The hook command itself.
    ///
    /// Python 3 rather than `nc -U`: `/usr/bin/python3` ships with macOS, and
    /// netcat's behaviour with bidirectional stdio varies by build (it likes to
    /// exit on stdin EOF, which is precisely when this needs to keep reading).
    /// Every failure path here returns without printing — see "fail open".
    private static func writeScript(to url: URL, socketPath: String) throws {
        let script = """
        #!/usr/bin/env python3
        # Generated by NotchFlow. Do not edit — it is rewritten on every launch.
        #
        # Claude Code approval and goal-lifecycle hook. PreToolUse asks the
        # running NotchFlow app for a decision; lifecycle invocations only send
        # a marker and exit successfully.
        #
        # Fails OPEN on purpose: if NotchFlow is not listening, or nobody answers
        # within the timeout, this prints nothing and exits 0, which leaves Claude
        # Code's own permission behaviour in charge. Denying or hanging instead
        # would let a quit app silently break a run the user deliberately started.
        import json
        import socket
        import sys

        SOCKET_PATH = \(pythonLiteral(socketPath))
        TIMEOUT_SECONDS = \(Int(decisionTimeout))

        def send_marker(payload, kind):
            marker = {"source": "claude", "session_id": payload.get("session_id", ""),
                      "cwd": payload.get("cwd", ""), "detail": payload.get("task_subject")
                          or payload.get("task_description") or "", "action": "marker", "kind": kind}
            if not marker["session_id"]:
                return
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(3)
            try:
                client.connect(SOCKET_PATH)
                client.sendall((json.dumps(marker, separators=(",", ":")) + "\\n").encode("utf-8"))
            except Exception:
                pass
            finally:
                try:
                    client.close()
                except Exception:
                    pass

        def main():
            raw = sys.stdin.read()
            try:
                payload = json.loads(raw)
            except Exception:
                return
            action = sys.argv[1] if len(sys.argv) > 1 else "approval"
            if action in ("goal_set", "goal_completed"):
                send_marker(payload, action)
                return
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(TIMEOUT_SECONDS)
            try:
                client.connect(SOCKET_PATH)
                # One compact line in: the app reads up to the newline, and JSON
                # escaping guarantees the payload contains no raw newline itself.
                client.sendall((json.dumps(payload, separators=(",", ":")) + "\\n").encode("utf-8"))
                buffer = b""
                while b"\\n" not in buffer:
                    chunk = client.recv(4096)
                    if not chunk:
                        return          # app went away mid-decision: fail open
                    buffer += chunk
                decision = buffer.split(b"\\n", 1)[0].decode("utf-8").strip()
            except Exception:
                return                  # no socket, refused, or timed out: fail open
            finally:
                try:
                    client.close()
                except Exception:
                    pass
            if decision:
                sys.stdout.write(decision + "\\n")

        main()

        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// The app-owned settings file. Passed with `--settings`, which Claude Code
    /// merges *on top of* the user's own configuration rather than replacing it —
    /// so this adds the hook without touching `~/.claude/settings.json`.
    ///
    /// `timeout` is explicit and generous: the hook is waiting on a human, and
    /// the default hook timeout is far shorter than that. It is set a little
    /// above the script's own wait so the script always gets to fail open itself
    /// rather than being killed mid-read.
    private static func writeSettings(to url: URL, scriptPath: String) throws {
        let command = "/usr/bin/python3 \(shellSingleQuoted(scriptPath))"
        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": gatedTools.joined(separator: "|"),
                    "hooks": [[
                        "type": "command",
                        "command": command,
                        "timeout": Int(decisionTimeout) + 10
                    ]]
                ]],
                "TaskCreated": [["hooks": [[
                    "type": "command", "command": command + " goal_set"
                ]]]],
                "TaskCompleted": [["hooks": [[
                    "type": "command", "command": command + " goal_completed"
                ]]]]
            ]
        ]
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// A Python string literal. JSON string syntax is a subset of Python's, so
    /// the encoder does the escaping — but `.withoutEscapingSlashes` is
    /// load-bearing, not cosmetic: JSON's optional `\/` is NOT a Python escape,
    /// and Python leaves an unrecognized escape in the string verbatim, so a
    /// path would come out as `\/Users\/…` and never connect.
    private static func pythonLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value],
                                                     options: [.withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(text.dropFirst().dropLast())   // strip the array brackets
    }

    /// The hook `command` is run through a shell, and the path contains
    /// "Application Support".
    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Socket

    enum SocketError: LocalizedError {
        case pathTooLong(Int)
        case failed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .pathTooLong(let limit):
                return "The approval socket path is longer than \(limit) bytes"
            case .failed(let call, let code):
                return "\(call) failed (\(String(cString: strerror(code))))"
            }
        }
    }

    private static func bindListener(at path: String) throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(capacity - 1) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.failed("socket", errno) }

        // A socket file survives a crash and would make bind fail with EADDRINUSE
        // forever. Nothing else owns this name, so removing it is safe.
        unlink(path)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw SocketError.failed("bind", code)
        }
        // Only this user may put an approval card on this user's screen.
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw SocketError.failed("listen", code)
        }
        return fd
    }
}

/// A stable handle on one connection's place in the queue, so the connection's
/// thread can withdraw the right card on EOF without reaching into main-actor
/// state. Written once on the main actor, read once on the main actor.
private final class ConnectionIdentity: @unchecked Sendable {
    var approvalID: String?
}

/// One accepted hook connection.
///
/// The fd is closed by exactly one owner — the connection's own thread, after it
/// observes EOF. `send` therefore never closes: it writes the decision and shuts
/// down the write side, which is what gives the reader its EOF. Any other split
/// risks the main actor closing an fd number the kernel has already handed to a
/// different socket.
final class HookConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let fd: Int32
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    /// Read one newline-terminated line. Blocking; nil on EOF or error.
    func readLine(limit: Int = 1 << 20) -> Data? {
        var buffer = Data()
        var byte = [UInt8](repeating: 0, count: 4096)
        while buffer.count < limit {
            let n = read(fd, &byte, byte.count)
            if n < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if n == 0 { return nil }
            buffer.append(contentsOf: byte[0..<n])
            if let newline = buffer.firstIndex(of: 0x0A) {
                return buffer.prefix(upTo: newline)
            }
        }
        return nil
    }

    /// Blocks until the peer closes the connection.
    func waitForPeerClose() {
        var scratch = [UInt8](repeating: 0, count: 256)
        while true {
            let n = read(fd, &scratch, scratch.count)
            if n == 0 { return }
            if n < 0 && errno != EINTR { return }
        }
    }

    /// Write the decision line and signal end-of-stream, so the hook's read
    /// returns immediately instead of waiting out its timeout.
    func send(line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        let payload = Array((line + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let n = payload.withUnsafeBytes { raw -> Int in
                write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                shutdown(fd, SHUT_RDWR)
                return false
            }
            offset += n
        }
        shutdown(fd, SHUT_WR)
        return true
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        Darwin.close(fd)
    }
}
