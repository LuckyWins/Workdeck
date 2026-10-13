# Workdeck — Settings Diff Before Connecting Design

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

Connecting the status line or the session hooks writes `~/.claude/settings.json` (and the `settings.json` of each extra instance) after a one-line alert. Disconnecting writes it with no confirmation at all. This spec shows the real change first: Connect and Disconnect open a block in Settings with a line diff of every file they would change, and write only after the user confirms what they saw.

This is item 4 of TODO's Planned list.

### Goals

- See exactly what Workdeck will change in each `settings.json` before it writes.
- Never write over changes the user has not reviewed.

### Non-Goals

- Previewing the silent writes that keep an agreed connection working: pointing the commands at a moved app, adding hook events a new version subscribes to, connecting an instance added while main is connected.
- Keeping the user's key order and indentation. Workdeck still writes the file sorted and indented; the review says so (§3.3).
- Previewing Workdeck's own files (the chained status line config in Application Support).

## 2. Flow

### 2.1 Where It Opens

- **Settings, "Claude Code · Limits":** `Connect…` and `Disconnect…` next to "Status line" open the review block under that row.
- **Settings, "Claude Code · Sessions":** `Connect…` and `Disconnect…` for the session hooks open the block under that row.
- **Popover:** turning Claude Code on with nothing connected opens Settings (bringing it forward if it is open) with the status line's Connect block open.
- One block is open at a time; opening another closes the first. Closing Settings closes the block without writing.
- The two alerts ("Connect Claude Code?", "Connect session hooks?") are removed.

### 2.2 Which Files

