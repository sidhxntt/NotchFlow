import AppKit
import ApplicationServices

/// Finds calls that never become notification banners.
///
/// `AlertBannerWatcher` covers what macOS puts in the banner strip — which is
/// how a relayed iPhone call arrives. It is NOT how most call apps announce
/// themselves. WhatsApp draws its own window ("Pri / WhatsApp audio call", with
/// Decline and Accept), and a banner sweep will never see it however carefully
/// it walks Notification Center. That was a real gap in the first version of
/// this feature, found by ringing the machine rather than by reading code.
///
/// So this watcher looks somewhere else entirely: at the windows of the apps
/// that place calls. A window counts as a call when its buttons say so — the
/// same accept/decline vocabulary the store already uses, because a call window
/// and a call banner agree about what their buttons are called even though they
/// agree about nothing else.
///
/// Two things this buys over the banner path:
///
///   · **The buttons are real.** They are ordinary `AXButton`s in an ordinary
///     window, so `AXPress` genuinely answers and hangs up. Banner actions are
///     often not exposed at all, which is why that path has a hand-off fallback.
///   · **A live call has somewhere to live.** The window stays up for the whole
///     conversation, so the notch can hold the call the way it holds the current
///     track — see `AlertCall.State.connected`.
@MainActor
final class CallWindowWatcher {
    static let shared = CallWindowWatcher()

    /// Apps whose windows are worth walking every second. A curated list, not
    /// every running process: walking all of them is a few hundred AX
    /// round-trips per tick, and the answer is almost always "no windows".
    /// Missing an app here costs a feature; scanning everything costs the main
    /// thread, every second, forever.
    private static let callApps: Set<String> = [
        "net.whatsapp.WhatsApp",
        "com.apple.FaceTime",
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "com.tdesktop.Telegram",
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.hnc.Discord",
        "com.skype.skype",
        "com.google.Meet",
    ]

    /// Tokens start well past the banner watcher's so the store can hand a press
    /// back to whichever source owns it without either one guessing.
    private static let tokenBase = 1_000_000

    private static let maxDepth = 12
    private static let maxNodes = 400

    /// A call this watcher has already identified — handed over as an
    /// `AlertCall`, not as a banner for the store to re-classify. The store's
    /// banner rule demands both an accept- and a decline-shaped button, which is
    /// right for a banner and wrong for a window: a call already in progress has
    /// only a hang-up, and passing one through that rule turned it into a
    /// notification tally instead of a call.
    var onCall: ((AlertCall) -> Void)?
    var onStateChange: ((Int, AlertCall.State) -> Void)?
    var onVanished: ((Int) -> Void)?

    private struct TrackedCall {
        let identity: String
        let element: AXUIElement
        var state: AlertCall.State
    }

    private var live: [Int: TrackedCall] = [:]
    private var nextToken = tokenBase

    private init() {}

    // MARK: - Sweep

