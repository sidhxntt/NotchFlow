import Foundation
import AppKit

/// Compatibility listener for Codex sessions started in Terminal.
///
/// Codex has no per-launch `--settings` equivalent the way Claude Code does
/// (see `ClaudeHookBridge`), so there is no way to reach a session the user
/// starts unassisted in their own terminal except through Codex's one shared,
/// user-owned `~/.codex/hooks.json`. `startIfNeeded` installs and self-heals
/// NotchFlow's own entries there — additively, never touching another tool's
/// hooks — so a fresh install and a corrupted file both end up wired without
/// a manual step. NotchFlow speaks the private Unix-socket protocol that
/// script talks while the app is running. Each hook process remains blocked
/// until the user chooses in the Agent tab.
///
/// Trust is the one piece this cannot do for the user: Codex requires an
/// explicit `/hooks` acceptance the first time a hook's content changes, and
/// there is no supported API to grant that on the user's behalf (see
/// https://github.com/openai/codex/issues/21615, open as of 2026-09-02).
/// Silently writing to Codex's own trust cache would mean forging a security
/// consent Codex deliberately keeps explicit, so this bridge does not attempt
/// it — only the wiring is automatic; trusting it is still the user's call,
/// once, the first time.
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
            .appendingPathComponent("Library/Application Support/NotchFlow/notch.sock").path
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

    private static var codexHookScriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/notchflow-codex-hook.py")
    }

    private static var codexHooksConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks.json")
    }

    private static var claudeLifecycleHookScriptURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/notchflow/notchflow-hook.py")
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
        Self.ensureGlobalHookInstalled()
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

    /// Writes the hook script and wires `~/.codex/hooks.json` so this
    /// machine's Codex terminal sessions reach the socket above without any
    /// separate installer. Runs on every `startIfNeeded`, so it also repairs
    /// a file an old or incompatible entry already broke.
    ///
    /// Additive and defensive by construction:
    ///  - Another tool's entries, under this event or any other, are never
    ///    touched — only a hook-group already running this exact script and
    ///    subcommand is treated as "already installed".
    ///  - Every `null` value under `hooks` is dropped, whatever key it is
    ///    under. `null` is valid JSON but not a valid hook value; Codex's own
    ///    config parser rejects the WHOLE file over one such key (`invalid
    ///    type: null`, reproduced 2026-09-02), so a single dead entry from
    ///    however it got there — a previous NotchFlow version, a hand edit —
    ///    silently zeroed out every hook, including ones nothing here owns.
    ///  - A parse failure on the existing file is treated the same as no
    ///    file: this rebuilds a valid one rather than leaving Codex unable to
    ///    load any hook at all.
    private static func ensureGlobalHookInstalled() {
        let scriptURL = codexHookScriptURL
        let configURL = codexHooksConfigURL
        do {
            try writeManagedHook(hookScriptContents, to: scriptURL)
            try writeManagedHook(claudeLifecycleHookScriptContents, to: claudeLifecycleHookScriptURL)
        } catch { return }

        var configuration: [String: Any] = [:]
        if let data = try? Data(contentsOf: configURL),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            configuration = parsed
        }

        var hooks = configuration["hooks"] as? [String: Any] ?? [:]
        hooks = hooks.filter { !($0.value is NSNull) }

        let scriptPath = scriptURL.path
        hooks["PermissionRequest"] = ensuring(
            command: "\"/usr/bin/python3\" \"\(scriptPath)\" gate", timeout: 1800, matcher: "*",
            in: hooks["PermissionRequest"])
        hooks["Stop"] = ensuring(
            command: "\"/usr/bin/python3\" \"\(scriptPath)\" clear", timeout: nil, matcher: nil,
            in: hooks["Stop"])
        hooks["UserPromptSubmit"] = ensuring(
            command: "\"/usr/bin/python3\" \"\(scriptPath)\" clear", timeout: nil, matcher: nil,
            in: hooks["UserPromptSubmit"])

        configuration["hooks"] = hooks
        guard JSONSerialization.isValidJSONObject(configuration),
              let data = try? JSONSerialization.data(withJSONObject: configuration,
                                                      options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    private static func writeManagedHook(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try? String(contentsOf: url, encoding: .utf8)
        guard existing != contents else { return }
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Appends a hook group running `command` to `existing` (one event's
    /// array of hook groups) unless a group already runs this exact command —
    /// so any other tool's group under the same event, and a NotchFlow group
    /// already present, both survive untouched.
    private static func ensuring(command: String, timeout: Int?, matcher: String?,
                                 in existing: Any?) -> [Any] {
        var groups = existing as? [Any] ?? []
        let alreadyPresent = groups.contains { group in
            guard let group = group as? [String: Any],
                  let innerHooks = group["hooks"] as? [Any] else { return false }
            return innerHooks.contains { ($0 as? [String: Any])?["command"] as? String == command }
        }
        guard !alreadyPresent else { return groups }

        var hook: [String: Any] = ["type": "command", "command": command]
        if let timeout { hook["timeout"] = timeout }
        var group: [String: Any] = ["hooks": [hook]]
        if let matcher { group["matcher"] = matcher }
        groups.append(group)
        return groups
    }

    /// The hook process itself — unchanged from the version this app's
    /// predecessor installed by hand. Fails OPEN on purpose:
    /// if NotchFlow is not listening, or nobody answers in time, this prints
    /// nothing and Codex falls back to its own approval prompt.
    private static let hookScriptContents = """
    #!/usr/bin/env python3
    # NotchFlow Codex bridge — DO NOT EDIT (managed by NotchFlow).
    # notchflow-codex-hook v1  (forward justification/escalation + apply_patch files
    # so the notch can say what's being approved and why)
    import sys, os, json, socket

    def sock_path():
        p = os.environ.get("NOTCHFLOW_SOCKET")
        if p:
            return p
        return os.path.expanduser("~/Library/Application Support/NotchFlow/notch.sock")

    def send(msg, wait, timeout):
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(3.0)
            s.connect(sock_path())
        except Exception:
            return None
        try:
            s.sendall((json.dumps(msg) + "\\n").encode("utf-8"))
            if not wait:
                return None
            s.settimeout(timeout)
            buf = b""
            while b"\\n" not in buf:
                chunk = s.recv(4096)
                if not chunk:
                    return None
                buf += chunk
            return json.loads(buf.split(b"\\n", 1)[0].decode("utf-8"))
        except Exception:
            return None
        finally:
            try: s.close()
            except Exception: pass

    def main():
        action = sys.argv[1] if len(sys.argv) > 1 else "clear"
        try:
            d = json.load(sys.stdin)
        except Exception:
            d = {}
        # Codex has emitted both session_id and thread_id across terminal and
        # app-server-adjacent hook payloads. Treat them as the same queue key.
        sid = d.get("session_id") or d.get("thread_id") or d.get("threadId") or ""
        if not sid:
            return
        tool = d.get("tool_name") or ""
        ti = d.get("tool_input") or {}
        if not isinstance(ti, dict):
            ti = {}
        cmd = ti.get("command")
        if isinstance(cmd, list):  # Codex sends argv arrays, e.g. ["bash","-lc","…"]
            parts = [str(x) for x in cmd]
            if len(parts) >= 3 and parts[1] in ("-lc", "-c"):
                cmd = parts[-1]    # the shell wrapper adds nothing — show the script
            else:
                cmd = " ".join(parts)
        # apply_patch approvals carry the change, not a command — surface the
        # files touched so the row isn't blank.
        patch = ti.get("changes") or ti.get("files") or ti.get("patch")
        if not cmd and patch:
            if isinstance(patch, dict):
                cmd = "patch: " + ", ".join(os.path.basename(str(p)) for p in list(patch.keys())[:4])
            elif isinstance(patch, list):
                cmd = "patch: " + ", ".join(os.path.basename(str(p)) for p in patch[:4])
        detail = cmd or ti.get("file_path") or ti.get("path") or ti.get("description") or ""
        # Why Codex is asking: its own user-facing justification for escalating,
        # and whether it wants to run outside the sandbox.
        reason = ti.get("justification") or ""
        escalated = ti.get("sandbox_permissions") == "require_escalated"
        base = {"v": 1, "source": "codex", "session_id": sid,
                "cwd": d.get("cwd", ""), "tool_name": tool, "detail": detail,
                "reason": reason, "escalated": escalated}

        if action == "clear":
            send({**base, "action": "clear"}, False, 0)
            return
        if action != "gate":
            return

        resp = send({**base, "action": "gate"}, True, 1795)
        if not resp:
            return  # fail open / timeout → Codex's own prompt
        behavior = resp.get("behavior", "")
        # Codex's PermissionRequest decision: an allow needs no updatedInput (unlike
        # Claude Code); a deny carries a message. Passthrough/unknown → no output.
        if behavior == "allow":
            dec = {"behavior": "allow"}
        elif behavior == "deny":
            dec = {"behavior": "deny", "message": "Denied from NotchFlow"}
        else:
            return
        print(json.dumps({"continue": True, "hookSpecificOutput": {
            "hookEventName": "PermissionRequest", "decision": dec}}))

    try:
        main()
    except Exception:
        pass
    """

    /// The lifecycle bridge for Claude Code sessions started in a terminal. It
    /// emits the same lightweight marker protocol that the socket listener
    /// already accepts, while leaving actual permission decisions to the
    /// NotchFlow approval hook configured for gated tools.
    private static let claudeLifecycleHookScriptContents = """
    #!/usr/bin/env python3
    # NotchFlow Claude lifecycle bridge — DO NOT EDIT (managed by NotchFlow).
    import json, os, socket, sys

    def sock_path():
        return os.environ.get("NOTCHFLOW_SOCKET") or os.path.expanduser(
            "~/Library/Application Support/NotchFlow/notch.sock")

    def send(message):
        client = None
        try:
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(3.0)
            client.connect(sock_path())
            client.sendall((json.dumps(message) + "\\n").encode("utf-8"))
        except Exception:
            pass
        finally:
            try:
                if client: client.close()
            except Exception: pass

    def main():
        action = sys.argv[1] if len(sys.argv) > 1 else "clear"
        try: payload = json.load(sys.stdin)
        except Exception: payload = {}
        session_id = payload.get("session_id") or ""
        if not session_id: return
        tool = payload.get("tool_name") or ""
        tool_input = payload.get("tool_input") or {}
        if not isinstance(tool_input, dict): tool_input = {}
        detail = (tool_input.get("command") or tool_input.get("file_path")
                  or tool_input.get("path") or tool_input.get("description") or "")
        message = {"v": 1, "source": "claude", "session_id": session_id,
                   "cwd": payload.get("cwd", ""), "tool_name": tool,
                   "detail": detail, "reason": ""}
        if action in ("clear", "start", "busy", "busydone", "done"):
            send({**message, "action": action})
        elif action == "idle":
            send({**message, "action": "marker", "kind": "idle"})
        elif action == "ask":
            kind = "plan" if tool == "ExitPlanMode" else "question"
            marker = {**message, "action": "marker", "kind": kind}
            if kind == "question":
                questions = tool_input.get("questions")
                first = questions[0] if isinstance(questions, list) and questions and isinstance(questions[0], dict) else {}
                if isinstance(first.get("question"), str) and first["question"].strip():
                    marker["detail"] = first["question"].strip()[:500]
                options = first.get("options")
                if isinstance(options, list):
                    marker["options"] = [option["label"].strip()[:120] for option in options
                                         if isinstance(option, dict) and isinstance(option.get("label"), str)
                                         and option["label"].strip()][:8]
                if isinstance(questions, list) and len(questions) > 1:
                    marker["more_questions"] = len(questions) - 1
            send(marker)

    main()
    """

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
        case activeNotchFlow
        case failed(String, Int32)

        var errorDescription: String? {
            switch self {
            case .activeNotchFlow: return "NotchFlow is already handling Terminal Codex approvals"
            case let .failed(call, code): return "\(call) failed (\(String(cString: strerror(code))))"
            }
        }
    }

    private static func bindListener(at path: String) throws -> Int32 {
        // A listening socket belongs to a running NotchFlow instance. A stale
        // socket is removed below so a relaunch can restore terminal approvals.
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
                if connected == 0 { throw SocketError.activeNotchFlow }
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
