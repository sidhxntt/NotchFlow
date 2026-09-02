# Contributing to NotchFlow

## Commit messages and releases

Every pull request merged into `main` that changes anything outside `web/**`
automatically creates and publishes a signed NotchFlow release. Use a
[Conventional Commit](https://www.conventionalcommits.org/) message so GitHub
Actions selects the right version:

| Commit message | Automatic version bump |
| --- | --- |
| `fix: correct the update label` | Patch — `1.1.1` → `1.1.2` |
| `feat: add Focus mode` | Minor — `1.1.1` → `1.2.0` |
| `feat!: replace the settings format` | Major — `1.1.1` → `2.0.0` |
| A commit with `BREAKING CHANGE:` in its body | Major — `1.1.1` → `2.0.0` |
| Any other non-web commit | Patch — `1.1.1` → `1.1.2` |

Use a feature branch and open a pull request; `main` is protected and accepts
changes only through a passing pull request. GitHub Actions creates the tag,
builds the app, notarizes it, and publishes the release after merge.

Changes limited to `web/**` do not create an app release.

GitHub generates the release notes from commit history. If a release also
needs curated in-app “What's New” text, add it to
`NotchFlow/Sources/WhatsNewService.swift` and run
`node scripts/gen-releases.mjs` before opening the pull request.
