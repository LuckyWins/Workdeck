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
- Reads stdin in chunks, keeping at most 4 MiB and draining the rest so Claude Code never sees a broken pipe (at most 4 MiB: `PostToolUse` payloads carry the tool output, which Workdeck never reads), filters (§4.2), appends one line, exits 0 with no output. Larger input or any error → exit 0 silently.
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
- Memory stays bounded: events older than 60 seconds before a session's newest event are folded into a settled state and dropped; only the last minute of events is kept for reordering late async hooks. Event files themselves grow for the life of a session (about 350 bytes per tool call) and are deleted with it.
- A file deleted and recreated between reads (new file number) is read from the start.
- One process runs one session: when two live sessions report the same PID (an in-process `/resume` that sent no `SessionEnd`), only the one with the newest event stays; the other is removed with its file.
- The store notifies the controller only when the sessions change or a new minute starts (durations are shown in minutes); the controller ignores sessions updates while the hooks are not connected.
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

## 9. Amendment: Terminal Look (2026-10-06)

After trying the first version, the user chose a terminal-style notch (htop-like):

- **Compact:** left — the limits ring and the most pressing window's percent (`42%`, labeled only for the weekly window: `7d 91%`); right — `●N` live sessions (dot colored by the most urgent session) and `✦N` running subagents across all sessions, shown only when there are any. Both sides are static. The menu bar fallback text is unchanged (`5h 42%`).
- **Expanded:** monospaced (SF Mono) text. A `─ limits ─` header, one row per window with a 16-cell block bar (`5h [███████░░░░░░░░░]  42%  ↺ 1h 20m`) colored by threshold, the forecast as an orange line below its window, then the age line. A `─ sessions ─ N ─` header and the session list: `●`/`○` dot, project, status, duration; agents as a tree (`├`/`└`) with a braille spinner, type, and dimmed description; "+N agents" as the last branch.
- **Motion (expanded only, up to 10 frames per second):** working session dots pulse, waiting dots blink slowly, agent spinners turn. Idle sessions are static and dimmed.
- **Clickable cues:** hovering a session highlights its block, shows a pointing-hand cursor, and replaces the duration with `↗ open`. With the usage API on, the age line itself is the refresh control: hovering highlights it and shows `click to refresh ↻`; it shows `refreshing…` with a spinner while fetching and is dimmed and disabled during a 429 pause.
- Alerts use the same style: `! 5-hour limit at 80%` with the reset time below.

## 10. Amendment: Keep Awake, Session Alerts, Current Action, Compacting (2026-10-06)

### 10.1 Hooks and Data

- Two more hook events: `PreToolUse` (the current action) and `PreCompact` (context compaction starts), ten in total. On the first launch of a version that subscribes to new events, the connector adds them once if Workdeck's hooks are connected (no new Connect needed; tracked by `claudeSessions.hookEventsVersion`). Events a user later removes stay removed. `PreToolUse` and `PreCompact` are optional: without them the hooks still count as connected. Repairs (path or events) never overwrite the backup.
- `HookEvent.action`: for `PreToolUse` only, the tool name and a short target, at most 30 characters (longer → 29 + "…"):
  - `Read`, `Edit`, `MultiEdit`, `Write` → file name of `file_path` (no directories); `NotebookEdit` → file name of `notebook_path`;
  - `Bash` → the first line of `command`, whitespace collapsed, with secret-looking values masked before truncation (`NAME=value` → `NAME=…`, `-pPASSWORD` → `-p…`, `Bearer|Basic|token VALUE` → `Bearer …`);
  - `WebFetch` → host of `url`; `WebSearch` → `query`; `Grep`, `Glob` → `pattern`;
  - `Agent`, `Task` → `subagent_type`;
  - `mcp__<server>__<tool>` → `mcp:<server>`;
  - any other tool → its name.
  Nothing else from `tool_input` is read or stored.

### 10.2 Session State

| Event | Effect |
|---|---|
| `UserPromptSubmit` | As before. Work (`workStartedAt`) starts whenever a quiet session gets busy (see §10.5). |
| `PreToolUse` | Sets the action of the agent with that `agent_id` when it is running; an `agent_id` of an agent not running (stopped, or not read yet) changes nothing; no `agent_id` sets the session's action. Status working unless the session is waiting. |
| `PostToolUse` | As before. The action stays until the next `PreToolUse` replaces it (no flicker between commands); "starting…" shows only before an agent's first command. |
| `Stop` | As before; clears the session action and records `lastStopAt`. |
| `PreCompact` | Status compacting; remembers the status it interrupted. |
| `SessionStart` with `source == "compact"` | A compacting session returns to idle if compaction interrupted an idle session (manual `/compact`), otherwise to working (idle follows on `Stop` or `idle_prompt`). |

Compacting counts as working for the counter color, ordering and keep-awake.

