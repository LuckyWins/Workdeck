# Workdeck — Statistics Window Design (Weekly Recap Stage 2)

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

The weekly recap (`specs/2026-10-13-weekly-recap-design.md`) shows last week once, in the notch, on the first unlock of a week. This spec adds a Statistics window that shows any kept week on demand, the current week included, so the numbers can be seen from the first day they are collected. It also gives the notch card a headline and a small chart, so the two read as one feature.

This is stage 2 of item 6 of TODO's Planned list. It reads the days stage 1 already records; nothing new is collected.

Chosen in the browser: a single-column window in the style of Screen Time (one big number, a chart, a "most worked on" list, plain lists after it) and, for the notch card, the terminal card with a headline and a Monday–Sunday chart (variant C).

### Goals

- See this week's work at any time, and earlier weeks back to twelve.
- Know at a glance whether this week is busier than the last.
- One color per project across the notch card and the window.

### Non-Goals

- A trend over several weeks (a chart of weekly totals), a date range picker, a share image.
- Showing the window in the notch or in Settings.
- Recording anything new.

## 2. Opening the Window

| From | Week shown |
|---|---|
| "Statistics…" in the Claude Code row of the popover, next to "Chats…" | The current week |
| "Details…" on the recap card in the notch | The recap's week; the recap is dismissed as with "Got it" |

- One window for the app (a SwiftUI `Window` scene like Chats), titled "Claude Code Statistics", default size about 460 × 680, not restored at launch. Opening it again brings it forward on the requested week.
- Workdeck activates when it opens, as for Chats.

## 3. The Window

```
┌ Claude Code Statistics ───────────── ‹  This week  › ┐
│ Oct 13–19 · so far                                    │
│ 6h 25m                                                │
│ ▲ 18% from the same days last week · 3h 12m a day     │
│  ▇▇                                                   │
│  ▇▇  ▇▇   ┆   ┆   ┆   ┆   ┆      ---- avg            │
│  M   T    W   T   F   S   S                           │
│ Most worked on                                        │
│ Workdeck   ██████████████████████            3h 40m   │
│            4 sessions · 31 files · +1 380 −290        │
│ vitastir   ████████████                      2h 05m   │
│            3 sessions · 14 files · +470 −101          │
│ Work                                                  │
│ Sessions                                          9   │
│ Files                                            48   │
│ Lines                                  +1 912  −406   │
│ Commands · agents                          164 · 12   │
│ Longest                           Workdeck · 1h 48m   │
│ Limits                                                │
│ main                         5h hit 1×   7d peak 83%  │
│ personal                     5h hit 0×   7d peak 22%  │
└───────────────────────────────────────────────────────┘
```

### 3.1 Toolbar

- `‹` shows the week before, down to the oldest week that has a day in the store, and never more than 12 weeks before the current one; it is disabled there.
- `›` shows the week after; it is disabled on the current week.
- "This week" shows the current week; it is disabled there.

### 3.2 Header

- The week range (`Oct 13–19`, `Sep 28–Oct 4`) as the window's subtitle under its title (the toolbar covered it in the content); above the total a small `Coding time`, with `· so far` on the current week.
- **Total:** the week's coding time in large type (`RecapText.duration`).
- **Comparison and average** in secondary text: `▲ 18% from the same days last week · 3h 12m a day`.
  - The comparison sets this week's days so far against the same weekdays of the week before: on a Tuesday, Monday and Tuesday against last Monday and Tuesday; for a past week, the whole week against the whole week before. Days are whole days, so on the current week today's part-day is set against a full day.
  - `▲ N% from the same days last week` when higher, `▼ N% …` when lower, rounded to a whole percent; `about the same as the same days last week` within 1 %. Neutral color: more work is neither good nor bad.
  - No comparison when the earlier days have no coding time (before Workdeck recorded, or a week off).
  - The average is the total over the days elapsed: seven for a past week; for the current week, the days from Monday up to and including today.

### 3.3 Chart

- Swift Charts, one stacked bar per weekday Monday to Sunday, stacked by project.
- Colors by `RecapPalette` (§5): the week's top three projects in indigo, cyan and yellow, every other project gray.
- A green dashed line at the daily average (§3.2), labeled `avg`, as in Screen Time.
- Days after today on the current week are drawn as faint empty columns; today's label is bold.
- Hovering a bar shows that day's total and its projects with their times.

### 3.4 Lists

