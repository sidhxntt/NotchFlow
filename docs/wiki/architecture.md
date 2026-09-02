# Architecture

## System map

```text
AppDelegate
  ├─ NotchPanel per selected display
  ├─ NotchModel: interaction, prompt, history, and AI state
  ├─ NotchCapabilityStore: service state presented to the UI
  └─ Settings and product services

SwiftUI notch views
  ├─ Resting notch, quick strip, and expanded workspace
  ├─ Media, file tray, utilities, activity, chat, and agent views
  └─ Detached windows where a task needs more room

Service layer
  ├─ Intent, notes, reminders, media, files, utilities, and updates
  ├─ Hosted-provider and local-CLI AI services
  └─ Agent task manager, adapters, hooks, and transcript observers

macOS and external systems
  ├─ AppKit panels, Apple Events, EventKit, notifications, Keychain
  ├─ MediaRemote and originating applications
  ├─ Configured AI providers and search providers
  └─ Locally installed agent CLIs
```

## App shell and display lifecycle

`AppDelegate` owns the live notch panels. Panels are keyed by `CGDirectDisplayID`, so display additions, removals, resolution changes, and user display-placement settings can be reconciled without creating separate application state for each screen.

`NotchPanel` provides the AppKit window behavior. SwiftUI supplies the rest of the visual hierarchy. All panels share one `NotchModel`; that model records which display currently owns the open island.

The panel is deliberately unlike a normal document window. It is borderless, transparent, floating, and able to join Spaces and accompany full-screen applications. It normally stays at the status-bar level so the notch sits above ordinary windows. During an active input-method composition, such as a CJK candidate selection, it temporarily moves below the candidate window; this avoids covering the system’s text-composition UI while not lowering the notch for ordinary typing.

Display changes are treated as lifecycle events. The app receives screen-parameter notifications, compares display metrics, creates panels where the placement policy requires them, and removes panels for displays that disappeared. A shared model prevents separate conversation histories or disconnected task state on each screen.

## State boundaries

| Component | Responsibility |
| --- | --- |
| `NotchModel` | Prompt lifecycle, view interaction, conversations, history, and user-facing outcomes |
| `NotchCapabilityStore` | Immutable service-published state for media, shelf items, devices, activity, and workspace policy |
| `AgentTaskManager` | Local task lifecycle, command adapters, streaming output, and recovery |
| `AIService` implementations | Provider-specific or CLI-specific request and stream behavior |
| Capability services | Narrow macOS integration boundaries for media, files, utilities, licensing, updates, and more |

The UI runs on the main actor. Services publish state through defined store boundaries instead of mutating views directly.

### Why there are two central state objects

`NotchModel` owns the interactive product story: whether the island is open, the active prompt, answer and task presentation, recent history, confirmations, and cancellation. `NotchCapabilityStore` represents current capability state supplied by focused services: media state, accessory state, system activity, files on the shelf, the selected workspace, and the agentic-mode policy.

Keeping those responsibilities separate limits coupling. A media refresh can update the shelf of system signals without rebuilding the prompt lifecycle. A UI transition can change without taking ownership of an Apple Event, a media process, or an updater transaction. This also makes it clearer which work has to return to the main actor and which work belongs on a service queue or Swift task.

## Intent and execution flow

```text
User input
  → IntentEngine suggestion
  → Visible user-selected destination
  → Ask / Note / Remind / Agent execution
  → Receipt, history entry, native-app target, or streamed result
```

Intent classification is assistive. A user can select the final destination rather than silently sending text to a provider, Notes, Reminders, or an agent.

### Intent implementation

The intent engine is an actor. It uses `NLContextualEmbedding` to embed English input locally, then evaluates a small logistic classifier and a nearby-example signal trained from bundled examples. The learned data is cached against the identity of the embedding model, so an operating-system model change can trigger retraining rather than reuse incompatible cached weights. A system Foundation Model, where available, is only a low-confidence second opinion; it is not required for the normal typing path.

