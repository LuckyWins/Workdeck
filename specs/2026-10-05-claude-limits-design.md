# Workdeck — Claude Code Limits Design

**Date:** 2026-10-05
**Status:** Approved for planning

## 1. Overview

The second Workdeck tool shows Claude Code subscription usage limits — the 5-hour window and the weekly (7-day) window — in a Dynamic Island–style indicator drawn over the MacBook notch, with a menu bar text fallback on screens without a notch.

### Goals

- See how much of the Claude Code limits is used without opening a terminal or running `/usage`.
- Avoid hitting a limit unexpectedly: alert at configurable thresholds and, optionally, when a limit resets.
- Two display modes, switchable in Settings: always visible, or only near limits.
- By default no credentials: read only data that Claude Code hands to a status line command. An opt-in second source (§10) covers working only in the Claude Code VS Code extension, whose panel does not run the status line.
- English UI and documentation; minimal, HIG-aligned look.

### Non-Goals (v1)

- Refreshing Claude Code's OAuth token or running Claude Code on the user's behalf.
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
| `WorkdeckStatusLine/` | new command-line tool target | `WorkdeckStatusLine` | Only `main.swift`: reads stdin, calls `StatusLineRunner`, prints. |
| `ClaudeUsage/` | new synchronized folder | `Workdeck`, `WorkdeckStatusLine` | Shared model, parser, formatting, snapshot file, chained command, and the `StatusLineRunner` logic. |
| `Workdeck/Features/ClaudeLimits/` | app feature folder | `Workdeck` | Store, policy, presenters, connector, views. |