- **Most worked on:** every project of the week, most time first, one compact row each as in Screen Time: the project name, a bar in its palette color whose length is relative to the first project, the time; hovering a row shows `N sessions · N files · +A −R` (zero parts left out, as the turn line does).
- **Work:** Sessions, Files, Lines (`+A` green, `−R` red), Commands · agents, Longest (`project · duration`, left out when there is none).
- **Filter by project:** a row under the pointer gets a light background; clicking a row in Most worked on highlights it in its color, dims the others, and shows Work for that project only, with a chip (color dot, name, `×`) after the Work title; clicking the row again or `×` shows all projects. Longest is left out while filtered (it is kept one per day, not per project). Changing the week clears the filter. The chart and Limits stay as they are.
- **Limits:** one row per account with data that week (main first, then by name, as on the notch card; a removed instance keeps its place): `5h hit N×` and `7d peak N%` in the limit bars' threshold colors. The section is left out without any account data.
- Numbers use `RecapText.number` (thin space above 999).

### 3.5 Empty and Live

- A week without coding time shows "No Claude Code work this week." in place of the header numbers, an empty chart, and no lists except Limits when it has data.
- When the session hooks are not connected, a secondary line under the header says "Coding time is counted while session hooks are connected." with a link button to Settings.
- The current week updates while the window is open, from the recorder's days in memory, on each sessions or usage update. Past weeks do not change.

## 4. The Notch Card (amends weekly recap spec §3)

```
─ last week · Oct 6–12 ─────────────────
 18h 42m                  ▂ ▅ ▃ █ ▄ ▁
 23 sessions              M T W T F S S
 142 files  +4 820 −1 310
 512 commands · 37 agents
 longest   Workdeck · 2h 14m
─ top projects ─────────────────────────
 ■ Workdeck                       9h 03m
 ■ vitastir                       6h 11m
 ■ pokemon                        2h 40m
─ limits ───────────────────────────────
 main        5h hit 2×    7d peak 81%
 personal    5h hit 0×    7d peak 34%
                     [Details…] [Got it]
```

- The coding time in large type, `N sessions` under it in `Terminal.dim`; files and lines, then commands and agents, each on a line of their own (the card holds about 40 characters per line).
- To its right a small Monday–Sunday chart, stacked by project in the palette colors, weekday initials under it.
- The `busiest` row is removed: the chart shows the busiest day.
- Top projects get a square in their palette color before the name.
- "Details…" opens the window on the recap's week and dismisses the recap; "Got it" is unchanged.
- Everything else of the weekly recap spec (when it shows, how long, alerts) is unchanged.

## 5. Architecture

| Component | Responsibility |
|---|---|
| `WeeklyRecap` (pure, extended) | For a week: per-day seconds split by project; every project with time, sessions, files, lines; the comparison with the same days of the week before; the daily average over the days elapsed. Takes `now` to know the elapsed days. |
| `RecapPalette` (new, pure) | A project's color slot for a week from its rank by time: 0, 1, 2 for the top three, `nil` (gray) for the rest. The views map slots to colors. |
| `StatisticsController` (new, `@Observable`) | The shown week, whether `‹`, `›` and "This week" are enabled, the summary of the shown week rebuilt from the recorder's days on each update; `show(week:)` for the openers. |
| `StatisticsWindow` (new view) | §3, with Swift Charts. |
| `RecapRecorder` | Exposes its days in memory for the controller (it already keeps them). |
| `ClaudeCodeController` | Owns the statistics controller, tells it on each refresh, and wires "Details…": dismiss the recap, show its week, open the window through `WindowOpener`. |
| `RecapView` | §4. |
| `ClaudeCodeRow` | "Statistics…". |
| `WorkdeckApp` | The `Window` scene. |

## 6. Edge Cases

| Condition | Behavior |
|---|---|
| No data at all (fresh install) | The window opens on the current week, empty (§3.5); `‹` is disabled. |
| A week in the middle has no days | It can still be reached with `‹` and shows as empty. |
| The week changes while the window shows "This week" | It moves to the new current week on the next update. A past week stays where it is. |
| Time zone or daylight saving change | Days and weeks follow the Mac's calendar at the moment of display, as the recorder does. |
| More than three projects | The rest are gray in the chart and the card; the window still lists every one. |
| An account removed | Its rows stay in past weeks under its name. |

## 7. Testing

- `WeeklyRecap`: per-day project split; every project with sessions, files and lines; the average over elapsed days for the current week and over seven for a past one; the comparison for the same days, `▲`, `▼`, within 1 %, and none without earlier data.
- `RecapPalette`: ranks by time, ties broken by name, gray after three.
- `StatisticsController`: navigation limits (oldest week with data, 12 weeks, current week), "This week", live rebuild on an update, moving to the new week only while on "This week".
- Controller: "Details…" dismisses the recap and shows its week.
- `RecapText`: the comparison text.
- Manual rows in `docs/testing.md`: the window from the popover and from "Details…", navigation, hover on a bar, the new notch card.

## 8. Documentation

README (the Statistics window), `docs/testing.md`, the weekly recap spec §3 pointing to §4 here, CLAUDE.md's Recap bullet (the window reads the same days), TODO item 6.
