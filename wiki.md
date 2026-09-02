# NotchFlow GitHub Wiki — Page Map

The complete GitHub Wiki source is maintained under [`docs/wiki/`](docs/wiki/index.md). Publish it into GitHub’s separate Wiki repository with [the publishing guide](docs/wiki-publishing.md).

| Source page | GitHub Wiki page |
| --- | --- |
| [`docs/wiki/index.md`](docs/wiki/index.md) | Home |
| [`docs/wiki/overview.md`](docs/wiki/overview.md) | Product overview |
| [`docs/wiki/features.md`](docs/wiki/features.md) | Features |
| [`docs/wiki/audience.md`](docs/wiki/audience.md) | Who NotchFlow is for |
| [`docs/wiki/modes.md`](docs/wiki/modes.md) | Generic mode and agentic mode |
| [`docs/wiki/architecture.md`](docs/wiki/architecture.md) | Architecture |
| [`docs/wiki/technology-stack.md`](docs/wiki/technology-stack.md) | Technology stack |
| [`docs/wiki/engineering-challenges.md`](docs/wiki/engineering-challenges.md) | Engineering challenges |
| [`docs/wiki/privacy-and-permissions.md`](docs/wiki/privacy-and-permissions.md) | Privacy and permissions |
| [`docs/wiki/release-distribution.md`](docs/wiki/release-distribution.md) | Release, signing, notarization, DMG, and ZIP delivery |
| [`docs/wiki/updates-and-versioning.md`](docs/wiki/updates-and-versioning.md) | Updates and versioning |
| [`docs/wiki/development.md`](docs/wiki/development.md) | Development |
| [`docs/wiki/faq.md`](docs/wiki/faq.md) | Frequently asked questions |

## What is NotchFlow?

NotchFlow is a direct-download macOS app that turns the display notch into a compact place to capture information, control common tasks, ask an AI question, and follow local coding-agent work. It is intended to reduce the small but repeated context switches between Terminal, Finder, Notes, Reminders, browsers, media applications, and project folders.

The notch is an entry point, not a replacement for those applications. A note remains in Apple Notes or a local Markdown file. A reminder remains in Apple Reminders. An agent runs through the local CLI and project folder chosen by the user. NotchFlow gives those actions a shared, low-friction surface and a reliable way to return to the originating app.

## What can it do?

### Capture and ask

The composer supports four visible destinations: Ask, Note, Remind, and Agent. It can suggest an intent while the user types, but it does not silently send text to a provider, write a note, create a reminder, or launch an agent. The user can always select the final destination before submission.

Ask streams an answer from a configured AI provider, an OpenAI-compatible endpoint, or a supported locally signed-in CLI. The conversation can be stored locally, copied, or reopened. Notes can be created in Apple Notes or saved to a Markdown destination. Reminders use the native macOS integration and expose permission-aware recovery when needed.

### Agent work

Agentic mode can launch a coding task in a project folder selected by the user, track its progress, retain its work trail, accept supported follow-ups, and recover interrupted task records. The agent layer supports locally installed CLI integrations rather than routing work through a NotchFlow service. It can also observe supported sessions that began elsewhere, while keeping observed status distinct from verified control authority.

### Everyday utilities

The non-agent experience includes media controls, a file tray for dropped files, clipboard context, utilities, activity signals, and display-aware notch panels. The Automatic media setting follows an eligible active media source. Apple Music and Spotify can be selected directly; browser and other system media appear as the generic system Now Playing source when macOS exposes them.

## Who is it for?

NotchFlow is especially useful for AI-assisted developers who want to know whether a local agent is working, waiting, completed, or needs attention without constantly foregrounding Terminal. It is also useful for knowledge workers who need to capture a sentence, create a reminder, ask a short question, or keep temporary files and playback close without breaking concentration.

It is not aimed at teams needing a shared cloud workspace, people who need Windows or Linux support, or users seeking an unsupervised autonomous computer-use agent. The product works best for Apple-silicon macOS users who value local storage and are comfortable bringing their own AI provider access or local CLI sign-in.

## Generic mode versus agentic mode

| Area | Generic mode | Agentic mode |
| --- | --- | --- |
| Goal | Calm desktop companion | AI and local-development command surface |
| Available workspaces | Media, Utilities, Activity Monitor | Everything in generic mode plus Chat, Agent, and AI Activity Monitor |
| AI chat and agent tasks | Hidden | Available when configured |
| Local CLI task control | Disabled | Available only for supported, healthy integrations |
| Media, files, and utilities | Available | Available |
| Authority model | No agent control layer | Explicit, capability-aware approvals and actions |

Generic mode is deliberate, not a failure state. It lets someone use NotchFlow as a media-and-utilities companion without exposing chat and agent surfaces. Agentic mode adds the local AI workflow, but it does not grant an agent blanket permission: a control is shown only when the relevant integration can identify, route, and confirm it safely.

## Architecture

```text
AppDelegate
  ├─ one AppKit NotchPanel per selected display
  ├─ one shared NotchModel for prompts, history, and interaction
  └─ one shared NotchCapabilityStore for service-published state

SwiftUI interface
  ├─ resting notch, quick strip, and expanded workspaces
  └─ media, utilities, file tray, chat, activity, and agent views

Service layer
  ├─ intent, Notes, Reminders, media, files, utilities, licensing, and updates
  ├─ direct provider and local-CLI AI services
  └─ agent manager, stream parsers, transcript observers, and approval bridges
```

