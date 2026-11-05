# Workdeck — Animated Notch Design

**Date:** 2026-11-05
**Status:** Draft

## 1. Overview

The landing page's first two feature tabs ("Limits and sessions in the notch", "Alerts that come to you") show still images of the notch. The notch is the part of Workdeck that moves: it sits compact, opens when the pointer rests on it, ticks through each session's steps, and opens by itself for an alert. This spec adds two short looping animations of exactly that, made by `make screenshots` from the demo, like the stills.

Decided with the user (2026-11-05):

- **Two animations**, replacing the stills of the first two tabs:
  1. **Hover:** the compact notch; an arrow pointer comes in and rests on it; the notch opens; for a couple of seconds the sessions' steps change; the pointer leaves; the notch closes.
  2. **Alert:** the compact notch opens by itself with the 5-hour limit alert, holds it, and closes.
- **Made automatically** with the stills, from the demo, so they stay current when the notch changes.

Decided by me and played back to the user (no objection):

- **Format: animated PNG (APNG)**, not GIF. GIF has 256 colors and on/off transparency: the notch's curved edges and its orange glow would come out ragged and banded on the landing page's indigo card. APNG keeps full color and soft transparency, plays in every current browser and in GitHub's README, and ImageIO writes it (no dependency).
- **The opening and closing are computed frame by frame**, imitating DynamicNotchKit's animation; its real animation cannot be captured offscreen.
- **Live holds** (the user, 2026-11-05, after the builder check): while the notch is open, its own motion plays — the agent spinner, the shimmer on the current step, the activity pulses, the rows sliding when a step changes, the alert badge's pulses and the countdown bar. These run on the wall clock (`TimelineView`, SwiftUI animations), so the open phases are captured live at about 10 frames a second, and each run of `make screenshots` gives slightly different files, as `notch-expanded.png` already does.

### Goals

- `make screenshots` also writes the two animations; the same story and timing every run (the wall-clock motion inside the open notch may land differently, §1).
- They loop forever, look like the real notch, and stay small enough for a web page.
- The landing page's first two tabs show them; people who asked their system for reduced motion see the still.

### Non-Goals

- Video (MP4/WebM), GIF, or a recording of the real screen.
- Animations of anything else (popover, windows, recap).
- Matching DynamicNotchKit's animation curve exactly; it must read the same, not be the same to the frame.
- Running in CI.

### Anti-Goals

- No real data in a frame (same rule as the stills: demo data only).
- `make test` and Xcode's test runs must not render or write anything (same switch as the stills).
- No change to the notch, the demo script or any product code for the animations' sake.

## 2. The Animations

Both are APNG at 2× (Retina), written next to the stills in `docs/media/screenshots/`, with a `.png` extension (browsers and GitHub's image proxy detect APNG by content; an `.apng` extension risks a wrong content type). The notch is black in both appearances, so one file each.

| File | Length (about) | What |
|---|---|---|
| `notch-hover-animated.png` | about 6.8 s, loops | compact (1 s) → pointer moves in and rests on the notch (0.6 s) → opens (0.4 s) → expanded, steps change (about 3.5 s) → pointer moves away (0.4 s) → closes (0.4 s) → compact (0.5 s) |
| `notch-alert-animated.png` | about 6.7 s, loops | compact (1 s) → opens with the alert (0.4 s) → holds the alert (2.5 s) → closes (0.4 s) → the ring flashes once, as after a real alert (`NotchPresenter.flash`; 1.9 s, its whole course) → compact (0.5 s) |

- **Content** is the real views with the demo's data, at the moments the stills use:
  - compact: `LimitsCompactLeading` / `LimitsCompactTrailing`;
  - expanded: `LimitsExpandedView` from the demo at successive seconds, so the step ticker and line counts move as they do in the demo; the expanded seconds start at the still's second 12;
  - alert: the demo's threshold alert, as `notch-alert.png`.
- **Frame and margin** as the stills now: the notch hangs from the image's top edge; a margin below and beside it. Every frame has the same size (APNG needs one canvas): wide and tall enough for the expanded notch and, for the hover animation, for the pointer's path.
- **The pointer** is macOS's own arrow (`NSCursor.arrow.image`, at its 2× representation), drawn over the frame. It enters from the lower right, rests on the compact notch's middle while the notch is open, and leaves the same way. The alert animation has no pointer.
- **The loop** starts and ends on the same compact frame, so the seam does not show. For the alert this is the compact state at the alert's moment (demo second 30, the ring already at 80 %) at both ends: the loop stays seamless, and the alert opening still reads; the ring turning orange because of the alert is not shown. *(My call, from the builder check.)*

## 3. How They Are Made

### 3.1 Opening and closing

DynamicNotchKit (1.1.x) opens the notch with `.bouncy(duration: 0.4)` and closes it with `.smooth(duration: 0.4)`. During the change, the outline's size moves between the compact and the expanded outline, and the expanded content comes in with a blur of 10, a vertical scale from 0.6 (anchored at the top) and opacity; the compact halves leave with the same blur, a horizontal scale to 0 and opacity (`NotchView`'s transitions). The frames reproduce this:

- **Progress** over time comes from SwiftUI's `Spring` (`Spring.bouncy(duration: 0.4)` opening, `Spring.smooth(duration: 0.4)` closing), sampled at 30 frames a second; it may overshoot 1 while opening, which grows the outline a little past its size and back, as in the real notch.
- **Outline:** width, height and corner radii interpolated between the compact and the expanded `NotchOutline` (the radii the stills use: 6/14 compact, 15/20 expanded) by progress.
- **Content:** the expanded view with blur `10 × (1 − p)`, vertical scale `0.6 + 0.4 × p` anchored at the top, opacity `p`; the compact halves with the reverse. Clipped to the outline, as the stills are.

