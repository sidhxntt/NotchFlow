# Generic Mode and Agentic Mode

## Generic mode

Generic mode is the focused desktop-companion configuration.

- Shows Media, Utilities, and Activity Monitor workspaces
- Keeps system activity, files, media, and utilities available
- Hides Chat, Agent, and AI Activity Monitor workspaces
- Removes agent-task entry points from the live UI
- Preserves the user’s non-agent preferences and local data

Generic mode is not a degraded failure state. It is an intentional configuration for someone who wants the notch as a calm, system-oriented companion. Its workspace policy keeps the product focused on media, utilities, connected-device signals, activity information, and file context.

## Agentic mode

Agentic mode adds the AI and developer workflow layer.

- Shows Chat and Agent workspaces
- Enables agent-task initiation and session handling
- Enables AI Activity Monitor views
- Connects selected AI providers and supported locally installed CLIs
- Supports streaming, follow-ups, session recovery, and approval flows

When the switch is enabled, the capability store makes the additional workspaces available immediately to the shared notch and Settings UI. When it is disabled while an agent-oriented tab is open, the app returns the visible workspace to Media so the UI cannot remain on a feature that is no longer enabled.

## Key distinction

| Topic | Generic mode | Agentic mode |
| --- | --- | --- |
| Everyday utilities | Available | Available |
| Media and file tray | Available | Available |
| Chat workspace | Hidden | Available |
| Agent workspace | Hidden | Available |
| AI activity monitor | Hidden | Available |
| Local CLI task controls | Disabled | Available when the integration supports them |

## Safety model

Agentic mode does not grant an agent blanket authority. NotchFlow keeps approval and control actions explicit, shows the relevant context, and only exposes actions that the connected integration can safely perform.

An enabled agentic UI does not mean every CLI action is always available. Integration health, supported capabilities, current task state, and explicit user confirmation still determine whether an action is rendered. A transcript hint, for example, can show that a session exists but must not by itself create an approval button.

## Choosing a mode

Choose generic mode when the desired experience is quick capture-adjacent utilities without conversational and coding-agent surfaces. Choose agentic mode when the Mac is also a local AI-development workstation and the user wants Chat, task execution, and agent visibility in the notch. Switching modes changes the workspace policy; it does not erase the local records that are already stored.
