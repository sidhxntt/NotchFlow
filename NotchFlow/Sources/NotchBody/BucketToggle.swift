import SwiftUI
import AppKit

/// The persistent destination pill that anchors the bucket row — the panel's
/// one explicit top-level choice, and the ONE place where routing shows itself.
/// Its first half is the live destination: it reads "Ask" at rest and becomes
/// "Note" / "Remind · Daily" (mark and colour with it) the moment the classifier
/// — or Tab — points the line somewhere else. Its second half arms the
/// folder-scoped agent compose, and only exists where an agent CLI does.
///
/// Words in one glass capsule washed with the active side's colour — the
/// ManageFilterChip recipe: the selected word bright, the other dim, no thumb,
/// no divider; the wash alone says which side is live. A plain click is enough
/// of a gate because arming is inert — it only unfurls the chips row; a run
/// still needs a folder, a typed task, and an explicit Enter.
struct BucketTogglePill: View {
    @ObservedObject var model: NotchModel

    /// The pill's whole geometry, as five constants: the mark's slot, the gap from
    /// the mark to its word, a word's leading padding, the soft edge its label is
    /// wiped open with, and the gap between the two words. Both the words AND the
    /// well below are laid out from these same numbers, which is what keeps the
    /// flip a single continuous move.
    ///
    /// `wipeSoft` is carved out of what used to be the word's trailing padding, so
    /// the label's clip ends in a fade instead of a razor cut — every outer
    /// measurement stays exactly what it was (`wordPad + wipeSoft + wordTrailPad`
    /// is still 9 + 9), only the last 8pt of the box is now a falloff instead of
    /// dead air.
    static let iconSlot: CGFloat = 18
    static let labelGap: CGFloat = 5
    static let wordPad: CGFloat = 9
    static let wipeSoft: CGFloat = 8
    static let wordTrailPad: CGFloat = wordPad - wipeSoft
    private static let wordGap: CGFloat = 2
    /// The glass capsule's own inset around the two words.
    static let sidePad: CGFloat = 3

    /// How wide the label's box is: the soft edge alone once the word is wiped
    /// shut, the gap plus the spelled-out word plus that edge when it is open.
    static func labelBoxWidth(_ title: String, spelled: Bool) -> CGFloat {
        spelled ? labelGap + BucketWord.labelWidth(title) + wipeSoft : wipeSoft
    }

    /// How wide a half is: always its mark, plus the spelled-out word when live.
    private static func wordWidth(_ title: String, spelled: Bool) -> CGFloat {
        wordPad + iconSlot + labelBoxWidth(title, spelled: spelled) + wordTrailPad
    }

    /// Where Enter sends the line right now, as far as the Ask half is concerned.
    /// An armed Agent bucket owns the line, so this half shows the face you'd get
    /// BACK by tapping it — the pinned mode, which is exactly what leaving the
    /// bucket restores (`setAgentBucket(false)`). It used to hard-code Ask, so a
    /// pinned Capture turned back into a speech bubble the moment Agent was armed
    /// and the half advertised a destination that tapping it wouldn't give you.
    static func destination(_ model: NotchModel) -> NotchModel.Panel {
        model.agentComposeActive ? (NotchModel.storedSubmitMode ?? .chat)
                                 : model.effectiveSubmitPanel
    }

    private var destination: NotchModel.Panel { Self.destination(model) }

    /// The Ask half's word — the destination *spelled out*: "Ask",
    /// "Capture · Note", "Capture · Reminder · Daily". This is the panel's one
    /// place where the routing shows itself; there is no ghost trailing the caret
    /// any more. Capture's two leaves share the noun and differ only in the dimmer
    /// suffix, so the pair reads as one destination with two landing places rather
    /// than two modes to pick between.
    static func askWord(_ model: NotchModel) -> String {
        switch destination(model) {
        case .chat:              return L("hint.ask")
        case .note, .reminder:   return L("hint.capture") + model.submitLabelSuffix
        }
    }

    private var askWord: String { Self.askWord(model) }

