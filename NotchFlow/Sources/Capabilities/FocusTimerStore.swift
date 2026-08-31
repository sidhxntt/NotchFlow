import Combine
import Foundation

public enum FocusTimerPhase: String, Codable, Equatable, Sendable {
    case ready
    case focus
    case `break`
}

/// A phase boundary the resting notch announces for a few minutes after it
/// happens — the only way the user hears about it with the panel folded.
public enum FocusTimerTransition: Equatable, Sendable {
    /// Focus ran out; the break is now counting down.
    case focusEnded
    /// The break ran out; the day is marked on the streak grid.
    case breakEnded
}

/// Persists a single focus/break session and the calendar days on which focus
/// was completed. Absolute end dates let the countdown reconcile after launch.
@MainActor
public final class FocusTimerStore: ObservableObject {
    /// One store for the whole app. The panel's `NotchBody` unmounts on every
    /// close, so a view-owned store could neither tick a running session nor
    /// notice a phase boundary while folded — and the resting notch's
    /// announcement is exactly what the user is waiting for at that moment.
    public static let shared = FocusTimerStore()

    public static let defaultFocusMinutes = 25
    public static let defaultBreakMinutes = 5
    /// How long a phase boundary stays on the resting notch's shoulders. Short on
    /// purpose: the running border is the standing signal, this is only the
    /// hand-off between the two phases.
    public static let transitionWindow: TimeInterval = 5

    @Published public private(set) var phase: FocusTimerPhase
    @Published public private(set) var isRunning: Bool
    @Published public private(set) var completedDayCount: Int
    @Published public private(set) var transition: FocusTimerTransition?

    // Clamping in a `didSet` would re-enter the setter (a `@Published` property is
    // a computed one, so the observer fires again) and overflow the stack the
    // moment a duration picker wrote through its binding. Clamp on the way in.
    @Published private var storedFocusMinutes: Int
    @Published private var storedBreakMinutes: Int

    public var focusMinutes: Int {
        get { storedFocusMinutes }
        set {
            let minutes = Self.clamp(newValue)
            rebaseActivePhaseDuration(from: storedFocusMinutes, to: minutes, phase: .focus)
            storedFocusMinutes = minutes
            persist()
        }
    }

    public var breakMinutes: Int {
        get { storedBreakMinutes }
        set {
            let minutes = Self.clamp(newValue)
            rebaseActivePhaseDuration(from: storedBreakMinutes, to: minutes, phase: .break)
            storedBreakMinutes = minutes
            persist()
        }
    }

    private let defaults: UserDefaults
    private let key = "notchflow.focusTimer.v1"
    private var endDate: Date?
    private var pausedSeconds: TimeInterval?
    /// Sessions completed per calendar day, not a set of days: the streak grid
    /// shades a square by how much focus it holds, the way a commit graph does.
    private var completedDays: [Date: Int]
    private var calendar: Calendar
    private var transitionAt: Date?
    private var ticker: Timer?

    public init(defaults: UserDefaults = .standard, calendar: Calendar = .current, now: Date = .now) {
        self.defaults = defaults
        self.calendar = calendar
        let saved = Self.load(from: defaults, key: key)
        phase = saved?.phase ?? .ready
        isRunning = saved?.isRunning ?? false
        storedFocusMinutes = Self.clamp(saved?.focusMinutes ?? Self.defaultFocusMinutes)
        storedBreakMinutes = Self.clamp(saved?.breakMinutes ?? Self.defaultBreakMinutes)
        endDate = saved?.endDate
        pausedSeconds = saved?.pausedSeconds
        completedDays = Self.tallies(from: saved, calendar: calendar)
        completedDayCount = completedDays.count
        refresh(at: now)
    }

    public func start(at now: Date = .now) {
        if phase == .ready {
            phase = .focus
            pausedSeconds = nil
            endDate = now.addingTimeInterval(duration(for: .focus))
            isRunning = true
        } else if !isRunning {
            resume(at: now)
            return
        }
        syncTicker()
        persist()
    }

    public func pause(at now: Date = .now) {
        guard phase != .ready, isRunning else { return }
        pausedSeconds = remaining(at: now)
        endDate = nil
        isRunning = false
        syncTicker()
        persist()
    }

    public func resume(at now: Date = .now) {
        guard phase != .ready, !isRunning else { return }
        endDate = now.addingTimeInterval(pausedSeconds ?? duration(for: phase))
        pausedSeconds = nil
        isRunning = true
        syncTicker()
        persist()
    }

    public func stop() {
        phase = .ready
        isRunning = false
        endDate = nil
        pausedSeconds = nil
        clearTransition()
        persist()
    }

    public func refresh(at now: Date = .now) {
        expireTransition(at: now)
        guard isRunning, let endDate, endDate <= now else {
            syncTicker()
            return
        }
        switch phase {
        case .focus:
            recordFocusCompletion(on: endDate)
            phase = .break
            self.endDate = endDate.addingTimeInterval(duration(for: .break))
            announce(.focusEnded, boundary: endDate, at: now)
        case .break:
            phase = .ready
            isRunning = false
            self.endDate = nil
            pausedSeconds = nil
            announce(.breakEnded, boundary: endDate, at: now)
        case .ready:
            isRunning = false
            self.endDate = nil
        }
        persist()
    }

