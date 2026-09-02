# Product Overview

## The idea

NotchFlow makes the space around a Mac’s notch an always-available operating surface. It is designed for short actions that normally make someone switch among Terminal, Finder, Notes, Reminders, browser tabs, and media controls.

## The workflow

1. Open the notch by hover, click, shortcut, drag-in, or the configured trigger.
2. Type or drop the thing that needs attention.
3. Let NotchFlow suggest an intent, then confirm or change the destination.
4. Continue in the native app, a chosen AI provider, or a local agent CLI when needed.

The product deliberately keeps the first interaction short. The notch is useful when someone needs to capture an idea, check active work, start a small action, or get back to the app that owns the task—not when they need a full replacement for that app.

## Four core intents

| Intent | Result |
| --- | --- |
| Ask | A streamed answer from the configured provider or CLI-backed service |
| Note | An Apple Note or local Markdown note |
| Remind | An Apple Reminder with a user-visible confirmation path |
| Agent | A task in a user-selected local project folder |

Automatic detection is a convenience layer, not a hidden routing rule. The intent engine uses Apple’s on-device NaturalLanguage embedding model and a small locally trained classifier to distinguish common asks from notes. On supported systems it can ask the system model for a second opinion only when confidence is low. Until that background preparation completes, NotchFlow falls back safely instead of holding up typing.

The visible selection remains the source of truth. A user can change a suggestion before any provider request, Apple Event, reminder creation, or agent launch happens.

## What NotchFlow is not

- A replacement for an IDE, Terminal, Finder, Notes, Reminders, or a browser
- A hosted AI gateway or a NotchFlow-operated data backend
- An autonomous computer-use tool that acts without user approval
- A Mac App Store product; it is delivered directly as a signed, notarized DMG

## Design stance

- One compact surface, multiple work contexts
- Minimal interruption; attention must be earned
- Clear authority boundaries for agent actions
- Local-first storage and direct provider connections

## Product boundaries

NotchFlow integrates with native applications and locally installed developer tools, but it does not impersonate them. A note remains an Apple Note or a Markdown file. A reminder remains in Apple Reminders. An agent task runs in the project folder and local CLI the user chose. The app’s job is to provide a concise entry point, state visibility, safe handoffs, and a way back to the original context.

## How attention works

The resting notch stays quiet whenever possible. When something is active, it can show compact state such as Now Playing or system activity. Higher-value events—an agent waiting for input, a completion, a failure, or a requested approval—take precedence over passive activity. The expanded view exposes the related workspace without turning every background event into an interruption.
