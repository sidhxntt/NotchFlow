# Engineering Implementation Guide

This is the source-level companion to [Features](features.md). It records the
engineering path behind each feature: the state owner, the UI route to the
notch, the macOS/CLI/provider boundary, safety behavior, and verification.

## Source-to-feature map

| Capability | Implementation owner | Notch route / verification |
| --- | --- | --- |
| App shell and display lifecycle | `AppDelegate.swift`, `NotchPanel.swift`, `NotchFlowApp.swift` | `ContentView.swift`, display-placement tests |
| Interaction and visual system | `ContentView.swift`, `NotchBody.swift`, `DesignSystem.swift`, `GlassBackground.swift` | `Components.swift`, mouse/force-click policies |
| Prompt, intent, history | `NotchModel.swift`, `IntentEngine.swift`, `IntentExamples.swift` | Notch and detached session views; intent evaluation |
| Ask and AI tools | `AIService.swift`, `APIKeyStore.swift`, `AgentHarness.swift`, `AgentTools.swift` | model picker, streamed answer components, Keychain |
| Notes and reminders | `NotesService.swift`, `FileNotesService.swift`, `RemindersService.swift` | quick-capture overlays and permission recovery |
| Local coding tasks | `AgentTaskService.swift`, `AgentHarness.swift`, `*CLIService.swift` | task trail, Recent history, detached task view |
| Codex/Claude external activity | `CodexAppServerBridge.swift`, `CodexTerminalHookBridge.swift`, `ClaudeHookBridge.swift`, `Capabilities/Agent*.swift` | AI activity and approval queue tests |
| Media | `MediaCapabilityService.swift`, `NotchCapabilityStore.swift` | `NotchNowPlayingView.swift`, media tests |
| Shelf and clipboard | `Capabilities/Shelf*.swift`, `ClipboardHistoryService.swift` | shelf/clipboard views and store tests |
| Utilities and signals | `Capabilities/*Utility*.swift`, monitor/weather/audio services | utility overlays and capability tests |
| Notifications | `AlertBannerWatcher.swift`, `AlertFeedStore.swift`, `RestingNotchPriority.swift` | `ContentView.swift`, alert/priority tests |
| Product access and updates | license, Keychain, updater, installer files | settings, updater tests, release shell checks |

## App shell, display behavior, and interaction

`NotchFlowApp.swift` gives AppKit ownership to `AppDelegate`. The delegate
creates one shared `NotchModel` (interaction, prompt, history, answers, tasks)
and one shared `NotchCapabilityStore` (service-published media, utilities,
devices, shelf, and workspace policy). Every panel receives those same
instances. This is the key multi-display invariant: opening the notch on a
second screen must not create a different conversation or task list.

`AppDelegate` keys `NotchPanel` windows by `CGDirectDisplayID`, observes
screen parameter changes, applies `DisplayPlacement`, and reconciles panels
when a display appears, disappears, or changes geometry. `NotchPanel.swift`
provides the desktop behavior SwiftUI does not: transparent borderless window
chrome, window level, Spaces/full-screen collection behavior, focus, and
shape-aware hit testing. `NotchMetrics` in `DesignSystem.swift` calculates
physical and virtual notch dimensions from the selected screen.

`ContentView` builds `NotchIsland`; `NotchBody` renders the selected
workspace; `NotchModel` owns open/close, focused panel, transition, and
cancellation state. `MouseVelocityTracker` drives the entry kick, while
`HoverDwellPolicy` and `ForceClickPressurePolicy` keep dwell/pressure
thresholds as pure, independently tested rules. During input-method marked
text, the panel lowers only enough to keep a CJK candidate window visible,
then restores its normal level. The fullscreen/display-placement check prevents
an obsolete fullscreen-hiding path from returning.

`HotKey.swift` owns global hotkeys, recorded shortcut chords, double-tap
modifier monitoring, selected-text capture, and saved app shortcuts.
`ShortcutsCatalog` and `ShortcutsUtilityOverlayView` expose them in the
notch. `MenuBarController`, `SettingsView`, and `InlineSettingsView`
provide routes outside the panel. `DetachedSessionWindow` and
`HistoryArchiveWindow` own normal-window presentation while retaining the
same shared model, so a larger task/answer does not fork its data from the
notch.

