# Workdeck — Clearer Agent Marks Design

**Date:** 2026-10-16
**Status:** Draft

## 1. Overview

While Claude Code and Codex are both on, every limits block, session row, alert and recap line starts with the agent's mark: the text glyphs `✳` (Claude Code, orange) and `◎` (Codex, mint). At the notch's font size they are small and alike, and in session rows they take the status color, so the agent is hard to tell at a glance. The compact notch also spends its width on a percent that the ring already shows.

This change draws the marks as two bold vector icons in the agents' colors, keeps the status in the session row's motion and text, and makes the compact notch shorter until a limit nears its first threshold. The choices were made on mockups in the visual companion (2026-10-16).

### Goals

- Tell Claude Code from Codex at a glance, by shape and by color, everywhere a mark shows.
- Keep each session's status readable once its mark no longer takes the status color.
- A compact notch that shows a percent only when it matters, and a clearer account label.

### Non-Goals

- The agents' own logos (trademarks): the icons only hint at them.
- Marks when only one agent is on (unchanged: none).
- Changes to the expanded notch's layout, the menu bar text, the limit level colors, or the popover.
- A setting to always show the percent in the compact notch.

## 2. The Icons

- **Claude Code:** eight even, bold rays (a heavier `✳`) in terracotta `#D97757`. Terracotta becomes Claude Code's agent color everywhere it is used (it was `.orange`), so the mark no longer matches the orange of the first threshold.
- **Codex:** a filled circle with a `>_` prompt cut out of it, in `.mint` (unchanged).
- Both are SwiftUI shapes sized to the text they sit in (about the cap height plus a little; 13 pt next to the 14 pt ring in the compact notch, 14 pt in a 13 pt session row). Where a mark sits inside a line of text it is an image inside the `Text`, so it wraps and truncates with it.
- The text glyphs `✳` and `◎` go everywhere.

## 3. Where Marks Show

Only while more than one agent is on, as today:

- The compact notch (§4).
- Limits blocks: block headers and the quiet one-line accounts.
- Session rows (§3.1).
- Alerts: a single alert's headline and each line of an alert batch.
- The recap card: the split line (`✳ Claude 10h 05m · ◎ Codex 4h 10m` becomes the icons with the same text), the longest stretch, and the Codex limits row.
- The Statistics window: Longest, the limits rows, and the segments of the agent filter (`All · [Claude icon] Claude Code · [Codex icon] Codex`).

### 3.1 Session Rows

- The leading mark is the agent's icon in the agent's color, never in the status color.
- The status shows as the dot did: a working session's icon pulses as the dot pulsed, a session that waits for you shows it at full strength, an idle one dimmed to about 40 %. Alert flashes glow around the icon as around the dot (green finished, orange needs you).
- The status text on the right keeps its colors.
- With one agent on, the row keeps its status dot `●`/`○` as today.

## 4. The Compact Notch

Left of the camera, in order:

1. The agent's icon, only while more than one agent is on.
2. The ring of the most pressing limit (unchanged).
3. For an extra Claude Code account (an instance), its first letter upper case in a small purple badge (`P`), the purple of the account tag in session rows. Nothing for the main account or Codex (unchanged).
4. The text:
   - below the first threshold (80 % by default), nothing for the 5-hour window, and only the window's short label for another window (`7d`), no percent;
   - from the first threshold on, the percent as today (`84%`, `7d 96%`), in the level's color (orange, then red);
   - `—` while nothing has been recorded (unchanged).

Right of the camera, the sessions and agents counters are unchanged. The expanded notch and the menu bar text always show the percent, as today.

## 5. Architecture

| Unit | Where | Change |
|---|---|---|
| `AgentIcon` (new) | `Features/Notch/AgentIcon.swift` | Two `Shape`s (`ClaudeMarkShape`, `CodexMarkShape`); a view `AgentIcon(agent:size:)` drawing one in the agent's color; and `AgentIcon.text(_:size:) -> Text`, the same shape rendered once per size into a template `NSImage` and returned as `Text(Image(nsImage:))` in the agent's color, for marks inside a line of text. |
| `AgentKind` | `Features/Notch/AgentSource.swift` | `mark` (the glyph) goes; `color` for Claude Code becomes terracotta `#D97757`. |
| `LimitsPresentation` | `Features/Notch/` | `displayName(_:showsMark:)` returns the name only; callers draw the icon. `compactNotchText(pressing:hasData:thresholds:)` hides the percent below the first threshold (§4). |
| `LimitsViewState` | same | `compactLabel` is the account letter only; a new `compactAgent: AgentKind?` carries the icon to draw, set only while marks show. |
| `NotchComposer` | same | Fills `compactAgent` instead of prefixing the glyph to the label. |
| `LimitsCompactLeading` | `LimitsNotchViews.swift` | Icon, ring, badge, text (§4). |
| Limits and alert views | `LimitsNotchViews.swift` | Icon instead of the glyph in headers, quiet lines and alerts. |
| `SessionsNotchViews` | same folder | The row's leading icon (§3.1). |
| `LimitsText.alertHeadline` | `Features/ClaudeCode/Limits/` | No glyph; the view adds the icon. |
| `RecapView`, `StatisticsWindow` | `Features/Recap/` | Icons instead of glyphs (§3). |

## 6. Testing

- `LimitsPresentation.compactNotchText`: 5-hour below the first threshold → empty; weekly below → `7d`; at and above the first threshold → the percent with its window label as today; no data → `—`; a custom first threshold (e.g. 60 %) moves the switch.
- `NotchComposer`: `compactAgent` set only while more than one agent is on; `compactLabel` holds only the account letter.
- `LimitsPresentation.displayName` and `LimitsText.alertHeadline` without glyphs.
- `AgentKind.color` for Claude Code is the terracotta.
- Rendering checks with `ImageRenderer` (as the earlier render tests in the scratchpad): the compact notch in its states, a limits header, a session row of each agent and status, an alert, the recap split line — compared by eye, not committed.
- `docs/testing.md`: a manual row for the compact notch below and above the threshold and the marks with both agents on.

## 7. Documentation

Every place that names the glyphs `✳` or `◎` describes the icons instead: `README.md` (the Codex feature line), `docs/claude-code.md` (the recap split line; the compact notch text), `docs/codex.md` (blocks, sessions, alerts, the recap), `docs/testing.md` (rows R11, X1, X3, X6 and others that expect a glyph, plus the new manual row), and `TODO.md` item 9.
