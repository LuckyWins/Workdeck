# Workdeck — Notch Hover and "When Active" Design

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

The Claude Code notch expands the moment the pointer touches it and collapses the moment it leaves. On the virtual notch in the middle of a menu bar (`specs/2026-10-12-virtual-notch-design.md`) the pointer crosses it on the way to menus, so the notch opens by accident, and a pointer resting on its edge makes it flicker.

The display modes are "Always" and "Only near limits". The second already hides the notch while nothing happens, but it hides it the instant the last session goes idle, so a finished session is never seen, and a hidden notch cannot be brought back without opening the popover.

This spec adds hover delays and turns "Only near limits" into **When active**: the notch stays a minute after work ends and can be peeked at by pointing at its place.

Idea source: [Coucou](https://github.com/Louis-CFM/coucou), an MIT-licensed notch companion (a 0.6 s grace before collapsing, a compact island that hides after 60 s without activity and returns on hover or new work).

### Goals

- Passing the pointer over the notch does not expand it; resting at its edge does not make it flicker.
- In "When active", the notch is there while something happens and for a minute after, and comes back on demand by pointing at it.

### Non-Goals

- Changing how alerts look or animate (next spec: state colors and animations).
- Delays or modes for the menu bar text (no notch, "Menu bar text" setting): it keeps today's behavior.
- Keyboard shortcuts for the notch (TODO).

## 2. Modes

- `LimitsDisplayMode` keeps two cases: `always` ("Always") and `whenActive` ("When active"). `whenActive` replaces `nearLimits`; its stored raw value stays `"nearLimits"`, so a saved choice carries over.
- Settings → Claude Code · Limits → **Show:** "Always" / "When active". The menu bar text mode reads `whenActive` as it read `nearLimits`: text only near limits.

## 3. "When Active" Visibility

With a notch (real or virtual), in "When active" the compact notch is visible while any of these holds:

1. A session is active: working, compacting, or waiting for you (`SessionsViewState.activeCount > 0`).
2. An account's limit is at or above the first threshold (level warning or critical).
3. Less than **60 s** have passed since the last moment rule 1 held (the linger). Workdeck launching with no active session starts no linger.
4. The pointer peeks at the notch's place (§5).
5. An alert is showing (as today).

Otherwise the notch is hidden. When it is visible it shows everything the compact notch has — the ring and percent of the compact account and the session counters — instead of hiding the ring at a normal level as "Only near limits" did. "Always" is unchanged: visible whenever there is data or a session.

## 4. Hover Delays

Apply in both modes, to the real and the virtual notch:

- **Enter:** the pointer must stay on the notch **0.25 s** before it expands from compact (or, when peeking, before the hidden notch shows as compact).
- **Exit:** after the pointer leaves, the notch waits **0.5 s** before collapsing (or hiding again after a peek). Coming back within that time cancels the collapse.
- Alerts expand at once, with no delay; an alert ends into the state the hover delays give at that moment.
- The delays live in `NotchPresenter`, between DynamicNotchKit's hover signal and the reconcile loop; a pending change is cancelled when the hover flips back.

## 5. Peeking at a Hidden Notch

- While the notch is hidden by "When active" (not while it is hidden because there is no data, the indicator is off, or there is no display), Workdeck watches the pointer with a global mouse-moved monitor (`NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved)`). It needs no permission, sees no clicks or keys, and does not block clicks the way a transparent window over the menu bar would.
- The peek zone is the notch's place: on a display with a camera housing, the housing (its width from the screen's auxiliary top areas, its height `safeAreaInsets.top`), widened by 60 pt on each side for the compact wings; on the virtual notch, DynamicNotchKit's 300 pt fallback at the top center, as tall as the menu bar, widened the same way.
- Pointer inside the zone for the enter delay → the compact notch shows; staying on it expands it as usual (§4). Pointer out of the zone and off the notch for the exit delay → hidden again.
- The monitor runs only while the notch is hidden in "When active" and is removed otherwise.

## 6. Architecture

| Component | Change |
|---|---|
| `LimitsDisplayMode` | `nearLimits` → `whenActive` (raw value `"nearLimits"`), title "When active". |
| `LimitsPresentation.display` | Takes the time since the last activity (`TimeInterval?`) and whether the pointer peeks; `whenActive` follows §3. `showsLimits` shows the limits part whenever the notch is visible in `whenActive`. |
| `ClaudeCodeController` | Records when sessions were last active, refreshes when the 60 s linger runs out, passes peeking from the presenter. |
| `NotchPresenter` | Hover enter/exit delays (`hoverEnterDelay` 0.25 s, `hoverExitDelay` 0.5 s, injectable for tests); owns the peek monitor while the notch is hidden in `whenActive`. |
| `PointerMonitoring` (new) | Starts and stops a global mouse-moved monitor and reports the pointer location; a fake in tests. |
| `NotchPeekZone` (new, pure) | The peek rectangle for a screen frame and a notch size, and whether a point is inside. |
| Settings view | The "Show" picker lists the two modes. |

## 7. Edge Cases

| Condition | Behavior |
|---|---|
| A session goes idle, another starts within 60 s | Visible throughout; the linger restarts when the last one goes idle. |
| The pointer sits in the peek zone when work ends | Stays visible until the pointer leaves, then hides after the exit delay (or when the linger ends, whichever is later). |
| Mode switched to "Always" while peeking | The monitor stops; the notch is visible. |
| Display changes while peeking | The zone is recomputed from the new target screen on the next mouse move. |
| A full-screen app on the virtual notch's display | Full screen still hides the resting notch (virtual notch spec §3.3); peeking does not show it there. |

## 8. Testing

Unit tests never touch real screens, the window server or global event monitors.

- Visibility: active session; near limit; 59 s and 61 s after the last activity; peeking; nothing (hidden); "Always" unchanged; the ring shown in "When active" at a normal level.
- Mode: a stored `"nearLimits"` reads as `whenActive`; title "When active".
- Hover delays (presenter with short injected delays): a hover shorter than the enter delay does not expand; a leave shorter than the exit delay does not collapse; an alert expands without delay.
- Peek: the monitor runs only while hidden in `whenActive`; a point inside the zone shows the notch, leaving hides it after the exit delay.
- `NotchPeekZone`: housing size from auxiliary areas, virtual fallback, 60 pt wings, points inside and outside.
- Controller: the linger ends with a refresh that hides the notch.

Manual rows in `docs/testing.md`: moving the pointer across the menu bar does not open the notch; resting on its edge does not flicker; a finished session stays visible for a minute; pointing at the hidden notch shows it.

## 9. Documentation

README (Claude Code: display modes, hover, peeking), `docs/testing.md`.