`GlassBackground`, `DesignSystem`, `Components`, `ImageStack`,
`Handwriting`, `IntroAnimation`, `LucideIcons`, and `VendorLogos` form
the reusable rendering layer: Liquid Glass, notch rim/progress geometry,
type/spacing tokens, streaming Markdown, source cards, confirmation overlays,
images/lightbox, handwriting, and artwork. Features consume these components
instead of reimplementing visual state.

## Composer, local history, and explicit intent routing

`NotchModel` owns composer text, images, selected destination, answer records,
errors, cancellation, and history. `IntentEngine` is an actor that debounces
typing, uses `NLContextualEmbedding`, scores a small logistic head plus nearby
labeled examples from `IntentExamples.swift`, and caches trained weights by
embedding-model identity. A model change causes retraining rather than reuse of
incompatible weights. When the model is unavailable or uncertain, it returns an
ambiguous suggestion—not a guessed side effect.

The visible Ask, Note, Remind, and Agent destination in `NotchBody` remains
the authority. A suggestion cannot send text, create a note/reminder, or start
an agent. `ConversationStore` serializes local records, stores attachments in
managed history storage, and preserves only valid agent resume metadata.
`Components` parses partial and complete Markdown streams, code, math, source
badges, media previews, and tail text; full events reconcile provisional text.
`scripts/intent_eval` and the fixture/test suite make classifier behavior
repeatable.

## Ask: direct providers, local models, images, and tools

`AIService.swift` defines common messages, images, stream events/retries,
provider specifications, model metadata, and direct streaming services.
`OpenAICompatAIService` supports OpenAI-style endpoints (including a chosen
local endpoint); `AnthropicAIService` implements Anthropic's stream contract.
`ModelPickerView` handles available models, recent-model MRUs, agent model
choices, and project-folder MRUs rather than leaving those persistence details
in an HTTP service.

`APIKeyStore` and `Capabilities/KeychainStore` are the secret boundary. Keys
are read from Keychain, never stored in SwiftUI state or release artifacts; a
legacy value is removed only after secure migration succeeds. `OpenRouterAuth`
owns provider browser authorization; `ProxyConfig` and `ShellEnvironment`
centralize network/process configuration.

`AgentHarness` normalizes messages, tool calls, tool results, and web sources.
`AgentTools` implements date/time, arithmetic, clipboard read, capability
inspection, link opening, ask-user, settings change, note/reminder creation,
history search, web search, and page reading. Search providers (Kimi, GLM,
Exa, Keenable, AnySearch) are isolated behind `SearchProvider`; an intentional
search is the only request sent to the selected service. `TokenMeter`,
`AppSupportPaths`, `StatsPane`, and `DiagnosticsLog` provide local usage
and diagnostic records, not a NotchFlow data relay.

## Notes, Markdown files, and Reminders

`NotesService` serializes AppleScript work on a dedicated queue and passes
typed text as an Apple Event parameter to a named script handler. It never
interpolates typed text into script source, so quotes/newlines cannot become
AppleScript syntax. The queue keeps the main actor free while the first
Automation request may be showing a TCC dialog, preventing a permission
deadlock. `NotesError` lets the UI show a specific recovery state.

`FileNotesService` defines `NoteDestination` and the local Markdown fallback.
`RemindersService` uses EventKit's async authorization/create path and exposes
typed failure reasons. `QuickNoteStore`, `QuickReminderStore`, and their
overlays reuse those services from Utilities instead of creating a separate
write implementation.

## Agent tasks: process ownership and engine-specific contracts

`AgentTaskManager` in `AgentTaskService.swift` owns task records, `RunState`,
processes, parsed logs, diffs/todos, session IDs, follow-ups, cancellation, and
recovery. Every initial/resumed round receives a new `RunState`, so parallel
tasks cannot collide on parser offsets, temporary images, or a process handle.
Child stdout/stderr are written to managed files and tailed by the manager.
That avoids SIGPIPE if the app closes; relaunch recovery can reattach to a live
process or collect a completed result. Images and prompt files live outside the
chosen project and are cleaned on settlement.

