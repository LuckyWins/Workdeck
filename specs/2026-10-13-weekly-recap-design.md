# Workdeck — Weekly Recap Design (Stage 1: Collection and Notch Card)

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

On the first unlock of a new week the notch shows what last week looked like with Claude Code: how long Claude worked, sessions, files, lines, commands, agents, the busiest day, the longest stretch of work, the top projects and, per account, how often the 5-hour limit was hit and the weekly peak. Workdeck collects the numbers itself while it runs, because the session event files are deleted when a session ends.

This is item 6 of TODO's Planned list, stage 1 of 2. Stage 2 (a "Weekly Recap…" window from the popover with daily bars by project, a project and account table, and earlier weeks) gets its own spec and reads the same data.

Inspired by Coucou's recap (`RecapStore`), adapted: coding time counts only Claude's work, sessions are real sessions, the busiest day and top projects go by time, and limits are added.

### Goals

- See last week's work at a glance on Monday, without opening anything.
- Keep only counts and names: no prompts, answers, file contents or paths.

### Non-Goals

- The recap window and charts (stage 2).
- A share image.
- Counting time while Workdeck is not running, or before this version.
- Questions answered and permission decisions (Workdeck does not answer either).

## 2. Metrics

| Metric | How it is counted |
|---|---|
| Coding time | Time when at least one listed session is `working` or `compacting`, or has running agents. Parallel sessions are merged: two sessions working during the same hour give 1 h. Waiting for you and idle time do not count. Each moment is split evenly between the projects of the sessions working then, so the projects add up to the total. |
| Sessions | Sessions that had a prompt or a step during the week (blank and revived-but-unused sessions never count). A session working on several days counts once per week. |
| Files | Distinct edited file names (Edit, MultiEdit, Write) per project during the week, as the turn line counts them. |
| Lines | Lines added and removed by edits (the counts of `specs/2026-10-13-edit-counts-and-step-ticker-design.md`). |
| Commands | Bash tool calls, by the main agent and its agents. |
| Agents | Agents started (`SubagentStart`). |
| Busiest day | The day with the most coding time. |
| Longest work | The longest uninterrupted stretch of one session's work, from the moment it got busy until it was quiet again (background agents included), with its project: `Workdeck · 2h 14m`. |
| Top projects | The three projects with the most coding time, each with its time. |
| 5-hour limit hit | Per account, the number of 5-hour windows that reached 100% during the week; a window is identified by its reset time and counted once. |
| Weekly peak | Per account, the highest 7-day percentage seen during the week. |

- Workdeck counts from the hook events and usage snapshots it already reads, only while it runs; the time before a relaunch is already saved, and counting resumes after it.
- A stretch that crosses midnight is split between the days; days and weeks follow the Mac's calendar and time zone. A week runs Monday to Sunday.

## 3. The Card

```
─ last week · Oct 6–12 ─────────────────
 18h 42m coding · 23 sessions · 37 agents
 142 files  +4 820 −1 310 · 512 commands
 busiest   Thu · 5h 10m
 longest   Workdeck · 2h 14m
─ top projects ─────────────────────────
 Workdeck                         9h 03m
 vitastir                         6h 11m
 pokemon                          2h 40m
─ limits ───────────────────────────────
 main        5h hit 2×    7d peak 81%
 personal    5h hit 0×    7d peak 34%
                                [Got it]
```

- Amended 2026-10-13: the card takes a headline, a Monday–Sunday chart and a "Details…" button (`specs/2026-10-13-statistics-window-design.md` §4).
- The expanded notch's terminal style. `+` green, `−` red; the weekly peak takes the threshold colors of the limit bars.
- Fewer than three projects show fewer lines. The limits block lists every account with data during the week; without any, it is left out.
- Durations: `<1m`, `42m`, `2h 14m`, `18h 42m`. Numbers above 999 get a thin space (`4 820`).

### 3.1 When It Shows

