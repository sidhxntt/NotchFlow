# NotchFlow — Product Requirements Document

**Status:** Product definition  
**Product name:** NotchFlow  
**Platform:** macOS 14+ on physical-notch MacBooks  
**Launch integrations:** OpenAI Codex and Anthropic Claude Code  
**Reference capabilities:** AgentNotch (agent-session monitoring), NotchDrop (temporary File Shelf), and NotchFlow (quick assistant, notes, reminders, and locally launched agent tasks)

## 1. Product summary

NotchFlow turns a physical MacBook notch into a calm, local-first operating surface for everyday work and AI-assisted development. It is one cohesive product rather than a collection of widgets: a user can drop a file, ask a quick question, save a note, set a reminder, launch a coding task, or respond to an existing agent session from the same notch surface.

NotchFlow combines three complementary jobs:

- **Keep:** hold temporary files and lightweight everyday controls close at hand.
- **Think:** capture a note or reminder, or get a concise answer from a configured assistant.
- **Act:** launch, monitor, and safely respond to local Codex and Claude Code work.

**Positioning:** *The useful part of your MacBook notch.*

## 2. Problem

MacBook users have a prominent but underused interaction zone at the top of their display. Existing notch utilities make it useful for files and quick widgets, while agent-monitoring tools show coding activity without giving users a unified place to continue work. Quick capture tools can create notes, reminders, or new agent tasks, but typically live apart from the user’s file and agent context.

People increasingly switch between everyday work, temporary files, quick thoughts, and long-lived AI tasks. They miss approvals, lose context, and repeatedly jump among Terminal, an editor, Finder, browser tabs, and capture apps. NotchFlow makes the next useful action visible at the point users already glance at.

## 3. Vision and principles

### Vision

On a physical-notch MacBook, the notch becomes a trusted command surface for the user’s digital day. It is quiet when nothing needs attention, useful for common actions throughout the day, and decisive when an AI agent needs a human decision.

### Product principles

1. **One surface, many contexts.** Files, everyday utilities, quick capture, assistant responses, and agent operations share an interaction model and visual language.
2. **Attention is earned.** NotchFlow interrupts only for a decision, completion, failure, reminder, or explicitly selected live activity.
3. **Control without impersonation.** The user can launch, redirect, approve, deny, stop, or resume an agent only when NotchFlow can clearly describe and verify the action.
4. **Local first.** Screen, file, clipboard, agent-session, note/reminder, history, and credential data remain on-device unless the user deliberately configures a direct provider or connected service.
5. **Fast enough to be habitual.** Opening, understanding status, and completing a common action must feel immediate.
6. **The notch is the product.** The launch experience targets physical-notch MacBooks; virtual-notch and external-display modes are out of scope.
7. **Intent is assistive, never opaque.** NotchFlow may suggest whether input is an ask, note, reminder, or agent task, but the user always sees and can change the selected destination before submission.

## 4. Target users and jobs to be done

| User | Primary job | NotchFlow outcome |
| --- | --- | --- |
| Everyday MacBook user | Keep small recurring tasks, temporary files, and playback close without opening more windows. | File Shelf, Now Playing, timers, calendar, reminders, and quick controls are one hover away. |
| Knowledge worker | Capture a thought, task, or meeting follow-up without breaking focus. | A single input can save a note, create a reminder, or answer a short question. |
| AI-assisted developer | Know whether Codex or Claude Code is working, blocked, or done. | Existing and NotchFlow-launched sessions are visible, prioritized, and actionable. |
| Power user | Run multiple activities without constant window scanning. | NotchFlow prioritizes the next item needing attention and provides a compact activity queue. |

## 5. Goals and non-goals

### Goals

