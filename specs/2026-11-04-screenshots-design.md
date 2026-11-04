# Workdeck — Automatic Screenshots Design

**Date:** 2026-11-04
**Status:** Draft

## 1. Overview

The README and the landing page (`site/index.html`) describe Workdeck in text only. This spec adds screenshots of its parts, made by one command from demo data, so they can be remade whenever the look changes or a feature is added.

Decided with the user (2026-11-04):

- **Still screenshots of separate parts**; video or GIF later (a separate item).
- **Made automatically** by a command, because the look and the features keep changing.
- **Rendered offscreen from demo data** (the spike, approved by the user: `.superpowers/screenshot-spike/`): the real views drawn in an invisible window, no Screen Recording permission, no real projects, accounts or titles. The spike showed that an offscreen `NSWindow` with an `NSHostingView` renders system controls (segmented picker, lists) that `ImageRenderer` leaves as placeholders.
- **The set** (user: "all ok, I'll decide when I see them"): compact notch, expanded notch, an alert, the weekly recap card, the popover, the Statistics window, the Chats window.

### Goals

- `make screenshots` writes every image, the same every time on the same macOS.
- The README and the landing page show them.
- Nothing personal can end up in an image.

### Non-Goals

- Video, GIF, animated notch.
- Screenshots of the real screen (menu bar, wallpaper, the physical notch).
- Pixel comparison tests (snapshot testing) or a check that images are up to date.
- Running in CI (macOS runners are scarce; the author runs it locally).

### Anti-Goals

- An image must never contain the author's real data: project names, chat titles, account names, limits, paths.
- Normal test runs (`make test`, Xcode) must not render or write images.

## 2. The Images

All PNG at 2× (Retina), written to `docs/media/screenshots/`. Light and dark where the part has both; the notch is black in both modes, so one image.

| File | What | Data |
|---|---|---|
| `notch-compact.png` | The compact notch: ring with percent, session counters, agent marks | Demo second ~12, as in the expanded view |
| `notch-expanded.png` | The expanded notch: three accounts' limits with the forecast, sessions with an agent, step ticker and line counts | Demo second 12 (as the spike) |
| `notch-alert.png` | The expanded notch with one limit alert ("5-hour limit at 80%") | Demo state plus the demo's threshold alert |
| `notch-recap.png` | The weekly recap card in the notch | `RecapDemoScript.recap` |
| `popover-light.png`, `popover-dark.png` | The menu bar popover: Closed-Lid Mode, Claude Code and Codex rows | Demo state; Closed-Lid Mode shown on |
| `statistics-light.png`, `statistics-dark.png` | The Statistics window (as the spike) | `RecapDemoScript.days`, a fixed Thursday |
| `chats-light.png`, `chats-dark.png` | The Chats window with two accounts | Made-up chats (§3.3) |

- **The notch** is drawn on black with the real notch shape: a flat top, rounded bottom corners, a few points of transparent margin around it. Its content is exactly the real view: `LimitsExpandedView` is 300 pt wide, so long session rows are cut with "…" as they are in the real notch, and that stays (the user, 2026-11-04: everything must match the real app; no change to the notch or the demo strings for the images).
- **Windows** (Statistics, Chats) are drawn at their default width with the window background, without window chrome: no title bar and no toolbar (the user, 2026-11-04: without the toolbar for now). Statistics loses its week arrows and subtitle; Chats loses its search field, the Last 30 days / All picker and Refresh, and shows its project and account chips and the list.
- **The popover** at its real width (300 pt), with the popover's material approximated by the window background.

## 3. How They Are Made

### 3.1 The command

`make screenshots` runs one Swift Testing suite, `ScreenshotTests`, which renders every image. The suite does nothing unless an environment variable asks for it (`WORKDECK_SCREENSHOTS=1`, passed to the hosted test process by `make screenshots`, e.g. as `TEST_RUNNER_WORKDECK_SCREENSHOTS=1`), so `make test` and Xcode's test runs skip it (§1 Anti-Goals). It prints the paths it wrote.

### 3.2 Rendering

A small helper renders a SwiftUI view in an offscreen, borderless `NSWindow` through an `NSHostingView` with a given appearance (`aqua`/`darkAqua`) and width, lets the run loop settle briefly (layout, `onAppear`), and writes `bitmapImageRepForCachingDisplay` output as PNG — the spike's approach. Fixed: the clock (the demo's fixed dates), the calendar and time zone (Europe/Berlin, as the tests use), the locale (`en_US_POSIX`), so reruns produce the same images.

### 3.3 Data

- **Notch:** the demo pipeline, as `ClaudeCodeDemoControllerTests` drives it (controller with fakes, `demoDidStart`, `demoTick(elapsed:)`, the presenter's last state).
- **Popover:** the demo does not reach the popover rows (they read the real stores), so the test seeds those stores with made-up data in temporary folders: a `claude-usage.json` snapshot and session event files for Claude Code, fake limits and sessions for Codex, Closed-Lid Mode's fakes reporting it on. No product code changes; the rows show what the app shows for that data. *(My call, from the builder check.)*
- **Statistics:** `RecapDemoScript.days` and a `StatisticsController` on a fixed date.
- **Chats:** a fixed list of made-up chats (projects `orbit-app`, `api-server`, `docs-site`; titles like "Fix the orbit renderer", "Add rate limiting"; accounts `main` and `personal`) given to the Chats window through its existing test seams (fakes for its index and instances), never the real `~/.claude*`.
- Anything that would read real files, the Keychain or the network is faked, as in the existing tests.

### 3.4 Where they show

Chosen by the user on 2026-11-04 from three layouts (a step-by-step tour, topic sections like Coucou, one stage with tabs): **the step-by-step tour**, to be polished later.

- **Landing page:** "How it works" after the install box: seven numbered steps in the order a colleague meets Workdeck — the popover, the compact notch, the expanded notch, an alert, Chats, the weekly recap, Statistics — each a screenshot and a title with two sentences, alternating left and right; every screenshot in a frame of one height (300 pt, 240 pt on a phone), scaled to fit. The old text-only "What does Workdeck do?" blocks are gone (the steps replace them). A click on a screenshot shows it full screen; Esc or a click closes it.
- **README:** "A Quick Tour", the same seven steps as a table (screenshot | step), every screenshot 220 px tall, light/dark through `<picture>`. No header image.
- `pages.yml` copies `docs/media/screenshots/` into the site.

### 3.5 Keeping them current

CLAUDE.md gains a rule: a change to what one of these parts looks like ends with `make screenshots` and the updated images in the same commit. `docs/media/screenshots/` holds only generated files.

## 4. Edge Cases

| Condition | Behavior |
|---|---|
| `make screenshots` on a Mac without a camera housing or with another macOS | Same images except for system font rendering; the notch is drawn, not captured. |
| A view that reads the real screen or system state (e.g. notch screen detection) | Given the demo's values (`cameraHousings: { [true] }` as in the tests). |
| An image larger than about 600 KB | Kept, but worth a look: the README loads all of them. |

## 5. Testing

The images are the output; there are no pixel assertions. `ScreenshotTests` checks that each file was written and is non-empty with the expected pixel width (2× the point width), and the suite is skipped without the environment variable (a test that `make test` does not write `docs/media/screenshots/`). The rendering helper and the demo setup are shared with the spike's approach.

## 6. Documentation

CLAUDE.md (Build and Test: `make screenshots`; the rule in §3.5), README (the images), `site/index.html`, `pages.yml` (copy the folder), TODO (the README media item: screenshots done, video still open).
