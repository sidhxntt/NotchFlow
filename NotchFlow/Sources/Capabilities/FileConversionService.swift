import Foundation

/// Per-file conversion and processing for the File tray, driven by the user's
/// own `my_media_automations` CLI (`auto`).
///
/// The CLI is four standalone tools behind one launcher — `auto <tool> <path>
/// <args…>` — and every one of them falls back to `@clack/prompts` when the
/// arguments it wants are absent. A GUI spawn has no TTY, so a missing argument
/// is not a prompt the user can answer, it is a process that never exits. Every
/// action modelled here therefore carries **all** of its arguments, including
/// the ones that are optional at a terminal:
///
///  - `convert … gif` also passes fps and width (`argv[4]`, `argv[5]`) — the
///    tool prompts unless it has *both*.
///  - `image … svg` also passes the SVG mode (`argv[4]`), and only ever `embed`:
///    the three tracing modes need `vtracer` on PATH, which is not a dependency
///    of the package.
///  - `bg … <background>` also passes the subject mode (`argv[4]`).
///
/// This file lives in `NotchCapabilities`, which cannot see `ShellEnvironment`
/// (that is in the app target). The two things a spawn needs from it — finding
/// `auto` on the user's *login-shell* PATH, and a child environment that can
/// resolve `node` for the shebang — arrive through `FileConversionShell`,
/// injected once by the UI. See `NotchShelfView.configureFileConversions()`.

// MARK: - Actions

/// One entry in a tray row's dropdown: a tool, the arguments that drive it
/// non-interactively, and what the produced file will be called.
public struct FileConversionAction: Identifiable, Hashable, Sendable {

    public enum Tool: String, Hashable, Sendable, CaseIterable {
        case convert, image, bg, compress

        /// The subfolder each tool creates *beside the input file*. Verified by
        /// running all four once in /tmp — they do not agree, so this cannot be
        /// assumed from `convert`'s behaviour alone.
        public var outputFolder: String {
            switch self {
            case .convert, .image: return "converted"
            case .bg: return "no-bg"
            case .compress: return "compressed"
            }
        }

        /// Menu section heading. Two tools share one heading on purpose: from the
        /// user's side `convert` and `image` are both "turn this into that", and
        /// which binary does it is an implementation detail.
        public var sectionTitle: String {
            switch self {
            case .convert, .image: return "Convert to"
            case .bg: return "Remove background"
            case .compress: return "Compress"
            }
        }

        /// Present participle for the running row, e.g. "Converting to PDF…".
        public var progressVerb: String {
            switch self {
            case .convert, .image: return "Converting to"
            case .bg: return "Removing background"
            case .compress: return "Compressing"
            }
        }
    }

    public let tool: Tool
    /// `argv[3]` — the target format, background or mode.
    public let argument: String
    /// `argv[4…]` — everything the tool would otherwise stop and ask for.
    public let extraArguments: [String]
    /// What the menu item says.
    public let label: String
    /// Extension of the file the tool writes. `nil` means "whatever the input
    /// was", which is what `compress` does — it re-encodes into the same
    /// container.
    public let outputExtension: String?

    public init(tool: Tool,
                argument: String,
                extraArguments: [String] = [],
                label: String,
                outputExtension: String?) {
        self.tool = tool
        self.argument = argument
        self.extraArguments = extraArguments
        self.label = label
        self.outputExtension = outputExtension
    }

    public var id: String {
        ([tool.rawValue, argument] + extraArguments).joined(separator: ":")
    }

    /// The full argument vector, minus the binary itself.
    public func arguments(input: URL) -> [String] {
        [tool.rawValue, input.path, argument] + extraArguments
    }
}

// MARK: - The catalog (pure)

/// Extension → available actions. No I/O, no CLI, no state: this is the part
/// worth pinning with tests, and `FileConversionServiceTests` does.
public enum FileConversionCatalog {

    // MARK: Source tables, mirrored from the CLI

    /// `src/convert/formats.ts` — `MATRIX`.
    static let convertMatrix: [String: [String]] = [
        "md": ["docx", "pdf", "html"],
        "markdown": ["docx", "pdf", "html"],
        "docx": ["md", "pdf", "html"],
        "html": ["pdf", "md", "docx"],
        "htm": ["pdf", "md", "docx"],
        "csv": ["json", "yaml", "xlsx"],
        "json": ["csv", "yaml", "xlsx"],
        "yaml": ["json", "csv", "xlsx"],
        "yml": ["json", "csv", "xlsx"],
        "xlsx": ["csv", "json", "yaml"],
        "mp4": ["gif", "mp3"],
        "mov": ["gif", "mp3"],
        "mkv": ["gif", "mp3"],
        "webm": ["gif", "mp3"],
        "avi": ["gif", "mp3"],
        "m4v": ["gif", "mp3"],
        "wav": ["mp3"],
        "m4a": ["mp3"],
        "aac": ["mp3"],
        "flac": ["mp3"],
        "ogg": ["mp3"],
        "mp3": ["wav"],
    ]

