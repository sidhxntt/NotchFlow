# Updates and Versioning

## What users receive

Users download the newest published NotchFlow release. They do not install missed releases one at a time: someone on `v1.0.0` who updates after `v1.0.1` and `v1.1.0` are published receives `v1.1.0` directly.

The GitHub Release is the immutable record of the source revision and assets that shipped. A release tag points at the exact commit used to build the app. Users receive the newest valid release rather than a chain of incremental patches, because every DMG and ZIP contains a complete app bundle.

## In-app updates

The app checks the configured GitHub Release feed for a newer signed version. Before replacing the installed bundle, it verifies the release artifact and then performs a recoverable replacement and relaunch.

Automatic checks are intentionally quiet. They run at launch and on the app’s schedule without interrupting a prompt or hover interaction. The Settings interface provides a manual check, a visible available-version state, and a recovery route to the release page if an attempted install fails. A manual check has a short network timeout so a broken connection cannot leave the Settings UI waiting indefinitely.

## Release notes

- `CHANGELOG.md` is generated from `WhatsNewService.swift`.
- Run `node scripts/gen-releases.mjs`; do not edit the generated changelog by hand.
- GitHub generates release notes from the commits in the published release.
- The in-app What’s New panel remains editorial and user-facing.

This separates two useful records. GitHub’s generated notes describe the commit set associated with a published tag. The in-app What’s New content is curated for people updating the product. Both should agree on the important user-facing change, but the in-app panel does not need to duplicate raw commit history.

## Version rules

| Commit signal | Version bump |
| --- | --- |
| `fix:` | Patch |
| Other app-source commit | Patch |
| `feat:` | Minor |
| `type!:` or `BREAKING CHANGE:` | Major |

Only app-source commits on `main` create a release version. A push whose changed files are entirely under `web/` is intentionally excluded from the app-release path.

The tag workflow serializes releases and detects a commit that already has a release tag before creating another. This avoids duplicate version allocation when a workflow is rerun. A manually pushed valid `vX.Y.Z` tag can still trigger the release workflow, but it is not needed for the normal protected-`main` path.

## Update safety

- Reject malformed update bundles
- Verify Developer ID signature and Gatekeeper assessment
- Verify NotchFlow bundle identifier and version fields
- Preserve the old installed app until replacement succeeds
- Roll back if the installation transaction fails

## User update path

1. NotchFlow discovers a newer published version.
2. The user sees it in Settings and requests the update.
3. The updater downloads the expected release artifact.
4. Artifact verification confirms that it is a NotchFlow bundle from the expected signing team and version.
5. The installed app is replaced only after verification succeeds.
6. The updater relaunches the new app or preserves the prior installation if replacement fails.

The normal manual-install equivalent is to download the latest DMG from GitHub Releases, drag the complete application into Applications, and replace the older copy. There is no requirement to install intermediate versions first.

See [release and distribution](release-distribution.md) for the artifact pipeline.
