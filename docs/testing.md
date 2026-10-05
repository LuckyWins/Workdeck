# Manual Testing

Root-level behavior cannot be covered by unit tests. Run this checklist after changing the helper, `HelperClient`, or `LidSleepController`.

Check the system setting at any point with:

```bash
pmset -g | grep SleepDisabled
```

`SleepDisabled 1` means sleep is disabled; no output (or `0`) means normal sleep.

## Setup

1. Build and run the `Workdeck` scheme from Xcode.
2. Make sure `pmset -g | grep SleepDisabled` prints nothing.

## Checklist

| # | Scenario | Steps | Expected |
|---|---|---|---|
| 1 | First-run approval | Open the popover, turn on Closed-Lid Mode. | Subtitle reads "Requires a one-time approval"; toggle is disabled; "Open System Settings…" opens Login Items & Extensions. |
| 2 | Approval picked up | Allow Workdeck in System Settings, reopen the popover. | Toggle is enabled; turning it on succeeds; menu bar icon becomes filled; `SleepDisabled 1`. |
| 3 | Lid closed on adapter | With the mode on, run `while true; do date +%T >> ~/lid-test.log; sleep 1; done` in Terminal, close the lid for 2 minutes, open it, check `tail -200 ~/lid-test.log` and `pmset -g log \| grep -E " Sleep \| Wake " \| tail -5`. | Timestamps continue through the closed-lid period (isolated one-second skips are loop drift, not sleep); no `Sleep` entry in that window. |
| 4 | Lid closed on battery | Unplug, repeat scenario 3. | Same as 3; subtitle mentions "Turns off below 20% battery". |
| 5 | Turn off | Turn the toggle off. | Icon becomes outline; `SleepDisabled` gone. |
| 6 | Quit restores sleep | Turn on, choose Quit Workdeck. | `SleepDisabled` gone. |
| 7 | Crash restores sleep | Turn on, then `pkill -9 -x Workdeck`. | `SleepDisabled` gone within a few seconds. |
| 8 | Reboot restores sleep | Turn on, restart the Mac without quitting Workdeck first. | After login, `SleepDisabled` gone. |
| 9 | Battery cutoff | On battery, set "Turn off below" just above the current charge in Settings while the mode is on. | Mode turns off; subtitle "Turned off: battery below N%". |
| 10 | Battery refusal | With charge below the threshold on battery, try to turn the mode on. | Toggle stays off; subtitle "Battery is below N%". |
| 11 | Helper restart | Turn on, then `sudo launchctl kickstart -k system/com.appcreators.workdeck.helper`, reopen the popover. | Mode is off; subtitle "Turned off: helper restarted"; `SleepDisabled` gone. |
| 12 | Launch at login | Enable "Launch at login" in Settings, log out and back in. | Workdeck icon appears in the menu bar. |
| 13 | Helper stopped | Turn on, then turn Workdeck off in **System Settings → General → Login Items & Extensions**. | `SleepDisabled` gone; the popover shows the approval state. |

Thermal cutoff is covered by unit tests only; it cannot be triggered reliably by hand.

## Claude Code Limits Checklist

Watch the snapshot with `cat ~/Library/Application\ Support/Workdeck/claude-usage.json` and the status line config with `grep -A3 statusLine ~/.claude/settings.json`.

| # | Scenario | Steps | Expected |
|---|---|---|---|
| L1 | Connect from popover | Turn on Claude Code Limits in the popover. | "Connect Claude Code?" alert appears; Connect adds `statusLine` pointing at `…/Contents/Helpers/workdeck-statusline`; backup file exists. |
| L2 | Connect from Settings | Disconnect, then click Connect… in Settings. | Same alert and result as L1. |
| L3 | Data arrives | Run a Claude Code session (Pro/Max) and send a message. | Claude Code's status line shows `5h N%`; the notch shows the same; popover row shows both windows and "updated just now". |
| L4 | Hover | Hover the compact notch, then move away. | Expands with both windows, reset times and age; collapses on exit. |
| L5 | Threshold alert | In Settings, set "First alert at" below the current usage. | Notch expands for ~6 s with "5-hour limit at N%", then returns; indicator turns orange. Hovering during or after the alert still expands/collapses correctly. |
| L6 | Only near limits | Set Show to "Only near limits" with usage below the first threshold. | Notch disappears completely (no empty pill); an alert from L5 still pops and hides again. |
| L7 | Lid closed | Connect an external display, close the lid. | Usage text appears next to the Workdeck icon; at or above the first threshold the icon becomes a warning triangle. Opening the lid brings the notch back. |
| L8 | Existing status line | With your own `statusLine` set, connect. | Claude Code shows `5h N% · <your output>`; Disconnect restores your original `statusLine` exactly. |
| L9 | Reset alert | Wait for (or simulate by editing `resets_at` in the snapshot to the past) a window that was above the first threshold. | "5-hour limit reset" appears once when "Notify when a limit resets" is on; nothing when it is off. |
| L10 | Moved app | Connect from the Xcode build, then run `make install` and launch from `/Applications`. | `statusLine` command is updated to the `/Applications` path on launch. |

## Results

Mark each run with the date, build commit, and macOS version. Record only scenarios that were actually executed.

### 2026-10-05 — commit `99dd67f`, macOS 27.0.1, MacBook Pro

| # | Result | Notes |
|---|---|---|
| 1 | ✅ Pass | Approval state shown after the team-ID and `.notFound` fixes. |
| 2 | ✅ Pass | Toggle became usable after approving in System Settings and reopening the popover. |
| 3 | ⏳ Not run | |
| 4 | ✅ Pass | On battery at 51 %, lid closed ~1.5 min: timestamp log continuous 16:18:27–16:20:15, no `Sleep` entry in `pmset -g log`. |
| 5–13 | ⏳ Not run | |

### 2026-10-05 — commit `0af2b9c`, installed with `make install` to `/Applications`

| # | Result | Notes |
|---|---|---|
| 1 | ✅ Pass | Re-approval requested for the `/Applications` copy; stale DerivedData helper was replaced automatically. |
| 2 | ✅ Pass | Mode toggles on and off; each change is logged by the helper with the client PID. |

