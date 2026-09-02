# Engineering Challenges, Explained Simply

Building a small app that sits at the top of the screen sounds simple at first. In practice, NotchFlow connects to macOS, other apps, AI services, local developer tools, files, and system permissions. Each connection can fail, wait too long, or report incomplete information.

This page explains the important problems we had to solve in plain language.

## A few useful words first

| Word | Plain-English meaning |
| --- | --- |
| Main thread | The part of the app responsible for drawing the interface and responding to clicks and typing |
| Background queue | A separate line of work used for slow tasks so the interface does not freeze |
| Deadlock | Two things wait for each other forever, so neither can continue |
| Semaphore | A small “wait until this is ready” signal used to coordinate work |
| Process | Another program that NotchFlow starts or communicates with, such as a coding-agent CLI |
| Stream | Data that arrives gradually instead of all at once, such as a live AI response |
| TCC | macOS’s privacy-permission system for things like controlling Notes or reading Reminders |
| Notarization | Apple checking distributed software and issuing a trust ticket for it |

## 1. The Apple Notes permission deadlock

### The user-facing problem

The first time someone saves a note to Apple Notes, macOS may ask: “NotchFlow wants to control Notes.” If the app freezes while that dialog is visible, the person cannot click Allow or Don’t Allow.

### Why it happens

Apple Notes is controlled through an Apple Event, which is a request sent from one Mac app to another. Sending that request can wait until Notes responds.

The permission dialog is also handled by macOS through the main thread. If NotchFlow makes the main thread wait for Apple Notes, a bad loop can happen:

```text
NotchFlow main thread waits for Apple Notes
Apple Notes waits for the user to answer the permission dialog
The user’s click needs NotchFlow's main thread
Nothing can move forward
```

That loop is called a deadlock.

### How NotchFlow handles it

NotchFlow sends Apple Notes work to a dedicated serial background queue. “Serial” means one note operation runs at a time. The main thread stays free to draw the permission dialog and receive the user’s click. When the note operation finishes, its result returns to the interface.

The same queue also protects the AppleScript object. AppleScript objects are not safe to use from multiple threads at the same time, so one owner and one queue make their use predictable.

### Why this matters

Saving a note remains responsive even on the very first permission request. If the user declines access, the app can explain what happened instead of silently losing the text. The user can also use the local Markdown note option, which does not need Apple Notes automation.

## 2. Semaphores are used carefully

### What a semaphore does

A semaphore is like a small gate. One part of the program reaches the gate and waits until another part says, “The information you need is ready.”

NotchFlow uses `DispatchSemaphore` in a few local CLI coordination paths. For example, a short setup step may need a result from an asynchronous callback before it can finish preparing a command.

### What a semaphore must not do

A semaphore must not be used to make the main thread wait for slow work. That would make the app feel frozen and can recreate the kind of deadlock described above.

### The rule used in NotchFlow

- Use a semaphore only for a short, controlled handoff at an integration boundary.
- Never use it to wait for a user click, a macOS permission prompt, or a streaming response on the UI thread.
- Use Swift tasks, actors, background queues, and completion callbacks for work that can take an unknown amount of time.

This is why “semaphores for deadlocks” is not quite the right description. Semaphores help coordinate a few short CLI operations. The Apple Notes deadlock is avoided by keeping the main thread free.

## 3. Reading output from other programs without getting stuck

### The problem

NotchFlow talks to external programs such as coding-agent CLIs, the system media adapter, and file converters. These programs can print output gradually and sometimes print a lot of error information.

Every process has output channels. If a child program fills an output channel and the parent app does not read it, the child can stop and wait. The parent might be waiting for the child to finish. This creates another kind of stall.

### A simple example

```text
File converter writes too much error output
Its error channel becomes full
Converter pauses until someone reads it
NotchFlow waits for converter to finish
The conversion appears frozen
```

### How NotchFlow handles it

The app reads streams as they arrive rather than assuming one complete message will appear at the end. For chatty file conversions, it handles standard output and standard error safely so a full error buffer cannot block the process.

Agent and media stream parsers also expect imperfect input. A line may be incomplete, an event may be missing optional information, or a process may stop halfway through a message. The app keeps useful state when possible and reports a clear failure when it cannot continue.

