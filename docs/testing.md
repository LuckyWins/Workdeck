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
| 14 | Settings tiles | Open Settings. | Each section header has a colored icon tile: General gray gear, Closed-Lid Mode indigo laptop, Limits orange gauge, Sessions green terminal, Instances blue people, About gray info. |

Thermal cutoff is covered by unit tests only; it cannot be triggered reliably by hand.

## Claude Code Limits Checklist

Watch the snapshot with `cat ~/Library/Application\ Support/Workdeck/claude-usage.json` and the status line config with `grep -A3 statusLine ~/.claude/settings.json`.

| # | Scenario | Steps | Expected |
|---|---|---|---|
| L1 | Connect from popover | Turn on Claude Code in the popover. | Settings opens with "Changes to settings.json" under Status line: the diff adds `statusLine` (with the reformat note if the file was not written by Workdeck before); Connect adds `statusLine` pointing at `…/Contents/Helpers/workdeck-statusline`; backup file exists. |
| L2 | Connect from Settings | Click Disconnect… in Settings, then Disconnect; then click Connect…. | Disconnect… shows the diff removing `statusLine`; after Disconnect, Connect… shows the same block as L1. |
| L3 | Data arrives | Run a Claude Code session (Pro/Max) and send a message. | Claude Code's status line shows `5h N%`; the notch's ring shows the same (the percent only from the first threshold); popover row shows both windows and "updated just now". |
| L4 | Hover | Hover the compact notch, then move away. | Expands with both windows, reset times and age; collapses on exit. |
| L5 | Threshold alert | In Settings, set "First alert at" below the current usage. | The notch expands with "! 5-hour limit at 80%" ("… at 95%" for the second) for about 6 s, its mark a glowing badge that pulses three times (orange, red for the second threshold); when it closes, the compact ring flashes orange once (red for the second threshold); the indicator turns orange. Hovering still expands and collapses correctly. A wash in the alert's color rises from the bottom edge, and a thin bar at the bottom shrinks to nothing as the alert closes (it hides while the pointer is on the notch, and shows the time left when the pointer leaves; a second alert within 6 s starts it again from full). |
| L6 | When active | Set Show to "When active" with usage below the first threshold, no active session, and the pointer away from the notch; wait a minute after the last session finished. | Notch disappears completely (no empty pill); an alert from L5 shows it: the alert expands with its text, then the compact notch flashes its ring, and it hides again a minute later. |
| L7 | Lid closed | Connect an external display, close the lid. | Usage text appears next to the Workdeck icon; at or above the first threshold the icon becomes a warning triangle. Opening the lid brings the notch back. |
| L8 | Existing status line | With your own `statusLine` set, connect. | Claude Code shows `5h N% · <your output>`; Disconnect restores your original `statusLine` exactly. |
| L9 | Reset alert | Wait for (or simulate by editing `resets_at` in the snapshot to the past) a window that was above the first threshold. | When "Notify when a limit resets" is on, the notch expands with "5-hour limit reset · back to 0%" for about 6 s (a green glowing badge), then the compact ring flashes green once; nothing when it is off. A wash in the alert's color rises from the bottom edge, and a thin bar at the bottom shrinks to nothing as the alert closes (it hides while the pointer is on the notch). |
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
| L22 | Waiting for Claude Code | With "Fetch usage from Anthropic" on, quit every Claude Code window and wait until the token expires (`expiresAt`, about eight hours), or check the next morning. Then start Claude Code. | Each account shows `13h ago · waiting for Claude Code` in grey, no orange error and no second line; Settings shows "Waiting for Claude Code to renew its login". Within five minutes of Claude Code starting, the line returns to `updated … ago`. |

## Claude Code Sessions Checklist

Watch the event files with `ls -la ~/Library/Application\ Support/Workdeck/sessions` and the hooks with `python3 -c "import json,os; print(list(json.load(open(os.path.expanduser('~/.claude/settings.json'))).get('hooks', {})))"`.

