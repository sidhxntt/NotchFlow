import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
extension DetachedSessionWindowController {
    // MARK: Window construction

    func makeWindow(at rect: NSRect, model: NotchModel) {
        var rect = rect
        let composing = session == .compose
        var bareComposer = false
        if case .shortcutComposer = session { bareComposer = true }
        if composing || bareComposer {
            // A composer is just the input: born as a slab the height of the
            // prompt row, hanging from the same top edge the panel had, instead
            // of a session-sized window three-quarters empty. The prompt-shortcut
            // composer is shorter still — a badge over a capsule, nothing else.
            let h = bareComposer
                ? composerRestingHeight
                : DetachedComposeView.restingHeight
            rect = NSRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
        }
        let w = DetachedWindow(
            contentRect: rect,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = face.title
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = true
        w.isReleasedWhenClosed = false
        // OFF, and it has to be off. Left on, the WINDOW SERVER claims every
        // press that lands on a point whose view answers `mouseDownCanMoveWindow`
        // — which is the hosting view, i.e. all of the card's own glass — and
        // runs its background-drag itself. It then moves nothing, and the app
        // never sees the event at all (a global monitor catches those presses;
        // `sendEvent` does not). The only pixels that stayed alive were the ones
        // AppKit views cover — the input's recess and the two chips — which is
        // exactly the map of what could and couldn't be grabbed: the header row's
        // empty half, the card's padding, dead; the input capsule, fine.
        //
        // With it off, every press reaches `DetachedWindow.sendEvent`, which
        // carries the window by hand (see the note there).
        w.isMovableByWindowBackground = false
        w.appearance = NSAppearance(named: .darkAqua)
        w.closesOnEscape = compactShortcut
        w.onAppShortcut = { [weak self] event in
            self?.handleAppShortcut(event) ?? false
        }
        w.minSize = bareComposer
            ? Self.compactComposerMinSize
            : (compactShortcut ? Self.compactMinSize
                               : (composing ? Self.composeMinSize : Self.threadMinSize))
        // While being carried it floats above everything, like a piece of the
        // island in the hand. `finishSettle` drops it to its pinned level.
        w.level = .statusBar
        if compactShortcut {
            // The other half of "beside the pointer": a pointer-side window
            // belongs to wherever the user is working *now*, not to the Space it
            // happened to be born on. Without this, re-firing the shortcut on
            // another display drags the user back across Spaces to the old
            // window — or leaves it answering invisibly on the Space they left.
            // Torn-out session windows are the user's own and keep AppKit's
            // default (they stay put on their Space).
            w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        }

        // Thread actions read the store's threadID at CALL time (not capture
        // time): a regenerate can re-id the thread, and the store's key is
        // kept current by the model (`runDetachedRound`).
        let root = DetachedSessionRootView(
            state: state,
            model: model,
            onTogglePin: { [weak self] in self?.togglePin() },
            onClose: { [weak self] in self?.window.close() },
            onInAppCopy: { [weak self] in
                self?.model?.rebaselineClipboardAfterInAppWrite()
            },
            onReplaceOriginal: { [weak self] text in
                self?.replaceOriginalText(with: text) ?? false
            },
            onFollowUp: { [weak self] line, images in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.submitDetachedFollowUp(threadID: id, question: line,
                                                   images: images)
            },
            onRegenerate: { [weak self] in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.regenerateDetachedAnswer(threadID: id)
            },
            onRegenerateWith: { [weak self] pick in
                guard let self, let id = self.threadStore?.threadID else { return }
                self.model?.regenerateDetachedAnswer(threadID: id, model: pick)
            },
            onChooseOption: { [weak self] questionID, option in
                self?.model?.chooseUserOption(option, questionID: questionID)
            },
            regenerateOptions: { [weak self] in
                self?.model?.regenerateModelOptions ?? []
            },
            // Enter in the composer: the round runs headless through the panel
            // pipeline and this window becomes the thread it started.
            onCompose: { [weak self] line, destination in
                guard let self, let model = self.model else { return }
                if let threadID = model.submitDetachedCompose(line, destination: destination) {
                    self.adoptThread(threadID)
                }
            },
            onComposeHeight: { [weak self] h in self?.resizeComposer(to: h) },
            onCompactPrompt: { [weak self] line, pin in
                self?.submitCompactShortcutPrompt(line, pin: pin)
            },
            onToggleForceTouchHistory: { [weak self] in
                self?.toggleForceTouchHistory()
            },
            onOpenForceTouchHistory: { [weak self] id in
                self?.openForceTouchHistoryThread(id)
            },
            onCaretOffset: { [weak self] offset in self?.alignCaret(to: offset) },
            compactShortcut: compactShortcut,
            onThreadHeight: { [weak self] h in
                guard let self else { return }
                var quickActionsChanged = false
                if case .shortcutComposer = self.state.session {
                    let promptIsEmpty = self.state.compactPromptDraft
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    quickActionsChanged = promptIsEmpty != self.compactPromptWasEmpty
                    self.compactPromptWasEmpty = promptIsEmpty
                }
                let animated = self.animateForceTouchHistoryResize || quickActionsChanged
                self.animateForceTouchHistoryResize = false
                self.resizeCompactThread(to: h, animated: animated)
            })
            // This window's own edges are the wall its hover tooltips clamp to —
            // the island's coordinate space doesn't reach here.
            .notchTooltipClipBox()
        let hosting = NSHostingView(rootView: root)
        // This window's size is OURS, not SwiftUI's. Every height here is
        // computed by the controller (`resizeComposer`, `resizeCompactThread`,
        // `glideCompact`) and written with `setFrame` — often mid-animation,
        // many times a second.
        //
        // Left at its default, `NSHostingView` also claims that ownership: on
        // every constraints pass it re-derives the window's content min/max
        // extrema by measuring the SwiftUI content, and it resizes the window
        // itself from `windowDidLayout`. Those measurements dirty the very view
        // graph that produced them, so the invalidation lands INSIDE AppKit's
        // display cycle and `-[NSWindow _postWindowNeedsUpdateConstraints]`
        // throws:
        //
        //   "marked as needing another Update Constraints in Window pass, but it
        //    has already had more … passes than there are views in the window"
        //
        // Keeping single views out of the sizing path only dodges one
        // instance of it. Emptying `sizingOptions` stops the
        // content-derived constraints, and keeping the hosting view one level
        // below `NSWindow.contentView` also removes SwiftUI's window-size bridge.
        // (On macOS 27 that bridge can still run `updateAnimatedWindowSize` for a
        // direct content view even when its sizing options are empty.) The plain
        // AppKit container owns the window edge; SwiftUI only autoresizes inside
        // the frame the controller gives it.
        hosting.sizingOptions = []
        let container = NSView(frame: NSRect(origin: .zero,
                                             size: w.contentLayoutRect.size))
        container.autoresizesSubviews = true
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        w.contentView = container
        w.delegate = self
        window = w
        w.orderFrontRegardless()
    }

    /// Replace the selection that launched this compact shortcut. Paste is used
    /// instead of AX assignment because it works across native, browser and
    /// Electron editors. The user's clipboard is restored after the target has
    /// consumed it, unless somebody else changed it during that short interval.
    private func replaceOriginalText(with text: String) -> Bool {
        guard compactShortcut,
              !text.isEmpty,
              let application = replacementApplication,
              !application.isTerminated
        else { return false }

        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            return false
        }
        let replacementChangeCount = pasteboard.changeCount
        model?.rebaselineClipboardAfterInAppWrite()

        // Let the button render its confirmation before this unpinned utility
        // window yields focus back to the source app.
        DispatchQueue.main.async { [weak self] in
            guard application.activate() else {
                if pasteboard.changeCount == replacementChangeCount {
                    snapshot.restore(to: pasteboard)
                    self?.model?.rebaselineClipboardAfterInAppWrite()
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                Self.postPasteShortcut()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard pasteboard.changeCount == replacementChangeCount else { return }
                    snapshot.restore(to: pasteboard)
                    self?.model?.rebaselineClipboardAfterInAppWrite()
                }
            }
        }
        return true
    }

