import AppKit
import CoreGraphics

/// Watches for macOS's secure prompts (see `SecurePromptPolicy`) and tells the
/// app delegate to take the notch panels off screen while one is showing.
///
/// There is no notification for "a Touch ID prompt appeared", so this polls the
/// window list — on-screen windows only, a sub-millisecond call — twice a
/// second, and immediately whenever another app activates (most prompts
/// activate their process). The callback fires only on a change.
@MainActor
final class SecurePromptGuard {
    static let shared = SecurePromptGuard()

    private(set) var isPromptVisible = false
    private var onChange: ((Bool) -> Void)?
    private var timer: Timer?
    private var activationObserver: NSObjectProtocol?
    /// Owners already written to the diagnostics log this session.
    private var reportedOwners = Set<String>()

    func start(onChange: @escaping (Bool) -> Void) {
        guard timer == nil else { return }
        self.onChange = onChange
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        check()
    }

    private func check() {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]] else { return }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let islandLayer = Int(CGWindowLevelForKey(.statusWindow))
        var found = false
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) != ownPID else { continue }
            let owner = window[kCGWindowOwnerName as String] as? String
            if SecurePromptPolicy.isSecurePrompt(ownerName: owner) {
                found = true
                break
            }
            let layer = window[kCGWindowLayer as String] as? Int ?? 0
            if SecurePromptPolicy.isUnknownHighWindow(ownerName: owner, layer: layer, islandLayer: islandLayer),
               let owner, reportedOwners.insert(owner).inserted {
                // Not acted on — only recorded, so a prompt this list does not
                // know yet can be identified from the diagnostics log.
                DiagnosticsLog.shared.record(provider: "SecurePrompt", kind: "unknown-high-window:\(owner)")
            }
        }
        guard found != isPromptVisible else { return }
        isPromptVisible = found
        onChange?(found)
    }
}
