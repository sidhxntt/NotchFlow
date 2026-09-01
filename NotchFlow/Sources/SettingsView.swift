import AppKit
import SwiftUI

/// The desktop Settings surface mirrors NotchFlow's workspaces. Chat and Agent
/// configuration is deliberately separate from the Media/Utilities companion
/// experience, with a small set of global app preferences below it.
struct NativeSettingsView: View {
    enum Page: String, CaseIterable, Identifiable {
        case chat = "Chat", agent = "Agent", media = "Media", utilities = "Utilities"
        case appearance = "Appearance", global = "Global", stats = "Stats", about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .chat: "message"; case .agent: "terminal"; case .media: "music.note"; case .utilities: "square.grid.2x2"
            case .appearance: "paintbrush"; case .global: "gearshape"; case .stats: "chart.bar"
            case .about: "info.circle"
            }
        }
    }

    @ObservedObject var model: NotchModel
    @ObservedObject private var capabilities = NotchCapabilityStore.shared
    @State private var page: Page = .chat

    /// The categories that mean anything for the way the app is currently
    /// configured. Chat, Agent, and Stats all describe the agentic layer — Stats
    /// is the archive that layer writes — so turning agentic mode off retires all
    /// three rather than leaving pages that report on a surface the user can no
    /// longer reach. Agentic mode itself lives in Global, which never leaves.
    static func pages(agenticModeEnabled: Bool) -> [Page] {
        Page.allCases.filter {
            agenticModeEnabled || ($0 != .chat && $0 != .agent && $0 != .stats)
        }
    }

    private var pages: [Page] { Self.pages(agenticModeEnabled: capabilities.agenticModeEnabled) }

    var body: some View {
        // A plain split, NOT `NavigationSplitView`: that container installs its own
        // sidebar-toggle toolbar item after SwiftUI mounts the hierarchy, and it
        // came back regardless of `.toolbar(removing: .sidebarToggle)` or clearing
        // `window.toolbar`. The settings sidebar is permanent by design — there is
        // nothing for a drawer control to do — so the fix is to not adopt the
        // container that insists on one.
        HStack(spacing: 0) {
            List(pages, selection: $page) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 150)

            Divider()

            InlineSettingsView(model: model, presentedInSettingsWindow: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // No minimum frame here — the floor is `window.minSize`. A SwiftUI minimum
        // becomes a hosting-view constraint the window has to satisfy, and the
        // widest pane's ideal width then pushed the window past the compact
        // default before it was ever shown.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { page = Self.page(for: model.settingsSection) }
        .onChange(of: page) { model.settingsSection = page.rawValue }
        .onChange(of: capabilities.agenticModeEnabled) { _, _ in
            if !pages.contains(page) { page = .media }
        }
        // `NavigationSplitView` used to name the window; without it the title is
        // ours to keep in step with the open category.
        .background(SettingsWindowTitle(title: page.rawValue))
    }

    private static func page(for section: String) -> Page {
        switch section {
        case "Model", "Capture": return .chat
        case "Shortcuts": return .agent
        case "General": return .global
        default: return Page(rawValue: section) ?? .chat
        }
    }
}

/// Owns the single, explicit macOS Settings window. `Settings` scenes are
/// responder-chain driven; that chain is not reliable for an accessory app with
/// no conventional main window, so NotchFlow presents this controller directly.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    func present(model: NotchModel) {
        if let window {
            window.contentView = Self.hostingView(model: model)
            hideEmptyToolbar(in: window)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NotchFlow Settings"
        window.minSize = NSSize(width: 640, height: 480)
        window.isReleasedWhenClosed = false
        // New frame key on every size change: an autosaved frame outranks the
        // `contentRect` above, so reusing the old key would restore the previous,
        // roomier window and the compact default would never be seen.
        let autosaveName = "NotchFlowSettings.compact2"
        let hasSavedFrame = UserDefaults.standard
            .string(forKey: "NSWindow Frame \(autosaveName)") != nil
        window.setFrameAutosaveName(autosaveName)
        window.contentView = Self.hostingView(model: model)
        window.delegate = self
        self.window = window
        hideEmptyToolbar(in: window)
        // Sized after the autosave name, which restores any saved frame the moment
        // it is set — and only when the user has never sized this window
        // themselves, because their own frame wins.
        if !hasSavedFrame {
            window.setContentSize(NSSize(width: 680, height: 520))
        }

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// The settings root, hosted inside a plain container view.
    ///
    /// As the window's `contentView`, `NSHostingView` publishes the SwiftUI
    /// content's ideal size to the window, which is obliged to grow to it — a
    /// 680×520 `contentRect` arrived on screen at 760×704, sized by whichever pane
    /// wanted the most room. Clearing `sizingOptions` alone did not settle it, so
    /// the hosting view goes one level down, autoresized inside an ordinary
    /// `NSView` that has no opinion about size at all. Settings scrolls; the
    /// content has no business dictating the window's dimensions.
    private static func hostingView(model: NotchModel) -> NSView {
        let hosting = NSHostingView(rootView: NativeSettingsView(model: model))
        hosting.sizingOptions = []
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 520))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    /// Settings owns no toolbar items of its own, and an empty toolbar still
    /// reserves a strip under the title bar. Cleared here rather than in SwiftUI
    /// because the hosting view is what attaches it.
    private func hideEmptyToolbar(in window: NSWindow) {
        DispatchQueue.main.async {
            window.toolbar = nil
        }
    }
}