    /// macOS can return an empty `AXWindows` array for an application until the
    /// client has asked for it once. Prime only the known call applications at
    /// launch, off the main actor, so the first incoming call is not sacrificed
    /// to that otherwise invisible handshake.
    func primeAccessibilityConnections() {
        guard AXIsProcessTrusted() else { return }
        let processIDs = NSWorkspace.shared.runningApplications.compactMap { app -> pid_t? in
            guard Self.callApps.contains(app.bundleIdentifier ?? "") else { return nil }
            return app.processIdentifier
        }
        guard !processIDs.isEmpty else { return }
        Thread.detachNewThread {
            for processID in processIDs {
                let application = AXUIElementCreateApplication(processID)
                AXUIElementSetMessagingTimeout(application, 0.25)
                var ignored: CFTypeRef?
                AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &ignored)
            }
        }
    }

    /// Driven by the app's existing one-second capability tick, same as the
    /// banner sweep. Inert without Accessibility, and never prompts.
    func sweep() {
        guard AXIsProcessTrusted() else { return }

        var found: [String: (element: AXUIElement, call: ParsedCall)] = [:]
        for app in NSWorkspace.shared.runningApplications
        where Self.callApps.contains(app.bundleIdentifier ?? "") {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            for (index, window) in Self.children(of: root, attribute: kAXWindowsAttribute).enumerated() {
                guard let parsed = parse(window: window, app: app) else { continue }
                found["\(app.bundleIdentifier ?? "")#\(index)"] = (window, parsed)
            }
        }

        for (token, tracked) in live where found[tracked.identity] == nil {
            live[token] = nil
            onVanished?(token)
        }

        for (identity, hit) in found {
            if let (token, tracked) = live.first(where: { $0.value.identity == identity }) {
                // Known call: the only thing that can change is whether it is
                // still ringing. Answering elsewhere (on the phone, in the app's
                // own window) retires the Accept button, and that is how we learn
                // the call went live.
                if tracked.state != hit.call.state {
                    live[token]?.state = hit.call.state
                    onStateChange?(token, hit.call.state)
                }
                continue
            }
            let token = nextToken
            nextToken += 1
            live[token] = TrackedCall(identity: identity, element: hit.element, state: hit.call.state)
            // `canAct` is unconditionally true here, unlike the banner path: these
            // are ordinary `AXButton`s in an ordinary window, and `press` below
            // really does drive them. The state travels with the call, so a
            // conversation we join in progress arrives as `.connected` rather
            // than as a ring nobody is making.
            onCall?(AlertCall(callerName: hit.call.caller,
                              appName: hit.call.appName,
                              bundleID: hit.call.bundleID,
                              token: token,
                              state: hit.call.state,
                              canAct: true))
        }
    }

    private struct ParsedCall {
        let caller: String
        let appName: String
        let bundleID: String?
        let state: AlertCall.State
    }

    /// Read one window, and decide whether it is a call at all.
    ///
    /// Ringing needs an accept-shaped button: that is the whole signal, and it is
    /// what keeps an ordinary chat window (which has no such button) from ringing
    /// the notch. A window that has only a hang-up-shaped button is a call
    /// already in progress.
    private func parse(window: AXUIElement, app: NSRunningApplication) -> ParsedCall? {
        var texts: [String] = []
        var buttons: [String] = []

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        while !queue.isEmpty, seen < Self.maxNodes {
            let (element, depth) = queue.removeFirst()
            seen += 1
            switch Self.string(element, kAXRoleAttribute) {
            case kAXStaticTextRole:
                if let value = Self.string(element, kAXValueAttribute), !value.isEmpty {
                    texts.append(value)
                }
            case kAXButtonRole:
                let label = Self.string(element, kAXTitleAttribute)
                    ?? Self.string(element, kAXDescriptionAttribute)
                if let label, !label.isEmpty { buttons.append(label) }
            default:
                break
            }
            guard depth < Self.maxDepth else { continue }
            for child in Self.children(of: element, attribute: kAXChildrenAttribute) {
                queue.append((child, depth + 1))
            }
        }

        let normalized = buttons.map(AlertFeedStore.normalizedForMatching)
        let hasAccept = normalized.contains { AlertFeedStore.acceptWords.contains($0) }
        let hasHangUp = normalized.contains { AlertFeedStore.declineWords.contains($0) }

        let state: AlertCall.State
        if hasAccept {
            state = .ringing
        } else if hasHangUp, AlertFeedStore.looksLikeCallWindowText(texts) {
            // Hang-up alone is ambiguous — plenty of windows have a button we'd
            // read as "end". Require the window to also SAY it is a call, so a
            // stray "End" somewhere in a chat app can't fake a live call.
            state = .connected
        } else {
            return nil
        }

        return ParsedCall(caller: Self.caller(from: texts, appName: app.localizedName ?? ""),
                          appName: AlertFeedStore.displayText(app.localizedName ?? ""),
                          bundleID: app.bundleIdentifier,
                          state: state)
    }

    /// The caller's name out of the window's text. WhatsApp puts it first, above
    /// a "WhatsApp audio call" subtitle; skip anything that is just the app
    /// naming itself, and fall back to the app's name so the ear is never blank.
    ///
    /// Every comparison runs on the normalized form. The app's own name is the
    /// clearest case: `NSRunningApplication` reports WhatsApp as
    /// `"\u{200E}WhatsApp"`, so a raw `contains` between its window text and its
    /// own name never matched and the subtitle could be read out as the caller.
    private static func caller(from texts: [String], appName: String) -> String {
        let normalizedApp = AlertFeedStore.normalizedForMatching(appName)
        for text in texts {
            let display = AlertFeedStore.displayText(text)
            guard !display.isEmpty else { continue }
            let normalized = AlertFeedStore.normalizedForMatching(text)
            // "WhatsApp audio call", "FaceTime Video" — descriptions of the call,
            // not of who is on it.
            if !normalizedApp.isEmpty, normalized.contains(normalizedApp) { continue }
            if ["call", "calling", "incoming"].contains(where: { normalized.hasPrefix($0) }) { continue }
            return display
        }
        return AlertFeedStore.displayText(appName)
    }

    // MARK: - Pressing

    /// Press the window's own Accept / Decline. Unlike a banner's actions these
    /// are ordinary buttons, so this really does answer and hang up.
    func press(token: Int, action: AlertCallAction) -> Bool {
        guard let window = live[token]?.element else { return false }

        let vocabulary = action == .accept
            ? AlertFeedStore.acceptWords
            : AlertFeedStore.declineWords

        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var seen = 0
        while !queue.isEmpty, seen < Self.maxNodes {
            let (element, depth) = queue.removeFirst()
            seen += 1
            if Self.string(element, kAXRoleAttribute) == kAXButtonRole {
                let label = Self.string(element, kAXTitleAttribute)
                    ?? Self.string(element, kAXDescriptionAttribute) ?? ""
                if vocabulary.contains(AlertFeedStore.normalizedForMatching(label)),
                   AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    return true
                }
            }
            guard depth < Self.maxDepth else { continue }
            for child in Self.children(of: element, attribute: kAXChildrenAttribute) {
                queue.append((child, depth + 1))
            }
        }
        return false
    }

    /// Whether this watcher owns the token, so the app can route a press to the
    /// right source without either one guessing.
    func owns(token: Int) -> Bool { live[token] != nil }

    // MARK: - AX plumbing

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement, attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
