# Workdeck — Quick Notes Long Rows Design

**Date:** 2026-11-09
**Status:** Implemented

## 1. Overview

Two problems with the open notes in the quick notes panel (quick notes spec §3.3):

- **A long note cannot be read.** Each row is one line, 30 pt high; the title shares the 580 pt panel with the list chip and the date, so a long note is cut with "…" and there is no way to see the rest in the panel.
- **The list does not show that it scrolls.** More than eight notes scroll, but the scroll indicator is hidden (`.scrollIndicators(.never)`), so the eight visible rows look like all the notes there are.

This spec changes the row layout and adds a cue for the notes below. Mockups were made in the browser during brainstorming and are not kept in the repository; the ASCII drawings here stand in for them.

Decided with the user (2026-11-09):

- **The title gets its own line, up to two lines**; the list and the date move under it, on a small second line.
- **Hovering or selecting a row shows the whole note.** The user reads notes with the mouse mostly, sometimes with ↑↓, so both must work.
- **Scroll cue: a fade at the edge plus a "N more" count** under the list (mockup option 2 of: fade, fade + count, thin scroll bar, counter in the header).

Played back to the user, no objection:

- Hover expands after a short pause (about 0.4 s), so moving the pointer across the list does not make it jump; selection (↑↓, click) expands at once.
- "Give to agent" on hover moves to the right end of the second line, so it no longer covers the title. "⌘Z Undo" and "Deleted" move there too.
- No system scroll bar.
- The list's height is a limit in points instead of a row count (rows have different heights now): about seven one-line rows in the Open section instead of eight, about four in Done instead of five, so the panel does not grow much taller.

A related fix lands separately, before this one, without a spec of its own: typing a list's name without `#` filters the open notes by list (each typed word matches the note's title or its list's title). It updates quick notes spec §3.3's "Typing filters" line.

### Goals

- Every note in the panel can be read in full without opening Reminders.
- It is obvious at a glance when more notes are below the visible ones, and how many.

### Non-goals

- Reordering notes, grouping them by list, or any other change to what the list contains or its order.
- Showing the reminder's notes field, URL or anything else Reminders stores besides the title.
- A different look for the `#` list rows, the agent picker or the folder prompt.

### Anti-goals

- The list jumping or reflowing while the pointer just passes over it.
- A list so tall that the panel covers much of the screen: one fewer row than today in each section is the accepted price of the second line (§4).
- The expanded row hiding the selection or scrolling out of view while ↑↓ moves through the list.

## 2. The row

```
│ ○ Check the staging migration                                   │
│   ● Workdeck · Tomorrow, 16:00                                  │
│ ○ Ask Sasha about the weekly limits reset and whether the Codex  │
│   numbers match what the usage API returns for the second inst…  │
│   ● Workdeck · → Claude · 11:05                                  │
│ ○ Update screenshots                                             │
│   ● Workdeck-site · 3 d                          [✳ Give to agent] │  ← hovered
```

