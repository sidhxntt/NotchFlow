import AppKit
import SwiftUI

/// Release-notes source for the "What's New" panel. The notes ship *inside* the
/// app bundle — there's no network fetch — so the panel always has exactly the
/// notes that were built into this copy of Notch, online or off.
///
/// To publish notes for a new release, add an entry to `bundled` below (newest
/// versions can go anywhere in the list — they're sorted newest-first for you)
/// and ship the build. That's the single place to edit.
///
/// The "first launch after an update shows what changed once" behaviour is owned
/// here: `unseenVersion` compares the running build against the last version the
/// user actually saw the panel for, and `markSeen()` records the current one.
@MainActor
final class WhatsNewService: ObservableObject {
    static let shared = WhatsNewService()

    /// One published release. `version` is the only required field; `date` is an
    /// optional adornment. The notes are split into four sections the panel renders
    /// under their own headings — `features` (brand-new capabilities),
    /// `improvements` (refinements to things that already existed), `fixes` (what
    /// got fixed), and `others` (project/personal housekeeping such as support and
    /// license links). Any can be empty; an empty section is omitted entirely.
    struct Entry: Identifiable, Equatable {
        var version: String
        var date: String?
        var heroAssetName: String?
        var features: [String]
        var improvements: [String]
        var fixes: [String]
        var others: [String]
        var action: Action?
        /// Which `features` line the action's button hangs under (0-based). `nil`
        /// puts it at the end of the release's notes.
        var actionAfter: Int?

        var id: String { version }

        /// The one thing a release wants the reader to be able to DO, offered as a
        /// button under its notes — a switch announced in a bullet is otherwise a
        /// scavenger hunt through Settings.
        ///
        /// A closed enum, not a closure: `Entry` is `Equatable` (the panel animates
        /// on it) and closures aren't. The view owns where each case goes.
        enum Action: String, Equatable {
            /// Settings → Appearance, where Force click pressure lives.
            case forceClickPressure

            var title: String {
                switch self {
                case .forceClickPressure: L("whatsnew.action.forceClick")
                }
            }
        }

        init(
            version: String,
            date: String? = nil,
            heroAssetName: String? = nil,
            features: [String] = [],
            improvements: [String] = [],
            fixes: [String] = [],
            others: [String] = [],
            action: Action? = nil,
            actionAfter: Int? = nil
        ) {
            self.version = version; self.date = date
            self.heroAssetName = heroAssetName
            self.features = features; self.improvements = improvements
            self.fixes = fixes; self.others = others
            self.action = action; self.actionAfter = actionAfter
        }
    }

    /// The release notes to render — newest first. Bundled, so always populated.
    @Published private(set) var entries: [Entry]

    /// The version (e.g. "1.0.5") to announce in the idle input cue, or `nil` once
    /// the user has seen the notes for this build. Resolved once at launch (a pure
    /// `@Published` the view can read on every render) and cleared by `markSeen()`.
    @Published private(set) var unseenVersion: String?

    // MARK: - Source