    /// `src/image/formats.ts` — `IMAGE_EXTENSIONS`.
    static let imageSources: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "jpe", "png", "webp", "gif", "bmp", "tif",
        "tiff", "avif", "jp2", "j2k", "ico", "psd", "svg", "dng", "cr2", "nef",
        "arw", "raf", "orf", "rw2",
    ]

    /// `src/image/formats.ts` — `VIDEO_EXTENSIONS`. The image tool's one video
    /// trick is remuxing to MP4, and it ignores `argv[3]` entirely on that path.
    static let imageVideoSources: Set<String> = [
        "mov", "qt", "mp4", "m4v", "avi", "mkv", "webm", "wmv", "flv", "mpg",
        "mpeg", "m2v", "3gp", "3g2", "mts", "m2ts", "ts", "ogv", "vob", "asf",
        "divx",
    ]

    /// `IMAGE_TARGETS` minus `jpg`: the CLI's own `dedupeTargets` treats `jpeg`
    /// and `jpg` as one encoder, so offering both is two menu items that write
    /// the same bytes.
    static let imageTargets = ["png", "jpeg", "webp", "svg"]

    /// `src/bg/formats.ts` — `IMAGE_EXTENSIONS`. Narrower than the image tool's:
    /// Vision goes through ImageIO, so no RAW and no PSD.
    static let backgroundSources: Set<String> = [
        "heic", "heif", "jpg", "jpeg", "jpe", "png", "webp", "tif", "tiff",
        "bmp", "gif", "avif", "jp2",
    ]

    /// `src/compress/formats.ts`.
    static let compressImageSources: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "webp", "tif", "tiff", "avif",
    ]

    static let compressVideoSources: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg",
        "3gp", "mts", "m2ts", "ts",
    ]

    /// `src/compress/formats.ts` — `MODES`.
    static let compressModes = [
        ("normal", "Normal", "visually lossless"),
        ("super", "Super", "caps images at 2560px, video at 1080p"),
        ("ultra", "Ultra", "smallest, 1600px / 720p30"),
    ]

    /// `src/bg/formats.ts` — `OUTPUT_MODES`, minus `custom` (which needs a hex
    /// colour the menu has nowhere to ask for). Output is always PNG.
    static let backgroundModes = [
        ("transparent", "Transparent"),
        ("white", "White"),
        ("black", "Black"),
    ]

    // MARK: Naming

    /// The CLI collapses these pairs before deciding whether a conversion is a
    /// no-op, and so do we — `.htm → html` and `.yml → yaml` are re-writes, not
    /// conversions, and they should not be in the menu.
    static func normalized(_ format: String) -> String {
        switch format.lowercased() {
        case "markdown": return "md"
        case "htm": return "html"
        case "yml": return "yaml"
        case "jpg": return "jpeg"
        default: return format.lowercased()
        }
    }

    /// Menu wording for a target format. The extension is the honest label for
    /// most of these; the two that are jargon get spelled out.
    static func targetLabel(_ target: String) -> String {
        switch target {
        case "md": return "Markdown"
        case "xlsx": return "Excel"
        case "svg": return "SVG"
        case "webp": return "WebP"
        default: return target.uppercased()
        }
    }

    // MARK: The mapping

    public static func actions(for url: URL) -> [FileConversionAction] {
        actions(forExtension: url.pathExtension)
    }

    /// Everything the four tools can do with a file of this extension.
    ///
    /// Case-insensitive, tolerant of a leading dot, and never offers a
    /// conversion to the format the file is already in. An extension no tool
    /// recognises returns `[]`, and the row then shows no dropdown at all.
    public static func actions(forExtension rawExtension: String) -> [FileConversionAction] {
        let ext = rawExtension
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .drop(while: { $0 == "." })
        let source = String(ext)
        guard !source.isEmpty else { return [] }
        let selfFormat = normalized(source)

        var actions: [FileConversionAction] = []

        // 1. convert — documents, data, video, audio.
        for target in convertMatrix[source] ?? [] where normalized(target) != selfFormat {
            // GIF is the one target with follow-up questions. 15fps/640px is the
            // CLI's own default pair, and passing both is what keeps it silent.
            let extras = target == "gif" ? ["15", "640"] : []
            actions.append(FileConversionAction(
                tool: .convert,
                argument: target,
                extraArguments: extras,
                label: targetLabel(target),
                outputExtension: target))
        }

        // 2. image — raster conversion, plus the video → MP4 remux.
        if imageSources.contains(source) {
            for target in imageTargets where normalized(target) != selfFormat {
                // `embed` is the only SVG mode that works out of the box; the
                // traces need `cargo install vtracer`.
                let extras = target == "svg" ? ["embed"] : []
                let label = target == "svg" ? "SVG (embedded)" : targetLabel(target)
                actions.append(FileConversionAction(
                    tool: .image,
                    argument: target,
                    extraArguments: extras,
                    label: label,
                    outputExtension: target))
            }
        } else if imageVideoSources.contains(source), source != "mp4" {
            actions.append(FileConversionAction(
                tool: .image,
                argument: "mp4",
                label: "MP4",
                outputExtension: "mp4"))
        }

        // 3. bg — Vision background removal. Always PNG out.
        if backgroundSources.contains(source) {
            for (mode, label) in backgroundModes {
                actions.append(FileConversionAction(
                    tool: .bg,
                    argument: mode,
                    // Without argv[4] the tool stops and asks which subjects to
                    // keep. `all` is its own default.
                    extraArguments: ["all"],
                    label: label,
                    outputExtension: "png"))
            }
        }

        // 4. compress — same container, fewer bytes.
        if compressImageSources.contains(source) || compressVideoSources.contains(source) {
            for (mode, label, _) in compressModes {
                actions.append(FileConversionAction(
                    tool: .compress,
                    argument: mode,
                    label: label,
                    outputExtension: nil))
            }
        }

        return actions
    }

    // MARK: Where the output lands

    /// The folder a tool writes into for a given input: `<input dir>/<tool
    /// folder>/`.
    public static func outputDirectory(for tool: FileConversionAction.Tool, input: URL) -> URL {
        input.deletingLastPathComponent()
            .appendingPathComponent(tool.outputFolder, isDirectory: true)
    }

    /// The path a tool will write, assuming no name collision. The tools do
    /// disambiguate collisions (`-jpg`, `-1` suffixes), which is why the
    /// service falls back to scanning the folder rather than trusting this
    /// alone — but it is right in the overwhelmingly common case.
    public static func expectedOutputURL(for action: FileConversionAction, input: URL) -> URL {
        let dir = outputDirectory(for: action.tool, input: input)
        let base = input.deletingPathExtension().lastPathComponent
        switch action.tool {
        case .convert, .image:
            return dir.appendingPathComponent(base)
                .appendingPathExtension(action.outputExtension ?? input.pathExtension)
        case .bg:
            // The background is baked into the name so the variants never
            // overwrite each other.
            return dir.appendingPathComponent("\(base)-\(action.argument)")
                .appendingPathExtension("png")
        case .compress:
            return dir.appendingPathComponent("\(base)-\(action.argument)")
                .appendingPathExtension(input.pathExtension.lowercased())
        }
    }
}

