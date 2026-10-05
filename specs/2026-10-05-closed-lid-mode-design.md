# Workdeck — Closed-Lid Mode Design

**Date:** 2026-10-05
**Status:** Approved for planning

## 1. Overview

Workdeck is a macOS menu bar utility for developers. It is designed to host a growing set of small tools; this spec covers the app shell and its first tool, **Closed-Lid Mode**, which keeps the Mac awake while the lid is closed.

### Goals

- Live in the menu bar only (no Dock icon). Clicking the icon opens a small popover.
- Toggle Closed-Lid Mode from the popover.
- Support two usage scenarios:
  - Mac on a desk with the lid closed, used remotely (SSH, long builds, agent sessions).
  - Mac carried in a bag while a long task keeps running.
- Never leave the Mac permanently unable to sleep: sleep is restored when the app quits, crashes, or the Mac reboots.
- Minimal UI that follows the Apple Human Interface Guidelines.
- English UI and documentation.

### Non-Goals (v1)

- Mac App Store distribution (the app is distributed directly).
- Timer-based auto-off, notifications, global hotkey.
- Auto-updates (Sparkle), notarization/release pipeline.
- iOS / visionOS targets.

## 2. Key Technical Constraint

Public power APIs (`IOPMAssertion`, as used by `caffeinate`) do not prevent clamshell sleep unless an external display and power are connected. The only reliable way to keep a Mac awake with the lid closed is the root-only system setting `SleepDisabled` (`pmset -a disablesleep 1`).

Therefore Workdeck ships a **privileged launchd daemon** registered via `SMAppService.daemon`. This requires the app to run **outside the App Sandbox**, which is acceptable because the app is not distributed through the Mac App Store.

Side effect: `disablesleep 1` disables system sleep entirely while active — idle sleep and Apple menu → Sleep also stop working. The display still turns off normally. This must be documented in the README.

## 3. Platform & Project Settings

| Setting | Value |
|---|---|
| Platform | macOS only (`SDKROOT = macosx`) |
| Deployment target | macOS 26.0 |
| Swift | Swift 6 language mode, strict concurrency |
| App default actor isolation | `MainActor` (helper: none) |
| App Sandbox | Off |
| Hardened Runtime | On |
| `LSUIElement` | `YES` |
| App bundle ID | `com.appcreators.workdeck` |
| Helper bundle ID / Mach service | `com.appcreators.workdeck.helper` |
| Development team | `U7HS7ZJUWC` |

Template cleanup: remove iOS/visionOS settings, rename `MyApp` to `WorkdeckApp`, delete `ContentView.swift`.

## 4. Architecture

Two targets plus a shared protocol file.

### 4.1 `Workdeck` (app)

| Unit | Responsibility |
|---|---|
| `WorkdeckApp` | `MenuBarExtra` (`.window` style) scene + `Settings` scene. Menu bar icon reflects mode state. |
| `LidSleepController` (`@Observable`) | Owns Closed-Lid Mode state; `enable()`, `disable(reason:)`, `refresh()`. Coordinates helper, monitors, and policy. |
| `SafeguardPolicy` | Pure logic. `canEnable(snapshot:threshold:)` and `evaluate(snapshot:threshold:)` → allow / cutoff(reason). |
| `PowerSourceMonitor` | Battery level + power source via `IOPSCopyPowerSourcesInfo` / `IOPSNotificationCreateRunLoopSource`. Emits `PowerSnapshot`. |
| `ThermalMonitor` | `ProcessInfo.thermalState` + `thermalStateDidChangeNotification`. |
| `HelperClient` | `NSXPCConnection` wrapper (async API, 5 s timeout, interruption/invalidation handling). |
| `HelperInstaller` | `SMAppService.daemon(plistName:)` register / unregister / status; opens System Settings → Login Items when approval is required. |
| `AppSettings` | Battery threshold (default 20 %, range 10–50 %, step 5) in `UserDefaults`; launch at login via `SMAppService.mainApp`. |
| Views | `PopoverView`, `ClosedLidModeRow`, `SettingsView`. |

`HelperClient`, `PowerSourceMonitor`, `ThermalMonitor`, and `HelperInstaller` are accessed through protocols so `LidSleepController` can be tested with fakes.

### 4.2 `WorkdeckHelper` (launchd daemon)

A command-line tool running as root.

