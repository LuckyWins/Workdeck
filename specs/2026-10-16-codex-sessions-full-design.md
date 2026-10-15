# Workdeck — Codex Sessions as Full as Claude's Design

**Date:** 2026-10-16
**Status:** Approved; implemented

## 1. Overview

A Codex session in the notch shows less than a Claude Code session: its agents are all named `default`, its edits show no `+N −M`, its turn has no `this turn · N files +A −R` total, and the recap and Statistics count no Codex files or lines. Its edits read `apply_patch` and some tools read `webrun` or `clockcurr_time`.

The line counts were meant to come from `patch_apply_end` lines of Codex's session files (Codex support spec §3.3), but the current Codex does not write them: a session file of 2026-10-15 with 59 `apply_patch` edits has none. This change takes everything from Codex's hooks instead, as for Claude Code, and stops reading session files for sessions.

### Goals

- Codex edits counted as Claude's: lines on the step, the turn's total, the agent's own edits, and files and lines in the recap and Statistics.
- Codex agents named after their task.
- Codex's own tools and edits read like Claude's steps.
- Workdeck reads Codex session files only for `token_count` (limits).

### Non-Goals

- Codex's `reasoning_effort` or a session's model in the row (Claude Code rows show neither).
- Edits Codex makes through shell commands (`sed -i`, `cat >`): as for Claude's Bash, they are not counted.
- The Codex chats list or several Codex accounts (their own TODO items).

## 2. What Codex Sends (probes of 2026-10-16)

Two probes logged only field names and value types (and, for IDs, short hashes), with a backup of `~/.codex/hooks.json` restored after each.

- `apply_patch`, `PreToolUse` and `PostToolUse`: `tool_input` is `{"command": "<patch>"}`, the whole patch in Codex's format: `*** Begin Patch`, then per file `*** Add File: <path>`, `*** Update File: <path>` (optionally followed by `*** Move to: <path>`) or `*** Delete File: <path>`, hunks of lines starting with `@@`, ` `, `+` or `-`, and `*** End Patch`. `PostToolUse`'s `tool_response` is a string starting with `Exit code: <n>`.
- `collaborationspawn_agent`: `tool_input` holds `task_name`, `fork_turns`, `model`, `reasoning_effort` and `message`; `tool_response` is `{"task_name": "<path-like name>"}`, without the new agent's ID.
- `SubagentStart` (`agent_id`, `agent_type`, `model`) follows its spawn's `PostToolUse` before the next spawn starts, also when two agents are asked for in parallel.

## 3. Behavior

### 3.1 Edits

- A patch of one file is the step `Edit A.swift` (a moved file shows its new name); deleting one file is `Delete A.swift`; a patch of several files is `Edit 3 files`.
- Once applied (`tool_response` starts with `Exit code: 0`), the step shows the patch's lines, e.g. `Edit 3 files +12 −4`, and they join the turn's total; the patch's files join the turn's files. A failed patch adds nothing.
- Lines are the hunks' `+` and `-` lines, all files together. A deleted file counts as a file without lines (Codex does not send its contents); an added file counts every line.
- A file with several sections in one patch is one file; patch lines may end in `\r\n`.
- An agent's own patches show on its row, as Claude's agents' edits do.
- The recap and Statistics count Codex files and lines from the turn, as Claude's.

### 3.2 Agent Names

- Each spawn that started an agent (its `PostToolUse` response holds `task_name`) leaves its full `task_name` waiting in its session; a failed spawn leaves none; the next `SubagentStart` without a description takes the oldest waiting name. A new prompt, `Stop` and `Interrupt` clear the waiting names, so a name from a launch that never started an agent does not go to another. Codex sends no key that pairs a spawn with its agent: if a subagent and the main agent spawn at the same moment and the later spawn's agent starts first, their names swap.
- The row shows the name readable: `swift_file_inventory` becomes `Swift file inventory` (underscores to spaces, first letter upper case). The stored name is unchanged.
- Trimming a large event file keeps the current turn's spawns, agent starts and stops, so a relaunch names the agents the same.
- The type `default` is hidden as Claude's built-in types are; an agent without a name (started before this version) shows `Agent`.

### 3.3 Tool Names