// MARK: - Outcome

public struct FileConversionOutcome: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// At least one file was produced.
        case success
        /// The tool ran and exited cleanly but wrote nothing — an already
        /// well-compressed image, a photo Vision finds no subject in. Not a
        /// failure, and saying "failed" would be a lie.
        case noChange
        case failure
    }

    public let kind: Kind
    public let message: String
    public let outputs: [URL]

    public init(kind: Kind, message: String, outputs: [URL] = []) {
        self.kind = kind
        self.message = message
        self.outputs = outputs
    }
}

// MARK: - Shell injection

/// The two things a spawn needs from the app target's `ShellEnvironment`.
///
/// Passed in rather than imported because this file compiles as part of the
/// `NotchCapabilities` library, which `ShellEnvironment` is not in. The closures
/// are `@Sendable`; the `Process` one is *called* on the background queue that
/// runs the job, so no `Process` ever crosses an isolation boundary.
public struct FileConversionShell: Sendable {
    public let which: @Sendable ([String]) -> String?
    public let makeProcess: @Sendable (String, [String], URL?) -> Process

    public init(which: @escaping @Sendable ([String]) -> String?,
                makeProcess: @escaping @Sendable (String, [String], URL?) -> Process) {
        self.which = which
        self.makeProcess = makeProcess
    }
}

// MARK: - The service

@MainActor
public final class FileConversionService: ObservableObject {
    public static let shared = FileConversionService()

    public enum Availability: Equatable, Sendable {
        /// Not probed yet — the tray shows nothing rather than flashing an
        /// affordance that may be about to disappear.
        case unknown
        case available(String)
        case missing
    }

