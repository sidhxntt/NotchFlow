import Darwin
import Foundation

/// One CPU sample split the way Activity Monitor's footer splits it: the
/// three percentages that always sum to 100.
///
/// `nice` ticks are folded into `user` — Activity Monitor does the same, and a
/// fourth series nobody recognises would only make the row list longer.
public struct CPUBreakdown: Equatable, Sendable {
    public let system: Double
    public let user: Double
    public let idle: Double

    public init(system: Double, user: Double, idle: Double) {
        self.system = system
        self.user = user
        self.idle = idle
    }

    /// What the old single-number readout showed — everything that isn't idle.
    public var busy: Double { min(100, max(0, system + user)) }
}

/// `kern.memorystatus_vm_pressure_level`, the one *real* pressure signal the
/// kernel hands out to unprivileged callers. It is a three-state flag, not a
/// curve — which is why the green graph next to it is a separate, derived
/// proxy (see `memoryPressureProxyPercent`).
public enum MemoryPressureLevel: Int, Sendable {
    case unknown = 0
    case normal = 1
    case warning = 2
    case critical = 4

    init(raw: Int32) {
        self = MemoryPressureLevel(rawValue: Int(raw)) ?? .unknown
    }

    public var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case .unknown: return "—"
        }
    }

    /// A semantic rendering tone for the pressure trace. Keeping the mapping
    /// beside the kernel value ensures the caption and graph cannot disagree.
    public var graphTone: MemoryPressureGraphTone {
        switch self {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        case .unknown: return .unknown
        }
    }
}

public enum MemoryPressureGraphTone: Sendable, Equatable {
    case normal
    case warning
    case critical
    case unknown
}

/// Live CPU, memory, and disk readouts for the Activity Monitor card in the
/// Utilities tab.
///
/// Same shape as `SystemUtilityService`: a `.shared` singleton, `@Published
/// private(set)` readouts, and a `refresh()` that pulls a fresh sample. Unlike
/// that service, this one is deliberately gated behind `startPolling()` /
/// `stopPolling()` rather than firing on every `refresh()` call from wherever
/// — CPU load needs two samples to diff, so the ticker owns pacing, and the
/// Activity Monitor card starts/stops it from `onAppear`/`onDisappear` so
/// nothing samples Mach host stats while nobody is looking at them.
///
/// What it deliberately does NOT report: a system-wide thread count. Activity
/// Monitor shows one, but getting it needs `task_for_pid` on every process,
/// which needs root — `task_threads` on our own task just returns our own
/// handful. A plausible-looking estimate would be a lie, so there isn't one.
@MainActor
public final class SystemMonitorService: ObservableObject {
    public static let shared = SystemMonitorService()

    /// How many samples the sparklines keep. Lives on the service, not the
    /// view: the buffer has to survive the card being scrolled away and come
    /// back with its history intact, and the service is the thing that
    /// outlives the view.
    nonisolated public static let historyLength = 40

    /// The system / user / idle split behind the visible CPU history.
    @Published public private(set) var cpuBreakdown: CPUBreakdown?
    /// Oldest first, newest last, at most `historyLength` entries.
    @Published public private(set) var cpuHistory: [CPUBreakdown] = []
    /// Live process count. Cheap and unprivileged, unlike the thread count.
    @Published public private(set) var processCount: Int?

    @Published public private(set) var memoryUsedBytes: UInt64?
    @Published public private(set) var memoryCompressedBytes: UInt64?
    @Published public private(set) var memoryCachedBytes: UInt64?
    @Published public private(set) var swapUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64 = ProcessInfo.processInfo.physicalMemory

    /// The kernel's own three-state pressure flag.
    @Published public private(set) var memoryPressureLevel: MemoryPressureLevel = .unknown
    /// Our derived 0...100 stand-in for a pressure *curve*. Not Apple's number.
    @Published public private(set) var memoryPressureProxyPercent: Double?
    @Published public private(set) var memoryPressureHistory: [Double] = []

    private var previousCPULoad: host_cpu_load_info?
    private var ticker: Timer?

    public var memoryUsedPercent: Double? {
        guard let memoryUsedBytes else { return nil }
        return Self.usedPercent(used: memoryUsedBytes, total: memoryTotalBytes)
    }

    // MARK: - Polling

