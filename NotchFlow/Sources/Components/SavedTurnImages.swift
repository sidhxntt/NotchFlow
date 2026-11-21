import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// One saved attachment, drawn from the history image store by filename. Renders
/// nothing at all when the file is gone (a cleared store, a hand-deleted JPEG) —
/// a missing picture is silence, never a broken-image box.
struct SavedImageThumb: View {
    let file: String
    var width: CGFloat = 34
    var height: CGFloat = 24
    var corner: CGFloat = 5

    var body: some View {
        if let image = NotchModel.historyImage(named: file) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
    }
}

/// The images a SAVED turn rode in with — the copied screenshot an Ask attached, the
/// shots pasted into an agent task — shown above that turn's text wherever a saved
/// thread is read back (the reopened panel, the archive transcript). Deliberately the
/// same 34×24 thumbnail language as the live compose previews, so a reopened
/// conversation looks like the one that was sent. Clicking one opens the full-size
/// JPEG in Preview: the strip is a reminder of what was asked about, and the archive
/// is where you'd go to look at it properly.
struct SavedTurnImages: View {
    let files: [String]

    /// Past this the strip folds the rest into a "+N", same as the agent compose row —
    /// a task can carry up to `NotchModel.agentImageLimit` (20) images, far more than
    /// fits across the panel.
    private static let stripMax = 6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(files.prefix(Self.stripMax), id: \.self) { file in
                Button {
                    NSWorkspace.shared.open(NotchModel.historyImageURL(file))
                } label: {
                    SavedImageThumb(file: file)
                }
                .buttonStyle(.plain)
            }
            if files.count > Self.stripMax {
                Text("+\(files.count - Self.stripMax)")
                    .font(.sf(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.text4)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