    /// Drops the resting-notch announcement — the panel is showing the timer
    /// itself, so the shoulder copy would be saying what is already on screen.
    public func acknowledgeTransition() {
        guard transition != nil else { return }
        clearTransition()
        syncTicker()
    }

    /// A boundary only speaks if it JUST happened. Reconciling a session the app
    /// slept through would otherwise announce a focus block that ended hours ago.
    private func announce(_ kind: FocusTimerTransition, boundary: Date, at now: Date) {
        guard now.timeIntervalSince(boundary) <= Self.transitionWindow else {
            clearTransition()
            syncTicker()
            return
        }
        transition = kind
        transitionAt = now
        syncTicker()
    }

    private func expireTransition(at now: Date) {
        guard let transitionAt else { return }
        guard now.timeIntervalSince(transitionAt) > Self.transitionWindow else { return }
        clearTransition()
    }

    private func clearTransition() {
        transition = nil
        transitionAt = nil
    }

    /// A running countdown and a live announcement both need a heartbeat with the
    /// panel folded, and neither needs one when the timer is idle — the store owns
    /// its own second hand rather than borrowing the overlay's, which only exists
    /// while the panel is open.
    private func syncTicker() {
        let wanted = isRunning || transition != nil
        guard wanted != (ticker != nil) else { return }
        guard wanted else {
            ticker?.invalidate()
            ticker = nil
            return
        }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    public func remaining(at now: Date = .now) -> TimeInterval {
        if isRunning, let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return max(0, pausedSeconds ?? 0)
    }

    /// How far through the CURRENT phase the session is, 0…1 — the lap the
    /// resting notch's border traces, so one lap always means one phase.
    /// A paused session reads its frozen `pausedSeconds`, so the border holds
    /// exactly where it stopped.
    public func progress(at now: Date = .now) -> Double {
        guard phase != .ready else { return 0 }
        let total = duration(for: phase)
        guard total > 0 else { return 0 }
        return min(1, max(0, 1 - remaining(at: now) / total))
    }

    public func recordFocusCompletion(on date: Date) {
        let day = calendar.startOfDay(for: date)
        completedDays[day, default: 0] += 1
        completedDayCount = completedDays.count
        persist()
    }

    public func currentStreak(at now: Date = .now) -> Int {
        let today = calendar.startOfDay(for: now)
        var day: Date
        if isCompleted(on: today) {
            day = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), isCompleted(on: yesterday) {
            day = yesterday
        } else {
            return 0
        }

        var count = 0
        while isCompleted(on: day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }

    public func isCompleted(on date: Date) -> Bool {
        sessions(on: date) > 0
    }

    /// Focus blocks finished on `date`'s calendar day — the streak grid's shade.
    public func sessions(on date: Date) -> Int {
        completedDays[calendar.startOfDay(for: date)] ?? 0
    }

    private func duration(for phase: FocusTimerPhase) -> TimeInterval {
        TimeInterval((phase == .break ? breakMinutes : focusMinutes) * 60)
    }

    /// The duration picker changes the definition of the phase that is already
    /// under way. Keep its elapsed portion fixed by moving the deadline (or the
    /// frozen remaining time) by the selected-duration delta; otherwise the
    /// countdown and its progress ring would measure two different sessions.
    private func rebaseActivePhaseDuration(from oldMinutes: Int, to newMinutes: Int,
                                           phase changedPhase: FocusTimerPhase) {
        guard phase == changedPhase, oldMinutes != newMinutes else { return }
        let delta = TimeInterval((newMinutes - oldMinutes) * 60)
        if isRunning {
            endDate = endDate?.addingTimeInterval(delta)
        } else if let pausedSeconds {
            self.pausedSeconds = max(0, pausedSeconds + delta)
        }
    }

    private func persist() {
        let state = PersistedState(
            phase: phase,
            isRunning: isRunning,
            focusMinutes: focusMinutes,
            breakMinutes: breakMinutes,
            endDate: endDate,
            pausedSeconds: pausedSeconds,
            completedDayIntervals: nil,
            completedDayTallies: completedDays.map {
                DayTally(day: $0.key.timeIntervalSinceReferenceDate, sessions: $0.value)
            }
        )
        defaults.set(try? JSONEncoder().encode(state), forKey: key)
    }

    private static func load(from defaults: UserDefaults, key: String) -> PersistedState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    /// Reads the per-day tallies, falling back to the pre-tally format where a
    /// day was only ever a member of a set — one session each.
    private static func tallies(from saved: PersistedState?, calendar: Calendar) -> [Date: Int] {
        guard let saved else { return [:] }
        if let tallies = saved.completedDayTallies {
            return Dictionary(
                tallies.map { (calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: $0.day)),
                               max(1, $0.sessions)) },
                uniquingKeysWith: +)
        }
        return Dictionary(
            (saved.completedDayIntervals ?? [])
                .map { (calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: $0)), 1) },
            uniquingKeysWith: +)
    }

    private static func clamp(_ minutes: Int) -> Int { min(max(minutes, 1), 180) }
}

private struct DayTally: Codable {
    let day: TimeInterval
    let sessions: Int
}

private struct PersistedState: Codable {
    let phase: FocusTimerPhase
    let isRunning: Bool
    let focusMinutes: Int
    let breakMinutes: Int
    let endDate: Date?
    let pausedSeconds: TimeInterval?
    /// Pre-tally format: read for migration, never written again.
    let completedDayIntervals: [TimeInterval]?
    let completedDayTallies: [DayTally]?
}
