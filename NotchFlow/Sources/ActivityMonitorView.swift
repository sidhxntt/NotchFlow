import SwiftUI

/// Replacement for the File tray / Calendar pair, swapped in by the toggle
/// circle that floats in the gutter between them.
///
/// Two cards, not one, and on the same `EqualHeightUtilitiesLayout` the pair it
/// replaces uses — so the columns line up, the gutter falls in the same place,
/// and the toggle circle sitting in that gutter doesn't move when you switch.
///
/// The split is Activity Monitor's own: its window has exactly two footers
/// worth reading at a glance, CPU on one tab and Memory on the other, and this
/// puts them side by side. Each card is that footer boiled down to what stays
/// legible at ~250pt — a small area chart of the last forty samples, then the
/// three or four numbers underneath it that the chart is a picture of.
///
/// Kept as quiet as the rest of the tab: small type, `Tokens.text1/2/3` for
/// hierarchy, and colour only where it carries meaning. Two places qualify: the
/// red/blue System-vs-User coding, which is the whole visual signature of
/// Activity Monitor's CPU footer and is what makes the stacked chart readable
/// at all, and the orange a memory reading takes on when it runs out of room —
/// the same restraint `BatteryReading.isLow` uses for its own tint.
///
/// Not shown, deliberately: a thread count. Activity Monitor prints one next to
/// its process count, but counting threads system-wide needs `task_for_pid` on
/// every process and therefore root. There is no honest way to show that number
/// from an unprivileged app, so the row simply isn't here.
struct ActivityMonitorView: View {
    @ObservedObject var monitor: SystemMonitorService

    /// Above this, a reading gets the one bit of alarm colour this card allows.
    private static let criticalThreshold: Double = 90

    /// Activity Monitor's own two-tone CPU coding, pulled a little brighter and
    /// a little less saturated so it survives the dark glass this sits on.
    private static let systemInk = Color(red: 0.98, green: 0.40, blue: 0.38)
    private static let userInk = Color(red: 0.36, green: 0.66, blue: 1.00)
    /// The pressure graph's green, matching the colour Activity Monitor uses
    /// while a machine is comfortable.
    private static let pressureInk = Color(red: 0.33, green: 0.82, blue: 0.47)

    /// Big enough to show a shape, small enough that four rows of numbers still
    /// fit under it without the card outgrowing the panel.
    private static let graphHeight: CGFloat = 34

