# Frequently Asked Questions

## Does NotchFlow require a hardware notch?

No. It supports a virtual notch on supported Macs and selected external displays. The same panel model is placed at the top-center of each selected display, while the product keeps one shared interaction and history model across those panels.

## Does NotchFlow need an account?

NotchFlow has no separate product account. Hosted AI services may require the account or API key you already use with that provider. Local CLI integrations use the sign-in owned by that CLI. The app can remain useful for notes, reminders, media, files, and utilities without configuring an AI provider.

## Where does data go?

Most product data remains on the Mac. An Ask request and its explicitly included context go directly to the provider or local endpoint selected by the user. NotchFlow does not relay this content through its own backend.

## Can it run local models?

Yes. OpenAI-compatible endpoints can be configured for local services such as Ollama, LM Studio, vLLM, or a self-hosted gateway. A custom local endpoint does not require an API key merely because hosted providers do; the endpoint and model configuration are the meaningful prerequisites.

## Can it control browser media?

When macOS exposes a browser session through system Now Playing, NotchFlow can present it as the generic Now Playing source and foreground the originating browser. Available commands depend on the source. The app does not claim that every browser player exposes identical seeking, volume, next, or previous controls.

## What does Automatic media source mean?

Automatic means NotchFlow follows whichever eligible source is currently playing. Apple Music and Spotify may be pinned explicitly; browser and other system media are represented through the generic Now Playing source. The ranking avoids letting stale metadata from an idle native player hide a newly active browser session.

## What is the difference between generic and agentic mode?

Generic mode keeps the compact media-and-utilities companion. Agentic mode enables Chat, Agent, and AI Activity Monitor workflows. See [Modes](modes.md).

## Do missed updates install sequentially?

No. Updating downloads the latest compatible published release directly. A complete application bundle is included in every release artifact, so a user who skips versions receives the newest one rather than installing each intermediate update. See [Updates and versioning](updates-and-versioning.md).

## Is NotchFlow on the Mac App Store?

No. It is a direct-download app delivered through GitHub Releases as a Developer ID-signed and Apple-notarized DMG, with a ZIP fallback. This path uses Apple notarization, not App Store review or Transporter upload. See [Release and distribution](release-distribution.md).

## Why does NotchFlow ask for macOS permissions?

Features that interact with Apple Notes, Reminders, notifications, media, or other macOS services may require the associated permission. The app requests access around the feature that needs it and provides an error or fallback route if permission is denied. For example, Apple Notes Automation can be replaced with local Markdown note saving.

## What happens when an agent needs approval?

NotchFlow may show a supported agent’s status and offer an explicit action only when it can identify the request and safely route the result. It does not auto-approve commands. If a session is only observed or cannot be controlled through a verified integration, the safe option is to open the original terminal or application instead.
