# Workdeck — Notch Polish Design (Wash, Countdown, Ticker, Settings Tiles)

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

Four small visual changes borrowed from [Coucou](https://github.com/Louis-CFM/coucou) and chosen in the browser against today's look:

1. An expanded alert gets a soft color wash rising from the bottom edge, in its flash color.
2. A thin countdown bar shows how long an expanded alert or recap stays before the notch closes.
3. The focused session's step ticker moves: a finished step rises and gets a `✓`, the new step slides in, the current step shimmers, the edges fade.
4. Each Settings section header gets a colored icon tile, as in System Settings.

A quiet ring that wakes on hover was considered and dropped: the compact notch is there to show limits and sessions at full strength.

### Non-Goals

- Changing alert texts, durations, clicks, flashes, or which alerts expand.
- Changing DynamicNotchKit's open and close animation.
- Sounds, a mascot, colored hover shadows.

## 2. Color Wash

- A radial gradient from below the expanded notch's bottom edge (an ellipse over the panel down to its bottom edge, center at 50 % width and 125 % height, fading out at 75 % of its radius) in the alert's flash color (`NotchFlash.color(of:thresholds:)`): orange for "needs you" and the first threshold, red for the second, green for "finished" and a reset. A batch takes its most urgent color, as the badge does.
- Strength: the color at about 60 % opacity at the center, under the content; dim text keeps its contrast because the wash stays in the lower part.
- The weekly recap card gets the same wash in indigo, so it reads apart from alerts.
- It fades in with the alert (0.3 s) and goes with it. With Reduce Motion it appears without the fade.
- It is drawn as a background of Workdeck's expanded view that extends past DynamicNotchKit's 15 pt content inset; the notch's own mask clips it to the panel. From below, the MacBook camera cutout never hides it (the reason a top glow was dropped in `specs/2026-10-13-alert-badge-design.md`).

## 3. Countdown Bar

- A 2 pt bar, white at 35 %, rounded, centered near the bottom edge of the expanded notch (inside the bottom inset), 160 pt wide at full.
- It appears with an expanded alert or the expanded recap and shrinks linearly to zero at the moment the notch closes them: 6 s for an alert, 60 s for the recap.
- It always tells the real time left:
  - An alert that joins a shown one restarts the alert's time, and the bar starts again from full.
  - While the pointer is on the notch the bar is hidden. The recap stays open while hovered and then waits out another full minute (as today); when the pointer leaves, the bar shows what is left of that minute.
  - An alert's time does not stop on hover (as today); its bar keeps running and shows again when the pointer leaves.
- No bar in the normal expanded view (hover without an alert or recap). With Reduce Motion the bar is not shown.

## 4. Step Ticker

The focused session's three steps (`specs/2026-10-13-edit-counts-and-step-ticker-design.md` §3.2) animate as one list:

- When a new step arrives, the previous current step moves up one line, shrinks to about 92 % and shifts 4 pt left (0.38 s, `timingCurve(0.4, 0, 0.2, 1)`); its `▸` turns into `✓` in `Terminal.faint`. The oldest step fades and rises out of the top. The new step slides in from below and fades in.
- Earlier steps keep `Terminal.faint` text; the current one `Terminal.text`.
- A running agent's current action (its card's second line) shimmers the same way (added 2026-10-14); before its first action, `starting…` stays dim.
- The current step's text shimmers: a light band (`Terminal.text` over `Terminal.dim`) sweeps across it every 2.2 s, only while the notch is expanded and the session works.
- The list fades out at its top (about 16 % of its height) and bottom (about 8 %) with a gradient mask.
- Only the mark and text step back; the counts keep their column, at 40 % opacity on finished steps. Counts (`+N −M`) and the agent launch rule (no current marker while the latest step launched an agent) are unchanged.
- With Reduce Motion: no movement, no shimmer; only `▸` turns into `✓`.

## 5. Settings Tiles

Each Settings section header becomes a label with a 20 × 20 rounded tile (corner radius 5), a white SF Symbol on a system color:

| Section | Symbol | Color |
|---|---|---|
| General | `gearshape.fill` | gray |
| Closed-Lid Mode | `laptopcomputer` | indigo |
| Claude Code · Limits | `gauge.with.dots.needle.50percent` | orange |
| Claude Code · Sessions | `terminal.fill` | green |
| Claude Code · Instances | `person.2.fill` | blue |
| About | `info.circle.fill` | gray |

Section footers and rows are unchanged.

## 6. Architecture

| Component | Change |
|---|---|
| `NotchWash` (new view modifier, `TerminalStyle.swift`) | The radial gradient of §2 for a color, extended past the content inset. |
| `LimitsExpandedView` | Wash for a single alert, a batch and the recap; the countdown bar. |
| `NotchCountdown` (new, pure) | `start` and `end` dates and `fraction(at:)` for the bar. |
| `LimitsNotchModel` | `countdown: NotchCountdown?` and `isHovering`, set by the presenter. |
| `NotchPresenter` | Sets `countdown` when an alert or the recap expands, restarts it when an alert joins or the recap's minute repeats, clears it when they close. |
| `CountdownBar` (new view) | §3; hidden while `isHovering`. |
| `SessionsList` (step rows) | §4. |
| `SettingsTile` (new view) and the Settings sections' headers | §5. |

## 7. Testing

- `NotchCountdown.fraction(at:)`: 1 at start, 0 at and after the end, linear between.
- Presenter: an expanded alert sets a countdown of `alertDuration`; a joining alert restarts it; it is cleared when the alert closes; the recap sets one of `recapDuration` and a repeated minute restarts it.
- Wash color for a batch is the badge's color (`NotchFlash.color(of:thresholds:)`, already tested).
- The look is checked with `ImageRenderer` snapshots during the work and live: rows L5, L9, S11, S12, R1 (wash and bar) and the ticker row in `docs/testing.md`.

## 8. Documentation

`docs/testing.md` rows above; a note in `specs/2026-10-13-alert-badge-design.md` §2 and `specs/2026-10-13-edit-counts-and-step-ticker-design.md` §3.5 pointing here.
