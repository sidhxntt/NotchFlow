import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

// MARK: - Answer media (images & PDFs)

/// Downloads and caches the media an answer references. One shared instance so
/// the several mounted copies of a turn (visible thread, height probe, blur
/// overlays) resolve a URL to ONE download: finished outcomes are cached,
/// in-flight fetches are joined. http/https only — answer text comes from an
/// LLM, so every other scheme (file://, custom) stays inert, matching the link
/// policy in `InlineMarkdownText`.
@MainActor
final class AnswerMediaLoader {
    static let shared = AnswerMediaLoader()

    /// A rendered PDF preview: page 1 plus how much more there is.
    struct PDFPreview {
        let firstPage: NSImage
        let pageCount: Int
    }

    enum Outcome {
        case image(NSImage)
        case pdf(PDFPreview)
        case failed
    }

    private enum Kind { case image, pdf }

    private var cache: [String: Outcome] = [:]
    private var order: [String] = []   // insertion order, for eviction
    private var inflight: [String: Task<Outcome, Never>] = [:]

    /// More than this is a mistake to pull down for a chat answer.
    private nonisolated static let byteCap = 30 * 1024 * 1024
    /// Decode bound — the panel shows ~700 device pixels, so a 12-megapixel
    /// photograph should cost a thumbnail's memory, not a 50 MB bitmap.
    private nonisolated static let maxPixel: CGFloat = 1600

    func image(for urlString: String) async -> Outcome {
        await outcome(for: urlString, as: .image)
    }

    func pdf(for urlString: String) async -> Outcome {
        await outcome(for: urlString, as: .pdf)
    }

    private func outcome(for urlString: String, as kind: Kind) async -> Outcome {
        if let hit = cache[urlString] { return hit }
        if let running = inflight[urlString] { return await running.value }
        let task = Task { await Self.fetch(urlString, as: kind) }
        inflight[urlString] = task
        let result = await task.value
        inflight[urlString] = nil
        cache[urlString] = result
        order.append(urlString)
        if order.count > 64 { cache.removeValue(forKey: order.removeFirst()) }
        return result
    }

    /// The off-main part: download, bound, decode. `nonisolated` so the fetch
    /// runs on the concurrency pool, not the main thread this class lives on.
    private nonisolated static func fetch(_ urlString: String, as kind: Kind) async -> Outcome {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let (data, response) = try? await URLSession.shared.data(from: url),
              data.count <= byteCap,
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { return .failed }

        switch kind {
        case .image:
            guard let image = downsampled(data) else { return .failed }
            return .image(image)
        case .pdf:
            guard let doc = PDFDocument(data: data), doc.pageCount > 0,
                  let page = doc.page(at: 0)
            else { return .failed }
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(2, 1200 / max(bounds.width, 1))
            let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
            return .pdf(PDFPreview(firstPage: page.thumbnail(of: size, for: .mediaBox),
                                   pageCount: doc.pageCount))
        }
    }

    /// Decode via ImageIO with a pixel cap (also normalises EXIF rotation).
    private nonisolated static func downsampled(_ data: Data) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Open a media reference in the default app — same scheme gate as the loader.
private func openAnswerMediaURL(_ urlString: String) {
    guard let url = URL(string: urlString),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else { return }
    NSWorkspace.shared.open(url)
}

/// The shape media takes while its download is in flight — a quiet island of
/// fixed height, so the panel settles in one reflow when the pixels land.
private struct MediaLoadingPlaceholder: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.white.opacity(0.04))
            .frame(height: 120)
            .overlay(ProgressView().controlSize(.small).tint(.white.opacity(0.4)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Tokens.hairline, lineWidth: 0.5)
            )
    }
}

