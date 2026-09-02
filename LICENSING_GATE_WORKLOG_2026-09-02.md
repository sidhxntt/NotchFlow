# Licensing Gate Worklog — 2 September 2026

## Outcome

The app now has a production licensing gate while local Debug builds remain
usable for development. The gate cleanly suspends product services when an
entitlement is unavailable, and the separate Agentic-mode preference correctly
controls whether Codex and Claude approvals are routed through the Notch.

This is a handoff note for the licensing-gate work completed today. It is not a
complete list of every pending change in the working tree.

## Licensing behaviour

- Release builds begin in `checking`, then permit product services only for an
  active trial or a validated license.
- The trial duration is seven 24-hour periods. Trial state, clock-tamper
  protection, the license key, activation instance, and validation state use
  secure local storage.
- Activations and validations are checked against the configured Lemon Squeezy
  store, product, variant, and customer email. A rejected activation is
  deactivated so it does not consume a device slot.
- A previously validated perpetual license remains available while offline;
  an explicitly invalid license or an expired trial blocks the product.
- When the entitlement becomes blocked, product tasks are cancelled, product
  windows and entry points are removed, and the license gate is shown. New
  work and asynchronous writes are guarded so they cannot outlive the gate.

## Debug entitlement fix

Debug builds intentionally have a local development entitlement, without
requiring a trial, a license key, or access to secure storage.

The fault was that startup recognized this entitlement, but a subsequent
`refreshIfPossible()` could fall through to the release-storage path. If the
installed app was actually the fresh Debug build, that refresh could still put
the app behind the gate.

`LicenseService` now treats the Debug entitlement as authoritative during both
initial resolution and every refresh. The entitlement is injectable in tests,
so release licensing logic is still tested even when the test target is built
with `DEBUG` enabled.

## Fresh-build and installed-app fix

The local build script builds a Debug product, then mirrors it to
`/Applications/NotchFlow.app` before launching it. This matters because
launching an old installed bundle can look like a licensing failure even when
the new Debug build is correct.

The signing step could encounter a temporary `.cstemp` file emitted by
`codesign`. `find` could return that path after it disappeared, aborting the
script before installation and leaving the old app in place. The script now
skips files that no longer exist, finishes signing, and mirrors the bundle with
`rsync --delete` so stale files cannot remain in the installed app.

The script also stabilizes the local app's TCC designated requirement using the
bundle identifier. Rebuilds therefore retain macOS permissions such as
Accessibility instead of appearing as a new app after every code-signing hash
change.

## Agentic mode and approvals

Agentic mode is deliberately independent from the license state.

| State | Intended behaviour |
| --- | --- |
| Agentic mode off | The Agent and in-app Chat surfaces are unavailable. Codex and Claude hook bridges are stopped, so their approval prompts remain in the native terminal sessions for the user to approve manually. The Notch does not show or route pending external approvals. |
| Agentic mode on | Codex and Claude bridges and monitoring start again. Pending approvals route to the Notch Agent tab, and in-app Chat and Agent work normally. If an approval was already pending when the preference is re-enabled, it is routed immediately. |

Turning Agentic mode off cancels Notch-owned Chat and Agent work and clears
Notch approval state; it does not terminate the user's external Codex or
Claude session. Hook delivery fails open to the CLI's own prompt while the mode
is off. Re-enabling restores routing for active and new external sessions, but
does not revive a cancelled in-app run.

Selecting the Agent workspace no longer silently re-enables Agentic mode. The
user's explicit off setting remains authoritative.

## Main files in this work

- `NotchFlow/Sources/Capabilities/LicenseService.swift` — entitlement,
  trial, activation, validation, and runtime-suspension rules; Debug refresh
  fix.
- `NotchFlow/Sources/Capabilities/KeychainStore.swift` and
  `NotchFlow/Sources/Capabilities/LicensingConfiguration.swift` — secure
  storage and release configuration support.
- `NotchFlow/Sources/AppDelegate.swift` — applies entitlement and Agentic-mode
  lifecycle changes to product services and bridges.
- `NotchFlow/Sources/AgentTaskService.swift` — stops/resumes external approval
  monitoring and bridges with Agentic mode.
- `NotchFlow/Sources/NotchModel.swift` and
  `NotchFlow/Sources/ContentView.swift` — guard Chat/Agent entry points and
  remove Agent-only Notch state while Agentic mode is off.
- `NotchFlow/Sources/Capabilities/NotchCapabilityStore.swift` — preserves the
  explicit Agentic-mode preference.
- `script/build_and_run.sh` — reliable signing, installation, launch, and TCC
  identity verification for the local Debug build.
- `Tests/NotchCapabilityTests/LicenseServiceTests.swift` and
  `Tests/NotchCapabilityTests/NotchCapabilityStoreTests.swift` — regression
  coverage for Debug refresh and the Agentic-mode off preference.

## Verification completed

- Added and passed a regression test proving the Debug entitlement remains
  `licensed` after a refresh.
- Added and passed a regression test proving selecting the Agent tab does not
  re-enable a disabled Agentic mode.
- Ran the full Swift test suite: 302 XCTest tests passed with zero failures,
  plus 96 Swift Testing tests passed.
- Ran `./script/build_and_run.sh --bundle`: Debug app build succeeded.
- Ran `./script/build_and_run.sh --verify`: Debug app built, installed, and
  launched successfully.
- Confirmed the installed app's designated requirement is
  `identifier "com.notchflow.app"`.

## Git handoff note

The working tree also contains unrelated product and release changes. For a
licensing-gate review or commit, use the file list above as the primary scope
and review the diff rather than staging the entire worktree indiscriminately.