- On the first screen unlock of a new week (normally Monday; if the Mac was not unlocked on Monday, the first day it is), and when Workdeck launches while last week's recap has not been dismissed.
- Only if last week had at least 15 minutes of coding time; otherwise that week is marked seen silently.
- In the notch Workdeck draws: the camera-housing notch, or the virtual notch on a display without one (e.g. an external monitor as the main display). Not in the menu bar text mode, and not with the indicator off (stage 2's window covers those).

### 3.2 How Long

- The notch expands with the recap for about 60 s; hovering keeps it open.
- Then it collapses, and the compact notch's right wing shows `◆` before the session counters.
- While `◆` shows: hovering the notch shows the recap instead of the usual expanded view; `Got it` dismisses the recap and `◆` until next week. In "When active" mode `◆` keeps the compact notch visible.
- Alerts: a "needs you" alert collapses an expanded recap to `◆` at once and shows; other alerts wait for the recap's minute to end, then show as usual. A recap never covers an alert already on screen: it waits for it to close.

## 4. Architecture

| Component | Responsibility |
|---|---|
| `RecapDay` (new, pure, Codable) | One day's totals: per project coding seconds, session IDs, edited file names, lines added and removed, commands, agents; the longest stretch (project, seconds); per account the 5-hour windows that reached 100% (by reset time) and the 7-day peak. |
| `ClaudeSession.commands` (reducer) | Bash tool calls of the session and its agents, counted from `PreToolUse` actions starting with `Bash`. |
| `RecapRecorder` (new) | Fed every sessions update (on each event and each minute) and each usage update. Adds to today: coding time since the previous update, split by project; new edits, files, commands and agents from the change in each session's counters (a session first seen after launch sets its baseline; a new turn starts from zero); a stretch when a session goes quiet; limits. |
| `RecapStore` (new) | `recap.json` in Workdeck's Application Support folder, schema version 1: written at most once a minute and on quit, atomically; days older than 12 weeks removed on load and on save; a file that cannot be read is renamed to `recap.corrupt-<timestamp>.json` and a new one starts. |
| `WeeklyRecap` (new, pure) | Builds a week's summary from its days: totals, top three projects, busiest day, longest stretch, limits per account, and whether it reaches 15 minutes. |
| `RecapText`, `RecapView` (new) | The card of §3. |
| `NotchPresenter` | The recap mode of §3.2 and its order with alerts. |
| `ClaudeCodeController` | Shows the recap on unlock (from `SessionActivityMonitor`) and at launch; remembers the dismissed week (`claudeRecap.dismissedWeek`); keeps the notch visible in "When active" while `◆` shows. |

## 5. Edge Cases

| Condition | Behavior |
|---|---|
| Workdeck quits during work | The time so far is saved; counting resumes at the next launch. |
| Session counters drop after a relaunch (trimmed event file) | The drop is ignored; only increases count. |
| Time zone or daylight saving changes | Days and weeks follow the Mac's calendar at the moment of counting. |
| An account was removed | Its rows stay in past days under its name. |
| `recap.json` is corrupt | Renamed aside, a new file starts. |
| The menu bar text mode or the indicator is off at the moment of unlock | The recap waits for the next unlock or launch with a notch shown. |

## 6. Testing

- `RecapRecorder` with synthetic session and usage updates: merged parallel sessions, the split between projects, a stretch over midnight, edits and files from counter changes and a new turn, commands, agents, the longest stretch, a 100% window counted once, the weekly peak, a session first seen after launch adding nothing.
- `WeeklyRecap`: totals, top three, busiest day, the 15-minute rule, week boundaries.
- `RecapStore`: round trip, pruning, a corrupt file.
- `RecapText`: durations and thousands separators.
- Presenter: 60 s and hover, `◆` after, `Got it`, "needs you" interrupting, other alerts waiting.
- Controller: unlock and launch triggers, once per week, the 15-minute rule, "When active".
- Manual rows in `docs/testing.md`.

## 7. Documentation

README (the weekly recap, what is stored and where), `docs/testing.md`, CLAUDE.md (where the recap's code and file live, and that it keeps only counts and names).
