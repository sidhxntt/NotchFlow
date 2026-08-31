import Foundation

/// The complete clean-room catalogue of optional desktop utilities.  A feature
/// definition describes policy only; its service remains responsible for the
/// real availability check and for requesting any system grant in context.
public enum UtilityFeature: String, CaseIterable, Hashable, Sendable {
    case windowSwitcher, dockPreview, dockClick, windowMaximizer, windowLayout, autoQuit
    case scrollInverter, focusFollowsMouse, smoothScroll, mouseNavigation, mouseButtonShortcuts, middleClick, keyboardDebounce, textSnippets, superKey
    case clipboardHistory, clipboardAutoClear, pastePlain, finderCutPaste, finderRename, shelf, urlCleaner, diskImageInstaller
    case appVolumeMixer, audioOutputRouting, soundOutputSwitcher, microphoneTools, musicLaunchBlocker
    case keepAwake, brightness, extraBrightness, bluetoothSleep
    case commandBar, quickToggles, radialMenu, colorPicker, screenOCR, screenshot, screenRecorder, cameraPreview, scratchpad, cleaningMode, killProcess
    case cleaner, managedDownloads, uninstaller, homebrew, appUpdates, mediaTools
    case monitorCPU, monitorGPU, monitorMemory, monitorNetwork, monitorDisk, monitorPower, monitorTemperature, fanControl
}

public enum UtilityPermission: String, Hashable, Sendable {
    case accessibility, screenRecording, microphone, camera, notifications, fullDiskAccess
    case finderAutomation, terminalAutomation, appManagement
}

public enum UtilityFeatureGroup: String, CaseIterable, Sendable {
    case windows, input, clipboard, audio, energy, tools, maintenance, monitor
}

public struct UtilityFeatureDefinition: Equatable, Sendable {
    public let feature: UtilityFeature
    public let group: UtilityFeatureGroup
    public let permissions: Set<UtilityPermission>
    public let requiresConfirmation: Bool

    public init(_ feature: UtilityFeature, group: UtilityFeatureGroup,
                permissions: Set<UtilityPermission> = [], requiresConfirmation: Bool = false) {
        self.feature = feature
        self.group = group
        self.permissions = permissions
        self.requiresConfirmation = requiresConfirmation
    }
}

public enum UtilityFeaturePreset: String, CaseIterable, Sendable {
    case essentials, windows, batteryAndQuiet

    public var features: Set<UtilityFeature> {
        switch self {
        case .essentials: [.clipboardHistory, .pastePlain, .shelf, .keepAwake, .quickToggles, .commandBar]
        case .windows: [.windowSwitcher, .dockPreview, .dockClick, .windowMaximizer, .windowLayout, .autoQuit]
        case .batteryAndQuiet: [.keepAwake, .brightness, .bluetoothSleep, .monitorPower, .monitorTemperature, .fanControl]
        }
    }
}

public enum UtilityFeatureRegistry {
    private static let destructive: Set<UtilityFeature> = [.cleaner, .uninstaller, .diskImageInstaller,
                                                            .homebrew, .appUpdates, .cleaningMode, .killProcess]

    public static func definition(for feature: UtilityFeature) -> UtilityFeatureDefinition {
        UtilityFeatureDefinition(feature, group: group(for: feature),
                                 permissions: permissions(for: feature),
                                 requiresConfirmation: destructive.contains(feature))
    }

    public static func definitions(in group: UtilityFeatureGroup) -> [UtilityFeatureDefinition] {
        UtilityFeature.allCases.filter { self.group(for: $0) == group }.map(definition(for:))
    }

    private static func group(for feature: UtilityFeature) -> UtilityFeatureGroup {
        switch feature {
        case .windowSwitcher, .dockPreview, .dockClick, .windowMaximizer, .windowLayout, .autoQuit: .windows
        case .scrollInverter, .focusFollowsMouse, .smoothScroll, .mouseNavigation, .mouseButtonShortcuts, .middleClick, .keyboardDebounce, .textSnippets, .superKey: .input
        case .clipboardHistory, .clipboardAutoClear, .pastePlain, .finderCutPaste, .finderRename, .shelf, .urlCleaner, .diskImageInstaller: .clipboard
        case .appVolumeMixer, .audioOutputRouting, .soundOutputSwitcher, .microphoneTools, .musicLaunchBlocker: .audio
        case .keepAwake, .brightness, .extraBrightness, .bluetoothSleep: .energy
        case .commandBar, .quickToggles, .radialMenu, .colorPicker, .screenOCR, .screenshot, .screenRecorder, .cameraPreview, .scratchpad, .cleaningMode, .killProcess: .tools
        case .cleaner, .managedDownloads, .uninstaller, .homebrew, .appUpdates, .mediaTools: .maintenance
        case .monitorCPU, .monitorGPU, .monitorMemory, .monitorNetwork, .monitorDisk, .monitorPower, .monitorTemperature, .fanControl: .monitor
        }
    }

    private static func permissions(for feature: UtilityFeature) -> Set<UtilityPermission> {
        switch feature {
        case .windowSwitcher, .dockPreview: [.accessibility, .screenRecording]
        case .dockClick, .windowMaximizer, .windowLayout, .autoQuit, .scrollInverter, .focusFollowsMouse, .smoothScroll, .mouseNavigation, .mouseButtonShortcuts, .middleClick, .keyboardDebounce, .textSnippets, .superKey, .pastePlain, .finderRename, .radialMenu, .commandBar, .cleaningMode: [.accessibility]
        case .finderCutPaste: [.accessibility, .finderAutomation]
        case .quickToggles: [.finderAutomation]
        case .screenOCR, .screenshot: [.screenRecording]
        case .screenRecorder: [.screenRecording, .microphone]
        case .cameraPreview: [.camera]
        case .cleaner: [.fullDiskAccess, .notifications]
        case .uninstaller: [.fullDiskAccess, .finderAutomation]
        case .homebrew: [.terminalAutomation, .appManagement]
        case .appUpdates: [.notifications, .appManagement]
        case .diskImageInstaller: [.appManagement]
        case .appVolumeMixer: [.accessibility, .microphone]
        case .monitorCPU, .monitorMemory, .monitorDisk, .monitorPower: [.notifications]
        default: []
        }
    }
}