    /// …and its mark: bubble for Ask, one pencil for both faces of Capture. The
    /// bell used to sit on Remind, and a second mark is exactly what made the two
    /// look like separate modes — whether it rings is the suffix's job to say, not
    /// a different icon's.
    private var askMark: LucideIcons.Mark {
        switch destination {
        case .chat:              return LucideIcons.messageCircle
        case .note, .reminder:   return LucideIcons.pencilLine
        }
    }

    var body: some View {
        let ask = askWord
        // `swapKey` is the destination CATEGORY, not the word: it rolls between
        // Ask and Capture faces without turning the chat composer into an Agent
        // mode selector.
        BucketWord(title: ask, icon: askMark, active: true,
                   swapKey: destination == .reminder ? .note : destination) {
            model.toggleSubmitPanel()
        }
        // Horizontal only (the words still stretch to the pill's 30pt height):
        // pins the row to exactly the width `wordWidth` computes, so a parent that
        // hands the pill extra room can never stretch a word out from under the
        // well below.
        .fixedSize(horizontal: true, vertical: false)
        // The active side sits in a recessed inner-shadow well — the pushed-in
        // "pin" look, so the live half reads as pressed into the glass rather than
        // just brighter. The 3pt inset matches the pill's 3pt horizontal padding,
        // so the well keeps an even margin to the glass on all four sides.
        //
        // ONE persistent shape behind BOTH words, positioned by the same word
        // arithmetic the words themselves are built from — not a per-word
        // background that inserts on one side and removes on the other, and not a
        // `matchedGeometryEffect` pair. Flipping the bucket just changes a width
        // and an offset, so the well GLIDES across and resizes on the pill's single
        // spring and can never disagree with the words it sits behind (the model
        // picker card's armed-row wash learned this the same way).
        .background(alignment: .leading) {
            Capsule().fill(
                Color.white.opacity(0.17)
                    .shadow(.inner(color: .black.opacity(0.48), radius: 3, y: 1))
            )
            // A hairline top rim sells the recessed glass edge — the well reads as
            // a brighter, more solid pane than a barely-there wash.
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .frame(width: Self.wordWidth(ask, spelled: true))
            .padding(.vertical, 3)
        }
        // Match the Recent disclosure chevron's fixed 30pt (IdleTrailingCluster's
        // chipSize) so the pill and the trailing dropdown line up on the row.
        .frame(height: 30)
        .padding(.horizontal, Self.sidePad)
        // The glass takes the destination's colour, so Capture ambers the capsule
        // the way the ghost tints its word.
        .glassCapsule(in: Capsule(), brighter: false,
                      tint: destination.intentTint)
        // Fast and all but critically damped. A 30pt switch is not a panel: the
        // old 0.34/0.82 took ~300ms and arrived with a visible bounce, where the
        // tab bar this is modelled on settles a comparable move in ~175ms flat.
        // 0.26/0.86 lands at ~220ms with under half a point of overshoot — quick
        // enough to read as one snap, with just enough spring left to belong to
        // the rest of the panel. The same spring carries an Ask→Note→Remind word
        // change, so the capsule resizes on one curve either way.
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: ask)
        .accessibilityElement(children: .contain)
    }
}

/// One word of the bucket pill. Both halves carry their mark (the destination's —
/// bubble / pencil / bell — on the first, a code bracket `</>` for Agent); the
/// active one spells its name out beside it, the inactive one collapses to the bare
/// icon — dim, brightening on hover, the way over to the other side.
/// Clicking the active Ask half cycles Ask ⇄ Capture (same path as Tab); the
/// active Agent half stays a no-op — arming is cheap, re-arming is not a switch.
///
/// **The pill has two switches, so it has two axes.** Changing BUCKET
/// (Ask⇄Agent) is horizontal: the well glides, one word wipes open while the
/// other wipes shut. Changing DESTINATION (Ask⇄Note⇄Remind) doesn't move
/// between halves at all — it substitutes a face in place — so it gets the
/// vertical one: mark and word roll up together and the new pair rises from
/// below, while the capsule springs to the new word's width around them. Read
/// the two side by side and you can tell which switch fired without reading a
/// single glyph, which is the whole point of spending the second axis on it.
private struct BucketWord: View {
    var title: String
    var icon: LucideIcons.Mark
    var active: Bool
    /// What a *roll* is keyed on — the live destination for the Ask half, `nil`
    /// for the Agent half, whose face is fixed. Keyed on the category rather than
    /// `title` so the bell doesn't somersault when only the recurrence suffix
    /// changes; that edit stays a quiet cross-fade inside the word (see
    /// `contentTransition` below).
    var swapKey: NotchModel.Panel?
    var action: () -> Void

