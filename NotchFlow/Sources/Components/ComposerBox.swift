import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// The app's **one** composer box — the recessed, growing input that every
/// follow-up line is typed into, on whichever surface it appears: the panel's
/// chat follow-up, the panel's agent-detail page, and the torn-off windows of
/// both.
///
/// It exists because those four had drifted into two species. The panel's boxes
/// grow on `NotchBody.composerShape` (a pill on its resting line that keeps the
/// SAME corner once the draft wraps), lift floor and rim together on focus, and
/// hand the placeholder slot to a SwiftUI label so it can clear the instant IME
/// pinyin appears. The detached windows meanwhile ran a flat `Capsule` with
/// `lit: false` and the native placeholder — a different rounding, no focus
/// response, and in the thread window a single-line `TextField` that couldn't
/// grow at all. A torn-off session is the same conversation in a bigger frame,
/// so its input cannot be a different control.
///
/// The box owns its own height and caret-width state. Those only ever fed its
/// own silhouette and its placeholder's fade, so keeping them in here is what
/// lets a call site be a handful of lines.
struct ComposerBox<Placeholder: View, Trailing: View>: View {
    @Binding var text: String
    var fontSize: CGFloat = NotchBody.followUpFontSize
    var maxVisibleLines: Int = NotchBody.promptMaxLines
    /// Flip true to pull first-responder into the box (see `PromptField`).
    var focusTrigger: Bool = false
    /// Whether the box currently holds the caret — floor and rim lift together.
    var focused: Bool = false
    /// A whisper of the destination's colour washed over the box while it holds
    /// text — the panel chat field's routing tell, so the input leans toward
    /// where Enter will send the line. `nil` on the surfaces that don't route.
    var tint: Color? = nil
    /// Flash the rim whenever this changes, in `pulseTint` — the peripheral twin
    /// of the destination pill's word swap. `nil` = no pulse.
    var pulse: AnyHashable? = nil
    var pulseTint: Color = .white
    var onSubmit: () -> Void
    /// Let the owning compose attach a clipboard image before the editor falls
    /// back to its ordinary text paste. Follow-up surfaces opt in only when the
    /// destination can actually receive image input.
    var onPasteImage: () -> Bool = { false }
    var onCommandSubmit: () -> Bool = { false }
    var onBack: () -> Void = {}
    var onTab: () -> Bool = { false }
    @ViewBuilder var placeholder: () -> Placeholder
    /// The control on the trailing edge — a `SendButton` on a chat line, the
    /// `AgentFollowUpKeyHints` labels on an agent one. Shows and hides on the
    /// caller's own terms; the row's height comes from the field, so appearing
    /// here never moves the box.
    @ViewBuilder var trailing: () -> Trailing

    /// 0 until the field reports its first layout — until then the box is one
    /// line of its own type size, which is exactly what it will measure.
    @State private var height: CGFloat = 0
    @State private var caretWidth: CGFloat = 0

    private var fieldHeight: CGFloat {
        height > 0 ? height : PromptField.lineHeight(for: fontSize)
    }
    /// The box's own outline: the field's slot (27pt at rest, taller once the
    /// text wraps) plus 6pt of padding top and bottom.
    private var shape: RoundedRectangle {
        NotchBody.composerShape(height: max(27, fieldHeight) + 12)
    }
    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        // Bottom-aligned so the trailing control stays on the box's last line as
        // a long follow-up unfolds upward, instead of floating at its middle.
        let box = HStack(alignment: .bottom, spacing: 6) {
            ZStack(alignment: .leading) {
                PromptField(
                    text: $text,
                    // Empty on purpose: the box can only hard-swap its native
                    // placeholder, so the slot belongs to the SwiftUI label
                    // below, which cross-fades and yields to composing pinyin.
                    placeholder: "",
                    fontSize: fontSize,
                    focusTrigger: focusTrigger,
                    maxVisibleLines: maxVisibleLines,
                    onSubmit: onSubmit,
                    onBack: onBack,
                    onTab: onTab,
                    onPasteImage: onPasteImage,
                    onCommandSubmit: onCommandSubmit,
                    onCaretWidth: { caretWidth = $0 },
                    onHeightChange: { height = $0 }
                )
                .frame(height: fieldHeight)
                // Shown only while the editor is truly empty — committed text, a
                // bare line break, and in-progress pinyin all hide it. (Raw
                // `isEmpty`, not the trimmed one: a ⇧⏎-only field still shows
                // glyphs, so the ghost must be gone.)
                if text.isEmpty && caretWidth == 0 {
                    placeholder()
                        .font(.sf(fontSize))
                        .foregroundStyle(Tokens.placeholder)
                        .lineLimit(1)
                        // Sit on the box's own ~2pt left inset, so the label
                        // lands where the typed glyphs will.
                        .padding(.leading, PromptField.textInset)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            // One line at rest is 18pt but the row is pinned to the trailing
            // control's 27pt — so a resting field centres in that slot and only
            // a wrapped follow-up pushes the row taller.
            .frame(height: max(27, fieldHeight))
            // Drives the placeholder's fade during IME pre-composition: pinyin
            // in the editor flips `caretWidth` while `text` is still empty, and
            // without this key the label would hard-pop instead of fading.
            .animation(.easeOut(duration: 0.16), value: caretWidth == 0)
            .animation(.easeOut(duration: 0.16), value: text.isEmpty)

            trailing()
        }
        .padding(.leading, 13)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(
            shape.fill(focused ? Tokens.recessFillLit : Tokens.recessFill)
                .overlay(
                    shape.fill((tint ?? .clear).opacity(!isEmpty ? 0.045 : 0))
                )
        )
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(focused ? Tokens.recessRimLit : Tokens.recessRim,
                               lineWidth: 0.5)
        )
        .animation(.smooth(duration: 0.25), value: tint)
        .animation(.easeOut(duration: 0.2), value: focused)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isEmpty)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: fieldHeight)

        if let pulse {
            box.intentChangePulse(on: pulse, shape: shape, tint: pulseTint)
        } else {
            box
        }
    }
}

/// Thumbnails for images explicitly pasted into a compose. Shared by the idle
/// prompt and every follow-up surface so an attachment has the same preview,
/// removal affordance, and overflow treatment before the first and later rounds.
struct ComposeImagesAttachedLine: View {
    let images: [NSImage]
    let onRemove: (Int) -> Void

    @State private var hoveredIndex: Int?

    /// A task can carry 20 images, far more than fits across the panel or a
    /// detached window, so the strip shows the first few and counts the rest.
    private static let stripMax = 6

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(images.prefix(Self.stripMax).enumerated()),
                    id: \.offset) { index, image in
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .overlay(alignment: .topTrailing) {
                        Button { onRemove(index) } label: {
                            Image(systemName: "xmark")
                                .font(.sf(8, weight: .bold))
                                .foregroundStyle(Tokens.text1)
                                .frame(width: 15, height: 15)
                                .background(Circle().fill(Color.black.opacity(0.66)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .offset(x: 5, y: -5)
                        .opacity(hoveredIndex == index ? 1 : 0)
                        .allowsHitTesting(hoveredIndex == index)
                    }
                    .onHover { inside in
                        withAnimation(.easeOut(duration: 0.12)) {
                            hoveredIndex = inside
                                ? index
                                : (hoveredIndex == index ? nil : hoveredIndex)
                        }
                    }
            }
            if images.count > Self.stripMax {
                Text("+\(images.count - Self.stripMax)")
                    .font(.sf(10, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.text4)
                    .frame(width: 26, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
            }
        }
        // The x badges overhang their thumbnails; give the row that room back.
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
