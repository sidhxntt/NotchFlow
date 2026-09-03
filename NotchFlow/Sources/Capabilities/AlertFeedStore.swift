import Combine
import Foundation

/// One banner macOS' Notification Center just put on screen, flattened to plain
/// values. `AlertBannerWatcher` (app side) produces these from the Accessibility
/// tree; nothing in this file knows that Accessibility exists, which is what
/// makes the policy below testable.
public struct AlertBanner: Equatable, Sendable {
    public let appName: String
    public let bundleID: String?
    public let title: String
    public let body: String
    public let token: Int

    public init(appName: String, bundleID: String?, title: String, body: String,
                token: Int) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.body = body
        self.token = token
    }

    /// The key the per-app tally is grouped under. Bundle ID when we could
    /// resolve one, otherwise the app's display name — never empty, so two
    /// unresolvable apps still keep separate counts.
    public var groupKey: String {
        if let bundleID, !bundleID.isEmpty { return bundleID }
        return appName.isEmpty ? "unknown" : appName
    }

    /// The displayed payload of one delivery. Accessibility can reuse the same
    /// banner container for the next notification, so the watcher compares this
    /// value in addition to that container's identity.
    public var deliverySignature: AlertBannerDeliverySignature {
        AlertBannerDeliverySignature(groupKey: groupKey, title: title, body: body)
    }
}

public struct AlertBannerDeliverySignature: Hashable, Sendable {
    public let groupKey: String
    public let title: String
    public let body: String

    public init(groupKey: String, title: String, body: String) {
        self.groupKey = groupKey
        self.title = title
        self.body = body
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

/// The single thing the resting notch reads.
public enum AlertAnnouncement: Equatable, Sendable {
    case notifications(AlertNotificationBurst)
}

/// Policy over the banner feed: tally, queue, expire.
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

    @Published public private(set) var announcement: AlertAnnouncement?

    private var counts: [String: Int] = [:]
    private var lastSeen: [String: Date] = [:]
    private var queue: [String] = []
    private var currentGroup: String?
    private var slotExpiresAt: Date?
    private var identities: [String: (bundleID: String?, appName: String)] = [:]
    private var bannerGroupsByToken: [Int: String] = [:]

    /// Our own banners (answer ready, agent finished) must never feed our own
    /// ear — that is a feedback loop, not a notification.
    private let ownBundleID: String?

    public init(ownBundleID: String? = Bundle.main.bundleIdentifier) {
        self.ownBundleID = ownBundleID
    }

    // MARK: - Ingest

    public func ingest(_ banner: AlertBanner, now: Date) {
        if let ownBundleID, banner.bundleID == ownBundleID { return }

        identities[banner.groupKey] = (banner.bundleID, banner.appName)
        bannerGroupsByToken[banner.token] = banner.groupKey
        counts[banner.groupKey, default: 0] += 1
        lastSeen[banner.groupKey] = now

        if currentGroup == banner.groupKey {
            slotExpiresAt = now.addingTimeInterval(Self.burstWindow)
        } else if currentGroup == nil {
            currentGroup = banner.groupKey
            slotExpiresAt = now.addingTimeInterval(Self.burstWindow)
        } else if !queue.contains(banner.groupKey) {
            queue.append(banner.groupKey)
        }
        publish()
    }

    /// The watcher noticed a banner leave the screen.
    public func bannerVanished(token: Int, now: Date) {
        bannerGroupsByToken[token] = nil
    }

    /// Refresh the dwell for the notification that macOS is still displaying.
    public func bannerIsVisible(token: Int, now: Date) {
        guard let group = bannerGroupsByToken[token], group == currentGroup else { return }
        slotExpiresAt = now.addingTimeInterval(Self.burstWindow)
    }

    // MARK: - Time

    public func tick(now: Date) {
        var changed = false

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

        if changed { publish() }
    }

    /// The user opened the notch — they have seen what there was to see, so
    /// every tally resets.
    public func notchDidOpen(now: Date) {
        counts.removeAll()
        lastSeen.removeAll()
        queue.removeAll()
        clearSlot()
        publish()
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

    private func publish() {
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
}
