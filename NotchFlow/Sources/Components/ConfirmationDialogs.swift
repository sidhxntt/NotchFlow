import SwiftUI
import AppKit
import Combine
import PDFKit
import ImageIO

/// The app's existing centered dialog layer: one whole-surface scrim and the
/// exact airy Liquid Glass slab used by destructive confirmation. Editors that
/// need the same modal hierarchy reuse this container instead of inventing a
/// popover or another card treatment.
struct ConfirmationDialogOverlay<Content: View>: View {
    var onDismiss: () -> Void
    var outerPadding: CGFloat = 24
    /// Light caught in the slab's rim, in colour (see `ConfirmationDialogGlass`).
    /// Off for the destructive confirmations — a card asking whether to throw work
    /// away should not be the prettiest thing on screen.
    var edgeGlow: Bool = false
    let content: Content

    init(onDismiss: @escaping () -> Void,
         outerPadding: CGFloat = 24,
         edgeGlow: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.onDismiss = onDismiss
        self.outerPadding = outerPadding
        self.edgeGlow = edgeGlow
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            content
                .background { ConfirmationDialogGlass(edgeGlow: edgeGlow) }
                .padding(outerPadding)
        }
    }
}

private struct ConfirmationDialogGlass: View {
    var edgeGlow: Bool = false

    /// The hues the rim refracts, in the order they run around it. Deliberately
    /// desaturated and few: real glass splits light into a narrow band, and four
    /// pale hues at low alpha read as that, where a full spectrum reads as a toy.
    private static let rimHues: [Color] = [
        Color(red: 0.52, green: 0.80, blue: 1.00),   // cool blue
        Color(red: 0.72, green: 0.58, blue: 1.00),   // violet
        Color(red: 1.00, green: 0.62, blue: 0.78),   // rose
        Color(red: 1.00, green: 0.84, blue: 0.60),   // warm amber
        Color(red: 0.52, green: 0.80, blue: 1.00),   // back to the start
    ]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack {
            shape.fill(.clear)
                .nativeGlass(in: shape)
                .overlay(shape.fill(Color.black.opacity(0.16)))
            shape
                .fill(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                     startPoint: .top, endPoint: .center))
                .blendMode(.plusLighter)

            if edgeGlow {
                // Colour only in the RIM, and only as light: an angular sweep of
                // pale hues, blurred so it has no drawn edge of its own and added
                // (plusLighter) so it brightens the glass instead of painting a
                // border on it. Two passes — a tight one that lives in the hairline
                // and a wide, fainter one that bleeds a few points inward.
                let sweep = AngularGradient(colors: Self.rimHues,
                                            center: .center, angle: .degrees(-45))
                shape.strokeBorder(sweep, lineWidth: 1.4)
                    .blur(radius: 2.5)
                    .blendMode(.plusLighter)
                    .opacity(0.55)
                shape.strokeBorder(sweep, lineWidth: 4)
                    .blur(radius: 9)
                    .blendMode(.plusLighter)
                    .opacity(0.22)
            }

            shape.strokeBorder(
                LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.75)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.40), radius: 22, y: 12)
    }
}

/// The destructive "Clear recent history?" confirmation, rendered as a card
/// **centered over the whole island** rather than a popover anchored to the Clear
/// pill (which dropped it down near the bottom of the panel). A dim scrim catches
/// outside taps to cancel; the card itself floats in the middle of the glass.
struct ClearHistoryConfirm: View {
    /// Rows filed in the last 24 hours, and the archive's total. The narrow scope is
    /// only offered when it's a real choice — with nothing recent (0) or nothing
    /// *but* recent (== total), both buttons would do the same thing, so the card
    /// falls back to the plain Cancel / Clear History pair.
    var lastDayCount: Int
    var totalCount: Int
    /// Agent's Recent surface is a hard source scope. Its destructive action is
    /// therefore one explicit Agent-only clear, not the global time-range chooser.
    var agentOnly = false
    var onCancel: () -> Void
    var onConfirm: (NotchModel.HistoryClearScope) -> Void

    private var offersScopeChoice: Bool {
        !agentOnly && lastDayCount > 0 && lastDayCount < totalCount
    }

