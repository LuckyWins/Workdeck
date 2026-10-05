# Workdeck — Claude Code Limits Design

**Date:** 2026-10-05
**Status:** Approved for planning

## 1. Overview

The second Workdeck tool shows Claude Code subscription usage limits — the 5-hour window and the weekly (7-day) window — in a Dynamic Island–style indicator drawn over the MacBook notch, with a menu bar text fallback on screens without a notch.

### Goals

- See how much of the Claude Code limits is used without opening a terminal or running `/usage`.
- Avoid hitting a limit unexpectedly: alert at configurable thresholds and, optionally, when a limit resets.
- Two display modes, switchable in Settings: always visible, or only near limits.
- No credentials: read only data that Claude Code hands to a status line command.
- English UI and documentation; minimal, HIG-aligned look.

### Non-Goals (v1)

- Reading OAuth tokens or calling undocumented Anthropic endpoints.
- Estimating usage from `~/.claude/projects/**/*.jsonl` transcripts.
- API-key (Console) usage and cost.
- `CLAUDE_CONFIG_DIR` support (only `~/.claude/settings.json`).
- A floating notch on screens without a notch.
- System notifications.

## 2. Data Source

The only documented channel that exposes plan limits is the Claude Code status line (https://code.claude.com/docs/en/statusline). Claude Code runs the configured `statusLine` command and passes JSON on stdin containing:

- `rate_limits.five_hour.used_percentage`, `rate_limits.seven_day.used_percentage` — numbers 0–100.
- `rate_limits.five_hour.resets_at`, `rate_limits.seven_day.resets_at` — Unix epoch seconds.

Documented constraints:

- Present only for claude.ai Pro and Max subscribers, and only after the first API response in a session.
- Each window may be independently absent; Claude Code drops a window once its `resets_at` passes.
- Updates arrive only while a Claude Code session runs (on each assistant message, `/compact`, and when a window resets).

Consequences: Workdeck shows the last known values with their age, treats windows past `resets_at` as unknown, and explains when no data has arrived.

## 3. Architecture

### 3.1 Targets and Folders

| Item | Kind | Compiled into | Purpose |
|---|---|---|---|
| `WorkdeckStatusLine/` | new command-line tool target | `WorkdeckStatusLine` (and tests, except `main.swift`) | The status line command Claude Code runs. |
| `ClaudeUsage/` | new synchronized folder | `Workdeck`, `WorkdeckStatusLine` | Shared model, parser, window selection, formatting. |
| `Workdeck/Features/ClaudeLimits/` | app feature folder | `Workdeck` | Store, policy, presenters, connector, views. |

- `WorkdeckStatusLine` is embedded at `Workdeck.app/Contents/Helpers/workdeck-statusline`; the app target depends on it.
- `ClaudeUsage/` is **not** compiled into the privileged `WorkdeckHelper`, which stays minimal.
- `WorkdeckTests` additionally compiles `WorkdeckStatusLine/` sources except `main.swift`; it reaches `ClaudeUsage` types via `@testable import Workdeck`.

### 3.2 Dependency

DynamicNotchKit (https://github.com/MrKai77/DynamicNotchKit), MIT license, free. Added via Swift Package Manager with "Up to Next Minor" from `1.1.0`. This is an agreed exception to the "no third-party dependencies" rule and is recorded in `CLAUDE.md`.

Relevant API (v1.1.0): `DynamicNotch(hoverBehavior:style:expanded:compactLeading:compactTrailing:)`, `expand(on:)`, `compact(on:)`, `hide()`, published `isHovering`. The library tracks hover but does not expand on hover by itself; Workdeck observes `isHovering` and calls `expand`/`compact`. Content views are captured at init, so they must observe Workdeck's observable models to update.

### 3.3 Components

| Unit | Responsibility |
|---|---|
| `ClaudeUsage/UsageSnapshot` | `UsageWindow { kind: fiveHour/sevenDay, usedPercent: Double, resetsAt: Date }`, `UsageSnapshot { capturedAt: Date, fiveHour: UsageWindow?, sevenDay: UsageWindow? }`, Codable, file format version 1. |
| `ClaudeUsage/StatusLineInputParser` | Extracts windows from Claude Code status line JSON; returns `nil` when `rate_limits` is absent or malformed. |
| `ClaudeUsage/UsageFormatting` | Picks the most pressing window (higher percent; tie → 5-hour) and formats compact text (`5h 42%`, `7d 91%`). |
| `WorkdeckStatusLine` core | `run(stdin:now:paths:chain:) -> String`: parse, write snapshot atomically when data is present, build output, invoke the chained command. |
| `ClaudeUsageStore` (`@Observable`) | Watches the snapshot directory, decodes, drops expired windows, exposes `snapshot`, `currentWindows`, `age`. |
| `LimitsAlertPolicy` | Pure: threshold crossings (once per window period), reset notices, persistence of fired keys. |
| `LimitsPresentation` | Pure: decides notch compact / notch hidden / menu bar text / nothing from mode, notch availability, data, thresholds. |
| `NotchPresenter` | Wraps DynamicNotchKit: finds the notch screen, shows/hides compact view, expands on hover and for alerts. |
| `ClaudeCodeConnector` | Connect/disconnect the status line in `~/.claude/settings.json`, backup, chaining, path repair. |
| `ClaudeLimitsSettings` | Mode, thresholds, reset-notice toggle, feature enabled flag (UserDefaults). |
| Views | `ClaudeLimitsRow` (popover), notch compact/expanded/alert views, Settings section. |

All file-system, clock, and defaults access is injected so units are testable.

## 4. Status Line Command (`workdeck-statusline`)

On every invocation:

1. Read all of stdin.
2. Parse with `StatusLineInputParser`.
3. If windows are present: write the snapshot to `~/Library/Application Support/Workdeck/claude-usage.json` atomically (write a temporary file in the same directory, then rename). Create the directory if needed. If no windows are present, leave the existing snapshot untouched so the last known data survives.
4. If a chained command is configured in `~/Library/Application Support/Workdeck/statusline.json` (`{"version": 1, "chainedCommand": "<original command>"}`), run it through `/bin/sh -c` with the same stdin, with a 2-second timeout; capture its first output line.
5. Print the compact text for the most pressing window (if any), joined with the chained output by ` · `. Print nothing if both are empty.
6. Always exit 0. Any error (bad JSON, write failure, chained command failure or timeout) is swallowed; Claude Code's status line must never break.

Concurrent sessions write the same file; last write wins. Limits are per account, so this is correct.

Performance target: well under 100 ms for the command itself (excluding the chained command).

## 5. App Behavior

### 5.1 Store

- Watches the snapshot's directory with a `DispatchSource` (atomic rename replaces the file, so the file itself cannot be watched) and reloads on change.
- A 60-second timer recomputes age and window expiry.
- A window whose `resetsAt` is in the past is treated as unknown: shown as "—" with "reset at HH:MM" until new data arrives.
- A corrupt snapshot file keeps the last good snapshot in memory.

### 5.2 Compact Indicator

- Shows the most pressing current window: `5h 42%`.
- Color: primary (white on the notch) below the first threshold, orange from the first, red from the second.
- No current data: "—" dimmed in "Always" mode; hidden in "Only near limits" mode.

### 5.3 Alerts

- **Threshold:** fires when a window's percent reaches a threshold. Each threshold fires once per window period, keyed by `(window kind, resetsAt, threshold)`. Fired keys are persisted in UserDefaults so relaunching does not repeat them. If the app starts already above a threshold, it fires once.
- **Reset:** when enabled, fires "5-hour limit reset" (or "Weekly limit reset") when a window that had reached the first threshold resets (its `resetsAt` passes or a new `resetsAt` arrives).
- **Presentation:** the notch expands for 6 seconds with the alert, then returns to compact ("Always") or hides ("Only near limits"). In the menu bar fallback, alerts are not shown separately; the text and its color reflect the state.

### 5.4 Hover

While the pointer is over the notch, it is expanded with details; on exit it returns to compact.

### 5.5 Screen Selection

- The notch is used on the screen with a camera housing (`safeAreaInsets.top > 0`).
- With no such screen (external display only, lid closed, or a Mac without a notch), the menu bar fallback is used: text `5h 42%` next to the Workdeck icon. "Always": always shown when the feature is enabled. "Only near limits": shown only while the first threshold is reached. If macOS ignores text color in the menu bar, the threshold state is shown by switching the symbol to `exclamationmark.triangle` instead.
- Screen configuration changes (`NSApplication.didChangeScreenParametersNotification`) re-run screen selection.

### 5.6 Connecting to Claude Code

**Connect** (from the popover toggle's first enable or Settings):

1. Show a confirmation: "Workdeck will add a status line command to ~/.claude/settings.json. A backup will be saved next to it." — Connect / Cancel.
2. Read `~/.claude/settings.json`. If it does not exist, start from `{}`. If it is not valid JSON, refuse: "Fix ~/.claude/settings.json first."
3. Copy the existing file to `~/.claude/settings.json.workdeck-backup`.
4. If a `statusLine` exists and its command is not Workdeck's, save it as the chained command in `statusline.json`.
5. Set `statusLine` to `{"type": "command", "command": "<app path>/Contents/Helpers/workdeck-statusline"}`. Only the `statusLine` key changes; key order and formatting may change because the file is re-serialized.

**Disconnect** restores the chained command as `statusLine` (or removes the key) and deletes `statusline.json`.

**On launch:** if `statusLine.command` points at a `workdeck-statusline` path other than the current bundle's, update it. If the key no longer points at Workdeck, the connection status becomes "Not connected".

If the embedded binary is missing, Connect is disabled with an error.

## 6. User Interface

### 6.1 Notch

- **Compact:** leading `gauge.with.dots.needle.50percent`; trailing `5h 42%` in monospaced digits, colored by threshold.
- **Expanded (hover):**

```
 5-hour    ████████░░░░░░  42%
           resets in 1h 20m
 Weekly    ███░░░░░░░░░░░  18%
           resets Thu 09:00
 Updated 3 min ago
```

  Older than one hour: "Updated 2 h ago — open Claude Code to refresh".
- **Alert:** "5-hour limit at 80%" / "Resets at 14:00"; reset: "5-hour limit reset".

### 6.2 Popover Row

Same style as Closed-Lid Mode: icon, "Claude Code Limits", toggle (shows/hides the indicator), subtitle:

| State | Subtitle |
|---|---|
| Not connected | "Not connected to Claude Code" |
| Connected, no data yet | "Waiting for data — start a Claude Code session" |
| Connected, no data 24 h after connecting | "Requires a Claude Pro or Max plan" |
| Data | "5h 42% · 7d 18% · updated 3m ago" |

The first enable while not connected runs the Connect confirmation. Turning the toggle off only hides the indicator; it does not disconnect Claude Code (use Settings → Disconnect).

### 6.3 Settings Section "Claude Code Limits"

- **Show:** "Always" / "Only near limits" (default "Always").
- **First alert at:** 50–95 %, step 5, default 80 %.
- **Second alert at:** above the first, up to 100 %, step 5, default 95 %.
- **Notify when a limit resets:** toggle, default on.
- **Claude Code:** "Connected" / "Not connected", Connect… / Disconnect button; footnote with the backup path.

## 7. Error Handling

| Failure | Handling |
|---|---|
| Bad or unexpected stdin JSON | Snapshot untouched; print chained output or nothing; exit 0. |
| Snapshot write fails | Create directory and retry once; otherwise continue silently. |
| Chained command fails or exceeds 2 s | Ignore its output; continue. |
| Corrupt snapshot in the app | Keep last good snapshot; treat file as no data. |
| `settings.json` invalid JSON | Connect refuses with a message; file untouched. |
| Embedded status line binary missing | Connect disabled with an error. |
| No notch screen | Menu bar fallback. |

## 8. Testing

**Unit tests (Swift Testing):**

- Parser: both windows, one window, no `rate_limits`, malformed JSON, integer and fractional percents.
- Window selection and compact formatting (table-driven).
- `LimitsAlertPolicy`: crossing, once per period, persisted keys across instances, start above threshold, reset notice only after the first threshold, reset notice disabled.
- Status line core: snapshot written only with data, atomic replacement, output composition, chained command success / failure / timeout.
- `ClaudeUsageStore`: reads from a temporary directory, expiry and age with an injected clock, corrupt file keeps last good snapshot.
- `ClaudeCodeConnector` on a temporary directory: no file, other keys preserved, foreign status line chained and restored, invalid JSON refused, stale path repaired.
- `LimitsPresentation`: mode × notch availability × data × thresholds.

**Manual checklist** additions in `docs/testing.md`: notch appearance, hover expansion, threshold alert, reset alert, lid-closed menu bar fallback, connect and disconnect with a real Claude Code session, chaining with an existing status line.

## 9. Documentation

- `README.md`: feature description, connecting to Claude Code, what is changed in `settings.json`, how to disconnect, data limitations (Pro/Max only, updates only during sessions).
- `CLAUDE.md`: `WorkdeckStatusLine` target and `ClaudeUsage/` folder, the DynamicNotchKit exception, the rule that the status line command must always exit 0.
- `docs/testing.md`: manual scenarios above.
