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
| 3 | Lid closed on adapter | With the mode on, start `ping 1.1.1.1` in Terminal (or an SSH session from another machine), close the lid for 2 minutes, open it. | The ping (or SSH session) kept running without a gap. |
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
