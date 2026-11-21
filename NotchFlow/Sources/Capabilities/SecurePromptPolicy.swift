import Foundation

/// Which on-screen windows are macOS's own secure prompts — Touch ID, password,
/// purchase and payment confirmations — that the notch must never sit over.
///
/// The island's panel is a 760×640 transparent window parked at status-bar
/// level for the life of the app. Transparent is not absent: the window server
/// still counts it as another process's window over the top of the screen,
/// and with NotchFlow running the Touch ID affordance of these prompts was
/// reported missing. Rather than depend on how each prompt reacts to an
/// overlay, the app takes its panels off screen while one is up and puts them
/// back when it goes away.
///
/// Matched by process name because that is what `CGWindowListCopyWindowInfo`
/// reports without Screen Recording permission (window *titles* need it).
public enum SecurePromptPolicy {
    /// Processes that draw secure system prompts.
    public static let ownerNames: Set<String> = [
        "coreautha",                        // LocalAuthentication: "… wants to use Touch ID"
        "SecurityAgent",                    // authorization / administrator password
        "LocalAuthenticationRemoteService",
        "LocalAuthenticationUIService",
        "AuthenticationServicesAgent",      // passkeys and sign-in sheets
        "AuthKitUIService",                 // Apple Account authentication
        "PassKitUIService",                 // Apple Pay
        "PaymentUIService",
        "storeuid",                         // App Store purchase confirmation
        "StoreUIService",
    ]

    /// System processes that legitimately own high windows near the notch and
    /// are not prompts. Excluded from the diagnostic log so it only ever
    /// surfaces genuinely unknown candidates.
    public static let ordinarySystemOwners: Set<String> = [
        "Window Server", "Dock", "Control Center", "ControlCenter", "SystemUIServer",
        "Notification Center", "NotificationCenter", "Spotlight", "TextInputMenuAgent",
        "TextInputSwitcher", "Screenshot", "screencaptureui", "WindowManager",
    ]

    public static func isSecurePrompt(ownerName: String?) -> Bool {
        guard let ownerName else { return false }
        return ownerNames.contains(ownerName)
    }

    /// A window worth recording when the user reports a hidden prompt: someone
    /// else's window at or above the island's level, below the menu layer
    /// (app menus, which open constantly, sit at 101), and not a known
    /// ordinary system surface.
    public static func isUnknownHighWindow(ownerName: String?, layer: Int, islandLayer: Int) -> Bool {
        guard let ownerName, !ownerName.isEmpty else { return false }
        guard layer >= islandLayer, layer < 101 else { return false }
        return !ownerNames.contains(ownerName) && !ordinarySystemOwners.contains(ownerName)
    }
}
