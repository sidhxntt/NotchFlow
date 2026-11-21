import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
extension DetachedSessionWindowController {
    /// The same prompt shortcut fired again: keep this exact NSWindow and replace
    /// only the live thread it observes. The prior round is cancelled, the shell
    /// returns to its waiting height, and the new answer grows it in place.
    func replaceCompactThread(with threadID: UUID, title: String,
                                      near pointer: NSPoint,
                                      sourceApplication: NSRunningApplication?) {
        guard compactShortcut, let model else { return }
        // Before any resize: the height clamps below measure against the frame,
        // so the window must already be on the display it's going to keep.
        summonPointer = nil
        setCompactWidth(Self.compactWidth)
        reanchorForInvocation(near: pointer, asComposer: false)
        if let oldStore = threadStore, oldStore.threadID != threadID {
            model.cancelCompactRound(threadID: oldStore.threadID)
            model.releaseDetachedThread(oldStore.threadID)
        }
        state.threadStore = model.adoptDetachedThread(threadID)
        state.session = .thread(id: threadID)
        // A shortcut that opens straight into an answer IS an arrival: it plays
        // the pointer entrance, unlike the capsule growing into its own card.
        state.openingFromComposer = false
        state.compactFaceDrills = false
        replacementApplication = sourceApplication
        window.title = title
        window.minSize = Self.compactMinSize
        // A fresh round with no composer behind it waits at the card again.
        compactFloorHeight = Self.compactInitialHeight
        resizeCompactThread(to: Self.compactInitialHeight, reset: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        armSummonGrace()
    }

    /// Reusing the same empty-prompt shortcut replaces both pieces of transient
    /// state: the captured selection and any draft left in the field. If its
    /// previous invocation was still generating, that obsolete round is stopped
    /// before this window returns to its one-line composer face.
    func replaceCompactComposer(selectedText: String,
                                        near pointer: NSPoint,
                                        sourceApplication: NSRunningApplication?,
                                        forceTouch: Bool) {
        guard compactShortcut, let model, let shortcutID = compactShortcutID else { return }
        summonPointer = pointer
        state.grownIn = ForceClickHerald.shared.isPresenting
        // Narrow again first: the re-anchor below places the window by the size
        // it is holding, so an answer's width would land the caret off the
        // pointer that summoned it.
        setCompactWidth(Self.composerWidth)
        reanchorForInvocation(near: pointer, asComposer: true)
        if let oldStore = threadStore {
            // Force Touch is another independent Ask, not a replacement for the
            // one already running. Match main-flow new-chat behavior: detach the
            // old round so it can finish into Recent instead of cancelling it.
            if forceTouch || state.forceTouchInvocation {
                model.detachCompactRound(threadID: oldStore.threadID)
            } else {
                model.cancelCompactRound(threadID: oldStore.threadID)
            }
            model.releaseDetachedThread(oldStore.threadID)
        }
        state.threadStore = nil
        state.compactSourceText = selectedText
        state.forceTouchInvocation = forceTouch
        state.forceTouchHistoryExpanded = false
        state.compactPromptDraft = ""
        compactPromptWasEmpty = true
        state.compactPromptGeneration += 1
        state.openingFromComposer = false
        state.compactFaceDrills = false
        state.session = .shortcutComposer(id: shortcutID)
        replacementApplication = sourceApplication
        window.title = L("shortcuts.promptAction.window.context")
        // Back to the capsule: drop the answer floor first, or AppKit clamps the
        // window at the taller size it was holding as a result view.
        window.minSize = Self.compactComposerMinSize
        compactFloorHeight = Self.compactInitialHeight
        resizeCompactThread(to: composerRestingHeight, reset: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        armSummonGrace()
        // The capsule the press stretched IS this window's capsule, so there is no
        // cue to take off screen — only the herald's bookkeeping to let go of.
        if state.grownIn { ForceClickHerald.shared.handOff() }
    }

    /// The transient instruction now has everything it needs. Start the same
    /// headless prompt-shortcut round as a saved instruction and let this exact
    /// compact window become its live result view in place.
    func submitCompactShortcutPrompt(_ prompt: String, pin: ModelPin? = nil) {
        guard compactShortcut,
              case .shortcutComposer = state.session,
              let model,
              let threadID = model.startPromptShortcutRound(
                prompt: prompt, selectedText: state.compactSourceText, pin: pin,
                origin: state.forceTouchInvocation ? .forceTouch : nil)
        else { return }
        // The line stays in the capsule while the capsule dissolves: clearing it
        // here brought the placeholder ("What should I do with it?") flashing
        // back for the length of the fade. The next invocation resets the draft
        // (`replaceCompactComposer`), and this face is leaving regardless.
        state.threadStore = model.adoptDetachedThread(threadID)
        // Everything below changes what the card holds AND how tall it is, in one
        // turn — so the reveal's mask has to be on the card before any of it runs
        // (see `withCompactRevealArmed`). Arming it costs a frame in which the
        // composer is unchanged, which is nothing to look at.
        withCompactRevealArmed { [weak self] in
            self?.openCompactAnswer(threadID: threadID)
        }
    }

    /// The second half of `submitCompactShortcutPrompt`, run once the reveal mask
    /// is live: the capsule's contents become the card's, and the window opens
    /// down to the waiting height.
    private func openCompactAnswer(threadID: UUID) {
        guard window != nil else { return }
        // The card takes over the box in place — it does not arrive from
        // anywhere (`DetachedSessionRootView.compactShortcutFace`), and it does
        // not dissolve into anything either: this is the morph, not navigation.
        state.openingFromComposer = true
        state.compactFaceDrills = false
        // Unanimated, like the two navigation paths: the growth this face needs
        // is the reveal mask's, which springs on its own, and the contents cross
        // over on their own numbers. An ambient animation here has nothing left
        // to do except spring the LAYOUT — every mark in the card sliding from
        // where it sat in the capsule to where it sits in the answer — which is
        // the opposite of the box simply opening.
        state.session = .thread(id: threadID)
        window.minSize = Self.compactMinSize
        // Enter opens the capsule into the waiting card, once, and the window
        // then holds there for the whole wait — the answer's arrival grows it
        // from that floor in one continuous glide (`resizeCompactThread`).
        //
        // It used to freeze at exactly the capsule's height so Enter moved
        // nothing at all. That only worked while the answer face was a bare
        // slab: it now carries the same header and follow-up line every other
        // detached thread does, and a capsule-height window would clip both.
        //
        // That growth is GLIDED, not set: a hard `setFrame` from the one-line
        // capsule to the waiting card is a cut, and a cut is what makes the card
        // read as a new dialog rather than the same box opening.
        // The card the user typed in does NOT resize to think: it holds the
        // exact height it already has after its quick actions have folded, and
        // only the answer grows it from there. Dropping to the waiting card's own
        // floor shrank the box under the line just submitted, which is a window closing and
        // another opening, not a card filling in.
        //
        // The BOX, though — not the drawer under it. An open History ledger is
        // hung below the input and leaves with the composer's face, so its rows
        // must come off this measurement first. Left in, they became the answer's
        // floor (`resizeCompactThread` never goes below it), and a one-line reply
        // submitted from an open ledger opened a card as tall as the whole recent
        // list, its answer stranded at the top of a void.
        compactFloorHeight = max(composerHeightWithoutLedger(),
                                 Self.compactInitialHeight)
        // The box the user typed in opens DOWNWARD and nothing else: same width,
        // same top edge, same left edge. It used to widen to the answer's
        // reading box (`compactWidth`) on the way, which moved the trailing edge
        // — and, at a screen edge, the whole window — out from under the line
        // the user had just pressed Enter on. One axis moves, and it is the one
        // the answer is arriving on.
        resizeCompactThread(to: compactFloorHeight, reset: true, animated: true)
    }

    /// The window's height with the History drawer's rows discounted — what the
    /// composer alone occupies. Equal to the frame while the ledger is folded.
    private func composerHeightWithoutLedger() -> CGFloat {
        guard state.forceTouchHistoryExpanded else { return window.frame.height }
        let ledger = CompactShortcutPromptView.historyBlock(
            model?.forceTouchHistory.count ?? 0)
        return max(window.frame.height - ledger, 0)
    }

    /// Keep History inside the pointer-side shell. From the composer the clock
    /// unfolds its private ledger below the input; from a result it returns this
    /// same window to that expanded ledger.
    func toggleForceTouchHistory() {
        guard compactShortcut, state.forceTouchInvocation else { return }
        if case .shortcutComposer = state.session {
            // Arm the disclosure's mask BEFORE the ledger changes size, so the
            // measurement it triggers can resize the window in the same turn it
            // arrives (see `withCompactRevealArmed`).
            withCompactRevealArmed { [weak self] in
                guard let self else { return }
                self.animateForceTouchHistoryResize = true
                self.state.forceTouchHistoryExpanded.toggle()
            }
            return
        }

        if let oldStore = threadStore {
            model?.releaseDetachedThread(oldStore.threadID)
        }
        state.threadStore = nil
        state.compactPromptDraft = ""
        compactPromptWasEmpty = true
        state.compactPromptGeneration += 1
        // Back is a SET, not a disclosure — so nothing here arms the reveal.
        animateForceTouchHistoryResize = false
        state.forceTouchHistoryExpanded = true
        state.openingFromComposer = false
        // …but it IS the ledger coming back, so it dissolves in the way it
        // dissolved out (`compactFaceTransition`).
        state.compactFaceDrills = true
        window.minSize = Self.compactComposerMinSize
        // NOT wrapped in `withAnimation`, and that is the whole point.
        //
        // The window's new height is a `setFrame` — instant, and the NSWindow
        // frame is provably never in motion here (measured at 120Hz: it goes to
        // its new value on the first tick and never moves again). But SwiftUI
        // lays the face out INSIDE that window, so the resize shows up as a
        // layout change on the very next update pass — and if that pass is
        // carrying an animation, SwiftUI springs the whole face from the old
        // geometry to the new one. Measured on the way back out of a
        // conversation, with the window stock still the entire time: the card
        // dropped 117px in one frame, sat there for three, then travelled back
        // up over ~270ms while growing. That is the jump — not the window, the
        // layout of the face inside it.
        //
        // So nothing here opens an animated transaction. The cross-fade does not
        // need one: `compactFaceTransition` declares its own animations, which
        // is what makes a transition play on an unanimated change.
        state.session = .shortcutComposer(
            id: compactShortcutID ?? SelectedTextShortcutStore.actionID)
        // The mirror of `openForceTouchHistoryThread`: the window knows how tall
        // the composer is before that face mounts — the draft was just cleared, so
        // it is one line, and the ledger below it is the same rows it always had —
        // so it lands there in ONE set and the cross-fade carries the change.
        //
        // Routed through the disclosure's reveal mask (what it used to do), the
        // return settled its top TWICE: the mask is top-anchored and holds the
        // window at the ANSWER's height for the whole collapse, laying the
        // composer out inside that tall frame, and the face then re-measured
        // itself on mount — a second, un-animated height report that cancelled the
        // reveal mid-flight and hard-set the frame. That is the jump-and-return
        // on the way back.
        let hasSelection = !state.compactSourceText
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        resizeCompactThread(
            to: CompactShortcutPromptView.expandedHeight(
                withPicks: hasSelection,
                historyCount: model?.forceTouchHistory.count ?? 0),
            reset: true,
            animated: false)
    }

    /// Replace the drawer with a saved Force Touch conversation without creating
    /// or activating another window.
    func openForceTouchHistoryThread(_ threadID: UUID) {
        guard compactShortcut, state.forceTouchInvocation, let model else { return }
        let store = model.adoptDetachedThread(threadID)
        state.threadStore = store
        // The ledger stays logically OPEN behind the conversation. Folding it
        // here re-measured the composer — still the live face for another beat —
        // as a collapsed one-line box, and that report was honoured: the window
        // slammed 379 → 147 → the card's own height inside 10ms, which is the
        // blink on opening an entry. Nothing reads the flag while a thread is up,
        // and Back sets it true again regardless, so there is nothing to fold.
        state.openingFromComposer = true
        // Forward through the ledger: the two faces cross-fade into each other
        // rather than staggering (`compactFaceTransition`).
        state.compactFaceDrills = true
        window.minSize = Self.compactMinSize
        compactFloorHeight = Self.compactInitialHeight
        // Unanimated, for the reason spelled out in `toggleForceTouchHistory`:
        // the window's height lands in one set, and an animated transaction here
        // would have SwiftUI spring the whole face's layout to meet it.
        state.session = .thread(id: threadID)
        // A saved thread is already written, so the window knows how tall it has
        // to be before the face mounts — open it AT that height in one move. It
        // used to open at the waiting card's floor and let the mounted view grow
        // it back out, which took the disclosure's own 0.7s reveal to hand the
        // answer over (the visible "a beat late"), and a longer answer's growth
        // landed mid-reveal only to be shrunk away again by that reveal's
        // completion — leaving a window too short to show the answer at all.
        //
        // And it lands in ONE set, not through the disclosure's reveal mask. That
        // mask is top-anchored: while it runs, the card is laid out at the OLD
        // frame's height, so everything the slab hangs off its bottom edge — the
        // action row, the follow-up capsule — sits below the mask's edge and only
        // snaps in when the frame is finally committed. The face swap already
        // cross-fades (`compactFaceContent`); the window simply arrives at the
        // size that face needs, with all of it visible at once.
        let answer = store.turns.last(where: { $0.role == "assistant" })?.text ?? ""
        let opening = max(Self.compactInitialHeight,
                          DetachedThreadView.estimatedCompactWindowHeight(for: answer))
        resizeCompactThread(to: opening, reset: true, animated: false)
    }

    /// The composer sent its first question: this window IS that thread now.
    /// Re-key it, adopt the round's live mirror, and let the root view swap the
    /// composer for the conversation — same window, in place, no second window
    /// and no trip back through the notch.
    func adoptThread(_ threadID: UUID) {
        guard let model, state.session == .compose else { return }
        let store = model.adoptDetachedThread(threadID)
        state.threadStore = store
        withAnimation(Self.reduceMotion ? nil : .easeOut(duration: 0.2)) {
            state.session = .thread(id: threadID)
        }
        growIntoThread()
    }

    /// A composer is a short window (it holds one input line); the conversation
    /// it just became needs room to write. Grow downward from the same top edge
    /// so the box the user typed in doesn't move under their eyes.
    private func growIntoThread() {
        let frame = window.frame
        let target = Self.threadWindowSize
        guard frame.height < target.height || frame.width < target.width else { return }
        var grown = NSRect(x: frame.minX, y: frame.maxY - max(frame.height, target.height),
                           width: max(frame.width, target.width),
                           height: max(frame.height, target.height))
        if let visible = window.screen?.visibleFrame {
            grown.origin = Self.clamped(origin: grown.origin, size: grown.size, in: visible)
        }
        window.minSize = Self.threadMinSize
        if Self.reduceMotion {
            window.setFrame(grown, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.24
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(grown, display: true)
            }
        }
    }

    /// The draft wrapped (or a save cue appeared / cleared): grow or shrink the
    /// slab from its BOTTOM edge, so the box the user is typing in never moves.
    /// Composer only — once it's a thread the window is the user's to size.
    func resizeComposer(to height: CGFloat) {
        guard state.session == .compose, window != nil else { return }
        let frame = window.frame
        guard abs(frame.height - height) > 0.5 else { return }
        var target = NSRect(x: frame.minX, y: frame.maxY - height,
                            width: frame.width, height: height)
        if let visible = window.screen?.visibleFrame {
            target.origin = Self.clamped(origin: target.origin, size: target.size,
                                         in: visible)
        }
        window.setFrame(target, display: true, animate: false)
    }

    /// Follow a compact answer's intrinsic height. Keep the top edge fixed while
    /// there is room below; at a screen edge the window shifts just enough to stay
    /// wholly visible. Past the cap, the thread's ScrollView takes over.
    func resizeCompactThread(to desiredHeight: CGFloat, reset: Bool = false,
                                     animated: Bool = false) {
        guard compactShortcut, window != nil else { return }
        let frame = window.frame
        let visible = window.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        let screenCap = visible.map { $0.height * 0.65 } ?? Self.compactMaxHeight
        // The bare composer is exactly as tall as its badge + capsule — far
        // shorter than any answer, and it must SHRINK again when a wrapped draft
        // is deleted, so it takes neither the answer floor nor the growth-only
        // hysteresis below.
        var bareComposer = false
        if case .shortcutComposer = state.session { bareComposer = true }
        // A round's floor is wherever it STARTED: a shortcut that opened straight
        // into an answer starts at the waiting card, one that grew out of a
        // composer keeps the composer's own height, so the wait never moves the
        // window (`submitCompactShortcutPrompt`).
        let floor = bareComposer
            ? CompactShortcutPromptView.restingHeight
            : compactFloorHeight
        let measured = min(max(desiredHeight, floor),
                           min(Self.compactMaxHeight, screenCap))
        if reset || bareComposer {
            compactRoundHeight = measured
            guard abs(frame.height - measured) > 0.5 else {
                stopCompactGlide()
                // A collapse keeps the NSWindow at its expanded height until the
                // reveal mask finishes. If the user re-opens History during that
                // interval, the requested height therefore already matches the
                // window even though the mask is still closing. Retarget that
                // reveal instead of returning and letting the stale collapse
                // completion shrink an expanded drawer underneath SwiftUI.
                if animated && !Self.reduceMotion,
                   (compactRevealCompletion != nil || state.compactRevealHeight != nil) {
                    animateCompactHeight(to: measured)
                }
                return
            }
            // Discrete composer changes reveal through one top-anchored mask.
            // Streaming answers still use the re-targetable glide below.
            if animated && !Self.reduceMotion {
                animateCompactHeight(to: measured)
            } else {
                stopCompactGlide()
                cancelCompactReveal()
                setCompactHeight(measured)
            }
            return
        }
        // Same hysteresis as the prompt editor's IME fix: growth is real and
        // immediate; a lower intermediate measurement is not. The floor is
        // deliberately reset only when this shortcut starts a new round.
        guard measured > compactRoundHeight + 0.5 else { return }
        compactRoundHeight = measured
        // A disclosure reveal in flight OWNS this window's height: it masks the
        // card to its own animating height and commits its target frame when it
        // finishes. Gliding underneath it draws the extra height behind that mask
        // and then loses it to the stale commit — and the growth-only hysteresis
        // above never asks again, so the answer stays clipped for good (this is
        // what left a reopened thread showing its toolbar over an empty card).
        // Re-aim the reveal instead.
        if compactRevealCompletion != nil || state.compactRevealHeight != nil {
            animateCompactHeight(to: measured)
            return
        }
        guard !Self.reduceMotion else {
            setCompactHeight(measured)
            return
        }
        glideCompact(to: measured)
    }

    /// Drop any disclosure reveal still in flight. A hard set owns this window's
    /// height outright, so a reveal left running would keep masking the card to a
    /// stale height and then commit a stale frame when it finished.
    private func cancelCompactReveal() {
        compactRevealGeneration += 1
        compactRevealCompletion?.cancel()
        compactRevealCompletion = nil
        state.onRevealArmed = nil
        guard state.compactRevealHeight != nil else { return }
        withAnimation(nil) { state.compactRevealHeight = nil }
    }

    /// Put the compact window at `height`, hanging from its own top edge and
    /// nudged back inside the screen at the bottom. Every compact resize — the
    /// hard sets and every frame of the glide — goes through here.
    private func setCompactHeight(_ height: CGFloat, width: CGFloat? = nil,
                                  reshadow: Bool = true) {
        guard window != nil else { return }
        let target = compactFrame(height: height, width: width)
        window.setFrame(target, display: true, animate: false)
        // The window's silhouette is its own glass, not its rect (the action pill
        // leaves a transparent band above the card), so AppKit has to re-derive
        // the shadow from what's drawn. Re-deriving it costs real work, so the
        // glide only asks for it every few frames (and always on its last one).
        if reshadow { window.invalidateShadow() }
    }

    /// The target frame shared by hard sets, streaming glides, and the one-shot
    /// History disclosure. Its top edge stays fixed whenever the screen allows.
    private func compactFrame(height: CGFloat, width: CGFloat? = nil) -> NSRect {
        let frame = window.frame
        var target = NSRect(x: frame.minX, y: frame.maxY - height,
                            width: width ?? frame.width, height: height)
        let visible = window.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
        // Growing downward walks the bottom edge into the dock, and a window
        // summoned near a side may already be sitting against one.
        if let visible {
            target.origin = Self.clamped(origin: target.origin, size: target.size,
                                         in: visible)
        }
        return target
    }

    /// A discrete compact resize is revealed inside a stationary top edge.
    ///
    /// Driving `NSWindow.setFrame` on every animation frame made the glass and
    /// its shadow re-layout independently of SwiftUI. Even with a mathematically
    /// fixed `maxY`, that redraw made the top border visibly tremble. Grow the
    /// window once, then animate only a top-aligned mask; for a collapse, shrink
    /// the mask first and commit the smaller window frame when it has finished.
    private func animateCompactHeight(to height: CGFloat) {
        stopCompactGlide()
        let revealInFlight = state.compactRevealHeight != nil
        compactRevealCompletion?.cancel()
        compactRevealGeneration += 1

        let start = window.frame
        let scale = window.backingScaleFactor
        let fixedTop = (start.maxY * scale).rounded() / scale
        let targetHeight = (height * scale).rounded() / scale
        let target = NSRect(x: start.minX,
                            y: fixedTop - targetHeight,
                            width: start.width,
                            height: targetHeight)
        let expanding = targetHeight > start.height + 0.5
        let generation = compactRevealGeneration
        let duration = Self.reduceMotion ? 0.22 : CompactHistoryMotion.settleDuration
        let revealAnimation: Animation = Self.reduceMotion
            ? .easeOut(duration: duration)
            : CompactHistoryMotion.spring

        // Install the mask before the host is allowed to take the larger size,
        // otherwise one unmasked final-size frame can flash between the two. An
        // interrupted reveal already has a live presentation value: preserve it
        // so another click reverses the spring from where it visibly is instead
        // of snapping back to the old endpoint first.
        if !revealInFlight {
            withAnimation(nil) {
                state.compactRevealHeight = start.height
            }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        // Safe to take the larger size right here: every discrete resize enters
        // through `withCompactRevealArmed`, so the mask above is already drawn by
        // the time this runs.
        if expanding {
            window.setFrame(target, display: true, animate: false)
        }

        // Landing the window on the smaller frame: the reveal owns the height
        // until it finishes, and this is what hands it back. Runs exactly once —
        // whichever of the two paths below gets here first.
        var committed = false
        let commit: () -> Void = { [weak self] in
            guard let self, !committed, self.window != nil,
                  self.compactRevealGeneration == generation else { return }
            committed = true
            if targetHeight < self.window.frame.height - 0.5 {
                self.window.setFrame(target, display: true, animate: false)
            }
            withAnimation(nil) {
                self.state.compactRevealHeight = nil
            }
            self.window.invalidateShadow()
            self.compactRevealCompletion = nil
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.compactRevealGeneration == generation else { return }
            // The commit rides the reveal's OWN completion, not a stopwatch. A
            // fixed delay had to be padded past the underdamped spring's settle
            // to be safe, which left the card folded and the window — its glass
            // and its shadow — still standing at the old height for the padding,
            // then snapping down a beat later. `.logicallyComplete` fires when the
            // spring has reached its value rather than when its last ripple is
            // retired, so the frame lands with the fold instead of after it.
            withAnimation(revealAnimation, completionCriteria: .logicallyComplete) {
                self.state.compactRevealHeight = targetHeight
            } completion: {
                commit()
            }
        }

        // Backstop only. If the reveal never reports (its view left the tree
        // mid-flight), the window would otherwise keep the reveal's height for
        // good. Deliberately later than the animation so the completion above is
        // what normally lands the frame.
        let completion = DispatchWorkItem(block: commit)
        compactRevealCompletion = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.25,
                                      execute: completion)
    }

    /// Put the reveal mask on the card at the height it ALREADY has — visually a
    /// no-op — and run `body` only once the face has actually drawn it. Every
    /// discrete compact resize is entered through here.
    ///
    /// The mask is published state: setting it does not draw anything, it
    /// schedules SwiftUI's next update, and that update lands whole frames later.
    /// Both ways of ignoring that are visible on screen:
    ///
    ///   · resize the window first (what this used to do) and the card is
    ///     presented at its FINAL size with no mask on it for 2-3 frames, then
    ///     snapped back to the old height for the reveal to play from — the
    ///     flash on entering an answer;
    ///   · defer only the `setFrame`, and the face — already laid out for the
    ///     new content — spends those frames squeezed into a window that is
    ///     still too small, which is a jump at the card's top edge.
    ///
    /// Arming at the height the card already has is free: the mask cuts exactly
    /// where the card already ends, so the wait costs nothing on screen. Once it
    /// is drawn, the content change, the measurement it triggers and the
    /// `setFrame` that follows can all stay in one synchronous turn.
    private func withCompactRevealArmed(_ body: @escaping () -> Void) {
        guard !Self.reduceMotion, window != nil,
              state.compactRevealHeight == nil else { return body() }
        withAnimation(nil) { state.compactRevealHeight = window.frame.height }
        let armedGeneration = compactRevealGeneration
        var ran = false
        let run: () -> Void = { [weak self] in
            guard !ran else { return }
            ran = true
            self?.state.onRevealArmed = nil
            body()
            // The mask is only ever meant to be handed straight to a reveal. If
            // the change turned out not to resize anything, no `animateCompactHeight`
            // follows to take it off again — and a mask left standing at a stale
            // height clips every later growth, which is how an answer ends up
            // permanently cut off. Take it back.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let self, self.compactRevealGeneration == armedGeneration,
                      self.state.compactRevealHeight != nil else { return }
                withAnimation(nil) { self.state.compactRevealHeight = nil }
            }
        }
        state.onRevealArmed = run
        // A face that never draws (the window closing mid-flight) must not
        // swallow the change it was gating.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: run)
    }

    /// Open the window down to `height` as ONE continuous move.
    ///
    /// An answer doesn't arrive at a height, it arrives at thirty of them — a
    /// chunk of Markdown at a time. Animating each report separately (the old
    /// 0.18s ease-out per geometry change) restarts the deceleration on every
    /// chunk, which is what made the expansion read as a stutter of little
    /// lurches instead of one shot. So the target is just re-aimed while the
    /// window is already moving: a critically-damped glide chases whatever the
    /// latest target is at whatever speed it currently has, and stops once —
    /// when the answer stops growing.
    private func glideCompact(to height: CGFloat) {
        compactTargetHeight = height
        guard compactGlideTimer == nil else { return }  // already moving: re-aimed
        compactGlideAt = ProcessInfo.processInfo.systemUptime
        var frame = 0
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self, self.window != nil else { timer.invalidate(); return }
            let now = ProcessInfo.processInfo.systemUptime
            // Clamped so a stalled run loop can't teleport the window.
            let dt = min(max(now - self.compactGlideAt, 1.0 / 240.0), 1.0 / 20.0)
            self.compactGlideAt = now
            let ease = 1 - exp(-dt / Self.compactGlideTau)
            let current = self.window.frame.height
            var next = current + (self.compactTargetHeight - current) * ease
            let done = abs(self.compactTargetHeight - next) < 0.5
            if done { next = self.compactTargetHeight }
            frame += 1
            self.setCompactHeight(next, reshadow: done || frame % 6 == 0)
            if done { self.stopCompactGlide() }
        }
        RunLoop.main.add(timer, forMode: .common)
        compactGlideTimer = timer
    }

