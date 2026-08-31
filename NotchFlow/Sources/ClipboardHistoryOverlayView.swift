import SwiftUI

/// A compact, local-only clipboard history. Its shape intentionally matches the
/// other existing utility overlays: one header, dense action rows, and no new
/// navigation surface.
struct ClipboardHistoryOverlayView: View {
    @ObservedObject var history: ClipboardHistoryService
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            Toggle("Save copied items on this Mac", isOn: $history.isEnabled)
                .font(.sf(11, weight: .medium))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.text2)

            if history.items.isEmpty {
                Text(history.isEnabled ? "Copy text, files, or images to build history." : "Turn on history to save future copies.")
                    .font(.sf(11, weight: .regular))
                    .foregroundStyle(Tokens.text3)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 5) {
                    ForEach(history.items.prefix(6)) { item in
                        itemRow(item)
                    }
                }
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var headerRow: some View {
        HStack {
            Label("Clipboard", systemImage: "clipboard.fill")
                .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
            Spacer()
            if !history.items.isEmpty {
                Button("Clear") { history.clearHistory() }
                    .buttonStyle(.plain)
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
            Button(action: close) {
                Image(systemName: "xmark").font(.sf(10, weight: .bold))
                    .frame(width: 25, height: 25)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).foregroundStyle(Tokens.text3)
            .accessibilityLabel("Close Clipboard")
        }
    }

    private func itemRow(_ item: ClipboardHistoryItem) -> some View {
        Button { history.restore(item) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol(for: item.content))
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 13)
                    .foregroundStyle(Tokens.text3)
                Text(item.content.displayText)
                    .font(.sf(11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)) }
            }
            .padding(.vertical, 6).padding(.horizontal, 8)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.text2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .contextMenu {
            Button(item.isPinned ? "Unpin" : "Pin") { history.setPinned(!item.isPinned, for: item) }
            Button("Remove", role: .destructive) { history.remove(item) }
        }
        .accessibilityLabel("Restore \(item.content.displayText) to clipboard")
    }

    private func symbol(for content: ClipboardContent) -> String {
        switch content {
        case .text: "doc.on.clipboard"
        case .file: "folder"
        case .image: "photo"
        }
    }
}
