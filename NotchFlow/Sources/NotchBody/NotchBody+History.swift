import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    // MARK: - Immersive history

    /// The immersive recent layout: a tall scroll surface with the prompt floating
    /// over its top as a translucent header. The list's content reaches up behind
    /// the header (`immersiveTopReach`), so rows scroll under the input and frost +
    /// fade out rather than ending on a hard cut — the panel reads as one
    /// continuous surface. The manage bar (the ⋯ chip at bottom-left, the Recent
    /// chevron at bottom-right) FLOATS across the bottom as fixed chrome: the list
    /// runs full-height *behind* it, so rows can scroll down past the buttons and
    /// stay partly visible through/around the glass.
    var immersiveHistoryView: some View {
        ZStack(alignment: .top) {
            historyList(immersive: true)
        }
            .overlay(alignment: .top) {
                // Front: the floating header — NO background of its own. The glass
                // shell must read identically whether the panel is collapsed or
                // expanded, so the prompt sits directly on the same translucent
                // material as the resting state. Legibility of the rows passing
                // behind comes entirely from the list's own top fade + blur (see
                // `historyList(immersive:)`).
                VStack(alignment: .leading, spacing: 0) {
                    // A pending copied-image preview rides INSIDE the floating
                    // header, above the prompt. The runway (`immersiveTopReach`,
                    // measured from this header's real height) grows to keep the
                    // first row clear. Same slot swap as the flat layout: an
                    // active agent compose shows its pasted attachment instead.
                    if let selection = model.selectionContext {
                        selectionContextLine(selection)
                            .padding(.bottom, 8)
                    } else if model.selectionContextHintShown {
                        selectionContextHintLine
                            .padding(.bottom, 8)
                    }
                    if model.agentComposeActive {
                        if !model.agentComposeImages.isEmpty {
                            ComposeImagesAttachedLine(images: model.agentComposeImages) {
                                model.removeAgentComposeImage(at: $0)
                            }
                            .padding(.bottom, 8)
                        }
                    } else if !model.askComposeImages.isEmpty {
                        ComposeImagesAttachedLine(images: model.askComposeImages) {
                            model.removeAskComposeImage(at: $0)
                        }
                        .padding(.bottom, 8)
                    }
                    idleInputRow
                    // The bucket row rides the immersive header too — but only while
                    // it still carries something (an active compose). The destination
                    // pill and the Recent chevron both leave it once the list is up,
                    // and an empty row would just pad the header.
                    if bucketRowHasContent {
                        bucketRow
                    }
                    // Agent status rows do NOT ride the header — they scroll with the
                    // recent list as its newest rows (see `historyList(immersive:)`),
                    // so a running task isn't pinned over the top of the scroll.
                }
                .padding(.bottom, 6)
                // Measure the header's real height so runway/frost track it.
                // A header with a preview is taller than a bare input; the preference feeds
                // measuredImmersiveHeaderHeight so immersiveTopReach adapts.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: ImmersiveHeaderHeightKey.self, value: geo.size.height
                        )
                    }
                )
            }
            .onPreferenceChange(ImmersiveHeaderHeightKey.self) { h in
                let measured = max(h, NotchBody.immersiveHeaderBaseline)
                if didMeasureImmersiveHeader {
                    // A later change (preview appearing/clearing) slides the runway
                    // so the list shifts smoothly rather than snapping.
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        measuredImmersiveHeaderHeight = measured
                    }
                } else {
                    // First measurement of this open: land it silently. Animating
                    // here forces an animated second layout pass that stalls the
                    // expand start.
                    didMeasureImmersiveHeader = true
                    measuredImmersiveHeaderHeight = measured
                }
            }
            // Fixed bottom chrome: the ⋯ chip and the Recent chevron, FLOATING over the
            // bottom corners of the full-height list. Because it's an overlay (not a sibling), the list runs
            // its whole height behind it — rows scroll down past the buttons and stay
            // partly visible through/around the translucent glass capsules. The glass
            // material gives the buttons enough body to stay legible over moving rows.
            .overlay(alignment: .bottom) {
                // Pull the bar tighter into the bottom corners than the body's
                // uniform 15pt inset would leave it: negative padding lands it 10pt
                // from each edge — the same 10 left and right, so the ⋯ and the
                // Recent chevron end up equidistant from their own panel edge —
                // still clear of the 30pt NotchShape corner arc at the bar's height.
                manageBar
                    .padding(.horizontal, -5)
                    .padding(.bottom, -5)
            }
            .transition(moduleTransition)
    }

    /// The two end-of-list actions — "See all history" (the standalone archive
    /// window, holding everything past `NotchModel.notchRecentCap`) and the
    /// destructive Clear. They live at the tail of the scroll content, not in the ⋯
    /// menu: you meet them only after scrolling past the oldest row, which is
    /// precisely the moment "show me everything" or "wipe this" becomes the next
    /// move. A fading hairline above them marks where the list ends.
    ///
    /// Agent mode drops Clear entirely — an agent row is a run's only record
    /// (its folder, its log, its resume handle), so a one-tap wipe at the end of
    /// the task list isn't an action that belongs there.
    @ViewBuilder
    private var historyFooterActions: some View {
        let showsSeeAll = model.recentScopeHistoryCount > NotchModel.notchRecentCap
        let showsClear = !model.agentComposeActive
        if showsSeeAll || showsClear {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0), .white.opacity(0.12), .white.opacity(0)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 0.5)

            HStack(spacing: 8) {
                // "See all history" earns its place only once the archive holds MORE
                // than the notch list can show — i.e. older items have been truncated
                // past `notchRecentCap`. When everything still fits, the archive window
                // would open onto the exact same rows already on screen, so the button
                // is pure redundancy and we drop it (Clear stays — it's always apt).
                if showsSeeAll {
                    HistoryFooterButton(
                        icon: "clock.arrow.circlepath",
                        title: L("recent.menu.seeAll")
                    ) {
                        // Fold the expanded recent list back to the compact prompt as
                        // the standalone archive takes over. Otherwise the still-open
                        // list floats above the newly centered History window and its
                        // top gets covered — and it's redundant, since the archive now
                        // holds everything. Same spring as the list's open/close.
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                            _ = model.collapseHistory()
                        }
                        NotificationCenter.default.post(
                            name: .openHistoryArchiveRequested,
                            object: nil,
                            userInfo: [
                                "scope": model.agentComposeActive
                                    ? HistoryArchiveScope.agent.rawValue
                                    : HistoryArchiveScope.chat.rawValue
                            ]
                        )
                    }
                }
                // Destructive, so it arms the confirmation instead of wiping on the
                // first tap. The confirm card renders centered over the whole island
                // (see NotchIsland), not anchored to this pill.
                if showsClear {
                    HistoryFooterButton(
                        icon: "trash",
                        title: L("recent.clear")
                    ) {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                            model.confirmingClear = true
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.top, 10)
        .padding(.horizontal, 8)
        }
    }

    /// The compact recent list (≤6 visible rows) with the manage bar (the ⋯ chip)
    /// pinned at the BOTTOM-LEFT below the list rows — matching the immersive layout.
    /// The open animation moves the whole block together via the moduleTransition at
    /// the call site (which also supplies the 12pt gap above the list).
    var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Live filter — hidden behind the filter icon by default. Only shown
            // once the list is long enough to be worth searching (matches historyList's
            // own > 6 overflow calibration) AND the user has explicitly expanded it.
            // The field spans the section width so its text aligns with the list rows
            // below, and its vertical padding is kept tight since it's a revealed
            // secondary control.
            if model.recentScopeHistoryCount > 6, model.showHistoryFilter {
                HistorySearchField(
                    text: $model.historySearchQuery,
                    placeholder: L("recent.filter"),
                    fontSize: 12,
                    focusTrigger: filterFocused
                )
                .frame(height: 18)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                )
                .padding(.bottom, 4)
                .transition(.opacity)
                .onAppear {
                    // The field is summoned with ⌘F (ContentView's key catcher flips
                    // showHistoryFilter). It only mounts once that's true, so grabbing
                    // focus on appear lands the caret without a click. The tiny delay
                    // lets SwiftUI finish inserting the field before the focus grab.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        filterFocused = true
                    }
                }
                .onChange(of: model.showHistoryFilter) { _, showing in
                    if !showing { filterFocused = false }
                }
            }

            historyList()

            // Manage bar below the list rows — bottom-left, matching the immersive
            // layout. The .padding(.top, 12) at the historySection call site in
            // idleView supplies the gap above the list; this bar closes the section.
            // No bottom inset: the body's own 15pt bottom padding is the breathing
            // room, and this keeps the bar low like the immersive variant.
            manageBar
                .padding(.top, 6)
                // Keep the popped-up manage menu (an overlay reaching UP over the
                // rows) drawing above the ScrollView sibling during transitions.
                .zIndex(1)
        }
    }

    /// Plain-input header baseline: the height the floating header now measures with
    /// just the input (the manage bar moved to the bottom, out of the header). The
    /// `inputRow` carries `.frame(height: 48)` and the floating-header VStack wraps it
    /// with `.padding(.bottom, 6)` → 54pt measured for the bare-input case. The seed is
    /// set to exactly 54 so the `max(h, baseline)` clamp matches the real first-frame
    /// measurement and never over-reserves runway.
    static let immersiveHeaderBaseline: CGFloat = 54

    /// How far the immersive list's content reaches UP behind the floating header so
    /// the first row rests just clear of it. Derived from the *measured* header height
    /// (`measuredImmersiveHeaderHeight`) rather than a constant, because the header is
    /// not fixed: a plain input is short, but a pending copied-image preview adds a
    /// line above the input. Tracking the real
    /// height keeps the first row clear whether or not a preview is present.
    private var immersiveTopReach: CGFloat { measuredImmersiveHeaderHeight + immersiveHeaderGap }

    /// Height of the top frost band, in points. Kept SHORTER than the layout runway
    /// (`immersiveTopReach`) on purpose: the band must taper fully to clear before it
    /// reaches the first row's resting position, or the blurred light-grey glyphs of
    /// that row stack into a bright halo (see `ProgressiveTopBlur`). A 4pt margin under
    /// the runway is the tuned ceiling — over the 320pt viewport the deepest frost layer
    /// is also the faintest, so its tail grazing the runway edge stays imperceptible
    /// while the opaque bulk of the frost sits above. Derived from the runway (not a
    /// constant) so the band tracks the header: it grows when a preview raises the header
    /// and shrinks back for a plain input, always ending just above the first row.
    private var immersiveBlurReach: CGFloat { max(immersiveTopReach - 4, 0) }

    /// Height of the bottom frost band — the mirror of `immersiveBlurReach`. Kept
    /// SHORTER than the bottom runway so the band tapers to clear before it reaches
    /// the last row's resting position (no blurred-glyph halo at rest); only rows
    /// travelling down into the runway behind the bar frost out.
    private var immersiveBottomBlurReach: CGFloat { max(immersiveBottomReach - 4, 0) }

    /// Total height of the immersive scroll region — deliberately taller than the
    /// compact 220 so the recent list fills the panel and reads as one continuous
    /// surface flowing under the header. The manage bar floats over its bottom-left;
    /// rows run their whole height behind it. Older rows are a scroll (or ↓) away.
    /// Static so Settings can size its own body against it (see
    /// `InlineSettingsView.settingsPaneMaxHeight`) — switching between the two
    /// must not resize the island, and two hand-tuned numbers would drift.
    static let immersiveListHeight: CGFloat = 320

    /// The recent list. `immersive` swaps the compact, below-the-header list for
    /// the tall variant whose content scrolls UP behind the floating input —
    /// frosting and fading as it goes (see `immersiveTopReach`). Only used once
    /// the list overflows; a short list stays compact under the header.
    /// The two bucket ledgers are spatial siblings: Chat is fixed on the left,
    /// Agent on the right. Replacing the whole scroll page (rather than diffing
    /// every unrelated row) gives Shift-Tab one unambiguous horizontal move.
    @ViewBuilder
    private func historyList(immersive: Bool = false) -> some View {
        ZStack(alignment: .topLeading) {
            if model.agentComposeActive {
                historyListPage(immersive: immersive)
                    .id("agent-recent")
                    .transition(
                        .move(edge: .trailing)
                            .combined(with: .opacity)
                    )
            } else {
                historyListPage(immersive: immersive)
                    .id("chat-recent")
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func historyListPage(immersive: Bool) -> some View {
        // More content than fits the window → the list scrolls. In the compact layout
        // the first row sits right under the (non-scrolling) RECENT header, so the
        // TOP never needs a fade — a fixed top pad there would just open a dead gap
        // below the header. The immersive layout is the opposite: its top reaches
        // up behind the floating input, so it DOES taper (fade + frost) there.
        //
        // The compact bottom taper turns on exactly when the content outgrows the
        // 220pt frame. `historyFooterActions` rides at the tail of that content, so
        // its height counts here too — otherwise a 5-row list would quietly scroll
        // its footer off a hard, un-faded edge.
        let contentHeight =
            CGFloat(model.recentVisible.count) * compactRowHeight
            + (model.recentVisible.isEmpty ? 0 : historyFooterHeight)
        let overflowing = contentHeight > compactListHeight
        return ScrollViewReader { proxy in
        ScrollView {
            // Lazy: the data holds up to `notchRecentCap` (100) rows but only ~6–9
            // fit the frame — no need to build and lay out the off-screen ones.
            LazyVStack(alignment: .leading, spacing: 0) {
                // Agent runs ride the TOP of the scroll — the newest rows, scrolling
                // with the recent list like everything else — instead of pinned above
                // it (immersive: in the floating header; compact: a fixed sibling). So
                // a live task scrolls away normally rather than fixed over the top.
                if model.agentComposeActive, !agentManager.tasks.isEmpty {
                    // No extra gap here: each agent row already carries the same 9pt
                    // vertical pad as a Recent row, so the last agent row meets the
                    // first history row on the same 18pt rhythm as any two rows.
                    agentStatusRows
                }
                // Index into the SAME slice the model navigates (`recentVisible`),
                // so the keyboard highlight and the rendered rows can't drift.
                ForEach(Array(model.recentVisible.enumerated()), id: \.element.id) { index, item in
                    Button { model.openHistory(item) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(item.displayTitle)
                                .font(.sf(14))
                                .tracking(-0.1)
                                .foregroundStyle(Tokens.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // Ask rows show how long ago; Note/Reminder captures
                            // show where tapping goes, in the same trailing slot —
                            // so the Recent list reads as one ledger of everything
                            // the notch did, not just AI answers. The capture badge
                            // pairs the destination with an up-right arrow (the same
                            // "opens elsewhere" glyph the footer uses) so the row
                            // reads as a live jump into Notes/Reminders, not a dead
                            // label — tapping it lands on that exact note/reminder.
                            if item.pending {
                                // Still answering: the question is already in the list,
                                // and this small three-dot wave sits where the timestamp
                                // will land once the answer settles in place.
                                RecentPendingDots()
                            } else if item.source.isThread {
                                HStack(spacing: 6) {
                                    // A round that produced no answer keeps its row
                                    // (the question is the user's), so the row has to
                                    // say so — otherwise it reads as an ordinary
                                    // answer until you open it.
                                    if item.failed {
                                        Text(L("recent.badge.failed"))
                                            .font(.sf(11, weight: .medium))
                                            .foregroundStyle(Tokens.danger.opacity(0.9))
                                    }
                                    Text(relativeTime(item.t))
                                        .font(.sf(11).monospacedDigit())
                                        .tracking(0.2)
                                        .foregroundStyle(Tokens.text4)
                                }
                            } else {
                                // The jump to Notes/Reminders lives on its OWN button,
                                // not the row body — tapping the row must never yank the
                                // user out to another app they didn't ask to open. Only
                                // this trailing pill switches apps. `.plain` + its own
                                // `contentShape` isolate the hit region so a tap here
                                // fires the jump and doesn't bubble to the row's Ask path.
                                CaptureJumpButton(
                                    title: item.source == .note ? L("recent.badge.notes") : L("recent.badge.reminders"),
                                    tint: item.source.tint
                                ) { model.openCaptureInApp(item) }
                                // VoiceOver: this control is the jump; name it by
                                // destination so it reads distinctly from the row.
                                .accessibilityLabel(
                                    item.source == .note ? L("recent.hint.note") : L("recent.hint.reminder")
                                )
                            }
                        }
                        .padding(.vertical, 9)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HistoryRowStyle(selected: model.highlightedHistoryIndex == index))
                    // VoiceOver: an Ask row IS its action — combine title + timestamp
                    // into one element that reopens the thread. A capture row's action
                    // now lives on the SEPARATE trailing jump button (the row body no
                    // longer switches apps), so keep it a container (`.contain`) whose
                    // jump button stays independently focusable rather than folding it
                    // into the row.
                    .modifier(RecentRowAccessibility(item: item))
                    // A deleted row collapses up and fades rather than vanishing on a
                    // hard cut — the rows below slide into the gap on the same spring
                    // that drives the list's other module motion. Paired with the
                    // `withAnimation` around the delete below; the removal edge is what
                    // SwiftUI plays this transition against.
                    //
                    // …except during a bulk Clear (`bulkClearing`), where the sideways
                    // slide is the wrong verb: it says "this one row, swept out", and a
                    // whole 24-hour window playing it at once read as a curtain wiping
                    // across the list. A clear isn't per-row — the rows just stop
                    // existing — so they dissolve in place and only the gap closing
                    // carries the motion.
                    .transition(
                        model.bulkClearing
                            ? .opacity.combined(with: .scale(scale: 0.97))
                            : .move(edge: .leading)
                                .combined(with: .opacity)
                                .combined(with: .scale(scale: 0.96, anchor: .leading))
                    )
                    // Right-click a row to drop just that entry (Clear still wipes
                    // the whole list). Single-item delete needs no confirmation —
                    // one row is cheap to retype, unlike the destructive Clear-all.
                    .contextMenu {
                        Button(L("recent.delete"), role: .destructive) {
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                                model.deleteHistory(id: item.id)
                            }
                        }
                    }
                    // Target for keyboard-follow scrolling: ↓/↑ moves the highlight,
                    // and the onChange below scrolls that row's id into view.
                    .id(item.id)
                }

                // End-of-list actions. They ride at the BOTTOM of the scroll content,
                // so a long list only reveals them once it's dragged all the way down —
                // past the oldest row, where "see everything" and "wipe everything"
                // are what's left to do. A short list that doesn't scroll shows them
                // right away, since it's already at its bottom.
                if !model.recentVisible.isEmpty {
                    historyFooterActions
                }
            }
            // The immersive TOP runway is NOT padding — it's a safe-area inset on the
            // ScrollView itself (see `.safeAreaInset` below), because a runway made of
            // content is a runway SwiftUI can scroll away. The compact layout takes a
            // short content reserve of its own (only when the list actually scrolls) so
            // its top taper falls over empty space under the (non-floating) RECENT
            // header rather than dimming the first row at idle.
            // The bottom inset differs by layout: the immersive list runs its
            // rows full-height behind the floating manage bar (so the last rows stay
            // visible through/around the buttons) and only needs a little clearance
            // off the rounded corner; the compact list reserves the full edgeFade so
            // its bottom taper falls over empty space, not a row.
            .padding(.top, immersive ? 0 : (overflowing ? compactTopFade : 0))
            // Immersive: a bottom runway rows scroll DOWN into behind the manage bar
            // (always present — the immersive layout only mounts for an overflowing
            // list). Compact: the edgeFade reserve, only when actually overflowing.
            .padding(.bottom, immersive ? immersiveBottomReach : (overflowing ? edgeFade : 0))
            // A real AppKit scroll-offset observer catches trackpad and mouse-wheel
            // scrolling on macOS 14. As soon as the Recent content moves under the
            // popup, fold the popup out of the way.
            .onScrollOffsetChange { _ in
                collapseManageMenu()
            }
        }
        #if DEBUG
        .coordinateSpace(name: "immScroll")
        #endif
        // The immersive top runway (`immersiveTopReach`): the strip the first row
        // rests below, and that rows travel up into behind the floating input. It is
        // a SAFE-AREA INSET rather than `.padding(.top)` on the stack, and that
        // distinction is the whole fix for a bug that made the list open "covering"
        // the prompt: as an inset the runway lives OUTSIDE the scrollable content,
        // so there is nothing there for the scroll view to scroll away.
        //
        // As content it was stealable, and got stolen intermittently. A LazyVStack's
        // content height keeps settling for a second or so after the list opens (rows
        // materialise and re-measure: 1688 → 1697 → 1703 → 1730pt in a measured
        // trace), and on every content-size change SwiftUI re-anchors the scroll to
        // the first *item*. Padding is not an item, so the anchor snapped row 0 to the
        // very top of the viewport — the offset jumped 0 → 66 in a single frame, with
        // no scroll gesture anywhere near it — and the top rows came to rest under the
        // "Type anything…" header. Whether it hit depended on whether one of those
        // height changes happened to land while the list sat still, which is exactly
        // why it looked random. Rows still scroll under the header as before: the
        // inset moves where the content RESTS, not how far it can travel.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear.frame(height: immersive ? immersiveTopReach : 0)
        }
        // Immersive: a tall surface that fills the whole panel; the manage bar floats
        // over its bottom-left. Compact: ~6 rows before the list scrolls, so a short
        // Recent list doesn't reserve a tall empty band. Older rows are a scroll away.
        .frame(maxHeight: immersive ? Self.immersiveListHeight : compactListHeight)
        .scrollIndicators(.never)
        // BOTH edges taper in either layout — the top dissolves rows sliding up under
        // the header (immersive: the floating input), the bottom dissolves rows sliding
        // DOWN behind the floating manage bar (so reaching the end reads as rows sliding
        // under the ⋯ chip, mirroring the top). Each edge's taper length tracks its own
        // runway (`immersiveTopReach` / `immersiveBottomReach`; compact: `compactTopFade`
        // / `edgeFade`), and the compact top only arms once the list actually overflows.
        .scrollEdgeFade(
            top: immersive ? true : overflowing,
            bottom: immersive ? true : overflowing,
            topFade: immersive ? immersiveTopReach : compactTopFade,
            bottomFade: immersive ? immersiveBottomReach : edgeFade
        )
        // Immersive only: frost the rows as they scroll UP into the runway behind the
        // floating input, so they read as pushed back — present but soft — not
        // hard-clipped. The band is kept SHORTER than the runway (`immersiveBlurReach`
        // < `immersiveTopReach`) so it tapers out before the first resting row: idle
        // rows stay crisp (no blurred-glyph halo), only rows travelling up under
        // "Type anything…" frost. Decoupled from `immersiveTopReach` (which is layout:
        // where rows rest) so tuning the blur never shifts the list. Glass translucency
        // is untouched — this only softens focus, never darkens.
        //
        // …and the mirror at the BOTTOM — frost rows scrolling DOWN into the runway
        // behind the manage bar, so they dissolve under the buttons the same way the
        // top dissolves them under the input. Band kept shorter than the bottom
        // runway (`immersiveBottomBlurReach` < `immersiveBottomReach`) so it clears
        // the last resting row (no halo at rest). A lighter peak radius than the top
        // (the bar is shorter than the input header, so less depth to hide).
        //
        // The two radii differ, so this can't collapse to one blurred copy — but it
        // still goes through the merged modifier, which lays the two layers as
        // SIBLINGS over the same list instead of nesting them. Stacked, the bottom
        // modifier's content was already `list + top-blur copy`, so the pair built
        // the scroll surface four times over on every open; sibling, it's three.
        .modifier(ConditionalEdgeBlur(active: immersive,
                                      topHeight: immersiveBlurReach,
                                      bottomHeight: immersiveBottomBlurReach,
                                      topRadius: 36,
                                      bottomRadius: 22))
        // Keep the keyboard-highlighted row visible: stepping ↓/↑ past the visible
        // window would otherwise leave the selection offscreen. Mirrors the
        // streaming tail-follow in `conversationScroll` — a reactive scroll in its
        // OWN transaction, separate from the highlight mutation, so SwiftUI doesn't
        // silently drop the `scrollTo` mid-reconciliation.
        .onChange(of: model.highlightedHistoryIndex) { _, newIndex in
            // Keyboard ↑/↓ navigation is a Recent selection change even when
            // the newly highlighted row is already visible and no scroll is needed.
            collapseManageMenu()
            guard let i = newIndex, model.recentVisible.indices.contains(i) else { return }
            let id = model.recentVisible[i].id
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        }
    }
}
