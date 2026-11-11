# The Instances Tab Animation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The landing page's last tab, "Every account, set up alike", plays `instances-animated.png`: the popover's Instances… button opens the Instances window, a skill one account lacks is copied into it through the cell's menu and the review sheet, and the cell turns present.

**Architecture:** `InstancesAnimation` in `WorkdeckTests/Screenshots`, built like `SwitchAccountAnimation`: `SceneTimeline` phases, a `PointerTrack`, a pure `shown(frame)` and a pure `Layout` of constants (the popover's place, the measured Instances… button and `+ Add` cell, the sheet's size), so the pointer's targets and the loop's seam are tested in every run. The popover is the real `PopoverView` in `PopoverScene`, its Claude Code row with a second instance so Instances… shows (`fixtures.claudeCode(extraInstance:)`). The window is two `snapshotWindow`s of the real `InstancesWindow` over `fixtures.instancesCompare()` under its default "Not everywhere" filter with `write-docs` selected: before and after the controller really copies `write-docs` from personal into main (into the fixture's temporary folders). The cell's menu is a look-alike carrying the real `CellMenu` item's title; the sheet is the real `SetupReviewSheet` rendered offscreen in its review and Done states and drawn in a sheet's frame over the window.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing.

**Spec:** `specs/2026-11-11-polish-batch-design.md` §6; `specs/2026-11-09-landing-tour-animations-design.md` §3–§4.

## Global Constraints

- Made-up accounts and skills only: the existing Instances fixture (main, personal, work) in temporary folders.
- Dark only, 60 frames a second, the canvas about the tour block's proportions (a `bleed` slide), under 8 MB before `oxipng`.
- The still test `instances()` and `instances-light/dark.png` stay; `instances-dark.png` is the reduced-motion image.
- Nothing in the app target changes.
- Do not run the full `make screenshots`: render only this scene; leave other features' images alone.
- English only; no commits.

## Review Focus

1. Each step reads at the page's size: the Instances… button, the window, the `+ Add` cell, the menu, the sheet, the present dot.
2. The pointer's clicks land on the real controls' places in the snapshots (measured constants; a wrong constant shows as a click beside the control).
3. The loop's seam: the last hold shows the popover again, as the first frame.
4. File size, and frames that rewrite the whole window (fades) kept short.

---

### Task 1: Pure tests first

- [ ] `everySceneEndsAsItStarts` gains the Instances scene: `shown(last) == shown(first)`, the pointer hidden at both ends.
- [ ] `instancesPointerTargetsTheButtonTheCellTheItemAndConfirm`: the clicks, in order, land on the Instances… button, the `+ Add` cell, the menu item, Confirm and Close.
- [ ] `theInstancesSceneCopiesAMissingSkill`: in the fixture under All, `release-notes` lacks a personal copy, its cell's menu offers one item, `Copy from main`; performing and confirming it makes the cell present.
- [ ] Watch them fail (no `InstancesAnimation`).

### Task 2: The scene

- [ ] `fixtures.claudeCode(extraInstances:)`: an extra account so the row shows Instances….
- [ ] `InstancesAnimation`: phases, `Layout`, `shown`, `pointer`, `make` (popover parts, two window snapshots, two sheet images), `write`; `InstancesView`, `CellMenuLookAlike`, the sheet frame.
- [ ] `@Test(.enabled(if: ScreenshotRenderer.isEnabled)) instancesAnimation()`, checking the measured sheet size against `Layout`, and `everyImageWasWritten` gains `instances-animated`.
- [ ] Render only this test, `oxipng`, look at frames of each step; tune the constants and timings.

### Task 3: Page and docs

- [ ] `site/index.html` slide 6: `bleed`, the reduced-motion `<source>` with `instances-dark.png`, `data-animated`, an alt text of the story; tab 6 `data-seconds` = the loop rounded up.
- [ ] `Makefile`: the image count 25.
- [ ] `CLAUDE.md` Screenshots paragraph: `instances-animated.png` (`InstancesAnimation`).
- [ ] Full suite.

## As built (rulings)

- `write-docs` is copied from personal into main ("Copy from personal"): copying `release-notes` would make its row "everywhere", so it would move or fold away — cost if wrong: three constants and one measurement.
- The window keeps the default "Not everywhere" filter, 800 × 660 (at 720 the inspector pushed the work column out); `write-docs` is selected so the inspector shows the skill.
- Short fades (window 0.12 s, sheet 0.2 s in, 0.15 s out) keep the file under the Makefile's 4.5 MB limit.
- The real sheet stays open after Confirm until Close: the scene shows Done and clicks Close (about 0.6 s).
- The cell's menu is a look-alike with the real item's title (an `NSMenu` cannot be captured offscreen); the sheet's frame is drawn around the real view.
- Slide 6 is `bleed` like slide 2: the reduced-motion still is `instances-dark.png` with `object-fit: cover`, and light-mode viewers see the dark still.
- The pointer test is `instancesPointerTargetsTheButtonTheCellTheItemAndTheSheet`.
