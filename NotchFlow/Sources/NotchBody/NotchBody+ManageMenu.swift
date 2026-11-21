import SwiftUI
import AppKit

@MainActor
extension NotchBody {
    /// The manage bar: the recent panel's bottom chrome, in both the compact and
    /// immersive layouts. The ⋯ chip holds the BOTTOM-LEFT corner and pops the manage
    /// MENU upward (filter by source, Settings) — see `manageMenu`. While a
    /// source filter is active and the menu is closed, a small tinted chip beside
    /// the ⋯ names the filter and clears it on tap, so the narrowed list never
    /// reads as "history lost". The Recent chevron (and the pin, once ⌘P holds the
    /// panel) holds the BOTTOM-RIGHT corner opposite it — while the list is up, the
    /// way out of it belongs on the same baseline as the ⋯, not up in the header.
    /// Always visible — fixed chrome below the list.
    ///
    /// Used by `historySection` (compact) as a VStack sibling below the list, and by
    /// `immersiveHistoryView` as an overlay across the bottom of the scroll frame.
    var manageBar: some View {
        HStack(spacing: 6) {
            // The single ⋯ chip. It only toggles the menu.
            moreEntry

            // A waiting build sits OUTSIDE the menu, next to the ⋯ — spelled out,
            // one tap, no digging. It stays put while the menu is up (the menu
            // floats above this row, covering nothing), and the menu drops its own
            // update row meanwhile (see `updateMenuRow`), so the action lives in
            // exactly one place.
            if let pending = pendingUpdateVersion {
                updateCue(version: pending, height: 34,
                          hovered: $updateCueBarHovered)
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.9, anchor: .leading))
                    )
            }

            // Active-filter chip: visible while a source filter narrows the list
            // and the menu is folded away. Tinted with the source's colour; the ×
            // makes "tap to clear" legible without a tooltip.
            if !model.agentComposeActive,
               !manageExpanded,
               let source = model.historySourceFilter {
                activeFilterChip(source)
                    .transition(
                        .move(edge: .leading)
                            .combined(with: .opacity)
                            .combined(with: .scale(scale: 0.9, anchor: .leading))
                    )
            }

            Spacer(minLength: 8)   // hold the two clusters apart, one per corner

            // The Recent (+ pin) cluster, handed over from the header for as long as
            // the list is up (see `bucketRow` / `inputRow`).
            // Sized to the ⋯ chip opposite it (34, not the prompt row's 30) — the
            // bar's two corners are one pair of controls and have to read as one.
            let cluster = idleTrailingCluster(chipSize: 34)
            if !cluster.isEmpty {
                cluster
            }
        }
        // The menu floats ABOVE the chip, anchored to its bottom-left, and grows
        // upward out of it. An overlay (not a sibling) so opening it never
        // relayouts the list — it draws over the rows like a real popup menu.
        .overlay(alignment: .bottomLeading) {
            if manageExpanded {
                manageMenu
                    // Lift the menu's bottom edge just above the 34pt ⋯ chip.
                    .offset(y: -(34 + 8))
                    // Unfurl UP and OUT of the ⋯ chip: grow from its top-left
                    // corner with a small rise, rather than popping in place —
                    // the upward mirror of how the island's other modules move.
                    .transition(
                        .scale(scale: 0.86, anchor: .bottomLeading)
                            .combined(with: .offset(y: 6))
                            .combined(with: .opacity)
                    )
            }
        }
        // Collapse the menu whenever the panel itself closes, so the next open
        // starts back at the bare ⋯ rather than a stale open menu.
        .onChange(of: model.showHistory) { _, showing in
            if !showing { manageExpanded = false }
        }
        // Chat and Agent own separate Recent pages. If the bucket changes while
        // this popup is open, fold it before the other page slides into place.
        .onChange(of: model.agentComposeActive) { _, _ in
            collapseManageMenu()
        }
        // One inset, both sides: the ⋯ and the Recent chevron sit the same distance
        // from their own edge, so the bar's two corners read as a matched pair. The
        // call site supplies the outward pull (the body's own 15pt is too generous
        // for corner chrome) and the bottom placement.
        .padding(.horizontal, 2)
    }

    /// The version of a build that's downloaded and waiting, if any — what the
    /// ordinary "Update to X" chips print, and what scopes 0.7.0's major-update
    /// treatment. Nil at every other phase.
    var pendingUpdateVersion: String? {
        if case .available(let v) = updater.phase { return v }
        return nil
    }

    /// The ⋯ entry: a single Liquid Glass chip that pops the manage menu up above
    /// itself. No update badge — a waiting build gets its own chip beside this one
    /// (see `updateCue`) rather than a dot to decode.
    private var moreEntry: some View {
        // ⋯ when closed; × once the menu is up, so the chip reads as "dismiss"
        // while the popup is showing.
        GlassIconButton(
            systemName: manageExpanded ? "xmark" : "ellipsis",
            help: L(manageExpanded ? "recent.collapse" : "recent.manage"),
            size: 34,
            showsTooltip: false
        ) {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                manageExpanded.toggle()
            }
        }
    }

    /// Fold the manage popup with the same response as its explicit close button.
    /// Scroll and Recent-page navigation both use this path, so the menu never
    /// hangs over content that has moved or been replaced underneath it.
    func collapseManageMenu() {
        guard manageExpanded else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            manageExpanded = false
        }
    }

    /// The upward manage menu: one small glass card holding the update action,
    /// release notes, and Settings — the two update entries pulled out here so
    /// they're one tap away instead of buried in Settings → About. (The source
    /// filter chips used to sit above it but were removed.) "See all history" and
    /// Clear deliberately do NOT live here — they sit at the very END of the recent
    /// list (see `historyFooterActions`), so they're reached by scrolling the list
    /// to its bottom.
    private var manageMenu: some View {
        return VStack(alignment: .leading, spacing: ManageMenuMetrics.rowSpacing) {
            // Update action: "Update to X" once a newer build is ready, otherwise a
            // manual freshness check that reports its result in place. Same
            // behaviour as the About version row.
            updateMenuRow
            // Release notes: the What's New panel, without a detour through Settings.
            manageMenuRow(icon: LucideIcons.scrollText, title: L("recent.menu.releaseNotes")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.openWhatsNew(on: nil)
                }
            }
            // The keyboard reference. It lands in Settings → Shortcuts rather than
            // popping a card of its own: the list is long enough to want the
            // settings pane's room, and the summon chord it leads with is
            // *editable* in the section right above it (General), so the two
            // belong under one roof. Same jump the update row makes to About.
            manageMenuRow(icon: LucideIcons.command, title: L("recent.menu.shortcuts")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.settingsSection = "Shortcuts"
                    model.toggleSettings()
                }
            }
            // What the archive adds up to. Like the shortcuts row it hands off to
            // its settings pane rather than popping a card here — the digest is a
            // grid of tiles, far more than this menu's width, and it sits next to
            // Shortcuts in the sidebar too.
            manageMenuRow(icon: LucideIcons.chartNoAxesColumn, title: L("recent.menu.stats")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.settingsSection = "Stats"
                    model.toggleSettings()
                }
            }
            manageMenuRow(icon: LucideIcons.settings, title: L("recent.menu.settings"), shortcut: "⌘,") {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.toggleSettings()
                }
            }
        }
        .padding(ManageMenuMetrics.cardPadding)
        .frame(minWidth: 176, alignment: .leading)
        .fixedSize()
        .manageMenuCardBackground()
    }

    /// The update row of the manage menu — "Check for updates", a tap jumps to
    /// Settings → About with a user-initiated check already running (the same path
    /// as the app menu's "Check for Updates…"), so the spinner, the "up to date"
    /// note, or the Update button land in the About slot built to show them instead
    /// of the menu pantomiming the check in place.
    ///
    /// Once a build IS waiting the row drops out entirely: the "Update to X" chip
    /// on the bar outside owns that action now (see `updateCue`), and repeating it
    /// in here would be the same tap twice.
    @ViewBuilder
    private var updateMenuRow: some View {
        if pendingUpdateVersion != nil {
            EmptyView()
        } else {
            manageMenuRow(icon: LucideIcons.circleFadingArrowUp,
                          title: L("recent.menu.checkForUpdates")) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    manageExpanded = false
                    model.settingsSection = "About"
                    model.toggleSettings()
                }
                updater.checkManually()
            }
        }
    }

    /// One full-width action row of the manage menu — icon, label, optional
    /// trailing shortcut hint — with the plain white hover wash the other glass
    /// popover menus use (see `ManageMenuRowStyle`).
    private func manageMenuRow(
        icon: LucideIcons.Mark, title: String, shortcut: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: ManageMenuMetrics.rowContentSpacing) {
                // A step quieter than the label it leads — the word is the thing being
                // read, the glyph only marks the row.
                LucideIcon(mark: icon)
                    .foregroundStyle(Tokens.text3)
                Text(title)
                    .font(.sf(ManageMenuMetrics.fontSize, weight: .medium))
                    .foregroundStyle(Tokens.text2)
                Spacer(minLength: 16)
                if let shortcut {
                    Text(shortcut)
                        .font(.sf(ManageMenuMetrics.accessoryFontSize))
                        .foregroundStyle(Tokens.text4)
                }
            }
            .padding(.horizontal, ManageMenuMetrics.rowHorizontalPadding)
            .padding(.vertical, ManageMenuMetrics.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(ManageMenuRowStyle())
        .onHover { inside in
            if inside { Haptics.alignment() }
        }
    }

    /// The collapsed-state reminder that a source filter is narrowing the list:
    /// a small tinted capsule beside the ⋯ naming the filter, with an × — tap
    /// anywhere on it to clear the filter and show everything again.
    private func activeFilterChip(_ source: NotchModel.HistoryItem.Source) -> some View {
        ActiveFilterChip(model: model, source: source)
    }
}