    /// The release notes, written straight into the app. **Edit here each release.**
    ///
    /// Each release has three sections — `features` (brand-new capabilities),
    /// `improvements` (refinements to existing behaviour), and `fixes` (what got
    /// fixed). Write for the user, not the code: say what changed for *them* and
    /// why it's nice, in plain language. Skip internal/refactor churn they'd never
    /// notice. Leave a section empty (omit it) if there's nothing for it.
    /// English-only by design. Order doesn't matter — `sorted` puts the newest
    /// version first. Each string is one bullet; no leading `•`.
    private static let bundled: [Entry] = [
        Entry(
            version: "1.0.2",
            date: "2026-09-02",
            features: [
                "Start with a full seven-day trial. When it ends, NotchFlow pauses every product feature until you activate a paid license.",
                "Buy a NotchFlow license through Lemon Squeezy, then enter the license key emailed to you to unlock this Mac.",
                "A valid NotchFlow license is perpetual and includes future NotchFlow updates.",
            ],
            improvements: [
                "Direct downloads now use a Developer ID-signed, notarized DMG. A matching ZIP remains available when you cannot mount a disk image.",
                "Release checks now verify the exact version, app identity, signer and Apple-silicon build before a download is published.",
            ],
            others: [
                "The new Privacy Policy explains what stays on your Mac, what is sent to providers you choose, and how licensing works.",
            ]
        ),
        Entry(
            version: "1.0",
            date: "2026-08-27",
            features: [
                "NotchFlow turns the notch into a place to think and act: hover it, type, and what you wrote is recognised as a chat, a note, a reminder, or a coding task — no mode to pick first.",
                "Ask any model you already pay for. Bring your own key for Anthropic, OpenAI, OpenRouter, Grok and others; prompts go straight to the provider you configured.",
                "Hand long work to a coding agent — Codex, Claude Code or Grok — and watch it run from the closed notch, with follow-up instructions and resume after an interruption.",
                "Drop files on the notch to park them in the File Tray, then drag them back out wherever you need them.",
                "Type a thought and file it in Apple Notes, or a time-bound line and file it in Apple Reminders.",
                "Copy something worth keeping and the notch offers to file it — press ⌘C again to accept.",
                "A Pomodoro timer that traces its lap around the notch's edge, announces each phase hand-off, and keeps a streak grid of the days you showed up.",
                "Now playing, volume and transport controls for whatever is making sound, plus an announcement when your AirPods connect.",
                "Notifications land on the notch's shoulders with an app's icon and unread count.",
                "Your calendar's next events, a webcam preview, and handwritten answers if you prefer them typeset by hand.",
                "Speaks English, Simplified and Traditional Chinese, Japanese, Korean, French and Spanish.",
            ],
            others: [
                "Everything stays on your Mac or goes directly to the provider you chose. NotchFlow relays nothing and has no account.",
                "Built on Notchi by Cyrus Cai, MIT licensed.",
            ]
        ),
    ]

    private let lastSeenVersionKey = "whatsnew_last_seen_version"

    /// Debug switch: when on, the cue and panel always appear and never record
    /// "seen", so What's New can be re-opened any number of times. Off by default.
    /// Flip it without a rebuild via either:
    ///   · `defaults write com.notchflow.app whatsnew_always_show -bool YES`
    ///   · launching with the `NOTCH_WHATSNEW_ALWAYS=1` environment variable
    /// (Set the default back to NO / unset the env var to restore normal once-per
    /// -version behaviour.)
    static let alwaysShowKey = "whatsnew_always_show"
    static var alwaysShow: Bool {
        if let env = ProcessInfo.processInfo.environment["NOTCH_WHATSNEW_ALWAYS"],
           env == "1" || env.lowercased() == "true" {
            return true
        }
        return UserDefaults.standard.bool(forKey: alwaysShowKey)
    }

    private init() {
        entries = Self.sorted(Self.bundled)
        unseenVersion = Self.resolveUnseenVersion(key: lastSeenVersionKey)
    }

    // MARK: - "Seen once per version"

    /// The running build, normalized to the same string `UpdaterService` compares.
    private var currentVersion: String { UpdaterService.currentVersion }

    /// Resolve, once at launch, whether the cue should announce this build — and
    /// record a baseline on a brand-new install so the very first launch stays
    /// quiet. A first-ever launch (no stored version) is treated as "seen": we
    /// don't pop What's New before the user has done anything. Only a genuine
    /// version *change* from a known baseline announces.
    private static func resolveUnseenVersion(key: String) -> String? {
        let current = UpdaterService.currentVersion
        // Debug switch wins: always announce, and never record a baseline.
        if alwaysShow { return current }
        guard let seen = UserDefaults.standard.string(forKey: key) else {
            UserDefaults.standard.set(current, forKey: key)
            return nil
        }
        return seen != current ? current : nil
    }

    /// Record that the user has now seen the notes for the running build, so the
    /// cue doesn't fire again until the next update. Clears `unseenVersion`, which
    /// dismisses the input-row cue.
    func markSeen() {
        // With the debug switch on, the cue is meant to persist — don't record a
        // baseline and don't clear the announce, so What's New keeps coming back.
        guard !Self.alwaysShow else { return }
        UserDefaults.standard.set(currentVersion, forKey: lastSeenVersionKey)
        unseenVersion = nil
    }

    // MARK: - Ordering

    /// Newest version first, so the panel leads with the latest release.
    private static func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { UpdaterService.isNewer($0.version, than: $1.version) }
    }
}
