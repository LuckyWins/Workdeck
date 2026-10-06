# Workdeck — Claude Code Sessions Design

**Date:** 2026-10-06
**Status:** Approved for planning

## 1. Overview

Claude Code Limits becomes one tool, **Claude Code**, with two parts: **Limits** (everything in `2026-10-05-claude-limits-design.md`) and **Sessions**, which is new. Sessions shows every live Claude Code session on this Mac in the expanded notch: whether it is working, waiting for the user, or idle, and which subagents are running inside it. Clicking a session brings its window to the front. The data comes from Claude Code hooks.

### Goals

- See at a glance which Claude Code sessions are working, which are waiting for you, and which are idle, across all projects, terminals, and the VS Code extension panel.
- See the subagents running inside each session: type, task description, how long they have been running.
- Jump to a session's window with one click.
- Connect explicitly, with a backup of `~/.claude/settings.json`; disconnect removes only Workdeck's entries.
- Never store prompts, answers, or tool input.

### Non-Goals (v1)

- Notifications or notch alerts when a session finishes or needs you.
- Approving permissions, answering questions, or any other control of Claude Code.
- History of past sessions or agents; finished agents disappear.
- Showing what a session or agent is doing right now (last tool call).
- Focusing a specific terminal tab (only the terminal app is activated).
- Sessions on other machines or in the cloud; `CLAUDE_CONFIG_DIR`.

## 2. Findings (probe on 2026-10-06, Claude Code 2.1.289, VS Code extension panel)

A temporary logging hook confirmed:

- Hooks run in the VS Code extension's graphical panel. Changes to the `hooks` key are picked up by sessions that are already running.
- `SessionStart` (`source`: `startup`, `resume`, …), `SessionEnd` (`reason`), `Stop`, `SubagentStart`, `SubagentStop` all fire. Every payload has `session_id`, `cwd`, `transcript_path`, `hook_event_name`. Subagent events add `agent_id` and `agent_type` (`Explore`, `general-purpose`, custom names); they carry no task description.
- Claude Code writes `<transcript dir>/<session_id>/subagents/agent-<agent_id>.meta.json` with `agentType` and `description`, created in the same second as `SubagentStart` (undocumented).
- The hook's environment includes `CLAUDE_PID` (the `claude` process), `CLAUDE_CODE_ENTRYPOINT` (`claude-vscode` in the panel), `CLAUDE_CODE_SESSION_ID`, and `__CFBundleIdentifier` (`com.microsoft.VSCode`). The parent chain is `claude` → VS Code helper → VS Code.
- `SessionEnd` fired (`reason: other`) for every session when the VS Code window reloaded. It is not documented to fire on a crash or kill.
- `Stop` carries `last_assistant_message` and `UserPromptSubmit` carries the prompt text; Workdeck must drop both.

Not probed: a terminal session's environment (`TERM_PROGRAM` expected), `Notification` payloads (documented `notification_type`: `permission_prompt`, `idle_prompt`, …), `PostToolUse` volume.

## 3. User Interface

### 3.1 Popover Row

The row "Claude Code Limits" becomes **Claude Code**. Its toggle still turns the notch indicator on and off. The subtitle joins both parts, for example `5h 42% · 7d 13% · 2 sessions, 1 waiting`. With Sessions not connected the sessions part is omitted; with no live sessions it reads `no sessions`.

### 3.2 Settings

The section "Claude Code Limits" becomes two sections, headed **Claude Code · Limits** and **Claude Code · Sessions** (a grouped form cannot nest sections):

```
Claude Code
  Limits
    Status line                              [Connect…]
    Fetch usage from Anthropic (unofficial)  [toggle]
    … Show, alert thresholds, reset notice, forecast (only with a limits source)
  Sessions
    Session hooks                            [Connect…] / [Disconnect]
```

The Sessions footer: "Adds hooks to ~/.claude/settings.json that tell Workdeck when sessions and agents start and stop. Prompts, answers and tool input are never stored." Connect shows a confirmation like the status line's ("Connect session hooks?"), saves the same backup file, and enables the indicator.

### 3.3 Notch

