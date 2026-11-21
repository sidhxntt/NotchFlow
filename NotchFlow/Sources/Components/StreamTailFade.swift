import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

// MARK: - Streaming tail glyph fade (macOS 15+)

/// Which glyphs of the streaming tail are *fresh* — revealed within the last fade
/// window — recorded as character-count milestones with timestamps. This is the
/// per-NEW-CHARACTER fade the old `TailFadeIn` couldn't do: that one re-faded the
/// whole tail block per chunk (a long paragraph visibly dimmed and re-lit on every
/// token — why it was neutered to a no-op). Here only glyphs *beyond* the length
/// already seen animate; everything already read never re-fades.
struct GlyphBirths: Equatable {
    struct Milestone: Equatable {
        var count: Int
        var at: TimeInterval
    }

    /// Glyph indices below this are settled — they always draw at full ink.
    var settled = 0
    /// Recent growth milestones, oldest first: a glyph at index i (settled ≤ i <
    /// count) was born at the first milestone whose `count` exceeds i.
    var fresh: [Milestone] = []

    mutating func note(length: Int, at now: TimeInterval) {
        // A shrink means the tail re-parsed into a different block shape (e.g. a
        // list marker completing); settle to the new length rather than replaying
        // a fade over text the reader has already seen.
        if length < (fresh.last?.count ?? settled) {
            settled = length
            fresh.removeAll()
            return
        }
        fresh.append(Milestone(count: length, at: now))
        // Milestones past the fade window draw at full ink anyway — fold them
        // into `settled` so the per-glyph lookup stays O(few) instead of growing
        // with the stream (30 ticks/s over a long answer).
        let horizon = now - 0.3
        while let first = fresh.first, first.at < horizon {
            settled = max(settled, first.count)
            fresh.removeFirst()
        }
    }

    func opacity(forGlyph index: Int, at now: TimeInterval, fade: TimeInterval) -> Double {
        if index < settled { return 1 }
        guard let birth = fresh.first(where: { index < $0.count })?.at else {
            // Laid out before its growth milestone was noted (same frame):
            // newborn. With no milestones at all, nothing is animating — full ink.
            return fresh.isEmpty ? 1 : 0
        }
        let age = now - birth
        return age >= fade ? 1 : max(0, age / fade)
    }
}

/// Draws the tail block's glyphs with recency-based opacity: glyphs the pacer
/// revealed within the last 180ms ramp from 0 → 1, everything older is plain
/// ink. Glyph order stands in for character order (true for the linear text
/// these rows hold), so no attribute plumbing through the markdown parser is
/// needed. Redraw cadence comes for free while streaming: the paced reveal
/// mutates the text ~30×/s, and each pass re-reads the clock here.
@available(macOS 15.0, *)
struct StreamTailRenderer: TextRenderer {
    var births: GlyphBirths

    /// How long one newly-revealed glyph takes to reach full ink.
    static let fade: TimeInterval = 0.18

    func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
        let now = ProcessInfo.processInfo.systemUptime
        var index = 0
        for line in layout {
            for run in line {
                for slice in run {
                    let opacity = births.opacity(forGlyph: index, at: now, fade: Self.fade)
                    if opacity >= 1 {
                        ctx.draw(slice)
                    } else {
                        var faded = ctx
                        faded.opacity = opacity
                        faded.draw(slice)
                    }
                    index += 1
                }
            }
        }
    }
}

/// Owns the birth history for one tail block and feeds it to the renderer.
/// Mounted fresh when a block becomes the tail, so a brand-new block fades in
/// whole (it IS entirely new text) and a block that graduates to the settled
/// head simply drops the renderer — full ink, no re-fade.
@available(macOS 15.0, *)
private struct StreamTailFade: ViewModifier {
    let textLength: Int
    @State private var births = GlyphBirths()

    func body(content: Content) -> some View {
        content
            .textRenderer(StreamTailRenderer(births: births))
            .onAppear {
                births.note(length: textLength, at: ProcessInfo.processInfo.systemUptime)
            }
            .onChange(of: textLength) { _, newValue in
                births.note(length: newValue, at: ProcessInfo.processInfo.systemUptime)
            }
    }
}

/// Availability shim for the printed voice's per-glyph fade (macOS 15+); on the
/// 14.0 deployment floor the streaming text falls back to the paced reveal alone.
///
/// Only the printed voice is handled here. A handwritten line is written by
/// `InkWriting`, which lives inside `InlineMarkdownText` — it needs the laid-out
/// characters to know which one it is drawing, and that string only exists there.
struct TailFadeIfAvailable: ViewModifier {
    var active: Bool
    var length: Int
    var hand: Bool = false

    func body(content: Content) -> some View {
        if active, !hand, #available(macOS 15.0, *) {
            content.modifier(StreamTailFade(textLength: length))
        } else {
            content
        }
    }
}