Stopped agents: an agent stopped by the main agent's `TaskStop` tool sends no `SubagentStop` (seen live on 2026-10-06). Each agent remembers its latest own event (`PreToolUse`/`PostToolUse` carry the subagent's `agent_id`, confirmed live). The store hides an agent that has been silent since the session's last `TaskStop` for at least 30 seconds, or silent for 30 minutes whatever the reason. Hidden agents return as soon as they send an event. Hidden agents do not count as running for the counter, keep-awake, or alerts.

### 10.3 Display

- Session row: while working with an action, the action replaces the word "working" (`● Workdeck   Bash xcodebuild -sch…  12m`). Compacting shows a cyan dot and "compacting".
- Agent row: the action, when known, replaces the description; the description becomes the row's help text.

### 10.4 Settings (section "Claude Code · Sessions", shown only with hooks connected; all off by default)

- **Keep Mac awake while Claude works** (`claudeSessions.keepAwake`).
- **Notify when a session finishes** (`claudeSessions.notifyFinished`) with **after working for** 1, 2, 5, 10, 15 or 30 minutes (`claudeSessions.finishedAfterMinutes`, default 10), shown when the toggle is on.
- **Notify when a session needs you** (`claudeSessions.notifyNeedsYou`).
- The two notify toggles are disabled while the indicator is off (alerts live in the notch), with the hint "Turn on Claude Code in the menu bar popover to see alerts in the notch."

### 10.5 Alerts

- New `LimitsAlert` cases: `sessionFinished(project:worked:)` → "✓ Workdeck finished" / "worked 14m" (green); `sessionNeedsYou(project:)` → "! vitastir needs you" / "permission prompt" (orange). They use the existing notch alert (6 seconds, one at a time) and require the indicator to be on.
- `SessionAlertPolicy` (pure) compares the previous and current session lists:
  - finished: a session that was working or compacting is now idle because of `Stop` (`since == lastStopAt`) **with no running agents**, and `lastStopAt − workStartedAt` (or the previous `since` without a work start) is at least the threshold. An agent stopping alone never announces: Claude Code re-invokes the model after a background agent, and the `Stop` that follows is the finish;
  - `workStartedAt` is set when a quiet session (idle, no agents) gets busy, unless it went quiet because its last agent stopped (`SubagentStop`) less than 10 seconds earlier — the re-invocation after a background agent — so "worked" covers the whole job, agents included. A `Stop` always closes the work: a quick reply from the user starts new work;
  - needs you: a session that was not waiting is now waiting;
  - none for sessions seen for the first time (launch, connect), or when the session's host app is frontmost and hosts no other live session (with several sessions in one app, such as VS Code windows, the window in front is unknown, so the alert shows).
- Alerts that arrive together are shown together: a header ("2 sessions finished", "2 sessions need you", "3 alerts") and one line per alert (at most three, then "+N more"). An alert arriving while others are on screen joins them and restarts the 6-second display.

### 10.6 Keep Awake

- While the setting is on and hooks are connected, a `PreventUserIdleSystemSleep` power assertion named "Workdeck: Claude Code is working" is held whenever any session is working or compacting or has running agents and had an event in the last hour (a missed `SubagentStop` or idle prompt must not keep the Mac awake for days); it is released otherwise. The display may still sleep; a closed lid still sleeps unless Closed-Lid Mode is on. The assertion is behind a protocol (`SleepPreventing`) for tests.

### 10.7 Privacy Wording

The Sessions footer and README change from "tool input is never stored" to "Prompts and answers are never stored; for tool calls only the tool name and a short target (file name, start of a command with secret-looking values masked, domain, search text) are kept."

### 10.8 Testing

Unit: action extraction for every tool kind, truncation, other input never stored; reducer rows of §10.2; event upgrade on launch; alert policy (threshold, Stop vs idle prompt, frontmost host, first sighting); settings defaults and persistence; keep-awake decisions with a fake; system assertion create and release. Manual `docs/testing.md` S10–S13: action and compacting display, finished alert after the threshold, needs-you alert, `pmset -g assertions` while working.

## 11. Amendment: Agent Cards (2026-10-06)

- `SubagentStart` also records, from the agent's `meta.json`, the model alias (`model`, e.g. "opus") and whether it runs in the background (`requestShape == "background"`), plus the path of the agent's own transcript (`<meta dir>/agent-<id>.jsonl`). Paths and these two fields only; no content.
- The app reads the agent transcript only up to the first assistant line to take `message.model` (e.g. `claude-opus-5-5`), at most 2 MiB, and remembers it per agent; it gives up after 30 lookups without a model. Token usage is not read: transcripts record output counts at the start of streaming, so they are unreliable.
- Each agent counts its own `PreToolUse` events as steps.
- Model names display as "Opus 5.5" / "Haiku 4.5" (the alias capitalized until the transcript names the model).
- An agent takes two lines in the expanded notch:
  ```
  ├ ⠋ general-purpose · Opus 5.5  bg           9m
  │   Bash cd /Users/andreu/Development/vi…  87 steps
  ```
  Line one: full type, model, a cyan `bg` for background agents, duration. Line two: the current action (or the description), and `N steps`. The tree line continues between agents. Help text: description · model · background/foreground.