    @State private var hovering = false

    /// How far the outgoing face lifts and the incoming one rises from — small on
    /// purpose. This is a 30pt pill, not a page: past ~6pt the roll stops reading
    /// as a substitution and starts reading as something falling through the
    /// glass. 5pt is enough to give the swap a direction, and still lets a 15pt
    /// glyph travel inside `rollBox` without the clip biting it.
    private static let rollTravel: CGFloat = 5
    /// The vertical room the word's clip leaves for that travel: the 12pt line
    /// (~15pt tall) plus the roll on both sides. Sized here rather than left to
    /// the text's own height, because `.clipped()` would otherwise slice the
    /// rolling glyphs off at their own baseline box.
    private static let rollBox: CGFloat = 26

    /// The destination swap itself. Asymmetric for the same reason the wipe's ink
    /// is: share one curve and both faces sit at half opacity through the middle
    /// of the move — the double exposure this replaced. So the old face is gone in
    /// ~100ms, before it has travelled far, and the new one comes up just behind
    /// it. Up-and-out / up-and-in in one direction always: a wheel that turns one
    /// way reads as "the destination changed", where a reversible roll would keep
    /// promising an order the classifier doesn't actually walk in.
    private static let roll = AnyTransition.asymmetric(
        insertion: .offset(y: rollTravel).combined(with: .opacity)
            .animation(.easeOut(duration: 0.20).delay(0.04)),
        removal: .offset(y: -rollTravel).combined(with: .opacity)
            .animation(.easeIn(duration: 0.10))
    )

