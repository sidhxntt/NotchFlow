import AppKit
import ApplicationServices

/// Reads macOS' notification banners off the Accessibility tree and hands them
/// to `AlertFeedStore` as flat values. This is the ONLY file that knows what a
/// banner looks like structurally, and it is deliberately small: everything
/// about *what to do* with a banner lives in the store, where it can be tested.
///
/// There is no public API for reading another app's notifications, so this walks
/// the window tree of `com.apple.notificationcenterui` — the process that draws
/// every banner. Two consequences worth naming:
///
///   · **Never prompts.** Same standing rule as `HotKey.swift`: if Accessibility
///     is not granted the watcher constructs, does nothing, and stays silent.
///     No feature of the app is allowed to conjure a TCC dialog on its own.
///   · **Banner-shaped, not delivery-shaped.** We see what macOS puts ON SCREEN.
///     Notifications suppressed by Do Not Disturb, or by an app set to alert
///     style "None", never appear here — by design, since the notch is
///     announcing the same interruption the banner was.
///
/// The tree's exact shape is undocumented, so this was built against a dump of
/// the live tree rather than from guesswork. What is actually there:
///
/// ```
/// AXWindow "Notification Center"          ← ONE standing window, screen-sized,
///   AXGroup                                 present whether or not anything is
///     AXGroup                               on screen
///       AXScrollArea
///         AXGroup  desc="WhatsApp, Priya, see you at 8"   ← one banner
///           AXStaticText "Priya"
///           AXStaticText "WhatsApp"
///           AXStaticText "see you at 8"
/// ```
///
/// Three consequences that drove the code below:
///
///   · A banner is **not a window** — it is a nested `AXGroup`. Diffing windows
///     finds nothing; the sweep diffs described groups instead.
///   · The **posting app is only in the group's `AXDescription`**, as its first
///     comma-separated component. It is absent from the static texts, so it
///     cannot be read off them.
///   · Described groups exist **only while banners are on screen** — zero of
///     them when nothing is showing. That is what makes the diff reliable
///     without any per-element registration.
///
/// Nothing indexes into the tree by position: extraction is a bounded
/// breadth-first walk collecting every static text and button under the group.
/// A release that reorders the subtree changes which string lands in `title`
/// versus `body`; it does not break the sweep.
@MainActor
final class AlertBannerWatcher {
    static let shared = AlertBannerWatcher()

    /// The process that draws banners. Stable across every macOS version that
    /// has a notch.
    private static let notificationCenterBundleID = "com.apple.notificationcenterui"

    /// Depth and node ceilings for one banner's sweep. A banner is a handful of
    /// nodes; these exist so a surprise (a tree that is deeper than we think, or
    /// an element that reports itself as its own child) costs microseconds
    /// instead of hanging the main thread — the same bounded-walk discipline
    /// `HotKey.swift` uses on browser trees.
    private static let maxDepth = 10
    private static let maxNodes = 400

    /// What macOS calls a banner, in its own words. Every transient banner's
    /// group carries one of these subroles; the widgets that fill the same
    /// window when the user opens Notification Center (Calendar, Weather, Screen
    /// Time, Batteries…) do not.
    ///
    /// This is a POSITIVE match, and that is the whole point. The first version
    /// of this file tried to exclude the widgets by counting groups and checking
    /// their geometry, which is guesswork that fails the moment someone has four
    /// widgets — verified against the live tree, where exactly four slipped
    /// through and the notch would have announced "Calendar: No More Events
    /// Today" as a notification. Matching what a banner IS cannot fail that way.
    ///
    /// There are TWO of them, and the second one is the one that matters here.
    /// macOS draws a notification either as a banner (fades away by itself) or
    /// as an *alert* (stays until it is dealt with), and it gives them different
    /// subroles — both names are right there in NotificationCenter's own binary,
    /// alongside the `…Stack` variants it uses when several group together. A
    /// ringing call is by definition the second kind: it has to persist and it
    /// has to carry buttons. Matching only `AXNotificationCenterBanner` therefore
    /// skipped precisely the notifications this feature exists for.
    ///
    /// The `…Stack` subroles are deliberately NOT here. A stack is a container of
    /// notifications, not one of them; leaving it unmatched means the walk
    /// descends into it and finds each real banner inside, which is what we want.
    /// Not in the SDK headers, hence the literals.
    private static let bannerSubroles: Set<String> = [
        "AXNotificationCenterBanner",
        "AXNotificationCenterAlert",
    ]

