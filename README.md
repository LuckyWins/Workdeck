# Workdeck

A minimal macOS menu bar toolbox for developers.

## Features

### Closed-Lid Mode

Keeps your Mac awake while the lid is closed — for long builds, remote sessions over SSH, or carrying a working Mac in a bag.

- Toggle it from the Workdeck popover in the menu bar. The menu bar icon fills in while it is on.
- **Safeguards:** turns itself off when running on battery below a configurable threshold (20 % by default) and when the Mac gets too hot.
- **Sleep always comes back:** normal sleep is restored when Workdeck quits, crashes, or the Mac restarts.

> **Note:** While Closed-Lid Mode is on, macOS does not sleep at all — idle sleep and Apple menu → Sleep are disabled too. The display still turns off as usual.

### Claude Code

#### Limits

Shows how much of your Claude Code plan limits you have used — the 5-hour window and the weekly window — in the MacBook notch, Dynamic Island style.

- The compact view shows a ring and the percent of the window closest to its limit, e.g. `42%` (labeled `7d 91%` when the weekly window is closer); hover to expand a terminal-style panel with a usage bar per window and when it resets.
- **Show:** "Always", or "When active": the notch appears while a session works or waits for you and while a limit is near, stays a minute after work ends, and shows when you point at its place. Hovering waits a moment before expanding and before collapsing, so passing the pointer by does not open it.
- Alerts at two configurable thresholds (80 % and 95 % by default) and, optionally, when a limit you came close to resets. A limit alert opens the notch with its text for a few seconds (`5-hour limit at 80%`, click it to open Chats), then flashes the compact notch's ring once in its color (orange, red, or green for a reset).
- A forecast in the expanded view, e.g. `runs out ~16:40 · resets 18:00`, when a limit will run out before it resets at your current pace (can be turned off in Settings).
- On a screen without a notch (an external display with the lid closed) the same notch is drawn at the top center of the main display as a virtual notch, and it hides while that display shows a full-screen app (alerts still appear). Settings → **Without a notch** switches to text next to the Workdeck icon in the menu bar instead.

**Connecting to Claude Code.** Turn on Claude Code in the popover (or click **Connect…** in Settings). Settings shows the change to each `settings.json` as a diff; after you click **Connect**, Workdeck adds its status line command to `~/.claude/settings.json` and saves a backup as `~/.claude/settings.json.workdeck-backup`. Only the `statusLine` key changes, but the file is re-written, so key order and formatting may change. If you already had a status line, Workdeck keeps running it and shows its output after the usage, e.g. `5h 42% · main`. **Disconnect…** in Settings shows its diff the same way and restores your previous status line.

**Limitations.** Claude Code reports plan usage through the status line only for Claude Pro and Max subscriptions, and only while a Claude Code session runs in a terminal (after the first response). The graphical panel of the Claude Code VS Code extension does not run the status line. Between sessions Workdeck shows the last known values and how old they are.

**Working only in the VS Code extension.** Turn on **Fetch usage from Anthropic (unofficial)** in Settings. Workdeck then reads the login token Claude Code stores in your Keychain (through the system `security` tool, so macOS does not ask for your password) and calls an undocumented Anthropic endpoint every 5 minutes, when you open the popover (at most once a minute), and when you click the refresh button in the expanded notch. Polling pauses while the screen is locked or asleep and catches up when you unlock. Workdeck never refreshes or stores the token. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working at any time; use this at your own discretion. Only Claude Code renews its login: while Claude Code is closed, or open but idle for hours, the token expires, and Workdeck stops calling the endpoint and shows "waiting for Claude Code" with the last figures until Claude Code runs again.

#### Sessions

Connect **Session hooks** in Settings to see every live Claude Code session in the expanded notch: whether it is working, waiting for you (a permission prompt), or idle, and which subagents are running inside it. The compact notch shows how many sessions are live (`●2`, orange when one waits for you) and how many subagents are running (`✦3`). In the expanded panel, agents appear as a tree under their session with a spinner, and working sessions pulse. File edits show the lines they added and removed (`+12 −3`), each session ends with its turn's total (`this turn · 5 files +84 −21`, `last turn` once it stops), and the session that most recently started working shows its last three steps, the current one brightest. Click a session to bring it to the front: VS Code, Cursor and Windsurf open the project's window; Terminal and iTerm2 show the session's own tab (macOS asks once whether Workdeck may control them); other terminals are activated.