- `webrun` shows as `Web`, `clockcurr_time` as `Clock`; other Codex tools keep their names. `Bash`, `apply_patch` and the agent tools are covered above and in the Codex support spec.

## 4. Data and Privacy

- `workdeck-hook --agent codex` keeps, besides what it keeps today:
  - on `apply_patch`'s `PreToolUse`: the action (§3.1), from the patch's file headers only;
  - on its `PostToolUse` with `Exit code: 0`: the added and removed line counts and up to 20 edited files' base names, each at most 100 characters;
  - on `collaborationspawn_agent`'s `PostToolUse` whose response holds `task_name`: the input's `task_name`, at most 100 characters.
- It no longer keeps the session file's path. The patch text, `message`, `tool_response` and paths are never kept.
- The app no longer reads Codex session files for sessions: `CodexPatchReader` and `CodexPatches` go. `CodexSessionFiles` stays for limits (`token_count`).
- Event files written by an older version still read; their `transcriptPath` is ignored.

## 5. Architecture

| Unit | Where | Change |
|---|---|---|
| `CodexPatchText` (new) | `ClaudeHooks/` | Parses a Codex patch: per file its base name and kind (add, update, delete, move target), and the `+`/`-` counts. Pure, `nonisolated`. |
| `HookPayloadFilter` | `ClaudeHooks/` | `action(toolName:input:)`: `apply_patch` → §3.1's action; `webrun` → `Web`, `clockcurr_time` → `Clock`. Codex `PostToolUse` of `apply_patch` → line counts and files when the response starts with `Exit code: 0`. Spawn → `agentTaskName`. Codex's tools are recognized by their names (`apply_patch`, `collaborationspawn_agent`, `webrun`, `clockcurr_time`), which Claude Code never sends. |
| `HookEvent` | `ClaudeHooks/` | Gains `editedFiles: [String]?` (Codex patches; Claude keeps `editedFile`) and `agentTaskName: String?`. `transcriptPath` stays decodable, no longer written. |
| `HookRunner` | `ClaudeHooks/` | Stops adding the session file's path for Codex. |
| `SessionReducer` | `Features/ClaudeCode/Sessions/` | `addEdit` inserts `editedFiles` too. A spawn's `agentTaskName` queues in the session; `SubagentStart` without a description takes the oldest; a prompt, `Stop` and `Interrupt` clear the queue. |
| `ClaudeSession` | same | `pendingAgentNames: [String]` (in memory, rebuilt from events like the rest). |
| `SessionsPresentation` / `AgentRow` | same | Codex agent names made readable; `default` hidden; no name → `Agent`. |
| `CodexSessionsController` | `Features/Codex/Sessions/` | Lists the store's sessions as they are; the patch reader goes. |
| `CodexPatches.swift` | `Features/Codex/Sessions/` | Deleted with its tests. |

## 6. Testing

- `CodexPatchText`: one updated file, an added file, a deleted file, a moved file, several files, `+++`/`---`-like content lines inside hunks counted as content, an empty or malformed patch.
- `HookPayloadFilter` / `HookRunner` with `--agent codex`: actions for one file, several files and a delete; counts and files only with `Exit code: 0`; no counts for a failed patch; the patch text is never in the event file; the spawn's task name kept and cut at 100; no session file path written; `webrun` and `clockcurr_time` names. Claude's events unchanged.
- `SessionReducer`: a Codex patch's lines on its step and in the turn with all its files; an agent's patch on the agent's row; two spawns then two starts get their names in order; a prompt between a spawn and a start clears the name.
- `SessionsPresentation`: a readable Codex name, `default` hidden, `Agent` without a name.
- The recap gets Codex files and lines through the turn (an existing recorder test with a Codex session's turn).
- `docs/testing.md`: a manual check with a real Codex session (an edit of one and of several files, a spawned agent).

## 7. Documentation

`docs/codex.md` (edits and agent names, what the hook keeps, no session file reading for sessions), `CLAUDE.md` (the `WorkdeckHook` and `Features/Codex` bullets: no session file path, no `patch_apply_end`), the Codex support spec §3.3 (superseded by this spec), `docs/testing.md`, `TODO.md` item 8.