- Make the notch valuable to both non-technical users and people running AI coding agents.
- Provide rich, reliable status and action control for local Codex and Claude Code sessions.
- Let users start a supported Codex or Claude Code task from NotchFlow in a chosen project, follow its progress, send a follow-up, stop it, and reopen its native session.
- Support common utility workflows without crowding the screen: File Shelf, calendar, timers, clipboard, reminders, camera, media, and configurable shortcuts.
- Provide a concise quick-assistant flow, note capture, and reminder capture from the notch.
- Preserve trust through clear permissions, action receipts, privacy controls, and reversible user actions.
- Deliver a cohesive macOS experience across normal desktop, full-screen, and multi-display workflows on supported hardware.

### Non-goals for launch

- Replacing Terminal, an IDE, Finder, Apple Notes, Reminders, or an agent’s native interface.
- Acting as a general autonomous computer-use agent.
- Supporting Windows, Linux, notchless Macs, external-display virtual notches, team collaboration, cloud sync, or remote agent control.
- Hosting or relaying user prompts, files, transcripts, or credentials through a NotchFlow-operated backend.
- Building a multi-provider AI platform, web-search agent, handwriting system, statistics dashboard, or integrations beyond Codex and Claude Code at launch.

## 6. Experience model

```text
COLLAPSED NOTCH
Passive identity + highest-priority activity signal
             |
             | hover, click, drag a file, or configurable shortcut
             v
QUICK STRIP
Current item + fast safe actions + quick composer
             |
             | click, drag down, shortcut, or choose a workspace
             v
EXPANDED NOOK
Everyday · Files · Capture · Assistant · Agents + activity queue
             |
             | command/action
             v
NATIVE APP / TERMINAL / EDITOR
NotchFlow confirms outcome and returns to the appropriate state
```

### States

- **Idle:** The collapsed notch blends into the hardware and exposes no distracting UI.
- **Ambient activity:** A subtle indicator represents Now Playing, timer progress, calendar imminence, a live assistant response, or an agent working. When no higher-priority attention item is pending, active playback is the default ambient signal.
- **Needs attention:** A restrained, distinct state signals an agent approval, question, failure, completion, due reminder, or a user-selected alert. The highest-priority item wins; remaining items appear in the activity queue.
- **Quick strip:** A small expansion reveals the current activity, the quick composer, and its fastest safe actions.
- **Expanded NotchFlow:** A larger popover below the notch reveals the active workspace and a persistent activity queue.

## 7. Functional requirements

### 7.1 Shared shell and navigation

- The app shall use a notch-aligned, borderless interface that does not block menu-bar interactions when collapsed.
- Users shall open NotchFlow by hover, click, drag gesture, file drag-in, or configurable keyboard shortcut.
- The app shall support collapsed, quick-strip, and expanded states with click-away, Escape, and configurable timeout dismissal. A pending destructive confirmation shall not disappear without an explicit choice.
- Users shall select a default workspace, pin common widgets, and restore workspace and preference state across launches.
- The activity queue shall show one prioritized item in collapsed and quick-strip states and all outstanding items in the expanded view.
- All shell behavior shall work predictably in full-screen spaces and on multiple displays, while the primary notch experience remains on the physical-notch display.

### 7.2 Everyday workspace

The Everyday workspace shall include:

- **Media / Now Playing:** The currently playing item from Spotify, Apple Music, or a supported web player in a browser shall automatically appear in the collapsed-notch activity signal, Quick Strip, and Everyday workspace. NotchFlow shall show source app, title, artist or publisher, artwork when available, playback state, and elapsed time. It shall provide play/pause, previous/next, scrub, and volume controls where the source exposes them. If multiple sources are active, the most recently audible source wins; the user may choose another active source from the expanded workspace.
- **Calendar:** next event, time-to-event, join link, and compact day agenda.
- **Timers:** create, pause, resume, dismiss, and label multiple timers.
- **Clipboard:** recent user-enabled clipboard entries, pinning, copy-back, and per-entry deletion.
- **Quick controls:** user-configured shortcuts for frequently used macOS actions and applications.
- **Notifications:** a compact, user-filtered list of high-value notifications; notification content remains local.
- **Camera:** a live webcam mirror with camera selection, mirror toggle, clear active-camera indication, and immediate stop behavior.

