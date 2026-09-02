# NotchFlow Direct Download Release Checklist

## Scope

NotchFlow will be distributed from the NotchFlow website, not through the Mac App Store. The downloadable artifact should be a signed and notarized DMG that contains `NotchFlow.app` and an Applications-folder shortcut.

Notarization is not Mac App Store review. It is Apple's automated security verification for Developer ID apps distributed directly to users.

## Already in place

- App bundle name: `NotchFlow.app`.
- Bundle identifier: `com.notchflow.app`.
- Version/build configuration through `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`.
- macOS 14.0 minimum deployment target.
- Final AppIcon asset catalog.
- Hardened Runtime enabled for Release builds.
- Calendar and Apple Events entitlements in `NotchFlow/Resources/NotchFlow.entitlements`.
- GitHub release workflow that builds a Release app and publishes a ZIP.
- `scripts/codesign-app.sh`, which signs nested code and verifies signatures and required entitlements.

## Required before public release

### Apple account and certificate

1. Join the Apple Developer Program.
2. Create a **Developer ID Application** certificate in the Apple Developer account.
3. Export it as a password-protected `.p12` and store it securely.

Do not use an ad-hoc identity, local development identity, Mac App Distribution certificate, or the repository's self-signed `NotchFlow Code Signing` certificate. Those are not appropriate for public direct distribution.

### CI secrets

Create or update these GitHub Actions secrets:

- `SIGNING_CERT_P12`: base64-encoded Developer ID Application `.p12`.
- `SIGNING_CERT_PASSWORD`: password used to export the `.p12`.
- `NOTARY_KEY_ID`: App Store Connect API-key ID.
- `NOTARY_ISSUER_ID`: App Store Connect issuer ID.
- `NOTARY_PRIVATE_KEY`: contents of the `.p8` App Store Connect API key.

Use a restricted App Store Connect API key for notarization automation. Never commit the `.p12`, `.p8`, passwords, or base64 content.

### Release signing changes

Update `scripts/codesign-app.sh` and `.github/workflows/release.yml` so a Release build:

- Uses the Developer ID Application identity for the app and nested code.
- Uses Hardened Runtime (`--options runtime`).
- Includes a secure signing timestamp (`--timestamp`).
- Preserves required Calendar and Apple Events entitlements.
- Excludes `com.apple.security.get-task-allow`.
- Fails when Developer ID signing is unavailable rather than falling back to ad-hoc signing.

Keep the current separate Debug signing behavior for local development; never publish a Debug artifact.

### Release architecture

Build a Release archive for every version tag. If NotchFlow supports both Intel and Apple silicon Macs, validate the final executable with:

```bash
lipo -archs NotchFlow.app/Contents/MacOS/NotchFlow
```

Expected output for a universal build: `arm64 x86_64`.

### DMG assembly

Add a release script such as `scripts/create-dmg.sh`. It must:

1. Create a temporary staging directory.
2. Copy in the already-signed `NotchFlow.app`.
3. Add an `Applications` symlink to `/Applications`.
4. Create a compressed read-only UDIF DMG named `NotchFlow-<version>.dmg`.
5. Never modify the app after signing it.

The mounted DMG should contain:

```text
NotchFlow.app
Applications -> /Applications
```

Finder layout, background artwork, and custom icon positioning are optional polish after the basic DMG works.

### Notarization and stapling

After signing and DMG creation, submit the DMG using `xcrun notarytool submit` with the App Store Connect API key. Wait for acceptance, then run:

```bash
xcrun stapler staple NotchFlow-<version>.dmg
xcrun stapler validate NotchFlow-<version>.dmg
```

In CI, create the API-key file in a temporary restricted-permission path, delete it even on failure, and retrieve the `notarytool` log whenever notarization is rejected.

### Final validation

Validate the stapled DMG and the app copied out of it:

```bash
codesign --verify --deep --strict --verbose=2 NotchFlow.app
codesign -dvvv --entitlements :- NotchFlow.app
spctl -a -vv NotchFlow.app
xcrun stapler validate NotchFlow-<version>.dmg
```

Test the release on a clean macOS user account or a second Mac:

1. Download the DMG through a browser so quarantine is applied.
2. Drag the app into Applications.
3. Launch normally, with no quarantine removal or “Open Anyway” workaround.
4. Verify Gatekeeper identifies the Developer ID publisher.
5. Exercise every permission-dependent feature: Calendar, Reminders, Apple Events, Accessibility, Screen Recording, Camera, and Location.
6. Verify an update preserves user data and expected permissions.

## Target release workflow

The GitHub tag workflow should produce:

- `NotchFlow-<version>.dmg` — primary website download.
- `NotchFlow-<version>.zip` — optional fallback/archive.

Required order:

```text
tag push
  → build Release archive
  → Developer ID sign and verify
  → create DMG
  → notarize DMG
  → staple and validate DMG
  → publish artifacts
```

## Definition of done

This work is complete when a version tag automatically produces a Developer ID-signed, notarized, stapled DMG and a clean Mac can install and launch NotchFlow without Gatekeeper workarounds.



1. media slider for browser
2. preview ui fixes
3. remove everything related for calling
   