Workdeck adds asynchronous hooks for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop`, `SubagentStart`, `SubagentStop`, `PreToolUse` and `PreCompact` to `~/.claude/settings.json` (with the same backup as the status line). The hook command, `workdeck-hook`, keeps only the event name, session and agent IDs, tool call IDs, the project folder, the agent type and task description, and which app hosts the session, in `~/Library/Application Support/Workdeck/sessions` (one file per session, deleted when the session ends and trimmed to its newest events above 1 MB). Prompts and answers are never stored; for tool calls only the tool name, a short target (file name, start of a command with secret-looking values masked, domain, search text) and, for file edits, how many lines were added and removed are kept. **Disconnect…** shows the diff and removes only Workdeck's hooks.

While a session works, its row shows what it is doing (`Bash xcodebuild -sch…`, `Read NotchPresenter.swift`), and agents show their own current step. Optional, all off by default in Settings: **Keep Mac awake while Claude works** (a standard power assertion, visible in `pmset -g assertions`; the display still sleeps and a closed lid still sleeps unless Closed-Lid Mode is on), **Notify when a session finishes** after it worked for at least the chosen time (10 minutes by default), which opens the notch with `<project> finished · worked 14m` for a few seconds (click it to bring the project's window forward) and then flashes the session dot green, and **Notify when a session needs you**, which opens the notch with the project's name for a few seconds (click it to bring the project's window forward) and then blinks the dot orange. Alerts are skipped while that session's app is in front.

#### Instances and Chats

Run a second Claude Code account side by side. In Settings → Claude Code · Instances, **Add Instance…** creates `~/.claude-<name>` (its own login, settings, skills and plugins — Workdeck copies none of them), adds `alias claude-<name>='CLAUDE_CONFIG_DIR="$HOME/.claude-<name>" claude'  # Workdeck` to `~/.zshrc` (backup: `~/.zshrc.workdeck-backup`), and opens Terminal so you can `/login`. **Remove…** deletes only that alias line; the folder and its login stay.

**Chats…** in the popover lists the chats of every instance by project, with their titles (read from the transcripts, shown only in the window, never stored or logged). **Terminal** (on hover) asks which account to open the chat with; another account gets the chat's transcript linked in with a hard link (a second name for the same file, so both accounts list it), then Terminal opens with `claude --resume`, so a chat goes on with the other account when a plan limit runs out; both instances then share one transcript. Workdeck warns before continuing a chat that is open somewhere else: writing to it from two places corrupts it. **Unlink** removes only the link. **VS Code** (on hover) asks for the account the same way and opens the chat's project in a VS Code profile named `Claude <instance>`, whose Claude Code extension runs on that account; set the profile up once with the steps behind **VS Code…** in the instance's row in Settings, then pick the chat in the Claude panel's history. Hovering a project's header offers **Terminal** and **VS Code** for a new chat in that project, and its `…` menu sets the project's **Default Account**: Terminal and VS Code, on the header and on its chats, then open on that account without asking, until it is set back to Ask Each Time.

With more than one instance, every instance gets Workdeck's status line and session hooks (`workdeck-statusline --instance <name>`, `workdeck-hook --instance <name>` in its own `settings.json`, with a backup), connected and disconnected together with the main one; instances added earlier are connected on the next launch. The expanded notch shows one limits block per account, the compact notch shows the account of your latest session with its first letter (`p 26%`), and sessions of an extra account carry a purple account tag. With "Fetch usage from Anthropic" on, each account is polled with its own Keychain item.

## Requirements

- macOS 26 or later
- Xcode 27 to build

## Building

```bash
make build     # Release build into ./build
make test      # run the unit tests
make install   # build, quit the installed Workdeck, copy it to /Applications, and launch it
               # (stops with an error if Workdeck is running from Xcode — stop it there first)
make clean     # remove ./build
```

Or open `Workdeck.xcodeproj` and run the `Workdeck` scheme. Both the `Workdeck` and `WorkdeckHelper` targets are signed with team `J55BY69CVU`; if you build with a different team, also update `teamIdentifier` in `Shared/HelperConstants.swift`.

Workdeck is not sandboxed and is not distributed through the Mac App Store.

`make install` produces a build signed with your Apple Development certificate. It runs on your own Mac; sharing it with others requires Developer ID signing and notarization, which this project does not set up yet.

macOS ties the helper approval to the app's location. After the first `make install`, approve Workdeck again in Login Items & Extensions; the copy Xcode runs from DerivedData stays listed there as a separate entry and can be turned off.

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
5. **Helper stopped** — when launchd stops the helper (for example, Workdeck is turned off in Login Items & Extensions), it resets the setting before exiting.

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
- **Claude Code tool:** Settings → About → **Copy Diagnostics** copies Workdeck's recent log and current state (no prompts, answers or tool details). Live log: `/usr/bin/log stream --predicate 'subsystem == "com.appcreators.workdeck"'`.

## Project Structure

```
Workdeck/          Menu bar app (SwiftUI)
  App/             Scenes and top-level views
  Core/            Helper client and installer, settings
  Features/        One folder per tool
WorkdeckHelper/    Privileged launchd helper
Shared/            Code compiled into both the app and the helper
LaunchDaemons/     launchd job definition embedded in the app bundle
ClaudeUsage/       Code shared by the app and the status line command
WorkdeckStatusLine/ Claude Code status line command (workdeck-statusline)
ClaudeHooks/       Code shared by the app and the hook command
WorkdeckHook/      Claude Code hook command (workdeck-hook)
WorkdeckTests/     Unit tests (Swift Testing)
specs/             Design specs
plans/             Implementation plans
docs/              Other documentation, including the manual testing checklist
```

## License

[MIT](LICENSE). "Claude" and "Claude Code" are trademarks of Anthropic; Workdeck is an independent project that works with Claude Code.