### 7.3 Files workspace — File Shelf

- Users shall drag files into the notch to create a temporary File Shelf.
- The shelf shall show file name, type, size, source location where available, and previews where practical.
- NotchFlow shall explicitly state whether a shelf item is a retained copy or an authorized reference. The launch implementation shall retain a local copy to ensure reliable drag-out and expiration behavior.
- Users shall drag items to other apps, open them, reveal them in Finder, copy, share, or remove them.
- Shelf content shall survive NotchFlow relaunches until removed or its user-selected expiration ends.
- NotchFlow shall store retained copies in an app-managed location, provide storage and retention controls, and request no more file access than needed for the files a user places in the shelf.

### 7.4 Capture workspace

- A single quick composer shall be available from the quick strip and expanded NotchFlow.
- The user shall be able to explicitly select **Ask**, **Note**, **Reminder**, or **Agent task** before submitting.
- NotchFlow may suggest a destination based on text, but the selected destination must remain visible and editable before submission.
- **Note:** NotchFlow shall save a note to the user’s selected local destination: Apple Notes when permission is granted, or a user-selected Markdown folder. It shall show a receipt and provide Open Original.
- **Reminder:** NotchFlow shall create a reminder in the user’s selected list, show the parsed title and due date before confirmation when a date is inferred, and provide an understandable correction path.
- **Quick assistant:** NotchFlow shall stream a concise answer in the notch, retain the conversation locally, and allow the user to reopen, copy, or clear it. A provider is enabled only through an explicit user configuration; request data goes directly to that provider or a selected local endpoint.
- Users shall be able to attach selected text, an explicitly pasted clipboard item, or an image to an Ask or Agent task. NotchFlow shall visibly identify all attached context before sending it.

### 7.5 Agent workspace

The Agents workspace is an operational surface for local Codex and Claude Code sessions. It supports both **observed sessions** that were started elsewhere and **NotchFlow-launched tasks** that NotchFlow starts in a user-selected project.

#### Session visibility

- NotchFlow shall discover eligible existing sessions through documented integrations, local hooks, or user-authorized transcript/state observation.
- NotchFlow shall display launched tasks from their process lifecycle and streamed output.
- Each session shall display agent type, project label, current task summary, origin (observed or NotchFlow-launched), state, elapsed time, and last meaningful event.
- States shall include: **working**, **waiting for user**, **approval requested**, **completed**, **failed**, **stopped**, and **unknown**.
- NotchFlow shall group child/subagent activity beneath its parent where the integration provides that relationship.
- Users shall filter, pin, dismiss, or reopen sessions; dismissal hides only NotchFlow’s representation and does not stop the underlying session.

#### Starting and continuing tasks

- A user shall be able to create a Codex or Claude Code task from the Capture workspace by selecting an installed, healthy integration and a project folder.
- Before launch, NotchFlow shall show the selected agent, project folder, prompt, explicit attachments, and any requested runtime options.
- NotchFlow shall start only the user’s locally installed and authenticated CLI; it shall not request or store provider credentials when the CLI already owns authentication.
- A NotchFlow-launched task shall show streamed progress, a compact work trail, final outcome, and a locally stored action history.
- Users shall be able to send a follow-up instruction to a NotchFlow-launched task when its adapter supports continuation or resume.
- Users shall be able to stop a NotchFlow-launched task, with confirmation when active work may leave a workspace in a partial state.

#### Actions and controls

- For a waiting agent, NotchFlow shall provide context-appropriate **Approve**, **Deny**, **Allow once**, **Stop**, **Send follow-up**, and **Open original session** actions only when the selected adapter can execute and confirm them safely.
- Approval controls shall show the exact request, affected command or operation, scope, and a short risk label before confirmation.
- Inferred state must be explicitly labelled and may not enable approval controls.
- Users shall be able to jump to the native terminal, app, or editor hosting a session whenever NotchFlow knows a valid target.
- NotchFlow shall display a timestamped local action receipt after every control action: what was sent, to which session, and whether the integration confirmed delivery.

