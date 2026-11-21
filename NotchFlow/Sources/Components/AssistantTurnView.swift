import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// The whole life of an assistant turn — the pre-stream wait, the answer
/// streaming in, and the settled answer — in ONE view, so nothing structural
/// swaps underneath the answer when the stream ends.
///
/// Why one view: the answer used to render through `StreamingMarkdown` while
/// streaming and then get replaced by a plain `MarkdownBlocks` once settled.
/// That swap re-built the whole subtree from a new identity, and the sub-pixel
/// difference between the two layouts hard-cut the answer ~2pt up-left at
/// completion. Here the answer is ALWAYS the same
/// `MarkdownBlocks` — streaming just keeps feeding it more `text` and it reflows
/// in place; settling only flips `textSelection` on the unchanged tree, which
/// causes no rebuild and no jump.
///
/// The wait state (mood word / tool-activity line) rides as an `.overlay`, never
/// a layout sibling: it fades out as the first real text lands and fades back in
/// between agent rounds, but because it's an overlay it has zero footprint on the
/// answer's own layout — so it can never push the answer around. The overlay also
/// keeps a layer mounted across every fade, so there's no frame where the slot is
/// momentarily empty between questions.
struct AssistantTurnView: View {
    let text: String
    /// Still in flight. Gates the wait overlay and holds the source badge back
    /// until the answer settles (so it doesn't jump as rounds add sources).
    var streaming: Bool = false
    /// The live tool-activity line ("Searching the web…") when a tool is running,
    /// else nil — takes the wait slot over the mood word while present.
    var activity: String? = nil
    /// The thinking orb's semantic mode for the wait line — rides the same
    /// harness signal as `activity` (see `NotchModel.thinkingOrbState`), so the
    /// orb and the words always agree. Defaults to the calm thinking ribbon.
    var orbState: OrbState = .composing
    /// The present-progressive mood word for the pre-stream wait (e.g. "Gazing…").
    var thinkingWord: String = ""
    /// When this round started thinking — drives the quiet elapsed-time suffix on
    /// the wait line (only surfaces past its threshold; see `WaitElapsedSuffix`).
    var thinkingSince: Date? = nil
    var sources: [WebSource] = []
    @Binding var hoveredSourceID: UUID?
    @Binding var sourceCloseWork: DispatchWorkItem?
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    /// This turn is an agent run's report (reopened agent session). Its footer drops
    /// the "Copy as plain text" action — an agent report is copied as Markdown only.
    var isAgent: Bool = false
    /// When this agent report's run finished — the reopened record's own timestamp.
    /// Non-nil only on a settled agent report turn; renders as a quiet completion
    /// stamp at the end of the footer. `nil` (no stamp) for ordinary chat answers.
    var completedAt: Date? = nil
    /// Whether this answer surface carries the full action row.
    var showsFooter: Bool = true
    /// Show the footer from the answer's first text instead of waiting for the
    /// request to settle. The compact pointer-side card runs this way: its window
    /// sizes itself to its content, so a footer that appeared only at settle would
    /// add its height after the fact and land below the fold while the AppKit
    /// frame animation caught up. Present from the first token, it is simply part
    /// of the stack the window is measured from. Regenerate stays disabled until
    /// cleanup ends either way.
    var stabilizesFooterWhileStreaming: Bool = false
    /// Keep the model info and agent completion stamp in the footer. The main
    /// panel's agent report moves those two pieces into the command chip beside
    /// its follow-up composer; detached threads keep the original footer metadata.
    var showsFooterMetadata: Bool = true
    var onInAppCopy: (() -> Void)? = nil
    /// Re-run this answer's question for a fresh take. Non-nil only on the LAST
    /// assistant turn — regenerating a mid-thread answer would orphan everything
    /// after it, so earlier turns never offer it.
    var onRegenerate: (() -> Void)? = nil
    /// The models offered by the regenerate button's right-click menu (XII-135) —
    /// each with whether it's the one currently in effect (greyed as "current").
    /// Empty ⇒ no menu (just the plain left-click regenerate).
    var regenerateModels: [(model: String, isCurrent: Bool)] = []
    /// Regenerate this answer with a specific model, once (XII-135).
    var onRegenerateWith: ((String) -> Void)? = nil
    /// The model this answer was regenerated with, when it wasn't the default
    /// (XII-135) — shown as a small caption so the answer says which model made it.
    var regenModel: String? = nil
    /// The concrete model the provider actually ran, echoed back in the stream —
    /// the real reply behind the `openrouter/free` auto-router. When present it
    /// takes precedence over `regenModel` in the footer caption, shown as a bare
    /// model name (vendor prefix and `:free` suffix stripped).
    var answerModel: String? = nil
    /// A clarifying question the model posed via the `ask_user` tool, still
    /// waiting on the user — renders as an option card under the (possibly still
    /// empty) answer. Non-nil only while this turn streams.
    var pendingQuestion: NotchModel.PendingUserQuestion? = nil
    /// The user tapped an option on the question card: (question id, option text).
    var onChooseOption: ((UUID, String) -> Void)? = nil