    /// Starts a repeating sample. Idempotent — calling it again while already
    /// running (e.g. a second `onAppear`) just leaves the existing ticker in
    /// place instead of stacking timers, the same guard `FocusTimerStore` uses
    /// for its own ticker.
    public func startPolling(interval: TimeInterval = 1.5) {
        guard ticker == nil else { return }
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    /// Stops sampling and drops the CPU baseline — the next `startPolling()`
    /// should not diff against a sample that might be minutes stale.
    ///
    /// The sparkline history is deliberately *not* cleared: the card gets torn
    /// down and rebuilt every time the user flips away from it and back, and
    /// throwing away forty samples on each flip would leave the graphs blank
    /// for the first minute of every visit.
    public func stopPolling() {
        ticker?.invalidate()
        ticker = nil
        previousCPULoad = nil
    }

    public func refresh() {
        refreshCPU()
        refreshMemory()
    }

    // MARK: - CPU

    private func refreshCPU() {
        processCount = Self.liveProcessCount()
        guard let current = Self.hostCPULoadInfo() else { return }
        defer { previousCPULoad = current }
        guard let previous = previousCPULoad else { return }
        let ticks = current.cpu_ticks
        let previousTicks = previous.cpu_ticks
        let breakdown = Self.cpuBreakdown(
            user1: previousTicks.0, system1: previousTicks.1, idle1: previousTicks.2, nice1: previousTicks.3,
            user2: ticks.0, system2: ticks.1, idle2: ticks.2, nice2: ticks.3)
        cpuBreakdown = breakdown
        cpuHistory = Self.appending(breakdown, to: cpuHistory)
    }

    /// `proc_listallpids(nil, 0)` asks libproc for the size of the pid table
    /// without asking for the table itself — no buffer, no per-process
    /// inspection, no entitlement. (This is exactly why a process count is
    /// shippable and a thread count is not: threads live behind
    /// `task_for_pid`, the pid *count* does not.)
    nonisolated static func liveProcessCount() -> Int? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        return Int(count)
    }

    /// `host_cpu_load_info`'s tick counters are cumulative since boot — one
    /// sample says nothing on its own, only the delta between two samples
    /// does. This splits that delta the way Activity Monitor's footer does,
    /// into system / user / idle shares of the window.
    nonisolated static func cpuBreakdown(
        user1: UInt32, system1: UInt32, idle1: UInt32, nice1: UInt32,
        user2: UInt32, system2: UInt32, idle2: UInt32, nice2: UInt32
    ) -> CPUBreakdown {
        // `nice` is user-space work at a lowered priority, so it belongs on the
        // user side of the split rather than in a series of its own.
        let user = max(0, Double(Int64(user2) - Int64(user1)) + Double(Int64(nice2) - Int64(nice1)))
        let system = max(0, Double(Int64(system2) - Int64(system1)))
        let idle = max(0, Double(Int64(idle2) - Int64(idle1)))
        let total = user + system + idle
        // No elapsed ticks (or counters that went backwards) reads as a fully
        // idle window rather than as a divide-by-zero.
        guard total > 0 else { return CPUBreakdown(system: 0, user: 0, idle: 100) }
        return CPUBreakdown(
            system: system / total * 100,
            user: user / total * 100,
            idle: idle / total * 100)
    }

    /// The single "how busy is it" number, kept as the one-line answer to the
    /// same tick delta `cpuBreakdown` splits three ways. Same maths, one
    /// implementation — the two cannot drift.
    nonisolated static func cpuPercent(
        user1: UInt32, system1: UInt32, idle1: UInt32, nice1: UInt32,
        user2: UInt32, system2: UInt32, idle2: UInt32, nice2: UInt32
    ) -> Double {
        cpuBreakdown(
            user1: user1, system1: system1, idle1: idle1, nice1: nice1,
            user2: user2, system2: system2, idle2: idle2, nice2: nice2).busy
    }

