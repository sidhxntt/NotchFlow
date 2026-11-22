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
    // MARK: - Product mode

    /// Chat and Agent are an optional layer over NotchFlow's always-available
    /// Media and Utilities workspaces. Disabling it immediately returns the
    /// workspace to Media, so a hidden Chat or Agent surface cannot linger.
    var agenticModeRow: some View {
        settingRow(label: "Agentic mode",
                   info: "Show Chat and Agent alongside Media and Utilities.") {
            Toggle("", isOn: $capabilities.agenticModeEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.text2)
        }
    }

    /// Media has no account and no library of its own — it reads whatever player
    /// the system is running. That leaves exactly two decisions worth making, and
    /// both of them change real behaviour: which player the notch follows when
    /// more than one holds a track, and whether a playing track is allowed to
    /// occupy the resting notch.
    var mediaSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Playback")
                .captionLabel()
            mediaPreferredSourceRow
            mediaClosedNotchRow
            Text("Media follows the active system player. Playback controls live in the Media tab.")
                .font(.sf(11.5))
                .foregroundStyle(Tokens.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
    }

    /// Pinning a player. Worth having because Music.app keeps a `current track`
    /// populated for days after playback stops, so a stale Music window and a live
    /// browser tab can otherwise trade the notch back and forth.
    private var mediaPreferredSourceRow: some View {
        settingRow(label: "Follow player",
                   info: "Which player the notch reads. Automatic follows whichever one is actually playing.",
                   aligned: true) {
            GlassMenu(title: capabilities.preferredMediaSource?.displayName ?? "Automatic") {
                Button { capabilities.preferredMediaSource = nil } label: {
                    menuOption("Automatic", selected: capabilities.preferredMediaSource == nil)
                }
                ForEach(MediaSource.allCases, id: \.self) { source in
                    Button { capabilities.preferredMediaSource = source } label: {
                        menuOption(source.displayName,
                                   selected: capabilities.preferredMediaSource == source)
                    }
                }
            }
        }
    }

    private var mediaClosedNotchRow: some View {
        settingRow(label: "Show in closed notch",
                   info: "Let a playing track claim one of the resting notch's ears. Off keeps media inside the opened panel.",
                   aligned: true,
                   forceStacked: true) {
            Toggle("", isOn: Binding(
                get: { mediaInClosedNotch },
                set: {
                    Haptics.levelChange()
                    mediaInClosedNotch = $0
                    MediaPresentationPolicy.showsInClosedNotch = $0
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Tokens.text2)
        }
    }
    // MARK: - Utilities

    /// The Utilities category was one switch, for a workspace that carries a
    /// clipboard, a focus timer, a File tray, a calendar with a weather line, and
    /// a nine-chip action strip. These are the settings those surfaces actually
    /// read — every one of them is stored state the running code consults, not a
    /// switch that only moves itself.
    var utilitiesSettingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clipboard")
                .captionLabel()
            clipboardHistoryRow
            clipboardLimitRow
            Text("Focus timer")
                .captionLabel()
                .padding(.top, 2)
            focusBlockRow
            focusBreakRow
            Text("File tray")
                .captionLabel()
                .padding(.top, 2)
            fileTrayRow
            Text("Calendar")
                .captionLabel()
                .padding(.top, 2)
            temperatureUnitRow
            Text("Calculator")
                .captionLabel()
                .padding(.top, 2)
            calculatorKeypadRow
            calculatorTapeRow
            calculatorPrecisionRow
            Text("Converter")
                .captionLabel()
                .padding(.top, 2)
            converterCategoriesRow
            converterCategoryRow
            currencyRatesRow
            Text("Quick actions")
                .captionLabel()
                .padding(.top, 2)
            quickActionsRow
        }
    }

    /// How many entries the history keeps. Already persisted and already honoured
    /// by the store's ring buffer — it simply had no control.
    private var clipboardLimitRow: some View {
        settingRow(label: "Keep the last",
                   info: "How many clipboard entries are retained. Older ones fall off the end; pinned ones stay.",
                   aligned: true) {
            GlassMenu(title: "\(clipboardLimit) items") {
                ForEach(Self.clipboardLimitChoices, id: \.self) { limit in
                    Button {
                        clipboardLimit = limit
                        clipboardHistory.limit = limit
                    } label: {
                        menuOption("\(limit) items", selected: limit == clipboardLimit)
                    }
                }
            }
            .disabled(!clipboardHistory.isEnabled)
            .opacity(clipboardHistory.isEnabled ? 1 : 0.45)

            if !clipboardHistory.items.isEmpty {
                SettingActionButton(title: clipboardHistory.items.count == 1
                    ? "Clear 1 item" : "Clear \(clipboardHistory.items.count) items") {
                    Haptics.levelChange()
                    clipboardHistory.clearHistory()
                }
            }
        }
    }

    private static let clipboardLimitChoices = [10, 20, 50, 100, 200]

    private var focusBlockRow: some View {
        settingRow(label: "Focus block",
                   info: "How long one Pomodoro runs. Changing it while a block is live rebases the remaining time.",
                   aligned: true) {
            GlassMenu(title: PomodoroDurationPresets.label(for: focusTimer.focusMinutes)) {
                ForEach(PomodoroDurationPresets.focus, id: \.self) { minutes in
                    Button { focusTimer.focusMinutes = minutes } label: {
                        menuOption(PomodoroDurationPresets.label(for: minutes),
                                   selected: minutes == focusTimer.focusMinutes)
                    }
                }
            }
        }
    }

    private var focusBreakRow: some View {
        settingRow(label: "Break",
                   info: "How long the break between focus blocks runs.",
                   aligned: true) {
            GlassMenu(title: PomodoroDurationPresets.label(for: focusTimer.breakMinutes)) {
                ForEach(PomodoroDurationPresets.breakTime, id: \.self) { minutes in
                    Button { focusTimer.breakMinutes = minutes } label: {
                        menuOption(PomodoroDurationPresets.label(for: minutes),
                                   selected: minutes == focusTimer.breakMinutes)
                    }
                }
            }
        }
    }

    /// The tray keeps whatever was dropped on it across relaunches, which is the
    /// point — but that also means it is the one Utilities surface that can
    /// quietly accumulate. This says what is in it and empties it.
    private var fileTrayRow: some View {
        settingRow(label: "Held items",
                   info: "Files dropped on the notch stay in the tray until removed. Clearing also deletes anything Notch staged itself.",
                   aligned: true) {
            Text(capabilities.shelfItems.isEmpty
                     ? "Empty"
                     : "\(capabilities.shelfItems.count) item\(capabilities.shelfItems.count == 1 ? "" : "s")")
                .font(.sf(12.5))
                .foregroundStyle(Tokens.text2)

            if !capabilities.shelfItems.isEmpty {
                SettingActionButton(title: "Clear") {
                    Haptics.levelChange()
                    capabilities.clearShelf()
                }
            }
        }
    }

    private var temperatureUnitRow: some View {
        settingRow(label: "Temperature",
                   info: "The unit for the reading under the panel's clock. System follows your region.",
                   aligned: true) {
            GlassMenu(title: temperatureUnit.label) {
                ForEach(WeatherUnitPreference.allCases, id: \.self) { unit in
                    Button {
                        temperatureUnit = unit
                        WeatherUnitPreference.current = unit
                    } label: {
                        menuOption(unit.label, selected: unit == temperatureUnit)
                    }
                }
            }
        }
    }

    // MARK: Calculator

    private var calculatorKeypadRow: some View {
        SettingsLocalState(UserDefaults.standard.object(forKey: CalculatorPreferences.showsKeypadKey) as? Bool ?? true) { shows in
            settingRow(label: "Keypad",
                       info: "Show the tap keypad beside the display. With it off the Calculator is just the field: type a sum and press Return.") {
                Toggle("", isOn: Binding(
                    get: { shows.wrappedValue },
                    set: {
                        Haptics.levelChange()
                        shows.wrappedValue = $0
                        UserDefaults.standard.set($0, forKey: CalculatorPreferences.showsKeypadKey)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.text2)
            }
        }
    }

    /// The tape of recent results lives only on this Mac; this is where it can be
    /// switched off, seen, and emptied without opening the notch.
    private var calculatorTapeRow: some View {
        SettingsLocalState(CalculatorTapeSettingsState.current) { tape in
            settingRow(label: "Keep a tape",
                       info: "Return or = saves the last \(CalculatorHistory.limit) results on this Mac so you can tap one to reuse it.") {
                Toggle("", isOn: Binding(
                    get: { tape.wrappedValue.enabled },
                    set: {
                        Haptics.levelChange()
                        tape.wrappedValue.enabled = $0
                        UserDefaults.standard.set($0, forKey: CalculatorPreferences.keepsTapeKey)
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Tokens.text2)

                if tape.wrappedValue.count > 0 {
                    SettingActionButton(title: "Clear \(tape.wrappedValue.count)") {
                        Haptics.levelChange()
                        var history = CalculatorHistory.load()
                        history.clear()
                        history.save()
                        tape.wrappedValue.count = 0
                    }
                }
            }
        }
    }

    private var calculatorPrecisionRow: some View {
        SettingsLocalState(UserDefaults.standard.object(forKey: CalculatorPreferences.precisionKey) as? Int
                           ?? CalculatorPreferences.automaticPrecision) { places in
            settingRow(label: "Decimals",
                       info: "Automatic shows as many digits as the answer needs. A fixed count always rounds to it, which suits money.",
                       aligned: true) {
                GlassMenu(title: CalculatorPreferences.precisionLabel(places.wrappedValue)) {
                    ForEach(CalculatorPreferences.precisionChoices, id: \.self) { choice in
                        Button {
                            places.wrappedValue = choice
                            UserDefaults.standard.set(choice, forKey: CalculatorPreferences.precisionKey)
                        } label: {
                            menuOption(CalculatorPreferences.precisionLabel(choice), selected: choice == places.wrappedValue)
                        }
                    }
                }
            }
        }
    }

    // MARK: Converter

    /// Which unit families the Converter's strip shows — the same chip control as
    /// the Utilities strip below, for the same reason: it edits a row of chips.
    private var converterCategoriesRow: some View {
        SettingsLocalState(UserDefaults.standard.string(forKey: ConverterCategoryVisibility.hiddenKey) ?? "") { hidden in
            VStack(alignment: .leading, spacing: 8) {
                settingLabel("Convert between",
                             info: "Pick the kinds of units the Converter offers. Hide the ones you never use; at least one stays on.")
                FlowLayout(hSpacing: 6, vSpacing: 6) {
                    ForEach(ConversionCategory.allCases) { category in
                        let shown = ConverterCategoryVisibility.visible(hiddenRaw: hidden.wrappedValue).contains(category)
                        Button {
                            Haptics.levelChange()
                            guard let next = ConverterCategoryVisibility.setting(category, visible: !shown,
                                                                                 in: hidden.wrappedValue) else { return }
                            hidden.wrappedValue = next
                            UserDefaults.standard.set(next, forKey: ConverterCategoryVisibility.hiddenKey)
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: category.symbolName)
                                    .font(.sf(10, weight: .semibold))
                                Text(category.title)
                                    .font(.sf(11.5, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(shown ? Tokens.text1 : Tokens.text4)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Capsule().fill(.white.opacity(shown ? 0.10 : 0.03)))
                            .overlay(Capsule().strokeBorder(.white.opacity(shown ? 0.16 : 0.07), lineWidth: 0.5))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(category.title)
                        .accessibilityAddTraits(shown ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// The Converter reopens on whatever was used last; this picks the family it
    /// starts in, resetting the pair to that family's everyday default.
    private var converterCategoryRow: some View {
        SettingsLocalState(ConverterSelection.load(visible: ConverterCategoryVisibility.visible()).category) { category in
            settingRow(label: "Opens on",
                       info: "The kind of units the Converter starts in. It also remembers the last pair you used.",
                       aligned: true) {
                GlassMenu(title: category.wrappedValue.title) {
                    ForEach(ConverterCategoryVisibility.visible()) { choice in
                        Button {
                            category.wrappedValue = choice
                            ConverterSelection(category: choice).save()
                        } label: {
                            menuOption(choice.title, selected: choice == category.wrappedValue)
                        }
                    }
                }
            }
        }
    }

    private var currencyRatesRow: some View {
        settingRow(label: "Currency rates",
                   info: "Daily reference rates from the European Central Bank, fetched without a key or account and kept on this Mac so currency works offline. Nothing about you is sent.",
                   aligned: true) {
            CurrencyRatesSettingStatus(store: CurrencyRateStore.shared)
        }
    }

    /// Which chips the Utilities strip offers. Rendered as a wrapping row of
    /// selectable chips rather than nine switch rows: the strip itself is a row
    /// of chips, so the control reads as the thing it edits.
    private var quickActionsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            settingLabel("Shown in the strip",
                         info: "Hide a chip you never use so the strip stops scrolling past it. The surface behind it stays reachable.")
            FlowLayout(hSpacing: 6, vSpacing: 6) {
                ForEach(QuickUtilityAction.allCases) { action in
                    quickActionChip(action)
                }
            }
        }
    }

    private func quickActionChip(_ action: QuickUtilityAction) -> some View {
        let shown = !quickActionsHidden.contains(action.id)
        return Button {
            // Refused when it would empty the strip — the switch must not claim a
            // change the store declined to make.
            guard QuickUtilityStrip.setVisible(!shown, for: action) else {
                Haptics.levelChange()
                return
            }
            Haptics.levelChange()
            quickActionsHidden = QuickUtilityStrip.hidden
        } label: {
            HStack(spacing: 5) {
                Image(systemName: action.symbolName)
                    .font(.sf(10, weight: .semibold))
                Text(action.title)
                    .font(.sf(11.5, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(shown ? Tokens.text1 : Tokens.text4)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Capsule().fill(.white.opacity(shown ? 0.10 : 0.03)))
            .overlay(Capsule().strokeBorder(.white.opacity(shown ? 0.16 : 0.07), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(shown ? .isSelected : [])
    }
}

/// Holds a little view-local state for a settings row whose value lives in
/// UserDefaults rather than on `InlineSettingsView` itself — a stored property
/// can't be added from an extension, and these two rows don't warrant one.
private struct SettingsLocalState<Value, Content: View>: View {
    @State private var value: Value
    private let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        _value = State(initialValue: initial)
        self.content = content
    }

    var body: some View { content($value) }
}

/// The tape row's two pieces of state, read together from UserDefaults.
private struct CalculatorTapeSettingsState {
    var enabled: Bool
    var count: Int

    static var current: CalculatorTapeSettingsState {
        CalculatorTapeSettingsState(
            enabled: UserDefaults.standard.object(forKey: CalculatorPreferences.keepsTapeKey) as? Bool ?? true,
            count: CalculatorHistory.load().records.count)
    }
}

/// Live status for the currency rates row: which day's rates are cached, and a
/// Refresh that shows its own progress.
private struct CurrencyRatesSettingStatus: View {
    @ObservedObject var store: CurrencyRateStore

    var body: some View {
        HStack(spacing: 10) {
            Text(status)
                .font(.sf(12.5))
                .foregroundStyle(store.state == .failed && store.rates == nil ? Tokens.danger : Tokens.text2)
            if store.state == .loading {
                ProgressView().controlSize(.mini)
            } else {
                SettingActionButton(title: "Refresh") {
                    Haptics.levelChange()
                    Task { await store.refresh() }
                }
            }
        }
    }

    private var status: String {
        if let rates = store.rates {
            return store.state == .failed ? "\(rates.publishedLabel) · couldn’t update" : "From \(rates.publishedLabel)"
        }
        return store.state == .failed ? "Couldn’t load" : "Not loaded yet"
    }
}