- `WorkdeckStatusLine` is embedded at `Workdeck.app/Contents/Helpers/workdeck-statusline`; the app target depends on it.
- `ClaudeUsage/` is **not** compiled into the privileged `WorkdeckHelper`, which stays minimal.
- All status line logic lives in `ClaudeUsage/`, so `WorkdeckTests` reaches it via `@testable import Workdeck`. (Compiling the tool's sources into the test bundle as well would duplicate the shared types in two modules.)

### 3.2 Dependency

DynamicNotchKit (https://github.com/MrKai77/DynamicNotchKit), MIT license, free. Added via Swift Package Manager with "Up to Next Minor" from `1.1.0`. This is an agreed exception to the "no third-party dependencies" rule and is recorded in `CLAUDE.md`.

Relevant API (v1.1.0): `DynamicNotch(hoverBehavior:style:expanded:compactLeading:compactTrailing:)`, `expand(on:)`, `compact(on:)`, `hide()`, published `isHovering`. The library tracks hover but does not expand on hover by itself; Workdeck observes `isHovering` and calls `expand`/`compact`. Content views are captured at init, so they must observe Workdeck's observable models to update.

### 3.3 Components

| Unit | Responsibility |
|---|---|
| `ClaudeUsage/UsageSnapshot` | `UsageWindow { kind: fiveHour/sevenDay, usedPercent: Double, resetsAt: Date }`, `UsageSnapshot { capturedAt: Date, fiveHour: UsageWindow?, sevenDay: UsageWindow? }`, Codable, file format version 1. |
| `ClaudeUsage/StatusLineInputParser` | Extracts windows from Claude Code status line JSON; returns `nil` when `rate_limits` is absent or malformed. |
| `ClaudeUsage/UsageFormatting` | Picks the most pressing window (higher percent; tie → 5-hour) and formats compact text (`5h 42%`, `7d 91%`). |
| `ClaudeUsage/StatusLineRunner` | `run(stdin:now:) -> String`: parse, write snapshot atomically when data is present, build output, invoke the chained command. |
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

Concurrent sessions write the same file, so new data is merged into the existing snapshot rather than replacing it: an unexpired window missing from the input is kept, a later `resets_at` wins, and within the same period — reset times within 5 minutes of each other, since the status line and the usage API report them with different precision — the higher percent wins (usage never decreases within a period) while the existing reset time is kept so alerts see one stable period. This keeps an idle session from erasing or rolling back a window that another session is updating.

Performance target: well under 100 ms for the command itself (excluding the chained command).

## 5. App Behavior

### 5.1 Store

- Watches the snapshot's directory with a `DispatchSource` (atomic rename replaces the file, so the file itself cannot be watched) and reloads on change.
- A 60-second timer recomputes age and window expiry.
- Once any usage has been recorded, a window that is missing, has no reset time (the usage API returns `resets_at: null` before the first message), or whose `resetsAt` has passed is **not started**: shown as 0 % with "starts with your next message". A new window only begins with the next Claude Code message, so this is accurate. "—" is used only when nothing has ever been recorded.
- A corrupt snapshot file keeps the last good snapshot in memory.

### 5.2 Compact Indicator

- Shows the most pressing current window: `5h 42%`.
- Color: primary (white on the notch) below the first threshold, orange from the first, red from the second.
- No running window but data recorded: `5h 0%` with an empty green ring ("Always"); hidden in "Only near limits" mode.
- Nothing ever recorded: "—" dimmed in "Always" mode; hidden in "Only near limits" mode.

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

- **Compact:** leading — a progress ring (`UsageRing`) filled to the most pressing window's percent, green below the first threshold, orange from it, red from the second, dim white with no data; trailing — `5h 42%` in monospaced digits, white below the first threshold and orange/red above.
- **Expanded (hover):**

```
 ◔  5-hour                 42%
    resets in 1h 20m
 ◔  Weekly                 18%
    resets Thu 09:00
 Updated 3 min ago
```

  Each window has its own ring and percent, colored by that window's level (green / orange / red).

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

## 10. Amendment: Anthropic Usage API (Opt-In)

**Why:** the Claude Code VS Code extension's graphical panel does not run the `statusLine` command (confirmed by testing and by third-party extension authors), so a user who works only in the panel gets no data. Every comparable tool reads Claude Code's OAuth token from the Keychain and polls an undocumented endpoint. The user chose to add this as an opt-in source, accepting that Anthropic's terms ("developers may not collect, store, or intermediate Claude.ai credentials or session tokens") do not allow it and that the endpoint may change.

### 10.1 Endpoint (undocumented)

- `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <token>`, `anthropic-beta: oauth-2025-04-20`, `Accept: application/json`, timeout 15 s.
- Response: `{"five_hour": {"utilization": 21.0, "resets_at": "<ISO 8601>"}, "seven_day": {…}, …}`. `utilization` is a percent (0–100); `resets_at` is ISO 8601 (with or without fractional seconds); a window may be `null` or absent; other keys are ignored.
- Token: Keychain generic password, service `Claude Code-credentials`; its data is JSON with the token at `claudeAiOauth.accessToken`.

### 10.2 Components (`Workdeck/Features/ClaudeLimits/UsageAPI/`, app only)

| Unit | Responsibility |
|---|---|
| `ClaudeCredentials` | `accessToken(fromCredentialsJSON:)` (pure) and `KeychainCredentialsReader` (`SecItemCopyMatching`); errors: not found, denied, malformed. |
| `UsageAPIResponseParser` | Response body → `UsageSnapshot` (clamped percents, ISO dates, missing/null windows). |
| `UsageAPIClient` | Builds the request; 200 → snapshot, 401/403 → `loginExpired`, 429 → `rateLimited(retryAfter)` (from `Retry-After`, default 10 min), other → `failed`. Transport injected. |
| `UsagePoller` (`@Observable`) | Polls every 5 minutes while enabled; `pollIfStale()` on popover open at most once per minute; pauses until `retryAfter` after 429; merges results into the snapshot file with `UsageSnapshot.merged(with:now:)` (atomic write), so `ClaudeUsageStore` and everything downstream is unchanged. Exposes a status: idle, ok(fetchedAt), loginExpired, rateLimited(until), noCredentials, failed(message). |

### 10.3 Behavior Changes

- `ClaudeLimitsSettings.fetchFromAPI` (default off).
- The indicator may show when the status line is connected **or** `fetchFromAPI` is on.
- Enabling the popover toggle asks to connect the status line only when `fetchFromAPI` is off.
- The controller starts/stops the poller with the setting and calls `pollIfStale()` when the popover opens.
- Workdeck never refreshes the token and never runs Claude Code. On 401/403 it keeps polling every 5 minutes (Claude Code may refresh the token at any time) and shows the status.
- The token lives only in memory for one request; it is never written to disk, logged, or included in error text. Requests go only to `https://api.anthropic.com`.

### 10.4 UI

- Settings → Claude Code Limits: toggle **Fetch usage from Anthropic (unofficial)** with the footnote "Uses the login token Claude Code stores in your Keychain to call an undocumented Anthropic endpoint every 5 minutes. Anthropic's terms do not allow third-party use of Claude Code credentials, and the endpoint may change or stop working. macOS will ask for Keychain access — choose Always Allow." and a status line: "Last fetched 2 min ago", "Login expired — open Claude Code to refresh", "Rate limited — retrying at 14:20", "Claude Code login not found", or the error in red.
- Popover row: when the status line is not connected but the API is on, the subtitle shows data or the poller's problem instead of "Not connected to Claude Code".

### 10.5 Errors

| Failure | Handling |
|---|---|
| No Keychain item or access denied | `noCredentials`; keep polling on schedule. |
| 401 / 403 | `loginExpired`; keep polling every 5 minutes. |
| 429 | Wait for `Retry-After`, or 10 minutes. |
| Unparseable response | `failed("Unexpected response")`; snapshot untouched. |
| Setting turned off | Stop the timer; keep the snapshot. |

### 10.6 Testing

Unit: token extraction; response parsing (both windows, `null`, fractional-second dates, out-of-range values, extra keys); client with a fake transport (URL and headers, each status code, `Retry-After`, token never in error text); poller with a fake client, temporary directory and injected clock (merge into the snapshot, 5-minute interval, 1-minute popover throttle, 429 pause, statuses, stop on disable); controller (shows without the status line when the API is on, no connect prompt, poller problems in the subtitle). Manual (`docs/testing.md` L14–L16): Keychain prompt and Always Allow, data while working only in the VS Code panel, expired-token behavior.


## 11. Amendment: Keychain Access, Polling Pause, Manual Refresh, Settings Layout, Forecast

**Why:** Claude Code recreates its Keychain item when it refreshes the OAuth token (about every 8 hours). The new item's partition list no longer includes Workdeck's team, so the next background poll shows a Keychain prompt that asks for the login password, even overnight with the lid closed. `/usr/bin/security` is in the item's partition list (confirmed: `security find-generic-password -s "Claude Code-credentials" -w` succeeds without a prompt), so reading through it avoids the prompt entirely. The other changes came out of the same review.

### 11.1 Reading the Token

- `SecurityCLICredentialsReader` replaces `KeychainCredentialsReader` (the `SecItemCopyMatching` code is removed).
- It runs `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w` with fixed arguments, reads stdout through a pipe, discards stderr, and terminates the process after 10 seconds.
- Exit 0 → trim the trailing newline and extract the token with `ClaudeCredentials.accessToken(fromCredentialsJSON:)`; exit 44 → `notFound`; timeout or any other exit → `accessDenied`.
- Running the process sits behind a protocol, so tests never run the real `security` or touch the Keychain.
- The token never appears in process arguments, logs, or error text (§10.3 still applies).

### 11.2 Pausing While the Screen Is Locked or Asleep

- `SessionActivityMonitor` (behind a protocol) reports whether the user session is active. It observes the distributed notifications `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` and `NSWorkspace.screensDidSleepNotification` / `screensDidWakeNotification`. Closed-Lid Mode with the lid closed puts the displays to sleep; a closed lid with an external display in use keeps polling.
- While inactive, `UsagePoller` skips its timer ticks and `pollIfStale()`. When the session becomes active again, the controller calls `pollIfStale()`.
- The status line is unaffected.

### 11.3 Manual Refresh

- Popover row: a small borderless `arrow.clockwise` button in the secondary color, left of the toggle, help text "Refresh usage". Shown only when `fetchFromAPI` is on; a small progress indicator replaces it while a fetch is in flight; disabled while a 429 pause is active.
- It calls `UsagePoller.refreshNow()`: polls immediately regardless of the 1-minute throttle and clears the Keychain denial block. It still respects the 429 pause and never starts a second fetch while one is in flight.
- The `keychainDenied` status text becomes "Keychain access denied — click Refresh to try again".

### 11.4 Settings Layout

The section lists data sources first; the rest appears only when at least one source is on (`hasDataSource`):

```
Claude Code Limits
  Status line                     [Connect…] / [Disconnect]
  Fetch usage from Anthropic (unofficial)   [toggle]
    <poller status>
  — only with a data source —
  Show                            Always ▾
  First alert at                     80% ▾
  Second alert at                    95% ▾
  Notify when a limit resets      [toggle]
  Forecast when limits run out    [toggle]
```

The footers stay; the API footnote drops "macOS will ask for Keychain access — choose Always Allow."

### 11.5 Forecast

- `ClaudeLimitsSettings.showForecast`, default on.
- `UsageWindowKind.duration`: 5 hours or 7 days.
- `UsageForecast.exhaustion(window:now:) -> Date?` (pure, `nonisolated`), the same for both windows: rate = percent / (now − window start), where window start = `resetsAt − duration`; exhaustion = now + (100 − percent) / rate, returned only when it is before `resetsAt`. `nil` when the window is at 0 % or at 100 % or more, has expired, or started less than 15 minutes (5-hour) or 6 hours (weekly) ago.
- Simplified after the first implementation: an earlier version used the last hour's rate for the 5-hour window, kept in an in-memory history; the user chose the single average-rate formula instead.
- `refresh()` computes forecasts only when `showForecast` is on and passes them in `LimitsViewState` (per window kind).
- Expanded notch only: a window with a forecast shows "runs out ~16:40 · resets 18:00" in place of the reset text, with "runs out ~16:40" in orange. Times use the reset text's format: `HH:mm` within a day, otherwise `EEE HH:mm`. Nothing changes when the limit lasts until the reset.

### 11.6 Testing

Unit: credentials reader with a fake process runner (exit codes 0, 44, other; timeout; malformed output; the token is never in error text); poller pause and resume, `refreshNow()` (bypasses the throttle, clears the denial block, respects 429, no concurrent fetch); forecast (both windows, all `nil` cases, exhaustion after the reset); `showForecast` default; forecast text; controller passes forecasts only when the setting is on and calls `pollIfStale()` when the session becomes active. Manual (`docs/testing.md`): no Keychain prompt after Claude Code refreshes its token; polling stops while the screen is locked and resumes after unlocking; the refresh button; the settings layout with and without a data source.