| Engine | Initial launch policy | Session and approval behavior |
| --- | --- | --- |
| Codex | `exec --json`, selected cwd, workspace-write sandbox, optional model/effort/images | `exec resume`; JSON becomes the work trail. App-server turns can receive in-notch callbacks. |
| Claude Code | prompt/verbose stream JSON plus partial messages, explicit `acceptEdits`, selected allowed tools | `--resume`; generated per-launch settings route gated tools to the hook bridge. |
| Grok | prompt file, streaming JSON, selected cwd, no interactive plan/auto-update | `--resume`; end event yields the session handle. |
| Command Code | JSON prompt mode plus headless trust/onboarding configuration | `--resume`; `run_start` supplies the reusable session. |
| PI | JSON prompt mode, deliberate project approval, offline startup | `--session`; initial session header supplies the continuation key. |

The adapters in `CodexCLIService`, `ClaudeCLIService`, `GrokCLIService`,
`CommandCodeCLIService`, and `PiCLIService` parse each vendor's real event
dialect. `AgentEngine.resumeCommand`, manager `followUp`/`resume`, task
trail components, and Recent history preserve only options supported by that
engine. `open original` is the fallback when NotchFlow cannot safely send an
action.

## How Codex and Claude approvals are routed into the notch

The approval layer never turns transcript text into authority.
`AgentApprovalQueue` keeps a FIFO queue per verified session, and
`AgentSessionActivityStore` groups it under the session root. Cards disappear
when their callback transport closes. Transcript observation can show work and
offer a native handoff, but cannot manufacture Approve/Deny controls.

### NotchFlow-launched Codex: app-server JSON-RPC

`CodexAppServerBridge` starts `codex app-server --stdio` once, retains the
JSON-RPC connection, initializes it, and starts a thread with the chosen cwd,
`approvalPolicy: on-request`, and `approvalsReviewer: user`. It then sends
the turn prompt. Callback IDs, the originating method, and requested permission
profile are retained with each queue item. When the person clicks Allow/Deny,
`decide` writes the response on that same connection. Different Codex approval
methods have different response shapes, so a permission profile is echoed as
requested rather than replaced with a broader grant. A terminal session is
never impersonated through this private connection.

### Terminal Codex: additive hook wiring

`CodexTerminalHookBridge.startIfNeeded` writes a narrowly managed Python hook
in the user's Codex configuration area, creates a per-user Unix listener, and
merges only NotchFlow groups into `hooks.json`. It installs `PermissionRequest`
as the hook's `gate` command and `Stop`/`UserPromptSubmit` as `clear`
commands to remove stale state. The merge is idempotent, preserves other tools'
hooks, removes invalid `null` hook entries that would invalidate the whole
config, and writes atomically. The hook sends a structured request over the
socket; the bridge stores the live connection by approval ID; the notch action
replies on the same connection.

The hook configuration makes re-routing automatic on app launch, but Codex's
own hook-trust acceptance remains a deliberate user action. NotchFlow does not
write a trust cache or bypass `/hooks`. It scans for stale NotchFlow hook paths,
offers an explicit backed-up repair, and leaves unfamiliar commands for review.
If the listener is unavailable, the product becomes blocked, or a hook times
out, the hook emits no decision and Codex retains its normal terminal prompt.

### Claude Code: generated per-launch PreToolUse settings

`ClaudeHookBridge` writes an app-owned hook script and settings JSON in managed
application support, opens a Unix socket, and returns `--settings` only to a
NotchFlow-launched Claude process. It does not overwrite the user's global
Claude settings. `AgentTaskManager` adds that argument on initial and resumed
launches because `--resume` does not carry flags forward.

The generated `PreToolUse` hook gates Bash, Edit, Write, NotebookEdit, and
other state-changing/external calls. Reads inside the selected project are
allowed immediately to avoid approval fatigue; reads outside the project—or
without enough cwd/path evidence—become a card. Each hook process waits on its
own socket connection. The bridge queues it by session, sends Allow/Deny only
after a click, and withdraws it if the connection ends. It fails open: no
listener means no injected settings; a timeout produces no override, leaving
Claude Code's ordinary permission model in charge.

`AgentTranscriptFiles` discovers recent Codex/Claude JSONL files and
`AgentTranscriptStatus` derives structured activity, session, plan, and usage
state. The manager merges that slower observation with callbacks;
`AIActivityMonitorView` renders it. Queue, transcript, and bridge behavior is
exercised by `CodexApprovalQueueTests`, `ClaudeApprovalQueueTests`,
agent-session/transcript tests, and `Tests/verify_approval_bridges.sh`.

## Media, shelf, clipboard, and notifications