    private static func postPasteShortcut() {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: source,
                                 virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
              let up = CGEvent(keyboardEventSource: source,
                               virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func centeredDefaultRect() -> NSRect {
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        return NSRect(x: screen.midX - 320, y: screen.midY - 280,
                      width: 640, height: 560)
    }

    /// Where a pointer-side window is born — ONE answer for every one of them.
    ///
    /// Beside the pointer: its right side, flipped left when that would cross the
    /// display, with the top edge just above the cursor. A prompt shortcut firing
    /// straight into an answer already opened here; a force click's composer used
    /// to be placed by its CARET instead, so the box wrapped around the cursor
    /// and the two gestures dropped their windows in visibly different places.
    /// The shortcut's placement is the one that survived.
    ///
    /// Pinning the *top* edge is what keeps it true for the rest of the window's
    /// life — every compact resize hangs off that edge (`setCompactHeight`), so
    /// growing into the answer never moves the line the user typed on.
    ///
    /// It clamps to the usable screen frame. The display is `NSScreen.containing`
    /// — the app's single source of truth for "where is the mouse", so a chord
    /// fired at a screen seam or in the menu-bar row can't land the window on a
    /// different monitor.
    ///
    /// `size` lets an already-grown window be re-anchored without shrinking back
    /// to the opening size; it defaults to the size a fresh window is born at.
    func compactRect(near pointer: NSPoint, size: NSSize? = nil,
                             asComposer: Bool = false) -> NSRect {
        Self.pointerSideRect(
            near: pointer,
            size: size ?? NSSize(width: Self.compactWidth,
                                 height: asComposer
                                     ? composerRestingHeight
                                     : Self.compactInitialHeight))
    }

    /// The frame itself. Static and public to the module because
    /// `ForceClickHerald` has to land its pressure cue on the *same* geometry —
    /// including the clamp. Two places each doing their own version of this
    /// arithmetic is exactly how the cue and the box it becomes would drift apart
    /// at a screen edge.
    static func pointerSideRect(near pointer: NSPoint, size: NSSize? = nil) -> NSRect {
        let visible = NSScreen.containing(pointer)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(size?.width ?? compactWidth, visible.width - screenMargin * 2)
        let height = size?.height ?? compactInitialHeight
        let rightX = pointer.x + pointerGap
        let leftX = pointer.x - pointerGap - width
        let x = rightX + width <= visible.maxX - screenMargin ? rightX : leftX
        let box = NSSize(width: width, height: height)
        return NSRect(origin: clamped(origin: NSPoint(x: x, y: pointer.y + 18 - height),
                                      size: box, in: visible),
                      size: box)
    }

    /// The composer's own frame at that placement — the same box, at the height a
    /// resting one-line composer is born.
    static func composerWindowRect(near pointer: NSPoint,
                                   size: NSSize? = nil) -> NSRect {
        pointerSideRect(near: pointer,
                        size: size ?? NSSize(width: compactWidth,
                                             height: CompactShortcutPromptView.restingHeight))
    }

    /// The input capsule's own screen rect inside that window — what the pressure
    /// cue grows into, and what it must be indistinguishable from at handoff.
    static func composerCapsuleRect(near pointer: NSPoint) -> NSRect {
        let window = composerWindowRect(near: pointer)
        let inset = CompactShortcutMetrics.inset
        let height = CompactShortcutMetrics.capDiameter
        return NSRect(x: window.minX + inset,
                      y: window.maxY - CompactShortcutMetrics.caretOffset.y - height / 2,
                      width: window.width - inset * 2,
                      height: height)
    }

    /// The composer just told us where its caret really is. Remember it for the next
    /// press (and for the pressure cue), then slide this window so the caret sits on
    /// the pointer that summoned it — the opening estimate is corrected inside the
    /// entrance, before there is anything to see.
    private func alignCaret(to offset: CGPoint) {
        // Remembered, not acted on. The offset still says where the input
        // capsule sits INSIDE the window, which is what the pressure cue scales
        // about (`drawPressure`) — but the window is no longer placed by it. It
        // opens beside the pointer like every other pointer-side window
        // (`pointerSideRect`), so sliding it afterwards to put the caret back
        // under the cursor would undo exactly that.
        CompactShortcutMetrics.rememberCaret(offset)
    }

    /// A window origin pulled back inside `visible`, keeping `screenMargin` clear
    /// on every edge. The single definition of "don't touch the sides" for the
    /// pointer-side windows — placement, the caret nudge and every resize go
    /// through it, so they cannot disagree about where the edge is.
    ///
    /// A display too small to hold the window with its margins keeps the leading
    /// and top edges rather than centring it: an overflowing box is better cut
    /// off where nothing is written than in the middle of the line.
    static func clamped(origin: NSPoint, size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, visible.minX + screenMargin),
                   max(visible.minX + screenMargin,
                       visible.maxX - screenMargin - size.width)),
            y: min(max(origin.y, visible.minY + screenMargin),
                   max(visible.minY + screenMargin,
                       visible.maxY - screenMargin - size.height)))
    }

    /// Where the entrance grows from: the pointer itself, expressed as a unit
    /// point in the window's own frame.
    ///
    /// A caret-placed composer holds the pointer *inside* it, so a corner anchor
    /// would swell the box out of a corner the user isn't looking at — it has to
    /// open from the caret. An answer window sits beside the pointer, which is
    /// outside its frame, so the clamp lands it on the leading or trailing edge
    /// exactly as the old corner test did.
    func anchorEntrance(rect: NSRect, pointer: NSPoint) {
        guard rect.width > 0, rect.height > 0 else {
            state.entranceAnchor = .topLeading
            return
        }
        state.entranceAnchor = UnitPoint(
            x: min(max((pointer.x - rect.minX) / rect.width, 0), 1),
            y: min(max((rect.maxY - pointer.y) / rect.height, 0), 1))
    }

    /// The pointer-side opening: the window fades up while its content swells
    /// out of the pointer corner (`DetachedSessionRootView.playEntrance`) — one
    /// move, not a fade followed by a settle.
    ///
    /// AppKit derives a borderless window's shadow from the drawn silhouette and
    /// caches it, so a shadow sampled mid-growth would stay a size too small for
    /// the rest of the window's life — it's re-derived once the spring is done.
    func playPointerEntrance() {
        guard !Self.reduceMotion else {
            window.alphaValue = 1
            return
        }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak window] in
            window?.invalidateShadow()
        }
    }

    /// A pointer-side window is *defined* by the pointer that summoned it, so a
    /// fresh invocation brings it to where the user is working NOW — even on the
    /// same display. Nothing closes these on focus loss: an unpinned one just
    /// drops behind the app in front, which reads as dismissed. Re-firing it then
    /// used to raise it back at its old spot, a screen away from the selection
    /// that summoned it.
    ///
    /// Two cases keep the window exactly where it is:
    ///   · it's PINNED — the tack means "keep this where I put it";
    ///   · the pointer is already at the window (a re-fire in place), so moving
    ///     it would only nudge a window the user is looking straight at.
    ///
    /// `asComposer` is passed rather than read off `state.session`: a re-fire
    /// re-anchors BEFORE the session is put back to its composer face, so the
    /// state would still say "thread" and place the window by the wrong rule.
    func reanchorForInvocation(near pointer: NSPoint, asComposer: Bool) {
        guard NSScreen.containing(pointer) != nil else { return }
        let sameDisplay = window.screen?.displayID == NSScreen.containing(pointer)?.displayID
        if window.isVisible, sameDisplay {
            if state.pinned { return }
            // "At the window" = inside it, or within the gap it was placed at.
            let reach = Self.pointerGap * 2
            if window.frame.insetBy(dx: -reach, dy: -reach).contains(pointer) { return }
        }
        // It moved to a new selection, so it *arrives* there: same entrance as a
        // fresh window, replayed in place of a teleport. (The early returns above
        // — pinned, or already under the pointer — leave it alone, and with it
        // the entrance.)
        let target = compactRect(near: pointer, size: window.frame.size,
                                 asComposer: asComposer)
        window.setFrame(target, display: true)
        anchorEntrance(rect: target, pointer: pointer)
        if !Self.reduceMotion {
            state.entranceToken += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak window] in
                window?.invalidateShadow()
            }
        }
    }
}
