import SwiftUI
import AppKit

/// Gives the File tray and Calendar their own equal-width surfaces while
/// stretching the shorter surface to match whichever side has more content.
/// Not file-private: `ActivityMonitorView` splits into two cards with the same
/// column geometry, so the toggle circle floating in the gutter lands on the
/// same seam whichever pair is showing.
struct EqualHeightUtilitiesLayout: Layout {
    let spacing: CGFloat

    init(spacing: CGFloat = 10) {
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let availableWidth = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width } + spacing * CGFloat(max(0, subviews.count - 1))
        let cellWidth = max(0, (availableWidth - spacing * CGFloat(max(0, subviews.count - 1))) / CGFloat(subviews.count))
        let cellProposal = ProposedViewSize(width: cellWidth, height: nil)
        let height = subviews.map { $0.sizeThatFits(cellProposal).height }.max() ?? 0
        return CGSize(width: availableWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let cellWidth = max(0, (bounds.width - spacing * CGFloat(max(0, subviews.count - 1))) / CGFloat(subviews.count))
        for (index, subview) in subviews.enumerated() {
            let x = bounds.minX + CGFloat(index) * (cellWidth + spacing)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: cellWidth, height: bounds.height)
            )
        }
    }
}

/// The command chip beside an agent thread's follow-up field opens this compact
/// metadata menu. The old version flattened all three values into one long hover
/// tooltip; rows make them scannable, and the folder row earns the menu treatment
/// by opening the working directory directly.
struct AgentRunMetadataMenu: View {
    let engine: String?
    let folderPath: String?
    let completedAt: Date?
    let onOpenFolder: () -> Void

    private var folderName: String? {
        guard let folderPath, !folderPath.isEmpty else { return nil }
        return URL(fileURLWithPath: folderPath).lastPathComponent
    }

    private var completed: String? {
        guard let completedAt else { return nil }
        return L("result.completedAt",
                 completedAt.formatted(date: .abbreviated, time: .shortened))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ManageMenuMetrics.rowSpacing) {
            if let engine, !engine.isEmpty {
                ResultMetadataRow(icon: LucideIcons.terminal, title: engine)
            }
            if let folderName {
                ResultMetadataRow(icon: LucideIcons.folder, title: folderName,
                                  accessory: "↗", action: onOpenFolder)
            }
            if let completed {
                ResultMetadataRow(icon: LucideIcons.clock, title: completed)
            }
        }
        .padding(ManageMenuMetrics.cardPadding)
        // Keep the card compact; long engine/folder/date values scroll inside
        // their row instead of making the whole menu sprawl across the answer.
        .frame(width: 220, alignment: .leading)
        .preferredColorScheme(.dark)
    }
}

/// One informational row in the agent metadata menu. Only the folder is a
/// button; engine and completion remain calm labels rather than fake actions.
struct ResultMetadataRow: View {
    let icon: LucideIcons.Mark
    let title: String
    var accessory: String? = nil
    var action: (() -> Void)? = nil

    @State private var hovering = false

    private var face: some View {
        HStack(spacing: ManageMenuMetrics.rowContentSpacing) {
            LucideIcon(mark: icon)
                .foregroundStyle(Tokens.text3)
                .frame(width: 13)
            HoverMarqueeText(
                text: title,
                color: Tokens.text2,
                hovering: hovering)
            if let accessory {
                Spacer(minLength: 4)
                Text(accessory)
                    .font(.sf(ManageMenuMetrics.accessoryFontSize, weight: .regular))
                    .foregroundStyle(Tokens.text4)
            }
        }
        .padding(.horizontal, ManageMenuMetrics.rowHorizontalPadding)
        .padding(.vertical, ManageMenuMetrics.rowVerticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if action == nil, hovering {
                Capsule(style: .continuous).fill(Color.white.opacity(0.06))
            }
        }
        .contentShape(Rectangle())
    }

    var body: some View {
        if let action {
            Button(action: action) { face }
                .buttonStyle(ManageMenuRowStyle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
                .accessibilityLabel(title)
                .accessibilityHint(L("agent.openFolder"))
        } else {
            face
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: Tokens.rowFade), value: hovering)
                .accessibilityElement(children: .combine)
        }
    }
}

/// A single-line menu value that stays still when it fits and gently travels
/// end-to-end while hovered when it does not. The previous `ScrollView` only
/// enabled trackpad scrolling; this makes the overflow behavior discoverable at
/// the exact moment the pointer asks to read the clipped value.
private struct HoverMarqueeText: View {
    let text: String
    let color: Color
    let hovering: Bool

    @State private var offset: CGFloat = 0

    private var textWidth: CGFloat {
        ceil(NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: ManageMenuMetrics.fontSize,
                                         weight: .medium)
            ]
        ).size().width) + 1
    }

    var body: some View {
        GeometryReader { proxy in
            Text(text)
                .font(.sf(ManageMenuMetrics.fontSize, weight: .medium))
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .leading)
                .onChange(of: hovering) { _, _ in
                    updateOffset(viewport: proxy.size.width)
                }
                .onChange(of: proxy.size.width) { _, width in
                    updateOffset(viewport: width)
                }
                .onChange(of: text) { _, _ in
                    updateOffset(viewport: proxy.size.width)
                }
        }
        .frame(height: ManageMenuMetrics.rowTextHeight)
        .clipped()
        .accessibilityLabel(text)
    }

    private func updateOffset(viewport: CGFloat) {
        let overflow = max(0, textWidth - viewport)
        guard hovering, overflow > 1 else {
            withAnimation(.easeOut(duration: 0.18)) { offset = 0 }
            return
        }
        // About 28pt/sec: calm enough to read dates and paths, but a full pass of
        // an ordinary overflow still completes within a couple of seconds. One
        // pass only — it parks on the tail end and stays there while the pointer
        // remains, instead of sliding back over text already being read. Leaving
        // the row eases it home.
        let duration = max(0.9, Double(overflow / 28))
        offset = 0
        withAnimation(.linear(duration: duration)) {
            offset = -overflow
        }
    }
}
