# Technology Stack

## Application platform

| Layer | Technology | Role |
| --- | --- | --- |
| Product UI | SwiftUI | Notch interface, Settings, workspace views, animations, and state-driven rendering |
| macOS window integration | AppKit | Borderless panels, window levels, display placement, Spaces, and native application behavior |
| Concurrency | Swift Concurrency, actors, tasks, `@MainActor` | UI isolation, service work, cancellation, and streaming coordination |
| Target | macOS 14+, arm64 | Direct-download Apple-silicon product target |

## Apple frameworks and system services

| Technology | Use in NotchFlow |
| --- | --- |
| NaturalLanguage | On-device embeddings for intent suggestions |
| FoundationModels, where available | Low-confidence second opinion for intent classification |
| Security / Keychain | Provider credentials and secure-value migration |
| Apple Events / Carbon scripting APIs | Apple Notes creation and reveal actions |
| EventKit | Reminders integration |
| MediaRemote adapter | System Now Playing sessions and browser media context |
| ServiceManagement and AppKit notifications | App lifecycle and system integration points |

## AI and agent layer

- Direct HTTP clients for supported hosted providers
- OpenAI-compatible custom endpoints, including local model servers
- Locally installed, user-authenticated CLI integrations
- Streaming parsers for provider and CLI event formats
- Local transcript observation and hook bridges for supported agent workflows
- A task manager for process lifetime, cancellation, follow-ups, work trails, and recovery

## Build, test, and release tooling

| Area | Tooling |
| --- | --- |
| Project build | Xcode project and Swift Package Manager tests |
| Release metadata | Node script generating `CHANGELOG.md` from What’s New entries |
| Package creation | Shell scripts for DMG and ZIP creation |
| Signing | `codesign`, Developer ID Application identity, hardened runtime, timestamp |
| Notarization | `xcrun notarytool` and `xcrun stapler` |
| CI/CD | GitHub Actions for pull-request validation, automatic tagging, release publishing, and website deployment |
| Website | Separate `web/` project deployed with GitHub Pages workflow |

## Why native Swift

NotchFlow needs unusually close interaction with macOS window levels, system permissions, Keychain, Apple Events, EventKit, media state, and code-signing distribution. SwiftUI provides the compositional interface layer, while AppKit handles the narrow set of desktop behaviors that SwiftUI alone does not expose precisely enough.

## External dependencies and boundaries

The app uses system frameworks and bundled adapters where required for macOS integration. AI providers, search providers, and agent CLIs remain external systems selected or installed by the user. Their availability and capabilities are treated as runtime conditions rather than assumed application dependencies.
