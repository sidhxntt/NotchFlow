import AVFoundation
import Combine
import CoreLocation
import EventKit
import Foundation

@MainActor
final class UtilityCapabilityService: ObservableObject {
    static let shared = UtilityCapabilityService()
    @Published private(set) var calendarPermission: CapabilityPermission = .unknown
    @Published private(set) var webcamPermission: CapabilityPermission = .unknown
    @Published private(set) var upcomingEvents: [EKEvent] = []
    @Published private(set) var webcamSession: AVCaptureSession?

    /// The current conditions shown under the clock. Nil until the first fetch
    /// lands (or forever, if Location was never granted) — the header simply
    /// omits the line, rather than showing a placeholder that never fills in.
    @Published private(set) var weather: WeatherSnapshot?

    private let eventStore = EKEventStore()

    /// Last reading, so the line is populated the instant the panel opens instead
    /// of after a network round-trip. Weather an hour old is not shown.
    private static let weatherCacheKey = "notchflow.weather.snapshot.v1"
    private var weatherFetchInFlight = false
    private var authorizationWatch: AnyCancellable?

    init() {
        // The Location prompt is answered asynchronously, and by then the pane's
        // `.task` has long since finished. Without this the weather would only
        // appear the NEXT time you opened Utilities, which reads as the grant not
        // having worked.
        authorizationWatch = WeatherLocationProvider.shared.$authorization
            .removeDuplicates()
            .sink { [weak self] status in
                guard status == .authorized || status == .authorizedAlways else { return }
                Task { @MainActor in await self?.refreshWeather() }
            }
    }

    func refreshCalendar() async {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess, .writeOnly:
            calendarPermission = .authorized
            let start = Date()
            let end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
            upcomingEvents = eventStore.events(matching: eventStore.predicateForEvents(withStart: start, end: end, calendars: nil))
                .sorted { $0.startDate < $1.startDate }
        case .notDetermined:
            let granted = (try? await eventStore.requestFullAccessToEvents()) ?? false
            calendarPermission = granted ? .authorized : .denied
            if granted { await refreshCalendar() }
        case .denied, .restricted: calendarPermission = .denied
        @unknown default: calendarPermission = .unavailable
        }
    }

    /// Refresh the conditions if what we have is stale. Called when the
    /// utilities pane appears — not on a timer, because weather nobody is looking
    /// at is a network request nobody asked for.
    func refreshWeather(now: Date = Date()) async {
        if weather == nil { weather = Self.cachedWeather() }
        if let weather, weather.isFresh(at: now, lifetime: 15 * 60) { return }
        guard !weatherFetchInFlight else { return }
        weatherFetchInFlight = true
        defer { weatherFetchInFlight = false }

        // Ask in context, on the pane that actually shows the weather, rather
        // than at launch or buried in Settings. macOS only ever shows this dialog
        // once per app, so there is nothing to spam: after the first answer the
        // provider reports the recorded status and this is a no-op.
        let provider = WeatherLocationProvider.shared
        if provider.authorization == .notDetermined {
            provider.requestAuthorization()
            return  // The prompt is answered asynchronously; the next refresh picks it up.
        }
        guard let coordinate = await provider.currentCoordinate() else { return }
        guard let fetched = await WeatherService.fetch(latitude: coordinate.latitude,
                                                       longitude: coordinate.longitude,
                                                       now: now) else { return }
        weather = fetched
        cache(fetched)
    }

    private static func cachedWeather() -> WeatherSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: weatherCacheKey),
              let snapshot = try? JSONDecoder().decode(WeatherSnapshot.self, from: data),
              snapshot.isFresh(at: Date()) else { return nil }
        return snapshot
    }

    private func cache(_ snapshot: WeatherSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.weatherCacheKey)
    }

    /// The meeting worth offering a Join button for: the next event that has a
    /// video link and starts within the window (or started moments ago).
    ///
    /// Computed rather than stored so it cannot go stale — the pane re-reads it
    /// every minute along with the clock, and a meeting that has drifted out of
    /// the window simply stops being returned.
    func imminentMeeting(now: Date = Date()) -> (event: EKEvent, link: MeetingLink)? {
        for event in upcomingEvents {
            guard let start = event.startDate else { continue }
            guard MeetingWindow.isImminent(start: start, now: now) else { continue }
            guard let link = MeetingLink.detect(url: event.url?.absoluteString,
                                                location: event.location,
                                                notes: event.notes) else { continue }
            return (event, link)
        }
        return nil
    }

    func startWebcam() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        guard granted else { webcamPermission = .denied; return }
        webcamPermission = .authorized
        guard let device = AVCaptureDevice.default(for: .video) else { webcamPermission = .unavailable; return }
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { webcamPermission = .unavailable; return }
        session.addInput(input)
        session.startRunning()
        webcamSession = session
    }

    func stopWebcam() { webcamSession?.stopRunning(); webcamSession = nil }
}