/// The degraded form of a media reference whose download failed (or whose
/// bytes weren't what the syntax claimed): a compact link-out chip, so the
/// reference is still reachable, never silently dropped. Not private: the
/// lightbox wears the same chip for its way out to the source.
struct MediaLinkChip: View {
    /// The leading glyph that says what KIND of thing failed to load. Nil where
    /// the chip is a plain way out to the source and the kind is already obvious
    /// (the lightbox's link, under the picture itself).
    var icon: String?
    let label: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.sf(baseFont - 3, weight: .medium))
                }
                Text(label)
                    .font(.sf(baseFont - 1))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.up.right")
                    .font(.sf(baseFont - 5, weight: .semibold))
                    .opacity(0.6)
            }
            .foregroundStyle(color.opacity(0.75))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Tokens.hairline, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// One `![alt](url)` reference as an inline image island. Spans the answer's
/// width (left-aligned, never upscaled past its natural size); tapping opens the
/// source in the browser.
struct AnswerImageView: View {
    let alt: String
    let urlString: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1

    /// Height ceiling for a tall image — enforced by capping the *width* instead
    /// of the height, so the frame keeps hugging the image (a maxHeight would
    /// pillarbox it inside a wider border).
    private static let heightCap: CGFloat = 360

    /// Nil on a surface with no lightbox over it (a preview, settings copy) —
    /// there the tap falls back to opening the source.
    @Environment(\.imageLightboxHostID) private var lightboxHostID

    @State private var outcome: AnswerMediaLoader.Outcome?

    var body: some View {
        Group {
            switch outcome {
            case .image(let image):
                let ratio = image.size.width / max(image.size.height, 1)
                // Tapping opens the image itself (`ImageLightbox`), not the
                // browser — same gesture a card in a gallery answers to. The
                // source stays one chip away, inside the lightbox.
                Button {
                    if let hostID = lightboxHostID {
                        ImageLightboxCenter.shared.present(
                            .init(images: [AnswerImageRef(alt: alt, urlString: urlString)],
                                  index: 0, host: hostID)
                        )
                    } else {
                        openAnswerMediaURL(urlString)
                    }
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(ratio, contentMode: .fit)
                        .frame(maxWidth: min(image.size.width, Self.heightCap * ratio))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alt.isEmpty ? "image" : alt)
            case .pdf, .failed:
                MediaLinkChip(icon: "photo",
                              label: alt.isEmpty ? (URL(string: urlString)?.host ?? urlString) : alt,
                              baseFont: baseFont, color: color) {
                    openAnswerMediaURL(urlString)
                }
            case nil:
                MediaLoadingPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: urlString) {
            outcome = await AnswerMediaLoader.shared.image(for: urlString)
        }
    }
}

/// A `.pdf` reference as a document island: the first page, then a footer with
/// the document's name and page count. Tapping opens the PDF itself.
struct AnswerPDFView: View {
    let title: String
    let urlString: String
    var baseFont: CGFloat = 15
    var color: Color = Tokens.text1

    @State private var outcome: AnswerMediaLoader.Outcome?

    var body: some View {
        Group {
            switch outcome {
            case .pdf(let preview):
                Button { openAnswerMediaURL(urlString) } label: {
                    VStack(spacing: 0) {
                        Image(nsImage: preview.firstPage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .frame(maxWidth: .infinity)
                        Divider().overlay(Tokens.hairline)
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.sf(baseFont - 3, weight: .medium))
                            Text(displayTitle)
                                .font(.sf(baseFont - 1, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(preview.pageCount == 1 ? "1 page" : "\(preview.pageCount) pages")
                                .font(.sf(baseFont - 2))
                                .opacity(0.55)
                            Image(systemName: "arrow.up.right")
                                .font(.sf(baseFont - 5, weight: .semibold))
                                .opacity(0.6)
                        }
                        .foregroundStyle(color.opacity(0.85))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Tokens.hairline, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(displayTitle)
            case .image, .failed:
                MediaLinkChip(icon: "doc.text", label: displayTitle,
                              baseFont: baseFont, color: color) {
                    openAnswerMediaURL(urlString)
                }
            case nil:
                MediaLoadingPlaceholder()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: urlString) {
            outcome = await AnswerMediaLoader.shared.pdf(for: urlString)
        }
    }

    private var displayTitle: String {
        if !title.isEmpty { return title }
        let name = URL(string: urlString)?.lastPathComponent ?? ""
        return name.isEmpty ? urlString : name
    }
}
