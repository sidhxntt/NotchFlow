import Combine
import Foundation

/// One banner macOS' Notification Center just put on screen, flattened to plain
/// values. `AlertBannerWatcher` (app side) produces these from the Accessibility
/// tree; nothing in this file knows that Accessibility exists, which is what
/// makes the policy below testable.
///
/// `token` is an opaque handle back to the live AX element, owned by the watcher.
/// The store never dereferences it — it hands it back when the user presses an
/// ear button.
public struct AlertBanner: Equatable, Sendable {
    public let appName: String
    public let bundleID: String?
    public let title: String
    public let body: String
    public let buttonTitles: [String]
    public let token: Int

    public init(appName: String, bundleID: String?, title: String, body: String,
                buttonTitles: [String], token: Int) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.body = body
        self.buttonTitles = buttonTitles
        self.token = token
    }

    /// The key the per-app tally is grouped under. Bundle ID when we could
    /// resolve one, otherwise the app's display name — never empty, so two
    /// unresolvable apps still keep separate counts.
    public var groupKey: String {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return appName.isEmpty ? "unknown" : appName
    }
}

/// A burst of notifications from ONE app: its identity for the left ear, its
/// running count for the right.
public struct AlertNotificationBurst: Equatable, Sendable {
    public let groupKey: String
    public let bundleID: String?
    public let appName: String
    public let count: Int
}

/// A call the notch is announcing. `canAct` is false when the banner never
/// exposed pressable Accept/Decline buttons — the ears then announce without
/// pretending they can answer.
public struct AlertCall: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Ringing: both buttons live.
        case ringing
        /// The user answered from the notch; only "hang up" remains.
        case connected
        /// We could not drive the banner, so we sent the user to the source app.
        case handedOff
    }

    public let callerName: String
    public let appName: String
    public let bundleID: String?
    public let token: Int
    public var state: State
    public var canAct: Bool
    /// When the call went live. Drives the ear's duration clock, and is nil
    /// while it is still ringing.
    public var connectedAt: Date?

    public init(callerName: String, appName: String, bundleID: String?, token: Int,
                state: State, canAct: Bool, connectedAt: Date? = nil) {
        self.callerName = callerName
        self.appName = appName
        self.bundleID = bundleID
        self.token = token
        self.state = state
        self.canAct = canAct
        self.connectedAt = connectedAt
    }
}

/// Which button an ear press maps to on the real banner.
public enum AlertCallAction: Equatable, Sendable {
    case accept
    case decline
}

/// The single thing the resting notch reads. Calls outrank notification bursts
/// (order.md: 1 vs 2) and both are resolved here, not in the view.
public enum AlertAnnouncement: Equatable, Sendable {
    case call(AlertCall)
    case notifications(AlertNotificationBurst)
}

/// Policy over the banner feed: classify, tally, queue, expire.
///
/// Everything time-dependent takes an explicit `now`, and the store never reads
/// the clock itself — `tick(now:)` is driven by the app's existing one-second
/// capability loop. That keeps the whole of this file exercisable from tests
/// without waiting on real seconds.
@MainActor
public final class AlertFeedStore: ObservableObject {
    public static let shared = AlertFeedStore()

    /// How long one app's burst holds the shoulders before the queue advances.
    /// Matches the AirPods announcement's three seconds — same idiom, same dwell.
    public static let burstWindow: TimeInterval = 3

    /// A per-app tally this stale is no longer "5 new messages", it's history.
    public static let tallyLifetime: TimeInterval = 120

    /// A ringing call nobody confirmed by now is gone (the caller hung up, or it
    /// was answered on the phone). Without this the ear could stick forever,
    /// since a vanished banner is only noticed on the watcher's next sweep.
    ///
    /// Applies to `.ringing` ONLY. A connected call is a standing state — the
    /// notch holds it the way it holds the current track, for as long as the call
    /// lasts — so it is retired by its source going away, never by a timer.
    public static let ringingLifetime: TimeInterval = 45

    @Published public private(set) var announcement: AlertAnnouncement?

    /// Per-app running counts, plus when each was last touched (for the idle
    /// reset). Keyed by `AlertBanner.groupKey`.
    private var counts: [String: Int] = [:]
    private var lastSeen: [String: Date] = [:]

    /// Apps waiting for their own three-second slot, oldest first. The app in
    /// the slot right now is NOT in here.
    private var queue: [String] = []
    private var currentGroup: String?
    private var slotExpiresAt: Date?

    /// Identity of the app whose burst is showing, so the ear can name it and
    /// resolve its icon.
    private var identities: [String: (bundleID: String?, appName: String)] = [:]

    private var call: AlertCall?
    private var callStartedAt: Date?

