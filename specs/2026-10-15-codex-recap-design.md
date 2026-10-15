# Workdeck — Codex in the Recap and Statistics Design

**Date:** 2026-10-15
**Status:** Approved; implemented

## 1. Overview

Stage 3 of Codex support (`specs/2026-10-15-codex-support-design.md`). The weekly recap card in the notch and the Statistics window count Codex's work next to Claude Code's. Both still show one week of coding, now across agents: the totals are the user's real coding time, a split line shows each agent's own time, and Statistics filters by agent.

The recap stops belonging to Claude Code, as the notch did in stage 1: an app-level `RecapController` owns the recorder, `recap.json`, the card and the Statistics window, and every agent tool feeds it.

### Goals

- Codex sessions, time, files, lines, commands, agents, longest session and limits in the recap and Statistics, counted as Claude Code's are.
- Totals that stay the user's real coding time when both agents work at once; each agent's own time true when filtered.
- Existing `recap.json` files read as Claude Code's work, nothing lost.
- With one agent only, the card and the window look as they do today.

### Non-Goals

- A share image, more than the kept twelve weeks, or other agents than Claude Code and Codex.
- Per-agent colors in the project chart: projects stay one bar across agents.
- Remembering the agent filter between openings of the window.

## 2. Counting Time

[Coucou](https://github.com/Louis-CFM/coucou) merges overlapping turns into one total and shows only a "top agent" by session count; it keeps no per-agent time. Workdeck keeps both:

- **Total:** each interval between updates is split evenly between all busy sessions of every agent, as today; a project's total time and the week's total are real time. An hour in which one Claude and one Codex session work gives the total 1h.
- **Per agent:** the same interval is split evenly between that agent's own busy sessions only. The same hour gives Claude Code 1h and Codex 1h.
- The split line can therefore sum to more than the total: the difference is time both agents worked at once.
- Everything else is as today (`RecapRecorder`): updates further apart than 2 minutes add no time (a sleeping Mac), midnight splits an interval, a session busy but silent for an hour is not counted, counts come from each session's baseline, and a stretch ends when its session is quiet or gone.

## 3. Behavior

### 3.1 The Notch Card

```
─ Last week · Oct 5–11 ──────────────
12h 40m                        ▇
23 sessions                 ▇  ▇ ▇
✳ Claude 10h 05m · ◎ Codex 4h 10m
61 files  +2 410 −530
212 commands · 14 agents
longest   ✳ Workdeck · 1h 48m
─ top projects
■ Workdeck                    6h 10m
■ vitastir                    3h 55m
■ docs-site                   1h 20m
─ limits
main          5h hit 1×  7d peak 83%
personal      5h hit 0×  7d peak 22%
◎ codex                  7d peak 41%
                  Details…  Got it
```

- The split line `✳ Claude 10h 05m · ◎ Codex 4h 10m` shows under the sessions count only when both agents have time that week; marks in the agents' colors (orange, mint). It is one line of about 34 characters, within the card's 40.
- Totals (sessions, files, lines, commands, agents) are across agents: sessions and files are unions, the rest sums.
- **Longest** is the longest stretch of any agent, with its agent's mark while the split line shows.
- **Projects** and the mini chart stay across agents: a project both worked on is one entry with its total time.
- **Limits:** Claude Code's accounts as today (main first, then by name), then Codex's account `◎ codex` with its 7-day peak; `5h hit N×` only when Codex's plan has a 5-hour window.
- With one agent that week, no split line and no marks: the card looks as today.

### 3.2 The Statistics Window

- Titled "Statistics" (was "Claude Code Statistics").
- Opened from a `chart.bar` button in the popover header next to the gear (help "Statistics"), replacing "Statistics…" in the Claude Code row, and from "Details…" on the card as today.
- A segmented control `All · Claude Code · Codex` under the toolbar, shown only when both agents have data in the kept weeks. Default All; it resets to All when the window opens.
- The filter applies to everything: the header (total, comparison, daily average), the chart, Most worked on, Work, Longest and Limits. Under Claude Code or Codex, times are that agent's own time (§2).
- The project filter (statistics spec §3.4) works inside the agent filter; changing the agent clears it, as changing the week does.
- Empty week: "No coding work this week." under All, "No Codex work this week." or "No Claude Code work this week." when filtered.
- The line "Coding time is counted while session hooks are connected." shows when no agent has its session hooks connected, or, when filtered, when that agent's are not.

### 3.3 Recording

- An agent's sessions count while its session hooks are connected, as Claude Code's do today; Codex's popover switch does not stop the counting (keep-awake does not follow it either).
- Limits are sampled from each agent's figures on each update: Claude Code per account, Codex from `CodexLimitsSource` only while the Codex tool is on or its session hooks are connected (its session files are read even while it is off; a disabled agent adds nothing).

### 3.4 Demo

- The demo recap gains Codex: a split line, Codex time on the docs-site project, and a `◎ codex` limits row. Nothing is saved, as today.

## 4. Data

`recap.json` keeps one entry per day, `schemaVersion` 2:

```json
{
  "date": "2026-10-13",
  "seconds": { "Workdeck": 9000, "docs-site": 1800 },
  "agents": {
    "claudeCode": { "projects": { "Workdeck": { "seconds": 9000, "sessionIDs": ["…"], "files": ["…"], "added": 120, "removed": 30, "commands": 40, "agents": 2 } },
                    "longest": { "project": "Workdeck", "seconds": 5400 },
                    "accounts": { "main": { "hitWindows": [], "weeklyPeak": 61 } } },
    "codex": { "projects": { "docs-site": { "seconds": 1800, … } }, "longest": …, "accounts": { "codex": { "weeklyPeak": 41 } } }
  }
}
```

- `seconds`: each project's total time (§2). It is the only total that cannot be derived from the agents' days.
- `agents`: each agent's own day in today's shape (projects with their counts, longest stretch, account limits). Accounts live under their agent, so a Claude Code instance named `codex` does not meet Codex's account.
- **Old files:** a day without `agents` reads as Claude Code's: its `projects`, `longest` and `accounts` become `agents.claudeCode`, and its project times become `seconds`. The file is written in the new shape at the next save; there is no separate migration.
- A file that cannot be read is set aside as `recap.corrupt-<time>.json` and counting starts over, as today.
- Kept data stays counts and names only: project and file names, session IDs, account labels; never paths, prompts or contents.

## 5. Architecture

| Unit | Where | Change |
|---|---|---|
| Recap files | `Features/ClaudeCode/Recap/` → `Features/Recap/` | Moved with `git mv`: model, recorder, store, texts, palette, colors, card view, `StatisticsController`, `StatisticsWindow`. |
| `RecapDay`, `RecapAgentDay` | `RecapModel.swift` | The day gains `seconds` and `agents`; `RecapAgentDay` holds today's projects, longest and accounts; decoding maps old days (§4). |
| `RecapRecorder` | `Features/Recap/` | `record(samples: [AgentRecapSample], now:)`: sessions and account samples per agent; total and per-agent time (§2); stretches and baselines carry the agent. |
| `WeeklyRecap` | `RecapModel.swift` | `summary(days:weekStart:agent:)` and `pace(days:weekStart:now:calendar:agent:)`: `agent == nil` is all agents. The summary gains `agentSeconds: [AgentKind: Double]` and the longest stretch's agent; accounts carry their agent. |
| `RecapController` (new, `@Observable`) | `Features/Recap/` | Owns the recorder, `RecapStore`, the pending card and `StatisticsController`. Records on every composer refresh, saves at most once a minute and on quit, checks the card on the first unlock of a week and asks the composer to show it, handles Got it and Details. A `DemoParticipant` with its own pure demo script. |
| `AgentSource` | `Features/Notch/` | Gains `recapSample: AgentRecapSample` (agent, sessions while hooks are connected, account samples); loses `dismissRecap` and `openRecapDetails`. |
| `NotchComposer` | `Features/Notch/` | Calls the recap controller's `record()` on each refresh; routes the card's Got it and Details to it. |
| `ClaudeCodeController` | existing | Loses the recorder, recap card, Statistics and demo recap code; provides its `recapSample`. |
| `CodexController` | existing | Provides its `recapSample`. |
| `StatisticsWindow` | `Features/Recap/` | Title, agent control, filtered texts (§3.2). |
| `PopoverView` | `App/` | `chart.bar` button in the header; `ClaudeCodeRow` loses "Statistics…". |
| `AppDelegate` | `App/` | Builds `RecapController` with the composer, registers it with `DemoMode`. |

## 6. Edge Cases

- Both agents in one project at once: the project's total gets the real time; each agent's entry gets its own time.
- A week with only Codex: no split line, no marks; Statistics shows no agent control unless Claude Code has data in another kept week.
- Codex's account without figures that day (API key sign-in): no Codex limits row, as Claude Code accounts without figures today.
- Session IDs of both agents are UUIDs and do not collide; baselines are kept per session ID.
- The demo starting or stopping while the card is up: as today, now in `RecapController`.

## 7. Testing

- `RecapModel` decoding: an old day becomes Claude Code's with the same totals; a new day round-trips.
- `RecapRecorder`: one Claude and one Codex session busy for 60 s give the project total 60 s and each agent 60 s; two Claude sessions in different projects give each project 30 s; counts and the longest stretch land under the right agent.
- `WeeklyRecap.summary`: all agents (unions, sums, longest across agents, accounts ordered Claude main, others, then codex), one agent, and `agentSeconds`.
- `WeeklyRecap.pace` per agent.
- `RecapController`: records every registered source, shows the card once per week, Got it and Details, saves at most once a minute.
- `StatisticsController`: the agent filter, its visibility, and clearing the project filter on agent change.
- Demo script: Codex appears in the demo recap.
- Existing recap and Statistics tests keep passing after the move, adjusted only for the new signatures.

## 8. Documentation

`docs/claude-code.md` (its Weekly Recap and Statistics section describes both agents, the split line and the agent filter), `docs/codex.md` (a short note that Codex counts in the recap, linking that section), README (feature list), `CLAUDE.md` (`Features/Recap/`, `RecapController`), `docs/testing.md` rows, `TODO.md` (Codex support done), and the Codex support spec's status ("stages 1–3 implemented" once done).
