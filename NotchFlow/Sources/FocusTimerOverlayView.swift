import SwiftUI

struct FocusTimerOverlayView: View {
    @ObservedObject var store: FocusTimerStore
    let close: () -> Void
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    // Flexible columns with square cells: the squares grow to consume the
    // tracker's width, so the gaps stay at the 3pt spacing on any panel width.
    private let columns = Array(repeating: GridItem(.flexible(minimum: 4), spacing: 3),
                                count: PomodoroOverlayLayout.activityWeekColumns)
    private var calendar: Calendar { .current }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            timingColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            streakColumn
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The close button hangs off the whole card, not the left column, so it
        // lands in the card's top-right corner like Quick Note's does instead of
        // in the middle of the two columns.
        .overlay(alignment: .topTrailing) { closeButton }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onReceive(timer) { date in
            now = date
            store.refresh(at: date)
        }
        .onAppear {
            store.refresh()
            // The timer is on screen; the resting notch's shoulders would only be
            // repeating what this card already says.
            store.acknowledgeTransition()
        }
    }

    private var timingColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
            HStack(spacing: 6) {
                durationPicker(title: "Focus", value: $store.focusMinutes,
                               presets: PomodoroDurationPresets.focus, tint: Tokens.accent)
                durationPicker(title: "Break", value: $store.breakMinutes,
                               presets: PomodoroDurationPresets.breakTime, tint: Tokens.text3)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.phase == .break ? "Break" : "Focus timer")
                        .font(.sf(10, weight: .semibold)).foregroundStyle(Tokens.text3)
                    Text(readout)
                        .font(.system(size: 23, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Tokens.text1)
                }
                Spacer(minLength: 2)
                // Padding and capsule INSIDE the label: applied outside the
                // Button they only pushed the pill outward while the clickable
                // area stayed the width of the word.
                Button { primaryAction() } label: {
                    Text(primaryActionTitle)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(Tokens.text1)
                        .background(Tokens.accent.opacity(0.28), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                if store.phase != .ready {
                    Button(action: store.stop) {
                        Text("Stop")
                            .font(.sf(10, weight: .medium)).foregroundStyle(Tokens.text3)
                            .padding(.horizontal, 4).padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var streakColumn: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Day streak")
                .font(.sf(12, weight: .bold)).foregroundStyle(Tokens.text1)
            Text("\(store.currentStreak(at: now)) focused days")
                .font(.sf(10.5, weight: .semibold)).foregroundStyle(Tokens.accent)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 3) {
                ForEach(trackerDays, id: \.self) { day in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.09))
                        // Deeper accent the more focus blocks the day holds, over
                        // the empty well so a single session still reads as blue.
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Tokens.accent.opacity(
                                    PomodoroOverlayLayout.shade(forSessions: store.sessions(on: day))))
                        }
                        .overlay {
                            if calendar.isDateInToday(day) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .stroke(Tokens.text2, lineWidth: 1)
                            }
                        }
                        .aspectRatio(1, contentMode: .fit)
                        .accessibilityLabel(day.formatted(date: .abbreviated, time: .omitted))
                        .accessibilityValue("\(store.sessions(on: day)) focus sessions")
                }
            }
        }
    }

    private var header: some View {
        Label("Focus Timer", systemImage: "timer")
            .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.sf(10, weight: .bold))
                .frame(width: 25, height: 25)
                .background(Color.white.opacity(0.08), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain).foregroundStyle(Tokens.text3)
        .accessibilityLabel("Close Focus Timer")
    }

    /// A stock `Picker` in menu style: the system draws the dropdown, so it gets
    /// the platform's glass menu, the selected checkmark, keyboard control and
    /// VoiceOver for free instead of a hand-rolled disclosure list.
    private func durationPicker(title: String, value: Binding<Int>, presets: [Int],
                                tint: Color) -> some View {
        Picker(selection: value) {
            ForEach(options(for: value.wrappedValue, in: presets), id: \.self) { minutes in
                Text(PomodoroDurationPresets.label(for: minutes)).tag(minutes)
            }
        } label: {
            // Kept on the picker itself so the caption sits on the control's own
            // baseline instead of wrapping onto a second line above it.
            Text(title).font(.sf(10, weight: .semibold)).foregroundStyle(Tokens.text3)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .tint(tint)
        .fixedSize()
        .accessibilityLabel("\(title) duration")
    }

    /// A restored session can hold a duration that is no longer a preset (older
    /// builds, or a clamped value). Offer it alongside the presets so the picker
    /// shows the real duration instead of an empty title.
    private func options(for current: Int, in presets: [Int]) -> [Int] {
        PomodoroDurationPresets.contains(current, in: presets) ? presets : (presets + [current]).sorted()
    }

    private var readout: String {
        let seconds = Int(store.remaining(at: now))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private var primaryActionTitle: String {
        if store.phase == .ready { return "Start" }
        return store.isRunning ? "Pause" : "Resume"
    }

    private func primaryAction() {
        if store.phase == .ready { store.start() }
        else if store.isRunning { store.pause() }
        else { store.resume() }
    }

    /// Newest first: today owns the top-left square and history runs away from
    /// it, so the square with the ring is where the eye lands first.
    private var trackerDays: [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<PomodoroOverlayLayout.activityDayCount)
            .compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }
}
