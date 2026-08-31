import Foundation

/// The odometer behind Settings → Stats' **Tokens** figure.
///
/// One rule, and everything else follows from it: **this counts only what a
/// provider actually reported.** No estimate from character counts, no "about
/// four characters to a token" — a request whose response carries a `usage`
/// block adds its numbers here, and a request that reports nothing adds nothing.
/// A figure the user can't verify is worth having only if it's the real one.
///
/// The consequence is that the meter starts at zero on the version that
/// introduced it: nothing on disk from before then recorded a `usage` block, and
/// inventing one retroactively is exactly the estimate this refuses to make. The
/// tile's ⓘ says so, naming the version and the day counting began.
///
/// Unlike the rest of the pane, this is *not* derived from the archive — it's a
/// running total in `UserDefaults`, because the tokens a request spent are not a
/// property of the row it left behind (a title generation leaves no row; a
/// resumed agent run leaves one row for many calls). It only ever moves forward,
/// including across a Clear: the archive's Clear removes *rows*, and the tokens
/// those requests actually cost were still spent. An odometer, not a tally of
/// what's currently on disk.
final class TokenMeter: @unchecked Sendable {
    static let shared = TokenMeter()

    /// What the pane needs to draw the tile and write its note.
    struct Reading: Equatable {
        var total: Int
        /// When the first token was counted, and the app version it was counted
        /// on — the "counting started here" the ⓘ names. `nil` until the first
        /// request reports usage.
        var since: Date?
        var sinceVersion: String?
    }

    /// A short, provider-scoped record of values the CLI or API actually
    /// reported. This deliberately stores consumption, never an inferred plan
    /// limit: the monitor can say what happened in a local time window without
    /// pretending it knows a subscription's remaining allowance.
    struct UsageWindow: Equatable {
        var input: Int
        var output: Int
        var startsAt: Date
        var endsAt: Date

        var total: Int { input + output }
    }

    enum LocalWindow: Sendable {
        case fiveHours
        case week
    }

    private struct UsageEvent: Codable {
        let identifier: String?
        var project: String?
        let date: Date
        let provider: String
        let input: Int
        let output: Int
    }

    struct ProjectActivity: Identifiable, Equatable {
        let id: String
        let project: String
        let providers: [String]
        let sessionCount: Int
        let contextUsed: Int?
        let contextWindow: Int?
    }

    private struct ContextEvent: Codable {
        let date: Date
        let project: String?
        let used: Int
        let window: Int?
    }

    private let lock = NSLock()
    private let defaults: UserDefaults
    private let ledger: TokenLedger?
    private var total: Int
    private var since: Date?
    private var sinceVersion: String?
    private var events: [UsageEvent]
    private var latestContextByProvider: [String: ContextEvent]

    private enum Key {
        static let total = "stats.tokens.total"
        static let since = "stats.tokens.since"
        static let sinceVersion = "stats.tokens.sinceVersion"
        static let events = "stats.tokens.events.v1"
        static let providerContexts = "stats.tokens.providerContexts.v1"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        total = defaults.integer(forKey: Key.total)
        since = defaults.object(forKey: Key.since) as? Date
        sinceVersion = defaults.string(forKey: Key.sinceVersion)
        let legacyEvents = (defaults.data(forKey: Key.events)).flatMap {
            try? JSONDecoder().decode([UsageEvent].self, from: $0)
        } ?? []
        ledger = AppSupportPaths.appDirectory.map {
            TokenLedger(url: $0.appendingPathComponent("TokenEvents.jsonl", isDirectory: false))
        }
        let journalEvents = ledger.flatMap { journal in
            try? journal.records().compactMap { try? JSONDecoder().decode(UsageEvent.self, from: $0) }
        } ?? []
        events = journalEvents.isEmpty ? legacyEvents : journalEvents
        // Migration is intentionally after both decodes have succeeded. The
        // legacy blob remains the recovery copy if Application Support cannot
        // be created or its first atomic write fails.
        if !legacyEvents.isEmpty, journalEvents.isEmpty, let ledger,
           let records = try? legacyEvents.map({ try JSONEncoder().encode($0) }),
           (try? ledger.replace(with: records)) != nil {
            defaults.removeObject(forKey: Key.events)
        }
        latestContextByProvider = (defaults.data(forKey: Key.providerContexts)).flatMap {
            try? JSONDecoder().decode([String: ContextEvent].self, from: $0)
        } ?? [:]
    }

