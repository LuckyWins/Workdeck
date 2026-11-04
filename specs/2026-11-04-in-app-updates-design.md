# Workdeck — In-App Updates and Release Notes Design

**Date:** 2026-11-04
**Status:** Draft

## 1. Overview

Today the author builds Workdeck on their Mac and sends the `.app` to colleagues, and every new version means sending it again. This spec lets an installed Workdeck learn that a new version is out, show what changed, and install it in place, with releases built and published by GitHub Actions when a version tag is pushed.

It also starts a changelog: every feature or fix adds a line to `CHANGELOG.md`, and the app shows those notes in a Release Notes window.

Decided with the user (brainstorming 2026-11-04, browser screens `updates-settings*`, `updates-about*`, `update-notice*` under `.superpowers/brainstorm/`):

- **Sparkle** does the checking, downloading, verifying and installing. It is a new third-party dependency, agreed for this purpose (§9).
- **Releases from CI on a tag**, not from the author's Mac.
- **Signing stays as it is:** the author's Apple Development certificate (team `J55BY69CVU`), not Developer ID, not notarized. Colleagues confirm "Open" (trust) the first time, and that is acceptable.
- **Settings → About, option 1:** the Version row carries the status and the one action that matters; a Release notes row opens a window. No separate Updates section, no automatic-check toggle in Settings.
- **Release Notes window, option B1:** versions in a list on the left, the selected version's notes on the right.
- **News of an update:** a one-line notch alert once per version, and a row in the popover above Quit while the update waits (option B). No dots on the gear or the menu bar icon, no flash of the compact notch.
- **Installing:** Install opens Sparkle's standard update window (notes, Install Update, Skip This Version, Remind Me Later, progress, Install and Relaunch).
- **Notes:** `CHANGELOG.md` in the repository root with an `Unreleased` section; a CLAUDE.md rule makes adding to it part of finishing every feature or fix.

### Goals

- A colleague with Workdeck installed gets every later version without anyone sending a file.
- Every version says, in plain words, what changed; the history can be read in the app.
- Publishing a version is: prepare it with one command, push a tag.
- An update keeps everything working: the privileged helper, the status line and hooks of every instance, Codex's hooks, `recap.json`, settings.

### Non-Goals