    @Published public private(set) var availability: Availability = .unknown
    /// Job currently running, keyed by the caller's row key.
    @Published public private(set) var running: [String: FileConversionAction] = [:]
    /// Last result per row key, cleared on a timer so the tray does not
    /// accumulate stale status.
    @Published public private(set) var outcomes: [String: FileConversionOutcome] = [:]

    /// Generous on purpose: a two-minute 4K clip going to GIF is a real thing
    /// someone will drop in the tray, and killing it at 60s would look broken.
    /// The point of the ceiling is that a wedged process cannot hang the row
    /// forever, not that it enforces a budget.
    public nonisolated static let timeout: TimeInterval = 300

    /// The launcher exposes two identical binaries; either will do.
    nonisolated static let binaryNames = ["auto", "my_media_automations"]

    private var shell: FileConversionShell?
    private var probing = false
    private var clearTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    // MARK: Availability

    /// Wire up the shell and resolve `auto` once, off the main thread. Safe to
    /// call from `.task` on every appearance — it does the work only once.
    public func prepare(shell: FileConversionShell) {
        if self.shell == nil { self.shell = shell }
        guard case .unknown = availability, !probing else { return }
        probing = true
        Task.detached(priority: .utility) { [shell] in
            let resolved = Self.locateBinary(shell: shell)
            await MainActor.run {
                self.probing = false
                self.availability = resolved.map { .available($0) } ?? .missing
            }
        }
    }

    public var resolvedBinary: String? {
        if case let .available(path) = availability { return path }
        return nil
    }

    /// Find `auto` on the user's login-shell PATH and prove it actually runs.
    ///
    /// The launcher has no `--version`, and running it bare opens its
    /// interactive menu — so the smoke test asks for a tool that cannot exist.
    /// A real launcher answers `Unknown tool "…"` and exits 1 in ~200ms; a
    /// broken shim does neither.
    nonisolated static func locateBinary(shell: FileConversionShell) -> String? {
        guard let path = shell.which(binaryNames) else { return nil }
        let process = shell.makeProcess(path, ["__notchflow_probe__"], nil)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.contains("Unknown tool") ? path : nil
    }

    // MARK: Running a job

    public func isRunning(key: String) -> Bool { running[key] != nil }

    /// Run one action against one file. `key` identifies the tray row, so two
    /// rows can convert at once but one row cannot start a second job on top of
    /// its own.
    public func run(_ action: FileConversionAction,
                    on input: URL,
                    key: String,
                    onFinish: (@MainActor ([URL]) -> Void)? = nil) {
        guard running[key] == nil else { return }
        guard let shell, let binary = resolvedBinary else {
            publish(FileConversionOutcome(kind: .failure,
                                          message: "Media Automations CLI not found"),
                    for: key)
            return
        }

        clearTasks[key]?.cancel()
        clearTasks[key] = nil
        outcomes[key] = nil
        running[key] = action

        Task.detached(priority: .userInitiated) { [shell, binary] in
            let outcome = Self.execute(action: action, input: input, binary: binary, shell: shell)
            await MainActor.run {
                self.running[key] = nil
                self.publish(outcome, for: key)
                if outcome.kind == .success { onFinish?(outcome.outputs) }
            }
        }
    }

    private func publish(_ outcome: FileConversionOutcome, for key: String) {
        outcomes[key] = outcome
        // A success is confirmation the new file is now in the tray, so it can
        // go quiet quickly. A failure is the only place the reason is written
        // down, so it lingers.
        let linger: UInt64 = outcome.kind == .failure ? 30 : 6
        clearTasks[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: linger * 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.outcomes[key] = nil
        }
    }

    public func dismissOutcome(key: String) {
        clearTasks[key]?.cancel()
        clearTasks[key] = nil
        outcomes[key] = nil
    }

    // MARK: Execution

    /// Spawn, wait (bounded), then work out what was written. Runs entirely off
    /// the main thread.
    nonisolated static func execute(action: FileConversionAction,
                                    input: URL,
                                    binary: String,
                                    shell: FileConversionShell) -> FileConversionOutcome {
        guard FileManager.default.fileExists(atPath: input.path) else {
            return FileConversionOutcome(kind: .failure, message: "File is missing")
        }

        // Anchored just before the spawn: everything the tool writes lands after
        // this, which is how a fresh output is told from one left by an earlier
        // run. A second of slack absorbs filesystem timestamp granularity.
        let startedAt = Date().addingTimeInterval(-1)

        let process = shell.makeProcess(binary, action.arguments(input: input),
                                        input.deletingLastPathComponent())
        let pipe = Pipe()
        // One pipe for both streams: a separate stderr pipe nobody drains is a
        // deadlock waiting for a chatty ffmpeg run to fill its buffer.
        process.standardOutput = pipe
        process.standardError = pipe
        // The tools fall back to interactive prompts whenever an argument is
        // missing. With no TTY that is an unkillable wait, so stdin is closed
        // from the start — a prompt then dies instead of hanging.
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return FileConversionOutcome(kind: .failure,
                                         message: "Could not start the CLI: \(error.localizedDescription)")
        }

