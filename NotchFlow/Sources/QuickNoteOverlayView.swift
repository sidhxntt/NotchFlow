import SwiftUI

struct QuickNoteOverlayView: View {
    @ObservedObject var store: QuickNoteStore
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Quick note", systemImage: "note.text")
                    .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.sf(10, weight: .bold))
                        .frame(width: 25, height: 25)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.text3)
                .accessibilityLabel("Close Quick Note")
            }
            TextEditor(text: $store.draft)
                .font(.sf(12, weight: .regular))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: 92)
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text("Write a thought…")
                            .font(.sf(12, weight: .regular)).foregroundStyle(Tokens.placeholder)
                            // Match TextEditor's inner text container (6pt outer
                            // padding plus its native 5pt text inset), so the hint
                            // begins beneath the caret rather than drifting.
                            .padding(.leading, 11).padding(.top, 7)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text(statusText).font(.sf(10, weight: .medium)).foregroundStyle(statusColor)
                Spacer()
                if store.saveState == .failed {
                    Button("Retry", action: store.retry)
                        .buttonStyle(.plain).font(.sf(10, weight: .semibold)).foregroundStyle(Tokens.accent)
                }
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var statusText: String {
        switch store.saveState {
        case .idle: "Saves automatically to Apple Notes"
        case .saving: "Saving…"
        case .saved: "Saved to Apple Notes"
        case .failed: "Couldn’t save — your draft is safe"
        }
    }

    private var statusColor: Color {
        store.saveState == .failed ? Tokens.danger : Tokens.text3
    }
}