#### Attention and notification policy

- An approval request, explicit agent question, failure, completion, due reminder, or explicitly enabled assistant completion shall enter the activity queue.
- Priority order is: approval request, explicit question, failure, due reminder, completion, user-pinned session, then ambient progress.
- Users shall configure visual treatment, sound, and macOS notifications for each attention category.
- NotchFlow shall never auto-approve a request or submit an instruction based solely on a notification, timer, or inferred intent.

### 7.6 Agent integration requirements

NotchFlow shall implement an adapter for each agent that normalizes native events into a shared local contract:

```text
session_id, parent_session_id, agent_type, origin, project_label,
state, summary, requested_action, action_payload,
created_at, updated_at, deep_link_target
```

- Adapters shall declare supported commands: open, start, resume, send instruction, approve, deny, allow once, and stop.
- The UI shall expose only commands the adapter can execute and confirm safely.
- Adapters shall distinguish verified state from inferred state.
- If an integration disconnects, NotchFlow shall preserve last known state with its timestamp and direct the user to the native session.
- Control actions shall be idempotent where supported; otherwise NotchFlow shall lock the action while acknowledgement is pending.
- Every integration action shall have a timeout, clear failed-delivery result, audit receipt, and Open Original fallback.

### 7.7 Settings and onboarding

- Onboarding shall explain notch interaction, required macOS permissions, integration health, assistant configuration, and privacy choices before affected features are enabled.
- Users shall connect Codex and Claude Code independently and see whether discovery, launch, and controls are healthy.
- Settings shall expose trigger gestures, shortcuts, workspace order, notification policy, File Shelf retention, camera behavior, local-data retention, note/reminder destinations, assistant provider configuration, and diagnostics.
- A privacy dashboard shall show what categories of local data NotchFlow currently reads, why, where retained copies are stored, and how to clear each category.

## 8. Privacy, security, and user trust

- Agent transcripts, screen content, file metadata, clipboard entries, calendar content, notes, reminders, camera video, chat history, and action receipts remain local by default.
- NotchFlow shall not upload user data for analytics, model processing, or product operations without separate, explicit opt-in.
- When a user configures an assistant provider, NotchFlow shall send only that user-selected request and explicit context directly to that provider or local endpoint. It shall not relay content through a NotchFlow service.
- Credentials and connection tokens shall use macOS Keychain; the app shall never request provider API keys unless a user explicitly enables a provider that requires one.
- NotchFlow shall request macOS permissions incrementally and only when a user invokes the dependent feature.
- Sensitive agent actions shall require explicit confirmation unless the user has selected a narrowly scoped, revocable preference for that exact verified action type.
- NotchFlow shall retain a user-clearable local audit log for agent-control and capture actions, including enough request context to understand the action but excluding full transcript content by default.
- Users shall be able to pause an integration or erase NotchFlow data without altering the underlying Codex, Claude Code, Notes, Reminders, or provider-session data.

## 9. Non-functional requirements

### Performance

- Collapsed NotchFlow must remain visually responsive with negligible perceived impact on normal Mac use.
- Quick strip shall appear within 150 ms of a valid user trigger in normal conditions.
- Confirmed local agent events shall appear within 2 seconds.
- Background monitoring shall minimize CPU, memory, disk reads, and battery use; it shall be throttled on battery when no attention-worthy event is pending.

### Accessibility

- All controls shall be keyboard operable and expose meaningful VoiceOver labels, state, and action descriptions.
- Status shall never be communicated by color alone.
- NotchFlow shall honor macOS accessibility settings for reduced motion, text size, contrast, sound, and notifications.

### Resilience