- Developer ID signing, notarization, a DMG, a Homebrew cask.
- Delta updates, beta or other update channels, downgrades.
- Automatic silent installation (Sparkle's `SUAutomaticallyUpdate`).
- A "What's New" card shown by itself after an update.
- Updating colleagues who still run a build without Sparkle: they install the first Sparkle version (1.1.0) by hand once.
- Our own update UI on top of Sparkle's install flow (a custom `SPUUserDriver`).

### Accepted Risk

Releases are built and signed only in CI (§5), so the Sparkle private key and the Apple Development certificate live in GitHub Actions secrets. Whoever takes over the author's GitHub account could push a workflow that signs and ships their own build, and an update brings a new privileged helper signed with the same certificate (`LidSleepController` reinstalls the helper when its version changes), so that would mean root on colleagues' Macs; the certificate could also be read out of the secrets. The user chose this on 2026-11-04 over signing on their own Mac: Workdeck goes to colleagues who already trust the author, and the account has two-factor authentication. The mitigations in §5.1 narrow who can reach the secrets; they do not remove the risk.

### Anti-Goals

- An update must never be installable unless it is signed with the release key: a changed download, a hijacked release asset or a man in the middle must not get code onto colleagues' Macs.
- The update news must not interrupt: no window in front of the user's work when the daily check finds a version.
- Settings must not get long: release notes never go into the Settings form.

## 2. What the User Sees

### 2.1 Settings → About

About keeps its section; its Version row changes and one row is added. Diagnostics stays as it is.

```
About
  Version 1.2.0 · up to date              [Check for Updates]
  Release notes                                      [Show…]
  Diagnostics                             [Copy Diagnostics]
```

With an update available:

```
  Version 1.2.0 · 1.3.0 available                   [Install]
```

- **Up to date** (green text, as the mockup) once a check this session found nothing newer; before any check, just `Version 1.2.0` with Check for Updates.
- **While checking:** `Version 1.2.0 · checking…`, the button disabled.
- **Install** opens Sparkle's update window for that version (§2.5). **Check for Updates** runs a user-initiated check: Sparkle shows its own window for "up to date", an error, or the update.
- **Show…** opens the Release Notes window (§2.2).
- No automatic-check toggle. Sparkle asks once, on the second launch, whether to check automatically (its standard permission prompt); the setting it stores is the one used. *Builder's note:* if the permission prompt is judged too intrusive for a menu bar app, `SUEnableAutomaticChecks = YES` in Info.plist turns checks on without asking — that is a change of this spec and needs the user's agreement.

### 2.2 Release Notes Window

A SwiftUI `Window` scene like Chats and Statistics, titled "Release Notes", about 560 × 420, not restored at launch; opening it again brings it forward.

```
┌ Release Notes ───────────────────────────────────────┐
│ 1.3.0  new    │ ┌ 1.3.0 is available      [Install] ┐ │
│ Nov 10, 2026  │ └───────────────────────────────────┘ │
│ 1.2.0 installed│ 1.3.0                                │
│ Nov 4, 2026   │ NEW                                   │
│ 1.1.1         │ • An activity grid in Statistics.     │
│ Oct 28, 2026  │ FIXED                                 │
│ 1.1.0         │ • The notch no longer flickers on…    │
└───────────────────────────────────────────────────────┘
```

- **Left:** every version newest first with its date; the installed one tagged `installed`, an available newer one tagged `new`. The list scrolls on its own.
- **Right:** the selected version's notes, grouped under New, Improved, Fixed (groups without lines left out), as a plain list.
- **Opens on** the available update when there is one, else on the installed version.
- **When an update is available**, a banner over its notes: `1.3.0 is available` with Install (§2.5). The banner shows only on the available version's page.
- **Sources:** installed and older versions come from the `CHANGELOG.md` bundled in the app (works offline). The available version's notes come from the appcast item Sparkle found (its description); they are shown as text, never as rendered HTML from the network.
- The appcast has one item, so before updating only the newest version's notes are known; versions skipped in between appear in the list after the update, from the new bundled changelog. *(My call.)*

### 2.3 Notch Alert

- When a check finds a version newer than the installed one, the notch shows one alert, once per version: `↑ Workdeck 1.3.0 available`, one line, for the usual alert time, with the countdown bar and a blue wash (limit alerts use orange, red and green).
- A click on it opens the Release Notes window on that version.
- No flash of the compact notch afterwards, no haptic, no lasting mark in the notch.
- It shows where alerts show today (the real or the virtual notch). With the menu bar text instead of a notch, or every agent's notch off, there is no alert; the popover row (§2.4) still tells.
- "Once per version" survives relaunches: the version last alerted is remembered (a `UserDefaults` key), so the same version never alerts again, also after Remind Me Later.

### 2.4 Popover Row

- While an update is available and not skipped, the popover shows one row above Quit Workdeck:

```
  ↑ Version 1.3.0 is available        What's New  [Install]
```

- **What's New** opens the Release Notes window on that version; **Install** opens Sparkle's window (§2.5).
- The row goes away when the update is installed, or when the user chose Skip This Version in Sparkle's window (until a newer version appears).
- The row survives a relaunch: the found version (number, date, notes) is remembered in `UserDefaults` and shown until the installed version reaches it, it is skipped, or a newer check replaces it. *(My call.)*

### 2.5 Installing

- Every Install button calls Sparkle's user-initiated check for updates, which brings up Sparkle's standard window for the found version: release notes, **Install Update**, **Skip This Version**, **Remind Me Later**; then download progress and **Install and Relaunch**. Workdeck activates first so the window is in front.
- Sparkle replaces `Workdeck.app` where it is and relaunches it.

### 2.6 Scheduled Checks

- Sparkle checks once a day (its default interval) when automatic checks are on.
- Scheduled finds use Sparkle's gentle reminders: Workdeck's user driver delegate takes over showing a scheduled update (`standardUserDriverShouldHandleShowingScheduledUpdate(_:andInImmediateFocus:)` returns `false`) and shows §2.3 and §2.4 instead of Sparkle's window. User-initiated checks keep Sparkle's window.

## 3. Changelog

`CHANGELOG.md` in the repository root:

```markdown
# Changelog

## Unreleased

### New
- An activity grid in Statistics: half a year of days, your streak, a click opens a week.

### Fixed
- …

## 1.1.0 — 2026-11-10

### New
- Workdeck updates itself: …
```

- Sections `## Unreleased` and `## <version> — <YYYY-MM-DD>`, newest first; groups `### New`, `### Improved`, `### Fixed`; one line per change, `- ` bullets.
- Lines are for colleagues using Workdeck: what changed for them, in English, short. Not commit messages, no file names or internals.
- The app bundles this file as a resource and parses it (pure parser, tested). Unknown headings and lines are ignored rather than failing.
- **CLAUDE.md rule** (added by this work, under Conventions or Documentation Layout): finishing a feature or a user-visible fix adds its line under `## Unreleased` in `CHANGELOG.md`, in the group it belongs to, in the same commit.
- The first `CHANGELOG.md` has `## 1.1.0` describing this release (updates and release notes) plus a short summary line of what 1.0 already had; earlier history is not reconstructed.

## 4. Versions

- `MARKETING_VERSION` is the version (`1.1.0`), `CURRENT_PROJECT_VERSION` the build number, an integer that grows by one with every release. Sparkle compares build numbers (`sparkle:version`) and shows the marketing version (`sparkle:shortVersionString`). Every target that carries these settings stays in step (the helper reports its version to the app: `HelperConstants.version(of:)`).
- `make release-prep VERSION=1.3.0`:
  - refuses when the working tree is not clean, when `VERSION` is not a semantic version greater than the current one, or when `## Unreleased` has no lines;
  - renames `## Unreleased` to `## 1.3.0 — <today>` and adds a new empty `## Unreleased` above it;
  - sets `MARKETING_VERSION` to the version and increments `CURRENT_PROJECT_VERSION`, for every target that has them;
  - commits `chore: release 1.3.0` (Conventional Commits, as the project uses).
  - It does not tag or push; the author pushes the commit and the tag `v1.3.0`.
- The first Sparkle version is **1.1.0** (build 2). Colleagues on 1.0 get it by hand once.

## 5. Releases from CI

A GitHub Actions workflow `.github/workflows/release.yml`, on a pushed tag `v*`, on a macOS runner (free for public repositories):

1. **Check:** the tag without `v` equals `MARKETING_VERSION`; `CHANGELOG.md` has a section for it. Otherwise fail before building.
2. **Sign in:** import the certificate and its private key (`.p12` from a secret, with its password) into a temporary keychain.
3. **Build:** `xcodebuild archive` of the Release configuration and export the app, signed with that certificate and team (manual signing with the Apple Development identity; no notarization). Whether this signs without an Apple account session on the runner is the first thing the first run proves; if it cannot, the builder stops and asks.
4. **Package:** `ditto -c -k --keepParent Workdeck.app Workdeck-1.3.0.zip`.
5. **Sign the update:** Sparkle's `sign_update` with the EdDSA private key from a secret.
6. **Appcast:** an `appcast.xml` with one item for this version: title, `sparkle:version`, `sparkle:shortVersionString`, `sparkle:minimumSystemVersion` (the app's deployment target), the enclosure URL of the zip in this release, its length and EdDSA signature, and a `description` made from the version's changelog section (simple HTML lists).
7. **Publish:** a GitHub release `v1.3.0` with the zip and `appcast.xml` as assets and the changelog section as its body.

- **Feed URL** (Info.plist `SUFeedURL`): `https://github.com/LuckyWins/Workdeck/releases/latest/download/appcast.xml` — always the newest release's appcast, no server.
- **Secrets** (in the `release` environment, §5.1): the certificate `.p12` (base64) and its password, and the Sparkle EdDSA private key; the temporary keychain's password is random per run. The Apple Development certificate expires after a year; renewing it means updating the secret (noted in the docs).
- **Keys:** the EdDSA key pair is made once with Sparkle's `generate_keys`; the public key goes into Info.plist (`SUPublicEDKey`), the private key only into the secret and the author's Keychain, never into the repository.

### 5.1 Protecting the Secrets

- The account has two-factor authentication (already on); a passkey or a security key is recommended in `docs/releasing.md`.
- The three secrets live in a GitHub **environment** named `release`, not in repository secrets; the environment allows deployments only from tags matching `v*`. The release job declares `environment: release`; no other workflow or job can read them.
- A **tag ruleset** protects `v*`: only the owner can create them, and they cannot be updated or deleted.
- The workflow uses only actions pinned to a full commit SHA (no `@v4` tags), and only first-party (`actions/*`) or none where a shell step does the job; Sparkle's tools come from the Sparkle release archive with a checked SHA-256.
- No secret is ever printed; the temporary keychain is deleted at the end of the job, also on failure.

## 6. What Must Survive an Update

| Thing | Why it should survive | How it is checked |
|---|---|---|
| Privileged helper (`SMAppService.daemon`) | Same bundle path, same team in the code-signing requirement (`HelperConstants`) | Manual: after an update, Closed-Lid Mode works without re-approval in Login Items |
| Status line and hook commands | Their paths point into `/Applications/Workdeck.app/Contents/Helpers`, unchanged when the bundle is replaced in place | Manual: sessions and limits keep updating after an update, for every instance and Codex |
| `recap.json`, settings, alert memory | In Application Support and `UserDefaults`, outside the bundle | Manual |
| No new "trust" prompt | Sparkle removes the quarantine attribute from the update it installs | Manual: the relaunched app opens without the Gatekeeper prompt |

If the first real update shows the helper needs re-approval, the app's existing helper status (`requiresApproval`) already guides the user; the builder records it in `docs/closed-lid-mode.md` rather than working around it.

## 7. Architecture

| Component | Responsibility |
|---|---|
| Sparkle (SPM) | `SPUStandardUpdaterController`/`SPUUpdater`, its standard user driver and installer. |
| `UpdateController` (new, `@Observable`, `Workdeck/Core/Updates/`) | Owns the updater; publishes the state the UI needs: installed version, available version (with its notes), checking, up to date, skipped; `checkForUpdates()`, `install()`; implements the gentle-reminder delegate (§2.6) and Sparkle's updater delegate (found, not found, skipped, installed). Behind a protocol (`Updating`) so the views and the notch alert can be tested with a fake, as the project wraps system services. |
| `Changelog` (new, pure, `nonisolated`) | Parses `CHANGELOG.md` text into versions (number, date, groups of lines); ignores what it does not know. |
| `ReleaseNotesWindow` (new view + `Window` scene in `WorkdeckApp`) | §2.2. |
| `SettingsView` About | §2.1. |
| `PopoverView` | §2.4. |
| Notch | §2.3: an update alert in the notch's alert model, shown once per version (remembered key), opening Release Notes on click; not tied to an agent. |
| `Makefile` | `release-prep` (§4). |
| `.github/workflows/release.yml` | §5. |
| `CHANGELOG.md`, `CLAUDE.md` rule | §3. |

- Tests never touch the network or Sparkle's real updater: `UpdateController`'s logic is tested through the `Updating` protocol and fakes; Sparkle is not started when `XCTestConfigurationFilePath` is set (as `AppDelegate` already does for the helper).
- Demo mode does not show the update alert or row.

## 8. Stages

1. **In the app:** Sparkle, `UpdateController`, About rows, Release Notes window, popover row, notch alert, `CHANGELOG.md`, the CLAUDE.md rule, `make release-prep`, versions. Testable with a locally made appcast and zip served from a local folder or a test release.
2. **CI release:** the workflow, secrets, keys, the first real release `v1.1.0`, the manual checks of §6 with a `v1.1.1` made only to test updating.

## 9. Pricing and Dependencies

- **Sparkle:** MIT, free; a framework of a few MB inside the app. SPM, "Up to Next Minor" from the current 2.x release. Agreed with the user on 2026-11-04 (CLAUDE.md requires agreement for new dependencies); CLAUDE.md's Conventions line about agreed exceptions gains Sparkle.
- **GitHub Releases and Actions macOS runners:** free for a public repository.
- **Monthly cost:** $0 now; $0 in a year at any number of colleagues. The only yearly cost is renewing the Apple Development certificate (part of the author's existing setup).

## 10. Edge Cases

| Condition | Behavior |
|---|---|
| No network, GitHub down | Scheduled checks fail quietly; Check for Updates shows Sparkle's error window; About keeps `Version 1.2.0`. |
| The appcast or zip is not signed with the release key | Sparkle refuses the update and says so in its window; nothing installs. |
| Workdeck runs from somewhere other than /Applications | Sparkle updates it where it is; the helper and hook paths are then wherever it runs (as today). |
| An update is found while the demo plays | No alert during the demo and the row waits; when the demo ends, the alert shows (a held-back alert does not count as shown) and the row appears. |
| The user skips 1.3.0, then 1.3.1 comes out | 1.3.1 alerts once and shows the row again. |
| Remind Me Later | The row stays; no second notch alert for that version. |
| A colleague still on 1.0 (no Sparkle) | Nothing happens until they install 1.1.0 by hand. |
| The changelog in the app has no section for the installed version (a local build) | The window lists what it has; nothing is tagged installed. |

## 11. Testing

- `Changelog`: sections and dates, groups, unknown headings and lines ignored, `Unreleased` handling, an empty file.
- `UpdateController` with a fake `Updating`: states (idle, checking, up to date, available, skipped), the once-per-version alert memory across "relaunches" (a fresh controller with the same defaults), skip clears the row and a newer version brings it back, demo suppresses the alert.
- Views: the About row's states, the Release Notes window opening on the right version (controller-level tests where the view logic is not trivial).
- `release-prep`: run against a temporary copy (or a dry-run flag) to check the changelog and version edits and its refusals.
- Manual rows in `docs/testing.md`: check for updates with a local appcast, the notch alert once, the popover row, Install through Sparkle's window, Skip, Remind Me Later, Release Notes window, and the §6 survival checks on a real update.

## 12. Documentation

- `README.md`: install (download the zip from GitHub Releases, Open on first launch), updates in one line, the Release Notes window.
- `docs/releasing.md` (new): how to cut a release (`make release-prep`, push the tag), the secrets and keys and how to renew the certificate.
- `docs/testing.md`: §11 rows.
- `CLAUDE.md`: the changelog rule, Sparkle among the agreed dependencies, `Workdeck/Core/Updates/` in Architecture, Build and Test gets `make release-prep`.
- `TODO.md`: the "Updating an installed Workdeck, and CI" item points here; Distribution's Sparkle item is replaced by this spec.
