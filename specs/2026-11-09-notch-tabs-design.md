# Workdeck — Notch Tabs Design

**Date:** 2026-11-09
**Status:** Draft

## 1. Overview

The expanded notch shows one thing today: limits and sessions. Quick notes live in a separate panel that grows out of the notch on a tap of the right Option, and the week's numbers are only in the Monday recap card and the Statistics window. This spec puts all three in the expanded notch as tabs, the way [Lumio](https://lumiomac.com/) does: **Sessions**, **Notes**, **Stats**.

Decided with the user (2026-11-09):

- **Three tabs** at the top of the expanded notch: Sessions (what the notch shows today), Notes (the quick notes panel's content), Stats (a card like the weekly recap, for the current week).
- **Tab bar look (mockup B):** three icons on the left, the selected one on a rounded gray background; the selected tab's name on the right, dim.
- **Hover always opens on Sessions.** The last tab is not remembered ("we'll see later how convenient it is"). *Superseded on 2026-11-11 (polish batch spec §4.1): hover opens on the tab last clicked.*
- **Notes is the same thing as the panel:** the line to type in, the open notes, Done, the `#` list, the agent picker, the folder prompt and the confirmation, with every key working as it does now.
- **The right Option opens the notch straight on Notes**, the cursor in the line. There is no separate-looking panel any more: from the outside it is one notch.
- **Played back, no objection:**
  - Clicking the Notes icon switches the tab and puts the cursor in the line at once. The notch takes the keyboard; the app the user was in stays active (as the notes panel does now).
  - While the user only looks (Sessions, Stats, or Notes before the keyboard is taken), the notch closes when the pointer leaves, as today. Once Notes has the keyboard, it behaves like the notes panel: it stays open when the pointer leaves and closes on Esc, a click outside, or after a save (as the panel closes after its confirmation).
  - Alerts (limits, needs-you, finished, updates) open the notch on Sessions. While Notes has the keyboard an alert does not interrupt: it waits until the notes close, then shows.
  - The Monday recap card stays as it is (its own view with Got it and Details…, not a tab).
  - Stats shows the **current** week so far, not last week.
- **After the builder check (the user, 2026-11-09):**
  - **The shortcut opens the tabbed notch on the screen with the pointer**, on any display, as the notes panel does today, and also when no notch is showing (Limits display "When active" with nothing going on, every agent tool off, a full-screen app on the virtual notch's display). There the notch is drawn as the virtual notch is (DynamicNotchKit's `.notch` look on a plain screen), with all three tabs. Hover still opens the notch only where it lives today (§6).
  - **Each tab keeps its own width:** Sessions and Stats as wide as the expanded notch is now (about 300 pt), Notes as wide as the panel (about 580 pt; its confirmation as now). Switching tabs grows or shrinks the notch evenly from its centre, animated as the notch already animates a change of content.

### Goals

- One place: hovering the notch reaches sessions, notes and the week without the popover.
- Notes typed from the notch are never lost to a pointer movement.
- Nothing about Sessions changes except the tab bar above it.

### Non-goals

- Remembering the last tab, a setting for the default tab, or reordering tabs.
- More tabs (music, terminal, and so on as in Lumio).
- Changing what the Monday card, the Statistics window or the notes panel's rows show.
- Tabs in the menu bar text mode ("Without a notch" → menu bar text): it has no expanded notch; the right Option keeps opening notes there as it does now.

### Anti-goals

- The notch taking the keyboard on hover alone: the user's typing in another app must never go into the notch because the pointer passed over it.
- A visible jump between "the notch" and "the notes panel": a window swap, if the builder uses one, must not show (no flicker, no change of width or corners mid-animation that reads as a second window).
- An alert eating a half-typed note.

## 2. The tab bar

```
┌──────────────────────────────────────────────┐
│ [◉] ✎  ▥                           Sessions  │
│ — ✳ main ─────────────────────── Max 5x ▾ —  │
│ 5h [██████░░░░░░]  55%           ↺ 3h 10m    │
│ …                                            │
└──────────────────────────────────────────────┘
```

- Three SF Symbols in a row on the left; the selected one on a small rounded `secondary`-gray background, the others dim. Builder's choice of symbols; my call as a starting point: `rectangle.stack` (Sessions), `square.and.pencil` (Notes), `chart.bar` (Stats).
- On the right, the selected tab's name, dim: "Sessions", "Notes", "Stats". My call: no counts in the bar (the Notes tab already shows "Open · 4").
- A click on an icon switches the tab. The bar stays at the top of every tab, also while Notes shows its picker, folder prompt or confirmation.
- Keyboard: my call — while Notes has the keyboard, no shortcut switches tabs (Tab and the arrows already mean something there). Clicks only.
- Switching tabs animates the content's height and width (§1: each tab keeps its width); the notch stays centred under the camera, so it never moves sideways.

## 3. Sessions

Exactly what the expanded notch shows today (limits per account, sessions, steps, refresh button), under the tab bar. Flashes, peeks, countdowns and the compact notch are unchanged.

When the notch was opened by the shortcut where nothing would show (every agent tool off, or no data yet), Sessions shows one dim line, "No sessions" (my call).

## 4. Notes

- The content and behavior of the quick notes panel (quick notes spec §3, and the Return changes of 2026-11-09: Return in an open `#` list picks the row and does not save).
- **Opened by hover, then a click on the Notes icon:** the tab shows and the line has the cursor at once; the notch takes the keyboard without activating Workdeck.
- **Opened by the right Option** (or the user's recorded shortcut, or the popover's Notes row): the notch opens straight on Notes with the cursor in the line, as the panel opens today, on the screen with the pointer.
- **Closing:** Esc, a click outside, the shortcut again, or the end of the confirmation after a save. Focus returns to the app that had it, as now. The next hover opens on Sessions (since polish batch spec §4: on the tab last clicked; a save from a panel not opened by the shortcut comes back to the line).
- **The draft:** as the panel does today, closing without saving keeps the typed text in memory (`NotesPanelModel.closed()`), and the next opening of Notes, by click or by shortcut, shows it again. Nothing new is persisted: a note's text never goes to `UserDefaults` or disk (quick notes spec §8).
- The notes panel's demo (`NotesDemo`) plays in the Notes tab.
- **Demo mode** (my call): Stats shows `RecapDemoScript`'s made-up days while the demo runs, as `RecapController` already swaps them in; the demo does not switch tabs by itself except where `NotesDemo` opens Notes, as it opens the panel today.

## 5. Stats

A card in the style of the Monday recap (`RecapView`), for the current week, Monday to today:

- Header "— this week · Nov 9–15".
- Coding time, sessions, the Monday–Sunday chart by project (days after today empty), time per agent, files and lines, commands and agents, longest work, top projects, limits (5-hour hits, 7-day peak per account) — the same rows as the recap card, from the same `RecapStore` data, today included as recorded so far.
- One button, **Details…**, which opens the Statistics window on the current week. No Got it.
- A week with nothing recorded yet shows the header and a dim "Nothing recorded this week yet" (my call).
- It follows the pointer like Sessions: it closes when the pointer leaves.

## 6. Alerts and the notch's states

- An alert opens the notch on Sessions, whatever tab was showing, unless Notes has the keyboard; then the alert waits and shows when the notes close (my call: in the order alerts already queue; nothing is dropped). Notes opened by hover hold no keyboard until clicked, so an alert closes them (polish batch spec §4.2).
- **Alerts and the Monday recap card show without the tab bar** (my call): they are messages, not tabs, and look exactly as now. When an alert ends while the pointer is still on the notch, the notch shows Sessions with the tab bar.
- **While last week's card waits for Got it**, a hover shows the card as now, without tabs (my call: the card is one click away from gone, and the recap spec's rule that it stays until Got it holds). After Got it, hovers show the tabs. The shortcut opens Notes even while the card waits; the card shows again on the next hover.
- The Monday recap card is not shown while Notes has the keyboard; it waits.
- Haptics: the hover tap stays on hover; switching tabs taps nothing (my call).
- The virtual notch on displays without a camera housing gets the same tabs.

