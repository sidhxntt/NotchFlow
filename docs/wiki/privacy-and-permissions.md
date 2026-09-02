# Privacy and Permissions

## Local-first by design

NotchFlow has no separate product account and no NotchFlow-operated user-data backend. Prompts, chats, history, notes, reminders, agent sessions, clipboard data, and shelf data remain on the Mac unless the user deliberately uses a connected service.

Local-first does not mean “nothing ever leaves the Mac.” It means the destination is explicit and direct. An Ask prompt goes to the provider or endpoint chosen in Settings; a web search goes to the selected search provider; a local agent task runs through the installed CLI in the chosen project. NotchFlow does not insert a product-operated relay between the user and those services.

## Direct connections

- AI prompts and explicitly attached context go directly to the configured provider or local endpoint.
- Local agent tasks use the user’s installed and authenticated CLI.
- Web search requests go to the selected search provider.
- NotchFlow does not relay this content through its own service.

## Credential handling

- Provider and search credentials are stored in macOS Keychain.
- No production API keys are bundled with the app.
- Local CLI authentication remains owned by the CLI.
- Certificates, notarization keys, and CI secrets never belong in source control.

### Keychain boundary

The secure storage layer uses a Keychain service scoped to NotchFlow’s bundle. It supports reading, setting, removal, and migration from legacy stored values. A legacy value is deleted only after the Keychain write succeeds, which avoids losing a credential during an update. This boundary is shared by the places that need secure local values rather than duplicating ad hoc preference storage.

## macOS permissions

| Permission or integration | Why it is used |
| --- | --- |
| Automation / Apple Events | Save or reveal Apple Notes |
| Reminders access | Create and manage Apple Reminders |
| Notifications | Notify about selected product events |
| Accessibility or related system access | Support configured interaction and system integrations when invoked |
| Media system access | Show and control supported Now Playing sessions |

Permissions are requested around the feature that needs them and failures surface a recovery path. Denying a permission should not make unrelated NotchFlow features unusable.

### Notes permission behavior

Apple Notes Automation is requested only when the Apple Notes destination is used. The first request may display a macOS privacy prompt. NotchFlow performs the blocking Apple Event off the main thread so the system dialog remains interactive. If access is declined, the user can grant it later in macOS settings or choose the Markdown note destination instead.

### Agent authority

The presence of an agent transcript does not by itself give NotchFlow permission to act. Sensitive controls depend on the connected adapter, current verified state, and an explicit interaction. A request that cannot be tied safely to a controllable session remains an observation with a native-tool fallback.

## User control

- Configure or disconnect providers and integrations
- Choose note destinations and media sources
- Review and clear local data through product controls
- Stop running local tasks and decline approvals
- Open the originating application where a feature provides a native target

## Data categories

| Category | Normal location | External destination only when chosen |
| --- | --- | --- |
| Provider keys | macOS Keychain | Never sent to a NotchFlow backend |
| Chats and recent history | Local application storage | Prompt content goes directly to the selected provider |
| Notes and reminders | Apple Notes, local Markdown, or Apple Reminders | Native Apple integration on the user’s Mac |
| Agent task records | Local application storage and local CLI/session data | The selected local CLI and its configured services |
| Shelf and clipboard context | Local application storage | Only when the user drags, copies, opens, or explicitly shares it |
| Release checks | Local updater state | GitHub Release endpoints for update metadata and artifacts |

## What to review before connecting a service

Review the privacy terms and data handling of every hosted AI or search provider you add. NotchFlow can keep its own product data local while a prompt still becomes subject to the policy of the provider the user deliberately selects. Use a local OpenAI-compatible endpoint or a signed-in local CLI when that better suits the user’s privacy requirements.

For the full legal and retention detail, read the tracked [Privacy Policy](../../PRIVACY.md).
