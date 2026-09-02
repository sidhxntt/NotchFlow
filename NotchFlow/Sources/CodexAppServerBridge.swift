import Foundation
import AppKit

/// Owns the Codex app-server connection used by NotchFlow-launched Codex turns.
/// App-server delivers approval callbacks to its owning client connection, which
/// lets this bridge make a user-selected decision directly from the notch.
@MainActor
final class CodexAppServerBridge: ObservableObject {
    static let shared = CodexAppServerBridge()

    enum Decision { case approve, deny }

    @Published private(set) var sessionQueues: [CodexApprovalSessionQueue] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var lastError: String? = nil

    private var queue = CodexApprovalQueue()
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var nextRequestID = 1
    /// JSON-RPC preserves the original id's type; retain it rather than inventing
    /// an unsafe terminal/PTY route for a decision.
    private var callbackIDs: [String: Any] = [:]
    /// Which app-server method raised each approval. The three approval methods
    /// do NOT share a response shape, so the decision cannot be written without
    /// knowing which one is being answered.
    private var approvalMethods: [String: String] = [:]
    /// For `item/permissions/requestApproval` only: the profile Codex asked for,
    /// echoed back verbatim on approve so the grant is exactly what was shown —
    /// never broader.
    private var requestedPermissions: [String: [String: Any]] = [:]
    private var responseHandlers: [Int: ([String: Any]) -> Void] = [:]
    private var textHandlers: [String: (String) -> Void] = [:]
    private var completionHandlers: [String: (Bool) -> Void] = [:]
    private var hierarchyObservation: UUID?

    var hasPendingApprovals: Bool { !sessionQueues.isEmpty }

    private init() {
        hierarchyObservation = AgentSessionActivityStore.shared.observeCodexHierarchy { [weak self] hierarchy in
            self?.queue.regroup(using: hierarchy)
            self?.publishQueue()
        }
    }

