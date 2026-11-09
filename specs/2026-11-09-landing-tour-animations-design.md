# Workdeck — Landing Tour Animations Design

**Date:** 2026-11-09
**Status:** Implemented

## 1. Overview

The landing page's tour (`site/index.html`, the tabs left of the screen) shows still images for most features, and two of its seven tabs no longer tell the story the user wants: "Everything in the menu bar" shows the popover, and "Alerts that come to you" shows only a limit alert, while what the user values in alerts is a finished session that takes them to its window. This spec reorders the tour, replaces one tab, and adds four animations made by `make screenshots`, like the notch animations (`specs/2026-11-05-notch-animations-design.md`).

Decided with the user (2026-11-09):

- **Tab order and content:**
  1. Limits and sessions in the notch: unchanged.
  2. Alerts: a **finished session's** alert; the pointer clicks it and the session's Terminal window comes to the front. No limit alert in this tab.
  3. Out of limit: starts with the **limit alert**; clicking it opens Chats; the chat is carried on to the second account in Terminal.
  4. **Closed-Lid Mode** replaces "Everything in the menu bar": turned on, lid closed with the confidence the work will get done, lid opened, the session has finished.
  5. Quick notes: unchanged (the user likes it).
  6. Your week: the weekly recap card in the notch, then Statistics, its activity grid filling in, and the window **slowly scrolling from top to bottom** (the tall still looks poor). Both the card and Statistics matter. No agent filter switching.
  7. Every account (Instances): unchanged, now last.
- **Everything drawn by code**, like the other animations: the Terminal window and the MacBook too, never a screen recording.
- **The Terminal window is an abstract macOS Terminal**: title bar with the three buttons, dark background, monospaced text; not a copy of a particular theme. Sessions usually run in Terminal.
- **Closed-Lid Mode scene:** the user closes the lid "sure that the work will be done", so the scene is: on → lid closed → time passes → lid opened → hovering the notch shows the session finished (no alert: the real app shows none after the lid opens; §3.3).
- **Nothing else on the page changes:** header, install box, "After installing", footer stay as they are.
- **One animation at a time:** each is rendered and shown to the user, who says whether it is fine before the next one starts; order: Alerts, Out of limit, Closed-Lid, Your week, then the page.

Decided by me and played back to the user (no objection):

- The Out of limit scene skips closing the old Terminal window: it explains nothing.
- The Closed-Lid scene was chosen from three (lid + time passing; lid + a second device over SSH; the popover only) as the one telling Workdeck's own story: agents work, you learn when they are done.
- Tab texts (§2).

### Goals

- Each reworked tab shows in a few seconds what the feature is for, as a loop.
- `make screenshots` writes the new animations with the rest; same story every run.
- People who asked for reduced motion see a still, as today.

### Non-Goals

- Changes to the README (its Features list does not mention the menu bar tab; its images stay).
- Animating tabs 1, 5 and 7 differently, or touching their files.
- Changes to the app's look or behavior for the animations' sake.
- Video formats, screen recordings, CI.

### Anti-Goals

- Real data in a frame: only demo and fixture data, as every screenshot (`ScreenshotFixtures`, the demo scripts).
- A drawn Terminal or MacBook that pretends to be a photo or a particular product's UI theme beyond what reads as "Terminal" and "a MacBook".
- Files so large the page gets slow: each animation under about 4 MB after `oxipng`, as the notch animations.
- `make test` rendering or writing anything (same switch as now).

## 2. The Tour

Tabs in order, with their text (title, line). Titles and lines of unchanged tabs stay as they are.

| # | Title | Line | Slide |
|---|---|---|---|
| 1 | Limits and sessions in the notch | unchanged | `notch-hover-animated.png`, unchanged |
| 2 | Alerts that come to you | A session that finished or waits for a permission, a limit running low. Click to jump to its window. | `alert-session-animated.png` (§3.1) |
| 3 | Out of limit? Switch accounts | A limit alert opens Chats: carry the chat on to your second Claude Code account in one click. | `switch-account-animated.png` (§3.2) |
| 4 | Close the lid, the work goes on | Closed-Lid Mode keeps the Mac awake with the lid closed: agents, builds and SSH finish while you're away. | `closed-lid-animated.png` (§3.3) |
| 5 | Quick notes to Reminders | unchanged | `notes-capture-animated.png`, unchanged |
| 6 | Your week at a glance | Half a year of work in Statistics: time, projects and limits by week. A recap comes on the first unlock of each week. | `week-frame.png`, `week-body.png`, `week-grid-empty.png` moved by the page's CSS (§3.5) |
| 7 | Every account, set up alike | unchanged | `instances-light/dark.png`, unchanged |