    var body: some View {
        EqualHeightUtilitiesLayout(spacing: 10) {
            cpuCard
                .frame(maxWidth: .infinity, alignment: .topLeading)
            memoryCard
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        // Only while this card is on screen: sampling Mach host stats twice a
        // second for a panel nobody is looking at would be pure waste. The
        // service's own start/stop guards make this safe to call from every
        // appear without stacking timers. The sample history survives the stop,
        // so coming back doesn't start the graphs from blank.
        .onAppear {
            monitor.startPolling()
        }
        .onDisappear { monitor.stopPolling() }
    }

    // MARK: - CPU

    private var cpuCard: some View {
        card(title: "CPU") {
            AreaSparkline(
                bands: [
                    // Bottom-up, same order as Activity Monitor stacks them:
                    // system underneath, user riding on top of it.
                    AreaSparkline.Band(values: monitor.cpuHistory.map(\.system), color: Self.systemInk),
                    AreaSparkline.Band(values: monitor.cpuHistory.map(\.user), color: Self.userInk)
                ],
                capacity: SystemMonitorService.historyLength)
                .frame(height: Self.graphHeight)
                .accessibilityLabel("CPU load over the last forty samples")
            statRow(swatch: Self.systemInk, title: "System", value: percentString(monitor.cpuBreakdown?.system))
            statRow(swatch: Self.userInk, title: "User", value: percentString(monitor.cpuBreakdown?.user))
            statRow(swatch: nil, title: "Idle", value: percentString(monitor.cpuBreakdown?.idle))
            statRow(swatch: nil, title: "Processes", value: monitor.processCount.map { $0.formatted() } ?? "—")
            activityMonitorLink
        }
    }

    /// The way out to the real thing.
    ///
    /// This card is a glance, not a tool: it cannot show a per-process table, and
    /// it deliberately omits the thread count it has no privilege to read. When
    /// the glance isn't enough, the honest move is to hand over to the app that
    /// can answer properly rather than grow a second Activity Monitor in a notch.
    ///
    /// Sits under the CPU column because that is where the missing detail hurts
    /// most — "what is eating my CPU" is a question this card raises and cannot
    /// answer.
    private var activityMonitorLink: some View {
        Button {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 9, weight: .semibold))
                Text("Go to Activity Monitor")
                    .font(.sf(10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            // The row IS the button: a plain-styled button hit-tests only its
            // drawn glyphs, which at this size is a target you have to hunt for.
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Tokens.accent)
        .accessibilityLabel("Open Activity Monitor")
    }

    // MARK: - Memory

    private var memoryCard: some View {
        // The caption is the kernel's real three-state pressure flag. The curve
        // is a locally sampled pressure proxy, but its ink follows that real
        // state so warning and critical conditions read exactly like Activity
        // Monitor rather than remaining misleadingly green.
        card(title: "Memory", caption: (text: "Pressure: \(monitor.memoryPressureLevel.label)", tint: pressureTint)) {
            AreaSparkline(
                bands: [AreaSparkline.Band(values: monitor.memoryPressureHistory, color: pressureTint)],
                capacity: SystemMonitorService.historyLength)
                .frame(height: Self.graphHeight)
                .accessibilityLabel("Memory pressure over the last forty samples")
            statRow(swatch: nil, title: "Physical",
                    value: SystemMonitorService.byteString(monitor.memoryTotalBytes))
            statRow(swatch: nil, title: "Used",
                    value: byteString(monitor.memoryUsedBytes),
                    isCritical: isCritical(monitor.memoryUsedPercent))
            statRow(swatch: nil, title: "Cached", value: byteString(monitor.memoryCachedBytes))
            statRow(swatch: nil, title: "Compressed", value: byteString(monitor.memoryCompressedBytes))
            statRow(swatch: nil, title: "Swap", value: byteString(monitor.swapUsedBytes))
        }
    }

    private var pressureTint: Color {
        switch monitor.memoryPressureLevel.graphTone {
        case .normal: return Self.pressureInk
        case .warning: return Tokens.captureTint
        case .critical: return .red
        case .unknown: return Tokens.text4
        }
    }

    // MARK: - Shared card chrome

    /// Same padding, corner radius and fill as `NotchShelfView` and
    /// `NotchUtilitiesView`, including the `maxWidth` that makes the background
    /// fill its whole column — without it the two cards draw at different widths
    /// and the gutter stops matching the layout's real seam.
    private func card<Content: View>(
        title: String,
        caption: (text: String, tint: Color)? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.sf(11, weight: .semibold)).foregroundStyle(Tokens.text3)
                Spacer(minLength: 4)
                if let caption {
                    Circle().fill(caption.tint).frame(width: 5, height: 5)
                    Text(caption.text)
                        .font(.sf(9.5, weight: .medium)).foregroundStyle(Tokens.text3)
                        .lineLimit(1)
                }
            }
            VStack(spacing: 5) { content() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// One footer line: an optional series swatch, a label, and a right-aligned
    /// monospaced number. Flatter than the boxed rows this card used to carry —
    /// four of those per card would be a wall of chips, and the numbers are the
    /// point here, not the containers.
    private func statRow(swatch: Color?, title: String, value: String, isCritical: Bool = false) -> some View {
        HStack(spacing: 7) {
            // Rows with no series still reserve the swatch, so every label in
            // the card starts on the same x.
            Circle()
                .fill(swatch ?? .clear)
                .frame(width: 5, height: 5)
            Text(title)
                .font(.sf(10.5, weight: .medium))
                .foregroundStyle(Tokens.text2)
            Spacer(minLength: 6)
            Text(value)
                .font(.sf(10.5, weight: .semibold).monospacedDigit())
                .foregroundStyle(isCritical ? Color.orange : Tokens.text1)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }

    /// Two decimals, the way Activity Monitor's own footer prints them. The
    /// digits are monospaced, so the extra precision costs nothing in jitter.
    private func percentString(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f%%", value)
    }

    private func byteString(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return SystemMonitorService.byteString(bytes)
    }

    private func isCritical(_ value: Double?) -> Bool {
        guard let value else { return false }
        return value >= Self.criticalThreshold
    }

}

// MARK: - Sparkline

/// A right-anchored stacked area chart over a fixed 0...100 scale.
///
/// Right-anchored because that is how Activity Monitor's graphs fill: the
/// newest sample pins to the right edge and older ones march left, so a buffer
/// that has only collected six samples draws six samples' worth of trace at the
/// right rather than stretching six points across the whole card and pretending
/// to be a full history.
///
/// Fixed 0...100 rather than auto-scaled to the data, for the same reason
/// Activity Monitor does it: an auto-scaled graph makes 3% CPU look identical
/// to 90% CPU, which is exactly the distinction the graph exists to make.
///
/// Drawn as a low-opacity fill with a thin brighter stroke on its upper edge —
/// ambient texture behind the numbers, not a chart demanding to be read.
private struct AreaSparkline: View {
    struct Band {
        /// This band's own contribution per sample, not a running total — the
        /// view stacks them. Oldest first.
        let values: [Double]
        let color: Color
    }

    let bands: [Band]
    /// The buffer's full size, which sets the horizontal spacing between
    /// samples. Without it the trace would re-scale on every tick until the
    /// buffer filled, and the graph would appear to breathe.
    let capacity: Int

    private var sampleCount: Int { bands.map(\.values.count).min() ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                ForEach(Array(bands.enumerated()), id: \.offset) { index, band in
                    let lower = points(cumulative(throughBand: index), in: size)
                    let upper = points(cumulative(throughBand: index + 1), in: size)
                    if upper.count >= 2 {
                        bandPath(lower: lower, upper: upper)
                            .fill(band.color.opacity(0.30))
                        polyline(upper)
                            .stroke(band.color.opacity(0.9), style: StrokeStyle(lineWidth: 1, lineJoin: .round))
                    }
                }
            }
        }
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
    }

