import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Window controller

/// The exact spring used by the main-flow Recent module. The compact Force
/// Touch drawer shares it for its shell, rows, and disclosure glyph so the whole
/// interaction has one gravity/rebound signature.
enum CompactHistoryMotion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    /// The reveal's backstop window (see `animateCompactHeight`): the frame
    /// normally lands on the spring's own completion, and this only covers a
    /// reveal that never reports.
    static let settleDuration: TimeInterval = 0.70
}

/// One controller per detached window. Born either mid-drag (`beginDragDetach`,
/// the tear-off path: a borderless-looking card that rides the mouse until
/// release, then settles into a full window) or directly (`present`, the V0
/// button path: the same settle morph, just without the ride).
@MainActor
final class DetachedSessionWindowController: NSObject, NSWindowDelegate {
    /// Every open detached window, so a second detach of the same session
    /// focuses the existing window instead of forking a twin.
    static var controllers: [DetachedSessionWindowController] = []

    static func requireProductEntitlement() -> Bool {
        guard LicenseService.shared.state.allowsProductServices else {
            NotificationCenter.default.post(name: .openSettingsRequested, object: nil)
            return false
        }
        return true
    }

    static func closeAllForLicenseBlock() {
        let openControllers = controllers
        for controller in openControllers { controller.window?.close() }
        controllers.removeAll()
    }

    static func controller(for session: DetachedSession) -> DetachedSessionWindowController? {
        controllers.first { $0.session == session }
    }

    /// What this window holds *right now* — a composer can become a thread
    /// mid-life, so it lives in the observable state and every reader (the merge
    /// zone, the twin check, the root view) goes through here.
    var session: DetachedSession { state.session }
    var threadStore: DetachedThreadStore? { state.threadStore }
    let face: DetachedCardFace
    weak var model: NotchModel?
    var window: NSWindow!
    let state: DetachedWindowState
    /// Prompt-shortcut results use the same live thread machinery, but wear a
    /// smaller pointer-side shell whose height follows the answer.
    let compactShortcut: Bool
    /// Quick actions operate on captured text, so an invocation without a real
    /// selection is born at the input-only height instead of opening empty space
    /// that the first SwiftUI layout immediately has to remove.
    var composerRestingHeight: CGFloat {
        CompactShortcutPromptView.restingHeight(
            withPicks: !state.compactSourceText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    /// Stable identity of the prompt binding that owns a compact window. Its
    /// thread id changes on each invocation; this id keeps the shell singular.
    let compactShortcutID: UUID?
    /// The app that owned the selected text when the shortcut fired. Updated on
    /// every invocation because one shortcut window may be reused across apps.
    var replacementApplication: NSRunningApplication?
    /// The pointer this composer was summoned at — kept so the first real layout
    /// can put the caret exactly on it (`alignCaret`), rather than leaving the
    /// window wherever the pre-layout estimate guessed.
    var summonPointer: NSPoint?
    /// How long after a pointer-side window opens a resign-key is read as the
    /// echo of the gesture that summoned it rather than as the user leaving.
    static let summonGrace: TimeInterval = 0.6
    /// Until when that applies — see `armSummonGrace`.
    var summonGraceUntil: Date?
    /// Polls the button that is still holding the summoning press down.
    var summonReleaseTimer: Timer?
    /// Key has already been taken back once for the current grace.
    var reclaimedAfterSummon = false
    /// Streaming Markdown can briefly report a shorter layout while a token is
    /// being reclassified or SwiftUI catches up with AppKit's text estimate.
    /// Keep the tallest accepted height for this round so those transient
    /// measurements cannot pull the window back and forth.
    var compactRoundHeight: CGFloat = CompactShortcutPromptView.restingHeight
    /// The height this round is pinned to until it has an answer to open for —
    /// the waiting card for a shortcut that opens straight into one, the
    /// composer's own height for a round the user typed
    /// (`submitCompactShortcutPrompt`). Thinking never moves the window.
    var compactFloorHeight: CGFloat =
        DetachedSessionWindowController.compactInitialHeight
    /// The live glide that opens the window as the answer lands: where it's
    /// headed, the tick that takes it there, and when that tick last ran.
    var compactTargetHeight: CGFloat = 0
    var compactGlideTimer: Timer?
    var compactGlideAt: TimeInterval = 0
    var compactRevealCompletion: DispatchWorkItem?
    var compactRevealGeneration = 0
    /// A History disclosure is one discrete resize, unlike streaming answer
    /// growth. It gets a dedicated top-locked animation instead of borrowing
    /// the answer glide while SwiftUI is animating the rows too.
    var animateForceTouchHistoryResize = false
    /// Tracks the empty/non-empty boundary of the compact prompt. Crossing it
    /// folds or restores the quick actions, so that one height change gets the
    /// same discrete top-locked animation as History instead of a hard resize.
    var compactPromptWasEmpty = true

    /// Mid-drag machinery (tear-off path only).
    var dragMonitor: Any?
    var grabOffset = NSPoint.zero          // mouse → window-origin delta, keeps the grip point
    var lastMouse = NSPoint.zero
    var lastMouseAt: TimeInterval = 0

    /// Merge-back machinery (settled phase).
    var moveObserver: NSObjectProtocol?
    var mergeArmed = false

    /// This window has held the keyboard at least once. The empty-composer
    /// dismissal below hangs off *losing* key, and a window that never got it
    /// (the activation lost a race with the source app) must not be closed by
    /// the resign that never had a matching become.
    var hasHeldKey = false

    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: - The force click, before it is a composer

    /// True while this window is drawing a force click that hasn't fired yet, or
    /// the stretch that follows it — i.e. while it is the cue *and* the window.
    var isDrawingPressure = false
    /// A retreat is in flight. Only `drawPressure` reads it, to interrupt that
    /// retreat when the same press comes back before the fade is done.
    var pressureRetracting = false

    init(session: DetachedSession, face: DetachedCardFace, model: NotchModel,
                 compactShortcut: Bool = false, compactShortcutID: UUID? = nil,
                 replacementApplication: NSRunningApplication? = nil) {
        self.state = DetachedWindowState(session: session)
        self.face = face
        self.model = model
        self.compactShortcut = compactShortcut
        self.compactShortcutID = compactShortcutID
        self.replacementApplication = replacementApplication
        super.init()
        // Pointer-side shortcut results behave like ordinary transient utility
        // windows. They stay above other apps only when the user explicitly pins
        // them; regular torn-out sessions retain their pinned-by-default behavior.
        if compactShortcut { state.pinned = false }
        if let threadID = session.threadID {
            state.threadStore = model.adoptDetachedThread(threadID)
        }
        if case .compose = session {
            // The line the user was already writing rides out with the window.
            // Read before `completeDetach` clears the panel's box — both entry
            // points construct the controller first.
            state.composeDraft = model.text
        }
    }
}
