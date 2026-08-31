import SwiftUI

/// Awake, sleep, and screensaver — the three ways this session decides whether
/// the display stays lit, in one card. Left is the state you HOLD (awake, for
/// as long as you leave it on); right is the two things you DO once (sleep now,
/// screensaver now). That split is the same "state versus action" reasoning
/// `FocusTimerOverlayView` uses for its timing/streak columns.
struct PowerUtilityOverlayView: View {
    @ObservedObject var system: SystemUtilityService
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerRow
            HStack(alignment: .top, spacing: 12) {
                awakeColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionsColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var headerRow: some View {
        HStack {
            Label(L("utilities.power.title"), systemImage: "moon.zzz.fill")
                .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
            Spacer()
            closeButton
        }
    }

    private var awakeColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("utilities.keepAwake"))
                .font(.sf(11, weight: .semibold))
                .foregroundStyle(Tokens.text3)
            Button {
                system.toggleKeepAwake()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: system.isKeepingAwake ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .font(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(system.keepAwakeStatus)
                            .font(.sf(11.5, weight: .semibold))
                    }
                    Spacer(minLength: 4)
                    Toggle("", isOn: Binding(get: { system.isKeepingAwake },
                                             set: { system.setKeepAwake($0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(system.isKeepingAwake ? Color.orange : Tokens.text2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(system.isKeepingAwake ? Color.orange.opacity(0.14) : Color.white.opacity(0.05)))
            .animation(.easeOut(duration: 0.16), value: system.isKeepingAwake)

            HStack(spacing: 6) {
                Menu {
                    Button("15 minutes") { system.keepAwake(for: 15) }
                    Button("30 minutes") { system.keepAwake(for: 30) }
                    Button("1 hour") { system.keepAwake(for: 60) }
                    Button("2 hours") { system.keepAwake(for: 120) }
                    Divider()
                    Button("Until stopped") { system.setKeepAwake(true) }
                } label: {
                    Label("Duration", systemImage: "timer")
                        .font(.sf(10, weight: .medium))
                }
                .menuStyle(.button).buttonStyle(.plain)
                Spacer()
                Toggle("Display may sleep", isOn: Binding(
                    get: { system.allowsDisplaySleep },
                    set: { system.setKeepAwake(system.isKeepingAwake, allowsDisplaySleep: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.sf(9.5, weight: .medium))
                .disabled(!system.isKeepingAwake)
            }
            .foregroundStyle(Tokens.text3)
            .padding(.horizontal, 3)
        }
    }

    private var actionsColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("utilities.power.now"))
                .font(.sf(11, weight: .semibold))
                .foregroundStyle(Tokens.text3)
            actionRow(title: L("utilities.power.sleepDisplay"), symbol: "moon.fill") {
                system.sleepDisplayNow()
            }
            actionRow(title: L("utilities.power.screensaver"), symbol: "sparkles.tv.fill") {
                system.startScreenSaverNow()
            }
        }
    }

    private func actionRow(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.sf(11.5, weight: .medium))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.sf(8, weight: .bold)).foregroundStyle(Tokens.text3)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.text2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.sf(10, weight: .bold))
                .frame(width: 25, height: 25)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(Tokens.text3)
        .accessibilityLabel(L("utilities.power.close"))
    }
}
