import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

@MainActor
extension InlineSettingsView {
    /// The collapsed-by-default tail of the General pane: plumbing nobody should
    /// have to walk past to reach the everyday rows. Same quiet disclosure line as
    /// `keySection` — it stays folded until the user opens it, whatever the proxy
    /// currently is.
    var advancedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) { advancedSectionOpen.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.sf(9, weight: .semibold))
                        .rotationEffect(.degrees(advancedSectionOpen ? 90 : 0))
                    Text(L("general.advanced"))
                        .font(.sf(12, weight: .medium))
                }
                .foregroundStyle(Tokens.text1)
                .padding(.horizontal, 10)
                .frame(height: 26)
                // The disclosure's own glass chip — a translucent pill that
                // brightens under the pointer, so the fold itself reads as a
                // control on the panel's glass rather than a bare line of text.
                .background(
                    Capsule()
                        .fill(.white.opacity(hoveredDisclosure == .advanced ? 0.12 : 0.06))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(hoveredDisclosure == .advanced ? 0.22 : 0.12),
                                      lineWidth: 0.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { hoveredDisclosure = .advanced }
                else if hoveredDisclosure == .advanced { hoveredDisclosure = nil }
            }
            .animation(.easeOut(duration: Tokens.hoverFade), value: hoveredDisclosure)

            if advancedSectionOpen {
                proxyRow
                    // Unfolds downward out of the disclosure line rather than
                    // popping in at full height.
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .clipped()
    }

    /// The proxy the whole app connects through — a manual value is forced onto
    /// both the app's own requests (`ProxyConfig.urlSession`) and the spawned
    /// agent CLIs. Empty = auto: the app follows the system proxy natively, and
    /// the CLIs (which inherit launchd's sparse environment, never the
    /// `HTTPS_PROXY` exported in a shell profile) fall back through the inherited
    /// env, macOS Network settings, then the login shell. The caption spells out
    /// what auto actually resolved to, so an empty field is never a mystery.
    private var proxyRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                Text(L("network.proxy"))
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                SettingInfo(L("network.proxy.hint"))
            }
            ZStack(alignment: .topLeading) {
                if model.proxyURL.isEmpty {
                    Text(L("network.proxy.placeholder"))
                        .font(.sf(13))
                        .foregroundStyle(Tokens.text3)
                        .allowsHitTesting(false)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                TextField("", text: Binding(
                    get: { model.proxyURL },
                    set: { model.proxyURL = $0 }
                ))
                    .textFieldStyle(.plain)
                    .font(.sf(13))
                    .foregroundStyle(Tokens.text1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    // Typing here counts as activity so a drifting pointer can't
                    // fold the panel mid-edit (same guard the API-key field uses).
                    .onChange(of: model.proxyURL) {
                        model.noteUserTyping()
                        refreshProxyStatus()
                    }
            }
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(.white.opacity(0.06))
            )
            Text(proxyStatus)
                .font(.sf(11))
                .foregroundStyle(Tokens.text3)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .onAppear { refreshProxyStatus() }
    }

    /// Resolving can spawn a login shell (the ".zshrc-only proxy" case), so it never
    /// runs on the render path — the caption fills in a beat later.
    private func refreshProxyStatus() {
        Task.detached(priority: .userInitiated) {
            let line = ProxyConfig.statusLine()
            await MainActor.run { proxyStatus = line }
        }
    }

    /// The global selected-text gesture has no keyboard binding: this is its one
    /// setting. Four ordered positions, quantized like the hover-sensitivity
    /// slider right above it — Off, Light, Medium, Firm. Off disarms the
    /// gesture entirely, so a plain click stays a plain click.
    var forceClickPressureRow: some View {
        detentSliderRow(label: L("general.forceClickPressure"),
                        info: L("general.forceClickPressure.hint"),
                        options: ForceClickPressure.allCases,
                        selected: model.forceClickPressure,
                        position: forceClickPressurePosition,
                        centers: $pressureTickCenters)
    }

    /// A detent slider and its tick labels, stacked under a full-width title row.
    ///
    /// These two used to sit beside their labels in the shared label column, with
    /// the slider pinned at 190pt. That layout could not hold: the column is sized
    /// to the widest label in the pane, and once the settings window went compact
    /// the longest of these titles ("Force click pressure", plus its ⓘ) ran out of
    /// column and drew straight over the slider's left end — the ⓘ disappeared
    /// under the thumb. Stacking removes the competition for horizontal space
    /// entirely: the title gets the whole row, the slider gets the whole row
    /// beneath it, and four tick labels have room to breathe at any window width.
    /// Half the width of the widest tick label, rounded up. "Instant" and "Medium"
    /// are the long ones at 10.5pt semibold; 30 clears them with room for a longer
    /// translation.
    private static let detentSliderInset: CGFloat = 30

    private func detentSliderRow<Option>(
        label: String,
        info: String,
        options: [Option],
        selected: Option,
        position: Binding<Double>,
        centers: Binding<[CGFloat]?>
    ) -> some View where Option: Identifiable & Equatable & Hashable,
                        Option: RawRepresentable, Option.RawValue == String {
        VStack(alignment: .leading, spacing: 6) {
            settingLabel(label, info: info)
            // The tick labels are positioned as a fraction of the slider's real
            // width (see `tickLabelRow`), so that width has to be a number rather
            // than "whatever is left" — hence the geometry read.
            GeometryReader { g in
                // Both the slider and the tick row are inset by the same amount,
                // so the fractions AppKit reports for its tick marks still line up
                // with where the labels are placed. The inset exists for the two
                // END labels: they are centred on ticks that sit at x=0 and
                // x=width, so without it half of "Click" and half of "Instant"
                // fall outside the row and get clipped away.
                let track = max(0, g.size.width - Self.detentSliderInset * 2)
                VStack(spacing: 2) {
                    NativeDetentSlider(value: position,
                                       ticks: options.count,
                                       tickCenters: centers)
                        .frame(width: track, height: 22)
                        .accessibilityLabel(label)

                    tickLabelRow(options, selected: selected,
                                 centers: centers.wrappedValue,
                                 width: track)
                }
                .padding(.horizontal, Self.detentSliderInset)
            }
            // Slider (22) + gap (2) + label row (14). Fixed because a
            // `GeometryReader` is greedy in both axes and would otherwise claim
            // the rest of the pane.
            .frame(height: 38)
        }
        // These rows are twice the height of a switch row; without a little air
        // under them the group reads as one dense block of sliders.
        .padding(.bottom, 4)
    }

    /// Labels under a detent slider, each centered on its tick's real x-position
    /// (from the slider's `rectOfTickMark`), so text sits squarely under the
    /// marks instead of under an equal-width division of the control.
    private func tickLabelRow<Option: Identifiable & Equatable & Hashable>(
        _ options: [Option],
        selected: Option,
        centers: [CGFloat]?,
        width: CGFloat
    ) -> some View where Option: RawRepresentable, Option.RawValue == String {
        ZStack {
            if let centers, centers.count == options.count {
                ForEach(Array(options.enumerated()), id: \.element) { index, option in
                    tickLabel(option, selected: selected)
                        .position(x: centers[index] * width, y: 7)
                }
            } else {
                // Until AppKit reports where its tick marks actually landed, fall
                // back to an even split — the row must never render blank.
                HStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element) { index, option in
                        tickLabel(option, selected: selected)
                            .frame(maxWidth: .infinity,
                                   alignment: index == 0 ? .leading
                                       : (index == options.count - 1 ? .trailing : .center))
                    }
                }
            }
        }
        .frame(width: width, height: 14)
    }

    private func tickLabel<Option: RawRepresentable & Equatable>(
        _ option: Option,
        selected: Option
    ) -> some View where Option.RawValue == String {
        let isSelected = option == selected
        return Text(optionLabel(option))
            .font(.sf(10.5, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Tokens.text1 : Tokens.text3)
            .lineLimit(1)
    }

    private func optionLabel<Option: RawRepresentable>(_ option: Option) -> String
    where Option.RawValue == String {
        if let pressure = option as? ForceClickPressure {
            return pressure.label
        }
        if let sensitivity = option as? HoverSensitivity {
            return sensitivity.label
        }
        return ""
    }

    private var forceClickPressurePosition: Binding<Double> {
        Binding(
            get: {
                Double(ForceClickPressure.allCases.firstIndex(of: model.forceClickPressure) ?? 2)
            },
            set: { position in
                let index = min(max(Int(position.rounded()), 0), ForceClickPressure.allCases.count - 1)
                // The gate (hold the rung while macOS's own lookup is armed) lives
                // on the model, because the dialog it raises does too.
                model.selectForceClickPressure(ForceClickPressure.allCases[index])
            }
        )
    }

    /// How readily the resting notch unfurls when the pointer reaches it. The
    /// four ordered policies map directly to a native, tick-mark-only NSSlider:
    /// Click, Low, Balanced, and Instant.
    var hoverSensitivityRow: some View {
        detentSliderRow(label: L("general.hoverSensitivity"),
                        info: L("general.hoverSensitivity.hint"),
                        options: HoverSensitivity.allCases,
                        selected: hoverSensitivity,
                        position: hoverSensitivityPosition,
                        centers: $hoverTickCenters)
    }

    private var hoverSensitivityPosition: Binding<Double> {
        Binding(
            get: {
                Double(HoverSensitivity.allCases.firstIndex(of: hoverSensitivity)
                       ?? HoverSensitivity.allCases.firstIndex(of: .balanced) ?? 0)
            },
            set: { position in
                let index = min(max(Int(position.rounded()), 0), HoverSensitivity.allCases.count - 1)
                selectHoverSensitivity(HoverSensitivity.allCases[index])
            }
        )
    }

    private func selectHoverSensitivity(_ newValue: HoverSensitivity) {
        guard newValue != hoverSensitivity else { return }
        hoverSensitivity = newValue
        // Through the model, not straight to `UserDefaults`: the island renders
        // the click level's flex off an observable mirror, which has to move too.
        model.applyHoverSensitivity(newValue)
    }

    /// Register or unregister the login item, keeping the toggle in sync with the
    /// OS. On success `launchAtLogin` already matches; on failure we snap it back
    /// to the real status so the switch never lies about what the system will do.
    func selectLaunchAtLogin(_ newValue: Bool) {
        launchAtLogin = newValue
        do {
            try LaunchAtLogin.setEnabled(newValue)
        } catch {
            // The OS refused (e.g. the item is disabled at the system level) —
            // fall back to the true status rather than leave a misleading switch.
            launchAtLogin = LaunchAtLogin.isEnabled
        }
    }
}
