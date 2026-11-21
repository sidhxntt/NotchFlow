import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

@MainActor
extension InlineSettingsView {
    // MARK: - Sidebar

    /// The categories worth showing for the way the app is configured right now.
    /// Chat, Agent, and Stats all describe the agentic layer — Stats is the
    /// archive that layer writes — so companion mode retires all three instead of
    /// offering pages about a surface the notch no longer has a tab for. Agentic
    /// mode itself is a Global row, which never leaves.
    var sidebarSections: [Section] {
        Section.sidebarCases.filter {
            capabilities.agenticModeEnabled
                || ($0 != .chat && $0 != .agent && $0 != .stats)
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sidebarSections) { s in
                SidebarItem(
                    title: s.title,
                    selected: section == s,
                    // The gear's update dot continues here: it leads to settings,
                    // then the About entry carries it the rest of the way to the
                    // update action — a quiet neutral dot, never a coloured one.
                    badged: s == .about && isUpdateAvailable
                ) {
                    withAnimation(.easeOut(duration: 0.16)) { section = s }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 104, alignment: .topLeading)
        .padding(.trailing, 12)
    }

    private var isUpdateAvailable: Bool {
        if case .available = updater.phase { return true }
        return false
    }

    /// One category row: quiet text that brightens on hover, a faint fill when
    /// selected — same translucent-chip language as GlassMenu, minus the border.
    private struct SidebarItem: View {
        var title: String
        var selected: Bool
        var badged: Bool
        var action: () -> Void

        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.sf(12.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Tokens.text1 : (hovering ? Tokens.text2 : Tokens.text3))
                    if badged {
                        Circle()
                            .fill(Tokens.text2)
                            .frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(.white.opacity(selected ? 0.08 : (hovering ? 0.04 : 0)))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
        }
    }
    // MARK: - Header

    /// This legacy header is retained only for pushed detail panes. Settings is
    /// hosted by the standalone macOS window, which supplies its own chrome.
    var header: some View {
        HStack(spacing: 10) {
            PanelBackPill(
                title: section.isDetail ? section.title : L("settings.title"),
                help: section.parent.map { L("navigation.backTo", $0.title) }
                    ?? L("settings.back")
            ) {
                if let parent = section.parent {
                    withAnimation(.easeOut(duration: 0.16)) { section = parent }
                } else {
                    model.toggleSettings()
                }
            }

            Spacer()

            // Stats' hover readout. The header is the one line in this panel with
            // standing empty space, so naming the square under the pointer costs
            // no layout anywhere — and at this height it is clear of the pane's
            // own tapers.
            statsReadout
        }
        .padding(.horizontal, 8)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .animation(.easeOut(duration: Tokens.rowFade), value: statsHover)
    }

    /// "Aug 5 · 21 chats · 2 agent runs" — the date, and what actually went
    /// through the notch that day, bucket by bucket. It used to read "23 items",
    /// which left the reader working out what an item was; each figure now
    /// carries the noun its column in the totals row carries, singular forms
    /// included, because "1 chats" is the kind of thing that makes a panel look
    /// unfinished. A day nothing happened on shows only its date — the empty
    /// square under the pointer has already said the rest.
    @ViewBuilder
    private var statsReadout: some View {
        if section == .stats, let day = statsHover?.day, let stats {
            let buckets = StatsFormat.dayBreakdown(stats.breakdown[day] ?? .init())
            Text(buckets.map { L("stats.dayTip", StatsFormat.day(day), $0) }
                 ?? StatsFormat.day(day))
                // Meta weight, not label weight: this line is an annotation on
                // the square under the pointer, and at `.text3`/11 it competed
                // with the back pill across the header from it.
                .font(.sf(10).monospacedDigit())
                .foregroundStyle(Tokens.text4)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 6)
                .transition(.opacity)
        }
    }
}