| # | Scenario | Steps | Expected |
|---|---|---|---|
| S1 | Connect | Settings → Claude Code · Sessions → Connect…, confirm. | Eight hook events appear in `settings.json`, each with an async `workdeck-hook` entry; `settings.json.workdeck-backup` holds the previous file; other hooks are unchanged. |
| S2 | VS Code panel | Open a Claude Code panel in VS Code and send a message. | The compact notch shows `● 1` (green while working); the expanded notch lists the project as "working", then "idle" with a duration after the answer. |
| S3 | Terminal | Run `claude` in Terminal in another folder and send a message. | A second row appears; the counter shows 2. |
| S4 | Waiting for you | In a session without auto-approval, ask for a command that needs permission. | The row turns orange "waiting for you" and moves to the top; the dot is orange. After approving, it returns to "working". |
| S5 | Agents | Ask a session to use the Explore agent. | An indented row "Explore · <task>" appears under the session while it runs and disappears when it finishes. With three or more agents, at most two rows plus "+N agents". |
| S6 | Click to focus | Click the VS Code session row, then a Terminal session row while another Terminal window is in front. | The VS Code window with that project comes to the front; Terminal shows the session's own tab. |
| S7 | Closing | Close the VS Code panel tab; separately, `kill` a terminal `claude` process. | The closed session disappears at once; the killed one within 10 seconds. Their files are deleted. |
| S9 | Interrupt | Send a long task, press Esc while it works; separately, answer "No" to a permission prompt. Wait about a minute. | The session returns to "idle" within about 10 seconds, in VS Code and in a terminal, with no "finished" alert. |
| S10 | Actions and compacting | Ask a session to read a file and run a command; then run `/compact`. | The row shows `Read <file>` and `Bash <command…>` while each runs; an agent's row shows its own step; during `/compact` the dot turns cyan and the row says "compacting", and afterwards an idle session returns to idle. A command like `mysql -pSECRET` shows `-p…`. |
| S11 | Finished alert | Turn on "Notify when a session finishes", set 1 min; switch to another app; give a session a task longer than a minute. | When it finishes, the notch expands with "✓ <project> finished · worked 1m" for about 6 s (a green glowing badge; a click opens the project), then the session dot flashes green once (it shows for the flash even with no active session). A turn shorter than a minute shows nothing; with the session's app in front, nothing either. A wash in the alert's color rises from the bottom edge, and a thin bar at the bottom shrinks to nothing as the alert closes (it hides while the pointer is on the notch, and shows the time left when the pointer leaves; a second alert within 6 s starts it again from full). |
| S12 | Needs-you alert | Turn on "Notify when a session needs you"; switch to another app; trigger a permission prompt. | The notch expands with "! <project> needs you · permission prompt" for about 6 s, the `!` an orange glowing badge that pulses three times; when it closes, the session dot blinks orange three times. A wash in the alert's color rises from the bottom edge, and a thin bar at the bottom shrinks to nothing as the alert closes (it hides while the pointer is on the notch). |
| S13 | Keep awake | Turn on "Keep Mac awake while Claude works"; while a session works run `pmset -g assertions \| grep Workdeck`. | "Workdeck: Claude Code is working" is listed while it works and gone a moment after it finishes. |
| S14 | Agent cards | Start a background agent and a foreground agent in a session, then hover the notch. | Each agent shows two lines: type · model ("Opus" at once, "Opus 5.5" after its first answer), `bg` on the background one, duration; then its current action and `N steps`. |
| S15 | Stopped background agent | Start two background agents, then ask Claude to stop one of them. | At the end of that turn the stopped agent disappears from the notch; the other stays. |
| S16 | Copy Diagnostics | Use Claude Code for a while, then Settings → About → Copy Diagnostics and paste into a text editor. | Version, connection states, settings, each session with status and agents (type, model, bg, steps), and log lines such as `vitastir (bd7757df): working → idle` and `Workdeck: finished after 3m, below 10m`. No prompts, actions or descriptions. Live: `/usr/bin/log stream --predicate 'subsystem == "com.appcreators.workdeck"'`. |
| S17 | Agent names and alert clicks | Start a general-purpose agent with a task, and a custom agent; switch away until a session needs you, then click the alert line. | Agents are named by their task; only the custom one shows its type. Clicking the needs-you alert opens that project's window; in a batch each line opens its own. |
| S18 | Blank sessions | In VS Code, with a session already open in a project, open a new Claude Code tab in the same project and do not type anything; then send a prompt in it. | The empty tab does not add a second row with the same project name; it appears once the prompt is sent. After `/clear` in a terminal session, its row disappears until the next prompt. Reopening a VS Code window that revives an old Claude chat tab adds no row until that chat gets a prompt; `claude --resume` in a terminal likewise shows its row with the first prompt. |
| S19 | Event file size | Keep a session busy until its file in `~/Library/Application Support/Workdeck/sessions` passes 1 MB (or relaunch Workdeck with a larger file from an older build). | The file drops to about 500 KB and Diagnostics shows "trimmed its event file from … KB to … KB"; the session keeps its status and agents, and after quitting and reopening Workdeck it shows the same status, agents and actions. |
| S20 | List transitions | Start a session and an agent, then let the agent finish and the session end. | Rows slide and fade in when they appear and fade out when they leave; nothing animates while nothing changes. |
| S21 | Edit counts | Ask a session to edit a file (a few lines), overwrite another with Write, and create a new one; hover the notch while it works and after it stops. | Each edit shows `+N −M` matching Claude Code's "Added N lines, removed M lines" (a new file only `+N`); the session ends with `this turn · 3 files +… −…`, which becomes `last turn` after the Stop and disappears on the next prompt without edits. An agent's edit shows its counts on the agent's second line. |
| S22 | Step ticker | Give a session a task with several tool calls and hover the notch. | Under the session, up to three steps: finished ones faint with `✓`, the current one bright with `▸`; each new step slides in at the bottom while the oldest fades out; the row's right side says `working`; launching an agent adds no ticker line and leaves no step marked `▸` while the agent runs. |
| S23 | Focus | Give two sessions tasks a few seconds apart and hover the notch while both work. | Only the session started last has the ticker; it does not move to the other session on each action, and moves only when that session stops. The other session shows its action and counts in its row. |
| S24 | Diff tabs and secrets | With `personal` added, put `"env": {"ANTHROPIC_API_KEY": "sk-test"}` in `~/.claude/settings.json`, disconnect the hooks, then Connect…. | Tabs `main` and `personal`; each shows its own file; the key's value shows as `"…"`; after Connect the file still holds `sk-test`. |
| S25 | File changed while reviewing | Open Connect… for the hooks, then edit `~/.claude/settings.json` in a text editor and save; click Connect. | Nothing is written; the block shows "settings.json changed since this preview. Review the new changes." with the new diff; Connect then works. |
| S26 | One block at a time | Open Connect… for the status line, then Connect… for the hooks; close Settings with a block open and reopen it. | Opening the second closes the first; reopened Settings shows no block and nothing was written. |
| S27 | Terminal tab | Run `claude` in two Terminal windows (minimize one of them, the one to click) and in a second tab of one window; click each session row. | Each click restores and shows exactly that session's tab. The first click asks once whether Workdeck may control Terminal. |
| S28 | iTerm2 panes | In iTerm2, split a tab into two panes and run `claude` in the right one; click its row; then minimize that window and click again. | iTerm2 comes forward with that tab and the right pane selected; the minimized window is restored. |
| S29 | Automation denied | Deny the Automation prompt (or turn Workdeck off for Terminal in System Settings → Privacy & Security → Automation), then click a Terminal session. | Terminal is activated as before; Diagnostics shows "Terminal tab: AppleScript error -1743". Turning it back on makes the next click show the tab. |
| S30 | Ticker motion | Let a session run several tools in a row with the notch expanded. | A finished step moves up and shrinks a little, its ▸ turns into ✓; the new step slides in from below; the current step's text shimmers, and so does each running agent's current action; the list fades at its top and bottom edges. With Reduce Motion only ▸ → ✓ changes. |
| S31 | Turn cut short by a limit | Let a Claude Code session hit its 5-hour limit in the middle of a turn (or any API error). | The session turns idle at once, without a "finished" alert, instead of staying "working" with its last step. |
| S8 | Disconnect | Disconnect… in Settings, check the diff, then Disconnect. | The diff removes only Workdeck's hook entries; your own hooks stay; the sessions disappear from the notch. |
| R1 | Recap on Monday | Work with Claude Code for at least 15 minutes during a week; on the following Monday unlock the Mac (or set the clock forward and relaunch Workdeck). | The notch expands, with an indigo wash from below and a bar that shrinks over the minute, showing "last week · <dates>", the coding time in large type with a Monday–Sunday chart by project beside it, files, lines, commands, agents, longest work, top projects with a colored square each, limits, and Details… and Got it; after about a minute it collapses and the right wing shows ◆; hovering shows the recap; Got it removes it until next week. |
| R2 | Quiet week | A week with less than 15 minutes of work. | No recap on Monday. |
| R3 | Alerts during the recap | With "Notify when a session needs you" on and the first threshold set below the current usage, while the recap is expanded trigger a permission prompt (session's app in the background), then let a limit cross the threshold. | "Needs you" shows at once and the recap steps back to ◆; the limit alert waits for the recap's minute to end. |
| R4 | When active | Set Show to "When active" with nothing going on, then unlock on Monday. | The recap shows; afterwards the compact notch stays visible with ◆ until Got it. |
| R5 | Statistics from the popover | Click the chart button in the popover's header. | The window opens on this week with "· so far"; days after today are faint, today's label is bold; › and This Week are disabled; the numbers grow while a session works. |
| R6 | Week navigation | In the Statistics window click ‹ several times, then ›, then This Week. | ‹ steps back to the oldest week with data and then disables; › comes back; This Week jumps to the current week. |
| R7 | Day details | Hover a day's bar in the chart, then move the pointer away. | The header shows that day: "Coding time · Tue, Oct 13", its total in large type and "3 projects · 22m above the daily average"; the other bars dim; a tooltip beside the bar lists the day's projects. Away from the chart, the header shows the week again. |
| R8 | Details… | With a recap pending, hover the notch and click Details…. | The recap and ◆ go away; the Statistics window opens on last week. |
| R9 | Hooks off | Disconnect the session hooks and open the Statistics window. | It says "Coding time is counted while session hooks are connected."; Settings… opens Settings. |
| R11 | Two agents | Work with Claude Code and Codex in one week (both hooks connected), then see the recap on Monday (or Try Demo). | Under the sessions: "Claude … · Codex …" after their icons, each agent's own time; longest work has its agent's icon; limits end with "codex" after its icon and its 7d peak, without "5h hit" on a weekly-only plan. |
| R12 | Agent filter | Open Statistics on a week with both agents' work, pick Codex, then All; close and reopen. | Header, chart, projects, Work and Limits show Codex's own work only, an empty week says "No Codex work this week."; a project filter clears on the switch; the window reopens on All. With only one agent ever recorded there is no control. |
| R10 | Filter by project | In the Statistics window click a project in Most worked on, then click it again; then click another and use the chip's ×. | The row is highlighted and the others dim; Work shows that project's sessions, files, lines, commands and agents with a chip after its title and no Longest row; a second click or × shows all projects again. |

## Claude Code Instances and Chats Checklist

| # | Scenario | Steps | Expected |
|---|---|---|---|
| C1 | Add an instance | Settings → Claude Code · Instances → Add Instance… → `work` → Add. | `~/.claude-work` exists (`drwx------`), `~/.zshrc` ends with the `claude-work` alias marked `# Workdeck`, `~/.zshrc.workdeck-backup` holds the old file, and Terminal opens `claude` for the new folder. After `/login` and returning to Workdeck, the row says "Signed in as …". |
| C2 | Alias | Open a new Terminal window and run `claude-work`. | Claude Code starts signed in to the second account (`/status`). |
| C3 | Continue a chat | Popover → Chats… → hover a chat of `main` → Terminal → work. | Terminal opens in the project folder with `claude --resume <id>` on the second account and shows the chat's history; the row gets `→ work`. Messages sent there appear in the chat when it is resumed with `claude`. |
| C4 | Live warning | Continue a chat that is open in VS Code. | An alert names VS Code; Cancel does nothing; Continue Anyway continues. |
| C5 | Unlink and remove | Unlink the chat from work (confirm the alert); then Settings → Remove… work. | The link is gone from `~/.claude-work/projects/…` and the original transcript is untouched; the alias line is gone from `~/.zshrc`; `~/.claude-work` stays. |
| C6 | Unusual paths | Continue a chat whose project folder name has spaces or quotes; add an instance while `~/.zshrc` is a symbolic link (dotfiles). | Terminal opens in the right folder; the alias is written into the linked file and the link stays. |
| C7 | Open in VS Code | Follow Settings → Instances → personal → VS Code…; then in Chats use VS Code → personal on a main chat. | The project opens in a window of the `Claude personal` profile; the Claude panel's history lists the chat and `/status` shows the second account; other VS Code windows stay on the main account. |
| C8 | Default account | Chats → hover a project header → `…` → Default Account → personal; click Terminal, then VS Code on one of its chats; then set Ask Each Time. | With personal set, both buttons open on personal at once and their help names it; a chat row's `…` holds only link actions; another project still asks; after Ask Each Time the chooser returns. |
| C9 | New chat in a project | Hover a project header (also with its chip selected) → Terminal → work; then VS Code → work. | Terminal opens in the project folder running `claude` on work without `--resume`; VS Code opens the project in the `Claude work` window; no chat gets linked. With the project folder deleted, both buttons are disabled. |

## Claude Code Accounts Checklist

| # | Scenario | Steps | Expected |
|---|---|---|---|
| A1 | Existing instance connects | With Limits and Sessions connected and `personal` added before this build, `make install` and launch. | `~/.claude-personal/settings.json` gets `workdeck-statusline --instance personal` and `workdeck-hook --instance personal` entries and a `.workdeck-backup`; the Instances row says `Limits ✓ · Sessions ✓`. |
| A2 | Two limits blocks | Use `claude-personal` until its status line has run, or turn on Fetch usage from Anthropic. | The expanded notch shows `— limits · main —` and `— limits · personal —`; the compact notch shows a purple `P` badge after the ring for the personal account and none for main, following the latest session. |
| A3 | Session tag | Start a session with `claude-personal`. | Its row in the notch has a purple `personal` tag; main sessions have none. |
| A4 | Limit alert | Lower the first threshold below an account's usage. | The notch expands with the alert and the account (`· personal`) for about 6 s, a click opens Chats on that account's latest session; then the compact ring flashes orange once. |
| A5 | Remove | Settings → Remove… personal. | Its entries leave `~/.claude-personal/settings.json` (previous status line restored), `claude-usage-personal.json` is deleted, and its block and tag disappear. |
| A6 | Account without sessions | With two accounts, work in one of them only and hover the notch. | The working account has its full block; the other is one dim line after it (`personal  7d 34% · 5h 12%` and its age, e.g. `13h ago`), without a waiting or refresh line. With no session at all, the compact notch's account has the full block. |

## Demo Mode Checklist

| # | Case | Steps | Expected |
|---|------|-------|----------|
| D1 | Start | Settings → General → Try Demo. | The notch expands for 6 s without a countdown bar, then the script of `specs/2026-10-14-demo-mode-design.md` §2.2 runs; Settings shows the seconds left beside Stop Demo, and the popover header shows `Demo · 54 s` with Stop. |
| D2 | Without a notch | With "Without a notch → Menu bar text" on a Mac without a notch (lid closed), Try Demo, then Stop Demo. | The virtual notch shows during the demo; the menu bar text returns at stop. |
| D3 | A full run | Watch one minute without touching the notch. | needs you (orange, 20 s), the threshold alert (30 s), finished (green, 42 s), the recap (indigo, 50–60 s, its bar runs out at 60 s); then the demo stops, the real notch returns and Settings shows Try Demo again. |
| D4 | Stop | Stop from Settings, then start and stop from the popover; quit during the demo and relaunch. | The real notch comes back at once, no real alert bursts out; after a relaunch the demo is off. |
| D5 | Real work during the demo | Run a Claude Code session while the demo plays, then stop. | The demo shows only its own sessions; after stop the real session is listed, and the Statistics window counts its time. |

## Notch Settings Checklist

| # | Case | Steps | Expected |
|---|------|-------|----------|
| N1 | Settings moved | Open Settings; check the Notch section; change Show, the alert thresholds, the forecast and Keep Mac awake; relaunch Workdeck. | The Notch section sits after Closed-Lid Mode with Show, Without a notch (lid closed only), both alert thresholds, reset alert, forecast, finished and needs-you alerts, haptic feedback and keep-awake; the Claude Code sections no longer have them. Every change shows at once in the notch (and `pmset -g assertions` for keep-awake) and survives the relaunch, as do the values chosen before this version. |
| N2 | Haptics | On a Force Touch trackpad: hover the compact notch until it opens; with a finger resting on the trackpad, let a needs-you alert come up (or run the demo); hover the open alert; turn off Settings → Notch → Haptic feedback and repeat. | A light tap when hover opens the notch, a stronger one when the alert comes up, nothing when hovering the open alert or on collapse; with the switch off, nothing taps. |

## Codex Checklist

| # | Case | Steps | Expected |
|---|------|-------|----------|
| X1 | Limits without a session | Turn on Codex in the popover with no Codex session running. | A `codex` block (plan Pro Lite or yours, weekly bar, `N free resets`); Settings → Codex shows Installed and the version. |
| X2 | Limits after a turn | Run one Codex turn (CLI or VS Code). | The block's age resets to `updated just now` within a second or two of the turn ending. |
| X3 | Both agents | Work in Claude Code with Codex on. | Blocks start with the Claude and Codex icons; session dots become the agents' icons; the compact notch shows the icon before the ring; a Codex alert starts with the Codex icon and opens nothing on click. |
| X4 | Codex off | Turn Codex off. | The notch looks exactly as before Codex: no marks, no Codex block. |
| X5 | Not installed | On a Mac without Codex (or rename `~/.codex` while Workdeck is quit), turn Codex on. | Row says `Codex not found`, no block, no crash. |
| X6 | Connect hooks | Settings → Codex → Session hooks → Connect…; confirm the diff; start a new Codex session in the CLI and one in VS Code. | `~/.codex/hooks.json` has ten Workdeck entries and a backup exists; both sessions appear with the Codex icon and their steps; clicking one brings its window or tab forward. |
| X7 | Permission, agent, patch | In a Codex session ask for a network command (approve it), an agent that counts files, and an edit of a project file. | "needs you" (with the Codex icon) while the prompt is open, then working; the agent appears under the session with its own step; the edit shows `Edit <file> +N −M` and the turn total. |
| X8 | Full Codex rows | In a new Codex chat ask for an edit of one file, then one patch of two files, then two agents spawned in parallel. | `Edit <file> +N −M`, then `Edit 2 files +N −M`, the turn's total with both files; the agents named after their tasks (`Count swift files`), with their model, no `default`. |
| X9 | Running sessions | Connect the hooks while a Codex session runs. | That session does not appear until it restarts; nothing else changes. |
| X10 | Disconnect | Settings → Codex → Disconnect…; confirm. | Only Workdeck's entries leave `hooks.json`; other hooks stay; Codex sessions disappear from the notch. |
| X11 | Agent icons | Turn on both agents; work in one session of each; let a limit cross the first threshold (or set it lower); open Statistics with both agents' weeks. | Blocks, session rows, alerts, the recap and Statistics show the Claude rays (terracotta) and the Codex circle (mint); a working session's icon pulses, a waiting one stays full, an idle one is dim; the compact notch shows the icon, the ring and a `P` badge for an extra account, and the percent only from the orange ring on (`7d` alone below it for the weekly window); the menu bar text (no notch screen) keeps `✳`/`◎`. |

## Virtual Notch Checklist

| # | Case | Steps | Expected |
|---|------|-------|----------|
| V1 | Monitor only | Close the lid with an external monitor connected and Closed-Lid Mode on. | A black notch sits over the menu bar at the top center of the monitor with the ring (and the percent from the first threshold) and session counters; hovering expands it; alerts expand it with their text, then flash its ring or dot. |
| V2 | Full screen | Put an app into full screen on the monitor, then two apps in Split View; trigger a "needs you" alert (a permission prompt with the session's app in the background), then a limit alert. | The notch disappears in the full-screen and Split View Spaces; each alert still expands it with its text, then it hides again with no flash; leaving full screen brings the compact notch back. |
| V3 | Monitor unplugged and back | Unplug the monitor (lid closed), plug it back. | No notch while there is no display; it returns on the monitor. |
| V4 | Lid opened | Open the lid with the monitor connected. | The notch moves to the MacBook's camera housing; the monitor shows none. |
| V5 | Menu bar text | Settings → Without a notch → Menu bar text; then back to Virtual notch. | The notch disappears and `5h 42%` shows next to the Workdeck icon; switching back restores the virtual notch at once. The picker is hidden while the lid is open. |
| V6 | Auto-hidden menu bar | System Settings → Control Center → Automatically hide and show the menu bar → Always; look at the top center of the monitor; then set it back. | Note whether the compact virtual notch is visible. A known limitation: it may be invisible; Menu bar text is the workaround. |
| V7 | Hover delays | Move the pointer quickly across the notch (on the virtual notch, along the menu bar); rest on its edge and wiggle. | Passing by does not expand it; resting expands it after a moment; a brief slip off the edge does not collapse it. |
| V8 | When active | Settings → Show → When active. Let a session finish; wait a minute; then point at the notch's place. | The notch stays about a minute after the session finishes, then hides; pointing at its place shows it, leaving hides it again. |

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