`MediaCapabilityService` normalizes direct Apple Music/Spotify AppleScript
controllers and the bundled `MediaRemoteAdapterController` into `MediaState`.
The adapter receives macOS system Now Playing events, allowing eligible browser
and other sessions without inventing site-specific browser controls. The service
polls at active/idle intervals, retains bounded artwork, and selects an explicit
pin first, then active playback and recency. This prevents stale Music metadata
from out-ranking a playing browser tab.

The MediaRemote payload carries the originating bundle identifier.
`MediaState.launchTarget` prefers it, and `NotchCapabilityStore.launchMedia`
foregrounds that browser/player before a source fallback. `NotchNowPlayingView`
only shows capability-appropriate commands; seek is routed through MediaRemote.
Ranking and browser-origin behavior have focused media/store tests.

The adapter is deliberately a bundled, versioned dependency rather than an
assumption about a developer machine. Its upstream source and license live in
`Vendor/MediaRemoteAdapter`; the built framework and adapter script are app
resources under `NotchFlow/Resources`; project resource entries copy both into
the application bundle. `scripts/codesign-app.sh` and `scripts/build_and_run.sh`
sign nested framework code before sealing the outer app. This makes the browser
seek/open-original path available in a release artifact as well as `make dev`.

`ShelfDropService` accepts drops and opens the shelf; `ShelfItem` is the
stable item contract; `ShelfPersistenceService` writes/restores local shelf
records; `NotchShelfView` renders handoff. `FileConversionService` manages
supported conversion processes and safely drains output. `ClipboardHistoryService`
is opt-in, polls `NSPasteboard` changes at a paced interval, ignores concealed,
transient, and autogenerated types, and resets its change baseline after a
restore. `ClipboardHistoryStore` manages limits, dedupe, pinning, removal, and
local persistence; the overlay only presents that data.

`AlertBannerWatcher` observes Notification Center banner windows and uses
`AlertBannerText` to normalize presentation text. `AlertFeedStore`
deduplicates bursts and produces short-lived announcements. `SustainedAlertGate`
avoids a transient steal; `RestingNotchPriority` resolves media, agent, device,
notification, and utility competition; `ContentView` renders the winner as an
overlay above working/planning state. Alert/feed/gate/priority tests keep the
policy deterministic.

## Utilities and desktop signals

`NotchUtilitiesView`, `NotchQuickUtilitiesView`, and `NotchUtilityOverlay`
present state from `NotchCapabilityStore`. Quick actions are Pomodoro, quick
note, reminder, power, devices, clipboard, and shortcuts. Focused overlays
separate UI from the long-lived service that owns timers/native handles.

`SystemUtilityService` owns IOKit keep-awake assertions, a timed
`KeepAwakePlan`, display sleep/screensaver, brightness, battery, and audio
output routes. Its process-owned assertion is released if the app exits.
`AudioDeviceCapabilityService` uses CoreAudio and `AccessoryConnectionSettler`
to coalesce noisy connect/disconnect transitions. `FocusTimerStore` owns phase,
deadline, ticker, and local streak state; the ring uses the same timer state.
`WeatherService` owns unit preference, location authorization/provider, refresh
policy, and a presentable `WeatherSnapshot`.

`SystemMonitorService` samples host CPU tick deltas, memory pressure, process
count, disk/memory information, and bounded history only while its UI is
visible. It labels a derived pressure curve honestly and does not fake a
privileged system-wide thread count. `ActivityMonitorView` and `StatsPane`
render the readings. `WindowLayoutPlanner`/history make layout actions
inspectable; `URLCleaningService` removes known tracking parameters without
fetching; `MeetingLink` recognizes meeting URLs; `TextSnippetStore` saves
text. `UtilitySettingsBackup` validates backup/restore values.
`UtilityProcessPolicy` constrains child utilities. `UtilityFeatureRegistry`
is a policy catalogue of optional features, their permissions, and confirmation
requirements—not a claim that every catalogue entry is enabled on every Mac.

The capability-test families for monitor, system utility, weather, audio,
window layout, URL cleaning, snippets, registry, process policy, backup, focus
timer, and power/quick utility layouts validate the pure logic behind these
routes.

## Settings, licensing, privacy, updates, and release integrity

