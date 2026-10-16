# Closed-Lid Mode

Keeps your Mac awake while the lid is closed — for long builds, remote sessions over SSH, or carrying a working Mac in a bag.

- Toggle it from the Workdeck popover in the menu bar. The menu bar icon fills in while it is on.
- **Safeguards:** turns itself off when running on battery below a configurable threshold (20 % by default) and when the Mac gets too hot.
- **Remembered:** the mode stays on across restarts of Workdeck (a reinstall, a crash) and of the Mac until you turn it off, or a safeguard does; then you turn it on again yourself.
- **Sleep comes back when nothing watches over it:** quitting Workdeck restores normal sleep at once (the mode turns on again at the next launch), and so does the helper when Workdeck is gone for more than a minute.

> **Note:** While Closed-Lid Mode is on, macOS does not sleep at all — idle sleep and Apple menu → Sleep are disabled too. The display still turns off as usual.

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

Workdeck remembers that you want the mode and turns it on at every launch, after the usual safeguard check. Every exit path still ends with normal sleep unless a Workdeck takes the mode over:

1. **Quit** — Workdeck turns sleep back on before exiting; the next launch turns the mode on again.
2. **Crash or force quit** — the helper notices the dropped XPC connection and waits up to a minute for a new Workdeck to take the mode over, then turns sleep back on.
3. **Reinstall** (`make install`, which quits Workdeck with `pkill`) — Workdeck tells the helper it is restarting; when the new Workdeck replaces the helper, the old one leaves a short handover record (a deadline and the boot time, in a root-only folder) and the new one keeps sleep off until the new Workdeck takes over, for at most a minute.
4. **Restart** — the helper starts at boot and resets the setting (a handover record from before the restart is ignored); after login Workdeck turns the mode on again.
5. **Helper crash** — the relaunched helper resets the setting and Workdeck turns the mode on again.
6. **Helper stopped** — when launchd stops the helper without a restart announcement (for example, Workdeck is turned off in Login Items & Extensions), it resets the setting before exiting. The one exception: if Workdeck was killed and did not come back, and within that same minute the helper is stopped for good, sleep stays disabled until the helper runs again or `sudo pmset -a disablesleep 0`. A shutdown in that minute is the same case for the shutdown itself; the helper restores sleep when it starts at the next boot.

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
- **Helper logs:** every change and every safety-net restore is logged:

  ```bash
  /usr/bin/log stream --predicate 'subsystem == "com.appcreators.workdeck.helper"'
  /usr/bin/log show --last 1h --predicate 'subsystem == "com.appcreators.workdeck.helper"'
  ```
- **"Couldn't change the sleep setting" after rebuilding in Xcode:** launchd may still be running an older helper build. Turn Workdeck off and on again in Login Items & Extensions. As a last resort, `sudo sfltool resetbtm` resets all background item approvals (for every app) and requires a restart.
