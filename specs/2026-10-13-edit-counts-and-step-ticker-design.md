# Workdeck — Edit Line Counts and Step Ticker Design

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

The expanded notch shows what each session is doing now, one action per row. This spec adds two things:

- **Line counts.** Every file edit shows how many lines it added and removed (`+12 −3`, green and red), and each session shows the total for its turn (`this turn · 5 files +84 −21`).
- **Step ticker.** The session in focus shows its last three steps instead of one action, older ones dimmer, the current one bright.

This is item 3 of TODO's Planned list.

### Goals

- See how much a session changed without opening the editor, including after it stopped.
- Follow what the session in focus has been doing for the last few steps, not only the current one.
- Keep the hook's privacy rule: no prompt, answer or file content is ever stored.

### Non-Goals

- Counting changes made through Bash (`sed`, `git checkout`, generators) or NotebookEdit.
- Showing the diff itself, or opening it on click.
- Counts in the compact notch, the popover row or the menu bar text.
- A step ticker for agents (their cards keep one action) or for more than one session.

## 2. Hook and Data

### 2.1 Counting

Counts come from the tool's response in `PostToolUse`, which Claude Code sends after an edit is applied. A denied or failed edit sends no `PostToolUse` and is not counted.

For `Edit`, `MultiEdit` and `Write`, `HookPayloadFilter` reads `tool_response`:

- **`structuredPatch` present and non-empty:** across all hunks' `lines`, lines starting with `+` are added and lines starting with `-` are removed. Context lines (` `) and markers (`\ No newline at end of file`) are not counted.
- **`Write` with `type == "create"` and an empty patch:** every line of `content` is added; a trailing newline does not make an extra line, and empty content is `+0`.
- **Any other shape** (no response, a missing or malformed patch, an update with an empty patch): no counts.

The text is read only to count lines. It is never stored or logged.

### 2.2 Event Fields

`HookEvent` gets four optional fields:

| Field | Events | Value |
|---|---|---|
| `toolUseID` | `PreToolUse`, `PostToolUse` | `tool_use_id`, kept only when it is 1–64 ASCII letters, digits, `_` or `-`. Matches a tool call's two events. |
| `linesAdded`, `linesRemoved` | `PostToolUse` of `Edit`, `MultiEdit`, `Write` | The counts of §2.1; both absent when there are none. |
| `editedFile` | Same as the counts | The file name of `tool_input.file_path` (no directories, at most 100 characters), as already shown in the action. |

Event files written by an earlier hook decode with these fields absent. The 4 MB input limit stays: a `PostToolUse` for a very large file is dropped whole, as today, and the step shows no counts.

### 2.3 Session State

`SessionReducer` adds:

- **`ClaudeSession.steps`:** the main agent's last three steps, oldest first: `toolUseID`, action, and counts once known. A `PreToolUse` without an agent ID appends a step and drops the oldest beyond three. `UserPromptSubmit` and a new session (`SessionStart` other than `compact`) clear the list; `Stop` keeps it.
- **Counts on the current action:** the session's current action and each running agent's action carry the counts of their tool call (`actionLines`). A new action starts without counts.
- **`PostToolUse` with counts:** the step and the current action (of the session or of the agent with that agent ID) whose `toolUseID` matches get the counts. A step already pushed out of the list, an agent that already stopped, or an event without `toolUseID` changes only the turn total.
- **Counts before their step:** each hook stamps its own time, so a fast edit's `PostToolUse` can be a moment earlier than its `PreToolUse`. Counts that match nothing wait (the newest 8, cleared by a prompt) and go to the step or agent action of the same tool call when it arrives.
- **`ClaudeSession.turn`:** lines added, lines removed, and the set of edited file names since the last `UserPromptSubmit`. Edits by the main agent and by every agent count. `UserPromptSubmit`, `SessionStart` with `startup`, `resume` or `clear` reset it; compaction does not. Edits after `Stop` (a background agent finishing) still add to it until the next prompt.

Files are told apart by name: two files with the same name in different folders count as one.

### 2.4 Event File Trimming

`SessionFileTrimmer` also keeps, among the older lines it would cut, the current turn's `UserPromptSubmit` and its newest 500 events with counts (about 225 KB), so a relaunch rebuilds the same turn total. Keeping every one would let a turn of a couple of thousand edits stay above the 1 MB trim size and be rewritten again and again; past 500 older edits, a relaunch shows a smaller total.

## 3. Display

### 3.1 Layout

```
— sessions ——————————————————————————————— 3 —
● vitastir                   waiting for you
    this turn · 1 file                    +4
● Workdeck                       working  4m
    · Read LimitsText.swift                       ← faint
    · Edit LimitsText.swift            +6 −2      ← dim
    ▸ Agent Explore                               ← bright, current
├ ⠋ Find rate limit usages · Opus 5.5     1m
│   Edit RateLimit.swift     +12 −3  7 steps
└ ⠙ Plan the store                        3m
    Read Store.swift                  1 step
    this turn · 5 files              +84 −21
● pokemon    Edit camera.dart  +3 −1      9m
    this turn · 1 file                 +3 −1
```

### 3.2 Session in Focus

