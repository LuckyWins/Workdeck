# Workdeck — Claude Code Accounts Design

**Date:** 2026-10-09
**Status:** Implemented

## 1. Overview

`2026-10-09-claude-instances-design.md` added extra Claude Code instances (`CLAUDE_CONFIG_DIR`, one login each) and the Chats window. This spec makes the rest of the Claude Code tool account-aware: every instance gets the status line, the session hooks and the usage API, the notch shows each account's limits and marks which account a session runs on, alerts name their account, and a limit alert opens the Chats window to move the work to another account.

### Goals

- See each account's 5-hour and weekly limits at once, so it is clear which account has room left.
- See the sessions and agents of every account in the notch, with their account marked.
- One Connect for all instances; instances added earlier, or later, are connected without extra steps.
- A limit alert leads to the chat to continue on another account in one click.

### Non-Goals

- Different alert thresholds, notch modes or settings per account.
- Choosing which account a new session uses.
- The VS Code extension on an extra instance.
- Combining limits across accounts (a total or an average).

## 2. Terms

- **Account** = instance (`ClaudeInstance`, previous spec). The main instance is `~/.claude`; extra ones are `~/.claude-<name>`.
- **Active account**: the account of the session with the latest hook event; the main account when there are no sessions or no hooks.
- **Accounts with data**: accounts whose snapshot has at least one window.

## 3. Data and Connection

### 3.1 Commands per Instance

- The main instance keeps today's commands: `'<app>/Contents/Helpers/workdeck-statusline'` and `'<app>/Contents/Helpers/workdeck-hook'`.
- An extra instance gets the same commands with `--instance <name>` appended, in its own `<dir>/settings.json`.
- `workdeck-statusline --instance <name>` writes `claude-usage-<name>.json` and keeps the instance's previous status line in `statusline-<name>.json` (main: `claude-usage.json`, `statusline.json`, unchanged). An argument that is not a valid instance name (spec `2026-10-09-claude-instances-design.md` §3.1 rules) is ignored and the command behaves as for the main instance.
- `workdeck-hook --instance <name>` adds `instance: "<name>"` to each event (`HookEvent.instance: String?`, `nil` for main). Events stay in the one sessions folder, keyed by session ID.

### 3.2 Connecting

