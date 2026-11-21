import SwiftUI
import Combine
import AppKit   // NSWorkspace — opening Notes/Reminders for a Recent capture
import Carbon.HIToolbox
import UniformTypeIdentifiers   // UTType — is a pasted file URL an image? (agent ⌘V)

/// Images loaded back out of the history store (`NotchModel.historyImage(named:)`),
/// keyed by filename. File-scope rather than a static on the (main-actor) model, so
/// the loader can stay `nonisolated` — a thumbnail is read from wherever the view or
/// a background sweep happens to run. `NSCache` is thread-safe and evicts under
/// memory pressure, so a big archive can't pin every screenshot it ever saw in RAM.
let historyImageCache = NSCache<NSString, NSImage>()

/// Decodes a JSON array element-by-element, dropping any element that fails to
/// decode instead of failing the whole array. Used for persisted history so one
/// corrupt or future-incompatible row can't wipe every Recent item (see
/// `loadHistory`). A single `try? decode([T].self …)` is all-or-nothing; this
/// isolates each element behind its own `try?`.
struct LossyArray<T: Decodable>: Decodable {
    let elements: [T]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [T] = []
        while !container.isAtEnd {
            // Decode each element into a throwaway wrapper so a failure advances the
            // container past the bad element (a bare `try? container.decode(T.self)`
            // leaves the cursor stuck and loops forever). The wrapper swallows the
            // error and yields nil; the element is then skipped.
            if let decoded = try container.decode(LossyElement<T>.self).value {
                result.append(decoded)
            }
        }
        elements = result
    }
}

/// One element of a `LossyArray`: decodes a `T`, or captures the failure as `nil`
/// while still consuming the element so the parent container can advance.
private struct LossyElement<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// The live conversation's turns, split into their own ObservableObject so the
/// ~30Hz streaming flushes invalidate ONLY the views that actually render the
/// thread (NotchBody observes this store directly). Before the split `turns` was
/// `@Published` on `NotchModel` itself, and — `@Published` granularity being the
/// whole object — every streamed chunk re-evaluated the body of EVERY surface
/// observing the model: the settings panel, onboarding, What's New, the History
/// window, none of which render the conversation. The model still exposes a
/// `turns` forwarder so its own logic reads/writes exactly as before.
@MainActor
final class ConversationStore: ObservableObject {
    @Published var turns: [NotchModel.Turn] = []
}

/// The notch's interaction state. Mirrors the prototype's `mode` plus the
/// open/closed state, and owns the history list + AI calls.
@MainActor
final class NotchModel: ObservableObject {
    enum Mode: Equatable {
        case idle      // resting input, may show "Recent"
        case load      // waiting on the AI
        case result    // showing an answer
    }

    /// Where pressing Enter on the current line will *send* it — whatever the user
    /// last pinned, and nothing else. This is a routing destination, NOT a rendered
    /// surface: there's only ever one input on screen ("Type anything…"). It just
    /// determines whether Enter asks the AI or files the line somewhere.
    ///   · `chat`     — ask the AI a question (idle/load/result)
    ///   · `note`     — file the line as a new note in Apple Notes
    ///   · `reminder` — file the line in Apple Reminders with the time it names
    enum Panel: String, Equatable {
        case chat
        case note
        case reminder
    }

    /// One bubble in the on-screen conversation. `role` is `"user"` or
    /// `"assistant"`; the assistant turn is created empty and filled as the stream
    /// arrives (`streaming` is true until it finishes), which is what lets the text
    /// appear to grow in place.
    struct Turn: Identifiable, Codable, Equatable {
        var id = UUID()
        var role: String     // "user" | "assistant"
        var text: String
        var streaming: Bool = false
        /// The prompt-shortcut request still belongs to the transcript and wire
        /// context, but its generated instruction + selected-text payload is an
        /// implementation detail and should not render as a user bubble.
        var hidesUserBubble: Bool = false
        /// True on the *user* turn whose message was enriched with the clipboard, so
        /// the result view can show a permanent "based on what you copied" trace above
        /// it — not a flag that flashes during load and vanishes. Always false on
        /// assistant turns.
        var usedClipboard: Bool = false
        /// A transient "🔍 searching…" label shown on a *streaming assistant* turn
        /// while the agent harness runs a tool, then cleared. Purely runtime UI — it
        /// is never persisted (no `CodingKey`), so a saved conversation never carries
        /// a stale activity line. `nil` whenever no tool is running.
        var toolActivity: String? = nil
        /// The rest of a live answer's presentation state. These values are
        /// runtime-only, just like `toolActivity`: detached windows mirror the
        /// exact state the panel renders instead of reconstructing a second,
        /// lossy "Thinking" state from the question text.
        var thinkingWord: String? = nil
        var thinkingOrbState: OrbState? = nil
        var thinkingStartedAt: Date? = nil
        var pendingQuestion: PendingUserQuestion? = nil
        /// Web sources behind this assistant answer, when it was grounded by a
        /// search tool (GLM today). Drives the clickable source badge under the
        /// answer. Persisted, so reopening a recent item keeps its sources.
        var sources: [WebSource] = []
        /// True on an *assistant* turn whose text is a failure reason written by the
        /// error path (the XII-85 error card), not model output. Persisted, because a
        /// later successful round snapshots the whole thread into history — and the
        /// wire context must keep filtering the error turn out after a reopen, so the
        /// model never sees "Anthropic · HTTP 401" as something it once said.
        var isError: Bool = false
        /// The model this assistant turn was regenerated with (XII-135), when it
        /// differs from the user's default — set by a one-shot "regenerate with…"
        /// pick so the answer can show which model produced it. `nil` for the normal
        /// case (default model), so a plain answer carries no annotation. Persisted,
        /// so a reopened thread still shows the badge.
        var regenModel: String? = nil
        /// The concrete model the provider actually ran for this assistant answer,
        /// as echoed back in the stream's `model` field. Its whole reason to exist
        /// is the `openrouter/free` auto-router: the request only names the router,
        /// so this is the sole record of which model really replied (e.g.
        /// `openai/gpt-oss-20b:free`). The footer strips the vendor prefix and
        /// `:free` suffix to show a bare model name. `nil` when the provider didn't
        /// report one (or on the plain non-agent path). Persisted, so a reopened
        /// thread still shows it.
        var answerModel: String? = nil

        /// The images this (user) turn rode in with — the copied screenshot an Ask
        /// attached, or the shots pasted into an agent task — as filenames under
        /// `NotchModel.historyImagesDirectory`, never bytes: the archive is one JSON
        /// file rewritten after every answer, and inlining base64 screenshots would
        /// add hundreds of KB to every rewrite. Empty for a plain text turn; a file
        /// that's since been deleted simply renders as nothing.
        var imageFiles: [String] = []

        /// True on a turn that is an agent run's record (the task prompt, the
        /// CLI's report) rather than a chat exchange. Gates the chat-only
        /// affordances on a reopened run: regenerate would re-run the task's
        /// prompt against the *chat model*, which can't touch the run's folder —
        /// so an agent report never offers it. Persisted, so a reopened run
        /// stays distinguishable from an Ask thread.
        var isAgent: Bool = false

        /// An agent answer turn's work trail — the round's tool calls and
        /// narration, sliced per round at settle (`AgentExchange.log`). The
        /// reopened record renders it above the report, so the thread reads
        /// like the live detail page did. `nil` on chat turns and on agent
        /// records filed before the trail was persisted.
        var agentLog: [AgentLogEntry]? = nil

        init(id: UUID = UUID(), role: String, text: String,
             streaming: Bool = false, usedClipboard: Bool = false,
             hidesUserBubble: Bool = false) {
            self.id = id; self.role = role; self.text = text
            self.streaming = streaming; self.usedClipboard = usedClipboard
            self.hidesUserBubble = hidesUserBubble
        }