- Not yet verified live: the model and `bg` on agents started after this version is installed (agents started earlier were recorded without them).

## 12. Amendment: Controller Split, Live Background Agents, Diagnostics (2026-10-06)

### 12.1 Controller Split (no behavior change)

- `ClaudeLimitsController` keeps only limits: status line connection, usage API poller, screen activity, limits alerts, the limits part of the notch state.
- New `ClaudeSessionsController`: session hooks connection, the session store, session alerts, keep-awake, window activation.
- New `ClaudeCodeController` composes both: the combined notch state (`LimitsViewState`), the popover row (subtitle, indicator toggle), the menu bar text, presenting alerts from both parts.
- `ClaudeLimitsSettings` becomes `ClaudeCodeSettings` (same UserDefaults keys); `ClaudeLimitsRow` becomes `ClaudeCodeRow`.
- Folders: `Workdeck/Features/ClaudeCode/` with `Limits/` (and `Limits/UsageAPI/`) and `Sessions/`; shared notch and settings code at its root. Tests mirror this under `WorkdeckTests/ClaudeCode/`.

### 12.2 Live Background Agents

- Probe (2026-10-06): `Stop` and `SubagentStop` carry `background_tasks`, a list of `{id, type, status, agent_type, description}`; `id` equals the agent's `agent_id`; the main agent's `Stop` lists the background agents alive at that moment (a `SubagentStop` still lists the stopping agent as running).
- The hook records, for `Stop` without `agent_id` only, `backgroundAgentIDs`: the `id` of entries whose `type` is `"subagent"` (validated like other IDs). Descriptions are never read.
- Reducer: on such a `Stop`, running agents whose IDs are not in the list are removed — foreground agents have finished by then, and a background agent missing from the list was stopped (e.g. with `TaskStop`). The `TaskStop` silence rule and the 30-minute silence rule (§10) stay as fallbacks for `Stop` events without the field.

### 12.3 Diagnostics

- Unified logging (`os.Logger`), subsystem `com.appcreators.workdeck`, categories `sessions`, `alerts`, `keepAwake`, `limits`. Logged: session status transitions (`vitastir: working → idle`), agents appearing and disappearing, alert decisions including why an alert was not shown (below threshold, host app in front, agents still running, indicator off), keep-awake on/off, hook connection errors, usage API status changes. Never logged: prompts, actions, descriptions, tokens; only session IDs (first 8 characters), project names, agent types, statuses.
- Settings → About: **Copy Diagnostics** copies the last hour of Workdeck's log entries plus a snapshot of the current state (sessions with status, agent count, types and models; relevant settings; connection states; app version) to the clipboard as plain text.

### 12.4 Testing

Unit: the split keeps every existing test's assertions (only constructors and the object a call goes through change); background agent IDs parsed only from main `Stop` and only `subagent` entries; reducer removal on `Stop`; alert decision reasons; the diagnostics snapshot text. Manual: `docs/testing.md` S15 (stopping a background agent with TaskStop removes it at the next Stop) and S16 (Copy Diagnostics).

## 13. Amendment: Agent Names and Clickable Alerts (2026-10-06)

- An agent's first line shows its task description instead of its type; a user-defined type follows the model as a dim tag (`Review auth module · Sonnet 5.5 · code-reviewer`). Claude Code's own types (`general-purpose`, `Explore`, `Plan`) appear only in the help text. Without a description, the type is the name. The second line shows the current command, or "starting…" before the first one.
- Session alerts (`finished`, `needs you`) are clickable: hovering shows the pointing hand, a highlight and "↗ open"; a click opens the project's window, found by project name (sessions in one project share a window). In a batch, each line opens its own project. Limit alerts are not clickable.

## 14. Amendment: Blank Sessions (2026-10-07)

Observed: the VS Code extension keeps a separate `claude` process for a new conversation tab. It sends `SessionStart` (`source: startup`) and nothing else until the first prompt, and Claude Code writes no transcript for it. The notch listed it as a second idle row with the same project name, which read as a duplicate.

- A session started with `source` `startup` or `clear` is blank until any event other than `SessionStart` arrives. A blank session is tracked (its file, PID and liveness checks as usual) but not listed, so it is not counted, alerted on or activated. It appears with its first prompt.
- `resume` sessions are not blank: they reopen a conversation that has content. A `SessionStart` without a `source`, or a session whose first seen event is not a start (hooks connected mid-session), is not blank either.
- The PID rule runs before this filter: after `/clear` in a terminal the previous session is dropped and the new blank one stays hidden until used.