    /// Our own banners (answer ready, agent finished) must never feed our own
    /// ear — that is a feedback loop, not a notification.
    private let ownBundleID: String?

    /// Set by the app so a press on the call ear can reach the real banner.
    /// Returns false when the press could not be delivered.
    public var pressHandler: ((Int, AlertCallAction) -> Bool)?

    /// Called when we could not drive the banner and the user should be taken to
    /// the source app instead.
    public var handOffHandler: ((String?) -> Void)?

    public init(ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.ownBundleID = ownBundleID
    }

    // MARK: - Ingest

    public func ingest(_ banner: AlertBanner, now: Date) {
        if let ownBundleID, banner.bundleID == ownBundleID { return }

        identities[banner.groupKey] = (banner.bundleID, banner.appName)

        if let classified = Self.classifyCall(banner) {
            // A call takes the strip outright: drop whatever burst was showing
            // so the ears don't flicker between a count and a ringing name.
            call = classified
            callStartedAt = now
            clearSlot()
            publish(now: now)
            return
        }

        counts[banner.groupKey, default: 0] += 1
        lastSeen[banner.groupKey] = now

        if currentGroup == banner.groupKey {
            // Same app again while it holds the slot: refresh the dwell so the
            // count the user ends up reading is the settled one.
            slotExpiresAt = now.addingTimeInterval(Self.burstWindow)
        } else if currentGroup == nil {
            currentGroup = banner.groupKey
            slotExpiresAt = now.addingTimeInterval(Self.burstWindow)
        } else if !queue.contains(banner.groupKey) {
            queue.append(banner.groupKey)
        }
        publish(now: now)
    }

    /// A source handing over a call it has ALREADY identified, rather than a
    /// banner we still have to classify.
    ///
    /// `CallWindowWatcher` is that source. It reads a real call window, where
    /// the evidence is much stronger than a banner's: a lone accept-shaped
    /// button in an app that places calls is a ringing call, and a lone hang-up
    /// beside text that says "call" is one already in progress. Re-deriving that
    /// through `classifyCall` threw the answer away, because the banner rule
    /// deliberately demands BOTH buttons — so a call the watcher had correctly
    /// recognised came out the other side filed as one more unread notification,
    /// which is how a live call ended up showing as a bell and a "1".
    ///
    /// The banner rule stays exactly as strict as it was; this is simply the door
    /// for a source that does not need it.
    public func ingest(call incoming: AlertCall, now: Date) {
        if let ownBundleID, incoming.bundleID == ownBundleID { return }

        if let current = call, current.token == incoming.token {
            // The same call again. Only its state can have moved, and
            // `updateCallState` is what knows how to stamp the duration clock
            // without restarting it.
            updateCallState(token: incoming.token, to: incoming.state, now: now)
            return
        }

        var adopted = incoming
        if adopted.state == .connected, adopted.connectedAt == nil {
            // We are meeting this call mid-conversation (the user answered in the
            // app, or we launched into a call already running). We cannot know
            // when it truly connected, so the clock starts now and reads low
            // rather than inventing a past — same rule as `updateCallState`.
            adopted.connectedAt = now
        }
        call = adopted
        callStartedAt = now
        // A call takes the strip outright, so drop whatever burst was showing.
        clearSlot()
        publish(now: now)
    }

    /// The watcher noticed a banner leave the screen. For a call that means it
    /// was resolved elsewhere (answered on the phone, caller gave up).
    public func bannerVanished(token: Int, now: Date) {
        guard let call, call.token == token else { return }
        // A call we answered from the notch keeps its banner for the duration of
        // the conversation on some apps and loses it on others; either way, once
        // it is gone there is nothing left to announce.
        self.call = nil
        callStartedAt = nil
        publish(now: now)
    }

    /// A source telling us the call's state changed underneath us — answered on
    /// the phone, or in the app's own window rather than from the notch. Without
    /// this the ear would sit on "ringing" through an entire conversation.
    public func updateCallState(token: Int, to state: AlertCall.State, now: Date) {
        guard var current = call, current.token == token, current.state != state else { return }
        current.state = state
        if state == .connected, current.connectedAt == nil {
            // First time we've seen it live. We can't know when it truly
            // connected — the source only tells us that it has — so the clock
            // starts now and reads slightly low rather than inventing a past.
            current.connectedAt = now
        }
        call = current
        publish(now: now)
    }

    // MARK: - Time