        // Same defensive decode as `HistoryItem` (see the long note there): turns
        // are persisted inside a saved thread, and the whole history list is
        // decoded in one `try?` — so a turn saved before `usedClipboard`/`streaming`
        // existed must NOT throw `keyNotFound` and take the entire list down with
        // it. `decodeIfPresent` + defaults is what keeps old saved conversations
        // loadable. `role`/`text` are required — every saved turn has them.
        // `toolActivity` is deliberately absent: it's runtime-only UI state.
        enum CodingKeys: String, CodingKey { case id, role, text, streaming, hidesUserBubble, usedClipboard, sources, isError, regenModel, answerModel, imageFiles, isAgent, agentLog }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id           = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            role         = try c.decode(String.self, forKey: .role)
            text         = try c.decode(String.self, forKey: .text)
            streaming    = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
            hidesUserBubble = try c.decodeIfPresent(Bool.self, forKey: .hidesUserBubble) ?? false
            usedClipboard = try c.decodeIfPresent(Bool.self, forKey: .usedClipboard) ?? false
            sources      = try c.decodeIfPresent([WebSource].self, forKey: .sources) ?? []
            isError      = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            regenModel   = try c.decodeIfPresent(String.self, forKey: .regenModel)
            answerModel  = try c.decodeIfPresent(String.self, forKey: .answerModel)
            imageFiles   = try c.decodeIfPresent([String].self, forKey: .imageFiles) ?? []
            isAgent      = try c.decodeIfPresent(Bool.self, forKey: .isAgent) ?? false
            agentLog     = try c.decodeIfPresent([AgentLogEntry].self, forKey: .agentLog)
        }
    }

    struct HistoryItem: Identifiable, Codable, Equatable {
        var id = UUID()
        var q: String
        var a: String
        var t: Date
        /// The full conversation, so reopening a recent item restores every turn
        /// (not just the first Q/A). Optional for backward-compatible decoding of
        /// items saved before multi-turn — those fall back to `[q, a]`.
        var turns: [Turn]? = nil
        /// A short title summarizing the actual conversation content. Generated
        /// asynchronously after the first answer so the recent list can show the
        /// topic (e.g. "Acme leadership") instead of a generic first prompt (e.g.
        /// "Summarize this"). `nil` for legacy items and for unconfigured/offline sessions.
        var title: String? = nil
        /// What the recent list should display: the generated title when available,
        /// otherwise the first user message for backward compatibility.
        var displayTitle: String { title ?? q }

        /// Every image attached anywhere in this conversation, in turn order — a
        /// screenshot an Ask rode in on, the shots pasted into an agent task. The
        /// Recent / archive rows preview the first one; the transcript shows them
        /// all on the turn they belong to.
        var imageFiles: [String] { (turns ?? []).flatMap(\.imageFiles) }

        /// Where this captured line actually went. `.ask` is an AI Q&A and `.agent`
        /// a finished Codex/Claude run — both are threads that reopen; `.note`/
        /// `.reminder` are captures filed into Apple Notes/Reminders — they keep a
        /// trace in Recent but have no answer to reopen, so tapping one jumps to
        /// that note/reminder in its app instead.
        /// Defaults to `.ask`; decoded with `decodeIfPresent` (see `init(from:)`)
        /// so items saved before this field decode as `.ask`, not a hard failure.
        /// (Agent runs filed before `.agent` existed stay `.ask` — they read as
        /// ordinary threads, which is exactly what they were.)
        enum Source: String, Codable {
            case ask, note, reminder, agent

            /// Rows whose body reopens a conversation, as opposed to a capture
            /// whose body is inert and whose trailing button jumps to another app.
            /// Every "is this an Ask row?" branch means this.
            var isThread: Bool { self == .ask || self == .agent }
        }
        var source: Source = .ask

        /// The interaction that created this row, when it needs its own scoped
        /// history surface. Ordinary panel asks and prompt shortcuts leave this
        /// nil; a conversation started from the Force Touch popup is stamped here
        /// so that popup's History button never mixes in unrelated Ask rows.
        enum Origin: String, Codable {
            case forceTouch
        }
        var origin: Origin? = nil

        /// Deep link back to the exact note/reminder this capture created, so
        /// tapping the row jumps straight to it in Apple Notes/Reminders instead
        /// of re-filling the input. The note's `x-coredata://` id (opened via
        /// AppleScript `show`) for notes, an `x-apple-reminderkit://` URL for
        /// reminders. `nil` for `.ask` items, and for captures saved before this
        /// field existed — those fall back to opening the destination app's main
        /// window (see `openCapture`). The service layer captures the identifier at
        /// creation time; if that capture fails the link stays nil and the row
        /// still opens the app, never dead-ends.
        var link: String? = nil

        /// How an `.agent` run ended — "success" / "failure" / "cancelled".
        /// Lets the detail surfaces show a failed run as failed instead of
        /// reading like an ordinary answer. `nil` for non-agent rows and for
        /// runs filed before this field existed.
        var agentOutcome: String? = nil

        /// The CLI session an `.agent` run left behind, and where it was working.
        /// Present on every settled row whose run reported a session id — it's
        /// what lets the reopened thread's follow-up resume the run in place
        /// (`continueAgentThread`), and what the interrupted row's resume button
        /// re-issues the cut round into.
        struct AgentResume: Codable, Equatable {
            /// `AgentEngine.rawValue` — the engine that owns the session.
            let engine: String
            let folderPath: String
            /// The CLI's own conversation handle (claude `session_id` / codex
            /// `thread_id`) — what `--resume` / `exec resume` takes.
            let session: String
        }
        var agentResume: AgentResume? = nil

        /// True only on a row whose run the app died during — the one row that
        /// grows the explicit resume button (`openAgentResume`). A resumed run
        /// re-files this same row on settle with this back to false, so the
        /// affordance disappears the moment the work is no longer interrupted.
        var agentInterrupted: Bool = false

        /// Transient: true while the first answer for this thread is still
        /// streaming. Set when the question is submitted so the row appears in
        /// Recent immediately (showing the question, with a three-dot placeholder
        /// where the timestamp goes), cleared once the answer lands (`persistThread`)
        /// or the round fails with nothing to keep (`settlePending`). Never encoded
        /// (absent from `CodingKeys`) — a reloaded item is always settled, so a row
        /// can't come back from disk stuck mid-answer.
        var pending: Bool = false

        /// True on a row whose last round produced no answer — the model returned
        /// nothing, or the stream died before the first token. The row is kept
        /// anyway (the question is the user's, and deleting it is how a whole
        /// conversation used to disappear from Recent); this is what lets it read
        /// as failed instead of passing for an ordinary answer. `a` carries the
        /// reason. Persisted, so the marker survives a relaunch.
        var failed: Bool = false

        /// The turns to restore on reopen: the saved thread when present, else a
        /// two-turn thread rebuilt from the legacy `q`/`a` fields. A note/reminder
        /// capture has no conversation at all — never synthesize a ghost assistant
        /// bubble for it.
        var conversation: [Turn] {
            guard source.isThread else { return [] }
            return turns ?? [
                Turn(role: "user", text: q),
                Turn(role: "assistant", text: a),
            ]
        }

        init(id: UUID = UUID(), q: String, a: String, t: Date,
             turns: [Turn]? = nil, title: String? = nil,
             source: Source = .ask, link: String? = nil,
             agentResume: AgentResume? = nil, origin: Origin? = nil) {
            self.id = id; self.q = q; self.a = a; self.t = t
            self.turns = turns; self.title = title
            self.source = source; self.link = link
            self.agentResume = agentResume
            self.origin = origin
        }

        // Custom decoder — the load-bearing reason this exists: history is decoded
        // as one `try? JSONDecoder().decode([HistoryItem].self …)` (see
        // `loadHistory`), so if ONE item fails to decode the WHOLE list is dropped
        // and every Recent row vanishes. Swift's *synthesized* `Decodable` calls
        // `decode` (not `decodeIfPresent`) for non-optional stored properties even
        // when they carry a Swift default — the `= .ask` / `= nil` defaults apply
        // only to the memberwise init, NOT to decoding. So an item saved before
        // `source`/`link`/`turns`/`title` existed would throw `keyNotFound` and
        // wipe the list. Decoding the newer fields with `decodeIfPresent` (and
        // falling back to their defaults) is what actually makes old items decode
        // cleanly with no migration. `id`/`q`/`a`/`t` are required — every saved
        // item has always had them.
        enum CodingKeys: String, CodingKey {
            case id, q, a, t, turns, title, source, origin, link, agentOutcome, agentResume,
                 agentInterrupted, failed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id     = try c.decode(UUID.self,   forKey: .id)
            q      = try c.decode(String.self, forKey: .q)
            a      = try c.decode(String.self, forKey: .a)
            t      = try c.decode(Date.self,   forKey: .t)
            turns  = try c.decodeIfPresent([Turn].self,  forKey: .turns)
            title  = try c.decodeIfPresent(String.self,  forKey: .title)
            source = try c.decodeIfPresent(Source.self,  forKey: .source) ?? .ask
            origin = try c.decodeIfPresent(Origin.self, forKey: .origin)
            link   = try c.decodeIfPresent(String.self,  forKey: .link)
            agentOutcome = try c.decodeIfPresent(String.self, forKey: .agentOutcome)
            agentResume = try c.decodeIfPresent(AgentResume.self, forKey: .agentResume)
            // Legacy rows (saved before this key) only carried `agentResume` when
            // the run WAS interrupted — so a missing key + a resume handle means
            // interrupted, not false, or old interrupted rows would lose their
            // resume button.
            agentInterrupted = try c.decodeIfPresent(Bool.self, forKey: .agentInterrupted)
                ?? (agentResume != nil)
            // Rows saved before failed rows were kept at all are, by definition,
            // rows that succeeded.
            failed = try c.decodeIfPresent(Bool.self, forKey: .failed) ?? false
        }

        /// Content search for the `search_history` tool — every place the user's own
        /// words could be, not just the row's title. The Recent list's filter
        /// matches `displayTitle` alone (that's the right behavior for skimming a
        /// list of rows), but a model asked "did I ever note anything about the
        /// landlord" has to find the word wherever it was written: in the generated
        /// title, in the captured line, in the answer, or in any turn of a longer
        /// thread.
        func matchesArchiveSearch(_ needle: String) -> Bool {
            if let title, title.localizedCaseInsensitiveContains(needle) { return true }
            if q.localizedCaseInsensitiveContains(needle) { return true }
            if a.localizedCaseInsensitiveContains(needle) { return true }
            return (turns ?? []).contains { $0.text.localizedCaseInsensitiveContains(needle) }
        }

        /// Squeeze a stored field onto ONE line: the digest is line-per-row, so a
        /// multi-line note ("Meeting notes\nDraft due Tuesday") would otherwise split into what
        /// reads as two separate entries.
        private static func flattened(_ s: String) -> String {
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }

        /// Flatten to the one line the model reads (see `HistoryDigestRow`).
        ///
        /// The headline is free summarization the app already paid for: an Ask row's
        /// `title` was generated from the whole exchange, and a capture's `q` IS the
        /// user's line — so a day of activity reads as a day of activity without any
        /// transcript crossing the wire. `body` carries the literal question behind
        /// an Ask only when the title is a summary that doesn't already say it.
        var digestRow: HistoryDigestRow {
            var kind = source.rawValue
            // A failed run must not read like an ordinary finished task.
            if source == .agent, let outcome = agentOutcome, !outcome.isEmpty {
                kind += "·\(outcome)"
            }
            let headline = String(Self.flattened(displayTitle)
                .prefix(HistoryDigestRow.headlineCap))
            var body: String? = nil
            if source.isThread {
                let asked = Self.flattened(q)
                // Only when it adds something: an untitled row's headline already IS
                // the question, and repeating it would just spend budget.
                if !asked.isEmpty, asked != headline {
                    body = String(asked.prefix(HistoryDigestRow.bodyCap))
                }
            }
            return HistoryDigestRow(date: t, kind: kind, headline: headline, body: body)
        }
    }

    // Open / closed drives the grow-out-of-the-notch animation.
    @Published var open = false {
        didSet {
            if open {
                // A bucket that came back armed from the last launch still has to be
                // re-seeded (folder, live engine) — see `rearmPersistedAgentBucket`.
                // Done on open, not at init: the probes it needs shell out, and by
                // the first open the launch `warmUp()` has warmed their caches.
                rearmPersistedAgentBucket()
            }
        }
    }
    /// The brief "content dissolving" beat between a close request and the shell
    /// actually retracting. Closing used to be one snap — `open` flipped false and
    /// the glass body and its content collapsed on the same transaction, reading as
    /// a clamp. Now `beginClose()` raises this first: the content fades out while the
    /// shell holds its expanded size, and only once it's gone does `fullClose()` drop
    /// `open` and let the shell retract — so closing mirrors the staged feel of the
    /// open. `open` stays true through this beat, so window key-handoff and the
    /// expanded geometry hold until the real close lands.
    @Published var closing = false
    /// Which screen's island is unfurled. With one panel per display sharing this
    /// model, `open` alone would unfurl every screen at once — views gate on
    /// `isOpen(on:)` so only the hovered screen expands while the others keep
    /// their resting notch. `nil` while closed (and in single-screen debug paths,
    /// where it means "any screen").
    @Published var activeDisplay: CGDirectDisplayID? = nil
    @Published var mode: Mode = .idle

    /// The user pinned the current answer's card (the pin button in `resultHeader`).
    /// While set, `collapseOnLeave` bails: the pointer leaving no longer folds the
    /// panel, so the answer stays parked open for reading. Scoped to the answer on
    /// screen — cleared whenever the page changes underneath it (`newChat`, a fresh
    /// `submit`, a `fullClose`), so a pin never leaks onto the next conversation.
    @Published var isAnswerPinned = false

    /// Whether the pointer is currently over the open island. Maintained by the
    /// island's own `.onHover` (and seeded from the real pointer position on the
    /// closed→open edge, for a keyboard summon that lands under a resting cursor).
    /// The result header's trailing chips read it so they can rest INVISIBLE and
    /// fade in only under the cursor — at a glance the answer is all there is.
    @Published var pointerInside = false

    /// A live slider drag or press inside an interactive workspace control. SwiftUI
    /// may briefly rebuild the island's tracking area while a control updates,
    /// which produces a synthetic hover exit even though the cursor has not left.
    /// That must never be treated as a request to close the notch.
    @Published var panelControlInteraction = false

    /// A direct Codex or Claude permission is awaiting an explicit decision in the
    /// Agent tab. Unlike ordinary workspace content, that request must not vanish
    /// merely because the pointer is outside the notch when the callback arrives.
    /// Esc remains a deliberate close; this only gates hover-driven collapse.
    @Published var directApprovalPending = false

    /// A utility overlay (Pomodoro / Quick note / Reminder) is on screen. It does
    /// NOT hold the panel open — the overlay folds on leave like every other
    /// module — it only tells the rest of the app that the panel is showing a
    /// small interactive card: the force-click text capture stands down so a
    /// press inside the overlay isn't read as a selection grab.
    @Published var utilityOverlayPresented = false

    /// Mirrors `HoverSensitivity.current` so the island's SwiftUI tree re-renders
    /// when the level changes. The persisted value stays the source of truth (the
    /// hover gate reads it live); this is the observable shadow, and every writer
    /// goes through `applyHoverSensitivity`.
    @Published var hoverSensitivity: HoverSensitivity = .current

    /// The `.click` level's hover acknowledgement: WHICH screen's resting notch is
    /// flexed a few points out under the pointer, saying "yes, I'm here — click
    /// me". It is a *gesture*, not an open — the panel stays folded until the
    /// click lands. Per display, because every screen hosts its own island off
    /// this one model and only the one under the pointer should stir. Raised by
    /// `hoverEntered`, dropped by the peek watch (and by any open, so the flex
    /// never survives into the unfurl).
    @Published var hoverPeek: CGDirectDisplayID? = nil

    /// Whether `display`'s resting notch is wearing the click level's flex.
    func isPeeking(on display: CGDirectDisplayID?) -> Bool {
        guard let display, let peek = hoverPeek else { return false }
        return peek == display
    }

    /// This thread was opened by a user-defined prompt shortcut (`runPromptShortcut`)
    /// rather than by typing into the panel. Such a run is a one-shot — the user
    /// hit a hotkey on a selection and wants to read the answer — so the result
    /// view collapses its follow-up input into a small floating button that costs
    /// no height, and only expands into the full field when tapped. Cleared
    /// wherever the page changes underneath it (`newChat`, `fullClose`, a fresh
    /// typed `submit`), so it never leaks onto the next conversation.
    @Published var fromPromptShortcut = false

    /// Selection captured by an empty prompt shortcut whose destination is the
    /// notch. It stays invisible model context while the ordinary idle field asks
    /// for a one-off instruction; `submitCurrent` consumes and clears it.
    @Published var promptShortcutContext: String?
    var usingPromptShortcutContext: Bool { promptShortcutContext != nil }

    /// What the user had highlighted in the app they came from, read at the open
    /// edge (`SelectedTextCapture.ambient`) and carried into the idle prompt as
    /// context for the next ask. The whole point is that "translate this" works
    /// without copying anything first — the thing on screen *is* "this".
    ///
    /// It is never silent: the badge above the input says it is being used and
    /// hands back an × to drop it (`dropSelectionContext`), because a selection
    /// left over in some window the user isn't thinking about must never quietly
    /// steer an answer.
    @Published var selectionContext: String?
    /// The app that selection came from ("Safari"), for the badge. `nil` when the
    /// name is unavailable — the badge then just says a selection is in use.
    @Published var selectionContextSource: String?
    /// The last selection dropped with the badge's ×. Kept across closes so the
    /// same still-highlighted paragraph doesn't march back in on the next summon:
    /// the × means "not this text", and it holds until the user highlights
    /// something else.
    var dismissedSelection: String?

    /// Settings → General, "Use selected text": whether opening the panel reads
    /// what the user had highlighted outside. On by default — it is the whole
    /// point of a notch you talk to ("translate this" with nothing copied) — but
    /// people who live with a permanent selection in an editor want the prompt to
    /// stay blank, so it is one switch away. Off also stops the accessibility read
    /// happening at all, not just the badge from drawing.
    @Published var selectionContextEnabled: Bool =
        UserDefaults.standard.object(forKey: NotchModel.selectionContextKey) as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(selectionContextEnabled,
                                      forKey: NotchModel.selectionContextKey)
            if !selectionContextEnabled { clearSelectionContext() }
        }
    }
    private static let selectionContextKey = "selectionContextEnabled"

    /// The one-time "you can switch this off in Settings" note, shown after the
    /// user drops a carried selection for the FIRST time — see
    /// `dropSelectionContext`. Retires itself after a few seconds.
    @Published var selectionContextHintShown = false
    var selectionContextHintTask: Task<Void, Never>?
    static let selectionContextHintSeenKey = "selectionContextHintSeen"

    /// The model picker popover (anchored to the model chip in settings) is open.
    /// While set, `collapseOnLeave` bails exactly as it does for a pinned answer: the
    /// popover is a separate window outside the island's tracking area, so moving the
    /// pointer into it reads as "left the island" and would otherwise fold the panel
    /// out from under the open picker. Set true while the popover shows, false on close.
    @Published var isModelPickerOpen = false

    /// The cross-provider model-config card, summoned straight from the panel instead of
    /// from inside Settings. Opened by the settings chip, and by ⌘⇧I only as the fallback
    /// for a machine with no agent CLI installed (there, the agent picker has nothing to
    /// show). `NotchBody` hangs the popover off the panel body.
    @Published var showModelPicker = false

    /// What ⌘⇧I summons: the agent's model + reasoning-effort quick picker — the two dials
    /// turned between runs — regardless of mode or whether the Agent bucket is armed.
    /// `NotchBody` hangs the popover off the panel body; `ContentView` owns the chord.
    @Published var showAgentPicker = false

    /// The Ask model chip's quick menu — the agent quick picker's card on the chat
    /// side, listing the five most recently used models (`AskModelMRU`). `NotchBody`
    /// hangs the popover off the panel body like the other two pickers.
    @Published var showAskModelPicker = false

    /// The agent compose's folder chip menu — the recently worked-in projects
    /// (`AgentFolderMRU`), with the file panel as its tail row. Hung off the chip
    /// itself, exactly like the two model menus.
    @Published var showAgentFolderPicker = false

    /// A settled result's metadata card: the Chat footer's ⓘ model menu or the
    /// Agent follow-up row's command menu. Both live in a separate child window,
    /// so leaving the island to reach one must not fold the result page out from
    /// under the pointer.
    @Published var isResultMetadataMenuOpen = false

    /// The agent task whose detail page is open — the full-page work trail a
    /// status row's tap opens while its run is live (a settled row opens its
    /// Recent record instead, which shows the same trail). `nil` = no detail
    /// page; also cleared by `newChat` so Back/⌘N leaves it like any thread.
    @Published var agentDetailTaskID: UUID? = nil

    /// A model picked from the ⌘⇧I picker whose provider has no key yet. The picker
    /// can't take a key itself, so it hands the pick to Settings: the panel opens on the
    /// key section for that provider, and the model is selected the moment a key lands
    /// (the same "configure only when the pick needs it" flow the settings picker runs).
    /// `InlineSettingsView` consumes and clears it on appear.
    @Published var pendingModelSetup: PendingModelSetup?

    struct PendingModelSetup: Equatable {
        let provider: Provider
        let id: String
    }

    /// Agent compose state (XII: agent-to-Codex): ON while the idle input
    /// is composing an agent task — Enter starts a `AgentTaskManager` run
    /// instead of asking the chat model. Entered by the bucket pill's Agent half
    /// (or Shift-Tab), or by dropping a project folder on the island; left by
    /// Shift-Tab / Tab or the pill's Ask half — NOT by submitting.
    /// A bucket you *live in*, not one you pass through: persisted, so a submit,
    /// a close, and a relaunch all land you back where you were, armed on the
    /// same project and engine.
    @Published var agentComposeActive =
        UserDefaults.standard.bool(forKey: "agentBucketArmed") {
        didSet {
            UserDefaults.standard.set(agentComposeActive, forKey: "agentBucketArmed")
            guard agentComposeActive != oldValue else { return }
            // Chat and Agent own separate Recent views: switching buckets changes
            // which rows exist without touching Chat's source filter itself.
            // Invalidate the derived slice and release any index into the old one.
            agentFilteredHistoryCache = nil
            highlightedHistoryIndex = nil
            historyRecallIndex = nil
        }
    }

    /// The folder the composed task will run in — seeded from the remembered
    /// last project on entry, replaced via the folder chip or a drop. nil until
    /// the user has ever picked one; Enter then opens the picker, which doubles
    /// as the first run's confirmation gate.
    @Published var agentComposeFolder: URL? = nil

    /// Every enabled skill Codex reports for the current agent folder. Loaded via
    /// app-server rather than a filesystem scan so plugins, disabled entries, and
    /// repo-scoped skills follow Codex's own rules exactly.
    @Published var agentSkills: [CodexCLIService.Skill] = []
    var agentSkillsTask: Task<Void, Never>?

    /// Which agent CLI the armed task will run on (Codex / Claude Code). Seeded
    /// from the remembered choice (raw read — no process probe at init) and
    /// persisted on change, so the armed mode survives relaunches whole. Driven
    /// by the compose row's model chip — picking a model picks its engine.
    @Published var agentArmedEngine: AgentEngine =
        AgentEngine.storedPreference ?? .codex {
        didSet { AgentEngine.rememberPreference(agentArmedEngine) }
    }

    /// The armed run's explicit model pick — a flag value from the armed
    /// engine's `modelChoices`, nil = that engine's own CLI-config default.
    /// Persisted alongside the engine so the whole compose survives relaunches.
    @Published var agentModelID: String? =
        UserDefaults.standard.string(forKey: "agentModel") {
        didSet { UserDefaults.standard.set(agentModelID, forKey: "agentModel") }
    }

    /// The armed run's reasoning effort (compose row's third chip); nil leaves
    /// both CLIs on their own defaults.
    @Published var agentEffort: AgentEffort? =
        UserDefaults.standard.string(forKey: "agentEffort").flatMap(AgentEffort.init) {
        didSet { UserDefaults.standard.set(agentEffort?.rawValue, forKey: "agentEffort") }
    }

    /// The images ⌘V-pasted into the agent compose — screenshots of the bug,
    /// a design mock, a before/after pair. Each ⌘V appends, so a task can carry
    /// several. They ride the run to the agent alongside the task text (codex
    /// attaches them with one `exec -i` each; claude gets them as vision blocks
    /// via `--input-format stream-json`). Session-only, cleared when the compose
    /// exits — an attachment belongs to the task being written, not the mode.
    @Published var agentComposeImages: [NSImage] = []

    /// Images explicitly ⌘V-pasted into an ordinary Ask. Kept separate from the
    /// system clipboard: copying an image never changes the UI or silently sends
    /// pixels. Each paste appends, and submit clears exactly this round's set.
    @Published var askComposeImages: [NSImage] = []

    /// How many images one agent round may carry. Both CLIs take far more —
    /// codex's `-i` is variadic (OpenAI accepts 500 images / 50MB per request)
    /// and claude's stream-json takes 100 image blocks — but Anthropic imposes a
    /// stricter per-image dimension cap on requests holding MORE than 20 images,
    /// so 20 is the line where neither engine needs special handling. (Screenshots
    /// encode at a 1568px long side anyway, well inside even that stricter cap.)
    static let composeImageLimit = 20
    static let agentImageLimit = composeImageLimit

    /// The last project chosen for an agent Codex task. Kept separately so the
    /// folder picker can reopen there even after the user explicitly exits agent
    /// mode.
    private static let agentFolderKey = "agentLastFolder"

    private static func savedAgentFolder(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            UserDefaults.standard.removeObject(forKey: key)
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func saveAgentFolder(_ folder: URL?, forKey key: String) {
        if let folder {
            UserDefaults.standard.set(folder.path, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    var lastAgentFolder: URL? {
        get {
            Self.savedAgentFolder(forKey: Self.agentFolderKey)
        }
        set {
            Self.saveAgentFolder(newValue, forKey: Self.agentFolderKey)
        }
    }

    /// The NSOpenPanel for picking a agent folder is up. Gates `collapseOnLeave`
    /// exactly like `isModelPickerOpen`: the open panel is a separate window, so
    /// the pointer moving into it must not fold the island behind it.
    @Published var isFolderPickerOpen = false

    /// True while the AI is in its pre-stream *thinking* phase — from the moment a
    /// question is submitted until the first answer token lands (or the round ends).
    /// Drives the 3 thinking dots shown beside the physical notch. Deliberately
    /// SEPARATE from `mode`/`open`: if the cursor leaves mid-think the panel folds
    /// back to the resting notch, but the round keeps running detached — the dots
    /// must stay lit beside the collapsed notch until that round produces text or
    /// finishes, so this can't be gated on the panel being open.
    @Published var thinking = false
    /// The answer turn whose pre-stream wait `thinking` is currently tracking. Lets
    /// the first-token / finish handlers clear `thinking` only for the round that
    /// actually owns it, so a superseded round can't switch the dots off under a
    /// newer one.
    var thinkingAnswerID: UUID? = nil

    /// How many Ask rounds are currently in flight — on screen or detached. A
    /// fully closed panel with a non-zero count means an answer is still
    /// streaming in the background, and the resting notch flexes into its busy
    /// ears — verb left, elapsed clock right (see `NotchIsland`) — so the work
    /// stays visible in the meanwhile; the walk-away notification and the Recent
    /// row cover the *result*. Unlike `thinking` (pre-stream wait only), this
    /// spans the whole round: incremented when a round's task starts, decremented
    /// on every exit path (clean finish, mid-stream error, supersede-cancel), so
    /// the indicator can never stick on after the last round settles.
    @Published var roundsInFlight = 0

    /// When the oldest still-running Ask round started — the resting notch's
    /// busy ear shows this elapsed clock (mirroring the agent card's), so
    /// "working" reads as *for how long*, not just an abstract wave.
    var busySince: Date? { inFlightRounds.first?.startedAt }

    /// The newest tool-activity line from ANY in-flight round, on screen or
    /// detached ("Searching the web…", "Reading github.com…"). Unlike
    /// `thinkingActivity` (on-screen rounds only), this one exists for the
    /// collapsed notch: the busy left ear shows whatever the AI is actually
    /// doing right now, falling back to a plain verb only between tools.
    /// Last-writer-wins across concurrent rounds; cleared when the last round
    /// settles (see the round task's defer).
    @Published var backgroundActivity: String? = nil

    /// True once an in-flight round has started streaming answer text — the
    /// collapsed busy ear's "Writing" phase. The tool-activity label is nil
    /// during the final compose/stream, and without this the ear would fall
    /// back to "Thinking" for the entire write. One publish per round (guarded
    /// in `appendChunk`), never per chunk; reset when a fresh round starts from
    /// idle and when the last round settles.
    @Published var backgroundWriting = false

    /// One still-streaming round's live mirror. A detached round streams into a
    /// task-local snapshot the screen can't see — this mirror is the model's
    /// copy of that snapshot, refreshed on every chunk/source, which is what
    /// lets a hover during the busy extension (or a tap on the round's pending
    /// Recent row) put the answer back on screen mid-write instead of landing
    /// on the idle prompt (see `attachInFlightRound`).
    struct InFlightRound {
        let answerID: UUID
        let threadID: UUID
        var thread: [Turn]
        /// Stamped at append — feeds the resting notch's elapsed clock.
        let startedAt = Date()
    }

    /// Live mirrors of every round currently in flight, oldest first — appended
    /// when a round's task starts and removed on the same defer that settles
    /// `roundsInFlight`, so the two can never disagree.
    var inFlightRounds: [InFlightRound] = []

    /// The cursor's velocity at the instant the island opened — SwiftUI
    /// orientation (+x right, +y down), points/second. Hover-opens pass the
    /// tracker's reading; every other path (⌘, / debug launches) leaves it
    /// zero, which renders as the standard calm unfurl. `NotchIsland` consumes
    /// it to seed the entry kick and ease the open spring — set *before* `open`
    /// flips so the view computes its animation from a fresh reading.
    /// Deliberately not `@Published`: it is only ever written immediately before
    /// `open` flips (which already invalidates the tree), so publishing it would
    /// just add a second whole-tree invalidation on the open edge.
    var entryVelocity: CGVector = .zero

    @Published var text = "" {      // current input (idle prompt or follow-up)
        didSet {
            let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // Deleting the hand-typed sigil retires its little explanation beside
            // the caret — but NOT the mode it pinned. The pin is sticky now (see
            // `manualPanelOverride`); switching back is Tab's job, or the pill's.
            if let trigger = typedNoteTriggerPrefix,
               !text.hasPrefix(trigger) {
                typedNoteTriggerPrefix = nil
                typedNoteModeActive = false
            }
            // A `/`-pinned prompt shortcut is still scoped to its line — it runs
            // its input through an AI instruction, so it parks the pinned mode
            // while it's up. Letting it go hands that mode back.
            if promptShortcutMode != nil,
               empty {
                promptShortcutMode = nil
                manualPanelOverride = Self.storedSubmitMode
            }
            // The `/` menu's highlight is scoped to the menu being open: every
            // edit that shuts it (a space, a submit, a delete-all) parks the
            // highlight back on the top row, and every edit that *narrows* it
            // clamps the highlight inside the shorter list — so the keyboard can
            // never sit on a row that isn't there.
            if !slashMenuOpen {
                slashHighlight = 0
            } else if slashHighlight >= slashMatches.count {
                slashHighlight = max(slashMatches.count - 1, 0)
            }
            if text == "/" { refreshAgentSkills(forceReload: true) }
            // Any real edit ends an ↑/↓ recall session, so the next ↑ starts fresh
            // from the newest item. `isRecallingText` shields the recall's own
            // fill from tripping this (it writes `text` too).
            if !isRecallingText { historyRecallIndex = nil }
            // Text arriving no longer folds the recent list: the Recent chevron
            // stays on the bucket row while you type (see `NotchBody.bucketRow` /
            // `promptHidesRecent`), so the list is that control's state alone —
            // closing it out from under a still-lit chevron was the incoherent half.
            //
            // The keyboard highlight DOES go, every keystroke. With text in the box
            // the arrows belong to the caret (`PromptField` routes ↑/↓ to the field
            // once it isn't empty), so a highlight left behind would be un-walkable
            // — and a stale one must never steal Enter from the visible text.
            // (`historyConfirmHighlighted` also guards on `!hasText` as a backstop.)
            if hasText, highlightedHistoryIndex != nil {
                highlightedHistoryIndex = nil
            }
            // Feed the "actively typing" signal that holds off hover-leave folding
            // (the one exception to leave-collapses). Empty writes don't count —
            // submit/clear set "" programmatically and mustn't read as typing.
            if !isRecallingText, !text.isEmpty { noteUserTyping() }
            scheduleDueDetection()
        }
    }

    /// An unsent idle draft parked at the last close so re-opening the notch can
    /// hand it back instead of dropping what the user was mid-way through typing.
    /// `fullClose` stashes `text` here (only when it's a non-empty idle draft —
    /// never a submitted-then-cleared line), and the closed→open edge in
    /// `openPanel` restores it into a fresh idle prompt. Explicit "start fresh"
    /// paths (`newChat`) never fill this, so backing out still lands on a blank
    /// prompt. Consumed on restore so it hands back exactly once.
    var savedIdleDraft: String = ""

    // MARK: - Parked session (close = park, reopen soon = restore)

    var parkedSession: ParkedSession? = nil

    /// The answer thread's last measured intrinsic height, mirrored here live by
    /// NotchBody's `AnswerHeightKey` probe. A plain var, deliberately not
    /// @Published — it's layout telemetry for the next mount, never something a
    /// mounted view re-reads.
    ///
    /// Why it exists: NotchBody unmounts on every close (`if isOpen` in
    /// ContentView), which resets its measurement @State to 0 — so a hover-reopen
    /// into a parked answer always mounted in the WRONG layout first (unclipped,
    /// the whole thread at full intrinsic height) and flipped to the clipped
    /// scroller one preference pass later, mid-open-spring. That structural swap
    /// (new ScrollView, header → floating overlay, follow-up → float, scroll
    /// snapped to bottom) stacked onto the unfurl is exactly what made reopening
    /// an answer visibly rougher than opening the idle prompt. Parking the
    /// measurement with the session and seeding the next mount from it means the
    /// first frame is already the final layout, and the open rides one clean
    /// spring — same as idle. Zeroed on every close after parking, so only a
    /// genuine parked-session restore ever hands a seed to a fresh mount.
    var lastMeasuredAnswerHeight: CGFloat = 0

    /// When the user last actually typed (prompt, follow-up, ⌘F filter, or a
    /// settings key field). This is the ONE exception to leave-collapses: while
    /// the keyboard is engaged, the pointer's position isn't an attention signal,
    /// so hover-leave defers folding until `typingGrace` after the last keystroke.
    var lastEditAt: Date = .distantPast

    // MARK: - Hover ground truth

    /// AppKit synthesizes tracking-area enter/exit events for a STATIONARY
    /// pointer whenever the tracked view's geometry changes underneath it — and
    /// the island's geometry animates on every open/close. Trusting those raw
    /// events produced a feedback loop: a spurious exit during the open spring
    /// folds the panel, the collapse sweeps the boundary back under the pointer
    /// and fires an enter, which re-opens it — the island visibly flaps. So
    /// hover events are treated as *hints* and verified against the pointer's
    /// real position before acting: `panelScreenFrames` (registered by
    /// AppDelegate, screen coords, bottom-left origin) plus `islandFrames`
    /// (published by the view, SwiftUI window space, top-left origin) locate
    /// the island on screen; `NSEvent.mouseLocation` is the ground truth.
    var panelScreenFrames: [CGDirectDisplayID: CGRect] = [:]
    var islandFrames: [CGDirectDisplayID: CGRect] = [:]
    /// Called with every `islandFrames` write, so AppDelegate can fit the
    /// panel's window to the island (see `NotchPanel.setVisibleHeight`).
    var onIslandFrameChange: ((CGDirectDisplayID, CGRect) -> Void)?
    /// Per-display resting-notch height (the screen's safe-area inset, or the
    /// menu-bar height on notch-less screens) — registered alongside the panel
    /// frame so the resting notch rect can be computed without live layout.
    var restHeights: [CGDirectDisplayID: CGFloat] = [:]
    /// Per-display width of the REAL hardware notch (measured from the screen's
    /// auxiliary top areas), nil on screens that have none. The hover judgement
    /// is made against this, never against `Tokens.notchWidth`: the drawn island
    /// is deliberately a few points wider than the cutout so its black always
    /// covers the bezel, and those few points hang over live menu bar — hovering
    /// them must not open the panel.
    var hardwareNotchWidths: [CGDirectDisplayID: CGFloat] = [:]

    /// The resting notch's current ear widths (busy verb/clock, finished badge,
    /// copy-sense hint), registered by `NotchIsland` so the resting-notch hover
    /// rect can include them without the model re-deriving measured text
    /// widths. Global, not per display: the collapsed ears render identically
    /// on every screen. Plain vars for the same reason as `islandFrames`.
    var restingEarLeft: CGFloat = 0
    var restingEarRight: CGFloat = 0

    // MARK: - Detached session windows (tear-off)
    @Published var detachDrag: DetachDrag? = nil

    /// True while a settled detached window is being dragged over a resting
    /// notch — the island swells slightly to say "drop it here to take it back".
    @Published var detachMergeHint = false

    /// True from the instant a drag hands off to the window until the SwiftUI
    /// gesture ends — its remaining onChanged ticks must not re-arm a drag.
    var detachHandedOff = false

    /// Live mirrors for detached thread windows, keyed by thread id — fed at
    /// streaming cadence from `syncInFlight` and settled by `persistThread`,
    /// so only the window observing a thread re-renders on its chunks.
    var detachedThreadStores: [UUID: DetachedThreadStore] = [:]

    /// The destination the user has pinned by hand — a typed `:`, Tab, or a `/`
    /// command. `nil` means Ask, the resting default; nothing reads the text to
    /// change that.
    ///
    /// It STAYS pinned. It used to be scoped to one line — cleared the moment the
    /// field emptied — so every capture bounced the pill back to Ask the instant
    /// it was filed, and a run of five notes meant re-pinning five times. A mode
    /// the user set by hand is a setting, not a gesture: it survives the submit,
    /// the panel closing, and the app quitting (`storedSubmitMode`), and only the
    /// same three doors that set it can change it back.
    @Published var manualPanelOverride: Panel? = NotchModel.startingSubmitMode

    /// True only for Note mode entered by typing its punctuation prefix. It
    /// drives the temporary explanation beside the caret and clears when that
    /// exact first glyph is removed.
    @Published var typedNoteModeActive = false

    /// The first *future* moment the current text names (NSDataDetector, sub-ms,
    /// recomputed off `text.didSet`). This is what splits a capture between Notes
    /// and Reminders — a structural fact, not a guess, and the only thing left
    /// that reads the line at all. The same date becomes the due date
    /// `submitReminder()` files, so the split and the alarm can never disagree.
    /// It changes nothing on screen: Capture says Capture either way.
    @Published var detectedDue: Date? = nil

    // MARK: - The `/` command menu

    /// Which row of the `/` menu the keyboard is on. Kept pinned to the top
    /// whenever the menu is shut (`text.didSet`), so a reopened menu never
    /// inherits a stale highlight.
    @Published var slashHighlight: Int = 0

    /// A prompt shortcut pinned as the current line's mode. When set, Enter on
    /// the idle prompt runs the input through that shortcut's instruction instead
    /// of the ordinary Ask/Note/Remind routing — the shortcut behaves as a named,
    /// switchable mode. Scope mirrors `manualPanelOverride`: it lifts the moment
    /// the field empties (submit, delete-all, close), so every fresh line starts
    /// on the classifier again.
    @Published var promptShortcutMode: PromptShortcut? = nil

    /// Non-nil while this round's wait word is pinned to a task word (see
    /// `taskWords`) — the reroll returns it unchanged and the rotation timer
    /// never starts. Cleared when the round ends.
    var pinnedThinkingWord: String? = nil
    /// Semantic orb paired with the pinned task word. Translation connects
    /// languages; the other literal task labels retain the composing ribbon.
    var pinnedThinkingOrb: OrbState = .composing

    /// The current rotating thinking word. Re-rolled at the start of each answer and
    /// every `thinkingWordInterval` while the wait is on screen, avoiding an immediate
    /// repeat. This is the *mood word only* — it is NOT the thing the UI displays
    /// directly. The UI reads `thinkingStatus`, which decides between this word and a
    /// live tool-activity line so the two can never both show at once.
    @Published var thinkingWord: String = NotchModel.thinkingWords.randomElement() ?? "drifting"

    /// A live tool-activity line ("Searching the web…", "Reading the results…") when a
    /// tool is running, else nil. Set by the harness via `updateActivity`.
    @Published var thinkingActivity: String? = nil

    /// The thinking orb's mode riding the live activity line — set by the SAME
    /// harness call that sets the label (the harness knows which tool it just
    /// launched; see `AgentHarness.orbState(for:)`), so the orb is never guessed
    /// back out of a localized string. Meaningful only while `thinkingActivity`
    /// is non-nil; the exposure below falls back to the calm thinking ribbon.
    @Published var thinkingActivityOrb: OrbState = .composing

    /// When the current round's pre-stream wait began — the anchor for the quiet
    /// "· 12s" elapsed suffix on the wait line (see `WaitElapsedSuffix`). Set when
    /// the wait starts, cleared when the first token lands or the round ends, so
    /// the timer can never tick over a streaming answer.
    @Published var thinkingStartedAt: Date? = nil

    /// Latched true the first time a tool runs this round. Before any tool, the wait is
    /// the bare three dots (no word). Once the round has touched a tool, it stays in
    /// "word mode" for the rest of the wait — the activity line while a tool runs, then
    /// the rotating mood word through the compose gap. Reset at the start of each round.
    @Published var hasUsedToolThisRound = false

    /// Slowly rotates the mood word while the pre-stream wait is on screen, so a long
    /// search/compose round (10s+ across several tool rounds) breathes instead of
    /// freezing on one word. Scheduled in `.common` mode so it keeps firing during the
    /// panel's animations/tracking. Started when `.load` begins, stopped the moment the
    /// first token lands or the round ends.
    var thinkingWordTimer: Timer? = nil

    // MARK: - Natural-language app settings

    /// At most one settings write can own a round's confirmation card. Models are
    /// instructed to batch, but this runtime gate keeps a malformed multi-call
    /// turn from showing two confirmations or racing two writes anyway.
    var settingsConfirmationAnswers: Set<UUID> = []

    // MARK: - Notes & reminders (create_note / create_reminder)

    /// At most one capture can own a round's confirmation card. The harness runs a
    /// turn's tool calls concurrently, so two `create_note` calls in one turn would
    /// otherwise race two cards onto the same answer; the loser is told to file
    /// them one at a time and simply calls again next round.
    var captureConfirmationAnswers: Set<UUID> = []

    // MARK: - Ask-the-user questions (the `ask_user` tool)

    /// Questions currently awaiting an answer, oldest first. Almost always 0 or 1
    /// (the tool is told to ask at most one per answer), but a detached round's
    /// unanswered question can coexist with a newer round's.
    @Published var pendingUserQuestions: [PendingUserQuestion] = []

    /// The suspended `ask_user` tool calls, keyed by question id. Resuming each
    /// exactly once is `resolveUserQuestion`'s job — every exit path (tap, timeout,
    /// round cancellation) funnels through it, and later calls for an already-
    /// resolved id are no-ops.
    var userChoiceContinuations: [UUID: CheckedContinuation<String, Error>] = [:]

    /// One past line written to Notes/Reminders this session, kept only to flash a
    /// brief confirmation under the record input. `nil` clears the cue.
    /// Not persisted — Notes/Reminders are the store of record; this is feedback.
    @Published var lastSavedNote: String? = nil
    /// Set when a note write fails (e.g. Automation permission not granted), so the
    /// record view can surface the recovery hint instead of silently dropping the
    /// line. Cleared on the next successful write or when the user edits the field.
    @Published var noteError: String? = nil
    /// True while a note write is in flight (the AppleScript runs off-thread and
    /// the first one waits on the TCC prompt), so the record view can show a quiet
    /// "Saving…" cue instead of looking like nothing happened on Enter.
    @Published var noteSaving = false

    /// Monotonic id for the *current* capture write (XII-117). `submitNote` /
    /// `submitReminder` bump this and capture the new value; their async callback
    /// only owns the shared UI state (`noteSaving`, `text`, `lastSavedNote`,
    /// `noteError`, the cue) when its captured id still equals this — i.e. it's
    /// the write that's actually in flight. A second capture fired inside the
    /// first's ~600ms AppleScript retry window supersedes it, so the first's
    /// late-arriving callback no longer clears the gate early, nor overwrites the
    /// second's success with its own (possibly failed) outcome, nor bounces an
    /// already-filed line back into the input via `reportCaptureFailure`. The
    /// superseded callback still persists its OWN Recent row (idempotent, its own
    /// data), so a successful write is never lost — only the shared cue is ceded.
    var captureToken = 0

    /// A failed Ask, surfaced as an actionable error state instead of a blank spinner
    /// or a generic line (XII-85). Carries the real, human-readable reason (e.g.
    /// "Anthropic · HTTP 401") and whether the likely fix is to set up a key (no key
    /// configured) versus retry (transient/network). `nil` when there's no error.
    ///
    /// **Never read this directly for rendering or acting — use `visibleAskError`.**
    /// This is raw storage for the round that failed, and it outlives that round's
    /// time on screen (nothing clears it on `newChat` / `openHistory` /
    /// `attachInFlightRound` / a reopened parked session). Read unscoped, a failure
    /// in one conversation followed the user into every *other* conversation they
    /// opened: the stale "Try again" capsule took the place of that thread's
    /// follow-up input, and tapping it re-ran the innocent thread's last question.
    @Published var askError: AskError? = nil

    /// The shape of an Ask failure the result view renders into a capsule action.
    struct AskError: Equatable {
        /// The real reason, passed through from the service layer (not a generic
        /// string) so the user sees what actually happened.
        let message: String
        /// True when no model/key is configured — the action should be "open
        /// Settings" rather than "retry" (retrying without a key can't succeed).
        let needsSetup: Bool
        /// The assistant turn this failure belongs to — the round's own error
        /// bubble. What binds the error state to ONE conversation: the capsule only
        /// renders while that exact turn is the on-screen thread's (see
        /// `visibleAskError`), so switching threads leaves it behind.
        let answerID: UUID
    }

    /// The failure the result view may act on: `askError`, but only while the turn
    /// it belongs to is still the one on screen. Every navigation away (a new chat,
    /// reopening another Recent row, reattaching a detached round, restoring a
    /// parked session) swaps `turns`, so the id stops matching and the capsule
    /// disappears with the conversation that earned it — the follow-up input comes
    /// back for the thread the user is actually looking at. Reopening the failed
    /// thread brings it back (the error turn persists with its id), which is right:
    /// the retry belongs to that round.
    var visibleAskError: AskError? {
        guard let error = askError, isOnScreen(answerID: error.answerID) else { return nil }
        return error
    }

    /// The pasteboard's `changeCount` as of the last moment the notch was *resting*
    /// (closed, or a fresh chat) — i.e. the value from *before* the current open. An
    /// Ask injects the clipboard when the live count has moved past this baseline,
    /// which is the signal that the user copied something for *this* session and a
    /// referential query ("summarize this") is about the thing they just copied.
    ///
    /// Crucially this is the *pre-open* value, NOT the count at the instant the panel
    /// opened: the user's intended flow is copy-THEN-open, so by open time the copy
    /// has already bumped the count. Baselining at open would swallow exactly the copy
    /// we want to catch. Instead we carry forward the resting count (see
    /// `pasteboardChangeCountAtRest`), so a copy made while the notch was closed still
    /// reads as "new" once it opens. A count that hasn't moved since rest means the
    /// clipboard is stale relative to this session, so we leave it alone. Re-baselined
    /// on a new chat so our own handoff write can't leak back in.
    var pasteboardChangeCountAtOpen = NSPasteboard.general.changeCount

    /// The pasteboard's `changeCount` while the notch is *resting* — refreshed every
    /// time it fully closes, so the next open can baseline against the count from
    /// before the user's copy-then-open. Seeded at construction so the very first
    /// open (copy → open, no prior close) still has a sane pre-copy reference: the
    /// count as of app launch. `openPanel` copies this into `pasteboardChangeCountAtOpen`
    /// on the closed→open edge.
    var pasteboardChangeCountAtRest = NSPasteboard.general.changeCount

    /// The encoded images riding the current thread, so follow-ups still see every
    /// screenshot from the opening question. Keyed by thread id so attachments
    /// never leak across conversations.
    var threadImages: (threadID: UUID, images: [ChatImage])? = nil

    /// The live conversation rendered in the result view — alternating user and
    /// assistant `Turn`s. A follow-up appends to this rather than replacing it, so
    /// the whole thread stays on screen and (via `submit`) in the model's context.
    /// Empty while idle; the first submit seeds the first user + assistant turns.
    /// Backed by `conversation` (see `ConversationStore`): streaming writes
    /// publish through the store, never through the model's `objectWillChange`,
    /// so surfaces that don't render the thread are never invalidated by a chunk.
    let conversation = ConversationStore()
    var turns: [Turn] {
        get { conversation.turns }
        set { conversation.turns = newValue }
    }

    /// The question shown in the result header — the *first* question of the
    /// thread, so the header labels the conversation as a whole. Empty when there's
    /// no conversation yet.
    var question: String { turns.first(where: { $0.role == "user" })?.text ?? "" }

    /// Whether a live backend is wired up (an API key is available for the
    /// selected provider). `false` means we're on the offline stub, in which case
    /// a follow-up can only ever return another placeholder — so the result view
    /// swaps the follow-up field for a "set up your model" call to action instead.
    /// Kept in sync by `AppDelegate` alongside `setService`.
    @Published var isConfigured = false

    @Published var showHistory = false {
        // Closing the recent list (from ANY of its 11+ callsites — fullClose,
        // newChat, collapseHistory, openHistory, settings, submit/submitNote/
        // submitReminder, …) drops any active filter, so reopening always starts on
        // the full unfiltered list. One didSet covers every path atomically.
        didSet {
            if !showHistory {
                historySearchQuery = ""
                showHistoryFilter = false
                historySourceFilter = nil
            }
        }
    }
    /// Whether the compact filter field is expanded below the RECENT header.
    /// Hidden by default so the list stays minimal; toggled from the filter icon.
    /// Cleared automatically when the list closes (see `showHistory`).
    @Published var showHistoryFilter = false
    /// Live substring filter for the recent list. Empty = show everything. Set by the
    /// `HistorySearchField` that appears above the rows once the list is long enough
    /// to need it; cleared automatically when the list closes (see `showHistory`).
    @Published var historySearchQuery = "" {
        // Filtering reshuffles which rows exist, so a stale keyboard highlight could
        // point at a now-hidden (or shifted) row. Release it on every query change;
        // the next ↓ re-selects row 0 of the freshly filtered slice.
        didSet {
            if historySearchQuery != oldValue { highlightedHistoryIndex = nil }
            if !historySearchQuery.isEmpty { noteUserTyping() }
            filteredHistoryCache = nil
            agentFilteredHistoryCache = nil
        }
    }
    /// Source filter for the recent list — `nil` shows everything. Set from the
    /// manage menu's filter chips (Note / Remind / Ask); cleared automatically
    /// when the list closes (see `showHistory`).
    @Published var historySourceFilter: HistoryItem.Source? = nil {
        // Same reasoning as `historySearchQuery`: filtering reshuffles which rows
        // exist, so a stale keyboard highlight could point at a hidden row.
        didSet {
            if historySourceFilter != oldValue { highlightedHistoryIndex = nil }
            filteredHistoryCache = nil
        }
    }
    /// The "What's New" release-notes panel — ⌘↵ (and the input-row cue) flip this.
    /// It owns the notch's idle body while visible; the back chevron / Esc returns
    /// to the prompt.
    @Published var showWhatsNew = false
    /// Arms the destructive "Clear recent history?" confirmation. Lives on the
    /// model (not the view) so the Clear pill can raise it while the centered
    /// confirmation card is mounted on the *island* — so it sits in the middle of
    /// the whole glass panel rather than anchored under the pill near the bottom.
    @Published var confirmingClear = false
    /// The Force Click rung the user picked while macOS's own force-click lookup
    /// is still armed — held here, unapplied, until `ForceClickLookupDialog`
    /// gets an answer. Lives on the model (not `InlineSettingsView`) for the same
    /// reason `confirmingClear` does: the card is mounted on the *island*, so its
    /// scrim covers the whole glass panel instead of stopping at the settings
    /// body's bounds and leaving the panel's padding uncovered.
    @Published var forceClickLookupConflict: ForceClickPressure?
    /// The armed Force Click rung, mirrored so the Settings slider and the dialog
    /// (which now lives outside Settings) read and write one value.
    @Published var forceClickPressure: ForceClickPressure = .current

    /// Arm a rung, or hold it back. macOS's own force-click lookup listens for the
    /// very same press, so with both live a hard click opens the system's
    /// dictionary panel over ours — and there is no API to clear that preference,
    /// only to read it. So when it is on, the rung is held (the slider stays put)
    /// and `ForceClickLookupDialog` hands the user over to System Settings; every
    /// other case applies straight away.
    func selectForceClickPressure(_ newValue: ForceClickPressure) {
        guard newValue != forceClickPressure else { return }
        if newValue.isEnabled, SystemLookupGesture.usesForceClick {
            forceClickLookupConflict = newValue
            return
        }
        applyForceClickPressure(newValue)
    }

    func applyForceClickPressure(_ newValue: ForceClickPressure) {
        forceClickPressure = newValue
        ForceClickPressure.current = newValue
    }
    /// Armed for the length of a confirmed Clear, and read by the recent rows to
    /// pick their removal transition. A single right-click → Delete slides *one*
    /// row out sideways, which reads as "that one, gone"; the same motion played
    /// by five or twelve rows at once reads as a curtain wipe. So a bulk clear
    /// dissolves its rows in place instead and lets the gap close on the spring.
    ///
    /// It has to be a separate beat from the removal: SwiftUI takes a removal
    /// transition from the view's LAST render before it disappears, so setting
    /// this in the same transaction that empties the array would still play the
    /// single-delete slide.
    @Published var bulkClearing = false
    /// The open settings category (raw value of `InlineSettingsView.Section`),
    /// held here rather than as view-local `@State` so it survives panel rebuilds.
    @Published var settingsSection: String = "Model"
    /// Which recent row the keyboard has highlighted while navigating the list
    /// with ↑/↓. `nil` means nothing is highlighted yet — the list may be open
    /// (revealed by mouse) but the caret is still in the input. The first ↓
    /// promotes this to `0`. Indexes into the *visible* slice (`recentVisible`).
    @Published var highlightedHistoryIndex: Int? = nil
    @Published var history: [HistoryItem] = [] {
        // The archive is one of the three inputs of `filteredHistory` — see the
        // cache note there.
        didSet {
            filteredHistoryCache = nil
            agentFilteredHistoryCache = nil
        }
    }

    /// Shell-style ↑/↓ history recall cursor for the idle prompt. `nil` means no
    /// recall session is in flight (the user is editing normally). Once ↑ pulls a
    /// past question into the box this holds the index into `recallQuestions` (the
    /// dedup'd list, NOT raw `history`) that's shown, so a further ↑ steps older and
    /// ↓ steps newer. Any real keystroke resets it to `nil` (see `text.didSet`), so
    /// recall never fights live editing.
    var historyRecallIndex: Int? = nil
    /// Set while `recallPreviousQuestion`/`recallNextQuestion` write `text`
    /// themselves, so the `text.didSet` reset doesn't mistake the recall's own fill
    /// for the user typing and immediately cancel the session.
    var isRecallingText = false
    @Published var recallPulse: (n: Int, dir: RecallDirection) = (0, .older)

    /// Memoized `filteredHistory`, invalidated by the didSets of its only three
    /// inputs (`history`, `historySourceFilter`, `historySearchQuery`). The filter
    /// walks the whole archive — which is unbounded and grows with months of use —
    /// while `recentVisible` is read several times per NotchBody body evaluation,
    /// so without the memo every unrelated re-render re-filtered the full archive.
    var filteredHistoryCache: [HistoryItem]? = nil

    /// Separate because Agent ignores the Ask-side source filter while sharing its
    /// text query. Keeping two caches prevents the standalone archive / Ask ledger
    /// from inheriting Agent's implicit source scope.
    var agentFilteredHistoryCache: [HistoryItem]? = nil

    // MARK: - Archive as context (search_history)

    var ai: AIService
    var task: Task<Void, Never>?
    /// Single-shot model side requests must remain owned until they finish so
    /// entitlement suspension can cancel them along with full answer rounds.
    var promptShortcutNameTasks: [UUID: Task<Void, Never>] = [:]
    var historyTitleTasks: [UUID: Task<Void, Never>] = [:]
    /// Every ask round remains cancellable even after its panel/window detaches.
    /// Normal closes intentionally drop `task`; entitlement suspension must not.
    var activeRoundTasks: [UUID: Task<Void, Never>] = [:]
    /// Detached prompt-shortcut rounds leave the panel's `task` slot so they can
    /// stream headlessly. Keep their handles by thread id so a repeated shortcut
    /// can supersede its previous translation in the same compact window.
    var compactRoundTasks: [UUID: Task<Void, Never>] = [:]
    /// Holds the auto-dismiss timer for the "Saved to Notes" cue so a rapid second
    /// save cancels the first one's fade rather than letting them overlap.
    var noteCueTask: Task<Void, Never>?
    var senseClassifyTask: Task<Void, Never>?
    var senseDismissTask: Task<Void, Never>?
    /// In-flight date detection for the current text — superseded by every
    /// keystroke so only the read of what's actually in the box lands.
    var dueTask: Task<Void, Never>?
    var typedNoteTriggerPrefix: String?
    /// The debounced pending save, so a burst of saves collapses to one write and
    /// the terminate flush can run it early.
    var pendingHistorySave: DispatchWorkItem?
    var hoverDwellTask: Task<Void, Never>?
    var hoverPeekTask: Task<Void, Never>?
    var leaveWatch: LeaveWatch?
    var leaveRecheckTask: Task<Void, Never>?
    /// The legacy UserDefaults key the archive used to live under. Only read for
    /// the one-time migration to the archive file (see `readHistoryFromDisk`);
    /// never written anymore.
    static let historyKey = "notch_history"

    /// Stable id for the conversation currently on screen, so a follow-up updates
    /// the *same* recent-list row instead of inserting a new one each turn. Reset
    /// whenever a fresh thread begins (first question, new chat, reopened item).
    var threadHistoryID = UUID()

    init(ai: AIService = StubAIService()) {
        self.ai = ai
        loadHistoryAsync()
        startClipboardSense()
        refreshAgentSkills()
        // A debounced archive write may still be pending when the user quits;
        // flush it synchronously so a ⌘Q moments after an answer can't lose the
        // newest row.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushHistorySave() }
        }
        // The other half of `rearmPersistedAgentBucket`'s "not yet" rule: it declines
        // to judge a restored bucket while the CLI probes are still in flight, so the
        // moment they land it has to be asked again — otherwise an engine that really
        // did go away would stay armed for the whole session.
        NotificationCenter.default.addObserver(
            forName: .cliAvailabilityResolved, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rearmPersistedAgentBucket() }
        }
    }

    /// Restores the lightweight model observers after a blocked runtime is
    /// successfully licensed again. Initial construction already starts these,
    /// so this is intentionally idempotent.
    func resumeAfterEntitlementRestored() {
        guard senseTimer == nil else { return }
        startClipboardSense()
        refreshAgentSkills()
    }

    /// Stop every model-owned activity at the entitlement boundary, including
    /// rounds whose visible panel or detached window has already gone away.
    func suspendForLicenseBlock() {
        task?.cancel()
        task = nil
        activeRoundTasks.values.forEach { $0.cancel() }
        activeRoundTasks.removeAll()
        compactRoundTasks.values.forEach { $0.cancel() }
        compactRoundTasks.removeAll()
        promptShortcutNameTasks.values.forEach { $0.cancel() }
        promptShortcutNameTasks.removeAll()
        historyTitleTasks.values.forEach { $0.cancel() }
        historyTitleTasks.removeAll()

        selectionContextHintTask?.cancel()
        selectionContextHintTask = nil
        agentSkillsTask?.cancel()
        agentSkillsTask = nil
        leaveRecheckTask?.cancel()
        leaveRecheckTask = nil
        hoverDwellTask?.cancel()
        hoverDwellTask = nil
        hoverPeekTask?.cancel()
        hoverPeekTask = nil
        dueTask?.cancel()
        dueTask = nil
        noteCueTask?.cancel()
        noteCueTask = nil
        thinkingWordTimer?.invalidate()
        thinkingWordTimer = nil
        senseTimer?.invalidate()
        senseTimer = nil
        senseReset()
        senseClassifyTask = nil
        senseDismissTask = nil

        let questionIDs = pendingUserQuestions.map(\.id)
        for id in questionIDs {
            resolveUserQuestion(id, with: .failure(CancellationError()))
        }
        thinking = false
        thinkingAnswerID = nil
        backgroundActivity = nil
        backgroundWriting = false
        open = false
        closing = false
        activeDisplay = nil
    }

    /// Agentic mode owns in-app Chat and Agent work, but not the companion
    /// media, utility, or clipboard services. Toggling it off therefore stops
    /// only outstanding AI work and removes its collapsed-notch activity.
    func suspendForAgenticModeDisabled() {
        task?.cancel()
        task = nil
        activeRoundTasks.values.forEach { $0.cancel() }
        activeRoundTasks.removeAll()
        compactRoundTasks.values.forEach { $0.cancel() }
        compactRoundTasks.removeAll()
        promptShortcutNameTasks.values.forEach { $0.cancel() }
        promptShortcutNameTasks.removeAll()
        historyTitleTasks.values.forEach { $0.cancel() }
        historyTitleTasks.removeAll()
        agentSkillsTask?.cancel()
        agentSkillsTask = nil

        let questionIDs = pendingUserQuestions.map(\.id)
        for id in questionIDs {
            resolveUserQuestion(id, with: .failure(CancellationError()))
        }
        thinking = false
        thinkingAnswerID = nil
        backgroundActivity = nil
        backgroundWriting = false
    }

    deinit {
        senseTimer?.invalidate()
        agentSkillsTask?.cancel()
        promptShortcutNameTasks.values.forEach { $0.cancel() }
        historyTitleTasks.values.forEach { $0.cancel() }
    }

    /// Swap the backend at runtime — used when the user saves an API key in
    /// Settings, so the next question goes live without an app restart.
    func setService(_ service: AIService) {
        ai = service
    }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - Clipboard sense (copy → hint on the resting notch → ⌘C again to file)
    @Published var clipboardSense: ClipboardSense = .idle

    /// Whether the resting notch watches the clipboard at all (Settings → Tools).
    /// OFF by default: an unrequested "To Save ⌘C" offer appearing on the resting
    /// notch after an ordinary copy reads as the notch interrupting, not helping.
    /// Turning it off tears down any visible hint immediately. The in-panel
    /// capture chip is unaffected — this only governs the closed-notch
    /// pre-sensing.
    @Published var copySenseEnabled: Bool =
        UserDefaults.standard.object(forKey: NotchModel.copySenseKey) as? Bool ?? false
    {
        didSet {
            UserDefaults.standard.set(copySenseEnabled, forKey: NotchModel.copySenseKey)
            if !copySenseEnabled { senseReset() }
        }
    }

    /// Whether the resting notch can show previews (Settings → Appearance,
    /// "Live activity"). Turning it off keeps the closed notch clear. The
    /// finished-count badge, agent card, and completion notification are
    /// unaffected.
    @Published var liveActivityEnabled: Bool =
        UserDefaults.standard.object(forKey: NotchModel.liveActivityKey) as? Bool ?? true
    {
        didSet {
            UserDefaults.standard.set(liveActivityEnabled,
                                      forKey: NotchModel.liveActivityKey)
        }
    }

    /// Whether the assistant's answers are written by hand instead of typeset
    /// (Settings → Appearance, "Handwritten answers"). Off by default — the
    /// printed voice stays the thing you get without asking.
    ///
    /// Scope is deliberately narrow: the assistant's own prose, and nothing else.
    /// The question you typed, the interface around it, notes, code blocks and
    /// every copied string are untouched, so the mode changes how the answer
    /// *reads* and never what it *is*. See `Handwriting`.
    @Published var handwrittenAnswers: Bool =
        UserDefaults.standard.bool(forKey: Handwriting.defaultsKey)
    {
        didSet {
            UserDefaults.standard.set(handwrittenAnswers, forKey: Handwriting.defaultsKey)
        }
    }

    /// The proxy Notch connects through (Settings → General) — the app's own
    /// requests and the spawned agent CLIs alike. Empty means auto — the app
    /// follows the system proxy natively, and `ProxyConfig` walks the CLIs through
    /// the inherited env, the system proxy, then the login shell. Storage and
    /// resolution live in `ProxyConfig`; this only publishes the field the
    /// settings row binds to.
    @Published var proxyURL: String = ProxyConfig.manual {
        didSet { ProxyConfig.manual = proxyURL }
    }
    @Published var customInstructions: String =
        UserDefaults.standard.string(forKey: NotchModel.customInstructionsKey) ?? ""
    {
        didSet {
            // Enforce the cap defensively (the field also limits input) and persist.
            if customInstructions.count > NotchModel.customInstructionsLimit {
                customInstructions = String(customInstructions.prefix(NotchModel.customInstructionsLimit))
                return   // the reassignment re-enters didSet, which persists
            }
            UserDefaults.standard.set(customInstructions, forKey: NotchModel.customInstructionsKey)
        }
    }

    var senseTimer: Timer?
    /// The last `changeCount` the watcher has accounted for. While the panel is
    /// open every tick just re-syncs this, so copies made in-session (including
    /// Notch's own pasteboard writes) can never read as new once the panel closes.
    var senseLastChangeCount = NSPasteboard.general.changeCount
    /// The clip the current hint is about — a re-copy must match it exactly.
    var senseClip: String?
    /// When the current hint appeared (the `senseMinReaction` anchor).
    var senseHintShownAt: Date?
    /// The clip a sense confirm has (or is currently) filing — suppresses both a
    /// re-hint and the in-panel capture chip for the same text, so one copied line
    /// can't be filed twice. Cleared if the write fails (the chip then returns as
    /// the retry path — the text is still safe in the clipboard).
    var senseCapturedClip: String?
    /// True once a read was attempted while the system's pasteboard-privacy state
    /// is `ask`/`default` (macOS 15.4+). One attempt lets the system surface its
    /// access alert so the user can decide; after that the watcher stays quiet
    /// until Settings says always-allow, instead of prompting on every copy.
    var senseAskAttempted = false

    // MARK: - Agent to Codex (XII: agent-to-Codex)

    /// One-shot model override for the NEXT `submit()` (XII-135): a "regenerate
    /// with X" pick sets this, `submit()` reads and clears it, builds a service
    /// pinned to X for just that turn, and stamps the answer with X — without ever
    /// touching the user's saved default. Nil for every normal submit.
    var regenOverrideModel: String?

    /// The provider half of that override, set only when the pick names a backend
    /// other than the selected one (a prompt shortcut's cross-provider pin). Nil
    /// means "the selected provider", which is every regenerate-with pick.
    var regenOverrideProvider: Provider?

    /// Shared tail of retry/regenerate: drop the newest Q/A pair, lift the question
    /// back into the input, and re-run `submit()` so a fresh answer streams into a
    /// clean pair. No-op when there's no question to re-run. A non-nil `model` runs
    /// this one regeneration on that model only (XII-135).
    func resubmitLastQuestion(model: String? = nil) {
        guard let lastUser = turns.last(where: { $0.role == "user" }) else { return }
        let question = lastUser.text
        if turns.last?.role == "assistant" { turns.removeLast() }
        if turns.last?.role == "user" { turns.removeLast() }
        regenOverrideModel = model
        text = question
        submit()
    }

    // MARK: - History images

    /// True once the launch load has merged the on-disk archive into `history`.
    /// Saves that fire before that (a capture seconds into a launch) are deferred:
    /// writing then would snapshot ONLY the new items, and a crash before the
    /// merge would replace the whole archive with them.
    var historyLoaded = false
    var historySaveDeferred = false
    /// A Chat clear can race the launch-time history read. Once armed, it owns only
    /// Ask / Notes / Reminders rows at or after its cutoff; Agent remains intact.
    var chatHistoryClearedBeforeLoad: Date?
    /// Agent counterpart to `chatHistoryClearedBeforeLoad`.
    var agentHistoryClearedBeforeLoad = false
}

/// Relative time strings ("just now", "12m ago"…) matching the prototype.
func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return L("time.justNow") }
    if s < 3600 { return L("time.minutesAgo", s / 60) }
    if s < 86400 { return L("time.hoursAgo", s / 3600) }
    return L("time.daysAgo", s / 86400)
}

/// A settled record's wall-clock completion stamp for the answer footer — the
/// time on its own when it finished today, month·day·time once it's older (year
/// dropped either way). Locale-aware (24h vs AM/PM follows the system), kept short
/// so it sits in the footer's quiet toolbar. The full date lives in the tooltip.
func completionStamp(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}