    /// The spelled-out word's exact width. `Font.sf` IS the system face, so
    /// `NSFont.systemFont` measures the very glyphs SwiftUI will draw — which turns
    /// the label into plain arithmetic instead of a geometry read that only settles
    /// a frame later, and hands the pill's well the SAME number this word is sized
    /// from. The +1 keeps the last glyph clear of the clip below.
    static func labelWidth(_ title: String) -> CGFloat {
        ceil(NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        ).size().width) + 1
    }

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(active ? Tokens.text1
                                        : (hovering ? Tokens.text2 : Tokens.text4))
                // Asymmetric on purpose: the trailing 8pt the word used to pad
                // with now lives inside the label's box as the wipe's falloff.
                .padding(.leading, BucketTogglePill.wordPad)
                .padding(.trailing, BucketTogglePill.wordTrailPad)
                // Fill the pill's full height so the well behind it can be inset a
                // uniform amount on every side, instead of being sized by the text
                // and floating with an uneven top/bottom margin.
                .frame(maxHeight: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
        // No per-word `active` animation: the word's reveal and the dim⇄bright
        // colour change ride the pill's single spring (BucketTogglePill's
        // `.animation(value:)`), so both halves and the well move as one shot
        // rather than each easing on its own.
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isSelected] : [])
    }

    private var content: some View {
        // Nothing here is ever inserted or removed by the BUCKET flip — that's the
        // whole point. The mark is permanent on BOTH halves, and the word stays in
        // the tree too, revealed by an animatable WIDTH (0 ⇄ its measured width)
        // under a clip. So the switch is one continuous interpolation on the pill's
        // spring: the word wipes open beside its mark while the other wipes shut
        // and the well glides between them. A `if active { Text }` instead would
        // pop the label in and out of layout and leave the outgoing word fading
        // outside the flow — the desynchronized version of this.
        //
        // A DESTINATION change is the one thing that does swap identity, because
        // it has to: the mark is a Path and two paths can't interpolate. It stays
        // "one shot" by keeping both faces in the same slot (the ZStacks below)
        // and rolling them together on one curve — the horizontal geometry never
        // learns a swap happened, it just springs to the new word's width.
        //
        // The mark is bigger AND heavier than a menu glyph (15/2.0 → 1.25pt of
        // stroke, against the menu's 13/1.75 → 0.95pt), because it carries more: on
        // the inactive side, with the word wiped shut, it is the ONLY thing naming
        // the other half of the switch, and it does that at 40% ink instead of the
        // menu's 55%. `weight` is grid-relative, so holding it at 2.0 through the
        // size bump is what lets the stroke ride up with the glyph rather than
        // staying pinned to the set's thinner line — deliberate, not an oversight.
        // (The SF mark this replaced ran `.bold` for the same reason.) It takes the
        // active side's ink from the shared `foregroundStyle`, so a live mark is
        // exactly as bright as the word beside it.
        HStack(spacing: 0) {
            // Two different paths can't interpolate, so a destination change
            // (bubble→pencil→bell) swaps identity and ROLLS. The ZStack is what
            // makes that a substitution rather than a shove: identity-swapped
            // views both live in the layout while the transition runs, and side
            // by side in the HStack the outgoing mark would push the word along
            // in front of it.
            ZStack {
                LucideIcon(mark: icon, size: 15, weight: 2.0)
                    .id(swapKey)
                    .transition(Self.roll)
            }
            // Same air around the glyph the SF mark had (11pt in 14), scaled.
            .frame(minWidth: BucketTogglePill.iconSlot)
            ZStack(alignment: .leading) {
                Text(title)
                    .font(.sf(12, weight: .medium))
                    // Within ONE destination the word can still change — a
                    // recurrence suffix ("Remind · Daily"→"· Weekly"). Identity
                    // holds across that, so it cross-fades in place instead of
                    // rolling the whole word for an edit the routing didn't make.
                    .contentTransition(.opacity)
                    // Ideal width regardless of the frame below, so the wipe slides
                    // the clip across a fully-typeset word instead of re-wrapping it.
                    .fixedSize()
                    .padding(.leading, BucketTogglePill.labelGap)
                    // The ink is the ONE thing that does NOT ride the pill's spring.
                    // Sharing that curve leaves both words parked at half opacity
                    // through the middle of the flip — two ghosts, the exact
                    // opposite of one continuous shot. So the outgoing word is gone
                    // in ~70ms (before its box has travelled far) and the incoming
                    // one comes up just BEHIND the wipe front, never ahead of it.
                    //
                    // It lives INSIDE the rolled view on purpose: an
                    // `.animation(_:value:)` wrapping the `.transition` below would
                    // put the roll inside a second animation scope, and which curve
                    // won would then be SwiftUI's business rather than ours. Here
                    // the two switches own strictly separate modifiers.
                    .opacity(active ? 1 : 0)
                    .animation(active ? .easeOut(duration: 0.16).delay(0.04)
                                      : .easeIn(duration: 0.07),
                               value: active)
                    // …and the word rolls on the SAME key and the same beat as the
                    // mark beside it, so the pair leaves and arrives as one face.
                    .id(swapKey)
                    .transition(Self.roll)
            }
                // Width is the wipe's (springs with the destination's word length);
                // the height is the roll's headroom. Both words sit leading-aligned
                // inside it, so a roll never nudges the mark or the pill's rim.
                .frame(width: BucketTogglePill.labelBoxWidth(title, spelled: active),
                       height: Self.rollBox,
                       alignment: .leading)
                .clipped()
                // …and the front itself is a gradient, not a razor: the glyph
                // crossing it rises through the falloff instead of being sliced
                // down the middle. At rest the 8pt zone sits past the last glyph,
                // in what used to be the word's trailing padding, so a settled
                // label is fully opaque.
                .mask(alignment: .leading) {
                    HStack(spacing: 0) {
                        Rectangle()
                        LinearGradient(colors: [.black, .black.opacity(0)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: BucketTogglePill.wipeSoft)
                    }
                }
        }
    }
}
