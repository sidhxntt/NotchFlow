import CoreAudio
import Foundation

/// The active audio output is the useful, privacy-preserving signal for an
/// AirPods connection: when macOS routes sound to AirPods, they are ready for
/// use without needing Bluetooth scans or additional permissions.
public struct ConnectedAudioDevice: Equatable, Sendable {
    public let name: String

    public init(name: String) {
        self.name = name
    }

    public static func isAirPodsName(_ name: String) -> Bool {
        name.localizedCaseInsensitiveContains("AirPods")
    }
}

public enum AccessoryConnectionEvent: Equatable, Sendable {
    case connected(ConnectedAudioDevice)
    case disconnected(ConnectedAudioDevice)

    public static func transition(
        from previous: ConnectedAudioDevice?,
        to current: ConnectedAudioDevice?
    ) -> AccessoryConnectionEvent? {
        guard previous != current else { return nil }
        if let current { return .connected(current) }
        if let previous { return .disconnected(previous) }
        return nil
    }

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// Decides when a change in the default output device is real.
///
/// Taking AirPods out does not hand the output over cleanly. Measured on Tahoe,
/// one removal reported:
///
///     17:35:22.434  MacBook Pro Speakers
///     17:35:22.838  Siddhant's AirPods Pro     ← flap back
///     17:35:23.244  MacBook Pro Speakers
///
/// Three transitions inside 810ms, against a once-a-second poll. Reading each
/// sample as truth meant a removal could announce "disconnected", then overwrite
/// itself with "connected" when the poll caught the flap, and land on whichever
/// of the two the 3-second window happened to end on — so removals showed the
/// wrong badge, or none.
///
/// Connections do not flap (the same log shows one clean transition), so they are
/// still trusted immediately. Only a device VANISHING has to hold still.
public struct AccessoryConnectionSettler: Sendable {
    /// Consecutive polls with no device before a removal is believed. Two, at the
    /// refresh loop's one-second cadence, outlasts the flap above.
    public static let samplesToConfirmRemoval = 2

    private var settled: ConnectedAudioDevice?
    private var vanishedSamples = 0

    public init(settled: ConnectedAudioDevice? = nil) {
        self.settled = settled
    }

    public var device: ConnectedAudioDevice? { settled }

    public mutating func observe(_ device: ConnectedAudioDevice?) -> AccessoryConnectionEvent? {
        guard device != settled else {
            vanishedSamples = 0
            return nil
        }
        if device != nil {
            vanishedSamples = 0
            let previous = settled
            settled = device
            return AccessoryConnectionEvent.transition(from: previous, to: device)
        }
        vanishedSamples += 1
        guard vanishedSamples >= Self.samplesToConfirmRemoval else { return nil }
        vanishedSamples = 0
        let previous = settled
        settled = nil
        return AccessoryConnectionEvent.transition(from: previous, to: nil)
    }
}

public final class AudioDeviceCapabilityService {
    public init() {}

    public func connectedAirPods() -> ConnectedAudioDevice? {
        var outputDevice = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var defaultOutputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            0,
            nil,
            &size,
            &outputDevice) == noErr else {
            return nil
        }

        var deviceName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(outputDevice, &nameAddress, 0, nil, &size, &deviceName) == noErr else {
            return nil
        }

        guard let deviceName else { return nil }
        let name = deviceName.takeUnretainedValue() as String
        return ConnectedAudioDevice.isAirPodsName(name) ? ConnectedAudioDevice(name: name) : nil
    }
}
