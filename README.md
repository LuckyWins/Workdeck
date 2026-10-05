# Workdeck

A minimal macOS menu bar toolbox for developers.

## Features

### Closed-Lid Mode

Keeps your Mac awake while the lid is closed — for long builds, remote sessions over SSH, or carrying a working Mac in a bag.

- Toggle it from the Workdeck popover in the menu bar. The menu bar icon fills in while it is on.
- **Safeguards:** turns itself off when running on battery below a configurable threshold (20 % by default) and when the Mac gets too hot.
- **Sleep always comes back:** normal sleep is restored when Workdeck quits, crashes, or the Mac restarts.

> **Note:** While Closed-Lid Mode is on, macOS does not sleep at all — idle sleep and Apple menu → Sleep are disabled too. The display still turns off as usual.

## Requirements

- macOS 26 or later
- Xcode 27 to build

## Building

```bash
xcodebuild -scheme Workdeck -destination 'platform=macOS' build
xcodebuild -scheme Workdeck -destination 'platform=macOS' test
```

Or open `Workdeck.xcodeproj` and run the `Workdeck` scheme. Both the `Workdeck` and `WorkdeckHelper` targets are signed with team `U7HS7ZJUWC`; if you build with a different team, also update `teamIdentifier` in `Shared/HelperConstants.swift`.

Workdeck is not sandboxed and is not distributed through the Mac App Store.

## First Run

The first time you turn on Closed-Lid Mode, Workdeck registers its helper and macOS asks for approval:

1. Click **Open System Settings…** in the popover.
2. In **General → Login Items & Extensions**, allow Workdeck.
3. Reopen the popover and turn on Closed-Lid Mode.

## Settings

Open Settings from the gear button in the popover.

- **Launch at login**
- **Turn off below** — battery threshold, 10–50 %

## How It Works

Keeping a Mac awake with the lid closed requires the root-only `SleepDisabled` power setting (`pmset -a disablesleep 1`); the public power-assertion APIs used by `caffeinate` do not prevent clamshell sleep.

- **Workdeck** is the menu bar app. It owns all decisions: when to turn the mode on or off and which safeguards apply.
- **WorkdeckHelper** is a small launchd daemon registered with `SMAppService` that runs as root. It can only set `disablesleep` to 0 or 1 and report the current value. It accepts XPC connections only from Workdeck signed by the same team.

Sleep is restored in every exit path:

1. **Quit** — Workdeck turns the mode off before exiting.
2. **Crash or force quit** — the helper notices the dropped XPC connection and turns the mode off.
3. **Restart** — the helper starts at boot and resets the setting.
4. **Helper crash** — the relaunched helper resets the setting and Workdeck shows "Turned off: helper restarted".

## Uninstalling

1. Turn off Closed-Lid Mode and quit Workdeck.
2. In **System Settings → General → Login Items & Extensions**, turn off Workdeck.
3. Delete `Workdeck.app`.

If sleep ever stays disabled, reset it manually:

```bash
sudo pmset -a disablesleep 0
```

## Troubleshooting

- **Check the current state:** `pmset -g | grep SleepDisabled` — no output means sleep works normally.
- **"Couldn't change the sleep setting" after rebuilding in Xcode:** launchd may still be running an older helper build. Turn Workdeck off and on again in Login Items & Extensions. As a last resort, `sudo sfltool resetbtm` resets all background item approvals (for every app) and requires a restart.

## Project Structure

```
Workdeck/          Menu bar app (SwiftUI)
  App/             Scenes and top-level views
  Core/            Helper client and installer, settings
  Features/        One folder per tool
WorkdeckHelper/    Privileged launchd helper
Shared/            Code compiled into both the app and the helper
LaunchDaemons/     launchd job definition embedded in the app bundle
WorkdeckTests/     Unit tests (Swift Testing)
specs/             Design specs
plans/             Implementation plans
docs/              Other documentation, including the manual testing checklist
```