- **Compact:** the limits ring and text stay on the left. On the right, a sessions counter `● 2` (live sessions). The dot is orange when any session waits for you, green when any is working, gray when all are idle. No sessions, or Sessions not connected → no counter.
- **Visibility:** the notch shows when the Limits part wants it (current rules) **or** when Sessions is connected and at least one session is live. In "Only near limits" mode with limits below the threshold, the compact notch shows only the sessions counter (left side empty).
- **Expanded:** the limits block as today (rings, forecast, "Updated …" line with the refresh button), then a divider and the sessions list:

```
● Workdeck            working         12m
    Explore · Find NotchPresenter usages  1m
● vitastir-core       waiting for you
○ pokemon             idle            25m
```

- One row per session: status dot, project name (last path component of `cwd`), status text, and time in the current state (working and idle; none for waiting).
- Under a session, one indented row per running agent: `<agent_type> · <description>` (type only when there is no description) and how long it has run. At most 2 agent rows per session, longest-running first; more → an indented row "+N agents".
- Order: waiting, then working, then idle; within a group, most recent state change first.
- At most 3 session rows; more → a last row "+2 more".
- Clicking a session row brings its window to the front (§5.4). The expanded view stays open while the pointer is over it.
- When the limits part is hidden (not connected, or "Only near limits" below threshold) the expanded view shows only the sessions list.

## 4. Architecture

### 4.1 Targets and Folders

| Item | Kind | Compiled into | Purpose |
|---|---|---|---|
| `WorkdeckHook/` | new command-line tool target | `WorkdeckHook` | Only `main.swift`: reads stdin and the environment, calls `HookRunner`, exits 0. |
| `ClaudeHooks/` | new synchronized folder | `Workdeck`, `WorkdeckHook` | Event model, payload filter, event file writer and reader, `HookRunner`. Everything `nonisolated`. |
| `Workdeck/Features/ClaudeSessions/` | app feature folder | `Workdeck` | Store, reducer, liveness, connector, window activation, views. |

- `WorkdeckHook` is embedded at `Workdeck.app/Contents/Helpers/workdeck-hook`, like `workdeck-statusline`. It is not compiled into the privileged helper.
- The existing `Workdeck/Features/ClaudeLimits/` keeps its name; the user-facing name changes only.

### 4.2 Components

| Unit | Responsibility |
|---|---|
| `ClaudeHooks/HookEvent` | `HookEvent { time: Date, name: HookEventName, sessionID, cwd, pid: Int32?, entrypoint: String?, hostBundleID: String?, termProgram: String?, source: String?, reason: String?, notificationType: String?, agentID: String?, agentType: String?, agentDescription: String? }`, Codable, one JSON object per line. Unknown event names are dropped. |
| `ClaudeHooks/HookPayloadFilter` | Pure: builds a `HookEvent` from the payload JSON and environment, copying only the fields above. Never reads `prompt`, `last_assistant_message`, `tool_input`, `tool_response`, or any other key. |
| `ClaudeHooks/AgentDescriptionReader` | For `SubagentStart`: reads `description` from `<dirname(transcript_path)>/<session_id>/subagents/agent-<agent_id>.meta.json`, retrying every 200 ms for up to 1 s; `nil` if absent or malformed. Truncated to 80 characters. |
| `ClaudeHooks/HookEventFile` | Appends one line to `~/Library/Application Support/Workdeck/sessions/<session_id>.jsonl` with `O_APPEND` (file mode 0600, directory 0700), and reads lines from a byte offset. Session IDs that are not a UUID-like `[A-Za-z0-9-]{1,64}` are rejected, so the ID cannot escape the directory. |
| `ClaudeHooks/HookRunner` | `run(stdin:environment:now:)`: filter, read the agent description when needed, append. Swallows every error. |
| `ClaudeSessions/SessionReducer` | Pure: folds a session's events (sorted by `time`) into `ClaudeSession` (§5.2). |
| `ClaudeSessions/ClaudeSessionStore` (`@Observable`) | Watches the sessions directory, reads appended lines per file, keeps reduced sessions, runs liveness checks, deletes files of ended sessions, exposes `sessions` sorted for display. |
| `ClaudeSessions/ProcessLiveness` | Protocol + system implementation: the start time of a running PID (`proc_pidinfo`), `nil` when it is not running. |
| `ClaudeSessions/SessionHooksConnector` | Connect/disconnect Workdeck's hook entries in `~/.claude/settings.json` (§5.3). |
| `ClaudeSessions/WindowActivator` | Protocol + system implementation: brings a session's window to the front (§5.4). |
| `ClaudeSessions/SessionsText` | Pure: status texts, durations, popover subtitle part. |
| `ClaudeLimitsController` | Gains the sessions store, connector and activator; builds the combined notch state and subtitle. |
| Views | Notch compact counter, expanded sessions list, Settings "Sessions" group. |

