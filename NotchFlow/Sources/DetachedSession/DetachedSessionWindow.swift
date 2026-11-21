import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A lossless-enough snapshot of the current pasteboard for a temporary
/// replace-selection paste. Every eagerly readable representation is retained;
/// restoration is skipped if another app changes the pasteboard in the meantime.
struct PasteboardSnapshot {
    let items: [[NSPasteboard.PasteboardType: Data]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { representations -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        _ = pasteboard.writeObjects(restored)
    }
}

// MARK: - What a detached window holds

/// One session torn out of the notch into its own window: a chat thread (Ask, or
/// a reopened agent-run thread) identified by its history id, a live agent task
/// identified by its `AgentTaskManager` id, or — with no session at all — the
/// idle prompt itself, torn out as a standalone composer. `.compose` carries no
/// id on purpose: it is the one page there can only ever be one of, so a second
/// tear-off focuses the composer already open instead of forking a twin. Sending
/// its first question promotes it to `.thread` in place (see `adoptThread`).
enum DetachedSession: Equatable {
    case compose
    /// A prompt shortcut with no saved instruction: the selection is already
    /// captured, and this compact face asks only for the one-off instruction.
    case shortcutComposer(id: UUID)
    case thread(id: UUID)
    case agentTask(id: UUID)

    var threadID: UUID? { if case .thread(let id) = self { return id }; return nil }
    var taskID: UUID?   { if case .agentTask(let id) = self { return id }; return nil }
}

/// The face the tear-off card wears — computed once at detach time so the ghost
/// in the canvas and the newborn window render the exact same card.
struct DetachedCardFace: Equatable {
    var title: String
    var subtitle: String
    var isAgent: Bool
    var running: Bool
}

/// Live mirror of a detached thread. While its round still streams, `NotchModel`
/// pushes every snapshot here (see `syncInFlight`/`persistThread`), so the
/// window keeps writing in real time even though the thread left the panel.
/// Deliberately its own tiny store: streaming-cadence updates invalidate only
/// the one window observing it, never the panel tree.
@MainActor
final class DetachedThreadStore: ObservableObject {
    /// Mutable because a regenerate on a single-pair thread re-ids it (the
    /// panel pipeline treats the emptied seed as a fresh thread) — the model
    /// re-keys this mirror to the new id so the window keeps following.
    var threadID: UUID
    @Published var turns: [NotchModel.Turn]
    @Published var agentFolderPath: String?
    @Published var completedAt: Date?
    /// Whether this thread's next destination can receive image input. Agent
    /// records follow their persisted CLI engine; ordinary Ask threads follow
    /// the active chat model at the moment the window is created.
    let followUpSupportsImages: Bool

    init(threadID: UUID, turns: [NotchModel.Turn],
         agentFolderPath: String? = nil, completedAt: Date? = nil,
         followUpSupportsImages: Bool = false) {
        self.threadID = threadID
        self.turns = turns
        self.agentFolderPath = agentFolderPath
        self.completedAt = completedAt
        self.followUpSupportsImages = followUpSupportsImages
    }

    /// The round finished (persisted to Recent) — freeze the mirror: no caret,
    /// no stale "searching…" line.
    func settle(with thread: [NotchModel.Turn]) {
        var cleaned = thread
        for i in cleaned.indices {
            cleaned[i].streaming = false
            cleaned[i].toolActivity = nil
            cleaned[i].thinkingStartedAt = nil
            cleaned[i].pendingQuestion = nil
        }
        turns = cleaned
    }
}

/// The detached window itself: borderless (the glass draws its own rounded
/// form — the system titlebar backdrop kept flashing against the glass and its
/// corner mask doesn't apply to transparent windows), but still key/main so
/// the follow-up field and shortcuts work. `.resizable` in the mask keeps
/// AppKit's edge-resize on a borderless window.
final class DetachedWindow: NSWindow {
    var closesOnEscape = false
    /// The app's editable chords (⌘P pin, ⌘C copy, ⌘R regenerate — see
    /// `DetachedSessionWindowController.handleAppShortcut`). A detached window is
    /// its own key window, so the panel's `KeyEventCatcher` — which only acts
    /// while ITS window is key — never sees these keys; the window has to answer
    /// them itself, or its chips would advertise chords that do nothing here.
    /// Returns true when the chord was claimed.
    var onAppShortcut: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Where the press that may become a move started: the pointer on screen and
    /// the window's own corner, both frozen at mouse-down.
    private var dragAnchor: (mouse: NSPoint, origin: NSPoint)?
    /// The press has travelled far enough to be a move rather than a click.
    private var dragging = false
    /// How far it has to travel first, so a tap on a SwiftUI button is still a
    /// tap — SwiftUI draws its controls, it does not give them AppKit views, so
    /// a press on one is indistinguishable from a press on bare glass until it
    /// moves.
    private static let dragSlop: CGFloat = 4

