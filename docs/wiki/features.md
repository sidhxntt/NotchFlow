# Features

## Smart capture and assistant

- Automatic intent suggestions for Ask, Note, Reminder, and Agent tasks
- Manual intent selection before submission
- Streaming answers, local conversation history, and copy/reopen actions
- Bring-your-own-key support for hosted and OpenAI-compatible endpoints
- Signed-in local CLI options for supported agent providers
- Web search, link opening, exact arithmetic, and settings actions where configured

### Ask

Ask is for quick answers that fit naturally in the notch. Responses stream into the interface, can be retained in local history, and can be reopened or copied. A configured hosted provider receives the prompt directly; an OpenAI-compatible endpoint may be a local model server. When the selected backend is a local signed-in CLI, authentication remains with that CLI instead of being copied into NotchFlow.

### Intent suggestions

The composer can recognize whether text reads more like a question or a capture. This keeps common tasks fast without silently changing their destination. The suggestion is visible, editable, and designed to degrade safely when on-device classification is not ready or is uncertain.

## Notes and reminders

- Save to Apple Notes
- Fallback to user-selected Markdown files
- Open the originating note after saving
- Create Apple Reminders
- Permission-aware error and recovery states

Apple Notes integration uses a parameterized Apple Event rather than placing typed text inside AppleScript source. This protects quotes, line breaks, and other user input from becoming script syntax. If Automation access is unavailable, the user sees a useful recovery state. Markdown notes provide a local file-based path that does not require Apple Notes automation.

Reminder creation uses the native Reminders framework. The product keeps capture and confirmation close together so a quick instruction can become an actionable reminder without forcing the user into the full Reminders application.

## Agent work

- Launch tasks in a chosen project folder
- Codex, Claude Code, Grok, Command Code, PI, and supported local CLI integrations
- Stream progress and retain task history
- Follow-up instructions and supported session continuation
- Observe supported externally started sessions
- Explicit approval, deny, stop, and open-original actions when safely supported
- Recover interrupted local runs and preserve outcomes

### Two kinds of agent visibility

NotchFlow distinguishes a task it launched from activity it observed elsewhere. A launched task has an explicit project folder, prompt, engine, lifecycle, and record in NotchFlow. An observed session may be visible through a supported local transcript or hook path, but observation alone does not manufacture authority to approve tools or send commands.

### Local task execution

Agent work is intentionally different from a short assistant response. A task may run for minutes, edit files in the selected workspace, emit a long stream of tool activity, and survive the notch being closed. The task manager, not a SwiftUI view, owns the process and its recovery information. Users can see progress, open the original context, send a supported follow-up, or stop work with the appropriate confirmation.

## Everyday workspace

- System Now Playing, including supported browser media
- Apple Music and Spotify source selection
- Playback controls, seeking where the source supports it, and open-original actions
- File tray for dropped files
- Clipboard context and quick utilities
- System activity, audio-device, and accessory signals
- Multi-display virtual-notch support

### Media behavior

Automatic media selection follows the strongest eligible currently active source. Apple Music and Spotify have dedicated integrations; browsers and other system media arrive through the generic Now Playing source when macOS exposes them. The media view uses the originating application target when available, so its open action can return the user to the correct browser or player. Seeking, volume, previous, and next remain conditional because not every source exposes every control.

### Files and context

Dropped files enter a shelf-style tray instead of disappearing into a hidden temporary workflow. The UI can reveal the tray for an incoming drop and keeps a local list of shelf items. Clipboard and utility features are treated as contextual helpers rather than a cloud synchronization system.

## Interface and customization

- SwiftUI and AppKit notch panels
- macOS Liquid Glass styling
- Configurable workspace, display placement, shortcuts, and preferences
- Agentic-mode switch for a focused non-agent workspace

## Distribution and updates

- Direct DMG installation with ZIP fallback
- Developer ID signing, Apple notarization, and stapled tickets
- GitHub Release publishing
- In-app update checks and release notes

## Feature availability

Some features depend on macOS permission, a configured provider, or a local executable that the user has already installed and signed in to. NotchFlow detects unavailable integrations and should present setup or recovery information instead of pretending an action was completed. This is particularly important for agents, Notes automation, Reminders, browser media, and web search.