`AppDelegate` owns panels keyed by display identity and reconciles them when displays are added, removed, resized, or selected in Settings. The panels share a single app model, so moving between displays does not create separate conversations or separate agent state. `NotchPanel` supplies the AppKit-level behavior required for a transparent, borderless overlay that follows Spaces and full-screen apps.

`NotchModel` owns the interactive story: prompt submission, visible transitions, local history, task presentation, confirmations, and cancellation. `NotchCapabilityStore` is the bridge for service-published state such as media, devices, activity, shelf items, workspace selection, and the agentic-mode policy. This separation prevents service code from mutating views directly and keeps UI changes on the main actor.

The intent engine is an actor that uses an on-device NaturalLanguage embedding and a small locally trained classifier. The agent manager owns long-running local processes independently of a transient SwiftUI view. The updater verifies a downloaded artifact before performing a recoverable app-bundle replacement.

## Engineering challenges and solutions

### TCC prompts, blocking calls, and deadlocks

Apple Notes Automation uses a synchronous Apple Event. The first attempt can trigger a TCC permission dialog that requires the main run loop to process the user’s click. If the app waited for AppleScript on the main thread, the script would wait for the user and the user interaction would wait for the main thread: a deadlock. NotchFlow runs AppleScript on a dedicated serial background queue and returns outcomes to the main actor.

### Semaphores and concurrency

`DispatchSemaphore` is used only in narrow local-CLI coordination paths where a short command setup must wait for an asynchronous result. It is not used as a UI waiting mechanism or as the Notes deadlock solution. UI state is protected through actor isolation, tasks, cancellation rules, serial queues, and explicit return-to-main updates.

### Streaming subprocesses

Agent CLIs, media adapters, and file conversion processes can emit partial records, malformed lines, or enough stderr to block a child process. NotchFlow treats output as a long-lived stream, handles partial/malformed events, supports cancellation, and drains output safely. For chatty converters, stdout and stderr are managed so a full error pipe cannot stall the process.

### Agent diversity and safe authority

Different local agents use different stream formats, session identifiers, hooks, resume behavior, and approval contracts. NotchFlow normalizes their state through adapters, but does not pretend every agent supports every action. Observed activity can be displayed; a sensitive command is exposed only if the app can safely route and acknowledge it. Otherwise, Open Original returns the user to the native tool.

### Process lifetime and recovery

Closing the notch must not accidentally cancel a project task that can run for minutes. Long-running tasks are owned by the task manager, retain their work trails and session information, and can be reattached after a relaunch. Short chat requests and long agent tasks therefore have intentionally different cancellation and persistence behavior.

### Display and input-method behavior

The notch has to coexist with menu bars, full-screen spaces, physical and virtual notch geometry, scale changes, and displays connecting or disconnecting. Input methods add a second window-level problem: a CJK candidate window needs to remain visible during marked-text composition. The panel adjusts its level only during that composition, then restores the notch to avoid persistent visual artifacts.

### Media ranking

Player apps can retain old metadata after playback stops, while a browser may have the most recently active session. Automatic source selection considers active playback and recency, while explicit pins override the automatic choice. The generic Now Playing source supports browser and other system media without falsely promising a site-specific browser filter or universal playback commands.

### Secure local data and updates

Credentials are stored in Keychain, with migration ordered so an old value is removed only after a secure write succeeds. Local histories use ordered or atomic persistence to reduce corruption risk. Updates are treated as untrusted executable bundles until their signature, Gatekeeper assessment, team identity, bundle identifier, and version are verified; installation retains a rollback route.

## Privacy and permissions

NotchFlow has no separate product account or NotchFlow-operated user-data backend. Chats, history, shelf records, notes, reminders, and agent activity remain local unless a user deliberately sends a prompt to a selected provider, invokes a search provider, or runs a local CLI that has its own configured services.

Provider and search credentials use macOS Keychain. Apple Notes, Reminders, notifications, media, and related features request or use the relevant macOS access only when needed. Permission denial produces a focused recovery path or local fallback where one exists—for example, Markdown note saving instead of Apple Notes Automation.

## Release, DMG, ZIP, and in-app updates

A non-`web/` Conventional Commit merged into protected `main` triggers the automatic release tagger. It calculates the next semantic `vX.Y.Z` tag, then starts the Release workflow. That workflow builds the arm64 app, imports a Developer ID Application certificate into a temporary keychain, signs nested code with hardened runtime and a secure timestamp, verifies the identity and versions, and submits the artifact to Apple’s notarization service.

The app is stapled after notarization, then packaged as the primary DMG. The DMG is notarized and stapled as well. A ZIP fallback is created from the already-stapled app because a ZIP archive itself cannot receive a stapled ticket. Both artifacts are mounted or extracted and revalidated before GitHub publishes the Release.

Users always update to the newest complete published build; they do not install missed versions sequentially. The in-app updater checks the release feed, verifies the downloaded update before replacement, preserves the previous bundle until the transaction succeeds, and relaunches the new version. Full certificate, Apple portal, GitHub secret, notarization, packaging, and troubleshooting steps are in [`docs/wiki/release-distribution.md`](docs/wiki/release-distribution.md).