### Why this matters

Long-running tasks keep showing progress instead of appearing stuck. A broken external tool produces a useful error state rather than taking down the whole notch interface.

## 4. Every AI coding tool speaks a different language

### The problem

Codex, Claude Code, Grok, Command Code, PI, and related tools are separate products. They do not all report progress in the same format. One may call an identifier a thread, another a session. One may offer a resume command, while another may only expose output. Permission requests and tool events can also arrive in different ways.

### How NotchFlow handles it

NotchFlow uses adapters. An adapter is a small translator between one external tool and the rest of the app.

Instead of making every screen understand every CLI format, an adapter translates external information into common ideas:

- What task is this?
- Which project folder is it using?
- Is it working, complete, failed, or waiting?
- What was the latest useful action?
- Can the app safely offer Open Original, follow-up, stop, or approval?

### Why this matters

The interface stays consistent even when external tools differ. More importantly, NotchFlow does not pretend an action is supported when a tool cannot reliably perform it.

## 5. Seeing an agent is different from controlling an agent

### The problem

An agent session might have been started in Terminal, outside NotchFlow. The app may be able to see its transcript or status. That does not automatically mean it can safely send commands to it.

For example, text that looks like a permission request is not enough proof that pressing Approve in NotchFlow would affect the correct terminal session.

### How NotchFlow handles it

NotchFlow separates:

- **Observed state** — information the app can see, such as a transcript or progress hint.
- **Verified control** — an action that the specific integration can route and confirm.

Approval requests pass through dedicated ownership and queue logic. The app matches them to the correct session where possible, handles expired or abandoned requests, and keeps a native fallback. If safe control is not available, it shows the state and lets the user open the original application instead.

### Why this matters

The product can be useful without claiming authority it does not have. This protects against approving the wrong command, sending a follow-up to the wrong task, or showing a button that cannot really work.

## 6. Agent tasks must survive the notch closing

### The problem

A normal AI question might finish in a few seconds. A coding task can take several minutes and may edit files, run tests, ask follow-up questions, or wait for a tool.

If a task belonged only to the visible SwiftUI panel, closing the notch could accidentally stop work. That would be surprising and could leave a project halfway through a task.

### How NotchFlow handles it

The task manager owns the process, output parser, timeout, task record, and recovery information. The visual panel only displays that state. Closing the panel detaches it from the task; it does not automatically cancel the task.

NotchFlow also keeps the important task information needed to reconnect after an app relaunch. A task can retain its prompt, project folder, session identifier, exchanges, work trail, outcome, and changed-file summary.

### Why this matters

The user can put the notch away without losing long-running work. At the same time, a short chat request and a long agent task can have different cancellation rules, which makes both behaviors feel intentional.

## 7. A GUI app does not have the same environment as Terminal

### The problem

A developer may be able to type `codex` or `claude` in Terminal, but a Mac app launched from Finder may not see the same PATH, proxy settings, shell configuration, or environment variables.

Without handling this difference, a feature can appear broken even though the CLI is installed and works perfectly in Terminal.

### How NotchFlow handles it

The CLI integration checks availability, prepares a controlled environment, and returns a setup or availability state when the command cannot be found. It does not assume every computer has one specific shell setup.

### Why this matters

Errors become understandable: “this integration is unavailable” is much better than an unexplained failed process. It also makes local CLI support more reliable across different developer machines.

## 8. The notch has unusual window and display rules

### The problem

NotchFlow is not a standard window in the middle of the screen. It is a transparent panel near the menu bar. It has to work across Spaces, full-screen apps, physical notches, virtual notches, different screen sizes, and external displays connecting or disconnecting.

Text input creates another challenge. During some languages’ input methods, macOS shows a candidate window for composing text. A notch panel above the menu bar can cover that candidate window.

### How NotchFlow handles it

The app owns one panel per selected display and identifies each display by a stable display ID. When display settings change, it compares the active screens and adjusts the panel collection.

During active marked-text composition only, the panel temporarily changes window level so the macOS candidate window remains visible. When composition ends—or if the panel closes unexpectedly—the panel returns to its normal resting level.

