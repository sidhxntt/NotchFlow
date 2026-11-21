import AppKit
import ApplicationServices
import CoreLocation
import Carbon.HIToolbox
import Carbon.OpenScripting
import EventKit
import SwiftUI
import UserNotifications

/// A native `NSSlider` quantized to a fixed ladder of tick positions — the
/// "multi-segment" control behind the hover-sensitivity row (3 ticks) and the
/// agent card's thinking-strength dial (N ticks). Ticks sit below the track;
/// dragging snaps to the nearest one, so `value` only ever lands on an integer
/// position in `0…ticks-1`.
struct NativeDetentSlider: NSViewRepresentable {
    @Binding var value: Double
    /// Number of detents on the ladder (tick marks + the positions they mark).
    /// Two ticks are the minimum the system allows; 3 = the old
    /// `NativeThreeStepSlider` exactly.
    let ticks: Int
    /// Normalized x-position of each tick's center inside the slider, 0…1
    /// (nil while the NSView isn't laid out yet). Labels align to these instead
    /// of a naive equal-width split, because the AppKit track is inset from the
    /// view's edges by half a thumb on each side. Defaults to nil for sliders
    /// that draw no label row.
    @Binding var tickCenters: [CGFloat]?

    init(value: Binding<Double>, ticks: Int, tickCenters: Binding<[CGFloat]?> = .constant(nil)) {
        _value = value
        self.ticks = ticks
        _tickCenters = tickCenters
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value, tickCenters: $tickCenters)
    }

    func makeNSView(context: Context) -> SliderView {
        let slider = SliderView(value: value,
                                minValue: 0,
                                maxValue: Double(ticks - 1),
                                target: context.coordinator,
                                action: #selector(Coordinator.valueChanged(_:)))
        slider.onTickGeometryChange = { [weak coordinator = context.coordinator] centers in
            coordinator?.publish(tickCenters: centers)
        }
        slider.sliderType = .linear
        slider.numberOfTickMarks = ticks
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = true
        slider.altIncrementValue = 1
        slider.isContinuous = true
        slider.controlSize = .small
        slider.trackFillColor = NSColor.white.withAlphaComponent(0.55)
        return slider
    }

    func updateNSView(_ slider: SliderView, context: Context) {
        context.coordinator.value = $value
        context.coordinator.tickCenters = $tickCenters
        // The ladder itself has to be re-applied, not just the value: SwiftUI
        // REUSES this NSSlider when `ticks` changes, and `makeNSView` only ever
        // ran once. A slider left holding the old count is not cosmetic — it
        // CRASHED the app: `rectOfTickMark(at:)` below raises an NSException for
        // an index past `numberOfTickMarks`, and an ObjC exception out of a
        // SwiftUI update is a hard termination, not a caught error. The way in
        // was arming a model whose rung count is higher than the armed one's
        // (pi's models offer five rungs; plenty of others offer two or three),
        // with the effort bar already on screen.
        if slider.numberOfTickMarks != ticks {
            slider.numberOfTickMarks = ticks
            slider.maxValue = Double(ticks - 1)
        }
        // Re-clamp on tick-count changes (e.g. the agent card's rungs can
        // shrink when the armed model changes) so the thumb can't sit past the
        // last detent it's now allowed to hit.
        let max = Double(ticks - 1)
        if value > max { value = max }
        if slider.doubleValue != value {
            slider.doubleValue = value
        }
        slider.reportTickGeometry()
    }

    /// Reports its own tick geometry from `layout()`. Reading it during
    /// `updateNSView` alone is too early — SwiftUI runs that before AppKit has
    /// sized the view, so `bounds.width` is still 0 and nothing ever measures
    /// again; that left the label row permanently empty.
    final class SliderView: NSSlider {
        var onTickGeometryChange: (([CGFloat]) -> Void)?

        override func layout() {
            super.layout()
            reportTickGeometry()
        }

        /// Normalized center of each tick mark, 0…1. Two detents are AppKit's
        /// minimum, so anything less has no geometry to read — asking anyway
        /// raises the same `rectOfTickMark(at:)` exception as an out-of-range
        /// index.
        func reportTickGeometry() {
            let width = bounds.width
            guard width > 0, numberOfTickMarks >= 2 else { return }
            let centers = (0..<numberOfTickMarks).map { index -> CGFloat in
                (rectOfTickMark(at: index).midX / width).clamped(to: 0...1)
            }
            onTickGeometryChange?(centers)
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        var tickCenters: Binding<[CGFloat]?>

        init(value: Binding<Double>, tickCenters: Binding<[CGFloat]?>) {
            self.value = value
            self.tickCenters = tickCenters
        }

        @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue
        }

        /// Hops to the next runloop pass: the measurement can land inside a
        /// SwiftUI update (or inside AppKit's layout), and writing state there
        /// is what SwiftUI warns about.
        func publish(tickCenters centers: [CGFloat]) {
            guard tickCenters.wrappedValue != centers else { return }
            DispatchQueue.main.async { [self] in
                guard tickCenters.wrappedValue != centers else { return }
                tickCenters.wrappedValue = centers
            }
        }
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