    /// The running total of every band up to (but not including) `throughBand`
    /// — i.e. the y a band sits on top of. Band 0 sits on the floor.
    private func cumulative(throughBand index: Int) -> [Double] {
        var totals = [Double](repeating: 0, count: sampleCount)
        for band in bands.prefix(index) {
            for sample in 0..<sampleCount { totals[sample] += band.values[sample] }
        }
        return totals
    }

    private func points(_ values: [Double], in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty, size.width > 0, size.height > 0 else { return [] }
        let step = size.width / CGFloat(max(capacity - 1, 1))
        return values.enumerated().map { index, value in
            let fromRight = CGFloat(values.count - 1 - index)
            let fraction = min(max(value, 0), 100) / 100
            return CGPoint(
                x: size.width - fromRight * step,
                y: size.height - size.height * CGFloat(fraction))
        }
    }

    /// The closed ribbon between two curves — filled per band so stacked bands
    /// never overlap. Overlapping translucent fills would muddy each other's
    /// colour, and the whole point of the red/blue split is that the two stay
    /// distinguishable.
    private func bandPath(lower: [CGPoint], upper: [CGPoint]) -> Path {
        var path = Path()
        guard upper.count >= 2, lower.count == upper.count else { return path }
        path.move(to: upper[0])
        for point in upper.dropFirst() { path.addLine(to: point) }
        for point in lower.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private func polyline(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}