- **First line:** the circle (done, undo ring; unchanged), then the title in the panel's 15 pt font, taking the whole width of the row. At most **two lines**, cut at the end with "…".
- **Second line**, indented to line up with the title, in 11 pt secondary: the list's color dot and title (`ListChip`), " · ", then the detail the row shows today in its right column: the due date (orange when today or overdue), "→ agent · time", the age, or for a Done item "Done 2 h ago". A row whose list is unknown shows only the detail.
- **Right end of the second line:** what replaces the detail today on hover or while waiting: the "Give to agent" capsule on hover of an open row, "⌘Z Undo" while a tick waits, "Deleted ⌘Z Undo" while a deletion waits. The detail stays on the left meanwhile.
- **Selected row:** the accent background as today, both lines white.
- Row padding grows so that two lines of text breathe (builder's call; the mockup used 6 pt top and bottom, 2 pt between lines).

## 3. Expanding

- **The selected row** (↑↓, click, the row the context menu was opened on) shows its whole title, every line, at once.
- **A hovered row** shows its whole title after the pointer has stayed on it for about **0.4 s**; it goes back to two lines when the pointer leaves, unless it is the selected row.
- Expanding pushes the rows below down inside the list; the list's own height does not change while it is at its limit (§4).
- When ↑↓ selects a row, the list scrolls so that the whole expanded row is visible.
- A title that fits in two lines looks the same expanded or not.
- At most one row is expanded by hover and one by selection, and **the keyboard takes over from the pointer** as in macOS menus: once ↑↓ is pressed, hover stops expanding (and a hover-expanded row collapses) until the pointer really moves again. A row that slides under a resting pointer while the list scrolls is not hovered. So ↑↓ never makes a row below the selection grow and push it away (Claude's call after the builder check, 2026-11-09).
- With Reduce Motion on, rows change height without animation.

## 4. Height and the scroll cue

```
│ ○ Renew passport                                                 │
│   ● Inbox · Fri, 10:00                       (fading into black) │
│                          ⌄ 7 more                                │
│ ↑↓ Select   ⌘↩ Give to agent   ⌘D Done                      esc │
```

- **Open section height:** the rows' natural height up to a limit of about seven one-line rows (builder's call on the exact number of points; the mockup was about 330 pt). Fewer notes than fill the limit: the list is as tall as its rows and does not scroll, as today.
- **Done section height:** likewise, up to about four one-line rows.
- **Fade:** while notes are below the visible part, the bottom of the list fades into the panel's black (about 30 pt); once scrolled down, the top fades too while notes are above. No fade when the list does not scroll.
- **Count:** under a scrolling list, a centered 11 pt secondary line "⌄ N more", N being the rows whose top is below the visible part. At the end of the list the line is gone (its space too, or kept empty: builder's call, whichever does not make the panel jump).
- The count and fades apply to the Done section the same way, with their own N.
- No system scroll bar (`.scrollIndicators(.never)` stays).

## 4a. Built (2026-11-09)

- The second line's list is a plain dot and title in the secondary style (as in the mockup), not the `#` chip's capsule.
- A fade's strength grows with the distance hidden beyond its edge, full at its 30 pt height, so a list scrolled a point or two barely dims its edge row.
- Opening the panel and typing (which filters, edits or restores the rows) count like ↑↓: a row that appears under a resting pointer is not hovered until the pointer moves, and a hovered row hidden by the filter does not come back expanded.
- ↑↓ scrolls to the next row in the direction of the move, so the selected row stays clear of the fade at that edge.
- "N more" also counts a row showing no more than 15 pt above the bottom edge, in the dark half of the fade (§4 said only rows below the visible part).
- Whether the list scrolls follows its content height against the limit, not the last measured height, so a list growing within its limit never shows the count for a moment.
- The hover background and "Give to agent" follow the same rule as expanding: a row that slides under a resting pointer after ↑↓ shows neither.
- The circle and the undo ring share one box on the title's first line, so a tick does not move the title.

## 5. Unchanged

- What the list contains, its order, the filter, ↑↓, ⌘↩, ⌘D, ⌘Z, the context menu (row menu spec) and editing in the line.
- The `#` list, the agent picker, the folder prompt and the confirmation.

## 6. Testing, docs

- **Tests:** the pure parts in the model or a small helper: the "N more" count from row frames and the visible range; the fade flags (more above, more below); the hover delay (expanded only after the delay, not when the pointer left earlier); which row is expanded (selected or hovered). Views themselves are covered by the screenshots.
- **Screenshots** at the end of the feature only (the user's rule): `notes-capture-animated.png` shows the open notes and changes; the fixtures may gain one long note so the image shows two lines.
- **Docs:** quick notes spec §3.3 (row layout, at most two lines, expand on hover or selection, the height limit and "N more" replace "at most eight rows visible"); `docs/quick-notes.md` (Open notes: long notes show in full on hover or selection, the "N more" line); `CHANGELOG.md` → Unreleased → Improved: "Quick notes: long notes show in full when you hover or select them, and the list shows how many more notes are below."
