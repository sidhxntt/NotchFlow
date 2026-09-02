import SwiftUI

/// True entry point. Before SwiftUI/AppKit spins up, the headless service mode
/// is peeled off: launched with `GrokSearchMCPServer.launchFlag`, this binary is
/// a tiny MCP stdio server (grok spawns it to reach Notch's unified web-search
/// backend — see `GrokCLIService`) and must never touch the UI stack. Everything
/// else falls through to the normal SwiftUI app.
@main
enum NotchFlowMain {
    static func main() {
        if CommandLine.arguments.contains(GrokSearchMCPServer.launchFlag) {
            let configuration = try? LicensingConfiguration.bundled()
            let entitlement = LicenseService.localEntitlementSnapshot(
                configuration: configuration
            )
            guard entitlement.allowsProductServices else {
                let message = "NotchFlow requires an active trial or license. Open the app to buy or activate.\n"
                FileHandle.standardError.write(Data(message.utf8))
                exit(EXIT_FAILURE)
            }
            GrokSearchMCPServer.runAndExit()
        }
        NotchFlowApp.main()
    }
}

/// The app. Runs as a UI-element (no Dock icon, no menu bar app
/// window) — it's a single floating panel that grows out of the Mac's notch.
/// The real work happens in `AppDelegate`, which owns the borderless panel.
struct NotchFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Keep SwiftUI's Settings scene for the system menu integration, but
        // replace its responder-chain action with our explicit single-window
        // controller. This works for an accessory app with no main window.
        Settings { Color.clear.frame(width: 1, height: 1) }
            // Slot a "Check for Updates…" item into the standard app menu, right
            // under "About Notch". Done through SwiftUI's command system (not a
            // hand-inserted `NSMenuItem`) so it survives SwiftUI rebuilding the
            // menu after launch. The app menu only exists in `.regular` mode (Dock
            // icon shown); in the default `.accessory` overlay there's no menu bar
            // at all, so the item simply isn't visible then. The action routes
            // through `AppDelegate` via a notification — same handler ⌘ uses.
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") {
                        NotificationCenter.default.post(
                            name: .openSettingsRequested, object: nil)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                }
                CommandGroup(after: .appInfo) {
                    Button(L("about.checkForUpdates") + "…") {
                        if LicenseService.shared.state.allowsProductServices {
                            NotificationCenter.default.post(
                                name: .checkForUpdatesRequested, object: nil)
                        } else {
                            NotificationCenter.default.post(
                                name: .openSettingsRequested, object: nil)
                        }
                    }
                }
            }
    }
}