    /// One opacity beat, shared by the wait-overlay fade so the handoff reads as
    /// part of the same calm rhythm rather than a separate flourish.
    private static let fade: Double = 0.18

    /// The footer's "which model made this" caption. Prefers the concrete model
    /// the provider actually ran (`answerModel`, shown as a bare name), and falls
    /// back to the regenerate-with pick (`regenModel`, shown verbatim — it's the
    /// user's own choice). `nil` when neither is set, so a plain default answer
    /// carries no caption.
    static func footerModelCaption(answerModel: String?, regenModel: String?) -> String? {
        if let answerModel, !answerModel.isEmpty { return bareModelName(answerModel) }
        return regenModel
    }

    /// A model id reduced to its bare name for display: drop the vendor prefix
    /// (everything up to and including the last `/`) and the `:free` suffix.
    /// `openai/gpt-oss-20b:free` → `gpt-oss-20b`, `openrouter/free` → `free`.
    static func bareModelName(_ id: String) -> String {
        var s = id
        if let slash = s.lastIndex(of: "/") { s = String(s[s.index(after: slash)...]) }
        if s.hasSuffix(":free") { s = String(s.dropLast(":free".count)) }
        return s.isEmpty ? id : s
    }

    /// True while the cursor is anywhere over this turn (answer text or footer).
    /// Drives the footer's island-hover: the action icons rest nearly invisible
    /// and surface together as one toolbar when the cursor enters the answer,
    /// instead of each icon lighting up on its own.
    @State private var turnHovered = false

    /// While the "Reading the results…" cue is up, the page titles are walked one
    /// at a time on a timer rather than snapping to the latest. A search round
    /// hands back all its sources at once, so without a paced walk the line would
    /// jump straight to the last title and every page before it would flash past
    /// unread. `readingIndex` is which source is currently shown; the timer below
    /// advances it, holding each title for `readingDwell` before the next.
    @State private var readingIndex = 0

    /// The rotation clock. A Combine timer publisher (not a hand-rolled `Timer` +
    /// `RunLoop.add`): `.onReceive` runs its closure in the *current* view context,
    /// so bumping `readingIndex` re-renders correctly. The earlier hand-rolled
    /// `Timer` captured a stale `self`, so its `readingIndex += 1` wrote to an
    /// orphaned `@State` box that never drove a re-render — the line looked frozen
    /// on the first host. `.autoconnect()` starts it on subscribe; we gate the tick
    /// on `isReading` so it only advances while the read cue is actually up.
    private let readingClock = Timer.publish(every: Self.readingDwell, on: .main, in: .common)
        .autoconnect()

