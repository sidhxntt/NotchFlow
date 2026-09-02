import Foundation

/// The pressure rungs for the selected-text Force Click gesture.
///
/// Contact-frame pressure varies between trackpads, so every rung combines an
/// absolute floor with the increase above the first-click baseline. The floors
/// are deliberately far enough apart that Light, Medium, and Firm require
/// recognizably different presses on the same trackpad.
public enum ForceClickPressurePolicy {
    public enum Level: String, CaseIterable, Sendable {
        case off
        case light
        case medium
        case firm
    }

    public static func progress(for level: Level, pressure: Float, baseline: Float) -> Double {
        guard level != .off else { return 0 }
        let threshold = threshold(for: level)
        let absolute = Double(pressure / threshold.minimumPressure)
        let proportional = baseline > 0
            ? Double(pressure / (baseline * threshold.ratio))
            : 0
        let risen = Double((pressure - baseline) / threshold.minimumRise)
        return max(0, min(1, min(absolute, min(proportional, risen))))
    }

    private static func threshold(for level: Level) -> (
        ratio: Float, minimumRise: Float, minimumPressure: Float
    ) {
        switch level {
        case .off:
            return (1, 1, 1)
        case .light:
            return (1.45, 45, 180)
        case .medium:
            return (2.15, 125, 300)
        case .firm:
            return (2.90, 220, 420)
        }
    }
}
