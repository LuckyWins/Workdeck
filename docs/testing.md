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
| L1 | Connect from popover | Turn on Claude Code in the popover. | "Connect Claude Code?" alert appears; Connect adds `statusLine` pointing at `…/Contents/Helpers/workdeck-statusline`; backup file exists. |
| L2 | Connect from Settings | Disconnect, then click Connect… in Settings. | Same alert and result as L1. |
| L3 | Data arrives | Run a Claude Code session (Pro/Max) and send a message. | Claude Code's status line shows `5h N%`; the notch shows the same; popover row shows both windows and "updated just now". |
| L4 | Hover | Hover the compact notch, then move away. | Expands with both windows, reset times and age; collapses on exit. |
| L5 | Threshold alert | In Settings, set "First alert at" below the current usage. | Notch expands for ~6 s with "5-hour limit at N%", then returns; indicator turns orange. Hovering during or after the alert still expands/collapses correctly. |
| L6 | Only near limits | Set Show to "Only near limits" with usage below the first threshold. | Notch disappears completely (no empty pill); an alert from L5 still pops and hides again. |
| L7 | Lid closed | Connect an external display, close the lid. | Usage text appears next to the Workdeck icon; at or above the first threshold the icon becomes a warning triangle. Opening the lid brings the notch back. |
| L8 | Existing status line | With your own `statusLine` set, connect. | Claude Code shows `5h N% · <your output>`; Disconnect restores your original `statusLine` exactly. |
| L9 | Reset alert | Wait for (or simulate by editing `resets_at` in the snapshot to the past) a window that was above the first threshold. | "5-hour limit reset" appears once when "Notify when a limit resets" is on; nothing when it is off. |
| L10 | Moved app | Connect from the Xcode build, then run `make install` and launch from `/Applications`. | `statusLine` command is updated to the `/Applications` path on launch. |
| L11 | Quick pass over the notch | Brush the pointer quickly across the compact notch on the way to the menu bar, several times. | The notch never stays expanded after the pointer has left. |
| L12 | External display as main | With the lid open, make an external display the main display (Displays settings), then change its resolution or sleep/wake. | The compact notch stays on the built-in screen; no black pill appears on the external display. |
| L13 | Sleep/wake with lid closed | Lid closed on an external display (menu bar fallback active), sleep and wake the Mac. | No black pill at the top of the external display; the menu bar text remains. |
| L14 | Keychain access | In Settings, turn on "Fetch usage from Anthropic (unofficial)". | No Keychain prompt appears; Settings shows "Last fetched just now". |
| L15 | VS Code panel only | Disconnect the status line, keep the API toggle on, enable the indicator, work only in the VS Code extension panel. | The notch shows usage within one poll (≤ 5 min, or immediately on opening the popover); values match `/usage` in the panel. |
| L16 | Expired login | Wait for (or force, by signing out of Claude Code) an expired token. | Popover row and Settings show "Login expired — open Claude Code to refresh"; after Claude Code refreshes its login, the next poll shows data again without restarting Workdeck. |
| L17 | Token refresh | Keep the API on through a day of normal use (Claude Code refreshes its login about every 8 hours), including a night with the lid closed in Closed-Lid Mode. | No Keychain prompt at any point; `/usr/bin/log show --last 1d --predicate 'eventMessage CONTAINS "displaying keychain prompt"'` shows nothing for Workdeck. |
| L18 | Paused while locked | API on; lock the screen (Control-Command-Q) for 10+ minutes, then unlock and open Settings. | While locked, "Last fetched" ages past 5 minutes; within seconds of unlocking it shows "just now". |
| L19 | Refresh button | API on; hover the notch and click the refresh icon at the end of the "Updated …" line. Turn the API off and hover again. | A spinner replaces the icon briefly and the line shows "Updated just now"; the notch stays expanded while the pointer is over it; with the API off the icon is gone. |
| L20 | Settings layout | Disconnect the status line and turn the API off. Then turn either on. | Only "Status line" and the API toggle are shown; turning either on reveals Show, the alert pickers, the reset toggle and the forecast toggle. |
| L21 | Forecast | Use Claude Code heavily in a running 5-hour window, then hover the notch. Turn off "Forecast when limits run out". | When the limit would run out before the reset, the row shows "runs out ~HH:mm · resets HH:mm" with the first part orange; with the setting off, the usual "resets in …" text returns. |

## Claude Code Sessions Checklist

Watch the event files with `ls -la ~/Library/Application\ Support/Workdeck/sessions` and the hooks with `python3 -c "import json,os; print(list(json.load(open(os.path.expanduser('~/.claude/settings.json'))).get('hooks', {})))"`.

| # | Scenario | Steps | Expected |
|---|---|---|---|
| S1 | Connect | Settings → Claude Code · Sessions → Connect…, confirm. | Eight hook events appear in `settings.json`, each with an async `workdeck-hook` entry; `settings.json.workdeck-backup` holds the previous file; other hooks are unchanged. |
| S2 | VS Code panel | Open a Claude Code panel in VS Code and send a message. | The compact notch shows `● 1` (green while working); the expanded notch lists the project as "working", then "idle" with a duration after the answer. |
| S3 | Terminal | Run `claude` in Terminal in another folder and send a message. | A second row appears; the counter shows 2. |
| S4 | Waiting for you | In a session without auto-approval, ask for a command that needs permission. | The row turns orange "waiting for you" and moves to the top; the dot is orange. After approving, it returns to "working". |
| S5 | Agents | Ask a session to use the Explore agent. | An indented row "Explore · <task>" appears under the session while it runs and disappears when it finishes. With three or more agents, at most two rows plus "+N agents". |
| S6 | Click to focus | Click the VS Code session row, then the Terminal row. | The VS Code window with that project comes to the front; Terminal is activated. |
| S7 | Closing | Close the VS Code panel tab; separately, `kill` a terminal `claude` process. | The closed session disappears at once; the killed one within 10 seconds. Their files are deleted. |
| S9 | Interrupt | Send a long task, press Esc while it works; separately, answer "No" to a permission prompt. Wait about a minute. | The session returns to "idle" within about a minute (Claude Code's idle prompt). |
| S8 | Disconnect | Disconnect in Settings. | Only Workdeck's hook entries are removed; your own hooks stay; the sessions disappear from the notch. |

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