- NotchFlow shall degrade safely when a permission, configured assistant, agent adapter, source app, or CLI is unavailable.
- The app shall never prevent access to macOS menu-bar items or block the user’s active work.
- A crash or restart shall not terminate, modify, or lose an underlying agent session unless the user explicitly requested its stop.
- Failure to infer a capture destination shall leave the user’s input intact and ask for an explicit destination.

## 10. Success criteria

The product is successful when launch validation proves all of the following:

- Users can open the correct NotchFlow workspace and complete a common action without searching for a window.
- A user can drop a file into the notch, recover it after relaunch, and safely drag it back into another app.
- A user can explicitly save a note, set a reminder, or ask a configured assistant while understanding where the data will go.
- Users running Codex or Claude Code correctly recognize every high-priority state—approval, question, failure, and completion—and can reach the original session or take a verified supported action.
- A user can launch a supported local Codex or Claude Code task from NotchFlow, see progress, send a follow-up where supported, and stop it deliberately.
- Every agent-control action is understandable before submission and leaves a readable receipt afterward.
- A privacy-conscious user can understand and change NotchFlow’s local-data and permission posture without support.

## 11. Measurement

Measurement is opt-in and collected locally first. Any shared diagnostic data must be aggregated and stripped of content, file names, project names, prompts, command text, note content, and reminder content.

Key metrics:

- Weekly active users, agent-connected users, and users of each workspace
- Workspace opens and completion rate for File Shelf, capture, assistant, and agent actions
- Now Playing availability, source selection, and playback-control success rate by source type
- Median time from agent attention event to user action or original-session jump
- Agent-action delivery success rate and false-state report rate
- Agent-task launch, completion, follow-up, and stop success rate
- Permission grant, denial, and recovery completion rates
- File Shelf return use, timer/reminder completion use, and capture destination corrections
- Crash-free active devices and battery/CPU resource-budget compliance
- Privacy-dashboard visits, data-clearing events, and opt-in telemetry rate

## 12. Launch acceptance criteria

The launch product is ready only when:

1. The shared notch shell, Everyday, Files, Capture, Assistant, and Agents workspaces are present and usable on supported physical-notch MacBooks.
2. File Shelf import, persistence, expiration, drag-out, deletion, reveal, and privacy disclosure are tested.
3. Now Playing correctly represents supported Spotify, Apple Music, and browser-player sources; source selection, metadata, and every exposed playback control have defined and tested behavior.
4. Notes and reminders have explicit destination, permission-denied, completion, and Open Original flows.
5. A configured quick assistant clearly identifies its provider and explicit context, streams or fails gracefully, and retains locally clearable history.
6. Codex and Claude Code each support reliable session visibility, native-session opening, NotchFlow-task launch, and every available verified instruction, follow-up, approval, denial, and stop control.
7. Unsupported or inferred agent actions are clearly unavailable rather than simulated.
8. Permission-denied, connection-lost, duplicate-action, app-restart, full-screen, and multi-display flows have defined and tested behavior.
9. Local-first data handling, audit-log clearing, retained-file clearing, and integration pausing are independently verified.
10. Accessibility and performance requirements are tested on supported macOS versions and representative MacBook hardware.

## 13. Open decisions to resolve before design and engineering

- Final product name and trademark clearance for “NotchFlow.”
- Supported macOS floor and physical-notch hardware list.
- Exact documented integration mechanism and public API/hook availability for Codex and Claude Code, especially for verified approval/denial and resume controls.
- The initial quick-assistant provider policy: one direct hosted provider, user-selected OpenAI-compatible endpoint, local endpoint, or no assistant at the first beta.
- Whether Apple Notes or a Markdown folder is the default note destination, and the default reminder list behavior.
- Exact supported browser-player integrations and their metadata/control capability matrix.
- Which notification sources and macOS quick controls qualify for launch.
- Whether clipboard history is disabled until explicitly enabled.
- File Shelf storage budget, default expiration, and handling of cloud/network-provider files.
- Commercial model: one-time purchase, subscription, free tier, or hybrid.
