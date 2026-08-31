import AppKit
import CoreAudio
import CoreGraphics
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// One battery reading, whether it belongs to the Mac or to something paired
/// with it.
public struct BatteryReading: Equatable, Identifiable, Sendable {
    public let name: String
    /// 0...100. Nil where a device reports being connected but not its level,
    /// which several Bluetooth accessories do.
    public let percent: Int?
    public let isCharging: Bool
    public let symbolName: String

    public var id: String { name }

    /// Low enough to be worth noticing, and not charging. Drives the one bit of
    /// colour in the row — everything else stays quiet.
    public var isLow: Bool {
        guard let percent, !isCharging else { return false }
        return percent <= 20
    }
}

/// A display the user can identify from the Device card. This is descriptive
/// only; changing brightness or display power deliberately remains outside this
/// permission-free utility.
public struct ConnectedDisplay: Equatable, Identifiable, Sendable {
    public let name: String
    public let resolution: String
    public var id: String { "\(name)-\(resolution)" }
}

/// The small local hardware summary shown in Devices. Keeping the labels here
/// lets the view stay a renderer rather than becoming a collection of system
/// probes.
public struct DeviceOverview: Equatable, Sendable {
    public let modelName: String
    public let macOSVersion: String
    public let uptime: TimeInterval
    public let displays: [ConnectedDisplay]

    public init(modelName: String, macOSVersion: String, uptime: TimeInterval, displays: [ConnectedDisplay]) {
        self.modelName = modelName
        self.macOSVersion = macOSVersion
        self.uptime = uptime
        self.displays = displays
    }

    public var uptimeLabel: String {
        let wholeMinutes = max(0, Int(uptime) / 60)
        let days = wholeMinutes / 1_440
        let hours = wholeMinutes % 1_440 / 60
        let minutes = wholeMinutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    public var displaySummary: String {
        "\(displays.count) display\(displays.count == 1 ? "" : "s")"
    }
}

/// A locally mounted, user-ejectable volume. The path is retained so its row
/// can open the volume in Finder or safely ask macOS to eject that exact disk.
public struct DeviceVolume: Equatable, Identifiable, Sendable {
    public let name: String
    public let url: URL
    public let availableBytes: Int64
    public let totalBytes: Int64
    public let isEjectable: Bool
    public var id: URL { url }

    public var capacityLabel: String {
        guard totalBytes > 0 else { return "—" }
        return "\(Int((Double(totalBytes - availableBytes) / Double(totalBytes) * 100).rounded()))% used"
    }
}

/// Battery details that macOS supplies without polling sensor hardware. Fields
/// are optional because desktop Macs and some third-party batteries do not
/// expose every value.
public struct BatteryDetails: Equatable, Sendable {
    public let health: String?
    public let cycleCount: Int?
    public let maximumCapacityPercent: Int?
    public let estimatedMinutes: Int?

    public init(health: String?, cycleCount: Int?, maximumCapacityPercent: Int?, estimatedMinutes: Int?) {
        self.health = health
        self.cycleCount = cycleCount
        self.maximumCapacityPercent = maximumCapacityPercent
        self.estimatedMinutes = estimatedMinutes
    }

    public var estimatedTimeLabel: String? {
        guard let estimatedMinutes, estimatedMinutes >= 0 else { return nil }
        return "\(estimatedMinutes / 60)h \(estimatedMinutes % 60)m remaining"
    }
}

/// The user-visible lifetime of a keep-awake assertion. It is deliberately
/// independent of IOKit, which makes expiry and presentation deterministic.
public struct KeepAwakePlan: Equatable, Sendable {
    public let until: Date?

    public init(until: Date?) { self.until = until }

    public func isActive(at date: Date) -> Bool {
        until.map { $0 > date } ?? true
    }

