# Workdeck — Activity Grid in Statistics Design

**Date:** 2026-11-04
**Status:** Draft

## 1. Overview

The Statistics window (`specs/2026-10-13-statistics-window-design.md`) shows one week at a time, reached with `‹` and `›`. This spec adds a GitHub-style grid of days at the top of the window: half a year of coding time at a glance, a current streak and a count of active days, and a quick way to open any kept week by clicking its column.

This is the first half of item 10 of TODO's Planned list. The second half, a 24-hour strip per day, needs coding time per hour, which `recap.json` does not keep; it stays in TODO.

The grid reads the days the recorder already keeps. Nothing new is recorded; the store only keeps days longer (§5).

Chosen in the browser (`.superpowers/brainstorm/`, screens `placement`, `placement-a-v2`, `color`):

- **Placement A:** the grid on top of the window, above the week, as a week picker (not a separate Activity page, not a section at the bottom).
- **Hover A1:** a tooltip next to the square (not the line under the grid changing).
- **Green** squares (not the Mac's accent color, not shades of the text color).
- **Fixed thresholds** in hours (not relative to the busiest day).

Prior art: [limitter](https://github.com/admnov38/limitter) (21-week grid, streaks), [Poirot](https://github.com/a7t-ai/poirot) `ContributionHeatmap.swift` (MIT; Monday-first grid with hover).

### Goals

- See at a glance how regularly and how much you have worked over the last half year.
- Open any kept week in one click instead of many `‹` clicks.
- Know your current streak of working days.

### Non-Goals

- The 24-hour strip, or recording coding time per hour.
- Backfilling days from before Workdeck recorded (Claude Code transcripts, `~/.claude/stats-cache.json`): days before the first recorded day are empty squares.
- A longest-streak figure, a busiest-weekday figure, a total for the grid's range.
- The grid in the notch, on the recap card or in the popover.
- A full year of columns, a horizontally scrolling grid.

### Anti-Goals

- The grid must not look like a fourth project next to the week chart's indigo, cyan and yellow.
- One shade must always mean the same amount of time: no scale that shifts with the agent filter or with one long day.

## 2. The Window

```
┌ Claude Code Statistics ───────────── ‹  This week  › ┐
│        [ All | Claude Code | Codex ]                  │
│     May    Jun     Jul    Aug     Sep    Oct    Nov   │
│ Mon ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪┃▪┃                     │
│     ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪┃▪┃                     │
│ Wed ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪┃▪┃                     │
│     ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪┃▪┃ ← outlined: the week │
│ Fri ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪┃▪┃   shown below        │
│     ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪┃▪┃                     │
│ Sun ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪┃▪┃                     │
│ 9 day streak · 67 active days      Less ▫▪▪▪■ More   │
│ ───────────────────────────────────────────────────── │
│ Coding time · so far                                  │
│ 6h 25m                                                │
│ … the week, unchanged (statistics spec §3.2–§3.5) …   │
└───────────────────────────────────────────────────────┘
```

### 2.1 Place

- The grid goes under the agent filter (when the filter shows) and above the week's header, followed by a divider; everything below it is unchanged.
- It shows also when the shown week, or the whole store, has no coding time (§6).

### 2.2 Grid

- **Columns** are weeks, Monday to Sunday top to bottom, following `RecapCalendar.weekStart` (the same weeks as the window's week view). The last column is the current week; there are `RecapStore.keptWeeks + 1` columns, i.e. the current week and the 26 full weeks before it (§5): the grid shows exactly what the store keeps.
- **Rows** are labeled `Mon`, `Wed`, `Fri`, `Sun` on the left in caption2 secondary text, using the calendar's short weekday symbols.
- **Month labels** above the grid in caption2 secondary text: a month's short name above the first column whose Monday falls in that month (the grid's first column always counts as its month's first). Labels need at least 3 columns between them; only the label on the first column can be closer to the next one, and then the first column's label is left out (as GitHub does), so every whole month keeps its name.
- **Squares** are square with rounded corners (about 2 pt) and a fixed gap of 3 pt. Their size follows the available width so that every column fits without horizontal scrolling at the window's minimum width (400 pt) and the grid uses the width at larger sizes; it does not grow past about 14 pt.
- **Days after today** in the current week are drawn as faint empty squares (as the week chart's future days are); they have no tooltip and no level.
- **The shown week's column** is outlined (primary color, about 1.5 pt), so the grid and the week below always agree. It follows `‹`, `›`, "This week", "Details…" from the recap card and clicks on the grid.

### 2.3 Shades

Five levels by the day's coding time for the selected agent filter (`All` uses the day's merged time, the same as the week view's total for that day; one agent uses that agent's own time):

| Level | Coding time | Fill |
|---|---|---|
| 0 | none | a neutral empty square (about `Color.secondary` at low opacity, visible in light and dark mode) |
| 1 | more than 0, under 1 h | green, light |
| 2 | 1 h to under 3 h | green, medium |
| 3 | 3 h to under 6 h | green, strong |
| 4 | 6 h or more | green, full |

- The green is the system green (`Color.green`), in four opacities or tints chosen by the builder so the steps are distinct in both appearances.
- The thresholds are the same for every agent filter: a day of Codex alone is usually paler, and that is intended.

### 2.4 Hover

- Hovering a past or today's square shows a tooltip next to it, in the style of the week chart's tooltip (`.regularMaterial`, rounded, caption text), kept inside the window:
  - first line: the day (`Thu, Oct 30`, as `RecapText` writes days) and its coding time (`RecapText.duration`);
  - then up to three projects of that day, most time first, each with its time, as the week chart's tooltip lists them (a color dot is not needed: the palette is per week);
  - a day without coding time: the day and `No coding`.
- The hovered square gets a light highlight so it is clear which one the tooltip belongs to.
- Hovering the legend shows its thresholds as a help tag: `Under 1h · 1–3h · 3–6h · 6h or more`.

### 2.5 Click

- Clicking any square, past or future, shows its week in the view below, as `show(week:)` does for "Details…": clicking a square of the current week returns to "This week" and follows it.
- The pointer is the link pointer over squares.

### 2.6 Line Under the Grid

- **Left**, in subheadline secondary text with the numbers in primary: `9 day streak · 67 active days`.
  - **Active day:** a day with coding time above zero for the selected filter.
  - **Active days:** the active days in the grid's range.
  - **Streak:** the number of consecutive active days ending today, or ending yesterday when today has no coding time yet (an empty today does not break the streak before midnight). `0 day streak` when yesterday and today are both empty. `1 day streak` in the singular.
  - Both follow the agent filter.
- **Right:** the legend, `Less`, the five fills, `More`, in caption2 secondary text.

### 2.7 Accessibility

- Each square is one accessibility element labeled with its day and coding time (`Thursday, October 30, 3 hours 12 minutes` or `no coding`), with the button trait; activating it does what a click does.
- The grid as a whole reads as a group named `Activity`.

## 3. Agent Filter

The existing `All · Claude Code · Codex` filter (Codex recap spec §3.2) applies to the grid, the streak and the active days, and the tooltip's projects (an agent shows its own projects). The grid itself does not add a filter.

## 4. Demo

`RecapDemoScript.days` loops over `0..<RecapStore.keptWeeks`, one week short of what the store keeps and the grid shows (`keptWeeks + 1` columns); it changes to `0...keptWeeks` so the demo's grid fills all 27 columns, and `RecapDemoScriptTests`' week count follows. The demo days must also reach every level in §2.3 (today they top out near 3.5 hours, so level 4 never shows) and have a few empty weekdays, so the demo shows the full legend and a believable pattern. The exact minutes are left to the builder; the script stays deterministic, and last week must still be worth a recap.

## 5. Keeping Days Longer

- `RecapStore.keptWeeks` goes from 12 to 26: the store keeps the current week and the 26 full weeks before it. Existing files need no migration; days simply stop being pruned at twelve weeks.
- The Statistics window's `‹` goes back as far as the store keeps (statistics spec §3.1 amended: 26 weeks instead of 12), still not past the oldest week with a day.
- File size stays small (a day is well under a kilobyte; half a year is tens of kilobytes).

## 6. Edge Cases

| Condition | Behavior |
|---|---|
| Fresh install, no days | The grid shows, every square empty; `0 day streak · 0 active days`. |
| Days before the first recorded day | Empty squares, no marking. |
| A week with no coding time is clicked | The week view shows its existing empty state (statistics spec §3.5). |
| The agent filter is hidden (only one agent ever worked) | The grid shows all agents' time, as the window does. |
| Today passes midnight while the window is open | The grid moves with the controller's `today` (it already republishes once a day): the new day appears, a new column starts on Monday, and the oldest column drops when it leaves the kept range. |
| Time zone or daylight saving change | Days follow the Mac's calendar at the moment of display, as the recorder and the week view do. |
| The window is resized | Squares resize to fit (§2.2); the line under the grid stays on one line at the minimum width, wrapping the legend under it if it must. |

## 7. Architecture

| Component | Responsibility |
|---|---|
| `ActivityGrid` (new, pure, `nonisolated`) | From the kept days, the agent filter, today and the calendar: the columns (week start, seven days each with date, seconds, level, future flag), the month labels with their column index, the streak, the active days. The level function with the thresholds of §2.3. The day's top three projects for the tooltip, from the same per-day project split the week chart uses for that filter. |
| `StatisticsController` | Builds the grid in `rebuild()` alongside the summary and publishes it only when it changes (as everything else there); clicking a column calls the existing `show(week:)`. |
| `ActivityGridView` (new view) | §2, drawn with plain SwiftUI shapes or Swift Charts as the builder prefers; the tooltip and the hover state are view state. |
| `StatisticsContent` | Places the grid and the divider above the header. |
| `RecapStore` | `keptWeeks = 26`. |
| `RecapDemoScript` | §4. |

`StatisticsController` currently rebuilds only while the window is visible; the grid follows the same rule.

## 8. Testing

- `ActivityGrid`: column count and order, Monday-first rows, today's column with future days; the levels at each threshold edge (0, 1 s, just under and at 1 h, 3 h, 6 h); the agent filter (All uses merged time, one agent its own); month labels and the overlap rule; the streak with today active, today empty and yesterday active, both empty, a gap; active days; the top three projects of a day.
- `StatisticsController`: the grid is rebuilt on an update and on a filter change and not republished when nothing changed; `‹` reaches 26 weeks; a click on a column shows that week, on the current week follows it.
- `RecapStore`: days older than 26 weeks are dropped, days between 12 and 26 weeks are kept.
- `RecapDemoScript`: the days cover the kept weeks, reach every level, and last week is still worth a recap.
- Manual rows in `docs/testing.md`: hover tooltip and legend help, click on a column, the outline following the arrows, the filter, the window at its minimum width, the demo's grid.

## 9. Documentation

- `docs/claude-code.md` § Weekly Recap and Statistics: the grid, streak and active days; "twelve weeks" becomes 26 (also for the demo's made-up weeks).
- `README.md`: the Weekly recap and Statistics bullet and the demo paragraph ("twelve" → 26 weeks, mention the activity grid).
- `CLAUDE.md`: the Recap bullet ("for twelve weeks" → 26, the grid in the Statistics window).
- `TODO.md` item 10: the grid done with this spec; the 24-hour strip stays, and the item's note about twelve weeks is updated.
- The statistics spec §3.1: points to §5 here for the 26-week limit.