    public func tick(now: Date) {
        var changed = false

        if let callStartedAt, let call, call.state == .ringing,
           now.timeIntervalSince(callStartedAt) >= Self.ringingLifetime {
            self.call = nil
            self.callStartedAt = nil
            changed = true
        }

        if let slotExpiresAt, now >= slotExpiresAt {
            advanceSlot(now: now)
            changed = true
        }

        // Idle reset: a tally nobody added to in two minutes stops being news.
        for (key, seen) in lastSeen where now.timeIntervalSince(seen) >= Self.tallyLifetime {
            counts[key] = nil
            lastSeen[key] = nil
            queue.removeAll { $0 == key }
            if currentGroup == key { clearSlot() }
            changed = true
        }

        if changed { publish(now: now) }
    }

    /// The user opened the notch — they have seen what there was to see, so
    /// every tally resets. A ringing call deliberately survives: opening the
    /// panel is not answering the phone.
    public func notchDidOpen(now: Date) {
        counts.removeAll()
        lastSeen.removeAll()
        queue.removeAll()
        clearSlot()
        publish(now: now)
    }

    // MARK: - Call actions

    public func perform(_ action: AlertCallAction, now: Date) {
        guard let current = call else { return }

        guard current.canAct, let pressHandler else {
            handOff(now: now)
            return
        }
        guard pressHandler(current.token, action) else {
            handOff(now: now)
            return
        }

        switch action {
        case .accept:
            var next = current
            next.state = .connected
            next.connectedAt = now
            call = next
        case .decline:
            call = nil
            callStartedAt = nil
        }
        publish(now: now)
    }

    private func handOff(now: Date) {
        guard var current = call else { return }
        handOffHandler?(current.bundleID)
        current.state = .handedOff
        current.canAct = false
        call = current
        publish(now: now)
    }

    // MARK: - Slot bookkeeping

    private func clearSlot() {
        currentGroup = nil
        slotExpiresAt = nil
    }

    private func advanceSlot(now: Date) {
        guard let next = queue.first else {
            clearSlot()
            return
        }
        queue.removeFirst()
        currentGroup = next
        slotExpiresAt = now.addingTimeInterval(Self.burstWindow)
    }

    private func publish(now: Date) {
        if let call {
            announcement = .call(call)
            return
        }
        guard let currentGroup,
              let count = counts[currentGroup], count > 0,
              let identity = identities[currentGroup] else {
            announcement = nil
            return
        }
        announcement = .notifications(
            AlertNotificationBurst(groupKey: currentGroup,
                                   bundleID: identity.bundleID,
                                   appName: identity.appName,
                                   count: count))
    }

    // MARK: - Classification

    /// A banner is a CALL when it offers both an accept-shaped and a
    /// decline-shaped button. Buttons are the signal, not the app: a WhatsApp
    /// message and a WhatsApp call come from the same bundle ID and differ only
    /// here. A lone "Dismiss"/"Mark as Read" pair therefore stays a
    /// notification, which is the whole point of requiring BOTH sides.
    static func classifyCall(_ banner: AlertBanner) -> AlertCall? {
        let normalized = banner.buttonTitles.map(Self.normalizedForMatching)
        let hasAccept = normalized.contains { acceptWords.contains($0) }
        let hasDecline = normalized.contains { declineWords.contains($0) }

        if hasAccept, hasDecline {
            // Both buttons present: the notch can really answer and hang up.
            return AlertCall(callerName: callerName(from: banner),
                             appName: banner.appName,
                             bundleID: banner.bundleID,
                             token: banner.token,
                             state: .ringing,
                             canAct: true,
                             connectedAt: nil)
        }

        // No usable buttons, but the banner says it is a call. WhatsApp,
        // FaceTime and Telegram all announce an incoming call in words, and
        // whether their Accept/Decline reaches the Accessibility tree is not
        // something we control — macOS hides banner actions behind hover on some
        // releases. Announcing "Priya is calling" with no buttons is far better
        // than filing a ringing phone as one more unread notification.
        //
        // `canAct: false`, deliberately: the ear then shows the caller and NO
        // buttons, so it never offers something it cannot deliver. Pressing it
        // hands off to the calling app.
        if looksLikeCallText(banner) {
            return AlertCall(callerName: callerName(from: banner),
                             appName: banner.appName,
                             bundleID: banner.bundleID,
                             token: banner.token,
                             state: .ringing,
                             canAct: false,
                             connectedAt: nil)
        }
        return nil
    }

    /// Does the banner's own text announce an incoming call?
    ///
    /// Matched against the BODY only, and only at its start. A chat message that
    /// happens to contain "incoming call" mid-sentence is a message, not a call —
    /// requiring the phrase to open the body is what keeps a conversation about
    /// calls from ringing the notch.
    static func looksLikeCallText(_ banner: AlertBanner) -> Bool {
        let body = normalizedForMatching(banner.body)
        guard !body.isEmpty else { return false }
        return callPhrases.contains { body.hasPrefix($0) }
    }