    public func remainingLabel(at date: Date) -> String? {
        guard let until else { return nil }
        let seconds = max(0, Int(until.timeIntervalSince(date).rounded(.down)))
        let hours = seconds / 3600
        let minutes = (seconds % 3600 + 59) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

/// The small system affordances the Utilities tab offers: staying awake,
/// switching where sound goes, and what is running low.
///
/// All three are deliberately permission-free. Keep-awake is an IOKit assertion,
/// output switching is CoreAudio, and battery levels come from IOKit's power
/// sources — none of them touch TCC, which is the whole reason they belong in a
/// tab you are meant to open casually.
@MainActor
public final class SystemUtilityService: ObservableObject {
    public static let shared = SystemUtilityService()

    // MARK: - Keep awake

    /// Whether the Mac is being held awake BY US. Deliberately not "is the Mac
    /// awake" — this reflects our own assertion, so the chip can never claim
    /// credit for someone else's (a running build, a video call).
    @Published public private(set) var isKeepingAwake = false
    @Published public private(set) var keepAwakePlan = KeepAwakePlan(until: nil)
    @Published public private(set) var allowsDisplaySleep = false

    private var assertionID: IOPMAssertionID = 0
    private var keepAwakeTimer: Timer?

    /// Take or drop a power assertion. `PreventUserIdleDisplaySleep` rather than
    /// system sleep: the point is that the screen stays readable, and preventing
    /// system sleep while letting the display nap is the useless half of the
    /// pair.
    ///
    /// The assertion dies with the process, so a crash cannot leave a Mac that
    /// refuses to sleep — the failure mode that makes this feature scary
    /// elsewhere.
    public func setKeepAwake(_ enabled: Bool, allowsDisplaySleep: Bool? = nil) {
        let nextAllowsDisplaySleep = allowsDisplaySleep ?? self.allowsDisplaySleep
        guard enabled != isKeepingAwake || nextAllowsDisplaySleep != self.allowsDisplaySleep else { return }
        if isKeepingAwake {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isKeepingAwake = false
        }
        self.allowsDisplaySleep = nextAllowsDisplaySleep
        if enabled {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                (nextAllowsDisplaySleep ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep) as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "NotchFlow keep awake" as CFString,
                &id)
            guard result == kIOReturnSuccess else { return }
            assertionID = id
            isKeepingAwake = true
        } else {
            keepAwakeTimer?.invalidate()
            keepAwakeTimer = nil
            keepAwakePlan = KeepAwakePlan(until: nil)
        }
    }

    public func toggleKeepAwake() { setKeepAwake(!isKeepingAwake) }

    public func keepAwake(for minutes: Int) {
        let duration = max(1, minutes)
        let deadline = Date().addingTimeInterval(TimeInterval(duration * 60))
        keepAwakePlan = KeepAwakePlan(until: deadline)
        setKeepAwake(true)
        keepAwakeTimer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.keepAwakePlan.isActive(at: Date()) { self.setKeepAwake(false) }
                else { self.objectWillChange.send() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAwakeTimer = timer
    }

    public var keepAwakeStatus: String {
        guard isKeepingAwake else { return "Off" }
        if let remaining = keepAwakePlan.remainingLabel(at: Date()) { return "\(remaining) left" }
        return allowsDisplaySleep ? "Display may sleep" : "On"
    }

    // MARK: - Sleep and screensaver

    /// Put the display to sleep right now, the rest of the machine untouched.
    ///
    /// `pmset displaysleepnow` rather than any IOKit call: it is the one route
    /// that puts the DISPLAY to sleep without also risking system sleep, needs
    /// no elevated privilege for the logged-in user, and is a stable public CLI
    /// rather than a private framework symbol that could vanish between
    /// releases.
    public func sleepDisplayNow() {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["displaysleepnow"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
        }
    }

    /// Start the screen saver right now, as if the idle timer had fired.
    ///
    /// Routed through AppleScript's "start current screen saver" — the same
    /// mechanism System Events itself exposes for this, and the one the
    /// hardened-runtime `com.apple.security.automation.apple-events`
    /// entitlement already covers (see `NotesService`, which drives Notes the
    /// same way). No new permission, no private symbol.
    public func startScreenSaverNow() {
        Task.detached(priority: .userInitiated) {
            let script = NSAppleScript(source:
                "tell application \"System Events\" to start current screen saver")
            var error: NSDictionary?
            script?.executeAndReturnError(&error)
        }
    }

    // MARK: - Audio output

    @Published public private(set) var outputDevices: [AudioOutputDevice] = []
    @Published public private(set) var currentOutputDeviceID: AudioDeviceID?

    public struct AudioOutputDevice: Equatable, Identifiable, Sendable {
        public let id: AudioDeviceID
        public let name: String
    }

    /// Every device that can actually play sound. Inputs are filtered out by
    /// asking for output stream configuration — a microphone is an audio device
    /// too, and listing it here would offer to send music to it.
    public func refreshOutputDevices() {
        outputDevices = Self.allOutputDevices()
        currentOutputDeviceID = Self.defaultOutputDeviceID()
    }

    public func selectOutputDevice(_ id: AudioDeviceID) {
        var deviceID = id
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &deviceID)
        guard status == noErr else { return }
        currentOutputDeviceID = id
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    private static func allOutputDevices() -> [AudioOutputDevice] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id), let name = name(of: id) else { return nil }
            return AudioOutputDevice(id: id, name: name)
        }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func name(of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return nil }
        return value as String
    }