    /// Starts a durable app-server once. Reused turns retain the same approval
    /// callback transport, allowing multiple Codex threads to queue independently.
    func startIfNeeded() {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard process == nil else { return }
        guard let binary = CodexCLIService.resolveBinary() else {
            lastError = "Codex is not available"
            return
        }
        let child = ShellEnvironment.makeProcess(binary, ["app-server", "--stdio"])
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.didTerminate() }
        }
        do {
            try child.run()
            process = child
            input = stdin.fileHandleForWriting
            isAvailable = true
            lastError = nil
            sendRequest(method: "initialize", params: [
                "clientInfo": ["name": "NotchFlow", "title": "NotchFlow", "version": "1.0"],
                "capabilities": ["experimentalApi": true, "requestAttestation": false]
            ]) { _ in }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Starts a Codex thread whose approvals are deliberately reviewed by this
    /// app. External Terminal sessions are never impersonated or auto-approved.
    func startTurn(folder: URL, prompt: String, model: String? = nil,
                   effort: AgentEffort? = nil,
                   onThreadStarted: @escaping (String) -> Void = { _ in },
                   onText: @escaping (String) -> Void = { _ in },
                   onFinished: @escaping (Bool) -> Void = { _ in }) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        startIfNeeded()
        guard process != nil else { return }
        var threadParams: [String: Any] = [
            "cwd": folder.path,
            "approvalPolicy": "on-request",
            "approvalsReviewer": "user"
        ]
        if let model { threadParams["model"] = model }
        sendRequest(method: "thread/start", params: threadParams) { [weak self] result in
            guard let response = result["result"] as? [String: Any],
                  let thread = response["thread"] as? [String: Any],
                  let id = thread["id"] as? String else {
                self?.lastError = "Codex could not start a task"
                return
            }
            onThreadStarted(id)
            self?.sendTurn(threadID: id, prompt: prompt, effort: effort,
                           onText: onText, onFinished: onFinished)
        }
    }

    /// Continue a thread that was created in this running bridge. It deliberately
    /// preserves its callback transport, so a second or third task round still
    /// routes every requested permission to the Agent tab.
    func continueTurn(threadID: String, prompt: String, effort: AgentEffort? = nil,
                      onText: @escaping (String) -> Void,
                      onFinished: @escaping (Bool) -> Void) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        startIfNeeded()
        guard process != nil else { return }
        sendTurn(threadID: threadID, prompt: prompt, effort: effort,
                 onText: onText, onFinished: onFinished)
    }

    private func sendTurn(threadID: String, prompt: String, effort: AgentEffort?,
                          onText: @escaping (String) -> Void,
                          onFinished: @escaping (Bool) -> Void) {
        textHandlers[threadID] = onText
        completionHandlers[threadID] = onFinished
        var turn: [String: Any] = [
            "threadId": threadID,
            "input": [["type": "text", "text": prompt, "text_elements": []]]
        ]
        if let effort { turn["effort"] = effort.rawValue }
        sendRequest(method: "turn/start", params: turn) { _ in }
    }

    func decide(_ decision: Decision, for approval: CodexApproval) {
        guard let rawID = callbackIDs[approval.id] else { return }
        let method = approvalMethods[approval.id] ?? "item/commandExecution/requestApproval"
        // Resolve locally only after the JSON-RPC response is successfully placed
        // on the app-server's stdin. This advances only this thread's FIFO queue.
        guard write(["jsonrpc": "2.0", "id": rawID,
                     "result": result(for: decision, method: method, approvalID: approval.id)]) else {
            lastError = "Could not send Codex decision"
            return
        }
        callbackIDs.removeValue(forKey: approval.id)
        approvalMethods.removeValue(forKey: approval.id)
        requestedPermissions.removeValue(forKey: approval.id)
        AgentSessionActivityStore.shared.resolveApproval(approval)
        queue.resolve(id: approval.id)
        publishQueue()
    }

    /// The response body for one decision.
    ///
    /// The three approval methods look alike from the outside and answer
    /// differently. Command and file-change approvals take a `decision` string;
    /// a **permissions** request takes no decision at all — its schema requires a
    /// `permissions` profile, and sending `{"decision": …}` there is simply
    /// invalid, which is what this used to do.
    private func result(for decision: Decision, method: String, approvalID: String) -> [String: Any] {
        guard method == "item/permissions/requestApproval" else {
            return ["decision": decision == .approve ? "accept" : "decline"]
        }

        // Approve grants exactly the profile Codex displayed and nothing more,
        // scoped to this turn rather than the session: the button said "approve
        // this", not "approve these for the rest of the conversation".
        //
        // Deny is still a well-formed grant — the field is required — carrying no
        // filesystem and no network access. That is how this protocol spells
        // "you may not have it" for a permissions request.
        let granted: [String: Any] = decision == .approve
            ? (requestedPermissions[approvalID] ?? [:])
            : ["fileSystem": NSNull(), "network": NSNull()]
        return ["permissions": granted, "scope": "turn"]
    }

    private func sendRequest(method: String, params: [String: Any],
                             completion: @escaping ([String: Any]) -> Void) {
        let id = nextRequestID
        nextRequestID += 1
        responseHandlers[id] = completion
        guard write(["jsonrpc": "2.0", "id": id, "method": method, "params": params]) else {
            responseHandlers.removeValue(forKey: id)
            lastError = "Could not communicate with Codex"
            return
        }
    }

    private func write(_ object: [String: Any]) -> Bool {
        guard let input, let data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        var line = data
        line.append(0x0A)
        do { try input.write(contentsOf: line); return true } catch { return false }
    }

    private func ingest(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        if let id = object["id"] as? Int, let completion = responseHandlers.removeValue(forKey: id) {
            completion(object)
            return
        }

        // Normal app-server notifications do not carry a request id. They are
        // task output and completion, not approval callbacks, and must not be
        // filtered out by the callback-id path below.
        if let notification = CodexAppServerNotification.decode(object) {
            switch notification.method {
            case "item/agentMessage/delta":
                if let threadID = notification.threadID, let delta = notification.delta {
                    textHandlers[threadID]?(delta)
                }
            case "turn/completed":
                if let threadID = notification.threadID {
                    completionHandlers.removeValue(forKey: threadID)?(
                        notification.turnStatus == "completed")
                    textHandlers.removeValue(forKey: threadID)
                }
            default:
                break
            }
            return
        }

        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any],
              let rawID = object["id"] else { return }
        switch method {
        case "item/commandExecution/requestApproval":
            enqueueCommandApproval(rawID: rawID, params: params)
        case "item/fileChange/requestApproval", "item/permissions/requestApproval":
            enqueueGenericApproval(rawID: rawID, params: params, method: method)
        default:
            break
        }
    }

    private func enqueueCommandApproval(rawID: Any, params: [String: Any]) {
        guard let threadID = params["threadId"] as? String,
              let itemID = params["itemId"] as? String else { return }
        let id = rpcKey(rawID)
        let command = (params["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = params["reason"] as? String
        let title = command?.isEmpty == false ? command! : "Run command"
        callbackIDs[id] = rawID
        approvalMethods[id] = "item/commandExecution/requestApproval"
        let approval = groupedForPresentation(
            CodexApproval(id: id, threadID: threadID, itemID: itemID,
                          title: title, detail: reason))
        queue.enqueue(approval)
        AgentSessionActivityStore.shared.recordApproval(approval)
        publishQueue()
        playApprovalPing()
    }

    private func enqueueGenericApproval(rawID: Any, params: [String: Any], method: String) {
        guard let threadID = params["threadId"] as? String,
              let itemID = params["itemId"] as? String else { return }
        let id = rpcKey(rawID)
        let title = method.contains("fileChange") ? "Apply file changes" : "Grant requested permission"
        callbackIDs[id] = rawID
        approvalMethods[id] = method
        if method == "item/permissions/requestApproval" {
            requestedPermissions[id] = params["permissions"] as? [String: Any] ?? [:]
        }
        let approval = groupedForPresentation(
            CodexApproval(id: id, threadID: threadID, itemID: itemID,
                          title: title, detail: params["reason"] as? String))
        queue.enqueue(approval)
        AgentSessionActivityStore.shared.recordApproval(approval)
        publishQueue()
        playApprovalPing()
    }

    private func publishQueue() { sessionQueues = queue.sessionQueues }
    private func rpcKey(_ id: Any) -> String { String(describing: id) }

    private func groupedForPresentation(_ approval: CodexApproval) -> CodexApproval {
        approval.grouped(under: AgentSessionActivityStore.shared.rootSessionID(
            for: approval.source, sessionID: approval.threadID))
    }

    private func playApprovalPing() {
        NSSound(named: NSSound.Name("Ping"))?.play()
    }

    /// The app-server can own several concurrent turns outside
    /// `AgentTaskManager.runs`; terminating the shared process is the only
    /// atomic way to ensure none survives a blocked entitlement transition.
    func shutdownForLicenseBlock() {
        let child = process
        try? input?.close()
        child?.terminate()
        didTerminate()
    }

    private func didTerminate() {
        process = nil
        input = nil
        isAvailable = false
        outputBuffer = Data()
        callbackIDs = [:]
        approvalMethods = [:]
        requestedPermissions = [:]
        responseHandlers = [:]
        textHandlers = [:]
        completionHandlers = [:]
        queue = CodexApprovalQueue()
        publishQueue()
    }
}