    /// Move the window from here, rather than leaving it to
    /// `isMovableByWindowBackground`.
    ///
    /// That flag is worse than useless here, and `makeWindow` turns it OFF. The
    /// card's content is one `NSHostingView`, which answers
    /// `mouseDownCanMoveWindow = true` for every point SwiftUI merely draws, so
    /// the window server claimed those presses for its own background drag and
    /// then moved nothing. The same mechanism made the earlier grab view
    /// (`WindowDragArea`, now gone) carve two dead strips instead of a handle.
    ///
    /// So the move is explicit: the press is watched here, and once it travels,
    /// the window follows the pointer by hand. Nothing about it depends on which
    /// view SwiftUI decided to put where.
    ///
    /// The other half of "a press lands here at all" is upstream of AppKit. A
    /// borderless window that isn't opaque gets an INPUT REGION, and a press
    /// outside it is routed to whatever app is behind the window — the app never
    /// hears about it. A view that opts out of SwiftUI hit testing is left out of
    /// that region no matter how solidly it draws, which is what a
    /// `.allowsHitTesting(false)` on the card's own glass cost: the card was a
    /// hole everywhere except its input recess and the rows' focus proxies, so it
    /// could be picked up by the input line and nowhere else. Measured, on this
    /// exact window shape: glass + 30% black, opted out → the press goes to the
    /// app behind; the same pixels left hit-testable → the press arrives. The
    /// glass is the card's surface; it takes the press.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragging = false
            dragAnchor = pressIsOnBareGlass(event)
                ? (NSEvent.mouseLocation, frame.origin) : nil
        case .leftMouseDragged:
            if let anchor = dragAnchor {
                let now = NSEvent.mouseLocation
                let dx = now.x - anchor.mouse.x
                let dy = now.y - anchor.mouse.y
                if dragging || hypot(dx, dy) > Self.dragSlop {
                    dragging = true
                    setFrameOrigin(NSPoint(x: anchor.origin.x + dx,
                                           y: anchor.origin.y + dy))
                    // The press is carrying the window; the content must not also
                    // read it as a gesture of its own.
                    return
                }
            }
        case .leftMouseUp:
            let wasDragging = dragging
            dragging = false
            dragAnchor = nil
            if wasDragging { return }
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Did this press land on the card's own surface rather than on something
    /// that wants it?
    ///
    /// Asked as a deny-list, not an allow-list. The card's hierarchy is mostly
    /// SwiftUI, which backs almost nothing with an AppKit view — but not
    /// nothing: SwiftUI wraps every representable in a plain host view. Listing
    /// the views that DO count as glass silently turns each of those into a dead
    /// patch the window will not move from.
    ///
    /// What actually wants a press is narrow and nameable: something that edits
    /// text or acts as a control. The prompt field keeps its caret and its
    /// selection, the answer keeps its selectable text, and every other pixel —
    /// known or not — carries the window.
    private func pressIsOnBareGlass(_ event: NSEvent) -> Bool {
        guard let content = contentView else { return false }
        let point = content.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        guard let hit = content.hitTest(point) else { return true }
        // Up the chain, not just the leaf: a press inside a field's inner clip
        // view still belongs to the field.
        var view: NSView? = hit
        while let v = view, v !== content {
            if v is NSControl || v is NSText { return false }
            view = v.superview
        }
        return true
    }

    /// LSUIElement app: there is no menu-bar Close item to catch ⌘W, so the
    /// window answers the equivalent itself — same path as the close chip.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if closesOnEscape,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           event.charactersIgnoringModifiers == "\u{1b}" {
            close()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            close()
            return true
        }
        if onAppShortcut?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
