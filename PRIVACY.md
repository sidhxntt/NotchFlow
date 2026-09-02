# NotchFlow Privacy Policy

Effective date: 2026-09-02

NotchFlow is a direct-download macOS application. This policy explains the data
the app handles, why it handles it, and the choices available to you. NotchFlow
does not operate its own account system or a backend that receives your prompt
content.

## Deployment requirement

This tracked policy is the source for the public policy. It is published at
`https://sidhxntt.github.io/NotchFlow/privacy/` (the URL configured in the
app). Before any public release, verify that the live page matches this file
and keep it updated when the product changes.

## Data stored on your Mac

NotchFlow stores the content needed to provide its local features, including
your recent prompts and answers, notes/reminder capture receipts, selected
settings, agent-run records, and any screenshots or images you attach to a
conversation. Conversation history and attached history images are stored in
your user Application Support directory. The app may also keep a small local
diagnostics log containing provider name, time, HTTP status, and error category;
it is designed not to contain prompt text, response text, clipboard content, or
API keys.

Agent features may read the local transcript files created by the coding CLI you
choose (such as Codex or Claude Code) so NotchFlow can show their status. Those
CLI transcript files remain under the CLI's own local storage and retention
rules; NotchFlow does not upload them to a NotchFlow service.

Provider API keys, the trial start, your Lemon Squeezy license key and activation
state, and an opaque per-install identifier are stored in the macOS **Keychain**.
Keychain data can survive an app reinstall. NotchFlow does not collect a hardware
fingerprint for licensing.

## Permissions

NotchFlow asks only for permissions needed by features you choose to use. They
can include:

- Automation access to create or open items in Apple Notes.
- Calendar and Reminders access to show calendar events and create reminders.
- Notifications to tell you about timers, reminders, calls, or other enabled
  alerts.
- Accessibility access when you turn on features that read selected text or
  interact with another app.
- Camera access when you enable the webcam preview.
- Location access when you enable local weather.

You can deny or revoke these permissions in macOS System Settings. A feature
that needs a denied permission will not be able to use it.

## Network use and third parties

NotchFlow sends data over the network only to services selected by you or needed
to deliver a service you request:

- **AI providers and web-search providers.** When you submit an Ask request,
  invoke an agent, use web search, or attach content for a provider feature,
  the relevant prompt, selected conversation context, and requested attachments
  are sent directly to the provider, locally signed-in CLI, or search service
  you configured. That provider's own terms and privacy policy apply to its use
  of the data. NotchFlow does not proxy that content through a NotchFlow server.
- **Apple services and apps.** When you choose Notes, Reminders, Calendar,
  notifications, camera, or location features, macOS and the relevant Apple app
  or service handle the requested action under Apple's policies and your device
  settings.
- **Lemon Squeezy.** Lemon Squeezy processes purchase checkout, payment,
  license-key delivery, and license activation, validation, or deactivation.
  The app sends the license key, an activation email when supplied, and an
  opaque install name to Lemon Squeezy's public licensing endpoints. Payment
  details are collected by Lemon Squeezy, not by NotchFlow. Lemon Squeezy's
  policies govern the information it processes.

The app also checks for signed application updates and may open links that you
explicitly choose, such as support, release notes, or a provider sign-in page.

## Trial and license

The seven-day trial starts on the first successful launch and is measured as
seven 24-hour periods. When it expires, NotchFlow blocks product functionality
until a valid paid license is activated. A valid paid license is perpetual and
includes future NotchFlow updates. An already activated license may remain
available while offline; validation is retried when a network connection is
available so a refunded, disabled, or deactivated license can be reflected.

## Retention and deletion

Local history is retained until you delete individual items or use the app's
Clear History controls; deleting history also removes associated history images.
You can remove provider credentials in Settings and deactivate a licensed Mac in
the License section of Settings → About. Removing the app does not necessarily remove Keychain items,
local Application Support files, content already saved to Apple Notes or
Reminders, or data held by your selected provider, CLI, or Lemon Squeezy.

To remove remaining local NotchFlow data, first use the in-app deletion controls
and remove credentials/license data through the app where available. Then move
`NotchFlow.app` to the Trash and remove its related Application Support and
Keychain entries if you no longer want to retain them. Deleting data held by a
provider, CLI, Apple app, or Lemon Squeezy must be requested from that service.

## Support

For a privacy question or deletion help, open a support request at
<https://github.com/sidhxntt/NotchFlow/issues>. Do not post API keys, license
keys, payment details, or private prompt content in a public issue.

## Changes to this policy

We will update this policy before a material change to the app's data practices.
The effective date at the top identifies the current version. Releases should
also include a user-facing note when a material privacy change occurs.