The SwiftUI layout also avoids fixed measurement loops. A view that measures itself, clips itself, then measures again can create a visual feedback loop. NotchFlow uses its measured geometry carefully so the notch does not jitter or lock into a bad size.

### Why this matters

The interface remains usable on multiple displays and does not break common international text input. It also avoids leaving a strange gap or incorrectly layered notch after editing.

## 9. Media is not as universal as it looks

### The problem

People expect “whatever is playing” to appear in the media area. Apple Music, Spotify, browser tabs, and other media apps do not all provide the same information or controls.

For example, a music app may remember a song long after it stopped playing, while a browser tab may be the source that was actually active a moment ago. Some sources allow seeking or next/previous controls; others do not.

### How NotchFlow handles it

NotchFlow combines dedicated Apple Music and Spotify controllers with a MediaRemote adapter for macOS system Now Playing sessions. It ranks sources by active playback and recency, while allowing the user to pin a source explicitly.

The generic Now Playing source covers browser and other system media that macOS exposes. When the media system identifies the originating application, NotchFlow can bring that player or browser forward. Controls are conditional on what the source actually supports.

### Why this matters

Automatic media selection follows the most relevant active source without hiding a browser session behind stale player metadata. The UI stays honest instead of showing controls that cannot work for a particular source.

## 10. Saving local data without losing it

### The problem

History, shelf items, task records, and settings can be written while the user is still interacting with the app. A crash or two writes happening at once can leave a half-written file or inconsistent state.

Secrets have an additional risk. API keys and credentials should not be stored like normal user preferences or committed to source control.

### How NotchFlow handles it

Local writes use ordering and atomic-file techniques where appropriate. “Atomic” means the new file is written as a complete replacement, so a crash does not normally leave a truncated half-file in its place.

Credentials use the macOS Keychain. When older stored values are migrated to Keychain, the app removes the old value only after the secure write succeeds.

### Why this matters

The app is more likely to recover cleanly from an interrupted write, and a failed migration does not turn a secret into lost data. Sensitive values do not travel with the app’s ordinary settings or source files.

## 11. Updating an app safely is a security feature

### The problem

An update is new executable software downloaded from outside the currently running application. Installing it blindly would be a security risk.

### How NotchFlow handles it

Before replacement, the updater checks the downloaded app’s signature, Gatekeeper assessment, expected team identity, bundle identifier, and version. It uses a same-volume replacement strategy and retains a rollback path if the replacement does not complete.

The updater does not remove macOS quarantine to force a launch. Apple’s trust checks remain part of the installation decision.

### Why this matters

Users receive a verified new build or keep their working old build. A failed or suspicious artifact does not simply replace the application because it had a higher version number.

## The main lessons

1. Keep the main thread free for the interface and macOS permission dialogs.
2. Treat external tools and streams as unreliable until proven otherwise.
3. Separate “we can see this” from “we can safely control this.”
4. Let long-running work belong to a durable manager, not a temporary view.
5. Prefer clear recovery options over silent failures.
6. Treat local data, credentials, and software updates as security-sensitive.

## Where to look in the code

- [`NotesService.swift`](../../NotchFlow/Sources/NotesService.swift) — Apple Notes queue and permission-deadlock handling
- [`AgentTaskService.swift`](../../NotchFlow/Sources/AgentTaskService.swift) — local task lifetime, streaming, and recovery
- [`AgentApprovalQueue.swift`](../../NotchFlow/Sources/Capabilities/AgentApprovalQueue.swift) — approval ownership and safety
- [`MediaCapabilityService.swift`](../../NotchFlow/Sources/Capabilities/MediaCapabilityService.swift) — media source selection and MediaRemote adapter
- [`NotchPanel.swift`](../../NotchFlow/Sources/NotchPanel.swift) — panel level, Spaces, and text-composition handling
- [`UpdaterService.swift`](../../NotchFlow/Sources/UpdaterService.swift) and [`UpdateArtifactVerifier.swift`](../../NotchFlow/Sources/UpdateArtifactVerifier.swift) — verified update flow
- [`KeychainStore.swift`](../../NotchFlow/Sources/Capabilities/KeychainStore.swift) — secure local credential storage