- **Connect** in "Claude Code · Limits" and "Connect…" in "Claude Code · Sessions" connect every instance; **Disconnect** disconnects every instance. Each instance's `settings.json` gets its own backup next to it (`settings.json.workdeck-backup`), as the main one does today.
- One instance failing (missing folder, invalid JSON) does not stop the others; the error is shown in that instance's row.
- **Add Instance** connects the new instance to whatever the main instance has connected. **Remove** disconnects the instance first (removes Workdeck's entries, restores its previous status line), deletes its `claude-usage-<name>.json` and `statusline-<name>.json`, then forgets it.
- **Reconcile on launch:** when Workdeck starts, and when an instance is added, every instance that is missing what the main instance has connected is connected, with a backup. No confirmation: Connect applies to all instances. This covers instances added before this feature.
- The Instances section shows per instance: `Limits ✓ · Sessions ✓`, `Not connected`, or the error.
- Hooks are read by running sessions at once; a running session picks up the status line only after it restarts.

### 3.3 Usage API per Account

- Each account has its own poller, credentials item, rate-limit backoff and refresh. The "Fetch usage from Anthropic" setting applies to all accounts.
- The main account reads `Claude Code-credentials` as today. An extra account reads the item Claude Code keys to its folder (§8, probe 1). Every rule of `UsageAPI/` stays: `/usr/bin/security`, never refresh, persist or log a token.
- If the probe finds no rule to derive the item name, extra accounts have no usage API and rely on the status line; the Limits section says so.

### 3.4 Alerts Memory

Fired alert keys are kept per account: the main account keeps `claudeLimits.firedAlertKeys`; an extra account uses `claudeLimits.firedAlertKeys.<name>`, removed on Remove.

## 4. Notch

### 4.1 Sessions

- With more than one instance connected, a session of an extra account shows its account name after the project name as a purple tag (`vitastir  personal`); main sessions are unchanged. One list, ordered as today.
- The compact counters `●N ✦N` count all accounts.

### 4.2 Limits, Expanded

- One block per account with data: header `— limits · main —`, `— limits · personal —`, then the 5h and 7d bars, reset times and forecasts, and its own `updated … ↻` line. Order: main, then extra instances in the order they were added.
- With one account with data the header stays `— limits —`.

### 4.3 Limits, Compact and Menu Bar

- The ring and percent show the active account. With two or more accounts with data, the percent is prefixed with the account's first letter (`p 26%`).
- "Only near limits": the notch shows when any account is near a limit, and then shows that account.
- The menu bar text on a screen without a notch shows what the compact notch shows.

### 4.4 Alerts

- Threshold and reset alerts are evaluated per account with the shared settings. With two or more accounts with data, the title names the account: `7d limit at 95% · main`.
- Clicking a limit alert opens the Chats window with the project of that account's latest session selected (All when there is none). In a batch each line opens its own.
- Session alerts (finished, needs you) keep their text and their click (open the project's window); they do not name the account, since the project already tells sessions apart.

### 4.5 Chats Window

`live` covers sessions of every instance, so the warning before Continue and Resume also fires for a chat open in an extra instance.

## 5. Architecture

| Component | Change |
|---|---|
| `ClaudeUsage/WorkdeckPaths` | `snapshotURL(for instance: String?)`, `statusLineConfigURL(for:)`; `nil` is main. |
| `ClaudeUsage/StatusLineRunner`, `WorkdeckStatusLine/main.swift` | Parse `--instance <name>`; use that instance's paths. |
| `ClaudeHooks/HookEvent`, `HookRunner`, `WorkdeckHook/main.swift` | `instance` field from `--instance <name>`. |
| `ClaudeSession` | `instance: String?`, set by the reducer from events. |
| `ClaudeCodeConnector`, `SessionHooksConnector` | Take the instance (settings URL, command arguments, paths); one connector per instance. |
| `SecurityCLICredentialsReader` | Takes the Keychain service name. |
| `AccountLimits` (new, `Limits/`) | One account's store, poller and connector, alert memory and forecasts. |
| `ClaudeLimitsController` | Holds one `AccountLimits` per instance; connects, reconciles and evaluates them all; exposes per-account view states and the active account. |
| `ClaudeSessionsController` | One hooks connector per instance; reconcile; active account from sessions. |
| `LimitsViewState`, `LimitsNotchViews`, `SessionsNotchViews` | Per-account blocks, compact prefix, session tag. |
| `LimitsAlert` | Carries the account name. |
| `ChatsController` | `focus(onLatestSessionOf instance:)` selects the project; live sessions of all instances. |
| `ClaudeInstancesController` | Add and Remove call into the limits and sessions controllers (connect, disconnect, delete files). |
| `DiagnosticsReport` | One block per account. |

## 6. Errors

| Condition | Behavior |
|---|---|
| An instance's `settings.json` is invalid JSON | That instance stays unconnected; its row shows "Fix ~/.claude-<name>/settings.json first: it is not valid JSON."; others connect. |
| An instance's folder is missing | Its row shows "Folder missing"; reconcile skips it. |
| The usage API of an extra account fails | Shown in that account's `updated …` line, as today for main. |
| `--instance` names an instance Workdeck does not know | The status line writes its own files; hook events are stored; the notch does not show them. |
| No Keychain rule found | Extra accounts use the status line only; the Limits section says "Usage API: main account only". |

## 7. Testing

Unit tests never touch the real Keychain, network, `~/.claude*`, sessions folder or snapshots.

- `StatusLineRunner` and `HookRunner` with `--instance`: paths, field, invalid names.
- Connectors per instance: settings URL, command arguments, backups, restore on disconnect.
- `ClaudeLimitsController`: connect all, one invalid `settings.json`, reconcile on launch and on add, remove deletes files and alert memory.
- Active account from sessions; fallback to main.
- View state: blocks per account, one-account header, compact prefix, "Only near limits" by any account.
- Alerts: per-account evaluation and memory, titles with the account, click opens Chats focused on the latest session's project.
- `ChatsController`: live for sessions of an extra instance.
- Credentials: the service name per instance, from the probed rule.

Manual rows in `docs/testing.md` for two signed-in accounts.

## 8. Probes (first implementation task, with the user's consent)

1. **Keychain item name for `~/.claude-personal`.** List generic password service names that start with `Claude Code-credentials` (names only); confirm a candidate with `security find-generic-password -s <name>` without `-w` (attributes only, no secret). Find the rule that derives the name from the folder path (for example a short hash of the path) and check that it reproduces the found name.
2. **Status line input of the second account** includes `rate_limits` (structure only).
3. **A hook command with `--instance personal`** in `~/.claude-personal/settings.json` runs and the event carries the field.

Results are recorded in §10.

## 9. Documentation

README (Claude Code: accounts), CLAUDE.md (per-instance files and commands), `docs/testing.md`, and §9 of `2026-10-09-claude-instances-design.md` pointing here.

## 10. Probe Results

To be filled in by the first implementation task.