/// Keeps the window title on the open category. `.navigationTitle` only reaches
/// the title bar through a navigation container, and Settings deliberately has
/// none (see `NativeSettingsView.body`).
private struct SettingsWindowTitle: NSViewRepresentable {
    var title: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let title = title
        DispatchQueue.main.async {
            view.window?.title = title
        }
    }
}

/// Notification names shared between the settings UI and `AppDelegate`.
///
/// These notifications coordinate the standalone Settings window with the
/// running notch. The same setting panes can still be hosted inline where a
/// focused flow needs them, but ordinary settings always open in their window.
extension Notification.Name {
    /// Posted after the user saves an API key or switches providers, so
    /// `AppDelegate` can rebuild the AI service and the next question goes live
    /// without a restart.
    static let aiBackendChanged = Notification.Name("aiBackendChanged")
    /// Posted by ⌘, (and the `NOTCH_SETTINGS` debug flag) so `AppDelegate` can
    /// show the standalone Settings window.
    static let openSettingsRequested = Notification.Name("openSettingsRequested")
    /// Posted by the app menu's "Check for Updates…" command so `AppDelegate`
    /// can open Settings → About and kick off a user-initiated update check.
    static let checkForUpdatesRequested = Notification.Name("checkForUpdatesRequested")
    /// Posted after the user changes the Display placement (Settings → Display),
    /// so `AppDelegate` can create/destroy per-screen panels immediately.
    static let displayPlacementChanged = Notification.Name("displayPlacementChanged")
    /// Posted after the user toggles the Dock icon (Settings → General), so
    /// `AppDelegate` can switch the app's activation policy live.
    static let dockIconVisibilityChanged = Notification.Name("dockIconVisibilityChanged")
    /// Posted after the user chooses an app icon (Settings → Appearance), so
    /// the Dock and app switcher update without a relaunch.
    static let appIconStyleChanged = Notification.Name("appIconStyleChanged")
    static let appIconAppearanceChanged = Notification.Name("appIconAppearanceChanged")
    /// Posted after the user toggles the menu bar icon (Settings → General),
    /// so `AppDelegate` can add or remove the status item right away.
    static let menuBarIconVisibilityChanged = Notification.Name("menuBarIconVisibilityChanged")
    /// Posted after the user toggles "Hide in full screen" (Settings → General),
    /// so `AppDelegate` re-evaluates which panels to hide right away.
    static let hideNotchInFullscreenChanged = Notification.Name("hideNotchInFullscreenChanged")
    /// Posted after the user changes the global summon shortcut (Settings →
    /// General), so `AppDelegate` re-registers the Carbon hot key immediately.
    static let summonHotKeyChanged = Notification.Name("summonHotKeyChanged")
    /// Posted after a prompt shortcut is added, removed, or re-recorded, so the
    /// live set of global Carbon hot keys follows the Shortcuts pane immediately.
    static let promptShortcutsChanged = Notification.Name("promptShortcutsChanged")
    /// Posted after an in-app action chord is rebound or reset from chat, so an
    /// open Shortcuts pane redraws instead of showing the pre-change binding.
    static let appShortcutsChanged = Notification.Name("appShortcutsChanged")
    /// Posted when the Shortcuts pane starts or stops listening for a chord, so
    /// every global hot key stands down and the recorder can actually observe the
    /// keys Notch itself owns (see `ShortcutRecording`).
    static let shortcutRecordingChanged = Notification.Name("shortcutRecordingChanged")
    /// Posted by the Recent list's "See all" action, so `AppDelegate` can open the
    /// standalone History window showing the complete, uncapped archive.
    static let openHistoryArchiveRequested = Notification.Name("openHistoryArchiveRequested")
    /// Posted when a CLI service's launch resolution lands (the `claude` / `codex` /
    /// `grok` / `cmd` binary probe finished), so the views that asked `isAvailable`
    /// while the answer was still unknown redraw with the real one. See
    /// `resolvedBinaryIfReady()` — availability reads never block a render, so this
    /// is what closes the loop.
    static let cliAvailabilityResolved = Notification.Name("cliAvailabilityResolved")
}
