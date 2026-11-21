import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Clipboard sense (copy → hint on the resting notch → ⌘C again to file)

    /// The copy-sense lifecycle, rendered by the resting notch's left extension
    /// (the same strip the busy dots use). `hinting` = the copied text read as a
    /// note/reminder and the notch is offering it — press ⌘C again to file it.
    /// `saving`/`saved`/`failed` narrate the write after a confirm. Every stage is
    /// only *visible* while the panel is closed; opening the panel hands the same
    /// clip to the in-panel capture chip instead.
    enum ClipboardSense: Equatable {
        case idle
        case hinting(panel: Panel)
        case saving(panel: Panel)
        case saved(panel: Panel)
        case failed
    }
    static let copySenseKey = "copySenseEnabled"
    /// Legacy key name, kept so the setting survives the agent-only → global move.
    static let liveActivityKey = "notchFlowActivityEnabled"

    /// A one-line personal preference the user set in Settings (XII-137), appended
    /// after the built-in persona on the Ask path — "always answer in English",
    /// "I'm a developer, prefer code", "use metric units". Empty = zero behaviour
    /// change (the default). Capped at `customInstructionsLimit` chars so it can't
    /// bloat the prompt and slow first token. Persisted in UserDefaults.
    static let customInstructionsLimit = 200
    static let customInstructionsKey = "customInstructions"

    /// Background sensing must earn its interruption: it is now the only place
    /// the engine gets a say at all, and a hint that lights up the closed notch on
    /// every copy needs a strong read. Below this the background default is
    /// *nothing* — and even above it the hint only offers; the user still presses
    /// ⌘C again to file. Nothing is ever routed on a guess.
    static let senseActionFloor = 0.55

    /// How long a hint stays up with no response before it fades on its own.
    private static let senseHintTimeout: TimeInterval = 5.0

    /// The minimum gap between the hint appearing and a re-copy that counts as a
    /// confirm. People habitually double-tap ⌘C "to make sure it copied" — those
    /// land well under this; a real "saw the hint, pressed again" can't. A re-copy
    /// faster than this refreshes the hint instead of firing it.
    private static let senseMinReaction: TimeInterval = 0.6

    /// Poll cadence for the resting watcher. Each tick is one `changeCount` read
    /// (an Int, no content access) unless the count actually moved.
    private static let senseTickInterval: TimeInterval = 0.3

    /// Start the resting watcher (called once from `init`). `.common` mode so a
    /// tracked menu or drag doesn't starve the tick; generous tolerance because
    /// nothing here needs frame accuracy.
    func startClipboardSense() {
        let t = Timer(timeInterval: Self.senseTickInterval, repeats: true) { [weak self] _ in
            // Scheduled on RunLoop.main, so the fire is always on the main
            // thread — assume (not hop to) the actor to keep the tick synchronous.
            MainActor.assumeIsolated { self?.senseTick() }
        }
        t.tolerance = Self.senseTickInterval / 2
        RunLoop.main.add(t, forMode: .common)
        senseTimer = t
    }

    private func senseTick() {
        let pb = NSPasteboard.general
        // Panel open: the in-panel clipboard flow owns the pasteboard. Track the
        // count so nothing copied (or written by us) in-session triggers a hint
        // after close.
        guard !open else {
            senseLastChangeCount = pb.changeCount
            return
        }
        // Disabled still tracks the count, so re-enabling can't hint on some
        // long-stale copy made while the switch was off.
        guard copySenseEnabled else {
            senseLastChangeCount = pb.changeCount
            return
        }
        let count = pb.changeCount
        guard count != senseLastChangeCount else {
            senseExpireHintIfStale()
            return
        }
        senseLastChangeCount = count

        guard let clip = senseReadClipboard() else {
            // The clipboard moved to something we won't touch (empty, oversized,
            // concealed, denied…) — any hint about the previous clip is stale.
            senseCancelHint()
            return
        }
        // A write is narrating (saving/saved/failed) — the strip is spoken for.
        // New copies during that beat just pass through unsensed.
        switch clipboardSense {
        case .saving, .saved, .failed:
            return
        case .hinting(let panel) where clip == senseClip:
            // The same text copied again while its hint is up. Fast enough to be a
            // habitual double-tap → refresh the hint; a beat later → the confirm.
            if let shown = senseHintShownAt,
               Date().timeIntervalSince(shown) >= Self.senseMinReaction {
                senseConfirm(clip: clip, panel: panel)
            } else {
                senseHintShownAt = Date()
            }
        default:
            senseClassify(clip)
        }
    }

    /// Read the pasteboard for sensing, or `nil` for anything the background
    /// watcher must not touch. Stricter than `clipboardContextIfEligible`: only a
    /// plain string (a bare URL or file path is never a note), never anything a
    /// password manager marked concealed/transient, and never while the system's
    /// pasteboard-privacy setting denies programmatic reads.
    private func senseReadClipboard() -> String? {
        guard senseClipboardAccessAllowed() else { return nil }
        let pb = NSPasteboard.general
        let types = pb.types ?? []
        let offLimits = ["org.nspasteboard.ConcealedType",
                         "org.nspasteboard.TransientType",
                         "org.nspasteboard.AutoGeneratedType"]
        guard !offLimits.contains(where: { types.contains(NSPasteboard.PasteboardType($0)) })
        else { return nil }
        guard let raw = pb.string(forType: .string) else { return nil }
        let clip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clip.count >= 2, clip.count <= 1500 else { return nil }
        // Text this app itself produced (a parked draft, a copied answer) is not
        // a jot the user wants filed back at them.
        guard !isCurrentSessionText(clip) else { return nil }
        return clip
    }

    /// Gate content reads on the system pasteboard-privacy state (macOS 15.4+).
    /// `alwaysAllow` senses freely; `alwaysDeny` never reads; `ask`/`default` get
    /// exactly one attempt per app session — enough for the system to show its
    /// consent alert once, never a prompt-per-copy drip.
    private func senseClipboardAccessAllowed() -> Bool {
        if #available(macOS 15.4, *) {
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow:
                return true
            case .alwaysDeny:
                return false
            case .default, .ask:
                if senseAskAttempted { return false }
                senseAskAttempted = true
                return true
            @unknown default:
                return false
            }
        }
        return true
    }

    /// Classify a fresh copy and raise (or decline to raise) the hint. Same
    /// engine and note→reminder split as the in-panel chip, but at the higher
    /// `senseActionFloor` — an unsure read means no hint, not a default.
    private func senseClassify(_ clip: String) {
        guard clip != senseCapturedClip else { return }   // already filed this text
        // The busy dots own the strip while a detached answer streams; a hint on
        // top would be two voices in one mouth. The copy simply goes unsensed.
        guard roundsInFlight == 0, !noteSaving else { return }
        senseClassifyTask?.cancel()
        senseClassifyTask = Task { [weak self] in
            let reading = await IntentEngine.shared.classify(clip)
            guard !Task.isCancelled, let self, !self.open, self.copySenseEnabled else { return }
            guard reading.intent == .note, reading.confidence >= Self.senseActionFloor else {
                self.senseCancelHint()
                return
            }
            let due = RemindersService.futureDate(in: clip)
                ?? RemindersService.recurrenceDate(in: clip)
            self.senseClip = clip
            self.senseHintShownAt = Date()
            self.clipboardSense = .hinting(panel: due != nil ? .reminder : .note)
        }
    }

    /// The confirm: file the clip where the hint said it would go, narrating
    /// saving → saved (or failed) in the strip. Writes go straight to the
    /// services — the submit-path plumbing (input-box state, saved cues) belongs
    /// to the open panel. The Recent row still lands via `persistCapture`, so a
    /// background capture shows up in history exactly like a chip capture.
    private func senseConfirm(clip: String, panel: Panel) {
        senseClassifyTask?.cancel()
        senseHintShownAt = nil
        // Claim the clip now, not on success — an open-panel chip tapped during
        // the in-flight write must not file a duplicate. Released on failure.
        senseCapturedClip = clip
        clipboardSense = .saving(panel: panel)
        switch panel {
        case .reminder:
            // Same past-due guard as `submitReminder`: better a reminder with no
            // time than one that silently never rings.
            var due = RemindersService.futureDate(in: clip)
                ?? RemindersService.recurrenceDate(in: clip)
            if let d = due, d <= Date() { due = nil }
            RemindersService.createReminder(clip, due: due) { [weak self] result in
                switch result {
                case .success(let link):
                    self?.senseWriteLanded(clip: clip, panel: panel, source: .reminder, link: link)
                case .failure:
                    self?.senseWriteFailed()
                }
            }
        case .note, .chat:
            // Honor the note destination here too — a closed-notch capture is the
            // same jot as a typed one, so it files to the same place.
            if NoteDestination.current == .markdownFolder {
                FileNotesService.writeNote(clip) { [weak self] result in
                    switch result {
                    case .success(let path):
                        self?.senseWriteLanded(clip: clip, panel: panel, source: .note, link: path)
                    case .failure:
                        self?.senseWriteFailed()
                    }
                }
            } else {
                NotesService.writeNote(clip) { [weak self] result in
                    switch result {
                    case .success(let noteID):
                        self?.senseWriteLanded(clip: clip, panel: panel, source: .note, link: noteID)
                    case .failure:
                        self?.senseWriteFailed()
                    }
                }
            }
        }
    }

    private func senseWriteLanded(clip: String, panel: Panel, source: HistoryItem.Source, link: String?) {
        persistCapture(clip, source: source, link: link)
        senseClip = nil
        // If the switch was flipped off while the write was in flight, the work
        // still landed (and Recent shows it) — just skip the cue.
        clipboardSense = copySenseEnabled ? .saved(panel: panel) : .idle
        senseDismiss(after: 1.4)
    }

    private func senseWriteFailed() {
        // Release the claim: the text is still safe in the clipboard, and the
        // in-panel capture chip becomes the retry path.
        senseCapturedClip = nil
        senseClip = nil
        clipboardSense = copySenseEnabled ? .failed : .idle
        senseDismiss(after: 2.4)
    }

    /// Retract the strip after a terminal cue has had its beat.
    private func senseDismiss(after seconds: TimeInterval) {
        senseDismissTask?.cancel()
        senseDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            switch self.clipboardSense {
            case .saved, .failed: self.clipboardSense = .idle
            default: break
            }
        }
    }

    /// Fade an unanswered hint once it has outstayed `senseHintTimeout`.
    private func senseExpireHintIfStale() {
        guard case .hinting = clipboardSense, let shown = senseHintShownAt,
              Date().timeIntervalSince(shown) > Self.senseHintTimeout else { return }
        senseCancelHint()
    }

    /// Drop a visible hint (never a saving/saved narration — those settle on
    /// their own via `senseDismiss`).
    func senseCancelHint() {
        senseClassifyTask?.cancel()
        if case .hinting = clipboardSense { clipboardSense = .idle }
        senseClip = nil
        senseHintShownAt = nil
    }

    /// Tear the whole sense state down (setting toggled off, panel opened).
    func senseReset() {
        senseClassifyTask?.cancel()
        senseDismissTask?.cancel()
        clipboardSense = .idle
        senseClip = nil
        senseHintShownAt = nil
    }
}
