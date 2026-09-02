# Development

## Prerequisites

- macOS with Xcode 16 or later
- Apple-silicon Mac for the production target
- Swift Package Manager or Xcode build tools
- A configured provider key or signed-in local CLI only for the features you intend to exercise

## Open and run

```bash
open NotchFlow.xcodeproj
```

Or use the repository development entry point:

```bash
./scripts/reinstall.sh
```

The development script is for the local iteration loop. It is not a substitute for the signed release workflow. Release packaging runs in GitHub Actions with the Developer ID certificate and notarization credentials stored as Actions secrets.

## Test

```bash
swift test
```

Useful release checks:

```bash
node scripts/gen-releases.mjs --check
bash Tests/verify_release_metadata.sh
bash Tests/verify_next_release_version.sh
bash Tests/verify_create_dmg.sh
bash Tests/verify_create_zip.sh
```

The Swift suite checks product behavior. The shell verification scripts protect release metadata, release naming, signing assumptions, packaging helpers, and the rules that prevent the release process from drifting from the published documentation.

## Contribution and release rules

- Use Conventional Commits.
- Open a pull request for `main`.
- Let the required verification check pass before merge.
- Do not force-push or delete `main`.
- Do not manually modify generated `CHANGELOG.md`.
- Do not commit API keys, signing certificates, or notarization keys.
- Keep website-only work under `web/` when it should not create an app release.

Read [CONTRIBUTING.md](../../CONTRIBUTING.md) and [RELEASING.md](../../RELEASING.md) before publishing.

### Why Conventional Commits matter here

Commit messages are not cosmetic in this repository. The automatic tagger reads the commits since the previous release and uses them to calculate the next semantic version. A feature commit signals a minor release, a fix signals a patch release, and an explicit breaking-change signal advances the major version. A malformed history can therefore produce the wrong customer-facing version or cause validation to reject the pull request.

### Protected-main workflow

`main` is the release boundary. Work is proposed through a pull request, validated, and merged. The merged app-source commit triggers tag creation and the signed release pipeline. Website-only changes use the separate Pages workflow and intentionally do not create a distributable macOS app release.

## Wiki maintenance

The Markdown files under `docs/wiki/` are the Wiki source of truth. Edit them with the code change they describe, then render and publish them using [Wiki publishing](../wiki-publishing.md).

The GitHub Wiki itself is another Git repository. Keep authoring in this repository so documentation changes receive the same review and history as code. The renderer copies only known pages and leaves unrelated files in the Wiki clone untouched; that prevents a documentation update from accidentally deleting a hand-maintained Wiki file.