    func stopCompactGlide() {
        compactGlideTimer?.invalidate()
        compactGlideTimer = nil
    }

    /// Put the window at `width` now, without animating — the path back from an
    /// answer to a composer, where nothing else is moving either.
    private func setCompactWidth(_ width: CGFloat) {
        guard window != nil, abs(window.frame.width - width) > 0.5 else { return }
        var frame = window.frame
        frame.size.width = width
        if let visible = window.screen?.visibleFrame {
            frame.origin = Self.clamped(origin: frame.origin, size: frame.size, in: visible)
        }
        window.setFrame(frame, display: true)
    }

    /// The glide's time constant: ~63% of the remaining distance per 0.1s, so a
    /// short answer opens in about a quarter second and a long one keeps opening
    /// at the same pace it's already moving at.
    private static let compactGlideTau: Double = 0.1

    /// A settled session window's working size, and the floor it may be dragged
    /// down to. A composer opens far shorter than this (see `makeWindow`).
    private static let threadWindowSize = NSSize(width: 560, height: 460)
    static let threadMinSize = NSSize(width: 420, height: 320)
    /// Kept BELOW the composer's resting height — a floor above it would have
    /// AppKit inflate the window the moment it's created.
    static let composeMinSize = NSSize(width: 380, height: 96)
    /// ONE width for every pointer-side window: the box the user types in, and
    /// the answer it becomes — a prompt shortcut firing straight into a card
    /// included. They are the same window, so they are the same width.
    ///
    /// It used to be two numbers, 330 for the composer and 410 for the answer,
    /// with Enter widening the box between them. 410 is wider than a card
    /// summoned at the pointer wants to be, 330 is tight for prose, and the
    /// widening was a moving edge under the line the user had just typed. This
    /// sits between them.
    static let compactWidth: CGFloat = 370
    /// The composer is that same box before it has anything to say.
    static let composerWidth: CGFloat = compactWidth
    /// The waiting card — what an answer window is before a word has landed: the
    /// window chrome an answered card carries (margins, header, follow-up row),
    /// its own top/bottom padding, the resting gaps the one orb row rests
    /// between, and that row. A single line never scrolls, so it wears the
    /// resting rhythm rather than the runways (`DetachedThreadView`) — budgeting
    /// two 28pt runways for it opened the wait 38pt taller than the card it
    /// becomes and left the orb floating in the middle of an empty box.
    static let compactInitialHeight: CGFloat =
        CompactShortcutMetrics.answerChrome
            + DetachedThreadView.compactCardPadding * 2
            + DetachedThreadView.restingTopGap + DetachedThreadView.restingBottomGap + 26
    static let compactMaxHeight: CGFloat = 520
    /// Kept at or below `compactWidth` — a compact composer opens into its
    /// answer at its OWN width now, and a floor wider than that is a floor
    /// AppKit widens the window through the instant the answer face sets it.
    static let compactMinSize = NSSize(width: 300, height: 96)
    /// The bare prompt-shortcut composer is shorter than any answer window, so
    /// it carries its own floor — the shared one would have AppKit inflate it
    /// back into a half-empty slab the moment it's created.
    /// Kept below `compactWidth` on BOTH axes — a floor wider than the composer
    /// is a floor AppKit inflates it back through the moment it is created.
    static let compactComposerMinSize = NSSize(width: 300, height: 60)
    static let pointerGap: CGFloat = 6
    /// The safe distance a pointer-side window keeps from every edge of its
    /// display. Not a hairline: these windows are summoned wherever the cursor
    /// happens to be, so a press taken near a corner regularly lands one against
    /// a side — flush there it reads as clipped, as though the box ran off the
    /// screen. Every placement, nudge and resize goes through `clamped(origin:)`
    /// so there is exactly one answer to where the edge is.
    static let screenMargin: CGFloat = 16
}
