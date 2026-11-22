# NotchFlow Privacy Policy

Effective date: 2026-11-22

<!--
Deployment requirement: this file is the source for the public policy published at
https://sidhxntt.github.io/NotchFlow/privacy/ (web/public/privacy/index.html,
the URL configured in the app). Keep the two in step, and update both before a
release that changes how the app handles data.
-->

NotchFlow is a direct-download macOS app. It has no account system and no
server of its own, so your prompts never pass through a NotchFlow backend. This
policy explains what the app keeps on your Mac, what it sends and to whom, and
how to remove it.

## At a glance

- **No account.** No sign-up, and no NotchFlow server receiving what you type.
- **Kept on your Mac.** History, notes, files and agent records are stored locally.
- **Sent only where you choose.** Prompts go straight to the provider, CLI or
  search service you set up.
- **Keys in the Keychain.** API keys and your license are stored in the macOS Keychain.
- **No tracking.** No analytics, advertising or tracking code in the app.
- **You decide for agents.** NotchFlow never approves an agent's request on your behalf.

## Data stored on your Mac

NotchFlow keeps what its local features need, in your user Application Support
directory and the app's preferences:

- Your recent prompts and answers, and any screenshots or images you attach to
  a conversation.
- Note and reminder receipts, and the text of a quick note until Apple Notes
  confirms it was saved.
- Agent-run records and logs, so a run can be reopened or recovered after a restart.
- File tray items: references to files you drop, plus copies of dropped text,
  images or links, kept until you remove them.
- Settings, prompt shortcuts and Pomodoro history.
- A small diagnostics log with the provider name, time, HTTP status and error
  category. It can also record the process name of an unrecognised system
  window that appears over the notch (see below). It is designed not to contain
  prompts, responses, clipboard content, window contents or API keys.

Provider API keys, the trial start, your Dodo Payments license key and
activation state, and an opaque per-install identifier are stored in the macOS
**Keychain**. Keychain data can survive an app reinstall. NotchFlow does not
collect a hardware fingerprint for licensing.

## Data the app reads but does not keep

Some features read information on your Mac to show it in the notch. None of it
is sent anywhere unless a row below says so.

- **Clipboard.** With Copy to file or clipboard history on, NotchFlow reads what
  you copy. Clipboard history is held in memory only, up to the limit you set,
  and is gone when the app quits. Items that password managers mark as
  concealed or transient are skipped.
- **Selected text.** When you run a prompt shortcut on a selection, the selected
  text is read and sent, with the shortcut's instruction, to the provider you chose.
- **Notification banners.** With Accessibility allowed, NotchFlow reads the text
  of banners on screen to show them beside the notch. They are not written to disk.
- **Now playing, calendar and devices.** Track details, your upcoming events and
  accessory battery levels are read from macOS to display them.
- **Coding CLI files.** To show session status, context and usage, NotchFlow
  reads the local transcripts and settings of the coding CLIs you use, such as
  Codex or Claude Code. Those files stay under the CLI's own storage and
  retention rules.
- **On-screen windows.** NotchFlow checks which apps own the windows on screen
  (their process names, never titles or contents) so it can step out of the way
  of macOS password, Touch ID and purchase prompts.
- **File drags.** While you drag something, NotchFlow checks whether the drag
  carries files (the type only, not the files themselves) so it can open the
  notch as a drop target.

## Files changed outside NotchFlow's folder

So that approvals from Codex and Claude Code sessions started in Terminal can
appear in the notch, NotchFlow adds its own entries to those CLIs' hook
settings. It only adds; other tools' entries are left as they are.

- **Codex:** entries in `~/.codex/hooks.json` and the script
  `~/.codex/notchflow-codex-hook.py`. Codex asks you to trust new hooks with
  `/hooks` before they run.
- **Claude Code:** one `PermissionRequest` entry in `~/.claude/settings.json`,
  and the script `~/.claude/notchflow/notchflow-hook.py`. The first change keeps
  a copy of your original file as `settings.notchflow-backup.json`, and a
  settings file that cannot be read is never rewritten.

The hooks pass the session ID, working folder, tool name and the command or
file path in question to NotchFlow over a local socket on your Mac. Nothing
goes over the network. When NotchFlow is closed or Agentic mode is off, the CLI
asks in the terminal as usual. To stop this entirely, remove NotchFlow's
entries from those files.

## Permissions

NotchFlow asks only for permissions needed by features you choose to use. They
can include:

- Automation access to create or open items in Apple Notes, and to control
  Apple Music or Spotify.
- Calendar and Reminders access to show your events and create reminders.
- Notifications to tell you about timers, reminders, calls or other enabled alerts.
- Accessibility access for features that read selected text, read notification
  banners or interact with another app.
- Camera access when you open the webcam preview.
- Location access when you enable local weather.

Some optional utilities may ask for others, such as Screen Recording, only when
you turn them on. You can deny or revoke any permission in macOS System
Settings; a feature that needs a denied permission will not be able to use it.

## What leaves your Mac

NotchFlow sends data over the network only to services you select, or that are
needed for something you asked for. It does not proxy your content through a
NotchFlow server.

| Service | What it receives | When |
| --- | --- | --- |
| The AI provider or signed-in CLI you configure | Your prompt, the conversation context you include, and attachments you add | When you Ask, run an agent, or use a provider feature |
| A web-search service (Exa, Keenable, AnySearch) or your provider's built-in search | The search query | When an answer needs a web search you have set up |
| Open-Meteo | Your approximate location, rounded to about 1 km | When the Utilities tab shows weather and you allowed Location |
| GitHub | A request for the latest release, and the update download | When NotchFlow checks for or installs an update |
| Dodo Payments | Your license key and an opaque install name. It returns the purchase email, which NotchFlow compares on your Mac with the one you typed; the email you type is not sent | When you buy, activate, validate or deactivate a license |
| Apple apps and services | The note, reminder, calendar, camera or location request | When you use those features, under Apple's policies and your settings |

Each provider's own terms and privacy policy apply to what it receives. Dodo
Payments, the merchant of record, collects payment details, not NotchFlow. NotchFlow may also open links
you choose, such as support, release notes or a provider sign-in page.

## Trial and license

The seven-day trial starts on the first successful launch and is measured as
seven 24-hour periods. When it expires, NotchFlow blocks product functionality
until a valid paid license is activated. A valid paid license is perpetual and
includes future NotchFlow updates. An already activated license may remain
available while offline; validation is retried when a network connection is
available so a refunded, disabled or deactivated license can be reflected.

## Retention and deletion

Local history is kept until you delete individual items or use the app's Clear
History controls; deleting history also removes its images. Removing a File
tray item deletes any copy NotchFlow made of it. You can remove provider
credentials in Settings and deactivate a licensed Mac in the License section of
Settings → About.

Removing the app does not necessarily remove Keychain items, Application Support
files, the CLI hook entries described above, content already saved to Apple
Notes or Reminders, or data held by a provider, CLI, Apple app or Dodo
Payments. To remove what remains, use the in-app deletion controls first, then
move `NotchFlow.app` to the Trash and delete its Application Support folder,
Keychain entries and hook entries if you no longer want them. Data held by
another service must be deleted through that service.

## Support and changes

For a privacy question or help with deletion, open a support request at
<https://github.com/sidhxntt/NotchFlow/issues>. Do not post API keys, license
keys, payment details or private prompt content in a public issue.

We will update this policy before a material change to the app's data
practices. The effective date at the top identifies the current version, and
releases include a note when a material privacy change occurs.
