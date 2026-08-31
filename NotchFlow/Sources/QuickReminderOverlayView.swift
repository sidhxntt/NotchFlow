import AppKit
import SwiftUI

/// One line of text, one schedule menu, one Save — the reminder twin of the
/// Quick note card. Nothing is written on a timer here: a reminder rings, so it
/// is only ever saved on an explicit Return or Save.
struct QuickReminderOverlayView: View {
    @ObservedObject var store: QuickReminderStore
    let close: () -> Void

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Quick reminder", systemImage: "checklist")
                    .font(.sf(13, weight: .bold)).foregroundStyle(Tokens.text1)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.sf(10, weight: .bold))
                        .frame(width: 25, height: 25)
                        .background(Color.white.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(Tokens.text3)
                .accessibilityLabel("Close Quick Reminder")
            }

            TextField("", text: $store.draft, prompt: Text("Remind me to…")
                .foregroundStyle(Tokens.placeholder))
                .textFieldStyle(.plain)
                .font(.sf(12, weight: .regular))
                .foregroundStyle(Tokens.text1)
                .focused($fieldFocused)
                .onSubmit(save)
                .onChange(of: store.draft) { _, _ in store.draftChanged() }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Color.black.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 8) {
                // Stock menu picker, so the schedule list is the platform's own
                // glass dropdown — same control as the focus durations.
                Picker(selection: $store.schedule) {
                    ForEach(QuickReminderSchedule.allCases) { option in
                        Text(title(for: option)).tag(option)
                    }
                } label: {
                    Text("When").font(.sf(10, weight: .semibold)).foregroundStyle(Tokens.text3)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .tint(Tokens.accent)
                .fixedSize()
                .accessibilityLabel("Reminder time")

                Spacer(minLength: 2)

                Button(action: save) {
                    Text(store.saveState == .saving ? "Saving…" : "Save")
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .foregroundStyle(store.canSave ? Tokens.text1 : Tokens.text3)
                        .background(Tokens.accent.opacity(store.canSave ? 0.28 : 0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!store.canSave)
            }

            HStack(spacing: 7) {
                Text(statusText)
                    .font(.sf(10, weight: .medium)).foregroundStyle(statusColor)
                    .lineLimit(1)
                if store.saveState == .idle {
                    Button("Open Reminders") {
                        NSWorkspace.shared.open(
                            URL(fileURLWithPath: "/System/Applications/Reminders.app"))
                    }
                    .buttonStyle(.plain)
                    .font(.sf(10, weight: .semibold))
                    .foregroundStyle(Tokens.accent)
                    .lineLimit(1)
                    .accessibilityLabel("Open Reminders")
                }
            }
        }
        .padding(11)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .onAppear { fieldFocused = true }
    }

    private func save() {
        // The parser lives in the app layer (it is EventKit-adjacent), so the
        // date named in the line is read here and handed to the store.
        store.save(parsed: RemindersService.futureDate(in: store.draft))
    }

    /// `.whenTyped` names the moment it actually found, so the menu says what
    /// will happen instead of making the user guess whether the line parsed.
    private func title(for option: QuickReminderSchedule) -> String {
        guard option == .whenTyped else { return option.title }
        guard let parsed = RemindersService.futureDate(in: store.draft) else {
            return "No date in text"
        }
        return parsed.formatted(date: .abbreviated, time: .shortened)
    }

    private var statusText: String {
        switch store.saveState {
        case .idle:
            return "Only saves it to Apple Reminders"
        case .saving:
            return "Saving to Apple Reminders…"
        case .saved:
            return "Saved to Apple Reminders"
        case .failed:
            return "Couldn’t save — your text is safe"
        }
    }

    private var statusColor: Color {
        store.saveState == .failed ? Tokens.danger : Tokens.text3
    }
}