The exact interpolation, which content shows at a given progress, and how many frames each phase gets are the builder's to tune by eye against the real notch; the numbers above are the starting point.

### 3.2 Frames and timing

A pure timeline type (no AppKit) describes an animation as phases (compact hold, pointer move, open, live hold, close, flash) with durations; it yields the frames with their delays and, for each frame, the demo second, the opening progress and the pointer's position. Pointer movement uses an ease-in-out curve over its phase. The timeline lives in the test target, next to the renderer.

- **A compact hold** is one frame with its whole delay (the compact notch has no wall-clock motion while nothing changes); this keeps the files small.
- **Live phases** (the open notch, the pointer leaving, the flash) are sampled at 60 frames a second, each frame captured at its moment of real time (§3.3). A frame whose moment has passed before the previous one finished drawing is dropped and the previous one shows longer, as a screen recording does (the open hover notch takes about 40 ms to draw offscreen, so it comes out near 24 frames a second at the real pace).
- **Opening, closing and the pointer coming in** are sampled at 60 frames a second (§3.1).
- *(Changed on 2026-11-05 after the user saw the first render: 10 frames a second looked jerky; the user asked for 60 and compression.)*

### 3.3 Rendering and writing

The recorder waits between frames by suspending (`Task.sleep`), not by running the run loop: the views' own tasks (the flash's timed fade) run on the main actor and resume only while the recorder yields it. Frames are rendered offscreen like the stills (`ScreenshotRenderer`'s borderless window), but one window and one hosting view stay up for a whole animation: the timeline's state (demo second, progress) is handed to the view, and the frame is captured with `cacheDisplay`. For a live hold, frames are captured 0.1 s of real time apart (run loop runs between them), so the `TimelineView` and SwiftUI animations advance as on screen; re-creating the window per frame (0.6 s settle each) would freeze them at random phases. Each bitmap is the canvas size, the pointer drawn over it where the timeline puts it. The frames are written as one APNG that loops forever. ImageIO encodes the pixels, but the writer assembles the APNG chunks itself (ImageIO writes every frame whole): a frame stores only the rectangle that changed since the previous one; when every changed pixel is opaque, the unchanged pixels inside it are stored clear and blended over; identical frames merge into one longer frame. The outline's size is rounded to the 2× pixel grid so the bounce's sub-pixel wobble merges too. Nothing is added to the app target.

### 3.4 Size

Each animation should stay under about 4 MB (the test's hard limit is 5 MB, checked before compression); the hover one is the larger. After the tests write them, `make screenshots` compresses both losslessly with `oxipng -o 4 --strip safe` (MIT, Homebrew; the user chose an external tool on 2026-11-05), which keeps the animation and takes about a third off (hover 4.5 → 2.9 MB). Lossy palette tools (pngquant) do not handle APNG. If one grows past that, the first things to change are the transition frame rate (30 → 20) and the number of expanded seconds, not the resolution.

## 4. Where They Show

- **Landing page:** the first tab's slide shows `notch-hover-animated.png`, the second's `notch-alert-animated.png`, top-aligned as the stills are now. Through `<picture>`, `(prefers-reduced-motion: reduce)` gets the still (`notch-expanded.png`, `notch-alert.png`). Each `<img>` loads its still with the page and names its animation in `data-animated`; once the page has loaded, a script fetches the animation and puts it in the still's place (not under reduced motion), so the first tab costs the still's ~130 KB up front, not the animation's few MB. The tab's own rotation (6 s a tab) is unchanged; the animation starts wherever it is when the tab shows, which is fine for a loop.
- **README:** the "Hover to see everything" and "When something needs you" rows show the animations instead of the stills, at the widths the stills have there (the hover one about 220 px tall, the alert one 360 px wide, as now). *(My call, from the builder check.)* GitHub has no reduced-motion switch for images; that is acceptable.
- `pages.yml` already copies the folder.

## 5. Edge Cases

| Condition | Behavior |
|---|---|
| A browser without APNG support | It shows the first frame (APNG's default image): the compact notch. Acceptable. |
| Reduced motion on the landing page | The still, via `<picture>`. |
| The notch's look changes | `make screenshots` remakes the animations with the stills (the CLAUDE.md rule covers them). |
| DynamicNotchKit changes its animation | The frames keep the old feel until someone updates §3.1's numbers; the stills are unaffected. |

## 6. Testing

- **Timeline (normal test run):** phases give the right total length; a compact hold becomes one frame with its whole delay; a live hold becomes frames 0.1 s apart; the first and last frames are the same state, so the loop is seamless; opening progress overshoots 1 and settles at 1; closing ends at 0.
- **Rendering (only with the switch, in `ScreenshotTests`):** each file is written, is an APNG with more than one frame and a loop count of 0, its canvas is 2× the point size, its first and last decoded frames are identical (the loop's seam), and its size is under 5 MB; the open hover notch fits every demo second it shows.
- `everyImageWasWritten` includes the two animations; `make screenshots`' count of written images goes from 10 to 12.

## 7. Documentation

- CLAUDE.md: the screenshots note mentions the two animations and the timeline type.
- README and `site/index.html`: §4.
- TODO: remove "GIFs of the notch on the landing page"; the README media item's video part stays open.