- Each animated tab gets `data-seconds` equal to its animation's length (rounded up to a whole second), as tabs 1, 2 and 5 have now, so the tab stays as long as one loop.
- Reduced motion (`<picture>` with `prefers-reduced-motion: reduce`) shows the still named in §3; the animation is loaded after the page as the existing ones are (`data-animated`).
- `popover-light/dark.png` leave the landing page but are still written (the README shows them). `chats-*.png` and `statistics-*.png` stay as the reduced-motion stills of tabs 3 and 6.
- Alt texts describe what happens in the animation, as the existing ones do.
- **A scene with a window touches the block's top and bottom** (the user, 2026-11-10): its picture has about the tour block's proportions (720 × 720 pt for a ~590 × 540 block), the notch flush with the top, the window running off the bottom; the page shows it with `object-fit: cover`, top-aligned, so the block crops the window's last points instead of leaving an empty band.

## 3. The Animations

All are APNG at 2×, loop forever, start and end on the same frame, and are written to `docs/media/screenshots/` like the notch animations, through the same timeline / recorder / `APNGWriter` path (§4). One file each, drawn in dark appearance (the notch is black in both appearances; the Terminal is dark; the windows in these scenes use their dark look). Lengths are starting points to tune by eye.

The pointer is macOS's arrow as in the notch animations. **A click** shows as a short press: the pointer dips (scale about 0.9 for ~0.15 s) and the clicked control shows its pressed state where the real view has one. *(My call.)*

### 3.1 Alerts: a finished session takes you to its window — `alert-session-animated.png` (about 8 s)

```
compact notch ─▶ opens by itself: "✳ orbit-app finished · 12m" (green glow)
      pointer comes in, clicks the alert
notch closes ─▶ a Terminal window slides/fades to the front below it:
┌ ● ● ●        orbit-app — claude ─────────────────────┐
│ ⏺ Done. The orbit renderer now batches draw calls;  │
│   all 48 tests pass.                                 │
│                                                      │
│ > _                                                  │
└──────────────────────────────────────────────────────┘
hold ─▶ Terminal fades, back to the compact notch
```

- The alert is the demo's real `.sessionFinished(project: "orbit-app", …)` alert view (`ClaudeCodeDemoScript`), opened and closed with the notch animation's computed opening (notch animations spec §3.1).
- The Terminal window is a new drawn view (§4.2) under the notch, on the clear canvas (§4.4); its content is made-up: the agent's last answer and an empty prompt line. The window title names the project.
- Still: `notch-alert.png`'s counterpart for this alert, a new still `alert-session.png` (the expanded "finished" alert). *(My call: the still shows the alert, the part that is Workdeck.)*

### 3.2 Out of limit: carry the chat to another account — `switch-account-animated.png` (about 10 s)

```
compact notch (ring red) ─▶ opens: "5-hour limit at 95% · main" (red glow)
pointer clicks the alert ─▶ notch closes, the Chats window appears
pointer moves to "Fix the orbit renderer" (main) ─▶ row hover shows Terminal
click Terminal ─▶ the account menu: main / personal ─▶ click "personal"
Chats steps back ─▶ Terminal in front:
┌ ● ● ●        orbit-app — claude ─────────────────────┐
│ $ claude --resume                                    │
│ ⏺ …the last messages of the chat…                   │
│ > _                                                  │
└──────────────────────────────────────────────────────┘
hold ─▶ back to the compact notch
```

