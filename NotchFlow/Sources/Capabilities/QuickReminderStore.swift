import Combine
import Foundation

public enum QuickReminderSaveState: Equatable, Sendable {
    case idle
    case saving
    case saved
    case failed
}

/// When a quick reminder should fire. Deliberately a handful of presets rather
/// than a date picker: the whole surface is one line of text and one menu.
public enum QuickReminderSchedule: String, CaseIterable, Codable, Identifiable, Sendable {
    /// Whatever moment the typed line names ("call mom tomorrow 6pm"). Falls
    /// back to no date when the line names nothing.
    case whenTyped
    case inOneHour
    case thisEvening
    case tomorrowMorning
    case noDate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .whenTyped: "When typed"
        case .inOneHour: "In an hour"
        case .thisEvening: "This evening"
        case .tomorrowMorning: "Tomorrow 9 AM"
        case .noDate: "No date"
        }
    }

    /// Evening means 8 PM; if that has already passed, the next one.
    public static let eveningHour = 20
    public static let morningHour = 9

    /// `parsed` is the date read out of the reminder's own text by the caller —
    /// only `.whenTyped` uses it, so the presets stay pure date arithmetic.
    public func fireDate(from now: Date, calendar: Calendar = .current, parsed: Date? = nil) -> Date? {
        switch self {
        case .noDate:
            return nil
        case .whenTyped:
            return parsed
        case .inOneHour:
            return now.addingTimeInterval(3_600)
        case .thisEvening:
            let evening = calendar.date(bySettingHour: Self.eveningHour, minute: 0, second: 0, of: now)
            guard let evening else { return nil }
            if evening > now { return evening }
            return calendar.date(byAdding: .day, value: 1, to: evening)
        case .tomorrowMorning:
            guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else { return nil }
            return calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: tomorrow)
        }
    }
}

/// The quick-reminder surface's state: one line of text, one schedule, and the
/// outcome of the last save. Unlike `QuickNoteStore` nothing is written on a
/// timer — a reminder fires an alarm, so it is only ever saved when the user
/// says so. The draft and the schedule are persisted, because the panel folds
/// the moment the pointer leaves and a half-typed reminder must survive that.
@MainActor
public final class QuickReminderStore: ObservableObject {
    /// `(text, due, completion)`. The app layer supplies the EventKit write; the
    /// store stays free of it so it can be driven straight from tests.
    public typealias Writer = (String, Date?, @escaping @MainActor (Bool) -> Void) -> Void

    @Published public var draft: String { didSet { persist() } }
    @Published public var schedule: QuickReminderSchedule { didSet { persist() } }
    @Published public private(set) var saveState: QuickReminderSaveState = .idle

    private let defaults: UserDefaults
    private let draftKey = "notchflow.quickReminder.draft.v1"
    private let scheduleKey = "notchflow.quickReminder.schedule.v1"
    private let writer: Writer

    public init(defaults: UserDefaults = .standard, writer: @escaping Writer) {
        self.defaults = defaults
        self.writer = writer
        draft = defaults.string(forKey: draftKey) ?? ""
        schedule = defaults.string(forKey: scheduleKey)
            .flatMap(QuickReminderSchedule.init(rawValue:)) ?? .whenTyped
    }

    public var canSave: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && saveState != .saving
    }

    /// `parsed` is the date the caller read out of `draft` (the app layer owns
    /// the natural-language parser). Only consulted for `.whenTyped`.
    public func save(now: Date = .now, calendar: Calendar = .current, parsed: Date? = nil) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, saveState != .saving else { return }
        let due = schedule.fireDate(from: now, calendar: calendar, parsed: parsed)
        saveState = .saving
        writer(text, due) { [weak self] success in
            guard let self else { return }
            if success {
                draft = ""
                schedule = .whenTyped
                defaults.removeObject(forKey: draftKey)
                saveState = .saved
            } else {
                saveState = .failed
            }
        }
    }

    /// Typing again after an outcome clears the badge, so the row never reads
    /// "Saved" over a line that has not been saved.
    public func draftChanged() {
        guard saveState == .saved || saveState == .failed else { return }
        saveState = .idle
    }

    private func persist() {
        if draft.isEmpty {
            defaults.removeObject(forKey: draftKey)
        } else {
            defaults.set(draft, forKey: draftKey)
        }
        defaults.set(schedule.rawValue, forKey: scheduleKey)
    }
}