    // MARK: - Batteries

    @Published public private(set) var batteries: [BatteryReading] = []
    @Published public private(set) var overview = DeviceOverview(modelName: "Mac", macOSVersion: "macOS", uptime: 0, displays: [])
    @Published public private(set) var removableVolumes: [DeviceVolume] = []
    /// A failed eject must be visible; otherwise the row simply reappears and
    /// gives no indication whether macOS rejected the operation or it is busy.
    @Published public private(set) var deviceActionError: String?
    @Published public private(set) var batteryDetails = BatteryDetails(health: nil, cycleCount: nil, maximumCapacityPercent: nil, estimatedMinutes: nil)

    /// Refreshes the concise, local hardware information used by Devices.
    /// No background monitor is left running: these values are sampled when the
    /// card opens or the user presses its refresh control.
    public func refreshDeviceDetails() {
        overview = Self.readOverview()
        removableVolumes = Self.ejectableVolumes(from: Self.readMountedVolumes())
        batteryDetails = Self.readBatteryDetails()
    }

    public func revealVolume(_ volume: DeviceVolume) {
        NSWorkspace.shared.activateFileViewerSelecting([volume.url])
    }

    public func ejectVolume(_ volume: DeviceVolume) {
        // AppKit exposes this operation synchronously in the macOS SDK this app
        // targets. It returns after Finder has handed the unmount request to the
        // system, so immediately refresh the small mounted-volume snapshot.
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            deviceActionError = nil
        } catch {
            deviceActionError = "Couldn't eject \(volume.name): \(error.localizedDescription)"
        }
        refreshDeviceDetails()
    }

    public func refreshBatteries() async {
        let local = Self.readBatteries()
        // Off the main thread: this spawns `system_profiler`, which takes about a
        // second — a visible stall if it ran where the UI does.
        let bluetooth = await Task.detached(priority: .utility) { Self.bluetoothBatteries() }.value
        batteries = local + bluetooth
    }

    /// The Mac's own battery, plus HID accessories macOS reports as power
    /// sources (Magic Mouse, Magic Keyboard, Magic Trackpad).
    ///
    /// AirPods are NOT here, despite being paired and playing audio — verified on
    /// a machine with them connected, where this returns exactly one source. They
    /// live in `SPBluetoothDataType` instead; `bluetoothBatteries` fetches those
    /// separately because doing so costs a subprocess.
    static func readBatteries() -> [BatteryReading] {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }

        return sources.compactMap { source in
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any] else { return nil }

            let name = (info[kIOPSNameKey] as? String) ?? "Battery"
            let current = info[kIOPSCurrentCapacityKey] as? Int
            let max = info[kIOPSMaxCapacityKey] as? Int
            let charging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            let type = (info[kIOPSTypeKey] as? String) ?? ""

            // Percentages are reported against each source's own maximum, which
            // is not always 100 — scaling is not optional.
            let percent: Int? = {
                guard let current, let max, max > 0 else { return nil }
                return Int((Double(current) / Double(max) * 100).rounded())
            }()

            return BatteryReading(name: Self.friendlyName(name, type: type),
                                  percent: percent,
                                  isCharging: charging,
                                  symbolName: Self.symbol(for: name, type: type))
        }
    }

    nonisolated static func ejectableVolumes(from volumes: [DeviceVolume]) -> [DeviceVolume] {
        volumes.filter(\.isEjectable).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    nonisolated private static func readMountedVolumes() -> [DeviceVolume] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeIsEjectableKey, .volumeAvailableCapacityKey, .volumeTotalCapacityKey
        ]
        return FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes])?
            .compactMap { url in
                guard let values = try? url.resourceValues(forKeys: keys),
                      let name = values.volumeName,
                      let isEjectable = values.volumeIsEjectable else { return nil }
                return DeviceVolume(name: name,
                                    url: url,
                                    availableBytes: values.volumeAvailableCapacity.map(Int64.init) ?? 0,
                                    totalBytes: values.volumeTotalCapacity.map(Int64.init) ?? 0,
                                    isEjectable: isEjectable)
            } ?? []
    }

    nonisolated private static func readOverview() -> DeviceOverview {
        let modelName = hardwareModelName()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let macOSVersion = "macOS \(version.majorVersion).\(version.minorVersion)"
        let displays = NSScreen.screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let mode = displayID.flatMap(CGDisplayCopyDisplayMode)
            let width = mode.map { Int($0.pixelWidth) } ?? Int(screen.frame.width.rounded())
            let height = mode.map { Int($0.pixelHeight) } ?? Int(screen.frame.height.rounded())
            return ConnectedDisplay(name: screen.localizedName, resolution: "\(width) × \(height)")
        }
        return DeviceOverview(modelName: modelName,
                              macOSVersion: macOSVersion,
                              uptime: ProcessInfo.processInfo.systemUptime,
                              displays: displays)
    }

    nonisolated private static func readBatteryDetails() -> BatteryDetails {
        var health: String?
        var estimatedMinutes: Int?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      (info[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                health = normalizedBatteryHealth(info[kIOPSBatteryHealthKey] as? String)
                let timeKey = ((info[kIOPSIsChargingKey] as? Bool) ?? false) ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey
                estimatedMinutes = info[timeKey] as? Int
                break
            }
        }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else {
            return BatteryDetails(health: health, cycleCount: nil, maximumCapacityPercent: nil, estimatedMinutes: estimatedMinutes)
        }
        defer { IOObjectRelease(service) }

        func number(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        // On current Apple Silicon notebooks `MaxCapacity` is already the
        // percentage System Information shows. Older hardware can expose a raw
        // capacity instead, where dividing by DesignCapacity is appropriate.
        let maximumCapacityPercent: Int? = {
            guard let maximum = number("MaxCapacity") else { return nil }
            if (0...100).contains(maximum) { return maximum }
            guard let design = number("DesignCapacity"), design > 0 else { return nil }
            return Int((Double(maximum) / Double(design) * 100).rounded())
        }()
        let registryHealth = batteryHealthLabel(permanentFailureStatus: number("PermanentFailureStatus"))
        return BatteryDetails(health: registryHealth ?? health,
                              cycleCount: number("CycleCount"),
                              maximumCapacityPercent: maximumCapacityPercent,
                              estimatedMinutes: estimatedMinutes)
    }

    /// `PermanentFailureStatus` is the battery controller's health verdict.
    /// It is the reliable public registry value available on modern Apple
    /// notebooks, unlike the optional IOPS health-description string.
    nonisolated static func batteryHealthLabel(permanentFailureStatus: Int?) -> String? {
        guard let permanentFailureStatus else { return nil }
        return permanentFailureStatus == 0 ? "Normal" : "Service Recommended"
    }

    nonisolated static func normalizedBatteryHealth(_ health: String?) -> String? {
        guard let health else { return nil }
        let value = health.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated private static func hardwareModelName() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPHardwareDataType", "-json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0, let name = hardwareModelName(from: data) {
                return name
            }
        }
        var size: size_t = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "Mac" }
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    nonisolated static func hardwareModelName(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overview = (root["SPHardwareDataType"] as? [[String: Any]])?.first,
              let name = normalizedBatteryHealth(overview["machine_name"] as? String)
        else { return nil }
        return name
    }

    /// Bluetooth accessory levels, which macOS keeps out of the power-source
    /// list. `system_profiler` is the only route that does not reach into
    /// IOBluetooth's private surface, and it costs a subprocess and roughly a
    /// second — so this is deliberately NOT on the one-second tick. It runs when
    /// the Utilities pane appears, off the main thread, and the result is cached.
    ///
    /// AirPods report three levels (case, left, right). The row shows the lowest
    /// of the two buds: that is the one about to run out, and three numbers do
    /// not fit a notch.
    nonisolated static func bluetoothBatteries() -> [BatteryReading] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseBluetoothBatteries(data)
    }

    /// Split out from the subprocess so the shape of the parse is testable
    /// against a captured payload rather than whatever is paired today.
    nonisolated static func parseBluetoothBatteries(_ data: Data) -> [BatteryReading] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        // Rank, not just value: the same device turns up in several sections
        // with different detail. AirPods list a case level everywhere and bud
        // levels only where the buds are actually reporting — and the buds are
        // the number that matters, since they are what dies mid-call. Taking the
        // lowest number across sections would show the case (79%) while the buds
        // sat at 90%, which understates what you can actually use.
        var best: [String: (reading: BatteryReading, rank: Int)] = [:]
        for section in sections {
            guard let connected = section["device_connected"] as? [[String: Any]] else { continue }
            for entry in connected {
                for (name, value) in entry {
                    guard let fields = value as? [String: Any] else { continue }

                    let buds = [fields["device_batteryLevelLeft"], fields["device_batteryLevelRight"]]
                        .compactMap { percentValue($0) }
                    let candidate: (level: Int, rank: Int)? = {
                        if let lowestBud = buds.min() { return (lowestBud, 2) }
                        if let main = percentValue(fields["device_batteryLevelMain"]) { return (main, 1) }
                        if let caseLevel = percentValue(fields["device_batteryLevelCase"]) { return (caseLevel, 0) }
                        return nil
                    }()
                    guard let candidate else { continue }
                    if let existing = best[name], existing.rank >= candidate.rank { continue }

                    best[name] = (BatteryReading(name: name,
                                                 percent: candidate.level,
                                                 isCharging: false,
                                                 symbolName: symbol(for: name, type: "")),
                                  candidate.rank)
                }
            }
        }
        return best.values.map(\.reading).sorted { $0.name < $1.name }
    }

    /// "79%" as macOS writes it.
    nonisolated static func percentValue(_ raw: Any?) -> Int? {
        guard let text = raw as? String else { return nil }
        return Int(text.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces))
    }

    /// "InternalBattery-0" is the Mac's own, and nobody calls it that.
    nonisolated static func friendlyName(_ raw: String, type: String) -> String {
        raw.hasPrefix("InternalBattery") ? "Mac" : raw
    }

    nonisolated static func symbol(for name: String, type: String) -> String {
        let lowered = name.lowercased()
        if lowered.contains("airpod") { return "airpodspro" }
        if lowered.contains("mouse") { return "magicmouse.fill" }
        if lowered.contains("keyboard") { return "keyboard.fill" }
        if lowered.contains("trackpad") { return "rectangle.and.hand.point.up.left.fill" }
        if lowered.contains("ipad") || lowered.contains("iphone") { return "iphone" }
        return "battery.100"
    }
}
