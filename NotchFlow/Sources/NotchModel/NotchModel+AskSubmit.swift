import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

@MainActor
extension NotchModel {
    // MARK: - Submit

    /// A user-defined global prompt shortcut: open on the requested display,
    /// discard any page the panel happened to be showing, and submit the bound
    /// instruction against the already-captured outside selection immediately.
    /// `openPanel` comes first so its reattach-on-open behavior can settle; the
    /// following `newChat` then guarantees this action starts its own conversation.
    func runPromptShortcut(prompt: String, selectedText: String,
                           pin: ModelPin? = nil,
                           on display: CGDirectDisplayID?) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        let instruction = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty,
              !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }

        mode = .idle
        openPanel(on: display)
        newChat()
        text = """
        \(instruction)

        <selected_text>
        \(selectedText)
        </selected_text>
        """
        // Mark the thread as shortcut-driven BEFORE submitting: the result view
        // reads this to collapse its follow-up input into a floating button.
        fromPromptShortcut = true
        armModelPin(pin)
        submit(hideUserBubble: true)
    }

    /// Arm the next `submit()` with a shortcut's pinned backend. Once saved, that
    /// provider/model pair is authoritative: losing its key or CLI session should
    /// surface that backend's error, never silently reroute the shortcut through
    /// the app's current default.
    func armModelPin(_ pin: ModelPin?) {
        guard let pin else {
            regenOverrideModel = nil
            regenOverrideProvider = nil
            return
        }
        regenOverrideModel = pin.model
        regenOverrideProvider = pin.provider
    }

    /// The empty form of a prompt shortcut, targeted at the notch. Open a fresh
    /// idle surface and retain the captured selection out of sight; the field is
    /// only for the instruction the user wants to apply to it.
    func openPromptShortcutComposer(selectedText: String,
                                    on display: CGDirectDisplayID?) {
        let context = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        mode = .idle
        openPanel(on: display)
        newChat()
        // Nothing was selected: this is the plain idle prompt, opened by the
        // gesture. The context stays nil so no badge claims a selection that
        // isn't there — the gesture still gets the user somewhere to type.
        promptShortcutContext = context.isEmpty ? nil : selectedText
    }

    /// ⌘↵: submit the current line to the *other family* — the one-key flip for
    /// when the effective destination reads the line wrong. There are two families:
    /// **Ask** (send to the AI) and **Capture** (keep for yourself). Flipping
    /// ask→capture picks the leaf by the same structural rule auto-routing uses —
    /// a named future time makes it a Reminder, otherwise a Note — so a manual
    /// flip can never file differently than the classifier would have. Either
    /// capture leaf flips back to Ask. Tab stays the precise three-way pick
    /// (`toggleSubmitPanel`); this is the coarse, no-look correction.
    func submitOtherFamily() {
        switch effectiveSubmitPanel {
        case .chat:
            if detectedDue != nil { submitReminder() } else { submitNote() }
        case .note, .reminder:
            submit()
        }
    }

    /// The clipboard string that's *available* as fresh outside context, or `nil`
    /// when the clipboard itself isn't a candidate. Used by deictic note capture
    /// ("save this" folds the copied URL/snippet into the note body). Available
    /// means: the user copied for *this*
    /// session — the `changeCount` has moved past its pre-open resting baseline, which
    /// covers the intended copy-THEN-open flow (the baseline is the count from before
    /// the open; see `pasteboardChangeCountAtOpen`) as well as a copy made while the
    /// panel is open; the clipboard holds a non-empty string, URL, or file URL; and
    /// it's short enough (≤ 1500 chars) to inject without blowing up the prompt;
    /// and it isn't text this session is itself displaying (see
    /// `isCurrentSessionText` — an in-panel copy never counts as outside context).
    /// Anything longer than 1500 chars, an image, or a stale clipboard returns nil.
    /// Never mutates the pasteboard.
    func clipboardContextIfEligible() -> String? {
        let pb = NSPasteboard.general
        guard pb.changeCount != pasteboardChangeCountAtOpen else { return nil }
        // Read priority: plain string (the common case) → "Copy Link" URL → Finder
        // file path. Safari/Chrome's right-click "Copy Link" writes `.URL` with no
        // `.string` companion, so a copied link would otherwise read as nil and inject
        // nothing on "summarize this link"; a Cmd-C from the address bar DOES write
        // `.string`, so it resolves in the first arm. Finder file copies write
        // `.fileURL` (a file:// URI) with no `.string`. First non-nil arm wins, so
        // plain-text copies are completely unaffected.
        let raw = pb.string(forType: .string)
               ?? pb.string(forType: .URL)
               ?? pb.string(forType: .fileURL)
        guard let s = raw else { return nil }
        let clip = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clip.isEmpty, clip.count <= 1500 else { return nil }
        // Text already visible inside this session is an *in-app* copy, not outside
        // context — quoting it back adds nothing. This catches the copies our code
        // never sees (⌘C in the input field, selecting answer text), which bypass
        // `rebaselineClipboardAfterInAppWrite` because the system performs them.
        guard !isCurrentSessionText(clip) else { return nil }
        return clip
    }

    /// True when `clip` (already trimmed) is text the current session itself is
    /// showing: the input-box draft, the parked idle draft, or a turn of the
    /// on-screen conversation. Turns also match on *containment* for clips of
    /// ≥ 40 chars, so a partial selection copied out of an answer still counts as
    /// in-app; short clips must match a whole turn exactly, so a word copied from
    /// another app that merely appears somewhere in the answer isn't swallowed.
    func isCurrentSessionText(_ clip: String) -> Bool {
        func matches(_ s: String) -> Bool {
            let body = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return clip == body || (clip.count >= 40 && body.contains(clip))
        }
        return matches(text) || matches(savedIdleDraft) || turns.contains { matches($0.text) }
    }

    /// The clipboard image available to attach to an Ask (XII-121), or `nil`.
    /// Gated on the ACTIVE MODEL first: only a model known to read images (see
    /// `Provider.modelSupportsVision`) gets the thumbnail at all — a text-only
    /// model shows no preview rather than promising an attach that would fail.
    /// Then the same freshness gate as the text path (the changeCount must have
    /// moved past the pre-open baseline), and only consulted when NO eligible
    /// text clip exists — a copied string always wins, so nothing about the text
    /// flow changes. `NSImage(pasteboard:)` reads PNG/TIFF (the screenshot
    /// formats) and returns nil for a text-only pasteboard.
    /// Can the model an Ask would go to right now actually read an image? Gates both
    /// the clipboard thumbnail below and the re-attach of a reopened thread's saved
    /// image — nothing offers or sends pixels a text-only model would choke on.
    /// Codex / Claude Code / Grok (CLI backends) count as text-only here: their
    /// models report as vision-capable by id, but the chat path doesn't forward
    /// images to the subprocess, so an attach there would be silently dropped.
    var activeModelSupportsVision: Bool {
        let provider = APIKeyStore.selectedProvider
        let model = APIKeyStore.effectiveModel(for: provider) ?? provider.defaultModel
        guard provider != .codex, provider != .claudeCode, provider != .grokCode,
              provider != .piCode else { return false }
        return Provider.modelSupportsVision(model)
    }

    /// Downsample + encode an attached image (XII-121): long side capped at 1568px
    /// (Anthropic's documented vision sweet spot; also keeps any provider's payload
    /// sane), JPEG at 0.82 — a full-screen Retina screenshot lands in the
    /// hundreds-of-KB range instead of many MB. Returns `nil` when the bitmap can't
    /// be read or encoded, in which case the turn just goes out as plain text.
    /// Every consumer takes these same bytes: the chat wraps them as a base64
    /// `ChatImage`, the agent hands them to its CLI (a temp file for codex's
    /// `exec -i`, a base64 vision block for claude's stream-json stdin), and the
    /// history store keeps them as the saved thumbnail.
    /// `nonisolated`: the downscale + JPEG of a Retina screenshot is real CPU, so
    /// callers run it on a detached task (see the encode step at the top of the
    /// round's task) instead of on the main actor at the moment of ⏎. Everything
    /// here draws into an offscreen bitmap context, which is safe off the main thread.
    nonisolated static func encodeJPEGForVision(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = rep.pixelsWide, h = rep.pixelsHigh
        guard w > 0, h > 0 else { return nil }
        let maxSide = 1568
        let scale = min(1.0, Double(maxSide) / Double(max(w, h)))
        let finalRep: NSBitmapImageRep
        if scale < 1.0 {
            let outW = max(1, Int(Double(w) * scale))
            let outH = max(1, Int(Double(h) * scale))
            guard let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: outW, pixelsHigh: outH,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }
            // Draw in pixel space: pin the rep's point size to its pixel size so
            // the NSImage draw isn't rescaled by a Retina points-vs-pixels factor.
            resized.size = NSSize(width: outW, height: outH)
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: resized) {
                NSGraphicsContext.current = ctx
                image.draw(in: NSRect(x: 0, y: 0, width: outW, height: outH),
                           from: .zero, operation: .copy, fraction: 1.0)
                ctx.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()
            finalRep = resized
        } else {
            finalRep = rep
        }
        return finalRep.representation(using: .jpeg,
                                       properties: [.compressionFactor: 0.82])
    }

    /// Whole-word containment for the Latin-script gates in `isDeicticNoteCapture` —
    /// avoids "it" firing inside "edit" or "this" inside "thistle". Loops over every
    /// occurrence so a non-boundary first hit doesn't mask a later word-boundary one.
    /// Builds a manual boundary test rather than dragging in NSRegularExpression.
    private func containsWord(_ word: String, in haystack: String) -> Bool {
        var start = haystack.startIndex
        while start < haystack.endIndex,
              let r = haystack.range(of: word, range: start..<haystack.endIndex) {
            let isBoundary: (Character?) -> Bool = { c in
                guard let c else { return true }            // string edge is a boundary
                return !(c.isLetter || c.isNumber)
            }
            let before = r.lowerBound > haystack.startIndex
                ? haystack[haystack.index(before: r.lowerBound)] : nil
            let after = r.upperBound < haystack.endIndex
                ? haystack[r.upperBound] : nil
            if isBoundary(before) && isBoundary(after) { return true }
            start = haystack.index(after: r.lowerBound)
        }
        return false
    }

    /// Rough char budget for the wired conversation history. A long thread grows
    /// unbounded turn by turn; left uncapped it eventually overruns the provider's
    /// context window, which comes back as a non-retryable 400 that kills the turn
    /// outright (not a graceful "too long"). We trim the OLDEST turns first, keeping
    /// the tail — the current question and its recent lead-up, which is what the
    /// answer actually depends on. ~48k characters is a conservative few-k-token
    /// slice that leaves ample room for the system prompt, tools, and the reply on
    /// every provider we ship, while still holding many turns of normal chat.
    private static let wireContextCharBudget = 48_000

    /// The wire copy of the thread for `submit()` (XII-88). Drops, besides the new
    /// round's placeholder, the assistant turns that never became a real answer:
    ///   - an *empty* turn left behind when a follow-up superseded a round before
    ///     its first token (Anthropic 400s on empty assistant content);
    ///   - an *error* turn holding the failure reason the XII-85 card wrote (the
    ///     model would read "Anthropic · HTTP 401" as its own prior reply).
    /// Dropping a turn can leave two user messages adjacent, which Anthropic also
    /// rejects (roles must alternate) — so consecutive same-role messages are
    /// merged. Only this wire copy is filtered; the visible thread keeps every turn.
    /// Also trims the oldest turns past `wireContextCharBudget` — see there.
    private static func wireContext(from turns: [Turn], excluding answerID: UUID)
        -> [ChatMessage]
    {
        // Keep only the turns that will actually be wired (same hygiene filter as
        // below), then walk from the newest backwards, admitting turns until the
        // char budget is spent. The current question is the last kept turn, so it is
        // always admitted first — a single turn is never dropped for being too big,
        // it's just the only one that fits. Older turns beyond the budget fall off.
        let wirable = turns.filter { turn in
            if turn.id == answerID { return false }
            if turn.role == "assistant" {
                let body = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if body.isEmpty || turn.isError { return false }
            }
            return true
        }
        var kept: [Turn] = []
        var used = 0
        for turn in wirable.reversed() {
            // Admit the newest turn unconditionally; after that, stop once adding the
            // next-older turn would blow the budget (older history just drops off).
            if !kept.isEmpty && used + turn.text.count > wireContextCharBudget { break }
            used += turn.text.count
            kept.insert(turn, at: 0)
        }
        // The untrimmed list always opened with the thread's first user question;
        // the budget cut can land between a question and its answer, leaving an
        // assistant turn first — which Anthropic rejects (the conversation must
        // open with a user turn). Drop any leading assistant turns so the trimmed
        // window still starts on a user message.
        while kept.first?.role == "assistant" { kept.removeFirst() }

        var messages: [ChatMessage] = []
        for turn in kept {
            if let last = messages.last, last.role == turn.role {
                messages[messages.count - 1] = ChatMessage(
                    role: turn.role, content: last.content + "\n\n" + turn.text)
            } else {
                messages.append(ChatMessage(role: turn.role, content: turn.text))
            }
        }
        return messages
    }

    func submit(hideUserBubble: Bool = false) {
        guard LicenseService.shared.state.allowsProductServices else { return }
        guard NotchCapabilityStore.shared.agenticModeEnabled else { return }
        // A line the user actually typed ends the shortcut's one-shot character —
        // from here the thread is an ordinary conversation, so the follow-up input
        // goes back to being a full field instead of a collapsed button.
        if !hideUserBubble { fromPromptShortcut = false }
        var q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pastedImages = askComposeImages
        if q.isEmpty {
            guard !pastedImages.isEmpty else { return }
            q = Self.agentImageOnlyPrompt(count: pastedImages.count)
        }
        // A follow-up on an agent thread whose CLI session is still resumable
        // goes back to the AGENT, not the chat model: the result view is the
        // run's conversation, so Enter there means "next instruction". Only
        // when the session is gone (no handle on record / engine uninstalled)
        // does the line fall through to the chat model, report as context.
        if agentThreadContinuation != nil {
            text = ""
            askComposeImages = []
            continueAgentThread(prompt: q, images: pastedImages)
            return
        }
        // Clear any prior error state — this attempt replaces it (XII-85).
        askError = nil
        // One-shot regenerate-with-model override (XII-135): build a service pinned
        // to the picked model for THIS turn only, without touching the saved
        // default. Consumed + cleared here. `regenModel` is stamped onto the answer
        // turn below so the result shows which model produced it.
        let overrideModel = regenOverrideModel
        let overrideProvider = regenOverrideProvider
        regenOverrideModel = nil
        regenOverrideProvider = nil
        // A prompt shortcut can pin a backend other than the selected one, so the
        // override builds against ITS provider.
        let pinnedProvider = overrideProvider ?? APIKeyStore.selectedProvider
        let overrideService: AIService? = overrideModel.flatMap { m in
            // Build the explicitly selected backend even if its credentials have
            // since disappeared. The resulting request will surface that setup
            // error instead of falling back to an unrelated default provider.
            return AppDelegate.makeService(provider: pinnedProvider,
                                           apiKey: APIKeyStore.keyOrEmpty(for: pinnedProvider),
                                           model: m)
        }
        // The provider this round actually streams from — the pin only counts once
        // its service exists. Everything provider-scoped below (tool registry, tool
        // support, recents) follows the service, never the setting behind it.
        let runProvider = overrideService == nil ? APIKeyStore.selectedProvider : pinnedProvider
        // This ask "uses" the model it will stream from — feed the chip menu's
        // recents (the one-shot regenerate override counts as the model used).
        let askProvider = runProvider
        AskModelMRU.record(provider: askProvider,
                           model: overrideModel
                               ?? APIKeyStore.effectiveModel(for: askProvider)
                               ?? askProvider.defaultModel)
        text = ""
        askComposeImages = []
        showHistory = false
        highlightedHistoryIndex = nil

        // A first question starts a fresh thread: give it a new history id so it
        // becomes its own recent row. A follow-up keeps the existing id, so the
        // whole conversation stays one row, updated in place. Captured before the
        // append below empties this out — clipboard injection keys off it too
        // (only a first turn pulls in the clipboard).
        let firstTurn = turns.isEmpty
        if firstTurn { threadHistoryID = UUID() }
        // Submitting never touches the pin. A follow-up keeps the pin the user set
        // to read the thread (asking on doesn't fold it), and a first question keeps
        // the pin set on the idle prompt — the only way one can be armed here, since
        // `newChat` / `fullClose` both clear it as they empty `turns`. Dropping it on
        // a first turn would fold the panel on leave exactly when the answer arrives.

        // A follow-up sent while the previous answer is still streaming supersedes
        // it: settle any stale streaming flag now, because the superseded task is
        // cancelled below and will never settle it itself.
        for i in turns.indices where turns[i].streaming { turns[i].streaming = false }

        // Append this question and an empty assistant turn it'll stream into. On a
        // first question `turns` is empty (fresh thread); on a follow-up the prior
        // turns are already here, so the new pair just extends the conversation.
        let questionTurn = Turn(role: "user", text: q,
                                hidesUserBubble: hideUserBubble)
        // Held so the deferred image encode below can find this exact turn again —
        // by id, never by index, since the thread on screen may have moved on (a new
        // chat, a reopened row) by the time the JPEG lands.
        let questionID = questionTurn.id
        turns.append(questionTurn)
        let answerID = UUID()
        var answerTurn = Turn(id: answerID, role: "assistant", text: "", streaming: true)
        // Stamp the one-shot regenerate model (XII-135) so the answer shows which
        // model produced it; rides into the saved snapshot below.
        answerTurn.regenModel = overrideModel
        turns.append(answerTurn)

        // The history sent to the model: every completed turn, plus the new
        // question — but NOT the empty assistant placeholder we just appended,
        // and minus the hygiene cases `wireContext` filters (XII-88): a superseded
        // round's still-empty assistant turn and an error card's reason text, both
        // of which providers either reject outright or misread as model speech.
        var context: [ChatMessage] = Self.wireContext(from: turns, excluding: answerID)

        let system = notchSystemPromptDated(customInstructions: customInstructions)

        // Explicitly pasted images attach to the newest wire message. The encoded
        // set is also parked on the thread so follow-ups still see every image.
        // Image rounds skip the agent harness (its tool wire has no image blocks).
        var imageAttached = false
        let pendingVisionImages = pastedImages
        if !pendingVisionImages.isEmpty {
            imageAttached = true
            if turns.count >= 2 { turns[turns.count - 2].usedClipboard = true }
        } else if !firstTurn, let parked = threadImages, parked.threadID == threadHistoryID,
                  let firstUser = context.firstIndex(where: { $0.role == "user" }) {
            context[firstUser].images = parked.images
            imageAttached = true
        }

        // Fresh thinking word for this answer's pre-stream wait, rotating slowly
        // while we wait so a long search/compose round doesn't freeze on one word.
        // Light the thinking dots for this round (cleared on the first token or when
        // the round ends) — they ride beside the notch even if the panel folds away.
        thinking = true
        thinkingAnswerID = answerID
        startThinkingWordRotation(for: q, answerID: answerID)
        mode = .load

        // The task owns a value-type snapshot of the thread it's answering, plus
        // the thread id captured here. Backing out (`newChat`) or closing the panel
        // (`fullClose`) only detaches the screen — the task keeps streaming into
        // its snapshot and persists the finished round to Recent, so an in-flight
        // round is never lost. The snapshot is also what gets saved, so whatever
        // `turns` shows by completion time (a new chat, a reopened history item,
        // nothing at all) can never leak into this thread's history row.
        let threadID = threadHistoryID
        let seedThread = turns

        // A first question parks a placeholder row in Recent right now, so leaving
        // the conversation mid-answer (collapse / newChat / close) shows the
        // question with a three-dot "answering…" marker instead of an empty list
        // that only fills in once the answer finishes. Follow-ups stream into the
        // row their first turn already created. The same-id row is replaced in
        // place by `persistThread` on completion, or removed by `settlePending` if
        // the round yields nothing.
        if firstTurn { parkPending(threadID: threadID, question: q) }

        // Cancelling here only ever supersedes within the SAME on-screen round (a
        // follow-up sent while the previous answer streams): detached tasks have
        // already cleared this slot, so they're out of reach.
        task?.cancel()
        let roundTask = Task { [weak self] in
            guard let self else { return }
            // Count this round in flight for the resting notch's background
            // indicator, and park its live mirror for reattach-on-open; the
            // defer pairs the teardown with every way out of this task —
            // finish, error, and supersede-cancel alike.
            self.roundsInFlight += 1
            // A round starting from idle owns the busy ear's phase from scratch.
            if self.inFlightRounds.isEmpty { self.backgroundWriting = false }
            self.inFlightRounds.append(
                InFlightRound(answerID: answerID, threadID: threadID, thread: seedThread))
            defer {
                self.roundsInFlight -= 1
                self.inFlightRounds.removeAll { $0.answerID == answerID }
                self.compactRoundTasks[threadID] = nil
                self.activeRoundTasks[answerID] = nil
                // Don't let the last round's tool label / write phase outlive
                // it on the collapsed notch's busy ear.
                if self.inFlightRounds.isEmpty {
                    self.backgroundActivity = nil
                    self.backgroundWriting = false
                }
                // A question can't normally outlive its round (cancellation and the
                // timeout both resolve it), but never strand a card on screen — or a
                // parked continuation — if one somehow does.
                for q in self.pendingUserQuestions where q.answerID == answerID {
                    self.resolveUserQuestion(q.id, with: .failure(CancellationError()))
                }
            }
            // The deferred vision encode (see `pendingVisionImage` above): produce
            // the wire bytes off the main actor, then attach them to the outgoing
            // context — nothing reads `context` until the stream starts below, so
            // the suspension is invisible beyond the thinking dots it happens under.
            // The same bytes are parked in the image store, so the row this round
            // settles into keeps the picture it was asked about.
            var savedImageFiles: [String] = []
            if !pendingVisionImages.isEmpty {
                let jpegs = await Task.detached(priority: .userInitiated) {
                    pendingVisionImages.compactMap { Self.encodeJPEGForVision($0) }
                }.value
                let encoded = jpegs.map {
                    ChatImage(base64: $0.base64EncodedString(), mediaType: "image/jpeg")
                }
                if !encoded.isEmpty {
                    context[context.count - 1].images = encoded
                    self.threadImages = (threadID: threadID, images: encoded)
                    savedImageFiles = await Task.detached(priority: .utility) {
                        jpegs.compactMap { Self.storeHistoryImage($0) }
                    }.value
                    if let i = self.turns.firstIndex(where: { $0.id == questionID }) {
                        self.turns[i].imageFiles = savedImageFiles
                    }
                }
            }
            var thread = seedThread
            // …and on the snapshot that actually gets persisted — `seedThread` was
            // captured before the encode finished, so it still has the bare question.
            if !savedImageFiles.isEmpty,
               let i = thread.firstIndex(where: { $0.id == questionID }) {
                thread[i].imageFiles = savedImageFiles
            }
            // Hoisted out of `do` so the error `catch` can read whatever streamed
            // before the failure — a mid-stream drop that already produced text must
            // persist that partial round, not discard it (see the catch below).
            var acc = ""
            // Throttle + pacing state for the streamed-text sink below. Providers
            // deliver deltas far faster than the display refreshes (some near
            // per-character) and in uneven bursts (a stall, then a slab), and
            // every write to `turns` re-evaluates NotchBody's whole tree (via
            // `ConversationStore`) and re-parses the growing tail's markdown — so
            // the per-chunk work is limited to accumulating into `acc`, and one
            // shared flush loop reveals the text at most ~30 times a second AND
            // at a smoothed rate: a burst is smeared across up to `paceMaxLag`
            // seconds instead of slamming in as one frame's slab.
            // Hoisted with `acc` so the catch paths can settle the throttle (a
            // trailing scheduled flush must never overwrite their final text).
            var pendingFlush: DispatchWorkItem? = nil
            var lastFlushAt: TimeInterval = 0
            var streamSettled = false
            // Pacing: how many characters of `acc` the UI currently shows, plus
            // the fractional remainder the integer step leaves behind each tick.
            var released = 0
            var releaseBudget: Double = 0
            do {
                // Push the PACED prefix of what's accumulated into the model/UI —
                // the one place the streamed text performs @Published writes.
                // Shared by the plain and agent paths so the snapshot threading,
                // first-chunk mode-flip, and on-screen guard live in exactly one
                // place. Main-actor (the task inherits it), so it can mutate the
                // task-local `acc`/`thread` and touch UI directly. `[weak self]`
                // mirrors the task; on a detached round `self` is gone and the
                // closure is a no-op.
                let flushInterval: TimeInterval = 1.0 / 30.0
                // The reveal rate self-regulates around one invariant: the display
                // never trails what has arrived by more than `paceMaxLag` seconds
                // (rate = backlog / maxLag, floored at `paceMinRate` so a trickle
                // still types along). Small bursts get smeared into a calm walk;
                // a giant slab still clears quickly — just smoothly.
                let paceMaxLag: TimeInterval = 1.2
                let paceMinRate: Double = 40   // characters per second
                // How long the close-out below is allowed to take. Short enough
                // that the settled footer reads as arriving WITH the last words,
                // long enough that a big remaining backlog still ramps out instead
                // of landing as one frame's slab — the very thing the pacing above
                // exists to prevent.
                let drainWindow: TimeInterval = 0.25
                // Non-nil once arrival has finished: the flat characters-per-second
                // that empties whatever is still buffered within `drainWindow`,
                // computed ONCE at that moment (see the close-out below). While it
                // is nil the live rate law above applies.
                //
                // Why the live law must not keep running past the end of the
                // stream: `rate = backlog / paceMaxLag` is derived from an
                // invariant about a LIVE stream — "the display never trails what
                // has arrived by more than 1.2s". Once nothing more is arriving
                // there is nothing left to smooth against, and the law decays
                // exponentially (τ = paceMaxLag) into the `paceMinRate` floor, so
                // the tail crawls exactly where the reader has already caught up:
                // a 240-character backlog took ~3s to finish, a short answer paid
                // 40 c/s all the way out. Nothing downstream can settle until it
                // does — `streaming` (and with it the answer's footer) flips only
                // after this drains — so that crawl was read as the footer lagging
                // the answer.
                var closeOutRate: Double? = nil
                var flushChunks: @MainActor () -> Void = {}
                flushChunks = { [weak self] in
                    guard let self, !streamSettled else { return }
                    pendingFlush?.cancel()
                    pendingFlush = nil
                    let now = ProcessInfo.processInfo.systemUptime
                    // First tick (lastFlushAt == 0) counts as one interval, so the
                    // very first characters paint immediately — time-to-first-paint
                    // is untouched by pacing.
                    let dt = lastFlushAt == 0 ? flushInterval : min(now - lastFlushAt, 0.25)
                    lastFlushAt = now
                    let backlog = acc.count - released
                    if backlog > 0 {
                        // Closing out (arrival done) → the flat rate fixed at that
                        // moment; still streaming → the live self-regulating law.
                        let rate = closeOutRate
                            ?? max(paceMinRate, Double(backlog) / paceMaxLag)
                        releaseBudget += rate * dt
                        let step = min(backlog, Int(releaseBudget))
                        if step > 0 {
                            releaseBudget -= Double(step)
                            released += step
                        }
                    }
                    let shown = released >= acc.count ? acc : String(acc.prefix(released))
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = shown
                    }
                    // Keep the reattach mirror current, so an open mid-stream
                    // restores everything revealed so far, not a stale snapshot.
                    self.syncInFlight(answerID, thread)
                    // The on-screen turn must still be live: a stop (Esc) settles
                    // it synchronously while this task is still being cancelled,
                    // and a trailing scheduled flush must not grow a turn the
                    // user already froze (what they saw at stop is what persists).
                    if self.isOnScreen(answerID: answerID),
                       self.turns.first(where: { $0.id == answerID })?.streaming == true {
                        // First real token ends the pre-stream wait: freeze the
                        // rotating thinking word (the dots/word fade out now anyway).
                        // Freeze ONLY — a full stop would also clear the tool
                        // activity, and a tool can still be running under this very
                        // text (a preface before a search): its line must survive.
                        self.freezeThinkingWord(for: answerID)
                        // First chunk: flip to the result view so the answer appears
                        // to grow in place out of the thinking state.
                        if self.mode == .load { self.mode = .result }
                        self.updateAnswer(id: answerID, text: shown)
                    }
                    // Keep draining: while revealed text still trails what has
                    // arrived, the loop schedules its own next tick — a stall in
                    // ARRIVALS must not stall the reveal (the old throttle only
                    // ticked when chunks landed, which is exactly what let a
                    // burst's slab sit until the next burst).
                    if released < acc.count, pendingFlush == nil {
                        let work = DispatchWorkItem { MainActor.assumeIsolated { flushChunks() } }
                        pendingFlush = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval, execute: work)
                    }
                }
                // The per-chunk sink: accumulate, then tick now if the throttle
                // window has passed (the first chunk always has — `lastFlushAt`
                // starts at 0 — so time-to-first-paint is untouched), else make
                // sure ONE trailing tick is scheduled for the window's end; from
                // there the flush loop keeps itself alive until drained.
                let appendChunk: @MainActor (String) -> Void = { [weak self] piece in
                    guard let self else { return }
                    acc += piece
                    // First real text for this round ends the thinking phase — clear the
                    // dots even if the panel folded away (the round is detached but still
                    // ours). Idempotent: only the round that owns the flag clears it.
                    self.endThinking(for: answerID)
                    // Mark the write phase for the collapsed busy ear — guarded
                    // so it publishes once per round, never per chunk.
                    if !self.backgroundWriting { self.backgroundWriting = true }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - lastFlushAt >= flushInterval {
                        flushChunks()
                    } else if pendingFlush == nil {
                        let work = DispatchWorkItem { MainActor.assumeIsolated { flushChunks() } }
                        pendingFlush = work
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + (flushInterval - (now - lastFlushAt)),
                            execute: work)
                    }
                }

                // Agent path when the backend can drive tools AND there are tools to
                // offer; otherwise the plain single-shot stream. The harness reads
                // tool calls, runs them, and threads the results back over several
                // turns — but to the UI it's the same growing answer. Any provider
                // that can't do tools, or a turn with an empty registry, falls
                // straight back to the existing behavior: nothing about plain Q&A
                // changes.
                // The standard tool set, plus the two tools that can't live in
                // `ToolRegistry.standard(for:)` because they need the live model:
                //  · `ask_user` — its suspension is owned by the model
                //    (`awaitUserChoice`), keyed to THIS round's answer turn so the
                //    question card renders under the answer it interrupts;
                //  · `manage_app_settings` — reads the live model-backed preferences
                //    and reuses this round's question card as its mandatory write
                //    confirmation gate;
                //  · `search_history` — reads the archive off `history`, which is
                //    main-actor state on this object;
                //  · `create_note` / `create_reminder` — the second write surface,
                //    gated on the same in-answer confirmation card and filing their
                //    Recent row through the model that owns `history`.
                var agentTools = ToolRegistry.standard(for: runProvider).tools
                agentTools.append(ManageAppSettingsTool { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.handleAppSettingsRequest(answerID: answerID,
                                                                   request: request)
                })
                agentTools.append(AskUserTool { [weak self] question, options in
                    guard let self else { throw CancellationError() }
                    return try await self.awaitUserChoice(answerID: answerID,
                                                          question: question,
                                                          options: options)
                })
                agentTools.append(CreateNoteTool { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.handleCaptureRequest(answerID: answerID,
                                                               request: request)
                })
                agentTools.append(CreateReminderTool { [weak self] request in
                    guard let self else { throw CancellationError() }
                    return try await self.handleCaptureRequest(answerID: answerID,
                                                               request: request)
                })
                agentTools.append(SearchHistoryTool { [weak self] query in
                    // A round whose model went away has no archive to read; an empty
                    // digest renders as "nothing recorded", which is honest.
                    guard let self else { return .empty }
                    return await MainActor.run { self.searchArchive(query) }
                })
                let registry = ToolRegistry(agentTools)
                // The service for THIS turn: a one-shot regenerate override (XII-135)
                // wins, else the main service. An upgraded model still gets the tool
                // harness below (search etc.), so the override rides both paths.
                let askService: AIService = overrideService ?? self.ai
                if !imageAttached,
                   let agent = askService as? AgentCapableService,
                   runProvider.supportsTools,
                   !registry.isEmpty {
                    let harness = AgentHarness(service: agent, registry: registry)
                    let agentMessages = context.map {
                        AgentMessage(kind: .text(role: $0.role, text: $0.content))
                    }
                    try await harness.run(
                        system: system,
                        messages: agentMessages,
                        onText: appendChunk,
                        onActivity: { [weak self] label, orb in
                            guard let self else { return }
                            // Every round feeds the background slot, on screen
                            // or detached — the collapsed notch's busy ear shows
                            // the same live line the panel would ("Searching the
                            // web…", "Reading github.com…"). This must sit BEFORE
                            // the isOnScreen gate: a detached round is exactly
                            // the one the resting notch is reporting on.
                            self.backgroundActivity = label
                            // The detached thread mirror needs the same live state:
                            // its header and answer wait row must say Search / Read /
                            // Calculate rather than falling back to a hard-coded verb.
                            if let i = thread.firstIndex(where: { $0.id == answerID }) {
                                thread[i].toolActivity = label
                                thread[i].thinkingOrbState = label == nil
                                    ? (Self.taskStyle(for: q)?.orb ?? .composing)
                                    : orb
                                self.syncInFlight(answerID, thread)
                            }
                            // The activity line only shows on a still-on-screen
                            // round; a detached harness silently ignores it.
                            if self.isOnScreen(answerID: answerID) {
                                if self.mode == .load { self.mode = .result }
                                self.updateActivity(id: answerID, label: label, orb: orb)
                            }
                        },
                        onSources: { [weak self] roundSources in
                            guard let self else { return }
                            if !roundSources.isEmpty {
                            }
                            // Accumulate sources across rounds onto the snapshot
                            // (so they persist with the thread) and, when on screen,
                            // the live turn (so the badge appears). Deduped by URL.
                            if let i = thread.firstIndex(where: { $0.id == answerID }) {
                                thread[i].sources = Self.mergedSources(thread[i].sources, roundSources)
                                self.syncInFlight(answerID, thread)
                            }
                            if self.isOnScreen(answerID: answerID) {
                                self.appendSources(id: answerID, roundSources)
                            }
                        },
                        onModel: { [weak self] ran in
                            guard let self else { return }
                            // Stamp the concrete model on both the persisted snapshot
                            // and the on-screen turn, mirroring `onSources`, so the
                            // footer shows which model actually replied.
                            if let i = thread.firstIndex(where: { $0.id == answerID }) {
                                thread[i].answerModel = ran
                                self.syncInFlight(answerID, thread)
                            }
                            if self.isOnScreen(answerID: answerID),
                               let i = self.turns.firstIndex(where: { $0.id == answerID }) {
                                self.turns[i].answerModel = ran
                            }
                        })
                } else {
                    // A regenerate override (XII-135) streams from its pinned
                    // service; everything else uses the main model.
                    let service = askService
                    // Stamp the model that answered, so the reply footer shows it. The
                    // harness path does this via `onModel`; this plain-stream path
                    // (Codex and other non-tool turns) otherwise left the footer blank.
                    let ranModel = overrideModel
                        ?? APIKeyStore.effectiveModel(for: runProvider)
                        ?? runProvider.defaultModel
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].answerModel = ranModel
                        self.syncInFlight(answerID, thread)
                    }
                    if self.isOnScreen(answerID: answerID),
                       let i = self.turns.firstIndex(where: { $0.id == answerID }) {
                        self.turns[i].answerModel = ranModel
                    }
                    for try await chunk in service.stream(system: system, messages: context) {
                        if Task.isCancelled { return }
                        appendChunk(chunk)
                    }
                }
                if Task.isCancelled { return }
                // Arrival is over. Switch the throttle to close-out: one flat rate,
                // fixed here, that empties whatever is still buffered in
                // `drainWindow` — a short linear ramp instead of the live law's
                // long exponential tail (see `closeOutRate`). The floor still
                // applies so a couple of trailing characters don't crawl.
                closeOutRate = max(paceMinRate,
                                   Double(acc.count - released) / drainWindow)
                // Let that close-out finish walking what's still buffered before
                // settling, so the tail ramps out instead of snapping in. Bounded
                // twice over: the flat rate empties the backlog in `drainWindow`,
                // and a hard deadline covers any stall.
                // Cancellation (Esc / superseded) breaks out — the catch paths
                // settle instantly, and what the user saw at stop is what persists.
                let drainDeadline = ProcessInfo.processInfo.systemUptime + 3
                while released < acc.count, !Task.isCancelled,
                      ProcessInfo.processInfo.systemUptime < drainDeadline {
                    try? await Task.sleep(nanoseconds: 33_000_000)
                }
                if Task.isCancelled { return }
                // Final flush: the terminal writes below must see the complete
                // text (pieces may still be buffered inside the throttle window,
                // or left by the drain deadline), and settling the flag keeps a
                // trailing scheduled flush from firing after them.
                released = acc.count
                flushChunks()
                streamSettled = true
                self.stopThinkingWordRotation(for: answerID)
                self.endThinking(for: answerID)
                if let i = thread.firstIndex(where: { $0.id == answerID }) {
                    thread[i].streaming = false
                }
                // Captured BEFORE persist: whether this round finished detached —
                // the user walked away while it streamed, so the panel folded back
                // to the resting notch (the three dots). When so, fire a native
                // banner so the finished answer doesn't just quietly go out.
                let walkedAway = !self.isPresented(answerID: answerID)
                self.markFinished(id: answerID)   // no-op when detached
                self.persistThread(thread, threadID: threadID, answer: acc)
                if walkedAway {
                    self.notifyAnswerReady(threadID: threadID, question: q, answer: acc)
                }
            } catch is CancellationError {
                // superseded by a newer round on the same screen; nothing to persist
                pendingFlush?.cancel()
                streamSettled = true
            } catch {
                if Task.isCancelled { return }
                // Settle the throttle before the terminal writes below: they own
                // the final text (partial + interrupted suffix, or the error
                // reason), and a trailing scheduled flush firing after them would
                // overwrite it with the bare partial.
                pendingFlush?.cancel()
                streamSettled = true
                self.stopThinkingWordRotation(for: answerID)
                self.endThinking(for: answerID)
                let partial = acc.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    // A mid-stream drop *after* the first chunk: we already have a real
                    // partial answer. Persist it to Recent exactly like a completed
                    // round — crucially this runs whether or not the thread is still on
                    // screen, so backing out / closing mid-answer over a flaky network
                    // no longer makes the question vanish from Recent. Settle the
                    // snapshot's streaming flag and tag the saved answer as interrupted,
                    // in both the assistant turn and the answer field so the reopened
                    // thread and the collapsed row agree.
                    let saved = acc + L("error.interrupted")
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = saved
                        thread[i].streaming = false
                    }
                    let walkedAway = !self.isPresented(answerID: answerID)
                    self.persistThread(thread, threadID: threadID, answer: saved)
                    // Only touch the screen when this round still owns it.
                    if self.isOnScreen(answerID: answerID) {
                        self.updateAnswer(id: answerID, text: saved)
                        self.markFinished(id: answerID)
                        self.mode = .result
                    } else if walkedAway {
                        // Interrupted but salvaged a partial answer, and the user had
                        // already walked away — still notify, same as a clean finish.
                        self.notifyAnswerReady(threadID: threadID, question: q, answer: saved)
                    }
                } else {
                    // Failed before any text arrived (refused connection, bad key):
                    // there's no answer to keep — but the QUESTION is the user's and
                    // must survive. File the row marked failed, carrying the real
                    // reason, instead of deleting it: a round that fails should leave
                    // a trace you can reopen and re-ask, not erase itself from Recent.
                    // `persistThread` also settles any detached mirror on this same
                    // text, so a mirroring window never sits on a spinner.
                    if let i = thread.firstIndex(where: { $0.id == answerID }) {
                        thread[i].text = error.localizedDescription
                        thread[i].isError = true
                        thread[i].streaming = false
                    }
                    self.persistThread(thread, threadID: threadID, answer: "")
                    if self.isOnScreen(answerID: answerID) {
                        // Surface the REAL reason (XII-85) — `ServiceError` already
                        // localizes to e.g. "Anthropic · HTTP 401" — and raise an
                        // actionable error state (retry, or open Settings when no key
                        // is set) instead of a dead generic line. An image round adds
                        // the vision hint (XII-121): the most likely cause of a
                        // rejected image payload is a model without vision support,
                        // and the raw provider error rarely says so legibly.
                        let reason = error.localizedDescription
                            + (imageAttached ? "\n" + L("ask.visionHint") : "")
                        self.updateAnswer(id: answerID, text: reason)
                        // Flag the turn so `wireContext` keeps this reason out of the
                        // next round's wire copy — a follow-up typed instead of a
                        // retry must not send the error text as model speech (XII-88).
                        self.markTurnError(id: answerID)
                        self.markFinished(id: answerID)
                        self.askError = AskError(message: reason,
                                                 needsSetup: !self.isConfigured,
                                                 answerID: answerID)
                        self.mode = .result
                    }
                    // Metadata-only breadcrumb (no prompt/answer/key) — failures
                    // go through the same diagnostics path whether the round is in
                    // the main panel, a Force Touch window, or already detached.
                    DiagnosticsLog.shared.record(
                        provider: runProvider.displayName,
                        status: Self.httpStatus(from: error),
                        error: error)
                }
            }
        }
        task = roundTask
        activeRoundTasks[answerID] = roundTask
    }

    /// The HTTP status carried by a service error, if any — for the diagnostics
    /// breadcrumb only. Pulls it from `ServiceError.http` without ever touching the
    /// response body. Nil for non-HTTP failures (timeout, offline, malformed).
    private static func httpStatus(from error: Error) -> Int? {
        (error as? OpenAICompatAIService.ServiceError)?.httpStatus
    }

    /// True while an ask round is streaming on THIS screen — the stop
    /// affordance's gate (XII-122). A round detached by `newChat`/`fullClose`
    /// keeps streaming into its snapshot but is no longer on-screen, so it
    /// doesn't count (there's nothing visible to stop).
    var isStreaming: Bool { turns.contains { $0.streaming } }

    /// Stop the in-flight ask (XII-122) — the streaming answer's stop button and
    /// Esc both land here. Cancels the current task but KEEPS whatever already
    /// streamed: a partial answer settles in place (and persists to Recent, like
    /// the mid-stream-drop path) so the thread stays followable and follow-ups
    /// work on it. A stop before the first token has nothing to keep — the empty
    /// pair is dropped and the question lifted back into the input instead, so
    /// the words aren't lost either way. No-op when nothing is streaming.
    func stopStreaming() {
        guard isStreaming else { return }
        task?.cancel()
        task = nil
        let activeAnswerIDs = turns.filter { $0.role == "assistant" && $0.streaming }.map(\.id)
        for answerID in activeAnswerIDs {
            stopThinkingWordRotation(for: answerID)
        }
        thinking = false
        thinkingAnswerID = nil
        // Settle the on-screen streaming flag(s), reading back the partial text.
        var partial = ""
        for i in turns.indices where turns[i].streaming {
            turns[i].streaming = false
            if turns[i].role == "assistant" { partial = turns[i].text }
        }
        if partial.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Nothing streamed yet: an empty assistant bubble is dead weight —
            // drop the pair, put the question back (ready to edit or resend), and
            // clear the parked "answering…" placeholder from Recent.
            if let lastUser = turns.last(where: { $0.role == "user" }) {
                let question = lastUser.text
                if turns.last?.role == "assistant" { turns.removeLast() }
                if turns.last?.role == "user" { turns.removeLast() }
                if text.isEmpty { text = question }
            }
            settlePending(threadHistoryID)
            mode = turns.isEmpty ? .idle : .result
        } else {
            mode = .result
            persistThread(turns, threadID: threadHistoryID, answer: partial)
        }
    }

    /// Retry the Ask that just failed (XII-85). The failed turn pair (the question
    /// plus its empty/error assistant turn) is still on screen; drop the assistant
    /// half and the question turn, lift the question back into the input, and re-run
    /// `submit()` so it streams a fresh answer into a clean pair. No-op when there's
    /// nothing to retry.
    func retryLastAsk() {
        // Gated on the *visible* error: a retry may only ever re-run the round that
        // actually failed on this screen, never the last question of whatever
        // conversation the user has since opened.
        guard visibleAskError != nil else { return }
        askError = nil
        resubmitLastQuestion()
    }

    /// The newest SETTLED assistant answer's text, trimmed — the target of the
    /// keyboard copy/save actions (XII-131). `nil` when there's no answer or the
    /// last one is still streaming (nothing final to act on yet).
    var lastAnswerText: String? {
        guard let last = turns.last, last.role == "assistant", !last.streaming else { return nil }
        let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Re-run the newest settled answer's question for a fresh take — the answer
    /// footer's regenerate button. Same drop-and-resubmit dance as `retryLastAsk`,
    /// but for a turn that *succeeded*: only ever offered on the last assistant
    /// turn (regenerating mid-thread would orphan everything after it), and gated
    /// on the stream being settled so a tap can't tear down an answer mid-flight.
    func regenerateLastAnswer(model: String? = nil) {
        // Never on an agent run's report (footer button and ⌘R alike): the chat
        // model can't re-run a task in the run's folder — it would just hallucinate
        // a "completed" report over the real one.
        guard let last = turns.last, last.role == "assistant", !last.streaming,
              !last.isAgent else { return }
        resubmitLastQuestion(model: model)
    }

    /// The models offered by the "regenerate with…" menu (XII-135): the current
    /// provider's available models, with the one currently in effect flagged so the
    /// menu can grey it out ("current"). Only meaningful when configured (a live
    /// backend); empty for the stub so the menu simply doesn't appear.
    var regenerateModelOptions: [(model: String, isCurrent: Bool)] {
        guard !(ai is StubAIService) else { return [] }
        let provider = APIKeyStore.selectedProvider
        let current = APIKeyStore.effectiveModel(for: provider) ?? provider.defaultModel
        return provider.availableModels.map { ($0, $0 == current) }
    }

    /// Does this *note* line point at something on the clipboard rather than carry
    /// its own content? Calibrated for **note-filing**: the
    /// verbs are save/keep/bookmark/file, and the useful payload is the copied
    /// URL/snippet, not the directive phrase. "Add this to my reading list" should
    /// file the link, not the literal sentence. Two signals, either is enough:
    ///   1. A note-filing verb paired with a deictic ("save **this**").
    ///   2. A very short line that is essentially a bare deictic ("this").
    /// Conservative by design: a self-contained jot ("buy milk", "dentist tue 3pm")
    /// matches neither and is filed verbatim as today. Lexical only; no model call.
    func isDeicticNoteCapture(_ line: String) -> Bool {
        let q = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return false }

        // Discourse markers that merely *contain* a deictic word — never captures.
        let discourseMarkers = ["that said", "that is to say", "that being said",
                                "it depends", "it is what it is"]
        if discourseMarkers.contains(where: { q.contains($0) }) { return false }

        let enDeictics = ["this", "that", "these", "those", "it"]
        let hasEnDeictic = enDeictics.contains { containsWord($0, in: q) }
        guard hasEnDeictic else { return false }

        // 1. Note-filing verb + deictic → capture (the verb's object is the clip).
        let enFileVerbs = ["save", "add", "bookmark", "keep", "file", "store",
                           "note", "jot", "log", "put", "record", "capture"]
        let hasFileVerb = enFileVerbs.contains { containsWord($0, in: q) }
        if hasFileVerb { return true }

        // 2. Essentially a bare deictic — nothing else of substance to file.
        let words = q.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        if words <= 5 { return true }

        return false
    }
}
