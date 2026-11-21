import Foundation
import AppKit

@MainActor
extension AgentTaskManager {
    /// Spawn one round's process — the shared tail of `start` (fresh session)
    /// and `followUp` (`resumeSession` != nil). Each call owns a fresh
    /// `RunState`, so parallel rounds never trample each other's bookkeeping.
    func launch(taskID: UUID, binary: String, engine: AgentEngine, folder: URL,
                        prompt: String, model: String?, effort: AgentEffort?,
                        imagesJPEG: [Data], resumeSession: String?,
                        promptMarkerID: UUID? = nil) {
        let run = RunState()
        runs[taskID] = run
        run.currentPrompt = prompt
        run.promptMarkerID = promptMarkerID
        // The round's trail starts where the task's log stands now (any follow-up
        // marker already appended stays with the PREVIOUS round's tail, not this
        // round's slice — the prompt becomes the record's own user turn instead).
        run.logStartIndex = taskIndex(taskID).map { tasks[$0].log.count } ?? 0
        // Keep a copy of the round's images beside the archive, so the Recent row
        // this run settles into can show what it was handed. Same already-downsampled
        // JPEGs that go to the CLI — a couple hundred KB each, written once per spawn.
        run.currentImageFiles = imagesJPEG.compactMap { NotchModel.storeHistoryImage($0) }

        // A model flag rides only on an explicit pick from the armed row's menu
        // (`model != nil`); the default stays flag-less so the run honors the
        // user's OWN CLI configuration — a stale pinned id 404s the whole run
        // ("Model not found gpt-5.6-luna"), while the config default is what
        // the user's own CLI demonstrably runs.
        var args: [String]
        switch engine {
        case .codex:
            // Sandboxed workspace-write: can edit anything under the folder and
            // run commands inside codex's sandbox; network stays off (codex's own
            // workspace-write default). `resume` is an `exec` subcommand, so the
            // exec-only flags must precede it; placing --color/-s/-C after the
            // resumed prompt makes the resume parser reject the follow-up before
            // it starts. The explicit `-` positional below keeps that prompt on
            // stdin like round one.
            args = ["exec", "--json", "--skip-git-repo-check", "--color", "never",
                    "-s", "workspace-write", "-C", folder.path]
            if resumeSession != nil { args.append("resume") }
            if let model { args += ["-m", model] }
            if let effort {
                args += ["-c", "model_reasoning_effort=\(effort.rawValue)"]
            }
            // Pasted images attach via codex's own flag. They need real files:
            // written to the temp dir (NOT the project folder — the run must
            // never plant artifacts in the user's repo), deleted on settle.
            // One `-i` per image is the only form BOTH paths take: `exec`'s
            // `-i` is variadic, but `exec resume`'s takes a single value per
            // occurrence, so `-i a.jpg b.jpg` is a parse error there.
            for jpeg in imagesJPEG {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("notch-agent-\(UUID().uuidString).jpg")
                if (try? jpeg.write(to: url)) != nil {
                    args += ["-i", url.path]
                    run.tempImageURLs.append(url)
                }
            }
            if let resumeSession { args += [resumeSession, "-"] }
        case .claude:
            // acceptEdits auto-approves file edits under the project (the cwd),
            // and Bash/web are pre-authorized so builds/tests/doc-lookups run
            // unattended — anything else falls to acceptEdits' auto-deny rather
            // than hanging on a prompt no one will answer. Explicit on purpose:
            // a bare spawn would inherit whatever permission defaultMode the
            // user's settings.json happens to have. Deliberately NOT --safe-mode
            // (the user's CLAUDE.md/skills are assets for implementation work)
            // and NOT --no-session-persistence (the session should be resumable
            // from a terminal with `claude --resume`, same as codex's).
            // `--include-partial-messages` is what makes the trail STREAM: without
            // it the CLI emits each assistant message whole, so a paragraph the
            // model spent 40s writing lands in one lump. With it the same message
            // also arrives as token deltas (`stream_event`), which the parser
            // grows the trail entry from — and the whole-message event that still
            // follows corrects it, so the two can't disagree.
            args = ["-p", "--verbose", "--output-format", "stream-json",
                    "--include-partial-messages",
                    "--permission-mode", "acceptEdits",
                    "--allowedTools", "Bash,WebSearch,WebFetch"]
            // …and route what those permissions would have auto-approved through
            // the notch first. `--settings` points at an app-generated file (see
            // `ClaudeHookBridge`) holding a single `PreToolUse` hook for
            // Bash/Edit/Write/NotebookEdit — the Claude equivalent of the Codex
            // path's app-server approval callbacks, and the reason a
            // NotchFlow-launched Claude run asks before it executes or mutates.
            // The user's own ~/.claude/settings.json is never touched; Claude
            // Code merges this file on top of it for this process only, and the
            // flag rides EVERY spawn because flags don't carry across --resume.
            // Empty (so: unchanged behaviour) if the socket could not be opened.
            args += ClaudeHookBridge.shared.launchArguments()
            // A follow-up resumes the persisted session (that's why the agent
            // path never passes --no-session-persistence). Flags don't carry
            // over from the resumed session, so everything above rides again.
            if let resumeSession { args += ["--resume", resumeSession] }
            if let model { args += ["--model", model] }
            // Same knob as Codex's, via the CLI's own flag (`--effort
            // low|medium|high|xhigh|max`).
            if let effort { args += ["--effort", effort.rawValue] }
            // With pasted images, stdin switches from plain text to one
            // stream-json user message carrying text + base64 vision blocks —
            // the CLI's only image route (there is no `-i` equivalent). The
            // output dialect is stream-json either way, so parsing is untouched.
            if !imagesJPEG.isEmpty { args += ["--input-format", "stream-json"] }
        case .grok:
            // Grok headless needs the prompt via --prompt-file: bare stdin
            // errors "Device not configured (os error 6)", and `-p` would merge
            // the stdin the shared writer sends (double prompt) — but
            // --prompt-file is authoritative and ignores stdin (verified). The
            // prompt file rides `tempImageURLs` so it's cleaned up on settle.
            // --always-approve lets file edits / shell run unattended (the twin
            // of codex's workspace-write and claude's acceptEdits); --no-plan
            // stops it pausing on a plan no one will approve. NOT sandboxed
            // (grok's sandbox profiles aren't wired) — parity with the Claude
            // engine, which likewise runs Bash unconfined. Session persists, so
            // a follow-up rides `--resume <id>` (id parsed from the `end` event).
            let promptURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("notch-grok-prompt-\(UUID().uuidString).txt")
            try? Data(prompt.utf8).write(to: promptURL)
            run.tempImageURLs.append(promptURL)
            args = ["--prompt-file", promptURL.path,
                    "--output-format", "streaming-json",
                    "--always-approve", "--no-plan", "--no-memory", "--no-subagents",
                    "--no-auto-update", "--cwd", folder.path]
            if let resumeSession { args += ["--resume", resumeSession] }
            if let model { args += ["-m", model] }
            if let effort { args += ["--reasoning-effort", effort.rawValue] }
        case .commandCode:
            // `--yolo` is what lets file writes and shell commands run unattended:
            // headless denies both by default, and with no TTY there is nobody to
            // approve them (the twin of codex's workspace-write, claude's
            // acceptEdits and grok's --always-approve). `--trust` skips the
            // first-run project-trust prompt and `--skip-onboarding` the taste
            // onboarding — both would otherwise block a run with no TTY. The
            // session persists (no `--no-session`), so a follow-up rides
            // `--resume <id>`, the id parsed from `run_start`.
            args = ["-p", "--output-format", "json",
                    "--yolo", "--trust", "--skip-onboarding", "--no-auto-update"]
            if let resumeSession { args += ["--resume", resumeSession] }
            if let model { args += ["-m", model] }
            if let effort { args += ["--effort", effort.rawValue] }
        case .pi:
            // pi needs no unattended-approval flag at all: headless `-p` runs its
            // tools (read/write/edit/bash/ls/grep/find) without ever prompting —
            // verified against the installed build, where a run wrote a file and
            // ran a shell command with no TTY and no approval events. `--approve`
            // is the OTHER kind of trust: it opts the run into the project's own
            // AGENTS.md / extensions / skills, which is deliberate here (parity
            // with the Claude engine, which likewise treats the repo's own
            // instructions as assets for implementation work). `--offline` keeps a
            // startup version check off the run (the twin of the others'
            // `--no-auto-update`). The session persists by default, so a follow-up
            // rides `--session <id>`, the id parsed from the `session` header line.
            args = ["-p", "--mode", "json", "--approve", "--offline"]
            if let resumeSession { args += ["--session", resumeSession] }
            args += PiCLIService.modelArgs(for: model)
            if let effort { args += ["--thinking", effort.rawValue] }
        }

        let p = ShellEnvironment.makeProcess(binary, args, cwd: folder)

        // stdout/stderr go to FILES, not pipes — deliberately. A pipe ties the
        // CLI to this process: quit the app mid-run and the orphaned CLI dies
        // of SIGPIPE at its next write. A file keeps the CLI self-sufficient,
        // so the run outlives the app that spawned it; the app streams
        // progress by tailing the file instead, and after a relaunch
        // `recoverInterruptedRuns` re-attaches to the live process (or
        // harvests the result a finished one left behind). stdin stays a
        // pipe: the prompt is written and closed within seconds of the spawn.
        let inPipe = Pipe()
        p.standardInput = inPipe
        let outURL = Self.stdoutLogURL(taskID: taskID)
        let errURL = Self.stderrLogURL(taskID: taskID)
        try? FileManager.default.createDirectory(at: Self.runLogsDirectory,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        guard let outWrite = try? FileHandle(forWritingTo: outURL),
              let errWrite = try? FileHandle(forWritingTo: errURL) else {
            // No log files means no redirect, no recovery record and no output
            // parse — don't spawn a run we'd be blind to.
            let reason = Self.spawnFailureReason(engine, "run log unavailable")
            settle(taskID: taskID,
                   snapshot: AgentSnapshot(finalMessage: "", failure: reason,
                                           stderrTail: "", sawTerminal: false),
                   exitStatus: 1)
            return
        }
        p.standardOutput = outWrite
        p.standardError = errWrite

        let state: AgentEventParser = Self.makeParser(for: engine)

        // Progress streams off the growing log file — push became poll: the
        // pipe's readability handler used to feed these bytes; a quarter-second
        // tail tick now reads the same bytes through the same parser.
        let tailer = RunLogTailer(url: outURL) { [weak self] data in
            if let update = state.ingest(data) {
                Task { @MainActor in
                    self?.applyProgress(update, for: taskID)
                }
            }
        }

        // Watchdog: terminate a runaway run; cancelled on clean exit.
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: watchdog)

        p.terminationHandler = { [weak self] proc in
            watchdog.cancel()
            // Once the process exited, everything it wrote is in the file —
            // there is no kernel pipe buffer to race (the old TeardownLatch's
            // whole job). One final drain picks up the tail, result event
            // included; stderr rides in for the failure tail.
            tailer.finishAndDrain()
            Self.appendStderrFile(errURL, to: state)
            let status = proc.terminationStatus
            let snapshot = state.finish()
            Task { @MainActor in
                self?.settle(taskID: taskID, snapshot: snapshot, exitStatus: status)
            }
        }

        do {
            try p.run()
        } catch {
            tailer.finishAndDrain()
            try? outWrite.close()
            try? errWrite.close()
            // A run that never launched settles like any other failure — same
            // exchange, same Recent row. Hand-rolling the outcome here (as this
            // used to) skipped `onSettled`, so a spawn failure left no record
            // at all once its card was dismissed.
            let reason = Self.spawnFailureReason(engine, error.localizedDescription)
            settle(taskID: taskID,
                   snapshot: AgentSnapshot(finalMessage: "", failure: reason,
                                           stderrTail: "", sawTerminal: false),
                   exitStatus: 1)
            return
        }
        // The child holds its own dups of the log descriptors now; the
        // parent's copies would only leak.
        try? outWrite.close()
        try? errWrite.close()
        run.process = p
        run.pid = p.processIdentifier
        run.spawnedAt = Date()
        run.stdoutTailer = tailer
        // Remember the run is in flight — WITH its pid — so a quit/crash
        // mid-run re-attaches to the still-running process on the next launch
        // instead of writing the run off.
        Self.saveInFlight(task: tasks.first { $0.id == taskID }, currentPrompt: prompt,
                          pid: run.pid, spawnedAt: run.spawnedAt,
                          imageFiles: run.currentImageFiles)

        // The task description goes in on stdin (no arg ⇒ stdin is the prompt),
        // then the pipe closes so the agent starts working. Claude-with-images is
        // the one shape that differs: `--input-format stream-json` above means
        // stdin must be a JSONL user message, with the pasted images riding as
        // base64 vision blocks next to the task text.
        //
        // Written OFF the main thread: the payload can exceed the pipe buffer
        // (one base64 screenshot easily does), and the write then blocks until
        // the CLI drains it. The throwing `write(contentsOf:)` also turns a
        // broken pipe (a CLI that died on startup) into an ignorable error —
        // the legacy `write(_:)` raised an ObjC exception there, which took the
        // whole app down; the run's failure is already reported via settle.
        let writer = inPipe.fileHandleForWriting
        let isClaude = engine == .claude
        DispatchQueue.global(qos: .userInitiated).async {
            defer { try? writer.close() }
            let payload: Data
            if isClaude, !imagesJPEG.isEmpty {
                // Images lead and the task text closes — the order Anthropic's own
                // vision guidance recommends. Past one image, each gets an "Image N:"
                // label so the prompt (and every follow-up) can refer to them by name.
                var content: [[String: Any]] = []
                for (i, jpeg) in imagesJPEG.enumerated() {
                    if imagesJPEG.count > 1 {
                        content.append(["type": "text", "text": "Image \(i + 1):"])
                    }
                    content.append(["type": "image",
                                    "source": ["type": "base64",
                                               "media_type": "image/jpeg",
                                               "data": jpeg.base64EncodedString()]])
                }
                content.append(["type": "text", "text": prompt])
                let message: [String: Any] = [
                    "type": "user",
                    "message": ["role": "user", "content": content],
                ]
                guard var line = try? JSONSerialization.data(withJSONObject: message)
                else { return }
                line.append(Data("\n".utf8))
                payload = line
            } else {
                payload = Data(prompt.utf8)
            }
            try? writer.write(contentsOf: payload)
        }
    }
}
