import SwiftUI
import AppKit

// MARK: - Agent status dot

private struct AgentPermissionPulse: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.orange)
            .frame(width: 8, height: 8)
            .shadow(color: .orange.opacity(0.6), radius: pulsing ? 5 : 1)
            .scaleEffect(reduceMotion ? 1 : (pulsing ? 1.0 : 0.72))
            .opacity(reduceMotion ? 0.9 : (pulsing ? 1 : 0.55))
            .onAppear { if !reduceMotion { pulsing = true } }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.85)
                .repeatForever(autoreverses: true), value: pulsing)
    }
}

struct AgentSessionStatusIcon: View {
    let status: AgentSessionStatus

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = false

    private var tint: Color {
        switch status {
        case .needsYou: return Tokens.danger
        case .question: return .orange
        case .planning, .planReady: return Tokens.captureTint
        case .working: return Tokens.accent
        case .done: return .green
        case .interrupted: return Tokens.captureTint
        }
    }

    var body: some View {
        Image(systemName: status.symbolName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(tint.opacity(0.15)))
            .rotationEffect(.degrees((status == .working || status == .planning) && !reduceMotion && phase ? 12 : 0))
            .scaleEffect((status == .working || status == .planning) && !reduceMotion && phase ? 1.08 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: phase)
            .onAppear { if (status == .working || status == .planning) && !reduceMotion { phase = true } }
            .accessibilityHidden(true)
    }
}

/// The outcome of an agent run in one 7pt glass bead: purple done, red failed,
/// grey cancelled. A *working* run draws nothing here — its activity line and
/// ticking clock already say it's alive, and a pulsing dot on top of them was
/// only noise. The slot is held either way, so the phrase beside it doesn't
/// slide sideways the moment the bead lights up.
struct AgentStatusDot: View {
    let running: Bool
    let outcome: AgentTaskManager.Outcome?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    private var tint: Color {
        switch outcome {
        case .success:   return .green
        case .failure:   return Tokens.danger
        case .cancelled: return Tokens.text4
        default:         return Tokens.accent
        }
    }

    var body: some View {
        ZStack {
            if running {
                // A working run breathes a flat translucent white dot in the slot —
                // the "it's alive" pulse that rides alongside the ticking activity
                // line, swinging transparency and scale as it breathes so it reads
                // without any glass sheen.
                Circle()
                    .fill(.white.opacity(0.5))
                    .opacity(reduceMotion ? 0.5 : (breathing ? 0.7 : 0.26))
                    .scaleEffect(reduceMotion ? 1 : (breathing ? 1.0 : 0.72))
                    .onAppear { if !reduceMotion { breathing = true } }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.9)
                        .repeatForever(autoreverses: true),
                               value: breathing)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            } else {
                // A settled run marks its slot with a flat coloured dot.
                Circle()
                    .fill(tint.opacity(0.92))
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: 7, height: 7)
        .animation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.7),
                   value: running)
    }
}
// MARK: - Agent compose chips (XII: agent-to-Codex)

/// The shared face of one armed-compose chip: leading glyph + label in the
/// clipboard preset chips' exact glass capsule, so the agent row reads as
/// the same species living in the same slot.
private struct AgentChipFace<Icon: View>: View {
    var icon: Icon
    var title: String
    var hovering: Bool
    /// Overrides the resting ink. Used when the chip is reporting something wrong
    /// rather than naming a setting — the Ask chip with no model configured.
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            icon
            Text(title)
                .font(.sf(12, weight: .light))
                .foregroundStyle(tint ?? (hovering ? Tokens.text2 : Tokens.text4))
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Capsule())
    }
}

/// A compose chip that fires an action on tap (the folder chip).
struct AgentComposeChip<Icon: View>: View {
    var title: String
    var tint: Color? = nil
    var action: () -> Void
    @ViewBuilder var icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            AgentChipFace(icon: icon(), title: title, hovering: hovering, tint: tint)
        }
        .buttonStyle(GlassPressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}

/// A compose chip that opens a picker menu on click (model / effort). The
/// system menu indicator is hidden — the chip itself is the whole affordance,
/// like every other capsule in the row.
struct AgentComposeMenuChip<Icon: View, Items: View>: View {
    var title: String
    @ViewBuilder var items: () -> Items
    @ViewBuilder var icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Menu(content: items) {
            AgentChipFace(icon: icon(), title: title, hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: Tokens.hoverFade), value: hovering)
    }
}