- The alert is the demo's 95 % threshold alert for `main`; clicking a limit alert opens Chats in the real app (`docs/claude-code.md`), so the scene follows the product.
- Chats is the real `ChatsView` over the existing Chats fixture (accounts `main` and `personal`, the chat "Fix the orbit renderer"), dark. Its row hover and the account menu are the real ones where they can be rendered offscreen; the menu (an `NSMenu` in the app) may be drawn as a look-alike popup if a real one cannot be captured. *(Builder's call.)*
- The second account is **personal** (the fixture's), not "work" as said in the conversation.
- Terminal: the same drawn view as §3.1, showing the resume command and two or three made-up lines of the chat.
- Still: `chats-dark.png` / `chats-light.png` as now.

### 3.3 Close the lid, the work goes on — `closed-lid-animated.png` (about 10 s)

```
a MacBook, front view, screen on:
  menu bar with Workdeck's icon, the popover open, Closed-Lid Mode switch turns on (pointer click)
  the notch shows a working orbit-app session (spinner)
lid closes (the screen folds down to the base's edge, darkening)
  beside it a clock runs 12:00 → 12:40
lid opens ─▶ the compact notch, no spinner any more
pointer rests on the notch ─▶ it opens: orbit-app's session is done (its steps ✓, finished while the lid was closed)
pointer leaves, notch closes ─▶ back to the first frame
```

- The MacBook is a new drawn view (§4.3): a simple front view (screen with bezel and notch, a thin base), not a product render. Closing is the screen's height going to zero toward the hinge with a darkening, opening the reverse; exact geometry is the builder's.
- Inside the screen, scaled down: the real `ClosedLidModeRow` (or the popover around it) for the switch, and the real compact and alert notch views. The menu bar is drawn simply (a bar with the Workdeck icon and a clock).
- The clock beside the laptop is large enough to read on the page; it says only the time.
- **After the lid opens, no alert** (the user, 2026-11-09, after the builder check): the real app drops an alert that fires with no screen (`NotchPresenter.present`, `guard screen() != nil`) and an alert lasts seconds, so the scene shows what the app really shows: the pointer hovers the notch and the expanded notch (the real view, scaled into the screen) has the orbit-app session finished, as a finished session reads there (its last steps checked, idle since it finished). Its finish time falls inside the 12:00–12:40 the clock ran.
- Still: a new `closed-lid.png`, the frame with the popover open and the switch on. *(My call.)*

### 3.4 Your week (superseded by §3.5: no notch, no card, CSS over stills)

```
compact notch ─▶ opens with the weekly recap card (last week · 10h 19m …)
pointer clicks "Details…" ─▶ card closes, the Statistics window appears
the activity grid fills in from the oldest week to the newest (~1 s)
the window's content scrolls slowly from the top to the bottom (~5 s)
hold ─▶ back to the compact notch
```

- The card is the real recap card (`notch-recap.png`'s view, `RecapDemoScript` data); Statistics is the real window over the existing statistics fixture, dark.
- **Grid filling:** the builder may drive it through the view (days shown up to a moving date) or by masking the grid's cells column by column; it must look like weeks appearing left to right, not a wipe across the labels.
- **Scrolling:** a smooth, eased scroll of the window's content from top to bottom; the window's title bar and toolbar stay in place, as when scrolling in the real window.
- Still: `statistics-dark.png` / `statistics-light.png` as now.

## 3.5 As built (the user's calls at each animation, 2026-11-10)

- **Alerts:** as §3.1; no hover cue before the click (tried, rejected); no countdown bar; 60 fps everywhere (the user: lower rates looked jerky).
- **Out of limit:** as §3.2; Chats is a 640 × 560 snapshot so the picture (720 × 720) has the block's proportions and touches its top and bottom; the page shows it with `object-fit: cover`, top-aligned.
- **Closed-Lid:** as §3.3; the screen goes dark at once before the lid turns (a lit lid weighed ~300 KB a frame); the lid turns on its hinge in perspective with rounded corners and lies on the base as a thin aluminum edge as wide as the base.
- **Your week (replaces §3.4):** no notch and no card: the Statistics window shows at once, its grid fills week by week, and the window scrolls slowly down and back up. The page does this with CSS over three stills (`week-frame.png`, `week-body.png`, `week-grid-empty.png`): a 60 fps scroll in an APNG would weigh 20+ MB. Reduced motion: the window stands still with the full grid.

## 4. How They Are Made

### 4.1 The pipeline

The four animations use the existing machinery: a pure timeline of phases yields frames (delays, progress, pointer position, per-scene state); the recorder renders one offscreen window per animation and captures frames; `APNGWriter` writes changed rectangles; `make screenshots` compresses with `oxipng`. New phase kinds (a click, a window appearing, a scroll, a lid angle, a clock time, a grid fill) are added to the timeline type or a scene-specific timeline next to it (builder's call), all pure and tested like `NotchAnimationTimeline` and `NotesAnimation`. Each scene is a test-target view composing the real app views with the drawn parts; nothing is added to the app target.

### 4.2 Drawn Terminal

A SwiftUI view in the test target: window corners and shadow like `ScreenshotRenderer.writeWindow`'s windows, a title bar with the three buttons and a centered title, a near-black background, SF Mono (system monospaced) text in light gray with the agent's marks in the Claude Code accent where the text has them. Its lines are passed in; nothing is read from a real terminal or transcript.

### 4.3 Drawn MacBook

A SwiftUI view in the test target: a dark bezel with rounded top corners and a notch, the screen content as a child view, a thin base below with a center lip. A `lidOpen` value from 1 to 0 folds the screen down toward the hinge (vertical scale toward the bottom edge plus darkening). Neutral grays, no logo.

### 4.4 Canvas and size

Each scene has one canvas size for all its frames (APNG). **The canvas is clear**, as in the existing animations (`writeAnimation`): the page's card shows through around the notch, the windows and the MacBook, and windows keep their shadows. *(My call after the builder check.)* The notch hangs from the top edge in scenes that use it (§3.1, 3.2), with windows below it. The slides with the notch at the top keep the `top` class. Each file stays under about 4 MB after `oxipng` (the test's limit before compression: 5 MB for a notch-only scene, as now, 8 MB for a scene with a window, which `oxipng` halves; the user, 2026-11-10: keep 60 frames a second, smoothness first); `make screenshots` fails when one is over 4.5 MB after `oxipng`; if one grows past that, the first things to cut are the length of window fades and holds, not the frame rate (the user) or resolution.

## 5. Page Changes

- `site/index.html`: the tabs in §2's order with §2's texts; slides with the new animations, stills and alt texts; `data-seconds` per animated tab.
- Nothing else on the page changes.

## 6. Edge Cases

| Condition | Behavior |
|---|---|
| Reduced motion | The still of §3 for each tab. |
| A browser without APNG | The first frame (compact notch, or the MacBook with the popover). Acceptable. |
| A product view changes look (notch, Chats, Statistics, recap) | `make screenshots` remakes the animations, as the rule for screenshots already says. |
| Light appearance on the page | The animations stay dark; the notch is black anyway. Acceptable. |

## 7. Testing

- **Timelines (normal test run):** each new scene's total length; first and last frames are the same state (seamless loop); a click phase dips and restores the pointer; the scroll phase goes from 0 to the bottom monotonically and eases; the grid fill reaches every week; the lid goes 1 → 0 → 1; the clock reads 12:00 at closing and 12:40 at opening.
- **Rendering (only with the screenshots switch):** each file written, an APNG with more than one frame and loop count 0, canvas 2× its point size, first and last decoded frames identical (a scene's last hold repeats its first frame, so `everySceneEndsAsItStarts` checks that each scene's state returns to its first), size under 5 MB (8 MB with a window) before `oxipng`; the new stills written at 2×.
- `everyImageWasWritten` includes `alert-session-animated`, `alert-session`, `switch-account-animated`, `closed-lid-animated`, `closed-lid`, `week-frame`, `week-body`, `week-grid-empty`; the Your week test checks the numbers the page's CSS has written in.
- The site: the existing install-command check still passes (`scripts/release/test_install.py`).

## 8. Documentation

- `CLAUDE.md`: the screenshots note mentions the three animations, the Your week stills, the drawn Terminal and MacBook.
- `docs/media/screenshots/` gets the new files (generated only).
- No CHANGELOG line: the app does not change (the landing page is not in the app's release notes).