## 7. What is left to the builder

- How it is built: tabs inside the DynamicNotchKit notch with the Notes tab handing over to the existing `NotesPanel` window (drawn to match, so the hand-over does not show), or one Workdeck window for the expanded notch, or another way — as long as §1's anti-goals hold. `NotesPanelModel`, `NotesController` and the panel's views are reused, not rewritten.
- Exact symbols, sizes, spacing and the tab-switch animation, following the notch's existing look (`TerminalStyle` for Sessions and Stats, the system font for Notes as now).
- How `NotchComposer` learns which tab is showing and whether Notes has the keyboard.

## 8. Testing, screenshots, docs

- **Tests:** the tab state (hover opens on Sessions; the shortcut opens on Notes; an alert switches to Sessions unless Notes has the keyboard, then waits), the Stats card's data for a partial week (fake `RecapStore` days, a week with nothing recorded), and the existing notes panel tests still passing against the tab.
- **Screenshots:** `notch-expanded.png` gets the tab bar; `notes-capture.png` and `notes-capture-animated.png` show Notes as a tab; a new still `notch-stats.png` shows the Stats tab from `RecapDemoScript`'s made-up days. `make screenshots` and the images in the same commit.
- **Docs:** `CHANGELOG.md` under Unreleased → New ("The expanded notch has tabs: Sessions, Notes and this week's Stats."); `docs/claude-code.md` (the notch section) and `docs/quick-notes.md` (opening from the notch); the README tour and `site/index.html` if their notch text changes; `CLAUDE.md`'s Notch and Notes entries.
