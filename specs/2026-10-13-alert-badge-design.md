# Workdeck — Glowing Alert Badge Design

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

Every alert again expands the notch with its text for about 6 seconds and then flashes the compact notch's ring or session dot (`specs/2026-10-13-notch-flash-design.md` §2.1, amended 2026-10-13). The expanded alert itself is plain: a black panel with a colored `!` or `✓`. This spec gives that mark the same language as the flashes: it becomes a glowing badge in the alert's color that pulses a few times.

Chosen in the browser among a top glow on the panel, a glowing mark, both, and today's look: the glowing mark looks the same on a MacBook, where the camera cutout would hide the center of a top glow, and on a monitor; the panel stays black, so dim text keeps its contrast.

### Non-Goals

- Changing the alert texts, the batch layout, clicks, the 6-second duration or the flashes after it.
- Coloring the panel's background.

## 2. Look

```
 ╭──╮
 │! │ vitastir needs you          ← badge: orange fill at low opacity, orange mark, glow pulsing 3 times
 ╰──╯   permission prompt
```

- **Badge:** an 18 pt circle filled with the alert's color at about 18 % opacity, the mark (`!` or `✓`) in the color, bold, and a soft glow around the circle in the color. The expanded alert also gets a wash from below and a countdown bar (`specs/2026-10-13-notch-polish-design.md`).
- **Pulse:** the glow swells and settles three times over about 4.8 s (1.6 s each), then stays at its resting strength while the alert is shown. It starts when the alert appears. A single alert that another joins becomes a batch and its badge pulses anew (the new alert also keeps the notch up longer); a batch that grows further does not restart it. With Reduce Motion on, the badge rests at its glow without pulsing.
- **Colors** are the flash colors (`NotchFlash.color(of:thresholds:)`): orange for "needs you" and the first threshold, red for the second (highest) threshold, green for "finished" and a reset.
- **Single alert:** its mark is the badge.
- **Batch:** the header's mark is the badge, in the most urgent color of the batch (red > orange > green); its symbol is `!` unless every alert is green (`✓`). The lines keep a plain colored symbol, now in the flash colors too (the second threshold turns red instead of orange).
- Nothing animates outside a shown alert.

## 3. Architecture

| Component | Change |
|---|---|
| `NotchFlash` | `static func color(of alerts: [LimitsAlert], thresholds: [Int]) -> NotchFlashColor?`: the most urgent color of a batch (`nil` for none). |
| `AlertBadge` (new view, `LimitsNotchViews.swift`) | The badge of §2 for a mark and a `NotchFlashColor`. |
| `LimitsExpandedView` | `alertView` and the batch header use `AlertBadge`; `alertColor(_:)` takes the flash color, so lines show red for the second threshold. |

## 4. Testing

- `NotchFlash.color(of:thresholds:)` for batches: the most urgent wins (red over orange over green), the highest threshold is red, a single green alert is green, an empty batch is `nil`.
- The look is checked live: rows L5 (first and second threshold), L9 (reset), S11 (finished), S12 (needs you) in `docs/testing.md` mention the glowing badge.

## 5. Documentation

`docs/testing.md` rows L5, L9, S11, S12; a line in `specs/2026-10-13-notch-flash-design.md` §2.1 pointing here.