    /// How the call apps word it, spaces stripped to match `normalizedForMatching`.
    /// Same reasoning as the button vocabulary: the banner is written in the
    /// SYSTEM's language, so every language we ship is live at once.
    static let callPhrases: Set<String> = [
        // en — WhatsApp ("Incoming voice call"), FaceTime, Telegram
        "incomingcall", "incomingvoicecall", "incomingvideocall",
        "iscalling", "callingyou", "wantstotalk",
        // zh-Hans / zh-Hant
        "来电", "來電", "语音通话", "語音通話", "视频通话", "視訊通話", "正在呼叫",
        // ja
        "着信", "音声通話", "ビデオ通話",
        // ko
        "수신전화", "음성통화", "영상통화",
        // fr
        "appelentrant", "appelvocal", "appelvidéo", "appelvideo",
        // es
        "llamadaentrante", "llamadadevoz", "videollamada",
    ]

    /// The banner's title is the caller on every call app we checked (FaceTime,
    /// relayed iPhone calls, WhatsApp, Telegram); the body carries "Incoming
    /// call"-type boilerplate. Fall back to the app name so the ear is never
    /// blank.
    private static func callerName(from banner: AlertBanner) -> String {
        let title = displayText(banner.title)
        if !title.isEmpty { return title }
        let body = displayText(banner.body)
        if !body.isEmpty { return body }
        return displayText(banner.appName)
    }

    /// A string as it should be SHOWN, rather than as it should be matched.
    ///
    /// Same invisible characters as `normalizedForMatching` come off — a caller
    /// whose name is nothing but bidi marks has to read as empty, not as a blank
    /// ear that thinks it has a name — but the letters keep their case and the
    /// spaces between words survive. Running "Jane Doe" together into one word is
    /// right for a button vocabulary and wrong for a name on the shoulder of the
    /// notch, which is why these are two functions and not one.
    public static func displayText(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Case-, space- and *invisible*-insensitive form used for button matching.
    /// Shared with the watcher, which has to find the same button again to press
    /// it.
    ///
    /// The invisible part is not defensive programming — it is the whole reason
    /// this feature ever worked. Real call apps do not ship the bare word
    /// "Accept". WhatsApp prefixes every single user-facing string with U+200E
    /// (LEFT-TO-RIGHT MARK) so a caller's name in a right-to-left script cannot
    /// flip the surrounding layout; you can see it in its own catalogue, where
    /// the button reads `"\u{200E}Accept"`, and in `NSRunningApplication`, where
    /// the app calls itself `"\u{200E}WhatsApp"`. Apple's own apps wrap names in
    /// the bidi isolates U+2068/U+2069 for the same reason.
    ///
    /// An earlier version stripped only ASCII space and U+00A0, so every one of
    /// those labels normalized to `"\u{200E}accept"` and matched NOTHING in the
    /// vocabularies below — the notch was walking real call windows and quietly
    /// deciding none of them were calls. Dropping the whole default-ignorable
    /// class (the bidi marks, the isolates, zero-width space, the BOM, soft
    /// hyphen, variation selectors) plus every Unicode whitespace is what makes
    /// the vocabularies match the strings that actually reach us.
    public static func normalizedForMatching(_ title: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in title.lowercased().unicodeScalars {
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
            result.append(scalar)
        }
        return String(result)
    }

    /// Button vocabulary in the languages the app ships, spaces stripped. This
    /// is matched against the SYSTEM's language (the banner is drawn by macOS
    /// and the source app), not the app's own setting, so all of them are live
    /// at once.
    static let acceptWords: Set<String> = [
        // en
        "accept", "answer", "pickup", "join",
        // zh-Hans / zh-Hant
        "接受", "接聽", "接听", "接電話", "接电话", "加入",
        // ja
        "応答", "参加",
        // ko
        "수락", "받기", "참여",
        // fr
        "accepter", "répondre", "repondre", "rejoindre",
        // es
        "aceptar", "responder", "contestar", "unirse",
    ]

    static let declineWords: Set<String> = [
        // en — "dismiss" is deliberately absent: it is the generic banner
        // action, so accepting it here would turn ordinary notifications into
        // phantom calls.
        "decline", "reject", "hangup", "end", "endcall", "ignore",
        // zh-Hans / zh-Hant
        "拒絕", "拒绝", "掛斷", "挂断", "結束", "结束",
        // ja
        "拒否", "終了", "切断",
        // ko
        "거절", "종료", "끊기",
        // fr
        "refuser", "rejeter", "raccrocher", "terminer",
        // es
        "rechazar", "colgar", "finalizar", "terminar",
    ]
}