`SettingsView` and `InlineSettingsView` expose typed policies for display,
hover, dock/icon, launch-at-login, providers, utilities, licenses, and notices.
`OnboardingService` tracks setup progress without storing keys. Generic versus
Agentic workspace policy is owned by `NotchCapabilityStore`: disabling the
agentic surface returns an agent-only tab to a safe workspace, closes bridge
transport, clears approval cards, and lets native tools fail open.

`LicenseService` and `LicensingConfiguration` implement the trial,
activation, entitlement refresh, developer-build exception, and blocked state.
Product services check this state before starting. `KeychainStore` is used for
secrets and durable sensitive values; `AppSupportPaths` supplies managed local
paths. No NotchFlow-operated user-data backend is involved: prompts go directly
to a selected provider, search to a selected search provider, and tasks to a
local CLI. `DiagnosticsLog` is local. The Privacy Policy and focused
license/store tests record user-control and edge-case contracts.

`UpdaterService` fetches release metadata. `UpdateArtifactVerifier` validates
a downloaded app's signature, Gatekeeper assessment, expected team, bundle ID,
and version before it is eligible. `UpdateInstallPlanner` makes a same-volume
replacement/rollback plan so the prior app survives until replacement works.
Updater/planner tests and `verify_updater_artifact_safety.sh` exercise that
boundary.

`Makefile` and `scripts/build_and_run.sh` provide the local loop: build
Debug, re-sign nested code/outer bundle with a stable designated requirement,
copy to the user's Applications directory, register it, and launch it. That
stable requirement prevents TCC from treating each rebuild as a distinct app.
`scripts/codesign-app.sh` supplies local signing. TCC identity, make-dev,
development-install-location, menu-bar, and approval-bridge checks verify a
usable development launch.

Release differs deliberately: DMG/ZIP scripts package the signed product; the
release workflow imports Developer ID material into a temporary CI keychain,
signs nested code with hardened runtime/timestamps, notarizes and staples, then
mounts/extracts and verifies final artifacts before GitHub publication.
`auto-release-tag.yml` derives semantic versions from Conventional Commits;
pull-request validation, package, release-metadata, version, DMG, ZIP, signing,
and identity shell checks guard the pipeline. `WhatsNewService` is the curated
in-app release-note source; `scripts/gen-releases.mjs` creates `CHANGELOG.md`.

## Verification map

The Wiki is not a substitute for tests. The following source-level checks are
the evidence that the contracts described above remain executable:

| Area | Tests and checks |
| --- | --- |
| Agent state and external observation | `AgentSessionStateTests`, `AgentTranscriptFilesTests`, `AgentTranscriptStatusTests`, `CodexApprovalQueueTests`, `ClaudeApprovalQueueTests`, `verify_approval_bridges.sh` |
| Capability state and policy | `AboutContentConfigurationTests`, `AlertBannerTextTests`, `AlertFeedStoreTests`, `ForceClickPressurePolicyTests`, `HoverDwellPolicyTests`, `MediaCapabilityServiceRankingTests`, `NotchCapabilityStoreTests`, `RestingNotchPriorityTests`, `SustainedAlertGateTests`, `SettingsPolicyTests` |
| Local storage and utilities | Clipboard store/service, command query, file conversion, meeting-link, snippets, URL-cleaning, utility registry/process/backup, weather, window-layout, system-monitor, and system-utility test suites |
| Product gate and updates | `LicenseServiceTests`, updater artifact/install tests, `verify_install_artifact_safety.sh`, `verify_updater_artifact_safety.sh` |
| Notch presentation and local run | menu-bar icon/about, force-click layout, power layout, fullscreen/display placement, accessibility refresh, make-dev entrypoint/readiness, TCC identity, and development-install-location checks |
| Distribution | signing, identity, release metadata, next-version, conventional-commit, DMG, ZIP, GitHub icon, intro, and English-only checks |

`swift test` runs the capability suites. The shell scripts are intentionally
small contract checks for generated artifacts, visual/layout source invariants,
launch readiness, packaging, and workflow metadata. CI invokes the relevant
release and pull-request checks, while the local development command verifies
that the app can actually start and accept its approval bridge connections.

## Documentation rule for future features

Every new feature should add four facts here or in its focused Wiki page: the
user action and state model; the service/native/process boundary; permission,
confirmation, fallback, and failure behavior; and the test or release
verification that protects it. That keeps the Wiki an engineering record of
what happens after a person clicks a notch control.