All file-system, clock, process, and workspace access is injected so units are testable.

## 5. Behavior

### 5.1 Hook Command (`workdeck-hook`)

- Configured for `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PostToolUse`, `Notification`, `Stop`, `SubagentStart`, `SubagentStop`, each as `{"type": "command", "command": "'<app>/Contents/Helpers/workdeck-hook'", "async": true, "timeout": 5}` with no matcher.
- Reads stdin (at most 4 MiB: `PostToolUse` payloads carry the tool output, which Workdeck never reads), filters (§4.2), appends one line, exits 0 with no output. Larger input or any error → exit 0 silently.
- Environment fields: `CLAUDE_PROJECT_DIR` → `projectDir`, `CLAUDE_PID` → `pid`, `CLAUDE_CODE_ENTRYPOINT` → `entrypoint`, `__CFBundleIdentifier` → `hostBundleID`, `TERM_PROGRAM` → `termProgram`.
- `transcript_path` is used only to locate the agent's `meta.json` and is not stored.

### 5.2 Session State

`ClaudeSession { id, cwd, projectName, status: working | waiting | idle, since: Date, agents: [RunningAgent], pid, pidSince, entrypoint, hostBundleID, termProgram, lastEventAt, hasEnded }` (`pidSince`: time of the first event that reported the current PID), `RunningAgent { id, type, description?, startedAt }`.

| Event | Effect |
|---|---|
| `SessionStart` (any `source` except `compact`) | Resets the session: status idle, no agents, takes `pid` and host fields from this event. Compaction keeps status and agents. |
| `UserPromptSubmit` | Status working (keeps `since` if already working). |
| `PostToolUse` | Status working, except while waiting for another agent: only a tool call from the agent that asked for permission (same `agent_id`, `nil` for the main agent) ends the wait. |
| `Notification` with `notification_type == "permission_prompt"` | Status waiting; remembers the asking agent. |
| `Notification` with `notification_type == "idle_prompt"` | Status idle: an interrupt (Esc) or a denied permission sends no `Stop`, and Claude Code reports the idle prompt about a minute later. Other notification types → no change. |
| `Stop` | Status idle. Running agents stay (background agents outlive the turn). |
| `SubagentStart` | Adds the agent. |
| `SubagentStop` | Removes the agent. |
| `SessionEnd` | Session ended: the store removes it and deletes its file. |

`since` changes only when the status changes. Fields missing from an event (for example `pid`) keep their previous values. The project folder is `CLAUDE_PROJECT_DIR` when the hook environment has it, otherwise the first `cwd` reported (or the `cwd` of `SessionStart`); later `cwd` values follow `cd` in the Bash tool and are ignored.

### 5.3 Connecting

- Same rules as the status line connector: requires the embedded binary, resolves a symlinked `settings.json` and keeps the link, refuses invalid JSON with the existing message, saves `settings.json.workdeck-backup` before writing, re-writes with sorted keys.
- Connect appends one matcher group `{"hooks": [<Workdeck hook>]}` to each of the eight event arrays, creating `hooks` and the arrays when missing. Existing groups and other keys are untouched. Connecting twice does not add duplicates.
- Workdeck's hook is recognized by its command ending in `/Contents/Helpers/workdeck-hook` (quotes ignored), like the status line command.
- Disconnect removes every Workdeck hook entry; a matcher group left with no hooks is removed; an event array left empty is removed; `hooks` left empty is removed.
- Status: connected when every one of the eight events has a Workdeck hook; partially connected (some missing) counts as not connected, and Connect repairs it.
- Path repair on launch, as for the status line: entries pointing at another Workdeck bundle are rewritten to this bundle's path, except from temporary locations.
- Settings key `claudeSessions.isConnected` is not stored; the status is always read from `settings.json`.

