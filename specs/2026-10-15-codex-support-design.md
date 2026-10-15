# Workdeck — Codex Support Design

**Date:** 2026-10-15
**Status:** Approved; stage 1 (limits) implemented

## 1. Overview

Workdeck shows OpenAI Codex next to Claude Code: Codex's plan limits and its live sessions and agents in the same notch, with the same alerts. Claude Code and Codex are equals: each is its own tool with a popover row and a Settings section, each block and session carries its agent's mark, and the notch is owned by neither.

This spec covers stage 1 (Codex limits) and stage 2 (Codex sessions) and the shared notch both need. Stage 3, Codex work in the weekly recap and the Statistics window, gets its own spec.

The data sources come from two probes on 2026-10-14 and 2026-10-15 on Codex CLI 0.162.1 and the VS Code extension `openai.chatgpt` (bundling codex 0.162.0-alpha), signed in with ChatGPT on the `prolite` plan. [Coucou](https://github.com/Louis-CFM/coucou) reads Codex the same way (hooks in `~/.codex/hooks.json`, limits from `codex app-server`).

### Goals

- Codex limits in the notch from data Codex already writes, plus a rare `codex app-server` question; no network call or credential of Workdeck's own.
- Codex sessions and agents from Codex hooks, through the existing `workdeck-hook`, session model and reducer.
- A notch composed from any number of agents, with Claude Code changing nothing visible when Codex is off.

### Non-Goals

- Codex in the recap and Statistics (stage 3).
- Answering Codex permission requests from the notch.
- Opening Codex chats elsewhere (Chats stays Claude-only), several Codex accounts, the Codex desktop app.
- Counting lines of edits Codex makes through its shell (Claude's Bash edits are not counted either).

## 2. What Codex Provides

### 2.1 Limits

- **Session files.** `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread id>.jsonl`, one JSON object per line. After each turn an `event_msg` line with `payload.type == "token_count"` carries `payload.rate_limits`: `{limit_id, primary, secondary, credits, plan_type, rate_limit_reached_type, …}`, each window `{used_percent, window_minutes, resets_at}` (`resets_at` in Unix seconds). Other lines hold prompts, answers and code and are never parsed beyond their `type`.
- **`codex app-server`.** JSON-RPC over stdin and stdout, one JSON object per line: `{"id":1,"method":"initialize","params":{"clientInfo":{"name":"workdeck","version":"<app version>"}}}`, `{"method":"initialized"}`, `{"id":2,"method":"account/rateLimits/read"}`. The answer to id 2 has `rateLimits` (camelCase: `usedPercent`, `windowDurationMins`, `resetsAt`, `planType`) and `rateLimitResetCredits.availableCount` (free full resets). Codex answers with its own sign-in; Workdeck never reads `~/.codex/auth.json`. Closing stdin ends the process.
- `prolite` has only a weekly window (`primary`, 10080 minutes); other plans add a 5-hour window (300 minutes). An API-key sign-in has no `rate_limits`.

### 2.2 Hooks

- `~/.codex/hooks.json`: `{"hooks": {"<Event>": [{"hooks": [{"type": "command", "command": "…", "timeout": 5}]}]}}`, the same shape as Claude Code's settings hooks. The `hooks` feature is stable and on. Hooks fire in the CLI (`originator: codex-tui`) and in the VS Code extension (`codex_vscode`); a running session reads the file only at its start.
- Events: `SessionStart` (`source`), `UserPromptSubmit` (`prompt`), `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop` (`last_assistant_message`, `stop_hook_active`), `SubagentStart` and `SubagentStop` (`agent_id`, `agent_type`; Stop adds `agent_transcript_path`), `Interrupt`, `SessionEnd` (`reason`).
- Every event: `session_id`, `transcript_path` (the session file of §2.1), `cwd`, `hook_event_name`, `model`, `permission_mode`; turn events add `turn_id`. Tool events add `tool_name`, `tool_input`, `tool_use_id` (not on `PermissionRequest`) and, after, `tool_response` (a string for shell commands). Tool calls made by an agent carry its `agent_id` and `agent_type`.
- Tool names: `Bash` (`tool_input.command`, plus `description` on a permission request) for every shell command, including reading and writing files; `collaborationspawn_agent` (`task_name`, `message`, `fork_turns`), `collaborationwait_agent` (`timeout_ms`).
- A hook that prints nothing on `PermissionRequest` leaves the request to the user as usual.
- File edits through Codex's patch tool did not reach hooks in either probe; they appear in the session file as `event_msg` / `patch_apply_end` with `changes: {<path>: {type, unified_diff, move_path}}`.

## 3. Behavior

### 3.1 The Notch with Two Agents

- **Agent marks:** Claude Code `✳` (orange), Codex `◎` (green). Marks show only while more than one agent is enabled; with Codex off the notch looks exactly as today.
- **Compact notch:** the ring and percent of the account of the most recent session across agents (`✳ 41%`, `◎ 7d 3%`, `✳p 26%` for an extra Claude account); without sessions, the agent whose limits changed last. Session and agent counters (`●2 ✦1`) count every agent. The menu bar text (no notch) and the menu bar warning glyph follow the same choice.
- **Expanded notch:** limit blocks in a fixed order, Claude accounts first, then Codex: `✳ main`, `✳ personal`, `◎ codex`, each with its plan on the right. An agent or account without a session is one dim line, as accounts are today (`specs/2026-10-09-claude-accounts-design.md`). The Codex block adds `3 free resets` under its bars when Codex reports any. Sessions are one list across agents in the current order; each row's status dot becomes its agent's mark, colored by status as the dot is; the purple account tag stays for extra Claude accounts.
- **Alerts** start with the agent's mark: `◎ Weekly limit at 80%`, `✳ vitastir finished · worked 14m`, `◎ Workdeck needs you`. A session alert carries its agent, so clicking it reaches only that agent: two agents working in folders with the same name never both bring a window forward. A limit alert opens Chats only for a Claude account.

### 3.2 Codex Limits

- **Session files** are watched with FSEvents on `~/.codex/sessions`. On a change, Workdeck reads at most the last 256 KB of the most recently modified session file and takes the newest `token_count` line's `rate_limits`; only lines containing `"token_count"` are decoded, and only `rate_limits` and the line's timestamp are kept. At launch the newest file is read the same way, so nothing is persisted by Workdeck.
- **`codex app-server`** is asked at launch, when the popover opens (at most once a minute) and from the refresh button in the expanded notch. One request at a time, 15 s timeout, the process ended after the answer. A newer answer replaces the file values; free resets come only from here. The `codex` binary is looked up in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, npm's global prefix, then the newest `~/.vscode/extensions/openai.chatgpt-*/bin/**/codex`; an app started from Finder has no shell `PATH`.
- **Windows:** `window_minutes` 300 → 5-hour, 10080 → weekly; other lengths go to the nearer of the two. A missing window is not shown.
- **Plan label:** `plus` Plus, `pro` Pro, `prolite` Pro Lite, `team` Team, `business` Business, `enterprise` Enterprise, `edu` Edu, others capitalized.
- **Forecast, alerts and resets** work as for Claude: the shared thresholds (§3.4), a reset alert when a window that was near its limit resets, fired-alert memory `codexLimits.firedAlertKeys`. A Codex limit alert opens nothing on click.
- **No data:** Codex not installed → no block, the popover row says `Codex not found`; an API-key sign-in → no block, Settings explains "Plan limits need Sign in with ChatGPT"; old data → shown with its age (`updated 3h ago`).

### 3.3 Codex Sessions

- **Connecting.** Settings → Codex → **Connect…** shows the diff of `~/.codex/hooks.json` (created when missing) in the existing review sheet (`SettingsReview`), backs it up to `~/.codex/hooks.json.workdeck-backup`, and adds `"<app>/Contents/Helpers/workdeck-hook" --agent codex` to the ten events of §2.2 with a 5 s timeout. **Disconnect…** shows its diff and removes only Workdeck's entries. A file that changed since the review is refused, as for `settings.json`. Sessions already running pick up the hooks at their next start.
- **Storage.** `workdeck-hook --agent codex` writes to `~/Library/Application Support/Workdeck/sessions-codex/`, one file per session, in today's event format with the same trimming and deletion.
- **Payload filter (allowlist).** Kept: event name, session, turn, agent and tool call IDs, `agent_type`, the project folder (`cwd`), `transcript_path`, `source`, `reason`, `stop_hook_active`, the host app (§3.3 last item) and the PID. Actions: `Bash` → `Bash <first 30 characters of the command>` with secret-looking values masked as for Claude; `collaborationspawn_agent` → an agent launch with the first 30 characters of `task_name`; `collaborationwait_agent` → `Waiting for agent`; any other tool → its name only. Never kept: `prompt`, `last_assistant_message`, `tool_response`, `message`, `description`.
- **Status.** `UserPromptSubmit` and tool events → working; `PermissionRequest` → waiting for you until the session's next event; `Stop` → the turn is finished (idle); `Interrupt` → idle; `SessionEnd` → the session goes; `SubagentStart` / `SubagentStop` → agents of the session's tree; tool events with an `agent_id` → that agent's current step. The existing reducer takes these as Claude's events, with `PermissionRequest` playing the part of Claude's permission-prompt notification.
- **Line counts.** While a Codex session works, Workdeck reads the tail of its session file (`transcript_path`) as it grows and decodes only `patch_apply_end` lines; for each change it counts the `+` and `−` lines of `unified_diff` and keeps the file's base name and the two counts, never the diff. Each becomes a step `Edit <file> +N −M` in the ticker and adds to the turn total. The path must lie under `~/.codex/sessions`; anything else is ignored.
- **Liveness and host.** The hook records the PID of its nearest ancestor process whose executable is named `codex` (`proc_pidpath`), so liveness works as for Claude; without one the session ends by its events or goes stale after the usual silence. The host app comes from the environment as for Claude (`__CFBundleIdentifier`, `TERM_PROGRAM`, the TTY), so clicking a session brings forward its VS Code window or its Terminal or iTerm2 tab.

### 3.4 Popover and Settings

- **Popover:** a **Codex** row under Claude Code with a switch and a subtitle (`7d 3% · 1 session`, `Codex not found`, `Not connected`). Its switch only adds or removes Codex's part of the notch; the notch shows while any agent is enabled.
- **Settings sections:** General · Closed-Lid Mode · **Notch** (new) · Claude Code · Limits · Claude Code · Sessions · Claude Code · Instances · **Codex** (new) · About.
- **Notch** gathers what applies to every agent, moved from the Claude Code sections: Show (Always, When active), Without a notch, the two alert thresholds and the reset alert, the forecast, Notify when a session finishes (and after how long), Notify when a session needs you, Keep Mac awake while an agent works. The `UserDefaults` keys stay as they are, so every choice carries over.
- **Codex** section: the Codex version and plan, the limits' state and age, session hooks with Connect… and Disconnect…, and the API-key note of §3.2.
- **Copy Diagnostics** adds Codex: installed or not, version, hooks connected, limits age, `app-server` status; no prompts, no paths beyond folder names.

### 3.5 Demo

The demo (`specs/2026-10-14-demo-mode-design.md`) gains a Codex session working in parallel and a Codex block, through the composer (§4).

## 4. Architecture

| Component | Location | Role |
|---|---|---|
| Shared notch files | `Workdeck/Features/Notch/` | `NotchPresenter`, the notch views (limits, sessions, recap card), `TerminalStyle`, `NotchFlash`, `NotchPeek`, `NotchCountdown`, `LimitsPresentation` move here from `Features/ClaudeCode/` with `git mv`, unchanged. |
| `AgentKind` (new) | `Features/Notch/` | `claudeCode`, `codex`: mark, color, name. |
| `AgentSource` (new protocol) | `Features/Notch/` | What an agent tool gives the notch: `isEnabled`, `hasSource`, limit blocks (`AccountLimitsViewState` with `agent`), sessions (`ClaudeSession` with `agent`), last activity, an `onChange` callback and an alerts callback; the refresh action. |
| `NotchComposer` (new, `@Observable`) | `Features/Notch/` | Owns `NotchPresenter`: merges the sources, picks the compact account, decides visibility (mode, peek, linger, notchless display), shows alerts and the recap, menu bar text and level, the demo override. Takes over that logic from `ClaudeCodeController.refresh()`. |
| `ClaudeCodeController` | existing | An `AgentSource`; keeps limits, usage API, hooks, instances, Chats, recap and Statistics; asks the composer to show the recap. |
| `CodexController` (new) | `Features/Codex/` | An `AgentSource` and the Codex popover row and Settings section. |
| `CodexLimitsSource` (new) | `Features/Codex/Limits/` | §3.2: the session-file watcher and tail parser, the `app-server` client behind a process-runner protocol, the plan labels. |
| `CodexSessionsController` (new) | `Features/Codex/Sessions/` | §3.3: the hooks connector (on `SettingsReview`), the session store on `sessions-codex`, the line counter on session files. |
| `HookPayloadFilter`, `HookRunner` | `ClaudeHooks/` | `--agent codex`: its directory, its allowlist and action names, the `codex` ancestor PID. |
| `NotchSettings` (new) | `Features/Notch/` | The shared settings of §3.4 over the existing keys. |

## 5. Testing

Swift Testing; no real `~/.codex`, network, Keychain or `~/.claude*`.

- Composer: merging two sources, block order, marks only with two agents, the compact account across agents, counters, visibility with one agent off or both off, alerts from both, the demo override. The existing controller tests keep passing after the move to the composer.
- Codex limits: `token_count` lines (both windows, weekly only, missing `rate_limits`, a corrupt line, a 256 KB tail cut mid-line), window mapping, plan labels, the `app-server` exchange and its timeout with a fake process, newer value wins, free resets.
- Hooks connector: the diff for a missing, empty and populated `hooks.json`, backup, Disconnect keeps foreign entries, a changed file is refused.
- Payload filter: Codex actions and masking, the never-kept fields, `--agent codex` directory.
- Reducer: Codex event sequences (permission, interrupt, agent with its own steps, session end).
- Line counter: `patch_apply_end` with one and several files, a move, a path outside `~/.codex/sessions`.
- Settings migration: values saved under the old sections read the same in Notch.
- Manual: new rows in `docs/testing.md` (CLI session, extension session, permission request, agent, edit with counts, limits without a session, Codex not installed, both agents at once).

## 6. Documentation

`docs/codex.md` (setup, what is read and kept, the hooks diff), README (feature list, setup, privacy), `docs/claude-code.md` (settings that moved to Notch), `CLAUDE.md` (`Features/Notch/`, `Features/Codex/`, the composer and `AgentSource`), `docs/testing.md` rows, `TODO.md` (stage 3).