    /// Add one request's reported usage.
    ///
    /// `input` is everything the model read — prompt plus, on providers that
    /// bill them separately, cache reads and cache writes; the caller folds
    /// those in, because only it knows its provider's spelling. Both sides are
    /// summed into one figure: the tile says "tokens", and a user asking how
    /// much they've run through the notch means the whole exchange, not one
    /// direction of it.
    ///
    /// Safe to call from any thread — every provider reports from whatever queue
    /// its stream is being parsed on.
    func record(input: Int, output: Int, provider: String = "Chat",
                recordedAt: Date = Date(), identifier: String? = nil, project: String? = nil) {
        let sum = max(0, input) + max(0, output)
        guard sum > 0 else { return }
        lock.lock()
        if let identifier, let index = events.firstIndex(where: { $0.identifier == identifier }) {
            let changedProject = events[index].project == nil && project != nil
            if changedProject { events[index].project = project }
            let savedEvents = events
            lock.unlock()
            // The transcript importer intentionally re-offers known events so
            // a changed tail can fill any gap. A duplicate that adds no data is
            // not a persistence event: rewriting the complete journal for each
            // one turned an initial history import into sustained 100% CPU.
            if changedProject { persist(events: savedEvents) }
            return
        }
        total += sum
        let stampNeeded = since == nil
        if stampNeeded {
            since = Date()
            sinceVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        }
        let now = Date()
        let event = UsageEvent(identifier: identifier, project: project, date: recordedAt, provider: provider,
                               input: max(0, input), output: max(0, output))
        events.append(event)
        // A seven-day monitor needs one extra day of slack around a calendar
        // boundary. The cap also prevents an unusually chatty session from
        // turning UserDefaults into an unbounded event archive.
        let oldest = now.addingTimeInterval(-8 * 24 * 60 * 60)
        let compacted = events.contains { $0.date < oldest } || events.count > 20_000
        events.removeAll { $0.date < oldest }
        if events.count > 20_000 { events.removeFirst(events.count - 20_000) }
        let (newTotal, stamp, version, savedEvents) = (total, since, sinceVersion, events)
        lock.unlock()

        defaults.set(newTotal, forKey: Key.total)
        if stampNeeded {
            defaults.set(stamp, forKey: Key.since)
            defaults.set(version, forKey: Key.sinceVersion)
        }
        persist(appending: event, snapshot: savedEvents, compacted: compacted)
    }

    var reading: Reading {
        lock.lock(); defer { lock.unlock() }
        return Reading(total: total, since: since, sinceVersion: sinceVersion)
    }