- Listens on Mach service `com.appcreators.workdeck.helper` with `NSXPCListener`.
- Accepts connections only from a client satisfying:
  `identifier "com.appcreators.workdeck" and anchor apple generic and certificate leaf[subject.OU] = "U7HS7ZJUWC"`
  (via `NSXPCListener.setConnectionCodeSigningRequirement` / per-connection requirement).
- `PowerSettings` sets the mode via `/usr/bin/pmset -a disablesleep 0|1` and reads it by parsing `SleepDisabled` from `pmset -g`. Commands run through an injectable `CommandRunner`.
- On startup: runs `disablesleep 0`.
- Tracks which connection enabled the mode; when that connection is invalidated, runs `disablesleep 0`.
- Holds no policy and exposes no other operations. It never executes arbitrary commands.

### 4.3 Shared: `HelperProtocol.swift`

Compiled into both targets:

```swift
@objc protocol HelperProtocol {
    func setSleepDisabled(_ disabled: Bool, reply: @escaping (Error?) -> Void)
    func isSleepDisabled(reply: @escaping (Bool) -> Void)
    func version(reply: @escaping (String) -> Void)
}
```

### 4.4 Bundle Layout

```
Workdeck.app/Contents/
├── MacOS/
│   ├── Workdeck
│   └── WorkdeckHelper
└── Library/LaunchDaemons/
    └── com.appcreators.workdeck.helper.plist
```

The launchd plist contains `Label`, `BundleProgram` (`Contents/MacOS/WorkdeckHelper`), `MachServices` (`com.appcreators.workdeck.helper`), `RunAtLoad = true`, and `AssociatedBundleIdentifiers` (`com.appcreators.workdeck`).

### 4.5 Source Layout

```
Workdeck/
├── App/            WorkdeckApp, PopoverView, SettingsView
├── Features/
│   └── ClosedLidMode/   LidSleepController, SafeguardPolicy, monitors, ClosedLidModeRow
└── Core/           HelperClient, HelperInstaller, AppSettings
WorkdeckHelper/     main.swift, HelperService, PowerSettings, CommandRunner, launchd plist
Shared/             HelperProtocol.swift
WorkdeckTests/
```

## 5. User Interface

### 5.1 Menu Bar Icon

Template SF Symbol: `rectangle.stack` when idle, `rectangle.stack.fill` when Closed-Lid Mode is active.

### 5.2 Popover (~300 pt wide)

```
┌────────────────────────────────────────┐
│  Workdeck                          ⚙︎  │
├────────────────────────────────────────┤
│  [icon]  Closed-Lid Mode          [ ●] │
│          Mac won't sleep when the lid  │
│          is closed                     │
├────────────────────────────────────────┤
│  Quit Workdeck                    ⌘Q   │
└────────────────────────────────────────┘
```

- Header: app name + gear button (`SettingsLink`; the app activates itself so the Settings window comes to front).
- Each tool is one row: icon, title, `Toggle`, secondary-colored subtitle. Future tools are added as additional rows.
- Footer: Quit (⌘Q).

### 5.3 Closed-Lid Mode Row States

| State | Toggle | Subtitle |
|---|---|---|
| Helper not approved | Disabled | "Requires a one-time approval" + "Open System Settings…" button |
| Off | Off | "Mac sleeps normally when the lid is closed" |
| On (power adapter) | On | "Mac won't sleep when the lid is closed" |
| On (battery) | On | "Mac won't sleep when the lid is closed · Turns off below N% battery" |
| Cut off by battery | Off | "Turned off: battery below N%" |
| Cut off by heat | Off | "Turned off: Mac is too hot" |
| Cut off by helper restart | Off | "Turned off: helper restarted" |
| Enable refused (battery below threshold) | Off | "Battery is below N%" |
| Error | Reflects actual state | "Couldn't change the sleep setting" (red) |

A cutoff/refusal subtitle persists until the user toggles the mode again.

### 5.4 Settings Window

`Settings` scene, `Form` with `.grouped` style:

- **General** — Launch at login (off by default).
- **Closed-Lid Mode** — Picker "Turn off below" (10–50 %, step 5, default 20 %); footnote "Also turns off if the Mac gets too hot."; helper status with approval button when needed.
- **About** — app version.

## 6. Behavior & Data Flow

### 6.1 Enabling