Classification is debounced and cached. This keeps the composer responsive while a user edits, deletes, or cycles input-method candidates. If the model is unavailable or still preparing, the UI gets an ambiguous reading and uses its ordinary safe default rather than blocking input.

## AI and agent integrations

Hosted providers use direct requests with credentials held in Keychain. OpenAI-compatible endpoints can include local deployments. Local CLI services use the user’s already installed and authenticated tools where supported.

The agent layer normalizes different stream formats, session identifiers, project context, tool events, and terminal hooks into the state consumed by the UI. It keeps task ownership outside a single view, so closing the notch does not necessarily destroy a running task.

### Ask versus Agent

An Ask is optimized for a short, isolated response. It can use a configured HTTP provider or a CLI-backed service, and it should not need write access to a user workspace. An Agent task is a longer-running local process with a user-selected folder and a deliberate task prompt. For example, the Codex task path uses the CLI’s workspace-write mode in that folder while the chat path remains isolated and read-only.

The difference matters operationally. Agent tasks can outlive the notch panel because their process ownership, output, task record, and recovery marker live in the task manager. Task output can be written to files and reattached after relaunch. A task has its own parser, process, timeout, exchanges, work trail, changed-file summary, and cleanup path; parallel tasks do not share a mutable process object.

### Session observation and approval bridging

Some sessions begin outside NotchFlow. Transcript watchers and hook bridges can identify them and provide status, but the UI keeps verified state separate from inferred information. Approval requests are resolved through a dedicated queue and bridge with ownership rules, so a transient tool hook cannot accidentally attach to the wrong task or grant an action merely because text looked like a permission prompt.

## System integrations

- Apple Events for Apple Notes
- EventKit for Reminders
- AppKit, Screen APIs, and Accessibility-aware interaction surfaces
- MediaRemote adapter for system Now Playing sessions
- File-system services for shelf items, Markdown notes, conversion, and local history
- Keychain for secrets
- GitHub Release metadata and verified artifacts for update delivery

### Media architecture

`MediaCapabilityService` aggregates controllers for Apple Music, Spotify, and a bundled MediaRemote adapter. Each controller returns a common `MediaState`; the service chooses a current state based on explicit source pinning, active playback, and recency. Dedicated player metadata is not allowed to permanently outrank a recently active browser tab merely because a player application still remembers an old track.

The MediaRemote adapter turns macOS system Now Playing events into decodable payloads. It supplies generic browser and other media sessions, artwork where available, and the originating application bundle identifier. Commands remain best-effort and capability-aware: browser volume is not exposed through the adapter, for example, and a UI control must not imply universal player support.

### Notes, reminders, files, and storage

Apple Notes calls are serialized behind an AppleScript service. User text is sent as an Apple Event parameter to a named script handler rather than interpolated into script source. Reminders use native asynchronous access. File-oriented notes and shelf data use local filesystem services; writes and archive updates have ordered or atomic handling so a partial write cannot silently corrupt history.

### Updates and licensing

The updater discovers a newer GitHub Release, downloads the expected artifact, and passes it through artifact verification before attempting installation. The licensing service, product gating, and secure value store remain separate from the update mechanism. The secure value boundary uses macOS Keychain rather than a plain preferences value for provider keys and related secrets.

## Distribution architecture

The [release workflow](release-distribution.md) builds an arm64 app, signs it with a Developer ID Application identity, notarizes it, produces DMG and ZIP deliverables, validates them, and publishes a GitHub Release. The in-app updater verifies the identity, bundle identifier, versions, and update artifact before replacement.

## Failure and recovery design

NotchFlow prefers a specific recovery route over a generic failure. A denied Notes Automation request leads to a permission explanation; an unavailable player can preserve the media state and report the command failure separately; a provider or CLI integration can surface setup guidance; an interrupted agent can be recovered or opened in its native context. The updater retains the old installed bundle until its same-volume replacement succeeds and can roll back a failed replacement.