    var body: some View {
        ConfirmationDialogOverlay(onDismiss: onCancel) {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text(L(agentOnly ? "clear.agent.title" : "clear.title"))
                        .font(.sf(15, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                    Text(L(agentOnly
                           ? "clear.agent.body"
                           : (offersScopeChoice ? "clear.body.scope" : "clear.body")))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if agentOnly {
                    VStack(spacing: 8) {
                        ConfirmDialogButton(title: L("clear.agent.confirm"),
                                            kind: .destructive) { onConfirm(.agent) }
                        ConfirmDialogButton(title: L("clear.cancel"),
                                            kind: .quiet,
                                            action: onCancel)
                    }
                } else if offersScopeChoice {
                    // Two reaches, stacked mild-first: the day window reads as plain
                    // glass, "Everything" as red-tinted glass. Cancel drops out of the
                    // material entirely so three capsules don't read as three peers.
                    VStack(spacing: 8) {
                        ConfirmDialogButton(title: L("clear.scope.lastDay"),
                                            kind: .neutral) { onConfirm(.lastDay) }
                        ConfirmDialogButton(title: L("clear.scope.all"),
                                            kind: .destructive) { onConfirm(.chat) }
                        ConfirmDialogButton(title: L("clear.cancel"),
                                            kind: .quiet,
                                            action: onCancel)
                    }
                } else {
                    HStack(spacing: 10) {
                        ConfirmDialogButton(title: L("clear.cancel"), kind: .neutral, action: onCancel)
                        ConfirmDialogButton(
                            title: L(agentOnly ? "clear.agent.confirm" : "clear.confirm"),
                            kind: .destructive
                        ) { onConfirm(agentOnly ? .agent : .chat) }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: 280)
        }
    }
}

/// The Force Click gate: macOS's own "Look up & data detectors" is bound to the
/// same press, so arming NotchFlow's gesture while that is on would put two panels
/// on one click. Shown *instead of* applying the setting — the rung the user
/// picked is held until they come back, which is why the dialog is a hand-off to
/// System Settings rather than a warning to wave away.
///
/// One button, on purpose: there is no "arm it anyway". Two panels on one press
/// is broken, not a trade-off, so the only way forward is the System Settings
/// hand-off (the scrim still dismisses, leaving the rung unarmed).
///
/// Wears the `ClearHistoryConfirm` clothes (scrim, Liquid Glass slab, the same
/// `ConfirmDialogButton` pair) because it is the same object: a card centered
/// over the island that owns the panel until it's answered.
struct ForceClickLookupDialog: View {
    /// The overlay does not contribute to its island's intrinsic size. Reserve
    /// this much vertical room at the host so the instructional image retains a
    /// useful size instead of becoming the flexible element SwiftUI compresses.
    static let minimumIslandHeight: CGFloat = 360

    /// Opens System Settings → Trackpad. The dialog stays up behind it: the
    /// preference is re-read when NotchFlow comes back, and the held rung applies
    /// itself the moment it reads Off.
    var onOpenSettings: () -> Void
    var onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCancel)

            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text(L("forceClick.lookup.title"))
                        .font(.sf(15, weight: .semibold))
                        .foregroundStyle(Tokens.text1)
                    Text(L("forceClick.lookup.body"))
                        .font(.sf(12))
                        .foregroundStyle(Tokens.text3)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Which row, on which page — the sentence above names it, the
                // picture points at it.
                Image("TrackpadLookupHint")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 154)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Tokens.hairline, lineWidth: 0.75)
                    )
                    .accessibilityHidden(true)

                ConfirmDialogButton(title: L("forceClick.lookup.open"),
                                    kind: .neutral,
                                    action: onOpenSettings)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: 380)
            .background {
                // Same glass recipe as `ClearHistoryConfirm` — see the note there.
                let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
                ZStack {
                    shape.fill(.clear)
                        .nativeGlass(in: shape)
                        .overlay(shape.fill(Color.black.opacity(0.16)))
                    shape
                        .fill(LinearGradient(colors: [.white.opacity(0.12), .clear],
                                             startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter)
                    shape.strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.08)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.75)
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.40), radius: 22, y: 12)
            }
            .padding(12)
        }
    }
}

/// A full-width Liquid Glass button for the confirmation card — the app's own
/// `glassCapsule` material (genuine `.glassEffect` on macOS 26+, blur fallback
/// below), washed white for a neutral action and red for the destructive one. The
/// `quiet` kind carries no material at all: it's the Cancel that sits *below*
/// stacked choices, where a third capsule would read as a third option. Brightens on
/// hover and gives under the press, like every other glass control in the panel.
struct ConfirmDialogButton: View {
    var title: String
    var kind: Kind
    var action: () -> Void

    enum Kind { case neutral, destructive, quiet }

    @State private var hovering = false

    private var label: Color {
        switch kind {
        case .destructive: Tokens.danger
        case .neutral: Tokens.text1
        case .quiet: hovering ? Tokens.text1 : Tokens.text3
        }
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.sf(13, weight: .semibold))
                .foregroundStyle(label)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .glassButtonSkin(kind: kind, hovering: hovering)
                .contentShape(Capsule())
        }
        .buttonStyle(ConfirmDialogPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

private extension View {
    /// The capsule's material, split out so the `quiet` kind can opt out of glass
    /// entirely (a bare hover wash) while the other two share `glassCapsule`.
    @ViewBuilder
    func glassButtonSkin(kind: ConfirmDialogButton.Kind, hovering: Bool) -> some View {
        switch kind {
        case .quiet:
            self.background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0)))
        case .neutral:
            self.glassCapsule(in: Capsule(), brighter: hovering)
        case .destructive:
            self.glassCapsule(in: Capsule(), brighter: hovering, tint: Tokens.danger)
        }
    }
}

/// Liquid Glass gives under a press. A touch of squash on the whole capsule, on the
/// panel's usual short spring — the material's own interactive highlight
/// (`.glassEffect(.clear.interactive())` inside `glassCapsule`) does the rest.
private struct ConfirmDialogPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.72),
                       value: configuration.isPressed)
    }
}