    /// `host_statistics` with `HOST_CPU_LOAD_INFO` — ticks per CPU state since
    /// boot. `nonisolated` and static: it is a blocking syscall with no
    /// dependency on this actor's state.
    nonisolated static func hostCPULoadInfo() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPointer in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, reboundPointer, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info
    }

    // MARK: - Memory

    private func refreshMemory() {
        swapUsedBytes = Self.swapUsedBytes()
        memoryPressureLevel = Self.kernelMemoryPressureLevel()
        guard let stats = Self.vmStatistics(), let pageSize = Self.pageSize() else { return }
        let bytesPerPage = UInt64(pageSize)
        func bytes<T: BinaryInteger>(_ pages: T) -> UInt64 { UInt64(max(0, Int64(pages))) * bytesPerPage }

        // These four are an *approximation* of how Activity Monitor decomposes
        // memory, not a reproduction of it — Apple's exact arithmetic isn't
        // published, and the numbers below land within a few hundred MB of what
        // Activity Monitor shows on the same machine at the same moment.
        //
        //   App Memory  ≈ internal pages that aren't purgeable
        //   Wired       =  wire_count (kernel pages that can never be paged out)
        //   Compressed  =  compressor_page_count
        //   Cached Files≈ external (file-backed) pages + purgeable pages
        //   Memory Used ≈ App + Wired + Compressed
        let wired = bytes(stats.wire_count)
        let compressed = bytes(stats.compressor_page_count)
        let purgeable = bytes(stats.purgeable_count)
        let app = bytes(stats.internal_page_count) - min(bytes(stats.internal_page_count), purgeable)
        memoryCompressedBytes = compressed
        memoryCachedBytes = bytes(stats.external_page_count) + purgeable
        memoryUsedBytes = app + wired + compressed

        let proxy = Self.memoryPressureProxyPercent(
            wiredBytes: wired, compressedBytes: compressed, physicalBytes: memoryTotalBytes)
        memoryPressureProxyPercent = proxy
        if let proxy {
            memoryPressureHistory = Self.appending(proxy, to: memoryPressureHistory)
        }
    }

    /// A stand-in for a memory-pressure *curve*, because the kernel does not
    /// expose one: `kern.memorystatus_vm_pressure_level` is a three-state flag
    /// (normal / warning / critical) and would draw as a flat line.
    ///
    /// THIS IS NOT APPLE'S MEMORY PRESSURE NUMBER. It is the share of physical
    /// memory held by pages the system cannot simply reclaim — wired pages and
    /// the compressor's pages. Those are the two things that actually climb as
    /// a machine runs out of headroom, so the curve moves in the same direction
    /// as Apple's graph, but the absolute value is ours, not theirs. The UI
    /// labels it "Pressure" and never claims it is the system metric; the
    /// kernel's real three-state flag is reported separately as
    /// `memoryPressureLevel`.
    nonisolated static func memoryPressureProxyPercent(
        wiredBytes: UInt64, compressedBytes: UInt64, physicalBytes: UInt64
    ) -> Double? {
        guard physicalBytes > 0 else { return nil }
        let unreclaimable = Double(wiredBytes) + Double(compressedBytes)
        return min(100, max(0, unreclaimable / Double(physicalBytes) * 100))
    }

    /// `kern.memorystatus_vm_pressure_level` — readable without privileges,
    /// unlike almost everything else Activity Monitor leans on.
    nonisolated static func kernelMemoryPressureLevel() -> MemoryPressureLevel {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return .unknown
        }
        return MemoryPressureLevel(raw: level)
    }

    /// `vm.swapusage` — the swap file's used/total, in bytes.
    nonisolated static func swapUsedBytes() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    /// `host_statistics64` with `HOST_VM_INFO64` — page counts by state, scaled
    /// to bytes by the caller via `pageSize()`.
    nonisolated static func vmStatistics() -> vm_statistics64? {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64()
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { reboundPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, reboundPointer, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return stats
    }

    nonisolated static func pageSize() -> vm_size_t? {
        var pageSize: vm_size_t = 0
        let result = host_page_size(mach_host_self(), &pageSize)
        guard result == KERN_SUCCESS else { return nil }
        return pageSize
    }

    // MARK: - Shared formatting

    /// `used / total * 100`, clamped — the same shape both memory and disk
    /// percentages reduce to, pulled out once so it is testable and so the
    /// two call sites cannot drift.
    nonisolated static func usedPercent(used: UInt64, total: UInt64) -> Double? {
        guard total > 0 else { return nil }
        return min(100, max(0, Double(used) / Double(total) * 100))
    }

    /// "12.3 GB" — binary-prefixed, one decimal place, matching how macOS
    /// itself renders storage in About This Mac / Activity Monitor.
    nonisolated static func gigabytesString(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gib)
    }

    /// The memory footer's own unit ladder: "0 bytes" when there is genuinely
    /// none (which is what swap reads on a healthy machine, and rounding that
    /// to "0.0 GB" would look like a truncation rather than a fact), then KB /
    /// MB, then two-decimal GB — the same precision Activity Monitor prints,
    /// and enough to tell 16.06 GB from 16.60 GB at a glance.
    nonisolated static func byteString(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 bytes" }
        let value = Double(bytes)
        let kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if value < mb { return String(format: "%.0f KB", value / kb) }
        if value < gb { return String(format: "%.0f MB", value / mb) }
        return String(format: "%.2f GB", value / gb)
    }

    /// Rolling sparkline buffer: append the newest sample, evict from the front
    /// once the window is full. Pure and generic so both history buffers share
    /// one eviction rule and it can be tested without a live host.
    nonisolated static func appending<T>(_ sample: T, to history: [T], limit: Int = historyLength) -> [T] {
        guard limit > 0 else { return [] }
        var next = history
        next.append(sample)
        if next.count > limit { next.removeFirst(next.count - limit) }
        return next
    }
}