    /// How long each host stays on the line before rotating to the next. Kept
    /// unhurried on purpose: each address should sit long enough to actually read,
    /// not flick past. The trade-off is that the post-search "reading" window is
    /// short (the model often starts answering within a beat, which clears the cue),
    /// so a long dwell means only the first host or two are seen before the answer
    /// takes over — but a readable pace matters more than walking the whole list.
    private static let readingDwell: TimeInterval = 1.2

    /// True exactly while the post-search read cue is on screen — the window in
    /// which page titles should rotate. Drives both `waitLine` and the timer.
    private var isReading: Bool {
        streaming && activity == L("agent.activity.composing") && !sources.isEmpty
    }

    /// Whether the answer currently has visible text. Trimmed, not a bare
    /// `!text.isEmpty`: GLM/Kimi open an agent turn with a lone `"\n"` content
    /// chunk *before* requesting a tool, so a raw emptiness check flips true on
    /// that newline and would hide the wait while the real answer is still a
    /// tool-round away. Treating whitespace-only as empty keeps the wait lit until
    /// genuine answer text lands. Re-evaluated live (not latched) so the wait
    /// comes back whenever the answer is momentarily empty again between rounds.
    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Show the wait overlay while streaming with no visible answer yet. The wait
    /// yields the INSTANT real text lands — no grace period: the line renders on
    /// top of the answer (it's an overlay), so any hold past the first tokens
    /// double-exposes the two texts (the old `readingHold` kept a host name over
    /// the streaming answer for up to a dwell). A host mid-glance just dissolves
    /// into the answer on the shared fade. Suppressed while an `ask_user`
    /// question card is up: the card IS the wait state then, and a "Waiting for
    /// your choice…" line above it would just say it twice.
    private var showWait: Bool { streaming && !hasText && pendingQuestion == nil }

    /// The mid-answer activity row. Once real text lands, `showWait` is off for
    /// good — but a tool can still be running under that text (the model spoke a
    /// preface, then searched), and hiding every cue there is what made a turn
    /// read as stalled mid-search. Whenever a live activity exists past the first
    /// text, it gets its OWN row under the growing answer instead of the overlay.
    /// Gated on `activity` (not `waitLine`) so the mood-word fallback never rides
    /// along — a plain streaming answer keeps its clean, indicator-free look.
    /// Suppressed under an `ask_user` card exactly like `showWait` (the card is
    /// the wait state then).
    private var showActivityRow: Bool {
        streaming && hasText && activity != nil && pendingQuestion == nil
    }

    /// A compact answer's toolbar follows the renderer's own completion edge, not
    /// request cleanup. Every other surface preserves settled-only behavior.
    private var footerIsVisible: Bool {
        !streaming || stabilizesFooterWhileStreaming
    }

