# Workdeck — Notch Flash Design

**Date:** 2026-10-13
**Status:** Implemented

## 1. Overview

Today an alert — a limit threshold or reset, a session that finished or needs you — expands the notch for about six seconds with a line of text, and several alerts show as a batch. This spec replaces that with a **flash**: the compact notch stays compact and its ring (and, for a session that needs you, the session dot) lights up once in the alert's color. What the alert reports is already visible when you hover the notch: the session's status and the limit's percent and color.

It also makes the list of sessions and agents move smoothly and checks that the ring's fill animation is visible.

This is item 2 of TODO's Planned list ("State colors and a livelier notch"). The background tint discussed first was dropped: on a MacBook the camera housing hides its center, and the flash reads the same on every notch.

### Goals

- See at a glance that something happened, and what kind, without the notch jumping open.
- Keep the notch calm: a flash plays once, and nothing animates at rest.

### Non-Goals

- Showing alert text for anything but "needs you" (no alerts section in the expanded notch).
- Clicking a flash (opening a project or Chats from it); only the "needs you" alert stays clickable. Session rows in the expanded notch still open their project; Chats opens from the popover. The click plumbing (the presenter's project and Chats actions, `ChatsController.focus(onChat:)`, the alert texts) stays in the code for notifications that may come later.
- Sounds, macOS notifications, a mascot.

## 2. Flash

### 2.1 Colors and Targets

The place tells where an alert comes from, the color how urgent it is (changed after the first probe: an orange "needs you" flash on a ring already orange near a limit was hard to see).

| Event (existing alert) | Flashes | Color |
|---|---|---|
| A limit reached the first threshold (`threshold`, first) | ring (left wing) | orange |
| A limit reached the second threshold (`threshold`, the highest) | ring | red |
| A limit reset (`reset`) | ring | green |
| A session needs you (`sessionNeedsYou`) | session dot `●` (right wing), blinking three times | orange |
| A session finished (`sessionFinished`) | session dot | green |

- Several alerts at one check flash both places at once when they come from both: the ring in the most urgent limit color, the dot in the most urgent session color (red > orange > green).
- The dot shows during its flash even when no session is active (it is otherwise drawn only while a session works or waits).
- **"Needs you" also expands the notch** (changed after the second probe): the one alert that waits for your action keeps today's alert — `vitastir needs you`, `permission prompt` for about 6 s, a click opens the project's window, several at once as a batch. Its dot blinks on the compact notch once the alert closes, since the expanded alert has no dot. Every other alert only flashes.
- Without a limits source the ring is not drawn; limit alerts cannot fire then.
- The rules for when an alert fires are unchanged: thresholds, "Notify when a limit resets", "Notify when a session finishes" with its minimum time, "Notify when a session needs you", and skipping session alerts while that session's app is in front. They now decide flashes.

- **Every alert expands again** (amended 2026-10-13, after living with the flashes): each alert expands the notch with its text for about 6 s, as "needs you" does (thresholds and resets open Chats on click, finished opens the project), alerts arriving together form one batch, and the ring or dot flash plays on the compact notch once the alert closes. The rules for when an alert fires are unchanged. The mark of the expanded alert is a glowing badge (specs/2026-10-13-alert-badge-design.md).

### 2.2 Look and Timing

- One pulse of about 1.5 s: the ring's stroke or the dot takes the flash color with a soft glow around it, then returns to its own color. "Needs you" blinks the dot three times within the same time. Plays once; never repeats.
- A flash arriving while another waits or plays merges with it and restarts: each place keeps the more urgent color, and the dot blinks if either did. No alert is lost when a Stop hook and a usage update land together.
- Flashes wait while a "needs you" alert is expanded and play on the compact notch after it.
- No frames run between flashes: the animation is driven by the flash event, not a timer.

### 2.3 Where It Plays

- **Compact notch visible:** on the compact ring (and dot).
- **Notch hidden** ("When active" with nothing going on): the notch shows compact, flashes, and stays for the "When active" linger (60 s), as if work had just ended.
- **Notch expanded** (the pointer is on it): the expanded view has no ring; the matching line's marker flashes instead — the session's status dot for session alerts, the limit block's header for limit alerts.
- **Menu bar text mode:** no flash (as today, alerts are not shown there).
- **Full-screen app on the virtual notch's display:** the resting notch stays hidden; no flash.

## 3. Smooth Lists

- Session rows and agent cards in the expanded notch fade and slide in when they appear and fade out when they leave (`.transition(.opacity.combined(with: .move(edge: .top)))`, keyed by session and agent IDs).
- The ring's fill already animates (`UsageRing`, 0.3 s). The probe (§6) checks it is visible in the running app; if DynamicNotchKit rebuilds the compact view and drops the animation, the fix keeps the ring's view identity stable.

## 4. Architecture

| Component | Change |
|---|---|
| `NotchFlash` (new, pure) | The ring's and the dot's colors for the alerts of one moment (`green`, `orange`, `red`, or none), and whether the dot blinks. |
| `LimitsNotchModel` | `flash: NotchFlashEvent?` (ring color, dot color, blink, and an ID so a repeated flash restarts the animation). |
| `NotchPresenter.flash(_:)` (replaces `present(_:)`) | Publishes one flash for the alerts of a moment; "needs you" alerts also go through the alert queue, batching and `alertDuration`, which now serve only them. |
| `UsageRing`, `SessionsCounter`, expanded markers | Play the flash when `flash` changes. |
| `ClaudeCodeController` | On alerts in "When active", counts the moment as activity for the linger, so a hidden notch shows for 60 s. |
| `LimitsExpandedView` | `alertView` and `batchView` show only "needs you" alerts; sessions list gets insert/remove transitions. |
| `LimitsText` | Unchanged; the alert title is used for the log line (`… flashed`), the other alert texts are kept for later notifications. |

## 5. Edge Cases

| Condition | Behavior |
|---|---|
| An alert arrives while the notch is hidden by a full-screen app | No flash; the alert is logged. |
| An alert arrives with no notch screen and the menu bar text mode | No flash; logged. |
| A threshold alert and a session alert at once | One flash, the more urgent color; the dot flashes too. |
| The pointer hovers during a flash | The flash moves to the expanded view's marker as the notch expands. |

## 6. Probe (first implementation task, checked by the user)

A build where alerts flash. The user checks on the MacBook and on the monitor:

1. The ring's glow is not clipped in the compact wing.
2. The flash is noticeable but calm.
3. The ring's fill animates when the percent changes.

If the glow is clipped, the flash becomes a color change of the ring without the glow. Results are recorded in §8.

## 7. Testing

- `NotchFlash`: color per alert kind; the most urgent color of a batch; the dot only with a session needing you.
- Presenter: `flash` publishes one flash for alerts arriving together; only "needs you" expands, with its text, also over a full-screen app; a hidden notch does not flash.
- Controller: an alert in "When active" shows a hidden notch for the linger.
- Alert rules unchanged (existing alert policy and session alert tests keep passing).

Manual rows in `docs/testing.md`: L5, L9, S11, S12, S17, A4 change from "expands with text" to "flashes"; a new row for the list transitions.

## 8. Probe Results

Probed on 2026-10-13 on the MacBook and the monitor:

1. First build (one color on the ring for every alert): the green "finished" flash read well, but an orange "needs you" flash on a ring already orange near a limit was hard to tell apart. Changed to the split by place in §2.1.
2. Second build (ring for limits, dot for sessions): fine; the user asked to keep the expanded alert for "needs you" as well, the one alert that waits for an action. A per-type choice between flash and expand went to TODO.
3. The ring's glow was not reported as clipped.

## 9. Documentation

README (alerts flash the compact notch instead of expanding it), `docs/testing.md`, and a note in `specs/2026-10-09-claude-accounts-design.md` §4.4 and `specs/2026-10-06-claude-sessions-design.md` that alerts flash and no longer open Chats or a project on click.