        let timedOut = TimeoutFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.trip()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // SIGTERM is a request. A node process wedged in a native ffmpeg call
        // can ignore it, and then the row would still never finish.
        let executioner = DispatchWorkItem {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 10, execute: executioner)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        executioner.cancel()

        let output = String(data: data, encoding: .utf8) ?? ""

        if timedOut.tripped {
            return FileConversionOutcome(
                kind: .failure,
                message: "Timed out after \(Int(timeout / 60)) min")
        }

        let outputs = locateOutputs(for: action, input: input, since: startedAt)

        guard process.terminationStatus == 0 else {
            return FileConversionOutcome(kind: .failure,
                                         message: summarize(output) ?? "Conversion failed",
                                         outputs: outputs)
        }
        guard !outputs.isEmpty else {
            // The launcher exits 0 even when the single job inside it failed —
            // it counts failures and reports them in its own summary rather
            // than in the status code. So "clean exit, nothing written" is two
            // different outcomes, and only the transcript can tell them apart:
            //  - a deliberate no-op (compress binning a result that saved <5%,
            //    bg skipping an image Vision finds no subject in) is marked ⏭,
            //  - a real failure (a malformed JSON, a missing ffmpeg) is marked ❌.
            let failed = output.contains("❌")
            return FileConversionOutcome(kind: failed ? .failure : .noChange,
                                         message: summarize(output)
                                            ?? (failed ? "Conversion failed" : "Nothing to do"))
        }
        return FileConversionOutcome(kind: .success,
                                     message: outputs.count == 1
                                        ? outputs[0].lastPathComponent
                                        : "\(outputs.count) files",
                                     outputs: outputs)
    }

    /// What the run actually produced.
    ///
    /// The predicted path first, because that is what happens almost always
    /// (including on a re-run, where the tool skips the work and leaves the
    /// earlier file in place — still the right thing to put in the tray). The
    /// folder scan is the fallback for the tools' collision suffixes, where a
    /// second source sharing a basename becomes `name-jpg.webp` or `name-1.webp`.
    nonisolated static func locateOutputs(for action: FileConversionAction,
                                          input: URL,
                                          since: Date) -> [URL] {
        let expected = FileConversionCatalog.expectedOutputURL(for: action, input: input)
        let fm = FileManager.default
        if fm.fileExists(atPath: expected.path) { return [expected] }

        let dir = FileConversionCatalog.outputDirectory(for: action.tool, input: input)
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let wantedExtension = expected.pathExtension.lowercased()
        let stem = expected.deletingPathExtension().lastPathComponent

        return entries
            .filter { $0.pathExtension.lowercased() == wantedExtension }
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(stem) }
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                               .isRegularFileKey])
                guard values?.isRegularFile == true else { return false }
                guard let modified = values?.contentModificationDate else { return false }
                return modified >= since
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// One short, honest line out of the CLI's box-drawn transcript.
    ///
    /// Prefers the line the tool marked as an error; otherwise the last thing it
    /// said. Clack's frame characters and any stray SGR codes are stripped, so
    /// the tray shows a sentence rather than a fragment of a box.
    nonisolated static func summarize(_ output: String) -> String? {
        let frame = CharacterSet(charactersIn: "│┌└├─╮╯◇◆◒○● \t")
        let lines = output
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]",
                                  with: "",
                                  options: .regularExpression)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: frame) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let chosen = lines.last { $0.contains("❌") } ?? lines[lines.count - 1]
        let cleaned = chosen
            .replacingOccurrences(of: "❌", with: "")
            // Clack's spinner leaves its elapsed timer glued to the end of the
            // line it stops on ("… -> .csv [0s]"), which is noise once the run
            // is over.
            .replacingOccurrences(of: "\\s*\\[[0-9]+[a-z]?(\\s+[0-9]+[a-z])*\\]$",
                                  with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        return String(cleaned.prefix(120))
    }

    /// Set from the watchdog queue, read after the wait — needs a lock, however
    /// briefly it is contended.
    private final class TimeoutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var tripped: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func trip() { lock.lock(); value = true; lock.unlock() }
    }
}