    /// Emitted for each banner that appears. Set by `AppDelegate`.
    var onBanner: ((AlertBanner) -> Void)?

    /// Emitted when a banner we reported leaves the screen.
    var onVanished: ((Int) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var watchedPID: pid_t?

    /// One banner we have reported and not yet retired. Identity is macOS'
    /// own per-notification UUID (`AXIdentifier`) where it exists, which is
    /// steadier than the element pointer: it survives the tree rebuilding a
    /// banner's group between sweeps, and it means the SAME notification is
    /// never announced twice.
    private struct TrackedBanner {
        let identity: String
        /// Retained so a call ear's button press has something to press.
        let element: AXUIElement
    }

    /// Live banners, by the token we handed the store.
    private var live: [Int: TrackedBanner] = [:]
    private var nextToken = 1

    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard AXIsProcessTrusted() else { return }
        attach()
        // Notification Center is restarted by the system from time to time (and
        // after a logout/login inside one app session). Re-attach when it comes
        // back, or the ears go quiet forever after the first restart.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == Self.notificationCenterBundleID else { return }
                MainActor.assumeIsolated { self?.attach() }
            }
            workspaceObservers.append(token)
        }
    }

    private func attach() {
        guard AXIsProcessTrusted() else { return }
        guard let pid = Self.notificationCenterPID() else {
            teardown()
            return
        }
        guard pid != watchedPID else { return }

        teardown()
        watchedPID = pid

        let app = AXUIElementCreateApplication(pid)
        appElement = app

        var created: AXObserver?
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, alertBannerObserverCallback, &created) == .success,
              let created else { return }
        observer = created

        // Both notifications, because which one fires for a banner has varied by
        // release: some draw each banner as a new window, some add a group to a
        // standing window. Either way the callback just re-sweeps.
        for notification in [kAXWindowCreatedNotification, kAXCreatedNotification,
                             kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(created, app, notification as CFString, context)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           AXObserverGetRunLoopSource(created),
                           .defaultMode)
    }

    private func teardown() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(),
                                  AXObserverGetRunLoopSource(observer),
                                  .defaultMode)
        }
        observer = nil
        appElement = nil
        watchedPID = nil
        for token in live.keys { onVanished?(token) }
        live.removeAll()
    }

    private static func notificationCenterPID() -> pid_t? {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: notificationCenterBundleID)
            .first?
            .processIdentifier
    }

    // MARK: - Sweep

    /// Diff the banner windows on screen against the ones we already reported.
    ///
    /// Driven from BOTH the observer callback (so a banner is announced the
    /// instant it appears) and the app's existing one-second capability tick
    /// (so the feature still works if the observer notifications don't fire on
    /// some future macOS, and so vanished banners are noticed at all — there is
    /// no reliable per-element destroyed notification for a banner we never
    /// registered individually). Both paths land here, and the `live` table
    /// makes the sweep idempotent.
    func sweep() {
        guard AXIsProcessTrusted() else { return }
        if watchedPID == nil || Self.notificationCenterPID() != watchedPID { attach() }
        guard let appElement else { return }

        let groups = bannerGroups(under: appElement)

        var onScreen: [String: AXUIElement] = [:]
        for group in groups { onScreen[Self.identity(of: group)] = group }

        // Retire first: a banner leaving is the only way a resolved call clears
        // its ear.
        for (token, tracked) in live where onScreen[tracked.identity] == nil {
            live[token] = nil
            onVanished?(token)
        }

        let known = Set(live.values.map(\.identity))
        for (identity, group) in onScreen where !known.contains(identity) {
            guard let banner = extract(from: group) else { continue }
            live[banner.token] = TrackedBanner(identity: identity, element: group)
            onBanner?(banner)
        }
    }

    /// Every banner currently on screen: the described groups under the standing
    /// window, filtered to the banner strip's geometry.
    private func bannerGroups(under appElement: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        var queue: [(AXUIElement, Int)] = Self
            .children(of: appElement, attribute: kAXWindowsAttribute)
            .map { ($0, 0) }
        var visited = Set<AXElementKey>()
        var seen = 0

        while !queue.isEmpty, seen < Self.maxNodes {
            let (element, depth) = queue.removeFirst()
            seen += 1
            guard visited.insert(AXElementKey(element)).inserted else { continue }

            if let subrole = Self.string(element, kAXSubroleAttribute),
               Self.bannerSubroles.contains(subrole) {
                found.append(element)
                // A banner's own children are its texts and buttons; there are no
                // nested banners, so don't descend further into one.
                continue
            }

            guard depth < Self.maxDepth else { continue }
            for child in Self.children(of: element, attribute: kAXChildrenAttribute) {
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    /// Flatten one banner group into strings. Returns nil for a group carrying no
    /// text — an empty announcement is worse than none.
    private func extract(from group: AXUIElement) -> AlertBanner? {
        // Each static text is kept WITH the name macOS gave it ("title",
        // "subtitle", "body"), because which line is which is the difference
        // between recognising "Incoming call" and reading the app's own name as
        // the start of the message. `AlertBannerText` does that reading, where it
        // can be tested.
        var texts: [AlertBannerText.Node] = []
        var buttons: [String] = []

        var queue: [(AXUIElement, Int)] = [(group, 0)]
        var visited = Set<AXElementKey>()
        var seen = 0

        while !queue.isEmpty, seen < Self.maxNodes {
            let (element, depth) = queue.removeFirst()
            seen += 1
            guard visited.insert(AXElementKey(element)).inserted else { continue }

            let role = Self.string(element, kAXRoleAttribute) ?? ""
            switch role {
            case kAXStaticTextRole:
                if let value = Self.string(element, kAXValueAttribute), !value.isEmpty {
                    texts.append(AlertBannerText.Node(
                        identifier: Self.string(element, "AXIdentifier"), value: value))
                }
            case kAXButtonRole:
                // A banner button names itself in whichever of these it has:
                // title on most, description on the icon-only ones.
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

        guard !texts.isEmpty else { return nil }

        let description = Self.string(group, kAXDescriptionAttribute) ?? ""
        let appName = Self.appName(fromDescription: description,
                                   texts: texts.map(\.value))
        let (title, body) = AlertBannerText.split(texts)

        let token = nextToken
        nextToken += 1
        return AlertBanner(appName: appName,
                           bundleID: Self.bundleID(forAppNamed: appName),
                           title: title,
                           body: body,
                           buttonTitles: buttons,
                           token: token)
    }

    // MARK: - Pressing

    /// Drive the real banner's Accept / Decline button. Returns false when the
    /// banner is gone or exposes no button matching the action, so the store can
    /// hand the user off to the source app rather than swallow the press.
    func press(token: Int, action: AlertCallAction) -> Bool {
        guard let banner = live[token]?.element else { return false }

        let vocabulary = action == .accept
            ? AlertFeedStore.acceptWords
            : AlertFeedStore.declineWords

        var queue: [(AXUIElement, Int)] = [(banner, 0)]
        var visited = Set<AXElementKey>()
        var seen = 0

        while !queue.isEmpty, seen < Self.maxNodes {
            let (element, depth) = queue.removeFirst()
            seen += 1
            guard visited.insert(AXElementKey(element)).inserted else { continue }

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

    /// Last resort when the banner cannot be driven: put the calling app in
    /// front so the user can answer where the real controls are.
    func handOff(toBundleID bundleID: String?) {
        guard let bundleID,
              let app = NSRunningApplication
                  .runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate(options: [])
    }

    // MARK: - AX plumbing

    /// Stable identity for one banner: macOS' own notification UUID
    /// (`AXIdentifier`), or the element's hash if a future release stops
    /// publishing one. The UUID is steadier than the element pointer — it
    /// survives the tree rebuilding a banner's group between sweeps, so the same
    /// notification is never announced twice.
    private static func identity(of element: AXUIElement) -> String {
        if let identifier = string(element, "AXIdentifier"), !identifier.isEmpty {
            return identifier
        }
        return "element-\(CFHash(element))"
    }

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

    /// The group's description is "App, <its texts joined by ', '>", so the app
    /// is what remains once the texts are removed — derived by subtraction
    /// rather than by taking component zero, which would hand back a fragment of
    /// the message for any app whose own name contains a comma, or on a release
    /// that reorders the description.
    private static func appName(fromDescription description: String, texts: [String]) -> String {
        let textValues = Set(texts)
        let remaining = description
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !textValues.contains($0) }
        if let first = remaining.first { return first }
        // Description carried nothing but the message: better to group under the
        // first line than to invent an app name.
        return texts.first ?? ""
    }

    /// Bundle ID for the app a banner names itself after. Anything posting a
    /// notification is running, so the running-application list is enough — and
    /// it avoids a LaunchServices lookup on the main thread. Nil is a fine
    /// answer: the store falls back to grouping by display name.
    private static func bundleID(forAppNamed name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if let cached = bundleIDCache[name] { return cached }

        var resolved = NSWorkspace.shared.runningApplications.first {
            $0.localizedName == name || $0.bundleURL?.deletingPathExtension().lastPathComponent == name
        }?.bundleIdentifier

        // An app can post a notification and not be running by the time we look
        // (a scheduled reminder, a helper that exits). Then the running list has
        // nothing and only the icon suffers, so fall back to the obvious
        // install locations before giving up. Cached either way — including the
        // misses, so an unresolvable name costs these stats once per launch.
        if resolved == nil {
            let roots = [URL(fileURLWithPath: "/Applications"),
                         URL(fileURLWithPath: "/System/Applications"),
                         URL(fileURLWithPath: "/System/Applications/Utilities"),
                         FileManager.default.homeDirectoryForCurrentUser
                             .appendingPathComponent("Applications")]
            for root in roots {
                let candidate = root.appendingPathComponent("\(name).app")
                if let bundle = Bundle(url: candidate)?.bundleIdentifier {
                    resolved = bundle
                    break
                }
            }
        }

        bundleIDCache[name] = resolved
        return resolved
    }

    /// App-name → bundle-ID memo, misses included. Names repeat constantly (one
    /// chat app can post a dozen banners a minute) and the miss path touches the
    /// filesystem.
    private static var bundleIDCache: [String: String?] = [:]
}

/// `AXUIElement` is a CFType with no `Hashable` conformance, but element
/// identity is exactly what the sweep's diff needs. `CFHash`/`CFEqual` are the
/// documented identity for AX elements.
private struct AXElementKey: Hashable {
    private let element: AXUIElement

    init(_ element: AXUIElement) { self.element = element }

    static func == (lhs: AXElementKey, rhs: AXElementKey) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(element))
    }
}

/// `AXObserverCreate` takes a C function pointer, so the callback cannot capture
/// — the watcher arrives through `refcon`. All it does is re-sweep: deciding
/// what changed is the sweep's job, which keeps this function trivial no matter
/// which notification fired.
private func alertBannerObserverCallback(_ observer: AXObserver,
                                        _ element: AXUIElement,
                                        _ notification: CFString,
                                        _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let watcher = Unmanaged<AlertBannerWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.sweep() }
}