    /// The distinct hosts to walk through, in first-seen order. `sources` is the
    /// URL-deduped list accumulated across *all* search rounds, so a later round
    /// that pulls a different page of a site already shown (a fresh URL, same host)
    /// would otherwise make the line read out that host a second time. Collapsing
    /// to distinct hosts here means each site is walked once no matter how many of
    /// its pages land across rounds — the line only ever advances to a genuinely
    /// new address. If every result is the same host, this is just that one host
    /// (nothing to switch to), which is the intended "unless they're all the same"
    /// fallback.
    private var readingHosts: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in sources where seen.insert(s.host).inserted { out.append(s.host) }
        return out
    }

    /// The single string the wait line shows, so the slot is always ONE line that
    /// crossfades in place — never a label stacked over a sub-line. While the
    /// post-search "Reading the results…" cue is up and we have a source, the line
    /// *becomes* the page being read right now ("Reading tmtpost.com" — the page's
    /// host, not its title or snippet) rather than the generic cue — naming the
    /// address it's reading, in the same slot. Otherwise it's the live activity
    /// line, or the mood word. nil = nothing to show.
    private var waitLine: String? {
        if isReading, !readingHosts.isEmpty {
            // Walk the DISTINCT hosts. The clock bumps `readingIndex` unbounded;
            // the modulo maps it onto the live distinct-host list (read fresh every
            // render, so hosts from a newer round are included), wrapping back to
            // the first once it has walked them all.
            return L("agent.activity.readingPage", readingHosts[readingIndex % readingHosts.count])
        }
        if let activity { return activity }
        return thinkingWord.isEmpty ? nil : thinkingWord
    }

    /// The one wait row — orb, crossfading line, elapsed suffix — shared by the
    /// pre-text overlay and the mid-answer activity row, so the two states render
    /// identically and hand off without a visual seam.
    private func waitRow(_ line: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ThinkingOrb(state: orbState)
                .centeredOnTextGlyphs(fontSize: baseFont)
            // Word and timer sit on ONE shared baseline. Centering them (the
            // HStack default) doesn't align text of two different sizes: the
            // smaller suffix's baseline lands ~0.5pt above the word's — a whole
            // retina pixel of visible float right beside it. The orb rides the
            // same baseline, optically centred on the glyphs.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CrossfadeText(text: line, font: baseFont, color: Tokens.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // The elapsed suffix sits OUTSIDE the dissolving word (a sibling,
                // fixed size) so the ticking seconds never ride the word-change
                // transition, and a long activity line truncates while the timer
                // stays visible.
                WaitElapsedSuffix(since: thinkingSince, font: baseFont)
                    .fixedSize()
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading,
               spacing: pendingQuestion != nil && !hasText ? 0 : 6) {
            // The answer — the SAME view whether streaming or settled, so the
            // stream→settle edge never rebuilds it. While streaming it reflows in
            // place as `text` grows; once settled it's identical but selectable.
            // Selection stays ENABLED the whole time — including while streaming —
            // on purpose. Toggling `.textSelection` at stream-end would swap between
            // its two distinct modifier types (`Enabled`/`Disabled…`), changing the
            // view's identity and re-introducing exactly the rebuild-jump this unified
            // view exists to kill. A constant `.enabled` keeps one identity throughout,
            // so the answer just reflows in place and never jumps. (The earlier reason
            // to disable mid-stream — the tail-follow `scrollTo` collapsing a drag —
            // only bites in the long, clipped/scrolling layout; the jump-free guarantee
            // matters more, and most answers are short and never scroll.)
            MarkdownBlocks(source: text, baseFont: baseFont, color: color,
                           onInAppCopy: onInAppCopy, streamingTail: streaming)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                // Reserve a line's worth of height while the answer is still empty
                // so the wait overlay has somewhere to sit and the bubble doesn't
                // pop from zero-height to one-line when the first token lands.
                .frame(minHeight: showWait ? baseFont * 1.6 : 0, alignment: .leading)
                // A choice card replaces the pre-answer wait completely. The empty
                // Markdown renderer otherwise keeps an intrinsic line box even
                // though its source is empty, leaving a conspicuous blank band
                // between the user bubble and the card.
                .frame(height: pendingQuestion != nil && !hasText ? 0 : nil,
                       alignment: .topLeading)
                .clipped()
                // The pre-stream wait: mood word, or the tool-activity line while a
                // tool runs. An overlay (not a sibling) so it never shifts the
                // answer; both layers stay mounted and cross-fade on their own
                // opacity, so the slot is never blank between rounds.
                .overlay(alignment: .topLeading) {
                    // ONE line, crossfading in place: mood word → "Searching…" →
                    // the page title it's reading → next page. Never two stacked
                    // layers — `waitLine` folds all of those into a single string
                    // so the slot just dissolves from one to the next.
                    Group {
                        if let waitLine {
                            waitRow(waitLine)
                        }
                    }
                    .opacity(showWait ? 1 : 0)
                    .allowsHitTesting(false)
                }

            // The mid-answer activity row (see `showActivityRow`): the same wait
            // row, but as a SIBLING under the growing text — an overlay would sit
            // on top of the answer. It appears only while a tool is actually
            // running past the first text ("Searching the web…" under a spoken
            // preface), and dissolves when the tool clears and the answer resumes.
            if showActivityRow, let waitLine {
                waitRow(waitLine)
                    // Clear the paragraph's OWN leading. Body text runs at
                    // `lineSpacing(baseFont * 0.45)` ≈ 7pt between its lines, so
                    // at the stack's bare 6pt this row sat tighter than the prose
                    // it follows and read as one more line of that paragraph
                    // rather than a separate status row. 12pt puts clear air
                    // between the spoken preface and the tool cue under it.
                    .padding(.top, 6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            // The `ask_user` question card: the model has paused this answer to ask
            // the user a multiple-choice question and is suspended until they pick
            // (or the wait times out). Only while streaming — a settled turn can't
            // be waiting on anyone.
            if streaming, let pendingQuestion {
                UserQuestionCard(question: pendingQuestion) { option in
                    onChooseOption?(pendingQuestion.id, option)
                }
                .padding(.top, hasText ? 2 : 0)
                .transition(.opacity)
            }

            // Answer footer: the source badge (when web-grounded, XII-118) plus a
            // quiet toolbar of answer actions — copy · regenerate · continue in
            // ChatGPT/Claude — in one row under the answer. Info on the left,
            // actions in escalating order (take it → redo it → leave with it).
            // Most surfaces wait for request settlement. A compact pointer-side
            // answer shows the row from its first text; regenerate remains disabled
            // until request cleanup ends. The icons share `turnHovered`.
            if showsFooter
                && (!streaming || stabilizesFooterWhileStreaming)
                && (hasText || !sources.isEmpty) {
                // Optically align the row's left edge with the answer text above
                // it. When a bare icon leads, its 11pt glyph sits centered in a
                // 22pt hit-frame, so it rests ~5pt inset from x=0 — the row reads
                // as indented past the text. Pull the row back by that inset so
                // the first glyph lands on the text's left edge. A leading source
                // badge is a bounded pill whose capsule is already flush at x=0,
                // so it needs no shift.
                let leadInset: CGFloat = sources.isEmpty ? -5 : 0
                // The same story vertically, and it's why this row crowded the
                // answer exactly when it was web-grounded: a bare icon's 11pt
                // glyph is centered in a 22pt hit-frame, so an icon-led row
                // already carries ~5pt of air above the glyph, while a leading
                // source badge is a flush capsule that carries none. The gap read
                // ~13pt without sources and a cramped 8pt with them. Pay the badge
                // case that difference so the footer sits the same distance under
                // the answer either way.
                let leadTop: CGFloat = sources.isEmpty ? 2 : 7
                HStack(spacing: 2) {
                    if !sources.isEmpty {
                        SourceBadge(sources: sources,
                                    hoveredID: $hoveredSourceID,
                                    pendingClose: $sourceCloseWork)
                            .padding(.trailing, 6)
                    }
                    if hasText {
                        // Copy the answer verbatim — markdown syntax intact
                        // (headings, `**bold**`, lists, code fences). The paired
                        // plain-text button below strips that formatting.
                        AnswerFooterButton(icon: "doc.on.doc",
                                           help: shortcutHelp("result.copyMarkdown",
                                                              action: .copyAnswer),
                                           rowHovered: turnHovered,
                                           confirms: true) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                text.trimmingCharacters(in: .whitespacesAndNewlines),
                                forType: .string
                            )
                            onInAppCopy?()
                        }
                        // Copy with every markdown mark removed — plain prose for
                        // pasting into fields that don't render markdown. Skipped on
                        // an agent report (the detail page copies as Markdown only).
                        if !isAgent {
                            AnswerFooterButton(icon: "text.alignleft",
                                               help: L("result.copyPlainText"),
                                               rowHovered: turnHovered,
                                               confirms: true) {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    MarkdownParser.plainText(text)
                                        .trimmingCharacters(in: .whitespacesAndNewlines),
                                    forType: .string
                                )
                                onInAppCopy?()
                            }
                        }
                    }
                    if let onRegenerate {
                        AnswerFooterButton(icon: "arrow.clockwise",
                                           help: shortcutHelp(
                                               regenerateModels.isEmpty
                                                   ? "result.regenerate"
                                                   : "result.regenerate.menu",
                                               action: .regenerate),
                                           rowHovered: turnHovered) {
                            onRegenerate()
                        }
                        // Right-click → pick a model for a one-shot regenerate
                        // (XII-135). Left-click stays "regenerate with the same
                        // model". The current model is shown greyed + disabled.
                        .contextMenu {
                            if !regenerateModels.isEmpty, let onRegenerateWith {
                                Text(L("result.regenerate.with"))
                                ForEach(regenerateModels, id: \.model) { option in
                                    Button {
                                        onRegenerateWith(option.model)
                                    } label: {
                                        if option.isCurrent {
                                            Text(L("result.regenerate.current", option.model))
                                        } else {
                                            Text(option.model)
                                        }
                                    }
                                    .disabled(option.isCurrent)
                                }
                            }
                        }
                        .disabled(streaming)
                    }
                    // The model that produced this answer — an ⓘ glyph whose
                    // tooltip is the model name. Prefer the concrete model the
                    // provider actually ran (the real reply behind
                    // `openrouter/free`), shown as a bare name; fall back to the
                    // regenerate-with pick when none was reported.
                    if showsFooterMetadata,
                       let caption = Self.footerModelCaption(answerModel: answerModel,
                                                             regenModel: regenModel) {
                        AnswerFooterButton(icon: "info.circle",
                                           help: caption,
                                           rowHovered: turnHovered) {}
                    }
                    // When the run finished — the settled agent report's completion
                    // stamp. A quiet caption (not a button): the wall-clock time on
                    // its own today, month·day·time once older, in the same
                    // hover-reveal rhythm as the action icons. Its tooltip carries
                    // the full date. Only on agent reports (`completedAt` is nil for
                    // chat answers).
                    if showsFooterMetadata, let completedAt {
                        Text(completionStamp(completedAt))
                            .font(.sf(11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Tokens.text4)
                            .padding(.leading, 5)
                            .opacity(turnHovered ? 0.9 : 0.4)
                            .animation(.easeOut(duration: 0.18), value: turnHovered)
                            .notchTooltip(L("result.completedAt",
                                            completedAt.formatted(date: .abbreviated,
                                                                  time: .shortened)))
                    }
                }
                .padding(.leading, leadInset)
                .padding(.top, leadTop)
                .opacity(footerIsVisible ? 1 : 0)
                .allowsHitTesting(footerIsVisible)
                .accessibilityHidden(!footerIsVisible)
                // No transition: the final text and this opacity land together.
                .animation(nil, value: footerIsVisible)
            }
        }
        .onHover { turnHovered = $0 }
        .animation(.easeInOut(duration: Self.fade), value: showWait)
        .animation(.easeInOut(duration: Self.fade), value: showActivityRow)
        .animation(.easeInOut(duration: 0.12), value: activity != nil)
        // The question card fades in when the model asks and out when the pick (or
        // timeout) releases the round — same beat as the wait overlay's fade.
        .animation(.easeInOut(duration: Self.fade), value: pendingQuestion)
        // A clock tick means the host on the line has had its full dwell — advance
        // to the next one so each host occupies exactly one dwell while the cue
        // is up. (No hold once the answer starts: the wait yields immediately.)
        .onReceive(readingClock) { _ in
            guard isReading else { return }
            readingIndex += 1
        }
        // Each time the read cue opens, restart the walk from the first host so a
        // new search begins fresh rather than continuing a stale offset.
        .onChange(of: isReading) { _, reading in
            if reading { readingIndex = 0 }
        }
    }
}