### 5.4 Store, Liveness, and Window Activation

- The store watches the sessions directory and each event file (file system events; appending to a file does not change its directory) plus a 10-second timer. It keeps a byte offset per file and reads only appended complete lines; a partial last line waits for the next read. Malformed lines are skipped.
- Liveness, every 10 seconds and after each read: a session is removed and its file deleted when
  - its last event is `SessionEnd`, or
  - it has a `pid` and that process is gone, or it started after the event that reported the PID (the PID was reused), or
  - it has no `pid` and no event for 24 hours.
- On launch, files of sessions found dead are deleted; the rest are read from the start.
- Activation on click:
  - `hostBundleID` of a known editor (VS Code `com.microsoft.VSCode`, VS Code Insiders, Cursor, Windsurf) → open the session's `cwd` with that application through `NSWorkspace`, which focuses the window holding that folder.
  - Any other `hostBundleID` (for example `com.apple.Terminal`, `com.googlecode.iterm2`, `com.mitchellh.ghostty`) → activate that application.
  - No `hostBundleID` → nothing happens.

### 5.5 Combined Display

- `LimitsViewState` gains `sessions: SessionsViewState` (the counter level and the rows to show).
- `LimitsPresentation.display` decides notch visibility from both parts (§3.3). The menu bar text fallback (no notch screen) is unchanged and shows limits only.
- The popover subtitle is built from both parts (§3.1).

## 6. Errors

| Failure | Handling |
|---|---|
| Workdeck not running | Hooks keep writing; on launch dead sessions are dropped and live ones restored. |
| Malformed or partial line | Skipped / read on the next pass. |
| No `CLAUDE_PID` (older Claude Code) | Removed on `SessionEnd`, or after 24 hours without events. |
| PID reused by another process | The process started after the event that reported the PID → removed. (The executable name is not checked: native installs name the binary after its version and npm installs run `node`.) |
| Resume in a new process | `SessionStart` resets the session with the new PID. |
| Hook cannot write | Exits 0; Claude Code is unaffected. |
| `meta.json` missing or late | Agent shown by type only. |
| Invalid `settings.json` | Connect and Disconnect refuse with the existing message. |
| App window not found | Activation does nothing. |
| More than 3 sessions | "+N more" row. |
| More than 2 agents in a session | "+N agents" row under it. |

## 7. Testing

Unit (Swift Testing; never the real `~/.claude`, the real sessions directory, or real processes other than harmless test binaries):

- `HookPayloadFilter`: every field mapping; prompt, answer and tool input never appear in the output for any payload; unknown events dropped; invalid session IDs rejected.
- `AgentDescriptionReader`: present, appears after a delay, never appears, malformed, truncation.
- `HookEventFile`: append and read from offset, partial last line, file and directory modes.
- `HookRunner`: end to end into a temporary directory; never throws.
- `SessionReducer`: every row of §5.2, ordering by time, resume, missing fields.
- `ClaudeSessionStore`: incremental reads, liveness with a fake (`SessionEnd`, dead PID, reused PID, 24-hour expiry), file deletion, sort order, "+N more" sessions and "+N agents".
- `SessionHooksConnector`: connect next to existing hooks, idempotent connect, partial repair, disconnect cleanup, symlink, backup, invalid JSON, path repair.
- `WindowActivator` with a fake workspace: editor vs. terminal vs. none.
- Controller and presentation: subtitle, counter level, visibility in "Only near limits", expanded view without limits.
- A build test that `workdeck-hook` is embedded and executable, like `workdeck-statusline`.

Manual (`docs/testing.md`, new rows S1–S8): connect and backup; sessions in the VS Code panel and in Terminal; waiting for a permission prompt; a subagent with description; click to focus VS Code and Terminal; closing a tab removes the session; killing `claude` removes it within 10 seconds; disconnect leaves other hooks intact.

## 8. Documentation

- `README.md`: rename the tool to Claude Code, describe Sessions, what the hooks add and store.
- `CLAUDE.md`: `WorkdeckHook/`, `ClaudeHooks/`, `Features/ClaudeSessions/`; the hook must exit 0, stay fast, and never store prompt, answer or tool content.
- `docs/testing.md`: S1–S8.