- The main instance's `settings.json`, and each extra instance's that the action would change: the same instances the action changes today (an instance sharing main's file, or whose folder is missing, is skipped as today and reports its error as today).
- A file the action would not change gets no tab. If no file would change, the block is not opened and nothing is written; the connection state is read again instead, since the file may have changed outside Workdeck: Disconnect… still disconnects (Workdeck's entries are already gone), Connect… finds Workdeck already connected.
- Main's invalid file stops a Connect (its error shows in the footer); a Disconnect still reviews the other instances.

### 2.3 Confirming

- **Cancel** closes the block. Nothing is written.
- **Connect / Disconnect** re-reads every file in the block.
  - If any file's bytes differ from the bytes the diff was built from, nothing is written; the block shows the new diff with `settings.json changed since this preview. Review the new changes.` above it.
  - Otherwise the action runs as today, for the reviewed files only: Connect backs up each existing file next to it (`settings.json.workdeck-backup`) and writes; Disconnect writes. Each file is checked once more right before it is written and left alone if it changed in that moment (`settings.json changed since this preview…` in the footer or the instances list).
- Errors after confirming (a write failing) show where they show today: the section footer and the instances list.
- A file that is not valid JSON fails before the block opens, with today's footer message.

## 3. Review Block

### 3.1 Layout

```
Claude Code · Limits
 Status line                                     [Connect…]
 ┌ Changes to settings.json ────────────────────────────┐
 │ [ main │ personal ]                                  │
 │ ~/.claude/settings.json                              │
 │ Workdeck also sorts the keys and re-indents this     │
 │ file.                                                │
 │ ┌──────────────────────────────────────────────────┐ │
 │ │   "model": "opus",                               │ │
 │ │   "statusLine": {                                │ │
 │ │ -   "command": "~/bin/my-statusline.sh",         │ │
 │ │ +   "command": "'/Applications/Workdeck.app/Con  │ │
 │ │ +   tents/Helpers/workdeck-statusline'",         │ │
 │ │     "type": "command"                            │ │
 │ │ ⋯ 12 unchanged lines                             │ │
 │ └──────────────────────────────────────────────────┘ │
 │ A backup is saved next to each file. Your previous   │
 │ status line keeps running after Workdeck's.          │
 │                                 [Cancel]  [Connect]  │
 └──────────────────────────────────────────────────────┘
```

- **Title:** `Changes to settings.json`.
- **Tabs:** a segmented control with one tab per changed file, named by instance, `main` first and the others by name; hidden with a single file. When the review refreshes, the first tab whose change is new or different is selected.
- **Path:** the file's path with `~`, as the user knows it (a symlink's own path).
- **Note:** `Workdeck also sorts the keys and re-indents this file.` when the file exists and its bytes differ from Workdeck's formatting of the same JSON.
- **Diff:** monospaced, 10 pt, at most about 220 pt high, then it scrolls. Long lines wrap; no horizontal scrolling.
- **Explanation**, by action:
  - Connect the status line: `A backup is saved next to each file.` plus, when a file has its own status line, `Your previous status line keeps running after Workdeck's.`
  - Connect the hooks: `A backup is saved next to each file. Your own hooks stay as they are.`
  - Disconnect the status line: `Your previous status line comes back.` when one was chained, otherwise nothing.
  - Disconnect the hooks: `Only Workdeck's hooks are removed.`
- **Buttons:** `Cancel` and `Connect` (or `Disconnect`), the latter the default.

### 3.2 Diff

- Line diff (longest common subsequence) of the file's text before and after, both in Workdeck's formatting (§3.3).
- Removed lines with `-` on a red background, added lines with `+` on a green background, context lines with two spaces. No line numbers.
- Three context lines around each change; changes closer than that join one hunk. Unchanged lines between hunks, and before the first and after the last, collapse into `⋯ N unchanged lines`; a single unchanged line is shown instead of folded.
- A missing file shows every line as added.
- When the line counts multiplied exceed 1,000,000, the diff shows only `File too large to preview`; confirming still works.

### 3.3 Formatting

Both sides are rendered as Workdeck writes the file: `JSONSerialization` with sorted keys, pretty-printed, without escaping slashes. The diff therefore shows only what Workdeck changes; the note in §3.1 says when the file's own formatting will change too. After Workdeck's first write the file is already in this format, and the diff is the file's real line diff.

### 3.4 Secrets

The diff can show context from the `env` block, which sorts right before `hooks` and may hold API keys. In every displayed line:

- a JSON string value whose key contains `KEY`, `TOKEN`, `SECRET`, `PASSWORD`, `AUTH`, `CREDENTIAL` or `HEADER` (any case) is shown as `"…"`;
- inside an object or array under such a key, every string value is shown as `"…"`;
- credentials in a URL (`scheme://user:password@host`) are shown as `scheme://…@host`.

Lines are compared unmasked, so a changed secret still shows as a changed line. Only the display changes; the file is written as planned.

## 4. Architecture

| Component | Change |
|---|---|
| `LineDiff` (new, pure, `nonisolated`) | `hunks(old:new:context:)` → blocks of context / removed / added lines and collapsed counts, or "too large". |
| `SettingsSecretMask` (new, pure) | Masks secret-looking string values in a line. |
| `ClaudeSettingsFile` | Reads the JSON and its bytes together; one formatting function shared by writing and by the review; `isUnchanged(since:)` compares the current bytes with the reviewed ones. |
| `SettingsChange` (new) | One file's plan: instance name, path, original bytes (`nil` for a missing file), text before and after, whether the file gets reformatted. |
| `ClaudeCodeConnector`, `SessionHooksConnector` | `plannedConnect()` and `plannedDisconnect()` build a `SettingsChange` (or `nil` when nothing changes) with the same pure transforms `connect()` and `disconnect()` use, without writing. `connect()` and `disconnect()` stay for the silent writes. |
| `ClaudeLimitsController`, `ClaudeSessionsController` | `reviewConnect()` / `reviewDisconnect()` build the review (main plus the extra instances the action changes); `confirmReview()` checks every file and either refreshes the review with the notice or runs today's `connect()` / `disconnect()`; `cancelReview()`. The `isConfirming…` flags go. |
| `SettingsChangeReview` (new view) | The block of §3.1. |
| `ClaudeLimitsSettingsSection`, `ClaudeSessionsSettingsSection` | Buttons open the block; alerts removed. |
| `ClaudeCodeController.setEnabled`, `ClaudeCodeRow` | Opens Settings with the status line review requested; the popover alert goes. |

## 5. Edge Cases

| Condition | Behavior |
|---|---|
| No `settings.json` yet | Every line added; no reformat note; no backup. |
| `settings.json` is a symlink | The link's path is shown; the bytes compared are the target's; writing keeps the link (as today). |
| The user had their own status line | Connect shows the command being replaced and says it keeps running; Disconnect shows it coming back. |
| A file changed after the diff was shown | Nothing written; new diff with the notice. |
| Settings closed with the block open | Same as Cancel. |
| The popover toggle while Settings is open | Settings comes forward with the status line block open. |
| An extra instance shares main's file or its folder is missing | No tab; its error shows in Instances as today. |

## 6. Testing

Unit tests use temporary folders only; never the real `~/.claude*`.

- **`LineDiff`:**
  - identical texts give no hunks;
  - added, removed and replaced lines;
  - three context lines and collapsed counts;
  - nearby changes join one hunk;
  - a missing old text; the size limit.
- **`SettingsSecretMask`:** masks string values of keys with `KEY`, `TOKEN`, `SECRET`, `PASSWORD` in any case; leaves other lines and non-string values alone.
- **Connectors:**
  - a plan never writes (the file's bytes are unchanged after planning);
  - the status line plan on a missing file, with the user's own status line, on a file already in Workdeck's format (no note), and on an unsorted file (note);
  - the disconnect plan restores the chained status line;
  - the hooks plan adds the events and keeps the user's hooks;
  - nothing to change gives `nil`.
- **Controllers:**
  - the review holds main and the extra instances the action changes;
  - confirming with unchanged files connects;
  - a file changed after review writes nothing and refreshes the review with the notice;
  - cancel writes nothing.
- **Manual rows** in `docs/testing.md`:
  - Connect and Disconnect of the status line and the hooks;
  - two accounts;
  - editing `settings.json` while the block is open;
  - the popover toggle.

## 7. Documentation

- README: Connect and Disconnect show the change to each `settings.json` before writing.
- `docs/testing.md`: the manual rows of §6.