    /// Real local consumption for a provider and period. Five-hour windows are
    /// aligned to local 00:00/05:00/10:00/15:00/20:00 boundaries; the weekly
    /// window follows the user's calendar. These are not vendor quota resets.
    func usage(provider: String, window: LocalWindow, now: Date = Date(), project: String? = nil) -> UsageWindow {
        let calendar = Calendar.autoupdatingCurrent
        let bounds: (Date, Date)
        switch window {
        case .fiveHours:
            let hour = calendar.component(.hour, from: now)
            let startHour = hour - (hour % 5)
            let day = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .hour, value: startHour, to: day) ?? day
            bounds = (start, calendar.date(byAdding: .hour, value: 5, to: start) ?? now)
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                ?? calendar.startOfDay(for: now)
            bounds = (start, calendar.date(byAdding: .day, value: 7, to: start) ?? now)
        }
        lock.lock(); defer { lock.unlock() }
        let source = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = events.filter { event in
            event.provider.lowercased() == source
                && AIActivityProject.matches(eventProject: event.project, displayedProject: project)
                && event.date >= bounds.0 && event.date < bounds.1
        }
        return UsageWindow(input: matching.reduce(0) { $0 + $1.input },
                           output: matching.reduce(0) { $0 + $1.output },
                           startsAt: bounds.0, endsAt: bounds.1)
    }

    func usage(project: String, window: LocalWindow, now: Date = Date()) -> UsageWindow {
        let calendar = Calendar.autoupdatingCurrent
        let start: Date
        let end: Date
        switch window {
        case .fiveHours:
            let day = calendar.startOfDay(for: now)
            start = calendar.date(byAdding: .hour, value: calendar.component(.hour, from: now) / 5 * 5, to: day) ?? day
            end = calendar.date(byAdding: .hour, value: 5, to: start) ?? now
        case .week:
            start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
            end = calendar.date(byAdding: .day, value: 7, to: start) ?? now
        }
        lock.lock(); defer { lock.unlock() }
        let matching = events.filter {
            AIActivityProject.display($0.project) == project && $0.date >= start && $0.date < end
        }
        return .init(input: matching.reduce(0) { $0 + $1.input }, output: matching.reduce(0) { $0 + $1.output }, startsAt: start, endsAt: end)
    }

    func projectActivities() -> [ProjectActivity] {
        lock.lock(); defer { lock.unlock() }
        let grouped = Dictionary(grouping: events) { AIActivityProject.display($0.project) }
        return grouped.map { project, entries in
            let sessions = Set(entries.compactMap { event -> String? in
                guard let id = event.identifier else { return nil }
                let parts = id.split(separator: ":")
                return parts.count >= 3 ? parts.dropFirst().dropLast().joined(separator: ":") : nil
            })
            let context = latestContextByProvider.values
                .filter { AIActivityProject.display($0.project) == project }
                .max { $0.date < $1.date }
            return .init(id: project, project: project,
                         providers: Array(Set(entries.map(\.provider))).sorted(), sessionCount: sessions.count,
                         contextUsed: context?.used, contextWindow: context?.window)
        }.sorted { $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending }
    }

    func recordContext(provider: String, project: String? = nil, used: Int, window: Int?, at date: Date = Date()) {
        guard used > 0 else { return }
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        let key = normalized + "|" + (project ?? "External sessions")
        if let existing = latestContextByProvider[key], existing.date > date {
            lock.unlock()
            return
        }
        latestContextByProvider[key] = .init(date: date, project: project, used: used, window: window)
        let saved = latestContextByProvider
        lock.unlock()
        if let encoded = try? JSONEncoder().encode(saved) {
            defaults.set(encoded, forKey: Key.providerContexts)
        }
    }

    private func persist(appending event: UsageEvent, snapshot: [UsageEvent], compacted: Bool) {
        guard let ledger else {
            persist(events: snapshot)
            return
        }
        if compacted {
            persist(events: snapshot)
            return
        }
        guard let encoded = try? JSONEncoder().encode(event), (try? ledger.append(encoded)) != nil else {
            // A full defaults snapshot is less efficient, but it is safer than
            // accepting a reported token count that disappears on restart.
            persist(events: snapshot)
            return
        }
        defaults.removeObject(forKey: Key.events)
    }

    private func persist(events: [UsageEvent]) {
        guard let ledger else {
            if let encoded = try? JSONEncoder().encode(events) { defaults.set(encoded, forKey: Key.events) }
            return
        }
        guard let records = try? events.map({ try JSONEncoder().encode($0) }),
              (try? ledger.replace(with: records)) != nil else {
            if let encoded = try? JSONEncoder().encode(events) { defaults.set(encoded, forKey: Key.events) }
            return
        }
        defaults.removeObject(forKey: Key.events)
    }
}
