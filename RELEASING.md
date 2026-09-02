# Releasing NotchFlow

NotchFlow ships direct-download, Apple-silicon (`arm64`) releases for macOS 14+
as a Developer ID-signed, notarized, stapled DMG. The DMG is the primary
download; a ZIP made from the same stapled app is the fallback. Users open the
DMG and drag **NotchFlow.app** into Applications without a quarantine workaround.

## Release prerequisites

Before merging an app change into `main`:

- Write the commit using [Conventional Commits](https://www.conventionalcommits.org/).
  The automatic release tag chooses the largest bump represented by commits
  since the last release: `fix:` (or any unclassified non-web commit) is a
  patch bump, `feat:` is a minor bump, and `type!:` or a `BREAKING CHANGE:`
  footer is a major bump.
- Optionally add a user-facing release entry to
  [WhatsNewService.swift](NotchFlow/Sources/WhatsNewService.swift), then run
  `node scripts/gen-releases.mjs`. `CHANGELOG.md` is generated; never edit it
  by hand. GitHub generates release notes from commits for every automated
  release; the bundled What's New panel remains deliberately editorial.
- Run `node scripts/gen-releases.mjs --check`,
  `bash Tests/verify_release_metadata.sh`, and
  `bash Tests/verify_next_release_version.sh`.
- Confirm the product promise remains true: the trial is exactly seven
  24-hour periods; after it expires every product capability is blocked until
  a valid Lemon Squeezy license is activated; a valid paid license is
  perpetual and includes future NotchFlow updates.
- Configure the bundled non-secret Lemon checkout URL plus expected store,
  product, and variant identifiers. The checkout URL must be HTTPS and every
  identifier must be non-zero. Never place a Lemon API token or webhook secret
  in the app or repository.
- Publish the exact tracked [Privacy Policy](PRIVACY.md) at
  `https://www.notch.website/privacy`, verify the live page matches this file,
  and only then advertise the in-app Privacy link. This repository does not
  deploy that website.
- Verify every public raw GitHub installer URL uses `/main/`, never `/master/`.

## Apple and GitHub Actions setup

These are two separate Apple credentials with different jobs:

| Apple item | Created in | Used for |
| --- | --- | --- |
| **Developer ID Application certificate** | Apple Developer → Certificates | Cryptographically signs `NotchFlow.app` for distribution outside the Mac App Store. |
| **App Store Connect Team API key** | App Store Connect → Users and Access → Integrations | Authenticates GitHub Actions to Apple’s notarization service. |

### 1. Developer ID Application certificate

1. Joined the Apple Developer Program.
2. In Keychain Access, created a Certificate Signing Request (CSR).
3. In Apple Developer, created a **Developer ID Application** certificate
   using that CSR. This is the certificate required to sign a direct-download
   Mac app; it is not a Mac App Store distribution certificate.
4. Downloaded and opened the `.cer` file so Keychain Access paired it with the
   private key generated alongside the CSR.
5. Exported the certificate **and private key** from Keychain as
   `Certificates.p12`, protected by an export password.

GitHub imports that `.p12` temporarily during a release, signs the app with
the identity, enables hardened runtime, and requests Apple’s signing timestamp.

### 2. App Store Connect Team API key

1. In **App Store Connect → Users and Access → Integrations → App Store
   Connect API**, created a **Team Key** named for NotchFlow notarization.
2. Assigned the **Developer** access role.
3. Downloaded the one-time `.p8` private-key file.
4. Recorded the displayed **Key ID** and the team’s **Issuer ID**.

GitHub writes this `.p8` key to a temporary restricted file only while running
`notarytool`; Apple uses the Key ID and Issuer ID to identify the key and team.
The temporary key file is removed even when notarization fails.

### 3. GitHub repository secrets

Added the Apple credential material to GitHub Actions secrets:

| Secret | Apple item it contains |
| --- | --- |
| `SIGNING_CERT_P12` | Base64-encoded `Certificates.p12` |
| `SIGNING_CERT_PASSWORD` | The `.p12` export password |
| `NOTARY_ISSUER_ID` | App Store Connect Issuer ID |
| `NOTARY_KEY_ID` | App Store Connect Team Key ID |
| `NOTARY_PRIVATE_KEY` | Contents of the downloaded `.p8` key |

The local `.p12` and `.p8` files are ignored by Git. Keep them out of the
repository and store them securely or delete them once backed up safely.

Set the non-secret repository Actions variable `APPLE_TEAM_ID` to the expected
ten-character Apple Developer Team ID. The release workflow requires this
value and compares it with the signed bundle so a valid certificate from the
wrong team cannot publish a NotchFlow release.

## What GitHub Actions does for each app-source push

On a push to `main`,
[.github/workflows/auto-release-tag.yml](.github/workflows/auto-release-tag.yml)
ignores a change set that is entirely under `web/`. Every other push is an app
release candidate. It finds the latest `vX.Y.Z` tag, calculates the next
version from the Conventional Commit messages, creates that tag at the pushed
commit, and dispatches the release workflow. It serializes these runs and
does not mint another tag when re-run for a commit that is already tagged.

The tag is still an immutable record of the exact shipped source. A manually
pushed `vX.Y.Z` tag also runs the release workflow, but normal releases do not
need a manual tag command.

## What GitHub Actions does for each release tag

On a pushed `v*` tag, [.github/workflows/release.yml](.github/workflows/release.yml):

1. Rejects malformed tags and derives `X.Y.Z` from an exact `vX.Y.Z` tag.
2. Stamps both `CFBundleShortVersionString` and `CFBundleVersion` with `X.Y.Z`
   and builds only `arm64`.
3. Runs Swift, packaging, and release-metadata checks before signing.
4. Imports the Developer ID certificate into a temporary CI keychain and signs
   the app with hardened runtime and a secure timestamp.
5. Verifies the exact bundle identifier (`com.notchflow.app`), both bundle
   versions, Apple-silicon architecture, Developer ID signature, and expected
   `APPLE_TEAM_ID` before packaging.
6. Creates the primary `NotchFlow-vX.Y.Z-arm64.dmg`, containing the app and an
   Applications shortcut, plus `NotchFlow-vX.Y.Z-arm64.zip` as the fallback.
7. Submits the DMG to Apple notarization, staples and validates both the DMG
   and app, then creates the ZIP from the stapled app.
8. Validates the mounted DMG and extracted ZIP before publishing the two exact
   artifacts. The workflow actions are pinned to immutable revisions.

If notarization is rejected, the workflow retrieves Apple’s notarization log
in the failed job output.

## Publish a release

Commit with the bump signal that describes the release, then push or merge it
to `main`. For example:

```bash
git commit -m "feat: add Focus mode"
git push origin my-feature-branch
```

Open a pull request and merge it into `main`; the **Create Release Tag**
workflow handles the tag and starts **Release**. A `fix:` follows `v1.0.2`
with `v1.0.3`; a `feat:` follows it with `v1.1.0`; and a breaking change
follows it with `v2.0.0`. A commit that changes only `web/` does not release
the app.

Watch the **Release** workflow in GitHub Actions. When it finishes, download
the published DMG on a clean Apple-silicon Mac and confirm Gatekeeper opens
it. Also inspect the ZIP fallback and test a fresh trial, a fully blocked
expired trial, a valid Lemon activation, and a signed in-app update.

## Protecting `main`

`main` is protected so releases begin only after a pull request is merged. It
requires the uniquely named **app-verification** check,
an up-to-date branch, resolved review conversations, linear history, and a
pull request (no approval count is required for this single-maintainer
repository). It also blocks force-pushes and deletion, including by admins.

After authenticating the GitHub CLI as a repository administrator, apply or
reapply the exact policy with:

```bash
bash scripts/protect-main-branch.sh
```

The script changes remote GitHub settings; use it only for this repository.

## Files that own the process

- [.github/workflows/release.yml](.github/workflows/release.yml) — build,
  signing, notarization, and publishing.
- [.github/workflows/auto-release-tag.yml](.github/workflows/auto-release-tag.yml)
  — computes and creates the tag for each non-web `main` push, then dispatches
  the release workflow.
- [scripts/next-release-version.sh](scripts/next-release-version.sh) —
  calculates the conventional-commit semantic version bump.
- [scripts/protect-main-branch.sh](scripts/protect-main-branch.sh) — applies
  the compatible, pull-request-based `main` branch-protection policy.
- [scripts/codesign-app.sh](scripts/codesign-app.sh) — signs and verifies the
  app; CI refuses any non-Developer-ID release signature.
- [scripts/create-dmg.sh](scripts/create-dmg.sh) — packages a signed app into
  the DMG.
- [scripts/create-zip.sh](scripts/create-zip.sh) — packages the same signed
  app into the optional fallback ZIP.
- [install.sh](install.sh) — optional command-line installer for the latest
  notarized DMG.
- [CHANGELOG.md](CHANGELOG.md) — generated, tracked public release record.
- [Tests/verify_release_metadata.sh](Tests/verify_release_metadata.sh) —
  checks public URLs, release-note parity, generated metadata, CI guards, and
  documentation requirements.
- [PRIVACY.md](PRIVACY.md) — tracked policy source. Hosting it at the configured
  public privacy URL remains a prerequisite outside this repository.