1. If helper status is not `.enabled`: call `register()` and show the approval state.
2. Read current `PowerSnapshot` and thermal state; if `SafeguardPolicy.canEnable` refuses, show the refusal reason and stay off.
3. Call `helper.setSleepDisabled(true)`. On success set `isActive = true`; on failure set `lastError`.

### 6.2 Safeguards (while active)

Every monitor event runs `SafeguardPolicy.evaluate`. A `.cutoff(reason)` result calls `disable(reason:)`.

- **Low battery:** triggers only when on battery power and `percent < threshold`. Not applicable on Macs without a battery.
- **Thermal:** triggers on `.serious` or `.critical`.
- Enabling is refused under the same conditions.

### 6.3 State Synchronization

On app launch and every time the popover opens, the controller calls `isSleepDisabled` and displays the actual system state.

### 6.4 Restore-Sleep Guarantees

1. **Normal quit:** `applicationWillTerminate` calls `disable`.
2. **App crash / force quit:** helper detects invalidation of the enabling connection and runs `disablesleep 0`.
3. **Reboot:** helper runs at load (`RunAtLoad`) and resets to `disablesleep 0`.
4. **Helper crash:** app `interruptionHandler` reconnects; the relaunched helper resets to 0 on startup; app shows "Turned off: helper restarted".

### 6.5 Helper Versioning

After connecting, the app calls `version()`. If it differs from the app's bundle version, the app runs `unregister()` then `register()` to install the updated helper.

## 7. Error Handling

| Failure | Handling |
|---|---|
| Helper not registered / requires approval | Row shows approval state; toggle disabled. |
| XPC error or 5 s timeout | `lastError` shown; state re-queried. |
| `pmset` non-zero exit | Helper returns an error containing stderr; surfaced as `lastError`. |
| Unauthorized client | Helper rejects the connection. |
| Helper version mismatch | Re-register helper. |

## 8. Testing

**Unit tests (Swift Testing, `WorkdeckTests`):**

- `SafeguardPolicy` — table-driven: power source × charge × threshold × thermal state, for both `canEnable` and `evaluate`.
- `LidSleepController` — with fake helper client, installer, and monitors: enable success, refusal on low battery, battery cutoff, thermal cutoff, XPC error, helper interruption, approval-required state.
- `PowerSettings` — with fake `CommandRunner`: correct `pmset` arguments, `SleepDisabled` parsing from `pmset -g` output, non-zero exit mapped to error.

**Manual checklist (`docs/testing.md`)** for the root-level parts:

- First-run helper approval flow.
- Lid closed on battery: Mac stays awake (verify via SSH or a running task).
- `kill -9` the app → `pmset -g | grep SleepDisabled` reports `0`.
- Reboot with mode on → mode is off after boot.
- Battery cutoff at threshold (set the threshold just above the current charge, unplug).
- Thermal cutoff is covered by unit tests only; it cannot be triggered reliably by hand.
- Launch at login.

## 9. Documentation

- `README.md` (root, English): overview, features, requirements, building from source, first-run helper approval, how it works, safeguards, the full-sleep-disable side effect, uninstalling and manual reset (`sudo pmset -a disablesleep 0`), project structure.
- `CLAUDE.md` (root, English): guidance for AI coding agents working in the repo:
  - Project purpose and the "menu bar toolbox" direction (new tools are added as popover rows under `Features/`).
  - Build and test commands (`xcodebuild` for the `Workdeck` scheme, running `WorkdeckTests`).
  - Architecture map: app vs. privileged helper, shared XPC protocol, where each unit lives.
  - Conventions: Swift 6 strict concurrency, SwiftUI + Apple HIG, English-only UI/code comments/docs/commits, no third-party dependencies without discussion.
  - Helper rules: keep it minimal, no new XPC methods without a security review, never execute arbitrary commands, every enable path must have a restore-sleep path.
  - Repository layout for docs: specs in `specs/`, plans in `plans/`, other documentation in `docs/`, `README.md` in the root.
  - Manual verification: root-level behavior is checked via `docs/testing.md`.
  - Git: no `Co-Authored-By` trailers and no mention of Claude/AI tools in commit messages or PR descriptions.
- `docs/testing.md`: manual test checklist.

`README.md` and `CLAUDE.md` are created early in the implementation (once the project structure exists) and updated as the feature lands, so both stay accurate at every commit.