- The focused session is the first working or compacting session in display order: the one that most recently started working. It changes only when that session stops or another starts working, never on each action.
- Its row shows the status (`working`, `compacting`) on the right instead of the action.
- Under the row, up to three step lines in the agents' small font, indented to the project name: earlier ones in `Terminal.faint` with `·` (changed 2026-10-13: a dim middle step looked like an agent's current action), the current one in `Terminal.text` with `▸`. With fewer steps, fewer lines; with none (thinking before the first tool call), none.
- A session waiting for you is never focused; nothing working means no ticker.
- Agent launches (`Agent …`, `Task …`) stay out of the ticker: the agent cards show them (changed 2026-10-13). While the latest step launched an agent, no step is marked current; the next step of the main agent is current again.

### 3.3 Counts

- Shown after the action on the focused session's step lines, on other working sessions' rows, and on agents' second line.
- `+N` green, `−M` red; on a dimmed line they take the line's dimming. A zero part is not shown (`+4`, `−3`); with both zero, nothing.
- When a line is too narrow, the action is truncated; the counts always stay visible.

### 3.4 Turn Total

- The last line of a session's block, after its agents: `this turn · N files` (or `1 file`) in `Terminal.dim` on the left, the counts on the right.
- `this turn` while the session works, waits or compacts; `last turn` once it is idle, until the next prompt. An idle session's block is already dimmed.
- No line when the turn has no edits.

### 3.5 Motion

- A new step slides in at the bottom of the ticker and the oldest fades out at the top (`.snappy`, keyed by step). Since 2026-10-13 the ticker's motion follows `specs/2026-10-13-notch-polish-design.md` §4.
- Counts fade in when the edit lands.
- When focus moves, the old session's ticker collapses and the new one expands.
- No frames run for this beyond the expanded notch's existing timeline.

## 4. Architecture

| Component | Change |
|---|---|
| `HookPayloadFilter` | `lineCounts(toolName:response:)`, `toolUseID` validation, `editedFile`; reads `tool_response` only for the three edit tools. |
| `HookEvent` | `toolUseID`, `linesAdded`, `linesRemoved`, `editedFile`. |
| `ClaudeSession`, `RunningAgent` | `steps`, `turn`, `actionLines`. |
| `SessionReducer` | §2.3. |
| `SessionFileTrimmer` | §2.4. |
| `SessionsPresentation` | Focused session, step rows with brightness levels, counts on rows and agents, turn line. |
| `SessionsText` | Counts text without zero parts, `this turn` / `last turn`, `N files`. |
| `SessionsList` | Ticker, counts, turn line, transitions. |

## 5. Edge Cases

| Condition | Behavior |
|---|---|
| The main agent edits two files in parallel | Each step gets its counts by `toolUseID`. |
| Counts arrive after their step left the ticker | Only the turn total changes. |
| An agent stops before its `PostToolUse` arrives | Only the turn total changes. |
| An edit is denied or fails | No counts; the step stays without them. |
| Events from an earlier hook, or no `tool_use_id` | No counts on steps; counts without an ID go to the turn total. |
| Bash or NotebookEdit changes files | Not counted (§1 Non-Goals). |
| No working session | No ticker; idle sessions show `last turn` lines. |
| Compaction | Counts as working: the ticker stays, the row says `compacting`. |
| `--resume`, `/clear`, a new session | The ticker and the turn total start over. |

## 6. Probe (first implementation task, run together with the user)

Only the hook part is built and installed first. In this Claude Code session the agent makes one `Edit`, overwrites a file with `Write`, and creates a new file with `Write`; then it reads this session's event file, which holds only the allowlisted fields. It checks that:

1. the counts match what Claude Code reports for each edit ("Added N lines, removed M lines");
2. `PreToolUse` and `PostToolUse` of each call carry the same `toolUseID`.

If `PostToolUse` has no `structuredPatch` or no `tool_use_id`, the work stops and the approach is discussed again. Results are recorded in §8.

## 7. Testing

- **Filter:**
  - counts across several hunks without context and marker lines;
  - a new file with and without a trailing newline, and an empty one;
  - malformed responses;
  - `toolUseID` validation;
  - no counts for other tools;
  - an encoded event holds no edit text.
- **Reducer:**
  - the ticker keeps the last three steps and a prompt clears it;
  - counts reach the right step, including parallel calls;
  - agents' action counts;
  - the turn total sums the main agent and agents with file names deduplicated, resets on prompt, startup, resume and clear, and survives compaction.
- **Trimmer:** a trimmed file rebuilds the same turn total.
- **Presentation:**
  - the focused session;
  - step brightness levels;
  - counts on rows and agents;
  - `this turn` and `last turn`;
  - no turn line without edits;
  - zero parts hidden.
- **Manual rows** in `docs/testing.md`: counts on an edit, the ticker on the focused session, `last turn` after Stop, focus moving between two sessions.

## 8. Probe Results

Probed on 2026-10-13 in a VS Code session: a `Write` creating a three-line file recorded `+3 −0`, a `Write` overwriting it (one line changed, one added) `+2 −1`, and an `Edit` replacing two lines with one `+1 −2`, matching the diffs. Each call's `PreToolUse` and `PostToolUse` carried the same `toolUseID` (`toolu_…`), and the event lines held no file text. `PostToolUse` does carry `structuredPatch`.

## 9. Documentation

- README: line counts and the step ticker.
- `docs/testing.md`: the manual rows of §7.
- `specs/2026-10-06-claude-sessions-design.md` §10.7: tool calls also keep the edited file's name and its added and removed line counts.
- `CLAUDE.md`: besides the action summary from tool input, the hook keeps only line counts and the file name from an edit's response, and the tool call ID.
