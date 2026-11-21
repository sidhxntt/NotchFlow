import Foundation
import AppKit

/// Tails a run's stdout log file: a quarter-second timer reads whatever grew
/// since the last tick and hands it to `onData` (the pipe readability handler
/// this replaced pushed the same bytes; the parser line-buffers, so chunk
/// boundaries don't matter). `finishAndDrain` — called once the process is
/// known to have exited — stops the timer and synchronously reads the file to
/// its end, so the final result event is always ingested before the settle.
final class RunLogTailer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let timer: DispatchSourceTimer
    private let handle: FileHandle?
    private let onData: (Data) -> Void
    private var finished = false

    init(url: URL, onData: @escaping (Data) -> Void) {
        self.onData = onData
        queue = DispatchQueue(label: "com.lofilab.notch.agent-tail", qos: .utility)
        handle = try? FileHandle(forReadingFrom: url)
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
    }

    deinit { timer.cancel() }

    /// Runs on `queue`. `availableData` on a regular file returns what sits
    /// between the current offset and EOF — empty (without blocking) when
    /// nothing new arrived.
    private func poll() {
        guard !finished, let handle else { return }
        let data = handle.availableData
        if !data.isEmpty { onData(data) }
    }

    /// Stop polling and synchronously drain the rest of the file. Idempotent;
    /// safe from any thread.
    func finishAndDrain() {
        timer.cancel()
        queue.sync {
            guard !finished else { return }
            finished = true
            guard let handle else { return }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { break }
                onData(data)
            }
            try? handle.close()
        }
    }
}

/// A one-shot gate for teardown paths that can race (a re-attached run's exit
/// watch vs. the immediate liveness re-probe) — first caller wins.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    func tryFire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
