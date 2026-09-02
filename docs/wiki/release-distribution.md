# Release, Signing, Notarization, DMG, and ZIP Delivery

NotchFlow is a direct-download macOS app. It does not use Mac App Store submission, App Review, or Transporter for this delivery path. Releases are built for Apple silicon, signed with a Developer ID Application certificate, notarized by Apple, and published through GitHub Releases.

## One-time Apple setup

### 1. Join the Apple Developer Program

An active Apple Developer Program membership is required for a Developer ID certificate and notarization access.

### 2. Create a certificate signing request

1. Open **Keychain Access** in `/Applications/Utilities`.
2. Choose **Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority**.
3. Enter the account email and a descriptive common name.
4. Leave the CA email empty.
5. Select **Saved to disk** and save the `.certSigningRequest` file.

### 3. Create the Developer ID Application certificate

1. Sign in to **Apple Developer → Certificates, Identifiers & Profiles**.
2. Select **Certificates** and click **Add (+)**.
3. Under **Software**, select **Developer ID**.
4. Select **Developer ID Application**.
5. Upload the CSR and download the resulting `.cer` file.
6. Open the `.cer` file in Keychain Access so it pairs with the private key from the CSR.
7. Export the certificate and private key from **My Certificates** as a password-protected `.p12`.

Use **Developer ID Application**, not **Developer ID Installer**. NotchFlow distributes an app in a DMG and ZIP, not a signed installer package.

### 4. Create a notarization API key

1. Sign in to **App Store Connect**.
2. Open **Users and Access → Integrations → App Store Connect API**.
3. Select **Team Keys**.
4. Click **Generate API Key**.
5. Give it a descriptive name and choose the required role.
6. Record the **Key ID** and the account **Issuer ID**.
7. Download the one-time `.p8` private key and store it securely.

Use a Team API key for this GitHub Actions workflow. Apple documents that individual API keys cannot use `notarytool`.

## One-time GitHub setup

In **GitHub → Settings → Secrets and variables → Actions**, add these repository secrets:

| Secret | Value |
| --- | --- |
| `SIGNING_CERT_P12` | Base64-encoded Developer ID Application `.p12` |
| `SIGNING_CERT_PASSWORD` | The `.p12` export password |
| `NOTARY_ISSUER_ID` | App Store Connect Issuer ID |
| `NOTARY_KEY_ID` | Team API key ID |
| `NOTARY_PRIVATE_KEY` | Contents of the downloaded `.p8` key |

Add this repository Actions variable:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Expected ten-character Apple Developer Team ID |

Never commit the `.p12`, `.p8`, passwords, Base64 certificate, or secret values. The workflow imports credentials only into a temporary CI keychain and temporary restricted files.

## Developer release checklist

1. Add a user-facing release entry to `NotchFlow/Sources/WhatsNewService.swift` when appropriate.
2. Run `node scripts/gen-releases.mjs` to regenerate `CHANGELOG.md`.
3. Run `node scripts/gen-releases.mjs --check`.
4. Run `bash Tests/verify_release_metadata.sh`.
5. Run `bash Tests/verify_next_release_version.sh`.
6. Use a Conventional Commit message and merge the pull request into `main`.
7. Confirm the changes are not only under `web/`.
8. Watch **Create Release Tag** and then **Release** in GitHub Actions.
9. Test the published DMG, ZIP fallback, fresh install, and in-app update on a clean Mac.

## Automated release pipeline

### Tag creation

`auto-release-tag.yml` runs after an app-source push to `main`.

- A `fix:` or unclassified app commit produces a patch release.
- A `feat:` produces a minor release.
- `!` or a `BREAKING CHANGE:` footer produces a major release.
- A changeset only under `web/` produces no app tag and no notarization run.
- The workflow creates an annotated `vX.Y.Z` tag for the exact merged commit.

### Build and signing

`release.yml` derives the version from that tag and:

1. Builds the arm64 Release app with both bundle version fields set to `X.Y.Z`.
2. Imports the `.p12` into a temporary CI keychain.
3. Signs the app and nested frameworks/tools with the Developer ID Application identity.
4. Enables hardened runtime and a secure signing timestamp.
5. Checks the bundle identifier, Team ID, architecture, versions, and signature.

### Notarization and packaging

1. Creates a temporary ZIP containing the signed app for Apple’s notarization upload.
2. Submits it with `xcrun notarytool submit --wait` using the Team API key.
3. Retrieves Apple’s log when notarization fails.
4. Staples and validates the ticket on `NotchFlow.app`.
5. Creates `NotchFlow-vX.Y.Z-arm64.dmg` from the stapled app.
6. Submits the DMG, then staples and validates its ticket.
7. Creates `NotchFlow-vX.Y.Z-arm64.zip` from the already-stapled app.
8. Mounts the DMG and extracts the ZIP for final validation.
9. Publishes both assets in the GitHub Release.

## Why the DMG and ZIP differ

| Artifact | Role | Ticket handling |
| --- | --- | --- |
| DMG | Primary download; users open it and drag the app to Applications | The DMG can receive a stapled ticket |
| ZIP | Fallback for Macs that cannot mount a disk image | ZIP files cannot be stapled directly |
| App inside ZIP | The executable delivered by the ZIP | Must already have its own stapled ticket |

## Release verification

The workflow checks:

- `codesign --verify --deep --strict --verbose=2`
- Bundle identifier and version parity with the tag
- Apple-silicon architecture and expected Team ID
- `spctl --assess --type execute --verbose=4`
- `xcrun stapler validate` for the app and DMG
- DMG mount, Applications alias, and app validation
- ZIP extraction and app validation

## Troubleshooting

| Symptom | First check |
| --- | --- |
| No release starts | Confirm a non-`web/` commit reached `main` and branch protection permitted the merge |
| Certificate import fails | Confirm the `.p12` includes the private key and the export password matches |
| Wrong signing identity | Confirm the identity begins with `Developer ID Application:` |
| Notarization fails | Read the `notarytool log` emitted by the failed workflow job |
| ZIP fails Gatekeeper validation | Confirm the app was stapled before the ZIP was created |
| In-app update refuses an artifact | Confirm signature, Team ID, bundle identifier, and versions match the release |

## Apple references

- [Create a certificate signing request](https://developer.apple.com/help/account/certificates/create-a-certificate-signing-request)
- [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [App Store Connect Team API keys](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Packaging Mac software for distribution](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)

The repository’s executable source of truth is [RELEASING.md](../../RELEASING.md) and the release workflows under [`.github/workflows`](../../.github/workflows/).
